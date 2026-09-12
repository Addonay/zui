//! Port of vello_cpu src/fine/lowp/blend.rs (Apache-2.0 OR MIT).
//!
//! Color mixing for the low-precision (u8) pipeline. Separable mix modes with
//! cheap integer formulas run in `u8`/`u16`; the remaining modes (`ColorDodge`,
//! `ColorBurn`, `SoftLight`, and the four non-separable modes) fall back to the
//! high-precision `f32x16` implementation and convert back, exactly like
//! upstream.
//!
//! Divergences from upstream (behavior-preserving):
//! - Upstream is generic over a `Simd` backend; this port fixes the
//!   fallback/baseline operation order with Zig vectors. Integer adds and
//!   multiplies use wrapping operators because that is what `fearless_simd`
//!   emits for its integer vectors (`u8::wrapping_add` et al.), so debug builds
//!   do not panic where upstream would wrap.
//! - `saturating_narrow`/`normalized_mul_u8` are transcribed as local helpers
//!   over `@Vector(32, u16)` instead of the sealed upstream traits.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const peniko = @import("../../../peniko/root.zig");
const common_util = @import("../../../common/util.zig");
const highp_blend = @import("../highp/blend.zig");

const U8x16 = simd.U8x16;
const U8x32 = simd.U8x32;
const F32x16 = simd.F32x16;
const Mix = peniko.Mix;

/// The widened counterpart of [`U8x32`] (`widen(u8x32)` upstream).
pub const U16x32 = @Vector(32, u16);
/// The shift type for 16-bit lanes.
const ShiftU16 = @Vector(32, std.math.Log2Int(u16));

/// `widen` for `u8x32` -> `u16x32`.
pub inline fn widen(v: U8x32) U16x32 {
    return @intCast(v);
}

/// `narrow` for `u16x32` -> `u8x32` (truncating).
pub inline fn narrow(v: U16x32) U8x32 {
    return @truncate(v);
}

/// `saturating_narrow` for `u16x32` -> `u8x32`.
pub inline fn saturatingNarrow(v: U16x32) U8x32 {
    return @intCast(@min(v, @as(U16x32, @splat(255))));
}

/// `Div255Ext::div_255` for `u16x32`: `(v + 255) >> 8`.
///
/// The wrapping add matches `fearless_simd`'s integer vector semantics; every
/// in-range call site stays below 65280 like upstream.
pub inline fn div255(v: U16x32) U16x32 {
    return (v +% @as(U16x32, @splat(255))) >> @as(ShiftU16, @splat(8));
}

/// Free-function `normalized_mul_u8` for `u8x32`, returning the widened
/// `u16x32` product (upstream `vello_common::util::normalized_mul_u8`).
pub inline fn normalizedMulWide(a: U8x32, b: U8x32) U16x32 {
    return div255(widen(a) *% widen(b));
}

/// Trait-method `normalized_mul` for `u8x32`, narrowing the widened product
/// back to `u8x32` (upstream `NormalizedMulExt`).
pub inline fn normalizedMul(a: U8x32, b: U8x32) U8x32 {
    return narrow(normalizedMulWide(a, b));
}

/// Build a 32-byte vector repeating one RGBA color eight times.
pub inline fn colorVector32(color: [4]u8) U8x32 {
    var out: U8x32 = undefined;
    inline for (0..8) |i| {
        out[4 * i + 0] = color[0];
        out[4 * i + 1] = color[1];
        out[4 * i + 2] = color[2];
        out[4 * i + 3] = color[3];
    }
    return out;
}

/// Convert 16 `u8` values to `f32` without normalization.
fn u8ToF32(val: U8x16) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..16) |i| {
        out[i] = @floatFromInt(val[i]);
    }
    return out;
}

/// Upstream `to_f32`: split into two `u8x16`, convert, and normalize.
fn toF32(val: U8x32) [2]F32x16 {
    const parts = simd.splitU8x32(val);
    var a = u8ToF32(parts[0]);
    var b = u8ToF32(parts[1]);
    a *= @as(F32x16, @splat(1.0 / 255.0));
    b *= @as(F32x16, @splat(1.0 / 255.0));
    return .{ a, b };
}

/// Upstream `to_u8`: `f32_to_u8(255.0 * val + 0.5)` for both halves, combined.
fn toU8(val1: F32x16, val2: F32x16) U8x32 {
    const scaled1 = simd.mulAddUnfused(
        val1,
        @as(F32x16, @splat(255.0)),
        @as(F32x16, @splat(0.5)),
    );
    const scaled2 = simd.mulAddUnfused(
        val2,
        @as(F32x16, @splat(255.0)),
        @as(F32x16, @splat(0.5)),
    );
    return simd.combineU8x16(common_util.f32ToU8(scaled1), common_util.f32ToU8(scaled2));
}

/// Upstream `mix`: u8 fast paths where available, f32 fallback otherwise.
pub fn mix(src_c: U8x32, bg_c: U8x32, blend_mode: peniko.BlendMode) U8x32 {
    if (tryU8Mix(blend_mode, src_c, bg_c)) |res| return res;

    // Fallback for blend modes that aren't supported in u8.
    const src = toF32(src_c);
    const bg = toF32(bg_c);
    const mixed_1 = highp_blend.mix(src[0], bg[0], blend_mode);
    const mixed_2 = highp_blend.mix(src[1], bg[1], blend_mode);
    return toU8(mixed_1, mixed_2);
}

/// Upstream `try_u8_mix`: `null` selects the f32 fallback.
fn tryU8Mix(blend_mode: peniko.BlendMode, src_c: U8x32, bg_c: U8x32) ?U8x32 {
    // We implement the u8 fast path for blend modes that
    // 1) are separable.
    // 2) don't have too many divisions, since integer normalization is
    //    relatively expensive.
    // In the future, it's possible to do further experimentation to see whether
    // some more blend modes are worth doing in integer space.
    return switch (blend_mode.mix) {
        .normal => src_c,
        .multiply => withSrcAlpha(multiplyInner(src_c, bg_c), src_c),
        .screen => withSrcAlpha(screenInner(src_c, bg_c), src_c),
        .overlay => withSrcAlpha(hardLightInner(src_c, bg_c, bg_c), src_c),
        .darken => withSrcAlpha(darkenInner(src_c, bg_c), src_c),
        .lighten => withSrcAlpha(lightenInner(src_c, bg_c), src_c),
        .hard_light => withSrcAlpha(hardLightInner(src_c, bg_c, src_c), src_c),
        .difference => withSrcAlpha(differenceInner(src_c, bg_c), src_c),
        .exclusion => withSrcAlpha(exclusionInner(src_c, bg_c), src_c),
        .color_dodge,
        .color_burn,
        .soft_light,
        .luminosity,
        .color,
        .hue,
        .saturation,
        => null,
    };
}

// Formula for blending is (see <https://www.w3.org/TR/compositing-1/#generalformula>):
//   Cs' = (1 - Ab) * Cs + Ab * B(Cb, Cs)
// Since vello_cpu expects premultiplied colors, we need to return:
//   M = As * Cs'
//     = As * (1 - Ab) * Cs + As * Ab * B(Cb, Cs)
//     = S * (1 - Ab) + As * Ab * B(Cb, Cs)
// where S = As * Cs and D = Ab * Cb (so just the premultiplied color).

/// Multiply:
///   B(Cb, Cs) = Cb * Cs
///   M = S * (1 - Ab) + S * D
fn multiplyInner(src_c: U8x32, bg_c: U8x32) U8x32 {
    const one_minus_bg_a = @as(U8x32, @splat(255)) -% simd.splat4th(bg_c);
    const p1 = normalizedMulWide(src_c, one_minus_bg_a);
    const p2 = normalizedMulWide(src_c, bg_c);

    return saturatingNarrow(p1 +% p2);
}

/// Screen:
///   B(Cb, Cs) = Cb + Cs - Cb * Cs
///   M = S + As * D - S * D
fn screenInner(src_c: U8x32, bg_c: U8x32) U8x32 {
    const p1 = normalizedMulWide(simd.splat4th(src_c), bg_c);
    const p2 = normalizedMulWide(src_c, bg_c);
    const res = (widen(src_c) +% p1) -% p2;

    return saturatingNarrow(res);
}

/// Darken:
///   B(Cb, Cs) = min(Cb, Cs)
///   M = S * (1 - Ab) + min(S * Ab, D * As)
fn darkenInner(src_c: U8x32, bg_c: U8x32) U8x32 {
    const src_a = simd.splat4th(src_c);
    const bg_a = simd.splat4th(bg_c);
    const p1 = normalizedMulWide(src_c, @as(U8x32, @splat(255)) -% bg_a);
    const p2 = @min(
        normalizedMulWide(src_c, bg_a),
        normalizedMulWide(bg_c, src_a),
    );

    return saturatingNarrow(p1 +% p2);
}

/// Lighten:
///   B(Cb, Cs) = max(Cb, Cs)
///   M = S * (1 - Ab) + max(S * Ab, D * As)
fn lightenInner(src_c: U8x32, bg_c: U8x32) U8x32 {
    const src_a = simd.splat4th(src_c);
    const bg_a = simd.splat4th(bg_c);
    const p1 = normalizedMulWide(src_c, @as(U8x32, @splat(255)) -% bg_a);
    const p2 = @max(
        normalizedMulWide(src_c, bg_a),
        normalizedMulWide(bg_c, src_a),
    );

    return saturatingNarrow(p1 +% p2);
}

/// Difference:
///   B(Cb, Cs) = abs(Cb - Cs)
///   M = S * (1 - Ab) + abs(S * Ab - D * As)
fn differenceInner(src_c: U8x32, bg_c: U8x32) U8x32 {
    const src_a = simd.splat4th(src_c);
    const bg_a = simd.splat4th(bg_c);
    const p1 = normalizedMulWide(src_c, @as(U8x32, @splat(255)) -% bg_a);
    const p2 = normalizedMulWide(src_c, bg_a);
    const p3 = normalizedMulWide(bg_c, src_a);
    const diff = @max(p2, p3) -% @min(p2, p3);

    return saturatingNarrow(p1 +% diff);
}

/// Exclusion:
///   B(Cb, Cs) = Cb + Cs - 2 * Cb * Cs
///   M = S + As * D - 2 * S * D
fn exclusionInner(src_c: U8x32, bg_c: U8x32) U8x32 {
    const p1 = normalizedMulWide(simd.splat4th(src_c), bg_c);
    const p2 = normalizedMulWide(src_c, bg_c);
    const res = widen(src_c) +% p1;
    const sub = p2 +% p2;
    const selected = @select(
        u16,
        res >= sub,
        res -% sub,
        @as(U16x32, @splat(0)),
    );

    return saturatingNarrow(selected);
}

/// Hard-light (also the basis of `Overlay`, with the condition swapped):
///   if Cs <= 0.5: B(Cb, Cs) = 2 * Cb * Cs
///   otherwise:    B(Cb, Cs) = 1 - 2 * (1 - Cb) * (1 - Cs)
fn hardLightInner(src_c: U8x32, bg_c: U8x32, condition: U8x32) U8x32 {
    const src = widen(src_c);
    const bg = widen(bg_c);
    const src_a = widen(simd.splat4th(src_c));
    const bg_a = widen(simd.splat4th(bg_c));
    const condition_a = widen(simd.splat4th(condition));
    const condition_w = widen(condition);

    const base = src *% (@as(U16x32, @splat(255)) -% bg_a);
    // Multiply branch: As * Ab * 2 * Cb * Cs = 2 * S * D.
    const multiply = (@as(U16x32, @splat(2)) *% src) *% bg;
    // Screen branch: As * Ab * (1 - 2 * (1 - Cb) * (1 - Cs))
    //              = As * Ab - 2 * (As - S) * (Ab - D).
    const screen = (src_a *% bg_a) -%
        ((@as(U16x32, @splat(2)) *% (src_a -% src)) *% (bg_a -% bg));
    // The spec condition is `Cs <= 0.5` but on unpremultiplied color.
    // Since `Cs = S / As`, we avoid division by multiplying both sides
    // by alpha: `Cs <= 0.5` => `S <= 0.5 * As` => `2 * S <= As`.
    const blended = @select(
        u16,
        (condition_w +% condition_w) <= condition_a,
        multiply,
        screen,
    );
    const res = div255(base +% blended);

    return saturatingNarrow(res);
}

/// Clamp the RGB channels to the source alpha and restore the source alpha.
///
/// It can happen that we end up with an R/G/B larger than the alpha value due
/// to arithmetic errors. We need to clamp to the alpha to ensure the color is
/// still a valid premultiplied color.
fn withSrcAlpha(rgb: U8x32, src_c: U8x32) U8x32 {
    // `u32x8::splat(u32::from_ne_bytes([0, 0, 0, 255])).to_bytes()`.
    var alpha_mask: U8x32 = undefined;
    inline for (0..8) |i| {
        alpha_mask[4 * i + 0] = 0;
        alpha_mask[4 * i + 1] = 0;
        alpha_mask[4 * i + 2] = 0;
        alpha_mask[4 * i + 3] = 255;
    }

    const rgb_clamped = @min(rgb, simd.splat4th(src_c));
    return (rgb_clamped & ~alpha_mask) | (src_c & alpha_mask);
}

// ---------------------------------------------------------------------------
// Tests (port of the upstream `#[cfg(test)]` module)
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Upstream `lowp_first_pixel_for_mix`.
fn lowpFirstPixelForMix(blend: Mix, src: [4]u8, bg: [4]u8) [4]u8 {
    const src_v = colorVector32(src);
    const bg_v = colorVector32(bg);
    const blend_mode = peniko.BlendMode.new(blend, .src_over);
    const res = mix(src_v, bg_v, blend_mode);
    var out: [4]u8 = undefined;
    out[0] = res[0];
    out[1] = res[1];
    out[2] = res[2];
    out[3] = res[3];
    return out;
}

/// Upstream `highp_first_pixel_for_mix`.
fn highpFirstPixelForMix(mix_mode: Mix, src: [4]u8, bg: [4]u8) [4]u8 {
    const to_f32 = struct {
        fn call(pixel: [4]u8) F32x16 {
            var values: [4]f32 = undefined;
            inline for (0..4) |i| {
                values[i] = @as(f32, @floatFromInt(pixel[i])) * (1.0 / 255.0);
            }
            const pixel_vec: simd.F32x4 = values;
            return simd.blockSplat(pixel_vec, pixel_vec, pixel_vec, pixel_vec);
        }
    }.call;

    const src_v = to_f32(src);
    const bg_v = to_f32(bg);
    const blend_mode = peniko.BlendMode.new(mix_mode, .src_over);

    const res = highp_blend.mix(src_v, bg_v, blend_mode);
    const scaled = simd.mulAddUnfused(
        res,
        @as(F32x16, @splat(255.0)),
        @as(F32x16, @splat(0.5)),
    );
    const converted = common_util.f32ToU8(scaled);
    return .{ converted[0], converted[1], converted[2], converted[3] };
}

/// Upstream `assert_lowp_matches_highp`.
fn expectLowpMatchesHighp(mix_mode: Mix, src: [4]u8, bg: [4]u8) !void {
    const MAX_DELTA: u8 = 2;

    const lowp = lowpFirstPixelForMix(mix_mode, src, bg);
    const highp = highpFirstPixelForMix(mix_mode, src, bg);

    const lowp_alpha = lowp[3];
    try testing.expectEqual(src[3], lowp_alpha);
    for (lowp[0..3], 0..) |component_value, component| {
        if (component_value > lowp_alpha) {
            std.debug.print(
                "{s} component {d} exceeded alpha: lowp={any}, src={any}, bg={any}\n",
                .{ @tagName(mix_mode), component, lowp, src, bg },
            );
            return error.TestUnexpectedResult;
        }
    }

    for (lowp, highp, 0..) |low, high, component| {
        const delta = if (low > high) low - high else high - low;
        if (delta > MAX_DELTA) {
            std.debug.print(
                "{s} component {d} differed by {d}: lowp={any}, highp={any}, src={any}, bg={any}\n",
                .{ @tagName(mix_mode), component, delta, lowp, highp, src, bg },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "multiply_does_not_wrap" {
    try expectLowpMatchesHighp(.multiply, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 129 });
}

test "screen_does_not_wrap" {
    try expectLowpMatchesHighp(.screen, .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 });
}

test "darken_does_not_wrap" {
    try expectLowpMatchesHighp(.darken, .{ 20, 20, 20, 20 }, .{ 92, 92, 92, 92 });
}

test "lighten_does_not_wrap" {
    try expectLowpMatchesHighp(.lighten, .{ 1, 1, 1, 2 }, .{ 129, 129, 129, 131 });
}

test "difference_does_not_wrap" {
    try expectLowpMatchesHighp(.difference, .{ 1, 1, 1, 2 }, .{ 129, 129, 129, 193 });
}

test "exclusion_does_not_wrap" {
    try expectLowpMatchesHighp(.exclusion, .{ 128, 128, 128, 255 }, .{ 128, 128, 128, 255 });
}

test "hard_light_does_not_wrap" {
    try expectLowpMatchesHighp(.hard_light, .{ 1, 1, 1, 2 }, .{ 2, 2, 2, 2 });
}

test "overlay_does_not_wrap" {
    try expectLowpMatchesHighp(.overlay, .{ 0, 0, 0, 1 }, .{ 1, 1, 1, 1 });
}
