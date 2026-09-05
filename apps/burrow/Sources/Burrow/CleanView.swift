import SwiftUI

struct CleanView: View {
    @Environment(AppState.self) private var appState
    @State private var presentedExecution: PresentedExecution?
    private let atmosphere = FeatureAtmosphere.clean

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 6)

            OrbView(atmosphere: atmosphere, progress: scanProgress, size: 245)

            VStack(spacing: 8) {
                Text(primaryValue).font(BurrowType.hero).contentTransition(.numericText())
                Text(secondaryValue)
                    .font(BurrowType.data)
                    .foregroundStyle(.white.opacity(0.48))
            }

            if appState.cleanPhase == .review {
                reviewPanel.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button(actionTitle) { handleAction() }
                    .buttonStyle(PrimaryCapsuleButtonStyle(accent: atmosphere.accent))
                    .disabled(scanProgress != nil)
            }

            if let error = appState.cleanError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BurrowType.data).foregroundStyle(Color(hex: 0xE6B75F))
            }

            Spacer(minLength: 16)

            VStack(spacing: 8) {
                if appState.cleanFooter.isDemoHistory {
                    Text("DEMO HISTORY")
                        .font(BurrowType.label)
                        .foregroundStyle(.white.opacity(0.3))
                }
                HStack(spacing: 28) {
                    footerMetric("Last clean", appState.cleanFooter.lastClean)
                    footerMetric("Lifetime reclaimed", appState.cleanFooter.lifetimeReclaimed)
                    footerMetric("Protected", appState.cleanFooter.protectedPaths)
                }
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 38)
        .animation(.easeInOut(duration: 0.24), value: appState.cleanPhase)
        .sheet(item: $presentedExecution) { presented in
            ExecutionFlowSheet(
                model: presented.model,
                currentPreviewFingerprint: appState.cleanPlan?.metadata.fingerprint ?? presented.fingerprint,
                accent: atmosphere.accent
            )
        }
    }

    private var scanProgress: Double? {
        if case .scanning(let progress) = appState.cleanPhase { return progress }
        return nil
    }

    private var primaryValue: String {
        switch appState.cleanPhase {
        case .idle: "Ready when you are"
        case .scanning(let progress): "\(Int(progress * 100))%"
        case .review: appState.cleanPlan.map { ByteFormatter.string($0.reclaimableBytes) } ?? "Preview ready"
        case .complete: "Preview closed"
        }
    }

    private var secondaryValue: String {
        switch appState.cleanPhase {
        case .idle: "A safe preview always comes first"
        case .scanning: "Mole is scanning in dry-run mode…"
        case .review: "\(appState.cleanPlan?.categories.count ?? 0) categories · \(appState.cleanPlan?.itemCount ?? 0) potential items"
        case .complete: "No cleanup was performed"
        }
    }

    private var actionTitle: String {
        appState.cleanPhase == .complete ? "Scan again" : "Scan this Mac"
    }

    private func handleAction() {
        if appState.cleanPhase == .complete { appState.cleanPhase = .idle }
        appState.previewClean()
    }

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            if let plan = appState.cleanPlan {
            ForEach(Array(plan.categories.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(atmosphere.accent)
                        .frame(width: 28, height: 28)
                        .background(atmosphere.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                    Text(item.title).font(BurrowType.body)
                    Spacer()
                    Text(item.reclaimableBytes.map(ByteFormatter.string) ?? "Review")
                        .font(BurrowType.data).foregroundStyle(.white.opacity(0.68))
                    Image(systemName: "eye.fill").foregroundStyle(atmosphere.accent)
                }
                .padding(.horizontal, 16).frame(height: 44)
                if index < plan.categories.count - 1 { Divider().opacity(0.18).padding(.leading, 56) }
            }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(appState.cleanPlan?.metadata.source.label ?? "PREVIEW") · NO CLEANUP PERFORMED")
                        .font(BurrowType.label).foregroundStyle(atmosphere.accent)
                    Text("Plan \(String(appState.cleanPlan?.metadata.fingerprint.prefix(12) ?? "pending"))")
                        .font(BurrowType.data).foregroundStyle(.white.opacity(0.36))
                }
                Spacer()
                Button("Close preview") { appState.cleanPhase = .complete }.buttonStyle(.plain)
                Button("Clean now") {
                    guard let model = appState.cleanExecution,
                          let fingerprint = appState.cleanPlan?.metadata.fingerprint else { return }
                    presentedExecution = PresentedExecution(model: model, fingerprint: fingerprint)
                }
                    .buttonStyle(PrimaryCapsuleButtonStyle(accent: atmosphere.accent))
                    .disabled(appState.cleanExecution == nil)
            }
            .padding(14)
        }
        .frame(maxWidth: 650)
        .burrowPanel()
    }

    private func footerMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(BurrowType.data).foregroundStyle(.white.opacity(0.72))
            Text(title.uppercased()).font(BurrowType.label).foregroundStyle(.white.opacity(0.3))
        }
    }
}
