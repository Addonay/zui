//! Public CPU renderer settings (part of the port of vello_cpu
//! src/render.rs, Apache-2.0 OR MIT).
//!
//! These types live in a leaf module so that both `cpu/render.zig` (which
//! re-exports them, matching the upstream public path) and
//! `cpu/dispatch/single_threaded.zig` can name them without an import cycle:
//! `render.zig` imports the dispatcher, so the dispatcher cannot import
//! `render.zig` back.

const std = @import("std");
const simd = @import("../simd/root.zig");
const peniko = @import("../peniko/root.zig");
const target_mod = @import("../common/target.zig");

/// How the destination pixmap is initialized before rendering.
pub const TargetInit = target_mod.TargetInit(peniko.Color);

/// The pixel format to assume for the destination pixmap.
pub const PixelFormat = enum {
    /// Premultiplied RGBA8.
    rgba8,
};

/// Whether to prioritize speed or quality when rendering.
///
/// Upstream selects the u8 pipeline for `optimize_speed` and the f32 pipeline
/// for `optimize_quality` when both cargo features are enabled; this port
/// mirrors that selection in `SingleThreadedDispatcher.rasterize`.
pub const RenderMode = enum {
    /// Prefer speed (u8 pipeline).
    optimize_speed,
    /// Prefer quality (f32 pipeline).
    optimize_quality,
};

/// Offset in destination pixels where the render context origin is placed.
///
/// Upstream uses a `(u16, u16)` tuple; the port keeps the named-field form the
/// CLI and `docs/cpu-pipeline.md` already use.
pub const Offset = struct {
    /// Horizontal offset in pixels.
    x: u16 = 0,
    /// Vertical offset in pixels.
    y: u16 = 0,
};

/// Settings to apply to the render context.
pub const RenderSettings = struct {
    /// The SIMD level that should be used for rendering operations.
    level: simd.Level,
    /// Number of worker threads. The M1 dispatcher is single-threaded, so this
    /// is currently ignored (multi-threading is M4); it is kept so callers and
    /// scene files match the upstream settings shape.
    num_threads: u16 = 0,

    /// The upstream default: detected baseline level, no worker threads.
    pub const default: RenderSettings = .{
        .level = .baseline,
        .num_threads = 0,
    };
};

/// Settings used when rasterizing a scene into a pixmap.
pub const RasterizerSettings = struct {
    /// Whether to prioritize speed or quality when rendering.
    render_mode: RenderMode,
    /// How the destination is initialized before drawing.
    target_init: TargetInit,
    /// Pixel format of the destination.
    pixel_format: PixelFormat,
    /// Offset in destination pixels where the render context origin is placed.
    ///
    /// See `RenderContext.renderWith` for the precise semantics.
    offset: Offset,

    /// The upstream default: speed mode, transparent clear, RGBA8, no offset.
    pub const default: RasterizerSettings = .{
        .render_mode = .optimize_speed,
        .target_init = .{ .clear = peniko.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    };
};

test "settings defaults match upstream" {
    const settings = RasterizerSettings.default;
    try std.testing.expectEqual(RenderMode.optimize_speed, settings.render_mode);
    try std.testing.expectEqual(PixelFormat.rgba8, settings.pixel_format);
    try std.testing.expectEqual(@as(u16, 0), settings.offset.x);
    try std.testing.expectEqual(@as(u16, 0), settings.offset.y);
    try std.testing.expectEqual(peniko.Color.TRANSPARENT, settings.target_init.clear);

    try std.testing.expectEqual(@as(u16, 0), RenderSettings.default.num_threads);
}
