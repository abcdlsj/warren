import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Project-first search modeled after Superset's project picker.
///
/// Results preserve the Project → Workspace → Session relationship instead of
/// flattening unrelated resources into a generic command list.
struct WarrenDesktopCommandPalette: View {
    private struct SearchResult: Identifiable {
        let group: WarrenDesktopProjectGroup
        let workspaces: [Workspace]

        var id: ProjectID { group.project.id }
    }

    let projection: WarrenDesktopProjection
    let onAction: (WarrenDesktopAction) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let results = searchResults
        VStack(spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                TextField("Search projects or branches…", text: $query)
                    .textFieldStyle(.plain)
                    .font(WarrenTypography.body)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .frame(height: 42)

            Divider()

            ScrollView {
                LazyVStack(spacing: WarrenSpacing.compact) {
                    ForEach(results) { result in
                        projectResult(result, tokens: tokens)
                    }
                }
                .padding(WarrenSpacing.compact)
            }
            .frame(maxHeight: 390)

            if results.isEmpty {
                Text("No projects found")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WarrenSpacing.large)
            }
        }
        .frame(width: 480)
        .background(tokens.chromeSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.medium)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private func projectResult(
        _ result: SearchResult,
        tokens: WarrenColorTokens
    ) -> some View {
        let group = result.group
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            Button {
                choose(.selectProject(group.project.id))
            } label: {
                HStack(spacing: WarrenSpacing.compact) {
                    Image(systemName: "folder")
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.project.name)
                            .font(WarrenTypography.bodyEmphasis)
                            .foregroundStyle(tokens.foreground)
                        Text(group.project.rootPath)
                            .font(WarrenTypography.supporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(height: 42)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            ForEach(result.workspaces) { workspace in
                Button {
                    choose(.selectWorkspace(workspace.id))
                } label: {
                    HStack(spacing: WarrenSpacing.compact) {
                        Circle()
                            .fill(tokens.mutedForeground)
                            .frame(width: 5, height: 5)
                            .frame(width: 18)
                        Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name)
                            .font(WarrenTypography.workspaceRow)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("Workspace")
                            .font(WarrenTypography.badge)
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .padding(.leading, WarrenSpacing.large)
                    .padding(.trailing, WarrenSpacing.compact)
                    .frame(height: 30)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

            }
        }
        .padding(.vertical, WarrenSpacing.xxs)
        .background(tokens.fillHover.opacity(0.45))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
    }

    private var searchResults: [SearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return projection.groups.map { SearchResult(group: $0, workspaces: $0.workspaces) }
        }
        return projection.groups.compactMap { group in
            let projectMatches = group.project.name.lowercased().contains(normalized)
                || group.project.rootPath.lowercased().contains(normalized)
            let workspaces = projectMatches
                ? group.workspaces
                : group.workspaces.filter { workspace in
                    workspace.name.lowercased().contains(normalized)
                        || (workspace.branch?.lowercased().contains(normalized) ?? false)
                }
            guard projectMatches || !workspaces.isEmpty else { return nil }
            return SearchResult(group: group, workspaces: workspaces)
        }
    }

    private func choose(_ action: WarrenDesktopAction) {
        onAction(action)
        onDismiss()
    }
}
