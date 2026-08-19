package server

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestParseGitWorktreesPorcelain(t *testing.T) {
	input := []byte("worktree /repo\x00HEAD abc\x00branch refs/heads/main\x00unknown future\x00\x00" +
		"worktree /repo-feature\x00HEAD def\x00branch refs/heads/feature/demo\x00locked reason\x00\x00" +
		"worktree /repo-detached\x00HEAD fed\x00detached\x00\x00" +
		"worktree /repo-stale\x00HEAD bad\x00prunable missing gitdir\x00\x00")

	got, err := parseGitWorktreesPorcelain(input)
	if err != nil {
		t.Fatal(err)
	}
	want := []gitWorktree{
		{Path: "/repo", Branch: "main"},
		{Path: "/repo-feature", Branch: "feature/demo", Locked: true},
		{Path: "/repo-detached", Detached: true},
		{Path: "/repo-stale", Prunable: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parsed worktrees: got %#v want %#v", got, want)
	}
}

func TestParseGitWorktreesPorcelainRejectsAttributesBeforeWorktree(t *testing.T) {
	_, err := parseGitWorktreesPorcelain([]byte("HEAD abc\x00branch refs/heads/main\x00"))
	if err == nil {
		t.Fatal("expected malformed worktree error")
	}
}

func TestParseGitWorktreesPorcelainRejectsEmptyPath(t *testing.T) {
	_, err := parseGitWorktreesPorcelain([]byte("worktree \x00HEAD abc\x00"))
	if err == nil {
		t.Fatal("expected empty worktree path error")
	}
}

func TestParseGitWorktreesPorcelainRejectsInvalidCheckoutState(t *testing.T) {
	tests := map[string][]byte{
		"empty branch":        []byte("worktree /repo\x00branch\x00"),
		"branch and detached": []byte("worktree /repo\x00branch refs/heads/main\x00detached\x00"),
	}
	for name, input := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseGitWorktreesPorcelain(input); err == nil {
				t.Fatal("expected invalid checkout state error")
			}
		})
	}
}

func TestWorkspacesForGitWorktreesProjectsValidDirectories(t *testing.T) {
	root := t.TempDir()
	mainPath := filepath.Join(root, "repository")
	featurePath := filepath.Join(root, "feature")
	detachedPath := filepath.Join(root, "detached")
	prunablePath := filepath.Join(root, "prunable")
	permissionPath := filepath.Join(root, "permission")
	filePath := filepath.Join(root, "not-a-directory")
	for _, directory := range []string{mainPath, featurePath, detachedPath, prunablePath, permissionPath} {
		if err := os.Mkdir(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filePath, []byte("file"), 0o644); err != nil {
		t.Fatal(err)
	}
	createdAt := time.Now().UTC()
	worktrees := []gitWorktree{
		{Path: mainPath, Branch: "main"},
		{Path: featurePath, Branch: "feature/demo", Locked: true},
		{Path: detachedPath, Detached: true},
		{Path: prunablePath, Branch: "stale", Prunable: true},
		{Path: filepath.Join(root, "missing"), Branch: "missing"},
		{Path: filepath.Join(mainPath, "."), Branch: "duplicate"},
		{Path: filePath, Branch: "file"},
	}

	got, err := workspacesForGitWorktrees("project", createdAt, worktrees, os.Stat, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("workspace count: got %d want 3: %#v", len(got), got)
	}
	if got[0].Path != mainPath || got[0].Name != "main" || got[0].Branch != "main" || got[0].Kind != "root" || got[0].Order != 0 {
		t.Fatalf("root workspace: %#v", got[0])
	}
	if got[1].Path != featurePath || got[1].Name != "feature/demo" || got[1].Branch != "feature/demo" || got[1].Kind != "worktree" || !got[1].WorktreeLocked || got[1].Order != 1 {
		t.Fatalf("branch workspace: %#v", got[1])
	}
	if got[2].Path != detachedPath || got[2].Name != "detached" || got[2].Branch != "" || got[2].Kind != "worktree" || got[2].Order != 2 {
		t.Fatalf("detached workspace: %#v", got[2])
	}
	for _, workspace := range got {
		if workspace.ProjectID != "project" || workspace.CreatedAt != createdAt || workspace.ID == "" {
			t.Fatalf("shared workspace metadata: %#v", workspace)
		}
	}

	permissionWorktrees := append([]gitWorktree(nil), worktrees[:3]...)
	permissionWorktrees = append(permissionWorktrees, gitWorktree{Path: permissionPath, Branch: "permission"})
	_, err = workspacesForGitWorktrees(
		"project",
		createdAt,
		permissionWorktrees,
		func(path string) (os.FileInfo, error) {
			if path == permissionPath {
				return nil, os.ErrPermission
			}
			return os.Stat(path)
		},
		true,
	)
	if err == nil {
		t.Fatal("expected filesystem permission error")
	}
}

func TestWorkspacesForGitWorktreesRejectsInvalidRoot(t *testing.T) {
	_, err := workspacesForGitWorktrees("project", time.Now().UTC(), []gitWorktree{{Path: "/bare", Bare: true}}, os.Stat, true)
	if err == nil {
		t.Fatal("expected bare repository error")
	}

	_, err = workspacesForGitWorktrees("project", time.Now().UTC(), []gitWorktree{{Path: "/missing"}}, os.Stat, true)
	if err == nil {
		t.Fatal("expected missing root error")
	}
}

func TestAddProjectImportsOnlyMainCheckoutByDefault(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repository")
	featurePath := filepath.Join(root, "feature")
	if err := os.Mkdir(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitForWorktreeTest(t, repository, "init", "--quiet", "--initial-branch=main")
	runGitForWorktreeTest(t, repository, "-c", "user.name=Warren Tests", "-c", "user.email=warren@example.com", "commit", "--quiet", "--allow-empty", "-m", "initial")
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "-b", "feature/demo", featurePath)

	state, err := store.Open(filepath.Join(root, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	project, err := service.AddProject(featurePath, "")
	if err != nil {
		t.Fatal(err)
	}

	snapshot := state.Snapshot()
	if len(snapshot.Projects) != 1 || len(snapshot.Workspaces) != 1 {
		t.Fatalf("imported state: projects=%d workspaces=%d, want 1 workspace", len(snapshot.Projects), len(snapshot.Workspaces))
	}
	workspace := snapshot.Workspaces[0]
	if workspace.Kind != "root" {
		t.Fatalf("workspace kind: got %q want root", workspace.Kind)
	}
	if !samePath(workspace.Path, canonicalWorktreeTestPath(t, repository)) {
		t.Fatalf("workspace path: got %q want %q", workspace.Path, canonicalWorktreeTestPath(t, repository))
	}
	if project.ID != workspace.ProjectID {
		t.Fatalf("workspace project: got %q want %q", workspace.ProjectID, project.ID)
	}
}

func TestAddProjectImportsAllGitWorktrees(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repository")
	featurePath := filepath.Join(root, "feature")
	detachedPath := filepath.Join(root, "detached")
	if err := os.Mkdir(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitForWorktreeTest(t, repository, "init", "--quiet", "--initial-branch=main")
	runGitForWorktreeTest(t, repository, "-c", "user.name=Warren Tests", "-c", "user.email=warren@example.com", "commit", "--quiet", "--allow-empty", "-m", "initial")
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "-b", "feature/demo", featurePath)
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "--detach", detachedPath, "HEAD")
	runGitForWorktreeTest(t, repository, "worktree", "lock", "--reason", "keep", featurePath)

	state, err := store.Open(filepath.Join(root, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	project, err := service.AddProjectWithOptions(detachedPath, "", true)
	if err != nil {
		t.Fatal(err)
	}
	canonicalRepository := canonicalWorktreeTestPath(t, repository)
	if project.Path != canonicalRepository {
		t.Fatalf("canonical project path: got %q want %q", project.Path, canonicalRepository)
	}
	if project.Name != "repository" {
		t.Fatalf("project name: got %q want repository", project.Name)
	}

	snapshot := state.Snapshot()
	if len(snapshot.Projects) != 1 || len(snapshot.Workspaces) != 3 {
		t.Fatalf("imported state: projects=%d workspaces=%d", len(snapshot.Projects), len(snapshot.Workspaces))
	}
	want := []struct {
		path   string
		name   string
		branch string
		kind   string
	}{
		{canonicalRepository, "main", "main", "root"},
		{canonicalWorktreeTestPath(t, detachedPath), "detached", "", "worktree"},
		{canonicalWorktreeTestPath(t, featurePath), "feature/demo", "feature/demo", "worktree"},
	}
	for index, workspace := range snapshot.Workspaces {
		if !samePath(workspace.Path, want[index].path) || workspace.Name != want[index].name || workspace.Branch != want[index].branch || workspace.Kind != want[index].kind || workspace.Order != index {
			t.Fatalf("workspace %d: got %#v want %#v", index, workspace, want[index])
		}
	}

	if _, err := service.AddProject(featurePath, "duplicate"); err == nil {
		t.Fatal("expected duplicate project error")
	}
	afterDuplicate := state.Snapshot()
	if len(afterDuplicate.Projects) != 1 || len(afterDuplicate.Workspaces) != 3 {
		t.Fatalf("duplicate import changed state: projects=%d workspaces=%d", len(afterDuplicate.Projects), len(afterDuplicate.Workspaces))
	}
}

func TestManualProjectWorktreeImportKeepsImportedCandidatesDisabled(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repository")
	featurePath := filepath.Join(root, "feature")
	detachedPath := filepath.Join(root, "detached")
	if err := os.Mkdir(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitForWorktreeTest(t, repository, "init", "--quiet", "--initial-branch=main")
	runGitForWorktreeTest(t, repository, "-c", "user.name=Warren Tests", "-c", "user.email=warren@example.com", "commit", "--quiet", "--allow-empty", "-m", "initial")
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "-b", "feature/demo", featurePath)
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "--detach", detachedPath, "HEAD")

	state, err := store.Open(filepath.Join(root, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}

	candidates, err := service.ListProjectWorktrees(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 2 {
		t.Fatalf("candidate count = %d, want 2: %#v", len(candidates), candidates)
	}
	for _, candidate := range candidates {
		if candidate.Imported {
			t.Fatalf("candidate unexpectedly imported before selection: %#v", candidate)
		}
	}

	created, err := service.ImportProjectWorktrees(project.ID, []string{featurePath})
	if err != nil {
		t.Fatalf("import selected worktree: %v", err)
	}
	if len(created) != 1 || !samePath(created[0].Path, featurePath) || created[0].Kind != "worktree" {
		t.Fatalf("created workspaces = %#v, want feature worktree", created)
	}
	if created[0].ManagedWorktree {
		t.Fatal("manually imported worktree must not be marked Warren-managed")
	}

	candidates, err = service.ListProjectWorktrees(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	var imported, remaining api.WorktreeCandidate
	for _, candidate := range candidates {
		if samePath(candidate.Path, featurePath) {
			imported = candidate
		} else if samePath(candidate.Path, detachedPath) {
			remaining = candidate
		}
	}
	if !imported.Imported || imported.WorkspaceID != created[0].ID {
		t.Fatalf("imported candidate = %#v, want workspace %s", imported, created[0].ID)
	}
	if remaining.Imported {
		t.Fatalf("unselected candidate was marked imported: %#v", remaining)
	}
	if _, err := service.ImportProjectWorktrees(project.ID, []string{featurePath}); err == nil {
		t.Fatal("re-importing an imported candidate must fail so clients keep it disabled")
	}
}

func TestEnablingProjectAutoImportImportsExistingWorktrees(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repository")
	featurePath := filepath.Join(root, "feature")
	if err := os.Mkdir(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitForWorktreeTest(t, repository, "init", "--quiet", "--initial-branch=main")
	runGitForWorktreeTest(t, repository, "-c", "user.name=Warren Tests", "-c", "user.email=warren@example.com", "commit", "--quiet", "--allow-empty", "-m", "initial")
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "-b", "feature/demo", featurePath)

	state, err := store.Open(filepath.Join(root, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	updated, err := service.SetProjectAutoImportGitWorktrees(project.ID, true)
	if err != nil {
		t.Fatalf("enable automatic import: %v", err)
	}
	if !updated.AutoImportGitWorktrees {
		t.Fatal("project auto import flag was not enabled")
	}
	snapshot := state.Snapshot()
	if len(snapshot.Workspaces) != 2 {
		t.Fatalf("workspace count after enabling auto import = %d, want 2", len(snapshot.Workspaces))
	}
	if !samePath(snapshot.Workspaces[1].Path, featurePath) {
		t.Fatalf("auto-imported workspace = %#v, want %s", snapshot.Workspaces[1], featurePath)
	}
}

func TestRemoveImportedWorktreeKeepsUserCheckout(t *testing.T) {
	root := t.TempDir()
	repository := filepath.Join(root, "repository")
	featurePath := filepath.Join(root, "feature")
	if err := os.Mkdir(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitForWorktreeTest(t, repository, "init", "--quiet", "--initial-branch=main")
	runGitForWorktreeTest(t, repository, "-c", "user.name=Warren Tests", "-c", "user.email=warren@example.com", "commit", "--quiet", "--allow-empty", "-m", "initial")
	runGitForWorktreeTest(t, repository, "worktree", "add", "--quiet", "-b", "feature/demo", featurePath)

	state, err := store.Open(filepath.Join(root, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	project, err := service.AddProjectWithOptions(repository, "", true)
	if err != nil {
		t.Fatal(err)
	}

	var imported api.Workspace
	for _, workspace := range state.Snapshot().Workspaces {
		if workspace.ProjectID == project.ID && workspace.Branch == "feature/demo" {
			imported = workspace
			break
		}
	}
	if imported.ID == "" {
		t.Fatal("imported worktree was not registered")
	}
	if imported.ManagedWorktree {
		t.Fatal("imported worktree must not be marked Warren-managed")
	}

	if err := service.RemoveWorkspace(context.Background(), imported.ID, RemoveWorkspaceOptions{
		Force:          true,
		RemoveWorktree: true,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(featurePath); err != nil {
		t.Fatalf("imported checkout was removed: %v", err)
	}
	output, err := exec.Command("git", "-C", repository, "worktree", "list", "--porcelain").Output()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(output), featurePath) {
		t.Fatalf("Git worktree registration was removed: %s", output)
	}
}

func runGitForWorktreeTest(t *testing.T, directory string, arguments ...string) {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", directory}, arguments...)...)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %s: %v", arguments, output, err)
	}
}

func canonicalWorktreeTestPath(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}
