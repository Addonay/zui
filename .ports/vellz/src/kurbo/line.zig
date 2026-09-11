//! Port of kurbo 0.13.1 `line.rs` (Apache-2.0 OR MIT).
//!
//! Shape duck typing (upstream `impl Shape for Line`):
//! `toPath(self, tolerance, allocator) !BezPath`, `boundingBox() Rect`,
//! `area() f64`, `perimeter(accuracy) f64`, `winding(pt) i32`.
//! `toPath` allocates with the supplied allocator; free the returned path
//! with `BezPath.deinit`.
//!
//! Zig has no operator overloading, so upstream operators are methods:
//! `addVec` (`Line + Vec2`), `subVec` (`Line - Vec2`), `transform`
//! (`Affine * Line`).

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;
const Affine = @import("affine.zig").Affine;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;

/// A single line.
pub const Line = struct {
    /// The line's start point.
    p0: Point,
    /// The line's end point.
    p1: Point,

    /// Create a new line.
    pub inline fn new(p0: Point, p1: Point) Line {
        return .{ .p0 = p0, .p1 = p1 };
    }

    /// Returns a copy of this `Line` with the end points swapped so that it
    /// points in the opposite direction.
    pub inline fn reversed(self: Line) Line {
        return .{ .p0 = self.p1, .p1 = self.p0 };
    }

    /// The length of the line.
    pub inline fn length(self: Line) f64 {
        return self.arclen(common.DEFAULT_ACCURACY);
    }

    /// The midpoint of the line.
    pub inline fn midpoint(self: Line) Point {
        return self.p0.midpoint(self.p1);
    }

    /// Computes the point where two lines, if extended to infinity, would
    /// cross.
    pub fn crossingPoint(self: Line, other: Line) ?Point {
        const ab = self.p1.subPoint(self.p0);
        const cd = other.p1.subPoint(other.p0);
        const pcd = ab.cross(cd);
        if (pcd == 0.0) {
            return null;
        }
        const h = ab.cross(self.p0.subPoint(other.p0)) / pcd;
        return other.p0.addVec(cd.mulScalar(h));
    }

    /// Is this line finite?
    pub inline fn isFinite(self: Line) bool {
        return self.p0.isFinite() and self.p1.isFinite();
    }

    /// Is this line `NaN`?
    pub inline fn isNan(self: Line) bool {
        return self.p0.isNan() or self.p1.isNan();
    }

    // --------------------------------------------------- ParamCurve surface

    /// Evaluate the line at parameter `t`.
    pub inline fn eval(self: Line, t: f64) Point {
        return self.p0.lerp(self.p1, t);
    }

    /// Get a subsegment of the line for the given parameter range.
    pub inline fn subsegment(self: Line, t0: f64, t1: f64) Line {
        return .{ .p0 = self.eval(t0), .p1 = self.eval(t1) };
    }

    /// Subdivide into halves.
    pub inline fn subdivide(self: Line) struct { Line, Line } {
        return .{ self.subsegment(0.0, 0.5), self.subsegment(0.5, 1.0) };
    }

    /// The start point.
    pub inline fn start(self: Line) Point {
        return self.p0;
    }

    /// The end point.
    pub inline fn end(self: Line) Point {
        return self.p1;
    }

    /// The derivative of the line, as a trivial constant curve.
    pub inline fn deriv(self: Line) ConstPoint {
        return ConstPoint{ .p = self.p1.subPoint(self.p0).toPoint() };
    }

    /// The arc length of the line (independent of `accuracy`).
    pub inline fn arclen(self: Line, accuracy: f64) f64 {
        _ = accuracy;
        return self.p1.subPoint(self.p0).hypot();
    }

    /// Solve for the parameter that has the given arc length from the start.
    pub inline fn invArclen(self: Line, target_arclen: f64, accuracy: f64) f64 {
        _ = accuracy;
        return target_arclen / self.p1.subPoint(self.p0).hypot();
    }

    /// Compute the signed area under the line.
    pub inline fn signedArea(self: Line) f64 {
        return self.p0.toVec2().cross(self.p1.toVec2()) * 0.5;
    }

    /// Find the position on the line nearest to the point.
    pub fn nearest(self: Line, p: Point, accuracy: f64) common.Nearest {
        _ = accuracy;
        const d = self.p1.subPoint(self.p0);
        const v = p.subPoint(self.p0);

        // Calculate projection parameter `t` of the point onto the line
        // segment s(t), with s(t) = (1-t) * p0 + t * p1.
        //
        // Note when the segment has 0 length, this will be positive or
        // negative infinity or NaN; see the clamping below.
        const t_unclamped = d.dot(v) / d.hypot2();

        // Clamp the parameter to be on the line segment. This clamps negative
        // infinity and NaN to `0.`, and positive infinity to `1.`.
        const t = @max(t_unclamped, 0.0);
        const t_clamped = @min(t, 1.0);

        // Calculate ||p - s(t)||^2.
        const distance_sq = v.sub(d.mulScalar(t_clamped)).hypot2();

        return .{ .distance_sq = distance_sq, .t = t_clamped };
    }

    /// The curvature of a line is always zero.
    pub inline fn curvature(self: Line, t: f64) f64 {
        _ = self;
        _ = t;
        return 0.0;
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Affine * Line`.
    pub inline fn transform(self: Line, affine: Affine) Line {
        return .{
            .p0 = affine.transformPoint(self.p0),
            .p1 = affine.transformPoint(self.p1),
        };
    }

    /// Upstream `Line + Vec2`.
    pub inline fn addVec(self: Line, v: Vec2) Line {
        return Line.new(self.p0.addVec(v), self.p1.addVec(v));
    }

    /// Upstream `Line - Vec2`.
    pub inline fn subVec(self: Line, v: Vec2) Line {
        return Line.new(self.p0.subVec(v), self.p1.subVec(v));
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath` (`MoveTo p0`, `LineTo p1`).
    ///
    /// Allocates with `allocator`; the caller owns the result.
    pub fn toPath(self: Line, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        _ = tolerance;
        var path = BezPath.init();
        errdefer path.deinit(allocator);
        try path.append(allocator, PathEl.moveTo(self.p0));
        try path.append(allocator, PathEl.lineTo(self.p1));
        return path;
    }

    /// The smallest rectangle that encloses the line.
    pub inline fn boundingBox(self: Line) Rect {
        return Rect.fromPoints(self.p0, self.p1);
    }

    /// Returning zero is consistent with the `Shape` contract (area is only
    /// meaningful for closed shapes).
    pub inline fn area(self: Line) f64 {
        _ = self;
        return 0.0;
    }

    /// Total length of the perimeter (the line's length).
    pub inline fn perimeter(self: Line, accuracy: f64) f64 {
        return self.arclen(accuracy);
    }

    /// Same consideration as `area`: zero.
    pub inline fn winding(self: Line, pt: Point) i32 {
        _ = self;
        _ = pt;
        return 0;
    }
};

/// A trivial "curve" that is just a constant; the derivative result of `Line`
/// (upstream `ConstPoint`).
pub const ConstPoint = struct {
    p: Point,

    /// Is this point finite?
    pub inline fn isFinite(self: ConstPoint) bool {
        return self.p.isFinite();
    }

    /// Is this point `NaN`?
    pub inline fn isNan(self: ConstPoint) bool {
        return self.p.isNan();
    }

    /// Evaluate the constant.
    pub inline fn eval(self: ConstPoint, t: f64) Point {
        _ = t;
        return self.p;
    }

    /// Subsegment of a constant curve is itself.
    pub inline fn subsegment(self: ConstPoint, t0: f64, t1: f64) ConstPoint {
        _ = t0;
        _ = t1;
        return self;
    }

    /// The derivative of a constant is zero.
    pub inline fn deriv(self: ConstPoint) ConstPoint {
        _ = self;
        return .{ .p = Point.new(0.0, 0.0) };
    }

    /// The arclength of a constant curve is zero.
    pub inline fn arclen(self: ConstPoint, accuracy: f64) f64 {
        _ = self;
        _ = accuracy;
        return 0.0;
    }

    /// The inverse arclength of a constant curve is zero.
    pub inline fn invArclen(self: ConstPoint, target_arclen: f64, accuracy: f64) f64 {
        _ = self;
        _ = target_arclen;
        _ = accuracy;
        return 0.0;
    }
};

test "line reversed" {
    const testing = std.testing;
    const l = Line.new(Point.new(0.0, 0.0), Point.new(1.0, 1.0));
    const f = l.reversed();
    try testing.expectEqualDeep(l.p0, f.p1);
    try testing.expectEqualDeep(l.p1, f.p0);
    try testing.expectEqualDeep(l, f.reversed());
}

test "line arclen" {
    const testing = std.testing;
    const l = Line.new(Point.new(0.0, 0.0), Point.new(1.0, 1.0));
    const true_len = @sqrt(2.0);
    const epsilon = 1e-9;
    try testing.expect(l.arclen(epsilon) - true_len < epsilon);

    const t = l.invArclen(true_len / 3.0, epsilon);
    try testing.expect(@abs(t - 1.0 / 3.0) < epsilon);
}

test "line midpoint" {
    const testing = std.testing;
    const l = Line.new(Point.new(0.0, 0.0), Point.new(2.0, 4.0));
    try testing.expectEqualDeep(Point.new(1.0, 2.0), l.midpoint());
}

test "line is_finite" {
    const testing = std.testing;
    try testing.expect((Line{ .p0 = Point.new(0.0, 0.0), .p1 = Point.new(1.0, 1.0) }).isFinite());
    try testing.expect(!(Line{ .p0 = Point.new(0.0, 0.0), .p1 = Point.new(std.math.inf(f64), 1.0) }).isFinite());
    try testing.expect(!(Line{ .p0 = Point.new(0.0, 0.0), .p1 = Point.new(0.0, std.math.inf(f64)) }).isFinite());
}

test "line nearest" {
    const testing = std.testing;
    const EPSILON: f64 = 1e-9;

    const line = Line.new(Point.new(-4.0, 0.0), Point.new(2.0, 1.0));

    // Projects onto the line segment end point.
    {
        const point = Point.new(4.0, 0.0);
        const nearest = line.nearest(point, 0.0);
        try testing.expectEqual(@as(f64, 1.0), nearest.t);
        try testing.expect(@abs(nearest.distance_sq - line.p1.distanceSquared(point)) < EPSILON);
    }

    // Projects onto the line segment start point.
    {
        const point = Point.new(0.0, -50.0);
        const nearest = line.nearest(point, 0.0);
        try testing.expectEqual(@as(f64, 0.0), nearest.t);
        try testing.expect(@abs(nearest.distance_sq - line.p0.distanceSquared(point)) < EPSILON);
    }

    // Projects onto the line segment proper.
    {
        const point = Point.new(-1.0, 0.5);
        const nearest = line.nearest(point, 0.0);
        try testing.expect(nearest.t > 0.0 and nearest.t < 1.0);
        try testing.expect(@abs(line.eval(nearest.t).distanceSquared(point) - nearest.distance_sq) < EPSILON);
        try testing.expect(line.eval(nearest.t * 0.95).distanceSquared(point) > nearest.distance_sq);
        try testing.expect(line.eval(nearest.t * 1.05).distanceSquared(point) > nearest.distance_sq);
    }
}

test "line crossing_point" {
    const testing = std.testing;
    const a = Line.new(Point.new(0.0, 0.0), Point.new(1.0, 1.0));
    const b = Line.new(Point.new(0.0, 1.0), Point.new(1.0, 0.0));
    const crossing = a.crossingPoint(b);
    try testing.expect(crossing != null);
    try testing.expect(crossing.?.distance(Point.new(0.5, 0.5)) < 1e-12);

    // Parallel lines do not cross.
    try testing.expectEqual(@as(?Point, null), a.crossingPoint(Line.new(Point.new(0.0, 1.0), Point.new(1.0, 2.0))));
}
