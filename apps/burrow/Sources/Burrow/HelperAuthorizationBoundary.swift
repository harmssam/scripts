import Foundation

enum HelperAuthorizationProtocol {
    static let version = 1
    static let structuredExecutionCapability = "burrow-plan-v1"
}

struct HelperAuthorizationEnvelope: Sendable, Equatable {
    let protocolVersion: Int
    let plan: ExecutionPlan
    let planFingerprint: String
    let planSchemaVersion: Int
    let engineVersion: String
    let requiredCapability: String
    let authorizationTicket: String
    let confirmationExpiresAt: Date
}

struct HelperAuthorizationConfiguration: Sendable, Equatable {
    let protocolVersion: Int
    let planSchemaVersion: Int
    let engineVersion: String
    let capabilities: Set<String>
    let trustedUserID: UInt32
    let trustedHomeRoot: String
    let ticketLifetime: TimeInterval
    let maximumOutstandingTickets: Int
}

struct AuthenticatedHelperClient: Sendable, Equatable {
    let userID: UInt32
    /// Stable identity derived from an authenticated audit token, never a caller label.
    let clientIdentifier: String
}

protocol HelperClientAuthenticating: Sendable {
    func authenticate(auditToken: Data) throws -> AuthenticatedHelperClient
}

protocol UserAuthorizationVerifying: Sendable {
    func verify(externalForm: Data, forTrustedUserID userID: UInt32) throws -> Bool
}

struct HelperAuthorizationTicket: Sendable, Equatable {
    let value: String
    let expiresAt: Date
}

/// Opaque capability backed by an already-open descriptor-relative target. It deliberately
/// contains no pathname, so a future executor cannot reopen the target by path.
struct ResolvedActionHandle: Sendable, Hashable {
    fileprivate let value: String

    init(opaqueValue: String) {
        value = opaqueValue
    }
}

struct ResolvedFilesystemEvidence: Sendable, Equatable {
    let nodeKind: ExpectedNodeKind
    let byteCount: Int64
    let modificationTime: Date
    let fileIdentifier: String
    let rootIdentifier: String
    let allPathComponentsResolvedWithoutFollowingLinks: Bool
    let contentSHA256: String?
    let directoryEntryCount: Int?
}

struct ResolvedActionTarget: Sendable, Equatable {
    let handle: ResolvedActionHandle
    let evidence: ResolvedFilesystemEvidence
}

/// Implementations must open the allowed root first, traverse beneath that descriptor using
/// no-follow/openat-style operations, and retain that exact opened target in the returned handle.
/// A later action must be atomic and descriptor-relative; a second pathname lookup is forbidden.
protocol FilesystemActionResolving: Sendable {
    func resolveAction(path: String, beneathTrustedRoot rootPath: String) throws -> ResolvedActionTarget
}

struct AuthorizedHelperAction: Sendable, Equatable {
    let operationID: String
    let action: ExecutionAction
    let handle: ResolvedActionHandle
    let evidence: ResolvedFilesystemEvidence
    let payload: ExecutionActionPayload?
}

struct AuthorizedHelperRequest: Sendable, Equatable {
    let planFingerprint: String
    let planSchemaVersion: Int
    let engineVersion: String
    let actions: [AuthorizedHelperAction]
}

enum HelperAuthorizationError: String, Error, Sendable, Equatable {
    case invalidEnvelope, incompatibleProtocol, incompatibleSchema, incompatibleEngine
    case missingCapability, invalidPlan, unauthenticatedClient, unauthorizedUser
    case invalidUserAuthorization, invalidTrustedHome, invalidConfirmation
    case ticketCapacityReached, invalidTicket, expiredTicket, replayedAuthorization
    case unsafePathResolution, duplicateActionHandle, targetChanged
    case replacementSourceChanged, directoryNotEmpty
}

/// Plan-bound ticket issuance and action-boundary revalidation. This type cannot mutate files,
/// start processes, install XPC services, or connect to a production transport.
actor HelperAuthorizationBoundary {
    private struct TicketRecord: Sendable {
        let planFingerprint: String
        let planSchemaVersion: Int
        let engineVersion: String
        let confirmationExpiresAt: Date
        let userID: UInt32
        let trustedHomeRoot: String
        let clientIdentifier: String
        let expiresAt: Date
    }

    private let configuration: HelperAuthorizationConfiguration
    private let resolver: any FilesystemActionResolving
    private let clientAuthenticator: any HelperClientAuthenticating
    private let userAuthorizationVerifier: any UserAuthorizationVerifying
    private let now: @Sendable () -> Date
    private let makeTicketValue: @Sendable () -> String
    private var outstandingTickets = [String: TicketRecord]()
    private var consumedTickets = [String: Date]()

    init(
        configuration: HelperAuthorizationConfiguration,
        resolver: any FilesystemActionResolving,
        clientAuthenticator: any HelperClientAuthenticating,
        userAuthorizationVerifier: any UserAuthorizationVerifying,
        now: @escaping @Sendable () -> Date = { Date() },
        makeTicketValue: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "") +
                UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.clientAuthenticator = clientAuthenticator
        self.userAuthorizationVerifier = userAuthorizationVerifier
        self.now = now
        self.makeTicketValue = makeTicketValue
    }

    /// Tickets are generated by the helper only after both injected trust checks succeed.
    func issueTicket(
        for plan: ExecutionPlan,
        confirmationExpiresAt: Date,
        auditToken: Data,
        userAuthorizationExternalForm: Data
    ) throws -> HelperAuthorizationTicket {
        let currentTime = now()
        purgeReplayState(at: currentTime)
        guard Self.isCanonicalTrustedHome(configuration.trustedHomeRoot) else {
            throw HelperAuthorizationError.invalidTrustedHome
        }
        let client = try authenticatedClient(auditToken)
        guard client.userID == configuration.trustedUserID else {
            throw HelperAuthorizationError.unauthorizedUser
        }
        let userAuthorized: Bool
        do {
            userAuthorized = try userAuthorizationVerifier.verify(
                externalForm: userAuthorizationExternalForm,
                forTrustedUserID: configuration.trustedUserID
            )
        } catch {
            throw HelperAuthorizationError.invalidUserAuthorization
        }
        guard userAuthorized else { throw HelperAuthorizationError.invalidUserAuthorization }
        let validated = try validatePlanBinding(plan, at: currentTime)
        guard confirmationExpiresAt > currentTime,
              confirmationExpiresAt <= validated.metadata.expiresAt else {
            throw HelperAuthorizationError.invalidConfirmation
        }
        guard configuration.ticketLifetime > 0, configuration.ticketLifetime <= 60,
              configuration.maximumOutstandingTickets > 0 else {
            throw HelperAuthorizationError.invalidEnvelope
        }
        guard outstandingTickets.count + consumedTickets.count < configuration.maximumOutstandingTickets else {
            throw HelperAuthorizationError.ticketCapacityReached
        }

        let value = makeTicketValue()
        guard Self.isValidTicketValue(value), outstandingTickets[value] == nil,
              consumedTickets[value] == nil else { throw HelperAuthorizationError.invalidTicket }
        let expiresAt = min(confirmationExpiresAt, currentTime.addingTimeInterval(configuration.ticketLifetime))
        outstandingTickets[value] = .init(
            planFingerprint: validated.metadata.fingerprint,
            planSchemaVersion: validated.metadata.schemaVersion,
            engineVersion: validated.metadata.engineVersion,
            confirmationExpiresAt: confirmationExpiresAt,
            userID: configuration.trustedUserID,
            trustedHomeRoot: configuration.trustedHomeRoot,
            clientIdentifier: client.clientIdentifier,
            expiresAt: expiresAt
        )
        return .init(value: value, expiresAt: expiresAt)
    }

    func authorize(_ envelope: HelperAuthorizationEnvelope, auditToken: Data) throws -> AuthorizedHelperRequest {
        let currentTime = now()
        consumedTickets = consumedTickets.filter { currentTime < $0.value }
        guard consumedTickets[envelope.authorizationTicket] == nil else {
            throw HelperAuthorizationError.replayedAuthorization
        }
        guard let ticket = outstandingTickets[envelope.authorizationTicket] else {
            throw HelperAuthorizationError.invalidTicket
        }
        guard currentTime < ticket.expiresAt else {
            outstandingTickets.removeValue(forKey: envelope.authorizationTicket)
            throw HelperAuthorizationError.expiredTicket
        }
        let client = try authenticatedClient(auditToken)
        guard client.userID == ticket.userID, client.clientIdentifier == ticket.clientIdentifier,
              ticket.userID == configuration.trustedUserID,
              ticket.trustedHomeRoot == configuration.trustedHomeRoot else {
            throw HelperAuthorizationError.unauthorizedUser
        }
        guard envelope.protocolVersion == configuration.protocolVersion,
              envelope.protocolVersion == HelperAuthorizationProtocol.version else {
            throw HelperAuthorizationError.incompatibleProtocol
        }
        guard envelope.planSchemaVersion == ticket.planSchemaVersion,
              envelope.planSchemaVersion == configuration.planSchemaVersion,
              envelope.planSchemaVersion == ExecutionPlanSchema.current,
              envelope.plan.metadata.schemaVersion == envelope.planSchemaVersion else {
            throw HelperAuthorizationError.incompatibleSchema
        }
        guard envelope.engineVersion == ticket.engineVersion,
              envelope.engineVersion == configuration.engineVersion,
              envelope.plan.metadata.engineVersion == envelope.engineVersion else {
            throw HelperAuthorizationError.incompatibleEngine
        }
        guard envelope.requiredCapability == HelperAuthorizationProtocol.structuredExecutionCapability,
              configuration.capabilities.contains(envelope.requiredCapability) else {
            throw HelperAuthorizationError.missingCapability
        }
        guard envelope.planFingerprint == ticket.planFingerprint,
              envelope.planFingerprint == envelope.plan.metadata.fingerprint else {
            throw HelperAuthorizationError.invalidEnvelope
        }
        guard envelope.confirmationExpiresAt == ticket.confirmationExpiresAt,
              currentTime < envelope.confirmationExpiresAt else {
            throw HelperAuthorizationError.invalidConfirmation
        }
        let plan = try validatePlanBinding(envelope.plan, at: currentTime)

        var handles = Set<ResolvedActionHandle>()
        var actions = [AuthorizedHelperAction]()
        for operation in plan.operations {
            guard let root = Self.allowedRoot(
                for: operation, planKind: plan.kind, trustedHomeRoot: ticket.trustedHomeRoot
            ) else { throw HelperAuthorizationError.unsafePathResolution }
            let resolved: ResolvedActionTarget
            do {
                resolved = try resolver.resolveAction(path: operation.target.path, beneathTrustedRoot: root)
            } catch { throw HelperAuthorizationError.unsafePathResolution }
            guard handles.insert(resolved.handle).inserted else {
                throw HelperAuthorizationError.duplicateActionHandle
            }
            try Self.revalidate(operation, resolved: resolved.evidence)
            actions.append(.init(
                operationID: operation.id, action: operation.action, handle: resolved.handle,
                evidence: resolved.evidence, payload: operation.payload
            ))
        }

        // Consumption occurs after full validation; the bounded tombstone lasts only until expiry.
        outstandingTickets.removeValue(forKey: envelope.authorizationTicket)
        consumedTickets[envelope.authorizationTicket] = ticket.expiresAt
        return .init(
            planFingerprint: plan.metadata.fingerprint,
            planSchemaVersion: plan.metadata.schemaVersion,
            engineVersion: plan.metadata.engineVersion,
            actions: actions
        )
    }

    private func authenticatedClient(_ auditToken: Data) throws -> AuthenticatedHelperClient {
        do {
            let client = try clientAuthenticator.authenticate(auditToken: auditToken)
            guard !client.clientIdentifier.isEmpty else {
                throw HelperAuthorizationError.unauthenticatedClient
            }
            return client
        } catch let error as HelperAuthorizationError { throw error }
        catch { throw HelperAuthorizationError.unauthenticatedClient }
    }

    private func validatePlanBinding(_ plan: ExecutionPlan, at date: Date) throws -> ExecutionPlan {
        guard plan.metadata.schemaVersion == configuration.planSchemaVersion else {
            throw HelperAuthorizationError.incompatibleSchema
        }
        guard plan.metadata.engineVersion == configuration.engineVersion else {
            throw HelperAuthorizationError.incompatibleEngine
        }
        do { return try plan.validated(at: date) }
        catch { throw HelperAuthorizationError.invalidPlan }
    }

    private func purgeReplayState(at date: Date) {
        outstandingTickets = outstandingTickets.filter { date < $0.value.expiresAt }
        consumedTickets = consumedTickets.filter { date < $0.value }
    }

    private static func revalidate(_ operation: ExecutionPlanOperation, resolved: ResolvedFilesystemEvidence) throws {
        guard resolved.allPathComponentsResolvedWithoutFollowingLinks,
              resolved.nodeKind != .symbolicLink, !resolved.rootIdentifier.isEmpty else {
            throw HelperAuthorizationError.unsafePathResolution
        }
        guard resolved.nodeKind == operation.target.nodeKind,
              resolved.byteCount == operation.target.byteCount,
              resolved.modificationTime == operation.target.modificationTime,
              resolved.fileIdentifier == operation.target.fileIdentifier else {
            throw HelperAuthorizationError.targetChanged
        }
        if operation.action == .replaceFile {
            guard let hash = operation.payload?.sourceSHA256, resolved.contentSHA256 == hash else {
                throw HelperAuthorizationError.replacementSourceChanged
            }
        }
        if operation.action == .removeDirectory {
            guard operation.payload?.directoryDeletionPolicy == .emptyOnly,
                  resolved.directoryEntryCount == 0 else {
                throw HelperAuthorizationError.directoryNotEmpty
            }
        }
    }

    private static func isValidTicketValue(_ value: String) -> Bool {
        (43...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    private static func isCanonicalTrustedHome(_ home: String) -> Bool {
        let components = home.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 2 && components[0] == "Users" &&
            URL(fileURLWithPath: home).standardizedFileURL.path == home && !home.hasSuffix("/")
    }

    private static func allowedRoot(
        for operation: ExecutionPlanOperation,
        planKind: ExecutionPlanKind,
        trustedHomeRoot: String
    ) -> String? {
        let roots: [String]
        switch (planKind, operation.action) {
        case (.clean, .removeFile), (.clean, .removeDirectory):
            roots = ["\(trustedHomeRoot)/Library/Caches", "\(trustedHomeRoot)/Library/Logs"]
        case (.optimize, .replaceFile), (.optimize, .removeFile):
            roots = ["\(trustedHomeRoot)/Library/Preferences"]
        case (.uninstall, .moveToTrash):
            roots = ["\(trustedHomeRoot)/Applications"]
        default:
            return nil
        }
        return roots.first { operation.target.path.hasPrefix($0 + "/") }
    }
}
