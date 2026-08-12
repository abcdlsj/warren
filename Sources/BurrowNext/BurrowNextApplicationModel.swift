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
import WebRelay

@MainActor
@Observable
final class BurrowNextApplicationModel {
    private(set) var snapshot: BurrowApplicationSnapshot
    private(set) var desktopProjection: BurrowDesktopProjection
    private(set) var navigation: BurrowDesktopNavigationState
    private(set) var mountedSurfaces: [GhosttySurface] = []
    private(set) var presentedIssue: BurrowApplicationIssue?

    @ObservationIgnored private let service: BurrowApplicationService
    @ObservationIgnored private let runtime: TmuxRuntime
    @ObservationIgnored private var webRelay: WebRelayServer?
    @ObservationIgnored private var webCommandObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResizeSizes: [TerminalSessionID: TerminalSize] = [:]
    @ObservationIgnored private var appliedResizeSizes: [TerminalSessionID: TerminalSize] = [:]
    @ObservationIgnored private var resizeTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var surfaces: [TerminalSessionID: GhosttySurface] = [:]
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
        let initialSnapshot = BurrowApplicationSnapshot.empty()
        let initialProjection = BurrowDesktopProjection.empty(host: initialSnapshot.host)
        self.snapshot = initialSnapshot
        self.desktopProjection = initialProjection
        self.navigation = BurrowDesktopNavigationReducer.initial(for: initialProjection)
    }

    static func live() -> BurrowNextApplicationModel {
        let runtime = TmuxRuntime()
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
        let visibleSessionIDs = Set(snapshot.tabs.compactMap(\.sessionID))
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
            tabs: snapshot.tabs,
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
            startWebRelay()
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
        stopWebRelay()
        surfaces.removeAll()
        mountedSurfaces.removeAll()
        for task in resizeTasks.values {
            task.cancel()
        }
        resizeTasks.removeAll()
        pendingResizeSizes.removeAll()
        appliedResizeSizes.removeAll()
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
                    request: request
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
        case .addProject, .requestNewSession, .launchSession,
             .closeTab, .closeOtherTabs, .closeAllTabs,
             .toggleInspector, .toggleSidebar:
            break
        }

        guard action.requiresHostSideEffect else { return }
        guard let workspaceID = workspaceID(for: action) else { return }
        enqueueWorkspaceAction(workspaceID: workspaceID) { [weak self] in
            await self?.performSerial(action)
        }
    }

    func dismissIssue() {
        presentedIssue = nil
        refreshDesktopProjection()
    }

    func report(_ error: Error) {
        present(error)
    }

    func startWebRelay() {
        guard webRelay == nil else { return }
        let relay = WebRelayServer(service: service)
        relay.start()
        webRelay = relay
        if ProcessInfo.processInfo.environment["BURROW_START_TUNNEL"] == "1" {
            relay.startTunnel()
        }
        if ProcessInfo.processInfo.environment["BURROW_START_TAILSCALE"] == "1" {
            Task { await relay.startTailscale() }
        }
        if ProcessInfo.processInfo.environment["BURROW_START_FUNNEL"] == "1" {
            Task { await relay.startFunnel() }
        }
        let center = NotificationCenter.default
        webCommandObservers = [
            center.addObserver(
                forName: WebRelayServer.startTunnel,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.webRelay?.startTunnel() }
            },
            center.addObserver(
                forName: WebRelayServer.stopTunnel,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.webRelay?.stopTunnel() }
            },
            center.addObserver(
                forName: WebRelayServer.copyWebURL,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.copyWebURL() }
            },
            center.addObserver(
                forName: WebRelayServer.startTailscale,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.webRelay?.startTailscale() }
            },
            center.addObserver(
                forName: WebRelayServer.stopTailscale,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.webRelay?.stopTailscale() }
            },
            center.addObserver(
                forName: WebRelayServer.startFunnel,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.webRelay?.startFunnel() }
            },
            center.addObserver(
                forName: WebRelayServer.stopFunnel,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.webRelay?.stopFunnel() }
            },
        ]
    }

    func stopWebRelay() {
        for observer in webCommandObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        webCommandObservers.removeAll()
        webRelay?.stop()
        webRelay = nil
    }

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
        case .addProject, .selectProject, .selectTab,
             .toggleInspector, .toggleSidebar:
            return nil
        }
    }

    private func copyWebURL() {
        guard let relay = webRelay else { return }
        let url: URL?
        if let host = relay.tunnelURL?.host
            ?? relay.tailscaleURL?.host
            ?? relay.funnelURL?.host {
            url = WebRelayServer.webPageDataURL(host: host)
        } else {
            url = WebRelayServer.webPageURL(host: nil)
        }
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

private extension BurrowNextApplicationModel {
    func performSerial(_ action: BurrowDesktopAction) async {
        switch action {
        case .requestNewSession:
            break
        case .closeTab(let tabID):
            // Close actions are generated from a value snapshot.  Treat a
            // stale action as a successful no-op so a rapid double-click does
            // not surface an error inspector.
            await run { try await service.closeTabIfPresent(tabID: tabID) }
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
                let tabID = try await service.addTab(workspaceID: workspaceID, request: request)
                selectCreatedTab(tabID, workspaceID: workspaceID)
            } catch {
                present(error)
            }
        case .addProject, .selectProject, .selectWorkspace, .selectTab,
             .toggleInspector, .toggleSidebar:
            break
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
        let visibleTabIDs = selectedWorkspaceID.map {
            Set(value.tabs(in: $0).map(\.id))
        } ?? []
        let renderedSessionIDs = Set(value.sessions.lazy.filter {
            visibleTabIDs.contains($0.tabID)
        }.map(\.id))
        for sessionID in surfaces.keys where !renderedSessionIDs.contains(sessionID) {
            disposeSurface(for: sessionID)
        }

        for session in value.sessions {
            // Only the selected workspace mounts renderers. Open tabs in
            // other project/branch workspaces stay Host-owned and cheap until
            // navigation selects their workspace again.
            guard visibleTabIDs.contains(session.tabID) else {
                if surfaces[session.id] != nil { disposeSurface(for: session.id) }
                continue
            }
            guard let attachmentID = session.attachmentID,
                  session.connectionState != .disconnected,
                  session.connectionState != .failed,
                  session.connectionState != .exited else {
                if surfaces[session.id] != nil { disposeSurface(for: session.id) }
                continue
            }
            if let current = surfaces[session.id], current.attachmentID != attachmentID {
                disposeSurface(for: session.id)
            }
            if surfaces[session.id] == nil {
                createSurface(for: session, attachmentID: attachmentID)
            }
            renderAvailableOutput(for: session)
        }
        refreshMountedSurfaces()
    }

    func createSurface(
        for session: BurrowApplicationSession,
        attachmentID: TerminalAttachmentID
    ) {
        let workspacePath = snapshot.workspace(id: session.workspaceID)?.path ?? ""
        let surface = GhosttySurface(
            id: session.id,
            attachmentID: attachmentID,
            workingDirectory: workspacePath,
            onInput: { [weak self] data in
                Task { @MainActor in
                    await self?.handleGhosttyInput(sessionID: session.id, data: data)
                }
            },
            onResize: { [weak self] columns, rows in
                Task { @MainActor in
                    await self?.handleGhosttyResize(
                        sessionID: session.id,
                        columns: columns,
                        rows: rows
                    )
                }
            }
        )
        surfaces[session.id] = surface
    }

    func renderAvailableOutput(for session: BurrowApplicationSession) {
        guard let surface = surfaces[session.id],
              let output = session.output,
              !output.frames.isEmpty else { return }
        var epoch = surface.renderedEpoch
        var sequence = surface.renderedSequence

        // Output snapshots retain a bounded ring, so the same old frames are
        // present in every publication.  Once the renderer caught up to the
        // ring's upper cursor there is nothing to scan or render again.
        guard epoch != output.epoch || output.upperSequence > sequence else {
            return
        }

        let firstPendingIndex: Int
        if epoch == output.epoch {
            firstPendingIndex = output.frames.firstIndex { frame in
                frame.header.sequence + UInt64(frame.payload.count) > sequence
            } ?? output.frames.count
        } else {
            firstPendingIndex = 0
        }
        guard firstPendingIndex < output.frames.count else { return }

        for frame in output.frames[firstPendingIndex...] {
            let frameEnd = frame.header.sequence + UInt64(frame.payload.count)
            guard frame.header.epoch == output.epoch, frameEnd > sequence else { continue }
            let offset = frame.header.sequence < sequence
                ? Int(sequence - frame.header.sequence)
                : 0
            let payload = offset == 0
                ? frame.payload
                : Data(frame.payload.dropFirst(offset))
            surface.receive(payload)
            sequence += UInt64(payload.count)
            epoch = frame.header.epoch
            surface.markRendered(epoch: epoch, sequence: sequence)
        }
    }

    func disposeSurface(for sessionID: TerminalSessionID) {
        surfaces.removeValue(forKey: sessionID)
        resizeTasks.removeValue(forKey: sessionID)?.cancel()
        pendingResizeSizes.removeValue(forKey: sessionID)
        appliedResizeSizes.removeValue(forKey: sessionID)
    }

    func refreshMountedSurfaces() {
        guard let workspaceID = selectedWorkspaceID else {
            mountedSurfaces = []
            return
        }
        let next = snapshot.tabs(in: workspaceID).compactMap { tab in
            tab.sessionID.flatMap { surfaces[$0] }
        }
        guard next.map(\.id) != mountedSurfaces.map(\.id)
                || zip(next, mountedSurfaces).contains(where: { $0 !== $1 }) else {
            return
        }
        mountedSurfaces = next
    }

    func handleGhosttyInput(sessionID: TerminalSessionID, data: Data) async {
        guard let session = snapshot.session(id: sessionID),
              let attachmentID = session.attachmentID else { return }
        do {
            try await service.sendInput(
                sessionID: sessionID,
                attachmentID: attachmentID,
                data: data
            )
        } catch {
            // A single input failure is recoverable and must not replace the
            // terminal with an Inspector. Runtime/session lifecycle failures
            // still arrive through snapshots and remain visible there.
            NSLog("Burrow terminal input failed for %@: %@", sessionID.description, String(describing: error))
        }
    }

    func handleGhosttyResize(
        sessionID: TerminalSessionID,
        columns: Int,
        rows: Int
    ) async {
        guard let size = TerminalSize(columns: columns, rows: rows),
              snapshot.session(id: sessionID)?.attachmentID != nil else { return }
        // Hidden Ghostty siblings remain mounted to preserve scrollback and
        // renderer state, but their intrinsic startup grid (often 50x17) must
        // never resize a background tmux pane. The selected tab is the sole
        // viewport owner; activation asks Ghostty to re-fit that surface.
        guard selectedTerminalSessionID == sessionID else { return }
        guard pendingResizeSizes[sessionID] != size,
              appliedResizeSizes[sessionID] != size else { return }

        // AppKit/Ghostty can report a startup grid (commonly 50x17) and the
        // fitted grid in adjacent callbacks. A Task per callback lets actor
        // reentrancy reorder the two Host requests, so the stale small resize
        // can win last. Keep one worker per Session and overwrite its pending
        // value: the worker serializes transport calls and always drains the
        // newest geometry before it exits.
        pendingResizeSizes[sessionID] = size
        guard resizeTasks[sessionID] == nil else { return }
        resizeTasks[sessionID] = Task { @MainActor [weak self] in
            await self?.drainGhosttyResizes(for: sessionID)
        }
    }

    func drainGhosttyResizes(for sessionID: TerminalSessionID) async {
        defer { resizeTasks.removeValue(forKey: sessionID) }

        while !Task.isCancelled {
            guard selectedTerminalSessionID == sessionID,
                  let size = pendingResizeSizes[sessionID],
                  let session = snapshot.session(id: sessionID),
                  let attachmentID = session.attachmentID else {
                pendingResizeSizes.removeValue(forKey: sessionID)
                return
            }

            do {
                try await service.resize(
                    sessionID: sessionID,
                    attachmentID: attachmentID,
                    size: size
                )
                appliedResizeSizes[sessionID] = size
            } catch {
                pendingResizeSizes.removeValue(forKey: sessionID)
                present(error)
                return
            }

            if pendingResizeSizes[sessionID] == size {
                pendingResizeSizes.removeValue(forKey: sessionID)
            }
        }
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
        case .addProject, .requestNewSession, .selectProject,
             .selectWorkspace, .selectTab, .toggleInspector, .toggleSidebar:
            false
        }
    }
}
