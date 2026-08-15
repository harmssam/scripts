import Foundation

struct ProcessActivity: Equatable, Identifiable, Sendable {
    let id: Int32
    let name: String
    let readRate: UInt64
    let writeRate: UInt64

    var totalRate: UInt64 { readRate + writeRate }
}

struct NetworkProcessActivity: Equatable, Identifiable, Sendable {
    let id: Int32
    let name: String
    let downloadRate: UInt64
    let uploadRate: UInt64

    var totalRate: UInt64 { downloadRate + uploadRate }
}