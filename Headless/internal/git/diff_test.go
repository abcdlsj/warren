package git

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiffWorkingTree(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	output, err := Diff(context.Background(), dir, "a.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "-a\n") || !strings.Contains(output, "+b\n") {
		t.Fatalf("diff = %q, want a -> b change", output)
	}
}

func TestDiffStaged(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "a.txt")
	output, err := Diff(context.Background(), dir, "a.txt", true, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "-a\n") || !strings.Contains(output, "+b\n") {
		t.Fatalf("staged diff = %q, want a -> b change", output)
	}
}

func TestDiffStagedFileHasNoUnstagedDiff(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "a.txt")
	output, err := Diff(context.Background(), dir, "a.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if output != "" {
		t.Fatalf("unstaged diff = %q, want empty for fully staged file", output)
	}
}

func TestDiffUntracked(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	output, err := Diff(context.Background(), dir, "new.txt", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "new file mode") || !strings.Contains(output, "+n") {
		t.Fatalf("untracked diff = %q, want new-file diff", output)
	}
}

func TestDiffCommit(t *testing.T) {
	dir := newRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitForTest(t, dir, "add", "a.txt")
	gitForTest(t, dir, "commit", "-m", "change a")
	output, err := Diff(context.Background(), dir, "a.txt", false, "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "-a\n") || !strings.Contains(output, "+b\n") {
		t.Fatalf("commit diff = %q, want a -> b change", output)
	}
}
