import WarrenDomain
import Foundation

/// A durable boundary for Host-owned state.  Implementations are injected;
/// this protocol does not prescribe a file location or create a singleton.
public protocol HostStateRepository: Sendable {
    func load() async throws -> PersistedHostState
    func save(_ state: PersistedHostState) async throws
    func updateSessionCursors(_ cursors: [TerminalSessionID: RecoveryAnchor]) async throws
    func updateSessionSize(sessionID: TerminalSessionID, size: TerminalSize) async throws
    func updateSessionAgent(sessionID: TerminalSessionID, agentSessionID: String?) async throws
    func markSessionEnded(sessionID: TerminalSessionID, endedAt: Date) async throws
}

public extension HostStateRepository {
    func updateSessionSize(sessionID: TerminalSessionID, size: TerminalSize) async throws {
        var state = try await load()
        guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        state.terminalSessions[index].terminalSize = size
        try await save(state)
    }
    func updateSessionAgent(sessionID: TerminalSessionID, agentSessionID: String?) async throws {
        var state = try await load()
        guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        state.terminalSessions[index].agentSessionID = agentSessionID
        try await save(state)
    }
    func markSessionEnded(sessionID: TerminalSessionID, endedAt: Date) async throws {
        var state = try await load()
        guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        state.terminalSessions[index].lifecycle = .ended
        state.terminalSessions[index].endedAt = endedAt
        try await save(state)
    }
    /// Compatibility fallback for non-SQLite repositories. Production SQLite
    /// uses a single bounded UPDATE transaction instead.
    func updateSessionCursors(_ cursors: [TerminalSessionID: RecoveryAnchor]) async throws {
        guard !cursors.isEmpty else { return }
        var state = try await load()
        for index in state.terminalSessions.indices {
            guard let anchor = cursors[state.terminalSessions[index].id] else { continue }
            let current = RecoveryAnchor(epoch: state.terminalSessions[index].epoch, sequence: state.terminalSessions[index].sequence)
            if anchor.epoch > current.epoch || (anchor.epoch == current.epoch && anchor.sequence > current.sequence) {
                state.terminalSessions[index].epoch = anchor.epoch
                state.terminalSessions[index].sequence = anchor.sequence
            }
        }
        try await save(state)
    }
}

public enum HostStateRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptedJSON(reason: String)
    case readFailed(path: String, reason: String)
    case directoryCreationFailed(path: String, reason: String)
    case encodingFailed(reason: String)
    case atomicWriteFailed(path: String, reason: String)
    case databaseOpenFailed(path: String, reason: String)
    case databaseReadFailed(path: String, reason: String)
    case databaseWriteFailed(path: String, reason: String)
    case invalidDatabaseValue(table: String, column: String, value: String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            return "Unsupported Host state schema version \(found); supported version is \(supported)."
        case let .corruptedJSON(reason):
            return "Host state JSON is corrupted: \(reason)"
        case let .readFailed(path, reason):
            return "Could not read Host state at \(path): \(reason)"
        case let .directoryCreationFailed(path, reason):
            return "Could not create Host state directory at \(path): \(reason)"
        case let .encodingFailed(reason):
            return "Could not encode Host state: \(reason)"
        case let .atomicWriteFailed(path, reason):
            return "Could not atomically write Host state at \(path): \(reason)"
        case let .databaseOpenFailed(path, reason):
            return "Could not open Host database at \(path): \(reason)"
        case let .databaseReadFailed(path, reason):
            return "Could not read Host database at \(path): \(reason)"
        case let .databaseWriteFailed(path, reason):
            return "Could not write Host database at \(path): \(reason)"
        case let .invalidDatabaseValue(table, column, value):
            return "Invalid value in \(table).\(column): \(value)"
        }
    }
}

extension HostStateRepositoryError {
    static func validateSupportedSchema(_ state: PersistedHostState) throws {
        guard state.schemaVersion >= 1,
              state.schemaVersion <= PersistedHostState.currentSchemaVersion else {
            throw Self.unsupportedSchemaVersion(
                found: state.schemaVersion,
                supported: PersistedHostState.currentSchemaVersion
            )
        }
    }
}
