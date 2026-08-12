import SwiftUI
import BurrowDesignSystem
import BurrowDomain

struct BurrowMobileWorkspaceSummary: View {
    let workspace: Workspace
    let projectName: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: BurrowSpacing.xs) {
            HStack(spacing: BurrowSpacing.small) {
                Image(systemName: "folder")
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityHidden(true)
                Text(projectName)
                    .font(BurrowTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Text(workspace.path)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch = workspace.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(BurrowTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, BurrowSpacing.compact)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue("\(projectName), \(workspace.path)")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}

struct BurrowMobileWorkspaceRow: View {
    let workspace: Workspace
    let projectName: String
    let sessionCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: BurrowSpacing.medium) {
            Image(systemName: "folder")
                .frame(width: 28, height: 28)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BurrowSpacing.xxs) {
                Text(workspace.name).font(BurrowTypography.sidebarRow)
                HStack(spacing: BurrowSpacing.xs) {
                    Text(projectName)
                    if let branch = workspace.branch {
                        Text("·")
                        Text(branch)
                    }
                }
                .font(BurrowTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: BurrowSpacing.small)
            Text("\(sessionCount)")
                .font(BurrowTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BurrowSpacing.standard)
        .padding(.vertical, BurrowSpacing.compact)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
    }

    private var tokens: BurrowColorTokens {
        BurrowColorTokens.resolved(for: colorScheme)
    }
}
