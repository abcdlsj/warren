package server

import (
	"context"
	"sync"
	"testing"
)

// kindRecordingRuntime records which engine handled a session and implements
// the full runtime surface so it can be registered alongside others.
type kindRecordingRuntime struct {
	mu       sync.Mutex
	kind     string
	created  []string
	resized  int
	captured int
	killed   []string
}

func (r *kindRecordingRuntime) Create(_ context.Context, name, _, _ string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.created = append(r.created, name)
	return nil
}
func (r *kindRecordingRuntime) Exists(context.Context, string) bool { return true }
func (r *kindRecordingRuntime) Capture(context.Context, string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.captured++
	return []byte("snapshot"), nil
}
func (r *kindRecordingRuntime) Input(context.Context, string, []byte) error { return nil }
func (r *kindRecordingRuntime) Resize(context.Context, string, int, int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resized++
	return nil
}
func (r *kindRecordingRuntime) Kill(_ context.Context, name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.killed = append(r.killed, name)
	return nil
}

func newCoexistService(t *testing.T) (*Service, *kindRecordingRuntime, *kindRecordingRuntime) {
	t.Helper()
	state := newStateWithSession(t, "session-coexist", "warren_coexist")
	ghostlineRuntime := &kindRecordingRuntime{kind: "ghostline"}
	tmuxRuntime := &kindRecordingRuntime{kind: "tmux"}
	service := &Service{
		Store:          state,
		Runtime:        ghostlineRuntime,
		Runtimes:       map[string]Runtime{"ghostline": ghostlineRuntime, "tmux": tmuxRuntime},
		DefaultRuntime: "ghostline",
	}
	return service, ghostlineRuntime, tmuxRuntime
}

func TestCreateSessionRoutesToRequestedRuntime(t *testing.T) {
	service, ghostlineRuntime, tmuxRuntime := newCoexistService(t)
	workspace := service.Store.Snapshot().Workspaces[0]

	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "tmux")
	if err != nil {
		t.Fatalf("CreateSession tmux: %v", err)
	}
	if session.RuntimeKind != "tmux" {
		t.Fatalf("session runtimeKind = %q", session.RuntimeKind)
	}
	tmuxRuntime.mu.Lock()
	tmuxCreated := len(tmuxRuntime.created)
	tmuxRuntime.mu.Unlock()
	if tmuxCreated != 1 {
		t.Fatalf("tmux created = %d, want 1", tmuxCreated)
	}

	session, err = service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "")
	if err != nil {
		t.Fatalf("CreateSession default: %v", err)
	}
	if session.RuntimeKind != "ghostline" {
		t.Fatalf("default session runtimeKind = %q", session.RuntimeKind)
	}
	ghostlineRuntime.mu.Lock()
	ghostlineCreated := len(ghostlineRuntime.created)
	ghostlineRuntime.mu.Unlock()
	if ghostlineCreated != 1 {
		t.Fatalf("ghostline created = %d, want 1", ghostlineCreated)
	}
}

func TestSessionRoutesRuntimeOperations(t *testing.T) {
	service, ghostlineRuntime, tmuxRuntime := newCoexistService(t)
	workspace := service.Store.Snapshot().Workspaces[0]
	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "tmux")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	if err := service.RenameSession(session.ID, "renamed"); err != nil {
		t.Fatalf("RenameSession: %v", err)
	}
	// Kill must go to the tmux engine.
	if err := service.DeleteSession(context.Background(), session.ID); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	tmuxRuntime.mu.Lock()
	killed := tmuxRuntime.killed
	tmuxRuntime.mu.Unlock()
	if len(killed) != 1 {
		t.Fatalf("tmux killed = %v, want one", killed)
	}
	ghostlineRuntime.mu.Lock()
	ghostKilled := len(ghostlineRuntime.killed)
	ghostlineRuntime.mu.Unlock()
	if ghostKilled != 0 {
		t.Fatalf("ghostline killed = %d, want 0", ghostKilled)
	}
}

func TestSetDefaultRuntimePersistsAndValidates(t *testing.T) {
	service, _, _ := newCoexistService(t)
	settingsPath := t.TempDir() + "/settings.json"
	service.SettingsPath = settingsPath
	if err := service.SetDefaultRuntime("tmux"); err != nil {
		t.Fatalf("SetDefaultRuntime: %v", err)
	}
	if service.DefaultRuntime != "tmux" {
		t.Fatalf("default = %q", service.DefaultRuntime)
	}
	if err := service.SetDefaultRuntime("bogus"); err == nil {
		t.Fatal("bogus runtime accepted")
	}
}
