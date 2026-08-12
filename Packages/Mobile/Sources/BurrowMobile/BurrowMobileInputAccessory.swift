import SwiftUI
import BurrowDesignSystem

struct BurrowMobileInputAccessoryBar: View {
    let session: BurrowMobileSessionModel
    let onEvent: (BurrowMobileEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: BurrowSpacing.hairline)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BurrowSpacing.xs) {
                    ForEach(BurrowMobileTerminalKey.allCases) { key in
                        BurrowMobileKeyButton(key: key, isEnabled: session.canSendInput, onPress: sendKey)
                    }
                }
                .padding(.horizontal, BurrowSpacing.standard)
                .padding(.vertical, BurrowSpacing.small)
            }
        }
        .background(tokens.chromeSurface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal input keys")
        .accessibilityValue(session.canSendInput ? "Controller input enabled" : "Observer input disabled")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }

    private func sendKey(_ key: BurrowMobileTerminalKey) {
        onEvent(.terminalInput(sessionID: session.id, key: key))
    }
}

private struct BurrowMobileKeyButton: View {
    let key: BurrowMobileTerminalKey
    let isEnabled: Bool
    let onPress: (BurrowMobileTerminalKey) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { onPress(key) } label: {
            Text(key.label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, BurrowSpacing.xs)
                .background(tokens.muted.opacity(0.5))
                .clipShape(.rect(cornerRadius: BurrowRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: BurrowRadius.small)
                        .stroke(tokens.border, lineWidth: BurrowSpacing.hairline)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityHint(isEnabled ? "Send this key to the terminal" : "Only the controller can send input")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}
