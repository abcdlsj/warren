import SwiftUI
import BurrowDesignSystem
import BurrowDomain
import BurrowObservation

/// A workspace row uses a compact 26pt desktop rhythm. Its marker lives in a
/// stable slot. The complete row is one navigation/session target; there is no
/// tiny nested add button competing with branch selection.
struct BurrowDesktopWorkspaceRow: View {
    let workspace: Workspace
    let semanticScope: String
    let sessionCount: Int
    let activity: TerminalSessionActivityState?
    let isCollapsed: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        if isCollapsed {
            collapsedRow
        } else {
            expandedRow
        }
    }

    private var collapsedRow: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                workspaceGlyph(tokens: tokens)
                if let activity {
                    BurrowDesktopActivityIndicator(activity: activity)
                        .offset(x: 5, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .clipShape(.rect(cornerRadius: BurrowRadius.row))
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .burrowSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, BurrowSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            HStack(spacing: BurrowSpacing.compact) {
                workspaceGlyph(tokens: tokens)
                    .frame(width: BurrowLayoutMetrics.sidebarRowIconSlotSize,
                           height: BurrowLayoutMetrics.sidebarRowIconSlotSize)

                Text(workspace.branch?.isEmpty == false
                     ? workspace.branch!
                     : (workspace.name.isEmpty ? "Workspace" : workspace.name))
                    .font(BurrowTypography.workspaceRow)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.foreground.opacity(0.80))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let activity {
                    BurrowDesktopActivityIndicator(activity: activity)
                }

                Spacer(minLength: 0)

                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(BurrowTypography.activityChip)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(tokens.fillHover)
                        .clipShape(.rect(cornerRadius: BurrowRadius.small))
                        .accessibilityLabel("\(sessionCount) sessions")
                }
            }
            .frame(minHeight: BurrowLayoutMetrics.sidebarWorkspaceRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .burrowSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .frame(maxWidth: .infinity, minHeight: BurrowLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.leading, BurrowSpacing.compact)
        .padding(.trailing, BurrowSpacing.compact)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .clipShape(.rect(cornerRadius: BurrowRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.horizontal, BurrowSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset renders local worktrees as a plain dot; the main workspace gets
    /// a laptop glyph. Branch rows deliberately have no branch icon.
    @ViewBuilder
    private func workspaceGlyph(tokens: BurrowColorTokens) -> some View {
        if workspace.branch == nil {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(tokens.mutedForeground.opacity(0.9))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}

/// Superset-style status point. Live/actionable states pulse; ready and exited
/// Sessions remain quiet static markers.
struct BurrowDesktopActivityIndicator: View {
    let activity: TerminalSessionActivityState
    @State private var isExpanded = false

    var body: some View {
        ZStack {
            if pulses {
                Circle()
                    .fill(color.opacity(0.65))
                    .frame(width: 8, height: 8)
                    .scaleEffect(isExpanded ? 1.9 : 1)
                    .opacity(isExpanded ? 0 : 0.75)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 10, height: 10)
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
                isExpanded = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private var pulses: Bool {
        switch activity {
        case .connecting, .working, .waitingForInput, .failed: true
        case .ready, .exited: false
        }
    }

    private var color: Color {
        switch activity {
        case .failed: Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        case .waitingForInput: Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
        case .connecting: Color(red: 168 / 255, green: 165 / 255, blue: 163 / 255)
        case .working: Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
        case .ready: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        case .exited: Color(red: 120 / 255, green: 113 / 255, blue: 108 / 255)
        }
    }

    private var accessibilityLabel: String {
        switch activity {
        case .failed: "Session failed"
        case .waitingForInput: "Session needs input"
        case .connecting: "Session connecting"
        case .working: "Session working"
        case .ready: "Session ready"
        case .exited: "Session exited"
        }
    }
}
