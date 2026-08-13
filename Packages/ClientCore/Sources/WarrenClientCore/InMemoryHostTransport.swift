import Foundation
import WarrenProtocol

/// A binary input observed by the deterministic in-memory transport.
public struct InMemorySentInput: Hashable, Sendable {
    public let metadata: InputMetadata
    public let payload: Data

    public init(metadata: InputMetadata, payload: Data) {
        self.metadata = metadata
        self.payload = payload
    }

}

/// Deterministic transport used by client-core tests and previews. The actor
/// makes sent messages and injected events safe to inspect from any task.
public actor InMemoryHostTransport: HostTransport {
    private let eventStream: AsyncThrowingStream<HostTransportEvent, Error>
    private var eventContinuation: AsyncThrowingStream<HostTransportEvent, Error>.Continuation?
    private var sentMessagesStorage: [ClientControlMessage] = []
    private var sentInputsStorage: [InMemorySentInput] = []
    private var isClosed = false

    public init() {
        let pair = AsyncThrowingStream<HostTransportEvent, Error>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    public nonisolated func events() -> AsyncThrowingStream<HostTransportEvent, Error> {
        eventStream
    }

    public func send(_ message: ClientControlMessage) async throws {
        guard !isClosed else { throw HostTransportError.closed }
        sentMessagesStorage.append(message)
    }

    public func sendInput(metadata: InputMetadata, payload: Data) async throws {
        guard !isClosed else { throw HostTransportError.closed }
        guard metadata.payloadLength == payload.count else {
            throw HostTransportError.inputPayloadLengthMismatch(
                expected: metadata.payloadLength,
                actual: payload.count
            )
        }
        sentInputsStorage.append(InMemorySentInput(metadata: metadata, payload: payload))
    }

    public var sentMessages: [ClientControlMessage] {
        sentMessagesStorage
    }

    public var sentInputs: [InMemorySentInput] {
        sentInputsStorage
    }

    public func yield(_ event: HostTransportEvent) {
        guard !isClosed else { return }
        eventContinuation?.yield(event)
    }

    public func finish() {
        guard !isClosed else { return }
        isClosed = true
        eventContinuation?.finish()
        eventContinuation = nil
    }

    public func fail(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        eventContinuation?.finish(throwing: error)
        eventContinuation = nil
    }
}
