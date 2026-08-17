import SwiftUI

public enum WarrenMotionRole: Sendable {
    case feedback
    case stateChange
    case overlay
}

/// Motion policy shared by every Warren surface.
///
/// Geometry around native renderer hosts must switch without animation.
/// These roles are reserved for local feedback, content state, and overlays.
public enum WarrenMotion {
    public static let feedbackDuration: TimeInterval = 0.08
    public static let stateChangeDuration: TimeInterval = 0.14
    public static let overlayDuration: TimeInterval = 0.16
    public static let activityPulseDuration: TimeInterval = 1.2

    public static func animation(
        _ role: WarrenMotionRole,
        reduceMotion: Bool
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        let duration = switch role {
        case .feedback: feedbackDuration
        case .stateChange: stateChangeDuration
        case .overlay: overlayDuration
        }
        return .easeOut(duration: duration)
    }
}

/// A stable status dot with an optional compositor-driven activity ring.
/// The ring is inserted only while work is active, so static warning and
/// failure states do not keep an infinite animation alive.
public struct WarrenStatusIndicator: View {
    private let color: Color
    private let isActive: Bool
    private let size: CGFloat
    private let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        color: Color,
        isActive: Bool = false,
        size: CGFloat = 7,
        accessibilityLabel: String
    ) {
        self.color = color
        self.isActive = isActive
        self.size = size
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ZStack {
            if isActive, !reduceMotion {
                WarrenStatusPulseRing(color: color, size: size)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WarrenStatusPulseRing: View {
    let color: Color
    let size: CGFloat

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.65))
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.9 : 1)
            .opacity(expanded ? 0 : 0.75)
            .onAppear {
                withAnimation(
                    .easeOut(duration: WarrenMotion.activityPulseDuration)
                        .repeatForever(autoreverses: false)
                ) {
                    expanded = true
                }
            }
    }
}
