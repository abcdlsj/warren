package git

import "context"

// Checkout switches the workspace to branch, creating it first when create
// is true. Remote-only names rely on git switch DWIM to track them.
func Checkout(ctx context.Context, dir, branch string, create bool) error {
	args := []string{"switch"}
	if create {
		args = append(args, "-c", branch)
	} else {
		args = append(args, branch)
	}
	_, err := run(ctx, dir, args...)
	return err
}

// Pull updates the workspace with a conservative fast-forward-only merge.
func Pull(ctx context.Context, dir string) (string, error) {
	return run(ctx, dir, "pull", "--ff-only")
}

// Push uploads the current branch, setting the upstream when the branch has
// none yet.
func Push(ctx context.Context, dir string) (string, error) {
	status, err := StatusFor(ctx, dir)
	if err != nil {
		return "", err
	}
	if status.Upstream == "" {
		return run(ctx, dir, "push", "-u", "origin", "HEAD")
	}
	return run(ctx, dir, "push")
}
