import SwiftUI

@main
struct BurrowApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Menu("Theme") {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            appState.theme = theme
                        } label: {
                            if appState.theme == theme {
                                Label(theme.rawValue, systemImage: "checkmark")
                            } else {
                                Text(theme.rawValue)
                            }
                        }
                    }
                }
            }
        }

        MenuBarExtra("Burrow", systemImage: "sparkles") {
            MenuBarDashboard()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
