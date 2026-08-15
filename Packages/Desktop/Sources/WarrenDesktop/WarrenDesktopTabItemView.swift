import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenObservation

struct WarrenDesktopTabItem: View {
    let tab: ClientTab
    let displayTitle: String
    let isSelected: Bool
    let isPinned: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let onMoveBefore: (String) -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTabFocused: Bool
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
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }
                    Text(displayTitle)
                        .font(WarrenTypography.tabShellTitle)
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
            .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isTabFocused, cornerRadius: 0))
            .focused($isTabFocused)
            .disabled(tab.sessionID == nil)
            .foregroundStyle(
                isSelected
                    ? tokens.foreground.opacity(0.90)
                    : tokens.mutedForeground
            )
            .accessibilityLabel("Tab \(displayTitle)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .warrenSemanticElement(
                id: "tab.\(tab.id)",
                role: .tab,
                label: "Tab \(displayTitle)",
                value: isSelected ? "Selected" : "Not selected",
                isSelected: isSelected,
                action: onSelect
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isCloseFocused))
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
            .accessibilityLabel("Close tab \(displayTitle)")
            .warrenSemanticElement(
                id: "tab.\(tab.id).close",
                role: .button,
                label: "Close tab \(displayTitle)",
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isSelected)
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
                Button(isPinned ? "Unpin Session" : "Pin Session", action: onTogglePin)
                Button("Rename Session", action: onRename)
                Button("Close Tab", action: onClose)
                Button("Close Other Tabs", action: onCloseOthers)
                Button("Close All Tabs", action: onCloseAll)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(displayTitle)")
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
