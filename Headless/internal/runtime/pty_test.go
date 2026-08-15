package runtime

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func newTestPTY(t *testing.T) *PTY {
	t.Helper()
	return NewPTY(t.TempDir())
}

func waitSpoolContains(t *testing.T, p *PTY, name, needle string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(p.SpoolPath(name))
		if err == nil && bytes.Contains(data, []byte(needle)) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	data, _ := os.ReadFile(p.SpoolPath(name))
	t.Fatalf("spool did not contain %q; got %q", needle, data)
}

func TestPTYCreateWritesSpoolAndCapture(t *testing.T) {
	runtimeAdapter := newTestPTY(t)
	ctx := context.Background()
	directory := t.TempDir()
	if err := runtimeAdapter.Create(ctx, "warren_test_capture", directory, "printf 'hello-pty\\r\\n'"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	waitSpoolContains(t, runtimeAdapter, "warren_test_capture", "hello-pty")

	snapshot, err := runtimeAdapter.Capture(ctx, "warren_test_capture")
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if !bytes.HasPrefix(snapshot, []byte("\x1b[3J\x1b[2J\x1b[H")) {
		t.Fatalf("capture missing screen reset prefix: %q", snapshot[:min(len(snapshot), 16)])
	}
	if !bytes.Contains(snapshot, []byte("hello-pty")) {
		t.Fatalf("capture missing output: %q", snapshot)
	}
}

func TestPTYInputReachesChild(t *testing.T) {
	runtimeAdapter := newTestPTY(t)
	ctx := context.Background()
	if err := runtimeAdapter.Create(ctx, "warren_test_input", t.TempDir(), "sh"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := runtimeAdapter.Input(ctx, "warren_test_input", []byte("echo pty-input-ok\r")); err != nil {
		t.Fatalf("Input: %v", err)
	}
	waitSpoolContains(t, runtimeAdapter, "warren_test_input", "pty-input-ok")
}

func TestPTYResize(t *testing.T) {
	runtimeAdapter := newTestPTY(t)
	ctx := context.Background()
	if err := runtimeAdapter.Create(ctx, "warren_test_resize", t.TempDir(), "sh"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := runtimeAdapter.Resize(ctx, "warren_test_resize", 80, 24); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	if err := runtimeAdapter.Input(ctx, "warren_test_resize", []byte("stty size\r")); err != nil {
		t.Fatalf("Input: %v", err)
	}
	// stty size prints "rows cols"; we resized to 80 columns x 24 rows.
	waitSpoolContains(t, runtimeAdapter, "warren_test_resize", "24 80")
}

func TestPTYKillEndsChild(t *testing.T) {
	runtimeAdapter := newTestPTY(t)
	ctx := context.Background()
	if err := runtimeAdapter.Create(ctx, "warren_test_kill", t.TempDir(), "sleep 30"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if !runtimeAdapter.Exists(ctx, "warren_test_kill") {
		t.Fatal("session should exist after Create")
	}
	pid := readPID(runtimeAdapter.PIDPath("warren_test_kill"))
	if pid <= 0 {
		t.Fatalf("expected a persisted pid, got %d", pid)
	}
	if err := runtimeAdapter.Kill(ctx, "warren_test_kill"); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	if runtimeAdapter.Exists(ctx, "warren_test_kill") {
		t.Fatal("session should not exist after Kill")
	}
	waitProcessGone(t, pid)
}

// TestPTYKillOrphan simulates a daemon restart: a fresh PTY instance shares
// the output directory but has no process handles, so Kill must fall back to
// the persisted pid file.
func TestPTYKillOrphan(t *testing.T) {
	directory := t.TempDir()
	original := NewPTY(directory)
	ctx := context.Background()
	if err := original.Create(ctx, "warren_test_orphan", t.TempDir(), "sleep 30"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	pid := readPID(original.PIDPath("warren_test_orphan"))
	if pid <= 0 {
		t.Fatalf("expected a persisted pid, got %d", pid)
	}

	restarted := NewPTY(directory)
	if restarted.Exists(ctx, "warren_test_orphan") {
		t.Fatal("restarted runtime must not know in-memory sessions")
	}
	created, err := restarted.ListCreated(ctx)
	if err != nil {
		t.Fatalf("ListCreated: %v", err)
	}
	if _, ok := created["warren_test_orphan"]; !ok {
		t.Fatalf("ListCreated missing orphan: %v", created)
	}
	if err := restarted.Kill(ctx, "warren_test_orphan"); err != nil {
		t.Fatalf("Kill orphan: %v", err)
	}
	waitProcessGone(t, pid)
}

func TestPTYRemoveSpoolCleansMetadata(t *testing.T) {
	runtimeAdapter := newTestPTY(t)
	ctx := context.Background()
	if err := runtimeAdapter.Create(ctx, "warren_test_cleanup", t.TempDir(), "sh"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	runtimeAdapter.RemoveSpool("warren_test_cleanup")
	for _, path := range []string{
		runtimeAdapter.SpoolPath("warren_test_cleanup"),
		runtimeAdapter.CreatedPath("warren_test_cleanup"),
		runtimeAdapter.PIDPath("warren_test_cleanup"),
	} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("expected %s to be removed, got %v", filepath.Base(path), err)
		}
	}
}

func waitProcessGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("process %d still alive", pid)
}
