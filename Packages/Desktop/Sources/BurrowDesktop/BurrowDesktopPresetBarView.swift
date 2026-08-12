import SwiftUI
import BurrowDesignSystem
import BurrowDomain

/// Pinned command launchers between the workspace tabs and pane toolbar.
///
/// Superset calls this its PresetsBar. Burrow currently has three executable
/// built-ins; custom commands continue through the full session creator. Every
/// button emits a typed intent and creates a real Host-owned session.
struct BurrowDesktopPresetBar: View {
    let workspace: Workspace?
    let onChooseCommand: () -> Void
    let onLaunch: (TerminalSessionLaunchRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BurrowSpacing.xxs) {
                Button(action: onChooseCommand) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(BurrowPresetHoverButtonStyle(tokens: tokens))
                .foregroundStyle(tokens.mutedForeground)
                .disabled(workspace == nil)
                .accessibilityLabel("Choose session command")
                .accessibilityHint("Open the full session launcher")

                Rectangle()
                    .fill(tokens.border)
                    .frame(width: BurrowSpacing.hairline, height: 16)
                    .padding(.horizontal, BurrowSpacing.xs)

                ForEach(BurrowDesktopSessionPreset.pinned) { preset in
                    Button {
                        onLaunch(preset.request)
                    } label: {
                        Text(preset.title)
                            .font(BurrowTypography.tabTitle)
                            .lineLimit(1)
                        .padding(.horizontal, BurrowSpacing.compact)
                        .frame(height: 24)
                        .contentShape(.rect)
                    }
                    .buttonStyle(BurrowPresetHoverButtonStyle(tokens: tokens))
                    .foregroundStyle(tokens.mutedForeground)
                    .disabled(workspace == nil)
                    .accessibilityLabel("Start \(preset.title)")
                    .accessibilityHint("Create a session in \(workspace?.name ?? "the selected workspace")")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, BurrowSpacing.compact)
            .frame(minWidth: 0, minHeight: BurrowLayoutMetrics.presetBarHeight)
        }
        .scrollIndicators(.hidden)
        .frame(height: BurrowLayoutMetrics.presetBarHeight)
        .background(tokens.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: BurrowSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command presets")
    }

}

private struct BurrowPresetHoverButtonStyle: ButtonStyle {
    let tokens: BurrowColorTokens

    func makeBody(configuration: Configuration) -> StyledBody {
        StyledBody(configuration: configuration, tokens: tokens)
    }

    struct StyledBody: View {
        let configuration: Configuration
        let tokens: BurrowColorTokens
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(isHovered || configuration.isPressed ? tokens.fillHover : .clear)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .clipShape(.rect(cornerRadius: BurrowRadius.small))
                .onHover { isHovered = $0 }
        }
    }
}
