//! Port of gpui/src/path_builder.rs: collects exact contours (lines, quadratic
//! and cubic Beziers, elliptical arcs) and emits closed chains of xy-monotone
//! quadratic `PathCurve`s via `Outline` for analytical winding rendering.
const std = @import("std");
const geometry = @import("geometry.zig");
const path_winding = @import("path_winding.zig");
const scene = @import("scene.zig");
const testing = std.testing;

const Point = geometry.Point;
const Pixels = geometry.Pixels;
const Path = scene.Path;
const PathCurve = path_winding.PathCurve;

/// Tolerance for treating cross products and distances as zero.
const epsilon: f32 = 1e-6;
/// Maximum cubic-to-quadratic approximation error in logical pixels (GPUI `TOLERANCE`).
const cubic_tolerance: f32 = 0.25;
/// Stroke flattening tolerance in logical pixels (`0.25 / STROKE_RESOLUTION_SCALE`).
const stroke_tolerance: f32 = 0.125;

/// How a fill decides what is inside.
pub const FillRule = enum { non_zero, even_odd };

pub const FillOptions = struct {
    fill_rule: FillRule = .even_odd,
};

/// Shape of the ends of open subpaths and dashes (GPUI `LineCap`).
pub const LineCap = enum { butt, square, round };

/// Shape of corners between stroke segments (GPUI `LineJoin`).
pub const LineJoin = enum { miter, miter_clip, round, bevel };

pub const StrokeOptions = struct {
    /// Full width of the stroke in logical pixels.
    line_width: Pixels = 1,
    /// Shape of the ends of open subpaths and dashes.
    line_cap: LineCap = .butt,
    /// Shape of corners.
    line_join: LineJoin = .miter,
    /// How long a miter join may get, as a multiple of the line width, before it is beveled instead.
    miter_limit: f32 = 4.0,
};

/// Whether a builder produces a filled or a stroked path.
pub const PathStyle = union(enum) {
    stroke: StrokeOptions,
    fill: FillOptions,
};

/// A 2D affine transform: `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub fn translation(x: f32, y: f32) Transform {
        return .{ .e = x, .f = y };
    }

    pub fn scale(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }

    /// Rotation by `radians`.
    pub fn rotation(radians: f32) Transform {
        const cos = @cos(radians);
        const sin = @sin(radians);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }

    /// Returns the transform that applies `self` first and then `other`.
    pub fn then(self: Transform, other: Transform) Transform {
        return .{
            .a = other.a * self.a + other.c * self.b,
            .b = other.b * self.a + other.d * self.b,
            .c = other.a * self.c + other.c * self.d,
            .d = other.b * self.c + other.d * self.d,
            .e = other.a * self.e + other.c * self.f + other.e,
            .f = other.b * self.e + other.d * self.f + other.f,
        };
    }

    pub fn apply(self: Transform, p: Point(Pixels)) Point(Pixels) {
        return .{
            .x = self.a * p.x + self.c * p.y + self.e,
            .y = self.b * p.x + self.d * p.y + self.f,
        };
    }
};

/// A path's contours as closed chains of xy-monotone quadratic curves (GPUI `Outline`).
pub const Outline = struct {
    allocator: std.mem.Allocator,
    curves: std.ArrayList(PathCurve) = .empty,
    start: Point(f32) = .{},
    current: Point(f32) = .{},
    has_contour: bool = false,
    non_finite: bool = false,

    pub fn init(allocator: std.mem.Allocator) Outline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Outline) void {
        self.curves.deinit(self.allocator);
    }

    fn accepts(self: *Outline, pts: []const Point(f32)) bool {
        for (pts) |pt| {
            if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) {
                self.non_finite = true;
                return false;
            }
        }
        return !self.non_finite;
    }

    /// Close the current contour and start a new one at `to`.
    pub fn move_to(self: *Outline, to: Point(f32)) !void {
        if (!self.accepts(&.{to})) return;
        if (self.has_contour) try self.close();
        self.start = to;
        self.current = to;
        self.has_contour = true;
    }

    pub fn line_to(self: *Outline, to: Point(f32)) !void {
        if (!self.accepts(&.{to})) return;
        if (!self.has_contour) {
            self.start = .{ .x = 0, .y = 0 };
            self.current = .{ .x = 0, .y = 0 };
            self.has_contour = true;
        }
        if (to.x != self.current.x or to.y != self.current.y) {
            try self.curves.append(self.allocator, PathCurve.line(self.current, to));
            self.current = to;
        }
    }

    pub fn curve_to(self: *Outline, to: Point(f32), ctrl: Point(f32)) !void {
        if (!self.accepts(&.{ to, ctrl })) return;
        if (!self.has_contour) {
            self.start = .{ .x = 0, .y = 0 };
            self.current = .{ .x = 0, .y = 0 };
            self.has_contour = true;
        }
        if (to.x == self.current.x and to.y == self.current.y and ctrl.x == self.current.x and ctrl.y == self.current.y) {
            return;
        }
        try PathCurve.push_monotone(&self.curves, self.allocator, self.current, ctrl, to);
        self.current = to;
    }

    pub fn cubic_to(self: *Outline, to: Point(f32), ctrl1: Point(f32), ctrl2: Point(f32)) !void {
        if (!self.accepts(&.{ to, ctrl1, ctrl2 })) return;
        if (!self.has_contour) {
            self.start = .{ .x = 0, .y = 0 };
            self.current = .{ .x = 0, .y = 0 };
            self.has_contour = true;
        }
        try self.subdivide_cubic(self.current, ctrl1, ctrl2, to, 0);
    }

    fn subdivide_cubic(
        self: *Outline,
        p0: Point(f32),
        c1: Point(f32),
        c2: Point(f32),
        p3: Point(f32),
        depth: u8,
    ) !void {
        // Midpoint quadratic approximation error bound: |p3 - 3*c2 + 3*c1 - p0| / (12 * sqrt(3)).
        const dx = p3.x - 3.0 * c2.x + 3.0 * c1.x - p0.x;
        const dy = p3.y - 3.0 * c2.y + 3.0 * c1.y - p0.y;
        const err_sq = (dx * dx + dy * dy) / 432.0;
        if (err_sq <= cubic_tolerance * cubic_tolerance or depth >= 12) {
            const q_ctrl: Point(f32) = .{
                .x = (3.0 * (c1.x + c2.x) - (p0.x + p3.x)) * 0.25,
                .y = (3.0 * (c1.y + c2.y) - (p0.y + p3.y)) * 0.25,
            };
            try self.curve_to(p3, q_ctrl);
            return;
        }
        const m01 = midpoint(p0, c1);
        const m12 = midpoint(c1, c2);
        const m23 = midpoint(c2, p3);
        const m012 = midpoint(m01, m12);
        const m123 = midpoint(m12, m23);
        const mid = midpoint(m012, m123);
        try self.subdivide_cubic(p0, m01, m012, mid, depth + 1);
        try self.subdivide_cubic(mid, m123, m23, p3, depth + 1);
    }

    /// Close the current contour with a straight line back to its start.
    pub fn close(self: *Outline) !void {
        if (!self.has_contour) return;
        const start_pt = self.start;
        try self.line_to(start_pt);
    }

    /// Returns the curves with every contour closed; consumes `self`.
    pub fn into_curves(self: *Outline) ![]PathCurve {
        if (self.non_finite) {
            self.curves.deinit(self.allocator);
            self.curves = .empty;
            return error.NonFinitePoint;
        }
        try self.close();
        return self.curves.toOwnedSlice(self.allocator);
    }
};

fn midpoint(a: Point(f32), b: Point(f32)) Point(f32) {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

const Segment = union(enum) {
    line: Point(Pixels),
    quad: struct { ctrl: Point(Pixels), to: Point(Pixels) },
    cubic: struct { ctrl1: Point(Pixels), ctrl2: Point(Pixels), to: Point(Pixels) },
};

const Contour = struct {
    start: Point(Pixels) = .{},
    current: Point(Pixels) = .{},
    segments: std.ArrayList(Segment) = .empty,
    closed: bool = false,
};

/// Builds a `Path` from move/line/curve commands using exact monotone quadratic outlines.
pub const PathBuilder = struct {
    allocator: std.mem.Allocator,
    contours: std.ArrayList(Contour) = .empty,
    // Named with a trailing underscore because `transform` is also the GPUI method that sets it.
    transform_: ?Transform = null,
    style: PathStyle,
    dash_array_: std.ArrayList(Pixels) = .empty,

    /// Creates a builder for a filled path.
    pub fn fill(allocator: std.mem.Allocator) PathBuilder {
        return .{ .allocator = allocator, .style = .{ .fill = .{} } };
    }

    /// Creates a builder for a stroked path of the given width.
    pub fn stroke(allocator: std.mem.Allocator, width: Pixels) PathBuilder {
        return .{ .allocator = allocator, .style = .{ .stroke = .{ .line_width = width } } };
    }

    /// Releases the builder without building it. `build` releases it as well.
    pub fn deinit(self: *PathBuilder) void {
        for (self.contours.items) |*contour| contour.segments.deinit(self.allocator);
        self.contours.deinit(self.allocator);
        self.dash_array_.deinit(self.allocator);
    }

    pub fn with_style(self: *PathBuilder, style: PathStyle) *PathBuilder {
        self.style = style;
        return self;
    }

    /// Sets the stroke dash pattern. An odd-length pattern is repeated to even length, as in SVG.
    pub fn dash_array_set(self: *PathBuilder, pattern: []const Pixels) !void {
        self.dash_array_.clearRetainingCapacity();
        try self.dash_array_.appendSlice(self.allocator, pattern);
        if (pattern.len % 2 == 1) try self.dash_array_.appendSlice(self.allocator, pattern);
    }

    /// Sets the dash array of the builder (GPUI `PathBuilder::dash_array`).
    pub fn dash_array(self: *PathBuilder, pattern: []const Pixels) *PathBuilder {
        self.dash_array_set(pattern) catch @panic("out of memory");
        return self;
    }

    /// Starts a new sub-path at `to`.
    pub fn move_to(self: *PathBuilder, to: Point(Pixels)) !void {
        try self.contours.append(self.allocator, .{
            .start = to,
            .current = to,
        });
    }

    /// Draws a straight line from the current point to `to`.
    pub fn line_to(self: *PathBuilder, to: Point(Pixels)) !void {
        const contour = try self.open_contour();
        try contour.segments.append(self.allocator, .{ .line = to });
        contour.current = to;
    }

    /// Draws a quadratic Bezier from the current point to `to` with control point `ctrl`.
    pub fn curve_to(self: *PathBuilder, to: Point(Pixels), ctrl: Point(Pixels)) !void {
        const contour = try self.open_contour();
        try contour.segments.append(self.allocator, .{ .quad = .{ .ctrl = ctrl, .to = to } });
        contour.current = to;
    }

    /// Draws a cubic Bezier from the current point to `to` with two control points.
    pub fn cubic_bezier_to(self: *PathBuilder, to: Point(Pixels), control_a: Point(Pixels), control_b: Point(Pixels)) !void {
        const contour = try self.open_contour();
        try contour.segments.append(self.allocator, .{ .cubic = .{ .ctrl1 = control_a, .ctrl2 = control_b, .to = to } });
        contour.current = to;
    }

    /// Draws an SVG-style elliptical arc from the current point to `to`.
    pub fn arc_to(
        self: *PathBuilder,
        radii: Point(Pixels),
        x_rotation: Pixels,
        large_arc: bool,
        sweep: bool,
        to: Point(Pixels),
    ) !void {
        const contour = try self.open_contour();
        const start = contour.current;

        var rx = @abs(radii.x);
        var ry = @abs(radii.y);
        if (rx < epsilon or ry < epsilon or (@abs(start.x - to.x) < epsilon and @abs(start.y - to.y) < epsilon)) {
            try contour.segments.append(self.allocator, .{ .line = to });
            contour.current = to;
            return;
        }

        // SVG endpoint-to-center parameterization (SVG 1.1, appendix F.6.5).
        const phi = x_rotation * std.math.pi / 180.0;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);
        const half_dx = (start.x - to.x) / 2.0;
        const half_dy = (start.y - to.y) / 2.0;
        const x1p = cos_phi * half_dx + sin_phi * half_dy;
        const y1p = -sin_phi * half_dx + cos_phi * half_dy;

        const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lambda > 1.0) {
            const s = @sqrt(lambda);
            rx *= s;
            ry *= s;
        }

        const rx2 = rx * rx;
        const ry2 = ry * ry;
        const numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
        const denominator = rx2 * y1p * y1p + ry2 * x1p * x1p;
        var coefficient = if (denominator > 0.0) @sqrt(@max(0.0, numerator / denominator)) else 0.0;
        if (large_arc == sweep) coefficient = -coefficient;

        const cxp = coefficient * rx * y1p / ry;
        const cyp = -coefficient * ry * x1p / rx;
        const cx = cos_phi * cxp - sin_phi * cyp + (start.x + to.x) / 2.0;
        const cy = sin_phi * cxp + cos_phi * cyp + (start.y + to.y) / 2.0;

        const ux = (x1p - cxp) / rx;
        const uy = (y1p - cyp) / ry;
        const vx = (-x1p - cxp) / rx;
        const vy = (-y1p - cyp) / ry;
        const theta1 = std.math.atan2(uy, ux);
        var delta_theta = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (!sweep and delta_theta > 0.0) delta_theta -= 2.0 * std.math.pi;
        if (sweep and delta_theta < 0.0) delta_theta += 2.0 * std.math.pi;

        const seg_count: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(delta_theta) / (std.math.pi * 0.5)))));
        const seg_angle = delta_theta / @as(f32, @floatFromInt(seg_count));
        const alpha = (4.0 / 3.0) * @tan(seg_angle * 0.25);

        for (0..seg_count) |i| {
            const t0 = theta1 + @as(f32, @floatFromInt(i)) * seg_angle;
            const t1 = t0 + seg_angle;
            const cos0 = @cos(t0);
            const sin0 = @sin(t0);
            const cos1 = @cos(t1);
            const sin1 = @sin(t1);

            const c1 = mapEllipse(cx, cy, rx, ry, cos_phi, sin_phi, cos0 - alpha * sin0, sin0 + alpha * cos0);
            const c2 = mapEllipse(cx, cy, rx, ry, cos_phi, sin_phi, cos1 + alpha * sin1, sin1 - alpha * cos1);
            const end_pt = if (i + 1 == seg_count)
                to
            else
                mapEllipse(cx, cy, rx, ry, cos_phi, sin_phi, cos1, sin1);

            try contour.segments.append(self.allocator, .{ .cubic = .{
                .ctrl1 = c1,
                .ctrl2 = c2,
                .to = end_pt,
            } });
        }
        contour.current = to;
    }

    fn mapEllipse(
        cx: f32,
        cy: f32,
        rx: f32,
        ry: f32,
        cos_phi: f32,
        sin_phi: f32,
        ux: f32,
        uy: f32,
    ) Point(Pixels) {
        return .{
            .x = cx + rx * ux * cos_phi - ry * uy * sin_phi,
            .y = cy + rx * ux * sin_phi + ry * uy * cos_phi,
        };
    }

    /// Like `arc_to`, with `to` relative to the current point.
    pub fn relative_arc_to(
        self: *PathBuilder,
        radii: Point(Pixels),
        x_rotation: Pixels,
        large_arc: bool,
        sweep: bool,
        to: Point(Pixels),
    ) !void {
        const start = try self.current_point();
        try self.arc_to(radii, x_rotation, large_arc, sweep, .{ .x = start.x + to.x, .y = start.y + to.y });
    }

    /// Adds a polyline through `points`, closing it when `closed` is true.
    pub fn add_polygon(self: *PathBuilder, points: []const Point(Pixels), closed: bool) !void {
        if (points.len == 0) return;
        try self.move_to(points[0]);
        for (points[1..]) |pt| try self.line_to(pt);
        if (closed) self.close();
    }

    /// Closes the current sub-path.
    pub fn close(self: *PathBuilder) void {
        if (self.contours.items.len == 0) return;
        const last = &self.contours.items[self.contours.items.len - 1];
        last.closed = true;
        last.current = last.start;
    }

    /// Applies `transform` to the path when it is built (GPUI `transform`).
    pub fn transform_by(self: *PathBuilder, t: Transform) void {
        self.transform_ = t;
    }
    pub const transform = transform_by;

    /// Translates the path by `to` when it is built.
    pub fn translate(self: *PathBuilder, to: Point(Pixels)) void {
        self.transform_ = (self.transform_ orelse Transform{}).then(Transform.translation(to.x, to.y));
    }

    /// Scales the path uniformly when it is built.
    pub fn scale(self: *PathBuilder, factor: f32) void {
        self.transform_ = (self.transform_ orelse Transform{}).then(Transform.scale(factor, factor));
    }

    /// Rotates the path by `degrees` when it is built.
    pub fn rotate(self: *PathBuilder, degrees: f32) void {
        const radians = degrees * std.math.pi / 180.0;
        self.transform_ = (self.transform_ orelse Transform{}).then(Transform.rotation(radians));
    }

    /// The closed contours to fill, and the rule to fill them by. Consumes `self`.
    pub fn outline(self: *PathBuilder) !struct { curves: []PathCurve, fill_rule: FillRule } {
        defer self.deinit();
        switch (self.style) {
            .fill => |opts| return .{
                .curves = try self.fill_outline(),
                .fill_rule = opts.fill_rule,
            },
            .stroke => |opts| return .{
                .curves = try self.stroke_outline(opts),
                .fill_rule = .non_zero,
            },
        }
    }

    /// Builds the commands into a `Path`. Consumes the builder, releasing its storage.
    pub fn build(self: *PathBuilder) !Path(Pixels) {
        const alloc = self.allocator;
        const result = try self.outline();
        return Path(Pixels).from_curves(alloc, result.curves, result.fill_rule == .even_odd);
    }

    fn open_contour(self: *PathBuilder) !*Contour {
        if (self.contours.items.len > 0) {
            const last = &self.contours.items[self.contours.items.len - 1];
            if (!last.closed) return last;
            const restart = last.start;
            try self.move_to(restart);
            return &self.contours.items[self.contours.items.len - 1];
        }
        try self.move_to(.{ .x = 0, .y = 0 });
        return &self.contours.items[0];
    }

    fn current_point(self: *PathBuilder) !Point(Pixels) {
        const contour = try self.open_contour();
        return contour.current;
    }

    fn apply_tx(self: *const PathBuilder, p: Point(Pixels)) Point(f32) {
        if (self.transform_) |tx| return tx.apply(p);
        return p;
    }

    fn fill_outline(self: *const PathBuilder) ![]PathCurve {
        var out = Outline.init(self.allocator);
        errdefer out.deinit();

        for (self.contours.items) |contour| {
            try out.move_to(self.apply_tx(contour.start));
            for (contour.segments.items) |seg| {
                switch (seg) {
                    .line => |to| try out.line_to(self.apply_tx(to)),
                    .quad => |q| try out.curve_to(self.apply_tx(q.to), self.apply_tx(q.ctrl)),
                    .cubic => |c| try out.cubic_to(self.apply_tx(c.to), self.apply_tx(c.ctrl1), self.apply_tx(c.ctrl2)),
                }
            }
            try out.close();
        }
        return try out.into_curves();
    }

    fn stroke_outline(self: *const PathBuilder, options: StrokeOptions) ![]PathCurve {
        if (!(options.line_width > 0.0) or !std.math.isFinite(options.line_width)) {
            return try self.allocator.alloc(PathCurve, 0);
        }
        const half_width = options.line_width * 0.5;
        var out = Outline.init(self.allocator);
        errdefer out.deinit();

        var flattened: std.ArrayList(Point(f32)) = .empty;
        defer flattened.deinit(self.allocator);

        for (self.contours.items) |contour| {
            flattened.clearRetainingCapacity();
            var cur = self.apply_tx(contour.start);
            try flattened.append(self.allocator, cur);
            for (contour.segments.items) |seg| {
                switch (seg) {
                    .line => |to| {
                        cur = self.apply_tx(to);
                        try flattened.append(self.allocator, cur);
                    },
                    .quad => |q| {
                        const c = self.apply_tx(q.ctrl);
                        const to = self.apply_tx(q.to);
                        try flatten_quad(self.allocator, &flattened, cur, c, to, 0);
                        cur = to;
                    },
                    .cubic => |cb| {
                        const c1 = self.apply_tx(cb.ctrl1);
                        const c2 = self.apply_tx(cb.ctrl2);
                        const to = self.apply_tx(cb.to);
                        try flatten_cubic(self.allocator, &flattened, cur, c1, c2, to, 0);
                        cur = to;
                    },
                }
            }
            const pts = try dedupe(self.allocator, flattened.items, contour.closed);
            defer self.allocator.free(pts);
            if (pts.len < 2) continue;

            // Validate finiteness before stroke math.
            for (pts) |pt| {
                if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) {
                    out.non_finite = true;
                    break;
                }
            }
            if (out.non_finite) break;

            const closed = contour.closed;
            if (self.dash_array_.items.len == 0) {
                try emit_stroke_polyline(&out, pts, closed, half_width, options);
            } else {
                try emit_stroke_dashed(self.allocator, &out, pts, closed, self.dash_array_.items, half_width, options);
            }
        }
        return try out.into_curves();
    }
};

fn flatten_quad(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Point(f32)),
    p0: Point(f32),
    ctrl: Point(f32),
    p1: Point(f32),
    depth: u8,
) !void {
    if (!std.math.isFinite(ctrl.x) or !std.math.isFinite(ctrl.y) or !std.math.isFinite(p1.x) or !std.math.isFinite(p1.y)) {
        try out.append(allocator, p1);
        return;
    }
    const dx = p0.x - 2.0 * ctrl.x + p1.x;
    const dy = p0.y - 2.0 * ctrl.y + p1.y;
    const err_sq = (dx * dx + dy * dy) / 16.0;
    if (err_sq <= stroke_tolerance * stroke_tolerance or depth >= 10) {
        try out.append(allocator, p1);
        return;
    }
    const m0 = midpoint(p0, ctrl);
    const m1 = midpoint(ctrl, p1);
    const mid = midpoint(m0, m1);
    try flatten_quad(allocator, out, p0, m0, mid, depth + 1);
    try flatten_quad(allocator, out, mid, m1, p1, depth + 1);
}

fn flatten_cubic(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Point(f32)),
    p0: Point(f32),
    c1: Point(f32),
    c2: Point(f32),
    p3: Point(f32),
    depth: u8,
) !void {
    if (!std.math.isFinite(c1.x) or !std.math.isFinite(c1.y) or !std.math.isFinite(c2.x) or !std.math.isFinite(c2.y) or !std.math.isFinite(p3.x) or !std.math.isFinite(p3.y)) {
        try out.append(allocator, p3);
        return;
    }
    const d1x = c1.x - p0.x - (p3.x - p0.x) / 3.0;
    const d1y = c1.y - p0.y - (p3.y - p0.y) / 3.0;
    const d2x = c2.x - p0.x - 2.0 * (p3.x - p0.x) / 3.0;
    const d2y = c2.y - p0.y - 2.0 * (p3.y - p0.y) / 3.0;
    const err_sq = 0.5625 * @max(d1x * d1x + d1y * d1y, d2x * d2x + d2y * d2y);
    if (err_sq <= stroke_tolerance * stroke_tolerance or depth >= 10) {
        try out.append(allocator, p3);
        return;
    }
    const m01 = midpoint(p0, c1);
    const m12 = midpoint(c1, c2);
    const m23 = midpoint(c2, p3);
    const m012 = midpoint(m01, m12);
    const m123 = midpoint(m12, m23);
    const mid = midpoint(m012, m123);
    try flatten_cubic(allocator, out, p0, m01, m012, mid, depth + 1);
    try flatten_cubic(allocator, out, mid, m123, m23, p3, depth + 1);
}

fn dedupe(allocator: std.mem.Allocator, points: []const Point(f32), drop_closing_dup: bool) ![]Point(f32) {
    var result: std.ArrayList(Point(f32)) = .empty;
    errdefer result.deinit(allocator);
    for (points) |pt| {
        if (result.items.len > 0 and same_point(result.items[result.items.len - 1], pt)) continue;
        try result.append(allocator, pt);
    }
    if (drop_closing_dup) {
        while (result.items.len > 1 and same_point(result.items[result.items.len - 1], result.items[0])) {
            _ = result.pop();
        }
    }
    return result.toOwnedSlice(allocator);
}

fn same_point(a: Point(f32), b: Point(f32)) bool {
    return @abs(a.x - b.x) < epsilon and @abs(a.y - b.y) < epsilon;
}

fn cross(u: Point(f32), v: Point(f32)) f32 {
    return u.x * v.y - u.y * v.x;
}

fn dot(u: Point(f32), v: Point(f32)) f32 {
    return u.x * v.x + u.y * v.y;
}

fn distance(a: Point(f32), b: Point(f32)) f32 {
    const d = b.sub(a);
    return @sqrt(d.x * d.x + d.y * d.y);
}

fn unit(a: Point(f32), b: Point(f32)) ?Point(f32) {
    const len = distance(a, b);
    if (!(len > epsilon)) return null;
    return b.sub(a).div(len);
}

fn left_normal(direction: Point(f32), length: f32) Point(f32) {
    return .{ .x = -direction.y * length, .y = direction.x * length };
}

/// Emits a polygon oriented with negative signed area (winding +1 inside) so
/// overlapping stroke rectangles, joins, and caps always add constructively.
fn emit_oriented_poly(out: *Outline, pts: []const Point(f32)) !void {
    if (pts.len < 3) return;
    var area: f32 = 0.0;
    for (pts, 0..) |pt, i| {
        area += cross(pt, pts[(i + 1) % pts.len]);
    }
    if (@abs(area) <= 1e-9) return;
    if (area < 0.0) {
        try out.move_to(pts[0]);
        for (pts[1..]) |pt| try out.line_to(pt);
    } else {
        try out.move_to(pts[pts.len - 1]);
        var i = pts.len - 1;
        while (i > 0) {
            i -= 1;
            try out.line_to(pts[i]);
        }
    }
    try out.close();
}

/// Emits a circular arc sector `(center -> a -> ... -> b -> center)` oriented
/// with negative signed area (winding +1 inside).
fn emit_round_sector(out: *Outline, center: Point(f32), a: Point(f32), b: Point(f32), radius: f32) !void {
    const ua = unit(center, a) orelse return;
    const ub = unit(center, b) orelse return;
    var delta = std.math.atan2(cross(ua, ub), dot(ua, ub));
    if (@abs(delta) < 1e-4) return;
    const theta0 = std.math.atan2(ua.y, ua.x);
    // Ensure consistent negative signed area: if delta > 0, sweep backwards (b -> a).
    const reverse = delta > 0.0;
    const start_theta = if (reverse) theta0 + delta else theta0;
    if (reverse) delta = -delta;

    const seg_count: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(delta) / (std.math.pi * 0.5)))));
    const seg_angle = delta / @as(f32, @floatFromInt(seg_count));
    const alpha = (4.0 / 3.0) * @tan(seg_angle * 0.25);

    try out.move_to(center);
    const first_pt = if (reverse) b else a;
    try out.line_to(first_pt);
    for (0..seg_count) |i| {
        const t0 = start_theta + @as(f32, @floatFromInt(i)) * seg_angle;
        const t1 = t0 + seg_angle;
        const c0 = @cos(t0);
        const s0 = @sin(t0);
        const c1 = @cos(t1);
        const s1 = @sin(t1);
        const ctrl1: Point(f32) = .{ .x = center.x + radius * (c0 - alpha * s0), .y = center.y + radius * (s0 + alpha * c0) };
        const ctrl2: Point(f32) = .{ .x = center.x + radius * (c1 + alpha * s1), .y = center.y + radius * (s1 - alpha * c1) };
        const end_pt: Point(f32) = if (i + 1 == seg_count)
            (if (reverse) a else b)
        else
            .{ .x = center.x + radius * c1, .y = center.y + radius * s1 };
        try out.cubic_to(end_pt, ctrl1, ctrl2);
    }
    try out.close();
}

fn emit_cap(out: *Outline, p: Point(f32), out_dir: Point(f32), half_width: f32, cap: LineCap) !void {
    switch (cap) {
        .butt => {},
        .square => {
            const n = left_normal(out_dir, half_width);
            const ext = out_dir.mul(half_width);
            try emit_oriented_poly(out, &.{
                p.sub(n),
                p.add(n),
                p.add(n).add(ext),
                p.sub(n).add(ext),
            });
        },
        .round => {
            const n = left_normal(out_dir, half_width);
            const mid = p.add(out_dir.mul(half_width));
            const p_pos = p.add(n);
            const p_neg = p.sub(n);
            try emit_round_sector(out, p, p_pos, mid, half_width);
            try emit_round_sector(out, p, mid, p_neg, half_width);
        },
    }
}

fn emit_join(
    out: *Outline,
    vertex: Point(f32),
    prev_dir: Point(f32),
    next_dir: Point(f32),
    half_width: f32,
    options: StrokeOptions,
) !void {
    const turn = cross(prev_dir, next_dir);
    if (@abs(turn) < epsilon) {
        // 180-degree reversal: round join adds a full cap-like semicircle.
        if (options.line_join == .round and dot(prev_dir, next_dir) < -0.5) {
            try emit_cap(out, vertex, prev_dir, half_width, .round);
        }
        return;
    }

    const side: f32 = if (turn > 0.0) -1.0 else 1.0;
    const p1 = vertex.add(left_normal(prev_dir, half_width * side));
    const p2 = vertex.add(left_normal(next_dir, half_width * side));

    switch (options.line_join) {
        .bevel => {
            try emit_oriented_poly(out, &.{ vertex, p1, p2 });
        },
        .round => {
            try emit_round_sector(out, vertex, p1, p2, half_width);
        },
        .miter, .miter_clip => {
            const t = cross(p2.sub(p1), next_dir) / turn;
            const miter_tip = p1.add(prev_dir.mul(t));
            const miter_dist = distance(vertex, miter_tip);
            const max_miter = options.miter_limit * half_width;
            if (miter_dist <= max_miter) {
                try emit_oriented_poly(out, &.{ vertex, p1, miter_tip, p2 });
            } else if (options.line_join == .miter) {
                try emit_oriented_poly(out, &.{ vertex, p1, p2 });
            } else {
                const bis = unit(vertex, miter_tip) orelse {
                    try emit_oriented_poly(out, &.{ vertex, p1, p2 });
                    return;
                };
                const clip_pt = vertex.add(bis.mul(max_miter));
                const d1 = dot(prev_dir, bis);
                const d2 = dot(next_dir, bis);
                if (@abs(d1) < epsilon or @abs(d2) < epsilon) {
                    try emit_oriented_poly(out, &.{ vertex, p1, p2 });
                    return;
                }
                const k1 = dot(clip_pt.sub(p1), bis) / d1;
                const k2 = dot(clip_pt.sub(p2), bis) / d2;
                const c1 = p1.add(prev_dir.mul(k1));
                const c2 = p2.add(next_dir.mul(k2));
                try emit_oriented_poly(out, &.{ vertex, p1, c1, c2, p2 });
            }
        },
    }
}

fn emit_stroke_polyline(
    out: *Outline,
    pts: []const Point(f32),
    closed: bool,
    half_width: f32,
    options: StrokeOptions,
) !void {
    const count = pts.len;
    const segment_count = if (closed) count else count - 1;

    for (0..segment_count) |index| {
        const a = pts[index];
        const b = pts[(index + 1) % count];
        const dir = unit(a, b) orelse continue;
        const n = left_normal(dir, half_width);
        try emit_oriented_poly(out, &.{ a.add(n), a.sub(n), b.sub(n), b.add(n) });
    }

    const vertex_start: usize = if (closed) 0 else 1;
    const vertex_end: usize = if (closed) count else count - 1;
    for (vertex_start..vertex_end) |vertex| {
        const prev = pts[(vertex + count - 1) % count];
        const cur = pts[vertex];
        const next = pts[(vertex + 1) % count];
        const prev_dir = unit(prev, cur) orelse continue;
        const next_dir = unit(cur, next) orelse continue;
        try emit_join(out, cur, prev_dir, next_dir, half_width, options);
    }

    if (!closed) {
        if (unit(pts[0], pts[1])) |first_dir| {
            try emit_cap(out, pts[0], first_dir.neg(), half_width, options.line_cap);
        }
        if (unit(pts[count - 2], pts[count - 1])) |last_dir| {
            try emit_cap(out, pts[count - 1], last_dir, half_width, options.line_cap);
        }
    }
}

fn emit_stroke_dashed(
    allocator: std.mem.Allocator,
    out: *Outline,
    pts: []const Point(f32),
    closed: bool,
    pattern: []const Pixels,
    half_width: f32,
    options: StrokeOptions,
) !void {
    var total: f32 = 0.0;
    for (pattern) |length| total += length;
    if (!(total > 0.0)) return emit_stroke_polyline(out, pts, closed, half_width, options);

    var piece: std.ArrayList(Point(f32)) = .empty;
    defer piece.deinit(allocator);

    var on = true;
    var pattern_index: usize = 0;
    var remaining = pattern[0];

    const count = pts.len;
    const segment_count = if (closed) count else count - 1;
    for (0..segment_count) |segment| {
        const a = pts[segment];
        const b = pts[(segment + 1) % count];
        const seg_len = distance(a, b);
        if (seg_len < epsilon) continue;
        const dir = unit(a, b) orelse continue;

        if (on and piece.items.len == 0) try piece.append(allocator, a);

        var pos: f32 = 0.0;
        while (seg_len - pos > remaining) {
            pos += remaining;
            const boundary = a.add(dir.mul(pos));
            if (on) {
                try piece.append(allocator, boundary);
                if (piece.items.len >= 2) {
                    try emit_stroke_polyline(out, piece.items, false, half_width, options);
                }
                piece.clearRetainingCapacity();
            } else {
                try piece.append(allocator, boundary);
            }
            on = !on;
            pattern_index = (pattern_index + 1) % pattern.len;
            remaining = pattern[pattern_index];
        }
        remaining -= seg_len - pos;
        if (on) try piece.append(allocator, b);
    }

    if (on and piece.items.len >= 2) {
        try emit_stroke_polyline(out, piece.items, false, half_width, options);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn point_at(x: f32, y: f32) Point(Pixels) {
    return .{ .x = x, .y = y };
}

fn winding_at(curves: []const PathCurve, px_x: f32, px_y: f32) i32 {
    var w: i32 = 0;
    for (curves) |c| {
        if (c.crosses(px_y)) {
            const x_hit = c.x_at_y(px_y);
            if (x_hit <= px_x) w += c.step();
        }
    }
    return w;
}

fn is_filled(curves: []const PathCurve, even_odd: bool, px_x: f32, px_y: f32) bool {
    const w = winding_at(curves, px_x, px_y);
    return if (even_odd) (@rem(w, 2) != 0) else (w != 0);
}

test "fill square builds closed monotone curves with exact bounds" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.add_polygon(&.{ point_at(0, 0), point_at(10, 0), point_at(10, 10), point_at(0, 10) }, true);

    var path = try builder.build();
    defer path.deinit();
    try testing.expectEqual(@as(usize, 4), path.curves.items.len);
    try testing.expectEqual(@as(f32, 0), path.bounds.origin.x);
    try testing.expectEqual(@as(f32, 10), path.bounds.size.width);
    try testing.expect(is_filled(path.curves.items, path.even_odd, 5, 5));
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 15, 5));
}

test "concave L shape fills interior and leaves notch empty" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.add_polygon(&.{
        point_at(0, 0),
        point_at(10, 0),
        point_at(10, 5),
        point_at(5, 5),
        point_at(5, 10),
        point_at(0, 10),
    }, true);

    var path = try builder.build();
    defer path.deinit();
    try testing.expect(is_filled(path.curves.items, path.even_odd, 2.5, 2.5));
    try testing.expect(is_filled(path.curves.items, path.even_odd, 2.5, 7.5));
    try testing.expect(is_filled(path.curves.items, path.even_odd, 7.5, 2.5));
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 7.5, 7.5));
}

test "fill: a self-intersecting bowtie covers both lobes and not the gaps" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.add_polygon(&.{ point_at(0, 0), point_at(2, 2), point_at(2, 0), point_at(0, 2) }, true);
    var path = try builder.build();
    defer path.deinit();
    try testing.expect(is_filled(path.curves.items, path.even_odd, 0.2, 1));
    try testing.expect(is_filled(path.curves.items, path.even_odd, 1.8, 1));
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 1, 0.2));
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 1, 1.8));
}

test "fill: an inner contour is a hole under even_odd" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.add_polygon(&.{ point_at(0, 0), point_at(4, 0), point_at(4, 4), point_at(0, 4) }, true);
    try builder.add_polygon(&.{ point_at(1, 1), point_at(3, 1), point_at(3, 3), point_at(1, 3) }, true);
    var path = try builder.build();
    defer path.deinit();
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 2, 2));
    try testing.expect(is_filled(path.curves.items, path.even_odd, 0.5, 2));
}

test "fill: a pentagram has an even-odd hole in the middle and non-zero filled middle" {
    var points: [5]Point(Pixels) = undefined;
    for (&points, 0..) |*pt, i| {
        const angle = @as(f32, @floatFromInt(i)) * 4.0 * std.math.pi / 5.0 - std.math.pi / 2.0;
        pt.* = .{ .x = 10.0 * @cos(angle), .y = 10.0 * @sin(angle) };
    }
    var builder_eo = PathBuilder.fill(testing.allocator);
    try builder_eo.add_polygon(&points, true);
    var path_eo = try builder_eo.build();
    defer path_eo.deinit();
    try testing.expect(!is_filled(path_eo.curves.items, path_eo.even_odd, 0, 0));
    try testing.expect(is_filled(path_eo.curves.items, path_eo.even_odd, 0, -8));

    var builder_nz = PathBuilder.fill(testing.allocator);
    _ = builder_nz.with_style(.{ .fill = .{ .fill_rule = .non_zero } });
    try builder_nz.add_polygon(&points, true);
    var path_nz = try builder_nz.build();
    defer path_nz.deinit();
    try testing.expect(is_filled(path_nz.curves.items, path_nz.even_odd, 0, 0));
    try testing.expect(is_filled(path_nz.curves.items, path_nz.even_odd, 0, -8));
}

test "stroked segment covers its width and caps" {
    var builder = PathBuilder.stroke(testing.allocator, 2);
    try builder.move_to(point_at(0, 0));
    try builder.line_to(point_at(10, 0));

    var path = try builder.build();
    defer path.deinit();
    try testing.expectApproxEqAbs(@as(f32, -1), path.bounds.origin.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), path.bounds.size.height, 1e-4);
    try testing.expect(!is_filled(path.curves.items, path.even_odd, -0.5, 0));

    var square_builder = PathBuilder.stroke(testing.allocator, 2);
    _ = square_builder.with_style(.{ .stroke = .{ .line_width = 2, .line_cap = .square } });
    try square_builder.move_to(point_at(0, 0));
    try square_builder.line_to(point_at(10, 0));
    var square_path = try square_builder.build();
    defer square_path.deinit();
    try testing.expect(is_filled(square_path.curves.items, square_path.even_odd, -0.5, 0));
    try testing.expect(is_filled(square_path.curves.items, square_path.even_odd, 10.5, 0));

    var round_builder = PathBuilder.stroke(testing.allocator, 4);
    _ = round_builder.with_style(.{ .stroke = .{ .line_width = 4, .line_cap = .round } });
    try round_builder.move_to(point_at(0, 0));
    try round_builder.line_to(point_at(10, 0));
    var round_path = try round_builder.build();
    defer round_path.deinit();
    try testing.expect(is_filled(round_path.curves.items, round_path.even_odd, -1.5, 0));
    try testing.expect(!is_filled(round_path.curves.items, round_path.even_odd, -1.9, 1.9));
}

test "stroke joins support bevel, miter, miter_clip, and round" {
    for ([_]LineJoin{ .bevel, .miter, .miter_clip, .round }) |join| {
        var builder = PathBuilder.stroke(testing.allocator, 4);
        _ = builder.with_style(.{ .stroke = .{ .line_width = 4, .line_join = join, .miter_limit = 4.0 } });
        try builder.move_to(point_at(0, 0));
        try builder.line_to(point_at(10, 0));
        try builder.line_to(point_at(10, 10));
        var path = try builder.build();
        defer path.deinit();
        // Outer corner at (11.5, -1.5) is covered by miter (dist = 2*sqrt(2) = 2.828 <= 8) and miter_clip, not bevel.
        if (join == .miter or join == .miter_clip) {
            try testing.expect(is_filled(path.curves.items, path.even_odd, 11.5, -1.5));
        } else if (join == .bevel) {
            try testing.expect(!is_filled(path.curves.items, path.even_odd, 11.5, -1.5));
        } else {
            try testing.expect(is_filled(path.curves.items, path.even_odd, 11.0, -1.0));
        }
    }
}

test "dash pattern splits a stroke into pieces" {
    var builder = PathBuilder.stroke(testing.allocator, 2);
    try builder.dash_array_set(&.{ 2, 2 });
    try builder.move_to(point_at(0, 0));
    try builder.line_to(point_at(10, 0));

    var path = try builder.build();
    defer path.deinit();
    try testing.expect(is_filled(path.curves.items, path.even_odd, 1.0, 0));
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 3.0, 0));
    try testing.expect(is_filled(path.curves.items, path.even_odd, 5.0, 0));
    try testing.expect(!is_filled(path.curves.items, path.even_odd, 7.0, 0));
    try testing.expect(is_filled(path.curves.items, path.even_odd, 9.0, 0));
}

test "translate moves the built path" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.add_polygon(&.{ point_at(0, 0), point_at(10, 0), point_at(0, 10) }, true);
    builder.translate(point_at(5, 7));

    var path = try builder.build();
    defer path.deinit();
    try testing.expectApproxEqAbs(@as(f32, 5), path.bounds.origin.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 7), path.bounds.origin.y, 1e-4);
}

test "semicircle arc ends on its end point" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.move_to(point_at(0, 0));
    try builder.arc_to(point_at(5, 5), 0, false, true, point_at(10, 0));
    builder.close();

    var path = try builder.build();
    defer path.deinit();
    try testing.expectApproxEqAbs(@as(f32, 10), path.bounds.size.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 5), @abs(path.bounds.size.height), 1e-2);
}

test "non_finite_point_fails_path" {
    var out = Outline.init(testing.allocator);
    defer out.deinit();
    try out.move_to(.{ .x = 0, .y = 0 });
    try out.line_to(.{ .x = 10, .y = 0 });
    try out.line_to(.{ .x = 10, .y = 10 });
    try out.move_to(.{ .x = 20, .y = 0 });
    try out.line_to(.{ .x = std.math.nan(f32), .y = 5 });
    try out.line_to(.{ .x = 30, .y = 10 });
    try testing.expectError(error.NonFinitePoint, out.into_curves());
}

test "endpoints_balance" {
    var curved_fill = PathBuilder.fill(testing.allocator);
    try curved_fill.move_to(point_at(450.3, 280.7));
    try curved_fill.curve_to(point_at(530.3, 230.7), point_at(450.3, 230.7));
    try curved_fill.arc_to(point_at(30.0, 30.0), 0.0, false, false, point_at(590.3, 230.7));
    curved_fill.close();

    var stroke_b = PathBuilder.stroke(testing.allocator, 2.0);
    try stroke_b.move_to(point_at(80.3, 500.7));
    try stroke_b.cubic_bezier_to(point_at(900.0, 250.0), point_at(300.0, 50.0), point_at(700.0, 800.0));

    var dashed = PathBuilder.stroke(testing.allocator, 3.0);
    _ = dashed.dash_array(&.{ 9.0, 4.0 });
    try dashed.move_to(point_at(50.3, 10.7));
    try dashed.arc_to(point_at(40.0, 40.0), 0.0, false, true, point_at(90.3, 50.7));

    var builders = [_]PathBuilder{ curved_fill, stroke_b, dashed };
    for (&builders) |*b| {
        const res = try b.outline();
        defer testing.allocator.free(res.curves);
        try testing.expect(res.curves.len > 0);

        const Key = struct { x: u32, y: u32 };
        var balance: std.AutoHashMapUnmanaged(Key, i32) = .empty;
        defer balance.deinit(testing.allocator);
        for (res.curves) |c| {
            for (c.endpoints()) |ep| {
                const k: Key = .{ .x = @bitCast(ep.point.x), .y = @bitCast(ep.point.y) };
                const entry = try balance.getOrPutValue(testing.allocator, k, 0);
                entry.value_ptr.* += ep.step;
            }
        }
        var it = balance.iterator();
        while (it.next()) |entry| {
            try testing.expectEqual(@as(i32, 0), entry.value_ptr.*);
        }
    }
}
