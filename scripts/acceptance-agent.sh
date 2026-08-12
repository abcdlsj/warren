#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> build app + cli"
bash "$repository_root/scripts/build-app.sh" debug >/dev/null
swift build --package-path "$repository_root" --product burrow >/dev/null
BIN="$(swift build --package-path "$repository_root" --show-bin-path)/burrow"

pkill -f '/Burrow.app/Contents/MacOS/Burrow' || true
sleep 1
open "$repository_root/Burrow.app"
sleep 8

cleanup() {
    pkill -f '/Burrow.app/Contents/MacOS/Burrow' || true
}
trap cleanup EXIT

round_one="codex-round-one-$(date +%s)"
round_two="codex-round-two-$(date +%s)"

echo "==> create codex session"
session_id="$("$BIN" agent create session "Acceptance Codex" \
    --command "codex exec \"Reply with exactly: $round_one\"" \
    --kind shell 2>/dev/null | tail -1)"
echo "session=$session_id"

echo "==> round 1: wait for codex reply"
"$BIN" session read "$session_id" --timeout 180 --contains "$round_one" >/tmp/acceptance-agent-r1.log

echo "==> round 2: send resume prompt"
"$BIN" session send "$session_id" \
    "codex exec resume --last \"Reply with exactly: $round_two\"" >/dev/null

echo "==> round 2: wait for codex reply"
"$BIN" session read "$session_id" --timeout 180 --contains "$round_two" >/tmp/acceptance-agent-r2.log

echo "Acceptance agent passed."
