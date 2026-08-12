import Foundation
import AppKit
import Observation
import BurrowApplication
import BurrowClientCore
import BurrowDesktop
import BurrowDomain
import GhosttyAdapter
import BurrowProtocol
import BurrowStateStore
import BurrowTmuxRuntime

@MainActor
@Observable
final class BurrowNextApplicationModel {
    private(set) var snapshot: BurrowApplicationSnapshot
    private(set) var desktopProjection: BurrowDesktopProjection
    private(set) var navigation: BurrowDesktopNavigationState
    private(set) var presentedIssue: BurrowApplicationIssue?

    @ObservationIgnored private let service: BurrowApplicationService
    @ObservationIgnored private let runtime: TmuxRuntime
    @ObservationIgnored private let renderer: BurrowRendererCoordinator
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    /// Host mutations are ordered per Workspace. A slow agent launch in one
    /// project must never block navigation or operations in another project.
    @ObservationIgnored private var workspaceActionTasks: [WorkspaceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var acceptingActions = true
    @ObservationIgnored private var shutdownStarted = false
    @ObservationIgnored private var shutdownFinished = false

    init(service: BurrowApplicationService, runtime: TmuxRuntime) {
        self.service = service
        self.runtime = runtime
        self.renderer = BurrowRendererCoordinator(service: service)
        let initialSnapshot = BurrowApplicationSnapshot.empty()
        let initialProjection = BurrowDesktopProjection.empty(host: initialSnapshot.host)
        self.snapshot = initialSnapshot
        self.desktopProjection = initialProjection
        self.navigation = BurrowDesktopNavigationReducer.initial(for: initialProjection)
    }

    static func live() -> BurrowNextApplicationModel {
        let tmuxSocketName = ProcessInfo.processInfo.environment["BURROW_TMUX_SOCKET_NAME"]
        let runtime = TmuxRuntime(
            executor: ProcessTmuxCommandExecutor(socketName: tmuxSocketName),
            outputDirectory: BurrowApplicationDefaults.runtimeOutputDirectory()
        )
        let repository: SQLiteHostStateRepository
        do {
            repository = try SQLiteHostStateRepository(
                databaseURL: BurrowApplicationDefaults.stateDatabaseURL()
            )
        } catch {
            fatalError("Could not open Burrow state database: \(error)")
        }
        let service = BurrowApplicationService(
            repository: repository,
            runtime: runtime,
            hostName: Host.current().localizedName ?? "Local Mac"
        )
        return BurrowNextApplicationModel(service: service, runtime: runtime)
    }

    private func makeDesktopProjection() -> BurrowDesktopProjection {
        let issue = presentedIssue
        let inspector = issue.map {
            BurrowDesktopInspectorContent(
                id: $0.id,
                title: $0.title,
                detail: "\($0.detail)\n\n\($0.recoverySuggestion)"
            )
        }
        let tabs = snapshot.windowLayout.workspaceViews.flatMap(\.tabs)
        let visibleSessionIDs = Set(tabs.compactMap(\.sessionID))
        let visibleSessions = snapshot.sessions.filter {
            visibleSessionIDs.contains($0.id)
        }
        let workspaceIDs = Dictionary(
            uniqueKeysWithValues: visibleSessions.map { ($0.id, $0.workspaceID) }
        )
        return BurrowDesktopProjection(
            host: snapshot.host,
            projects: snapshot.projects,
            workspaces: snapshot.workspaces,
            sessions: visibleSessions.map { session in
                BurrowDesktopSession(
                    id: session.id,
                    workspaceID: session.workspaceID,
                    tabID: session.tabID,
                    title: session.title,
                    kind: session.kind,
                    state: Self.desktopSessionState(for: session.connectionState)
                )
            },
            tabs: tabs,
            sessionWorkspaceIDs: workspaceIDs,
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
    }

    func shutdown() async {
        beginShutdown()
        guard !shutdownFinished else { return }
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
            throw BurrowApplicationError.unsupportedAction(
                "Headless lifecycle probe could not resolve the created session."
            )
        }
        return sessionID
    }

    func runtimeExists(sessionID: TerminalSessionID) async -> Bool {
        await runtime.exists(sessionID: sessionID)
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
                navigation = BurrowDesktopNavigationState(
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

    func perform(_ action: BurrowDesktopAction) {
        guard acceptingActions else { return }
        navigation = BurrowDesktopNavigationReducer.reduce(
            navigation,
            action: action,
            in: desktopProjection
        )

        switch action {
        case .selectProject, .selectWorkspace, .selectTab, .openSession:
            reconcileSurfaces(with: snapshot)
        case .addProject, .importSuperset, .requestNewWorkspace,
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

    func workspaceID(for action: BurrowDesktopAction) -> WorkspaceID? {
        switch action {
        case .launchSession(let workspaceID, _),
             .requestNewSession(let workspaceID),
             .selectWorkspace(let workspaceID):
            return workspaceID
        case .openSession(let sessionID):
            return desktopProjection.sessions.first { $0.id == sessionID }?.workspaceID
        case .closeTab(let tabID), .closeOtherTabs(let tabID):
            return workspaceID(forTabID: tabID)
        case .closeAllTabs:
            return selectedWorkspaceID
        case .addProject, .importSuperset, .requestNewWorkspace,
             .selectProject, .selectTab,
             .toggleInspector, .toggleSidebar:
            return nil
        }
    }

}

private extension BurrowNextApplicationModel {
    func ensureDefaultShellTab(in workspaceID: WorkspaceID) async {
        do {
            let tabID = try await service.ensureDefaultShellTab(workspaceID: workspaceID)
            selectCreatedTab(tabID, workspaceID: workspaceID)
        } catch {
            present(error)
        }
    }

    func performSerial(_ action: BurrowDesktopAction) async {
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
        case .addProject, .importSuperset, .requestNewWorkspace,
             .selectProject, .selectWorkspace, .selectTab,
             .toggleInspector, .toggleSidebar:
            break
        }
    }

    func performClientLayout(_ action: BurrowDesktopAction) async {
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
            default:
                return
            }
        } catch {
            present(error)
        }
    }

    var desktopConnectionState: BurrowDesktopConnectionState {
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
        for state: BurrowApplicationConnectionState
    ) -> BurrowDesktopSessionState {
        switch state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .attached: .attached
        case .reconnecting: .reconnecting
        case .exited: .exited
        case .failed: .failed
        }
    }

    func apply(_ value: BurrowApplicationSnapshot) async {
        snapshot = value
        if presentedIssue == nil {
            presentedIssue = value.issues.last
        }
        refreshDesktopProjection()
        navigation = BurrowDesktopNavigationReducer.reconcile(
            navigation,
            with: desktopProjection
        )
        reconcileSurfaces(with: value)
    }

    func reconcileSurfaces(with value: BurrowApplicationSnapshot) {
        renderer.reconcile(
            snapshot: value,
            activeWorkspaceID: selectedWorkspaceID,
            activeSessionID: selectedTerminalSessionID,
            reportError: { [weak self] error in self?.present(error) }
        )
    }

    func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            present(error)
        }
    }

    func present(_ error: Error) {
        presentedIssue = BurrowApplicationIssue(id: "ui.\(String(describing: error))", error: error)
        refreshDesktopProjection()
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
        navigation = BurrowDesktopNavigationState(
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
        guard let sessionID = desktopProjection.tabs.first(where: { $0.id == tabID })?.sessionID else {
            return nil
        }
        return desktopProjection.sessionWorkspaceIDs[sessionID]
    }

}

private extension BurrowDesktopAction {
    var requiresHostSideEffect: Bool {
        switch self {
        case .closeTab, .closeOtherTabs, .closeAllTabs,
             .openSession, .launchSession:
            true
        case .addProject, .importSuperset, .requestNewWorkspace,
             .requestNewSession, .selectProject,
             .selectWorkspace, .selectTab, .toggleInspector, .toggleSidebar:
            false
        }
    }

    var requiresClientLayoutSideEffect: Bool {
        switch self {
        case .selectProject, .selectWorkspace, .selectTab:
            true
        default:
            false
        }
    }
}
