package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func writeLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	data := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
}

func appendLine(t *testing.T, path, line string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(line + "\n"); err != nil {
		t.Fatal(err)
	}
}

func TestReadNewNormalizesCodexTranscript(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-test.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/work"}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\"command\":\"ls\"}"}}`,
		`{"timestamp":"2026-08-16T10:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"file.txt\n"}}`,
		`{"timestamp":"2026-08-16T10:00:04Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Do it"}]}}`,
	)

	events, next, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	if next <= 0 {
		t.Fatalf("offset did not advance: %d", next)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "assistant,tool_call,tool_output,user"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[0].Content != "Hello" || events[1].ToolName != "Bash" || events[2].Output != "file.txt\n" {
		t.Fatalf("normalized events = %#v", events)
	}
}

func TestCodexDeveloperAndInjectedContextCollapseToSystemInstructions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-instructions.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions> long policy"}]}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/work</cwd>\n</environment_context>"}]}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real question"}]}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "system_instructions,system_instructions,user"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[2].Content != "Real question" {
		t.Fatalf("last user content = %q", events[2].Content)
	}
}

func TestCodexWebSearchAndStreamingMessagesNormalize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-web.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"web_search_call","id":"call-1","status":"completed","action":{"type":"search","queries":["site:example.com codex"]}}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"web_search_call","id":"call-2","status":"failed","action":{"type":"open_page","url":"https://example.com/a"}}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"Let me look at that file"}}`,
		`{"timestamp":"2026-08-16T10:00:03Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Checking read scope"}}`,
		`{"timestamp":"2026-08-16T10:00:04Z","type":"response_item","payload":{"type":"plan","id":"plan-1","content":[{"type":"output_text","text":"Proposed plan"}]}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "tool_call,tool_call,assistant,reasoning,unknown"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[0].ToolName != "web_search" || events[0].ToolStatus != "success" {
		t.Fatalf("web search success = %#v", events[0])
	}
	if events[1].ToolStatus != "error" {
		t.Fatalf("web search failure = %#v", events[1])
	}
	if events[2].Content != "Let me look at that file" || events[3].Content != "Checking read scope" {
		t.Fatalf("streaming events = %#v", events[2:4])
	}
	if events[4].Content != "Proposed plan" {
		t.Fatalf("unknown fallback should extract inner text, got %q", events[4].Content)
	}
}

func TestCodexDeduplicatesTwinStreamingEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-twin.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"reasoning","content":[{"type":"reasoning","text":"Think once"}]}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Think once"}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Reply once"}]}}`,
		`{"timestamp":"2026-08-16T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"Reply once"}}`,
		`{"timestamp":"2026-08-16T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}}`,
		`{"timestamp":"2026-08-16T10:00:05Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\"command\":\"ls\"}"}}`,
		`{"timestamp":"2026-08-16T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4,"output_tokens":5,"total_tokens":9}}}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	// Reasoning and assistant appear once. Usage events stay in the stream;
	// the web client decides where to surface them.
	if got, want := strings.Join(kinds, ","), "reasoning,assistant,usage,tool_call,usage"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
}

func TestCodexApprovedPrefixNoticeIsHidden(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-approved.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Approved command prefix saved:\n- [\"glab\", \"mr\", \"view\"]"}]}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real user turn"}]}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "user" {
		t.Fatalf("events = %#v, want only the real user turn", events)
	}
}

func TestClaudeHookAttachmentBecomesSystem(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-hooks.jsonl")
	writeLines(t, path,
		`{"type":"attachment","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"","stdout":"done"}}`,
		`{"type":"attachment","uuid":"a2","timestamp":"2026-08-16T10:00:01Z","attachment":{"type":"skill_listing","content":"- skill: demo"}}`,
	)
	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v", events)
	}
	if events[0].Type != "system" || !strings.HasPrefix(events[0].Content, "Hook: SessionStart:startup") {
		t.Fatalf("hook attachment = %#v", events[0])
	}
	if events[1].Type != "system_instructions" {
		t.Fatalf("skill listing = %#v", events[1])
	}
}

func TestReadNewNormalizesClaudeTranscript(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	writeLines(t, path,
		`{"type":"summary","summary":"fixture","leafUuid":null}`,
		`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":"Hello"}}`,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}`,
	)

	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "user,assistant,tool_call"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[0].Content != "Hello" || events[1].Content != "Hi" || events[2].ToolName != "Bash" {
		t.Fatalf("normalized events = %#v", events)
	}
}

func TestWatcherTailsNewLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-live.jsonl")
	writeLines(t, path, `{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`)

	var mu sync.Mutex
	var seen []api.AgentEvent
	watcher := Start("session-1", "codex", path, func(events []api.AgentEvent, _ api.AgentActivity) {
		mu.Lock()
		seen = append(seen, events...)
		mu.Unlock()
	}, nil)
	defer watcher.Close()

	deadline := time.Now().Add(3 * time.Second)
	for {
		mu.Lock()
		count := len(seen)
		mu.Unlock()
		if count >= 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("initial event never arrived")
		}
		time.Sleep(10 * time.Millisecond)
	}

	appendLine(t, path, `{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"live"}]}}`)
	deadline = time.Now().Add(3 * time.Second)
	for {
		mu.Lock()
		count := len(seen)
		var contents []string
		var sequences []uint64
		for _, event := range seen {
			contents = append(contents, event.Content)
			sequences = append(sequences, event.Sequence)
		}
		mu.Unlock()
		if count >= 2 {
			if contents[1] != "live" {
				t.Fatalf("live event content = %q, want live", contents[1])
			}
			if sequences[0] != 1 || sequences[1] != 2 {
				t.Fatalf("event sequences = %d,%d, want 1,2", sequences[0], sequences[1])
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("live event never arrived: %#v", contents)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestFinderPicksNewestMatchingCodex(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sessions")
	older := filepath.Join(root, "2026", "08", "16", "rollout-old.jsonl")
	newer := filepath.Join(root, "2026", "08", "16", "rollout-new.jsonl")
	writeLines(t, older, `{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"old","cwd":"/work/warren"}}`)
	writeLines(t, newer, `{"timestamp":"2026-08-16T11:00:00Z","type":"session_meta","payload":{"id":"new","cwd":"/work/warren"}}`)
	writeLines(t, filepath.Join(root, "2026", "08", "16", "rollout-other.jsonl"),
		`{"timestamp":"2026-08-16T11:10:00Z","type":"session_meta","payload":{"id":"other","cwd":"/elsewhere"}}`)

	finder := DefaultFinder{CodexRoot: root}
	path, err := finder.Find(context.Background(), "codex", "/work/warren", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != "rollout-new.jsonl" {
		t.Fatalf("finder picked %q, want rollout-new.jsonl", path)
	}
}

func TestFinderIgnoresTranscriptsBeforeSessionStart(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sessions")
	path := filepath.Join(root, "2026", "08", "16", "rollout-old.jsonl")
	writeLines(t, path, `{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"old","cwd":"/work/warren"}}`)
	finder := DefaultFinder{CodexRoot: root}
	future := time.Now().Add(time.Hour)
	found, err := finder.Find(context.Background(), "codex", "/work/warren", future)
	if err != nil {
		t.Fatal(err)
	}
	if found != "" {
		t.Fatalf("finder adopted a transcript older than the session: %q", found)
	}
}

func TestFinderMatchesClaudeCwd(t *testing.T) {
	root := filepath.Join(t.TempDir(), "projects")
	path := filepath.Join(root, "-work-warren", "session.jsonl")
	writeLines(t, path,
		`{"type":"summary","summary":"x","leafUuid":null}`,
		`{"type":"user","uuid":"u1","cwd":"/work/warren","message":{"role":"user","content":"hi"}}`,
	)

	finder := DefaultFinder{ClaudeRoot: root}
	found, err := finder.Find(context.Background(), "claude", "/work/warren", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if found != path {
		t.Fatalf("finder picked %q, want %q", found, path)
	}
}

func TestCodexToolOutputAttributionAndStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-tools.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\"command\":\"false\"}"}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"output\":\"boom\",\"metadata\":{\"exit_code\":1,\"error\":\"command failed\"}}"}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want 2", events)
	}
	call := events[0]
	output := events[1]
	if call.ToolName != "Bash" || output.ToolName != "Bash" || output.CallID != "call-1" {
		t.Fatalf("tool attribution = %#v / %#v", call, output)
	}
	if output.ToolStatus != "error" || output.Error != "command failed" || output.Output != "boom" {
		t.Fatalf("tool status = %#v", output)
	}
}

func TestCodexTokenUsageEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-tokens.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5","effort":"high"}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":30},"model_context_window":272000}}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %#v, want only the usage event", events)
	}
	usage := events[0]
	if usage.Type != "usage" || usage.Model != "gpt-5" || usage.Usage == nil {
		t.Fatalf("usage event = %#v", usage)
	}
	if usage.Usage.InputTokens != 10 || usage.Usage.CacheReadInputTokens != 4 ||
		usage.Usage.OutputTokens != 20 || usage.Usage.ReasoningOutputTokens != 5 ||
		usage.Usage.TotalTokens != 30 {
		t.Fatalf("usage details = %#v", usage.Usage)
	}
}

func TestClaudeToolResultErrorAndFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-tools.jsonl")
	writeLines(t, path,
		`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"cannot read file","is_error":true}]},"toolUseResult":{"filePath":"/work/warren/main.go","interrupted":false}}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %#v, want 1", events)
	}
	event := events[0]
	if event.Type != "tool_output" || event.CallID != "toolu_1" ||
		event.ToolStatus != "error" || event.Error != "cannot read file" ||
		len(event.Files) != 1 || event.Files[0] != "/work/warren/main.go" {
		t.Fatalf("tool result = %#v", event)
	}
}

func TestClaudeAssistantCarriesModelUsageAndSidechain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-assistant.jsonl")
	writeLines(t, path,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","isSidechain":true,"message":{"id":"msg_1","model":"claude-opus-4-7","role":"assistant","content":[{"type":"text","text":"subagent says hi"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %#v, want 1", events)
	}
	event := events[0]
	if event.Type != "assistant" || !event.Sidechain || event.Model != "claude-opus-4-7" ||
		event.StopReason != "end_turn" || event.Usage == nil ||
		event.Usage.InputTokens != 100 || event.Usage.OutputTokens != 50 {
		t.Fatalf("assistant event = %#v", event)
	}
}

func TestClaudeApiErrorBecomesErrorEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-error.jsonl")
	writeLines(t, path,
		`{"type":"system","subtype":"api_error","uuid":"s1","timestamp":"2026-08-16T10:00:00Z","content":"upstream timeout"}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "error" || events[0].Error != "upstream timeout" {
		t.Fatalf("error event = %#v", events)
	}
}

func TestCodexApplyPatchExtractsFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-patch.jsonl")
	arguments := `{\"patch\":\"*** Add File: src/a.go\\n+package a\\n*** Update File: src/b.go\\n- old\\n+ new\"}`
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"apply_patch","arguments":"`+arguments+`"}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Files) != 2 ||
		events[0].Files[0] != "src/a.go" || events[0].Files[1] != "src/b.go" {
		t.Fatalf("patch files = %#v", events)
	}
}

func TestClaudeEditToolCarriesFilePath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-edit.jsonl")
	writeLines(t, path,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/work/warren/main.go","old_string":"a","new_string":"b"}}]}}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Files) != 1 || events[0].Files[0] != "/work/warren/main.go" {
		t.Fatalf("edit files = %#v", events)
	}
}
