package server

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/store"
)

func waitForProcessCwd(t *testing.T, pid int, directory string) {
	t.Helper()
	directory = resolvePath(directory)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cwd, err := processCwd(pid); err == nil && resolvePath(cwd) == directory {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("process %d never changed into %s", pid, directory)
}

func waitForCommandExit(t *testing.T, command *exec.Cmd) {
	t.Helper()
	wait := make(chan error, 1)
	go func() {
		wait <- command.Wait()
	}()
	select {
	case <-wait:
		return
	case <-time.After(5 * time.Second):
		t.Fatalf("process %d is still alive", command.Process.Pid)
	}
}

func startSleepIn(t *testing.T, directory string) *exec.Cmd {
	t.Helper()
	command := exec.Command("sh", "-c", `cd "$1" && exec sleep 60`, "sh", directory)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill() })
	return command
}

func TestTerminateProcessesUnderKillsCwdProcesses(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	command := startSleepIn(t, directory)
	waitForProcessCwd(t, command.Process.Pid, directory)

	terminated, err := terminateProcessesUnder(directory)
	if err != nil {
		t.Fatal(err)
	}
	if terminated == 0 {
		t.Fatal("expected at least one terminated process")
	}
	waitForCommandExit(t, command)
}

func TestTerminateProcessesUnderLeavesOutsideProcesses(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	command := exec.Command("sh", "-c", "exec sleep 60")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill() })

	if _, err := terminateProcessesUnder(directory); err != nil {
		t.Fatal(err)
	}
	if !processAlive(command.Process.Pid) {
		t.Fatal("process outside the worktree was terminated")
	}
}

func TestRemoveWorkspaceTerminatesProcessesInWorktree(t *testing.T) {
	t.Parallel()
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
	runGit("config", "user.email", "test@example.com")
	runGit("config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("warren\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit("add", "README.md")
	runGit("commit", "--quiet", "-m", "init")

	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:        state,
		Runtime:      &memoryRuntime{sessions: map[string][]byte{}},
		WorktreeRoot: filepath.Join(directory, "worktrees"),
	}
	project, err := service.AddProject(repository, "")
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := service.CreateWorkspace(project.ID, "feature/terminate-processes", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(workspace.Path); err != nil {
		t.Fatalf("created worktree missing: %v", err)
	}

	command := startSleepIn(t, workspace.Path)
	waitForProcessCwd(t, command.Process.Pid, workspace.Path)

	if err := service.RemoveWorkspace(context.Background(), workspace.ID, RemoveWorkspaceOptions{
		Force:          true,
		RemoveWorktree: true,
	}); err != nil {
		t.Fatal(err)
	}
	waitForCommandExit(t, command)
	if _, err := os.Stat(workspace.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree should be removed, stat error = %v", err)
	}
}
