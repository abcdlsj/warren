import SwiftUI
import BurrowDesignSystem
import BurrowDomain

struct BurrowDesktopSidebar: View {
    let projection: BurrowDesktopProjection
    @Binding var sidebarState: BurrowDesktopSidebarState
    let selection: BurrowDesktopSidebarSelection?
    let selectedTabID: String?
    let chromeMode: BurrowDesktopChromeMode
    let onAction: (BurrowDesktopAction) -> Void
    let onCommandPalette: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            BurrowDesktopSidebarHeader(
                isCollapsed: sidebarState.isCollapsed,
                chromeMode: chromeMode,
                onToggle: toggleSidebar,
                onCommandPalette: onCommandPalette
            )
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    BurrowDesktopSidebarRows(
                        groups: projection.groups,
                        sessions: projection.sessions,
                        isCollapsed: sidebarState.isCollapsed,
                        selection: selection,
                        onAddProject: { onAction(.addProject) },
                        onAction: onAction
                    )
                    .padding(.vertical, BurrowSpacing.compact)
                }
                .onChange(of: selection) { _, newSelection in
                    guard case let .workspace(workspaceID)? = newSelection else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(workspaceID, anchor: .center)
                    }
                }
            }
            .overlay(alignment: .top) {
                BurrowDesktopSidebarFade(edge: .top)
            }
            .overlay(alignment: .bottom) {
                BurrowDesktopSidebarFade(edge: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
        .background(tokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(tokens.border)
                .frame(width: BurrowSpacing.hairline)
        }
    }

    private func toggleSidebar() {
        sidebarState.toggleCollapsed()
        onAction(.toggleSidebar)
    }

    private var selectedWorkspace: Workspace? {
        guard let selection else {
            return projection.groups.lazy.compactMap(\.workspaces.first).first
        }
        switch selection {
        case .project(let projectID):
            return projection.firstWorkspace(in: projectID)
        case .workspace(let workspaceID):
            return projection.workspace(id: workspaceID)
        }
    }
}
