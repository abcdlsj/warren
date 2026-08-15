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
    @State private var dragSession = WarrenDesktopSidebarDragSession()
    @State private var dragFrames: [String: WarrenSidebarRowDragFrame] = [:]
    @State private var dragRestoreExpansions: Set<ProjectID> = []
    @State private var isProjectDragActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    ZStack {
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
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: WarrenSidebarRowDragFramesKey.self,
                            value: [
                                group.project.id.description: WarrenSidebarRowDragFrame(
                                    info: WarrenSidebarRowDragInfo(
                                        id: group.project.id.description,
                                        kind: .project(group.project.id),
                                        name: group.project.name,
                                        isLastOfList: group.project.id == groups.last?.project.id
                                    ),
                                    frame: proxy.frame(
                                        in: .named(WarrenSidebarRowsDragCoordinateSpace.name)
                                    )
                                ),
                            ]
                        )
                    }
                    )
                    if isCollapsed || tree.expandedProjectIDs.contains(group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            ZStack {
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
                            }
                            .id(workspace.id)
                            .transition(.opacity)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(
                                    key: WarrenSidebarRowDragFramesKey.self,
                                    value: [
                                        workspace.id.description: WarrenSidebarRowDragFrame(
                                            info: WarrenSidebarRowDragInfo(
                                                id: workspace.id.description,
                                                kind: .workspace(
                                                    workspace.id,
                                                    projectID: group.project.id
                                                ),
                                                name: workspace.name,
                                                isLastOfList: workspace.id == group.workspaces.last?.id
                                            ),
                                            frame: proxy.frame(
                                                in: .named(WarrenSidebarRowsDragCoordinateSpace.name)
                                            )
                                        ),
                                    ]
                                )
                            }
                            )
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: WarrenSidebarRowsDragCoordinateSpace.name)
        .onPreferenceChange(WarrenSidebarRowDragFramesKey.self) { frames in
            dragFrames = frames
        }
        .overlay {
            WarrenDesktopSidebarDragOverlay(
                session: dragSession,
                rows: dragFrames,
                onDropProject: { payload, beforeProjectID in
                    dropProject(payload, before: beforeProjectID)
                },
                onDropWorkspace: { payload, beforeWorkspaceID, projectID in
                    dropWorkspace(
                        payload,
                        before: beforeWorkspaceID,
                        inProject: projectID
                    )
                },
                onProjectDragBegan: beginProjectDrag,
                onProjectDragEnded: endProjectDrag
            )
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

    /// While a project is being reordered, collapse every expanded project so
    /// the whole project list is visible; restore the previous expansion set
    /// when the drag session ends.
    private func beginProjectDrag() {
        guard !isCollapsed, !isProjectDragActive else { return }
        isProjectDragActive = true
        dragRestoreExpansions = tree.expandedProjectIDs
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            tree.expandedProjectIDs = []
        }
    }

    private func endProjectDrag() {
        guard isProjectDragActive else { return }
        isProjectDragActive = false
        let restore = dragRestoreExpansions
        dragRestoreExpansions = []
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            tree.expandedProjectIDs = restore
        }
    }

    private func dropProject(
        _ payload: String,
        before projectID: ProjectID?
    ) -> Bool {
        guard payload.hasPrefix(WarrenSidebarDragPayload.projectPrefix),
              let sourceID = ProjectID(uuidString: String(
                payload.dropFirst(WarrenSidebarDragPayload.projectPrefix.count)
              ))
        else { return false }
        if projectID == sourceID {
            return false
        }
        onAction(.moveProject(sourceID, before: projectID))
        return true
    }

    private func dropWorkspace(
        _ payload: String,
        before workspaceID: WorkspaceID?,
        inProject projectID: ProjectID? = nil
    ) -> Bool {
        guard payload.hasPrefix(WarrenSidebarDragPayload.workspacePrefix),
              let sourceID = WorkspaceID(uuidString: String(
                payload.dropFirst(WarrenSidebarDragPayload.workspacePrefix.count)
              )),
              let source = groups
                .flatMap(\.workspaces)
                .first(where: { $0.id == sourceID })
        else { return false }
        if workspaceID == sourceID {
            return false
        }
        if let projectID, source.projectID != projectID {
            return false
        }
        if let workspaceID {
            guard let target = groups
                .flatMap(\.workspaces)
                .first(where: { $0.id == workspaceID }),
                  target.projectID == source.projectID
            else { return false }
        }
        onAction(.moveWorkspace(sourceID, before: workspaceID))
        return true
    }

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
