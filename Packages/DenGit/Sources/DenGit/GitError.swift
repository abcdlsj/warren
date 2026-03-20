import Foundation

public enum GitError: Error, Sendable {
    case binaryNotFound
    case executionFailed(command: String, exitCode: Int32, stderr: String)
    case notAGitRepo(path: String)
    case worktreeAlreadyExists(path: String)
    case parseError(String)
}
