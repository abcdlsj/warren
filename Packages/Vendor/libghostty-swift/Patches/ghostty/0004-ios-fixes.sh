#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# Every step below used to detect "already applied" by grepping for the *old*
# anchor, so an upstream rename read as success and the step quietly did
# nothing. Each step now decides between three outcomes explicitly:
#
#   - the patched form is already present  -> skip, say so
#   - the anchor is present exactly once   -> transform
#   - anything else                        -> hard failure
#
# and nothing is written to disk until all four steps have succeeded.

python3 - "$SOURCE_DIR" <<'PYEOF'
import re
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])

# Staged writes. Nothing reaches disk until every transformation has succeeded,
# so a late failure can never leave a half-patched tree behind.
pending = []
messages = []


def stage(path, text, label):
    pending.append((path, text, label))


def load(rel_path):
    """Read a file that must exist. A missing file is an error, never a skip."""
    path = source_dir / rel_path
    if not path.is_file():
        print(f"[-] missing file: {rel_path}")
        sys.exit(1)
    return path, path.read_text()


def require(condition, message):
    """Explicit check. Never use `assert` — `python -O` strips it."""
    if not condition:
        print(f"[-] {message}")
        sys.exit(1)


def replace_exact(text, old, new, what, expected=1):
    found = text.count(old)
    if found != expected:
        print(f"[-] {what}: expected {expected} match(es), found {found}")
        print(f"    {old[:80]}...")
        sys.exit(1)
    return text.replace(old, new, expected)


# ──────────────────────────────────────────────────────────────────────
# 1. cf_release_thread — ignore loop.run errors on iOS
#    The kqueue-based event loop panics on the iOS simulator (mach ports).
# ──────────────────────────────────────────────────────────────────────
cf_path, cf = load("src/os/cf_release_thread.zig")
cf_old = "    try self.loop.run(.until_done);"
cf_new = (
    '    self.loop.run(.until_done) catch |err| '
    '{ log.warn("cf release loop failed err={}", .{err}); return; };'
)
if cf_new in cf:
    messages.append("[+] cf_release_thread already patched")
else:
    # There is a second, already-guarded `self.loop.run(.until_done)` in the
    # abnormal-exit drain path; only the bare `try` form is ours.
    cf = replace_exact(cf, cf_old, cf_new, "cf_release_thread loop.run")
    stage(cf_path, cf, "src/os/cf_release_thread.zig")
    messages.append("[+] patched cf_release_thread to ignore loop errors")

# ──────────────────────────────────────────────────────────────────────
# 2. Disable private window blur API (App Store compliance)
# ──────────────────────────────────────────────────────────────────────
embedded_path, embedded = load("src/apprt/embedded.zig")
blur_old = """    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;"""

blur_new = """    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        _ = app;
        _ = window;
        return;
    }"""

if "CGSSetWindowBackgroundBlurRadius" not in embedded:
    messages.append("[+] blur patch already applied")
else:
    # Reaching here means the private symbol is still referenced, so a missing
    # anchor is upstream drift — not an already-applied tree.
    embedded = replace_exact(
        embedded, blur_old, blur_new, "embedded.zig background blur function"
    )
    require(
        "CGSSetWindowBackgroundBlurRadius" not in embedded,
        "postcondition: private blur symbol still referenced in embedded.zig",
    )
    stage(embedded_path, embedded, "src/apprt/embedded.zig")
    messages.append("[+] patched: disabled private blur API")

# ──────────────────────────────────────────────────────────────────────
# 3. Metal framework linkage for pkg/macos
#
#    This step targeted `lib.linkFramework("IOSurface");` /
#    `module.linkFramework("IOSurface", .{});`. Upstream has since replaced
#    both with a table-driven `frameworks` array, so those anchors no longer
#    exist and this step has been a silent no-op that still printed success.
#    Recognize the current shape explicitly and fail if we recognize neither.
# ──────────────────────────────────────────────────────────────────────
macos_build_path, macos_build = load("pkg/macos/build.zig")
lib_anchor = '    lib.linkFramework("IOSurface");'
module_anchor = '        module.linkFramework("IOSurface", .{});'
table_anchor = (
    '    .{ .tag = .all, .name = "IOSurface", .headers = &.{"IOSurfaceRef.h"} },'
)

if 'lib.linkFramework("Metal")' in macos_build:
    messages.append("[+] Metal frameworks already linked")
elif lib_anchor in macos_build or module_anchor in macos_build:
    macos_build = replace_exact(
        macos_build,
        lib_anchor,
        lib_anchor
        + '\n    lib.linkFramework("Metal");'
        + '\n    lib.linkFramework("MetalKit");',
        "pkg/macos/build.zig lib.linkFramework",
    )
    macos_build = replace_exact(
        macos_build,
        module_anchor,
        module_anchor
        + '\n        module.linkFramework("Metal", .{});'
        + '\n        module.linkFramework("MetalKit", .{});',
        "pkg/macos/build.zig module.linkFramework",
    )
    stage(macos_build_path, macos_build, "pkg/macos/build.zig")
    messages.append("[+] patched: linked Metal frameworks")
elif table_anchor in macos_build:
    messages.append(
        "[+] Metal framework linkage not applicable: pkg/macos/build.zig is "
        "table-driven upstream"
    )
else:
    print(
        "[-] pkg/macos/build.zig: neither the per-call linkFramework anchors "
        "nor the upstream frameworks table were found"
    )
    sys.exit(1)

# ──────────────────────────────────────────────────────────────────────
# 4. Lower the iOS deployment target to 15.0
# ──────────────────────────────────────────────────────────────────────
config_path, config = load("src/build/Config.zig")
ios_semver = re.compile(
    r"\.ios => \.\{ \.semver = \.\{\n"
    r"\s*\.major = \d+,\n"
    r"\s*\.minor = \d+,\n"
    r"\s*\.patch = \d+,"
)
ios_target = (
    ".ios => .{ .semver = .{\n"
    "            .major = 15,\n"
    "            .minor = 0,\n"
    "            .patch = 0,"
)
ios_matches = ios_semver.findall(config)
require(
    len(ios_matches) == 1,
    f"Config.zig iOS semver block: expected 1 match, found {len(ios_matches)}",
)
if ios_matches[0] == ios_target:
    messages.append("[+] iOS deployment target already patched")
else:
    config = ios_semver.sub(lambda _: ios_target, config, count=1)
    require(
        ios_target in config,
        "postcondition: iOS deployment target not lowered in Config.zig",
    )
    stage(config_path, config, "src/build/Config.zig")
    messages.append("[+] patched: iOS deployment target -> 15.0")

# All transformations succeeded — commit them.
for path, body, _ in pending:
    path.write_text(body)

for message in messages:
    print(message)
PYEOF

echo "[+] all ios-fixes patches applied"
