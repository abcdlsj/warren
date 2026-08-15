#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"
install_path="/Applications/Warren.app"
executable_path="$app_path/Contents/MacOS/Warren"
installed_executable_path="$install_path/Contents/MacOS/Warren"
menubar_executable_path="$app_path/Contents/MacOS/WarrenDaemonMenuBar"
installed_menubar_executable_path="$install_path/Contents/MacOS/WarrenDaemonMenuBar"
daemon_executable_path="$app_path/Contents/MacOS/warren-headless"
installed_daemon_executable_path="$install_path/Contents/MacOS/warren-headless"

is_running() {
    pgrep -f "$executable_path$" >/dev/null 2>&1 \
        || pgrep -f "$installed_executable_path$" >/dev/null 2>&1
}

is_menubar_running() {
    pgrep -f "$menubar_executable_path$" >/dev/null 2>&1 \
        || pgrep -f "$installed_menubar_executable_path$" >/dev/null 2>&1
}

is_daemon_running() {
    pgrep -f "$daemon_executable_path$" >/dev/null 2>&1 \
        || pgrep -f "$installed_daemon_executable_path$" >/dev/null 2>&1
}

notify_maintenance() {
    local token_file="$HOME/.warren/token"
    [[ -r "$token_file" ]] || return 0
    local token
    token="$(tr -d '[:space:]' < "$token_file")"
    [[ -n "$token" ]] || return 0
    curl -fsS -m 2 -X POST "http://127.0.0.1:8789/v1/maintenance" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"message":"Installing a new Warren build; the daemon will restart."}' \
        >/dev/null 2>&1 || true
}

force_terminate() {
    local pattern="$1"
    pkill -TERM -f "$pattern$" >/dev/null 2>&1 || true
    for _ in {1..30}; do
        pgrep -f "$pattern$" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    pkill -KILL -f "$pattern$" >/dev/null 2>&1 || true
    for _ in {1..30}; do
        pgrep -f "$pattern$" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    return 1
}

echo "Building Warren.app (release)..."
bash "$repository_root/scripts/build-app.sh" release

# Tell connected Desktop/Web clients the daemon is about to restart so they
# show an update state instead of a misleading connection error. Best-effort:
# old daemons without the endpoint simply restart without the notice.
notify_maintenance

relaunch_after_install=false
if is_running; then
    relaunch_after_install=true
    osascript -e 'tell application id "com.abcdlsj.warren" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
        is_running || break
        sleep 0.1
    done
fi

if is_running; then
    force_terminate "$executable_path" || true
    force_terminate "$installed_executable_path" || true
fi

if is_menubar_running; then
    force_terminate "$menubar_executable_path" || true
    force_terminate "$installed_menubar_executable_path" || true
fi

# The daemon is deliberately independent during normal Desktop shutdown, but
# an app update must replace its executable too. tmux sessions survive SIGTERM
# and the new menu-bar process will start the freshly installed daemon.
if is_daemon_running; then
    force_terminate "$daemon_executable_path" || true
    force_terminate "$installed_daemon_executable_path" || true
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
if [[ "$relaunch_after_install" == true ]]; then
    open "$install_path"
    echo "Relaunched $install_path"
fi
