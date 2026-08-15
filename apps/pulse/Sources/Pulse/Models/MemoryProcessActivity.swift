import Foundation

struct MemoryProcessActivity: Equatable, Identifiable, Sendable {
    let id: Int32
    let name: String
    let memoryBytes: UInt64
}
