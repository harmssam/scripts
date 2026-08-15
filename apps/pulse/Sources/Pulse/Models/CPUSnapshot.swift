import Foundation

struct CPUTicks: Equatable, Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

struct CPUUsageSample: Equatable, Sendable {
    let total: Double
    let user: Double
    let system: Double
    let idle: Double
    let isValid: Bool

    static let invalid = CPUUsageSample(total: 0, user: 0, system: 0, idle: 0, isValid: false)
}

struct CPUProcessActivity: Equatable, Identifiable, Sendable {
    let id: Int32
    let name: String
    let usage: Double
}

enum CPUUsageCalculator {
    static func usage(current: CPUTicks, previous: CPUTicks) -> CPUUsageSample {
        let userDiff = Double(current.user &- previous.user)
        let systemDiff = Double(current.system &- previous.system)
        let idleDiff = Double(current.idle &- previous.idle)
        let niceDiff = Double(current.nice &- previous.nice)
        let activeDiff = userDiff + systemDiff + niceDiff
        let totalTicks = activeDiff + idleDiff

        guard totalTicks > 0 else { return .invalid }

        let user = userDiff / totalTicks
        let system = systemDiff / totalTicks
        let idle = idleDiff / totalTicks

        return CPUUsageSample(
            total: user + system,
            user: user,
            system: system,
            idle: idle,
            isValid: true
        )
    }
}