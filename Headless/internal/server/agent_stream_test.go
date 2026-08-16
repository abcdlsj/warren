package server

import (
	"context"
	"encoding/json"
	"fmt"
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

	initialActivity := readAgentActivity(t, connection)
	if initialActivity != api.AgentActivityReady {
		t.Fatalf("initial activity = %q, want ready", initialActivity)
	}
	initial := readAgentEvents(t, connection)
	if len(initial) != 1 {
		t.Fatalf("initial agent tail = %#v, want 1", initial)
	}
	if initial[0]["type"] != "assistant" {
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
	liveActivity := readAgentActivity(t, connection)
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

func readAgentActivity(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) api.AgentActivity {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	if err := connection.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("agent activity message never arrived: %v", err)
		}
		var message struct {
			Type     string            `json:"t"`
			Activity api.AgentActivity `json:"activity"`
		}
		if json.Unmarshal(data, &message) != nil || message.Type != "agent.activity" {
			continue
		}
		return message.Activity
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

func TestAgentHistoryPagePaginates(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-page"] = &agentSession{}
	service.agentsMu.Unlock()
	events := make([]api.AgentEvent, 5)
	for index := range events {
		events[index] = api.AgentEvent{
			Sequence: uint64(index + 1),
			Type:     "assistant",
			Content:  strings.Repeat("x", 64),
		}
	}
	service.recordAgentEvents("session-page", events, api.AgentActivityWorking)

	first := service.agentHistoryPage("session-page", 0, 2)
	if len(first.Events) != 2 || first.Events[0].Sequence != 4 || first.Events[1].Sequence != 5 {
		t.Fatalf("first page = %#v, want sequences 4,5", first.Events)
	}
	if first.Cursor != 4 || !first.HasMore {
		t.Fatalf("first page cursor=%d hasMore=%t, want cursor=4 hasMore=true", first.Cursor, first.HasMore)
	}

	second := service.agentHistoryPage("session-page", first.Cursor, 2)
	if len(second.Events) != 2 || second.Events[0].Sequence != 2 || second.Events[1].Sequence != 3 {
		t.Fatalf("second page = %#v, want sequences 2,3", second.Events)
	}
	if second.Cursor != 2 || !second.HasMore {
		t.Fatalf("second page cursor=%d hasMore=%t, want cursor=2 hasMore=true", second.Cursor, second.HasMore)
	}

	third := service.agentHistoryPage("session-page", second.Cursor, 2)
	if len(third.Events) != 1 || third.Events[0].Sequence != 1 {
		t.Fatalf("third page = %#v, want sequence 1", third.Events)
	}
	if third.Cursor != 1 || third.HasMore {
		t.Fatalf("third page cursor=%d hasMore=%t, want cursor=1 hasMore=false", third.Cursor, third.HasMore)
	}
}

func TestSplitAgentEventsBoundsBatches(t *testing.T) {
	events := make([]api.AgentEvent, 100)
	for index := range events {
		events[index] = api.AgentEvent{
			Sequence: uint64(index + 1),
			Type:     "assistant",
			Content:  strings.Repeat("x", 10*1024),
		}
	}
	batches := splitAgentEvents(events, 256*1024)
	if len(batches) < 2 {
		t.Fatalf("batches = %d, want multiple batches", len(batches))
	}
	total := 0
	for index, batch := range batches {
		total += len(batch)
		encoded, err := json.Marshal(api.AgentMessage{Type: "agent", Events: batch})
		if err != nil {
			t.Fatal(err)
		}
		if len(encoded) > 256*1024 {
			t.Fatalf("batch %d encoded %d bytes, want <= 256 KiB", index, len(encoded))
		}
	}
	if total != len(events) {
		t.Fatalf("split total = %d, want %d", total, len(events))
	}
}

func TestAgentTailIsBounded(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-tail"] = &agentSession{}
	service.agentsMu.Unlock()
	events := make([]api.AgentEvent, 200)
	for index := range events {
		events[index] = api.AgentEvent{
			Sequence: uint64(index + 1),
			Type:     "assistant",
			Content:  strings.Repeat("x", 4*1024),
		}
	}
	service.recordAgentEvents("session-tail", events, api.AgentActivityWorking)

	tail := service.agentTail("session-tail", agentAttachHistoryMaxEvents, agentAttachHistoryMaxBytes)
	if len(tail) > agentAttachHistoryMaxEvents {
		t.Fatalf("tail length = %d, want <= %d", len(tail), agentAttachHistoryMaxEvents)
	}
	encoded, err := json.Marshal(api.AgentMessage{Type: "agent", Events: tail})
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > agentAttachHistoryMaxBytes {
		t.Fatalf("tail encoded %d bytes, want <= %d", len(encoded), agentAttachHistoryMaxBytes)
	}
	if got := tail[len(tail)-1].Sequence; got != 200 {
		t.Fatalf("tail newest sequence = %d, want 200", got)
	}
}

func TestAgentHistoryOverWebSocket(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-history.jsonl")
	lines := make([]string, 3)
	for index := range lines {
		lines[index] = fmt.Sprintf(
			`{"timestamp":"2026-08-16T10:00:0%dZ","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello-%d"}]}}`,
			index, index,
		)
	}
	if err := os.WriteFile(transcriptPath, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-history-ws", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-history-ws", Lifecycle: "running", CreatedAt: time.Now().UTC(),
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
	_ = runtime.Create(context.Background(), "runtime-history-ws", directory, "", nil)
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
	for len(service.agentHistory("session-history-ws")) < 3 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if history := service.agentHistory("session-history-ws"); len(history) != 3 {
		t.Fatalf("history length = %d, want 3", len(history))
	}

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	result := requestResult[map[string]any](t, connection, "agent.history", map[string]any{
		"session": "session-history-ws",
		"limit":   2,
	})
	events, ok := result["events"].([]any)
	if !ok || len(events) != 2 {
		t.Fatalf("history events = %#v, want 2", result["events"])
	}
	first, ok := events[0].(map[string]any)
	if !ok || first["seq"] != float64(2) {
		t.Fatalf("first history event = %#v, want seq 2", events[0])
	}
	if result["cursor"] != float64(2) || result["hasMore"] != true {
		t.Fatalf("history metadata = cursor %v hasMore %v, want cursor 2 hasMore true", result["cursor"], result["hasMore"])
	}

	previous := requestResult[map[string]any](t, connection, "agent.history", map[string]any{
		"session": "session-history-ws",
		"before":  float64(2),
		"limit":   2,
	})
	previousEvents, ok := previous["events"].([]any)
	if !ok || len(previousEvents) != 1 {
		t.Fatalf("previous history events = %#v, want 1", previous["events"])
	}
	previousFirst, ok := previousEvents[0].(map[string]any)
	if !ok || previousFirst["seq"] != float64(1) {
		t.Fatalf("previous first event = %#v, want seq 1", previousEvents[0])
	}
	if previous["hasMore"] != false {
		t.Fatalf("previous history hasMore = %v, want false", previous["hasMore"])
	}
}
