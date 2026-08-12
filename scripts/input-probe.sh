#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

swift build --package-path "$repository_root" --product InputProbe >/dev/null
BIN="$(swift build --package-path "$repository_root" --show-bin-path)"

"$BIN/InputProbe" > /tmp/inputprobe.log 2>&1
echo "InputProbe passed: Ghostty surface received typed bytes"
