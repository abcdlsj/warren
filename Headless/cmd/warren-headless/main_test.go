package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadOrCreateTokenRepairsDeletedParentDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".warren", "token")

	first, err := loadOrCreateToken(path)
	if err != nil {
		t.Fatalf("create token: %v", err)
	}
	if first == "" {
		t.Fatal("created an empty token")
	}

	if err := os.RemoveAll(filepath.Dir(path)); err != nil {
		t.Fatalf("remove token directory: %v", err)
	}
	if err := ensureTokenFile(path, first); err != nil {
		t.Fatalf("repair token: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read repaired token: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != first {
		t.Fatalf("repaired token = %q, want %q", got, first)
	}
}

func TestEnsureTokenFileRestoresOwnedTokenAfterReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := writeTokenFile(path, "owned-token"); err != nil {
		t.Fatalf("write initial token: %v", err)
	}
	if err := os.WriteFile(path, []byte("other-token\n"), 0o600); err != nil {
		t.Fatalf("replace token: %v", err)
	}

	if err := ensureTokenFile(path, "owned-token"); err != nil {
		t.Fatalf("restore owned token: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read restored token: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != "owned-token" {
		t.Fatalf("restored token = %q, want owned-token", got)
	}
}

func TestReplaceWithSymlinkPointsStableAtTarget(t *testing.T) {
	dir := t.TempDir()
	stable := filepath.Join(dir, "ghostline.sock")
	target := filepath.Join(dir, "ghostline-1.sock")
	if err := os.WriteFile(stable, nil, 0o600); err != nil {
		t.Fatalf("create old socket path: %v", err)
	}
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatalf("create target path: %v", err)
	}
	if err := replaceWithSymlink(stable, target); err != nil {
		t.Fatalf("replaceWithSymlink: %v", err)
	}
	info, err := os.Lstat(stable)
	if err != nil {
		t.Fatalf("lstat stable: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("stable is not a symlink: %v", info.Mode())
	}
	resolved, err := filepath.EvalSymlinks(stable)
	if err != nil {
		t.Fatalf("eval symlink: %v", err)
	}
	targetResolved, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatalf("eval target: %v", err)
	}
	if resolved != targetResolved {
		t.Fatalf("stable resolves to %q, want %q", resolved, targetResolved)
	}
}
