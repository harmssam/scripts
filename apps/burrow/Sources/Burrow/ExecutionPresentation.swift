import Foundation
import Observation

enum ExecutionPresentationMode: Equatable, Sendable {
    /// Replays a demo scenario in memory. It never opens or changes a filesystem node.
    case fixtureSimulation
    /// The shipping default. No confirmation can cross the disabled transport boundary.
    case productionDisabled

    var label: String {
        switch self {
        case .fixtureSimulation: "DEMO SCENARIO · NO FILES WILL CHANGE"
        case .productionDisabled: "EXECUTION DISABLED"
        }
    }
}

struct ExecutionPlanReview: Equatable, Sendable {
    let previewFingerprint: String
    let plan: ExecutionPlan

    var operation: MaintenanceOperation {
        MaintenanceOperation(rawValue: plan.kind.rawValue) ?? .clean
    }

    var itemCount: Int { plan.operations.count }
    var affectedBytes: Int64 { plan.operations.reduce(0) { $0 + $1.target.byteCount } }
    var shortFingerprint: String { String(plan.metadata.fingerprint.prefix(8)).uppercased() }
}

enum ExecutionPresentationState: Equatable, Sendable {
    case review(ExecutionPlanReview)
    case confirming(ExecutionPlanReview, ExecutionConfirmation, SafetyGate)
    case executing(ExecutionPlanReview, ExecutionProgress)
    case receipt(ExecutionPlanReview, OperationReceipt)
    case stale(previousPlanFingerprint: String)
    case failed(String)
}

enum ExecutionPresentationError: Error, Equatable, Sendable {
    case previewChanged
    case confirmationUnavailable
    case confirmationRejected
}

/// Main-actor presentation state for the review → confirm → execute → receipt flow.
/// The reviewed plan is immutable and every transition rechecks its preview binding.
@Observable @MainActor
final class ExecutionPresentationModel {
    private(set) var state: ExecutionPresentationState
    let mode: ExecutionPresentationMode

    private let coordinator: OperationCoordinator
    private let now: @Sendable () -> Date
    private let persistReceipt: (@MainActor (OperationReceipt) async -> Void)?
    private var executionTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var persistedReceiptID: UUID?

    init(
        review: ExecutionPlanReview,
        mode: ExecutionPresentationMode,
        coordinator: OperationCoordinator,
        now: @escaping @Sendable () -> Date = Date.init,
        persistReceipt: (@MainActor (OperationReceipt) async -> Void)? = nil
    ) {
        self.state = .review(review)
        self.mode = mode
        self.coordinator = coordinator
        self.now = now
        self.persistReceipt = persistReceipt
    }

    var review: ExecutionPlanReview? {
        switch state {
        case .review(let review), .confirming(let review, _, _),
             .executing(let review, _), .receipt(let review, _): review
        case .stale, .failed: nil
        }
    }

    var isExecuting: Bool {
        if case .executing = state { return true }
        return false
    }

    var isCancellationRequested: Bool {
        if case .executing(_, let progress) = state { return progress.cancellationRequested }
        return false
    }

    func beginConfirmation(currentPreviewFingerprint: String) throws {
        guard case .review(let review) = state else { throw ExecutionPresentationError.confirmationUnavailable }
        try assertCurrent(review, currentPreviewFingerprint: currentPreviewFingerprint)

        let timestamp = now()
        let confirmation = try ExecutionConfirmation(validatedPlan: review.plan, at: timestamp)
        let gate: SafetyGate
        switch mode {
        case .fixtureSimulation:
            gate = SafetyGate.evaluate(
                engineAvailable: true, diskAccess: .full, plan: review.plan,
                at: timestamp, helperReady: true
            )
        case .productionDisabled:
            gate = SafetyGate.evaluate(
                engineAvailable: true, diskAccess: .full, plan: review.plan,
                at: timestamp, helperReady: false
            )
        }
        state = .confirming(review, confirmation, gate)
    }

    func confirmAndExecute(typedPhrase: String, currentPreviewFingerprint: String) throws {
        guard case .confirming(let review, let confirmation, let gate) = state else {
            throw ExecutionPresentationError.confirmationUnavailable
        }
        try assertCurrent(review, currentPreviewFingerprint: currentPreviewFingerprint)
        let timestamp = now()
        guard confirmation.isAuthorized(typedPhrase: typedPhrase, now: timestamp, gate: gate) else {
            throw ExecutionPresentationError.confirmationRejected
        }

        let operationConfirmation = try OperationConfirmation(validatedPlan: review.plan, confirmedAt: timestamp)
        let runID = UUID()
        activeRunID = runID
        state = .executing(review, .init(
            completedItems: 0, totalItems: review.itemCount,
            currentTask: mode == .fixtureSimulation ? "Preparing demo scenario…" : "Starting…",
            cancellationRequested: false
        ))
        executionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await coordinator.execute(
                    plan: review.plan,
                    confirmation: operationConfirmation
                ) { [weak self] event in
                    await self?.acceptProgress(event, for: review, runID: runID)
                }
                guard activeRunID == runID else { return }
                state = .receipt(review, receipt)
                await persistFixtureReceiptIfNeeded(receipt)
            } catch is CancellationError {
                guard activeRunID == runID else { return }
                state = .failed("The simulation was cancelled before a receipt was available.")
            } catch {
                guard activeRunID == runID else { return }
                state = .failed(Self.safeMessage(for: error))
            }
            if activeRunID == runID {
                activeRunID = nil
                executionTask = nil
            }
        }
    }

    func cancel() {
        guard case .executing(let review, let progress) = state else { return }
        state = .executing(review, .init(
            completedItems: progress.completedItems, totalItems: progress.totalItems,
            currentTask: progress.currentTask, cancellationRequested: true
        ))
        executionTask?.cancel()
    }

    /// Lets lifecycle owners and tests await the coordinator's bounded shutdown path
    /// without polling presentation state or guessing at transport timing.
    func waitForExecutionToSettle() async {
        let task = executionTask
        await task?.value
    }

    func invalidateIfPreviewChanged(to currentPreviewFingerprint: String) {
        guard let review, review.previewFingerprint != currentPreviewFingerprint else { return }
        executionTask?.cancel()
        executionTask = nil
        activeRunID = nil
        state = .stale(previousPlanFingerprint: review.plan.metadata.fingerprint)
    }

    func refreshExpiry() {
        let expirableReview: ExecutionPlanReview
        switch state {
        case .review(let review), .confirming(let review, _, _): expirableReview = review
        case .executing, .receipt, .stale, .failed: return
        }
        do {
            _ = try expirableReview.plan.validated(at: now())
        } catch {
            executionTask?.cancel()
            executionTask = nil
            activeRunID = nil
            state = .stale(previousPlanFingerprint: expirableReview.plan.metadata.fingerprint)
        }
    }

    /// View actions use this wrapper so validation failures become visible state instead
    /// of disappearing behind a `try?` at the button boundary.
    func requestConfirmation(currentPreviewFingerprint: String) {
        do {
            try beginConfirmation(currentPreviewFingerprint: currentPreviewFingerprint)
        } catch {
            transitionForActionFailure(error)
        }
    }

    func authorizeAndExecute(typedPhrase: String, currentPreviewFingerprint: String) {
        do {
            try confirmAndExecute(
                typedPhrase: typedPhrase,
                currentPreviewFingerprint: currentPreviewFingerprint
            )
        } catch {
            transitionForActionFailure(error)
        }
    }

    private func acceptProgress(
        _ event: ExecutionProgressEvent,
        for review: ExecutionPlanReview,
        runID: UUID
    ) {
        guard activeRunID == runID, case .executing(_, let progress) = state else { return }
        let completed = event.kind == .operationCompleted
            ? min(progress.totalItems, progress.completedItems + 1)
            : progress.completedItems
        let task: String
        switch event.kind {
        case .started: task = "Demo scenario started"
        case .operationStarted:
            let ordinal = review.plan.operations.firstIndex { $0.id == event.operationID }.map { $0 + 1 }
            task = ordinal.map { "Simulating item \($0) of \(review.itemCount)…" } ?? "Simulating reviewed item…"
        case .operationCompleted: task = "Completed demo step \(completed) of \(progress.totalItems)"
        case .operationFailed: task = "A demo step stopped safely"
        case .completed: task = "Demo scenario complete"
        case .failed: task = "Demo scenario stopped safely"
        }
        state = .executing(review, .init(
            completedItems: completed,
            totalItems: progress.totalItems,
            currentTask: task,
            cancellationRequested: progress.cancellationRequested
        ))
    }

    private func persistFixtureReceiptIfNeeded(_ receipt: OperationReceipt) async {
        guard mode == .fixtureSimulation, persistedReceiptID != receipt.id else { return }
        persistedReceiptID = receipt.id
        await persistReceipt?(receipt)
    }

    private func transitionForActionFailure(_ error: Error) {
        if case .stale = state { return }
        if error is ExecutionPlanValidationError, let review {
            state = .stale(previousPlanFingerprint: review.plan.metadata.fingerprint)
        } else {
            state = .failed(Self.safeMessage(for: error))
        }
    }

    private func assertCurrent(_ review: ExecutionPlanReview, currentPreviewFingerprint: String) throws {
        guard review.previewFingerprint == currentPreviewFingerprint else {
            state = .stale(previousPlanFingerprint: review.plan.metadata.fingerprint)
            throw ExecutionPresentationError.previewChanged
        }
        do {
            _ = try review.plan.validated(at: now())
        } catch {
            state = .stale(previousPlanFingerprint: review.plan.metadata.fingerprint)
            throw error
        }
    }

    private static func safeMessage(for error: Error) -> String {
        switch error {
        case OperationCoordinatorError.unavailableTransport:
            "Execution is disabled in this build. No files were changed."
        case ExecutionPlanValidationError.expired:
            "The reviewed plan expired. Build a fresh preview."
        case OperationCoordinatorError.transportTimedOut:
            "The demo scenario timed out and was stopped safely. No files were changed."
        default:
            "The simulation stopped safely. No files were changed."
        }
    }
}

@MainActor
enum FixtureExecutionPresentationFactory {
    static func clean(
        _ preview: CleanPreviewPlan,
        now: Date = Date(),
        persistReceipt: (@MainActor (OperationReceipt) async -> Void)? = nil
    ) throws -> ExecutionPresentationModel {
        let entries = preview.categories.map { ($0.id, $0.reclaimableBytes ?? 0) }
        guard !entries.isEmpty else { throw ExecutionPlanValidationError.emptyPlan }
        return try make(
            previewFingerprint: preview.metadata.fingerprint, kind: .clean,
            engineVersion: preview.metadata.engineVersion, entries: entries, now: now,
            persistReceipt: persistReceipt
        ) { index, entry in
            .init(
                id: "fixture.clean.\(index)", action: .removeFile,
                target: .init(
                    path: "/Users/burrow-fixture/Library/Caches/preview-\(index)", nodeKind: .file,
                    byteCount: entry.1, modificationTime: now, fileIdentifier: "fixture:\(entry.0)"
                ),
                reason: "Demo scenario for preview \(preview.metadata.fingerprint.prefix(8))", payload: nil
            )
        }
    }

    static func optimize(
        _ preview: OptimizePreviewPlan,
        now: Date = Date(),
        persistReceipt: (@MainActor (OperationReceipt) async -> Void)? = nil
    ) throws -> ExecutionPresentationModel {
        let tasks = preview.tasks.filter { $0.disposition == .wouldApply }
        let entries = tasks.map { ($0.id, Int64(0)) }
        guard !entries.isEmpty else { throw ExecutionPlanValidationError.emptyPlan }
        return try make(
            previewFingerprint: preview.metadata.fingerprint, kind: .optimize,
            engineVersion: preview.metadata.engineVersion, entries: entries, now: now,
            persistReceipt: persistReceipt
        ) { index, entry in
            .init(
                id: "fixture.optimize.\(index)", action: .removeFile,
                target: .init(
                    path: "/Users/burrow-fixture/Library/Preferences/preview-\(index).plist", nodeKind: .file,
                    byteCount: entry.1, modificationTime: now, fileIdentifier: "fixture:\(entry.0)"
                ),
                reason: "Demo scenario for preview \(preview.metadata.fingerprint.prefix(8))", payload: nil
            )
        }
    }

    static func uninstall(
        _ preview: UninstallPreviewPlan,
        now: Date = Date(),
        persistReceipt: (@MainActor (OperationReceipt) async -> Void)? = nil
    ) throws -> ExecutionPresentationModel {
        let entries = preview.applications.map { ($0.id, $0.sizeBytes ?? 0) }
        guard !entries.isEmpty else { throw ExecutionPlanValidationError.emptyPlan }
        return try make(
            previewFingerprint: preview.metadata.fingerprint, kind: .uninstall,
            engineVersion: preview.metadata.engineVersion, entries: entries, now: now,
            persistReceipt: persistReceipt
        ) { index, entry in
            .init(
                id: "fixture.uninstall.\(index)", action: .moveToTrash,
                target: .init(
                    path: "/Applications/Burrow Fixture \(index + 1).app", nodeKind: .directory,
                    byteCount: entry.1, modificationTime: now, fileIdentifier: "fixture:\(entry.0)"
                ),
                reason: "Demo scenario for selection \(preview.metadata.fingerprint.prefix(8))", payload: nil
            )
        }
    }

    private static func make<Entry>(
        previewFingerprint: String,
        kind: ExecutionPlanKind,
        engineVersion: String,
        entries: [Entry],
        now: Date,
        persistReceipt: (@MainActor (OperationReceipt) async -> Void)?,
        operation: (Int, Entry) -> ExecutionPlanOperation
    ) throws -> ExecutionPresentationModel {
        let operations = entries.enumerated().map(operation)
        let metadata = ExecutionPlanMetadata(
            schemaVersion: ExecutionPlanSchema.current,
            engineVersion: engineVersion.isEmpty ? "fixture" : engineVersion,
            createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(10 * 60), fingerprint: ""
        )
        let unsigned = ExecutionPlan(metadata: metadata, kind: kind, operations: operations)
        let plan = ExecutionPlan(
            metadata: .init(
                schemaVersion: metadata.schemaVersion, engineVersion: metadata.engineVersion,
                createdAt: metadata.createdAt, expiresAt: metadata.expiresAt,
                fingerprint: try unsigned.calculatedFingerprint()
            ),
            kind: kind, operations: operations
        )
        _ = try plan.validated(at: now)

        let events = fixtureEvents(for: plan, startingAt: now)
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: .init(
                schemaVersion: ExecutionPlanSchema.current, engineVersion: plan.metadata.engineVersion,
                supportedPlanKinds: [kind], progressEventSchemaVersion: ProgressEventSchema.current
            ),
            events: events, eventDelayNanoseconds: 140_000_000
        )
        let coordinator = OperationCoordinator(transport: transport)
        return ExecutionPresentationModel(
            review: .init(previewFingerprint: previewFingerprint, plan: plan),
            mode: .fixtureSimulation, coordinator: coordinator,
            persistReceipt: persistReceipt
        )
    }

    private static func fixtureEvents(for plan: ExecutionPlan, startingAt start: Date) -> [ExecutionProgressEvent] {
        var events: [ExecutionProgressEvent] = [
            .init(
                schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: 0,
                timestamp: start, kind: .started, operationID: nil, completedBytes: nil,
                message: "Demo scenario started"
            )
        ]
        var completedBytes: Int64 = 0
        for operation in plan.operations {
            events.append(.init(
                schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: events.count,
                timestamp: start.addingTimeInterval(Double(events.count) / 100), kind: .operationStarted,
                operationID: operation.id, completedBytes: nil, message: nil
            ))
            completedBytes += operation.target.byteCount
            events.append(.init(
                schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: events.count,
                timestamp: start.addingTimeInterval(Double(events.count) / 100), kind: .operationCompleted,
                operationID: operation.id, completedBytes: operation.target.byteCount, message: "Simulated"
            ))
        }
        events.append(.init(
            schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: events.count,
            timestamp: start.addingTimeInterval(Double(events.count) / 100), kind: .completed,
                operationID: nil, completedBytes: completedBytes, message: "Demo scenario complete"
        ))
        return events
    }
}
