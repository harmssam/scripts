import Foundation

struct TempSnapshot: Equatable, Sendable {
    let cpuTemperature: Double? // Celsius
    let gpuTemperature: Double? // Celsius

    var isAvailable: Bool {
        cpuTemperature != nil || gpuTemperature != nil
    }

    static let unavailable = TempSnapshot(cpuTemperature: nil, gpuTemperature: nil)
}