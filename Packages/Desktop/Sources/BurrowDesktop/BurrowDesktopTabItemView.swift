import SwiftUI
import BurrowClientCore
import BurrowDesignSystem

struct BurrowDesktopTabItem: View {
    let tab: ClientTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.burrowForceHover) private var forceHover
    @FocusState private var isCloseFocused: Bool
    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var exposesClose: Bool {
        isHovered || isCloseFocused || forceHover
    }

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: BurrowSpacing.small) {
                    Text(tab.title)
                        .font(isSelected ? BurrowTypography.activeTabTitle : BurrowTypography.tabTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, BurrowSpacing.medium)
                .padding(.trailing, BurrowLayoutMetrics.tabAccessoryColumnWidth)
                .frame(
                    width: BurrowLayoutMetrics.tabWidth,
                    height: BurrowLayoutMetrics.tabBarHeight,
                    alignment: .leading
                )
                .background(Color.clear)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
            .accessibilityLabel("Tab \(tab.title)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .frame(
                width: BurrowLayoutMetrics.tabCloseButtonSize,
                height: BurrowLayoutMetrics.tabCloseButtonSize
            )
            .contentShape(.rect)
            .background(
                isCloseHovered
                    ? (isSelected ? tokens.muted.opacity(0.65) : tokens.fillHover)
                    : .clear
            )
            .clipShape(.rect(cornerRadius: BurrowRadius.small))
            .opacity(exposesClose ? 1 : 0)
            .allowsHitTesting(exposesClose)
            .focused($isCloseFocused)
            .onHover { isCloseHovered = $0 }
            .accessibilityHidden(!exposesClose)
            .accessibilityLabel("Close tab \(tab.title)")
            .padding(.trailing, BurrowSpacing.xs)
        }
        .frame(width: BurrowLayoutMetrics.tabWidth, height: BurrowLayoutMetrics.tabBarHeight)
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
                .frame(height: BurrowSpacing.hairline)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Tab", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
            Button("Close All Tabs", action: onCloseAll)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(tab.title)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct BurrowDesktopTabAddSlot: View {
    let action: () -> Void
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = BurrowColorTokens.resolved(for: colorScheme)
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
                RoundedRectangle(cornerRadius: BurrowRadius.small)
                    .stroke(tokens.border.opacity(0.60), lineWidth: BurrowSpacing.hairline)
            }
            .clipShape(.rect(cornerRadius: BurrowRadius.small))
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel("New tab")
        }
        .frame(width: BurrowLayoutMetrics.tabAddButtonSlotWidth, height: BurrowLayoutMetrics.tabBarHeight)
        .padding(.leading, BurrowSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab actions")
    }
}
