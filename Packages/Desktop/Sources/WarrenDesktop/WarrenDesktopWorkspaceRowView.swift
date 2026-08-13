import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// A workspace row uses a compact 26pt desktop rhythm. Its marker lives in a
/// stable slot. The complete row is one navigation/session target; there is no
/// tiny nested add button competing with branch selection.
struct WarrenDesktopWorkspaceRow: View {
    let workspace: Workspace
    let semanticScope: String
    let activity: AgentActivityState?
    let isCollapsed: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void

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
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                workspaceGlyph(tokens: tokens)
                if let activity {
                    WarrenDesktopActivityIndicator(activity: activity)
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
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .onHover { isHovered = $0 }
        .contextMenu { Button("Rename Workspace", action: onRename) }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            HStack(spacing: WarrenSpacing.compact) {
                workspaceGlyph(tokens: tokens)
                    .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                           height: WarrenLayoutMetrics.sidebarRowIconSlotSize)

                Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                    .font(WarrenTypography.workspaceRow)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.foreground.opacity(0.80))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let activity {
                    WarrenDesktopActivityIndicator(activity: activity)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.leading, WarrenSpacing.compact)
        .padding(.trailing, WarrenSpacing.compact)
        .background(isSelected ? tokens.fillSelected : (isHovered ? tokens.fillHover : .clear))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu { Button("Rename Workspace", action: onRename) }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset renders local worktrees as a plain dot; the main workspace gets
    /// a laptop glyph. Branch rows deliberately have no branch icon.
    @ViewBuilder
    private func workspaceGlyph(tokens: WarrenColorTokens) -> some View {
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

/// Superset-style Agent activity point. Live/actionable states pulse; ready is
/// a quiet static marker.
struct WarrenDesktopActivityIndicator: View {
    let activity: AgentActivityState
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
        case .working, .waitingForInput, .failed: true
        case .ready: false
        }
    }

    private var color: Color {
        switch activity {
        case .failed: Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        case .waitingForInput: Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
        case .working: Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
        case .ready: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        }
    }

    private var accessibilityLabel: String {
        switch activity {
        case .failed: "Session failed"
        case .waitingForInput: "Session needs input"
        case .working: "Agent working"
        case .ready: "Agent ready"
        }
    }
}
