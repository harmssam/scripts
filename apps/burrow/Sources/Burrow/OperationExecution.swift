import Foundation

/// A short-lived, UI-issued acknowledgement of the exact plan the user reviewed.
struct OperationConfirmation: Sendable, Equatable {
    let planFingerprint: String
    let operation: MaintenanceOperation
    let itemCount: Int
    let affectedBytes: Int64
    let planExpiresAt: Date
    let confirmedAt: Date
    let expiresAt: Date

    init(validatedPlan plan: ExecutionPlan, confirmedAt: Date = Date()) throws {
        let plan = try plan.validated(at: confirmedAt)
        guard let operation = MaintenanceOperation(rawValue: plan.kind.rawValue) else {
            throw OperationCoordinatorError.confirmationMismatch
        }
        let bytes = try plan.operations.reduce(Int64(0)) { total, operation in
            let (sum, overflow) = total.addingReportingOverflow(operation.target.byteCount)
            guard !overflow else { throw OperationCoordinatorError.confirmationMismatch }
            return sum
        }
        planFingerprint = plan.metadata.fingerprint
        self.operation = operation
        itemCount = plan.operations.count
        affectedBytes = bytes
        planExpiresAt = plan.metadata.expiresAt
        self.confirmedAt = confirmedAt
        expiresAt = min(plan.metadata.expiresAt, confirmedAt.addingTimeInterval(5 * 60))
    }
}

/// Deliberately narrow transport boundary. A future XPC implementation must conform to
/// this plan-in/events-out surface; it cannot accept commands or arbitrary paths.
protocol PrivilegedOperationTransport: Sendable {
    func capabilities() async -> ExecutionPlanCapabilities
    func execute(validatedPlan: ExecutionPlan) async throws -> AsyncThrowingStream<ExecutionProgressEvent, Error>
    func cancel(planFingerprint: String) async
}

enum OperationCoordinatorError: Error, Equatable, Sendable {
    case confirmationMismatch
    case invalidConfirmationLifetime
    case confirmationExpired
    case unavailableTransport
    case unsupportedPlanKind(ExecutionPlanKind)
    case incompatibleEngine(expected: String, actual: String)
    case executionAlreadyInProgress
    case incompleteTransportStream
    case transportTimedOut
}

/// The only component allowed to turn a reviewed plan into a transport request.
actor OperationCoordinator {
    private let transport: any PrivilegedOperationTransport
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private var activeFingerprint: String?

    init(
        transport: any PrivilegedOperationTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        timeout: Duration = .seconds(30)
    ) {
        self.transport = transport
        self.now = now
        self.timeout = timeout
    }

    func execute(
        plan: ExecutionPlan,
        confirmation: OperationConfirmation,
        onProgress: @escaping @Sendable (ExecutionProgressEvent) async -> Void = { _ in }
    ) async throws -> OperationReceipt {
        guard activeFingerprint == nil else { throw OperationCoordinatorError.executionAlreadyInProgress }

        let authorizationTime = now()
        let validatedPlan = try plan.validated(at: authorizationTime)
        try Self.validate(confirmation, for: validatedPlan, at: authorizationTime)
        // Reserve before the first suspension point. Actor reentrancy must not allow a
        // second request through while capabilities are being negotiated.
        activeFingerprint = validatedPlan.metadata.fingerprint
        defer { activeFingerprint = nil }

        try await validateCapabilities(for: validatedPlan)
        try Task.checkCancellation()
        let executionStartedAt = now()
        // Capabilities are an asynchronous trust boundary. Revalidate the plan and
        // confirmation immediately before handing either to a transport.
        let immediatelyValidatedPlan = try validatedPlan.validated(at: executionStartedAt)
        try Self.validate(confirmation, for: immediatelyValidatedPlan, at: executionStartedAt)

        // Keep consumption in a separately cancellable task. If the caller cancels,
        // forward that signal immediately and then collect consume()'s bounded receipt;
        // otherwise a task-group cancellation can race the receipt and surface a bare
        // CancellationError to the presentation layer.
        let consumption = Task {
            try await self.consume(
                plan: immediatelyValidatedPlan,
                startedAt: executionStartedAt,
                onProgress: onProgress
            )
        }
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: OperationReceipt.self) { group in
                    group.addTask { try await consumption.value }
                    group.addTask {
                        try await Task.sleep(for: self.timeout)
                        consumption.cancel()
                        throw OperationCoordinatorError.transportTimedOut
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw OperationCoordinatorError.incompleteTransportStream
                    }
                    return result
                }
            } catch is CancellationError {
                consumption.cancel()
                return try await consumption.value
            }
        } onCancel: {
            consumption.cancel()
        }
    }

    private func consume(
        plan immediatelyValidatedPlan: ExecutionPlan,
        startedAt executionStartedAt: Date,
        onProgress: @escaping @Sendable (ExecutionProgressEvent) async -> Void
    ) async throws -> OperationReceipt {
        var events: [ExecutionProgressEvent] = []
        var wasCancelled = false
        do {
            try await withTaskCancellationHandler {
                let stream = try await transport.execute(validatedPlan: immediatelyValidatedPlan)
                for try await event in stream {
                    try ProgressEventContract.validatePrefix(event, preceding: events, for: immediatelyValidatedPlan)
                    events.append(event)
                    await onProgress(event)
                }
            } onCancel: {
                Task { await self.transport.cancel(planFingerprint: immediatelyValidatedPlan.metadata.fingerprint) }
            }
        } catch is CancellationError {
            wasCancelled = true
        }

        let hasTerminalEvent = events.last.map { $0.kind == .completed || $0.kind == .failed } ?? false
        if Task.isCancelled && !hasTerminalEvent { wasCancelled = true }
        if wasCancelled {
            // The cancellation handler cannot await. Make delivery deterministic before
            // returning a receipt; transports must treat duplicate cancellation as safe.
            await transport.cancel(planFingerprint: immediatelyValidatedPlan.metadata.fingerprint)
            return Self.receipt(
                for: immediatelyValidatedPlan, events: events, outcome: .cancelled,
                startedAt: executionStartedAt, finishedAt: now()
            )
        }

        guard let terminal = events.last, terminal.kind == .completed || terminal.kind == .failed else {
            throw OperationCoordinatorError.incompleteTransportStream
        }
        _ = try ProgressEventContract.validate(events, for: immediatelyValidatedPlan)
        let outcome: ExecutionOutcome
        if terminal.kind == .completed {
            outcome = .completed
        } else if events.contains(where: { $0.kind == .operationCompleted }) {
            outcome = .partiallyCompleted
        } else {
            outcome = .failed
        }
        return Self.receipt(
            for: immediatelyValidatedPlan, events: events, outcome: outcome,
            startedAt: executionStartedAt, finishedAt: now()
        )
    }

    private static func validate(_ confirmation: OperationConfirmation, for plan: ExecutionPlan, at now: Date) throws {
        guard confirmation.planFingerprint == plan.metadata.fingerprint else {
            throw OperationCoordinatorError.confirmationMismatch
        }
        let affectedBytes = try plan.operations.reduce(Int64(0)) { total, operation in
            let (sum, overflow) = total.addingReportingOverflow(operation.target.byteCount)
            guard !overflow else { throw OperationCoordinatorError.confirmationMismatch }
            return sum
        }
        guard confirmation.operation.rawValue == plan.kind.rawValue,
              confirmation.itemCount == plan.operations.count,
              confirmation.affectedBytes == affectedBytes,
              confirmation.planExpiresAt == plan.metadata.expiresAt else {
            throw OperationCoordinatorError.confirmationMismatch
        }
        guard confirmation.confirmedAt >= plan.metadata.createdAt,
              confirmation.confirmedAt <= now,
              confirmation.confirmedAt < confirmation.expiresAt,
              confirmation.expiresAt <= plan.metadata.expiresAt,
              confirmation.expiresAt.timeIntervalSince(confirmation.confirmedAt) <= 5 * 60 else {
            throw OperationCoordinatorError.invalidConfirmationLifetime
        }
        guard now < confirmation.expiresAt else { throw OperationCoordinatorError.confirmationExpired }
    }

    private func validateCapabilities(for plan: ExecutionPlan) async throws {
        let capabilities = await transport.capabilities()
        guard capabilities.supportsStructuredPlans else { throw OperationCoordinatorError.unavailableTransport }
        guard capabilities.supportedPlanKinds.contains(plan.kind) else {
            throw OperationCoordinatorError.unsupportedPlanKind(plan.kind)
        }
        guard capabilities.engineVersion == plan.metadata.engineVersion else {
            throw OperationCoordinatorError.incompatibleEngine(
                expected: plan.metadata.engineVersion, actual: capabilities.engineVersion
            )
        }
    }

    private static func receipt(
        for plan: ExecutionPlan,
        events: [ExecutionProgressEvent],
        outcome: ExecutionOutcome,
        startedAt: Date,
        finishedAt: Date
    ) -> OperationReceipt {
        var started = Set<String>()
        var terminalEvents: [String: ExecutionProgressEvent] = [:]
        for event in events {
            guard let id = event.operationID else { continue }
            if event.kind == .operationStarted { started.insert(id) }
            if event.kind == .operationCompleted || event.kind == .operationFailed { terminalEvents[id] = event }
        }

        let items = plan.operations.map { operation -> OperationReceipt.Item in
            let ordinal = (plan.operations.firstIndex(where: { $0.id == operation.id }) ?? 0) + 1
            let safeTitle = "\(maintenanceOperation(for: plan.kind).title) item \(ordinal)"
            if let event = terminalEvents[operation.id] {
                return .init(
                    title: safeTitle,
                    detail: event.kind == .operationCompleted ? "Completed" : "Stopped because the target no longer matched the reviewed plan.",
                    status: event.kind == .operationCompleted ? .completed : .failed
                )
            }
            return .init(
                title: safeTitle,
                detail: started.contains(operation.id) ? "Interrupted before completion" : "Not started",
                status: .skipped
            )
        }
        return .init(
            operation: maintenanceOperation(for: plan.kind),
            planFingerprint: plan.metadata.fingerprint,
            startedAt: startedAt,
            finishedAt: max(finishedAt, startedAt),
            outcome: outcome,
            completedBytes: events.filter { $0.kind == .operationCompleted }.compactMap(\.completedBytes).reduce(0, +),
            items: items
        )
    }

    private static func maintenanceOperation(for kind: ExecutionPlanKind) -> MaintenanceOperation {
        switch kind {
        case .clean: .clean
        case .optimize: .optimize
        case .uninstall: .uninstall
        }
    }
}
