//! Port of vello_common math.rs (Apache-2.0 OR MIT).
//!
//! `FloatExt` becomes a pair of free functions (`isNearlyZero`,
//! `isNearlyZeroWithinTolerance`) because Zig has no traits; call sites pass
//! either `f32` or `f64` and the tolerance is always `f32`, matching upstream.
//!
//! Ownership/allocator note: pure numeric helpers, no allocation.

const std = @import("std");

/// `NEARLY_ZERO`, kept identical to upstream and to the shader constant in
/// `render.wgsl` (`1/4096`).
pub const SCALAR_NEARLY_ZERO: f32 = 1.0 / 4096.0;

/// Round `value` up to the next multiple of `step`.
pub fn snapUp(value: f64, step: u16) f64 {
    const step_f = @as(f64, @floatFromInt(step));
    return @ceil(value / step_f) * step_f;
}

/// Whether the number is approximately 0.
pub fn isNearlyZero(x: anytype) bool {
    return isNearlyZeroWithinTolerance(x, SCALAR_NEARLY_ZERO);
}

/// Whether the number is approximately 0, with a given tolerance.
pub fn isNearlyZeroWithinTolerance(x: anytype, tolerance: f32) bool {
    std.debug.assert(tolerance >= 0.0);
    return switch (@typeInfo(@TypeOf(x))) {
        .float => |info| switch (info.bits) {
            32 => @abs(x) <= tolerance,
            64 => @abs(x) <= @as(f64, tolerance),
            else => @compileError("FloatExt supports only f32 and f64"),
        },
        else => @compileError("FloatExt supports only f32 and f64"),
    };
}

/// `core::f32::consts::FRAC_2_SQRT_PI` = `2 / sqrt(pi)`, exact f32 bits.
const FRAC_2_SQRT_PI: f32 = @bitCast(@as(u32, 0x3f906ebb));

/// Approximate the erf function.
///
/// See <https://raphlinus.github.io/audio/2018/09/05/sigmoid.html>. Ported
/// term-for-term; the clamp prevents the polynomial from producing `inf`/`NaN`
/// for large inputs (`erf(±10) ≈ 1` well within `f32` precision).
pub fn computeErf7(x: f32) f32 {
    // Upstream uses Rust's `f32::clamp`, which propagates NaN; `@min`/`@max`
    // would instead replace a NaN with a bound, so spell out the comparisons.
    const clamped = if (x < -10.0) -10.0 else if (x > 10.0) 10.0 else x;
    const scaled = clamped * FRAC_2_SQRT_PI;
    const scaled_sq = scaled * scaled;
    const adjusted = scaled +
        (0.24295 + (0.03395 + 0.0104 * scaled_sq) * scaled_sq) * (scaled * scaled_sq);
    return adjusted / @sqrt(1.0 + adjusted * adjusted);
}

test "snap_up" {
    try std.testing.expectEqual(@as(f64, 8.0), snapUp(5.0, 4));
    try std.testing.expectEqual(@as(f64, -4.0), snapUp(-4.1, 4));
    try std.testing.expectEqual(@as(f64, 0.0), snapUp(0.0, 4));
    try std.testing.expectEqual(@as(f64, 8.0), snapUp(4.0000001, 4));
}

test "compute_erf7 matches upstream bit patterns" {
    // Oracle values captured from the pinned upstream implementation
    // (rustc -O, `f32` arithmetic) and compared bit-for-bit.
    const cases = [_]struct { x: f32, bits: u32 }{
        .{ .x = -12.0, .bits = 0xbf800000 },
        .{ .x = -10.0, .bits = 0xbf800000 },
        .{ .x = -3.0, .bits = 0xbf7ffafe },
        .{ .x = -1.0, .bits = 0xbf57abed },
        .{ .x = -0.5, .bits = 0xbf054e73 },
        .{ .x = 0.0, .bits = 0x00000000 },
        .{ .x = 0.25, .bits = 0x3e8d850e },
        .{ .x = 0.5, .bits = 0x3f054e73 },
        .{ .x = 0.75, .bits = 0x3f360d53 },
        .{ .x = 1.0, .bits = 0x3f57abed },
        .{ .x = 2.0, .bits = 0x3f7ec36c },
        .{ .x = 3.0, .bits = 0x3f7ffafe },
        .{ .x = 10.0, .bits = 0x3f800000 },
        .{ .x = 12.0, .bits = 0x3f800000 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.bits, @as(u32, @bitCast(computeErf7(case.x))));
    }
    try std.testing.expect(std.math.isNan(computeErf7(std.math.nan(f32))));
}

test "is_nearly_zero" {
    try std.testing.expect(isNearlyZero(@as(f32, 0.0)));
    try std.testing.expect(isNearlyZero(@as(f64, 0.0)));
    try std.testing.expect(isNearlyZero(@as(f32, 1.0 / 8192.0)));
    try std.testing.expect(!isNearlyZero(@as(f32, 0.001)));
    try std.testing.expect(!isNearlyZero(@as(f64, -0.001)));
    try std.testing.expect(isNearlyZeroWithinTolerance(@as(f64, 0.5), 1.0));
}
