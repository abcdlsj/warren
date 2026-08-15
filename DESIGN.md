# Warren Product and System Design

Status: single source of truth for phase-one design
Scope: product, domain model, architecture, data, terminal runtime, UI, and acceptance
Update rules: when implementation conflicts with this document, this document wins; design changes must update this document in the same commit

## 1. Product Goals

Warren is a local-first development workbench organized around Workspaces, with durable terminal sessions at its core.

The macOS Desktop connects to an in-process Local Host by default, and can also connect to `warren-headless` running on a VPS. Users can switch between Local and Server from the top-right corner to manage Projects, Workspaces, Git worktrees, and Terminal Sessions on the target Host, with persistent terminal interaction through Ghostty. The CLI uses the same remote API and provides SSH bootstrap and port-forwarding entry points.

The system must keep stable boundaries for a future iOS native client, Session sharing, Automation, and a central control plane. Web reachability is enabled explicitly by the user; neither the Desktop nor the headless daemon opens a public entry point by default.

## 2. First Principles

1. Sessions belong to Hosts, Tabs belong to Windows, Runtimes belong to Sessions. An open Tab holds one Session; closing the Tab also ends that Session and its Runtime.
2. Workspaces are the isolation boundary for terminals, Tabs, and async commands.
3. tmux is a replaceable Runtime Adapter, not a product domain model.
4. In Warren v1, an open Tab corresponds to one Warren Terminal Session; closing a Tab explicitly terminates that Session's Runtime. Switching Workspaces or quitting the Client does not additionally terminate Tabs/Sessions that are still retained in the client layout.
5. Only Close Tab or an explicit Terminate Session ends a Runtime; switching Workspaces, detaching, and quitting the Client never end a still-running Session.
6. The UI only displays projections and sends typed intents; it never directly manipulates tmux, the database, or the Ghostty lifecycle.
7. Every state kind has exactly one write authority; caches and projections must not become a second authority.
8. Every async operation carries an immutable target ID and Request ID; it never infers its target from the current selection when it completes.
9. Local and future network connections share the same application protocol.
10. Observability is a product capability, not a test patch.

## 3. Shared Terminology

### 3.1 Resources

**Host**: execution node holding the real state of Projects, Workspaces, Terminal Sessions, and Runtimes. A Host can be the local Host Service on the current Mac, or `warren-headless` on a remote VPS.

**Project**: identity of a Git repository. Projects organize Workspaces; they are not terminal working directories.

**Workspace**: a concrete, accessible local working directory under a Project, together with its Git context. The main checkout and worktrees are both Workspaces. A Workspace ID is stable identity; branch and path are mutable attributes.

**Terminal Session**: interactive terminal context on a Host. It belongs to exactly one Workspace and is accessed through an open Tab; closing the Tab ends the Session. Sessions still running when the Client quits can be kept by the Host and restored after restart.

**Runtime Binding**: persistent mapping from a Terminal Session to its concrete runtime implementation. In phase one, one Warren Session maps to one dedicated tmux session and one pane.

### 3.2 Clients

**Device**: stable device identity. Phase one only has the current Mac, but the model must not assume there is always exactly one device.

**Client Instance**: one run of the app. It is invalidated when the app quits.

**Client Window**: independent navigation and layout scope. Each Window independently stores its Active Workspace and Workspace Views.

**Workspace View**: local presentation state a Window keeps for a Workspace, including ordered Tabs and the Active Tab.

**Tab**: local entry in a Workspace View that points to a Terminal Session. In Warren v1, an open Tab corresponds to one Session; closing a Tab terminates that Session's Runtime. The same active Session is not opened twice within one Workspace View.

**Renderer Surface**: Ghostty surface a client mounts for a Tab. A Surface does not own a Session.

**Attachment**: temporary connection between a Client Instance and a Terminal Session. Future sharing is built from multiple Attachments on the same Session.

**Input Lease**: exclusive lease that lets one Attachment send input to a Session.

**Canonical Viewport Owner**: the only participant allowed to change PTY row/column counts. In phase one, the Input Lease holder also serves this role; observers must not resize the PTY.

### 3.3 Import and Automation

**Superset Import**: onboarding operation that reads Project and Workspace metadata from a local Superset database and copies it into Warren-owned data in one pass. It is not a sync.

**Import Receipt**: durable record of a successful import, containing source, version, time, and summary. After success, Warren no longer prompts automatically or re-imports.

**Automation Run**: in a later version, a non-human task with a clear start, exit status, and retention policy. It may use a Terminal Session to show progress, but must not infer completion from Tabs or prompts.

## 4. Authority Model

```text
Resource Authority
Selected Host
└── Project
    └── Workspace
        └── Terminal Session
            └── Runtime Binding

Presentation Authority
Device
└── Client Instance
    └── Client Window
        ├── Active Workspace
        └── Workspace Views
            └── Tabs / Active Tab

Connection Authority
Terminal Session
└── Attachments
    ├── Input Lease
    └── Canonical Viewport Owner
```

| State | Single authority | Persisted |
| --- | --- | --- |
| Projects, Workspaces, Sessions | Host Store | Yes |
| Runtime Bindings, Session state | Host Store | Yes |
| PTY output recovery position | Host Output Store | Yes |
| Windows, Workspace Views, Tabs | Client Layout Store | Yes, device-local |
| Attachments, Leases, Viewport Owners | Host in-memory state | No |
| Agent activity (working, waiting, ready, failed) | Host in-memory state | No |
| Surfaces, focus, measured size | Renderer Coordinator | No |
| Import completion state | Import Receipt Store | Yes |

## 5. Required Invariants

1. A Workspace belongs to exactly one Project.
2. A Terminal Session belongs to exactly one Workspace.
3. A Tab belongs to exactly one Window's Workspace View and references only Sessions in that Workspace.
4. The top Tab bar shows only Tabs of the Active Workspace.
5. Switching Workspaces must atomically switch Tabs, the Active Tab, and the Renderer Set.
6. A Window has exactly one Active Workspace; a Workspace View has at most one Active Tab.
7. Background Workspaces mount no Surfaces and send no input or resize.
8. A Session has at most one Input Lease and one Canonical Viewport Owner.
9. In Warren v1, closing a Tab terminates its Runtime; it is not merely a detach. Ended Session records without a Tab can be retained for history and later cleanup.
10. Adding a Project creates a Workspace; adding a Workspace or Tab-bar entry creates a Session.
11. Creating a Session must carry a fixed Workspace ID and Request ID; the same Request ID creates at most one Session.
12. App initialization must not auto-create shell, Codex, or Claude Sessions.
13. Selecting a Workspace with no Tabs must idempotently create a default Shell Tab; repeated selection must not create duplicates.
14. The app allows only one foreground Client Instance; repeated launches activate the existing instance and then exit.
15. Quitting the app must end the Client process but must not kill created tmux Sessions.
16. Import must not modify Superset data, Git repositories, worktrees, or tmux.

## 6. Module Boundaries

```text
macOS UI
  ↓ typed intents / screen projections
Client Application
  ├── Client Layout Store
  └── Renderer Coordinator → Ghostty Adapter
  ↓ Host Protocol
Local Transport
  ↓
Host Service
  ├── Resource Service
  ├── Session Service
  ├── Import Service
  ├── Host Store
  └── Terminal Runtime → tmux Adapter
```

Dependencies may only point inward to protocol and domain values. SwiftUI, Ghostty, tmux, SQLite, the Superset schema, and WebSocket are edge adapters.

### 6.1 Future Extension Boundaries

```text
macOS / iOS / Web Client
        ↓
Endpoint Resolver
        ↓
Local IPC / Direct WebSocket / Relay Transport
        ↓
Host Service or Host Daemon
```

The macOS Client uses in-process composition for Local and a versioned WebSocket API for Server. `warren-headless` is the deployment form of a remote Host, owning an independent resource tree and tmux runtime. Switching endpoints only replaces the client projection and renderer; it does not migrate or terminate resources on the other Host.

SSH only bootstraps the remote daemon and forwards a loopback port. Once `warren ssh` establishes reachability, Desktop and CLI continue over the same WebSocket API; Git, tmux, and resource semantics must not be encoded into the SSH transport.

Tailscale, LAN, and Cloudflare Tunnel only provide network reachability; they are not part of the business model. The central Relay Service only provides Host registration, discovery, pairing, revocation, signaling, and WebSocket relay; Sessions and processes remain owned by the Host.

The daemon serves the Web UI over HTTP on `0.0.0.0:8789` (Desktop and CLI keep using the loopback address) and over HTTPS on `0.0.0.0:8788` for LAN devices; the HTTPS listener uses a locally generated CA so phones only need to trust it once. Public access still uses an explicitly started Cloudflare Tunnel or Tailscale Serve HTTPS URL; the URL carries a random pairing token and the WebSocket handshake still requires authentication. Slow Web clients use a bounded non-blocking send queue and must never block the macOS main thread or Host output.

The Web/PWA client uses React + Vite, with source in `Web/`. React owns the component tree and client state; xterm owns terminal rendering. `Web/dist` contains build output only and is embedded by both the Go daemon and the Go Relay Service; do not maintain single-file inline copies of the script.

The remote control plane is an independently deployable process. Each Host is issued a separate credential by an admin and only makes outbound WSS connections to the Relay; the Relay multiplexes Web clients by connection ID and never connects to an inbound macOS port. A short-lived, one-time pairing code is exchanged for an HMAC access token bound to the Host and credential generation; revoking or rotating a Host credential must disconnect the Host immediately and invalidate old tokens. The Relay persists credential hashes, generations, and online metadata, but never Project/Workspace/Session state, terminal output, or user input. Public deployments must sit behind TLS, enforce a strict Origin, use strong random secrets, and use a persistent data volume.

Session sharing is added incrementally through Principals, Share Grants, Capabilities, and multiple Attachments, without changing the resource tree.

## 7. Local Data Design

Warren uses its own versioned SQLite database with WAL, foreign keys, and a busy timeout enabled. JSON files must not carry concurrent resource state.

Default directories:

```text
~/Library/Application Support/Warren/
├── state.sqlite3
├── state.sqlite3-wal
├── state.sqlite3-shm
├── runtime/
│   └── <session-id>/output.log
├── diagnostics/
└── lock/
```

Tests must be able to override the data directory and tmux socket through explicit launch arguments without touching user data.

Minimal data set:

```text
schema_migrations(version, applied_at)
hosts(id, kind, display_name, created_at)
projects(id, host_id, name, repository_path, repository_identity, created_at, updated_at)
workspaces(id, project_id, name, path, branch, kind, created_at, updated_at)
terminal_sessions(id, workspace_id, title, kind, lifecycle, created_at, ended_at)
runtime_bindings(session_id, adapter, runtime_identifier, metadata, output_epoch, output_sequence)
client_windows(id, device_id, active_workspace_id, geometry, updated_at)
workspace_views(window_id, workspace_id, active_tab_id, updated_at)
tabs(id, window_id, workspace_id, session_id, position, created_at)
import_receipts(id, source_kind, source_identity, source_version, summary, completed_at)
request_receipts(request_id, command_kind, resource_id, completed_at)
```

Constraints:

- Projects are deduplicated by normalized repository identity.
- Workspaces are deduplicated by normalized real path within a Host.
- A Session's Workspace foreign key must not be null.
- A Tab's Workspace must match its Session's Workspace.
- Tab positions within a Window are unique and continuously normalized.
- All migrations are transactional and provide forward migrations from the previous published schema.

## 8. Superset One-Time Import

### 8.1 Source

Phase one reads `~/.superset/local.db` by default. Users may explicitly select another file. Reads must be read-only and detect required tables and columns before importing; Warren must not assume Superset's future schema stays unchanged.

Imported objects:

- `projects`: name, main repository path, and available Git metadata.
- `worktrees`: working directory, branch, and owning main repository.
- `workspaces`: display name, order, and relationship to a worktree or the main checkout.

Explicitly not imported:

- tmux sessions, terminal tabs, panes, terminal output.
- Superset accounts, organizations, tasks, Automations, and cloud identities.
- UI window state and credentials.

### 8.2 Flow

```text
Select Import from Superset
→ open and identify schema read-only
→ build candidate Projects/Workspaces
→ validate realpath, Git common-dir, and branch
→ show importable, duplicate, missing, and invalid summary
→ write Warren IDs in one SQLite transaction
→ write Import Receipt
→ select the first valid Workspace
```

On failure the whole transaction rolls back, leaving no half-imported data or Receipt. After success, Warren no longer checks Superset automatically and sets up no file watchers. Re-import is an explicit diagnostic capability, not part of the phase-one main flow.

## 9. Session and tmux Design

### 9.1 Mapping

One Terminal Session maps to one uniquely named tmux session. Phase one uses only its first pane; tmux windows/panes are not exposed as UI domain objects.

The tmux session name is derived from the Warren Session ID, never from user titles, branches, or paths, so renaming or character escaping cannot affect identity.

### 9.2 Creation

```text
CreateSession(workspaceID, launchSpec, requestID)
→ validate Workspace and request idempotency
→ subscribe to Runtime output
→ create tmux detached
→ set working directory, TERM, size, and shell environment
→ install the output pipe
→ persist Session and Runtime Binding
→ return resource events
→ Client Layout creates and activates the Tab
```

The interactive shell starts directly as the foreground process of the tmux pane. Preset commands must not simulate keystrokes after a fixed sleep; the Runtime must provide a reliable way to start commands and preserve a full interactive TTY.

### 9.3 Input

Ordinary byte input uses `load-buffer` and `paste-buffer -d` with a unique tmux buffer, serialized per Session for ordering. Special keys and signals use explicit operations; control actions such as `Ctrl-C` are never encoded as ordinary business strings.

Any input must validate the Attachment, Input Lease, and Session lifecycle. Input failure must not break the connection or the app globally.

### 9.4 Output and Color

`tmux pipe-pane` produces raw PTY bytes. The Host does not strip ANSI, OSC, Unicode, or control sequences; Ghostty parses and renders them on the client side, so colors from Codex, Claude, shells, and TUIs are preserved.

Output goes to both:

- a bounded in-memory ring: low-latency broadcast and short-term recovery;
- a per-Session persistent log: recovery after Host/app restart and long-running tasks.

Every byte position is identified by `epoch + sequence`. On reconnect, a client requests its last Recovery Anchor; the Host sends catch-up bytes or reanchors, never silently skipping gaps.

### 9.5 Size and Focus

Only the Active Tab Surface of the Active Workspace can take local keyboard focus. Only the Canonical Viewport Owner can resize the PTY.

Resize uses one worker per Session with latest-wins semantics; after a Surface becomes active, row/column counts are forcibly recomputed from the actual visible area once. Layout callbacks from hidden Surfaces are discarded.

### 9.6 Close, Quit, and Recovery

- Close Tab: terminate the Runtime, record the Session as ended, then remove the local Tab and Surface; ended Sessions cannot be reopened, only a new Tab/Session can be created.
- Detach: disconnect one Attachment without ending the Session.
- Terminate Session: ask the Runtime to end tmux and record ended state.
- Quit Client: stop UI, connections, and observation tasks; tmux keeps running.
- Relaunch: the Host Store restores resources, and the Runtime Adapter detects and adopts live tmux; missing Runtimes are marked ended and must not stay stuck in connecting.

The Runtime uses a single lifecycle watcher. Each round runs one `list-sessions` to fetch the live tmux set and compares it against all managed Sessions; no per-Session polling processes. Transient command failures do not produce ended events. The watcher must stop when no managed Sessions remain.

## 10. macOS Interaction Design

The UI information architecture follows Superset's proven base relationships without copying its domain implementation:

```text
Window
├── Sidebar
│   └── Project
│       └── Workspaces
└── Workspace Screen
    ├── Top Bar
    ├── Preset Bar
    ├── Workspace-scoped Tab Bar
    └── Active Terminal
```

Behavior requirements:

- The initial empty state shows only Import or Add Project; it creates no Sessions.
- Projects are collapsed by default; Workspaces appear only after explicit expansion, and newly added Projects are collapsed by default.
- Besides a dedicated add button, the whole Project row is the expand/collapse hot zone; expanding does not implicitly create a Session.
- The whole Workspace row is the hot zone for selecting and entering a Session; no small, easy-to-misclick add buttons remain.
- Clicking a Workspace must switch immediately without waiting for tmux, Git, or disk operations.
- After clicking a Workspace with no Tabs, show a non-interactive `Starting Shell…` loading Tab and content progress state immediately, then create the default Shell in that Workspace's serial command queue. Rapid repeated clicks share the same in-flight operation; on success the loading Tab is replaced in place; on failure it is removed and a recoverable error is shown. If the user has already navigated elsewhere, the creation result must not steal the selection back.
- Clicking a Tab must switch the Active Session immediately and hand focus to Ghostty.
- Presets create a Session in the Workspace captured at click time; switching Workspaces must not change the in-flight request target.
- The Tab add button sits right after the last Tab; with no Tabs it sits at the start position.
- Icons that are meaningless, actionless, or redundant are not shown.
- Typography, density, spacing, hierarchy, and hover/selected states use the Superset macOS Desktop as the phase-one visual baseline; the terminal itself uses monospace fonts and Ghostty theme capabilities.
- Every interactive element must have a stable Accessibility Identifier, Role, Label, Value, and an executable Action.
- In the custom frameless window, only an explicit empty chrome leaf node at the top may call AppKit `performDrag`; Tabs, buttons, and the terminal must not inherit window dragging.
- A Workspace aggregates explicit activity across all Host Sessions, prioritized `failed > waitingForInput > connecting > working > ready > exited`; it must not look at only the current Tab.
- Superset-style status dots: failed red breathing, waitingForInput yellow breathing, working amber breathing, ready green static, exited gray static.
- Agent activity is reported by Claude/Codex Hooks managed by Warren. Hooks read only the event type and `WARREN_SESSION_ID`; they never read or upload conversation content. Config merging must preserve user entries and update idempotently.
- When Warren launches Codex, it uses `--dangerously-bypass-hook-trust` only to trust the Warren-generated and -validated Hook; it must not bypass Codex command approval or sandbox.

## 11. Web/PWA Interaction Design

The Web Client uses the same Project → Workspace → Session information architecture as the desktop and follows these rules:

- Desktop width shows a fixed Sidebar, horizontal Session Tabs, Preset Bar, and Terminal.
- Mobile width uses a closable Sidebar drawer, horizontally scrollable Tabs, and a bottom safe-area shortcut bar.
- The PWA provides a manifest, maskable icons, standalone mode, and shell caching; the pairing token is stored locally in the browser after first authentication so the installed app can start from `start_url`.
- Offline, the PWA shows only the cached UI shell and a disconnected state; it never fakes Host or Session availability.
- Web Attachments are distinct identities from Desktop Attachments; both ends can observe simultaneously. Only an Attachment that actually sends input or resizes acquires the Control Lease with last-writer-wins semantics.
- Creating a Session on Web shows loading immediately; when the Host returns the new Session ID, attach directly instead of waiting for the next roster guess.
- Touch arrow keys send real ANSI cursor sequences; Esc, Tab, Ctrl-C, and Ctrl-D send real control bytes.

Performance goals:

- Local navigation and Tab switching complete in one main-thread transaction without waiting for I/O.
- Each tmux lifecycle observation round starts at most one query process; query frequency does not grow with Session count.
- Input writes to the Runtime must not be blocked by persistence or the global Snapshot.
- PTY output must not be backpressured by database writes.
- A single Workspace failure must not freeze other Workspaces or the whole window.

## 12. Non-Intrusive Observability and Acceptance Design

Acceptance must not depend on screenshots, must not move the mouse, and must not steal keyboard focus from the user's current app.

### 12.1 Three Observation Layers

**Domain event log**: every command and state transition emits a structured event with monotonic timestamp, trace ID, request ID, window ID, workspace ID, session ID, old state, target state, result, and error. Credentials and full user input must never be logged.

**Semantic UI snapshot**: the real Views expose a read-only semantic tree with Accessibility Identifier, role, label, value, enabled, selected, focused, frame, and children. It describes what the user can operate on, without pixels.

**Terminal probe**: records Runtime state, actual tmux dimensions, Attachment/Lease, input sequences, Recovery Anchor, raw output summaries, and parsed cell/style summaries. Color acceptance reads post-ANSI cell attributes, never screenshots.

### 12.2 Test Execution

Tests use an isolated temporary directory and an isolated tmux server:

```text
Warren Test Process
├── data-dir = mktemp
├── tmux socket = warren-test-<uuid>
├── deterministic clock / request IDs
├── offscreen, never-key NSWindow
└── test observation socket
```

The real SwiftUI Root View is mounted in an `orderOut`'d NSWindow. Tests click, select, type, and resize through Accessibility Actions or direct event dispatch; they must not use CGEvent to move the global mouse, must not call `NSApp.activate`, and must not call `makeKeyAndOrderFront`.

The Observation Socket only opens under an explicit test launch argument, uses a random temporary Unix socket, and provides:

- `snapshot.resources`
- `snapshot.window`
- `snapshot.accessibility`
- `snapshot.renderer`
- `snapshot.runtime`
- `events.since(sequence)`
- `intent.perform(identifier, action)`
- `wait.until(predicate, timeout)`

Production builds disable this entry point by default. Test actions must still go through the same typed intents as the real UI; directly tampering with the Store to fake a pass is forbidden.

### 12.3 Acceptance Evidence

Each end-to-end case outputs one machine-readable artifact:

```text
artifacts/<run-id>/
├── result.json
├── event-trace.jsonl
├── semantic-ui.json
├── runtime.json
└── terminal-cells.json
```

Failure reports must identify the last successful invariant, the first violating event, related resource IDs, and a reproducible command. Tests must verify at the end that the user's mouse coordinates and foreground app PID did not change.

## 13. Out of Scope for Phase One

- Multi-user accounts, organizations, billing, and cross-organization Host directories.
- Automatic Host registration or automatic public entry points.
- iOS native client.
- Multi-person sharing and permission UI.
- Automation scheduler.
- tmux multi-window/pane to UI Pane mapping.
- Cross-device real-time Client Layout sync.
- CRDT.

These capabilities can only be added incrementally through the defined Host Protocol, Transport, Principal/Capability, Attachment, and Runtime boundaries; they must not pollute the phase-one model retroactively.
