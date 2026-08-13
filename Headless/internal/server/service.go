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
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type Service struct {
	Store        *store.Store
	Runtime      Runtime
	WorktreeRoot string
}

type Runtime interface {
	Create(context.Context, string, string, string) error
	Exists(context.Context, string) bool
	Capture(context.Context, string) ([]byte, error)
	Input(context.Context, string, []byte) error
	Resize(context.Context, string, int, int) error
	Kill(context.Context, string) error
}

func (s *Service) Roster(ctx context.Context) api.State {
	state := s.Store.Snapshot()
	changed := false
	now := time.Now().UTC()
	for i := range state.Sessions {
		if state.Sessions[i].Lifecycle == "running" && !s.Runtime.Exists(ctx, state.Sessions[i].Runtime) {
			state.Sessions[i].Lifecycle = "ended"
			state.Sessions[i].EndedAt = &now
			changed = true
		}
	}
	if changed {
		_ = s.Store.Update(func(value *api.State) error { value.Sessions = state.Sessions; return nil })
	}
	sort.Slice(state.Projects, func(i, j int) bool { return state.Projects[i].Name < state.Projects[j].Name })
	sort.Slice(state.Workspaces, func(i, j int) bool { return state.Workspaces[i].CreatedAt.Before(state.Workspaces[j].CreatedAt) })
	sort.Slice(state.Sessions, func(i, j int) bool { return state.Sessions[i].CreatedAt.Before(state.Sessions[j].CreatedAt) })
	return state
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
	if err := s.Runtime.Kill(ctx, session.Runtime); err != nil {
		return err
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
		}
	}
	return nil
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
