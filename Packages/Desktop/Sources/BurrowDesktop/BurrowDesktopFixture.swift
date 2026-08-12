import Foundation
import BurrowClientCore
import BurrowDomain

/// A project and its device-local workspace rows for the desktop shell.
///
/// This is a value projection. It carries no Host process, persistence, or
/// transport behavior, and can therefore be rebuilt from Host/Client state
/// whenever the composition root receives an update.
public struct BurrowDesktopProjectGroup: Identifiable, Hashable, Sendable {
    public let project: Project
    public let workspaces: [Workspace]

    public var id: Project.ID { project.id }

    public init(project: Project, workspaces: [Workspace] = []) {
        self.project = project
        self.workspaces = workspaces
    }
}

/// Optional trailing inspector content. The shell owns its slot geometry.
public struct BurrowDesktopInspectorContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String = "inspector", title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// A client-owned terminal session shown in the sidebar and session tabs.
/// Workspaces describe filesystem contexts; sessions describe resumable
/// terminals attached to those contexts.
public struct BurrowDesktopSession: Identifiable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID
    public let tabID: String
    public let title: String
    public let kind: TerminalSessionKind
    public let state: BurrowDesktopSessionState

    public init(
        id: TerminalSessionID,
        workspaceID: WorkspaceID,
        tabID: String,
        title: String,
        kind: TerminalSessionKind = .shell,
        state: BurrowDesktopSessionState = .attached
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.title = title
        self.kind = kind
        self.state = state
    }
}

public enum BurrowDesktopSessionState: String, Hashable, Sendable {
    case disconnected
    case connecting
    case attached
    case reconnecting
    case exited
    case failed

    public var isActive: Bool {
        switch self {
        case .attached, .connecting, .reconnecting:
            true
        case .disconnected, .exited, .failed:
            false
        }
    }
}

/// Connection state rendered by the desktop chrome.
public enum BurrowDesktopConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case attached
    case reconnecting
    case failed

    public var isConnected: Bool {
        self == .attached
    }
}

/// Immutable data projection consumed by the production desktop shell.
///
/// The executable owns the mutable Host/Client models and creates this value
/// at its composition boundary. The views never mutate this projection and do
/// not know whether it came from an embedded Host, a test double, or a future
/// transport adapter.
public struct BurrowDesktopProjection: Sendable, Hashable {
    /// The small identity-only value used by SwiftUI when it only needs to
    /// validate selection.  Comparing the full projection here would walk
    /// every project, workspace, tab, and session mapping on every snapshot.
    public struct ReconciliationKey: Sendable, Hashable {
        public let projectIDs: [ProjectID]
        public let workspaceIDs: [WorkspaceID]
        public let tabIDs: [String]
        public let sessionIDs: [TerminalSessionID]
        public let inspectorID: String?

        fileprivate init(projection: BurrowDesktopProjection) {
            self.projectIDs = projection.groups.map(\.project.id)
            self.workspaceIDs = projection.groups.flatMap { $0.workspaces.map(\.id) }
            self.tabIDs = projection.tabs.map(\.id)
            self.sessionIDs = projection.sessions.map(\.id)
            self.inspectorID = projection.inspector?.id
        }
    }

    public let host: BurrowDomain.Host
    public let groups: [BurrowDesktopProjectGroup]
    public let sessions: [BurrowDesktopSession]
    public let tabs: [ClientTab]
    public let sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID]
    public let inspector: BurrowDesktopInspectorContent?
    public let connectionState: BurrowDesktopConnectionState

    public var isConnected: Bool {
        connectionState.isConnected
    }

    public var reconciliationKey: ReconciliationKey {
        ReconciliationKey(projection: self)
    }

    public init(
        host: BurrowDomain.Host,
        groups: [BurrowDesktopProjectGroup],
        sessions: [BurrowDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        inspector: BurrowDesktopInspectorContent? = nil,
        connectionState: BurrowDesktopConnectionState = .attached
    ) {
        self.host = host
        self.groups = groups
        self.sessions = sessions
        self.tabs = tabs
        self.sessionWorkspaceIDs = sessionWorkspaceIDs
        self.inspector = inspector
        self.connectionState = connectionState
    }

    /// Convenience initializer for callers that already have domain arrays.
    /// Grouping happens once at projection construction, not while rendering rows.
    public init(
        host: BurrowDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        sessions: [BurrowDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        inspector: BurrowDesktopInspectorContent? = nil,
        connectionState: BurrowDesktopConnectionState = .attached
    ) {
        let groups = projects.map { project in
            BurrowDesktopProjectGroup(
                project: project,
                workspaces: workspaces.filter { $0.projectID == project.id }
            )
        }
        self.init(
            host: host,
            groups: groups,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            inspector: inspector,
            connectionState: connectionState
        )
    }

    public static func empty(host: BurrowDomain.Host) -> Self {
        Self(host: host, groups: [])
    }

    public func projectGroup(id: ProjectID) -> BurrowDesktopProjectGroup? {
        groups.first { $0.project.id == id }
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        for group in groups {
            if let workspace = group.workspaces.first(where: { $0.id == id }) {
                return workspace
            }
        }
        return nil
    }

    public func firstWorkspace(in projectID: ProjectID) -> Workspace? {
        projectGroup(id: projectID)?.workspaces.first
    }

    public func workspace(for sessionID: TerminalSessionID) -> Workspace? {
        guard let workspaceID = sessionWorkspaceIDs[sessionID] else { return nil }
        return workspace(id: workspaceID)
    }

    /// Tabs are workspace-local UI. The Host may keep tabs from several
    /// workspaces open, but a workspace chrome must never render siblings
    /// owned by another project/branch.
    public func tabs(in workspaceID: WorkspaceID) -> [ClientTab] {
        tabs.filter { tab in
            guard let sessionID = tab.sessionID else { return false }
            return sessionWorkspaceIDs[sessionID] == workspaceID
        }
    }
}

/// A deterministic preview/test-only fixture. Production composition should
/// construct `BurrowDesktopProjection` from live Host and Client state instead.
///
/// This compatibility wrapper remains temporarily so the old BurrowNext preview
/// entry can compile while the executable is moved to the real composition
/// root. It intentionally exposes only the wrapped value and lookup helpers.
public struct BurrowDesktopFixture: Sendable {
    public let projection: BurrowDesktopProjection

    public var host: BurrowDomain.Host { projection.host }
    public var groups: [BurrowDesktopProjectGroup] { projection.groups }
    public var sessions: [BurrowDesktopSession] { projection.sessions }
    public var tabs: [ClientTab] { projection.tabs }
    public var inspector: BurrowDesktopInspectorContent? { projection.inspector }
    public var isConnected: Bool { projection.isConnected }

    public init(projection: BurrowDesktopProjection) {
        self.projection = projection
    }

    public init(
        host: BurrowDomain.Host,
        groups: [BurrowDesktopProjectGroup],
        tabs: [ClientTab] = [],
        inspector: BurrowDesktopInspectorContent? = nil,
        isConnected: Bool = true
    ) {
        self.init(
            projection: BurrowDesktopProjection(
                host: host,
                groups: groups,
                tabs: tabs,
                inspector: inspector,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public init(
        host: BurrowDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        tabs: [ClientTab] = [],
        inspector: BurrowDesktopInspectorContent? = nil,
        isConnected: Bool = true
    ) {
        self.init(
            projection: BurrowDesktopProjection(
                host: host,
                projects: projects,
                workspaces: workspaces,
                tabs: tabs,
                inspector: inspector,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public func projectGroup(id: ProjectID) -> BurrowDesktopProjectGroup? {
        projection.projectGroup(id: id)
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        projection.workspace(id: id)
    }

    public func firstWorkspace(in projectID: ProjectID) -> Workspace? {
        projection.firstWorkspace(in: projectID)
    }

    /// Stable IDs keep preview diffing and UI tests deterministic.
    public static var preview: Self {
        let hostID = HostID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000001"))
        let projectID = ProjectID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000002"))
        let secondProjectID = ProjectID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000003"))
        let firstWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000004"))
        let secondWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000005"))
        let thirdWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000006"))
        let firstSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000007"))
        let secondSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000008"))

        let host = BurrowDomain.Host(id: hostID, name: "Local Mac")
        let project = Project(
            id: projectID,
            hostID: hostID,
            name: "Burrow",
            rootPath: "/Users/demo/Code/burrow"
        )
        let secondProject = Project(
            id: secondProjectID,
            hostID: hostID,
            name: "Superset",
            rootPath: "/Users/demo/Code/superset"
        )
        let workspaces = [
            Workspace(
                id: firstWorkspaceID,
                projectID: projectID,
                name: "main",
                path: "/Users/demo/Code/burrow",
                branch: "main"
            ),
            Workspace(
                id: secondWorkspaceID,
                projectID: projectID,
                name: "feature/mobile-shell",
                path: "/Users/demo/Code/burrow-feature",
                branch: "feature/mobile-shell"
            ),
            Workspace(
                id: thirdWorkspaceID,
                projectID: secondProjectID,
                name: "review",
                path: "/Users/demo/Code/superset-review",
                branch: "review/burrow"
            ),
        ]
        let tabs = [
            ClientTab(
                id: "tab-main",
                title: "main",
                sessionID: firstSessionID,
                kind: .shell
            ),
            ClientTab(
                id: "tab-review",
                title: "review",
                sessionID: secondSessionID,
                kind: .claude
            ),
        ]
        let sessions = [
            BurrowDesktopSession(
                id: firstSessionID,
                workspaceID: firstWorkspaceID,
                tabID: "tab-main",
                title: "main",
                kind: .shell
            ),
            BurrowDesktopSession(
                id: secondSessionID,
                workspaceID: thirdWorkspaceID,
                tabID: "tab-review",
                title: "review",
                kind: .claude
            ),
        ]

        return Self(
            projection: BurrowDesktopProjection(
                host: host,
                projects: [project, secondProject],
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                sessionWorkspaceIDs: [
                    firstSessionID: firstWorkspaceID,
                    secondSessionID: thirdWorkspaceID,
                ],
                inspector: BurrowDesktopInspectorContent(
                    title: "Workspace Inspector",
                    detail: "Select a workspace to view local layout details."
                )
            )
        )
    }

    private static func uuid(_ string: String) -> UUID {
        // Fixture literals are compile-time-known and deliberately fail fast
        // if somebody edits one into a non-UUID value.
        UUID(uuidString: string)!
    }
}

public enum BurrowDesktopSidebarSelection: Hashable, Sendable {
    case project(ProjectID)
    case workspace(WorkspaceID)
}

/// User intent emitted by the desktop shell. The composition root translates
/// these intents into Host, ClientLayoutStore, or renderer operations.
public enum BurrowDesktopAction: Hashable, Sendable {
    case addProject
    case importSuperset
    case selectProject(ProjectID)
    case selectWorkspace(WorkspaceID)
    case openSession(TerminalSessionID)
    case selectTab(String)
    case requestNewSession(WorkspaceID)
    case launchSession(WorkspaceID, TerminalSessionLaunchRequest)
    case closeTab(String)
    case closeOtherTabs(String)
    case closeAllTabs
    case toggleInspector
    case toggleSidebar
}

/// UI-only event surface. The package itself performs no side effects.
///
/// Keeping one typed event channel avoids hiding important composition work in
/// row views. It also makes the full action contract easy to test without
/// constructing a Host or starting a process.
public struct BurrowDesktopActions {
    public let send: @MainActor (BurrowDesktopAction) -> Void

    public init(
        send: @escaping @MainActor (BurrowDesktopAction) -> Void = { _ in }
    ) {
        self.send = send
    }

    @MainActor
    public func callAsFunction(_ action: BurrowDesktopAction) {
        send(action)
    }
}

/// Context passed to the injected terminal surface slot. A surface renders
/// bytes and forwards input through its own injected adapter; this value never
/// contains a process, transport, or persistence dependency.
public struct BurrowDesktopTerminalContext: Hashable, Sendable {
    public let workspace: Workspace
    public let tab: ClientTab

    public init(workspace: Workspace, tab: ClientTab) {
        self.workspace = workspace
        self.tab = tab
    }
}
