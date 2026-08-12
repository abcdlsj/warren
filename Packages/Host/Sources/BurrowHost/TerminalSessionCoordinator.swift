import Foundation
import BurrowDomain
import BurrowProtocol

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
    }

    package let runtime: any TerminalRuntime
    package let outputCapacity: Int
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

    public init(
        runtime: any TerminalRuntime,
        outputCapacity: Int = 256,
        leaseDuration: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(outputCapacity > 0, "Output ring capacity must be positive.")
        precondition(leaseDuration > 0, "Control lease duration must be positive.")
        self.runtime = runtime
        self.outputCapacity = outputCapacity
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
    }
}
