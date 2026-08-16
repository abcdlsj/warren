#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

MARKER="LIBGHOSTTY_SPM_TRIM_PATCH"

# Skip if already applied
if grep -q "$MARKER" "$SOURCE_DIR/src/build/Config.zig" 2>/dev/null; then
    echo "[+] trim patch already applied"
    exit 0
fi

python3 - "$SOURCE_DIR" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])
marker = sys.argv[2]


class PatchError(Exception):
    pass


def load(rel):
    """Read a file that must exist. A missing file is a hard error, never a skip."""
    path = source_dir / rel
    if not path.is_file():
        raise PatchError(f"missing file: {rel}")
    return path, path.read_text()


def replace_exact(text, old, new, what, expected=1):
    """Replace with an exact match count.

    Both zero matches (upstream renamed the anchor) and more matches than
    expected (upstream grew a second call site) are errors. A silent no-op
    here previously emitted syntactically invalid Zig with a zero exit code,
    which CI then tried to compile.
    """
    found = text.count(old)
    if found != expected:
        raise PatchError(
            f"{what}: expected {expected} match(es), found {found}"
        )
    return text.replace(old, new)


# Every transformation runs against in-memory copies first. Nothing is written
# until all of them succeed, so a later failure can never leave a half-patched
# tree behind the already-installed marker.
config_path, config = load("src/build/Config.zig")
shared_path, shared = load("src/build/SharedDeps.zig")
bc_path, bc = load("src/build_config.zig")
global_path, glob = load("src/global.zig")
shader_path, shader = load("src/renderer/shadertoy.zig")

# ──────────────────────────────────────────────────────────────────────
# 1. Config.zig — add custom_shaders feature flag
# ──────────────────────────────────────────────────────────────────────
config = replace_exact(
    config,
    "sentry: bool = true,",
    f"sentry: bool = true,\ncustom_shaders: bool = true, // {marker}",
    "Config.zig sentry field",
)

sentry_end = """    ) orelse sentry: {
        switch (target.result.os.tag) {
            .macos, .ios => break :sentry true,

            // Note its false for linux because the crash reports on Linux
            // don't have much useful information.
            else => break :sentry false,
        }
    };"""

new_options = sentry_end + """

    config.custom_shaders = b.option(
        bool,
        "custom-shaders",
        "Build with custom shader (glslang/spirv-cross) support.",
    ) orelse true;"""

config = replace_exact(config, sentry_end, new_options, "Config.zig sentry option block")

config = replace_exact(
    config,
    'step.addOption(bool, "sentry", self.sentry);',
    'step.addOption(bool, "sentry", self.sentry);\n'
    '    step.addOption(bool, "custom_shaders", self.custom_shaders);',
    "Config.zig addOptions",
)

# ──────────────────────────────────────────────────────────────────────
# 2. SharedDeps.zig — gate glslang + spirv-cross on custom_shaders
# ──────────────────────────────────────────────────────────────────────
shared = replace_exact(
    shared,
    '    // Glslang\n    if (b.lazyDependency("glslang", .{',
    '    // Glslang — only needed for custom shaders\n    if (self.config.custom_shaders) if (b.lazyDependency("glslang", .{',
    "SharedDeps.zig glslang open",
)

# `if (cond) if (...) |x| {...}` is a statement and needs the trailing
# semicolon; without it the file no longer parses.
shared = replace_exact(
    shared,
    """            step.root_module.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                b.allocator,
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    }

    // Spirv-cross""",
    """            step.root_module.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                b.allocator,
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    };

    // Spirv-cross""",
    "SharedDeps.zig glslang close",
)

shared = replace_exact(
    shared,
    '    // Spirv-cross\n    if (b.lazyDependency("spirv_cross", .{',
    '    // Spirv-cross — only needed for custom shaders\n    if (self.config.custom_shaders) if (b.lazyDependency("spirv_cross", .{',
    "SharedDeps.zig spirv-cross open",
)

shared = replace_exact(
    shared,
    """            step.root_module.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                b.allocator,
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    }

    // Sentry""",
    """            step.root_module.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                b.allocator,
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    };

    // Sentry""",
    "SharedDeps.zig spirv-cross close",
)

# ──────────────────────────────────────────────────────────────────────
# 3. build_config.zig — re-export custom_shaders flag
# ──────────────────────────────────────────────────────────────────────
bc = replace_exact(
    bc,
    'const options = @import("build_options");',
    'const options = @import("build_options");\npub const custom_shaders = options.custom_shaders;',
    "build_config.zig options import",
)

# ──────────────────────────────────────────────────────────────────────
# 4. global.zig — conditional glslang init
#    (global.zig already imports build_config)
# ──────────────────────────────────────────────────────────────────────
glob = replace_exact(
    glob,
    'const glslang = @import("glslang");',
    'const glslang = if (build_config.custom_shaders) @import("glslang") else struct {\n'
    '    pub fn init() !void {}\n'
    '};',
    "global.zig glslang import",
)

# ──────────────────────────────────────────────────────────────────────
# 5. renderer/shadertoy.zig — gate shader imports and loadFromFile
#    When custom_shaders is disabled, loadFromFile is unreachable
#    so glslang/spirv_cross are never semantically analyzed
# ──────────────────────────────────────────────────────────────────────
shader = replace_exact(
    shader,
    'const glslang = @import("glslang");',
    'const build_config = @import("../build_config.zig");\n'
    'const glslang = @import("glslang");',
    "shadertoy.zig glslang import",
)

shader = replace_exact(
    shader,
    """pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;""",
    """pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const [:0]const u8 {
    if (comptime !build_config.custom_shaders) return &.{};
    var list: std.ArrayList([:0]const u8) = .empty;""",
    "shadertoy.zig loadFromFiles guard",
)

# Postconditions: the marker must be installed and every gate present.
if marker not in config:
    raise PatchError("postcondition: marker missing from Config.zig")
for name, body, needle in (
    ("SharedDeps.zig", shared, "if (self.config.custom_shaders) if (b.lazyDependency(\"glslang\""),
    ("build_config.zig", bc, "pub const custom_shaders"),
    ("global.zig", glob, "if (build_config.custom_shaders)"),
    ("shadertoy.zig", shader, "if (comptime !build_config.custom_shaders)"),
):
    if needle not in body:
        raise PatchError(f"postcondition failed in {name}")

# All transformations succeeded — commit them.
for path, body, label in (
    (config_path, config, "Config.zig"),
    (shared_path, shared, "SharedDeps.zig"),
    (bc_path, bc, "build_config.zig"),
    (global_path, glob, "global.zig"),
    (shader_path, shader, "renderer/shadertoy.zig"),
):
    path.write_text(body)
    print(f"[+] patched {label}")

print(f"[+] all trim patches complete ({marker})")
PYEOF

echo "[+] trim patch applied"
