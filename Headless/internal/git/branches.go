package git

import (
	"context"
	"strings"
)

// BranchList separates local and remote branch names for one workspace.
type BranchList struct {
	Local  []string
	Remote []string
}

func Branches(ctx context.Context, dir string) (BranchList, error) {
	local, err := run(ctx, dir, "for-each-ref", "--format=%(refname:short)", "refs/heads")
	if err != nil {
		return BranchList{}, err
	}
	remote, err := run(ctx, dir, "for-each-ref", "--format=%(refname:short)", "refs/remotes")
	if err != nil {
		return BranchList{}, err
	}
	return parseBranches(local, remote), nil
}

func parseBranches(local, remote string) BranchList {
	return BranchList{
		Local:  branchNames(local),
		Remote: branchNames(remote),
	}
}

func branchNames(output string) []string {
	var names []string
	for _, line := range strings.Split(output, "\n") {
		name := strings.TrimSpace(line)
		if name == "" || strings.HasSuffix(name, "/HEAD") {
			continue
		}
		names = append(names, name)
	}
	return names
}

func RemoteURL(ctx context.Context, dir string) (string, error) {
	output, err := run(ctx, dir, "remote", "get-url", "origin")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(output), nil
}
