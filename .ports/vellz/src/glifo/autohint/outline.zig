//! Outline representation and helpers for autohinting.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/outline.rs`: the per-point
//! representation with directions and weak-point markers, plus the segment
//! preprocessing passes (`link_points`, near/direction computation,
//! topology simplification and orientation).

const std = @import("std");
const glyf = @import("../glyf.zig");
const metrics = @import("metrics.zig");
const fixed = @import("fixed.zig");

pub const PointFlags = struct {
    pub const on_curve: u8 = 0x01;
    pub const cubic: u8 = 0x80;
    pub const marker_near: u8 = 0x08;
    pub const marker_weak_interpolation: u8 = 0x02;
    pub const marker_touched_x: u8 = 0x10;
    pub const marker_touched_y: u8 = 0x20;
};

/// Hinting directions; `dir1 + dir2 == 0` when opposite.
pub const Direction = enum(i8) {
    /// Undetermined direction.
    none = 4,
    /// Toward the right.
    right = 1,
    /// Toward the left.
    left = -1,
    /// Toward the top.
    up = 2,
    /// Toward the bottom.
    down = -2,

    /// Computes a direction from a vector (FreeType `af_direction_from_vectors`).
    pub fn new(dx: i32, dy: i32) Direction {
        var result: Direction = .none;
        var long_arm: i32 = 0;
        var short_arm: i32 = 0;
        if (dy >= dx) {
            if (dy >= -dx) {
                result = .up;
                long_arm = dy;
                short_arm = dx;
            } else {
                result = .left;
                long_arm = -dx;
                short_arm = dy;
            }
        } else if (dy >= -dx) {
            result = .right;
            long_arm = dx;
            short_arm = dy;
        } else {
            result = .down;
            long_arm = -dy;
            short_arm = dx;
        }
        // Return no direction if arm lengths do not differ enough.
        if (long_arm <= 14 *% @as(i32, @intCast(@abs(short_arm)))) {
            return .none;
        }
        return result;
    }

    pub fn isOpposite(self: Direction, other: Direction) bool {
        return @as(i8, @intFromEnum(self)) +% @as(i8, @intFromEnum(other)) == 0;
    }

    pub fn isSameAxis(self: Direction, other: Direction) bool {
        return @abs(@as(i8, @intFromEnum(self))) == @abs(@as(i8, @intFromEnum(other)));
    }

    pub fn normalize(self: Direction) Direction {
        return switch (self) {
            .left => .right,
            .down => .up,
            else => self,
        };
    }
};

/// The overall orientation of an outline.
pub const Orientation = enum { clockwise, counter_clockwise };

/// Outline point with the context required for hinting.
pub const Point = struct {
    /// Describes the type and hinting state of the point.
    flags: u8 = 0,
    /// X coordinate in font units.
    fx: i32 = 0,
    /// Y coordinate in font units.
    fy: i32 = 0,
    /// Scaled X coordinate.
    ox: i32 = 0,
    /// Scaled Y coordinate.
    oy: i32 = 0,
    /// Hinted X coordinate.
    x: i32 = 0,
    /// Hinted Y coordinate.
    y: i32 = 0,
    /// Direction of inwards vector.
    in_dir: Direction = .none,
    /// Direction of outwards vector.
    out_dir: Direction = .none,
    /// Context dependent coordinate.
    u: i32 = 0,
    /// Context dependent coordinate.
    v: i32 = 0,
    /// Index of next point in contour.
    next_ix: u16 = 0,
    /// Index of previous point in contour.
    prev_ix: u16 = 0,

    pub fn isOnCurve(self: Point) bool {
        return self.flags & PointFlags.on_curve != 0;
    }

    pub fn next(self: Point) usize {
        return self.next_ix;
    }

    pub fn prev(self: Point) usize {
        return self.prev_ix;
    }
};

/// Inclusive index range of one contour.
pub const Contour = struct {
    first_ix: u16 = 0,
    last_ix: u16 = 0,

    pub fn first(self: Contour) usize {
        return self.first_ix;
    }

    pub fn last(self: Contour) usize {
        return self.last_ix;
    }

    pub fn next(self: Contour, index: usize) usize {
        if (index >= self.last_ix) return self.first_ix;
        return index + 1;
    }

    pub fn prev(self: Contour, index: usize) usize {
        if (index <= self.first_ix) return self.last_ix;
        return index - 1;
    }
};

/// An autohint outline in font units.
pub const Outline = struct {
    /// Allocator used by the sink callbacks during `fill`.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    units_per_em: i32 = 0,
    orientation: ?Orientation = null,
    points: std.ArrayListUnmanaged(Point) = .empty,
    contours: std.ArrayListUnmanaged(Contour) = .empty,
    advance: i32 = 0,

    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.contours.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *Outline) void {
        self.units_per_em = 0;
        self.points.clearRetainingCapacity();
        self.contours.clearRetainingCapacity();
        self.advance = 0;
        self.orientation = null;
    }

    // Sink callbacks used by `glyf.Outlines.drawUnscaled`.
    pub fn tryReserve(self: *Outline, additional: usize) glyf.DrawError!void {
        self.points.ensureUnusedCapacity(self.allocator, additional) catch {
            return error.OutOfMemory;
        };
    }

    pub fn push(self: *Outline, point: glyf.UnscaledSinkPoint) glyf.DrawError!void {
        const allocator = self.allocator;
        const new_point_ix = std.math.cast(u16, self.points.items.len) orelse
            return error.OutOfMemory;
        if (point.is_contour_start) {
            self.contours.append(allocator, .{
                .first_ix = new_point_ix,
                .last_ix = new_point_ix,
            }) catch return error.OutOfMemory;
        } else if (self.contours.items.len > 0) {
            self.contours.items[self.contours.items.len - 1].last_ix +%= 1;
        } else {
            self.contours.append(allocator, .{
                .first_ix = new_point_ix,
                .last_ix = new_point_ix,
            }) catch return error.OutOfMemory;
        }
        self.points.append(allocator, .{
            .flags = point.flags,
            .fx = point.x,
            .fy = point.y,
        }) catch return error.OutOfMemory;
    }

    /// Fills the outline from the scaler with the same preprocessing passes
    /// upstream runs after `draw_unscaled`.
    pub fn fill(
        self: *Outline,
        allocator: std.mem.Allocator,
        outlines: *const glyf.Outlines,
        gid: glyf.GlyphId,
        quirks: metrics.QuirksMode,
    ) glyf.DrawError!void {
        self.clear();
        self.allocator = allocator;
        self.advance = try outlines.drawUnscaled(allocator, gid, self);
        self.units_per_em = outlines.unitsPerEm();
        // Heuristic value
        const near_limit = @divTrunc(20 * self.units_per_em, 2048);
        self.linkPoints();
        self.markNearPoints(near_limit);
        self.computeDirections(near_limit);
        self.simplifyTopology();
        switch (quirks) {
            .aot => self.checkRemainingWeakPoints(isCornerFlatAot),
            .jit => self.checkRemainingWeakPoints(isCornerFlatJit),
        }
        self.computeOrientation();
    }

    /// Applies dimension-specific scaling factors and deltas to each point.
    pub fn scaleBy(self: *Outline, scale: *const metrics.Scale) void {
        for (self.points.items) |*point| {
            const x = fixed.mul(point.fx, scale.x_scale) +% scale.x_delta;
            const y = fixed.mul(point.fy, scale.y_scale) +% scale.y_delta;
            point.ox = x;
            point.x = x;
            point.oy = y;
            point.y = y;
        }
    }

    /// Emits the hinted outline through the shared FreeType path conversion.
    pub fn toPath(
        self: *const Outline,
        allocator: std.mem.Allocator,
        style: glyf.PathStyle,
        pen: anytype,
    ) glyf.DrawError!void {
        const packed_points = try allocator.alloc(glyf.PathContourPoint, self.points.items.len);
        defer allocator.free(packed_points);
        for (self.points.items, 0..) |point, ix| {
            packed_points[ix] = .{ .x = point.x, .y = point.y, .flags = point.flags };
        }
        for (self.contours.items) |contour| {
            if (contour.last() >= packed_points.len) continue;
            try glyf.contourPointsToPath(
                packed_points[contour.first() .. contour.last() + 1],
                style,
                pen,
            );
        }
    }

    // ------------------------------------------------------------ internals

    fn linkPoints(self: *Outline) void {
        for (self.contours.items) |contour| {
            if (contour.last() >= self.points.items.len) continue;
            const first_ix = contour.first_ix;
            var prev_ix = contour.last_ix;
            var ix = contour.first();
            while (ix <= contour.last()) : (ix += 1) {
                const point = &self.points.items[ix];
                point.prev_ix = @intCast(ix);
                prev_ix = @intCast(ix);
                point.next_ix = @truncate(ix + 1);
            }
            self.points.items[contour.last()].next_ix = first_ix;
        }
    }

    fn markNearPoints(self: *Outline, near_limit: i32) void {
        for (self.contours.items) |contour| {
            if (contour.last() >= self.points.items.len) continue;
            var prev_ix = contour.last();
            var ix = contour.first();
            while (ix <= contour.last()) : (ix += 1) {
                const point = self.points.items[ix];
                const prev = &self.points.items[prev_ix];
                const out_x = point.fx -% prev.fx;
                const out_y = point.fy -% prev.fy;
                if (@as(i32, @intCast(@abs(out_x))) +% @as(i32, @intCast(@abs(out_y))) < near_limit) {
                    prev.flags |= PointFlags.marker_near;
                }
                prev_ix = ix;
            }
        }
    }

    fn computeDirections(self: *Outline, near_limit: i32) void {
        const near_limit2 = 2 *% near_limit -% 1;
        for (self.contours.items) |contour| {
            if (contour.last() >= self.points.items.len) continue;
            // Walk backward to find the first non-near point.
            var first_ix = contour.first();
            var ix = first_ix;
            var prev_ix = contour.prev(first_ix);
            var point = self.points.items[first_ix];
            while (prev_ix != first_ix) {
                const prev = self.points.items[prev_ix];
                const out_x = point.fx -% prev.fx;
                const out_y = point.fy -% prev.fy;
                if (@as(i32, @intCast(@abs(out_x))) +% @as(i32, @intCast(@abs(out_y))) >= near_limit2) {
                    break;
                }
                point = prev;
                ix = prev_ix;
                prev_ix = contour.prev(prev_ix);
            }
            first_ix = ix;
            // Abuse u and v to store deltas to the next and previous
            // non-near points, respectively.
            self.points.items[first_ix].u = @intCast(first_ix);
            self.points.items[first_ix].v = @intCast(first_ix);
            var next_ix = first_ix;
            ix = first_ix;
            var out_x: i32 = 0;
            var out_y: i32 = 0;
            while (true) {
                const point_ix = next_ix;
                next_ix = contour.next(point_ix);
                const point_value = self.points.items[point_ix];
                const next = &self.points.items[next_ix];
                // Accumulate the deltas until we surpass near_limit.
                out_x +%= next.fx -% point_value.fx;
                out_y +%= next.fy -% point_value.fy;
                if (@as(i32, @intCast(@abs(out_x))) +% @as(i32, @intCast(@abs(out_y))) < near_limit) {
                    next.flags |= PointFlags.marker_weak_interpolation;
                    if (next_ix == first_ix) break;
                    continue;
                }
                const out_dir = Direction.new(out_x, out_y);
                next.in_dir = out_dir;
                next.v = @intCast(ix);
                const cur = &self.points.items[ix];
                cur.u = @intCast(next_ix);
                cur.out_dir = out_dir;
                // Adjust directions for all intermediate points.
                var inter_ix = contour.next(ix);
                while (inter_ix != next_ix) {
                    const inter = &self.points.items[inter_ix];
                    inter.in_dir = out_dir;
                    inter.out_dir = out_dir;
                    inter_ix = contour.next(inter_ix);
                }
                ix = next_ix;
                self.points.items[ix].u = @intCast(first_ix);
                self.points.items[first_ix].v = @intCast(ix);
                out_x = 0;
                out_y = 0;
                if (next_ix == first_ix) break;
            }
        }
    }

    fn simplifyTopology(self: *Outline) void {
        for (0..self.points.items.len) |i| {
            const point = self.points.items[i];
            if (point.flags & PointFlags.marker_weak_interpolation != 0) continue;
            if (point.in_dir == .none and point.out_dir == .none) {
                const u_index: usize = @intCast(point.u);
                const v_index: usize = @intCast(point.v);
                if (u_index >= self.points.items.len or v_index >= self.points.items.len) continue;
                const next_u = self.points.items[u_index];
                const prev_v = self.points.items[v_index];
                const in_x = point.fx -% prev_v.fx;
                const in_y = point.fy -% prev_v.fy;
                const out_x = next_u.fx -% point.fx;
                const out_y = next_u.fy -% point.fy;
                if ((in_x ^ out_x) >= 0 and (in_y ^ out_y) >= 0) {
                    // Both vectors point into the same quadrant.
                    self.points.items[i].flags |= PointFlags.marker_weak_interpolation;
                    self.points.items[v_index].u = @intCast(u_index);
                    self.points.items[u_index].v = @intCast(v_index);
                }
            }
        }
    }

    fn checkRemainingWeakPoints(
        self: *Outline,
        is_corner_flat: *const fn (i32, i32, i32, i32) bool,
    ) void {
        for (0..self.points.items.len) |i| {
            const point = self.points.items[i];
            var make_weak = false;
            if (point.flags & PointFlags.marker_weak_interpolation != 0) continue;
            if (!point.isOnCurve()) {
                // Control points are always weak.
                make_weak = true;
            } else if (point.out_dir == point.in_dir) {
                if (point.out_dir != .none) {
                    // Point lies on a vertical or horizontal segment but not
                    // at start or end.
                    make_weak = true;
                } else {
                    const u_index: usize = @intCast(point.u);
                    const v_index: usize = @intCast(point.v);
                    if (u_index >= self.points.items.len or v_index >= self.points.items.len) continue;
                    const next_u = self.points.items[u_index];
                    const prev_v = self.points.items[v_index];
                    if (is_corner_flat(
                        point.fx -% prev_v.fx,
                        point.fy -% prev_v.fy,
                        next_u.fx -% point.fx,
                        next_u.fy -% point.fy,
                    )) {
                        // One of the vectors is more dominant.
                        make_weak = true;
                        self.points.items[v_index].u = @intCast(u_index);
                        self.points.items[u_index].v = @intCast(v_index);
                    }
                }
            } else if (point.in_dir.isOpposite(point.out_dir)) {
                // Point forms a "spike".
                make_weak = true;
            }
            if (make_weak) {
                self.points.items[i].flags |= PointFlags.marker_weak_interpolation;
            }
        }
    }

    fn computeOrientation(self: *Outline) void {
        self.orientation = null;
        if (self.points.items.len == 0) return;
        var area: i64 = 0;
        for (self.contours.items) |contour| {
            if (contour.last() >= self.points.items.len) continue;
            const last_ix = contour.last();
            const first_ix = contour.first();
            var prev_x: i64 = self.points.items[last_ix].fx;
            var prev_y: i64 = self.points.items[last_ix].fy;
            var ix = first_ix;
            while (ix <= last_ix) : (ix += 1) {
                const x: i64 = self.points.items[ix].fx;
                const y: i64 = self.points.items[ix].fy;
                area += (y - prev_y) * (x + prev_x);
                prev_x = x;
                prev_y = y;
            }
        }
        if (area < 0) {
            self.orientation = .counter_clockwise;
        } else if (area > 0) {
            self.orientation = .clockwise;
        }
    }
};

/// Offline or "ahead of time" version from ttfautohint.
pub fn isCornerFlatAot(in_x: i32, in_y: i32, out_x: i32, out_y: i32) bool {
    const d_in = @as(i32, @intCast(@abs(in_x))) +% @as(i32, @intCast(@abs(in_y)));
    const d_out = @as(i32, @intCast(@abs(out_x))) +% @as(i32, @intCast(@abs(out_y)));
    const d_corner = @as(i32, @intCast(@abs(in_x +% out_x))) +%
        @as(i32, @intCast(@abs(in_y +% out_y)));
    return (d_in +% d_out -% d_corner) < (d_corner >> 4);
}

/// Runtime or "just in time" hinted version from FreeType.
pub fn isCornerFlatJit(in_x: i32, in_y: i32, out_x: i32, out_y: i32) bool {
    const ax = in_x +% out_x;
    const ay = in_y +% out_y;
    const d_in = hypot(in_x, in_y);
    const d_out = hypot(out_x, out_y);
    const d_hypot = hypot(ax, ay);
    return (d_in +% d_out -% d_hypot) < (d_hypot >> 4);
}

fn hypot(x_raw: i32, y_raw: i32) i32 {
    const x: i32 = @intCast(@abs(x_raw));
    const y: i32 = @intCast(@abs(y_raw));
    if (x > y) return x +% ((3 *% y) >> 3);
    return y +% ((3 *% x) >> 3);
}

test "direction from vectors matches upstream" {
    try std.testing.expectEqual(Direction.left, Direction.new(-100, 0));
    try std.testing.expectEqual(Direction.right, Direction.new(100, 0));
    try std.testing.expectEqual(Direction.down, Direction.new(0, -100));
    try std.testing.expectEqual(Direction.up, Direction.new(0, 100));
    try std.testing.expectEqual(Direction.up, Direction.new(7, 100));
    // This triggers the too-close heuristic.
    try std.testing.expectEqual(Direction.none, Direction.new(8, 100));
}

test "direction axes and opposites" {
    const hori = [_]Direction{ .left, .right };
    const vert = [_]Direction{ .up, .down };
    for (hori) |h| {
        for (hori) |h2| {
            try std.testing.expect(h.isSameAxis(h2));
            if (h != h2) {
                try std.testing.expect(h.isOpposite(h2));
            } else {
                try std.testing.expect(!h.isOpposite(h2));
            }
        }
        for (vert) |v| {
            try std.testing.expect(!h.isSameAxis(v));
            try std.testing.expect(!h.isOpposite(v));
        }
    }
    for (vert) |v| {
        for (vert) |v2| {
            try std.testing.expect(v.isSameAxis(v2));
            if (v != v2) {
                try std.testing.expect(v.isOpposite(v2));
            } else {
                try std.testing.expect(!v.isOpposite(v2));
            }
        }
    }
}
