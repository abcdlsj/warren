import Foundation

/// Persisted UI selection and small presentation flags.
public struct UIState: Codable, Equatable, Sendable {
    public var selectedProjectId: UUID?
    public var selectedWorktreeId: UUID?
    public var selectedWindowId: String?
    /// Reserved for future sidebar variants such as global search.
    public var sidebarMode: SidebarMode
    public var searchQuery: String

    public init(
        selectedProjectId: UUID? = nil,
        selectedWorktreeId: UUID? = nil,
        selectedWindowId: String? = nil,
        sidebarMode: SidebarMode = .worktrees,
        searchQuery: String = ""
    ) {
        self.selectedProjectId = selectedProjectId
        self.selectedWorktreeId = selectedWorktreeId
        self.selectedWindowId = selectedWindowId
        self.sidebarMode = sidebarMode
        self.searchQuery = searchQuery
    }
}
