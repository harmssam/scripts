import CryptoKit
import Foundation

enum ExecutionPlanSchema {
    static let current = 1
}

enum ExecutionPlanKind: String, Codable, Sendable, Equatable, CaseIterable {
    case clean
    case optimize
    case uninstall
}

enum ExecutionAction: String, Codable, Sendable, Equatable {
    case removeFile
    case removeDirectory
    case moveToTrash
    case replaceFile
}

enum ExpectedNodeKind: String, Codable, Sendable, Equatable {
    case file
    case directory
    case symbolicLink
}

enum DirectoryDeletionPolicy: String, Codable, Sendable, Equatable {
    /// The helper may remove the directory only after a no-follow enumeration proves it is empty.
    case emptyOnly
}

/// Action-specific data is deliberately explicit. Replacement bytes are carried in the plan,
/// the source digest binds the content observed during planning, and the postcondition digest
/// defines the exact content that must exist after an atomic replacement.
struct ExecutionActionPayload: Codable, Sendable, Equatable {
    let replacementContentBase64: String?
    let sourceSHA256: String?
    let postconditionSHA256: String?
    let directoryDeletionPolicy: DirectoryDeletionPolicy?
}

/// Evidence observed when the engine created the plan. An executor must observe the same
/// identity immediately before acting; this model is not itself authorization to execute.
struct ExecutionTargetEvidence: Codable, Sendable, Equatable {
    let path: String
    let nodeKind: ExpectedNodeKind
    let byteCount: Int64
    let modificationTime: Date
    /// Opaque engine-produced stable identity binding the filesystem/volume and node.
    /// It is mandatory for every destructive target and must be re-observed by the helper.
    let fileIdentifier: String?
}

struct ExecutionPlanOperation: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let action: ExecutionAction
    let target: ExecutionTargetEvidence
    let reason: String
    let payload: ExecutionActionPayload?
}

struct ExecutionPlanMetadata: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let engineVersion: String
    let createdAt: Date
    let expiresAt: Date
    let fingerprint: String
}

struct ExecutionPlan: Codable, Sendable, Equatable, Identifiable {
    let metadata: ExecutionPlanMetadata
    let kind: ExecutionPlanKind
    let operations: [ExecutionPlanOperation]

    var id: String { metadata.fingerprint }

    func calculatedFingerprint() throws -> String {
        SHA256.hash(data: canonicalFingerprintBytes()).map { String(format: "%02x", $0) }.joined()
    }

    /// Cross-language fingerprint encoding (v1): signed integers are 8-byte big-endian;
    /// strings are UTF-8 prefixed by an 8-byte unsigned big-endian byte length; optionals
    /// start with 0x00/0x01; arrays start with an 8-byte count. Dates are signed Unix epoch
    /// milliseconds. Fields appear in the exact order below. JSON serialization is irrelevant.
    func canonicalFingerprintBytes() -> Data {
        var writer = CanonicalFingerprintWriter()
        writer.string("burrow-execution-plan-v1")
        writer.integer(Int64(metadata.schemaVersion))
        writer.string(metadata.engineVersion)
        writer.integer(Self.epochMilliseconds(metadata.createdAt))
        writer.integer(Self.epochMilliseconds(metadata.expiresAt))
        writer.string(kind.rawValue)
        writer.count(operations.count)
        for operation in operations {
            writer.string(operation.id)
            writer.string(operation.action.rawValue)
            writer.string(operation.target.path)
            writer.string(operation.target.nodeKind.rawValue)
            writer.integer(operation.target.byteCount)
            writer.integer(Self.epochMilliseconds(operation.target.modificationTime))
            writer.optionalString(operation.target.fileIdentifier)
            writer.string(operation.reason)
            writer.optionalPayload(operation.payload)
        }
        return writer.data
    }

    func validated(at now: Date = Date()) throws -> ExecutionPlan {
        guard metadata.schemaVersion == ExecutionPlanSchema.current else {
            throw ExecutionPlanValidationError.unsupportedSchema(metadata.schemaVersion)
        }
        guard !metadata.engineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutionPlanValidationError.missingEngineVersion
        }
        guard metadata.createdAt < metadata.expiresAt else {
            throw ExecutionPlanValidationError.invalidLifetime
        }
        guard metadata.expiresAt.timeIntervalSince(metadata.createdAt) <= 15 * 60 else {
            throw ExecutionPlanValidationError.invalidLifetime
        }
        guard now >= metadata.createdAt.addingTimeInterval(-30) else {
            throw ExecutionPlanValidationError.notYetValid
        }
        guard now < metadata.expiresAt else { throw ExecutionPlanValidationError.expired }
        guard !operations.isEmpty else { throw ExecutionPlanValidationError.emptyPlan }

        var operationIDs = Set<String>()
        var targetPaths = Set<String>()
        for operation in operations {
            guard !operation.id.isEmpty, operationIDs.insert(operation.id).inserted else {
                throw ExecutionPlanValidationError.duplicateOperationID(operation.id)
            }
            guard !operation.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExecutionPlanValidationError.missingReason(operation.id)
            }
            let path = operation.target.path
            guard Self.isCanonicalAbsolutePath(path) else {
                throw ExecutionPlanValidationError.invalidPath(path)
            }
            guard targetPaths.insert(path).inserted else {
                throw ExecutionPlanValidationError.duplicateTarget(path)
            }
            guard operation.target.byteCount >= 0 else {
                throw ExecutionPlanValidationError.invalidByteCount(operation.id)
            }
            guard let identity = operation.target.fileIdentifier,
                  !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExecutionPlanValidationError.missingTargetIdentity(operation.id)
            }
            guard Self.action(operation.action, isAllowedFor: kind) else {
                throw ExecutionPlanValidationError.actionNotAllowed(operation.action, kind)
            }
            guard Self.action(operation.action, matches: operation.target.nodeKind) else {
                throw ExecutionPlanValidationError.nodeKindMismatch(operation.id)
            }
            guard Self.isAllowedRoot(path, kind: kind, action: operation.action) else {
                throw ExecutionPlanValidationError.targetOutsideAllowedRoot(path, kind, operation.action)
            }
            try Self.validatePayload(operation)
        }

        let sortedPaths = targetPaths.sorted()
        for index in sortedPaths.indices.dropLast() {
            let ancestor = sortedPaths[index]
            if sortedPaths[(index + 1)...].contains(where: { $0.hasPrefix(ancestor + "/") }) {
                throw ExecutionPlanValidationError.overlappingTargets(ancestor)
            }
        }

        let expected = try calculatedFingerprint()
        guard metadata.fingerprint == expected else {
            throw ExecutionPlanValidationError.fingerprintMismatch
        }
        return self
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.first == "/", path != "/",
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path, !path.hasSuffix("/") else { return false }
        let forbidden = ["/System", "/bin", "/sbin", "/usr", "/dev", "/private/var/db"]
        return !forbidden.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func isValidUninstallApplicationPath(_ path: String) -> Bool {
        guard isCanonicalAbsolutePath(path), path.hasSuffix(".app") else { return false }
        let components = path.split(separator: "/").map(String.init)
        if components.count == 2, components[0] == "Applications" { return true }
        return components.count == 4 && components[0] == "Users" && components[2] == "Applications"
    }

    /// This is the unprivileged contract allowlist, not a filesystem authorization check.
    /// The future helper must independently resolve every component without following symlinks,
    /// verify mount/device and stable identity, and repeat the kind/content checks at action time.
    private static func isAllowedRoot(_ path: String, kind: ExecutionPlanKind, action: ExecutionAction) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        let userLibrary: (String) -> Bool = { folder in
            components.count >= 5 && components[0] == "Users" && components[2] == "Library" &&
                components[3] == folder
        }
        switch (kind, action) {
        case (.clean, .removeFile), (.clean, .removeDirectory):
            return userLibrary("Caches") || userLibrary("Logs")
        case (.optimize, .replaceFile), (.optimize, .removeFile):
            return userLibrary("Preferences") ||
                (components.count >= 3 && components[0] == "Library" && components[1] == "Preferences")
        case (.uninstall, .moveToTrash):
            return isValidUninstallApplicationPath(path)
        default:
            return false
        }
    }

    private static func validatePayload(_ operation: ExecutionPlanOperation) throws {
        switch operation.action {
        case .removeFile, .moveToTrash:
            guard operation.payload == nil else { throw ExecutionPlanValidationError.invalidActionPayload(operation.id) }
        case .removeDirectory:
            guard operation.payload?.directoryDeletionPolicy == .emptyOnly,
                  operation.payload?.replacementContentBase64 == nil,
                  operation.payload?.sourceSHA256 == nil,
                  operation.payload?.postconditionSHA256 == nil else {
                throw ExecutionPlanValidationError.invalidActionPayload(operation.id)
            }
        case .replaceFile:
            guard let payload = operation.payload,
                  payload.directoryDeletionPolicy == nil,
                  let encoded = payload.replacementContentBase64,
                  let content = Data(base64Encoded: encoded), !content.isEmpty,
                  content.base64EncodedString() == encoded,
                  let source = payload.sourceSHA256, isSHA256(source),
                  let postcondition = payload.postconditionSHA256, isSHA256(postcondition),
                  SHA256.hash(data: content).map({ String(format: "%02x", $0) }).joined() == postcondition else {
                throw ExecutionPlanValidationError.invalidActionPayload(operation.id)
            }
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func action(_ action: ExecutionAction, isAllowedFor kind: ExecutionPlanKind) -> Bool {
        switch kind {
        case .clean: action == .removeFile || action == .removeDirectory
        case .optimize: action == .replaceFile || action == .removeFile
        case .uninstall: action == .moveToTrash
        }
    }

    private static func action(_ action: ExecutionAction, matches nodeKind: ExpectedNodeKind) -> Bool {
        switch action {
        case .removeFile, .replaceFile: nodeKind == .file
        case .removeDirectory: nodeKind == .directory
        case .moveToTrash: nodeKind != .symbolicLink
        }
    }
}

enum ExecutionPlanValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case missingEngineVersion
    case invalidLifetime
    case notYetValid
    case expired
    case emptyPlan
    case duplicateOperationID(String)
    case duplicateTarget(String)
    case missingReason(String)
    case invalidPath(String)
    case invalidByteCount(String)
    case missingTargetIdentity(String)
    case actionNotAllowed(ExecutionAction, ExecutionPlanKind)
    case nodeKindMismatch(String)
    case invalidActionPayload(String)
    case targetOutsideAllowedRoot(String, ExecutionPlanKind, ExecutionAction)
    case overlappingTargets(String)
    case fingerprintMismatch
}

private struct CanonicalFingerprintWriter {
    var data = Data()

    mutating func integer(_ value: Int64) { unsigned(UInt64(bitPattern: value)) }
    mutating func count(_ value: Int) { unsigned(UInt64(value)) }
    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        unsigned(UInt64(bytes.count))
        data.append(bytes)
    }
    mutating func optionalString(_ value: String?) {
        guard let value else { data.append(0); return }
        data.append(1)
        string(value)
    }
    mutating func optionalPayload(_ payload: ExecutionActionPayload?) {
        guard let payload else { data.append(0); return }
        data.append(1)
        optionalString(payload.replacementContentBase64)
        optionalString(payload.sourceSHA256)
        optionalString(payload.postconditionSHA256)
        optionalString(payload.directoryDeletionPolicy?.rawValue)
    }
    private mutating func unsigned(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

enum ExecutionPlanRequest: Sendable, Equatable {
    case clean
    case optimize
    case uninstall(applicationPaths: [String])
}

struct ExecutionPlanCapabilities: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let engineVersion: String
    let supportedPlanKinds: Set<ExecutionPlanKind>
    let progressEventSchemaVersion: Int?

    var supportsStructuredPlans: Bool {
        schemaVersion == ExecutionPlanSchema.current && progressEventSchemaVersion == ProgressEventSchema.current
    }

    static func unavailable(engineVersion: String) -> Self {
        .init(schemaVersion: 0, engineVersion: engineVersion, supportedPlanKinds: [], progressEventSchemaVersion: nil)
    }
}
