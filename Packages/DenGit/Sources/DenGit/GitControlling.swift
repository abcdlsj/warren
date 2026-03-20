import Foundation

public protocol GitControlling: Sendable {

    func listWorktrees(repoPath: String) async throws -> [GitWorktreeInfo]

    func addWorktree(repoPath: String, path: String, branch: String, createBranch: Bool) async throws

    func removeWorktree(repoPath: String, path: String, force: Bool) async throws

    func status(worktreePath: String) async throws -> GitStatusInfo

    func isGitRepo(path: String) async throws -> Bool

    func gitCommonDir(path: String) async throws -> String
}
