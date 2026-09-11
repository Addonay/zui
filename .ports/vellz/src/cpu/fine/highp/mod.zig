//! Port of vello_cpu src/fine/highp/mod.rs (Apache-2.0 OR MIT).
//!
//! High-precision (f32) rendering kernel: color components are premultiplied
//! linear floats in `[0, 1]`, packed into RGBA8 only by `pack`.
//!
//! `F32Kernel` is the only kernel instantiated in M1; it implements the
//! comptime surface documented in `fine/mod.zig`. `lowp` (u8) drops in later
//! behind the same surface.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const peniko = @import("../../../peniko/root.zig");
const paint_mod = @import("../../../common/paint.zig");
const mask_mod = @import("../../../common/mask.zig");
const region_mod = @import("../../region.zig");
const fine = @import("../mod.zig");
const blend_mod = @import("blend.zig");
const compose_mod = @import("compose.zig");

const F32x4 = simd.F32x4;
const F32x16 = simd.F32x16;
const U8x16 = simd.U8x16;
const Mask = mask_mod.Mask;
const PremulColor = paint_mod.PremulColor;
const Tint = paint_mod.Tint;
const Region = region_mod.Region;

fn one() F32x16 {
    return @splat(1.0);
}

/// Build `[r, g, b, a]` repeated across four pixels.
fn colorVector(color: [4]f32) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..4) |i| {
        out[4 * i + 0] = color[0];
        out[4 * i + 1] = color[1];
        out[4 * i + 2] = color[2];
        out[4 * i + 3] = color[3];
    }
    return out;
}

/// Convert 16 `u8` values to `f32` without normalization (`255` becomes
/// `255.0`, not `1.0`).
fn u8ToF32(val: U8x16) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..16) |i| {
        out[i] = @floatFromInt(val[i]);
    }
    return out;
}

/// Expand 4 mask bytes into a 16-element f32 vector with normalized values.
///
/// Converts `u8` mask values to `f32` in `[0.0, 1.0]`, then duplicates each
/// mask value across 4 consecutive elements (one per color component):
/// `[m0, m1, m2, m3] -> [m0/255 x4, m1/255 x4, m2/255 x4, m3/255 x4]`.
fn extractMasks(masks: [4]u8) F32x16 {
    var result: F32x16 = undefined;
    inline for (0..4) |i| {
        const value = @as(f32, @floatFromInt(masks[i])) * (1.0 / 255.0);
        inline for (0..4) |component| {
            result[i * 4 + component] = value;
        }
    }
    return result;
}

/// Per-column `[u8; 4]` alpha quadruples from a strip alpha buffer.
const QuadSliceIter = struct {
    data: []const u8,
    idx: usize = 0,

    fn next(self: *@This()) ?[4]u8 {
        if (self.idx + 4 > self.data.len) return null;
        const quad = self.data[self.idx..][0..4].*;
        self.idx += 4;
        return quad;
    }
};

/// Per-column `[u8; 4]` samples from a render mask.
///
/// Out-of-bounds samples yield `255` (no masking), matching
/// `F32Kernel::blend` upstream (this differs from `Fine::mask`, which yields
/// `0`).
const MaskQuadIter = struct {
    m: *const Mask,
    x: u16,
    y: u16,

    fn next(self: *@This()) ?[4]u8 {
        const width = self.m.width();
        const height = self.m.height();

        const samples = if (self.x < width and self.y + 3 < height)
            // All in bounds, sample directly.
            [4]u8{
                self.m.sample(self.x, self.y),
                self.m.sample(self.x, self.y + 1),
                self.m.sample(self.x, self.y + 2),
                self.m.sample(self.x, self.y + 3),
            }
        else
            // Fallback: check each individually.
            [4]u8{
                if (self.x < width and self.y < height) self.m.sample(self.x, self.y) else 255,
                if (self.x < width and self.y + 1 < height) self.m.sample(self.x, self.y + 1) else 255,
                if (self.x < width and self.y + 2 < height) self.m.sample(self.x, self.y + 2) else 255,
                if (self.x < width and self.y + 3 < height) self.m.sample(self.x, self.y + 3) else 255,
            };

        self.x += 1;
        return samples;
    }
};

/// Component-wise (exact) combination of alpha quadruples.
const QuadProductIter = struct {
    a: *QuadSliceIter,
    b: *MaskQuadIter,

    fn next(self: *@This()) ?[4]u8 {
        const a1 = self.a.next() orelse return null;
        const a2 = self.b.next() orelse return null;

        var out: [4]u8 = undefined;
        inline for (0..4) |i| {
            out[i] = @intCast((@as(u16, a1[i]) * @as(u16, a2[i])) / 255);
        }
        return out;
    }
};

/// The kernel for doing rendering using f32.
pub const F32Kernel = struct {
    /// The basic numeric type of the kernel.
    pub const Numeric = f32;
    /// The zero value for this numeric type.
    pub const ZERO: f32 = 0.0;
    /// The maximum opacity value for this numeric type.
    pub const ONE: f32 = 1.0;
    /// The SIMD composite type used for batch blending/compositing.
    pub const Composite = F32x16;
    /// The SIMD vector type used for conversions between u8 and f32.
    pub const NumericVec = F32x16;
    /// The number of numeric values per composite vector.
    pub const COMPOSITE_LENGTH: usize = 16;

    /// Build a composite from a numeric slice.
    pub fn compositeFromSlice(slice: []const f32) Composite {
        return simd.fromSlice(F32x16, slice);
    }

    /// Build a composite by repeating a single RGBA color across four pixels.
    pub fn compositeFromColor(color: [4]f32) Composite {
        return colorVector(color);
    }

    /// Numeric-vector conversion from `f32x16` (identity for this kernel).
    pub fn numericVecFromF32(val: F32x16) NumericVec {
        return val;
    }

    /// Numeric-vector conversion from `u8x16`, normalized to `[0, 1]`.
    pub fn numericVecFromU8(val: U8x16) NumericVec {
        return u8ToF32(val) * @as(F32x16, @splat(1.0 / 255.0));
    }

    /// Extract RGBA color components from a premultiplied color as f32 values.
    pub fn extractColor(color: PremulColor) [4]f32 {
        return color.asPremulF32().components;
    }

    /// Fill a buffer with a solid color.
    pub fn copySolid(_: simd.Level, dest: []f32, src: [4]f32) void {
        std.debug.assert(dest.len % 16 == 0);
        const color = colorVector(src);

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            simd.storeSlice(color, dest[i..][0..16]);
        }
    }

    /// Apply per-pixel mask values to a buffer by multiplying each component.
    pub fn applyMask(_: simd.Level, dest: []f32, src: anytype) void {
        std.debug.assert(dest.len % 16 == 0);
        var iter = src;

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const loaded = simd.fromSlice(F32x16, dest[i..][0..16]);
            const mask = iter.next() orelse @panic("apply_mask: mask iterator exhausted");
            simd.storeSlice(loaded * mask, dest[i..][0..16]);
        }
    }

    /// Apply an image tint to an already-painted buffer.
    pub fn applyTint(_: simd.Level, dest: []f32, tint: *const Tint) void {
        const premul = tint.color.premultiply();
        const components = premul.components;
        const tint_v = colorVector(components);

        switch (tint.mode) {
            .alpha_mask => {
                var i: usize = 0;
                while (i < dest.len) : (i += 16) {
                    const pixel = simd.fromSlice(F32x16, dest[i..][0..16]);
                    const alphas = simd.splat4th(pixel);
                    simd.storeSlice(tint_v * alphas, dest[i..][0..16]);
                }
            },
            .multiply => {
                var i: usize = 0;
                while (i < dest.len) : (i += 16) {
                    const pixel = simd.fromSlice(F32x16, dest[i..][0..16]);
                    simd.storeSlice(pixel * tint_v, dest[i..][0..16]);
                }
            },
        }
    }

    /// Composites a solid color onto a buffer using alpha blending.
    ///
    /// Dispatches to either the masked or unmasked implementation based on the
    /// presence of per-pixel alpha masks.
    pub fn alphaCompositeSolid(
        _: simd.Level,
        dest: []f32,
        src: [4]f32,
        alphas: ?[]const u8,
    ) void {
        if (alphas) |alpha_slice| {
            var alpha_iter = QuadSliceIter{ .data = alpha_slice };
            alphaFill.alphaCompositeSolid(dest, src, &alpha_iter);
        } else {
            fill.alphaCompositeSolid(dest, src);
        }
    }

    /// Composites a source buffer onto a destination buffer using alpha
    /// blending.
    pub fn alphaCompositeBuffer(
        _: simd.Level,
        dest: []f32,
        src: []const f32,
        alphas: ?[]const u8,
    ) void {
        if (alphas) |alpha_slice| {
            var alpha_iter = QuadSliceIter{ .data = alpha_slice };
            alphaFill.alphaCompositeArbitrary(dest, src, &alpha_iter);
        } else {
            fill.alphaCompositeArbitrary(dest, src);
        }
    }

    /// Applies a blend mode to composite source pixels onto destination.
    ///
    /// Handles both color mixing (multiply, screen, ...) and compositing, with
    /// optional per-pixel alpha and render-mask modulation.
    pub fn blend(
        _: simd.Level,
        dest: []f32,
        start_x: u16,
        start_y: u16,
        src: anytype,
        blend_mode: peniko.BlendMode,
        alphas: ?[]const u8,
        mask: ?*const Mask,
    ) void {
        if (alphas) |alpha_slice| {
            var alpha_iter = QuadSliceIter{ .data = alpha_slice };
            if (mask) |m| {
                var mask_iter = MaskQuadIter{ .m = m, .x = start_x, .y = start_y };
                var product = QuadProductIter{ .a = &alpha_iter, .b = &mask_iter };
                alphaFill.blend(dest, src, &product, blend_mode);
            } else {
                alphaFill.blend(dest, src, &alpha_iter, blend_mode);
            }
        } else if (mask) |m| {
            var mask_iter = MaskQuadIter{ .m = m, .x = start_x, .y = start_y };
            alphaFill.blend(dest, src, &mask_iter, blend_mode);
        } else {
            fill.blend(dest, src, blend_mode);
        }
    }

    /// Fill a row scratch span with a solid color, optionally modulated by
    /// per-pixel alphas.
    pub fn fillSolid(level: simd.Level, dest: []f32, color: PremulColor, alphas: ?[]const u8) void {
        const extracted = extractColor(color);

        if (extracted[3] == ONE and alphas == null) {
            copySolid(level, dest, extracted);
        } else {
            alphaCompositeSolid(level, dest, extracted, alphas);
        }
    }

    /// Pack row scratch data into a row-major output buffer.
    ///
    /// The per-pixel conversion matches Rust's saturating `as u8` cast of
    /// `src * 255.0 + 0.5`.
    pub fn pack(_: simd.Level, scratch: []const f32, width: usize, region: *Region) void {
        for (0..region.height) |y| {
            const row = region.rowMut(@intCast(y))[0 .. width * fine.COLOR_COMPONENTS];
            var dx: usize = 0;
            while (dx < width) : (dx += 1) {
                const idx = fine.COLOR_COMPONENTS *
                    (@as(usize, fine.TILE_HEIGHT) * dx + @as(usize, y));
                inline for (0..fine.COLOR_COMPONENTS) |component| {
                    row[fine.COLOR_COMPONENTS * dx + component] =
                        roundToU8(scratch[idx + component] * 255.0 + 0.5);
                }
            }
        }
    }

    /// Unpack row-major input data into row scratch.
    pub fn unpack(_: simd.Level, region: *Region, width: usize, scratch: []f32) void {
        for (0..region.height) |y| {
            const row = region.rowMut(@intCast(y))[0 .. width * fine.COLOR_COMPONENTS];
            var dx: usize = 0;
            while (dx < width) : (dx += 1) {
                const idx = fine.COLOR_COMPONENTS *
                    (@as(usize, fine.TILE_HEIGHT) * dx + @as(usize, y));
                inline for (0..fine.COLOR_COMPONENTS) |component| {
                    scratch[idx + component] =
                        @as(f32, @floatFromInt(row[fine.COLOR_COMPONENTS * dx + component])) / 255.0;
                }
            }
        }
    }
};

/// Rust's `(value) as u8`: truncate toward zero, saturate out-of-range values,
/// and map NaN to 0.
fn roundToU8(value: f32) u8 {
    if (std.math.isNan(value)) return 0;
    if (value <= 0.0) return 0;
    if (value >= 255.0) return 255;
    return @intFromFloat(value);
}

/// Alpha compositing and blending without per-pixel alpha masks.
const fill = struct {
    /// `result = src + bg * (1 - src_alpha)`, using FMA.
    fn alphaCompositeInner(dest: []f32, src: F32x16, one_minus_alpha: F32x16) void {
        const bg = simd.fromSlice(F32x16, dest);
        const result = simd.mulAdd(one_minus_alpha, bg, src);
        simd.storeSlice(result, dest);
    }

    fn alphaCompositeSolid(dest: []f32, src: [4]f32) void {
        std.debug.assert(dest.len % 16 == 0);
        const one_minus_alpha = one() - @as(F32x16, @splat(src[3]));
        const src_c = colorVector(src);

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            alphaCompositeInner(dest[i..][0..16], src_c, one_minus_alpha);
        }
    }

    fn alphaCompositeArbitrary(dest: []f32, src: []const f32) void {
        std.debug.assert(dest.len % 16 == 0);
        std.debug.assert(src.len >= dest.len);

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const next_src = simd.fromSlice(F32x16, src[i..][0..16]);
            const one_minus_alpha = one() - simd.splat4th(next_src);
            alphaCompositeInner(dest[i..][0..16], next_src, one_minus_alpha);
        }
    }

    fn blend(dest: []f32, src: anytype, blend_mode: peniko.BlendMode) void {
        std.debug.assert(dest.len % 16 == 0);
        var source = src;

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const next_src = source.next() orelse @panic("blend: source iterator exhausted");
            const bg = simd.fromSlice(F32x16, dest[i..][0..16]);
            const src_c = blend_mod.mix(next_src, bg, blend_mode);
            const result = compose_mod.compose(blend_mode, src_c, bg, null);
            simd.storeSlice(result, dest[i..][0..16]);
        }
    }
};

/// Alpha compositing and blending with per-pixel alpha masks.
const alphaFill = struct {
    /// `result = src * mask + bg * (1 - src_alpha * mask)`, using FMA.
    fn alphaCompositeInner(
        dest: []f32,
        masks: [4]u8,
        src_c: F32x16,
        src_a: F32x16,
        one_v: F32x16,
    ) void {
        const bg = simd.fromSlice(F32x16, dest);
        const mask_a = extractMasks(masks);
        // 1 - src_a * mask_a
        const inv_src_a_mask_a = simd.mulAdd(-mask_a, src_a, one_v);

        const result = simd.mulAdd(bg, inv_src_a_mask_a, src_c * mask_a);
        simd.storeSlice(result, dest);
    }

    fn alphaCompositeSolid(dest: []f32, src: [4]f32, quads: anytype) void {
        std.debug.assert(dest.len % 16 == 0);
        var iter = quads;
        const src_a: F32x16 = @splat(src[3]);
        const src_c = colorVector(src);
        const one_v = one();

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const masks = iter.next() orelse @panic("alpha_composite_solid: mask iterator exhausted");
            alphaCompositeInner(dest[i..][0..16], masks, src_c, src_a, one_v);
        }
    }

    fn alphaCompositeArbitrary(dest: []f32, src: []const f32, quads: anytype) void {
        std.debug.assert(dest.len % 16 == 0);
        std.debug.assert(src.len >= dest.len);
        var iter = quads;
        const one_v = one();

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const masks = iter.next() orelse @panic("alpha_composite_arbitrary: mask iterator exhausted");
            const next_src = simd.fromSlice(F32x16, src[i..][0..16]);
            const src_a = simd.splat4th(next_src);
            alphaCompositeInner(dest[i..][0..16], masks, next_src, src_a, one_v);
        }
    }

    fn blend(dest: []f32, src: anytype, quads: anytype, blend_mode: peniko.BlendMode) void {
        std.debug.assert(dest.len % 16 == 0);
        var source = src;
        var quad_iter = quads;

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const next_src = source.next() orelse @panic("blend: source iterator exhausted");
            const masks_bytes = quad_iter.next() orelse @panic("blend: mask iterator exhausted");
            const masks = extractMasks(masks_bytes);

            const bg = simd.fromSlice(F32x16, dest[i..][0..16]);
            const src_c = blend_mod.mix(next_src, bg, blend_mode);
            const result = compose_mod.compose(blend_mode, src_c, bg, masks);
            simd.storeSlice(result, dest[i..][0..16]);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extract_color_matches_premultiplied_components" {
    const color = PremulColor.fromAlphaColor(peniko.Color.fromRgb8(255, 128, 64));
    const components = F32Kernel.extractColor(color);
    try testing.expectEqualSlices(f32, &color.asPremulF32().components, &components);
}

test "copy_solid_repeats_color" {
    var dest: [16]f32 = @splat(0.0);
    F32Kernel.copySolid(.fallback, &dest, .{ 0.25, 0.5, 0.75, 1.0 });
    try testing.expectEqualSlices(f32, &[_]f32{
        0.25, 0.5, 0.75, 1.0,
        0.25, 0.5, 0.75, 1.0,
        0.25, 0.5, 0.75, 1.0,
        0.25, 0.5, 0.75, 1.0,
    }, &dest);
}

test "unmasked_alpha_composite_solid" {
    var dest: [16]f32 = @splat(0.0);
    // backdrop = (0.4, 0.4, 0.4, 0.4)
    for (0..4) |i| {
        dest[4 * i + 0] = 0.4;
        dest[4 * i + 1] = 0.4;
        dest[4 * i + 2] = 0.4;
        dest[4 * i + 3] = 0.4;
    }

    F32Kernel.alphaCompositeSolid(.fallback, &dest, .{ 0.5, 0.0, 0.0, 0.5 }, null);

    // result = src + bg * (1 - src_a) = (0.5 + 0.2, 0.2, 0.2, 0.5 + 0.2)
    try testing.expectApproxEqAbs(@as(f32, 0.7), dest[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), dest[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), dest[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), dest[3], 1e-6);
}

test "masked_alpha_composite_solid" {
    var dest: [16]f32 = @splat(0.0);
    const alphas = [_]u8{ 255, 128, 0, 64 };
    F32Kernel.alphaCompositeSolid(.fallback, &dest, .{ 1.0, 0.0, 0.0, 1.0 }, &alphas);

    // mask_a = m / 255; result = src * mask_a on a zero backdrop.
    try testing.expectApproxEqAbs(@as(f32, 1.0), dest[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), dest[4], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dest[8], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), dest[12], 1e-6);
}

test "alpha_composite_buffer" {
    const src = [_]f32{
        0.5, 0.0, 0.0, 0.5,
        0.5, 0.0, 0.0, 0.5,
        0.5, 0.0, 0.0, 0.5,
        0.5, 0.0, 0.0, 0.5,
    };
    var dest: [16]f32 = @splat(1.0);

    F32Kernel.alphaCompositeBuffer(.fallback, &dest, &src, null);

    // result = src + bg * (1 - src_a) = 0.5 + 0.5 = 1.0 for RGB, alpha 0.5 + 0.5.
    for (0..4) |pixel| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), dest[4 * pixel + 0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1.0), dest[4 * pixel + 3], 1e-6);
    }
}

test "apply_mask_multiplies_components" {
    var dest: [16]f32 = @splat(0.5);
    const mask = F32Kernel.numericVecFromU8(@as(U8x16, @splat(128)));
    F32Kernel.applyMask(.fallback, &dest, fine.RepeatNumericVec(F32Kernel){ .value = mask });

    const expected = 0.5 * (128.0 / 255.0);
    for (dest) |value| {
        try testing.expectApproxEqAbs(@as(f32, expected), value, 1e-6);
    }
}

test "apply_tint_alpha_mask_and_multiply" {
    const tint = Tint{ .color = peniko.Color.fromRgb8(255, 0, 0), .mode = .alpha_mask };
    var dest: [16]f32 = @splat(0.5);
    F32Kernel.applyTint(.fallback, &dest, &tint);
    // tint_v = (1, 0, 0, 1); multiplied by the pixel alpha (0.5).
    try testing.expectApproxEqAbs(@as(f32, 0.5), dest[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dest[3], 1e-6);

    const multiply_tint = Tint{ .color = peniko.Color.fromRgb8(255, 255, 255), .mode = .multiply };
    var dest2: [16]f32 = @splat(0.5);
    F32Kernel.applyTint(.fallback, &dest2, &multiply_tint);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dest2[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dest2[3], 1e-6);
}

test "pack_matches_rust_saturating_cast" {
    // These are already-scaled values (`src * 255.0 + 0.5`).
    try testing.expectEqual(@as(u8, 0), roundToU8(std.math.nan(f32)));
    try testing.expectEqual(@as(u8, 0), roundToU8(-1.0));
    try testing.expectEqual(@as(u8, 0), roundToU8(0.0));
    try testing.expectEqual(@as(u8, 0), roundToU8(0.5));
    try testing.expectEqual(@as(u8, 127), roundToU8(127.5));
    try testing.expectEqual(@as(u8, 128), roundToU8(128.0));
    try testing.expectEqual(@as(u8, 255), roundToU8(255.0));
    try testing.expectEqual(@as(u8, 255), roundToU8(255.5));
    try testing.expectEqual(@as(u8, 255), roundToU8(1e9));
}
