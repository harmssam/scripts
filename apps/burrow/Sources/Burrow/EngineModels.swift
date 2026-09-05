import Foundation

struct StatusSnapshot: Decodable, Sendable, Equatable {
    struct Hardware: Decodable, Sendable, Equatable {
        let model: String
        let cpuModel: String
        let totalRAM: String
        let osVersion: String

        enum CodingKeys: String, CodingKey {
            case model
            case cpuModel = "cpu_model"
            case totalRAM = "total_ram"
            case osVersion = "os_version"
        }
    }

    struct CPU: Decodable, Sendable, Equatable {
        let usage: Double
        let coreCount: Int
        enum CodingKeys: String, CodingKey { case usage; case coreCount = "core_count" }
    }

    struct Memory: Decodable, Sendable, Equatable {
        let used: UInt64
        let total: UInt64
        let usedPercent: Double
        let swapUsed: UInt64
        enum CodingKeys: String, CodingKey {
            case used, total
            case usedPercent = "used_percent"
            case swapUsed = "swap_used"
        }
    }

    struct Disk: Decodable, Sendable, Equatable {
        let mount: String
        let used: UInt64
        let total: UInt64
        let usedPercent: Double
        let external: Bool
        enum CodingKeys: String, CodingKey {
            case mount, used, total, external
            case usedPercent = "used_percent"
        }
    }

    struct Network: Decodable, Sendable, Equatable {
        let name: String
        let receiveMBs: Double
        let transmitMBs: Double
        enum CodingKeys: String, CodingKey {
            case name
            case receiveMBs = "rx_rate_mbs"
            case transmitMBs = "tx_rate_mbs"
        }
    }

    struct Battery: Decodable, Sendable, Equatable {
        let percent: Double
        let status: String
        let health: String
        let capacity: Int
    }

    struct Thermal: Decodable, Sendable, Equatable {
        let cpuTemp: Double
        let fanSpeed: Int
        enum CodingKeys: String, CodingKey { case cpuTemp = "cpu_temp"; case fanSpeed = "fan_speed" }
    }

    struct ProcessInfo: Decodable, Sendable, Equatable, Identifiable {
        let pid: Int
        let name: String
        let cpu: Double
        let memory: Double
        let memoryBytes: UInt64
        var id: Int { pid }
        enum CodingKeys: String, CodingKey {
            case pid, name, cpu, memory
            case memoryBytes = "memory_bytes"
        }
    }

    let collectedAt: String
    let host: String
    let uptime: String
    let hardware: Hardware
    let healthScore: Int
    let healthMessage: String
    let cpu: CPU
    let memory: Memory
    let disks: [Disk]
    let network: [Network]
    let batteries: [Battery]
    let thermal: Thermal
    let topProcesses: [ProcessInfo]

    enum CodingKeys: String, CodingKey {
        case host, uptime, hardware, cpu, memory, disks, network, batteries, thermal
        case collectedAt = "collected_at"
        case healthScore = "health_score"
        case healthMessage = "health_score_msg"
        case topProcesses = "top_processes"
    }
}

struct AnalyzeReport: Decodable, Sendable, Equatable {
    struct Entry: Decodable, Sendable, Equatable, Identifiable {
        let name: String
        let path: String
        let size: Int64
        let isDirectory: Bool
        var id: String { path }
        enum CodingKeys: String, CodingKey {
            case name, path, size
            case isDirectory = "is_dir"
        }
    }

    let path: String
    let entries: [Entry]
    let totalSize: Int64
    let totalFiles: Int64?

    enum CodingKeys: String, CodingKey {
        case path, entries
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }
}

enum EngineAvailability: Equatable, Sendable {
    case checking
    case available(version: String)
    case unavailable(String)
}

enum DiskAccessLevel: Equatable, Sendable {
    case full
    case limited
}

enum EngineError: LocalizedError, Equatable, Sendable {
    case unavailable
    case launchFailed(String)
    case commandFailed(Int32, String)
    case malformedOutput(String)
    case incompatibleVersion(String)
    case unsupportedCapability(String)
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Mole CLI was not found. Install it with Homebrew to enable live data."
        case .launchFailed(let message): "Could not start the preview engine: \(message)"
        case .commandFailed(let code, let message): "The engine stopped with code \(code): \(message)"
        case .malformedOutput(let message): "The engine returned data Burrow could not read: \(message)"
        case .incompatibleVersion(let version): "Preview plans require the tested Mole 1.53 adapter; found \(version)."
        case .unsupportedCapability(let capability): "The engine does not provide \(capability). No changes were made."
        case .invalidRequest(let message): "The request was rejected before invoking the engine: \(message)"
        }
    }
}
