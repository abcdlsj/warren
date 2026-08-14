import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenDesktopSidebar: View {
    let projection: WarrenDesktopProjection
    @Binding var sidebarState: WarrenDesktopSidebarState
    let selection: WarrenDesktopSidebarSelection?
    let chromeMode: WarrenDesktopChromeMode
    let onAction: (WarrenDesktopAction) -> Void
    let onCommandPalette: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            WarrenDesktopSidebarHeader(
                isCollapsed: sidebarState.isCollapsed,
                chromeMode: chromeMode,
                onToggle: toggleSidebar,
                onCommandPalette: onCommandPalette
            )
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    WarrenDesktopSidebarRows(
                        groups: projection.groups,
                        workspaceActivities: projection.workspaceActivities,
                        isCollapsed: sidebarState.isCollapsed,
                        selection: selection,
                        onAddProject: { onAction(.addProject) },
                        onAction: onAction
                    )
                    .padding(.vertical, WarrenSpacing.compact)
                }
                .onChange(of: selection) { _, newSelection in
                    guard case let .workspace(workspaceID)? = newSelection else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(workspaceID, anchor: .center)
                    }
                }
            }
            .overlay(alignment: .top) {
                WarrenDesktopSidebarFade(edge: .top)
            }
            .overlay(alignment: .bottom) {
                WarrenDesktopSidebarFade(edge: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
        .background(tokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(tokens.border)
                .frame(width: WarrenSpacing.hairline)
        }
    }

    private func toggleSidebar() {
        sidebarState.toggleCollapsed()
        onAction(.toggleSidebar)
    }

}
