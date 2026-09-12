//! Fixed-point helpers shared by the autohinter.
//!
//! Port of the `fixed_mul`/`fixed_div`/`fixed_mul_div`/`pix_round`/
//! `pix_floor` helpers in `skrifa 0.44.0`'s
//! `outline/autohint/metrics/mod.rs`, which wrap `font-types` `Fixed` (16.16)
//! arithmetic. Rust release builds wrap on overflow; these helpers do too.

const std = @import("std");

/// `Fixed` multiplication: round half away from zero.
pub fn mul(a: i32, b: i32) i32 {
    const ab: i64 = @as(i64, a) * @as(i64, b);
    const adjust: i64 = 0x8000 - @as(i64, @intFromBool(ab < 0));
    return @truncate((ab + adjust) >> 16);
}

/// `Fixed` division: `(au << 16 + bu >> 1) / bu`, sign applied afterwards,
/// `0x7fffffff` when the divisor is zero.
pub fn div(a: i32, b: i32) i32 {
    const negative = (a < 0) != (b < 0);
    const au: u64 = @abs(@as(i64, a));
    const bu: u64 = @abs(@as(i64, b));
    const q: u32 = if (bu == 0)
        0x7FFFFFFF
    else
        @truncate(((au << 16) + (bu >> 1)) / bu);
    const bits: i32 = @bitCast(q);
    return if (negative) -%bits else bits;
}

/// `Fixed::mul_div`: `(self * a) / b` with full 64-bit intermediates and
/// `0x7fffffff` when `b` is zero.
pub fn mulDiv(a: i32, b: i32, c: i32) i32 {
    var sign: i32 = 1;
    var su: u64 = @bitCast(@as(i64, a));
    var bu_raw: u64 = @bitCast(@as(i64, b));
    var cu: u64 = @bitCast(@as(i64, c));
    if (a < 0) {
        su = 0 -% su;
        sign = -1;
    }
    if (b < 0) {
        bu_raw = 0 -% bu_raw;
        sign = -sign;
    }
    if (c < 0) {
        cu = 0 -% cu;
        sign = -sign;
    }
    const result: u32 = if (cu > 0)
        @truncate((su *% bu_raw +% (cu >> 1)) / cu)
    else
        0x7FFFFFFF;
    const bits: i32 = @bitCast(result);
    return if (sign < 0) -%bits else bits;
}

/// `pix_round`: round to the nearest 1/64 pixel (away from zero on ties is
/// not used; upstream adds 32 then floors).
pub fn pixRound(a: i32) i32 {
    return (a +% 32) & ~@as(i32, 63);
}

/// `pix_floor`: floor to a 1/64 pixel boundary.
pub fn pixFloor(a: i32) i32 {
    return a & ~@as(i32, 63);
}

/// `derived_constant`: constants are defined for a UPEM of 2048.
pub fn derivedConstant(units_per_em: i32, value: i32) i32 {
    return @divTrunc(value * units_per_em, 2048);
}

/// Rust `f32 as i32`: saturating, NaN maps to 0, truncation toward zero.
pub fn saturatingF32ToI32(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= 2147483648.0) return std.math.maxInt(i32);
    if (value < -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(value);
}

test "fixed mul and div match font-types" {
    // Fixed::from_bits(0x10000) is 1.0.
    try std.testing.expectEqual(@as(i32, 0x10000), mul(0x10000, 0x10000));
    try std.testing.expectEqual(@as(i32, 0x8000), mul(0x8000, 0x10000));
    try std.testing.expectEqual(@as(i32, 0x10000), div(0x10000, 0x10000));
    // Round half away from zero on the product.
    try std.testing.expectEqual(@as(i32, 0x18000), mul(0x18000, 0x10000));
    try std.testing.expectEqual(@as(i32, 0x10000), mul(0x20000, 0x8000));
    // Sign handling on the division argument.
    try std.testing.expectEqual(@as(i32, -2), mulDiv(-2, 1, 1));
    _ = &div;
}

test "mul_div matches fixed mul_div" {
    try std.testing.expectEqual(@as(i32, 0x10000), mulDiv(0x10000, 0x10000, 0x10000));
    try std.testing.expectEqual(@as(i32, 0x8000), mulDiv(0x10000, 0x8000, 0x10000));
    try std.testing.expectEqual(@as(i32, 0x7FFFFFFF), mulDiv(1, 1, 0));
}

test "derived constant and pixel rounding" {
    try std.testing.expectEqual(@as(i32, 50), derivedConstant(2048, 50));
    try std.testing.expectEqual(@as(i32, 25), derivedConstant(1024, 50));
    try std.testing.expectEqual(@as(i32, 64), pixRound(33));
    try std.testing.expectEqual(@as(i32, 64), pixRound(32));
    try std.testing.expectEqual(@as(i32, 0), pixRound(-32));
    try std.testing.expectEqual(@as(i32, -64), pixRound(-33));
    try std.testing.expectEqual(@as(i32, -64), pixFloor(-1));
}
