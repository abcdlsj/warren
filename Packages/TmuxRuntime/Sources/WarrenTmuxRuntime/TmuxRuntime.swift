import Foundation
import WarrenDomain
import WarrenHost

/// A macOS Host runtime backed by one detached tmux session per Warren Session.
///
/// tmux owns the shell lifetime.  Warren only owns the adapter's observation
/// handles, so attachment and transport teardown never kill a tmux session.
public actor TmuxRuntime: TerminalRuntime {
    public static let runtimeName = "tmux"

    struct ManagedSession {
        let descriptor: TerminalRuntimeDescriptor
        let paneTarget: String
        let spoolURL: URL
        let inputBufferName: String
        let watcher: OutputSpoolWatcher
        var isRunning: Bool
        var metadata: TerminalRuntimeMetadata?
    }

    struct WriteTail {
        let token: UUID
        let completion: Task<Void, Never>
    }

    let executor: any TmuxCommandExecuting
    let outputDirectory: URL
    let exitPollIntervalNanoseconds: UInt64
    let sessionEnvironment: [String: String]
    var sessions: [TerminalSessionID: ManagedSession] = [:]
    var continuations: [TerminalSessionID: [UUID: AsyncStream<TerminalRuntimeEvent>.Continuation]] = [:]
    var writeTails: [TerminalSessionID: WriteTail] = [:]
    var lifecycleMonitorTask: Task<Void, Never>?

    public init(
        executor: any TmuxCommandExecuting = ProcessTmuxCommandExecutor(),
        outputDirectory: URL = TmuxRuntime.defaultOutputDirectory,
        exitPollIntervalNanoseconds: UInt64 = 1_000_000_000,
        sessionEnvironment: [String: String] = [:]
    ) {
        precondition(exitPollIntervalNanoseconds > 0, "Exit polling interval must be positive.")
        self.executor = executor
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.exitPollIntervalNanoseconds = exitPollIntervalNanoseconds
        self.sessionEnvironment = sessionEnvironment
    }

    public static var defaultOutputDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Warren/RuntimeOutput", isDirectory: true)
    }

    // MARK: TerminalRuntime

    public func create(
        sessionID: TerminalSessionID,
        workingDirectory: String,
        size: TerminalSize,
        launchSpec: TerminalRuntimeLaunchSpec
    ) async throws -> TerminalRuntimeDescriptor {
        try validateWorkingDirectory(workingDirectory)
        let name = TmuxSessionNaming.name(for: sessionID)
        try await clearEndedStateOrReject(sessionID: sessionID, name: name)
        guard !(try await hasSession(named: name)) else {
            throw TmuxRuntimeError.sessionAlreadyExists(
                name: name,
                recovery: "Adopt the persisted descriptor, or remove the orphaned tmux session after confirming it belongs to Warren, then create a new one."
            )
        }

        let spoolURL = try prepareSpool(for: name)
        let shellPath = Self.interactiveShellPath
        let launchCommand: String?
        switch launchSpec {
        case .interactiveShell:
            launchCommand = nil
        case .command(let command):
            launchCommand = command
        }
        let descriptor = TerminalRuntimeDescriptor(
            runtime: Self.runtimeName,
            identifier: name,
            metadata: [
                "paneTarget": "",
                "outputPath": spoolURL.path,
                "workingDirectory": workingDirectory,
                "inputBuffer": Self.inputBufferName(for: sessionID),
                "shell": shellPath,
                "launchSpec": launchCommand ?? "interactive-shell",
            ]
        )

        do {
            try await requireSuccess(
                [
                    "new-session", "-d", "-s", name,
                    "-c", workingDirectory,
                    "-x", String(size.columns),
                    "-y", String(size.rows),
                ] + WarrenTerminalEnvironment.tmuxSessionArguments(
                    environment: sessionEnvironment.merging(
                        ["WARREN_SESSION_ID": sessionID.description],
                        uniquingKeysWith: { _, sessionID in sessionID }
                    )
                ) + [
                    WarrenTerminalEnvironment.launchCommand(
                        shellPath: shellPath,
                        command: launchCommand,
                        environment: sessionEnvironment.merging(
                            ["WARREN_SESSION_ID": sessionID.description],
                            uniquingKeysWith: { _, sessionID in sessionID }
                        )
                    ),
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
                launchInteractiveShell: false,
                shellPath: nil
            )
            try await resize(sessionID: sessionID, size: size)
        } catch {
            await removeManagedSession(sessionID)
            throw normalize(error)
        }
    }

    public func presence(sessionID: TerminalSessionID) async -> TerminalRuntimePresence {
        if let managed = sessions[sessionID] {
            return managed.isRunning ? .present : .missing
        }
        do {
            return try await hasSession(named: TmuxSessionNaming.name(for: sessionID))
                ? .present
                : .missing
        } catch {
            return .unavailable(String(describing: error))
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
        // Pasting raw escape sequences through tmux's paste-buffer does not
        // behave like a real key press (for example less/git log ignores
        // pasted CSI arrow bytes). Route recognized terminal keys through
        // tmux send-keys so shells and pagers see the same key the user
        // actually pressed.
        if let keyName = Self.tmuxKeyName(for: data) {
            try await requireSuccess(
                ["send-keys", "-t", managed.paneTarget, keyName],
                recovery: "Ensure the tmux pane is alive, then retry the key operation."
            )
            return
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

    public func sendSpecialKey(
        sessionID: TerminalSessionID,
        key: TerminalSpecialKey
    ) async throws {
        guard let managed = sessions[sessionID], managed.isRunning else {
            throw TmuxRuntimeError.sessionNotFound(
                name: TmuxSessionNaming.name(for: sessionID),
                recovery: "Adopt a live runtime descriptor first."
            )
        }
        do {
            try await requireSuccess(
                ["send-keys", "-t", managed.paneTarget, Self.tmuxKey(for: key)],
                recovery: "Ensure the tmux pane is alive, then retry the key operation."
            )
        } catch {
            throw normalize(error)
        }
    }

    public func inspect(sessionID: TerminalSessionID) async throws -> TerminalRuntimeInspection {
        let name = TmuxSessionNaming.name(for: sessionID)
        guard try await hasSession(named: name) else {
            return TerminalRuntimeInspection(isRunning: false)
        }
        let descriptor = sessions[sessionID]?.descriptor
        let target = sessions[sessionID]?.paneTarget ?? name
        let separator = "|"
        let format = "#{pane_current_command}\(separator)#{pane_current_path}"
        let arguments = ["display-message", "-p", "-t", target, format]
        let result = try await execute(arguments: arguments)
        guard result.exitCode == 0 else {
            throw commandError(
                arguments: arguments,
                result: result,
                recovery: "Ensure the tmux pane is still alive, then retry inspection."
            )
        }
        let fields = result.stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
        return TerminalRuntimeInspection(
            isRunning: true,
            descriptor: descriptor,
            paneProcess: fields.first.map(String.init),
            workingDirectory: fields.count > 1 ? String(fields[1]) : nil
        )
    }

    public func terminate(sessionID: TerminalSessionID) async throws {
        let name = TmuxSessionNaming.name(for: sessionID)
        guard try await hasSession(named: name) else {
            throw TmuxRuntimeError.sessionNotFound(
                name: name,
                recovery: "The runtime is already stopped; refresh Host session state."
            )
        }
        do {
            try await requireSuccess(
                ["kill-session", "-t", name],
                recovery: "Ensure the tmux server is available, then retry termination."
            )
            finishSession(sessionID: sessionID, exitCode: nil)
        } catch {
            throw normalize(error)
        }
    }

    public func purge(
        sessionID: TerminalSessionID,
        descriptor: TerminalRuntimeDescriptor
    ) async throws {
        guard descriptor.runtime == Self.runtimeName,
              descriptor.identifier == TmuxSessionNaming.name(for: sessionID) else {
            throw TmuxRuntimeError.descriptorInvalid(
                reason: "runtime artifact descriptor does not match the Session.",
                recovery: "Use the descriptor persisted for this Warren Terminal Session."
            )
        }
        switch await presence(sessionID: sessionID) {
        case .missing:
            break
        case .present:
            throw TmuxRuntimeError.sessionAlreadyExists(
                name: descriptor.identifier,
                recovery: "Terminate the runtime before purging its artifacts."
            )
        case .unavailable(let reason):
            throw TmuxRuntimeError.commandFailed(
                arguments: ["has-session", "-t", descriptor.identifier],
                exitCode: -1,
                stderr: reason,
                recovery: "Restore tmux availability, then retry artifact cleanup."
            )
        }
        let expected = outputDirectory.standardizedFileURL
            .appendingPathComponent("\(descriptor.identifier).out", isDirectory: false)
            .standardizedFileURL
        let actual = try spoolURL(from: descriptor).standardizedFileURL
        guard actual == expected else {
            throw TmuxRuntimeError.descriptorInvalid(
                reason: "outputPath is outside this Session's managed RuntimeOutput artifact.",
                recovery: "Do not delete an unverified path from runtime metadata."
            )
        }
        await removeManagedSession(sessionID)
        guard FileManager.default.fileExists(atPath: actual.path) else { return }
        do {
            try FileManager.default.removeItem(at: actual)
        } catch {
            throw TmuxRuntimeError.outputSpoolUnavailable(
                path: actual.path,
                reason: String(describing: error),
                recovery: "Check Warren's write access to RuntimeOutput, then retry deletion."
            )
        }
    }

    private static func tmuxKey(for key: TerminalSpecialKey) -> String {
        switch key {
        case .interrupt: "C-c"
        case .endOfFile: "C-d"
        case .escape: "Escape"
        case .enter: "Enter"
        case .tab: "Tab"
        case .backspace: "BSpace"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// Maps terminal byte sequences that must reach tmux as key presses
    /// instead of pasted text. Exact single-key sequences (arrows, editing
    /// keys, and common CSI/SS3 forms) return tmux's key name; everything
    /// else returns nil and continues through the binary-safe paste path.
    private static func tmuxKeyName(for data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes == [0x1B] {
            return "Escape"
        }
        if bytes == [0x0D] || bytes == [0x0A] {
            return "Enter"
        }
        if bytes == [0x09] {
            return "Tab"
        }
        if bytes == [0x7F] {
            return "BSpace"
        }
        if bytes == [0x1B, 0x4F, 0x41] || bytes == [0x1B, 0x5B, 0x41] {
            return "Up"
        }
        if bytes == [0x1B, 0x4F, 0x42] || bytes == [0x1B, 0x5B, 0x42] {
            return "Down"
        }
        if bytes == [0x1B, 0x4F, 0x43] || bytes == [0x1B, 0x5B, 0x43] {
            return "Right"
        }
        if bytes == [0x1B, 0x4F, 0x44] || bytes == [0x1B, 0x5B, 0x44] {
            return "Left"
        }
        if bytes == [0x1B, 0x4F, 0x48] || bytes == [0x1B, 0x5B, 0x48] {
            return "Home"
        }
        if bytes == [0x1B, 0x4F, 0x46] || bytes == [0x1B, 0x5B, 0x46] {
            return "End"
        }
        guard bytes.count >= 4, bytes[0] == 0x1B else { return nil }
        guard bytes[1] == 0x5B else { return nil }

        let text = String(decoding: bytes, as: UTF8.self)
        guard text.hasPrefix("\u{1B}["), let final = text.last else { return nil }
        let params = text.dropFirst(2).dropLast().split(separator: ";").map(String.init)
        if final == "~" {
            guard params.count == 1, let code = Int(params[0]) else { return nil }
            switch code {
            case 1, 7: return "Home"
            case 2: return "IC"
            case 3: return "DC"
            case 4, 8: return "End"
            case 5: return "PageUp"
            case 6: return "PageDown"
            case 11: return "F1"
            case 12: return "F2"
            case 13: return "F3"
            case 14: return "F4"
            case 15: return "F5"
            case 17: return "F6"
            case 18: return "F7"
            case 19: return "F8"
            case 20: return "F9"
            case 21: return "F10"
            case 23: return "F11"
            case 24: return "F12"
            default: return nil
            }
        }

        let base: String
        switch final {
        case "A": base = "Up"
        case "B": base = "Down"
        case "C": base = "Right"
        case "D": base = "Left"
        case "H": base = "Home"
        case "F": base = "End"
        case "Z": base = "BTab"
        default: return nil
        }
        guard let modifier = params.last else { return base }
        let prefix: String?
        switch modifier {
        case "2": prefix = "S-"
        case "3": prefix = "M-"
        case "4": prefix = "M-S-"
        case "5": prefix = "C-"
        case "6": prefix = "C-S-"
        case "7": prefix = "C-M-"
        case "8": prefix = "C-M-S-"
        default: prefix = nil
        }
        return prefix.map { $0 + base }
    }

}
