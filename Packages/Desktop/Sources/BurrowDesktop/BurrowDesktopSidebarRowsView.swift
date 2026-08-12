import SwiftUI
import BurrowDesignSystem
import BurrowDomain

struct BurrowDesktopSidebarRows: View {
    let groups: [BurrowDesktopProjectGroup]
    let sessions: [BurrowDesktopSession]
    let isCollapsed: Bool
    let selection: BurrowDesktopSidebarSelection?
    let onAddProject: () -> Void
    let onAction: (BurrowDesktopAction) -> Void

    @State private var collapsedProjectIDs: Set<ProjectID> = []
    @State private var projectsCollapsed = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
            if !isCollapsed {
                BurrowDesktopSidebarSectionHeader(
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
                ForEach(sessionWorkspaces) { workspace in
                    BurrowDesktopWorkspaceRow(
                        workspace: workspace,
                        semanticScope: "session-list",
                        sessionCount: sessions.filter { $0.workspaceID == workspace.id }.count,
                        isCollapsed: false,
                        isSelected: selection == .workspace(workspace.id),
                        onSelect: { select(.workspace(workspace.id)) },
                        onAddSession: {
                            onAction(.requestNewSession(workspace.id))
                        }
                    )
                    .id("sessions-\(workspace.id)")
                    .transition(.opacity)
                }
            }

            if !isCollapsed {
                BurrowDesktopSidebarSectionHeader(
                    title: "Projects",
                    disclosureExpanded: !projectsCollapsed,
                    actionImage: "folder.badge.plus",
                    actionLabel: "Add project",
                    onToggle: toggleProjects,
                    onAction: onAddProject
                )
            }
            if groups.isEmpty && !isCollapsed {
                VStack(spacing: BurrowSpacing.xs) {
                    Text("No workspaces yet")
                        .font(BurrowTypography.emptyState)
                    Text("Add a project or drop a Git repository folder")
                        .font(BurrowTypography.badge)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, BurrowSpacing.medium)
                .padding(.vertical, BurrowSpacing.large)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No workspaces yet. Add a project or drop a Git repository folder.")
            }
            if isCollapsed || !projectsCollapsed {
                ForEach(groups) { group in
                    BurrowDesktopProjectRow(
                        project: group.project,
                        isCollapsed: isCollapsed,
                        isSelected: selection == .project(group.project.id),
                        isExpanded: !collapsedProjectIDs.contains(group.project.id),
                        onSelect: { select(.project(group.project.id)) },
                        onToggleExpansion: { toggleProject(group.project.id) },
                        onAddWorkspace: {
                            onAction(.requestNewWorkspace(group.project.id))
                        }
                    )
                    if isCollapsed || !collapsedProjectIDs.contains(group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            let workspaceSessions = sessions.filter {
                                $0.workspaceID == workspace.id
                            }
                            BurrowDesktopWorkspaceRow(
                                workspace: workspace,
                                semanticScope: "project-list",
                                sessionCount: workspaceSessions.count,
                                isCollapsed: isCollapsed,
                                isSelected: selection == .workspace(workspace.id),
                                onSelect: { select(.workspace(workspace.id)) },
                                onAddSession: {
                                    onAction(.requestNewSession(workspace.id))
                                }
                            )
                            .id(workspace.id)
                            .transition(.opacity)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func select(_ newSelection: BurrowDesktopSidebarSelection) {
        switch newSelection {
        case .project(let projectID):
            onAction(.selectProject(projectID))
        case .workspace(let workspaceID):
            onAction(.selectWorkspace(workspaceID))
        }
    }

    private func toggleProject(_ projectID: ProjectID) {
        withAnimation(.easeOut(duration: 0.15)) {
            if collapsedProjectIDs.contains(projectID) {
                collapsedProjectIDs.remove(projectID)
            } else {
                collapsedProjectIDs.insert(projectID)
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

    private var sessionWorkspaces: [Workspace] {
        let ids = Set(sessions.map(\.workspaceID))
        return groups.flatMap(\.workspaces).filter { ids.contains($0.id) }
    }
}

private struct BurrowDesktopSidebarSectionHeader: View {
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
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        HStack(spacing: BurrowSpacing.small) {
            Button(action: { onToggle?() }) {
                HStack(spacing: BurrowSpacing.small) {
                    Text(title.uppercased())
                        .font(BurrowTypography.sectionLabel)
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
            .frame(width: BurrowLayoutMetrics.sidebarActionButtonSize,
                   height: BurrowLayoutMetrics.sidebarActionButtonSize)
            .contentShape(.rect)
            .background(tokens.fillHover.opacity(isHovered ? 1 : 0))
            .clipShape(.rect(cornerRadius: BurrowRadius.small))
            .accessibilityLabel(actionLabel)
        }
        .foregroundStyle(tokens.mutedForeground)
        .frame(height: BurrowLayoutMetrics.sidebarSectionLabelHeight)
        .padding(.leading, BurrowSpacing.standard)
        .padding(.trailing, BurrowSpacing.compact)
        .onHover { isHovered = $0 }
    }
}
