//! Port of kurbo 0.13.1 `cubicbez.rs` (Apache-2.0 OR MIT).
//!
//! Shape duck typing (upstream `impl Shape for CubicBez`):
//! `toPath(self, tolerance, allocator) !BezPath`, `boundingBox() Rect`,
//! `area() f64`, `perimeter(accuracy) f64`, `winding(pt) i32`.
//! `toPath` allocates with the supplied allocator; free the result with
//! `BezPath.deinit`.
//!
//! Flattening: `flatten(self, tolerance, allocator, ctx, callback)` mirrors
//! the `CurveTo` branch of `bezpath.flatten` exactly (quadratic conversion
//! with `TO_QUAD_TOL`, then per-quad subdivision), calling
//! `callback(ctx, Point)` for each generated line endpoint, ending with `p3`.
//!
//! `toQuads` in this port allocates and returns a slice (upstream returns an
//! `impl Iterator`); the caller owns it.
//!
//! Omissions: the quadratic-spline fitting machinery (`approx_spline`,
//! `cubics_to_quadratic_splines`, `split_into_n`; these need `QuadSpline`,
//! outside this port's scope) and `CuspType`/`regularize_cusp`/`detect_cusp`
//! (only used by upstream stroke/offset code, also out of scope).
//! `nearest` ports the `polycool` quintic solver from `common.zig`.

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;
const Affine = @import("affine.zig").Affine;
const quadbez = @import("quadbez.zig");
const QuadBez = quadbez.QuadBez;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;

/// Proportion of tolerance budget that goes to cubic to quadratic conversion
/// (upstream `bezpath::TO_QUAD_TOL`).
pub const TO_QUAD_TOL: f64 = 0.1;

/// A quadratic approximation of a sub-segment of a cubic, as produced by
/// `toQuads`.
pub const ToQuad = struct {
    /// Start parameter of the cubic sub-segment.
    t0: f64,
    /// End parameter of the cubic sub-segment.
    t1: f64,
    /// Best approximating quadratic for the sub-segment.
    quad: QuadBez,
};

/// A single cubic Bézier segment.
pub const CubicBez = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,

    /// Create a new cubic Bézier segment.
    pub inline fn new(p0: Point, p1: Point, p2: Point, p3: Point) CubicBez {
        return .{ .p0 = p0, .p1 = p1, .p2 = p2, .p3 = p3 };
    }

    /// Convert to quadratic Béziers.
    ///
    /// The result contains the start and end parameter in the cubic of each
    /// quadratic segment, along with the quadratic.
    ///
    /// This always produces at least one `QuadBez`. Allocates with `allocator`;
    /// the caller owns the returned slice.
    pub fn toQuads(self: CubicBez, accuracy: f64, allocator: std.mem.Allocator) ![]ToQuad {
        if (!(accuracy > 0.0)) return error.InvalidTolerance;
        // The maximum error, as a vector from the cubic to the best
        // approximating quadratic, is proportional to the third derivative,
        // which is constant across the segment. Thus, the error scales down as
        // the third power of the number of subdivisions, so we subdivide `t`
        // evenly.
        //
        // This magic number is the square of 36 / sqrt(3).
        const max_hypot2 = 432.0 * accuracy * accuracy;
        const p1x2 = self.p1.toVec2().mulScalar(3.0).sub(self.p0.toVec2());
        const p2x2 = self.p2.toVec2().mulScalar(3.0).sub(self.p3.toVec2());
        const err = p2x2.sub(p1x2).hypot2();
        const n = @max(common.ceilToUsizeMin1(std.math.pow(f64, err / max_hypot2, 1.0 / 6.0)), 1);

        const result = try allocator.alloc(ToQuad, n);
        errdefer allocator.free(result);
        for (result, 0..) |*out, i| {
            const t0 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const t1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n));
            const seg = self.subsegment(t0, t1);
            const q1x2 = seg.p1.toVec2().mulScalar(3.0).sub(seg.p0.toVec2());
            const q2x2 = seg.p2.toVec2().mulScalar(3.0).sub(seg.p3.toVec2());
            out.* = .{
                .t0 = t0,
                .t1 = t1,
                .quad = QuadBez.new(seg.p0, q1x2.add(q2x2).divScalar(4.0).toPoint(), seg.p3),
            };
        }
        return result;
    }

    /// Is this cubic Bezier curve finite?
    pub inline fn isFinite(self: CubicBez) bool {
        return self.p0.isFinite() and self.p1.isFinite() and
            self.p2.isFinite() and self.p3.isFinite();
    }

    /// Is this cubic Bezier curve `NaN`?
    pub inline fn isNan(self: CubicBez) bool {
        return self.p0.isNan() or self.p1.isNan() or self.p2.isNan() or self.p3.isNan();
    }

    /// Determine the inflection points.
    ///
    /// Return value is the t parameters of the inflection points of the curve
    /// segment. There are a maximum of two for a cubic Bézier.
    pub fn inflections(self: CubicBez) common.SmallVec(f64, 2) {
        var result = common.SmallVec(f64, 2){};
        const a = self.p1.subPoint(self.p0);
        const b = self.p2.subPoint(self.p1).sub(a);
        const c = self.p3.subPoint(self.p0).sub(self.p2.subPoint(self.p1).mulScalar(3.0));
        const roots = common.solveQuadratic(a.cross(b), a.cross(c), b.cross(c));
        for (roots.slice()) |t| {
            if (t >= 0.0 and t <= 1.0) {
                result.push(t);
            }
        }
        return result;
    }

    /// Find points on the curve where the tangent line passes through the
    /// given point.
    pub fn tangentsToPoint(self: CubicBez, p: Point) common.QuarticRoots {
        var result = common.QuarticRoots{};
        const params = self.parameters();
        const a = params[0];
        const b = params[1];
        const c = params[2];
        const d_orig = params[3];
        const d = d_orig.sub(p.toVec2());
        // coefficients of x(t) cross x'(t)
        const c4 = b.cross(a);
        const c3 = 2.0 * c.cross(a);
        const c2 = c.cross(b) + 3.0 * d.cross(a);
        const c1 = 2.0 * d.cross(b);
        const c0 = d.cross(c);
        const roots = common.solveQuartic(c0, c1, c2, c3, c4);
        for (roots.slice()) |t| {
            if (t >= 0.0 and t <= 1.0) {
                result.push(t);
            }
        }
        return result;
    }

    /// Finds the value of `t` for which `self.eval(t)` is about `y`.
    ///
    /// Assumes that this segment is monotonic in `y` and that it crosses the
    /// height `y`. (Under these assumptions, there is a unique answer.)
    pub fn solveMonotonicForY(self: CubicBez, y: f64) f64 {
        const start_pt = self.start();
        const end_pt = self.end();

        const p1 = self.p1;
        const p2 = self.p2;
        const a = end_pt.y - 3.0 * p2.y + 3.0 * p1.y - start_pt.y;
        const b = 3.0 * (p2.y - 2.0 * p1.y + start_pt.y);
        const c = 3.0 * (p1.y - start_pt.y);
        const d = start_pt.y - y;
        const roots = common.solveCubic(d, c, b, a);
        for (roots.slice()) |t| {
            if (t >= 0.0 and t <= 1.0) {
                return t;
            }
        }

        // Even though we asserted that our y range contains `y`, it's possible
        // that we failed to find a solution numerically.
        if (@abs(start_pt.y - y) <= @abs(end_pt.y - y)) {
            return 0.0;
        }
        return 1.0;
    }

    /// Polynomial parameters `(a, b, c, d)` of the cubic such that
    /// `p(t) = a t^3 + b t^2 + c t + d`.
    fn parameters(self: CubicBez) [4]Vec2 {
        const c = self.p1.subPoint(self.p0).mulScalar(3.0);
        const b = self.p2.subPoint(self.p1).mulScalar(3.0).sub(c);
        const d = self.p0.toVec2();
        const a = self.p3.toVec2().sub(d).sub(c).sub(b);
        return .{ a, b, c, d };
    }

    // --------------------------------------------------- ParamCurve surface

    /// Evaluate the curve at parameter `t`.
    pub inline fn eval(self: CubicBez, t: f64) Point {
        const mt = 1.0 - t;
        const v = self.p0.toVec2().mulScalar(mt * mt * mt).add(
            self.p1.toVec2().mulScalar(mt * mt * 3.0).add(
                self.p2.toVec2().mulScalar(mt * 3.0).add(self.p3.toVec2().mulScalar(t)).mulScalar(t),
            ).mulScalar(t),
        );
        return v.toPoint();
    }

    /// Get a subsegment of the curve for the given parameter range.
    pub fn subsegment(self: CubicBez, t0: f64, t1: f64) CubicBez {
        const p0 = self.eval(t0);
        const p3 = self.eval(t1);
        const d = self.deriv();
        const scale = (t1 - t0) * (1.0 / 3.0);
        const p1 = p0.addVec(d.eval(t0).toVec2().mulScalar(scale));
        const p2 = p3.subVec(d.eval(t1).toVec2().mulScalar(scale));
        return .{ .p0 = p0, .p1 = p1, .p2 = p2, .p3 = p3 };
    }

    /// Subdivide into halves, using de Casteljau.
    pub inline fn subdivide(self: CubicBez) struct { CubicBez, CubicBez } {
        const pm = self.eval(0.5);
        return .{
            CubicBez.new(
                self.p0,
                self.p0.midpoint(self.p1),
                self.p0.toVec2().add(self.p1.toVec2().mulScalar(2.0)).add(self.p2.toVec2()).mulScalar(0.25).toPoint(),
                pm,
            ),
            CubicBez.new(
                pm,
                self.p1.toVec2().add(self.p2.toVec2().mulScalar(2.0)).add(self.p3.toVec2()).mulScalar(0.25).toPoint(),
                self.p2.midpoint(self.p3),
                self.p3,
            ),
        };
    }

    /// The start point.
    pub inline fn start(self: CubicBez) Point {
        return self.p0;
    }

    /// The end point.
    pub inline fn end(self: CubicBez) Point {
        return self.p3;
    }

    /// The derivative of the curve, as a quadratic.
    pub inline fn deriv(self: CubicBez) QuadBez {
        return QuadBez.new(
            self.p1.subPoint(self.p0).mulScalar(3.0).toPoint(),
            self.p2.subPoint(self.p1).mulScalar(3.0).toPoint(),
            self.p3.subPoint(self.p2).mulScalar(3.0).toPoint(),
        );
    }

    /// Arclength of a cubic Bézier segment.
    ///
    /// This is an adaptive subdivision approach using Legendre-Gauss
    /// quadrature in the base case, and an error estimate to decide when to
    /// subdivide.
    pub fn arclen(self: CubicBez, accuracy: f64) f64 {
        return arclenRec(self, accuracy, 0);
    }

    /// Solve for the parameter that has the given arc length from the start.
    pub fn invArclen(self: CubicBez, target_arclen: f64, accuracy: f64) f64 {
        return common.invArclen(CubicBez, self, target_arclen, accuracy, subsegmentArclen);
    }

    fn subsegmentArclen(c: CubicBez, t0: f64, t1: f64, accuracy: f64) f64 {
        return c.subsegment(t0, t1).arclen(accuracy);
    }

    /// Compute the signed area under the curve.
    pub inline fn signedArea(self: CubicBez) f64 {
        return (self.p0.x * (6.0 * self.p1.y + 3.0 * self.p2.y + self.p3.y) +
            3.0 * (self.p1.x * (-2.0 * self.p0.y + self.p2.y + self.p3.y) -
                self.p2.x * (self.p0.y + self.p1.y - 2.0 * self.p3.y)) -
            self.p3.x * (self.p0.y + 3.0 * self.p1.y + 6.0 * self.p2.y)) * (1.0 / 20.0);
    }

    /// Find the nearest point using a quintic solver.
    ///
    /// The polynomial `|self - p|^2` has degree 6, so we find its critical
    /// points and evaluate them all to find the best one.
    pub fn nearest(self: CubicBez, p: Point, accuracy: f64) common.Nearest {
        var r_best: ?f64 = null;
        var t_best: f64 = 0.0;

        // Reparameterize `self - p` as q0 + q1 t + q2 t^2 + q3 t^3.
        const q0 = self.p0.subPoint(p);
        const q1 = self.p1.subPoint(self.p0).mulScalar(3.0);
        const q2 = self.p0.toVec2().sub(self.p1.toVec2().mulScalar(2.0)).add(self.p2.toVec2()).mulScalar(3.0);
        const q3 = self.p0.toVec2().neg().add(self.p1.toVec2().mulScalar(3.0))
            .sub(self.p2.toVec2().mulScalar(3.0)).add(self.p3.toVec2());

        // Coefficients of the degree-5 polynomial (self - p) dot tangent.
        const c0 = q0.dot(q1);
        const c1 = q1.hypot2() + 2.0 * q2.dot(q0);
        const c2 = 3.0 * (q2.dot(q1) + q3.dot(q0));
        const c3 = 4.0 * q3.dot(q1) + 2.0 * q2.hypot2();
        const c4 = 5.0 * q3.dot(q2);
        const c5 = 3.0 * q3.hypot2();

        const roots = common.rootsBetweenQuintic(
            .{ c0, c1, c2, c3, c4, c5 },
            0.0,
            1.0,
            accuracy,
        );

        for (roots.slice()) |t| {
            evalCubicT(p, &t_best, &r_best, t, self.eval(t));
        }

        // If we found all 5 critical points, we can skip evaluating the
        // endpoints.
        if (roots.len != 5) {
            evalCubicT(p, &t_best, &r_best, 0.0, self.p0);
            evalCubicT(p, &t_best, &r_best, 1.0, self.p3);
        }

        return .{ .t = t_best, .distance_sq = r_best.? };
    }

    /// Compute the extrema of the curve (at most four), in increasing
    /// parameter order. Only extrema within the interior of the curve count.
    pub fn extrema(self: CubicBez) common.SmallVec(f64, common.MAX_EXTREMA) {
        var result = common.SmallVec(f64, common.MAX_EXTREMA){};
        const d0 = self.p1.subPoint(self.p0);
        const d1 = self.p2.subPoint(self.p1);
        const d2 = self.p3.subPoint(self.p2);
        oneCoord(&result, d0.x, d1.x, d2.x);
        oneCoord(&result, d0.y, d1.y, d2.y);
        std.mem.sort(f64, result.sliceMut(), {}, std.sort.asc(f64));
        return result;
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Affine * CubicBez`.
    pub inline fn transform(self: CubicBez, affine: Affine) CubicBez {
        return .{
            .p0 = affine.transformPoint(self.p0),
            .p1 = affine.transformPoint(self.p1),
            .p2 = affine.transformPoint(self.p2),
            .p3 = affine.transformPoint(self.p3),
        };
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath` (`MoveTo p0`, `CurveTo p1 p2 p3`).
    pub fn toPath(self: CubicBez, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        _ = tolerance;
        var path = BezPath.init();
        errdefer path.deinit(allocator);
        try path.append(allocator, PathEl.moveTo(self.p0));
        try path.append(allocator, PathEl.curveTo(self.p1, self.p2, self.p3));
        return path;
    }

    /// The smallest rectangle that encloses the curve.
    pub fn boundingBox(self: CubicBez) Rect {
        var bbox = Rect.fromPoints(self.start(), self.end());
        const ext = self.extrema();
        for (ext.slice()) |t| {
            bbox = bbox.unionPt(self.eval(t));
        }
        return bbox;
    }

    /// The area under the curve is not defined for an open shape.
    pub inline fn area(self: CubicBez) f64 {
        _ = self;
        return 0.0;
    }

    /// Total length of perimeter (the curve's arclength).
    pub inline fn perimeter(self: CubicBez, accuracy: f64) f64 {
        return self.arclen(accuracy);
    }

    /// The winding number is not defined for an open shape.
    pub inline fn winding(self: CubicBez, pt: Point) i32 {
        _ = self;
        _ = pt;
        return 0;
    }

    /// Flatten this cubic into line segments.
    ///
    /// `callback(point)` is invoked for each generated subdivision point and
    /// finally for `p3`, matching the `CurveTo` branch of `bezpath.flatten`.
    /// `allocator` is used for the intermediate quadratic buffer and is not
    /// retained.
    pub fn flatten(self: CubicBez, tolerance: f64, allocator: std.mem.Allocator, ctx: anytype, callback: anytype) !void {
        if (!(tolerance > 0.0)) return error.InvalidTolerance;
        const sqrt_tol = @sqrt(tolerance);

        // Subdivide into quadratics, and estimate the number of subdivisions
        // required for each, summing to arrive at an estimate for the number
        // of subdivisions for the cubic. Also retain these parameters.
        const quads = try self.toQuads(tolerance * TO_QUAD_TOL, allocator);
        defer allocator.free(quads);
        const sqrt_remain_tol = sqrt_tol * @sqrt(1.0 - TO_QUAD_TOL);
        var sum: f64 = 0.0;
        const params = try allocator.alloc(quadbez.FlattenParams, quads.len);
        defer allocator.free(params);
        for (quads, 0..) |*tq, i| {
            params[i] = tq.quad.estimateSubdiv(sqrt_remain_tol);
            sum += params[i].val;
        }
        const n = common.ceilToUsizeMin1(0.5 * sum / sqrt_remain_tol);

        // Iterate through the quadratics, outputting the points of
        // subdivisions that fall within that quadratic.
        const step = sum / @as(f64, @floatFromInt(n));
        var i: usize = 1;
        var val_sum: f64 = 0.0;
        for (quads, 0..) |tq, qi| {
            var target = @as(f64, @floatFromInt(i)) * step;
            const recip_val = 1.0 / params[qi].val;
            while (target < val_sum + params[qi].val) {
                const u = (target - val_sum) * recip_val;
                const t = tq.quad.determineSubdivT(&params[qi], u);
                callback(ctx, tq.quad.eval(t));
                i += 1;
                if (i == n + 1) {
                    break;
                }
                target = @as(f64, @floatFromInt(i)) * step;
            }
            val_sum += params[qi].val;
        }
        callback(ctx, self.p3);
    }
};

fn evalCubicT(p: Point, t_best: *f64, r_best: *?f64, t: f64, p0: Point) void {
    const r = p0.subPoint(p).hypot2();
    if (r_best.* == null or r < r_best.*.?) {
        r_best.* = r;
        t_best.* = t;
    }
}

fn oneCoord(result: *common.SmallVec(f64, common.MAX_EXTREMA), d0: f64, d1: f64, d2: f64) void {
    const a = d0 - 2.0 * d1 + d2;
    const b = 2.0 * (d1 - d0);
    const c = d0;
    const roots = common.solveQuadratic(c, b, a);
    for (roots.slice()) |t| {
        if (t > 0.0 and t < 1.0) {
            result.push(t);
        }
    }
}

fn arclenQuadratureCore(coeffs: []const [2]f64, dm: Vec2, dm1: Vec2, dm2: Vec2) f64 {
    var sum: f64 = 0.0;
    for (coeffs) |coeff| {
        const wi = coeff[0];
        const xi = coeff[1];
        const d = dm.add(dm2.mulScalar(xi * xi));
        const dpx = d.add(dm1.mulScalar(xi)).hypot();
        const dmx = d.sub(dm1.mulScalar(xi)).hypot();
        sum += (@sqrt(2.25) * wi) * (dpx + dmx);
    }
    return sum;
}

fn arclenRec(c: CubicBez, accuracy: f64, depth: usize) f64 {
    const d03 = c.p3.subPoint(c.p0);
    const d01 = c.p1.subPoint(c.p0);
    const d12 = c.p2.subPoint(c.p1);
    const d23 = c.p3.subPoint(c.p2);
    const lp_lc = d01.hypot() + d12.hypot() + d23.hypot() - d03.hypot();
    const dd1 = d12.sub(d01);
    const dd2 = d23.sub(d12);
    // It might be faster to do direct multiplies; the data dependencies would
    // be shorter. The following values don't have the factor of 3 for first
    // derivative.
    const dm = d01.add(d23).mulScalar(0.25).add(d12.mulScalar(0.5)); // first derivative at midpoint
    const dm1 = dd2.add(dd1).mulScalar(0.5); // second derivative at midpoint
    const dm2 = dd2.sub(dd1).mulScalar(0.25); // 0.5 * third derivative at midpoint

    var est: f64 = 0.0;
    for (common.GAUSS_LEGENDRE_COEFFS_8) |coeff| {
        const wi = coeff[0];
        const xi = coeff[1];
        const d_norm2 = dm.add(dm1.mulScalar(xi)).add(dm2.mulScalar(xi * xi)).hypot2();
        const dd_norm2 = dm1.add(dm2.mulScalar(2.0 * xi)).hypot2();
        est += wi * (dd_norm2 / d_norm2);
    }
    const est_gauss8_error = @min(common.FloatFuncs.powi(est, 3) * 2.5e-6, 3e-2) * lp_lc;
    if (est_gauss8_error < accuracy) {
        return arclenQuadratureCore(common.GAUSS_LEGENDRE_COEFFS_8_HALF, dm, dm1, dm2);
    }
    const est_gauss16_error = @min(common.FloatFuncs.powi(est, 6) * 1.5e-11, 9e-3) * lp_lc;
    if (est_gauss16_error < accuracy) {
        return arclenQuadratureCore(common.GAUSS_LEGENDRE_COEFFS_16_HALF, dm, dm1, dm2);
    }
    const est_gauss24_error = @min(common.FloatFuncs.powi(est, 9) * 3.5e-16, 3.5e-3) * lp_lc;
    if (est_gauss24_error < accuracy or depth >= 20) {
        return arclenQuadratureCore(common.GAUSS_LEGENDRE_COEFFS_24_HALF, dm, dm1, dm2);
    }
    const sub = c.subdivide();
    return arclenRec(sub[0], accuracy * 0.5, depth + 1) + arclenRec(sub[1], accuracy * 0.5, depth + 1);
}

test "cubicbez deriv" {
    const testing = std.testing;
    // y = x^2
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0 / 3.0, 0.0),
        Point.new(2.0 / 3.0, 1.0 / 3.0),
        Point.new(1.0, 1.0),
    );
    const deriv = c.deriv();

    const n = 10;
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const delta = 1e-6;
        const p = c.eval(t);
        const p1 = c.eval(t + delta);
        const d_approx = p1.subPoint(p).mulScalar(1.0 / delta);
        const d = deriv.eval(t).toVec2();
        try testing.expect(d.sub(d_approx).hypot() < delta * 2.0);
    }
}

test "cubicbez arclen" {
    const testing = std.testing;
    // y = x^2
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0 / 3.0, 0.0),
        Point.new(2.0 / 3.0, 1.0 / 3.0),
        Point.new(1.0, 1.0),
    );
    const true_arclen = 0.5 * @sqrt(5.0) + 0.25 * @log(2.0 + @sqrt(5.0));
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const accuracy = std.math.pow(f64, 0.1, @floatFromInt(i));
        const err = c.arclen(accuracy) - true_arclen;
        try testing.expect(@abs(err) < accuracy);
    }
}

test "cubicbez inv_arclen" {
    const testing = std.testing;
    // y = x^2 / 100
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(100.0 / 3.0, 0.0),
        Point.new(200.0 / 3.0, 100.0 / 3.0),
        Point.new(100.0, 100.0),
    );
    const true_arclen = 100.0 * (0.5 * @sqrt(5.0) + 0.25 * @log(2.0 + @sqrt(5.0)));
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const accuracy = std.math.pow(f64, 0.1, @floatFromInt(i));
        const n = 10;
        var j: usize = 0;
        while (j <= n) : (j += 1) {
            const arc = @as(f64, @floatFromInt(j)) * (true_arclen / @as(f64, @floatFromInt(n)));
            const t = c.invArclen(arc, accuracy * 0.5);
            const actual_arc = c.subsegment(0.0, t).arclen(accuracy * 0.5);
            try testing.expect(@abs(arc - actual_arc) < accuracy);
        }
    }
    // corner case: user passes accuracy larger than total arc length
    {
        const accuracy = true_arclen * 1.1;
        const arc = true_arclen * 0.5;
        const t = c.invArclen(arc, accuracy);
        const actual_arc = c.subsegment(0.0, t).arclen(accuracy);
        try testing.expect(@abs(arc - actual_arc) < 2.0 * accuracy);
    }
}

test "cubicbez signed_area_linear" {
    const testing = std.testing;
    // y = 1 - x
    const c = CubicBez.new(
        Point.new(1.0, 0.0),
        Point.new(2.0 / 3.0, 1.0 / 3.0),
        Point.new(1.0 / 3.0, 2.0 / 3.0),
        Point.new(0.0, 1.0),
    );
    const epsilon = 1e-12;
    try testing.expect(@abs(c.transform(Affine.rotate(0.5)).signedArea() - 0.5) < epsilon);
    try testing.expect(@abs(c.transform(Affine.translate(Vec2.new(0.0, 1.0))).signedArea() - 1.0) < epsilon);
    try testing.expect(@abs(c.transform(Affine.translate(Vec2.new(1.0, 0.0))).signedArea() - 1.0) < epsilon);
}

test "cubicbez signed_area" {
    const testing = std.testing;
    // y = 1 - x^3
    const c = CubicBez.new(
        Point.new(1.0, 0.0),
        Point.new(2.0 / 3.0, 1.0),
        Point.new(1.0 / 3.0, 1.0),
        Point.new(0.0, 1.0),
    );
    const epsilon = 1e-12;
    try testing.expect(@abs(c.signedArea() - 0.75) < epsilon);
    try testing.expect(@abs(c.transform(Affine.rotate(0.5)).signedArea() - 0.75) < epsilon);
    try testing.expect(@abs(c.transform(Affine.translate(Vec2.new(0.0, 1.0))).signedArea() - 1.25) < epsilon);
    try testing.expect(@abs(c.transform(Affine.translate(Vec2.new(1.0, 0.0))).signedArea() - 1.25) < epsilon);
}

test "cubicbez nearest" {
    const testing = std.testing;
    const verify = struct {
        fn f(result: common.Nearest, expected: f64) !void {
            try std.testing.expect(@abs(result.t - expected) < 1e-6);
        }
    }.f;

    // y = x^3
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0 / 3.0, 0.0),
        Point.new(2.0 / 3.0, 0.0),
        Point.new(1.0, 1.0),
    );
    try verify(c.nearest(Point.new(0.1, 0.001), 1e-6), 0.1);
    try verify(c.nearest(Point.new(0.2, 0.008), 1e-6), 0.2);
    try verify(c.nearest(Point.new(0.3, 0.027), 1e-6), 0.3);
    try verify(c.nearest(Point.new(0.4, 0.064), 1e-6), 0.4);
    try verify(c.nearest(Point.new(0.5, 0.125), 1e-6), 0.5);
    try verify(c.nearest(Point.new(0.6, 0.216), 1e-6), 0.6);
    try verify(c.nearest(Point.new(0.7, 0.343), 1e-6), 0.7);
    try verify(c.nearest(Point.new(0.8, 0.512), 1e-6), 0.8);
    try verify(c.nearest(Point.new(0.9, 0.729), 1e-6), 0.9);
    try verify(c.nearest(Point.new(1.0, 1.0), 1e-6), 1.0);
    try verify(c.nearest(Point.new(1.1, 1.1), 1e-6), 1.0);
    try verify(c.nearest(Point.new(-0.1, 0.0), 1e-6), 0.0);
    const a = Affine.rotate(0.5);
    try verify(c.transform(a).nearest(a.transformPoint(Point.new(0.1, 0.001)), 1e-6), 0.1);

    // Here's a case that tripped up the old solver because the start is close
    // to degenerate and the end is actually degenerate; see kurbo #446.
    const curve = CubicBez.new(
        Point.new(461.0, 123.0),
        Point.new(460.99999999999994, 123.00000000000004),
        Point.new(111.0, 319.0),
        Point.new(111.0, 319.0),
    );
    const p = Point.new(282.0379003395483, 223.21877580985594);
    const eps = 0.0005;
    const nearest = curve.nearest(p, eps);
    const q = curve.eval(nearest.t);
    const r = curve.eval(0.5075474297354187);
    try testing.expect(q.subPoint(p).hypot() <= r.subPoint(p).hypot() + eps);
}

test "cubicbez degenerate_to_quads" {
    const testing = std.testing;
    const c = CubicBez.new(
        Point.new(0.0, 9.0),
        Point.new(6.0, 6.0),
        Point.new(12.0, 3.0),
        Point.new(18.0, 0.0),
    );
    const quads = try c.toQuads(1e-6, testing.allocator);
    defer testing.allocator.free(quads);
    try testing.expectEqual(@as(usize, 1), quads.len);
}

test "cubicbez extrema" {
    const testing = std.testing;
    // y = x^2
    const q = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(0.0, 1.0),
        Point.new(1.0, 1.0),
        Point.new(1.0, 0.0),
    );
    const extrema = q.extrema();
    try testing.expectEqual(@as(usize, 1), extrema.len);
    try testing.expect(@abs(extrema.get(0) - 0.5) < 1e-6);

    const q2 = CubicBez.new(
        Point.new(0.4, 0.5),
        Point.new(0.0, 1.0),
        Point.new(1.0, 0.0),
        Point.new(0.5, 0.4),
    );
    try testing.expectEqual(@as(usize, 4), q2.extrema().len);
}

test "cubicbez toquads" {
    const testing = std.testing;
    // y = x^3
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0 / 3.0, 0.0),
        Point.new(2.0 / 3.0, 0.0),
        Point.new(1.0, 1.0),
    );
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const accuracy = std.math.pow(f64, 0.1, @floatFromInt(i));
        const quads = try c.toQuads(accuracy, testing.allocator);
        defer testing.allocator.free(quads);
        for (quads) |tq| {
            const epsilon = 1e-12;
            try testing.expect(tq.quad.start().subPoint(c.eval(tq.t0)).hypot() < epsilon);
            try testing.expect(tq.quad.end().subPoint(c.eval(tq.t1)).hypot() < epsilon);
            const n = 4;
            var j: usize = 0;
            while (j <= n) : (j += 1) {
                const t = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(n));
                const p = tq.quad.eval(t);
                const err = @abs(p.y - p.x * p.x * p.x);
                try testing.expect(err < accuracy);
            }
        }
    }
}

test "cubicbez inflections" {
    const testing = std.testing;
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(0.8, 1.0),
        Point.new(0.2, 1.0),
        Point.new(1.0, 0.0),
    );
    const inflections = c.inflections();
    try testing.expectEqual(@as(usize, 2), inflections.len);
    try testing.expect(@abs(inflections.get(0) - 0.311018) < 1e-6);
    try testing.expect(@abs(inflections.get(1) - 0.688982) < 1e-6);

    const c2 = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0, 1.0),
        Point.new(2.0, -1.0),
        Point.new(3.0, 0.0),
    );
    const inflections2 = c2.inflections();
    try testing.expectEqual(@as(usize, 1), inflections2.len);
    try testing.expect(@abs(inflections2.get(0) - 0.5) < 1e-6);

    const c3 = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0, 1.0),
        Point.new(2.0, 1.0),
        Point.new(3.0, 0.0),
    );
    try testing.expectEqual(@as(usize, 0), c3.inflections().len);
}

test "cubicbez tangents_to_point" {
    const testing = std.testing;
    // y = x^3
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0 / 3.0, 0.0),
        Point.new(2.0 / 3.0, 0.0),
        Point.new(1.0, 1.0),
    );

    // For this probe point the quartic has an interior root; the reported
    // parameter's tangent line must pass through the point.
    const p = Point.new(2.0, 3.0);
    const roots = c.tangentsToPoint(p);
    try testing.expect(roots.len >= 1);
    var found = false;
    for (roots.slice()) |t| {
        try testing.expect(t >= 0.0 and t <= 1.0);
        const x = c.eval(t);
        const tangent = c.deriv().eval(t).toVec2();
        const cross = x.subPoint(p).cross(tangent);
        if (@abs(cross) < 1e-9) found = true;
    }
    try testing.expect(found);

    // A point with no real tangent from the curve is allowed to return
    // nothing; the call must still be well-defined.
    _ = c.tangentsToPoint(Point.new(0.0, 1.0));
}

test "cubicbez flatten" {
    const testing = std.testing;
    // y = x^3
    const c = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(1.0 / 3.0, 0.0),
        Point.new(2.0 / 3.0, 0.0),
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
    const tolerance = 0.01;
    try c.flatten(tolerance, testing.allocator, &ctx, Ctx.call);
    try testing.expect(ctx.points.items.len >= 1);
    try testing.expectEqualDeep(c.p3, ctx.points.items[ctx.points.items.len - 1]);

    // The polyline must stay within tolerance of the curve (sampled).
    var last = c.p0;
    for (ctx.points.items) |p| {
        const mid = last.midpoint(p);
        const nearest = c.nearest(mid, 1e-9);
        try testing.expect(@sqrt(nearest.distance_sq) <= tolerance + 1e-9);
        last = p;
    }
}
