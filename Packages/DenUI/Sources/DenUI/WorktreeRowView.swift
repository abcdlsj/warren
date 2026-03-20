import SwiftUI
import DenCore

/// Sidebar row for one worktree, including git status badges and optional remove affordance.
public struct WorktreeRowView: View {
    let worktree: Worktree
    let isSelected: Bool
    let isPoppedOut: Bool
    let onSelect: () -> Void
    var onRemove: (() -> Void)?

    @State private var isHovered = false

    public init(
        worktree: Worktree,
        isSelected: Bool,
        isPoppedOut: Bool = false,
        onSelect: @escaping () -> Void,
        onRemove: (() -> Void)? = nil
    ) {
        self.worktree = worktree
        self.isSelected = isSelected
        self.isPoppedOut = isPoppedOut
        self.onSelect = onSelect
        self.onRemove = onRemove
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 16, height: 16, alignment: .top)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: DenTokens.Spacing.sm) {
                            Text(displayName)
                                .font(worktree.isMainWorktree ? DenTokens.Font.rowTitleBold : DenTokens.Font.rowTitle)
                                .foregroundStyle(isSelected ? DenTokens.Palette.text : DenTokens.Palette.subtext1)
                                .lineLimit(1)

                            if worktree.isMainWorktree {
                                Text("main")
                                    .font(DenTokens.Font.caption2)
                                    .foregroundStyle(DenTokens.Palette.overlay0)
                            }
                        }

                        if let subtitle = subtitleText {
                            Text(subtitle)
                                .font(DenTokens.Font.caption)
                                .foregroundStyle(DenTokens.Palette.overlay0)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    statusIndicators
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if shouldShowRemoveButton, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DenTokens.Palette.subtext0)
                        .frame(width: 18, height: 18)
                        .background(DenTokens.Color.rowHover)
                        .clipShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(.trailing, DenTokens.Spacing.sm)
                .help("Remove Worktree")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .background(rowBackground)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: DenTokens.Radius.small, style: .continuous)
                    .fill(DenTokens.Color.accent)
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var displayName: String {
        worktree.branch ?? worktree.name
    }

    private var subtitleText: String? {
        // Show the friendly worktree name only when it differs from the actual branch name.
        let branch = worktree.branch ?? worktree.name
        let name = worktree.name
        if name == branch { return nil }
        return name
    }

    private var iconColor: SwiftUI.Color {
        if isSelected { return DenTokens.Color.active }
        if worktree.isMainWorktree { return DenTokens.Color.active.opacity(0.72) }
        return DenTokens.Palette.overlay0
    }

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(DenTokens.Color.rowSelected)
        } else if isHovered {
            return AnyShapeStyle(DenTokens.Color.rowHover)
        } else {
            return AnyShapeStyle(SwiftUI.Color.clear)
        }
    }

    @ViewBuilder
    private var statusIndicators: some View {
        HStack(spacing: DenTokens.Spacing.xs + 1) {
            if isPoppedOut {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(DenTokens.Palette.overlay0)
                    .help("Popped out")
            }

            if worktree.aheadCount > 0 {
                Text("+\(worktree.aheadCount)")
                    .font(DenTokens.Font.monoSmall)
                    .foregroundStyle(DenTokens.Color.success)
            }

            if worktree.behindCount > 0 {
                Text("-\(worktree.behindCount)")
                    .font(DenTokens.Font.monoSmall)
                    .foregroundStyle(DenTokens.Color.error)
            }

            if worktree.hasUncommittedChanges {
                // Small dot keeps the row compact while still surfacing "dirty" state.
                Circle()
                    .fill(DenTokens.Color.warning)
                    .frame(width: DenTokens.Icon.dot, height: DenTokens.Icon.dot)
                    .help("Uncommitted changes")
            }

            if worktree.isDetached {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DenTokens.Color.attention)
                    .help("Detached HEAD")
            }
        }
    }

    private var shouldShowRemoveButton: Bool {
        isHovered && !worktree.isMainWorktree && onRemove != nil
    }
}
