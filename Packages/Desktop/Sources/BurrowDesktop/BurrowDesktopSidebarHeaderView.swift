import SwiftUI
import BurrowDesignSystem

struct BurrowDesktopSidebarHeader: View {
    let isCollapsed: Bool
    let chromeMode: BurrowDesktopChromeMode
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
                ? BurrowColorTokens.resolved(for: colorScheme).sidebarSurface
                : .clear
        )
    }

    /// Superset's expanded dashboard header has a 32pt traffic-light row with
    /// an 80pt leading inset, followed by its compact navigation actions. Burrow
    /// keeps the same geometry and exposes the one supported action: opening a
    /// new terminal session in the selected workspace.
    private var workspaceHeader: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                BurrowDesktopWindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: BurrowLayoutMetrics.tabBarHeight)
                    .background(BurrowColorTokens.resolved(for: colorScheme).chromeSurface)

                compactSearchButton
                    .padding(.top, BurrowSpacing.medium)
            } else {
                trafficRow
                    .padding(.top, BurrowLayoutMetrics.sidebarHeaderTopPadding)
                    .padding(.bottom, BurrowLayoutMetrics.sidebarHeaderBottomGap)

                expandedSearchButton
            }
        }
    }

    private var trafficRow: some View {
        HStack(spacing: BurrowSpacing.small) {
            // Superset owns an 80pt traffic-light pad; Burrow renders the
            // lights itself because the window is borderless.
            BurrowDesktopTrafficLights()
                .frame(width: BurrowLayoutMetrics.macTrafficLightInset, alignment: .leading)

            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .foregroundStyle(BurrowColorTokens.resolved(for: colorScheme).mutedForeground)
            .accessibilityLabel("Collapse sidebar")
            .accessibilityHint("Collapse the project and session list")

            BurrowDesktopWindowDragRegion()
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .frame(height: BurrowLayoutMetrics.sidebarTrafficRowHeight)
    }

    private var expandedSearchButton: some View {
        Button(action: onCommandPalette) {
            HStack(spacing: BurrowSpacing.compact) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BurrowColorTokens.resolved(for: colorScheme).mutedForeground)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text("Search")
                    .font(BurrowTypography.sidebarRow)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("⌘K")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BurrowColorTokens.resolved(for: colorScheme).mutedForeground)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(BurrowColorTokens.resolved(for: colorScheme).fillHover)
                    .clipShape(.rect(cornerRadius: 4))
            }
            .padding(.horizontal, BurrowSpacing.compact)
            .frame(height: BurrowLayoutMetrics.sidebarProjectRowHeight)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(BurrowColorTokens.resolved(for: colorScheme).mutedForeground)
        .background(BurrowColorTokens.resolved(for: colorScheme).fillHover.opacity(0.001))
        .clipShape(.rect(cornerRadius: BurrowRadius.small))
        .padding(.horizontal, BurrowSpacing.xs)
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
        .foregroundStyle(BurrowColorTokens.resolved(for: colorScheme).mutedForeground)
        .accessibilityLabel("Search")
    }

    private var collapsedDashboardHeader: some View {
        Button(action: onToggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: BurrowLayoutMetrics.sidebarHeaderRowHeight)
        .contentShape(.rect)
        .accessibilityLabel("Expand sidebar")
        .accessibilityHint("Show the project and workspace list")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BurrowSpacing.compact)
    }

    private var expandedDashboardHeader: some View {
        HStack(spacing: BurrowSpacing.compact) {
            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: BurrowLayoutMetrics.sidebarHeaderRowHeight)
            .contentShape(.rect)
            .accessibilityLabel("Collapse sidebar")
            .accessibilityHint("Collapse the sidebar to icons")

            Spacer(minLength: 0)
        }
        .frame(height: BurrowLayoutMetrics.sidebarHeaderRowHeight)
        .padding(.horizontal, BurrowSpacing.compact)
    }
}
