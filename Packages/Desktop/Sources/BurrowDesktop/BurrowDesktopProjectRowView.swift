import SwiftUI
import BurrowDesignSystem
import BurrowDomain

    /// A project row mirrors Superset's `DashboardSidebarProjectRow`: the icon and
/// disclosure affordance share a 20pt slot, while the new-workspace action is
/// disclosed only on hover or keyboard focus.
struct BurrowDesktopProjectRow: View {
    let project: Project
    let isCollapsed: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        if isCollapsed {
            collapsedRow
        } else {
            expandedRow
        }
    }

    private var collapsedRow: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            projectAvatar(tokens: tokens)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .clipShape(.rect(cornerRadius: BurrowRadius.row))
        .accessibilityLabel("Project \(project.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, BurrowSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        return HStack(spacing: BurrowSpacing.xs) {
            Button(action: {
                onToggleExpansion()
                onSelect()
            }) {
                HStack(spacing: BurrowSpacing.compact) {
                    ZStack {
                        projectAvatar(tokens: tokens)
                            .opacity(isHovered ? 0 : 1)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .opacity(isHovered ? 1 : 0)
                    }
                    .frame(width: BurrowLayoutMetrics.sidebarRowIconSlotSize,
                           height: BurrowLayoutMetrics.sidebarRowIconSlotSize)

                    Text(project.name)
                        .font(BurrowTypography.sidebarRow)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
            .accessibilityLabel("Project \(project.name)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .frame(maxWidth: .infinity, minHeight: BurrowLayoutMetrics.sidebarProjectRowHeight)
        .padding(.leading, BurrowSpacing.compact)
        .padding(.trailing, BurrowSpacing.xs)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .clipShape(.rect(cornerRadius: BurrowRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.horizontal, BurrowSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset's project rows render a first-letter avatar (or the project's
    /// icon); the folder glyph is reserved for the collapsed rail in their web
    /// shell and does not appear in the desktop sidebar.
    private func projectAvatar(tokens: BurrowColorTokens) -> some View {
        Text(String(project.name.prefix(1)).uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tokens.foreground.opacity(0.92))
            .frame(width: BurrowLayoutMetrics.sidebarRowIconSlotSize,
                   height: BurrowLayoutMetrics.sidebarRowIconSlotSize)
            .background(tokens.muted.opacity(0.55))
            .clipShape(.rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tokens.border.opacity(0.55), lineWidth: BurrowSpacing.hairline)
            }
            .accessibilityHidden(true)
    }
}
