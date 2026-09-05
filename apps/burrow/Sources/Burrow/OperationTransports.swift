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

/// Tests-only. Mutates files only under the injected root; the shipping app must not construct this.
actor FixtureRootOperationTransport: PrivilegedOperationTransport {
    private let rootURL: URL
    private var cancelledFingerprints = Set<String>()

    init(rootURL: URL) { self.rootURL = rootURL }

    func capabilities() async -> ExecutionPlanCapabilities {
        .init(
            schemaVersion: ExecutionPlanSchema.current,
            engineVersion: "fixture-root",
            supportedPlanKinds: Set(ExecutionPlanKind.allCases),
            progressEventSchemaVersion: ProgressEventSchema.current
        )
    }

    func execute(validatedPlan: ExecutionPlan) async throws -> AsyncThrowingStream<ExecutionProgressEvent, Error> {
        if cancelledFingerprints.contains(validatedPlan.metadata.fingerprint) { throw CancellationError() }
        let events = try run(validatedPlan)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(planFingerprint: String) async { cancelledFingerprints.insert(planFingerprint) }

    private func run(_ plan: ExecutionPlan) throws -> [ExecutionProgressEvent] {
        let targets = try plan.operations.map { operation in
            (operation, try containedURL(for: operation.target.path, action: operation.action))
        }
        for (operation, url) in targets { try apply(operation, at: url) }
        return progressEvents(for: plan)
    }

    private func containedURL(for path: String, action: ExecutionAction) throws -> URL {
        switch action {
        case .removeFile, .removeDirectory, .moveToTrash: break
        case .replaceFile: throw HelperAuthorizationError.invalidPlan
        }
        guard path.first == "/", !path.split(separator: "/").contains("..") else {
            throw HelperAuthorizationError.unsafePathResolution
        }
        let standardizedRoot = (rootURL.path as NSString).standardizingPath
        let standardizedPath = (path as NSString).standardizingPath
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard isStrictlyInside(standardizedPath, root: standardizedRoot),
              isStrictlyInside(resolvedPath.path, root: resolvedRoot.path),
              isStrictlyInside((resolvedPath.path as NSString).standardizingPath, root: (resolvedRoot.path as NSString).standardizingPath)
        else {
            throw HelperAuthorizationError.unsafePathResolution
        }
        return URL(fileURLWithPath: standardizedPath)
    }

    private func apply(_ operation: ExecutionPlanOperation, at url: URL) throws {
        switch operation.action {
        case .removeFile, .moveToTrash:
            do { try FileManager.default.removeItem(at: url) }
            catch { throw HelperAuthorizationError.targetChanged }
        case .removeDirectory:
            let entries: [String]
            do { entries = try FileManager.default.contentsOfDirectory(atPath: url.path) }
            catch { throw HelperAuthorizationError.targetChanged }
            guard entries.isEmpty else { throw HelperAuthorizationError.directoryNotEmpty }
            do { try FileManager.default.removeItem(at: url) }
            catch { throw HelperAuthorizationError.targetChanged }
        case .replaceFile:
            throw HelperAuthorizationError.invalidPlan
        }
    }

    private func progressEvents(for plan: ExecutionPlan) -> [ExecutionProgressEvent] {
        let start = Date()
        var events: [ExecutionProgressEvent] = [
            .init(
                schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: 0,
                timestamp: start, kind: .started, operationID: nil, completedBytes: nil,
                message: "Execution started"
            )
        ]
        var completedBytes: Int64 = 0
        for operation in plan.operations {
            events.append(.init(
                schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: events.count,
                timestamp: start.addingTimeInterval(Double(events.count)), kind: .operationStarted,
                operationID: operation.id, completedBytes: nil, message: nil
            ))
            completedBytes += operation.target.byteCount
            events.append(.init(
                schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: events.count,
                timestamp: start.addingTimeInterval(Double(events.count)), kind: .operationCompleted,
                operationID: operation.id, completedBytes: operation.target.byteCount, message: nil
            ))
        }
        events.append(.init(
            schemaVersion: ProgressEventSchema.current, planFingerprint: plan.id, sequence: events.count,
            timestamp: start.addingTimeInterval(Double(events.count)), kind: .completed,
            operationID: nil, completedBytes: completedBytes, message: "Execution complete"
        ))
        return events
    }

    private func isStrictlyInside(_ path: String, root: String) -> Bool {
        guard path.hasPrefix(root), path.count > root.count else { return false }
        return path[path.index(path.startIndex, offsetBy: root.count)] == "/"
    }
}
