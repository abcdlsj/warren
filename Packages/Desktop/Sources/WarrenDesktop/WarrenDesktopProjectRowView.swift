import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// A project row mirrors Superset's `DashboardSidebarProjectRow`: the avatar
/// leads, the workspace count sits beside the name, and the new-workspace plus
/// remains available while the disclosure chevron overlays the avatar slot on
/// hover or keyboard focus.
struct WarrenDesktopProjectRow: View {
    let project: Project
    let workspaceCount: Int
    let isCollapsed: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isPinned: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void
    let onAddWorkspace: () -> Void
    let onImportWorktrees: () -> Void
    let onToggleAutoImportWorktrees: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @FocusState private var isAddFocused: Bool
    @FocusState private var isToggleFocused: Bool

    var body: some View {
        if isCollapsed {
            collapsedRow
        } else {
            expandedRow
        }
    }

    private var collapsedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            projectAvatar(tokens: tokens)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityLabel("Project \(project.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "project.\(project.id.description)",
            role: .button,
            label: "Project \(project.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .focused($isFocused)
        .contextMenu {
            Button(isPinned ? "Unpin Project" : "Pin Project", action: onTogglePin)
            Button("Rename Project", action: onRename)
            Button("Import Existing Worktrees…", action: onImportWorktrees)
            Button(
                project.autoImportGitWorktrees
                    ? "Disable Automatic Worktree Import"
                    : "Enable Automatic Worktree Import (No Confirmation)",
                action: onToggleAutoImportWorktrees
            )
            Divider()
            Button("Delete Project…", role: .destructive, action: onDelete)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let actionSlot = WarrenLayoutMetrics.sidebarActionButtonSize + WarrenSpacing.compact
        let compactActionSize = WarrenLayoutMetrics.sidebarActionButtonSize - WarrenSpacing.xs
        return ZStack(alignment: .trailing) {
            Button(action: onToggleExpansion) {
                HStack(spacing: WarrenSpacing.compact) {
                    projectAvatar(tokens: tokens)
                        .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                               height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
                        .opacity(isHovered || isToggleFocused ? 0 : 1)

                    Text(project.name)
                        .font(WarrenTypography.navigationItem)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("(\(workspaceCount))")
                        .font(WarrenTypography.navigationMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .opacity(isHovered || isToggleFocused || forceHover ? 1 : 0)
                        .accessibilityHidden(true)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, WarrenSpacing.compact)
                .padding(.trailing, actionSlot)
                .frame(minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
            .focused($isFocused)
            .foregroundStyle(tokens.projectText)
            .accessibilityLabel("Project \(project.name)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .warrenSemanticElement(
                id: "project.\(project.id.description)",
                role: .button,
                label: "Project \(project.name)",
                value: isExpanded ? "Expanded" : "Collapsed",
                isSelected: isSelected,
                action: onToggleExpansion
            )

            HStack(spacing: WarrenSpacing.xxs) {
                Button(action: onAddWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.86))
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isAddFocused))
                .frame(width: compactActionSize, height: compactActionSize)
                .contentShape(.rect)
                .opacity(isHovered || isAddFocused ? 1 : 0)
                .focused($isAddFocused)
                .accessibilityLabel("New workspace in \(project.name)")
                .help("New workspace")
                .warrenSemanticElement(
                    id: "project.\(project.id.description).new-workspace",
                    role: .button,
                    label: "New workspace in \(project.name)",
                    action: onAddWorkspace
                )
            }
            .padding(.trailing, WarrenSpacing.xs)
        }
        .overlay(alignment: .leading) {
            Button(action: onToggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground.opacity(0.86))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isToggleFocused))
            .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                   height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
            .contentShape(.rect)
            .opacity(isHovered || isToggleFocused ? 1 : 0)
            .focused($isToggleFocused)
            .padding(.leading, WarrenSpacing.compact)
            .accessibilityLabel(isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)")
            .warrenSemanticElement(
                id: "project.\(project.id.description).toggle",
                role: .button,
                label: isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)",
                action: onToggleExpansion
            )
        }
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: false,
            pressed: false,
            selected: isSelected,
            focused: isFocused,
            hovered: isHovered || isAddFocused || isToggleFocused
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(isPinned ? "Unpin Project" : "Pin Project", action: onTogglePin)
            Button("Rename Project", action: onRename)
            Button("Import Existing Worktrees…", action: onImportWorktrees)
            Button(
                project.autoImportGitWorktrees
                    ? "Disable Automatic Worktree Import"
                    : "Enable Automatic Worktree Import (No Confirmation)",
                action: onToggleAutoImportWorktrees
            )
            Divider()
            Button("Delete Project…", role: .destructive, action: onDelete)
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset's project rows render a first-letter avatar (or the project's
    /// icon); Warren uses the same slot for its first-letter avatar.
    private func projectAvatar(tokens: WarrenColorTokens) -> some View {
        Text(String(project.name.prefix(1)).uppercased())
            .font(WarrenTypography.compactCode)
            .foregroundStyle(tokens.foreground.opacity(0.92))
            .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                   height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
            .background(tokens.muted.opacity(0.55))
            .clipShape(.rect(cornerRadius: WarrenRadius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.xs)
                    .stroke(tokens.border.opacity(0.55), lineWidth: WarrenSpacing.hairline)
            }
            .accessibilityHidden(true)
    }
}
