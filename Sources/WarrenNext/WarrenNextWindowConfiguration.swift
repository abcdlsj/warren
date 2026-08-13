import AppKit
import SwiftUI

/// Window values copied from Superset's Electron main window. Superset uses
/// the primary display work area on first launch and clamps both dimensions to
/// a 400pt minimum; the fallback only exists for SwiftUI's static Scene API.
enum WarrenNextWindowConfiguration {
    static let minimumSize = NSSize(width: 400, height: 400)
    static let fallbackDefaultSize = NSSize(width: 1280, height: 800)
    static let trafficLightOrigin = NSPoint(x: 16, y: 16)

    @MainActor
    static func defaultSize(for screen: NSScreen? = NSScreen.main) -> NSSize {
        screen?.visibleFrame.size ?? fallbackDefaultSize
    }

    @MainActor
    static func apply(to window: NSWindow) {
        window.minSize = minimumSize
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // A SwiftUI WindowGroup window still reserves a system titlebar strip
        // even with hiddenTitleBar. Remove the titled style so the content and
        // the 40pt chrome run edge-to-edge; Warren draws its own traffic lights
        // in the sidebar header, matching Superset's single-surface top.
        window.styleMask.remove(.titled)
        window.styleMask.insert(.borderless)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.closable)
        // Never make the whole content view a drag target.  The content view
        // contains the terminal, and AppKit's background-drag fallback wins
        // over a terminal drag as soon as the pointer leaves the first cell.
        // The standard titlebar remains movable; terminal mouseDown/
        // mouseDragged/mouseUp events stay owned by SwiftTerm.
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: 0x15 / 255,
            green: 0x11 / 255,
            blue: 0x10 / 255,
            alpha: 1
        )
        positionTrafficLights(in: window)

        if !window.isVisible {
            window.setContentSize(defaultSize(for: window.screen ?? NSScreen.main))
            window.center()
        }

        // This representable is attached only after WindowGroup has produced
        // a concrete window, so presenting here cannot race scene creation.
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    @MainActor
    private static func positionTrafficLights(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let buttonContainer = closeButton.superview else {
            return
        }

        let buttons: [(NSWindow.ButtonType, CGFloat)] = [
            (.closeButton, 0),
            (.miniaturizeButton, 20),
            (.zoomButton, 40),
        ]
        let y = buttonContainer.bounds.height - trafficLightOrigin.y - closeButton.frame.height
        for (buttonType, offset) in buttons {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            var frame = button.frame
            frame.origin = NSPoint(x: trafficLightOrigin.x + offset, y: y)
            button.frame = frame
        }
    }
}

struct WarrenNextWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WarrenNextWindowConfigurationView {
        WarrenNextWindowConfigurationView()
    }

    func updateNSView(_ nsView: WarrenNextWindowConfigurationView, context: Context) {
        nsView.applyIfNeeded()
    }
}

@MainActor
final class WarrenNextWindowConfigurationView: NSView {
    private weak var configuredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window
        WarrenNextWindowConfiguration.apply(to: window)
    }
}
