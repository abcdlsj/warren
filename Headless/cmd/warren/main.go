package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/client"
	"github.com/abcdlsj/warren/Headless/internal/config"
)

var version = "dev"
var outputJSON bool
var endpointName string
var endpointURL string
var endpointToken string
var configPath string

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "warren:", err)
		os.Exit(1)
	}
}

func run(arguments []string) error {
	global := flag.NewFlagSet("warren", flag.ContinueOnError)
	global.SetOutput(io.Discard)
	global.BoolVar(&outputJSON, "json", false, "JSON output")
	global.StringVar(&endpointName, "endpoint", env("WARREN_ENDPOINT", ""), "endpoint name")
	global.StringVar(&endpointURL, "server", env("WARREN_SERVER", ""), "server URL")
	global.StringVar(&endpointToken, "token", env("WARREN_TOKEN", ""), "server token")
	global.StringVar(&configPath, "config", config.DefaultPath(), "config path")
	arguments = hoistGlobalFlags(arguments)
	if err := global.Parse(arguments); err != nil {
		return err
	}
	args := global.Args()
	if len(args) == 0 {
		usage()
		return nil
	}
	switch args[0] {
	case "version":
		fmt.Println(version)
		return nil
	case "endpoint", "server":
		return endpointCommand(args[1:])
	case "ssh":
		return sshCommand(args[1:])
	case "project", "workspace", "worktree", "session":
		return resourceCommand(args)
	case "headless":
		return headlessCommand(args[1:])
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		return fmt.Errorf("unknown command %q; run 'warren help'", args[0])
	}
}

var globalFlagNames = map[string]bool{
	"json":     true,
	"endpoint": true,
	"server":   true,
	"token":    true,
	"config":   true,
}

// hoistGlobalFlags moves global flags (--json, --endpoint, --server, --token,
// --config) to the front so they work before or after the subcommand. Go's
// flag package stops parsing at the first positional argument, which would
// otherwise silently ignore flags such as `warren session list --json`.
func hoistGlobalFlags(arguments []string) []string {
	extracted := make([]string, 0, len(arguments))
	rest := make([]string, 0, len(arguments))
	for index := 0; index < len(arguments); index++ {
		item := arguments[index]
		name, _, hasValue := splitFlag(item)
		if !globalFlagNames[name] {
			rest = append(rest, item)
			continue
		}
		if hasValue || name == "json" {
			extracted = append(extracted, item)
			continue
		}
		if index+1 < len(arguments) && !strings.HasPrefix(arguments[index+1], "--") {
			extracted = append(extracted, item, arguments[index+1])
			index++
			continue
		}
		// Missing value: leave it for flag.Parse to report.
		rest = append(rest, item)
	}
	return append(extracted, rest...)
}

func splitFlag(item string) (name, value string, hasValue bool) {
	if !strings.HasPrefix(item, "--") {
		return "", "", false
	}
	trimmed := strings.TrimPrefix(item, "--")
	if split := strings.SplitN(trimmed, "=", 2); len(split) == 2 {
		return split[0], split[1], true
	}
	return trimmed, "", false
}

func connect() (context.Context, *client.Client, error) {
	dialContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	url, token := endpointURL, endpointToken
	if url == "" {
		settings, err := config.Load(configPath)
		if err != nil {
			return nil, nil, err
		}
		value, err := settings.Resolve(endpointName)
		if err != nil {
			return nil, nil, fmt.Errorf("%w; add one with 'warren endpoint add' or pass --server and --token", err)
		}
		url, token = value.URL, value.Token
	}
	if token == "" {
		return nil, nil, errors.New("endpoint token is required")
	}
	value, err := client.Dial(dialContext, url, token)
	return context.Background(), value, err
}

func resourceCommand(args []string) error {
	resource := args[0]
	if resource == "worktree" {
		resource = "workspace"
	}
	if len(args) < 2 {
		return fmt.Errorf("%s command is required", resource)
	}
	action := args[1]
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	if action == "list" {
		state, err := c.Roster(ctx)
		if err != nil {
			return err
		}
		switch resource {
		case "project":
			return printValue(projectRows(state))
		case "workspace":
			return printValue(workspaceRows(state))
		case "session":
			return printValue(sessionRows(state))
		}
	}
	params := parseFlags(args[2:])
	method := ""
	var result any
	switch resource + "." + action {
	case "project.add":
		method = "project.add"
		result = &api.Project{}
	case "project.remove", "project.delete":
		method = "project.remove"
		result = &map[string]any{}
	case "project.rename":
		method = "project.rename"
		result = &map[string]any{}
	case "project.pin":
		method = "project.pin"
	case "project.move":
		method = "project.move"
		result = &map[string]any{}
	case "workspace.create", "workspace.add":
		method = "workspace.create"
		result = &api.Workspace{}
	case "workspace.remove", "workspace.delete":
		method = "workspace.remove"
		result = &map[string]any{}
		// The interactive UI sends an explicit boolean. The CLI keeps the
		// historical behavior unless the caller opts out with --keep-worktree.
		if boolValue(params, "keep_worktree") {
			params["remove_worktree"] = false
		}
		delete(params, "keep_worktree")
	case "workspace.rename":
		method = "workspace.rename"
		result = &map[string]any{}
	case "workspace.pin":
		method = "workspace.pin"
	case "workspace.move":
		method = "workspace.move"
		result = &map[string]any{}
	case "session.create", "session.add":
		method = "session.create"
		result = &api.Session{}
	case "session.remove", "session.delete", "session.kill":
		method = "session.delete"
		result = &map[string]any{}
	case "session.rename":
		method = "session.rename"
		result = &map[string]any{}
	case "session.pin":
		method = "session.pin"
		result = &map[string]any{}
	case "session.send":
		id := positional(params, 0, "session id")
		text := strings.Join(positionals(params)[1:], " ")
		if text == "" {
			data, _ := io.ReadAll(os.Stdin)
			text = string(data)
		}
		if _, err := c.Attach(ctx, id); err != nil {
			return err
		}
		if !strings.HasSuffix(text, "\n") && !boolValue(params, "raw") {
			text += "\r"
		}
		if err := c.Input(ctx, []byte(text)); err != nil {
			return err
		}
		fmt.Println("sent")
		return nil
	case "session.read", "session.attach":
		return sessionRead(ctx, c, params, action == "attach")
	default:
		return fmt.Errorf("unsupported command: %s %s", resource, action)
	}
	request := normalizedParams(params, resource, action)
	if err := c.Request(ctx, method, request, result); err != nil {
		return err
	}
	return printValue(result)
}

func sessionRead(ctx context.Context, c *client.Client, params map[string]any, follow bool) error {
	id := positional(params, 0, "session id")
	if _, err := c.Attach(ctx, id); err != nil {
		return err
	}
	timeout := durationValue(params, "timeout", 8*time.Second)
	needle := stringValue(params, "contains")
	if follow {
		ctx, _ = signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	} else {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.Background(), timeout)
		defer cancel()
	}
	err := c.ReadOutput(ctx, func(data []byte) bool {
		_, _ = os.Stdout.Write(data)
		return !follow && needle != "" && strings.Contains(string(data), needle)
	})
	if errors.Is(err, context.Canceled) && follow {
		return nil
	}
	if errors.Is(err, context.DeadlineExceeded) {
		if needle == "" {
			return nil
		}
		return fmt.Errorf("expected text not found before timeout: %s", needle)
	}
	return err
}

func endpointCommand(args []string) error {
	settings, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if len(args) == 0 || args[0] == "list" {
		for index, name := range settings.Names() {
			value := settings.Endpoints[name]
			marker := " "
			if name == settings.Current {
				marker = "*"
			}
			if outputJSON {
				continue
			}
			if index == 0 {
				fmt.Printf("%s %-16s %s\t%s\n", " ", "NAME", "URL", "SSH")
			}
			fmt.Printf("%s %-16s %s\t%s\n", marker, name, value.URL, displayValue(value.SSH))
		}
		if outputJSON {
			return printValue(settings)
		}
		return nil
	}
	switch args[0] {
	case "add":
		flags := parseFlags(args[1:])
		name := positional(flags, 0, "endpoint name")
		url := stringValue(flags, "url")
		token := stringValue(flags, "token")
		if url == "" || token == "" {
			return errors.New("--url and --token are required")
		}
		settings.Endpoints[name] = config.Endpoint{Name: name, URL: url, Token: token, SSH: stringValue(flags, "ssh")}
		if settings.Current == "" || boolValue(flags, "use") {
			settings.Current = name
		}
		return config.Save(configPath, settings)
	case "use":
		if len(args) < 2 {
			return errors.New("endpoint name is required")
		}
		if _, ok := settings.Endpoints[args[1]]; !ok {
			return fmt.Errorf("endpoint not found: %s", args[1])
		}
		settings.Current = args[1]
		return config.Save(configPath, settings)
	case "remove":
		if len(args) < 2 {
			return errors.New("endpoint name is required")
		}
		delete(settings.Endpoints, args[1])
		if settings.Current == args[1] {
			settings.Current = ""
		}
		return config.Save(configPath, settings)
	case "current":
		value, err := settings.Resolve("")
		if err != nil {
			return err
		}
		return printValue(value)
	default:
		return fmt.Errorf("unknown endpoint command: %s", args[0])
	}
}

func sshCommand(args []string) error {
	flags := parseFlags(args)
	target := positional(flags, 0, "SSH target")
	localPort := stringValueDefault(flags, "local-port", "8789")
	remotePort := stringValueDefault(flags, "remote-port", "8789")
	name := stringValueDefault(flags, "name", strings.NewReplacer("@", "-", ":", "-").Replace(target))
	remoteStart := "command -v warren-headless >/dev/null || { echo 'warren-headless is not installed' >&2; exit 127; }; mkdir -p ~/.warren; test -s ~/.warren/token || (umask 077; openssl rand -base64 32 | tr -d '\\n' > ~/.warren/token); (curl -fsS http://127.0.0.1:" + remotePort + "/healthz >/dev/null 2>&1 || nohup warren-headless --listen 127.0.0.1:" + remotePort + " > ~/.warren/headless.log 2>&1 &); cat ~/.warren/token"
	output, err := exec.Command("ssh", target, remoteStart).CombinedOutput()
	if err != nil {
		return fmt.Errorf("start remote headless: %s: %w", strings.TrimSpace(string(output)), err)
	}
	token := strings.TrimSpace(string(output))
	if token == "" {
		return errors.New("remote headless returned an empty token")
	}
	settings, err := config.Load(configPath)
	if err != nil {
		return err
	}
	settings.Endpoints[name] = config.Endpoint{Name: name, URL: "http://127.0.0.1:" + localPort, Token: token, SSH: target}
	settings.Current = name
	if err := config.Save(configPath, settings); err != nil {
		return err
	}
	command := exec.Command("ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-L", localPort+":127.0.0.1:"+remotePort, target)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	fmt.Fprintf(os.Stderr, "Warren endpoint %q active at http://127.0.0.1:%s; keep this process running.\n", name, localPort)
	return command.Run()
}

func headlessCommand(args []string) error {
	binary, err := exec.LookPath("warren-headless")
	if err != nil {
		return errors.New("warren-headless is not installed")
	}
	command := exec.Command(binary, args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

func parseFlags(args []string) map[string]any {
	value := map[string]any{"_": []string{}}
	for index := 0; index < len(args); index++ {
		item := args[index]
		if !strings.HasPrefix(item, "--") {
			value["_"] = append(value["_"].([]string), item)
			continue
		}
		key := strings.TrimPrefix(item, "--")
		if split := strings.SplitN(key, "=", 2); len(split) == 2 {
			value[split[0]] = split[1]
			continue
		}
		if index+1 < len(args) && !strings.HasPrefix(args[index+1], "--") {
			value[key] = args[index+1]
			index++
		} else {
			value[key] = true
		}
	}
	return value
}
func normalizedParams(values map[string]any, resource, action string) map[string]any {
	result := map[string]any{}
	for key, value := range values {
		if key != "_" {
			result[key] = value
		}
	}
	positions := positionals(values)
	if len(positions) > 0 {
		if action == "add" && resource == "project" {
			result["path"] = positions[0]
		} else if action == "create" && resource == "workspace" {
			result["project"] = positions[0]
		} else if action == "create" && resource == "session" {
			result["workspace"] = positions[0]
		} else {
			result["id"] = positions[0]
		}
	}
	return result
}
func positionals(value map[string]any) []string { result, _ := value["_"].([]string); return result }
func positional(value map[string]any, index int, label string) string {
	items := positionals(value)
	if len(items) <= index {
		panicUsage(label + " is required")
	}
	return items[index]
}
func panicUsage(message string) string {
	fmt.Fprintln(os.Stderr, "warren:", message)
	os.Exit(2)
	return ""
}
func stringValue(value map[string]any, key string) string {
	result, _ := value[key].(string)
	return result
}
func stringValueDefault(value map[string]any, key, fallback string) string {
	if result := stringValue(value, key); result != "" {
		return result
	}
	return fallback
}
func boolValue(value map[string]any, key string) bool {
	switch result := value[key].(type) {
	case bool:
		return result
	case string:
		parsed, err := strconv.ParseBool(result)
		return err == nil && parsed
	default:
		return false
	}
}
func durationValue(value map[string]any, key string, fallback time.Duration) time.Duration {
	result, err := time.ParseDuration(stringValue(value, key))
	if err == nil {
		return result
	}
	if seconds, err := strconv.Atoi(stringValue(value, key)); err == nil {
		return time.Duration(seconds) * time.Second
	}
	return fallback
}

// SessionRow joins a session with its workspace and project so the CLI can
// display context the roster already carries. The embedded Session keeps the
// JSON payload backward compatible while adding the resolved names/paths.
type SessionRow struct {
	api.Session
	ProjectID     string `json:"projectId,omitempty"`
	ProjectName   string `json:"projectName,omitempty"`
	WorkspaceName string `json:"workspaceName,omitempty"`
	Branch        string `json:"branch,omitempty"`
	Path          string `json:"path,omitempty"`
}

func sessionRows(state api.State) []SessionRow {
	workspaces := make(map[string]api.Workspace, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		workspaces[workspace.ID] = workspace
	}
	projects := make(map[string]api.Project, len(state.Projects))
	for _, project := range state.Projects {
		projects[project.ID] = project
	}
	rows := make([]SessionRow, 0, len(state.Sessions))
	for _, session := range state.Sessions {
		row := SessionRow{Session: session}
		if workspace, ok := workspaces[session.WorkspaceID]; ok {
			row.WorkspaceName = workspace.Name
			row.Branch = workspace.Branch
			row.Path = workspace.Path
			if project, ok := projects[workspace.ProjectID]; ok {
				row.ProjectID = project.ID
				row.ProjectName = project.Name
			}
		}
		rows = append(rows, row)
	}
	return rows
}

// ProjectRow adds roster-derived context (workspace count) to a project while
// keeping the original JSON fields intact.
type ProjectRow struct {
	api.Project
	Workspaces int `json:"workspaces,omitempty"`
}

func projectRows(state api.State) []ProjectRow {
	byProject := make(map[string]int)
	for _, workspace := range state.Workspaces {
		byProject[workspace.ProjectID]++
	}
	rows := make([]ProjectRow, 0, len(state.Projects))
	for _, project := range state.Projects {
		rows = append(rows, ProjectRow{Project: project, Workspaces: byProject[project.ID]})
	}
	return rows
}

// WorkspaceRow joins a workspace with its project and adds a running session
// count while keeping the original JSON fields intact.
type WorkspaceRow struct {
	api.Workspace
	ProjectName string `json:"projectName,omitempty"`
	Sessions    int    `json:"sessions,omitempty"`
}

func workspaceRows(state api.State) []WorkspaceRow {
	projects := make(map[string]api.Project, len(state.Projects))
	for _, project := range state.Projects {
		projects[project.ID] = project
	}
	runningByWorkspace := make(map[string]int)
	for _, session := range state.Sessions {
		if session.Lifecycle == "running" {
			runningByWorkspace[session.WorkspaceID]++
		}
	}
	rows := make([]WorkspaceRow, 0, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		row := WorkspaceRow{Workspace: workspace, Sessions: runningByWorkspace[workspace.ID]}
		if project, ok := projects[workspace.ProjectID]; ok {
			row.ProjectName = project.Name
		}
		rows = append(rows, row)
	}
	return rows
}

func printValue(value any) error {
	if outputJSON {
		data, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}
	switch items := value.(type) {
	case []ProjectRow:
		fmt.Println("ID\tNAME\tPATH\tWORKSPACES\tPINNED\tCREATED")
		for _, item := range items {
			fmt.Printf("%s\t%s\t%s\t%d\t%s\t%s\n",
				item.ID,
				item.Name,
				item.Path,
				item.Workspaces,
				displayBool(item.Pinned),
				formatTime(item.CreatedAt),
			)
		}
	case []WorkspaceRow:
		fmt.Println("ID\tPROJECT\tNAME\tBRANCH\tPATH\tKIND\tSESSIONS\tPINNED\tCREATED")
		for _, item := range items {
			fmt.Printf("%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n",
				item.ID,
				displayValue(item.ProjectName),
				item.Name,
				displayValue(item.Branch),
				item.Path,
				item.Kind,
				item.Sessions,
				displayBool(item.Pinned),
				formatTime(item.CreatedAt),
			)
		}
	case []SessionRow:
		fmt.Println("ID\tPROJECT\tWORKSPACE\tBRANCH\tTITLE\tKIND\tCOMMAND\tLIFECYCLE\tPINNED\tCREATED")
		for _, item := range items {
			fmt.Printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
				item.ID,
				displayValue(item.ProjectName),
				displayValue(item.WorkspaceName),
				displayValue(item.Branch),
				item.Title,
				item.Kind,
				displayValue(item.Command),
				item.Lifecycle,
				displayBool(item.Pinned),
				formatTime(item.CreatedAt),
			)
		}
	default:
		data, _ := json.MarshalIndent(value, "", "  ")
		fmt.Println(string(data))
	}
	return nil
}

func displayValue(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func displayBool(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func formatTime(value time.Time) string {
	if value.IsZero() {
		return "-"
	}
	return value.Local().Format("2006-01-02 15:04")
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func usage() {
	fmt.Print(`Warren CLI

Usage:
  warren [--endpoint NAME | --server URL --token TOKEN] <command>

Commands:
  endpoint list|add|use|remove|current
  project list|add|remove|rename|pin|move
  workspace list|create|remove|rename|pin|move  (worktree is an alias)
  session list|create|delete|rename|pin|send|read|attach
  ssh USER@HOST                     start daemon, save endpoint, keep SSH tunnel
  headless [FLAGS]                  run the installed daemon

Examples:
  warren endpoint add vps --url http://127.0.0.1:8789 --token TOKEN --use
  warren project add /srv/my-repo
  warren project move PROJECT_ID --before OTHER_PROJECT_ID
  warren workspace create PROJECT_ID --branch release/feature
    --path is optional; omit it to create under ~/.warren/worktrees/
    (pass --path only when the worktree must live somewhere specific)
  warren workspace remove WORKSPACE_ID --force
    --keep-worktree keeps the local Git worktree on disk
  warren workspace move WORKSPACE_ID --before OTHER_WORKSPACE_ID
  warren session create WORKSPACE_ID --kind codex --command codex
  warren session attach SESSION_ID
`)
}
