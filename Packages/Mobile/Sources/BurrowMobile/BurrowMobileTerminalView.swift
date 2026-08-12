import SwiftUI
import BurrowDesignSystem

struct BurrowMobileTerminalView: View {
    let session: BurrowMobileSessionModel
    let onEvent: (BurrowMobileEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            BurrowMobileTerminalHeader(session: session, onDismiss: dismissTerminal, onEvent: onEvent)
            BurrowMobileTerminalPlaceholder(session: session)
            BurrowMobileInputAccessoryBar(session: session, onEvent: onEvent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }

    private func dismissTerminal() {
        onEvent(.terminalDismissed(sessionID: session.id))
        dismiss()
    }
}

struct BurrowMobileTerminalHeader: View {
    let session: BurrowMobileSessionModel
    let onDismiss: () -> Void
    let onEvent: (BurrowMobileEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BurrowSpacing.small) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to sessions")

            VStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
                Text(session.title)
                    .font(BurrowTypography.paneHeader)
                    .lineLimit(1)
                Text(session.controlLabel)
                    .font(BurrowTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: BurrowSpacing.xs)
            BurrowMobileConnectionBadge(session: session)
            BurrowMobileTerminalControlButton(session: session, onEvent: onEvent)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, BurrowSpacing.standard)
        .background(tokens.chromeSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: BurrowSpacing.hairline)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal session \(session.title)")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

private struct BurrowMobileTerminalControlButton: View {
    let session: BurrowMobileSessionModel
    let onEvent: (BurrowMobileEvent) -> Void

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
