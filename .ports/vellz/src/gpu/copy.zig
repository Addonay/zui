//! Port of `vello_gpu/src/copy.rs` (Apache-2.0 OR MIT).
//!
//! GPU instance data for copies between intermediate textures. The shader
//! reads four packed `u16` pairs; see `docs/shader-interface.md` §3–§4.

const std = @import("std");
const util = @import("util.zig");

/// Per-instance data for one copy pass (`GpuCopyInstance` upstream).
///
/// Vertex layout: 16 bytes, four `Uint32` attributes at shader locations 0–3,
/// instance step mode.
pub const GpuCopyInstance = extern struct {
    /// Origin in the destination texture page, packed as `u16x2`.
    dest_texture_origin: u32,
    /// Origin in the source texture page, packed as `u16x2`.
    source_texture_origin: u32,
    /// Width and height of the copied region, packed as `u16x2`.
    copy_rect_size: u32,
    /// Width and height of the destination texture page, packed as `u16x2`.
    dest_texture_size: u32,

    /// Build an instance from unpacked `u16` coordinates.
    pub fn new(
        dest_texture_origin: [2]u16,
        source_texture_origin: [2]u16,
        copy_rect_size: [2]u16,
        dest_texture_size: [2]u16,
    ) GpuCopyInstance {
        return .{
            .dest_texture_origin = util.packU16Pair(dest_texture_origin[0], dest_texture_origin[1]),
            .source_texture_origin = util.packU16Pair(source_texture_origin[0], source_texture_origin[1]),
            .copy_rect_size = util.packU16Pair(copy_rect_size[0], copy_rect_size[1]),
            .dest_texture_size = util.packU16Pair(dest_texture_size[0], dest_texture_size[1]),
        };
    }
};

comptime {
    if (@sizeOf(GpuCopyInstance) != 16) {
        @compileError("GpuCopyInstance must be exactly 16 bytes");
    }
    if (@offsetOf(GpuCopyInstance, "dest_texture_origin") != 0 or
        @offsetOf(GpuCopyInstance, "source_texture_origin") != 4 or
        @offsetOf(GpuCopyInstance, "copy_rect_size") != 8 or
        @offsetOf(GpuCopyInstance, "dest_texture_size") != 12)
    {
        @compileError("GpuCopyInstance field offsets diverged from the shader contract");
    }
}

test "gpu copy instance layout and packing" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GpuCopyInstance));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(GpuCopyInstance));

    const instance = GpuCopyInstance.new(.{ 1, 2 }, .{ 3, 4 }, .{ 5, 6 }, .{ 7, 8 });
    try std.testing.expectEqual(@as(u32, 0x0002_0001), instance.dest_texture_origin);
    try std.testing.expectEqual(@as(u32, 0x0004_0003), instance.source_texture_origin);
    try std.testing.expectEqual(@as(u32, 0x0006_0005), instance.copy_rect_size);
    try std.testing.expectEqual(@as(u32, 0x0008_0007), instance.dest_texture_size);

    // The instance must be reinterpretable as bytes for buffer uploads.
    // Little endian: x occupies bytes 0-1, y bytes 2-3.
    const bytes = std.mem.asBytes(&instance);
    try std.testing.expectEqual(@as(usize, 16), bytes.len);
    try std.testing.expectEqual(@as(u8, 1), bytes[0]);
    try std.testing.expectEqual(@as(u8, 2), bytes[2]);
}
