import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopSidebarRows: View {
    let groups: [WarrenDesktopProjectGroup]
    let workspaceActivities: [WorkspaceID: AgentActivityState]
    @Binding var tree: WarrenDesktopSidebarTreeState
    let isCollapsed: Bool
    let selection: WarrenDesktopSidebarSelection?
    let onAddProject: () -> Void
    let onAction: (WarrenDesktopAction) -> Void

    @State private var pendingRename: Workspace?
    @State private var workspaceName = ""
    @State private var pendingRenameProject: Project?
    @State private var projectName = ""
    @State private var dragSource: WarrenDesktopSidebarDragSource?
    @State private var dragTargetID: String?
    @State private var dragRestoreExpansions: Set<ProjectID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let endMarker = "warren.sidebar.drag.end"

    var body: some View {
        LazyVStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            if !isCollapsed {
                WarrenDesktopSidebarSectionHeader(
                    title: "Projects",
                    disclosureExpanded: !tree.projectsCollapsed,
                    actionImage: "folder.badge.plus",
                    actionLabel: "Add project",
                    onToggle: toggleProjects,
                    onAction: onAddProject
                )
            }
            if groups.isEmpty && !isCollapsed {
                VStack(spacing: WarrenSpacing.xs) {
                    Text("No workspaces yet")
                        .font(WarrenTypography.body)
                    Text("Add a project or drop a Git repository folder")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.vertical, WarrenSpacing.large)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No workspaces yet. Add a project or drop a Git repository folder.")
            }
            if isCollapsed || !tree.projectsCollapsed {
                ForEach(groups) { group in
                    WarrenDesktopProjectRow(
                        project: group.project,
                        workspaceCount: group.workspaces.count,
                        isCollapsed: isCollapsed,
                        isSelected: selection == .project(group.project.id),
                        isExpanded: tree.expandedProjectIDs.contains(group.project.id),
                        isPinned: group.project.pinned,
                        onSelect: { select(.project(group.project.id)) },
                        onToggleExpansion: { toggleProject(group.project.id) },
                        onAddWorkspace: {
                            onAction(.requestNewWorkspace(group.project.id))
                        },
                        onRename: {
                            projectName = group.project.name
                            pendingRenameProject = group.project
                        },
                        onTogglePin: {
                            onAction(.setProjectPinned(
                                group.project.id,
                                !group.project.pinned
                            ))
                        }
                    )
                    .simultaneousGesture(projectDragGesture(projectID: group.project.id))
                    .onHover { hovering in
                        updateDragTarget(.project, id: group.project.id.description, hovering: hovering)
                    }
                    .overlay {
                        dragTargetIndicator(.project, id: group.project.id.description)
                    }
                    if isCollapsed || tree.expandedProjectIDs.contains(group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            WarrenDesktopWorkspaceRow(
                                workspace: workspace,
                                semanticScope: "project-list",
                                activity: workspaceActivity(workspace.id),
                                isCollapsed: isCollapsed,
                                isSelected: selection == .workspace(workspace.id),
                                isPinned: workspace.pinned,
                                onSelect: { select(.workspace(workspace.id)) },
                                onDoubleClick: { onAction(.launchSession(workspace.id, .shell)) },
                                onRename: {
                                    workspaceName = workspace.name
                                    pendingRename = workspace
                                },
                                onTogglePin: {
                                    onAction(.setWorkspacePinned(
                                        workspace.id,
                                        !workspace.pinned
                                    ))
                                }
                            )
                            .id(workspace.id)
                            .transition(.opacity)
                            .simultaneousGesture(workspaceDragGesture(workspace: workspace))
                            .onHover { hovering in
                                updateDragTarget(
                                    .workspace,
                                    id: workspace.id.description,
                                    projectID: workspace.projectID,
                                    hovering: hovering
                                )
                            }
                            .overlay {
                                dragTargetIndicator(.workspace, id: workspace.id.description)
                            }
                        }
                        if dragSource?.kind == .workspace,
                           dragSource?.projectID == group.project.id {
                            dragEndSlot(.workspace, projectID: group.project.id)
                        }
                    }
                }
                .transition(.opacity)
                if dragSource?.kind == .project {
                    dragEndSlot(.project)
                }
            }
        }
        .onChange(of: selection) { _, newSelection in
            guard case .workspace(let workspaceID)? = newSelection,
                  let workspace = groups
                    .flatMap(\.workspaces)
                    .first(where: { $0.id == workspaceID })
            else { return }
            _ = withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                tree.expandedProjectIDs.insert(workspace.projectID)
            }
        }
        .alert("Rename Workspace", isPresented: Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        )) {
            TextField("Workspace name", text: $workspaceName)
            Button("Rename") {
                guard let workspace = pendingRename else { return }
                pendingRename = nil
                onAction(.renameWorkspace(workspace.id, workspaceName))
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        } message: {
            Text("The Git branch name and worktree path are unchanged.")
        }
        .alert("Rename Project", isPresented: Binding(
            get: { pendingRenameProject != nil },
            set: { if !$0 { pendingRenameProject = nil } }
        )) {
            TextField("Project name", text: $projectName)
            Button("Rename") {
                guard let project = pendingRenameProject else { return }
                pendingRenameProject = nil
                onAction(.renameProject(project.id, projectName))
            }
            Button("Cancel", role: .cancel) { pendingRenameProject = nil }
        } message: {
            Text("Only the sidebar label changes; the repository path stays the same.")
        }
        .onChange(of: groups) { oldGroups, newGroups in
            guard let projectID = selectedProjectID else { return }
            let oldCount = workspaceCount(for: projectID, in: oldGroups)
            let newCount = workspaceCount(for: projectID, in: newGroups)
            guard newCount > oldCount else { return }
            _ = withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                tree.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private var selectedProjectID: ProjectID? {
        switch selection {
        case .project(let projectID):
            return projectID
        case .workspace(let workspaceID):
            return groups.first { $0.workspaces.contains { $0.id == workspaceID } }?.project.id
        case nil:
            return nil
        }
    }

    private func workspaceCount(
        for projectID: ProjectID,
        in groups: [WarrenDesktopProjectGroup]
    ) -> Int {
        groups.first { $0.project.id == projectID }?.workspaces.count ?? 0
    }

    private func select(_ newSelection: WarrenDesktopSidebarSelection) {
        switch newSelection {
        case .project(let projectID):
            onAction(.selectProject(projectID))
        case .workspace(let workspaceID):
            onAction(.selectWorkspace(workspaceID))
        }
    }

    private func toggleProject(_ projectID: ProjectID) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if tree.expandedProjectIDs.contains(projectID) {
                tree.expandedProjectIDs.remove(projectID)
            } else {
                tree.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private func toggleProjects() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            tree.projectsCollapsed.toggle()
        }
    }

    private func workspaceActivity(_ workspaceID: WorkspaceID) -> AgentActivityState? {
        workspaceActivities[workspaceID]
    }

    private func projectDragGesture(projectID: ProjectID) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                beginDrag(.project, id: projectID.description, projectID: nil)
            }
            .onEnded { _ in
                finishDrag(.project)
            }
    }

    private func workspaceDragGesture(workspace: Workspace) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                beginDrag(
                    .workspace,
                    id: workspace.id.description,
                    projectID: workspace.projectID
                )
            }
            .onEnded { _ in
                finishDrag(.workspace)
            }
    }

    private func beginDrag(
        _ kind: WarrenDesktopSidebarDragKind,
        id: String,
        projectID: ProjectID?
    ) {
        guard dragSource == nil,
              !isCollapsed,
              NSEvent.modifierFlags.contains(.command) else { return }
        dragSource = WarrenDesktopSidebarDragSource(
            kind: kind,
            id: id,
            projectID: projectID
        )
        dragTargetID = nil
        dragRestoreExpansions = tree.expandedProjectIDs
        if kind == .project {
            // Project reordering shows the whole project list: collapse every
            // project while dragging, then restore the previous expansion set.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                tree.expandedProjectIDs = []
            }
        }
    }

    private func finishDrag(_ kind: WarrenDesktopSidebarDragKind) {
        guard let source = dragSource, source.kind == kind else { return }
        defer {
            if source.kind == .project {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    tree.expandedProjectIDs = dragRestoreExpansions
                }
            }
            dragSource = nil
            dragTargetID = nil
            dragRestoreExpansions = []
        }
        guard let target = dragTargetID else { return }
        switch kind {
        case .project:
            guard let sourceID = ProjectID(uuidString: source.id) else { return }
            let before = target == Self.endMarker
                ? nil
                : ProjectID(uuidString: target)
            if target == Self.endMarker || before != nil {
                onAction(.moveProject(sourceID, before: before))
            }
        case .workspace:
            guard let sourceID = WorkspaceID(uuidString: source.id) else { return }
            let before = target == Self.endMarker
                ? nil
                : WorkspaceID(uuidString: target)
            if target == Self.endMarker || before != nil {
                onAction(.moveWorkspace(sourceID, before: before))
            }
        }
    }

    private func updateDragTarget(
        _ kind: WarrenDesktopSidebarDragKind,
        id: String,
        projectID: ProjectID? = nil,
        hovering: Bool
    ) {
        guard let source = dragSource, source.kind == kind else { return }
        if kind == .workspace, let projectID, source.projectID != projectID {
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if hovering {
                dragTargetID = id
            } else if dragTargetID == id {
                dragTargetID = nil
            }
        }
    }

    @ViewBuilder
    private func dragTargetIndicator(
        _ kind: WarrenDesktopSidebarDragKind,
        id: String
    ) -> some View {
        if dragSource?.kind == kind, dragTargetID == id {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            RoundedRectangle(cornerRadius: WarrenRadius.row)
                .strokeBorder(tokens.ring.opacity(0.75), lineWidth: 1)
                .padding(.horizontal, WarrenSpacing.compact)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func dragEndSlot(
        _ kind: WarrenDesktopSidebarDragKind,
        projectID: ProjectID? = nil
    ) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Color.clear
            .frame(height: WarrenSpacing.standard)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if dragTargetID == Self.endMarker {
                    RoundedRectangle(cornerRadius: WarrenRadius.row)
                        .fill(tokens.ring.opacity(0.35))
                        .padding(.horizontal, WarrenSpacing.compact)
                }
            }
            .onHover { hovering in
                guard let source = dragSource, source.kind == kind,
                      kind != .workspace || source.projectID == projectID else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    dragTargetID = hovering ? Self.endMarker : nil
                }
            }
            .padding(.horizontal, WarrenSpacing.compact)
    }
}

private enum WarrenDesktopSidebarDragKind: String {
    case project
    case workspace
}

private struct WarrenDesktopSidebarDragSource {
    let kind: WarrenDesktopSidebarDragKind
    let id: String
    let projectID: ProjectID?
}

private struct WarrenDesktopSessionRow: View {
    let session: WarrenDesktopSession
    let workspace: Workspace?
    let isSelected: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @FocusState private var isActionFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.compact) {
            Button(action: onOpen) {
                HStack(spacing: WarrenSpacing.compact) {
                    if let activity = session.activity {
                        WarrenDesktopActivityIndicator(activity: activity)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(WarrenTypography.navigationItem)
                            .foregroundStyle(tokens.foreground.opacity(0.86))
                            .lineLimit(1)
                        if let workspace {
                            Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name)
                                .font(WarrenTypography.navigationMeta)
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isFocused: isActionFocused))
            .focused($isActionFocused)
            .warrenSemanticElement(
                id: "session.\(session.id.description)",
                role: .button,
                label: "Open Session \(session.title)",
                value: isSelected ? "Selected" : nil,
                isSelected: isSelected,
                action: onOpen
            )

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                               height: WarrenLayoutMetrics.sidebarActionButtonSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red.opacity(0.85))
                .accessibilityLabel("Delete Session \(session.title)")
                .help("Delete Session")
                .warrenSemanticElement(
                    id: "session.\(session.id.description).delete",
                    role: .button,
                    label: "Delete Session \(session.title)",
                    action: onDelete
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.leading, WarrenSpacing.standard)
        .padding(.trailing, WarrenSpacing.compact)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: false,
            pressed: false,
            selected: isSelected,
            focused: isActionFocused,
            hovered: isHovered
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .padding(.horizontal, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
    }
}

private struct WarrenDesktopSidebarSectionHeader: View {
    let title: String
    var disclosureExpanded: Bool? = nil
    let actionImage: String
    let actionLabel: String
    var actionEnabled = true
    var onToggle: (() -> Void)?
    let onAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isActionFocused: Bool
    @FocusState private var isToggleFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            Button(action: { onToggle?() }) {
                HStack(spacing: WarrenSpacing.small) {
                    Text(title.uppercased())
                        .font(WarrenTypography.sectionLabel)
                        .tracking(1.0)
                    if let disclosureExpanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(disclosureExpanded ? 90 : 0))
                            .opacity(isHovered || isToggleFocused ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: disclosureExpanded)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isToggleFocused))
            .disabled(onToggle == nil)
            .focused($isToggleFocused)

            Button(action: onAction) {
                Image(systemName: actionImage)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isActionFocused))
            .disabled(!actionEnabled)
            .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                   height: WarrenLayoutMetrics.sidebarActionButtonSize)
            .contentShape(.rect)
            .focused($isActionFocused)
            .accessibilityLabel(actionLabel)
        }
        .foregroundStyle(tokens.mutedForeground)
        .frame(height: WarrenLayoutMetrics.sidebarSectionLabelHeight)
        .padding(.leading, WarrenSpacing.standard)
        .padding(.trailing, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
    }
}
