import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenObservation

struct WarrenDesktopTabItem: View {
    let tab: ClientTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let onMoveBefore: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @FocusState private var isCloseFocused: Bool
    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var exposesClose: Bool {
        tab.sessionID != nil && (isHovered || isCloseFocused || forceHover)
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: WarrenSpacing.small) {
                    if tab.sessionID == nil {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                    Text(tab.title)
                        .font(isSelected ? WarrenTypography.activeTabTitle : WarrenTypography.tabTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, WarrenSpacing.medium)
                .padding(.trailing, WarrenLayoutMetrics.tabAccessoryColumnWidth)
                .frame(
                    width: WarrenLayoutMetrics.tabWidth,
                    height: WarrenLayoutMetrics.tabBarHeight,
                    alignment: .leading
                )
                .background(Color.clear)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(tab.sessionID == nil)
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
            .accessibilityLabel("Tab \(tab.title)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .warrenSemanticElement(
                id: "tab.\(tab.id)",
                role: .tab,
                label: "Tab \(tab.title)",
                value: isSelected ? "Selected" : "Not selected",
                isSelected: isSelected,
                action: onSelect
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(
                width: WarrenLayoutMetrics.tabCloseButtonSize,
                height: WarrenLayoutMetrics.tabCloseButtonSize
            )
            .contentShape(.rect)
            .background(
                isCloseHovered
                    ? (isSelected ? tokens.muted.opacity(0.65) : tokens.fillHover)
                    : .clear
            )
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .opacity(exposesClose ? 1 : 0)
            .allowsHitTesting(exposesClose)
            .focused($isCloseFocused)
            .onHover { isCloseHovered = $0 }
            .accessibilityHidden(!exposesClose)
            .accessibilityLabel("Close tab \(tab.title)")
            .warrenSemanticElement(
                id: "tab.\(tab.id).close",
                role: .button,
                label: "Close tab \(tab.title)",
                isEnabled: exposesClose,
                action: onClose
            )
            .padding(.trailing, WarrenSpacing.xs)
        }
        .frame(width: WarrenLayoutMetrics.tabWidth, height: WarrenLayoutMetrics.tabBarHeight)
        .background(
            isSelected
                ? tokens.background
                : (isHovered ? tokens.tabInactiveHover : .clear)
        )
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .overlay {
            Rectangle()
                .stroke(isSelected ? tokens.border : .clear, lineWidth: isSelected ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            // Active tabs flow into pane content by covering the bar's bottom
            // border. Inactive tabs keep the unbroken 1px separator.
            Rectangle()
                .fill(isSelected ? tokens.background : tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
        .contentShape(.rect)
        .draggable(tab.id)
        .dropDestination(for: String.self) { tabIDs, _ in
            guard let sourceID = tabIDs.first else { return false }
            onMoveBefore(sourceID)
            return true
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if tab.sessionID != nil {
                Button("Close Tab", action: onClose)
                Button("Close Other Tabs", action: onCloseOthers)
                Button("Close All Tabs", action: onCloseAll)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(tab.title)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct WarrenDesktopTabAddSlot: View {
    let action: () -> Void
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .background(tokens.muted.opacity(0.30))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.small)
                    .stroke(tokens.border.opacity(0.60), lineWidth: WarrenSpacing.hairline)
            }
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel("New tab")
            .warrenSemanticElement(
                id: "tab.new",
                role: .button,
                label: "New tab",
                isEnabled: isEnabled,
                action: action
            )
        }
        .frame(width: WarrenLayoutMetrics.tabAddButtonSlotWidth, height: WarrenLayoutMetrics.tabBarHeight)
        .padding(.leading, WarrenSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab actions")
    }
}
