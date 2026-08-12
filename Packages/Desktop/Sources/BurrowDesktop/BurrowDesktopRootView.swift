import SwiftUI
import BurrowClientCore
import BurrowDesignSystem
import BurrowDomain

/// Production macOS shell.
///
/// The shell consumes an immutable Host/Client value projection and emits
/// typed intents. It does not start a process, persist layout, or talk to a
/// transport. The terminal is an explicit generic surface slot, so the
/// composition root can inject a real remote SwiftTerm view without type
/// erasure or hidden process ownership.
public struct BurrowDesktopRoot<TerminalSurface: View>: View {
    public let projection: BurrowDesktopProjection
    public let navigation: BurrowDesktopNavigationState
    public let chromeMode: BurrowDesktopChromeMode

    private let actions: BurrowDesktopActions
    private let terminalSurface: @MainActor (BurrowDesktopTerminalContext) -> TerminalSurface
    @State private var sidebarState: BurrowDesktopSidebarState
    @State private var inspectorVisible: Bool
    @State private var inspectorWasAvailable: Bool
    @State private var commandPalettePresented = false

    public init(
        projection: BurrowDesktopProjection,
        navigation: BurrowDesktopNavigationState? = nil,
        chromeMode: BurrowDesktopChromeMode = .workspace,
        actions: BurrowDesktopActions = BurrowDesktopActions(),
        @ViewBuilder terminalSurface: @escaping @MainActor (BurrowDesktopTerminalContext) -> TerminalSurface
    ) {
        self.projection = projection
        self.navigation = navigation ?? BurrowDesktopNavigationReducer.initial(for: projection)
        self.chromeMode = chromeMode
        self.actions = actions
        self.terminalSurface = terminalSurface
        _sidebarState = State(initialValue: Self.restoredSidebarState())
        _inspectorVisible = State(initialValue: projection.inspector != nil)
        _inspectorWasAvailable = State(initialValue: projection.inspector != nil)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                BurrowDesktopSidebar(
                    projection: projection,
                    sidebarState: $sidebarState,
                    selection: navigation.selection,
                    selectedTabID: navigation.selectedTabID,
                    chromeMode: chromeMode,
                    onAction: dispatch,
                    onCommandPalette: { commandPalettePresented = true }
                )
                .frame(width: sidebarState.renderedWidth)

                VStack(spacing: 0) {
                    if chromeMode.showsIndependentTopBar {
                        BurrowDesktopTopBar(
                            hostName: projection.host.name,
                            isConnected: projection.isConnected,
                            isSidebarCollapsed: sidebarState.isCollapsed,
                            hasInspector: projection.inspector != nil,
                            isInspectorVisible: inspectorVisible,
                            onToggleSidebar: toggleSidebar,
                            onToggleInspector: {}
                        )
                    }
                    BurrowDesktopTabBar(
                        tabs: workspaceTabs,
                        selectedTabID: navigation.selectedTabID,
                        chromeMode: chromeMode,
                        isSidebarCollapsed: sidebarState.isCollapsed,
                        isConnected: projection.isConnected,
                        hasInspector: projection.inspector != nil,
                        isInspectorVisible: inspectorVisible,
                        onToggleSidebar: toggleSidebar,
                        onToggleInspector: toggleInspector,
                        onCommandPalette: { commandPalettePresented = true },
                        onSelectTab: { dispatch(.selectTab($0)) },
                        canAddTab: selectedWorkspace != nil,
                        onAddTab: {
                            guard let workspaceID = selectedWorkspace?.id else { return }
                            dispatch(.requestNewSession(workspaceID))
                        },
                        onCloseTab: { dispatch(.closeTab($0)) },
                        onCloseOtherTabs: { dispatch(.closeOtherTabs($0)) },
                        onCloseAllTabs: { dispatch(.closeAllTabs) }
                    )
                    BurrowDesktopPresetBar(
                        workspace: selectedWorkspace,
                        onChooseCommand: {
                            guard let workspaceID = selectedWorkspace?.id else { return }
                            dispatch(.requestNewSession(workspaceID))
                        },
                        onLaunch: { request in
                            guard let workspaceID = selectedWorkspace?.id else { return }
                            dispatch(.launchSession(workspaceID, request))
                        }
                    )
                    HStack(spacing: 0) {
                        BurrowDesktopWorkspaceContent(
                            workspace: contentWorkspace,
                            tab: selectedTab,
                            hasProjects: !projection.groups.isEmpty,
                            // Superset keeps the 28pt pane toolbar in workspace
                            // mode too. It is pane chrome, not a duplicate top bar.
                            showsPaneHeader: true,
                            branchSessions: contentWorkspace.map { workspace in
                                projection.sessions.filter {
                                    $0.workspaceID == workspace.id
                                }
                            } ?? [],
                            onAddProject: { dispatch(.addProject) },
                            onNewSession: {
                                guard let workspace = selectedWorkspace else { return }
                                dispatch(.requestNewSession(workspace.id))
                            },
                            onOpenSession: { dispatch(.openSession($0)) },
                            terminalSurface: terminalSurface
                        )
                        if inspectorVisible, let inspector = projection.inspector {
                            BurrowDesktopInspectorSlot(content: inspector)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: inspectorVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .frame(
            minWidth: BurrowLayoutMetrics.sidebarExpandedWidth
                + BurrowLayoutMetrics.paneMinimumWidth,
            minHeight: (chromeMode.showsIndependentTopBar ? BurrowLayoutMetrics.topBarHeight : 0)
                + BurrowLayoutMetrics.tabBarHeight
                + BurrowLayoutMetrics.presetBarHeight
                + BurrowLayoutMetrics.paneHeaderHeight
                + BurrowLayoutMetrics.paneMinimumHeight
        )
        .denSurface()
        .onChange(of: projection.reconciliationKey) { _, _ in
            reconcileInspector(with: projection)
        }
        .onChange(of: sidebarState) { _, newState in
            Self.persist(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: BurrowDesktopCommand.commandPalette)) { _ in
            commandPalettePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: BurrowDesktopCommand.newSession)) { _ in
            guard let workspace = selectedWorkspace else { return }
            dispatch(.requestNewSession(workspace.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: BurrowDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: BurrowDesktopCommand.toggleInspector)) { _ in
            toggleInspector()
        }
        .sheet(isPresented: $commandPalettePresented) {
            BurrowDesktopCommandPalette(
                projection: projection,
                onAction: { action in
                    dispatch(action)
                }
            )
            .padding(40)
        }
    }

    private var selectedWorkspace: Workspace? {
        if let sessionID = selectedTab?.sessionID,
           let workspace = projection.workspace(for: sessionID) {
            return workspace
        }
        guard let selection = navigation.selection else {
            return firstWorkspace
        }
        switch selection {
        case .project(let projectID):
            return projection.firstWorkspace(in: projectID)
        case .workspace(let workspaceID):
            return projection.workspace(id: workspaceID)
        }
    }

    private var selectedTab: ClientTab? {
        guard let selectedTabID = navigation.selectedTabID else { return nil }
        return workspaceTabs.first { $0.id == selectedTabID }
    }

    private var workspaceTabs: [ClientTab] {
        guard let workspaceID = navigationWorkspace?.id else { return [] }
        return projection.tabs(in: workspaceID)
    }

    /// Navigation owns the workspace. A selected tab may help resolve an old
    /// projection during reconciliation, but it must never pull content back
    /// to a different workspace after the user has switched project/branch.
    private var navigationWorkspace: Workspace? {
        guard let selection = navigation.selection else { return firstWorkspace }
        switch selection {
        case .project(let projectID):
            return projection.firstWorkspace(in: projectID)
        case .workspace(let workspaceID):
            return projection.workspace(id: workspaceID)
        }
    }

    private var contentWorkspace: Workspace? {
        if let sessionID = selectedTab?.sessionID,
           let workspace = projection.workspace(for: sessionID) {
            return workspace
        }
        return selectedWorkspace
    }

    private var firstWorkspace: Workspace? {
        projection.groups.lazy.compactMap(\BurrowDesktopProjectGroup.workspaces).first?.first
    }

    private func dispatch(_ action: BurrowDesktopAction) {
        actions(action)
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) {
            sidebarState.toggleCollapsed()
        }
        actions(.toggleSidebar)
    }

    private func toggleInspector() {
        inspectorVisible.toggle()
        actions(.toggleInspector)
    }

    private func reconcileInspector(with newProjection: BurrowDesktopProjection) {
        if newProjection.inspector == nil {
            inspectorVisible = false
        } else if !inspectorWasAvailable {
            inspectorVisible = true
        }
        inspectorWasAvailable = newProjection.inspector != nil
    }

    private static func restoredSidebarState() -> BurrowDesktopSidebarState {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: BurrowDesktopSidebarKeys.width) as? Double
        // The rail always starts expanded. A collapsed state was persisted by
        // earlier builds during testing; ignore it so first launch is usable.
        defaults.removeObject(forKey: BurrowDesktopSidebarKeys.collapsed)
        return BurrowDesktopSidebarState(
            width: storedWidth ?? BurrowLayoutMetrics.sidebarExpandedWidth,
            isCollapsed: false
        )
    }

    private static func persist(_ state: BurrowDesktopSidebarState) {
        UserDefaults.standard.set(state.width, forKey: BurrowDesktopSidebarKeys.width)
    }
}

private enum BurrowDesktopSidebarKeys {
    static let width = "burrow.desktop.sidebarWidth"
    static let collapsed = "burrow.desktop.sidebarCollapsed"
}

/// Compatibility preview shell for the old BurrowNext entry point.
///
/// This is deliberately not the production composition API. It exists only
/// until BurrowNext injects its embedded Host, in-process transport, and real
/// SwiftTerm surface through `BurrowDesktopRoot`.
@available(*, deprecated, message: "Use BurrowDesktopRoot(projection:actions:terminalSurface:) for production composition.")
public struct BurrowDesktopRootView: View {
    public let fixture: BurrowDesktopFixture
    public let chromeMode: BurrowDesktopChromeMode
    private let actions: BurrowDesktopActions

    public init(
        fixture: BurrowDesktopFixture = .preview,
        chromeMode: BurrowDesktopChromeMode = .workspace,
        actions: BurrowDesktopActions = BurrowDesktopActions()
    ) {
        self.fixture = fixture
        self.chromeMode = chromeMode
        self.actions = actions
    }

    public var body: some View {
        BurrowDesktopRoot(
            projection: fixture.projection,
            chromeMode: chromeMode,
            actions: actions
        ) { context in
            BurrowDesktopTerminalPlaceholder(workspace: context.workspace)
        }
    }
}
