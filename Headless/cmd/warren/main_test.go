package main

import (
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/config"
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

	rows := sessionRows(state, false, false)
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

	rows := sessionRows(state, false, false)
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

func TestSessionRowsHideEndedByDefault(t *testing.T) {
	now := time.Now().UTC()
	endedAt := now.Add(-time.Hour)
	state := api.State{
		Sessions: []api.Session{
			{ID: "session-running", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-ended", WorkspaceID: "workspace-1", Lifecycle: "ended", EndedAt: &endedAt, CreatedAt: now},
		},
	}

	rows := sessionRows(state, false, false)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1 (default hides ended)", len(rows))
	}
	if rows[0].ID != "session-running" {
		t.Errorf("row id = %q, want session-running", rows[0].ID)
	}
}

func TestSessionRowsAllIncludesEnded(t *testing.T) {
	now := time.Now().UTC()
	endedAt := now.Add(-time.Hour)
	state := api.State{
		Sessions: []api.Session{
			{ID: "session-running", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-ended", WorkspaceID: "workspace-1", Lifecycle: "ended", EndedAt: &endedAt, CreatedAt: now},
		},
	}

	rows := sessionRows(state, true, false)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (--all includes ended)", len(rows))
	}
}

func TestSessionRowsEndedOnly(t *testing.T) {
	now := time.Now().UTC()
	endedAt := now.Add(-time.Hour)
	state := api.State{
		Sessions: []api.Session{
			{ID: "session-running", WorkspaceID: "workspace-1", Lifecycle: "running", CreatedAt: now},
			{ID: "session-ended", WorkspaceID: "workspace-1", Lifecycle: "ended", EndedAt: &endedAt, CreatedAt: now},
		},
	}

	rows := sessionRows(state, false, true)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1 (--ended lists only ended)", len(rows))
	}
	if rows[0].ID != "session-ended" {
		t.Errorf("row id = %q, want session-ended", rows[0].ID)
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

func TestHoistGlobalFlagsLeavesTokenForEndpointAdd(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want []string
	}{
		{
			name: "endpoint add token stays local",
			args: []string{"endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret"},
			want: []string{"endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret"},
		},
		{
			name: "server alias also keeps token",
			args: []string{"server", "add", "spike", "--token=secret", "--url", "http://127.0.0.1:8789"},
			want: []string{"server", "add", "spike", "--token=secret", "--url", "http://127.0.0.1:8789"},
		},
		{
			name: "json still hoists for endpoint add",
			args: []string{"endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret", "--json"},
			want: []string{"--json", "endpoint", "add", "spike", "--url", "http://127.0.0.1:8789", "--token", "secret"},
		},
		{
			name: "config still hoists for endpoint add",
			args: []string{"--config", "/tmp/cfg.json", "endpoint", "add", "spike", "--token", "secret"},
			want: []string{"--config", "/tmp/cfg.json", "endpoint", "add", "spike", "--token", "secret"},
		},
		{
			name: "other commands still hoist token",
			args: []string{"session", "list", "--token", "secret"},
			want: []string{"--token", "secret", "session", "list"},
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

func TestEndpointAddKeepsTokenFlag(t *testing.T) {
	configPath = filepath.Join(t.TempDir(), "config.json")
	t.Cleanup(func() { configPath = config.DefaultPath() })

	if err := run([]string{
		"--config", configPath,
		"endpoint", "add", "spike",
		"--url", "http://127.0.0.1:8789",
		"--token", "secret",
	}); err != nil {
		t.Fatal(err)
	}
	settings, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, ok := settings.Endpoints["spike"]
	if !ok {
		t.Fatalf("endpoint spike not saved: %#v", settings.Endpoints)
	}
	if endpoint.Token != "secret" {
		t.Errorf("token = %q, want secret", endpoint.Token)
	}
}

func TestRunHelpExitsSuccessfully(t *testing.T) {
	for _, arguments := range [][]string{
		{"help"},
		{"-h"},
		{"--help"},
		{"workspace", "--help"},
		{"workspace", "-h"},
		{"worktree", "--help"},
		{"worktree", "-h"},
		{"project", "--help"},
		{"session", "--help"},
	} {
		if err := run(arguments); err != nil {
			t.Errorf("run(%v) = %v, want nil", arguments, err)
		}
	}
}

func TestRunResourceHelpDoesNotConnect(t *testing.T) {
	// These commands must not reach connect(); validation and help happen
	// before any server dial, so they succeed even without an endpoint.
	for _, arguments := range [][]string{
		{"workspace", "create", "--help"},
		{"worktree", "create", "--help"},
		{"session", "attach", "--help"},
	} {
		if err := run(arguments); err != nil {
			t.Errorf("run(%v) = %v, want nil", arguments, err)
		}
	}
}

func TestRunMissingArgumentsReturnUsageError(t *testing.T) {
	tests := []struct {
		arguments []string
		message   string
		usage     string
	}{
		{[]string{"workspace", "create"}, "missing PROJECT_ID", "warren workspace create PROJECT_ID"},
		{[]string{"worktree", "create"}, "missing PROJECT_ID", "warren worktree create PROJECT_ID"},
		{[]string{"worktree", "create", "PROJECT_ID"}, "missing --branch BRANCH", "warren worktree create PROJECT_ID"},
		{[]string{"workspace"}, "workspace command is required", "warren workspace list"},
		{[]string{"session", "send"}, "missing SESSION_ID", "warren session send SESSION_ID"},
		{[]string{"endpoint", "add"}, "missing ENDPOINT_NAME", "warren endpoint add NAME"},
		{[]string{"ssh"}, "missing SSH_TARGET", "warren ssh USER@HOST"},
	}
	for _, test := range tests {
		err := run(test.arguments)
		var usageErr *usageError
		if !errors.As(err, &usageErr) {
			t.Errorf("run(%v) error = %v, want *usageError", test.arguments, err)
			continue
		}
		if usageErr.message != test.message {
			t.Errorf("run(%v) message = %q, want %q", test.arguments, usageErr.message, test.message)
		}
		if !contains(usageErr.text, test.usage) {
			t.Errorf("run(%v) usage = %q, want it to contain %q", test.arguments, usageErr.text, test.usage)
		}
	}
}

func TestRunUnsupportedActionUsesAliasInError(t *testing.T) {
	err := run([]string{"worktree", "bogus"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "unsupported command: worktree bogus" {
		t.Errorf("message = %q, want %q", usageErr.message, "unsupported command: worktree bogus")
	}
	if !contains(usageErr.text, "warren worktree list") {
		t.Errorf("usage should use the typed alias, got %q", usageErr.text)
	}
}

func TestRunSessionListAllEndedMutuallyExclusive(t *testing.T) {
	err := run([]string{"session", "list", "--all", "--ended"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "--all and --ended are mutually exclusive" {
		t.Errorf("message = %q", usageErr.message)
	}
	if !contains(usageErr.text, "warren session list [--all | --ended]") {
		t.Errorf("usage should mention --all/--ended, got %q", usageErr.text)
	}
}

func TestRunUnknownCommandReturnsUsageError(t *testing.T) {
	err := run([]string{"nope"})
	var usageErr *usageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("error = %v, want *usageError", err)
	}
	if usageErr.message != "unknown command \"nope\"; run 'warren help'" {
		t.Errorf("message = %q", usageErr.message)
	}
}

func contains(text, substring string) bool {
	return strings.Contains(text, substring)
}
