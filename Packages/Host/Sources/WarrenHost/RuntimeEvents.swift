import Foundation
import WarrenDomain
import WarrenProtocol

/// Runtime output is bounded before it enters the Host ring or an attachment
/// stream.  The value matches the binary transport's default payload ceiling
/// while keeping WarrenHost independent from a concrete transport package.
public enum RuntimeOutputIngestionError: Error, Codable, Hashable, Sendable {
    case payloadTooLarge(actual: Int, limit: Int)
    case invalidChunkSize(actual: Int, limit: Int)
}

extension TerminalSessionCoordinator {
    public static let defaultRuntimeOutputLimit = 8 * 1024 * 1024
    /// Runtime adapters may deliver arbitrarily large spool catch-up reads.
    /// This deterministic frame size keeps one PTY frame small while
    /// preserving every byte and its sequence offset.
    public static let defaultRuntimeOutputChunkSize = 64 * 1024

    /// Starts the one runtime-event consumer owned by this Host session.
    /// Calling it repeatedly is idempotent.  The stream is independent of
    /// Client attachments, so a transport can close while the PTY continues
    /// to run and produce recoverable output.
    public func attachRuntimeStream(sessionID: TerminalSessionID) async throws {
        guard sessions[sessionID] != nil else {
            throw protocolError(.sessionNotFound, "Cannot observe a missing terminal session.")
        }
        guard runtimeEventTokens[sessionID] == nil else { return }

        let stream = await runtime.events(for: sessionID)
        try startRuntimeStream(sessionID: sessionID, stream: stream)
    }

    /// Stops only the Host-side runtime event subscription.  It does not
    /// terminate or remove the runtime session.
    public func detachRuntimeStream(sessionID: TerminalSessionID) {
        runtimeEventTasks.removeValue(forKey: sessionID)?.cancel()
        runtimeEventTokens.removeValue(forKey: sessionID)
    }

    /// Explicit seam for runtime adapters that already own an event loop.
    /// Empty chunks are harmless and ignored.  This single-frame API keeps
    /// its explicit payload ceiling for callers that require one frame.
    @discardableResult
    public func consumeRuntimeOutput(
        sessionID: TerminalSessionID,
        data: Data,
        maxPayload: Int = TerminalSessionCoordinator.defaultRuntimeOutputLimit
    ) throws -> TerminalOutputFrame? {
        guard sessions[sessionID] != nil else {
            throw protocolError(.sessionNotFound, "Cannot consume output for a missing terminal session.")
        }
        guard !data.isEmpty else { return nil }
        guard maxPayload > 0, data.count <= maxPayload else {
            throw RuntimeOutputIngestionError.payloadTooLarge(
                actual: data.count,
                limit: maxPayload
            )
        }
        return try recordOutput(sessionID: sessionID, data: data)
    }

    /// Records one runtime read as a contiguous sequence of bounded frames.
    ///
    /// Runtime adapters must use this path: a spool read can be larger than a
    /// transport frame (especially after the App was offline), but dropping or
    /// rejecting that read would make `sequence` diverge from the spool byte
    /// offset.  Every chunk is appended and published in order, and the
    /// OutputRing's byte cursor advances by the exact original data count.
    @discardableResult
    public func consumeRuntimeOutputChunks(
        sessionID: TerminalSessionID,
        data: Data,
        chunkSize: Int = TerminalSessionCoordinator.defaultRuntimeOutputChunkSize
    ) throws -> [TerminalOutputFrame] {
        guard sessions[sessionID] != nil else {
            throw protocolError(.sessionNotFound, "Cannot consume output for a missing terminal session.")
        }
        guard !data.isEmpty else { return [] }
        guard chunkSize > 0, chunkSize <= TerminalSessionCoordinator.defaultRuntimeOutputLimit else {
            throw RuntimeOutputIngestionError.invalidChunkSize(
                actual: chunkSize,
                limit: TerminalSessionCoordinator.defaultRuntimeOutputLimit
            )
        }

        // Validate the whole append before publishing any chunk.  This keeps
        // a sequence overflow from leaving a partially committed read.
        let upper = sessions[sessionID]!.output.upperSequence
        guard UInt64(data.count) <= UInt64.max - upper else {
            throw OutputRingError.payloadTooLarge
        }

        var frames: [TerminalOutputFrame] = []
        let frameCount = data.count / chunkSize + (data.count % chunkSize == 0 ? 0 : 1)
        frames.reserveCapacity(frameCount)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let frame = try recordOutput(
                sessionID: sessionID,
                data: Data(data[offset..<end])
            )
            frames.append(frame)
            offset = end
        }
        return frames
    }

    package func startRuntimeStream(
        sessionID: TerminalSessionID,
        stream: AsyncStream<TerminalRuntimeEvent>
    ) throws {
        guard sessions[sessionID] != nil else {
            throw protocolError(.sessionNotFound, "Cannot observe a missing terminal session.")
        }
        guard runtimeEventTokens[sessionID] == nil else { return }

        let token = UUID()
        runtimeEventTokens[sessionID] = token
        let task = Task { [weak self, stream, token] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consumeRuntimeEvent(event)
            }
            await self?.runtimeStreamFinished(sessionID: sessionID, token: token)
        }
        runtimeEventTasks[sessionID] = task
    }

    private func consumeRuntimeEvent(_ event: TerminalRuntimeEvent) {
        switch event {
        case .output(let sessionID, let data):
            do {
                _ = try consumeRuntimeOutputChunks(sessionID: sessionID, data: data)
            } catch let error as ProtocolError {
                publishRuntimeError(error, sessionID: sessionID)
            } catch let error as RuntimeOutputIngestionError {
                let protocolError = ProtocolError(
                    code: .invalidFrame,
                    message: "The runtime output chunk configuration is invalid: \(error).",
                    retryable: true
                )!
                publishRuntimeError(protocolError, sessionID: sessionID)
            } catch {
                let protocolError = ProtocolError(
                    code: .internalFailure,
                    message: "The runtime output could not be recorded: \(error).",
                    retryable: true
                )!
                publishRuntimeError(protocolError, sessionID: sessionID)
            }

        case .metadata(let sessionID, let value):
            guard var state = sessions[sessionID], state.runtimeMetadata != value else { return }
            state.runtimeMetadata = value
            sessions[sessionID] = state
            let message = ServerControlMessage.runtimeMetadata(
                RuntimeMetadataMessage(
                    sessionID: sessionID,
                    process: value.process,
                    workingDirectory: value.workingDirectory
                )
            )
            for attachmentID in state.attachments.keys {
                yieldRuntimeEvent(.control(message), to: attachmentID)
            }

        case .exited(let sessionID, let exitCode):
            guard let state = sessions[sessionID] else { return }
            let exit = ServerControlMessage.exit(
                ExitMessage(
                    sessionID: sessionID,
                    epoch: state.output.epoch,
                    sequence: state.output.upperSequence,
                    exitCode: exitCode.map { Int($0) },
                    reason: "runtime_exited"
                )
            )
            for attachmentID in state.attachments.keys {
                yieldRuntimeEvent(.control(exit), to: attachmentID)
            }
            // Exit is a terminal event for attachment streams.  The Host
            // session record itself remains available for inspection/recovery.
            for attachmentID in state.attachments.keys {
                eventContinuations[attachmentID]?.continuation.finish()
                eventContinuations.removeValue(forKey: attachmentID)
            }
            runtimeEventTasks.removeValue(forKey: sessionID)
            runtimeEventTokens.removeValue(forKey: sessionID)
        }
    }

    private func runtimeStreamFinished(sessionID: TerminalSessionID, token: UUID) {
        guard runtimeEventTokens[sessionID] == token else { return }
        runtimeEventTasks.removeValue(forKey: sessionID)
        runtimeEventTokens.removeValue(forKey: sessionID)
    }

    private func publishRuntimeError(_ error: ProtocolError, sessionID: TerminalSessionID) {
        guard let state = sessions[sessionID] else { return }
        for attachmentID in state.attachments.keys {
            yieldRuntimeEvent(.control(.error(error)), to: attachmentID)
        }
    }

    private func yieldRuntimeEvent(_ event: HostSessionEvent, to attachmentID: TerminalAttachmentID) {
        guard let current = eventContinuations[attachmentID] else { return }
        if case .terminated = current.continuation.yield(event) {
            eventContinuations.removeValue(forKey: attachmentID)
        }
    }
}
