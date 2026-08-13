import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenMobileWorkspaceSummary: View {
    let workspace: Workspace
    let projectName: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            HStack(spacing: WarrenSpacing.small) {
                Image(systemName: "folder")
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityHidden(true)
                Text(projectName)
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Text(workspace.path)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch = workspace.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WarrenSpacing.compact)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue("\(projectName), \(workspace.path)")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}

struct WarrenMobileWorkspaceRow: View {
    let workspace: Workspace
    let projectName: String
    let sessionCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WarrenSpacing.medium) {
            Image(systemName: "folder")
                .frame(width: 28, height: 28)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text(workspace.name).font(WarrenTypography.sidebarRow)
                HStack(spacing: WarrenSpacing.xs) {
                    Text(projectName)
                    if let branch = workspace.branch {
                        Text("·")
                        Text(branch)
                    }
                }
                .font(WarrenTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: WarrenSpacing.small)
            Text("\(sessionCount)")
                .font(WarrenTypography.badge)
                .foregroundStyle(tokens.mutedForeground)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.compact)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
    }

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }
}
