import AppKit
import SwiftUI

struct AppsView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var subtab = "Uninstall"
    @State private var presentedExecution: PresentedExecution?
    private let atmosphere = FeatureAtmosphere.apps

    private var filteredApps: [UninstallPreviewPlan.Application] {
        query.isEmpty ? appState.uninstallPlan.applications : appState.uninstallPlan.applications.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Section", selection: $subtab) {
                    Text("Uninstall").tag("Uninstall")
                    Text("Updates").tag("Updates")
                    Text("Startup").tag("Startup")
                }
                .pickerStyle(.segmented).frame(width: 280)

                Spacer()

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search applications", text: $query).textFieldStyle(.plain).frame(width: 180)
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(.white.opacity(0.055), in: Capsule())
            }

            if subtab == "Uninstall" {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredApps) { app in appRow(app) }
                    }
                }
                .overlay {
                    if appState.appsAreLoading {
                        ProgressView("Loading installed applications…")
                    } else if filteredApps.isEmpty {
                        ContentUnavailableView(
                            appState.appsError == nil ? "No applications found" : "Application inventory unavailable",
                            systemImage: "app.badge",
                            description: Text(appState.appsError ?? "No installed applications match this search.")
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    subtab == "Updates" ? "Updates are unavailable" : "Startup items are unavailable",
                    systemImage: subtab == "Updates" ? "arrow.triangle.2.circlepath" : "power",
                    description: Text("This feature is not implemented in this build.")
                )
                .frame(maxHeight: .infinity)
            }

            selectionBar
        }
        .padding(.horizontal, 30).padding(.bottom, 24)
        .onChange(of: appState.selectedAppIDs) { _, _ in
            appState.prepareAppsExecution()
        }
        .sheet(item: $presentedExecution) { presented in
            ExecutionFlowSheet(
                model: presented.model,
                currentPreviewFingerprint: appState.selectedUninstallPlan.metadata.fingerprint,
                accent: atmosphere.accent
            )
        }
    }

    private func appRow(_ app: UninstallPreviewPlan.Application) -> some View {
        let selected = appState.selectedAppIDs.contains(app.id)
        let expanded = appState.expandedAppID == app.id
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable().scaledToFit()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(BurrowType.title)
                    Text("\(app.source) · \(app.bundleID)")
                        .font(BurrowType.data).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Text(app.sizeBytes.map(ByteFormatter.string) ?? app.displaySize)
                    .font(BurrowType.data).foregroundStyle(.white.opacity(0.7))
                Button { appState.expandedAppID = expanded ? nil : app.id } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(expanded ? "Collapse details for \(app.name)" : "Expand details for \(app.name)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the application path and explains the current inventory limits.")
                Toggle("Select \(app.name)", isOn: Binding(
                    get: { selected },
                    set: { isSelected in
                        if isSelected { appState.selectedAppIDs.insert(app.id) }
                        else { appState.selectedAppIDs.remove(app.id) }
                    }
                )).labelsHidden().toggleStyle(.checkbox)
            }
            .padding(14)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details for \(app.name)")
                        .font(BurrowType.label)
                        .accessibilityAddTraits(.isHeader)
                    detailRow("Application", app.path, app.sizeBytes)
                    Text("Inventory evidence only. Related files require Mole's future structured uninstall-plan protocol.")
                        .font(BurrowType.data).foregroundStyle(.white.opacity(0.32)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 70).padding(.bottom, 16)
                .accessibilityElement(children: .contain)
            }
        }
        .burrowPanel()
    }

    private func detailRow(_ label: String, _ path: String, _ size: Int64?) -> some View {
        HStack {
            Image(systemName: "checkmark.square.fill").foregroundStyle(atmosphere.accent)
            Text(label).font(BurrowType.body).frame(width: 135, alignment: .leading)
            Text(path).font(BurrowType.data).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            Spacer()
            Text(size.map(ByteFormatter.string) ?? "Size unavailable").font(BurrowType.data)
        }
    }

    private var selectionBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appState.selectedAppIDs.count) selected · \(appState.selectedAppsSize, specifier: "%.2f") GB known")
                    .font(BurrowType.data).foregroundStyle(.white.opacity(0.65))
                Text("\(appState.uninstallPlan.metadata.source.label) · selection \(appState.selectedUninstallPlan.metadata.fingerprint.prefix(10))")
                    .font(BurrowType.label).foregroundStyle(atmosphere.accent.opacity(0.8))
            }
            Spacer()
            Button("Clear") { appState.selectedAppIDs.removeAll() }.buttonStyle(.plain).foregroundStyle(atmosphere.accent)
            Button("Uninstall") {
                appState.prepareAppsExecution()
                guard let model = appState.appsExecution else { return }
                presentedExecution = PresentedExecution(
                    model: model,
                    fingerprint: appState.selectedUninstallPlan.metadata.fingerprint
                )
            }
                .buttonStyle(PrimaryCapsuleButtonStyle(accent: atmosphere.accent))
                .disabled(appState.selectedAppIDs.isEmpty || appState.appsExecution == nil)
        }
        .padding(.leading, 12)
    }
}
