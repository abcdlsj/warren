import SwiftUI
import WarrenDesignSystem

/// A prominent but non-modal update prompt that leaves the active terminal
/// usable while the user decides when to restart Warren.
struct WarrenUpdateBanner: View {
    let release: WarrenRelease?
    let isInstalling: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.medium) {
            if isInstalling {
                WarrenBrailleSpinner(
                    size: 20,
                    accessibilityLabel: "Installing Warren update"
                )
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tokens.highlight)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text(isInstalling ? "Installing Warren update…" : "Warren update available")
                    .font(WarrenTypography.bodyEmphasis)
                    .foregroundStyle(tokens.foreground)
                if let release {
                    Text(
                        isInstalling
                            ? "Warren will restart when the installation is complete."
                            : "\(release.displayVersion) is ready to download and install."
                    )
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                }
            }

            Spacer(minLength: WarrenSpacing.small)

            if !isInstalling {
                Button("Install Update") {
                    NotificationCenter.default.post(
                        name: WarrenUpdateNotification.installRequested,
                        object: nil
                    )
                }
                .buttonStyle(WarrenPrimaryButtonStyle())

                Button("Later") {
                    NotificationCenter.default.post(
                        name: WarrenUpdateNotification.dismiss,
                        object: nil
                    )
                }
                .buttonStyle(WarrenSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
        .frame(maxWidth: 560)
        .warrenPanelSurface(cornerRadius: WarrenRadius.base)
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.base)
                .stroke(tokens.highlight.opacity(0.75), lineWidth: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isInstalling
                ? "Installing Warren update"
                : "Warren update \(release?.displayVersion ?? "available")"
        )
    }
}
