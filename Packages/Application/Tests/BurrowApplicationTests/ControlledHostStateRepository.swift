import BurrowStateStore

actor ControlledHostStateRepository: HostStateRepository {
    private var state: PersistedHostState?
    private var shouldBlockNextSave = false
    private var blockedSaveContinuation: CheckedContinuation<Void, Never>?
    private var blockedSignal: AsyncStream<Void>.Continuation?

    init(initialState: PersistedHostState? = nil) {
        self.state = initialState
    }

    func load() async throws -> PersistedHostState {
        state ?? .empty
    }

    func save(_ state: PersistedHostState) async throws {
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            blockedSignal?.yield(())
            blockedSignal?.finish()
            blockedSignal = nil
            await withCheckedContinuation { continuation in
                blockedSaveContinuation = continuation
            }
        }
        self.state = state
    }

    func blockNextSave() -> AsyncStream<Void> {
        shouldBlockNextSave = true
        let pair = AsyncStream<Void>.makeStream()
        blockedSignal = pair.continuation
        return pair.stream
    }

    func resumeBlockedSave() {
        blockedSaveContinuation?.resume()
        blockedSaveContinuation = nil
    }
}
