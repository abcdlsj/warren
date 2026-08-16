import Foundation

struct WarrenTerminalOutputSlice: Equatable, Sendable {
    let epoch: UInt64
    let sequence: UInt64
    let payload: Data

    var endSequence: UInt64 {
        sequence + UInt64(payload.count)
    }
}

/// Ordered, append-only bytes waiting to be fed into one terminal surface.
///
/// The buffer remembers the sequence already enqueued, so repeated immutable
/// snapshots cannot append the same PTY bytes twice while an earlier batch is
/// still being rendered.
struct WarrenTerminalOutputBuffer: Sendable {
    private struct Chunk: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let payload: Data
    }

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

    mutating func take(maxBytes: Int) -> WarrenTerminalOutputSlice? {
        precondition(maxBytes > 0)
        guard !isEmpty else { return nil }
        let chunk = chunks[headIndex]
        let count = min(maxBytes, chunk.payload.count - headOffset)
        let start = headOffset
        let end = start + count
        let payload = start == 0 && end == chunk.payload.count
            ? chunk.payload
            : Data(chunk.payload[start..<end])
        let slice = WarrenTerminalOutputSlice(
            epoch: chunk.epoch,
            sequence: chunk.sequence + UInt64(start),
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
