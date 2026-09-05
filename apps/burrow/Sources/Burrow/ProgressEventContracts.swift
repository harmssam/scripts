import Foundation

enum ProgressEventSchema {
    static let current = 1
}

enum ExecutionProgressEventKind: String, Codable, Sendable, Equatable {
    case started
    case operationStarted
    case operationCompleted
    case operationFailed
    case completed
    case failed
}

struct ExecutionProgressEvent: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let planFingerprint: String
    let sequence: Int
    let timestamp: Date
    let kind: ExecutionProgressEventKind
    let operationID: String?
    let completedBytes: Int64?
    let message: String?
}

enum ProgressEventContract {
    static func decodeJSONL(_ data: Data, for plan: ExecutionPlan) throws -> [ExecutionProgressEvent] {
        _ = try plan.validated(at: plan.metadata.createdAt)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProgressEventValidationError.invalidUTF8
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last == "" else { throw ProgressEventValidationError.incompleteFinalLine }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events: [ExecutionProgressEvent] = try lines.dropLast().enumerated().map { index, line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ProgressEventValidationError.blankLine(index + 1)
            }
            do { return try decoder.decode(ExecutionProgressEvent.self, from: Data(line.utf8)) }
            catch { throw ProgressEventValidationError.malformedLine(index + 1) }
        }
        return try validate(events, for: plan)
    }

    static func validate(_ events: [ExecutionProgressEvent], for plan: ExecutionPlan) throws -> [ExecutionProgressEvent] {
        // The event stream is never trusted to confer validity on its plan. Validate the
        // complete contract and fingerprint first, at the moment execution claims to start.
        _ = try plan.validated(at: events.first?.timestamp ?? plan.metadata.createdAt)
        guard !events.isEmpty else { throw ProgressEventValidationError.emptyStream }
        guard events[0].kind == .started, events[0].operationID == nil else {
            throw ProgressEventValidationError.firstEventMustBeStarted
        }
        for (index, event) in events.enumerated() {
            try validatePrefix(event, preceding: Array(events[..<index]), for: plan)
        }
        let operationIDs = Set(plan.operations.map(\.id))
        var started = Set<String>()
        var finished = Set<String>()
        var failedOperations = Set<String>()
        var terminal = false
        var previousTimestamp: Date?

        for (index, event) in events.enumerated() {
            guard event.schemaVersion == ProgressEventSchema.current else {
                throw ProgressEventValidationError.unsupportedSchema(event.schemaVersion)
            }
            guard event.planFingerprint == plan.metadata.fingerprint else {
                throw ProgressEventValidationError.planMismatch
            }
            guard event.sequence == index else {
                throw ProgressEventValidationError.invalidSequence(expected: index, actual: event.sequence)
            }
            guard !terminal else { throw ProgressEventValidationError.eventAfterTerminal }
            guard event.completedBytes.map({ $0 >= 0 }) ?? true else {
                throw ProgressEventValidationError.invalidByteCount
            }
            if let previousTimestamp, event.timestamp < previousTimestamp {
                throw ProgressEventValidationError.nonmonotonicTimestamp
            }
            previousTimestamp = event.timestamp
            switch event.kind {
            case .started:
                guard index == 0, event.operationID == nil else { throw ProgressEventValidationError.invalidTransition }
            case .operationStarted:
                let id = try operationID(event, known: operationIDs)
                guard started.insert(id).inserted else { throw ProgressEventValidationError.invalidTransition }
            case .operationCompleted, .operationFailed:
                let id = try operationID(event, known: operationIDs)
                guard started.contains(id), finished.insert(id).inserted else { throw ProgressEventValidationError.invalidTransition }
                if event.kind == .operationFailed { failedOperations.insert(id) }
            case .completed:
                guard event.operationID == nil, finished == operationIDs, failedOperations.isEmpty else {
                    throw ProgressEventValidationError.invalidTransition
                }
                terminal = true
            case .failed:
                guard event.operationID == nil else { throw ProgressEventValidationError.invalidTransition }
                terminal = true
            }
        }
        guard terminal else { throw ProgressEventValidationError.missingTerminalEvent }
        return events
    }

    /// Validates one event against an already accepted prefix. Streaming transports should
    /// call this before exposing each event to state or receipt code.
    static func validatePrefix(
        _ event: ExecutionProgressEvent,
        preceding events: [ExecutionProgressEvent],
        for plan: ExecutionPlan
    ) throws {
        _ = try plan.validated(at: events.first?.timestamp ?? event.timestamp)
        guard event.schemaVersion == ProgressEventSchema.current else {
            throw ProgressEventValidationError.unsupportedSchema(event.schemaVersion)
        }
        guard event.planFingerprint == plan.metadata.fingerprint else { throw ProgressEventValidationError.planMismatch }
        guard event.sequence == events.count else {
            throw ProgressEventValidationError.invalidSequence(expected: events.count, actual: event.sequence)
        }
        guard event.completedBytes.map({ $0 >= 0 }) ?? true else {
            throw ProgressEventValidationError.invalidByteCount
        }
        if let previous = events.last {
            guard event.timestamp >= previous.timestamp else { throw ProgressEventValidationError.nonmonotonicTimestamp }
            guard previous.kind != .completed && previous.kind != .failed else {
                throw ProgressEventValidationError.eventAfterTerminal
            }
        }
        guard !events.isEmpty || (event.kind == .started && event.operationID == nil) else {
            throw ProgressEventValidationError.firstEventMustBeStarted
        }

        let known = Set(plan.operations.map(\.id))
        let started = Set(events.filter { $0.kind == .operationStarted }.compactMap(\.operationID))
        let finished = Set(events.filter { $0.kind == .operationCompleted || $0.kind == .operationFailed }.compactMap(\.operationID))
        switch event.kind {
        case .started:
            guard events.isEmpty, event.operationID == nil, event.completedBytes == nil else {
                throw ProgressEventValidationError.invalidTransition
            }
        case .operationStarted:
            guard event.completedBytes == nil else { throw ProgressEventValidationError.invalidTransition }
            guard let id = event.operationID, known.contains(id) else {
                throw ProgressEventValidationError.unknownOperation(event.operationID)
            }
            guard !started.contains(id), !finished.contains(id) else { throw ProgressEventValidationError.invalidTransition }
        case .operationCompleted, .operationFailed:
            guard let id = event.operationID, known.contains(id) else {
                throw ProgressEventValidationError.unknownOperation(event.operationID)
            }
            guard started.contains(id), !finished.contains(id) else { throw ProgressEventValidationError.invalidTransition }
            if event.kind == .operationCompleted {
                guard let bytes = event.completedBytes else {
                    throw ProgressEventValidationError.missingCompletedByteCount(operationID: id)
                }
                if let planned = plan.operations.first(where: { $0.id == id })?.target.byteCount,
                   bytes > planned {
                    throw ProgressEventValidationError.byteCountExceedsPlan(operationID: id)
                }
            } else if event.completedBytes != nil {
                throw ProgressEventValidationError.invalidTransition
            }
        case .completed:
            guard event.operationID == nil,
                  finished == known,
                  !events.contains(where: { $0.kind == .operationFailed }) else {
                throw ProgressEventValidationError.invalidTransition
            }
            try validateTerminalBytes(event, preceding: events)
        case .failed:
            guard event.operationID == nil else { throw ProgressEventValidationError.invalidTransition }
            try validateTerminalBytes(event, preceding: events)
        }
    }

    private static func validateTerminalBytes(
        _ event: ExecutionProgressEvent,
        preceding events: [ExecutionProgressEvent]
    ) throws {
        let successfulBytes = events.filter { $0.kind == .operationCompleted }
            .compactMap(\.completedBytes).reduce(0, +)
        guard event.completedBytes == successfulBytes else {
            throw ProgressEventValidationError.terminalByteCountMismatch(expected: successfulBytes, actual: event.completedBytes)
        }
    }

    private static func operationID(_ event: ExecutionProgressEvent, known: Set<String>) throws -> String {
        guard let id = event.operationID, known.contains(id) else {
            throw ProgressEventValidationError.unknownOperation(event.operationID)
        }
        return id
    }
}

enum ProgressEventValidationError: Error, Equatable, Sendable {
    case invalidUTF8
    case incompleteFinalLine
    case blankLine(Int)
    case malformedLine(Int)
    case emptyStream
    case firstEventMustBeStarted
    case unsupportedSchema(Int)
    case planMismatch
    case invalidSequence(expected: Int, actual: Int)
    case unknownOperation(String?)
    case invalidTransition
    case invalidByteCount
    case byteCountExceedsPlan(operationID: String)
    case missingCompletedByteCount(operationID: String)
    case terminalByteCountMismatch(expected: Int64, actual: Int64?)
    case nonmonotonicTimestamp
    case eventAfterTerminal
    case missingTerminalEvent
}
