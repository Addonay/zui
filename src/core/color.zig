//! sRGB color in linear 0-1 floats.
//!
//! Why two spellings: Zig has no overloading, so ints and floats need
//! distinct names. `hex` takes packed ints (`RRGGBB` or `RRGGBBAA`,
//! branched on magnitude like Gooey's `Color.hex`); `rgb`/`rgba` take
//! 0-1 floats. This keeps call sites unambiguous: `hex(0x7c5cff)` vs
//! `rgba(0.48, 0.36, 1.0, 0.8)`.

const std = @import("std");

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        std.debug.assert(r >= 0 and r <= 1);
        std.debug.assert(g >= 0 and g <= 1);
        std.debug.assert(b >= 0 and b <= 1);
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        std.debug.assert(r >= 0 and r <= 1);
        std.debug.assert(g >= 0 and g <= 1);
        std.debug.assert(b >= 0 and b <= 1);
        std.debug.assert(a >= 0 and a <= 1);
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn hex(value: u32) Color {
        if (value > 0xFFFFFF) {
            return .{
                .r = @as(f32, @floatFromInt((value >> 24) & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
                .a = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
            };
        }
        return .{
            .r = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
            .a = 1,
        };
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        std.debug.assert(a >= 0 and a <= 1);
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub fn toRgba(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
};

pub fn hex(value: u32) Color {
    return Color.hex(value);
}

pub fn rgb(r: f32, g: f32, b: f32) Color {
    return Color.rgb(r, g, b);
}

pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
    return Color.rgba(r, g, b, a);
}

test "hex splits RRGGBB and RRGGBBAA" {
    const solid = Color.hex(0xFF0000);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, solid.toRgba());
    const with_alpha = Color.hex(0xFFFFFF80);
    try std.testing.expect(with_alpha.a < 1 and with_alpha.a > 0);
}

test "rgb asserts range in debug" {
    const c = Color.rgb(0.5, 0.25, 1);
    try std.testing.expectEqual(@as(f32, 1), c.a);
}
