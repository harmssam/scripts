import AppKit
import SwiftUI

struct AnalyzeView: View {
    @Environment(AppState.self) private var appState
    @State private var deletionCandidate: AnalyzeReport.Entry?
    private let atmosphere = FeatureAtmosphere.analyze

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            HStack {
                Label("Whole Disk", systemImage: "internaldrive")
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Text(appState.analyzeReport?.path ?? appState.analyzeSelection).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text(reportSummary).font(BurrowType.data).foregroundStyle(.white.opacity(0.5))
                Button("Choose Folder") { chooseFolder() }.buttonStyle(.plain).foregroundStyle(atmosphere.accent)
                Button { scanCurrentPath() } label: {
                    appState.analyzeIsScanning ? AnyView(ProgressView().controlSize(.small)) : AnyView(Image(systemName: "arrow.clockwise"))
                }.buttonStyle(.plain).disabled(appState.analyzeIsScanning)
            }
            .font(BurrowType.body).padding(.horizontal, 8)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        OrbView(atmosphere: atmosphere, size: 92)
                        Text("\(appState.analyzeReport?.entries.count ?? 0) items").font(BurrowType.data)
                        Text(appState.analyzeReport.map { "\(ByteFormatter.string($0.totalSize)) scanned" } ?? "Choose a folder to scan").font(BurrowType.label).foregroundStyle(.secondary)
                    }.padding(.vertical, 18).frame(maxWidth: .infinity)

                    Text("CURRENT FOLDER").font(BurrowType.label).foregroundStyle(.white.opacity(0.36)).padding(.horizontal, 14).padding(.bottom, 8)

                    if let report = appState.analyzeReport {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(report.entries) { entry in
                                    Button {
                                        appState.analyzeSelection = entry.path
                                    } label: {
                                        folderRow(
                                            entry.name,
                                            ByteFormatter.string(entry.size),
                                            entry.isDirectory ? "folder.fill" : "doc.fill",
                                            selected: entry.path == appState.analyzeSelection
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                                        if entry.isDirectory { appState.openAnalyzeEntry(entry) }
                                    })
                                }
                            }
                        }
                    }
                    Spacer()
                    if let error = appState.analyzeError {
                        Text(error).font(BurrowType.label).foregroundStyle(Color(hex: 0xE6B75F)).padding(14)
                    } else {
                        Text(appState.analyzeReport == nil ? "Choose a folder to load live data" : "Select an item · Delete moves it to Trash").font(BurrowType.label).foregroundStyle(.white.opacity(0.3)).padding(14)
                    }
                }
                .frame(width: 230).burrowPanel()

                DiskTreemap(
                    entries: appState.analyzeReport?.entries ?? [],
                    selection: $appState.analyzeSelection,
                    onOpen: appState.openAnalyzeEntry
                )
                    .overlay {
                        if appState.analyzeIsScanning {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.large)
                                Text("Analyzing this folder…").font(BurrowType.data)
                            }
                            .padding(22).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .burrowPanel()
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
        .onDeleteCommand { requestDeletion() }
        .alert("Move to Trash?", isPresented: deletionAlertIsPresented, presenting: deletionCandidate) { _ in
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
            Button("OK", role: .destructive) { deleteCandidate() }
                .keyboardShortcut(.defaultAction)
        } message: { entry in
            Text("“\(entry.name)” will be moved to the Trash.")
        }
    }

    private var reportSummary: String {
        guard let report = appState.analyzeReport else { return "No scan loaded" }
        return "\(ByteFormatter.string(report.totalSize)) · \(report.totalFiles ?? 0) files"
    }

    private func folderRow(_ name: String, _ size: String, _ symbol: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(selected ? atmosphere.accent : .white.opacity(0.42)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(BurrowType.body).lineLimit(1)
                Text(size).font(BurrowType.data).foregroundStyle(.white.opacity(0.38))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.22))
        }
        .padding(.horizontal, 14).frame(height: 52)
        .background(selected ? .white.opacity(0.06) : .clear)
    }

    private func scanCurrentPath() {
        let path = appState.analyzeReport?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        appState.scan(directory: URL(fileURLWithPath: path))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.scan(directory: url)
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )
    }

    private func requestDeletion() {
        deletionCandidate = appState.analyzeReport?.entries.first { $0.path == appState.analyzeSelection }
    }

    private func deleteCandidate() {
        do {
            try appState.moveAnalyzeSelectionToTrash()
        } catch {
            appState.analyzeError = "Could not move the item to Trash: \(error.localizedDescription)"
        }
        deletionCandidate = nil
    }
}

struct DiskTreemap: View {
    let entries: [AnalyzeReport.Entry]
    @Binding var selection: String
    let onOpen: (AnalyzeReport.Entry) -> Void

    private let palette: [UInt32] = [
        0xD6AD62, 0xC78345, 0xAA5940, 0x8D697B, 0x6C735A,
        0xA77C52, 0x7A5C46, 0xB56F52, 0x88734E, 0x725E68
    ]

    var body: some View {
        GeometryReader { proxy in
            let tiles = TreemapLayout.tiles(for: entries, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.entry.id) { index, tile in
                    tileView(tile, color: palette[index % palette.count])
                        .frame(width: max(0, tile.rect.width - 2), height: max(0, tile.rect.height - 2))
                        .offset(x: tile.rect.minX + 1, y: tile.rect.minY + 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Disk usage treemap")
    }

    @ViewBuilder
    private func tileView(_ tile: TreemapLayout.Tile, color: UInt32) -> some View {
        let isSelected = selection == tile.entry.path
        Button { selection = tile.entry.path } label: {
            GeometryReader { tileProxy in
                let roomy = tileProxy.size.width >= 110 && tileProxy.size.height >= 70
                let compact = tileProxy.size.width >= 62 && tileProxy.size.height >= 38
                VStack(alignment: .leading, spacing: 3) {
                    if roomy {
                        Image(systemName: tile.entry.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if compact {
                        Text(tile.entry.name)
                            .font(roomy ? BurrowType.title : BurrowType.label)
                            .lineLimit(roomy ? 2 : 1)
                        if roomy {
                            Text(ByteFormatter.string(tile.entry.size))
                                .font(BurrowType.data)
                                .opacity(0.72)
                        }
                    }
                }
                .padding(roomy ? 10 : 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .foregroundStyle(.white.opacity(0.94))
            .background(Color(hex: color).opacity(isSelected ? 0.98 : 0.76))
            .overlay {
                if isSelected {
                    Rectangle().stroke(.white.opacity(0.9), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if tile.entry.isDirectory { onOpen(tile.entry) }
        })
        .help("\(tile.entry.name) — \(ByteFormatter.string(tile.entry.size))\(tile.entry.isDirectory ? " · Double-click to open" : "")")
        .accessibilityLabel("\(tile.entry.name), \(ByteFormatter.string(tile.entry.size))")
        .accessibilityHint(tile.entry.isDirectory ? "Double-click to analyze this folder" : "Selects this file")
    }
}

enum TreemapLayout {
    struct Tile: Equatable {
        let entry: AnalyzeReport.Entry
        let rect: CGRect
    }

    static func tiles(for entries: [AnalyzeReport.Entry], in bounds: CGRect) -> [Tile] {
        let sorted = entries
            .filter { $0.size > 0 }
            .sorted { lhs, rhs in
                lhs.size == rhs.size ? lhs.path < rhs.path : lhs.size > rhs.size
            }
        guard !sorted.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        var result: [Tile] = []
        partition(sorted[...], in: bounds, into: &result)
        return result
    }

    private static func partition(_ entries: ArraySlice<AnalyzeReport.Entry>, in rect: CGRect, into result: inout [Tile]) {
        guard let first = entries.first else { return }
        guard entries.count > 1 else {
            result.append(Tile(entry: first, rect: rect))
            return
        }

        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        let target = Double(total) / 2
        var running: Int64 = 0
        var splitOffset = 1
        var bestDistance = Double.greatestFiniteMagnitude
        for offset in 1..<entries.count {
            running += entries[entries.index(entries.startIndex, offsetBy: offset - 1)].size
            let distance = abs(Double(running) - target)
            if distance <= bestDistance {
                bestDistance = distance
                splitOffset = offset
            } else {
                break
            }
        }

        let splitIndex = entries.index(entries.startIndex, offsetBy: splitOffset)
        let leading = entries[..<splitIndex]
        let trailing = entries[splitIndex...]
        let leadingSize = leading.reduce(Int64(0)) { $0 + $1.size }
        let fraction = CGFloat(Double(leadingSize) / Double(total))

        if rect.width >= rect.height {
            let leadingWidth = rect.width * fraction
            partition(leading, in: CGRect(x: rect.minX, y: rect.minY, width: leadingWidth, height: rect.height), into: &result)
            partition(trailing, in: CGRect(x: rect.minX + leadingWidth, y: rect.minY, width: rect.width - leadingWidth, height: rect.height), into: &result)
        } else {
            let leadingHeight = rect.height * fraction
            partition(leading, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: leadingHeight), into: &result)
            partition(trailing, in: CGRect(x: rect.minX, y: rect.minY + leadingHeight, width: rect.width, height: rect.height - leadingHeight), into: &result)
        }
    }
}
