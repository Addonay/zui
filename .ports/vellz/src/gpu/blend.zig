//! Port of `vello_gpu/src/blend.rs` (instance layout and packing subset)
//! (Apache-2.0 OR MIT).
//!
//! The instance constructor needs the schedule's `BlendOp`, `BlendStrip`, and
//! texture regions, so only the `GpuBlendInstance` layout and the bit-level
//! `blend_config` packing land here. `copy_from_scratch` and `new` follow with
//! the schedule port without changing this contract; see
//! `docs/shader-interface.md` §4.

const std = @import("std");
const peniko = @import("../peniko/root.zig");
const util = @import("util.zig");

/// Per-instance data for one blend pass (`GpuBlendInstance` upstream).
///
/// Vertex layout: 32 bytes, eight `Uint32` attributes at shader locations 0–7,
/// instance step mode.
pub const GpuBlendInstance = extern struct {
    /// Atlas-space geometry origin, packed as `u16x2`.
    geometry_origin: u32,
    /// Geometry width in the low 16 bits and height in the high 16 bits.
    geometry_size: u32,
    /// Alpha texture column index for strip geometry.
    geometry_alpha_col_idx: u32,
    /// Width and height of the parent layer texture, packed as `u16x2`.
    parent_texture_size: u32,
    /// Atlas-space origin of the layer in the child layer texture, packed as
    /// `u16x2`.
    child_texture_origin: u32,
    /// Origin of the child layer expressed in parent texture coordinates,
    /// packed as `u16x2`.
    child_parent_origin: u32,
    /// Scene-space width and height of the sampled child layer, packed as
    /// `u16x2`.
    child_rect_size: u32,
    /// Packed blend mode, opacity, parent/child texture parity, and
    /// alpha-presence flag.
    blend_config: u32,
};

comptime {
    if (@sizeOf(GpuBlendInstance) != 32) {
        @compileError("GpuBlendInstance must be exactly 32 bytes");
    }
    const fields = .{
        "geometry_origin",
        "geometry_size",
        "geometry_alpha_col_idx",
        "parent_texture_size",
        "child_texture_origin",
        "child_parent_origin",
        "child_rect_size",
        "blend_config",
    };
    for (fields, 0..) |name, i| {
        if (@offsetOf(GpuBlendInstance, name) != i * 4) {
            @compileError("GpuBlendInstance field offsets diverged from the shader contract");
        }
    }
}

/// Packed `blend_config` bit layout (see `docs/shader-interface.md` §4):
///
/// - bits 0–7: compose (Porter-Duff 0–13)
/// - bits 8–15: mix (0–15)
/// - bits 16–23: opacity
/// - bit 24: parent texture parity
/// - bit 25: child texture parity
/// - bit 26: has alpha
pub fn packBlendConfig(
    mix: peniko.blend.Mix,
    compose: peniko.blend.Compose,
    opacity: f32,
    parent_texture_parity: bool,
    child_texture_parity: bool,
    has_alpha: bool,
) u32 {
    return packCompose(compose) |
        (packMix(mix) << 8) |
        (@as(u32, util.packOpacity(opacity)) << 16) |
        (@as(u32, @intFromBool(parent_texture_parity)) << 24) |
        (@as(u32, @intFromBool(child_texture_parity)) << 25) |
        (@as(u32, @intFromBool(has_alpha)) << 26);
}

/// The shader's mix discriminant (upstream `pack_mix`).
pub fn packMix(mix: peniko.blend.Mix) u32 {
    return @as(u32, mix.toU8());
}

/// The shader's compose discriminant (upstream `pack_compose`).
pub fn packCompose(compose: peniko.blend.Compose) u32 {
    return @as(u32, compose.toU8());
}

test "gpu blend instance layout" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(GpuBlendInstance));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(GpuBlendInstance));

    var instance = std.mem.zeroes(GpuBlendInstance);
    instance.geometry_origin = util.packU16Pair(1, 2);
    instance.child_rect_size = util.packU16Pair(3, 4);
    try std.testing.expectEqual(@as(u32, 0x0002_0001), instance.geometry_origin);
    try std.testing.expectEqual(@as(u32, 0x0004_0003), instance.child_rect_size);

    const bytes = std.mem.asBytes(&instance);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
}

test "pack blend config bit layout" {
    // Normal + SrcOver, full opacity, no parity/has-alpha.
    try std.testing.expectEqual(
        @as(u32, 3 | (0 << 8) | (255 << 16)),
        packBlendConfig(.normal, .src_over, 1.0, false, false, false),
    );
    try std.testing.expectEqual(
        @as(u32, 0 | (1 << 8) | (128 << 16) | (1 << 24) | (1 << 25) | (1 << 26)),
        packBlendConfig(.multiply, .clear, 0.5, true, true, true),
    );
    // All 16 mix and 14 compose discriminants fit their fields.
    for (0..16) |value| {
        const mix = peniko.blend.Mix.fromU8(@intCast(value)).?;
        try std.testing.expectEqual(@as(u32, @intCast(value)), packMix(mix));
    }
    for (0..14) |value| {
        const compose = peniko.blend.Compose.fromU8(@intCast(value)).?;
        try std.testing.expectEqual(@as(u32, @intCast(value)), packCompose(compose));
    }
    // opacity 0 is exactly 0, opacity 1 is exactly 255.
    try std.testing.expectEqual(
        @as(u32, 3 | (0 << 8)),
        packBlendConfig(.normal, .src_over, 0.0, false, false, false),
    );
}
