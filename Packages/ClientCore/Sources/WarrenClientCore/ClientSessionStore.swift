import Foundation
import WarrenDomain
import WarrenProtocol

/// Actor-isolated projection of one Host terminal session on one Client.
/// Disconnecting this actor never destroys the attachment or recovery anchor;
/// a reconnect coordinator can therefore create a new attach request later.
public actor ClientSessionStore {
    private var hostProjection: ClientHostProjection?
    private let sessionID: TerminalSessionID
    private let clientID: ClientID
    private var attachment: TerminalAttachment?
    private var controllerAttachmentID: TerminalAttachmentID?
    private var controlLeaseID: ControlLeaseID?
    private var connectionState: ClientConnectionState = .disconnected
    private var recoveryAnchor: RecoveryAnchor?
    private var title: String?
    private var runtimeProcess = ""
    private var workingDirectory = ""
    private var capabilities: ProtocolCapabilities = .core
    private var reanchorRequired = false
    private var lastError: ProtocolError?

    public init(
        host: WarrenDomain.Host? = nil,
        sessionID: TerminalSessionID,
        clientID: ClientID
    ) {
        self.hostProjection = host.map(ClientHostProjection.init(host:))
        self.sessionID = sessionID
        self.clientID = clientID
    }

    public init(
        hostProjection: ClientHostProjection?,
        sessionID: TerminalSessionID,
        clientID: ClientID
    ) {
        self.hostProjection = hostProjection
        self.sessionID = sessionID
        self.clientID = clientID
    }

    public func snapshot() -> ClientSessionSnapshot {
        ClientSessionSnapshot(
            hostProjection: hostProjection,
            sessionID: sessionID,
            clientID: clientID,
            attachment: attachment,
            controllerAttachmentID: controllerAttachmentID,
            controlLeaseID: controlLeaseID,
            connectionState: connectionState,
            recoveryAnchor: recoveryAnchor,
            title: title,
            runtimeProcess: runtimeProcess,
            workingDirectory: workingDirectory,
            capabilities: capabilities,
            reanchorRequired: reanchorRequired,
            lastError: lastError
        )
    }

    public func setHost(_ host: WarrenDomain.Host?) {
        hostProjection = host.map(ClientHostProjection.init(host:))
    }

    public func setHostProjection(_ projection: ClientHostProjection?) {
        hostProjection = projection
    }

    public func markConnecting() {
        connectionState = .connecting
    }

    public func markReconnecting() {
        connectionState = .reconnecting
    }

    /// Marks only the connection as lost. Host/session projection, attachment
    /// identity and the last anchor remain available for a later attach.
    public func markDisconnected() {
        connectionState = .disconnected
    }

    public func clearError() {
        lastError = nil
        if case .failed = connectionState {
            connectionState = .disconnected
        }
    }

    @discardableResult
    public func consume(_ event: HostTransportEvent) throws -> ClientSessionUpdate {
        switch event {
        case .control(let message):
            return try consume(message)
        case .binary(let frame):
            return try consume(binaryFrame: frame)
        }
    }

    @discardableResult
    public func consume(_ message: ServerControlMessage) throws -> ClientSessionUpdate {
        guard ProtocolVersion.current.canDecode(message.version) else {
            throw ClientSessionStoreError.unsupportedVersion(message.version)
        }

        switch message {
        case .attached(let value):
            try validateSession(value.sessionID)
            attachment = TerminalAttachment(
                id: value.attachmentID,
                sessionID: value.sessionID,
                clientID: clientID
            )
            controllerAttachmentID = value.controllerAttachmentID
            controlLeaseID = nil
            capabilities = value.capabilities
            recoveryAnchor = RecoveryAnchor(epoch: value.epoch, sequence: value.sequence)
            reanchorRequired = false
            lastError = nil
            connectionState = .attached
            return .attached(snapshot())

        case .synced(let value):
            try validateSession(value.sessionID)
            updateAnchorIfNewer(value.anchor)
            reanchorRequired = false
            connectionState = .attached
            return .synced(snapshot())

        case .controlChanged(let value):
            try validateSession(value.sessionID)
            controllerAttachmentID = value.controllerAttachmentID
            controlLeaseID = value.leaseID
            return .controlChanged(snapshot())

        case .exit(let value):
            try validateSession(value.sessionID)
            updateAnchorIfNewer(RecoveryAnchor(epoch: value.epoch, sequence: value.sequence))
            controllerAttachmentID = nil
            controlLeaseID = nil
            connectionState = .exited
            return .exit(snapshot())

        case .error(let value):
            if let sessionID = value.sessionID {
                try validateSession(sessionID)
            }
            lastError = value
            connectionState = .failed(value)
            return .error(snapshot())

        case .title(let value):
            try validateSession(value.sessionID)
            title = value.title
            return .title(snapshot())

        case .runtimeMetadata(let value):
            try validateSession(value.sessionID)
            runtimeProcess = value.process
            workingDirectory = value.workingDirectory
            return .runtimeMetadata(snapshot())
        }
    }

    /// Consumes a complete frame and advances the anchor by its byte count.
    /// The header's sequence is the next byte position expected by the client.
    @discardableResult
    public func consume(binaryFrame frame: BinaryOutputFrame) throws -> ClientSessionUpdate {
        try validateSession(frame.header.sessionID)
        guard frame.hasValidPayloadLength else {
            throw ClientSessionStoreError.invalidBinaryPayloadLength(
                expected: frame.header.payloadLength,
                received: frame.payload.count
            )
        }
        try validateAndAdvance(anchor: frame.header)
        return .binary(frame, snapshot())
    }

    /// Header-only path for transports that deliver payload bytes to a renderer
    /// separately. It performs no allocation based on `payloadLength`.
    @discardableResult
    public func consume(binaryHeader header: BinaryOutputFrameHeader) throws -> ClientSessionUpdate {
        try validateAndAdvance(anchor: header)
        return .binaryHeader(header, snapshot())
    }

    private func validateSession(_ received: TerminalSessionID) throws {
        guard received == sessionID else {
            throw ClientSessionStoreError.sessionMismatch(expected: sessionID, received: received)
        }
    }

    /// Validates one frame position and advances the next-byte anchor. Keeping
    /// this helper independent of `BinaryOutputFrame` makes the header-only
    /// path safe even for a very large, but representable, payload length.
    private func validateAndAdvance(anchor header: BinaryOutputFrameHeader) throws {
        try validateSession(header.sessionID)
        guard connectionState != .exited else {
            throw ClientSessionStoreError.sessionExited
        }
        guard let current = recoveryAnchor else {
            throw ClientSessionStoreError.noRecoveryAnchor
        }
        guard header.epoch == current.epoch else {
            reanchorRequired = true
            connectionState = .reconnecting
            throw ClientSessionStoreError.binaryEpochMismatch(
                expected: current.epoch,
                received: header.epoch
            )
        }
        guard header.sequence == current.sequence else {
            if header.sequence > current.sequence {
                reanchorRequired = true
                connectionState = .reconnecting
            }
            throw ClientSessionStoreError.binaryOutOfOrder(
                expected: current.sequence,
                received: header.sequence
            )
        }
        let (nextSequence, overflowed) = header.sequence.addingReportingOverflow(
            UInt64(header.payloadLength)
        )
        guard !overflowed else {
            throw ClientSessionStoreError.sequenceOverflow
        }
        recoveryAnchor = RecoveryAnchor(epoch: current.epoch, sequence: nextSequence)
    }

    private func updateAnchorIfNewer(_ candidate: RecoveryAnchor) {
        guard let current = recoveryAnchor else {
            recoveryAnchor = candidate
            return
        }
        if candidate.epoch > current.epoch
            || (candidate.epoch == current.epoch && candidate.sequence >= current.sequence) {
            recoveryAnchor = candidate
        }
    }
}
