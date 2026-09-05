import Foundation
import Testing
@testable import Burrow

@Suite("Mole 1.53 preview plan golden contracts")
struct PreviewPlanContractTests {
    @Test("Clean dry-run becomes an immutable schema-one plan")
    func cleanGolden() throws {
        let output = try fixture("clean-1.53", extension: "txt")
        let first = try MolePreviewAdapter_v1_53.clean(output: output, engineVersion: "Mole version 1.53.0")
        let second = try MolePreviewAdapter_v1_53.clean(output: output, engineVersion: "Mole version 1.53.0")
        #expect(first.metadata.schemaVersion == 1)
        #expect(first.metadata.source == .moleCompatibilityAdapter)
        #expect(first.itemCount == 13)
        #expect(first.reclaimableBytes == 3_080_000_000)
        #expect(first.categories.map(\.title) == ["User essentials", "Browsers"])
        #expect(first.metadata.fingerprint == second.metadata.fingerprint)
        #expect(first.metadata.fingerprint.count == 64)
    }

    @Test("Optimize requires explicit no-change markers")
    func optimizeGolden() throws {
        let output = try fixture("optimize-1.53", extension: "txt")
        let plan = try MolePreviewAdapter_v1_53.optimize(output: output, engineVersion: "Mole version 1.53.0")
        #expect(plan.applyCount == 1)
        #expect(plan.tasks.count == 3)
        #expect(plan.tasks[1].disposition == .skipped)
        #expect(throws: EngineError.self) {
            try MolePreviewAdapter_v1_53.optimize(output: output.replacingOccurrences(of: "No Changes Made", with: "Changes Made"), engineVersion: "Mole version 1.53.0")
        }
    }

    @Test("Piped uninstall inventory JSON has stable path identity")
    func uninstallGolden() throws {
        let output = try fixture("uninstall-list-1.53", extension: "json")
        let plan = try MolePreviewAdapter_v1_53.applications(output: output, engineVersion: "Mole version 1.53.0")
        #expect(plan.applications.count == 2)
        #expect(plan.applications[0].bundleID == "com.example.canvas")
        #expect(plan.applications[1].id == "/Applications/Tiny Tool.app")
        #expect(plan.applications[0].sizeBytes == 1_200_000_000)
        let selection = plan.selecting(ids: [plan.applications[0].id])
        #expect(selection.applications.count == 1)
        #expect(selection.metadata.fingerprint != plan.metadata.fingerprint)
        #expect(selection == plan.selecting(ids: [plan.applications[0].id]))
    }

    @Test("Plans encode their source, schema, and fingerprint")
    func envelopeEncoding() throws {
        let output = try fixture("clean-1.53", extension: "txt")
        let plan = try MolePreviewAdapter_v1_53.clean(output: output, engineVersion: "Mole version 1.53.0")
        let data = try JSONEncoder().encode(plan)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["schemaVersion"] as? Int == 1)
        #expect(metadata["source"] as? String == "moleCompatibilityAdapter")
        #expect((metadata["fingerprint"] as? String)?.count == 64)
    }

    private func fixture(_ name: String, extension fileExtension: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
