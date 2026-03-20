import Foundation

/// Parsed summary of one entry from `git worktree list --porcelain`.
public struct GitWorktreeInfo: Equatable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool

    public init(
        path: String,
        head: String,
        branch: String? = nil,
        isDetached: Bool = false,
        isBare: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
    }

    public var branchName: String? {
        // Porcelain output uses full refs; most callers only care about the human branch name.
        guard let branch else { return nil }
        let prefix = "refs/heads/"
        if branch.hasPrefix(prefix) {
            return String(branch.dropFirst(prefix.count))
        }
        return branch
    }
}
