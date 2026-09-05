import Foundation

/// Safety state shared by the future Clean, Optimize, and Uninstall execution surfaces.
/// These models deliberately contain no executor or filesystem APIs.
enum MaintenanceOperation: String, Codable, CaseIterable, Sendable {
    case clean
    case optimize
    case uninstall

    var title: String { rawValue.capitalized }
}

enum SafetyRequirement: String, Codable, Equatable, Hashable, Sendable {
    case engineUnavailable
    case exactPlanRequired
    case stalePlan
    case fullDiskAccessRequired
    case privilegedHelperRequired

    var message: String {
        switch self {
        case .engineUnavailable: "The maintenance engine is unavailable."
        case .exactPlanRequired: "An exact, structured plan is required."
        case .stalePlan: "The preview changed or expired. Build a new plan."
        case .fullDiskAccessRequired: "Full Disk Access is required for complete coverage."
        case .privilegedHelperRequired: "The signed helper is not installed yet."
        }
    }
}

struct SafetyGate: Equatable, Sendable {
    let canPreview: Bool
    let canExecute: Bool
    let requirements: [SafetyRequirement]

    static func evaluate(
        engineAvailable: Bool,
        diskAccess: DiskAccessLevel,
        plan: ExecutionPlan?,
        at now: Date = Date(),
        helperReady: Bool
    ) -> Self {
        var requirements: [SafetyRequirement] = []
        if !engineAvailable { requirements.append(.engineUnavailable) }
        if let plan {
            if (try? plan.validated(at: now)) == nil { requirements.append(.stalePlan) }
        } else {
            requirements.append(.exactPlanRequired)
        }
        if diskAccess != .full { requirements.append(.fullDiskAccessRequired) }
        if !helperReady { requirements.append(.privilegedHelperRequired) }

        return SafetyGate(
            canPreview: engineAvailable,
            canExecute: engineAvailable && requirements.isEmpty,
            requirements: requirements
        )
    }
}

struct ExecutionConfirmation: Equatable, Sendable {
    let operation: MaintenanceOperation
    let planFingerprint: String
    let itemCount: Int
    let affectedBytes: Int64
    let planExpiresAt: Date

    init(validatedPlan plan: ExecutionPlan, at now: Date = Date()) throws {
        let plan = try plan.validated(at: now)
        guard let operation = MaintenanceOperation(rawValue: plan.kind.rawValue) else {
            throw ExecutionConfirmationError.unsupportedOperation
        }
        self.operation = operation
        planFingerprint = plan.metadata.fingerprint
        itemCount = plan.operations.count
        affectedBytes = try plan.operations.reduce(0) { total, operation in
            let (sum, overflow) = total.addingReportingOverflow(operation.target.byteCount)
            guard !overflow else { throw ExecutionConfirmationError.byteCountOverflow }
            return sum
        }
        planExpiresAt = plan.metadata.expiresAt
    }

    var requiredPhrase: String { "\(operation.rawValue.uppercased()) \(shortFingerprint)" }
    var shortFingerprint: String { String(planFingerprint.prefix(8)).uppercased() }

    func isAuthorized(
        typedPhrase: String,
        now: Date,
        gate: SafetyGate
    ) -> Bool {
        gate.canExecute
            && now < planExpiresAt
            && typedPhrase.trimmingCharacters(in: .whitespacesAndNewlines) == requiredPhrase
    }
}

enum ExecutionConfirmationError: Error, Equatable, Sendable {
    case unsupportedOperation
    case byteCountOverflow
}

enum ExecutionOutcome: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case partiallyCompleted
    case failed

    var title: String {
        switch self {
        case .completed: "Completed"
        case .cancelled: "Cancelled safely"
        case .partiallyCompleted: "Partially completed"
        case .failed: "Stopped with an error"
        }
    }
}

enum ReceiptItemStatus: String, Codable, Equatable, Sendable {
    case completed
    case skipped
    case failed
}

struct OperationReceipt: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let detail: String
        let status: ReceiptItemStatus

        init(id: UUID = UUID(), title: String, detail: String, status: ReceiptItemStatus) {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
        }
    }

    let id: UUID
    let operation: MaintenanceOperation
    let planFingerprint: String
    let startedAt: Date
    let finishedAt: Date
    let outcome: ExecutionOutcome
    /// Bytes reported by successfully completed operations. This is not necessarily
    /// reclaimed disk space (for example, moving an app to Trash does not free space).
    let completedBytes: Int64?
    let items: [Item]

    init(
        id: UUID = UUID(),
        operation: MaintenanceOperation,
        planFingerprint: String,
        startedAt: Date,
        finishedAt: Date,
        outcome: ExecutionOutcome,
        completedBytes: Int64? = nil,
        items: [Item]
    ) {
        self.id = id
        self.operation = operation
        self.planFingerprint = planFingerprint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.completedBytes = completedBytes
        self.items = items
    }

    var completedCount: Int { items.count { $0.status == .completed } }
    var failedCount: Int { items.count { $0.status == .failed } }
    var skippedCount: Int { items.count { $0.status == .skipped } }
}

struct ExecutionProgress: Equatable, Sendable {
    let completedItems: Int
    let totalItems: Int
    let currentTask: String
    let cancellationRequested: Bool

    var fraction: Double {
        guard totalItems > 0 else { return 0 }
        return min(1, max(0, Double(completedItems) / Double(totalItems)))
    }
}
