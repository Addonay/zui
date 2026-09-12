//! Port of vello_common flatten.rs + flatten_simd.rs (Apache-2.0 OR MIT).
//!
//! Flattening of filled paths into f32 line segments, including the culling
//! heuristics, the f64 quadratic subdivision, and the f32 cubic-to-quads
//! subdivision of `flatten_simd.rs`.
//!
//! Numeric conventions: upstream's scalar `fearless_simd` backend
//! (`Level::fallback`, the byte-exact oracle variant) implements `mul_add` as
//! a separate multiply and add, and Zig's default float mode does not contract
//! it into an FMA, so `mulAdd` below is a plain multiply plus add. The cubic
//! path is a scalar transcription of the f32x8 code with the exact same
//! operation order, lane layout, and accumulations; SIMD acceleration is
//! deferred.
//!
//! `stroke`/`expandStroke` need the kurbo `Stroke`/`StrokeCtx` port
//! (Milestone 2) and return `error.Unsupported`; no approximation is used.
//!
//! Ownership: `FlattenCtx.flattened_cubics` is heap-backed. Every function
//! that can grow it takes an explicit allocator; release it with
//! `FlattenCtx.deinit`. `Line`/`Point` are plain values.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const geometry = @import("geometry.zig");
const simd = @import("../simd/root.zig");

/// The hardcoded (squared) flattening tolerance: `0.5 * 0.5`.
pub const SQRT_TOL: f64 = 0.5;
/// `SQRT_TOL` squared. Since `sqrt` is not available in const contexts
/// upstream hardcodes the squared tolerance and derives the others.
pub const TOL: f64 = SQRT_TOL * SQRT_TOL;
/// `TOL` squared, used to compare squared distances without a `sqrt`.
pub const TOL_2: f64 = TOL * TOL;

/// Tile height in pixels.
///
/// Mirrors `tile.Tile.HEIGHT`, duplicated here because `tile.zig` imports
/// this module for `Line` and a mutual import would create a dependency
/// cycle. `tile.zig` asserts the two agree.
pub const TILE_HEIGHT: u16 = 4;

/// A point with `f32` coordinates (upstream `flatten::Point`).
pub const Point = struct {
    /// The x coordinate.
    x: f32,
    /// The y coordinate.
    y: f32,

    /// The point `(0, 0)`.
    pub const ZERO: Point = .{ .x = 0.0, .y = 0.0 };

    /// Create a new point.
    pub inline fn new(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    /// Upstream `From<kurbo::Point>`: round to the nearest `f32`.
    pub inline fn fromKurbo(value: kurbo.Point) Point {
        return .{ .x = @floatCast(value.x), .y = @floatCast(value.y) };
    }
};

/// A line with `f32` endpoints (upstream `flatten::Line`).
pub const Line = struct {
    /// The start point of the line.
    p0: Point,
    /// The end point of the line.
    p1: Point,

    /// Create a new line.
    pub inline fn new(p0: Point, p1: Point) Line {
        return .{ .p0 = p0, .p1 = p1 };
    }
};

/// The element of a path made of lines (upstream `flatten_simd::LinePathEl`).
///
/// Each subpath must start with a `move_to`. Closing of subpaths is not
/// supported here, and subpaths are not closed implicitly when a new subpath
/// (with `move_to`) is started: it is expected that closed subpaths are
/// watertight, i.e. the last `line_to` matches the first `move_to` exactly.
/// This intentionally allows non-watertight subpaths because, e.g., lines
/// fully outside of the viewport do not need to be drawn.
pub const LinePathEl = union(enum) {
    /// Start a new subpath at the point.
    move_to: kurbo.Point,
    /// Draw a line to the point.
    line_to: kurbo.Point,
};

/// Upstream `flatten_simd::Callback`.
///
/// Upstream uses a trait so that the callback can be inlined; Zig has no
/// trait objects, so this is an explicit vtable. Unlike upstream, `call` can
/// fail because the sink owns heap storage and Zig errors must be explicit.
pub const Callback = struct {
    /// The callback receiver.
    ctx: *anyopaque,
    /// The callback implementation; erased over the receiver.
    call_fn: *const fn (ctx: *anyopaque, el: LinePathEl) anyerror!void,

    /// Invoke the callback.
    pub inline fn call(self: Callback, el: LinePathEl) anyerror!void {
        return self.call_fn(self.ctx, el);
    }
};

/// The number of quads a cubic is split into at most.
pub const MAX_QUADS: usize = 16;

/// An `f32` point used internally by the flattener (upstream `Point32`).
const Point32 = struct {
    x: f32,
    y: f32,
};

/// The context needed for flattening curves (upstream `FlattenCtx`).
///
/// The arrays are scratch space reused across calls; `flattened_cubics` is
/// owned heap storage that grows on demand and is released with `deinit`.
pub const FlattenCtx = struct {
    /// The +4 is to encourage alignment; might be better to be explicit.
    even_pts: [MAX_QUADS + 4]Point32,
    /// Odd evaluated points of the cubic.
    odd_pts: [MAX_QUADS]Point32,
    /// Per-quad parabola integral at the start.
    a0: [MAX_QUADS]f32,
    /// Per-quad difference of parabola integrals.
    da: [MAX_QUADS]f32,
    /// Per-quad inverse integral at the start.
    u0: [MAX_QUADS]f32,
    /// Per-quad inverse-integral scale.
    uscale: [MAX_QUADS]f32,
    /// The number of `subdivisions * 2 * sqrt_tol`.
    val: [MAX_QUADS]f32,
    /// The number of quads in the current cubic.
    n_quads: usize,
    /// Reusable buffer for flattened cubic points. Owned; caller frees with
    /// `deinit` using the allocator passed to `fill`.
    flattened_cubics: std.ArrayList(Point32),

    /// Create a zeroed context. Does not allocate.
    pub fn init() FlattenCtx {
        return .{
            .even_pts = @splat(Point32{ .x = 0.0, .y = 0.0 }),
            .odd_pts = @splat(Point32{ .x = 0.0, .y = 0.0 }),
            .a0 = @splat(0.0),
            .da = @splat(0.0),
            .u0 = @splat(0.0),
            .uscale = @splat(0.0),
            .val = @splat(0.0),
            .n_quads = 0,
            .flattened_cubics = .empty,
        };
    }

    /// Release the owned point buffer. `allocator` must be the allocator that
    /// was passed to the `fill` calls that grew this context.
    pub fn deinit(self: *FlattenCtx, allocator: std.mem.Allocator) void {
        self.flattened_cubics.deinit(allocator);
        self.* = undefined;
    }
};

/// The sink used by `fill` (upstream `FlattenerCallback`).
pub const FlattenerCallback = struct {
    /// Appended-to line buffer, borrowed from the caller.
    line_buf: *std.ArrayList(Line),
    /// Allocator backing `line_buf` growth.
    allocator: std.mem.Allocator,
    /// Start point of the current subpath.
    start: Point = Point.ZERO,
    /// Current point.
    p0: Point = Point.ZERO,
    /// Whether any emitted point was NaN.
    is_nan: bool = false,

    /// Process one line-path element.
    pub fn callback(self: *FlattenerCallback, el: LinePathEl) !void {
        switch (el) {
            .move_to => |p| {
                self.is_nan = self.is_nan or p.isNan();

                const pf = Point.fromKurbo(p);
                self.start = pf;
                self.p0 = pf;
            },
            .line_to => |p| {
                self.is_nan = self.is_nan or p.isNan();

                const pf = Point.fromKurbo(p);
                try self.line_buf.append(self.allocator, Line.new(self.p0, pf));
                self.p0 = pf;
            },
        }
    }

    /// Erase this sink into the `Callback` interface.
    pub fn asCallback(self: *FlattenerCallback) Callback {
        return .{ .ctx = self, .call_fn = callErased };
    }

    fn callErased(ctx: *anyopaque, el: LinePathEl) anyerror!void {
        const self: *FlattenerCallback = @ptrCast(@alignCast(ctx));
        return self.callback(el);
    }
};

/// Flatten a filled Bézier path into line segments.
///
/// See the note about open subpaths and culling on upstream `fill`: open
/// subpaths are closed by connecting the last endpoint to the starting point,
/// and lines may be culled where they cannot affect coverage or winding.
///
/// `line_buf` is cleared first. `cull_bbox` is in scene pixels. `allocator` is
/// only used to grow `ctx.flattened_cubics`; `level` selects the (future) SIMD
/// backend and is currently unused.
pub fn fill(
    allocator: std.mem.Allocator,
    level: simd.Level,
    path: []const kurbo.PathEl,
    affine: kurbo.Affine,
    line_buf: *std.ArrayList(Line),
    ctx: *FlattenCtx,
    cull_bbox: geometry.RectU16,
) !void {
    try fillImpl(allocator, level, path, affine, line_buf, ctx, cull_bbox);
}

/// Flatten a filled Bézier path into line segments (upstream `fill_impl`).
///
/// See the note about open subpaths and culling on [`fill`]. This is the
/// backend-generic entry point; the port has a single portable backend.
pub fn fillImpl(
    allocator: std.mem.Allocator,
    level: simd.Level,
    path: []const kurbo.PathEl,
    affine: kurbo.Affine,
    line_buf: *std.ArrayList(Line),
    flatten_ctx: *FlattenCtx,
    cull_bbox: geometry.RectU16,
) !void {
    line_buf.clearRetainingCapacity();
    var lb = FlattenerCallback{ .line_buf = line_buf, .allocator = allocator };

    try flattenPath(allocator, level, path, affine, lb.asCallback(), flatten_ctx, cull_bbox);

    // A path that contains NaN is ill-defined, so ignore it.
    if (lb.is_nan) {
        std.log.warn("A path contains NaN, ignoring it.", .{});
        line_buf.clearRetainingCapacity();
    }
}

/// Flatten a stroked Bézier path into line segments.
///
/// Port of upstream `flatten::stroke`: expands the stroke with
/// `kurbo.strokeWith` at a tolerance scaled by the transform, then flattens
/// the expanded path as a fill.
pub fn stroke(
    allocator: std.mem.Allocator,
    level: simd.Level,
    path: []const kurbo.PathEl,
    style: *const kurbo.Stroke,
    affine: kurbo.Affine,
    line_buf: *std.ArrayList(Line),
    flatten_ctx: *FlattenCtx,
    stroke_ctx: *kurbo.StrokeCtx,
    cull_bbox: geometry.RectU16,
) !void {
    // Upstream: tolerance = TOL / max(|a|, |d|, 1).
    const coeffs = affine.c;
    const tolerance = TOL / @max(@max(@abs(coeffs[0]), @abs(coeffs[3])), 1.0);

    try expandStroke(allocator, path, style, tolerance, stroke_ctx);
    try fill(
        allocator,
        level,
        stroke_ctx.output().elements.items,
        affine,
        line_buf,
        flatten_ctx,
        cull_bbox,
    );
}

/// Expand a stroked path to a filled path (upstream `flatten::expand_stroke`).
pub fn expandStroke(
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    style: *const kurbo.Stroke,
    tolerance: f64,
    stroke_ctx: *kurbo.StrokeCtx,
) !void {
    const opts = kurbo.StrokeOpts{};
    try kurbo.strokeWith(allocator, path, style, &opts, tolerance, stroke_ctx);
}

/// See the docs for the kurbo implementation of flattening:
/// <https://docs.rs/kurbo/latest/kurbo/fn.flatten.html>
///
/// This version works with the same approach as upstream's f32x4/f32x8 SIMD
/// implementation; the port keeps the identical operation order and per-lane
/// math in scalar form. `callback` receives `move_to`/`line_to` elements.
pub fn flattenPath(
    allocator: std.mem.Allocator,
    level: simd.Level,
    path: []const kurbo.PathEl,
    affine: kurbo.Affine,
    callback: Callback,
    flatten_ctx: *FlattenCtx,
    cull_bbox: geometry.RectU16,
) !void {
    flatten_ctx.flattened_cubics.clearRetainingCapacity();

    // For the culling performed here to be correct, the top y coordinate of
    // the cull bbox must be aligned to strip row boundaries (upstream
    // comment kept in full in flatten_simd.rs; see `TILE_HEIGHT`).
    const left: f64 = @floatFromInt(cull_bbox.x0);
    const top: f64 = @floatFromInt((cull_bbox.y0 / TILE_HEIGHT) * TILE_HEIGHT);
    const right: f64 = @floatFromInt(cull_bbox.x1);
    const bottom: f64 = @floatFromInt(cull_bbox.y1);

    if (path.len == 0) return;

    const first_el = path[0].transform(affine);
    const start_pt = switch (first_el) {
        .MoveTo => |p| p,
        else => {
            std.debug.assert(false); // upstream debug_assert! + return
            return;
        },
    };

    var start_pt_var = start_pt;
    var last_pt = start_pt;
    try callback.call(.{ .move_to = start_pt });

    for (path[1..]) |el| {
        switch (el.transform(affine)) {
            .MoveTo => |p| {
                if (pointNe(last_pt, start_pt_var)) {
                    try callback.call(.{ .line_to = start_pt_var });
                }
                last_pt = p;
                start_pt_var = p;
                try callback.call(.{ .move_to = p });
            },
            .LineTo => |p| {
                last_pt = p;
                try callback.call(.{ .line_to = p });
            },
            .QuadTo => |q| {
                const p0 = last_pt;
                const p1 = q.p1;
                const p2 = q.p2;
                const line = kurbo.Line.new(p0, p2);
                // Fully right, above, or below the culling bbox: no coverage
                // or winding impact; conservatively tested with the control
                // hull.
                if ((p0.x > right and p1.x > right and p2.x > right) or
                    (p0.y < top and p1.y < top and p2.y < top) or
                    (p0.y > bottom and p1.y > bottom and p2.y > bottom))
                {
                    try callback.call(.{ .move_to = p2 });
                }
                // Fully left: may affect winding but not shape, so emit the
                // chord. Otherwise: if the control point is within 2*TOL of
                // the chord, the curve itself is within 1/2 of that (i.e.
                // TOL), so the chord is accurate enough.
                else if ((p0.x < left and p1.x < left and p2.x < left) or
                    line.nearest(p1, 0.0).distance_sq <= 4.0 * TOL_2)
                {
                    try callback.call(.{ .line_to = p2 });
                } else {
                    const quad = kurbo.QuadBez.new(p0, p1, p2);
                    const params = quad.estimateSubdiv(SQRT_TOL);
                    const n = @max(kurbo.common.ceilToUsizeMin1(0.5 / SQRT_TOL * params.val), 1);
                    const step = 1.0 / @as(f64, @floatFromInt(n));
                    var i: usize = 1;
                    while (i < n) : (i += 1) {
                        const u = @as(f64, @floatFromInt(i)) * step;
                        const t = quad.determineSubdivT(&params, u);
                        try callback.call(.{ .line_to = quad.eval(t) });
                    }
                    try callback.call(.{ .line_to = p2 });
                }
                last_pt = p2;
            },
            .CurveTo => |c| {
                const p0 = last_pt;
                const p1 = c.p1;
                const p2 = c.p2;
                const p3 = c.p3;
                const line = kurbo.Line.new(p0, p3);
                // Fully right, above, or below the culling bbox.
                if ((p0.x > right and p1.x > right and p2.x > right and p3.x > right) or
                    (p0.y < top and p1.y < top and p2.y < top and p3.y < top) or
                    (p0.y > bottom and p1.y > bottom and p2.y > bottom and p3.y > bottom))
                {
                    try callback.call(.{ .move_to = p3 });
                }
                // Fully left, or within 3/4 * max(control distances) of the
                // chord (which bounds the curve's distance at 3/4 of the
                // control-point distance, squared compared against
                // (4/3*TOL)^2 = 16/9 * TOL_2).
                else if ((p0.x < left and p1.x < left and p2.x < left and p3.x < left) or
                    @max(
                        line.nearest(p1, 0.0).distance_sq,
                        line.nearest(p2, 0.0).distance_sq,
                    ) <= 16.0 / 9.0 * TOL_2)
                {
                    try callback.call(.{ .line_to = p3 });
                } else {
                    const cubic = kurbo.CubicBez.new(p0, p1, p2, p3);
                    const max = try flattenCubic(allocator, level, cubic, flatten_ctx);

                    for (flatten_ctx.flattened_cubics.items[1..max]) |p| {
                        try callback.call(.{
                            .line_to = kurbo.Point.new(p.x, p.y),
                        });
                    }
                }
                last_pt = p3;
            },
            .ClosePath => {
                if (pointNe(last_pt, start_pt_var)) {
                    try callback.call(.{ .line_to = start_pt_var });

                    // Kurbo says: "If `quad_to` [or another drawing op] is
                    // called immediately after `close_path` then the current
                    // subpath starts at the initial point of the previous
                    // subpath." Hence `last_pt` goes back to `start_pt`.
                    last_pt = start_pt_var;
                }
            },
        }
    }

    if (pointNe(last_pt, start_pt_var)) {
        try callback.call(.{ .line_to = start_pt_var });
    }
}

/// `kurbo::Point != kurbo::Point` semantics (NaN compares unequal).
inline fn pointNe(a: kurbo.Point, b: kurbo.Point) bool {
    return !(a.x == b.x and a.y == b.y);
}

/// Multiply-add with upstream's scalar-fallback semantics: a separate
/// multiply, then an add. Zig's strict float mode does not contract this.
inline fn mulAdd(a: f32, b: f32, c: f32) f32 {
    const product = a * b;
    return product + c;
}

/// An approximation to `integral (1 + 4x^2)^-0.25 dx`, f32 version of
/// [`kurbo.QuadBez.estimateSubdiv`]'s helper (upstream
/// `approx_parabola_integral_simd`).
fn approxParabolaIntegralF32(x: f32) f32 {
    const D: f32 = 0.67;
    const D_POWI_4: f32 = 0.201_511_2;

    const temp = @sqrt(@sqrt(mulAdd(x * x, 0.25, D_POWI_4)));
    const denom = temp + (1.0 - D);
    return x / denom;
}

/// An approximation to the inverse parabola integral, f32 version (upstream
/// `approx_parabola_inv_integral_simd`).
fn approxParabolaInvIntegralF32(x: f32) f32 {
    const B: f32 = 0.39;
    const ONE_MINUS_B: f32 = 1.0 - B;

    const temp = @sqrt(mulAdd(x * x, 0.25, B * B));
    const factor = ONE_MINUS_B + temp;
    return x * factor;
}

/// Evaluate the cubic polynomial given by `coeff_a*t^3 + coeff_b*t^2 +
/// coeff_c*t + coeff_d` using Horner's method, exactly as the upstream SIMD
/// loop does.
inline fn evalCubic1d(coeff_a: f32, coeff_b: f32, coeff_c: f32, coeff_d: f32, t: f32) f32 {
    return mulAdd(mulAdd(mulAdd(coeff_a, t, coeff_b), t, coeff_c), t, coeff_d);
}

/// Evaluate the cubic at evenly spaced `t` values and store the points in
/// `even_pts`/`odd_pts` (upstream `eval_cubics_simd`).
///
/// The upstream f32x8 iteration evaluates four points per step with `t` values
/// `[4i, 4i+2, 4i+1, 4i+3] * dt`; the low half is stored in `even_pts` and the
/// high half in `odd_pts`, so `even_pts[k] = eval(2k*dt)` and
/// `odd_pts[k] = eval((2k+1)*dt)`. `t` is accumulated, not recomputed, to
/// match the SIMD rounding exactly.
fn evalCubics(c: kurbo.CubicBez, n: usize, result: *FlattenCtx) void {
    result.n_quads = n;
    const dt: f32 = 0.5 / @as(f32, @floatFromInt(n));

    const p0x: f32 = @floatCast(c.p0.x);
    const p0y: f32 = @floatCast(c.p0.y);
    const p1x: f32 = @floatCast(c.p1.x);
    const p1y: f32 = @floatCast(c.p1.y);
    const p2x: f32 = @floatCast(c.p2.x);
    const p2y: f32 = @floatCast(c.p2.y);
    const p3x: f32 = @floatCast(c.p3.x);
    const p3y: f32 = @floatCast(c.p3.y);

    const coeff_a_x = mulAdd(p1x - p2x, 3.0, p3x - p0x);
    const coeff_b_x = mulAdd(p1x, -2.0, p0x + p2x) * 3.0;
    const coeff_c_x = (p1x - p0x) * 3.0;
    const coeff_d_x = p0x;
    const coeff_a_y = mulAdd(p1y - p2y, 3.0, p3y - p0y);
    const coeff_b_y = mulAdd(p1y, -2.0, p0y + p2y) * 3.0;
    const coeff_c_y = (p1y - p0y) * 3.0;
    const coeff_d_y = p0y;

    // Lane order of the upstream iota: [0, 0, 2, 2, 1, 1, 3, 3].
    const iota = [4]f32{ 0.0, 2.0, 1.0, 3.0 };
    var t: [4]f32 = undefined;
    inline for (0..4) |lane| t[lane] = iota[lane] * dt;
    const t_inc = 4.0 * dt;

    var i: usize = 0;
    while (i < (n + 1) / 2) : (i += 1) {
        const px = [4]f32{
            evalCubic1d(coeff_a_x, coeff_b_x, coeff_c_x, coeff_d_x, t[0]),
            evalCubic1d(coeff_a_x, coeff_b_x, coeff_c_x, coeff_d_x, t[1]),
            evalCubic1d(coeff_a_x, coeff_b_x, coeff_c_x, coeff_d_x, t[2]),
            evalCubic1d(coeff_a_x, coeff_b_x, coeff_c_x, coeff_d_x, t[3]),
        };
        const py = [4]f32{
            evalCubic1d(coeff_a_y, coeff_b_y, coeff_c_y, coeff_d_y, t[0]),
            evalCubic1d(coeff_a_y, coeff_b_y, coeff_c_y, coeff_d_y, t[1]),
            evalCubic1d(coeff_a_y, coeff_b_y, coeff_c_y, coeff_d_y, t[2]),
            evalCubic1d(coeff_a_y, coeff_b_y, coeff_c_y, coeff_d_y, t[3]),
        };

        // low half -> even_pts (points 2i, 2i+1), high half -> odd_pts.
        result.even_pts[2 * i] = .{ .x = px[0], .y = py[0] };
        result.even_pts[2 * i + 1] = .{ .x = px[1], .y = py[1] };
        result.odd_pts[2 * i] = .{ .x = px[2], .y = py[2] };
        result.odd_pts[2 * i + 1] = .{ .x = px[3], .y = py[3] };

        inline for (0..4) |lane| t[lane] += t_inc;
    }

    // `p3_128.store_slice(&mut even_pts[n * 2..][..8])`: four copies of the
    // f32-converted end point starting at point index `n`.
    inline for (0..4) |k| {
        result.even_pts[n + k] = .{ .x = p3x, .y = p3y };
    }
}

/// Compute per-quad subdivision parameters (upstream `estimate_subdiv_simd`).
///
/// The scalar transcription keeps the upstream lane naming: the low SIMD lanes
/// hold `d12`-derived values but are bound to the names `x0`/`a0`/`u0`, and
/// the high lanes hold the `d01`-derived `x2`/`a2`/`u2`. All downstream uses
/// are consistently swapped, so this is faithful, not a reinterpretation.
fn estimateSubdiv(sqrt_tol: f32, ctx: *FlattenCtx) void {
    const n = ctx.n_quads;

    var i: usize = 0;
    while (i < (n + 3) / 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            const idx = i * 4 + j;
            const p0 = ctx.even_pts[idx];
            const p_half = ctx.odd_pts[idx];
            const p2 = ctx.even_pts[idx + 1];

            const x = p0.x * -0.5;
            const y = p0.y * -0.5;
            const p1 = Point32{
                .x = mulAdd(p2.x, -0.5, mulAdd(p_half.x, 2.0, x)),
                .y = mulAdd(p2.y, -0.5, mulAdd(p_half.y, 2.0, y)),
            };
            ctx.odd_pts[idx] = p1;

            const d01x = p1.x - p0.x;
            const d01y = p1.y - p0.y;
            const d12x = p2.x - p1.x;
            const d12y = p2.y - p1.y;
            const ddx = d01x - d12x;
            const ddy = d01y - d12y;
            const d02x = d01x + d12x;
            const d02y = d01y + d12y;
            // cross = ddx * (-d02y) + d02x * ddy
            const cross = mulAdd(ddx, -d02y, d02x * ddy);

            // Low lanes: d12-derived numerator (upstream binding `x0`).
            // High lanes: d01-derived numerator (upstream binding `x2`).
            const x0_num = mulAdd(d12y, ddy, d12x * ddx);
            const x2_num = mulAdd(d01y, ddy, d01x * ddx);
            const x0 = x0_num / cross;
            const x2 = x2_num / cross;

            const dd_hypot = @sqrt(mulAdd(ddy, ddy, ddx * ddx));
            const scale_denom = dd_hypot * (x2 - x0);
            const scale = @abs(cross / scale_denom);

            const a0 = approxParabolaIntegralF32(x0);
            const a2 = approxParabolaIntegralF32(x2);
            const da = a2 - a0;
            const da_abs = @abs(da);
            const sqrt_scale = @sqrt(scale);

            // mask = (x0 | x2) >= 0, computed on the bit patterns like
            // upstream's integer `simd_ge_i32x4` (so -0.0 counts as negative).
            const bits: u32 = @as(u32, @bitCast(x0)) | @as(u32, @bitCast(x2));
            const non_cusp = bits < 0x8000_0000;

            const noncusp_val = da_abs * sqrt_scale;
            const xmin = sqrt_tol / sqrt_scale;
            const approxint = approxParabolaIntegralF32(xmin);
            const cusp_val = (sqrt_tol * da_abs) / approxint;
            const val_raw = if (non_cusp) noncusp_val else cusp_val;
            const val = if (std.math.isFinite(val_raw)) val_raw else 0.0;

            const u0_val = approxParabolaInvIntegralF32(a0);
            const u2_val = approxParabolaInvIntegralF32(a2);
            const uscale_a = u2_val - u0_val;
            const uscale = 1.0 / uscale_a;

            ctx.a0[idx] = a0;
            ctx.da[idx] = da;
            ctx.u0[idx] = u0_val;
            ctx.uscale[idx] = uscale;
            ctx.val[idx] = val;
        }
    }
}

/// Output `n_points` subdivision points of quad `i` into `flattened_cubics`
/// (upstream `output_lines_simd`).
fn outputLines(
    ctx: *FlattenCtx,
    i: usize,
    x0: f32,
    dx: f32,
    n_points: usize,
    start_idx: usize,
) void {
    const p0 = ctx.even_pts[i];
    const p1 = ctx.odd_pts[i];
    const p2 = ctx.even_pts[i + 1];

    // Lane order of the upstream IOTA2: [0, 0, 1, 1, 2, 2, 3, 3].
    const iota2 = [4]f32{ 0.0, 1.0, 2.0, 3.0 };
    const da = ctx.da[i];
    const a0 = ctx.a0[i];
    var a: [4]f32 = undefined;
    inline for (0..4) |lane| {
        const x = mulAdd(iota2[lane], dx, x0);
        a[lane] = mulAdd(da, x, a0);
    }
    const a_inc = 4.0 * dx * da;
    const uscale = ctx.uscale[i];
    const u0_scalar = ctx.u0[i];

    const coeff_a_x = mulAdd(p1.x, -2.0, p0.x) + p2.x;
    const coeff_b_x = (p1.x - p0.x) * 2.0;
    const coeff_c_x = p0.x;
    const coeff_a_y = mulAdd(p1.y, -2.0, p0.y) + p2.y;
    const coeff_b_y = (p1.y - p0.y) * 2.0;
    const coeff_c_y = p0.y;

    var j: usize = 0;
    while (j < (n_points + 3) / 4) : (j += 1) {
        inline for (0..4) |k| {
            const u = approxParabolaInvIntegralF32(a[k]);
            const t = (u - u0_scalar) * uscale;
            const px = mulAdd(mulAdd(coeff_a_x, t, coeff_b_x), t, coeff_c_x);
            const py = mulAdd(mulAdd(coeff_a_y, t, coeff_b_y), t, coeff_c_y);
            ctx.flattened_cubics.items[start_idx + j * 4 + k] = .{ .x = px, .y = py };
        }
        inline for (0..4) |k| a[k] += a_inc;
    }
}

// ---------------------------------------------------------------------------
// `@Vector` backend (upstream `flatten_simd.rs` f32x8 paths)
// ---------------------------------------------------------------------------

const F32x4 = simd.F32x4;
const F32x8 = simd.F32x8;
const I32x4 = simd.I32x4;
const U32x4 = simd.U32x4;

/// `f32x8::block_splat` of the `index`-th point of an interleaved
/// `[x0, y0, x1, y1]` vector, i.e. `[x, y, x, y, x, y, x, y]` (upstream
/// `split_single` followed by `block_splat`).
inline fn pointSplatF32x4(v: F32x4, comptime index: usize) F32x8 {
    const x = v[index * 2];
    const y = v[index * 2 + 1];
    return .{ x, y, x, y, x, y, x, y };
}

/// `pt_splat_simd`: an `(x, y)` pair repeated four times.
inline fn pointSplat(p: Point32) F32x8 {
    return .{ p.x, p.y, p.x, p.y, p.x, p.y, p.x, p.y };
}

inline fn splat8(value: f32) F32x8 {
    return @splat(value);
}

/// SIMD version of [`approxParabolaIntegralF32`], generic over the vector
/// width (upstream `approx_parabola_integral_simd` is generic over
/// `SimdFloat`).
inline fn approxParabolaIntegralSimd(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const D: f32 = 0.67;
    const D_POWI_4: f32 = 0.201_511_2;

    const temp = @sqrt(@sqrt(simd.mulAddUnfused(
        x * x,
        @as(V, @splat(0.25)),
        @as(V, @splat(D_POWI_4)),
    )));
    return x / (temp + @as(V, @splat(1.0 - D)));
}

/// SIMD version of [`approxParabolaInvIntegralF32`], generic over the vector
/// width (upstream `approx_parabola_inv_integral_simd`).
inline fn approxParabolaInvIntegralSimd(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const B: f32 = 0.39;
    const temp = @sqrt(simd.mulAddUnfused(
        x * x,
        @as(V, @splat(0.25)),
        @as(V, @splat(B * B)),
    ));
    return x * (@as(V, @splat(1.0 - B)) + temp);
}

/// Upstream `is_finite_simd`: `|x|`'s bit pattern below infinity.
inline fn isFiniteSimd(x: F32x4) simd.Mask32x4 {
    const bits: U32x4 = @bitCast(@abs(x));
    return bits < @as(U32x4, @splat(0x7f80_0000));
}

/// Load four interleaved `(x, y)` points into an `f32x8`.
inline fn loadPoints(points: []const Point32) F32x8 {
    std.debug.assert(points.len >= 4);
    var out: F32x8 = undefined;
    inline for (0..4) |k| {
        out[2 * k] = points[k].x;
        out[2 * k + 1] = points[k].y;
    }
    return out;
}

/// Store four interleaved `(x, y)` points from an `f32x8`.
inline fn storePoints(dest: []Point32, v: F32x8) void {
    std.debug.assert(dest.len >= 4);
    inline for (0..4) |k| {
        dest[k] = .{ .x = v[2 * k], .y = v[2 * k + 1] };
    }
}

/// Upstream `eval_cubics_simd`: evaluate the cubic at four `t` values per
/// iteration.
///
/// Lane `k` of the `f32x8` evaluates one coordinate of point `k`; the lane
/// order `[0, 0, 2, 2, 1, 1, 3, 3]` and the `t` accumulation match upstream,
/// so every lane performs the same operation sequence as the scalar
/// transcription.
fn evalCubicsVector(c: kurbo.CubicBez, n: usize, result: *FlattenCtx) void {
    result.n_quads = n;
    const dt: f32 = 0.5 / @as(f32, @floatFromInt(n));

    const p0p1: F32x4 = .{
        @floatCast(c.p0.x),
        @floatCast(c.p0.y),
        @floatCast(c.p1.x),
        @floatCast(c.p1.y),
    };
    const p2p3: F32x4 = .{
        @floatCast(c.p2.x),
        @floatCast(c.p2.y),
        @floatCast(c.p3.x),
        @floatCast(c.p3.y),
    };

    const p0_128 = pointSplatF32x4(p0p1, 0);
    const p1_128 = pointSplatF32x4(p0p1, 1);
    const p2_128 = pointSplatF32x4(p2p3, 0);
    const p3_128 = pointSplatF32x4(p2p3, 1);

    // Horner coefficients, exactly as upstream `eval_cubics_simd`.
    const coeff_a = simd.mulAddUnfused(p1_128 - p2_128, splat8(3.0), p3_128 - p0_128);
    const coeff_b = simd.mulAddUnfused(p1_128, splat8(-2.0), p0_128 + p2_128) * splat8(3.0);
    const coeff_c = (p1_128 - p0_128) * splat8(3.0);
    const coeff_d = p0_128;

    const iota: F32x8 = .{ 0.0, 0.0, 2.0, 2.0, 1.0, 1.0, 3.0, 3.0 };
    var t = iota * splat8(dt);
    const t_inc = splat8(4.0 * dt);

    var i: usize = 0;
    while (i < (n + 1) / 2) : (i += 1) {
        const evaluated = simd.mulAddUnfused(
            simd.mulAddUnfused(
                simd.mulAddUnfused(coeff_a, t, coeff_b),
                t,
                coeff_c,
            ),
            t,
            coeff_d,
        );

        const parts = simd.splitF32x8(evaluated);
        // Low half -> even points 2i, 2i+1; high half -> odd points 2i, 2i+1.
        result.even_pts[2 * i] = .{ .x = parts[0][0], .y = parts[0][1] };
        result.even_pts[2 * i + 1] = .{ .x = parts[0][2], .y = parts[0][3] };
        result.odd_pts[2 * i] = .{ .x = parts[1][0], .y = parts[1][1] };
        result.odd_pts[2 * i + 1] = .{ .x = parts[1][2], .y = parts[1][3] };

        t += t_inc;
    }

    // `p3_128.store_slice(&mut even_pts[n * 2..][..8])`: the endpoint fills
    // points `n..n+4`.
    const p3x: f32 = @floatCast(c.p3.x);
    const p3y: f32 = @floatCast(c.p3.y);
    inline for (0..4) |k| {
        result.even_pts[n + k] = .{ .x = p3x, .y = p3y };
    }
}

/// Upstream `estimate_subdiv_simd`: four quads per iteration.
///
/// The low four lanes carry the `d12`-derived values upstream binds to
/// `x0`/`a0`/`u0`; the high four lanes carry the `d01`-derived
/// `x2`/`a2`/`u2`. This is the same (deliberate) lane naming as the scalar
/// transcription, which the upstream `unzip`/`combine` lane order produces.
fn estimateSubdivVector(sqrt_tol: f32, ctx: *FlattenCtx) void {
    const n = ctx.n_quads;

    var i: usize = 0;
    while (i < (n + 3) / 4) : (i += 1) {
        const p0 = loadPoints(ctx.even_pts[4 * i ..][0..4]);
        const p_half = loadPoints(ctx.odd_pts[4 * i ..][0..4]);
        const p2 = loadPoints(ctx.even_pts[4 * i + 1 ..][0..4]);

        const x = p0 * splat8(-0.5);
        const x1 = simd.mulAddUnfused(p_half, splat8(2.0), x);
        const p1 = simd.mulAddUnfused(p2, splat8(-0.5), x1);
        storePoints(ctx.odd_pts[4 * i ..], p1);

        const d01 = p1 - p0;
        const d12 = p2 - p1;
        const d01x = simd.unzipLowF32x8Wide(d01, d01);
        const d01y = simd.unzipHighF32x8Wide(d01, d01);
        const d12x = simd.unzipLowF32x8Wide(d12, d12);
        const d12y = simd.unzipHighF32x8Wide(d12, d12);
        const ddx = d01x - d12x;
        const ddy = d01y - d12y;
        const d02x = d01x + d12x;
        const d02y = d01y + d12y;
        // `(d02x * ddy) - (d02y * ddx)`, as `mul_add(-d02y, ddx)`.
        const cross = simd.mulAddUnfused(ddx, -d02y, d02x * ddy);

        const ddx_low = simd.splitF32x8(ddx)[0];
        const ddy_low = simd.splitF32x8(ddy)[0];
        const d12x_low = simd.splitF32x8(d12x)[0];
        const d01x_low = simd.splitF32x8(d01x)[0];
        const d12y_low = simd.splitF32x8(d12y)[0];
        const d01y_low = simd.splitF32x8(d01y)[0];

        const x0_x2_a = simd.combineF32x4(d12x_low, d01x_low) * ddx;
        const x0_x2_num = simd.mulAddUnfused(
            simd.combineF32x4(d12y_low, d01y_low),
            ddy,
            x0_x2_a,
        );
        const x0_x2 = x0_x2_num / cross;
        const dd_hypot = @sqrt(simd.mulAddUnfused(ddy_low, ddy_low, ddx_low * ddx_low));

        const x0_x2_parts = simd.splitF32x8(x0_x2);
        const x0 = x0_x2_parts[0];
        const x2 = x0_x2_parts[1];
        const scale_denom = dd_hypot * (x2 - x0);
        const cross_low = simd.splitF32x8(cross)[0];
        const scale = @abs(cross_low / scale_denom);

        const a0_a2 = approxParabolaIntegralSimd(x0_x2);
        const a_parts = simd.splitF32x8(a0_a2);
        const a0 = a_parts[0];
        const a2 = a_parts[1];
        const da = a2 - a0;
        const da_abs = @abs(da);
        const sqrt_scale = @sqrt(scale);

        // `mask = (x0 | x2) >= 0` on the raw bit patterns (so `-0.0` counts
        // as negative), exactly like the integer SIMD comparison upstream.
        const bits = @as(I32x4, @bitCast(x0)) | @as(I32x4, @bitCast(x2));
        const non_cusp = bits >= @as(I32x4, @splat(0));

        const noncusp_val = da_abs * sqrt_scale;
        const xmin = @as(F32x4, @splat(sqrt_tol)) / sqrt_scale;
        const approxint = approxParabolaIntegralSimd(xmin);
        const cusp_val = (@as(F32x4, @splat(sqrt_tol)) * da_abs) / approxint;
        const val_raw = simd.select(F32x4, non_cusp, noncusp_val, cusp_val);
        const val = simd.select(F32x4, isFiniteSimd(val_raw), val_raw, @as(F32x4, @splat(0.0)));

        const u0_u2 = approxParabolaInvIntegralSimd(a0_a2);
        const u_parts = simd.splitF32x8(u0_u2);
        const u0_val = u_parts[0];
        const u2_val = u_parts[1];
        const uscale = @as(F32x4, @splat(1.0)) / (u2_val - u0_val);

        ctx.a0[4 * i ..][0..4].* = a0;
        ctx.da[4 * i ..][0..4].* = da;
        ctx.u0[4 * i ..][0..4].* = u0_val;
        ctx.uscale[4 * i ..][0..4].* = uscale;
        ctx.val[4 * i ..][0..4].* = val;
    }
}

/// Upstream `output_lines_simd`: emit `n_points` subdivision points of quad
/// `i` into `flattened_cubics`.
fn outputLinesVector(
    ctx: *FlattenCtx,
    i: usize,
    x0: f32,
    dx: f32,
    n_points: usize,
    start_idx: usize,
) void {
    const p0 = pointSplat(ctx.even_pts[i]);
    const p1 = pointSplat(ctx.odd_pts[i]);
    const p2 = pointSplat(ctx.even_pts[i + 1]);

    // Lane order of the upstream IOTA2: [0, 0, 1, 1, 2, 2, 3, 3].
    const iota2: F32x8 = .{ 0.0, 0.0, 1.0, 1.0, 2.0, 2.0, 3.0, 3.0 };
    const x = simd.mulAddUnfused(iota2, splat8(dx), splat8(x0));
    const a_start = simd.mulAddUnfused(splat8(ctx.da[i]), x, splat8(ctx.a0[i]));
    const a_inc = splat8(4.0 * dx * ctx.da[i]);
    const uscale = splat8(ctx.uscale[i]);
    const u0_vec = splat8(ctx.u0[i]);

    const coeff_a = simd.mulAddUnfused(p1, splat8(-2.0), p0) + p2;
    const coeff_b = (p1 - p0) * splat8(2.0);
    const coeff_c = p0;

    var a = a_start;
    var j: usize = 0;
    while (j < (n_points + 3) / 4) : (j += 1) {
        const u = approxParabolaInvIntegralSimd(a);
        const t = (u - u0_vec) * uscale;
        const p = simd.mulAddUnfused(
            simd.mulAddUnfused(coeff_a, t, coeff_b),
            t,
            coeff_c,
        );
        storePoints(ctx.flattened_cubics.items[start_idx + j * 4 ..], p);
        a += a_inc;
    }
}

/// Flatten a cubic into `ctx.flattened_cubics`, returning the number of
/// entries (including the start point) that are valid.
///
/// Upstream `flatten_cubic_simd`, dispatched per [`simd.Level`]: `fallback`
/// runs the scalar transcription, every vector level the `@Vector` backend.
/// Both produce bit-identical results (the differential test below asserts
/// this for every level).
fn flattenCubic(
    allocator: std.mem.Allocator,
    level: simd.Level,
    c: kurbo.CubicBez,
    ctx: *FlattenCtx,
) !usize {
    return simd.dispatch(CubicBackends, level, .{ allocator, c, ctx });
}

/// Per-level cubic flattening backends (`fearless_simd::dispatch!` shape).
const CubicBackends = struct {
    pub fn fallback(
        allocator: std.mem.Allocator,
        c: kurbo.CubicBez,
        ctx: *FlattenCtx,
    ) !usize {
        return flattenCubicScalar(allocator, c, ctx);
    }

    pub fn vector(
        allocator: std.mem.Allocator,
        c: kurbo.CubicBez,
        ctx: *FlattenCtx,
    ) !usize {
        return flattenCubicVector(allocator, c, ctx);
    }
};

/// Scalar transcription of upstream `flatten_cubic_simd` (the `fallback`
/// backend).
fn flattenCubicScalar(
    allocator: std.mem.Allocator,
    c: kurbo.CubicBez,
    ctx: *FlattenCtx,
) !usize {
    const n_quads = estimateNumQuads(c, @floatCast(TOL));
    evalCubics(c, n_quads, ctx);
    const tol: f32 = @as(f32, @floatCast(TOL)) * (1.0 - TO_QUAD_TOL);
    const sqrt_tol: f32 = @sqrt(tol);
    estimateSubdiv(sqrt_tol, ctx);

    return flattenCubicTail(allocator, ctx, n_quads, sqrt_tol, outputLines);
}

/// `@Vector` backend of upstream `flatten_cubic_simd`: the same operation
/// order per lane as [`flattenCubicScalar`], evaluated four points at a time
/// with `f32x8`.
fn flattenCubicVector(
    allocator: std.mem.Allocator,
    c: kurbo.CubicBez,
    ctx: *FlattenCtx,
) !usize {
    const n_quads = estimateNumQuads(c, @floatCast(TOL));
    evalCubicsVector(c, n_quads, ctx);
    const tol: f32 = @as(f32, @floatCast(TOL)) * (1.0 - TO_QUAD_TOL);
    const sqrt_tol: f32 = @sqrt(tol);
    estimateSubdivVector(sqrt_tol, ctx);

    return flattenCubicTail(allocator, ctx, n_quads, sqrt_tol, outputLinesVector);
}

/// The backend-independent scheduling tail of `flatten_cubic_simd`: sum the
/// per-quad subdivision values (sequentially and in lane order, exactly like
/// upstream's `iter().sum()`), size the output buffer, and emit the quads
/// through `output`.
fn flattenCubicTail(
    allocator: std.mem.Allocator,
    ctx: *FlattenCtx,
    n_quads: usize,
    sqrt_tol: f32,
    comptime output: fn (*FlattenCtx, usize, f32, f32, usize, usize) void,
) !usize {
    var sum: f32 = 0.0;
    for (ctx.val[0..n_quads]) |v| sum += v;

    const n_raw = f32CeilToUsize(@ceil(0.5 * sum / sqrt_tol));
    const n = @max(n_raw, 1);
    const target_len = std.math.add(usize, n, 4) catch return error.OutOfMemory;
    if (target_len > ctx.flattened_cubics.items.len) {
        const old_len = ctx.flattened_cubics.items.len;
        try ctx.flattened_cubics.resize(allocator, target_len);
        @memset(ctx.flattened_cubics.items[old_len..], Point32{ .x = 0.0, .y = 0.0 });
    }

    const step = sum / @as(f32, @floatFromInt(n));
    const step_recip = 1.0 / step;
    var val_sum: f32 = 0.0;
    var last_n: usize = 0;
    var x0base: f32 = 0.0;

    var i: usize = 0;
    while (i < n_quads) : (i += 1) {
        const val = ctx.val[i];
        val_sum += val;
        const this_n = val_sum * step_recip;
        const this_n_next = 1.0 + @floor(this_n);
        const this_n_next_idx = f32ToUsizeSat(this_n_next);
        const dn = this_n_next_idx -| last_n;
        if (dn > 0) {
            const dx = step / val;
            const x0 = x0base * dx;
            output(ctx, i, x0, dx, dn, last_n);
        }
        x0base = this_n_next - this_n;
        last_n = this_n_next_idx;
    }

    ctx.flattened_cubics.items[n] = ctx.even_pts[n_quads];

    return n + 1;
}

/// The proportion of the tolerance budget spent on cubic-to-quadratic
/// conversion (upstream `TO_QUAD_TOL`).
const TO_QUAD_TOL: f32 = 0.1;

/// Upstream `estimate_num_quads`: convert `accuracy` into the number of
/// quadratic segments for the cubic.
fn estimateNumQuads(c: kurbo.CubicBez, accuracy: f32) usize {
    const q_accuracy: f64 = @floatCast(accuracy * TO_QUAD_TOL);
    const max_hypot2 = 432.0 * q_accuracy * q_accuracy;
    const p1x2 = c.p1.toVec2().mulScalar(3.0).sub(c.p0.toVec2());
    const p2x2 = c.p2.toVec2().mulScalar(3.0).sub(c.p3.toVec2());
    const err = p2x2.sub(p1x2).hypot2();
    const err_div = err / max_hypot2;

    return estimate(err_div);
}

/// Upstream `estimate`: the lookup-table form of
/// `(err_div.powf(1/6).ceil() as usize).max(1).min(MAX_QUADS)`.
fn estimate(err_div: f64) usize {
    const LUT: [MAX_QUADS]f64 = .{
        1.0,       64.0,      729.0,      4096.0,
        15625.0,   46656.0,   117649.0,   262144.0,
        531441.0,  1000000.0, 1771561.0,  2985984.0,
        4826809.0, 7529536.0, 11390625.0, 16777216.0,
    };

    for (LUT, 0..) |threshold, i| {
        if (err_div <= threshold) return i + 1;
    }
    return MAX_QUADS;
}

/// Rust `f32 as usize` semantics: truncate, saturate, NaN becomes 0.
fn f32ToUsizeSat(x: f32) usize {
    if (std.math.isNan(x) or x <= 0.0) return 0;
    const max: f32 = @floatFromInt(std.math.maxInt(usize));
    if (x >= max) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// Rust `x.ceil() as usize` semantics (without the `.max(1)`).
fn f32CeilToUsize(x: f32) usize {
    return f32ToUsizeSat(@ceil(x));
}

// ---------------------------------------------------------------------------
// Tests. Upstream `flatten.rs`/`flatten_simd.rs` has a single (`#[ignore]`d)
// test for `estimate`; the `fill` behavior tests below are added for the port.
// ---------------------------------------------------------------------------

test "estimate matches old_estimate on sampled f32" {
    const testing = std.testing;

    // Upstream iterates all u32 bit patterns and is `#[ignore]`d for runtime
    // (and because `powf` rounds differently at exact bucket boundaries). The
    // port pins the LUT contract at the boundaries and allows a one-step
    // difference from the powf estimate elsewhere.
    const LUT = [MAX_QUADS]f64{
        1.0,       64.0,      729.0,      4096.0,
        15625.0,   46656.0,   117649.0,   262144.0,
        531441.0,  1000000.0, 1771561.0,  2985984.0,
        4826809.0, 7529536.0, 11390625.0, 16777216.0,
    };
    for (LUT, 0..) |threshold, i| {
        try testing.expectEqual(i + 1, estimate(threshold));
        try testing.expectEqual(i + 1, estimate(std.math.nextAfter(f64, threshold, 0.0)));
    }

    var i: u32 = 0;
    while (i < 0x1_0000) : (i += 1) {
        const x: f32 = @floatFromInt(i);
        if (std.math.isFinite(x)) {
            try expectEstimateClose(oldEstimate(@floatCast(x)), estimate(@floatCast(x)));
        }
    }
    i = 0;
    while (i < std.math.maxInt(u32) - 977) : (i += 977) {
        const x: f32 = @bitCast(i);
        if (std.math.isFinite(x)) {
            try expectEstimateClose(oldEstimate(@floatCast(x)), estimate(@floatCast(x)));
        }
    }
}

fn expectEstimateClose(old: usize, new: usize) !void {
    const diff = @max(old, new) - @min(old, new);
    if (diff > 1) {
        std.debug.print("estimate mismatch: old={} new={}\n", .{ old, new });
        return error.TestUnexpectedResult;
    }
}

fn oldEstimate(err_div: f64) usize {
    const n_quads = kurbo.common.ceilToUsizeMin1(std.math.pow(f64, err_div, 1.0 / 6.0));
    return @min(n_quads, MAX_QUADS);
}

test "fill each path element type" {
    const testing = std.testing;
    const a = testing.allocator;

    var line_buf: std.ArrayList(Line) = .empty;
    defer line_buf.deinit(a);
    var ctx = FlattenCtx.init();
    defer ctx.deinit(a);
    const bbox = geometry.RectU16.new(0, 0, 100, 100);

    // MoveTo + LineTo + implicit close.
    {
        const path = [_]kurbo.PathEl{
            kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
            kurbo.PathEl.lineTo(kurbo.Point.new(10.0, 0.0)),
        };
        try fill(a, .baseline, &path, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
        try testing.expectEqual(@as(usize, 2), line_buf.items.len);
        try testing.expectEqual(Line.new(.{ .x = 0.0, .y = 0.0 }, .{ .x = 10.0, .y = 0.0 }), line_buf.items[0]);
        try testing.expectEqual(Line.new(.{ .x = 10.0, .y = 0.0 }, .{ .x = 0.0, .y = 0.0 }), line_buf.items[1]);
    }

    // Explicit ClosePath does not duplicate the implicit close.
    {
        const path = [_]kurbo.PathEl{
            kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
            kurbo.PathEl.lineTo(kurbo.Point.new(10.0, 0.0)),
            kurbo.PathEl.closePath(),
        };
        try fill(a, .baseline, &path, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
        try testing.expectEqual(@as(usize, 2), line_buf.items.len);
    }

    // MoveTo to a new subpath closes the previous one.
    {
        const path = [_]kurbo.PathEl{
            kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
            kurbo.PathEl.lineTo(kurbo.Point.new(10.0, 0.0)),
            kurbo.PathEl.moveTo(kurbo.Point.new(20.0, 0.0)),
            kurbo.PathEl.lineTo(kurbo.Point.new(20.0, 10.0)),
        };
        try fill(a, .baseline, &path, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
        try testing.expectEqual(@as(usize, 4), line_buf.items.len);
        try testing.expectEqual(Line.new(.{ .x = 10.0, .y = 0.0 }, .{ .x = 0.0, .y = 0.0 }), line_buf.items[1]);
        try testing.expectEqual(Line.new(.{ .x = 20.0, .y = 0.0 }, .{ .x = 20.0, .y = 10.0 }), line_buf.items[2]);
    }

    // QuadTo subdivides (at least the end point is emitted).
    {
        const path = [_]kurbo.PathEl{
            kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
            kurbo.PathEl.quadTo(kurbo.Point.new(50.0, 100.0), kurbo.Point.new(100.0, 0.0)),
        };
        try fill(a, .baseline, &path, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
        try testing.expect(line_buf.items.len > 2);
        const last = line_buf.items[line_buf.items.len - 2];
        try testing.expectEqual(@as(f32, 100.0), last.p1.x);
        try testing.expectEqual(@as(f32, 0.0), last.p1.y);
        // The implicit close is the final line.
        try testing.expectEqual(@as(f32, 0.0), line_buf.items[line_buf.items.len - 1].p1.x);
    }

    // CurveTo subdivides and ends exactly at the f32 end point.
    {
        const path = [_]kurbo.PathEl{
            kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
            kurbo.PathEl.curveTo(
                kurbo.Point.new(10.0, 30.0),
                kurbo.Point.new(40.0, 30.0),
                kurbo.Point.new(50.0, 0.0),
            ),
        };
        try fill(a, .baseline, &path, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
        try testing.expect(line_buf.items.len > 3);
        const before_close = line_buf.items[line_buf.items.len - 2];
        try testing.expectEqual(@as(f32, 50.0), before_close.p1.x);
        try testing.expectEqual(@as(f32, 0.0), before_close.p1.y);
    }

    // An empty path clears the buffer and emits nothing.
    {
        try fill(a, .baseline, &[_]kurbo.PathEl{}, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
        try testing.expectEqual(@as(usize, 0), line_buf.items.len);
    }

    // Note: a non-empty path whose first element is not `MoveTo` trips the
    // upstream `debug_assert` and returns; that path is not exercised here
    // because the port keeps the assertion.
}

test "fill applies affine and culls" {
    const testing = std.testing;
    const a = testing.allocator;

    var line_buf: std.ArrayList(Line) = .empty;
    defer line_buf.deinit(a);
    var ctx = FlattenCtx.init();
    defer ctx.deinit(a);

    // Line segments are never culled by `fill` (only quads/cubics are); a
    // triangle fully translated outside the cull bbox still emits its lines.
    const path = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(10.0, 0.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(0.0, 10.0)),
        kurbo.PathEl.closePath(),
    };
    const far = kurbo.Affine.translate(kurbo.Vec2.new(1000.0, 1000.0));
    try fill(
        a,
        .baseline,
        &path,
        far,
        &line_buf,
        &ctx,
        geometry.RectU16.new(0, 0, 100, 100),
    );
    try testing.expectEqual(@as(usize, 3), line_buf.items.len);
    try testing.expectEqual(@as(f32, 1000.0), line_buf.items[0].p0.x);
    try testing.expectEqual(@as(f32, 1010.0), line_buf.items[0].p1.x);

    // A cubic fully outside on the right is reduced to a MoveTo.
    const culled_curve = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(500.0, 10.0)),
        kurbo.PathEl.curveTo(
            kurbo.Point.new(510.0, 20.0),
            kurbo.Point.new(520.0, 30.0),
            kurbo.Point.new(530.0, 40.0),
        ),
    };
    try fill(
        a,
        .baseline,
        &culled_curve,
        kurbo.Affine.IDENTITY,
        &line_buf,
        &ctx,
        geometry.RectU16.new(0, 0, 100, 100),
    );
    // `MoveTo(p3)` then the implicit close to the subpath start point.
    try testing.expectEqual(@as(usize, 1), line_buf.items.len);
    try testing.expectEqual(@as(f32, 530.0), line_buf.items[0].p0.x);
    try testing.expectEqual(@as(f32, 500.0), line_buf.items[0].p1.x);

    // A quad fully left of the viewport is flattened to its chord.
    const left_curve = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(-500.0, 10.0)),
        kurbo.PathEl.quadTo(kurbo.Point.new(-510.0, 60.0), kurbo.Point.new(-520.0, 20.0)),
    };
    try fill(
        a,
        .baseline,
        &left_curve,
        kurbo.Affine.IDENTITY,
        &line_buf,
        &ctx,
        geometry.RectU16.new(0, 0, 100, 100),
    );
    try testing.expectEqual(@as(usize, 2), line_buf.items.len);
    try testing.expectEqual(@as(f32, -520.0), line_buf.items[0].p1.x);
}

test "fill drops paths containing NaN" {
    const testing = std.testing;
    const a = testing.allocator;

    var line_buf: std.ArrayList(Line) = .empty;
    defer line_buf.deinit(a);
    var ctx = FlattenCtx.init();
    defer ctx.deinit(a);
    const nan = std.math.nan(f64);
    const path = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(nan, 10.0)),
    };
    try fill(
        a,
        .baseline,
        &path,
        kurbo.Affine.IDENTITY,
        &line_buf,
        &ctx,
        geometry.RectU16.new(0, 0, 100, 100),
    );
    try testing.expectEqual(@as(usize, 0), line_buf.items.len);
}

test "fill reuses the context across calls" {
    const testing = std.testing;
    const a = testing.allocator;

    var line_buf: std.ArrayList(Line) = .empty;
    defer line_buf.deinit(a);
    var ctx = FlattenCtx.init();
    defer ctx.deinit(a);
    const bbox = geometry.RectU16.new(0, 0, 100, 100);

    const curve = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(0.0, 0.0)),
        kurbo.PathEl.curveTo(
            kurbo.Point.new(10.0, 90.0),
            kurbo.Point.new(90.0, 90.0),
            kurbo.Point.new(100.0, 0.0),
        ),
    };
    try fill(a, .baseline, &curve, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
    const first_len = line_buf.items.len;
    try testing.expect(first_len > 2);

    try fill(a, .baseline, &curve, kurbo.Affine.IDENTITY, &line_buf, &ctx, bbox);
    try testing.expectEqual(first_len, line_buf.items.len);
}

test "vector cubic flattening is bit-identical to the scalar fallback" {
    const testing = std.testing;
    const a = testing.allocator;

    const levels = [_]simd.Level{
        .fallback, .baseline, .sse2, .sse4_2, .avx2, .avx512, .neon, .wasm_simd128,
    };

    var reference: std.ArrayList(Line) = .empty;
    defer reference.deinit(a);
    var candidate: std.ArrayList(Line) = .empty;
    defer candidate.deinit(a);
    var ctx = FlattenCtx.init();
    defer ctx.deinit(a);

    const bbox = geometry.RectU16.new(0, 0, 256, 256);
    var prng = std.Random.DefaultPrng.init(0x5eed_5eed);
    const random = prng.random();

    var elements: [4]kurbo.PathEl = undefined;
    var iter: usize = 0;
    while (iter < 512) : (iter += 1) {
        if (iter < 3) {
            // Fixed shapes: a shallow curve (one quad), a deep curve (many
            // quads), and a cubic with an off-screen endpoint (culling).
            const fixed = [3][4]kurbo.Point{
                .{
                    kurbo.Point.new(0.0, 0.0),
                    kurbo.Point.new(10.0, 1.0),
                    kurbo.Point.new(20.0, 1.0),
                    kurbo.Point.new(30.0, 0.0),
                },
                .{
                    kurbo.Point.new(0.0, 0.0),
                    kurbo.Point.new(10.0, 90.0),
                    kurbo.Point.new(90.0, 90.0),
                    kurbo.Point.new(100.0, 0.0),
                },
                .{
                    kurbo.Point.new(-500.0, 20.0),
                    kurbo.Point.new(-400.0, 600.0),
                    kurbo.Point.new(400.0, -600.0),
                    kurbo.Point.new(500.0, 30.0),
                },
            };
            const pts = fixed[iter];
            elements[0] = kurbo.PathEl.moveTo(pts[0]);
            elements[1] = kurbo.PathEl.curveTo(pts[1], pts[2], pts[3]);
            if (iter == 2) {
                // A second subpath exercises context reuse within one call.
                elements[2] = kurbo.PathEl.moveTo(kurbo.Point.new(150.0, 150.0));
                elements[3] = kurbo.PathEl.curveTo(
                    kurbo.Point.new(160.0, 10.0),
                    kurbo.Point.new(200.0, 250.0),
                    kurbo.Point.new(210.0, 160.0),
                );
            } else {
                elements[2] = kurbo.PathEl.lineTo(kurbo.Point.new(0.0, 0.0));
                elements[3] = kurbo.PathEl.closePath();
            }
        } else {
            const x0 = random.float(f32) * 300.0 - 50.0;
            const y0 = random.float(f32) * 300.0 - 50.0;
            elements[0] = kurbo.PathEl.moveTo(kurbo.Point.new(x0, y0));
            elements[1] = kurbo.PathEl.curveTo(
                kurbo.Point.new(random.float(f32) * 400.0 - 100.0, random.float(f32) * 400.0 - 100.0),
                kurbo.Point.new(random.float(f32) * 400.0 - 100.0, random.float(f32) * 400.0 - 100.0),
                kurbo.Point.new(
                    x0 + random.float(f32) * 300.0 - 150.0,
                    y0 + random.float(f32) * 300.0 - 150.0,
                ),
            );
            elements[2] = kurbo.PathEl.lineTo(kurbo.Point.new(x0, y0));
            elements[3] = kurbo.PathEl.closePath();
        }

        const affine = if (iter % 2 == 0)
            kurbo.Affine.IDENTITY
        else
            kurbo.Affine.scale(0.75).thenTranslate(kurbo.Vec2.new(11.25, -4.5));

        for (levels, 0..) |level, li| {
            const out = if (li == 0) &reference else &candidate;
            try fill(a, level, &elements, affine, out, &ctx, bbox);
            if (li != 0) {
                try testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(reference.items),
                    std.mem.sliceAsBytes(candidate.items),
                );
            }
        }
    }
}

test "stroke expands and flattens a line" {
    const testing = std.testing;
    var line_buf: std.ArrayList(Line) = .empty;
    defer line_buf.deinit(testing.allocator);
    var ctx = FlattenCtx.init();
    defer ctx.deinit(testing.allocator);
    var stroke_ctx: kurbo.StrokeCtx = .{};
    defer stroke_ctx.deinit(testing.allocator);

    const path = [_]kurbo.PathEl{
        .{ .MoveTo = kurbo.Point.new(0.0, 0.0) },
        .{ .LineTo = kurbo.Point.new(10.0, 0.0) },
    };
    const style = kurbo.Stroke.new(2.0);
    try stroke(
        testing.allocator,
        .baseline,
        &path,
        &style,
        kurbo.Affine.IDENTITY,
        &line_buf,
        &ctx,
        &stroke_ctx,
        geometry.RectU16.new(0, 0, 16, 16),
    );
    // A horizontal segment with butt caps expands to a rectangle: at least
    // one quad (four edges) after flattening.
    try testing.expect(line_buf.items.len >= 4);

    // An empty path expands to nothing and does not fail.
    line_buf.clearRetainingCapacity();
    try stroke(
        testing.allocator,
        .baseline,
        &[_]kurbo.PathEl{},
        &style,
        kurbo.Affine.IDENTITY,
        &line_buf,
        &ctx,
        &stroke_ctx,
        geometry.RectU16.new(0, 0, 16, 16),
    );
    try testing.expectEqual(@as(usize, 0), line_buf.items.len);
}
