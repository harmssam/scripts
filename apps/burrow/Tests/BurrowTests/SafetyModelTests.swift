import Foundation
import Testing
@testable import Burrow

@Suite("Phase 4 safety presentation models")
struct SafetyModelTests {
    @Test("Execution stays locked until every safety requirement passes")
    func gateFailsClosed() {
        let gate = SafetyGate.evaluate(
            engineAvailable: true,
            diskAccess: .limited,
            plan: nil,
            helperReady: false
        )

        #expect(gate.canPreview)
        #expect(!gate.canExecute)
        #expect(gate.requirements == [
            .exactPlanRequired,
            .fullDiskAccessRequired,
            .privilegedHelperRequired,
        ])
    }

    @Test("A fully satisfied safety gate permits confirmation")
    func gateCanBecomeReady() throws {
        let plan = try makePlan()
        let gate = SafetyGate.evaluate(
            engineAvailable: true,
            diskAccess: .full,
            plan: plan,
            at: Date(timeIntervalSince1970: 1_050),
            helperReady: true
        )
        #expect(gate.canPreview)
        #expect(gate.canExecute)
        #expect(gate.requirements.isEmpty)
    }

    @Test("Confirmation binds phrase, current fingerprint, expiry, and gate")
    func confirmationIsPlanBound() throws {
        let plan = try makePlan()
        let confirmation = try ExecutionConfirmation(
            validatedPlan: plan, at: Date(timeIntervalSince1970: 1_050)
        )
        let ready = SafetyGate(canPreview: true, canExecute: true, requirements: [])

        #expect(confirmation.operation == .clean)
        #expect(confirmation.itemCount == 1)
        #expect(confirmation.affectedBytes == 42)
        #expect(confirmation.planExpiresAt == plan.metadata.expiresAt)
        #expect(confirmation.isAuthorized(
            typedPhrase: confirmation.requiredPhrase,
            now: Date(timeIntervalSince1970: 1_099),
            gate: ready
        ))
        #expect(!confirmation.isAuthorized(
            typedPhrase: confirmation.requiredPhrase,
            now: plan.metadata.expiresAt,
            gate: ready
        ))
    }

    @Test("A blocked gate cannot be bypassed with the correct phrase")
    func confirmationCannotBypassGate() throws {
        let confirmation = try ExecutionConfirmation(
            validatedPlan: makePlan(), at: Date(timeIntervalSince1970: 1_050)
        )
        let blocked = SafetyGate(
            canPreview: true,
            canExecute: false,
            requirements: [.privilegedHelperRequired]
        )
        #expect(!confirmation.isAuthorized(
            typedPhrase: confirmation.requiredPhrase,
            now: Date(timeIntervalSince1970: 1_050),
            gate: blocked
        ))
    }

    private func makePlan() throws -> ExecutionPlan {
        let operation = ExecutionPlanOperation(
            id: "clean.one", action: .removeFile,
            target: .init(
                path: "/Users/test/Library/Caches/item", nodeKind: .file, byteCount: 42,
                modificationTime: Date(timeIntervalSince1970: 1_000), fileIdentifier: "fixture"
            ),
            reason: "Cache", payload: nil
        )
        let unsigned = ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: "1.53.0",
                createdAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: Date(timeIntervalSince1970: 1_100), fingerprint: ""
            ),
            kind: .clean, operations: [operation]
        )
        return ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: "1.53.0",
                createdAt: unsigned.metadata.createdAt, expiresAt: unsigned.metadata.expiresAt,
                fingerprint: try unsigned.calculatedFingerprint()
            ),
            kind: .clean, operations: [operation]
        )
    }

    @Test("Progress is clamped and handles empty plans")
    func progressClamps() {
        #expect(ExecutionProgress(completedItems: 5, totalItems: 4, currentTask: "Done", cancellationRequested: false).fraction == 1)
        #expect(ExecutionProgress(completedItems: -1, totalItems: 4, currentTask: "Starting", cancellationRequested: false).fraction == 0)
        #expect(ExecutionProgress(completedItems: 0, totalItems: 0, currentTask: "Empty", cancellationRequested: false).fraction == 0)
    }

    @Test("Partial receipts preserve completed, skipped, and failed evidence")
    func partialReceiptCounts() throws {
        let receipt = OperationReceipt(
            operation: .optimize,
            planFingerprint: "feedface",
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 105),
            outcome: .partiallyCompleted,
            items: [
                .init(title: "Cache", detail: "Finished", status: .completed),
                .init(title: "Index", detail: "Cancelled before start", status: .skipped),
                .init(title: "Service", detail: "Permission changed", status: .failed),
            ]
        )

        #expect(receipt.completedCount == 1)
        #expect(receipt.skippedCount == 1)
        #expect(receipt.failedCount == 1)

        let roundTrip = try JSONDecoder().decode(OperationReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(roundTrip == receipt)
    }
}
