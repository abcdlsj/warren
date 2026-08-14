import SwiftUI
import Foundation
import WarrenDesignSystem

public struct WarrenDesktopWebRelayStatus: Hashable, Sendable {
    public var isRunning: Bool
    public var localURL: URL?
    public var secureURL: URL?

    public init(isRunning: Bool = false, localURL: URL? = nil, secureURL: URL? = nil) {
        self.isRunning = isRunning
        self.localURL = localURL
        self.secureURL = secureURL
    }
}

public struct WarrenDesktopWebRelayPanel: View {
    public let status: WarrenDesktopWebRelayStatus
    public let onStart: () -> Void
    public let onStop: () -> Void
    public let onOpenURL: (URL) -> Void
    public let onCopyURL: (URL) -> Void

    public init(
        status: WarrenDesktopWebRelayStatus,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onCopyURL: @escaping (URL) -> Void
    ) {
        self.status = status
        self.onStart = onStart
        self.onStop = onStop
        self.onOpenURL = onOpenURL
        self.onCopyURL = onCopyURL
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: .dark)
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            HStack {
                Label("Web Relay", systemImage: "globe")
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
                HStack(spacing: WarrenSpacing.xs) {
                    Button(status.isRunning ? "Stop" : "Start") {
                        status.isRunning ? onStop() : onStart()
                    }
                    .buttonStyle(WarrenPrimaryButtonStyle())
                    .controlSize(.small)
                    Button("Open") { onOpenURL(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Copy") { onCopyURL(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Text("Local Web Relay is unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                Button("Start Web Relay", action: onStart)
                    .buttonStyle(WarrenPrimaryButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(WarrenSpacing.medium)
        .frame(width: 300, alignment: .leading)
        .background(tokens.chromeSurface)
        .overlay(RoundedRectangle(cornerRadius: WarrenRadius.medium).stroke(tokens.border))
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        .shadow(radius: 12, y: 4)
    }
}
