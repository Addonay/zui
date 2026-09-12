//! Mask-layer compositing instance data (M5 mask adapt).
//!
//! Upstream `vello_gpu` has no mask sampling path and panics on mask layers
//! (`scene.rs`). This port implements the documented adapt: the rendered layer
//! region is multiplied by the mask in a dedicated pass into the shared
//! scratch texture, then copied back before the layer is composited. The
//! multiplier is a single instance per masked layer; see `mask.wgsl` for the
//! shader and `docs/gpu-compatibility.md` for the divergence record.
//!
//! Vertex layout: 24 bytes, six `Uint32` attributes at shader locations 0–5,
//! instance step mode. All coordinates are packed `u16` pairs; mask sampling
//! uses the layer bbox origin to recover scene pixel coordinates, exactly like
//! the CPU `SampledMaskIter` (`x = span.pixelX()`, `y = row_y`).

const std = @import("std");
const geometry = @import("../common/geometry.zig");
const util = @import("util.zig");
const target_mod = @import("target.zig");

const RectU16 = geometry.RectU16;
const SizeU16 = geometry.SizeU16;

/// Per-instance data for one mask multiply pass.
pub const GpuMaskInstance = extern struct {
    /// Origin of the destination region in the scratch texture (`u16x2`).
    geometry_origin: u32,
    /// Width and height of the region (`u16x2`).
    geometry_size: u32,
    /// Origin of the source region in the layer texture (`u16x2`).
    source_origin: u32,
    /// Scene-space origin of the layer bbox (`u16x2`); mask sample
    /// coordinates are `scene_origin + local`.
    scene_origin: u32,
    /// Mask dimensions (`u16x2`); samples outside are transparent black.
    mask_size: u32,
    /// Destination texture dimensions (`u16x2`) used for NDC conversion.
    texture_size: u32,

    /// Build an instance from unpacked coordinates.
    pub fn new(
        geometry_origin: [2]u16,
        geometry_size: [2]u16,
        source_origin: [2]u16,
        scene_origin: [2]u16,
        mask_size: [2]u16,
        texture_size: [2]u16,
    ) GpuMaskInstance {
        return .{
            .geometry_origin = util.packU16Pair(geometry_origin[0], geometry_origin[1]),
            .geometry_size = util.packU16Pair(geometry_size[0], geometry_size[1]),
            .source_origin = util.packU16Pair(source_origin[0], source_origin[1]),
            .scene_origin = util.packU16Pair(scene_origin[0], scene_origin[1]),
            .mask_size = util.packU16Pair(mask_size[0], mask_size[1]),
            .texture_size = util.packU16Pair(texture_size[0], texture_size[1]),
        };
    }

    /// Build the instance that multiplies `region` (a layer allocation) by a
    /// mask of `mask_size` into the scratch texture at the same coordinates.
    ///
    /// The scratch texture mirrors the layer page allocation, so source and
    /// destination origins are the region rectangle, and `layer_bbox` maps
    /// pixels back to scene coordinates for mask sampling.
    pub fn fromRegion(
        region: target_mod.LayerTextureRegion,
        mask_size: [2]u16,
        texture_size: SizeU16,
    ) GpuMaskInstance {
        return new(
            .{ region.texture.rect.x0, region.texture.rect.y0 },
            .{ region.texture.rect.width(), region.texture.rect.height() },
            .{ region.texture.rect.x0, region.texture.rect.y0 },
            .{ region.layer_bbox.x0, region.layer_bbox.y0 },
            mask_size,
            .{ texture_size.width(), texture_size.height() },
        );
    }
};

comptime {
    if (@sizeOf(GpuMaskInstance) != 24) {
        @compileError("GpuMaskInstance must be exactly 24 bytes");
    }
    const fields = .{
        "geometry_origin",
        "geometry_size",
        "source_origin",
        "scene_origin",
        "mask_size",
        "texture_size",
    };
    for (fields, 0..) |name, i| {
        if (@offsetOf(GpuMaskInstance, name) != i * 4) {
            @compileError("GpuMaskInstance field offsets diverged from the shader contract");
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "gpu mask instance layout and packing" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(GpuMaskInstance));
    try testing.expectEqual(@as(usize, 4), @alignOf(GpuMaskInstance));

    const instance = GpuMaskInstance.new(.{ 1, 2 }, .{ 3, 4 }, .{ 5, 6 }, .{ 7, 8 }, .{ 9, 10 }, .{ 11, 12 });
    try testing.expectEqual(@as(u32, 0x0002_0001), instance.geometry_origin);
    try testing.expectEqual(@as(u32, 0x0004_0003), instance.geometry_size);
    try testing.expectEqual(@as(u32, 0x0006_0005), instance.source_origin);
    try testing.expectEqual(@as(u32, 0x0008_0007), instance.scene_origin);
    try testing.expectEqual(@as(u32, 0x000A_0009), instance.mask_size);
    try testing.expectEqual(@as(u32, 0x000C_000B), instance.texture_size);
}

test "gpu mask instance follows the layer region mapping" {
    const region = target_mod.LayerTextureRegion{
        .texture = .{
            .target = target_mod.LayerTextureId.new(.even, 0),
            .rect = RectU16.new(100, 200, 150, 250),
        },
        .layer_bbox = RectU16.new(10, 20, 60, 70),
    };
    const instance = GpuMaskInstance.fromRegion(region, .{ 64, 64 }, SizeU16.new(4096));

    try testing.expectEqual(@as(u32, 100 | (200 << 16)), instance.geometry_origin);
    try testing.expectEqual(@as(u32, 50 | (50 << 16)), instance.geometry_size);
    try testing.expectEqual(@as(u32, 100 | (200 << 16)), instance.source_origin);
    try testing.expectEqual(@as(u32, 10 | (20 << 16)), instance.scene_origin);
    try testing.expectEqual(@as(u32, 64 | (64 << 16)), instance.mask_size);
    try testing.expectEqual(@as(u32, 4096 | (4096 << 16)), instance.texture_size);
}
