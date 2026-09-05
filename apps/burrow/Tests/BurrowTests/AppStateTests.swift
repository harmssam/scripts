import Foundation
import Testing
@testable import Burrow

@Suite("Burrow app state")
@MainActor
struct AppStateTests {
    @Test("Every primary section has a distinct atmosphere")
    func sectionsExist() {
        #expect(AppSection.allCases.map(\.rawValue) == ["Clean", "Apps", "Optimize", "Analyze", "Status"])
    }

    @Test("Selected app size includes application and related files")
    func selectedSize() {
        let state = AppState()
        let app = UninstallPreviewPlan.Application(
            id: "test.app", name: "Test", bundleID: "test.app", uninstallName: "Test",
            path: "/Applications/Test.app", source: "Test", displaySize: "1 GB", sizeBytes: 1_000_000_000
        )
        state.uninstallPlan = UninstallPreviewPlan(
            metadata: .init(
                schemaVersion: PreviewPlanSchema.current,
                fingerprint: PreviewFingerprint.make(kind: "test", engineVersion: "test", components: [app.id]),
                engineVersion: "test", source: .moleCompatibilityAdapter, warnings: []
            ),
            applications: [app]
        )
        let first = state.uninstallPlan.applications[0]
        state.selectedAppIDs.insert(first.id)
        #expect(state.selectedAppsSize == Double(first.sizeBytes ?? 0) / 1_000_000_000)
    }

    @Test("AppState has no mutating execute wrappers")
    func noExecuteWrappers() throws {
        let source = try String(contentsOf: sourceFile("AppState.swift"), encoding: .utf8)
        #expect(!source.contains("func executeClean("))
        #expect(!source.contains("func executeOptimize("))
        #expect(!source.contains("func executeUninstall("))
        #expect(!source.contains("func executeSelectedApps("))
    }

    @Test("A preview still builds cleanExecution via FixtureExecutionPresentationFactory")
    func previewBuildsCleanExecution() async throws {
        let state = AppState(engine: PreviewOnlyEngine())
        state.previewClean()
        try await waitUntil { state.cleanPhase == .review }
        #expect(state.cleanPhase == .review)
        let execution = try #require(state.cleanExecution)
        #expect(execution.mode == .fixtureSimulation)
        #expect(execution.review?.previewFingerprint == state.cleanPlan?.metadata.fingerprint)
    }

    @Test("previewOptimize failure leaves optimizePlan nil")
    func optimizePreviewFailureClearsPlan() async throws {
        let state = AppState(engine: PreviewOnlyEngine())
        state.optimizePlan = PreviewFallbacks.optimize(reason: "stale")
        state.previewOptimize()
        try await waitUntil { !state.optimizeIsLoading }
        #expect(state.optimizePlan == nil)
        #expect(state.optimizeExecution == nil)
        #expect(state.optimizeError != nil)
    }

    @Test("Empty receipt history shows truthful Clean footer placeholders")
    func emptyFooterIsTruthful() async throws {
        let directory = try temporaryReceiptDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileOperationReceiptStore(directoryURL: directory)
        let state = AppState(engine: PreviewOnlyEngine(), receiptStore: store)
        await state.loadStoredReceipts()

        #expect(state.cleanFooter.lastClean == "—")
        #expect(state.cleanFooter.lifetimeReclaimed == "0 B")
        #expect(state.cleanFooter.protectedPaths == "—")
        #expect(!state.cleanFooter.isDemoHistory)
        let source = try String(contentsOf: sourceFile("CleanView.swift"), encoding: .utf8)
        #expect(!source.contains("8 days ago"))
        #expect(!source.contains("148.2 GB"))
        #expect(!source.contains("12 paths"))
    }

    @Test("Saving a demo receipt drives footer-derived Clean history")
    func demoReceiptDrivesFooter() async throws {
        let directory = try temporaryReceiptDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileOperationReceiptStore(directoryURL: directory)
        let state = AppState(engine: PreviewOnlyEngine(), receiptStore: store)
        let now = Date()
        let finishedAt = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let receipt = makeHistoryReceipt(finishedAt: finishedAt, bytes: 42)

        await state.persistDemoReceipt(receipt)

        let expected = CleanFooterMetrics(
            receipts: [StoredOperationReceipt(receipt: receipt, provenance: .fixtureSimulation)],
            now: now
        )
        #expect(state.cleanFooter.lastClean == expected.lastClean)
        #expect(state.cleanFooter.lifetimeReclaimed == ByteFormatter.string(Int64(42)))
        #expect(state.cleanFooter.protectedPaths == "—")
        #expect(state.cleanFooter.isDemoHistory)

        let loaded = try await store.receipts()
        #expect(loaded.count == 1)
        #expect(loaded[0].provenance == .fixtureSimulation)
        #expect(loaded[0].receipt.id == receipt.id)
    }

    @Test("startReadOnlyServices loads persisted receipts into the Clean footer")
    func startReadOnlyServicesLoadsReceipts() async throws {
        let directory = try temporaryReceiptDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileOperationReceiptStore(directoryURL: directory)
        let finishedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let receipt = makeHistoryReceipt(finishedAt: finishedAt, bytes: 1_024)
        try await store.save(receipt, provenance: .fixtureSimulation)

        let state = AppState(engine: PreviewOnlyEngine(), receiptStore: store)
        state.startReadOnlyServices()
        try await waitUntil { state.cleanFooter.isDemoHistory }

        #expect(state.cleanFooter.lastClean != "—")
        #expect(state.cleanFooter.lifetimeReclaimed == ByteFormatter.string(Int64(1_024)))
        #expect(state.storedReceipts.map(\.provenance) == [.fixtureSimulation])
    }

    @Test("Cancelled receipts do not inflate lifetime reclaimed")
    func cancelledReceiptsAreExcludedFromLifetime() async throws {
        let directory = try temporaryReceiptDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileOperationReceiptStore(directoryURL: directory)
        let state = AppState(engine: PreviewOnlyEngine(), receiptStore: store)
        let completed = makeHistoryReceipt(finishedAt: Date().addingTimeInterval(-60), bytes: 100)
        let cancelled = OperationReceipt(
            operation: .clean,
            planFingerprint: String(repeating: "b", count: 64),
            startedAt: Date().addingTimeInterval(-3),
            finishedAt: Date().addingTimeInterval(-2),
            outcome: .cancelled,
            completedBytes: 0,
            items: [
                .init(title: "Clean item 1", detail: "Not started", status: .skipped),
            ]
        )
        await state.persistDemoReceipt(completed)
        await state.persistDemoReceipt(cancelled)

        #expect(state.cleanFooter.lifetimeReclaimed == ByteFormatter.string(Int64(100)))
        #expect(state.storedReceipts.count == 2)
        #expect(state.cleanFooter.isDemoHistory)
    }

    @Test("AppState demo persistence never writes authenticated-helper provenance")
    func demoPathDoesNotWriteHelperProvenance() throws {
        let source = try String(contentsOf: sourceFile("AppState.swift"), encoding: .utf8)
        #expect(source.contains("provenance: .fixtureSimulation"))
        #expect(!source.contains("provenance: .authenticatedHelper"))
    }

    @Test("prepareAppsExecution builds a demo presentation from the selection")
    func prepareAppsExecutionFromSelection() {
        let state = AppState()
        let app = UninstallPreviewPlan.Application(
            id: "test.app", name: "Test", bundleID: "test.app", uninstallName: "Test",
            path: "/Applications/Test.app", source: "Test", displaySize: "1 GB", sizeBytes: 1_000_000_000
        )
        state.uninstallPlan = UninstallPreviewPlan(
            metadata: .init(
                schemaVersion: PreviewPlanSchema.current,
                fingerprint: PreviewFingerprint.make(kind: "test", engineVersion: "test", components: [app.id]),
                engineVersion: "test", source: .moleCompatibilityAdapter, warnings: []
            ),
            applications: [app]
        )
        state.selectedAppIDs = [app.id]
        state.prepareAppsExecution()
        #expect(state.appsExecution?.mode == .fixtureSimulation)
        #expect(state.appsExecution?.review?.previewFingerprint == state.selectedUninstallPlan.metadata.fingerprint)

        state.selectedAppIDs.removeAll()
        state.prepareAppsExecution()
        #expect(state.appsExecution == nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sourceFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Burrow/\(name)")
    }

    private func makeHistoryReceipt(finishedAt: Date, bytes: Int64) -> OperationReceipt {
        OperationReceipt(
            operation: .clean,
            planFingerprint: String(repeating: "a", count: 64),
            startedAt: finishedAt.addingTimeInterval(-1),
            finishedAt: finishedAt,
            outcome: .completed,
            completedBytes: bytes,
            items: [
                .init(title: "Clean item 1", detail: "Completed", status: .completed),
            ]
        )
    }

    private func temporaryReceiptDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-appstate-receipts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor PreviewOnlyEngine: EngineClientProtocol {
    func availability() async -> EngineAvailability { .unavailable("test") }
    func statusSnapshot() async throws -> StatusSnapshot { throw EngineError.unavailable }
    func analyze(path: String) async throws -> AnalyzeReport { throw EngineError.unavailable }
    func cleanPreview() async throws -> CleanPreviewPlan { PreviewFallbacks.clean(reason: "test") }
    func optimizePreview() async throws -> OptimizePreviewPlan { throw EngineError.unavailable }
    func uninstallInventory() async throws -> UninstallPreviewPlan { throw EngineError.unavailable }
    func executionPlanCapabilities() async -> ExecutionPlanCapabilities { .unavailable(engineVersion: "test") }
    func executionPlan(for request: ExecutionPlanRequest) async throws -> ExecutionPlan { throw EngineError.unavailable }
}
