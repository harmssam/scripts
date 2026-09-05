import Foundation
import Testing
@testable import Burrow

@Suite("Fixture-only execution presentation")
@MainActor
struct ExecutionPresentationTests {
    @Test("A preview fingerprint is carried into the exact review and confirmation")
    func previewBinding() throws {
        let preview = PreviewFallbacks.clean(reason: "Fixture")
        let model = try FixtureExecutionPresentationFactory.clean(preview)

        #expect(model.mode == .fixtureSimulation)
        let review = try #require(model.review)
        #expect(review.previewFingerprint == preview.metadata.fingerprint)
        #expect(review.plan.metadata.fingerprint != preview.metadata.fingerprint)

        try model.beginConfirmation(currentPreviewFingerprint: preview.metadata.fingerprint)
        guard case .confirming(let confirmingReview, let confirmation, let gate) = model.state else {
            Issue.record("Expected confirmation state")
            return
        }
        #expect(confirmingReview == review)
        #expect(confirmation.planFingerprint == review.plan.metadata.fingerprint)
        #expect(gate.canExecute)
    }

    @Test("A changed preview fails closed into a stale-plan state")
    func changedPreviewIsStale() throws {
        let preview = PreviewFallbacks.optimize(reason: "Fixture")
        let model = try FixtureExecutionPresentationFactory.optimize(preview)
        let originalPlanFingerprint = try #require(model.review?.plan.metadata.fingerprint)

        #expect(throws: ExecutionPresentationError.previewChanged) {
            try model.beginConfirmation(currentPreviewFingerprint: "replacement-preview")
        }
        guard case .stale(let fingerprint) = model.state else {
            Issue.record("Expected stale state")
            return
        }
        #expect(fingerprint == originalPlanFingerprint)
    }

    @Test("An expired plan becomes stale before confirmation")
    func expiredPlanIsStale() throws {
        let clock = LockedPresentationClock(Date())
        let preview = PreviewFallbacks.clean(reason: "Fixture")
        let fixture = try FixtureExecutionPresentationFactory.clean(preview, now: clock.value)
        let review = try #require(fixture.review)
        let model = ExecutionPresentationModel(
            review: review, mode: .productionDisabled,
            coordinator: OperationCoordinator(
                transport: DisabledPrivilegedOperationTransport(engineVersion: review.plan.metadata.engineVersion),
                now: { clock.value }
            ),
            now: { clock.value }
        )
        clock.value = review.plan.metadata.expiresAt

        #expect(throws: ExecutionPlanValidationError.expired) {
            try model.beginConfirmation(currentPreviewFingerprint: preview.metadata.fingerprint)
        }
        guard case .stale = model.state else { Issue.record("Expected stale state"); return }
    }

    @Test("Production-disabled presentation cannot authorize execution")
    func productionRemainsDisabled() throws {
        let preview = PreviewFallbacks.clean(reason: "Fixture")
        let fixture = try FixtureExecutionPresentationFactory.clean(preview)
        let review = try #require(fixture.review)
        let model = ExecutionPresentationModel(
            review: review, mode: .productionDisabled,
            coordinator: OperationCoordinator(
                transport: DisabledPrivilegedOperationTransport(engineVersion: review.plan.metadata.engineVersion)
            )
        )

        try model.beginConfirmation(currentPreviewFingerprint: preview.metadata.fingerprint)
        guard case .confirming(_, let confirmation, let gate) = model.state else {
            Issue.record("Expected confirmation state")
            return
        }
        #expect(!gate.canExecute)
        #expect(throws: ExecutionPresentationError.confirmationRejected) {
            try model.confirmAndExecute(
                typedPhrase: confirmation.requiredPhrase,
                currentPreviewFingerprint: preview.metadata.fingerprint
            )
        }
    }

    @Test("Cancelling a running fixture produces a bounded cancellation result")
    func cancellation() async throws {
        let preview = PreviewFallbacks.clean(reason: "Fixture")
        let fixture = try FixtureExecutionPresentationFactory.clean(preview)
        let review = try #require(fixture.review)
        let transport = SuspendedPresentationTransport(
            capabilities: .init(
                schemaVersion: ExecutionPlanSchema.current,
                engineVersion: review.plan.metadata.engineVersion,
                supportedPlanKinds: [review.plan.kind],
                progressEventSchemaVersion: ProgressEventSchema.current
            )
        )
        let model = ExecutionPresentationModel(
            review: review,
            mode: .fixtureSimulation,
            coordinator: OperationCoordinator(transport: transport, timeout: .seconds(1))
        )
        try model.beginConfirmation(currentPreviewFingerprint: preview.metadata.fingerprint)
        guard case .confirming(_, let confirmation, _) = model.state else {
            Issue.record("Expected confirmation state")
            return
        }
        try model.confirmAndExecute(
            typedPhrase: confirmation.requiredPhrase,
            currentPreviewFingerprint: preview.metadata.fingerprint
        )
        while !(await transport.hasStarted) { await Task.yield() }
        model.cancel()
        await model.waitForExecutionToSettle()

        guard case .receipt(_, let receipt) = model.state else {
            Issue.record("Expected a cancellation receipt")
            return
        }
        #expect(receipt.outcome == .cancelled)
        #expect(await transport.receivedCancellation)
    }

    @Test("Timer refresh expires a reviewed or confirming plan into stale state")
    func refreshExpiry() throws {
        let clock = LockedPresentationClock(Date())
        let preview = PreviewFallbacks.clean(reason: "Fixture")
        let fixture = try FixtureExecutionPresentationFactory.clean(preview, now: clock.value)
        let review = try #require(fixture.review)
        let model = ExecutionPresentationModel(
            review: review, mode: .productionDisabled,
            coordinator: OperationCoordinator(
                transport: DisabledPrivilegedOperationTransport(engineVersion: review.plan.metadata.engineVersion),
                now: { clock.value }
            ),
            now: { clock.value }
        )

        clock.value = review.plan.metadata.expiresAt
        model.refreshExpiry()
        guard case .stale(let fingerprint) = model.state else {
            Issue.record("Expected stale state")
            return
        }
        #expect(fingerprint == review.plan.metadata.fingerprint)
    }

    @Test("Factories reject demo runs that contain no actionable item")
    func zeroActionPlanIsRejected() {
        let metadata = PreviewPlanMetadata(
            schemaVersion: PreviewPlanSchema.current,
            fingerprint: PreviewFingerprint.make(kind: "optimize", engineVersion: "demo", components: []),
            engineVersion: "demo", source: .demoFallback, warnings: []
        )
        let preview = OptimizePreviewPlan(metadata: metadata, tasks: [], applyCount: 0)

        #expect(throws: ExecutionPlanValidationError.emptyPlan) {
            try FixtureExecutionPresentationFactory.optimize(preview)
        }
    }

    @Test("Malformed live progress fails before presentation accepts it")
    func malformedProgressFailsClosed() async throws {
        let preview = PreviewFallbacks.clean(reason: "Fixture")
        let fixture = try FixtureExecutionPresentationFactory.clean(preview)
        let review = try #require(fixture.review)
        let invalidFirstEvent = ExecutionProgressEvent(
            schemaVersion: ProgressEventSchema.current,
            planFingerprint: review.plan.id,
            sequence: 0,
            timestamp: review.plan.metadata.createdAt,
            kind: .operationStarted,
            operationID: review.plan.operations[0].id,
            completedBytes: nil,
            message: "untrusted path: /private/example"
        )
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: .init(
                schemaVersion: ExecutionPlanSchema.current,
                engineVersion: review.plan.metadata.engineVersion,
                supportedPlanKinds: [review.plan.kind],
                progressEventSchemaVersion: ProgressEventSchema.current
            ),
            events: [invalidFirstEvent]
        )
        let model = ExecutionPresentationModel(
            review: review,
            mode: .fixtureSimulation,
            coordinator: OperationCoordinator(transport: transport)
        )

        try model.beginConfirmation(currentPreviewFingerprint: preview.metadata.fingerprint)
        guard case .confirming(_, let confirmation, _) = model.state else {
            Issue.record("Expected confirmation state")
            return
        }
        try model.confirmAndExecute(
            typedPhrase: confirmation.requiredPhrase,
            currentPreviewFingerprint: preview.metadata.fingerprint
        )
        await model.waitForExecutionToSettle()

        guard case .failed(let message) = model.state else {
            Issue.record("Expected safe failure state")
            return
        }
        #expect(message == "The simulation stopped safely. No files were changed.")
        #expect(!message.contains("/private/example"))
    }
}

private actor SuspendedPresentationTransport: PrivilegedOperationTransport {
    private let advertisedCapabilities: ExecutionPlanCapabilities
    private var continuation: AsyncThrowingStream<ExecutionProgressEvent, Error>.Continuation?
    private(set) var hasStarted = false
    private(set) var receivedCancellation = false

    init(capabilities: ExecutionPlanCapabilities) { advertisedCapabilities = capabilities }

    func capabilities() async -> ExecutionPlanCapabilities { advertisedCapabilities }

    func execute(validatedPlan: ExecutionPlan) async throws -> AsyncThrowingStream<ExecutionProgressEvent, Error> {
        hasStarted = true
        let pair = AsyncThrowingStream<ExecutionProgressEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func cancel(planFingerprint: String) async {
        receivedCancellation = true
        continuation?.finish(throwing: CancellationError())
        continuation = nil
    }
}

private final class LockedPresentationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }

    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
