import Foundation

struct RefreshRates: Sendable {
    var downloadRate: UInt64 = 0
    var uploadRate: UInt64 = 0
    var diskReadRate: UInt64 = 0
    var diskWriteRate: UInt64 = 0
}

struct RefreshDetails: Sendable {
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
}

struct ProcessTableRow: Sendable, Equatable {
    var pid: Int32
    var cpuPercent: Double
    var rssKB: UInt64
    var name: String
}

enum ProcessTable {
    static func parse(_ output: String) -> [ProcessTableRow] {
        var rows: [ProcessTableRow] = []
        for line in output.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rssKB = UInt64(parts[2]) else { continue }
            let name = (String(parts[3]) as NSString).lastPathComponent
            rows.append(ProcessTableRow(pid: pid, cpuPercent: cpu, rssKB: rssKB, name: name))
        }
        return rows
    }

    static func topCPU(_ rows: [ProcessTableRow], limit: Int) -> [CPUProcessActivity] {
        rows.filter { $0.cpuPercent > 0 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { CPUProcessActivity(id: $0.pid, name: $0.name, usage: $0.cpuPercent / 100) }
    }

    static func topMemory(_ rows: [ProcessTableRow], limit: Int) -> [MemoryProcessActivity] {
        rows.filter { $0.rssKB > 0 }
            .sorted { $0.rssKB > $1.rssKB }
            .prefix(limit)
            .map { MemoryProcessActivity(id: $0.pid, name: $0.name, memoryBytes: $0.rssKB * 1024) }
    }
}

/// Runs monitor I/O off the MainActor. AppState applies results in short, await-free bursts.
actor MonitorCollector {
    let networkMonitor = NetworkMonitor()
    let diskMonitor = DiskMonitor()
    let cpuMonitor = CPUMonitor()
    let gpuMonitor = GPUMonitor()
    let thermalMonitor = ThermalMonitor()
    let memoryMonitor = MemoryMonitor()
    private var detailsInFlight = false
    private var lastProcessTableSampleTime: Date?
    private var cachedCPUProcesses: [CPUProcessActivity] = []
    private var cachedMemoryProcesses: [MemoryProcessActivity] = []
    private var cachedDiskProcesses: [ProcessActivity] = []
    private let processSampleInterval: TimeInterval = 3
    private(set) var processTableSampleCount = 0

    func beginDetailsIfIdle() -> Bool {
        guard !detailsInFlight else { return false }
        detailsInFlight = true
        return true
    }

    func endDetails() {
        detailsInFlight = false
    }

    func collectRates() async -> RefreshRates {
        async let networkRates = networkMonitor.sampleRates()
        async let diskRates = diskMonitor.sampleRates()
        let rates = await networkRates
        let disk = await diskRates
        return RefreshRates(
            downloadRate: rates.bytesIn,
            uploadRate: rates.bytesOut,
            diskReadRate: disk.read,
            diskWriteRate: disk.write
        )
    }

    nonisolated static func shouldSampleProcessTable(
        includeProcesses: Bool,
        now: Date,
        last: Date?,
        interval: TimeInterval
    ) -> Bool {
        guard includeProcesses else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    func collectDetails(includeProcesses: Bool = true) async -> RefreshDetails {
        CrashReporter.breadcrumb("MonitorCollector: awaiting detail samples")
        async let sampledNetworkProcesses = networkMonitor.sampleProcesses()
        async let sampledGPUProcesses = gpuMonitor.sampleProcesses()
        async let sampledMemorySnapshot = memoryMonitor.sample()
        async let sampledCPUUsage = cpuMonitor.sampleUsage()
        async let sampledGPUSnapshot = gpuMonitor.sample()
        async let thermal = thermalMonitor.sample()

        let now = Date()
        if Self.shouldSampleProcessTable(
            includeProcesses: includeProcesses,
            now: now,
            last: lastProcessTableSampleTime,
            interval: processSampleInterval
        ) {
            await refreshProcessLists(now: now)
        }

        let smc = await thermal
        return RefreshDetails(
            cpuUsage: await sampledCPUUsage,
            cpuProcesses: cachedCPUProcesses,
            gpuSnapshot: await sampledGPUSnapshot,
            gpuProcesses: await sampledGPUProcesses,
            networkProcesses: await sampledNetworkProcesses,
            diskProcesses: cachedDiskProcesses,
            tempSnapshot: smc.temp,
            fanSnapshot: smc.fans,
            memorySnapshot: await sampledMemorySnapshot,
            memoryProcesses: cachedMemoryProcesses
        )
    }

    private func refreshProcessLists(now: Date) async {
        guard let output = try? await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid,pcpu,rss,comm"]
        ) else {
            return
        }
        processTableSampleCount += 1
        let rows = ProcessTable.parse(output)
        let elapsed = lastProcessTableSampleTime.map { max(now.timeIntervalSince($0), 0.001) } ?? 1.0
        lastProcessTableSampleTime = Date()
        cachedCPUProcesses = ProcessTable.topCPU(rows, limit: 5)
        cachedMemoryProcesses = ProcessTable.topMemory(rows, limit: 5)
        cachedDiskProcesses = await diskMonitor.sampleProcesses(from: rows, elapsed: elapsed)
    }

    func purgeMemory(aggressive: Bool) async -> Bool {
        await memoryMonitor.purge(aggressive: aggressive)
    }

    func sampleMemory() async -> MemorySnapshot {
        await memoryMonitor.sample()
    }
}