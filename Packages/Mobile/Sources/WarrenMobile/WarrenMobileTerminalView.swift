import SwiftUI
import WarrenDesignSystem

struct WarrenMobileTerminalView: View {
    let session: WarrenMobileSessionModel
    let onEvent: (WarrenMobileEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            WarrenMobileTerminalHeader(session: session, onDismiss: dismissTerminal, onEvent: onEvent)
            WarrenMobileTerminalPlaceholder(session: session)
            WarrenMobileInputAccessoryBar(session: session, onEvent: onEvent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }

    private func dismissTerminal() {
        onEvent(.terminalDismissed(sessionID: session.id))
        dismiss()
    }
}

struct WarrenMobileTerminalHeader: View {
    let session: WarrenMobileSessionModel
    let onDismiss: () -> Void
    let onEvent: (WarrenMobileEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WarrenSpacing.small) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to sessions")

            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text(session.title)
                    .font(WarrenTypography.paneHeader)
                    .lineLimit(1)
                Text(session.controlLabel)
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: WarrenSpacing.xs)
            WarrenMobileConnectionBadge(session: session)
            WarrenMobileTerminalControlButton(session: session, onEvent: onEvent)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, WarrenSpacing.standard)
        .background(tokens.chromeSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal session \(session.title)")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

private struct WarrenMobileTerminalControlButton: View {
    let session: WarrenMobileSessionModel
    let onEvent: (WarrenMobileEvent) -> Void

    var body: some View {
        Group {
            if session.canReconnect {
                Button("Reconnect") { onEvent(.reconnect(sessionID: session.id)) }
                    .accessibilityHint("Reconnect this terminal session")
            } else if session.canRequestControl {
                Button("Control") { onEvent(.requestControl(sessionID: session.id)) }
                    .accessibilityHint("Request input control for this session")
            } else if session.canSendInput {
                Button("Release") { onEvent(.releaseControl(sessionID: session.id)) }
                    .accessibilityHint("Release input control for other clients")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
