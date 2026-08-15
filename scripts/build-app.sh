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

if [[ "${WARREN_SKIP_WEB_BUILD:-0}" != "1" ]]; then
    bash "$repository_root/scripts/prepare-web.sh"
    npm --prefix "$repository_root/Web" run build
fi

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --product WarrenNext

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --product WarrenDaemonMenuBar

build_version="$(bash "$repository_root/scripts/version.sh")"
go build -ldflags "-X main.version=$build_version" -o "$repository_root/.build/warren-cli" "$repository_root/Headless/cmd/warren"
go build -ldflags "-X main.version=$build_version" -o "$repository_root/.build/warren-headless" "$repository_root/Headless/cmd/warren-headless"

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
install -m 755 "$binary_directory/WarrenDaemonMenuBar" "$staging_path/Contents/MacOS/WarrenDaemonMenuBar"
install -m 755 "$repository_root/.build/warren-cli" "$staging_path/Contents/MacOS/warren-cli"
install -m 755 "$repository_root/.build/warren-headless" "$staging_path/Contents/MacOS/warren-headless"
install -m 644 "$repository_root/Support/Info.plist" "$staging_path/Contents/Info.plist"
install -m 644 "$repository_root/Assets/Brand/Warren.icns" "$staging_path/Contents/Resources/Warren.icns"
cp -R \
    "$binary_directory/WarrenDesktop_WarrenDesktop.bundle" \
    "$staging_path/Contents/Resources/WarrenDesktop_WarrenDesktop.bundle"
cp -R "$repository_root/Web/dist/." "$staging_path/Contents/Resources/"

codesign --force --sign - "$staging_path"
rm -rf "$app_path"
mv "$staging_path" "$app_path"
trap - EXIT

echo "Built $app_path"
