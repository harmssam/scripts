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
    @Test("Launch plan uses argv arrays without a shell")
    func launchPlanHasNoShell() {
        let to = URL(fileURLWithPath: "/Applications/Pulse Beta.app")

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
        #expect(launch.arguments[1].contains("\"" ) == false)
        #expect(to.path.contains(" "))
    }

    @Test("Replace drops files that are not in the new bundle")
    func replaceDropsStaleFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseReplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = root.appendingPathComponent("Pulse.app")
        let src = root.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("stale.bin"))
        try Data("old-keep".utf8).write(to: dest.appendingPathComponent("keep.bin"))
        try Data("new-keep".utf8).write(to: src.appendingPathComponent("keep.bin"))
        try Data("fresh".utf8).write(to: src.appendingPathComponent("fresh.bin"))

        let result = UpdateInstaller.replace(from: src, to: dest)
        guard case .success = result else {
            Issue.record("expected replace success")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("stale.bin").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("fresh.bin").path))
        let keep = try String(contentsOf: dest.appendingPathComponent("keep.bin"), encoding: .utf8)
        #expect(keep == "new-keep")
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

    @Test("Failed install keeps the pending update so retry can run")
    func keepsAvailableUpdateWhenInstallFails() {
        let update = AppUpdate(
            version: "9.9.9",
            downloadURL: URL(string: "https://example.com/Pulse.zip")!,
            releaseURL: URL(string: "https://example.com/release")!
        )
        #expect(AppState.nextAvailableUpdate(current: update, installSucceeded: false) == update)
        #expect(AppState.nextAvailableUpdate(current: update, installSucceeded: true) == nil)
    }
}