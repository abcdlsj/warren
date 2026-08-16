# Warren engineering lessons

High-value pitfalls and the context around them, numbered in the order they
were recorded. Each entry is a short story: symptom, root cause, what we
learned, and the current state.

## 001 - tmux snapshot replay misaligns TUI color blocks (and why ghostline exists)

### Symptom

With the tmux runtime, agent TUIs (Codex, Claude Code, etc.) show misaligned
background-color blocks on soft-wrapped colored history. A tab switch or
attach replays the full tmux history and the color blocks no longer line up
with the text.

### Root cause

tmux is a middle layer that re-parses program output and emits its own
rendering sequence. Warren captures that rendering (`capture-pane`) and
replays it into Ghostty. Replaying a full snapshot can break background color
blocks on soft-wrapped history because of Ghostty's BCE (background color
erase) handling - upstream issues
[ghostty#12497](https://github.com/ghostty-org/ghostty/issues/12497) and
[ghostty#12505](https://github.com/ghostty-org/ghostty/issues/12505).

Two adjacent traps made it worse:

- Hidden AppKit terminal views report their intrinsic 50x17 grid to tmux
  unless every mounted renderer is forced to the same pane-sized viewport;
  otherwise switching tabs visibly reflows the agent before it expands again.
- An invalid font size/typography preference can make Ghostty or the web
  terminal construct an unusable grid, so preferences are clamped at the
  boundary.

### The struggle (from git log)

The color-block problem is exactly what pushed Warren away from tmux:

- `e333fb1` / `e5f902b`: use ghostline for the PTY runtime (ghostline became
  the default).
- `ccec0ba`: render PTY snapshots with libghostty-vt instead of tmux capture.
- `fc13cfb`: restore colors and avoid black screen on PTY reattach.
- `f505ef8`: preserve the TUI cursor in ghostline snapshots.
- ghostline `10825d0`: resize the emulator before the PTY so redraws are not
  parsed at the old size; `7a6f71b`: restore cursor and terminal modes in VT
  snapshots.
- `d6b3f5e` / `d0f21b2`: keep tmux as a supported alternative runtime with
  ghostline/tmux coexistence.
- `fde9aea` / `e906e57`: document the BCE limitation and its live-scroll
  caveats.

### Current state

ghostline is the default runtime: the server owns the PTY and emulates it
server-side with libghostty-vt, so the client parses the original PTY bytes
once instead of tmux's re-rendered output. tmux remains supported but its
snapshot replay keeps the BCE limitation. Warren deliberately keeps snapshot
bytes faithful and tracks upstream instead of applying a lossy workaround;
surfaces are retained across tab switches so one manual resize reflows
Ghostty back into alignment, and later switches resume from an anchor without
replaying history. A live scroll can still re-trigger BCE corruption until
upstream changes the behavior.

## 002 - Ghostty open-url fallback flooded os_log and pegged a core

### Symptom

The fan spins up and Warren.app holds one thread at ~90-97% CPU for 20+
minutes. `logd` sits at 60%+ CPU. The unified log contains 3,965,343 copies
of one message in under two seconds:

```
[com.mitchellh.ghostty:os-open] os-open: open stderr=
```

After the burst, the firehose starts throttling and drops messages, but the
thread keeps burning CPU on formatting and retry waits.

### Root cause

One click on a file path rendered by an agent TUI
(`/Headless/internal/server/ghostline.go`):

1. Ghostty detects the link and calls `Surface.processLinks` -> `openUrl`
   (`src/Surface.zig`).
2. The embedded apprt (libghostty-swift 1.0.16) does not consume the action:
   its C action callback always returns `false`, so Ghostty believes the
   embedder did not handle it.
3. Ghostty falls back to `internal_os.open` and spawns `/usr/bin/open`, then
   `openThread` reads stderr and logs every line
   (`src/os/open.zig`, `open stderr=`).
4. That one runaway `open` produced millions of stderr lines. Release builds
   keep info logging enabled, and the macOS os_log backend formats every
   message, so the thread saturates a core and logd.

What it was NOT: page-capacity expansion logs. Measured with libghostty-vt on
the same core: a real 5MB Codex stream produces 0 capacity logs; crafted
style/hyperlink stress streams produce ~53-530 per pass; only a zero-width
character flood reaches 210k logs per 400KB (a different message).

### Fix

Warren owns the open semantics instead of letting Ghostty fall back:

- Implement the terminal open-url handler: only non-empty URLs with a known
  scheme (`http`, `https`, `mailto`, `tel`, `file`) or existing absolute
  paths are opened, via `NSWorkspace`; missing paths and empty targets are
  silently ignored.
- Make the vendored libghostty-swift action callback return `true` when the
  embedder installed an open-url handler, so Ghostty never spawns
  `/usr/bin/open`. Upstream has no fix (libghostty-swift main is still
  storage.1.0.16), hence the vendor.

### Debugging notes

- `ps -M` shows one thread with ~90% CPU and ~12 minutes of user time while
  every other thread is idle.
- `sample` pins the hot thread inside `zig_os_log_with_type` ->
  `_os_log_impl_flatten_and_send`, with the
  `__FIREHOSE_CLIENT_THROTTLED_DUE_TO_HEAVY_LOGGING__` marker.
- Use `/usr/bin/log show ... --predicate 'process == "Warren"'`; plain `log`
  in zsh is the math builtin and fails with "too many arguments".
