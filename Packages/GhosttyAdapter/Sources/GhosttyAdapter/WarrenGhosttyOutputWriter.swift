import Foundation
import GhosttyTerminal

/// Feeds Host output into one Ghostty surface off the main thread.
///
/// Ghostty's own terminal reads PTY bytes on a background termio thread and
/// only hops to the main thread to present. Warren's renderer previously
/// forwarded every output chunk on the main actor, so a streaming agent
/// saturated the same thread that also handles trackpad scroll events —
/// scroll input had to wait behind ANSI parsing. This writer keeps an ordered
/// pending buffer and drains it on a utility-priority detached task, matching
/// Ghostty's real-world input-to-render pipeline.
public final class WarrenGhosttyOutputWriter: @unchecked Sendable {
    private struct Chunk: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let payload: Data
    }

    private struct Slice: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let endSequence: UInt64
        let payload: Data
    }

    private struct Buffer {
        private(set) var epoch: UInt64?
        private(set) var enqueuedSequence: UInt64 = 0
        private var chunks: [Chunk] = []
        private var headIndex = 0
        private var headOffset = 0

        var isEmpty: Bool { headIndex >= chunks.count }

        mutating func reset(epoch: UInt64, sequence: UInt64) {
            self.epoch = epoch
            enqueuedSequence = sequence
            chunks.removeAll(keepingCapacity: true)
            headIndex = 0
            headOffset = 0
        }

        mutating func append(epoch: UInt64, sequence: UInt64, payload: Data) {
            guard !payload.isEmpty,
                  UInt64(payload.count) <= UInt64.max - sequence else { return }
            if self.epoch != epoch {
                reset(epoch: epoch, sequence: 0)
            }
            let end = sequence + UInt64(payload.count)
            guard end > enqueuedSequence else { return }
            let offset = sequence < enqueuedSequence
                ? Int(enqueuedSequence - sequence)
                : 0
            let retained = offset == 0 ? payload : Data(payload.dropFirst(offset))
            chunks.append(Chunk(
                epoch: epoch,
                sequence: sequence + UInt64(offset),
                payload: retained
            ))
            enqueuedSequence = end
        }

        mutating func take(maxBytes: Int) -> Slice? {
            precondition(maxBytes > 0)
            guard !isEmpty else { return nil }
            let chunk = chunks[headIndex]
            let count = min(maxBytes, chunk.payload.count - headOffset)
            let start = headOffset
            let end = start + count
            let payload = start == 0 && end == chunk.payload.count
                ? chunk.payload
                : Data(chunk.payload[start..<end])
            let slice = Slice(
                epoch: chunk.epoch,
                sequence: chunk.sequence + UInt64(start),
                endSequence: chunk.sequence + UInt64(end),
                payload: payload
            )
            headOffset = end
            if headOffset == chunk.payload.count {
                headIndex += 1
                headOffset = 0
                compactIfNeeded()
            }
            return slice
        }

        private mutating func compactIfNeeded() {
            guard headIndex >= 32, headIndex * 2 >= chunks.count else { return }
            chunks.removeFirst(headIndex)
            headIndex = 0
        }
    }

    private let lock = NSLock()
    private let inMemory: InMemoryTerminalSession
    private let ansiObserver: TerminalANSIObserver
    private let budgetBytes: Int
    private let yield: Duration
    private var buffer = Buffer()
    private var feedTask: Task<Void, Never>?
    private var latestRenderedEpoch: UInt64 = 0
    private var latestRenderedSequence: UInt64 = 0
    private var rawEpoch: UInt64 = 1
    private var rawSequence: UInt64 = 0
    private var onDrained: (@Sendable () -> Void)?

    init(
        inMemory: InMemoryTerminalSession,
        ansiObserver: TerminalANSIObserver,
        budgetBytes: Int = 128 * 1024,
        yield: Duration = .milliseconds(8)
    ) {
        precondition(budgetBytes > 0)
        self.inMemory = inMemory
        self.ansiObserver = ansiObserver
        self.budgetBytes = budgetBytes
        self.yield = yield
    }

    deinit {
        feedTask?.cancel()
    }

    /// Epoch of the output currently buffered, if any.
    public var bufferEpoch: UInt64? {
        lock.withLock { buffer.epoch }
    }

    /// Highest sequence already enqueued into the pending buffer.
    public var enqueuedSequence: UInt64 {
        lock.withLock { buffer.enqueuedSequence }
    }

    /// Last (epoch, sequence) actually written into Ghostty.
    public var renderedEpoch: UInt64 {
        lock.withLock { latestRenderedEpoch }
    }

    public var renderedSequence: UInt64 {
        lock.withLock { latestRenderedSequence }
    }

    /// Drops pending bytes and restarts the recovery anchor. Safe to call
    /// while a feed is in flight; the next enqueue starts a fresh drain.
    public func reset(epoch: UInt64, sequence: UInt64) {
        lock.withLock {
            buffer.reset(epoch: epoch, sequence: sequence)
        }
    }

    /// Records that Ghostty has consumed bytes through `sequence` for `epoch`.
    public func markRendered(epoch: UInt64, sequence: UInt64) {
        lock.withLock {
            latestRenderedEpoch = epoch
            latestRenderedSequence = sequence
        }
    }

    /// Enqueues a framed output payload and drains it on the background task.
    public func enqueue(epoch: UInt64, sequence: UInt64, payload: Data) {
        lock.withLock {
            buffer.append(epoch: epoch, sequence: sequence, payload: payload)
        }
        startFeedIfNeeded()
    }

    /// Enqueues raw Host bytes for transports without DENB frame metadata.
    /// All raw bytes share one synthetic epoch so ordering is preserved.
    public func enqueueRaw(_ payload: Data) {
        guard !payload.isEmpty else { return }
        let sequence = lock.withLock { () -> UInt64 in
            let sequence = max(rawSequence, buffer.enqueuedSequence)
            rawSequence = sequence &+ UInt64(payload.count)
            return sequence
        }
        enqueue(epoch: rawEpoch, sequence: sequence, payload: payload)
    }

    /// Writes bytes into Ghostty synchronously (used by tests and initial
    /// snapshots where ordering with in-flight feed work is not a concern).
    public func receive(_ payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        ansiObserver.receive(payload)
        inMemory.receive(payload)
    }

    /// Cancels the background feed and drops pending bytes.
    public func shutdown() {
        lock.lock()
        feedTask?.cancel()
        feedTask = nil
        buffer = Buffer()
        onDrained = nil
        lock.unlock()
    }

    /// Registers a callback fired when the background feed finishes draining
    /// the pending buffer. Called off the main thread; hop to the main actor
    /// before touching UI state.
    public func setOnDrained(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            onDrained = handler
        }
    }

    private func startFeedIfNeeded() {
        lock.lock()
        guard feedTask == nil, !buffer.isEmpty else {
            lock.unlock()
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drain()
        }
        feedTask = task
        lock.unlock()
    }

    private func drain() async {
        while !Task.isCancelled {
            let slice: Slice? = lock.withLock {
                buffer.take(maxBytes: budgetBytes)
            }
            guard let slice else {
                lock.withLock { feedTask = nil }
                return
            }

            lock.withLock {
                ansiObserver.receive(slice.payload)
                inMemory.receive(slice.payload)
                latestRenderedEpoch = slice.epoch
                latestRenderedSequence = slice.endSequence
            }

            let hasMore = lock.withLock { !buffer.isEmpty }
            if !hasMore {
                let handler = lock.withLock { () -> (@Sendable () -> Void)? in
                    feedTask = nil
                    return onDrained
                }
                handler?()
                return
            }
            do {
                try await Task.sleep(for: yield)
            } catch {
                lock.withLock { feedTask = nil }
                return
            }
        }
        lock.withLock { feedTask = nil }
    }
}
