import Foundation

/// Actor-isolated wrapper around URLSession's task. The task never crosses the
/// adapter's isolation boundary, and the core codec only sees `[UInt8]`.
actor URLSessionWebSocketTaskAdapter: BurrowWebSocketTaskAdapter {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() async {
        task.resume()
    }

    func cancel() async {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func send(_ message: BurrowWebSocketMessage) async throws {
        switch message {
        case .text(let value):
            try await task.send(.string(value))
        case .binary(let value):
            try await task.send(.data(Data(value)))
        }
    }

    func receive() async throws -> BurrowWebSocketMessage {
        switch try await task.receive() {
        case .string(let value):
            return .text(value)
        case .data(let value):
            return .binary(Array(value))
        @unknown default:
            throw URLSessionWebSocketClientTransportError.invalidIncomingMessage
        }
    }
}
