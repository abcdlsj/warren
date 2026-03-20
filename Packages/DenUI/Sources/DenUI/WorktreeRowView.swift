import SwiftUI
import DenCore

public struct WorktreeRowView: View {
    let worktree: Worktree
    let isSelected: Bool
    let onSelect: () -> Void
    var onRemove: (() -> Void)?

    @State private var isHovered = false

    public init(
        worktree: Worktree,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onRemove: (() -> Void)? = nil
    ) {
        self.worktree = worktree
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onRemove = onRemove
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: DenTokens.Spacing.md) {
                Image(systemName: worktree.isMainWorktree ? "star.fill" : "arrow.triangle.branch")
                    .font(DenTokens.Font.label)
                    .foregroundStyle(
                        worktree.isMainWorktree
                            ? DenTokens.Color.attention
                            : DenTokens.Color.muted
                    )

                VStack(alignment: .leading, spacing: DenTokens.Spacing.xxs) {
                    HStack(spacing: DenTokens.Spacing.sm) {
                        Text(worktree.branch ?? worktree.name)
                            .font(DenTokens.Font.rowTitle)
                            .foregroundStyle(
                                isSelected ? DenTokens.Palette.text : DenTokens.Palette.subtext1
                            )
                            .lineLimit(1)

                        gitStatusBadges
                    }

                    subtitleText
                }

                Spacer(minLength: 0)

                if isHovered, !worktree.isMainWorktree, let onRemove {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DenTokens.Color.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Remove Worktree")
                    .transition(.opacity)
                }
            }
            .padding(.vertical, DenTokens.Spacing.md)
            .padding(.horizontal, DenTokens.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: DenTokens.Radius.small))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Background

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(DenTokens.Color.active.opacity(DenTokens.Opacity.light))
        } else if isHovered {
            return AnyShapeStyle(DenTokens.Palette.surface0.opacity(0.6))
        } else {
            return AnyShapeStyle(Color.clear)
        }
    }

    // MARK: - Subtitle

    private var subtitleText: some View {
        HStack(spacing: DenTokens.Spacing.sm) {
            Text(worktree.name)
                .font(DenTokens.Font.caption2)
                .foregroundStyle(DenTokens.Color.muted)
                .lineLimit(1)

            if worktree.tmuxSessionId != nil {
                Circle()
                    .fill(DenTokens.Color.success)
                    .frame(width: DenTokens.Icon.dot, height: DenTokens.Icon.dot)
            }
        }
    }

    // MARK: - Git Status Badges

    @ViewBuilder
    private var gitStatusBadges: some View {
        HStack(spacing: DenTokens.Spacing.xs) {
            if worktree.aheadCount > 0 || worktree.behindCount > 0 {
                HStack(spacing: DenTokens.Spacing.xxs) {
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
                }
                .padding(.horizontal, DenTokens.Spacing.sm)
                .padding(.vertical, DenTokens.Spacing.xxs)
                .background(DenTokens.Palette.surface0.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: DenTokens.Radius.small))
            }

            if worktree.hasUncommittedChanges {
                Circle()
                    .fill(DenTokens.Color.warning)
                    .frame(width: DenTokens.Icon.dot, height: DenTokens.Icon.dot)
                    .help("Uncommitted changes")
            }

            if worktree.isDetached {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DenTokens.Icon.indicator))
                    .foregroundStyle(DenTokens.Color.attention)
                    .help("Detached HEAD")
            }
        }
    }
}
