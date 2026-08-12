#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

swift run --package-path "$repository_root" UIProbe

echo
echo "Read the non-visual semantic report with:"
echo "  cat /tmp/burrow-observation/ui-probe/result.json"
echo "  cat /tmp/burrow-observation/ui-probe/semantic-ui.json"
