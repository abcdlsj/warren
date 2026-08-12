import SwiftUI
import BurrowClientCore
import BurrowDesignSystem
import BurrowDomain
import BurrowObservation

struct BurrowDesktopWorkspaceContent<TerminalSurface: View>: View {
    let workspace: Workspace?
    let tab: ClientTab?
    let hasProjects: Bool
    let showsPaneHeader: Bool
    let branchSessions: [BurrowDesktopSession]
    let onAddProject: () -> Void
    let onImportSuperset: () -> Void
    let onNewSession: () -> Void
    let onOpenSession: (TerminalSessionID) -> Void
    let terminalSurface: @MainActor (BurrowDesktopTerminalContext) -> TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        if let workspace, let tab {
            BurrowDesktopPaneView(
                workspace: workspace,
                tab: tab,
                showsPaneHeader: showsPaneHeader,
                terminalSurface: terminalSurface(
                    BurrowDesktopTerminalContext(workspace: workspace, tab: tab)
                )
            )
        } else if workspace == nil, tab == nil, !hasProjects {
            emptyWelcome(tokens: tokens)
        } else if let workspace, tab == nil {
            emptyWorkspace(tokens: tokens, workspace: workspace)
        } else {
            VStack(spacing: BurrowSpacing.medium) {
                Text(tab == nil ? "No tabs open" : "No panes open")
                    .font(BurrowTypography.emptyState)
                    .foregroundStyle(tokens.mutedForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab == nil ? "No open tabs" : "No open panels")
        }
    }

    private func emptyWelcome(tokens: BurrowColorTokens) -> some View {
        VStack(spacing: BurrowSpacing.medium) {
            VStack(spacing: BurrowSpacing.xs) {
                Text("Welcome to Burrow")
                    .font(.system(size: 18, weight: .semibold))
                Text("Add a project folder, then start a shell or an agent CLI.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
            }
            Button(action: onAddProject) {
                Label("Add Project…", systemImage: "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .burrowSemanticElement(
                id: "onboarding.add-project",
                role: .button,
                label: "Add Project",
                action: onAddProject
            )
            Button(action: onImportSuperset) {
                Text("Import from Superset…")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .burrowSemanticElement(
                id: "onboarding.import-superset",
                role: .button,
                label: "Import from Superset",
                action: onImportSuperset
            )
            HStack(spacing: BurrowSpacing.xs) {
                Text("Or press")
                Text("⌘K")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tokens.fillHover)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("to open the command palette.")
            }
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func emptyWorkspace(tokens: BurrowColorTokens, workspace: Workspace) -> some View {
        VStack(spacing: BurrowSpacing.medium) {
            VStack(spacing: BurrowSpacing.xs) {
                Text(workspace.name)
                    .font(.system(size: 18, weight: .semibold))
                if let branch = workspace.branch {
                    Text(branch)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(tokens.highlight)
                }
            }

            if branchSessions.isEmpty {
                Text("No sessions in this branch")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
            } else {
                VStack(spacing: 2) {
                    ForEach(branchSessions) { session in
                        Button {
                            onOpenSession(session.id)
                        } label: {
                            HStack(spacing: BurrowSpacing.compact) {
                                Text(session.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                Spacer()
                                Text(session.kind.displayName)
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .padding(.horizontal, BurrowSpacing.medium)
                            .frame(height: 34)
                            .background(tokens.fillHover.opacity(0.001))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
            }

            Button(action: onNewSession) {
                Label("New Session…", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct BurrowDesktopPaneView<TerminalSurface: View>: View {
    let workspace: Workspace
    let tab: ClientTab
    let showsPaneHeader: Bool
    let terminalSurface: TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            if showsPaneHeader {
                HStack(spacing: BurrowSpacing.compact) {
                    Text(tab.title)
                        .font(BurrowTypography.paneHeader)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BurrowSpacing.medium)
                .frame(height: BurrowLayoutMetrics.paneHeaderHeight)
                .background(tokens.tertiaryWash)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(tokens.border)
                        .frame(height: BurrowSpacing.hairline)
                }
            }

            terminalSurface
                // AppKit-backed terminal views have a useful intrinsic grid
                // size. Without an explicit flexible frame SwiftUI preserves
                // that size and centers a 50-column surface inside a much
                // larger pane. The pane owns geometry, so the renderer must
                // accept the entire proposed content size.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(BurrowSpacing.compact)
                .background(tokens.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .overlay {
            Rectangle()
                .stroke(tokens.border, lineWidth: BurrowSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel \(tab.title)")
    }
}

struct BurrowDesktopTerminalPlaceholder: View {
    let workspace: Workspace

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        VStack(spacing: BurrowSpacing.compact) {
            Text("Preview terminal surface")
                .font(BurrowTypography.emptyState)
            Text("Session content for \(workspace.name) will appear when the terminal renderer is connected.")
                .font(.footnote)
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(BurrowSpacing.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview terminal content for workspace \(workspace.name)")
    }
}

struct BurrowDesktopInspectorSlot: View {
    let content: BurrowDesktopInspectorContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: BurrowSpacing.medium) {
            Text(content.title)
                .font(BurrowTypography.paneHeader)
                .accessibilityAddTraits(.isHeader)
            Text(content.detail)
                .font(.footnote)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(BurrowSpacing.medium)
        .frame(
            minWidth: BurrowLayoutMetrics.inspectorDefaultWidth,
            idealWidth: BurrowLayoutMetrics.inspectorDefaultWidth,
            maxWidth: BurrowLayoutMetrics.inspectorDefaultWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(tokens.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tokens.border)
                .frame(width: BurrowSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
    }
}
