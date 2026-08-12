import SwiftUI
import BurrowDesignSystem
import BurrowDomain

/// A compact command palette in the spirit of Superset and Termio: one search
/// field that jumps to sessions, opens workspaces, or runs shell actions.
struct BurrowDesktopCommandPalette: View {
    let projection: BurrowDesktopProjection
    let onAction: (BurrowDesktopAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private struct PaletteRow: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let subtitle: String
        let action: BurrowDesktopAction
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BurrowSpacing.compact) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search sessions, workspaces, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, BurrowSpacing.standard)
            .frame(height: 44)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredRows) { row in
                        Button {
                            onAction(row.action)
                            dismiss()
                        } label: {
                            HStack(spacing: BurrowSpacing.medium) {
                                Image(systemName: row.symbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                    if !row.subtitle.isEmpty {
                                        Text(row.subtitle)
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, BurrowSpacing.standard)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, BurrowSpacing.xs)
            }
            .frame(maxHeight: 320)

            if filteredRows.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No results for “\(query)”")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Divider()

            HStack {
                Text("↑↓ to browse   ↵ to open")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("esc to close")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, BurrowSpacing.standard)
            .frame(height: 30)
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: BurrowSpacing.hairline)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .onAppear {
            searchFocused = true
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var filteredRows: [PaletteRow] {
        var rows: [PaletteRow] = []
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let workspace = selectedWorkspace {
            rows.append(PaletteRow(
                id: "new-session",
                symbol: "plus.square.on.square",
                title: "New Session…",
                subtitle: workspace.name,
                action: .requestNewSession(workspace.id)
            ))
        }
        rows.append(PaletteRow(
            id: "add-project",
            symbol: "folder.badge.plus",
            title: "Add Project…",
            subtitle: "Import a local folder",
            action: .addProject
        ))
        rows.append(PaletteRow(
            id: "toggle-sidebar",
            symbol: "sidebar.left",
            title: "Toggle Sidebar",
            subtitle: "Show or hide the project list",
            action: .toggleSidebar
        ))
        for session in projection.sessions {
            let workspaceName = projection.workspace(for: session.id)?.name ?? "Workspace"
            rows.append(PaletteRow(
                id: "session-\(session.id)",
                symbol: session.kind.symbolName,
                title: session.title,
                subtitle: "\(workspaceName) · \(session.kind.displayName)",
                action: .openSession(session.id)
            ))
        }

        for group in projection.groups {
            for workspace in group.workspaces {
                rows.append(PaletteRow(
                    id: "workspace-\(workspace.id)",
                    symbol: "rectangle.split.3x1",
                    title: workspace.name,
                    subtitle: group.project.name,
                    action: .selectWorkspace(workspace.id)
                ))
            }
        }

        if normalized.isEmpty {
            return rows
        }
        return rows.filter {
            $0.title.lowercased().contains(normalized)
                || $0.subtitle.lowercased().contains(normalized)
        }
    }

    private var selectedWorkspace: Workspace? {
        if let session = projection.sessions.first(where: { $0.tabID == projection.tabs.first?.id }),
           let workspace = projection.workspace(for: session.id) {
            return workspace
        }
        return projection.groups.lazy.compactMap(\.workspaces.first).first
    }
}
