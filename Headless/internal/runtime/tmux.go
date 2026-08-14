package runtime

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
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
	target := runtimeName + ":0.0"
	// Query the cursor and capture the pane in one tmux command sequence. A
	// shell can move between two separate tmux invocations, which would make a
	// cursor coordinate belong to a different screen than the captured cells.
	output, err := t.command(ctx,
		"display-message", "-p", "-t", target, "#{cursor_x},#{cursor_y}", ";",
		"capture-pane", "-p", "-e", "-J", "-S", "-", "-t", target,
	).Output()
	if err != nil {
		return nil, err
	}
	capture, cursorX, cursorY, err := parseCaptureWithCursor(output)
	if err != nil {
		return nil, fmt.Errorf("parse tmux capture: %w", err)
	}
	return renderCaptureSnapshot(capture, cursorX, cursorY), nil
}

func parseCaptureWithCursor(output []byte) ([]byte, int, int, error) {
	metadata, capture, found := bytes.Cut(output, []byte{'\n'})
	if !found {
		return nil, 0, 0, fmt.Errorf("missing cursor metadata")
	}
	values := strings.SplitN(strings.TrimSpace(string(metadata)), ",", 2)
	if len(values) != 2 {
		return nil, 0, 0, fmt.Errorf("invalid cursor metadata %q", metadata)
	}
	cursorX, err := strconv.Atoi(values[0])
	if err != nil || cursorX < 0 {
		return nil, 0, 0, fmt.Errorf("invalid cursor column %q", values[0])
	}
	cursorY, err := strconv.Atoi(values[1])
	if err != nil || cursorY < 0 {
		return nil, 0, 0, fmt.Errorf("invalid cursor row %q", values[1])
	}
	return capture, cursorX, cursorY, nil
}

func renderCaptureSnapshot(output []byte, cursorX, cursorY int) []byte {
	if cursorX < 0 || cursorY < 0 {
		return nil
	}
	output = trimCaptureFinalLineEnding(output)
	// capture-pane emits LF-only lines. A terminal interprets LF as a line
	// feed without returning to column zero, which makes every subsequent
	// snapshot drift farther to the right in xterm.js. Normalize the snapshot
	// to the CRLF convention used by a PTY before sending it to clients.
	normalized := normalizeCaptureOutput(output)
	// Clear both the visible screen and the client's old scrollback before
	// replaying the complete tmux history. Restore the real tmux cursor after
	// replay: the final capture line may contain the prompt at any column, and
	// a trailing LF would otherwise move the cursor to the next row/column 0.
	result := make([]byte, 0, len(normalized)+32)
	result = append(result, []byte("\x1b[3J\x1b[2J\x1b[H")...)
	result = append(result, normalized...)
	result = append(result, []byte(fmt.Sprintf("\x1b[%d;%dH", cursorY+1, cursorX+1))...)
	return result
}

func trimCaptureFinalLineEnding(output []byte) []byte {
	if len(output) == 0 || output[len(output)-1] != '\n' {
		return output
	}
	output = output[:len(output)-1]
	if len(output) > 0 && output[len(output)-1] == '\r' {
		output = output[:len(output)-1]
	}
	return output
}

func normalizeCaptureOutput(output []byte) []byte {
	if len(output) == 0 {
		return nil
	}

	normalized := make([]byte, 0, len(output)+bytes.Count(output, []byte{'\n'}))
	for index, value := range output {
		if value == '\n' && (index == 0 || output[index-1] != '\r') {
			normalized = append(normalized, '\r')
		}
		normalized = append(normalized, value)
	}
	return normalized
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
