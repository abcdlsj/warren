# Changelog

All notable changes to Warren are documented here.

## [Unreleased]

- Add release notes here before the next version is published.

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
