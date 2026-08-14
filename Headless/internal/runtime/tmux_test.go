package runtime

import (
	"bytes"
	"context"
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
