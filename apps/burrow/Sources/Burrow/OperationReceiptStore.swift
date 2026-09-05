import Darwin
import Foundation

/// Always distinguishes simulated history from authenticated helper results.
enum OperationReceiptProvenance: String, Codable, Equatable, Sendable {
    case fixtureSimulation
    case authenticatedHelper
}

struct StoredOperationReceipt: Equatable, Sendable {
    let receipt: OperationReceipt
    let provenance: OperationReceiptProvenance
}

protocol OperationReceiptStoring: Sendable {
    func save(_ receipt: OperationReceipt, provenance: OperationReceiptProvenance) async throws
    func receipts() async throws -> [StoredOperationReceipt]
}

enum OperationReceiptStoreError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidReceipt
    case unsupportedSchema(Int)
    case corruptedStore
    case unsafeFilesystem
}

actor FileOperationReceiptStore: OperationReceiptStoring {
    struct Configuration: Sendable {
        let maximumReceiptCount: Int
        let retentionInterval: TimeInterval
        let maximumItemsPerReceipt: Int
        let maximumStoreBytes: Int
        let maximumQuarantineCount: Int
        let quarantineRetentionInterval: TimeInterval
        let maximumQuarantineBytes: Int

        init(
            maximumReceiptCount: Int = 100,
            retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
            maximumItemsPerReceipt: Int = 10_000,
            maximumStoreBytes: Int = 4 * 1_024 * 1_024,
            maximumQuarantineCount: Int = 3,
            quarantineRetentionInterval: TimeInterval = 7 * 24 * 60 * 60,
            maximumQuarantineBytes: Int = 1 * 1_024 * 1_024
        ) {
            self.maximumReceiptCount = maximumReceiptCount
            self.retentionInterval = retentionInterval
            self.maximumItemsPerReceipt = maximumItemsPerReceipt
            self.maximumStoreBytes = maximumStoreBytes
            self.maximumQuarantineCount = maximumQuarantineCount
            self.quarantineRetentionInterval = quarantineRetentionInterval
            self.maximumQuarantineBytes = maximumQuarantineBytes
        }

        fileprivate var isValid: Bool {
            maximumReceiptCount > 0 && maximumReceiptCount <= 10_000
                && retentionInterval.isFinite && retentionInterval > 0
                && maximumItemsPerReceipt > 0 && maximumItemsPerReceipt <= 100_000
                && maximumStoreBytes >= 1_024 && maximumStoreBytes <= 64 * 1_024 * 1_024
                && maximumQuarantineCount >= 0 && maximumQuarantineCount <= 100
                && quarantineRetentionInterval.isFinite && quarantineRetentionInterval > 0
                && maximumQuarantineBytes >= 0 && maximumQuarantineBytes <= 64 * 1_024 * 1_024
        }
    }

    private struct Envelope: Codable {
        static let currentSchemaVersion = 2
        let schemaVersion: Int
        var receipts: [PersistedReceipt]
    }

    /// Deliberately excludes item titles/details and all plan or engine content.
    private struct PersistedReceipt: Codable {
        enum ResultCode: String, Codable { case completed, targetMismatch, interrupted, notStarted }
        struct Item: Codable {
            let id: UUID
            let status: ReceiptItemStatus
            let resultCode: ResultCode
        }
        let id: UUID
        let operation: MaintenanceOperation
        let planFingerprint: String
        let provenance: OperationReceiptProvenance
        let startedAt: Date
        let finishedAt: Date
        let outcome: ExecutionOutcome
        let completedBytes: Int64?
        let items: [Item]
    }

    private let directoryURL: URL
    private let storeURL: URL
    private let configuration: Configuration
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        directoryURL: URL,
        configuration: Configuration = .init(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard configuration.isValid else { throw OperationReceiptStoreError.invalidConfiguration }
        let directory = directoryURL.standardizedFileURL
        let store = directory.appendingPathComponent("operation-receipts-v2.json", isDirectory: false)
        guard store.deletingLastPathComponent().standardizedFileURL == directory else {
            throw OperationReceiptStoreError.unsafeFilesystem
        }
        self.directoryURL = directory
        self.storeURL = store
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
    }

    func save(_ receipt: OperationReceipt, provenance: OperationReceiptProvenance) throws {
        try ensureSecureDirectory()
        let persisted = try validatedPersistedReceipt(from: receipt, provenance: provenance)
        var envelope = try readEnvelope()
        envelope.receipts.removeAll { $0.id == persisted.id }
        envelope.receipts.append(persisted)
        envelope.receipts = retained(envelope.receipts, at: now())
        try write(envelope)
    }

    func receipts() throws -> [StoredOperationReceipt] {
        try ensureSecureDirectory()
        var envelope = try readEnvelope()
        let kept = retained(envelope.receipts, at: now())
        if kept.map(\.id) != envelope.receipts.map(\.id) {
            envelope.receipts = kept
            try write(envelope)
        }
        return kept.map(makeStoredReceipt)
    }

    private func readEnvelope() throws -> Envelope {
        try ensureSecureDirectory()
        try pruneQuarantine()
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return Envelope(schemaVersion: Envelope.currentSchemaVersion, receipts: [])
        }
        try ensureRegularFile(at: storeURL)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: storeURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= configuration.maximumStoreBytes else {
                throw OperationReceiptStoreError.corruptedStore
            }
            let data = try Data(contentsOf: storeURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Envelope.currentSchemaVersion else {
                try quarantineStore()
                throw OperationReceiptStoreError.unsupportedSchema(envelope.schemaVersion)
            }
            guard envelope.receipts.count <= configuration.maximumReceiptCount,
                  envelope.receipts.allSatisfy({ isValidPersistedReceipt($0, at: now()) }) else {
                throw OperationReceiptStoreError.corruptedStore
            }
            return envelope
        } catch let error as OperationReceiptStoreError {
            if error == .corruptedStore { try? quarantineStore() }
            throw error
        } catch {
            try? quarantineStore()
            throw OperationReceiptStoreError.corruptedStore
        }
    }

    private func write(_ envelope: Envelope) throws {
        try ensureSecureDirectory()
        if fileManager.fileExists(atPath: storeURL.path) { try ensureRegularFile(at: storeURL) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= configuration.maximumStoreBytes else {
            throw OperationReceiptStoreError.invalidReceipt
        }
        try data.write(to: storeURL, options: [.atomic])
        try setAndVerifyPermissions(0o600, at: storeURL, requireDirectory: false)
    }

    private func quarantineStore() throws {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        try ensureRegularFile(at: storeURL)
        let attributes = try fileManager.attributesOfItem(atPath: storeURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        if configuration.maximumQuarantineCount == 0 || size > configuration.maximumQuarantineBytes {
            try fileManager.removeItem(at: storeURL)
            try pruneQuarantine()
            return
        }
        let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
        let destination = directoryURL.appendingPathComponent(
            "operation-receipts-corrupt-\(timestamp)-\(UUID().uuidString).json"
        )
        try fileManager.moveItem(at: storeURL, to: destination)
        try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
        try setAndVerifyPermissions(0o600, at: destination, requireDirectory: false)
        try pruneQuarantine()
    }

    private func pruneQuarantine() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let entries = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(keys))
            .filter { $0.lastPathComponent.hasPrefix("operation-receipts-corrupt-") }
            .compactMap { url -> (URL, Date, Int)? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else {
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }
        let cutoff = now().addingTimeInterval(-configuration.quarantineRetentionInterval)
        var count = 0
        var bytes = 0
        for entry in entries {
            let fits = count < configuration.maximumQuarantineCount
                && entry.1 >= cutoff
                && entry.2 >= 0
                && entry.2 <= configuration.maximumQuarantineBytes - bytes
            if fits {
                count += 1
                bytes += entry.2
                try setAndVerifyPermissions(0o600, at: entry.0, requireDirectory: false)
            } else {
                try fileManager.removeItem(at: entry.0)
            }
        }
    }

    private func retained(_ receipts: [PersistedReceipt], at date: Date) -> [PersistedReceipt] {
        let cutoff = date.addingTimeInterval(-configuration.retentionInterval)
        return receipts.filter { $0.finishedAt >= cutoff }
            .sorted {
                $0.finishedAt == $1.finishedAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.finishedAt > $1.finishedAt
            }
            .prefix(configuration.maximumReceiptCount).map { $0 }
    }

    private func validatedPersistedReceipt(
        from receipt: OperationReceipt,
        provenance: OperationReceiptProvenance
    ) throws -> PersistedReceipt {
        let persisted = PersistedReceipt(
            id: receipt.id, operation: receipt.operation,
            planFingerprint: receipt.planFingerprint, provenance: provenance,
            startedAt: receipt.startedAt, finishedAt: receipt.finishedAt,
            outcome: receipt.outcome, completedBytes: receipt.completedBytes,
            items: try receipt.items.enumerated().map { index, item in
                guard item.title == "\(receipt.operation.title) item \(index + 1)",
                      safeDetails(for: item.status).contains(item.detail) else {
                    throw OperationReceiptStoreError.invalidReceipt
                }
                return .init(id: item.id, status: item.status, resultCode: resultCode(for: item.detail))
            }
        )
        guard isValidPersistedReceipt(persisted, at: now()) else {
            throw OperationReceiptStoreError.invalidReceipt
        }
        return persisted
    }

    private func isValidPersistedReceipt(_ receipt: PersistedReceipt, at date: Date) -> Bool {
        guard !receipt.items.isEmpty,
              receipt.items.count <= configuration.maximumItemsPerReceipt,
              receipt.startedAt.timeIntervalSince1970.isFinite,
              receipt.finishedAt.timeIntervalSince1970.isFinite,
              receipt.startedAt <= receipt.finishedAt,
              receipt.finishedAt <= date.addingTimeInterval(5 * 60),
              receipt.completedBytes.map({ $0 >= 0 }) ?? true,
              isSafeFingerprint(receipt.planFingerprint),
              Set(receipt.items.map(\.id)).count == receipt.items.count,
              receipt.items.allSatisfy(statusMatchesResultCode) else { return false }

        let completed = receipt.items.count { $0.status == .completed }
        let failed = receipt.items.count { $0.status == .failed }
        let skipped = receipt.items.count { $0.status == .skipped }
        if completed == 0, let bytes = receipt.completedBytes, bytes != 0 { return false }
        switch receipt.outcome {
        case .completed: return completed == receipt.items.count && failed == 0 && skipped == 0
        case .cancelled: return failed == 0 && skipped > 0
        case .partiallyCompleted: return completed > 0 && (failed > 0 || skipped > 0)
        case .failed: return failed > 0
        }
    }

    private func statusMatchesResultCode(_ item: PersistedReceipt.Item) -> Bool {
        switch (item.status, item.resultCode) {
        case (.completed, .completed), (.failed, .targetMismatch),
             (.skipped, .interrupted), (.skipped, .notStarted): return true
        default: return false
        }
    }

    private func ensureSecureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw OperationReceiptStoreError.unsafeFilesystem }
            let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw OperationReceiptStoreError.unsafeFilesystem }
        } else {
            try fileManager.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try setAndVerifyPermissions(0o700, at: directoryURL, requireDirectory: true)
    }

    private func ensureRegularFile(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OperationReceiptStoreError.unsafeFilesystem
        }
        try setAndVerifyPermissions(0o600, at: url, requireDirectory: false)
    }

    private func setAndVerifyPermissions(_ mode: Int, at url: URL, requireDirectory: Bool) throws {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (requireDirectory ? O_DIRECTORY : 0)
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else { throw OperationReceiptStoreError.unsafeFilesystem }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == (requireDirectory ? S_IFDIR : S_IFREG),
              info.st_uid == geteuid(),
              fchmod(descriptor, mode_t(mode)) == 0,
              fstat(descriptor, &info) == 0,
              Int(info.st_mode & 0o777) == mode,
              info.st_uid == geteuid() else {
            throw OperationReceiptStoreError.unsafeFilesystem
        }
    }

    private func isSafeFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func makeStoredReceipt(_ persisted: PersistedReceipt) -> StoredOperationReceipt {
        StoredOperationReceipt(
            receipt: OperationReceipt(
                id: persisted.id, operation: persisted.operation,
                planFingerprint: persisted.planFingerprint,
                startedAt: persisted.startedAt, finishedAt: persisted.finishedAt,
                outcome: persisted.outcome, completedBytes: persisted.completedBytes,
                items: persisted.items.enumerated().map { index, item in
                    .init(id: item.id, title: "\(persisted.operation.title) item \(index + 1)",
                          detail: detail(for: item.resultCode), status: item.status)
                }
            ), provenance: persisted.provenance
        )
    }

    private func safeDetails(for status: ReceiptItemStatus) -> Set<String> {
        switch status {
        case .completed: ["Completed"]
        case .failed: ["Stopped because the target no longer matched the reviewed plan."]
        case .skipped: ["Interrupted before completion", "Not started"]
        }
    }

    private func resultCode(for detail: String) -> PersistedReceipt.ResultCode {
        switch detail {
        case "Completed": .completed
        case "Stopped because the target no longer matched the reviewed plan.": .targetMismatch
        case "Interrupted before completion": .interrupted
        default: .notStarted
        }
    }

    private func detail(for code: PersistedReceipt.ResultCode) -> String {
        switch code {
        case .completed: "Completed"
        case .targetMismatch: "Stopped because the target no longer matched the reviewed plan."
        case .interrupted: "Interrupted before completion"
        case .notStarted: "Not started"
        }
    }
}
