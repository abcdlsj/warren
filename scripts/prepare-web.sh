#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
web_root="$repository_root/Web"
stamp="$web_root/node_modules/.warren-lock.sha256"

if command -v shasum >/dev/null 2>&1; then
    lock_hash="$(shasum -a 256 "$web_root/package-lock.json" | awk '{print $1}')"
else
    lock_hash="$(sha256sum "$web_root/package-lock.json" | awk '{print $1}')"
fi

if [[ -x "$web_root/node_modules/.bin/vite" ]] && [[ -f "$stamp" ]]; then
    read -r installed_hash < "$stamp"
    if [[ "$installed_hash" == "$lock_hash" ]]; then
        exit 0
    fi
fi

npm --prefix "$web_root" ci
echo "$lock_hash" > "$stamp"
