package git

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMainBranchFallsBackToMaster(t *testing.T) {
	dir := newRepository(t)
	if got := MainBranch(context.Background(), dir); got != "" {
		t.Fatalf("MainBranch with no remote refs = %q, want empty", got)
	}
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/master", "HEAD")
	if got := MainBranch(context.Background(), dir); got != "refs/remotes/origin/master" {
		t.Fatalf("MainBranch = %q, want origin/master", got)
	}
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	if got := MainBranch(context.Background(), dir); got != "refs/remotes/origin/main" {
		t.Fatalf("MainBranch = %q, want origin/main", got)
	}
}

func TestIsMergedAndLogRange(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "checkout", "-b", "dev")
	if err := os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "dev change")
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "main")

	mainRef := "refs/remotes/origin/main"
	if merged, err := IsMerged(context.Background(), dir, mainRef); err != nil || merged {
		t.Fatalf("IsMerged = %v, %v, want false", merged, err)
	}
	unmerged, err := LogRange(context.Background(), dir, mainRef)
	if err != nil {
		t.Fatal(err)
	}
	if len(unmerged) != 1 || unmerged[0].Subject != "dev change" {
		t.Fatalf("unmerged = %#v, want only the dev commit", unmerged)
	}

	gitForTest(t, dir, "checkout", "main")
	gitForTest(t, dir, "merge", "--ff-only", "dev")
	gitForTest(t, dir, "checkout", "dev")
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "main")
	if merged, err := IsMerged(context.Background(), dir, mainRef); err != nil || !merged {
		t.Fatalf("IsMerged after merge = %v, %v, want true", merged, err)
	}
	unmerged, err = LogRange(context.Background(), dir, mainRef)
	if err != nil {
		t.Fatal(err)
	}
	if len(unmerged) != 0 {
		t.Fatalf("unmerged after merge = %#v, want none", unmerged)
	}
}

func TestOperationStateDetectsInProgressOperations(t *testing.T) {
	dir := newRepository(t)
	if got := OperationState(context.Background(), dir); got != "" {
		t.Fatalf("OperationState idle = %q, want empty", got)
	}
	gitDir := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "--absolute-git-dir"))
	rebaseDir := filepath.Join(gitDir, "rebase-merge")
	if err := os.MkdirAll(filepath.Join(rebaseDir, "interactive"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := OperationState(context.Background(), dir); got != "rebase" {
		t.Fatalf("OperationState = %q, want rebase", got)
	}
}

func TestRebaseMain(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "checkout", "-b", "dev")
	if err := os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "dev change")
	gitForTest(t, dir, "checkout", "main")
	if err := os.WriteFile(filepath.Join(dir, "c.txt"), []byte("c\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "main change")
	gitForTest(t, dir, "update-ref", "refs/remotes/origin/main", "main")
	gitForTest(t, dir, "checkout", "dev")
	mainRef := "refs/remotes/origin/main"

	if err := RebaseMain(context.Background(), dir, mainRef); err != nil {
		t.Fatalf("RebaseMain on clean tree = %v, want nil", err)
	}
	gitForTest(t, dir, "merge-base", "--is-ancestor", "main", "HEAD")
	if got := strings.TrimSpace(gitForTest(t, dir, "rev-list", "--count", mainRef+"..HEAD")); got != "1" {
		t.Fatalf("unmerged after rebase = %s, want only the dev commit", got)
	}

	if err := os.WriteFile(filepath.Join(dir, "dirty.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RebaseMain(context.Background(), dir, mainRef); err == nil {
		t.Fatal("RebaseMain on dirty tree = nil, want error")
	}
	gitForTest(t, dir, "clean", "-f")

	gitDir := strings.TrimSpace(gitForTest(t, dir, "rev-parse", "--absolute-git-dir"))
	if err := os.MkdirAll(filepath.Join(gitDir, "rebase-merge"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := RebaseMain(context.Background(), dir, mainRef); err == nil {
		t.Fatal("RebaseMain during rebase = nil, want error")
	}
	os.RemoveAll(filepath.Join(gitDir, "rebase-merge"))

	gitForTest(t, dir, "checkout", "main")
	if err := RebaseMain(context.Background(), dir, mainRef); err == nil {
		t.Fatal("RebaseMain on the main line = nil, want error")
	}
}
