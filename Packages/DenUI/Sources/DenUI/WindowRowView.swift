import SwiftUI
import DenCore

public struct WindowRowView: View {
    let window: RuntimeWindow
    let isActive: Bool
    let shortcutIndex: Int?
    let onSelect: () -> Void

    @State private var isHovered = false

    public init(
        window: RuntimeWindow,
        isActive: Bool,
        shortcutIndex: Int? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.window = window
        self.isActive = isActive
        self.shortcutIndex = shortcutIndex
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DenTokens.Spacing.md) {
                Image(systemName: "terminal")
                    .font(DenTokens.Font.label)
                    .foregroundStyle(isActive ? DenTokens.Color.active : DenTokens.Color.inactive)

                Text(window.title.isEmpty ? "Window \(window.tmuxWindowIndex)" : window.title)
                    .font(DenTokens.Font.windowTitle)
                    .lineLimit(1)
                    .foregroundStyle(
                        isActive ? DenTokens.Palette.text : DenTokens.Palette.subtext0
                    )

                Spacer()

                if let shortcutIndex {
                    Text("\u{2318}\(shortcutIndex)")
                        .font(DenTokens.Font.shortcut)
                        .foregroundStyle(DenTokens.Palette.overlay0)
                        .padding(.horizontal, DenTokens.Spacing.sm)
                        .padding(.vertical, DenTokens.Spacing.xxs)
                        .background(DenTokens.Palette.surface0.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: DenTokens.Radius.small))
                }

                if isActive {
                    Circle()
                        .fill(DenTokens.Color.active)
                        .frame(
                            width: DenTokens.Icon.indicator,
                            height: DenTokens.Icon.indicator
                        )
                }
            }
            .padding(.vertical, DenTokens.Spacing.xs)
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

    private var rowBackground: some ShapeStyle {
        if isActive {
            return AnyShapeStyle(DenTokens.Color.active.opacity(DenTokens.Opacity.subtle))
        } else if isHovered {
            return AnyShapeStyle(DenTokens.Palette.surface0.opacity(0.4))
        } else {
            return AnyShapeStyle(Color.clear)
        }
    }
}
