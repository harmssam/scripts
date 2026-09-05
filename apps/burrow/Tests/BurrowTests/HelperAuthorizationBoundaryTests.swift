import CryptoKit
import Foundation
import Testing
@testable import Burrow

@Suite("Helper authorization boundary")
struct HelperAuthorizationBoundaryTests {
    private let instant = Date(timeIntervalSince1970: 1_788_470_400)
    private let auditToken = Data("trusted-audit-token".utf8)
    private let authorization = Data("authorization-external-form".utf8)
    private let ticketValue = String(repeating: "a", count: 64)

    @Test("Helper-issued ticket authorizes exact plan once and returns only opaque action handles")
    func authorizesOnce() async throws {
        let fixture = try makeFixture()
        let boundary = makeBoundary(fixture.target)
        let ticket = try await issue(boundary, plan: fixture.plan)
        let request = try await boundary.authorize(envelope(fixture.plan, ticket), auditToken: auditToken)

        #expect(request.planFingerprint == fixture.plan.metadata.fingerprint)
        #expect(request.actions.count == 1)
        #expect(request.actions[0].handle == fixture.target.handle)
        #expect(request.actions[0].operationID == "operation-1")
        await #expect(throws: HelperAuthorizationError.replayedAuthorization) {
            try await boundary.authorize(self.envelope(fixture.plan, ticket), auditToken: self.auditToken)
        }
    }

    @Test("Tickets require authenticated audit-token identity and verified user authorization")
    func issuanceTrust() async throws {
        let fixture = try makeFixture()
        let badClient = makeBoundary(fixture.target, authenticatedClient: nil)
        await #expect(throws: HelperAuthorizationError.unauthenticatedClient) {
            try await self.issue(badClient, plan: fixture.plan)
        }

        let wrongUser = makeBoundary(
            fixture.target,
            authenticatedClient: .init(userID: 502, clientIdentifier: "signed.app")
        )
        await #expect(throws: HelperAuthorizationError.unauthorizedUser) {
            try await self.issue(wrongUser, plan: fixture.plan)
        }

        let denied = makeBoundary(fixture.target, userAuthorizationAccepted: false)
        await #expect(throws: HelperAuthorizationError.invalidUserAuthorization) {
            try await self.issue(denied, plan: fixture.plan)
        }
    }

    @Test("Ticket is bound to authenticated client, plan, schema, engine, and confirmation expiry")
    func exactBinding() async throws {
        let fixture = try makeFixture()
        let boundary = makeBoundary(fixture.target)
        let ticket = try await issue(boundary, plan: fixture.plan)

        await #expect(throws: HelperAuthorizationError.unauthenticatedClient) {
            try await boundary.authorize(self.envelope(fixture.plan, ticket), auditToken: Data("other".utf8))
        }
        await #expect(throws: HelperAuthorizationError.invalidEnvelope) {
            let changed = self.envelope(fixture.plan, ticket, fingerprint: "tampered")
            _ = try await boundary.authorize(changed, auditToken: self.auditToken)
        }
        await #expect(throws: HelperAuthorizationError.incompatibleSchema) {
            let changed = self.envelope(fixture.plan, ticket, schema: 2)
            _ = try await boundary.authorize(changed, auditToken: self.auditToken)
        }
        await #expect(throws: HelperAuthorizationError.incompatibleEngine) {
            let changed = self.envelope(fixture.plan, ticket, engine: "other")
            _ = try await boundary.authorize(changed, auditToken: self.auditToken)
        }
        await #expect(throws: HelperAuthorizationError.invalidConfirmation) {
            let changed = self.envelope(
                fixture.plan, ticket,
                confirmationExpiry: self.instant.addingTimeInterval(40)
            )
            _ = try await boundary.authorize(changed, auditToken: self.auditToken)
        }

        // Failed validation does not consume the single-use ticket.
        _ = try await boundary.authorize(envelope(fixture.plan, ticket), auditToken: auditToken)
    }

    @Test("Tickets are short-lived, bounded, and expired replay state is purged")
    func boundedTickets() async throws {
        let fixture = try makeFixture()
        let clock = LockedClock(instant)
        let generator = TicketGenerator([
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
            String(repeating: "c", count: 64)
        ])
        let boundary = makeBoundary(
            fixture.target, clock: clock, generator: generator, maximumOutstandingTickets: 1
        )
        let first = try await issue(boundary, plan: fixture.plan)
        #expect(first.expiresAt == instant.addingTimeInterval(30))
        await #expect(throws: HelperAuthorizationError.ticketCapacityReached) {
            try await self.issue(boundary, plan: fixture.plan)
        }
        clock.value = instant.addingTimeInterval(31)
        await #expect(throws: HelperAuthorizationError.expiredTicket) {
            try await boundary.authorize(self.envelope(fixture.plan, first), auditToken: self.auditToken)
        }

        // Expiry frees bounded storage. Use a newly valid plan because the original instant moved.
        let later = try makeFixture(now: clock.value)
        _ = try await issue(boundary, plan: later.plan)
    }

    @Test("Only roots beneath the trusted user's home are accepted")
    func trustedUserRootsOnly() async throws {
        let systemPlan = try makeFixture(
            kind: .uninstall, action: .moveToTrash, path: "/Applications/Other.app"
        )
        let boundary = makeBoundary(systemPlan.target)
        let ticket = try await issue(boundary, plan: systemPlan.plan)
        await #expect(throws: HelperAuthorizationError.unsafePathResolution) {
            try await boundary.authorize(self.envelope(systemPlan.plan, ticket), auditToken: self.auditToken)
        }

        let otherUser = try makeFixture(path: "/Users/other/Library/Caches/example.cache")
        let otherBoundary = makeBoundary(otherUser.target)
        let otherTicket = try await issue(otherBoundary, plan: otherUser.plan)
        await #expect(throws: HelperAuthorizationError.unsafePathResolution) {
            try await otherBoundary.authorize(
                self.envelope(otherUser.plan, otherTicket), auditToken: self.auditToken
            )
        }
    }

    @Test("No-follow and stable target evidence are revalidated before ticket consumption")
    func targetEvidence() async throws {
        let fixture = try makeFixture()
        let unsafe = replacing(fixture.target, noFollow: false)
        let boundary = makeBoundary(unsafe)
        let ticket = try await issue(boundary, plan: fixture.plan)
        await #expect(throws: HelperAuthorizationError.unsafePathResolution) {
            try await boundary.authorize(self.envelope(fixture.plan, ticket), auditToken: self.auditToken)
        }

        let stale = replacing(fixture.target, identity: "different-node")
        let staleBoundary = makeBoundary(stale)
        let staleTicket = try await issue(staleBoundary, plan: fixture.plan)
        await #expect(throws: HelperAuthorizationError.targetChanged) {
            try await staleBoundary.authorize(
                self.envelope(fixture.plan, staleTicket), auditToken: self.auditToken
            )
        }
    }

    @Test("Replacement hash and empty-directory evidence remain action-bound")
    func actionEvidence() async throws {
        let original = Data("before".utf8)
        let replacement = Data("after".utf8)
        let sourceHash = sha256(original)
        let replace = try makeFixture(
            kind: .optimize, action: .replaceFile,
            path: "/Users/test/Library/Preferences/example.plist",
            byteCount: Int64(original.count),
            payload: .init(
                replacementContentBase64: replacement.base64EncodedString(),
                sourceSHA256: sourceHash, postconditionSHA256: sha256(replacement),
                directoryDeletionPolicy: nil
            ), contentSHA256: String(repeating: "f", count: 64)
        )
        let replaceBoundary = makeBoundary(replace.target)
        let replaceTicket = try await issue(replaceBoundary, plan: replace.plan)
        await #expect(throws: HelperAuthorizationError.replacementSourceChanged) {
            try await replaceBoundary.authorize(
                self.envelope(replace.plan, replaceTicket), auditToken: self.auditToken
            )
        }

        let directory = try makeFixture(
            action: .removeDirectory, path: "/Users/test/Library/Caches/not-empty",
            nodeKind: .directory, byteCount: 0,
            payload: .init(
                replacementContentBase64: nil, sourceSHA256: nil, postconditionSHA256: nil,
                directoryDeletionPolicy: .emptyOnly
            ), directoryEntryCount: 1
        )
        let directoryBoundary = makeBoundary(directory.target)
        let directoryTicket = try await issue(directoryBoundary, plan: directory.plan)
        await #expect(throws: HelperAuthorizationError.directoryNotEmpty) {
            try await directoryBoundary.authorize(
                self.envelope(directory.plan, directoryTicket), auditToken: self.auditToken
            )
        }
    }

    @Test("Resolver cannot alias two operations to one opened handle")
    func duplicateHandles() async throws {
        let fixture = try makeFixture(operationCount: 2)
        let boundary = makeBoundary(fixture.target)
        let ticket = try await issue(boundary, plan: fixture.plan)
        await #expect(throws: HelperAuthorizationError.duplicateActionHandle) {
            try await boundary.authorize(self.envelope(fixture.plan, ticket), auditToken: self.auditToken)
        }
    }

    private struct Fixture {
        let plan: ExecutionPlan
        let target: ResolvedActionTarget
    }

    private func makeFixture(
        now: Date? = nil,
        kind: ExecutionPlanKind = .clean,
        action: ExecutionAction = .removeFile,
        path: String = "/Users/test/Library/Caches/example.cache",
        nodeKind: ExpectedNodeKind = .file,
        byteCount: Int64 = 6,
        payload: ExecutionActionPayload? = nil,
        contentSHA256: String? = nil,
        directoryEntryCount: Int? = nil,
        operationCount: Int = 1
    ) throws -> Fixture {
        let base = now ?? instant
        let operations = (1...operationCount).map { index in
            ExecutionPlanOperation(
                id: "operation-\(index)", action: action,
                target: .init(
                    path: index == 1 ? path : path + ".\(index)", nodeKind: nodeKind,
                    byteCount: byteCount, modificationTime: base, fileIdentifier: "node-1"
                ), reason: "Fixture", payload: payload
            )
        }
        let unsigned = ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: "Mole 2.0",
                createdAt: base.addingTimeInterval(-10), expiresAt: base.addingTimeInterval(300),
                fingerprint: ""
            ), kind: kind, operations: operations
        )
        let plan = ExecutionPlan(
            metadata: .init(
                schemaVersion: 1, engineVersion: "Mole 2.0",
                createdAt: unsigned.metadata.createdAt, expiresAt: unsigned.metadata.expiresAt,
                fingerprint: try unsigned.calculatedFingerprint()
            ), kind: kind, operations: operations
        )
        let evidence = ResolvedFilesystemEvidence(
            nodeKind: nodeKind, byteCount: byteCount, modificationTime: base,
            fileIdentifier: "node-1", rootIdentifier: "volume-1",
            allPathComponentsResolvedWithoutFollowingLinks: true,
            contentSHA256: contentSHA256, directoryEntryCount: directoryEntryCount
        )
        return .init(
            plan: plan,
            target: .init(handle: .init(opaqueValue: "opaque-open-descriptor"), evidence: evidence)
        )
    }

    private func makeBoundary(
        _ target: ResolvedActionTarget,
        authenticatedClient: AuthenticatedHelperClient? = .init(
            userID: 501, clientIdentifier: "signed.app"
        ),
        userAuthorizationAccepted: Bool = true,
        clock: LockedClock? = nil,
        generator: TicketGenerator? = nil,
        maximumOutstandingTickets: Int = 8
    ) -> HelperAuthorizationBoundary {
        let clock = clock ?? LockedClock(instant)
        let generator = generator ?? TicketGenerator([ticketValue])
        return .init(
            configuration: .init(
                protocolVersion: 1, planSchemaVersion: 1, engineVersion: "Mole 2.0",
                capabilities: [HelperAuthorizationProtocol.structuredExecutionCapability],
                trustedUserID: 501, trustedHomeRoot: "/Users/test", ticketLifetime: 30,
                maximumOutstandingTickets: maximumOutstandingTickets
            ),
            resolver: FixtureActionResolver(target: target),
            clientAuthenticator: FixtureClientAuthenticator(
                expectedToken: auditToken, client: authenticatedClient
            ),
            userAuthorizationVerifier: FixtureAuthorizationVerifier(
                expectedForm: authorization, accepted: userAuthorizationAccepted
            ),
            now: { clock.value }, makeTicketValue: { generator.next() }
        )
    }

    private func issue(_ boundary: HelperAuthorizationBoundary, plan: ExecutionPlan) async throws -> HelperAuthorizationTicket {
        try await boundary.issueTicket(
            for: plan, confirmationExpiresAt: plan.metadata.createdAt.addingTimeInterval(60),
            auditToken: auditToken, userAuthorizationExternalForm: authorization
        )
    }

    private func envelope(
        _ plan: ExecutionPlan,
        _ ticket: HelperAuthorizationTicket,
        fingerprint: String? = nil,
        schema: Int? = nil,
        engine: String? = nil,
        confirmationExpiry: Date? = nil
    ) -> HelperAuthorizationEnvelope {
        .init(
            protocolVersion: 1, plan: plan,
            planFingerprint: fingerprint ?? plan.metadata.fingerprint,
            planSchemaVersion: schema ?? 1, engineVersion: engine ?? "Mole 2.0",
            requiredCapability: HelperAuthorizationProtocol.structuredExecutionCapability,
            authorizationTicket: ticket.value,
            confirmationExpiresAt: confirmationExpiry ?? plan.metadata.createdAt.addingTimeInterval(60)
        )
    }

    private func replacing(
        _ target: ResolvedActionTarget,
        identity: String? = nil,
        noFollow: Bool? = nil
    ) -> ResolvedActionTarget {
        let old = target.evidence
        return .init(
            handle: target.handle,
            evidence: .init(
                nodeKind: old.nodeKind, byteCount: old.byteCount,
                modificationTime: old.modificationTime,
                fileIdentifier: identity ?? old.fileIdentifier,
                rootIdentifier: old.rootIdentifier,
                allPathComponentsResolvedWithoutFollowingLinks:
                    noFollow ?? old.allPathComponentsResolvedWithoutFollowingLinks,
                contentSHA256: old.contentSHA256, directoryEntryCount: old.directoryEntryCount
            )
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FixtureClientAuthenticator: HelperClientAuthenticating {
    let expectedToken: Data
    let client: AuthenticatedHelperClient?

    func authenticate(auditToken: Data) throws -> AuthenticatedHelperClient {
        guard auditToken == expectedToken, let client else {
            throw HelperAuthorizationError.unauthenticatedClient
        }
        return client
    }
}

private struct FixtureAuthorizationVerifier: UserAuthorizationVerifying {
    let expectedForm: Data
    let accepted: Bool

    func verify(externalForm: Data, forTrustedUserID userID: UInt32) throws -> Bool {
        externalForm == expectedForm && userID == 501 && accepted
    }
}

private struct FixtureActionResolver: FilesystemActionResolving {
    let target: ResolvedActionTarget

    func resolveAction(path: String, beneathTrustedRoot rootPath: String) throws -> ResolvedActionTarget {
        target
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class TicketGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) { self.values = values }
    func next() -> String { lock.withLock { values.removeFirst() } }
}
