#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> swift build"
swift build --package-path "$repository_root"

for package in Domain StateStore Host Application Desktop GhosttyAdapter WebRelay; do
    echo "==> swift test $package"
    swift test --package-path "$repository_root/Packages/$package"
done

echo "==> tmux integration test"
swift test --package-path "$repository_root" --filter ApplicationIntegrationTests

echo "==> build app"
bash "$repository_root/scripts/build-app.sh" debug

echo "==> verify bundled web page"
test -f "$repository_root/Burrow.app/Contents/Resources/web.html"

echo "All checks passed."
