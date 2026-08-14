package server

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// spoolRuntime simulates the tmux adapter contract: output lives in one
// append-only file per session, input echoes into the same file, and pipe
// installation is idempotent.
type spoolRuntime struct {
	mu           sync.Mutex
	directory    string
	sessions     map[string]bool
	pipeInstalls map[string]int
	resizes      []recordedResize
}

func newSpoolRuntime(t *testing.T) *spoolRuntime {
	t.Helper()
	return &spoolRuntime{
		directory:    t.TempDir(),
		sessions:     map[string]bool{},
		pipeInstalls: map[string]int{},
	}
}

func (runtime *spoolRuntime) Create(_ context.Context, name, _, _ string) error {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	runtime.sessions[name] = true
	return os.WriteFile(runtime.SpoolPath(name), nil, 0o600)
}

func (runtime *spoolRuntime) Exists(_ context.Context, name string) bool {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	return runtime.sessions[name]
}

func (runtime *spoolRuntime) List(context.Context) (map[string]bool, error) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	result := make(map[string]bool, len(runtime.sessions))
	for name := range runtime.sessions {
		result[name] = true
	}
	return result, nil
}

func (runtime *spoolRuntime) Capture(_ context.Context, name string) ([]byte, error) {
	return os.ReadFile(runtime.SpoolPath(name))
}

func (runtime *spoolRuntime) Input(_ context.Context, name string, data []byte) error {
	file, err := os.OpenFile(runtime.SpoolPath(name), os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.Write(data)
	return err
}

func (runtime *spoolRuntime) Resize(_ context.Context, _ string, columns, rows int) error {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	runtime.resizes = append(runtime.resizes, recordedResize{columns: columns, rows: rows})
	return nil
}

func (runtime *spoolRuntime) Kill(_ context.Context, name string) error {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	delete(runtime.sessions, name)
	return nil
}

func (runtime *spoolRuntime) EnsurePipe(_ context.Context, name string) error {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if !runtime.sessions[name] {
		return os.ErrNotExist
	}
	runtime.pipeInstalls[name]++
	return nil
}

func (runtime *spoolRuntime) SpoolPath(name string) string {
	return filepath.Join(runtime.directory, name+".out")
}

func (runtime *spoolRuntime) SpoolSize(_ context.Context, name string) (int64, error) {
	info, err := os.Stat(runtime.SpoolPath(name))
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

func (runtime *spoolRuntime) TruncateSpool(_ context.Context, name string) error {
	return os.Truncate(runtime.SpoolPath(name), 0)
}

func (runtime *spoolRuntime) ArchiveSpool(context.Context, string) error { return nil }

func (runtime *spoolRuntime) RemoveSpool(name string) {
	_ = os.Remove(runtime.SpoolPath(name))
}

func TestStreamedAttachReplaysTailAndNeverDuplicates(t *testing.T) {
	state := newStateWithSession(t, "session-stream", "runtime-stream")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-stream", t.TempDir(), ""); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(runtime.SpoolPath("runtime-stream"), []byte("welcome\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnection(t, httpServer.URL, "/ws")
	defer connection.Close()

	attachBrowser(t, connection, "session-stream", nil)
	attached := readBrowserMessage(t, connection, "attached")
	if attached["reanchor"] != true {
		t.Fatalf("first attach should reanchor, got %#v", attached)
	}
	firstSnapshot := readBinaryFrame(t, connection)
	if string(firstSnapshot.Payload) != "welcome\r\n" {
		t.Fatalf("snapshot payload = %q", firstSnapshot.Payload)
	}
	synced := readBrowserMessage(t, connection, "synced")
	anchor := anchorFromMessage(t, synced)

	writeRawInput(t, connection, []byte("echo one\r"))
	first := readBinaryFrame(t, connection)
	if first.Sequence != anchor.Sequence || string(first.Payload) != "echo one\r" {
		t.Fatalf("first live frame = %#v", first)
	}
	anchor = anchorAfter(first)

	sendDetach(t, connection)
	if err := runtime.Input(context.Background(), "runtime-stream", []byte("echo two\r")); err != nil {
		t.Fatal(err)
	}
	waitForRingUpper(t, service, "session-stream", 27)

	attachBrowser(t, connection, "session-stream", &anchor)
	attached = readBrowserMessage(t, connection, "attached")
	if attached["reanchor"] == true {
		t.Fatalf("tail recovery must not reanchor, got %#v", attached)
	}
	delta := readBinaryFrame(t, connection)
	if delta.Sequence != anchor.Sequence || string(delta.Payload) != "echo two\r" {
		t.Fatalf("recovery delta = %#v", delta)
	}
	readBrowserMessage(t, connection, "synced")

	// No second copy of the delta may arrive after synced.
	if err := connection.SetReadDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	kind, _, err := connection.ReadMessage()
	if err == nil && kind == websocket.BinaryMessage {
		t.Fatal("duplicate output arrived after recovery")
	}
	_ = connection.SetReadDeadline(time.Time{})
}

func waitForRingUpper(t *testing.T, service *Service, sessionID string, want uint64) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		service.outputMu.Lock()
		outputSession := service.outputs[sessionID]
		service.outputMu.Unlock()
		if outputSession != nil {
			outputSession.mu.Lock()
			upper := outputSession.ring.Upper()
			outputSession.mu.Unlock()
			if upper >= want {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("ring upper never reached %d", want)
}

func TestRepeatedAttachInstallsPipeOnce(t *testing.T) {
	state := newStateWithSession(t, "session-pipe", "runtime-pipe")
	runtime := newSpoolRuntime(t)
	_ = runtime.Create(context.Background(), "runtime-pipe", t.TempDir(), "")
	service := &Service{Store: state, Runtime: runtime}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnection(t, httpServer.URL, "/ws")
	defer connection.Close()
	for attempt := 0; attempt < 2; attempt++ {
		attachBrowser(t, connection, "session-pipe", nil)
		readBrowserMessage(t, connection, "attached")
		readBrowserMessage(t, connection, "synced")
		sendDetach(t, connection)
	}
	runtime.mu.Lock()
	installs := runtime.pipeInstalls["runtime-pipe"]
	runtime.mu.Unlock()
	if installs != 1 {
		t.Fatalf("pipe installs = %d, want exactly 1", installs)
	}
}

func TestSlowClientOverflowClosesOnlyThatPeer(t *testing.T) {
	state, _ := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	service := &Service{Store: state, Runtime: newSpoolRuntime(t)}
	service.lazyInit()
	peer := &wsPeer{
		server:   &HTTPServer{Service: service},
		outbound: make(chan outboundMessage, 4),
		closed:   make(chan struct{}),
	}
	peer.attached = &api.Session{ID: "slow-session"}
	service.peers["slow-session"] = map[*wsPeer]struct{}{peer: {}}

	filled := 0
	for peer.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: []byte("x")}) {
		filled++
	}
	if filled != 4 {
		t.Fatalf("queue accepted %d items, want 4", filled)
	}
	select {
	case <-peer.closed:
	default:
		t.Fatal("overflow did not close the slow peer")
	}
	service.outputMu.Lock()
	_, stillRegistered := service.peers["slow-session"][peer]
	service.outputMu.Unlock()
	if stillRegistered {
		t.Fatal("overflow closed peer but left it registered")
	}
}

func TestLifecycleAdoptsLiveAndMarksMissingEnded(t *testing.T) {
	state := newStateWithSession(t, "session-live", "runtime-live")
	_ = state.Update(func(value *api.State) error {
		value.Sessions = append(value.Sessions, api.Session{
			ID: "session-gone", Runtime: "runtime-gone", Lifecycle: "running",
			CreatedAt: time.Now().UTC(),
		})
		return nil
	})
	runtime := newSpoolRuntime(t)
	_ = runtime.Create(context.Background(), "runtime-live", t.TempDir(), "")
	service := &Service{Store: state, Runtime: runtime}

	ctx, cancel := context.WithCancel(context.Background())
	service.Start(ctx)
	defer cancel()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		service.outputMu.Lock()
		adopted := service.outputs["session-live"] != nil
		service.outputMu.Unlock()
		snapshot := state.Snapshot()
		goneEnded := false
		for _, session := range snapshot.Sessions {
			if session.ID == "session-gone" && session.Lifecycle == "ended" {
				goneEnded = true
			}
		}
		if adopted && goneEnded {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	service.outputMu.Lock()
	adopted := service.outputs["session-live"] != nil
	service.outputMu.Unlock()
	snapshot := state.Snapshot()
	goneEnded := false
	for _, session := range snapshot.Sessions {
		if session.ID == "session-gone" && session.Lifecycle == "ended" {
			goneEnded = true
		}
	}
	if !adopted || !goneEnded {
		t.Fatalf("adopted=%t goneEnded=%t", adopted, goneEnded)
	}
}

func TestExplicitDeleteKillsTmuxAndRemovesSpool(t *testing.T) {
	state := newStateWithSession(t, "session-delete", "runtime-delete")
	runtime := newSpoolRuntime(t)
	_ = runtime.Create(context.Background(), "runtime-delete", t.TempDir(), "")
	service := &Service{Store: state, Runtime: runtime}
	if err := service.DeleteSession(context.Background(), "session-delete"); err != nil {
		t.Fatal(err)
	}
	if runtime.Exists(context.Background(), "runtime-delete") {
		t.Fatal("explicit delete did not kill tmux")
	}
	if _, err := os.Stat(runtime.SpoolPath("runtime-delete")); err == nil {
		t.Fatal("explicit delete did not remove the output spool")
	}
}

func newStateWithSession(t *testing.T, sessionID, runtimeName string) *store.Store {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: "/tmp", Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{{
			ID: sessionID, WorkspaceID: workspaceID, Title: "Shell", Kind: "shell",
			Runtime: runtimeName, Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return state
}

func attachBrowser(t *testing.T, connection *websocket.Conn, sessionID string, anchor *output.Anchor) {
	t.Helper()
	message := api.Envelope{Type: "attach", Session: sessionID}
	if anchor != nil {
		message.Epoch = anchor.Epoch
		message.Sequence = anchor.Sequence
	}
	if err := connection.WriteJSON(message); err != nil {
		t.Fatal(err)
	}
}

func sendDetach(t *testing.T, connection *websocket.Conn) {
	t.Helper()
	if err := connection.WriteJSON(api.Envelope{Type: "detach"}); err != nil {
		t.Fatal(err)
	}
}

func writeRawInput(t *testing.T, connection *websocket.Conn, data []byte) {
	t.Helper()
	if err := connection.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatal(err)
	}
}

func readBinaryFrame(t *testing.T, connection *websocket.Conn) output.DecodedFrame {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	_ = connection.SetReadDeadline(deadline)
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.BinaryMessage {
			continue
		}
		frame, err := output.DecodeOutput(data)
		if err != nil {
			t.Fatalf("decode output frame: %v", err)
		}
		return frame
	}
}

func anchorFromMessage(t *testing.T, message map[string]any) output.Anchor {
	t.Helper()
	epoch, ok := message["epoch"].(float64)
	sequence, okSequence := message["sequence"].(float64)
	if !ok || !okSequence {
		t.Fatalf("message has no anchor: %#v", message)
	}
	return output.Anchor{Epoch: uint64(epoch), Sequence: uint64(sequence)}
}

func anchorAfter(frame output.DecodedFrame) output.Anchor {
	return output.Anchor{
		Epoch:    frame.Epoch,
		Sequence: frame.Sequence + uint64(len(frame.Payload)),
	}
}
