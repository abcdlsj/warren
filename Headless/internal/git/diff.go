package git

import (
	"context"
	"strings"
)

// Diff returns the unified diff of one path in the working tree. When commit
// is non-empty it diffs that commit against its parent; otherwise staged
// selects the index and unstaged shows the working tree. Untracked files
// have no reference version, so the whole file is shown as new content.
func Diff(ctx context.Context, dir, path string, staged bool, commit string) (string, error) {
	if commit != "" {
		return run(ctx, dir, "show", "--format=", "--no-ext-diff", commit, "--", path)
	}
	if staged {
		return run(ctx, dir, "diff", "--cached", "--no-ext-diff", "--", path)
	}
	output, err := run(ctx, dir, "diff", "--no-ext-diff", "--", path)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(output) != "" || tracked(ctx, dir, path) {
		return output, nil
	}
	return runAllowExit(ctx, dir, "diff", "--no-index", "--no-ext-diff", "--", "/dev/null", path)
}

// tracked reports whether git tracks path in the index.
func tracked(ctx context.Context, dir, path string) bool {
	_, err := run(ctx, dir, "ls-files", "--error-unmatch", "--", path)
	return err == nil
}
