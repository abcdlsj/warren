import Foundation

/// Runtime view of one tmux window discovered in the latest poll.
public struct RuntimeWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tmuxWindowId }
    public let tmuxWindowId: String
    public let worktreeId: UUID
    public var tmuxWindowIndex: Int
    public var title: String
    public var activePaneId: String?
    public var paneCount: Int
    public var cwd: String?

    public init(
        tmuxWindowId: String,
        worktreeId: UUID,
        tmuxWindowIndex: Int = 0,
        title: String = "",
        activePaneId: String? = nil,
        paneCount: Int = 1,
        cwd: String? = nil
    ) {
        self.tmuxWindowId = tmuxWindowId
        self.worktreeId = worktreeId
        self.tmuxWindowIndex = tmuxWindowIndex
        self.title = title
        self.activePaneId = activePaneId
        self.paneCount = paneCount
        self.cwd = cwd
    }
}
