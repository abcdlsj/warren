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

func StatusFor(ctx context.Context, dir string) (Status, error) {
	output, err := run(ctx, dir, "-c", "core.quotepath=false", "status", "--porcelain=v2", "-z", "--branch")
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
		tokens := strings.Fields(chunk)
		if len(tokens) == 0 {
			continue
		}
		switch tokens[0] {
		case "1":
			path := strings.Join(tokens[8:], " ")
			addXY(&status, tokens[1], path, "")
		case "2":
			path := strings.Join(tokens[9:], " ")
			renameFrom := ""
			if i+1 < len(chunks) {
				renameFrom = chunks[i+1]
				i++
			}
			addXY(&status, tokens[1], path, renameFrom)
		case "?":
			status.Changes = append(status.Changes, Change{Path: strings.Join(tokens[1:], " "), Status: "?"})
		case "u":
			status.Changes = append(status.Changes, Change{Path: strings.Join(tokens[9:], " "), Status: strings.ToUpper(tokens[1])})
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
		status.Ahead = abCount(fields[1])
		status.Behind = abCount(fields[2])
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
