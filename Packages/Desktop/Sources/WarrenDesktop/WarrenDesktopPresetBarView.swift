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
    let onLaunch: (TerminalSessionLaunchRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
            surface: tokens.background
        ) {
            HStack(spacing: WarrenSpacing.small) {
                ForEach(WarrenDesktopSessionPreset.pinned) { preset in
                    Button {
                        onLaunch(preset.request)
                    } label: {
                        HStack(spacing: 6) {
                            WarrenPresetIcon(preset: preset)
                                .frame(width: 14, height: 14)

                            Text(preset.presetBarTitle)
                                .font(.system(size: 13, weight: .light))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WarrenPresetButtonStyle())
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
        return WarrenPresetIconCache.shared.image(named: name)
    }
}

@MainActor
final class WarrenPresetIconCache {
    typealias Loader = @MainActor (String) -> NSImage?

    static let shared = WarrenPresetIconCache { name in
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("WarrenDesktop_WarrenDesktop.bundle", isDirectory: true)
            .appendingPathComponent("\(name).svg")
        let url = packaged.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? Bundle.module.url(forResource: name, withExtension: "svg")
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private let loader: Loader
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard !missing.contains(name) else { return nil }
        guard let image = loader(name) else {
            missing.insert(name)
            return nil
        }
        images[name] = image
        return image
    }
}
