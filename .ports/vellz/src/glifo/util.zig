//! Utility helpers ported from `glifo/src/util.rs`.
//!
//! `FloatExt` becomes free functions (Zig has no extension methods) and
//! `AffineExt` becomes a small predicate namespace over `kurbo.Affine`.
//! Thresholds and branch conditions are transcribed verbatim; T3's
//! `GlyphScaleProperties`/transform code depends on them.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");

// From tiny-skia, as upstream: `1 / (1 << 12)`.
pub const scalar_nearly_zero_f32: f32 = 1.0 / 4096.0;
pub const scalar_nearly_zero_f64: f64 = 1.0 / 4096.0;

/// Whether the number is approximately 0.
pub fn isNearlyZero(x: f32) bool {
    return isNearlyZeroWithinTolerance(x, scalar_nearly_zero_f32);
}

/// Whether the number is approximately 0 within `tolerance`.
pub fn isNearlyZeroWithinTolerance(x: f32, tolerance: f32) bool {
    return @abs(x) <= tolerance;
}

/// Whether the transform has any skewing coefficient.
pub fn hasSkew(affine: kurbo.Affine) bool {
    const c = affine.asCoeffs();
    return @abs(c[1]) > scalar_nearly_zero_f64 or @abs(c[2]) > scalar_nearly_zero_f64;
}

/// Whether the transform has a vertical skew.
pub fn hasVerticalSkew(affine: kurbo.Affine) bool {
    const c = affine.asCoeffs();
    return @abs(c[1]) > scalar_nearly_zero_f64;
}

/// Whether the transform has positive, uniform scaling factors and no skew.
pub fn isPositiveUniformScaleWithoutSkew(affine: kurbo.Affine) bool {
    const c = affine.asCoeffs();
    return @abs(c[0] - c[3]) <= scalar_nearly_zero_f64 and
        c[0] > 0.0 and
        c[3] > 0.0 and
        !hasSkew(affine);
}

/// Whether the transform has positive, uniform scaling factors and no
/// vertical skew.
pub fn isPositiveUniformScaleWithoutVerticalSkew(affine: kurbo.Affine) bool {
    const c = affine.asCoeffs();
    return @abs(c[0] - c[3]) <= scalar_nearly_zero_f64 and
        c[0] > 0.0 and
        c[3] > 0.0 and
        !hasVerticalSkew(affine);
}

/// Whether the transform has non-unit scale or skew.
///
/// Negative scales (i.e. -1.0) are explicitly allowed.
pub fn hasNonUnitSkewOrScale(affine: kurbo.Affine) bool {
    const c = affine.asCoeffs();
    return hasSkew(affine) or
        @abs(1.0 - @abs(c[0])) > scalar_nearly_zero_f64 or
        @abs(1.0 - @abs(c[3])) > scalar_nearly_zero_f64;
}

test "detects positive uniform scale without skew" {
    const transform = kurbo.Affine.scale(2.0);
    try std.testing.expect(!hasSkew(transform));
    try std.testing.expect(!hasVerticalSkew(transform));
    try std.testing.expect(isPositiveUniformScaleWithoutSkew(transform));
    try std.testing.expect(isPositiveUniformScaleWithoutVerticalSkew(transform));
}

test "rejects skewed scales" {
    const horiz = kurbo.Affine.new(.{ 2.0, 0.0, 0.25, 2.0, 0.0, 0.0 });
    try std.testing.expect(hasSkew(horiz));
    try std.testing.expect(!hasVerticalSkew(horiz));
    try std.testing.expect(!isPositiveUniformScaleWithoutSkew(horiz));
    try std.testing.expect(isPositiveUniformScaleWithoutVerticalSkew(horiz));

    const vert = kurbo.Affine.new(.{ 2.0, 0.25, 0.0, 2.0, 0.0, 0.0 });
    try std.testing.expect(hasSkew(vert));
    try std.testing.expect(hasVerticalSkew(vert));
    try std.testing.expect(!isPositiveUniformScaleWithoutSkew(vert));
    try std.testing.expect(!isPositiveUniformScaleWithoutVerticalSkew(vert));
}

test "rejects non-uniform or non-positive scale and allows axis flips" {
    const non_uniform = kurbo.Affine.new(.{ 2.0, 0.0, 0.0, 3.0, 0.0, 0.0 });
    const flipped = kurbo.Affine.new(.{ -2.0, 0.0, 0.0, -2.0, 0.0, 0.0 });
    try std.testing.expect(hasNonUnitSkewOrScale(non_uniform));
    try std.testing.expect(!isPositiveUniformScaleWithoutSkew(non_uniform));
    try std.testing.expect(!isPositiveUniformScaleWithoutVerticalSkew(non_uniform));
    try std.testing.expect(hasNonUnitSkewOrScale(flipped));
    try std.testing.expect(!isPositiveUniformScaleWithoutSkew(flipped));
    try std.testing.expect(!isPositiveUniformScaleWithoutVerticalSkew(flipped));

    const flip_x = kurbo.Affine.new(.{ -1.0, 0.0, 0.0, 1.0, 0.0, 0.0 });
    const flip_y = kurbo.Affine.new(.{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0 });
    const flip_xy = kurbo.Affine.new(.{ -1.0, 0.0, 0.0, -1.0, 0.0, 0.0 });
    try std.testing.expect(!hasNonUnitSkewOrScale(flip_x));
    try std.testing.expect(!hasNonUnitSkewOrScale(flip_y));
    try std.testing.expect(!hasNonUnitSkewOrScale(flip_xy));
}

test "nearly zero thresholds" {
    try std.testing.expect(isNearlyZero(0.0));
    try std.testing.expect(isNearlyZero(1.0 / 8192.0));
    try std.testing.expect(!isNearlyZero(1.0 / 2048.0));
    try std.testing.expect(isNearlyZeroWithinTolerance(-0.5, 0.5));
}
