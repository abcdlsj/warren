# CLAUDE.md

## Build & Test Commands

```bash
mise run build           # Debug build (swift build | xcbeautify)
mise run build:release   # Release build
mise run dev             # Build + run the app
mise run test            # All tests
mise run clean           # Remove .build
```

Tests are executable targets, run via `swift run <TestTarget>` from each package directory.

## Architecture

Den is a macOS native workspace terminal. It organizes development around **Projects** (git repos) and **Worktrees** (branches), using **tmux** as the persistent runtime backend and **libghostty** for GPU-accelerated terminal rendering.

### Package Dependency Graph

```
App Target (Sources/Den/)
  +- DenCore        -- Models + @Observable AppState (no I/O)
  +- DenPersistence -- GRDB/SQLite repositories (depends on DenCore)
  +- DenTmux        -- tmux CLI integration via actors (no deps on other packages)
  +- DenGit         -- git worktree integration via actors (no deps on other packages)
  +- DenTerminal    -- libghostty GPU terminal (depends on GhosttyKit XCFramework)
  +- DenUI          -- SwiftUI sidebar views (depends on DenCore)
```

`WorkspaceManager` lives in the app target because it coordinates across DenPersistence, DenTmux, DenGit, and DenCore.

### Data Flow

```
User action -> WorkspaceManager -> AppState (@Observable) -> SwiftUI re-render
                |                        |
         TmuxBackend (actor)     UIStateRepository (SQLite)
```

**AppState** (`@MainActor @Observable`) is the single source of truth for UI.

### UI Structure

AppKit shell with SwiftUI leaf views:

```
NSSplitViewController (2 columns)
  +- NSHostingController -> WorktreeSidebarView (200pt min, SwiftUI)
  +- TerminalAreaViewController                 (400pt min, AppKit)
       +- GhosttySurfaceView (libghostty Metal rendering)
```

### Key Mapping: Worktree -> tmux

Each worktree binds to one tmux session named `<shortName>/<branchSlug>`. The terminal surface runs `tmux attach-session -t <name>`. LRU cache (max 3) keeps recently-used surfaces alive.

### Persistence

GRDB.swift with SQLite (WAL mode) at `~/Library/Application Support/Den/den.sqlite`. Three tables: `project`, `worktree`, `uiState`.

## Key Conventions

- **Swift 6 strict concurrency**: UI code is `@MainActor`. Backends use actors.
- **macOS 14+ (Sonoma)**: Required for `@Observable` macro.
- **AppKit-first**: Terminal embedding uses AppKit. SwiftUI is for sidebar views only.
- **SwiftUI views are pure**: Data + callbacks as parameters, no direct AppState dependency.
- **tmux session naming**: `<shortName>/<branchSlug>` via `SessionNaming`. Common branch prefixes stripped.
- **No XCTest**: Tests are executable targets with custom assert helpers.
