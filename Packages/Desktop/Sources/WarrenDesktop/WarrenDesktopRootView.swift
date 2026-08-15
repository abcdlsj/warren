import SwiftUI
import os
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
    public let webStatus: WarrenDesktopWebStatus

    private let endpointOptions: [WarrenDesktopEndpointOption]
    private let selectedEndpointID: String
    private let onSelectEndpoint: (String) -> Void

    private let actions: WarrenDesktopActions
    private let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    private let onWebStart: () -> Void
    private let onWebStop: () -> Void
    private let onWebOpenURL: (URL) -> Void
    private let onWebCopyURL: (URL) -> Void
    @State private var sidebarState: WarrenDesktopSidebarState
    @State private var inspectorVisible: Bool
    @State private var inspectorWasAvailable: Bool
    @State private var commandPalettePresented = false
    @State private var settingsPresented = false
    @State private var navigationBeforeSettings: WarrenDesktopNavigationState?
    @State private var webPresented = false
    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var terminalTitleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
    @Environment(\.warrenSemanticRecorder) private var semanticRecorder

    private struct Presentation {
        let workspace: Workspace?
        let contentWorkspace: Workspace?
        let tab: ClientTab?
        let session: WarrenDesktopSession?
        let tabs: [ClientTab]
    }

    public init(
        projection: WarrenDesktopProjection,
        navigation: WarrenDesktopNavigationState? = nil,
        chromeMode: WarrenDesktopChromeMode = .workspace,
        actions: WarrenDesktopActions = WarrenDesktopActions(),
        webStatus: WarrenDesktopWebStatus = .init(),
        endpointOptions: [WarrenDesktopEndpointOption] = [
            .init(id: "local", label: "Local", isLocal: true),
        ],
        selectedEndpointID: String = "local",
        onSelectEndpoint: @escaping (String) -> Void = { _ in },
        onWebStart: @escaping () -> Void = {},
        onWebStop: @escaping () -> Void = {},
        onWebOpenURL: @escaping (URL) -> Void = { _ in },
        onWebCopyURL: @escaping (URL) -> Void = { _ in },
        @ViewBuilder terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.projection = projection
        self.navigation = navigation ?? WarrenDesktopNavigationReducer.initial(for: projection)
        self.chromeMode = chromeMode
        self.webStatus = webStatus
        self.endpointOptions = endpointOptions
        self.selectedEndpointID = selectedEndpointID
        self.onSelectEndpoint = onSelectEndpoint
        self.actions = actions
        self.terminalSurface = terminalSurface
        self.onWebStart = onWebStart
        self.onWebStop = onWebStop
        self.onWebOpenURL = onWebOpenURL
        self.onWebCopyURL = onWebCopyURL
        _sidebarState = State(initialValue: Self.restoredSidebarState())
        _inspectorVisible = State(initialValue: projection.inspector != nil)
        _inspectorWasAvailable = State(initialValue: projection.inspector != nil)
    }

    public var body: some View {
        let presentation = makePresentation()
        ZStack(alignment: .topLeading) {
            if settingsPresented {
                WarrenDesktopSettingsView(onBack: closeSettings)
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
                        tabs: presentation.tabs,
                        selectedTabID: navigation.selectedTabID,
                        chromeMode: chromeMode,
                        isSidebarCollapsed: sidebarState.isCollapsed,
                        isConnected: projection.isConnected,
                        endpointOptions: endpointOptions,
                        selectedEndpointID: selectedEndpointID,
                        webStatus: webStatus,
                        hasInspector: projection.inspector != nil,
                        isInspectorVisible: inspectorVisible,
                        onToggleSidebar: toggleSidebar,
                        onToggleInspector: toggleInspector,
                        onCommandPalette: { commandPalettePresented = true },
                        onSettings: {
                            commandPalettePresented = false
                            navigationBeforeSettings = navigation
                            settingsPresented = true
                        },
                        onWeb: { webPresented.toggle() },
                        onSelectEndpoint: onSelectEndpoint,
                        onSelectTab: { dispatch(.selectTab($0)) },
                        onMoveTab: { tabID, destinationTabID in
                            dispatch(.moveTab(tabID, before: destinationTabID))
                        },
                        canAddTab: presentation.workspace != nil,
                        onAddTab: {
                            guard let workspaceID = presentation.workspace?.id else { return }
                            dispatch(.requestNewSession(workspaceID))
                        },
                        onCloseTab: { dispatch(.closeTab($0)) },
                        onCloseOtherTabs: { dispatch(.closeOtherTabs($0)) },
                        onCloseAllTabs: { dispatch(.closeAllTabs) }
                    )
                    WarrenDesktopPresetBar(
                        workspace: presentation.workspace,
                        onLaunch: { request in
                            guard let workspaceID = presentation.workspace?.id else { return }
                            dispatch(.launchSession(workspaceID, request))
                        }
                    )
                    HStack(spacing: 0) {
                        WarrenDesktopWorkspaceContent(
                            workspace: presentation.contentWorkspace,
                            tab: presentation.tab,
                            hasProjects: !projection.groups.isEmpty,
                            // Superset keeps the 28pt pane toolbar in workspace
                            // mode too. It is pane chrome, not a duplicate top bar.
                            showsPaneHeader: true,
                            session: presentation.session,
                            hostName: projection.host.name,
                            titleTemplate: TerminalDisplayTitleTemplate(rawValue: terminalTitleTemplate),
                            terminalFont: TerminalFontPreference(
                                family: terminalFontFamily,
                                size: terminalFontSize
                            ),
                            onAddProject: { dispatch(.addProject) },
                            onImportSuperset: { dispatch(.importSuperset) },
                            onNewSession: {
                                guard let workspace = presentation.workspace else { return }
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
            guard let workspace = presentation.workspace else { return }
            dispatch(.requestNewSession(workspace.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.nextTab)) { _ in
            guard let tabID = WarrenDesktopTabCycler.tabID(
                forward: true,
                in: presentation.tabs,
                selectedTabID: navigation.selectedTabID
            ) else { return }
            dispatch(.selectTab(tabID))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.previousTab)) { _ in
            guard let tabID = WarrenDesktopTabCycler.tabID(
                forward: false,
                in: presentation.tabs,
                selectedTabID: navigation.selectedTabID
            ) else { return }
            dispatch(.selectTab(tabID))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.closeTab)) { _ in
            guard let tab = presentation.tab, tab.sessionID != nil else { return }
            dispatch(.closeTab(tab.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleInspector)) { _ in
            toggleInspector()
        }
        .overlay {
            if commandPalettePresented && !settingsPresented {
                GeometryReader { proxy in
                    let panelWidth = min(
                        WarrenLayoutMetrics.commandPaletteWidth,
                        max(0, proxy.size.width - WarrenSpacing.standard * 2)
                    )
                    let resultsMaxHeight = max(
                        0,
                        proxy.size.height * 0.8
                            - WarrenLayoutMetrics.commandInputHeight
                            - WarrenSpacing.hairline
                    )
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()
                            .onTapGesture { commandPalettePresented = false }

                        WarrenDesktopCommandPalette(
                            projection: projection,
                            onAction: dispatch,
                            onDismiss: { commandPalettePresented = false },
                            width: panelWidth,
                            resultsMaxHeight: resultsMaxHeight
                        )
                        .padding(.top, max(WarrenSpacing.standard, proxy.size.height * 0.5 - 278))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .overlay(alignment: .topTrailing) {
            if webPresented && !settingsPresented {
                WarrenDesktopWebPanel(
                    status: webStatus,
                    onStart: onWebStart,
                    onStop: onWebStop,
                    onOpenURL: onWebOpenURL,
                    onCopyURL: onWebCopyURL
                )
                .padding(.top, WarrenLayoutMetrics.tabBarHeight + WarrenSpacing.small)
                .padding(.trailing, WarrenSpacing.medium)
            }
        }
        .warrenSemanticObservationRoot(recorder: semanticRecorder)
    }

    /// Resolve all selection-dependent UI values once per body evaluation.
    /// SwiftUI asks for these values in several branches and closures; keeping
    /// one immutable presentation value avoids repeated graph lookups while
    /// preserving the navigation ownership rules.
    private func makePresentation() -> Presentation {
        let interval = WarrenDesktopPerformance.signposter.beginInterval("SwiftUI Presentation")
        defer { WarrenDesktopPerformance.signposter.endInterval("SwiftUI Presentation", interval) }
        let navigationWorkspace: Workspace?
        switch navigation.selection {
        case .project(let projectID):
            navigationWorkspace = projection.firstWorkspace(in: projectID)
        case .workspace(let workspaceID):
            navigationWorkspace = projection.workspace(id: workspaceID)
        case nil:
            navigationWorkspace = firstWorkspace
        }
        let tabs = navigationWorkspace.map { projection.tabs(in: $0.id) } ?? []
        let tab = navigation.selectedTabID.flatMap { selectedTabID in
            tabs.first { $0.id == selectedTabID }
        }
        let tabWorkspace = tab?.sessionID.flatMap { projection.workspace(for: $0) }
        let workspace = tabWorkspace ?? navigationWorkspace
        let session = tab?.sessionID.flatMap { projection.session(id: $0) }
        return Presentation(
            workspace: workspace,
            contentWorkspace: tabWorkspace ?? workspace,
            tab: tab,
            session: session,
            tabs: tabs
        )
    }

    private var firstWorkspace: Workspace? {
        projection.firstWorkspace
    }

    private func dispatch(_ action: WarrenDesktopAction) {
        actions(action)
    }

    private func closeSettings() {
        let previousNavigation = navigationBeforeSettings
        navigationBeforeSettings = nil
        settingsPresented = false
        if let previousNavigation {
            dispatch(.restoreNavigation(previousNavigation))
        }
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

/// Pure tab-cycling rule for the ⌘X / ⇧⌘X shortcuts. A workspace must have
/// more than one open tab; without a current selection the first tab wins.
enum WarrenDesktopTabCycler {
    static func tabID(
        forward: Bool,
        in tabs: [ClientTab],
        selectedTabID: String?
    ) -> String? {
        guard tabs.count > 1 else { return nil }
        guard let selectedTabID,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            return tabs.first?.id
        }
        let nextIndex = (
            selectedIndex + (forward ? 1 : -1) + tabs.count
        ) % tabs.count
        return tabs[nextIndex].id
    }
}

private enum WarrenDesktopPerformance {
    static let signposter = OSSignposter(
        subsystem: "com.abcdlsj.warren",
        category: "UI Performance"
    )
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
