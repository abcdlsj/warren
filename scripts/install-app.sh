#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"
install_path="/Applications/Warren.app"
executable_path="$app_path/Contents/MacOS/Warren"

is_running() {
    pgrep -f "$executable_path$" >/dev/null 2>&1
}

echo "Building Warren.app (release)..."
bash "$repository_root/scripts/build-app.sh" release

if is_running; then
    osascript -e 'tell application id "com.abcdlsj.warren" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
        is_running || break
        sleep 0.1
    done
fi

if is_running; then
    echo "Warren did not terminate before installation." >&2
    exit 1
fi

echo "Installing to $install_path..."
rm -rf "$install_path"
ditto "$app_path" "$install_path"
echo "Installed $install_path"
