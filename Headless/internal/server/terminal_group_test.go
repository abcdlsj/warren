package server

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type directoryRecordingRuntime struct {
	*memoryRuntime
	directory string
}

type blockingCreateRuntime struct {
	*memoryRuntime
	entered chan struct{}
	release chan struct{}
}

func (runtime *blockingCreateRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	select {
	case <-runtime.entered:
	default:
		close(runtime.entered)
	}
	select {
	case <-runtime.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	return runtime.memoryRuntime.Create(ctx, name, directory, command, env)
}

func (runtime *directoryRecordingRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	runtime.directory = directory
	return runtime.memoryRuntime.Create(ctx, name, directory, command, env)
}

func TestTerminalGroupSessionUsesConfiguredHome(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(t.TempDir(), "group-home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	runtime := &directoryRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	service := &Service{Store: state, Runtime: runtime}

	group, err := service.CreateTerminalGroup("Build", home)
	if err != nil {
		t.Fatal(err)
	}
	session, err := service.CreateGroupSession(context.Background(), group.ID, "", "shell", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if session.WorkspaceID != "" || session.TerminalGroupID != group.ID {
		t.Fatalf("session scope = %#v", session)
	}
	if session.ScopeKind() != api.SessionScopeTerminalGroup {
		t.Fatalf("session scope kind = %q", session.ScopeKind())
	}
	if runtime.directory != home {
		t.Fatalf("runtime directory = %q, want %q", runtime.directory, home)
	}
}

func TestMoveSessionBetweenWorkspaceAndTerminalGroup(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	workspaceDir := filepath.Join(t.TempDir(), "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	groupHome := filepath.Join(t.TempDir(), "group-home")
	if err := os.MkdirAll(groupHome, 0o755); err != nil {
		t.Fatal(err)
	}
	workspace := api.Workspace{
		ID:        "workspace-1",
		ProjectID: "project-1",
		Name:      "main",
		Path:      workspaceDir,
		Kind:      "root",
		CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = append(value.Workspaces, workspace)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	group := state.Snapshot().TerminalGroups[0]
	if err := state.Update(func(value *api.State) error {
		for index := range value.TerminalGroups {
			if value.TerminalGroups[index].ID == group.ID {
				value.TerminalGroups[index].Home = groupHome
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryRuntime(t)
	service := &Service{Store: state, Runtime: runtime}

	session, err := service.CreateGroupSession(context.Background(), group.ID, "", "shell", "", "")
	if err != nil {
		t.Fatal(err)
	}
	moved, err := service.MoveSession(context.Background(), session.ID, workspace.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if moved.WorkspaceID != workspace.ID || moved.TerminalGroupID != "" {
		t.Fatalf("moved to workspace scope = %#v", moved)
	}
	if moved.ScopeKind() != api.SessionScopeWorkspace {
		t.Fatalf("moved scope kind = %q", moved.ScopeKind())
	}
	persisted := state.Snapshot().Sessions[0]
	if persisted.WorkspaceID != workspace.ID || persisted.TerminalGroupID != "" {
		t.Fatalf("persisted workspace scope = %#v", persisted)
	}
	if !runtime.Exists(context.Background(), session.Runtime) {
		t.Fatal("move killed the runtime")
	}

	back, err := service.MoveSession(context.Background(), session.ID, "", group.ID)
	if err != nil {
		t.Fatal(err)
	}
	if back.WorkspaceID != "" || back.TerminalGroupID != group.ID {
		t.Fatalf("moved back to group scope = %#v", back)
	}
	if back.ScopeKind() != api.SessionScopeTerminalGroup {
		t.Fatalf("moved back scope kind = %q", back.ScopeKind())
	}
	if !runtime.Exists(context.Background(), session.Runtime) {
		t.Fatal("second move killed the runtime")
	}
}

func TestMoveSessionValidatesScopeAndTarget(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	group := state.Snapshot().TerminalGroups[0]
	session, err := service.CreateGroupSession(context.Background(), group.ID, "", "shell", "", "")
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name        string
		sessionID   string
		workspaceID string
		groupID     string
		want        string
	}{
		{name: "missing target", sessionID: session.ID, want: "workspace or terminal group is required"},
		{name: "missing session", sessionID: "missing", workspaceID: "workspace-1", want: "session not found: missing"},
		{name: "missing workspace", sessionID: session.ID, workspaceID: "workspace-1", want: "workspace not found: workspace-1"},
		{name: "missing group", sessionID: session.ID, groupID: "missing", want: "terminal group not found: missing"},
		{name: "conflicting targets", sessionID: session.ID, workspaceID: "workspace-1", groupID: group.ID, want: "workspace and terminal group are mutually exclusive"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := service.MoveSession(context.Background(), test.sessionID, test.workspaceID, test.groupID)
			if err == nil || err.Error() != test.want {
				t.Fatalf("MoveSession error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestTerminalGroupDeletionRequiresForceAndRecreatesInbox(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &directoryRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	service := &Service{Store: state, Runtime: runtime}
	group := state.Snapshot().TerminalGroups[0]

	if _, err := service.CreateGroupSession(context.Background(), group.ID, "", "shell", "", ""); err != nil {
		t.Fatal(err)
	}
	if err := service.RemoveTerminalGroup(context.Background(), group.ID, false); err == nil {
		t.Fatal("removing a non-empty group without force should fail")
	}
	if len(state.Snapshot().TerminalGroups) != 1 || len(state.Snapshot().Sessions) != 1 {
		t.Fatal("failed deletion changed persisted state")
	}
	if err := service.RemoveTerminalGroup(context.Background(), group.ID, true); err != nil {
		t.Fatal(err)
	}
	if len(state.Snapshot().TerminalGroups) != 0 || len(state.Snapshot().Sessions) != 0 {
		t.Fatalf("forced deletion left state: %#v", state.Snapshot())
	}

	session, err := service.CreateDefaultGroupSession(context.Background(), "", "shell", "", "")
	if err != nil {
		t.Fatal(err)
	}
	snapshot := state.Snapshot()
	if len(snapshot.TerminalGroups) != 1 || snapshot.TerminalGroups[0].Name != "Inbox" {
		t.Fatalf("default group after deletion = %#v", snapshot.TerminalGroups)
	}
	if session.TerminalGroupID != snapshot.TerminalGroups[0].ID {
		t.Fatalf("default session group = %q, want %q", session.TerminalGroupID, snapshot.TerminalGroups[0].ID)
	}
}

func TestTerminalGroupWebSocketProtocol(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	group := requestResult[api.TerminalGroup](t, connection, "terminal-group.create", map[string]any{
		"name": "Review",
	})
	if group.Name != "Review" {
		t.Fatalf("created group = %#v", group)
	}
	session := requestResult[api.Session](t, connection, "session.create", map[string]any{
		"group": group.ID,
		"kind":  "shell",
	})
	if session.TerminalGroupID != group.ID || session.ScopeKind() != api.SessionScopeTerminalGroup {
		t.Fatalf("created group session = %#v", session)
	}
	roster := requestResult[api.State](t, connection, "roster", nil)
	if len(roster.TerminalGroups) != 2 {
		t.Fatalf("roster groups = %#v", roster.TerminalGroups)
	}
}

func TestSessionMoveWebSocketProtocol(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	workspace := api.Workspace{
		ID:        "workspace-1",
		ProjectID: "project-1",
		Name:      "main",
		Path:      t.TempDir(),
		Kind:      "root",
		CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = append(value.Workspaces, workspace)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	group := state.Snapshot().TerminalGroups[0]
	session := requestResult[api.Session](t, connection, "session.create", map[string]any{
		"group": group.ID,
		"kind":  "shell",
	})
	if session.TerminalGroupID != group.ID {
		t.Fatalf("created group session = %#v", session)
	}

	moved := requestResult[api.Session](t, connection, "session.move", map[string]any{
		"id":        session.ID,
		"workspace": workspace.ID,
	})
	if moved.WorkspaceID != workspace.ID || moved.TerminalGroupID != "" {
		t.Fatalf("moved session = %#v", moved)
	}
	roster := requestResult[api.State](t, connection, "roster", nil)
	var persisted api.Session
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID {
			persisted = candidate
			break
		}
	}
	if persisted.WorkspaceID != workspace.ID || persisted.TerminalGroupID != "" {
		t.Fatalf("roster workspace scope = %#v", persisted)
	}

	back := requestResult[api.Session](t, connection, "session.move", map[string]any{
		"id":    session.ID,
		"group": group.ID,
	})
	if back.WorkspaceID != "" || back.TerminalGroupID != group.ID {
		t.Fatalf("moved back session = %#v", back)
	}
}

func TestTerminalGroupHTTPRejectsConflictingSessionScope(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	errText := requestError(t, connection, "session.create", map[string]any{
		"workspace": "workspace-1",
		"group":     "group-1",
	})
	if errText != "workspace and terminal group are mutually exclusive" {
		t.Fatalf("error = %q", errText)
	}
}

func TestTerminalGroupLifecycleSerializesCreateAndDelete(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &blockingCreateRuntime{
		memoryRuntime: newMemoryRuntime(t),
		entered:       make(chan struct{}),
		release:       make(chan struct{}),
	}
	service := &Service{Store: state, Runtime: runtime}
	group := state.Snapshot().TerminalGroups[0]

	created := make(chan struct {
		session api.Session
		err     error
	}, 1)
	go func() {
		session, err := service.CreateGroupSession(context.Background(), group.ID, "", "shell", "", "")
		created <- struct {
			session api.Session
			err     error
		}{session: session, err: err}
	}()
	select {
	case <-runtime.entered:
	case <-time.After(time.Second):
		t.Fatal("Group Session creation did not reach the runtime")
	}

	removed := make(chan error, 1)
	go func() {
		removed <- service.RemoveTerminalGroup(context.Background(), group.ID, true)
	}()
	select {
	case err := <-removed:
		t.Fatalf("Group deletion completed while creation was in progress: %v", err)
	case <-time.After(25 * time.Millisecond):
	}
	close(runtime.release)

	createdResult := <-created
	if createdResult.err != nil {
		t.Fatalf("CreateGroupSession: %v", createdResult.err)
	}
	if err := <-removed; err != nil {
		t.Fatalf("RemoveTerminalGroup: %v", err)
	}

	snapshot := state.Snapshot()
	if len(snapshot.TerminalGroups) != 0 || len(snapshot.Sessions) != 0 {
		t.Fatalf("lifecycle left durable state: %#v", snapshot)
	}
	if runtime.Exists(context.Background(), createdResult.session.Runtime) {
		t.Fatal("lifecycle left an orphan runtime")
	}
}
