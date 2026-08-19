# Changelog

All notable changes to Warren are documented here.

## [Unreleased]

- Check GitHub Releases in the background and offer a prominent in-app Warren update banner with one-click download and installation.
- Add release notes here before the next version is published.

## [0.5.0] - 2026-08-20

### Added

- Show project and workspace deletion progress directly in the desktop sidebar, disabling affected controls until the daemon confirms removal.

### Changed

- Preserve legacy Warren-managed worktree ownership during startup migration while leaving external checkouts user-owned.
- Keep desktop workspace actions in an explicit, stable order.

### Fixed

- Reconcile pending project and workspace deletions across roster refreshes and reconnects without leaving stale loading indicators.
- Flush the AppKit layout before creating a terminal surface so the initial shell cursor and viewport use the final pane geometry.

## [0.4.0] - 2026-08-19

### Added

- Add project-scoped controls for importing existing Git worktrees, including one-time selection and automatic import from Desktop, Web, and CLI.
- Show merged worktrees in the macOS sidebar and keep their terminal groups accessible.
- Configure empty-workspace defaults for opening a shell and starting an AI session.

### Changed

- Keep imported worktrees protected from destructive workspace operations.
- Present the terminal-group editor from the desktop window for predictable modal behavior.

### Fixed

- Make workspace removal resilient when Git worktree cleanup fails.
- Correct tmux session listing when separators appear in session names.
- Preserve workspace initializer argument order during worktree-backed workspace creation.

## [0.3.1] - 2026-08-19

### Fixed

- Fix first launch reporting "The local daemon is not running" (code 7) on a clean
  machine: the client now re-reads `~/.warren/token` on every connect attempt, so it
  picks up the token the daemon writes during first-run startup.

## [0.3.0] - 2026-08-19

### Added

- Import project git worktrees into workspaces, gated behind a new worktree setting.
- Start a default AI session for new workspaces on macOS and the web.
- Configure the order of session presets.
- Open worktrees in external IDEs from the workspace menu, with installed IDE detection and custom IDE entries.
- Drag projects to reorder the sidebar directly on the web.
- Add an onboarding changelog page.

### Fixed

- Make the worktree import setting toggleable in settings.
- Avoid restoring sessions during web restoration.
- Reject invalid git worktree records.

## [0.2.0] - 2026-08-19

### Added

- Move sessions between terminal groups and workspaces with tab-scoped targets.
- Read agent transcripts in the headless service and surface agent chat updates on the web.
- Remember scoped navigation positions and merge them into workspace state.
- Track worktree branches merged into the default branch.
- Add merge projection state and session locking in the headless service.

### Changed

- Improve session title precedence and merged-workspace reconciliation.
- Remove activity drag-to-dismiss in favor of the context-menu flow.
- Bound session attach preparation and harden terminal surface/output lifecycle handling.

### Fixed

- Prevent fullscreen teardown deadlocks and merge projection refresh saturation.
- Preserve terminal search keyboard handling.
- Harden agent transcript parsing and stream handling.
- Scope relay web assets under the host route when Vite emits relative URLs.
