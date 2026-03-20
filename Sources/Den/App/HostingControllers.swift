import AppKit
import SwiftUI
import DenCore
import DenTerminal
import DenUI

// MARK: - Sidebar Hosting

/// Thin AppKit wrapper around the SwiftUI sidebar tree.
@MainActor
final class SidebarHostingController: NSViewController {

    private let appState: AppState
    private let hostingController: NSHostingController<SidebarContentView>

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
        self.hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        // Host the SwiftUI sidebar inside an AppKit container so split-view sizing still works normally.
        addChild(hostingController)
        let hostingView = hostingController.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.view = container
    }

    func updateAppearance(themeInfo: TerminalThemeInfo) {
        view.appearance = NSAppearance(named: themeInfo.isDark ? .darkAqua : .aqua)
    }
}

// MARK: - Sidebar Content View

/// Adapter that turns observable AppState into the explicit props consumed by DenUI.
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
            // Pass snapshots instead of the full AppState so the UI package stays presentation-only.
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
            onAddProject: onAddProject,
            poppedOutWorktreeIds: appState.poppedOutWorktreeIds
        )
    }
}
