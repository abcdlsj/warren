import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenStateStore
import Foundation

private enum WarrenApplicationPerformance {
    /// One display-sized burst is enough to absorb PTY frame bursts without
    /// adding visible terminal latency.
    static let outputPublicationDelay: UInt64 = 16_000_000
    /// The durable cursor is only needed for later runtime adoption.  Keeping
    /// this write off the PTY event path prevents JSON I/O from backpressuring
    /// terminal rendering.
    static let sequencePersistenceDelay: UInt64 = 250_000_000
}

extension WarrenApplicationService {
    internal func withPersistenceMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await persistenceGate.acquire()
        do {
            let value = try await operation()
            await persistenceGate.release()
            return value
        } catch {
            await persistenceGate.release()
            throw error
        }
    }

    internal func save(_ candidate: PersistedHostState) async throws {
        do {
            try await repository.save(candidate)
        } catch {
            throw WarrenApplicationError.repository(String(describing: error))
        }
    }

    /// Queues a monotonic Host cursor for a coalesced durable write. The
    /// in-memory cursor advances immediately, while a failed write remains
    /// retryable and adoption can safely replay the older durable spool tail.
    internal func persistSequence(
        sessionID: TerminalSessionID,
        anchor: RecoveryAnchor
    ) async throws {
        queueSequencePersistence(sessionID: sessionID, anchor: anchor)
    }

    /// Advances the in-memory cursor and schedules one delayed save for a
    /// burst of output frames. Sequence writes are monotonic per session.
    internal func queueSequencePersistence(
        sessionID: TerminalSessionID,
        anchor: RecoveryAnchor
    ) {
        guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let current = state.terminalSessions[index]
        guard anchor.epoch > current.epoch ||
            (anchor.epoch == current.epoch && anchor.sequence > current.sequence)
        else { return }

        state.terminalSessions[index].epoch = anchor.epoch
        state.terminalSessions[index].sequence = anchor.sequence

        if let pending = pendingSequenceAnchors[sessionID],
           isAnchorAtLeast(pending, anchor) {
            // A newer cursor is already waiting for the same coalesced save.
        } else {
            pendingSequenceAnchors[sessionID] = anchor
        }
        scheduleSequencePersistence()
    }

    private func scheduleSequencePersistence() {
        guard lifecycle != .stopping, sequencePersistenceTask == nil else { return }
        sequencePersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: WarrenApplicationPerformance.sequencePersistenceDelay)
            } catch {
                return
            }
            await self?.flushPendingSequencePersistence()
        }
    }

    internal func flushPendingSequencePersistence() async {
        sequencePersistenceTask = nil
        guard !pendingSequenceAnchors.isEmpty else { return }

        let flushed = pendingSequenceAnchors
        do {
            // Capture `state` only after acquiring the gate.  This keeps a
            // delayed cursor save from overwriting a concurrent project or
            // resize mutation that was already serialized by the gate.
            try await withPersistenceMutation {
                try await save(state)
            }
            for (sessionID, anchor) in flushed {
                guard let pending = pendingSequenceAnchors[sessionID] else { continue }
                if isAnchorAtLeast(anchor, pending) {
                    pendingSequenceAnchors.removeValue(forKey: sessionID)
                }
            }
        } catch {
            report(error.asApplicationError, id: "persistence.sequence")
            // Do not spin a retry loop while the service is shutting down;
            // the final state remains in memory and will be reported there.
            if lifecycle != .stopping {
                scheduleSequencePersistence()
            }
        }
    }

    internal func invalidateOutputSnapshot(for sessionID: TerminalSessionID) {
        invalidatedOutputSessions.insert(sessionID)
    }

    /// Reapplies output cursors that advanced while a slower repository save
    /// suspended the actor. Without this merge, assigning an older candidate
    /// after the await can roll the in-memory cursor backwards until the next
    /// coalesced sequence write.
    internal func mergePendingSequences(into candidate: inout PersistedHostState) {
        for (sessionID, anchor) in pendingSequenceAnchors {
            guard let index = candidate.terminalSessions.firstIndex(where: { $0.id == sessionID }) else {
                continue
            }
            let current = candidate.terminalSessions[index]
            guard anchor.epoch > current.epoch ||
                (anchor.epoch == current.epoch && anchor.sequence > current.sequence)
            else { continue }
            candidate.terminalSessions[index].epoch = anchor.epoch
            candidate.terminalSessions[index].sequence = anchor.sequence
        }
    }

    internal func scheduleOutputPublication(for sessionID: TerminalSessionID) {
        guard lifecycle != .stopping else { return }
        pendingOutputSessions.insert(sessionID)
        guard outputPublishTask == nil else { return }
        outputPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: WarrenApplicationPerformance.outputPublicationDelay)
            } catch {
                return
            }
            await self?.flushPendingOutputPublication()
        }
    }

    internal func flushPendingOutputPublication() async {
        outputPublishTask = nil
        guard !pendingOutputSessions.isEmpty else { return }
        pendingOutputSessions.removeAll()
        await publish()
    }

    private func isAnchorAtLeast(_ lhs: RecoveryAnchor, _ rhs: RecoveryAnchor) -> Bool {
        lhs.epoch > rhs.epoch ||
            (lhs.epoch == rhs.epoch && lhs.sequence >= rhs.sequence)
    }

    internal func makeSnapshot() async -> WarrenApplicationSnapshot {
        // `connections` is a dictionary, and sorting by the UUID-derived tab
        // ID makes a newly created tab jump to an arbitrary position.  The
        // durable terminal list is the Host's creation order, so use it as
        // the primary order and retain a deterministic fallback for a runtime
        // adopted outside the state file.
        let sessionOrder = Dictionary(
            uniqueKeysWithValues: state.terminalSessions.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        let sorted = connections.values.sorted {
            let lhs = sessionOrder[$0.session.id] ?? Int.max
            let rhs = sessionOrder[$1.session.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.tabID < $1.tabID
        }
        var sessions: [WarrenApplicationSession] = []
        sessions.reserveCapacity(state.terminalSessions.count)

        for connection in sorted {
            let client = await connection.store.snapshot()
            let connectionState: WarrenApplicationConnectionState
            if connection.runtimeEnded {
                connectionState = .exited
            } else { switch client.connectionState {
            case .disconnected: connectionState = .disconnected
            case .connecting: connectionState = .connecting
            case .attached: connectionState = .attached
            case .reconnecting: connectionState = .reconnecting
            case .exited: connectionState = .exited
            case .failed: connectionState = .failed
            } }

            let output: WarrenApplicationOutputSnapshot?
            if let cached = outputSnapshotCache[connection.session.id],
               !invalidatedOutputSessions.contains(connection.session.id) {
                output = cached
            } else if let hostSnapshot = try? await coordinator.snapshot(of: connection.session.id) {
                let refreshed = WarrenApplicationOutputSnapshot(
                    sessionID: connection.session.id,
                    ring: hostSnapshot.output
                )
                outputSnapshotCache[connection.session.id] = refreshed
                invalidatedOutputSessions.remove(connection.session.id)
                output = refreshed
            } else {
                output = nil
            }
            sessions.append(
                WarrenApplicationSession(
                    id: connection.session.id,
                    workspaceID: connection.workspaceID,
                    tabID: connection.tabID,
                    title: connection.title,
                    kind: connection.kind,
                    connectionState: connectionState,
                    activityState: activityState(for: connection.session.id, connectionState: connectionState),
                    runtimeProcess: client.runtimeProcess,
                    workingDirectory: client.workingDirectory.isEmpty
                        ? (state.workspaces.first { $0.id == connection.workspaceID }?.path ?? "")
                        : client.workingDirectory,
                    attachmentID: client.attachmentID ?? connection.attachmentID,
                    controllerAttachmentID: client.controllerAttachmentID,
                    controlLeaseID: client.controlLeaseID,
                    recoveryAnchor: client.recoveryAnchor ?? connection.session.recoveryAnchor,
                    terminalSize: connection.terminalSize,
                    runtimeAdoptionDescriptor: connection.descriptor,
                    output: output
                )
            )
        }

        // Keep dormant metadata in the Host snapshot for CLI roster/history
        // queries without adopting or recreating its runtime. Desktop filters
        // this collection through the visible Tab IDs at its projection seam.
        let connectedSessionIDs = Set(sessions.map(\.id))
        for persisted in state.terminalSessions where !connectedSessionIDs.contains(persisted.id) {
            sessions.append(WarrenApplicationSession(
                id: persisted.id,
                workspaceID: persisted.workspaceID,
                tabID: tabID(for: persisted.id),
                title: persisted.title?.isEmpty == false
                    ? persisted.title!
                    : (persisted.kind == .shell ? "Terminal" : persisted.kind.displayName),
                kind: persisted.kind,
                connectionState: persisted.lifecycle == .ended ? .exited : .disconnected,
                activityState: persisted.lifecycle == .ended ? .exited : .connecting,
                workingDirectory: persisted.workingDirectory,
                recoveryAnchor: RecoveryAnchor(
                    epoch: persisted.epoch,
                    sequence: persisted.sequence
                ),
                terminalSize: persisted.terminalSize,
                runtimeAdoptionDescriptor: persisted.runtimeAdoptionDescriptor
            ))
        }

        let windowLayout = await layoutStore.window(id: windowID)
        return WarrenApplicationSnapshot(
            host: host,
            projects: state.projects,
            workspaces: state.workspaces,
            sessions: sessions,
            windowLayout: windowLayout,
            issues: issues,
            lifecycle: lifecycle
        )
    }

    func activityState(
        for sessionID: TerminalSessionID,
        connectionState: WarrenApplicationConnectionState
    ) -> TerminalSessionActivityState {
        switch connectionState {
        case .failed:
            return .failed
        case .exited:
            return .exited
        case .connecting, .reconnecting, .disconnected:
            return sessionActivity[sessionID] ?? .connecting
        case .attached:
            return sessionActivity[sessionID] ?? .working
        }
    }
}

private extension TerminalSession {
    var recoveryAnchor: RecoveryAnchor {
        RecoveryAnchor(epoch: epoch, sequence: sequence)
    }
}
