import BurrowDomain
import BurrowHost
import BurrowLocalTransport
import BurrowProtocol
import Foundation

extension BurrowApplicationService {
    /// Opens an independent attachment for a non-desktop client.
    ///
    /// The desktop projection keeps its own attachment in `connections`.
    /// Web and future remote clients must use this channel so their output
    /// subscriptions and control leases cannot replace the desktop stream.
    public func openClientAttachment(
        sessionID: TerminalSessionID,
        clientID: ClientID,
        attachmentID: TerminalAttachmentID,
        recoveryAnchor: RecoveryAnchor? = nil
    ) async throws -> HostAttachmentChannel {
        try requireReady()
        await ensureSessionRestored(sessionID)
        return try await coordinator.attachAndSubscribe(AttachRequest(
            sessionID: sessionID,
            clientID: clientID,
            attachmentID: attachmentID,
            recoveryAnchor: recoveryAnchor
        ))
    }

    /// Read-only Host attachment snapshot for diagnostics and contract tests.
    public func hostSessionSnapshot(
        sessionID: TerminalSessionID
    ) async throws -> HostSessionSnapshot {
        try requireReady()
        await ensureSessionRestored(sessionID)
        return try await coordinator.snapshot(of: sessionID)
    }

    /// Sends input from an independent client attachment. Control remains
    /// last-writer-wins and is acquired only when that client actually types.
    public func sendClientInput(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        data: Data
    ) async throws {
        _ = try await coordinator.requestControl(ControlRequest(
            sessionID: sessionID,
            attachmentID: attachmentID
        ))
        guard let metadata = InputMetadata(
            sessionID: sessionID,
            attachmentID: attachmentID,
            payloadLength: data.count
        ) else {
            throw BurrowApplicationError.transport("Invalid remote terminal input length.")
        }
        try await coordinator.input(metadata, data: data)
    }

    public func resizeClientAttachment(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        size: TerminalSize
    ) async throws {
        _ = try await coordinator.requestControl(ControlRequest(
            sessionID: sessionID,
            attachmentID: attachmentID
        ))
        try await coordinator.resize(ResizeRequest(
            sessionID: sessionID,
            attachmentID: attachmentID,
            size: size
        ))
    }

    public func closeClientAttachment(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        reason: String? = nil
    ) async {
        _ = try? await coordinator.detach(DetachRequest(
            sessionID: sessionID,
            attachmentID: attachmentID,
            reason: reason
        ))
    }

    /// Attaches the one local Client projection to a Host session.
    @discardableResult
    public func attach(
        sessionID: TerminalSessionID,
        recoveryAnchor: RecoveryAnchor? = nil,
        attachmentID: TerminalAttachmentID? = nil
    ) async throws -> TerminalAttachmentID {
        try requireReady()
        await ensureSessionRestored(sessionID)
        return try await attachInternal(
            sessionID: sessionID,
            recoveryAnchor: recoveryAnchor,
            attachmentID: attachmentID,
            requireReady: false
        )
    }

    /// Requests the single control lease and completes after the Host emits
    /// the corresponding control_changed event through the shared event seam.
    public func requestControl(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID
    ) async throws {
        try requireAttachment(sessionID: sessionID, attachmentID: attachmentID)
        let pair = AsyncStream<Result<Void, BurrowApplicationError>>.makeStream()
        let token = UUID()
        controlWaiters[token] = ControlWaiter(
            sessionID: sessionID,
            attachmentID: attachmentID,
            continuation: pair.continuation
        )
        do {
            try await transport.send(.requestControl(ControlRequest(
                sessionID: sessionID,
                attachmentID: attachmentID
            )))
        } catch {
            controlWaiters.removeValue(forKey: token)?.continuation.finish()
            throw BurrowApplicationError.transport(String(describing: error))
        }
        var iterator = pair.stream.makeAsyncIterator()
        while let result = await iterator.next() {
            switch result {
            case .success:
                return
            case let .failure(error):
                throw error
            }
        }
        throw BurrowApplicationError.transport("Control confirmation stream ended.")
    }

    public func control(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID
    ) async throws {
        try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
    }

    /// Sends raw terminal bytes. Input metadata is generated here so callers
    /// cannot accidentally send a JSON control message carrying PTY bytes.
    public func sendInput(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        data: Data
    ) async throws {
        try requireAttachment(sessionID: sessionID, attachmentID: attachmentID)
        try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
        guard let metadata = InputMetadata(
            sessionID: sessionID,
            attachmentID: attachmentID,
            payloadLength: data.count
        ) else {
            throw BurrowApplicationError.protocolFailure(
                ProtocolError(
                    code: .invalidFrame,
                    message: "Invalid terminal input length.",
                    retryable: false
                )!
            )
        }
        do {
            try await transport.sendInput(metadata: metadata, payload: data)
        } catch {
            // Input is an ephemeral operation. A rejected key must not mutate
            // Host lifecycle state or open a global Inspector; the attachment
            // remains valid and the next queued input can still succeed.
            throw error.asApplicationError
        }
    }

    public func sendInput(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        payload: Data
    ) async throws {
        try await sendInput(sessionID: sessionID, attachmentID: attachmentID, data: payload)
    }

    public func input(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        data: Data
    ) async throws {
        try await sendInput(sessionID: sessionID, attachmentID: attachmentID, data: data)
    }

    public func sendSpecialKey(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        key: TerminalSpecialKey
    ) async throws {
        try requireAttachment(sessionID: sessionID, attachmentID: attachmentID)
        try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
        try await coordinator.sendSpecialKey(
            sessionID: sessionID,
            attachmentID: attachmentID,
            key: key
        )
    }

    public func inspectSessionRuntime(
        sessionID: TerminalSessionID
    ) async throws -> TerminalRuntimeInspection {
        try requireReady()
        await ensureSessionRestored(sessionID)
        if let persisted = state.terminalSessions.first(where: { $0.id == sessionID }),
           persisted.lifecycle == .ended {
            return TerminalRuntimeInspection(isRunning: false)
        }
        return try await coordinator.inspectRuntime(sessionID: sessionID)
    }

    public func terminateSession(sessionID: TerminalSessionID) async throws {
        try requireReady()
        await ensureSessionRestored(sessionID)
        try await coordinator.terminateRuntime(sessionID: sessionID)
        await markSessionEnded(sessionID: sessionID)
        await publish()
    }

    public func resize(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        size: TerminalSize
    ) async throws {
        try requireAttachment(sessionID: sessionID, attachmentID: attachmentID)
        let needsPersistence = connections[sessionID]?.terminalSize != size
        try await requestControl(sessionID: sessionID, attachmentID: attachmentID)
        do {
            // Persisted geometry is only the last requested viewport, not an
            // authoritative observation of the live runtime. Always calibrate
            // the PTY on a newly mounted/activated renderer; otherwise a prior
            // interrupted or reordered resize can leave tmux smaller forever.
            try await transport.send(.resize(ResizeRequest(
                sessionID: sessionID,
                attachmentID: attachmentID,
                size: size
            )))
            guard needsPersistence else { return }
            try await withPersistenceMutation {
                guard var connection = connections[sessionID] else {
                    throw BurrowApplicationError.sessionNotFound(sessionID)
                }
                guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else {
                    throw BurrowApplicationError.sessionNotFound(sessionID)
                }
                var candidate = state
                candidate.terminalSessions[index].terminalSize = size
                try await save(candidate)
                mergePendingSequences(into: &candidate)
                state = candidate
                connection.terminalSize = size
                connections[sessionID] = connection
            }
            await publish()
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "session.\(sessionID).resize")
            await publish()
            throw appError
        }
    }

    public func detach(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        reason: String? = nil
    ) async throws {
        try requireAttachment(sessionID: sessionID, attachmentID: attachmentID)
        do {
            try await transport.send(.detach(DetachRequest(
                sessionID: sessionID,
                attachmentID: attachmentID,
                reason: reason
            )))
            if var connection = connections[sessionID], connection.attachmentID == attachmentID {
                connection.attachmentID = nil
                connections[sessionID] = connection
                await connection.store.markDisconnected()
                invalidateOutputSnapshot(for: sessionID)
            }
            await publish()
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "session.\(sessionID).detach")
            await publish()
            throw appError
        }
    }

    internal func requireAttachment(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID
    ) throws {
        guard let connection = connections[sessionID] else {
            throw BurrowApplicationError.sessionNotFound(sessionID)
        }
        guard connection.attachmentID == attachmentID else {
            throw BurrowApplicationError.attachmentNotFound(attachmentID)
        }
    }

    internal func attachInternal(
        sessionID: TerminalSessionID,
        recoveryAnchor: RecoveryAnchor?,
        attachmentID: TerminalAttachmentID? = nil,
        requireReady: Bool
    ) async throws -> TerminalAttachmentID {
        if requireReady { try self.requireReady() }
        guard var connection = connections[sessionID] else {
            throw BurrowApplicationError.sessionNotFound(sessionID)
        }
        let resolvedAttachmentID = attachmentID ?? TerminalAttachmentID()
        connection.attachmentID = resolvedAttachmentID
        connections[sessionID] = connection
        await connection.store.markConnecting()

        let pair = AsyncStream<Result<TerminalAttachmentID, BurrowApplicationError>>.makeStream()
        let token = UUID()
        attachmentWaiters[token] = AttachmentWaiter(
            sessionID: sessionID,
            attachmentID: resolvedAttachmentID,
            continuation: pair.continuation
        )
        do {
            try await transport.send(.attach(AttachRequest(
                sessionID: sessionID,
                clientID: clientID,
                attachmentID: resolvedAttachmentID,
                recoveryAnchor: recoveryAnchor
            )))
        } catch {
            _ = attachmentWaiters.removeValue(forKey: token)
            let appError = error.asApplicationError
            report(appError, id: "session.\(sessionID).attach")
            await publish()
            throw appError
        }

        var iterator = pair.stream.makeAsyncIterator()
        while let result = await iterator.next() {
            switch result {
            case let .success(id): return id
            case let .failure(error): throw error
            }
        }
        throw BurrowApplicationError.transport("Terminal attachment confirmation stream ended.")
    }
}
