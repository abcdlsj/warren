package main

import (
	"reflect"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestSessionRowsJoinsWorkspaceAndProject(t *testing.T) {
	now := time.Now().UTC()
	state := api.State{
		Projects: []api.Project{{
			ID:   "project-1",
			Name: "warren",
			Path: "/srv/warren",
		}},
		Workspaces: []api.Workspace{{
			ID:        "workspace-1",
			ProjectID: "project-1",
			Name:      "release/feature",
			Path:      "/srv/warren/.worktrees/feature",
			Branch:    "release/feature",
		}},
		Sessions: []api.Session{{
			ID:          "session-1",
			WorkspaceID: "workspace-1",
			Title:       "Codex",
			Kind:        "codex",
			Command:     "codex",
			Lifecycle:   "running",
			CreatedAt:   now,
		}},
	}

	rows := sessionRows(state)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.ProjectID != "project-1" || row.ProjectName != "warren" {
		t.Errorf("project = %q/%q, want project-1/warren", row.ProjectID, row.ProjectName)
	}
	if row.WorkspaceName != "release/feature" {
		t.Errorf("workspace name = %q, want release/feature", row.WorkspaceName)
	}
	if row.Branch != "release/feature" || row.Path != "/srv/warren/.worktrees/feature" {
		t.Errorf("branch/path = %q/%q, want release/feature//srv/warren/.worktrees/feature", row.Branch, row.Path)
	}
	if row.Session.ID != "session-1" || row.Title != "Codex" {
		t.Errorf("embedded session lost: %+v", row.Session)
	}
}

func TestSessionRowsKeepsOrphanSessionUsable(t *testing.T) {
	state := api.State{
		Sessions: []api.Session{{
			ID:          "session-1",
			WorkspaceID: "missing-workspace",
			Title:       "Shell",
			Kind:        "shell",
			Lifecycle:   "running",
		}},
	}

	rows := sessionRows(state)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.ProjectName != "" || row.WorkspaceName != "" || row.Branch != "" {
		t.Errorf("orphan row should stay empty, got %+v", row)
	}
	if row.Session.ID != "session-1" {
		t.Errorf("session id = %q, want session-1", row.Session.ID)
	}
}

func TestProjectRowsCountWorkspaces(t *testing.T) {
	state := api.State{
		Projects: []api.Project{
			{ID: "project-1", Name: "warren", Path: "/srv/warren"},
			{ID: "project-2", Name: "empty", Path: "/srv/empty"},
		},
		Workspaces: []api.Workspace{
			{ID: "workspace-1", ProjectID: "project-1"},
			{ID: "workspace-2", ProjectID: "project-1"},
		},
	}

	rows := projectRows(state)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	if rows[0].ID != "project-1" || rows[0].Workspaces != 2 {
		t.Errorf("project-1 rows = %d, want 2 (id %q)", rows[0].Workspaces, rows[0].ID)
	}
	if rows[1].ID != "project-2" || rows[1].Workspaces != 0 {
		t.Errorf("project-2 rows = %d, want 0 (id %q)", rows[1].Workspaces, rows[1].ID)
	}
}

func TestWorkspaceRowsJoinProjectAndCountRunningSessions(t *testing.T) {
	now := time.Now().UTC()
	state := api.State{
		Projects: []api.Project{{
			ID:   "project-1",
			Name: "warren",
			Path: "/srv/warren",
		}},
		Workspaces: []api.Workspace{{
			ID:        "workspace-1",
			ProjectID: "project-1",
			Name:      "release/feature",
			Path:      "/srv/warren/.worktrees/feature",
			Branch:    "release/feature",
			Kind:      "worktree",
			CreatedAt: now,
		}},
		Sessions: []api.Session{
			{ID: "session-1", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-2", WorkspaceID: "workspace-1", Lifecycle: "exited", CreatedAt: now},
			{ID: "session-3", WorkspaceID: "missing", Lifecycle: "running", CreatedAt: now},
		},
	}

	rows := workspaceRows(state)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.ProjectName != "warren" {
		t.Errorf("project name = %q, want warren", row.ProjectName)
	}
	if row.Sessions != 1 {
		t.Errorf("running sessions = %d, want 1", row.Sessions)
	}
	if row.Workspace.ID != "workspace-1" || row.Kind != "worktree" {
		t.Errorf("embedded workspace lost: %+v", row.Workspace)
	}
}

func TestHoistGlobalFlagsMovesFlagsFromAnyPosition(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want []string
	}{
		{
			name: "json after subcommand",
			args: []string{"session", "list", "--json"},
			want: []string{"--json", "session", "list"},
		},
		{
			name: "json before subcommand",
			args: []string{"--json", "session", "list"},
			want: []string{"--json", "session", "list"},
		},
		{
			name: "value flag mixed with json",
			args: []string{"session", "list", "--endpoint", "vps", "--json"},
			want: []string{"--endpoint", "vps", "--json", "session", "list"},
		},
		{
			name: "equals form is preserved",
			args: []string{"session", "list", "--config=/tmp/cfg.json", "--json=false"},
			want: []string{"--config=/tmp/cfg.json", "--json=false", "session", "list"},
		},
		{
			name: "headless flags are untouched",
			args: []string{"headless", "--name", "host-a"},
			want: []string{"headless", "--name", "host-a"},
		},
		{
			name: "missing value stays for flag parser",
			args: []string{"session", "list", "--token"},
			want: []string{"session", "list", "--token"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := hoistGlobalFlags(test.args); !reflect.DeepEqual(got, test.want) {
				t.Errorf("hoistGlobalFlags(%v) = %v, want %v", test.args, got, test.want)
			}
		})
	}
}
