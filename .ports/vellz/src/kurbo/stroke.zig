//! Port of kurbo 0.13.1 stroke.rs (Apache-2.0 OR MIT).
//!
//! Stroke expansion: the style types (`Stroke`, `Join`, `Cap`, `Dashes`,
//! `StrokeOpts`), the reusable `StrokeCtx`, the `stroke`/`strokeWith` entry
//! points, joins/caps, and the dash iterator. The expansion algorithm,
//! tolerance behavior, and numerical detail mirror upstream exactly.
//!
//! Adaptations, following the conventions of the other files in this port:
//! - Zig has no closures or iterator traits. `stroke`/`strokeWith` take an
//!   explicit allocator and a `[]const PathEl`; `DashIterator` is generic over
//!   an inner type that exposes `next() ?PathEl`, and `dash`/`dashIter` accept
//!   a path slice and return `DashIterator(PathSliceIter)`.
//! - `StrokeCtx` owns all four upstream paths and exposes `deinit(allocator)`.
//!   Upstream's private field `output` is named `output_path` because Zig
//!   cannot declare a field and a method with the same name; `output()` has
//!   upstream's behavior.
//! - `Dashes` is `SmallVec<[f64; 4]>` upstream, which spills to the heap for
//!   patterns longer than four. `Stroke` remains a plain value here, so four
//!   entries is a hard capacity and `Stroke.withDashes` returns
//!   `error.DashPatternTooLong` rather than spilling (no silent truncation).
//! - Upstream `Stroke` derives `Clone`/`PartialEq`; Zig value semantics give
//!   the copy behavior, and `Stroke.eql` provides the comparison because Zig
//!   has no `==` for structs.
//! - `Arc`/`Arc::to_cubic_beziers` now live in `arc.zig` and are shared with
//!   `expand.zig`; `regularize_cusp`/`detect_cusp` (upstream `cubicbez.rs`,
//!   `pub(crate)`) remain ported privately below, as does `offset_cubic`
//!   (offset.rs). When `offset.zig` lands, `doCubic` should call it and the
//!   private copy here should go.
//! - `StrokeOptLevel.optimized` is accepted and stored exactly like upstream,
//!   where the current implementation ignores it (upstream doc comment).

const std = @import("std");

const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Affine = @import("affine.zig").Affine;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;
const PathSeg = bezpath.PathSeg;
const segments = bezpath.segments;
const Line = @import("line.zig").Line;
const QuadBez = @import("quadbez.zig").QuadBez;
const CubicBez = @import("cubicbez.zig").CubicBez;
const Arc = @import("arc.zig").Arc;

/// The number of dash lengths stored inline (upstream `SmallVec<[f64; 4]>`).
const dash_capacity = 4;

/// Point equality; Zig has no `==` for structs.
fn pointsEqual(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

// ---------------------------------------------------------------------------
// Style types
// ---------------------------------------------------------------------------

/// Defines the connection between two segments of a stroke.
///
/// Variant order matches upstream kurbo 0.13.1 (`Miter`, `Round`, `Bevel`);
/// numeric conversions (SVG, scene files, serialized settings) depend on it.
pub const Join = enum {
    /// The segments are extended to their natural intersection point.
    miter,
    /// An arc between the segments.
    round,
    /// A straight line connecting the segments.
    bevel,
};

/// Defines the shape to be drawn at the ends of a stroke.
///
/// Variant order matches upstream kurbo 0.13.1 (`Butt`, `Round`, `Square`).
pub const Cap = enum {
    /// Flat cap.
    butt,
    /// Rounded cap with radius equal to half the stroke width.
    round,
    /// Square cap with dimensions equal to half the stroke width.
    square,
};

/// Collection of values representing lengths in a dash pattern.
///
/// Upstream is `smallvec::SmallVec<[f64; 4]>`, which spills to the heap for
/// patterns longer than four entries. This port keeps the same inline storage
/// but has no allocator in `Stroke`, so the capacity is explicit: see
/// `Stroke.withDashes`.
pub const Dashes = common.SmallVec(f64, dash_capacity);

/// The visual style of a stroke.
pub const Stroke = struct {
    /// Width of the stroke.
    width: f64 = 1.0,
    /// Style for connecting segments of the stroke.
    join: Join = .round,
    /// Limit for miter joins.
    miter_limit: f64 = 4.0,
    /// Style for capping the beginning of an open subpath.
    start_cap: Cap = .round,
    /// Style for capping the end of an open subpath.
    end_cap: Cap = .round,
    /// Lengths of dashes in alternating on/off order.
    dash_pattern: Dashes = .{},
    /// Offset of the first dash.
    dash_offset: f64 = 0.0,

    /// Creates a new stroke with the specified width (upstream `new`).
    pub fn new(width: f64) Stroke {
        return .{ .width = width };
    }

    /// Builder method for setting the join style.
    pub fn withJoin(self: Stroke, join: Join) Stroke {
        var result = self;
        result.join = join;
        return result;
    }

    /// Builder method for setting the limit for miter joins.
    pub fn withMiterLimit(self: Stroke, limit: f64) Stroke {
        var result = self;
        result.miter_limit = limit;
        return result;
    }

    /// Builder method for setting the cap style for the start of the stroke.
    pub fn withStartCap(self: Stroke, cap: Cap) Stroke {
        var result = self;
        result.start_cap = cap;
        return result;
    }

    /// Builder method for setting the cap style for the end of the stroke.
    pub fn withEndCap(self: Stroke, cap: Cap) Stroke {
        var result = self;
        result.end_cap = cap;
        return result;
    }

    /// Builder method for setting the cap style.
    pub fn withCaps(self: Stroke, cap: Cap) Stroke {
        return self.withStartCap(cap).withEndCap(cap);
    }

    /// Builder method for setting the dashing parameters.
    ///
    /// The pattern is copied into the inline `Dashes` storage; upstream's
    /// `SmallVec<[f64; 4]>` would spill to the heap past four entries, which a
    /// plain value cannot do, so longer patterns are reported explicitly.
    pub fn withDashes(self: Stroke, offset: f64, pattern: []const f64) error{DashPatternTooLong}!Stroke {
        if (pattern.len > dash_capacity) return error.DashPatternTooLong;
        var result = self;
        result.dash_offset = offset;
        result.dash_pattern.clear();
        for (pattern) |d| result.dash_pattern.push(d);
        return result;
    }

    /// Returns `true` if all floating-point stroke parameters are finite.
    pub fn isFinite(self: *const Stroke) bool {
        if (!std.math.isFinite(self.width)) return false;
        if (!std.math.isFinite(self.miter_limit)) return false;
        if (!std.math.isFinite(self.dash_offset)) return false;
        for (self.dash_pattern.slice()) |d| {
            if (!std.math.isFinite(d)) return false;
        }
        return true;
    }

    /// Returns `true` if any floating-point stroke parameter is `NaN`.
    pub fn isNan(self: *const Stroke) bool {
        if (std.math.isNan(self.width)) return true;
        if (std.math.isNan(self.miter_limit)) return true;
        if (std.math.isNan(self.dash_offset)) return true;
        for (self.dash_pattern.slice()) |d| {
            if (std.math.isNan(d)) return true;
        }
        return false;
    }

    /// Value comparison (upstream derives `PartialEq`).
    ///
    /// Compares only the live portion of `dash_pattern`, so it is safe on
    /// values whose inline buffer is partially undefined.
    pub fn eql(self: *const Stroke, other: *const Stroke) bool {
        if (self.width != other.width) return false;
        if (self.join != other.join) return false;
        if (self.miter_limit != other.miter_limit) return false;
        if (self.start_cap != other.start_cap) return false;
        if (self.end_cap != other.end_cap) return false;
        if (self.dash_offset != other.dash_offset) return false;
        const a = self.dash_pattern.slice();
        const b = other.dash_pattern.slice();
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x != y) return false;
        }
        return true;
    }
};

/// Optimization level for computing stroke outlines.
///
/// Note that in the current implementation, this setting has no effect.
/// However, having a tradeoff between optimization of number of segments
/// and speed makes sense and may be added in the future, so applications
/// should set it appropriately.
pub const StrokeOptLevel = enum {
    /// Adaptively subdivide segments in half.
    subdivide,
    /// Compute optimized subdivision points to minimize error.
    optimized,
};

/// Options for path stroking.
pub const StrokeOpts = struct {
    opt_level: StrokeOptLevel = .subdivide,
    /// When `true`, dashes are emitted in the order they appear along the
    /// path. The default `false` delays a subpath's first dash so it can be
    /// merged with a dash that wraps through `ClosePath`; this option
    /// disables both the reorder and the wraparound merge, so a dash
    /// spanning the seam is truncated there.
    stable_dash_order: bool = false,

    /// Upstream `StrokeOpts::default()`.
    pub const default: StrokeOpts = .{};

    /// Set optimization level for computing stroke outlines.
    pub fn optLevel(self: StrokeOpts, opt_level: StrokeOptLevel) StrokeOpts {
        var opts = self;
        opts.opt_level = opt_level;
        return opts;
    }

    /// When `true`, dashes are emitted in the order they appear along the path.
    pub fn stableDashOrder(self: StrokeOpts, stable: bool) StrokeOpts {
        var opts = self;
        opts.stable_dash_order = stable;
        return opts;
    }
};

// ---------------------------------------------------------------------------
// Stroke context and entry points
// ---------------------------------------------------------------------------

/// A structure that is used for creating strokes.
///
/// See also `strokeWith`.
pub const StrokeCtx = struct {
    // As a possible future optimization, we might not need separate storage
    // for forward and backward paths, we can add forward to the output
    // in-place. However, this structure is clearer and the cost fairly modest.
    //
    // Upstream field `output` is `output_path` here because Zig cannot have a
    // field and a method with the same name; `output()` matches upstream.
    output_path: BezPath = .{},
    forward_path: BezPath = .{},
    backward_path: BezPath = .{},
    result_path: BezPath = .{},
    start_pt: Point = Point.ORIGIN,
    start_norm: Vec2 = Vec2.ZERO,
    start_tan: Vec2 = Vec2.ZERO,
    last_pt: Point = Point.ORIGIN,
    last_tan: Vec2 = Vec2.ZERO,
    // Precomputation of the join threshold, to optimize per-join logic.
    // If hypot < (hypot + dot) * join_thresh, omit join altogether.
    join_thresh: f64 = 0.0,

    /// Upstream `StrokeCtx::default()`.
    pub const default: StrokeCtx = .{};

    /// Create an empty context; no allocation happens until a stroke is
    /// expanded into it.
    pub fn init() StrokeCtx {
        return .{};
    }

    /// Release all storage owned by the context.
    pub fn deinit(self: *StrokeCtx, allocator: std.mem.Allocator) void {
        self.output_path.deinit(allocator);
        self.forward_path.deinit(allocator);
        self.backward_path.deinit(allocator);
        self.result_path.deinit(allocator);
        self.* = .{};
    }

    /// Return the path that defines the expanded stroke.
    pub fn output(self: *const StrokeCtx) *const BezPath {
        return &self.output_path;
    }

    fn reset(self: *StrokeCtx) void {
        self.output_path.truncate(0);
        self.forward_path.truncate(0);
        self.backward_path.truncate(0);
        self.start_pt = Point.ORIGIN;
        self.start_norm = Vec2.ZERO;
        self.start_tan = Vec2.ZERO;
        self.last_pt = Point.ORIGIN;
        self.last_tan = Vec2.ZERO;
        self.join_thresh = 0.0;
    }

    /// Append forward and backward paths to output.
    fn finish(self: *StrokeCtx, allocator: std.mem.Allocator, style: *const Stroke) !void {
        // TODO: scale
        const tolerance = 1e-3;
        if (self.forward_path.elements.items.len == 0) return;
        try self.output_path.elements.appendSlice(allocator, self.forward_path.elements.items);
        const back_els = self.backward_path.elements.items;
        const return_p = back_els[back_els.len - 1].endPoint().?;
        const d = self.last_pt.subPoint(return_p);
        switch (style.end_cap) {
            .butt => try self.output_path.lineTo(allocator, return_p),
            .round => try roundCap(allocator, &self.output_path, tolerance, self.last_pt, d),
            .square => try squareCap(allocator, &self.output_path, false, self.last_pt, d),
        }
        try extendReversed(allocator, &self.output_path, back_els);
        switch (style.start_cap) {
            .butt => try self.output_path.closePath(allocator),
            .round => try roundCap(allocator, &self.output_path, tolerance, self.start_pt, self.start_norm),
            .square => try squareCap(allocator, &self.output_path, true, self.start_pt, self.start_norm),
        }

        self.forward_path.truncate(0);
        self.backward_path.truncate(0);
    }

    /// Finish a closed path.
    fn finishClosed(self: *StrokeCtx, allocator: std.mem.Allocator, style: *const Stroke) !void {
        if (self.forward_path.elements.items.len == 0) return;
        try self.doJoin(allocator, style, self.start_tan);
        try self.output_path.elements.appendSlice(allocator, self.forward_path.elements.items);
        try self.output_path.closePath(allocator);
        const back_els = self.backward_path.elements.items;
        const last_pt = back_els[back_els.len - 1].endPoint().?;
        try self.output_path.moveTo(allocator, last_pt);
        try extendReversed(allocator, &self.output_path, back_els);
        try self.output_path.closePath(allocator);
        self.forward_path.truncate(0);
        self.backward_path.truncate(0);
    }

    fn doJoin(self: *StrokeCtx, allocator: std.mem.Allocator, style: *const Stroke, tan0: Vec2) !void {
        // TODO: scale
        const tolerance = 1e-3;
        const scale = 0.5 * style.width / tan0.hypot();
        const norm = Vec2.new(-tan0.y, tan0.x).mulScalar(scale);
        const p0 = self.last_pt;
        if (self.forward_path.elements.items.len == 0) {
            try self.forward_path.moveTo(allocator, p0.subVec(norm));
            try self.backward_path.moveTo(allocator, p0.addVec(norm));
            self.start_tan = tan0;
            self.start_norm = norm;
        } else {
            const ab = self.last_tan;
            const cd = tan0;
            const cross = ab.cross(cd);
            const dot = ab.dot(cd);
            const hypot = common.FloatFuncs.hypot(cross, dot);
            // possible TODO: a minor speedup could be squaring both sides
            if (dot <= 0.0 or @abs(cross) >= hypot * self.join_thresh) {
                switch (style.join) {
                    .bevel => {
                        try self.forward_path.lineTo(allocator, p0.subVec(norm));
                        try self.backward_path.lineTo(allocator, p0.addVec(norm));
                    },
                    .miter => {
                        // Upstream `miter_limit.powi(2)`; repeated multiplication preserves
                        // Rust/LLVM `powi` rounding exactly.
                        const miter_limit2 = style.miter_limit * style.miter_limit;
                        if (2.0 * hypot < (hypot + dot) * miter_limit2) {
                            // TODO: maybe better to store last_norm or derive from path?
                            const last_scale = 0.5 * style.width / ab.hypot();
                            const last_norm = Vec2.new(-ab.y, ab.x).mulScalar(last_scale);
                            if (cross > 0.0) {
                                const fp_last = p0.subVec(last_norm);
                                const fp_this = p0.subVec(norm);
                                const h = ab.cross(fp_this.subPoint(fp_last)) / cross;
                                const miter_pt = fp_this.subVec(cd.mulScalar(h));
                                try self.forward_path.lineTo(allocator, miter_pt);
                                try self.backward_path.lineTo(allocator, p0);
                            } else if (cross < 0.0) {
                                const fp_last = p0.addVec(last_norm);
                                const fp_this = p0.addVec(norm);
                                const h = ab.cross(fp_this.subPoint(fp_last)) / cross;
                                const miter_pt = fp_this.subVec(cd.mulScalar(h));
                                try self.backward_path.lineTo(allocator, miter_pt);
                                try self.forward_path.lineTo(allocator, p0);
                            }
                        }
                        try self.forward_path.lineTo(allocator, p0.subVec(norm));
                        try self.backward_path.lineTo(allocator, p0.addVec(norm));
                    },
                    .round => {
                        const angle = common.FloatFuncs.atan2(cross, dot);
                        if (angle > 0.0) {
                            try self.backward_path.lineTo(allocator, p0.addVec(norm));
                            try roundJoin(allocator, &self.forward_path, tolerance, p0, norm, angle);
                        } else {
                            try self.forward_path.lineTo(allocator, p0.subVec(norm));
                            try roundJoinRev(allocator, &self.backward_path, tolerance, p0, norm.neg(), -angle);
                        }
                    },
                }
            }
        }
    }

    fn doLine(self: *StrokeCtx, allocator: std.mem.Allocator, style: *const Stroke, tangent: Vec2, p1: Point) !void {
        const scale = 0.5 * style.width / tangent.hypot();
        const norm = Vec2.new(-tangent.y, tangent.x).mulScalar(scale);
        try self.forward_path.lineTo(allocator, p1.subVec(norm));
        try self.backward_path.lineTo(allocator, p1.addVec(norm));
        self.last_pt = p1;
    }

    fn doCubic(self: *StrokeCtx, allocator: std.mem.Allocator, style: *const Stroke, c: CubicBez, tolerance: f64) !void {
        // First, detect degenerate linear case

        // Ordinarily, this is the direction of the chord, but if the chord is very
        // short, we take the longer control arm.
        const chord = c.p3.subPoint(c.p0);
        var chord_ref = chord;
        var chord_ref_hypot2 = chord_ref.hypot2();
        const d01 = c.p1.subPoint(c.p0);
        if (d01.hypot2() > chord_ref_hypot2) {
            chord_ref = d01;
            chord_ref_hypot2 = chord_ref.hypot2();
        }
        const d23 = c.p3.subPoint(c.p2);
        if (d23.hypot2() > chord_ref_hypot2) {
            chord_ref = d23;
            chord_ref_hypot2 = chord_ref.hypot2();
        }
        // Project Bézier onto chord
        const q0 = c.p0.toVec2().dot(chord_ref);
        const q1 = c.p1.toVec2().dot(chord_ref);
        const q2 = c.p2.toVec2().dot(chord_ref);
        const q3 = c.p3.toVec2().dot(chord_ref);
        const ENDPOINT_D: f64 = 0.01;
        if (q3 <= q0 or
            q1 > q2 or
            q1 < q0 + ENDPOINT_D * (q3 - q0) or
            q2 > q3 - ENDPOINT_D * (q3 - q0))
        {
            // potentially a cusp inside
            const x01 = d01.cross(chord_ref);
            const x23 = d23.cross(chord_ref);
            const x03 = chord.cross(chord_ref);
            const thresh = tolerance * tolerance * chord_ref_hypot2;
            if (x01 * x01 < thresh and x23 * x23 < thresh and x03 * x03 < thresh) {
                // control points are nearly co-linear
                const midpoint = c.p0.midpoint(c.p3);
                // Mapping back from projection of reference chord
                const ref_vec = chord_ref.divScalar(chord_ref_hypot2);
                const ref_pt = midpoint.subVec(ref_vec.mulScalar(0.5 * (q0 + q3)));
                try self.doLinear(allocator, style, c, .{ q0, q1, q2, q3 }, ref_pt, ref_vec);
                return;
            }
        }

        try offsetCubic(allocator, c, -0.5 * style.width, tolerance, &self.result_path);
        try self.forward_path.elements.appendSlice(allocator, self.result_path.elements.items[1..]);
        try offsetCubic(allocator, c, 0.5 * style.width, tolerance, &self.result_path);
        try self.backward_path.elements.appendSlice(allocator, self.result_path.elements.items[1..]);
        self.last_pt = c.p3;
    }

    /// Do a cubic which is actually linear.
    ///
    /// The `p` argument is the control points projected to the reference chord.
    /// The ref arguments are the inverse map of a projection back to the client
    /// coordinate space.
    fn doLinear(
        self: *StrokeCtx,
        allocator: std.mem.Allocator,
        style: *const Stroke,
        c: CubicBez,
        p: [4]f64,
        ref_pt: Point,
        ref_vec: Vec2,
    ) !void {
        // Always do round join, to model cusp as limit of finite curvature (see Nehab).
        const lin_style = Stroke.new(style.width).withJoin(.round);
        // Tangents of endpoints (for connecting to joins)
        const tans = (PathSeg{ .Cubic = c }).tangents();
        const tan1 = tans[1];
        self.last_tan = tans[0];
        // find cusps
        const c0 = p[1] - p[0];
        const c1 = 2.0 * p[2] - 4.0 * p[1] + 2.0 * p[0];
        const c2 = p[3] - 3.0 * p[2] + 3.0 * p[1] - p[0];
        const roots = common.solveQuadratic(c0, c1, c2);
        // discard cusps right at endpoints
        const EPSILON: f64 = 1e-6;
        for (roots.slice()) |t| {
            if (t > EPSILON and t < 1.0 - EPSILON) {
                const mt = 1.0 - t;
                const z = mt * (mt * mt * p[0] + 3.0 * t * (mt * p[1] + t * p[2])) + t * t * t * p[3];
                const pt = ref_pt.addVec(ref_vec.mulScalar(z));
                const tan = pt.subPoint(self.last_pt);
                try self.doJoin(allocator, &lin_style, tan);
                try self.doLine(allocator, &lin_style, tan, pt);
                self.last_tan = tan;
            }
        }
        const tan = c.p3.subPoint(self.last_pt);
        try self.doJoin(allocator, &lin_style, tan);
        try self.doLine(allocator, &lin_style, tan, c.p3);
        self.last_tan = tan;
        try self.doJoin(allocator, &lin_style, tan1);
    }
};

/// Expand a stroke into a fill.
///
/// The `tolerance` parameter controls the accuracy of the result. In general,
/// the number of subdivisions in the output scales at least to the -1/4 power
/// of the parameter, for example making it 1/16 as big generates twice as many
/// segments. Currently the algorithm is not tuned for extremely fine tolerances.
/// The theoretically optimum scaling exponent is -1/6, but achieving this may
/// require slow numerical techniques (currently a subject of research). The
/// appropriate value depends on the application; if the result of the stroke
/// will be scaled up, a smaller value is needed.
///
/// This method attempts a fairly high degree of correctness, but ultimately
/// is based on computing parallel curves and adding joins and caps, rather than
/// computing the rigorously correct parallel sweep (which requires evolutes in
/// the general case). See [Nehab 2020] for more discussion.
///
/// [Nehab 2020]: https://dl.acm.org/doi/10.1145/3386569.3392392
///
/// The returned path is owned by the caller and must be freed with
/// `BezPath.deinit(allocator)`.
pub fn stroke(
    allocator: std.mem.Allocator,
    path: []const PathEl,
    style: *const Stroke,
    opts: *const StrokeOpts,
    tolerance: f64,
) !BezPath {
    var ctx = StrokeCtx{};
    errdefer ctx.deinit(allocator);
    try strokeWith(allocator, path, style, opts, tolerance, &ctx);

    const output = ctx.output_path;
    ctx.output_path = BezPath.init();
    ctx.deinit(allocator);
    return output;
}

/// Expand a stroke into a fill.
///
/// This is the same as `stroke`, except for the fact that you can explicitly
/// pass a `StrokeCtx`. By doing so, you can reuse the same context over
/// multiple calls and ensure that the number of reallocations is minimized.
///
/// Unlike `stroke`, this method doesn't return an owned version of the expanded
/// stroke as a `BezPath`. Instead, you can get a reference to the resulting
/// path by calling `StrokeCtx.output`.
pub fn strokeWith(
    allocator: std.mem.Allocator,
    path: []const PathEl,
    style: *const Stroke,
    opts: *const StrokeOpts,
    tolerance: f64,
    ctx: *StrokeCtx,
) !void {
    if (style.dash_pattern.len == 0) {
        var it = PathSliceIter{ .elements = path };
        try strokeUndashed(allocator, &it, style, tolerance, ctx);
    } else {
        var dashed = dashIter(allocator, path, style.dash_offset, style.dash_pattern.slice(), opts.stable_dash_order);
        defer dashed.deinit();
        try strokeUndashed(allocator, &dashed, style, tolerance, ctx);
    }
}

/// Version of stroke expansion for styles with no dashes.
///
/// Generic over any iterator type with a `next() ?PathEl` method.
fn strokeUndashed(
    allocator: std.mem.Allocator,
    path: anytype,
    style: *const Stroke,
    tolerance: f64,
    ctx: *StrokeCtx,
) !void {
    ctx.reset();
    ctx.join_thresh = 2.0 * tolerance / style.width;

    while (try pathNext(path)) |el| {
        const p0 = ctx.last_pt;
        switch (el) {
            .MoveTo => |p| {
                try ctx.finish(allocator, style);
                ctx.start_pt = p;
                ctx.last_pt = p;
            },
            .LineTo => |p1| {
                if (!pointsEqual(p1, p0)) {
                    const tangent = p1.subPoint(p0);
                    try ctx.doJoin(allocator, style, tangent);
                    ctx.last_tan = tangent;
                    try ctx.doLine(allocator, style, tangent, p1);
                }
            },
            .QuadTo => |qp| {
                if (!pointsEqual(qp.p1, p0) or !pointsEqual(qp.p2, p0)) {
                    const q = QuadBez.new(p0, qp.p1, qp.p2);
                    const tans = (PathSeg{ .Quad = q }).tangents();
                    try ctx.doJoin(allocator, style, tans[0]);
                    try ctx.doCubic(allocator, style, q.raise(), tolerance);
                    ctx.last_tan = tans[1];
                }
            },
            .CurveTo => |cp| {
                if (!pointsEqual(cp.p1, p0) or !pointsEqual(cp.p2, p0) or !pointsEqual(cp.p3, p0)) {
                    const c = CubicBez.new(p0, cp.p1, cp.p2, cp.p3);
                    const tans = (PathSeg{ .Cubic = c }).tangents();
                    try ctx.doJoin(allocator, style, tans[0]);
                    try ctx.doCubic(allocator, style, c, tolerance);
                    ctx.last_tan = tans[1];
                }
            },
            .ClosePath => {
                if (!pointsEqual(p0, ctx.start_pt)) {
                    const tangent = ctx.start_pt.subPoint(p0);
                    try ctx.doJoin(allocator, style, tangent);
                    ctx.last_tan = tangent;
                    try ctx.doLine(allocator, style, tangent, ctx.start_pt);
                }
                try ctx.finishClosed(allocator, style);
            },
        }
    }
    try ctx.finish(allocator, style);
}

/// Advance an iterator that is either fallible or infallible; Zig has no
/// iterator trait, and `DashIterator` can wrap another `DashIterator`.
inline fn pathNext(iter: anytype) !?PathEl {
    switch (@typeInfo(@TypeOf(iter.next()))) {
        .error_union => return try iter.next(),
        else => return iter.next(),
    }
}

// ---------------------------------------------------------------------------
// Joins and caps
// ---------------------------------------------------------------------------

fn roundCap(
    allocator: std.mem.Allocator,
    out: *BezPath,
    tolerance: f64,
    center: Point,
    norm: Vec2,
) !void {
    try roundJoin(allocator, out, tolerance, center, norm, std.math.pi);
}

fn roundJoin(
    allocator: std.mem.Allocator,
    out: *BezPath,
    tolerance: f64,
    center: Point,
    norm: Vec2,
    angle: f64,
) !void {
    const a = Affine.new(.{ norm.x, norm.y, -norm.y, norm.x, center.x, center.y });
    const arc = Arc.new(Point.ORIGIN, Vec2.new(1.0, 1.0), std.math.pi - angle, angle, 0.0);
    try arc.toCubicBeziers(allocator, out, tolerance, a);
}

fn roundJoinRev(
    allocator: std.mem.Allocator,
    out: *BezPath,
    tolerance: f64,
    center: Point,
    norm: Vec2,
    angle: f64,
) !void {
    const a = Affine.new(.{ norm.x, norm.y, norm.y, -norm.x, center.x, center.y });
    const arc = Arc.new(Point.ORIGIN, Vec2.new(1.0, 1.0), std.math.pi - angle, angle, 0.0);
    try arc.toCubicBeziers(allocator, out, tolerance, a);
}

fn squareCap(
    allocator: std.mem.Allocator,
    out: *BezPath,
    close: bool,
    center: Point,
    norm: Vec2,
) !void {
    const a = Affine.new(.{ norm.x, norm.y, -norm.y, norm.x, center.x, center.y });
    try out.lineTo(allocator, a.transformPoint(Point.new(1.0, 1.0)));
    try out.lineTo(allocator, a.transformPoint(Point.new(-1.0, 1.0)));
    if (close) {
        try out.closePath(allocator);
    } else {
        try out.lineTo(allocator, a.transformPoint(Point.new(-1.0, 0.0)));
    }
}

fn extendReversed(
    allocator: std.mem.Allocator,
    out: *BezPath,
    elements: []const PathEl,
) !void {
    var i = elements.len;
    while (i > 1) {
        i -= 1;
        const end = elements[i - 1].endPoint().?;
        switch (elements[i]) {
            .LineTo => try out.lineTo(allocator, end),
            .QuadTo => |q| try out.quadTo(allocator, q.p1, end),
            .CurveTo => |c| try out.curveTo(allocator, c.p2, c.p1, end),
            else => unreachable,
        }
    }
}

// ---------------------------------------------------------------------------
// Dashing
// ---------------------------------------------------------------------------

/// State of the dash iterator.
pub const DashState = enum {
    need_input,
    to_stash,
    working,
    from_stash,
};

fn segToEl(el: PathSeg) PathEl {
    return switch (el) {
        .Line => |l| PathEl.lineTo(l.p1),
        .Quad => |q| PathEl.quadTo(q.p1, q.p2),
        .Cubic => |c| PathEl.curveTo(c.p1, c.p2, c.p3),
    };
}

const DASH_ACCURACY: f64 = 1e-6;

/// Iterator over a slice of `PathEl`, the Zig counterpart of
/// `impl Iterator<Item = PathEl>` for a path's element slice.
pub const PathSliceIter = struct {
    elements: []const PathEl,
    ix: usize = 0,

    pub fn next(self: *PathSliceIter) ?PathEl {
        if (self.ix >= self.elements.len) return null;
        const el = self.elements[self.ix];
        self.ix += 1;
        return el;
    }
};

/// Create a new dashing iterator.
///
/// Handling of dashes is fairly orthogonal to stroke expansion. This iterator
/// is an internal detail of the stroke expansion logic, but is also available
/// separately, and is expected to be useful when doing stroke expansion on
/// GPU.
///
/// Upstream is an iterator-to-iterator transform over `impl Iterator<Item =
/// PathEl>`; here the input is a path element slice, and the result is a
/// `DashIterator(PathSliceIter)`. Because it consumes the input sequentially
/// and produces consistent output with correct joins, it requires internal
/// state and may allocate.
///
/// Accuracy is currently hard-coded to 1e-6. This is better than generally
/// expected, and care is taken to get cusps correct, among other things.
pub fn dash(
    allocator: std.mem.Allocator,
    path: []const PathEl,
    dash_offset: f64,
    dashes: []const f64,
) DashIterator(PathSliceIter) {
    return dashIter(allocator, path, dash_offset, dashes, false);
}

/// `dash` with the stable-order flag; port of upstream's private `dash_iter`.
pub fn dashIter(
    allocator: std.mem.Allocator,
    path: []const PathEl,
    dash_offset: f64,
    dashes: []const f64,
    stable_dash_order: bool,
) DashIterator(PathSliceIter) {
    return DashIterator(PathSliceIter).init(
        allocator,
        .{ .elements = path },
        dash_offset,
        dashes,
        stable_dash_order,
    );
}

/// An implementation of dashing as an iterator-to-iterator transformation.
pub fn DashIterator(comptime Inner: type) type {
    return struct {
        const Self = @This();

        inner: Inner,
        input_done: bool,
        closepath_pending: bool,
        dashes: []const f64,
        dash_ix: usize,
        init_dash_ix: usize,
        init_dash_remaining: f64,
        init_is_active: bool,
        is_active: bool,
        state: DashState,
        current_seg: PathSeg,
        t: f64,
        dash_remaining: f64,
        seg_remaining: f64,
        start_pt: Point,
        last_pt: Point,
        stash: std.ArrayList(PathEl),
        stash_ix: usize,
        stable_dash_order: bool,
        needs_moveto: bool,
        allocator: std.mem.Allocator,

        /// Create the iterator; mirrors upstream `dash_iter` including the
        /// normalization of the offset by the (doubled, for odd-length
        /// patterns) period.
        pub fn init(
            allocator: std.mem.Allocator,
            inner: Inner,
            dash_offset: f64,
            dashes: []const f64,
            stable_dash_order: bool,
        ) Self {
            std.debug.assert(dashes.len > 0);
            // Ensure that offset is positive and minimal by normalization using period
            var period: f64 = 0.0;
            for (dashes) |d| period += d;
            // The SVG spec requires odd-length dash arrays to be doubled to become even-length:
            // <https://www.w3.org/TR/SVG2/painting.html#StrokeDasharrayProperty>
            // This prevents gaps and dashes from swapping with one another as the offset increases.
            if (dashes.len % 2 == 1) period = 2.0 * period;
            const offset = common.FloatFuncs.remEuclid(dash_offset, period);

            var dash_ix: usize = 0;
            var dash_remaining = dashes[dash_ix] - offset;
            var is_active = true;
            // Find place in dashes array for initial offset.
            while (dash_remaining < 0.0) {
                dash_ix = (dash_ix + 1) % dashes.len;
                dash_remaining += dashes[dash_ix];
                is_active = !is_active;
            }
            return .{
                .inner = inner,
                .input_done = false,
                .closepath_pending = false,
                .dashes = dashes,
                .dash_ix = dash_ix,
                .init_dash_ix = dash_ix,
                .init_dash_remaining = dash_remaining,
                .init_is_active = is_active,
                .is_active = is_active,
                .state = .need_input,
                .current_seg = .{ .Line = Line.new(Point.ORIGIN, Point.ORIGIN) },
                .t = 0.0,
                .dash_remaining = dash_remaining,
                .seg_remaining = 0.0,
                .start_pt = Point.ORIGIN,
                .last_pt = Point.ORIGIN,
                .stash = .empty,
                .stash_ix = 0,
                .stable_dash_order = stable_dash_order,
                .needs_moveto = true,
                .allocator = allocator,
            };
        }

        /// Release the stash. The iterator itself borrows `dashes` and the
        /// inner iterator, which are owned by the caller.
        pub fn deinit(self: *Self) void {
            self.stash.deinit(self.allocator);
            self.stash = .empty;
        }

        pub fn next(self: *Self) !?PathEl {
            while (true) {
                switch (self.state) {
                    .need_input => {
                        if (self.input_done) return null;
                        try self.getInput();
                        if (self.input_done) return null;
                        self.state = .to_stash;
                    },
                    .to_stash => {
                        if (try self.step()) |el| {
                            if (self.stable_dash_order) return el;
                            try self.stash.append(self.allocator, el);
                        }
                    },
                    .working => {
                        if (try self.step()) |el| return el;
                    },
                    .from_stash => {
                        if (self.stash_ix < self.stash.items.len) {
                            const el = self.stash.items[self.stash_ix];
                            self.stash_ix += 1;
                            return el;
                        } else {
                            self.stash.clearRetainingCapacity();
                            self.stash_ix = 0;
                            if (self.input_done) return null;
                            if (self.closepath_pending) {
                                self.closepath_pending = false;
                                self.state = .need_input;
                            } else {
                                self.state = .to_stash;
                            }
                        }
                    },
                }
            }
        }

        fn getInput(self: *Self) !void {
            while (true) {
                if (self.closepath_pending) {
                    try self.handleClosepath();
                    break;
                }
                const next_el = (try pathNext(&self.inner)) orelse {
                    self.input_done = true;
                    self.state = .from_stash;
                    return;
                };
                const p0 = self.last_pt;
                switch (next_el) {
                    .MoveTo => |p| {
                        if (self.stash.items.len != 0) {
                            self.state = .from_stash;
                        }
                        self.start_pt = p;
                        self.last_pt = p;
                        self.resetPhase();
                        continue;
                    },
                    .LineTo => |p1| {
                        const l = Line.new(p0, p1);
                        self.seg_remaining = l.arclen(DASH_ACCURACY);
                        self.current_seg = .{ .Line = l };
                        self.last_pt = p1;
                    },
                    .QuadTo => |qp| {
                        const q = QuadBez.new(p0, qp.p1, qp.p2);
                        self.seg_remaining = q.arclen(DASH_ACCURACY);
                        self.current_seg = .{ .Quad = q };
                        self.last_pt = qp.p2;
                    },
                    .CurveTo => |cp| {
                        const c = CubicBez.new(p0, cp.p1, cp.p2, cp.p3);
                        self.seg_remaining = c.arclen(DASH_ACCURACY);
                        self.current_seg = .{ .Cubic = c };
                        self.last_pt = cp.p3;
                    },
                    .ClosePath => {
                        self.closepath_pending = true;
                        if (!pointsEqual(p0, self.start_pt)) {
                            const l = Line.new(p0, self.start_pt);
                            self.seg_remaining = l.arclen(DASH_ACCURACY);
                            self.current_seg = .{ .Line = l };
                            self.last_pt = self.start_pt;
                        } else {
                            try self.handleClosepath();
                        }
                    },
                }
                break;
            }
            self.t = 0.0;
        }

        /// Move arc length forward to next event.
        fn step(self: *Self) !?PathEl {
            var result: ?PathEl = null;
            if (self.state == .to_stash and self.needs_moveto) {
                self.needs_moveto = false;
                if (self.is_active) {
                    result = PathEl.moveTo(self.current_seg.start());
                } else {
                    self.state = .working;
                }
            } else if (self.dash_remaining < self.seg_remaining) {
                // next transition is a dash transition
                const seg = self.current_seg.subsegment(self.t, 1.0);
                const t1 = seg.invArclen(self.dash_remaining, DASH_ACCURACY);
                if (self.is_active) {
                    const subseg = seg.subsegment(0.0, t1);
                    result = segToEl(subseg);
                    self.state = .working;
                } else {
                    const p = seg.eval(t1);
                    result = PathEl.moveTo(p);
                }
                self.is_active = !self.is_active;
                self.t += t1 * (1.0 - self.t);
                self.seg_remaining -= self.dash_remaining;
                self.dash_ix += 1;
                if (self.dash_ix == self.dashes.len) {
                    self.dash_ix = 0;
                }
                self.dash_remaining = self.dashes[self.dash_ix];
            } else {
                if (self.is_active) {
                    const seg = self.current_seg.subsegment(self.t, 1.0);
                    result = segToEl(seg);
                }
                self.dash_remaining -= self.seg_remaining;
                try self.getInput();
            }
            return result;
        }

        fn handleClosepath(self: *Self) !void {
            if (self.state == .to_stash) {
                // Have looped back without breaking a dash, just play it back
                try self.stash.append(self.allocator, PathEl.closePath());
            } else if (self.is_active and !self.stable_dash_order) {
                // connect with path in stash, skip MoveTo.
                self.stash_ix = 1;
            }
            self.state = .from_stash;
            self.resetPhase();
        }

        fn resetPhase(self: *Self) void {
            self.dash_ix = self.init_dash_ix;
            self.dash_remaining = self.init_dash_remaining;
            self.is_active = self.init_is_active;
            self.needs_moveto = true;
        }
    };
}

// ---------------------------------------------------------------------------
// Offset curve of a cubic (port of the subset of offset.rs used by doCubic)
// ---------------------------------------------------------------------------

/// State used for computing an offset curve of a single cubic.
const CubicOffset = struct {
    /// The cubic being offset. This has been regularized.
    c: CubicBez,
    /// The derivative of `c`.
    q: QuadBez,
    /// The offset distance (same as the argument).
    d: f64,
    /// `c0 + c1 t + c2 t^2` is the cross product of second and first
    /// derivatives of the underlying cubic, multiplied by the offset.
    /// This is used for computing cusps on the offset curve.
    ///
    /// Note that given a curve `c(t)`, its signed curvature is
    /// `c''(t) x c'(t) / ||c'(t)||^3`. See also `cuspSign`.
    c0: f64,
    c1: f64,
    c2: f64,
    /// The tolerance (same as the argument).
    tolerance: f64,

    /// Create a new curve from Bézier segment and offset.
    fn new(c: CubicBez, d: f64, tolerance: f64) CubicOffset {
        const q = c.deriv();
        const d2 = 2.0 * d;
        const p1xp0 = q.p1.toVec2().cross(q.p0.toVec2());
        const p2xp0 = q.p2.toVec2().cross(q.p0.toVec2());
        const p2xp1 = q.p2.toVec2().cross(q.p1.toVec2());
        return .{
            .c = c,
            .q = q,
            .d = d,
            .c0 = d2 * p1xp0,
            .c1 = d2 * (p2xp0 - 2.0 * p1xp0),
            .c2 = d2 * (p2xp1 - p2xp0 + p1xp0),
            .tolerance = tolerance,
        };
    }

    /// Compute curvature of the source curve times offset plus 1.
    ///
    /// This quantity is called "cusp" because cusps appear in the offset curve
    /// where this value crosses zero. This is based on the geometric property
    /// that the offset curve has a cusp when the radius of curvature of the
    /// source curve is equal to the offset curve's distance.
    ///
    /// Note: there is a potential division by zero when the derivative vanishes.
    /// We avoid doing so for interior points by regularizing the cubic beforehand.
    /// We avoid doing so for endpoints by calling `endpointCusp` instead.
    fn cuspSign(self: *const CubicOffset, t: f64) f64 {
        const ds2 = self.q.eval(t).toVec2().hypot2();
        return ((self.c2 * t + self.c1) * t + self.c0) / (ds2 * @sqrt(ds2)) + 1.0;
    }

    /// Compute cusp value of endpoint.
    ///
    /// This is a special case of `cuspSign`. For the start point, `tan` should
    /// be the start point tangent and `y` should be `c0`. For the end point,
    /// `tan` should be the end point tangent and `y` should be
    /// `c0 + c1 + c2`.
    ///
    /// This is just evaluating the polynomial at t=0 and t=1.
    fn endpointCusp(self: *const CubicOffset, tan: Point, y: f64) f64 {
        _ = self;
        // Robustness to avoid divide-by-zero when derivatives vanish
        const TAN_DIST_EPSILON: f64 = 1e-12;
        const tan_dist = @max(tan.toVec2().hypot(), TAN_DIST_EPSILON);
        const rsqrt = 1.0 / tan_dist;
        return y * (rsqrt * rsqrt * rsqrt) + 1.0;
    }

    /// Primary entry point for recursive subdivision.
    ///
    /// The error set is explicit: `offsetRec` and `subdivide` are mutually
    /// recursive and would otherwise not infer a finite error set.
    fn offsetRec(
        self: *const CubicOffset,
        allocator: std.mem.Allocator,
        rec: OffsetRec,
        result: *BezPath,
    ) std.mem.Allocator.Error!void {
        // First, determine whether the offset curve contains a cusp. ...
        if (rec.cusp0 * rec.cusp1 < 0.0) {
            const a = rec.t0;
            const b = rec.t1;
            const s = common.FloatFuncs.signum(rec.cusp1);
            const CuspCtx = struct {
                co: *const CubicOffset,
                s: f64,

                fn eval(ctx: *@This(), t: f64) f64 {
                    return ctx.s * ctx.co.cuspSign(t);
                }
            };
            var itp_ctx = CuspCtx{ .co = self, .s = s };
            const k1 = 0.2 / (b - a);
            const ITP_EPS: f64 = 1e-12;
            const t = common.solveItp(
                CuspCtx,
                CuspCtx.eval,
                &itp_ctx,
                a,
                b,
                ITP_EPS,
                1,
                k1,
                s * rec.cusp0,
                s * rec.cusp1,
            );
            // TODO(robustness): If we're unlucky, there will be 3 cusps between t0
            // and t1, and the solver will land on the middle one. ...
            const utan_t = self.q.eval(t).toVec2().normalize();
            const cusp_t_minus = common.FloatFuncs.copysign(CUSP_EPSILON, rec.cusp0);
            const cusp_t_plus = common.FloatFuncs.copysign(CUSP_EPSILON, rec.cusp1);
            try self.subdivide(allocator, rec, result, t, utan_t, cusp_t_minus, cusp_t_plus);
            return;
        }
        // We determine the first approximation to the offset curve.
        const ab = self.drawArc(rec);
        var a = ab[0];
        var b = ab[1];
        const dt = (rec.t1 - rec.t0) * (1.0 / @as(f64, @floatFromInt(N_LSE + 1)));
        // These represent t values on the source curve.
        var ts: [N_LSE]f64 = undefined;
        for (&ts, 0..) |*t, i| {
            t.* = rec.t0 + @as(f64, @floatFromInt(i + 1)) * dt;
        }
        var c_approx = self.apply(rec, a, b);
        const err_init = self.evalErr(rec, c_approx, &ts);
        var err = err_init;
        // Number of least-squares refinement steps. More gives a smaller
        // error, but takes more time.
        const N_REFINE: usize = 2;
        for (0..N_REFINE) |_| {
            if (err.err_squared <= self.tolerance * self.tolerance) {
                break;
            }
            const ab2 = self.refineLeastSquares(rec, a, b, &err);
            const c_approx2 = self.apply(rec, ab2[0], ab2[1]);
            const err2 = self.evalErr(rec, c_approx2, &ts);
            if (err2.err_squared >= err.err_squared) {
                break;
            }
            err = err2;
            a = ab2[0];
            b = ab2[1];
            c_approx = c_approx2;
        }
        if (rec.depth < MAX_DEPTH and err.err_squared > self.tolerance * self.tolerance) {
            const sp = self.findSubdivisionPoint(rec);
            // TODO(robustness): if cusp is extremely near zero, then assign epsilon
            // with alternate signs based on derivative of cusp.
            const cusp = self.cuspSign(sp.t);
            try self.subdivide(allocator, rec, result, sp.t, sp.utan, cusp, cusp);
        } else {
            try result.curveTo(allocator, c_approx.p1, c_approx.p2, c_approx.p3);
        }
    }

    /// Recursively subdivide.
    fn subdivide(
        self: *const CubicOffset,
        allocator: std.mem.Allocator,
        rec: OffsetRec,
        result: *BezPath,
        t: f64,
        utan_t: Vec2,
        cusp_t_minus: f64,
        cusp_t_plus: f64,
    ) std.mem.Allocator.Error!void {
        const rec0 = OffsetRec{
            .t0 = rec.t0,
            .t1 = t,
            .utan0 = rec.utan0,
            .utan1 = utan_t,
            .cusp0 = rec.cusp0,
            .cusp1 = cusp_t_minus,
            .depth = rec.depth + 1,
        };
        try self.offsetRec(allocator, rec0, result);
        const rec1 = OffsetRec{
            .t0 = t,
            .t1 = rec.t1,
            .utan0 = utan_t,
            .utan1 = rec.utan1,
            .cusp0 = cusp_t_plus,
            .cusp1 = rec.cusp1,
            .depth = rec.depth + 1,
        };
        try self.offsetRec(allocator, rec1, result);
    }

    /// Convert from (a, b) parameter space to the approximate cubic Bézier.
    fn apply(self: *const CubicOffset, rec: OffsetRec, a: f64, b: f64) CubicBez {
        // wondering if p0 and p3 should be in rec
        // Scale factor from derivatives to displacements
        const s = (1.0 / 3.0) * (rec.t1 - rec.t0);
        const p0 = self.c.eval(rec.t0).addVec(rec.utan0.turn90().mulScalar(self.d));
        const l0 = s * self.q.eval(rec.t0).toVec2().length() + a * self.d;
        var p1 = p0;
        if (l0 * rec.cusp0 > 0.0) {
            p1 = p1.addVec(rec.utan0.mulScalar(l0));
        }
        const p3 = self.c.eval(rec.t1).addVec(rec.utan1.turn90().mulScalar(self.d));
        var p2 = p3;
        const l1 = s * self.q.eval(rec.t1).toVec2().length() - b * self.d;
        if (l1 * rec.cusp1 > 0.0) {
            p2 = p2.subVec(rec.utan1.mulScalar(l1));
        }
        return CubicBez.new(p0, p1, p2, p3);
    }

    /// Compute arc approximation.
    fn drawArc(self: *const CubicOffset, rec: OffsetRec) [2]f64 {
        // possible optimization: this can probably be done with vectors
        // rather than arctangent
        _ = self;
        const th = common.FloatFuncs.atan2(rec.utan1.cross(rec.utan0), rec.utan1.dot(rec.utan0));
        const half = 0.5 * th;
        const a = (2.0 / 3.0) / (1.0 + common.FloatFuncs.cos(half)) * 2.0 * common.FloatFuncs.sin(half);
        return .{ a, -a };
    }

    /// Evaluate error and also refine t values.
    fn evalErr(
        self: *const CubicOffset,
        rec: OffsetRec,
        c_approx: CubicBez,
        ts: *[N_LSE]f64,
    ) ErrEval {
        const qa = c_approx.deriv();
        var err_squared: f64 = 0.0;
        var unorms: [N_LSE]Vec2 = @splat(Vec2.ZERO);
        var err_vecs: [N_LSE]Vec2 = @splat(Vec2.ZERO);
        for (0..N_LSE) |i| {
            const ta = @as(f64, @floatFromInt(i + 1)) * (1.0 / @as(f64, @floatFromInt(N_LSE + 1)));
            var t = ts[i];
            const p = self.c.eval(t);
            // Newton step to refine t value
            const pa = c_approx.eval(ta);
            const tana = qa.eval(ta).toVec2();
            t += tana.dot(pa.subPoint(p)) / tana.dot(self.q.eval(t).toVec2());
            t = @max(rec.t0, @min(rec.t1, t));
            ts[i] = t;
            const cusp = common.FloatFuncs.signum(rec.cusp0);
            const unorm = tana.normalize().turn90().mulScalar(cusp);
            unorms[i] = unorm;
            const p_new = self.c.eval(t).addVec(unorm.mulScalar(self.d));
            const err_vec = pa.subPoint(p_new);
            err_vecs[i] = err_vec;
            var dist_err_squared = err_vec.lengthSquared();
            if (!std.math.isFinite(dist_err_squared)) {
                // A hack to make sure we reject bad refinements
                dist_err_squared = 1e12;
            }
            // Note: consider also incorporating angle error
            err_squared = @max(dist_err_squared, err_squared);
        }
        return .{
            .err_squared = err_squared,
            .unorms = unorms,
            .err_vecs = err_vecs,
        };
    }

    /// Refine an approximation, minimizing least squares error.
    fn refineLeastSquares(
        self: *const CubicOffset,
        rec: OffsetRec,
        a: f64,
        b: f64,
        err: *const ErrEval,
    ) [2]f64 {
        var aa: f64 = 0.0;
        var ab: f64 = 0.0;
        var ac: f64 = 0.0;
        var bb: f64 = 0.0;
        var bc: f64 = 0.0;
        for (0..N_LSE) |i| {
            const n = err.unorms[i];
            const err_vec = err.err_vecs[i];
            const c_n = err_vec.dot(n);
            const c_t = err_vec.cross(n);
            const a_n = A_WEIGHTS[i] * rec.utan0.dot(n);
            const a_t = A_WEIGHTS[i] * rec.utan0.cross(n);
            const b_n = B_WEIGHTS[i] * rec.utan1.dot(n);
            const b_t = B_WEIGHTS[i] * rec.utan1.cross(n);
            aa += a_n * a_n + BLEND * (a_t * a_t);
            ab += a_n * b_n + BLEND * a_t * b_t;
            ac += a_n * c_n + BLEND * a_t * c_t;
            bb += b_n * b_n + BLEND * (b_t * b_t);
            bc += b_n * c_n + BLEND * b_t * c_t;
        }
        const idet = 1.0 / (self.d * (aa * bb - ab * ab));
        const delta_a = idet * (ac * bb - ab * bc);
        const delta_b = idet * (aa * bc - ac * ab);
        return .{ a - delta_a, b - delta_b };
    }

    /// Decide where to subdivide when error is exceeded.
    fn findSubdivisionPoint(self: *const CubicOffset, rec: OffsetRec) SubdivisionPoint {
        const t = 0.5 * (rec.t0 + rec.t1);
        const q_t = self.q.eval(t).toVec2();
        const x0 = @abs(rec.utan0.cross(q_t));
        const x1 = @abs(rec.utan1.cross(q_t));
        const SUBDIVIDE_THRESH: f64 = 0.1;
        if (x0 > SUBDIVIDE_THRESH * x1 and x1 > SUBDIVIDE_THRESH * x0) {
            const utan = q_t.normalize();
            return .{ .t = t, .utan = utan };
        }

        // Note: do we want to track p0 & p3 in rec, to avoid repeated eval?
        const chord = self.c.eval(rec.t1).subPoint(self.c.eval(rec.t0));
        if (chord.cross(rec.utan0) * chord.cross(rec.utan1) < 0.0) {
            const tan = rec.utan0.add(rec.utan1);
            if (self.subdivideForTangent(rec.utan0, rec.t0, rec.t1, tan, false)) |subdivision| {
                return subdivision;
            }
        }
        // Curve definitely has an inflection point
        // Try to subdivide based on integral of absolute curvature.

        // Tangents at recursion endpoints and inflection points.
        var tangents = common.SmallVec(Vec2, 4){};
        var ts = common.SmallVec(f64, 4){};
        tangents.push(rec.utan0);
        ts.push(rec.t0);
        const infl = self.c.inflections();
        for (infl.slice()) |t_infl| {
            if (t_infl > rec.t0 and t_infl < rec.t1) {
                tangents.push(self.q.eval(t_infl).toVec2());
                ts.push(t_infl);
            }
        }
        tangents.push(rec.utan1);
        ts.push(rec.t1);
        var arc_angles = common.SmallVec(f64, 3){};
        var sum: f64 = 0.0;
        for (0..tangents.len - 1) |i| {
            const tan0 = tangents.get(i);
            const tan1 = tangents.get(i + 1);
            const th = common.FloatFuncs.atan2(tan0.cross(tan1), tan0.dot(tan1));
            sum += @abs(th);
            arc_angles.push(th);
        }
        var target = sum * 0.5;
        var i: usize = 0;
        while (@abs(arc_angles.get(i)) < target) {
            target -= @abs(arc_angles.get(i));
            i += 1;
        }
        const rotation = Vec2.fromAngle(common.FloatFuncs.copysign(target, arc_angles.get(i)));
        const base = tangents.get(i);
        const tan = base.rotateScale(rotation);
        const utan0 = if (i == 0) rec.utan0 else base.normalize();
        return self.subdivideForTangent(utan0, ts.get(i), ts.get(i + 1), tan, true).?;
    }

    /// Find a subdivision point, given a tangent vector.
    fn subdivideForTangent(
        self: *const CubicOffset,
        utan0: Vec2,
        t0: f64,
        t1: f64,
        tan: Vec2,
        force: bool,
    ) ?SubdivisionPoint {
        var t: f64 = 0.0;
        var n_soln: usize = 0;
        // set up quadratic equation for matching tangents
        const z0 = tan.cross(self.q.p0.toVec2());
        const z1 = tan.cross(self.q.p1.toVec2());
        const z2 = tan.cross(self.q.p2.toVec2());
        const c0 = z0;
        const c1 = 2.0 * (z1 - z0);
        const c2 = (z2 - z1) - (z1 - z0);
        const roots = common.solveQuadratic(c0, c1, c2);
        for (roots.slice()) |root| {
            if (root >= t0 and root <= t1) {
                t = root;
                n_soln += 1;
            }
        }
        if (n_soln != 1) {
            if (!force) {
                return null;
            }
            // Numerical failure, try to subdivide at cusp; we pick the
            // smaller derivative.
            if (self.q.eval(t0).toVec2().lengthSquared() > self.q.eval(t1).toVec2().lengthSquared()) {
                t = t1;
            } else {
                t = t0;
            }
        }
        const q = self.q.eval(t).toVec2();
        const UTAN_EPSILON: f64 = 1e-12;
        const utan = if (n_soln == 1 and q.lengthSquared() >= UTAN_EPSILON)
            q.normalize()
        else if (tan.lengthSquared() >= UTAN_EPSILON)
            // Curve has a zero-derivative cusp but angles well defined
            tan.normalize()
        else
            // 180 degree U-turn, arbitrarily pick a direction.
            // If we get to this point, there will probably be a failure.
            utan0.turn90();
        return .{ .t = t, .utan = utan };
    }
};

// We never let cusp values have an absolute value smaller than
// this. When a cusp is found, determine its sign and use this value.
const CUSP_EPSILON: f64 = 1e-12;

/// Number of points for least-squares fit and error evaluation.
///
/// This value is a tradeoff between accuracy and performance. ...
const N_LSE: usize = 8;

/// The proportion of transverse error that is blended in the least-squares logic.
const BLEND: f64 = 1e-3;

/// Maximum recursion depth.
///
/// Recursion is bounded to this depth, so the total number of subdivisions will
/// not exceed two to this power.
const MAX_DEPTH: usize = 8;

/// State local to a subdivision.
const OffsetRec = struct {
    t0: f64,
    t1: f64,
    // unit tangent at t0
    utan0: Vec2,
    // unit tangent at t1
    utan1: Vec2,
    cusp0: f64,
    cusp1: f64,
    /// Recursion depth
    depth: usize,
};

/// Result of error evaluation.
const ErrEval = struct {
    /// Maximum detected error
    err_squared: f64,
    /// Unit normals sampled uniformly across approximation
    unorms: [N_LSE]Vec2,
    /// Difference between point on source curve and normal from approximation.
    err_vecs: [N_LSE]Vec2,
};

/// Result of subdivision.
const SubdivisionPoint = struct {
    /// Source curve t value at subdivision point
    t: f64,
    /// Unit tangent at subdivision point
    utan: Vec2,
};

/// Cusp classification (upstream `cubicbez.rs` `CuspType`).
const CuspType = enum {
    loop,
    double_inflection,
};

/// Preprocess a cubic Bézier to ease numerical robustness.
///
/// If the cubic Bézier segment has zero or near-zero derivatives as an interior
/// cusp, perturb the control points to make curvature finite, avoiding
/// numerical robustness problems in offset and stroke.
///
/// Private port of upstream `CubicBez::regularize_cusp` (`pub(crate)`).
fn regularizeCusp(c: CubicBez, dimension: f64) CubicBez {
    var result = c;
    // First step: if control point is too near the endpoint, nudge it away
    // along the tangent.
    if (detectCusp(c, dimension)) |cusp_type| {
        const d01 = result.p1.subPoint(result.p0);
        const d01h = d01.hypot();
        const d23 = result.p3.subPoint(result.p2);
        const d23h = d23.hypot();
        switch (cusp_type) {
            .loop => {
                result.p1 = result.p1.addVec(d01.mulScalar(dimension / d01h));
                result.p2 = result.p2.subVec(d23.mulScalar(dimension / d23h));
            },
            .double_inflection => {
                // Avoid making control distance smaller than dimension
                if (d01h > 2.0 * dimension) {
                    result.p1 = result.p1.subVec(d01.mulScalar(dimension / d01h));
                }
                if (d23h > 2.0 * dimension) {
                    result.p2 = result.p2.addVec(d23.mulScalar(dimension / d23h));
                }
            },
        }
    }
    return result;
}

/// Detect whether there is a cusp.
///
/// Return a cusp classification if there is a cusp with curvature greater than
/// the reciprocal of the given dimension.
///
/// Private port of upstream `CubicBez::detect_cusp`.
fn detectCusp(c: CubicBez, dimension: f64) ?CuspType {
    const d01 = c.p1.subPoint(c.p0);
    const d02 = c.p2.subPoint(c.p0);
    const d03 = c.p3.subPoint(c.p0);
    const d12 = c.p2.subPoint(c.p1);
    const d23 = c.p3.subPoint(c.p2);
    const det_012 = d01.cross(d02);
    const det_123 = d12.cross(d23);
    const det_013 = d01.cross(d03);
    const det_023 = d02.cross(d03);
    if (det_012 * det_123 > 0.0 and det_012 * det_013 < 0.0 and det_012 * det_023 < 0.0) {
        const q = c.deriv();
        // accuracy isn't used for quadratic nearest
        const nearest = q.nearest(Point.ORIGIN, 1e-9);
        // detect whether curvature at minimum derivative exceeds 1/dimension,
        // without division.
        const d = q.eval(nearest.t);
        const d2 = q.deriv().eval(nearest.t);
        const cross = d.toVec2().cross(d2.toVec2());
        const xd = cross * dimension;
        // Upstream `powi`; repeated multiplication preserves LLVM `powi` rounding.
        if (nearest.distance_sq * nearest.distance_sq * nearest.distance_sq <= xd * xd) {
            const a = 3.0 * det_012 + det_023 - 2.0 * det_013;
            const b = -3.0 * det_012 + det_013;
            const const_c = det_012;
            const disc = b * b - 4.0 * a * const_c;
            if (disc > 0.0) {
                return .double_inflection;
            } else {
                return .loop;
            }
        }
    }
    return null;
}

/// Compute Bézier weights for evenly subdivided t values.
fn mkAWeights(comptime rev: bool) [N_LSE]f64 {
    var result: [N_LSE]f64 = @splat(0.0);
    var i: usize = 0;
    while (i < N_LSE) : (i += 1) {
        const t = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(N_LSE + 1));
        const mt = 1.0 - t;
        const ix = if (rev) N_LSE - 1 - i else i;
        result[ix] = 3.0 * mt * t * mt;
    }
    return result;
}

const A_WEIGHTS: [N_LSE]f64 = mkAWeights(false);
const B_WEIGHTS: [N_LSE]f64 = mkAWeights(true);

/// Compute an approximate offset curve (`offset.rs::offset_cubic`).
///
/// The parallel curve of `c` offset by `d` is written to the `result` path.
///
/// There is a fair amount of attention to robustness, but this method is not
/// suitable for degenerate cubics with entirely co-linear control points.
/// Those cases should be handled before calling this function, by replacing
/// them with linear segments (`doCubic` does).
///
/// Private because upstream owns this in `offset.rs`; see the module docs.
fn offsetCubic(
    allocator: std.mem.Allocator,
    c: CubicBez,
    d: f64,
    tolerance: f64,
    result: *BezPath,
) !void {
    result.truncate(0);
    // A tuning parameter for regularization. A value too large may distort the curve,
    // while a value too small may fail to generate smooth curves. This is a somewhat
    // arbitrary value, and should be revisited.
    const DIM_TUNE: f64 = 0.25;
    // We use regularization to perturb the curve to avoid *interior* zero-derivative
    // cusps. There is robustness logic in place to handle zero derivatives at the
    // endpoints.
    const c_regularized = regularizeCusp(c, tolerance * DIM_TUNE);
    const co = CubicOffset.new(c_regularized, d, tolerance);
    const tans = (PathSeg{ .Cubic = c }).tangents();
    const utan0 = tans[0].normalize();
    const utan1 = tans[1].normalize();
    const cusp0 = co.endpointCusp(co.q.p0, co.c0);
    const cusp1 = co.endpointCusp(co.q.p2, co.c0 + co.c1 + co.c2);
    try result.moveTo(allocator, c.p0.addVec(utan0.turn90().mulScalar(d)));
    const rec = OffsetRec{
        .t0 = 0.0,
        .t1 = 1.0,
        .utan0 = utan0,
        .utan1 = utan1,
        .cusp0 = cusp0,
        .cusp1 = cusp1,
        .depth = 0,
    };
    try co.offsetRec(allocator, rec, result);
}

// ---------------------------------------------------------------------------
// Tests (ported from stroke.rs and offset.rs, plus cap/join smoke tests)
// ---------------------------------------------------------------------------

fn collectElements(
    allocator: std.mem.Allocator,
    path: []const PathEl,
    dashes: []const f64,
    offset: f64,
    stable: bool,
) !std.ArrayList(PathEl) {
    var els = std.ArrayList(PathEl).empty;
    errdefer els.deinit(allocator);
    var it = dashIter(allocator, path, offset, dashes, stable);
    defer it.deinit();
    while (try it.next()) |el| {
        try els.append(allocator, el);
    }
    return els;
}

fn collectSegments(
    allocator: std.mem.Allocator,
    path: []const PathEl,
    dashes: []const f64,
    offset: f64,
    stable: bool,
) !std.ArrayList(PathSeg) {
    var els = try collectElements(allocator, path, dashes, offset, stable);
    defer els.deinit(allocator);
    var result = std.ArrayList(PathSeg).empty;
    errdefer result.deinit(allocator);
    var it = segments(els.items);
    while (it.next()) |seg| {
        try result.append(allocator, seg);
    }
    return result;
}

test "pathological stroke" {
    const allocator = std.testing.allocator;
    // A degenerate stroke with a cusp at the endpoint.
    const curve = CubicBez.new(
        Point.new(602.469, 286.585),
        Point.new(641.975, 286.585),
        Point.new(562.963, 286.585),
        Point.new(562.963, 286.585),
    );
    var path = try curve.toPath(0.1, allocator);
    defer path.deinit(allocator);
    const style = Stroke.new(1.0);
    var stroked = try stroke(allocator, path.elementsSlice(), &style, &StrokeOpts.default, 0.001);
    defer stroked.deinit(allocator);
    try std.testing.expect(stroked.isFinite());
}

test "dash miter join" {
    // <https://github.com/linebender/kurbo/issues/482>
    const allocator = std.testing.allocator;
    var path = BezPath.init();
    defer path.deinit(allocator);
    try path.moveTo(allocator, Point.new(70.0, 80.0));
    try path.lineTo(allocator, Point.new(0.0, 80.0));
    try path.lineTo(allocator, Point.new(0.0, 77.0));

    var expected = BezPath.init();
    defer expected.deinit(allocator);
    try expected.moveTo(allocator, Point.new(70.0, 90.0));
    try expected.lineTo(allocator, Point.new(0.0, 90.0));
    // Miter join point on forward path
    try expected.lineTo(allocator, Point.new(-10.0, 90.0));
    try expected.lineTo(allocator, Point.new(-10.0, 80.0));
    try expected.lineTo(allocator, Point.new(-10.0, 77.0));
    try expected.lineTo(allocator, Point.new(10.0, 77.0));
    try expected.lineTo(allocator, Point.new(10.0, 80.0));
    // Miter join point on backward path
    try expected.lineTo(allocator, Point.new(0.0, 80.0));
    try expected.lineTo(allocator, Point.new(0.0, 70.0));
    try expected.lineTo(allocator, Point.new(70.0, 70.0));
    try expected.closePath(allocator);

    const style = try Stroke.new(20.0)
        .withJoin(.miter)
        .withCaps(.butt)
        .withDashes(0.0, &.{ 73.0, 12.0 });
    var got = try stroke(allocator, path.elementsSlice(), &style, &StrokeOpts.default, 0.25);
    defer got.deinit(allocator);
    try std.testing.expectEqualDeep(expected.elementsSlice(), got.elementsSlice());
}

test "broken strokes" {
    // Test cases adapted from https://github.com/linebender/vello/pull/388
    const allocator = std.testing.allocator;
    const broken_cubics = [_][4][2]f64{
        .{
            .{ 465.24423, 107.11105 },
            .{ 475.50754, 107.11105 },
            .{ 475.50754, 107.11105 },
            .{ 475.50754, 107.11105 },
        },
        // Near-cusp
        .{ .{ 0.0, -0.01 }, .{ 128.0, 128.001 }, .{ 128.0, -0.01 }, .{ 0.0, 128.001 } },
        // Flat line with 180
        .{ .{ 0.0, 0.0 }, .{ 0.0, -10.0 }, .{ 0.0, -10.0 }, .{ 0.0, 10.0 } },
        // Flat line with 2 180s
        .{ .{ 10.0, 0.0 }, .{ 0.0, 0.0 }, .{ 20.0, 0.0 }, .{ 10.0, 0.0 } },
        // Flat diagonal with 180
        .{ .{ 39.0, -39.0 }, .{ 40.0, -40.0 }, .{ 40.0, -40.0 }, .{ 0.0, 0.0 } },
        // Diag w/ an internal 180
        .{ .{ 40.0, 40.0 }, .{ 0.0, 0.0 }, .{ 200.0, 200.0 }, .{ 0.0, 0.0 } },
        // Circle
        .{ .{ 0.0, 0.0 }, .{ 1e-2, 0.0 }, .{ -1e-2, 0.0 }, .{ 0.0, 0.0 } },
        // Flat line with no turns:
        .{
            .{ 400.75, 100.05 },
            .{ 400.75, 100.05 },
            .{ 100.05, 300.95 },
            .{ 100.05, 300.95 },
        },
        // Flat line with 2 180s
        .{ .{ 0.5, 0.0 }, .{ 0.0, 0.0 }, .{ 20.0, 0.0 }, .{ 10.0, 0.0 } },
        // Flat line with a 180
        .{ .{ 10.0, 0.0 }, .{ 0.0, 0.0 }, .{ 10.0, 0.0 }, .{ 10.0, 0.0 } },
    };
    const style = Stroke.new(30.0).withCaps(.butt).withJoin(.miter);
    for (broken_cubics) |cubic| {
        const c = CubicBez.new(
            Point.new(cubic[0][0], cubic[0][1]),
            Point.new(cubic[1][0], cubic[1][1]),
            Point.new(cubic[2][0], cubic[2][1]),
            Point.new(cubic[3][0], cubic[3][1]),
        );
        var path = try c.toPath(0.1, allocator);
        defer path.deinit(allocator);
        var stroked = try stroke(allocator, path.elementsSlice(), &style, &StrokeOpts.default, 0.001);
        defer stroked.deinit(allocator);
        try std.testing.expect(stroked.isFinite());
    }
}

test "dash sequence" {
    const allocator = std.testing.allocator;
    const shape = Line.new(Point.new(0.0, 0.0), Point.new(21.0, 0.0));
    const dashes = [4]f64{ 1.0, 5.0, 2.0, 5.0 };
    const expansion = [4]PathSeg{
        .{ .Line = Line.new(Point.new(6.0, 0.0), Point.new(8.0, 0.0)) },
        .{ .Line = Line.new(Point.new(13.0, 0.0), Point.new(14.0, 0.0)) },
        .{ .Line = Line.new(Point.new(19.0, 0.0), Point.new(21.0, 0.0)) },
        .{ .Line = Line.new(Point.new(0.0, 0.0), Point.new(1.0, 0.0)) },
    };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    var got = try collectSegments(allocator, path.elementsSlice(), &dashes, 0.0, false);
    defer got.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expansion.len), got.items.len);
    for (expansion, got.items) |e, g| {
        try std.testing.expectEqualDeep(e, g);
    }
}

test "dash sequence closed path" {
    const allocator = std.testing.allocator;
    const shape = @import("rect.zig").Rect.fromPoints(Point.new(0.0, 0.0), Point.new(4.0, 4.0));
    const dashes = [2]f64{ 5.0, 1.0 };
    const expansion = [_]PathEl{
        PathEl.moveTo(Point.new(4.0, 2.0)),
        PathEl.lineTo(Point.new(4.0, 4.0)),
        PathEl.lineTo(Point.new(1.0, 4.0)),
        PathEl.moveTo(Point.new(0.0, 4.0)),
        PathEl.lineTo(Point.new(0.0, 0.0)),
        PathEl.lineTo(Point.new(4.0, 0.0)),
        PathEl.lineTo(Point.new(4.0, 1.0)),
    };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    var got = try collectElements(allocator, path.elementsSlice(), &dashes, 0.0, false);
    defer got.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expansion.len), got.items.len);
    for (expansion, got.items) |e, g| {
        try std.testing.expectEqualDeep(e, g);
    }
}

test "dash sequence stable order" {
    const allocator = std.testing.allocator;
    const shape = Line.new(Point.new(0.0, 0.0), Point.new(21.0, 0.0));
    const dashes = [4]f64{ 1.0, 5.0, 2.0, 5.0 };
    const expansion = [4]PathSeg{
        .{ .Line = Line.new(Point.new(0.0, 0.0), Point.new(1.0, 0.0)) },
        .{ .Line = Line.new(Point.new(6.0, 0.0), Point.new(8.0, 0.0)) },
        .{ .Line = Line.new(Point.new(13.0, 0.0), Point.new(14.0, 0.0)) },
        .{ .Line = Line.new(Point.new(19.0, 0.0), Point.new(21.0, 0.0)) },
    };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    var got = try collectSegments(allocator, path.elementsSlice(), &dashes, 0.0, true);
    defer got.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expansion.len), got.items.len);
    for (expansion, got.items) |e, g| {
        try std.testing.expectEqualDeep(e, g);
    }
}

test "dash sequence closed path stable order" {
    const allocator = std.testing.allocator;
    const shape = @import("rect.zig").Rect.fromPoints(Point.new(0.0, 0.0), Point.new(4.0, 4.0));
    const dashes = [2]f64{ 5.0, 1.0 };
    const expansion = [_]PathEl{
        PathEl.moveTo(Point.new(0.0, 0.0)),
        PathEl.lineTo(Point.new(4.0, 0.0)),
        PathEl.lineTo(Point.new(4.0, 1.0)),
        PathEl.moveTo(Point.new(4.0, 2.0)),
        PathEl.lineTo(Point.new(4.0, 4.0)),
        PathEl.lineTo(Point.new(1.0, 4.0)),
        PathEl.moveTo(Point.new(0.0, 4.0)),
        PathEl.lineTo(Point.new(0.0, 0.0)),
    };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    var got = try collectElements(allocator, path.elementsSlice(), &dashes, 0.0, true);
    defer got.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expansion.len), got.items.len);
    for (expansion, got.items) |e, g| {
        try std.testing.expectEqualDeep(e, g);
    }
}

test "dash sequence offset" {
    // Same as dash_sequence, but with a dash offset
    // of 3, which skips the first dash and cuts into
    // the first gap.
    const allocator = std.testing.allocator;
    const shape = Line.new(Point.new(0.0, 0.0), Point.new(21.0, 0.0));
    const dashes = [4]f64{ 1.0, 5.0, 2.0, 5.0 };
    const expansion = [3]PathSeg{
        .{ .Line = Line.new(Point.new(3.0, 0.0), Point.new(5.0, 0.0)) },
        .{ .Line = Line.new(Point.new(10.0, 0.0), Point.new(11.0, 0.0)) },
        .{ .Line = Line.new(Point.new(16.0, 0.0), Point.new(18.0, 0.0)) },
    };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    var got = try collectSegments(allocator, path.elementsSlice(), &dashes, 3.0, false);
    defer got.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expansion.len), got.items.len);
    for (expansion, got.items) |e, g| {
        try std.testing.expectEqualDeep(e, g);
    }
}

test "dash stable order multi subpath" {
    // Differently-sized subpaths verify stable mode restarts the dash pattern
    // per subpath without leaking state.
    const allocator = std.testing.allocator;
    var path = BezPath.init();
    defer path.deinit(allocator);
    try path.moveTo(allocator, Point.new(0.0, 0.0));
    try path.lineTo(allocator, Point.new(2.0, 0.0));
    try path.lineTo(allocator, Point.new(2.0, 2.0));
    try path.lineTo(allocator, Point.new(0.0, 2.0));
    try path.closePath(allocator);
    try path.moveTo(allocator, Point.new(10.0, 10.0));
    try path.lineTo(allocator, Point.new(15.0, 10.0));
    try path.lineTo(allocator, Point.new(15.0, 14.0));
    try path.lineTo(allocator, Point.new(10.0, 14.0));
    try path.closePath(allocator);
    const dashes = [2]f64{ 3.0, 1.0 };
    const expansion = [_]PathEl{
        PathEl.moveTo(Point.new(0.0, 0.0)),
        PathEl.lineTo(Point.new(2.0, 0.0)),
        PathEl.lineTo(Point.new(2.0, 1.0)),
        PathEl.moveTo(Point.new(2.0, 2.0)),
        PathEl.lineTo(Point.new(0.0, 2.0)),
        PathEl.lineTo(Point.new(0.0, 1.0)),
        PathEl.moveTo(Point.new(10.0, 10.0)),
        PathEl.lineTo(Point.new(13.0, 10.0)),
        PathEl.moveTo(Point.new(14.0, 10.0)),
        PathEl.lineTo(Point.new(15.0, 10.0)),
        PathEl.lineTo(Point.new(15.0, 12.0)),
        PathEl.moveTo(Point.new(15.0, 13.0)),
        PathEl.lineTo(Point.new(15.0, 14.0)),
        PathEl.lineTo(Point.new(13.0, 14.0)),
        PathEl.moveTo(Point.new(12.0, 14.0)),
        PathEl.lineTo(Point.new(10.0, 14.0)),
        PathEl.lineTo(Point.new(10.0, 13.0)),
        PathEl.moveTo(Point.new(10.0, 12.0)),
        PathEl.lineTo(Point.new(10.0, 10.0)),
    };
    var got = try collectElements(allocator, path.elementsSlice(), &dashes, 0.0, true);
    defer got.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expansion.len), got.items.len);
    for (expansion, got.items) |e, g| {
        try std.testing.expectEqualDeep(e, g);
    }
}

test "dash negative offset" {
    const allocator = std.testing.allocator;
    const shape = Line.new(Point.new(0.0, 0.0), Point.new(28.0, 0.0));
    const dashes = [2]f64{ 4.0, 2.0 };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    var pos = try collectSegments(allocator, path.elementsSlice(), &dashes, 60.0, false);
    defer pos.deinit(allocator);
    var neg = try collectSegments(allocator, path.elementsSlice(), &dashes, -60.0, false);
    defer neg.deinit(allocator);
    try std.testing.expectEqualDeep(pos.items, neg.items);
}

test "dash odd length matches doubled" {
    const allocator = std.testing.allocator;
    const shape = Line.new(Point.new(0.0, 0.0), Point.new(50.0, 0.0));
    const odd = [1]f64{10.0};
    const doubled = [2]f64{ 10.0, 10.0 };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    const offsets = [_]f64{ 0.0, 5.0, 9.0, 10.0, 11.0, 15.0, 20.0, 25.0, 100.0, -7.0 };
    for (offsets) |offset| {
        var from_odd = try collectSegments(allocator, path.elementsSlice(), &odd, offset, false);
        defer from_odd.deinit(allocator);
        var from_doubled = try collectSegments(allocator, path.elementsSlice(), &doubled, offset, false);
        defer from_doubled.deinit(allocator);
        try std.testing.expectEqualDeep(from_odd.items, from_doubled.items);
    }
}

test "dash three element matches doubled" {
    const allocator = std.testing.allocator;
    const shape = Line.new(Point.new(0.0, 0.0), Point.new(200.0, 0.0));
    const three = [3]f64{ 20.0, 10.0, 3.0 };
    const doubled = [6]f64{ 20.0, 10.0, 3.0, 20.0, 10.0, 3.0 };
    var path = try shape.toPath(0.0, allocator);
    defer path.deinit(allocator);
    const offsets = [_]f64{ 0.0, 15.0, 32.0, 33.0, 34.0, 50.0, 66.0, 99.0 };
    for (offsets) |offset| {
        var from_three = try collectSegments(allocator, path.elementsSlice(), &three, offset, false);
        defer from_three.deinit(allocator);
        var from_doubled = try collectSegments(allocator, path.elementsSlice(), &doubled, offset, false);
        defer from_doubled.deinit(allocator);
        try std.testing.expectEqualDeep(from_three.items, from_doubled.items);
    }
}

test "stroke is finite fields" {
    const finite = try Stroke.new(2.0)
        .withMiterLimit(4.0)
        .withDashes(0.0, &.{ 1.0, 2.0 });
    try std.testing.expect(finite.isFinite());

    const non_finite_width = Stroke.new(std.math.inf(f64));
    try std.testing.expect(!non_finite_width.isFinite());

    const non_finite_miter = Stroke.new(2.0).withMiterLimit(std.math.nan(f64));
    try std.testing.expect(!non_finite_miter.isFinite());

    const non_finite_dash_offset = try Stroke.new(2.0)
        .withDashes(-std.math.inf(f64), &.{ 1.0, 2.0 });
    try std.testing.expect(!non_finite_dash_offset.isFinite());

    const non_finite_dash_pattern = try Stroke.new(2.0)
        .withDashes(0.0, &.{ 1.0, std.math.nan(f64) });
    try std.testing.expect(!non_finite_dash_pattern.isFinite());
}

test "stroke is nan fields" {
    const finite = try Stroke.new(2.0)
        .withMiterLimit(4.0)
        .withDashes(0.0, &.{ 1.0, 2.0 });
    try std.testing.expect(!finite.isNan());

    const nan_width = Stroke.new(std.math.nan(f64));
    try std.testing.expect(nan_width.isNan());

    const nan_miter = Stroke.new(2.0).withMiterLimit(std.math.nan(f64));
    try std.testing.expect(nan_miter.isNan());

    const nan_dash_offset = try Stroke.new(2.0).withDashes(std.math.nan(f64), &.{ 1.0, 2.0 });
    try std.testing.expect(nan_dash_offset.isNan());

    const nan_dash_pattern = try Stroke.new(2.0).withDashes(0.0, &.{ 1.0, std.math.nan(f64) });
    try std.testing.expect(nan_dash_pattern.isNan());

    const infinite_width = Stroke.new(std.math.inf(f64));
    try std.testing.expect(!infinite_width.isNan());
}

test "stroke builder and capacity" {
    const built = Stroke.new(3.0)
        .withJoin(.bevel)
        .withStartCap(.square)
        .withEndCap(.butt)
        .withMiterLimit(10.0);
    try std.testing.expectEqual(@as(f64, 3.0), built.width);
    try std.testing.expectEqual(Join.bevel, built.join);
    try std.testing.expectEqual(Cap.square, built.start_cap);
    try std.testing.expectEqual(Cap.butt, built.end_cap);
    try std.testing.expectEqual(@as(f64, 10.0), built.miter_limit);

    // Upstream defaults.
    const default = Stroke.new(1.0);
    try std.testing.expectEqual(Join.round, default.join);
    try std.testing.expectEqual(Cap.round, default.start_cap);
    try std.testing.expectEqual(Cap.round, default.end_cap);
    try std.testing.expectEqual(@as(f64, 4.0), default.miter_limit);
    try std.testing.expectEqual(@as(usize, 0), default.dash_pattern.len);

    // Options builders.
    const opts = StrokeOpts.default.stableDashOrder(true).optLevel(.optimized);
    try std.testing.expect(opts.stable_dash_order);
    try std.testing.expectEqual(StrokeOptLevel.optimized, opts.opt_level);
    try std.testing.expectEqual(StrokeOptLevel.subdivide, StrokeOpts.default.opt_level);
    try std.testing.expect(!StrokeOpts.default.stable_dash_order);

    // The inline capacity is explicit instead of a heap spill.
    const too_long = Stroke.new(1.0).withDashes(0.0, &.{ 1.0, 2.0, 3.0, 4.0, 5.0 });
    try std.testing.expectError(error.DashPatternTooLong, too_long);
}

test "stroke caps produce finite output" {
    const allocator = std.testing.allocator;
    var path = BezPath.init();
    defer path.deinit(allocator);
    try path.moveTo(allocator, Point.new(0.0, 0.0));
    try path.lineTo(allocator, Point.new(10.0, 0.0));
    for ([_]Cap{ .butt, .round, .square }) |cap| {
        const style = Stroke.new(4.0).withCaps(cap);
        var stroked = try stroke(allocator, path.elementsSlice(), &style, &StrokeOpts.default, 0.01);
        defer stroked.deinit(allocator);
        try std.testing.expect(stroked.isFinite());
        try std.testing.expect(!stroked.isEmpty());
    }
}

test "stroke joins produce finite output" {
    const allocator = std.testing.allocator;
    var path = BezPath.init();
    defer path.deinit(allocator);
    try path.moveTo(allocator, Point.new(0.0, 0.0));
    try path.lineTo(allocator, Point.new(10.0, 0.0));
    try path.lineTo(allocator, Point.new(10.0, 10.0));
    for ([_]Join{ .bevel, .miter, .round }) |join| {
        const style = Stroke.new(4.0).withJoin(join);
        var stroked = try stroke(allocator, path.elementsSlice(), &style, &StrokeOpts.default, 0.01);
        defer stroked.deinit(allocator);
        try std.testing.expect(stroked.isFinite());
        try std.testing.expect(!stroked.isEmpty());
    }

    // Clockwise turn exercises the reversed round join.
    var cw = BezPath.init();
    defer cw.deinit(allocator);
    try cw.moveTo(allocator, Point.new(0.0, 0.0));
    try cw.lineTo(allocator, Point.new(10.0, 0.0));
    try cw.lineTo(allocator, Point.new(10.0, -10.0));
    const cw_style = Stroke.new(4.0).withJoin(.round);
    var cw_stroked = try stroke(allocator, cw.elementsSlice(), &cw_style, &StrokeOpts.default, 0.01);
    defer cw_stroked.deinit(allocator);
    try std.testing.expect(cw_stroked.isFinite());
    var has_curve = false;
    for (cw_stroked.elementsSlice()) |el| {
        if (std.meta.activeTag(el) == .CurveTo) has_curve = true;
    }
    try std.testing.expect(has_curve);
}

test "stroke ctx is reusable" {
    const allocator = std.testing.allocator;
    var ctx = StrokeCtx{};
    defer ctx.deinit(allocator);

    var long_path = BezPath.init();
    defer long_path.deinit(allocator);
    try long_path.moveTo(allocator, Point.new(0.0, 0.0));
    try long_path.lineTo(allocator, Point.new(10.0, 0.0));

    var short_path = BezPath.init();
    defer short_path.deinit(allocator);
    try short_path.moveTo(allocator, Point.new(0.0, 0.0));
    try short_path.lineTo(allocator, Point.new(4.0, 0.0));

    const style = Stroke.new(2.0);
    try strokeWith(allocator, long_path.elementsSlice(), &style, &StrokeOpts.default, 0.01, &ctx);
    try std.testing.expect(ctx.output().isFinite());
    try std.testing.expect(ctx.output().boundingBox().maxX() > 9.0);

    // Same context, different path: `reset` must discard the previous output.
    try strokeWith(allocator, short_path.elementsSlice(), &style, &StrokeOpts.default, 0.01, &ctx);
    try std.testing.expect(ctx.output().isFinite());
    // The half-width round cap reaches x = 4 + 1 = 5.
    try std.testing.expect(ctx.output().boundingBox().maxX() < 6.0);
    try std.testing.expect(ctx.output().boundingBox().maxX() > 4.0);
}

test "stroke closed path produces finite output" {
    const allocator = std.testing.allocator;
    var path = BezPath.init();
    defer path.deinit(allocator);
    try path.moveTo(allocator, Point.new(0.0, 0.0));
    try path.lineTo(allocator, Point.new(10.0, 0.0));
    try path.lineTo(allocator, Point.new(10.0, 10.0));
    try path.closePath(allocator);
    const style = Stroke.new(4.0).withJoin(.round).withCaps(.round);
    var stroked = try stroke(allocator, path.elementsSlice(), &style, &StrokeOpts.default, 0.01);
    defer stroked.deinit(allocator);
    try std.testing.expect(stroked.isFinite());
    try std.testing.expect(!stroked.isEmpty());
}

test "offset pathological curves" {
    // This test tries combinations of parameters that have caused problems in
    // the past.
    const allocator = std.testing.allocator;
    const curve = CubicBez.new(
        Point.new(-1236.3746269978635, 152.17981429574826),
        Point.new(-1175.18662093517, 108.04721798590596),
        Point.new(-1152.142883879584, 105.76260301083356),
        Point.new(-1151.842639804639, 105.73040758939104),
    );
    const offset = 3603.7267536453924;
    const accuracy = 0.1;

    var result = BezPath.init();
    defer result.deinit(allocator);
    try offsetCubic(allocator, curve, offset, accuracy, &result);
    try std.testing.expect(result.elements.items.len > 0);
    try std.testing.expect(std.meta.activeTag(result.elements.items[0]) == .MoveTo);

    try offsetCubic(allocator, curve, offset, accuracy, &result);
    try std.testing.expect(result.elements.items.len > 0);
    try std.testing.expect(std.meta.activeTag(result.elements.items[0]) == .MoveTo);
}

test "offset infinite recursion" {
    // Cubic offset that used to trigger infinite recursion.
    const allocator = std.testing.allocator;
    const tolerance: f64 = 0.1;
    const offset: f64 = -0.5;
    const c = CubicBez.new(
        Point.new(1096.2962962962963, 593.90243902439033),
        Point.new(1043.6213991769548, 593.90243902439033),
        Point.new(1030.4526748971193, 593.90243902439033),
        Point.new(1056.7901234567901, 593.90243902439033),
    );

    var result = BezPath.init();
    defer result.deinit(allocator);
    try offsetCubic(allocator, c, offset, tolerance, &result);
    try std.testing.expect(result.isFinite());
}

test "offset cubic simple line" {
    const allocator = std.testing.allocator;
    const cubic = CubicBez.new(
        Point.new(0.0, 0.0),
        Point.new(10.0, 0.0),
        Point.new(20.0, 0.0),
        Point.new(30.0, 0.0),
    );
    var result = BezPath.init();
    defer result.deinit(allocator);
    try offsetCubic(allocator, cubic, 5.0, 1e-6, &result);
    try std.testing.expect(result.isFinite());
}
