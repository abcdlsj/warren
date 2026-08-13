import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopSidebarRows: View {
    let groups: [WarrenDesktopProjectGroup]
    let sessions: [WarrenDesktopSession]
    let isCollapsed: Bool
    let selection: WarrenDesktopSidebarSelection?
    let selectedTabID: String?
    let onAddProject: () -> Void
    let onAction: (WarrenDesktopAction) -> Void

    /// Project trees start closed. An allow-list makes newly imported projects
    /// closed by construction instead of requiring fragile state migration.
    @State private var expandedProjectIDs: Set<ProjectID> = []
    @State private var projectsCollapsed = false
    @State private var pendingDeletion: WarrenDesktopSession?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            if !isCollapsed {
                WarrenDesktopSidebarSectionHeader(
                    title: "Sessions",
                    actionImage: "plus",
                    actionLabel: "New session",
                    actionEnabled: firstWorkspace != nil,
                    onAction: {
                        if let workspace = firstWorkspace {
                            onAction(.requestNewSession(workspace.id))
                        }
                    }
                )
            }
            if !isCollapsed {
                ForEach(sessions) { session in
                    WarrenDesktopSessionRow(
                        session: session,
                        workspace: workspace(for: session),
                        isSelected: session.tabID == selectedTabID,
                        onOpen: { onAction(.openSession(session.id)) },
                        onDelete: { pendingDeletion = session }
                    )
                    .id("session-\(session.id)")
                    .transition(.opacity)
                }
            }

            if !isCollapsed {
                WarrenDesktopSidebarSectionHeader(
                    title: "Projects",
                    disclosureExpanded: !projectsCollapsed,
                    actionImage: "folder.badge.plus",
                    actionLabel: "Add project",
                    onToggle: toggleProjects,
                    onAction: onAddProject
                )
            }
            if groups.isEmpty && !isCollapsed {
                VStack(spacing: WarrenSpacing.xs) {
                    Text("No workspaces yet")
                        .font(WarrenTypography.emptyState)
                    Text("Add a project or drop a Git repository folder")
                        .font(WarrenTypography.badge)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.vertical, WarrenSpacing.large)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No workspaces yet. Add a project or drop a Git repository folder.")
            }
            if isCollapsed || !projectsCollapsed {
                ForEach(groups) { group in
                    WarrenDesktopProjectRow(
                        project: group.project,
                        isCollapsed: isCollapsed,
                        isSelected: selection == .project(group.project.id),
                        isExpanded: expandedProjectIDs.contains(group.project.id),
                        onSelect: { select(.project(group.project.id)) },
                        onToggleExpansion: { toggleProject(group.project.id) },
                        onAddWorkspace: {
                            onAction(.requestNewWorkspace(group.project.id))
                        }
                    )
                    if isCollapsed || expandedProjectIDs.contains(group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            WarrenDesktopWorkspaceRow(
                                workspace: workspace,
                                semanticScope: "project-list",
                                activity: workspaceActivity(workspace.id),
                                isCollapsed: isCollapsed,
                                isSelected: selection == .workspace(workspace.id),
                                onSelect: { select(.workspace(workspace.id)) }
                            )
                            .id(workspace.id)
                            .transition(.opacity)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.title ?? "Session")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                guard let session = pendingDeletion else { return }
                pendingDeletion = nil
                onAction(.deleteSession(session.id))
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This closes every Tab for this Session, terminates its process if running, and removes its saved history.")
        }
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
        withAnimation(.easeOut(duration: 0.15)) {
            if expandedProjectIDs.contains(projectID) {
                expandedProjectIDs.remove(projectID)
            } else {
                expandedProjectIDs.insert(projectID)
            }
        }
    }

    private func toggleProjects() {
        withAnimation(.easeOut(duration: 0.15)) {
            projectsCollapsed.toggle()
        }
    }

    private var firstWorkspace: Workspace? {
        groups.lazy.compactMap(\.workspaces.first).first
    }

    private func workspace(for session: WarrenDesktopSession) -> Workspace? {
        groups.lazy.flatMap(\.workspaces).first { $0.id == session.workspaceID }
    }

    private func workspaceActivity(_ workspaceID: WorkspaceID) -> TerminalSessionActivityState? {
        sessions.lazy
            .filter { $0.workspaceID == workspaceID }
            .map(\.activity)
            .max { activityPriority($0) < activityPriority($1) }
    }

    private func activityPriority(_ activity: TerminalSessionActivityState) -> Int {
        switch activity {
        case .failed: 5
        case .waitingForInput: 4
        case .connecting: 3
        case .working: 2
        case .ready: 1
        case .exited: 0
        }
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

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.compact) {
            Button(action: onOpen) {
                HStack(spacing: WarrenSpacing.compact) {
                    WarrenDesktopActivityIndicator(activity: session.activity)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(WarrenTypography.workspaceRow)
                            .foregroundStyle(tokens.foreground.opacity(0.86))
                            .lineLimit(1)
                        if let workspace {
                            Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name)
                                .font(WarrenTypography.badge)
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
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
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
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
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            Button(action: { onToggle?() }) {
                HStack(spacing: WarrenSpacing.small) {
                    Text(title.uppercased())
                        .font(WarrenTypography.sectionLabel)
                        .tracking(0.75)
                    if let disclosureExpanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(disclosureExpanded ? 90 : 0))
                            .opacity(disclosureExpanded && !isHovered ? 0 : 1)
                            .animation(.easeOut(duration: 0.15), value: disclosureExpanded)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(onToggle == nil)

            Button(action: onAction) {
                Image(systemName: actionImage)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!actionEnabled)
            .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                   height: WarrenLayoutMetrics.sidebarActionButtonSize)
            .contentShape(.rect)
            .background(tokens.fillHover.opacity(isHovered ? 1 : 0))
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .accessibilityLabel(actionLabel)
        }
        .foregroundStyle(tokens.mutedForeground)
        .frame(height: WarrenLayoutMetrics.sidebarSectionLabelHeight)
        .padding(.leading, WarrenSpacing.standard)
        .padding(.trailing, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
    }
}
