import Foundation
import DenGit

// MARK: - GitWorktreeParser Tests

func testParseWorktreeSingle() {
    let output = """
    worktree /Users/dev/project
    HEAD abc123def456789012345678901234567890abcd
    branch refs/heads/main

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 1)
    assertEqual(worktrees[0].path, "/Users/dev/project")
    assertEqual(worktrees[0].head, "abc123def456789012345678901234567890abcd")
    assertEqual(worktrees[0].branch, "refs/heads/main")
    assertFalse(worktrees[0].isDetached)
    assertFalse(worktrees[0].isBare)
    assertEqual(worktrees[0].branchName, "main")
}

func testParseWorktreeMultiple() {
    let output = """
    worktree /Users/dev/project
    HEAD abc123def456789012345678901234567890abcd
    branch refs/heads/main

    worktree /Users/dev/project-feature
    HEAD def789abc012345678901234567890abcdef1234
    branch refs/heads/feature-branch

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 2)

    assertEqual(worktrees[0].path, "/Users/dev/project")
    assertEqual(worktrees[0].branchName, "main")

    assertEqual(worktrees[1].path, "/Users/dev/project-feature")
    assertEqual(worktrees[1].head, "def789abc012345678901234567890abcdef1234")
    assertEqual(worktrees[1].branch, "refs/heads/feature-branch")
    assertEqual(worktrees[1].branchName, "feature-branch")
}

func testParseWorktreeDetached() {
    let output = """
    worktree /Users/dev/project-detached
    HEAD 111222333444555666777888999000aaabbbcccddd
    detached

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 1)
    assertEqual(worktrees[0].path, "/Users/dev/project-detached")
    assertTrue(worktrees[0].isDetached)
    assertNil(worktrees[0].branch)
    assertNil(worktrees[0].branchName)
}

func testParseWorktreeBare() {
    let output = """
    worktree /Users/dev/bare-repo
    HEAD abc123def456789012345678901234567890abcd
    bare

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 1)
    assertEqual(worktrees[0].path, "/Users/dev/bare-repo")
    assertTrue(worktrees[0].isBare)
    assertNil(worktrees[0].branch)
}

func testParseWorktreeMixed() {
    let output = """
    worktree /Users/dev/project
    HEAD abc123def456789012345678901234567890abcd
    branch refs/heads/main

    worktree /Users/dev/project-feature
    HEAD def789abc012345678901234567890abcdef1234
    branch refs/heads/feature-branch

    worktree /Users/dev/project-detached
    HEAD 111222333444555666777888999000aaabbbcccddd
    detached

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 3)

    assertFalse(worktrees[0].isDetached)
    assertEqual(worktrees[0].branchName, "main")

    assertFalse(worktrees[1].isDetached)
    assertEqual(worktrees[1].branchName, "feature-branch")

    assertTrue(worktrees[2].isDetached)
    assertNil(worktrees[2].branch)
}

func testParseWorktreeEmpty() {
    let worktrees = GitWorktreeParser.parse("")
    assertEqual(worktrees.count, 0)
}

func testParseWorktreeWhitespaceOnly() {
    let worktrees = GitWorktreeParser.parse("   \n\n  \n")
    assertEqual(worktrees.count, 0)
}

func testParseWorktreeMalformedMissingHead() {
    let output = """
    worktree /Users/dev/project

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 0, "Should skip entries missing HEAD")
}

func testParseWorktreeMalformedMissingPath() {
    let output = """
    HEAD abc123def456789012345678901234567890abcd
    branch refs/heads/main

    """
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 0, "Should skip entries missing worktree path")
}

func testParseWorktreeNoTrailingNewline() {
    let output = "worktree /Users/dev/project\nHEAD abc123\nbranch refs/heads/main"
    let worktrees = GitWorktreeParser.parse(output)
    assertEqual(worktrees.count, 1)
    assertEqual(worktrees[0].path, "/Users/dev/project")
    assertEqual(worktrees[0].head, "abc123")
}

func testBranchNameExtraction() {
    let info = GitWorktreeInfo(
        path: "/test",
        head: "abc",
        branch: "refs/heads/feature/sidebar-v2"
    )
    assertEqual(info.branchName, "feature/sidebar-v2")

    let noBranch = GitWorktreeInfo(path: "/test", head: "abc", isDetached: true)
    assertNil(noBranch.branchName)
}
