import Foundation
import WarrenProtocol

/// A PTY output frame. The header is kept separate from its bytes so a client
/// can validate the recovery position before handing bytes to a renderer.
public struct BinaryOutputFrame: Hashable, Sendable {
    public let header: BinaryOutputFrameHeader
    public let payload: Data

    public init(header: BinaryOutputFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public var hasValidPayloadLength: Bool {
        payload.count == header.payloadLength
    }
}

/// Events received from a Host transport. Control messages and PTY bytes use
/// separate event cases because they have different versioning and recovery
/// rules.
public enum HostTransportEvent: Hashable, Sendable {
    case control(ServerControlMessage)
    case binary(BinaryOutputFrame)
}

public enum HostTransportError: Error, Equatable, Sendable {
    case closed
    case inputPayloadLengthMismatch(expected: Int, actual: Int)
}

/// A transport only moves versioned control messages and received binary
/// frames. The default macOS composition talks to the local/remote
/// `warren-headless` daemon over WebSocket; other adapters can implement this
/// boundary without moving session projection or layout policy into the
/// transport.
public protocol HostTransport: Sendable {
    func send(_ message: ClientControlMessage) async throws
    /// Sends terminal input as one bounded binary envelope.
    ///
    /// The metadata's `payloadLength` must equal `payload.count`. Its optional
    /// sequence is advisory in protocol 1.0: there is no ACK/deduplication
    /// contract and callers must not retry it as an idempotent operation.
    func sendInput(metadata: InputMetadata, payload: Data) async throws
    func events() -> AsyncThrowingStream<HostTransportEvent, Error>
}
