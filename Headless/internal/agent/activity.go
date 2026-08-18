package agent

import (
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// pendingToolTimeout is how long an unfinished tool call may run before the
// agent is assumed to be waiting for the user (for example an approval
// prompt that the transcript records as a tool call without a result yet).
const pendingToolTimeout = 5 * time.Second

// ActivityTracker folds transcript events into a single presentation state.
// It lives beside the parser so the status light moves with the same stream
// that renders the conversation.
type ActivityTracker struct {
	activity     api.AgentActivity
	pendingTools int
	pendingSince time.Time
}

// NewActivityTracker starts an agent in the ready state: open, idle, waiting
// for the first instruction.
func NewActivityTracker() *ActivityTracker {
	return &ActivityTracker{activity: api.AgentActivityReady}
}

// Activity returns the current presentation state.
func (t *ActivityTracker) Activity() api.AgentActivity {
	if t.activity == "" {
		return api.AgentActivityReady
	}
	return t.activity
}

// Observe advances the tracker from one normalized transcript event.
func (t *ActivityTracker) Observe(event api.AgentEvent) {
	if event.Sidechain {
		return
	}
	switch event.Type {
	case "user":
		t.working()
	case "tool_call":
		t.toolStarted(event.Timestamp)
	case "tool_output":
		t.toolFinished(event.ToolStatus == "error")
	case "error":
		t.failed()
	case "assistant":
		if event.StopReason == "end_turn" {
			t.TurnComplete()
		}
	}
}

// TurnStarted marks the beginning of a new turn.
func (t *ActivityTracker) TurnStarted() {
	t.working()
}

// TurnComplete marks a finished turn. The agent is idle and ready for the
// next instruction.
func (t *ActivityTracker) TurnComplete() {
	t.pendingTools = 0
	t.pendingSince = time.Time{}
	t.set(api.AgentActivityReady)
}

// TurnFailed marks a turn that ended with an error. The agent failed and
// waits for the next instruction.
func (t *ActivityTracker) TurnFailed() {
	t.pendingTools = 0
	t.pendingSince = time.Time{}
	t.set(api.AgentActivityFailed)
}

// TurnAborted marks a turn the user interrupted. The agent stops and waits
// for input.
func (t *ActivityTracker) TurnAborted() {
	t.pendingTools = 0
	t.pendingSince = time.Time{}
	t.set(api.AgentActivityWaitingForInput)
}

// Exited marks the agent process as gone.
func (t *ActivityTracker) Exited() {
	t.set(api.AgentActivityExited)
}

// Tick notices that a tool call has been waiting too long without a result.
func (t *ActivityTracker) Tick(now time.Time) {
	if t.activity != api.AgentActivityWorking || t.pendingTools == 0 || t.pendingSince.IsZero() {
		return
	}
	if now.Sub(t.pendingSince) >= pendingToolTimeout {
		t.set(api.AgentActivityWaitingForInput)
	}
}

func (t *ActivityTracker) working() {
	t.set(api.AgentActivityWorking)
}

func (t *ActivityTracker) toolStarted(at time.Time) {
	t.pendingTools++
	if t.pendingSince.IsZero() {
		if at.IsZero() {
			at = time.Now()
		}
		t.pendingSince = at
	}
	t.working()
}

func (t *ActivityTracker) toolFinished(failed bool) {
	if t.pendingTools > 0 {
		t.pendingTools--
	}
	if t.pendingTools == 0 {
		t.pendingSince = time.Time{}
	}
	if failed {
		t.failed()
		return
	}
	if t.activity == api.AgentActivityWaitingForInput {
		t.working()
	}
}

func (t *ActivityTracker) failed() {
	t.set(api.AgentActivityFailed)
}

func (t *ActivityTracker) set(state api.AgentActivity) {
	t.activity = state
}
