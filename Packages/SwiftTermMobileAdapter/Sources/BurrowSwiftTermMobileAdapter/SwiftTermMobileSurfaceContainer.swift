#if os(iOS)
import SwiftUI
import UIKit
import BurrowTerminalRenderer
@preconcurrency import SwiftTerm

/// Stable UIKit host for a renderer-owned remote TerminalView.
@MainActor
public final class SwiftTermMobileSurfaceContainer: UIView {
    private var child: TerminalView?
    private var childConstraints: [NSLayoutConstraint] = []
    private weak var renderer: SwiftTermMobileRenderer?
    private var surface: TerminalSurface?
    private var wantsFocus = false

    public var attachedTerminalView: TerminalView? { child }

    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        clipsToBounds = true
    }

    func apply(renderer: SwiftTermMobileRenderer, surface: TerminalSurface, focused: Bool) {
        guard let terminal = renderer.view(for: surface) else {
            detach()
            return
        }
        if child !== terminal {
            detachChild()
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            childConstraints = [
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            NSLayoutConstraint.activate(childConstraints)
            child = terminal
        }
        self.renderer = renderer
        self.surface = surface
        self.wantsFocus = focused
        renderer.updateSurface(surface, view: terminal, focused: focused)
    }

    func detach() {
        detachChild()
        renderer = nil
        surface = nil
        wantsFocus = false
    }

    private func detachChild() {
        if let renderer, let surface, let child {
            renderer.updateSurface(surface, view: child, focused: false)
        }
        _ = child?.resignFirstResponder()
        NSLayoutConstraint.deactivate(childConstraints)
        childConstraints.removeAll()
        child?.removeFromSuperview()
        child = nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let renderer, let surface else { return }
        renderer.attach(surface: surface, to: self, focused: wantsFocus)
    }
}

/// SwiftUI wrapper whose dismantling only detaches UIKit views. Session
/// disposal is explicit and remains owned by the renderer/client coordinator.
@MainActor
public struct SwiftTermMobileView: UIViewRepresentable {
    public let renderer: SwiftTermMobileRenderer
    public let surface: TerminalSurface
    public var focused: Bool

    public init(renderer: SwiftTermMobileRenderer, surface: TerminalSurface, focused: Bool = false) {
        self.renderer = renderer
        self.surface = surface
        self.focused = focused
    }

    public func makeUIView(context: Context) -> SwiftTermMobileSurfaceContainer {
        let container = SwiftTermMobileSurfaceContainer()
        renderer.attach(surface: surface, to: container, focused: focused)
        return container
    }

    public func updateUIView(_ uiView: SwiftTermMobileSurfaceContainer, context: Context) {
        renderer.attach(surface: surface, to: uiView, focused: focused)
    }

    public static func dismantleUIView(_ uiView: SwiftTermMobileSurfaceContainer, coordinator: ()) {
        uiView.detach()
    }
}
#endif
