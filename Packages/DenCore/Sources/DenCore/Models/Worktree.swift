import Foundation

/// Persisted metadata for one logical branch checkout / workspace.
public struct Worktree: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let projectId: UUID
    public var name: String
    public var path: String
    public var branch: String?
    public var headSHA: String?
    public var isMainWorktree: Bool
    public var isDetached: Bool
    /// Dirty/ahead/behind are denormalized from polling so the sidebar can render without extra git calls.
    public var hasUncommittedChanges: Bool
    public var aheadCount: Int
    public var behindCount: Int
    public var lastActiveAt: Date?
    /// Persisted tmux identity lets runtime sessions be recreated deterministically.
    public var tmuxSessionId: String?
    public var tmuxSessionName: String?

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        path: String,
        branch: String? = nil,
        headSHA: String? = nil,
        isMainWorktree: Bool = false,
        isDetached: Bool = false,
        hasUncommittedChanges: Bool = false,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        lastActiveAt: Date? = nil,
        tmuxSessionId: String? = nil,
        tmuxSessionName: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.path = path
        self.branch = branch
        self.headSHA = headSHA
        self.isMainWorktree = isMainWorktree
        self.isDetached = isDetached
        self.hasUncommittedChanges = hasUncommittedChanges
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.lastActiveAt = lastActiveAt
        self.tmuxSessionId = tmuxSessionId
        self.tmuxSessionName = tmuxSessionName
    }
}
