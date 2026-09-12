//! Port of vello_cpu src/fine/lowp/mod.rs (Apache-2.0 OR MIT).
//!
//! Low-precision (u8/u16) fine rasterization kernel. Color components are
//! premultiplied bytes in `0..255`; intermediate products widen to `u16` and
//! divide by 255 with the upstream `(v + 255) >> 8` approximation.
//!
//! `U8Kernel` implements the same comptime surface as `highp.F32Kernel`
//! (documented in `../mod.zig`): `Numeric`/`Composite`/`NumericVec`, the
//! neutral values, packing, and the compositing/blending entry points. Painter
//! selection for indexed paints happens in `Fine.indexedFill`, which dispatches
//! on `K.Numeric` and uses the u8-native bilinear image painters from
//! `lowp/image.zig` and the u8 LUT gradient painter from `lowp/gradient.zig`
//! exactly where upstream's `U8Kernel` overrides the defaults.
//!
//! Divergences from upstream (behavior-preserving):
//! - No `Simd` backend parameter: the port pins the fixed-width `@Vector`
//!   semantics from `src/simd`.
//! - Integer wrapping semantics are explicit (`+%`, `-%`, `*%`) because
//!   `fearless_simd` emits wrapping integer vector ops; this also keeps debug
//!   builds panic-free on out-of-gamut premultiplied inputs, which upstream's
//!   release builds wrap.
//! - The `u8x64` batch in `fill::alphaCompositeSolid` is loaded as two
//!   `u8x32` halves (no 64-lane alias is declared in `src/simd`).
//! - Upstream panics on a missing iterator element (`unwrap`); the port's
//!   loops stop at the shorter iterator like `zip`, and `applyMask` panics
//!   with an explicit message because its contract is fixed-length.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const common_util = @import("../../../common/util.zig");
const geometry = @import("../../../common/geometry.zig");
const mask_mod = @import("../../../common/mask.zig");
const paint_mod = @import("../../../common/paint.zig");
const peniko = @import("../../../peniko/root.zig");
const region_mod = @import("../../region.zig");
const blend_mod = @import("blend.zig");
const compose_mod = @import("compose.zig");

/// The u8-native gradient painter (upstream `lowp::gradient`).
pub const gradient = @import("gradient.zig");
/// The u8-native bilinear image painters (upstream `lowp::image`).
pub const image = @import("image.zig");
/// The u8 color-mixing helpers (upstream `lowp::blend`).
pub const blend = blend_mod;
/// The u8 Porter-Duff composition helpers (upstream `lowp::compose`).
pub const compose = compose_mod;

const U8x16 = simd.U8x16;
const U8x32 = simd.U8x32;
const F32x16 = simd.F32x16;
const U16x32 = blend_mod.U16x32;
const Mask = mask_mod.Mask;
const PremulColor = paint_mod.PremulColor;
const Tint = paint_mod.Tint;
const Region = region_mod.Region;

/// Number of color components per pixel (RGBA).
const COLOR_COMPONENTS: usize = 4;
/// The tile width in pixels.
const TILE_WIDTH: u16 = 4;
/// The tile height in pixels.
const TILE_HEIGHT: u16 = 4;
/// Number of color components in a single column of a tile.
const TILE_HEIGHT_COMPONENTS: usize = @as(usize, TILE_HEIGHT) * COLOR_COMPONENTS;

/// The kernel for doing rendering using u8/u16.
pub const U8Kernel = struct {
    /// The basic numeric type of the kernel.
    pub const Numeric = u8;
    /// The zero value for this numeric type.
    pub const ZERO: u8 = 0;
    /// The maximum opacity value for this numeric type.
    pub const ONE: u8 = 255;
    /// The SIMD composite type used for batch blending/compositing.
    pub const Composite = U8x32;
    /// The SIMD vector type used for conversions between u8 and f32.
    pub const NumericVec = U8x16;
    /// The number of numeric values per composite vector.
    pub const COMPOSITE_LENGTH: usize = 32;

    /// Build a composite from a numeric slice.
    pub fn compositeFromSlice(slice: []const u8) Composite {
        return simd.fromSlice(U8x32, slice);
    }

    /// Build a composite by repeating a single RGBA color across eight pixels.
    pub fn compositeFromColor(color: [4]u8) Composite {
        return blend_mod.colorVector32(color);
    }

    /// Numeric-vector conversion from `f32x16`, scaled by 255 and rounded.
    pub fn numericVecFromF32(val: F32x16) NumericVec {
        return common_util.f32ToU8(simd.mulAddUnfused(
            val,
            @as(F32x16, @splat(255.0)),
            @as(F32x16, @splat(0.5)),
        ));
    }

    /// Numeric-vector conversion from `u8x16` (identity for this kernel).
    pub fn numericVecFromU8(val: U8x16) NumericVec {
        return val;
    }

    /// Extract RGBA color components from a premultiplied color as u8 values.
    pub fn extractColor(color: PremulColor) [4]u8 {
        return color.asPremulRgba8().toU8Array();
    }

    /// Fill a buffer with a solid color.
    pub fn copySolid(_: simd.Level, dest: []u8, src: [4]u8) void {
        // Upstream `cast_slice_mut::<u8, u32>(dest).fill(u32::from_ne_bytes(src))`.
        std.debug.assert(dest.len % COLOR_COMPONENTS == 0);
        var i: usize = 0;
        while (i + COLOR_COMPONENTS <= dest.len) : (i += COLOR_COMPONENTS) {
            dest[i..][0..COLOR_COMPONENTS].* = src;
        }
    }

    /// Apply per-pixel mask values to a buffer by multiplying each component.
    pub fn applyMask(_: simd.Level, dest: []u8, src: anytype) void {
        std.debug.assert(dest.len % 16 == 0);
        var iter = src;

        var i: usize = 0;
        while (i < dest.len) : (i += 16) {
            const loaded = simd.fromSlice(U8x16, dest[i..][0..16]);
            const mask = iter.next() orelse @panic("apply_mask: mask iterator exhausted");
            simd.storeSlice(
                common_util.narrow(common_util.normalizedMulU8(loaded, mask)),
                dest[i..][0..16],
            );
        }
    }

    /// Apply an image tint to an already-painted buffer.
    pub fn applyTint(_: simd.Level, dest: []u8, tint: *const Tint) void {
        const premul = tint.color.premultiply();
        const components = premul.components;
        var color_bytes: [4]u8 = undefined;
        inline for (0..4) |i| color_bytes[i] = tintComponentToU8(components[i]);
        const tint_v = blend_mod.colorVector32(color_bytes);

        switch (tint.mode) {
            .alpha_mask => {
                var i: usize = 0;
                while (i + 32 <= dest.len) : (i += 32) {
                    const pixel = simd.fromSlice(U8x32, dest[i..][0..32]);
                    const alphas = simd.splat4th(pixel);
                    simd.storeSlice(blend_mod.normalizedMul(tint_v, alphas), dest[i..][0..32]);
                }
            },
            .multiply => {
                var i: usize = 0;
                while (i + 32 <= dest.len) : (i += 32) {
                    const pixel = simd.fromSlice(U8x32, dest[i..][0..32]);
                    simd.storeSlice(blend_mod.normalizedMul(pixel, tint_v), dest[i..][0..32]);
                }
            },
        }
    }

    /// Composites a solid color onto a buffer using alpha blending.
    pub fn alphaCompositeSolid(
        _: simd.Level,
        dest: []u8,
        src: [4]u8,
        alphas: ?[]const u8,
    ) void {
        if (alphas) |alpha_slice| {
            var alpha_iter = Alpha8Iter{ .data = alpha_slice };
            alphaFill.alphaCompositeSolid(dest, src, &alpha_iter);
        } else {
            fill.alphaCompositeSolid(dest, src);
        }
    }

    /// Composites a source buffer onto a destination buffer using alpha
    /// blending.
    pub fn alphaCompositeBuffer(
        _: simd.Level,
        dest: []u8,
        src: []const u8,
        alphas: ?[]const u8,
    ) void {
        if (alphas) |alpha_slice| {
            var alpha_iter = Alpha8Iter{ .data = alpha_slice };
            alphaFill.alphaComposite(dest, Chunk32Iter{ .data = src }, &alpha_iter);
        } else {
            fill.alphaComposite(dest, Chunk32Iter{ .data = src });
        }
    }

    /// Applies a blend mode to composite source pixels onto destination.
    pub fn blend(
        _: simd.Level,
        dest: []u8,
        start_x: u16,
        start_y: u16,
        src: anytype,
        blend_mode: peniko.BlendMode,
        alphas: ?[]const u8,
        mask: ?*const Mask,
    ) void {
        if (alphas) |alpha_slice| {
            var alpha_iter = Alpha8Iter{ .data = alpha_slice };
            if (mask) |m| {
                var mask_iter = MaskPairIter{ .m = m, .x = start_x, .y = start_y };
                var product = AlphaMaskProductIter{ .a = &alpha_iter, .b = &mask_iter };
                alphaFill.blend(dest, src, blend_mode, &product);
            } else {
                alphaFill.blend(dest, src, blend_mode, &alpha_iter);
            }
        } else if (mask) |m| {
            var mask_iter = MaskPairIter{ .m = m, .x = start_x, .y = start_y };
            alphaFill.blend(dest, src, blend_mode, &mask_iter);
        } else {
            fill.blend(dest, src, blend_mode);
        }
    }

    /// Fill a row scratch span with a solid color, optionally modulated by
    /// per-pixel alphas.
    pub fn fillSolid(level: simd.Level, dest: []u8, color: PremulColor, alphas: ?[]const u8) void {
        const extracted = extractColor(color);

        if (extracted[3] == ONE and alphas == null) {
            copySolid(level, dest, extracted);
        } else {
            alphaCompositeSolid(level, dest, extracted, alphas);
        }
    }

    /// Pack row scratch data into a row-major output buffer.
    pub fn pack(_: simd.Level, scratch: []const u8, width: usize, region: *Region) void {
        const block_width = if (region.height == TILE_HEIGHT)
            (width / TILE_WIDTH) * TILE_WIDTH
        else
            0;
        if (block_width > 0) {
            packBlock(scratch, block_width, region);
        }

        const tail_width = width - block_width;
        if (tail_width > 0) {
            packTail(
                scratch[block_width * TILE_HEIGHT_COMPONENTS ..],
                block_width,
                tail_width,
                region,
            );
        }
    }

    /// Unpack row-major input data into row scratch.
    pub fn unpack(_: simd.Level, region: *Region, width: usize, scratch: []u8) void {
        const block_width = if (region.height == TILE_HEIGHT)
            (width / TILE_WIDTH) * TILE_WIDTH
        else
            0;
        if (block_width > 0) {
            unpackBlock(region, block_width, scratch);
        }

        const tail_width = width - block_width;
        if (tail_width > 0) {
            unpackTail(
                region,
                block_width,
                tail_width,
                scratch[block_width * TILE_HEIGHT_COMPONENTS ..],
            );
        }
    }
};

/// Rust `(value * 255.0 + 0.5) as u8` for the tint color components.
fn tintComponentToU8(value: f32) u8 {
    const scaled = value * 255.0 + 0.5;
    if (std.math.isNan(scaled)) return 0;
    if (scaled <= 0.0) return 0;
    if (scaled >= 255.0) return 255;
    return @intFromFloat(scaled);
}

/// Upstream `pack_block`: deinterleave full 4-pixel columns into rows.
fn packBlock(scratch: []const u8, width: usize, region: *Region) void {
    var row_offsets: [4]usize = .{ 0, 0, 0, 0 };

    var dx: usize = 0;
    while (dx < width) : (dx += 4) {
        inline for (0..4) |y| {
            const row = region.areas[y];
            inline for (0..4) |col| {
                const src = (dx + col) * TILE_HEIGHT_COMPONENTS + y * COLOR_COMPONENTS;
                @memcpy(
                    row[row_offsets[y]..][0..COLOR_COMPONENTS],
                    scratch[src..][0..COLOR_COMPONENTS],
                );
                row_offsets[y] += COLOR_COMPONENTS;
            }
        }
    }
}

/// Upstream `pack_tail`: copy the remaining columns one pixel at a time.
fn packTail(scratch: []const u8, x: usize, width: usize, region: *Region) void {
    for (0..region.height) |y| {
        const row = region.areas[y][x * COLOR_COMPONENTS ..][0 .. width * COLOR_COMPONENTS];
        for (0..width) |dx| {
            const idx = COLOR_COMPONENTS * (@as(usize, TILE_HEIGHT) * dx + y);
            @memcpy(
                row[dx * COLOR_COMPONENTS ..][0..COLOR_COMPONENTS],
                scratch[idx..][0..COLOR_COMPONENTS],
            );
        }
    }
}

/// Upstream `unpack_block`: interleave rows back into 4-pixel columns.
fn unpackBlock(region: *Region, width: usize, scratch: []u8) void {
    var row_offsets: [4]usize = .{ 0, 0, 0, 0 };

    var dx: usize = 0;
    while (dx < width) : (dx += 1) {
        const col = scratch[dx * TILE_HEIGHT_COMPONENTS ..][0..TILE_HEIGHT_COMPONENTS];
        inline for (0..4) |y| {
            const row = region.areas[y];
            @memcpy(
                col[y * COLOR_COMPONENTS ..][0..COLOR_COMPONENTS],
                row[row_offsets[y]..][0..COLOR_COMPONENTS],
            );
            row_offsets[y] += COLOR_COMPONENTS;
        }
    }
}

/// Upstream `unpack_tail`.
fn unpackTail(region: *Region, x: usize, width: usize, scratch: []u8) void {
    for (0..region.height) |y| {
        const row = region.areas[y][x * COLOR_COMPONENTS ..][0 .. width * COLOR_COMPONENTS];
        for (0..width) |dx| {
            const idx = COLOR_COMPONENTS * (@as(usize, TILE_HEIGHT) * dx + y);
            @memcpy(
                scratch[idx..][0..COLOR_COMPONENTS],
                row[dx * COLOR_COMPONENTS ..][0..COLOR_COMPONENTS],
            );
        }
    }
}

/// Alpha compositing and blending operations without per-pixel alpha masks.
const fill = struct {
    /// Applies blend mode compositing to a buffer without per-pixel masks.
    fn blend(dest: []u8, src: anytype, blend_mode: peniko.BlendMode) void {
        var source = src;
        const default_mix = blend_mode.mix == .normal;

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const next_src = source.next() orelse break;
            const bg_v = simd.fromSlice(U8x32, dest[i..][0..32]);
            const src_c = if (default_mix)
                next_src
            else
                blend_mod.mix(next_src, bg_v, blend_mode);
            const res = compose_mod.compose(src_c, bg_v, blend_mode, null);
            simd.storeSlice(res, dest[i..][0..32]);
        }
    }

    /// Composites a solid color onto a buffer using alpha blending.
    ///
    /// Uses the "over" operator: `result = src + bg * (1 - src_alpha)`
    fn alphaCompositeSolid(dest: []u8, src: [4]u8) void {
        const one_minus_alpha = @as(U8x32, @splat(255)) -% @as(U8x32, @splat(src[3]));
        const src_c = blend_mod.colorVector32(src);

        var i: usize = 0;
        while (i + 64 <= dest.len) : (i += 64) {
            // We process in batches of 64 because loading/storing is much
            // faster this way (at least on NEON), but since we widen to u16,
            // we can only work with 256 bits, so we split it up.
            const bg_1 = simd.fromSlice(U8x32, dest[i..][0..32]);
            const bg_2 = simd.fromSlice(U8x32, dest[i + 32 ..][0..32]);
            const res_1 = alphaCompositeInner(bg_1, src_c, one_minus_alpha);
            const res_2 = alphaCompositeInner(bg_2, src_c, one_minus_alpha);
            simd.storeSlice(res_1, dest[i..][0..32]);
            simd.storeSlice(res_2, dest[i + 32 ..][0..32]);
        }
    }

    /// Composites a buffer of colors onto another buffer using alpha blending.
    fn alphaComposite(dest: []u8, src: anytype) void {
        var source = src;

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const next_src = source.next() orelse break;
            const one_minus_alpha = @as(U8x32, @splat(255)) -% simd.splat4th(next_src);
            const bg_v = simd.fromSlice(U8x32, dest[i..][0..32]);
            const res = alphaCompositeInner(bg_v, next_src, one_minus_alpha);
            simd.storeSlice(res, dest[i..][0..32]);
        }
    }

    /// Formula: `result = src + bg * (1 - src_alpha)`.
    fn alphaCompositeInner(bg: U8x32, src: U8x32, one_minus_alpha: U8x32) U8x32 {
        return blend_mod.normalizedMul(bg, one_minus_alpha) +% src;
    }
};

/// Alpha compositing and blending operations with per-pixel alpha masks.
const alphaFill = struct {
    /// Applies blend mode compositing with per-pixel alpha masks.
    fn blend(dest: []u8, src: anytype, blend_mode: peniko.BlendMode, alphas: anytype) void {
        var source = src;
        var alpha_iter = alphas;
        const default_mix = blend_mode.mix == .normal;

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const next_src = source.next() orelse break;
            const next_mask = alpha_iter.next() orelse break;
            const bg_v = simd.fromSlice(U8x32, dest[i..][0..32]);
            const src_c = if (default_mix)
                next_src
            else
                blend_mod.mix(next_src, bg_v, blend_mode);
            const masks = extractMasks(next_mask);
            const res = compose_mod.compose(src_c, bg_v, blend_mode, masks);
            simd.storeSlice(res, dest[i..][0..32]);
        }
    }

    /// Composites a solid color with per-pixel alpha masks.
    fn alphaCompositeSolid(dest: []u8, src: [4]u8, alphas: anytype) void {
        const src_a: U8x32 = @splat(src[3]);
        const src_c = blend_mod.colorVector32(src);
        const one: U8x32 = @splat(255);

        var alpha_iter = alphas;
        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const next_mask = alpha_iter.next() orelse break;
            alphaCompositeInner(dest[i..][0..32], next_mask, src_c, src_a, one);
        }
    }

    /// Composites a buffer of colors with per-pixel alpha masks.
    fn alphaComposite(dest: []u8, src: anytype, alphas: anytype) void {
        var source = src;
        var alpha_iter = alphas;
        const one: U8x32 = @splat(255);

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const next_src = source.next() orelse break;
            const next_mask = alpha_iter.next() orelse break;
            const src_a = simd.splat4th(next_src);
            alphaCompositeInner(dest[i..][0..32], next_mask, next_src, src_a, one);
        }
    }

    /// Formula: `result = src * mask + bg * (1 - src_alpha * mask)`.
    fn alphaCompositeInner(
        dest: []u8,
        masks: [8]u8,
        src_c: U8x32,
        src_a: U8x32,
        one: U8x32,
    ) void {
        const bg_v = simd.fromSlice(U8x32, dest);

        const mask_v = extractMasks(masks);
        const inv_src_a_mask_a = one -%
            blend_mod.narrow(blend_mod.normalizedMulWide(src_a, mask_v));

        const bg = blend_mod.widen(bg_v);
        const inv = blend_mod.widen(inv_src_a_mask_a);
        const src = blend_mod.widen(src_c);
        const mask = blend_mod.widen(mask_v);
        const result = blend_mod.div255((bg *% inv) +% (src *% mask));
        const res = blend_mod.narrow(result);

        simd.storeSlice(res, dest);
    }
};

/// Expands 8 mask bytes into a 32-byte vector where each pixel's 4 components
/// share the same mask value.
///
/// Input: [m0, m1, ..., m7]
/// Output: [m0, m0, m0, m0, m1, m1, m1, m1, ..., m7, m7, m7, m7]
fn extractMasks(masks: [8]u8) U8x32 {
    var out: U8x32 = undefined;
    inline for (0..8) |pixel| {
        inline for (0..4) |component| {
            out[pixel * 4 + component] = masks[pixel];
        }
    }
    return out;
}

/// Per-two-column `[u8; 8]` alpha quadruples from a strip alpha buffer.
const Alpha8Iter = struct {
    data: []const u8,
    idx: usize = 0,

    fn next(self: *@This()) ?[8]u8 {
        if (self.idx + 8 > self.data.len) return null;
        const quad = self.data[self.idx..][0..8].*;
        self.idx += 8;
        return quad;
    }
};

/// Per-two-column `[u8; 8]` samples from a render mask.
///
/// Out-of-bounds samples yield `255` (no masking), matching `U8Kernel::blend`
/// upstream (this differs from `Fine::mask`, which yields `0`).
const MaskPairIter = struct {
    m: *const Mask,
    x: u16,
    y: u16,

    fn next(self: *@This()) ?[8]u8 {
        const width = self.m.width();
        const height = self.m.height();

        const Sample = struct {
            fn call(m: *const Mask, x: u16, y: u16, w: u16, h: u16) u8 {
                if (x < w and y < h) return m.sample(x, y);
                return 255;
            }
        };

        const samples = [8]u8{
            Sample.call(self.m, self.x, self.y, width, height),
            Sample.call(self.m, self.x, self.y +% 1, width, height),
            Sample.call(self.m, self.x, self.y +% 2, width, height),
            Sample.call(self.m, self.x, self.y +% 3, width, height),
            Sample.call(self.m, self.x +% 1, self.y, width, height),
            Sample.call(self.m, self.x +% 1, self.y +% 1, width, height),
            Sample.call(self.m, self.x +% 1, self.y +% 2, width, height),
            Sample.call(self.m, self.x +% 1, self.y +% 3, width, height),
        };

        self.x +%= 2;

        return samples;
    }
};

/// Component-wise `div_255(a * b)` combination of alpha pairs and mask pairs.
const AlphaMaskProductIter = struct {
    a: *Alpha8Iter,
    b: *MaskPairIter,

    fn next(self: *@This()) ?[8]u8 {
        const a1 = self.a.next() orelse return null;
        const a2 = self.b.next() orelse return null;

        var out: [8]u8 = undefined;
        inline for (0..8) |i| {
            // Upstream `div_255(a1 as u16 * a2 as u16) as u8`.
            const product = @as(u16, a1[i]) * @as(u16, a2[i]);
            out[i] = @intCast((product + 255) >> 8);
        }
        return out;
    }
};

/// An iterator over 32-byte chunks of a numeric buffer.
const Chunk32Iter = struct {
    data: []const u8,
    idx: usize = 0,

    fn next(self: *@This()) ?U8x32 {
        if (self.idx + 32 > self.data.len) return null;
        const chunk = simd.fromSlice(U8x32, self.data[self.idx..][0..32]);
        self.idx += 32;
        return chunk;
    }
};

// ---------------------------------------------------------------------------
// Tests (port of the upstream `#[cfg(test)]` module)
// ---------------------------------------------------------------------------

const testing = std.testing;
const Pixmap = @import("../../../common/pixmap.zig").Pixmap;
const RectU16 = geometry.RectU16;

fn testPackUnpackRoundtrip(
    comptime width: u16,
    comptime pack_fn: fn (level: simd.Level, scratch: []const u8, width: usize, region: *Region) void,
    comptime unpack_fn: fn (level: simd.Level, region: *Region, width: usize, scratch: []u8) void,
) !void {
    const allocator = testing.allocator;
    const height = TILE_HEIGHT;
    const scratch_len = @as(usize, width) * TILE_HEIGHT_COMPONENTS;
    const width_usize = @as(usize, width);

    // Just some pseudo-random numbers.
    var scratch: [scratch_len]u8 = undefined;
    for (0..scratch_len) |n| {
        scratch[n] = @intCast((n * 7 + 13) % 256);
    }

    var pixmap = try Pixmap.init(allocator, width, height);
    defer pixmap.deinit(allocator);

    {
        var pixmap_mut = pixmap.asMut();
        var region = Region.init(&pixmap_mut, RectU16.new(0, 0, width, height));
        pack_fn(.fallback, &scratch, width_usize, &region);
    }

    var unpacked: [scratch_len]u8 = @splat(0);
    {
        var pixmap_mut = pixmap.asMut();
        var region = Region.init(&pixmap_mut, RectU16.new(0, 0, width, height));
        unpack_fn(.fallback, &region, width_usize, &unpacked);
    }

    try testing.expectEqualSlices(u8, &scratch, &unpacked);
}

test "pack_block_unpack_block_roundtrip" {
    try testPackUnpackRoundtrip(TILE_WIDTH * 2, U8Kernel.pack, U8Kernel.unpack);
}

test "pack_unpack_roundtrip" {
    try testPackUnpackRoundtrip(TILE_WIDTH * 2 + 1, U8Kernel.pack, U8Kernel.unpack);
}

test "kernel conversions scale f32 and keep u8" {
    // `u8x16::from_f32`: `f32_to_u8(v * 255.0 + 0.5)`.
    const from_f32 = U8Kernel.numericVecFromF32(@as(F32x16, @splat(0.5)));
    try testing.expectEqual(@as(u8, 128), from_f32[0]);

    const from_u8 = U8Kernel.numericVecFromU8(@as(U8x16, @splat(200)));
    try testing.expectEqual(@as(u8, 200), from_u8[0]);

    const color = PremulColor.fromAlphaColor(peniko.Color.fromRgb8(255, 128, 64));
    try testing.expectEqualSlices(
        u8,
        &color.asPremulRgba8().toU8Array(),
        &U8Kernel.extractColor(color),
    );

    try testing.expectEqual(@as(u8, 255), U8Kernel.ONE);
    try testing.expectEqual(@as(u8, 0), U8Kernel.ZERO);
}

test "apply_tint alpha_mask and multiply" {
    // Opaque red tint: (255, 0, 0, 255).
    const alpha_tint = Tint{ .color = peniko.Color.fromRgb8(255, 0, 0), .mode = .alpha_mask };
    var dest: [32]u8 = @splat(128);
    U8Kernel.applyTint(.fallback, &dest, &alpha_tint);

    // tint_v * pixel_alpha = (255, 0, 0, 255) * (128, ...) / 255.
    inline for (0..8) |pixel| {
        try testing.expectEqual(@as(u8, 128), dest[4 * pixel + 0]);
        try testing.expectEqual(@as(u8, 0), dest[4 * pixel + 1]);
        try testing.expectEqual(@as(u8, 0), dest[4 * pixel + 2]);
        try testing.expectEqual(@as(u8, 128), dest[4 * pixel + 3]);
    }

    // A white multiply tint is the identity.
    const white_tint = Tint{ .color = peniko.Color.WHITE, .mode = .multiply };
    var dest2: [32]u8 = @splat(200);
    U8Kernel.applyTint(.fallback, &dest2, &white_tint);
    inline for (0..32) |i| {
        try testing.expectEqual(@as(u8, 200), dest2[i]);
    }
}

test "extract_masks_repeats_each_byte_four_times" {
    const masks = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const extracted = extractMasks(masks);
    inline for (0..8) |pixel| {
        inline for (0..4) |component| {
            try testing.expectEqual(masks[pixel], extracted[pixel * 4 + component]);
        }
    }
}
