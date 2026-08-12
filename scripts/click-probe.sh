#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

swift build --package-path "$repository_root" --product ClickProbe >/dev/null
BIN="$(swift build --package-path "$repository_root" --show-bin-path)/ClickProbe"

failed=0
for scenario in workspace-chrome branch-detail empty-welcome; do
    if CLICKPROBE_ONLY="$scenario" "$BIN" \
        > "/tmp/clickprobe-$scenario.log" 2>&1; then
        echo "ClickProbe $scenario passed"
    else
        echo "ClickProbe $scenario FAILED (see /tmp/clickprobe-$scenario.log)"
        failed=1
    fi
done

exit "$failed"
