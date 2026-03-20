import Foundation
import DenGit

// MARK: - GitStatusParser Tests

func testParseStatusClean() {
    let output = """
    # branch.oid abc123
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +0 -0
    """
    let status = GitStatusParser.parse(output)
    assertFalse(status.isDirty)
    assertEqual(status.branch, "main")
    assertEqual(status.upstream, "origin/main")
    assertEqual(status.ahead, 0)
    assertEqual(status.behind, 0)
    assertEqual(status.stagedCount, 0)
    assertEqual(status.modifiedCount, 0)
    assertEqual(status.untrackedCount, 0)
}

func testParseStatusDirty() {
    let output = """
    # branch.oid abc123
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +2 -1
    1 M. N... 100644 100644 100644 abc123 def456 src/file.swift
    1 .M N... 100644 100644 100644 abc123 def456 src/other.swift
    ? untracked-file.txt
    """
    let status = GitStatusParser.parse(output)
    assertTrue(status.isDirty)
    assertEqual(status.branch, "main")
    assertEqual(status.upstream, "origin/main")
    assertEqual(status.ahead, 2)
    assertEqual(status.behind, 1)
    assertEqual(status.stagedCount, 1, "M. has staged change")
    assertEqual(status.modifiedCount, 1, ".M has unstaged change")
    assertEqual(status.untrackedCount, 1)
}

func testParseStatusStagedOnly() {
    let output = """
    # branch.oid abc123
    # branch.head feature
    1 A. N... 000000 100644 100644 0000000 abc1234 new-file.swift
    1 M. N... 100644 100644 100644 abc123 def456 modified.swift
    """
    let status = GitStatusParser.parse(output)
    assertTrue(status.isDirty)
    assertEqual(status.stagedCount, 2)
    assertEqual(status.modifiedCount, 0)
    assertEqual(status.untrackedCount, 0)
    assertEqual(status.branch, "feature")
    assertNil(status.upstream, "No upstream header means nil")
}

func testParseStatusModifiedOnly() {
    let output = """
    # branch.oid abc123
    # branch.head main
    1 .M N... 100644 100644 100644 abc123 def456 src/file.swift
    1 .D N... 100644 100644 000000 abc123 000000 src/deleted.swift
    """
    let status = GitStatusParser.parse(output)
    assertTrue(status.isDirty)
    assertEqual(status.stagedCount, 0)
    assertEqual(status.modifiedCount, 2)
}

func testParseStatusBothStagedAndModified() {
    let output = """
    # branch.oid abc123
    # branch.head main
    1 MM N... 100644 100644 100644 abc123 def456 src/file.swift
    """
    let status = GitStatusParser.parse(output)
    assertTrue(status.isDirty)
    assertEqual(status.stagedCount, 1, "M in index position = staged")
    assertEqual(status.modifiedCount, 1, "M in worktree position = modified")
}

func testParseStatusUntrackedOnly() {
    let output = """
    # branch.oid abc123
    # branch.head main
    ? new-file.txt
    ? another-file.txt
    ? dir/nested.txt
    """
    let status = GitStatusParser.parse(output)
    assertTrue(status.isDirty)
    assertEqual(status.untrackedCount, 3)
    assertEqual(status.stagedCount, 0)
    assertEqual(status.modifiedCount, 0)
}

func testParseStatusAheadBehind() {
    let output = """
    # branch.oid abc123
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +5 -3
    """
    let status = GitStatusParser.parse(output)
    assertFalse(status.isDirty, "No file changes")
    assertEqual(status.ahead, 5)
    assertEqual(status.behind, 3)
}

func testParseStatusNoUpstream() {
    let output = """
    # branch.oid abc123
    # branch.head new-branch
    """
    let status = GitStatusParser.parse(output)
    assertEqual(status.branch, "new-branch")
    assertNil(status.upstream)
    assertEqual(status.ahead, 0)
    assertEqual(status.behind, 0)
}

func testParseStatusRenameEntry() {
    let output = """
    # branch.oid abc123
    # branch.head main
    2 R. N... 100644 100644 100644 abc123 def456 R100 new-name.swift\told-name.swift
    """
    let status = GitStatusParser.parse(output)
    assertEqual(status.stagedCount, 1, "R in index = staged rename")
    assertEqual(status.modifiedCount, 0)
}

func testParseStatusEmpty() {
    let status = GitStatusParser.parse("")
    assertFalse(status.isDirty)
    assertNil(status.branch)
    assertNil(status.upstream)
    assertEqual(status.ahead, 0)
    assertEqual(status.behind, 0)
}

func testParseStatusIgnoredEntries() {
    let output = """
    # branch.oid abc123
    # branch.head main
    ! .build/debug
    ! .derived-data/
    """
    let status = GitStatusParser.parse(output)
    assertFalse(status.isDirty, "Ignored entries should not make status dirty")
    assertEqual(status.untrackedCount, 0)
}

func testGitStatusInfoCleanStatic() {
    let clean = GitStatusInfo.clean
    assertFalse(clean.isDirty)
    assertEqual(clean.untrackedCount, 0)
    assertEqual(clean.modifiedCount, 0)
    assertEqual(clean.stagedCount, 0)
    assertEqual(clean.ahead, 0)
    assertEqual(clean.behind, 0)
    assertNil(clean.branch)
    assertNil(clean.upstream)
}

func testGitStatusInfoIsDirtyComputed() {
    let withStaged = GitStatusInfo(stagedCount: 1)
    assertTrue(withStaged.isDirty)

    let withModified = GitStatusInfo(modifiedCount: 1)
    assertTrue(withModified.isDirty)

    let withUntracked = GitStatusInfo(untrackedCount: 1)
    assertTrue(withUntracked.isDirty)

    let allZero = GitStatusInfo()
    assertFalse(allZero.isDirty)
}
