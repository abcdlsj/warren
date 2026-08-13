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
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webRelayStatus: WarrenDesktopWebRelayStatus
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onWebRelay: () -> Void
    let onSelectEndpoint: (String) -> Void
    let onSelectTab: (String) -> Void
    let onMoveTab: (String, String?) -> Void
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
                                onCloseAll: onCloseAllTabs,
                                onMoveBefore: { sourceID in onMoveTab(sourceID, tab.id) }
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
                        .dropDestination(for: String.self) { tabIDs, _ in
                            guard let tabID = tabIDs.first else { return false }
                            onMoveTab(tabID, nil)
                            return true
                        }
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                // Do not let the ScrollView greedily consume the entire bar.
                // Its intrinsic track ends after the add button; the remaining
                // chrome is a real AppKit window-drag surface.
                .frame(maxWidth: tabTrackWidth, alignment: .leading)
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
                        endpointOptions: endpointOptions,
                        selectedEndpointID: selectedEndpointID,
                        webRelayStatus: webRelayStatus,
                        hasInspector: hasInspector,
                        isInspectorVisible: isInspectorVisible,
                        onCommandPalette: onCommandPalette,
                        onSettings: onSettings,
                        onWebRelay: onWebRelay,
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

    private var tabTrackWidth: CGFloat {
        CGFloat(tabs.count) * WarrenLayoutMetrics.tabWidth
            + WarrenLayoutMetrics.tabAddButtonSlotWidth
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
    let webRelayStatus: WarrenDesktopWebRelayStatus
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onWebRelay: () -> Void
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
                        .font(WarrenTypography.badge)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
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
                label: "Web Relay",
                hint: webRelayStatus.isRunning ? "Web Relay is running" : "Web Relay is stopped",
                action: onWebRelay,
                tint: webRelayStatus.isRunning ? .green : nil
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
