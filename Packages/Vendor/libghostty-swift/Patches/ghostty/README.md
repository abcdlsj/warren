# Ghostty Patches

This directory is the single place for local upstream Ghostty patches used by
the `libghostty-spm` build pipeline.

## Rules

- Keep patches numbered so they apply in a stable order.
- Prefer standard unified diff files (`.patch`) when the upstream context is
  stable.
- Use executable patch scripts (`.sh`) only when upstream context is too
  unstable for a reliable diff.
- Every patch in this directory must be safe to re-run.
- Patches here are applied automatically by `Script/build-ghostty.sh`, so they
  affect macOS, iOS, and Mac Catalyst builds equally.

## Current goal

This patch workflow exists so we can carry host-managed IO work required for
sandboxed iOS, macOS, and Mac Catalyst integration without hiding upstream
modifications inside ad-hoc build script edits.

## Rebase notes

- `0002-host-managed-io.patch` — rebased onto ghostty `2da015c` (July 2026,
  the VT-throughput commit #13220). Host-managed IO is **not** upstream; this
  patch still adds it (the C API `ghostty_surface_write_buffer` /
  `ghostty_surface_process_exit`, the `receive_buffer`/`receive_resize`
  callbacks, the `GHOSTTY_SURFACE_IO_BACKEND_*` enum, `src/termio/HostManaged.zig`,
  and the `Surface.zig` backend switch). The throughput commit only shifted line
  numbers and inserted a `GHOSTTY_SURFACE_ID` env block inside `Surface.zig`'s
  init; that block is preserved inside the new `.exec` switch arm. `0001` and
  `0009` were likewise re-targeted to this ref (renamed `lib_shared`, restructured
  SIMD flags list).
