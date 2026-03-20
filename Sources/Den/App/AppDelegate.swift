import AppKit
import DenConfig
import DenCore
import DenGit
import DenPersistence
import DenTerminal
import DenTmux
import DenUI
import SwiftUI

/// Top-level composition root for the macOS app.
/// It wires persistence, runtime backends, AppKit windows, and the SwiftUI sidebar together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Detached terminal windows are backed by cloned tmux session groups.
    /// The surface/controller pair is kept here so AppDelegate can own cleanup.
    private struct PopoutSession {
        let worktreeId: UUID
        let sourceSessionName: String
        let popoutSessionName: String
        let surface: NSView
        let controller: PopoutTerminalWindowController
    }

    private var mainWindowController: MainWindowController?
    private var workspaceManager: WorkspaceManager?
    private var appState: AppState?
    private var terminalAreaController: TerminalAreaViewController?
    private var rootSplitVC: RootSplitViewController?
    private var sidebarController: SidebarHostingController?
    private var keyMonitor: Any?
    private var popoutSessionsByWorktreeId: [UUID: PopoutSession] = [:]
    private var popoutCreationWorktreeIds: Set<UUID> = []
    private var config: DenConfiguration = .default

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.config = DenConfiguration.load()

        let state = AppState()
        self.appState = state

        // Persistence is best-effort: prefer an on-disk GRDB store, but fall back to
        // an in-memory database so the app can still start if Application Support setup fails.
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

        let terminalArea = TerminalAreaViewController()
        terminalArea.onCreateSession = { [weak self] in
            guard let self else { return }
            if let manager = self.workspaceManager, manager.hasSelectedWorktree {
                Task { await manager.reconnectCurrentSession() }
            } else {
                self.showAddProjectPanel()
            }
        }
        terminalArea.onCreateTab = { [weak manager] in
            guard let manager else { return }
            Task { @MainActor in await manager.createNewWindow() }
        }
        terminalArea.onPopOutSession = { [weak self] in
            self?.popoutTerminalMenuAction()
        }
        self.terminalAreaController = terminalArea

        let themeInfo = terminalArea.themeInfo

        // The main window only provides the AppKit shell. Content is composed below.
        let windowController = MainWindowController(themeInfo: themeInfo)
        self.mainWindowController = windowController

        // The sidebar is SwiftUI, but selection still flows back into WorkspaceManager so
        // AppState remains the single source of truth.
        let sidebarController = SidebarHostingController(
            appState: state,
            onSelectProject: { [weak manager, weak self] projectId in
                manager?.selectProject(projectId)
                self?.updateWindowTitle()
                self?.updateTerminalTitleBar()
            },
            onSelectWorktree: { [weak manager, weak self] worktreeId in
                if self?.focusPopout(forWorktreeId: worktreeId) == true {
                    return
                }
                manager?.selectWorktree(worktreeId)
                self?.updateWindowTitle()
                self?.updateTerminalTitleBar()
            },
            onSelectWindow: { [weak manager, weak self] windowId in
                if self?.focusPopout(forWindowId: windowId) == true {
                    return
                }
                manager?.selectWindow(windowId)
                self?.updateWindowTitle()
                self?.updateTerminalTitleBar()
            },
            onCreateWorktree: { [weak manager] branchName in
                guard let manager else { return }
                Task { @MainActor in
                    await manager.handleCreateWorktree(branchName: branchName)
                }
            },
            onRemoveWorktree: { [weak manager, weak self] worktreeId in
                guard let manager, let self else { return }
                Task { @MainActor in
                    await self.closePopout(forWorktreeId: worktreeId)
                    await manager.removeWorktree(worktreeId: worktreeId)
                }
            },
            onRemoveProject: { [weak manager, weak self] projectId in
                guard let manager, let self else { return }
                Task { @MainActor in
                    await self.closePopouts(forProjectId: projectId)
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

        // AppKit split view bridges the SwiftUI sidebar and the terminal container.
        let splitVC = RootSplitViewController(
            sidebarController: sidebarController,
            contentController: terminalArea
        )
        self.rootSplitVC = splitVC

        windowController.contentViewController = splitVC
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // WorkspaceManager emits high-level terminal intents; it never talks to AppKit directly.
        manager.onTerminalSwitch = { [weak self, weak terminalArea] sessionName, workingDirectory in
            terminalArea?.attachToSession(sessionName: sessionName, workingDirectory: workingDirectory)
            self?.updateTerminalTitleBar()
        }

        manager.onTerminalDetach = { [weak terminalArea, weak manager] in
            terminalArea?.hasSelectedWorktree = manager?.hasSelectedWorktree ?? false
            terminalArea?.detach()
        }

        manager.restoreState()

        setupMainMenu()
        setupKeyMonitor()
        updateWindowTitle()

        // Startup finishes only after tmux availability and runtime synchronization are checked.
        Task {
            let tmuxAvailable = await manager.checkTmuxAvailability()
            if !tmuxAvailable {
                showTmuxMissingAlert()
                return
            }

            await manager.cleanupOrphanedPopoutSessions()
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
        Task { @MainActor in
            await closeAllPopouts()
        }
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
                // Adding a project also creates the main worktree/session pair.
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

        // Menus mostly forward to WorkspaceManager or the currently focused terminal surface.
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
        windowMenu.addItem(menuItem("Pop Out Terminal", action: #selector(popoutTerminalMenuAction), key: "o", mods: [.command, .control]))
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

    @objc private func popoutTerminalMenuAction() {
        guard let terminalArea = terminalAreaController,
              let manager = workspaceManager else { return }

        guard let worktreeId = appState?.selectedWorktree?.id else { return }

        if let existing = popoutSessionsByWorktreeId[worktreeId] {
            existing.controller.showWindow(nil)
            existing.controller.focusTerminal()
            return
        }

        guard !popoutCreationWorktreeIds.contains(worktreeId) else { return }
        popoutCreationWorktreeIds.insert(worktreeId)

        Task { @MainActor in
            defer { popoutCreationWorktreeIds.remove(worktreeId) }
            do {
                let popoutInfo = try await manager.createPopoutSessionForSelectedWorktree()

                // Popout windows render a separate terminal surface attached to the cloned session.
                let surface = terminalArea.createStandaloneSurface(
                    sessionName: popoutInfo.popoutSessionName,
                    workingDirectory: popoutInfo.workingDirectory
                )

                let popout = PopoutTerminalWindowController(
                    surface: surface,
                    sessionName: popoutInfo.sourceSessionName,
                    terminalHost: terminalArea.terminalHost,
                    themeInfo: terminalArea.themeInfo
                )

                let popoutSession = PopoutSession(
                    worktreeId: popoutInfo.worktreeId,
                    sourceSessionName: popoutInfo.sourceSessionName,
                    popoutSessionName: popoutInfo.popoutSessionName,
                    surface: surface,
                    controller: popout
                )

                popout.onClose = { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.closePopout(forWorktreeId: popoutInfo.worktreeId)
                    }
                }

                popoutSessionsByWorktreeId[popoutInfo.worktreeId] = popoutSession
                appState?.poppedOutWorktreeIds.insert(popoutInfo.worktreeId)
                popout.showWindow(nil)
                popout.focusTerminal()
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Failed to pop out terminal"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func closePopouts(forProjectId projectId: UUID) async {
        let worktreeIds = appState?.worktrees
            .filter { $0.projectId == projectId }
            .map(\.id) ?? []
        for worktreeId in worktreeIds {
            await closePopout(forWorktreeId: worktreeId)
        }
    }

    private func closeAllPopouts() async {
        let worktreeIds = Array(popoutSessionsByWorktreeId.keys)
        for worktreeId in worktreeIds {
            await closePopout(forWorktreeId: worktreeId)
        }
    }

    @discardableResult
    private func focusPopout(forWorktreeId worktreeId: UUID) -> Bool {
        guard let popout = popoutSessionsByWorktreeId[worktreeId] else { return false }
        // Detached windows win focus over the embedded terminal for the same worktree.
        popout.controller.showWindow(nil)
        popout.controller.focusTerminal()
        return true
    }

    @discardableResult
    private func focusPopout(forWindowId windowId: String) -> Bool {
        guard let window = appState?.runtimeWindows.first(where: { $0.tmuxWindowId == windowId }) else {
            return false
        }
        return focusPopout(forWorktreeId: window.worktreeId)
    }

    private func closePopout(forWorktreeId worktreeId: UUID) async {
        guard let popout = popoutSessionsByWorktreeId.removeValue(forKey: worktreeId) else { return }

        popout.controller.onClose = nil
        if popout.controller.window?.isVisible == true {
            popout.controller.close()
        }
        popout.surface.removeFromSuperview()
        terminalAreaController?.terminalHost.destroySurface(popout.surface)
        try? await workspaceManager?.tmuxBackend.killSession(id: popout.popoutSessionName)
        appState?.poppedOutWorktreeIds.remove(worktreeId)
    }

    @objc private func newTabMenuAction() {
        guard let manager = workspaceManager else { return }
        Task { @MainActor in await manager.createNewWindow() }
    }

    @objc private func closePaneMenuAction() {
        if let keyWindow = NSApp.keyWindow,
           popoutSessionsByWorktreeId.values.contains(where: { $0.controller.window === keyWindow }) {
            keyWindow.close()
            return
        }
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

    private func updateTerminalTitleBar() {
        terminalAreaController?.hasSelectedWorktree = workspaceManager?.hasSelectedWorktree ?? false
        // The terminal chrome mirrors current selection without owning the selection itself.
        terminalAreaController?.updateTitleBar(
            projectName: appState?.selectedProject?.name,
            worktreeName: appState?.selectedWorktree?.branch ?? appState?.selectedWorktree?.name
        )
    }

    private func updateWindowTitle() {
        // Use branch/worktree first so the active context is visible in the OS window title.
        mainWindowController?.updateTitle(
            projectName: appState?.selectedProject?.name,
            worktreeName: appState?.selectedWorktree?.branch ?? appState?.selectedWorktree?.name
        )
    }
}
