import Foundation
import WarrenClientCore
import WarrenDomain

/// A project and its device-local workspace rows for the desktop shell.
///
/// This is a value projection. It carries no Host process, persistence, or
/// transport behavior, and can therefore be rebuilt from Host/Client state
/// whenever the composition root receives an update.
public struct WarrenDesktopProjectGroup: Identifiable, Hashable, Sendable {
    public let project: Project
    public let workspaces: [Workspace]

    public var id: Project.ID { project.id }

    public init(project: Project, workspaces: [Workspace] = []) {
        self.project = project
        self.workspaces = workspaces
    }
}

/// Optional trailing inspector content. The shell owns its slot geometry.
public struct WarrenDesktopInspectorContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    /// Text copied by the Inspector action. Keep the title with the detail so
    /// a pasted diagnostic remains understandable outside the app.
    public var clipboardText: String {
        "\(title)\n\n\(detail)"
    }

    public init(id: String = "inspector", title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// Desktop read model for a Host-owned Warren Terminal Session. `tabID` is
/// present only when the current Window Layout contains an entry for it.
public struct WarrenDesktopSession: Identifiable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID
    public let tabID: String?
    public let title: String
    public let customTitle: String?
    public let pinned: Bool
    public let kind: TerminalSessionKind
    public let state: WarrenDesktopSessionState
    public let activity: AgentActivityState?
    public let runtimeProcess: String
    public let workingDirectory: String

    public init(
        id: TerminalSessionID,
        workspaceID: WorkspaceID,
        tabID: String? = nil,
        title: String,
        customTitle: String? = nil,
        pinned: Bool = false,
        kind: TerminalSessionKind = .shell,
        state: WarrenDesktopSessionState = .attached,
        activity: AgentActivityState? = nil,
        runtimeProcess: String = "",
        workingDirectory: String = ""
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.title = title
        self.customTitle = customTitle
        self.pinned = pinned
        self.kind = kind
        self.state = state
        self.activity = activity
        self.runtimeProcess = runtimeProcess
        self.workingDirectory = workingDirectory
    }

}

public enum WarrenDesktopSessionState: String, Hashable, Sendable {
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
public enum WarrenDesktopConnectionState: Hashable, Sendable {
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
public struct WarrenDesktopProjection: Sendable, Hashable {
    /// The small identity-only value used by SwiftUI when it only needs to
    /// validate selection.  Comparing the full projection here would walk
    /// every project, workspace, tab, and session mapping on every snapshot.
    public struct ReconciliationKey: Sendable, Hashable {
        public let projectIDs: [ProjectID]
        public let workspaceIDs: [WorkspaceID]
        public let tabIDs: [String]
        public let sessionIDs: [TerminalSessionID]
        public let inspectorID: String?

        fileprivate init(
            groups: [WarrenDesktopProjectGroup],
            sessions: [WarrenDesktopSession],
            tabs: [ClientTab],
            inspectorID: String?
        ) {
            self.projectIDs = groups.map(\.project.id)
            self.workspaceIDs = groups.flatMap { $0.workspaces.map(\.id) }
            self.tabIDs = tabs.map(\.id)
            self.sessionIDs = sessions.map(\.id)
            self.inspectorID = inspectorID
        }
    }

    public let host: WarrenDomain.Host
    public let groups: [WarrenDesktopProjectGroup]
    public let sessions: [WarrenDesktopSession]
    public let tabs: [ClientTab]
    public let sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID]
    public let tabWorkspaceIDs: [String: WorkspaceID]
    public let reconciliationKey: ReconciliationKey
    /// Lookup tables are built once at the projection boundary. SwiftUI can
    /// ask for the same relationship many times while reconciling a frame;
    /// those reads must not rescan the whole sidebar/session tree.
    private let workspacesByID: [WorkspaceID: Workspace]
    private let sessionsByID: [TerminalSessionID: WarrenDesktopSession]
    private let tabsByWorkspaceID: [WorkspaceID: [ClientTab]]
    private let firstWorkspaceID: WorkspaceID?
    private let firstWorkspaceIDByProjectID: [ProjectID: WorkspaceID]
    private let activityByWorkspaceID: [WorkspaceID: AgentActivityState]
    public let inspector: WarrenDesktopInspectorContent?
    public let connectionState: WarrenDesktopConnectionState

    public var isConnected: Bool {
        connectionState.isConnected
    }

    /// Activity is already reduced by workspace during projection creation.
    /// Exposing the value map keeps the sidebar from rebuilding one on every
    /// body evaluation.
    public var workspaceActivities: [WorkspaceID: AgentActivityState] {
        activityByWorkspaceID
    }

    public var firstWorkspace: Workspace? {
        firstWorkspaceID.flatMap { workspacesByID[$0] }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host
            && lhs.groups == rhs.groups
            && lhs.sessions == rhs.sessions
            && lhs.tabs == rhs.tabs
            && lhs.sessionWorkspaceIDs == rhs.sessionWorkspaceIDs
            && lhs.tabWorkspaceIDs == rhs.tabWorkspaceIDs
            && lhs.inspector == rhs.inspector
            && lhs.connectionState == rhs.connectionState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(groups)
        hasher.combine(sessions)
        hasher.combine(tabs)
        hasher.combine(sessionWorkspaceIDs)
        hasher.combine(tabWorkspaceIDs)
        hasher.combine(inspector)
        hasher.combine(connectionState)
    }

    public init(
        host: WarrenDomain.Host,
        groups: [WarrenDesktopProjectGroup],
        sessions: [WarrenDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        tabWorkspaceIDs: [String: WorkspaceID] = [:],
        inspector: WarrenDesktopInspectorContent? = nil,
        connectionState: WarrenDesktopConnectionState = .attached
    ) {
        let pinnedBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.pinned) }
        )
        self.host = host
        self.groups = Self.pinnedFirst(groups) { $0.project.pinned }.map { group in
            WarrenDesktopProjectGroup(
                project: group.project,
                workspaces: Self.pinnedFirst(group.workspaces) { $0.pinned }
            )
        }
        self.sessions = Self.pinnedFirst(sessions) { $0.pinned }
        self.tabs = Self.pinnedFirst(tabs) { tab in
            tab.sessionID.flatMap { pinnedBySessionID[$0] } ?? false
        }
        self.sessionWorkspaceIDs = sessionWorkspaceIDs
        let resolvedTabWorkspaceIDs = tabWorkspaceIDs.merging(
            Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
                tab.sessionID.flatMap { sessionWorkspaceIDs[$0] }.map { (tab.id, $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        self.tabWorkspaceIDs = resolvedTabWorkspaceIDs

        var workspacesByID: [WorkspaceID: Workspace] = [:]
        var firstWorkspaceID: WorkspaceID?
        var firstWorkspaceIDByProjectID: [ProjectID: WorkspaceID] = [:]
        for group in groups {
            for workspace in group.workspaces {
                workspacesByID[workspace.id] = workspace
                if firstWorkspaceID == nil {
                    firstWorkspaceID = workspace.id
                }
                if firstWorkspaceIDByProjectID[group.project.id] == nil {
                    firstWorkspaceIDByProjectID[group.project.id] = workspace.id
                }
            }
        }
        self.workspacesByID = workspacesByID
        self.firstWorkspaceID = firstWorkspaceID
        self.firstWorkspaceIDByProjectID = firstWorkspaceIDByProjectID

        self.sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        var tabsByWorkspaceID: [WorkspaceID: [ClientTab]] = [:]
        for tab in tabs {
            guard let workspaceID = resolvedTabWorkspaceIDs[tab.id] else { continue }
            tabsByWorkspaceID[workspaceID, default: []].append(tab)
        }
        self.tabsByWorkspaceID = tabsByWorkspaceID

        var activityByWorkspaceID: [WorkspaceID: AgentActivityState] = [:]
        for session in sessions {
            guard let activity = session.activity else { continue }
            guard let current = activityByWorkspaceID[session.workspaceID],
                  current.workspacePriority >= activity.workspacePriority else {
                activityByWorkspaceID[session.workspaceID] = activity
                continue
            }
        }
        self.activityByWorkspaceID = activityByWorkspaceID
        self.inspector = inspector
        self.connectionState = connectionState
        self.reconciliationKey = ReconciliationKey(
            groups: groups,
            sessions: sessions,
            tabs: tabs,
            inspectorID: inspector?.id
        )
    }

    /// Convenience initializer for callers that already have domain arrays.
    /// Grouping happens once at projection construction, not while rendering rows.
    public init(
        host: WarrenDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        sessions: [WarrenDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        tabWorkspaceIDs: [String: WorkspaceID] = [:],
        inspector: WarrenDesktopInspectorContent? = nil,
        connectionState: WarrenDesktopConnectionState = .attached
    ) {
        var workspacesByProjectID: [ProjectID: [Workspace]] = [:]
        for workspace in Self.pinnedFirst(workspaces, isPinned: \.pinned) {
            workspacesByProjectID[workspace.projectID, default: []].append(workspace)
        }
        let groups = Self.pinnedFirst(projects, isPinned: \.pinned).map { project in
            WarrenDesktopProjectGroup(
                project: project,
                workspaces: workspacesByProjectID[project.id] ?? []
            )
        }
        self.init(
            host: host,
            groups: groups,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            inspector: inspector,
            connectionState: connectionState
        )
    }

    private static func pinnedFirst<Value>(
        _ values: [Value],
        isPinned: (Value) -> Bool
    ) -> [Value] {
        values.filter { isPinned($0) } + values.filter { !isPinned($0) }
    }

    public static func empty(host: WarrenDomain.Host) -> Self {
        Self(host: host, groups: [])
    }

    public func projectGroup(id: ProjectID) -> WarrenDesktopProjectGroup? {
        groups.first { $0.project.id == id }
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        workspacesByID[id]
    }

    public func firstWorkspace(in projectID: ProjectID) -> Workspace? {
        firstWorkspaceIDByProjectID[projectID].flatMap { workspacesByID[$0] }
    }

    public func workspace(for sessionID: TerminalSessionID) -> Workspace? {
        guard let workspaceID = sessionWorkspaceIDs[sessionID] else { return nil }
        return workspacesByID[workspaceID]
    }

    public func session(id: TerminalSessionID) -> WarrenDesktopSession? {
        sessionsByID[id]
    }

    public func workspaceID(forTabID tabID: String) -> WorkspaceID? {
        tabWorkspaceIDs[tabID]
    }

    /// Tabs are workspace-local UI. The Host may keep tabs from several
    /// workspaces open, but a workspace chrome must never render siblings
    /// owned by another project/branch.
    public func tabs(in workspaceID: WorkspaceID) -> [ClientTab] {
        tabsByWorkspaceID[workspaceID] ?? []
    }

    /// Returns the most actionable state for a Workspace. A failure or input
    /// request must remain visible even when another Session is still working.
    public func activity(in workspaceID: WorkspaceID) -> AgentActivityState? {
        activityByWorkspaceID[workspaceID]
    }
}

private extension AgentActivityState {
    var workspacePriority: Int {
        switch self {
        case .failed: 5
        case .waitingForInput: 4
        case .working: 3
        case .ready: 1
        }
    }
}

/// A deterministic preview/test-only fixture. Production composition should
/// construct `WarrenDesktopProjection` from live Host and Client state instead.
///
/// This compatibility wrapper remains temporarily so the old WarrenNext preview
/// entry can compile while the executable is moved to the real composition
/// root. It intentionally exposes only the wrapped value and lookup helpers.
public struct WarrenDesktopFixture: Sendable {
    public let projection: WarrenDesktopProjection

    public var host: WarrenDomain.Host { projection.host }
    public var groups: [WarrenDesktopProjectGroup] { projection.groups }
    public var sessions: [WarrenDesktopSession] { projection.sessions }
    public var tabs: [ClientTab] { projection.tabs }
    public var inspector: WarrenDesktopInspectorContent? { projection.inspector }
    public var isConnected: Bool { projection.isConnected }

    public init(projection: WarrenDesktopProjection) {
        self.projection = projection
    }

    public init(
        host: WarrenDomain.Host,
        groups: [WarrenDesktopProjectGroup],
        tabs: [ClientTab] = [],
        inspector: WarrenDesktopInspectorContent? = nil,
        isConnected: Bool = true
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                groups: groups,
                tabs: tabs,
                inspector: inspector,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public init(
        host: WarrenDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        tabs: [ClientTab] = [],
        inspector: WarrenDesktopInspectorContent? = nil,
        isConnected: Bool = true
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                projects: projects,
                workspaces: workspaces,
                tabs: tabs,
                inspector: inspector,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public func projectGroup(id: ProjectID) -> WarrenDesktopProjectGroup? {
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

        let host = WarrenDomain.Host(id: hostID, name: "Local Mac")
        let project = Project(
            id: projectID,
            hostID: hostID,
            name: "Warren",
            rootPath: "/Users/demo/Code/warren"
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
                path: "/Users/demo/Code/warren",
                branch: "main"
            ),
            Workspace(
                id: secondWorkspaceID,
                projectID: projectID,
                name: "feature/mobile-shell",
                path: "/Users/demo/Code/warren-feature",
                branch: "feature/mobile-shell"
            ),
            Workspace(
                id: thirdWorkspaceID,
                projectID: secondProjectID,
                name: "review",
                path: "/Users/demo/Code/superset-review",
                branch: "review/warren"
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
            WarrenDesktopSession(
                id: firstSessionID,
                workspaceID: firstWorkspaceID,
                tabID: "tab-main",
                title: "main",
                kind: .shell
            ),
            WarrenDesktopSession(
                id: secondSessionID,
                workspaceID: thirdWorkspaceID,
                tabID: "tab-review",
                title: "review",
                kind: .claude
            ),
        ]

        return Self(
            projection: WarrenDesktopProjection(
                host: host,
                projects: [project, secondProject],
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                sessionWorkspaceIDs: [
                    firstSessionID: firstWorkspaceID,
                    secondSessionID: thirdWorkspaceID,
                ],
                inspector: WarrenDesktopInspectorContent(
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

public enum WarrenDesktopSidebarSelection: Hashable, Sendable {
    case project(ProjectID)
    case workspace(WorkspaceID)
}

/// User intent emitted by the desktop shell. The composition root translates
/// these intents into Host, ClientLayoutStore, or renderer operations.
public enum WarrenDesktopAction: Hashable, Sendable {
    case addProject
    case importSuperset
    case requestNewWorkspace(ProjectID)
    case renameProject(ProjectID, String)
    case renameWorkspace(WorkspaceID, String)
    case deleteProject(ProjectID)
    case deleteWorkspace(WorkspaceID, removeLocalWorktree: Bool)
    case renameSession(TerminalSessionID, String)
    case setProjectPinned(ProjectID, Bool)
    case setWorkspacePinned(WorkspaceID, Bool)
    case setSessionPinned(TerminalSessionID, Bool)
    case selectProject(ProjectID)
    case selectWorkspace(WorkspaceID)
    case moveProject(ProjectID, before: ProjectID?)
    case moveWorkspace(WorkspaceID, before: WorkspaceID?)
    case openSession(TerminalSessionID)
    case deleteSession(TerminalSessionID)
    case selectTab(String)
    case moveTab(String, before: String?)
    case requestNewSession(WorkspaceID)
    case launchSession(WorkspaceID, TerminalSessionLaunchRequest)
    case closeTab(String)
    case closeOtherTabs(String)
    case closeAllTabs
    case restoreNavigation(WarrenDesktopNavigationState)
    case toggleInspector
    case toggleSidebar
}

/// UI-only event surface. The package itself performs no side effects.
///
/// Keeping one typed event channel avoids hiding important composition work in
/// row views. It also makes the full action contract easy to test without
/// constructing a Host or starting a process.
public struct WarrenDesktopActions {
    public let send: @MainActor (WarrenDesktopAction) -> Void

    public init(
        send: @escaping @MainActor (WarrenDesktopAction) -> Void = { _ in }
    ) {
        self.send = send
    }

    @MainActor
    public func callAsFunction(_ action: WarrenDesktopAction) {
        send(action)
    }
}

/// Context passed to the injected terminal surface slot. A surface renders
/// bytes and forwards input through its own injected adapter; this value never
/// contains a process, transport, or persistence dependency.
public struct WarrenDesktopTerminalContext: Hashable, Sendable {
    public let workspace: Workspace
    public let tab: ClientTab
    public let font: TerminalFontPreference

    public init(
        workspace: Workspace,
        tab: ClientTab,
        font: TerminalFontPreference = .init()
    ) {
        self.workspace = workspace
        self.tab = tab
        self.font = font
    }
}
