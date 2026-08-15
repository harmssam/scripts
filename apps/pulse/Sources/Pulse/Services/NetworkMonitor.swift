import Foundation

actor NetworkMonitor {
    struct InterfaceStats: Sendable {
        let name: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private var previousStats: [String: InterfaceStats] = [:]
    private var previousTimestamp: Date?
    private var previousProcessBytes: [String: (bytesIn: UInt64, bytesOut: UInt64, pid: Int32)] = [:]
    private var cachedProcesses: [NetworkProcessActivity] = []
    private var lastProcessSampleTime: Date?
    private var processSampleInFlight = false
    private let processSampleInterval: TimeInterval = 3
    /// nettop -L 1 routinely takes ~5s on busy systems; keep margin above that.
    private let nettopTimeout: TimeInterval = 10

    func sampleRates() async -> (bytesIn: UInt64, bytesOut: UInt64) {
        let current = await readInterfaceStats()
        let now = Date()

        defer {
            previousStats = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
            previousTimestamp = now
        }

        guard let previousTime = previousTimestamp else {
            return (0, 0)
        }

        let elapsed = now.timeIntervalSince(previousTime)
        guard elapsed > 0 else { return (0, 0) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for stat in current where !stat.name.hasPrefix("lo") {
            guard let previous = previousStats[stat.name] else { continue }

            let deltaIn = stat.bytesIn >= previous.bytesIn ? stat.bytesIn - previous.bytesIn : stat.bytesIn
            let deltaOut = stat.bytesOut >= previous.bytesOut ? stat.bytesOut - previous.bytesOut : stat.bytesOut
            totalIn += Self.rate(deltaBytes: deltaIn, elapsed: elapsed)
            totalOut += Self.rate(deltaBytes: deltaOut, elapsed: elapsed)
        }

        return (totalIn, totalOut)
    }

    func sampleProcesses(limit: Int = 5) async -> [NetworkProcessActivity] {
        let now = Date()
        if let lastSample = lastProcessSampleTime,
           now.timeIntervalSince(lastSample) < processSampleInterval {
            return cachedProcesses
        }
        if processSampleInFlight {
            return cachedProcesses
        }

        processSampleInFlight = true
        defer {
            processSampleInFlight = false
        }

        CrashReporter.breadcrumb("NetworkMonitor.sampleProcesses: nettop start")
        let output: String
        do {
            output = try await ProcessRunner.run(
                executable: "/usr/bin/nettop",
                arguments: [
                    "-P", "-L", "1",
                    "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch",
                    "-t", "external"
                ],
                timeout: nettopTimeout
            )
        } catch {
            AppLogger.debug("nettop failed: \(error)", category: AppLogger.monitor)
            CrashReporter.breadcrumb("NetworkMonitor.sampleProcesses: nettop failed")
            lastProcessSampleTime = Self.nextRateTimestamp(
                previous: lastProcessSampleTime,
                sampleSucceeded: false,
                now: Date()
            )
            return cachedProcesses
        }
        CrashReporter.breadcrumb("NetworkMonitor.sampleProcesses: nettop done")

        let current = parseNettopOutput(output)
        let sampleTime = Date()
        let elapsed = lastProcessSampleTime.map { sampleTime.timeIntervalSince($0) } ?? 0
        var activities: [NetworkProcessActivity] = []

        for (name, bytes) in current {
            guard let previous = previousProcessBytes[name] else { continue }

            let downloadDelta = bytes.bytesIn >= previous.bytesIn ? bytes.bytesIn - previous.bytesIn : bytes.bytesIn
            let uploadDelta = bytes.bytesOut >= previous.bytesOut ? bytes.bytesOut - previous.bytesOut : bytes.bytesOut

            let downloadRate = Self.rate(deltaBytes: downloadDelta, elapsed: elapsed)
            let uploadRate = Self.rate(deltaBytes: uploadDelta, elapsed: elapsed)

            if downloadRate > 0 || uploadRate > 0 {
                activities.append(NetworkProcessActivity(
                    id: bytes.pid,
                    name: name,
                    downloadRate: downloadRate,
                    uploadRate: uploadRate
                ))
            }
        }

        previousProcessBytes = current
        lastProcessSampleTime = Self.nextRateTimestamp(
            previous: lastProcessSampleTime,
            sampleSucceeded: true,
            now: sampleTime
        )

        cachedProcesses = activities
            .sorted { $0.totalRate > $1.totalRate }
            .prefix(limit)
            .map { $0 }
        return cachedProcesses
    }

    private func readInterfaceStats() async -> [InterfaceStats] {
        guard let output = try? await ProcessRunner.run(
            executable: "/usr/sbin/netstat",
            arguments: ["-ib"]
        ) else {
            return []
        }
        return parseNetstatOutput(output)
    }

    func parseNetstatOutput(_ output: String) -> [InterfaceStats] {
        var stats: [String: InterfaceStats] = [:]

        for line in output.components(separatedBy: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 10,
                  let packetsIn = UInt64(columns[4]),
                  let bytesIn = UInt64(columns[6]),
                  let packetsOut = UInt64(columns[7]),
                  let bytesOut = UInt64(columns[9]) else {
                continue
            }

            let name = String(columns[0])
            if var existing = stats[name] {
                existing = InterfaceStats(
                    name: name,
                    bytesIn: existing.bytesIn + bytesIn,
                    bytesOut: existing.bytesOut + bytesOut
                )
                stats[name] = existing
            } else {
                stats[name] = InterfaceStats(name: name, bytesIn: bytesIn, bytesOut: bytesOut)
            }

            _ = packetsIn
            _ = packetsOut
        }

        return Array(stats.values)
    }

    func parseNettopOutput(_ output: String) -> [String: (bytesIn: UInt64, bytesOut: UInt64, pid: Int32)] {
        var result: [String: (bytesIn: UInt64, bytesOut: UInt64, pid: Int32)] = [:]

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("time") || line.contains("state") {
                continue
            }

            let components = line.components(separatedBy: ",")
            guard components.count >= 3 else { continue }

            let processInfo = components[0].trimmingCharacters(in: .whitespaces)
            var processName = processInfo
            var pid: Int32 = 0

            if let dotRange = processInfo.range(of: ".", options: .backwards) {
                processName = String(processInfo[..<dotRange.lowerBound])
                pid = Int32(String(processInfo[dotRange.upperBound...])) ?? 0
            }

            if processName.isEmpty || processName == "kernel_task" {
                continue
            }

            let bytesIn = UInt64(components[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let bytesOut = UInt64(components[2].trimmingCharacters(in: .whitespaces)) ?? 0

            if let existing = result[processName] {
                result[processName] = (existing.bytesIn + bytesIn, existing.bytesOut + bytesOut, existing.pid)
            } else {
                result[processName] = (bytesIn, bytesOut, pid)
            }
        }

        return result
    }

    nonisolated static func rate(deltaBytes: UInt64, elapsed: TimeInterval) -> UInt64 {
        guard elapsed > 0 else { return 0 }
        return UInt64(Double(deltaBytes) / elapsed)
    }

    nonisolated static func nextRateTimestamp(
        previous: Date?,
        sampleSucceeded: Bool,
        now: Date
    ) -> Date? {
        sampleSucceeded ? now : previous
    }
}