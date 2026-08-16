package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestEnsureAgentAdoptsShellBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentState(agent.StatePath(session.ID), api.AgentActivityReady); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a watcher for the shell overlay")
	}
	if got := entry.watcher.Path(); got != transcriptPath {
		t.Fatalf("watcher path = %q, want %q", got, transcriptPath)
	}
	if got := service.agentActivity(session.ID); got != api.AgentActivityReady {
		t.Fatalf("activity = %q, want ready", got)
	}
	current := state.Snapshot()
	if current.Sessions[0].AgentSessionID != "thread-shell" || current.Sessions[0].TranscriptPath != transcriptPath {
		t.Fatalf("shell session meta = %#v", current.Sessions[0])
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && candidate.AgentActivity != api.AgentActivityReady {
			t.Fatalf("roster activity = %q, want ready", candidate.AgentActivity)
		}
	}
	entry.watcher.Close()
}

func TestEnsureAgentClearsShellBindingOnExit(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "claude",
		SessionID:      "claude-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentState(agent.StatePath(session.ID), api.AgentActivityReady); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentState(agent.StatePath(session.ID), api.AgentActivityExited); err != nil {
		t.Fatal(err)
	}

	active := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), active)
	if err != nil {
		t.Fatal(err)
	}
	if entry != nil {
		t.Fatal("shell overlay must be torn down after SessionEnd")
	}
	current := state.Snapshot()
	if current.Sessions[0].AgentSessionID != "" || current.Sessions[0].TranscriptPath != "" {
		t.Fatalf("shell session meta was not cleared: %#v", current.Sessions[0])
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == active.ID && candidate.AgentActivity != "" {
			t.Fatalf("roster activity = %q, want empty", candidate.AgentActivity)
		}
	}
}

func TestPlainShellSessionHasNoAgentActivity(t *testing.T) {
	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", t.TempDir(), "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry != nil {
		t.Fatal("plain shell must not start an agent watcher")
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && candidate.AgentActivity != "" {
			t.Fatalf("plain shell activity = %q, want empty", candidate.AgentActivity)
		}
	}
}

func TestAgentLivenessClearsShellOverlayAfterExit(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(transcriptPath, old, old); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:   state,
		Runtime: runtime,
		AgentLiveness: func(context.Context, string) bool {
			return false
		},
	}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentState(agent.StatePath(session.ID), api.AgentActivityReady); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if got := service.agentActivity(session.ID); got != api.AgentActivityReady {
		t.Fatalf("activity before liveness = %q, want ready", got)
	}

	service.applyAgentLiveness(context.Background(), session)
	stateValue, err := agent.ReadAgentState(agent.StatePath(session.ID))
	if err != nil {
		t.Fatal(err)
	}
	if stateValue != api.AgentActivityExited {
		t.Fatalf("state after liveness = %q, want exited", stateValue)
	}
	active := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), active)
	if err != nil {
		t.Fatal(err)
	}
	if entry != nil {
		t.Fatal("shell overlay must be torn down after liveness exit")
	}
	if got := service.agentActivity(session.ID); got != "" {
		t.Fatalf("activity after clear = %q, want empty", got)
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && candidate.AgentActivity != "" {
			t.Fatalf("roster activity = %q, want empty", candidate.AgentActivity)
		}
	}
}

func TestAgentLivenessKeepsLiveTranscript(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(transcriptPath, old, old); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:   state,
		Runtime: runtime,
		AgentLiveness: func(context.Context, string) bool {
			return true
		},
	}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentState(agent.StatePath(session.ID), api.AgentActivityReady); err != nil {
		t.Fatal(err)
	}

	service.applyAgentLiveness(context.Background(), session)
	stateValue, err := agent.ReadAgentState(agent.StatePath(session.ID))
	if err != nil {
		t.Fatal(err)
	}
	if stateValue != api.AgentActivityReady {
		t.Fatalf("state with live process = %q, want ready", stateValue)
	}
}

func TestCreateSessionInjectsShellBindEnvironment(t *testing.T) {
	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := &envRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	service := &Service{Store: state, Runtime: runtime}
	workspace := state.Snapshot().Workspaces[0]

	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	env := runtime.lastEnv()
	joined := strings.Join(env, "\n")
	for _, expected := range []string{
		agent.BindEnvSession + "=" + session.ID,
		agent.BindEnvFile + "=" + agent.BindPath(session.ID),
		agent.BindEnvState + "=" + agent.StatePath(session.ID),
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("shell env missing %q: %#v", expected, env)
		}
	}
	if strings.Contains(joined, agent.BindEnvKind+"=") {
		t.Fatalf("shell env must not pin an agent kind: %#v", env)
	}
}

type envRecordingRuntime struct {
	*memoryRuntime
	mu   sync.Mutex
	envs [][]string
}

func (r *envRecordingRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	r.mu.Lock()
	r.envs = append(r.envs, append([]string(nil), env...))
	r.mu.Unlock()
	return r.memoryRuntime.Create(ctx, name, directory, command, env)
}

func (r *envRecordingRuntime) lastEnv() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.envs) == 0 {
		return nil
	}
	return r.envs[len(r.envs)-1]
}
