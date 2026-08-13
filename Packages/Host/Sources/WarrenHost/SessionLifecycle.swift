import Foundation
import WarrenDomain
import WarrenProtocol

public struct AttachResult: Hashable, Sendable, Identifiable {
    public let attachment: TerminalAttachment
    public let session: TerminalSession
    public let capabilities: ProtocolCapabilities
    public let recovery: RecoveryResponse
    public let controllerLease: ControlLease?

    public var id: TerminalAttachmentID { attachment.id }
    public var attachmentID: TerminalAttachmentID { attachment.id }
    public var sessionID: TerminalSessionID { session.id }
    public var epoch: UInt64 { session.epoch }
    public var sequence: UInt64 { session.sequence }
    public var controllerAttachmentID: TerminalAttachmentID? {
        controllerLease?.attachmentID
    }

    package init(
        attachment: TerminalAttachment,
        session: TerminalSession,
        capabilities: ProtocolCapabilities,
        recovery: RecoveryResponse,
        controllerLease: ControlLease?
    ) {
        self.attachment = attachment
        self.session = session
        self.capabilities = capabilities
        self.recovery = recovery
        self.controllerLease = controllerLease
    }

    public var attachedMessage: AttachedMessage {
        AttachedMessage(
            sessionID: session.id,
            attachmentID: attachment.id,
            // `sequence` is the cursor at which the following recovery
            // frames begin, not necessarily the ring's current upper bound.
            // A client consumes this message before those frames and would
            // otherwise reject a valid tail as out of order.
            epoch: recovery.epoch,
            sequence: recovery.frames.first?.header.sequence ?? recovery.upperSequence,
            capabilities: capabilities,
            controllerAttachmentID: controllerLease?.attachmentID
        )
    }
}

/// The application persists this binding alongside its Host session record.
/// Runtime details stay opaque to WarrenDomain and can therefore be replaced by
/// another adapter without changing the Client protocol.
public struct TerminalSessionRuntimeBinding: Hashable, Sendable {
    public let session: TerminalSession
    public let descriptor: TerminalRuntimeDescriptor

    public init(session: TerminalSession, descriptor: TerminalRuntimeDescriptor) {
        self.session = session
        self.descriptor = descriptor
    }
}

public typealias CreatedTerminalSession = TerminalSessionRuntimeBinding

public struct HostSessionSnapshot: Hashable, Sendable, Identifiable {
    public let session: TerminalSession
    public let attachments: [TerminalAttachment]
    public let controllerLease: ControlLease?
    public let output: OutputRingSnapshot
    public let runtimeMetadata: TerminalRuntimeMetadata?

    public var id: TerminalSessionID { session.id }
    public var controllerAttachmentID: TerminalAttachmentID? {
        controllerLease?.attachmentID
    }
}

extension TerminalSessionCoordinator {
    public func createSession(
        workspace: Workspace,
        size: TerminalSize = TerminalSessionCoordinator.defaultTerminalSize
    ) async throws -> TerminalSession {
        try await createSessionWithRuntimeDescriptor(workspace: workspace, size: size).session
    }

    /// Creates a Host session and returns the opaque runtime descriptor that
    /// must be persisted by the application for a later adoption.
    public func createSessionWithRuntimeDescriptor(
        workspace: Workspace,
        size: TerminalSize = TerminalSessionCoordinator.defaultTerminalSize,
        launchSpec: TerminalRuntimeLaunchSpec = .interactiveShell
    ) async throws -> TerminalSessionRuntimeBinding {
        let session = TerminalSession(workspaceID: workspace.id)
        // Subscribe before creating the runtime so a fast shell cannot emit
        // its first bytes before Host has an output consumer.
        let runtimeEvents = await runtime.events(for: session.id)
        let descriptor = try await runtime.create(
            sessionID: session.id,
            workingDirectory: workspace.path,
            size: size,
            launchSpec: launchSpec
        )
        sessions[session.id] = SessionState(
            session: session,
            attachments: [:],
            controllerLease: nil,
            output: OutputRing(epoch: session.epoch, capacity: outputCapacity),
            runtimeMetadata: nil
        )
        try startRuntimeStream(sessionID: session.id, stream: runtimeEvents)
        return TerminalSessionRuntimeBinding(session: session, descriptor: descriptor)
    }

    /// Reconstructs a persisted Host session and adopts its still-running
    /// runtime.  Runtime events are subscribed before `adopt`; the pump is
    /// registered immediately after adoption, so output emitted during the
    /// adapter's setup remains queued and receives the persisted byte offset.
    public func adoptSession(
        _ session: TerminalSession,
        descriptor: TerminalRuntimeDescriptor,
        size: TerminalSize
    ) async throws -> TerminalSession {
        guard sessions[session.id] == nil else {
            throw protocolError(.invalidMessage, "The terminal session is already registered with this Host.")
        }
        let runtimeEvents = await runtime.events(for: session.id)
        try await runtime.adopt(
            sessionID: session.id,
            descriptor: descriptor,
            size: size,
            outputOffset: session.sequence
        )
        sessions[session.id] = SessionState(
            session: session,
            attachments: [:],
            controllerLease: nil,
            output: OutputRing(
                epoch: session.epoch,
                capacity: outputCapacity,
                nextSequence: session.sequence
            ),
            runtimeMetadata: nil
        )
        try startRuntimeStream(sessionID: session.id, stream: runtimeEvents)
        return session
    }

    public func session(_ sessionID: TerminalSessionID) -> TerminalSession? {
        sessions[sessionID]?.session
    }

    public func snapshot(of sessionID: TerminalSessionID) throws -> HostSessionSnapshot {
        guard let state = sessions[sessionID] else {
            throw protocolError(.sessionNotFound, "Terminal session does not exist.")
        }
        return HostSessionSnapshot(
            session: state.session,
            attachments: state.attachments.values
                .map(\.attachment)
                .sorted { $0.id.description < $1.id.description },
            controllerLease: state.controllerLease,
            output: OutputRingSnapshot(
                epoch: state.output.epoch,
                lowerSequence: state.output.lowerSequence,
                upperSequence: state.output.upperSequence,
                frames: state.output.frames
            ),
            runtimeMetadata: state.runtimeMetadata
        )
    }

    /// Forgets an already-stopped Host Session after its durable record and
    /// client references are being explicitly deleted. Refusing a live
    /// runtime keeps cleanup from accidentally becoming another terminate API.
    public func discardStoppedSession(_ sessionID: TerminalSessionID) async throws {
        guard let state = sessions[sessionID] else { return }
        switch await runtime.presence(sessionID: sessionID) {
        case .missing:
            break
        case .present:
            throw protocolError(.invalidMessage, "A live terminal runtime must be terminated before deletion.")
        case .unavailable(let reason):
            throw protocolError(
                .internalFailure,
                "The terminal runtime could not be verified before deletion: \(reason)",
                retryable: true
            )
        }
        for attachmentID in state.attachments.keys {
            eventContinuations.removeValue(forKey: attachmentID)?.continuation.finish()
        }
        detachRuntimeStream(sessionID: sessionID)
        sessions.removeValue(forKey: sessionID)
    }

    public func attach(
        _ request: AttachRequest,
        now: Date? = nil
    ) async throws -> AttachResult {
        try attachResult(for: request, now: now)
    }

    /// Atomically attaches a client and opens its Host event channel.
    ///
    /// Keeping registration and the initial recovery snapshot in one actor
    /// turn closes the otherwise subtle gap where PTY output could arrive
    /// between `attach` and `subscribe`.  The returned stream starts with an
    /// `attached` event, followed by retained output and a final `synced`
    /// marker when recovery was requested.
    public func attachAndSubscribe(
        _ request: AttachRequest,
        now: Date? = nil
    ) throws -> HostAttachmentChannel {
        let result = try attachResult(for: request, now: now)
        // A single ordered, bounded stream carries both control and output.
        // Any overflow terminates this Attachment rather than dropping an
        // event; the client can reconnect from its last confirmed anchor.
        let streamPair = AsyncStream<HostSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(eventBufferCapacity)
        )
        let attachmentID = result.attachmentID

        // A repeated attach with the same attachment identity replaces the
        // old subscription, but never creates or destroys the runtime
        // session.  The old stream is completed before its continuation is
        // removed so consumers can terminate deterministically.
        eventContinuations[attachmentID]?.continuation.finish()
        let continuation = streamPair.continuation
        let subscriptionToken = UUID()
        eventContinuations[attachmentID] = AttachmentEventContinuation(
            token: subscriptionToken,
            sessionID: result.sessionID,
            continuation: continuation
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeEventSubscription(
                    attachmentID: attachmentID,
                    token: subscriptionToken
                )
            }
        }

        let recovery = result.recovery
        func enqueue(_ event: HostSessionEvent) throws {
            switch continuation.yield(event) {
            case .enqueued:
                return
            case .dropped:
                continuation.finish()
                eventContinuations.removeValue(forKey: attachmentID)
                throw HostAttachmentStreamError.eventBufferOverflow
            case .terminated:
                eventContinuations.removeValue(forKey: attachmentID)
                throw HostAttachmentStreamError.eventBufferOverflow
            @unknown default:
                eventContinuations.removeValue(forKey: attachmentID)
                throw HostAttachmentStreamError.eventBufferOverflow
            }
        }
        // A recovery tail starts before the current upper sequence.  The
        // attached cursor therefore points at the first retained byte; the
        // final synced marker advances it to the current upper sequence.
        try enqueue(.control(.attached(result.attachedMessage)))
        if let metadata = sessions[result.sessionID]?.runtimeMetadata {
            try enqueue(.control(.runtimeMetadata(
                RuntimeMetadataMessage(
                    sessionID: result.sessionID,
                    process: metadata.process,
                    workingDirectory: metadata.workingDirectory
                )
            )))
        }
        for frame in recovery.frames {
            try enqueue(.binary(frame))
        }
        // Emitting a synced marker for every attach gives the client a stable
        // recovery boundary, including an exact attach with no frames.
        try enqueue(.control(.synced(
            SyncedMessage(sessionID: result.sessionID, anchor: recovery.anchor)
        )))

        return HostAttachmentChannel(result: result, events: streamPair.stream)
    }

    package func attachResult(
        for request: AttachRequest,
        now: Date?
    ) throws -> AttachResult {
        try validate(version: request.version)
        guard var state = sessions[request.sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot attach because the terminal session was not found.")
        }
        expireLease(in: &state, at: now ?? clock())

        let attachment: TerminalAttachment
        let capabilities: ProtocolCapabilities
        if let requestedID = request.attachmentID,
           let existing = state.attachments[requestedID] {
            guard existing.attachment.sessionID == request.sessionID,
                  existing.attachment.clientID == request.clientID else {
                throw protocolError(.invalidMessage, "The requested attachment belongs to another client or session.")
            }
            attachment = existing.attachment
            capabilities = existing.capabilities
        } else {
            attachment = TerminalAttachment(
                id: request.attachmentID ?? TerminalAttachmentID(),
                sessionID: request.sessionID,
                clientID: request.clientID
            )
            guard state.attachments[attachment.id] == nil else {
                throw protocolError(.invalidMessage, "The attachment identifier is already in use.")
            }
            capabilities = request.capabilities
            state.attachments[attachment.id] = AttachmentState(
                attachment: attachment,
                capabilities: capabilities
            )
        }

        let recovery = state.output.recovery(for: request.recoveryAnchor)
        sessions[request.sessionID] = state
        return AttachResult(
            attachment: attachment,
            session: state.session,
            capabilities: capabilities,
            recovery: recovery,
            controllerLease: state.controllerLease
        )
    }

    @discardableResult
    public func detach(
        _ request: DetachRequest,
        now: Date? = nil
    ) throws -> TerminalAttachment {
        try validate(version: request.version)
        guard var state = sessions[request.sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot detach because the terminal session was not found.")
        }
        expireLease(in: &state, at: now ?? clock())
        let removedController = state.controllerLease?.attachmentID == request.attachmentID
        guard let removed = state.attachments.removeValue(forKey: request.attachmentID) else {
            throw protocolError(.attachmentNotFound, "Cannot detach because the attachment was not found.")
        }
        if removedController {
            state.controllerLease = nil
        }
        sessions[request.sessionID] = state
        eventContinuations[request.attachmentID]?.continuation.finish()
        eventContinuations.removeValue(forKey: request.attachmentID)
        if removedController {
            publishControlChanged(for: request.sessionID)
        }
        return removed.attachment
    }
}
