import Foundation

struct UpdateInstallPlan: Sendable {
    let executable: String
    let arguments: [String]
}

enum UpdateInstaller {
    enum InstallError: Error, Sendable {
        case replaceFailed
        case launchFailedToStart
        case launchFailed(Int32)
    }

    static func launchPlan(installedPath: String) -> UpdateInstallPlan {
        UpdateInstallPlan(
            executable: "/usr/bin/open",
            arguments: ["-n", installedPath, "--args", InstallLocationChecker.updatingLaunchArgument]
        )
    }

    static func replace(from: URL, to: URL) -> Result<Void, InstallError> {
        do {
            _ = try FileManager.default.replaceItemAt(to, withItemAt: from)
            return .success(())
        } catch {
            return .failure(.replaceFailed)
        }
    }

    static func install(from: URL, to: URL) -> Result<Void, InstallError> {
        switch replace(from: from, to: to) {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }

        switch run(launchPlan(installedPath: to.path)) {
        case .failure(.failedToStart):
            return .failure(.launchFailedToStart)
        case .failure(.nonZero(let status)):
            return .failure(.launchFailed(status))
        case .success:
            return .success(())
        }
    }

    private enum RunError: Error {
        case failedToStart
        case nonZero(Int32)
    }

    private static func run(_ plan: UpdateInstallPlan) -> Result<Void, RunError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.failedToStart)
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 else {
            return .failure(.nonZero(status))
        }
        return .success(())
    }
}
