//! Port of vello_cpu src/fine/highp/blend.rs (Apache-2.0 OR MIT).
//!
//! Color mixing from the W3C *Compositing and Blending Level 1* draft, on
//! interleaved `f32x16` (4 pixels of RGBA). Separable mix modes operate on the
//! unpremultiplied per-channel vectors; the non-separable modes follow the
//! upstream `set_lum`/`set_sat`/`clip_color` helpers.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const peniko = @import("../../../peniko/root.zig");
const util = @import("../../util.zig");

const F32x4 = simd.F32x4;
const F32x16 = simd.F32x16;
const Mix = peniko.Mix;

fn splat4(value: f32) F32x4 {
    return @splat(value);
}

fn splat16(value: f32) F32x16 {
    return @splat(value);
}

/// Unpremultiplied RGB channels for one `F32x4` block of pixels.
const Channels = struct {
    r: F32x4,
    g: F32x4,
    b: F32x4,

    fn unpremultiply(self: Channels, a: F32x4) Channels {
        return .{
            .r = util.unpremultiply(self.r, a),
            .g = util.unpremultiply(self.g, a),
            .b = util.unpremultiply(self.b, a),
        };
    }
};

/// The split representation of an interleaved RGBA vector.
const Split = struct {
    channels: Channels,
    a: F32x4,
};

/// Apply a blend mode's mixing function to `src_c` (premultiplied source) and
/// `bg` (premultiplied backdrop), returning the mixed source color.
pub fn mix(src_c: F32x16, bg: F32x16, blend_mode: peniko.BlendMode) F32x16 {
    if (blend_mode.mix == .normal) {
        return src_c;
    }

    // See <https://www.w3.org/TR/compositing-1/#blending>.
    const bg_split = split(bg);
    const src_split = split(src_c);

    const unpremultiplied_bg = bg_split.channels.unpremultiply(bg_split.a);
    const unpremultiplied_src = src_split.channels.unpremultiply(src_split.a);

    var res_bg = unpremultiplied_bg;
    const mixed = mixChannels(blend_mode.mix, unpremultiplied_src, unpremultiplied_bg);

    res_bg.r = applyAlpha(bg_split.a, src_split.a, unpremultiplied_src.r, mixed.r);
    res_bg.g = applyAlpha(bg_split.a, src_split.a, unpremultiplied_src.g, mixed.g);
    res_bg.b = applyAlpha(bg_split.a, src_split.a, unpremultiplied_src.b, mixed.b);

    return interleave(res_bg, src_split.a);
}

fn split(input: F32x16) Split {
    var storage: [16]f32 = @splat(0.0);
    simd.storeSlice(input, &storage);

    var r: F32x4 = undefined;
    var g: F32x4 = undefined;
    var b: F32x4 = undefined;
    var a: F32x4 = undefined;
    inline for (0..4) |i| {
        r[i] = storage[4 * i + 0];
        g[i] = storage[4 * i + 1];
        b[i] = storage[4 * i + 2];
        a[i] = storage[4 * i + 3];
    }

    return .{ .channels = .{ .r = r, .g = g, .b = b }, .a = a };
}

fn interleave(channels: Channels, a: F32x4) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..4) |i| {
        out[4 * i + 0] = channels.r[i];
        out[4 * i + 1] = channels.g[i];
        out[4 * i + 2] = channels.b[i];
        out[4 * i + 3] = a[i];
    }
    return out;
}

fn applyAlpha(
    bg_a: F32x4,
    src_a: F32x4,
    unpremultiplied_src_channel: F32x4,
    mix_src_channel: F32x4,
) F32x4 {
    const p1 = (splat4(1.0) - bg_a) * unpremultiplied_src_channel;
    const p2 = bg_a * mix_src_channel;

    return util.premultiply(p1 + p2, src_a);
}

fn mixChannels(mode: Mix, src: Channels, bg: Channels) Channels {
    return switch (mode) {
        .normal => src,
        .multiply => separable(multiplySingle, src, bg),
        .screen => separable(screenSingle, src, bg),
        .overlay => separable(overlaySingle, src, bg),
        .darken => separable(minSingle, src, bg),
        .lighten => separable(maxSingle, src, bg),
        .color_dodge => separable(colorDodgeSingle, src, bg),
        .color_burn => separable(colorBurnSingle, src, bg),
        .hard_light => separable(hardLightSingle, src, bg),
        .soft_light => separable(softLightSingle, src, bg),
        .difference => separable(differenceSingle, src, bg),
        .exclusion => separable(exclusionSingle, src, bg),
        .luminosity => luminosityMix(src, bg),
        .color => colorMix(src, bg),
        .hue => hueMix(src, bg),
        .saturation => saturationMix(src, bg),
    };
}

fn separable(comptime calc: fn (F32x4, F32x4) F32x4, src: Channels, bg: Channels) Channels {
    return .{
        .r = calc(src.r, bg.r),
        .g = calc(src.g, bg.g),
        .b = calc(src.b, bg.b),
    };
}

fn multiplySingle(src: F32x4, bg: F32x4) F32x4 {
    return src * bg;
}

fn screenSingle(src: F32x4, bg: F32x4) F32x4 {
    return bg + src - src * bg;
}

fn minSingle(src: F32x4, bg: F32x4) F32x4 {
    return @min(src, bg);
}

fn maxSingle(src: F32x4, bg: F32x4) F32x4 {
    return @max(src, bg);
}

fn differenceSingle(src: F32x4, bg: F32x4) F32x4 {
    const mask = src <= bg;
    return simd.select(F32x4, mask, bg - src, src - bg);
}

fn exclusionSingle(src: F32x4, bg: F32x4) F32x4 {
    return (src + bg) - splat4(2.0) * (src * bg);
}

fn hardLightSingle(src: F32x4, bg: F32x4) F32x4 {
    const two = splat4(2.0);

    const mask = src <= splat4(0.5);
    const opt1 = multiplySingle(bg, src * two);
    const opt2 = screenSingle(bg, two * src - splat4(1.0));

    return simd.select(F32x4, mask, opt1, opt2);
}

fn overlaySingle(src: F32x4, bg: F32x4) F32x4 {
    return hardLightSingle(bg, src);
}

fn softLightSingle(src: F32x4, bg: F32x4) F32x4 {
    const mask_1 = bg <= splat4(0.25);

    const d = simd.select(
        F32x4,
        mask_1,
        ((splat4(16.0) * bg - splat4(12.0)) * bg + splat4(4.0)) * bg,
        @sqrt(bg),
    );

    const mask_2 = src <= splat4(0.5);

    return simd.select(
        F32x4,
        mask_2,
        bg - (splat4(1.0) - splat4(2.0) * src) * bg * (splat4(1.0) - bg),
        bg + (splat4(2.0) * src - splat4(1.0)) * (d - bg),
    );
}

fn colorDodgeSingle(src: F32x4, bg: F32x4) F32x4 {
    const mask_1 = bg == splat4(0.0);
    const mask_2 = src == splat4(1.0);

    return simd.select(
        F32x4,
        // if bg == 0
        mask_1,
        splat4(0.0),
        // else if src == 1
        simd.select(
            F32x4,
            mask_2,
            splat4(1.0),
            // else
            @min(splat4(1.0), bg / (splat4(1.0) - src)),
        ),
    );
}

fn colorBurnSingle(src: F32x4, bg: F32x4) F32x4 {
    const mask_1 = bg == splat4(1.0);
    const mask_2 = src == splat4(0.0);

    return simd.select(
        F32x4,
        // if bg == 1
        mask_1,
        splat4(1.0),
        // else if src == 0
        simd.select(
            F32x4,
            mask_2,
            splat4(0.0),
            // else
            splat4(1.0) - @min(splat4(1.0), (splat4(1.0) - bg) / src),
        ),
    );
}

fn hueMix(src: Channels, bg: Channels) Channels {
    var result = src;
    const saturation = sat(bg.r, bg.g, bg.b);
    const luminosity = lum(bg.r, bg.g, bg.b);
    setSat(&result.r, &result.g, &result.b, saturation);
    setLum(&result.r, &result.g, &result.b, luminosity);
    return result;
}

fn saturationMix(src: Channels, bg: Channels) Channels {
    var result = bg;
    const luminosity = lum(bg.r, bg.g, bg.b);
    const saturation = sat(src.r, src.g, src.b);
    setSat(&result.r, &result.g, &result.b, saturation);
    setLum(&result.r, &result.g, &result.b, luminosity);
    return result;
}

fn colorMix(src: Channels, bg: Channels) Channels {
    var result = src;
    setLum(&result.r, &result.g, &result.b, lum(bg.r, bg.g, bg.b));
    return result;
}

fn luminosityMix(src: Channels, bg: Channels) Channels {
    var result = bg;
    setLum(&result.r, &result.g, &result.b, lum(src.r, src.g, src.b));
    return result;
}

fn lum(r: F32x4, g: F32x4, b: F32x4) F32x4 {
    return splat4(0.3) * r + splat4(0.59) * g + splat4(0.11) * b;
}

fn sat(r: F32x4, g: F32x4, b: F32x4) F32x4 {
    return @max(r, @max(g, b)) - @min(r, @min(g, b));
}

fn clipColor(r: *F32x4, g: *F32x4, b: *F32x4) void {
    const zero = splat4(0.0);
    const one = splat4(1.0);

    const l = lum(r.*, g.*, b.*);
    const n = @min(r.*, @min(g.*, b.*));
    const x = @max(r.*, @max(g.*, b.*));

    inline for ([3]*F32x4{ r, g, b }) |c| {
        c.* = simd.select(
            F32x4,
            n < zero,
            l + (((c.* - l) * l) / (l - n)),
            c.*,
        );

        c.* = simd.select(
            F32x4,
            x > one,
            l + (((c.* - l) * (one - l)) / (x - l)),
            c.*,
        );
    }
}

fn setLum(r: *F32x4, g: *F32x4, b: *F32x4, l: F32x4) void {
    const d = l - lum(r.*, g.*, b.*);
    r.* += d;
    g.* += d;
    b.* += d;

    clipColor(r, g, b);
}

// Adapted from tiny-skia.
fn setSat(r: *F32x4, g: *F32x4, b: *F32x4, s: F32x4) void {
    const mn = @min(r.*, @min(g.*, b.*));
    const mx = @max(r.*, @max(g.*, b.*));
    const saturation = mx - mn;

    // Map min channel to 0, max channel to s, and scale the middle
    // proportionally.
    r.* = scaleSatChannel(r.*, mn, saturation, s);
    g.* = scaleSatChannel(g.*, mn, saturation, s);
    b.* = scaleSatChannel(b.*, mn, saturation, s);
}

fn scaleSatChannel(c: F32x4, mn: F32x4, saturation: F32x4, s: F32x4) F32x4 {
    return simd.select(
        F32x4,
        saturation == splat4(0.0),
        splat4(0.0),
        (c - mn) * s / saturation,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pixelRgba(r: f32, g: f32, b: f32, a: f32) F32x16 {
    var out: F32x16 = undefined;
    inline for (0..4) |i| {
        out[4 * i + 0] = r;
        out[4 * i + 1] = g;
        out[4 * i + 2] = b;
        out[4 * i + 3] = a;
    }
    return out;
}

/// Compare all four pixels of an interleaved vector component-wise.
fn expectPixelApprox(expected: [4]f32, actual: F32x16, tolerance: f32) !void {
    inline for (0..4) |pixel| {
        inline for (0..4) |component| {
            try testing.expectApproxEqAbs(
                expected[component],
                actual[4 * pixel + component],
                tolerance,
            );
        }
    }
}

test "mix_normal_returns_source" {
    const src = pixelRgba(0.25, 0.5, 0.75, 0.5);
    const bg = pixelRgba(0.1, 0.2, 0.3, 1.0);
    try testing.expectEqual(src, mix(src, bg, peniko.BlendMode.default));
}

test "mix_separable_modes_match_formulas" {
    const src_c: F32x16 = pixelRgba(0.8, 0.25, 0.5, 1.0);
    const bg_c: F32x16 = pixelRgba(0.4, 0.75, 0.5, 1.0);

    const multiply = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.multiply));
    try expectPixelApprox(
        .{ 0.8 * 0.4, 0.25 * 0.75, 0.5 * 0.5, 1.0 },
        multiply,
        1e-6,
    );

    const screen = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.screen));
    try expectPixelApprox(
        .{ 0.4 + 0.8 - 0.8 * 0.4, 0.75 + 0.25 - 0.25 * 0.75, 0.5 + 0.5 - 0.25, 1.0 },
        screen,
        1e-6,
    );

    const darken = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.darken));
    try expectPixelApprox(.{ 0.4, 0.25, 0.5, 1.0 }, darken, 1e-6);

    const lighten = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.lighten));
    try expectPixelApprox(.{ 0.8, 0.75, 0.5, 1.0 }, lighten, 1e-6);

    const difference = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.difference));
    try expectPixelApprox(.{ 0.4, 0.5, 0.0, 1.0 }, difference, 1e-6);
}

test "mix_multiplies_out_alpha_for_translucent_source" {
    // Premultiplied translucent source and backdrop.
    const src_c: F32x16 = pixelRgba(0.2, 0.1, 0.05, 0.5);
    const bg_c: F32x16 = pixelRgba(0.3, 0.6, 0.9, 1.0);

    const result = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.multiply));

    // Unpremultiplied src = (0.4, 0.2, 0.1); bg = (0.3, 0.6, 0.9).
    // mix = src * bg = (0.12, 0.12, 0.09).
    // apply_alpha = ((1 - 1) * src + 1 * mix) * src_a = mix * 0.5.
    try expectPixelApprox(.{ 0.06, 0.06, 0.045, 0.5 }, result, 1e-6);
}

test "mix_non_separable_hue_keeps_backdrop_luminosity" {
    const src_c: F32x16 = pixelRgba(0.9, 0.1, 0.1, 1.0);
    const bg_c: F32x16 = pixelRgba(0.25, 0.5, 0.75, 1.0);

    const result = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.hue));

    // The result must carry the backdrop's luminosity in all channels.
    const expected_lum = 0.3 * 0.25 + 0.59 * 0.5 + 0.11 * 0.75;
    const actual_lum = 0.3 * result[0] + 0.59 * result[1] + 0.11 * result[2];
    try testing.expectApproxEqAbs(expected_lum, actual_lum, 1e-4);
    try testing.expectEqual(@as(f32, 1.0), result[3]);
}

test "mix_luminosity_keeps_backdrop_color" {
    const src_c: F32x16 = pixelRgba(0.9, 0.1, 0.1, 1.0);
    const bg_c: F32x16 = pixelRgba(0.25, 0.5, 0.75, 1.0);

    const result = mix(src_c, bg_c, peniko.BlendMode.from(peniko.Mix.luminosity));
    const expected_lum = 0.3 * 0.9 + 0.59 * 0.1 + 0.11 * 0.1;
    const actual_lum = 0.3 * result[0] + 0.59 * result[1] + 0.11 * result[2];
    try testing.expectApproxEqAbs(expected_lum, actual_lum, 1e-4);
}
