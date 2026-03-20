import AppKit
import DenCore
import DenGit
import DenPersistence
import DenTerminal
import DenTmux
import DenUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var workspaceManager: WorkspaceManager?
    private var appState: AppState?
    private var terminalAreaController: TerminalAreaViewController?
    private var rootSplitVC: RootSplitViewController?
    private var sidebarController: SidebarHostingController?
    private var keyMonitor: Any?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.appState = state

        // Initialize database
        let database: AppDatabase
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("Den", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let dbPath = appSupport.appendingPathComponent("den.sqlite").path
            database = try AppDatabase.onDisk(path: dbPath)
        } catch {
            database = try! AppDatabase.inMemory()
        }

        let projectRepo = ProjectRepository(database: database)
        let worktreeRepo = WorktreeRepository(database: database)
        let uiStateRepo = UIStateRepository(database: database)
        let tmuxBackend = TmuxBackend()
        let gitBackend = GitBackend()

        let manager = WorkspaceManager(
            appState: state,
            projectRepo: projectRepo,
            worktreeRepo: worktreeRepo,
            uiStateRepo: uiStateRepo,
            tmuxBackend: tmuxBackend,
            gitBackend: gitBackend
        )
        self.workspaceManager = manager

        try? manager.loadAll()

        // Create terminal area (initializes GhosttyApp and extracts theme)
        let terminalArea = TerminalAreaViewController()
        terminalArea.onCreateSession = { [weak self] in
            guard let self else { return }
            if let manager = self.workspaceManager, manager.hasSelectedWorktree {
                Task { await manager.reconnectCurrentSession() }
            } else {
                self.showAddProjectPanel()
            }
        }
        self.terminalAreaController = terminalArea

        // Wire ghostty keybinding actions to tmux operations
        if let adapter = terminalArea.terminalHost as? GhosttyAdapter {
            adapter.actionHandler = { [weak self] action in
                self?.handleGhosttyAction(action)
            }
        }

        let themeInfo = terminalArea.themeInfo

        // Build main window
        let windowController = MainWindowController(themeInfo: themeInfo)
        self.mainWindowController = windowController

        // Build sidebar
        let sidebarController = SidebarHostingController(
            appState: state,
            onSelectProject: { [weak manager, weak self] projectId in
                manager?.selectProject(projectId)
                self?.updateWindowTitle()
            },
            onSelectWorktree: { [weak manager, weak self] worktreeId in
                manager?.selectWorktree(worktreeId)
                self?.updateWindowTitle()
            },
            onSelectWindow: { [weak manager, weak self] windowId in
                manager?.selectWindow(windowId)
                self?.updateWindowTitle()
            },
            onCreateWorktree: { [weak manager] branchName in
                guard let manager else { return }
                Task { @MainActor in
                    await manager.handleCreateWorktree(branchName: branchName)
                }
            },
            onRemoveWorktree: { [weak manager] worktreeId in
                guard let manager else { return }
                Task { @MainActor in
                    await manager.removeWorktree(worktreeId: worktreeId)
                }
            },
            onRemoveProject: { [weak manager] projectId in
                guard let manager else { return }
                Task { @MainActor in
                    await manager.removeProject(projectId: projectId)
                }
            },
            onToggleCollapse: { [weak manager] projectId in
                manager?.toggleProjectCollapse(projectId)
            },
            onAddProject: { [weak self] in
                self?.showAddProjectPanel()
            }
        )
        self.sidebarController = sidebarController
        sidebarController.updateAppearance(themeInfo: themeInfo)

        // Build split view
        let splitVC = RootSplitViewController(
            sidebarController: sidebarController,
            contentController: terminalArea
        )
        self.rootSplitVC = splitVC

        windowController.onToggleSidebar = { [weak splitVC] in
            splitVC?.toggleSidebar()
        }

        windowController.contentViewController = splitVC
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wire terminal switch/detach
        manager.onTerminalSwitch = { [weak terminalArea] sessionName, workingDirectory in
            terminalArea?.attachToSession(sessionName: sessionName, workingDirectory: workingDirectory)
        }

        manager.onTerminalDetach = { [weak terminalArea, weak manager] in
            terminalArea?.hasSelectedWorktree = manager?.hasSelectedWorktree ?? false
            terminalArea?.detach()
        }

        manager.restoreState()

        setupMainMenu()
        setupKeyMonitor()
        updateWindowTitle()

        // Check tmux and start polling
        Task {
            let tmuxAvailable = await manager.checkTmuxAvailability()
            if !tmuxAvailable {
                showTmuxMissingAlert()
                return
            }

            await manager.refreshRuntimeState()
            manager.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }

        workspaceManager?.stopPolling()
        workspaceManager?.saveUIStateOnTerminate()
        terminalAreaController?.removeAllSurfaces()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Add Project

    private func showAddProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder"
        panel.prompt = "Add Project"

        guard let window = mainWindowController?.window else { return }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.handleAddProject(path: url.path)
        }
    }

    private func handleAddProject(path: String) {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in
            do {
                let project = try await manager.addProject(path: path)
                mainWindowController?.updateTitle(projectName: project.name)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Failed to add project"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Den", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Open Project...", action: #selector(openProjectMenuAction), key: "o", mods: [.command, .shift]))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Den", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(menuItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option]))
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Den", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Tmux menu
        let tmuxMenuItem = NSMenuItem()
        let tmuxMenu = NSMenu(title: "Tmux")
        tmuxMenu.addItem(menuItem("New Tab", action: #selector(newTabMenuAction), key: "t"))
        tmuxMenu.addItem(menuItem("Close Pane", action: #selector(closePaneMenuAction), key: "w"))
        tmuxMenu.addItem(.separator())
        tmuxMenu.addItem(menuItem("Next Tab", action: #selector(nextTabMenuAction), key: "]", mods: [.command, .shift]))
        tmuxMenu.addItem(menuItem("Previous Tab", action: #selector(previousTabMenuAction), key: "[", mods: [.command, .shift]))
        tmuxMenu.addItem(.separator())
        tmuxMenu.addItem(menuItem("Split Right", action: #selector(splitRightMenuAction), key: "d"))
        tmuxMenu.addItem(menuItem("Split Down", action: #selector(splitDownMenuAction), key: "d", mods: [.command, .shift]))
        tmuxMenu.addItem(.separator())
        tmuxMenu.addItem(menuItem("Next Pane", action: #selector(nextPaneMenuAction), key: "]"))
        tmuxMenu.addItem(menuItem("Previous Pane", action: #selector(previousPaneMenuAction), key: "["))
        tmuxMenu.addItem(menuItem("Toggle Pane Zoom", action: #selector(togglePaneZoomMenuAction), key: "\r", mods: [.command, .shift]))
        tmuxMenu.addItem(menuItem("Equalize Panes", action: #selector(equalizePanesMenuAction), key: "=", mods: [.command, .control]))
        tmuxMenuItem.submenu = tmuxMenu
        mainMenu.addItem(tmuxMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Toggle Sidebar", action: #selector(toggleSidebarMenuAction), key: "b"))
        windowMenu.addItem(menuItem("Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", mods: [.command, .control]))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(menuItem("Close Window", action: #selector(closeWindowMenuAction), key: "w", mods: [.command, .shift]))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String,
        mods: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        let systemActions: Set<String> = [
            NSStringFromSelector(#selector(NSWindow.toggleFullScreen(_:))),
            NSStringFromSelector(#selector(NSApplication.hideOtherApplications(_:))),
        ]
        if !systemActions.contains(NSStringFromSelector(action)) {
            item.target = self
        }
        return item
    }

    // MARK: - Menu Actions

    @objc private func openProjectMenuAction() {
        showAddProjectPanel()
    }

    @objc private func toggleSidebarMenuAction() {
        rootSplitVC?.toggleSidebar()
    }

    @objc private func newTabMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.createNewWindow() }
    }

    @objc private func closePaneMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.closeCurrentPane() }
    }

    @objc private func closeWindowMenuAction() {
        mainWindowController?.window?.close()
    }

    @objc private func splitRightMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.splitCurrentPane(horizontal: true) }
    }

    @objc private func splitDownMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.splitCurrentPane(horizontal: false) }
    }

    @objc private func nextTabMenuAction() {
        workspaceManager?.nextWindow()
    }

    @objc private func previousTabMenuAction() {
        workspaceManager?.previousWindow()
    }

    @objc private func nextPaneMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.navigatePane(direction: .next) }
    }

    @objc private func previousPaneMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.navigatePane(direction: .previous) }
    }

    @objc private func togglePaneZoomMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.togglePaneZoom() }
    }

    @objc private func equalizePanesMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.equalizePanes() }
    }

    // MARK: - Key Monitor

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers ?? ""

            // Cmd+1-9: select tmux window by index
            if mods == [.command], let digit = Int(key), digit >= 1, digit <= 9 {
                self?.workspaceManager?.selectWindowByIndex(digit)
                return nil
            }

            // Ctrl+Tab / Ctrl+Shift+Tab: cycle worktrees
            if event.keyCode == 48 {
                if mods == [.control] {
                    self?.workspaceManager?.cycleWorktree(forward: true)
                    return nil
                }
                if mods == [.control, .shift] {
                    self?.workspaceManager?.cycleWorktree(forward: false)
                    return nil
                }
            }

            return event
        }
    }

    // MARK: - Ghostty Action Handler

    private func handleGhosttyAction(_ action: GhosttyAppAction) {
        guard let manager = workspaceManager else { return }
        switch action {
        case .newTab:
            Task { await manager.createNewWindow() }
        case .closeTab:
            Task { await manager.closeCurrentPane() }
        case .gotoTab(let target):
            switch target {
            case .previous: manager.previousWindow()
            case .next: manager.nextWindow()
            case .last: manager.selectWindowByIndex(9)
            case .index(let n): manager.selectWindowByIndex(n)
            }
        case .newSplit(let dir):
            let horizontal = (dir == .right || dir == .left)
            Task { await manager.splitCurrentPane(horizontal: horizontal) }
        case .gotoSplit(let dir):
            let paneDir: PaneDirection
            switch dir {
            case .previous: paneDir = .previous
            case .next: paneDir = .next
            case .up: paneDir = .up
            case .down: paneDir = .down
            case .left: paneDir = .left
            case .right: paneDir = .right
            }
            Task { await manager.navigatePane(direction: paneDir) }
        case .resizeSplit(let dir, let amount):
            let paneDir: PaneDirection
            switch dir {
            case .up: paneDir = .up
            case .down: paneDir = .down
            case .left: paneDir = .left
            case .right: paneDir = .right
            }
            Task { await manager.resizePane(direction: paneDir, amount: Int(amount)) }
        case .equalizeSplits:
            Task { await manager.equalizePanes() }
        case .toggleSplitZoom:
            Task { await manager.togglePaneZoom() }
        case .newWindow:
            break
        case .closeWindow:
            mainWindowController?.window?.close()
        case .openConfig:
            break
        case .toggleFullscreen:
            mainWindowController?.window?.toggleFullScreen(nil)
        }
    }

    // MARK: - Tmux Missing Alert

    private func showTmuxMissingAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "tmux not found"
        alert.informativeText = """
            Den requires tmux to manage terminal sessions. \
            Please install tmux and relaunch the app.

            Install via Homebrew:
              brew install tmux

            Or via MacPorts:
              sudo port install tmux
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helpers

    private func updateWindowTitle() {
        mainWindowController?.updateTitle(
            projectName: appState?.selectedProject?.name,
            worktreeName: appState?.selectedWorktree?.branch ?? appState?.selectedWorktree?.name
        )
    }
}
