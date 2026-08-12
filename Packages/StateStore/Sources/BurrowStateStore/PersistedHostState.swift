import BurrowDomain

/// Versioned, durable Host-owned state.
///
/// The collections are intentionally separate so relationships remain
/// represented by BurrowDomain's strong identifiers.  Device-local layout and
/// connection-scoped control state do not belong here.
public struct PersistedHostState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var hosts: [Host]
    public var projects: [Project]
    public var workspaces: [Workspace]
    public var terminalSessions: [PersistedTerminalSession]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        hosts: [Host] = [],
        projects: [Project] = [],
        workspaces: [Workspace] = [],
        terminalSessions: [PersistedTerminalSession] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
        self.projects = projects
        self.workspaces = workspaces
        self.terminalSessions = terminalSessions
    }

    public static var empty: Self { Self() }
}
