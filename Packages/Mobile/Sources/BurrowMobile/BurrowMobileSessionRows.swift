import SwiftUI
import BurrowDesignSystem

struct BurrowMobileSessionRow: View {
    let session: BurrowMobileSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BurrowSpacing.medium) {
            BurrowMobileStatusDot(tone: session.statusTone)
            VStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
                Text(session.title).font(BurrowTypography.sidebarRow)
                Text(session.controlLabel)
                    .font(BurrowTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: BurrowSpacing.small)
            Text(session.connectionLabel)
                .font(BurrowTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BurrowSpacing.standard)
        .padding(.vertical, BurrowSpacing.compact)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session \(session.title)")
        .accessibilityValue(session.accessibilityStatus)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

struct BurrowMobileStatusDot: View {
    let tone: BurrowMobileStatusTone
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        switch tone {
        case .positive: return .green
        case .caution: return .orange
        case .destructive: return tokens.destructive
        case .neutral: return tokens.mutedForeground
        }
    }
}
