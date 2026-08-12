import BurrowDomain
import BurrowHost
import BurrowStateStore

extension BurrowApplicationService {
    internal func restorePersistedSessions() async {
        let openSessionIDs = Set(
            await layoutStore.window(id: windowID).workspaceViews
                .flatMap(\.tabs)
                .compactMap(\.sessionID)
        )
        for persisted in state.terminalSessions where openSessionIDs.contains(persisted.id) {
            await restore(persisted, attachClient: true)
        }
    }

    internal func ensureSessionRestored(_ sessionID: TerminalSessionID) async {
        guard connections[sessionID] == nil else { return }
        if let task = restorationTasks[sessionID] {
            await task.value
            return
        }
        guard let persisted = state.terminalSessions.first(where: { $0.id == sessionID }) else {
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.restore(persisted, attachClient: false)
        }
        restorationTasks[sessionID] = task
        await task.value
        restorationTasks.removeValue(forKey: sessionID)
    }

    private func restore(
        _ persisted: PersistedTerminalSession,
        attachClient: Bool
    ) async {
        var persisted = persisted
        guard let workspace = state.workspaces.first(where: { $0.id == persisted.workspaceID }) else {
            appendIssue(
                BurrowApplicationIssue(
                    id: "session.\(persisted.id).workspace",
                    title: "Terminal session is missing a workspace",
                    detail: "Session \(persisted.id) references a missing Workspace.",
                    recoverySuggestion: "Fix the Workspace in the state file, then reopen Burrow."
                )
            )
            return
        }
        if !(await runtime.exists(sessionID: persisted.id)) {
            // The tmux server (or this session's tmux pane) may be gone after
            // a reboot or a manual tmux kill. Do not leave the UI parked on
            // "Connecting": recreate a fresh runtime in the same workspace and
            // continue adoption. The old spool is intentionally not replayed;
            // a brand-new shell is more useful than a dead session reference.
            do {
                let descriptor = try await runtime.create(
                    sessionID: persisted.id,
                    workingDirectory: persisted.workingDirectory,
                    size: persisted.terminalSize
                )
                var candidate = state
                if let index = candidate.terminalSessions.firstIndex(where: {
                    $0.id == persisted.id
                }) {
                    candidate.terminalSessions[index].runtimeAdoptionDescriptor =
                        RuntimeDescriptorMapping.persisted(from: descriptor)
                }
                try await save(candidate)
                state = candidate
                persisted.runtimeAdoptionDescriptor =
                    RuntimeDescriptorMapping.persisted(from: descriptor)
            } catch {
                report(
                    .runtime("Runtime for Session \(persisted.id) could not be recreated: \(error)"),
                    id: "session.\(persisted.id).runtime"
                )
                insertConnection(
                    session: persisted.terminalSession,
                    workspace: workspace,
                    descriptor: persisted.runtimeAdoptionDescriptor,
                    terminalSize: persisted.terminalSize,
                    title: persisted.title,
                    kind: persisted.kind
                )
                return
            }
        }
        guard let persistedDescriptor = persisted.runtimeAdoptionDescriptor else {
            appendIssue(
                BurrowApplicationIssue(
                    id: "session.\(persisted.id).descriptor",
                    title: "Terminal session could not be restored",
                    detail: "Session has no descriptor for reconnecting to the local runtime.",
                    recoverySuggestion: "Create a new terminal tab; the old record is retained for diagnostics."
                )
            )
            insertConnection(
                session: persisted.terminalSession,
                workspace: workspace,
                descriptor: nil,
                terminalSize: persisted.terminalSize,
                title: persisted.title,
                kind: persisted.kind
            )
            return
        }

        do {
            let restoredSession = try await beginRestoredEpoch(for: persisted)
            insertConnection(
                session: restoredSession,
                workspace: workspace,
                descriptor: persistedDescriptor,
                terminalSize: persisted.terminalSize,
                title: persisted.title,
                kind: persisted.kind
            )
            _ = try await coordinator.adoptSession(
                restoredSession,
                descriptor: RuntimeDescriptorMapping.runtime(from: persistedDescriptor),
                size: persisted.terminalSize
            )
            if attachClient {
                do {
                    _ = try await attachInternal(
                        sessionID: persisted.id,
                        recoveryAnchor: RecoveryAnchor(epoch: restoredSession.epoch, sequence: 0),
                        requireReady: false
                    )
                } catch {
                    report(error.asApplicationError, id: "session.\(persisted.id).attach")
                }
            }
        } catch {
            report(
                .runtime(String(describing: error)),
                id: "session.\(persisted.id).adopt"
            )
        }
    }

    /// A new renderer cannot reuse the previous emulator state. Starting a
    /// fresh epoch at byte zero makes the runtime replay its durable spool so
    /// SwiftTerm can reconstruct the terminal screen after an App restart.
    private func beginRestoredEpoch(
        for persisted: PersistedTerminalSession
    ) async throws -> TerminalSession {
        let (epoch, overflowed) = persisted.epoch.addingReportingOverflow(1)
        guard !overflowed else {
            throw BurrowApplicationError.runtime("Recovery epoch exhausted for Session \(persisted.id).")
        }
        invalidateOutputSnapshot(for: persisted.id)
        let session = TerminalSession(
            id: persisted.id,
            workspaceID: persisted.workspaceID,
            epoch: epoch,
            sequence: 0
        )
        guard let index = state.terminalSessions.firstIndex(where: { $0.id == persisted.id }) else {
            throw BurrowApplicationError.sessionNotFound(persisted.id)
        }
        var candidate = state
        candidate.terminalSessions[index].epoch = epoch
        candidate.terminalSessions[index].sequence = 0
        try await save(candidate)
        mergePendingSequences(into: &candidate)
        state = candidate
        return session
    }
}
