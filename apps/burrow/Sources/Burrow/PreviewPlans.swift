import CryptoKit
import Foundation

enum PreviewPlanSchema {
    static let current = 1
}

enum PreviewPlanSource: String, Codable, Sendable, Equatable {
    case moleCompatibilityAdapter
    case demoFallback

    var label: String {
        switch self {
        case .moleCompatibilityAdapter: "LIVE PREVIEW"
        case .demoFallback: "UNAVAILABLE"
        }
    }
}

struct PreviewPlanMetadata: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let fingerprint: String
    let engineVersion: String
    let source: PreviewPlanSource
    let warnings: [String]
}

enum PreviewFingerprint {
    static func make(kind: String, engineVersion: String, components: [String]) -> String {
        let canonical = (["burrow-preview", "schema=\(PreviewPlanSchema.current)", "kind=\(kind)", "engine=\(engineVersion)"] + components)
            .joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CleanPreviewPlan: Codable, Sendable, Equatable, Identifiable {
    struct Category: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let itemCount: Int?
        let reclaimableBytes: Int64?
        let details: [String]
    }

    let metadata: PreviewPlanMetadata
    let categories: [Category]
    let reclaimableBytes: Int64
    let itemCount: Int
    var id: String { metadata.fingerprint }
}

struct OptimizePreviewPlan: Codable, Sendable, Equatable, Identifiable {
    enum Disposition: String, Codable, Sendable, Equatable {
        case wouldApply
        case unchanged
        case skipped
        case unavailable
        case failed
    }

    struct Task: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let disposition: Disposition
    }

    let metadata: PreviewPlanMetadata
    let tasks: [Task]
    let applyCount: Int
    var id: String { metadata.fingerprint }
}

struct UninstallPreviewPlan: Codable, Sendable, Equatable, Identifiable {
    struct Application: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let bundleID: String
        let uninstallName: String
        let path: String
        let source: String
        let displaySize: String
        let sizeBytes: Int64?
    }

    let metadata: PreviewPlanMetadata
    let applications: [Application]
    var id: String { metadata.fingerprint }

    func selecting(ids: Set<String>) -> UninstallPreviewPlan {
        let selected = applications.filter { ids.contains($0.id) }
        let fingerprint = PreviewFingerprint.make(
            kind: "uninstall-selection", engineVersion: metadata.engineVersion,
            components: selected.flatMap { [$0.id, $0.displaySize] }
        )
        return UninstallPreviewPlan(
            metadata: .init(
                schemaVersion: metadata.schemaVersion, fingerprint: fingerprint,
                engineVersion: metadata.engineVersion, source: metadata.source, warnings: metadata.warnings
            ),
            applications: selected
        )
    }
}

enum PreviewFallbacks {
    static func clean(reason: String) -> CleanPreviewPlan {
        let categories = DemoData.cleanCategories.enumerated().map { index, item in
            CleanPreviewPlan.Category(id: "demo-clean-\(index)", title: item.0, itemCount: nil, reclaimableBytes: nil, details: [])
        }
        let fingerprint = PreviewFingerprint.make(kind: "clean", engineVersion: "demo", components: categories.map(\.title))
        return CleanPreviewPlan(
            metadata: .init(schemaVersion: PreviewPlanSchema.current, fingerprint: fingerprint, engineVersion: "demo", source: .demoFallback, warnings: [reason]),
            categories: categories,
            reclaimableBytes: 34_800_000_000,
            itemCount: 0
        )
    }

    static func optimize(reason: String) -> OptimizePreviewPlan {
        let tasks = DemoData.optimizeTasks.enumerated().map { index, title in
            OptimizePreviewPlan.Task(id: "demo-optimize-\(index)", title: title, detail: "Preview only", disposition: .wouldApply)
        }
        let fingerprint = PreviewFingerprint.make(kind: "optimize", engineVersion: "demo", components: tasks.map(\.title))
        return OptimizePreviewPlan(
            metadata: .init(schemaVersion: PreviewPlanSchema.current, fingerprint: fingerprint, engineVersion: "demo", source: .demoFallback, warnings: [reason]),
            tasks: tasks,
            applyCount: tasks.count
        )
    }

    static func apps(reason: String) -> UninstallPreviewPlan {
        let applications: [UninstallPreviewPlan.Application] = []
        let fingerprint = PreviewFingerprint.make(kind: "uninstall", engineVersion: "unavailable", components: [])
        return UninstallPreviewPlan(
            metadata: .init(schemaVersion: PreviewPlanSchema.current, fingerprint: fingerprint, engineVersion: "unavailable", source: .demoFallback, warnings: [reason]),
            applications: applications
        )
    }
}
