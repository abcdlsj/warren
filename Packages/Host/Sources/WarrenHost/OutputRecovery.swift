import Foundation
import WarrenDomain

extension TerminalSessionCoordinator {
    @discardableResult
    public func recordOutput(
        sessionID: TerminalSessionID,
        data: Data
    ) throws -> TerminalOutputFrame {
        guard var state = sessions[sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot record output for a missing session.")
        }
        let frame = try state.output.append(sessionID: sessionID, payload: data)
        state.session.sequence = state.output.upperSequence
        sessions[sessionID] = state
        publishOutput(frame, sessionID: sessionID)
        return frame
    }

    public func recover(
        sessionID: TerminalSessionID,
        anchor: RecoveryAnchor?
    ) throws -> RecoveryResponse {
        guard let state = sessions[sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot recover a missing session.")
        }
        return state.output.recovery(for: anchor)
    }
}
