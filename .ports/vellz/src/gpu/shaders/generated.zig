//! Compiled WGSL shader sources from the pinned `vello_gpu_shaders` revision.
//!
//! These are minified/linked WGSL strings produced upstream by WESL + naga
//! 29.0.3. They are checked in so a GPU build needs neither Cargo, WESL, nor
//! naga. Regenerate with `tools/generate_shaders.sh`; see `manifest.json` for
//! byte counts and SHA-256 hashes and `docs/shader-interface.md` for the
//! host-side contract (bind groups, vertex layouts, struct layouts).

/// `render.wesl`: sparse-strip fill/alpha/opaque/depth rendering.
pub const RENDER = @embedFile("render.wgsl");
/// `clear.wesl`: rectangle and atlas-region clears.
pub const CLEAR = @embedFile("clear.wgsl");
/// `copy.wesl`: texture-region copy.
pub const COPY = @embedFile("copy.wgsl");
/// `blend.wesl`: layer compositing.
pub const BLEND = @embedFile("blend.wgsl");
/// `filter.wesl`: offset/flood/blur/drop-shadow executor.
pub const FILTER = @embedFile("filter.wgsl");

/// All shader roots by name, for enumeration and tests.
pub const all = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "render", .source = RENDER },
    .{ .name = "clear", .source = CLEAR },
    .{ .name = "copy", .source = COPY },
    .{ .name = "blend", .source = BLEND },
    .{ .name = "filter", .source = FILTER },
};

test "shader sources are non-empty and contain expected entry points" {
    const std = @import("std");
    for (all) |shader| {
        try std.testing.expect(shader.source.len > 0);
        // All five roots share the vs_main/fs_main entry-point convention.
        try std.testing.expect(std.mem.indexOf(u8, shader.source, "vs_main") != null);
        try std.testing.expect(std.mem.indexOf(u8, shader.source, "fs_main") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, CLEAR, "vs_main_fullscreen") != null);
    try std.testing.expect(std.mem.indexOf(u8, CLEAR, "fs_transparent") != null);
}
