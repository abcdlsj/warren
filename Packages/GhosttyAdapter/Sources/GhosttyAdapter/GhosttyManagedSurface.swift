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
                    surface: surface,
                    focusDriver: focusDriver,
                    hidden: !isActive
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
        // Re-entering a shell (tab switch, worktree switch, settings
        // dismissal) can recreate the AppKit view while the renderer is
        // still settling. Poll cheaply until the view mounts (no render tick
        // while unmounted), then a few delayed draws cover content that
        // arrives after the mount. Frame-rate drawing for seconds starves the
        // main actor and hangs the desktop.
        TerminalDiagnostics.log("managed_present_start", [
            "session": surface.id.description,
            "active": isActive ? "true" : "false",
        ])
        surface.requestDisplayRefresh()
        DispatchQueue.main.async { [weak surface] in
            surface?.requestDisplayRefresh()
        }
        Task { @MainActor [weak surface] in
            guard let surface else { return }
            var drewOnce = false
            for attempt in 0..<60 {
                let drew = surface.presentNow()
                if drew {
                    drewOnce = true
                }
                TerminalDiagnostics.logVerbose("managed_present_attempt", [
                    "session": surface.id.description,
                    "attempt": String(attempt),
                    "drew": drew ? "true" : "false",
                ])
                if drew {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            TerminalDiagnostics.log("managed_present_poll_done", [
                "session": surface.id.description,
                "success": drewOnce ? "true" : "false",
            ])
            for delay in [0.1, 0.25, 0.5] {
                try? await Task.sleep(for: .seconds(delay))
                surface.requestDisplayRefresh()
                let drew = surface.presentNow()
                if drew {
                    TerminalDiagnostics.logVerbose("managed_present_delayed", [
                        "session": surface.id.description,
                        "delay": String(delay),
                        "drew": "true",
                    ])
                } else {
                    TerminalDiagnostics.log("managed_present_delayed", [
                        "session": surface.id.description,
                        "delay": String(delay),
                        "drew": "false",
                    ])
                }
            }
        }
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

    /// Fits and presents a terminal view a few times after it mounts. The
    /// activation/attach polls handle late mounts; repeating fitToSize at
    /// frame rate would churn layout and starve the main actor.
    public func fitAndPresent(
        of state: TerminalViewState,
        present: @escaping () -> Void
    ) {
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self, weak state] in
                guard let self, let state else {
                    TerminalDiagnostics.log("fit_present_miss", [
                        "delay": String(format: "%.2f", delay),
                        "reason": "state-gone",
                    ])
                    return
                }
                let match = self.terminalView(matching: state)
                let found = match != nil
                let window = match.map { String($0.0.windowNumber) } ?? "nil"
                let bounds = match.map {
                    GhosttyDiagnosticsFormat.finiteSize($0.1.bounds.size)
                } ?? "nil"
                let hidden = match.map { $0.1.isHidden ? "true" : "false" } ?? "nil"
                if found {
                    TerminalDiagnostics.logVerbose("fit_present", [
                        "delay": String(format: "%.2f", delay),
                        "found": "true",
                        "window": window,
                        "bounds": bounds,
                        "hidden": hidden,
                    ])
                } else {
                    TerminalDiagnostics.log("fit_present_miss", [
                        "delay": String(format: "%.2f", delay),
                        "reason": "no-terminal-view",
                    ])
                }
                guard let (_, target) = match else { return }
                target.fitToSize()
                present()
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
    let surface: GhosttySurface
    let focusDriver: GhosttyFocusDriver
    let hidden: Bool
    let repair: () -> Void

    func makeNSView(context: Context) -> GhosttyWindowProbeView {
        let view = GhosttyWindowProbeView(frame: .zero)
        configure(view)
        view.shouldHide = hidden
        view.applyHidden()
        DispatchQueue.main.async { [weak view] in view?.registerAndRepair() }
        return view
    }

    func updateNSView(_ view: GhosttyWindowProbeView, context: Context) {
        configure(view)
        view.shouldHide = hidden
        view.applyHidden()
    }

    private func configure(_ view: GhosttyWindowProbeView) {
        view.onWindowAvailable = { [weak state, weak focusDriver, weak surface] window in
            guard let state, let focusDriver, let surface else { return }
            TerminalDiagnostics.log("probe_window_available", [
                "session": surface.id.description,
                "window": String(window.windowNumber),
                "bounds": GhosttyDiagnosticsFormat.finiteSize(window.frame.size),
            ])
            focusDriver.register(state, in: window)
            repair()
            // The terminal view just mounted (or was recreated by a worktree
            // or tab switch). Fit and draw it immediately, then again after
            // layout settles; the activation/attach polls cover late mounts.
            focusDriver.fitAndPresent(of: state) {
                surface.requestDisplayRefresh()
                _ = surface.presentNow()
            }
        }
        view.onApplyHidden = { [weak view, weak state] hidden in
            guard let view,
                  let state,
                  let window = view.window,
                  let root = window.contentView,
                  let terminal = Self.terminalView(matching: state, under: root) else {
                TerminalDiagnostics.log("probe_apply_hidden", [
                    "hidden": hidden ? "true" : "false",
                    "found": "false",
                ])
                return
            }
            terminal.isHidden = hidden
            TerminalDiagnostics.log("probe_apply_hidden", [
                "hidden": hidden ? "true" : "false",
                "found": "true",
            ])
        }
    }

    private static func terminalView(
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

enum GhosttyDiagnosticsFormat {
    static func finiteSize(_ size: CGSize) -> String {
        "\(finitePart(size.width))x\(finitePart(size.height))"
    }

    private static func finitePart(_ value: CGFloat) -> String {
        guard value.isFinite else { return "inf" }
        if value > 1_000_000 { return ">1M" }
        if value < -1_000_000 { return "<-1M" }
        return String(Int(value))
    }
}

private final class GhosttyWindowProbeView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?
    var onApplyHidden: ((Bool) -> Void)?
    var shouldHide = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TerminalDiagnostics.log("probe_window_move", [
            "attached": window != nil ? "true" : "false",
            "window": window.map { String($0.windowNumber) } ?? "nil",
            "hidden": shouldHide ? "true" : "false",
            "bounds": GhosttyDiagnosticsFormat.finiteSize(bounds.size),
            "visible": GhosttyDiagnosticsFormat.finiteSize(visibleRect.size),
        ])
        registerAndRepair()
    }

    func registerAndRepair() {
        guard let window else { return }
        onWindowAvailable?(window)
        applyHidden()
    }

    func applyHidden() {
        onApplyHidden?(shouldHide)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
