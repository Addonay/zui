//! Software rasterizer for GPU Scene quads.
//!
//! Renders Scene draw lists into a 32-bit pixel buffer (RGBA/BGRA/ARGB).
//! Zero allocation; supports clipping to buffer bounds, alpha blending,
//! and rounded corners.

const std = @import("std");
const core = @import("../core/root.zig");
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

        const sr_f = std.math.clamp(q.color.r * 255.0, 0.0, 255.0);
        const sg_f = std.math.clamp(q.color.g * 255.0, 0.0, 255.0);
        const sb_f = std.math.clamp(q.color.b * 255.0, 0.0, 255.0);
        const sa_f = std.math.clamp(q.color.a * 255.0, 0.0, 255.0);
        var er_f = sr_f;
        var eg_f = sg_f;
        var eb_f = sb_f;
        var ea_f = sa_f;
        if (q.gradient_to) |gt| {
            er_f = std.math.clamp(gt.r * 255.0, 0.0, 255.0);
            eg_f = std.math.clamp(gt.g * 255.0, 0.0, 255.0);
            eb_f = std.math.clamp(gt.b * 255.0, 0.0, 255.0);
            ea_f = std.math.clamp(gt.a * 255.0, 0.0, 255.0);
        }
        const has_gradient = q.gradient_to != null;
        const inv_w = if (q.w > 0) 1.0 / q.w else 0;

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

                // Ring exclusion: inside the outer shape but strictly inside
                // the inset inner shape (corner arcs honored) → hole.
                if (q.border_width > 0) {
                    const bw = q.border_width;
                    const iw = q.w - bw * 2;
                    const ih = q.h - bw * 2;
                    if (iw > 0 and ih > 0) {
                        const ix = q.x + bw;
                        const iy = q.y + bw;
                        if (px > ix and px < ix + iw and py > iy and py < iy + ih) {
                            var in_hole = true;
                            const ir = @max(0.0, radius - bw);
                            if (ir > 0) {
                                var ccx: f32 = 0;
                                var ccy: f32 = 0;
                                var corner = false;
                                if (px < ix + ir and py < iy + ir) {
                                    corner = true;
                                    ccx = ix + ir;
                                    ccy = iy + ir;
                                } else if (px > ix + iw - ir and py < iy + ir) {
                                    corner = true;
                                    ccx = ix + iw - ir;
                                    ccy = iy + ir;
                                } else if (px < ix + ir and py > iy + ih - ir) {
                                    corner = true;
                                    ccx = ix + ir;
                                    ccy = iy + ih - ir;
                                } else if (px > ix + iw - ir and py > iy + ih - ir) {
                                    corner = true;
                                    ccx = ix + iw - ir;
                                    ccy = iy + ih - ir;
                                }
                                if (corner) {
                                    const ddx = px - ccx;
                                    const ddy = py - ccy;
                                    if (ddx * ddx + ddy * ddy > ir * ir) in_hole = false;
                                }
                            }
                            if (in_hole) continue;
                        }
                    }
                }

                var sr: u32 = @intFromFloat(sr_f);
                var sg: u32 = @intFromFloat(sg_f);
                var sb: u32 = @intFromFloat(sb_f);
                var sa: u32 = @intFromFloat(sa_f);
                if (has_gradient) {
                    const t = std.math.clamp((px - q.x) * inv_w, 0.0, 1.0);
                    sr = @intFromFloat(sr_f + (er_f - sr_f) * t);
                    sg = @intFromFloat(sg_f + (eg_f - sg_f) * t);
                    sb = @intFromFloat(sb_f + (eb_f - sb_f) * t);
                    sa = @intFromFloat(sa_f + (ea_f - sa_f) * t);
                }
                if (sa == 255 and !has_gradient) {
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

    pub fn drawGlyph(self: Target, g: scene_mod.Glyph, pixels: []const u8) void {
        if (g.w == 0 or g.h == 0 or g.color.a <= 0) return;
        const w = @as(usize, g.w);
        const h = @as(usize, g.h);

        const sr: u32 = @intFromFloat(std.math.clamp(g.color.r * 255.0, 0.0, 255.0));
        const sg: u32 = @intFromFloat(std.math.clamp(g.color.g * 255.0, 0.0, 255.0));
        const sb: u32 = @intFromFloat(std.math.clamp(g.color.b * 255.0, 0.0, 255.0));
        const base_a = std.math.clamp(g.color.a, 0.0, 1.0);

        // Snap the coverage box to whole pixels once; fractional pen
        // positions accumulate in layout, not in rasterization.
        const gx: i32 = @as(i32, @intFromFloat(@round(g.x)));
        const gy: i32 = @as(i32, @intFromFloat(@round(g.y)));

        var j: usize = 0;
        while (j < h) : (j += 1) {
            const dy = gy + @as(i32, @intCast(j));
            if (dy < 0 or dy >= @as(i32, @intCast(self.height))) continue;
            const fdy = @as(f32, @floatFromInt(dy)) + 0.5;
            if (fdy < g.clip.y or fdy >= g.clip.y + g.clip.h) continue;
            const row_off = @as(usize, @intCast(dy)) * self.stride;
            var i: usize = 0;
            while (i < w) : (i += 1) {
                const dx = gx + @as(i32, @intCast(i));
                if (dx < 0 or dx >= @as(i32, @intCast(self.width))) continue;
                const fdx = @as(f32, @floatFromInt(dx)) + 0.5;
                if (fdx < g.clip.x or fdx >= g.clip.x + g.clip.w) continue;
                const src_off = @as(usize, g.atlas_offset) + j * w + i;
                if (src_off >= pixels.len) continue;
                const coverage = pixels[src_off];
                if (coverage == 0) continue;
                const sa: u32 = @intFromFloat(base_a * @as(f32, @floatFromInt(coverage)));
                if (sa == 0) continue;

                const off = row_off + @as(usize, @intCast(dx)) * 4;
                if (off + 4 > self.pixels.len) continue;
                if (sa == 255 and base_a >= 1.0) {
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

    pub fn renderScene(self: Target, scene: *const Scene, glyph_pixels: []const u8, image_pixels: []const u8) void {
        for (scene.slice()) |q| {
            self.drawQuad(q);
        }
        for (scene.glyphSlice()) |g| {
            self.drawGlyph(g, glyph_pixels);
        }
        for (scene.imageSlice()) |b| {
            self.drawImage(b, image_pixels);
        }
    }

    /// Nearest-neighbor image blit with straight-alpha blend, optional
    /// grayscale + multiply tint, rounded corners, and clip — mirroring
    /// the quad/glyph pixel pipeline (opaque fast path + blend path).
    pub fn drawImage(self: Target, b: scene_mod.ImageBlit, pixels: []const u8) void {
        if (b.w <= 0 or b.h <= 0 or b.src_w == 0 or b.src_h == 0) return;
        const sw = @as(usize, b.src_w);
        const sh = @as(usize, b.src_h);
        if (@as(usize, b.pool_offset) + sw * sh * 4 > pixels.len) return;

        const x0: i32 = @intFromFloat(@max(0.0, b.x));
        const y0: i32 = @intFromFloat(@max(0.0, b.y));
        const x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.width)), b.x + b.w));
        const y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.height)), b.y + b.h));
        if (x0 >= x1 or y0 >= y1) return;

        const tr: f32 = std.math.clamp(b.tint.r, 0.0, 1.0);
        const tg: f32 = std.math.clamp(b.tint.g, 0.0, 1.0);
        const tb: f32 = std.math.clamp(b.tint.b, 0.0, 1.0);
        const ta: f32 = std.math.clamp(b.tint.a, 0.0, 1.0);

        // Cover-crop window (defaults to the full source).
        const cw: f32 = if (b.src_crop_w > 0) @min(b.src_crop_w, @as(f32, @floatFromInt(sw))) else @as(f32, @floatFromInt(sw));
        const ch: f32 = if (b.src_crop_h > 0) @min(b.src_crop_h, @as(f32, @floatFromInt(sh))) else @as(f32, @floatFromInt(sh));
        const cx0: f32 = std.math.clamp(b.src_x, 0.0, @as(f32, @floatFromInt(sw)) - cw);
        const cy0: f32 = std.math.clamp(b.src_y, 0.0, @as(f32, @floatFromInt(sh)) - ch);

        const r_max = @min(b.w / 2.0, b.h / 2.0);
        const radius = @min(b.radius, r_max);
        const r_sq = radius * radius;

        var y: i32 = y0;
        while (y < y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            if (py < b.clip.y or py >= b.clip.y + b.clip.h) continue;
            const row_off = @as(usize, @intCast(y)) * self.stride;
            // Nearest source row within the crop window.
            const sy: usize = @min(sh - 1, @as(usize, @intFromFloat(cy0 + (py - b.y) * ch / b.h)));

            var x: i32 = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                if (px < b.clip.x or px >= b.clip.x + b.clip.w) continue;
                if (radius > 0) {
                    var in_corner = false;
                    var cx: f32 = 0;
                    var cy: f32 = 0;
                    if (px < b.x + radius and py < b.y + radius) {
                        in_corner = true;
                        cx = b.x + radius;
                        cy = b.y + radius;
                    } else if (px > b.x + b.w - radius and py < b.y + radius) {
                        in_corner = true;
                        cx = b.x + b.w - radius;
                        cy = b.y + radius;
                    } else if (px < b.x + radius and py > b.y + b.h - radius) {
                        in_corner = true;
                        cx = b.x + radius;
                        cy = b.y + b.h - radius;
                    } else if (px > b.x + b.w - radius and py > b.y + b.h - radius) {
                        in_corner = true;
                        cx = b.x + b.w - radius;
                        cy = b.y + b.h - radius;
                    }
                    if (in_corner) {
                        const dx = px - cx;
                        const dy = py - cy;
                        if (dx * dx + dy * dy > r_sq) continue;
                    }
                }
                const sx: usize = @min(sw - 1, @as(usize, @intFromFloat(cx0 + (px - b.x) * cw / b.w)));
                const src_off = @as(usize, b.pool_offset) + (sy * sw + sx) * 4;
                if (src_off + 4 > pixels.len) continue;
                var sr: u32 = pixels[src_off];
                var sg: u32 = pixels[src_off + 1];
                var sb: u32 = pixels[src_off + 2];
                var sa: u32 = pixels[src_off + 3];
                if (b.gray) {
                    const luma = (sr * 77 + sg * 150 + sb * 29) >> 8;
                    sr = luma;
                    sg = luma;
                    sb = luma;
                }
                // Straight-alpha over opaque fast path matches quads/glyphs.
                sa = @intFromFloat(@as(f32, @floatFromInt(sa)) * ta);
                sr = @intFromFloat(@as(f32, @floatFromInt(sr)) * tr);
                sg = @intFromFloat(@as(f32, @floatFromInt(sg)) * tg);
                sb = @intFromFloat(@as(f32, @floatFromInt(sb)) * tb);
                if (sa == 0) continue;
                const off = row_off + @as(usize, @intCast(x)) * 4;
                if (off + 4 > self.pixels.len) continue;
                if (sa == 255 and ta >= 1.0) {
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

    fn packColor(self: Target, c: Color) u32 {
        const r: u32 = @intFromFloat(std.math.clamp(c.r * 255.0, 0.0, 255.0));
        const g: u32 = @intFromFloat(std.math.clamp(c.g * 255.0, 0.0, 255.0));
        const b: u32 = @intFromFloat(std.math.clamp(c.b * 255.0, 0.0, 255.0));
        const a: u32 = @intFromFloat(std.math.clamp(c.a * 255.0, 0.0, 255.0));

        // NOTE: WL_SHM_FORMAT_ARGB8888 is the u32 value 0xAARRGGBB, which on
        // little-endian lands in memory as [B, G, R, A] — the same byte order
        // as BGRA. The old `.argb32` packing wrote [A, R, G, B] instead, which
        // put blue in the alpha byte: the dark theme bg (~7% "alpha") turned
        // nearly transparent and translucent blobs rendered nearly opaque.
        return switch (self.format) {
            .bgra32 => (a << 24) | (r << 16) | (g << 8) | b,
            .rgba32 => (a << 24) | (b << 16) | (g << 8) | r,
            .argb32 => (a << 24) | (r << 16) | (g << 8) | b,
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
                self.pixels[off + 0] = @truncate(b);
                self.pixels[off + 1] = @truncate(g);
                self.pixels[off + 2] = @truncate(r);
                self.pixels[off + 3] = @truncate(a);
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
                .b = self.pixels[off + 0],
                .g = self.pixels[off + 1],
                .r = self.pixels[off + 2],
                .a = self.pixels[off + 3],
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

test "software argb32 matches wayland byte order" {
    var buf: [4 * 4 * 4]u8 = undefined;
    const target = Target.init(&buf, 4, 4, .argb32);

    // theme.bg #0e0e13 opaque must land alpha in the last byte, otherwise
    // Wayland shows the window as transparent.
    target.clear(Color.hex(0x0e0e13));
    try std.testing.expectEqual(@as(u8, 0x13), buf[0]); // b
    try std.testing.expectEqual(@as(u8, 0x0e), buf[1]); // g
    try std.testing.expectEqual(@as(u8, 0x0e), buf[2]); // r
    try std.testing.expectEqual(@as(u8, 255), buf[3]); // a

    // Semi-transparent white over black: alpha blends, byte order stays.
    target.clear(Color.hex(0x000000));
    target.drawQuad(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .color = Color.rgba(1.0, 1.0, 1.0, 0.5),
    });
    try std.testing.expect(buf[0] >= 126 and buf[0] <= 129);
    try std.testing.expectEqual(@as(u8, 255), buf[3]);
}

test "software ring honors radius" {
    var buf: [12 * 12 * 4]u8 = undefined;
    const target = Target.init(&buf, 12, 12, .rgba32);
    target.clear(Color.hex(0x000000));
    target.drawQuad(.{
        .x = 0,
        .y = 0,
        .w = 12,
        .h = 12,
        .radius = 5,
        .border_width = 2,
        .color = Color.hex(0xFFFFFF),
    });
    const at = struct {
        fn pixel(pixels: []u8, x: usize, y: usize) u8 {
            return pixels[(y * 12 + x) * 4];
        }
    }.pixel;
    // Corner outside the rounded outline stays empty...
    try std.testing.expectEqual(@as(u8, 0), at(&buf, 0, 0));
    // ...edge band paints...
    try std.testing.expectEqual(@as(u8, 255), at(&buf, 6, 1));
    try std.testing.expectEqual(@as(u8, 255), at(&buf, 1, 6));
    // ...and the interior hole stays empty.
    try std.testing.expectEqual(@as(u8, 0), at(&buf, 6, 6));
}

test "software glyph blit respects coverage and clip" {
    var buf: [6 * 6 * 4]u8 = undefined;
    const target = Target.init(&buf, 6, 6, .rgba32);
    target.clear(Color.hex(0x000000));

    // 2x2 block: only the diagonal covers.
    const coverage = [_]u8{ 255, 0, 0, 255 };
    const white = Color.hex(0xFFFFFF);
    target.drawGlyph(.{
        .x = 1,
        .y = 1,
        .w = 2,
        .h = 2,
        .color = white,
        .atlas_offset = 0,
        .clip = .{ .x = 0, .y = 0, .w = 6, .h = 6 },
    }, &coverage);

    // (1,1) and (2,2) covered; (2,1) and (1,2) stay black.
    try std.testing.expectEqual(@as(u8, 255), buf[(1 * 6 + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0), buf[(1 * 6 + 2) * 4]);
    try std.testing.expectEqual(@as(u8, 0), buf[(2 * 6 + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 255), buf[(2 * 6 + 2) * 4]);

    // Same glyph clipped to the left column only: (2,2) must not paint.
    target.clear(Color.hex(0x000000));
    target.drawGlyph(.{
        .x = 1,
        .y = 1,
        .w = 2,
        .h = 2,
        .color = white,
        .atlas_offset = 0,
        .clip = .{ .x = 0, .y = 0, .w = 2, .h = 6 },
    }, &coverage);
    try std.testing.expectEqual(@as(u8, 255), buf[(1 * 6 + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0), buf[(2 * 6 + 2) * 4]);

    // Stale atlas offsets read nothing and never crash.
    target.drawGlyph(.{
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .color = white,
        .atlas_offset = 9999,
        .clip = .{ .x = 0, .y = 0, .w = 6, .h = 6 },
    }, &coverage);
}

test "software gradient quad lerps left to right" {
    var buf: [8 * 1 * 4]u8 = undefined;
    const target = Target.init(&buf, 8, 1, .rgba32);
    target.clear(Color.hex(0x000000));
    target.drawQuad(.{
        .x = 0,
        .y = 0,
        .w = 8,
        .h = 1,
        .color = Color.hex(0x000000),
        .gradient_to = Color.hex(0xFFFFFF),
    });
    // Left edge near black, right edge near white, middle between.
    try std.testing.expect(buf[0] < 48);
    try std.testing.expect(buf[(7 * 4)] > 200);
    const mid = buf[4 * 4];
    try std.testing.expect(mid > 90 and mid < 170);
}

test "software image blit samples, crops, tints, and grays" {
    // 2x2 source: red, green / blue, white (RGBA).
    const src = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    var buf: [4 * 4 * 4]u8 = undefined;
    const target = Target.init(&buf, 4, 4, .rgba32);
    const full_clip = core.Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };

    // 1:1 identity blit.
    target.clear(Color.hex(0x000000));
    target.drawImage(.{
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .clip = full_clip,
    }, &src);
    try std.testing.expectEqual(@as(u8, 255), buf[0]); // red
    try std.testing.expectEqual(@as(u8, 255), buf[1 * 4 + 1]); // green
    try std.testing.expectEqual(@as(u8, 255), buf[(1 * 4 + 0) * 4 + 2]); // blue
    try std.testing.expectEqual(@as(u8, 255), buf[(1 * 4 + 1) * 4]); // white

    // 2x upscale: nearest neighbor doubles pixels.
    target.clear(Color.hex(0x000000));
    target.drawImage(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .clip = full_clip,
    }, &src);
    try std.testing.expectEqual(@as(u8, 255), buf[0]);
    try std.testing.expectEqual(@as(u8, 255), buf[1 * 4]);
    try std.testing.expectEqual(@as(u8, 255), buf[(2 * 4 + 2) * 4 + 2]); // blue block

    // Cover crop: right half of the source only.
    target.clear(Color.hex(0x000000));
    target.drawImage(.{
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .src_x = 1,
        .src_y = 0,
        .src_crop_w = 1,
        .src_crop_h = 2,
        .clip = full_clip,
    }, &src);
    try std.testing.expectEqual(@as(u8, 255), buf[1]); // green column
    try std.testing.expectEqual(@as(u8, 255), buf[(1 * 4) * 4]); // white column

    // Grayscale: red -> luma ~76 (1:1 sampling).
    target.clear(Color.hex(0x000000));
    target.drawImage(.{
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .gray = true,
        .clip = full_clip,
    }, &src);
    try std.testing.expect(buf[0] > 70 and buf[0] < 85);
    try std.testing.expectEqual(buf[0], buf[1]);
    try std.testing.expectEqual(buf[0], buf[2]);

    // Stale pool offsets read nothing and never crash.
    target.drawImage(.{
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .pool_offset = 9999,
        .src_w = 2,
        .src_h = 2,
        .clip = full_clip,
    }, &src);
}
