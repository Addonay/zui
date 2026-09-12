//! GPU backend root.

const build_options = @import("build_options");

/// Compiled WGSL sources from the pinned `vello_gpu_shaders` revision.
pub const shaders = @import("shaders/generated.zig");

/// Host/shader layout contract (CPU-safe: no `wgpu` import).
pub const util = @import("util.zig");
pub const copy = @import("copy.zig");
pub const blend = @import("blend.zig");
pub const filter = @import("filter.zig");
pub const render = @import("render/common.zig");

/// `vello_gpu` port, bottom-up (CPU-safe: these modules never import `wgpu`).
pub const target = @import("target.zig");
pub const rect = @import("rect.zig");
pub const paint = @import("paint.zig");
pub const scene = @import("scene.zig");
pub const draw = @import("draw.zig");
pub const schedule = @import("schedule/mod.zig");
pub const resources = @import("resources.zig");
pub const text = @import("text.zig");

pub const Scene = scene.Scene;
pub const RecordedDraw = scene.RecordedDraw;

/// The wgpu-backed device/pipeline layer. Referenced only when the package is
/// built with `-Dgpu=true`; the path must still exist in a CPU-only build
/// because Zig resolves import paths even in untaken comptime branches.
pub const backend = if (build_options.gpu) @import("backend/root.zig") else struct {};

test {
    @import("std").testing.refAllDecls(@This());

    // The layout modules are exercised in the default test build through the
    // unconditional imports in `src/root.zig`; import them here as well so a
    // `-Dgpu=true` test run analyzes them from the GPU root.
    _ = @import("util.zig");
    _ = @import("copy.zig");
    _ = @import("blend.zig");
    _ = @import("filter.zig");
    _ = @import("render/common.zig");
    _ = @import("target.zig");
    _ = @import("rect.zig");
    _ = @import("paint.zig");
    _ = @import("scene.zig");
    _ = @import("draw.zig");
    _ = @import("schedule/mod.zig");
    _ = @import("resources.zig");
    _ = @import("text.zig");
}
