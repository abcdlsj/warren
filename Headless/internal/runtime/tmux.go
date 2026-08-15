package runtime

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Tmux struct {
	Binary    string
	Socket    string
	OutputDir string

	sessionMu sync.Mutex
	sessions  map[string]*sync.Mutex
}

func (t *Tmux) command(ctx context.Context, args ...string) *exec.Cmd {
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

func (t *Tmux) Check(ctx context.Context) error {
	if _, err := exec.LookPath(defaultString(t.Binary, "tmux")); err != nil {
		return fmt.Errorf("tmux is required: %w", err)
	}
	return nil
}

func (t *Tmux) Create(ctx context.Context, runtimeName, directory, command string) error {
	args := []string{"new-session", "-d", "-s", runtimeName, "-c", directory, "-x", "120", "-y", "36"}
	if strings.TrimSpace(command) != "" {
		args = append(args, command)
	}
	output, err := t.command(ctx, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create tmux session: %s: %w", strings.TrimSpace(string(output)), err)
	}
	if err := t.setLatestWindowSize(ctx, runtimeName); err != nil {
		_ = t.Kill(ctx, runtimeName)
		return err
	}
	return nil
}

// EnsurePipe installs the raw PTY byte pipe for a session. tmux supports one
// pipe per pane, so the install is guarded by `#{pane_pipe}` instead of the
// `-o` toggle flag: `pipe-pane -o` closes an existing pipe on tmux 3.5a,
// which would silently stop every adopted session's output after a daemon
// restart. With the guard, repeated attach/adopt never stack a pipe and never
// tear down an already-correct one.
func (t *Tmux) EnsurePipe(ctx context.Context, runtimeName string) error {
	if !t.Exists(ctx, runtimeName) {
		return fmt.Errorf("tmux session not found: %s", runtimeName)
	}
	if t.OutputDir == "" {
		t.OutputDir = defaultOutputDirectory()
	}
	if err := os.MkdirAll(t.OutputDir, 0o700); err != nil {
		return fmt.Errorf("create runtime output directory: %w", err)
	}
	spoolPath := t.SpoolPath(runtimeName)
	file, err := os.OpenFile(spoolPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open output spool: %w", err)
	}
	_ = file.Close()
	pane, err := t.PaneTarget(ctx, runtimeName)
	if err != nil {
		return err
	}
	lock := t.sessionLock(runtimeName)
	lock.Lock()
	defer lock.Unlock()
	hasPipe, err := t.paneHasPipe(ctx, pane)
	if err != nil {
		return err
	}
	if !hasPipe {
		output, installErr := t.command(ctx,
			"pipe-pane", "-O", "-t", pane,
			"cat >> "+shellQuote(spoolPath),
		).CombinedOutput()
		if installErr != nil {
			return fmt.Errorf("install tmux output pipe: %s: %w", strings.TrimSpace(string(output)), installErr)
		}
	}
	return t.setLatestWindowSize(ctx, runtimeName)
}

func (t *Tmux) paneHasPipe(ctx context.Context, pane string) (bool, error) {
	output, err := t.command(ctx, "display-message", "-p", "-t", pane, "#{pane_pipe}").Output()
	if err != nil {
		return false, fmt.Errorf("query tmux output pipe: %w", err)
	}
	return strings.TrimSpace(string(output)) == "1", nil
}

func (t *Tmux) ClosePipe(ctx context.Context, runtimeName string) error {
	pane, err := t.PaneTarget(ctx, runtimeName)
	if err != nil {
		return err
	}
	output, err := t.command(ctx, "pipe-pane", "-t", pane).CombinedOutput()
	if err != nil {
		return fmt.Errorf("close tmux output pipe: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) PaneTarget(ctx context.Context, runtimeName string) (string, error) {
	output, err := t.command(ctx, "display-message", "-p", "-t", runtimeName, "#{pane_id}").Output()
	if err != nil {
		return "", fmt.Errorf("resolve tmux pane: %w", err)
	}
	pane := strings.TrimSpace(string(output))
	if pane == "" {
		return runtimeName + ":0.0", nil
	}
	return pane, nil
}

func (t *Tmux) setLatestWindowSize(ctx context.Context, runtimeName string) error {
	output, err := t.command(ctx, "set-window-option", "-t", runtimeName, "window-size", "latest").CombinedOutput()
	if err != nil {
		return fmt.Errorf("set tmux window-size latest: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) SpoolPath(runtimeName string) string {
	dir := t.OutputDir
	if dir == "" {
		dir = defaultOutputDirectory()
	}
	return filepath.Join(dir, runtimeName+".out")
}

func (t *Tmux) SpoolSize(ctx context.Context, runtimeName string) (int64, error) {
	info, err := os.Stat(t.SpoolPath(runtimeName))
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

// TruncateSpool compacts the live spool in place. The pipe command keeps its
// O_APPEND file descriptor, so tmux output continues into the same inode from
// byte zero; Host bumps the epoch and reanchors clients.
func (t *Tmux) TruncateSpool(ctx context.Context, runtimeName string) error {
	path := t.SpoolPath(runtimeName)
	if err := os.Truncate(path, 0); err != nil {
		return fmt.Errorf("truncate output spool: %w", err)
	}
	return nil
}

// ArchiveSpool compresses the current spool to a timestamped .gz file and
// prunes old archives. Best-effort diagnostics; truncation must not depend on
// archive success.
func (t *Tmux) ArchiveSpool(ctx context.Context, runtimeName string) error {
	path := t.SpoolPath(runtimeName)
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 {
		return nil
	}
	archive := path + "." + strconv.FormatInt(time.Now().UnixNano(), 10) + ".gz"
	source, err := os.Open(path)
	if err != nil {
		return err
	}
	defer source.Close()
	destination, err := os.OpenFile(archive, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	writer := gzip.NewWriter(destination)
	if _, err := io.Copy(writer, source); err != nil {
		_ = writer.Close()
		_ = destination.Close()
		_ = os.Remove(archive)
		return err
	}
	if err := writer.Close(); err != nil {
		_ = destination.Close()
		_ = os.Remove(archive)
		return err
	}
	if err := destination.Close(); err != nil {
		return err
	}
	return t.pruneArchives(path)
}

func (t *Tmux) pruneArchives(path string) error {
	matches, err := filepath.Glob(path + ".*.gz")
	if err != nil {
		return err
	}
	for len(matches) > 3 {
		oldest := matches[0]
		for _, match := range matches[1:] {
			if match < oldest {
				oldest = match
			}
		}
		_ = os.Remove(oldest)
		matches = removeString(matches, oldest)
	}
	return nil
}

func removeString(values []string, target string) []string {
	result := values[:0]
	for _, value := range values {
		if value != target {
			result = append(result, value)
		}
	}
	return result
}

func (t *Tmux) RemoveSpool(runtimeName string) {
	path := t.SpoolPath(runtimeName)
	_ = os.Remove(path)
	for _, match := range mustGlob(path + ".*.gz") {
		_ = os.Remove(match)
	}
}

func mustGlob(pattern string) []string {
	matches, _ := filepath.Glob(pattern)
	return matches
}

func defaultOutputDirectory() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren", "output")
}

func (t *Tmux) Exists(ctx context.Context, runtimeName string) bool {
	return t.command(ctx, "has-session", "-t", runtimeName).Run() == nil
}

func (t *Tmux) List(ctx context.Context) (map[string]bool, error) {
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

// ListCreated returns the sessions on this socket with their tmux creation
// timestamps. The service uses it to reclaim orphaned sessions that outlived
// their state record, e.g. after a state reset or daemon crash.
func (t *Tmux) ListCreated(ctx context.Context) (map[string]time.Time, error) {
	output, err := t.command(ctx, "list-sessions", "-F", "#{session_name}\t#{session_created}").CombinedOutput()
	if err != nil {
		message := string(output)
		if strings.Contains(message, "no server running") || strings.Contains(message, "failed to connect") {
			return map[string]time.Time{}, nil
		}
		return nil, fmt.Errorf("list tmux sessions: %s: %w", strings.TrimSpace(message), err)
	}
	sessions := make(map[string]time.Time)
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\t", 2)
		if len(fields) != 2 {
			continue
		}
		created, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			continue
		}
		sessions[fields[0]] = time.Unix(created, 0)
	}
	return sessions, nil
}

func (t *Tmux) Capture(ctx context.Context, runtimeName string) ([]byte, error) {
	target := runtimeName + ":0.0"
	// Query the cursor and capture the pane in one tmux command sequence. A
	// shell can move between two separate tmux invocations, which would make a
	// cursor coordinate belong to a different screen than the captured cells.
	output, err := t.command(ctx,
		"display-message", "-p", "-t", target, "#{cursor_x},#{cursor_y}", ";",
		"capture-pane", "-p", "-e", "-S", "-", "-t", target,
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
	// Ghostty's BCE handling corrupts soft-wrapped colored history when a
	// snapshot line ends with an active background color: the color bleeds
	// past later SGR resets after the line scrolls. Rewrite every physical row
	// to reset SGR at its boundaries and re-assert the carried style at the
	// start of the next row, so no color is ever active while a new row is
	// created by scrolling.
	output = rewriteSGRRows(output)
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

type sgrColor struct {
	rgb   bool
	index uint8
	r     uint8
	g     uint8
	b     uint8
}

type sgrState struct {
	flags map[int]bool
	fg    *sgrColor
	bg    *sgrColor
}

func newSGRState() *sgrState {
	return &sgrState{flags: map[int]bool{}}
}

func (s *sgrState) reset() {
	s.flags = map[int]bool{}
	s.fg = nil
	s.bg = nil
}

func (s *sgrState) apply(params string) {
	if params == "" {
		s.reset()
		return
	}
	parts := strings.Split(params, ";")
	for i := 0; i < len(parts); i++ {
		n, err := strconv.Atoi(parts[i])
		if err != nil {
			continue
		}
		switch {
		case n == 0:
			s.reset()
		case n == 1:
			s.flags[1] = true
		case n == 2:
			s.flags[1] = false
			s.flags[2] = true
		case n == 3:
			s.flags[3] = true
		case n == 4:
			s.flags[4] = true
		case n == 5:
			s.flags[5] = true
		case n == 7:
			s.flags[7] = true
		case n == 8:
			s.flags[8] = true
		case n == 9:
			s.flags[9] = true
		case n == 21:
			s.flags[21] = true
		case n == 22:
			s.flags[1] = false
			s.flags[2] = false
		case n == 23:
			s.flags[3] = false
		case n == 24:
			s.flags[4] = false
			s.flags[21] = false
		case n == 25:
			s.flags[5] = false
		case n == 27:
			s.flags[7] = false
		case n == 28:
			s.flags[8] = false
		case n == 29:
			s.flags[9] = false
		case n >= 30 && n <= 37:
			s.fg = &sgrColor{index: uint8(n - 30)}
		case n == 38:
			if i+1 < len(parts) {
				mode, modeErr := strconv.Atoi(parts[i+1])
				if modeErr != nil {
					continue
				}
				i++
				if mode == 5 && i+1 < len(parts) {
					value, _ := strconv.Atoi(parts[i+1])
					s.fg = &sgrColor{index: uint8(value)}
					i++
				} else if mode == 2 && i+3 < len(parts) {
					r, _ := strconv.Atoi(parts[i+1])
					g, _ := strconv.Atoi(parts[i+2])
					b, _ := strconv.Atoi(parts[i+3])
					s.fg = &sgrColor{rgb: true, r: uint8(r), g: uint8(g), b: uint8(b)}
					i += 3
				}
			}
		case n == 39:
			s.fg = nil
		case n >= 40 && n <= 47:
			s.bg = &sgrColor{index: uint8(n - 40)}
		case n == 48:
			if i+1 < len(parts) {
				mode, modeErr := strconv.Atoi(parts[i+1])
				if modeErr != nil {
					continue
				}
				i++
				if mode == 5 && i+1 < len(parts) {
					value, _ := strconv.Atoi(parts[i+1])
					s.bg = &sgrColor{index: uint8(value)}
					i++
				} else if mode == 2 && i+3 < len(parts) {
					r, _ := strconv.Atoi(parts[i+1])
					g, _ := strconv.Atoi(parts[i+2])
					b, _ := strconv.Atoi(parts[i+3])
					s.bg = &sgrColor{rgb: true, r: uint8(r), g: uint8(g), b: uint8(b)}
					i += 3
				}
			}
		case n == 49:
			s.bg = nil
		case n >= 90 && n <= 97:
			s.fg = &sgrColor{index: uint8(n - 90 + 8)}
		case n >= 100 && n <= 107:
			s.bg = &sgrColor{index: uint8(n - 100 + 8)}
		}
	}
}

func (s *sgrState) canonical() []byte {
	if len(s.flags) == 0 && s.fg == nil && s.bg == nil {
		return nil
	}
	var parts []string
	for flag := 1; flag <= 21; flag++ {
		if s.flags[flag] {
			parts = append(parts, strconv.Itoa(flag))
		}
	}
	if s.fg != nil {
		if s.fg.rgb {
			parts = append(parts, "38", "2",
				strconv.Itoa(int(s.fg.r)),
				strconv.Itoa(int(s.fg.g)),
				strconv.Itoa(int(s.fg.b)))
		} else if s.fg.index < 8 {
			parts = append(parts, strconv.Itoa(30+int(s.fg.index)))
		} else {
			parts = append(parts, strconv.Itoa(90+int(s.fg.index)-8))
		}
	}
	if s.bg != nil {
		if s.bg.rgb {
			parts = append(parts, "48", "2",
				strconv.Itoa(int(s.bg.r)),
				strconv.Itoa(int(s.bg.g)),
				strconv.Itoa(int(s.bg.b)))
		} else if s.bg.index < 8 {
			parts = append(parts, strconv.Itoa(40+int(s.bg.index)))
		} else {
			parts = append(parts, strconv.Itoa(100+int(s.bg.index)-8))
		}
	}
	return []byte("\x1b[" + strings.Join(parts, ";") + "m")
}

func rewriteSGRRows(output []byte) []byte {
	if len(output) == 0 {
		return nil
	}
	if output[len(output)-1] == '\n' {
		output = output[:len(output)-1]
		if len(output) > 0 && output[len(output)-1] == '\r' {
			output = output[:len(output)-1]
		}
	}
	rows := bytes.Split(output, []byte{'\n'})
	state := newSGRState()
	result := make([]byte, 0, len(output)+len(rows)*8)
	for _, row := range rows {
		result = append(result, "\x1b[0m"...)
		if canonical := state.canonical(); canonical != nil {
			result = append(result, canonical...)
		}
		for i := 0; i < len(row); {
			if row[i] == 0x1b && i+1 < len(row) && row[i+1] == '[' {
				end := i + 2
				for end < len(row) && row[end] != 'm' {
					end++
				}
				if end < len(row) && row[end] == 'm' {
					state.apply(string(row[i+2 : end]))
					result = append(result, row[i:end+1]...)
					i = end + 1
					continue
				}
			}
			result = append(result, row[i])
			i++
		}
		result = append(result, "\x1b[0m\n"...)
	}
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

func (t *Tmux) Input(ctx context.Context, runtimeName string, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	lock := t.sessionLock(runtimeName)
	lock.Lock()
	defer lock.Unlock()
	// Every write uses a unique tmux buffer so concurrent inputs can never
	// cross. paste-buffer -d deletes the buffer on success; a failed write is
	// cleaned up below and never touches another input.
	bufferName := "warren-in-" + strings.ReplaceAll(newID(), "-", "")
	cmd := t.command(ctx, "load-buffer", "-b", bufferName, "-")
	cmd.Stdin = bytes.NewReader(data)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("load tmux input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	if output, err := t.command(ctx, "paste-buffer", "-b", bufferName, "-d", "-t", runtimeName+":0.0").CombinedOutput(); err != nil {
		_, _ = t.command(ctx, "delete-buffer", "-b", bufferName).CombinedOutput()
		return fmt.Errorf("send tmux input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) Resize(ctx context.Context, runtimeName string, columns, rows int) error {
	lock := t.sessionLock(runtimeName)
	lock.Lock()
	defer lock.Unlock()
	return t.command(ctx, "resize-window", "-t", runtimeName, "-x", fmt.Sprint(columns), "-y", fmt.Sprint(rows)).Run()
}

func (t *Tmux) Kill(ctx context.Context, runtimeName string) error {
	output, err := t.command(ctx, "kill-session", "-t", runtimeName).CombinedOutput()
	if err != nil && t.Exists(ctx, runtimeName) {
		return fmt.Errorf("kill tmux session: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) sessionLock(name string) *sync.Mutex {
	t.sessionMu.Lock()
	defer t.sessionMu.Unlock()
	if t.sessions == nil {
		t.sessions = map[string]*sync.Mutex{}
	}
	lock := t.sessions[name]
	if lock == nil {
		lock = &sync.Mutex{}
		t.sessions[name] = lock
	}
	return lock
}

// newID is a UUIDv4-style generator used only for tmux buffer names.
func newID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
