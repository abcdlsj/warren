import AppKit
import SwiftUI
import DenCore
import DenTerminal
import DenUI

// MARK: - Sidebar Hosting

@MainActor
final class SidebarHostingController: NSHostingController<SidebarContentView> {

    private let appState: AppState

    init(
        appState: AppState,
        onSelectProject: @escaping (UUID) -> Void,
        onSelectWorktree: @escaping (UUID) -> Void,
        onSelectWindow: @escaping (String) -> Void,
        onCreateWorktree: ((String) -> Void)? = nil,
        onRemoveWorktree: ((UUID) -> Void)? = nil,
        onRemoveProject: ((UUID) -> Void)? = nil,
        onToggleCollapse: ((UUID) -> Void)? = nil,
        onAddProject: (() -> Void)? = nil
    ) {
        self.appState = appState
        let rootView = SidebarContentView(
            appState: appState,
            onSelectProject: onSelectProject,
            onSelectWorktree: onSelectWorktree,
            onSelectWindow: onSelectWindow,
            onCreateWorktree: onCreateWorktree,
            onRemoveWorktree: onRemoveWorktree,
            onRemoveProject: onRemoveProject,
            onToggleCollapse: onToggleCollapse,
            onAddProject: onAddProject
        )
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAppearance(themeInfo: GhosttyThemeInfo) {
        view.appearance = NSAppearance(named: themeInfo.isDark ? .darkAqua : .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = themeInfo.background.cgColor
    }
}

// MARK: - Sidebar Content View

struct SidebarContentView: View {
    @Bindable var appState: AppState
    let onSelectProject: (UUID) -> Void
    let onSelectWorktree: (UUID) -> Void
    let onSelectWindow: (String) -> Void
    let onCreateWorktree: ((String) -> Void)?
    let onRemoveWorktree: ((UUID) -> Void)?
    let onRemoveProject: ((UUID) -> Void)?
    let onToggleCollapse: ((UUID) -> Void)?
    let onAddProject: (() -> Void)?

    var body: some View {
        WorktreeSidebarView(
            projects: appState.projects,
            worktrees: appState.worktrees,
            windows: appState.runtimeWindows,
            selectedProjectId: appState.uiState.selectedProjectId,
            selectedWorktreeId: appState.uiState.selectedWorktreeId,
            selectedWindowId: appState.uiState.selectedWindowId,
            onSelectProject: onSelectProject,
            onSelectWorktree: onSelectWorktree,
            onSelectWindow: onSelectWindow,
            onCreateWorktree: onCreateWorktree,
            onRemoveWorktree: onRemoveWorktree,
            onRemoveProject: onRemoveProject,
            onToggleCollapse: onToggleCollapse,
            onAddProject: onAddProject
        )
    }
}
