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
}
