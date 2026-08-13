import AppKit
import SwiftUI
import WarrenTerminalRenderer
@preconcurrency import SwiftTerm

/// Stable SwiftUI-owned host. The renderer owns the TerminalView; this host
/// only attaches or detaches it with constraints and never sets its geometry.
@MainActor
public final class SwiftTermSurfaceContainer: NSView {
    private var child: TerminalView?
    private var childConstraints: [NSLayoutConstraint] = []
    private var focusRecognizer: NSClickGestureRecognizer?
    private weak var renderer: SwiftTermRenderer?
    private var surface: TerminalSurface?
    private var focused = false

    public var attachedTerminalView: TerminalView? { child }

    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func apply(renderer: SwiftTermRenderer, surface: TerminalSurface, focused: Bool) {
        guard let terminal = renderer.view(for: surface) else {
            detach()
            return
        }
        let attachedNewChild = child !== terminal
        if attachedNewChild {
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
            installFocusRecognizer(on: terminal)
        }
        self.renderer = renderer
        self.surface = surface
        self.focused = focused
        renderer.updateSurface(
            surface,
            view: terminal,
            focused: focused,
            requestFocus: attachedNewChild && terminal.window != nil
        )
    }

    func detach() {
        detachChild()
        renderer = nil
        surface = nil
        focused = false
    }

    private func detachChild() {
        if let renderer, let surface, let child {
            renderer.updateSurface(surface, view: child, focused: false)
        }
        NSLayoutConstraint.deactivate(childConstraints)
        childConstraints.removeAll()
        if let focusRecognizer {
            child?.removeGestureRecognizer(focusRecognizer)
            self.focusRecognizer = nil
        }
        child?.removeFromSuperview()
        child = nil
    }

    private func installFocusRecognizer(on terminal: TerminalView) {
        let recognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(terminalClicked(_:))
        )
        // Keep SwiftTerm's selection and mouse-reporting path intact. The
        // recognizer only repairs AppKit first-responder ownership.
        recognizer.delaysPrimaryMouseButtonEvents = false
        terminal.addGestureRecognizer(recognizer)
        focusRecognizer = recognizer
    }

    @objc private func terminalClicked(_ recognizer: NSClickGestureRecognizer) {
        focusTerminal()
    }

    @discardableResult
    func focusTerminal() -> Bool {
        guard let child else { return false }
        return window?.makeFirstResponder(child) ?? false
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let renderer, let surface, let child else { return }
        renderer.updateSurface(
            surface,
            view: child,
            focused: focused,
            requestFocus: focused
        )
    }
}

/// SwiftUI wrapper for one renderer-owned remote terminal surface.
@MainActor
public struct SwiftTermView: NSViewRepresentable {
    public let renderer: SwiftTermRenderer
    public let surface: TerminalSurface
    public var focused: Bool

    public init(renderer: SwiftTermRenderer, surface: TerminalSurface, focused: Bool = false) {
        self.renderer = renderer
        self.surface = surface
        self.focused = focused
    }

    public func makeNSView(context: Context) -> SwiftTermSurfaceContainer {
        let container = SwiftTermSurfaceContainer()
        renderer.attach(surface: surface, to: container, focused: focused)
        return container
    }

    public func updateNSView(_ nsView: SwiftTermSurfaceContainer, context: Context) {
        renderer.attach(surface: surface, to: nsView, focused: focused)
    }

    public static func dismantleNSView(_ nsView: SwiftTermSurfaceContainer, coordinator: ()) {
        nsView.detach()
    }
}
