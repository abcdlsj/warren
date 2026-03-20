import AppKit
import DenTerminal
import DenUI

/// Owns the embedded terminal surface and the small AppKit chrome above it.
/// Session selection comes from WorkspaceManager; this controller only renders that selection.
@MainActor
final class TerminalAreaViewController: NSViewController {

    // MARK: - Dependencies

    let terminalHost: TerminalHost
    private let surfaceCache: TerminalSurfaceCache

    // MARK: - State

    private var currentSessionName: String?
    private var currentWorkingDirectory: String?
    private var currentProjectName: String?
    private var currentWorktreeName: String?

    private var currentSurface: NSView?
    private var emptyStateView: NSView?

    private var tabsBarView: NSView?
    private var toolsBarView: NSView?
    private var pathBarView: NSView?

    private var sessionPillLabel: NSTextField?
    private var projectPillLabel: NSTextField?
    private var connectionLabel: NSTextField?
    private var pathLabel: NSTextField?
    private var createTabButton: NSButton?
    private var popOutButton: NSButton?

    var onCreateSession: (() -> Void)?
    var onCreateTab: (() -> Void)?
    var onPopOutSession: (() -> Void)?
    var hasSelectedWorktree: Bool = false

    // MARK: - Init

    init(terminalHost: TerminalHost? = nil) {
        let host = terminalHost ?? SwiftTermAdapter()
        self.terminalHost = host
        self.surfaceCache = TerminalSurfaceCache(maxSize: 3, terminalHost: host)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Theme

    var themeInfo: TerminalThemeInfo {
        (terminalHost as? SwiftTermAdapter)?.themeInfo ?? .fallback
    }

    // MARK: - Lifecycle

    private static let tabsBarHeight: CGFloat = 36
    private static let toolsBarHeight: CGFloat = 30
    private static let pathBarHeight: CGFloat = 26

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DenTokens.Cocoa.background.cgColor
        self.view = container

        setupChrome()
        refreshChrome()
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
            // Re-selecting the same session only refreshes metadata and keyboard focus.
            currentWorkingDirectory = workingDirectory
            refreshChrome()
            focusCurrentSurface()
            return
        }

        hideEmptyState()

        if let oldSurface = currentSurface {
            oldSurface.removeFromSuperview()
        }

        let escaped = shellEscape(sessionName)
        let command = "tmux new-session -A -s \(escaped)"
        let surface = surfaceCache.surface(
            forSession: sessionName,
            command: command,
            workingDirectory: workingDirectory
        )

        // A zero-sized surface usually means terminal initialization failed before layout completed.
        guard surface.frame.size != .zero || view.bounds.size != .zero else {
            showError("Failed to create terminal surface for session '\(sessionName)'.")
            return
        }

        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        let topAnchor = pathBarView?.bottomAnchor ?? view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        currentSessionName = sessionName
        currentWorkingDirectory = workingDirectory
        currentSurface = surface

        refreshChrome()
        terminalHost.surfaceDidResize(surface, to: view.bounds.size)
        focusCurrentSurface()
    }

    func detach() {
        if let session = currentSessionName {
            // The embedded terminal should not keep stale views/processes alive after detach.
            surfaceCache.remove(sessionName: session)
        }
        currentSurface?.removeFromSuperview()
        currentSurface = nil
        currentSessionName = nil
        currentWorkingDirectory = nil
        refreshChrome()
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

    func createStandaloneSurface(sessionName: String, workingDirectory: String) -> NSView {
        let escaped = shellEscape(sessionName)
        let command = "tmux new-session -A -s \(escaped)"
        // Popout windows bypass the cache because they own their own surface lifetime.
        return terminalHost.createSurface(
            command: command,
            workingDirectory: workingDirectory
        )
    }

    // MARK: - Chrome

    private func setupChrome() {
        // AppKit chrome keeps terminal embedding/resizing predictable inside the split view.
        let tabs = makeBarView(color: DenTokens.Cocoa.panel)
        let tools = makeBarView(color: DenTokens.Cocoa.panelRaised)
        let path = makeBarView(color: DenTokens.Cocoa.panel)

        view.addSubview(tabs)
        view.addSubview(tools)
        view.addSubview(path)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: Self.tabsBarHeight),

            tools.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            tools.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tools.heightAnchor.constraint(equalToConstant: Self.toolsBarHeight),

            path.topAnchor.constraint(equalTo: tools.bottomAnchor),
            path.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            path.heightAnchor.constraint(equalToConstant: Self.pathBarHeight),
        ])

        setupTabsContent(in: tabs)
        setupToolsContent(in: tools)
        setupPathContent(in: path)

        tabsBarView = tabs
        toolsBarView = tools
        pathBarView = path
    }

    private func setupTabsContent(in bar: NSView) {
        let sessionPill = makeStatusPill(systemName: "terminal")
        sessionPillLabel = sessionPill.label

        let projectPill = makeStatusPill(systemName: "folder")
        projectPillLabel = projectPill.label

        let stack = NSStackView(views: [sessionPill.view, projectPill.view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let connection = NSTextField(labelWithString: "Idle")
        connection.font = .systemFont(ofSize: 11, weight: .semibold)
        connection.textColor = DenTokens.Cocoa.subtext
        connection.alignment = .center
        connection.wantsLayer = true
        connection.layer?.backgroundColor = DenTokens.Cocoa.panelMuted.cgColor
        connection.layer?.cornerRadius = 7
        connection.translatesAutoresizingMaskIntoConstraints = false
        connectionLabel = connection

        bar.addSubview(stack)
        bar.addSubview(connection)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            connection.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            connection.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            connection.heightAnchor.constraint(equalToConstant: 22),
            connection.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
    }

    private func setupToolsContent(in bar: NSView) {
        let hint = NSTextField(labelWithString: "⌘1-9 windows   Ctrl+Tab worktrees")
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = DenTokens.Cocoa.subtext
        hint.translatesAutoresizingMaskIntoConstraints = false

        let newTab = makeToolbarButton(title: "New Tab", systemName: "plus", action: #selector(createTabButtonClicked))
        let popOut = makeToolbarButton(title: "Pop Out", systemName: "arrow.up.right.square", action: #selector(popOutButtonClicked))
        createTabButton = newTab
        popOutButton = popOut

        let actionStack = NSStackView(views: [newTab, popOut])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(hint)
        bar.addSubview(actionStack)

        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            actionStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            actionStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func setupPathContent(in bar: NSView) {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = DenTokens.Cocoa.subtext
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
        ])

        pathLabel = label
    }

    private func makeBarView(color: NSColor) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = color.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = DenTokens.Cocoa.border.cgColor
        return bar
    }

    private func makeStatusPill(systemName: String) -> (view: NSView, label: NSTextField) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DenTokens.Cocoa.panelRaised.cgColor
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = DenTokens.Cocoa.border.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.contentTintColor = DenTokens.Cocoa.subtext
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = DenTokens.Cocoa.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 24),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return (container, label)
    }

    private func makeToolbarButton(title: String, systemName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = DenTokens.Cocoa.text
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.wantsLayer = true
        button.layer?.backgroundColor = DenTokens.Cocoa.panelRaised.cgColor
        button.layer?.cornerRadius = 7
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = DenTokens.Cocoa.border.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: title == "New Tab" ? 78 : 82).isActive = true
        return button
    }

    func updateTitleBar(projectName: String?, worktreeName: String?) {
        currentProjectName = projectName
        currentWorktreeName = worktreeName
        refreshChrome()
    }

    private func refreshChrome() {
        let hasSession = currentSessionName != nil
        sessionPillLabel?.stringValue = currentSessionName ?? "No Session"
        projectPillLabel?.stringValue = currentProjectName ?? "No Repository"
        connectionLabel?.stringValue = hasSession ? "Live" : "Idle"
        connectionLabel?.textColor = hasSession ? DenTokens.Cocoa.accent : DenTokens.Cocoa.subtext
        connectionLabel?.layer?.backgroundColor = hasSession
            ? DenTokens.Cocoa.accentWeak.cgColor
            : DenTokens.Cocoa.panelRaised.cgColor
        popOutButton?.isEnabled = hasSession
        popOutButton?.alphaValue = hasSession ? 1.0 : 0.45

        var line = compactPath(currentWorkingDirectory)
        if let worktree = currentWorktreeName, !worktree.isEmpty {
            // Show branch/worktree name before the path, similar to a terminal prompt.
            line = "\(worktree) - \(line)"
        }
        pathLabel?.stringValue = line
    }

    private func compactPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "No active session" }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Empty State

    private func showEmptyState() {
        guard emptyStateView == nil else { return }

        // This doubles as a recovery prompt when a session has exited for the selected worktree.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DenTokens.Cocoa.panelRaised.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = DenTokens.Cocoa.border.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .thin)
        icon.contentTintColor = DenTokens.Cocoa.accent

        let label = NSTextField(labelWithString: hasSelectedWorktree ? "Session ended" : "No active session")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = DenTokens.Cocoa.text
        label.alignment = .center

        let subtitleText = hasSelectedWorktree
            ? "The terminal session has exited"
            : "Select a worktree or add a project to get started"
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = DenTokens.Cocoa.subtext
        subtitle.alignment = .center

        let buttonTitle = hasSelectedWorktree ? "Reconnect" : "Add Project..."
        let button = NSButton(title: buttonTitle, target: self, action: #selector(emptyStateButtonClicked))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = DenTokens.Cocoa.text
        button.wantsLayer = true
        button.layer?.backgroundColor = DenTokens.Cocoa.accentWeak.cgColor
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = DenTokens.Cocoa.accent.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false

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
            button.heightAnchor.constraint(equalToConstant: 32),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])

        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 26),
            container.widthAnchor.constraint(equalToConstant: 320),
            container.heightAnchor.constraint(equalToConstant: 180),
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

    @objc private func createTabButtonClicked() {
        onCreateTab?()
    }

    @objc private func popOutButtonClicked() {
        onPopOutSession?()
    }

    // MARK: - Helpers

    private func shellEscape(_ str: String) -> String {
        // Session names and paths may contain spaces or quotes, so the shell handoff must be escaped.
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
