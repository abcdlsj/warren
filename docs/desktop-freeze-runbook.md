# Desktop Freeze ("Spinner") Troubleshooting Runbook

This document is the context for an automation that detects a frozen Warren
desktop and spawns a dedicated Codex session to diagnose and fix it. It
condenses what was learned while debugging repeated "spinner / stuck" reports
on 2026-08-16/17.

## Symptom

- The desktop shows an in-app spinner or a black terminal pane and stops
  responding to clicks.
- Either:
  - the main thread is pegged at ~100% CPU inside SwiftUI
    (`ViewGraphRootValueUpdater.updateGraph` -> layout), or
  - the main thread is idle but `logd` is backed up and the UI stays frozen.
- `~/Library/Logs/Warren/terminal-diagnostics.log` stops advancing while the
  Warren GUI process is still alive.
- The unified log contains bursts of:

  ```
  [com.apple.runtime-issues:SwiftUI] Publishing changes from within view
  updates is not allowed, this will cause undefined behavior.
  ```

## Where the logs live

| Path | Writer | Notes |
| --- | --- | --- |
| `~/Library/Logs/Warren/terminal-diagnostics.log` (+ `.log.1`) | Warren's `TerminalDiagnostics` (Swift, direct FileHandle, **not** os_log) | Freezing here is the freeze detector |
| `~/.warren/ghostline.log` | ghostline server | Runtime/session adoption |
| `~/.warren/output/*.out` | session output captures | Contains shell history incl. CLI commands |
| `~/.warren/state.json` | headless daemon | Projects/workspaces/endpoints |
| Unified log | SwiftUI / AppKit / CFNetwork / Ghostty | Use `/usr/bin/log`, never `log` (zsh math builtin) |

## Detection checklist (run before restarting anything)

1. Find the GUI process and its CPU:

   ```sh
   ps -o pid,etime,%cpu,command -p "$(pgrep -f '/Applications/Warren.app/Contents/MacOS/Warren$' | head -1)"
   ```

2. Check whether the diagnostics log is still being written:

   ```sh
   stat -f '%Sm %z' -t '%H:%M:%S' ~/Library/Logs/Warren/terminal-diagnostics.log
   tail -20 ~/Library/Logs/Warren/terminal-diagnostics.log
   ```

   Frozen mtime while the process is alive = freeze.

3. Count SwiftUI publishing faults in the unified log:

   ```sh
   /usr/bin/log show --last 5m \
     --predicate 'eventMessage CONTAINS[c] "Publishing changes"' \
     --style compact | wc -l
   ```

   A burst (or repeated hits) is the signature of the known publish-during-
   view-update bug. Absence does not rule out a layout-only loop.

4. Check the installed binary is newer than the last fix commit:

   ```sh
   stat -f '%Sm' -t '%H:%M:%S' /Applications/Warren.app/Contents/MacOS/Warren
   git log --oneline -3
   ```

   If the binary predates the fixes below, the freeze may already be fixed in
   source; rebuild and retest first.

5. Find the last user action in the diagnostics log:

   ```sh
   rg '"event":"action"' ~/Library/Logs/Warren/terminal-diagnostics.log | tail -5
   ```

   So far every freeze has been triggered by a workspace or tab switch,
   frequently right after a batch of workspaces was imported/created via the
   `warren` CLI.

6. Sample the process to see where time goes:

   ```sh
   sample <pid> 2 1 -file /tmp/warren_sample.txt
   ```

   - Main thread in `updateGraph`/layout => SwiftUI re-entrant update loop.
   - A thread stuck in `zig_os_log_with_type` /
     `FIREHOSE_CLIENT_THROTTLED_DUE_TO_HEAVY_LOGGING__` => logd backpressure;
     find what flooded os_log first.

7. If the UI must be recovered now: restart the Warren GUI **only**. Sessions
   live in `warren-headless` / ghostline, not the GUI. While the GUI is stuck,
   sessions stay usable through the Web UI at `http://127.0.0.1:8789` (token in
   `~/.warren/token`) or the `warren` CLI.

## Root causes found so far

### 1. Ghostty open-url fallback flooded os_log (earlier incident)

See `docs/lessons.md` #002. Ghostty fell back to spawning `/usr/bin/open`
when the embedder did not consume the open-url action, producing millions of
`os-open: open stderr=` lines and throttling the whole process.

Fix: vendored `libghostty-swift`; `GhosttySurface` installs an
`openURLHandler` and the C action callback returns `true` when a handler is
present. Warren owns URL validation.

### 2. Terminal state `@Published` writes inside SwiftUI view updates

Ghostty callbacks are dispatched through `terminalRunOnMain`, which executes
**synchronously** when already on the main thread. Surface creation/rebuild
and focus changes can therefore fire callbacks inside `NSViewRepresentable`
updates (`makeNSView`/`updateNSView`, layout passes). Every `@Published`
write in `TerminalViewState` (vendored
`State/TerminalViewState+Delegate.swift`) then publishes from within a view
update, faulting SwiftUI and re-entering layout.

Affected properties: `surfaceSize`, `isFocused`, `title`, `workingDirectory`,
`bellCount`/`lastBellAt`, `lastDesktopNotification*`,
`lastCommandExitCode`/`lastCommandDurationNanos`.

Fix: defer every write one main-actor hop (`Task { @MainActor }`) and skip
identical values. Commits:

- `63a4312` fix(vendor): defer ghostty state publishes out of SwiftUI updates
  (resize + focus)
- `af20337` fix(vendor): defer remaining terminal state publishes out of
  SwiftUI updates (title, working dir, bell, notification, command)

### 3. Warren UI `onPreferenceChange` handlers writing `@State` in-transaction

`onPreferenceChange` callbacks run inside the SwiftUI update transaction.
Two Warren views wrote `@State` there:

- `WarrenOverflowFadeScrollView` (DesignSystem): `contentFrame` + edge states,
  then `onHorizontalOverflowChange` (tab bar `hasTabOverflow`, which feeds
  back into layout width).
- `WarrenDesktopSidebarRows` (Desktop): `dragFrames`, which is read by the
  drag overlay in the same body.

Fix: defer the writes one main-actor hop and guard equality. Commit:

- `0aa4f2f` fix(desktop): defer preference-change state writes out of SwiftUI
  updates

## Common trigger

Switching workspaces/tabs, especially:

- right after a batch migration/import that changes the roster (e.g. the
  Superset -> `warren` CLI migration that created 11 bili-gateway
  workspaces and removed one while the desktop was connected);
- while a terminal surface is being mounted/hidden and the window is
  resizing at the same time (attach `resize_request` followed by the fault).

## Verification

- `swift test --package-path Packages/GhosttyAdapter` — includes
  `TerminalStatePublicationTests` that pin the deferred-publication contract
  with a bare `TerminalViewState` (no real surface).
- `swift test --package-path Packages/Desktop` — includes NSHostingView-based
  hosts of the tab bar / overflow scroll view that assert overflow state
  settles.
- `swift build` at the repo root.

## How to fix a new occurrence

1. Confirm the running binary includes the three commits above; if not,
   rebuild/install and retest before debugging.
2. Reproduce with the smallest fake: a bare `TerminalViewState` for vendored
   callbacks, or an `NSHostingView` harness for Warren views (see the test
   files referenced above).
3. Find the remaining `@Published`/`@State` write that can run synchronously
   during a view update (layout, `updateNSView`, `onPreferenceChange`, or a
   `terminalRunOnMain` callback on the main thread).
4. Defer it one main-actor hop, guard equality, add a regression test,
   run the package tests + root build, and commit with a `fix:` prefix.
