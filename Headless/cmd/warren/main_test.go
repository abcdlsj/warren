package main

import (
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
