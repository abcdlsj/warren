package server

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// agentLivenessIdle is how long a transcript must stop changing before
	// the daemon considers the CLI a candidate for exit detection. An agent
	// that is idle while waiting for input still holds its transcript open,
	// so the file mtime alone never marks it exited.
	agentLivenessIdle = 10 * time.Second
	// agentLivenessRecheck throttles the external lsof probe to once per
	// session per interval. lsof is cheap, but the lifecycle loop runs every
	// second and a user can keep many agent tabs open.
	agentLivenessRecheck = 10 * time.Second
)

// applyAgentLiveness is a fallback for CLIs that exit without running the
// Warren SessionEnd hook (for example the process is killed). The transcript
// stops changing and no process holds it open, so the daemon marks the
// session exited and the normal SessionEnd cleanup path takes over.
func (s *Service) applyAgentLiveness(ctx context.Context, session api.Session) {
	switch session.Kind {
	case "codex", "claude", "shell", "custom":
	default:
		return
	}
	path := s.agentTranscriptPath(session)
	if path == "" || s.transcriptTakenByOther(path, session.ID) {
		return
	}
	info, err := os.Stat(path)
	if err != nil || info.IsDir() || time.Since(info.ModTime()) < agentLivenessIdle {
		return
	}
	state, err := agent.ReadAgentState(agent.StatePath(session.ID))
	if err != nil || state == api.AgentActivityExited {
		return
	}

	s.lazyInit()
	s.agentsMu.Lock()
	entry := s.agents[session.ID]
	var last time.Time
	if entry != nil {
		entry.mu.Lock()
		last = entry.lastLiveness
		entry.lastLiveness = time.Now()
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if entry != nil && time.Since(last) < agentLivenessRecheck {
		return
	}

	if s.agentLiveness(ctx, path) {
		return
	}
	_ = agent.WriteAgentState(agent.StatePath(session.ID), api.AgentActivityExited)
	s.applyAgentState(session)
}

// agentTranscriptPath resolves the transcript the current binding points at,
// falling back to the persisted session metadata. The binding is preferred
// because Codex can rotate to a fresh rollout after `/clear`.
func (s *Service) agentTranscriptPath(session api.Session) string {
	if binding, err := agent.ReadBinding(agent.BindPath(session.ID)); err == nil && binding != nil {
		if info, err := os.Stat(binding.TranscriptPath); err == nil && !info.IsDir() {
			return binding.TranscriptPath
		}
	}
	if session.TranscriptPath != "" {
		if info, err := os.Stat(session.TranscriptPath); err == nil && !info.IsDir() {
			return session.TranscriptPath
		}
	}
	return ""
}

func (s *Service) agentLiveness(ctx context.Context, path string) bool {
	if s.AgentLiveness != nil {
		return s.AgentLiveness(ctx, path)
	}
	return transcriptHasOpenProcess(ctx, path)
}

// transcriptHasOpenProcess reports whether any process currently holds the
// transcript file open. The CLI keeps its rollout file open for the whole
// conversation, so an empty lsof result means the agent process is gone. If
// lsof is unavailable or the probe fails for any reason other than "no
// matches", the function assumes the process is alive to avoid false exits.
func transcriptHasOpenProcess(ctx context.Context, path string) bool {
	if _, err := exec.LookPath("lsof"); err != nil {
		return true
	}
	output, err := exec.CommandContext(ctx, "lsof", "-t", path).Output()
	if err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) && exitError.ExitCode() == 1 {
			return false
		}
		return true
	}
	return strings.TrimSpace(string(output)) != ""
}
