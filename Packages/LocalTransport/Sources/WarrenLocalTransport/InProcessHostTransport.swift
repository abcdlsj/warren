import Foundation
import WarrenClientCore
import WarrenDomain
import WarrenHost
import WarrenProtocol

public enum InProcessHostTransportError: Error, Equatable, Sendable {
    /// The caller opted into a bounded event queue and it overflowed.  The
    /// stream is terminated so the client can reattach and recover from the
    /// Host OutputRing instead of consuming a silently corrupted projection.
    case eventBufferOverflow
}

/// A HostTransport backed by an embedded Host in the same process.
///
/// There is no listener, discovery, account, or shared mutable registry here:
/// the application constructs one transport with the coordinator it owns.
/// Keeping this type behind `HostTransport` leaves room for another adapter in
/// a future product without making a local personal-use app depend on it.
public actor InProcessHostTransport: HostTransport {
    private struct AttachmentRecord: Sendable {
        let sessionID: TerminalSessionID
        let taskToken: UUID
        var pump: Task<Void, Never>?
    }

    private let coordinator: TerminalSessionCoordinator
    private let eventStream: AsyncThrowingStream<HostTransportEvent, Error>
    private var eventContinuation: AsyncThrowingStream<HostTransportEvent, Error>.Continuation?
    private var attachments: [TerminalAttachmentID: AttachmentRecord] = [:]
    private var closed = false

    /// `eventBufferCapacity` bounds the client-facing queue.  The Host's
    /// OutputRing remains the recovery authority when a slow consumer causes
    /// a stream item to be dropped.
    public init(
        coordinator: TerminalSessionCoordinator,
        eventBufferCapacity: Int? = nil
    ) {
        if let eventBufferCapacity {
            precondition(eventBufferCapacity > 0, "The local transport event buffer must be positive.")
        }
        self.coordinator = coordinator
        let pair: (
            stream: AsyncThrowingStream<HostTransportEvent, Error>,
            continuation: AsyncThrowingStream<HostTransportEvent, Error>.Continuation
        )
        if let eventBufferCapacity {
            // This opt-in bounded mode is primarily useful for stress tests.
            // Production uses the default unbounded mode so control messages
            // can never be silently dropped behind a burst of PTY output.
            pair = AsyncThrowingStream<HostTransportEvent, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(eventBufferCapacity)
            )
        } else {
            pair = AsyncThrowingStream<HostTransportEvent, Error>.makeStream()
        }
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation

        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.close() }
        }
    }

    deinit {
        // The app normally calls `close()`.  Cancellation of the event stream
        // reaches close through `onTermination`; this fallback only finishes
        // the local queue and never performs actor-isolated Host work.
        let current = attachments
        for record in current.values {
            record.pump?.cancel()
        }
        let coordinator = coordinator
        Task {
            for (attachmentID, record) in current {
                _ = try? await coordinator.detach(DetachRequest(
                    sessionID: record.sessionID,
                    attachmentID: attachmentID,
                    reason: "transport_deallocated"
                ))
            }
        }
        eventContinuation?.finish()
    }

    public nonisolated func events() -> AsyncThrowingStream<HostTransportEvent, Error> {
        eventStream
    }

    /// Routes a control message to the Host coordinator.  Protocol failures
    /// are emitted as structured `.error` events, matching the wire contract;
    /// only transport/lifecycle failures are thrown to the caller.
    public func send(_ message: ClientControlMessage) async throws {
        try ensureOpen()

        switch message {
        case .attach(let request):
            do {
                try await attach(request)
            } catch let error as ProtocolError {
                emit(error, sessionID: request.sessionID, attachmentID: request.attachmentID)
            }

        case .resize(let request):
            do {
                try await coordinator.resize(request)
            } catch let error as ProtocolError {
                emit(error, sessionID: request.sessionID, attachmentID: request.attachmentID)
            }

        case .focus(let request):
            // Focus is intentionally client-local in protocol 1.0.  Validate
            // the attachment so a stale UI cannot silently target another
            // session; no fake Host state or acknowledgement is manufactured.
            do {
                try await coordinator.validateAttachment(
                    sessionID: request.sessionID,
                    attachmentID: request.attachmentID,
                    version: request.version
                )
            } catch let error as ProtocolError {
                emit(error, sessionID: request.sessionID, attachmentID: request.attachmentID)
            }

        case .requestControl(let request):
            do {
                _ = try await coordinator.requestControl(request)
            } catch let error as ProtocolError {
                emit(error, sessionID: request.sessionID, attachmentID: request.attachmentID)
            }

        case .releaseControl(let request):
            do {
                try await coordinator.releaseControl(request)
            } catch let error as ProtocolError {
                emit(error, sessionID: request.sessionID, attachmentID: request.attachmentID)
            }

        case .detach(let request):
            do {
                try await detach(request)
            } catch let error as ProtocolError {
                emit(error, sessionID: request.sessionID, attachmentID: request.attachmentID)
            }
        }
    }

    /// Routes terminal input as bytes.  A successful call means the Host has
    /// accepted the write; the runtime's eventual output arrives on `events`.
    public func sendInput(metadata: InputMetadata, payload: Data) async throws {
        try ensureOpen()
        guard metadata.payloadLength == payload.count else {
            throw HostTransportError.inputPayloadLengthMismatch(
                expected: metadata.payloadLength,
                actual: payload.count
            )
        }
        do {
            try await coordinator.input(metadata, data: payload)
        } catch let error as ProtocolError {
            emit(error, sessionID: metadata.sessionID, attachmentID: metadata.attachmentID)
        }
    }

    /// Releases subscriptions and attachments while leaving every Host
    /// TerminalSession and its runtime process untouched.
    public func close() async {
        guard !closed else { return }
        closed = true

        let current = attachments
        attachments.removeAll(keepingCapacity: false)
        for record in current.values {
            record.pump?.cancel()
        }

        for (attachmentID, record) in current {
            let request = DetachRequest(
                sessionID: record.sessionID,
                attachmentID: attachmentID,
                reason: "transport_closed"
            )
            // A close is best effort.  The transport has already stopped
            // exposing events and must not keep a Host actor alive waiting for
            // an error from a stale attachment.
            _ = try? await coordinator.detach(request)
        }

        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func ensureOpen() throws {
        guard !closed else { throw HostTransportError.closed }
    }

    private func attach(_ request: AttachRequest) async throws {
        let channel = try await coordinator.attachAndSubscribe(request)
        let attachmentID = channel.result.attachmentID

        if let previous = attachments.removeValue(forKey: attachmentID) {
            previous.pump?.cancel()
        }

        let token = UUID()
        let task = Task { [weak self, stream = channel.events] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.forward(event)
            }
            await self?.subscriptionEnded(
                attachmentID: attachmentID,
                taskToken: token
            )
        }
        attachments[attachmentID] = AttachmentRecord(
            sessionID: channel.result.sessionID,
            taskToken: token,
            pump: task
        )
    }

    private func detach(_ request: DetachRequest) async throws {
        _ = try await coordinator.detach(request)
        attachments.removeValue(forKey: request.attachmentID)?.pump?.cancel()
    }

    private func forward(_ event: HostSessionEvent) {
        guard !closed else { return }
        switch event {
        case .control(let message):
            yield(.control(message))
        case .binary(let frame):
            yield(.binary(
                BinaryOutputFrame(header: frame.header, payload: frame.payload)
            ))
        }
    }

    private func emit(
        _ error: ProtocolError,
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID?
    ) {
        guard !closed else { return }
        let routed = ProtocolError(
            version: error.version,
            sessionID: error.sessionID ?? sessionID,
            code: error.code,
            message: error.message,
            retryable: error.retryable
        ) ?? error
        yield(.control(.error(routed)))
    }

    private func yield(_ event: HostTransportEvent) {
        guard !closed else { return }
        let result = eventContinuation?.yield(event) ?? .terminated
        if case .dropped = result {
            // A bounded queue cannot safely distinguish a dropped control
            // event from a dropped output event after the fact.  Terminating
            // is therefore the explicit resync signal for both cases.
            eventContinuation?.finish(throwing: InProcessHostTransportError.eventBufferOverflow)
            Task { await close() }
        }
    }

    private func subscriptionEnded(
        attachmentID: TerminalAttachmentID,
        taskToken: UUID
    ) {
        guard let record = attachments[attachmentID], record.taskToken == taskToken else {
            return
        }
        attachments.removeValue(forKey: attachmentID)
        let coordinator = coordinator
        Task {
            _ = try? await coordinator.detach(DetachRequest(
                sessionID: record.sessionID,
                attachmentID: attachmentID,
                reason: "subscription_ended"
            ))
        }
    }
}

/// The longer name reads well at composition sites while preserving the
/// concise type used by the first macOS integration.
public typealias LocalHostTransport = InProcessHostTransport
