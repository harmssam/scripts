import Foundation
import Testing
@testable import Burrow

@Suite("Status metric formatting")
struct StatusMetricsFormattingTests {
    @Test("Network rates and thermal display come from a snapshot")
    func formatsRatesAndThermalFromSnapshot() throws {
        let json = #"""
        {
          "collected_at":"2026-09-03T21:17:58-06:00","host":"test.local","uptime":"3h",
          "hardware":{"model":"MacBook Pro","cpu_model":"Apple M1 Pro","total_ram":"32 GB","os_version":"macOS 14"},
          "health_score":92,"health_score_msg":"Excellent",
          "cpu":{"usage":12.5,"core_count":10},
          "memory":{"used":100,"total":200,"used_percent":50,"swap_used":0},
          "disks":[{"mount":"/","used":25,"total":100,"used_percent":25,"external":false}],
          "network":[{"name":"en0","rx_rate_mbs":0.5,"tx_rate_mbs":0.25}],
          "batteries":[{"percent":90,"status":"charging","health":"Good","capacity":95}],
          "thermal":{"cpu_temp":42,"fan_speed":0},
          "top_processes":[{"pid":42,"name":"Finder","cpu":3.2,"memory":0.4,"memory_bytes":1024}]
        }
        """#

        let snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))
        let network = try #require(snapshot.network.first)
        #expect(StatusMetricsFormatting.cpuBadge(celsius: snapshot.thermal.cpuTemp) == "42°C")
        #expect(StatusMetricsFormatting.cpuBadge(celsius: nil) == "LIVE")
        #expect(StatusMetricsFormatting.rate(network.receiveMBs) == "512 KB/s")
        #expect(StatusMetricsFormatting.rate(network.transmitMBs) == "256 KB/s")
        #expect(StatusMetricsFormatting.rate(1.5) == "1.5 MB/s")
    }
}
