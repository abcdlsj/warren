import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenLocalTransport
import WarrenProtocol
import WarrenStateStore
import Foundation

/// The macOS composition boundary for one personal-use Warren instance.
///
/// This actor owns the embedded Host coordinator, the in-process transport,
/// durable Host state and every ClientSessionStore. It deliberately knows
/// nothing about SwiftUI, AppKit, SwiftTerm or a network listener.
public actor WarrenApplicationService {
    internal struct SessionConnection: Sendable {
        var session: TerminalSession
        let workspaceID: WorkspaceID
        var terminalSize: TerminalSize
        let descriptor: RuntimeAdoptionDescriptor?
        let store: ClientSessionStore
        var attachmentID: TerminalAttachmentID?
        var title: String
        var customTitle: String?
        var kind: TerminalSessionKind
    }

    internal struct AttachmentWaiter: Sendable {
        let sessionID: TerminalSessionID
        let attachmentID: TerminalAttachmentID
        let continuation: AsyncStream<Result<TerminalAttachmentID, WarrenApplicationError>>.Continuation
    }

    internal struct ControlWaiter: Sendable {
        let sessionID: TerminalSessionID
        let attachmentID: TerminalAttachmentID
        let continuation: AsyncStream<Result<Void, WarrenApplicationError>>.Continuation
    }

    internal let repository: any HostStateRepository
    internal let runtime: any TerminalRuntime
    internal let clientID: ClientID
    internal let hostName: String
    internal let clock: @Sendable () -> Date
    internal let gitMetadataReader: any GitMetadataReader
    internal let gitWorktreeManager: any GitWorktreeManaging
    internal let worktreeRootDirectory: URL
    internal let coordinator: TerminalSessionCoordinator
    internal var transport: InProcessHostTransport
    internal let persistenceGate = WarrenApplicationPersistenceGate()
    internal let layoutStore: ClientLayoutStore
    internal let windowID: ClientWindowID

    internal var state: PersistedHostState = .empty
    internal var host: WarrenDomain.Host = WarrenApplicationDefaults.localHost
    internal var lifecycle: WarrenApplicationLifecycle = .idle
    internal var issues: [WarrenApplicationIssue] = []
    internal var connections: [TerminalSessionID: SessionConnection] = [:]
    /// Explicit activity observed from an external Agent Conversation.
    internal var agentActivityBySessionID: [TerminalSessionID: AgentActivityState] = [:]
    /// Explicit open/attach requests share restoration work so concurrent
    /// clients cannot adopt the same runtime twice. Startup adopts every
    /// running Session for lifecycle observation, but only visible Tabs get an
    /// Attachment.
    internal var restorationTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    /// Coalesces repeated empty-Workspace selections while the first shell is
    /// still crossing runtime and persistence boundaries.
    internal var defaultTabTasks: [WorkspaceID: Task<String, Error>] = [:]
    internal var eventLoopTask: Task<Void, Never>?
    internal var runtimeLifecycleTask: Task<Void, Never>?
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
    internal var outputSnapshotCache: [TerminalSessionID: WarrenApplicationOutputSnapshot] = [:]
    internal var invalidatedOutputSessions: Set<TerminalSessionID> = []
    internal var snapshotContinuations: [UUID: AsyncStream<WarrenApplicationSnapshot>.Continuation] = [:]
    internal var attachmentWaiters: [UUID: AttachmentWaiter] = [:]
    internal var controlWaiters: [UUID: ControlWaiter] = [:]

    public init(
        repository: any HostStateRepository,
        runtime: any TerminalRuntime,
        clientID: ClientID = WarrenApplicationDefaults.localClientID,
        hostName: String = "Local Mac",
        clock: @escaping @Sendable () -> Date = { Date() },
        gitMetadataReader: any GitMetadataReader = NoopGitMetadataReader(),
        gitWorktreeManager: any GitWorktreeManaging = LocalGitWorktreeManager(),
        worktreeRootDirectory: URL = WarrenApplicationDefaults.worktreeRootDirectory()
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
        self.worktreeRootDirectory = worktreeRootDirectory.standardizedFileURL
        self.windowID = WarrenApplicationDefaults.mainWindowID
        self.layoutStore = try! ClientLayoutStore(
            clientID: clientID,
            defaultWindowID: WarrenApplicationDefaults.mainWindowID,
            repository: repository as? any ClientLayoutRepository
        )
        let eventBufferCapacity = Int(ProcessInfo.processInfo.environment["WARREN_EVENT_BUFFER_CAPACITY"] ?? "256") ?? 256
        let coordinator = TerminalSessionCoordinator(runtime: runtime, eventBufferCapacity: max(1, eventBufferCapacity), clock: clock)
        self.coordinator = coordinator
        self.transport = InProcessHostTransport(coordinator: coordinator)
    }

    deinit {
        eventLoopTask?.cancel()
        runtimeLifecycleTask?.cancel()
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
    public func snapshots() async -> AsyncStream<WarrenApplicationSnapshot> {
        let pair = AsyncStream<WarrenApplicationSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let token = UUID()
        snapshotContinuations[token] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotContinuation(token) }
        }
        pair.continuation.yield(await makeSnapshot())
        return pair.stream
    }

    public func snapshot() async -> WarrenApplicationSnapshot {
        await makeSnapshot()
    }

    /// Receives lifecycle events from an agent hook, automation runner, or a
    /// future remote Host. Views never infer this state from terminal text.
    public func reportAgentActivity(
        sessionID: TerminalSessionID,
        state activity: AgentActivityState?,
        agentSessionID: String? = nil
    ) async throws {
        try requireReady()
        guard let index = state.terminalSessions.firstIndex(where: { $0.id == sessionID }) else {
            throw WarrenApplicationError.sessionNotFound(sessionID)
        }
        if let value = agentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           state.terminalSessions[index].agentSessionID != value {
            try await withPersistenceMutation {
                try await repository.updateSessionAgent(sessionID: sessionID, agentSessionID: value)
                state.terminalSessions[index].agentSessionID = value
            }
        }
        agentActivityBySessionID[sessionID] = activity
        await publish()
    }

    /// Returns a copy for diagnostics and deterministic persistence tests.
    public func persistedState() -> PersistedHostState { state }

    /// Boots the local Host and recovers all runtime descriptors that still
    /// exist. Calling it twice is an actionable lifecycle error.
    public func start() async throws {
        guard lifecycle == .idle else {
            if lifecycle == .ready { throw WarrenApplicationError.alreadyStarted }
            throw WarrenApplicationError.invalidLifecycle(lifecycle)
        }
        lifecycle = .starting
        await publish()
        do {
            var loaded = try await repository.load()
            let (resolvedHost, _) = resolveLocalHost(in: &loaded)
            state = loaded
            host = resolvedHost
            try await repository.upsertHost(host)
            try await layoutStore.start()
            startEventLoop()
            await startRuntimeLifecycleLoop()
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
        runtimeLifecycleTask?.cancel()
        runtimeLifecycleTask = nil
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

extension WarrenApplicationService {
    internal func requireReady() throws {
        guard lifecycle == .ready else {
            if lifecycle == .idle { throw WarrenApplicationError.notStarted }
            throw WarrenApplicationError.invalidLifecycle(lifecycle)
        }
    }

    internal func appendIssue(_ issue: WarrenApplicationIssue) {
        issues.removeAll { $0.id == issue.id }
        issues.append(issue)
    }

    internal func report(_ error: WarrenApplicationError, id: String) {
        appendIssue(
            WarrenApplicationIssue(
                id: id,
                severity: .error,
                title: error.errorDescription ?? "Warren operation failed",
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
