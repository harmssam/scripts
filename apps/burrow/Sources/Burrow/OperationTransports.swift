import Foundation

/// Production default until a separately signed and audited helper exists.
struct DisabledPrivilegedOperationTransport: PrivilegedOperationTransport {
    let engineVersion: String

    init(engineVersion: String = "unavailable") { self.engineVersion = engineVersion }

    func capabilities() async -> ExecutionPlanCapabilities { .unavailable(engineVersion: engineVersion) }

    func execute(validatedPlan: ExecutionPlan) async throws -> AsyncThrowingStream<ExecutionProgressEvent, Error> {
        throw OperationCoordinatorError.unavailableTransport
    }

    func cancel(planFingerprint: String) async {}
}

/// Test/demo transport. It only replays supplied contract events and never accesses the filesystem.
actor InMemoryPrivilegedOperationTransport: PrivilegedOperationTransport {
    private let advertisedCapabilities: ExecutionPlanCapabilities
    private let events: [ExecutionProgressEvent]
    private let capabilityDelayNanoseconds: UInt64
    private let eventDelayNanoseconds: UInt64
    private var cancelledFingerprints = Set<String>()
    private(set) var receivedFingerprints: [String] = []

    init(
        capabilities: ExecutionPlanCapabilities,
        events: [ExecutionProgressEvent],
        capabilityDelayNanoseconds: UInt64 = 0,
        eventDelayNanoseconds: UInt64 = 0
    ) {
        advertisedCapabilities = capabilities
        self.events = events
        self.capabilityDelayNanoseconds = capabilityDelayNanoseconds
        self.eventDelayNanoseconds = eventDelayNanoseconds
    }

    func capabilities() async -> ExecutionPlanCapabilities {
        if capabilityDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: capabilityDelayNanoseconds)
        }
        return advertisedCapabilities
    }

    func execute(validatedPlan: ExecutionPlan) async throws -> AsyncThrowingStream<ExecutionProgressEvent, Error> {
        receivedFingerprints.append(validatedPlan.metadata.fingerprint)
        let fingerprint = validatedPlan.metadata.fingerprint
        let fixtureEvents = events
        let delay = eventDelayNanoseconds
        return AsyncThrowingStream { continuation in
            let producer = Task.detached { [weak self] in
                do {
                    for event in fixtureEvents {
                        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                        guard let self, !(await self.isCancelled(fingerprint)) else {
                            throw CancellationError()
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func cancel(planFingerprint: String) async { cancelledFingerprints.insert(planFingerprint) }

    func didReceiveCancellation(for fingerprint: String) -> Bool { cancelledFingerprints.contains(fingerprint) }

    private func isCancelled(_ fingerprint: String) -> Bool { cancelledFingerprints.contains(fingerprint) }
}
