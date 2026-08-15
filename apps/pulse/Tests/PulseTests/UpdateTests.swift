import Foundation
import Testing
@testable import Pulse

@Suite("Version comparison")
struct VersionComparatorTests {
    @Test("Detects newer patch, minor, and major versions")
    func newerVersions() {
        #expect(VersionComparator.isNewer("0.2.5", than: "0.2.4"))
        #expect(VersionComparator.isNewer("0.3.0", than: "0.2.4"))
        #expect(VersionComparator.isNewer("1.0.0", than: "0.2.4"))
        #expect(VersionComparator.isNewer("v0.2.10", than: "0.2.4"))
    }

    @Test("Rejects same or older versions")
    func sameOrOlderVersions() {
        #expect(!VersionComparator.isNewer("0.2.4", than: "0.2.4"))
        #expect(!VersionComparator.isNewer("0.2.3", than: "0.2.4"))
        #expect(!VersionComparator.isNewer("0.1.9", than: "0.2.4"))
        #expect(!VersionComparator.isNewer("v0.2.4", than: "0.2.4"))
    }

    @Test("Handles unequal segment counts")
    func unequalSegments() {
        #expect(VersionComparator.isNewer("0.2", than: "0.1.9"))
        #expect(!VersionComparator.isNewer("0.2", than: "0.2.1"))
    }
}

@Suite("Update extraction")
struct UpdateExtractorTests {
    @Test("Finds app bundle at archive root")
    func findsRootBundle() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseUpdateTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = temp.appendingPathComponent("Pulse.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let found = UpdateExtractor.findAppBundle(named: "Pulse.app", in: temp)
        #expect(found?.standardizedFileURL == app.standardizedFileURL)
    }

    @Test("Finds nested app bundle")
    func findsNestedBundle() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseUpdateTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let nested = temp.appendingPathComponent("nested/Pulse.app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let found = UpdateExtractor.findAppBundle(named: "Pulse.app", in: temp)
        #expect(found?.standardizedFileURL == nested.standardizedFileURL)
    }
}

@Suite("Update download validation")
struct UpdateDownloaderTests {
    @Test("Accepts valid zip header")
    func validZipHeader() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseZipTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }

        let zipHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        try zipHeader.write(to: temp)
        try UpdateDownloader.validateZip(at: temp)
    }

    @Test("Rejects non-zip content")
    func rejectsInvalidHeader() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseZipTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data("<html>not a zip</html>".utf8).write(to: temp)
        #expect(throws: (any Error).self) {
            try UpdateDownloader.validateZip(at: temp)
        }
    }
}

@Suite("Update installer")
struct UpdateInstallerTests {
    @Test("Replace and launch plans use argv arrays without a shell")
    func plansHaveNoShell() {
        let from = URL(fileURLWithPath: "/tmp/New \"Pulse\".app")
        let to = URL(fileURLWithPath: "/Applications/Pulse Beta.app")

        let replace = UpdateInstaller.replacePlan(from: from, to: to)
        #expect(replace.executable == "/usr/bin/ditto")
        #expect(!replace.executable.contains("bash"))
        #expect(!replace.arguments.contains("-c"))
        #expect(!replace.arguments.contains("bash"))
        #expect(replace.arguments == [from.path, to.path])
        #expect(replace.arguments[0].contains("\""))
        #expect(replace.arguments[1].contains(" "))

        let launch = UpdateInstaller.launchPlan(installedPath: to.path)
        #expect(launch.executable == "/usr/bin/open")
        #expect(!launch.executable.contains("bash"))
        #expect(!launch.arguments.contains("-c"))
        #expect(!launch.arguments.contains("bash"))
        #expect(launch.arguments == [
            "-n",
            to.path,
            "--args",
            InstallLocationChecker.updatingLaunchArgument
        ])
        #expect(launch.arguments[1].contains(" "))
    }

    @Test("Failed replace returns an error and does not succeed")
    func failedReplaceReturnsError() {
        let missing = URL(fileURLWithPath: "/tmp/Pulse-missing-\(UUID().uuidString).app")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pulse-install-dest-\(UUID().uuidString).app")
        let result = UpdateInstaller.install(from: missing, to: dest)
        switch result {
        case .success:
            Issue.record("expected replace failure")
        case .failure:
            break
        }
    }
}