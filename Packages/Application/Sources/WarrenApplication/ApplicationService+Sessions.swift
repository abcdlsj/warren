import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenProtocol
import WarrenStateStore
import Foundation

extension WarrenApplicationService {
    /// Creates a Host-owned Session. Client Tab creation is a separate layout
    /// mutation performed by `addTab`, never a field on the Session record.
    @discardableResult
    public func createSession(
        workspaceID: WorkspaceID,
        launchCommand: String? = nil,
        kind: TerminalSessionKind = .shell,
        title: String? = nil,
        requestID: UUID? = nil
    ) async throws -> TerminalSession {
        do {
            let session = try await withPersistenceMutation {
                try requireReady()
                if let requestID,
                   let receipt = state.requestReceipts.first(where: {
                       $0.requestID == requestID && $0.commandKind == "create_session"
                   }), let sessionID = TerminalSessionID(uuidString: receipt.resourceID),
                   let persisted = state.terminalSessions.first(where: { $0.id == sessionID }) {
                    return persisted.terminalSession
                }
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else {
                    throw WarrenApplicationError.workspaceNotFound(workspaceID)
                }
                let binding = try await coordinator.createSessionWithRuntimeDescriptor(
                    workspace: workspace,
                    size: TerminalSessionCoordinator.defaultTerminalSize,
                    launchSpec: TerminalRuntimeLaunchSpec(command: launchCommand)
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
                    title: resolvedTitle
                )
                var candidate = state
                candidate.terminalSessions.removeAll { $0.id == persisted.id }
                candidate.terminalSessions.append(persisted)
                if let requestID {
                    candidate.requestReceipts.append(PersistedRequestReceipt(
                        requestID: requestID,
                        commandKind: "create_session",
                        resourceID: persisted.id.description,
                        completedAt: clock()
                    ))
                }
                do {
                    try await save(candidate)
                } catch {
                    try? await runtime.terminate(sessionID: binding.session.id)
                    throw error
                }
                mergePendingSequences(into: &candidate)
                state = candidate
                insertConnection(
                    session: binding.session,
                    workspace: workspace,
                    descriptor: persisted.runtimeAdoptionDescriptor!,
                    title: resolvedTitle,
                    kind: kind
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
        let tabID = tabID(for: session.id)
        let resolvedTitle = state.terminalSessions.first(where: { $0.id == session.id })?.title
            ?? kind.displayName
        try await layoutStore.upsertTab(
            ClientTab(id: tabID, title: resolvedTitle, sessionID: session.id, kind: kind),
            workspaceID: workspaceID,
            select: true,
            in: windowID
        )
        let attachmentID = try await attach(sessionID: session.id)
        try await requestControl(sessionID: session.id, attachmentID: attachmentID)
        await publish()
        return tabID
    }

    @discardableResult
    public func createSession(
        workspaceID: WorkspaceID,
        request: TerminalSessionLaunchRequest
    ) async throws -> TerminalSession {
        let identified = request.identified()
        return try await createSession(
            workspaceID: workspaceID,
            launchCommand: identified.command,
            kind: identified.kind,
            title: identified.title,
            requestID: identified.requestID
        )
    }

    @discardableResult
    public func addTab(
        workspaceID: WorkspaceID,
        request: TerminalSessionLaunchRequest
    ) async throws -> String {
        let identified = request.identified()
        let session = try await createSession(workspaceID: workspaceID, request: identified)
        let tabID = tabID(for: session.id)
        let resolvedTitle = state.terminalSessions.first(where: { $0.id == session.id })?.title
            ?? identified.kind.displayName
        try await layoutStore.upsertTab(
            ClientTab(
                id: tabID,
                title: resolvedTitle,
                sessionID: session.id,
                kind: identified.kind
            ),
            workspaceID: workspaceID,
            select: true,
            in: windowID
        )
        if connections[session.id]?.attachmentID == nil {
            let attachmentID = try await attach(sessionID: session.id)
            try await requestControl(sessionID: session.id, attachmentID: attachmentID)
        }
        await publish()
        return tabID
    }

    /// Ensures an empty Workspace View has one interactive shell Tab.
    ///
    /// Repeated selections share the same in-flight operation. Existing Tabs
    /// are never replaced, and durable Sessions without an open Tab are not
    /// implicitly revived.
    @discardableResult
    public func ensureDefaultShellTab(workspaceID: WorkspaceID) async throws -> String {
        try requireReady()
        guard state.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw WarrenApplicationError.workspaceNotFound(workspaceID)
        }
        if let existing = await layoutStore.window(id: windowID)
            .workspaceView(for: workspaceID)?.tabs.first {
            return existing.id
        }
        if let task = defaultTabTasks[workspaceID] {
            return try await task.value
        }

        let request = TerminalSessionLaunchRequest.shell.identified()
        let task = Task<String, Error> { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.addTab(workspaceID: workspaceID, request: request)
        }
        defaultTabTasks[workspaceID] = task
        do {
            let tabID = try await task.value
            defaultTabTasks.removeValue(forKey: workspaceID)
            return tabID
        } catch {
            defaultTabTasks.removeValue(forKey: workspaceID)
            throw error
        }
    }

    public func selectWorkspace(_ workspaceID: WorkspaceID) async throws {
        try requireReady()
        guard state.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw WarrenApplicationError.workspaceNotFound(workspaceID)
        }
        try await layoutStore.selectWorkspace(workspaceID, in: windowID)
        let tabs = await layoutStore.window(id: windowID).workspaceView(for: workspaceID)?.tabs ?? []
        for sessionID in tabs.compactMap(\.sessionID) {
            await ensureSessionRestored(sessionID)
        }
        await publish()
    }

    public func selectTab(tabID: String, workspaceID: WorkspaceID) async throws {
        try await layoutStore.selectTab(tabID, workspaceID: workspaceID, in: windowID)
        if let sessionID = await layoutStore.window(id: windowID)
            .workspaceView(for: workspaceID)?.tabs.first(where: { $0.id == tabID })?.sessionID {
            await ensureSessionRestored(sessionID)
            if let connection = connections[sessionID], connection.attachmentID == nil {
                let attachmentID = try await attach(sessionID: sessionID)
                try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
            }
        }
        await publish()
    }

    public func closeTab(tabID: String, workspaceID: WorkspaceID) async throws {
        guard let sessionID = try await layoutStore.removeTab(
            id: tabID,
            workspaceID: workspaceID,
            in: windowID
        ) else {
            throw WarrenApplicationError.tabNotFound(tabID)
        }
        if let attachmentID = connections[sessionID]?.attachmentID {
            try await detach(sessionID: sessionID, attachmentID: attachmentID, reason: "tab_closed")
        }
        clearClientCaches(for: sessionID)
        await publish()
    }

    public func closeTabIfPresent(tabID: String, workspaceID: WorkspaceID) async throws {
        do {
            try await closeTab(tabID: tabID, workspaceID: workspaceID)
        } catch WarrenApplicationError.tabNotFound {
            return
        }
    }

    public func closeTabs(in workspaceID: WorkspaceID, except tabID: String? = nil) async {
        guard let removed = try? await layoutStore.removeTabs(
            workspaceID: workspaceID,
            except: tabID,
            in: windowID
        ) else { return }
        for sessionID in removed {
            if let attachmentID = connections[sessionID]?.attachmentID {
                try? await detach(sessionID: sessionID, attachmentID: attachmentID, reason: "tab_closed")
            }
            clearClientCaches(for: sessionID)
        }
        await publish()
    }

    @discardableResult
    public func openSession(sessionID: TerminalSessionID) async throws -> String {
        try requireReady()
        guard let persisted = state.terminalSessions.first(where: { $0.id == sessionID }) else {
            throw WarrenApplicationError.sessionNotFound(sessionID)
        }
        await ensureSessionRestored(sessionID)
        guard let connection = connections[sessionID] else {
            throw WarrenApplicationError.sessionNotFound(sessionID)
        }
        try await layoutStore.upsertTab(
            ClientTab(
                id: connection.tabID,
                title: connection.title,
                sessionID: sessionID,
                kind: connection.kind
            ),
            workspaceID: persisted.workspaceID,
            select: true,
            in: windowID
        )
        if connection.attachmentID == nil {
            let attachmentID = try await attach(sessionID: sessionID)
            try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
        }
        await publish()
        return connection.tabID
    }

    internal func insertConnection(
        session: TerminalSession,
        workspace: Workspace,
        descriptor: RuntimeAdoptionDescriptor?,
        terminalSize: TerminalSize = TerminalSessionCoordinator.defaultTerminalSize,
        title: String? = nil,
        kind: TerminalSessionKind = .shell
    ) {
        guard connections[session.id] == nil else { return }
        connections[session.id] = SessionConnection(
            session: session,
            workspaceID: workspace.id,
            tabID: tabID(for: session.id),
            terminalSize: terminalSize,
            descriptor: descriptor,
            store: ClientSessionStore(host: host, sessionID: session.id, clientID: clientID),
            attachmentID: nil,
            title: title?.isEmpty == false ? title! : (workspace.name.isEmpty ? "Terminal" : workspace.name),
            kind: kind,
            runtimeEnded: false
        )
    }

    internal func tabID(for sessionID: TerminalSessionID) -> String {
        "session-\(sessionID.description)"
    }

    private func clearClientCaches(for sessionID: TerminalSessionID) {
        outputSnapshotCache.removeValue(forKey: sessionID)
        invalidatedOutputSessions.remove(sessionID)
        pendingOutputSessions.remove(sessionID)
    }
}
