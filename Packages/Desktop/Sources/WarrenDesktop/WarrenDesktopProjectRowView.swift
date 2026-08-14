import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

    /// A project row mirrors Superset's `DashboardSidebarProjectRow`: the icon and
/// disclosure affordance share a 20pt slot, while the new-workspace action is
/// disclosed only on hover or keyboard focus.
struct WarrenDesktopProjectRow: View {
    let project: Project
    let isCollapsed: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void
    let onAddWorkspace: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @FocusState private var isAddFocused: Bool

    private var showsActions: Bool { isHovered || isFocused || isAddFocused }

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
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return ZStack(alignment: .trailing) {
            Button(action: onToggleExpansion) {
                HStack(spacing: WarrenSpacing.compact) {
                    ZStack {
                        projectAvatar(tokens: tokens)
                            .opacity(isHovered ? 0 : 1)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .opacity(isHovered ? 1 : 0)
                    }
                    .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                           height: WarrenLayoutMetrics.sidebarRowIconSlotSize)

                    Text(project.name)
                        .font(WarrenTypography.navigationGroup)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .padding(.leading, WarrenSpacing.compact)
                .padding(.trailing, WarrenLayoutMetrics.sidebarActionButtonSize + WarrenSpacing.xs)
                .frame(minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
            .focused($isFocused)
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
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

            Button(action: onAddWorkspace) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isAddFocused))
            .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                   height: WarrenLayoutMetrics.sidebarActionButtonSize)
            .contentShape(.rect)
            .opacity(showsActions ? 1 : 0)
            .focused($isAddFocused)
            .accessibilityLabel("New workspace in \(project.name)")
            .warrenSemanticElement(
                id: "project.\(project.id.description).new-workspace",
                role: .button,
                label: "New workspace in \(project.name)",
                action: onAddWorkspace
            )
            .padding(.trailing, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: false,
            pressed: false,
            selected: isSelected,
            focused: isFocused,
            hovered: isHovered || isAddFocused
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset's project rows render a first-letter avatar (or the project's
    /// icon); the folder glyph is reserved for the collapsed rail in their web
    /// shell and does not appear in the desktop sidebar.
    private func projectAvatar(tokens: WarrenColorTokens) -> some View {
        Text(String(project.name.prefix(1)).uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tokens.foreground.opacity(0.92))
            .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                   height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
            .background(tokens.muted.opacity(0.55))
            .clipShape(.rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tokens.border.opacity(0.55), lineWidth: WarrenSpacing.hairline)
            }
            .accessibilityHidden(true)
    }
}
