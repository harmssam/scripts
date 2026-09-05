import SwiftUI

struct OptimizeView: View {
    @Environment(AppState.self) private var appState
    @State private var showingRun = false
    @State private var executionModel: ExecutionPresentationModel?
    private let atmosphere = FeatureAtmosphere.optimize

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 10)
            OrbView(
                atmosphere: atmosphere,
                progress: appState.optimizeIsLoading ? 0.22 : nil,
                size: 210
            )
            Text(appState.optimizeIsLoading ? "Building a safe preview" : appState.optimizePlan == nil ? "A lighter-running Mac" : "Maintenance preview")
                .font(BurrowType.hero)
            Text(appState.optimizePlan.map { "\($0.applyCount) potential changes" } ?? "Previewed, bounded maintenance tasks")
                .font(BurrowType.data).foregroundStyle(.white.opacity(0.45))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayTasks) { task in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: task.disposition))
                                .foregroundStyle(task.disposition == .failed ? .orange : atmosphere.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).font(BurrowType.data).foregroundStyle(.white.opacity(0.8))
                                Text(task.detail).font(BurrowType.label).foregroundStyle(.white.opacity(0.3)).lineLimit(1)
                            }
                            Spacer()
                            Text(task.disposition.rawValue.uppercased()).font(BurrowType.label).foregroundStyle(.white.opacity(0.25))
                        }
                        .padding(.horizontal, 16).frame(height: 36)
                    }
                }
            }
            .frame(maxWidth: 540, maxHeight: 280).burrowPanel()
            .overlay {
                if displayTasks.isEmpty {
                    Text(appState.optimizeIsLoading ? "Building a safe preview…" : "Awaiting dry-run preview")
                        .font(BurrowType.data).foregroundStyle(.white.opacity(0.45))
                }
            }

            if let plan = appState.optimizePlan {
                Text("\(plan.metadata.source.label) · PLAN \(plan.metadata.fingerprint.prefix(12)) · NO CHANGES MADE")
                    .font(BurrowType.label).foregroundStyle(atmosphere.accent.opacity(0.8))
            }
            if let error = appState.optimizeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BurrowType.data).foregroundStyle(Color(hex: 0xE6B75F))
            }

            HStack {
                Button(appState.optimizePlan == nil ? "Preview maintenance" : "Refresh preview") {
                    appState.previewOptimize()
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(accent: atmosphere.accent))
                .disabled(appState.optimizeIsLoading)
                if appState.optimizePlan != nil {
                    Button("Optimize now") {
                        guard let model = appState.optimizeExecution else { return }
                        executionModel = model
                        showingRun = true
                    }
                        .buttonStyle(PrimaryCapsuleButtonStyle(accent: atmosphere.accent))
                        .disabled(appState.optimizeExecution == nil)
                }
            }
            Spacer(minLength: 12)
        }
        .sheet(isPresented: $showingRun) {
            if let executionModel, let plan = appState.optimizePlan {
                ExecutionFlowSheet(
                    model: executionModel,
                    currentPreviewFingerprint: plan.metadata.fingerprint,
                    accent: atmosphere.accent
                )
            }
        }
    }

    private var displayTasks: [OptimizePreviewPlan.Task] {
        appState.optimizePlan?.tasks ?? []
    }

    private func icon(for disposition: OptimizePreviewPlan.Disposition) -> String {
        switch disposition {
        case .wouldApply: "sparkles"
        case .unchanged: "checkmark.circle"
        case .skipped: "forward.circle"
        case .unavailable: "questionmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
