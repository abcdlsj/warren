import Foundation
import BurrowDomain
import BurrowProtocol

public enum OutputRingError: Error, Codable, Hashable, Sendable {
    case emptyPayload
    case payloadTooLarge
}

/// One binary PTY output frame. The payload is deliberately kept as bytes;
/// terminal parsing belongs to a renderer, not to Host.
public struct TerminalOutputFrame: Hashable, Sendable {
    public let header: BinaryOutputFrameHeader
    public let payload: Data

    public var anchor: RecoveryAnchor {
        RecoveryAnchor(
            epoch: header.epoch,
            sequence: header.sequence + UInt64(header.payloadLength)
        )
    }

    fileprivate init(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        payload: Data
    ) throws {
        guard !payload.isEmpty else { throw OutputRingError.emptyPayload }
        guard UInt64(payload.count) <= UInt64.max - sequence else {
            throw OutputRingError.payloadTooLarge
        }
        self.header = BinaryOutputFrameHeader(
            sessionID: sessionID,
            epoch: epoch,
            sequence: sequence,
            payloadLength: payload.count
        )!
        self.payload = payload
    }
}

/// A bounded sequence interval retained by Host for reconnecting clients.
public struct OutputRing: Hashable, Sendable {
    public let capacity: Int
    public private(set) var epoch: UInt64

    private var retainedFrames: [TerminalOutputFrame]
    private var nextSequence: UInt64

    public init(epoch: UInt64 = 0, capacity: Int = 256, nextSequence: UInt64 = 0) {
        precondition(capacity > 0, "Output ring capacity must be positive.")
        self.capacity = capacity
        self.epoch = epoch
        self.retainedFrames = []
        self.nextSequence = nextSequence
    }

    public var lowerSequence: UInt64 {
        retainedFrames.first?.header.sequence ?? nextSequence
    }

    public var upperSequence: UInt64 { nextSequence }

    public var anchor: RecoveryAnchor {
        RecoveryAnchor(epoch: epoch, sequence: upperSequence)
    }

    public var frames: [TerminalOutputFrame] { retainedFrames }

    @discardableResult
    public mutating func append(
        sessionID: TerminalSessionID,
        payload: Data
    ) throws -> TerminalOutputFrame {
        guard !payload.isEmpty else { throw OutputRingError.emptyPayload }
        guard UInt64(payload.count) <= UInt64.max - nextSequence else {
            throw OutputRingError.payloadTooLarge
        }
        let sequence = nextSequence
        let frame = try TerminalOutputFrame(
            sessionID: sessionID,
            epoch: epoch,
            sequence: sequence,
            payload: payload
        )
        retainedFrames.append(frame)
        nextSequence = sequence + UInt64(payload.count)
        if retainedFrames.count > capacity {
            retainedFrames.removeFirst(retainedFrames.count - capacity)
        }
        return frame
    }

    public func plan(for anchor: RecoveryAnchor?) -> RecoveryPlan {
        RecoveryPlanner.plan(
            serverEpoch: epoch,
            bufferLowerSequence: lowerSequence,
            bufferUpperSequence: upperSequence,
            anchor: anchor
        )
    }

    /// Produces the bytes needed by a client, or the retained snapshot when a
    /// new epoch/evicted anchor requires re-anchoring.
    public func recovery(for anchor: RecoveryAnchor?) -> RecoveryResponse {
        let plan = plan(for: anchor)
        let selectedFrames: [TerminalOutputFrame]
        switch plan {
        case .exact:
            selectedFrames = []
        case .tail(let from):
            // Recovery anchors are byte offsets, not frame indexes.  If a
            // client reconnects in the middle of a retained chunk, trim that
            // first chunk so its header starts exactly at the requested byte.
            selectedFrames = retainedFrames.compactMap { frame in
                let frameStart = frame.header.sequence
                let frameEnd = frame.anchor.sequence
                guard frameEnd > from else { return nil }
                guard frameStart < from else { return frame }
                let offset = Int(from - frameStart)
                let payload = frame.payload.dropFirst(offset)
                return try? TerminalOutputFrame(
                    sessionID: frame.header.sessionID,
                    epoch: frame.header.epoch,
                    sequence: from,
                    payload: Data(payload)
                )
            }
        case .reanchor:
            selectedFrames = retainedFrames
        }
        return RecoveryResponse(
            plan: plan,
            epoch: epoch,
            lowerSequence: lowerSequence,
            upperSequence: upperSequence,
            frames: selectedFrames
        )
    }

    public mutating func reset(epoch: UInt64, nextSequence: UInt64 = 0) {
        self.epoch = epoch
        retainedFrames.removeAll(keepingCapacity: true)
        self.nextSequence = nextSequence
    }
}

public struct OutputRingSnapshot: Hashable, Sendable {
    public let epoch: UInt64
    public let lowerSequence: UInt64
    public let upperSequence: UInt64
    public let frames: [TerminalOutputFrame]

    public var anchor: RecoveryAnchor {
        RecoveryAnchor(epoch: epoch, sequence: upperSequence)
    }
}

public enum RecoveryResult: Hashable, Sendable {
    case snapshot(OutputRingSnapshot)
    case catchUp(OutputRingSnapshot)
    case reanchor(OutputRingSnapshot)
}

public struct RecoveryResponse: Hashable, Sendable {
    public let plan: RecoveryPlan
    public let epoch: UInt64
    public let lowerSequence: UInt64
    public let upperSequence: UInt64
    public let frames: [TerminalOutputFrame]

    public var anchor: RecoveryAnchor {
        RecoveryAnchor(epoch: epoch, sequence: upperSequence)
    }

    public var snapshot: OutputRingSnapshot {
        OutputRingSnapshot(
            epoch: epoch,
            lowerSequence: lowerSequence,
            upperSequence: upperSequence,
            frames: frames
        )
    }

    public var result: RecoveryResult {
        switch plan {
        case .exact:
            return .snapshot(snapshot)
        case .tail:
            return .catchUp(snapshot)
        case .reanchor:
            return .reanchor(snapshot)
        }
    }
}
