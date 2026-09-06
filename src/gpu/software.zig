//! Software rasterizer for GPU Scene quads.
//!
//! Renders Scene draw lists into a 32-bit pixel buffer (RGBA/BGRA/ARGB).
//! Zero allocation; supports clipping to buffer bounds, alpha blending,
//! and rounded corners.

const std = @import("std");
const color = @import("../core/color.zig");
const scene_mod = @import("scene.zig");

pub const Quad = scene_mod.Quad;
pub const Scene = scene_mod.Scene;
pub const Color = color.Color;

pub const PixelFormat = enum {
    rgba32,
    bgra32,
    argb32,
};

pub const Target = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat = .bgra32,

    pub fn init(pixels: []u8, width: u32, height: u32, format: PixelFormat) Target {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = width * 4,
            .format = format,
        };
    }

    pub fn clear(self: Target, c: Color) void {
        const p = self.packColor(c);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row_offset = y * self.stride;
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const off = row_offset + x * 4;
                if (off + 4 <= self.pixels.len) {
                    std.mem.writeInt(u32, self.pixels[off..][0..4], p, .little);
                }
            }
        }
    }

    pub fn drawQuad(self: Target, q: Quad) void {
        if (q.w <= 0 or q.h <= 0 or q.color.a <= 0) return;

        const x0: i32 = @intFromFloat(@max(0.0, q.x));
        const y0: i32 = @intFromFloat(@max(0.0, q.y));
        const x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.width)), q.x + q.w));
        const y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.height)), q.y + q.h));

        if (x0 >= x1 or y0 >= y1) return;

        const sr: u32 = @intFromFloat(std.math.clamp(q.color.r * 255.0, 0.0, 255.0));
        const sg: u32 = @intFromFloat(std.math.clamp(q.color.g * 255.0, 0.0, 255.0));
        const sb: u32 = @intFromFloat(std.math.clamp(q.color.b * 255.0, 0.0, 255.0));
        const sa: u32 = @intFromFloat(std.math.clamp(q.color.a * 255.0, 0.0, 255.0));

        const r_max = @min(q.w / 2.0, q.h / 2.0);
        const radius = @min(q.radius, r_max);
        const r_sq = radius * radius;

        var y: i32 = y0;
        while (y < y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const row_off = @as(usize, @intCast(y)) * self.stride;

            var x: i32 = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;

                // Rounded corner test
                if (radius > 0) {
                    var in_corner = false;
                    var cx: f32 = 0;
                    var cy: f32 = 0;

                    if (px < q.x + radius and py < q.y + radius) {
                        in_corner = true;
                        cx = q.x + radius;
                        cy = q.y + radius;
                    } else if (px > q.x + q.w - radius and py < q.y + radius) {
                        in_corner = true;
                        cx = q.x + q.w - radius;
                        cy = q.y + radius;
                    } else if (px < q.x + radius and py > q.y + q.h - radius) {
                        in_corner = true;
                        cx = q.x + radius;
                        cy = q.y + q.h - radius;
                    } else if (px > q.x + q.w - radius and py > q.y + q.h - radius) {
                        in_corner = true;
                        cx = q.x + q.w - radius;
                        cy = q.y + q.h - radius;
                    }

                    if (in_corner) {
                        const dx = px - cx;
                        const dy = py - cy;
                        if (dx * dx + dy * dy > r_sq) continue;
                    }
                }

                const off = row_off + @as(usize, @intCast(x)) * 4;
                if (off + 4 > self.pixels.len) continue;

                if (sa == 255) {
                    self.writePixel(off, sr, sg, sb, 255);
                } else {
                    const dst = self.readPixel(off);
                    const inv_a = 255 - sa;
                    const out_r = (sr * sa + dst.r * inv_a) / 255;
                    const out_g = (sg * sa + dst.g * inv_a) / 255;
                    const out_b = (sb * sa + dst.b * inv_a) / 255;
                    const out_a = sa + (dst.a * inv_a) / 255;
                    self.writePixel(off, out_r, out_g, out_b, out_a);
                }
            }
        }
    }

    pub fn renderScene(self: Target, scene: *const Scene) void {
        for (scene.slice()) |q| {
            self.drawQuad(q);
        }
    }

    fn packColor(self: Target, c: Color) u32 {
        const r: u32 = @intFromFloat(std.math.clamp(c.r * 255.0, 0.0, 255.0));
        const g: u32 = @intFromFloat(std.math.clamp(c.g * 255.0, 0.0, 255.0));
        const b: u32 = @intFromFloat(std.math.clamp(c.b * 255.0, 0.0, 255.0));
        const a: u32 = @intFromFloat(std.math.clamp(c.a * 255.0, 0.0, 255.0));

        return switch (self.format) {
            .bgra32 => (a << 24) | (r << 16) | (g << 8) | b,
            .rgba32 => (a << 24) | (b << 16) | (g << 8) | r,
            .argb32 => (b << 24) | (g << 16) | (r << 8) | a,
        };
    }

    fn writePixel(self: Target, off: usize, r: u32, g: u32, b: u32, a: u32) void {
        switch (self.format) {
            .bgra32 => {
                self.pixels[off + 0] = @truncate(b);
                self.pixels[off + 1] = @truncate(g);
                self.pixels[off + 2] = @truncate(r);
                self.pixels[off + 3] = @truncate(a);
            },
            .rgba32 => {
                self.pixels[off + 0] = @truncate(r);
                self.pixels[off + 1] = @truncate(g);
                self.pixels[off + 2] = @truncate(b);
                self.pixels[off + 3] = @truncate(a);
            },
            .argb32 => {
                self.pixels[off + 0] = @truncate(a);
                self.pixels[off + 1] = @truncate(r);
                self.pixels[off + 2] = @truncate(g);
                self.pixels[off + 3] = @truncate(b);
            },
        }
    }

    const Pixel = struct { r: u32, g: u32, b: u32, a: u32 };

    fn readPixel(self: Target, off: usize) Pixel {
        return switch (self.format) {
            .bgra32 => .{
                .b = self.pixels[off + 0],
                .g = self.pixels[off + 1],
                .r = self.pixels[off + 2],
                .a = self.pixels[off + 3],
            },
            .rgba32 => .{
                .r = self.pixels[off + 0],
                .g = self.pixels[off + 1],
                .b = self.pixels[off + 2],
                .a = self.pixels[off + 3],
            },
            .argb32 => .{
                .a = self.pixels[off + 0],
                .r = self.pixels[off + 1],
                .g = self.pixels[off + 2],
                .b = self.pixels[off + 3],
            },
        };
    }
};

test "software target clear and draw quad" {
    var buf: [16 * 16 * 4]u8 = undefined;
    const target = Target.init(&buf, 16, 16, .rgba32);

    target.clear(Color.hex(0x000000));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    try std.testing.expectEqual(@as(u8, 255), buf[3]);

    target.drawQuad(.{
        .x = 2,
        .y = 2,
        .w = 4,
        .h = 4,
        .color = Color.hex(0xFF0000),
    });

    // Pixel at (3, 3) should be red
    const off = (3 * 16 + 3) * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[off + 0]); // r
    try std.testing.expectEqual(@as(u8, 0), buf[off + 1]); // g
    try std.testing.expectEqual(@as(u8, 0), buf[off + 2]); // b
    try std.testing.expectEqual(@as(u8, 255), buf[off + 3]); // a

    // Pixel at (0, 0) should still be black
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "software target alpha blending" {
    var buf: [4 * 4 * 4]u8 = undefined;
    const target = Target.init(&buf, 4, 4, .rgba32);

    target.clear(Color.hex(0x000000)); // Black base

    // Draw semi-transparent white (50% alpha)
    target.drawQuad(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .color = Color.rgba(1.0, 1.0, 1.0, 0.5),
    });

    // Should be around ~127
    try std.testing.expect(buf[0] >= 126 and buf[0] <= 129);
}

test "software target rounded quad corners" {
    var buf: [10 * 10 * 4]u8 = undefined;
    const target = Target.init(&buf, 10, 10, .rgba32);

    target.clear(Color.hex(0x000000));

    target.drawQuad(.{
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .radius = 4,
        .color = Color.hex(0xFFFFFF),
    });

    // Center (5, 5) should be white
    const center_off = (5 * 10 + 5) * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[center_off]);

    // Top-left corner (0, 0) should remain black because of radius 4
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}
