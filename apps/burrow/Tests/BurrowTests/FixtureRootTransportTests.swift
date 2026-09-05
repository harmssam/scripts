import Foundation
import Testing
@testable import Burrow

@Suite("Fixture-root operation transport")
struct FixtureRootTransportTests {
    @Test("An allowed delete under the injected root succeeds")
    func allowedDelete() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("item.cache")
        let payload = Data("hello".utf8)
        try payload.write(to: file)
        let plan = try makePlan(path: file.path, byteCount: Int64(payload.count))
        let transport = FixtureRootOperationTransport(rootURL: root)

        let events = try await collect(transport.execute(validatedPlan: plan))

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(events.map(\.kind) == [.started, .operationStarted, .operationCompleted, .completed])
        #expect(events.map(\.sequence) == [0, 1, 2, 3])
        #expect(events.map(\.schemaVersion).allSatisfy { $0 == ProgressEventSchema.current })
        #expect(events.map(\.planFingerprint).allSatisfy { $0 == plan.metadata.fingerprint })
        #expect(events[0].operationID == nil)
        #expect(events[0].completedBytes == nil)
        #expect(events[1].operationID == plan.operations[0].id)
        #expect(events[2].operationID == plan.operations[0].id)
        #expect(events[2].completedBytes == Int64(payload.count))
        #expect(events[3].operationID == nil)
        #expect(events[3].completedBytes == Int64(payload.count))
    }

    @Test("A path outside the injected root throws")
    func pathOutsideRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-fixture-outside-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let transport = FixtureRootOperationTransport(rootURL: root)

        await #expect(throws: HelperAuthorizationError.unsafePathResolution) {
            _ = try await self.collect(transport.execute(validatedPlan: try self.makePlan(path: outside.path, byteCount: 4)))
        }
        await #expect(throws: HelperAuthorizationError.unsafePathResolution) {
            let escaped = (root.path as NSString).appendingPathComponent("../\(outside.lastPathComponent)")
            _ = try await self.collect(transport.execute(validatedPlan: try self.makePlan(path: escaped, byteCount: 4)))
        }
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }

    @Test("A symlink that escapes the injected root throws")
    func symlinkEscape() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-fixture-link-target-\(UUID().uuidString)")
        let sentinel = Data("do-not-touch".utf8)
        try sentinel.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("escape.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let transport = FixtureRootOperationTransport(rootURL: root)

        await #expect(throws: HelperAuthorizationError.unsafePathResolution) {
            _ = try await self.collect(transport.execute(validatedPlan: try self.makePlan(path: link.path, byteCount: 12)))
        }
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("Empty directory removal matches the directoryNotEmpty contract")
    func emptyDirectoryContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        let occupied = root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: occupied.appendingPathComponent("child.txt"))
        let transport = FixtureRootOperationTransport(rootURL: root)

        let emptyPlan = try makePlan(
            action: .removeDirectory, path: empty.path, nodeKind: .directory, byteCount: 0,
            payload: .init(
                replacementContentBase64: nil, sourceSHA256: nil, postconditionSHA256: nil,
                directoryDeletionPolicy: .emptyOnly
            )
        )
        let emptyEvents = try await collect(transport.execute(validatedPlan: emptyPlan))
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(emptyEvents.last?.kind == .completed)

        let occupiedPlan = try makePlan(
            action: .removeDirectory, path: occupied.path, nodeKind: .directory, byteCount: 0,
            payload: .init(
                replacementContentBase64: nil, sourceSHA256: nil, postconditionSHA256: nil,
                directoryDeletionPolicy: .emptyOnly
            )
        )
        await #expect(throws: HelperAuthorizationError.directoryNotEmpty) {
            _ = try await self.collect(transport.execute(validatedPlan: occupiedPlan))
        }
        #expect(FileManager.default.fileExists(atPath: occupied.path))
        #expect(FileManager.default.fileExists(atPath: occupied.appendingPathComponent("child.txt").path))
    }

    @Test("replaceFile fails closed without mutating the fixture")
    func replaceFileFailsClosed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.plist")
        let original = Data("keep".utf8)
        try original.write(to: file)
        let transport = FixtureRootOperationTransport(rootURL: root)
        let plan = try makePlan(
            action: .replaceFile, path: file.path, nodeKind: .file, byteCount: Int64(original.count),
            kind: .optimize
        )

        await #expect(throws: HelperAuthorizationError.invalidPlan) {
            _ = try await self.collect(transport.execute(validatedPlan: plan))
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("removeFile and moveToTrash require a regular file in the fixture root")
    func fileActionsRequireRegularFile() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("trashed.cache")
        try Data("bye".utf8).write(to: file)
        let transport = FixtureRootOperationTransport(rootURL: root)

        await #expect(throws: HelperAuthorizationError.targetChanged) {
            _ = try await self.collect(
                transport.execute(validatedPlan: try self.makePlan(path: directory.path, byteCount: 0))
            )
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))

        let events = try await collect(
            transport.execute(validatedPlan: try makePlan(action: .moveToTrash, path: file.path, byteCount: 3, kind: .uninstall))
        )
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(events.last?.kind == .completed)
    }

    private func makePlan(
        action: ExecutionAction = .removeFile,
        path: String,
        nodeKind: ExpectedNodeKind = .file,
        byteCount: Int64,
        payload: ExecutionActionPayload? = nil,
        kind: ExecutionPlanKind = .clean
    ) throws -> ExecutionPlan {
        let now = Date()
        let operation = ExecutionPlanOperation(
            id: "operation.0", action: action,
            target: .init(
                path: path, nodeKind: nodeKind, byteCount: byteCount,
                modificationTime: now, fileIdentifier: "fixture-node"
            ),
            reason: "Fixture", payload: payload
        )
        let unsigned = ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: "1.53.0",
                createdAt: now.addingTimeInterval(-10), expiresAt: now.addingTimeInterval(300),
                fingerprint: ""
            ),
            kind: kind, operations: [operation]
        )
        return ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: unsigned.metadata.engineVersion,
                createdAt: unsigned.metadata.createdAt, expiresAt: unsigned.metadata.expiresAt,
                fingerprint: try unsigned.calculatedFingerprint()
            ),
            kind: kind, operations: [operation]
        )
    }

    private func collect(_ stream: AsyncThrowingStream<ExecutionProgressEvent, Error>) async throws -> [ExecutionProgressEvent] {
        var events: [ExecutionProgressEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func temporaryRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-fixture-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
