import Foundation

/// Central observable state shared by the AppKit shell and SwiftUI sidebar.
@MainActor
@Observable
public final class AppState {
    /// Long-lived project metadata persisted in GRDB.
    public var projects: [Project] = []
    /// Long-lived worktree metadata persisted in GRDB.
    public var worktrees: [Worktree] = []
    /// Runtime-only tmux windows discovered during polling.
    public var runtimeWindows: [RuntimeWindow] = []
    /// Runtime-only tmux panes discovered during polling.
    public var runtimePanes: [RuntimePane] = []
    /// Persisted UI selection and sidebar state.
    public var uiState: UIState = UIState()
    /// Worktrees currently rendered in detached popout windows.
    public var poppedOutWorktreeIds: Set<UUID> = []

    public init() {}

    // MARK: - Derived state

    public var selectedProject: Project? {
        guard let id = uiState.selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    public var selectedWorktree: Worktree? {
        guard let id = uiState.selectedWorktreeId else { return nil }
        return worktrees.first { $0.id == id }
    }

    public var selectedWindow: RuntimeWindow? {
        guard let id = uiState.selectedWindowId else { return nil }
        return runtimeWindows.first { $0.tmuxWindowId == id }
    }

    public var worktreesForSelectedProject: [Worktree] {
        guard let projectId = uiState.selectedProjectId else { return [] }
        return worktrees.filter { $0.projectId == projectId }
    }

    public var windowsForSelectedWorktree: [RuntimeWindow] {
        guard let worktreeId = uiState.selectedWorktreeId else { return [] }
        return runtimeWindows
            .filter { $0.worktreeId == worktreeId }
            .sorted { $0.tmuxWindowIndex < $1.tmuxWindowIndex }
    }

    public func panes(forWindow windowId: String) -> [RuntimePane] {
        runtimePanes.filter { $0.tmuxWindowId == windowId }
    }
}
