#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

if version="$(git -C "$repository_root" describe --tags --exact-match 2>/dev/null)"; then
    printf '%s\n' "$version"
elif hash="$(git -C "$repository_root" rev-parse --short HEAD 2>/dev/null)"; then
    printf '%s\n' "$hash"
else
    printf '%s\n' "dev"
fi
