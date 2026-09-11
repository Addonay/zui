//! Port of kurbo 0.13.1 `quadbez.rs` (Apache-2.0 OR MIT).
//!
//! Shape duck typing (upstream `impl Shape for QuadBez`):
//! `toPath(self, tolerance, allocator) !BezPath`, `boundingBox() Rect`,
//! `area() f64`, `perimeter(accuracy) f64`, `winding(pt) i32`.
//! `toPath` allocates with the supplied allocator; free the result with
//! `BezPath.deinit`.
//!
//! Flattening: `flatten(self, tolerance, allocator, ctx, callback)` uses the
//! same subdivision heuristic as `bezpath.flatten` (the `QuadTo` branch) and
//! calls `callback(ctx, Point)` for each generated line endpoint, ending with
//! `p2`. The `allocator` parameter is accepted for a uniform signature with
//! `CubicBez.flatten` and is unused here.
//!
//! Omissions: `to_quads`-related spline machinery (`QuadSpline` is outside
//! this port's scope) and the `Affine * QuadBez` operator, which is
//! `QuadBez.transform` here.

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;
const Affine = @import("affine.zig").Affine;
const line_mod = @import("line.zig");
const Line = line_mod.Line;
const cubicbez = @import("cubicbez.zig");
const CubicBez = cubicbez.CubicBez;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;

/// A single quadratic Bézier segment.
pub const QuadBez = struct {
    p0: Point,
    p1: Point,
    p2: Point,

    /// Create a new quadratic Bézier segment.
    pub inline fn new(p0: Point, p1: Point, p2: Point) QuadBez {
        return .{ .p0 = p0, .p1 = p1, .p2 = p2 };
    }

    /// Raise the order by 1.
    ///
    /// Returns a cubic Bézier segment that exactly represents this quadratic.
    pub fn raise(self: QuadBez) CubicBez {
        const two_thirds = 2.0 / 3.0;
        return CubicBez.new(
            self.p0,
            self.p0.addVec(self.p1.subPoint(self.p0).mulScalar(two_thirds)),
            self.p2.addVec(self.p1.subPoint(self.p2).mulScalar(two_thirds)),
            self.p2,
        );
    }

    /// Estimate the number of subdivisions for flattening.
    pub fn estimateSubdiv(self: QuadBez, sqrt_tol: f64) FlattenParams {
        // Determine transformation to y = x^2 parabola.
        const d01 = self.p1.subPoint(self.p0);
        const d12 = self.p2.subPoint(self.p1);
        const dd = d01.sub(d12);
        const cross = self.p2.subPoint(self.p0).cross(dd);
        const x0 = d01.dot(dd) * (1.0 / cross);
        const x2 = d12.dot(dd) * (1.0 / cross);
        const scale = @abs(cross / (dd.hypot() * (x2 - x0)));

        // Compute number of subdivisions needed.
        const a0 = approxParabolaIntegral(x0);
        const a2 = approxParabolaIntegral(x2);
        const val: f64 = if (std.math.isFinite(scale)) blk: {
            const da = @abs(a2 - a0);
            const sqrt_scale = @sqrt(scale);
            if (common.FloatFuncs.signum(x0) == common.FloatFuncs.signum(x2)) {
                break :blk da * sqrt_scale;
            }
            // Handle cusp case (segment contains curvature maximum)
            const xmin = sqrt_tol / sqrt_scale;
            break :blk sqrt_tol * da / approxParabolaIntegral(xmin);
        } else 0.0;
        const u0_val = approxParabolaInvIntegral(a0);
        const u2_val = approxParabolaInvIntegral(a2);
        const uscale = 1.0 / (u2_val - u0_val);
        return .{ .a0 = a0, .a2 = a2, .u0 = u0_val, .uscale = uscale, .val = val };
    }

    /// Maps a value from 0..1 to 0..1.
    pub fn determineSubdivT(self: QuadBez, params: *const FlattenParams, x: f64) f64 {
        _ = self;
        const a = params.a0 + (params.a2 - params.a0) * x;
        const u = approxParabolaInvIntegral(a);
        return (u - params.u0) * params.uscale;
    }

    /// Is this quadratic Bezier curve finite?
    pub inline fn isFinite(self: QuadBez) bool {
        return self.p0.isFinite() and self.p1.isFinite() and self.p2.isFinite();
    }

    /// Is this quadratic Bezier curve `NaN`?
    pub inline fn isNan(self: QuadBez) bool {
        return self.p0.isNan() or self.p1.isNan() or self.p2.isNan();
    }

    /// Finds the value of `t` for which `self.eval(t)` is about `y`.
    ///
    /// Assumes that this segment is monotonic in `y` and that it crosses the
    /// height `y`. (Under these assumptions, there is a unique answer.)
    pub fn solveMonotonicForY(self: QuadBez, y: f64) f64 {
        const start_pt = self.start();
        const end_pt = self.end();

        const a = end_pt.y - 2.0 * self.p1.y + start_pt.y;
        const b = 2.0 * (self.p1.y - start_pt.y);
        const c = start_pt.y - y;

        const roots = common.solveQuadratic(c, b, a);
        for (roots.slice()) |t| {
            if (t >= 0.0 and t <= 1.0) {
                return t;
            }
        }

        // Even though we asserted that our y range contains `y`, it's possible
        // that we failed to find a solution numerically. (For example, rounding
        // of a, b, or c might have pushed the root outside of [0.0, 1.0].)
        // If we failed to find a solution, the real solution should be close
        // to one of the endpoints.
        if (@abs(start_pt.y - y) <= @abs(end_pt.y - y)) {
            return 0.0;
        }
        return 1.0;
    }

    // --------------------------------------------------- ParamCurve surface

    /// Evaluate the curve at parameter `t`.
    pub inline fn eval(self: QuadBez, t: f64) Point {
        const mt = 1.0 - t;
        const v = self.p0.toVec2().mulScalar(mt * mt).add(
            self.p1.toVec2().mulScalar(mt * 2.0).add(self.p2.toVec2().mulScalar(t)).mulScalar(t),
        );
        return v.toPoint();
    }

    /// Get a subsegment of the curve for the given parameter range.
    pub fn subsegment(self: QuadBez, t0: f64, t1: f64) QuadBez {
        const p0 = self.eval(t0);
        const p2 = self.eval(t1);
        const p1 = p0.addVec(
            self.p1.subPoint(self.p0).lerp(self.p2.subPoint(self.p1), t0).mulScalar(t1 - t0),
        );
        return .{ .p0 = p0, .p1 = p1, .p2 = p2 };
    }

    /// Subdivide into halves, using de Casteljau.
    pub inline fn subdivide(self: QuadBez) struct { QuadBez, QuadBez } {
        const pm = self.eval(0.5);
        return .{
            QuadBez.new(self.p0, self.p0.midpoint(self.p1), pm),
            QuadBez.new(pm, self.p1.midpoint(self.p2), self.p2),
        };
    }

    /// The start point.
    pub inline fn start(self: QuadBez) Point {
        return self.p0;
    }

    /// The end point.
    pub inline fn end(self: QuadBez) Point {
        return self.p2;
    }

    /// The derivative of the curve, as a line.
    pub inline fn deriv(self: QuadBez) Line {
        return Line.new(
            Vec2.mulScalar(self.p1.toVec2().sub(self.p0.toVec2()), 2.0).toPoint(),
            Vec2.mulScalar(self.p2.toVec2().sub(self.p1.toVec2()), 2.0).toPoint(),
        );
    }

    /// Arclength of a quadratic Bézier segment.
    ///
    /// This computation is based on an analytical formula. Since that formula
    /// suffers from numerical instability when the curve is very close to a
    /// straight line, we detect that case and fall back to Legendre-Gauss
    /// quadrature.
    ///
    /// Accuracy should be better than 1e-13 over the entire range.
    pub fn arclen(self: QuadBez, accuracy: f64) f64 {
        _ = accuracy;
        const d2 = self.p0.toVec2().sub(self.p1.toVec2().mulScalar(2.0)).add(self.p2.toVec2());
        const a = d2.hypot2();
        const d1 = self.p1.subPoint(self.p0);
        const c = d1.hypot2();
        if (a < 5e-4 * c) {
            // This case happens for nearly straight Béziers.
            //
            // Calculate arclength using Legendre-Gauss quadrature using
            // Behdad's formula.
            const v0 = self.p0.toVec2().mulScalar(-0.492943519233745)
                .add(self.p1.toVec2().mulScalar(0.430331482911935))
                .add(self.p2.toVec2().mulScalar(0.0626120363218102))
                .hypot();
            const v1 = self.p2.subPoint(self.p0).mulScalar(0.4444444444444444).hypot();
            const v2 = self.p0.toVec2().mulScalar(-0.0626120363218102)
                .sub(self.p1.toVec2().mulScalar(0.430331482911935))
                .add(self.p2.toVec2().mulScalar(0.492943519233745))
                .hypot();
            return v0 + v1 + v2;
        }
        const b = 2.0 * d2.dot(d1);

        const sabc = @sqrt(a + b + c);
        const a2 = std.math.pow(f64, a, -0.5);
        const a32 = common.FloatFuncs.powi(a2, 3);
        const c2 = 2.0 * @sqrt(c);
        const ba_c2 = b * a2 + c2;

        const v0 = 0.25 * a2 * a2 * b * (2.0 * sabc - c2) + sabc;
        // The factor of a2 here is a little arbitrary: we really want to test
        // whether ba_c2 is small, but it's also important for this comparison
        // to be scale-invariant.
        if (ba_c2 * a2 < 1e-13) {
            // This case happens for Béziers with a sharp kink.
            return v0;
        }
        return v0 + 0.25 * a32 * (4.0 * c * a - b * b) *
            @log(((2.0 * a + b) * a2 + 2.0 * sabc) / ba_c2);
    }

    /// Solve for the parameter that has the given arc length from the start.
    pub fn invArclen(self: QuadBez, target_arclen: f64, accuracy: f64) f64 {
        return common.invArclen(QuadBez, self, target_arclen, accuracy, subsegmentArclen);
    }

    fn subsegmentArclen(q: QuadBez, t0: f64, t1: f64, accuracy: f64) f64 {
        return q.subsegment(t0, t1).arclen(accuracy);
    }

    /// Compute the signed area under the curve.
    pub inline fn signedArea(self: QuadBez) f64 {
        return (self.p0.x * (2.0 * self.p1.y + self.p2.y) +
            2.0 * self.p1.x * (self.p2.y - self.p0.y) -
            self.p2.x * (self.p0.y + 2.0 * self.p1.y)) * (1.0 / 6.0);
    }

    /// Find the nearest point, using an analytical algorithm based on cubic
    /// root finding.
    pub fn nearest(self: QuadBez, p: Point, accuracy: f64) common.Nearest {
        _ = accuracy;
        const d0 = self.p1.subPoint(self.p0);
        const d1 = self.p0.toVec2().add(self.p2.toVec2()).sub(self.p1.toVec2().mulScalar(2.0));
        const d = self.p0.subPoint(p);
        const c0 = d.dot(d0);
        const c1 = 2.0 * d0.hypot2() + d.dot(d1);
        const c2 = 3.0 * d1.dot(d0);
        const c3 = d1.hypot2();
        const roots = common.solveCubic(c0, c1, c2, c3);
        var r_best: ?f64 = null;
        var t_best: f64 = 0.0;
        var need_ends = false;
        if (roots.len == 0) {
            need_ends = true;
        }
        for (roots.slice()) |t| {
            need_ends = tryQuadT(self, p, &t_best, &r_best, t) or need_ends;
        }
        if (need_ends) {
            evalQuadT(p, &t_best, &r_best, 0.0, self.p0);
            evalQuadT(p, &t_best, &r_best, 1.0, self.p2);
        }

        return .{ .t = t_best, .distance_sq = r_best.? };
    }

    /// Compute the extrema of the curve (at most two).
    ///
    /// Only extrema within the interior of the curve count, in increasing
    /// parameter order.
    pub fn extrema(self: QuadBez) common.SmallVec(f64, common.MAX_EXTREMA) {
        var result = common.SmallVec(f64, common.MAX_EXTREMA){};
        const d0 = self.p1.subPoint(self.p0);
        const d1 = self.p2.subPoint(self.p1);
        const dd = d1.sub(d0);
        if (dd.x != 0.0) {
            const t = -d0.x / dd.x;
            if (t > 0.0 and t < 1.0) {
                result.push(t);
            }
        }
        if (dd.y != 0.0) {
            const t = -d0.y / dd.y;
            if (t > 0.0 and t < 1.0) {
                result.push(t);
                if (result.len == 2 and result.buf[0] > t) {
                    result.swap(0, 1);
                }
            }
        }
        return result;
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Affine * QuadBez`.
    pub inline fn transform(self: QuadBez, affine: Affine) QuadBez {
        return .{
            .p0 = affine.transformPoint(self.p0),
            .p1 = affine.transformPoint(self.p1),
            .p2 = affine.transformPoint(self.p2),
        };
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath` (`MoveTo p0`, `QuadTo p1 p2`).
    pub fn toPath(self: QuadBez, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        _ = tolerance;
        var path = BezPath.init();
        errdefer path.deinit(allocator);
        try path.append(allocator, PathEl.moveTo(self.p0));
        try path.append(allocator, PathEl.quadTo(self.p1, self.p2));
        return path;
    }

    /// The smallest rectangle that encloses the curve.
    pub fn boundingBox(self: QuadBez) Rect {
        var bbox = Rect.fromPoints(self.start(), self.end());
        const ext = self.extrema();
        for (ext.slice()) |t| {
            bbox = bbox.unionPt(self.eval(t));
        }
        return bbox;
    }

    /// The area under the curve is not defined for an open shape.
    pub inline fn area(self: QuadBez) f64 {
        _ = self;
        return 0.0;
    }

    /// Total length of perimeter (the curve's arclength).
    pub inline fn perimeter(self: QuadBez, accuracy: f64) f64 {
        return self.arclen(accuracy);
    }

    /// The winding number is not defined for an open shape.
    pub inline fn winding(self: QuadBez, pt: Point) i32 {
        _ = self;
        _ = pt;
        return 0;
    }

    /// Flatten this quadratic into line segments.
    ///
    /// `callback(point)` is invoked for each interior subdivision point and
    /// finally for `p2`, matching the `QuadTo` branch of `bezpath.flatten`.
    /// The `allocator` parameter is unused (accepted for signature symmetry
    /// with `CubicBez.flatten`).
    pub fn flatten(self: QuadBez, tolerance: f64, allocator: std.mem.Allocator, ctx: anytype, callback: anytype) !void {
        _ = allocator;
        if (tolerance <= 0.0) return error.InvalidTolerance;
        const sqrt_tol = @sqrt(tolerance);
        const params = self.estimateSubdiv(sqrt_tol);
        const n = common.ceilToUsizeMin1(0.5 * params.val / sqrt_tol);
        const step = 1.0 / @as(f64, @floatFromInt(n));
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const u = @as(f64, @floatFromInt(i)) * step;
            const t = self.determineSubdivT(&params, u);
            callback(ctx, self.eval(t));
        }
        callback(ctx, self.p2);
    }
};

/// Flattening parameters (upstream `pub(crate) struct FlattenParams`).
pub const FlattenParams = struct {
    a0: f64,
    a2: f64,
    u0: f64,
    uscale: f64,
    /// The number of `subdivisions * 2 * sqrt_tol`.
    val: f64,
};

/// An approximation to `integral (1 + 4x^2)^-0.25 dx`.
///
/// This is used for flattening curves.
fn approxParabolaIntegral(x: f64) f64 {
    const D: f64 = 0.67;
    return x / (1.0 - D + std.math.sqrt(std.math.sqrt((D * D) * (D * D) + 0.25 * x * x)));
}

/// An approximation to the inverse parabola integral.
fn approxParabolaInvIntegral(x: f64) f64 {
    const B: f64 = 0.39;
    return x * (1.0 - B + @sqrt(B * B + 0.25 * x * x));
}

/// Helper for `QuadBez.nearest`: evaluate a parameter and keep the best.
fn evalQuadT(pt: Point, t_best: *f64, r_best: *?f64, t: f64, p0: Point) void {
    const r = p0.subPoint(pt).hypot2();
    if (r_best.* == null or r < r_best.*.?) {
        r_best.* = r;
        t_best.* = t;
    }
}

/// Helper for `QuadBez.nearest`: evaluate `t` if in range; report whether it
/// was out of range.
fn tryQuadT(q: QuadBez, pt: Point, t_best: *f64, r_best: *?f64, t: f64) bool {
    if (!(t >= 0.0 and t <= 1.0)) {
        return true;
    }
    evalQuadT(pt, t_best, r_best, t, q.eval(t));
    return false;
}

test "quadbez deriv" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(0.0, 0.0),
        Point.new(0.0, 0.5),
        Point.new(1.0, 1.0),
    );
    const deriv = q.deriv();

    const n = 10;
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const delta = 1e-6;
        const p = q.eval(t);
        const p1 = q.eval(t + delta);
        const d_approx = p1.subPoint(p).mulScalar(1.0 / delta);
        const d = deriv.eval(t).toVec2();
        try testing.expect(d.sub(d_approx).hypot() < delta * 2.0);
    }
}

test "quadbez arclen" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(0.0, 0.0),
        Point.new(0.0, 0.5),
        Point.new(1.0, 1.0),
    );
    const true_arclen = 0.5 * @sqrt(5.0) + 0.25 * @log(2.0 + @sqrt(5.0));
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const accuracy = std.math.pow(f64, 0.1, @floatFromInt(i));
        const est = q.arclen(accuracy);
        try testing.expect(@abs(est - true_arclen) < accuracy);
    }
}

test "quadbez arclen pathological" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(-1.0, 0.0),
        Point.new(1.03, 0.0),
        Point.new(1.0, 0.0),
    );
    const true_arclen = 2.0008737864167325; // A rough empirical calculation
    const accuracy = 1e-11;
    const est = q.arclen(accuracy);
    try testing.expect(@abs(est - true_arclen) < accuracy);
}

test "quadbez subsegment" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(3.1, 4.1),
        Point.new(5.9, 2.6),
        Point.new(5.3, 5.8),
    );
    const t0 = 0.1;
    const t1 = 0.8;
    const qs = q.subsegment(t0, t1);
    const epsilon = 1e-12;
    const n = 10;
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const ts = t0 + t * (t1 - t0);
        try testing.expect(q.eval(ts).subPoint(qs.eval(t)).hypot() < epsilon);
    }
}

test "quadbez raise" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(3.1, 4.1),
        Point.new(5.9, 2.6),
        Point.new(5.3, 5.8),
    );
    const c = q.raise();
    const qd = q.deriv();
    const cd = c.deriv();
    const epsilon = 1e-12;
    const n = 10;
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        try testing.expect(q.eval(t).subPoint(c.eval(t)).hypot() < epsilon);
        try testing.expect(qd.eval(t).subPoint(cd.eval(t)).hypot() < epsilon);
    }
}

test "quadbez signed_area" {
    const testing = std.testing;
    // y = 1 - x^2
    const q = QuadBez.new(
        Point.new(1.0, 0.0),
        Point.new(0.5, 1.0),
        Point.new(0.0, 1.0),
    );
    const epsilon = 1e-12;
    try testing.expect(@abs(q.signedArea() - 2.0 / 3.0) < epsilon);
    try testing.expect(@abs(q.transform(Affine.rotate(0.5)).signedArea() - 2.0 / 3.0) < epsilon);
    try testing.expect(@abs(q.transform(Affine.translate(Vec2.new(0.0, 1.0))).signedArea() - 3.5 / 3.0) < epsilon);
    try testing.expect(@abs(q.transform(Affine.translate(Vec2.new(1.0, 0.0))).signedArea() - 3.5 / 3.0) < epsilon);
}

test "quadbez nearest" {
    const verify = struct {
        fn f(result: common.Nearest, expected: f64) !void {
            try std.testing.expect(@abs(result.t - expected) < 1e-6);
        }
    }.f;

    // y = x^2
    const q = QuadBez.new(
        Point.new(-1.0, 1.0),
        Point.new(0.0, -1.0),
        Point.new(1.0, 1.0),
    );
    try verify(q.nearest(Point.new(0.0, 0.0), 1e-3), 0.5);
    try verify(q.nearest(Point.new(0.0, 0.1), 1e-3), 0.5);
    try verify(q.nearest(Point.new(0.0, -0.1), 1e-3), 0.5);
    try verify(q.nearest(Point.new(0.5, 0.25), 1e-3), 0.75);
    try verify(q.nearest(Point.new(1.0, 1.0), 1e-3), 1.0);
    try verify(q.nearest(Point.new(1.1, 1.1), 1e-3), 1.0);
    try verify(q.nearest(Point.new(-1.1, 1.1), 1e-3), 0.0);
    const a = Affine.rotate(0.5);
    try verify(q.transform(a).nearest(a.transformPoint(Point.new(0.5, 0.25)), 1e-3), 0.75);
}

test "quadbez nearest_low_order" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(-1.0, 0.0),
        Point.new(0.0, 0.0),
        Point.new(1.0, 0.0),
    );
    try testing.expect(@abs(q.nearest(Point.new(0.0, 0.0), 1e-3).t - 0.5) < 1e-6);
    try testing.expect(@abs(q.nearest(Point.new(0.0, 1.0), 1e-3).t - 0.5) < 1e-6);
}

test "quadbez nearest_rounding_panic" {
    const quad = QuadBez.new(
        Point.new(-1.0394736842105263, 0.0),
        Point.new(0.8210526315789474, -1.511111111111111),
        Point.new(0.0, 1.9333333333333333),
    );
    const test_point = Point.new(-1.7976931348623157e308, 0.8571428571428571);
    const result = quad.nearest(test_point, 1e-6);
    try std.testing.expect(result.t >= 0.0 and result.t <= 1.0);
}

test "quadbez extrema" {
    const testing = std.testing;
    // y = x^2
    const q = QuadBez.new(
        Point.new(-1.0, 1.0),
        Point.new(0.0, -1.0),
        Point.new(1.0, 1.0),
    );
    const extrema = q.extrema();
    try testing.expectEqual(@as(usize, 1), extrema.len);
    try testing.expect(@abs(extrema.get(0) - 0.5) < 1e-6);

    const q2 = QuadBez.new(
        Point.new(0.0, 0.5),
        Point.new(1.0, 1.0),
        Point.new(0.5, 0.0),
    );
    const extrema2 = q2.extrema();
    try testing.expectEqual(@as(usize, 2), extrema2.len);
    try testing.expect(@abs(extrema2.get(0) - 1.0 / 3.0) < 1e-6);
    try testing.expect(@abs(extrema2.get(1) - 2.0 / 3.0) < 1e-6);

    // Reverse direction
    const q3 = QuadBez.new(
        Point.new(0.5, 0.0),
        Point.new(1.0, 1.0),
        Point.new(0.0, 0.5),
    );
    const extrema3 = q3.extrema();
    try testing.expectEqual(@as(usize, 2), extrema3.len);
    try testing.expect(@abs(extrema3.get(0) - 1.0 / 3.0) < 1e-6);
    try testing.expect(@abs(extrema3.get(1) - 2.0 / 3.0) < 1e-6);
}

test "quadbez perimeter_not_nan" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(2685.0, -1251.0),
        Point.new(2253.0, -1303.0),
        Point.new(2253.0, -1303.0),
    );
    const len = q.arclen(common.DEFAULT_ACCURACY);
    try testing.expect(std.math.isFinite(len));
}

test "quadbez inv_arclen" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(0.0, 0.0),
        Point.new(0.0, 0.5),
        Point.new(1.0, 1.0),
    );
    const true_arclen = 0.5 * @sqrt(5.0) + 0.25 * @log(2.0 + @sqrt(5.0));
    const accuracy = 1e-9;
    const t = q.invArclen(true_arclen * 0.5, accuracy);
    const actual = q.subsegment(0.0, t).arclen(accuracy);
    try testing.expect(@abs(actual - true_arclen * 0.5) < 1e-6);

    try testing.expectEqual(@as(f64, 0.0), q.invArclen(-1.0, accuracy));
    try testing.expectEqual(@as(f64, 1.0), q.invArclen(true_arclen * 2.0, accuracy));
}

test "quadbez flatten" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(0.0, 0.0),
        Point.new(0.0, 0.5),
        Point.new(1.0, 1.0),
    );
    const Ctx = struct {
        points: std.ArrayList(Point) = .empty,
        fn call(ctx: *@This(), p: Point) void {
            ctx.points.append(std.testing.allocator, p) catch @panic("OOM");
        }
    };
    var ctx = Ctx{};
    defer ctx.points.deinit(testing.allocator);
    try q.flatten(0.1, testing.allocator, &ctx, Ctx.call);
    try testing.expect(ctx.points.items.len >= 1);
    try testing.expectEqualDeep(q.p2, ctx.points.items[ctx.points.items.len - 1]);

    // The polyline must stay within tolerance of the curve (sampled).
    var last = q.p0;
    for (ctx.points.items) |p| {
        const mid = last.midpoint(p);
        const nearest = q.nearest(mid, 1e-9);
        try testing.expect(@sqrt(nearest.distance_sq) <= 0.1 + 1e-9);
        last = p;
    }
}
