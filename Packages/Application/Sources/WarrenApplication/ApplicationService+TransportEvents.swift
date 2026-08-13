import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenProtocol

extension WarrenApplicationService {
    /// The sole transport-event consumption seam. Both the in-process stream
    /// and deterministic tests enter here, so Client projection and sequence
    /// persistence cannot diverge between production and tests.
    public func consumeTransportEvent(_ event: HostTransportEvent) async {
        switch event {
        case let .control(message):
            await consumeControl(message)
        case let .binary(frame):
            await consumeBinary(frame)
        }
    }

    private func consumeControl(_ message: ServerControlMessage) async {
        guard let sessionID = sessionID(for: message), var connection = connections[sessionID] else {
            return
        }
        do {
            let update = try await connection.store.consume(message)
            switch update {
            case let .attached(snapshot):
                guard let attachmentID = snapshot.attachmentID else {
                    throw WarrenApplicationError.transport("Host returned an attached message without an attachment ID.")
                }
                connection.attachmentID = attachmentID
                connections[sessionID] = connection
            case let .synced(snapshot):
                updateSessionAnchor(sessionID: sessionID, anchor: snapshot.recoveryAnchor)
                if let attachmentID = connection.attachmentID {
                    completeAttachmentWaiter(
                        sessionID: sessionID,
                        attachmentID: attachmentID,
                        result: .success(attachmentID)
                    )
                }
            case let .controlChanged(snapshot):
                connections[sessionID] = connection
                if let controller = snapshot.controllerAttachmentID,
                   controller == connection.attachmentID {
                    completeControlWaiter(
                        sessionID: sessionID,
                        attachmentID: controller,
                        result: .success(())
                    )
                }
            case let .error(snapshot):
                connections[sessionID] = connection
                if let error = snapshot.lastError {
                    completeAttachmentWaiter(
                        sessionID: sessionID,
                        attachmentID: connection.attachmentID,
                        result: .failure(.protocolFailure(error))
                    )
                    completeControlWaiter(
                        sessionID: sessionID,
                        attachmentID: connection.attachmentID,
                        result: .failure(.protocolFailure(error))
                    )
                    report(.protocolFailure(error), id: "session.\(sessionID).protocol")
                }
            case let .exit(snapshot):
                connection.session.epoch = snapshot.recoveryAnchor?.epoch ?? connection.session.epoch
                connection.session.sequence = snapshot.recoveryAnchor?.sequence ?? connection.session.sequence
                connection.runtimeEnded = true
                connections[sessionID] = connection
                await markSessionEnded(sessionID: sessionID)
            case let .title(snapshot):
                connection.title = snapshot.title ?? connection.title
                connections[sessionID] = connection
            case .binary, .binaryHeader:
                connections[sessionID] = connection
            }
        } catch {
            let appError = error.asApplicationError
            completeAttachmentWaiter(
                sessionID: sessionID,
                attachmentID: connection.attachmentID,
                result: .failure(appError)
            )
            completeControlWaiter(
                sessionID: sessionID,
                attachmentID: connection.attachmentID,
                result: .failure(appError)
            )
            report(appError, id: "session.\(sessionID).protocol-consume")
        }
        await publish()
    }

    private func consumeBinary(_ frame: BinaryOutputFrame) async {
        let sessionID = frame.header.sessionID
        guard var connection = connections[sessionID] else { return }
        do {
            _ = try await connection.store.consume(.binary(frame))
            connection.session.epoch = frame.header.epoch
            connection.session.sequence = frame.header.sequence + UInt64(frame.payload.count)
            connections[sessionID] = connection
            invalidateOutputSnapshot(for: sessionID)
            queueSequencePersistence(
                sessionID: sessionID,
                anchor: RecoveryAnchor(
                    epoch: frame.header.epoch,
                    sequence: connection.session.sequence
                )
            )
        } catch {
            let appError = error.asApplicationError
            report(appError, id: "session.\(sessionID).output")
        }
        scheduleOutputPublication(for: sessionID)
    }

    private func sessionID(for message: ServerControlMessage) -> TerminalSessionID? {
        switch message {
        case let .attached(value): return value.sessionID
        case let .error(value): return value.sessionID ?? soleSessionID()
        case let .exit(value): return value.sessionID
        case let .title(value): return value.sessionID
        case let .synced(value): return value.sessionID
        case let .controlChanged(value): return value.sessionID
        }
    }

    private func soleSessionID() -> TerminalSessionID? {
        guard connections.count == 1 else { return nil }
        return connections.keys.first
    }

    private func updateSessionAnchor(sessionID: TerminalSessionID, anchor: RecoveryAnchor?) {
        guard let anchor, var connection = connections[sessionID] else { return }
        guard anchor.epoch > connection.session.epoch ||
            (anchor.epoch == connection.session.epoch && anchor.sequence >= connection.session.sequence)
        else { return }
        connection.session.epoch = anchor.epoch
        connection.session.sequence = anchor.sequence
        connections[sessionID] = connection
    }

    private func completeAttachmentWaiter(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID?,
        result: Result<TerminalAttachmentID, WarrenApplicationError>
    ) {
        let matching = attachmentWaiters.filter {
            $0.value.sessionID == sessionID &&
                (attachmentID == nil || $0.value.attachmentID == attachmentID)
        }
        for (token, waiter) in matching {
            waiter.continuation.yield(result)
            waiter.continuation.finish()
            attachmentWaiters.removeValue(forKey: token)
        }
    }

    private func completeControlWaiter(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID?,
        result: Result<Void, WarrenApplicationError>
    ) {
        guard let attachmentID else { return }
        let matching = controlWaiters.filter {
            $0.value.sessionID == sessionID && $0.value.attachmentID == attachmentID
        }
        for (token, waiter) in matching {
            waiter.continuation.yield(result)
            waiter.continuation.finish()
            controlWaiters.removeValue(forKey: token)
        }
    }
}
