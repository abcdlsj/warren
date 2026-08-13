import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenMobileWorkspaceDetailView: View {
    let workspace: Workspace
    let fixture: WarrenMobileFixture
    @Environment(\.colorScheme) private var colorScheme

    private var sessions: [WarrenMobileSessionModel] {
        fixture.sessions(for: workspace.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                WarrenMobileWorkspaceSummary(
                    workspace: workspace,
                    projectName: fixture.project(for: workspace)?.name ?? "Project"
                )
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.top, WarrenSpacing.small)
                WarrenMobileSectionHeading(title: "SESSIONS")
                if sessions.isEmpty {
                    WarrenMobileEmptyState(title: "No sessions", message: "Terminal sessions created on the Host will appear here.")
                } else {
                    ForEach(sessions) { session in
                        NavigationLink(value: WarrenMobileRoute.session(session.id)) {
                            WarrenMobileSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, WarrenSpacing.small)
        }
        .navigationTitle(workspace.name)
        .background(tokens.background)
        .scrollIndicators(.hidden)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}
