# Startup Performance Governance

Status: active engineering policy

This document is the review contract for Warren cold-start changes. Read it
before changing the application launch path, the menu-bar supervisor, the
desktop connection handshake, or headless daemon initialization. Update this
document when the startup sequence or its performance budget changes.

## Goal

Cold start means the first launch after the Warren processes are not running.
The user should see a usable desktop shell quickly while the daemon and
optional integrations continue to become ready in the background. Startup
optimization must reduce time to first useful interaction without weakening
session durability, authentication, recovery, or error visibility.

The primary milestones are:

| Milestone | Meaning | May wait for network or optional disk I/O? |
| --- | --- | --- |
| `T_process` | Warren process and single-instance lock are established | No |
| `T_window` | Main window and menu are visible | No |
| `T_token` | Local daemon has published its authentication token | No; token polling is bounded and local |
| `T_transport` | Desktop WebSocket is authenticated | No optional work may precede it |
| `T_roster` | First authoritative roster is applied | No optional work may precede it |
| `T_usable` | The user can inspect and operate the restored workspace | No |

The critical path is `T_process -> T_window -> T_token -> T_transport ->
T_roster -> T_usable`. Every other startup operation must either be removed
from that path or have a bounded, user-visible reason to remain there.

## Current startup sequence

The following ownership boundaries are intentional:

1. `Sources/Warren/WarrenMain.swift` performs diagnostics, single-instance
   locking, helper launch, window creation, and menu construction. These are
   required to present the desktop shell.
2. `Sources/WarrenDaemonMenuBar/main.swift` owns daemon supervision. It creates
   the status item, checks `/healthz` and authenticated `/v1/state`, starts the
   headless process when needed, and reports daemon state. Its polling loop is
   independent from the desktop's WebSocket connection.
3. `Headless/cmd/warren-headless/main.go` loads settings, the token, and the
   durable store, verifies the runtime adapters, creates the listener, and then
   starts the HTTP/WebSocket server. These prerequisites currently precede the
   first listener; measure them before changing their order. Tunnel restoration
   is already asynchronous.
4. `Sources/Warren/WarrenCompositionRoot.swift` waits only for the local token
   file before asking the remote model to connect. The remote model owns
   WebSocket retry and readiness; the desktop must not add a second `/v1/state`
   probe for the same handshake.
5. `Sources/Warren/WarrenRemoteApplicationModel.swift` establishes the
   authenticated WebSocket and applies the first roster. Optional tunnel
   status refresh runs concurrently and must not delay roster consumption.
6. `Headless/internal/server/service.go` performs the minimal in-memory and
   lifecycle initialization required to serve clients. Agent hook installation
   touches user configuration and therefore runs outside the readiness path in
   a best-effort background goroutine.

The legacy worktree-ownership migration in `Service.Start` remains synchronous
because it changes durable state that the first roster can expose. It may move
later only with an explicit compatibility plan, idempotence proof, and a
measurement showing that deferral cannot expose stale ownership.

The following work is intentionally deferred:

- CLI installation and shell profile edits (`WarrenCLIInstaller`), using a
  utility-priority task from the desktop app.
- Automatic update checks, already delayed by the app's update cadence.
- Tunnel status refresh, which is useful for the top-bar projection but is not
  required to render the workspace roster.
- Codex and Claude hook installation, which is optional and must not prevent
  daemon readiness.

The current daemon-side candidates for a later, measured optimization are
`settings.Load`, runtime adapter checks, the Ghostline version probe, and LAN
certificate setup. They are not background work yet because the HTTP listener
and runtime selection must remain coherent when the first client connects.

## What belongs on the critical path

Keep an operation synchronous only when all of the following are true:

- the next user-visible state cannot be correct without its result;
- moving it later would create a broken or ambiguous interaction;
- it has a bounded completion time or an existing retry/timeout policy; and
- it does not duplicate work owned by another startup component.

Examples include the single-instance lock, creating the first window, reading
the local token needed for authentication, opening the WebSocket, and applying
the first roster. Store initialization that is required to answer the first
roster also belongs here, but optional migrations, integrations, and metadata
refreshes do not.

## What belongs in the background

An operation is a background candidate when it is optional for first use,
touches user configuration, performs network I/O, or only enriches an already
usable projection. Background work must satisfy all of these rules:

- use an explicit task or goroutine with a clear owner;
- cancel it on disconnect, replacement, or application termination when the
  result is no longer relevant;
- make late results harmless by checking the active endpoint/generation before
  publishing state;
- log failures at an appropriate level without turning an optional failure into
  a startup failure; and
- avoid unbounded retries, duplicate requests, and untracked goroutine leaks.

Moving work to the background is not permission to race shared state. Swift
tasks must respect actor isolation and `Sendable` boundaries. Go goroutines
must not read or write mutable service state outside its established locks or
single-owner loops.

## Review checklist for every startup change

Before editing:

- Identify which milestone the change affects and write down its current and
  expected owner.
- Search all startup callers, including the menu-bar helper and daemon start;
  do not optimize one client while leaving a duplicate probe elsewhere.
- Classify each operation as critical, deferred, or lazy-on-first-use.
- Confirm whether the operation performs disk, network, process, shell-profile,
  hook, migration, or renderer work.

After editing:

- Verify that `T_window`, `T_transport`, and `T_roster` do not wait on optional
  work.
- Check cancellation and replacement behavior for every new task/goroutine.
- Check first launch, daemon already running, token missing, daemon restart,
  endpoint switch, app termination, and read-only home-directory behavior.
- Preserve durable sessions and the existing reconnect/retry semantics.
- Add or update a focused test when ordering, generation, or failure behavior
  changes.
- Run `git diff --check`, the relevant Swift build/tests, and
  `go test ./Headless/...` for daemon changes.
- Record the measured or reasoned performance impact in the change description
  and update this document if the ownership boundary changed.

## Measurement protocol

Use a cold process launch, not only a warm rebuild. Capture at least three
runs with the same machine, display, and workspace state. Record:

- process start to first window visible (`T_window`);
- process start to token publication (`T_token`);
- token to WebSocket authentication (`T_transport`);
- authentication to first roster (`T_roster`); and
- process start to first usable workspace (`T_usable`).

When adding an operation, measure both wall time and resource impact (CPU,
memory, disk, network, and child-process count). A faster window that leaves a
slow or unreliable roster is not a successful startup optimization.

For failures, include the phase and owner in logs. Optional work should be
diagnosable after launch without blocking the primary connection path.

## Current follow-up candidates

These are not permission to change behavior without measurement:

- instrument the milestones above with structured diagnostics;
- reduce duplicate supervisor health requests while keeping the status item
  truthful;
- make deferred task cancellation and completion observable in debug builds;
- profile first-roster store loading and migrations before moving any required
  work out of the daemon's critical path; and
- evaluate whether renderer or endpoint metadata can be lazy-loaded after the
  first roster.

Any future change in these areas must start by rereading this document and
updating the ownership table when the sequence changes.
