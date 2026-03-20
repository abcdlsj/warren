import Foundation
import DenCore

// MARK: - Project Tests

func testProjectDefaultInit() {
    let project = Project(name: "den", repoRootPath: "/Users/test/den")
    assertEqual(project.name, "den")
    assertEqual(project.repoRootPath, "/Users/test/den")
    assertEqual(project.gitCommonDir, "")
    assertNil(project.originURL)
    assertNil(project.iconName)
    assertFalse(project.isFavorite)
    assertFalse(project.isCollapsed)
    assertNil(project.lastActiveAt)
}

func testProjectFullInit() {
    let id = UUID()
    let date = Date()
    let project = Project(
        id: id,
        name: "anna",
        repoRootPath: "/repos/anna",
        gitCommonDir: "/repos/anna/.git",
        originURL: "git@github.com:user/anna.git",
        iconName: "folder",
        isFavorite: true,
        isCollapsed: true,
        lastActiveAt: date
    )
    assertEqual(project.id, id)
    assertEqual(project.name, "anna")
    assertEqual(project.originURL, "git@github.com:user/anna.git")
    assertTrue(project.isFavorite)
}

func testProjectAutoShortName() {
    assertEqual(Project.autoShortName(from: "den"), "den")
    assertEqual(Project.autoShortName(from: "my-awesome-project"), "map")
    assertEqual(Project.autoShortName(from: "short"), "short")
}

func testProjectEquatable() {
    let id = UUID()
    let a = Project(id: id, name: "a", repoRootPath: "/a")
    let b = Project(id: id, name: "a", repoRootPath: "/a")
    let c = Project(id: id, name: "c", repoRootPath: "/a")
    assertEqual(a, b)
    assertNotEqual(a, c)
}

func testProjectCodable() {
    let project = Project(name: "test", repoRootPath: "/test")
    let data = try! JSONEncoder().encode(project)
    let decoded = try! JSONDecoder().decode(Project.self, from: data)
    assertEqual(decoded, project)
}

// MARK: - Worktree Tests

func testWorktreeDefaultInit() {
    let projectId = UUID()
    let wt = Worktree(projectId: projectId, name: "main", path: "/repos/den")
    assertEqual(wt.projectId, projectId)
    assertEqual(wt.name, "main")
    assertNil(wt.branch)
    assertFalse(wt.isMainWorktree)
    assertFalse(wt.isDetached)
    assertFalse(wt.hasUncommittedChanges)
    assertEqual(wt.aheadCount, 0)
    assertEqual(wt.behindCount, 0)
    assertNil(wt.tmuxSessionId)
    assertNil(wt.tmuxSessionName)
}

func testWorktreeCodable() {
    let wt = Worktree(
        projectId: UUID(),
        name: "feat-sidebar",
        path: "/repos/den/feat-sidebar",
        branch: "feat/sidebar"
    )
    let data = try! JSONEncoder().encode(wt)
    let decoded = try! JSONDecoder().decode(Worktree.self, from: data)
    assertEqual(decoded, wt)
}

// MARK: - RuntimeWindow Tests

func testRuntimeWindowIdDerivation() {
    let win = RuntimeWindow(tmuxWindowId: "@1", worktreeId: UUID())
    assertEqual(win.id, "@1")
}

func testRuntimeWindowDefaults() {
    let win = RuntimeWindow(tmuxWindowId: "@1", worktreeId: UUID())
    assertEqual(win.tmuxWindowIndex, 0)
    assertEqual(win.title, "")
    assertEqual(win.paneCount, 1)
    assertNil(win.cwd)
}

func testRuntimeWindowCodable() {
    let win = RuntimeWindow(
        tmuxWindowId: "@2",
        worktreeId: UUID(),
        tmuxWindowIndex: 1,
        title: "editor",
        paneCount: 2
    )
    let data = try! JSONEncoder().encode(win)
    let decoded = try! JSONDecoder().decode(RuntimeWindow.self, from: data)
    assertEqual(decoded, win)
}

// MARK: - RuntimePane Tests

func testRuntimePaneIdDerivation() {
    let pane = RuntimePane(tmuxPaneId: "%0", tmuxWindowId: "@1")
    assertEqual(pane.id, "%0")
}

func testRuntimePaneDefaults() {
    let pane = RuntimePane(tmuxPaneId: "%0", tmuxWindowId: "@1")
    assertFalse(pane.isActive)
    assertFalse(pane.isZoomed)
    assertNil(pane.title)
    assertNil(pane.cwd)
    assertNil(pane.tty)
}

func testRuntimePaneCodable() {
    let pane = RuntimePane(
        tmuxPaneId: "%1",
        tmuxWindowId: "@2",
        title: "zsh",
        cwd: "/home",
        tty: "/dev/ttys001",
        isActive: true,
        isZoomed: false
    )
    let data = try! JSONEncoder().encode(pane)
    let decoded = try! JSONDecoder().decode(RuntimePane.self, from: data)
    assertEqual(decoded, pane)
}

// MARK: - UIState Tests

func testUIStateDefaultInit() {
    let state = UIState()
    assertNil(state.selectedProjectId)
    assertNil(state.selectedWorktreeId)
    assertNil(state.selectedWindowId)
    assertEqual(state.sidebarMode, .worktrees)
    assertEqual(state.searchQuery, "")
}

func testUIStateCodable() {
    let state = UIState(
        selectedProjectId: UUID(),
        selectedWorktreeId: UUID(),
        selectedWindowId: "@1",
        sidebarMode: .search,
        searchQuery: "test"
    )
    let data = try! JSONEncoder().encode(state)
    let decoded = try! JSONDecoder().decode(UIState.self, from: data)
    assertEqual(decoded, state)
}

// MARK: - SidebarMode Tests

func testSidebarModeRawValues() {
    assertEqual(SidebarMode.worktrees.rawValue, "worktrees")
    assertEqual(SidebarMode.search.rawValue, "search")
}

func testSidebarModeCodable() {
    for mode: SidebarMode in [.worktrees, .search] {
        let data = try! JSONEncoder().encode(mode)
        let decoded = try! JSONDecoder().decode(SidebarMode.self, from: data)
        assertEqual(decoded, mode)
    }
}

// MARK: - Main

print("=== DenCore Model Tests ===")

testProjectDefaultInit()
testProjectFullInit()
testProjectAutoShortName()
testProjectEquatable()
testProjectCodable()

testWorktreeDefaultInit()
testWorktreeCodable()

testRuntimeWindowIdDerivation()
testRuntimeWindowDefaults()
testRuntimeWindowCodable()

testRuntimePaneIdDerivation()
testRuntimePaneDefaults()
testRuntimePaneCodable()

testUIStateDefaultInit()
testUIStateCodable()

testSidebarModeRawValues()
testSidebarModeCodable()

printResults()

if failCount > 0 {
    fflush(stdout)
    fatalError("Tests failed")
}
