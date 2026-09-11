//! Port of kurbo 0.13.1 `bezpath.rs` (Apache-2.0 OR MIT).
//!
//! `BezPath` owns a heap-allocated array of `PathEl` (`std.ArrayList`, the
//! unmanaged flavor). Construct with `BezPath.init()`; every method that
//! grows the path takes an allocator, and `deinit(allocator)` releases the
//! storage. `clone`/`fromSvg`/`reverseSubpaths`/`toSvg` and shape `toPath`
//! return owned paths.
//!
//! Shape duck typing (upstream `impl Shape for BezPath`): `toPath(tolerance,
//! allocator)` clones, `boundingBox()`, `area()`, `perimeter(accuracy)`,
//! `winding(pt)`.
//!
//! Adaptations:
//! - `flatten` and `toQuads` allocate where upstream uses an internal `Vec`
//!   scratch buffer; the allocator is explicit and temporary.
//! - The flatten callbacks take an explicit `ctx` plus a callback function
//!   (Zig has no closures): `callback(ctx, el_or_point)`.
//! - Zig error sets cannot carry the offending character, so
//!   `svg.SvgParseError.UnknownCommand` has no payload (upstream
//!   `UnknownCommand(char)`).
//!
//! Omissions: `MinDistance`/`min_dist` (needs the upstream `mindist` module),
//! `close_subpaths` (upstream `pub(crate)`), and the `TranslateScale`
//! transform operators (that type is out of scope).

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;
const Affine = @import("affine.zig").Affine;
const line_mod = @import("line.zig");
const Line = line_mod.Line;
const quadbez = @import("quadbez.zig");
const QuadBez = quadbez.QuadBez;
const cubicbez = @import("cubicbez.zig");
const CubicBez = cubicbez.CubicBez;

/// Alias so `BezPath.segments` can call the free function of the same name.
const segmentsOf = segments;

/// The element of a Bézier path.
///
/// A valid path has `MoveTo` at the beginning of each subpath.
pub const PathEl = union(enum) {
    /// Move directly to the point without drawing anything, starting a new
    /// subpath.
    MoveTo: Point,
    /// Draw a line from the current location to the point.
    LineTo: Point,
    /// Draw a quadratic Bézier using the current location and the two points.
    QuadTo: QuadToPoints,
    /// Draw a cubic Bézier using the current location and the three points.
    CurveTo: CurveToPoints,
    /// Close off the path.
    ClosePath,

    /// Payload of `QuadTo`: control point and end point.
    pub const QuadToPoints = struct { p1: Point, p2: Point };
    /// Payload of `CurveTo`: two control points and the end point.
    pub const CurveToPoints = struct { p1: Point, p2: Point, p3: Point };

    pub inline fn moveTo(p: Point) PathEl {
        return .{ .MoveTo = p };
    }

    pub inline fn lineTo(p: Point) PathEl {
        return .{ .LineTo = p };
    }

    pub inline fn quadTo(p1: Point, p2: Point) PathEl {
        return .{ .QuadTo = .{ .p1 = p1, .p2 = p2 } };
    }

    pub inline fn curveTo(p1: Point, p2: Point, p3: Point) PathEl {
        return .{ .CurveTo = .{ .p1 = p1, .p2 = p2, .p3 = p3 } };
    }

    pub inline fn closePath() PathEl {
        return .ClosePath;
    }

    /// Is this path element finite?
    pub inline fn isFinite(self: PathEl) bool {
        return switch (self) {
            .MoveTo => |p| p.isFinite(),
            .LineTo => |p| p.isFinite(),
            .QuadTo => |q| q.p1.isFinite() and q.p2.isFinite(),
            .CurveTo => |c| c.p1.isFinite() and c.p2.isFinite() and c.p3.isFinite(),
            .ClosePath => true,
        };
    }

    /// Is this path element `NaN`?
    pub inline fn isNan(self: PathEl) bool {
        return switch (self) {
            .MoveTo => |p| p.isNan(),
            .LineTo => |p| p.isNan(),
            .QuadTo => |q| q.p1.isNan() or q.p2.isNan(),
            .CurveTo => |c| c.p1.isNan() or c.p2.isNan() or c.p3.isNan(),
            .ClosePath => false,
        };
    }

    /// Get the end point of the path element, if it exists.
    pub inline fn endPoint(self: PathEl) ?Point {
        return switch (self) {
            .MoveTo => |p| p,
            .LineTo => |p| p,
            .QuadTo => |q| q.p2,
            .CurveTo => |c| c.p3,
            .ClosePath => null,
        };
    }

    /// Upstream `Affine * PathEl`.
    pub inline fn transform(self: PathEl, affine: Affine) PathEl {
        return switch (self) {
            .MoveTo => |p| PathEl.moveTo(affine.transformPoint(p)),
            .LineTo => |p| PathEl.lineTo(affine.transformPoint(p)),
            .QuadTo => |q| PathEl.quadTo(affine.transformPoint(q.p1), affine.transformPoint(q.p2)),
            .CurveTo => |c| PathEl.curveTo(
                affine.transformPoint(c.p1),
                affine.transformPoint(c.p2),
                affine.transformPoint(c.p3),
            ),
            .ClosePath => .ClosePath,
        };
    }
};

/// A segment of a Bézier path.
pub const PathSeg = union(enum) {
    /// A line segment.
    Line: Line,
    /// A quadratic Bézier segment.
    Quad: QuadBez,
    /// A cubic Bézier segment.
    Cubic: CubicBez,

    /// Get the `PathEl` that is equivalent to discarding the segment start
    /// point.
    pub inline fn asPathEl(self: PathSeg) PathEl {
        return switch (self) {
            .Line => |l| PathEl.lineTo(l.p1),
            .Quad => |q| PathEl.quadTo(q.p1, q.p2),
            .Cubic => |c| PathEl.curveTo(c.p1, c.p2, c.p3),
        };
    }

    /// Returns a new `PathSeg` describing the same path as `self`, but with
    /// the points reversed.
    pub inline fn reverse(self: PathSeg) PathSeg {
        return switch (self) {
            .Line => |l| .{ .Line = Line.new(l.p1, l.p0) },
            .Quad => |q| .{ .Quad = QuadBez.new(q.p2, q.p1, q.p0) },
            .Cubic => |c| .{ .Cubic = CubicBez.new(c.p3, c.p2, c.p1, c.p0) },
        };
    }

    /// Convert this segment to a cubic Bézier.
    pub inline fn toCubic(self: PathSeg) CubicBez {
        return switch (self) {
            .Line => |l| CubicBez.new(l.p0, l.p0, l.p1, l.p1),
            .Cubic => |c| c,
            .Quad => |q| q.raise(),
        };
    }

    /// Is this segment finite?
    pub inline fn isFinite(self: PathSeg) bool {
        return switch (self) {
            .Line => |l| l.isFinite(),
            .Quad => |q| q.isFinite(),
            .Cubic => |c| c.isFinite(),
        };
    }

    /// Is this segment `NaN`?
    pub inline fn isNan(self: PathSeg) bool {
        return switch (self) {
            .Line => |l| l.isNan(),
            .Quad => |q| q.isNan(),
            .Cubic => |c| c.isNan(),
        };
    }

    /// Upstream `Affine * PathSeg`.
    pub inline fn transform(self: PathSeg, affine: Affine) PathSeg {
        return switch (self) {
            .Line => |l| .{ .Line = l.transform(affine) },
            .Quad => |q| .{ .Quad = q.transform(affine) },
            .Cubic => |c| .{ .Cubic = c.transform(affine) },
        };
    }

    // --------------------------------------------------- ParamCurve surface

    /// Evaluate the segment at parameter `t`.
    pub inline fn eval(self: PathSeg, t: f64) Point {
        return switch (self) {
            .Line => |l| l.eval(t),
            .Quad => |q| q.eval(t),
            .Cubic => |c| c.eval(t),
        };
    }

    /// Get a subsegment for the given parameter range.
    pub inline fn subsegment(self: PathSeg, t0: f64, t1: f64) PathSeg {
        return switch (self) {
            .Line => |l| .{ .Line = l.subsegment(t0, t1) },
            .Quad => |q| .{ .Quad = q.subsegment(t0, t1) },
            .Cubic => |c| .{ .Cubic = c.subsegment(t0, t1) },
        };
    }

    /// The start point.
    pub inline fn start(self: PathSeg) Point {
        return switch (self) {
            .Line => |l| l.start(),
            .Quad => |q| q.start(),
            .Cubic => |c| c.start(),
        };
    }

    /// The end point.
    pub inline fn end(self: PathSeg) Point {
        return switch (self) {
            .Line => |l| l.end(),
            .Quad => |q| q.end(),
            .Cubic => |c| c.end(),
        };
    }

    /// The arclength of the segment.
    pub inline fn arclen(self: PathSeg, accuracy: f64) f64 {
        return switch (self) {
            .Line => |l| l.arclen(accuracy),
            .Quad => |q| q.arclen(accuracy),
            .Cubic => |c| c.arclen(accuracy),
        };
    }

    /// Solve for the parameter that has the given arc length from the start.
    pub inline fn invArclen(self: PathSeg, target_arclen: f64, accuracy: f64) f64 {
        return switch (self) {
            .Line => |l| l.invArclen(target_arclen, accuracy),
            .Quad => |q| q.invArclen(target_arclen, accuracy),
            .Cubic => |c| c.invArclen(target_arclen, accuracy),
        };
    }

    /// Compute the signed area under the segment.
    pub inline fn signedArea(self: PathSeg) f64 {
        return switch (self) {
            .Line => |l| l.signedArea(),
            .Quad => |q| q.signedArea(),
            .Cubic => |c| c.signedArea(),
        };
    }

    /// Find the nearest position on the segment to the point.
    pub inline fn nearest(self: PathSeg, p: Point, accuracy: f64) common.Nearest {
        return switch (self) {
            .Line => |l| l.nearest(p, accuracy),
            .Quad => |q| q.nearest(p, accuracy),
            .Cubic => |c| c.nearest(p, accuracy),
        };
    }

    /// Compute the extrema of the segment.
    pub fn extrema(self: PathSeg) common.SmallVec(f64, common.MAX_EXTREMA) {
        return switch (self) {
            .Line => common.SmallVec(f64, common.MAX_EXTREMA){},
            .Quad => |q| q.extrema(),
            .Cubic => |c| c.extrema(),
        };
    }

    /// Return parameter ranges, each of which is monotonic within the range.
    pub fn extremaRanges(self: PathSeg) common.SmallVec([2]f64, common.MAX_EXTREMA + 1) {
        var result = common.SmallVec([2]f64, common.MAX_EXTREMA + 1){};
        var t0: f64 = 0.0;
        const ext = self.extrema();
        for (ext.slice()) |t| {
            result.push(.{ t0, t });
            t0 = t;
        }
        result.push(.{ t0, 1.0 });
        return result;
    }

    /// The smallest rectangle that encloses the segment.
    pub fn boundingBox(self: PathSeg) Rect {
        var bbox = Rect.fromPoints(self.start(), self.end());
        const ext = self.extrema();
        for (ext.slice()) |t| {
            bbox = bbox.unionPt(self.eval(t));
        }
        return bbox;
    }

    /// A single-segment "winding" number.
    ///
    /// Assume that `self` is monotonic in `y`, and take a ray pointing left
    /// from `p`. Handling of endpoints is subtle so that consecutive segments
    /// are counted consistently: `self` contains the endpoint with smaller y,
    /// and not the endpoint with larger y.
    fn windingInner(self: PathSeg, p: Point) i32 {
        const start_pt = self.start();
        const end_pt = self.end();
        const sign: i32 = blk: {
            if (end_pt.y > start_pt.y) {
                if (p.y < start_pt.y or p.y >= end_pt.y) {
                    return 0;
                }
                break :blk -1;
            } else if (end_pt.y < start_pt.y) {
                if (p.y < end_pt.y or p.y >= start_pt.y) {
                    return 0;
                }
                break :blk 1;
            } else {
                return 0;
            }
        };
        const sign_f: f64 = @floatFromInt(sign);
        switch (self) {
            .Line => {
                if (p.x < @min(start_pt.x, end_pt.x)) {
                    return 0;
                }
                if (p.x >= @max(start_pt.x, end_pt.x)) {
                    return sign;
                }
                // line equation ax + by = c
                const a = end_pt.y - start_pt.y;
                const b = start_pt.x - end_pt.x;
                const c = a * start_pt.x + b * start_pt.y;
                if ((a * p.x + b * p.y - c) * sign_f <= 0.0) {
                    return sign;
                }
                return 0;
            },
            .Quad => |quad| {
                const p1 = quad.p1;
                if (p.x < @min(@min(start_pt.x, end_pt.x), p1.x)) {
                    return 0;
                }
                if (p.x >= @max(@max(start_pt.x, end_pt.x), p1.x)) {
                    return sign;
                }
                const t = quad.solveMonotonicForY(p.y);
                const x = quad.eval(t).x;
                if (p.x >= x) {
                    return sign;
                }
                return 0;
            },
            .Cubic => |cubic| {
                const p1 = cubic.p1;
                const p2 = cubic.p2;
                if (p.x < @min(@min(@min(start_pt.x, end_pt.x), p1.x), p2.x)) {
                    return 0;
                }
                if (p.x >= @max(@max(@max(start_pt.x, end_pt.x), p1.x), p2.x)) {
                    return sign;
                }
                const t = cubic.solveMonotonicForY(p.y);
                const x = cubic.eval(t).x;
                if (p.x >= x) {
                    return sign;
                }
                return 0;
            },
        }
    }

    /// Compute the winding number contribution of a single segment.
    fn winding(self: PathSeg, p: Point) i32 {
        var total: i32 = 0;
        const ranges = self.extremaRanges();
        for (ranges.slice()) |range| {
            total += self.subsegment(range[0], range[1]).windingInner(p);
        }
        return total;
    }

    /// Compute intersections against a line.
    ///
    /// Returns the intersections, with the segment and line `t` values. This
    /// test is inclusive of points near the endpoints of the segment, so that
    /// testing a line against multiple contiguous segments of a path catches
    /// at least one of them.
    pub fn intersectLine(self: PathSeg, line: Line) common.SmallVec(LineIntersection, 3) {
        const EPSILON: f64 = 1e-9;
        const p0 = line.p0;
        const p1 = line.p1;
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        var result = common.SmallVec(LineIntersection, 3){};
        switch (self) {
            .Line => |l| {
                const det = dx * (l.p1.y - l.p0.y) - dy * (l.p1.x - l.p0.x);
                if (@abs(det) < EPSILON) {
                    // Lines are coincident (or nearly so).
                    return result;
                }
                const t = (dx * (p0.y - l.p0.y) - dy * (p0.x - l.p0.x)) / det;
                if (t >= -EPSILON and t <= 1.0 + EPSILON) {
                    // u = position on probe line
                    const u =
                        ((l.p0.x - p0.x) * (l.p1.y - l.p0.y) - (l.p0.y - p0.y) * (l.p1.x - l.p0.x)) / det;
                    if (u >= 0.0 and u <= 1.0) {
                        result.push(.{ .line_t = u, .segment_t = t });
                    }
                }
            },
            .Quad => |q| {
                // Determine x and y as a quadratic polynomial as a function of
                // t, then plug those values into the line equation for the
                // probe line and solve that for t.
                const px = quadraticBezCoefs(q.p0.x, q.p1.x, q.p2.x);
                const py = quadraticBezCoefs(q.p0.y, q.p1.y, q.p2.y);
                const c0 = dy * (px[0] - p0.x) - dx * (py[0] - p0.y);
                const c1 = dy * px[1] - dx * py[1];
                const c2 = dy * px[2] - dx * py[2];
                const invlen2 = 1.0 / (dx * dx + dy * dy);
                const roots = common.solveQuadratic(c0, c1, c2);
                for (roots.slice()) |t| {
                    if (t >= -EPSILON and t <= 1.0 + EPSILON) {
                        const x = px[0] + t * px[1] + t * t * px[2];
                        const y = py[0] + t * py[1] + t * t * py[2];
                        const u = ((x - p0.x) * dx + (y - p0.y) * dy) * invlen2;
                        if (u >= 0.0 and u <= 1.0) {
                            result.push(.{ .line_t = u, .segment_t = t });
                        }
                    }
                }
            },
            .Cubic => |c| {
                // Same technique as above, but a cubic polynomial.
                const px = cubicBezCoefs(c.p0.x, c.p1.x, c.p2.x, c.p3.x);
                const py = cubicBezCoefs(c.p0.y, c.p1.y, c.p2.y, c.p3.y);
                const c0 = dy * (px[0] - p0.x) - dx * (py[0] - p0.y);
                const c1 = dy * px[1] - dx * py[1];
                const c2 = dy * px[2] - dx * py[2];
                const c3 = dy * px[3] - dx * py[3];
                const invlen2 = 1.0 / (dx * dx + dy * dy);
                const roots = common.solveCubic(c0, c1, c2, c3);
                for (roots.slice()) |t| {
                    if (t >= -EPSILON and t <= 1.0 + EPSILON) {
                        const x = px[0] + t * px[1] + t * t * px[2] + t * t * t * px[3];
                        const y = py[0] + t * py[1] + t * t * py[2] + t * t * t * py[3];
                        const u = ((x - p0.x) * dx + (y - p0.y) * dy) * invlen2;
                        if (u >= 0.0 and u <= 1.0) {
                            result.push(.{ .line_t = u, .segment_t = t });
                        }
                    }
                }
            },
        }
        return result;
    }

    /// Compute endpoint tangents of a path segment.
    ///
    /// This version is robust to the path segment not being a regular curve.
    pub fn tangents(self: PathSeg) struct { Vec2, Vec2 } {
        const EPS: f64 = 1e-12;
        switch (self) {
            .Line => |l| {
                const d = l.p1.subPoint(l.p0);
                return .{ d, d };
            },
            .Quad => |q| {
                const d01 = q.p1.subPoint(q.p0);
                const d0 = if (d01.hypot2() > EPS) d01 else q.p2.subPoint(q.p0);
                const d12 = q.p2.subPoint(q.p1);
                const d1 = if (d12.hypot2() > EPS) d12 else q.p2.subPoint(q.p0);
                return .{ d0, d1 };
            },
            .Cubic => |c| {
                const d01 = c.p1.subPoint(c.p0);
                const d0 = if (d01.hypot2() > EPS) d01 else blk: {
                    const d02 = c.p2.subPoint(c.p0);
                    break :blk if (d02.hypot2() > EPS) d02 else c.p3.subPoint(c.p0);
                };
                const d23 = c.p3.subPoint(c.p2);
                const d1 = if (d23.hypot2() > EPS) d23 else blk: {
                    const d13 = c.p3.subPoint(c.p1);
                    break :blk if (d13.hypot2() > EPS) d13 else c.p3.subPoint(c.p0);
                };
                return .{ d0, d1 };
            },
        }
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath` (`MoveTo` start, then this segment's element).
    pub fn toPath(self: PathSeg, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        _ = tolerance;
        var path = BezPath.init();
        errdefer path.deinit(allocator);
        try path.append(allocator, PathEl.moveTo(self.start()));
        try path.append(allocator, self.asPathEl());
        return path;
    }

    /// The area under the curve.
    pub inline fn area(self: PathSeg) f64 {
        return self.signedArea();
    }

    /// Total length of perimeter (the segment's arclength).
    pub inline fn perimeter(self: PathSeg, accuracy: f64) f64 {
        return self.arclen(accuracy);
    }

    /// The winding number is not defined for an open segment.
    ///
    /// Adaptation: upstream's `impl Shape for PathSeg` defines `winding` as
    /// always zero while the inherent (private) `PathSeg::winding` computes
    /// the real per-segment contribution. Zig cannot have both names, so the
    /// inherent contribution is the public `winding` (used by
    /// `BezPath.winding`) and the always-zero shape method is this
    /// `shapeWinding`.
    pub inline fn shapeWinding(self: PathSeg, pt: Point) i32 {
        _ = self;
        _ = pt;
        return 0;
    }
};

/// An intersection of a `Line` and a `PathSeg`.
pub const LineIntersection = struct {
    /// The 'time' that the intersection occurs, on the line. In 0..1.
    line_t: f64,
    /// The 'time' that the intersection occurs, on the path segment.
    segment_t: f64,

    /// Is this line intersection finite?
    pub inline fn isFinite(self: LineIntersection) bool {
        return std.math.isFinite(self.line_t) and std.math.isFinite(self.segment_t);
    }

    /// Is this line intersection `NaN`?
    pub inline fn isNan(self: LineIntersection) bool {
        return std.math.isNan(self.line_t) or std.math.isNan(self.segment_t);
    }
};

/// Return polynomial coefficients given quadratic Bézier coordinates.
fn quadraticBezCoefs(x0: f64, x1: f64, x2: f64) [3]f64 {
    return .{ x0, 2.0 * x1 - 2.0 * x0, x2 - 2.0 * x1 + x0 };
}

/// Return polynomial coefficients given cubic Bézier coordinates.
fn cubicBezCoefs(x0: f64, x1: f64, x2: f64, x3: f64) [4]f64 {
    return .{
        x0,
        3.0 * x1 - 3.0 * x0,
        3.0 * x2 - 6.0 * x1 + 3.0 * x0,
        x3 - 3.0 * x2 + 3.0 * x1 - x0,
    };
}

/// A Bézier path.
///
/// These docs assume basic familiarity with Bézier curves; see Pomax's
/// "A Primer on Bézier Curves".
///
/// Conceptually, a `BezPath` contains zero or more subpaths. Each subpath
/// *always* begins with a `MoveTo`, then has zero or more `LineTo`, `QuadTo`,
/// and `CurveTo` elements, and optionally ends with a `ClosePath`.
pub const BezPath = struct {
    elements: std.ArrayList(PathEl) = .empty,

    /// Create a new, empty path. Does not allocate.
    pub inline fn init() BezPath {
        return .{};
    }

    /// Create a new, empty path with the specified capacity. Allocates with
    /// `allocator`; release with `deinit`.
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !BezPath {
        var path = BezPath.init();
        try path.elements.ensureTotalCapacity(allocator, capacity);
        return path;
    }

    /// Take ownership of an already-built element list.
    pub inline fn initOwned(elements: std.ArrayList(PathEl)) BezPath {
        return .{ .elements = elements };
    }

    /// Consume the path and return its element list.
    pub inline fn intoElements(self: BezPath) std.ArrayList(PathEl) {
        return self.elements;
    }

    /// Release the path's storage.
    pub fn deinit(self: *BezPath, allocator: std.mem.Allocator) void {
        self.elements.deinit(allocator);
        self.* = .{};
    }

    /// Create a deep copy of the path. Allocates with `allocator`; the caller
    /// owns the result.
    pub fn clone(self: *const BezPath, allocator: std.mem.Allocator) !BezPath {
        return .{ .elements = try self.elements.clone(allocator) };
    }

    /// Create a path that copies the given element slice. Allocating; the
    /// caller owns the result.
    pub fn fromElements(allocator: std.mem.Allocator, els: []const PathEl) !BezPath {
        var path = BezPath.init();
        errdefer path.deinit(allocator);
        try path.elements.appendSlice(allocator, els);
        return path;
    }

    /// Removes the last `PathEl` from the path and returns it, or `null` if
    /// the path is empty.
    pub fn pop(self: *BezPath) ?PathEl {
        return self.elements.pop();
    }

    /// Push a generic path element onto the path. Appends; allocates on
    /// capacity growth.
    pub fn append(self: *BezPath, allocator: std.mem.Allocator, el: PathEl) !void {
        try self.elements.append(allocator, el);
    }

    /// Push a "move to" element onto the path.
    pub fn moveTo(self: *BezPath, allocator: std.mem.Allocator, p: Point) !void {
        try self.append(allocator, PathEl.moveTo(p));
    }

    /// Push a "line to" element onto the path.
    pub fn lineTo(self: *BezPath, allocator: std.mem.Allocator, p: Point) !void {
        try self.append(allocator, PathEl.lineTo(p));
    }

    /// Push a "quad to" element onto the path.
    pub fn quadTo(self: *BezPath, allocator: std.mem.Allocator, p1: Point, p2: Point) !void {
        try self.append(allocator, PathEl.quadTo(p1, p2));
    }

    /// Push a "curve to" element onto the path.
    pub fn curveTo(self: *BezPath, allocator: std.mem.Allocator, p1: Point, p2: Point, p3: Point) !void {
        try self.append(allocator, PathEl.curveTo(p1, p2, p3));
    }

    /// Push a "close path" element onto the path.
    pub fn closePath(self: *BezPath, allocator: std.mem.Allocator) !void {
        try self.append(allocator, PathEl.closePath());
    }

    /// Get the path elements.
    pub inline fn elementsSlice(self: *const BezPath) []const PathEl {
        return self.elements.items;
    }

    /// Get the path elements (mutable).
    pub inline fn elementsMut(self: *BezPath) []PathEl {
        return self.elements.items;
    }

    /// Iterate over the path segments.
    pub inline fn segments(self: *const BezPath) Segments {
        return segmentsOf(self.elements.items);
    }

    /// Shorten the path, keeping the first `len` elements.
    pub fn truncate(self: *BezPath, len: usize) void {
        self.elements.shrinkRetainingCapacity(@min(len, self.elements.items.len));
    }

    /// Get the segment at the given element index.
    ///
    /// This returns the segment that ends at the provided element index. In
    /// effect it is *1-indexed*: since no segment ends at the first element
    /// (which is presumed to be a `MoveTo`) `getSeg(0)` always returns `null`.
    pub fn getSeg(self: *const BezPath, ix: usize) ?PathSeg {
        if (ix == 0 or ix >= self.elements.items.len) {
            return null;
        }
        const last = switch (self.elements.items[ix - 1]) {
            .MoveTo => |p| p,
            .LineTo => |p| p,
            .QuadTo => |q| q.p2,
            .CurveTo => |c| c.p3,
            .ClosePath => return null,
        };
        switch (self.elements.items[ix]) {
            .LineTo => |p| return .{ .Line = Line.new(last, p) },
            .QuadTo => |q| return .{ .Quad = QuadBez.new(last, q.p1, q.p2) },
            .CurveTo => |c| return .{ .Cubic = CubicBez.new(last, c.p1, c.p2, c.p3) },
            .ClosePath => {
                var i = ix;
                while (i > 0) {
                    i -= 1;
                    switch (self.elements.items[i]) {
                        .MoveTo => |start| {
                            if (start.x != last.x or start.y != last.y) {
                                return .{ .Line = Line.new(last, start) };
                            }
                        },
                        else => {},
                    }
                }
                return null;
            },
            .MoveTo => return null,
        }
    }

    /// Returns `true` if the path contains no segments.
    pub fn isEmpty(self: *const BezPath) bool {
        for (self.elements.items) |el| {
            switch (el) {
                .MoveTo, .ClosePath => {},
                else => return false,
            }
        }
        return true;
    }

    /// Apply an affine transform to the path.
    pub fn applyAffine(self: *BezPath, affine: Affine) void {
        for (self.elements.items) |*el| {
            el.* = el.transform(affine);
        }
    }

    /// Is this path finite?
    pub fn isFinite(self: *const BezPath) bool {
        for (self.elements.items) |el| {
            if (!el.isFinite()) return false;
        }
        return true;
    }

    /// Is this path `NaN`?
    pub fn isNan(self: *const BezPath) bool {
        for (self.elements.items) |el| {
            if (el.isNan()) return true;
        }
        return false;
    }

    /// Returns a rectangle that conservatively encloses the path.
    ///
    /// Unlike `boundingBox`, this uses control points directly rather than
    /// computing tight bounds for curve elements.
    pub fn controlBox(self: *const BezPath) Rect {
        var cbox: ?Rect = null;
        for (self.elements.items) |el| {
            switch (el) {
                .MoveTo => |p| cbox = addPt(cbox, p),
                .LineTo => |p| cbox = addPt(cbox, p),
                .QuadTo => |q| {
                    cbox = addPt(cbox, q.p1);
                    cbox = addPt(cbox, q.p2);
                },
                .CurveTo => |c| {
                    cbox = addPt(cbox, c.p1);
                    cbox = addPt(cbox, c.p2);
                    cbox = addPt(cbox, c.p3);
                },
                .ClosePath => {},
            }
        }
        return cbox orelse Rect.ZERO;
    }

    /// Returns the current position in the path, if the path is not empty.
    ///
    /// Unlike `PathEl.end_point` on the last entry, this handles `ClosePath`
    /// by finding the first point of the last subpath (O(n)).
    pub fn currentPosition(self: *const BezPath) ?Point {
        const last = if (self.elements.items.len == 0) return null else self.elements.items[self.elements.items.len - 1];
        switch (last) {
            .MoveTo => |p| return p,
            .LineTo => |p| return p,
            .QuadTo => |q| return q.p2,
            .CurveTo => |c| return c.p3,
            .ClosePath => {
                var first_of_subpath: ?PathEl = null;
                var i = self.elements.items.len - 1;
                while (i > 0) {
                    i -= 1;
                    const el = self.elements.items[i];
                    if (el == .ClosePath) break;
                    first_of_subpath = el;
                }
                if (first_of_subpath) |el| {
                    return el.endPoint();
                }
                return null;
            },
        }
    }

    /// Returns a new path with the winding direction of all subpaths reversed.
    ///
    /// Allocates with `allocator`; the caller owns the result.
    pub fn reverseSubpaths(self: *const BezPath, allocator: std.mem.Allocator) !BezPath {
        const els = self.elements.items;
        var reversed = BezPath.init();
        errdefer reversed.deinit(allocator);

        var start_ix: usize = 1;
        var start_pt = Point.ZERO;
        var pending_move = false;
        for (els, 0..) |el, ix| {
            switch (el) {
                .MoveTo => |pt| {
                    if (pending_move) {
                        try reversed.append(allocator, PathEl.moveTo(start_pt));
                    }
                    if (start_ix < ix) {
                        try reverseSubpath(allocator, start_pt, els[start_ix..ix], &reversed);
                    }
                    pending_move = true;
                    start_pt = pt;
                    start_ix = ix + 1;
                },
                .ClosePath => {
                    if (start_ix <= ix) {
                        try reverseSubpath(allocator, start_pt, els[start_ix..ix], &reversed);
                    }
                    try reversed.append(allocator, PathEl.closePath());
                    start_ix = ix + 1;
                    pending_move = false;
                },
                else => {
                    pending_move = false;
                },
            }
        }
        if (start_ix < els.len) {
            try reverseSubpath(allocator, start_pt, els[start_ix..], &reversed);
        } else if (pending_move) {
            try reversed.append(allocator, PathEl.moveTo(start_pt));
        }
        return reversed;
    }

    /// Returns an iterator over the subpaths of this path.
    ///
    /// Each yielded slice starts at a `MoveTo` and extends up to (but not
    /// including) the next `MoveTo`.
    pub inline fn subpaths(self: *const BezPath) Subpaths {
        return .{ .elements = self.elements.items };
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath` (a deep copy). Allocates with `allocator`.
    pub fn toPath(self: *const BezPath, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        _ = tolerance;
        return self.clone(allocator);
    }

    /// Signed area (meaningful only for closed paths).
    pub fn area(self: *const BezPath) f64 {
        return self.segments().area();
    }

    /// Total length of the perimeter.
    pub fn perimeter(self: *const BezPath, accuracy: f64) f64 {
        return self.segments().perimeter(accuracy);
    }

    /// Winding number of a point.
    pub fn winding(self: *const BezPath, pt: Point) i32 {
        return self.segments().winding(pt);
    }

    /// Returns `true` if the point is inside the path (non-zero rule).
    pub inline fn contains(self: *const BezPath, pt: Point) bool {
        return self.winding(pt) != 0;
    }

    /// The smallest rectangle that encloses the path.
    pub fn boundingBox(self: *const BezPath) Rect {
        return self.segments().boundingBox();
    }
};

fn addPt(cbox: ?Rect, p: Point) Rect {
    if (cbox) |box| {
        return box.unionPt(p);
    }
    return Rect.fromPoints(p, p);
}

/// An iterator over the subpaths of a `BezPath`; created by `BezPath.subpaths`.
pub const Subpaths = struct {
    elements: []const PathEl,
    i: usize = 0,

    /// Returns the next subpath slice, or `null` at the end.
    pub fn next(self: *Subpaths) ?[]const PathEl {
        if (self.i >= self.elements.len) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.elements.len and
            std.meta.activeTag(self.elements[self.i]) != .MoveTo)
        {
            self.i += 1;
        }
        return self.elements[start..self.i];
    }
};

/// Helper for `reverseSubpath`; `els` must not contain any `MoveTo` or
/// `ClosePath` elements.
fn reverseSubpath(
    allocator: std.mem.Allocator,
    start_pt: Point,
    els: []const PathEl,
    reversed: *BezPath,
) !void {
    var end_pt = start_pt;
    if (els.len > 0) {
        if (els[els.len - 1].endPoint()) |p| {
            end_pt = p;
        }
    }
    try reversed.append(allocator, PathEl.moveTo(end_pt));
    var i = els.len;
    while (i > 0) {
        i -= 1;
        const el = els[i];
        const e_pt = if (i > 0) els[i - 1].endPoint().? else start_pt;
        switch (el) {
            .LineTo => try reversed.append(allocator, PathEl.lineTo(e_pt)),
            .QuadTo => |c0| try reversed.append(allocator, PathEl.quadTo(c0.p1, e_pt)),
            .CurveTo => |c| try reversed.append(allocator, PathEl.curveTo(c.p2, c.p1, e_pt)),
            else => unreachable,
        }
    }
}

/// Transform an iterator over path elements into one over path segments.
pub fn segments(elements: []const PathEl) Segments {
    return .{ .elements = elements };
}

/// An iterator that transforms path elements to path segments.
pub const Segments = struct {
    elements: []const PathEl,
    ix: usize = 0,
    start: Point = Point.ZERO,
    last: Point = Point.ZERO,
    started: bool = false,

    /// Returns the next segment, or `null` at the end.
    ///
    /// Panics (Zig `unreachable`) if the element stream starts with a
    /// `ClosePath`, matching the upstream assertion.
    pub fn next(self: *Segments) ?PathSeg {
        while (self.ix < self.elements.len) {
            const el = self.elements[self.ix];
            self.ix += 1;
            if (!self.started) {
                switch (el) {
                    .MoveTo => |p| {
                        self.start = p;
                        self.last = p;
                    },
                    .LineTo => |p| {
                        self.start = p;
                        self.last = p;
                    },
                    .QuadTo => |q| {
                        self.start = q.p2;
                        self.last = q.p2;
                    },
                    .CurveTo => |c| {
                        self.start = c.p3;
                        self.last = c.p3;
                    },
                    .ClosePath => unreachable, // can't start a segment on a ClosePath
                }
                self.started = true;
            }

            switch (el) {
                .MoveTo => |p| {
                    self.start = p;
                    self.last = p;
                    continue;
                },
                .LineTo => |p| {
                    const seg: PathSeg = .{ .Line = Line.new(self.last, p) };
                    self.last = p;
                    return seg;
                },
                .QuadTo => |q| {
                    const seg: PathSeg = .{ .Quad = QuadBez.new(self.last, q.p1, q.p2) };
                    self.last = q.p2;
                    return seg;
                },
                .CurveTo => |c| {
                    const seg: PathSeg = .{ .Cubic = CubicBez.new(self.last, c.p1, c.p2, c.p3) };
                    self.last = c.p3;
                    return seg;
                },
                .ClosePath => {
                    if (self.last.x != self.start.x or self.last.y != self.start.y) {
                        const seg: PathSeg = .{ .Line = Line.new(self.last, self.start) };
                        self.last = self.start;
                        return seg;
                    }
                    continue;
                },
            }
        }
        return null;
    }

    /// Here, `accuracy` specifies the accuracy for each Bézier segment. At
    /// worst, the total error is `accuracy` times the number of segments.
    pub fn perimeter(self: Segments, accuracy: f64) f64 {
        var result: f64 = 0.0;
        var it = self;
        while (it.next()) |seg| {
            result += seg.arclen(accuracy);
        }
        return result;
    }

    /// The sum of signed areas of all segments.
    pub fn area(self: Segments) f64 {
        var result: f64 = 0.0;
        var it = self;
        while (it.next()) |seg| {
            result += seg.signedArea();
        }
        return result;
    }

    /// The sum of winding contributions of all segments.
    pub fn winding(self: Segments, p: Point) i32 {
        var result: i32 = 0;
        var it = self;
        while (it.next()) |seg| {
            result += seg.winding(p);
        }
        return result;
    }

    /// The smallest rectangle enclosing all segments.
    pub fn boundingBox(self: Segments) Rect {
        var bbox: ?Rect = null;
        var it = self;
        while (it.next()) |seg| {
            const seg_bb = seg.boundingBox();
            bbox = if (bbox) |bb| bb.unionWith(seg_bb) else seg_bb;
        }
        return bbox orelse Rect.ZERO;
    }
};

/// Flatten the path, invoking the callback repeatedly.
///
/// Flattening approximates curves with a succession of line segments. The
/// tolerance value controls the maximum distance between the curved input
/// segments and their polyline approximations.
///
/// The callback receives `PathEl` values (`MoveTo`, `LineTo` and
/// `ClosePath`); callbacks must return `void`. `allocator` is used for
/// temporary buffers only and is not retained.
///
/// This is a direct port of upstream's algorithm (quadratic Bézier
/// flattening from Raph Levien's blog post, extended to cubics by converting
/// them to quadratics first).
pub fn flatten(
    path: []const PathEl,
    tolerance: f64,
    allocator: std.mem.Allocator,
    ctx: anytype,
    callback: anytype,
) !void {
    if (!(tolerance > 0.0)) return error.InvalidTolerance;
    const sqrt_tol = @sqrt(tolerance);
    var last_pt: ?Point = null;
    for (path) |el| {
        switch (el) {
            .MoveTo => |p| {
                last_pt = p;
                callback(ctx, PathEl.moveTo(p));
            },
            .LineTo => |p| {
                last_pt = p;
                callback(ctx, PathEl.lineTo(p));
            },
            .QuadTo => |q| {
                if (last_pt) |p0| {
                    const quad = QuadBez.new(p0, q.p1, q.p2);
                    const params = quad.estimateSubdiv(sqrt_tol);
                    const n = common.ceilToUsizeMin1(0.5 * params.val / sqrt_tol);
                    const step = 1.0 / @as(f64, @floatFromInt(n));
                    var i: usize = 1;
                    while (i < n) : (i += 1) {
                        const u = @as(f64, @floatFromInt(i)) * step;
                        const t = quad.determineSubdivT(&params, u);
                        callback(ctx, PathEl.lineTo(quad.eval(t)));
                    }
                    callback(ctx, PathEl.lineTo(q.p2));
                }
                last_pt = q.p2;
            },
            .CurveTo => |c| {
                if (last_pt) |p0| {
                    const cubic = CubicBez.new(p0, c.p1, c.p2, c.p3);

                    // Subdivide into quadratics, and estimate the number of
                    // subdivisions required for each, summing to arrive at an
                    // estimate for the number of subdivisions for the cubic.
                    const quads = try cubic.toQuads(tolerance * cubicbez.TO_QUAD_TOL, allocator);
                    defer allocator.free(quads);
                    const sqrt_remain_tol = sqrt_tol * @sqrt(1.0 - cubicbez.TO_QUAD_TOL);
                    var sum: f64 = 0.0;
                    const params = try allocator.alloc(quadbez.FlattenParams, quads.len);
                    defer allocator.free(params);
                    for (quads, 0..) |tq, i| {
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
                            callback(ctx, PathEl.lineTo(tq.quad.eval(t)));
                            i += 1;
                            if (i == n + 1) {
                                break;
                            }
                            target = @as(f64, @floatFromInt(i)) * step;
                        }
                        val_sum += params[qi].val;
                    }
                    callback(ctx, PathEl.lineTo(c.p3));
                }
                last_pt = c.p3;
            },
            .ClosePath => {
                last_pt = null;
                callback(ctx, PathEl.closePath());
            },
        }
    }
}

/// Try to parse a path from an SVG path element.
///
/// `BezPath.fromSvg` equivalent; implemented in `svg.zig`.
pub fn fromSvg(allocator: std.mem.Allocator, data: []const u8) !BezPath {
    return @import("svg.zig").parseSvg(allocator, data);
}

// ------------------------------------------------------------------
// Tests (ported from bezpath.rs).
// ------------------------------------------------------------------

test "elements to segments closepath refers to last moveto" {
    const testing = std.testing;
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    try path.moveTo(testing.allocator, Point.new(5.0, 5.0));
    try path.lineTo(testing.allocator, Point.new(15.0, 15.0));
    try path.moveTo(testing.allocator, Point.new(10.0, 10.0));
    try path.lineTo(testing.allocator, Point.new(15.0, 15.0));
    try path.closePath(testing.allocator);

    var last: ?PathSeg = null;
    var it = path.segments();
    while (it.next()) |seg| {
        last = seg;
    }
    try testing.expect(last != null);
    switch (last.?) {
        .Line => |l| {
            try testing.expectEqualDeep(Point.new(15.0, 15.0), l.p0);
            try testing.expectEqualDeep(Point.new(10.0, 10.0), l.p1);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bezpath closepath-only path is empty" {
    const testing = std.testing;
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    try path.closePath(testing.allocator);
    // A lone ClosePath contains no segments (upstream's `Segments` iterator
    // asserts if asked to start on it; that panic case is a programming error
    // and is not exercised here).
    try testing.expect(path.isEmpty());
}

test "bezpath contains" {
    const testing = std.testing;
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    try path.moveTo(testing.allocator, Point.new(0.0, 0.0));
    try path.lineTo(testing.allocator, Point.new(1.0, 1.0));
    try path.lineTo(testing.allocator, Point.new(2.0, 0.0));
    try path.closePath(testing.allocator);
    try testing.expectEqual(@as(i32, -1), path.winding(Point.new(1.0, 0.5)));
    try testing.expect(path.contains(Point.new(1.0, 0.5)));
}

test "bezpath get_seg matches segments" {
    const testing = std.testing;
    const Circle = @import("circle.zig").Circle;
    var circle = Circle.new(Point.new(10.0, 10.0), 2.0);
    var path = try circle.toPath(common.DEFAULT_ACCURACY, testing.allocator);
    defer path.deinit(testing.allocator);

    var i: usize = 1;
    var it = path.segments();
    while (it.next()) |seg| : (i += 1) {
        const got = path.getSeg(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualDeep(seg, got);
    }
}

test "bezpath control_box" {
    const testing = std.testing;
    var path = try fromSvg(testing.allocator, "M200,300 C50,50 350,50 200,300");
    defer path.deinit(testing.allocator);
    try testing.expectEqualDeep(Rect.new(50.0, 50.0, 350.0, 300.0), path.controlBox());
    try testing.expect(path.controlBox().area() > path.boundingBox().area());
}

test "bezpath current_position" {
    const testing = std.testing;
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    try testing.expectEqual(@as(?Point, null), path.currentPosition());
    try path.moveTo(testing.allocator, Point.new(0.0, 0.0));
    try testing.expectEqualDeep(Point.new(0.0, 0.0), path.currentPosition().?);
    try path.lineTo(testing.allocator, Point.new(10.0, 10.0));
    try testing.expectEqualDeep(Point.new(10.0, 10.0), path.currentPosition().?);
    try path.lineTo(testing.allocator, Point.new(10.0, 0.0));
    try testing.expectEqualDeep(Point.new(10.0, 0.0), path.currentPosition().?);
    try path.closePath(testing.allocator);
    try testing.expectEqualDeep(Point.new(0.0, 0.0), path.currentPosition().?);

    try path.closePath(testing.allocator);
    try testing.expectEqual(@as(?Point, null), path.currentPosition());

    try path.moveTo(testing.allocator, Point.new(0.0, 10.0));
    try testing.expectEqualDeep(Point.new(0.0, 10.0), path.currentPosition().?);
    try path.closePath(testing.allocator);
    try testing.expectEqualDeep(Point.new(0.0, 10.0), path.currentPosition().?);
    try path.closePath(testing.allocator);
    try testing.expectEqual(@as(?Point, null), path.currentPosition());
}

test "bezpath winding_endpoints (kurbo #531)" {
    const testing = std.testing;
    var bez = BezPath.init();
    defer bez.deinit(testing.allocator);
    const a = testing.allocator;
    try bez.moveTo(a, Point.new(200.0, 410.0));
    try bez.curveTo(a, Point.new(139.0, 410.0), Point.new(90.0, 360.8772277832031), Point.new(90.0, 300.0));
    try bez.curveTo(a, Point.new(90.0, 239.0), Point.new(139.0, 190.0), Point.new(200.0, 190.0));
    try bez.curveTo(a, Point.new(150.0, 210.0), Point.new(110.0, 250.0), Point.new(110.0, 300.0));
    try bez.curveTo(a, Point.new(110.0, 349.0), Point.new(150.0, 390.0), Point.new(200.0, 390.0));
    try bez.closePath(a);

    try testing.expect(bez.contains(Point.new(100.0, 300.1)));
    try testing.expect(bez.contains(Point.new(100.0, 299.9)));
    try testing.expect(bez.contains(Point.new(100.0, 300.0)));
}

test "bezpath reverse_subpaths closed triangle" {
    const testing = std.testing;
    var path = try fromSvg(testing.allocator, "M100,100 L150,200 L50,200 Z");
    defer path.deinit(testing.allocator);
    var reversed = try path.reverseSubpaths(testing.allocator);
    defer reversed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), reversed.elementsSlice().len);
    try testing.expectEqualDeep(PathEl.moveTo(Point.new(50.0, 200.0)), reversed.elementsSlice()[0]);
    try testing.expectEqualDeep(PathEl.lineTo(Point.new(150.0, 200.0)), reversed.elementsSlice()[1]);
    try testing.expectEqualDeep(PathEl.lineTo(Point.new(100.0, 100.0)), reversed.elementsSlice()[2]);
    try testing.expectEqualDeep(PathEl.closePath(), reversed.elementsSlice()[3]);
}

test "bezpath intersect_line" {
    const testing = std.testing;
    const h_line = Line.new(Point.new(0.0, 0.0), Point.new(100.0, 0.0));
    {
        const v_line = Line.new(Point.new(10.0, -10.0), Point.new(10.0, 10.0));
        const intersections = (PathSeg{ .Line = h_line }).intersectLine(v_line);
        try testing.expectEqual(@as(usize, 1), intersections.len);
        try testing.expect(@abs(intersections.get(0).segment_t - 0.1) < 1e-8);
        try testing.expect(@abs(intersections.get(0).line_t - 0.5) < 1e-8);
    }
    {
        const v_line = Line.new(Point.new(-10.0, -10.0), Point.new(-10.0, 10.0));
        try testing.expectEqual(
            @as(usize, 0),
            (PathSeg{ .Line = h_line }).intersectLine(v_line).len,
        );
    }
    {
        const v_line = Line.new(Point.new(10.0, 10.0), Point.new(10.0, 20.0));
        try testing.expectEqual(
            @as(usize, 0),
            (PathSeg{ .Line = h_line }).intersectLine(v_line).len,
        );
    }
}

test "bezpath intersect_qad" {
    const testing = std.testing;
    const q = QuadBez.new(
        Point.new(0.0, -10.0),
        Point.new(10.0, 20.0),
        Point.new(20.0, -10.0),
    );
    {
        const v_line = Line.new(Point.new(10.0, -10.0), Point.new(10.0, 10.0));
        const intersections = (PathSeg{ .Quad = q }).intersectLine(v_line);
        try testing.expectEqual(@as(usize, 1), intersections.len);
        try testing.expect(@abs(intersections.get(0).segment_t - 0.5) < 1e-8);
        try testing.expect(@abs(intersections.get(0).line_t - 0.75) < 1e-8);
    }
    {
        const h_line = Line.new(Point.new(0.0, 0.0), Point.new(100.0, 0.0));
        try testing.expectEqual(@as(usize, 2), (PathSeg{ .Quad = q }).intersectLine(h_line).len);
    }
}

test "bezpath intersect_cubic" {
    const testing = std.testing;
    const c = CubicBez.new(
        Point.new(0.0, -10.0),
        Point.new(10.0, 20.0),
        Point.new(20.0, -20.0),
        Point.new(30.0, 10.0),
    );
    {
        const v_line = Line.new(Point.new(10.0, -10.0), Point.new(10.0, 10.0));
        const intersections = (PathSeg{ .Cubic = c }).intersectLine(v_line);
        try testing.expectEqual(@as(usize, 1), intersections.len);
        try testing.expect(@abs(intersections.get(0).segment_t - 0.333333333) < 1e-8);
        try testing.expect(@abs(intersections.get(0).line_t - 0.592592592) < 1e-8);
    }
    {
        const h_line = Line.new(Point.new(0.0, 0.0), Point.new(100.0, 0.0));
        try testing.expectEqual(@as(usize, 3), (PathSeg{ .Cubic = c }).intersectLine(h_line).len);
    }
}

test "bezpath subpaths" {
    const testing = std.testing;
    var path = try fromSvg(testing.allocator, "M10,10 L0,10 L0,0 L10,0 Z M100,100 M30,0 Q35,10,40,0 L30,0");
    defer path.deinit(testing.allocator);

    var it = path.subpaths();
    const sp1 = it.next().?;
    try testing.expectEqual(@as(usize, 5), sp1.len);
    const sp2 = it.next().?;
    try testing.expectEqual(@as(usize, 1), sp2.len);
    const sp3 = it.next().?;
    try testing.expectEqual(@as(usize, 3), sp3.len);
    try testing.expect(it.next() == null);
}

test "bezpath flatten" {
    const testing = std.testing;
    var path = BezPath.init();
    defer path.deinit(testing.allocator);
    try path.moveTo(testing.allocator, Point.new(0.0, 0.0));
    try path.quadTo(testing.allocator, Point.new(0.0, 0.5), Point.new(1.0, 1.0));
    try path.curveTo(
        testing.allocator,
        Point.new(1.5, 2.0),
        Point.new(2.5, 0.0),
        Point.new(3.0, 1.0),
    );

    const Ctx = struct {
        last: ?Point = null,
        first_after_move: ?Point = null,
        lines: usize = 0,
        closes: usize = 0,
        fn call(ctx: *@This(), el: PathEl) void {
            switch (el) {
                .MoveTo => |p| {
                    ctx.last = p;
                    ctx.first_after_move = p;
                },
                .LineTo => |p| {
                    ctx.lines += 1;
                    ctx.last = p;
                },
                .ClosePath => ctx.closes += 1,
                else => @panic("flatten emitted a curve"),
            }
        }
    };
    var ctx = Ctx{};
    try flatten(path.elementsSlice(), 0.1, testing.allocator, &ctx, Ctx.call);
    try testing.expect(ctx.lines > 2);
    try testing.expectEqualDeep(Point.new(3.0, 1.0), ctx.last.?);
}
