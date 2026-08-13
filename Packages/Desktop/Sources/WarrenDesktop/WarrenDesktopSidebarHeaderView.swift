import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopSidebarHeader: View {
    let isCollapsed: Bool
    let chromeMode: WarrenDesktopChromeMode
    let onToggle: () -> Void
    let onCommandPalette: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if chromeMode == .workspace {
                workspaceHeader
            } else if isCollapsed {
                collapsedDashboardHeader
            } else {
                expandedDashboardHeader
            }
        }
        .background(
            chromeMode == .workspace
                ? WarrenColorTokens.resolved(for: colorScheme).sidebarSurface
                : .clear
        )
    }

    /// Superset's expanded dashboard header has a 32pt traffic-light row with
    /// an 80pt leading inset, followed by its compact navigation actions. Warren
    /// keeps the same geometry and exposes the one supported action: opening a
    /// new terminal session in the selected workspace.
    private var workspaceHeader: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                WarrenDesktopWindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: WarrenLayoutMetrics.tabBarHeight)
                    .background(WarrenColorTokens.resolved(for: colorScheme).chromeSurface)

                compactSearchButton
                    .padding(.top, WarrenSpacing.medium)
            } else {
                trafficRow
                    .padding(.top, WarrenLayoutMetrics.sidebarHeaderTopPadding)
                    .padding(.bottom, WarrenLayoutMetrics.sidebarHeaderBottomGap)

                expandedSearchButton
            }
        }
    }

    private var trafficRow: some View {
        HStack(spacing: WarrenSpacing.small) {
            // Superset owns an 80pt traffic-light pad; Warren renders the
            // lights itself because the window is borderless.
            WarrenDesktopTrafficLights()
                .frame(width: WarrenLayoutMetrics.macTrafficLightInset, alignment: .leading)

            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
            .accessibilityLabel("Collapse sidebar")
            .accessibilityHint("Collapse the project and session list")

            WarrenDesktopWindowDragRegion()
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .frame(height: WarrenLayoutMetrics.sidebarTrafficRowHeight)
    }

    private var expandedSearchButton: some View {
        Button(action: onCommandPalette) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text("Search")
                    .font(WarrenTypography.sidebarRow)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("⌘K")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(WarrenColorTokens.resolved(for: colorScheme).fillHover)
                    .clipShape(.rect(cornerRadius: 4))
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(height: WarrenLayoutMetrics.sidebarProjectRowHeight)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
        .background(WarrenColorTokens.resolved(for: colorScheme).fillHover.opacity(0.001))
        .clipShape(.rect(cornerRadius: WarrenRadius.small))
        .padding(.horizontal, WarrenSpacing.xs)
        .accessibilityLabel("Search")
    }

    private var compactSearchButton: some View {
        Button(action: onCommandPalette) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
        .accessibilityLabel("Search")
    }

    private var collapsedDashboardHeader: some View {
        Button(action: onToggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: WarrenLayoutMetrics.sidebarHeaderRowHeight)
        .contentShape(.rect)
        .accessibilityLabel("Expand sidebar")
        .accessibilityHint("Show the project and workspace list")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedDashboardHeader: some View {
        HStack(spacing: WarrenSpacing.compact) {
            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: WarrenLayoutMetrics.sidebarHeaderRowHeight)
            .contentShape(.rect)
            .accessibilityLabel("Collapse sidebar")
            .accessibilityHint("Collapse the sidebar to icons")

            Spacer(minLength: 0)
        }
        .frame(height: WarrenLayoutMetrics.sidebarHeaderRowHeight)
        .padding(.horizontal, WarrenSpacing.compact)
    }
}
