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
