//! Port of gpui/src/path_builder.rs. Lyon is replaced by flattening curves to polylines,
//! ear-clipping fills per contour and stroking segments as quads with bevel joins.
const std = @import("std");
const geometry = @import("geometry.zig");
const scene = @import("scene.zig");
const testing = std.testing;

const Point = geometry.Point;
const Pixels = geometry.Pixels;
const Path = scene.Path;

/// Segments used to flatten each quadratic or cubic curve.
const curve_steps = 16;
/// Segments used to flatten each elliptical arc.
const arc_steps = 32;
/// Tolerance for treating cross products and distances as zero.
const epsilon: f32 = 1e-6;

/// How a fill decides what is inside. Each contour is triangulated on its own, so holes are not
/// subtracted from their outer contour yet.
pub const FillRule = enum { non_zero, even_odd };

pub const FillOptions = struct {
    fill_rule: FillRule = .non_zero,
};

pub const StrokeOptions = struct {
    /// Full width of the stroke in logical pixels.
    line_width: Pixels = 1,
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

/// Points of one sub-path, plus whether it was closed.
const Contour = struct {
    points: std.ArrayList(Point(Pixels)) = .empty,
    closed: bool = false,
};

/// Builds a `Path` from move/line/curve commands, then tessellates it on `build`.
pub const PathBuilder = struct {
    allocator: std.mem.Allocator,
    contours: std.ArrayList(Contour) = .empty,
    transform: ?Transform = null,
    style: PathStyle,
    dash_array: std.ArrayList(Pixels) = .empty,

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
        for (self.contours.items) |*contour| contour.points.deinit(self.allocator);
        self.contours.deinit(self.allocator);
        self.dash_array.deinit(self.allocator);
    }

    pub fn with_style(self: *PathBuilder, style: PathStyle) *PathBuilder {
        self.style = style;
        return self;
    }

    /// Sets the stroke dash pattern. An odd-length pattern is repeated to even length, as in SVG.
    pub fn dash_array_set(self: *PathBuilder, pattern: []const Pixels) !void {
        self.dash_array.clearRetainingCapacity();
        try self.dash_array.appendSlice(self.allocator, pattern);
        if (pattern.len % 2 == 1) try self.dash_array.appendSlice(self.allocator, pattern);
    }

    /// Starts a new sub-path at `to`.
    pub fn move_to(self: *PathBuilder, to: Point(Pixels)) !void {
        var contour: Contour = .{};
        errdefer contour.points.deinit(self.allocator);
        try contour.points.append(self.allocator, to);
        try self.contours.append(self.allocator, contour);
    }

    /// Draws a straight line from the current point to `to`.
    pub fn line_to(self: *PathBuilder, to: Point(Pixels)) !void {
        const contour = try self.open_contour();
        try contour.points.append(self.allocator, to);
    }

    /// Draws a quadratic Bézier from the current point to `to` with control point `ctrl`.
    pub fn curve_to(self: *PathBuilder, to: Point(Pixels), ctrl: Point(Pixels)) !void {
        const start = try self.current_point();
        const contour = try self.open_contour();
        var step: usize = 1;
        while (step <= curve_steps) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / curve_steps;
            const u = 1 - t;
            try contour.points.append(self.allocator, .{
                .x = u * u * start.x + 2 * u * t * ctrl.x + t * t * to.x,
                .y = u * u * start.y + 2 * u * t * ctrl.y + t * t * to.y,
            });
        }
    }

    /// Draws a cubic Bézier from the current point to `to` with two control points.
    pub fn cubic_bezier_to(self: *PathBuilder, to: Point(Pixels), control_a: Point(Pixels), control_b: Point(Pixels)) !void {
        const start = try self.current_point();
        const contour = try self.open_contour();
        var step: usize = 1;
        while (step <= curve_steps) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / curve_steps;
            const u = 1 - t;
            const w0 = u * u * u;
            const w1 = 3 * u * u * t;
            const w2 = 3 * u * t * t;
            const w3 = t * t * t;
            try contour.points.append(self.allocator, .{
                .x = w0 * start.x + w1 * control_a.x + w2 * control_b.x + w3 * to.x,
                .y = w0 * start.y + w1 * control_a.y + w2 * control_b.y + w3 * to.y,
            });
        }
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
        const start = try self.current_point();
        const contour = try self.open_contour();

        var rx = @abs(radii.x);
        var ry = @abs(radii.y);
        if (rx < epsilon or ry < epsilon or (@abs(start.x - to.x) < epsilon and @abs(start.y - to.y) < epsilon)) {
            try contour.points.append(self.allocator, to);
            return;
        }

        // SVG endpoint-to-center conversion (SVG 1.1, appendix F.6.5).
        const phi = x_rotation * std.math.pi / 180.0;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);
        const half_dx = (start.x - to.x) / 2;
        const half_dy = (start.y - to.y) / 2;
        const x1p = cos_phi * half_dx + sin_phi * half_dy;
        const y1p = -sin_phi * half_dx + cos_phi * half_dy;

        const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }

        const rx2 = rx * rx;
        const ry2 = ry * ry;
        const numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
        const denominator = rx2 * y1p * y1p + ry2 * x1p * x1p;
        var coefficient = @sqrt(@max(0, numerator / denominator));
        if (large_arc == sweep) coefficient = -coefficient;

        const cxp = coefficient * rx * y1p / ry;
        const cyp = -coefficient * ry * x1p / rx;
        const cx = cos_phi * cxp - sin_phi * cyp + (start.x + to.x) / 2;
        const cy = sin_phi * cxp + cos_phi * cyp + (start.y + to.y) / 2;

        const ux = (x1p - cxp) / rx;
        const uy = (y1p - cyp) / ry;
        const vx = (-x1p - cxp) / rx;
        const vy = (-y1p - cyp) / ry;
        const theta1 = std.math.atan2(uy, ux);
        var delta_theta = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (!sweep and delta_theta > 0) delta_theta -= 2 * std.math.pi;
        if (sweep and delta_theta < 0) delta_theta += 2 * std.math.pi;

        var step: usize = 1;
        while (step <= arc_steps) : (step += 1) {
            const theta = theta1 + delta_theta * @as(f32, @floatFromInt(step)) / arc_steps;
            try contour.points.append(self.allocator, .{
                .x = cx + rx * @cos(theta) * cos_phi - ry * @sin(theta) * sin_phi,
                .y = cy + rx * @cos(theta) * sin_phi + ry * @sin(theta) * cos_phi,
            });
        }
        // Land exactly on the requested end point despite rounding.
        contour.points.items[contour.points.items.len - 1] = to;
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
        for (points[1..]) |point| try self.line_to(point);
        if (closed) self.close();
    }

    /// Closes the current sub-path.
    pub fn close(self: *PathBuilder) void {
        if (self.contours.items.len == 0) return;
        self.contours.items[self.contours.items.len - 1].closed = true;
    }

    /// Applies `transform` to the path when it is built.
    pub fn transform_by(self: *PathBuilder, transform: Transform) void {
        self.transform = transform;
    }

    /// Translates the path by `to` when it is built.
    pub fn translate(self: *PathBuilder, to: Point(Pixels)) void {
        self.transform = (self.transform orelse Transform{}).then(Transform.translation(to.x, to.y));
    }

    /// Scales the path uniformly when it is built.
    pub fn scale(self: *PathBuilder, factor: f32) void {
        self.transform = (self.transform orelse Transform{}).then(Transform.scale(factor, factor));
    }

    /// Rotates the path by `degrees` when it is built.
    pub fn rotate(self: *PathBuilder, degrees: f32) void {
        const radians = degrees * std.math.pi / 180.0;
        self.transform = (self.transform orelse Transform{}).then(Transform.rotation(radians));
    }

    /// Tessellates the commands into a `Path`. Consumes the builder, releasing its storage.
    pub fn build(self: *PathBuilder) !Path(Pixels) {
        defer self.deinit();

        if (self.transform) |transform| {
            for (self.contours.items) |*contour| {
                for (contour.points.items) |*point| point.* = transform.apply(point.*);
            }
        }

        var triangles: std.ArrayList([3]Point(Pixels)) = .empty;
        defer triangles.deinit(self.allocator);

        switch (self.style) {
            .fill => try self.tessellate_fill(&triangles),
            .stroke => |options| try self.tessellate_stroke(&triangles, options.line_width / 2),
        }
        return build_path(self.allocator, triangles.items);
    }

    /// Returns the open sub-path, starting a new one (from the last point or the origin) when needed.
    fn open_contour(self: *PathBuilder) !*Contour {
        if (self.contours.items.len > 0) {
            const last = &self.contours.items[self.contours.items.len - 1];
            if (!last.closed) return last;

            // After a close, drawing continues from the sub-path's start point.
            const restart = last.points.items[0];
            try self.move_to(restart);
            return &self.contours.items[self.contours.items.len - 1];
        }
        try self.move_to(.{ .x = 0, .y = 0 });
        return &self.contours.items[0];
    }

    fn current_point(self: *PathBuilder) !Point(Pixels) {
        const contour = try self.open_contour();
        return contour.points.items[contour.points.items.len - 1];
    }

    fn tessellate_fill(self: *PathBuilder, triangles: *std.ArrayList([3]Point(Pixels))) !void {
        var contours: std.ArrayList([]const Point(Pixels)) = .empty;
        defer {
            for (contours.items) |points| self.allocator.free(points);
            contours.deinit(self.allocator);
        }
        for (self.contours.items) |*contour| {
            const points = try dedupe(self.allocator, contour.points.items);
            if (points.len < 3) {
                self.allocator.free(points);
                continue;
            }
            contours.append(self.allocator, points) catch |err| {
                self.allocator.free(points);
                return err;
            };
        }
        // One simple polygon, the usual case, gives the fewest triangles by clipping ears.
        if (contours.items.len == 1 and !self_intersects(contours.items[0])) {
            const start = triangles.items.len;
            if (try ear_clip(self.allocator, contours.items[0], triangles)) return;
            triangles.shrinkRetainingCapacity(start);
        }
        try fill_even_odd(self.allocator, contours.items, triangles);
    }

    fn tessellate_stroke(self: *PathBuilder, triangles: *std.ArrayList([3]Point(Pixels)), half_width: f32) !void {
        for (self.contours.items) |*contour| {
            const points = try dedupe(self.allocator, contour.points.items);
            defer self.allocator.free(points);
            if (points.len < 2) continue;
            const closed = contour.closed and points.len >= 3;

            if (self.dash_array.items.len == 0) {
                try stroke_polyline(self.allocator, points, closed, half_width, triangles);
            } else {
                try stroke_dashed(self.allocator, points, closed, self.dash_array.items, half_width, triangles);
            }
        }
    }
};

/// Returns `points` without consecutive duplicates, and without a final point equal to the first.
fn dedupe(allocator: std.mem.Allocator, points: []const Point(Pixels)) ![]Point(Pixels) {
    var result: std.ArrayList(Point(Pixels)) = .empty;
    errdefer result.deinit(allocator);
    for (points) |point| {
        if (result.items.len > 0 and same_point(result.items[result.items.len - 1], point)) continue;
        try result.append(allocator, point);
    }
    while (result.items.len > 1 and same_point(result.items[result.items.len - 1], result.items[0])) {
        _ = result.pop();
    }
    return result.toOwnedSlice(allocator);
}

fn same_point(a: Point(Pixels), b: Point(Pixels)) bool {
    return @abs(a.x - b.x) < epsilon and @abs(a.y - b.y) < epsilon;
}

fn cross(u: Point(Pixels), v: Point(Pixels)) f32 {
    return u.x * v.y - u.y * v.x;
}

fn point_in_triangle(p: Point(Pixels), a: Point(Pixels), b: Point(Pixels), c: Point(Pixels), sign: f32) bool {
    const d1 = sign * cross(b.sub(a), p.sub(a));
    const d2 = sign * cross(c.sub(b), p.sub(b));
    const d3 = sign * cross(a.sub(c), p.sub(c));
    return d1 >= -epsilon and d2 >= -epsilon and d3 >= -epsilon;
}

/// Whether two non-adjacent edges of a closed polygon cross.
fn self_intersects(points: []const Point(Pixels)) bool {
    const count = points.len;
    for (0..count) |i| {
        const a = points[i];
        const b = points[(i + 1) % count];
        var j = i + 2;
        while (j < count) : (j += 1) {
            // The last edge shares a vertex with the first.
            if (i == 0 and j == count - 1) continue;
            const c = points[j];
            const d = points[(j + 1) % count];
            const d1 = cross(b.sub(a), c.sub(a));
            const d2 = cross(b.sub(a), d.sub(a));
            const d3 = cross(d.sub(c), a.sub(c));
            const d4 = cross(d.sub(c), b.sub(c));
            if (((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))) return true;
        }
    }
    return false;
}

/// Fills any set of closed contours with the even-odd rule, lyon's default, so crossings and holes
/// come out right. Cuts the shape at every vertex and crossing into horizontal bands. Within a band
/// no edges cross, so sorting them by x and pairing them gives trapezoids.
fn fill_even_odd(allocator: std.mem.Allocator, contours: []const []const Point(Pixels), triangles: *std.ArrayList([3]Point(Pixels))) !void {
    const Edge = struct {
        top: Point(Pixels),
        bottom: Point(Pixels),

        fn x_at(edge: @This(), y: f32) f32 {
            const t = (y - edge.top.y) / (edge.bottom.y - edge.top.y);
            return edge.top.x + (edge.bottom.x - edge.top.x) * t;
        }
    };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    var cuts: std.ArrayList(f32) = .empty;
    defer cuts.deinit(allocator);
    for (contours) |points| {
        for (points, 0..) |a, index| {
            const b = points[(index + 1) % points.len];
            try cuts.append(allocator, a.y);
            if (a.y == b.y) continue;
            try edges.append(allocator, if (a.y < b.y) .{ .top = a, .bottom = b } else .{ .top = b, .bottom = a });
        }
    }
    for (edges.items, 0..) |e, i| {
        for (edges.items[i + 1..]) |f| {
            const r = e.bottom.sub(e.top);
            const q = f.bottom.sub(f.top);
            const denominator = cross(r, q);
            if (denominator == 0) continue;
            const to_f = f.top.sub(e.top);
            const t = cross(to_f, q) / denominator;
            const u = cross(to_f, r) / denominator;
            if (t > 0 and t < 1 and u > 0 and u < 1) try cuts.append(allocator, e.top.y + r.y * t);
        }
    }
    std.mem.sort(f32, cuts.items, {}, std.sort.asc(f32));

    const Crossing = struct {
        x: f32,
        edge: usize,
        fn less(_: void, a: @This(), b: @This()) bool {
            return a.x < b.x;
        }
    };
    var active: std.ArrayList(Crossing) = .empty;
    defer active.deinit(allocator);
    var band: usize = 0;
    while (band + 1 < cuts.items.len) : (band += 1) {
        const y0 = cuts.items[band];
        const y1 = cuts.items[band + 1];
        if (y1 - y0 < 1e-4) continue;
        const middle = (y0 + y1) / 2;
        active.clearRetainingCapacity();
        for (edges.items, 0..) |edge, index| {
            if (edge.top.y <= middle and edge.bottom.y > middle) {
                try active.append(allocator, .{ .x = edge.x_at(middle), .edge = index });
            }
        }
        std.mem.sort(Crossing, active.items, {}, Crossing.less);
        var pair: usize = 0;
        while (pair + 1 < active.items.len) : (pair += 2) {
            const left = edges.items[active.items[pair].edge];
            const right = edges.items[active.items[pair + 1].edge];
            const top_left: Point(Pixels) = .{ .x = left.x_at(y0), .y = y0 };
            const top_right: Point(Pixels) = .{ .x = right.x_at(y0), .y = y0 };
            const bottom_left: Point(Pixels) = .{ .x = left.x_at(y1), .y = y1 };
            const bottom_right: Point(Pixels) = .{ .x = right.x_at(y1), .y = y1 };
            if (top_right.x - top_left.x > epsilon) try triangles.append(allocator, .{ top_left, top_right, bottom_right });
            if (bottom_right.x - bottom_left.x > epsilon) try triangles.append(allocator, .{ top_left, bottom_right, bottom_left });
        }
    }
}

/// Triangulates one simple polygon by repeatedly clipping convex ears. Returns false if it runs out
/// of ears, which leaves the polygon unfinished.
fn ear_clip(allocator: std.mem.Allocator, points: []const Point(Pixels), triangles: *std.ArrayList([3]Point(Pixels))) !bool {
    var area: f32 = 0;
    for (points, 0..) |point, index| {
        area += cross(point, points[(index + 1) % points.len]);
    }
    if (@abs(area) < epsilon) return true;
    const sign: f32 = if (area > 0) 1 else -1;

    var remaining: std.ArrayList(usize) = .empty;
    defer remaining.deinit(allocator);
    try remaining.ensureTotalCapacity(allocator, points.len);
    for (0..points.len) |index| remaining.appendAssumeCapacity(index);

    while (remaining.items.len > 3) {
        const count = remaining.items.len;
        var clipped = false;
        for (0..count) |position| {
            const prev_index = remaining.items[(position + count - 1) % count];
            const current_index = remaining.items[position];
            const next_index = remaining.items[(position + 1) % count];
            const a = points[prev_index];
            const b = points[current_index];
            const c = points[next_index];

            if (sign * cross(b.sub(a), c.sub(b)) <= epsilon) continue;

            var blocked = false;
            for (remaining.items) |other| {
                if (other == prev_index or other == current_index or other == next_index) continue;
                if (point_in_triangle(points[other], a, b, c, sign)) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;

            try triangles.append(allocator, .{ a, b, c });
            _ = remaining.orderedRemove(position);
            clipped = true;
            break;
        }
        if (!clipped) return false;
    }

    if (remaining.items.len == 3) {
        const a = points[remaining.items[0]];
        const b = points[remaining.items[1]];
        const c = points[remaining.items[2]];
        if (@abs(cross(b.sub(a), c.sub(a))) > epsilon) try triangles.append(allocator, .{ a, b, c });
    }
    return true;
}

/// Emits a quad per segment and a bevel triangle per join, so an open or closed polyline is covered.
fn stroke_polyline(
    allocator: std.mem.Allocator,
    points: []const Point(Pixels),
    closed: bool,
    half_width: f32,
    triangles: *std.ArrayList([3]Point(Pixels)),
) !void {
    const count = points.len;
    const segment_count = if (closed) count else count - 1;

    var index: usize = 0;
    while (index < segment_count) : (index += 1) {
        const a = points[index];
        const b = points[(index + 1) % count];
        const direction = unit(a, b) orelse continue;
        const normal = left_normal(direction, half_width);

        const p0 = a.add(normal);
        const p1 = a.sub(normal);
        const p2 = b.sub(normal);
        const p3 = b.add(normal);
        try triangles.append(allocator, .{ p0, p1, p2 });
        try triangles.append(allocator, .{ p0, p2, p3 });
    }

    // Joins: cover the gap on the outer side of each bend.
    var vertex: usize = if (closed) 0 else 1;
    const vertex_end = if (closed) count else count - 1;
    while (vertex < vertex_end) : (vertex += 1) {
        const previous = points[(vertex + count - 1) % count];
        const current = points[vertex];
        const next = points[(vertex + 1) % count];
        const previous_direction = unit(previous, current) orelse continue;
        const next_direction = unit(current, next) orelse continue;

        const turn = cross(previous_direction, next_direction);
        if (@abs(turn) < epsilon) continue;
        const side: f32 = if (turn > 0) -1 else 1;
        const previous_normal = left_normal(previous_direction, half_width * side);
        const next_normal = left_normal(next_direction, half_width * side);
        try triangles.append(allocator, .{ current, current.add(previous_normal), current.add(next_normal) });
    }
}

/// Splits the polyline into the "on" pieces of `pattern` and strokes each piece.
fn stroke_dashed(
    allocator: std.mem.Allocator,
    points: []const Point(Pixels),
    closed: bool,
    pattern: []const Pixels,
    half_width: f32,
    triangles: *std.ArrayList([3]Point(Pixels)),
) !void {
    var total: f32 = 0;
    for (pattern) |length| total += length;
    if (total <= 0) return stroke_polyline(allocator, points, closed, half_width, triangles);

    var piece: std.ArrayList(Point(Pixels)) = .empty;
    defer piece.deinit(allocator);

    var on = true;
    var pattern_index: usize = 0;
    var remaining = pattern[0];

    const count = points.len;
    const segment_count = if (closed) count else count - 1;
    var segment: usize = 0;
    while (segment < segment_count) : (segment += 1) {
        const a = points[segment];
        const b = points[(segment + 1) % count];
        const segment_length = distance(a, b);
        if (segment_length < epsilon) continue;
        const direction = unit(a, b) orelse continue;

        if (on and piece.items.len == 0) try piece.append(allocator, a);

        var position: f32 = 0;
        while (segment_length - position > remaining) {
            position += remaining;
            const boundary = a.add(direction.mul(position));
            if (on) {
                try piece.append(allocator, boundary);
                try stroke_polyline(allocator, piece.items, false, half_width, triangles);
                piece.clearRetainingCapacity();
            } else {
                try piece.append(allocator, boundary);
            }
            on = !on;
            pattern_index = (pattern_index + 1) % pattern.len;
            remaining = pattern[pattern_index];
        }
        remaining -= segment_length - position;
        if (on) try piece.append(allocator, b);
    }

    if (on and piece.items.len >= 2) try stroke_polyline(allocator, piece.items, false, half_width, triangles);
}

/// Appends each triangle as a fill triangle (texture coordinates `(0, 1)`) to the path.
fn build_path(allocator: std.mem.Allocator, triangles: []const [3]Point(Pixels)) !Path(Pixels) {
    const first = if (triangles.len > 0) triangles[0][0] else Point(Pixels){};
    var path = Path(Pixels).new(allocator, first);
    errdefer path.deinit();
    const texture_corner: Point(f32) = .{ .x = 0, .y = 1 };
    for (triangles) |triangle| {
        try path.push_triangle(triangle, .{ texture_corner, texture_corner, texture_corner });
    }
    return path;
}

fn distance(a: Point(Pixels), b: Point(Pixels)) f32 {
    const d = b.sub(a);
    return @sqrt(d.x * d.x + d.y * d.y);
}

/// Unit vector from `a` to `b`, or null when they coincide.
fn unit(a: Point(Pixels), b: Point(Pixels)) ?Point(Pixels) {
    const length = distance(a, b);
    if (length < epsilon) return null;
    return b.sub(a).div(length);
}

/// Normal to the left of `direction`, scaled to `length`.
fn left_normal(direction: Point(Pixels), length: f32) Point(Pixels) {
    return .{ .x = -direction.y * length, .y = direction.x * length };
}

fn triangle_area(triangle: [3]Point(Pixels)) f32 {
    return @abs(cross(triangle[1].sub(triangle[0]), triangle[2].sub(triangle[0]))) / 2;
}

fn sum_triangle_area(path: *const Path(Pixels)) f32 {
    var total: f32 = 0;
    var index: usize = 0;
    while (index + 2 < path.vertices.items.len) : (index += 3) {
        total += triangle_area(.{
            path.vertices.items[index].xy_position,
            path.vertices.items[index + 1].xy_position,
            path.vertices.items[index + 2].xy_position,
        });
    }
    return total;
}

fn point_at(x: f32, y: f32) Point(Pixels) {
    return .{ .x = x, .y = y };
}

test "fill square tessellates into two triangles" {
    var builder = PathBuilder.fill(testing.allocator);
    try builder.add_polygon(&.{ point_at(0, 0), point_at(10, 0), point_at(10, 10), point_at(0, 10) }, true);

    var path = try builder.build();
    defer path.deinit();
    try testing.expectEqual(@as(usize, 6), path.vertices.items.len);
    try testing.expectEqual(@as(f32, 0), path.bounds.origin.x);
    try testing.expectEqual(@as(f32, 10), path.bounds.size.width);
    try testing.expectApproxEqAbs(@as(f32, 100), sum_triangle_area(&path), 1e-3);
}

test "ear clipping handles a concave L shape" {
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
    try testing.expectEqual(@as(usize, 12), path.vertices.items.len);
    try testing.expectApproxEqAbs(@as(f32, 75), sum_triangle_area(&path), 1e-3);
}

fn covered_area(triangles: []const [3]Point(Pixels)) f32 {
    var total: f32 = 0;
    for (triangles) |t| total += @abs(cross(t[1].sub(t[0]), t[2].sub(t[0]))) / 2;
    return total;
}

fn covers(triangles: []const [3]Point(Pixels), p: Point(Pixels)) bool {
    for (triangles) |t| {
        const sign: f32 = if (cross(t[1].sub(t[0]), t[2].sub(t[0])) > 0) 1 else -1;
        if (point_in_triangle(p, t[0], t[1], t[2], sign)) return true;
    }
    return false;
}

fn fill_test(contours: []const []const Point(Pixels)) !std.ArrayList([3]Point(Pixels)) {
    var builder = PathBuilder.fill(std.testing.allocator);
    defer builder.deinit();
    for (contours) |points| try builder.add_polygon(points, true);
    var triangles: std.ArrayList([3]Point(Pixels)) = .empty;
    try builder.tessellate_fill(&triangles);
    return triangles;
}

test "fill: a self-intersecting bowtie covers both lobes and not the gaps" {
    var triangles = try fill_test(&.{&.{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 2 } }});
    defer triangles.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 2), covered_area(triangles.items), 0.001);
    try std.testing.expect(covers(triangles.items, .{ .x = 0.2, .y = 1 }));
    try std.testing.expect(covers(triangles.items, .{ .x = 1.8, .y = 1 }));
    try std.testing.expect(!covers(triangles.items, .{ .x = 1, .y = 0.2 }));
    try std.testing.expect(!covers(triangles.items, .{ .x = 1, .y = 1.8 }));
}

test "fill: an inner contour is a hole" {
    var triangles = try fill_test(&.{
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } },
        &.{ .{ .x = 1, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 3 }, .{ .x = 1, .y = 3 } },
    });
    defer triangles.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 12), covered_area(triangles.items), 0.001);
    try std.testing.expect(!covers(triangles.items, .{ .x = 2, .y = 2 }));
    try std.testing.expect(covers(triangles.items, .{ .x = 0.5, .y = 2 }));
}

test "fill: a pentagram has an even-odd hole in the middle" {
    var points: [5]Point(Pixels) = undefined;
    for (&points, 0..) |*point, i| {
        const pi: f32 = std.math.pi;
        const angle = @as(f32, @floatFromInt(i)) * 4 * pi / 5 - pi / 2;
        point.* = .{ .x = 10 * @cos(angle), .y = 10 * @sin(angle) };
    }
    var triangles = try fill_test(&.{&points});
    defer triangles.deinit(std.testing.allocator);
    try std.testing.expect(!covers(triangles.items, .{ .x = 0, .y = 0 }));
    try std.testing.expect(covers(triangles.items, .{ .x = 0, .y = -8 }));
}

test "fill: a simple polygon still clips ears" {
    var triangles = try fill_test(&.{&.{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 } }});
    defer triangles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), triangles.items.len);
}

test "stroked segment covers its width" {
    var builder = PathBuilder.stroke(testing.allocator, 2);
    try builder.move_to(point_at(0, 0));
    try builder.line_to(point_at(10, 0));

    var path = try builder.build();
    defer path.deinit();
    try testing.expectEqual(@as(usize, 6), path.vertices.items.len);
    try testing.expectApproxEqAbs(@as(f32, -1), path.bounds.origin.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), path.bounds.size.height, 1e-4);
}

test "stroke joins add a bevel at bends" {
    var builder = PathBuilder.stroke(testing.allocator, 2);
    try builder.move_to(point_at(0, 0));
    try builder.line_to(point_at(10, 0));
    try builder.line_to(point_at(10, 10));

    var path = try builder.build();
    defer path.deinit();
    try testing.expectEqual(@as(usize, 15), path.vertices.items.len);
}

test "dash pattern splits a stroke into pieces" {
    var builder = PathBuilder.stroke(testing.allocator, 1);
    try builder.dash_array_set(&.{ 2, 2 });
    try builder.move_to(point_at(0, 0));
    try builder.line_to(point_at(10, 0));

    var path = try builder.build();
    defer path.deinit();
    // Pieces [0,2], [4,6] and [8,10] are three quads of two triangles each.
    try testing.expectEqual(@as(usize, 18), path.vertices.items.len);
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
