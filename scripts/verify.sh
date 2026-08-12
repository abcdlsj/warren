#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> swift build"
swift build --package-path "$repository_root"

for package in Domain StateStore Host Application Desktop GhosttyAdapter Observation; do
    echo "==> swift test $package"
    swift test --package-path "$repository_root/Packages/$package"
done

echo "==> tmux integration test"
swift test --package-path "$repository_root" --filter ApplicationIntegrationTests

echo "==> process lifecycle contracts"
BURROW_APP_EXECUTABLE="$repository_root/.build/debug/BurrowNext" \
    swift test --package-path "$repository_root" --filter BurrowProcessTests

echo "==> non-visual semantic UI acceptance"
BURROW_ARTIFACT_DIR="${BURROW_ARTIFACT_DIR:-/tmp/burrow-observation/ui-probe}" \
    swift run --package-path "$repository_root" UIProbe

echo "==> headless terminal color semantics"
BURROW_ARTIFACT_DIR="${BURROW_TERMINAL_ARTIFACT_DIR:-/tmp/burrow-observation/terminal-probe}" \
    swift run --package-path "$repository_root" TerminalProbe

echo "==> build app"
bash "$repository_root/scripts/build-app.sh" debug

echo "All checks passed."
