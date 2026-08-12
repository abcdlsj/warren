import BurrowClientCore
import BurrowDomain
import BurrowHost
import BurrowProtocol
import BurrowStateStore
import Foundation

extension BurrowApplicationService {
    /// Creates a Host session, persists its opaque runtime descriptor, and
    /// exposes a disconnected tab projection. Attachment is a separate typed
    /// operation so callers can choose when the Client view connects.
    @discardableResult
    public func createSession(
        workspaceID: WorkspaceID,
        launchCommand: String? = nil,
        kind: TerminalSessionKind = .shell,
        title: String? = nil,
        isTabVisible: Bool = true
    ) async throws -> TerminalSession {
        do {
            let session = try await withPersistenceMutation {
                try requireReady()
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else {
                    throw BurrowApplicationError.workspaceNotFound(workspaceID)
                }
                let binding = try await coordinator.createSessionWithRuntimeDescriptor(
                    workspace: workspace,
                    size: TerminalSessionCoordinator.defaultTerminalSize
                )
                let resolvedTitle = title?.isEmpty == false
                    ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : (kind == .shell ? workspace.name : kind.displayName)
                let persisted = PersistedTerminalSession(
                    id: binding.session.id,
                    workspaceID: workspace.id,
                    epoch: binding.session.epoch,
                    sequence: binding.session.sequence,
                    workingDirectory: workspace.path,
                    terminalSize: TerminalSessionCoordinator.defaultTerminalSize,
                    runtimeAdoptionDescriptor: RuntimeDescriptorMapping.persisted(from: binding.descriptor),
                    kind: kind,
                    title: resolvedTitle,
                    isTabVisible: isTabVisible
                )
                if let launchCommand, !launchCommand.isEmpty {
                    let trimmed = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Give the freshly spawned shell a beat to reach its
                        // prompt; otherwise the first Enter can be swallowed by
                        // shell startup and the agent command stays unexecuted.
                        try await Task.sleep(for: .milliseconds(500))
                        try await runtime.write(
                            sessionID: binding.session.id,
                            data: Data((trimmed + "\r").utf8)
                        )
                    }
                }
                var candidate = state
                candidate.terminalSessions.removeAll { $0.id == persisted.id }
                candidate.terminalSessions.append(persisted)
                try await save(candidate)
                mergePendingSequences(into: &candidate)
                state = candidate
                insertConnection(
                    session: binding.session,
                    workspace: workspace,
                    descriptor: persisted.runtimeAdoptionDescriptor!,
                    title: resolvedTitle,
                    kind: kind,
                    isTabVisible: isTabVisible
                )
                return binding.session
            }
            await publish()
            return session
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "session.create.\(workspaceID)")
            await publish()
            throw appError
        }
    }

    /// Compatibility composition API for the desktop tab bar.
    @discardableResult
    public func addTab(
        workspaceID: WorkspaceID,
        launchCommand: String? = nil,
        kind: TerminalSessionKind = .shell,
        title: String? = nil
    ) async throws -> String {
        let session = try await createSession(
            workspaceID: workspaceID,
            launchCommand: launchCommand,
            kind: kind,
            title: title
        )
        let attachmentID = try await attach(sessionID: session.id)
        try await requestControl(sessionID: session.id, attachmentID: attachmentID)
        return tabID(for: session.id)
    }

    /// Starts and attaches a session from a typed client launch request.
    @discardableResult
    public func addTab(
        workspaceID: WorkspaceID,
        request: TerminalSessionLaunchRequest
    ) async throws -> String {
        try await addTab(
            workspaceID: workspaceID,
            launchCommand: request.command,
            kind: request.kind,
            title: request.title
        )
    }

    public func closeTab(tabID: String) async throws {
        guard let sessionID = connections.first(where: {
            $0.value.tabID == tabID && $0.value.isTabVisible
        })?.key else {
            throw BurrowApplicationError.tabNotFound(tabID)
        }
        if let attachmentID = connections[sessionID]?.attachmentID {
            try await detach(sessionID: sessionID, attachmentID: attachmentID, reason: "tab_closed")
        }
        guard var connection = connections[sessionID] else {
            throw BurrowApplicationError.sessionNotFound(sessionID)
        }
        connection.isTabVisible = false
        connections[sessionID] = connection
        try? await persistTabVisibility(sessionID: sessionID, isVisible: false)
        outputSnapshotCache.removeValue(forKey: sessionID)
        invalidatedOutputSessions.remove(sessionID)
        pendingOutputSessions.remove(sessionID)
        // This deliberately leaves PersistedTerminalSession and the runtime
        // alive. Closing a Client tab is never a kill operation.
        await publish()
    }

    /// Reopens a durable terminal session in the local tab strip.
    ///
    /// Closing a tab only detaches its renderer. The Host session and tmux
    /// runtime remain alive, so reopening reuses that session instead of
    /// creating a second shell for the same workspace.
    @discardableResult
    public func openSession(sessionID: TerminalSessionID) async throws -> String {
        try requireReady()
        await ensureSessionRestored(sessionID)
        guard var connection = connections[sessionID] else {
            throw BurrowApplicationError.sessionNotFound(sessionID)
        }
        connection.isTabVisible = true
        connections[sessionID] = connection
        try? await persistTabVisibility(sessionID: sessionID, isVisible: true)

        if connection.attachmentID == nil {
            let attachmentID = try await attach(sessionID: sessionID)
            try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
        } else {
            await publish()
        }
        return connection.tabID
    }

    /// Idempotent close used by event-driven shells.  A UI can receive a
    /// stale close action while a previous snapshot is being reconciled; that
    /// action should not turn into a visible error after the tab is already
    /// gone.  The strict `closeTab(tabID:)` API remains available for callers
    /// that need to diagnose a missing tab.
    public func closeTabIfPresent(tabID: String) async throws {
        guard connections.contains(where: {
            $0.value.tabID == tabID && $0.value.isTabVisible
        }) else {
            return
        }
        do {
            try await closeTab(tabID: tabID)
        } catch BurrowApplicationError.tabNotFound {
            // Another serialized close won the race between the lookup and
            // the detach confirmation.  The requested end state is already
            // true, so keep this operation idempotent.
        }
    }

    public func closeTabs(except tabID: String? = nil) async {
        let ids = connections.values.filter(\.isTabVisible).map(\.tabID).filter {
            tabID == nil || $0 != tabID
        }
        for id in ids { try? await closeTab(tabID: id) }
    }

    /// Closes only the Client tabs presented by one workspace. Other
    /// project/branch workspaces keep their open tabs and runtime ownership.
    public func closeTabs(in workspaceID: WorkspaceID, except tabID: String? = nil) async {
        let ids = connections.values.filter {
            $0.workspaceID == workspaceID && $0.isTabVisible
        }.map(\.tabID).filter {
            tabID == nil || $0 != tabID
        }
        for id in ids { try? await closeTab(tabID: id) }
    }

    internal func insertConnection(
        session: TerminalSession,
        workspace: Workspace,
        descriptor: RuntimeAdoptionDescriptor?,
        terminalSize: TerminalSize = TerminalSessionCoordinator.defaultTerminalSize,
        title: String? = nil,
        kind: TerminalSessionKind = .shell,
        isTabVisible: Bool = true
    ) {
        guard connections[session.id] == nil else { return }
        connections[session.id] = SessionConnection(
            session: session,
            workspaceID: workspace.id,
            tabID: tabID(for: session.id),
            isTabVisible: isTabVisible,
            terminalSize: terminalSize,
            descriptor: descriptor,
            store: ClientSessionStore(
                host: host,
                sessionID: session.id,
                clientID: clientID
            ),
            attachmentID: nil,
            title: title?.isEmpty == false ? title! : (workspace.name.isEmpty ? "Terminal" : workspace.name),
            kind: kind
        )
    }

    private func persistTabVisibility(
        sessionID: TerminalSessionID,
        isVisible: Bool
    ) async throws {
        try await withPersistenceMutation {
            guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else {
                return
            }
            var candidate = state
            candidate.terminalSessions[index].isTabVisible = isVisible
            try await save(candidate)
            state = candidate
        }
    }

    internal func tabID(for sessionID: TerminalSessionID) -> String {
        "session-\(sessionID.description)"
    }
}
