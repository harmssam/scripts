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

/// Runs monitor I/O off the MainActor. AppState applies results in short, await-free bursts.
actor MonitorCollector {
    let networkMonitor = NetworkMonitor()
    let diskMonitor = DiskMonitor()
    let cpuMonitor = CPUMonitor()
    let gpuMonitor = GPUMonitor()
    let thermalMonitor = ThermalMonitor()
    let memoryMonitor = MemoryMonitor()
    private var detailsInFlight = false

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

    func collectDetails() async -> RefreshDetails {
        CrashReporter.breadcrumb("MonitorCollector: awaiting detail samples")
        async let sampledNetworkProcesses = networkMonitor.sampleProcesses()
        async let sampledDiskProcesses = diskMonitor.sampleProcesses()
        async let sampledCPUProcesses = cpuMonitor.sampleProcesses()
        async let sampledGPUProcesses = gpuMonitor.sampleProcesses()
        async let sampledMemorySnapshot = memoryMonitor.sample()
        async let sampledMemoryProcesses = memoryMonitor.sampleTopMemoryProcesses()
        async let sampledCPUUsage = cpuMonitor.sampleUsage()
        async let sampledGPUSnapshot = gpuMonitor.sample()
        async let thermal = thermalMonitor.sample()

        let smc = await thermal
        return RefreshDetails(
            cpuUsage: await sampledCPUUsage,
            cpuProcesses: await sampledCPUProcesses,
            gpuSnapshot: await sampledGPUSnapshot,
            gpuProcesses: await sampledGPUProcesses,
            networkProcesses: await sampledNetworkProcesses,
            diskProcesses: await sampledDiskProcesses,
            tempSnapshot: smc.temp,
            fanSnapshot: smc.fans,
            memorySnapshot: await sampledMemorySnapshot,
            memoryProcesses: await sampledMemoryProcesses
        )
    }

    func purgeMemory(aggressive: Bool) async -> Bool {
        await memoryMonitor.purge(aggressive: aggressive)
    }

    func sampleMemory() async -> MemorySnapshot {
        await memoryMonitor.sample()
    }
}