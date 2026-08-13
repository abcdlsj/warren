import WarrenDomain
import Foundation

public struct PersistedRequestReceipt: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let commandKind: String
    public let resourceID: String
    public let completedAt: Date

    public init(
        requestID: UUID,
        commandKind: String,
        resourceID: String,
        completedAt: Date
    ) {
        self.requestID = requestID
        self.commandKind = commandKind
        self.resourceID = resourceID
        self.completedAt = completedAt
    }
}

/// Versioned, durable Host-owned state.
///
/// The collections are intentionally separate so relationships remain
/// represented by WarrenDomain's strong identifiers.  Device-local layout and
/// connection-scoped control state do not belong here.
public struct PersistedHostState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var hosts: [WarrenDomain.Host]
    public var projects: [Project]
    public var workspaces: [Workspace]
    public var terminalSessions: [PersistedTerminalSession]
    public var requestReceipts: [PersistedRequestReceipt]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        hosts: [WarrenDomain.Host] = [],
        projects: [Project] = [],
        workspaces: [Workspace] = [],
        terminalSessions: [PersistedTerminalSession] = [],
        requestReceipts: [PersistedRequestReceipt] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
        self.projects = projects
        self.workspaces = workspaces
        self.terminalSessions = terminalSessions
        self.requestReceipts = requestReceipts
    }

    public static var empty: Self { Self() }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hosts
        case projects
        case workspaces
        case terminalSessions
        case requestReceipts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hosts = try container.decode([WarrenDomain.Host].self, forKey: .hosts)
        projects = try container.decode([Project].self, forKey: .projects)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        terminalSessions = try container.decode(
            [PersistedTerminalSession].self,
            forKey: .terminalSessions
        )
        requestReceipts = try container.decodeIfPresent(
            [PersistedRequestReceipt].self,
            forKey: .requestReceipts
        ) ?? []
    }
}
