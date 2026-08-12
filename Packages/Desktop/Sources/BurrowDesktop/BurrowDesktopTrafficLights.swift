import AppKit
import SwiftUI

/// Superset's macOS traffic lights are drawn by the system into the sidebar
/// header. Burrow runs a borderless window so the top chrome is one seamless
/// surface, which means the lights are rendered here instead.
struct BurrowDesktopTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            trafficLight(color: .red) {
                NSApp.keyWindow?.performClose(nil)
            }
            trafficLight(color: .yellow) {
                NSApp.keyWindow?.miniaturize(nil)
            }
            trafficLight(color: .green) {
                NSApp.keyWindow?.performZoom(nil)
            }
        }
        .padding(.leading, 16)
        .accessibilityElement(children: .contain)
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
