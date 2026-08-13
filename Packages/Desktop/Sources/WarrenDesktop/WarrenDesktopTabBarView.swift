import SwiftUI
import WarrenClientCore
import WarrenDesignSystem

/// Superset v2's workspace chrome is one 40pt row. Leading controls only
/// appear when the left rail is collapsed; an expanded sidebar owns its own
/// header controls, so the workspace never gets a duplicate 48pt top bar.
struct WarrenDesktopTabBar: View {
    let tabs: [ClientTab]
    let selectedTabID: String?
    let chromeMode: WarrenDesktopChromeMode
    let isSidebarCollapsed: Bool
    let isConnected: Bool
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onSelectTab: (String) -> Void
    let canAddTab: Bool
    let onAddTab: () -> Void
    let onCloseTab: (String) -> Void
    let onCloseOtherTabs: (String) -> Void
    let onCloseAllTabs: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(tokens.chromeSurface)

            HStack(spacing: 0) {
                if chromeMode == .workspace, isSidebarCollapsed {
                    WarrenDesktopCollapsedWorkspaceLeading(onToggleSidebar: onToggleSidebar)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            WarrenDesktopTabItem(
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
                        WarrenDesktopTabAddSlot(
                            action: onAddTab,
                            isEnabled: canAddTab
                        )
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollIndicators(.hidden)

                // The drag filler lives outside the scroll view, exactly like
                // Superset's TabBar: tabs scroll independently and the remaining
                // empty leaf is the only window-drag target.
                WarrenDesktopWindowDragRegion()
                    .frame(minWidth: WarrenSpacing.standard, maxWidth: .infinity)
                    .accessibilityHidden(true)

                if tabs.isEmpty {
                    Text("No tabs open")
                        .font(WarrenTypography.emptyState)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, WarrenSpacing.medium)
                }

                if chromeMode == .workspace {
                    WarrenDesktopWorkspaceTabTrailing(
                        isConnected: isConnected,
                        hasInspector: hasInspector,
                        isInspectorVisible: isInspectorVisible,
                        onCommandPalette: onCommandPalette,
                        onSettings: onSettings,
                        onToggleInspector: onToggleInspector
                    )
                }
            }
            .frame(height: WarrenLayoutMetrics.tabBarHeight)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .overlay(alignment: .bottom) {
            WarrenDesktopChromeDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tab bar")
    }
}

private struct WarrenDesktopCollapsedWorkspaceLeading: View {
    let onToggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: WarrenSpacing.small) {
            Color.clear
                .frame(width: max(
                    WarrenLayoutMetrics.macTrafficLightInset
                        - WarrenLayoutMetrics.sidebarCollapsedWidth,
                    0
                ))

            WarrenDesktopChromeButton(
                systemImage: "sidebar.left",
                label: "Expand sidebar",
                hint: "Show the project and workspace list",
                action: onToggleSidebar
            )
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }
}

private struct WarrenDesktopWorkspaceTabTrailing: View {
    let isConnected: Bool
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onToggleInspector: () -> Void

    var body: some View {
        HStack(spacing: WarrenSpacing.xs) {
            WarrenDesktopChromeButton(
                systemImage: "gearshape",
                label: "Settings",
                hint: "Open Warren settings",
                action: onSettings
            )
            WarrenDesktopChromeButton(
                systemImage: "magnifyingglass",
                label: "Command palette",
                hint: "Open the command palette (⌘K)",
                action: onCommandPalette
            )
            if hasInspector {
                WarrenDesktopInspectorButton(
                    isVisible: isInspectorVisible,
                    action: onToggleInspector
                )
            }
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace actions")
    }
}
