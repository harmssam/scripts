import Darwin
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
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        for operation in plan.operations { try apply(operation, rootFD: rootFD) }
        return progressEvents(for: plan)
    }

    private func openRoot() throws -> Int32 {
        let path = rootURL.resolvingSymlinksInPath().path
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw HelperAuthorizationError.unsafePathResolution }
        return fd
    }

    private func apply(_ operation: ExecutionPlanOperation, rootFD: Int32) throws {
        switch operation.action {
        case .replaceFile: throw HelperAuthorizationError.invalidPlan
        case .removeFile, .removeDirectory, .moveToTrash: break
        }
        let components = try relativeComponents(path: operation.target.path)
        var dirFD = rootFD
        var opened: [Int32] = []
        defer { for fd in opened.reversed() { Darwin.close(fd) } }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(dirFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw HelperAuthorizationError.unsafePathResolution }
            opened.append(next)
            dirFD = next
        }
        try unlinkLast(parentFD: dirFD, name: components[components.count - 1], action: operation.action)
    }

    private func unlinkLast(parentFD: Int32, name: String, action: ExecutionAction) throws {
        let openFlags: Int32
        let unlinkFlags: Int32
        switch action {
        case .removeFile, .moveToTrash:
            openFlags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            unlinkFlags = 0
        case .removeDirectory:
            openFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            unlinkFlags = AT_REMOVEDIR
        case .replaceFile:
            throw HelperAuthorizationError.invalidPlan
        }

        let fd = name.withCString { Darwin.openat(parentFD, $0, openFlags) }
        if fd < 0 {
            if errno == ELOOP { throw HelperAuthorizationError.unsafePathResolution }
            throw HelperAuthorizationError.targetChanged
        }
        defer { Darwin.close(fd) }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw HelperAuthorizationError.targetChanged }
        let type = st.st_mode & S_IFMT
        switch action {
        case .removeFile, .moveToTrash:
            guard type == S_IFREG else { throw HelperAuthorizationError.targetChanged }
        case .removeDirectory:
            guard type == S_IFDIR else { throw HelperAuthorizationError.targetChanged }
        case .replaceFile:
            throw HelperAuthorizationError.invalidPlan
        }

        // Tests-only: trash is unlinkat in-tree; trashItem would leave the fixture root.
        let result = name.withCString { Darwin.unlinkat(parentFD, $0, unlinkFlags) }
        if result != 0 {
            if unlinkFlags == AT_REMOVEDIR, errno == ENOTEMPTY || errno == EEXIST {
                throw HelperAuthorizationError.directoryNotEmpty
            }
            throw HelperAuthorizationError.targetChanged
        }
    }

    private func relativeComponents(path: String) throws -> [String] {
        guard path.first == "/", !path.split(separator: "/").contains("..") else {
            throw HelperAuthorizationError.unsafePathResolution
        }
        let standardized = (path as NSString).standardizingPath
        let roots = [
            (rootURL.path as NSString).standardizingPath,
            (rootURL.resolvingSymlinksInPath().path as NSString).standardizingPath
        ]
        guard let root = roots.first(where: { isStrictlyInside(standardized, root: $0) }) else {
            throw HelperAuthorizationError.unsafePathResolution
        }
        let relative = String(standardized.dropFirst(root.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw HelperAuthorizationError.unsafePathResolution
        }
        return components
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
