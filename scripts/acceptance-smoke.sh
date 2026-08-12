#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 1/3 full unit + integration verification"
bash "$repository_root/scripts/verify.sh"

echo "==> 2/5 real app web relay (auth / roster / attach / input / echo)"
bash "$repository_root/scripts/verify-web.sh"

echo "==> 3/5 every visible control is clickable and reaches its action"
bash "$repository_root/scripts/click-probe.sh"

echo "==> 4/5 headless UI observation"
bash "$repository_root/scripts/observe-ui.sh"

echo "==> 5/5 Ghostty keyboard input reaches the host"
bash "$repository_root/scripts/input-probe.sh"

echo "Acceptance smoke passed."
