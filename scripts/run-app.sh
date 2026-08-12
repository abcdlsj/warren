#!/usr/bin/env bash

set -euo pipefail

configuration="${1:-debug}"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Burrow.app"
executable_path="$app_path/Contents/MacOS/Burrow"

is_running() {
    pgrep -f "$executable_path$" >/dev/null
}

bash "$repository_root/scripts/build-app.sh" "$configuration"

if is_running; then
    # Transition: quit both the legacy Den bundle and the current Burrow bundle.
    osascript -e 'tell application id "com.abcdlsj.burrow" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application id "com.abcdlsj.den" to quit' >/dev/null 2>&1 || true

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
        echo "Burrow did not terminate cleanly." >&2
        exit 1
    fi
fi

open "$app_path"
