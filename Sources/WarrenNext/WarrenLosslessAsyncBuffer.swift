import Foundation

/// A small lossless bridge around `AsyncStream`.
///
/// `AsyncStream`'s bounded policies normally drop an element when full. This
/// wrapper retries that same element after the consumer makes room, turning a
/// full buffer into backpressure instead of terminal-byte loss.
struct WarrenLosslessAsyncBuffer<Element: Sendable>: Sendable {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init(capacity: Int) {
        precondition(capacity > 0)
        let pair = AsyncStream<Element>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    func send(_ element: Element) async -> Bool {
        while !Task.isCancelled {
            switch continuation.yield(element) {
            case .enqueued:
                return true
            case .dropped:
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return false
                }
            case .terminated:
                return false
            @unknown default:
                return false
            }
        }
        return false
    }

    func finish() {
        continuation.finish()
    }
}
