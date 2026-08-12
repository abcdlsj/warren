#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 1/2 full local unit + integration verification"
bash "$repository_root/scripts/verify.sh"

echo "==> 2/2 non-visual UI semantics and typed actions"
bash "$repository_root/scripts/observe-ui.sh"

echo "Acceptance smoke passed."
