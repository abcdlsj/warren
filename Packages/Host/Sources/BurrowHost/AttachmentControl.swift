import Foundation
import BurrowDomain
import BurrowProtocol

extension TerminalSessionCoordinator {
    @discardableResult
    public func requestControl(
        _ request: ControlRequest,
        now: Date? = nil
    ) throws -> ControlLease {
        try validate(version: request.version)
        guard var state = sessions[request.sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot request control for a missing session.")
        }
        let instant = now ?? clock()
        expireLease(in: &state, at: instant)
        guard state.attachments[request.attachmentID] != nil else {
            throw protocolError(.attachmentNotFound, "Cannot request control from a missing attachment.")
        }
        if let existing = state.controllerLease {
            if existing.attachmentID == request.attachmentID {
                sessions[request.sessionID] = state
                publishControlChanged(for: request.sessionID)
                return existing
            }
            // Last writer wins: a web or second client that starts typing
            // takes over the lease. The previous controller's next input will
            // request control again and reclaim it.
            state.controllerLease = nil
        }
        guard let lease = ControlLease(
            sessionID: request.sessionID,
            attachmentID: request.attachmentID,
            issuedAt: instant,
            expiresAt: instant.addingTimeInterval(leaseDuration)
        ) else {
            throw protocolError(.internalFailure, "The control lease could not be issued.")
        }
        state.controllerLease = lease
        sessions[request.sessionID] = state
        publishControlChanged(for: request.sessionID)
        return lease
    }

    public func releaseControl(
        _ request: ReleaseControlRequest,
        now: Date? = nil
    ) throws {
        try validate(version: request.version)
        guard var state = sessions[request.sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot release control for a missing session.")
        }
        let instant = now ?? clock()
        guard state.attachments[request.attachmentID] != nil else {
            throw protocolError(.attachmentNotFound, "Cannot release control from a missing attachment.")
        }
        guard let lease = state.controllerLease else {
            throw protocolError(.controlRequired, "This attachment does not hold the control lease.")
        }
        guard lease.isActive(at: instant) else {
            state.controllerLease = nil
            sessions[request.sessionID] = state
            throw protocolError(.controlLeaseExpired, "The control lease has expired; request a new lease.", retryable: true)
        }
        guard lease.attachmentID == request.attachmentID else {
            sessions[request.sessionID] = state
            throw protocolError(.controlRequired, "Only the current controller can release the control lease.")
        }
        if let requestedLeaseID = request.leaseID, requestedLeaseID != lease.id {
            sessions[request.sessionID] = state
            throw protocolError(.controlLeaseExpired, "The supplied control lease is no longer current.", retryable: true)
        }
        state.controllerLease = nil
        sessions[request.sessionID] = state
        publishControlChanged(for: request.sessionID)
    }

    public func input(
        _ request: InputMetadata,
        data: Data,
        now: Date? = nil
    ) async throws {
        try validate(version: request.version)
        guard var state = sessions[request.sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot write input to a missing session.")
        }
        guard request.payloadLength == data.count else {
            throw protocolError(.invalidFrame, "Input metadata payloadLength does not match the binary payload.")
        }
        try requireController(
            in: &state,
            sessionID: request.sessionID,
            attachmentID: request.attachmentID,
            at: now ?? clock()
        )
        sessions[request.sessionID] = state
        do {
            try await runtime.write(sessionID: request.sessionID, data: data)
        } catch {
            throw protocolError(.internalFailure, "The terminal runtime rejected input: \(error).", retryable: true)
        }
    }

    public func resize(
        _ request: ResizeRequest,
        now: Date? = nil
    ) async throws {
        try validate(version: request.version)
        guard var state = sessions[request.sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot resize a missing session.")
        }
        try requireController(
            in: &state,
            sessionID: request.sessionID,
            attachmentID: request.attachmentID,
            at: now ?? clock()
        )
        sessions[request.sessionID] = state
        do {
            try await runtime.resize(sessionID: request.sessionID, size: request.size)
        } catch {
            throw protocolError(.internalFailure, "The terminal runtime rejected resize: \(error).", retryable: true)
        }
    }

    public func sendSpecialKey(
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        key: TerminalSpecialKey,
        now: Date? = nil
    ) async throws {
        guard var state = sessions[sessionID] else {
            throw protocolError(.sessionNotFound, "Cannot send a key to a missing session.")
        }
        try requireController(
            in: &state,
            sessionID: sessionID,
            attachmentID: attachmentID,
            at: now ?? clock()
        )
        sessions[sessionID] = state
        do {
            try await runtime.sendSpecialKey(sessionID: sessionID, key: key)
        } catch {
            throw protocolError(.internalFailure, "The terminal runtime rejected the key: \(error).", retryable: true)
        }
    }

    public func inspectRuntime(
        sessionID: TerminalSessionID
    ) async throws -> TerminalRuntimeInspection {
        guard sessions[sessionID] != nil else {
            throw protocolError(.sessionNotFound, "Cannot inspect a missing session.")
        }
        return try await runtime.inspect(sessionID: sessionID)
    }

    public func terminateRuntime(sessionID: TerminalSessionID) async throws {
        guard sessions[sessionID] != nil else {
            throw protocolError(.sessionNotFound, "Cannot terminate a missing session.")
        }
        do {
            try await runtime.terminate(sessionID: sessionID)
        } catch {
            throw protocolError(.internalFailure, "The terminal runtime could not terminate: \(error).", retryable: true)
        }
    }
}
