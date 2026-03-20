import SwiftUI
import DenCore

/// Sidebar row for one runtime tmux window.
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
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? DenTokens.Color.active : DenTokens.Palette.overlay0)
                    .frame(width: 14, alignment: .center)

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
                        .foregroundStyle(isActive ? DenTokens.Palette.overlay1 : DenTokens.Palette.overlay0)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: DenTokens.Radius.small, style: .continuous)
                    .fill(DenTokens.Color.accent)
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: some ShapeStyle {
        if isActive {
            return AnyShapeStyle(DenTokens.Color.rowSelected)
        } else if isHovered {
            return AnyShapeStyle(DenTokens.Color.rowHover)
        } else {
            return AnyShapeStyle(SwiftUI.Color.clear)
        }
    }
}
