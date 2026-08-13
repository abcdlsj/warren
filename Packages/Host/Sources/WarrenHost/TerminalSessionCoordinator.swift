import Foundation
import WarrenDomain
import WarrenProtocol

public enum HostRuntimeLifecycleEvent: Hashable, Sendable {
    case exited(sessionID: TerminalSessionID, exitCode: Int?)
}

/// Host 对 Terminal Session、Attachment 和 Control Lease 的唯一内存权威。
/// Attachment 的销毁不会触碰 runtime 中的 Session。
public actor TerminalSessionCoordinator {
    public static let defaultTerminalSize = TerminalSize(columns: 80, rows: 24)!

    package struct AttachmentState: Sendable {
        var attachment: TerminalAttachment
        var capabilities: ProtocolCapabilities
    }

    package struct SessionState: Sendable {
        var session: TerminalSession
        var attachments: [TerminalAttachmentID: AttachmentState]
        var controllerLease: ControlLease?
        var output: OutputRing
        var runtimeMetadata: TerminalRuntimeMetadata?
    }

    package let runtime: any TerminalRuntime
    package let outputCapacity: Int
    package let eventBufferCapacity: Int
    package let leaseDuration: TimeInterval
    package let clock: @Sendable () -> Date
    package var sessions: [TerminalSessionID: SessionState] = [:]

    /// One stream per attachment.  The stream is deliberately owned by the
    /// coordinator rather than by a transport so output publication remains
    /// tied to the Host session's actor-isolated state.  A transport may
    /// subscribe and detach without changing the runtime session lifetime.
    package var eventContinuations: [TerminalAttachmentID: AttachmentEventContinuation] = [:]

    /// Runtime output consumers are owned by the coordinator, one per Host
    /// session. They are cancelled independently from attachment streams so
    /// closing a Client transport never tears down the terminal runtime.
    package var runtimeEventTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    package var runtimeEventTokens: [TerminalSessionID: UUID] = [:]
    package var lifecycleEventContinuations: [
        UUID: AsyncStream<HostRuntimeLifecycleEvent>.Continuation
    ] = [:]

    public init(
        runtime: any TerminalRuntime,
        outputCapacity: Int = 256,
        eventBufferCapacity: Int = HostAttachmentChannel.eventBufferCapacity,
        leaseDuration: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(outputCapacity > 0, "Output ring capacity must be positive.")
        precondition(eventBufferCapacity > 0, "Attachment event buffer capacity must be positive.")
        precondition(leaseDuration > 0, "Control lease duration must be positive.")
        self.runtime = runtime
        self.outputCapacity = outputCapacity
        self.eventBufferCapacity = eventBufferCapacity
        self.leaseDuration = leaseDuration
        self.clock = clock
    }

    deinit {
        for task in runtimeEventTasks.values {
            task.cancel()
        }
        for subscription in eventContinuations.values {
            subscription.continuation.finish()
        }
        for continuation in lifecycleEventContinuations.values {
            continuation.finish()
        }
    }

    /// Host-level Runtime lifecycle facts. Unlike attachment streams, this
    /// stream exists so persistence can observe exits with no connected client.
    public func runtimeLifecycleEvents() -> AsyncStream<HostRuntimeLifecycleEvent> {
        let pair = AsyncStream<HostRuntimeLifecycleEvent>.makeStream()
        let token = UUID()
        lifecycleEventContinuations[token] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLifecycleEventContinuation(token) }
        }
        return pair.stream
    }

    private func removeLifecycleEventContinuation(_ token: UUID) {
        lifecycleEventContinuations.removeValue(forKey: token)
    }
}
