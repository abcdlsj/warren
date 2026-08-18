package server

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type gitRepo struct {
	path string
	run  func(arguments ...string)
}

func newGitRepo(t *testing.T, defaultBranch string) gitRepo {
	t.Helper()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit := func(arguments ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", repository}, arguments...)...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", arguments, output, err)
		}
	}
	runGit("init", "--quiet")
	output, err := exec.Command("git", "-C", repository, "symbolic-ref", "--quiet", "HEAD").Output()
	if err != nil {
		t.Fatalf("git symbolic-ref HEAD: %v", err)
	}
	if strings.TrimSpace(string(output)) != "refs/heads/"+defaultBranch {
		runGit("checkout", "--quiet", "-b", defaultBranch)
	}
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("warren\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit("add", "README.md")
	runGit("commit", "--quiet", "-m", "init")
	return gitRepo{path: repository, run: runGit}
}

func newMergeTestService(t *testing.T, project api.Project, workspaces []api.Workspace) (*Service, *store.Store) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = append(value.Projects, project)
		value.Workspaces = append(value.Workspaces, workspaces...)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return &Service{Store: state}, state
}

func mergeStateOf(t *testing.T, service *Service, workspaceID string) (api.MergeState, bool) {
	t.Helper()
	return service.mergeCache.get(workspaceID)
}

func TestRefreshMergeStatesClassifiesSquashMergedAndAheadBranches(t *testing.T) {
	t.Parallel()
	repo := newGitRepo(t, "main")
	repo.run("checkout", "--quiet", "-b", "feature/merged")
	if err := os.WriteFile(filepath.Join(repo.path, "feature-1.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo.run("add", "feature-1.txt")
	repo.run("commit", "--quiet", "-m", "feature work one")
	if err := os.WriteFile(filepath.Join(repo.path, "feature-2.txt"), []byte("two\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo.run("add", "feature-2.txt")
	repo.run("commit", "--quiet", "-m", "feature work two")
	repo.run("checkout", "--quiet", "main")
	repo.run("merge", "--squash", "feature/merged")
	repo.run("commit", "--quiet", "-m", "squash merge feature/merged")
	if err := os.WriteFile(filepath.Join(repo.path, "unrelated.txt"), []byte("later\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo.run("add", "unrelated.txt")
	repo.run("commit", "--quiet", "-m", "main advanced after the merge")

	// The strict ancestry check must not recognize a squash merge; the merge
	// projection exists precisely to cover this case.
	if err := exec.Command("git", "-C", repo.path,
		"merge-base", "--is-ancestor", "feature/merged", "main").Run(); err == nil {
		t.Fatal("squash merge unexpectedly made the branch an ancestor of main")
	}

	repo.run("checkout", "--quiet", "-b", "feature/ahead")
	if err := os.WriteFile(filepath.Join(repo.path, "ahead.txt"), []byte("ahead\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo.run("add", "ahead.txt")
	repo.run("commit", "--quiet", "-m", "unmerged work")
	repo.run("checkout", "--quiet", "main")

	project := api.Project{ID: "project-1", Name: "repo", Path: repo.path}
	workspaces := []api.Workspace{
		{ID: "ws-merged", ProjectID: "project-1", Branch: "feature/merged", Kind: "worktree"},
		{ID: "ws-ahead", ProjectID: "project-1", Branch: "feature/ahead", Kind: "worktree"},
		{ID: "ws-root", ProjectID: "project-1", Branch: "main", Kind: "root"},
	}
	service, _ := newMergeTestService(t, project, workspaces)
	service.refreshMergeStates(context.Background())

	if state, ok := mergeStateOf(t, service, "ws-merged"); !ok || state != api.MergeStateMerged {
		t.Errorf("ws-merged state = %q/%v, want merged", state, ok)
	}
	if state, ok := mergeStateOf(t, service, "ws-ahead"); !ok || state != api.MergeStateUnmerged {
		t.Errorf("ws-ahead state = %q/%v, want unmerged", state, ok)
	}
	if _, ok := mergeStateOf(t, service, "ws-root"); ok {
		t.Error("root workspace must not carry a merge state")
	}

	roster, _ := service.RosterVersion(context.Background())
	states := make(map[string]api.MergeState, len(roster.Workspaces))
	for _, workspace := range roster.Workspaces {
		states[workspace.ID] = workspace.MergeState
	}
	if states["ws-merged"] != api.MergeStateMerged {
		t.Errorf("roster merge state = %q, want merged", states["ws-merged"])
	}
	if states["ws-ahead"] != api.MergeStateUnmerged {
		t.Errorf("roster merge state = %q, want unmerged", states["ws-ahead"])
	}
	if states["ws-root"] != "" {
		t.Errorf("roster merge state = %q, want empty", states["ws-root"])
	}
}

func TestRefreshMergeStatesFallsBackToMaster(t *testing.T) {
	t.Parallel()
	repo := newGitRepo(t, "master")
	repo.run("checkout", "--quiet", "-b", "feature/merged")
	if err := os.WriteFile(filepath.Join(repo.path, "feature.txt"), []byte("merged\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo.run("add", "feature.txt")
	repo.run("commit", "--quiet", "-m", "feature work")
	repo.run("checkout", "--quiet", "master")
	repo.run("merge", "--quiet", "--no-ff", "feature/merged", "-m", "merge feature/merged")

	project := api.Project{ID: "project-1", Name: "repo", Path: repo.path}
	service, _ := newMergeTestService(t, project, []api.Workspace{
		{ID: "ws-merged", ProjectID: "project-1", Branch: "feature/merged", Kind: "worktree"},
	})
	service.refreshMergeStates(context.Background())

	if state, ok := mergeStateOf(t, service, "ws-merged"); !ok || state != api.MergeStateMerged {
		t.Errorf("master-backed workspace state = %q/%v, want merged", state, ok)
	}
}

func TestRefreshMergeStatesLeavesUnqueryableReposUnknown(t *testing.T) {
	t.Parallel()
	project := api.Project{ID: "project-1", Name: "missing", Path: filepath.Join(t.TempDir(), "missing")}
	service, _ := newMergeTestService(t, project, []api.Workspace{
		{ID: "ws-missing", ProjectID: "project-1", Branch: "feature/x", Kind: "worktree"},
	})
	service.refreshMergeStates(context.Background())

	if state, ok := mergeStateOf(t, service, "ws-missing"); ok {
		t.Errorf("missing repo state = %q, want unknown", state)
	}
}

func TestRefreshMergeStatesPrunesRemovedWorkspaces(t *testing.T) {
	t.Parallel()
	repo := newGitRepo(t, "main")
	repo.run("checkout", "--quiet", "-b", "feature/merged")
	if err := os.WriteFile(filepath.Join(repo.path, "feature.txt"), []byte("merged\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	repo.run("add", "feature.txt")
	repo.run("commit", "--quiet", "-m", "feature work")
	repo.run("checkout", "--quiet", "main")
	repo.run("merge", "--quiet", "--no-ff", "feature/merged", "-m", "merge feature/merged")

	project := api.Project{ID: "project-1", Name: "repo", Path: repo.path}
	service, _ := newMergeTestService(t, project, []api.Workspace{
		{ID: "ws-merged", ProjectID: "project-1", Branch: "feature/merged", Kind: "worktree"},
	})
	service.refreshMergeStates(context.Background())
	if state, ok := mergeStateOf(t, service, "ws-merged"); !ok || state != api.MergeStateMerged {
		t.Fatalf("workspace state = %q/%v, want merged", state, ok)
	}

	if err := service.RemoveWorkspace(context.Background(), "ws-merged", RemoveWorkspaceOptions{Force: true}); err != nil {
		t.Fatal(err)
	}
	service.refreshMergeStates(context.Background())
	if state, ok := mergeStateOf(t, service, "ws-merged"); ok {
		t.Errorf("removed workspace state = %q, want pruned", state)
	}
}

func TestRosterOverlaysMergeCacheWithoutGit(t *testing.T) {
	t.Parallel()
	project := api.Project{ID: "project-1", Name: "repo", Path: filepath.Join(t.TempDir(), "missing")}
	service, _ := newMergeTestService(t, project, []api.Workspace{
		{ID: "ws-cached", ProjectID: "project-1", Branch: "feature/x", Kind: "worktree"},
	})
	service.lazyInit()
	service.mergeCache.replace(map[string]api.MergeState{"ws-cached": api.MergeStateMerged})

	roster, _ := service.RosterVersion(context.Background())
	if len(roster.Workspaces) != 1 || roster.Workspaces[0].MergeState != api.MergeStateMerged {
		t.Fatalf("roster merge state = %+v, want merged overlay", roster.Workspaces)
	}
}
