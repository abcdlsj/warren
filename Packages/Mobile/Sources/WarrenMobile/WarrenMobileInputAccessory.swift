import SwiftUI
import WarrenDesignSystem

struct WarrenMobileInputAccessoryBar: View {
    let session: WarrenMobileSessionModel
    let onEvent: (WarrenMobileEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WarrenSpacing.xs) {
                    ForEach(WarrenMobileTerminalKey.allCases) { key in
                        WarrenMobileKeyButton(key: key, isEnabled: session.canSendInput, onPress: sendKey)
                    }
                }
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.vertical, WarrenSpacing.small)
            }
        }
        .background(tokens.chromeSurface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal input keys")
        .accessibilityValue(session.canSendInput ? "Controller input enabled" : "Observer input disabled")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }

    private func sendKey(_ key: WarrenMobileTerminalKey) {
        onEvent(.terminalInput(sessionID: session.id, key: key))
    }
}

private struct WarrenMobileKeyButton: View {
    let key: WarrenMobileTerminalKey
    let isEnabled: Bool
    let onPress: (WarrenMobileTerminalKey) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { onPress(key) } label: {
            Text(key.label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, WarrenSpacing.xs)
                .background(tokens.muted.opacity(0.5))
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityHint(isEnabled ? "Send this key to the terminal" : "Only the controller can send input")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}
