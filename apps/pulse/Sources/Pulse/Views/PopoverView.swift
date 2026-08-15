import AppKit
import SwiftUI

enum PopoverLayout {
    static let width: CGFloat = 340
    static let scrollHeight: CGFloat = 490
}

private struct MetricCardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [MetricCardKind: CGFloat] = [:]

    static func reduce(value: inout [MetricCardKind: CGFloat], nextValue: () -> [MetricCardKind: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PopoverView: View {
    @ObservedObject var appState: AppState
    @StateObject private var dragCoordinator = MetricCardDragCoordinator()
    @State private var draggingCard: MetricCardKind?
    @State private var dropInsertionIndex: Int?
    @State private var cardHeights: [MetricCardKind: CGFloat] = [:]
    @State private var scrollViewportFrame: CGRect = .zero
    @State private var scrollStepIndex: Int = 0
    @State private var dropLandingCard: MetricCardKind?
    @State private var dropLandingSettled = false
    @State private var dropLandingTask: Task<Void, Never>?

    private var autoscrollRailHeight: CGFloat {
        max(56, PopoverLayout.scrollHeight * 0.20)
    }

    private let cardStackSpacing: CGFloat = 12
    private let cardGapHitHeight: CGFloat = 22
    @State private var isQuitHovered = false
    @State private var isSettingsHovered = false
    @State private var showSettings = false

    private var metrics: PopoverMetrics { appState.popoverMetrics }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            cardScroller
            Divider()
            footer
        }
        .frame(width: PopoverLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .pulsePopoverChrome()
        .sheet(isPresented: $showSettings) {
            SettingsView(appState: appState)
        }
    }

    private var updateStatusLabel: String {
        if let status = appState.updateStatus {
            if appState.updateProgress > 0, status.hasPrefix("Downloading") {
                let percent = SafeNumeric.roundedInt(appState.updateProgress * 100)
                return "Downloading \(percent)%"
            }
            return status
        }
        return "Updating..."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Pulse")
                    .font(.headline)
                Spacer()

                if appState.updateFailed, appState.availableUpdate != nil {
                    Button {
                        appState.retryUpdate()
                    } label: {
                        Label("Retry update", systemImage: "arrow.clockwise.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(appState.updateStatus ?? "Update failed — tap to retry")
                } else if !appState.autoUpdateEnabled, let update = appState.availableUpdate {
                    Button {
                        appState.startUpdate()
                    } label: {
                        Label("Update \(update.version)", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("Click to update to version \(update.version)")
                } else if appState.isDownloadingUpdate {
                    HStack(spacing: 4) {
                        if appState.updateProgress > 0 {
                            ProgressView(value: appState.updateProgress)
                                .frame(width: 60)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16)
                        }
                        Text(updateStatusLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                quitButton
            }
            Text(appState.headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var cardScroller: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if appState.isPopoverShown {
                        LazyVStack(spacing: cardStackSpacing) {
                            ScrollViewAnchor(
                                dragCoordinator: dragCoordinator,
                                screenFrame: $scrollViewportFrame
                            )
                            .frame(height: 1)

                            ForEach(Array(appState.metricCardOrder.enumerated()), id: \.element) { index, kind in
                                CardGapDropZone(
                                    insertionIndex: index,
                                    isActive: dropInsertionIndex == index,
                                    isDragging: draggingCard != nil,
                                    hitHeight: cardGapHitHeight,
                                    order: $appState.metricCardOrder,
                                    dragging: $draggingCard,
                                    dropInsertionIndex: $dropInsertionIndex,
                                    dragCoordinator: dragCoordinator
                                )
                                reorderableSection(for: kind, index: index)
                                    .id(kind)
                            }
                            CardGapDropZone(
                                insertionIndex: appState.metricCardOrder.count,
                                isActive: dropInsertionIndex == appState.metricCardOrder.count,
                                isDragging: draggingCard != nil,
                                hitHeight: cardGapHitHeight,
                                order: $appState.metricCardOrder,
                                dragging: $draggingCard,
                                dropInsertionIndex: $dropInsertionIndex,
                                dragCoordinator: dragCoordinator
                            )
                            bottomDropZone
                        }
                        .animation(nil, value: draggingCard)
                    }
                }
                .padding(12)
                .frame(width: PopoverLayout.width)
                .background(scrollGapDropLayer)
                .onPreferenceChange(MetricCardHeightPreferenceKey.self) { heights in
                    cardHeights.merge(heights) { _, new in new }
                }
            }
            .frame(width: PopoverLayout.width, height: PopoverLayout.scrollHeight, alignment: .top)
            .background(AlwaysVisibleScrollBar())
            .overlay {
                ScrollViewportTracker(screenFrame: $scrollViewportFrame)
                    .allowsHitTesting(false)
            }
            .overlay { dragAutoscrollRails }
            .onAppear {
                configureDragCoordinator(scrollProxy: scrollProxy)
            }
            .onChange(of: draggingCard) { _, newValue in
                configureDragCoordinator(scrollProxy: scrollProxy)
                if let kind = newValue,
                   let index = appState.metricCardOrder.firstIndex(of: kind) {
                    dropLandingTask?.cancel()
                    dropLandingCard = nil
                    dropLandingSettled = false
                    scrollStepIndex = index
                    beginDragSession()
                } else {
                    dropInsertionIndex = nil
                    dragCoordinator.reset()
                }
            }
        }
    }

    private func configureDragCoordinator(scrollProxy: ScrollViewProxy) {
        dragCoordinator.configure(
            viewportFrame: { scrollViewportFrame },
            viewportHeight: PopoverLayout.scrollHeight,
            onScrollFallback: { direction in
                let order = appState.metricCardOrder
                guard !order.isEmpty else { return }

                let base = dropInsertionIndex ?? scrollStepIndex
                let nextIndex = max(0, min(order.count - 1, base + direction))
                guard nextIndex != scrollStepIndex else { return }

                scrollStepIndex = nextIndex
                let target = order[nextIndex]
                withAnimation(.easeInOut(duration: 0.22)) {
                    scrollProxy.scrollTo(target, anchor: direction < 0 ? .top : .bottom)
                }
            },
            onCardDropped: { kind in
                triggerDropLanding(for: kind)
            }
        )
    }

    private func triggerDropLanding(for kind: MetricCardKind) {
        dropLandingTask?.cancel()
        dropLandingCard = kind
        dropLandingSettled = false

        dropLandingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(PopoverDropAnimation.landing) {
                dropLandingSettled = true
            }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, dropLandingCard == kind else { return }
            dropLandingCard = nil
            dropLandingSettled = false
        }
    }

    private func cardDragAppearance(for kind: MetricCardKind) -> (opacity: Double, scale: CGFloat) {
        if draggingCard == kind {
            return (0.55, 0.97)
        }
        if dropLandingCard == kind {
            return dropLandingSettled ? (1.0, 1.0) : (1.0, 0.98)
        }
        return (1.0, 1.0)
    }

    private var scrollGapDropLayer: some View {
        Group {
            if draggingCard != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.plainText],
                        delegate: ScrollGapDropDelegate(
                            order: $appState.metricCardOrder,
                            dragging: $draggingCard,
                            dropInsertionIndex: $dropInsertionIndex,
                            dragCoordinator: dragCoordinator
                        )
                    )
            }
        }
    }

    private func beginDragSession() {
        dragCoordinator.beginDragSession(
            order: $appState.metricCardOrder,
            dragging: $draggingCard,
            dropInsertionIndex: $dropInsertionIndex
        )
    }

    private var dragAutoscrollRails: some View {
        Group {
            if draggingCard != nil {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: autoscrollRailHeight)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.plainText],
                            delegate: EdgeAutoscrollDropDelegate(
                                insertionIndex: 0,
                                order: $appState.metricCardOrder,
                                dragging: $draggingCard,
                                dropInsertionIndex: $dropInsertionIndex,
                                dragCoordinator: dragCoordinator
                            )
                        )
                    Spacer()
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(height: autoscrollRailHeight)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.plainText],
                            delegate: EdgeAutoscrollDropDelegate(
                                insertionIndex: appState.metricCardOrder.count,
                                order: $appState.metricCardOrder,
                                dragging: $draggingCard,
                                dropInsertionIndex: $dropInsertionIndex,
                                dragCoordinator: dragCoordinator
                            )
                        )
                }
            }
        }
    }

    private var bottomDropZone: some View {
        Color.clear
            .frame(height: 0)
            .overlay(alignment: .top) {
                if draggingCard != nil {
                    Color.clear
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.plainText],
                            delegate: BottomMetricCardDropDelegate(
                                order: $appState.metricCardOrder,
                                dragging: $draggingCard,
                                dropInsertionIndex: $dropInsertionIndex,
                                dragCoordinator: dragCoordinator
                            )
                        )
                }
            }
            .allowsHitTesting(draggingCard != nil)
    }

    private func reorderableSection(for kind: MetricCardKind, index: Int) -> some View {
        let grabber = CardGrabber(
            kind: kind,
            dragging: $draggingCard,
            onDragBegan: { beginDragSession() }
        )
        let appearance = cardDragAppearance(for: kind)

        return cardContent(for: kind, grabber: AnyView(grabber))
            .opacity(appearance.opacity)
            .scaleEffect(appearance.scale)
            .animation(.easeOut(duration: 0.12), value: draggingCard)
            .animation(PopoverDropAnimation.landing, value: dropLandingSettled)
            .animation(PopoverDropAnimation.landing, value: dropLandingCard)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MetricCardHeightPreferenceKey.self,
                        value: [kind: proxy.size.height]
                    )
                }
            )
            .onDrop(
                of: [.plainText],
                delegate: MetricCardReorderDelegate(
                    card: kind,
                    cardHeight: cardHeights[kind] ?? 120,
                    order: $appState.metricCardOrder,
                    dragging: $draggingCard,
                    dropInsertionIndex: $dropInsertionIndex,
                    dragCoordinator: dragCoordinator
                )
            )
    }

    @ViewBuilder
    private func cardContent(for kind: MetricCardKind, grabber: AnyView) -> some View {
        switch kind {
        case .network: networkCard(grabber: grabber)
        case .disk: diskCard(grabber: grabber)
        case .cpu: cpuCard(grabber: grabber)
        case .gpu: gpuCard(grabber: grabber)
        case .memory: memoryCard(grabber: grabber)
        case .thermal: tempCard(grabber: grabber)
        }
    }

    private func networkCard(grabber: AnyView) -> some View {
        MetricCard(
            title: "Network",
            icon: "network",
            trailingHeader: grabber,
            summary: [
                SummaryItem(label: "Download", value: "\(ByteFormatter.formatMbps(bytesPerSecond: appState.downloadRate)) Mbps", tint: .blue),
                SummaryItem(label: "Upload", value: "\(ByteFormatter.formatMbps(bytesPerSecond: appState.uploadRate)) Mbps", tint: .green)
            ],
            sparklines: [
                SparklineSpec(values: metrics.networkDownHistory, color: .blue, label: "Download"),
                SparklineSpec(values: metrics.networkUpHistory, color: .green, label: "Upload")
            ],
            columns: [
                MetricColumn(title: "Process", width: .flexible, alignment: .leading),
                MetricColumn(title: "↓ Mbps", width: .fixed(52), alignment: .trailing),
                MetricColumn(title: "↑ Mbps", width: .fixed(52), alignment: .trailing)
            ],
            rows: metrics.networkProcesses.map { process in
                [
                    process.name,
                    ByteFormatter.formatMbps(bytesPerSecond: process.downloadRate),
                    ByteFormatter.formatMbps(bytesPerSecond: process.uploadRate)
                ]
            },
            emptyMessage: "No active network traffic"
        )
    }

    private func cpuCard(grabber: AnyView) -> some View {
        MetricCard(
            title: "CPU",
            icon: "cpu",
            trailingHeader: grabber,
            summary: [
                SummaryItem(
                    label: "Total",
                    value: metrics.cpuUsage.isValid ? PercentFormatter.format(metrics.cpuUsage.total) : "—",
                    tint: .red
                ),
                SummaryItem(
                    label: "User",
                    value: metrics.cpuUsage.isValid ? PercentFormatter.format(metrics.cpuUsage.user) : "—",
                    tint: .red.opacity(0.8)
                ),
                SummaryItem(
                    label: "System",
                    value: metrics.cpuUsage.isValid ? PercentFormatter.format(metrics.cpuUsage.system) : "—",
                    tint: .red.opacity(0.6)
                )
            ],
            sparklines: [
                SparklineSpec(values: metrics.cpuHistory, color: .red, label: "Usage")
            ],
            columns: [
                MetricColumn(title: "Process", width: .flexible, alignment: .leading),
                MetricColumn(title: "CPU", width: .fixed(52), alignment: .trailing)
            ],
            rows: metrics.cpuProcesses.map { process in
                [process.name, PercentFormatter.formatDetailed(process.usage)]
            },
            emptyMessage: "No active CPU usage"
        )
    }

    private func gpuCard(grabber: AnyView) -> some View {
        let gpu = metrics.gpuSnapshot

        return MetricCard(
            title: "GPU",
            icon: "display",
            subtitle: gpu.isAvailable ? gpu.name : nil,
            trailingHeader: grabber,
            summary: gpuSummaryItems(for: gpu),
            sparklines: gpu.isAvailable ? [
                SparklineSpec(values: metrics.gpuHistory, color: .indigo, label: "Utilization")
            ] : [],
            columns: [
                MetricColumn(title: "Process", width: .flexible, alignment: .leading),
                MetricColumn(title: "Memory", width: .fixed(64), alignment: .trailing)
            ],
            rows: metrics.gpuProcesses.map { process in
                [
                    process.name,
                    ByteFormatter.formatBytes(process.memoryBytes)
                ]
            },
            emptyMessage: gpu.isAvailable ? "No active GPU clients" : "GPU metrics unavailable on this system"
        )
    }

    private func memoryCard(grabber: AnyView) -> some View {
        let mem = metrics.memorySnapshot
        guard mem.isValid else {
            return AnyView(
                MetricCard(
                    title: "Memory",
                    icon: "memorychip",
                    trailingHeader: grabber,
                    summary: [SummaryItem(label: "Status", value: "Unavailable", tint: .secondary)],
                    sparklines: [],
                    columns: [],
                    rows: [],
                    emptyMessage: "Memory stats unavailable"
                )
            )
        }

        let usedStr = ByteFormatter.formatBytes(mem.used)
        let freeStr = ByteFormatter.formatBytes(mem.free)

        // Compact total for title, e.g. "32GB" or "16.5GB"
        let gib = mem.total / (1024 * 1024 * 1024)
        let rem = mem.total % (1024 * 1024 * 1024)
        let totalDisplay: String
        if rem == 0 {
            totalDisplay = "\(gib)GB"
        } else {
            let totalGB = Double(mem.total) / (1024 * 1024 * 1024)
            totalDisplay = String(format: "%.1fGB", totalGB)
        }

        let topMemory = Array(metrics.memoryProcesses.prefix(5))

        let card = MetricCard(
            title: "Memory (\(totalDisplay))",
            icon: "memorychip",
            trailingHeader: grabber,
            summary: [
                SummaryItem(label: "Used", value: usedStr, tint: .purple),
                SummaryItem(label: "Free", value: freeStr, tint: .purple),
                SummaryItem(label: "Wired", value: ByteFormatter.formatBytes(mem.wired), tint: .purple),
                SummaryItem(label: "Compr.", value: ByteFormatter.formatBytes(mem.compressed), tint: .purple)
            ],
            sparklines: [
                SparklineSpec(values: metrics.memoryUsedHistory, color: .purple, label: "Used")
            ],
            columns: [
                MetricColumn(title: "Process", width: .flexible, alignment: .leading),
                MetricColumn(title: "Memory", width: .fixed(64), alignment: .trailing)
            ],
            rows: topMemory.map { proc in
                [proc.name, ByteFormatter.formatBytes(proc.memoryBytes)]
            },
            emptyMessage: "No significant memory users"
        )

        return AnyView(
            VStack(spacing: 8) {
                card

                Toggle("Aggressive", isOn: $appState.aggressivePurge)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("Simulates critical memory pressure + extra purges. Frees significantly more RAM for large LLMs. Use with care.")

                Button {
                    Task { await appState.purgeMemory() }
                } label: {
                    Label(appState.aggressivePurge ? "Free Memory (Aggressive)" : "Free Memory", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .help(appState.aggressivePurge ? "Aggressive purge: forces kernel to release max possible memory" : "Purge inactive memory (helps free RAM for LLMs)")
            }
        )
    }

    private func tempCard(grabber: AnyView) -> some View {
        let t = metrics.tempSnapshot
        let f = metrics.fanSnapshot

        let summary: [SummaryItem] = [
            SummaryItem(
                label: "CPU",
                value: t.cpuTemperature.map { "\(SafeNumeric.roundedInt($0))°C" } ?? "—",
                tint: .orange
            ),
            SummaryItem(
                label: "GPU",
                value: t.gpuTemperature.map { "\(SafeNumeric.roundedInt($0))°C" } ?? "—",
                tint: .orange.opacity(0.75)
            )
        ]

        let hasCPU = t.cpuTemperature != nil
        let hasGPU = t.gpuTemperature != nil
        let sparklines: [SparklineSpec] = [
            hasCPU ? SparklineSpec(values: metrics.cpuTempHistory, color: .orange, label: "CPU °C") : nil,
            hasGPU ? SparklineSpec(values: metrics.gpuTempHistory, color: .orange.opacity(0.7), label: "GPU °C") : nil
        ].compactMap { $0 }

        let fanContent: AnyView? = f.isAvailable ? AnyView(
            TimelineView(.animation) { context in
                HStack(spacing: 14) {
                    ForEach(f.fans) { fan in
                        FanAnimation(fan: fan, date: context.date)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        ) : nil

        let empty = !t.isAvailable && !f.isAvailable
        let card = MetricCard(
            title: "Thermal",
            icon: "thermometer",
            trailingHeader: grabber,
            summary: summary,
            sparklines: sparklines,
            columns: [],
            rows: [],
            emptyMessage: empty ? "Thermal sensors unavailable" : nil,
            afterSparklines: fanContent
        )

        return AnyView(
            VStack(spacing: 8) {
                card

                if f.isAvailable {
                    HStack(spacing: 8) {
                        Picker("Duration", selection: $appState.fanBoostDurationMinutes) {
                            ForEach(AppState.fanBoostDurationOptions, id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 84)
                        .disabled(appState.isFanBoostActive)
                        .help("How long to keep fans at maximum speed")

                        Button {
                            Task { await appState.toggleFanBoost() }
                        } label: {
                            if appState.isFanBoostActive, let remaining = appState.fanBoostRemainingSeconds {
                                Label("Stop Boost (\(formatBoostCountdown(remaining)))", systemImage: "fanblades.fill")
                                    .font(.caption.weight(.semibold))
                            } else {
                                Label("Boost Fans", systemImage: "fanblades.fill")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .help(appState.isFanBoostActive
                              ? "Stop manual fan boost and return to automatic control"
                              : "Run all fans at 100% before heavy workloads")
                    }

                    if let error = appState.fanBoostError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        )
    }

    private func formatBoostCountdown(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, secs)
        }
        return "\(secs)s"
    }

    private func gpuSummaryItems(for gpu: GPUSnapshot) -> [SummaryItem] {
        guard gpu.isAvailable else {
            return [
                SummaryItem(label: "Status", value: "Unavailable", tint: .secondary)
            ]
        }

        var items = [
            SummaryItem(
                label: "Utilization",
                value: gpu.utilization.map { PercentFormatter.format($0) } ?? "—",
                tint: .indigo
            ),
            SummaryItem(
                label: gpu.memoryLabel,
                value: gpu.memoryUsedBytes.map { ByteFormatter.formatBytes($0) } ?? "—",
                tint: .teal
            )
        ]

        if let renderer = gpu.rendererUtilization, let tiler = gpu.tilerUtilization {
            items.append(
                SummaryItem(
                    label: "Render/Tiler",
                    value: "\(PercentFormatter.format(renderer)) / \(PercentFormatter.format(tiler))",
                    tint: .cyan
                )
            )
        }

        return items
    }

    private func diskCard(grabber: AnyView) -> some View {
        MetricCard(
            title: "Disk",
            icon: "internaldrive",
            trailingHeader: grabber,
            summary: [
                SummaryItem(label: "Read", value: ByteFormatter.formatRate(bytesPerSecond: metrics.diskReadRate), tint: .orange),
                SummaryItem(label: "Write", value: ByteFormatter.formatRate(bytesPerSecond: metrics.diskWriteRate), tint: .purple)
            ],
            sparklines: [
                SparklineSpec(values: metrics.diskReadHistory, color: .orange, label: "Read"),
                SparklineSpec(values: metrics.diskWriteHistory, color: .purple, label: "Write")
            ],
            columns: [
                MetricColumn(title: "Process", width: .flexible, alignment: .leading),
                MetricColumn(title: "Read", width: .fixed(64), alignment: .trailing),
                MetricColumn(title: "Write", width: .fixed(64), alignment: .trailing)
            ],
            rows: metrics.diskProcesses.map { process in
                [
                    process.name,
                    ByteFormatter.formatRate(bytesPerSecond: process.readRate),
                    ByteFormatter.formatRate(bytesPerSecond: process.writeRate)
                ]
            },
            emptyMessage: "No active disk I/O"
        )
    }

    private var footer: some View {
        HStack {
            settingsButton

            if let error = metrics.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
            }

            Spacer()

            Button("Logs") {
                NSWorkspace.shared.selectFile(AppLogger.logFileURL.path, inFileViewerRootedAtPath: "")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .font(.caption2)
            .help("Open Pulse log file")

            Button {
                appState.checkForUpdatesIfStale(force: true)
            } label: {
                Text("v\(AppState.currentAppVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Check for updates")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .imageScale(.small)
                .foregroundStyle(isSettingsHovered ? Color.primary : Color.secondary)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSettingsHovered ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isSettingsHovered = $0 }
        .help("Settings")
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "power")
                .imageScale(.small)
                .foregroundStyle(isQuitHovered ? Color.red : Color.secondary)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isQuitHovered ? Color.red.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .focusable(false)
        .onHover { isQuitHovered = $0 }
        .help("Quit Pulse (⌘Q)")
    }
}

// MARK: - Card components

private struct SparklineSpec {
    let values: [Double]
    let color: Color
    let label: String
}

private struct SummaryItem {
    let label: String
    let value: String
    let tint: Color
}

private struct MetricColumn {
    enum Width {
        case flexible
        case fixed(CGFloat)
    }

    let title: String
    let width: Width
    let alignment: Alignment
}

private struct MetricCard: View {
    let title: String
    let icon: String
    let subtitle: String?
    let summary: [SummaryItem]
    let sparklines: [SparklineSpec]
    let columns: [MetricColumn]
    let rows: [[String]]
    let emptyMessage: String?
    let afterSparklines: AnyView?
    let trailingHeader: AnyView?

    @State private var isProcessListExpanded = false

    init(
        title: String,
        icon: String,
        subtitle: String? = nil,
        trailingHeader: AnyView? = nil,
        summary: [SummaryItem],
        sparklines: [SparklineSpec] = [],
        columns: [MetricColumn],
        rows: [[String]],
        emptyMessage: String? = nil,
        afterSparklines: AnyView? = nil
    ) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.trailingHeader = trailingHeader
        self.summary = summary
        self.sparklines = sparklines
        self.columns = columns
        self.rows = rows
        self.emptyMessage = emptyMessage
        self.afterSparklines = afterSparklines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: icon)
                        .font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if let trailingHeader {
                    trailingHeader
                }
            }

            if !summary.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(summary.enumerated()), id: \.offset) { _, item in
                        summaryTile(item)
                    }
                }
            }

            if !sparklines.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(sparklines.enumerated()), id: \.offset) { _, spec in
                        SparklineView(values: spec.values, color: spec.color, label: spec.label)
                    }
                }
            }

            if let content = afterSparklines {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }

            if columns.isEmpty {
                if let emptyMessage {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            } else {
                processListSection
            }
        }
        .padding(10)
        .pulseCardGlass()
    }

    private var accentColor: Color {
        summary.first?.tint ?? .accentColor
    }

    private var processListLabel: String {
        if rows.isEmpty {
            return "Processes"
        }
        return "Processes (\(rows.count))"
    }

    private var processListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isProcessListExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isProcessListExpanded ? 90 : 0))
                    Text(processListLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isProcessListExpanded ? "Collapse process list" : "Expand process list")

            if isProcessListExpanded {
                if rows.isEmpty {
                    Text(emptyMessage ?? "No activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        tableHeader
                        Divider()
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            tableRow(row, shaded: index.isMultiple(of: 2))
                            if index < rows.count - 1 {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .pulseInsetSurface(cornerRadius: 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func summaryTile(_ item: SummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.value)
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .pulseInsetSurface(cornerRadius: 6)
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                Text(column.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: isFlexible(column) ? .infinity : nil, alignment: column.alignment)
                    .frame(width: fixedWidth(for: column))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tableRow(_ cells: [String], shaded: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let text = index < cells.count ? cells[index] : ""
                Text(text)
                    .font(index == 0 ? .caption : .caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: isFlexible(column) ? .infinity : nil, alignment: column.alignment)
                    .frame(width: fixedWidth(for: column))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(shaded ? Color.primary.opacity(0.04) : .clear)
    }

    private func isFlexible(_ column: MetricColumn) -> Bool {
        if case .flexible = column.width { return true }
        return false
    }

    private func fixedWidth(for column: MetricColumn) -> CGFloat? {
        if case .fixed(let value) = column.width { return value }
        return nil
    }
}