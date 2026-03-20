import Foundation

public actor TmuxCommandRunner {

    private var resolvedBinaryPath: String?
    private var shellEnvironment: [String: String]?

    public init() {}

    // MARK: - Shell Environment

    private func loadShellEnvironment() async -> [String: String] {
        if let cached = shellEnvironment {
            return cached
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let (output, _, exitCode) = try await runProcess(
                executablePath: shell,
                arguments: ["-l", "-i", "-c", "env"],
                environment: nil
            )
            if exitCode == 0 {
                var env: [String: String] = [:]
                for line in output.split(separator: "\n") {
                    if let eqIndex = line.firstIndex(of: "=") {
                        let key = String(line[line.startIndex..<eqIndex])
                        let value = String(line[line.index(after: eqIndex)...])
                        env[key] = value
                    }
                }
                shellEnvironment = env
                return env
            }
        } catch {
            // Fall through to process environment
        }

        let env = ProcessInfo.processInfo.environment
        shellEnvironment = env
        return env
    }

    // MARK: - Binary Resolution

    public func resolveBinaryPath() async throws -> String {
        if let cached = resolvedBinaryPath {
            return cached
        }

        let commonPaths = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                resolvedBinaryPath = path
                return path
            }
        }

        let env = await loadShellEnvironment()
        if let pathVar = env["PATH"] {
            let dirs = pathVar.split(separator: ":")
            for dir in dirs {
                let candidate = "\(dir)/tmux"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    resolvedBinaryPath = candidate
                    return candidate
                }
            }
        }

        throw TmuxError.binaryNotFound
    }

    public func isAvailable() async -> Bool {
        do {
            _ = try await resolveBinaryPath()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Command Execution

    public func run(_ arguments: String...) async throws -> String {
        try await run(arguments)
    }

    public func run(_ arguments: [String]) async throws -> String {
        let binaryPath = try await resolveBinaryPath()
        let env = await loadShellEnvironment()
        let (stdout, stderr, exitCode) = try await runProcess(
            executablePath: binaryPath,
            arguments: arguments,
            environment: env
        )

        if exitCode != 0 {
            let cmd = "tmux \(arguments.joined(separator: " "))"
            if exitCode == 1 && stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ""
            }
            let errorMessage = stderr.isEmpty ? stdout : stderr
            throw TmuxError.executionFailed(command: cmd, exitCode: exitCode, stderr: errorMessage)
        }

        return stdout
    }

    // MARK: - Private

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> (output: String, stderr: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.terminationHandler = { _ in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: (output, stderr, process.terminationStatus))
            }
        }
    }
}
