#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# All five steps below used to run as independent per-file scripts: each one
# wrote its file the moment it finished, several of their `str.replace` calls
# had no match check at all, and a missing file was treated as "nothing to do".
# A failure in step 3 therefore left steps 1 and 2 committed, and the next run
# read those as already-applied. Everything is now one transaction: every
# anchor is matched an exact number of times, and nothing is written until all
# five steps have succeeded.

python3 - "$SOURCE_DIR" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])

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


# =============================================================================
# Patch 1: IOSurfaceLayer — iOS rendering compatibility
#
# Problem: On iOS, IOSurface dimensions may differ by ±1 pixel from the
# CALayer bounds due to rounding differences between UIKit point-to-pixel
# conversion and Metal's integer pixel sizes. The upstream code does an
# exact match and silently discards the surface, causing a blank screen.
#
# Additionally, iOS doesn't have a native CALayer subclass optimized for
# IOSurface content display. Using the private CAIOSurfaceLayer class
# (available since iOS 11) provides hardware-accelerated compositing.
#
# Fix:
# - Allow ±1px tolerance on iOS when comparing surface vs layer dimensions
# - Dynamically adjust contentsScale when dimensions don't match exactly
# - Use CAIOSurfaceLayer as base class on iOS for native IOSurface compositing
# - Mark layer as opaque since terminal content fills the entire bounds
# =============================================================================
layer_path, layer = load("src/renderer/metal/IOSurfaceLayer.zig")
if "CAIOSurfaceLayer" in layer:
    messages.append("[+] IOSurfaceLayer already patched")
else:
    # Need builtin for comptime os.tag checks
    layer = replace_exact(
        layer,
        'const std = @import("std");\nconst Allocator = std.mem.Allocator;',
        'const std = @import("std");\nconst builtin = @import("builtin");\n'
        'const Allocator = std.mem.Allocator;',
        "IOSurfaceLayer builtin import",
    )

    # The scoped log is only used in the size check we're replacing; drop it
    layer = replace_exact(
        layer,
        "\nconst log = std.log.scoped(.IOSurfaceLayer);\n",
        "\n",
        "IOSurfaceLayer scoped log",
    )

    # Terminal surface is always fully opaque — tell the compositor
    layer = replace_exact(
        layer,
        'layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);'
        "\n\n    layer.setInstanceVariable",
        'layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);'
        '\n    layer.setProperty("opaque", true);\n\n    layer.setInstanceVariable',
        "IOSurfaceLayer opaque property",
    )

    # Replace the strict size equality check with a platform-aware version.
    # On iOS, UIKit's point→pixel rounding can produce a 1px discrepancy.
    # Rather than dropping the frame entirely (→ blank screen), we accept it
    # and recalculate contentsScale so CoreAnimation stretches correctly.
    old_block = """    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }"""

    new_block = """    const sw = surface.getWidth();
    const sh = surface.getHeight();
    const dw: usize = if (width > sw) width - sw else sw - width;
    const dh: usize = if (height > sh) height - sh else sh - height;
    // iOS UIKit rounding can produce ±1px discrepancy; macOS must match exactly
    const max_drift: usize = if (comptime builtin.os.tag == .ios) 1 else 0;
    if (dw > max_drift or dh > max_drift) {
        if (comptime builtin.os.tag == .ios) {
            // Recalculate contentsScale so CA maps surface pixels to layer points
            const pw = bounds.size.width;
            const ph = bounds.size.height;
            if (pw > 0 and ph > 0) {
                const cs_x: f64 = @as(f64, @floatFromInt(sw)) / pw;
                const cs_y: f64 = @as(f64, @floatFromInt(sh)) / ph;
                const cs: f64 = @max(cs_x, cs_y);
                if (@abs(cs - scale) > 0.01) {
                    layer.setProperty("contentsScale", cs);
                }
            }
        } else {
            return;
        }
    }"""

    layer = replace_exact(
        layer, old_block, new_block, "IOSurfaceLayer size check block"
    )

    # Use the system-provided CAIOSurfaceLayer on iOS; it handles
    # IOSurface display natively with zero-copy compositing.
    old_cls = """    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;"""

    new_cls = """    const parent_cls = if (comptime builtin.os.tag == .ios)
        // CAIOSurfaceLayer provides native zero-copy IOSurface compositing
        objc.getClass("CAIOSurfaceLayer") orelse
            objc.getClass("CALayer") orelse return error.ObjCFailed
    else
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(parent_cls, "IOSurfaceLayer") orelse return error.ObjCFailed;"""

    layer = replace_exact(
        layer, old_cls, new_cls, "IOSurfaceLayer objc parent class"
    )

    # Dropping the scoped log declaration is only safe if nothing else used it.
    require(
        "log." not in layer,
        "postcondition: IOSurfaceLayer still references the removed scoped log",
    )

    stage(layer_path, layer, "src/renderer/metal/IOSurfaceLayer.zig")
    messages.append(
        "[+] patched IOSurfaceLayer: iOS size tolerance + CAIOSurfaceLayer"
    )

# =============================================================================
# Patch 2: Metal.zig — iOS first-frame display + synchronous present
#
# Problem 1: On iOS the IOSurfaceLayer is added as a sublayer of the UIView's
# backing layer. By the time the renderer registers its display callback the
# sublayer already has its bounds set, so no "display" message is generated.
# The first frame never renders.
#
# Problem 2: The async present path dispatches to the main thread via GCD.
# On iOS the render loop already runs on the main thread, so the async
# dispatch adds an unnecessary runloop turn of latency and can cause ordering
# issues with UIKit layout.
#
# Fix:
# - Call setNeedsDisplay after registering the display callback on iOS
# - On iOS, always use the synchronous present path (setSurface checks
#   isMainThread internally and runs inline when true)
# =============================================================================
metal_path, metal = load("src/renderer/Metal.zig")
if "setNeedsDisplay" in metal:
    messages.append("[+] Metal.zig already patched")
else:
    # Kick the first display cycle after callback registration on iOS
    old_cb = """        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}"""

    new_cb = """        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );

    // iOS: sublayer bounds are already set before the callback is wired up,
    // so no display message fires automatically. Kick the first frame.
    if (comptime builtin.os.tag == .ios) {
        self.layer.layer.msgSend(void, objc.sel("setNeedsDisplay"), .{});
    }
}"""

    metal = replace_exact(metal, old_cb, new_cb, "Metal.zig loopEnter callback")

    # iOS render loop is main-thread; skip the async dispatch path entirely.
    old_present = """pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}"""

    new_present = """pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    // iOS: always present synchronously — the render loop already runs on
    // the main thread, so the async GCD hop is unnecessary overhead.
    if (comptime builtin.os.tag == .ios) {
        try self.layer.setSurface(target.surface);
        return;
    }
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}"""

    metal = replace_exact(
        metal, old_present, new_present, "Metal.zig present function"
    )

    stage(metal_path, metal, "src/renderer/Metal.zig")
    messages.append("[+] patched Metal.zig: iOS first-frame trigger + sync present")

# =============================================================================
# Patch 3: coretext.zig — Skip CF release thread on iOS
#
# Problem: The CoreText font shaper spawns a background thread that uses
# libxev's kqueue event loop to asynchronously release CoreFoundation
# objects. On iOS, kqueue's Mach port allocation fails (sandbox restrictions
# + simulator incompatibility), crashing the thread and potentially stalling
# font shaping operations.
#
# Fix: Make the CF release thread optional. On iOS, skip thread creation
# entirely and release CF objects synchronously in endFrame(). This is
# acceptable because iOS devices have fast enough CF release performance
# and the terminal doesn't produce the same volume of shaped text as a
# desktop compositor.
# =============================================================================
coretext_path, coretext = load("src/font/shaper/coretext.zig")
if "cf_release_thread: ?*CFReleaseThread," in coretext:
    messages.append("[+] coretext.zig already patched")
else:
    # Make the struct fields optional so nil can represent "no thread"
    coretext = replace_exact(
        coretext,
        "cf_release_thread: *CFReleaseThread,\n    cf_release_thr: std.Thread,",
        "cf_release_thread: ?*CFReleaseThread,\n    cf_release_thr: ?std.Thread,",
        "coretext CF release thread fields",
    )

    # Guard thread creation behind a comptime platform check
    old_create = """        // Create the CF release thread.
        var cf_release_thread = try alloc.create(CFReleaseThread);
        errdefer alloc.destroy(cf_release_thread);
        cf_release_thread.* = try .init(alloc);
        errdefer cf_release_thread.deinit();

        // Start the CF release thread.
        var cf_release_thr = try std.Thread.spawn(
            .{},
            CFReleaseThread.threadMain,
            .{cf_release_thread},
        );
        cf_release_thr.setName(global.io(), "cf_release") catch {};

        return .{"""

    new_create = """        // On iOS the kqueue-based event loop used by the release thread
        // crashes due to Mach port sandbox restrictions. Skip it entirely
        // and fall through to synchronous release in endFrame.
        var cf_release_thread: ?*CFReleaseThread = null;
        var cf_release_thr: ?std.Thread = null;
        if (comptime builtin.os.tag != .ios) {
            const thr_obj = try alloc.create(CFReleaseThread);
            errdefer alloc.destroy(thr_obj);
            thr_obj.* = try .init(alloc);
            errdefer thr_obj.deinit();
            const thr = try std.Thread.spawn(.{}, CFReleaseThread.threadMain, .{thr_obj});
            thr.setName(global.io(), "cf_release") catch {};
            cf_release_thread = thr_obj;
            cf_release_thr = thr;
        }

        return .{"""

    coretext = replace_exact(
        coretext,
        old_create,
        new_create,
        "coretext CF release thread creation block",
    )

    # Deinit: only join/stop the thread if it was created
    old_deinit = """        // Stop the CF release thread
        {
            self.cf_release_thread.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.join();
        }
        self.cf_release_thread.deinit();
        self.alloc.destroy(self.cf_release_thread);"""

    new_deinit = """        // Stop the CF release thread (nil on iOS)
        if (self.cf_release_thread) |thr_obj| {
            thr_obj.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.?.join();
            thr_obj.deinit();
            self.alloc.destroy(thr_obj);
        }"""

    coretext = replace_exact(
        coretext,
        old_deinit,
        new_deinit,
        "coretext CF release thread deinit block",
    )

    # endFrame: guard the mailbox push behind an optional check.
    # When nil (iOS), fall through to the synchronous release below.
    old_end = """        // Send the items. If the send succeeds then we wake up the
        // thread to process the items. If the send fails then do a manual
        // cleanup.
        if (self.cf_release_thread.mailbox.push(global.io(), .{ .release = .{
            .refs = items,
            .alloc = self.alloc,
        } }, .{ .forever = {} }) != 0) {
            self.cf_release_thread.wakeup.notify() catch |err| {
                log.warn(
                    "error notifying cf release thread to wake up, may stall err={}",
                    .{err},
                );
            };
            return;
        }

        for (items) |ref| macos.foundation.CFRelease(ref);"""

    new_end = """        // Offload to the background release thread when available.
        // On iOS cf_release_thread is nil, so we fall through to sync release.
        if (self.cf_release_thread) |thr_obj| {
            if (thr_obj.mailbox.push(global.io(), .{ .release = .{
                .refs = items,
                .alloc = self.alloc,
            } }, .{ .forever = {} }) != 0) {
                thr_obj.wakeup.notify() catch |err| {
                    log.warn(
                        "error notifying cf release thread to wake up, may stall err={}",
                        .{err},
                    );
                };
                return;
            }
        }

        for (items) |ref| macos.foundation.CFRelease(ref);"""

    coretext = replace_exact(
        coretext, old_end, new_end, "coretext endFrame mailbox block"
    )

    # Every remaining use must go through the optional; a bare field access
    # would not compile once the fields became optional.
    require(
        "self.cf_release_thread." not in coretext,
        "postcondition: coretext.zig still dereferences cf_release_thread directly",
    )

    stage(coretext_path, coretext, "src/font/shaper/coretext.zig")
    messages.append("[+] patched coretext.zig: CF release thread disabled on iOS")

# =============================================================================
# Patch 4: iosurface.zig — Explicit row byte alignment
#
# Problem: When creating an IOSurface without specifying bytesPerRow, the
# system picks whatever alignment it wants. Metal textures created from
# these surfaces may have mismatched row strides, causing corrupted or
# shifted glyph rendering (especially visible on font atlas textures).
#
# Fix: Calculate 64-byte-aligned row bytes and pass kIOSurfaceBytesPerRow
# when creating the IOSurface. Also suppress unused return value warnings
# from IOSurfaceLock/Unlock.
# =============================================================================
iosurface_path, iosurface = load("pkg/macos/iosurface/iosurface.zig")
if "kIOSurfaceBytesPerRow" in iosurface:
    messages.append("[+] iosurface.zig already patched")
else:
    # Compute aligned row stride before creating the Number objects
    old_start = """    pub fn init(properties: Properties) Allocator.Error!*IOSurface {
        var w = try foundation.Number.create(.int, &properties.width);"""

    new_start = """    pub fn init(properties: Properties) Allocator.Error!*IOSurface {
        // Ensure row stride is 64-byte aligned for Metal texture compatibility.
        const aligned_stride: c_int = @intCast(
            (properties.width * properties.bytes_per_element + 63) & ~@as(c_int, 63),
        );
        var w = try foundation.Number.create(.int, &properties.width);"""

    iosurface = replace_exact(
        iosurface, old_start, new_start, "iosurface init start"
    )

    # Create a Number for the stride and include it in the dictionary
    old_dict_setup = """        var bpe = try foundation.Number.create(.int, &properties.bytes_per_element);
        defer bpe.release();

        var properties_dict = try foundation.Dictionary.create("""

    new_dict_setup = """        var bpe = try foundation.Number.create(.int, &properties.bytes_per_element);
        defer bpe.release();

        var stride_num = try foundation.Number.create(.int, &aligned_stride);
        defer stride_num.release();

        var properties_dict = try foundation.Dictionary.create("""

    iosurface = replace_exact(
        iosurface, old_dict_setup, new_dict_setup, "iosurface bpe block"
    )

    # Extend the dictionary keys/values arrays
    old_dict = """            &[_]?*const anyopaque{
                c.kIOSurfaceWidth,
                c.kIOSurfaceHeight,
                c.kIOSurfacePixelFormat,
                c.kIOSurfaceBytesPerElement,
            },
            &[_]?*const anyopaque{ w, h, pf, bpe },"""

    new_dict = """            &[_]?*const anyopaque{
                c.kIOSurfaceWidth,
                c.kIOSurfaceHeight,
                c.kIOSurfacePixelFormat,
                c.kIOSurfaceBytesPerElement,
                c.kIOSurfaceBytesPerRow,
            },
            &[_]?*const anyopaque{ w, h, pf, bpe, stride_num },"""

    iosurface = replace_exact(
        iosurface, old_dict, new_dict, "iosurface dictionary keys"
    )

    # Silence unused return value from IOSurfaceLock/Unlock
    iosurface = replace_exact(
        iosurface,
        "        c.IOSurfaceLock(\n            @ptrCast(self),\n            0,\n            null,\n        );",
        "        _ = c.IOSurfaceLock(\n            @ptrCast(self),\n            0,\n            null,\n        );",
        "iosurface IOSurfaceLock discard",
    )
    iosurface = replace_exact(
        iosurface,
        "        c.IOSurfaceUnlock(\n            @ptrCast(self),\n            0,\n            null,\n        );",
        "        _ = c.IOSurfaceUnlock(\n            @ptrCast(self),\n            0,\n            null,\n        );",
        "iosurface IOSurfaceUnlock discard",
    )

    stage(iosurface_path, iosurface, "pkg/macos/iosurface/iosurface.zig")
    messages.append("[+] patched iosurface.zig: 64-byte stride alignment for Metal")

# =============================================================================
# Patch 5: build.zig.zon — libxev pin for the iOS kqueue mach port panic
#
# The bundled libxev used mach ports for async wakeup on Darwin, and its
# kqueue backend returned null for mach port kevents on non-macOS Darwin
# (iOS); the caller then unwrapped that null and panicked. This step repinned
# libxev to mitchellh/libxev@7e7d2f2 which handles iOS correctly.
#
# Upstream ghostty has since repinned libxev itself, so neither our old URL nor
# our old hash exists any more and this step had become a silent no-op that
# still printed success. Recognize the exact upstream pin we verified as
# carrying the fix, and fail on anything we do not recognize.
# =============================================================================
zon_path, zon = load("build.zig.zon")
old_url = '"https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz"'
new_url = '"https://github.com/mitchellh/libxev/archive/7e7d2f2ab4700544657f8ec268715c8ef320d839.tar.gz"'
old_hash = '"libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs"'
new_hash = '"libxev-0.0.0-86vtcwE9EwB942iWRnaNMXHv3n0BeLAs_tVhrs5cT8cQ"'
upstream_url = '"https://deps.files.ghostty.org/libxev-9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf.tar.gz"'
upstream_hash = '"libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F"'

if new_url in zon and new_hash in zon:
    messages.append("[+] libxev already updated")
elif old_url in zon:
    zon = replace_exact(zon, old_url, new_url, "build.zig.zon libxev url")
    zon = replace_exact(zon, old_hash, new_hash, "build.zig.zon libxev hash")
    stage(zon_path, zon, "build.zig.zon")
    messages.append("[+] patched build.zig.zon: updated libxev for iOS mach port fix")
elif upstream_url in zon and upstream_hash in zon:
    messages.append(
        "[+] libxev repin not applicable: upstream already pins libxev 9ce8e8e"
    )
else:
    print(
        "[-] build.zig.zon: libxev is pinned to an unrecognized revision; "
        "re-verify the iOS mach port fix and update this patch"
    )
    sys.exit(1)

# All transformations succeeded — commit them.
for path, body, _ in pending:
    path.write_text(body)

for message in messages:
    print(message)
PYEOF

echo "[+] all ios metal rendering patches applied"
