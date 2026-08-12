import Foundation

public struct Host: Identifiable, Codable, Hashable, Sendable {
    public let id: HostID
    public var name: String

    public init(id: HostID = HostID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: ProjectID
    public let hostID: HostID
    public var name: String
    public var rootPath: String

    public init(
        id: ProjectID = ProjectID(),
        hostID: HostID,
        name: String,
        rootPath: String
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.rootPath = rootPath
    }
}

public struct Workspace: Identifiable, Codable, Hashable, Sendable {
    public let id: WorkspaceID
    public let projectID: ProjectID
    public var name: String
    public var path: String
    public var branch: String?

    public init(
        id: WorkspaceID = WorkspaceID(),
        projectID: ProjectID,
        name: String,
        path: String,
        branch: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.path = path
        self.branch = branch
    }
}

public struct TerminalSession: Identifiable, Codable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID
    public var epoch: UInt64
    public var sequence: UInt64

    public init(
        id: TerminalSessionID = TerminalSessionID(),
        workspaceID: WorkspaceID,
        epoch: UInt64 = 0,
        sequence: UInt64 = 0
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.epoch = epoch
        self.sequence = sequence
    }
}

public struct TerminalAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: TerminalAttachmentID
    public let sessionID: TerminalSessionID
    public let clientID: ClientID

    public init(
        id: TerminalAttachmentID = TerminalAttachmentID(),
        sessionID: TerminalSessionID,
        clientID: ClientID
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientID = clientID
    }
}

public struct Client: Identifiable, Codable, Hashable, Sendable {
    public let id: ClientID
    public var name: String

    public init(id: ClientID = ClientID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A device-local layout. Its geometry is not shared across clients or owned by the host.
public struct ClientLayout: Codable, Hashable, Sendable {
    public let clientID: ClientID
    public var sidebarWidth: Double
    public var sidebarCollapsed: Bool
    public var windowSize: LayoutSize?

    public init(
        clientID: ClientID,
        sidebarWidth: Double = 240,
        sidebarCollapsed: Bool = false,
        windowSize: LayoutSize? = nil
    ) {
        self.clientID = clientID
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.windowSize = windowSize
    }
}

public struct LayoutSize: Codable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    /// Layout dimensions must be finite and strictly positive.
    public init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }
}

public struct TerminalSize: Codable, Hashable, Sendable {
    public let columns: Int
    public let rows: Int

    /// A terminal cannot have a zero or negative viewport.
    public init?(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return nil }
        self.columns = columns
        self.rows = rows
    }
}

public struct ControlLease: Identifiable, Codable, Hashable, Sendable {
    public let id: ControlLeaseID
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public var issuedAt: Date
    public var expiresAt: Date

    public init?(
        id: ControlLeaseID = ControlLeaseID(),
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        issuedAt: Date,
        expiresAt: Date
    ) {
        guard expiresAt > issuedAt else { return nil }
        self.id = id
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// A lease is active at its issue instant and ceases to be active at expiry.
    public func isActive(at date: Date) -> Bool {
        issuedAt <= date && date < expiresAt
    }
}

public struct RecoveryAnchor: Codable, Hashable, Sendable {
    public let epoch: UInt64
    public let sequence: UInt64

    public init(epoch: UInt64, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }
}

/// The session template Burrow used to launch a terminal. This is a UI-facing
/// hint on the durable Host record: the runtime itself only sees a shell and
/// an optional launch command, so an unknown future kind can never make a
/// session unrecoverable.
public enum TerminalSessionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case shell
    case claude
    case codex
    case custom

    public var displayName: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .custom: "Custom"
        }
    }

}

/// A value-only request for starting one terminal session.
///
/// The durable `kind` describes what was launched. The command and title stay
/// explicit because future user-defined presets may share a kind while using
/// different commands. No UI callback or runtime handle crosses this boundary.
public struct TerminalSessionLaunchRequest: Hashable, Sendable {
    public let kind: TerminalSessionKind
    public let command: String?
    public let title: String?

    public init(
        kind: TerminalSessionKind,
        command: String? = nil,
        title: String? = nil
    ) {
        let normalizedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.command = normalizedCommand?.isEmpty == false ? normalizedCommand : nil
        self.title = normalizedTitle?.isEmpty == false ? normalizedTitle : nil
    }

    public static let shell = Self(kind: .shell)
    public static let claude = Self(kind: .claude, command: "claude", title: "Claude Code")
    public static let codex = Self(kind: .codex, command: "codex", title: "Codex")
}
