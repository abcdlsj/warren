import Foundation
import AppKit
import Observation
import WarrenApplication
import WarrenClientCore
import WarrenDesktop
import WarrenDomain
import GhosttyAdapter
import WarrenProtocol
import WarrenStateStore
import WarrenTmuxRuntime
import WebRelay
import Darwin

@MainActor
@Observable
final class WarrenNextApplicationModel {
    private(set) var snapshot: WarrenApplicationSnapshot
    private(set) var desktopProjection: WarrenDesktopProjection
    private(set) var navigation: WarrenDesktopNavigationState
    private(set) var presentedIssue: WarrenApplicationIssue?
    private(set) var pendingDefaultShellWorkspaceIDs: Set<WorkspaceID> = []
    private(set) var webRelayStatus = WarrenDesktopWebRelayStatus()

    @ObservationIgnored private let service: WarrenApplicationService
    @ObservationIgnored private let runtime: TmuxRuntime
    @ObservationIgnored private let renderer: WarrenRendererCoordinator
    @ObservationIgnored private var webRelay: WebRelayServer?
    @ObservationIgnored private var relayHostConnector: RelayHostConnector?
    @ObservationIgnored private let controlPlaneConfiguration: (url: URL, hostID: String, credential: String)?
    @ObservationIgnored private var relayStopTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    /// Host mutations are ordered per Workspace. A slow agent launch in one
    /// project must never block navigation or operations in another project.
    @ObservationIgnored private var workspaceActionTasks: [WorkspaceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var acceptingActions = true
    @ObservationIgnored private var shutdownStarted = false
    @ObservationIgnored private var shutdownFinished = false

    init(
        service: WarrenApplicationService,
        runtime: TmuxRuntime,
        controlPlaneConfiguration: (url: URL, hostID: String, credential: String)? = nil
    ) {
        self.service = service
        self.runtime = runtime
        self.controlPlaneConfiguration = controlPlaneConfiguration
        self.renderer = WarrenRendererCoordinator(service: service)
        let initialSnapshot = WarrenApplicationSnapshot.empty()
        let initialProjection = WarrenDesktopProjection.empty(host: initialSnapshot.host)
        self.snapshot = initialSnapshot
        self.desktopProjection = initialProjection
        self.navigation = WarrenDesktopNavigationReducer.initial(for: initialProjection)
        // Bind the local WebRelay as soon as the composition model exists.
        // Startup/session restoration may be expensive; remote availability
        // must not depend on SwiftUI finishing its first transaction.
        startWebRelay()
        startControlPlaneConnectorIfConfigured()
    }

    static func live() -> WarrenNextApplicationModel {
        let isHeadlessAcceptance = ProcessInfo.processInfo.environment[
            "WARREN_HEADLESS_ACCEPTANCE"
        ] == "1"
        let controlPlaneConfiguration = isHeadlessAcceptance
            ? nil
            : WarrenControlPlaneCredentialStore.loadOrImport(
                environment: ProcessInfo.processInfo.environment
            )
        if !isHeadlessAcceptance {
            unsetenv("WARREN_CONTROL_PLANE_URL")
            unsetenv("WARREN_CONTROL_PLANE_HOST_ID")
            unsetenv("WARREN_CONTROL_PLANE_HOST_TOKEN")
        }
        // Headless verification must not read/write real pairing preferences
        // or rewrite real user agent config.
        let hookEnvironment = isHeadlessAcceptance
            ? [:]
            : WebRelayServer.agentHookEnvironment
        if !isHeadlessAcceptance {
            _ = WebRelayServer.installAgentHooks()
        }
        let tmuxSocketName = ProcessInfo.processInfo.environment["WARREN_TMUX_SOCKET_NAME"]
        let runtime = TmuxRuntime(
            executor: ProcessTmuxCommandExecutor(socketName: tmuxSocketName),
            outputDirectory: WarrenApplicationDefaults.runtimeOutputDirectory(),
            sessionEnvironment: hookEnvironment
        )
        let repository: SQLiteHostStateRepository
        do {
            repository = try SQLiteHostStateRepository(
                databaseURL: WarrenApplicationDefaults.stateDatabaseURL()
            )
        } catch {
            fatalError("Could not open Warren state database: \(error)")
        }
        let service = WarrenApplicationService(
            repository: repository,
            runtime: runtime,
            hostName: Host.current().localizedName ?? "Local Mac"
        )
        return WarrenNextApplicationModel(
            service: service,
            runtime: runtime,
            controlPlaneConfiguration: controlPlaneConfiguration
        )
    }

    private func makeDesktopProjection() -> WarrenDesktopProjection {
        let interval = WarrenPerformance.signposter.beginInterval("Desktop Projection")
        defer { WarrenPerformance.signposter.endInterval("Desktop Projection", interval) }
        let issue = presentedIssue
        let inspector = issue.map {
            WarrenDesktopInspectorContent(
                id: $0.id,
                title: $0.title,
                detail: "\($0.detail)\n\n\($0.recoverySuggestion)"
            )
        }
        var tabs = snapshot.windowLayout.workspaceViews.flatMap(\.tabs)
        // Sidebar activity is a Host-resource projection, not a Tab
        // projection. A live headless Session or a Session whose layout entry
        // is missing must still make its Workspace visible.
        // The desktop sidebar is a view of this window's Client layout, not a
        // durable Host history list. Dormant Sessions may still be running for
        // Web/remote clients, but without a local Tab they must not appear as
        // clickable desktop rows.
        let visibleSessions = snapshot.sessions.filter { $0.tabID != nil }
        let workspaceIDs = Dictionary(
            uniqueKeysWithValues: visibleSessions.map { ($0.id, $0.workspaceID) }
        )
        var tabWorkspaceIDs = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            tab.sessionID.flatMap { workspaceIDs[$0] }.map { (tab.id, $0) }
        })
        for workspaceID in pendingDefaultShellWorkspaceIDs
            where !tabs.contains(where: { tabWorkspaceIDs[$0.id] == workspaceID }) {
            let pending = ClientTab(
                id: Self.pendingShellTabID(for: workspaceID),
                title: "Starting Shell…",
                kind: .shell
            )
            tabs.append(pending)
            tabWorkspaceIDs[pending.id] = workspaceID
        }
        return WarrenDesktopProjection(
            host: snapshot.host,
            projects: snapshot.projects,
            workspaces: snapshot.workspaces,
            sessions: visibleSessions.map { session in
                WarrenDesktopSession(
                    id: session.id,
                    workspaceID: session.workspaceID,
                    tabID: session.tabID,
                    title: session.title,
                    kind: session.kind,
                    state: Self.desktopSessionState(
                        for: session.connectionState,
                        lifecycle: session.lifecycle
                    ),
                    activity: session.agentActivity,
                    runtimeProcess: session.runtimeProcess,
                    workingDirectory: session.workingDirectory
                )
            },
            tabs: tabs,
            sessionWorkspaceIDs: workspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            inspector: inspector,
            connectionState: desktopConnectionState
        )
    }

    func start() async {
        guard !started else { return }
        started = true
        let stream = await service.snapshots()
        snapshotTask = Task { @MainActor [weak self, stream] in
            for await value in stream {
                guard !Task.isCancelled else { return }
                await self?.apply(value)
            }
        }
        do {
            try await service.start()
            // The model may have been constructed before AppKit's run loop
            // started. Kick the outbound connector again from the live startup
            // task so URLSession gets a scheduling point after launch.
            startControlPlaneConnectorIfConfigured()
        } catch {
            present(error)
        }
    }

    func beginShutdown() {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        acceptingActions = false
        snapshotTask?.cancel()
        snapshotTask = nil
        for task in workspaceActionTasks.values {
            task.cancel()
        }
        workspaceActionTasks.removeAll()
        renderer.shutdown()
        webRelay?.stop()
        webRelay = nil
        webRelayStatus = WarrenDesktopWebRelayStatus()
        if let relayHostConnector {
            self.relayHostConnector = nil
            relayStopTask = Task { await relayHostConnector.stop() }
        }
    }

    func shutdown() async {
        beginShutdown()
        guard !shutdownFinished else { return }
        await relayStopTask?.value
        relayStopTask = nil
        await service.shutdown()
        await runtime.shutdown()
        shutdownFinished = true
    }

    func addProject(_ folder: URL) async {
        await run { _ = try await service.addProject(folder: folder) }
    }

    func headlessCreateShell(folder: URL) async throws -> TerminalSessionID {
        let project = try await service.addProject(folder: folder)
        let workspace = try await service.rootWorkspace(for: project.id)
        let tabID = try await service.addTab(workspaceID: workspace.id)
        let value = await service.snapshot()
        guard let sessionID = value.tabs(in: workspace.id)
            .first(where: { $0.id == tabID })?.sessionID else {
            throw WarrenApplicationError.unsupportedAction(
                "Headless lifecycle probe could not resolve the created session."
            )
        }
        return sessionID
    }

    func runtimeExists(sessionID: TerminalSessionID) async -> Bool {
        await runtime.presence(sessionID: sessionID) == .present
    }

    private func startWebRelay() {
        guard webRelay == nil else { return }
        let relay = WebRelayServer(service: service)
        relay.start()
        webRelay = relay
        updateWebRelayStatus()
        guard relay.listeningPort == WebRelayServer.defaultPort else { return }
        startControlPlaneConnectorIfConfigured()
    }

    func startWebRelayFromUI() {
        if webRelay == nil {
            let relay = WebRelayServer(service: service)
            relay.start()
            webRelay = relay
        } else if webRelay?.listeningPort == nil {
            webRelay?.start()
        }
        updateWebRelayStatus()
    }

    func stopWebRelay() {
        webRelay?.stop()
        updateWebRelayStatus()
    }

    private func updateWebRelayStatus() {
        webRelayStatus = WarrenDesktopWebRelayStatus(
            isRunning: webRelay?.listeningPort == WebRelayServer.defaultPort,
            localURL: WebRelayServer.localWebURL,
            secureURL: webRelay?.secureWebURL
        )
    }

    func openWebRelayURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyWebRelayURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Remote control is opt-in. Defining both environment values creates one
    /// outbound Host tunnel; ordinary launches remain loopback-only.
    private func startControlPlaneConnectorIfConfigured() {
        guard ProcessInfo.processInfo.environment["WARREN_HEADLESS_ACCEPTANCE"] != "1",
              relayHostConnector == nil,
              let configuration = controlPlaneConfiguration
                  ?? WarrenControlPlaneCredentialStore.loadOrImport(
                      environment: ProcessInfo.processInfo.environment
                  ) else { return }
        NSLog("Warren control-plane connector starting for %@", configuration.url.absoluteString)
        let connector = RelayHostConnector(configuration: .init(
            relayURL: configuration.url,
            hostID: configuration.hostID,
            hostName: snapshot.host.name,
            bootstrapToken: configuration.credential,
            localPairingToken: WebRelayServer.accessToken
        ))
        relayHostConnector = connector
        // Do not inherit the SwiftUI main actor here. A busy AttributeGraph
        // update must not prevent the Host WebSocket from reaching Relay.
        Task.detached { await connector.start() }
    }

    func copyLocalWebURL() {
        guard webRelay != nil, let url = WebRelayServer.localWebURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func startCloudflareWebAccess() {
        webRelay?.startTunnel()
    }

    func stopCloudflareWebAccess() {
        webRelay?.stopTunnel()
    }

    func startTailscaleWebAccess() {
        Task { await webRelay?.startTailscale() }
    }

    func stopTailscaleWebAccess() {
        Task { await webRelay?.stopTailscale() }
    }

    func copySecureWebURL() {
        guard let url = webRelay?.secureWebURL else {
            present(WarrenApplicationError.transport(
                "Secure Web access is not ready. Start Cloudflare Tunnel or Tailscale Serve first."
            ))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func previewSupersetImport(from databaseURL: URL) async throws -> SupersetImportPreview {
        try await service.previewSupersetImport(from: databaseURL)
    }

    func commitSupersetImport(_ preview: SupersetImportPreview) async {
        do {
            _ = try await service.commitSupersetImport(preview)
        } catch {
            present(error)
        }
    }

    func createWorkspace(projectID: ProjectID, request: WorkspaceCreationRequest) {
        guard acceptingActions else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let workspace = try await service.createWorkspace(
                    projectID: projectID,
                    request: request
                )
                navigation = WarrenDesktopNavigationState(
                    selection: .workspace(workspace.id),
                    selectedTabID: nil
                )
            } catch {
                present(error)
            }
        }
    }

    func createSession(
        workspaceID: WorkspaceID,
        request: TerminalSessionLaunchRequest
    ) {
        guard acceptingActions else { return }
        enqueueWorkspaceAction(workspaceID: workspaceID) { [weak self] in
            guard let self else { return }
            do {
                let tabID = try await self.service.addTab(
                    workspaceID: workspaceID,
                    request: request.identified()
                )
                self.selectCreatedTab(tabID, workspaceID: workspaceID)
            } catch {
                self.present(error)
            }
        }
    }

    func perform(_ action: WarrenDesktopAction) {
        guard acceptingActions else { return }
        if case .selectWorkspace(let workspaceID) = action,
           desktopProjection.tabs(in: workspaceID).isEmpty {
            pendingDefaultShellWorkspaceIDs.insert(workspaceID)
            refreshDesktopProjection()
        }
        navigation = WarrenDesktopNavigationReducer.reduce(
            navigation,
            action: action,
            in: desktopProjection
        )

        switch action {
        case .selectProject, .selectWorkspace, .selectTab, .openSession, .deleteSession:
            reconcileSurfaces(with: snapshot)
        case .addProject, .importSuperset, .requestNewWorkspace, .renameWorkspace, .moveTab,
             .requestNewSession, .launchSession,
             .closeTab, .closeOtherTabs, .closeAllTabs,
             .toggleInspector, .toggleSidebar:
            break
        }

        if action.requiresClientLayoutSideEffect {
            Task { @MainActor [weak self] in
                await self?.performClientLayout(action)
            }
        }

        if case .selectWorkspace(let workspaceID) = action {
            enqueueWorkspaceAction(workspaceID: workspaceID) { [weak self] in
                await self?.ensureDefaultShellTab(in: workspaceID)
            }
        } else if action.requiresHostSideEffect,
                  let workspaceID = workspaceID(for: action) {
            enqueueWorkspaceAction(workspaceID: workspaceID) { [weak self] in
                await self?.performSerial(action)
            }
        }
    }

    func dismissIssue() {
        presentedIssue = nil
        refreshDesktopProjection()
    }

    func report(_ error: Error) {
        present(error)
    }

    var mountedSurfaces: [GhosttySurface] { renderer.mountedSurfaces }


    func enqueueWorkspaceAction(
        workspaceID: WorkspaceID,
        operation: @escaping @MainActor () async -> Void
    ) {
        let previous = workspaceActionTasks[workspaceID]
        workspaceActionTasks[workspaceID] = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.acceptingActions else { return }
            await operation()
        }
    }

    func workspaceID(for action: WarrenDesktopAction) -> WorkspaceID? {
        switch action {
        case .launchSession(let workspaceID, _),
             .requestNewSession(let workspaceID),
             .selectWorkspace(let workspaceID):
            return workspaceID
        case .openSession(let sessionID):
            return desktopProjection.sessions.first { $0.id == sessionID }?.workspaceID
        case .deleteSession(let sessionID):
            return desktopProjection.sessions.first { $0.id == sessionID }?.workspaceID
        case .closeTab(let tabID), .closeOtherTabs(let tabID), .moveTab(let tabID, _):
            return workspaceID(forTabID: tabID)
        case .closeAllTabs:
            return selectedWorkspaceID
        case .renameWorkspace(let workspaceID, _):
            return workspaceID
        case .addProject, .importSuperset, .requestNewWorkspace,
             .selectProject, .selectTab,
             .toggleInspector, .toggleSidebar:
            return nil
        }
    }

}

extension WarrenNextApplicationModel {
    func ensureDefaultShellTab(in workspaceID: WorkspaceID) async {
        do {
            let tabID = try await service.ensureDefaultShellTab(workspaceID: workspaceID)
            selectCreatedTab(tabID, workspaceID: workspaceID)
        } catch {
            pendingDefaultShellWorkspaceIDs.remove(workspaceID)
            refreshDesktopProjection()
            present(error)
        }
    }

    func performSerial(_ action: WarrenDesktopAction) async {
        switch action {
        case .requestNewSession:
            break
        case .closeTab(let tabID):
            // Close actions are generated from a value snapshot.  Treat a
            // stale action as a successful no-op so a rapid double-click does
            // not surface an error inspector.
            guard let workspaceID = workspaceID(forTabID: tabID) else { return }
            await run {
                try await service.closeTabIfPresent(tabID: tabID, workspaceID: workspaceID)
            }
        case .closeOtherTabs(let tabID):
            guard let workspaceID = workspaceID(forTabID: tabID) else { return }
            await service.closeTabs(in: workspaceID, except: tabID)
        case .closeAllTabs:
            guard let workspaceID = selectedWorkspaceID else { return }
            await service.closeTabs(in: workspaceID)
        case .openSession(let sessionID):
            do {
                let tabID = try await service.openSession(sessionID: sessionID)
                if let session = desktopProjection.sessions.first(where: { $0.id == sessionID }) {
                    selectCreatedTab(tabID, workspaceID: session.workspaceID)
                }
            } catch {
                present(error)
            }
        case .deleteSession(let sessionID):
            await run {
                try await service.deleteSession(sessionID: sessionID)
                // A prior restore failure may still be the visible inspector
                // issue. Once the destructive operation succeeds, remove that
                // stale diagnostic so it cannot cover the empty workspace.
                self.presentedIssue = nil
                self.refreshDesktopProjection()
            }
        case .renameWorkspace(let workspaceID, let name):
            await run { try await service.renameWorkspace(workspaceID, name: name) }
        case .launchSession(let workspaceID, let request):
            do {
                let tabID = try await service.addTab(
                    workspaceID: workspaceID,
                    request: request.identified()
                )
                selectCreatedTab(tabID, workspaceID: workspaceID)
            } catch {
                present(error)
            }
        case .addProject, .importSuperset, .requestNewWorkspace, .moveTab,
             .selectProject, .selectWorkspace, .selectTab,
             .toggleInspector, .toggleSidebar:
            break
        }
    }

    func performClientLayout(_ action: WarrenDesktopAction) async {
        do {
            switch action {
            case .selectWorkspace(let workspaceID):
                try await service.selectWorkspace(workspaceID)
            case .selectProject(let projectID):
                if let workspaceID = desktopProjection.firstWorkspace(in: projectID)?.id {
                    try await service.selectWorkspace(workspaceID)
                }
            case .selectTab(let tabID):
                if let workspaceID = workspaceID(forTabID: tabID) {
                    try await service.selectTab(tabID: tabID, workspaceID: workspaceID)
                }
            case .moveTab(let tabID, let destinationTabID):
                if let workspaceID = workspaceID(forTabID: tabID) {
                    try await service.moveTab(
                        tabID: tabID,
                        before: destinationTabID,
                        workspaceID: workspaceID
                    )
                }
            default:
                return
            }
        } catch {
            present(error)
        }
    }

    var desktopConnectionState: WarrenDesktopConnectionState {
        switch snapshot.lifecycle {
        case .idle, .stopping:
            return .disconnected
        case .starting:
            return .connecting
        case .failed:
            return .failed
        case .ready:
            if snapshot.sessions.contains(where: { $0.connectionState == .failed }) { return .failed }
            if snapshot.sessions.contains(where: { $0.connectionState == .reconnecting }) { return .reconnecting }
            if snapshot.sessions.contains(where: { $0.connectionState == .connecting }) { return .connecting }
            return .attached
        }
    }

    private static func desktopSessionState(
        for state: WarrenApplicationConnectionState,
        lifecycle: TerminalSessionLifecycle
    ) -> WarrenDesktopSessionState {
        guard lifecycle == .running else { return .exited }
        switch state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .attached: return .attached
        case .reconnecting: return .reconnecting
        case .failed: return .failed
        }
    }

    func apply(_ value: WarrenApplicationSnapshot) async {
        let previousSnapshot = snapshot
        let previousPendingWorkspaceIDs = pendingDefaultShellWorkspaceIDs
        let previousIssue = presentedIssue
        snapshot = value
        pendingDefaultShellWorkspaceIDs = pendingDefaultShellWorkspaceIDs.filter {
            value.tabs(in: $0).isEmpty
        }
        if presentedIssue == nil {
            presentedIssue = value.issues.last(where: { issue in
                Self.issueBelongsToDesktop(issue, snapshot: value)
            })
        }
        // PTY output snapshots arrive as often as every display frame. Output,
        // attachment cursors and terminal geometry belong to the renderer, not
        // the SwiftUI read model. Skip rebuilding the entire project/sidebar/
        // tab projection when none of its actual inputs changed.
        if previousPendingWorkspaceIDs != pendingDefaultShellWorkspaceIDs
            || previousIssue != presentedIssue
            || !Self.desktopProjectionInputsEqual(previousSnapshot, value) {
            refreshDesktopProjection()
        }
        let nextNavigation = WarrenDesktopNavigationReducer.reconcile(
            navigation,
            with: desktopProjection
        )
        // Snapshot publications are also used for coalesced PTY output. Do
        // not invalidate the whole SwiftUI root when navigation did not
        // actually change; doing so turns background terminal output into a
        // continuous AttributeGraph rebuild.
        if nextNavigation != navigation {
            navigation = nextNavigation
        }
        reconcileSurfaces(with: value)
    }

    static func desktopProjectionInputsEqual(
        _ lhs: WarrenApplicationSnapshot,
        _ rhs: WarrenApplicationSnapshot
    ) -> Bool {
        guard lhs.host == rhs.host,
              lhs.projects == rhs.projects,
              lhs.workspaces == rhs.workspaces,
              lhs.windowLayout == rhs.windowLayout,
              lhs.lifecycle == rhs.lifecycle,
              lhs.sessions.count == rhs.sessions.count else { return false }

        return zip(lhs.sessions, rhs.sessions).allSatisfy { left, right in
            left.id == right.id
                && left.workspaceID == right.workspaceID
                && left.tabID == right.tabID
                && left.title == right.title
                && left.kind == right.kind
                && left.lifecycle == right.lifecycle
                && left.connectionState == right.connectionState
                && left.agentActivity == right.agentActivity
                && left.runtimeProcess == right.runtimeProcess
                && left.workingDirectory == right.workingDirectory
        }
    }

    func reconcileSurfaces(
        with value: WarrenApplicationSnapshot,
        terminalFont: TerminalFontPreference? = nil
    ) {
        let defaults = UserDefaults.standard
        let font = terminalFont ?? TerminalFontPreference(
            family: defaults.string(forKey: WarrenPreferenceKey.terminalFontFamily)
                ?? TerminalFontPreference.defaultFamily,
            size: defaults.object(forKey: WarrenPreferenceKey.terminalFontSize) as? Double
                ?? TerminalFontPreference.defaultSize
        )
        renderer.reconcile(
            snapshot: value,
            activeWorkspaceID: selectedWorkspaceID,
            activeSessionID: selectedTerminalSessionID,
            terminalFont: font,
            reportError: { [weak self] error in self?.present(error) }
        )
    }

    func updateTerminalFont(_ preference: TerminalFontPreference) {
        reconcileSurfaces(with: snapshot, terminalFont: preference)
    }

    func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            present(error)
        }
    }

    func present(_ error: Error) {
        presentedIssue = WarrenApplicationIssue(id: "ui.\(String(describing: error))", error: error)
        refreshDesktopProjection()
    }

    private static func issueBelongsToDesktop(
        _ issue: WarrenApplicationIssue,
        snapshot: WarrenApplicationSnapshot
    ) -> Bool {
        // Restore/adoption issues are scoped to one durable Session. Do not
        // surface an error for a hidden Host/Web Session in the desktop pane.
        // Transport and project/workspace issues remain global diagnostics.
        guard issue.id.hasPrefix("session.") else { return true }
        let parts = issue.id.split(separator: ".")
        guard parts.count >= 2 else { return true }
        let rawID = String(parts[1])
        return snapshot.sessions.contains {
            $0.id.description == rawID && $0.tabID != nil
        }
    }

    func refreshDesktopProjection() {
        let next = makeDesktopProjection()
        guard next != desktopProjection else { return }
        desktopProjection = next
    }

    func selectCreatedTab(_ tabID: String, workspaceID: WorkspaceID) {
        // A launch captures its destination Workspace. If the user navigated
        // elsewhere while tmux was starting, keep the new Tab in its original
        // Workspace View without stealing the current screen.
        guard selectedWorkspaceID == workspaceID else { return }
        navigation = WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: tabID
        )
    }

    var selectedTerminalSessionID: TerminalSessionID? {
        guard let selectedTabID = navigation.selectedTabID else { return nil }
        return desktopProjection.tabs.first { $0.id == selectedTabID }?.sessionID
    }

    var selectedWorkspaceID: WorkspaceID? {
        switch navigation.selection {
        case .workspace(let workspaceID):
            return workspaceID
        case .project(let projectID):
            return desktopProjection.firstWorkspace(in: projectID)?.id
        case nil:
            return nil
        }
    }

    func workspaceID(forTabID tabID: String) -> WorkspaceID? {
        desktopProjection.workspaceID(forTabID: tabID)
    }

}

extension WarrenNextApplicationModel {
    static func pendingShellTabID(for workspaceID: WorkspaceID) -> String {
        "pending-shell-\(workspaceID.description)"
    }
}

private extension WarrenDesktopAction {
    var requiresHostSideEffect: Bool {
        switch self {
        case .closeTab, .closeOtherTabs, .closeAllTabs, .renameWorkspace,
             .openSession, .deleteSession, .launchSession:
            true
        case .addProject, .importSuperset, .requestNewWorkspace,
             .requestNewSession, .selectProject,
             .selectWorkspace, .selectTab, .moveTab,
             .toggleInspector, .toggleSidebar:
            false
        }
    }

    var requiresClientLayoutSideEffect: Bool {
        switch self {
        case .selectProject, .selectWorkspace, .selectTab, .moveTab:
            true
        default:
            false
        }
    }
}
