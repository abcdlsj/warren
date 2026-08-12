import BurrowDomain

public enum ClientLayoutStoreError: Error, Equatable, Sendable {
    case invalidSidebarWidth(Double)
    case workspaceMismatch
}

public struct ClientTab: Codable, Hashable, Sendable, Identifiable {
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

public struct ClientPane: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var tabID: String?
    public var sessionID: TerminalSessionID?

    public init(id: String, tabID: String? = nil, sessionID: TerminalSessionID? = nil) {
        self.id = id
        self.tabID = tabID
        self.sessionID = sessionID
    }
}

public enum ClientNavigationDestination: Codable, Hashable, Sendable {
    case host(HostID)
    case project(ProjectID)
    case workspace(WorkspaceID)
    case session(TerminalSessionID)
}

/// One Window's presentation state for one Workspace. It is device-local and
/// never changes Host Session lifecycle.
public struct ClientWorkspaceView: Codable, Hashable, Sendable, Identifiable {
    public var id: WorkspaceID { workspaceID }
    public let workspaceID: WorkspaceID
    public var tabs: [ClientTab]
    public var activeTabID: String?
    public var panes: [ClientPane]
    public var activePaneID: String?

    public init(
        workspaceID: WorkspaceID,
        tabs: [ClientTab] = [],
        activeTabID: String? = nil,
        panes: [ClientPane] = [],
        activePaneID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.tabs = tabs
        self.activeTabID = tabs.contains(where: { $0.id == activeTabID }) ? activeTabID : nil
        self.panes = panes
        self.activePaneID = activePaneID
    }
}

/// Independent navigation and layout scope for one macOS window.
public struct ClientWindowLayout: Codable, Hashable, Sendable, Identifiable {
    public let id: ClientWindowID
    public private(set) var sidebarWidth: Double
    public var sidebarCollapsed: Bool
    public var windowSize: LayoutSize?
    public var activeWorkspaceID: WorkspaceID?
    public var workspaceViews: [ClientWorkspaceView]
    public var navigationPath: [ClientNavigationDestination]

    public init?(
        id: ClientWindowID = ClientWindowID(),
        sidebarWidth: Double = 240,
        sidebarCollapsed: Bool = false,
        windowSize: LayoutSize? = nil,
        activeWorkspaceID: WorkspaceID? = nil,
        workspaceViews: [ClientWorkspaceView] = [],
        navigationPath: [ClientNavigationDestination] = []
    ) {
        guard sidebarWidth.isFinite, sidebarWidth > 0 else { return nil }
        self.id = id
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.windowSize = windowSize
        self.activeWorkspaceID = activeWorkspaceID
        self.workspaceViews = workspaceViews
        self.navigationPath = navigationPath
    }

    public func workspaceView(for workspaceID: WorkspaceID) -> ClientWorkspaceView? {
        workspaceViews.first { $0.workspaceID == workspaceID }
    }

    public var activeWorkspaceView: ClientWorkspaceView? {
        activeWorkspaceID.flatMap(workspaceView(for:))
    }

    fileprivate mutating func updateSidebarWidth(_ width: Double) {
        sidebarWidth = width
    }
}

/// Complete device-local presentation authority. Host resources and runtime
/// bindings are deliberately absent.
public struct ClientLayoutSnapshot: Codable, Hashable, Sendable {
    public let clientID: ClientID
    public var windows: [ClientWindowLayout]

    public init(clientID: ClientID, windows: [ClientWindowLayout] = []) {
        self.clientID = clientID
        self.windows = windows
    }

    public func window(id: ClientWindowID) -> ClientWindowLayout? {
        windows.first { $0.id == id }
    }
}

public protocol ClientLayoutRepository: Sendable {
    func loadClientLayout(
        clientID: ClientID,
        defaultWindowID: ClientWindowID
    ) async throws -> ClientLayoutSnapshot
    func saveClientLayout(_ layout: ClientLayoutSnapshot) async throws
}

/// Serializes all mutations to the device-local Window/Workspace view tree.
public actor ClientLayoutStore {
    private let clientID: ClientID
    private let defaultWindowID: ClientWindowID
    private let defaultSidebarWidth: Double
    private let repository: (any ClientLayoutRepository)?
    private var layout: ClientLayoutSnapshot

    public init(
        clientID: ClientID,
        defaultWindowID: ClientWindowID,
        repository: (any ClientLayoutRepository)? = nil,
        defaultSidebarWidth: Double = 240
    ) throws {
        guard defaultSidebarWidth.isFinite, defaultSidebarWidth > 0 else {
            throw ClientLayoutStoreError.invalidSidebarWidth(defaultSidebarWidth)
        }
        self.clientID = clientID
        self.defaultWindowID = defaultWindowID
        self.repository = repository
        self.defaultSidebarWidth = defaultSidebarWidth
        self.layout = ClientLayoutSnapshot(clientID: clientID)
    }

    public func start() async throws {
        if let repository {
            layout = try await repository.loadClientLayout(
                clientID: clientID,
                defaultWindowID: defaultWindowID
            )
        }
        if layout.windows.isEmpty {
            layout.windows = [makeWindow(id: defaultWindowID)]
            try await persist()
        }
    }

    public func snapshot() -> ClientLayoutSnapshot { layout }

    public func window(id: ClientWindowID) -> ClientWindowLayout {
        if let window = layout.window(id: id) { return window }
        let window = makeWindow(id: id)
        layout.windows.append(window)
        return window
    }

    public func selectWorkspace(_ workspaceID: WorkspaceID?, in windowID: ClientWindowID) async throws {
        var window = ensureWindow(id: windowID)
        window.activeWorkspaceID = workspaceID
        if let workspaceID, window.workspaceView(for: workspaceID) == nil {
            window.workspaceViews.append(ClientWorkspaceView(workspaceID: workspaceID))
        }
        replaceWindow(window)
        try await persist()
    }

    public func upsertTab(
        _ tab: ClientTab,
        workspaceID: WorkspaceID,
        select: Bool,
        in windowID: ClientWindowID
    ) async throws {
        var window = ensureWindow(id: windowID)
        let index = ensureWorkspaceView(workspaceID, in: &window)
        if let tabIndex = window.workspaceViews[index].tabs.firstIndex(where: { $0.id == tab.id }) {
            window.workspaceViews[index].tabs[tabIndex] = tab
        } else {
            window.workspaceViews[index].tabs.append(tab)
        }
        if select { window.workspaceViews[index].activeTabID = tab.id }
        replaceWindow(window)
        try await persist()
    }

    public func selectTab(
        _ tabID: String?,
        workspaceID: WorkspaceID,
        in windowID: ClientWindowID
    ) async throws {
        var window = ensureWindow(id: windowID)
        let index = ensureWorkspaceView(workspaceID, in: &window)
        guard tabID == nil || window.workspaceViews[index].tabs.contains(where: { $0.id == tabID }) else {
            throw ClientLayoutStoreError.workspaceMismatch
        }
        window.activeWorkspaceID = workspaceID
        window.workspaceViews[index].activeTabID = tabID
        replaceWindow(window)
        try await persist()
    }

    @discardableResult
    public func removeTab(
        id tabID: String,
        workspaceID: WorkspaceID,
        in windowID: ClientWindowID
    ) async throws -> TerminalSessionID? {
        var window = ensureWindow(id: windowID)
        let index = ensureWorkspaceView(workspaceID, in: &window)
        let tabs = window.workspaceViews[index].tabs
        guard let removedIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let sessionID = tabs[removedIndex].sessionID
        window.workspaceViews[index].tabs.remove(at: removedIndex)
        if window.workspaceViews[index].activeTabID == tabID {
            let remaining = window.workspaceViews[index].tabs
            window.workspaceViews[index].activeTabID = remaining.indices.contains(removedIndex)
                ? remaining[removedIndex].id
                : remaining.last?.id
        }
        replaceWindow(window)
        try await persist()
        return sessionID
    }

    public func removeTabs(
        workspaceID: WorkspaceID,
        except tabID: String? = nil,
        in windowID: ClientWindowID
    ) async throws -> [TerminalSessionID] {
        var window = ensureWindow(id: windowID)
        let index = ensureWorkspaceView(workspaceID, in: &window)
        let removed = window.workspaceViews[index].tabs.filter { $0.id != tabID }
        window.workspaceViews[index].tabs.removeAll { $0.id != tabID }
        window.workspaceViews[index].activeTabID = tabID
        replaceWindow(window)
        try await persist()
        return removed.compactMap(\.sessionID)
    }

    public func setSidebarCollapsed(_ collapsed: Bool, in windowID: ClientWindowID) async throws {
        var window = ensureWindow(id: windowID)
        window.sidebarCollapsed = collapsed
        replaceWindow(window)
        try await persist()
    }

    public func setSidebarWidth(_ width: Double, in windowID: ClientWindowID) async throws {
        guard width.isFinite, width > 0 else { throw ClientLayoutStoreError.invalidSidebarWidth(width) }
        var window = ensureWindow(id: windowID)
        window.updateSidebarWidth(width)
        replaceWindow(window)
        try await persist()
    }

    private func makeWindow(id: ClientWindowID) -> ClientWindowLayout {
        ClientWindowLayout(id: id, sidebarWidth: defaultSidebarWidth)!
    }

    private func ensureWindow(id: ClientWindowID) -> ClientWindowLayout {
        window(id: id)
    }

    private func ensureWorkspaceView(
        _ workspaceID: WorkspaceID,
        in window: inout ClientWindowLayout
    ) -> Int {
        if let index = window.workspaceViews.firstIndex(where: { $0.workspaceID == workspaceID }) {
            return index
        }
        window.workspaceViews.append(ClientWorkspaceView(workspaceID: workspaceID))
        return window.workspaceViews.endIndex - 1
    }

    private func replaceWindow(_ window: ClientWindowLayout) {
        if let index = layout.windows.firstIndex(where: { $0.id == window.id }) {
            layout.windows[index] = window
        } else {
            layout.windows.append(window)
        }
    }

    private func persist() async throws {
        try await repository?.saveClientLayout(layout)
    }
}
