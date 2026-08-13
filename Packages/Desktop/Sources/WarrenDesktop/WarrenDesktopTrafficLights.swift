import AppKit
import SwiftUI

/// Superset's macOS traffic lights are drawn by the system into the sidebar
/// header. Warren runs a borderless window so the top chrome is one seamless
/// surface, which means the lights are rendered here instead.
struct WarrenDesktopTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            trafficLight(color: .red) {
                targetWindow?.performClose(nil)
            }
            trafficLight(color: .yellow) {
                targetWindow?.miniaturize(nil)
            }
            trafficLight(color: .green) {
                targetWindow?.performZoom(nil)
            }
        }
        .padding(.leading, 16)
        .accessibilityElement(children: .contain)
    }

    /// Clicking a SwiftUI control can temporarily clear `keyWindow` for a
    /// borderless window. Resolve the actual visible Warren window instead of
    /// silently dropping the traffic-light action.
    private var targetWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.closable) }
    }

    private func trafficLight(
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    Circle()
                        .stroke(.black.opacity(0.12), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color == .red ? "Close" : color == .yellow ? "Minimize" : "Zoom")
    }
}
