//! Port of vello_cpu src/fine/lowp/compose.rs (Apache-2.0 OR MIT).
//!
//! Porter-Duff composition for the low-precision (u8) pipeline. Each
//! composition mode is expressed by the pair of Fa/Fb coefficient functions
//! from the upstream `compose!` macro; the `Plus`/`PlusLighter` mode uses the
//! saturating variant.
//!
//! Divergences from upstream (behavior-preserving):
//! - Upstream attaches `compose` to `BlendMode` through the `ComposeExt` trait;
//!   Zig has no traits, so [`compose`] takes the blend mode as an argument and
//!   [`BLendMode`] stays the shared peniko type.
//! - Integer arithmetic uses wrapping operators to match `fearless_simd`'s
//!   wrapping integer semantics (and to keep debug builds panic-free for
//!   out-of-gamut premultiplied inputs, which upstream's release builds wrap).

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const peniko = @import("../../../peniko/root.zig");
const blend = @import("blend.zig");

const U8x32 = simd.U8x32;
const Compose = peniko.Compose;
const U16x32 = blend.U16x32;

/// Upstream `ComposeExt::compose` for `u8x32`.
///
/// `alpha_mask` modulates the composed result against the backdrop before it
/// is written back (used by the masked blend path).
pub fn compose(src_c: U8x32, bg_c: U8x32, blend_mode: peniko.BlendMode, alpha_mask: ?U8x32) U8x32 {
    var res = composeInner(blend_mode.compose, src_c, bg_c);

    if (alpha_mask) |mask| {
        const mask_inv = @as(U8x32, @splat(255)) -% mask;
        const p1 = blend.widen(mask) *% blend.widen(res);
        const p2 = blend.widen(mask_inv) *% blend.widen(bg_c);
        res = blend.narrow(blend.div255(p1 +% p2));
    }

    return res;
}

/// The coefficient selectors of the upstream `compose!` macro.
const Coefficient = enum {
    zero,
    one,
    one_minus_b,
    one_minus_s,
    b,
    s,
};

/// The Fa/Fb pair and saturation flag for a composition mode.
const Spec = struct {
    fa: Coefficient,
    fb: Coefficient,
    sat: bool,
};

fn specFor(mode: Compose) Spec {
    return switch (mode) {
        .clear => .{ .fa = .zero, .fb = .zero, .sat = false },
        .copy => .{ .fa = .one, .fb = .zero, .sat = false },
        .src_over => .{ .fa = .one, .fb = .one_minus_s, .sat = false },
        .dest_over => .{ .fa = .one_minus_b, .fb = .one, .sat = false },
        .dest => .{ .fa = .zero, .fb = .one, .sat = false },
        .xor => .{ .fa = .one_minus_b, .fb = .one_minus_s, .sat = false },
        .src_in => .{ .fa = .b, .fb = .zero, .sat = false },
        .dest_in => .{ .fa = .zero, .fb = .s, .sat = false },
        .src_out => .{ .fa = .one_minus_b, .fb = .zero, .sat = false },
        .dest_out => .{ .fa = .zero, .fb = .one_minus_s, .sat = false },
        .src_atop => .{ .fa = .b, .fb = .one_minus_s, .sat = false },
        .dest_atop => .{ .fa = .one_minus_b, .fb = .s, .sat = false },
        .plus => .{ .fa = .one, .fb = .one, .sat = true },
        // Have not been able to find a formula for this, so just fallback to Plus.
        .plus_lighter => .{ .fa = .one, .fb = .one, .sat = true },
    };
}

fn coefficient(kind: Coefficient, al_s: U8x32, al_b: U8x32) U8x32 {
    return switch (kind) {
        .zero => @splat(0),
        .one => @splat(255),
        .one_minus_b => @as(U8x32, @splat(255)) -% al_b,
        .one_minus_s => @as(U8x32, @splat(255)) -% al_s,
        .b => al_b,
        .s => al_s,
    };
}

fn composeInner(mode: Compose, src_c: U8x32, bg_c: U8x32) U8x32 {
    const spec = specFor(mode);
    const al_b = simd.splat4th(bg_c);
    const al_s = simd.splat4th(src_c);

    const fa = coefficient(spec.fa, al_s, al_b);
    const fb = coefficient(spec.fb, al_s, al_b);

    if (spec.sat) {
        const sum = blend.widen(blend.normalizedMul(src_c, fa)) +%
            blend.widen(blend.normalizedMul(fb, bg_c));
        return blend.narrow(@min(@max(sum, @as(U16x32, @splat(0))), @as(U16x32, @splat(255))));
    }

    return blend.normalizedMul(src_c, fa) +% blend.normalizedMul(fb, bg_c);
}

// ---------------------------------------------------------------------------
// Tests (upstream `compose.rs` has no `#[cfg(test)]` module; these pin the
// coefficient table semantics against the Porter-Duff definitions)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pixel(r: u8, g: u8, b: u8, a: u8) U8x32 {
    return blend.colorVector32(.{ r, g, b, a });
}

/// Assert that every RGBA block of `actual` equals `expected`.
fn expectPixel(expected: [4]u8, actual: U8x32) !void {
    inline for (0..8) |i| {
        try testing.expectEqual(expected[0], actual[4 * i + 0]);
        try testing.expectEqual(expected[1], actual[4 * i + 1]);
        try testing.expectEqual(expected[2], actual[4 * i + 2]);
        try testing.expectEqual(expected[3], actual[4 * i + 3]);
    }
}

test "src_over composites source over backdrop" {
    const src = pixel(128, 0, 0, 128);
    const bg = pixel(0, 0, 255, 255);
    const result = compose(src, bg, .{ .compose = .src_over }, null);

    // result = src + bg * (1 - src_a): red 128, blue/alpha 255 * 127 / 255
    // via `div_255(127 * 255) = 127`, i.e. (128, 0, 127, 255).
    try expectPixel(.{ 128, 0, 127, 255 }, result);
}

test "dest and clear ignore the source" {
    const src = pixel(10, 20, 30, 40);
    const bg = pixel(50, 60, 70, 80);

    try expectPixel(.{ 0, 0, 0, 0 }, compose(src, bg, .{ .compose = .clear }, null));
    try expectPixel(.{ 50, 60, 70, 80 }, compose(src, bg, .{ .compose = .dest }, null));
    try expectPixel(.{ 10, 20, 30, 40 }, compose(src, bg, .{ .compose = .copy }, null));
}

test "plus saturates instead of wrapping" {
    const src = pixel(200, 200, 200, 200);
    const bg = pixel(200, 200, 200, 200);
    const result = compose(src, bg, .{ .compose = .plus }, null);

    try expectPixel(.{ 255, 255, 255, 255 }, result);
}

test "alpha mask blends result against backdrop" {
    const src = pixel(255, 0, 0, 255);
    const bg = pixel(0, 0, 255, 255);
    const mask = blend.colorVector32(.{ 128, 128, 128, 128 });
    const result = compose(src, bg, .{ .compose = .src_over }, mask);

    // p1 = widened(128) * widened(res), p2 = widened(127) * widened(bg);
    // red: div255(128 * 255) = 128; blue: div255(127 * 255) = 127;
    // alpha: div255(128 * 255 + 127 * 255) = 255.
    try expectPixel(.{ 128, 0, 127, 255 }, result);
}
