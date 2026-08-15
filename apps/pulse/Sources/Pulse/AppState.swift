import AppKit
import Foundation
import OSLog

@MainActor
final class AppState: ObservableObject {
    @Published var downloadRate: UInt64 = 0
    @Published var uploadRate: UInt64 = 0
    @Published var diskReadRate: UInt64 = 0
    @Published var diskWriteRate: UInt64 = 0
    @Published var cpuUsage = CPUUsageSample.invalid
    @Published var cpuProcesses: [CPUProcessActivity] = []
    @Published var gpuSnapshot = GPUSnapshot.unavailable
    @Published var gpuProcesses: [GPUProcessActivity] = []
    @Published var networkProcesses: [NetworkProcessActivity] = []
    @Published var diskProcesses: [ProcessActivity] = []
    @Published var tempSnapshot = TempSnapshot.unavailable
    @Published var fanSnapshot = FanSnapshot.unavailable
    @Published var memorySnapshot = MemorySnapshot.unavailable
    @Published var memoryProcesses: [MemoryProcessActivity] = []
    @Published var lastError: String?

    @Published private(set) var networkDownHistory: [Double] = []
    @Published private(set) var networkUpHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var cpuTempHistory: [Double] = []
    @Published private(set) var gpuTempHistory: [Double] = []
    @Published private(set) var memoryUsedHistory: [Double] = []

    private let collector = MonitorCollector()

    private lazy var updateManager = UpdateManager(
        currentVersion: Self.currentAppVersion
    )

    static var currentAppVersion: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback for debug runs of the raw executable (bundle plist may not be loaded)
        if let plistURL = Bundle.main.url(forResource: "Info", withExtension: "plist"),
           let data = try? Data(contentsOf: plistURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let v = dict["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "0.2.14"
    }
    @Published var availableUpdate: AppUpdate?
    @Published var isDownloadingUpdate = false
    @Published var updateProgress: Double = 0
    @Published var updateStatus: String?
    @Published var updateFailed = false

    private var updateTask: Task<Void, Never>?
    private var lastUpdateCheck: Date?
    private let updateCheckInterval: TimeInterval = 3600
    private let updateCheckThrottle: TimeInterval = 15 * 60

    @Published var autoUpdateEnabled: Bool = UserDefaults.standard.bool(forKey: "autoUpdateEnabled") {
        didSet {
            UserDefaults.standard.set(autoUpdateEnabled, forKey: "autoUpdateEnabled")
            if autoUpdateEnabled, availableUpdate != nil, !isDownloadingUpdate {
                startUpdate()
            }
        }
    }

    @Published var aggressivePurge: Bool = UserDefaults.standard.bool(forKey: "aggressivePurge") {
        didSet {
            UserDefaults.standard.set(aggressivePurge, forKey: "aggressivePurge")
        }
    }

    static let fanBoostDurationOptions = [5, 10, 15, 30]

    @Published var fanBoostDurationMinutes: Int = {
        let saved = UserDefaults.standard.integer(forKey: "fanBoostDurationMinutes")
        let fallback = 10
        let options = [5, 10, 15, 30]
        return options.contains(saved) ? saved : fallback
    }() {
        didSet {
            UserDefaults.standard.set(fanBoostDurationMinutes, forKey: "fanBoostDurationMinutes")
        }
    }

    @Published private(set) var isFanBoostActive = false
    @Published private(set) var fanBoostRemainingSeconds: Int?
    @Published private(set) var fanBoostError: String?

    @Published var logLevel: LogLevel = LogLevel.loadSaved() {
        didSet {
            AppLogger.minimumLevel = logLevel
        }
    }

    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isEnabled else { return }
            if !LaunchAtLogin.setEnabled(launchAtLogin) {
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    @Published var isPopoverShown = false {
        didSet {
            if isPopoverShown {
                publishCachedPopoverMetrics()
            }
        }
    }

    @Published var metricCardOrder: [MetricCardKind] = MetricCardKind.loadSavedOrder() {
        didSet {
            MetricCardKind.saveOrder(metricCardOrder)
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var fanBoostTask: Task<Void, Never>?
    private var downHistory = HistoryBuffer()
    private var upHistory = HistoryBuffer()
    private var diskReadHistoryBuffer = HistoryBuffer()
    private var diskWriteHistoryBuffer = HistoryBuffer()
    private var cpuHistoryBuffer = HistoryBuffer()
    private var gpuHistoryBuffer = HistoryBuffer()
    private var cpuTempHistoryBuffer = HistoryBuffer()
    private var gpuTempHistoryBuffer = HistoryBuffer()
    private var memoryUsedHistoryBuffer = HistoryBuffer()

    /// Popover-only metrics collected every refresh but published only while the popover is open.
    /// Avoids SwiftUI re-rendering the hidden hosting view during MainActor suspension at `await`.
    private struct CachedPopoverMetrics {
        var diskReadRate: UInt64 = 0
        var diskWriteRate: UInt64 = 0
        var cpuUsage = CPUUsageSample.invalid
        var cpuProcesses: [CPUProcessActivity] = []
        var gpuSnapshot = GPUSnapshot.unavailable
        var gpuProcesses: [GPUProcessActivity] = []
        var networkProcesses: [NetworkProcessActivity] = []
        var diskProcesses: [ProcessActivity] = []
        var tempSnapshot = TempSnapshot.unavailable
        var fanSnapshot = FanSnapshot.unavailable
        var memorySnapshot = MemorySnapshot.unavailable
        var memoryProcesses: [MemoryProcessActivity] = []
        var lastError: String?
        var networkDownHistory: [Double] = []
        var networkUpHistory: [Double] = []
        var diskReadHistory: [Double] = []
        var diskWriteHistory: [Double] = []
        var cpuHistory: [Double] = []
        var gpuHistory: [Double] = []
        var cpuTempHistory: [Double] = []
        var gpuTempHistory: [Double] = []
        var memoryUsedHistory: [Double] = []
    }

    private var cachedPopoverMetrics = CachedPopoverMetrics()

    let refreshInterval: TimeInterval = 1.0

    var headerSubtitle: String {
        let down = ByteFormatter.formatMenuBarMbps(bytesPerSecond: downloadRate)
        let up = ByteFormatter.formatMenuBarMbps(bytesPerSecond: uploadRate)
        let cpu = cpuUsage.isValid ? PercentFormatter.format(cpuUsage.total) : "—"
        var base = "↓\(down) ↑\(up) Mbps · CPU \(cpu)"
        if let t = tempSnapshot.cpuTemperature, t.isFinite {
            base += " · \(SafeNumeric.roundedInt(t))°C"
        }
        if memorySnapshot.isValid {
            base += " · Free \(ByteFormatter.formatBytes(memorySnapshot.free))"
        }
        return base
    }

    init() {
        checkForUpdates()
        // start() / startMonitoring() called from AppDelegate right after creation
    }

    func start() {
        startMonitoring()
    }

    deinit {
        refreshTask?.cancel()
        updateCheckTask?.cancel()
        updateTask?.cancel()
        fanBoostTask?.cancel()
    }

    private func applyRates(_ rates: RefreshRates) {
        downloadRate = rates.downloadRate
        uploadRate = rates.uploadRate
    }

    private func applyDetails(_ rates: RefreshRates, _ details: RefreshDetails) {
        CrashReporter.breadcrumb("AppState.refresh: applying state")
        var metrics = cachedPopoverMetrics
        metrics.lastError = nil
        metrics.diskReadRate = rates.diskReadRate
        metrics.diskWriteRate = rates.diskWriteRate
        metrics.cpuUsage = details.cpuUsage
        metrics.gpuSnapshot = details.gpuSnapshot
        metrics.tempSnapshot = details.tempSnapshot
        metrics.fanSnapshot = details.fanSnapshot
        metrics.networkProcesses = details.networkProcesses
        metrics.diskProcesses = details.diskProcesses
        metrics.cpuProcesses = details.cpuProcesses
        metrics.gpuProcesses = details.gpuProcesses
        metrics.memorySnapshot = details.memorySnapshot
        metrics.memoryProcesses = details.memoryProcesses
        appendHistoryBuffers(
            using: metrics,
            downloadRate: rates.downloadRate,
            uploadRate: rates.uploadRate
        )
        metrics.networkDownHistory = downHistory.values
        metrics.networkUpHistory = upHistory.values
        metrics.diskReadHistory = diskReadHistoryBuffer.values
        metrics.diskWriteHistory = diskWriteHistoryBuffer.values
        metrics.cpuHistory = cpuHistoryBuffer.values
        metrics.gpuHistory = gpuHistoryBuffer.values
        metrics.cpuTempHistory = cpuTempHistoryBuffer.values
        metrics.gpuTempHistory = gpuTempHistoryBuffer.values
        metrics.memoryUsedHistory = memoryUsedHistoryBuffer.values
        cachedPopoverMetrics = metrics
        if isPopoverShown {
            publishCachedPopoverMetrics()
        }
        CrashReporter.breadcrumb("AppState.refresh: complete")
    }

    private func appendHistoryBuffers(
        using metrics: CachedPopoverMetrics,
        downloadRate: UInt64,
        uploadRate: UInt64
    ) {
        downHistory.append(ByteFormatter.megabitsPerSecond(from: downloadRate))
        upHistory.append(ByteFormatter.megabitsPerSecond(from: uploadRate))
        diskReadHistoryBuffer.append(Double(metrics.diskReadRate))
        diskWriteHistoryBuffer.append(Double(metrics.diskWriteRate))

        if metrics.cpuUsage.isValid {
            cpuHistoryBuffer.append(metrics.cpuUsage.total)
        }

        if let utilization = metrics.gpuSnapshot.utilization {
            gpuHistoryBuffer.append(utilization)
        }

        if let cpuT = metrics.tempSnapshot.cpuTemperature {
            cpuTempHistoryBuffer.append(cpuT)
        }
        if let gpuT = metrics.tempSnapshot.gpuTemperature {
            gpuTempHistoryBuffer.append(gpuT)
        }

        if metrics.memorySnapshot.isValid {
            memoryUsedHistoryBuffer.append(Double(metrics.memorySnapshot.used))
        }
    }

    private func publishCachedPopoverMetrics() {
        let metrics = cachedPopoverMetrics
        diskReadRate = metrics.diskReadRate
        diskWriteRate = metrics.diskWriteRate
        cpuUsage = metrics.cpuUsage
        cpuProcesses = metrics.cpuProcesses
        gpuSnapshot = metrics.gpuSnapshot
        gpuProcesses = metrics.gpuProcesses
        networkProcesses = metrics.networkProcesses
        diskProcesses = metrics.diskProcesses
        tempSnapshot = metrics.tempSnapshot
        fanSnapshot = metrics.fanSnapshot
        memorySnapshot = metrics.memorySnapshot
        memoryProcesses = metrics.memoryProcesses
        lastError = metrics.lastError
        networkDownHistory = metrics.networkDownHistory
        networkUpHistory = metrics.networkUpHistory
        diskReadHistory = metrics.diskReadHistory
        diskWriteHistory = metrics.diskWriteHistory
        cpuHistory = metrics.cpuHistory
        gpuHistory = metrics.gpuHistory
        cpuTempHistory = metrics.cpuTempHistory
        gpuTempHistory = metrics.gpuTempHistory
        memoryUsedHistory = metrics.memoryUsedHistory
    }

    private func startMonitoring() {
        let collector = collector
        let interval = refreshInterval
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                CrashReporter.breadcrumb("AppState.refresh start")

                let deadline = ContinuousClock.now + .seconds(interval)
                let rates = await collector.collectRates()
                await MainActor.run {
                    self.applyRates(rates)
                }

                if await collector.beginDetailsIfIdle() {
                    Task {
                        let details = await collector.collectDetails()
                        await MainActor.run {
                            self.applyDetails(rates, details)
                        }
                        await collector.endDetails()
                    }
                }

                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        }

        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.updateCheckInterval ?? 3600))
                self?.checkForUpdates()
            }
        }
    }

    func checkForUpdatesIfStale(force: Bool = false) {
        if !force,
           let lastUpdateCheck,
           Date().timeIntervalSince(lastUpdateCheck) < updateCheckThrottle {
            return
        }
        checkForUpdates()
    }

    func checkForUpdates() {
        lastUpdateCheck = Date()
        AppLogger.debug("Checking for updates...", category: AppLogger.update)
        Task {
            if let update = await updateManager.checkForUpdate() {
                AppLogger.info("New version found: \(update.version)", category: AppLogger.update)
                await MainActor.run {
                    self.availableUpdate = update
                    if self.autoUpdateEnabled {
                        AppLogger.info("Auto-update is enabled — starting update automatically", category: AppLogger.update)
                        self.startUpdate()
                    } else {
                        AppLogger.debug("Auto-update is disabled — showing manual update button", category: AppLogger.update)
                    }
                }
            } else {
                AppLogger.debug("No update available", category: AppLogger.update)
                await MainActor.run {
                    self.availableUpdate = nil
                }
            }
        }
    }

    func startUpdate() {
        guard let update = availableUpdate, !isDownloadingUpdate else { return }

        updateTask?.cancel()
        AppLogger.info("Starting update to v\(update.version)", category: AppLogger.update)
        isDownloadingUpdate = true
        updateFailed = false
        updateStatus = "Downloading v\(update.version)..."
        updateProgress = 0

        updateTask = Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PulseUpdate-\(UUID().uuidString)")
                AppLogger.debug("Using temp dir: \(tempDir.path)", category: AppLogger.update)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                let zipURL = tempDir.appendingPathComponent("Pulse.zip")

                AppLogger.debug("Downloading from \(update.downloadURL)", category: AppLogger.update)
                try await UpdateDownloader.download(from: update.downloadURL, to: zipURL) { progress in
                    await MainActor.run {
                        if let progress {
                            self.updateProgress = progress
                        }
                    }
                }

                await MainActor.run {
                    self.updateStatus = "Extracting..."
                    self.updateProgress = 0
                }

                let newAppURL = try await UpdateExtractor.extract(zipURL: zipURL, to: tempDir)
                AppLogger.debug("Update package ready at \(newAppURL.path)", category: AppLogger.update)

                await MainActor.run {
                    self.updateStatus = "Installing..."
                    self.isDownloadingUpdate = false
                }
                await self.performUpdateInstall(newAppURL: newAppURL)
            } catch is CancellationError {
                AppLogger.debug("Update cancelled", category: AppLogger.update)
                await MainActor.run {
                    self.isDownloadingUpdate = false
                    self.updateStatus = nil
                }
            } catch {
                AppLogger.error("Update failed: \(error)", category: AppLogger.update)
                await MainActor.run {
                    self.updateStatus = "Update failed"
                    self.updateFailed = true
                    self.isDownloadingUpdate = false
                }
            }
        }
    }

    func retryUpdate() {
        updateFailed = false
        updateStatus = nil
        startUpdate()
    }

    nonisolated static func nextAvailableUpdate(current: AppUpdate?, installSucceeded: Bool) -> AppUpdate? {
        installSucceeded ? nil : current
    }

    private func performUpdateInstall(newAppURL: URL) async {
        let currentAppURL = Bundle.main.bundleURL
        AppLogger.debug("Preparing to replace app at \(currentAppURL.path) with \(newAppURL.path)", category: AppLogger.update)

        let result = await Task.detached {
            UpdateInstaller.install(from: newAppURL, to: currentAppURL)
        }.value

        let succeeded: Bool
        if case .success = result { succeeded = true } else { succeeded = false }
        availableUpdate = Self.nextAvailableUpdate(current: availableUpdate, installSucceeded: succeeded)

        switch result {
        case .success:
            AppLogger.info("Terminating current instance for update", category: AppLogger.update)
            NSApp.terminate(nil)
        case .failure(let error):
            AppLogger.error("Update install failed: \(error)", category: AppLogger.update)
            updateStatus = "Update failed"
            updateFailed = true
        }
    }

    func toggleFanBoost() async {
        if isFanBoostActive {
            await stopFanBoost()
        } else {
            await startFanBoost()
        }
    }

    func startFanBoost() async {
        guard !isFanBoostActive else { return }

        fanBoostError = nil
        let applied = await FanController.shared.applyMaxSpeed()
        guard applied else {
            fanBoostError = "Could not take fan control"
            return
        }

        isFanBoostActive = true
        let duration = TimeInterval(fanBoostDurationMinutes * 60)
        let deadline = Date().addingTimeInterval(duration)
        fanBoostRemainingSeconds = Int(duration.rounded())

        fanBoostTask?.cancel()
        fanBoostTask = Task {
            while !Task.isCancelled, Date() < deadline {
                _ = await FanController.shared.applyMaxSpeed()

                let remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
                await MainActor.run {
                    self.fanBoostRemainingSeconds = remaining > 0 ? remaining : nil
                }

                try? await Task.sleep(for: .seconds(5))
            }

            guard !Task.isCancelled else { return }
            await self.finishFanBoost()
        }
    }

    func stopFanBoost() async {
        fanBoostTask?.cancel()
        fanBoostTask = nil
        await finishFanBoost()
    }

    func restoreFanControlOnExit() async {
        fanBoostTask?.cancel()
        fanBoostTask = nil
        _ = await FanController.shared.restoreAutomatic()
        isFanBoostActive = false
        fanBoostRemainingSeconds = nil
    }

    private func finishFanBoost() async {
        _ = await FanController.shared.restoreAutomatic()
        isFanBoostActive = false
        fanBoostRemainingSeconds = nil
        fanBoostTask = nil
    }

    func purgeMemory() async {
        let aggressive = aggressivePurge
        AppLogger.debug("Purging inactive memory (aggressive: \(aggressive))...", category: AppLogger.monitor)
        let success = await collector.purgeMemory(aggressive: aggressive)
        if success {
            let snapshot = await collector.sampleMemory()
            cachedPopoverMetrics.memorySnapshot = snapshot
            if isPopoverShown {
                memorySnapshot = snapshot
            }
            AppLogger.info("Memory purged. Free: \(ByteFormatter.formatBytes(snapshot.free))", category: AppLogger.monitor)
        } else {
            cachedPopoverMetrics.lastError = "Failed to free memory"
            if isPopoverShown {
                lastError = cachedPopoverMetrics.lastError
            }
            AppLogger.error("Failed to purge memory", category: AppLogger.monitor)
        }
    }
}