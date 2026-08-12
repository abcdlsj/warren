import SwiftUI
import BurrowClientCore
import BurrowDesignSystem

/// Superset v2's workspace chrome is one 40pt row. Leading controls only
/// appear when the left rail is collapsed; an expanded sidebar owns its own
/// header controls, so the workspace never gets a duplicate 48pt top bar.
struct BurrowDesktopTabBar: View {
    let tabs: [ClientTab]
    let selectedTabID: String?
    let chromeMode: BurrowDesktopChromeMode
    let isSidebarCollapsed: Bool
    let isConnected: Bool
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onCommandPalette: () -> Void
    let onSelectTab: (String) -> Void
    let canAddTab: Bool
    let onAddTab: () -> Void
    let onCloseTab: (String) -> Void
    let onCloseOtherTabs: (String) -> Void
    let onCloseAllTabs: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(tokens.chromeSurface)

            HStack(spacing: 0) {
                if chromeMode == .workspace, isSidebarCollapsed {
                    BurrowDesktopCollapsedWorkspaceLeading(onToggleSidebar: onToggleSidebar)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            BurrowDesktopTabItem(
                                tab: tab,
                                isSelected: selectedTabID == tab.id,
                                onSelect: { onSelectTab(tab.id) },
                                onClose: { onCloseTab(tab.id) },
                                onCloseOthers: { onCloseOtherTabs(tab.id) },
                                onCloseAll: onCloseAllTabs
                            )
                        }

                        // The add affordance belongs to the tab track. Keeping
                        // it inside the scroll content makes it follow the last
                        // tab when tabs are inserted or removed, matching
                        // Superset's GroupStrip instead of pinning it after a
                        // greedily expanding ScrollView.
                        BurrowDesktopTabAddSlot(
                            action: onAddTab,
                            isEnabled: canAddTab
                        )
                    }
                    .frame(minHeight: BurrowLayoutMetrics.tabBarHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollIndicators(.hidden)

                // The drag filler lives outside the scroll view, exactly like
                // Superset's TabBar: tabs scroll independently and the remaining
                // empty leaf is the only window-drag target.
                BurrowDesktopWindowDragRegion()
                    .frame(minWidth: BurrowSpacing.standard, maxWidth: .infinity)
                    .accessibilityHidden(true)

                if tabs.isEmpty {
                    Text("No tabs open")
                        .font(BurrowTypography.emptyState)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, BurrowSpacing.medium)
                }

                if chromeMode == .workspace {
                    BurrowDesktopWorkspaceTabTrailing(
                        isConnected: isConnected,
                        hasInspector: hasInspector,
                        isInspectorVisible: isInspectorVisible,
                        onCommandPalette: onCommandPalette,
                        onToggleInspector: onToggleInspector
                    )
                }
            }
            .frame(height: BurrowLayoutMetrics.tabBarHeight)
        }
        .frame(height: BurrowLayoutMetrics.tabBarHeight)
        .overlay(alignment: .bottom) {
            BurrowDesktopChromeDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tab bar")
    }
}

private struct BurrowDesktopCollapsedWorkspaceLeading: View {
    let onToggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: BurrowSpacing.small) {
            Color.clear
                .frame(width: max(
                    BurrowLayoutMetrics.macTrafficLightInset
                        - BurrowLayoutMetrics.sidebarCollapsedWidth,
                    0
                ))

            BurrowDesktopChromeButton(
                systemImage: "sidebar.left",
                label: "Expand sidebar",
                hint: "Show the project and workspace list",
                action: onToggleSidebar
            )
        }
        .padding(.horizontal, BurrowSpacing.xs)
        .frame(minHeight: BurrowLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }
}

private struct BurrowDesktopWorkspaceTabTrailing: View {
    let isConnected: Bool
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onCommandPalette: () -> Void
    let onToggleInspector: () -> Void

    var body: some View {
        HStack(spacing: BurrowSpacing.xs) {
            BurrowDesktopChromeButton(
                systemImage: "magnifyingglass",
                label: "Command palette",
                hint: "Open the command palette (⌘K)",
                action: onCommandPalette
            )
            if hasInspector {
                BurrowDesktopInspectorButton(
                    isVisible: isInspectorVisible,
                    action: onToggleInspector
                )
            }
        }
        .padding(.horizontal, BurrowSpacing.xs)
        .frame(minHeight: BurrowLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace actions")
    }
}
