import Foundation

struct GPUProcessActivity: Equatable, Identifiable, Sendable {
    let id: Int32
    let name: String
    let usage: Double
    let memoryBytes: UInt64
}

struct GPUSnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let name: String
    let utilization: Double?
    let rendererUtilization: Double?
    let tilerUtilization: Double?
    let memoryUsedBytes: UInt64?
    let memoryLabel: String

    static let unavailable = GPUSnapshot(
        isAvailable: false,
        name: "Unavailable",
        utilization: nil,
        rendererUtilization: nil,
        tilerUtilization: nil,
        memoryUsedBytes: nil,
        memoryLabel: "Shared"
    )
}

struct ParsedAccelerator: Sendable {
    let ioClass: String
    let name: String
    let utilization: Double?
    let rendererUtilization: Double?
    let tilerUtilization: Double?
    let memoryUsedBytes: UInt64?
    let memoryLabel: String
}

enum GPUPerformanceParser {
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    static func parse(ioClass: String, statistics: [String: Any]) -> ParsedAccelerator {
        let utilization = percentValue(statistics["Device Utilization %"] ?? statistics["GPU Activity(%)"])
        let renderer = percentValue(statistics["Renderer Utilization %"])
        let tiler = percentValue(statistics["Tiler Utilization %"])

        let (memoryBytes, memoryLabel) = memoryInfo(from: statistics, appleSilicon: isAppleSilicon)

        return ParsedAccelerator(
            ioClass: ioClass,
            name: gpuName(ioClass: ioClass, statistics: statistics),
            utilization: utilization,
            rendererUtilization: renderer,
            tilerUtilization: tiler,
            memoryUsedBytes: memoryBytes,
            memoryLabel: memoryLabel
        )
    }

    static func selectPrimary(from accelerators: [ParsedAccelerator]) -> GPUSnapshot? {
        guard !accelerators.isEmpty else { return nil }

        let primary = accelerators.max { lhs, rhs in
            (lhs.utilization ?? 0) < (rhs.utilization ?? 0)
        } ?? accelerators[0]

        return GPUSnapshot(
            isAvailable: true,
            name: primary.name,
            utilization: primary.utilization,
            rendererUtilization: primary.rendererUtilization,
            tilerUtilization: primary.tilerUtilization,
            memoryUsedBytes: primary.memoryUsedBytes,
            memoryLabel: primary.memoryLabel
        )
    }

    static func percentValue(_ value: Any?) -> Double? {
        guard let number = numericValue(value), number.isFinite else { return nil }
        let clamped = min(max(number, 0), 100)
        return clamped / 100
    }

    static func gpuName(ioClass: String, statistics: [String: Any]) -> String {
        if let model = statistics["model"] as? String, !model.isEmpty {
            return model
        }

        let lower = ioClass.lowercased()
        if lower.contains("agx") { return "Apple GPU" }
        if lower.contains("amd") { return "AMD GPU" }
        if lower.contains("intel") { return "Intel GPU" }
        if lower.contains("nvidia") || lower.contains("nv") { return "NVIDIA GPU" }
        return "GPU"
    }

    private static func memoryInfo(from statistics: [String: Any], appleSilicon: Bool) -> (UInt64?, String) {
        if let total = numericValue(statistics["VRAM,totalMB"]),
           let free = numericValue(statistics["VRAM,freeMB"]) {
            let usedMB = max(total - free, 0)
            return (UInt64(usedMB * 1_024 * 1_024), "VRAM")
        }

        if let bytes = numericValue(statistics["In use system memory"]) {
            return (UInt64(bytes), appleSilicon ? "Shared" : "Shared")
        }

        return (nil, appleSilicon ? "Shared" : "VRAM")
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let int as Int:
            return Double(int)
        case let int32 as Int32:
            return Double(int32)
        case let uint as UInt64:
            return Double(uint)
        case let double as Double:
            return double
        default:
            return nil
        }
    }
}