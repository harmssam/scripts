import Darwin
import Foundation
import Testing
@testable import Pulse

@Suite("Monitor parsing")
struct MonitorParsingTests {
    @Test("getifaddrs mapper drops loopback and matches sampleRates math")
    func interfaceRatesFromSnapshots() {
        let previousRows: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = [
            ("lo0", 1_000, 1_000),
            ("en0", 1_000_000, 500_000),
        ]
        let currentRows: [(name: String, bytesIn: UInt64, bytesOut: UInt64)] = [
            ("lo0", 9_000, 8_000),
            ("en0", 1_003_000, 506_000),
        ]

        let previousStats = NetworkMonitor.interfaceStats(from: previousRows)
        let currentStats = NetworkMonitor.interfaceStats(from: currentRows)

        #expect(previousStats.contains { $0.name.hasPrefix("lo") } == false)
        #expect(currentStats.contains { $0.name.hasPrefix("lo") } == false)

        let en0 = currentStats.first { $0.name == "en0" }
        #expect(en0?.bytesIn == 1_003_000)
        #expect(en0?.bytesOut == 506_000)

        let previous = Dictionary(uniqueKeysWithValues: previousStats.map { ($0.name, $0) })
        let rates = NetworkMonitor.interfaceRates(current: currentStats, previous: previous, elapsed: 3)
        #expect(rates.bytesIn == 1_000)
        #expect(rates.bytesOut == 2_000)
    }

    @Test("Parses nettop process rows")
    func nettopParsing() async {
        let monitor = NetworkMonitor()
        let output = """
        time,,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch
        Safari.123,1000,2000
        kernel_task.0,0,0
        """

        let stats = await monitor.parseNettopOutput(output)

        #expect(stats["Safari"]?.bytesIn == 1000)
        #expect(stats["Safari"]?.bytesOut == 2000)
        #expect(stats["Safari"]?.pid == 123)
        #expect(stats["kernel_task"] == nil)
    }

    @Test("Formats Mbps from bytes per second")
    func mbpsFormatting() {
        #expect(ByteFormatter.formatMbps(bytesPerSecond: 0) == "0.0")
        #expect(ByteFormatter.formatMbps(bytesPerSecond: 125_000) == "1.0")
        #expect(ByteFormatter.formatMbps(bytesPerSecond: 12_500_000) == "100")
    }

    @Test("Formats compact menu bar Mbps")
    func menuBarMbpsFormatting() {
        #expect(ByteFormatter.formatMenuBarMbps(bytesPerSecond: 0) == "0")
        #expect(ByteFormatter.formatMenuBarMbps(bytesPerSecond: 125_000) == "1.0")
        #expect(ByteFormatter.formatMenuBarMbps(bytesPerSecond: 1_250_000) == "10")
        #expect(ByteFormatter.formatMenuBarMbps(bytesPerSecond: 12_500_000) == "100")
    }

    @Test("Disk statistics dictionary totals match Bytes (Read) and Bytes (Write)")
    func diskStatisticsDictionary() {
        let statistics: [String: Any] = [
            "Bytes (Read)": 472_490_442_752 as UInt64,
            "Bytes (Write)": 191_732_469_760 as UInt64,
        ]
        let totals = DiskMonitor.cumulativeBytes(from: statistics)
        #expect(totals.read == 472_490_442_752)
        #expect(totals.write == 191_732_469_760)
    }

    @Test("Parses ioreg statistics dictionary lines")
    func ioregStatisticsParsing() async {
        let monitor = DiskMonitor()
        let line = """
        "Statistics" = {"Operations (Write)"=8123719,"Bytes (Read)"=472490442752,"Bytes (Write)"=191732469760,"Operations (Read)"=14754103}
        """

        let read = await monitor.parseStatisticValue(in: line, key: "Bytes (Read)")
        let write = await monitor.parseStatisticValue(in: line, key: "Bytes (Write)")

        #expect(read == 472_490_442_752)
        #expect(write == 191_732_469_760)
    }

    @Test("Network process rate divides delta by elapsed seconds")
    func networkProcessRate() {
        #expect(NetworkMonitor.rate(deltaBytes: 3000, elapsed: 3) == 1000)
        #expect(NetworkMonitor.rate(deltaBytes: 1000, elapsed: 0) == 0)
        #expect(NetworkMonitor.rate(deltaBytes: 1000, elapsed: -1) == 0)
    }

    @Test("Failed process sample does not advance the rate timestamp")
    func failedProcessSampleKeepsRateTimestamp() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_003)
        #expect(
            NetworkMonitor.nextRateTimestamp(previous: previous, sampleSucceeded: false, now: now)
                == previous
        )
        #expect(
            NetworkMonitor.nextRateTimestamp(previous: nil, sampleSucceeded: false, now: now) == nil
        )
        #expect(
            NetworkMonitor.nextRateTimestamp(previous: previous, sampleSucceeded: true, now: now)
                == now
        )
    }

    @Test("shouldRefreshProcesses gates interval and in-flight")
    func processRefreshPredicate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recent = now.addingTimeInterval(-0.1)
        let stale = now.addingTimeInterval(-4)
        #expect(
            NetworkMonitor.shouldRefreshProcesses(
                now: now, last: recent, interval: 3, inFlight: false
            ) == false
        )
        #expect(
            NetworkMonitor.shouldRefreshProcesses(
                now: now, last: stale, interval: 3, inFlight: false
            ) == true
        )
        #expect(
            NetworkMonitor.shouldRefreshProcesses(
                now: now, last: stale, interval: 3, inFlight: true
            ) == false
        )
        #expect(
            NetworkMonitor.shouldRefreshProcesses(
                now: now, last: nil, interval: 3, inFlight: false
            ) == true
        )
        #expect(
            NetworkMonitor.shouldRefreshProcesses(
                now: now, last: nil, interval: 3, inFlight: true
            ) == false
        )
    }

    @Test("Memory used is active+wired+compressed; free includes inactive")
    func memoryBucketsFromPageCounts() {
        // Units: `total` is bytes. active/wired/compressed/freePages/inactive/speculative
        // are page counts; `from` multiplies them by getpagesize().
        let pageSize = UInt64(getpagesize())
        let gib: UInt64 = 1 << 30
        func pages(_ gibCount: UInt64) -> UInt64 { gibCount * gib / pageSize }

        let snapshot = MemorySnapshot.from(
            total: 16 * gib,
            active: pages(4),
            wired: pages(2),
            compressed: pages(1),
            freePages: pages(1),
            inactive: pages(8),
            speculative: 0
        )
        #expect(snapshot.used == 7 * gib)
        #expect(snapshot.free == 9 * gib)
        #expect(snapshot.isValid)

        let withSpeculative = MemorySnapshot.from(
            total: 16 * gib,
            active: pages(4),
            wired: pages(2),
            compressed: pages(1),
            freePages: pages(1),
            inactive: pages(8),
            speculative: pages(1)
        )
        #expect(withSpeculative.used == 7 * gib)
        #expect(withSpeculative.free == 10 * gib)
    }

    @Test("Shared process table ranks CPU by pcpu and memory by rss")
    func sharedProcessTableRanking() {
        let output = """
          PID  %CPU    RSS COMM
          452  44.0   1024 WindowServer
          765  23.2    512 Terminal
          100   0.0      8 idle
          999   5.0   8192 Safari
           50   1.0   4096 Mail
        """
        let rows = ProcessTable.parse(output)
        let cpu = ProcessTable.topCPU(rows, limit: 3)
        let memory = ProcessTable.topMemory(rows, limit: 3)

        #expect(cpu.map(\.id) == [452, 765, 999])
        #expect(cpu[0].name == "WindowServer")
        #expect(cpu[0].usage == 0.44)
        #expect(abs(cpu[1].usage - 0.232) < 0.0001)
        #expect(memory.map(\.id) == [999, 50, 452])
        #expect(memory[0].memoryBytes == 8192 * 1024)
        #expect(memory[1].name == "Mail")
    }

    @Test("Disk prune drops previous stats for PIDs missing from the current table")
    func diskPruneMissingPIDs() async {
        let monitor = DiskMonitor()
        await monitor.replacePreviousProcessStats([
            1: (read: 100, write: 10),
            2: (read: 200, write: 20),
        ])
        let table = [ProcessTableRow(pid: 2, cpuPercent: 1, rssKB: 8, name: "keep")]
        _ = await monitor.sampleProcesses(from: table, elapsed: 1)
        #expect(await monitor.previousProcessStatPIDs() == [2])
    }

    @Test("collectDetails(includeProcesses: false) does not sample the process table")
    func collectDetailsSkipsProcessTableWhenClosed() async {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(
            MonitorCollector.shouldSampleProcessTable(
                includeProcesses: false, now: now, last: nil, interval: 3
            ) == false
        )
        #expect(
            MonitorCollector.shouldSampleProcessTable(
                includeProcesses: true, now: now, last: nil, interval: 3
            ) == true
        )
        #expect(
            MonitorCollector.shouldSampleProcessTable(
                includeProcesses: true, now: now, last: now.addingTimeInterval(-0.1), interval: 3
            ) == false
        )
        #expect(
            MonitorCollector.shouldSampleProcessTable(
                includeProcesses: true, now: now, last: now.addingTimeInterval(-4), interval: 3
            ) == true
        )

        let collector = MonitorCollector()
        _ = await collector.collectDetails(includeProcesses: false)
        #expect(await collector.processTableSampleCount == 0)
    }

    @Test("Thermal monitor samples without crashing on Apple Silicon")
    func thermalSampling() async {
        let monitor = ThermalMonitor()
        let snapshot = await monitor.sample()

        if let cpu = snapshot.temp.cpuTemperature {
            #expect(cpu > 15 && cpu < 140)
        }
        for fan in snapshot.fans.fans {
            #expect(fan.currentRPM >= 0)
            if let minR = fan.minRPM, let maxR = fan.maxRPM {
                #expect(minR <= maxR)
            }
        }
    }
}