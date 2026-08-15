package runtime

import (
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// PTY is a tmux-free runtime that owns one pseudo-terminal per session. The
// daemon keeps the child alive after every client disconnects, and raw PTY
// bytes are appended to the same per-session spool consumed by SpoolWatcher,
// so the output pipeline (ring, recovery anchors, reanchor) is unchanged.
//
// Known differences from the tmux adapter:
//   - Input bytes are written to the PTY verbatim, so there is no tmux
//     paste-vs-key translation layer and kitty-protocol keys (for example
//     Shift+Enter) reach the application unchanged.
//   - A daemon restart closes the PTY master and ends its sessions. tmux
//     sessions survive a daemon restart because tmux owns them; the PTY
//     runtime owns children directly and does not implement adoption yet.
type PTY struct {
	OutputDir string

	mu       sync.Mutex
	sessions map[string]*ptySession
}

type ptySession struct {
	name      string
	command   *exec.Cmd
	master    *os.File
	spool     *os.File
	vt        *VTTerminal
	createdAt time.Time

	inputMu   sync.Mutex
	closeOnce sync.Once
	done      chan struct{}
	reaped    chan struct{}
}

func NewPTY(outputDir string) *PTY {
	return &PTY{OutputDir: outputDir, sessions: map[string]*ptySession{}}
}

// Check reports whether the runtime can start. Unlike tmux there is no
// external binary to find, so the check always succeeds.
func (p *PTY) Check(context.Context) error {
	return nil
}

func (p *PTY) Create(_ context.Context, runtimeName, directory, command string) error {
	p.mu.Lock()
	if p.sessions[runtimeName] != nil {
		p.mu.Unlock()
		return fmt.Errorf("pty session already exists: %s", runtimeName)
	}
	p.mu.Unlock()

	if p.OutputDir == "" {
		p.OutputDir = defaultOutputDirectory()
	}
	if err := os.MkdirAll(p.OutputDir, 0o700); err != nil {
		return fmt.Errorf("create runtime output directory: %w", err)
	}
	spool, err := os.OpenFile(p.SpoolPath(runtimeName), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open output spool: %w", err)
	}
	vt, err := NewVTTerminal(120, 36)
	if err != nil {
		_ = spool.Close()
		return fmt.Errorf("create ghostty vt: %w", err)
	}
	cmd := ptyCommand(directory, command)
	master, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 120, Rows: 36})
	if err != nil {
		_ = spool.Close()
		vt.Close()
		return fmt.Errorf("start pty: %w", err)
	}
	session := &ptySession{
		name:      runtimeName,
		command:   cmd,
		master:    master,
		spool:     spool,
		vt:        vt,
		createdAt: time.Now(),
		done:      make(chan struct{}),
		reaped:    make(chan struct{}),
	}
	p.mu.Lock()
	p.sessions[runtimeName] = session
	p.mu.Unlock()
	// Persist creation metadata so a restarted daemon can still identify and
	// reclaim orphaned children (see ListCreated and Kill).
	_ = os.WriteFile(p.CreatedPath(runtimeName), []byte(strconv.FormatInt(session.createdAt.Unix(), 10)+"\n"), 0o600)
	_ = os.WriteFile(p.PIDPath(runtimeName), []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o600)
	go p.copyOutput(session)
	return nil
}

// ptyCommand builds the child command. An empty command starts the user's
// shell; otherwise the command is executed through sh -lc, matching how tmux
// runs new-session commands.
func ptyCommand(directory, command string) *exec.Cmd {
	var cmd *exec.Cmd
	if strings.TrimSpace(command) == "" {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "sh"
		}
		cmd = exec.Command(shell)
	} else {
		cmd = exec.Command("sh", "-lc", command)
	}
	cmd.Dir = directory
	// tmux forces a known TERM on its panes; a bare daemon may otherwise
	// inherit an empty TERM and programs (git diff, ls, TUIs) would suppress
	// colors. Pin the same 256-color environment for every child so the
	// rendered output is stable regardless of how the daemon was launched.
	cmd.Env = ptyEnvironment()
	return cmd
}

func ptyEnvironment() []string {
	env := make([]string, 0, len(os.Environ())+2)
	for _, item := range os.Environ() {
		if strings.HasPrefix(item, "TERM=") ||
			strings.HasPrefix(item, "COLORTERM=") ||
			// The daemon host may export NO_COLOR (for example when launched
			// from an agent session). It must not leak into PTY children:
			// Warren pins a color-capable terminal and the client renderer
			// handles colors itself, so applications like Codex would
			// otherwise silently downgrade to monochrome.
			strings.HasPrefix(item, "NO_COLOR=") {
			continue
		}
		env = append(env, item)
	}
	return append(env, "TERM=xterm-256color", "COLORTERM=truecolor")
}

// copyOutput drains the PTY master into the append-only spool, then reaps
// the child. The spool file descriptor stays O_APPEND, so TruncateSpool can
// compact the file in place without stopping the drain, exactly like the
// tmux pipe-pane path.
func (p *PTY) copyOutput(session *ptySession) {
	defer close(session.done)
	buffer := make([]byte, 32*1024)
	for {
		read, err := session.master.Read(buffer)
		if read > 0 {
			chunk := buffer[:read]
			_, _ = session.spool.Write(chunk)
			session.vt.Feed(chunk)
		}
		if err != nil {
			break
		}
	}
	_ = session.command.Wait()
	close(session.reaped)
}

// EnsurePipe is idempotent by construction: the PTY runtime owns the spool
// from Create on, so there is no pipe to install on adopt.
func (p *PTY) EnsurePipe(_ context.Context, runtimeName string) error {
	if p.session(runtimeName) == nil {
		return fmt.Errorf("pty session not found: %s", runtimeName)
	}
	return nil
}

func (p *PTY) Input(_ context.Context, runtimeName string, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	session := p.session(runtimeName)
	if session == nil {
		return fmt.Errorf("pty session not found: %s", runtimeName)
	}
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	if _, err := session.master.Write(data); err != nil {
		return fmt.Errorf("write pty input: %w", err)
	}
	return nil
}

func (p *PTY) Resize(_ context.Context, runtimeName string, columns, rows int) error {
	if columns <= 0 || rows <= 0 {
		return nil
	}
	session := p.session(runtimeName)
	if session == nil {
		return fmt.Errorf("pty session not found: %s", runtimeName)
	}
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	if err := pty.Setsize(session.master, &pty.Winsize{Cols: uint16(columns), Rows: uint16(rows)}); err != nil {
		return err
	}
	session.vt.Resize(columns, rows)
	return nil
}

// Capture renders the current emulated screen (visible grid + scrollback)
// with SGR styles preserved, so the client can replay a complete snapshot at
// its own size. This replaces the raw spool replay, which could not restore
// the screen when the PTY history was produced at a different size.
func (p *PTY) Capture(_ context.Context, runtimeName string) ([]byte, error) {
	session := p.session(runtimeName)
	if session == nil {
		return nil, fmt.Errorf("pty session not found: %s", runtimeName)
	}
	snapshot, err := session.vt.Snapshot()
	if err != nil {
		return nil, err
	}
	result := make([]byte, 0, len(snapshot)+7)
	result = append(result, "\x1b[3J\x1b[2J\x1b[H"...)
	result = append(result, snapshot...)
	return result, nil
}

// Recover returns the spool bytes in [offset, end), the raw PTY output a
// client still needs after its anchor. Host prefers this over a full reanchor
// snapshot whenever the spool still covers the anchor, so switching back to a
// retained surface renders the missing tail without clearing the screen.
func (p *PTY) Recover(_ context.Context, runtimeName string, offset, end int64) ([]byte, error) {
	if p.session(runtimeName) == nil {
		return nil, fmt.Errorf("pty session not found: %s", runtimeName)
	}
	file, err := os.Open(p.SpoolPath(runtimeName))
	if err != nil {
		return nil, fmt.Errorf("open output spool: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if offset < 0 {
		offset = 0
	}
	if offset > info.Size() {
		return nil, fmt.Errorf("spool offset %d beyond size %d", offset, info.Size())
	}
	if end > info.Size() {
		end = info.Size()
	}
	if end < offset {
		end = offset
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	data := make([]byte, end-offset)
	if _, err := io.ReadFull(file, data); err != nil {
		return nil, err
	}
	return data, nil
}

func (p *PTY) Kill(_ context.Context, runtimeName string) error {
	session := p.session(runtimeName)
	if session != nil {
		p.removeSession(runtimeName)
		return p.terminate(session)
	}
	// Unknown to this process: the daemon restarted and the metadata files
	// are the only handle to the orphaned child.
	pid := readPID(p.PIDPath(runtimeName))
	if pid <= 0 {
		return nil
	}
	_ = syscall.Kill(-pid, syscall.SIGHUP)
	time.Sleep(500 * time.Millisecond)
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	return nil
}

func (p *PTY) terminate(session *ptySession) error {
	select {
	case <-session.done:
		// The child already exited and was reaped by copyOutput.
		session.close()
		return nil
	default:
	}
	if session.command.Process != nil {
		_ = syscall.Kill(-session.command.Process.Pid, syscall.SIGHUP)
	}
	select {
	case <-session.reaped:
	case <-time.After(time.Second):
		if session.command.Process != nil {
			_ = syscall.Kill(-session.command.Process.Pid, syscall.SIGKILL)
		}
		<-session.reaped
	}
	session.close()
	return nil
}

func (s *ptySession) close() {
	s.closeOnce.Do(func() {
		_ = s.master.Close()
		_ = s.spool.Close()
		s.vt.Close()
	})
}

func (p *PTY) Exists(_ context.Context, runtimeName string) bool {
	session := p.session(runtimeName)
	if session == nil {
		return false
	}
	select {
	case <-session.done:
		return false
	default:
		return true
	}
}

func (p *PTY) List(context.Context) (map[string]bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	sessions := make(map[string]bool, len(p.sessions))
	for name, session := range p.sessions {
		select {
		case <-session.done:
		default:
			sessions[name] = true
		}
	}
	return sessions, nil
}

// ListCreated returns live sessions with their creation time, persisted in
// metadata files so a restarted daemon can reclaim orphans it no longer has
// a process handle for.
func (p *PTY) ListCreated(context.Context) (map[string]time.Time, error) {
	matches, err := filepath.Glob(filepath.Join(p.outputDir(), "*"+spoolSuffix+createdSuffix))
	if err != nil {
		return nil, err
	}
	sessions := make(map[string]time.Time, len(matches))
	for _, match := range matches {
		name := strings.TrimSuffix(filepath.Base(match), spoolSuffix+createdSuffix)
		data, err := os.ReadFile(match)
		if err != nil {
			continue
		}
		seconds, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
		if err != nil {
			continue
		}
		sessions[name] = time.Unix(seconds, 0)
	}
	return sessions, nil
}

func (p *PTY) SpoolPath(runtimeName string) string {
	return filepath.Join(p.outputDir(), runtimeName+spoolSuffix)
}

func (p *PTY) CreatedPath(runtimeName string) string {
	return p.SpoolPath(runtimeName) + createdSuffix
}

func (p *PTY) PIDPath(runtimeName string) string {
	return p.SpoolPath(runtimeName) + pidSuffix
}

func (p *PTY) SpoolSize(_ context.Context, runtimeName string) (int64, error) {
	info, err := os.Stat(p.SpoolPath(runtimeName))
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

// TruncateSpool compacts the live spool in place. The copyOutput goroutine
// keeps its O_APPEND file descriptor, so output continues into the same
// inode from byte zero; Host bumps the epoch and reanchors clients.
func (p *PTY) TruncateSpool(_ context.Context, runtimeName string) error {
	if err := os.Truncate(p.SpoolPath(runtimeName), 0); err != nil {
		return fmt.Errorf("truncate output spool: %w", err)
	}
	return nil
}

// ArchiveSpool compresses the current spool to a timestamped .gz file and
// prunes old archives. Best-effort diagnostics; truncation must not depend
// on archive success. Mirrors the tmux adapter's spool helpers.
func (p *PTY) ArchiveSpool(_ context.Context, runtimeName string) error {
	path := p.SpoolPath(runtimeName)
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
	return p.pruneArchives(path)
}

func (p *PTY) pruneArchives(path string) error {
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

func (p *PTY) RemoveSpool(runtimeName string) {
	_ = os.Remove(p.SpoolPath(runtimeName))
	_ = os.Remove(p.CreatedPath(runtimeName))
	_ = os.Remove(p.PIDPath(runtimeName))
	for _, match := range mustGlob(p.SpoolPath(runtimeName) + ".*.gz") {
		_ = os.Remove(match)
	}
}

func (p *PTY) outputDir() string {
	if p.OutputDir != "" {
		return p.OutputDir
	}
	return defaultOutputDirectory()
}

func (p *PTY) session(name string) *ptySession {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.sessions[name]
}

func (p *PTY) removeSession(name string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.sessions, name)
}

func readPID(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0
	}
	return pid
}

const (
	spoolSuffix   = ".out"
	createdSuffix = ".created"
	pidSuffix     = ".pid"
)
