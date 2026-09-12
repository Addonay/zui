//! Port of `vello_gpu/src/util.rs` (packing subset) (Apache-2.0 OR MIT).
//!
//! Only the GPU instance packing helpers needed by the host/shader layout
//! contract are ported here; `Ranges`/`RangedSlice` land with the schedule.
//! The remaining `util.rs` surface can be added without changing these
//! functions.

const std = @import("std");

/// Pack a `u16` pair into a `u32` with `x` in the low 16 bits and `y` in the
/// high 16 bits (the layout consumed by the strip/blend/copy shaders).
pub fn packU16Pair(x: u16, y: u16) u32 {
    return @as(u32, x) | (@as(u32, y) << 16);
}

/// Unpack the `u16` pair produced by [`packU16Pair`].
pub fn unpackU16Pair(value: u32) [2]u16 {
    return .{ @truncate(value), @truncate(value >> 16) };
}

/// Round an opacity in `0.0..1.0` to the normalized `u8` range, clamping and
/// rounding exactly like upstream (`(clamped * 255.0).round() as u8`).
pub fn packOpacity(opacity: f32) u8 {
    const clamped = std.math.clamp(opacity, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

test "pack_u16_pair round trip" {
    try std.testing.expectEqual(@as(u32, 0x0000_0001), packU16Pair(1, 0));
    try std.testing.expectEqual(@as(u32, 0x0001_0000), packU16Pair(0, 1));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), packU16Pair(0x5678, 0x1234));
    try std.testing.expectEqual([2]u16{ 0x5678, 0x1234 }, unpackU16Pair(0x1234_5678));
    try std.testing.expectEqual([2]u16{ 0xFFFF, 0xFFFF }, unpackU16Pair(0xFFFF_FFFF));
}

test "pack_opacity clamps and rounds" {
    try std.testing.expectEqual(@as(u8, 0), packOpacity(0.0));
    try std.testing.expectEqual(@as(u8, 255), packOpacity(1.0));
    try std.testing.expectEqual(@as(u8, 128), packOpacity(0.5));
    try std.testing.expectEqual(@as(u8, 0), packOpacity(-1.0));
    try std.testing.expectEqual(@as(u8, 255), packOpacity(2.0));
    // Upstream uses round-half-away-from-zero: 0.5/255 * 255 = 0.5 -> 1.
    try std.testing.expectEqual(@as(u8, 1), packOpacity(0.5 / 255.0));
}
