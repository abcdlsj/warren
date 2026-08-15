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
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"`+directory+`"}}`+"\n",
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
	if err := runtime.Create(context.Background(), "runtime-agent", directory, ""); err != nil {
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

	initial := readAgentEvents(t, connection)
	if len(initial) != 1 {
		t.Fatalf("initial agent events = %#v, want 1", initial)
	}
	if initial[0]["type"] != "system" {
		t.Fatalf("initial event type = %#v", initial[0]["type"])
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

	live := readAgentEvents(t, connection)
	if len(live) != 1 || live[0]["content"] != "live prompt" {
		t.Fatalf("live agent events = %#v", live)
	}
	if history := service.agentHistory("session-agent"); len(history) != 2 {
		t.Fatalf("history length = %d, want 2", len(history))
	}
}

func readAgentEvents(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) []map[string]any {
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
			Type   string           `json:"t"`
			Events []map[string]any `json:"events"`
		}
		if json.Unmarshal(data, &message) != nil || message.Type != "agent" {
			continue
		}
		return message.Events
	}
}

func TestAgentHistoryIncludesInitialAndLiveEvents(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-agent.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(strings.Join([]string{
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"t","cwd":"` + directory + `"}}`,
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
	_ = runtime.Create(context.Background(), "runtime-history", directory, "")
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
