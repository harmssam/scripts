import Foundation

struct UpdateInstallPlan: Sendable {
    let executable: String
    let arguments: [String]
}

enum UpdateInstaller {
    enum InstallError: Error, Sendable {
        case replaceFailedToStart
        case replaceFailed(Int32)
        case launchFailedToStart
        case launchFailed(Int32)
    }

    static func replacePlan(from: URL, to: URL) -> UpdateInstallPlan {
        UpdateInstallPlan(
            executable: "/usr/bin/ditto",
            arguments: [from.path, to.path]
        )
    }

    static func launchPlan(installedPath: String) -> UpdateInstallPlan {
        UpdateInstallPlan(
            executable: "/usr/bin/open",
            arguments: ["-n", installedPath, "--args", InstallLocationChecker.updatingLaunchArgument]
        )
    }

    static func install(from: URL, to: URL) -> Result<Void, InstallError> {
        switch run(replacePlan(from: from, to: to)) {
        case .failure(.failedToStart):
            return .failure(.replaceFailedToStart)
        case .failure(.nonZero(let status)):
            return .failure(.replaceFailed(status))
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
