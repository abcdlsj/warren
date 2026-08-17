# Problem Record: Ghostline Migration Fails to Encode a Live Session Snapshot

- Recorded: 2026-08-17 (Asia/Shanghai)
- Repository: `abcdlsj/warren`
- Branch: `main`
- Related repository: `../ghostline`, currently at `v0.5.0`
- Status: Diagnosed with a reproducible failure class; exact historical parser state is not recoverable; fix pending
- First observed: 2026-08-17 11:30:04 (Asia/Shanghai)
- Affected runtime: `warren_150c5318c4bf404e9b9c6a2cb31bd6c1`
- Affected session ID: `150c5318-c4bf-404e-9b9c-6a2cb31bd6c1`
- Affected workspace: repository `abcdlsj/warren`, branch `main`

## Summary

Warren's new headless daemon embeds ghostline `v0.5.0`, while the detached
ghostline server that owns existing PTY sessions is still running the `v0.4.0`
protocol. Warren correctly detects the protocol mismatch and attempts a rolling
upgrade. The upgrade pauses the old server, prepares each session, and asks the
old server to encode a libghostty-vt migration snapshot. Encoding fails for one
live session with `ghostty snapshot encode failed: -2`.

The new server exits and Warren keeps the old server alive. This preserves the
session and is the correct failure behavior for a migration that cannot prove
that all sessions were transferred.

## Symptom

The affected session is visibly healthy and remains interactive. It is a
long-lived Codex shell with `lifecycle=running` and `alive=true`. However, the
rolling upgrade fails during the migration snapshot step:

```text
ghostline serve: adopt from /Users/lisongjian/.warren/ghostline.sock.admin: encode snapshot for warren_150c5318c4bf404e9b9c6a2cb31bd6c1: ghostty snapshot encode failed: -2
ghostline upgrade phase=failed from_version="0.4.0" to_version="0.5.0" trigger="protocol_mismatch" error="start upgraded server: spawned ghostline server exited: exit status 1: ghostline serve: adopt from /Users/lisongjian/.warren/ghostline.sock.admin: encode snapshot for warren_150c5318c4bf404e9b9c6a2cb31bd6c1: ghostty snapshot encode failed: -2"
```

The same failure was retried at 11:49 and failed on the same session. The
old server continued to answer RPC requests with protocol version `0.4.0`.

## Expected Behavior

When Warren starts with ghostline `v0.5.0` and finds an older detached server,
the server should migrate every live session, including the emulator state,
without interrupting child PTYs. After all sessions are committed, the stable
socket should point to the new server and the old server should retire.

If any session cannot be transferred safely, the old server must remain the
owner of every session and the new server must exit. No session or PTY data
should be lost.

## Version Evidence

- `warren/go.mod` declares `github.com/abcdlsj/ghostline v0.5.0`.
- The installed `/Applications/Warren.app/Contents/MacOS/warren-headless`
  binary embeds ghostline `v0.5.0` and Warren build `40d7977`.
- The long-lived ghostline server process (PID `92390`) loads
  `~/go/pkg/mod/github.com/abcdlsj/ghostline@v0.4.0/third_party/lib/libghostty-vt.dylib`
  and reports RPC protocol version `0.4.0`.
- `../ghostline` local `HEAD`, `origin/main`, and tag `v0.5.0` all point to
  commit `2118ef6`; there was no newer upstream ghostline version at the time
  of investigation.

## Upgrade Path

The relevant path is `ensureGhostlineClient` in
`Headless/cmd/warren-headless/main.go`:

1. Connect to the stable ghostline socket.
2. Query the detached server's protocol version.
3. On a mismatch, spawn a fresh server on a temporary socket.
4. Ask the fresh server to adopt every session through the old admin socket.
5. The old server encodes one migration snapshot per session.
6. Only after all sessions are prepared and committed does Warren replace the
   stable socket symlink.
7. On any error, the fresh server exits and Warren keeps using the old client.

The failure occurs at step 5, before the new server can commit this session.

## What `-2` Means

`-2` is `GHOSTTY_INVALID_VALUE`. The vendored ghostty snapshot API documents
that encoding can return this value when the VT parser or UTF-8 decoder is in
an unfinished state and continuation tracking was not enabled before the input
that produced that state. It can also occur when the continuation state exceeds
the configured tracking budget.

This is a serialization precondition failure. It does not mean that the PTY
child exited, that the session is not interactive, or that the visible screen
cannot be formatted for display. Warren's normal display snapshot uses the
formatter path; migration uses the stricter persistent-state encoder.

## Investigation Evidence

### The failure class is reproducible

Using the same `libghostty-vt.dylib` binary loaded by the old server:

- An unterminated OSC sequence larger than the 1 MiB continuation budget
  returns `ghostty snapshot encode failed: -2`.
- Encoding a snapshot with an unfinished continuation succeeds in the source
  terminal, but restoring that snapshot and immediately encoding the restored
  terminal returns `-2` because restore disables continuation tracking until it
  is re-enabled for future input.
- Ordinary mid-OSC input below the budget, a partial UTF-8 sequence, and a
  terminal in the middle of a synchronized update all encoded successfully.

Therefore, a normal-looking screen can coexist with an unencodable transient
parser state.

### The retained spool does not reproduce the historical failure

The affected session's retained output consists of three gzip archives followed
by the current live spool. Replaying them in chronological order produced about
31 MB of PTY bytes.

- Full replay: `EncodeState` succeeded.
- 4 KiB incremental scan across the complete replay: zero failures.
- Byte-by-byte scan over the final 200 KiB, covering the upgrade failure period
  and subsequent output: zero failures.
- The live session still returns a normal display checkpoint and remains alive.

This proves that the exact state present in the old server at the time of the
failure cannot be reconstructed from the currently retained spool bytes. It
does not disprove a transient parser state in the live emulator.

### Spool compaction is a leading investigation target

Warren currently handles output compaction in two separate calls in
`Headless/internal/server/service.go`:

```go
_ = adapter.ArchiveSpool(ctx, session.Runtime)
_ = adapter.TruncateSpool(ctx, session.Runtime)
```

Ghostline feeds PTY bytes into the emulator and spool under `outputMu`, while
the host's archive and truncate operations are separate runtime calls. Archive
errors are ignored, and there is no single transaction covering archive,
truncation, and the persisted watcher offset. This can create a gap between
what the emulator has consumed and what remains available for later replay.

This is a plausible explanation for why the live emulator could have a state
that the retained spool cannot reproduce, but it is not yet proven to be the
specific trigger for the 11:30 failure. The exact parser state and the bytes
around the failure were not captured at the time.

## Confirmed vs. Unconfirmed

### Confirmed

- The running detached server is ghostline protocol `0.4.0`.
- The new Warren daemon expects ghostline protocol `0.5.0`.
- Rolling upgrade is attempted automatically on protocol mismatch.
- The upgrade fails while encoding the migration snapshot for the session
  listed above.
- The error is `GHOSTTY_INVALID_VALUE` from `ghostty_snapshot_encode_alloc`.
- The old server is intentionally retained after the failed migration.
- The session is healthy from the user's point of view and can still produce a
  normal display snapshot.

### Unconfirmed

- The exact unfinished VT/UTF-8 sequence or continuation state at 11:30.
- Whether spool compaction caused the emulator/spool evidence gap.
- Whether the state came from a large continuation, a restored snapshot, or a
  different libghostty-vt parser edge case.

## Impact

- Existing sessions remain on ghostline `v0.4.0` after every failed upgrade
  attempt.
- New sessions created after the daemon starts may still be served through the
  existing old server, so the process can remain on the older protocol longer
  than expected.
- No evidence of PTY termination or user-visible session data loss was found.
- Repeated daemon starts retry the upgrade and emit the same failure until the
  offending session ends or the migration path is fixed.

## Proposed Fix Work

The following work is intentionally recorded for a later repair; it was not
performed as part of this investigation:

1. Add structured diagnostics around `EncodeState` failures, including whether
   the terminal has tracked continuation data and the configured continuation
   limit.
2. Make spool archive/truncate and watcher re-anchoring atomic from the host's
   point of view, or refuse to truncate when archiving fails.
3. Add tests for large unterminated OSC input, restored unfinished parser state,
   archive/truncate races, and a rolling upgrade with one unencodable session.
4. Preserve the current migration failure contract: do not retire the old
   server unless every session has been prepared and committed.
5. After the fix, retry this upgrade with the affected session still alive and
   verify that the stable socket reports `0.5.0` without ending the PTY child.

## Acceptance Criteria

- The affected session can be migrated while remaining interactive.
- The stable ghostline socket reports `0.5.0` after a successful daemon restart.
- No PTY output is lost across archive, migration, or re-anchoring boundaries.
- A deliberately unencodable session causes a clear, structured diagnostic and
  leaves the old server serving all sessions.
- The failure and fallback behavior are covered by automated tests.
