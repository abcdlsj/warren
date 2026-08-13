import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// Production macOS shell.
///
/// The shell consumes an immutable Host/Client value projection and emits
/// typed intents. It does not start a process, persist layout, or talk to a
/// transport. The terminal is an explicit generic surface slot, so the
/// composition root can inject a real remote SwiftTerm view without type
/// erasure or hidden process ownership.
public struct WarrenDesktopRoot<TerminalSurface: View>: View {
    public let projection: WarrenDesktopProjection
    public let navigation: WarrenDesktopNavigationState
    public let chromeMode: WarrenDesktopChromeMode
    public let webRelayStatus: WarrenDesktopWebRelayStatus

    private let actions: WarrenDesktopActions
    private let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    private let onWebRelayStart: () -> Void
    private let onWebRelayStop: () -> Void
    private let onWebRelayOpenURL: (URL) -> Void
    private let onWebRelayCopyURL: (URL) -> Void
    @State private var sidebarState: WarrenDesktopSidebarState
    @State private var inspectorVisible: Bool
    @State private var inspectorWasAvailable: Bool
    @State private var commandPalettePresented = false
    @State private var settingsPresented = false
    @State private var webRelayPresented = false
    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var terminalTitleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
    @Environment(\.warrenSemanticRecorder) private var semanticRecorder

    public init(
        projection: WarrenDesktopProjection,
        navigation: WarrenDesktopNavigationState? = nil,
        chromeMode: WarrenDesktopChromeMode = .workspace,
        actions: WarrenDesktopActions = WarrenDesktopActions(),
        webRelayStatus: WarrenDesktopWebRelayStatus = .init(),
        onWebRelayStart: @escaping () -> Void = {},
        onWebRelayStop: @escaping () -> Void = {},
        onWebRelayOpenURL: @escaping (URL) -> Void = { _ in },
        onWebRelayCopyURL: @escaping (URL) -> Void = { _ in },
        @ViewBuilder terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.projection = projection
        self.navigation = navigation ?? WarrenDesktopNavigationReducer.initial(for: projection)
        self.chromeMode = chromeMode
        self.webRelayStatus = webRelayStatus
        self.actions = actions
        self.terminalSurface = terminalSurface
        self.onWebRelayStart = onWebRelayStart
        self.onWebRelayStop = onWebRelayStop
        self.onWebRelayOpenURL = onWebRelayOpenURL
        self.onWebRelayCopyURL = onWebRelayCopyURL
        _sidebarState = State(initialValue: Self.restoredSidebarState())
        _inspectorVisible = State(initialValue: projection.inspector != nil)
        _inspectorWasAvailable = State(initialValue: projection.inspector != nil)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if settingsPresented {
                WarrenDesktopSettingsView(onBack: { settingsPresented = false })
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                WarrenDesktopSidebar(
                    projection: projection,
                    sidebarState: $sidebarState,
                    selection: navigation.selection,
                    chromeMode: chromeMode,
                    onAction: dispatch,
                    onCommandPalette: { commandPalettePresented = true }
                )
                .frame(width: sidebarState.renderedWidth)

                VStack(spacing: 0) {
                    if chromeMode.showsIndependentTopBar {
                        WarrenDesktopTopBar(
                            hostName: projection.host.name,
                            isConnected: projection.isConnected,
                            isSidebarCollapsed: sidebarState.isCollapsed,
                            hasInspector: projection.inspector != nil,
                            isInspectorVisible: inspectorVisible,
                            onToggleSidebar: toggleSidebar,
                            onToggleInspector: {}
                        )
                    }
                    WarrenDesktopTabBar(
                        tabs: workspaceTabs,
                        selectedTabID: navigation.selectedTabID,
                        chromeMode: chromeMode,
                        isSidebarCollapsed: sidebarState.isCollapsed,
                        isConnected: projection.isConnected,
                        webRelayStatus: webRelayStatus,
                        hasInspector: projection.inspector != nil,
                        isInspectorVisible: inspectorVisible,
                        onToggleSidebar: toggleSidebar,
                        onToggleInspector: toggleInspector,
                        onCommandPalette: { commandPalettePresented = true },
                        onSettings: {
                            commandPalettePresented = false
                            settingsPresented = true
                        },
                        onWebRelay: { webRelayPresented.toggle() },
                        onSelectTab: { dispatch(.selectTab($0)) },
                        onMoveTab: { tabID, destinationTabID in
                            dispatch(.moveTab(tabID, before: destinationTabID))
                        },
                        canAddTab: selectedWorkspace != nil,
                        onAddTab: {
                            guard let workspaceID = selectedWorkspace?.id else { return }
                            dispatch(.requestNewSession(workspaceID))
                        },
                        onCloseTab: { dispatch(.closeTab($0)) },
                        onCloseOtherTabs: { dispatch(.closeOtherTabs($0)) },
                        onCloseAllTabs: { dispatch(.closeAllTabs) }
                    )
                    WarrenDesktopPresetBar(
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
                        WarrenDesktopWorkspaceContent(
                            workspace: contentWorkspace,
                            tab: selectedTab,
                            hasProjects: !projection.groups.isEmpty,
                            // Superset keeps the 28pt pane toolbar in workspace
                            // mode too. It is pane chrome, not a duplicate top bar.
                            showsPaneHeader: true,
                            session: selectedTab?.sessionID.flatMap { id in
                                projection.sessions.first { $0.id == id }
                            },
                            hostName: projection.host.name,
                            titleTemplate: TerminalDisplayTitleTemplate(rawValue: terminalTitleTemplate),
                            terminalFont: TerminalFontPreference(
                                family: terminalFontFamily,
                                size: terminalFontSize
                            ),
                            onAddProject: { dispatch(.addProject) },
                            onImportSuperset: { dispatch(.importSuperset) },
                            onNewSession: {
                                guard let workspace = selectedWorkspace else { return }
                                dispatch(.requestNewSession(workspace.id))
                            },
                            terminalSurface: terminalSurface
                        )
                        if inspectorVisible, let inspector = projection.inspector {
                            WarrenDesktopInspectorSlot(content: inspector)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: inspectorVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .frame(
            minWidth: WarrenLayoutMetrics.sidebarExpandedWidth
                + WarrenLayoutMetrics.paneMinimumWidth,
            minHeight: (chromeMode.showsIndependentTopBar ? WarrenLayoutMetrics.topBarHeight : 0)
                + WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.presetBarHeight
                + WarrenLayoutMetrics.paneHeaderHeight
                + WarrenLayoutMetrics.paneMinimumHeight
        )
        .denSurface()
        .onChange(of: projection.reconciliationKey) { _, _ in
            reconcileInspector(with: projection)
        }
        .onChange(of: sidebarState) { _, newState in
            Self.persist(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.commandPalette)) { _ in
            commandPalettePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.newSession)) { _ in
            guard let workspace = selectedWorkspace else { return }
            dispatch(.requestNewSession(workspace.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleInspector)) { _ in
            toggleInspector()
        }
        .overlay(alignment: .topLeading) {
            if commandPalettePresented && !settingsPresented {
                WarrenDesktopCommandPalette(
                    projection: projection,
                    onAction: dispatch,
                    onDismiss: { commandPalettePresented = false }
                )
                .padding(.leading, sidebarState.renderedWidth + WarrenSpacing.large)
                .padding(.top, WarrenLayoutMetrics.tabBarHeight + WarrenSpacing.medium)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if webRelayPresented && !settingsPresented {
                WarrenDesktopWebRelayPanel(
                    status: webRelayStatus,
                    onStart: onWebRelayStart,
                    onStop: onWebRelayStop,
                    onOpenURL: onWebRelayOpenURL,
                    onCopyURL: onWebRelayCopyURL
                )
                .padding(.top, WarrenLayoutMetrics.tabBarHeight + WarrenSpacing.small)
                .padding(.trailing, WarrenSpacing.medium)
            }
        }
        .warrenSemanticObservationRoot(recorder: semanticRecorder)
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
        projection.groups.lazy.compactMap(\WarrenDesktopProjectGroup.workspaces).first?.first
    }

    private func dispatch(_ action: WarrenDesktopAction) {
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

    private func reconcileInspector(with newProjection: WarrenDesktopProjection) {
        if newProjection.inspector == nil {
            inspectorVisible = false
        } else if !inspectorWasAvailable {
            inspectorVisible = true
        }
        inspectorWasAvailable = newProjection.inspector != nil
    }

    private static func restoredSidebarState() -> WarrenDesktopSidebarState {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: WarrenDesktopSidebarKeys.width) as? Double
        return WarrenDesktopSidebarState(
            width: storedWidth ?? WarrenLayoutMetrics.sidebarExpandedWidth,
            isCollapsed: defaults.bool(forKey: WarrenDesktopSidebarKeys.collapsed)
        )
    }

    private static func persist(_ state: WarrenDesktopSidebarState) {
        UserDefaults.standard.set(state.width, forKey: WarrenDesktopSidebarKeys.width)
    }
}

private enum WarrenDesktopSidebarKeys {
    static let width = "warren.desktop.sidebarWidth"
    static let collapsed = "warren.desktop.sidebarCollapsed"
}

/// Compatibility preview shell for the old WarrenNext entry point.
///
/// This is deliberately not the production composition API. It exists only
/// until WarrenNext injects its embedded Host, in-process transport, and real
/// SwiftTerm surface through `WarrenDesktopRoot`.
@available(*, deprecated, message: "Use WarrenDesktopRoot(projection:actions:terminalSurface:) for production composition.")
public struct WarrenDesktopRootView: View {
    public let fixture: WarrenDesktopFixture
    public let chromeMode: WarrenDesktopChromeMode
    private let actions: WarrenDesktopActions

    public init(
        fixture: WarrenDesktopFixture = .preview,
        chromeMode: WarrenDesktopChromeMode = .workspace,
        actions: WarrenDesktopActions = WarrenDesktopActions()
    ) {
        self.fixture = fixture
        self.chromeMode = chromeMode
        self.actions = actions
    }

    public var body: some View {
        WarrenDesktopRoot(
            projection: fixture.projection,
            chromeMode: chromeMode,
            actions: actions
        ) { context in
            WarrenDesktopTerminalPlaceholder(workspace: context.workspace)
        }
    }
}
