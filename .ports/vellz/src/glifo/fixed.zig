//! `font-types` 0.12 fixed-point primitives used by the CFF/CFF2 pipeline.
//!
//! `glyf.zig` has its own copies of the `glyf`-specific helpers (F26Dot6
//! rounding and the `Scale26Dot6` scaler); this module carries the general
//! 16.16 `Fixed` / 2.14 `F2Dot14` operations the CFF charstring evaluator and
//! the item variation store need. Every operation mirrors the exact Rust
//! implementation (`font-types/src/fixed.rs`) including wrapping behavior, so
//! the f32 values emitted at the pen boundary are bit-identical.

const std = @import("std");

/// 16.16 fixed point, `Fixed` in `font-types`.
pub const Fixed = struct {
    bits: i32,

    pub const zero: Fixed = .{ .bits = 0 };
    pub const one: Fixed = .{ .bits = 1 << 16 };
    pub const neg_one: Fixed = .{ .bits = @bitCast(@as(u32, 0xFFFF0000)) };
    pub const min: Fixed = .{ .bits = std.math.minInt(i32) };
    pub const max: Fixed = .{ .bits = std.math.maxInt(i32) };

    pub fn fromBits(bits: i32) Fixed {
        return .{ .bits = bits };
    }

    /// `Fixed::from_i32`: `value << 16` with Rust's truncating shift.
    pub fn fromI32(value: i32) Fixed {
        return .{ .bits = @bitCast(@as(u32, @bitCast(value)) << 16) };
    }

    /// `Fixed::to_i32`: `(bits + 0x8000) >> 16` with wrapping add.
    pub fn toI32(self: Fixed) i32 {
        return (@as(i32, @bitCast(@as(u32, @bitCast(self.bits)) +% 0x8000))) >> 16;
    }

    /// `Fixed::to_f32`: `bits as f32 * (1/65536)`, the lossy float boundary.
    pub fn toF32(self: Fixed) f32 {
        return @as(f32, @floatFromInt(self.bits)) * (1.0 / 65536.0);
    }

    /// `Fixed::round`: `(bits + 0x8000) & !0xFFFF`, wrapping add.
    pub fn round(self: Fixed) Fixed {
        const wrapped: i32 = @bitCast(@as(u32, @bitCast(self.bits)) +% 0x8000);
        return .{ .bits = wrapped & ~@as(i32, 0xFFFF) };
    }

    /// `Fixed::floor`: `bits & !0xFFFF`.
    pub fn floor(self: Fixed) Fixed {
        return .{ .bits = self.bits & ~@as(i32, 0xFFFF) };
    }

    /// `Fixed::abs`.
    pub fn abs(self: Fixed) Fixed {
        return .{ .bits = if (self.bits < 0) -%self.bits else self.bits };
    }

    pub fn add(a: Fixed, b: Fixed) Fixed {
        return .{ .bits = a.bits +% b.bits };
    }

    pub fn sub(a: Fixed, b: Fixed) Fixed {
        return .{ .bits = a.bits -% b.bits };
    }

    /// `Fixed::Mul`: `(ab + 0x8000 - (ab < 0)) >> 16`, truncating to i32.
    pub fn mul(a: Fixed, b: Fixed) Fixed {
        const ab: i64 = @as(i64, a.bits) * @as(i64, b.bits);
        const adjust: i64 = 0x8000 - @as(i64, @intFromBool(ab < 0));
        return .{ .bits = @truncate((ab + adjust) >> 16) };
    }

    /// `Fixed::Div`: `((au << 16) + (bu >> 1)) / bu`, sign applied after;
    /// `0x7fffffff` when the divisor is zero.
    pub fn div(a: Fixed, b: Fixed) Fixed {
        const negative = (a.bits < 0) != (b.bits < 0);
        const au: u64 = @abs(@as(i64, a.bits));
        const bu: u64 = @abs(@as(i64, b.bits));
        const q: u32 = if (bu == 0)
            0x7FFFFFFF
        else
            @truncate(((au << 16) + (bu >> 1)) / bu);
        const bits: i32 = @bitCast(q);
        return .{ .bits = if (negative) -%bits else bits };
    }

    /// `Fixed::mul_div`: `(self * a + b/2) / b` on absolute values, sign
    /// applied afterwards, `0x7fffffff` when `b` is zero.
    pub fn mulDiv(self: Fixed, a: Fixed, b: Fixed) Fixed {
        var sign: i32 = 1;
        var su: u64 = @bitCast(@as(i64, self.bits));
        var au: u64 = @bitCast(@as(i64, a.bits));
        var bu: u64 = @bitCast(@as(i64, b.bits));
        if (self.bits < 0) {
            su = 0 -% su;
            sign = -1;
        }
        if (a.bits < 0) {
            au = 0 -% au;
            sign = -sign;
        }
        if (b.bits < 0) {
            bu = 0 -% bu;
            sign = -sign;
        }
        const result: u64 = if (bu > 0)
            (su *% au +% (bu >> 1)) / bu
        else
            0x7FFFFFFF;
        const bits: i32 = @bitCast(@as(u32, @truncate(result)));
        return .{ .bits = if (sign < 0) -%bits else bits };
    }
};

/// 2.14 fixed point, `F2Dot14` in `font-types`; the bit pattern of
/// `glifo`/`skrifa`'s `NormalizedCoord`.
pub const F2Dot14 = struct {
    bits: i16,

    pub fn fromBits(bits: i16) F2Dot14 {
        return .{ .bits = bits };
    }

    /// `F2Dot14::to_fixed`: `bits as i32 * 4`.
    pub fn toFixed(self: F2Dot14) Fixed {
        return .{ .bits = @as(i32, self.bits) * 4 };
    }

    /// `F2Dot14::to_f32`: `bits as f32 / 16384.0`.
    pub fn toF32(self: F2Dot14) f32 {
        return @as(f32, @floatFromInt(self.bits)) * (1.0 / 16384.0);
    }
};

/// `f32 as i32` (Rust): saturating, NaN maps to 0, truncation toward zero.
pub fn saturatingF32ToI32(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= 2147483648.0) return std.math.maxInt(i32);
    if (value < -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(value);
}

// --------------------------------------------------------------------- tests

const expectEqual = std.testing.expectEqual;

test "Fixed arithmetic matches font-types wrapping semantics" {
    try expectEqual(@as(i32, 1 << 16), Fixed.mul(Fixed.one, Fixed.one).bits);
    try expectEqual(@as(i32, 0x8000), Fixed.mul(Fixed.fromBits(0x8000), Fixed.one).bits);
    try expectEqual(@as(i32, 3 << 16), Fixed.div(Fixed.fromI32(3), Fixed.one).bits);
    try expectEqual(@as(i32, 0x18000), Fixed.div(Fixed.fromI32(3), Fixed.fromI32(2)).bits);
    try expectEqual(@as(i32, 0x7FFFFFFF), Fixed.div(Fixed.fromI32(1), Fixed.zero).bits);
    try expectEqual(@as(i32, 1), Fixed.fromBits(0x8000).toI32());
    try expectEqual(@as(i32, 0), Fixed.fromBits(0x7FFF).toI32());
    try expectEqual(@as(i32, -2 << 16), Fixed.fromI32(-2).bits);
}

test "mul_div sign and zero divisor" {
    // 0.5 * 1 / 1 = 0.5
    try expectEqual(@as(i32, 0x8000), Fixed.fromBits(0x8000).mulDiv(Fixed.one, Fixed.one).bits);
    // -1 * 1 / 2 = -0.5
    try expectEqual(
        @as(i32, -0x8000),
        Fixed.neg_one.mulDiv(Fixed.one, Fixed.fromI32(2)).bits,
    );
    try expectEqual(
        @as(i32, 0x7FFFFFFF),
        Fixed.one.mulDiv(Fixed.one, Fixed.zero).bits,
    );
}

test "F2Dot14 to fixed" {
    try expectEqual(@as(i32, 4), F2Dot14.fromBits(1).toFixed().bits);
    try expectEqual(@as(i32, -4), F2Dot14.fromBits(-1).toFixed().bits);
    try expectEqual(@as(i32, 65536), F2Dot14.fromBits(16384).toFixed().bits);
}
