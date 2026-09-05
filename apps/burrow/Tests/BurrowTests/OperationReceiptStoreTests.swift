import Foundation
import Testing
@testable import Burrow

@Suite("Privacy-preserving operation receipt persistence")
struct OperationReceiptStoreTests {
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Round trip persists only bounded structural receipt data")
    func privacyPreservingRoundTrip() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory: directory)
        let receipt = makeReceipt()

        try await store.save(receipt, provenance: .fixtureSimulation)
        let loaded = try await store.receipts()

        #expect(loaded.count == 1)
        #expect(loaded[0].receipt == receipt)
        #expect(loaded[0].provenance == .fixtureSimulation)

        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\":2"))
        #expect(text.contains("\"provenance\":\"fixtureSimulation\""))
        #expect(!text.contains("title"))
        #expect(!text.contains("detail"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("reason"))
        #expect(!text.contains("message"))
    }

    @Test("History is ordered, count bounded, and expired receipts are removed")
    func retentionAndCountBounds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FileOperationReceiptStore.Configuration(
            maximumReceiptCount: 2,
            retentionInterval: 100,
            maximumItemsPerReceipt: 10,
            maximumStoreBytes: 16_384
        )
        let store = try makeStore(directory: directory, configuration: configuration)

        try await store.save(makeReceipt(id: UUID(), finishedOffset: -200), provenance: .fixtureSimulation)
        let middle = makeReceipt(id: UUID(), finishedOffset: -20)
        let newest = makeReceipt(id: UUID(), finishedOffset: -10)
        let extra = makeReceipt(id: UUID(), finishedOffset: -30)
        try await store.save(middle, provenance: .fixtureSimulation)
        try await store.save(newest, provenance: .authenticatedHelper)
        try await store.save(extra, provenance: .fixtureSimulation)

        let loaded = try await store.receipts()
        #expect(loaded.map(\.receipt.id) == [newest.id, middle.id])
        #expect(loaded.map(\.provenance) == [.authenticatedHelper, .fixtureSimulation])
    }

    @Test("Unknown provenance is rejected and quarantined")
    func unknownProvenanceFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory: directory)
        try await store.save(makeReceipt(), provenance: .fixtureSimulation)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "\"provenance\":\"fixtureSimulation\"",
            with: "\"provenance\":\"authenticatedMole\""
        )
        try Data(text.utf8).write(to: file)

        await #expect(throws: OperationReceiptStoreError.corruptedStore) {
            _ = try await store.receipts()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Unexpected receipt text is rejected and never reaches disk")
    func rejectsSensitiveText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory: directory)
        let unsafe = OperationReceipt(
            operation: .clean,
            planFingerprint: String(repeating: "a", count: 64),
            startedAt: fixedNow.addingTimeInterval(-2),
            finishedAt: fixedNow.addingTimeInterval(-1),
            outcome: .failed,
            items: [
                .init(
                    title: "Clean item 1",
                    detail: "/Users/alice/Library/Caches/private",
                    status: .failed
                ),
            ]
        )

        await #expect(throws: OperationReceiptStoreError.invalidReceipt) {
            try await store.save(unsafe, provenance: .fixtureSimulation)
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("operation-receipts-v2.json").path
        ))
    }

    @Test("Malformed data is quarantined and loading fails closed")
    func corruptionIsQuarantined() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        try Data("not-json".utf8).write(to: file)
        let store = try makeStore(directory: directory)

        await #expect(throws: OperationReceiptStoreError.corruptedStore) {
            _ = try await store.receipts()
        }

        #expect(!FileManager.default.fileExists(atPath: file.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("operation-receipts-corrupt-") }
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]) == Data("not-json".utf8))
    }

    @Test("Unsupported schemas are quarantined without being overwritten")
    func unsupportedSchemaFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        try Data(#"{"schemaVersion":99,"receipts":[]}"#.utf8).write(to: file)
        let store = try makeStore(directory: directory)

        await #expect(throws: OperationReceiptStoreError.unsupportedSchema(99)) {
            _ = try await store.receipts()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Outcome, item, byte, and timestamp invariants fail closed on save")
    func semanticInvariantsOnSave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory: directory)

        let inconsistent: [OperationReceipt] = [
            makeSemanticReceipt(outcome: .completed, completedBytes: 1, statuses: [.completed, .skipped]),
            makeSemanticReceipt(outcome: .cancelled, completedBytes: 0, statuses: [.failed, .skipped]),
            makeSemanticReceipt(outcome: .partiallyCompleted, completedBytes: 1, statuses: [.completed, .completed]),
            makeSemanticReceipt(outcome: .failed, completedBytes: 0, statuses: [.skipped, .skipped]),
            makeSemanticReceipt(outcome: .cancelled, completedBytes: 1, statuses: [.skipped, .skipped]),
            OperationReceipt(
                operation: .clean,
                planFingerprint: String(repeating: "a", count: 64),
                startedAt: fixedNow,
                finishedAt: fixedNow.addingTimeInterval(-1),
                outcome: .completed,
                completedBytes: 1,
                items: [.init(title: "Clean item 1", detail: "Completed", status: .completed)]
            ),
        ]

        for receipt in inconsistent {
            await #expect(throws: OperationReceiptStoreError.invalidReceipt) {
                try await store.save(receipt, provenance: .fixtureSimulation)
            }
        }
    }

    @Test("Cross-field corruption on disk is quarantined")
    func semanticInvariantsOnLoad() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory: directory)
        try await store.save(makeReceipt(), provenance: .fixtureSimulation)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"outcome\":\"completed\"", with: "\"outcome\":\"cancelled\"")
        try Data(text.utf8).write(to: file)

        await #expect(throws: OperationReceiptStoreError.corruptedStore) {
            _ = try await store.receipts()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Directory and files have private POSIX permissions")
    func privatePermissions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let store = try makeStore(directory: directory)
        try await store.save(makeReceipt(), provenance: .authenticatedHelper)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")

        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(directoryMode == 0o700)
        #expect(fileMode == 0o600)
    }

    @Test("Symlinked directory and store are rejected without touching their targets")
    func rejectsSymlinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        let linkedDirectoryStore = try makeStore(directory: linkedDirectory)
        await #expect(throws: OperationReceiptStoreError.unsafeFilesystem) {
            _ = try await linkedDirectoryStore.receipts()
        }

        let outside = root.appendingPathComponent("outside.json")
        let sentinel = Data("do-not-touch".utf8)
        try sentinel.write(to: outside)
        let storePath = realDirectory.appendingPathComponent("operation-receipts-v2.json")
        try FileManager.default.createSymbolicLink(at: storePath, withDestinationURL: outside)
        let linkedFileStore = try makeStore(directory: realDirectory)
        await #expect(throws: OperationReceiptStoreError.unsafeFilesystem) {
            _ = try await linkedFileStore.receipts()
        }
        #expect(try Data(contentsOf: outside) == sentinel)
    }

    @Test("Quarantine is bounded by count, age, and total bytes")
    func boundedQuarantine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FileOperationReceiptStore.Configuration(
            maximumReceiptCount: 10,
            retentionInterval: 100,
            maximumItemsPerReceipt: 10,
            maximumStoreBytes: 1_024,
            maximumQuarantineCount: 2,
            quarantineRetentionInterval: 60,
            maximumQuarantineBytes: 12
        )
        let store = try makeStore(directory: directory, configuration: configuration)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        for _ in 0..<4 {
            try Data("broken".utf8).write(to: file)
            await #expect(throws: OperationReceiptStoreError.corruptedStore) {
                _ = try await store.receipts()
            }
        }
        var quarantined = try quarantineFiles(in: directory)
        #expect(quarantined.count == 2)
        let totalBytes = try quarantined.reduce(0) { partial, url in
            partial + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        #expect(totalBytes <= 12)

        for url in quarantined {
            try FileManager.default.setAttributes(
                [.modificationDate: fixedNow.addingTimeInterval(-120)], ofItemAtPath: url.path
            )
        }
        _ = try await store.receipts()
        quarantined = try quarantineFiles(in: directory)
        #expect(quarantined.isEmpty)
    }

    @Test("Oversized malformed input is discarded instead of retained raw")
    func oversizedCorruptionIsNotRetained() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FileOperationReceiptStore.Configuration(
            maximumStoreBytes: 1_024,
            maximumQuarantineBytes: 8
        )
        let store = try makeStore(directory: directory, configuration: configuration)
        let file = directory.appendingPathComponent("operation-receipts-v2.json")
        try Data(repeating: 0x41, count: 1_025).write(to: file)

        await #expect(throws: OperationReceiptStoreError.corruptedStore) {
            _ = try await store.receipts()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try quarantineFiles(in: directory).isEmpty)
    }

    private func makeStore(
        directory: URL,
        configuration: FileOperationReceiptStore.Configuration = .init()
    ) throws -> FileOperationReceiptStore {
        try FileOperationReceiptStore(
            directoryURL: directory,
            configuration: configuration,
            now: { fixedNow }
        )
    }

    private func makeReceipt(
        id: UUID = UUID(),
        finishedOffset: TimeInterval = -1
    ) -> OperationReceipt {
        let finishedAt = fixedNow.addingTimeInterval(finishedOffset)
        return OperationReceipt(
            id: id,
            operation: .clean,
            planFingerprint: String(repeating: "a", count: 64),
            startedAt: finishedAt.addingTimeInterval(-1),
            finishedAt: finishedAt,
            outcome: .completed,
            completedBytes: 42,
            items: [
                .init(title: "Clean item 1", detail: "Completed", status: .completed),
                .init(title: "Clean item 2", detail: "Completed", status: .completed),
            ]
        )
    }

    private func makeSemanticReceipt(
        outcome: ExecutionOutcome,
        completedBytes: Int64?,
        statuses: [ReceiptItemStatus]
    ) -> OperationReceipt {
        OperationReceipt(
            operation: .clean,
            planFingerprint: String(repeating: "a", count: 64),
            startedAt: fixedNow.addingTimeInterval(-2),
            finishedAt: fixedNow.addingTimeInterval(-1),
            outcome: outcome,
            completedBytes: completedBytes,
            items: statuses.enumerated().map { index, status in
                let detail: String = switch status {
                case .completed: "Completed"
                case .failed: "Stopped because the target no longer matched the reviewed plan."
                case .skipped: "Not started"
                }
                return .init(title: "Clean item \(index + 1)", detail: detail, status: status)
            }
        )
    }

    private func quarantineFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("operation-receipts-corrupt-") }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-receipt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
