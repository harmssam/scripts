import Foundation

struct DemoApp: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    let appSizeGB: Double
    let leftoverSizeGB: Double
    let lastUsed: String
    let symbol: String
    var totalSizeGB: Double { appSizeGB + leftoverSizeGB }
}

struct DemoMetric: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let detail: String
    let symbol: String
    let tintHex: UInt32
    let samples: [Double]
}

enum DemoData {
    static let apps = [
        DemoApp(name: "Canvas", version: "4.8.2", appSizeGB: 1.24, leftoverSizeGB: 0.42, lastUsed: "active now", symbol: "scribble.variable"),
        DemoApp(name: "Code Studio", version: "1.96.1", appSizeGB: 0.88, leftoverSizeGB: 0.31, lastUsed: "2 hours ago", symbol: "chevron.left.forwardslash.chevron.right"),
        DemoApp(name: "Northstar", version: "2.1.0", appSizeGB: 0.29, leftoverSizeGB: 0.08, lastUsed: "11 days ago", symbol: "star.fill"),
        DemoApp(name: "Relay", version: "7.4.0", appSizeGB: 0.71, leftoverSizeGB: 0.19, lastUsed: "3 weeks ago", symbol: "point.3.connected.trianglepath.dotted")
    ]

    static let cleanCategories = [
        ("Application caches", "19.8 GB", "square.stack.3d.up.fill"),
        ("Developer files", "8.4 GB", "hammer.fill"),
        ("Browser data", "3.7 GB", "globe"),
        ("Logs & temporary files", "2.9 GB", "doc.text.fill")
    ]

    static let optimizeTasks = [
        "Refresh Launch Services", "Rebuild Quick Look cache", "Repair Homebrew paths",
        "Refresh font registry", "Restart Finder services", "Verify system databases"
    ]

    static let metrics = [
        DemoMetric(name: "CPU", value: "12%", detail: "Load 2.6 · 10 cores", symbol: "cpu", tintHex: 0x63D6A4, samples: [8, 12, 9, 15, 13, 18, 10, 12]),
        DemoMetric(name: "GPU", value: "4%", detail: "Idle · 16 cores", symbol: "display", tintHex: 0xE9A85E, samples: [3, 4, 3, 6, 4, 3, 5, 4]),
        DemoMetric(name: "Memory", value: "58%", detail: "18.4 GB · 0 swap", symbol: "memorychip", tintHex: 0xE6D27A, samples: [52, 54, 55, 58, 57, 59, 58, 58]),
        DemoMetric(name: "Disk", value: "412 GB", detail: "free of 994 GB", symbol: "internaldrive", tintHex: 0x7DAAF2, samples: [40, 41, 41, 42, 42, 42, 41, 41]),
        DemoMetric(name: "Network", value: "3 KB/s", detail: "Wi-Fi · ↓ 8 KB/s", symbol: "network", tintHex: 0x60B8E8, samples: [2, 8, 3, 12, 5, 14, 2, 7]),
        DemoMetric(name: "Battery", value: "91%", detail: "Healthy · charging", symbol: "battery.100percent", tintHex: 0x5FD49A, samples: [86, 87, 88, 89, 89, 90, 90, 91])
    ]
}
