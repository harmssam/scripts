import Foundation

protocol EngineClientProtocol: Sendable {
    func availability() async -> EngineAvailability
    func statusSnapshot() async throws -> StatusSnapshot
    func analyze(path: String) async throws -> AnalyzeReport
    func cleanPreview() async throws -> CleanPreviewPlan
    func optimizePreview() async throws -> OptimizePreviewPlan
    func uninstallInventory() async throws -> UninstallPreviewPlan
    func executionPlanCapabilities() async -> ExecutionPlanCapabilities
    func executionPlan(for request: ExecutionPlanRequest) async throws -> ExecutionPlan
}

actor MoleEngineClient: EngineClientProtocol {
    /// Only engines that explicitly put this marker in `--version` are queried for the
    /// Burrow structured protocol. This prevents probing stock Mole with unknown flags.
    private static let structuredProtocolMarker = "burrow-plan-v1"
    private let executableURL: URL?
    private let decoder = JSONDecoder()
    private var cachedVersion: String?

    init(executableURL: URL? = MoleEngineClient.discoverExecutable()) {
        self.executableURL = executableURL
    }

    func availability() async -> EngineAvailability {
        guard executableURL != nil else {
            return .unavailable("Mole CLI not found in /opt/homebrew/bin or /usr/local/bin")
        }
        do {
            let output = try await run(arguments: ["--version"])
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? "Mole installed"
            cachedVersion = firstLine
            return .available(version: firstLine)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func statusSnapshot() async throws -> StatusSnapshot {
        let output = try await run(arguments: ["status", "--json"])
        do { return try decoder.decode(StatusSnapshot.self, from: Data(output.utf8)) }
        catch { throw EngineError.malformedOutput(error.localizedDescription) }
    }

    func analyze(path: String) async throws -> AnalyzeReport {
        let output = try await run(arguments: ["analyze", "--json", path])
        do { return try decoder.decode(AnalyzeReport.self, from: Data(output.utf8)) }
        catch { throw EngineError.malformedOutput(error.localizedDescription) }
    }

    func cleanPreview() async throws -> CleanPreviewPlan {
        let version = try await compatiblePreviewVersion()
        let output = try await run(arguments: ["clean", "--dry-run"])
        return try MolePreviewAdapter_v1_53.clean(output: output, engineVersion: version)
    }

    func optimizePreview() async throws -> OptimizePreviewPlan {
        let version = try await compatiblePreviewVersion()
        let result = try await runResult(arguments: ["optimize", "--dry-run"])
        // Mole 1.53 can return 1 for a completed dry-run when individual checks are unavailable.
        // The strict adapter still requires both no-change markers before accepting the output.
        if result.status != 0 && !result.stdout.contains("Dry Run Complete, No Changes Made") {
            throw EngineError.commandFailed(result.status, result.stderr)
        }
        return try MolePreviewAdapter_v1_53.optimize(output: result.stdout, engineVersion: version)
    }

    func uninstallInventory() async throws -> UninstallPreviewPlan {
        let version = try await compatiblePreviewVersion()
        // Mole 1.53 emits JSON automatically when --list stdout is a pipe. It rejects --list --json.
        let output = try await run(arguments: ["uninstall", "--list"])
        return try MolePreviewAdapter_v1_53.applications(output: output, engineVersion: version)
    }

    func executionPlanCapabilities() async -> ExecutionPlanCapabilities {
        guard executableURL != nil else { return .unavailable(engineVersion: "unavailable") }
        do {
            let version = try await engineVersion()
            // Mole 1.53 has no structured plan or progress protocol. Never probe it with
            // invented flags: its human-readable dry runs are preview evidence only.
            guard version.contains(Self.structuredProtocolMarker) else {
                return .unavailable(engineVersion: version)
            }
            let output = try await run(arguments: ["capabilities", "--json"])
            let capabilities = try decoder.decode(ExecutionPlanCapabilities.self, from: Data(output.utf8))
            guard capabilities.engineVersion == version, capabilities.supportsStructuredPlans else {
                return .unavailable(engineVersion: version)
            }
            return capabilities
        } catch {
            return .unavailable(engineVersion: "unknown")
        }
    }

    func executionPlan(for request: ExecutionPlanRequest) async throws -> ExecutionPlan {
        let capabilities = await executionPlanCapabilities()
        let kind: ExecutionPlanKind
        switch request {
        case .clean: kind = .clean
        case .optimize: kind = .optimize
        case .uninstall: kind = .uninstall
        }
        guard capabilities.supportsStructuredPlans,
              capabilities.supportedPlanKinds.contains(kind) else {
            throw EngineError.unsupportedCapability("structured \(kind.rawValue) execution plans")
        }
        let arguments: [String]
        let selectedApplicationPaths: [String]
        switch request {
        case .clean:
            arguments = ["clean", "--plan-json"]
            selectedApplicationPaths = []
        case .optimize:
            arguments = ["optimize", "--plan-json"]
            selectedApplicationPaths = []
        case .uninstall(let applicationPaths):
            arguments = try Self.uninstallPlanArguments(applicationPaths: applicationPaths)
            selectedApplicationPaths = applicationPaths
        }

        let output = try await run(arguments: arguments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan: ExecutionPlan
        do { plan = try decoder.decode(ExecutionPlan.self, from: Data(output.utf8)) }
        catch { throw EngineError.malformedOutput("Structured plan JSON was malformed: \(error.localizedDescription)") }
        guard plan.kind == kind, plan.metadata.engineVersion == capabilities.engineVersion else {
            throw EngineError.malformedOutput("Structured plan identity did not match the negotiated request")
        }
        let validated: ExecutionPlan
        do { validated = try plan.validated() }
        catch { throw EngineError.malformedOutput("Structured plan validation failed: \(error)") }
        if kind == .uninstall {
            let trashTargets = Set(validated.operations.filter { $0.action == .moveToTrash }.map(\.target.path))
            guard Set(selectedApplicationPaths) == trashTargets else {
                throw EngineError.malformedOutput("Uninstall plan application targets did not exactly match the selection")
            }
        }
        return validated
    }

    /// Validate every operand before process launch and terminate option parsing with `--`.
    /// This is internal so contract tests can prove the exact argv without running a command.
    static func uninstallPlanArguments(applicationPaths: [String]) throws -> [String] {
        guard !applicationPaths.isEmpty else {
            throw EngineError.invalidRequest("Select at least one application")
        }
        guard Set(applicationPaths).count == applicationPaths.count else {
            throw EngineError.invalidRequest("Duplicate application path")
        }
        for path in applicationPaths where !ExecutionPlan.isValidUninstallApplicationPath(path) {
            throw EngineError.invalidRequest("Invalid application path: \(path)")
        }
        return ["uninstall", "--plan-json", "--"] + applicationPaths
    }

    private func engineVersion() async throws -> String {
        if let cachedVersion { return cachedVersion }
        let output = try await run(arguments: ["--version"])
        let version = output.split(separator: "\n").first.map(String.init) ?? ""
        cachedVersion = version
        return version
    }

    private func compatiblePreviewVersion() async throws -> String {
        let version = try await engineVersion()
        guard version.contains(MolePreviewAdapter_v1_53.supportedVersionMarker) else {
            throw EngineError.incompatibleVersion(version)
        }
        return version
    }

    private func run(arguments: [String]) async throws -> String {
        let result = try await runResult(arguments: arguments)
        guard result.status == 0 else { throw EngineError.commandFailed(result.status, result.stderr) }
        return result.stdout
    }

    private func runResult(arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        guard let executableURL else { throw EngineError.unavailable }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = Self.safeEnvironment()

            let outputBuffer = ProcessOutputBuffer()
            let errorBuffer = ProcessOutputBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { outputBuffer.append(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { errorBuffer.append(data) }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: EngineError.launchFailed(error.localizedDescription))
                return
            }

            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                outputBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                errorBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())

                let output = String(decoding: outputBuffer.data, as: UTF8.self)
                let errorOutput = String(decoding: errorBuffer.data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: (process.terminationStatus, output, errorOutput))
                } else {
                    continuation.resume(returning: (process.terminationStatus, output, errorOutput))
                }
            }
        }
    }

    nonisolated static func discoverExecutable() -> URL? {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "mo"),
            URL(fileURLWithPath: "/opt/homebrew/bin/mo"),
            URL(fileURLWithPath: "/usr/local/bin/mo")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func safeEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": source["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": source["LC_ALL"] ?? "en_US.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1"
        ]
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum DiskAccessChecker {
    static func currentLevel() -> DiskAccessLevel {
        let protectedProbe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/History.db").path
        return FileManager.default.isReadableFile(atPath: protectedProbe) ? .full : .limited
    }
}

enum ByteFormatter {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
