import SwiftUI
import BurrowDesignSystem

struct BurrowDesktopChromeButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .background(isHovered ? tokens.fillHover : .clear)
        .clipShape(.rect(cornerRadius: BurrowRadius.small))
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

struct BurrowDesktopInspectorButton: View {
    let isVisible: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14, weight: .regular))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(isVisible ? tokens.foreground : tokens.mutedForeground)
        .background(isHovered ? tokens.muted.opacity(0.50) : .clear)
        .clipShape(.rect(cornerRadius: BurrowRadius.small))
        .onHover { isHovered = $0 }
        .accessibilityLabel(isVisible ? "Hide inspector" : "Show inspector")
        .accessibilityHint("Toggle the workspace info sidebar")
    }
}

struct BurrowDesktopOfflineBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        Label("Offline", systemImage: "wifi.slash")
            .font(BurrowTypography.badge)
            .foregroundStyle(tokens.mutedForeground)
            .padding(.horizontal, BurrowSpacing.compact)
            .padding(.vertical, BurrowSpacing.xs)
            .background(tokens.muted)
            .clipShape(.rect(cornerRadius: BurrowRadius.small))
            .accessibilityLabel("Offline")
    }
}

struct BurrowDesktopChromeDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(BurrowColorTokens.resolved(for: colorScheme).border)
            .frame(height: BurrowSpacing.hairline)
    }
}
