import Darwin
import Foundation

struct MemorySnapshot: Sendable {
    let total: UInt64
    let free: UInt64
    let used: UInt64
    let active: UInt64
    let wired: UInt64
    let compressed: UInt64
    let isValid: Bool

    var usedPercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    static let unavailable = MemorySnapshot(
        total: 0,
        free: 0,
        used: 0,
        active: 0,
        wired: 0,
        compressed: 0,
        isValid: false
    )

    /// `total` is bytes (`hw.memsize`). Other arguments are Mach page counts.
    static func from(
        total: UInt64,
        active: UInt64,
        wired: UInt64,
        compressed: UInt64,
        freePages: UInt64,
        inactive: UInt64,
        speculative: UInt64
    ) -> MemorySnapshot {
        let pageSize = UInt64(getpagesize())
        return MemorySnapshot(
            total: total,
            free: (freePages + inactive + speculative) * pageSize,
            used: (active + wired + compressed) * pageSize,
            active: active * pageSize,
            wired: wired * pageSize,
            compressed: compressed * pageSize,
            isValid: true
        )
    }
}