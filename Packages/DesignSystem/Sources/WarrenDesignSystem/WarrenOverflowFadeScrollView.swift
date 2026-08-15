import SwiftUI

private struct WarrenOverflowFadeMetrics: Equatable {
    var frame: CGRect = .zero
}

private struct WarrenOverflowFadeMetricsKey: PreferenceKey {
    static let defaultValue = WarrenOverflowFadeMetrics()
    static func reduce(value: inout WarrenOverflowFadeMetrics, nextValue: () -> WarrenOverflowFadeMetrics) {
        value = nextValue()
    }
}

/// A scroll view that exposes only edge-overflow booleans to its overlays.
/// Geometry may be sampled continuously, but state changes are committed only
/// when an edge crosses the one-point visibility boundary.
public struct WarrenOverflowFadeScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let fadeLength: CGFloat
    private let surface: Color
    private let onHorizontalOverflowChange: ((Bool) -> Void)?
    private let content: () -> Content
    private let spaceName = UUID()

    @State private var canScrollTop = false
    @State private var canScrollBottom = false
    @State private var canScrollLeft = false
    @State private var canScrollRight = false
    @State private var hasOverflowX = false
    @State private var hasOverflowY = false

    public init(
        _ axes: Axis.Set = .vertical,
        fadeLength: CGFloat = 24,
        surface: Color,
        onHorizontalOverflowChange: ((Bool) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.axes = axes
        self.fadeLength = fadeLength
        self.surface = surface
        self.onHorizontalOverflowChange = onHorizontalOverflowChange
        self.content = content
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollView(axes, showsIndicators: false) {
                content()
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: WarrenOverflowFadeMetricsKey.self,
                                value: WarrenOverflowFadeMetrics(frame: contentGeometry.frame(in: .named(spaceName)))
                            )
                        }
                    }
            }
            .coordinateSpace(name: spaceName)
            .onPreferenceChange(WarrenOverflowFadeMetricsKey.self) { metrics in
                updateEdges(contentFrame: metrics.frame, viewport: viewport.size)
            }
            .overlay(alignment: .top) {
                if axes.contains(.vertical), canScrollTop {
                    fade(edge: .top)
                }
            }
            .overlay(alignment: .bottom) {
                if axes.contains(.vertical), canScrollBottom {
                    fade(edge: .bottom)
                }
            }
            .overlay(alignment: .leading) {
                if axes.contains(.horizontal), canScrollLeft {
                    fade(edge: .leading)
                }
            }
            .overlay(alignment: .trailing) {
                if axes.contains(.horizontal), canScrollRight {
                    fade(edge: .trailing)
                }
            }
        }
    }

    private enum Edge { case top, bottom, leading, trailing }

    @ViewBuilder
    private func fade(edge: Edge) -> some View {
        switch edge {
        case .top:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: fadeLength)
                .allowsHitTesting(false)
        case .bottom:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .bottom, endPoint: .top)
                .frame(height: fadeLength)
                .allowsHitTesting(false)
        case .leading:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeLength)
                .allowsHitTesting(false)
        case .trailing:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .trailing, endPoint: .leading)
                .frame(width: fadeLength)
                .allowsHitTesting(false)
        }
    }

    private func updateEdges(contentFrame: CGRect, viewport: CGSize) {
        let epsilon: CGFloat = 1
        let nextOverflowX = axes.contains(.horizontal)
            && contentFrame.width > viewport.width + epsilon
        let nextOverflowY = axes.contains(.vertical)
            && contentFrame.height > viewport.height + epsilon
        let nextTop = axes.contains(.vertical) && contentFrame.minY < -epsilon
        let nextBottom = axes.contains(.vertical) && contentFrame.maxY > viewport.height + epsilon
        let nextLeft = axes.contains(.horizontal) && contentFrame.minX < -epsilon
        let nextRight = axes.contains(.horizontal) && contentFrame.maxX > viewport.width + epsilon

        guard nextOverflowX != hasOverflowX || nextOverflowY != hasOverflowY
                || nextTop != canScrollTop || nextBottom != canScrollBottom
                || nextLeft != canScrollLeft || nextRight != canScrollRight else { return }
        hasOverflowX = nextOverflowX
        hasOverflowY = nextOverflowY
        canScrollTop = nextTop
        canScrollBottom = nextBottom
        canScrollLeft = nextLeft
        canScrollRight = nextRight
        onHorizontalOverflowChange?(hasOverflowX)
    }
}
