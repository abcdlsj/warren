package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type staticAgentFinder struct {
	path string
}

func (f staticAgentFinder) Find(context.Context, string, string, time.Time) (string, error) {
	return f.path, nil
}

func TestAgentTranscriptStreamsToWeb(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-agent.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-agent", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-agent", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()
	attachBrowser(t, connection, "session-agent", nil)
	readBrowserMessage(t, connection, "attached")
	readBinaryFrame(t, connection)
	readBrowserMessage(t, connection, "synced")

	initial, initialActivity := readAgentEvents(t, connection)
	if len(initial) != 1 {
		t.Fatalf("initial agent events = %#v, want 1", initial)
	}
	if initial[0]["type"] != "assistant" {
		t.Fatalf("initial event type = %#v", initial[0]["type"])
	}
	if initialActivity != api.AgentActivityReady {
		t.Fatalf("initial activity = %q, want ready", initialActivity)
	}

	file, err := os.OpenFile(transcriptPath, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"live prompt"}]}}` + "\n")
	closeErr := file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}

	live, liveActivity := readAgentEvents(t, connection)
	if len(live) != 1 || live[0]["content"] != "live prompt" {
		t.Fatalf("live agent events = %#v", live)
	}
	if liveActivity != api.AgentActivityWorking {
		t.Fatalf("live activity = %q, want working", liveActivity)
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == "session-agent" && candidate.AgentActivity != api.AgentActivityWorking {
			t.Fatalf("roster activity = %q, want working", candidate.AgentActivity)
		}
	}
	if history := service.agentHistory("session-agent"); len(history) != 2 {
		t.Fatalf("history length = %d, want 2", len(history))
	}
}

func TestEnsureAgentPrefersCodexBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-bound.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-bound","cwd":"`+directory+`"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	binding := agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-bound",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}
	if err := agent.WriteBinding(agent.BindPath("session-bound"), binding); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-bound", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-bound", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: filepath.Join(directory, "wrong-path.jsonl")},
	}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a bound watcher")
	}
	if got := entry.watcher.Path(); got != transcriptPath {
		t.Fatalf("watcher path = %q, want %q", got, transcriptPath)
	}
	current, _ := state.SnapshotVersion()
	if current.Sessions[0].AgentSessionID != "thread-bound" || current.Sessions[0].TranscriptPath != transcriptPath {
		t.Fatalf("session meta = %#v", current.Sessions[0])
	}
	entry.watcher.Close()
}

func TestEnsureAgentDerivesClaudePathFromSessionID(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(directory, "claude"))
	transcriptPath := agent.ClaudeTranscriptPath(agent.ClaudeProjectsRoot(), directory, "uuid-claude")
	if err := os.MkdirAll(filepath.Dir(transcriptPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(transcriptPath, []byte(
		`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":"Hello"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-claude", WorkspaceID: workspaceID, Title: "Claude", Kind: "claude",
		AgentSessionID: "uuid-claude", Runtime: "runtime-claude", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: filepath.Join(directory, "wrong-path.jsonl")},
	}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a bound watcher")
	}
	if got := entry.watcher.Path(); got != transcriptPath {
		t.Fatalf("watcher path = %q, want %q", got, transcriptPath)
	}
	entry.watcher.Close()
}

func TestEnsureAgentDoesNotStealAnotherSessionsTranscript(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-shared.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-a","cwd":"`+directory+`"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	sessionA := api.Session{
		ID: "session-a", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-a", Lifecycle: "running", TranscriptPath: transcriptPath, CreatedAt: time.Now().UTC(),
	}
	sessionB := api.Session{
		ID: "session-b", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-b", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{sessionA, sessionB}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), sessionB)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher != nil {
		t.Fatal("session B must not adopt a transcript already owned by session A")
	}
}

func TestAgentStateFileReflectsShellReturn(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	session := api.Session{
		ID: "session-agent", Title: "Codex", Kind: "codex",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	service := &Service{Store: state, Runtime: newSpoolRuntime(t)}
	service.lazyInit()

	statePath := agent.StatePath(session.ID)
	if err := agent.WriteAgentState(statePath, api.AgentActivityExited); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	if got := service.agentActivity(session.ID); got != api.AgentActivityExited {
		t.Fatalf("after SessionEnd state = %q, want exited", got)
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && candidate.AgentActivity != api.AgentActivityExited {
			t.Fatalf("roster activity = %q, want exited", candidate.AgentActivity)
		}
	}

	if err := agent.WriteAgentState(statePath, api.AgentActivityReady); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	if got := service.agentActivity(session.ID); got != api.AgentActivityReady {
		t.Fatalf("after new SessionStart state = %q, want ready", got)
	}
}

func readAgentEvents(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) ([]map[string]any, api.AgentActivity) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	if err := connection.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("agent message never arrived: %v", err)
		}
		var message struct {
			Type     string            `json:"t"`
			Activity api.AgentActivity `json:"activity"`
			Events   []map[string]any  `json:"events"`
		}
		if json.Unmarshal(data, &message) != nil || message.Type != "agent" {
			continue
		}
		return message.Events, message.Activity
	}
}

func TestAgentHistoryIncludesInitialAndLiveEvents(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-agent.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(strings.Join([]string{
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`,
	}, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-history", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-history", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newSpoolRuntime(t)
	_ = runtime.Create(context.Background(), "runtime-history", directory, "", nil)
	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for len(service.agentHistory("session-history")) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if history := service.agentHistory("session-history"); len(history) != 1 {
		t.Fatalf("history length = %d, want 1", len(history))
	}
}
