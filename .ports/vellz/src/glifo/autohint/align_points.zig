//! Aligning hinted points to the grid-fitted edges.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/hint/outline.rs`: the three
//! passes that map edge positions onto outline points (direct edge points,
//! strong-point interpolation and weak-point IUP interpolation).

const std = @import("std");
const metrics = @import("metrics.zig");
const outline_mod = @import("outline.zig");
const topo = @import("topo.zig");

const Dimension = @import("types.zig").Dimension;
const Direction = outline_mod.Direction;
const Outline = outline_mod.Outline;
const Point = outline_mod.Point;
const ScriptGroup = topo.ScriptGroup;
const PointFlags = outline_mod.PointFlags;

/// Aligns all points of an edge to the same coordinate value.
pub fn alignEdgePoints(
    outline: *Outline,
    axis: *const topo.Axis,
    script_group: ScriptGroup,
    scale: *const metrics.Scale,
) void {
    const edges = axis.edges.items;
    const segments = axis.segments.items;
    const points = outline.points.items;
    // Snapping is configurable for CJK.
    const snap = script_group == .default or
        (axis.dim == .horizontal and scale.flags.contains(metrics.ScaleFlags.horizontal_snap)) or
        (axis.dim == .vertical and scale.flags.contains(metrics.ScaleFlags.vertical_snap));
    for (segments) |segment| {
        const edge = segment.edge(edges) orelse continue;
        const delta = edge.pos - edge.opos;
        var point_ix = segment.first();
        const last_ix = segment.last();
        while (true) {
            if (point_ix >= points.len) return;
            const point = &points[point_ix];
            if (axis.dim == .horizontal) {
                if (snap) {
                    point.x = edge.pos;
                } else {
                    point.x +%= delta;
                }
                point.flags |= PointFlags.marker_touched_x;
            } else {
                if (snap) {
                    point.y = edge.pos;
                } else {
                    point.y +%= delta;
                }
                point.flags |= PointFlags.marker_touched_y;
            }
            if (point_ix == last_ix) break;
            point_ix = point.next();
        }
    }
}

/// Aligns the strong points; equivalent to the TrueType `IP` instruction.
pub fn alignStrongPoints(outline: *Outline, axis: *topo.Axis) void {
    if (axis.edges.items.len == 0) return;
    const dim = axis.dim;
    const touch_flag: u8 = if (dim == .horizontal)
        PointFlags.marker_touched_x
    else
        PointFlags.marker_touched_y;
    const points = outline.points.items;
    outer: for (points, 0..) |*point, point_ix| {
        _ = point_ix;
        // Skip points that are already touched; weak interpolation runs in
        // the next pass.
        if (point.flags & (touch_flag | PointFlags.marker_weak_interpolation) != 0) continue;
        const u: i32 = if (dim == .vertical) point.fy else point.fx;
        const ou: i32 = if (dim == .vertical) point.oy else point.ox;
        const edges = axis.edges.items;
        // Is the point before the first edge?
        const first_edge = edges[0];
        const delta_first = first_edge.fpos - u;
        if (delta_first >= 0) {
            storePoint(point, dim, first_edge.pos - (first_edge.opos - ou));
            continue;
        }
        // Is the point after the last edge?
        const last_edge = edges[edges.len - 1];
        const delta_last = u - @as(i32, last_edge.fpos);
        if (delta_last >= 0) {
            storePoint(point, dim, last_edge.pos + (ou - last_edge.opos));
            continue;
        }
        // Find enclosing edges; for a small number of edges use a linear
        // search. This is critical for matching FreeType when multiple edges
        // share an fpos.
        var min_ix: usize = 0;
        if (edges.len <= 8) {
            var found = false;
            for (edges, 0..) |edge, ix| {
                if (@as(i32, edge.fpos) >= u) {
                    if (edge.fpos == u) {
                        storePoint(point, dim, edge.pos);
                        continue :outer;
                    }
                    min_ix = ix;
                    found = true;
                    break;
                }
            }
            if (!found) min_ix = 0;
        } else {
            var lo: usize = 0;
            var hi: usize = edges.len;
            while (lo < hi) {
                const mid = (lo + hi) >> 1;
                const edge = edges[mid];
                const fpos: i32 = edge.fpos;
                if (u < fpos) {
                    hi = mid;
                } else if (u > fpos) {
                    lo = mid + 1;
                } else {
                    storePoint(point, dim, edge.pos);
                    continue :outer;
                }
            }
            min_ix = lo;
        }
        // Point is not on an edge.
        if (min_ix == 0) continue;
        const before_ix = min_ix - 1;
        if (before_ix >= edges.len or min_ix >= edges.len) continue;
        const edge_before = &axis.edges.items[before_ix];
        const before_pos = edge_before.pos;
        const before_fpos: i32 = edge_before.fpos;
        const edge_scale = if (edge_before.scale == 0) blk: {
            const edge_after = edges[min_ix];
            const scale = metrics.fixedDiv(
                edge_after.pos - edge_before.pos,
                edge_after.fpos - before_fpos,
            );
            edge_before.scale = scale;
            break :blk scale;
        } else edge_before.scale;
        storePoint(point, dim, before_pos + metrics.fixedMul(u - before_fpos, edge_scale));
    }
}

fn storePoint(point: *Point, dim: Dimension, u: i32) void {
    if (dim == .horizontal) {
        point.x = u;
        point.flags |= PointFlags.marker_touched_x;
    } else {
        point.y = u;
        point.flags |= PointFlags.marker_touched_y;
    }
}

/// Aligns the weak points; equivalent to the TrueType `IUP` instruction.
pub fn alignWeakPoints(outline: *Outline, dim: Dimension) void {
    const touch_marker: u8 = if (dim == .horizontal) blk: {
        for (outline.points.items) |*point| {
            point.u = point.x;
            point.v = point.ox;
        }
        break :blk PointFlags.marker_touched_x;
    } else blk: {
        for (outline.points.items) |*point| {
            point.u = point.y;
            point.v = point.oy;
        }
        break :blk PointFlags.marker_touched_y;
    };
    for (outline.contours.items) |contour| {
        if (contour.last() >= outline.points.items.len) continue;
        const points = outline.points.items[contour.first() .. contour.last() + 1];
        // Find the first touched point.
        var first_touched_ix: ?usize = null;
        for (points, 0..) |point, ix| {
            if (point.flags & touch_marker != 0) {
                first_touched_ix = ix;
                break;
            }
        }
        const first_touched = first_touched_ix orelse continue;
        const last_ix = points.len - 1;
        var point_ix = first_touched;
        var last_touched_ix: usize = 0;
        outer: while (true) {
            // Skip any touched neighbors.
            while (point_ix < last_ix and points[point_ix + 1].flags & touch_marker != 0) {
                point_ix += 1;
            }
            last_touched_ix = point_ix;
            // Find the next touched point.
            point_ix += 1;
            while (true) {
                if (point_ix > last_ix) break :outer;
                if (points[point_ix].flags & touch_marker != 0) break;
                point_ix += 1;
            }
            iupInterpolate(points, last_touched_ix + 1, point_ix - 1, last_touched_ix, point_ix);
        }
        if (last_touched_ix == first_touched) {
            // Special case: only one point was touched.
            iupShift(points, 0, last_ix, first_touched);
        } else {
            // Interpolate the remainder.
            if (last_touched_ix < last_ix) {
                iupInterpolate(points, last_touched_ix + 1, last_ix, last_touched_ix, first_touched);
            }
            if (first_touched > 0) {
                iupInterpolate(points, 0, first_touched - 1, last_touched_ix, first_touched);
            }
        }
    }
    // Save interpolated values.
    if (dim == .horizontal) {
        for (outline.points.items) |*point| {
            point.x = point.u;
        }
    } else {
        for (outline.points.items) |*point| {
            point.y = point.u;
        }
    }
}

/// Shifts original coordinates of all points between `p1_ix` and `p2_ix`
/// (inclusive) by the difference at `ref_ix`.
fn iupShift(points: []Point, p1_ix: usize, p2_ix: usize, ref_ix: usize) void {
    if (ref_ix >= points.len or p1_ix > p2_ix or p2_ix >= points.len) return;
    const ref_point = points[ref_ix];
    const delta = ref_point.u - ref_point.v;
    if (delta == 0) return;
    var ix = p1_ix;
    while (ix < ref_ix) : (ix += 1) {
        points[ix].u = points[ix].v + delta;
    }
    ix = ref_ix + 1;
    while (ix <= p2_ix) : (ix += 1) {
        points[ix].u = points[ix].v + delta;
    }
}

/// Interpolates the coordinates of all points between `p1_ix` and `p2_ix`
/// using `ref1_ix`/`ref2_ix` as reference points.
fn iupInterpolate(
    points: []Point,
    p1_ix: usize,
    p2_ix: usize,
    ref1_ix: usize,
    ref2_ix: usize,
) void {
    if (p1_ix > p2_ix) return;
    if (ref1_ix >= points.len or ref2_ix >= points.len or p2_ix >= points.len) return;
    var ref_point1 = points[ref1_ix];
    var ref_point2 = points[ref2_ix];
    if (ref_point1.v > ref_point2.v) {
        const tmp = ref_point1;
        ref_point1 = ref_point2;
        ref_point2 = tmp;
    }
    const r1_u = ref_point1.u;
    const v1 = ref_point1.v;
    const r2_u = ref_point2.u;
    const v2 = ref_point2.v;
    const d1 = r1_u - v1;
    const d2 = r2_u - v2;
    if (r1_u == r2_u or v1 == v2) {
        for (points[p1_ix .. p2_ix + 1]) |*point| {
            point.u = if (point.v <= v1)
                point.v + d1
            else if (point.v >= v2)
                point.v + d2
            else
                r1_u;
        }
    } else {
        const scale = metrics.fixedDiv(r2_u - r1_u, v2 - v1);
        for (points[p1_ix .. p2_ix + 1]) |*point| {
            point.u = if (point.v <= v1)
                point.v + d1
            else if (point.v >= v2)
                point.v + d2
            else
                r1_u + metrics.fixedMul(point.v - v1, scale);
        }
    }
}
