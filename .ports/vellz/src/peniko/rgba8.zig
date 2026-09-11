//! Port of peniko 0.6.1 (no direct counterpart) / color 0.3.3 rgba8.rs
//! (Apache-2.0 OR MIT).
//!
//! Packed 8-bit sRGB colors. Both structs are `extern` (upstream `#[repr(C)]`)
//! so pixel buffers can be reinterpreted as `[4]u8` / `u32` without padding.

const std = @import("std");
const color = @import("color.zig");

/// A packed representation of straight (non-premultiplied) sRGB colors.
pub const Rgba8 = extern struct {
    /// Red component.
    r: u8,
    /// Green component.
    g: u8,
    /// Blue component.
    b: u8,
    /// Alpha component, interpreted as straight alpha.
    a: u8,

    /// Return the color values in the order `[r, g, b, a]`.
    pub fn toU8Array(self: Rgba8) [4]u8 {
        return .{ self.r, self.g, self.b, self.a };
    }

    /// Build a color from a `[r, g, b, a]` byte array.
    pub fn fromU8Array(bytes: [4]u8) Rgba8 {
        return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
    }

    /// Return the color as a native-endian packed value, with `r` the least
    /// significant byte on little-endian targets.
    pub fn toU32(self: Rgba8) u32 {
        return @bitCast(self.toU8Array());
    }

    /// Interpret a native-endian packed value as a color, with `r` the least
    /// significant byte on little-endian targets.
    pub fn fromU32(packed_bytes: u32) Rgba8 {
        return fromU8Array(@bitCast(packed_bytes));
    }

    /// Convert to a straight-alpha sRGB color.
    pub fn toAlphaColor(self: Rgba8) color.AlphaColor(color.Srgb) {
        return color.AlphaColor(color.Srgb).fromRgba8(self.r, self.g, self.b, self.a);
    }
};

/// A packed representation of premultiplied sRGB colors.
pub const PremulRgba8 = extern struct {
    /// Red component.
    r: u8,
    /// Green component.
    g: u8,
    /// Blue component.
    b: u8,
    /// Alpha component.
    a: u8,

    /// Return the color values in the order `[r, g, b, a]`.
    pub fn toU8Array(self: PremulRgba8) [4]u8 {
        return .{ self.r, self.g, self.b, self.a };
    }

    /// Build a color from a `[r, g, b, a]` byte array.
    pub fn fromU8Array(bytes: [4]u8) PremulRgba8 {
        return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
    }

    /// Return the color as a native-endian packed value, with `r` the least
    /// significant byte on little-endian targets.
    pub fn toU32(self: PremulRgba8) u32 {
        return @bitCast(self.toU8Array());
    }

    /// Interpret a native-endian packed value as a color, with `r` the least
    /// significant byte on little-endian targets.
    pub fn fromU32(packed_bytes: u32) PremulRgba8 {
        return fromU8Array(@bitCast(packed_bytes));
    }

    /// Convert to a premultiplied sRGB color.
    pub fn toPremulColor(self: PremulRgba8) color.PremulColor(color.Srgb) {
        return color.PremulColor(color.Srgb).fromRgba8(self.r, self.g, self.b, self.a);
    }
};

test "to_u32" {
    // Upstream test: `to_u32` is `from_ne_bytes`, i.e. native endianness.
    const c = Rgba8{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try std.testing.expectEqual(std.mem.nativeToLittle(u32, 0x04030201), c.toU32());

    const p = PremulRgba8{ .r = 0xaa, .g = 0xbb, .b = 0xcc, .a = 0xff };
    try std.testing.expectEqual(std.mem.nativeToLittle(u32, 0xffccbbaa), p.toU32());
}

test "from_u32" {
    const c = Rgba8{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try std.testing.expectEqual(c, Rgba8.fromU32(std.mem.nativeToLittle(u32, 0x04030201)));

    const p = PremulRgba8{ .r = 0xaa, .g = 0xbb, .b = 0xcc, .a = 0xff };
    try std.testing.expectEqual(p, PremulRgba8.fromU32(std.mem.nativeToLittle(u32, 0xffccbbaa)));
}

test "to_u8_array" {
    const c = Rgba8{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, c.toU8Array());

    const p = PremulRgba8{ .r = 0xaa, .g = 0xbb, .b = 0xcc, .a = 0xff };
    try std.testing.expectEqual([4]u8{ 0xaa, 0xbb, 0xcc, 0xff }, p.toU8Array());
}

test "from_u8_array" {
    const c = Rgba8{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try std.testing.expectEqual(c, Rgba8.fromU8Array(.{ 1, 2, 3, 4 }));

    const p = PremulRgba8{ .r = 0xaa, .g = 0xbb, .b = 0xcc, .a = 0xff };
    try std.testing.expectEqual(p, PremulRgba8.fromU8Array(.{ 0xaa, 0xbb, 0xcc, 0xff }));
}

test "extern layout" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Rgba8));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(PremulRgba8));
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, Rgba8.fromU8Array(.{ 1, 2, 3, 4 }).toU8Array());
}

test "byte round trip through colors" {
    const bytes = [4]u8{ 12, 34, 56, 78 };
    const straight = Rgba8.fromU8Array(bytes);
    const alpha = straight.toAlphaColor();
    try std.testing.expectEqual(bytes, alpha.toRgba8().toU8Array());

    const premul = PremulRgba8.fromU8Array(bytes);
    const premul_color = premul.toPremulColor();
    try std.testing.expectEqual(bytes, premul_color.toRgba8().toU8Array());
}
