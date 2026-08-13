import SwiftUI
import WarrenDesignSystem

struct WarrenMobileSessionRow: View {
    let session: WarrenMobileSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WarrenSpacing.medium) {
            WarrenMobileStatusDot(tone: session.statusTone)
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text(session.title).font(WarrenTypography.sidebarRow)
                Text(session.controlLabel)
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: WarrenSpacing.small)
            Text(session.connectionLabel)
                .font(WarrenTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.compact)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session \(session.title)")
        .accessibilityValue(session.accessibilityStatus)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

struct WarrenMobileStatusDot: View {
    let tone: WarrenMobileStatusTone
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        switch tone {
        case .positive: return .green
        case .caution: return .orange
        case .destructive: return tokens.destructive
        case .neutral: return tokens.mutedForeground
        }
    }
}
