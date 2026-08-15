import Foundation

struct Fan: Equatable, Sendable, Identifiable {
    let id: Int
    let currentRPM: Double
    let minRPM: Double?
    let maxRPM: Double?

    var percentage: Double? {
        guard let maxRpm = maxRPM, maxRpm > 0 else { return nil }
        let pct = (currentRPM / maxRpm) * 100
        return Swift.min(Swift.max(pct, 0), 100)
    }

    var formatted: String {
        let rpm = SafeNumeric.roundedInt(currentRPM)
        if let pct = percentage, pct.isFinite {
            return "\(rpm) RPM (\(SafeNumeric.roundedInt(pct))%)"
        }
        return "\(rpm) RPM"
    }
}

struct FanSnapshot: Equatable, Sendable {
    let fans: [Fan]

    var isAvailable: Bool { !fans.isEmpty }

    static let unavailable = FanSnapshot(fans: [])
}