#!/usr/bin/env bash

set -euo pipefail

configuration="${1:-debug}"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"
executable_path="$app_path/Contents/MacOS/Warren"

is_running() {
    pgrep -f "$executable_path$" >/dev/null
}

bash "$repository_root/scripts/build-app.sh" "$configuration"

if is_running; then
    osascript -e 'tell application id "com.abcdlsj.warren" to quit' >/dev/null 2>&1 || true

    for _ in {1..50}; do
        is_running || break
        sleep 0.1
    done

    if is_running; then
        pkill -TERM -f "$executable_path$"
        for _ in {1..20}; do
            is_running || break
            sleep 0.1
        done
    fi

    if is_running; then
        echo "Warren did not terminate cleanly." >&2
        exit 1
    fi
fi

open "$app_path"
