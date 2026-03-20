import AppKit
import Foundation
import DenCore
import DenGit
import DenPersistence
import DenTmux

/// Coordinates persisted project/worktree metadata, live tmux state, and current UI selection.
enum WorkspaceError: Error, LocalizedError {
    case projectNotFound
    case branchNameEmpty
    case branchNameInvalid(String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "Project not found."
        case .branchNameEmpty:
            return "Branch name cannot be empty."
        case .branchNameInvalid(let name):
            return "Invalid branch name: \"\(name)\"."
        }
    }
}

@MainActor
final class WorkspaceManager {

    // AppState is the single mutable snapshot observed by both AppKit and SwiftUI.
    let appState: AppState
    let projectRepo: ProjectRepository
    let worktreeRepo: WorktreeRepository
    let uiStateRepo: UIStateRepository
    let tmuxBackend: TmuxBackend
    let gitBackend: GitBackend
    let gitStatusCoordinator: GitStatusCoordinator

    var onTerminalSwitch: ((String, String) -> Void)?
    var onTerminalDetach: (() -> Void)?

    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: UInt64 = 5_000_000_000
    private var latestSessions: [TmuxSession] = []

    private(set) var isTmuxAvailable: Bool = true

    init(
        appState: AppState,
        projectRepo: ProjectRepository,
        worktreeRepo: WorktreeRepository,
        uiStateRepo: UIStateRepository,
        tmuxBackend: TmuxBackend,
        gitBackend: GitBackend
    ) {
        self.appState = appState
        self.projectRepo = projectRepo
        self.worktreeRepo = worktreeRepo
        self.uiStateRepo = uiStateRepo
        self.tmuxBackend = tmuxBackend
        self.gitBackend = gitBackend
        self.gitStatusCoordinator = GitStatusCoordinator(gitBackend: gitBackend)
    }

    // MARK: - Load All State

    func loadAll() throws {
        appState.projects = try projectRepo.fetchAll()
        var allWorktrees: [Worktree] = []
        for project in appState.projects {
            let wts = try worktreeRepo.fetchAll(forProject: project.id)
            allWorktrees.append(contentsOf: wts)
        }
        appState.worktrees = allWorktrees
        appState.uiState = try uiStateRepo.fetch()
    }

    func checkTmuxAvailability() async -> Bool {
        let available = await tmuxBackend.isAvailable()
        isTmuxAvailable = available
        return available
    }

    func cleanupOrphanedPopoutSessions() async {
        let sessionNames = await tmuxBackend.listSessionNames()
        // Popout sessions are disposable clones and should not survive an app restart.
        for sessionName in sessionNames where sessionName.contains("__popout_") {
            try? await tmuxBackend.killSession(id: sessionName)
        }
    }

    // MARK: - Select Project

    func selectProject(_ projectId: UUID) {
        appState.uiState.selectedProjectId = projectId
        appState.uiState.selectedWorktreeId = nil
        appState.uiState.selectedWindowId = nil

        // Eagerly select the first visible worktree so the terminal area has a deterministic target.
        let worktrees = selectableWorktrees(forProjectId: projectId)
        if let first = worktrees.first {
            selectWorktree(first.id)
        }

        saveUIState()
    }

    // MARK: - Toggle Project Collapse

    func toggleProjectCollapse(_ projectId: UUID) {
        guard let index = appState.projects.firstIndex(where: { $0.id == projectId }) else { return }
        appState.projects[index].isCollapsed.toggle()
    }

    // MARK: - Select Worktree

    func selectWorktree(_ worktreeId: UUID) {
        guard !appState.poppedOutWorktreeIds.contains(worktreeId) else { return }
        appState.uiState.selectedWorktreeId = worktreeId
        appState.uiState.selectedWindowId = nil

        guard let worktree = appState.worktrees.first(where: { $0.id == worktreeId }) else { return }

        Task {
            // A worktree selection is really "select or lazily recreate the backing tmux session".
            await ensureTmuxSession(for: worktree)
            if let sessionName = worktree.tmuxSessionName {
                onTerminalSwitch?(sessionName, worktree.path)
            }
            await refreshRuntimeState()
        }

        saveUIState()
    }

    // MARK: - Select Window

    func selectWindow(_ windowId: String) {
        appState.uiState.selectedWindowId = windowId

        if let window = appState.runtimeWindows.first(where: { $0.tmuxWindowId == windowId }),
           let worktree = appState.worktrees.first(where: { $0.id == window.worktreeId }),
           let sessionName = worktree.tmuxSessionName {
            if appState.uiState.selectedWorktreeId != worktree.id {
                appState.uiState.selectedWorktreeId = worktree.id
            }
            Task {
                // Keep tmux's active window aligned with the sidebar/window selection.
                try? await tmuxBackend.selectWindow(sessionId: sessionName, windowId: windowId)
            }
            onTerminalSwitch?(sessionName, worktree.path)
        }

        saveUIState()
    }

    // MARK: - Add Project

    @discardableResult
    func addProject(path: String) async throws -> Project {
        let name = (path as NSString).lastPathComponent

        let isRepo = try await gitBackend.isGitRepo(path: path)
        var commonDir = path
        if isRepo {
            // Linked worktrees may store git metadata outside repoRootPath.
            commonDir = try await gitBackend.gitCommonDir(path: path)
        }

        let project = Project(
            name: name,
            repoRootPath: path,
            gitCommonDir: commonDir,
            lastActiveAt: Date()
        )
        try projectRepo.save(project)

        let sessionName = SessionNaming.sessionName(projectShortName: project.shortName, worktree: "main")
        let worktree = Worktree(
            projectId: project.id,
            name: "main",
            path: path,
            branch: "main",
            isMainWorktree: true,
            tmuxSessionName: sessionName
        )
        try worktreeRepo.save(worktree)

        Task {
            // Session creation is intentionally fire-and-forget so the UI can render immediately.
            await createTmuxSession(name: sessionName, cwd: path)
        }

        try loadAll()
        selectProject(project.id)

        return project
    }

    // MARK: - Create Worktree

    @discardableResult
    func createWorktree(projectId: UUID, branchName: String) async throws -> Worktree {
        let trimmed = branchName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw WorkspaceError.branchNameEmpty
        }

        let invalidChars = CharacterSet(charactersIn: " ~^:?*[\\")
        if trimmed.unicodeScalars.contains(where: { invalidChars.contains($0) }) {
            throw WorkspaceError.branchNameInvalid(trimmed)
        }

        guard let project = appState.projects.first(where: { $0.id == projectId }) else {
            throw WorkspaceError.projectNotFound
        }

        let projectSlug = SessionNaming.slugify(project.name)
        let branchSlug = SessionNaming.slugify(trimmed)

        let denDir = (NSHomeDirectory() as NSString).appendingPathComponent(".den")
        let projectDir = (denDir as NSString).appendingPathComponent(projectSlug)
        let worktreePath = (projectDir as NSString).appendingPathComponent(branchSlug)

        // Den owns secondary worktrees under ~/.den so user repos remain uncluttered.
        try FileManager.default.createDirectory(
            atPath: projectDir,
            withIntermediateDirectories: true
        )

        try await gitBackend.addWorktree(
            repoPath: project.repoRootPath,
            path: worktreePath,
            branch: trimmed,
            createBranch: true
        )

        let sessionName = SessionNaming.sessionName(projectShortName: project.shortName, worktree: trimmed)
        let worktree = Worktree(
            projectId: projectId,
            name: trimmed,
            path: worktreePath,
            branch: trimmed,
            isMainWorktree: false,
            tmuxSessionName: sessionName
        )
        try worktreeRepo.save(worktree)

        await createTmuxSession(name: sessionName, cwd: worktreePath)

        appState.worktrees.append(worktree)
        selectWorktree(worktree.id)

        return worktree
    }

    func handleCreateWorktree(branchName: String) async {
        let trimmed = branchName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showErrorAlert(title: "Invalid Branch Name", message: WorkspaceError.branchNameEmpty.localizedDescription)
            return
        }

        guard let projectId = appState.uiState.selectedProjectId else {
            showErrorAlert(title: "No Project Selected", message: "Please select a project first.")
            return
        }

        do {
            _ = try await createWorktree(projectId: projectId, branchName: trimmed)
            await refreshRuntimeState()
        } catch {
            showErrorAlert(title: "Failed to Create Worktree", message: error.localizedDescription)
        }
    }

    // MARK: - Remove Worktree

    func removeWorktree(worktreeId: UUID) async {
        guard let index = appState.worktrees.firstIndex(where: { $0.id == worktreeId }) else { return }
        let worktree = appState.worktrees[index]

        if worktree.isMainWorktree {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Cannot remove main worktree"
            alert.informativeText = "The main worktree is tied to the project's root directory and cannot be removed."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove worktree \"\(worktree.name)\"?"
        alert.informativeText = "This worktree is at \(worktree.path)"
        alert.addButton(withTitle: "Remove from Den")
        alert.addButton(withTitle: "Remove from Den and Delete Files")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            softDeleteWorktree(at: index)

        case .alertSecondButtonReturn:
            softDeleteWorktree(at: index)
            if let project = appState.projects.first(where: { $0.id == worktree.projectId }) {
                do {
                    try await gitBackend.removeWorktree(
                        repoPath: project.repoRootPath,
                        path: worktree.path,
                        force: false
                    )
                } catch {
                    let errorAlert = NSAlert()
                    errorAlert.alertStyle = .warning
                    errorAlert.messageText = "Failed to delete worktree files"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            }

            if let sessionName = worktree.tmuxSessionName {
                try? await tmuxBackend.killSession(id: sessionName)
            }

        default:
            break
        }
    }

    // MARK: - Remove Project

    func removeProject(projectId: UUID) async {
        guard let project = appState.projects.first(where: { $0.id == projectId }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove project \"\(project.name)\"?"
        alert.informativeText = "This will remove the project and all its worktrees from Den. Git repositories on disk will not be deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let projectWorktrees = appState.worktrees.filter { $0.projectId == projectId }

        for worktree in projectWorktrees {
            if let sessionName = worktree.tmuxSessionName {
                try? await tmuxBackend.killSession(id: sessionName)
            }
        }

        appState.worktrees.removeAll { $0.projectId == projectId }
        for worktree in projectWorktrees {
            try? worktreeRepo.delete(id: worktree.id)
        }

        appState.projects.removeAll { $0.id == projectId }
        try? projectRepo.delete(id: projectId)

        if appState.uiState.selectedProjectId == projectId {
            appState.uiState.selectedProjectId = nil
            appState.uiState.selectedWorktreeId = nil
            appState.uiState.selectedWindowId = nil

            if let firstProject = appState.projects.first {
                selectProject(firstProject.id)
            }
            saveUIState()
        }
    }

    private func softDeleteWorktree(at index: Int) {
        let worktree = appState.worktrees[index]
        let wasSelected = appState.uiState.selectedWorktreeId == worktree.id

        // "Soft delete" forgets Den metadata first; filesystem cleanup is handled separately.
        appState.worktrees.remove(at: index)
        try? worktreeRepo.delete(id: worktree.id)

        if wasSelected {
            appState.uiState.selectedWorktreeId = nil
            appState.uiState.selectedWindowId = nil
            let remaining = appState.worktreesForSelectedProject
            if let first = remaining.first {
                selectWorktree(first.id)
            }
            saveUIState()
        }
    }

    // MARK: - Tmux Integration

    private func createTmuxSession(name: String, cwd: String) async {
        _ = try? await tmuxBackend.createSession(name: name, cwd: cwd)
        await configureTmuxStatusLine(sessionId: name)
    }

    private func configureTmuxStatusLine(sessionId: String) async {
        let set: (String, String) async -> Void = { [weak self] option, value in
            try? await self?.tmuxBackend.setOption(sessionId: sessionId, option: option, value: value)
        }

        // Keep tmux visuals close to the app's warm dark palette.
        let base = "#1e1e2e"
        let surface0 = "#313244"
        let overlay0 = "#6c7086"
        let text = "#cdd6f4"
        let blue = "#89b4fa"
        let green = "#a6e3a1"

        await set("status", "on")
        await set("status-position", "bottom")
        await set("status-style", "bg=\(base),fg=\(overlay0)")
        await set("status-left", "#[fg=\(base),bg=\(blue),bold]  #S #[fg=\(blue),bg=\(base)] ")
        await set("status-left-length", "30")
        await set("status-right", "#[fg=\(surface0)]#[fg=\(text),bg=\(surface0)] %H:%M #[fg=\(green),bg=\(surface0)] 󰉋 #(basename #{pane_current_path}) ")
        await set("status-right-length", "60")

        // Window status
        let setW: (String, String) async -> Void = { [weak self] option, value in
            try? await self?.tmuxBackend.setWindowOption(global: false, target: sessionId, option: option, value: value)
        }

        await setW("window-status-format", "#[fg=\(overlay0),bg=\(base)] #I:#W ")
        await setW("window-status-current-format", "#[fg=\(blue),bg=\(surface0),bold] #I:#W ")
        await setW("window-status-separator", "")

        // Pane border colors
        await set("pane-border-style", "fg=\(surface0)")
        await set("pane-active-border-style", "fg=\(blue)")
    }

    private func ensureTmuxSession(for worktree: Worktree) async {
        guard let sessionName = worktree.tmuxSessionName else { return }

        let existingNames = await tmuxBackend.listSessionNames()
        let exists = existingNames.contains(sessionName)

        if !exists {
            // Runtime sessions are treated as cacheable state that can be reconstructed from persisted metadata.
            await createTmuxSession(name: sessionName, cwd: worktree.path)
        }
    }

    func refreshRuntimeState() async {
        guard let sessions = try? await tmuxBackend.scanAll() else { return }

        var runtimeWindows: [RuntimeWindow] = []

        for session in sessions {
            guard let worktree = appState.worktrees.first(where: {
                $0.tmuxSessionName == session.name
            }) else { continue }

            for tmuxWindow in session.windows {
                let rw = RuntimeWindow(
                    tmuxWindowId: tmuxWindow.windowId,
                    worktreeId: worktree.id,
                    tmuxWindowIndex: tmuxWindow.windowIndex,
                    title: tmuxWindow.name,
                    paneCount: tmuxWindow.panes.count
                )
                runtimeWindows.append(rw)
            }
        }

        appState.runtimeWindows = runtimeWindows
    }

    // MARK: - Persistence

    private func saveUIState() {
        try? uiStateRepo.save(appState.uiState)
    }

    func saveUIStateOnTerminate() {
        try? uiStateRepo.save(appState.uiState)
    }

    // MARK: - Coordinated Polling

    func startPolling() {
        guard pollingTask == nil else { return }
        let interval = self.pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.coordinatedPoll()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func coordinatedPoll() async {
        // Poll tmux and git concurrently so UI freshness does not depend on either backend finishing first.
        async let tmuxResult: [TmuxSession]? = {
            try? await self.tmuxBackend.scanAll()
        }()
        async let gitResult: [UUID: GitStatusInfo] = {
            await self.gitStatusCoordinator.pollAll(worktrees: self.appState.worktrees)
        }()

        let sessions = await tmuxResult
        let gitStatuses = await gitResult

        if let sessions {
            await detectAndRecoverDeadSessions(sessions: sessions)
            latestSessions = sessions
            updateRuntimeState(from: sessions)
        }

        updateWorktreeGitStatus(gitStatuses)
    }

    private func updateRuntimeState(from sessions: [TmuxSession]) {
        var runtimeWindows: [RuntimeWindow] = []

        for session in sessions {
            guard let worktree = appState.worktrees.first(where: {
                $0.tmuxSessionName == session.name
            }) else { continue }

            for tmuxWindow in session.windows {
                let rw = RuntimeWindow(
                    tmuxWindowId: tmuxWindow.windowId,
                    worktreeId: worktree.id,
                    tmuxWindowIndex: tmuxWindow.windowIndex,
                    title: tmuxWindow.name,
                    paneCount: tmuxWindow.panes.count
                )
                runtimeWindows.append(rw)
            }
        }

        appState.runtimeWindows = runtimeWindows
    }

    private func updateWorktreeGitStatus(_ statuses: [UUID: GitStatusInfo]) {
        for i in appState.worktrees.indices {
            guard let status = statuses[appState.worktrees[i].id] else { continue }
            let wt = appState.worktrees[i]
            // Persist only material changes so the DB is not rewritten on every poll tick.
            let changed = wt.hasUncommittedChanges != status.isDirty
                || wt.aheadCount != status.ahead
                || wt.behindCount != status.behind

            if changed {
                appState.worktrees[i].hasUncommittedChanges = status.isDirty
                appState.worktrees[i].aheadCount = status.ahead
                appState.worktrees[i].behindCount = status.behind
                try? worktreeRepo.save(appState.worktrees[i])
            }
        }
    }

    // MARK: - Window / Pane Operations

    func createNewWindow() async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }
        await ensureTmuxSession(for: worktree)
        _ = try? await tmuxBackend.createWindow(sessionId: sessionName, name: nil, cwd: worktree.path)
        await refreshRuntimeState()
        onTerminalSwitch?(sessionName, worktree.path)
    }

    func splitCurrentPane(horizontal: Bool) async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }
        do {
            _ = try await tmuxBackend.splitPane(
                sessionId: sessionName,
                paneId: "",
                horizontal: horizontal,
                cwd: worktree.path
            )
            await refreshRuntimeState()
        } catch {
            showErrorAlert(title: "Failed to split pane", message: error.localizedDescription)
        }
    }

    func nextWindow() {
        navigateWindow(offset: 1)
    }

    func previousWindow() {
        navigateWindow(offset: -1)
    }

    func closeCurrentPane() async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }

        do {
            // Passing the session target lets tmux resolve the currently active pane implicitly.
            try await tmuxBackend.killPane(sessionId: sessionName, paneId: sessionName)
            await refreshRuntimeState()

            let stillHasWindows = appState.runtimeWindows.contains { $0.worktreeId == worktree.id }
            if !stillHasWindows {
                appState.uiState.selectedWindowId = nil
                onTerminalDetach?()
            }
        } catch {
            showErrorAlert(title: "Failed to close pane", message: error.localizedDescription)
        }
    }

    func closeWindow(windowId: String) async {
        guard let rw = appState.runtimeWindows.first(where: { $0.tmuxWindowId == windowId }),
              let worktree = appState.worktrees.first(where: { $0.id == rw.worktreeId }),
              let sessionName = worktree.tmuxSessionName else { return }

        let windowsInSession = appState.runtimeWindows.filter { $0.worktreeId == worktree.id }

        do {
            if windowsInSession.count <= 1 {
                try await tmuxBackend.killSession(id: sessionName)
                appState.runtimeWindows.removeAll { $0.worktreeId == worktree.id }
                if worktree.id == appState.uiState.selectedWorktreeId {
                    appState.uiState.selectedWindowId = nil
                    onTerminalDetach?()
                }
            } else {
                try await tmuxBackend.killWindow(sessionId: sessionName, windowId: windowId)
                await refreshRuntimeState()
                if windowId == appState.uiState.selectedWindowId {
                    appState.uiState.selectedWindowId = nil
                    if let first = appState.runtimeWindows.first(where: { $0.worktreeId == worktree.id }) {
                        selectWindow(first.tmuxWindowId)
                    }
                }
            }
        } catch {
            showErrorAlert(title: "Failed to close window", message: error.localizedDescription)
        }
    }

    // MARK: - Window Navigation

    private var selectedWorktree: Worktree? {
        guard let id = appState.uiState.selectedWorktreeId else { return nil }
        return appState.worktrees.first { $0.id == id }
    }

    var hasSelectedWorktree: Bool {
        selectedWorktree != nil
    }

    func reconnectCurrentSession() async {
        guard let worktree = selectedWorktree else { return }
        await ensureTmuxSession(for: worktree)
        if let sessionName = worktree.tmuxSessionName {
            onTerminalSwitch?(sessionName, worktree.path)
        }
        await refreshRuntimeState()
    }

    func createPopoutSessionForSelectedWorktree() async throws -> (worktreeId: UUID, sourceSessionName: String, popoutSessionName: String, workingDirectory: String) {
        guard let worktree = selectedWorktree,
              let sourceSessionName = worktree.tmuxSessionName else {
            throw WorkspaceError.projectNotFound
        }

        await ensureTmuxSession(for: worktree)

        let cloneSuffix = UUID().uuidString.prefix(8).lowercased()
        let popoutSessionName = "\(sourceSessionName)__popout_\(cloneSuffix)"
        // Cloning into the same session group preserves tabs/panes without stealing the embedded client.
        _ = try await tmuxBackend.cloneSessionGroup(
            sourceSessionId: sourceSessionName,
            cloneSessionId: popoutSessionName
        )

        return (
            worktreeId: worktree.id,
            sourceSessionName: sourceSessionName,
            popoutSessionName: popoutSessionName,
            workingDirectory: worktree.path
        )
    }

    private func navigateWindow(offset: Int) {
        guard let worktree = selectedWorktree else { return }
        let windows = appState.runtimeWindows
            .filter { $0.worktreeId == worktree.id }
            .sorted { $0.tmuxWindowIndex < $1.tmuxWindowIndex }
        guard !windows.isEmpty else { return }

        let currentIndex = windows.firstIndex(where: { $0.tmuxWindowId == appState.uiState.selectedWindowId }) ?? 0
        let newIndex = (currentIndex + offset + windows.count) % windows.count
        selectWindow(windows[newIndex].tmuxWindowId)
    }

    func selectWindowByIndex(_ index: Int) {
        let windows = appState.windowsForSelectedWorktree
        guard !windows.isEmpty else { return }

        let targetIndex: Int
        if index == 9 {
            targetIndex = windows.count - 1
        } else {
            targetIndex = index - 1
        }

        guard targetIndex >= 0, targetIndex < windows.count else { return }
        selectWindow(windows[targetIndex].tmuxWindowId)
    }

    // MARK: - Worktree Cycling

    func cycleWorktree(forward: Bool) {
        guard let projectId = appState.uiState.selectedProjectId else { return }
        let projectWorktrees = selectableWorktrees(forProjectId: projectId)
        guard !projectWorktrees.isEmpty else { return }

        let currentIndex = projectWorktrees.firstIndex(where: {
            $0.id == appState.uiState.selectedWorktreeId
        }) ?? 0

        let offset = forward ? 1 : -1
        let newIndex = (currentIndex + offset + projectWorktrees.count) % projectWorktrees.count
        selectWorktree(projectWorktrees[newIndex].id)
    }

    // MARK: - Pane Navigation & Management

    func navigatePane(direction: PaneDirection) async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }
        do {
            try await tmuxBackend.navigatePane(sessionId: sessionName, direction: direction)
        } catch {
            // Non-fatal
        }
    }

    func resizePane(direction: PaneDirection, amount: Int = 10) async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }
        do {
            try await tmuxBackend.resizePane(sessionId: sessionName, direction: direction, amount: amount)
        } catch {
            // Non-fatal
        }
    }

    func togglePaneZoom() async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }
        do {
            try await tmuxBackend.togglePaneZoom(sessionId: sessionName)
        } catch {
            // Non-fatal
        }
    }

    func equalizePanes() async {
        guard let worktree = selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }
        do {
            try await tmuxBackend.equalizePanes(sessionId: sessionName)
        } catch {
            // Non-fatal
        }
    }

    // MARK: - Session Death Detection

    func detectAndRecoverDeadSessions(sessions: [TmuxSession]) async {
        guard let worktree = appState.selectedWorktree,
              let sessionName = worktree.tmuxSessionName else { return }

        let sessionAlive = sessions.contains { $0.name == sessionName }
        let hadWindows = appState.runtimeWindows.contains { $0.worktreeId == worktree.id }

        if !sessionAlive && hadWindows {
            // Visible sessions are recreated automatically so the terminal does not stay blank after a crash.
            await createTmuxSession(name: sessionName, cwd: worktree.path)
            onTerminalSwitch?(sessionName, worktree.path)
        }
    }

    // MARK: - Restore State

    func restoreState() {
        let uiState = appState.uiState

        // Restoration is defensive: every persisted identifier is revalidated against current data.
        guard let projectId = uiState.selectedProjectId,
              appState.projects.contains(where: { $0.id == projectId }) else {
            if let first = appState.projects.first {
                selectProject(first.id)
            }
            return
        }

        appState.uiState.selectedProjectId = projectId

        guard let worktreeId = uiState.selectedWorktreeId,
              appState.worktrees.contains(where: { $0.id == worktreeId }),
              !appState.poppedOutWorktreeIds.contains(worktreeId) else {
            let worktrees = selectableWorktrees(forProjectId: projectId)
            if let first = worktrees.first {
                selectWorktree(first.id)
            }
            return
        }

        appState.uiState.selectedWorktreeId = worktreeId

        if let worktree = appState.worktrees.first(where: { $0.id == worktreeId }) {
            Task {
                await ensureTmuxSession(for: worktree)
                await refreshRuntimeState()

                if let sessionName = worktree.tmuxSessionName {
                    onTerminalSwitch?(sessionName, worktree.path)
                }

                if let windowId = uiState.selectedWindowId,
                   appState.runtimeWindows.contains(where: { $0.tmuxWindowId == windowId }) {
                    appState.uiState.selectedWindowId = windowId
                    if let sessionName = worktree.tmuxSessionName {
                        try? await tmuxBackend.selectWindow(sessionId: sessionName, windowId: windowId)
                    }
                }
            }
        }
    }

    // MARK: - Git Status

    func refreshGitStatus() async {
        let statuses = await gitStatusCoordinator.pollAll(worktrees: appState.worktrees)
        updateWorktreeGitStatus(statuses)
    }

    // MARK: - Helpers

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func selectableWorktrees(forProjectId projectId: UUID) -> [Worktree] {
        // Detached worktrees stay in the model but are hidden from the embedded sidebar list.
        appState.worktrees.filter {
            $0.projectId == projectId && !appState.poppedOutWorktreeIds.contains($0.id)
        }
    }
}
