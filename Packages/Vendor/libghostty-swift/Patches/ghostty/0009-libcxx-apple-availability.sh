#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# Zig's bundled libc++ headers ship with Apple vendor availability annotations
# disabled, so C++ code references runtime symbols that the Apple system
# libc++.1.dylib may not export at our deployment floors (e.g.
# std::__1::__libcpp_verbose_abort, exported only since iOS 16.3 /
# macOS 13.3 / tvOS 16.3). Forcing the annotations on makes libc++ headers
# degrade gracefully below those floors (exactly like Apple SDK clang) and
# turns any hard dependency on a too-new symbol into a compile error instead
# of a dyld crash at app launch.
#
# -Wno-macro-redefined: zig predefines the macro to 0 on its own command
# line; our -D override redefines it.
#
# All three insertions used to be blind perl/python substitutions on an anchor
# that appears more than once per file; the flag grep afterwards only proved
# *something* was inserted, not that it landed in the right list. Each anchor
# below is now matched exactly once, and nothing is written until all three
# succeed.

python3 - "$SOURCE_DIR" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])

FLAG = "_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS"

# Staged writes. Nothing reaches disk until every transformation has succeeded,
# so a late failure can never leave a partially patched tree that the next run
# reads as "already applied".
pending = []
messages = []


def stage(path, text, label):
    pending.append((path, text, label))


def load(rel_path):
    """Read a file that must exist. A missing file is an error, never a skip."""
    path = source_dir / rel_path
    if not path.is_file():
        print(f"[-] missing: {path}; upstream changed, update this patch")
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
# 1. highway flags (hwy/abort.cc et al reference __libcpp_verbose_abort
#    through the -fno-exceptions throw helpers)
# ──────────────────────────────────────────────────────────────────────
highway_path, highway = load("pkg/highway/build.zig")
if FLAG in highway:
    messages.append("[+] highway libc++ availability already patched")
else:
    # `try flags.appendSlice(b.allocator, &.{` alone occurs three times in this
    # file; the following comment pins it to the top-level flag list.
    highway = replace_exact(
        highway,
        '    try flags.appendSlice(b.allocator, &.{\n'
        '        // Highway can avoid libc++ entirely as long as all users compile\n',
        '    try flags.appendSlice(b.allocator, &.{\n'
        '        "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",\n'
        '        "-Wno-macro-redefined",\n'
        '        // Highway can avoid libc++ entirely as long as all users compile\n',
        "highway flags block",
    )
    stage(highway_path, highway, "pkg/highway/build.zig")
    messages.append("[+] patched: highway libc++ availability annotations")

# ──────────────────────────────────────────────────────────────────────
# 2. simdutf flags
# ──────────────────────────────────────────────────────────────────────
simdutf_path, simdutf = load("pkg/simdutf/build.zig")
if FLAG in simdutf:
    messages.append("[+] simdutf libc++ availability already patched")
else:
    simdutf = replace_exact(
        simdutf,
        '    try flags.appendSlice(b.allocator, &.{\n'
        '        "-fno-sanitize=undefined",\n',
        '    try flags.appendSlice(b.allocator, &.{\n'
        '        "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",\n'
        '        "-Wno-macro-redefined",\n'
        '        "-fno-sanitize=undefined",\n',
        "simdutf flags block",
    )
    stage(simdutf_path, simdutf, "pkg/simdutf/build.zig")
    messages.append("[+] patched: simdutf libc++ availability annotations")

# ──────────────────────────────────────────────────────────────────────
# 3. ghostty's own C++ SIMD sources (src/simd/*.cpp)
#
#    Upstream (ghostty 2da015c+) builds the src/simd C++ flags into a runtime
#    `flags` ArrayList instead of a static per-arch array literal, so we inject
#    our two flags right after that list is initialized — this covers every
#    architecture, matching the old both-branches patch.
# ──────────────────────────────────────────────────────────────────────
shared_path, shared = load("src/build/SharedDeps.zig")
if FLAG in shared:
    messages.append("[+] src/simd libc++ availability already patched")
else:
    anchor = "        var flags: std.ArrayListUnmanaged([]const u8) = .empty;\n"
    inject = (
        "        // libghostty-spm: honor Apple libc++ vendor availability annotations\n"
        "        // so the C++ SIMD sources degrade gracefully below our deployment\n"
        "        // floors instead of dyld-crashing on a too-new symbol.\n"
        '        try flags.appendSlice(b.allocator, &.{\n'
        '            "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",\n'
        '            "-Wno-macro-redefined",\n'
        "        });\n"
    )
    shared = replace_exact(
        shared, anchor, anchor + inject, "src/simd flags anchor"
    )
    stage(shared_path, shared, "src/build/SharedDeps.zig")
    messages.append("[+] patched: src/simd libc++ availability annotations")

# Postconditions before anything is written.
for _, body, label in pending:
    require(FLAG in body, f"postcondition: {FLAG} missing from {label}")

# All transformations succeeded — commit them.
for path, body, _ in pending:
    path.write_text(body)

for message in messages:
    print(message)
PYEOF

echo "[+] all libcxx-apple-availability patches applied"
