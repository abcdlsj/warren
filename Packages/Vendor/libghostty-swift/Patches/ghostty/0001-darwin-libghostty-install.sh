#!/bin/zsh

set -euo pipefail

SOURCE_DIR=${1:-}

if [ -z "$SOURCE_DIR" ]; then
    echo "[-] missing source_dir"
    exit 1
fi

BUILD_ZIG="$SOURCE_DIR/build.zig"
MARKER="libghostty static install for Darwin"

if [ ! -f "$BUILD_ZIG" ]; then
    echo "[-] build.zig not found: $BUILD_ZIG"
    exit 1
fi

if grep -Fq "$MARKER" "$BUILD_ZIG"; then
    echo "[+] patch already applied: 0001-darwin-libghostty-install"
    exit 0
fi

# The block was previously replaced with a `sed` address range, which matches
# by line pattern and cannot tell "upstream renamed the anchor" from "matched
# something else". Matching the whole block exactly, once, makes drift loud.
python3 - "$BUILD_ZIG" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

build_zig = Path(sys.argv[1])
marker = sys.argv[2]

# Staged write. Nothing reaches disk until every transformation succeeds.
pending = []


def stage(path, text, label):
    pending.append((path, text, label))


def load(path):
    """Read a file that must exist. A missing file is an error, never a skip."""
    if not path.is_file():
        print(f"[-] missing file: {path}")
        sys.exit(1)
    return path.read_text()


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


text = load(build_zig)

old_guard = """        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("ghostty-internal.dll");
                lib_static.install("ghostty-internal-static.lib");
            } else {
                lib_shared.install("ghostty-internal.so");
                lib_static.install("ghostty-internal.a");
            }
        }"""

new_guard = """        // libghostty static install for Darwin:
        // upstream only wires this for non-Darwin today, but we need the
        // static archive for our own XCFramework assembly pipeline.
        lib_shared.installHeader(); // Only need one header
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.install("libghostty.so");
        }
        lib_static.install("libghostty.a");"""

text = replace_exact(text, old_guard, new_guard, "build.zig non-Darwin install guard")

stage(build_zig, text, "build.zig")

# Postcondition before anything is written.
staged = {label: body for _, body, label in pending}
require(marker in staged["build.zig"], "postcondition: marker missing from build.zig")

for path, body, label in pending:
    path.write_text(body)
PYEOF

echo "[+] applied patch: 0001-darwin-libghostty-install"
