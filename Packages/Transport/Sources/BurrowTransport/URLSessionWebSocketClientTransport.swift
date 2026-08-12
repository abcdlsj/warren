import Foundation
import BurrowClientCore
import BurrowProtocol

public enum URLSessionWebSocketClientTransportError: Error, Equatable, Sendable {
    case alreadyConnected
    case notConnected
    case closed
    case invalidIncomingMessage
}

/// Client-only WebSocket transport. It owns one receive loop and turns a
/// terminal error or cancellation into completion of its event stream.
public actor URLSessionWebSocketClientTransport: HostTransport {
    private enum Lifecycle: Sendable {
        case idle
        case connected
        case failed
        case closed
    }

    private let url: URL?
    private let session: URLSession?
    private let codec: BurrowWireCodec
    private let injectedTask: (any BurrowWebSocketTaskAdapter)?
    private let eventStream: AsyncThrowingStream<HostTransportEvent, Error>
    private var eventContinuation: AsyncThrowingStream<HostTransportEvent, Error>.Continuation?
    private var taskAdapter: (any BurrowWebSocketTaskAdapter)?
    private var receiveTask: Task<Void, Never>?
    private var lifecycle: Lifecycle = .idle

    public init(
        url: URL,
        session: URLSession = .shared,
        codec: BurrowWireCodec = BurrowWireCodec()
    ) {
        self.url = url
        self.session = session
        self.codec = codec
        self.injectedTask = nil
        let pair = AsyncThrowingStream<HostTransportEvent, Error>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    /// Injection point for tests and alternate WebSocket implementations.
    init(
        task: any BurrowWebSocketTaskAdapter,
        codec: BurrowWireCodec = BurrowWireCodec()
    ) {
        self.url = nil
        self.session = nil
        self.codec = codec
        self.injectedTask = task
        let pair = AsyncThrowingStream<HostTransportEvent, Error>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    public nonisolated func events() -> AsyncThrowingStream<HostTransportEvent, Error> {
        eventStream
    }

    public func connect() async throws {
        switch lifecycle {
        case .connected:
            throw URLSessionWebSocketClientTransportError.alreadyConnected
        case .closed, .failed:
            throw URLSessionWebSocketClientTransportError.closed
        case .idle:
            break
        }

        let adapter: any BurrowWebSocketTaskAdapter
        if let injectedTask {
            adapter = injectedTask
        } else if let url, let session {
            adapter = URLSessionWebSocketTaskAdapter(task: session.webSocketTask(with: url))
        } else {
            throw URLSessionWebSocketClientTransportError.notConnected
        }
        taskAdapter = adapter
        lifecycle = .connected
        await adapter.resume()
        receiveTask = Task { [weak self, adapter] in
            await self?.runReceiveLoop(using: adapter)
        }
    }

    public func close() async {
        guard lifecycle != .closed else { return }
        lifecycle = .closed
        receiveTask?.cancel()
        receiveTask = nil
        let adapter = taskAdapter
        taskAdapter = nil
        eventContinuation?.finish()
        eventContinuation = nil
        await adapter?.cancel()
    }

    public func send(_ message: ClientControlMessage) async throws {
        guard lifecycle == .connected, let adapter = taskAdapter else {
            throw lifecycle == .closed
                ? URLSessionWebSocketClientTransportError.closed
                : URLSessionWebSocketClientTransportError.notConnected
        }

        do {
            let bytes = try codec.encodeControl(message)
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw BurrowWireCodecError.invalidUTF8
            }
            try await adapter.send(.text(text))
        } catch {
            await failTransport(with: error, adapter: adapter)
            throw error
        }
    }

    public func sendInput(metadata: InputMetadata, payload: Data) async throws {
        guard lifecycle == .connected, let adapter = taskAdapter else {
            throw lifecycle == .closed
                ? URLSessionWebSocketClientTransportError.closed
                : URLSessionWebSocketClientTransportError.notConnected
        }

        // Local validation errors do not poison a healthy connection. Only a
        // failed WebSocket send transitions the transport to `.failed`.
        let bytes = try codec.encodeInput(metadata: metadata, payload: payload)
        do {
            try await adapter.send(.binary(bytes))
        } catch {
            await failTransport(with: error, adapter: adapter)
            throw error
        }
    }

    private func runReceiveLoop(using adapter: any BurrowWebSocketTaskAdapter) async {
        do {
            while !Task.isCancelled {
                let message = try await adapter.receive()
                guard !Task.isCancelled, lifecycle == .connected else { return }
                let event: HostTransportEvent
                switch message {
                case .text(let text):
                    guard let bytes = text.data(using: .utf8) else {
                        throw BurrowWireCodecError.invalidUTF8
                    }
                    event = .control(try codec.decodeServerControl(Array(bytes)))
                case .binary(let bytes):
                    // A Client receives only Host output on this stream. The
                    // decoder checks the envelope direction and kind.
                    let decoded = try codec.decodeOutputFrame(bytes)
                    event = .binary(BinaryOutputFrame(
                        header: decoded.header,
                        payload: decoded.payload
                    ))
                }
                eventContinuation?.yield(event)
            }
        } catch {
            guard !Task.isCancelled, lifecycle == .connected else { return }
            await failTransport(with: error, adapter: adapter)
        }
    }

    private func failTransport(with error: Error, adapter: any BurrowWebSocketTaskAdapter) async {
        guard lifecycle == .connected else { return }
        lifecycle = .failed
        receiveTask = nil
        taskAdapter = nil
        eventContinuation?.finish(throwing: error)
        eventContinuation = nil
        await adapter.cancel()
    }
}
