import AppKit
import DenTerminal
import DenUI

/// Configures the main application window chrome.
/// Selection and business state live elsewhere; this type only manages window appearance.
final class MainWindowController: NSWindowController {

    // MARK: - Init

    init(themeInfo: TerminalThemeInfo = .fallback) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 500)
        window.title = "Den"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DenTokens.Cocoa.background
        window.appearance = NSAppearance(named: themeInfo.isDark ? .darkAqua : .aqua)
        window.setFrameAutosaveName("DenMainWindow")
        if !window.setFrameUsingName("DenMainWindow") {
            window.center()
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    func updateTitle(projectName: String?, worktreeName: String? = nil) {
        var parts: [String] = []
        if let worktreeName { parts.append(worktreeName) }
        if let projectName { parts.append(projectName) }
        // Keep the most specific context first so branch/project are visible in Mission Control.
        parts.append("Den")
        window?.title = parts.joined(separator: " — ")
    }
}
