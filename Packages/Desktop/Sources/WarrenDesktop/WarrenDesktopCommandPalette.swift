import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Project-first search modeled after Superset's command palette.
///
/// Results preserve the Project → Workspace → Session relationship instead of
/// flattening unrelated resources into a generic command list. The palette is
/// a centered modal: a scrim, a 48pt input row, project group headings, and
/// full keyboard navigation (arrows + Return, Esc to dismiss).
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

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

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

            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

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
                    .padding(WarrenSpacing.compact)
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedIndex) { _, newIndex in
                    guard rows.indices.contains(newIndex) else { return }
                    proxy.scrollTo(rows[newIndex].id, anchor: .center)
                }
            }

            if rows.isEmpty {
                Text("No results found")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WarrenSpacing.large)
            }
        }
        .frame(width: WarrenLayoutMetrics.commandPaletteWidth)
        .background(tokens.popoverSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.medium)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
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
                .frame(width: 20)
                .accessibilityHidden(true)

            TextField("Type a command or search…", text: $query)
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
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(tokens.fillHover)
                .clipShape(.rect(cornerRadius: 4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .frame(height: WarrenLayoutMetrics.commandInputHeight)
        .background(tokens.inputSurface)
    }

    @ViewBuilder
    private func projectGroup(
        _ result: SearchResult,
        tokens: WarrenColorTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            Text(result.group.project.name)
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.compact)
                .padding(.top, WarrenSpacing.xs)
                .padding(.bottom, WarrenSpacing.xxs)

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
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "folder")
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.group.project.name)
                        .font(WarrenTypography.bodyEmphasis)
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
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(height: 44)
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
            HStack(spacing: WarrenSpacing.compact) {
                Circle()
                    .fill(tokens.mutedForeground)
                    .frame(width: 5, height: 5)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name)
                    .font(WarrenTypography.navigationItem)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Workspace")
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.mutedForeground)
            }
            .padding(.leading, WarrenSpacing.large)
            .padding(.trailing, WarrenSpacing.compact)
            .frame(height: 34)
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
