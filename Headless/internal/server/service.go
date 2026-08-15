package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

const (
	defaultRingCapacity = 256
	defaultRingMaxBytes = 8 * 1024 * 1024
	defaultMaxSpool     = 64 * 1024 * 1024
	cursorPersistEvery  = 256 * 1024
)

type Service struct {
	Store         *store.Store
	Runtime       Runtime
	WorktreeRoot  string
	MaxSpoolBytes int64
	RingCapacity  int
	RingMaxBytes  int

	outputMu       sync.Mutex
	outputs        map[string]*outputSession
	peers          map[string]map[*wsPeer]struct{}
	focusedPeers   map[string]*wsPeer
	broadcastLocks map[string]*sync.Mutex

	lifecycleOnce   sync.Once
	lifecycleCancel context.CancelFunc
}

type outputSession struct {
	mu                sync.Mutex
	sessionID         string
	runtimeName       string
	ring              *output.Ring
	watcher           *runtime.SpoolWatcher
	persistedSequence uint64
	reanchorRequired  bool
}

type Runtime interface {
	Create(context.Context, string, string, string) error
	Exists(context.Context, string) bool
	Capture(context.Context, string) ([]byte, error)
	Input(context.Context, string, []byte) error
	Resize(context.Context, string, int, int) error
	Kill(context.Context, string) error
}

type RuntimeLister interface {
	List(context.Context) (map[string]bool, error)
}

// OutputRuntime is implemented by the tmux adapter: pipe-pane installs an
// idempotent raw byte pipe and the service owns one SpoolWatcher per session.
type OutputRuntime interface {
	Runtime
	EnsurePipe(context.Context, string) error
	SpoolPath(string) string
	SpoolSize(context.Context, string) (int64, error)
	TruncateSpool(context.Context, string) error
	ArchiveSpool(context.Context, string) error
	RemoveSpool(string)
}

func (s *Service) outputAdapter() OutputRuntime {
	adapter, _ := s.Runtime.(OutputRuntime)
	return adapter
}

func (s *Service) lazyInit() {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	s.lazyInitLocked()
}

func (s *Service) lazyInitLocked() {
	if s.outputs == nil {
		s.outputs = map[string]*outputSession{}
	}
	if s.peers == nil {
		s.peers = map[string]map[*wsPeer]struct{}{}
	}
	if s.focusedPeers == nil {
		s.focusedPeers = map[string]*wsPeer{}
	}
	if s.broadcastLocks == nil {
		s.broadcastLocks = map[string]*sync.Mutex{}
	}
}

// Start runs the single lifecycle watcher. One goroutine probes tmux for all
// managed sessions; it never creates a polling task per Session.
func (s *Service) Start(parent context.Context) {
	s.lifecycleOnce.Do(func() {
		ctx, cancel := context.WithCancel(context.WithoutCancel(parent))
		s.lifecycleCancel = cancel
		go s.lifecycleLoop(ctx)
	})
}

func (s *Service) Shutdown() {
	if s.lifecycleCancel != nil {
		s.lifecycleCancel()
	}
	s.outputMu.Lock()
	outputs := make([]*outputSession, 0, len(s.outputs))
	for _, outputSession := range s.outputs {
		outputs = append(outputs, outputSession)
	}
	s.outputMu.Unlock()
	for _, outputSession := range outputs {
		outputSession.watcher.Close()
		outputSession.mu.Lock()
		_ = s.persistCursorLocked(outputSession)
		outputSession.mu.Unlock()
	}
}

func (s *Service) lifecycleLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	s.reconcile(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.reconcile(ctx)
		}
	}
}

func (s *Service) reconcile(ctx context.Context) {
	probeContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	running := s.runningSessions(probeContext)
	for _, session := range s.Store.Snapshot().Sessions {
		if session.Lifecycle != "running" {
			s.stopOutput(session.ID, false)
			continue
		}
		if !running(session.Runtime) {
			s.markEnded(session.ID)
			continue
		}
		_, _ = s.ensureOutput(ctx, session)
	}
}

func (s *Service) Roster(ctx context.Context) api.State {
	state, _ := s.RosterVersion(ctx)
	return state
}

func (s *Service) RosterVersion(ctx context.Context) (api.State, uint64) {
	state, revision := s.Store.SnapshotVersion()
	changed := false
	now := time.Now().UTC()
	// A roster request can be cancelled when a WebSocket disconnects. That
	// cancellation says nothing about the tmux process: using the cancelled
	// request context for the probe makes List fail and Exists return false,
	// which incorrectly ends a session that was just created or is still alive.
	// Keep the probe independent of the observer lifecycle, but bounded so a
	// broken runtime cannot hold roster reconciliation forever.
	probeContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	running := s.runningSessions(probeContext)
	for i := range state.Sessions {
		if state.Sessions[i].Lifecycle == "running" && !running(state.Sessions[i].Runtime) {
			state.Sessions[i].Lifecycle = "ended"
			state.Sessions[i].EndedAt = &now
			changed = true
		}
	}
	if changed {
		ended := make(map[string]time.Time)
		for _, session := range state.Sessions {
			if session.EndedAt != nil {
				ended[session.ID] = *session.EndedAt
			}
		}
		_ = s.Store.Update(func(value *api.State) error {
			for index := range value.Sessions {
				if endedAt, ok := ended[value.Sessions[index].ID]; ok && value.Sessions[index].Lifecycle == "running" {
					value.Sessions[index].Lifecycle = "ended"
					value.Sessions[index].EndedAt = &endedAt
				}
			}
			return nil
		})
		for sessionID := range ended {
			s.stopOutput(sessionID, true)
		}
		state, revision = s.Store.SnapshotVersion()
	}
	sort.Slice(state.Projects, func(i, j int) bool { return state.Projects[i].Name < state.Projects[j].Name })
	sort.Slice(state.Workspaces, func(i, j int) bool { return state.Workspaces[i].CreatedAt.Before(state.Workspaces[j].CreatedAt) })
	sort.Slice(state.Sessions, func(i, j int) bool { return state.Sessions[i].CreatedAt.Before(state.Sessions[j].CreatedAt) })
	return state, revision
}

func (s *Service) runningSessions(ctx context.Context) func(string) bool {
	if runtimeAdapter, ok := s.Runtime.(RuntimeLister); ok {
		if sessions, err := runtimeAdapter.List(ctx); err == nil {
			return func(name string) bool { return sessions[name] }
		}
	}
	return func(name string) bool { return s.Runtime.Exists(ctx, name) }
}

func (s *Service) AddProject(path, name string) (api.Project, error) {
	resolved, err := filepath.Abs(expandHome(strings.TrimSpace(path)))
	if err != nil {
		return api.Project{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return api.Project{}, fmt.Errorf("project path is not a directory: %s", resolved)
	}
	if output, err := exec.Command("git", "-C", resolved, "rev-parse", "--show-toplevel").Output(); err == nil {
		resolved = strings.TrimSpace(string(output))
	} else {
		return api.Project{}, fmt.Errorf("project is not a Git repository: %s", resolved)
	}
	if name == "" {
		name = filepath.Base(resolved)
	}
	project := api.Project{ID: store.NewID(), Name: name, Path: resolved, CreatedAt: time.Now().UTC()}
	branch := gitOutput(resolved, "branch", "--show-current")
	workspace := api.Workspace{ID: store.NewID(), ProjectID: project.ID, Name: defaultValue(branch, "main"), Path: resolved, Branch: branch, Kind: "root", CreatedAt: project.CreatedAt}
	err = s.Store.Update(func(state *api.State) error {
		for _, value := range state.Projects {
			if samePath(value.Path, resolved) {
				return fmt.Errorf("project already exists: %s", resolved)
			}
		}
		state.Projects = append(state.Projects, project)
		state.Workspaces = append(state.Workspaces, workspace)
		return nil
	})
	return project, err
}

func (s *Service) RemoveProject(id string, force bool) error {
	state := s.Store.Snapshot()
	for _, workspace := range state.Workspaces {
		if workspace.ProjectID != id {
			continue
		}
		for _, session := range state.Sessions {
			if session.WorkspaceID == workspace.ID && session.Lifecycle == "running" && !force {
				return errors.New("project has running sessions; use --force")
			}
		}
	}
	if force {
		for _, workspace := range state.Workspaces {
			if workspace.ProjectID == id {
				_ = s.removeWorkspaceRuntime(context.Background(), state, workspace.ID)
			}
		}
	}
	return s.Store.Update(func(value *api.State) error {
		found := false
		workspaceIDs := map[string]bool{}
		for _, p := range value.Projects {
			if p.ID == id {
				found = true
			}
		}
		if !found {
			return fmt.Errorf("project not found: %s", id)
		}
		value.Projects = filter(value.Projects, func(p api.Project) bool { return p.ID != id })
		value.Workspaces = filter(value.Workspaces, func(w api.Workspace) bool {
			if w.ProjectID == id {
				workspaceIDs[w.ID] = true
				return false
			}
			return true
		})
		value.Sessions = filter(value.Sessions, func(session api.Session) bool { return !workspaceIDs[session.WorkspaceID] })
		return nil
	})
}

func (s *Service) CreateWorkspace(projectID, branch, name, path string) (api.Workspace, error) {
	state := s.Store.Snapshot()
	var project *api.Project
	for i := range state.Projects {
		if state.Projects[i].ID == projectID {
			project = &state.Projects[i]
			break
		}
	}
	if project == nil {
		return api.Workspace{}, fmt.Errorf("project not found: %s", projectID)
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return api.Workspace{}, errors.New("branch is required")
	}
	id := store.NewID()
	if name == "" {
		name = branch
	}
	if path != "" {
		if resolved, err := filepath.Abs(expandHome(path)); err == nil {
			if info, statErr := os.Stat(resolved); statErr == nil && info.IsDir() {
				if output, gitErr := exec.Command("git", "-C", resolved, "rev-parse", "--show-toplevel").Output(); gitErr == nil {
					root := strings.TrimSpace(string(output))
					if samePath(root, project.Path) {
						if branch == "" {
							branch = gitOutput(resolved, "branch", "--show-current")
						}
						if name == "" {
							name = defaultValue(branch, "main")
						}
						workspace := api.Workspace{ID: id, ProjectID: projectID, Name: name, Path: resolved, Branch: branch, Kind: "root", CreatedAt: time.Now().UTC()}
						if err := s.Store.Update(func(value *api.State) error { value.Workspaces = append(value.Workspaces, workspace); return nil }); err != nil {
							return api.Workspace{}, err
						}
						return workspace, nil
					}
					if name == "" {
						name = filepath.Base(resolved)
					}
					workspace := api.Workspace{ID: id, ProjectID: projectID, Name: name, Path: resolved, Branch: branch, Kind: "worktree", CreatedAt: time.Now().UTC()}
					if err := s.Store.Update(func(value *api.State) error { value.Workspaces = append(value.Workspaces, workspace); return nil }); err != nil {
						return api.Workspace{}, err
					}
					return workspace, nil
				}
			}
		}
	}
	if path == "" {
		path = filepath.Join(expandHome(s.WorktreeRoot), project.ID[:8], id[:8]+"-"+safeName(branch))
	}
	path, _ = filepath.Abs(expandHome(path))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return api.Workspace{}, err
	}
	args := []string{"-C", project.Path, "worktree", "add", path, branch}
	if exec.Command("git", "-C", project.Path, "show-ref", "--verify", "--quiet", "refs/heads/"+branch).Run() != nil {
		args = []string{"-C", project.Path, "worktree", "add", "-b", branch, path}
	}
	if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
		return api.Workspace{}, fmt.Errorf("git worktree add: %s: %w", strings.TrimSpace(string(output)), err)
	}
	workspace := api.Workspace{ID: id, ProjectID: projectID, Name: name, Path: path, Branch: branch, Kind: "worktree", CreatedAt: time.Now().UTC()}
	if err := s.Store.Update(func(value *api.State) error { value.Workspaces = append(value.Workspaces, workspace); return nil }); err != nil {
		_, _ = exec.Command("git", "-C", project.Path, "worktree", "remove", "--force", path).CombinedOutput()
		return api.Workspace{}, err
	}
	return workspace, nil
}

func (s *Service) RemoveWorkspace(ctx context.Context, id string, force bool) error {
	state := s.Store.Snapshot()
	var workspace *api.Workspace
	for i := range state.Workspaces {
		if state.Workspaces[i].ID == id {
			workspace = &state.Workspaces[i]
			break
		}
	}
	if workspace == nil {
		return fmt.Errorf("workspace not found: %s", id)
	}
	for _, session := range state.Sessions {
		if session.WorkspaceID == id && session.Lifecycle == "running" && !force {
			return errors.New("workspace has running sessions; use --force")
		}
	}
	if force {
		_ = s.removeWorkspaceRuntime(ctx, state, id)
	}
	if workspace.Kind == "worktree" {
		var project api.Project
		for _, value := range state.Projects {
			if value.ID == workspace.ProjectID {
				project = value
			}
		}
		if output, err := exec.Command("git", "-C", project.Path, "worktree", "remove", "--force", workspace.Path).CombinedOutput(); err != nil {
			return fmt.Errorf("git worktree remove: %s: %w", strings.TrimSpace(string(output)), err)
		}
	}
	return s.Store.Update(func(value *api.State) error {
		value.Workspaces = filter(value.Workspaces, func(w api.Workspace) bool { return w.ID != id })
		value.Sessions = filter(value.Sessions, func(session api.Session) bool { return session.WorkspaceID != id })
		return nil
	})
}

func (s *Service) CreateSession(ctx context.Context, workspaceID, command, kind, title string) (api.Session, error) {
	state := s.Store.Snapshot()
	var workspace *api.Workspace
	for i := range state.Workspaces {
		if state.Workspaces[i].ID == workspaceID {
			workspace = &state.Workspaces[i]
			break
		}
	}
	if workspace == nil {
		return api.Session{}, fmt.Errorf("workspace not found: %s", workspaceID)
	}
	id := store.NewID()
	runtimeName := "warren_" + strings.ReplaceAll(id, "-", "")
	if kind == "" {
		kind = "shell"
	}
	if title == "" {
		title = map[string]string{"shell": "Shell", "codex": "Codex", "claude": "Claude Code"}[kind]
	}
	if title == "" {
		title = strings.Fields(command)[0]
	}
	if err := s.Runtime.Create(ctx, runtimeName, workspace.Path, command); err != nil {
		return api.Session{}, err
	}
	session := api.Session{ID: id, WorkspaceID: workspaceID, Title: title, Kind: kind, Command: command, Runtime: runtimeName, Lifecycle: "running", CreatedAt: time.Now().UTC()}
	if err := s.Store.Update(func(value *api.State) error { value.Sessions = append(value.Sessions, session); return nil }); err != nil {
		_ = s.Runtime.Kill(ctx, runtimeName)
		return api.Session{}, err
	}
	if _, err := s.ensureOutput(ctx, session); err != nil {
		_ = s.Runtime.Kill(ctx, runtimeName)
		_ = s.Store.Update(func(value *api.State) error {
			value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
			return nil
		})
		if adapter := s.outputAdapter(); adapter != nil {
			adapter.RemoveSpool(runtimeName)
		}
		return api.Session{}, err
	}
	return session, nil
}

func (s *Service) DeleteSession(ctx context.Context, id string) error {
	state := s.Store.Snapshot()
	var session *api.Session
	for i := range state.Sessions {
		if state.Sessions[i].ID == id {
			session = &state.Sessions[i]
			break
		}
	}
	if session == nil {
		return fmt.Errorf("session not found: %s", id)
	}
	// Only explicit Close Tab / Terminate Session reaches kill-session.
	if err := s.Runtime.Kill(ctx, session.Runtime); err != nil {
		return err
	}
	s.stopOutput(id, true)
	if adapter := s.outputAdapter(); adapter != nil {
		adapter.RemoveSpool(session.Runtime)
	}
	return s.Store.Update(func(value *api.State) error {
		value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
		return nil
	})
}

func (s *Service) Session(id string) (api.Session, bool) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID == id {
			return session, true
		}
	}
	return api.Session{}, false
}

func (s *Service) removeWorkspaceRuntime(ctx context.Context, state api.State, workspaceID string) error {
	for _, session := range state.Sessions {
		if session.WorkspaceID == workspaceID {
			_ = s.Runtime.Kill(ctx, session.Runtime)
			s.stopOutput(session.ID, true)
			if adapter := s.outputAdapter(); adapter != nil {
				adapter.RemoveSpool(session.Runtime)
			}
		}
	}
	return nil
}

// ensureOutput adopts a running Session: idempotently installs the output
// pipe, opens the spool watcher from the persisted offset, and creates the
// output ring. Repeating attach/adopt never stacks another pipe.
func (s *Service) ensureOutput(ctx context.Context, session api.Session) (*outputSession, error) {
	s.lazyInit()
	s.outputMu.Lock()
	if existing := s.outputs[session.ID]; existing != nil {
		s.outputMu.Unlock()
		return existing, nil
	}
	s.outputMu.Unlock()

	adapter := s.outputAdapter()
	if adapter == nil {
		ring := output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence)
		outputSession := &outputSession{sessionID: session.ID, runtimeName: session.Runtime, ring: ring}
		s.outputMu.Lock()
		s.outputs[session.ID] = outputSession
		s.outputMu.Unlock()
		return outputSession, nil
	}
	if err := adapter.EnsurePipe(ctx, session.Runtime); err != nil {
		return nil, err
	}
	spoolOffset := int64(session.Sequence)
	if size, err := adapter.SpoolSize(ctx, session.Runtime); err == nil && size < spoolOffset {
		spoolOffset = 0
	}
	// Adoption always reanchors the next client once: tmux may have emitted
	// bytes while this Host was down and the spool could not capture them.
	// A snapshot restores the screen without pretending the byte stream has
	// no gap.
	outputSession := &outputSession{
		sessionID:         session.ID,
		runtimeName:       session.Runtime,
		persistedSequence: session.Sequence,
		reanchorRequired:  true,
	}
	watcher, err := runtime.NewSpoolWatcher(
		adapter.SpoolPath(session.Runtime),
		spoolOffset,
		func(data []byte) { s.recordOutput(session.ID, data) },
		func() { s.rotated(session.ID) },
		func() { s.compactSpool(session.ID) },
	)
	if err != nil {
		return nil, fmt.Errorf("watch output spool: %w", err)
	}
	watcher.SetMaxBytes(s.maxSpoolBytes())
	watcher.Start()
	outputSession.watcher = watcher
	outputSession.ring = output.NewRing(session.Epoch, s.ringCapacity(), s.ringMaxBytes(), session.Sequence)

	s.outputMu.Lock()
	if previous := s.outputs[session.ID]; previous != nil {
		s.outputMu.Unlock()
		watcher.Close()
		return previous, nil
	}
	s.outputs[session.ID] = outputSession
	s.outputMu.Unlock()
	return outputSession, nil
}

func (s *Service) ringCapacity() int {
	if s.RingCapacity > 0 {
		return s.RingCapacity
	}
	return defaultRingCapacity
}

func (s *Service) ringMaxBytes() int {
	if s.RingMaxBytes > 0 {
		return s.RingMaxBytes
	}
	return defaultRingMaxBytes
}

func (s *Service) maxSpoolBytes() int64 {
	if s.MaxSpoolBytes > 0 {
		return s.MaxSpoolBytes
	}
	return defaultMaxSpool
}

func (s *Service) recordOutput(sessionID string, data []byte) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return
	}
	for _, chunk := range output.SplitPayload(data) {
		outputSession.mu.Lock()
		frame, err := outputSession.ring.Append(sessionID, chunk)
		epoch := outputSession.ring.Epoch
		sequence := outputSession.ring.Upper()
		outputSession.mu.Unlock()
		if err != nil {
			continue
		}
		// Ring first, then clients: recovery is always authoritative even when
		// a peer cannot keep up and has to reconnect.
		s.broadcastFrame(frame)
		s.maybePersistCursor(sessionID, epoch, sequence)
	}
}

func (s *Service) maybePersistCursor(sessionID string, epoch, sequence uint64) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return
	}
	outputSession.mu.Lock()
	if sequence-outputSession.persistedSequence < cursorPersistEvery {
		outputSession.mu.Unlock()
		return
	}
	outputSession.persistedSequence = sequence
	err := s.persistCursorLocked(outputSession)
	outputSession.mu.Unlock()
	_ = err
}

func (s *Service) persistCursorLocked(outputSession *outputSession) error {
	epoch := outputSession.ring.Epoch
	sequence := outputSession.ring.Upper()
	return s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == outputSession.sessionID && value.Sessions[index].Lifecycle == "running" {
				value.Sessions[index].Epoch = epoch
				value.Sessions[index].Sequence = sequence
			}
		}
		return nil
	})
}

func (s *Service) broadcastFrame(frame output.Frame) {
	encoded, err := output.EncodeOutput(frame.SessionID, frame.Epoch, frame.Sequence, frame.Payload)
	if err != nil {
		return
	}
	lock := s.broadcastLock(frame.SessionID)
	lock.Lock()
	defer lock.Unlock()
	s.outputMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers[frame.SessionID]))
	for peer := range s.peers[frame.SessionID] {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	for _, peer := range peers {
		if !peer.enqueueBinary(encoded) {
			s.detachPeer(peer, frame.SessionID)
		}
	}
}

func (s *Service) broadcastLock(sessionID string) *sync.Mutex {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	s.lazyInitLocked()
	lock := s.broadcastLocks[sessionID]
	if lock == nil {
		lock = &sync.Mutex{}
		s.broadcastLocks[sessionID] = lock
	}
	return lock
}

// attachOutput prepares a peer's subscription under the session broadcast
// lock, so recovery replay can never interleave with newer live output.
func (s *Service) attachOutput(ctx context.Context, peer *wsPeer, session api.Session, anchor *output.Anchor) error {
	lock, resume, err := s.prepareAttach(ctx, session)
	if err != nil {
		return err
	}
	defer func() {
		lock.Unlock()
		resume()
	}()
	return s.attachOutputLocked(ctx, peer, session, anchor)
}

// prepareAttach pauses the session's spool watcher before taking the
// broadcast lock. A paused watcher cannot read or broadcast, so a reanchor
// snapshot is an atomic point in the byte stream: bytes at or below the
// snapshot are represented exactly once.
func (s *Service) prepareAttach(ctx context.Context, session api.Session) (*sync.Mutex, func(), error) {
	outputSession, err := s.ensureOutput(ctx, session)
	if err != nil {
		return nil, nil, err
	}
	resume := func() {}
	if outputSession.watcher != nil {
		outputSession.watcher.Pause()
		resume = outputSession.watcher.Resume
	}
	lock := s.broadcastLock(session.ID)
	lock.Lock()
	return lock, resume, nil
}

func (s *Service) attachOutputLocked(ctx context.Context, peer *wsPeer, session api.Session, anchor *output.Anchor) error {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[session.ID]
	s.outputMu.Unlock()

	s.registerPeer(session.ID, peer)

	outputSession.mu.Lock()
	recovery := outputSession.ring.Recovery(anchor)
	reanchorRequired := outputSession.reanchorRequired
	outputSession.mu.Unlock()

	if !recovery.Reanchor && !reanchorRequired {
		// The attached cursor must point at the first frame the client is
		// about to receive. For a tail recovery the frames are trimmed to
		// start at the requested anchor, which can be after the ring's oldest
		// retained frame; reporting the lower bound would make a valid tail
		// look like a gap and trigger a reconnect loop.
		sequence := recovery.Upper
		if len(recovery.Frames) > 0 {
			sequence = recovery.Frames[0].Sequence
		}
		if err := peer.enqueueAttached(session.ID, recovery.Epoch, sequence, false); err != nil {
			return err
		}
		for _, frame := range recovery.Frames {
			encoded, encodeErr := output.EncodeOutput(frame.SessionID, frame.Epoch, frame.Sequence, frame.Payload)
			if encodeErr != nil {
				return encodeErr
			}
			if !peer.enqueueBinary(encoded) {
				return errors.New("outbound queue overflow during recovery")
			}
		}
		return peer.enqueueSynced(session.ID, recovery.Epoch, recovery.Upper)
	}

	// Reanchor: capture the real tmux screen and replay it as a snapshot
	// reset. Snapshot frames reuse the current upper sequence; clients do not
	// advance their anchor until the synced marker arrives.
	snapshot, err := s.Runtime.Capture(ctx, session.Runtime)
	if err != nil {
		return err
	}
	upper := recovery.Upper
	epoch := recovery.Epoch
	if outputSession != nil && outputSession.watcher != nil {
		// The capture snapshot is a rendered screen, not a byte position in
		// the append-only spool: capture-pane output can be much larger than
		// the raw PTY bytes (clear sequences, cursor restore, padded rows).
		// Skipping to len(snapshot) would overshoot the spool and make the
		// watcher misread every attach as an in-place compaction. Measure the
		// spool size before capturing and re-anchor the byte stream there.
		adapter := s.outputAdapter()
		size, sizeErr := adapter.SpoolSize(ctx, session.Runtime)
		if sizeErr != nil {
			return fmt.Errorf("read output spool size before reanchor: %w", sizeErr)
		}
		if err := outputSession.watcher.SkipTo(size); err != nil {
			return err
		}
		upper = uint64(size)
	}
	if outputSession != nil {
		outputSession.mu.Lock()
		outputSession.ring.Reset(epoch, upper)
		outputSession.persistedSequence = upper
		outputSession.reanchorRequired = false
		outputSession.mu.Unlock()
	}
	if err := peer.enqueueAttached(session.ID, epoch, upper, true); err != nil {
		return err
	}
	for _, chunk := range output.SplitPayload(snapshot) {
		encoded, encodeErr := output.EncodeOutput(session.ID, epoch, upper, chunk)
		if encodeErr != nil {
			return encodeErr
		}
		if !peer.enqueueBinary(encoded) {
			return errors.New("outbound queue overflow during reanchor")
		}
	}
	return peer.enqueueSynced(session.ID, epoch, upper)
}

func (s *Service) PingOutput(sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession != nil && outputSession.watcher != nil {
		outputSession.watcher.Ping()
	}
}

func (s *Service) detachPeer(peer *wsPeer, sessionID string) {
	s.lazyInit()
	s.outputMu.Lock()
	if peers := s.peers[sessionID]; peers != nil {
		delete(peers, peer)
		if len(peers) == 0 {
			delete(s.peers, sessionID)
		}
	}
	if s.focusedPeers[sessionID] == peer {
		delete(s.focusedPeers, sessionID)
	}
	s.outputMu.Unlock()
}

// registerPeer records a live output subscription. It is intentionally kept
// separate from attachOutputLocked so an attach can claim focus and resize
// the runtime before the first snapshot is captured.
func (s *Service) registerPeer(sessionID string, peer *wsPeer) {
	s.lazyInit()
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	if s.peers[sessionID] == nil {
		s.peers[sessionID] = map[*wsPeer]struct{}{}
	}
	s.peers[sessionID][peer] = struct{}{}
}

// focusPeerLocked updates focus ownership and optionally resizes the shared
// runtime. The caller must hold the session broadcast lock. Keeping both
// operations under that lock prevents an old endpoint's resize from racing a
// focus handoff.
func (s *Service) focusPeerLocked(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	focused bool,
	columns, rows int,
	resizeSpecified bool,
) (resized bool, err error) {
	s.lazyInit()
	s.outputMu.Lock()
	_, registered := s.peers[session.ID][peer]
	owner := s.focusedPeers[session.ID]
	s.outputMu.Unlock()
	if !registered {
		return false, nil
	}
	if !focused {
		if owner == peer {
			s.outputMu.Lock()
			if s.focusedPeers[session.ID] == peer {
				delete(s.focusedPeers, session.ID)
			}
			s.outputMu.Unlock()
		}
		return false, nil
	}
	if resizeSpecified {
		if err := s.Runtime.Resize(ctx, session.Runtime, columns, rows); err != nil {
			return false, err
		}
		resized = true
	}
	s.outputMu.Lock()
	// A peer can disconnect while Runtime.Resize is in flight. Do not hand
	// focus back to a socket that has already been removed from the roster.
	if _, stillRegistered := s.peers[session.ID][peer]; !stillRegistered {
		s.outputMu.Unlock()
		return false, nil
	}
	s.focusedPeers[session.ID] = peer
	s.outputMu.Unlock()
	return resized, nil
}

// resizeFocusedLocked only lets the current focused peer mutate the shared
// tmux/PTY size. A background endpoint receives a successful no-op so stale
// browser resize callbacks do not surface as terminal errors.
func (s *Service) resizeFocusedLocked(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	columns, rows int,
) (bool, error) {
	s.lazyInit()
	s.outputMu.Lock()
	focused := s.focusedPeers[session.ID] == peer
	s.outputMu.Unlock()
	if !focused {
		return false, nil
	}
	if err := s.Runtime.Resize(ctx, session.Runtime, columns, rows); err != nil {
		return false, err
	}
	return true, nil
}

func (s *Service) focusPeer(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	focused bool,
	columns, rows int,
	resizeSpecified bool,
) (bool, bool, error) {
	lock := s.broadcastLock(session.ID)
	lock.Lock()
	defer lock.Unlock()
	resized, err := s.focusPeerLocked(ctx, peer, session, focused, columns, rows, resizeSpecified)
	if err != nil {
		return false, false, err
	}
	return s.isFocused(peer, session.ID), resized, nil
}

func (s *Service) resizeFocused(
	ctx context.Context,
	peer *wsPeer,
	session api.Session,
	columns, rows int,
) (bool, error) {
	lock := s.broadcastLock(session.ID)
	lock.Lock()
	defer lock.Unlock()
	return s.resizeFocusedLocked(ctx, peer, session, columns, rows)
}

func (s *Service) isFocused(peer *wsPeer, sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.focusedPeers[sessionID] == peer
}

func (s *Service) hasFocusedPeer(sessionID string) bool {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	return s.focusedPeers[sessionID] != nil
}

func (s *Service) stopOutput(sessionID string, notify bool) {
	s.lazyInit()
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	delete(s.outputs, sessionID)
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		peers = append(peers, peer)
	}
	delete(s.peers, sessionID)
	delete(s.focusedPeers, sessionID)
	s.outputMu.Unlock()
	if outputSession != nil && outputSession.watcher != nil {
		outputSession.watcher.Close()
	}
	if notify {
		for _, peer := range peers {
			_ = peer.enqueueExited(sessionID)
		}
	}
}

func (s *Service) markEnded(sessionID string) {
	now := time.Now().UTC()
	changed := false
	_ = s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == sessionID && value.Sessions[index].Lifecycle == "running" {
				value.Sessions[index].Lifecycle = "ended"
				value.Sessions[index].EndedAt = &now
				changed = true
			}
		}
		return nil
	})
	if changed {
		s.stopOutput(sessionID, true)
	}
}

func (s *Service) compactSpool(sessionID string) {
	state := s.Store.Snapshot()
	var session api.Session
	for _, value := range state.Sessions {
		if value.ID == sessionID {
			session = value
			break
		}
	}
	if session.ID == "" {
		return
	}
	adapter := s.outputAdapter()
	if adapter == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = adapter.ArchiveSpool(ctx, session.Runtime)
	_ = adapter.TruncateSpool(ctx, session.Runtime)
}

// rotated runs when the spool watcher observes an in-place compaction. Host
// bumps the epoch, resets the ring, persists the cursor, and reanchors every
// attached peer with a fresh tmux snapshot.
func (s *Service) rotated(sessionID string) {
	s.lazyInit()
	state := s.Store.Snapshot()
	var session api.Session
	for _, value := range state.Sessions {
		if value.ID == sessionID {
			session = value
			break
		}
	}
	if session.ID == "" {
		return
	}
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return
	}
	lock := s.broadcastLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	outputSession.mu.Lock()
	outputSession.ring.Reset(outputSession.ring.Epoch+1, 0)
	outputSession.persistedSequence = 0
	_ = s.persistCursorLocked(outputSession)
	outputSession.mu.Unlock()

	snapshot, err := s.Runtime.Capture(context.Background(), session.Runtime)
	if err != nil {
		return
	}
	s.outputMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers[sessionID]))
	for peer := range s.peers[sessionID] {
		peers = append(peers, peer)
	}
	s.outputMu.Unlock()
	epoch := outputSession.ring.Epoch
	for _, peer := range peers {
		_ = peer.enqueueAttached(session.ID, epoch, 0, true)
		for _, chunk := range output.SplitPayload(snapshot) {
			if encoded, encodeErr := output.EncodeOutput(session.ID, epoch, 0, chunk); encodeErr == nil {
				if !peer.enqueueBinary(encoded) {
					s.detachPeer(peer, sessionID)
				}
			}
		}
		_ = peer.enqueueSynced(session.ID, epoch, 0)
	}
}

func gitOutput(path string, args ...string) string {
	return strings.TrimSpace(string(mustOutput(exec.Command("git", append([]string{"-C", path}, args...)...))))
}
func mustOutput(command *exec.Cmd) []byte { output, _ := command.Output(); return output }
func defaultValue(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
func expandHome(path string) string {
	if path == "~" {
		home, _ := os.UserHomeDir()
		return home
	}
	if strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, path[2:])
	}
	return path
}
func samePath(left, right string) bool {
	a, _ := filepath.Abs(left)
	b, _ := filepath.Abs(right)
	return filepath.Clean(a) == filepath.Clean(b)
}
func safeName(value string) string {
	replacer := strings.NewReplacer("/", "-", " ", "-", "..", "-")
	return strings.Trim(replacer.Replace(value), ".-")
}
func filter[T any](values []T, keep func(T) bool) []T {
	result := make([]T, 0, len(values))
	for _, value := range values {
		if keep(value) {
			result = append(result, value)
		}
	}
	return result
}
