package agent

import (
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestActivityTrackerLifecycle(t *testing.T) {
	tracker := NewActivityTracker()

	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("initial activity = %q, want ready", got)
	}

	tracker.Observe(api.AgentEvent{Type: "user"})
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after user message = %q, want working", got)
	}

	tracker.TurnComplete()
	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after turn complete = %q, want ready", got)
	}

	tracker.Observe(api.AgentEvent{Type: "error"})
	if got := tracker.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("after error = %q, want failed", got)
	}

	tracker.TurnStarted()
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after turn start = %q, want working", got)
	}

	tracker.TurnAborted()
	if got := tracker.Activity(); got != api.AgentActivityWaitingForInput {
		t.Fatalf("after turn abort = %q, want waiting for input", got)
	}
}

func TestActivityTrackerNoticesStalledTool(t *testing.T) {
	tracker := NewActivityTracker()
	started := time.Now()

	tracker.Observe(api.AgentEvent{Type: "user"})
	tracker.Observe(api.AgentEvent{Type: "tool_call", Timestamp: started})
	tracker.Tick(started.Add(4 * time.Second))
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("before timeout = %q, want working", got)
	}

	tracker.Tick(started.Add(6 * time.Second))
	if got := tracker.Activity(); got != api.AgentActivityWaitingForInput {
		t.Fatalf("after timeout = %q, want waiting for input", got)
	}

	tracker.Observe(api.AgentEvent{Type: "tool_output", ToolStatus: "success"})
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after tool result = %q, want working", got)
	}
}

func TestActivityTrackerIgnoresSidechains(t *testing.T) {
	tracker := NewActivityTracker()

	tracker.Observe(api.AgentEvent{
		Type:       "assistant",
		StopReason: "end_turn",
		Sidechain:  true,
	})
	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("sidechain end_turn changed activity to %q, want ready", got)
	}
}

func TestParserDrivesCodexActivity(t *testing.T) {
	parser := newParser("codex")

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}`))
	if got := parser.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after task_started = %q, want working", got)
	}

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"task_complete"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after task_complete = %q, want ready", got)
	}

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"turn_aborted"}}`))
	if got := parser.Activity(); got != api.AgentActivityWaitingForInput {
		t.Fatalf("after turn_aborted = %q, want waiting for input", got)
	}
}

func TestParserDrivesClaudeActivity(t *testing.T) {
	parser := newParser("claude")

	parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}`))
	if got := parser.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after user = %q, want working", got)
	}

	parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after end_turn = %q, want ready", got)
	}

	parser.parse([]byte(`{"type":"system","subtype":"api_error","timestamp":"2026-08-16T10:00:02Z","content":"boom"}`))
	if got := parser.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("after api_error = %q, want failed", got)
	}
}
