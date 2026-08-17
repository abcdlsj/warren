import Foundation

/// Preserves callback order before terminal input crosses into Swift concurrency.
///
/// Ghostty emits bracketed paste as separate start, payload, and end writes.
/// Creating one unstructured task per write can reorder those fenceposts, so
/// callbacks append synchronously here and a single task drains them in FIFO
/// order on the main actor.
final class WarrenOrderedInputBridge: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (Data) async -> Void

    private let lock = NSLock()
    private let sink: Sink
    private var pending = Data()
    private var isDrainScheduled = false

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        pending.append(data)
        let shouldSchedule = !isDrainScheduled
        if shouldSchedule {
            isDrainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    @MainActor
    private func drain() async {
        while let data = takePending() {
            await sink(data)
        }
    }

    private func takePending() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard !pending.isEmpty else {
            isDrainScheduled = false
            return nil
        }
        let data = pending
        pending.removeAll(keepingCapacity: true)
        return data
    }
}
