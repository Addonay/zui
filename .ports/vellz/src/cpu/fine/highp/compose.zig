//! Port of vello_cpu src/fine/highp/compose.rs (Apache-2.0 OR MIT).
//!
//! Porter-Duff compositing for the f32 kernel, with optional non-isolated
//! alpha masking.
//!
//! Note on the two kinds of blending (as upstream):
//! - *Isolated* blending composites whole layers; `alpha_mask` is `None`.
//! - *Non-isolated* blending composites a single path with the backdrop; when
//!   present, `alpha_mask` holds the strip coverage and the composited result
//!   is lerped with the backdrop: `res = mask * res + (1 - mask) * bg`.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const peniko = @import("../../../peniko/root.zig");

const F32x16 = simd.F32x16;

fn one() F32x16 {
    return @splat(1.0);
}

fn zero() F32x16 {
    return @splat(0.0);
}

/// Composite a mixed source color `src_c` over `bg_c` with the mode's
/// composition operator, optionally masked by `alpha_mask`.
pub fn compose(
    blend_mode: peniko.BlendMode,
    src_c: F32x16,
    bg_c: F32x16,
    alpha_mask: ?F32x16,
) F32x16 {
    var res = switch (blend_mode.compose) {
        .src_over => composeWith(faOne, fbOneMinusSrcAlpha, false, src_c, bg_c),
        .clear => composeWith(faZero, fbZero, false, src_c, bg_c),
        .copy => composeWith(faOne, fbZero, false, src_c, bg_c),
        .dest_over => composeWith(faOneMinusBgAlpha, fbOne, false, src_c, bg_c),
        .dest => composeWith(faZero, fbOne, false, src_c, bg_c),
        .src_in => composeWith(faBgAlpha, fbZero, false, src_c, bg_c),
        .dest_in => composeWith(faZero, fbSrcAlpha, false, src_c, bg_c),
        .src_out => composeWith(faOneMinusBgAlpha, fbZero, false, src_c, bg_c),
        .dest_out => composeWith(faZero, fbOneMinusSrcAlpha, false, src_c, bg_c),
        .src_atop => composeWith(faBgAlpha, fbOneMinusSrcAlpha, false, src_c, bg_c),
        .dest_atop => composeWith(faOneMinusBgAlpha, fbSrcAlpha, false, src_c, bg_c),
        .xor => composeWith(faOneMinusBgAlpha, fbOneMinusSrcAlpha, false, src_c, bg_c),
        .plus => composeWith(faOne, fbOne, true, src_c, bg_c),
        // Upstream has not been able to find a formula for this, so it falls
        // back to Plus; preserved here.
        .plus_lighter => composeWith(faOne, fbOne, true, src_c, bg_c),
    };

    if (alpha_mask) |alpha| {
        const alpha_inv = one() - alpha;
        res = alpha * res + alpha_inv * bg_c;
    }

    return res;
}

fn composeWith(
    comptime fa: fn (F32x16, F32x16) F32x16,
    comptime fb: fn (F32x16, F32x16) F32x16,
    comptime saturate: bool,
    src_c: F32x16,
    bg_c: F32x16,
) F32x16 {
    const al_b = simd.splat4th(bg_c);
    const al_s = simd.splat4th(src_c);

    const fa_v = fa(al_s, al_b);
    const fb_v = fb(al_s, al_b);

    const res = src_c * fa_v + fb_v * bg_c;
    if (saturate) {
        return @max(@min(res, one()), zero());
    }
    return res;
}

fn faZero(_: F32x16, _: F32x16) F32x16 {
    return zero();
}

fn faOne(_: F32x16, _: F32x16) F32x16 {
    return one();
}

fn faSrcAlpha(al_s: F32x16, _: F32x16) F32x16 {
    return al_s;
}

fn faBgAlpha(_: F32x16, al_b: F32x16) F32x16 {
    return al_b;
}

fn faOneMinusBgAlpha(_: F32x16, al_b: F32x16) F32x16 {
    return one() - al_b;
}

fn fbZero(_: F32x16, _: F32x16) F32x16 {
    return zero();
}

fn fbOne(_: F32x16, _: F32x16) F32x16 {
    return one();
}

fn fbSrcAlpha(al_s: F32x16, _: F32x16) F32x16 {
    return al_s;
}

fn fbOneMinusSrcAlpha(al_s: F32x16, _: F32x16) F32x16 {
    return one() - al_s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build an interleaved RGBA vector filled with one pixel value.
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

test "compose_src_over_is_porter_duff_over" {
    const src = pixelRgba(0.4, 0.2, 0.1, 0.5);
    const bg = pixelRgba(0.2, 0.6, 0.8, 1.0);

    const res = compose(peniko.BlendMode.default, src, bg, null);

    // result = src + bg * (1 - src_a)
    try expectPixelApprox(
        .{ 0.4 + 0.2 * 0.5, 0.2 + 0.6 * 0.5, 0.1 + 0.8 * 0.5, 0.5 + 1.0 * 0.5 },
        res,
        1e-6,
    );
}

test "compose_clear_copy_dest" {
    const src = pixelRgba(0.4, 0.2, 0.1, 0.5);
    const bg = pixelRgba(0.2, 0.6, 0.8, 1.0);

    try testing.expectEqual(pixelRgba(0.0, 0.0, 0.0, 0.0), compose(
        peniko.BlendMode.from(peniko.Compose.clear),
        src,
        bg,
        null,
    ));
    try testing.expectEqual(src, compose(
        peniko.BlendMode.from(peniko.Compose.copy),
        src,
        bg,
        null,
    ));
    try testing.expectEqual(bg, compose(
        peniko.BlendMode.from(peniko.Compose.dest),
        src,
        bg,
        null,
    ));
}

test "compose_dest_over_swaps_roles" {
    const src = pixelRgba(0.4, 0.2, 0.1, 0.5);
    const bg = pixelRgba(0.2, 0.6, 0.8, 0.4);

    const res = compose(peniko.BlendMode.from(peniko.Compose.dest_over), src, bg, null);

    // result = bg + src * (1 - bg_a)
    try expectPixelApprox(
        .{ 0.2 + 0.4 * 0.6, 0.6 + 0.2 * 0.6, 0.8 + 0.1 * 0.6, 0.4 + 0.5 * 0.6 },
        res,
        1e-6,
    );
}

test "compose_plus_saturates" {
    const src = pixelRgba(0.8, 0.2, 0.1, 0.9);
    const bg = pixelRgba(0.9, 0.6, 0.0, 0.5);

    const res = compose(peniko.BlendMode.from(peniko.Compose.plus), src, bg, null);

    try expectPixelApprox(.{ 1.0, 0.8, 0.1, 1.0 }, res, 1e-6);
    try testing.expectEqual(res, compose(
        peniko.BlendMode.from(peniko.Compose.plus_lighter),
        src,
        bg,
        null,
    ));
}

test "compose_applies_alpha_mask_lerp" {
    const src = pixelRgba(0.4, 0.2, 0.1, 0.5);
    const bg = pixelRgba(0.2, 0.6, 0.8, 1.0);
    const mask: F32x16 = @splat(0.25);

    const unmasked = compose(peniko.BlendMode.default, src, bg, null);
    const masked = compose(peniko.BlendMode.default, src, bg, mask);

    // masked = mask * unmasked + (1 - mask) * bg
    inline for (0..16) |lane| {
        const expected = 0.25 * unmasked[lane] + 0.75 * bg[lane];
        try testing.expectApproxEqAbs(expected, masked[lane], 1e-6);
    }
}

test "compose_xor_and_src_in" {
    const src = pixelRgba(0.4, 0.2, 0.1, 0.5);
    const bg = pixelRgba(0.2, 0.6, 0.8, 0.25);

    const xor = compose(peniko.BlendMode.from(peniko.Compose.xor), src, bg, null);
    try expectPixelApprox(
        .{
            0.4 * 0.75 + 0.2 * 0.5,
            0.2 * 0.75 + 0.6 * 0.5,
            0.1 * 0.75 + 0.8 * 0.5,
            0.5 * 0.75 + 0.25 * 0.5,
        },
        xor,
        1e-6,
    );

    const src_in = compose(peniko.BlendMode.from(peniko.Compose.src_in), src, bg, null);
    try expectPixelApprox(.{ 0.4 * 0.25, 0.2 * 0.25, 0.1 * 0.25, 0.5 * 0.25 }, src_in, 1e-6);
}
