import Foundation
import WarrenHost

extension TmuxRuntime {
    func hasSession(named name: String) async throws -> Bool {
        let arguments = ["has-session", "-t", name]
        let result = try await execute(arguments: arguments)
        if result.exitCode == 0 { return true }
        if result.exitCode == 1 { return false }
        throw commandError(
            arguments: arguments,
            result: result,
            recovery: "Check tmux server status, then retry."
        )
    }

    func probeManagedSessions() async -> [String: TerminalRuntimeMetadata]? {
        do {
            let separator = "|"
            let arguments = [
                "list-panes", "-a", "-F",
                "#{session_name}\(separator)#{pane_current_command}\(separator)#{pane_current_path}",
            ]
            let result = try await execute(arguments: arguments)
            // tmux exits 1 when no server/sessions exist. That is a valid
            // empty snapshot; higher exit codes and executor failures remain
            // transient observation errors.
            if result.exitCode == 1 { return [:] }
            guard result.exitCode == 0 else { return nil }
            var observations: [String: TerminalRuntimeMetadata] = [:]
            for line in result.stdoutText.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: Character(separator), maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { continue }
                observations[String(fields[0])] = TerminalRuntimeMetadata(
                    process: String(fields[1]),
                    workingDirectory: String(fields[2])
                )
            }
            return observations
        } catch {
            // A transient tmux invocation failure must not immediately report
            // an exit. The next monitor tick gets another chance.
            return nil
        }
    }

    func paneTarget(for name: String) async throws -> String {
        let arguments = ["display-message", "-p", "-t", name, "#{pane_id}"]
        let result = try await execute(arguments: arguments)
        guard result.exitCode == 0 else {
            throw commandError(
                arguments: arguments,
                result: result,
                recovery: "Ensure the new tmux session has an available pane."
            )
        }
        let target = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw TmuxRuntimeError.descriptorInvalid(
                reason: "tmux returned no pane target.",
                recovery: "Close the orphaned session, then create a new one."
            )
        }
        return target
    }

    func resolvePaneTarget(from descriptor: TerminalRuntimeDescriptor) async throws -> String {
        if let target = descriptor.metadata["paneTarget"], !target.isEmpty {
            let arguments = ["display-message", "-p", "-t", target, "#{pane_id}"]
            let result = try await execute(arguments: arguments)
            if result.exitCode == 0 {
                return target
            }
        }
        return try await paneTarget(for: descriptor.identifier)
    }

    func requireSuccess(
        _ arguments: [String],
        standardInput: Data? = nil,
        recovery: String
    ) async throws {
        let result = try await execute(arguments: arguments, standardInput: standardInput)
        guard result.exitCode == 0 else {
            throw commandError(arguments: arguments, result: result, recovery: recovery)
        }
    }

    func execute(
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> TmuxCommandResult {
        do {
            return try await executor.execute(arguments: arguments, standardInput: standardInput)
        } catch let error as TmuxRuntimeError {
            throw error
        } catch {
            if let mapped = TmuxRuntimeError.fromExecutor(error) {
                throw mapped
            }
            throw TmuxRuntimeError.commandFailed(
                arguments: arguments,
                exitCode: -1,
                stderr: String(describing: error),
                recovery: "Check the tmux process and local execution environment, then retry."
            )
        }
    }

    func commandError(
        arguments: [String],
        result: TmuxCommandResult,
        recovery: String
    ) -> TmuxRuntimeError {
        .commandFailed(
            arguments: arguments,
            exitCode: result.exitCode,
            stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines),
            recovery: recovery
        )
    }
}
