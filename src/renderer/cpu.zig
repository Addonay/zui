//! CPU rasterizer for GPUI scenes: headless rendering, snapshot tests and a software fallback.
//! The fragment math is ported from gpui_wgpu/src/shaders.wgsl and matches the GPU pixels:
//! composite in sRGB-encoded values, paths resolved from 4x MSAA. The canvas holds premultiplied
//! colors (what wl_shm ARGB8888 and X11 32-bit pixels mean), so a transparent window needs no
//! conversion on present: the clear is premultiplied, and `over_straight` is the premultiplied
//! over operator once the canvas is read as premultiplied. For opaque windows alpha is 1 and
//! nothing changes. Fills are SIMD over 4 pixels; interior pixels of rounded or
//! bordered quads skip the SDF, as the shader's fast path does.
const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const atlas = @import("../atlas.zig");
const scene = @import("../scene.zig");
const testing = std.testing;

const Bounds = geometry.Bounds;
const Corners = geometry.Corners;
const ScaledPixels = geometry.ScaledPixels;
const Scene = scene.Scene;
const Quad = scene.Quad;
const Shadow = scene.Shadow;
const Underline = scene.Underline;
const MonochromeSprite = scene.MonochromeSprite;
const SubpixelSprite = scene.SubpixelSprite;
const PolychromeSprite = scene.PolychromeSprite;
const TransformationMatrix = scene.TransformationMatrix;
const Hsla = color.Hsla;
const Background = color.Background;
const BackgroundTag = color.BackgroundTag;
const CpuAtlas = atlas.CpuAtlas;
const CpuTexture = atlas.CpuTexture;
const AtlasTile = atlas.AtlasTile;

/// Byte order of a framebuffer.
pub const PixelFormat = enum { rgba8, bgra8 };

/// A borrowed pixel buffer. Row `y` starts at byte `y * stride`; `stride` is in bytes.
pub const Framebuffer = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
};

const F4 = @Vector(4, f32);
const B4 = @Vector(4, bool);

/// GPUI's `M_PI_F`, which is deliberately not the exact value of pi.
const PI: f32 = 3.1415926;
const SQRT_HALF: f32 = 0.70710678;
const zero4: F4 = @splat(0);
const one4: F4 = @splat(1);
const lane_offsets: F4 = .{ 0.5, 1.5, 2.5, 3.5 };
/// Coverage sample positions of the 4x MSAA pattern used for paths, relative to the pixel corner.
const msaa_offsets = [4][2]f32{ .{ 0.375, 0.125 }, .{ 0.875, 0.375 }, .{ 0.125, 0.625 }, .{ 0.625, 0.875 } };

/// Sprite contrast and gamma settings with the renderer defaults (gamma 1.8, enhanced contrast 1.0 / 0.5).
const grayscale_enhanced_contrast: f32 = 1.0;
const subpixel_enhanced_contrast: f32 = 0.5;
const gamma_ratios: [4]f32 = gamma_correction_ratios(1.8);

inline fn s4(x: f32) F4 {
    return @splat(x);
}

inline fn sat(v: F4) F4 {
    return @min(@max(v, zero4), one4);
}

inline fn sat1(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

inline fn vlen(x: F4, y: F4) F4 {
    return @sqrt(x * x + y * y);
}

/// Pixel x coordinates (pixel centers) of the 4 lanes starting at pixel `x0`.
inline fn x_lanes(x0: usize) F4 {
    return s4(@floatFromInt(x0)) + lane_offsets;
}

/// Port of get_gamma_correction_ratios from gpui/src/platform.rs for gamma values 1.0..2.2.
fn gamma_correction_ratios(gamma: f64) [4]f32 {
    const table = [13][4]f64{
        .{ 0.0000, 0.0000, 0.0000, 0.0000 },
        .{ 0.0166, -0.0807, 0.2227, -0.0751 },
        .{ 0.0350, -0.1760, 0.4325, -0.1370 },
        .{ 0.0543, -0.2821, 0.6302, -0.1876 },
        .{ 0.0739, -0.3963, 0.8167, -0.2287 },
        .{ 0.0933, -0.5161, 0.9926, -0.2616 },
        .{ 0.1121, -0.6395, 1.1588, -0.2877 },
        .{ 0.1300, -0.7649, 1.3159, -0.3080 },
        .{ 0.1469, -0.8911, 1.4644, -0.3234 },
        .{ 0.1627, -1.0170, 1.6051, -0.3347 },
        .{ 0.1773, -1.1420, 1.7385, -0.3426 },
        .{ 0.1908, -1.2652, 1.8650, -0.3476 },
        .{ 0.2031, -1.3864, 1.9851, -0.3501 },
    };
    const norm13: f64 = (65536.0 / (255.0 * 255.0)) * 4.0;
    const norm24: f64 = (256.0 / 255.0) * 4.0;
    const index: usize = @intFromFloat(@round(gamma * 10.0) - 10.0);
    const r = table[index];
    return .{
        @floatCast(r[0] / 4.0 * norm13),
        @floatCast(r[1] / 4.0 * norm24),
        @floatCast(r[2] / 4.0 * norm13),
        @floatCast(r[3] / 4.0 * norm24),
    };
}

// ---------------------------------------------------------------------------
// Color conversions (shaders.wgsl)
// ---------------------------------------------------------------------------

/// Hsla to RGBA as in `hsla_to_rgba` of shaders.wgsl. No clamping, no transfer function.
fn hsla_to_rgba(c: Hsla) [4]f32 {
    const h = c.h * 6.0;
    const chroma = (1.0 - @abs(2.0 * c.l - 1.0)) * c.s;
    const x = chroma * (1.0 - @abs(@rem(h, 2.0) - 1.0));
    const m = c.l - chroma / 2.0;
    var rgb = [3]f32{ m, m, m };
    if (h >= 0.0 and h < 1.0) {
        rgb[0] += chroma;
        rgb[1] += x;
    } else if (h >= 1.0 and h < 2.0) {
        rgb[0] += x;
        rgb[1] += chroma;
    } else if (h >= 2.0 and h < 3.0) {
        rgb[1] += chroma;
        rgb[2] += x;
    } else if (h >= 3.0 and h < 4.0) {
        rgb[1] += x;
        rgb[2] += chroma;
    } else if (h >= 4.0 and h < 5.0) {
        rgb[0] += x;
        rgb[2] += chroma;
    } else {
        rgb[0] += chroma;
        rgb[2] += x;
    }
    return .{ rgb[0], rgb[1], rgb[2], c.a };
}

fn linear_to_srgb_scalar(v: f32) f32 {
    if (v < 0.0031308) return v * 12.92;
    return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

fn linear_srgb_to_oklab(c: [4]f32) [4]f32 {
    const l = 0.4122214708 * c[0] + 0.5363325363 * c[1] + 0.0514459929 * c[2];
    const m = 0.2119034982 * c[0] + 0.6806995451 * c[1] + 0.1073969566 * c[2];
    const s = 0.0883024619 * c[0] + 0.2817188376 * c[1] + 0.6299787005 * c[2];
    const l_ = std.math.pow(f32, l, 1.0 / 3.0);
    const m_ = std.math.pow(f32, m, 1.0 / 3.0);
    const s_ = std.math.pow(f32, s, 1.0 / 3.0);
    return .{
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
        c[3],
    };
}

fn srgb_to_linear_scalar(v: f32) f32 {
    if (v < 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

const srgb_lut_size = 4096;
/// `srgb_to_linear` sampled on a uniform grid; linear interpolation error is below 1e-7.
const srgb_lut: [srgb_lut_size + 1]f32 = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [srgb_lut_size + 1]f32 = undefined;
    for (0..srgb_lut_size + 1) |i| {
        table[i] = srgb_to_linear_scalar(@as(f32, @floatFromInt(i)) / srgb_lut_size);
    }
    break :blk table;
};

/// `srgb_to_linear` for the lanes of a vector of pixels (values outside [0, 1] are clamped).
fn srgb_to_linear4(v: F4) F4 {
    const finite = @select(f32, v > zero4, v, zero4);
    const x: [4]f32 = @min(finite, one4) * s4(srgb_lut_size);
    var out: [4]f32 = undefined;
    for (0..4) |i| {
        const f = @min(x[i], srgb_lut_size - 1);
        const base = @floor(f);
        const idx: usize = @intFromFloat(base);
        const frac = f - base;
        out[i] = srgb_lut[idx] + (srgb_lut[idx + 1] - srgb_lut[idx]) * frac;
    }
    return out;
}

/// `oklab_to_linear_srgb` on channel vectors (`ch[3]` is alpha and passes through).
fn oklab_to_linear4(ch: *[4]F4) void {
    const L = ch[0];
    const A = ch[1];
    const B = ch[2];
    const l_ = L + s4(0.3963377774) * A + s4(0.2158037573) * B;
    const m_ = L - s4(0.1055613458) * A - s4(0.0638541728) * B;
    const s_ = L - s4(0.0894841775) * A - s4(1.2914855480) * B;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    ch[0] = s4(4.0767416621) * l - s4(3.3077115913) * m + s4(0.2309699292) * s;
    ch[1] = s4(-1.2684380046) * l + s4(2.6097574011) * m - s4(0.3413193965) * s;
    ch[2] = s4(-0.0041960863) * l - s4(0.7034186147) * m + s4(1.7076147010) * s;
}

/// Straight RGBA lanes: one color per pixel, alpha included.
const Rgba4 = struct {
    r: F4,
    g: F4,
    b: F4,
    a: F4,

    inline fn splat(c: [4]f32) Rgba4 {
        return .{ .r = s4(c[0]), .g = s4(c[1]), .b = s4(c[2]), .a = s4(c[3]) };
    }
};

// ---------------------------------------------------------------------------
// Backgrounds (prepare_gradient_color / gradient_color in shaders.wgsl)
// ---------------------------------------------------------------------------

/// Per-primitive background constants; per-pixel evaluation is in `background_lanes`.
const BgPrep = struct {
    tag: BackgroundTag = .solid,
    /// Solid color, or the pattern color.
    solid: [4]f32 = .{ 0, 0, 0, 0 },
    /// Gradient stops, already transformed into the working space of `oklab` or sRGB.
    stop: [2][4]f32 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } },
    stop_pct: [2]f32 = .{ 0, 0 },
    oklab: bool = false,
    size: [2]f32 = .{ 0, 0 },
    dir: [2]f32 = .{ 0, 0 },
    dir_len: f32 = 1,
    long_x: bool = true,
    /// Pattern height or checkerboard cell size.
    param: f32 = 0,
    cos: f32 = 1,
    sin: f32 = 0,
    period: f32 = 1,
    half_gap: f32 = 0,

    fn init(bg: Background, w: f32, h: f32) BgPrep {
        var p: BgPrep = .{ .tag = bg.tag, .solid = hsla_to_rgba(bg.solid), .size = .{ w, h } };
        switch (bg.tag) {
            .solid => {},
            .linear_gradient => {
                // -90 degrees to match the CSS gradient angle.
                const radians = (@rem(bg.gradient_angle_or_pattern_height, 360.0) - 90.0) * PI / 180.0;
                var dir = [2]f32{ @cos(radians), @sin(radians) };
                if (w > h) {
                    dir[1] *= h / w;
                } else {
                    dir[0] *= w / h;
                }
                p.dir = dir;
                p.dir_len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1]);
                p.long_x = @abs(dir[0]) > @abs(dir[1]);
                p.stop_pct = .{ bg.colors[0].percentage, bg.colors[1].percentage };
                p.oklab = bg.color_space == .oklab;
                for (0..2) |i| {
                    const c = hsla_to_rgba(bg.colors[i].color);
                    if (p.oklab) {
                        p.stop[i] = linear_srgb_to_oklab(c);
                    } else {
                        p.stop[i] = .{ linear_to_srgb_scalar(c[0]), linear_to_srgb_scalar(c[1]), linear_to_srgb_scalar(c[2]), c[3] };
                    }
                }
            },
            .pattern_slash => {
                const g = bg.gradient_angle_or_pattern_height;
                const pattern_width = (g / 65535.0) / 255.0;
                const pattern_interval = @rem(g, 65535.0) / 255.0;
                const pattern_height = pattern_width + pattern_interval;
                const stripe = PI / 4.0;
                p.param = pattern_height;
                p.cos = @cos(stripe);
                p.sin = @sin(stripe);
                p.period = pattern_height * @sin(stripe);
                p.half_gap = p.period * (pattern_width / pattern_height) / 2.0;
            },
            .checkerboard => p.param = bg.gradient_angle_or_pattern_height,
        }
        return p;
    }
};

fn background_lanes(bp: *const BgPrep, ox: f32, oy: f32, x: F4, py: f32) Rgba4 {
    return switch (bp.tag) {
        .solid => Rgba4.splat(bp.solid),
        .linear_gradient => gradient_lanes(bp, ox, oy, x, py),
        .pattern_slash => pattern_lanes(bp, ox, oy, x, py),
        .checkerboard => checker_lanes(bp, ox, oy, x, py),
    };
}

fn gradient_lanes(bp: *const BgPrep, ox: f32, oy: f32, x: F4, py: f32) Rgba4 {
    const hw = bp.size[0] * 0.5;
    const hh = bp.size[1] * 0.5;
    const ctp_x = x - s4(ox + hw);
    const ctp_y = py - (oy + hh);
    var t = (ctp_x * s4(bp.dir[0]) + s4(ctp_y * bp.dir[1])) / s4(bp.dir_len);
    if (bp.long_x) {
        t = (t + s4(hw)) / s4(bp.size[0]);
    } else {
        t = (t + s4(hh)) / s4(bp.size[1]);
    }
    t = (t - s4(bp.stop_pct[0])) / s4(bp.stop_pct[1] - bp.stop_pct[0]);
    t = sat(t);
    const inv_t = one4 - t;
    var ch: [4]F4 = undefined;
    for (0..4) |k| ch[k] = s4(bp.stop[0][k]) * inv_t + s4(bp.stop[1][k]) * t;
    if (bp.oklab) {
        oklab_to_linear4(&ch);
    } else {
        ch[0] = srgb_to_linear4(ch[0]);
        ch[1] = srgb_to_linear4(ch[1]);
        ch[2] = srgb_to_linear4(ch[2]);
    }
    return .{ .r = ch[0], .g = ch[1], .b = ch[2], .a = ch[3] };
}

fn pattern_lanes(bp: *const BgPrep, ox: f32, oy: f32, x: F4, py: f32) Rgba4 {
    const rel_x = x - s4(ox);
    const rel_y = py - oy;
    const rotated_x = s4(bp.cos) * rel_x + s4(bp.sin * rel_y);
    const pattern = @rem(rotated_x, s4(bp.period));
    const distance = @min(pattern, s4(bp.period) - pattern) - s4(bp.half_gap);
    var c = Rgba4.splat(bp.solid);
    c.a = c.a * sat(s4(0.5) - distance);
    return c;
}

fn checker_lanes(bp: *const BgPrep, ox: f32, oy: f32, x: F4, py: f32) Rgba4 {
    const size = s4(bp.param);
    const rel_x = x - s4(ox);
    const rel_y = s4(py - oy);
    const xi = @floor(rel_x / size);
    const yi = @floor(rel_y / size);
    const should = @rem(xi + yi, s4(2));
    var c = Rgba4.splat(bp.solid);
    c.a = c.a * sat(should);
    return c;
}

// ---------------------------------------------------------------------------
// Framebuffer access and blending
// ---------------------------------------------------------------------------

/// Validated view of a framebuffer; pixels are read and written as straight RGBA in [0, 1].
const Target = struct {
    bytes: []u8,
    width: usize,
    height: usize,
    stride: usize,
    bgra: bool,
    /// Rows `[y0, y1)` this target may write; bands of one frame are disjoint.
    y0: usize = 0,
    y1: usize = 0,

    fn init(fb: Framebuffer) ?Target {
        const w: usize = fb.width;
        const h: usize = fb.height;
        const stride: usize = fb.stride;
        if (w == 0 or h == 0 or stride < w * 4) return null;
        if (fb.pixels.len < (h - 1) * stride + w * 4) return null;
        return .{ .bytes = fb.pixels, .width = w, .height = h, .stride = stride, .bgra = fb.format == .bgra8, .y1 = h };
    }

    fn rows(self: Target, y0: usize, y1: usize) Target {
        var band = self;
        band.y0 = y0;
        band.y1 = y1;
        return band;
    }

    inline fn offset(self: Target, x: usize, y: usize) usize {
        return y * self.stride + x * 4;
    }

    inline fn load(self: Target, off: usize) F4 {
        const p = self.bytes[off..][0..4];
        const r = unorm(p[if (self.bgra) 2 else 0]);
        const b = unorm(p[if (self.bgra) 0 else 2]);
        return .{ r, unorm(p[1]), b, unorm(p[3]) };
    }

    inline fn store(self: Target, off: usize, c: F4) void {
        self.bytes[off..][0..4].* = self.pack(.{ c[0], c[1], c[2], c[3] });
    }

    inline fn pack(self: Target, c: [4]f32) [4]u8 {
        const r = to_u8(c[0]);
        const g = to_u8(c[1]);
        const b = to_u8(c[2]);
        const a = to_u8(c[3]);
        return if (self.bgra) .{ b, g, r, a } else .{ r, g, b, a };
    }
};

inline fn unorm(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) * (1.0 / 255.0);
}

inline fn to_u8(v: f32) u8 {
    if (!(v > 0)) return 0;
    if (v >= 1) return 255;
    return @intFromFloat(v * 255.0 + 0.5);
}

/// Converts a straight RGBA color to the premultiplied form the canvas stores. Opaque colors
/// (alpha 1) are unchanged, so opaque windows clear to the same pixels as before.
pub fn premultiply(c: [4]f32) [4]f32 {
    return .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
}

/// Source-over of a straight color `c` onto `d` (`d` premultiplied, as the canvas is; see `premultiply`).
inline fn over_straight(d: F4, c: F4) F4 {
    const a = c[3];
    const src = F4{ c[0] * a, c[1] * a, c[2] * a, a };
    return src + d * s4(1 - a);
}

/// Source-over of a premultiplied color `p` onto `d`.
inline fn over_premul(d: F4, p: F4) F4 {
    return p + d * s4(1 - p[3]);
}

inline fn blend_px(t: Target, x: usize, y: usize, c: F4) void {
    if (!(c[3] > 0)) return;
    const off = t.offset(x, y);
    t.store(off, over_straight(t.load(off), c));
}

const F16 = @Vector(16, f32);
const U16 = @Vector(16, u8);

/// Over-blend coefficients for 4 pixels in byte-slot order: out = p + dst * inv, per 16 channel bytes.
const Blend16 = struct {
    p: F16,
    inv: F16,

    /// Builds the coefficients from straight colors, one lane per pixel.
    inline fn from(c: Rgba4, bgra: bool) Blend16 {
        const r = if (bgra) c.b else c.r;
        const b = if (bgra) c.r else c.b;
        const a = c.a;
        const pr = r * a;
        const pg = c.g * a;
        const pb = b * a;
        // Interleave to (r, g, b, a) per pixel.
        // Negative shuffle indices select from the second operand: ~k is its element k.
        const rg = @shuffle(f32, pr, pg, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
        const ba = @shuffle(f32, pb, a, [8]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
        const p = @shuffle(f32, rg, ba, [16]i32{ 0, 1, -1, -2, 2, 3, -3, -4, 4, 5, -5, -6, 6, 7, -7, -8 });
        const alpha16 = @shuffle(f32, a, undefined, [16]i32{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 });
        return .{ .p = p, .inv = @as(F16, @splat(1)) - alpha16 };
    }
};

/// Blends the 4 pixels stored at byte offset `off` (16 bytes, one row segment) with `bl`.
inline fn blend4(t: Target, off: usize, bl: Blend16) void {
    const dst: U16 = t.bytes[off..][0..16].*;
    const dst_f: F16 = @floatFromInt(dst);
    const out = bl.p + dst_f * @as(F16, @splat(1.0 / 255.0)) * bl.inv;
    // NaN compares false, so it is replaced by 0 before the float-to-int conversion.
    const zero16: F16 = @splat(0);
    const finite = @select(f32, out > zero16, out, zero16);
    const clamped = @min(finite, @as(F16, @splat(1)));
    const scaled: @Vector(16, u32) = @intFromFloat(clamped * @as(F16, @splat(255)) + @as(F16, @splat(0.5)));
    const bytes: U16 = @truncate(scaled);
    t.bytes[off..][0..16].* = bytes;
}

/// Blends `n` pixels (n <= 4) of straight colors starting at pixel (x0, y).
inline fn blend_lanes(t: Target, y: usize, x0: usize, n: usize, c: Rgba4) void {
    if (n == 4) {
        blend4(t, t.offset(x0, y), Blend16.from(c, t.bgra));
        return;
    }
    const ra: [4]f32 = c.r;
    const ga: [4]f32 = c.g;
    const ba: [4]f32 = c.b;
    const aa: [4]f32 = c.a;
    for (0..n) |i| blend_px(t, x0 + i, y, .{ ra[i], ga[i], ba[i], aa[i] });
}

fn fill_opaque(t: Target, y: usize, x0: usize, x1: usize, c: [4]f32) void {
    const px = t.pack(c);
    var pattern: [16]u8 = undefined;
    for (0..4) |i| pattern[i * 4 ..][0..4].* = px;
    const pattern_v: U16 = pattern;
    var x = x0;
    while (x + 4 <= x1) : (x += 4) t.bytes[t.offset(x, y)..][0..16].* = pattern_v;
    while (x < x1) : (x += 1) t.bytes[t.offset(x, y)..][0..4].* = px;
}

/// Fills pixels [x0, x1) of row `y` with a background (solid, gradient or pattern).
fn fill_span(t: Target, y: usize, x0: usize, x1: usize, bp: *const BgPrep, ox: f32, oy: f32) void {
    if (bp.tag == .solid) {
        const c = bp.solid;
        if (!(c[3] > 0)) return;
        if (c[3] >= 1) {
            fill_opaque(t, y, x0, x1, c);
            return;
        }
        const bl = Blend16.from(Rgba4.splat(c), t.bgra);
        var x = x0;
        while (x + 4 <= x1) : (x += 4) blend4(t, t.offset(x, y), bl);
        while (x < x1) : (x += 1) blend_px(t, x, y, .{ c[0], c[1], c[2], c[3] });
        return;
    }
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    var x = x0;
    while (x < x1) : (x += 4) {
        const n = @min(4, x1 - x);
        blend_lanes(t, y, x, n, background_lanes(bp, ox, oy, x_lanes(x), py));
    }
}

/// Pixel index range `[a, b)` whose centers lie in `[lo, hi)`, clamped to `[0, limit)`.
fn axis_range(lo: f32, hi: f32, clip_lo: f32, clip_hi: f32, limit: usize) ?[2]usize {
    const a = @max(lo, clip_lo);
    const b = @min(hi, clip_hi);
    if (!(b > a)) return null;
    const lim: f32 = @floatFromInt(limit);
    const first = std.math.clamp(@ceil(a - 0.5), 0, lim);
    const end = std.math.clamp(@ceil(b - 0.5), 0, lim);
    if (!(end > first)) return null;
    const x0: usize = @intFromFloat(first);
    const x1: usize = @intFromFloat(end);
    return .{ x0, x1 };
}

const PixelRect = struct {
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
};

/// Pixels whose centers lie inside both `bounds` and `clip`, inside the framebuffer and the target's band.
fn rect_pixels(bounds: Bounds(ScaledPixels), clip: Bounds(ScaledPixels), t: Target) ?PixelRect {
    const xs = axis_range(bounds.origin.x, bounds.origin.x + bounds.size.width, clip.origin.x, clip.origin.x + clip.size.width, t.width) orelse return null;
    const ys = axis_range(bounds.origin.y, bounds.origin.y + bounds.size.height, clip.origin.y, clip.origin.y + clip.size.height, t.height) orelse return null;
    const y0 = @max(ys[0], t.y0);
    const y1 = @min(ys[1], t.y1);
    if (!(y1 > y0)) return null;
    return .{ .x0 = xs[0], .x1 = xs[1], .y0 = y0, .y1 = y1 };
}

// ---------------------------------------------------------------------------
// Rounded-rectangle SDF (quad_sdf / quad_sdf_impl / pick_corner_radius)
// ---------------------------------------------------------------------------

const RRect = struct {
    ox: f32,
    oy: f32,
    w: f32,
    h: f32,
    hw: f32,
    hh: f32,
    cx: f32,
    cy: f32,
    tl: f32,
    tr: f32,
    br: f32,
    bl: f32,

    fn init(bounds: Bounds(ScaledPixels), radii: Corners(ScaledPixels)) RRect {
        const hw = bounds.size.width * 0.5;
        const hh = bounds.size.height * 0.5;
        return .{
            .ox = bounds.origin.x,
            .oy = bounds.origin.y,
            .w = bounds.size.width,
            .h = bounds.size.height,
            .hw = hw,
            .hh = hh,
            .cx = bounds.origin.x + hw,
            .cy = bounds.origin.y + hh,
            .tl = radii.top_left,
            .tr = radii.top_right,
            .br = radii.bottom_right,
            .bl = radii.bottom_left,
        };
    }
};

/// Radius of the corner nearest to the point, given its offset from the rect center.
inline fn pick_radius(rr: *const RRect, cxp: F4, cyp: f32) F4 {
    const left_r = if (cyp < 0) rr.tl else rr.bl;
    const right_r = if (cyp < 0) rr.tr else rr.br;
    return @select(f32, cxp < zero4, s4(left_r), s4(right_r));
}

inline fn sdf_impl(ccx: F4, ccy: F4, r: F4) F4 {
    const straight = @max(ccx, ccy);
    const rounded = vlen(@max(zero4, ccx), @max(zero4, ccy)) + @min(zero4, @max(ccx, ccy)) - r;
    return @select(f32, r == zero4, straight, rounded);
}

/// Signed distance to the rounded rect (negative inside).
fn quad_sdf(rr: *const RRect, px: F4, py: f32) F4 {
    const cxp = (px - s4(rr.ox)) - s4(rr.hw);
    const cyp = (py - rr.oy) - rr.hh;
    const r = pick_radius(rr, cxp, cyp);
    const c2x = @abs(cxp) - s4(rr.hw);
    const c2y = s4(@abs(cyp) - rr.hh);
    return sdf_impl(c2x + r, c2y + r, r);
}

// ---------------------------------------------------------------------------
// Quads (fs_quad)
// ---------------------------------------------------------------------------

const QuadGeom = struct {
    rr: RRect,
    bw_top: f32,
    bw_right: f32,
    bw_bottom: f32,
    bw_left: f32,
    dashed: bool,
    unrounded: bool,
    border: [4]f32,
    bg: BgPrep,

    fn init(q: *const Quad) QuadGeom {
        const b = q.bounds;
        const bw = q.border_widths;
        const r = q.corner_radii;
        return .{
            .rr = RRect.init(b, r),
            .bw_top = bw.top,
            .bw_right = bw.right,
            .bw_bottom = bw.bottom,
            .bw_left = bw.left,
            .dashed = q.border_style == .dashed,
            .unrounded = r.top_left == 0 and r.top_right == 0 and r.bottom_right == 0 and r.bottom_left == 0,
            .border = hsla_to_rgba(q.border_color),
            .bg = BgPrep.init(q.background, b.size.width, b.size.height),
        };
    }
};

/// Pixels of row `py` that are certainly background (no SDF needed), as an index range.
fn quad_interior(g: *const QuadGeom, py: f32, x0: usize, x1: usize) [2]usize {
    const rr = &g.rr;
    const ry = py - rr.oy;
    if (ry < g.bw_top + 1 or ry > rr.h - g.bw_bottom - 1) return .{ 0, 0 };
    // Near a rounded corner the straight edge moves inwards by the corner radius.
    var left: f32 = 0;
    var right: f32 = 0;
    if (ry < rr.tl + 1) left = @max(left, rr.tl + 1);
    if (ry > rr.h - rr.bl - 1) left = @max(left, rr.bl + 1);
    if (ry < rr.tr + 1) right = @max(right, rr.tr + 1);
    if (ry > rr.h - rr.br - 1) right = @max(right, rr.br + 1);
    const lo = @max(g.bw_left + 1, left);
    const hi = rr.w - @max(g.bw_right + 1, right);
    if (!(hi > lo)) return .{ 0, 0 };
    const a = std.math.clamp(@floor(rr.ox + lo - 0.5) + 1, @as(f32, @floatFromInt(x0)), @as(f32, @floatFromInt(x1)));
    const b = std.math.clamp(@ceil(rr.ox + hi - 0.5), @as(f32, @floatFromInt(x0)), @as(f32, @floatFromInt(x1)));
    if (!(b > a)) return .{ 0, 0 };
    return .{ @intFromFloat(a), @intFromFloat(b) };
}

fn dash_alpha(t: f32, period: f32, length: f32, velocity: f32) f32 {
    const half_period = period / 2;
    const half_length = length / 2;
    const fmod_v = t + half_period - half_length;
    const centered = (fmod_v - period * @trunc(fmod_v / period)) - half_period;
    const signed_distance = @abs(centered) - half_length;
    return sat1(0.5 - signed_distance / velocity);
}

inline fn corner_dash_velocity(dv1: f32, dv2: f32) f32 {
    if (dv1 == 0) return dv2;
    if (dv2 == 0) return dv1;
    return @min(dv1, dv2);
}

/// Alpha multiplier of a dashed border pixel; a port of the dashed branch of fs_quad.
fn dash_multiplier(g: *const QuadGeom, px: f32, py: f32) f32 {
    const rr = &g.rr;
    const point_x = px - rr.ox;
    const point_y = py - rr.oy;
    const ctp_x = point_x - rr.hw;
    const ctp_y = point_y - rr.hh;
    const size_x = rr.w;
    const size_y = rr.h;
    const radius: f32 = if (ctp_x < 0) (if (ctp_y < 0) rr.tl else rr.bl) else (if (ctp_y < 0) rr.tr else rr.br);
    const c2p_x = @abs(ctp_x) - rr.hw;
    const c2p_y = @abs(ctp_y) - rr.hh;
    const ccp_x = c2p_x + radius;
    const ccp_y = c2p_y + radius;
    const near_rounded = ccp_x >= 0 and ccp_y >= 0;

    const dash_length_per_width: f32 = 2.0;
    const dash_period_per_width: f32 = 3.0;
    const dv_numerator: f32 = 1.0 / dash_period_per_width;

    var t: f32 = 0;
    var max_t: f32 = 0;
    var dash_velocity: f32 = 0;
    if (g.unrounded) {
        const is_horizontal = ccp_x < ccp_y;
        const dashed_x = @max(g.bw_bottom, g.bw_top);
        const dashed_y = @max(g.bw_right, g.bw_left);
        const border_width = if (is_horizontal) dashed_x else dashed_y;
        dash_velocity = dv_numerator / border_width;
        t = (if (is_horizontal) point_x else point_y) * dash_velocity;
        max_t = (if (is_horizontal) size_x else size_y) * dash_velocity;
    } else {
        const r_tr = rr.tr;
        const r_br = rr.br;
        const r_bl = rr.bl;
        const r_tl = rr.tl;
        const dv_t: f32 = if (g.bw_top <= 0) 0 else dv_numerator / g.bw_top;
        const dv_r: f32 = if (g.bw_right <= 0) 0 else dv_numerator / g.bw_right;
        const dv_b: f32 = if (g.bw_bottom <= 0) 0 else dv_numerator / g.bw_bottom;
        const dv_l: f32 = if (g.bw_left <= 0) 0 else dv_numerator / g.bw_left;

        const s_t = (size_x - r_tl - r_tr) * dv_t;
        const s_r = (size_y - r_tr - r_br) * dv_r;
        const s_b = (size_x - r_br - r_bl) * dv_b;
        const s_l = (size_y - r_bl - r_tl) * dv_l;

        const cdv_tr = corner_dash_velocity(dv_t, dv_r);
        const cdv_br = corner_dash_velocity(dv_b, dv_r);
        const cdv_bl = corner_dash_velocity(dv_b, dv_l);
        const cdv_tl = corner_dash_velocity(dv_t, dv_l);

        const half_pi = PI / 2.0;
        const c_tr = r_tr * half_pi * cdv_tr;
        const c_br = r_br * half_pi * cdv_br;
        const c_bl = r_bl * half_pi * cdv_bl;
        const c_tl = r_tl * half_pi * cdv_tl;

        const upto_tr = s_t;
        const upto_r = upto_tr + c_tr;
        const upto_br = upto_r + s_r;
        const upto_b = upto_br + c_br;
        const upto_bl = upto_b + s_b;
        const upto_l = upto_bl + c_bl;
        const upto_tl = upto_l + s_l;
        max_t = upto_tl + c_tl;

        if (near_rounded) {
            const radians = std.math.atan2(ccp_y, ccp_x);
            const corner_t = radians * radius;
            if (ctp_x >= 0) {
                if (ctp_y < 0) {
                    dash_velocity = cdv_tr;
                    t = upto_r - corner_t * dash_velocity;
                } else {
                    dash_velocity = cdv_br;
                    t = upto_br + corner_t * dash_velocity;
                }
            } else {
                if (ctp_y >= 0) {
                    dash_velocity = cdv_bl;
                    t = upto_l - corner_t * dash_velocity;
                } else {
                    dash_velocity = cdv_tl;
                    t = upto_tl + corner_t * dash_velocity;
                }
            }
        } else {
            const is_horizontal = ccp_x < ccp_y;
            if (is_horizontal) {
                if (ctp_y < 0) {
                    dash_velocity = dv_t;
                    t = (point_x - r_tl) * dash_velocity;
                } else {
                    dash_velocity = dv_b;
                    t = upto_bl - (point_x - r_bl) * dash_velocity;
                }
            } else {
                if (ctp_x < 0) {
                    dash_velocity = dv_l;
                    t = upto_tl - (point_y - r_tl) * dash_velocity;
                } else {
                    dash_velocity = dv_r;
                    t = upto_r + (point_y - r_tr) * dash_velocity;
                }
            }
        }
    }

    const dash_length = dash_length_per_width / dash_period_per_width;
    // Straight borders start and end with a dash.
    if (g.unrounded) max_t -= dash_length;
    if (max_t >= 1) {
        const dash_count = @floor(max_t);
        return dash_alpha(t, max_t / dash_count, dash_length, dash_velocity);
    } else if (g.unrounded) {
        const dash_gap = max_t - dash_length;
        if (dash_gap > 0) return dash_alpha(t, dash_length + dash_gap, dash_length, dash_velocity);
    }
    return 1;
}

/// Quad color for 4 pixels, straight RGBA with coverage in alpha. Port of fs_quad after the fast path.
fn quad_lanes(g: *const QuadGeom, bgl: Rgba4, x: F4, py: f32) Rgba4 {
    const rr = &g.rr;
    const zero = zero4;
    const cxp = (x - s4(rr.ox)) - s4(rr.hw);
    const cyp = (py - rr.oy) - rr.hh;
    const top = cyp < 0;
    const radius = pick_radius(rr, cxp, cyp);

    // Border widths nearest to this point, and the reduced widths used by the inner edge.
    const bwx = @select(f32, cxp < zero, s4(g.bw_left), s4(g.bw_right));
    const bwy: f32 = if (top) g.bw_top else g.bw_bottom;
    const rbx = @select(f32, bwx == zero, s4(-0.5), bwx);
    const rby: f32 = if (bwy == 0) -0.5 else bwy;
    const rby_v = s4(rby);

    const c2px = @abs(cxp) - s4(rr.hw);
    const c2py = s4(@abs(cyp) - rr.hh);
    const ccpx = c2px + radius;
    const ccpy = c2py + radius;
    const near_rounded = (ccpx >= zero) & (ccpy >= zero);
    const sbix = c2px + rbx;
    const sbiy = c2py + rby_v;
    const beyond = (sbix > zero) | (sbiy > zero);
    const within = (sbix < s4(-0.5)) & (sbiy < s4(-0.5));
    const not_near = near_rounded == @as(B4, @splat(false));
    const fast = within & not_near;

    const outer = sdf_impl(ccpx, ccpy, radius);
    const ccp_le0 = (ccpx <= zero) | (ccpy <= zero);
    const inner1 = -@max(sbix, sbiy);
    const inner2 = s4(-1);
    const same = rbx == rby_v;
    const inner3 = -(outer + rbx);
    const ex = @max(zero, radius - rbx);
    const ey = @max(zero, radius - rby_v);
    const unit = vlen(ccpx / ex, ccpy / ey) - one4;
    const inner4 = unit * (ex + ey) * s4(-0.5);
    var inner = @select(f32, same, inner3, inner4);
    inner = @select(f32, beyond, inner2, inner);
    inner = @select(f32, ccp_le0, inner1, inner);

    const border_sdf = @max(inner, outer);
    const has_border = border_sdf < s4(0.5);

    var border_a = s4(g.border[3]);
    if (g.dashed) {
        var m = [4]f32{ 1, 1, 1, 1 };
        const hb: [4]bool = has_border;
        const xa: [4]f32 = x;
        for (0..4) |i| {
            if (hb[i]) m[i] = dash_multiplier(g, xa[i], py);
        }
        border_a = border_a * @as(F4, m);
    }

    // over(background, border), then mix towards it inside the border band.
    const bga = bgl.a;
    const inv_ba = one4 - border_a;
    const alpha_b = border_a + bga * inv_ba;
    const denom_ok = alpha_b > zero;
    const denom = @select(f32, denom_ok, alpha_b, one4);
    const blend_r = @select(f32, denom_ok, (s4(g.border[0]) * border_a + bgl.r * bga * inv_ba) / denom, zero);
    const blend_g = @select(f32, denom_ok, (s4(g.border[1]) * border_a + bgl.g * bga * inv_ba) / denom, zero);
    const blend_b = @select(f32, denom_ok, (s4(g.border[2]) * border_a + bgl.b * bga * inv_ba) / denom, zero);

    const t = @select(f32, has_border, sat(s4(0.5) - inner), zero);
    const omt = one4 - t;
    const out_r = bgl.r * omt + blend_r * t;
    const out_g = bgl.g * omt + blend_g * t;
    const out_b = bgl.b * omt + blend_b * t;
    const out_a = bga * omt + alpha_b * t;

    const coverage = @select(f32, fast, one4, sat(s4(0.5) - outer));
    return .{ .r = out_r, .g = out_g, .b = out_b, .a = out_a * coverage };
}

fn quad_edge(t: Target, y: usize, x0: usize, x1: usize, g: *const QuadGeom) void {
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    var x = x0;
    while (x < x1) : (x += 4) {
        const n = @min(4, x1 - x);
        const xv = x_lanes(x);
        const bgl = background_lanes(&g.bg, g.rr.ox, g.rr.oy, xv, py);
        blend_lanes(t, y, x, n, quad_lanes(g, bgl, xv, py));
    }
}

fn draw_quad(t: Target, q: *const Quad) void {
    const bw = q.border_widths;
    const border_visible = !q.border_color.is_transparent() and (bw.top > 0 or bw.right > 0 or bw.bottom > 0 or bw.left > 0);
    if (q.background.is_transparent() and !border_visible) return;
    const r = rect_pixels(q.bounds, q.content_mask.bounds, t) orelse return;
    const g = QuadGeom.init(q);

    const no_border = bw.top == 0 and bw.right == 0 and bw.bottom == 0 and bw.left == 0;
    if (g.unrounded and no_border) {
        for (r.y0..r.y1) |y| fill_span(t, y, r.x0, r.x1, &g.bg, g.rr.ox, g.rr.oy);
        return;
    }

    for (r.y0..r.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const inner = quad_interior(&g, py, r.x0, r.x1);
        if (inner[0] < inner[1]) {
            quad_edge(t, y, r.x0, inner[0], &g);
            fill_span(t, y, inner[0], inner[1], &g.bg, g.rr.ox, g.rr.oy);
            quad_edge(t, y, inner[1], r.x1, &g);
        } else {
            quad_edge(t, y, r.x0, r.x1, &g);
        }
    }
}

// ---------------------------------------------------------------------------
// Shadows (fs_shadow)
// ---------------------------------------------------------------------------

fn erf4(v: F4) F4 {
    const s = @select(f32, v > zero4, one4, @select(f32, v < zero4, -one4, zero4));
    const a = @abs(v);
    const r1 = one4 + (s4(0.278393) + (s4(0.230389) + (s4(0.000972) + s4(0.078108) * a) * a) * a) * a;
    const r2 = r1 * r1;
    return s - s / (r2 * r2);
}

fn gaussian(x: f32, sigma: f32) f32 {
    return @exp(-(x * x) / (2.0 * sigma * sigma)) / (@sqrt(2.0 * PI) * sigma);
}

/// Integral of a gaussian of width `sigma` over the rounded box, along x at offset `yv`.
fn blur_along_x(hw: f32, hh: f32, cxp: F4, yv: f32, sigma: f32, corner: F4) F4 {
    const delta = @min(s4(hh - @abs(yv)) - corner, zero4);
    const curved = s4(hw) - corner + @sqrt(@max(zero4, corner * corner - delta * delta));
    const k = s4(SQRT_HALF / sigma);
    return s4(0.5) * (erf4((cxp + curved) * k) - erf4((cxp - curved) * k));
}

/// Blurred coverage of the rounded box `rr` at 4 pixels (4-sample integration in y).
fn shadow_alpha(rr: *const RRect, blur: f32, px: F4, py: f32) F4 {
    if (blur == 0) return sat(s4(0.5) - quad_sdf(rr, px, py));
    const cxp = (px - s4(rr.ox)) - s4(rr.hw);
    const cyp = (py - rr.oy) - rr.hh;
    const corner = pick_radius(rr, cxp, cyp);
    const low = cyp - rr.hh;
    const high = cyp + rr.hh;
    const start = @min(@max(-3.0 * blur, low), high);
    const end = @min(@max(3.0 * blur, low), high);
    const step = (end - start) / 4.0;
    var y = start + step * 0.5;
    var alpha = zero4;
    for (0..4) |_| {
        const blur_x = blur_along_x(rr.hw, rr.hh, cxp, cyp - y, blur, corner);
        alpha += blur_x * s4(gaussian(y, blur) * step);
        y += step;
    }
    return alpha;
}

fn draw_shadow(t: Target, sh: *const Shadow) void {
    if (sh.color.a == 0) return;
    const col = hsla_to_rgba(sh.color);
    const hole = RRect.init(sh.bounds, sh.corner_radii);
    const elem = RRect.init(sh.element_bounds, sh.element_corner_radii);
    const inset = sh.inset != 0;
    // Drop shadows reach 3 sigma past the box; inset shadows live inside the element.
    const region: Bounds(ScaledPixels) = if (inset) sh.element_bounds else blk: {
        const m = 3.0 * sh.blur_radius;
        break :blk .{
            .origin = .{ .x = sh.bounds.origin.x - m, .y = sh.bounds.origin.y - m },
            .size = .{ .width = sh.bounds.size.width + 2 * m, .height = sh.bounds.size.height + 2 * m },
        };
    };
    const r = rect_pixels(region, sh.content_mask.bounds, t) orelse return;
    const c_rgb = Rgba4.splat(col);

    for (r.y0..r.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x = r.x0;
        while (x < r.x1) : (x += 4) {
            const n = @min(4, r.x1 - x);
            const xv = x_lanes(x);
            var alpha = shadow_alpha(&hole, sh.blur_radius, xv, py);
            if (inset) {
                alpha = (one4 - alpha) * sat(s4(0.5) - quad_sdf(&elem, xv, py));
            }
            var out = c_rgb;
            out.a = alpha * s4(col[3]);
            blend_lanes(t, y, x, n, out);
        }
    }
}

// ---------------------------------------------------------------------------
// Underlines (fs_underline)
// ---------------------------------------------------------------------------

fn draw_underline(t: Target, u: *const Underline) void {
    if (u.color.a == 0) return;
    const r = rect_pixels(u.bounds, u.content_mask.bounds, t) orelse return;
    const col = hsla_to_rgba(u.color);
    if (u.wavy.value == 0) {
        // blend_color(color, color.a) multiplies alpha by alpha again, as the shader does.
        const c = [4]f32{ col[0], col[1], col[2], col[3] * col[3] };
        for (r.y0..r.y1) |y| {
            for (r.x0..r.x1) |x| blend_px(t, x, y, .{ c[0], c[1], c[2], c[3] });
        }
        return;
    }

    const thickness = u.thickness;
    const size_y = u.bounds.size.height;
    const half_thickness = thickness * 0.5;
    const frequency = PI * 2.0 * thickness / size_y;
    const amplitude = (thickness * 0.8) / size_y;
    const ox = u.bounds.origin.x;
    const oy = u.bounds.origin.y;
    for (r.y0..r.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const st_y = (py - oy) / size_y - 0.5;
        var x = r.x0;
        while (x < r.x1) : (x += 4) {
            const n = @min(4, r.x1 - x);
            const st_x = (x_lanes(x) - s4(ox)) / s4(size_y);
            const angle = st_x * s4(frequency);
            const sine = @sin(angle) * s4(amplitude);
            const d_sine = @cos(angle) * s4(amplitude * frequency);
            const distance = (s4(st_y) - sine) / @sqrt(one4 + d_sine * d_sine);
            const distance_px = distance * s4(size_y);
            const from_top = distance_px - s4(half_thickness);
            const from_bottom = distance_px + s4(half_thickness);
            const alpha = sat(s4(0.5) - @max(-from_bottom, from_top));
            var out = Rgba4.splat(col);
            out.a = alpha * s4(col[3] * col[3]);
            blend_lanes(t, y, x, n, out);
        }
    }
}

// ---------------------------------------------------------------------------
// Sprites (fs_mono_sprite, fs_poly_sprite, fs_subpixel_sprite)
// ---------------------------------------------------------------------------

/// Maps device pixels into a sprite's unit square, inverting its transformation.
const SpriteXf = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    tx: f32,
    ty: f32,
    inv_det: f32,
    ox: f32,
    oy: f32,
    w: f32,
    h: f32,

    fn init(m: TransformationMatrix, bounds: Bounds(ScaledPixels)) ?SpriteXf {
        const a = m.rotation_scale[0][0];
        const b = m.rotation_scale[0][1];
        const c = m.rotation_scale[1][0];
        const d = m.rotation_scale[1][1];
        const det = a * d - b * c;
        if (det == 0 or !std.math.isFinite(det)) return null;
        return .{
            .a = a,
            .b = b,
            .c = c,
            .d = d,
            .tx = m.translation[0],
            .ty = m.translation[1],
            .inv_det = 1.0 / det,
            .ox = bounds.origin.x,
            .oy = bounds.origin.y,
            .w = bounds.size.width,
            .h = bounds.size.height,
        };
    }

    /// Device-space pixel range covered by the transformed sprite, clipped to `clip`.
    fn device_rect(self: SpriteXf, t: Target, clip: Bounds(ScaledPixels)) ?PixelRect {
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        const corners = [4][2]f32{ .{ 0, 0 }, .{ self.w, 0 }, .{ 0, self.h }, .{ self.w, self.h } };
        for (corners) |corner| {
            const px = self.ox + corner[0];
            const py = self.oy + corner[1];
            const dx = self.tx + self.a * px + self.b * py;
            const dy = self.ty + self.c * px + self.d * py;
            min_x = @min(min_x, dx);
            min_y = @min(min_y, dy);
            max_x = @max(max_x, dx);
            max_y = @max(max_y, dy);
        }
        const bounds: Bounds(ScaledPixels) = .{
            .origin = .{ .x = min_x, .y = min_y },
            .size = .{ .width = max_x - min_x, .height = max_y - min_y },
        };
        return rect_pixels(bounds, clip, t);
    }

    /// Unit-square coordinates of device pixel center (px, py), or null outside the sprite.
    inline fn unit(self: SpriteXf, px: f32, py: f32) ?[2]f32 {
        const dx = px - self.tx;
        const dy = py - self.ty;
        const lx = (self.d * dx - self.b * dy) * self.inv_det;
        const ly = (-self.c * dx + self.a * dy) * self.inv_det;
        const u = (lx - self.ox) / self.w;
        const v = (ly - self.oy) / self.h;
        if (!(u >= 0 and u <= 1 and v >= 0 and v <= 1)) return null;
        return .{ u, v };
    }
};

/// Bilinear sample of all channels of `tex` at texel coordinates (texel centers at i + 0.5).
fn sample_texture(tex: *const CpuTexture, fx: f32, fy: f32) [4]f32 {
    const w: f32 = @floatFromInt(tex.width);
    const h: f32 = @floatFromInt(tex.height);
    const sx = fx - 0.5;
    const sy = fy - 0.5;
    const fx0 = @floor(sx);
    const fy0 = @floor(sy);
    const wx = sx - fx0;
    const wy = sy - fy0;
    const x0f = std.math.clamp(fx0, 0, w - 1);
    const y0f = std.math.clamp(fy0, 0, h - 1);
    const x1f = std.math.clamp(fx0 + 1, 0, w - 1);
    const y1f = std.math.clamp(fy0 + 1, 0, h - 1);
    const x0: usize = @intFromFloat(x0f);
    const y0: usize = @intFromFloat(y0f);
    const x1: usize = @intFromFloat(x1f);
    const y1: usize = @intFromFloat(y1f);
    const stride = @as(usize, tex.width) * tex.bytes_per_pixel;
    const bpp: usize = tex.bytes_per_pixel;
    var out = [4]f32{ 0, 0, 0, 0 };
    for (0..bpp) |c| {
        const v00 = unorm(tex.bytes[y0 * stride + x0 * bpp + c]);
        const v10 = unorm(tex.bytes[y0 * stride + x1 * bpp + c]);
        const v01 = unorm(tex.bytes[y1 * stride + x0 * bpp + c]);
        const v11 = unorm(tex.bytes[y1 * stride + x1 * bpp + c]);
        const top = v00 + (v10 - v00) * wx;
        const bottom = v01 + (v11 - v01) * wx;
        out[c] = top + (bottom - top) * wy;
    }
    return out;
}

/// Texel-space origin and size of a tile.
fn tile_texels(tile: AtlasTile) [4]f32 {
    return .{
        @floatFromInt(tile.bounds.origin.x),
        @floatFromInt(tile.bounds.origin.y),
        @floatFromInt(tile.bounds.size.width),
        @floatFromInt(tile.bounds.size.height),
    };
}

fn color_brightness(rgb: [3]f32) f32 {
    return rgb[0] * 0.30 + rgb[1] * 0.59 + rgb[2] * 0.11;
}

/// Light-on-dark contrast boost, as in `light_on_dark_contrast`.
fn enhanced_contrast(factor: f32, brightness: f32) f32 {
    return factor * sat1(4.0 * (0.75 - brightness));
}

/// Applies `apply_contrast_and_gamma_correction` to one coverage value.
inline fn gamma_correct(s: f32, k: f32, adj: f32, off: f32) f32 {
    const ca = s * (k + 1.0) / (s * k + 1.0);
    const corr = adj * ca + off;
    return ca + ca * (1.0 - ca) * corr;
}

fn draw_mono(t: Target, tex: *const CpuTexture, sp: *const MonochromeSprite) void {
    if (sp.color.a == 0) return;
    const xf = SpriteXf.init(sp.transformation, sp.bounds) orelse return;
    const r = xf.device_rect(t, sp.content_mask.bounds) orelse return;
    const col = hsla_to_rgba(sp.color);
    const brightness = color_brightness(.{ col[0], col[1], col[2] });
    const k = enhanced_contrast(grayscale_enhanced_contrast, brightness);
    const adj = gamma_ratios[0] * brightness + gamma_ratios[1];
    const off = gamma_ratios[2] * brightness + gamma_ratios[3];
    const tile = tile_texels(sp.tile);
    for (r.y0..r.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        for (r.x0..r.x1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const uv = xf.unit(px, py) orelse continue;
            const s = sample_texture(tex, tile[0] + uv[0] * tile[2], tile[1] + uv[1] * tile[3])[0];
            const alpha = gamma_correct(s, k, adj, off);
            blend_px(t, x, y, .{ col[0], col[1], col[2], col[3] * alpha });
        }
    }
}

fn draw_polychrome(t: Target, tex: *const CpuTexture, sp: *const PolychromeSprite) void {
    if (sp.opacity <= 0) return;
    const r = rect_pixels(sp.bounds, sp.content_mask.bounds, t) orelse return;
    const rr = RRect.init(sp.bounds, sp.corner_radii);
    const tile = tile_texels(sp.tile);
    const ox = sp.bounds.origin.x;
    const oy = sp.bounds.origin.y;
    const w = sp.bounds.size.width;
    const h = sp.bounds.size.height;
    for (r.y0..r.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        for (r.x0..r.x1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const sdf = quad_sdf(&rr, s4(px), py)[0];
            const coverage = sp.opacity * sat1(0.5 - sdf);
            const u = (px - ox) / w;
            const v = (py - oy) / h;
            const s = sample_texture(tex, tile[0] + u * tile[2], tile[1] + v * tile[3]);
            const alpha = s[3] * coverage;
            if (!(alpha > 0)) continue;
            if (sp.grayscale.value != 0) {
                const lum = s[0] * 0.2126 + s[1] * 0.7152 + s[2] * 0.0722;
                blend_px(t, x, y, .{ lum, lum, lum, alpha });
            } else {
                blend_px(t, x, y, .{ s[0], s[1], s[2], alpha });
            }
        }
    }
}

/// Subpixel text: per-channel coverage blended with dual-source semantics.
fn draw_subpixel(t: Target, tex: *const CpuTexture, sp: *const SubpixelSprite) void {
    if (sp.color.a == 0) return;
    const xf = SpriteXf.init(sp.transformation, sp.bounds) orelse return;
    const r = xf.device_rect(t, sp.content_mask.bounds) orelse return;
    const col = hsla_to_rgba(sp.color);
    const rgb = [3]f32{ col[0], col[1], col[2] };
    const k = enhanced_contrast(subpixel_enhanced_contrast, color_brightness(rgb));
    const tile = tile_texels(sp.tile);
    for (r.y0..r.y1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        for (r.x0..r.x1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const uv = xf.unit(px, py) orelse continue;
            const s = sample_texture(tex, tile[0] + uv[0] * tile[2], tile[1] + uv[1] * tile[3]);
            const off = t.offset(x, y);
            const d: [4]f32 = t.load(off);
            var out: [4]f32 = undefined;
            for (0..3) |c| {
                const adj = gamma_ratios[0] * rgb[c] + gamma_ratios[1];
                const off_c = gamma_ratios[2] * rgb[c] + gamma_ratios[3];
                const cov = col[3] * gamma_correct(s[c], k, adj, off_c);
                out[c] = rgb[c] * cov + d[c] * (1 - cov);
            }
            out[3] = 1;
            t.store(off, @as(F4, out));
        }
    }
}

// ---------------------------------------------------------------------------
// Paths (fs_path_rasterization + fs_path, 4x MSAA)
// ---------------------------------------------------------------------------

/// Rasterizes one triangle into the per-sample accumulators `acc` (4 samples per pixel of `r`).
fn rasterize_triangle(acc: []F4, r: PixelRect, bp: *const BgPrep, ox: f32, oy: f32, v: [3]scene.PathVertex(ScaledPixels)) void {
    const x0 = v[0].xy_position.x;
    const y0 = v[0].xy_position.y;
    const x1 = v[1].xy_position.x;
    const y1 = v[1].xy_position.y;
    const x2 = v[2].xy_position.x;
    const y2 = v[2].xy_position.y;
    const det = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
    if (!(@abs(det) > 1e-12)) return;
    const inv = 1.0 / det;
    const db1dx = (y2 - y0) * inv;
    const db1dy = -(x2 - x0) * inv;
    const db2dx = -(y1 - y0) * inv;
    const db2dy = (x1 - x0) * inv;
    const s0 = v[0].st_position;
    const s1 = v[1].st_position;
    const s2 = v[2].st_position;
    // Screen-space derivatives of the (affine) texture coordinates.
    const dsdx = (s1.x - s0.x) * db1dx + (s2.x - s0.x) * db2dx;
    const dtdx = (s1.y - s0.y) * db1dx + (s2.y - s0.y) * db2dx;
    const dsdy = (s1.x - s0.x) * db1dy + (s2.x - s0.x) * db2dy;
    const dtdy = (s1.y - s0.y) * db1dy + (s2.y - s0.y) * db2dy;
    const straight = dsdx * dsdx + dsdy * dsdy < 1e-6;

    const coords = [6]f32{ x0, y0, x1, y1, x2, y2 };
    for (coords) |c| if (!std.math.isFinite(c)) return;
    const min_x = @min(x0, @min(x1, x2));
    const max_x = @max(x0, @max(x1, x2));
    const min_y = @min(y0, @min(y1, y2));
    const max_y = @max(y0, @max(y1, y2));
    const px0: usize = @max(r.x0, @as(usize, @intFromFloat(std.math.clamp(@floor(min_x), 0, 1e9))));
    const py0: usize = @max(r.y0, @as(usize, @intFromFloat(std.math.clamp(@floor(min_y), 0, 1e9))));
    const px1: usize = @min(r.x1, @as(usize, @intFromFloat(std.math.clamp(@ceil(max_x) + 1, 0, 1e9))));
    const py1: usize = @min(r.y1, @as(usize, @intFromFloat(std.math.clamp(@ceil(max_y) + 1, 0, 1e9))));
    // The triangle lies outside the clip rect: `py0..py1` would have a negative length.
    if (px1 <= px0 or py1 <= py0) return;
    const w = r.x1 - r.x0;

    for (py0..py1) |py_i| {
        for (px0..px1) |px_i| {
            // Coverage per MSAA sample.
            var mask: u4 = 0;
            for (msaa_offsets, 0..) |o, s| {
                const sx = @as(f32, @floatFromInt(px_i)) + o[0];
                const sy = @as(f32, @floatFromInt(py_i)) + o[1];
                const b1 = ((sx - x0) * (y2 - y0) - (x2 - x0) * (sy - y0)) * inv;
                const b2 = ((x1 - x0) * (sy - y0) - (sx - x0) * (y1 - y0)) * inv;
                const b0 = 1 - b1 - b2;
                if (b1 >= 0 and b2 >= 0 and b0 >= 0) mask |= @as(u4, 1) << @intCast(s);
            }
            if (mask == 0) continue;

            // Fragment shading happens once per pixel, at its center.
            const cx = @as(f32, @floatFromInt(px_i)) + 0.5;
            const cy = @as(f32, @floatFromInt(py_i)) + 0.5;
            const b1c = ((cx - x0) * (y2 - y0) - (x2 - x0) * (cy - y0)) * inv;
            const b2c = ((x1 - x0) * (cy - y0) - (cx - x0) * (y1 - y0)) * inv;
            const s_x = s0.x + (s1.x - s0.x) * b1c + (s2.x - s0.x) * b2c;
            const s_y = s0.y + (s1.y - s0.y) * b1c + (s2.y - s0.y) * b2c;
            var alpha: f32 = 1;
            if (!straight) {
                const gx = 2.0 * s_x * dsdx - dtdx;
                const gy = 2.0 * s_x * dsdy - dtdy;
                const f = s_x * s_x - s_y;
                const distance = f / @sqrt(gx * gx + gy * gy);
                alpha = sat1(0.5 - distance);
            }
            const bgc = background_lanes(bp, ox, oy, s4(cx), cy);
            const a = bgc.a[0] * alpha;
            const frag = F4{ bgc.r[0] * bgc.a[0] * alpha, bgc.g[0] * bgc.a[0] * alpha, bgc.b[0] * bgc.a[0] * alpha, a };
            if (!(a > 0)) continue;

            const pixel = (py_i - r.y0) * w + (px_i - r.x0);
            for (0..4) |s| {
                if (mask & (@as(u4, 1) << @intCast(s)) == 0) continue;
                const slot = &acc[pixel * 4 + s];
                slot.* = over_premul(slot.*, frag);
            }
        }
    }
}

fn draw_path(scratch: *std.ArrayList(F4), gpa: std.mem.Allocator, t: Target, p: *const scene.Path(ScaledPixels)) void {
    const verts = p.vertices.items;
    if (verts.len < 3) return;
    const cb = p.clipped_bounds();
    const r = rect_pixels(cb, cb, t) orelse return;
    const w = r.x1 - r.x0;
    const h = r.y1 - r.y0;

    scratch.resize(gpa, w * h * 4) catch return;
    const acc = scratch.items;
    @memset(acc, zero4);

    const bp = BgPrep.init(p.color, cb.size.width, cb.size.height);
    var i: usize = 0;
    while (i + 3 <= verts.len) : (i += 3) {
        rasterize_triangle(acc, r, &bp, cb.origin.x, cb.origin.y, .{ verts[i], verts[i + 1], verts[i + 2] });
    }

    // Resolve the samples and composite the premultiplied result.
    for (0..h) |ry| {
        for (0..w) |rx| {
            const base = (ry * w + rx) * 4;
            const sum = acc[base] + acc[base + 1] + acc[base + 2] + acc[base + 3];
            const c = sum * s4(0.25);
            if (!(c[3] > 0)) continue;
            const x = r.x0 + rx;
            const y = r.y0 + ry;
            const off = t.offset(x, y);
            t.store(off, over_premul(t.load(off), c));
        }
    }
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

fn empty_scratch() [CpuRenderer.max_bands]std.ArrayList(F4) {
    var lists: [CpuRenderer.max_bands]std.ArrayList(F4) = undefined;
    for (&lists) |*list| list.* = .empty;
    return lists;
}

/// Software renderer for `Scene`. Owns scratch memory reused across frames.
pub const CpuRenderer = struct {
    /// Upper bound on worker bands per frame.
    pub const max_bands = 16;
    /// Bands are at least this many rows high, so small frames stay on one thread.
    const min_band_rows = 32;

    allocator: std.mem.Allocator,
    /// Threads to draw with: 0 uses the CPU count, 1 draws on the calling thread.
    threads: usize = 0,
    /// Per-band scratch for path rasterization.
    scratch: [max_bands]std.ArrayList(F4) = empty_scratch(),

    /// Creates a renderer; scratch buffers grow on demand.
    pub fn init(allocator: std.mem.Allocator) CpuRenderer {
        return .{ .allocator = allocator };
    }

    /// Releases the scratch buffers.
    pub fn deinit(self: *CpuRenderer) void {
        for (&self.scratch) |*list| list.deinit(self.allocator);
    }

    /// Clears `fb` to `clear` and draws `scene` (already `finish()`ed), sampling sprite textures from `atlas`.
    /// Rows are split into bands drawn in parallel; each band replays the whole scene in order.
    pub fn draw(self: *CpuRenderer, sc: *const Scene, atlas_: *const CpuAtlas, fb: Framebuffer, clear: Hsla) void {
        const full = Target.init(fb) orelse return;
        const clear_rgba = clear.to_rgb();
        const clear_px = premultiply(.{ clear_rgba.r, clear_rgba.g, clear_rgba.b, clear_rgba.a });

        const wanted = if (self.threads == 0) (std.Thread.getCpuCount() catch 1) else self.threads;
        const bands = std.math.clamp(@min(wanted, full.height / min_band_rows), 1, max_bands);
        if (bands == 1) {
            self.draw_band(0, sc, atlas_, full, clear_px);
            return;
        }

        var jobs: [max_bands]BandJob = undefined;
        var threads: [max_bands]?std.Thread = @splat(null);
        for (0..bands) |i| {
            jobs[i] = .{
                .renderer = self,
                .scene = sc,
                .atlas = atlas_,
                .target = full.rows(full.height * i / bands, full.height * (i + 1) / bands),
                .clear = clear_px,
                .index = i,
            };
        }
        // Band 0 runs here; a band whose thread cannot be spawned also runs here, after the others.
        for (1..bands) |i| threads[i] = std.Thread.spawn(.{}, run_job, .{&jobs[i]}) catch null;
        run_job(&jobs[0]);
        for (1..bands) |i| {
            if (threads[i]) |thread| thread.join() else run_job(&jobs[i]);
        }
    }

    fn draw_band(self: *CpuRenderer, index: usize, sc: *const Scene, atlas_: *const CpuAtlas, t: Target, clear_px: [4]f32) void {
        for (t.y0..t.y1) |y| fill_opaque(t, y, 0, t.width, clear_px);

        var batches = sc.batches();
        while (batches.next()) |batch| switch (batch) {
            .shadows => |items| for (items) |*item| draw_shadow(t, item),
            .quads => |items| for (items) |*item| draw_quad(t, item),
            .paths => |items| for (items) |*item| draw_path(&self.scratch[index], self.allocator, t, item),
            .underlines => |items| for (items) |*item| draw_underline(t, item),
            .monochrome_sprites => |b| if (atlas_.texture(b.texture_id)) |tex| {
                for (b.sprites) |*item| draw_mono(t, tex, item);
            },
            .subpixel_sprites => |b| if (atlas_.texture(b.texture_id)) |tex| {
                for (b.sprites) |*item| draw_subpixel(t, tex, item);
            },
            .polychrome_sprites => |b| if (atlas_.texture(b.texture_id)) |tex| {
                for (b.sprites) |*item| draw_polychrome(t, tex, item);
            },
            // Platform surfaces (video frames) have no CPU representation and are skipped.
            .surfaces => {},
        };
    }
};

const BandJob = struct {
    renderer: *CpuRenderer,
    scene: *const Scene,
    atlas: *const CpuAtlas,
    target: Target,
    clear: [4]f32,
    index: usize,
};

fn run_job(job: *BandJob) void {
    job.renderer.draw_band(job.index, job.scene, job.atlas, job.target, job.clear);
}

/// Writes a binary PPM (P6) of `fb` for snapshots. Alpha is dropped.
pub fn write_ppm(fb: Framebuffer, writer: anytype) !void {
    try writer.print("P6\n{d} {d}\n255\n", .{ fb.width, fb.height });
    const bgra = fb.format == .bgra8;
    const stride: usize = fb.stride;
    const width: usize = fb.width;
    var row: [256 * 3]u8 = undefined;
    for (0..fb.height) |y| {
        const line = fb.pixels[y * stride ..];
        var x: usize = 0;
        while (x < width) {
            const n = @min(256, width - x);
            for (0..n) |i| {
                const p = line[(x + i) * 4 ..][0..4];
                row[i * 3 ..][0..3].* = if (bgra) .{ p[2], p[1], p[0] } else .{ p[0], p[1], p[2] };
            }
            try writer.writeAll(row[0 .. n * 3]);
            x += n;
        }
    }
}

// ---------------------------------------------------------------------------
// Benchmark
// ---------------------------------------------------------------------------

const now_ns = @import("../executor.zig").now_ns;

/// Builds `quad_count` random quads over a 1920x1080 scene and returns the mean nanoseconds per `draw`.
/// Meaningful only in ReleaseFast builds.
pub fn bench(allocator: std.mem.Allocator, quad_count: usize, frames: usize) !u64 {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const width = 1920;
    const height = 1080;

    var sc = Scene.init(allocator);
    defer sc.deinit();
    const full: Bounds(ScaledPixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } };
    for (0..quad_count) |_| {
        const w = 8 + random.float(f32) * 200;
        const h = 8 + random.float(f32) * 100;
        const x = random.float(f32) * (width - w);
        const y = random.float(f32) * (height - h);
        const radius: f32 = if (random.boolean()) 0 else 4;
        const quad: Quad = .{
            .bounds = .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } },
            .content_mask = .{ .bounds = full },
            .background = color.solid_background(color.hsla(random.float(f32), 0.6, 0.5, 0.9)),
            .corner_radii = .{ .top_left = radius, .top_right = radius, .bottom_right = radius, .bottom_left = radius },
        };
        try sc.insert_primitive(.{ .quad = quad });
    }
    sc.finish();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    var cpu_atlas = CpuAtlas.init(allocator);
    defer cpu_atlas.deinit();

    const pixels = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(pixels);
    const fb: Framebuffer = .{ .pixels = pixels, .width = width, .height = height, .stride = width * 4, .format = .rgba8 };

    renderer.draw(&sc, &cpu_atlas, fb, color.black());
    const start = now_ns();
    for (0..frames) |_| renderer.draw(&sc, &cpu_atlas, fb, color.black());
    return (now_ns() - start) / @max(frames, 1);
}

test "bench: 10k quads at 1920x1080 (ReleaseFast only)" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    const ns = try bench(testing.allocator, 10_000, 20);
    std.debug.print("cpu bench: 10000 quads 1920x1080: {d} us/frame\n", .{ns / 1000});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestFb = struct {
    buffer: []u8,
    fb: Framebuffer,

    fn init(w: u32, h: u32, clear_px: [4]u8) !TestFb {
        const buffer = try testing.allocator.alloc(u8, w * h * 4);
        var i: usize = 0;
        while (i < buffer.len) : (i += 4) buffer[i..][0..4].* = clear_px;
        return .{ .buffer = buffer, .fb = .{ .pixels = buffer, .width = w, .height = h, .stride = w * 4, .format = .rgba8 } };
    }

    fn deinit(self: *TestFb) void {
        testing.allocator.free(self.buffer);
    }

    fn at(self: TestFb, x: u32, y: u32) [4]u8 {
        const off = y * self.fb.stride + x * 4;
        return self.buffer[off..][0..4].*;
    }
};

fn test_rect(x: f32, y: f32, w: f32, h: f32) Bounds(ScaledPixels) {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn test_mask(x: f32, y: f32, w: f32, h: f32) scene.ContentMask(ScaledPixels) {
    return .{ .bounds = test_rect(x, y, w, h) };
}

test "solid quad covers exactly its bounds" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(2, 3, 4, 2),
        .content_mask = test_mask(0, 0, 10, 10),
        .background = color.solid_background(color.red()),
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(2, 3));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(5, 4));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(6, 3));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(1, 3));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 2));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 5));
}

test "rounded corners are partially covered" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(0, 0, 8, 8),
        .content_mask = test_mask(0, 0, 10, 10),
        .background = color.solid_background(color.red()),
        .corner_radii = .{ .top_left = 4, .top_right = 4, .bottom_right = 4, .bottom_left = 4 },
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(0, 0));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(4, 4));
    const edge = target.at(2, 0);
    try testing.expect(edge[0] > 50 and edge[0] < 200);
}

test "content mask clips quads" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(0, 0, 10, 10),
        .content_mask = test_mask(0, 0, 5, 5),
        .background = color.solid_background(color.red()),
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(2, 2));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(7, 7));
}

test "one pixel border draws only on the edges" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(0, 0, 6, 6),
        .content_mask = test_mask(0, 0, 10, 10),
        .background = color.solid_background(color.transparent_black()),
        .border_color = color.blue(),
        .border_widths = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.at(0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.at(5, 5));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.at(3, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.at(0, 3));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 2));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(1, 1));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(7, 7));
}

test "dashed border leaves gaps" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(0, 0, 40, 10),
        .content_mask = test_mask(0, 0, 40, 10),
        .background = color.solid_background(color.transparent_black()),
        .border_color = color.blue(),
        .border_style = .dashed,
        .border_widths = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
    } });
    sc.finish();

    var target = try TestFb.init(40, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    var blue: usize = 0;
    var gap: usize = 0;
    for (0..40) |x| {
        const p = target.at(@intCast(x), 0);
        if (p[2] == 255) blue += 1 else gap += 1;
    }
    try testing.expect(blue > 0);
    try testing.expect(gap > 0);
}

test "interior fast path matches the full SDF" {
    const quad: Quad = .{
        .bounds = test_rect(3.25, 2.5, 30.5, 20),
        .content_mask = test_mask(0, 0, 40, 30),
        .background = color.linear_gradient(
            45,
            color.linear_color_stop(color.red(), 0),
            color.linear_color_stop(color.blue(), 1),
        ),
        .border_color = color.hsla(0.3, 0.8, 0.4, 0.7),
        .border_widths = .{ .top = 2, .right = 1, .bottom = 3, .left = 2 },
        .corner_radii = .{ .top_left = 6, .top_right = 3, .bottom_right = 9, .bottom_left = 0 },
    };

    var fast = try TestFb.init(40, 30, .{ 0, 0, 0, 255 });
    defer fast.deinit();
    draw_quad(Target.init(fast.fb).?, &quad);

    var full = try TestFb.init(40, 30, .{ 0, 0, 0, 255 });
    defer full.deinit();
    const t = Target.init(full.fb).?;
    const g = QuadGeom.init(&quad);
    const r = rect_pixels(quad.bounds, quad.content_mask.bounds, t).?;
    for (r.y0..r.y1) |y| quad_edge(t, y, r.x0, r.x1, &g);

    try testing.expectEqualSlices(u8, full.buffer, fast.buffer);
}

test "linear gradient runs from the first stop to the second" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const bg = color.linear_gradient(
        90,
        color.linear_color_stop(color.black(), 0),
        color.linear_color_stop(color.white(), 1),
    );
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(0, 0, 10, 10),
        .content_mask = test_mask(0, 0, 10, 10),
        .background = bg,
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    const left = target.at(0, 5);
    const right = target.at(9, 5);
    try testing.expect(left[0] < 40);
    try testing.expect(right[0] > 215);
}

test "monochrome sprite tints its tile" {
    var cpu_atlas = CpuAtlas.init(testing.allocator);
    defer cpu_atlas.deinit();
    const tile = try cpu_atlas.insert(.monochrome, .{ .width = 2, .height = 2 }, &.{ 255, 0, 0, 0 });

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .monochrome_sprite = .{
        .tile = tile,
        .bounds = test_rect(1, 1, 2, 2),
        .content_mask = test_mask(0, 0, 10, 10),
        .color = color.red(),
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &cpu_atlas, target.fb, color.black());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(1, 1));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 1));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 2));
}

test "polychrome sprite copies texels" {
    var cpu_atlas = CpuAtlas.init(testing.allocator);
    defer cpu_atlas.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const tile = try cpu_atlas.insert(.polychrome, .{ .width = 2, .height = 2 }, &pixels);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .polychrome_sprite = .{
        .tile = tile,
        .bounds = test_rect(0, 0, 2, 2),
        .content_mask = test_mask(0, 0, 10, 10),
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &cpu_atlas, target.fb, color.black());

    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, target.at(0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.at(1, 0));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, target.at(1, 1));
}

test "blurred shadow darkens its box and leaves far pixels alone" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .shadow = .{
        .blur_radius = 4,
        .bounds = test_rect(10, 10, 10, 10),
        .content_mask = test_mask(0, 0, 40, 40),
        .color = color.black(),
        .element_bounds = test_rect(10, 10, 10, 10),
    } });
    sc.finish();

    var target = try TestFb.init(40, 40, .{ 255, 255, 255, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.white());

    // Analytic value for a 10px box blurred with sigma 4 at its center: 255 * (1 - erf(5 / (4 sqrt 2))^2) = 96.
    const center = target.at(15, 15)[0];
    try testing.expect(center > 80 and center < 115);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, target.at(39, 39));
}

test "underline covers its rectangle" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .underline = .{
        .bounds = test_rect(2, 5, 6, 2),
        .content_mask = test_mask(0, 0, 10, 10),
        .color = color.red(),
        .thickness = 2,
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(3, 5));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(3, 4));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(3, 7));
}

test "path triangle is antialiased on its diagonal and filled inside" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();

    var path = scene.Path(ScaledPixels).new(testing.allocator, .{ .x = 0, .y = 0 });
    path.content_mask = test_mask(0, 0, 100, 100);
    path.color = color.solid_background(color.red());
    path.move_to(.{ .x = 0, .y = 0 });
    try path.line_to(.{ .x = 10, .y = 0 });
    try path.line_to(.{ .x = 10, .y = 10 });
    try sc.insert_primitive(.{ .path = path });
    sc.finish();

    var target = try TestFb.init(12, 12, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(8, 2));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 8));
    const edge = target.at(5, 5);
    try testing.expect(edge[0] > 60 and edge[0] < 200);
}

test "checkerboard alternates cells" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(0, 0, 4, 4),
        .content_mask = test_mask(0, 0, 10, 10),
        .background = color.checkerboard(color.red(), 2),
    } });
    sc.finish();

    var target = try TestFb.init(10, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(0, 0));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(2, 0));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(0, 2));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.at(2, 2));
}

test "wavy underline stays within its band" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .underline = .{
        .bounds = test_rect(0, 2, 20, 4),
        .content_mask = test_mask(0, 0, 30, 10),
        .color = color.red(),
        .thickness = 1,
        .wavy = .{ .value = 1 },
    } });
    sc.finish();

    var target = try TestFb.init(30, 10, .{ 0, 0, 0, 255 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.black());

    var painted: usize = 0;
    for (0..30) |x| {
        for (0..10) |y| {
            const p = target.at(@intCast(x), @intCast(y));
            if (p[0] == 0) continue;
            painted += 1;
            try testing.expect(y >= 2 and y < 6 and x < 20);
        }
    }
    try testing.expect(painted > 0);
}

test "subpixel sprite blends each channel separately" {
    var cpu_atlas = CpuAtlas.init(testing.allocator);
    defer cpu_atlas.deinit();
    const tile = try cpu_atlas.insert(.subpixel, .{ .width = 1, .height = 1 }, &.{ 255, 255, 255, 255 });

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .subpixel_sprite = .{
        .tile = tile,
        .bounds = test_rect(1, 1, 1, 1),
        .content_mask = test_mask(0, 0, 4, 4),
        .color = color.green(),
    } });
    sc.finish();

    var target = try TestFb.init(4, 4, .{ 255, 0, 0, 255 });
    defer target.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &cpu_atlas, target.fb, color.red());

    // color.green() has lightness 0.25, so its green channel is 0.5.
    try testing.expectEqual([4]u8{ 0, 128, 0, 255 }, target.at(1, 1));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.at(0, 0));
}

test "banded rendering matches single-threaded rendering" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const full = test_mask(0, 0, 96, 160);
    for (0..150) |i| {
        const x = random.float(f32) * 80;
        const y = random.float(f32) * 150;
        const w = 4 + random.float(f32) * 30;
        const h = 4 + random.float(f32) * 30;
        switch (i % 3) {
            0 => try sc.insert_primitive(.{ .quad = .{
                .bounds = test_rect(x, y, w, h),
                .content_mask = full,
                .background = color.solid_background(color.hsla(random.float(f32), 0.7, 0.5, 0.8)),
                .corner_radii = .{ .top_left = 3, .top_right = 3, .bottom_right = 3, .bottom_left = 3 },
                .border_widths = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                .border_color = color.blue(),
            } }),
            1 => try sc.insert_primitive(.{ .shadow = .{
                .blur_radius = 3,
                .bounds = test_rect(x, y, w, h),
                .content_mask = full,
                .color = color.black(),
                .element_bounds = test_rect(x, y, w, h),
            } }),
            else => {
                var path = scene.Path(ScaledPixels).new(testing.allocator, .{ .x = x, .y = y });
                path.content_mask = full;
                path.color = color.solid_background(color.green());
                path.move_to(.{ .x = x, .y = y });
                try path.line_to(.{ .x = x + w, .y = y });
                try path.line_to(.{ .x = x, .y = y + h });
                try sc.insert_primitive(.{ .path = path });
            },
        }
    }
    sc.finish();

    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var single = try TestFb.init(96, 160, .{ 10, 20, 30, 255 });
    defer single.deinit();
    var banded = try TestFb.init(96, 160, .{ 10, 20, 30, 255 });
    defer banded.deinit();

    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.threads = 1;
    renderer.draw(&sc, &atlas_, single.fb, color.black());
    renderer.threads = 4;
    renderer.draw(&sc, &atlas_, banded.fb, color.black());

    try testing.expectEqualSlices(u8, single.buffer, banded.buffer);
}

test "ppm output has a P6 header and drops alpha" {
    var pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const fb: Framebuffer = .{ .pixels = &pixels, .width = 2, .height = 1, .stride = 8, .format = .rgba8 };
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write_ppm(fb, &writer);
    try testing.expectEqualStrings("P6\n2 1\n255\n\xff\x00\x00\x00\xff\x00", writer.buffered());
}

test "premultiply: alpha 0 zeroes the color, alpha 1 keeps it, in between scales it" {
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, premultiply(.{ 1, 0.5, 0.25, 0 }));
    try testing.expectEqual([4]f32{ 0.2, 0.4, 0.6, 1 }, premultiply(.{ 0.2, 0.4, 0.6, 1 }));
    try testing.expectEqual([4]f32{ 0.5, 0, 0.25, 0.5 }, premultiply(.{ 1, 0, 0.5, 0.5 }));
    // In bytes: a full channel at 128/255 alpha stays 128 after premultiplying.
    const half = premultiply(.{ 1, 1, 1, 128.0 / 255.0 });
    try testing.expectEqual(@as(u8, 128), to_u8(half[3]));
    try testing.expectEqual(@as(u8, 128), to_u8(half[0]));
    const solid = premultiply(.{ 1, 1, 1, 1 });
    try testing.expectEqual(@as(u8, 255), to_u8(solid[0]));
}

test "a transparent clear is transparent and a half quad lands premultiplied" {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    try sc.insert_primitive(.{ .quad = .{
        .bounds = test_rect(1, 1, 2, 1),
        .content_mask = test_mask(0, 0, 4, 4),
        .background = color.solid_background(color.hsla(0, 1, 0.5, 0.5)),
    } });
    sc.finish();

    var target = try TestFb.init(4, 4, .{ 9, 9, 9, 9 });
    defer target.deinit();
    var atlas_ = CpuAtlas.init(testing.allocator);
    defer atlas_.deinit();
    var renderer = CpuRenderer.init(testing.allocator);
    defer renderer.deinit();
    renderer.draw(&sc, &atlas_, target.fb, color.transparent_black());

    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, target.at(0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, target.at(3, 3));
    // Red at half alpha, premultiplied: color 0.5 and alpha 0.5, i.e. 128 in each.
    try testing.expectEqual([4]u8{ 128, 0, 0, 128 }, target.at(1, 1));
}

