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
	"sort"
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
		var usageErr *usageError
		if errors.As(err, &usageErr) {
			fmt.Fprintln(os.Stderr, "warren:", usageErr.message)
			if usageErr.text != "" {
				fmt.Fprintln(os.Stderr)
				fmt.Fprint(os.Stderr, usageErr.text)
			}
			os.Exit(2)
		}
		fmt.Fprintln(os.Stderr, "warren:", err)
		os.Exit(1)
	}
}

type usageError struct {
	message string
	text    string
}

func (e *usageError) Error() string { return e.message }

func newUsageError(message, text string) error {
	return &usageError{message: message, text: text}
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
		if errors.Is(err, flag.ErrHelp) {
			usage()
			return nil
		}
		return newUsageError(err.Error(), usageText())
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
		return newUsageError(fmt.Sprintf("unknown command %q; run 'warren help'", args[0]), usageText())
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
	endpointAdd := isEndpointAdd(arguments)
	for index := 0; index < len(arguments); index++ {
		item := arguments[index]
		name, _, hasValue := splitFlag(item)
		if !globalFlagNames[name] {
			rest = append(rest, item)
			continue
		}
		// endpoint add accepts its own --token; keep it local so the
		// subcommand receives it instead of treating it as the server token.
		if endpointAdd && name == "token" {
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

// isEndpointAdd reports whether the arguments target `endpoint add` (or its
// `server add` alias), where --token is a subcommand flag rather than a global
// server token.
func isEndpointAdd(arguments []string) bool {
	position := 0
	for index := 0; index < len(arguments); index++ {
		item := arguments[index]
		name, _, hasValue := splitFlag(item)
		if globalFlagNames[name] {
			if hasValue || name == "json" {
				continue
			}
			if index+1 < len(arguments) && !strings.HasPrefix(arguments[index+1], "--") {
				index++
			}
			continue
		}
		position++
		switch position {
		case 1:
			if item != "endpoint" && item != "server" {
				return false
			}
		case 2:
			return item == "add"
		default:
			return false
		}
	}
	return false
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

func canonicalResource(name string) string {
	if name == "worktree" {
		return "workspace"
	}
	return name
}

func isHelpArgument(argument string) bool {
	return argument == "-h" || argument == "--help"
}

var resourceActions = map[string]map[string]bool{
	"project": {
		"list": true, "add": true, "remove": true, "delete": true,
		"rename": true, "pin": true, "move": true,
	},
	"workspace": {
		"list": true, "create": true, "add": true, "remove": true, "delete": true,
		"rename": true, "pin": true, "move": true,
	},
	"session": {
		"list": true, "create": true, "add": true, "remove": true, "delete": true,
		"kill": true, "rename": true, "pin": true, "send": true, "read": true,
		"attach": true,
	},
}

func knownResourceAction(resource, action string) bool {
	return resourceActions[resource][action]
}

func requiredPositionals(resource, action string) []string {
	switch resource + "." + action {
	case "project.add":
		return []string{"PATH"}
	case "project.remove", "project.delete", "project.rename", "project.pin", "project.move":
		return []string{"PROJECT_ID"}
	case "workspace.create", "workspace.add":
		return []string{"PROJECT_ID"}
	case "workspace.remove", "workspace.delete", "workspace.rename", "workspace.pin", "workspace.move":
		return []string{"WORKSPACE_ID"}
	case "session.create", "session.add":
		return []string{"WORKSPACE_ID"}
	case "session.remove", "session.delete", "session.kill", "session.rename", "session.pin",
		"session.send", "session.read", "session.attach":
		return []string{"SESSION_ID"}
	}
	return nil
}

func missingPositional(params map[string]any, labels []string) string {
	items := positionals(params)
	for index, label := range labels {
		if len(items) <= index || strings.TrimSpace(items[index]) == "" {
			return label
		}
	}
	return ""
}

func missingRequiredFlag(resource, action string, params map[string]any) string {
	switch resource + "." + action {
	case "project.rename", "workspace.rename":
		if stringValue(params, "name") == "" {
			return "--name NAME"
		}
	case "session.rename":
		if stringValue(params, "title") == "" {
			return "--title TITLE"
		}
	case "workspace.create", "workspace.add":
		if stringValue(params, "branch") == "" {
			return "--branch BRANCH"
		}
	}
	return ""
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
	commandName := args[0]
	resource := canonicalResource(commandName)
	if len(args) < 2 {
		return newUsageError(fmt.Sprintf("%s command is required", commandName), resourceUsageText(commandName))
	}
	if isHelpArgument(args[1]) {
		fmt.Print(resourceUsageText(commandName))
		return nil
	}
	action := args[1]
	if !knownResourceAction(resource, action) {
		return newUsageError(fmt.Sprintf("unsupported command: %s %s", commandName, action), resourceUsageText(commandName))
	}
	params := parseFlags(args[2:])
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(actionUsageText(commandName, action))
		return nil
	}
	if label := missingPositional(params, requiredPositionals(resource, action)); label != "" {
		return newUsageError("missing "+label, actionUsageText(commandName, action))
	}
	if label := missingRequiredFlag(resource, action, params); label != "" {
		return newUsageError("missing "+label, actionUsageText(commandName, action))
	}
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
		result = &map[string]any{}
	case "project.move":
		method = "project.move"
		result = &map[string]any{}
	case "workspace.create", "workspace.add":
		method = "workspace.create"
		result = &api.WorkspaceCreateResult{}
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
		result = &map[string]any{}
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
		return printValue(map[string]any{"sent": true})
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
		if outputJSON {
			return printValue(settings)
		}
		rows := make([][]string, 0, len(settings.Endpoints))
		for _, name := range settings.Names() {
			value := settings.Endpoints[name]
			marker := ""
			if name == settings.Current {
				marker = "*"
			}
			rows = append(rows, []string{marker, name, value.URL, displayValue(value.SSH)})
		}
		printTable([]string{"CURRENT", "NAME", "URL", "SSH"}, rows...)
		return nil
	}
	if isHelpArgument(args[0]) || (len(args) >= 2 && isHelpArgument(args[1])) {
		fmt.Print(endpointUsageText())
		return nil
	}
	switch args[0] {
	case "add":
		flags := parseFlags(args[1:])
		if boolValue(flags, "help") || boolValue(flags, "h") {
			fmt.Print(endpointUsageText())
			return nil
		}
		if label := missingPositional(flags, []string{"ENDPOINT_NAME"}); label != "" {
			return newUsageError("missing "+label, endpointUsageText())
		}
		name := positional(flags, 0, "endpoint name")
		url := stringValue(flags, "url")
		token := stringValue(flags, "token")
		if url == "" || token == "" {
			return newUsageError("--url and --token are required", endpointUsageText())
		}
		settings.Endpoints[name] = config.Endpoint{Name: name, URL: url, Token: token, SSH: stringValue(flags, "ssh")}
		if settings.Current == "" || boolValue(flags, "use") {
			settings.Current = name
		}
		if err := config.Save(configPath, settings); err != nil {
			return err
		}
		return printValue(map[string]any{"added": true, "name": name})
	case "use":
		if len(args) < 2 {
			return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
		}
		if _, ok := settings.Endpoints[args[1]]; !ok {
			return fmt.Errorf("endpoint not found: %s", args[1])
		}
		settings.Current = args[1]
		if err := config.Save(configPath, settings); err != nil {
			return err
		}
		return printValue(map[string]any{"current": args[1]})
	case "remove":
		if len(args) < 2 {
			return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
		}
		delete(settings.Endpoints, args[1])
		if settings.Current == args[1] {
			settings.Current = ""
		}
		if err := config.Save(configPath, settings); err != nil {
			return err
		}
		return printValue(map[string]any{"removed": true, "name": args[1]})
	case "current":
		value, err := settings.Resolve("")
		if err != nil {
			return err
		}
		return printValue(value)
	default:
		return newUsageError(fmt.Sprintf("unknown endpoint command: %s", args[0]), endpointUsageText())
	}
}

func sshCommand(args []string) error {
	if len(args) >= 1 && isHelpArgument(args[0]) {
		fmt.Print(sshUsageText())
		return nil
	}
	flags := parseFlags(args)
	if boolValue(flags, "help") || boolValue(flags, "h") {
		fmt.Print(sshUsageText())
		return nil
	}
	if label := missingPositional(flags, []string{"SSH_TARGET"}); label != "" {
		return newUsageError("missing "+label, sshUsageText())
	}
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
	if action == "create" && resource == "session" {
		// The daemon reads runtimeKind; the CLI flag uses kebab-case.
		if value, ok := result["runtime-kind"]; ok {
			result["runtimeKind"] = value
			delete(result, "runtime-kind")
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
func positional(value map[string]any, index int, _ string) string {
	items := positionals(value)
	if len(items) <= index {
		return ""
	}
	return items[index]
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
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, projectRowCells(item))
		}
		printTable([]string{"ID", "NAME", "PATH", "WORKSPACES", "PINNED", "CREATED"}, rows...)
	case []WorkspaceRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, workspaceRowCells(item))
		}
		printTable([]string{"ID", "PROJECT", "NAME", "BRANCH", "PATH", "KIND", "SESSIONS", "PINNED", "CREATED"}, rows...)
	case []SessionRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, sessionRowCells(item))
		}
		printTable([]string{"ID", "PROJECT", "WORKSPACE", "BRANCH", "TITLE", "KIND", "COMMAND", "LIFECYCLE", "PINNED", "CREATED"}, rows...)
	case api.WorkspaceCreateResult:
		printKVTable(workspaceCreateResultPairs(items))
	case *api.WorkspaceCreateResult:
		printKVTable(workspaceCreateResultPairs(*items))
	case api.Workspace:
		printKVTable(workspaceCreateResultPairs(api.WorkspaceCreateResult{Workspace: items, Created: true}))
	case *api.Workspace:
		printKVTable(workspaceCreateResultPairs(api.WorkspaceCreateResult{Workspace: *items, Created: true}))
	case api.Project:
		printKVTable(projectPairs(items))
	case *api.Project:
		printKVTable(projectPairs(*items))
	case api.Session:
		printKVTable(sessionPairs(items))
	case *api.Session:
		printKVTable(sessionPairs(*items))
	case config.Endpoint:
		printKVTable([][2]string{
			{"NAME", items.Name},
			{"URL", items.URL},
			{"SSH", displayValue(items.SSH)},
		})
	case *config.Endpoint:
		printKVTable([][2]string{
			{"NAME", items.Name},
			{"URL", items.URL},
			{"SSH", displayValue(items.SSH)},
		})
	case map[string]bool:
		printKVTable(boolMapPairs(items))
	case *map[string]bool:
		printKVTable(boolMapPairs(*items))
	case map[string]any:
		printKVTable(anyMapPairs(items))
	case *map[string]any:
		printKVTable(anyMapPairs(*items))
	default:
		data, _ := json.MarshalIndent(value, "", "  ")
		fmt.Println(string(data))
	}
	return nil
}

func projectRowCells(item ProjectRow) []string {
	return []string{
		item.ID,
		item.Name,
		item.Path,
		strconv.Itoa(item.Workspaces),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func workspaceRowCells(item WorkspaceRow) []string {
	return []string{
		item.ID,
		displayValue(item.ProjectName),
		item.Name,
		displayValue(item.Branch),
		item.Path,
		item.Kind,
		strconv.Itoa(item.Sessions),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func sessionRowCells(item SessionRow) []string {
	return []string{
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
	}
}

func workspaceCreateResultPairs(value api.WorkspaceCreateResult) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"PROJECT", value.ProjectID},
		{"NAME", value.Name},
		{"BRANCH", displayValue(value.Branch)},
		{"PATH", value.Path},
		{"KIND", value.Kind},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
		{"CREATED", displayBool(value.Created)},
		{"GIT WORKTREE", displayBool(value.GitWorktree)},
	}
}

func projectPairs(value api.Project) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"PATH", value.Path},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func sessionPairs(value api.Session) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"WORKSPACE", value.WorkspaceID},
		{"TITLE", value.Title},
		{"KIND", value.Kind},
		{"COMMAND", displayValue(value.Command)},
		{"RUNTIME", value.Runtime},
		{"LIFECYCLE", value.Lifecycle},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func boolMapPairs(value map[string]bool) [][2]string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([][2]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, [2]string{strings.ToUpper(key), displayBool(value[key])})
	}
	return pairs
}

func anyMapPairs(value map[string]any) [][2]string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([][2]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, [2]string{strings.ToUpper(key), displayAny(value[key])})
	}
	return pairs
}

func displayAny(value any) string {
	switch item := value.(type) {
	case bool:
		return displayBool(item)
	case string:
		return displayValue(item)
	case float64:
		return strconv.FormatFloat(item, 'f', -1, 64)
	default:
		data, _ := json.Marshal(item)
		return string(data)
	}
}

func printTable(headers []string, rows ...[]string) {
	widths := make([]int, len(headers))
	for index, header := range headers {
		widths[index] = len(header)
	}
	for _, row := range rows {
		for index, cell := range row {
			if index < len(widths) && len(cell) > widths[index] {
				widths[index] = len(cell)
			}
		}
	}
	printTableRow(headers, widths)
	for _, row := range rows {
		printTableRow(row, widths)
	}
}

func printTableRow(cells []string, widths []int) {
	var line strings.Builder
	for index, cell := range cells {
		if index > 0 {
			line.WriteString("  ")
		}
		if index < len(widths) {
			fmt.Fprintf(&line, "%-*s", widths[index], cell)
		} else {
			line.WriteString(cell)
		}
	}
	fmt.Println(strings.TrimRight(line.String(), " "))
}

func printKVTable(pairs [][2]string) {
	width := 0
	for _, pair := range pairs {
		if len(pair[0]) > width {
			width = len(pair[0])
		}
	}
	for _, pair := range pairs {
		fmt.Printf("%-*s  %s\n", width, pair[0], pair[1])
	}
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

func usage() { fmt.Print(usageText()) }

func usageText() string {
	return `Warren CLI

Usage:
  warren [--endpoint NAME | --server URL --token TOKEN] [--json] <command>

Commands:
  endpoint list|add|use|remove|current
  project list|add|remove|rename|pin|move
  workspace list|create|remove|rename|pin|move  (alias: worktree)
  session list|create|delete|rename|pin|send|read|attach
  ssh USER@HOST                     start daemon, save endpoint, keep SSH tunnel
  headless [FLAGS]                  run the installed daemon

Global flags:
  --json                            machine-readable JSON output
  --endpoint NAME                   endpoint name from the local config
  --server URL --token TOKEN        connect directly to a server
  --config PATH                     config file (default ~/.warren/config.json)

Run 'warren <command> --help' for command-specific help.

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
`
}

func resourceUsageText(commandName string) string {
	aliasNote := ""
	switch commandName {
	case "worktree":
		aliasNote = "\nworktree is an alias for workspace; use either name.\n"
	case "workspace":
		aliasNote = "\nworkspace has alias: worktree.\n"
	}
	switch canonicalResource(commandName) {
	case "project":
		return `Usage:
  warren project list
  warren project add PATH [--name NAME]
  warren project remove PROJECT_ID [--force]
  warren project rename PROJECT_ID --name NAME
  warren project pin PROJECT_ID --pinned BOOL
  warren project move PROJECT_ID [--before OTHER_PROJECT_ID]
`
	case "workspace":
		return fmt.Sprintf(`Usage:
  warren %s list
  warren %s create PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]
  warren %s remove WORKSPACE_ID [--force] [--keep-worktree]
  warren %s rename WORKSPACE_ID --name NAME
  warren %s pin WORKSPACE_ID --pinned BOOL
  warren %s move WORKSPACE_ID [--before OTHER_WORKSPACE_ID]
%s`, commandName, commandName, commandName, commandName, commandName, commandName, aliasNote)
	case "session":
		return `Usage:
  warren session list
  warren session create WORKSPACE_ID [--kind KIND] [--command CMD] [--title TITLE]
  warren session remove SESSION_ID [--force]
  warren session rename SESSION_ID --title TITLE
  warren session pin SESSION_ID --pinned BOOL
  warren session send SESSION_ID [TEXT...]
  warren session read SESSION_ID [--timeout DURATION] [--contains TEXT]
  warren session attach SESSION_ID
`
	}
	return ""
}

func actionUsageText(commandName, action string) string {
	name := commandName
	switch canonicalResource(commandName) + "." + action {
	case "project.list", "workspace.list", "session.list":
		return fmt.Sprintf("Usage:\n  warren %s %s\n", name, action)
	case "project.add":
		return fmt.Sprintf("Usage:\n  warren %s add PATH [--name NAME]\n", name)
	case "project.remove", "project.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove PROJECT_ID [--force]\n", name)
	case "project.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename PROJECT_ID --name NAME\n", name)
	case "project.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin PROJECT_ID --pinned BOOL\n", name)
	case "project.move":
		return fmt.Sprintf("Usage:\n  warren %s move PROJECT_ID [--before OTHER_PROJECT_ID]\n", name)
	case "workspace.create", "workspace.add":
		return fmt.Sprintf("Usage:\n  warren %s create PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]\n", name)
	case "workspace.remove", "workspace.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove WORKSPACE_ID [--force] [--keep-worktree]\n", name)
	case "workspace.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename WORKSPACE_ID --name NAME\n", name)
	case "workspace.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin WORKSPACE_ID --pinned BOOL\n", name)
	case "workspace.move":
		return fmt.Sprintf("Usage:\n  warren %s move WORKSPACE_ID [--before OTHER_WORKSPACE_ID]\n", name)
	case "session.create", "session.add":
		return fmt.Sprintf("Usage:\n  warren %s create WORKSPACE_ID [--kind KIND] [--command CMD] [--title TITLE]\n", name)
	case "session.remove", "session.delete", "session.kill":
		return fmt.Sprintf("Usage:\n  warren %s remove SESSION_ID [--force]\n", name)
	case "session.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename SESSION_ID --title TITLE\n", name)
	case "session.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin SESSION_ID --pinned BOOL\n", name)
	case "session.send":
		return fmt.Sprintf("Usage:\n  warren %s send SESSION_ID [TEXT...]\n", name)
	case "session.read":
		return fmt.Sprintf("Usage:\n  warren %s read SESSION_ID [--timeout DURATION] [--contains TEXT]\n", name)
	case "session.attach":
		return fmt.Sprintf("Usage:\n  warren %s attach SESSION_ID\n", name)
	}
	return resourceUsageText(commandName)
}

func endpointUsageText() string {
	return `Usage:
  warren endpoint list
  warren endpoint add NAME --url URL --token TOKEN [--ssh SSH] [--use]
  warren endpoint use NAME
  warren endpoint remove NAME
  warren endpoint current
`
}

func sshUsageText() string {
	return `Usage:
  warren ssh USER@HOST [--local-port PORT] [--remote-port PORT] [--name NAME]
`
}
