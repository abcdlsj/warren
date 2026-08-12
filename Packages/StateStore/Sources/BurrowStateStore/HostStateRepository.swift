/// A durable boundary for Host-owned state.  Implementations are injected;
/// this protocol does not prescribe a file location or create a singleton.
public protocol HostStateRepository: Sendable {
    func load() async throws -> PersistedHostState
    func save(_ state: PersistedHostState) async throws
}

public enum HostStateRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptedJSON(reason: String)
    case readFailed(path: String, reason: String)
    case directoryCreationFailed(path: String, reason: String)
    case encodingFailed(reason: String)
    case atomicWriteFailed(path: String, reason: String)

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
