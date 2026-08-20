package git

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Fetch downloads the latest refs from origin so panel comparisons against
// origin/main reflect what is actually on the remote. It never touches the
// working tree, so it is safe during rebases and merges.
func Fetch(ctx context.Context, dir string) error {
	_, err := run(ctx, dir, "fetch", "origin")
	return err
}

// RebaseMain rebases the current branch onto the remote main line ref when it
// is safe: no operation (rebase/merge/cherry-pick/revert) is in progress, the
// working tree is clean, and the branch is not the main line itself. It
// returns an error when any guard fails or git rebase does; the caller treats
// it as a non-fatal skip so the panel still shows the last-known state.
func RebaseMain(ctx context.Context, dir, ref string) error {
	if OperationState(ctx, dir) != "" {
		return errors.New("git operation in progress")
	}
	status, err := StatusFor(ctx, dir)
	if err != nil {
		return err
	}
	if len(status.Changes) > 0 {
		return errors.New("working tree not clean")
	}
	if status.Branch == "" {
		return errors.New("detached HEAD")
	}
	short := strings.TrimPrefix(strings.TrimPrefix(ref, "refs/remotes/"), "origin/")
	if status.Branch == short {
		return errors.New("branch is the main line")
	}
	_, err = run(ctx, dir, "rebase", ref)
	return err
}

// MainBranch returns the remote ref of the repository's main line
// (origin/main, falling back to origin/master), or "" when the remote has
// neither.
func MainBranch(ctx context.Context, dir string) string {
	for _, ref := range []string{"refs/remotes/origin/main", "refs/remotes/origin/master"} {
		if _, err := run(ctx, dir, "rev-parse", "--verify", "--quiet", ref); err == nil {
			return ref
		}
	}
	return ""
}

// IsMerged reports whether HEAD is an ancestor of ref, i.e. every commit on
// the current branch is already reachable from the main line.
func IsMerged(ctx context.Context, dir, ref string) (bool, error) {
	output, err := run(ctx, dir, "rev-list", "--count", ref+"..HEAD")
	if err != nil {
		return false, err
	}
	count, err := strconv.Atoi(strings.TrimSpace(output))
	if err != nil {
		return false, err
	}
	return count == 0, nil
}

// OperationState reports an in-progress git operation by inspecting the
// per-worktree git directory, or "" when the workspace is idle.
func OperationState(ctx context.Context, dir string) string {
	output, err := run(ctx, dir, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return ""
	}
	gitDir := strings.TrimSpace(output)
	for _, marker := range []struct {
		path string
		name string
	}{
		{"rebase-merge", "rebase"},
		{"rebase-apply", "rebase"},
		{"MERGE_HEAD", "merge"},
		{"CHERRY_PICK_HEAD", "cherry-pick"},
		{"REVERT_HEAD", "revert"},
	} {
		if _, err := os.Stat(filepath.Join(gitDir, marker.path)); err == nil {
			return marker.name
		}
	}
	return ""
}
