package runtime

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

type Tmux struct {
	Binary string
	Socket string
}

func (t Tmux) command(ctx context.Context, args ...string) *exec.Cmd {
	all := make([]string, 0, len(args)+2)
	if t.Socket != "" {
		all = append(all, "-L", t.Socket)
	}
	all = append(all, args...)
	binary := t.Binary
	if binary == "" {
		binary = "tmux"
	}
	return exec.CommandContext(ctx, binary, all...)
}

func (t Tmux) Check(ctx context.Context) error {
	if _, err := exec.LookPath(defaultString(t.Binary, "tmux")); err != nil {
		return fmt.Errorf("tmux is required: %w", err)
	}
	return nil
}

func (t Tmux) Create(ctx context.Context, runtimeName, directory, command string) error {
	args := []string{"new-session", "-d", "-s", runtimeName, "-c", directory, "-x", "120", "-y", "36"}
	if strings.TrimSpace(command) != "" {
		args = append(args, command)
	}
	output, err := t.command(ctx, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create tmux session: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t Tmux) Exists(ctx context.Context, runtimeName string) bool {
	return t.command(ctx, "has-session", "-t", runtimeName).Run() == nil
}

func (t Tmux) List(ctx context.Context) (map[string]bool, error) {
	output, err := t.command(ctx, "list-sessions", "-F", "#{session_name}").CombinedOutput()
	if err != nil {
		message := string(output)
		if strings.Contains(message, "no server running") || strings.Contains(message, "failed to connect") {
			return map[string]bool{}, nil
		}
		return nil, fmt.Errorf("list tmux sessions: %s: %w", strings.TrimSpace(message), err)
	}
	sessions := make(map[string]bool)
	for _, name := range strings.Fields(string(output)) {
		sessions[name] = true
	}
	return sessions, nil
}

func (t Tmux) Capture(ctx context.Context, runtimeName string) ([]byte, error) {
	output, err := t.command(ctx, "capture-pane", "-p", "-e", "-J", "-S", "-", "-t", runtimeName+":0.0").Output()
	if err != nil {
		return nil, err
	}
	return append([]byte("\x1b[H\x1b[2J"), output...), nil
}

func (t Tmux) Input(ctx context.Context, runtimeName string, data []byte) error {
	cmd := t.command(ctx, "load-buffer", "-")
	cmd.Stdin = bytes.NewReader(data)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("load tmux input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	if output, err := t.command(ctx, "paste-buffer", "-d", "-t", runtimeName+":0.0").CombinedOutput(); err != nil {
		return fmt.Errorf("send tmux input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t Tmux) Resize(ctx context.Context, runtimeName string, columns, rows int) error {
	return t.command(ctx, "resize-window", "-t", runtimeName, "-x", fmt.Sprint(columns), "-y", fmt.Sprint(rows)).Run()
}

func (t Tmux) Kill(ctx context.Context, runtimeName string) error {
	output, err := t.command(ctx, "kill-session", "-t", runtimeName).CombinedOutput()
	if err != nil && t.Exists(ctx, runtimeName) {
		return fmt.Errorf("kill tmux session: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
