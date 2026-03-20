import Foundation

public actor GitCommandRunner {

    private var resolvedBinaryPath: String?

    public init() {}

    // MARK: - Binary Resolution

    public func resolveBinaryPath() async throws -> String {
        if let cached = resolvedBinaryPath {
            return cached
        }

        let commonPaths = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                resolvedBinaryPath = path
                return path
            }
        }

        let (output, exitCode) = try await runProcess(
            executablePath: "/usr/bin/which",
            arguments: ["git"]
        )

        if exitCode == 0 {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                resolvedBinaryPath = path
                return path
            }
        }

        throw GitError.binaryNotFound
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
        let (stdout, exitCode) = try await runProcess(
            executablePath: binaryPath,
            arguments: arguments
        )

        if exitCode != 0 {
            let cmd = "git \(arguments.joined(separator: " "))"
            throw GitError.executionFailed(command: cmd, exitCode: exitCode, stderr: stdout)
        }

        return stdout
    }

    public func run(in directory: String, _ arguments: [String]) async throws -> String {
        try await run(["-C", directory] + arguments)
    }

    // MARK: - Private

    private func runProcess(
        executablePath: String,
        arguments: [String]
    ) async throws -> (output: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let output = stderr.isEmpty ? stdout : stderr
                continuation.resume(returning: (output, process.terminationStatus))
            }
        }
    }
}
