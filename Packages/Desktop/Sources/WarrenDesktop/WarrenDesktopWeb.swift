import SwiftUI
import Foundation
import WarrenDesignSystem

public struct WarrenDesktopWebStatus: Hashable, Sendable {
    public var isRunning: Bool
    public var localURL: URL?
    public var secureURL: URL?
    public var canControl: Bool

    public init(isRunning: Bool = false, localURL: URL? = nil, secureURL: URL? = nil, canControl: Bool = true) {
        self.isRunning = isRunning
        self.localURL = localURL
        self.secureURL = secureURL
        self.canControl = canControl
    }
}

public struct WarrenDesktopWebPanel: View {
    public let status: WarrenDesktopWebStatus
    public let canShare: Bool
    public let onStart: () -> Void
    public let onStop: () -> Void
    public let onOpenURL: (URL) -> Void
    public let onCopyURL: (URL) -> Void

    public init(
        status: WarrenDesktopWebStatus,
        canShare: Bool = true,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onCopyURL: @escaping (URL) -> Void
    ) {
        self.status = status
        self.canShare = canShare
        self.onStart = onStart
        self.onStop = onStop
        self.onOpenURL = onOpenURL
        self.onCopyURL = onCopyURL
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: .dark)
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            HStack {
                Label("Web", systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(status.isRunning ? Color.green : tokens.mutedForeground)
                    .frame(width: 7, height: 7)
                Text(status.isRunning ? "Running" : "Stopped")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
            }
            WarrenDesktopChromeDivider()
            if let url = status.localURL {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                HStack(spacing: WarrenSpacing.compact) {
                    WarrenDesktopWebActionButton(title: "Open") {
                        onOpenURL(url)
                    }
                    WarrenDesktopWebActionButton(title: "Copy") {
                        onCopyURL(url)
                    }
                }
                if canShare && status.canControl {
                    WarrenDesktopChromeDivider()
                    if let secureURL = status.secureURL {
                        Text(secureURL.absoluteString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                        HStack(spacing: WarrenSpacing.compact) {
                            WarrenDesktopWebActionButton(title: "Open") {
                                onOpenURL(secureURL)
                            }
                            WarrenDesktopWebActionButton(title: "Copy") {
                                onCopyURL(secureURL)
                            }
                            WarrenDesktopWebActionButton(title: "Stop Sharing") {
                                onStop()
                            }
                        }
                    } else {
                        WarrenDesktopWebActionButton(title: "Share") {
                            onStart()
                        }
                    }
                }
            } else {
                Text("Local Web is unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .padding(WarrenSpacing.medium)
        .frame(width: 300, alignment: .leading)
        .background(tokens.chromeSurface)
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.medium)
                .stroke(tokens.border.opacity(0.55), lineWidth: WarrenSpacing.hairline)
        )
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
    }
}

/// Plain-text action used by the Web panel so Stop, Open, and Copy share one
/// consistent hit target and visual language without button borders.
private struct WarrenDesktopWebActionButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? tokens.foreground : tokens.mutedForeground)
                .frame(
                    maxWidth: .infinity,
                    minHeight: WarrenLayoutMetrics.compactControlHeight
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}
