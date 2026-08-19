package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestMigrateLegacyWorktreeOwnershipUsesWarrenRootOnly(t *testing.T) {
	root := t.TempDir()
	warrenRoot := filepath.Join(root, "warren-worktrees")
	externalRoot := filepath.Join(root, "superset-worktrees")
	legacyPath := filepath.Join(warrenRoot, "project", "legacy")
	externalPath := filepath.Join(externalRoot, "project", "imported")
	for _, path := range []string{legacyPath, externalPath} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	statePath := filepath.Join(root, "state.json")
	state, err := store.Open(statePath, "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: "project", Path: filepath.Join(root, "repository")}}
		value.Workspaces = []api.Workspace{
			{ID: "root", ProjectID: "project", Path: filepath.Join(root, "repository"), Kind: "root"},
			{ID: "legacy", ProjectID: "project", Path: legacyPath, Kind: "worktree"},
			{ID: "external", ProjectID: "project", Path: externalPath, Kind: "worktree"},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	state, err = store.Open(statePath, "test")
	if err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: warrenRoot,
	}
	service.RosterVersion(context.Background())

	snapshot := state.Snapshot()
	if !snapshot.WorktreeOwnershipMigrated {
		t.Fatal("legacy worktree ownership migration was not recorded")
	}
	managed := map[string]bool{}
	for _, workspace := range snapshot.Workspaces {
		managed[workspace.ID] = workspace.ManagedWorktree
	}
	if !managed["legacy"] {
		t.Fatal("legacy Warren worktree was not marked managed")
	}
	if managed["root"] || managed["external"] {
		t.Fatalf("migration marked non-worktree or external checkout: %#v", managed)
	}

	service.migrateLegacyWorktreeOwnership()
	reopened, err := store.Open(statePath, "test")
	if err != nil {
		t.Fatal(err)
	}
	if !reopened.Snapshot().WorktreeOwnershipMigrated {
		t.Fatal("migration marker was not persisted")
	}
}

func TestMigratedLegacyWorktreeCanBeRemovedFromDisk(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repository")
	if err := os.Mkdir(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitForWorktreeTest(t, repository, "init", "--quiet", "--initial-branch=main")
	runGitForWorktreeTest(t, repository, "-c", "user.name=Warren Tests", "-c", "user.email=warren@example.com", "commit", "--quiet", "--allow-empty", "-m", "initial")

	state, err := store.Open(filepath.Join(root, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:        state,
		WorktreeRoot: filepath.Join(root, "worktrees"),
	}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := service.CreateWorkspace(project.ID, "feature/legacy", "", "")
	if err != nil {
		t.Fatal(err)
	}

	if err := state.Update(func(value *api.State) error {
		value.WorktreeOwnershipMigrated = false
		for index := range value.Workspaces {
			if value.Workspaces[index].ID == workspace.ID {
				value.Workspaces[index].ManagedWorktree = false
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service.migrateLegacyWorktreeOwnership()
	var migrated api.Workspace
	for _, value := range state.Snapshot().Workspaces {
		if value.ID == workspace.ID {
			migrated = value
			break
		}
	}
	if !migrated.ManagedWorktree {
		t.Fatal("legacy worktree was not restored to Warren ownership")
	}

	if err := service.RemoveWorkspace(context.Background(), workspace.ID, RemoveWorkspaceOptions{
		Force:          true,
		RemoveWorktree: true,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(workspace.Path); !os.IsNotExist(err) {
		t.Fatalf("migrated worktree remains on disk, stat error: %v", err)
	}
}
