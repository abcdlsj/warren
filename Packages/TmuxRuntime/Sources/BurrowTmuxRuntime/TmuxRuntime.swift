import Foundation
import BurrowDomain
import BurrowHost

/// A macOS Host runtime backed by one detached tmux session per Burrow Session.
///
/// tmux owns the shell lifetime.  Burrow only owns the adapter's observation
/// handles, so attachment and transport teardown never kill a tmux session.
public actor TmuxRuntime: TerminalRuntime {
    public static let runtimeName = "tmux"

    struct ManagedSession {
        let descriptor: TerminalRuntimeDescriptor
        let paneTarget: String
        let spoolURL: URL
        let inputBufferName: String
        let watcher: OutputSpoolWatcher
        var monitorTask: Task<Void, Never>?
        var isRunning: Bool
    }

    struct WriteTail {
        let token: UUID
        let completion: Task<Void, Never>
    }

    let executor: any TmuxCommandExecuting
    let outputDirectory: URL
    let exitPollIntervalNanoseconds: UInt64
    var sessions: [TerminalSessionID: ManagedSession] = [:]
    var continuations: [TerminalSessionID: [UUID: AsyncStream<TerminalRuntimeEvent>.Continuation]] = [:]
    var writeTails: [TerminalSessionID: WriteTail] = [:]

    public init(
        executor: any TmuxCommandExecuting = ProcessTmuxCommandExecutor(),
        outputDirectory: URL = TmuxRuntime.defaultOutputDirectory,
        exitPollIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        precondition(exitPollIntervalNanoseconds > 0, "Exit polling interval must be positive.")
        self.executor = executor
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.exitPollIntervalNanoseconds = exitPollIntervalNanoseconds
    }

    public static var defaultOutputDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Burrow/RuntimeOutput", isDirectory: true)
    }

    // MARK: TerminalRuntime

    public func create(
        sessionID: TerminalSessionID,
        workingDirectory: String,
        size: TerminalSize
    ) async throws -> TerminalRuntimeDescriptor {
        try validateWorkingDirectory(workingDirectory)
        let name = TmuxSessionNaming.name(for: sessionID)
        try await clearEndedStateOrReject(sessionID: sessionID, name: name)
        guard !(try await hasSession(named: name)) else {
            throw TmuxRuntimeError.sessionAlreadyExists(
                name: name,
                recovery: "Adopt the persisted descriptor, or remove the orphaned tmux session after confirming it belongs to Burrow, then create a new one."
            )
        }

        let spoolURL = try prepareSpool(for: name)
        let shellPath = Self.interactiveShellPath
        let descriptor = TerminalRuntimeDescriptor(
            runtime: Self.runtimeName,
            identifier: name,
            metadata: [
                "paneTarget": "",
                "outputPath": spoolURL.path,
                "workingDirectory": workingDirectory,
                "inputBuffer": Self.inputBufferName(for: sessionID),
                "shell": shellPath,
            ]
        )

        do {
            try await requireSuccess(
                [
                    "new-session", "-d", "-s", name,
                    "-c", workingDirectory,
                    "-x", String(size.columns),
                    "-y", String(size.rows),
                ] + BurrowTerminalEnvironment.tmuxSessionArguments + [
                    BurrowTerminalEnvironment.interactiveShellCommand(shellPath: shellPath),
                ],
                recovery: "Ensure the tmux server can start and the working directory still exists."
            )
            let paneTarget = try await paneTarget(for: name)
            let finalizedDescriptor = descriptorWithPane(
                descriptor,
                paneTarget: paneTarget
            )
            try await install(
                sessionID: sessionID,
                descriptor: finalizedDescriptor,
                paneTarget: paneTarget,
                spoolURL: spoolURL,
                inputBufferName: Self.inputBufferName(for: sessionID),
                outputOffset: 0,
                pipeOnlyIfMissing: false,
                launchInteractiveShell: false,
                shellPath: nil
            )
            return finalizedDescriptor
        } catch {
            await bestEffortKill(name: name)
            throw normalize(error)
        }
    }

    public func adopt(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor,
        size: TerminalSize,
        outputOffset: UInt64
    ) async throws {
        guard descriptor.runtime == Self.runtimeName else {
            throw TmuxRuntimeError.descriptorInvalid(
                reason: "runtime is `\(descriptor.runtime)`, not `\(Self.runtimeName)`.",
                recovery: "Pass this session to the Runtime Adapter matching descriptor.runtime."
            )
        }
        guard descriptor.identifier == TmuxSessionNaming.name(for: sessionID),
              TmuxSessionNaming.sessionID(from: descriptor.identifier) == sessionID else {
            throw TmuxRuntimeError.descriptorInvalid(
                reason: "identifier does not match Host sessionID.",
                recovery: "Regenerate a matching runtime descriptor from PersistedTerminalSession."
            )
        }
        try await clearEndedStateOrReject(sessionID: sessionID, name: descriptor.identifier)
        guard try await hasSession(named: descriptor.identifier) else {
            throw TmuxRuntimeError.sessionNotFound(
                name: descriptor.identifier,
                recovery: "Check whether the tmux server is running; if the session exited, mark it ended in Host before creating a new one."
            )
        }

        let spoolURL = try spoolURL(from: descriptor)
        guard FileManager.default.fileExists(atPath: spoolURL.path) else {
            throw TmuxRuntimeError.outputSpoolUnavailable(
                path: spoolURL.path,
                reason: "Persisted output spool does not exist.",
                recovery: "Do not delete this session's RuntimeOutput file; " +
                    "restore it from a backup before adoption, or create a new session."
            )
        }
        let paneTarget = try await resolvePaneTarget(from: descriptor)
        let inputBuffer = descriptor.metadata["inputBuffer"] ?? Self.inputBufferName(for: sessionID)
        do {
            try await install(
                sessionID: sessionID,
                descriptor: descriptor,
                paneTarget: paneTarget,
                spoolURL: spoolURL,
                inputBufferName: inputBuffer,
                outputOffset: outputOffset,
                pipeOnlyIfMissing: true,
                launchInteractiveShell: false,
                shellPath: nil
            )
            try await resize(sessionID: sessionID, size: size)
        } catch {
            await removeManagedSession(sessionID)
            throw normalize(error)
        }
    }

    public func exists(sessionID: TerminalSessionID) async -> Bool {
        if let managed = sessions[sessionID] {
            return managed.isRunning
        }
        do {
            return try await hasSession(named: TmuxSessionNaming.name(for: sessionID))
        } catch {
            return false
        }
    }

    public func events(for sessionID: TerminalSessionID) async -> AsyncStream<TerminalRuntimeEvent> {
        let (stream, continuation) = AsyncStream<TerminalRuntimeEvent>.makeStream()
        let token = UUID()
        continuations[sessionID, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(token, for: sessionID) }
        }
        return stream
    }

    public func write(sessionID: TerminalSessionID, data: Data) async throws {
        guard !data.isEmpty else { return }

        // Actor isolation does not make a two-command tmux transaction atomic:
        // another write can enter while this one awaits. Keep one FIFO tail per
        // Session so terminal bytes preserve caller order.
        let previous = writeTails[sessionID]?.completion
        let token = UUID()
        let operation = Task<Void, Error> { [self] in
            await previous?.value
            try await performWrite(sessionID: sessionID, data: data)
        }
        let completion = Task<Void, Never> {
            _ = try? await operation.value
        }
        writeTails[sessionID] = WriteTail(token: token, completion: completion)

        do {
            try await operation.value
            finishWrite(sessionID: sessionID, token: token)
        } catch {
            finishWrite(sessionID: sessionID, token: token)
            throw normalize(error)
        }
    }

    private func performWrite(
        sessionID: TerminalSessionID,
        data: Data
    ) async throws {
        guard let managed = sessions[sessionID], managed.isRunning else {
            throw TmuxRuntimeError.sessionNotFound(
                name: TmuxSessionNaming.name(for: sessionID),
                recovery: "Adopt a live runtime descriptor first."
            )
        }
        let bufferName = "\(managed.inputBufferName)-\(UUID().uuidString.lowercased())"
        do {
            try await requireSuccess(
                ["load-buffer", "-b", bufferName, "-"],
                standardInput: data,
                recovery: "Ensure the tmux server is still running, then retry input."
            )
            try await requireSuccess(
                ["paste-buffer", "-b", bufferName, "-d", "-t", managed.paneTarget],
                recovery: "Ensure the tmux pane is still alive, then retry input."
            )
        } catch {
            // paste-buffer -d removes the buffer on success. On failure, clean
            // only this write's unique buffer; never touch another input.
            _ = try? await executor.execute(
                arguments: ["delete-buffer", "-b", bufferName],
                standardInput: nil
            )
            throw error
        }
    }

    private func finishWrite(sessionID: TerminalSessionID, token: UUID) {
        guard writeTails[sessionID]?.token == token else { return }
        writeTails.removeValue(forKey: sessionID)
    }

    public func resize(sessionID: TerminalSessionID, size: TerminalSize) async throws {
        guard let managed = sessions[sessionID], managed.isRunning else {
            throw TmuxRuntimeError.sessionNotFound(
                name: TmuxSessionNaming.name(for: sessionID),
                recovery: "Adopt a live runtime descriptor first."
            )
        }
        do {
            try await requireSuccess(
                ["resize-window", "-t", managed.paneTarget, "-x", String(size.columns), "-y", String(size.rows)],
                recovery: "Ensure the tmux pane is still alive, then retry resizing."
            )
        } catch {
            throw normalize(error)
        }
    }

}
