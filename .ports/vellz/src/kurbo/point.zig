//! Port of kurbo 0.13.1 `point.rs` (Apache-2.0 OR MIT).
//!
//! Zig has no operator overloading, so the upstream operators are methods:
//! `addVec` (`Point + Vec2`), `subVec` (`Point - Vec2`), `subPoint`
//! (`Point - Point -> Vec2`).
//!
//! Omissions: the `mint` conversions (feature-gated upstream) and the
//! `Axis`-indexed accessors (`Axis` is not part of this port's surface).

const std = @import("std");
const common = @import("common.zig");
const Vec2 = @import("vec2.zig").Vec2;

/// A 2D point.
///
/// This type has the same layout as `Vec2`, but its meaning is different:
/// `Vec2` represents a change in location (for example velocity).
pub const Point = struct {
    /// The x coordinate.
    x: f64,
    /// The y coordinate.
    y: f64,

    /// The point (0, 0).
    pub const ZERO: Point = Point.new(0.0, 0.0);

    /// The point at the origin; (0, 0).
    pub const ORIGIN: Point = Point.new(0.0, 0.0);

    /// Create a new `Point` with the provided `x` and `y` coordinates.
    pub inline fn new(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }

    /// Convert this point into a `Vec2`.
    pub inline fn toVec2(self: Point) Vec2 {
        return Vec2.new(self.x, self.y);
    }

    /// Linearly interpolate between two points.
    pub inline fn lerp(self: Point, other: Point, t: f64) Point {
        return self.toVec2().lerp(other.toVec2(), t).toPoint();
    }

    /// Determine the midpoint of two points.
    pub inline fn midpoint(self: Point, other: Point) Point {
        return Point.new(0.5 * (self.x + other.x), 0.5 * (self.y + other.y));
    }

    /// Euclidean distance.
    pub inline fn distance(self: Point, other: Point) f64 {
        return self.subPoint(other).hypot();
    }

    /// Squared Euclidean distance.
    pub inline fn distanceSquared(self: Point, other: Point) f64 {
        return self.subPoint(other).hypot2();
    }

    /// Returns a new `Point` with `x` and `y` rounded to the nearest integer.
    pub inline fn round(self: Point) Point {
        return Point.new(@round(self.x), @round(self.y));
    }

    /// Returns a new `Point` with `x` and `y` rounded up.
    pub inline fn ceil(self: Point) Point {
        return Point.new(@ceil(self.x), @ceil(self.y));
    }

    /// Returns a new `Point` with `x` and `y` rounded down.
    pub inline fn floor(self: Point) Point {
        return Point.new(@floor(self.x), @floor(self.y));
    }

    /// Returns a new `Point` with `x` and `y` rounded away from zero.
    pub inline fn expand(self: Point) Point {
        return Point.new(common.expand(self.x), common.expand(self.y));
    }

    /// Returns a new `Point` with `x` and `y` rounded toward zero.
    pub inline fn trunc(self: Point) Point {
        return Point.new(@trunc(self.x), @trunc(self.y));
    }

    /// Is this point finite?
    pub inline fn isFinite(self: Point) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y);
    }

    /// Is this point `NaN`?
    pub inline fn isNan(self: Point) bool {
        return std.math.isNan(self.x) or std.math.isNan(self.y);
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Point + Vec2`.
    pub inline fn addVec(self: Point, other: Vec2) Point {
        return Point.new(self.x + other.x, self.y + other.y);
    }

    /// Upstream `Point - Vec2`.
    pub inline fn subVec(self: Point, other: Vec2) Point {
        return Point.new(self.x - other.x, self.y - other.y);
    }

    /// Upstream `Point - Point`.
    pub inline fn subPoint(self: Point, other: Point) Vec2 {
        return Vec2.new(self.x - other.x, self.y - other.y);
    }
};

test "point arithmetic" {
    const testing = std.testing;
    try testing.expectEqualDeep(
        Point.new(-10.0, 0.0),
        Point.new(0.0, 0.0).subVec(Vec2.new(10.0, 0.0)),
    );
    try testing.expectEqualDeep(
        Vec2.new(5.0, -101.0),
        Point.new(0.0, 0.0).subPoint(Point.new(-5.0, 101.0)),
    );
}

test "point distance" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 5.0), Point.new(0.0, 10.0).distance(Point.new(0.0, 5.0)));
    try testing.expectEqual(@as(f64, 5.0), Point.new(-11.0, 1.0).distance(Point.new(-7.0, -2.0)));
}

test "point round/expand/trunc" {
    const testing = std.testing;
    const a = Point.new(3.3, 3.6).round();
    const b = Point.new(3.0, -3.1).round();
    try testing.expectEqual(@as(f64, 3.0), a.x);
    try testing.expectEqual(@as(f64, 4.0), a.y);
    try testing.expectEqual(@as(f64, 3.0), b.x);
    try testing.expectEqual(@as(f64, -3.0), b.y);

    const c = Point.new(3.3, 3.6).expand();
    const d = Point.new(3.0, -3.1).expand();
    try testing.expectEqual(@as(f64, 4.0), c.x);
    try testing.expectEqual(@as(f64, 4.0), c.y);
    try testing.expectEqual(@as(f64, 3.0), d.x);
    try testing.expectEqual(@as(f64, -4.0), d.y);

    const e = Point.new(3.3, 3.6).trunc();
    try testing.expectEqual(@as(f64, 3.0), e.x);
    try testing.expectEqual(@as(f64, 3.0), e.y);
}
