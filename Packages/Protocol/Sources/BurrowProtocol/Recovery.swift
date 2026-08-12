import BurrowDomain

public enum RecoveryPlan: Hashable, Sendable {
    case exact
    case tail(from: UInt64)
    case reanchor
}

/// Plans recovery against a retained sequence interval [lower, upper).
public enum RecoveryPlanner {
    /// `anchor.sequence` is the next sequence the client needs. Therefore an
    /// anchor equal to `upper` is already synchronized, while an anchor inside
    /// the retained interval can be served from the buffer.
    public static func plan(
        serverEpoch: UInt64,
        bufferLowerSequence: UInt64,
        bufferUpperSequence: UInt64,
        anchor: RecoveryAnchor?
    ) -> RecoveryPlan {
        guard let anchor,
              bufferLowerSequence <= bufferUpperSequence,
              anchor.epoch == serverEpoch else {
            return .reanchor
        }

        if anchor.sequence == bufferUpperSequence {
            return .exact
        }

        guard anchor.sequence >= bufferLowerSequence,
              anchor.sequence < bufferUpperSequence else {
            return .reanchor
        }

        return .tail(from: anchor.sequence)
    }
}
