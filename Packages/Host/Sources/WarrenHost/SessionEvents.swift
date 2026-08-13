import Foundation
import WarrenDomain
import WarrenProtocol

/// Events produced by one Host attachment.
///
/// This is deliberately a Host-facing type.  A transport maps it to its own
/// client event model, so the coordinator never imports a particular client
/// or UI package.
public enum HostSessionEvent: Hashable, Sendable {
    case control(ServerControlMessage)
    case binary(TerminalOutputFrame)
}

/// The result of attaching together with the atomically registered event
/// channel.  The channel remains valid until detach, replacement by another
/// attach with the same attachment identity, or stream cancellation.
public struct HostAttachmentChannel: Sendable {
    public let result: AttachResult
    public let events: AsyncStream<HostSessionEvent>

    public init(result: AttachResult, events: AsyncStream<HostSessionEvent>) {
        self.result = result
        self.events = events
    }
}

/// Stored only by the actor that owns the session map.  The token prevents a
/// late termination callback from an old stream removing a replacement
/// subscription for the same attachment identity.
package struct AttachmentEventContinuation: Sendable {
    package let token: UUID
    package let sessionID: TerminalSessionID
    package let continuation: AsyncStream<HostSessionEvent>.Continuation

    package init(
        token: UUID = UUID(),
        sessionID: TerminalSessionID,
        continuation: AsyncStream<HostSessionEvent>.Continuation
    ) {
        self.token = token
        self.sessionID = sessionID
        self.continuation = continuation
    }
}

extension TerminalSessionCoordinator {
    /// Validates a client-local operation (currently focus) without creating
    /// Host state for it.
    public func validateAttachment(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        version: ProtocolVersion = .current
    ) throws {
        try validate(version: version)
        guard let state = sessions[sessionID] else {
            throw protocolError(.sessionNotFound, "The terminal session does not exist.")
        }
        guard state.attachments[attachmentID] != nil else {
            throw protocolError(.attachmentNotFound, "The attachment is not connected to this session.")
        }
    }

    /// Removes only the event subscription.  It intentionally does not detach
    /// the attachment: a stream consumer can be replaced independently from
    /// the attachment's Host identity.
    package func removeEventSubscription(
        attachmentID: TerminalAttachmentID,
        token: UUID? = nil
    ) {
        guard let current = eventContinuations[attachmentID] else { return }
        if let token, current.token != token { return }
        eventContinuations.removeValue(forKey: attachmentID)
    }

    /// Notifies all live attachments when the control lease changes.
    package func publishControlChanged(for sessionID: TerminalSessionID) {
        guard let state = sessions[sessionID] else { return }
        let message = ServerControlMessage.controlChanged(
            ControlChangedMessage(
                sessionID: sessionID,
                controllerAttachmentID: state.controllerLease?.attachmentID,
                leaseID: state.controllerLease?.id
            )
        )
        for attachmentID in state.attachments.keys {
            yield(.control(message), to: attachmentID)
        }
    }

    /// Publishes a terminal output frame only to attachments of its own
    /// session.  The OutputRing is updated before publication, so every
    /// receiver can recover from a dropped/buffered event using the same
    /// authoritative sequence interval.
    package func publishOutput(
        _ frame: TerminalOutputFrame,
        sessionID: TerminalSessionID
    ) {
        guard let state = sessions[sessionID] else { return }
        for attachmentID in state.attachments.keys {
            yield(.binary(frame), to: attachmentID)
        }
    }

    private func yield(_ event: HostSessionEvent, to attachmentID: TerminalAttachmentID) {
        guard let current = eventContinuations[attachmentID] else { return }
        switch current.continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            // Host attachment streams are currently unbounded so this is
            // defensive only.  If a future bounded implementation is used,
            // the next frame's sequence exposes the gap to ClientSessionStore
            // and the client can reattach with its retained recovery anchor.
            break
        case .terminated:
            eventContinuations.removeValue(forKey: attachmentID)
        @unknown default:
            eventContinuations.removeValue(forKey: attachmentID)
        }
    }
}
