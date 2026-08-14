#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"
install_path="/Applications/Warren.app"
executable_path="$app_path/Contents/MacOS/Warren"
menubar_executable_path="$app_path/Contents/MacOS/WarrenDaemonMenuBar"
daemon_executable_path="$app_path/Contents/MacOS/warren-headless"
installed_daemon_executable_path="$install_path/Contents/MacOS/warren-headless"

is_running() {
    pgrep -f "$executable_path$" >/dev/null 2>&1
}

is_menubar_running() {
    pgrep -f "$menubar_executable_path$" >/dev/null 2>&1
}

is_daemon_running() {
    pgrep -f "$daemon_executable_path$" >/dev/null 2>&1 \
        || pgrep -f "$installed_daemon_executable_path$" >/dev/null 2>&1
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

if is_menubar_running; then
    pkill -f "$menubar_executable_path$" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        is_menubar_running || break
        sleep 0.1
    done
fi

# The daemon is deliberately independent during normal Desktop shutdown, but
# an app update must replace its executable too. tmux sessions survive SIGTERM
# and the new menu-bar process will start the freshly installed daemon.
if is_daemon_running; then
    pkill -f "$daemon_executable_path$" >/dev/null 2>&1 || true
    pkill -f "$installed_daemon_executable_path$" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        is_daemon_running || break
        sleep 0.1
    done
fi

if is_running; then
    echo "Warren did not terminate before installation." >&2
    exit 1
fi

if is_menubar_running; then
    echo "Warren daemon menubar did not terminate before installation." >&2
    exit 1
fi

if is_daemon_running; then
    echo "Warren headless daemon did not terminate before installation." >&2
    exit 1
fi

echo "Installing to $install_path..."
rm -rf "$install_path"
ditto "$app_path" "$install_path"
cli_install_directory="$HOME/.local/bin"
mkdir -p "$cli_install_directory"
install -m 755 "$app_path/Contents/MacOS/warren-cli" "$cli_install_directory/warren"
install -m 755 "$app_path/Contents/MacOS/warren-headless" "$cli_install_directory/warren-headless"
echo "Installed $install_path"
echo "Installed CLI tools to $cli_install_directory"
