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
    let session: WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let terminalFont: TerminalFontPreference
    let onAddProject: () -> Void
    let onImportSuperset: () -> Void
    let onNewSession: () -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var primaryButtonFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let workspace, let tab {
            WarrenDesktopPaneView(
                workspace: workspace,
                tab: tab,
                session: session,
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
                Text("Select a workspace")
                    .font(WarrenTypography.emptyState)
                    .foregroundStyle(tokens.mutedForeground)
                Text("Choose a workspace to open its terminals")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No workspace selected")
        }
    }

    private func emptyWelcome(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.compact) {
            Text("Open a project to begin")
                .font(WarrenTypography.emptyState)
                .foregroundStyle(tokens.mutedForeground)
            Button(action: onAddProject) {
                Text("Add Project…")
                    .font(WarrenTypography.supporting)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tokens.mutedForeground)
            .focused($primaryButtonFocused)
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
            .opacity(0.75)
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
        VStack(spacing: WarrenSpacing.compact) {
            Text("Start a session")
                .font(WarrenTypography.emptyState)
                .foregroundStyle(tokens.mutedForeground)
            Text("Open a terminal with the + button or a preset")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .opacity(0.75)
            VStack(spacing: WarrenSpacing.xs) {
                shortcutRow(tokens: tokens, key: "⌘T", label: "New terminal")
                shortcutRow(tokens: tokens, key: "⌘X", label: "Next tab")
                shortcutRow(tokens: tokens, key: "⇧⌘X", label: "Previous tab")
                shortcutRow(tokens: tokens, key: "⌘W", label: "Close terminal")
            }
            .frame(maxWidth: 420)
            .padding(.top, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No open sessions in \(workspace.name)")
    }

    private func shortcutRow(
        tokens: WarrenColorTokens,
        key: String,
        label: String
    ) -> some View {
        HStack(spacing: WarrenSpacing.medium) {
            Text(key)
                .font(WarrenTypography.shortcut)
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 72, alignment: .leading)
            Spacer(minLength: WarrenSpacing.medium)
            Text(label)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
        }
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
                        .font(WarrenTypography.paneShellTitle)
                        .foregroundStyle(tokens.mutedForeground)
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
