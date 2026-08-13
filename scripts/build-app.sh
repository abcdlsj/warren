#!/usr/bin/env bash

set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --product WarrenNext

binary_directory="$(
    swift build \
        --package-path "$repository_root" \
        --configuration "$configuration" \
        --show-bin-path
)"
staging_path="$(mktemp -d "$repository_root/.build/Warren.app.staging.XXXXXX")"

cleanup() {
    rm -rf "$staging_path"
}
trap cleanup EXIT

mkdir -p "$staging_path/Contents/MacOS" "$staging_path/Contents/Resources"
install -m 755 "$binary_directory/WarrenNext" "$staging_path/Contents/MacOS/Warren"
install -m 644 "$repository_root/Support/Info.plist" "$staging_path/Contents/Info.plist"
install -m 644 "$repository_root/Assets/Brand/Warren.icns" "$staging_path/Contents/Resources/Warren.icns"
cp -R \
    "$binary_directory/WarrenDesktop_WarrenDesktop.bundle" \
    "$staging_path/Contents/Resources/WarrenDesktop_WarrenDesktop.bundle"
install -m 644 \
    "$repository_root/Packages/WebRelay/Sources/WebRelay/Resources/web.html" \
    "$staging_path/Contents/Resources/web.html"
for resource in manifest.webmanifest service-worker.js icon.svg icon-192.png icon-512.png apple-touch-icon.png \
    preset-shell.svg preset-claude.svg preset-codex.svg preset-codex-white.svg; do
    install -m 644 \
        "$repository_root/Packages/WebRelay/Sources/WebRelay/Resources/$resource" \
        "$staging_path/Contents/Resources/$resource"
done

codesign --force --sign - "$staging_path"
rm -rf "$app_path"
mv "$staging_path" "$app_path"
trap - EXIT

echo "Built $app_path"
