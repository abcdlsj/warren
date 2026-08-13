import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopWorkspaceContent<TerminalSurface: View>: View {
    let workspace: Workspace?
    let tab: ClientTab?
    let hasProjects: Bool
    let showsPaneHeader: Bool
    let branchSessions: [WarrenDesktopSession]
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let terminalFont: TerminalFontPreference
    let onAddProject: () -> Void
    let onImportSuperset: () -> Void
    let onNewSession: () -> Void
    let onOpenSession: (TerminalSessionID) -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let workspace, let tab {
            WarrenDesktopPaneView(
                workspace: workspace,
                tab: tab,
                session: tab.sessionID.flatMap { sessionID in
                    branchSessions.first { $0.id == sessionID }
                },
                hostName: hostName,
                titleTemplate: titleTemplate,
                showsPaneHeader: showsPaneHeader,
                terminalSurface: terminalSurface(
                    WarrenDesktopTerminalContext(
                        workspace: workspace,
                        tab: tab,
                        font: terminalFont
                    )
                )
            )
        } else if workspace == nil, tab == nil, !hasProjects {
            emptyWelcome(tokens: tokens)
        } else if let workspace, tab == nil {
            emptyWorkspace(tokens: tokens, workspace: workspace)
        } else {
            VStack(spacing: WarrenSpacing.medium) {
                Text(tab == nil ? "No tabs open" : "No panes open")
                    .font(WarrenTypography.emptyState)
                    .foregroundStyle(tokens.mutedForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab == nil ? "No open tabs" : "No open panels")
        }
    }

    private func emptyWelcome(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(tokens.mutedForeground)
            Text("Open a project to begin")
                .font(WarrenTypography.screenTitle)
            Button(action: onAddProject) {
                Text("Add Project…")
                    .font(WarrenTypography.bodyEmphasis)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .warrenSemanticElement(
                id: "onboarding.add-project",
                role: .button,
                label: "Add Project",
                action: onAddProject
            )
            Button(action: onImportSuperset) {
                Text("Import from Superset")
                    .font(WarrenTypography.supporting)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tokens.mutedForeground)
            .warrenSemanticElement(
                id: "onboarding.import-superset",
                role: .button,
                label: "Import from Superset",
                action: onImportSuperset
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func emptyWorkspace(tokens: WarrenColorTokens, workspace: Workspace) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            if branchSessions.isEmpty {
                Image(systemName: "terminal")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                Text("Start a session")
                    .font(WarrenTypography.screenTitle)
                Button(action: onNewSession) {
                    Text("New Session…")
                        .font(WarrenTypography.bodyEmphasis)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                VStack(spacing: 2) {
                    ForEach(branchSessions) { session in
                        Button {
                            onOpenSession(session.id)
                        } label: {
                            HStack(spacing: WarrenSpacing.compact) {
                                Text(session.title)
                                    .font(WarrenTypography.bodyEmphasis)
                                    .foregroundStyle(tokens.foreground)
                                Spacer()
                                Text(session.kind.displayName)
                                    .font(WarrenTypography.badge)
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .padding(.horizontal, WarrenSpacing.medium)
                            .frame(height: 34)
                            .background(tokens.fillHover.opacity(0.001))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct WarrenDesktopPaneView<TerminalSurface: View>: View {
    let workspace: Workspace
    let tab: ClientTab
    let session: WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let showsPaneHeader: Bool
    let terminalSurface: TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            if showsPaneHeader {
                HStack(spacing: WarrenSpacing.compact) {
                    Text(displayTitle)
                        .font(WarrenTypography.paneHeader)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(height: WarrenLayoutMetrics.paneHeaderHeight)
                .background(tokens.tertiaryWash)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(tokens.border)
                        .frame(height: WarrenSpacing.hairline)
                }
            }

            terminalSurface
                // AppKit-backed terminal views have a useful intrinsic grid
                // size. Without an explicit flexible frame SwiftUI preserves
                // that size and centers a 50-column surface inside a much
                // larger pane. The pane owns geometry, so the renderer must
                // accept the entire proposed content size.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(WarrenSpacing.compact)
                .background(tokens.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .overlay {
            Rectangle()
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel \(tab.title)")
    }

    private var displayTitle: String {
        titleTemplate.render(TerminalDisplayTitleContext(
            session: session?.title ?? tab.title,
            command: session?.runtimeProcess ?? tab.kind.displayName,
            directory: session?.workingDirectory.isEmpty == false
                ? session!.workingDirectory
                : workspace.path,
            workspace: workspace.name,
            branch: workspace.branch ?? "",
            host: hostName,
            user: NSUserName(),
            os: ProcessInfo.processInfo.operatingSystemVersionString
        ))
    }
}

struct WarrenDesktopTerminalPlaceholder: View {
    let workspace: Workspace

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: WarrenSpacing.compact) {
            Text("Preview terminal surface")
                .font(WarrenTypography.emptyState)
            Text("Session content for \(workspace.name) will appear when the terminal renderer is connected.")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WarrenSpacing.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview terminal content for workspace \(workspace.name)")
    }
}

struct WarrenDesktopInspectorSlot: View {
    let content: WarrenDesktopInspectorContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text(content.title)
                .font(WarrenTypography.paneHeader)
                .accessibilityAddTraits(.isHeader)
            Text(content.detail)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(WarrenSpacing.medium)
        .frame(
            minWidth: WarrenLayoutMetrics.inspectorDefaultWidth,
            idealWidth: WarrenLayoutMetrics.inspectorDefaultWidth,
            maxWidth: WarrenLayoutMetrics.inspectorDefaultWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(tokens.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tokens.border)
                .frame(width: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
    }
}
