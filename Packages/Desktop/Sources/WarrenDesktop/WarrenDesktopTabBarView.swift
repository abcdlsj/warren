import SwiftUI
import WarrenClientCore
import WarrenDesignSystem

/// Superset v2's workspace chrome is one 40pt row. Leading controls only
/// appear when the left rail is collapsed; an expanded sidebar owns its own
/// header controls, so the workspace never gets a duplicate 48pt top bar.
struct WarrenDesktopTabBar: View {
    let tabs: [ClientTab]
    let tabTitles: [String: String]
    let selectedTabID: String?
    let chromeMode: WarrenDesktopChromeMode
    let isSidebarCollapsed: Bool
    let isConnected: Bool
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onWeb: () -> Void
    let onSelectEndpoint: (String) -> Void
    let onSelectTab: (String) -> Void
    let onMoveTab: (String, String?) -> Void
    let canAddTab: Bool
    let onAddTab: () -> Void
    let onCloseTab: (String) -> Void
    let onCloseOtherTabs: (String) -> Void
    let onCloseAllTabs: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hasTabOverflow = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(tokens.chromeSurface)

            HStack(spacing: 0) {
                if chromeMode == .workspace, isSidebarCollapsed {
                    WarrenDesktopCollapsedWorkspaceLeading(onToggleSidebar: onToggleSidebar)
                }

                WarrenOverflowFadeScrollView(
                    .horizontal,
                    fadeLength: WarrenLayoutMetrics.tabScrollFadeLength,
                    surface: tokens.chromeSurface,
                    showsEdgeChevrons: true,
                    onHorizontalOverflowChange: { hasTabOverflow = $0 }
                ) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            WarrenDesktopTabItem(
                                tab: tab,
                                displayTitle: tabTitles[tab.id] ?? tab.title,
                                isSelected: selectedTabID == tab.id,
                                onSelect: { onSelectTab(tab.id) },
                                onClose: { onCloseTab(tab.id) },
                                onCloseOthers: { onCloseOtherTabs(tab.id) },
                                onCloseAll: onCloseAllTabs,
                                onMoveBefore: { sourceID in onMoveTab(sourceID, tab.id) }
                            )
                        }

                        // Superset's GroupStrip pins the add affordance outside
                        // the scroller once tabs overflow, so the right edge
                        // always exposes a clickable anchor. Inside the track
                        // we keep a same-width drop target so "move to end"
                        // still works after the button leaves the scroll area.
                        if hasTabOverflow {
                            Color.clear
                                .frame(width: WarrenLayoutMetrics.tabAddButtonSlotWidth)
                                .dropDestination(for: String.self) { tabIDs, _ in
                                    guard let tabID = tabIDs.first else { return false }
                                    onMoveTab(tabID, nil)
                                    return true
                                }
                        } else {
                            WarrenDesktopTabAddSlot(
                                action: onAddTab,
                                isEnabled: canAddTab
                            )
                            .dropDestination(for: String.self) { tabIDs, _ in
                                guard let tabID = tabIDs.first else { return false }
                                onMoveTab(tabID, nil)
                                return true
                            }
                        }

                        // When tabs do not fill the bar, the leftover track is
                        // still a window-drag surface. It lives inside the
                        // scroll content so the scroll view can always occupy
                        // the full remaining width and measure overflow
                        // against the real viewport instead of the content.
                        if !hasTabOverflow {
                            WarrenDesktopWindowDragRegion()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if hasTabOverflow {
                    WarrenDesktopTabAddSlot(
                        action: onAddTab,
                        isEnabled: canAddTab
                    )
                    .dropDestination(for: String.self) { tabIDs, _ in
                        guard let tabID = tabIDs.first else { return false }
                        onMoveTab(tabID, nil)
                        return true
                    }
                }

                // The drag filler lives outside the scroll view, exactly like
                // Superset's TabBar: it stays available when the track is full
                // so there is always a small native drag leaf.
                WarrenDesktopWindowDragRegion()
                    .frame(minWidth: WarrenSpacing.standard, maxWidth: .infinity)
                    .accessibilityHidden(true)

                if chromeMode == .workspace {
                    WarrenDesktopWorkspaceTabTrailing(
                        isConnected: isConnected,
                        endpointOptions: endpointOptions,
                        selectedEndpointID: selectedEndpointID,
                        webStatus: webStatus,
                        hasInspector: hasInspector,
                        isInspectorVisible: isInspectorVisible,
                        onCommandPalette: onCommandPalette,
                        onSettings: onSettings,
                        onWeb: onWeb,
                        onSelectEndpoint: onSelectEndpoint,
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
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onWeb: () -> Void
    let onSelectEndpoint: (String) -> Void
    let onToggleInspector: () -> Void

    var body: some View {
        HStack(spacing: WarrenSpacing.xs) {
            Menu {
                ForEach(endpointOptions) { endpoint in
                    Button {
                        onSelectEndpoint(endpoint.id)
                    } label: {
                        if endpoint.id == selectedEndpointID {
                            Label(endpoint.label, systemImage: "checkmark")
                        } else {
                            Text(endpoint.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(endpointOptions.first(where: { $0.id == selectedEndpointID })?.label ?? "Server")
                        .font(WarrenTypography.navigationMeta)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Execution server")

            WarrenDesktopChromeButton(
                systemImage: "gearshape",
                label: "Settings",
                hint: "Open Warren settings",
                action: onSettings
            )
            WarrenDesktopChromeButton(
                systemImage: "globe",
                label: "Web",
                hint: webStatus.isRunning ? "Web is running" : "Web is stopped",
                action: onWeb,
                tint: webStatus.isRunning ? .green : nil
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
