import Foundation
import BurrowDomain
import BurrowProtocol

extension TerminalSessionCoordinator {
    package func validate(version: ProtocolVersion) throws {
        guard ProtocolVersion.current.canDecode(version) else {
            throw protocolError(
                .unsupportedVersion,
                "Protocol version \(version.major).\(version.minor) is not supported by this Host."
            )
        }
    }

    package func expireLease(in state: inout SessionState, at date: Date) {
        if let lease = state.controllerLease, !lease.isActive(at: date) {
            state.controllerLease = nil
        }
    }

    package func requireController(
        in state: inout SessionState,
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        at date: Date
    ) throws {
        guard state.attachments[attachmentID] != nil else {
            throw protocolError(.attachmentNotFound, "The attachment is not connected to this session.")
        }
        guard let lease = state.controllerLease else {
            throw protocolError(.controlRequired, "A current control lease is required for input or resize.")
        }
        guard lease.isActive(at: date) else {
            state.controllerLease = nil
            throw protocolError(.controlLeaseExpired, "The control lease has expired; request a new lease.", retryable: true)
        }
        guard lease.attachmentID == attachmentID else {
            throw protocolError(.controlRequired, "Only the current controller may send input or resize.")
        }
        guard lease.sessionID == sessionID else {
            throw protocolError(.invalidMessage, "The control lease belongs to another session.")
        }
    }

    package func protocolError(
        _ code: ProtocolErrorCode,
        _ message: String,
        retryable: Bool = false
    ) -> ProtocolError {
        ProtocolError(code: code, message: message, retryable: retryable)!
    }
}
