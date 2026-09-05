import Foundation

enum MolePreviewAdapter_v1_53 {
    static let supportedVersionMarker = "Mole version 1.53."

    static func clean(output: String, engineVersion: String) throws -> CleanPreviewPlan {
        let text = stripANSI(output)
        guard text.contains("Dry Run Mode, Preview only, no deletions"),
              text.contains("Dry run complete - no changes made"),
              let summary = text.split(separator: "\n").first(where: { $0.contains("Potential space:") && $0.contains("Items:") })
        else { throw EngineError.malformedOutput("Mole 1.53 clean dry-run markers were missing") }

        var categories: [CleanPreviewPlan.Category] = []
        var currentTitle: String?
        var details: [String] = []

        func appendCurrent() {
            guard let currentTitle, !details.isEmpty else { return }
            let parsed = details.map(parseCleanDetail)
            let counts = parsed.compactMap(\.count)
            let sizes = parsed.compactMap(\.bytes)
            categories.append(.init(
                id: slug(currentTitle), title: currentTitle,
                itemCount: counts.isEmpty ? nil : counts.reduce(0, +),
                reclaimableBytes: sizes.isEmpty ? nil : sizes.reduce(0, +), details: details
            ))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤ ") {
                appendCurrent()
                currentTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                details = []
            } else if currentTitle != nil, line.hasPrefix("→ ") || line.hasPrefix("◎ ") || line.hasPrefix("⊙ ") {
                details.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        appendCurrent()

        let fields = String(summary).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2,
              let sizeText = fields.first?.split(separator: ":", maxSplits: 1).last,
              let reclaimable = parseBytes(String(sizeText)),
              let itemText = fields[1].split(separator: ":", maxSplits: 1).last,
              let itemCount = Int(itemText.trimmingCharacters(in: .whitespaces))
        else { throw EngineError.malformedOutput("Mole 1.53 clean summary was malformed") }

        let components = categories.flatMap { [$0.id, String($0.itemCount ?? 0), String($0.reclaimableBytes ?? 0)] }
        let fingerprint = PreviewFingerprint.make(kind: "clean", engineVersion: engineVersion, components: components)
        return CleanPreviewPlan(
            metadata: .init(schemaVersion: PreviewPlanSchema.current, fingerprint: fingerprint, engineVersion: engineVersion, source: .moleCompatibilityAdapter, warnings: ["Compatibility preview: category-level evidence only. Execution is disabled."]),
            categories: categories, reclaimableBytes: reclaimable, itemCount: itemCount
        )
    }

    static func optimize(output: String, engineVersion: String) throws -> OptimizePreviewPlan {
        let text = stripANSI(output)
        guard text.contains("DRY RUN MODE, No files will be modified"),
              text.contains("Dry Run Complete, No Changes Made"),
              let applyLine = text.split(separator: "\n").first(where: { $0.contains("Would apply") && $0.contains("optimizations") })
        else { throw EngineError.malformedOutput("Mole 1.53 optimize dry-run markers were missing") }

        var tasks: [OptimizePreviewPlan.Task] = []
        var section: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤ ") {
                section = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if let sectionTitle = section, line.hasPrefix("→ ") || line.hasPrefix("✓ ") || line.hasPrefix("◎ ") {
                let detail = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let normalized = detail.lowercased()
                let disposition: OptimizePreviewPlan.Disposition
                if normalized.contains("failed") {
                    disposition = .failed
                } else if normalized.contains("not available") || normalized.contains("unavailable") {
                    disposition = .unavailable
                } else if line.hasPrefix("◎ ") || normalized.contains("skipped") || normalized.hasPrefix("close ") {
                    disposition = .skipped
                } else if line.hasPrefix("✓ ") || normalized.contains("already") || normalized.contains("optimal") || normalized.contains("valid") || normalized.contains("healthy") || normalized.hasPrefix("no ") {
                    disposition = .unchanged
                } else {
                    disposition = .wouldApply
                }
                tasks.append(.init(id: slug(sectionTitle), title: sectionTitle, detail: detail, disposition: disposition))
                section = nil
            }
        }
        guard let countText = applyLine.split(separator: " ").dropFirst(2).first, let applyCount = Int(countText), !tasks.isEmpty
        else { throw EngineError.malformedOutput("Mole 1.53 optimize summary was malformed") }

        let components = tasks.flatMap { [$0.id, $0.detail, $0.disposition.rawValue] }
        let fingerprint = PreviewFingerprint.make(kind: "optimize", engineVersion: engineVersion, components: components)
        return OptimizePreviewPlan(
            metadata: .init(schemaVersion: PreviewPlanSchema.current, fingerprint: fingerprint, engineVersion: engineVersion, source: .moleCompatibilityAdapter, warnings: ["Compatibility preview: no optimization can be started from Burrow."]),
            tasks: tasks, applyCount: applyCount
        )
    }

    static func applications(output: String, engineVersion: String) throws -> UninstallPreviewPlan {
        struct RawApplication: Decodable {
            let name: String
            let bundleID: String
            let source: String
            let uninstallName: String
            let path: String
            let size: String
            enum CodingKeys: String, CodingKey {
                case name, source, path, size
                case bundleID = "bundle_id"
                case uninstallName = "uninstall_name"
            }
        }

        let decoded: [RawApplication]
        do { decoded = try JSONDecoder().decode([RawApplication].self, from: Data(output.utf8)) }
        catch { throw EngineError.malformedOutput("Mole 1.53 uninstall list JSON was malformed: \(error.localizedDescription)") }
        guard !decoded.isEmpty else { throw EngineError.malformedOutput("Mole 1.53 returned an empty application inventory") }

        let applications: [UninstallPreviewPlan.Application] = decoded.map {
            let identity = $0.bundleID == "unknown" ? $0.path : $0.bundleID + "|" + $0.path
            return UninstallPreviewPlan.Application(
                id: identity, name: $0.name, bundleID: $0.bundleID, uninstallName: $0.uninstallName,
                path: $0.path, source: $0.source, displaySize: $0.size, sizeBytes: parseBytes($0.size)
            )
        }.sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }

        let fingerprint = PreviewFingerprint.make(kind: "uninstall", engineVersion: engineVersion, components: applications.flatMap { [$0.id, $0.displaySize] })
        return UninstallPreviewPlan(
            metadata: .init(schemaVersion: PreviewPlanSchema.current, fingerprint: fingerprint, engineVersion: engineVersion, source: .moleCompatibilityAdapter, warnings: ["Inventory only. Related-file enumeration and removal remain disabled until Mole exposes a structured plan protocol."]),
            applications: applications
        )
    }

    private static func parseCleanDetail(_ detail: String) -> (count: Int?, bytes: Int64?) {
        let components = detail.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let count = components.lazy.compactMap { component -> Int? in
            guard component.contains(" items") || component.contains(" dirs") || component.contains(" entries") else { return nil }
            return Int(component.split(separator: " ").first ?? "")
        }.first
        let bytes = components.lazy.compactMap { parseBytes($0.replacingOccurrences(of: " dry", with: "")) }.first
        return (count, bytes)
    }

    static func parseBytes(_ text: String) -> Int64? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let units: [(String, Double)] = [("TB", 1_000_000_000_000), ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000), ("B", 1)]
        for (suffix, multiplier) in units where cleaned.hasSuffix(suffix) {
            let number = cleaned.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let value = Double(number) { return Int64(value * multiplier) }
        }
        return nil
    }

    private static func slug(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { result, character in
            if character != "-" || result.last != "-" { result.append(character) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(of: "\\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
