import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Project-first search modeled after Superset's command palette.
///
/// Results preserve the Project → Workspace → Session relationship instead of
/// flattening unrelated resources into a generic command list. The panel stays
/// compact while idle and expands only after the user starts searching.
struct WarrenDesktopCommandPalette: View {
    private struct SearchResult: Identifiable {
        let group: WarrenDesktopProjectGroup
        let workspaces: [Workspace]

        var id: ProjectID { group.project.id }
    }

    private struct PaletteRow: Identifiable {
        enum Kind {
            case project
            case workspace
        }

        let id: String
        let kind: Kind
        let result: SearchResult
        let workspace: Workspace?
    }

    let projection: WarrenDesktopProjection
    let onAction: (WarrenDesktopAction) -> Void
    let onDismiss: () -> Void
    let width: CGFloat
    let resultsMaxHeight: CGFloat

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hasQuery: Bool {
        !normalizedQuery.isEmpty
    }

    private var searchResults: [SearchResult] {
        let normalized = normalizedQuery
        guard !normalized.isEmpty else { return [] }
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

    private var rows: [PaletteRow] {
        searchResults.flatMap { result -> [PaletteRow] in
            var rows = [PaletteRow(
                id: "project.\(result.group.project.id)",
                kind: .project,
                result: result,
                workspace: nil
            )]
            rows.append(contentsOf: result.workspaces.map { workspace in
                PaletteRow(
                    id: "workspace.\(workspace.id)",
                    kind: .workspace,
                    result: result,
                    workspace: workspace
                )
            })
            return rows
        }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            inputRow(tokens: tokens)

            if hasQuery {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)

                if rows.isEmpty {
                    Text("No results found.")
                        .font(WarrenTypography.body)
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WarrenSpacing.large)
                } else {
                    ScrollViewReader { proxy in
                        WarrenOverflowFadeScrollView(
                            .vertical,
                            fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                            surface: tokens.popoverSurface
                        ) {
                            LazyVStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                ForEach(searchResults) { result in
                                    projectGroup(result, tokens: tokens)
                                }
                            }
                            .padding(WarrenLayoutMetrics.commandPaletteResultsPadding)
                        }
                        .frame(maxHeight: resultsMaxHeight)
                        .onChange(of: selectedIndex) { _, newIndex in
                            guard rows.indices.contains(newIndex) else { return }
                            proxy.scrollTo(rows[newIndex].id, anchor: .center)
                        }
                    }
                }
            } else {
                idlePrompt(tokens: tokens)
            }
        }
        .frame(width: width)
        .warrenPanelSurface(cornerRadius: WarrenRadius.base)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: rows.count) { _, count in
            if !rows.indices.contains(selectedIndex) {
                selectedIndex = max(0, count - 1)
            }
        }
    }

    private func inputRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            TextField("Search projects or workspaces…", text: $query)
                .textFieldStyle(.plain)
                .font(WarrenTypography.body)
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard rows.indices.contains(selectedIndex) else { return .ignored }
                    chooseRow(rows[selectedIndex])
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear search")
            }

            Text("esc")
                .font(WarrenTypography.shortcut)
                .tracking(0.5)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tokens.muted)
                .clipShape(.rect(cornerRadius: WarrenRadius.xs))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.xs)
                        .stroke(tokens.ring, lineWidth: WarrenSpacing.hairline)
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, WarrenLayoutMetrics.commandPaletteInputHorizontalPadding)
        .frame(height: WarrenLayoutMetrics.commandInputHeight)
        .background(tokens.popoverSurface)
    }

    private func idlePrompt(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)

            Text("Start typing to search projects and workspaces")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, WarrenLayoutMetrics.commandPaletteInputHorizontalPadding)
        .frame(height: WarrenLayoutMetrics.commandPaletteIdleHeight)
        .background(tokens.popoverSurface)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func projectGroup(
        _ result: SearchResult,
        tokens: WarrenColorTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            Text(result.group.project.name)
                .font(WarrenTypography.groupHeading)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
                .padding(.top, WarrenSpacing.compact)
                .padding(.bottom, WarrenSpacing.xs)

            projectRow(result, tokens: tokens)

            ForEach(result.workspaces) { workspace in
                workspaceRow(result, workspace: workspace, tokens: tokens)
            }
        }
        .padding(.bottom, WarrenSpacing.xs)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
    }

    private func projectRow(
        _ result: SearchResult,
        tokens: WarrenColorTokens
    ) -> some View {
        let id = "project.\(result.group.project.id)"
        let selectedID = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
        let isSelected = selectedID == id
        return Button {
            choose(.selectProject(result.group.project.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.group.project.name)
                        .font(WarrenTypography.navigationItem)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    Text(result.group.project.rootPath)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
            .frame(minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .id(id)
        .onHover { isHovered in
            if isHovered, let index = rows.firstIndex(where: { $0.id == id }) {
                selectedIndex = index
            }
        }
    }

    private func workspaceRow(
        _ result: SearchResult,
        workspace: Workspace,
        tokens: WarrenColorTokens
    ) -> some View {
        let id = "workspace.\(workspace.id)"
        let selectedID = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
        let isSelected = selectedID == id
        return Button {
            choose(.selectWorkspace(workspace.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name)
                    .font(WarrenTypography.navigationItem)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Workspace")
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.mutedForeground)
            }
            .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
            .frame(minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .id(id)
        .onHover { isHovered in
            if isHovered, let index = rows.firstIndex(where: { $0.id == id }) {
                selectedIndex = index
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), rows.count - 1)
        selectedIndex = next
    }

    private func chooseRow(_ row: PaletteRow) {
        switch row.kind {
        case .project:
            choose(.selectProject(row.result.group.project.id))
        case .workspace:
            if let workspace = row.workspace {
                choose(.selectWorkspace(workspace.id))
            }
        }
    }

    private func choose(_ action: WarrenDesktopAction) {
        onAction(action)
        onDismiss()
    }
}
