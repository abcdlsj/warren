package server

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// mergeRefreshInterval bounds how stale the merge projection may become
	// between background refreshes. Git worktree branches are local refs, so
	// a 30s tick is cheap even with many projects.
	mergeRefreshInterval = 30 * time.Second
	// mergeCommandTimeout bounds every git command so a wedged repository can
	// never stall the background merge loop.
	mergeCommandTimeout = 2 * time.Second
	// mergeRefreshTimeout bounds one whole refresh pass so many workspaces or
	// slow disks cannot leave the projection stale for minutes. Workspaces
	// that did not get checked fall back to unknown on the next roster.
	mergeRefreshTimeout = 15 * time.Second
)

// mergeStateCache holds the latest merge projection per workspace. It is
// written by the background merge loop and read by roster snapshots, so git
// work can never block a broadcast.
type mergeStateCache struct {
	mu     sync.RWMutex
	values map[string]api.MergeState
}

func (c *mergeStateCache) get(workspaceID string) (api.MergeState, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	value, ok := c.values[workspaceID]
	return value, ok
}

// snapshot returns an immutable copy of the projection so one roster snapshot
// never mixes two generations of merge state.
func (c *mergeStateCache) snapshot() map[string]api.MergeState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	next := make(map[string]api.MergeState, len(c.values))
	for workspaceID, state := range c.values {
		next[workspaceID] = state
	}
	return next
}

// replace swaps the whole projection atomically. Workspaces that are no
// longer present, not eligible, or whose repository could not be queried
// simply drop out of the map and render as "unknown".
func (c *mergeStateCache) replace(next map[string]api.MergeState) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values = next
}

// mergeLoop refreshes the merge projection immediately at startup, on every
// tick, and after workspace/project mutations signal the wake channel.
func (s *Service) mergeLoop(ctx context.Context) {
	ticker := time.NewTicker(mergeRefreshInterval)
	defer ticker.Stop()
	s.refreshMergeStates(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.refreshMergeStates(ctx)
		case <-s.mergeWake:
			// Coalesce bursts of mutations into one refresh.
			drained := false
			for !drained {
				select {
				case <-s.mergeWake:
				default:
					drained = true
				}
			}
			s.refreshMergeStates(ctx)
		}
	}
}

// wakeMergeRefresh schedules an immediate background refresh without
// blocking the caller when one is already pending.
func (s *Service) wakeMergeRefresh() {
	s.initMergeState()
	select {
	case s.mergeWake <- struct{}{}:
	default:
	}
}

// refreshMergeStates recomputes the merge projection for every eligible
// worktree workspace. A workspace is eligible when it is a git worktree on a
// named branch that differs from the project's default branch.
func (s *Service) refreshMergeStates(ctx context.Context) {
	if s.Store == nil {
		return
	}
	s.initMergeState()
	refreshCtx, cancel := context.WithTimeout(ctx, mergeRefreshTimeout)
	defer cancel()
	state := s.Store.Snapshot()
	byProject := make(map[string][]api.Workspace)
	for _, workspace := range state.Workspaces {
		if workspace.Kind == "worktree" && workspace.Branch != "" {
			byProject[workspace.ProjectID] = append(byProject[workspace.ProjectID], workspace)
		}
	}
	next := make(map[string]api.MergeState, len(state.Workspaces))
	for _, project := range state.Projects {
		workspaces := byProject[project.ID]
		if len(workspaces) == 0 {
			continue
		}
		defaultName, ok := resolveDefaultBranch(ctx, project.Path)
		if !ok {
			// Unknown default branch: keep every workspace of this project
			// out of the projection instead of guessing.
			continue
		}
		worktreeBranches, ok := worktreeBranchMap(refreshCtx, project.Path)
		if !ok {
			continue
		}
		for _, workspace := range workspaces {
			if workspace.Branch == defaultName {
				continue
			}
			if actual, found := worktreeBranches[worktreePathKey(workspace.Path)]; !found || actual != workspace.Branch {
				// The stored branch no longer matches the worktree HEAD (or
				// the worktree is gone/detached); do not trust stale state.
				continue
			}
			merged, known := branchMergedInto(refreshCtx, project.Path, defaultName, workspace.Branch)
			if !known {
				continue
			}
			if merged {
				next[workspace.ID] = api.MergeStateMerged
			} else {
				next[workspace.ID] = api.MergeStateUnmerged
			}
		}
	}
	s.mergeCache.replace(next)
}

// resolveDefaultBranch returns the project's default branch name. It prefers
// the remote HEAD symref (what the hosting platform declares as default),
// then falls back to local main and master. The returned name is the short
// branch name, e.g. "main".
func resolveDefaultBranch(ctx context.Context, repo string) (string, bool) {
	gitCtx, cancel := context.WithTimeout(ctx, mergeCommandTimeout)
	defer cancel()
	if output, err := exec.CommandContext(gitCtx, "git", "-C", repo,
		"symbolic-ref", "--quiet", "refs/remotes/origin/HEAD").Output(); err == nil {
		ref := strings.TrimSpace(string(output))
		if name := strings.TrimPrefix(ref, "refs/remotes/origin/"); name != ref && name != "" && name != "HEAD" {
			if exec.CommandContext(gitCtx, "git", "-C", repo, "show-ref",
				"--verify", "--quiet", "refs/remotes/origin/"+name).Run() == nil {
				return name, true
			}
		}
	}
	for _, name := range []string{"main", "master"} {
		if exec.CommandContext(gitCtx, "git", "-C", repo, "show-ref",
			"--verify", "--quiet", "refs/heads/"+name).Run() == nil {
			return name, true
		}
	}
	return "", false
}

// worktreeBranchMap maps every registered worktree path to the short branch
// name it currently has checked out. Detached worktrees and entries without a
// branch are omitted, so callers treat them as unknown.
func worktreeBranchMap(ctx context.Context, repo string) (map[string]string, bool) {
	output, err := exec.CommandContext(ctx, "git", "-C", repo,
		"worktree", "list", "--porcelain").Output()
	if err != nil {
		return nil, false
	}
	result := make(map[string]string)
	var path string
	for _, line := range strings.Split(string(output), "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			path = strings.TrimSpace(strings.TrimPrefix(line, "worktree "))
		case strings.HasPrefix(line, "branch "):
			ref := strings.TrimSpace(strings.TrimPrefix(line, "branch "))
			if name := strings.TrimPrefix(ref, "refs/heads/"); name != ref && path != "" {
				result[worktreePathKey(path)] = name
			}
		}
	}
	return result, true
}

// worktreePathKey normalizes a worktree path so paths reached through a
// symlink (for example /var vs /private/var on macOS) compare equal to the
// canonical path git reports.
func worktreePathKey(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return filepath.Clean(absolute)
}

// branchMergedInto reports whether the branch carries no changes that are
// missing from the default branch. Squash and rebase merges are recognized
// even though the original commits are not ancestors of main: instead of
// comparing history, every path the branch changed since it diverged is
// compared against the default branch, so the branch only counts as merged
// when the default branch already contains identical content for those
// paths. Both the local and remote-tracking default refs are checked: a
// local merge that was not pushed yet and a remote merge that was not
// fetched yet are both recognized.
func branchMergedInto(ctx context.Context, repo, defaultName, branch string) (merged, known bool) {
	gitCtx, cancel := context.WithTimeout(ctx, mergeCommandTimeout)
	defer cancel()
	targets := []string{
		"refs/heads/" + defaultName,
		"refs/remotes/origin/" + defaultName,
	}
	checked := false
	for _, target := range targets {
		if err := exec.CommandContext(gitCtx, "git", "-C", repo, "show-ref",
			"--verify", "--quiet", target).Run(); err != nil {
			continue
		}
		merged, known := branchChangesIncluded(gitCtx, repo, target, "refs/heads/"+branch)
		if known && merged {
			return true, true
		}
		if known {
			checked = true
		}
		// Any other failure (missing branch, corrupt object, timeout) is
		// inconclusive for this target; another lineage may still answer.
	}
	return false, checked
}

// branchChangesIncluded compares only the paths the branch changed since it
// diverged from target. An empty path list means the branch has no unique
// work at all (it is an ancestor of target), which counts as merged.
func branchChangesIncluded(ctx context.Context, repo, target, branch string) (merged, known bool) {
	mergeBaseOutput, err := exec.CommandContext(ctx, "git", "-C", repo,
		"merge-base", target, branch).Output()
	if err != nil {
		return false, false
	}
	mergeBase := strings.TrimSpace(string(mergeBaseOutput))
	if mergeBase == "" {
		return false, false
	}
	pathsOutput, err := exec.CommandContext(ctx, "git", "-C", repo,
		"diff", "--name-only", "-z", "--no-renames", mergeBase, branch).Output()
	if err != nil {
		return false, false
	}
	var paths []string
	for _, path := range strings.Split(strings.TrimRight(string(pathsOutput), "\x00"), "\x00") {
		if path != "" {
			paths = append(paths, path)
		}
	}
	if len(paths) == 0 {
		return true, true
	}
	args := append([]string{"--literal-pathspecs", "-C", repo,
		"diff", "--quiet", branch, target, "--"}, paths...)
	err = exec.CommandContext(ctx, "git", args...).Run()
	if err == nil {
		return true, true
	}
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		return false, true
	}
	return false, false
}
