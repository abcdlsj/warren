import AppKit
import DenTerminal

/// Owns a detached terminal window for a cloned tmux session group.
@MainActor
final class PopoutTerminalWindowController: NSWindowController, NSWindowDelegate {

    let surface: NSView
    let sessionName: String
    private let terminalHost: TerminalHost

    var onClose: (() -> Void)?

    init(surface: NSView, sessionName: String, terminalHost: TerminalHost, themeInfo: TerminalThemeInfo) {
        self.surface = surface
        self.sessionName = sessionName
        self.terminalHost = terminalHost

        // Use a real window so the detached terminal can be focused and resized like a normal terminal app.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = sessionName
        window.backgroundColor = themeInfo.background
        window.minSize = NSSize(width: 400, height: 300)
        window.center()

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = themeInfo.background.cgColor

        let titleBar = NSView()
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1).cgColor
        titleBar.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: sessionName)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor(srgbRed: 0xd3 / 255.0, green: 0xd7 / 255.0, blue: 0xcf / 255.0, alpha: 0.8)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleBar.addSubview(titleLabel)

        container.addSubview(titleBar)

        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: container.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -12),

            surface.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 2),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        window.contentView = container

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowDidResize(_ notification: Notification) {
        guard let contentView = window?.contentView else { return }
        terminalHost.surfaceDidResize(surface, to: contentView.bounds.size)
    }

    func windowWillClose(_ notification: Notification) {
        // Higher-level cleanup (AppState + tmux clone teardown) is handled by AppDelegate.
        onClose?()
    }

    func focusTerminal() {
        terminalHost.focusSurface(surface)
    }
}
