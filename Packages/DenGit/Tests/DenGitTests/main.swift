import Foundation
import DenGit

print("=== DenGit Tests ===")

// GitWorktreeParser tests
testParseWorktreeSingle()
testParseWorktreeMultiple()
testParseWorktreeDetached()
testParseWorktreeBare()
testParseWorktreeMixed()
testParseWorktreeEmpty()
testParseWorktreeWhitespaceOnly()
testParseWorktreeMalformedMissingHead()
testParseWorktreeMalformedMissingPath()
testParseWorktreeNoTrailingNewline()
testBranchNameExtraction()

// GitStatusParser tests
testParseStatusClean()
testParseStatusDirty()
testParseStatusStagedOnly()
testParseStatusModifiedOnly()
testParseStatusBothStagedAndModified()
testParseStatusUntrackedOnly()
testParseStatusAheadBehind()
testParseStatusNoUpstream()
testParseStatusRenameEntry()
testParseStatusEmpty()
testParseStatusIgnoredEntries()
testGitStatusInfoCleanStatic()
testGitStatusInfoIsDirtyComputed()

printResults()

if failCount > 0 {
    fatalError("Tests failed")
}
