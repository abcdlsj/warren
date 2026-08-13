import WarrenDomain

public enum TerminalInputEncodingError: Error, Equatable, Sendable {
    case unsupportedControl(Character)
}

/// Errors at the renderer boundary are structural so callers can decide
/// whether to retry, reanchor, or discard a stale surface without parsing text.
public enum TerminalRendererError: Error, Equatable, Sendable {
    case surfaceAlreadyExists(TerminalAttachmentID)
    case unknownSurface(TerminalSurfaceID)
    case surfaceDisposed(TerminalSurfaceID)
    case surfaceBindingMismatch(TerminalSurfaceID)
    case sessionMismatch(expected: TerminalSessionID, received: TerminalSessionID)
    case invalidOutputLength(expected: Int, received: Int)
    case outputEpochMismatch(expected: UInt64, received: UInt64)
    case outputOutOfOrder(expected: UInt64, received: UInt64)
    case reanchorRequired(TerminalSurfaceID)
    case sequenceOverflow
    case inputEncoding(TerminalInputEncodingError)
}
