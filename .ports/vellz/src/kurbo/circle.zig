//! Port of kurbo 0.13.1 `circle.rs` (Apache-2.0 OR MIT).
//!
//! Shape duck typing (upstream `impl Shape for Circle`):
//! `toPath(self, tolerance, allocator) !BezPath`, `boundingBox() Rect`,
//! `area() f64`, `perimeter(accuracy) f64`, `winding(pt) i32`.
//! `toPath` allocates with the supplied allocator; free the result with
//! `BezPath.deinit`.
//!
//! Zig has no operator overloading, so `Circle + Vec2`/`Circle - Vec2` are
//! `addVec`/`subVec`.
//!
//! Omissions: `CircleSegment` (needs `Arc`), the `Affine * Circle -> Ellipse`
//! operator (needs `Ellipse`), and the `mint` conversions.
//!
//! Adaptation: `toPath` returns `error.InvalidTolerance` for a non-positive
//! tolerance instead of upstream's saturating huge subdivision count.

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;

const PI = std.math.pi;

/// A circle.
pub const Circle = struct {
    /// The center.
    center: Point,
    /// The radius.
    radius: f64,

    /// A new circle from center and radius.
    pub inline fn new(center: Point, radius: f64) Circle {
        return .{ .center = center, .radius = radius };
    }

    /// Is this circle finite?
    pub inline fn isFinite(self: Circle) bool {
        return self.center.isFinite() and std.math.isFinite(self.radius);
    }

    /// Is this circle `NaN`?
    pub inline fn isNan(self: Circle) bool {
        return self.center.isNan() or std.math.isNan(self.radius);
    }

    /// Upstream `Circle + Vec2`.
    pub inline fn addVec(self: Circle, v: Vec2) Circle {
        return .{ .center = self.center.addVec(v), .radius = self.radius };
    }

    /// Upstream `Circle - Vec2`.
    pub inline fn subVec(self: Circle, v: Vec2) Circle {
        return .{ .center = self.center.subVec(v), .radius = self.radius };
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath`.
    ///
    /// Allocates with `allocator`; the caller owns the result. The path starts
    /// with a `MoveTo` followed by `n` `CurveTo` elements and a `ClosePath`,
    /// using upstream's tolerance-derived subdivision count.
    pub fn toPath(self: Circle, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        if (!(tolerance > 0.0)) return error.InvalidTolerance;
        const scaled_err = @abs(self.radius) / tolerance;
        var n: usize = undefined;
        var arm_len: f64 = undefined;
        if (scaled_err < 1.0 / 1.9608e-4) {
            // Solution from http://spencermortensen.com/articles/bezier-circle/
            n = 4;
            arm_len = 0.551915024494;
        } else {
            // This is empirically determined to fall within error tolerance.
            n = common.ceilToUsizeMin1(std.math.pow(f64, 1.1163 * scaled_err, 1.0 / 6.0));
            // Note: this isn't minimum error, but it is simple and we can
            // easily estimate the error.
            arm_len = (4.0 / 3.0) * @tan((PI / 2.0) / @as(f64, @floatFromInt(n)));
        }
        const delta_th = 2.0 * PI / @as(f64, @floatFromInt(n));

        var path = BezPath.init();
        errdefer path.deinit(allocator);

        const a = arm_len;
        const r = self.radius;
        const x = self.center.x;
        const y = self.center.y;
        try path.append(allocator, PathEl.moveTo(Point.new(x + r, y)));
        var ix: usize = 1;
        while (ix <= n) : (ix += 1) {
            const th1 = delta_th * @as(f64, @floatFromInt(ix));
            const th0 = th1 - delta_th;
            const sc0 = common.FloatFuncs.sinCos(th0);
            const s0 = sc0[0];
            const c0 = sc0[1];
            var s1: f64 = 0.0;
            var c1: f64 = 1.0;
            if (ix != n) {
                const sc1 = common.FloatFuncs.sinCos(th1);
                s1 = sc1[0];
                c1 = sc1[1];
            }
            try path.append(allocator, PathEl.curveTo(
                Point.new(x + r * (c0 - a * s0), y + r * (s0 + a * c0)),
                Point.new(x + r * (c1 + a * s1), y + r * (s1 - a * c1)),
                Point.new(x + r * c1, y + r * s1),
            ));
        }
        try path.append(allocator, PathEl.closePath());
        return path;
    }

    /// Signed area covered by this shape (`PI * radius^2`).
    pub inline fn area(self: Circle) f64 {
        return PI * common.FloatFuncs.powi(self.radius, 2);
    }

    /// Total length of perimeter (`|2 * PI * radius|`).
    pub inline fn perimeter(self: Circle, accuracy: f64) f64 {
        _ = accuracy;
        return @abs(2.0 * PI * self.radius);
    }

    /// The winding number of a point.
    pub fn winding(self: Circle, pt: Point) i32 {
        if (pt.subPoint(self.center).hypot2() < common.FloatFuncs.powi(self.radius, 2)) {
            return 1;
        }
        return 0;
    }

    /// Returns `true` if the point is inside the circle.
    pub inline fn contains(self: Circle, pt: Point) bool {
        return self.winding(pt) != 0;
    }

    /// The smallest rectangle that encloses the circle.
    pub inline fn boundingBox(self: Circle) Rect {
        const r = @abs(self.radius);
        return Rect.new(
            self.center.x - r,
            self.center.y - r,
            self.center.x + r,
            self.center.y + r,
        );
    }
};

fn assertApproxEq(x: f64, y: f64) !void {
    // Note: we might want to be more rigorous in testing the accuracy of the
    // conversion into Béziers, but this seems good enough.
    try std.testing.expect(@abs(x - y) < 1e-7);
}

test "circle area_sign" {
    const testing = std.testing;
    const center = Point.new(5.0, 5.0);
    const c = Circle.new(center, 5.0);
    try assertApproxEq(c.area(), 25.0 * PI);

    try testing.expectEqual(@as(i32, 1), c.winding(center));

    var p = try c.toPath(1e-9, testing.allocator);
    defer p.deinit(testing.allocator);
    try assertApproxEq(c.area(), p.area());
    try testing.expectEqual(c.winding(center), p.winding(center));

    const c_neg_radius = Circle.new(center, -5.0);
    try assertApproxEq(c_neg_radius.area(), 25.0 * PI);

    try testing.expectEqual(@as(i32, 1), c_neg_radius.winding(center));

    var p_neg_radius = try c_neg_radius.toPath(1e-9, testing.allocator);
    defer p_neg_radius.deinit(testing.allocator);
    try assertApproxEq(c_neg_radius.area(), p_neg_radius.area());
    try testing.expectEqual(c_neg_radius.winding(center), p_neg_radius.winding(center));
}
