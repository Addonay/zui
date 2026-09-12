//! Port of kurbo 0.13.1 `expand.rs` (Apache-2.0 OR MIT).
//!
//! Path expansion by dilation (`expand_path`/`expand_path_signed`) and the
//! `Diagonal2` anisotropic expansion matrix. `glifo` uses `expand_path` for
//! synthetic embolden: it draws the glyph outline, then dilates it so that the
//! result matches stroking the path with a width of `2 * expand` and filling
//! the original (nonzero rule).
//!
//! Adaptations, following the conventions of the other files in this port:
//! - `impl Shape` becomes a `[]const PathEl` input; callers pass
//!   `BezPath.elementsSlice()`. `close_subpaths` + `Segments::area` (the sign
//!   probe) is transcribed as `closedSubpathsArea`.
//! - Path building allocates, so the expansion functions return `!BezPath`
//!   with an explicit allocator; upstream aborts on allocation failure.
//! - The `Join::Round` arm uses the shared `arc.zig` port of
//!   `Arc::to_cubic_beziers`.
//!
//! Numerical order is preserved expression-for-expression; no operation is
//! reordered, reassociated, or replaced (in particular `Vec2 / f64` keeps
//! upstream's multiply-by-reciprocal behavior and `f64::max` NaN semantics).

const std = @import("std");
const arc_mod = @import("arc.zig");
const bezpath = @import("bezpath.zig");
const stroke = @import("stroke.zig");
const common = @import("common.zig");
const Affine = @import("affine.zig").Affine;
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const QuadBez = @import("quadbez.zig").QuadBez;
const CubicBez = @import("cubicbez.zig").CubicBez;
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;
const PathSeg = bezpath.PathSeg;
const Join = stroke.Join;

/// A diagonal matrix, suitable for representing anisotropic scaling.
pub const Diagonal2 = struct {
    /// The horizontal expansion factor.
    xx: f64,
    /// The vertical expansion factor.
    yy: f64,

    /// Create a diagonal matrix.
    pub inline fn new(xx: f64, yy: f64) Diagonal2 {
        return .{ .xx = xx, .yy = yy };
    }

    /// Matrix inverse.
    ///
    /// Will of course produce infinities if a component is zero.
    pub fn inv(self: Diagonal2) Diagonal2 {
        return new(1.0 / self.xx, 1.0 / self.yy);
    }

    /// Absolute value of transform components.
    pub fn abs(self: Diagonal2) Diagonal2 {
        return new(@abs(self.xx), @abs(self.yy));
    }

    /// Scale a normal vector.
    ///
    /// This is mathematically equivalent to `self * (self * n).normalize()`
    /// for positive transforms, but handles zeros and gets the sign correct
    /// when negative.
    ///
    /// Note that `n` need not be unit length.
    pub fn scaleNormal(self: Diagonal2, n: Vec2) Vec2 {
        const z = self.mulVec(n);
        const z_hypot2 = z.hypot2();
        if (z_hypot2 == 0.0) {
            return Vec2.ZERO;
        }
        const inv_scale = 1.0 / @sqrt(z_hypot2);
        return self.abs().mulVec(z).mulScalar(inv_scale);
    }

    /// Upstream unary `-Diagonal2`.
    pub fn neg(self: Diagonal2) Diagonal2 {
        return new(-self.xx, -self.yy);
    }

    /// Upstream `Diagonal2 * Vec2`.
    pub fn mulVec(self: Diagonal2, rhs: Vec2) Vec2 {
        return Vec2.new(self.xx * rhs.x, self.yy * rhs.y);
    }

    /// Upstream `Diagonal2 * Point`.
    pub fn mulPoint(self: Diagonal2, rhs: Point) Point {
        return Point.new(self.xx * rhs.x, self.yy * rhs.y);
    }
};

const ExpandCtx = struct {
    expand: Diagonal2,
    join: Join,
    miter_limit: f64,
    tolerance: f64,
    result: BezPath,
    first_n: ?Vec2,
    first_tan: Vec2,
    last_pt: Point,
    last_n: ?Vec2,
    last_tan: Vec2,
    allocator: std.mem.Allocator,

    /// Helper function to determine if a distance is within tolerance.
    fn inTolerance(self: *const ExpandCtx, v: Vec2) bool {
        return v.hypot2() < self.tolerance * self.tolerance;
    }

    /// Process a line segment. Includes initial join.
    fn doLine(self: *ExpandCtx, p1: Point) !void {
        if (p1.x == self.last_pt.x and p1.y == self.last_pt.y) {
            return;
        }
        const tan = p1.subPoint(self.last_pt);
        const n = self.expand.scaleNormal(tan.turn90());
        try self.doJoin(n, tan, true);
        const out_p1 = p1.addVec(n);
        try self.result.lineTo(self.allocator, out_p1);
        self.last_n = n;
        self.last_tan = tan;
        self.last_pt = p1;
    }

    /// Process a quadratic Bézier segment. Includes initial join.
    fn doQuad(self: *ExpandCtx, p1: Point, p2: Point) !void {
        const q0 = p1.subPoint(self.last_pt);
        const q1 = p2.subPoint(p1);
        if (self.inTolerance(q0) or self.inTolerance(q1)) {
            try self.doLine(p2);
            return;
        }
        const einv = self.expand.inv();
        const utan0 = einv.mulVec(q0).normalize();
        const utan1 = einv.mulVec(q1).normalize();
        const det = utan1.cross(utan0);
        if (@abs(det) < 1e-10) {
            try self.doLine(p2);
            return;
        }
        const utanm = einv.mulVec(p2.subPoint(self.last_pt)).normalize();
        const n0 = self.expand.abs().mulVec(utan0.turn90());
        const n1 = self.expand.abs().mulVec(utan1.turn90());
        const mid_chord = self.last_pt.midpoint(p2);
        const m = mid_chord.midpoint(p1).addVec(
            self.expand.abs().mulVec(utanm.turn90()),
        );
        const out_p0 = self.last_pt.addVec(n0);
        const out_p3 = p2.addVec(n1);
        const rhs = einv.mulVec(m.subPoint(out_p0.midpoint(out_p3)));
        const idet = (8.0 / 3.0) / det;
        const a = @max(utan1.cross(rhs) * idet, 0.0);
        const b = @max(utan0.cross(rhs) * idet, 0.0);
        try self.doJoin(n0, q0, false);
        const out_p1 = out_p0.addVec(self.expand.mulVec(utan0.mulScalar(a)));
        const out_p2 = out_p3.subVec(self.expand.mulVec(utan1.mulScalar(b)));
        try self.result.curveTo(self.allocator, out_p1, out_p2, out_p3);
        self.last_n = n1;
        self.last_tan = q1;
        self.last_pt = p2;
    }

    /// Process a cubic segment. Includes initial join.
    fn doCubic(self: *ExpandCtx, p1: Point, p2: Point, p3: Point) !void {
        const einv = self.expand.inv();
        const c = CubicBez.new(
            einv.mulPoint(self.last_pt),
            einv.mulPoint(p1),
            einv.mulPoint(p2),
            einv.mulPoint(p3),
        );
        const tangents = (PathSeg{ .Cubic = c }).tangents();
        const tan0 = tangents[0];
        const tan1 = tangents[1];
        const utan0 = tan0.normalize();
        const utan1 = tan1.normalize();
        const q = c.deriv();
        const p1xp0 = q.p1.toVec2().cross(q.p0.toVec2());
        const p2xp1 = q.p2.toVec2().cross(q.p1.toVec2());
        const cx = CubicCtx{ .q = q, .utan0 = utan0, .utan1 = utan1 };
        // First we try one-point, but only if there isn't one inflection point.
        var soln = if (p1xp0 * p2xp1 >= 0.0) tryOnePoint(&cx) else null;
        if (soln == null) {
            // We try two-point linear if we don't have a one-point solution. A
            // more sophisticated approach would be to evaluate error and pick a
            // minimum, but that would be more complexity and take time. This is
            // very likely good enough for the purpose.
            soln = twoPointLinear(&cx);
        }
        if (soln) |ab| {
            const n0 = self.expand.abs().mulVec(utan0.turn90());
            const n1 = self.expand.abs().mulVec(utan1.turn90());
            try self.doJoin(n0, self.expand.mulVec(utan0), false);
            const out_p3 = p3.addVec(n1);
            // TODO: clamp to correct direction
            const out_p1 = p1.addVec(n0).addVec(
                self.expand.abs().mulVec(utan0.mulScalar(ab[0])),
            );
            const out_p2 = p2.addVec(n1).addVec(
                self.expand.abs().mulVec(utan1.mulScalar(ab[1])),
            );
            try self.result.curveTo(self.allocator, out_p1, out_p2, out_p3);
            self.last_n = n1;
            self.last_tan = self.expand.mulVec(utan1);
            self.last_pt = p3;
        } else {
            try self.doLine(p3);
        }
    }

    /// Do a join.
    ///
    /// The `tan` parameter is a vector tangent to the start of the new segment.
    /// The `n` parameter is the normal vector (turned tangent) scaled by the
    /// expansion.
    fn doJoin(self: *ExpandCtx, n: Vec2, tan: Vec2, is_line: bool) !void {
        // TODO: other join types etc
        if (self.last_n) |last_n| {
            const p = self.last_pt.addVec(n);
            if (!self.inTolerance(n.sub(last_n))) {
                if (self.join != .bevel) {
                    const cross = self.last_tan.cross(tan);
                    if (cross * self.expand.xx < 0.0) {
                        switch (self.join) {
                            .bevel => unreachable,
                            .miter => {
                                const dot = self.last_tan.dot(tan);
                                const hypot = common.FloatFuncs.hypot(cross, dot);
                                if (2.0 * hypot < (hypot + dot) *
                                    self.miter_limit * self.miter_limit)
                                {
                                    const h = n.sub(last_n).cross(tan) /
                                        self.last_tan.cross(tan);
                                    const miter_pt = self.last_pt.addVec(last_n).addVec(
                                        self.last_tan.mulScalar(h),
                                    );
                                    // A cheap optimization to reduce line segments
                                    // with joins to lines
                                    const elements = self.result.elementsMut();
                                    if (elements.len > 0 and
                                        std.meta.activeTag(elements[elements.len - 1]) == .LineTo)
                                    {
                                        elements[elements.len - 1].LineTo = miter_pt;
                                    } else {
                                        try self.result.lineTo(self.allocator, miter_pt);
                                    }
                                    if (is_line) return;
                                }
                            },
                            .round => {
                                // Cheaper inverse; everything is normalized so
                                // we don't care about uniform scaling.
                                const einv = Diagonal2.new(self.expand.yy, self.expand.xx);
                                const last_tann = einv.mulVec(self.last_tan);
                                const tann = einv.mulVec(tan);
                                const crossn = last_tann.cross(tann);
                                const dotn = last_tann.dot(tann);
                                const angle = @abs(common.FloatFuncs.atan2(crossn, dotn));
                                const nt = self.expand.mulVec(tann.normalize());
                                const a = Affine.new(.{
                                    n.x,
                                    n.y,
                                    nt.x,
                                    nt.y,
                                    self.last_pt.x,
                                    self.last_pt.y,
                                });
                                const arc = arc_mod.Arc.new(
                                    Point.ORIGIN,
                                    Vec2.new(1.0, 1.0),
                                    -angle,
                                    angle,
                                    0.0,
                                );
                                const tolerance = self.tolerance / @max(
                                    @abs(einv.xx),
                                    @abs(einv.yy),
                                );
                                try arc.toCubicBeziers(
                                    self.allocator,
                                    &self.result,
                                    tolerance,
                                    a,
                                );
                                return;
                            },
                        }
                    }
                }
                // Bevel case
                try self.result.lineTo(self.allocator, p);
            }
        } else {
            try self.result.moveTo(self.allocator, self.last_pt.addVec(n));
            self.first_n = n;
            self.first_tan = tan;
        }
    }

    /// Close an open subpath if there is one; no-op if already closed.
    fn doClosePath(self: *ExpandCtx, first_pt: Point) !void {
        if (self.first_n) |first_n| {
            self.first_n = null;
            // could do this test inside do_line for all lines, but it already
            // checks for 0-length
            if (first_pt.distanceSquared(self.last_pt) > self.tolerance * self.tolerance) {
                try self.doLine(first_pt);
            }
            try self.doJoin(first_n, self.first_tan, true);
            try self.result.closePath(self.allocator);
        }
        self.last_n = null;
    }
};

const CubicCtx = struct {
    q: QuadBez,
    utan0: Vec2,
    utan1: Vec2,
};

const TwoPointSample = struct {
    a_n: f64,
    b_n: f64,
    c_n: f64,
};

// Note: here is our own copy of sophisticated cubic Bézier offset logic. We
// have the ability to apply anisotropic expansion, but not cusp detection or
// subdivision, and I've also stripped out all the error evaluation. At some
// point, we want to redo stroking, and there may be an opportunity to share
// code.

/// Try to compute one-point shape control for a cubic.
///
/// Result is `(a, b)` parameters.
fn tryOnePoint(cx: *const CubicCtx) ?[2]f64 {
    // TODO: possibly reduce duplication with quadratic case.
    const tan = cx.q.eval(0.5).toVec2();
    const tan_hypot2 = tan.hypot2();
    if (tan_hypot2 < 1e-12) {
        return null;
    }
    // Upstream `tan / tan_hypot2.sqrt()`; `Vec2 / f64` is multiply-by-reciprocal.
    const utan = tan.divScalar(@sqrt(tan_hypot2));
    const z = utan.sub(utan0plus1(cx).mulScalar(0.5)).turn90();
    const cross = cx.utan0.cross(cx.utan1);
    if (@abs(cross) < 1e-12) {
        return null;
    }
    const idet = (8.0 / 3.0) / cross;
    const a = z.cross(cx.utan1) * idet;
    const b = cx.utan0.cross(z) * idet;
    //let delta_tan = 0.75 * (b * cx.utan1 - a * cx.utan0) + 1.5 * (cx.utan1 - cx.utan0).turn_90();
    //let angle_err = delta_tan.cross(utan);
    //let err_est = 0.16 * angle_err.abs();
    return .{ a, b };
}

/// Upstream `0.5 * (cx.utan0 + cx.utan1)`; preserved as a helper so the
/// parenthesization stays visible at the call site.
inline fn utan0plus1(cx: *const CubicCtx) Vec2 {
    return cx.utan0.add(cx.utan1);
}

fn twoPointLinear(cx: *const CubicCtx) ?[2]f64 {
    const T0: f64 = 0.35;
    var s: [2]TwoPointSample = undefined;
    for ([2]f64{ T0, 1.0 - T0 }, 0..) |t, i| {
        const utan = cx.q.eval(t).toVec2().normalize();
        const n = utan.turn90();
        const utan0_n = cx.utan0.dot(n);
        const utan1_n = cx.utan1.dot(n);
        const utan0xn = cx.utan0.dot(utan);
        const utan1xn = cx.utan1.dot(utan);
        const mt = 1.0 - t;
        const b0 = mt * mt * mt;
        const b1 = 3.0 * mt * t * mt;
        const b2 = 3.0 * mt * t * t;
        const b3 = t * t * t;
        const a_n = b1 * utan0_n;
        const b_n = b2 * utan1_n;
        const c_n = (b0 + b1) * utan0xn + (b2 + b3) * utan1xn - 1.0;
        s[i] = .{ .a_n = a_n, .b_n = b_n, .c_n = c_n };
    }
    const det = s[0].a_n * s[1].b_n - s[1].a_n * s[0].b_n;
    // Consider both near-zero and NaN determinants to be failures.
    if (!(@abs(det) > 1e-12)) {
        return null;
    }
    const idet = -1.0 / det;
    const a = idet * (s[0].c_n * s[1].b_n - s[1].c_n * s[0].b_n);
    const b = idet * (s[0].a_n * s[1].c_n - s[1].a_n * s[0].c_n);
    return .{ a, b };
}

/// Expand a path.
///
/// Expands a filled path by the expansion, which allows separate x and y
/// factors. The path (and the result) is interpreted according to the nonzero
/// winding rule. Both factors should be positive. A negative expansion will
/// shrink the path but is also likely to leave intersection artifacts at
/// corners.
///
/// The direction of the expansion is based on the signed area of the overall
/// path. This should give expected results most of the time, but there are
/// exceptions. For a figure-eight path, one lobe will be expanded and the other
/// shrunk. Similarly if there are two disjoint subpaths with opposite winding.
///
/// The tolerance is mostly for joins and robustness; it is not used to guide
/// subdivision. Rather, each Bézier segment in the input generally results in
/// one cubic Bézier in the output. Thus, it is not expected to work well when
/// the expansion factor is large compared with the radius of curvature on the
/// input.
pub fn expandPath(
    allocator: std.mem.Allocator,
    elements: []const PathEl,
    expand_in: Diagonal2,
    join: Join,
    miter_limit: f64,
    tolerance: f64,
) !BezPath {
    var expand = expand_in;
    if (try closedSubpathsArea(allocator, elements) >= 0.0) {
        expand = expand.neg();
    }
    return expandPathSigned(allocator, elements, expand, join, miter_limit, tolerance);
}

/// Expand a path when the sign is known.
///
/// Applies the expansion based on the path orientation, so that expansion
/// happens with positive `expand` values on subpaths with negative area, or
/// vice versa. This is backwards from the intuitive sign convention, but
/// results from the choice of convention for the offset primitives.
pub fn expandPathSigned(
    allocator: std.mem.Allocator,
    elements: []const PathEl,
    expand: Diagonal2,
    join: Join,
    miter_limit: f64,
    tolerance: f64,
) !BezPath {
    var ctx = ExpandCtx{
        .expand = expand,
        .join = join,
        .miter_limit = miter_limit,
        .tolerance = tolerance,
        .result = BezPath.init(),
        .first_n = null,
        .first_tan = Vec2.ZERO,
        .last_pt = Point.ZERO,
        .last_n = null,
        .last_tan = Vec2.ZERO,
        .allocator = allocator,
    };
    errdefer ctx.result.deinit(allocator);
    var first_pt = Point.ZERO;
    for (elements) |el| {
        switch (el) {
            .MoveTo => |point| {
                try ctx.doClosePath(first_pt);
                first_pt = point;
                ctx.last_pt = point;
            },
            .LineTo => |p1| try ctx.doLine(p1),
            .QuadTo => |q| try ctx.doQuad(q.p1, q.p2),
            .CurveTo => |c| try ctx.doCubic(c.p1, c.p2, c.p3),
            .ClosePath => try ctx.doClosePath(first_pt),
        }
    }
    // Treat all subpaths as closed; close if left open in input.
    try ctx.doClosePath(first_pt);
    return ctx.result;
}

const CloseSubpathState = enum {
    start,
    in_subpath,
    closed_last,
    pending_move_to,
};

/// Signed area of the path with every open subpath implicitly closed.
///
/// Port of upstream `segments(close_subpaths(path_elements)).area()`: the
/// `CloseSubpaths` iterator state machine materializes the same element stream
/// (inserting `ClosePath` before a `MoveTo` mid-path and at the end), then
/// sums `PathSeg.signedArea` in order so the floating-point summation order
/// matches.
fn closedSubpathsArea(
    allocator: std.mem.Allocator,
    elements: []const PathEl,
) !f64 {
    var closed: std.ArrayList(PathEl) = .empty;
    defer closed.deinit(allocator);

    var state: CloseSubpathState = .start;
    var pending: Point = Point.ZERO;
    var i: usize = 0;
    while (true) {
        switch (state) {
            .start => {
                if (i >= elements.len) break;
                const el = elements[i];
                i += 1;
                if (std.meta.activeTag(el) != .ClosePath) {
                    state = .in_subpath;
                }
                try closed.append(allocator, el);
            },
            .in_subpath => {
                if (i >= elements.len) {
                    state = .closed_last;
                    try closed.append(allocator, PathEl.closePath());
                    continue;
                }
                const el = elements[i];
                i += 1;
                switch (el) {
                    .MoveTo => |point| {
                        state = .pending_move_to;
                        pending = point;
                        try closed.append(allocator, PathEl.closePath());
                    },
                    .ClosePath => {
                        state = .start;
                        try closed.append(allocator, el);
                    },
                    else => try closed.append(allocator, el),
                }
            },
            .closed_last => break,
            .pending_move_to => {
                state = .start;
                try closed.append(allocator, PathEl.moveTo(pending));
            },
        }
    }

    var result: f64 = 0.0;
    var it = bezpath.segments(closed.items);
    while (it.next()) |seg| {
        result += seg.signedArea();
    }
    return result;
}

// --------------------------------------------------------------------- tests
const testing = std.testing;
const Rect = @import("rect.zig").Rect;

test "expand rect miter/bevel/round areas match upstream" {
    // Ported from upstream `expand_rect`.
    const center = Point.new(100.0, 100.0);
    const size = @import("size.zig").Size.new(30.0, 20.0);
    const rect = Rect.fromCenterSize(center, size);
    var path = try rect.toPath(1e-3, testing.allocator);
    defer path.deinit(testing.allocator);
    const expand = Diagonal2.new(10.0, 10.0);

    const mitered = try expandPath(
        testing.allocator,
        path.elementsSlice(),
        expand,
        .miter,
        4.0,
        1e-3,
    );
    defer {
        var m = mitered;
        m.deinit(testing.allocator);
    }
    const expected_area_mitered =
        (size.width + 2.0 * expand.xx) * (size.height + 2.0 * expand.yy);
    try testing.expect(@abs(mitered.area() - expected_area_mitered) < 1e-9);

    const beveled = try expandPath(
        testing.allocator,
        path.elementsSlice(),
        expand,
        .bevel,
        4.0,
        1e-3,
    );
    defer {
        var b = beveled;
        b.deinit(testing.allocator);
    }
    const expected_area_beveled = expected_area_mitered - 2.0 * expand.xx * expand.yy;
    try testing.expect(@abs(beveled.area() - expected_area_beveled) < 1e-9);

    const rounded = try expandPath(
        testing.allocator,
        path.elementsSlice(),
        expand,
        .round,
        4.0,
        0.1,
    );
    defer {
        var r = rounded;
        r.deinit(testing.allocator);
    }
    const expected_area_rounded = expected_area_mitered -
        (4.0 - std.math.pi) * expand.xx * expand.yy;
    try testing.expect(@abs(rounded.area() - expected_area_rounded) < 1e-1);
}

test "expand closes an open subpath" {
    // Ported from upstream `assert_expand_subpath_closed`.
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    try path.moveTo(testing.allocator, Point.new(0.0, 0.0));
    try path.lineTo(testing.allocator, Point.new(100.0, 0.0));
    try path.lineTo(testing.allocator, Point.new(100.0, 100.0));
    try path.lineTo(testing.allocator, Point.new(0.0, 100.0));

    var expanded = try expandPath(
        testing.allocator,
        path.elementsSlice(),
        Diagonal2.new(10.0, 10.0),
        .miter,
        4.0,
        1e-3,
    );
    defer expanded.deinit(testing.allocator);
    const last = expanded.elementsSlice()[expanded.elementsSlice().len - 1];
    try testing.expectEqual(PathEl.ClosePath, last);
}

test "expand degenerate input is empty" {
    // Ported from upstream `expand_degenerate_input`.
    const path = try bezpath.fromSvg(testing.allocator, "M0,0 C0,0 0,0 0,0 Z");
    var p = path;
    defer p.deinit(testing.allocator);
    var expanded = try expandPath(
        testing.allocator,
        p.elementsSlice(),
        Diagonal2.new(10.0, 10.0),
        .miter,
        4.0,
        1e-3,
    );
    defer expanded.deinit(testing.allocator);
    try testing.expect(expanded.elementsSlice().len == 0);
}

test "expand open and closed subpaths agree" {
    // Ported from upstream `expand_open_subpath_uses_implicit_close_for_area_sign`.
    var open = BezPath.init();
    defer open.deinit(testing.allocator);
    try open.moveTo(testing.allocator, Point.new(100.0, 100.0));
    try open.lineTo(testing.allocator, Point.new(110.0, 100.0));
    try open.lineTo(testing.allocator, Point.new(100.0, 110.0));

    var closed = BezPath.init();
    defer closed.deinit(testing.allocator);
    try closed.moveTo(testing.allocator, Point.new(100.0, 100.0));
    try closed.lineTo(testing.allocator, Point.new(110.0, 100.0));
    try closed.lineTo(testing.allocator, Point.new(100.0, 110.0));
    try closed.closePath(testing.allocator);

    const expand = Diagonal2.new(1.0, 1.0);
    var open_expanded = try expandPath(
        testing.allocator,
        open.elementsSlice(),
        expand,
        .miter,
        4.0,
        1e-3,
    );
    defer open_expanded.deinit(testing.allocator);
    var closed_expanded = try expandPath(
        testing.allocator,
        closed.elementsSlice(),
        expand,
        .miter,
        4.0,
        1e-3,
    );
    defer closed_expanded.deinit(testing.allocator);

    try testing.expectEqualSlices(
        PathEl,
        closed_expanded.elementsSlice(),
        open_expanded.elementsSlice(),
    );
}

test "expand glyph shape matches upstream measurements" {
    // Ported from upstream `expand_glyph_shape` (moments omitted; this port
    // does not have `ParamCurveMoments`). WARNING: upstream marks this test
    // fragile; the area/perimeter goldens are from a known-good build.
    const path = try bezpath.fromSvg(
        testing.allocator,
        "M10.359375,-0.359375 Q6.484375,-0.359375 4.0625,2.1875 Q1.640625,4.734375 1.640625,8.984375 " ++
            "L1.640625,9.578125 Q1.640625,12.40625 2.71875,14.625 Q3.796875,16.859375 5.734375,18.109375 " ++
            "Q7.6875,19.375 9.953125,19.375 Q13.65625,19.375 15.703125,16.921875 Q17.765625,14.484375 17.765625,9.9375 " ++
            "L17.765625,8.578125 L4.890625,8.578125 Q4.953125,5.765625 6.53125,4.03125 Q8.109375,2.296875 10.53125,2.296875 " ++
            "Q12.25,2.296875 13.4375,3 Q14.640625,3.703125 15.546875,4.875 L17.53125,3.328125 Q15.140625,-0.359375 10.359375,-0.359375 Z " ++
            "M9.953125,16.703125 Q7.984375,16.703125 6.640625,15.265625 Q5.3125,13.828125 5,11.25 L14.515625,11.25 L14.515625,11.5 " ++
            "Q14.375,13.96875 13.171875,15.328125 Q11.984375,16.703125 9.953125,16.703125 Z",
    );
    var p = path;
    defer p.deinit(testing.allocator);
    var expanded = try expandPath(
        testing.allocator,
        p.elementsSlice(),
        Diagonal2.new(1.5, 1.0),
        .round,
        4.0,
        0.1,
    );
    defer expanded.deinit(testing.allocator);
    const expected_area: f64 = -291.3217958410297;
    const expected_perimeter: f64 = 120.89147879578239;
    try testing.expect(@abs(expanded.area() - expected_area) < 1e-3);
    try testing.expect(@abs(expanded.perimeter(1e-9) - expected_perimeter) < 1e-3);
}
