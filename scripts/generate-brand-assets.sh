#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
brand_root="$repository_root/Assets/Brand"
web_public_root="$repository_root/Web/public"
iconset_root="$brand_root/Warren.iconset"
master_svg="$brand_root/warren-app-icon.svg"
compact_svg="$brand_root/warren-app-icon-32.svg"
micro_svg="$brand_root/warren-app-icon-16.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert is required to generate Warren brand assets" >&2
    exit 1
fi

render() {
    local source="$1"
    local size="$2"
    local destination="$3"
    rsvg-convert --width "$size" --height "$size" --output "$destination" "$source"
}

mkdir -p "$iconset_root" "$web_public_root"

render "$master_svg" 1024 "$brand_root/warren-app-icon.png"

# macOS uses optical-size sources rather than shrinking the detailed master
# through the two sizes where its 32 px construction grid lands on half pixels.
render "$micro_svg" 16 "$iconset_root/icon_16x16.png"
render "$compact_svg" 32 "$iconset_root/icon_16x16@2x.png"
render "$compact_svg" 32 "$iconset_root/icon_32x32.png"
render "$master_svg" 64 "$iconset_root/icon_32x32@2x.png"
render "$master_svg" 128 "$iconset_root/icon_128x128.png"
render "$master_svg" 256 "$iconset_root/icon_128x128@2x.png"
render "$master_svg" 256 "$iconset_root/icon_256x256.png"
render "$master_svg" 512 "$iconset_root/icon_256x256@2x.png"
render "$master_svg" 512 "$iconset_root/icon_512x512.png"
render "$master_svg" 1024 "$iconset_root/icon_512x512@2x.png"

if command -v iconutil >/dev/null 2>&1; then
    iconutil --convert icns --output "$brand_root/Warren.icns" "$iconset_root"
else
    echo "warning: iconutil not found; skipped Warren.icns" >&2
fi

cp "$master_svg" "$web_public_root/icon.svg"
render "$micro_svg" 16 "$web_public_root/favicon-16.png"
render "$compact_svg" 32 "$web_public_root/favicon-32.png"
render "$master_svg" 180 "$web_public_root/apple-touch-icon.png"
render "$master_svg" 192 "$web_public_root/icon-192.png"
render "$master_svg" 512 "$web_public_root/icon-512.png"
