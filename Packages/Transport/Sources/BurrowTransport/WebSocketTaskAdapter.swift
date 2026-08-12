/// The transport's small message vocabulary keeps URLSession details at the
/// edge. Control is always text; PTY output is always binary.
enum BurrowWebSocketMessage: Hashable, Sendable {
    case text(String)
    case binary([UInt8])
}

/// The minimum surface needed by the client transport. All calls are async so
/// scripted actors and URLSession actors have the same isolation boundary.
protocol BurrowWebSocketTaskAdapter: Sendable {
    func resume() async
    func cancel() async
    func send(_ message: BurrowWebSocketMessage) async throws
    func receive() async throws -> BurrowWebSocketMessage
}
