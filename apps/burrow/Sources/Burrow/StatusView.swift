import SwiftUI

struct StatusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                HealthCard(snapshot: appState.statusSnapshot)
                ForEach(statusMetrics) { metric in MetricCard(metric: metric) }
            }
            if let error = appState.statusError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BurrowType.data).foregroundStyle(Color(hex: 0xE6B75F))
            }
            ProcessTable(processes: appState.statusSnapshot?.topProcesses ?? [])
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
    }

    private var statusMetrics: [DemoMetric] {
        guard let snapshot = appState.statusSnapshot else { return [] }
        let disk = snapshot.disks.first { !$0.external } ?? snapshot.disks.first
        let network = snapshot.network.first
        let battery = snapshot.batteries.first
        return [
            DemoMetric(name: "CPU", value: "\(Int(snapshot.cpu.usage.rounded()))%", detail: "\(snapshot.cpu.coreCount) cores", symbol: "cpu", tintHex: 0x63D6A4, samples: appState.statusHistory["cpu"] ?? [snapshot.cpu.usage]),
            DemoMetric(name: "Memory", value: "\(Int(snapshot.memory.usedPercent.rounded()))%", detail: "\(ByteFormatter.string(snapshot.memory.used)) · \(ByteFormatter.string(snapshot.memory.swapUsed)) swap", symbol: "memorychip", tintHex: 0xE6D27A, samples: appState.statusHistory["memory"] ?? [snapshot.memory.usedPercent]),
            DemoMetric(name: "Disk", value: disk.map { ByteFormatter.string($0.total - $0.used) } ?? "—", detail: disk.map { "free · \(Int($0.usedPercent.rounded()))% used" } ?? "Unavailable", symbol: "internaldrive", tintHex: 0x7DAAF2, samples: [disk?.usedPercent ?? 0]),
            DemoMetric(name: "Network", value: network.map { Self.rate($0.receiveMBs + $0.transmitMBs) } ?? "—", detail: network.map { "\($0.name) · live" } ?? "Unavailable", symbol: "network", tintHex: 0x60B8E8, samples: appState.statusHistory["network"] ?? [0]),
            DemoMetric(name: "Battery", value: battery.map { "\(Int($0.percent))%" } ?? "—", detail: battery.map { "\($0.health) · \($0.status)" } ?? "No battery", symbol: "battery.100percent", tintHex: 0x5FD49A, samples: [battery?.percent ?? 0])
        ]
    }

    private static func rate(_ megabytes: Double) -> String {
        megabytes < 1 ? "\(Int((megabytes * 1024).rounded())) KB/s" : String(format: "%.1f MB/s", megabytes)
    }
}

struct HealthCard: View {
    let snapshot: StatusSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("HEALTH", systemImage: "sun.max.fill").font(BurrowType.label).foregroundStyle(Color(hex: 0x66D8A4))
                Spacer()
                Text(snapshot.map { "\($0.hardware.cpuModel) · \($0.hardware.totalRAM)" } ?? "WAITING FOR MO").font(BurrowType.label).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.map { String($0.healthScore) } ?? "—").font(BurrowType.metric).contentTransition(.numericText())
                Text(snapshot == nil ? "Loading" : "Live").font(BurrowType.data).foregroundStyle(.white.opacity(0.48))
            }
            Text(snapshot?.healthMessage ?? "Waiting for live status data").font(BurrowType.body).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            Spacer()
            Text(snapshot.map { "up \($0.uptime) · \($0.hardware.osVersion)" } ?? "mo status --json").font(BurrowType.data).foregroundStyle(.white.opacity(0.33)).lineLimit(1)
        }
        .padding(16).frame(minHeight: 150).burrowPanel()
    }
}

struct MetricCard: View {
    let metric: DemoMetric
    private var tint: Color { Color(hex: metric.tintHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(metric.name.uppercased(), systemImage: metric.symbol).font(BurrowType.label).foregroundStyle(tint)
                Spacer()
                Text(metric.name == "CPU" ? "44°C" : "LIVE").font(BurrowType.label).foregroundStyle(tint.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 3).background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(metric.value).font(BurrowType.metric)
            Sparkline(samples: metric.samples, color: tint).frame(height: 28)
            Spacer(minLength: 0)
            Text(metric.detail).font(BurrowType.data).foregroundStyle(.white.opacity(0.38))
        }
        .padding(16).frame(minHeight: 150).burrowPanel()
    }
}

struct Sparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let maxValue = samples.max() ?? 1
            let minValue = samples.min() ?? 0
            let range = max(maxValue - minValue, 1)
            Path { path in
                for (index, value) in samples.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(max(samples.count - 1, 1))
                    let y = geometry.size.height * (1 - CGFloat((value - minValue) / range))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

struct ProcessTable: View {
    let processes: [StatusSnapshot.ProcessInfo]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 90, alignment: .trailing)
                Text("CPU").frame(width: 90, alignment: .trailing)
                Text("MEMORY").frame(width: 110, alignment: .trailing)
            }.font(BurrowType.label).foregroundStyle(.white.opacity(0.34)).padding(.horizontal, 14).frame(height: 32)
            Divider().opacity(0.2)
            if processes.isEmpty {
                Text("Waiting for live process data…").font(BurrowType.data).foregroundStyle(.secondary).frame(height: 44)
            } else {
                ForEach(processes.prefix(5)) { process in
                    processRow(process.name, String(process.pid), String(format: "%.1f", process.cpu), ByteFormatter.string(process.memoryBytes))
                }
            }
        }.burrowPanel()
    }

    private func processRow(_ name: String, _ pid: String, _ cpu: String, _ memory: String) -> some View {
        HStack {
            Label(name, systemImage: "app.fill").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(pid).frame(width: 90, alignment: .trailing)
            Text("\(cpu)%").frame(width: 90, alignment: .trailing)
            Text(memory).frame(width: 110, alignment: .trailing)
        }.font(BurrowType.data).foregroundStyle(.white.opacity(0.66)).padding(.horizontal, 14).frame(height: 34)
    }
}
