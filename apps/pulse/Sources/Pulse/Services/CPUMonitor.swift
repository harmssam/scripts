import Darwin
import Foundation

actor CPUMonitor {
    private var previousTicks: CPUTicks?

    func sampleUsage() -> CPUUsageSample {
        guard let current = readHostCPULoad() else {
            return .invalid
        }

        defer { previousTicks = current }

        guard let previous = previousTicks else {
            return .invalid
        }

        return CPUUsageCalculator.usage(current: current, previous: previous)
    }

    private func readHostCPULoad() -> CPUTicks? {
        let count = MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var info = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }
}