package store

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func BenchmarkSnapshot(b *testing.B) {
	state := api.State{Schema: 1, Host: api.Host{ID: NewID(), Name: "benchmark"}}
	for projectIndex := 0; projectIndex < 50; projectIndex++ {
		projectID := NewID()
		state.Projects = append(state.Projects, api.Project{
			ID: projectID, Name: fmt.Sprintf("project-%d", projectIndex), Path: "/work/project",
		})
		for workspaceIndex := 0; workspaceIndex < 4; workspaceIndex++ {
			workspaceID := NewID()
			state.Workspaces = append(state.Workspaces, api.Workspace{
				ID: workspaceID, ProjectID: projectID, Name: "workspace", Path: "/work/project/worktree",
			})
			for sessionIndex := 0; sessionIndex < 2; sessionIndex++ {
				endedAt := time.Now()
				state.Sessions = append(state.Sessions, api.Session{
					ID: NewID(), WorkspaceID: workspaceID, Runtime: "warren_session", EndedAt: &endedAt,
				})
			}
		}
	}
	store := &Store{state: state}

	b.ReportAllocs()
	for b.Loop() {
		_ = store.Snapshot()
	}
}

func TestSnapshotDoesNotShareMutableState(t *testing.T) {
	endedAt := time.Now()
	store := &Store{changed: make(chan struct{}), state: api.State{
		Projects: []api.Project{{ID: "project"}},
		Sessions: []api.Session{{ID: "session", EndedAt: &endedAt}},
	}}

	snapshot := store.Snapshot()
	snapshot.Projects[0].ID = "changed"
	changedTime := endedAt.Add(time.Hour)
	*snapshot.Sessions[0].EndedAt = changedTime

	current := store.Snapshot()
	if current.Projects[0].ID != "project" || !current.Sessions[0].EndedAt.Equal(endedAt) {
		t.Fatalf("snapshot mutated store: %#v", current)
	}
}

func TestUpdateAdvancesRevisionAndNotifiesWatchers(t *testing.T) {
	store := &Store{changed: make(chan struct{})}
	_, revision := store.SnapshotVersion()
	changed := store.ChangesSince(revision)
	store.path = filepath.Join(t.TempDir(), "state.json")
	if err := store.Update(func(state *api.State) error {
		state.Schema = 1
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	select {
	case <-changed:
	default:
		t.Fatal("watcher was not notified")
	}
	_, nextRevision := store.SnapshotVersion()
	if nextRevision != revision+1 {
		t.Fatalf("revision=%d, want %d", nextRevision, revision+1)
	}
	select {
	case <-store.ChangesSince(revision):
	default:
		t.Fatal("stale revision did not report an immediate change")
	}
}
