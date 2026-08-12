import SwiftUI
import BurrowDesignSystem
import BurrowDomain

struct BurrowMobileHostListView: View {
    let fixture: BurrowMobileFixture
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                BurrowMobileSectionHeading(title: "HOSTS")
                if fixture.hosts.isEmpty {
                    BurrowMobileEmptyState(title: "No hosts", message: "Hosts available to this client will appear here.")
                } else {
                    ForEach(fixture.hosts) { host in
                        NavigationLink(value: BurrowMobileRoute.host(host.id)) {
                            BurrowMobileHostRow(host: host, workspaceCount: fixture.workspaces(for: host.id).count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, BurrowSpacing.small)
        }
        .background(tokens.background)
        .scrollIndicators(.hidden)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

struct BurrowMobileHostDetailView: View {
    let host: BurrowDomain.Host
    let fixture: BurrowMobileFixture
    @Environment(\.colorScheme) private var colorScheme

    private var workspaces: [Workspace] {
        fixture.workspaces(for: host.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                BurrowMobileHostSummary(host: host, workspaceCount: workspaces.count)
                    .padding(.horizontal, BurrowSpacing.standard)
                    .padding(.top, BurrowSpacing.small)
                BurrowMobileSectionHeading(title: "WORKSPACES")
                if workspaces.isEmpty {
                    BurrowMobileEmptyState(title: "No workspaces", message: "Create a workspace on the Host to continue.")
                } else {
                    ForEach(workspaces) { workspace in
                        NavigationLink(value: BurrowMobileRoute.workspace(workspace.id)) {
                            BurrowMobileWorkspaceRow(
                                workspace: workspace,
                                projectName: fixture.project(for: workspace)?.name ?? "Project",
                                sessionCount: fixture.sessions(for: workspace.id).count
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, BurrowSpacing.small)
        }
        .navigationTitle(host.name)
        .background(tokens.background)
        .scrollIndicators(.hidden)
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

private struct BurrowMobileHostRow: View {
    let host: BurrowDomain.Host
    let workspaceCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BurrowSpacing.medium) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
                Text(host.name).font(BurrowTypography.sidebarRow)
                Text("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")")
                    .font(BurrowTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: BurrowSpacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BurrowSpacing.standard)
        .padding(.vertical, BurrowSpacing.compact)
        .background(tokens.background)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.name)")
        .accessibilityValue("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

private struct BurrowMobileHostSummary: View {
    let host: BurrowDomain.Host
    let workspaceCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BurrowSpacing.medium) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(tokens.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
                Text(host.name).font(BurrowTypography.activeTabTitle)
                Text("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s") available")
                    .font(BurrowTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, BurrowSpacing.compact)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.name)")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}
