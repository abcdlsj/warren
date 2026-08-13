import Foundation

/// Environment policy for processes and shells hosted by Warren.
///
/// The application may itself be launched by Codex, Claude Code, VS Code, or
/// another terminal. Their identity and color-policy variables describe the
/// launcher, not the terminal Warren hosts, so they must not leak into tmux.
enum WarrenTerminalEnvironment {
    static let termProgram = "Warren"

    static var termProgramVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "dev"
    }

    static func sanitized(from parent: [String: String]) -> [String: String] {
        let dropped: Set<String> = [
            "CLAUDECODE", "CLAUDE_EFFORT", "TERM_SESSION_ID", "TERMINAL_EMULATOR",
            "TMUX", "TMUX_PANE", "STY", "INSIDE_EMACS", "LC_TERMINAL",
            "LC_TERMINAL_VERSION", "KONSOLE_VERSION", "GNOME_TERMINAL_SERVICE",
            "WT_SESSION", "NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE",
            "WARREN_CONTROL_PLANE_URL", "WARREN_CONTROL_PLANE_HOST_ID",
            "WARREN_CONTROL_PLANE_HOST_TOKEN",
        ]
        let droppedPrefixes = [
            "TERM_PROGRAM", "VSCODE_", "CLAUDE_CODE_", "ITERM_", "GHOSTTY_",
            "KITTY_", "WEZTERM_", "ALACRITTY_",
        ]

        var environment = parent.filter { key, _ in
            !dropped.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = termProgram
        environment["TERM_PROGRAM_VERSION"] = termProgramVersion
        return environment
    }

    static func tmuxSessionArguments(environment: [String: String] = [:]) -> [String] {
        let base = [
            "-e", "COLORTERM=truecolor",
            "-e", "TERM_PROGRAM=\(termProgram)",
            "-e", "TERM_PROGRAM_VERSION=\(termProgramVersion)",
        ]
        return base + environment.sorted { $0.key < $1.key }.flatMap { key, value in
            ["-e", "\(key)=\(value)"]
        }
    }

    /// Command used for the first pane in a tmux session.
    ///
    /// Session-level tmux environment removal is insufficient: a session
    /// with no `NO_COLOR` override falls back to a stale value in a long-lived
    /// tmux server. `env -u` removes the policy at the actual process boundary.
    static func interactiveShellCommand(shellPath: String) -> String {
        launchCommand(shellPath: shellPath, command: nil)
    }

    static func launchCommand(
        shellPath: String,
        command: String?,
        environment: [String: String] = [:]
    ) -> String {
        let assignments = [
            "COLORTERM=truecolor",
            "TERM_PROGRAM=\(termProgram)",
            "TERM_PROGRAM_VERSION=\(termProgramVersion)",
        ] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let components = [
            "/usr/bin/env",
            "-u", "NO_COLOR",
            "-u", "FORCE_COLOR",
            "-u", "CLICOLOR",
            "-u", "CLICOLOR_FORCE",
        ] + assignments + [shellPath] + (command.map { ["-l", "-c", "exec \($0)"] } ?? [])
        return components.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// The result of one direct `tmux` process invocation.  Standard output and
/// error stay as bytes so the runtime never loses diagnostic data due to an
/// encoding conversion.
public struct TmuxCommandResult: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

/// Errors that happen before tmux can produce a command result.
public enum TmuxCommandExecutorError: Error, Equatable, Sendable, LocalizedError {
    case binaryNotFound(searchPaths: [String])
    case launchFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(searchPaths):
            return "tmux executable not found. Checked: " +
                searchPaths.joined(separator: ", ") +
                ". Install tmux first (for example `brew install tmux`)."
        case let .launchFailed(path, reason):
            return "Cannot start tmux (" + path + "): " + reason + ". Check file permissions and the local runtime environment."
        }
    }
}

/// Injectable process boundary for deterministic runtime tests.
public protocol TmuxCommandExecuting: Sendable {
    func execute(arguments: [String], standardInput: Data?) async throws -> TmuxCommandResult
}

public extension TmuxCommandExecuting {
    func execute(arguments: [String]) async throws -> TmuxCommandResult {
        try await execute(arguments: arguments, standardInput: nil)
    }
}

/// Direct, shell-free tmux invocation used by the macOS adapter.
///
/// Only tmux's `pipe-pane` command receives a shell command, because tmux
/// itself requires one for its output pipe.  All control and input operations
/// use Process arguments and (for input) standard input bytes.
public actor ProcessTmuxCommandExecutor: TmuxCommandExecuting {
    private let configuredPath: String?
    private let environment: [String: String]
    private let serverArguments: [String]
    private var resolvedPath: String?

    public init(
        tmuxPath: String? = nil,
        environment: [String: String]? = nil,
        socketName: String? = nil
    ) {
        self.configuredPath = tmuxPath
        self.environment = WarrenTerminalEnvironment.sanitized(
            from: environment ?? ProcessInfo.processInfo.environment
        )
        if let socketName, !socketName.isEmpty {
            precondition(
                Self.isValidSocketName(socketName),
                "tmux socket name must contain only letters, numbers, dot, underscore, or hyphen."
            )
            self.serverArguments = ["-L", socketName]
        } else {
            self.serverArguments = []
        }
    }

    public func execute(
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> TmuxCommandResult {
        let path = try resolvePath()
        return try await runProcess(
            executablePath: path,
            arguments: serverArguments + arguments,
            standardInput: standardInput,
            environment: environment
        )
    }

    private static func isValidSocketName(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func resolvePath() throws -> String {
        if let resolvedPath {
            return resolvedPath
        }

        let candidates: [String]
        if let configuredPath {
            candidates = [configuredPath]
        } else {
            var values = [
                "/opt/homebrew/bin/tmux",
                "/usr/local/bin/tmux",
                "/usr/bin/tmux",
            ]
            if let path = environment["PATH"] {
                values.append(contentsOf: path.split(separator: ":").map { "\($0)/tmux" })
            }
            candidates = values
        }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            resolvedPath = candidate
            return candidate
        }
        throw TmuxCommandExecutorError.binaryNotFound(searchPaths: candidates)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        standardInput: Data?,
        environment: [String: String]
    ) async throws -> TmuxCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = standardInput == nil ? nil : Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TmuxCommandExecutorError.launchFailed(
                    path: executablePath,
                    reason: String(describing: error)
                ))
                return
            }

            process.terminationHandler = { process in
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: TmuxCommandResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                ))
            }

            if let standardInput, let stdinPipe {
                stdinPipe.fileHandleForWriting.write(standardInput)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }
    }
}
