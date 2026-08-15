package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Binding records which Codex/Claude conversation belongs to one Warren
// session. It is written by the Warren-managed SessionStart hook (Codex) or
// derived from the deterministic `--session-id` flag (Claude), and read by
// the daemon so transcript discovery is keyed by the CLI's own session ID
// instead of guessing by cwd and mtime.
type Binding struct {
	Provider       string    `json:"provider"`
	SessionID      string    `json:"sessionId"`
	TranscriptPath string    `json:"transcriptPath"`
	Cwd            string    `json:"cwd,omitempty"`
	UpdatedAt      time.Time `json:"updatedAt"`
}

const (
	// BindEnvSession marks the Warren session owning the CLI process. Hooks
	// and tool subprocesses see it, but only the managed hook uses it.
	BindEnvSession = "WARREN_SESSION_ID"
	// BindEnvFile points the managed hook at the file it must write with the
	// CLI session ID and transcript path.
	BindEnvFile = "WARREN_BIND_FILE"
	// BindEnvKind names the agent kind (codex or claude) for the hook.
	BindEnvKind = "WARREN_AGENT_KIND"
	// hookCommandMarker identifies the Warren-managed hook entry so repeated
	// daemon starts can merge idempotently.
	hookCommandMarker = "# warren-agent-bind-v1"
)

// BindEnvironment returns the tmux environment entries a Codex/Claude
// process needs so the managed hook can report its own session ID.
func BindEnvironment(warrenSessionID, kind string) []string {
	return []string{
		BindEnvSession + "=" + warrenSessionID,
		BindEnvKind + "=" + kind,
		BindEnvFile + "=" + BindPath(warrenSessionID),
	}
}

// BindPath is the per-session file the managed hook writes.
func BindPath(warrenSessionID string) string {
	return filepath.Join(BindDir(), warrenSessionID+".json")
}

// BindDir is the directory holding per-session bindings.
func BindDir() string {
	return filepath.Join(configDir(), "agent-bind")
}

// configDir is the Warren data directory. Kept behind a function so tests can
// redirect it without touching the user's real home directory.
func configDir() string {
	if value := os.Getenv("WARREN_DATA_DIR"); value != "" {
		return value
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren")
}

// WriteBinding persists the binding reported by a hook. It is safe for the
// hook and the daemon to race: both write the same structured JSON and the
// daemon only starts a watcher for a path that exists on disk.
func WriteBinding(path string, binding Binding) error {
	if binding.Provider == "" || binding.SessionID == "" || binding.TranscriptPath == "" {
		return errors.New("binding needs provider, session id and transcript path")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create binding directory: %w", err)
	}
	data, err := json.Marshal(binding)
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	return nil
}

// ReadBinding returns nil when the file does not exist or is malformed; a
// malformed file is transient while a hook is mid-write, so callers retry.
func ReadBinding(path string) (*Binding, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var binding Binding
	if err := json.Unmarshal(data, &binding); err != nil {
		return nil, nil
	}
	if binding.SessionID == "" || binding.TranscriptPath == "" {
		return nil, nil
	}
	return &binding, nil
}

// RemoveBinding cleans up the per-session file when the session is deleted.
func RemoveBinding(warrenSessionID string) {
	_ = os.Remove(BindPath(warrenSessionID))
}

// InjectClaudeSessionID makes Claude's transcript path deterministic for a
// Warren session. Existing resume/session flags are left untouched so a user
// who explicitly resumes an older conversation keeps their intent.
func InjectClaudeSessionID(command, warrenSessionID string) string {
	fields := strings.Fields(command)
	if len(fields) == 0 || !strings.HasPrefix(fields[0], "claude") {
		return command
	}
	for _, field := range fields[1:] {
		if field == "--session-id" || field == "--resume" || field == "-r" ||
			strings.HasPrefix(field, "--session-id=") || strings.HasPrefix(field, "--resume=") {
			return command
		}
	}
	rest := strings.TrimSpace(strings.TrimPrefix(command, fields[0]))
	result := fields[0] + " --session-id " + warrenSessionID
	if rest != "" {
		result += " " + rest
	}
	return result
}

// ClaudeTranscriptPath computes the transcript file Claude writes for a
// given session ID in a given working directory.
func ClaudeTranscriptPath(claudeRoot, workspacePath, sessionID string) string {
	absolute, err := filepath.Abs(workspacePath)
	if err != nil {
		absolute = workspacePath
	}
	// Claude names the project folder by replacing every path separator in
	// the absolute cwd with "-", including the leading one.
	project := strings.ReplaceAll(filepath.Clean(absolute), string(filepath.Separator), "-")
	return filepath.Join(claudeRoot, project, sessionID+".jsonl")
}

// CodexHome returns the Codex configuration directory the daemon's children
// inherit, honoring CODEX_HOME just like the CLI itself.
func CodexHome() string {
	return filepath.Dir(defaultCodexSessionsRoot())
}

// ClaudeProjectsRoot returns the directory Claude writes transcripts into,
// honoring CLAUDE_CONFIG_DIR just like the CLI itself.
func ClaudeProjectsRoot() string {
	return defaultClaudeProjectsRoot()
}

// EnsureCodexBindHook installs the Warren SessionStart hook into Codex's
// user hooks file, preserving every existing entry. The hook command is a
// small script under Warren's hooks directory so it works without any
// Python/Node runtime beyond the shell.
func EnsureCodexBindHook(codexHome string) (changed bool, err error) {
	hooksPath := filepath.Join(codexHome, "hooks.json")
	scriptPath := filepath.Join(configDir(), "hooks", "codex-bind.sh")
	if err := os.MkdirAll(filepath.Dir(scriptPath), 0o700); err != nil {
		return false, fmt.Errorf("create hooks directory: %w", err)
	}
	if err := os.WriteFile(scriptPath, []byte(codexBindHookScript), 0o700); err != nil {
		return false, fmt.Errorf("write bind hook script: %w", err)
	}

	document := map[string]any{}
	if data, err := os.ReadFile(hooksPath); err == nil {
		if err := json.Unmarshal(data, &document); err != nil {
			return false, fmt.Errorf("parse existing hooks file %s: %w", hooksPath, err)
		}
	}
	hooks, _ := document["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
		document["hooks"] = hooks
	}
	entries, _ := hooks["SessionStart"].([]any)
	command := "bash '" + scriptPath + "' " + hookCommandMarker
	for _, entry := range entries {
		item, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		inner, _ := item["hooks"].([]any)
		for _, hook := range inner {
			config, ok := hook.(map[string]any)
			if !ok {
				continue
			}
			if text, _ := config["command"].(string); strings.Contains(text, hookCommandMarker) {
				if text == command {
					return false, nil
				}
				config["command"] = command
				return true, writeHooksJSON(hooksPath, document)
			}
		}
	}
	hooks["SessionStart"] = append(entries, map[string]any{
		"hooks": []any{
			map[string]any{"type": "command", "command": command},
		},
	})
	return true, writeHooksJSON(hooksPath, document)
}

func writeHooksJSON(path string, document map[string]any) error {
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

// codexBindHookScript reads the SessionStart JSON from stdin, extracts the
// CLI session ID and transcript path, and writes them to the bind file named
// by $WARREN_BIND_FILE. The marker string appears in the command so the
// daemon can find and update its own entry idempotently.
const codexBindHookScript = `#!/bin/sh
# warren-agent-bind-v1
[ -n "$WARREN_BIND_FILE" ] || exit 0
input=$(cat)
session_id=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
transcript_path=$(printf '%s' "$input" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
cwd=$(printf '%s' "$input" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
[ -n "$session_id" ] || session_id=$(printf '%s' "$input" | sed -nE 's/.*"thread_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
[ -n "$session_id" ] || exit 0
[ -n "$transcript_path" ] || exit 0
provider=${WARREN_AGENT_KIND:-codex}
dir=$(dirname "$WARREN_BIND_FILE")
mkdir -p "$dir" 2>/dev/null || exit 0
temporary="$WARREN_BIND_FILE.tmp.$$"
{
  printf '{"provider":"%s","sessionId":"%s","transcriptPath":"%s","cwd":"%s","updatedAt":"%s"}\n' \
    "$provider" "$session_id" "$transcript_path" "$cwd" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$temporary" 2>/dev/null || exit 0
mv -f "$temporary" "$WARREN_BIND_FILE" 2>/dev/null || exit 0
printf '%s\n' '{"continue":true}'
exit 0
`
