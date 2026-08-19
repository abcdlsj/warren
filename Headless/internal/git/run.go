package git

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const commandTimeout = 60 * time.Second

// Error carries the trimmed command output so the UI can show why an
// operation failed instead of a bare exit status.
type Error struct {
	Output string
	Err    error
}

func (e *Error) Error() string {
	if message := strings.TrimSpace(e.Output); message != "" {
		return message
	}
	return e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }

func run(ctx context.Context, dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return "", fmt.Errorf("git %s timed out: %w", strings.Join(args, " "), ctx.Err())
		}
		return "", &Error{Output: string(output), Err: err}
	}
	return string(output), nil
}
