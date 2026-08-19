package git

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func gitForTest(t *testing.T, dir string, args ...string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git binary not available")
	}
	command := exec.Command("git", append([]string{"-C", dir}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
	return string(output)
}

func newRepository(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repository")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "init", "--quiet", "-b", "main")
	gitForTest(t, dir, "config", "user.email", "test@example.com")
	gitForTest(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "init")
	return dir
}

func TestStatusForReportsCleanTree(t *testing.T) {
	dir := newRepository(t)
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Branch != "main" {
		t.Fatalf("branch = %q, want main", status.Branch)
	}
	if len(status.Changes) != 0 {
		t.Fatalf("changes = %#v, want none", status.Changes)
	}
}

func TestStatusForReportsUntrackedAndModified(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []Change{
		{Path: "a.txt", Status: "M"},
		{Path: "new.txt", Status: "?"},
	}
	if len(status.Changes) != len(want) {
		t.Fatalf("changes = %#v, want %#v", status.Changes, want)
	}
	for i := range want {
		if status.Changes[i] != want[i] {
			t.Fatalf("changes[%d] = %#v, want %#v", i, status.Changes[i], want[i])
		}
	}
}

func TestLogAndBranchesAndCheckout(t *testing.T) {
	dir := newRepository(t)
	gitForTest(t, dir, "branch", "dev")
	gitForTest(t, dir, "checkout", "-q", "dev")
	if err := os.WriteFile(filepath.Join(dir, "dev.txt"), []byte("d\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "-A")
	gitForTest(t, dir, "commit", "-m", "dev commit")

	commits, err := Log(context.Background(), dir, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(commits) != 2 {
		t.Fatalf("commits = %d, want 2", len(commits))
	}
	if commits[0].Subject != "dev commit" || len(commits[0].Files) != 1 ||
		commits[0].Files[0] != (FileChange{Path: "dev.txt", Status: "A"}) {
		t.Fatalf("latest commit = %#v", commits[0])
	}

	branches, err := Branches(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, name := range branches.Local {
		if name == "dev" {
			found = true
		}
	}
	if !found {
		t.Fatalf("local branches = %#v, want dev", branches.Local)
	}

	if err := Checkout(context.Background(), dir, "main", false); err != nil {
		t.Fatal(err)
	}
	status, err := StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Branch != "main" {
		t.Fatalf("branch after checkout = %q, want main", status.Branch)
	}

	if err := Checkout(context.Background(), dir, "feature/new", true); err != nil {
		t.Fatal(err)
	}
	status, err = StatusFor(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Branch != "feature/new" {
		t.Fatalf("branch after create = %q, want feature/new", status.Branch)
	}
}

func TestPullFailsFastWhenDiverged(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git binary not available")
	}
	// Build a local clone pair so pull has a real remote to talk to.
	upstream := newRepository(t)
	clone := filepath.Join(t.TempDir(), "clone")
	gitForTest(t, filepath.Dir(upstream), "clone", "-q", upstream, clone)
	gitForTest(t, clone, "config", "user.email", "test@example.com")
	gitForTest(t, clone, "config", "user.name", "Test")

	// Upstream advances; local clone diverges.
	gitForTest(t, upstream, "checkout", "-q", "main")
	if err := os.WriteFile(filepath.Join(upstream, "u.txt"), []byte("u\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, upstream, "add", "-A")
	gitForTest(t, upstream, "commit", "-m", "upstream commit")
	if err := os.WriteFile(filepath.Join(clone, "c.txt"), []byte("c\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, clone, "add", "-A")
	gitForTest(t, clone, "commit", "-m", "local commit")

	_, err := Pull(context.Background(), clone)
	if err == nil {
		t.Fatal("pull --ff-only should fail on diverged history")
	}
	if !strings.Contains(err.Error(), "Not possible to fast-forward") {
		t.Fatalf("pull error = %q, want fast-forward hint", err.Error())
	}
}
