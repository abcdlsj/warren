import Foundation
import GRDB
import DenCore

public struct WorktreeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "worktree"

    public var id: String
    public var projectId: String
    public var name: String
    public var path: String
    public var branch: String?
    public var headSHA: String?
    public var isMainWorktree: Bool
    public var isDetached: Bool
    public var hasUncommittedChanges: Bool
    public var aheadCount: Int
    public var behindCount: Int
    public var lastActiveAt: Date?
    public var tmuxSessionId: String?
    public var tmuxSessionName: String?

    public init(from worktree: Worktree) {
        self.id = worktree.id.uuidString
        self.projectId = worktree.projectId.uuidString
        self.name = worktree.name
        self.path = worktree.path
        self.branch = worktree.branch
        self.headSHA = worktree.headSHA
        self.isMainWorktree = worktree.isMainWorktree
        self.isDetached = worktree.isDetached
        self.hasUncommittedChanges = worktree.hasUncommittedChanges
        self.aheadCount = worktree.aheadCount
        self.behindCount = worktree.behindCount
        self.lastActiveAt = worktree.lastActiveAt
        self.tmuxSessionId = worktree.tmuxSessionId
        self.tmuxSessionName = worktree.tmuxSessionName
    }

    public func toModel() -> Worktree? {
        guard let uuid = UUID(uuidString: id),
              let projUUID = UUID(uuidString: projectId) else {
            return nil
        }
        return Worktree(
            id: uuid,
            projectId: projUUID,
            name: name,
            path: path,
            branch: branch,
            headSHA: headSHA,
            isMainWorktree: isMainWorktree,
            isDetached: isDetached,
            hasUncommittedChanges: hasUncommittedChanges,
            aheadCount: aheadCount,
            behindCount: behindCount,
            lastActiveAt: lastActiveAt,
            tmuxSessionId: tmuxSessionId,
            tmuxSessionName: tmuxSessionName
        )
    }
}
