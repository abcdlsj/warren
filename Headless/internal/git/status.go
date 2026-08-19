package git

import (
	"context"
	"strconv"
	"strings"
)

// Change is one working-tree change of a workspace.
type Change struct {
	Path       string
	Status     string
	Staged     bool
	RenameFrom string
}

// Status summarizes one workspace working tree.
type Status struct {
	Branch   string
	Upstream string
	Ahead    int
	Behind   int
	Stash    int
	Changes  []Change
}

// StatusFor reports the working-tree status of the git repository at dir.
func StatusFor(ctx context.Context, dir string) (Status, error) {
	output, err := run(ctx, dir, "-c", "core.quotepath=false", "status", "--porcelain=v2", "-z", "--branch", "--show-stash")
	if err != nil {
		return Status{}, err
	}
	return parseStatus(output), nil
}

// parseStatus reads porcelain v2 output. With -z the entire stream is
// NUL-delimited: header lines start with "# " and rename records are two
// chunks (new path then old path).
func parseStatus(output string) Status {
	var status Status
	chunks := strings.Split(output, "\x00")
	for i := 0; i < len(chunks); i++ {
		chunk := chunks[i]
		if chunk == "" {
			continue
		}
		if strings.HasPrefix(chunk, "# ") {
			parseStatusHeader(&status, strings.TrimPrefix(chunk, "# "))
			continue
		}
		switch chunk[0] {
		case '1':
			parts := strings.SplitN(chunk, " ", 9)
			if len(parts) < 9 {
				continue
			}
			addXY(&status, parts[1], parts[8], "")
		case '2':
			parts := strings.SplitN(chunk, " ", 10)
			if len(parts) < 10 {
				continue
			}
			renameFrom := ""
			if i+1 < len(chunks) {
				renameFrom = chunks[i+1]
				i++
			}
			addXY(&status, parts[1], parts[9], renameFrom)
		case '?':
			parts := strings.SplitN(chunk, " ", 2)
			if len(parts) < 2 {
				continue
			}
			status.Changes = append(status.Changes, Change{Path: parts[1], Status: "?"})
		case 'u':
			parts := strings.SplitN(chunk, " ", 11)
			if len(parts) < 11 {
				continue
			}
			status.Changes = append(status.Changes, Change{Path: parts[10], Status: parts[1]})
		}
	}
	return status
}

func parseStatusHeader(status *Status, line string) {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return
	}
	switch fields[0] {
	case "branch.head":
		if fields[1] != "(detached)" {
			status.Branch = fields[1]
		}
	case "branch.upstream":
		status.Upstream = fields[1]
	case "branch.ab":
		if len(fields) >= 3 {
			status.Ahead = abCount(fields[1])
			status.Behind = abCount(fields[2])
		}
	case "stash":
		status.Stash, _ = strconv.Atoi(fields[1])
	}
}

func abCount(value string) int {
	value = strings.TrimPrefix(value, "+")
	value = strings.TrimPrefix(value, "-")
	count, _ := strconv.Atoi(value)
	return count
}

// addXY appends one Change per non-dot XY position; a file with both staged
// and unstaged changes intentionally yields two entries for the same path.
func addXY(status *Status, xy, path, renameFrom string) {
	if len(xy) != 2 {
		return
	}
	if staged := xy[0]; staged != '.' {
		status.Changes = append(status.Changes, Change{Path: path, Status: string(staged), Staged: true, RenameFrom: renameFrom})
	}
	if unstaged := xy[1]; unstaged != '.' {
		status.Changes = append(status.Changes, Change{Path: path, Status: string(unstaged), Staged: false, RenameFrom: renameFrom})
	}
}
