import Foundation
import Testing
@testable import Burrow

@Suite("Plan-bound operation coordinator")
struct OperationCoordinatorTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A matching confirmation and capability produce a completed receipt")
    func successfulReceipt() async throws {
        let plan = try makePlan()
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: capabilities(for: plan), events: completedEvents(for: plan)
        )
        let coordinator = OperationCoordinator(transport: transport, now: { base.addingTimeInterval(60) })

        let receipt = try await coordinator.execute(plan: plan, confirmation: confirmation(for: plan))

        #expect(receipt.outcome == .completed)
        #expect(receipt.planFingerprint == plan.metadata.fingerprint)
        #expect(receipt.items.map(\.status) == [.completed, .completed])
        #expect(receipt.completedBytes == 300)
        #expect(await transport.receivedFingerprints == [plan.metadata.fingerprint])
    }

    @Test("Confirmation fingerprint, lifetime, and expiry fail before transport execution")
    func confirmationGates() async throws {
        let plan = try makePlan()
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: capabilities(for: plan), events: completedEvents(for: plan)
        )
        let otherPlan = try makePlan(operationCount: 1)

        await #expect(throws: OperationCoordinatorError.confirmationMismatch) {
            try await OperationCoordinator(transport: transport, now: { base.addingTimeInterval(60) }).execute(
                plan: plan, confirmation: confirmation(for: otherPlan)
            )
        }
        await #expect(throws: OperationCoordinatorError.invalidConfirmationLifetime) {
            try await OperationCoordinator(transport: transport, now: { base.addingTimeInterval(-1) }).execute(
                plan: plan, confirmation: confirmation(for: plan)
            )
        }
        await #expect(throws: OperationCoordinatorError.confirmationExpired) {
            try await OperationCoordinator(transport: transport, now: { base.addingTimeInterval(301) }).execute(
                plan: plan, confirmation: confirmation(for: plan)
            )
        }
        #expect(await transport.receivedFingerprints.isEmpty)
    }

    @Test("Unavailable, unsupported, and engine-mismatched transports fail closed")
    func capabilityGates() async throws {
        let plan = try makePlan()
        let confirmation = confirmation(for: plan)
        let now = { @Sendable in self.base.addingTimeInterval(60) }

        await #expect(throws: OperationCoordinatorError.unavailableTransport) {
            try await OperationCoordinator(
                transport: DisabledPrivilegedOperationTransport(engineVersion: plan.metadata.engineVersion), now: now
            ).execute(plan: plan, confirmation: confirmation)
        }

        let unsupported = InMemoryPrivilegedOperationTransport(
            capabilities: .init(
                schemaVersion: 1, engineVersion: plan.metadata.engineVersion,
                supportedPlanKinds: [.optimize], progressEventSchemaVersion: 1
            ), events: []
        )
        await #expect(throws: OperationCoordinatorError.unsupportedPlanKind(.clean)) {
            try await OperationCoordinator(transport: unsupported, now: now).execute(plan: plan, confirmation: confirmation)
        }

        let mismatch = InMemoryPrivilegedOperationTransport(
            capabilities: .init(
                schemaVersion: 1, engineVersion: "other", supportedPlanKinds: [.clean], progressEventSchemaVersion: 1
            ), events: []
        )
        await #expect(throws: OperationCoordinatorError.incompatibleEngine(expected: "1.53.0", actual: "other")) {
            try await OperationCoordinator(transport: mismatch, now: now).execute(plan: plan, confirmation: confirmation)
        }
    }

    @Test("A valid failed stream records completed, failed, and untouched work")
    func partialFailureReceipt() async throws {
        let plan = try makePlan(operationCount: 3)
        let events = [
            event(plan, 0, .started),
            event(plan, 1, .operationStarted, operation: 0),
            event(plan, 2, .operationCompleted, operation: 0, bytes: 100),
            event(plan, 3, .operationStarted, operation: 1),
            event(plan, 4, .operationFailed, operation: 1, message: "Identity changed: \(plan.operations[1].target.path)"),
            event(plan, 5, .failed, bytes: 100, message: "Stopped safely")
        ]
        let transport = InMemoryPrivilegedOperationTransport(capabilities: capabilities(for: plan), events: events)
        let receipt = try await OperationCoordinator(
            transport: transport, now: { base.addingTimeInterval(60) }
        ).execute(plan: plan, confirmation: confirmation(for: plan))

        #expect(receipt.outcome == .partiallyCompleted)
        #expect(receipt.items.map(\.status) == [.completed, .failed, .skipped])
        #expect(receipt.items[1].detail == "Stopped because the target no longer matched the reviewed plan.")
        #expect(!receipt.items[1].detail.contains(plan.operations[1].target.path))
    }

    @Test("Cancellation is forwarded and returns a deterministic bounded receipt")
    func cancellationReceipt() async throws {
        let plan = try makePlan()
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: capabilities(for: plan),
            events: completedEvents(for: plan),
            eventDelayNanoseconds: 5_000_000_000
        )
        let coordinator = OperationCoordinator(transport: transport, now: { base.addingTimeInterval(60) })
        let task = Task { try await coordinator.execute(plan: plan, confirmation: confirmation(for: plan)) }

        while await transport.receivedFingerprints.isEmpty { await Task.yield() }
        task.cancel()
        let receipt = try await task.value

        #expect(receipt.outcome == .cancelled)
        #expect(receipt.items.allSatisfy { $0.status == .skipped })
        #expect(receipt.items.allSatisfy { $0.detail == "Not started" })
        #expect(await transport.didReceiveCancellation(for: plan.id))
    }

    @Test("Invalid progress never produces a receipt")
    func invalidProgressFailsClosed() async throws {
        let plan = try makePlan()
        let invalid = [event(plan, 0, .started), event(plan, 2, .operationStarted, operation: 0)]
        let transport = InMemoryPrivilegedOperationTransport(capabilities: capabilities(for: plan), events: invalid)
        await #expect(throws: ProgressEventValidationError.invalidSequence(expected: 1, actual: 2)) {
            try await OperationCoordinator(
                transport: transport, now: { base.addingTimeInterval(60) }
            ).execute(plan: plan, confirmation: confirmation(for: plan))
        }
    }

    @Test("Execution slot is reserved before asynchronous capability negotiation")
    func concurrentExecutionFailsClosed() async throws {
        let plan = try makePlan()
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: capabilities(for: plan), events: completedEvents(for: plan),
            capabilityDelayNanoseconds: 60_000_000
        )
        let coordinator = OperationCoordinator(transport: transport, now: { self.base.addingTimeInterval(60) })
        let first = Task { try await coordinator.execute(plan: plan, confirmation: confirmation(for: plan)) }
        try await Task.sleep(nanoseconds: 10_000_000)

        await #expect(throws: OperationCoordinatorError.executionAlreadyInProgress) {
            try await coordinator.execute(plan: plan, confirmation: confirmation(for: plan))
        }
        _ = try await first.value
        #expect(await transport.receivedFingerprints.count == 1)
    }

    @Test("Plan is revalidated after capability negotiation and before transport")
    func revalidatesAtTransportBoundary() async throws {
        let plan = try makePlan()
        let clock = TestClock([
            base.addingTimeInterval(60),
            plan.metadata.expiresAt,
        ])
        let transport = InMemoryPrivilegedOperationTransport(
            capabilities: capabilities(for: plan), events: completedEvents(for: plan)
        )

        await #expect(throws: ExecutionPlanValidationError.expired) {
            try await OperationCoordinator(transport: transport, now: { clock.next() }).execute(
                plan: plan, confirmation: confirmation(for: plan)
            )
        }
        #expect(await transport.receivedFingerprints.isEmpty)
    }

    private func makePlan(operationCount: Int = 2) throws -> ExecutionPlan {
        let operations = (0..<operationCount).map { index in
            ExecutionPlanOperation(
                id: "operation.\(index)", action: .removeFile,
                target: .init(
                    path: "/Users/test/Library/Caches/item-\(index)", nodeKind: .file,
                    byteCount: Int64((index + 1) * 100), modificationTime: base, fileIdentifier: "id-\(index)"
                ),
                reason: "Fixture", payload: nil
            )
        }
        let unsigned = ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: "1.53.0", createdAt: base,
                expiresAt: base.addingTimeInterval(600), fingerprint: ""
            ),
            kind: .clean, operations: operations
        )
        return .init(
            metadata: .init(
                schemaVersion: 1, engineVersion: "1.53.0", createdAt: base,
                expiresAt: base.addingTimeInterval(600), fingerprint: try unsigned.calculatedFingerprint()
            ),
            kind: .clean, operations: operations
        )
    }

    private func confirmation(for plan: ExecutionPlan) -> OperationConfirmation {
        try! .init(validatedPlan: plan, confirmedAt: base)
    }

    private func capabilities(for plan: ExecutionPlan) -> ExecutionPlanCapabilities {
        .init(
            schemaVersion: 1, engineVersion: plan.metadata.engineVersion,
            supportedPlanKinds: [.clean], progressEventSchemaVersion: 1
        )
    }

    private func completedEvents(for plan: ExecutionPlan) -> [ExecutionProgressEvent] {
        [
            event(plan, 0, .started),
            event(plan, 1, .operationStarted, operation: 0),
            event(plan, 2, .operationCompleted, operation: 0, bytes: 100),
            event(plan, 3, .operationStarted, operation: 1),
            event(plan, 4, .operationCompleted, operation: 1, bytes: 200),
            event(plan, 5, .completed, bytes: 300, message: "Done")
        ]
    }

    private func event(
        _ plan: ExecutionPlan,
        _ sequence: Int,
        _ kind: ExecutionProgressEventKind,
        operation index: Int? = nil,
        bytes: Int64? = nil,
        message: String? = nil
    ) -> ExecutionProgressEvent {
        .init(
            schemaVersion: 1, planFingerprint: plan.id, sequence: sequence,
            timestamp: base.addingTimeInterval(Double(sequence)), kind: kind,
            operationID: index.map { plan.operations[$0].id }, completedBytes: bytes, message: message
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    private var last: Date

    init(_ values: [Date]) {
        self.values = values
        last = values.last ?? .distantPast
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return last }
        last = values.removeFirst()
        return last
    }
}
