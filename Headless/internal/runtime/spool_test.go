package runtime

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSpoolWatcherStreamsFromOffsetAndDetectsRotation(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "session.out")
	if err := os.WriteFile(path, []byte("abc"), 0o600); err != nil {
		t.Fatal(err)
	}

	bytesSeen := make(chan []byte, 8)
	rotated := make(chan struct{}, 1)
	watcher, err := NewSpoolWatcher(
		path,
		0,
		func(data []byte) { bytesSeen <- append([]byte(nil), data...) },
		func() { rotated <- struct{}{} },
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	watcher.Start()
	defer watcher.Close()

	collect := func(want string) {
		t.Helper()
		deadline := time.After(2 * time.Second)
		var received []byte
		for {
			select {
			case chunk := <-bytesSeen:
				received = append(received, chunk...)
				if string(received) == want {
					return
				}
			case <-deadline:
				t.Fatalf("watcher received %q, want %q", received, want)
			}
		}
	}

	collect("abc")
	if watcher.Offset() != 3 {
		t.Fatalf("offset = %d, want 3", watcher.Offset())
	}

	appendToFile(t, path, "def")
	collect("def")

	// In-place compaction: tmux's pipe keeps its O_APPEND descriptor, so the
	// watcher must re-base to zero and report the rotation.
	if err := os.Truncate(path, 0); err != nil {
		t.Fatal(err)
	}
	select {
	case <-rotated:
	case <-time.After(2 * time.Second):
		t.Fatal("rotation was not detected")
	}
	if watcher.Offset() != 0 {
		t.Fatalf("offset after rotation = %d, want 0", watcher.Offset())
	}
	appendToFile(t, path, "g")
	collect("g")
}

func TestSpoolWatcherRejectsOffsetBeyondSize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.out")
	if err := os.WriteFile(path, []byte("ab"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSpoolWatcher(path, 3, nil, nil, nil); err == nil {
		t.Fatal("offset beyond file size was accepted")
	}
}

func appendToFile(t *testing.T, path, data string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(data); err != nil {
		t.Fatal(err)
	}
}
