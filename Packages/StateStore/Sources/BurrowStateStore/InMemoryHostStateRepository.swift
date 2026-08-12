/// An actor repository for deterministic Host lifecycle tests and previews.
public actor InMemoryHostStateRepository: HostStateRepository {
    private var state: PersistedHostState?

    public init(initialState: PersistedHostState? = nil) {
        self.state = initialState
    }

    public func load() async throws -> PersistedHostState {
        if let state {
            try HostStateRepositoryError.validateSupportedSchema(state)
            return state
        }
        return .empty
    }

    public func save(_ state: PersistedHostState) async throws {
        try HostStateRepositoryError.validateSupportedSchema(state)
        self.state = state
    }
}
