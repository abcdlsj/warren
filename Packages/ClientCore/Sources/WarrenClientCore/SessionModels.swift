import WarrenDomain
import WarrenProtocol

public struct ClientHostProjection: Hashable, Sendable {
    public var host: Host

    public init(host: Host) {
        self.host = host
    }
}

public enum ClientConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case attached
    case reconnecting
    case exited
    case failed(ProtocolError)
}

/// The complete client-side projection needed to reconnect a session. It is
/// intentionally a value so it can be handed from an actor to a UI or a
/// reconnect coordinator without sharing mutable state.
public struct ClientSessionSnapshot: Hashable, Sendable {
    public let hostProjection: ClientHostProjection?
    public let sessionID: TerminalSessionID
    public let clientID: ClientID
    public let attachment: TerminalAttachment?
    public let controllerAttachmentID: TerminalAttachmentID?
    public let controlLeaseID: ControlLeaseID?
    public let connectionState: ClientConnectionState
    public let recoveryAnchor: RecoveryAnchor?
    public let title: String?
    public let runtimeProcess: String
    public let workingDirectory: String
    public let capabilities: ProtocolCapabilities
    public let reanchorRequired: Bool
    public let lastError: ProtocolError?

    public init(
        hostProjection: ClientHostProjection?,
        sessionID: TerminalSessionID,
        clientID: ClientID,
        attachment: TerminalAttachment?,
        controllerAttachmentID: TerminalAttachmentID?,
        controlLeaseID: ControlLeaseID?,
        connectionState: ClientConnectionState,
        recoveryAnchor: RecoveryAnchor?,
        title: String?,
        runtimeProcess: String = "",
        workingDirectory: String = "",
        capabilities: ProtocolCapabilities,
        reanchorRequired: Bool,
        lastError: ProtocolError?
    ) {
        self.hostProjection = hostProjection
        self.sessionID = sessionID
        self.clientID = clientID
        self.attachment = attachment
        self.controllerAttachmentID = controllerAttachmentID
        self.controlLeaseID = controlLeaseID
        self.connectionState = connectionState
        self.recoveryAnchor = recoveryAnchor
        self.title = title
        self.runtimeProcess = runtimeProcess
        self.workingDirectory = workingDirectory
        self.capabilities = capabilities
        self.reanchorRequired = reanchorRequired
        self.lastError = lastError
    }

    public var host: Host? { hostProjection?.host }
    public var attachmentID: TerminalAttachmentID? { attachment?.id }
    public var controller: TerminalAttachmentID? { controllerAttachmentID }
    public var anchor: RecoveryAnchor? { recoveryAnchor }
}

public enum ClientSessionUpdate: Hashable, Sendable {
    case attached(ClientSessionSnapshot)
    case synced(ClientSessionSnapshot)
    case controlChanged(ClientSessionSnapshot)
    case exit(ClientSessionSnapshot)
    case error(ClientSessionSnapshot)
    case title(ClientSessionSnapshot)
    case runtimeMetadata(ClientSessionSnapshot)
    case binary(BinaryOutputFrame, ClientSessionSnapshot)
    case binaryHeader(BinaryOutputFrameHeader, ClientSessionSnapshot)
}

public enum ClientSessionStoreError: Error, Equatable, Sendable {
    case sessionMismatch(expected: TerminalSessionID, received: TerminalSessionID)
    case attachmentMismatch(expected: TerminalAttachmentID, received: TerminalAttachmentID)
    case unsupportedVersion(ProtocolVersion)
    case invalidBinaryPayloadLength(expected: Int, received: Int)
    case noRecoveryAnchor
    case binaryEpochMismatch(expected: UInt64, received: UInt64)
    case binaryOutOfOrder(expected: UInt64, received: UInt64)
    case sequenceOverflow
    case sessionExited
}
