import SwiftUI
import BurrowDesignSystem
import BurrowDomain

struct BurrowMobileWorkspaceDetailView: View {
    let workspace: Workspace
    let fixture: BurrowMobileFixture
    @Environment(\.colorScheme) private var colorScheme

    private var sessions: [BurrowMobileSessionModel] {
        fixture.sessions(for: workspace.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                BurrowMobileWorkspaceSummary(
                    workspace: workspace,
                    projectName: fixture.project(for: workspace)?.name ?? "Project"
                )
                .padding(.horizontal, BurrowSpacing.standard)
                .padding(.top, BurrowSpacing.small)
                BurrowMobileSectionHeading(title: "SESSIONS")
                if sessions.isEmpty {
                    BurrowMobileEmptyState(title: "No sessions", message: "Terminal sessions created on the Host will appear here.")
                } else {
                    ForEach(sessions) { session in
                        NavigationLink(value: BurrowMobileRoute.session(session.id)) {
                            BurrowMobileSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, BurrowSpacing.small)
        }
        .navigationTitle(workspace.name)
        .background(tokens.background)
        .scrollIndicators(.hidden)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}
