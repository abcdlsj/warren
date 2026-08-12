import BurrowClientCore
import BurrowDomain
import BurrowHost
import BurrowLocalTransport
import BurrowProtocol
import BurrowStateStore
import Foundation

/// The macOS composition boundary for one personal-use Burrow instance.
///
/// This actor owns the embedded Host coordinator, the in-process transport,
/// durable Host state and every ClientSessionStore. It deliberately knows
/// nothing about SwiftUI, AppKit, SwiftTerm or a network listener.
public actor BurrowApplicationService {
    internal struct SessionConnection: Sendable {
        var session: TerminalSession
        let workspaceID: WorkspaceID
        let tabID: String
        var terminalSize: TerminalSize
        let descriptor: RuntimeAdoptionDescriptor?
        let store: ClientSessionStore
        var attachmentID: TerminalAttachmentID?
        var title: String
        var kind: TerminalSessionKind
        var runtimeEnded: Bool
    }

    internal struct AttachmentWaiter: Sendable {
        let sessionID: TerminalSessionID
        let attachmentID: TerminalAttachmentID
        let continuation: AsyncStream<Result<TerminalAttachmentID, BurrowApplicationError>>.Continuation
    }

    internal struct ControlWaiter: Sendable {
        let sessionID: TerminalSessionID
        let attachmentID: TerminalAttachmentID
        let continuation: AsyncStream<Result<Void, BurrowApplicationError>>.Continuation
    }

    internal let repository: any HostStateRepository
    internal let runtime: any TerminalRuntime
    internal let clientID: ClientID
    internal let hostName: String
    internal let clock: @Sendable () -> Date
    internal let gitMetadataReader: any GitMetadataReader
    internal let gitWorktreeManager: any GitWorktreeManaging
    internal let coordinator: TerminalSessionCoordinator
    internal let transport: InProcessHostTransport
    internal let persistenceGate = BurrowApplicationPersistenceGate()
    internal let layoutStore: ClientLayoutStore
    internal let windowID: ClientWindowID

    internal var state: PersistedHostState = .empty
    internal var host: BurrowDomain.Host = BurrowApplicationDefaults.localHost
    internal var lifecycle: BurrowApplicationLifecycle = .idle
    internal var issues: [BurrowApplicationIssue] = []
    internal var connections: [TerminalSessionID: SessionConnection] = [:]
    /// Closed tabs and headless CLI sessions remain durable but are not
    /// eagerly adopted on every desktop launch. Explicit open/attach requests
    /// restore them through this shared task so concurrent clients cannot
    /// adopt the same runtime twice.
    internal var restorationTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    /// Coalesces repeated empty-Workspace selections while the first shell is
    /// still crossing runtime and persistence boundaries.
    internal var defaultTabTasks: [WorkspaceID: Task<String, Error>] = [:]
    internal var eventLoopTask: Task<Void, Never>?
    /// PTY output can arrive much faster than the desktop needs to redraw.
    /// Keep one scheduled publication for a burst instead of rebuilding the
    /// complete value snapshot for every frame.
    internal var pendingOutputSessions: Set<TerminalSessionID> = []
    internal var outputPublishTask: Task<Void, Never>?
    /// The in-memory cursor advances immediately, while durable cursor writes
    /// are coalesced.  A stale cursor is safe on adoption because the runtime
    /// replays the retained spool tail.
    internal var pendingSequenceAnchors: [TerminalSessionID: RecoveryAnchor] = [:]
    internal var sequencePersistenceTask: Task<Void, Never>?
    internal var outputSnapshotCache: [TerminalSessionID: BurrowApplicationOutputSnapshot] = [:]
    internal var invalidatedOutputSessions: Set<TerminalSessionID> = []
    internal var snapshotContinuations: [UUID: AsyncStream<BurrowApplicationSnapshot>.Continuation] = [:]
    internal var attachmentWaiters: [UUID: AttachmentWaiter] = [:]
    internal var controlWaiters: [UUID: ControlWaiter] = [:]

    public init(
        repository: any HostStateRepository,
        runtime: any TerminalRuntime,
        clientID: ClientID = BurrowApplicationDefaults.localClientID,
        hostName: String = "Local Mac",
        clock: @escaping @Sendable () -> Date = { Date() },
        gitMetadataReader: any GitMetadataReader = NoopGitMetadataReader(),
        gitWorktreeManager: any GitWorktreeManaging = LocalGitWorktreeManager()
    ) {
        self.repository = repository
        self.runtime = runtime
        self.clientID = clientID
        self.hostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Local Mac"
            : hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clock = clock
        self.gitMetadataReader = gitMetadataReader
        self.gitWorktreeManager = gitWorktreeManager
        self.windowID = BurrowApplicationDefaults.mainWindowID
        self.layoutStore = try! ClientLayoutStore(
            clientID: clientID,
            defaultWindowID: BurrowApplicationDefaults.mainWindowID,
            repository: repository as? any ClientLayoutRepository
        )
        let coordinator = TerminalSessionCoordinator(runtime: runtime, clock: clock)
        self.coordinator = coordinator
        self.transport = InProcessHostTransport(coordinator: coordinator)
    }

    deinit {
        eventLoopTask?.cancel()
        outputPublishTask?.cancel()
        sequencePersistenceTask?.cancel()
        for task in defaultTabTasks.values { task.cancel() }
        for waiter in attachmentWaiters.values {
            waiter.continuation.yield(.failure(.transport("The application service was released.")))
            waiter.continuation.finish()
        }
        for waiter in controlWaiters.values {
            waiter.continuation.yield(.failure(.transport("The application service was released.")))
            waiter.continuation.finish()
        }
    }

    /// A value-only stream for an eventual `@Observable` composition model.
    public func snapshots() async -> AsyncStream<BurrowApplicationSnapshot> {
        let pair = AsyncStream<BurrowApplicationSnapshot>.makeStream()
        let token = UUID()
        snapshotContinuations[token] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotContinuation(token) }
        }
        pair.continuation.yield(await makeSnapshot())
        return pair.stream
    }

    public func snapshot() async -> BurrowApplicationSnapshot {
        await makeSnapshot()
    }

    /// Returns a copy for diagnostics and deterministic persistence tests.
    public func persistedState() -> PersistedHostState { state }

    /// Boots the local Host and recovers all runtime descriptors that still
    /// exist. Calling it twice is an actionable lifecycle error.
    public func start() async throws {
        guard lifecycle == .idle else {
            if lifecycle == .ready { throw BurrowApplicationError.alreadyStarted }
            throw BurrowApplicationError.invalidLifecycle(lifecycle)
        }
        lifecycle = .starting
        await publish()
        do {
            var loaded = try await repository.load()
            var didMigrate = false
            migrateSchemaIfNeeded(&loaded, didMigrate: &didMigrate)
            let (resolvedHost, changed) = resolveLocalHost(in: &loaded)
            state = loaded
            host = resolvedHost
            if changed || didMigrate { try await save(loaded) }
            try await layoutStore.start()
            startEventLoop()
            await restorePersistedSessions()
            lifecycle = .ready
            await publish()
        } catch {
            lifecycle = .failed
            let appError = error.asApplicationError
            appendIssue(appError.issue)
            await publish()
            throw appError
        }
    }

    private func migrateSchemaIfNeeded(
        _ state: inout PersistedHostState,
        didMigrate: inout Bool
    ) {
        guard state.schemaVersion < PersistedHostState.currentSchemaVersion else { return }
        state.schemaVersion = PersistedHostState.currentSchemaVersion
        didMigrate = true
    }

    /// Naming used by composition roots that treat startup as bootstrap.
    public func bootstrap() async throws { try await start() }

    public func shutdown() async {
        guard lifecycle != .idle else { return }
        lifecycle = .stopping
        for task in restorationTasks.values { task.cancel() }
        restorationTasks.removeAll()
        for task in defaultTabTasks.values { task.cancel() }
        defaultTabTasks.removeAll()
        eventLoopTask?.cancel()
        eventLoopTask = nil
        outputPublishTask?.cancel()
        outputPublishTask = nil
        sequencePersistenceTask?.cancel()
        sequencePersistenceTask = nil
        await flushPendingSequencePersistence()
        await transport.close()
        for connection in connections.values {
            await coordinator.detachRuntimeStream(sessionID: connection.session.id)
            await connection.store.markDisconnected()
        }
        resolveAllWaiters(with: .failure(.transport("The application service was closed.")))
        await publish()
    }
}

extension BurrowApplicationService {
    internal func requireReady() throws {
        guard lifecycle == .ready else {
            if lifecycle == .idle { throw BurrowApplicationError.notStarted }
            throw BurrowApplicationError.invalidLifecycle(lifecycle)
        }
    }

    internal func appendIssue(_ issue: BurrowApplicationIssue) {
        issues.removeAll { $0.id == issue.id }
        issues.append(issue)
    }

    internal func report(_ error: BurrowApplicationError, id: String) {
        appendIssue(
            BurrowApplicationIssue(
                id: id,
                severity: .error,
                title: error.errorDescription ?? "Burrow operation failed",
                detail: String(describing: error),
                recoverySuggestion: error.recoverySuggestion ?? "Please try again."
            )
        )
    }

    internal func publish() async {
        // A control/state publication already carries the latest output.  Do
        // not let the delayed output task publish the same value again.
        if !pendingOutputSessions.isEmpty {
            pendingOutputSessions.removeAll()
            outputPublishTask?.cancel()
            outputPublishTask = nil
        }
        let value = await makeSnapshot()
        for continuation in snapshotContinuations.values { continuation.yield(value) }
    }

    internal func removeSnapshotContinuation(_ token: UUID) {
        snapshotContinuations.removeValue(forKey: token)
    }
}
