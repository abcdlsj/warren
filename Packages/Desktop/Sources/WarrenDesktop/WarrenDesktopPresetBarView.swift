import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Pinned command launchers between the workspace tabs and pane toolbar.
///
/// Superset calls this its PresetsBar. Warren currently has three executable
/// built-ins; custom commands continue through the full session creator. Every
/// button emits a typed intent and creates a real Host-owned session.
struct WarrenDesktopPresetBar: View {
    let workspace: Workspace?
    let onChooseCommand: () -> Void
    let onLaunch: (TerminalSessionLaunchRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: WarrenSpacing.xxs) {
                Button(action: onChooseCommand) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(WarrenPresetHoverButtonStyle(tokens: tokens))
                .foregroundStyle(tokens.mutedForeground)
                .disabled(workspace == nil)
                .accessibilityLabel("Choose session command")
                .accessibilityHint("Open the full session launcher")

                Rectangle()
                    .fill(tokens.border)
                    .frame(width: WarrenSpacing.hairline, height: 16)
                    .padding(.horizontal, WarrenSpacing.xs)

                ForEach(WarrenDesktopSessionPreset.pinned) { preset in
                    Button {
                        onLaunch(preset.request)
                    } label: {
                        HStack(spacing: 6) {
                            WarrenPresetIcon(preset: preset)
                                .frame(width: 14, height: 14)

                            Text(preset.presetBarTitle)
                                .font(.system(size: 12, weight: .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WarrenPresetHoverButtonStyle(tokens: tokens))
                    .foregroundStyle(tokens.mutedForeground)
                    .disabled(workspace == nil)
                    .accessibilityLabel("Start \(preset.title)")
                    .accessibilityHint("Create a session in \(workspace?.name ?? "the selected workspace")")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(minWidth: 0, minHeight: WarrenLayoutMetrics.presetBarHeight)
        }
        .scrollIndicators(.hidden)
        .frame(height: WarrenLayoutMetrics.presetBarHeight)
        .background(tokens.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command presets")
    }

}

private struct WarrenPresetIcon: View {
    let preset: WarrenDesktopSessionPreset

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .opacity(0.9)
                .accessibilityHidden(true)
        }
    }

    private var image: NSImage? {
        guard var name = preset.presetBarIconName else { return nil }
        if name == "preset-codex", colorScheme == .dark {
            name = "preset-codex-white"
        }
        guard let url = packagedResourceURL(name: name)
            ?? Bundle.module.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func packagedResourceURL(name: String) -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("WarrenDesktop_WarrenDesktop.bundle", isDirectory: true)
            .appendingPathComponent("\(name).svg")
            .existingFileURL
    }
}

private extension URL {
    var existingFileURL: URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}

private struct WarrenPresetHoverButtonStyle: ButtonStyle {
    let tokens: WarrenColorTokens

    func makeBody(configuration: Configuration) -> StyledBody {
        StyledBody(configuration: configuration, tokens: tokens)
    }

    struct StyledBody: View {
        let configuration: Configuration
        let tokens: WarrenColorTokens
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(isHovered || configuration.isPressed ? tokens.fillHover : .clear)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .onHover { isHovered = $0 }
        }
    }
}
