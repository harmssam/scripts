import CryptoKit
import Foundation
import Testing
@testable import Burrow

@Suite("Structured execution plan contracts")
struct ExecutionPlanContractTests {
    private let validAt = ISO8601DateFormatter().date(from: "2026-09-03T21:45:00Z")!

    @Test("Golden plan has a canonical deterministic fingerprint")
    func goldenPlan() throws {
        let plan = try fixturePlan()
        let expected = String(data: fixtureData("execution-plan-v1", "fingerprint"), encoding: .utf8)!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(expected == "d1bf154ca6d75e990179d49a124526f668cbbf0f6d99aaab568a2cdaefd8bdbb")
        #expect(try plan.calculatedFingerprint() == expected)
        #expect(try plan.validated(at: validAt) == plan)
        #expect(plan.operations.first?.target.path == "/Users/test/Library/Caches/example.cache")
    }

    @Test("Golden capabilities explicitly negotiate every plan kind and progress schema")
    func goldenCapabilities() throws {
        let capabilities = try JSONDecoder().decode(
            ExecutionPlanCapabilities.self, from: fixtureData("execution-capabilities-v1", "json")
        )
        #expect(capabilities.supportsStructuredPlans)
        #expect(capabilities.supportedPlanKinds == Set(ExecutionPlanKind.allCases))
    }

    @Test("Mole without the protocol fails closed")
    func unsupportedEngine() async throws {
        let engine = MoleEngineClient(executableURL: nil)
        let capabilities = await engine.executionPlanCapabilities()
        #expect(!capabilities.supportsStructuredPlans)
        await #expect(throws: EngineError.unsupportedCapability("structured clean execution plans")) {
            try await engine.executionPlan(for: .clean)
        }
    }

    @Test("Schema, expiry, future creation, and lifetime are rejected")
    func timeAndSchemaValidation() throws {
        let plan = try fixturePlan()
        #expect(throws: ExecutionPlanValidationError.unsupportedSchema(2)) {
            try replacing(plan, schema: 2).validated(at: validAt)
        }
        #expect(throws: ExecutionPlanValidationError.expired) {
            try plan.validated(at: plan.metadata.expiresAt)
        }
        #expect(throws: ExecutionPlanValidationError.notYetValid) {
            try plan.validated(at: plan.metadata.createdAt.addingTimeInterval(-31))
        }
        #expect(throws: ExecutionPlanValidationError.invalidLifetime) {
            try replacing(plan, expiresAt: plan.metadata.createdAt.addingTimeInterval(901)).validated(at: validAt)
        }
    }

    @Test("Fingerprint binds every path-level operation")
    func fingerprintTampering() throws {
        let plan = try fixturePlan()
        let changed = operation(plan.operations[0], path: "/Users/test/Library/Caches/other.cache")
        #expect(throws: ExecutionPlanValidationError.fingerprintMismatch) {
            try replacing(plan, operations: [changed]).validated(at: validAt)
        }
    }

    @Test("Plans reject relative, noncanonical, root, and protected paths", arguments: [
        "tmp/file", "/tmp/../etc/hosts", "/", "/System/Library/file", "/usr/local/file", "/private/var/db/item"
    ])
    func dangerousPaths(path: String) throws {
        let plan = try fixturePlan()
        let changed = operation(plan.operations[0], path: path)
        #expect(throws: ExecutionPlanValidationError.self) {
            try replacingAndSigning(plan, operations: [changed]).validated(at: validAt)
        }
    }

    @Test("Operation IDs and target paths must be unique")
    func uniqueness() throws {
        let plan = try fixturePlan()
        let duplicateID = operation(plan.operations[0], path: "/Users/test/Library/Caches/two.cache")
        #expect(throws: ExecutionPlanValidationError.duplicateOperationID("clean.cache.example")) {
            try replacingAndSigning(plan, operations: [plan.operations[0], duplicateID]).validated(at: validAt)
        }
        let otherID = ExecutionPlanOperation(
            id: "other", action: .removeFile, target: plan.operations[0].target, reason: "Duplicate target", payload: nil
        )
        #expect(throws: ExecutionPlanValidationError.duplicateTarget(plan.operations[0].target.path)) {
            try replacingAndSigning(plan, operations: [plan.operations[0], otherID]).validated(at: validAt)
        }
    }

    @Test("Plan kind restricts actions and node kinds")
    func actions() throws {
        let plan = try fixturePlan()
        let trash = operation(plan.operations[0], action: .moveToTrash)
        #expect(throws: ExecutionPlanValidationError.actionNotAllowed(.moveToTrash, .clean)) {
            try replacingAndSigning(plan, operations: [trash]).validated(at: validAt)
        }
        let directoryEvidence = ExecutionTargetEvidence(
            path: plan.operations[0].target.path, nodeKind: .directory, byteCount: 4096,
            modificationTime: plan.operations[0].target.modificationTime, fileIdentifier: "device:inode-directory"
        )
        let mismatch = ExecutionPlanOperation(id: "clean.cache.example", action: .removeFile, target: directoryEvidence, reason: "Mismatch", payload: nil)
        #expect(throws: ExecutionPlanValidationError.nodeKindMismatch("clean.cache.example")) {
            try replacingAndSigning(plan, operations: [mismatch]).validated(at: validAt)
        }
    }

    @Test("Destructive targets require stable identity and may not overlap")
    func targetIdentityAndOverlap() throws {
        let plan = try fixturePlan()
        let missingIdentity = ExecutionPlanOperation(
            id: "missing", action: .removeFile,
            target: .init(
                path: "/Users/test/Library/Caches/missing", nodeKind: .file, byteCount: 1,
                modificationTime: plan.metadata.createdAt, fileIdentifier: nil
            ), reason: "Fixture", payload: nil
        )
        #expect(throws: ExecutionPlanValidationError.missingTargetIdentity("missing")) {
            try signed(kind: .clean, like: plan, operations: [missingIdentity]).validated(at: validAt)
        }

        let ancestor = operation(plan.operations[0], path: "/Users/test/Library/Caches/tree")
        let descendant = ExecutionPlanOperation(
            id: "descendant", action: .removeFile,
            target: .init(
                path: "/Users/test/Library/Caches/tree/item", nodeKind: .file, byteCount: 1,
                modificationTime: plan.metadata.createdAt, fileIdentifier: "device:inode-2"
            ), reason: "Fixture", payload: nil
        )
        #expect(throws: ExecutionPlanValidationError.overlappingTargets(ancestor.target.path)) {
            try signed(kind: .clean, like: plan, operations: [descendant, ancestor]).validated(at: validAt)
        }
    }

    @Test("Kinds and actions enforce narrow target roots")
    func allowedRoots() throws {
        let plan = try fixturePlan()
        let outside = operation(plan.operations[0], path: "/Applications/NotACache.app")
        #expect(throws: ExecutionPlanValidationError.targetOutsideAllowedRoot(outside.target.path, .clean, .removeFile)) {
            try signed(kind: .clean, like: plan, operations: [outside]).validated(at: validAt)
        }
    }

    @Test("Directory deletion is empty-only and replacement binds source, bytes, and postcondition")
    func actionPayloads() throws {
        let plan = try fixturePlan()
        let directory = ExecutionPlanOperation(
            id: "empty.directory", action: .removeDirectory,
            target: .init(
                path: "/Users/test/Library/Caches/empty", nodeKind: .directory, byteCount: 0,
                modificationTime: plan.metadata.createdAt, fileIdentifier: "device:inode-directory"
            ), reason: "Empty cache directory",
            payload: .init(
                replacementContentBase64: nil, sourceSHA256: nil, postconditionSHA256: nil,
                directoryDeletionPolicy: .emptyOnly
            )
        )
        #expect(try signed(kind: .clean, like: plan, operations: [directory]).validated(at: validAt).operations.count == 1)
        let noPolicy = ExecutionPlanOperation(
            id: directory.id, action: directory.action, target: directory.target,
            reason: directory.reason, payload: nil
        )
        #expect(throws: ExecutionPlanValidationError.invalidActionPayload(directory.id)) {
            try signed(kind: .clean, like: plan, operations: [noPolicy]).validated(at: validAt)
        }

        let bytes = Data("replacement\n".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let replacement = ExecutionPlanOperation(
            id: "replace.preference", action: .replaceFile,
            target: .init(
                path: "/Users/test/Library/Preferences/example.conf", nodeKind: .file, byteCount: 12,
                modificationTime: plan.metadata.createdAt, fileIdentifier: "device:inode-preference"
            ), reason: "Normalize preference",
            payload: .init(
                replacementContentBase64: bytes.base64EncodedString(), sourceSHA256: String(repeating: "a", count: 64),
                postconditionSHA256: digest, directoryDeletionPolicy: nil
            )
        )
        #expect(try signed(kind: .optimize, like: plan, operations: [replacement]).validated(at: validAt).kind == .optimize)
        let badPostcondition = ExecutionPlanOperation(
            id: replacement.id, action: replacement.action, target: replacement.target,
            reason: replacement.reason,
            payload: .init(
                replacementContentBase64: bytes.base64EncodedString(), sourceSHA256: String(repeating: "a", count: 64),
                postconditionSHA256: String(repeating: "b", count: 64), directoryDeletionPolicy: nil
            )
        )
        #expect(throws: ExecutionPlanValidationError.invalidActionPayload(replacement.id)) {
            try signed(kind: .optimize, like: plan, operations: [badPostcondition]).validated(at: validAt)
        }
    }

    @Test("Uninstall argv validates application operands and terminates option parsing")
    func uninstallArguments() throws {
        #expect(try MoleEngineClient.uninstallPlanArguments(applicationPaths: ["/Applications/-Example.app"]) ==
            ["uninstall", "--plan-json", "--", "/Applications/-Example.app"])
        #expect(throws: EngineError.invalidRequest("Invalid application path: --help")) {
            try MoleEngineClient.uninstallPlanArguments(applicationPaths: ["--help"])
        }
        #expect(throws: EngineError.invalidRequest("Invalid application path: /Applications/Example.app/Contents")) {
            try MoleEngineClient.uninstallPlanArguments(applicationPaths: ["/Applications/Example.app/Contents"])
        }
    }

    @Test("Golden JSONL stream validates state and plan binding")
    func goldenProgress() throws {
        let events = try ProgressEventContract.decodeJSONL(fixtureData("progress-events-v1", "jsonl"), for: fixturePlan())
        #expect(events.count == 4)
        #expect(events.last?.kind == .completed)
    }

    @Test("Progress rejects plan mismatch, sequence gaps, unknown operations, and missing terminal")
    func progressFailures() throws {
        let plan = try fixturePlan()
        var events = try ProgressEventContract.decodeJSONL(fixtureData("progress-events-v1", "jsonl"), for: plan)
        events[1] = event(events[1], fingerprint: "wrong")
        #expect(throws: ProgressEventValidationError.planMismatch) { try ProgressEventContract.validate(events, for: plan) }

        events = try decodedProgress()
        events[1] = event(events[1], sequence: 4)
        #expect(throws: ProgressEventValidationError.invalidSequence(expected: 1, actual: 4)) { try ProgressEventContract.validate(events, for: plan) }

        events = try decodedProgress()
        events[1] = event(events[1], operationID: "unknown")
        #expect(throws: ProgressEventValidationError.unknownOperation("unknown")) { try ProgressEventContract.validate(events, for: plan) }

        events = try decodedProgress()
        #expect(throws: ProgressEventValidationError.missingTerminalEvent) { try ProgressEventContract.validate(Array(events.dropLast()), for: plan) }

        events = try decodedProgress()
        events[0] = event(events[0], kind: .operationStarted, operationID: "clean.cache.example")
        #expect(throws: ProgressEventValidationError.firstEventMustBeStarted) { try ProgressEventContract.validate(events, for: plan) }

        events = try decodedProgress()
        events[2] = event(events[2], kind: .operationFailed)
        #expect(throws: ProgressEventValidationError.invalidTransition) { try ProgressEventContract.validate(events, for: plan) }
    }

    @Test("Plan validation precedes progress semantics")
    func planBeforeProgress() throws {
        let plan = try fixturePlan()
        let invalidPlan = ExecutionPlan(
            metadata: .init(
                schemaVersion: plan.metadata.schemaVersion, engineVersion: plan.metadata.engineVersion,
                createdAt: plan.metadata.createdAt, expiresAt: plan.metadata.expiresAt, fingerprint: "tampered"
            ), kind: plan.kind, operations: plan.operations
        )
        var events = try decodedProgress()
        events[0] = event(events[0], kind: .operationStarted, operationID: plan.operations[0].id)
        #expect(throws: ExecutionPlanValidationError.fingerprintMismatch) {
            try ProgressEventContract.validate(events, for: invalidPlan)
        }
    }

    @Test("Progress byte accounting is complete and plan-bounded")
    func progressByteAccounting() throws {
        let plan = try fixturePlan()
        var events = try decodedProgress()
        let completed = events[2]
        events[2] = .init(
            schemaVersion: completed.schemaVersion, planFingerprint: completed.planFingerprint,
            sequence: completed.sequence, timestamp: completed.timestamp, kind: completed.kind,
            operationID: completed.operationID, completedBytes: nil, message: completed.message
        )
        #expect(throws: ProgressEventValidationError.missingCompletedByteCount(operationID: "clean.cache.example")) {
            try ProgressEventContract.validate(events, for: plan)
        }

        events = try decodedProgress()
        events[2] = .init(
            schemaVersion: completed.schemaVersion, planFingerprint: completed.planFingerprint,
            sequence: completed.sequence, timestamp: completed.timestamp, kind: completed.kind,
            operationID: completed.operationID, completedBytes: 4097, message: completed.message
        )
        #expect(throws: ProgressEventValidationError.byteCountExceedsPlan(operationID: "clean.cache.example")) {
            try ProgressEventContract.validate(events, for: plan)
        }

        events = try decodedProgress()
        let terminal = events[3]
        events[3] = .init(
            schemaVersion: terminal.schemaVersion, planFingerprint: terminal.planFingerprint,
            sequence: terminal.sequence, timestamp: terminal.timestamp, kind: terminal.kind,
            operationID: nil, completedBytes: 0, message: terminal.message
        )
        #expect(throws: ProgressEventValidationError.terminalByteCountMismatch(expected: 4096, actual: 0)) {
            try ProgressEventContract.validate(events, for: plan)
        }
    }

    @Test("JSONL requires complete, nonblank records")
    func framing() throws {
        let plan = try fixturePlan()
        let data = fixtureData("progress-events-v1", "jsonl")
        #expect(throws: ProgressEventValidationError.incompleteFinalLine) {
            try ProgressEventContract.decodeJSONL(Data(data.dropLast()), for: plan)
        }
        let blank = Data("\n".utf8) + data
        #expect(throws: ProgressEventValidationError.blankLine(1)) {
            try ProgressEventContract.decodeJSONL(blank, for: plan)
        }
    }

    private func fixturePlan() throws -> ExecutionPlan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExecutionPlan.self, from: fixtureData("execution-plan-v1", "json"))
    }

    private func decodedProgress() throws -> [ExecutionProgressEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(data: fixtureData("progress-events-v1", "jsonl"), encoding: .utf8).unwrap()
        return try text.split(separator: "\n").map { try decoder.decode(ExecutionProgressEvent.self, from: Data($0.utf8)) }
    }

    private func fixtureData(_ name: String, _ ext: String) -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: ext)!)
    }

    private func replacing(_ plan: ExecutionPlan, schema: Int? = nil, expiresAt: Date? = nil, operations: [ExecutionPlanOperation]? = nil) -> ExecutionPlan {
        .init(metadata: .init(
            schemaVersion: schema ?? plan.metadata.schemaVersion, engineVersion: plan.metadata.engineVersion,
            createdAt: plan.metadata.createdAt, expiresAt: expiresAt ?? plan.metadata.expiresAt,
            fingerprint: plan.metadata.fingerprint
        ), kind: plan.kind, operations: operations ?? plan.operations)
    }

    private func replacingAndSigning(_ plan: ExecutionPlan, operations: [ExecutionPlanOperation]) throws -> ExecutionPlan {
        let unsigned = replacing(plan, operations: operations)
        let fingerprint = try unsigned.calculatedFingerprint()
        return .init(metadata: .init(
            schemaVersion: unsigned.metadata.schemaVersion, engineVersion: unsigned.metadata.engineVersion,
            createdAt: unsigned.metadata.createdAt, expiresAt: unsigned.metadata.expiresAt, fingerprint: fingerprint
        ), kind: unsigned.kind, operations: unsigned.operations)
    }

    private func signed(kind: ExecutionPlanKind, like plan: ExecutionPlan, operations: [ExecutionPlanOperation]) throws -> ExecutionPlan {
        let unsigned = ExecutionPlan(
            metadata: .init(
                schemaVersion: plan.metadata.schemaVersion, engineVersion: plan.metadata.engineVersion,
                createdAt: plan.metadata.createdAt, expiresAt: plan.metadata.expiresAt, fingerprint: ""
            ), kind: kind, operations: operations
        )
        return .init(
            metadata: .init(
                schemaVersion: unsigned.metadata.schemaVersion, engineVersion: unsigned.metadata.engineVersion,
                createdAt: unsigned.metadata.createdAt, expiresAt: unsigned.metadata.expiresAt,
                fingerprint: try unsigned.calculatedFingerprint()
            ), kind: kind, operations: operations
        )
    }

    private func operation(_ source: ExecutionPlanOperation, path: String? = nil, action: ExecutionAction? = nil) -> ExecutionPlanOperation {
        .init(id: source.id, action: action ?? source.action, target: .init(
            path: path ?? source.target.path, nodeKind: source.target.nodeKind, byteCount: source.target.byteCount,
            modificationTime: source.target.modificationTime, fileIdentifier: source.target.fileIdentifier
        ), reason: source.reason, payload: source.payload)
    }

    private func event(_ source: ExecutionProgressEvent, fingerprint: String? = nil, sequence: Int? = nil,
                       kind: ExecutionProgressEventKind? = nil, operationID: String? = nil) -> ExecutionProgressEvent {
        .init(schemaVersion: source.schemaVersion, planFingerprint: fingerprint ?? source.planFingerprint,
              sequence: sequence ?? source.sequence, timestamp: source.timestamp, kind: kind ?? source.kind,
              operationID: operationID ?? source.operationID, completedBytes: source.completedBytes, message: source.message)
    }
}

private extension Optional where Wrapped == String {
    func unwrap() throws -> String {
        guard let self else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return self
    }
}
