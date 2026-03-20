import SwiftUI
import DenCore

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

    @State private var editingProjectId: UUID?
    @State private var newBranchName = ""
    @State private var isSubmitting = false
    @State private var hoveredProjectId: UUID?

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
        onAddProject: (() -> Void)? = nil
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
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 {
                            sectionDivider
                        }
                        projectSection(project)
                    }

                    if projects.isEmpty {
                        emptyState
                    }
                }
                .padding(.top, DenTokens.Spacing.lg)
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DenTokens.Palette.mantle)
    }

    // MARK: - Section Divider

    private var sectionDivider: some View {
        DenTokens.Palette.surface0
            .frame(height: 1)
            .padding(.horizontal, DenTokens.Spacing.xl)
            .padding(.vertical, DenTokens.Spacing.xs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DenTokens.Spacing.lg) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(DenTokens.Palette.overlay0)

            Text("No projects")
                .font(DenTokens.Font.body)
                .foregroundStyle(DenTokens.Palette.overlay0)

            if let onAddProject {
                Button(action: onAddProject) {
                    Text("Add Repository")
                        .font(DenTokens.Font.footnote)
                        .foregroundStyle(DenTokens.Color.active)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DenTokens.Spacing.emptyState)
    }

    // MARK: - Project Section

    @ViewBuilder
    private func projectSection(_ project: Project) -> some View {
        projectHeader(project)

        if !project.isCollapsed {
            if editingProjectId == project.id {
                branchNameInput
                    .padding(.horizontal, DenTokens.Spacing.sm)
            }

            let projectWorktrees = worktrees.filter { $0.projectId == project.id }

            if projectWorktrees.isEmpty {
                Text("No worktrees")
                    .font(DenTokens.Font.caption2)
                    .foregroundStyle(DenTokens.Palette.overlay0)
                    .padding(.horizontal, DenTokens.Spacing.xl)
                    .padding(.vertical, DenTokens.Spacing.sm)
            }

            ForEach(projectWorktrees) { worktree in
                worktreeRow(worktree)
            }
        }
    }

    // MARK: - Project Header

    @ViewBuilder
    private func projectHeader(_ project: Project) -> some View {
        HStack(spacing: DenTokens.Spacing.md) {
            Image(systemName: project.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DenTokens.Palette.overlay0)
                .frame(width: 12)

            if let iconName = project.iconName {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(DenTokens.Color.active)
            }

            Text(project.name)
                .font(DenTokens.Font.sectionTitle)
                .foregroundStyle(DenTokens.Palette.subtext1)
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            if hoveredProjectId == project.id {
                HStack(spacing: DenTokens.Spacing.sm) {
                    if !project.isCollapsed, onCreateWorktree != nil {
                        Button {
                            onSelectProject?(project.id)
                            editingProjectId = project.id
                            newBranchName = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DenTokens.Palette.overlay1)
                        }
                        .buttonStyle(.plain)
                        .help("New Worktree")
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DenTokens.Spacing.xl)
        .padding(.top, DenTokens.Spacing.xl)
        .padding(.bottom, DenTokens.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleCollapse?(project.id)
            onSelectProject?(project.id)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredProjectId = hovering ? project.id : nil
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
    }

    // MARK: - Worktree Row

    @ViewBuilder
    private func worktreeRow(_ worktree: Worktree) -> some View {
        let isSelected = worktree.id == selectedWorktreeId
        let worktreeWindows = windows
            .filter { $0.worktreeId == worktree.id }
            .sorted { $0.tmuxWindowIndex < $1.tmuxWindowIndex }

        VStack(alignment: .leading, spacing: 0) {
            WorktreeRowView(
                worktree: worktree,
                isSelected: isSelected,
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

            if !worktreeWindows.isEmpty {
                ForEach(
                    Array(worktreeWindows.enumerated()), id: \.element.id
                ) { index, window in
                    WindowRowView(
                        window: window,
                        isActive: isSelected && window.tmuxWindowId == selectedWindowId,
                        shortcutIndex: isSelected && index < 9 ? index + 1 : nil,
                        onSelect: { onSelectWindow(window.tmuxWindowId) }
                    )
                    .padding(.leading, DenTokens.Spacing.xxl)
                }
            }
        }
        .padding(.horizontal, DenTokens.Spacing.sm)
    }

    // MARK: - Branch Name Input

    private var branchNameInput: some View {
        HStack(spacing: DenTokens.Spacing.sm) {
            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(DenTokens.Font.label)
                    .foregroundStyle(DenTokens.Color.muted)
            }

            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.plain)
                .font(DenTokens.Font.footnote)
                .foregroundStyle(DenTokens.Palette.text)
                .disabled(isSubmitting)
                .onSubmit { submitBranchName() }

            Button(action: { submitBranchName() }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DenTokens.Color.success)
            }
            .buttonStyle(.plain)
            .disabled(
                newBranchName.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting
            )

            Button(action: { cancelCreation() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DenTokens.Palette.overlay0)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, DenTokens.Spacing.lg)
        .padding(.vertical, DenTokens.Spacing.sm)
        .background(DenTokens.Palette.surface0.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DenTokens.Radius.small))
    }

    private func submitBranchName() {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        onCreateWorktree?(trimmed)
        editingProjectId = nil
        isSubmitting = false
        newBranchName = ""
    }

    private func cancelCreation() {
        editingProjectId = nil
        newBranchName = ""
    }

    // MARK: - Footer

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            DenTokens.Palette.surface0
                .frame(height: 1)

            HStack(spacing: DenTokens.Spacing.xl) {
                if let onAddProject {
                    Button(action: onAddProject) {
                        Image(systemName: "plus.rectangle.on.folder")
                            .font(.system(size: 13))
                            .foregroundStyle(DenTokens.Palette.overlay1)
                    }
                    .buttonStyle(.plain)
                    .help("Add Repository")
                }

                Spacer()
            }
            .padding(.horizontal, DenTokens.Spacing.xl)
            .padding(.vertical, DenTokens.Spacing.lg)
        }
        .background(DenTokens.Palette.crust)
    }
}
