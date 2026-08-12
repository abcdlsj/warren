import SwiftUI
import BurrowDesignSystem
import BurrowDomain
import BurrowObservation

/// A workspace row uses a compact 26pt desktop rhythm. Its marker lives in a
/// stable slot and the secondary action is a sibling control, never a nested
/// button, so selection and add-session clicks have deterministic routing.
struct BurrowDesktopWorkspaceRow: View {
    let workspace: Workspace
    let semanticScope: String
    let sessionCount: Int
    let isCollapsed: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onAddSession: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.burrowForceHover) private var forceHover
    @FocusState private var isFocused: Bool
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
            workspaceGlyph(tokens: tokens)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .clipShape(.rect(cornerRadius: BurrowRadius.row))
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .burrowSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, BurrowSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        return HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: BurrowSpacing.compact) {
                    workspaceGlyph(tokens: tokens)
                        .frame(width: BurrowLayoutMetrics.sidebarRowIconSlotSize,
                               height: BurrowLayoutMetrics.sidebarRowIconSlotSize)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.name.isEmpty ? (workspace.branch ?? "Workspace") : workspace.name)
                            .font(BurrowTypography.sidebarRow)
                            .foregroundStyle(isSelected ? tokens.foreground : tokens.foreground.opacity(0.80))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let branch = workspace.branch,
                           !branch.isEmpty,
                           branch != workspace.name {
                            Text(branch)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if sessionCount > 0 {
                        Text("\(sessionCount)")
                            .font(BurrowTypography.activityChip)
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(tokens.fillHover)
                            .clipShape(.rect(cornerRadius: BurrowRadius.small))
                            .accessibilityLabel("\(sessionCount) sessions")
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($isFocused)
            .accessibilityLabel("Workspace \(workspace.name)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .burrowSemanticElement(
                id: "workspace.\(semanticScope).\(workspace.id.description)",
                role: .button,
                label: "Workspace \(workspace.name)",
                value: isSelected ? "Selected" : "Not selected",
                isSelected: isSelected,
                action: onSelect
            )

            Button(action: onAddSession) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .background(tokens.fillHover)
            .clipShape(.rect(cornerRadius: BurrowRadius.small))
            .opacity(isHovered || forceHover ? 1 : 0)
            .allowsHitTesting(isHovered || forceHover)
            .accessibilityHidden(!(isHovered || forceHover))
            .accessibilityLabel("New session in \(workspace.name)")
            .burrowSemanticElement(
                id: "workspace.\(semanticScope).\(workspace.id.description).new-session",
                role: .button,
                label: "New session in \(workspace.name)",
                isEnabled: isHovered || forceHover,
                action: onAddSession
            )
        }
        .frame(maxWidth: .infinity, minHeight: BurrowLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.leading, BurrowSpacing.compact)
        .padding(.trailing, BurrowSpacing.compact)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .clipShape(.rect(cornerRadius: BurrowRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.horizontal, BurrowSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset renders local worktrees as a plain dot; the main workspace gets
    /// a laptop glyph. Branch rows deliberately have no branch icon.
    @ViewBuilder
    private func workspaceGlyph(tokens: BurrowColorTokens) -> some View {
        if workspace.branch == nil {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(tokens.mutedForeground.opacity(0.9))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}
