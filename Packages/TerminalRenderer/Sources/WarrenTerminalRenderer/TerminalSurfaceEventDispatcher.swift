import Foundation

/// Serializes SwiftTerm delegate callbacks onto an async sink.
///
/// SwiftTerm normally calls delegates synchronously, while the transport is
/// async. A single task tail preserves the order of every observed callback
/// without retaining completed tasks. UIKit may also report layout changes on
/// a later run-loop turn; consumers must therefore treat the sink as eventual,
/// ordered delivery rather than infer that no later resize can be emitted.
@MainActor
public final class TerminalSurfaceEventDispatcher {
    private let sink: @Sendable (TerminalSurfaceEvent) async -> Void
    private var tail: Task<Void, Never>?
    private var tailID: UInt64?
    private var nextID: UInt64 = 0
    private var pending: [UInt64: Task<Void, Never>] = [:]

    public init(sink: @escaping @Sendable (TerminalSurfaceEvent) async -> Void) {
        self.sink = sink
    }

    public func enqueue(_ event: TerminalSurfaceEvent) {
        let previous = tail
        nextID &+= 1
        let eventID = nextID
        let sink = sink
        let current = Task { @MainActor [weak self, previous] in
            defer { self?.finish(eventID: eventID) }
            await previous?.value
            guard !Task.isCancelled else { return }
            await sink(event)
        }
        tail = current
        tailID = eventID
        pending[eventID] = current
    }

    public func drain() async {
        await tail?.value
    }

    public func cancel() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        tail = nil
        tailID = nil
    }

    deinit {
        pending.values.forEach { $0.cancel() }
    }

    private func finish(eventID: UInt64) {
        pending.removeValue(forKey: eventID)
        if tailID == eventID {
            tail = nil
            tailID = nil
        }
    }
}
