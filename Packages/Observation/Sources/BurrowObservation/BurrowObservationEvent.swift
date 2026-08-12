import Foundation

public struct BurrowObservationContext: Codable, Hashable, Sendable {
    public let traceID: UUID
    public let requestID: UUID?
    public let windowID: String?
    public let workspaceID: String?
    public let sessionID: String?

    public init(
        traceID: UUID = UUID(),
        requestID: UUID? = nil,
        windowID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) {
        self.traceID = traceID
        self.requestID = requestID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

public enum BurrowObservationEventKind: String, Codable, Hashable, Sendable {
    case command
    case resource
    case layout
    case renderer
    case runtime
    case invariantViolation = "invariant_violation"
}

/// A privacy-safe event. Callers record identifiers and state names, never
/// terminal input, credentials, environment variables, or PTY payloads.
public struct BurrowObservationEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let kind: BurrowObservationEventKind
    public let name: String
    public let context: BurrowObservationContext
    public let previousState: String?
    public let nextState: String?
    public let result: String?
    public let errorCode: String?

    public init(
        id: UUID = UUID(),
        sequence: UInt64,
        timestampNanoseconds: UInt64,
        kind: BurrowObservationEventKind,
        name: String,
        context: BurrowObservationContext,
        previousState: String? = nil,
        nextState: String? = nil,
        result: String? = nil,
        errorCode: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.kind = kind
        self.name = name
        self.context = context
        self.previousState = previousState
        self.nextState = nextState
        self.result = result
        self.errorCode = errorCode
    }
}

public actor BurrowObservationLog {
    public typealias Clock = @Sendable () -> UInt64

    private let capacity: Int
    private let clock: Clock
    private var nextSequence: UInt64 = 0
    private var retained: [BurrowObservationEvent] = []

    public init(
        capacity: Int = 4_096,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds }
    ) {
        precondition(capacity > 0, "Observation capacity must be positive.")
        self.capacity = capacity
        self.clock = clock
    }

    @discardableResult
    public func record(
        kind: BurrowObservationEventKind,
        name: String,
        context: BurrowObservationContext = BurrowObservationContext(),
        previousState: String? = nil,
        nextState: String? = nil,
        result: String? = nil,
        errorCode: String? = nil
    ) -> BurrowObservationEvent {
        let event = BurrowObservationEvent(
            sequence: nextSequence,
            timestampNanoseconds: clock(),
            kind: kind,
            name: name,
            context: context,
            previousState: previousState,
            nextState: nextState,
            result: result,
            errorCode: errorCode
        )
        nextSequence &+= 1
        retained.append(event)
        if retained.count > capacity {
            retained.removeFirst(retained.count - capacity)
        }
        return event
    }

    public func events(since sequence: UInt64? = nil) -> [BurrowObservationEvent] {
        guard let sequence else { return retained }
        return retained.filter { $0.sequence >= sequence }
    }
}
