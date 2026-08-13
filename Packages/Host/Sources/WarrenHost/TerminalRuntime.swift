import Foundation
import WarrenDomain

/// An opaque handle that lets Host persist enough information to adopt a
/// runtime session after the Host process is restarted.
///
/// The runtime name and metadata are deliberately kept outside the domain
/// model.  A tmux adapter may store a tmux session name and pane target here;
/// another adapter can use a process identifier, a socket path, or any other
/// stable identifier without changing Host.
public struct TerminalRuntimeDescriptor: Codable, Hashable, Sendable {
    public let runtime: String
    public let identifier: String
    public let metadata: [String: String]

    public init(
        runtime: String,
        identifier: String,
        metadata: [String: String] = [:]
    ) {
        self.runtime = runtime
        self.identifier = identifier
        self.metadata = metadata
    }
}

/// Events produced by a runtime independently of Client attachment state.
/// Output payloads are raw PTY bytes; parsing and rendering stay on the
/// Client side.
public enum TerminalRuntimeEvent: Hashable, Sendable {
    case output(sessionID: TerminalSessionID, data: Data)
    case metadata(sessionID: TerminalSessionID, value: TerminalRuntimeMetadata)
    case exited(sessionID: TerminalSessionID, exitCode: Int?)
}

public struct TerminalRuntimeMetadata: Codable, Hashable, Sendable {
    public let process: String
    public let workingDirectory: String

    public init(process: String = "", workingDirectory: String = "") {
        self.process = process
        self.workingDirectory = workingDirectory
    }
}

public enum TerminalRuntimeLaunchSpec: Codable, Hashable, Sendable {
    case interactiveShell
    case command(String)

    public init(command: String?) {
        let value = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        self = value?.isEmpty == false ? .command(value!) : .interactiveShell
    }
}

public enum TerminalSpecialKey: String, Codable, Hashable, Sendable {
    case interrupt
    case endOfFile
    case escape
    case enter
    case tab
    case backspace
    case up
    case down
    case left
    case right
}

public struct TerminalRuntimeInspection: Codable, Hashable, Sendable {
    public let isRunning: Bool
    public let descriptor: TerminalRuntimeDescriptor?
    public let paneProcess: String?
    public let workingDirectory: String?

    public init(
        isRunning: Bool,
        descriptor: TerminalRuntimeDescriptor? = nil,
        paneProcess: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.isRunning = isRunning
        self.descriptor = descriptor
        self.paneProcess = paneProcess
        self.workingDirectory = workingDirectory
    }
}

/// The result of asking a runtime backend whether it still owns a Session.
/// `unavailable` is deliberately distinct from `missing`: an observation
/// failure must never become evidence that the terminal ended.
public enum TerminalRuntimePresence: Hashable, Sendable {
    case present
    case missing
    case unavailable(String)
}

/// The small runtime boundary owned by Host. A tmux adapter can implement this
/// protocol without becoming part of the domain model.
public protocol TerminalRuntime: Sendable {
    func create(
        sessionID: TerminalSessionID,
        workingDirectory: String,
        size: TerminalSize,
        launchSpec: TerminalRuntimeLaunchSpec
    ) async throws -> TerminalRuntimeDescriptor

    /// Reconnects Host to an already-running runtime session.  `outputOffset`
    /// is the number of PTY bytes already committed to Host's output ring;
    /// adapters should begin emitting persisted output after that offset.
    func adopt(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor,
        size: TerminalSize,
        outputOffset: UInt64
    ) async throws

    /// Observes whether the runtime currently owns a Session with this Host
    /// identifier. This is a process-restart check, not an attachment count.
    func presence(sessionID: TerminalSessionID) async -> TerminalRuntimePresence

    /// Subscribes to runtime events.  Subscription is allowed before
    /// `create`, which prevents a fast shell from racing Host's first output
    /// listener.  The stream finishes after an `exited` event.
    func events(for sessionID: TerminalSessionID) async -> AsyncStream<TerminalRuntimeEvent>

    func write(sessionID: TerminalSessionID, data: Data) async throws
    func sendSpecialKey(sessionID: TerminalSessionID, key: TerminalSpecialKey) async throws
    func resize(sessionID: TerminalSessionID, size: TerminalSize) async throws
    func inspect(sessionID: TerminalSessionID) async throws -> TerminalRuntimeInspection
    func terminate(sessionID: TerminalSessionID) async throws

    /// Removes durable adapter artifacts after the Session record is deleted.
    /// It must not terminate a live runtime.
    func purge(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor
    ) async throws
}

public extension TerminalRuntime {
    func create(
        sessionID: TerminalSessionID,
        workingDirectory: String,
        size: TerminalSize
    ) async throws -> TerminalRuntimeDescriptor {
        try await create(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            size: size,
            launchSpec: .interactiveShell
        )
    }

    func purge(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor
    ) async throws {
        _ = sessionID
        _ = descriptor
    }

    /// Convenience for diagnostics and tests that only need a live/not-live
    /// answer. Lifecycle-changing code must switch over `presence` instead.
    func exists(sessionID: TerminalSessionID) async -> Bool {
        await presence(sessionID: sessionID) == .present
    }
}

public enum TerminalRuntimeError: Error, Codable, Hashable, Sendable {
    case sessionAlreadyExists
    case sessionNotFound
    case invalidWorkingDirectory
    case operationFailed(String)
}
