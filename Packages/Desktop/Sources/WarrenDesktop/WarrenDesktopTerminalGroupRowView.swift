import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopTerminalGroupRow: View {
    let group: WarrenDesktopTerminalGroup
    let isCollapsed: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onSetHome: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

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
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .regular))
                if let activity = group.activity {
                    WarrenDesktopActivityIndicator(activity: activity)
                        .offset(x: 5, y: -3)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .focused($isFocused)
        .frame(width: 32, height: 32)
        .foregroundStyle(tokens.mutedForeground)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityLabel("Terminal group \(group.group.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "terminal-group.\(group.id.description)",
            role: .button,
            label: "Terminal group \(group.group.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .contextMenu { contextMenu }
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .regular))
                    .frame(
                        width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                        height: WarrenLayoutMetrics.sidebarRowIconSlotSize
                    )
                    .accessibilityHidden(true)

                Text(group.group.name.isEmpty ? "Terminal Group" : group.group.name)
                    .font(WarrenTypography.navigationItem)
                    .foregroundStyle(isSelected ? tokens.workspaceSelectedText : tokens.workspaceText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if group.runningSessionCount > 0 {
                    Text("\(group.runningSessionCount)")
                        .font(WarrenTypography.navigationMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityLabel("\(group.runningSessionCount) running")
                }

                if let activity = group.activity {
                    WarrenDesktopActivityIndicator(activity: activity)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .focused($isFocused)
        .accessibilityLabel("Terminal group \(group.group.name)")
        .accessibilityValue(
            "\(group.runningSessionCount) running terminal\(group.runningSessionCount == 1 ? "" : "s")"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "terminal-group.\(group.id.description)",
            role: .button,
            label: "Terminal group \(group.group.name)",
            value: isSelected ? "Selected" : "Not selected",
            isSelected: isSelected,
            action: onSelect
        )
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.horizontal, WarrenSpacing.compact)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Rename Terminal Group", action: onRename)
        Button("Set Default Home…", action: onSetHome)
        Divider()
        Button("Delete Terminal Group…", role: .destructive, action: onDelete)
    }
}

struct WarrenDesktopTerminalGroupEditor: View {
    let title: String
    @Binding var name: String
    @Binding var home: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var nameFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text(title)
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text("Name")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                TextField("Terminal group name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text("Default home")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                TextField("Use host HOME", text: $home)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onConfirm)
                    .buttonStyle(WarrenPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 390)
        .warrenPanelSurface(cornerRadius: WarrenRadius.large)
        .onAppear { nameFocused = true }
        .onExitCommand(perform: onCancel)
    }
}
