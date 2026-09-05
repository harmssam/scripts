import AppKit
import SwiftUI

struct MenuBarDashboard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let snapshot = appState.statusSnapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.map { String($0.healthScore) } ?? "—").font(BurrowType.metric)
                Text(snapshot?.healthMessage ?? "Waiting for Mole status").font(BurrowType.data).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                compactMetric("CPU", snapshot.map { "\(Int($0.cpu.usage.rounded()))%" } ?? "—", 0x63D6A4)
                compactMetric("MEM", snapshot.map { "\(Int($0.memory.usedPercent.rounded()))%" } ?? "—", 0xE6D27A)
                compactMetric("DISK", snapshot?.disks.first.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—", 0x7DAAF2)
            }
            Divider()
            VStack(spacing: 7) {
                menuRow("Network", "↓ 8 · ↑ 3 KB/s")
                menuRow("Battery", snapshot?.batteries.first.map { "\(Int($0.percent))% · \($0.health.lowercased())" } ?? "—")
                menuRow("Top process", snapshot?.topProcesses.first.map { "\($0.name) · \(Int($0.cpu))%" } ?? "—")
            }
            Divider()
            HStack {
                Button("Open Status") {
                    appState.selection = .status
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14).frame(width: 330)
    }

    private func compactMetric(_ name: String, _ value: String, _ color: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(BurrowType.label).foregroundStyle(Color(hex: color))
            Text(value).font(BurrowType.title)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).burrowPanel()
    }

    private func menuRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(BurrowType.data)
        }.font(BurrowType.body)
    }
}
