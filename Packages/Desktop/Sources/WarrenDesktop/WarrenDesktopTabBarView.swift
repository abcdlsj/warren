import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

/// Superset v2's workspace chrome is one 40pt row. Leading controls only
/// appear when the left rail is collapsed; an expanded sidebar owns its own
/// header controls, so the workspace never gets a duplicate 48pt top bar.
struct WarrenDesktopTabBar: View {
    let tabs: [ClientTab]
    let tabTitles: [String: String]
    let tabActivities: [TerminalSessionID: AgentActivityState]
    let pinnedSessionIDs: Set<TerminalSessionID>
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
    let onRenameSession: (TerminalSessionID, String) -> Void
    let onToggleSessionPin: (TerminalSessionID, Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hasTabOverflow = false
    @State private var pendingRenameSessionID: TerminalSessionID?
    @State private var sessionRenameTitle = ""

    static func tabTrackWidth(tabCount: Int) -> CGFloat {
        CGFloat(tabCount) * WarrenLayoutMetrics.tabWidth
            + WarrenLayoutMetrics.tabAddButtonSlotWidth
            // The add-tab affordance carries a small leading inset, so its
            // real in-track width is the slot plus one xs step. Matching the
            // frame cap to the measured content avoids an overflow toggle at
            // the exact-fit boundary.
            + WarrenSpacing.xs
    }

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
                    showsEdgeChevrons: hasTabOverflow,
                    onHorizontalOverflowChange: { hasTabOverflow = $0 }
                ) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            WarrenDesktopTabItem(
                                tab: tab,
                                displayTitle: tabTitles[tab.id] ?? tab.title,
                                activity: tab.sessionID.flatMap { tabActivities[$0] },
                                isSelected: selectedTabID == tab.id,
                                isPinned: tab.sessionID.map(pinnedSessionIDs.contains) ?? false,
                                onSelect: { onSelectTab(tab.id) },
                                onClose: { onCloseTab(tab.id) },
                                onCloseOthers: { onCloseOtherTabs(tab.id) },
                                onCloseAll: onCloseAllTabs,
                                onMoveBefore: { sourceID in onMoveTab(sourceID, tab.id) },
                                onRename: {
                                    guard let sessionID = tab.sessionID else { return }
                                    sessionRenameTitle = tabTitles[tab.id] ?? tab.title
                                    pendingRenameSessionID = sessionID
                                },
                                onTogglePin: {
                                    guard let sessionID = tab.sessionID else { return }
                                    onToggleSessionPin(
                                        sessionID,
                                        !pinnedSessionIDs.contains(sessionID)
                                    )
                                }
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
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                .frame(
                    maxWidth: hasTabOverflow ? .infinity : Self.tabTrackWidth(tabCount: tabs.count),
                    alignment: .leading
                )
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
                WarrenDesktopWindowDragRegion(identifier: "warren.tab-bar-drag-region")
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
        .alert("Rename Session", isPresented: Binding(
            get: { pendingRenameSessionID != nil },
            set: { if !$0 { pendingRenameSessionID = nil } }
        )) {
            TextField("Session title", text: $sessionRenameTitle)
            Button("Rename") {
                guard let sessionID = pendingRenameSessionID else { return }
                pendingRenameSessionID = nil
                onRenameSession(sessionID, sessionRenameTitle)
            }
            Button("Cancel", role: .cancel) { pendingRenameSessionID = nil }
        } message: {
            Text("Custom titles are stored on the Host and shared by every client.")
        }
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
            WarrenDesktopWindowDragRegion()
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
            WarrenDesktopChromeButton(
                systemImage: "gearshape",
                label: "Settings",
                hint: "Open Warren settings",
                action: onSettings
            )
            WarrenDesktopEndpointControl(
                isConnected: isConnected,
                endpoints: endpointOptions,
                selectedID: selectedEndpointID,
                onSelect: onSelectEndpoint
            )
            WarrenDesktopChromeButton(
                systemImage: "globe",
                label: "Web",
                hint: webStatus.tunnelRunning
                    ? "Public sharing is on"
                    : (webStatus.isRunning ? "Web is running" : "Web is stopped"),
                action: onWeb,
                tint: webStatus.tunnelRunning
                    ? .blue
                    : (webStatus.isRunning ? .green : nil)
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

private struct WarrenDesktopEndpointControl: View {
    let isConnected: Bool
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var isPresented = false
    @State private var dismissTask: Task<Void, Never>?

    private var selectedEndpoint: WarrenDesktopEndpointOption? {
        endpoints.first { $0.id == selectedID }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: toggle) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 2)
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
                Circle()
                    .fill(isConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .focused($isFocused)
        .foregroundStyle(tokens.mutedForeground)
        .accessibilityLabel("Execution server: \(selectedEndpoint?.label ?? "Server")")
        .accessibilityHint(isConnected ? "Connected. Click for details." : "Disconnected. Click for details.")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent(tokens: tokens)
        }
        .onDisappear {
            dismissTask?.cancel()
        }
    }

    @ViewBuilder
    private func popoverContent(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                Circle()
                    .fill(isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(isConnected ? "Connected" : "Disconnected")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
            }
            .padding(.bottom, WarrenSpacing.compact)

            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
                .padding(.bottom, WarrenSpacing.small)

            ForEach(endpoints) { endpoint in
                Button {
                    onSelect(endpoint.id)
                    dismissTask?.cancel()
                    dismissTask = nil
                    isPresented = false
                } label: {
                    HStack(spacing: WarrenSpacing.compact) {
                        Image(systemName: endpoint.id == selectedID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                endpoint.id == selectedID
                                    ? tokens.highlight
                                    : tokens.mutedForeground
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(endpoint.label)
                                .font(WarrenTypography.navigationMeta)
                                .foregroundStyle(tokens.foreground)
                            if let detail = endpoint.detail {
                                Text(detail)
                                    .font(WarrenTypography.supporting)
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, WarrenSpacing.xs)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(WarrenSpacing.medium)
        .frame(width: 220)
    }

    private func toggle() {
        if isPresented {
            dismissTask?.cancel()
            dismissTask = nil
            isPresented = false
        } else {
            show()
        }
    }

    private func show() {
        dismissTask?.cancel()
        isPresented = true
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                isPresented = false
            }
        }
    }
}
