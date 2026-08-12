import SwiftUI
import BurrowDesignSystem

struct BurrowMobileConnectionBadge: View {
    let session: BurrowMobileSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BurrowSpacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(session.connectionLabel)
                .font(BurrowTypography.badge)
                .lineLimit(1)
        }
        .padding(.horizontal, BurrowSpacing.small)
        .padding(.vertical, BurrowSpacing.xs)
        .background(tokens.muted.opacity(0.45))
        .clipShape(.rect(cornerRadius: BurrowRadius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection status")
        .accessibilityValue(session.accessibilityStatus)
    }

    private var statusColor: Color {
        switch session.statusTone {
        case .positive: return .green
        case .caution: return .orange
        case .destructive: return tokens.destructive
        case .neutral: return tokens.mutedForeground
        }
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

struct BurrowMobileTerminalPlaceholder: View {
    let session: BurrowMobileSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: BurrowSpacing.medium) {
                Text(session.outputPreview.joined(separator: "\n"))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
                    Text("Terminal placeholder").font(BurrowTypography.emptyState)
                    Text("A PTY renderer will be attached here in a later slice.")
                        .font(BurrowTypography.badge)
                        .foregroundStyle(tokens.mutedForeground)
                }
                .padding(.top, BurrowSpacing.large)
            }
            .frame(minWidth: 0, alignment: .leading)
            .padding(BurrowSpacing.standard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal preview")
        .accessibilityValue("No live PTY connected")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}
