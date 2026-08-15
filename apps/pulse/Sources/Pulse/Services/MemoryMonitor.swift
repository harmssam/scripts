import Darwin
import Foundation

actor MemoryMonitor {
    private var cachedProcesses: [MemoryProcessActivity] = []
    private var lastProcessSampleTime: Date?
    private var processSampleInFlight = false
    private let processSampleInterval: TimeInterval = 3

    func sample() -> MemorySnapshot {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let totalResult = sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard totalResult == 0, total > 0 else {
            return .unavailable
        }

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return .unavailable
        }

        return MemorySnapshot.from(
            total: total,
            active: UInt64(vmStats.active_count),
            wired: UInt64(vmStats.wire_count),
            compressed: UInt64(vmStats.compressor_page_count),
            freePages: UInt64(vmStats.free_count),
            inactive: UInt64(vmStats.inactive_count),
            speculative: UInt64(vmStats.speculative_count)
        )
    }

    func purge(aggressive: Bool = false) async -> Bool {
        let purgePath = "/usr/bin/purge"
        let purgeExists = FileManager.default.fileExists(atPath: purgePath)

        if purgeExists {
            do {
                AppLogger.debug("Running standard purge...", category: AppLogger.monitor)
                _ = try await ProcessRunner.run(executable: purgePath, arguments: [])
                AppLogger.debug("Standard purge succeeded.", category: AppLogger.monitor)
            } catch ProcessRunner.RunnerError.nonZeroExit(let code) {
                AppLogger.debug("purge exited with status \(code) (often harmless)", category: AppLogger.monitor)
            } catch {
                AppLogger.error("Standard purge failed: \(error)", category: AppLogger.monitor)
                if !aggressive {
                    return false
                }
            }
        } else {
            AppLogger.debug("No /usr/bin/purge available on this system.", category: AppLogger.monitor)
            if !aggressive {
                // For standard mode without purge, do a light pressure to at least attempt some release
                AppLogger.debug("Falling back to light memory_pressure for standard purge...", category: AppLogger.monitor)
                do {
                    let pressure = Process()
                    pressure.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
                    pressure.arguments = ["-l", "warn", "-s", "2"]
                    try pressure.run()
                    try await Task.sleep(for: .seconds(3))
                    if pressure.isRunning { pressure.terminate() }
                    AppLogger.debug("Light pressure fallback completed.", category: AppLogger.monitor)
                    return true
                } catch {
                    AppLogger.error("Light fallback failed: \(error)", category: AppLogger.monitor)
                    return false
                }
            }
        }

        if aggressive {
            AppLogger.debug("Performing aggressive memory release via memory_pressure...", category: AppLogger.monitor)
            do {
                let pressure = Process()
                pressure.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
                pressure.arguments = ["-l", "critical", "-s", "5"]
                try pressure.run()

                try await Task.sleep(for: .seconds(6))

                if pressure.isRunning {
                    pressure.terminate()
                }

                if purgeExists {
                    _ = try? await ProcessRunner.run(executable: purgePath, arguments: [])
                }

                AppLogger.debug("Aggressive purge completed.", category: AppLogger.monitor)
            } catch {
                AppLogger.error("Aggressive memory_pressure step failed (non-fatal): \(error)", category: AppLogger.monitor)
            }
            return true
        }

        return true
    }

    func sampleTopMemoryProcesses(limit: Int = 5) async -> [MemoryProcessActivity] {
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
            lastProcessSampleTime = Date()
        }

        guard let output = try? await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid,rss,comm"]
        ) else {
            return cachedProcesses
        }

        var processes: [MemoryProcessActivity] = []

        for line in output.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let rssKB = UInt64(parts[1]) else {
                continue
            }

            let name = (String(parts[2]) as NSString).lastPathComponent
            let bytes = rssKB * 1024

            if bytes > 0 {
                processes.append(MemoryProcessActivity(id: pid, name: name, memoryBytes: bytes))
            }
        }

        cachedProcesses = processes
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(limit)
            .map { $0 }
        return cachedProcesses
    }
}