import Foundation

/// Errors surfaced by tmux discovery, execution, or output parsing.
public enum TmuxError: Error, LocalizedError, Sendable {
    case binaryNotFound
    case executionFailed(command: String, exitCode: Int32, stderr: String)
    case notYetImplemented(String)
    case parseError(String)
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "tmux binary not found. Install via: brew install tmux"
        case .executionFailed(let command, let exitCode, let stderr):
            return "tmux failed (exit \(exitCode)): \(stderr.isEmpty ? command : stderr)"
        case .notYetImplemented(let method):
            return "tmux operation not yet implemented: \(method)"
        case .parseError(let detail):
            return "tmux parse error: \(detail)"
        case .sessionNotFound(let name):
            return "tmux session not found: \(name)"
        }
    }
}
