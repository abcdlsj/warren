import AppKit
import DenTerminal

@MainActor
final class TerminalAreaViewController: NSViewController {

    // MARK: - Dependencies

    let terminalHost: TerminalHost
    private let surfaceCache: TerminalSurfaceCache

    // MARK: - State

    private var currentSessionName: String?
    private var currentSurface: NSView?
    private var emptyStateView: NSView?

    var onCreateSession: (() -> Void)?

    var hasSelectedWorktree: Bool = false

    // MARK: - Init

    init(terminalHost: TerminalHost? = nil) {
        let host = terminalHost ?? GhosttyAdapter()
        self.terminalHost = host
        self.surfaceCache = TerminalSurfaceCache(maxSize: 3, terminalHost: host)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Theme

    var themeInfo: GhosttyThemeInfo {
        (terminalHost as? GhosttyAdapter)?.themeInfo ?? .fallback
    }

    func reloadConfig() {
        (terminalHost as? GhosttyAdapter)?.reloadConfig()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = themeInfo.background.cgColor
        self.view = container
        showEmptyState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let surface = currentSurface {
            terminalHost.surfaceDidResize(surface, to: view.bounds.size)
        }
    }

    // MARK: - Public API

    func attachToSession(sessionName: String, workingDirectory: String) {
        if sessionName == currentSessionName {
            focusCurrentSurface()
            return
        }

        hideEmptyState()

        if let oldSurface = currentSurface {
            oldSurface.removeFromSuperview()
        }

        let escaped = shellEscape(sessionName)
        let command = "tmux has-session -t \(escaped) 2>/dev/null && tmux attach-session -t \(escaped) || tmux new-session -s \(escaped)"
        let surface = surfaceCache.surface(
            forSession: sessionName,
            command: command,
            workingDirectory: workingDirectory
        )

        guard surface.frame.size != .zero || view.bounds.size != .zero else {
            showError("Failed to create terminal surface for session '\(sessionName)'.")
            return
        }

        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        currentSessionName = sessionName
        currentSurface = surface

        terminalHost.surfaceDidResize(surface, to: view.bounds.size)
        focusCurrentSurface()
    }

    func detach() {
        if let session = currentSessionName {
            surfaceCache.remove(sessionName: session)
        }
        currentSurface?.removeFromSuperview()
        currentSurface = nil
        currentSessionName = nil
        showEmptyState()
    }

    func focusCurrentSurface() {
        guard let surface = currentSurface else { return }
        terminalHost.focusSurface(surface)
    }

    func removeAllSurfaces() {
        detach()
        surfaceCache.removeAll()
    }

    // MARK: - Empty State

    private func showEmptyState() {
        guard emptyStateView == nil else { return }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .thin)
        icon.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(labelWithString: hasSelectedWorktree ? "Session ended" : "No active session")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let subtitleText = hasSelectedWorktree
            ? "The terminal session has exited"
            : "Select a worktree or add a project to get started"
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.alignment = .center

        let buttonTitle = hasSelectedWorktree ? "Reconnect" : "Add Project..."
        let button = NSButton(title: buttonTitle, target: self, action: #selector(emptyStateButtonClicked))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large

        container.addSubview(icon)
        container.addSubview(label)
        container.addSubview(subtitle)
        container.addSubview(button)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -12),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -16),

            subtitle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),

            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
        ])

        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        emptyStateView = container
    }

    private func hideEmptyState() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
    }

    @objc private func emptyStateButtonClicked() {
        onCreateSession?()
    }

    // MARK: - Helpers

    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func showError(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Terminal Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
