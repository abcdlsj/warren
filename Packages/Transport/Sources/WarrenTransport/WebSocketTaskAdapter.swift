/// The transport's small message vocabulary keeps URLSession details at the
/// edge. Control is always text; PTY output is always binary.
enum WarrenWebSocketMessage: Hashable, Sendable {
    case text(String)
    case binary([UInt8])
}

/// The minimum surface needed by the client transport. All calls are async so
/// scripted actors and URLSession actors have the same isolation boundary.
protocol WarrenWebSocketTaskAdapter: Sendable {
    func resume() async
    func cancel() async
    func send(_ message: WarrenWebSocketMessage) async throws
    func receive() async throws -> WarrenWebSocketMessage
}
