import AppKit
import SwiftUI
import GhosttyTerminal

/// Keeps one terminal surface mounted and gives it an independent focus intent.
///
/// A shared optional `FocusState` lets a hidden sibling's resign callback clear
/// the active terminal. A Boolean per surface avoids that cross-talk; AppKit's
/// first responder remains the source of truth for actual keyboard ownership.
public struct GhosttyManagedSurface: View {
    public let surface: GhosttySurface
    public let isActive: Bool
    public let focusDriver: GhosttyFocusDriver
    public let viewportSize: CGSize?
    public let onFocused: () -> Void
    public let onBlurred: () -> Void

    @FocusState private var surfaceFocused: Bool

    public init(
        surface: GhosttySurface,
        isActive: Bool,
        focusDriver: GhosttyFocusDriver,
        viewportSize: CGSize? = nil,
        onFocused: @escaping () -> Void = {},
        onBlurred: @escaping () -> Void = {}
    ) {
        self.surface = surface
        self.isActive = isActive
        self.focusDriver = focusDriver
        self.viewportSize = viewportSize
        self.onFocused = onFocused
        self.onBlurred = onBlurred
    }

    public var body: some View {
        surface.view
            .terminalFocused($surfaceFocused)
            .frame(
                width: viewportSize?.width,
                height: viewportSize?.height
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GhosttyWindowProbe(
                    state: surface.state,
                    focusDriver: focusDriver
                ) {
                    guard isActive else { return }
                    focusDriver.moveFocus(
                        to: surface.state,
                        replacingCurrentResponder: false,
                        canFocus: { isActive },
                        onFocused: onFocused
                    )
                }
            }
            .onAppear {
                guard isActive else { return }
                surfaceFocused = true
                requestSelectionFocus()
                requestImmediateDisplayRefresh()
            }
            .onChange(of: isActive, initial: true) { _, active in
                surfaceFocused = active
                if active {
                    requestSelectionFocus()
                    requestImmediateDisplayRefresh()
                    focusDriver.refreshLayout(
                        of: surface.state,
                        canRefresh: { isActive },
                        onRefreshed: {
                            surface.synchronizeViewport()
                            // The view has settled by the second refresh leg;
                            // re-claim focus so keystrokes land without a click.
                            focusDriver.moveFocus(
                                to: surface.state,
                                replacingCurrentResponder: true,
                                canFocus: { isActive },
                                onFocused: onFocused
                            )
                        }
                    )
                } else {
                    onBlurred()
                }
            }
            .onChange(of: surfaceFocused) { _, focused in
                if focused { onFocused() } else { onBlurred() }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification
                )
            ) { note in
                guard isActive,
                      let window = note.object as? NSWindow,
                      focusDriver.owns(surface.state, in: window) else { return }
                focusDriver.moveFocus(
                    to: surface.state,
                    replacingCurrentResponder: false,
                    canFocus: { isActive },
                    onFocused: onFocused
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didResignKeyNotification
                )
            ) { note in
                guard isActive,
                      let window = note.object as? NSWindow,
                      focusDriver.owns(surface.state, in: window) else { return }
                onBlurred()
            }
            .id(ObjectIdentifier(surface.state))
    }

    private func requestSelectionFocus() {
        focusDriver.moveFocus(
            to: surface.state,
            replacingCurrentResponder: true,
            canFocus: { isActive },
            onFocused: onFocused
        )
    }

    private func requestImmediateDisplayRefresh() {
        // Re-entering a shell (tab switch, settings dismissal) can recreate
        // the AppKit view while the renderer is still settling. Request a
        // renderer-thread frame immediately and once more after the runloop,
        // then force-present the settled grid so the first frame never waits
        // for a resize or keystroke.
        surface.refreshAfterReentry()
    }
}

/// Resolves a specific Ghostty view from its state and moves AppKit focus with
/// bounded exponential backoff. This is the same focus ownership model used by
/// Termio and Ghostty: selection may replace a responder, while render/window
/// repair only fills an orphaned responder slot.
@MainActor
public final class GhosttyFocusDriver {
    private enum Strength {
        case replaceResponder
        case repairOrphan
    }

    private weak var lastFocusedSurface: TerminalView?
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var replaceGeneration = 0
    private var repairGeneration = 0

    public init() {}

    public func register(_ state: TerminalViewState, in window: NSWindow) {
        windows[ObjectIdentifier(state)] = WeakWindow(window)
    }

    public func owns(_ state: TerminalViewState, in window: NSWindow) -> Bool {
        windows[ObjectIdentifier(state)]?.value === window
    }

    public func moveFocus(
        to state: TerminalViewState,
        replacingCurrentResponder: Bool,
        canFocus: @escaping () -> Bool,
        onFocused: @escaping () -> Void = {}
    ) {
        let strength: Strength = replacingCurrentResponder
            ? .replaceResponder
            : .repairOrphan
        let generation: Int
        switch strength {
        case .replaceResponder:
            replaceGeneration += 1
            generation = replaceGeneration
        case .repairOrphan:
            repairGeneration += 1
            generation = repairGeneration
        }
        scheduleMove(
            to: state,
            strength: strength,
            generation: generation,
            delay: 0,
            attemptsRemaining: 9,
            canFocus: canFocus,
            onFocused: onFocused
        )
    }

    /// Re-fit a mounted renderer after tab activation. Hidden surfaces keep
    /// their state, but only the newly active one owns PTY geometry.
    public func refreshLayout(
        of state: TerminalViewState,
        canRefresh: @escaping () -> Bool,
        onRefreshed: @escaping () -> Void = {}
    ) {
        for delay in [0.0, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
                guard let self, let state, canRefresh(),
                      let (_, target) = self.terminalView(matching: state) else { return }
                target.fitToSize()
                onRefreshed()
            }
        }
    }

    private func scheduleMove(
        to state: TerminalViewState,
        strength: Strength,
        generation: Int,
        delay: TimeInterval,
        attemptsRemaining: Int,
        canFocus: @escaping () -> Bool,
        onFocused: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self,
                  let state,
                  self.isCurrent(strength, generation: generation),
                  canFocus() else { return }

            guard let (window, target) = self.terminalView(matching: state) else {
                guard attemptsRemaining > 0 else { return }
                self.retryMove(
                    to: state,
                    strength: strength,
                    generation: generation,
                    after: delay,
                    attemptsRemaining: attemptsRemaining - 1,
                    canFocus: canFocus,
                    onFocused: onFocused
                )
                return
            }
            let current = window.firstResponder
            if current === target {
                self.lastFocusedSurface = target
                onFocused()
                return
            }
            if strength == .repairOrphan,
               current != nil,
               current !== window {
                return
            }

            let previous = (current as? TerminalView) ?? self.lastFocusedSurface
            if let previous, previous !== target {
                _ = previous.resignFirstResponder()
            }
            if window.makeFirstResponder(target), window.firstResponder === target {
                self.lastFocusedSurface = target
                onFocused()
            } else {
                guard attemptsRemaining > 0 else { return }
                self.retryMove(
                    to: state,
                    strength: strength,
                    generation: generation,
                    after: delay,
                    attemptsRemaining: attemptsRemaining - 1,
                    canFocus: canFocus,
                    onFocused: onFocused
                )
            }
        }
    }

    private func retryMove(
        to state: TerminalViewState,
        strength: Strength,
        generation: Int,
        after delay: TimeInterval,
        attemptsRemaining: Int,
        canFocus: @escaping () -> Bool,
        onFocused: @escaping () -> Void
    ) {
        let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
        scheduleMove(
            to: state,
            strength: strength,
            generation: generation,
            delay: nextDelay,
            attemptsRemaining: attemptsRemaining,
            canFocus: canFocus,
            onFocused: onFocused
        )
    }

    private func isCurrent(_ strength: Strength, generation: Int) -> Bool {
        switch strength {
        case .replaceResponder:
            generation == replaceGeneration
        case .repairOrphan:
            generation == repairGeneration
        }
    }

    private func terminalView(
        matching state: TerminalViewState
    ) -> (NSWindow, TerminalView)? {
        let key = ObjectIdentifier(state)
        let candidates = [windows[key]?.value, NSApp.keyWindow].compactMap { $0 }
        var visited: Set<ObjectIdentifier> = []
        for window in candidates {
            guard visited.insert(ObjectIdentifier(window)).inserted else { continue }
            guard let root = window.contentView,
                  let target = terminalView(matching: state, under: root),
                  target.window === window else { continue }
            return (window, target)
        }
        return nil
    }

    private func terminalView(
        matching state: TerminalViewState,
        under root: NSView
    ) -> TerminalView? {
        if let terminal = root as? TerminalView,
           let delegate = terminal.delegate as AnyObject?,
           delegate === state {
            return terminal
        }
        for child in root.subviews {
            if let match = terminalView(matching: state, under: child) {
                return match
            }
        }
        return nil
    }
}

private final class WeakWindow {
    weak var value: NSWindow?

    init(_ value: NSWindow) {
        self.value = value
    }
}

private struct GhosttyWindowProbe: NSViewRepresentable {
    let state: TerminalViewState
    let focusDriver: GhosttyFocusDriver
    let repair: () -> Void

    func makeNSView(context: Context) -> GhosttyWindowProbeView {
        let view = GhosttyWindowProbeView(frame: .zero)
        configure(view)
        DispatchQueue.main.async { [weak view] in view?.registerAndRepair() }
        return view
    }

    func updateNSView(_ view: GhosttyWindowProbeView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GhosttyWindowProbeView) {
        view.onWindowAvailable = { [weak state, weak focusDriver] window in
            guard let state, let focusDriver else { return }
            focusDriver.register(state, in: window)
            repair()
        }
    }
}

private final class GhosttyWindowProbeView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerAndRepair()
    }

    func registerAndRepair() {
        guard let window else { return }
        onWindowAvailable?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
