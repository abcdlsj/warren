package agent

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudeTranscriptPathSanitizesWorkspace(t *testing.T) {
	got := ClaudeTranscriptPath("/Users/me/.claude/projects", "/Users/me/Workspace/demo", "abc-123")
	want := "/Users/me/.claude/projects/-Users-me-Workspace-demo/abc-123.jsonl"
	if got != want {
		t.Fatalf("ClaudeTranscriptPath = %q, want %q", got, want)
	}
}

func TestInjectClaudeSessionID(t *testing.T) {
	const id = "11111111-2222-4333-8444-555555555555"
	cases := []struct {
		name    string
		command string
		want    string
	}{
		{"plain", "claude", "claude --session-id " + id},
		{"with flags", "claude --model sonnet", "claude --session-id " + id + " --model sonnet"},
		{"keeps resume", "claude -r old-id", "claude -r old-id"},
		{"keeps explicit session", "claude --session-id old-id", "claude --session-id old-id"},
		{"not claude", "codex --dangerously-bypass-hook-trust", "codex --dangerously-bypass-hook-trust"},
		{"empty", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := InjectClaudeSessionID(tc.command, id); got != tc.want {
				t.Fatalf("InjectClaudeSessionID(%q) = %q, want %q", tc.command, got, tc.want)
			}
		})
	}
}

func TestBindingRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bind.json")
	binding := Binding{
		Provider:       "codex",
		SessionID:      "thread-1",
		TranscriptPath: "/Users/me/.codex/sessions/rollout.jsonl",
		Cwd:            "/Users/me/Work",
	}
	if err := WriteBinding(path, binding); err != nil {
		t.Fatal(err)
	}
	got, err := ReadBinding(path)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.SessionID != "thread-1" || got.TranscriptPath != binding.TranscriptPath {
		t.Fatalf("ReadBinding = %#v", got)
	}
	if binding, err := ReadBinding(filepath.Join(t.TempDir(), "missing.json")); err != nil || binding != nil {
		t.Fatalf("missing binding = %#v, %v; want nil, nil", binding, err)
	}
	if err := WriteBinding(path, Binding{Provider: "codex"}); err == nil {
		t.Fatal("WriteBinding accepted an incomplete binding")
	}
}

func TestEnsureCodexBindHookMergesIdempotently(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	codexHome := t.TempDir()
	hooksPath := filepath.Join(codexHome, "hooks.json")
	if err := os.WriteFile(hooksPath, []byte(`{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "echo user-hook"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo stop-hook"}]}
    ]
  }
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	changed, err := EnsureCodexBindHook(codexHome)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("first install must report changed")
	}
	var document map[string]any
	data, err := os.ReadFile(hooksPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	hooks := document["hooks"].(map[string]any)
	start := hooks["SessionStart"].([]any)
	if len(start) != 2 {
		t.Fatalf("SessionStart entries = %d, want 2 (user + warren)", len(start))
	}
	warren := start[1].(map[string]any)["hooks"].([]any)[0].(map[string]any)["command"].(string)
	if !strings.Contains(warren, hookCommandMarker) {
		t.Fatalf("warren hook command = %q", warren)
	}
	if !strings.Contains(warren, filepath.Join(configDir(), "hooks", "codex-bind.sh")) {
		t.Fatalf("warren hook command = %q, want script path", warren)
	}
	stop := hooks["Stop"].([]any)
	if len(stop) != 1 {
		t.Fatalf("Stop entries = %d, want 1 preserved", len(stop))
	}

	changed, err = EnsureCodexBindHook(codexHome)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second install must be a no-op")
	}
	dataAfter, err := os.ReadFile(hooksPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(dataAfter) != string(data) {
		t.Fatal("second install rewrote the hooks file")
	}
}

func TestBindEnvironment(t *testing.T) {
	entries := BindEnvironment("warren-1", "codex")
	joined := strings.Join(entries, "\n")
	if !strings.Contains(joined, BindEnvSession+"=warren-1") ||
		!strings.Contains(joined, BindEnvKind+"=codex") ||
		!strings.Contains(joined, BindEnvFile+"="+BindPath("warren-1")) {
		t.Fatalf("BindEnvironment = %#v", entries)
	}
}

func TestCodexBindHookScriptWritesBinding(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	codexHome := t.TempDir()
	if _, err := EnsureCodexBindHook(codexHome); err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(configDir(), "hooks", "codex-bind.sh")
	bindPath := filepath.Join(t.TempDir(), "bind.json")
	command := exec.Command("bash", scriptPath)
	command.Stdin = strings.NewReader(`{"session_id":"thread-9","transcript_path":"/work/rollout-9.jsonl","cwd":"/work","hook_event_name":"SessionStart"}`)
	command.Env = append(os.Environ(),
		"WARREN_BIND_FILE="+bindPath,
		"WARREN_AGENT_KIND=codex",
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("bind hook failed: %v: %s", err, output)
	}
	binding, err := ReadBinding(bindPath)
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.SessionID != "thread-9" || binding.TranscriptPath != "/work/rollout-9.jsonl" || binding.Provider != "codex" {
		t.Fatalf("hook binding = %#v", binding)
	}
}
