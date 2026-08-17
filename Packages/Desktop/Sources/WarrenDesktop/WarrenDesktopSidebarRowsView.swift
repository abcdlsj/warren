import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

enum WarrenDesktopDeletionRequest {
    case workspace(Workspace, project: Project?)
    case project(Project, workspaceCount: Int)
}

struct WarrenDesktopSidebarRows: View {
    let groups: [WarrenDesktopProjectGroup]
    let workspaceActivities: [WorkspaceID: AgentActivityState]
    @Binding var tree: WarrenDesktopSidebarTreeState
    let isCollapsed: Bool
    let selection: WarrenDesktopSidebarSelection?
    let onAddProject: () -> Void
    let onAction: (WarrenDesktopAction) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void

    @State private var pendingRename: Workspace?
    @State private var workspaceName = ""
    @State private var pendingRenameProject: Project?
    @State private var projectName = ""
    @State private var dragSession = WarrenDesktopSidebarDragSession()
    /// Ephemeral presentation state; persisted expansion preferences remain untouched.
    @State private var dragAutoCollapse: WarrenSidebarDragAutoCollapse?
    @State private var dragSourceRowID: String?
    @State private var isDragMeasurementEnabled = false
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
                    projectRow(for: group)
                    if isCollapsed || isProjectExpanded(group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            workspaceRow(workspace, in: group)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: WarrenSidebarRowsDragCoordinateSpace.name)
        .overlayPreferenceValue(WarrenSidebarRowDragFramesKey.self) { frames in
            WarrenDesktopSidebarDragOverlay(
                session: dragSession,
                rows: isDragMeasurementEnabled ? frames : [:],
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
                onDragAutoCollapseChanged: setDragAutoCollapse,
                onDragSourceChanged: { id in
                    dragSourceRowID = id
                },
                onMeasurementNeededChanged: { isNeeded in
                    guard isDragMeasurementEnabled != isNeeded else { return }
                    isDragMeasurementEnabled = isNeeded
                }
            )
        }
        .onChange(of: selection) { _, newSelection in
            guard case .workspace(let workspaceID)? = newSelection,
                  let workspace = groups
                    .flatMap(\.workspaces)
                    .first(where: { $0.id == workspaceID })
            else { return }
            _ = withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.expandedProjectIDs.insert(workspace.projectID)
            }
        }
        .overlay {
            if pendingRename != nil {
                WarrenTextInputDialog(
                    title: "Rename Workspace",
                    message: "The Git branch name and worktree path are unchanged.",
                    fieldLabel: "Workspace name",
                    text: $workspaceName,
                    confirmLabel: "Rename",
                    onCancel: { pendingRename = nil },
                    onConfirm: {
                        guard let workspace = pendingRename else { return }
                        pendingRename = nil
                        onAction(.renameWorkspace(workspace.id, workspaceName))
                    }
                )
            }
        }
        .overlay {
            if pendingRenameProject != nil {
                WarrenTextInputDialog(
                    title: "Rename Project",
                    message: "Only the sidebar label changes; the repository path stays the same.",
                    fieldLabel: "Project name",
                    text: $projectName,
                    confirmLabel: "Rename",
                    onCancel: { pendingRenameProject = nil },
                    onConfirm: {
                        guard let project = pendingRenameProject else { return }
                        pendingRenameProject = nil
                        onAction(.renameProject(project.id, projectName))
                    }
                )
            }
        }
        .onChange(of: groups) { oldGroups, newGroups in
            guard let projectID = selectedProjectID else { return }
            let oldCount = workspaceCount(for: projectID, in: oldGroups)
            let newCount = workspaceCount(for: projectID, in: newGroups)
            guard newCount > oldCount else { return }
            _ = withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
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
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.expandedProjectIDs.contains(projectID) {
                tree.expandedProjectIDs.remove(projectID)
            } else {
                tree.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private func isProjectExpanded(_ projectID: ProjectID) -> Bool {
        WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedExpansions: tree.expandedProjectIDs,
            autoCollapse: dragAutoCollapse
        )
    }

    private func setDragAutoCollapse(_ autoCollapse: WarrenSidebarDragAutoCollapse?) {
        guard autoCollapse == nil || !isCollapsed else { return }
        guard dragAutoCollapse != autoCollapse else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragAutoCollapse = autoCollapse
        }
    }

    private func toggleProjects() {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.projectsCollapsed.toggle()
        }
    }

    @ViewBuilder
    private func projectRow(
        for group: WarrenDesktopProjectGroup
    ) -> some View {
        ZStack {
            WarrenDesktopProjectRow(
                project: group.project,
                workspaceCount: group.workspaces.count,
                isCollapsed: isCollapsed,
                isSelected: selection == .project(group.project.id),
                isExpanded: isProjectExpanded(group.project.id),
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
                },
                onDelete: {
                    onRequestDeletion(.project(
                        group.project,
                        workspaceCount: group.workspaces.count
                    ))
                }
            )
        }
        .background {
            if isDragMeasurementEnabled {
                GeometryReader { proxy in
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
            }
        }
        .opacity(dragSourceRowID == group.project.id.description ? 0.2 : 1)
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: dragSourceRowID
        )
    }

    @ViewBuilder
    private func workspaceRow(
        _ workspace: Workspace,
        in group: WarrenDesktopProjectGroup
    ) -> some View {
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
                },
                onDelete: {
                    onRequestDeletion(.workspace(
                        workspace,
                        project: group.project
                    ))
                }
            )
        }
        .id(workspace.id)
        .transition(.opacity)
        .background {
            if isDragMeasurementEnabled {
                GeometryReader { proxy in
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
            }
        }
        .opacity(dragSourceRowID == workspace.id.description ? 0.2 : 1)
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: dragSourceRowID
        )
    }

    private func workspaceActivity(_ workspaceID: WorkspaceID) -> AgentActivityState? {
        workspaceActivities[workspaceID]
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
                .foregroundStyle(tokens.destructive)
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
                            .animation(
                                WarrenMotion.animation(
                                    .stateChange,
                                    reduceMotion: reduceMotion
                                ),
                                value: disclosureExpanded
                            )
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

struct WarrenDesktopDeleteWorkspaceConfirmation: View {
    let workspace: Workspace
    let project: Project?
    @Binding var removeWorktree: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isWorktree: Bool {
        guard let project else { return true }
        return URL(fileURLWithPath: workspace.path)
            .standardizedFileURL.path
            != URL(fileURLWithPath: project.rootPath)
                .standardizedFileURL.path
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("Delete workspace?")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            Text("“\(workspace.name)” and every session it owns will be removed from Warren.")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if isWorktree {
                Toggle("Also delete the local worktree directory", isOn: $removeWorktree)
                    .toggleStyle(.checkbox)
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.foreground)
                    .tint(tokens.highlight)
                    .help("Leave unchecked to keep the Git worktree and branch on disk.")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(WarrenDestructiveButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 380)
        .onExitCommand(perform: onCancel)
    }
}

struct WarrenDesktopDeleteProjectConfirmation: View {
    let project: Project
    let workspaceCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("Delete project?")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            Text("“\(project.name)” and its \(workspaceCount) workspace(s) will be removed from Warren.")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            Text("Local Git worktree directories are kept on disk.")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(WarrenDestructiveButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 380)
        .onExitCommand(perform: onCancel)
    }
}
