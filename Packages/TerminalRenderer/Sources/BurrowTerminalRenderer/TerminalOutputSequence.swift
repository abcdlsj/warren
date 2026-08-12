import Foundation
import BurrowClientCore
import BurrowDomain

/// Platform-neutral PTY output ordering state machine.
///
/// `sequence` is a byte offset. A failed epoch/order check enters the
/// reanchor state and remains there until the client receives an explicit
/// recovery anchor from Host.
public struct TerminalOutputSequence: Hashable, Sendable {
    public private(set) var expectedAnchor: RecoveryAnchor
    public private(set) var needsReanchor: Bool

    public init(anchor: RecoveryAnchor) {
        expectedAnchor = anchor
        needsReanchor = false
    }

    /// Validates and advances one complete output frame.
    ///
    /// The state is advanced only after every check succeeds. Epoch, order,
    /// and arithmetic failures mark the sequence as requiring reanchor so a
    /// stale stream cannot be rendered accidentally afterward.
    public mutating func accept(
        _ output: BinaryOutputFrame,
        sessionID: TerminalSessionID,
        surfaceID: TerminalSurfaceID
    ) throws -> Data {
        guard output.hasValidPayloadLength else {
            throw TerminalRendererError.invalidOutputLength(
                expected: output.header.payloadLength,
                received: output.payload.count
            )
        }
        guard output.header.sessionID == sessionID else {
            throw TerminalRendererError.sessionMismatch(
                expected: sessionID,
                received: output.header.sessionID
            )
        }
        guard !needsReanchor else {
            throw TerminalRendererError.reanchorRequired(surfaceID)
        }
        guard output.header.epoch == expectedAnchor.epoch else {
            needsReanchor = true
            throw TerminalRendererError.outputEpochMismatch(
                expected: expectedAnchor.epoch,
                received: output.header.epoch
            )
        }
        guard output.header.sequence == expectedAnchor.sequence else {
            needsReanchor = true
            throw TerminalRendererError.outputOutOfOrder(
                expected: expectedAnchor.sequence,
                received: output.header.sequence
            )
        }

        let (nextSequence, overflowed) = output.header.sequence.addingReportingOverflow(
            UInt64(output.payload.count)
        )
        guard !overflowed else {
            needsReanchor = true
            throw TerminalRendererError.sequenceOverflow
        }
        expectedAnchor = RecoveryAnchor(epoch: output.header.epoch, sequence: nextSequence)
        return output.payload
    }

    /// Replaces the expected byte offset after Host has completed recovery.
    public mutating func reanchor(_ anchor: RecoveryAnchor) {
        expectedAnchor = anchor
        needsReanchor = false
    }
}
