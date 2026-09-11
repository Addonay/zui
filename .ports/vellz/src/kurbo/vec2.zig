//! Port of kurbo 0.13.1 `vec2.rs` (Apache-2.0 OR MIT).
//!
//! Zig has no operator overloading, so the upstream operators are methods:
//! `add` (`+`), `sub` (`-`), `mulScalar` (`* f64`), `div` (`/ f64`, which
//! upstream implements as multiplication by the reciprocal), `divExact`
//! (per-component division) and `neg` (unary `-`).
//!
//! Omissions: the `mint` conversions (feature-gated upstream) and the
//! `Axis`-indexed accessors (`Axis` is not part of this port's surface).

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Size = @import("size.zig").Size;

/// A 2D vector.
///
/// This is intended primarily for a vector in the mathematical sense,
/// but it can be interpreted as a translation, and converted to and
/// from a [`Point`] (vector relative to the origin) and [`Size`].
pub const Vec2 = struct {
    /// The x-coordinate.
    x: f64,
    /// The y-coordinate.
    y: f64,

    /// The vector (0, 0).
    pub const ZERO: Vec2 = Vec2.new(0.0, 0.0);

    /// Create a new vector.
    pub inline fn new(x: f64, y: f64) Vec2 {
        return .{ .x = x, .y = y };
    }

    /// Convert this vector into a `Point`.
    pub inline fn toPoint(self: Vec2) Point {
        return Point.new(self.x, self.y);
    }

    /// Convert this vector into a `Size`.
    pub inline fn toSize(self: Vec2) Size {
        return Size.new(self.x, self.y);
    }

    /// Create a vector with the same value for `x` and `y`.
    pub inline fn splat(v: f64) Vec2 {
        return .{ .x = v, .y = v };
    }

    /// Dot product of two vectors.
    pub inline fn dot(self: Vec2, other: Vec2) f64 {
        return self.x * other.x + self.y * other.y;
    }

    /// Cross product of two vectors.
    ///
    /// This is signed so that `(1, 0) × (0, 1) = 1`.
    pub inline fn cross(self: Vec2, other: Vec2) f64 {
        return self.x * other.y - self.y * other.x;
    }

    /// Magnitude of vector.
    ///
    /// Avoids `f64::hypot` as it calls a slow library function.
    pub inline fn hypot(self: Vec2) f64 {
        return @sqrt(self.hypot2());
    }

    /// Magnitude of vector. Alias for `hypot`.
    pub inline fn length(self: Vec2) f64 {
        return self.hypot();
    }

    /// Magnitude squared of vector.
    pub inline fn hypot2(self: Vec2) f64 {
        return self.dot(self);
    }

    /// Magnitude squared of vector. Alias for `hypot2`.
    pub inline fn lengthSquared(self: Vec2) f64 {
        return self.hypot2();
    }

    /// Find the angle in radians between this vector and `(1, 0)`, in the
    /// positive `y` direction.
    pub inline fn atan2(self: Vec2) f64 {
        return std.math.atan2(self.y, self.x);
    }

    /// Alias for `atan2`.
    pub inline fn angle(self: Vec2) f64 {
        return self.atan2();
    }

    /// A unit vector of the given angle.
    pub inline fn fromAngle(th: f64) Vec2 {
        const sc = common.FloatFuncs.sinCos(th);
        return .{ .x = sc[1], .y = sc[0] };
    }

    /// Linearly interpolate between two vectors.
    pub inline fn lerp(self: Vec2, other: Vec2, t: f64) Vec2 {
        return self.add(other.sub(self).mulScalar(t));
    }

    /// Returns a vector of magnitude 1.0 with the same angle as `self`.
    ///
    /// This produces `NaN` values when the magnitude is `0`.
    pub inline fn normalize(self: Vec2) Vec2 {
        return self.divScalar(self.hypot());
    }

    /// Returns a new `Vec2` with `x` and `y` rounded to the nearest integer.
    pub inline fn round(self: Vec2) Vec2 {
        return .{ .x = @round(self.x), .y = @round(self.y) };
    }

    /// Returns a new `Vec2` with `x` and `y` rounded up.
    pub inline fn ceil(self: Vec2) Vec2 {
        return .{ .x = @ceil(self.x), .y = @ceil(self.y) };
    }

    /// Returns a new `Vec2` with `x` and `y` rounded down.
    pub inline fn floor(self: Vec2) Vec2 {
        return .{ .x = @floor(self.x), .y = @floor(self.y) };
    }

    /// Returns a new `Vec2` with `x` and `y` rounded away from zero.
    pub inline fn expand(self: Vec2) Vec2 {
        return .{ .x = common.expand(self.x), .y = common.expand(self.y) };
    }

    /// Returns a new `Vec2` with `x` and `y` rounded toward zero.
    pub inline fn trunc(self: Vec2) Vec2 {
        return .{ .x = @trunc(self.x), .y = @trunc(self.y) };
    }

    /// Is this `Vec2` finite?
    pub inline fn isFinite(self: Vec2) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y);
    }

    /// Is this `Vec2` `NaN`?
    pub inline fn isNan(self: Vec2) bool {
        return std.math.isNan(self.x) or std.math.isNan(self.y);
    }

    /// Divides this `Vec2` by a scalar, per component.
    ///
    /// Unlike `div` (which multiplies by the reciprocal for performance),
    /// this performs the division per-component for consistent rounding.
    pub inline fn divExact(self: Vec2, divisor: f64) Vec2 {
        return .{ .x = self.x / divisor, .y = self.y / divisor };
    }

    /// Turn by 90 degrees.
    pub inline fn turn90(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    /// Combine two vectors interpreted as rotation and scaling.
    pub inline fn rotateScale(self: Vec2, rhs: Vec2) Vec2 {
        return .{
            .x = self.x * rhs.x - self.y * rhs.y,
            .y = self.x * rhs.y + self.y * rhs.x,
        };
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Vec2 + Vec2`.
    pub inline fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    /// Upstream `Vec2 - Vec2`.
    pub inline fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    /// Upstream `Vec2 * f64`.
    pub inline fn mulScalar(self: Vec2, other: f64) Vec2 {
        return .{ .x = self.x * other, .y = self.y * other };
    }

    /// Upstream `Vec2 / f64`.
    ///
    /// Note: upstream implements this by multiplying by the reciprocal, which
    /// is more efficient but has different roundoff behavior than division.
    pub inline fn divScalar(self: Vec2, other: f64) Vec2 {
        return self.mulScalar(1.0 / other);
    }

    /// Upstream unary `-Vec2`.
    pub inline fn neg(self: Vec2) Vec2 {
        return .{ .x = -self.x, .y = -self.y };
    }
};

test "vec2 cross sign" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 1.0), Vec2.new(1.0, 0.0).cross(Vec2.new(0.0, 1.0)));
}

test "vec2 turn_90" {
    const testing = std.testing;
    const u = Vec2.new(0.1, 0.2);
    const turned = u.turn90();
    // This should be exactly equal by IEEE rules.
    try testing.expectEqual(u.length(), turned.length());
    const EPSILON: f64 = 1e-12;
    try testing.expect(@abs(u.angle() + std.math.pi / 2.0 - turned.angle()) < EPSILON);
}

test "vec2 rotate_scale" {
    const testing = std.testing;
    const u = Vec2.new(0.1, 0.2);
    const v = Vec2.new(0.3, -0.4);
    const uv = u.rotateScale(v);
    const EPSILON: f64 = 1e-12;
    try testing.expect(@abs(u.length() * v.length() - uv.length()) < EPSILON);
    try testing.expect(@abs(u.angle() + v.angle() - uv.angle()) < EPSILON);
}
