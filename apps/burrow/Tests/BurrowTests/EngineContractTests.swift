import Foundation
import Testing
@testable import Burrow

@Suite("Read-only engine contracts")
struct EngineContractTests {
    @Test("Status JSON decodes additive upstream fields")
    func statusDecoding() throws {
        let json = #"""
        {
          "collected_at":"2026-09-03T21:17:58-06:00","host":"test.local","uptime":"3h",
          "hardware":{"model":"MacBook Pro","cpu_model":"Apple M1 Pro","total_ram":"32 GB","os_version":"macOS 14"},
          "health_score":92,"health_score_msg":"Excellent",
          "cpu":{"usage":12.5,"core_count":10,"future_field":true},
          "memory":{"used":100,"total":200,"used_percent":50,"swap_used":0},
          "disks":[{"mount":"/","used":25,"total":100,"used_percent":25,"external":false}],
          "network":[{"name":"en0","rx_rate_mbs":0.5,"tx_rate_mbs":0.25}],
          "batteries":[{"percent":90,"status":"charging","health":"Good","capacity":95}],
          "thermal":{"cpu_temp":42,"fan_speed":0},
          "top_processes":[{"pid":42,"name":"Finder","cpu":3.2,"memory":0.4,"memory_bytes":1024}],
          "unknown_top_level":"accepted"
        }
        """#

        let snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.healthScore == 92)
        #expect(snapshot.cpu.coreCount == 10)
        #expect(snapshot.topProcesses.first?.name == "Finder")
    }

    @Test("Analyze JSON keeps path identity and signed sizes")
    func analyzeDecoding() throws {
        let json = #"""
        {"path":"/tmp","overview":false,"entries":[
          {"name":"Cache","path":"/tmp/Cache","size":2048,"is_dir":true},
          {"name":"note.txt","path":"/tmp/note.txt","size":12,"is_dir":false,"last_access":"today"}
        ],"large_files":[],"total_size":2060,"total_files":2}
        """#

        let report = try JSONDecoder().decode(AnalyzeReport.self, from: Data(json.utf8))
        #expect(report.path == "/tmp")
        #expect(report.entries[0].id == "/tmp/Cache")
        #expect(report.entries[0].isDirectory)
        #expect(report.totalFiles == 2)
    }

    @Test("Byte formatting is human readable")
    func byteFormatting() {
        #expect(ByteFormatter.string(Int64(1_024)).contains("KB"))
    }
}
