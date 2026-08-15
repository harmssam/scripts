import Foundation

/// Single sequential SMC pass for temperatures and fans.
/// TempMonitor and FanMonitor must not run in parallel — that pattern caused SIGTRAP.
actor ThermalMonitor {
    private var cachedTemp = TempSnapshot.unavailable
    private var cachedFans = FanSnapshot.unavailable
    private var lastSampleTime: Date?
    private let sampleInterval: TimeInterval

    /// Keys that last returned a value in 20...130. Empty means probe the full list.
    private var workingCPUKeys: [String] = []
    private var workingGPUKeys: [String] = []

    private let readFloat: @Sendable (String) async -> Double?
    private let usesExternalProbe: Bool

    private let cpuKeys: [String] = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "TC10", "TC11", "TC12", "TC13", "TC20", "TC21", "TC22", "TC23",
        "TC30", "TC31", "TC32", "TC33", "TC40", "TC41", "TC42", "TC43",
        "TC50", "TC51", "TC52", "TC53",
        "TC0D", "TC0E", "TC0F", "TC0P", "TCAD", "TCXC",
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B"
    ]

    private let gpuKeys: [String] = [
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        "Tg0f", "Tg0j",
        "Tg04", "Tg0C", "Tg0K", "Tg0S",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0d", "Tg0e", "Tg0k",
        "TG0D", "TG0P", "TG0H"
    ]

    init(
        sampleInterval: TimeInterval = 3,
        readFloat: (@Sendable (String) async -> Double?)? = nil
    ) {
        self.sampleInterval = sampleInterval
        self.usesExternalProbe = readFloat != nil
        self.readFloat = readFloat ?? { key in
            await SMCService.shared.readFloat(key: key)
        }
    }

    func sample() async -> (temp: TempSnapshot, fans: FanSnapshot) {
        let now = Date()
        if let lastSample = lastSampleTime,
           now.timeIntervalSince(lastSample) < sampleInterval {
            return (cachedTemp, cachedFans)
        }

        CrashReporter.breadcrumb("ThermalMonitor.sample start")

        if !usesExternalProbe {
            guard await SMCService.shared.isConnected else {
                AppLogger.error("SMC not connected for thermal reading", category: AppLogger.monitor)
                defer { lastSampleTime = Date() }
                return (cachedTemp, cachedFans)
            }
        }

        let temp = await sampleTemperatures()
        let fans = usesExternalProbe ? FanSnapshot.unavailable : await sampleFans()

        cachedTemp = temp
        cachedFans = fans
        lastSampleTime = Date()
        CrashReporter.breadcrumb("ThermalMonitor.sample complete")
        return (temp, fans)
    }

    private func sampleTemperatures() async -> TempSnapshot {
        let cpuProbe = workingCPUKeys.isEmpty ? cpuKeys : workingCPUKeys
        let gpuProbe = workingGPUKeys.isEmpty ? gpuKeys : workingGPUKeys

        let (cpu, cpuHits) = await readMaxTemperature(from: cpuProbe)
        let (gpu, gpuHits) = await readMaxTemperature(from: gpuProbe)

        workingCPUKeys = cpuHits
        workingGPUKeys = gpuHits

        if cpu == nil && gpu == nil {
            AppLogger.debug("No valid temperature readings from SMC", category: AppLogger.monitor)
            return .unavailable
        }
        return TempSnapshot(cpuTemperature: cpu, gpuTemperature: gpu)
    }

    private func readMaxTemperature(from keys: [String]) async -> (Double?, [String]) {
        var maxValue: Double = 0
        var hits: [String] = []
        var seen = Set<String>()
        for key in keys {
            guard seen.insert(key).inserted else { continue }
            guard let value = await readFloat(key) else { continue }
            guard (20.0...130.0).contains(value) else { continue }
            hits.append(key)
            if value > maxValue {
                maxValue = value
            }
        }
        return (maxValue > 0 ? maxValue : nil, hits)
    }

    private func sampleFans() async -> FanSnapshot {
        let fanCount = Int(await SMCService.shared.readUInt8(key: "FNum") ?? 0)
        AppLogger.debug("SMC reported \(fanCount) fans", category: AppLogger.monitor)

        var fans: [Fan] = []
        let maxToProbe = max(fanCount, 2)
        for i in 0..<maxToProbe {
            let base = "F\(i)"
            guard let rpm = await SMCService.shared.readFloat(key: "\(base)Ac") else { continue }

            let minR = await SMCService.shared.readFloat(key: "\(base)Mn")
            let maxR = await SMCService.shared.readFloat(key: "\(base)Mx")

            fans.append(Fan(
                id: i,
                currentRPM: SafeNumeric.sanitized(rpm),
                minRPM: minR.map { SafeNumeric.sanitized($0) },
                maxRPM: maxR.map { SafeNumeric.sanitized($0) }
            ))
        }

        if fans.isEmpty {
            AppLogger.debug("No fan RPM readings from SMC", category: AppLogger.monitor)
        }
        return FanSnapshot(fans: fans)
    }
}
