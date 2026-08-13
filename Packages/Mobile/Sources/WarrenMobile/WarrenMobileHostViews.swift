import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenMobileHostListView: View {
    let fixture: WarrenMobileFixture
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                WarrenMobileSectionHeading(title: "HOSTS")
                if fixture.hosts.isEmpty {
                    WarrenMobileEmptyState(title: "No hosts", message: "Hosts available to this client will appear here.")
                } else {
                    ForEach(fixture.hosts) { host in
                        NavigationLink(value: WarrenMobileRoute.host(host.id)) {
                            WarrenMobileHostRow(host: host, workspaceCount: fixture.workspaces(for: host.id).count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, WarrenSpacing.small)
        }
        .background(tokens.background)
        .scrollIndicators(.hidden)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

struct WarrenMobileHostDetailView: View {
    let host: WarrenDomain.Host
    let fixture: WarrenMobileFixture
    @Environment(\.colorScheme) private var colorScheme

    private var workspaces: [Workspace] {
        fixture.workspaces(for: host.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                WarrenMobileHostSummary(host: host, workspaceCount: workspaces.count)
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.top, WarrenSpacing.small)
                WarrenMobileSectionHeading(title: "WORKSPACES")
                if workspaces.isEmpty {
                    WarrenMobileEmptyState(title: "No workspaces", message: "Create a workspace on the Host to continue.")
                } else {
                    ForEach(workspaces) { workspace in
                        NavigationLink(value: WarrenMobileRoute.workspace(workspace.id)) {
                            WarrenMobileWorkspaceRow(
                                workspace: workspace,
                                projectName: fixture.project(for: workspace)?.name ?? "Project",
                                sessionCount: fixture.sessions(for: workspace.id).count
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, WarrenSpacing.small)
        }
        .navigationTitle(host.name)
        .background(tokens.background)
        .scrollIndicators(.hidden)
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

private struct WarrenMobileHostRow: View {
    let host: WarrenDomain.Host
    let workspaceCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WarrenSpacing.medium) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text(host.name).font(WarrenTypography.sidebarRow)
                Text("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")")
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: WarrenSpacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.compact)
        .background(tokens.background)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.name)")
        .accessibilityValue("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

private struct WarrenMobileHostSummary: View {
    let host: WarrenDomain.Host
    let workspaceCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WarrenSpacing.medium) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(tokens.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text(host.name).font(WarrenTypography.activeTabTitle)
                Text("\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s") available")
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WarrenSpacing.compact)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.name)")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}
