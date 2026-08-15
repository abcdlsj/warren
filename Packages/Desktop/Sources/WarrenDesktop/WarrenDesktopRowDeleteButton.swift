import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// Destructive row action shown on hover. It intentionally requires a
/// double-click (matching the row's double-click convention) so an accidental
/// click cannot begin a destructive confirmation flow.
struct WarrenDesktopRowDeleteButton: View {
    let label: String
    let onDelete: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.red.opacity(0.88))
                .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                       height: WarrenLayoutMetrics.sidebarActionButtonSize)
                .contentShape(.rect)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .focused($isFocused)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDelete))
        .accessibilityLabel(label)
        .help("Double-click to delete")
        .warrenSemanticElement(
            id: label,
            role: .button,
            label: label,
            action: onDelete
        )
    }
}
