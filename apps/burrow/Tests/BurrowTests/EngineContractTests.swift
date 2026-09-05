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

    @Test("Engine protocol and client have no mutating execute methods")
    func noMutatingExecuteMethods() throws {
        let _: any EngineClientProtocol = ReadOnlyEngineClient()
        let source = try burrowSource("EngineClient.swift")
        #expect(!source.contains("func executeClean("))
        #expect(!source.contains("func executeOptimize("))
        #expect(!source.contains("func executeUninstall("))
        #expect(source.contains("burrow-plan-v1"))
        #expect(source.contains("guard version.contains(Self.structuredProtocolMarker)"))
    }

    @Test("Clean, optimize, and uninstall argv never launch without a preview or plan flag")
    func mutatingArgvIsGated() throws {
        let files = ["EngineClient.swift", "AppState.swift", "CleanView.swift", "OptimizeView.swift", "AppsView.swift"]
        for file in files {
            try assertSafeMaintenanceArgv(in: burrowSource(file), file: file)
        }
        #expect(
            try MoleEngineClient.uninstallPlanArguments(applicationPaths: ["/Applications/-Example.app"])
                == ["uninstall", "--plan-json", "--", "/Applications/-Example.app"]
        )
    }

    private func burrowSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Burrow/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func assertSafeMaintenanceArgv(in source: String, file: String) throws {
        for command in ["clean", "optimize", "uninstall"] {
            let needle = "[\"\(command)\""
            var searchStart = source.startIndex
            while let start = source.range(of: needle, range: searchStart..<source.endIndex) {
                guard let close = source[start.upperBound...].firstIndex(of: "]") else {
                    Issue.record("Unterminated \(command) argv in \(file)")
                    return
                }
                let literal = String(source[start.lowerBound...close])
                let gated = literal.contains("--dry-run") || literal.contains("--list") || literal.contains("--plan-json")
                #expect(gated, "Bare \(command) argv in \(file): \(literal)")
                searchStart = source.index(after: close)
            }
        }
    }
}

private actor ReadOnlyEngineClient: EngineClientProtocol {
    func availability() async -> EngineAvailability { .unavailable("test") }
    func statusSnapshot() async throws -> StatusSnapshot { throw EngineError.unavailable }
    func analyze(path: String) async throws -> AnalyzeReport { throw EngineError.unavailable }
    func cleanPreview() async throws -> CleanPreviewPlan { throw EngineError.unavailable }
    func optimizePreview() async throws -> OptimizePreviewPlan { throw EngineError.unavailable }
    func uninstallInventory() async throws -> UninstallPreviewPlan { throw EngineError.unavailable }
    func executionPlanCapabilities() async -> ExecutionPlanCapabilities { .unavailable(engineVersion: "test") }
    func executionPlan(for request: ExecutionPlanRequest) async throws -> ExecutionPlan { throw EngineError.unavailable }
}
