import Observation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case space = "Space"
    case woodland = "Woodland"

    var id: Self { self }
}

enum AppSection: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case apps = "Apps"
    case optimize = "Optimize"
    case analyze = "Analyze"
    case status = "Status"

    var id: Self { self }

    var atmosphere: FeatureAtmosphere {
        switch self {
        case .clean: .clean
        case .apps: .apps
        case .optimize: .optimize
        case .analyze: .analyze
        case .status: .status
        }
    }
}

@Observable @MainActor
final class AppState {
    var selection: AppSection = .clean
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appearanceThemeV2") }
    }
    var cleanPhase: CleanPhase = .idle
    var expandedAppID: String?
    var selectedAppIDs: Set<String> = []
    var analyzeSelection = "Library"
    var optimizeRunning = false
    var optimizeStep = 0
    var engineAvailability: EngineAvailability = .checking
    var diskAccess = DiskAccessChecker.currentLevel()
    var statusSnapshot: StatusSnapshot?
    var statusError: String?
    var statusHistory: [String: [Double]] = [:]
    var analyzeReport: AnalyzeReport?
    var analyzeIsScanning = false
    var analyzeError: String?
    var cleanPlan: CleanPreviewPlan?
    var cleanExecution: ExecutionPresentationModel?
    var cleanError: String?
    var optimizePlan: OptimizePreviewPlan?
    var optimizeExecution: ExecutionPresentationModel?
    var optimizeIsLoading = false
    var optimizeError: String?
    var uninstallPlan = PreviewFallbacks.apps(reason: "Loading the read-only application inventory…")
    var appsAreLoading = false
    var appsError: String?
    var appsExecution: ExecutionPresentationModel?
    private(set) var storedReceipts: [StoredOperationReceipt] = []

    private let engine: any EngineClientProtocol
    private let receiptStore: any OperationReceiptStoring
    private var persistedReceiptIDs: Set<UUID> = []
    private var statusTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?
    private var didStartServices = false

    init(
        engine: any EngineClientProtocol = MoleEngineClient(),
        receiptStore: any OperationReceiptStoring = AppState.makeDefaultReceiptStore()
    ) {
        self.engine = engine
        self.receiptStore = receiptStore
        theme = UserDefaults.standard.string(forKey: "appearanceThemeV2")
            .flatMap(AppTheme.init(rawValue:)) ?? .woodland
        if let sectionArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--section=") }),
           let requested = AppSection(rawValue: String(sectionArgument.dropFirst("--section=".count)).capitalized)
        {
            selection = requested
        }
    }

    var cleanFooter: CleanFooterMetrics {
        CleanFooterMetrics(receipts: storedReceipts)
    }

    var atmosphere: FeatureAtmosphere {
        theme == .woodland ? .woodland : selection.atmosphere
    }

    var selectedAppsSize: Double {
        Double(uninstallPlan.applications.filter { selectedAppIDs.contains($0.id) }.compactMap(\.sizeBytes).reduce(0, +)) / 1_000_000_000
    }

    var selectedUninstallPlan: UninstallPreviewPlan {
        uninstallPlan.selecting(ids: selectedAppIDs)
    }

    func previewClean() {
        guard cleanPhase == .idle || cleanPhase == .complete else { return }
        cleanPhase = .scanning(progress: 0.03)
        cleanError = nil
        Task {
            do {
                cleanPlan = try await engine.cleanPreview()
            } catch {
                cleanError = error.localizedDescription
                cleanPlan = nil
            }
            cleanExecution = cleanPlan.flatMap { try? FixtureExecutionPresentationFactory.clean($0, persistReceipt: fixtureReceiptPersister()) }
            cleanPhase = .review
        }
    }

    func previewOptimize() {
        guard !optimizeIsLoading else { return }
        optimizeIsLoading = true
        optimizeError = nil
        Task {
            do {
                optimizePlan = try await engine.optimizePreview()
            } catch {
                optimizeError = error.localizedDescription
                optimizePlan = nil
            }
            optimizeExecution = optimizePlan.flatMap { try? FixtureExecutionPresentationFactory.optimize($0, persistReceipt: fixtureReceiptPersister()) }
            optimizeIsLoading = false
        }
    }

    func startReadOnlyServices() {
        guard !didStartServices else { return }
        didStartServices = true
        diskAccess = DiskAccessChecker.currentLevel()
        Task { await loadStoredReceipts() }
        statusTask = Task {
            engineAvailability = await engine.availability()
            guard case .available = engineAvailability else { return }
            Task { await loadApplicationInventory() }
            while !Task.isCancelled {
                do {
                    let snapshot = try await engine.statusSnapshot()
                    statusSnapshot = snapshot
                    statusError = nil
                    appendHistory("cpu", snapshot.cpu.usage)
                    appendHistory("memory", snapshot.memory.usedPercent)
                    if let network = snapshot.network.first {
                        appendHistory("network", (network.receiveMBs + network.transmitMBs) * 1024)
                    }
                } catch {
                    statusError = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func loadApplicationInventory() async {
        appsAreLoading = true
        do {
            uninstallPlan = try await engine.uninstallInventory()
            appsError = nil
            selectedAppIDs = selectedAppIDs.intersection(Set(uninstallPlan.applications.map(\.id)))
        } catch {
            appsError = error.localizedDescription
            uninstallPlan = PreviewFallbacks.apps(reason: error.localizedDescription)
            selectedAppIDs.removeAll()
        }
        appsAreLoading = false
    }

    func prepareAppsExecution() {
        let selection = selectedUninstallPlan
        appsExecution = try? FixtureExecutionPresentationFactory.uninstall(selection, persistReceipt: fixtureReceiptPersister())
    }

    func refreshStatus() {
        Task {
            do {
                statusSnapshot = try await engine.statusSnapshot()
                statusError = nil
            } catch {
                statusError = error.localizedDescription
            }
        }
    }

    func scan(directory: URL) {
        guard !analyzeIsScanning else { return }
        analyzeIsScanning = true
        analyzeError = nil
        analyzeSelection = directory.path
        analyzeReport = AnalyzeReport(path: directory.path, entries: [], totalSize: 0, totalFiles: 0)
        analyzeTask = Task {
            let hasSecurityScope = directory.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { directory.stopAccessingSecurityScopedResource() }
            }
            do {
                async let finalReport = engine.analyze(path: directory.path)
                for try await preview in ProgressiveDirectoryScanner.scan(directory: directory) {
                    guard !Task.isCancelled else { return }
                    analyzeReport = preview
                }
                analyzeReport = try await finalReport
                analyzeSelection = directory.path
            } catch {
                analyzeError = error.localizedDescription
            }
            analyzeIsScanning = false
        }
    }

    func openAnalyzeEntry(_ entry: AnalyzeReport.Entry) {
        guard entry.isDirectory else { return }
        scan(directory: URL(fileURLWithPath: entry.path))
    }

    func moveAnalyzeSelectionToTrash() throws {
        guard let report = analyzeReport,
              let entry = report.entries.first(where: { $0.path == analyzeSelection }) else { return }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
        analyzeSelection = report.path
        scan(directory: URL(fileURLWithPath: report.path))
    }

    func persistDemoReceipt(_ receipt: OperationReceipt) async {
        guard persistedReceiptIDs.insert(receipt.id).inserted else { return }
        do {
            try await receiptStore.save(receipt, provenance: .fixtureSimulation)
            await loadStoredReceipts()
        } catch {
            persistedReceiptIDs.remove(receipt.id)
        }
    }

    func loadStoredReceipts() async {
        do {
            storedReceipts = try await receiptStore.receipts()
            persistedReceiptIDs.formUnion(storedReceipts.map(\.receipt.id))
        } catch {
            storedReceipts = []
        }
    }

    private func fixtureReceiptPersister() -> (@MainActor (OperationReceipt) async -> Void) {
        { [weak self] receipt in
            await self?.persistDemoReceipt(receipt)
        }
    }

    private static func makeDefaultReceiptStore() -> any OperationReceiptStoring {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burrow", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true)
        return try! FileOperationReceiptStore(directoryURL: directory)
    }

    private func appendHistory(_ key: String, _ value: Double) {
        var values = statusHistory[key, default: []]
        values.append(value)
        statusHistory[key] = Array(values.suffix(24))
    }
}

struct CleanFooterMetrics: Equatable {
    let lastClean: String
    let lifetimeReclaimed: String
    let protectedPaths: String
    let isDemoHistory: Bool

    init(receipts: [StoredOperationReceipt], now: Date = Date()) {
        let latest = receipts.max { lhs, rhs in
            if lhs.receipt.finishedAt == rhs.receipt.finishedAt {
                return lhs.receipt.id.uuidString < rhs.receipt.id.uuidString
            }
            return lhs.receipt.finishedAt < rhs.receipt.finishedAt
        }
        lastClean = latest.map { Self.relativeTime($0.receipt.finishedAt, now: now) } ?? "—"
        let total = receipts.reduce(Int64(0)) { partial, stored in
            guard stored.receipt.outcome == .completed else { return partial }
            return partial + (stored.receipt.completedBytes ?? 0)
        }
        lifetimeReclaimed = total == 0 ? "0 B" : ByteFormatter.string(total)
        protectedPaths = "—"
        isDemoHistory = receipts.contains { $0.provenance == .fixtureSimulation }
    }

    private static func relativeTime(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum ProgressiveDirectoryScanner {
    static func scan(directory: URL) -> AsyncThrowingStream<AnalyzeReport, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
                    let children = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                    )
                    var entries = try children.map { url in
                        let values = try url.resourceValues(forKeys: keys)
                        let isDirectory = values.isDirectory == true
                        let initialSize = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? (isDirectory ? 1 : 0))
                        return AnalyzeReport.Entry(name: url.lastPathComponent, path: url.path, size: max(1, initialSize), isDirectory: isDirectory)
                    }
                    continuation.yield(report(path: directory.path, entries: entries))

                    for index in entries.indices where entries[index].isDirectory {
                        try Task.checkCancellation()
                        entries[index] = AnalyzeReport.Entry(
                            name: entries[index].name,
                            path: entries[index].path,
                            size: directorySize(URL(fileURLWithPath: entries[index].path)),
                            isDirectory: true
                        )
                        continuation.yield(report(path: directory.path, entries: entries))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func report(path: String, entries: [AnalyzeReport.Entry]) -> AnalyzeReport {
        AnalyzeReport(
            path: path,
            entries: entries,
            totalSize: entries.reduce(0) { $0 + $1.size },
            totalFiles: nil
        )
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 1 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return max(1, total)
    }
}

enum CleanPhase: Equatable {
    case idle
    case scanning(progress: Double)
    case review
    case complete
}

struct PresentedExecution: Identifiable {
    let id = UUID()
    let model: ExecutionPresentationModel
    let fingerprint: String
}
