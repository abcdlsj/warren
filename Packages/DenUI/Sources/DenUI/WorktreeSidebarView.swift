import SwiftUI
import DenCore

/// SwiftUI sidebar showing projects, worktrees, and runtime tmux windows.
public struct WorktreeSidebarView: View {
    private let projects: [Project]
    private let worktrees: [Worktree]
    private let windows: [RuntimeWindow]
    private let selectedProjectId: UUID?
    private let selectedWorktreeId: UUID?
    private let selectedWindowId: String?
    private let onSelectProject: ((UUID) -> Void)?
    private let onSelectWorktree: (UUID) -> Void
    private let onSelectWindow: (String) -> Void
    private let onCreateWorktree: ((String) -> Void)?
    private let onRemoveWorktree: ((UUID) -> Void)?
    private let onRemoveProject: ((UUID) -> Void)?
    private let onToggleCollapse: ((UUID) -> Void)?
    private let onAddProject: (() -> Void)?
    private let poppedOutWorktreeIds: Set<UUID>

    @State private var editingProjectId: UUID?
    @State private var newBranchName = ""
    @State private var isSubmitting = false

    public init(
        projects: [Project] = [],
        worktrees: [Worktree] = [],
        windows: [RuntimeWindow] = [],
        selectedProjectId: UUID? = nil,
        selectedWorktreeId: UUID? = nil,
        selectedWindowId: String? = nil,
        onSelectProject: ((UUID) -> Void)? = nil,
        onSelectWorktree: @escaping (UUID) -> Void,
        onSelectWindow: @escaping (String) -> Void,
        onCreateWorktree: ((String) -> Void)? = nil,
        onRemoveWorktree: ((UUID) -> Void)? = nil,
        onRemoveProject: ((UUID) -> Void)? = nil,
        onToggleCollapse: ((UUID) -> Void)? = nil,
        onAddProject: (() -> Void)? = nil,
        poppedOutWorktreeIds: Set<UUID> = []
    ) {
        self.projects = projects
        self.worktrees = worktrees
        self.windows = windows
        self.selectedProjectId = selectedProjectId
        self.selectedWorktreeId = selectedWorktreeId
        self.selectedWindowId = selectedWindowId
        self.onSelectProject = onSelectProject
        self.onSelectWorktree = onSelectWorktree
        self.onSelectWindow = onSelectWindow
        self.onCreateWorktree = onCreateWorktree
        self.onRemoveWorktree = onRemoveWorktree
        self.onRemoveProject = onRemoveProject
        self.onToggleCollapse = onToggleCollapse
        self.onAddProject = onAddProject
        self.poppedOutWorktreeIds = poppedOutWorktreeIds
    }

    private enum Layout {
        static let sidePadding: CGFloat = 14
        static let rowHeight: CGFloat = 40
        static let sectionSpacing: CGFloat = 6
        static let childIndent: CGFloat = 18
    }

    public var body: some View {
        ZStack {
            DenTokens.Color.panel

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Layout.sidePadding)
                    .padding(.top, 12)

                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        ForEach(projects) { project in
                            projectSection(project)
                        }

                        if projects.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, Layout.sidePadding)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }

                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DenTokens.Color.border.opacity(0.95))
                .frame(width: 1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)

                Text("Workspaces")
                    .font(DenTokens.Font.headline)

                Spacer(minLength: 0)
            }
            .foregroundStyle(DenTokens.Palette.text)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(DenTokens.Color.rowSelected)
            .clipShape(.rect(cornerRadius: 8))

            Text("\(projects.count) projects  \(worktrees.count) branches  \(windows.count) sessions")
                .font(DenTokens.Font.caption)
                .foregroundStyle(DenTokens.Palette.subtext0)
                .padding(.horizontal, 10)
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DenTokens.Color.border.opacity(0.88))
                .frame(height: 1)
        }
    }

    private func addRepositoryButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DenTokens.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)

                Text("Add Repository")
                    .font(DenTokens.Font.body)

                Spacer(minLength: 0)
            }
            .foregroundStyle(DenTokens.Palette.subtext1)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(SwiftUI.Color.clear)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DenTokens.Color.border.opacity(0.82), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func projectSection(_ project: Project) -> some View {
        let projectWorktrees = worktrees.filter { $0.projectId == project.id }
        let isSelected = selectedProjectId == project.id
        // Only the selected project expands; the sidebar behaves like a focused navigator, not a full tree explorer.
        let showChildren = isSelected && !project.isCollapsed

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DenTokens.Spacing.sm) {
                Button {
                    onSelectProject?(project.id)
                } label: {
                    HStack(spacing: 10) {
                        ProjectBadge(project.name, size: 18)

                        Text(project.name)
                            .font(DenTokens.Font.headline)
                            .foregroundStyle(isSelected ? DenTokens.Palette.text : DenTokens.Palette.subtext1)
                            .lineLimit(1)

                        Text("\(projectWorktrees.count)")
                            .font(DenTokens.Font.caption)
                            .foregroundStyle(DenTokens.Palette.overlay0)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Layout.rowHeight, alignment: .leading)
                    .padding(.leading, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if onCreateWorktree != nil {
                    iconActionButton(systemName: "plus") {
                        onSelectProject?(project.id)
                        editingProjectId = project.id
                        newBranchName = ""
                    }
                    .help("New Worktree")
                }

                iconActionButton(systemName: project.isCollapsed ? "chevron.right" : "chevron.down") {
                    onToggleCollapse?(project.id)
                }
                .help(project.isCollapsed ? "Expand" : "Collapse")
            }
            .padding(.trailing, 6)
            .padding(.vertical, 2)
            .background(isSelected ? DenTokens.Color.rowSelected : SwiftUI.Color.clear)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: DenTokens.Radius.small, style: .continuous)
                        .fill(DenTokens.Color.accent)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contextMenu {
                if onCreateWorktree != nil {
                    Button {
                        onSelectProject?(project.id)
                        editingProjectId = project.id
                        newBranchName = ""
                    } label: {
                        Label("New Worktree...", systemImage: "plus")
                    }
                }

                Divider()

                Button {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: project.repoRootPath
                    )
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                if let onRemoveProject {
                    Divider()
                    Button(role: .destructive) {
                        onRemoveProject(project.id)
                    } label: {
                        Label("Remove Project...", systemImage: "trash")
                    }
                }
            }

            if showChildren {
                VStack(alignment: .leading, spacing: 8) {
                    if editingProjectId == project.id {
                        branchNameInput
                    }

                    ForEach(projectWorktrees) { worktree in
                        worktreeRow(worktree)
                    }
                }
                .padding(.leading, Layout.childIndent)
                .padding(.trailing, 6)
                .padding(.bottom, 12)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconActionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DenTokens.Palette.overlay0)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func worktreeRow(_ worktree: Worktree) -> some View {
        let isSelected = worktree.id == selectedWorktreeId
        let worktreeWindows = windows
            .filter { $0.worktreeId == worktree.id }
            .sorted { $0.tmuxWindowIndex < $1.tmuxWindowIndex }

        VStack(alignment: .leading, spacing: 8) {
            WorktreeRowView(
                worktree: worktree,
                isSelected: isSelected,
                isPoppedOut: poppedOutWorktreeIds.contains(worktree.id),
                onSelect: { onSelectWorktree(worktree.id) },
                onRemove: onRemoveWorktree.map { remove in { remove(worktree.id) } }
            )
            .contextMenu {
                Button {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: worktree.path
                    )
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                if !worktree.isMainWorktree, let onRemove = onRemoveWorktree {
                    Divider()
                    Button(role: .destructive) {
                        onRemove(worktree.id)
                    } label: {
                        Label("Remove Worktree...", systemImage: "trash")
                    }
                }
            }

            if isSelected, !worktreeWindows.isEmpty {
                // Runtime windows are shown only for the active worktree to keep the sidebar compact.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sessions")
                        .font(DenTokens.Font.caption2)
                        .foregroundStyle(DenTokens.Palette.overlay0)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .padding(.leading, 10)
                        .padding(.bottom, 2)

                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(worktreeWindows.enumerated()), id: \.element.id) { index, window in
                            WindowRowView(
                                window: window,
                                isActive: window.tmuxWindowId == selectedWindowId,
                                shortcutIndex: index < 9 ? index + 1 : nil,
                                onSelect: { onSelectWindow(window.tmuxWindowId) }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
                .padding(.top, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DenTokens.Palette.surface1.opacity(0.72))
                        .frame(width: 1)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                }
            }
        }
    }

    private var branchNameInput: some View {
        HStack(spacing: DenTokens.Spacing.sm) {
            Image(systemName: isSubmitting ? "hourglass" : "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DenTokens.Color.muted)

            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.plain)
                .font(DenTokens.Font.caption)
                .foregroundStyle(DenTokens.Palette.text)
                .disabled(isSubmitting)
                .onSubmit { submitBranchName() }

            iconActionButton(systemName: "checkmark") {
                submitBranchName()
            }
            .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)

            iconActionButton(systemName: "xmark") {
                cancelCreation()
            }
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DenTokens.Color.panelRaised)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DenTokens.Color.border, lineWidth: 0.8)
        )
    }

    private func submitBranchName() {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        // Creation itself is asynchronous in the app layer; locally we just disable the input briefly.
        onCreateWorktree?(trimmed)
        editingProjectId = nil
        isSubmitting = false
        newBranchName = ""
    }

    private func cancelCreation() {
        editingProjectId = nil
        newBranchName = ""
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No repository yet")
                .font(DenTokens.Font.caption)
                .foregroundStyle(DenTokens.Palette.overlay0)

            Text("Use Add Repository to start")
                .font(DenTokens.Font.caption2)
                .foregroundStyle(DenTokens.Palette.subtext0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let onAddProject {
                addRepositoryButton(onAddProject)
            }

            HStack(spacing: DenTokens.Spacing.sm) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DenTokens.Palette.overlay0)

                Text("⌘1-9 sessions  Ctrl+Tab branches")
                    .font(DenTokens.Font.caption2)
                    .foregroundStyle(DenTokens.Palette.subtext0)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Layout.sidePadding)
        .padding(.vertical, 12)
        .background(DenTokens.Palette.mantle)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DenTokens.Palette.surface1.opacity(0.78))
                .frame(height: 1)
        }
    }
}
