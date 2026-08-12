import BurrowDomain

public enum ClientLayoutStoreError: Error, Equatable, Sendable {
    case invalidSidebarWidth(Double)
}

public struct ClientTab: Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var sessionID: TerminalSessionID?
    public var kind: TerminalSessionKind

    public init(
        id: String,
        title: String,
        sessionID: TerminalSessionID? = nil,
        kind: TerminalSessionKind = .shell
    ) {
        self.id = id
        self.title = title
        self.sessionID = sessionID
        self.kind = kind
    }
}

public struct ClientPane: Hashable, Sendable, Identifiable {
    public let id: String
    public var tabID: String?
    public var sessionID: TerminalSessionID?

    public init(id: String, tabID: String? = nil, sessionID: TerminalSessionID? = nil) {
        self.id = id
        self.tabID = tabID
        self.sessionID = sessionID
    }
}

public enum ClientNavigationDestination: Hashable, Sendable {
    case host(HostID)
    case project(ProjectID)
    case workspace(WorkspaceID)
    case session(TerminalSessionID)
}

/// Device-local navigation state. No field in this value is a Host protocol
/// message, and ClientLayoutStore has no transport dependency by design.
public struct ClientLayoutSnapshot: Hashable, Sendable {
    public let clientID: ClientID
    public private(set) var sidebarWidth: Double
    public var sidebarCollapsed: Bool
    public var windowSize: LayoutSize?
    public var tabs: [ClientTab]
    public var selectedTabID: String?
    public var panes: [ClientPane]
    public var selectedPaneID: String?
    public var navigationPath: [ClientNavigationDestination]

    public init?(
        clientID: ClientID,
        sidebarWidth: Double = 240,
        sidebarCollapsed: Bool = false,
        windowSize: LayoutSize? = nil,
        tabs: [ClientTab] = [],
        selectedTabID: String? = nil,
        panes: [ClientPane] = [],
        selectedPaneID: String? = nil,
        navigationPath: [ClientNavigationDestination] = []
    ) {
        guard sidebarWidth.isFinite, sidebarWidth > 0 else {
            return nil
        }
        self.clientID = clientID
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.windowSize = windowSize
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.panes = panes
        self.selectedPaneID = selectedPaneID
        self.navigationPath = navigationPath
    }

    fileprivate mutating func updateSidebarWidth(_ width: Double) {
        sidebarWidth = width
    }

    public var domainLayout: ClientLayout {
        ClientLayout(
            clientID: clientID,
            sidebarWidth: sidebarWidth,
            sidebarCollapsed: sidebarCollapsed,
            windowSize: windowSize
        )
    }
}

/// Stores independent layout snapshots per device identity. Actor isolation
/// protects the map while keeping every mutation local to this client.
public actor ClientLayoutStore {
    private let defaultSidebarWidth: Double
    private var layouts: [ClientID: ClientLayoutSnapshot] = [:]

    public init() {
        self.defaultSidebarWidth = 240
    }

    public init(defaultSidebarWidth: Double) throws {
        guard defaultSidebarWidth.isFinite, defaultSidebarWidth > 0 else {
            throw ClientLayoutStoreError.invalidSidebarWidth(defaultSidebarWidth)
        }
        self.defaultSidebarWidth = defaultSidebarWidth
    }

    public func snapshot(for clientID: ClientID) -> ClientLayoutSnapshot {
        if let layout = layouts[clientID] {
            return layout
        }
        let layout = ClientLayoutSnapshot(clientID: clientID, sidebarWidth: defaultSidebarWidth)!
        layouts[clientID] = layout
        return layout
    }

    public func layout(for clientID: ClientID) -> ClientLayoutSnapshot {
        snapshot(for: clientID)
    }

    public func replace(_ layout: ClientLayoutSnapshot) {
        layouts[layout.clientID] = layout
    }

    public func setSidebarCollapsed(_ collapsed: Bool, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.sidebarCollapsed = collapsed
        layouts[clientID] = layout
    }

    public func setSidebarWidth(_ width: Double, for clientID: ClientID) throws {
        guard width.isFinite, width > 0 else {
            throw ClientLayoutStoreError.invalidSidebarWidth(width)
        }
        var layout = snapshot(for: clientID)
        layout.updateSidebarWidth(width)
        layouts[clientID] = layout
    }

    public func setWindowSize(_ size: LayoutSize?, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.windowSize = size
        layouts[clientID] = layout
    }

    public func replaceTabs(_ tabs: [ClientTab], selectedTabID: String? = nil, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.tabs = tabs
        layout.selectedTabID = selectedTabID
        layouts[clientID] = layout
    }

    public func upsertTab(_ tab: ClientTab, select: Bool = false, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        if let index = layout.tabs.firstIndex(where: { $0.id == tab.id }) {
            layout.tabs[index] = tab
        } else {
            layout.tabs.append(tab)
        }
        if select {
            layout.selectedTabID = tab.id
        }
        layouts[clientID] = layout
    }

    public func removeTab(id: String, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.tabs.removeAll { $0.id == id }
        if layout.selectedTabID == id {
            layout.selectedTabID = nil
        }
        layouts[clientID] = layout
    }

    public func selectTab(id: String?, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.selectedTabID = id
        layouts[clientID] = layout
    }

    public func replacePanes(_ panes: [ClientPane], selectedPaneID: String? = nil, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.panes = panes
        layout.selectedPaneID = selectedPaneID
        layouts[clientID] = layout
    }

    public func selectPane(id: String?, for clientID: ClientID) {
        var layout = snapshot(for: clientID)
        layout.selectedPaneID = id
        layouts[clientID] = layout
    }

    public func setNavigationPath(
        _ path: [ClientNavigationDestination],
        for clientID: ClientID
    ) {
        var layout = snapshot(for: clientID)
        layout.navigationPath = path
        layouts[clientID] = layout
    }

    public func reset(for clientID: ClientID) {
        layouts[clientID] = ClientLayoutSnapshot(
            clientID: clientID,
            sidebarWidth: defaultSidebarWidth
        )!
    }
}
