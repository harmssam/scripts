import Darwin
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
    private var lastProcessAttemptTime: Date?
    private var processSampleInFlight = false
    private let processSampleInterval: TimeInterval = 3
    /// nettop -L 1 routinely takes ~5s on busy systems; keep margin above that.
    private let nettopTimeout: TimeInterval = 10

    func sampleRates() async -> (bytesIn: UInt64, bytesOut: UInt64) {
        let current = readInterfaceStats()
        let now = Date()

        defer {
            previousStats = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
            previousTimestamp = now
        }

        guard let previousTime = previousTimestamp else {
            return (0, 0)
        }

        return Self.interfaceRates(
            current: current,
            previous: previousStats,
            elapsed: now.timeIntervalSince(previousTime)
        )
    }

    func sampleProcesses(limit: Int = 5) -> [NetworkProcessActivity] {
        let now = Date()
        guard Self.shouldRefreshProcesses(
            now: now,
            last: lastProcessAttemptTime,
            interval: processSampleInterval,
            inFlight: processSampleInFlight
        ) else {
            return cachedProcesses
        }

        processSampleInFlight = true
        Task.detached { [self] in
            await self.refreshProcessSample(limit: limit)
        }
        return cachedProcesses
    }

    private func refreshProcessSample(limit: Int) async {
        defer { processSampleInFlight = false }

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
            let failedAt = Date()
            lastProcessAttemptTime = failedAt
            lastProcessSampleTime = Self.nextRateTimestamp(
                previous: lastProcessSampleTime,
                sampleSucceeded: false,
                now: failedAt
            )
            return
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
        lastProcessAttemptTime = sampleTime

        cachedProcesses = activities
            .sorted { $0.totalRate > $1.totalRate }
            .prefix(limit)
            .map { $0 }
    }

    private func readInterfaceStats() -> [InterfaceStats] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return []
        }

        var rows: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = []
        buffer.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            let end = cursor.advanced(by: length)
            while cursor.advanced(by: MemoryLayout<if_msghdr>.size) <= end {
                let hdr = cursor.assumingMemoryBound(to: if_msghdr.self).pointee
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0, cursor.advanced(by: msgLen) <= end else { break }
                if hdr.ifm_type == UInt8(RTM_IFINFO2), msgLen >= MemoryLayout<if_msghdr2>.size {
                    let ifm = cursor.assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(ifm.ifm_index), &nameBuf) != nil {
                        let nul = nameBuf.firstIndex(of: 0) ?? nameBuf.endIndex
                        let name = String(decoding: nameBuf[..<nul].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        let data = ifm.ifm_data
                        rows.append((name, data.ifi_ibytes, data.ifi_obytes))
                    }
                }
                cursor = cursor.advanced(by: msgLen)
            }
        }
        return Self.interfaceStats(from: rows)
    }

    nonisolated static func interfaceStats(
        from rows: [(name: String, bytesIn: UInt64, bytesOut: UInt64)]
    ) -> [InterfaceStats] {
        var stats: [String: InterfaceStats] = [:]
        for row in rows where !row.name.hasPrefix("lo") {
            stats[row.name] = InterfaceStats(name: row.name, bytesIn: row.bytesIn, bytesOut: row.bytesOut)
        }
        return Array(stats.values)
    }

    nonisolated static func interfaceRates(
        current: [InterfaceStats],
        previous: [String: InterfaceStats],
        elapsed: TimeInterval
    ) -> (bytesIn: UInt64, bytesOut: UInt64) {
        guard elapsed > 0 else { return (0, 0) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for stat in current where !stat.name.hasPrefix("lo") {
            guard let previous = previous[stat.name] else { continue }

            let deltaIn = Self.byteDelta(current: stat.bytesIn, previous: previous.bytesIn)
            let deltaOut = Self.byteDelta(current: stat.bytesOut, previous: previous.bytesOut)
            totalIn += Self.rate(deltaBytes: deltaIn, elapsed: elapsed)
            totalOut += Self.rate(deltaBytes: deltaOut, elapsed: elapsed)
        }

        return (totalIn, totalOut)
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

    nonisolated static func byteDelta(current: UInt64, previous: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        if previous <= UInt64(UInt32.max), current <= UInt64(UInt32.max) {
            return (UInt64(1) << 32) - previous + current
        }
        return current
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

    nonisolated static func shouldRefreshProcesses(
        now: Date,
        last: Date?,
        interval: TimeInterval,
        inFlight: Bool
    ) -> Bool {
        if inFlight { return false }
        if let last, now.timeIntervalSince(last) < interval { return false }
        return true
    }
}