import Foundation
import DenTmux

// MARK: - TmuxParser: Session Parsing Tests

func testParseSessionsSingle() {
    let output = "$0\tmy-session\t3\t1\n"
    let sessions = TmuxParser.parseSessions(output)
    assertEqual(sessions.count, 1)
    assertEqual(sessions[0].sessionId, "$0")
    assertEqual(sessions[0].name, "my-session")
    assertEqual(sessions[0].windowCount, 3)
    assertTrue(sessions[0].isAttached)
}

func testParseSessionsMultiple() {
    let output = """
    $0\tdev\t2\t1
    $1\tden/main\t1\t0
    $2\tbackground\t4\t0
    """
    let sessions = TmuxParser.parseSessions(output)
    assertEqual(sessions.count, 3)

    assertEqual(sessions[0].sessionId, "$0")
    assertEqual(sessions[0].name, "dev")
    assertEqual(sessions[0].windowCount, 2)
    assertTrue(sessions[0].isAttached)

    assertEqual(sessions[1].sessionId, "$1")
    assertEqual(sessions[1].name, "den/main")
    assertEqual(sessions[1].windowCount, 1)
    assertFalse(sessions[1].isAttached)

    assertEqual(sessions[2].sessionId, "$2")
    assertEqual(sessions[2].name, "background")
    assertEqual(sessions[2].windowCount, 4)
    assertFalse(sessions[2].isAttached)
}

func testParseSessionsEmpty() {
    let sessions = TmuxParser.parseSessions("")
    assertEqual(sessions.count, 0)
}

func testParseSessionsMalformed() {
    let output = "incomplete\tdata\n"
    let sessions = TmuxParser.parseSessions(output)
    assertEqual(sessions.count, 0, "Should skip lines with fewer than 4 fields")
}

// MARK: - TmuxParser: Window Parsing Tests

func testParseWindowsSingle() {
    let output = "@0\t0\tzsh\t1\t/Users/test/project\n"
    let windows = TmuxParser.parseWindows(output)
    assertEqual(windows.count, 1)
    assertEqual(windows[0].windowId, "@0")
    assertEqual(windows[0].windowIndex, 0)
    assertEqual(windows[0].name, "zsh")
    assertTrue(windows[0].isActive)
    assertEqual(windows[0].currentPath, "/Users/test/project")
}

func testParseWindowsMultiple() {
    let output = """
    @0\t0\teditor\t1\t/Users/test/project
    @1\t1\tserver\t0\t/Users/test/project/api
    @2\t2\tlogs\t0\t
    """
    let windows = TmuxParser.parseWindows(output)
    assertEqual(windows.count, 3)

    assertEqual(windows[0].windowId, "@0")
    assertEqual(windows[0].name, "editor")
    assertTrue(windows[0].isActive)

    assertEqual(windows[1].windowId, "@1")
    assertEqual(windows[1].windowIndex, 1)
    assertEqual(windows[1].name, "server")
    assertFalse(windows[1].isActive)
    assertEqual(windows[1].currentPath, "/Users/test/project/api")

    assertEqual(windows[2].windowId, "@2")
    assertEqual(windows[2].windowIndex, 2)
    assertNil(windows[2].currentPath, "Empty path should be nil")
}

func testParseWindowsEmpty() {
    let windows = TmuxParser.parseWindows("")
    assertEqual(windows.count, 0)
}

// MARK: - TmuxParser: Pane Parsing Tests

func testParsePanesSingle() {
    let output = "%0\t/dev/ttys001\t1\t/Users/test/project\tzsh\n"
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 1)
    assertEqual(panes[0].paneId, "%0")
    assertEqual(panes[0].tty, "/dev/ttys001")
    assertTrue(panes[0].isActive)
    assertEqual(panes[0].currentPath, "/Users/test/project")
    assertEqual(panes[0].title, "zsh")
    assertNil(panes[0].lastActivity, "No activity field in 5-field format")
}

func testParsePanesMultiple() {
    let output = """
    %0\t/dev/ttys001\t1\t/Users/test\tzsh
    %1\t/dev/ttys002\t0\t/Users/test/src\tvim
    """
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 2)

    assertEqual(panes[0].paneId, "%0")
    assertTrue(panes[0].isActive)
    assertEqual(panes[0].title, "zsh")

    assertEqual(panes[1].paneId, "%1")
    assertFalse(panes[1].isActive)
    assertEqual(panes[1].title, "vim")
    assertEqual(panes[1].tty, "/dev/ttys002")
}

func testParsePanesEmptyOptionals() {
    let output = "%0\t\t0\t\t\n"
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 1)
    assertNil(panes[0].tty, "Empty tty should be nil")
    assertFalse(panes[0].isActive)
    assertNil(panes[0].currentPath, "Empty path should be nil")
    assertNil(panes[0].title, "Empty title should be nil")
}

func testParsePanesEmpty() {
    let panes = TmuxParser.parsePanes("")
    assertEqual(panes.count, 0)
}

func testParsePanesWithActivity() {
    let output = "%0\t/dev/ttys001\t1\t/Users/test\tzsh\t1710784200\n"
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 1)
    assertEqual(panes[0].paneId, "%0")
    assertEqual(panes[0].lastActivity, 1710784200.0)
}

func testParsePanesMultipleWithActivity() {
    let output = """
    %0\t/dev/ttys001\t1\t/Users/test\tzsh\t1710784200
    %1\t/dev/ttys002\t0\t/Users/test/src\tvim\t1710784195
    """
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 2)
    assertEqual(panes[0].lastActivity, 1710784200.0)
    assertEqual(panes[1].lastActivity, 1710784195.0)
}

func testParsePanesActivityEmptyField() {
    let output = "%0\t/dev/ttys001\t1\t/Users/test\tzsh\t\n"
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 1)
    assertNil(panes[0].lastActivity, "Empty activity field should be nil")
}

func testPaneFormatContainsActivity() {
    assertTrue(
        TmuxParser.paneFormat.contains("#{pane_activity}"),
        "Pane format should include pane_activity"
    )
}

// MARK: - SessionNaming Tests

func testSlugifySimple() {
    assertEqual(SessionNaming.slugify("den"), "den")
    assertEqual(SessionNaming.slugify("My Project"), "my-project")
    assertEqual(SessionNaming.slugify("hello_world"), "hello-world")
}

func testSlugifySpecialChars() {
    assertEqual(SessionNaming.slugify("feat/sidebar-v2"), "feat-sidebar-v2")
    assertEqual(SessionNaming.slugify("...leading"), "leading")
    assertEqual(SessionNaming.slugify("trailing..."), "trailing")
    assertEqual(SessionNaming.slugify("a--b"), "a-b", "Should collapse consecutive hyphens")
}

func testSlugifyUnicode() {
    assertEqual(SessionNaming.slugify("cafe123"), "cafe123")
}

func testSessionNameGeneration() {
    assertEqual(
        SessionNaming.sessionName(projectShortName: "den", worktree: "main"),
        "den/main"
    )
    assertEqual(
        SessionNaming.sessionName(projectShortName: "mp", worktree: "feat/sidebar"),
        "mp/sidebar"
    )
    assertEqual(
        SessionNaming.sessionName(projectShortName: "api", worktree: "feature/auth-flow"),
        "api/auth-flow"
    )
}

func testStripBranchPrefix() {
    assertEqual(SessionNaming.stripBranchPrefix("feature/auth"), "auth")
    assertEqual(SessionNaming.stripBranchPrefix("feat/sidebar"), "sidebar")
    assertEqual(SessionNaming.stripBranchPrefix("fix/crash"), "crash")
    assertEqual(SessionNaming.stripBranchPrefix("hotfix/urgent"), "urgent")
    assertEqual(SessionNaming.stripBranchPrefix("release/2.0"), "2.0")
    assertEqual(SessionNaming.stripBranchPrefix("main"), "main")
    assertEqual(SessionNaming.stripBranchPrefix("my-branch"), "my-branch")
}

func testSessionNameParsing() {
    let result = SessionNaming.parse("den/main")
    assertNotNil(result)
    assertEqual(result?.projectShortName, "den")
    assertEqual(result?.branchSlug, "main")
}

func testSessionNameParsingComplex() {
    let result = SessionNaming.parse("mp/sidebar-v2")
    assertNotNil(result)
    assertEqual(result?.projectShortName, "mp")
    assertEqual(result?.branchSlug, "sidebar-v2")
}

func testSessionNameParsingInvalid() {
    assertNil(SessionNaming.parse("regular-session"))
    assertNil(SessionNaming.parse("/no-project"))
    assertNil(SessionNaming.parse("no-branch/"))
    assertNil(SessionNaming.parse(""))
}

func testIsDenSession() {
    assertTrue(SessionNaming.isDenSession("den/main"))
    assertTrue(SessionNaming.isDenSession("a/b"))
    assertFalse(SessionNaming.isDenSession("dev"))
    assertFalse(SessionNaming.isDenSession(""))
}

// MARK: - TmuxSession Model Tests

func testTmuxSessionDenDetection() {
    let denSession = TmuxSession(sessionId: "$0", name: "den/main")
    assertTrue(denSession.isDenSession)
    assertEqual(denSession.projectShortName, "den")
    assertEqual(denSession.branchSlug, "main")

    let regularSession = TmuxSession(sessionId: "$1", name: "dev")
    assertFalse(regularSession.isDenSession)
    assertNil(regularSession.projectShortName)
    assertNil(regularSession.branchSlug)
}

// MARK: - Format String Tests

func testFormatStringsContainDelimiter() {
    let tab = TmuxParser.delimiter
    assertTrue(TmuxParser.sessionFormat.contains(tab), "Session format should use tab delimiter")
    assertTrue(TmuxParser.windowFormat.contains(tab), "Window format should use tab delimiter")
    assertTrue(TmuxParser.paneFormat.contains(tab), "Pane format should use tab delimiter")
}

func testSessionFormatFields() {
    assertTrue(TmuxParser.sessionFormat.contains("#{session_id}"))
    assertTrue(TmuxParser.sessionFormat.contains("#{session_name}"))
    assertTrue(TmuxParser.sessionFormat.contains("#{session_windows}"))
    assertTrue(TmuxParser.sessionFormat.contains("#{session_attached}"))
}

// MARK: - Pane with current command

func testParsePanesWithCurrentCommand() {
    let output = "%0\t/dev/ttys001\t1\t/Users/test\tzsh\t1710784200\tnode\t1710784100\n"
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 1)
    assertEqual(panes[0].currentCommand, "node")
    assertEqual(panes[0].startTime, 1710784100.0)
}

func testParsePanesWithEmptyCommandFields() {
    let output = "%0\t/dev/ttys001\t1\t/Users/test\tzsh\t1710784200\t\t\n"
    let panes = TmuxParser.parsePanes(output)
    assertEqual(panes.count, 1)
    assertNil(panes[0].currentCommand, "Empty command should be nil")
    assertNil(panes[0].startTime, "Empty start time should be nil")
}

func testPaneFormatContainsNewFields() {
    assertTrue(
        TmuxParser.paneFormat.contains("#{pane_current_command}"),
        "Pane format should include pane_current_command"
    )
    assertTrue(
        TmuxParser.paneFormat.contains("#{pane_start_time}"),
        "Pane format should include pane_start_time"
    )
}

// MARK: - Main

print("=== DenTmux Tests ===")

// Parser: Sessions
testParseSessionsSingle()
testParseSessionsMultiple()
testParseSessionsEmpty()
testParseSessionsMalformed()

// Parser: Windows
testParseWindowsSingle()
testParseWindowsMultiple()
testParseWindowsEmpty()

// Parser: Panes
testParsePanesSingle()
testParsePanesMultiple()
testParsePanesEmptyOptionals()
testParsePanesEmpty()
testParsePanesWithActivity()
testParsePanesMultipleWithActivity()
testParsePanesActivityEmptyField()
testPaneFormatContainsActivity()

// SessionNaming
testSlugifySimple()
testSlugifySpecialChars()
testSlugifyUnicode()
testSessionNameGeneration()
testStripBranchPrefix()
testSessionNameParsing()
testSessionNameParsingComplex()
testSessionNameParsingInvalid()
testIsDenSession()

// TmuxSession model
testTmuxSessionDenDetection()

// Format strings
testFormatStringsContainDelimiter()
testSessionFormatFields()

// Pane command fields
testParsePanesWithCurrentCommand()
testParsePanesWithEmptyCommandFields()
testPaneFormatContainsNewFields()

printResults()

if failCount > 0 {
    fflush(stdout)
    fatalError("Tests failed")
}
