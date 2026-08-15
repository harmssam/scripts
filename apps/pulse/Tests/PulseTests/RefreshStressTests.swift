import Testing
@testable import Pulse

/// Exercises the production refresh pipeline (off-MainActor collect + MainActor apply).
@Suite("Refresh stress", .serialized)
struct RefreshStressTests {
    @Test("Collector sampling survives repeated refresh cycles", arguments: [8, 15])
    func repeatedRefreshCycles(iterations: Int) async {
        let collector = MonitorCollector()

        for cycle in 0..<iterations {
            let rates = await collector.collectRates()
            let details = await collector.collectDetails()
            #expect(rates.downloadRate >= 0)
            _ = details.cpuUsage
            try? await Task.sleep(for: .milliseconds(100))
            if cycle % 5 == 4 {
                try? await Task.sleep(for: .seconds(3.1))
            }
        }
    }

    @Test("collectRates returns while collectDetails is in flight")
    func collectRatesDuringDetails() async {
        let collector = MonitorCollector()
        async let details = collector.collectDetails()
        try? await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        let rates = await collector.collectRates()
        #expect(rates.downloadRate >= 0)
        #expect(start.duration(to: ContinuousClock.now) < .seconds(1))
        _ = await details
    }

    @Test("ProcessRunner handles concurrent subprocess spawns")
    func concurrentProcessRunner() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await ProcessRunner.run(
                        executable: "/bin/ps",
                        arguments: ["-Aceo", "pid,comm"],
                        timeout: 5
                    )
                }
            }
            for try await output in group {
                #expect(!output.isEmpty)
            }
        }
    }

    @Test("ProcessRunner survives nettop overlapping short-lived tools")
    func nettopWithParallelShortTools() async throws {
        for _ in 0..<6 {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await ProcessRunner.run(
                        executable: "/usr/bin/nettop",
                        arguments: [
                            "-P", "-L", "1",
                            "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch",
                            "-t", "external"
                        ],
                        timeout: 10
                    )
                }
                for _ in 0..<3 {
                    group.addTask {
                        try await ProcessRunner.run(
                            executable: "/bin/ps",
                            arguments: ["-Aceo", "pid,comm"],
                            timeout: 5
                        )
                    }
                }
                for try await output in group {
                    #expect(!output.isEmpty)
                }
            }
        }
    }
}