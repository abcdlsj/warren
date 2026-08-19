package git

import (
	"context"
	"strconv"
	"strings"
	"time"
)

// FileChange is one file touched by a commit, as reported by --name-status.
type FileChange struct {
	Path       string
	Status     string
	RenameFrom string
}

// Commit is one entry of a workspace's commit history.
type Commit struct {
	Hash    string
	Short   string
	Subject string
	Author  string
	Email   string
	Time    time.Time
	Files   []FileChange
}

func Log(ctx context.Context, dir string, limit int) ([]Commit, error) {
	output, err := run(ctx, dir, "-c", "core.quotepath=false", "log",
		"--name-status", "--format=COMMIT%x00%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00",
		"-n", strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	return parseLog(output), nil
}

// parseLog reads git log --name-status output. Each commit is a
// "COMMIT\x00" marker followed by NUL-separated fields, a blank line, and
// the name-status lines for that commit.
func parseLog(output string) []Commit {
	var commits []Commit
	for _, chunk := range strings.Split(output, "COMMIT\x00") {
		if chunk == "" {
			continue
		}
		fields := strings.SplitN(chunk, "\x00", 7)
		if len(fields) < 6 {
			continue
		}
		commit := Commit{
			Hash:    fields[0],
			Short:   fields[1],
			Subject: fields[2],
			Author:  fields[3],
			Email:   fields[4],
		}
		if parsed, err := time.Parse(time.RFC3339, fields[5]); err == nil {
			commit.Time = parsed
		}
		if len(fields) > 6 {
			commit.Files = parseNameStatus(fields[6])
		}
		commits = append(commits, commit)
	}
	return commits
}

func parseNameStatus(block string) []FileChange {
	var files []FileChange
	for _, line := range strings.Split(block, "\n") {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 2 || parts[0] == "" {
			continue
		}
		change := FileChange{Status: parts[0][:1], Path: parts[1]}
		if len(parts) > 2 {
			change.Path = parts[2]
			change.RenameFrom = parts[1]
		}
		files = append(files, change)
	}
	return files
}
