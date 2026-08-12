import SwiftUI
import BurrowDesignSystem

/// Dashboard-only chrome. v2 workspace routes deliberately do not render this
/// 48pt bar; their 40pt TabBar owns the complete top chrome instead.
struct BurrowDesktopTopBar: View {
    let hostName: String
    let isConnected: Bool
    let isSidebarCollapsed: Bool
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        HStack(spacing: BurrowSpacing.xs) {
            // Superset's traffic-light inset is a non-interactive leaf. Keeping
            // it separate means a future AppKit window-drag bridge cannot steal
            // events from the controls next to it.
            Color.clear
                .frame(width: BurrowLayoutMetrics.expandedSidebarChromeInset)

            BurrowDesktopChromeButton(
                systemImage: isSidebarCollapsed ? "sidebar.left" : "sidebar.leading",
                label: isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar",
                hint: isSidebarCollapsed ? "Show the project and workspace list" : "Hide the project and workspace list",
                action: onToggleSidebar
            )

            Text(hostName)
                .font(BurrowTypography.sidebarRow)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: BurrowSpacing.medium)

            if hasInspector {
                BurrowDesktopInspectorButton(
                    isVisible: isInspectorVisible,
                    action: onToggleInspector
                )
            }

            Color.clear
                .frame(width: BurrowSpacing.standard)
        }
        .frame(height: BurrowLayoutMetrics.topBarHeight)
        .background(tokens.chromeSurface)
        .overlay(alignment: .bottom) {
            BurrowDesktopChromeDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top navigation bar")
    }
}
