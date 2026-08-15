package runtime

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

func TestParseCaptureWithCursor(t *testing.T) {
	capture, cursorX, cursorY, err := parseCaptureWithCursor([]byte("7,3\nfirst\nsecond\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cursorX != 7 || cursorY != 3 {
		t.Fatalf("cursor = (%d, %d), want (7, 3)", cursorX, cursorY)
	}
	if string(capture) != "first\nsecond\n" {
		t.Fatalf("capture = %q", capture)
	}

	for _, input := range []string{"", "7\nbody", "x,3\nbody", "7,x\nbody", "-1,3\nbody", "7,-1\nbody"} {
		t.Run("invalid "+input, func(t *testing.T) {
			if _, _, _, err := parseCaptureWithCursor([]byte(input)); err == nil {
				t.Fatalf("parseCaptureWithCursor(%q) unexpectedly succeeded", input)
			}
		})
	}
}

func TestRenderCaptureSnapshotRestoresCursorAndDoesNotAddFinalRow(t *testing.T) {
	got := renderCaptureSnapshot([]byte("prompt\noutput\n"), 4, 2)
	want := []byte("\x1b[3J\x1b[2J\x1b[Hprompt\r\noutput\x1b[3;5H")
	if !bytes.Equal(got, want) {
		t.Fatalf("renderCaptureSnapshot() = %q, want %q", got, want)
	}
}

func TestTmuxKeyNameMapsTerminalSequences(t *testing.T) {
	cases := map[string]string{
		"\x1b[A":    "Up",
		"\x1bOA":    "Up",
		"\x1b[B":    "Down",
		"\x1b[C":    "Right",
		"\x1b[D":    "Left",
		"\x1b[H":    "Home",
		"\x1b[F":    "End",
		"\x1b[5~":   "PageUp",
		"\x1b[6~":   "PageDown",
		"\x1b[3~":   "DC",
		"\x1b[1;2A": "S-Up",
		"\x1b[1;5B": "C-Down",
		"\x1b[1;3C": "M-Right",
		"\x1b[Z":    "BTab",
		"\x1b[11~":  "F1",
		"\r":        "Enter",
		"\t":        "Tab",
		"\x7f":      "BSpace",
	}
	for input, want := range cases {
		got, ok := tmuxKeyName([]byte(input))
		if !ok || got != want {
			t.Fatalf("tmuxKeyName(%q) = (%q, %v), want (%q, true)", input, got, ok, want)
		}
	}
	for _, input := range []string{"hello", "\n", "\x1b[99~", "\x1b[1;9A", "abc\x1b[A"} {
		if got, ok := tmuxKeyName([]byte(input)); ok {
			t.Fatalf("tmuxKeyName(%q) = (%q, true), want false", input, got)
		}
	}
}

func TestRenderCaptureSnapshotPreservesEmptyRowsAndCRLF(t *testing.T) {
	got := renderCaptureSnapshot([]byte("prompt\r\n\r\n"), 0, 1)
	want := []byte("\x1b[3J\x1b[2J\x1b[Hprompt\r\n\x1b[2;1H")
	if !bytes.Equal(got, want) {
		t.Fatalf("renderCaptureSnapshot() = %q, want %q", got, want)
	}
}

func TestCaptureUsesRealTmuxCursorAndSingleCommandSnapshot(t *testing.T) {
	binary, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux is not installed")
	}

	name := "warren_capture_" + strconv.FormatInt(time.Now().UnixNano(), 10)
	tmux := Tmux{Binary: binary, Socket: name}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := tmux.Create(ctx, name, t.TempDir(), "bash --noprofile --norc"); err != nil {
		t.Fatal(err)
	}
	defer tmux.Kill(context.Background(), name)

	// Leave the shell blocked after moving its cursor, so the cursor cannot be
	// changed by the next prompt before Capture reads it.
	if err := tmux.Input(ctx, name, []byte("printf '\\033[3;7Hmark'; sleep 2\n")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	snapshot, err := tmux.Capture(ctx, name)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(snapshot, []byte("mark")) {
		t.Fatalf("snapshot does not contain tmux content: %q", snapshot)
	}
	if !bytes.HasPrefix(snapshot, []byte("\x1b[3J\x1b[2J\x1b[H")) {
		t.Fatalf("snapshot does not reset the terminal: %q", snapshot[:min(len(snapshot), 32)])
	}
	if !bytes.HasSuffix(snapshot, []byte("\x1b[3;11H")) {
		t.Fatalf("snapshot does not restore tmux cursor: %q", snapshot[len(snapshot)-min(len(snapshot), 32):])
	}
}

func TestListCreatedReturnsSessionCreationTimestamps(t *testing.T) {
	binary, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux is not installed")
	}

	name := "warren_list_" + strconv.FormatInt(time.Now().UnixNano(), 10)
	tmux := Tmux{Binary: binary, Socket: name}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := tmux.Create(ctx, name, t.TempDir(), "bash --noprofile --norc"); err != nil {
		t.Fatal(err)
	}
	defer tmux.Kill(context.Background(), name)

	created, err := tmux.ListCreated(ctx)
	if err != nil {
		t.Fatal(err)
	}
	createdAt, ok := created[name]
	if !ok {
		t.Fatalf("ListCreated() = %v, missing %s", created, name)
	}
	if age := time.Since(createdAt); age < 0 || age > time.Minute {
		t.Fatalf("ListCreated() timestamp %v is not near now", createdAt)
	}
}

func TestNormalizeCaptureOutput(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "lf only", input: "first\nsecond\n", want: "first\r\nsecond\r\n"},
		{name: "existing crlf", input: "first\r\nsecond\r\n", want: "first\r\nsecond\r\n"},
		{name: "mixed endings", input: "first\nsecond\r\nthird", want: "first\r\nsecond\r\nthird"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := normalizeCaptureOutput([]byte(test.input))
			if !bytes.Equal(got, []byte(test.want)) {
				t.Fatalf("normalizeCaptureOutput(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestEnsurePipeDoesNotCloseExistingPipe(t *testing.T) {
	binary, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux is not installed")
	}

	name := "warren_pipe_" + strconv.FormatInt(time.Now().UnixNano(), 10)
	tmux := Tmux{Binary: binary, Socket: name, OutputDir: t.TempDir()}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := tmux.Create(ctx, name, t.TempDir(), "bash --noprofile --norc"); err != nil {
		t.Fatal(err)
	}
	defer tmux.Kill(context.Background(), name)

	if err := tmux.EnsurePipe(ctx, name); err != nil {
		t.Fatal(err)
	}
	pane, err := tmux.PaneTarget(ctx, name)
	if err != nil {
		t.Fatal(err)
	}
	hasPipe := func() bool {
		value, err := tmux.paneHasPipe(ctx, pane)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	if !hasPipe() {
		t.Fatal("output pipe was not installed")
	}

	// Regression: `pipe-pane -o` toggles and closes the pipe on tmux 3.5a.
	// Re-ensuring after adoption must keep the pipe installed.
	if err := tmux.EnsurePipe(ctx, name); err != nil {
		t.Fatal(err)
	}
	if !hasPipe() {
		t.Fatal("re-ensure closed an existing output pipe")
	}

	spool := tmux.SpoolPath(name)
	if err := tmux.Input(ctx, name, []byte("echo pipe-ok\n")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(spool)
		if bytes.Contains(data, []byte("pipe-ok")) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("spool %s did not receive output after re-ensure", spool)
}
