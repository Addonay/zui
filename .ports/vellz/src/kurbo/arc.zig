//! Port of kurbo 0.13.1 `arc.rs` (Apache-2.0 OR MIT).
//!
//! A single elliptical arc segment plus its cubic-Bézier append iteration
//! (`append_iter`/`to_cubic_beziers`), the subset used by `stroke.zig`'s round
//! joins/caps and `expand.zig`'s round joins.
//!
//! Adaptations, following the conventions of the other files in this port:
//! - `Arc::to_cubic_beziers` takes an explicit allocator and appends to a
//!   `BezPath` after applying `transform`, the Zig counterpart of upstream's
//!   `FnMut(Point, Point, Point)` closure.
//! - Upstream's `f64` transcendentals (`sin_cos`, `tan`, `powf`) go through
//!   `common.FloatFuncs`, which delegates to the same libm operations.
//!
//! Omissions: the `Shape`/`ParamCurve` trait impls (`eval`, `subsegment`,
//! `path_elements`, ...) and `from_svg`; only the append machinery is ported.

const std = @import("std");
const common = @import("common.zig");
const bezpath = @import("bezpath.zig");
const Affine = @import("affine.zig").Affine;
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;

/// A single elliptical arc segment.
pub const Arc = struct {
    /// The arc's centre point.
    center: Point,
    /// The arc's radii, where the vector's x-component is the radius in the
    /// positive x direction after applying `x_rotation`.
    radii: Vec2,
    /// The start angle in radians.
    start_angle: f64,
    /// The angle between the start and end of the arc, in radians.
    sweep_angle: f64,
    /// How much the arc is rotated, in radians.
    x_rotation: f64,

    /// Create a new `Arc`.
    pub inline fn new(
        center: Point,
        radii: Vec2,
        start_angle: f64,
        sweep_angle: f64,
        x_rotation: f64,
    ) Arc {
        return .{
            .center = center,
            .radii = radii,
            .start_angle = start_angle,
            .sweep_angle = sweep_angle,
            .x_rotation = x_rotation,
        };
    }

    /// Returns a copy of this `Arc` in the opposite direction.
    ///
    /// The new `Arc` will sweep towards the original `Arc`s start angle.
    pub inline fn reversed(self: Arc) Arc {
        return .{
            .center = self.center,
            .radii = self.radii,
            .start_angle = self.start_angle + self.sweep_angle,
            .sweep_angle = -self.sweep_angle,
            .x_rotation = self.x_rotation,
        };
    }

    inline fn angleAt(self: Arc, t: f64) f64 {
        return self.start_angle + self.sweep_angle * t;
    }

    /// Create an iterator generating Bézier path elements.
    ///
    /// The generated elements can be appended to an existing Bezier path.
    pub fn appendIter(self: Arc, tolerance: f64) ArcAppendIter {
        const sign = common.FloatFuncs.signum(self.sweep_angle);
        const scaled_err = @max(self.radii.x, self.radii.y) / tolerance;
        // Number of subdivisions per ellipse based on error tolerance.
        // Note: this may slightly underestimate the error for quadrants.
        const n_err = @max(common.FloatFuncs.powf(1.1163 * scaled_err, 1.0 / 6.0), 3.999_999);
        const n_f = @ceil(n_err * @abs(self.sweep_angle) * (1.0 / (2.0 * std.math.pi)));
        const angle_step = self.sweep_angle / n_f;
        const n = common.castToUsize(n_f);
        const arm_len = (4.0 / 3.0) * common.FloatFuncs.tan(@abs(0.25 * angle_step)) * sign;
        const angle0 = self.start_angle;
        const p0 = sampleEllipse(self.radii, self.x_rotation, angle0);

        return .{
            .idx = 0,
            .center = self.center,
            .radii = self.radii,
            .x_rotation = self.x_rotation,
            .n = n,
            .arm_len = arm_len,
            .angle_step = angle_step,
            .p0 = p0,
            .angle0 = angle0,
        };
    }

    /// Converts this `Arc` into a series of cubic Bézier segments.
    ///
    /// Appends one `CurveTo` per segment to `out`, mapping the control points
    /// through `transform` first. Upstream's closure parameter becomes the
    /// caller-provided path.
    pub fn toCubicBeziers(
        self: Arc,
        allocator: std.mem.Allocator,
        out: *BezPath,
        tolerance: f64,
        transform: Affine,
    ) !void {
        var it = self.appendIter(tolerance);
        while (it.next()) |el| {
            switch (el) {
                .CurveTo => |c| try out.curveTo(
                    allocator,
                    transform.transformPoint(c.p1),
                    transform.transformPoint(c.p2),
                    transform.transformPoint(c.p3),
                ),
                else => {},
            }
        }
    }
};

/// Iterator over the cubic Bézier segments of an `Arc`; created by
/// `Arc.appendIter`.
pub const ArcAppendIter = struct {
    idx: usize,

    center: Point,
    radii: Vec2,
    x_rotation: f64,
    n: usize,
    arm_len: f64,
    angle_step: f64,

    p0: Vec2,
    angle0: f64,

    /// Returns the next `CurveTo` element, or `null` when the arc is done.
    pub fn next(self: *ArcAppendIter) ?PathEl {
        if (self.idx >= self.n) return null;

        const angle1 = self.angle0 + self.angle_step;
        const p0 = self.p0;
        const p1 = p0.add(sampleEllipse(
            self.radii,
            self.x_rotation,
            self.angle0 + std.math.pi / 2.0,
        ).mulScalar(self.arm_len));
        const p3 = sampleEllipse(self.radii, self.x_rotation, angle1);
        const p2 = p3.sub(sampleEllipse(
            self.radii,
            self.x_rotation,
            angle1 + std.math.pi / 2.0,
        ).mulScalar(self.arm_len));

        self.angle0 = angle1;
        self.p0 = p3;
        self.idx += 1;

        return PathEl.curveTo(
            self.center.addVec(p1),
            self.center.addVec(p2),
            self.center.addVec(p3),
        );
    }
};

/// Take the ellipse radii, how the radii are rotated, and the angle, and
/// return a point on the ellipse (upstream `sample_ellipse`).
fn sampleEllipse(radii: Vec2, x_rotation: f64, angle: f64) Vec2 {
    const sc = common.FloatFuncs.sinCos(angle);
    const angle_sin = sc[0];
    const angle_cos = sc[1];
    const u = radii.x * angle_cos;
    const v = radii.y * angle_sin;
    return rotatePt(Vec2.new(u, v), x_rotation);
}

/// Rotate `pt` about the origin by `angle` radians (upstream `rotate_pt`).
fn rotatePt(pt: Vec2, angle: f64) Vec2 {
    const sc = common.FloatFuncs.sinCos(angle);
    const angle_sin = sc[0];
    const angle_cos = sc[1];
    return Vec2.new(
        pt.x * angle_cos - pt.y * angle_sin,
        pt.x * angle_sin + pt.y * angle_cos,
    );
}

// --------------------------------------------------------------------- tests
const testing = std.testing;

test "arc full circle appends cubics that close" {
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    const arc = Arc.new(Point.new(10.0, 20.0), Vec2.new(5.0, 5.0), 0.0, 2.0 * std.math.pi, 0.0);
    try arc.toCubicBeziers(testing.allocator, &path, 1e-3, Affine.IDENTITY);
    try testing.expect(path.elementsSlice().len >= 4);
    for (path.elementsSlice()) |el| {
        try testing.expect(std.meta.activeTag(el) == .CurveTo);
    }
    // Last control point closes back on the start point.
    const last = path.elementsSlice()[path.elementsSlice().len - 1].CurveTo.p3;
    try testing.expect(@abs(last.x - 15.0) < 1e-9);
    try testing.expect(@abs(last.y - 20.0) < 1e-9);
}

test "arc quarter circle end lands on the x axis" {
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    const arc = Arc.new(Point.ORIGIN, Vec2.new(2.0, 3.0), 0.0, std.math.pi / 2.0, 0.0);
    try arc.toCubicBeziers(testing.allocator, &path, 1e-6, Affine.IDENTITY);
    const last = path.elementsSlice()[path.elementsSlice().len - 1].CurveTo.p3;
    try testing.expect(@abs(last.x - 0.0) < 1e-9);
    try testing.expect(@abs(last.y - 3.0) < 1e-9);
}
