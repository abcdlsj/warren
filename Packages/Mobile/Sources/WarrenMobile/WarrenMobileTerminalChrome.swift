import SwiftUI
import WarrenDesignSystem

struct WarrenMobileConnectionBadge: View {
    let session: WarrenMobileSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WarrenSpacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(session.connectionLabel)
                .font(WarrenTypography.badge)
                .lineLimit(1)
        }
        .padding(.horizontal, WarrenSpacing.small)
        .padding(.vertical, WarrenSpacing.xs)
        .background(tokens.muted.opacity(0.45))
        .clipShape(.rect(cornerRadius: WarrenRadius.small))
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

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

struct WarrenMobileTerminalPlaceholder: View {
    let session: WarrenMobileSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
                Text(session.outputPreview.joined(separator: "\n"))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text("Terminal placeholder").font(WarrenTypography.emptyState)
                    Text("A PTY renderer will be attached here in a later slice.")
                        .font(WarrenTypography.badge)
                        .foregroundStyle(tokens.mutedForeground)
                }
                .padding(.top, WarrenSpacing.large)
            }
            .frame(minWidth: 0, alignment: .leading)
            .padding(WarrenSpacing.standard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal preview")
        .accessibilityValue("No live PTY connected")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}
