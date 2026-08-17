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

/// Warren's single indeterminate loading mark: square particles orbit as one
/// compositor transform. Use it only where the user is actively waiting.
public struct WarrenParticleSpinner: View {
    private let size: CGFloat
    private let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 18, accessibilityLabel: String = "Loading") {
        self.size = size
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let color = WarrenColorTokens.resolved(for: colorScheme).highlight
        Group {
            if reduceMotion {
                WarrenParticleField(size: size, color: color)
            } else {
                WarrenSpinningParticleField(size: size, color: color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WarrenSpinningParticleField: View {
    let size: CGFloat
    let color: Color

    @State private var rotates = false

    var body: some View {
        WarrenParticleField(size: size, color: color)
            .rotationEffect(.degrees(rotates ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    rotates = true
                }
            }
    }
}

private struct WarrenParticleField: View {
    let size: CGFloat
    let color: Color

    private static let positions: [CGPoint] = [
        CGPoint(x: -1, y: -1), CGPoint(x: 0, y: -1),
        CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        CGPoint(x: -1, y: 1), CGPoint(x: -1, y: 0),
    ]

    var body: some View {
        let particleSize = max(2, size * 0.15)
        let radius = size * 0.34
        ZStack {
            ForEach(Array(Self.positions.enumerated()), id: \.offset) { index, point in
                RoundedRectangle(cornerRadius: particleSize * 0.34)
                    .fill(color.opacity(0.28 + Double(index) * 0.09))
                    .frame(width: particleSize, height: particleSize)
                    .offset(x: point.x * radius, y: point.y * radius)
            }
        }
    }
}
