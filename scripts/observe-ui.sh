#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

swift run --package-path "$repository_root" UIProbe

echo
echo "Open the report with:"
echo "  cat /tmp/burrow-ui-report/report.json"
echo "  open /tmp/burrow-ui-report"
