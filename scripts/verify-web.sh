#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

bash "$repository_root/scripts/build-app.sh" debug
pkill -f '/Burrow.app/Contents/MacOS/Burrow' || true
sleep 1
open "$repository_root/Burrow.app"
sleep 6

cleanup() {
    pkill -f '/Burrow.app/Contents/MacOS/Burrow' || true
}
trap cleanup EXIT

for attempt in 1 2 3; do
    if python3 "$repository_root/scripts/verify-web.py"; then
        exit 0
    fi
    echo "web verify attempt $attempt failed, retrying…"
    sleep 2
done
exit 1
