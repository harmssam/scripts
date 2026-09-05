import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var appState = appState
        FeatureCanvas(atmosphere: appState.atmosphere, theme: appState.theme, section: appState.selection) {
            VStack(spacing: 0) {
                CapsuleTabBar(selection: $appState.selection)
                    .padding(.top, 22)
                    .padding(.bottom, 10)

                EngineStatusBanner()
                    .padding(.horizontal, 30)
                    .padding(.bottom, 10)

                Group {
                    switch appState.selection {
                    case .clean: CleanView()
                    case .apps: AppsView()
                    case .optimize: OptimizeView()
                    case .analyze: AnalyzeView()
                    case .status: StatusView()
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.24), value: appState.selection)
        .tint(appState.atmosphere.accent)
        .task { appState.startReadOnlyServices() }
    }
}

struct EngineStatusBanner: View {
    @Environment(AppState.self) private var appState
    @State private var showingDiskAccessGuide = false

    var body: some View {
        HStack(spacing: 8) {
            switch appState.engineAvailability {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Connecting to the read-only engine…")
            case .available(let version):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x63D6A4))
                Text(version)
                if appState.diskAccess == .limited {
                    Spacer()
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill").foregroundStyle(Color(hex: 0xE6B75F))
                    Text("Limited disk access")
                    Button("Set up") { showingDiskAccessGuide = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(hex: 0xE6B75F))
                        .accessibilityLabel("Set up Full Disk Access")
                }
            case .unavailable(let message):
                Image(systemName: "bolt.slash.fill").foregroundStyle(Color(hex: 0xE6B75F))
                Text(message)
                Spacer()
                Text("Live data unavailable")
            }
        }
        .font(BurrowType.label)
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 12)
        .frame(maxWidth: 760, minHeight: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.2), in: Capsule())
        .accessibilityElement(children: appState.diskAccess == .limited ? .contain : .combine)
        .sheet(isPresented: $showingDiskAccessGuide) {
            DiskAccessGuide(level: appState.diskAccess)
        }
    }
}

struct CapsuleTabBar: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .foregroundStyle(.black.opacity(0.8))
                .background(.white.opacity(0.92), in: Circle())
                .accessibilityLabel("Burrow")

            ForEach(AppSection.allCases) { section in
                Button(section.rawValue) { selection = section }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selection == section ? .black.opacity(0.85) : .white.opacity(0.56))
                    .padding(.horizontal, 20)
                    .frame(height: 34)
                    .background(selection == section ? .white.opacity(0.94) : .clear, in: Capsule())
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.16), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08)) }
    }
}
