//! Topology analysis: segments, stems (links), serifs and blue edges.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/topo/{mod,segments,edges}.rs`.
//! A segment is a run of points aligned along one axis; edges are sets of
//! segments within a stem-width threshold. The algorithms preserve
//! FreeType's iteration order exactly because later stages depend on edge
//! order.

const std = @import("std");
const metrics = @import("metrics.zig");
const outline_mod = @import("outline.zig");
const fixed = @import("fixed.zig");

pub const Dimension = @import("types.zig").Dimension;
const Direction = outline_mod.Direction;
const Orientation = outline_mod.Orientation;
const Outline = outline_mod.Outline;
const Point = outline_mod.Point;

/// Source for an alignment zone.
pub const BlueProvenance = struct {
    /// Index of the blue in the associated metrics.
    index: u16 = 0,
    /// Was the blue an overshoot?
    is_shoot: bool = false,
};

/// Flags that define the properties of segments and edges.
pub const TopoFlags = struct {
    bits: u8 = 0,

    /// Regular segment or edge.
    pub const normal = TopoFlags{ .bits = 0 };
    /// Segment or edge has rounded geometry.
    pub const round = TopoFlags{ .bits = 1 };
    /// Segment or edge represents a serif.
    pub const serif = TopoFlags{ .bits = 2 };
    /// Segment or edge has been successfully processed.
    pub const done = TopoFlags{ .bits = 4 };
    /// Segment or edge aligns to a neutral blue zone.
    pub const neutral = TopoFlags{ .bits = 8 };

    pub fn contains(self: TopoFlags, other: TopoFlags) bool {
        return self.bits & other.bits == other.bits;
    }

    pub fn intersects(self: TopoFlags, other: TopoFlags) bool {
        return self.bits & other.bits != 0;
    }

    pub fn unionWith(self: TopoFlags, other: TopoFlags) TopoFlags {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn without(self: TopoFlags, other: TopoFlags) TopoFlags {
        return .{ .bits = self.bits & ~other.bits };
    }
};

/// Sequence of points with a single dominant direction.
pub const Segment = struct {
    /// Flags describing the properties of the segment.
    flags: TopoFlags = .normal,
    /// Dominant direction of the segment.
    dir: Direction = .none,
    /// Position of the segment.
    pos: i16 = 0,
    /// Deviation from segment position.
    delta: i16 = 0,
    /// Minimum coordinate of the segment.
    min_coord: i16 = 0,
    /// Maximum coordinate of the segment.
    max_coord: i16 = 0,
    /// Hinted segment height.
    height: i16 = 0,
    /// Used during stem matching.
    score: i32 = 0,
    /// Used during stem matching.
    len: i32 = 0,
    /// Index of best candidate for a stem link.
    link_ix: ?u16 = null,
    /// Index of best candidate for a serif link.
    serif_ix: ?u16 = null,
    /// Index of first point in the outline.
    first_ix: u16 = 0,
    /// Index of last point in the outline.
    last_ix: u16 = 0,
    /// Index of edge that is associated with the segment.
    edge_ix: ?u16 = null,
    /// Index of next segment in edge's segment list.
    edge_next_ix: ?u16 = null,

    pub fn first(self: Segment) usize {
        return self.first_ix;
    }

    pub fn last(self: Segment) usize {
        return self.last_ix;
    }

    pub fn edge(self: Segment, edges: []const Edge) ?Edge {
        const ix = self.edge_ix orelse return null;
        if (ix >= edges.len) return null;
        return edges[ix];
    }

    pub fn link(self: Segment, segments: []const Segment) ?Segment {
        const ix = self.link_ix orelse return null;
        if (ix >= segments.len) return null;
        return segments[ix];
    }

    pub fn nextInEdge(self: Segment, segments: []const Segment) ?Segment {
        const ix = self.edge_next_ix orelse return null;
        if (ix >= segments.len) return null;
        return segments[ix];
    }
};

/// Sequence of segments used for grid-fitting.
pub const Edge = struct {
    /// Original, unscaled position in font units.
    fpos: i16 = 0,
    /// Original, scaled position.
    opos: i32 = 0,
    /// Current position.
    pos: i32 = 0,
    /// Edge flags.
    flags: TopoFlags = .normal,
    /// Edge direction.
    dir: Direction = .none,
    /// Present if this is a blue edge.
    blue_edge: ?metrics.ScaledWidth = null,
    /// Retains which blue zone was selected and whether the overshoot
    /// position won.
    blue_provenance: ?BlueProvenance = null,
    /// Index of linked edge.
    link_ix: ?u16 = null,
    /// Index of primary edge for serif.
    serif_ix: ?u16 = null,
    /// Used to speed up edge interpolation.
    scale: i32 = 0,
    /// Index of first segment in edge.
    first_ix: u16 = 0,
    /// Index of last segment in edge.
    last_ix: u16 = 0,

    pub fn link(self: Edge, edges: []const Edge) ?Edge {
        const ix = self.link_ix orelse return null;
        if (ix >= edges.len) return null;
        return edges[ix];
    }

    pub fn serif(self: Edge, edges: []const Edge) ?Edge {
        const ix = self.serif_ix orelse return null;
        if (ix >= edges.len) return null;
        return edges[ix];
    }
};

/// Segments and edges for one dimension of an outline.
pub const Axis = struct {
    dim: Dimension = .horizontal,
    major_dir: Direction = .none,
    segments: std.ArrayListUnmanaged(Segment) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,

    pub fn deinit(self: *Axis, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
        self.edges.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *Axis, dim: Dimension, orientation: ?Orientation) void {
        self.dim = dim;
        self.major_dir = switch (dim) {
            .horizontal => if (orientation == Orientation.clockwise) .down else .up,
            .vertical => if (orientation == Orientation.clockwise) .right else .left,
        };
        self.segments.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
    }

    /// Inserts the given edge into the sorted edge list.
    pub fn insertEdge(self: *Axis, allocator: std.mem.Allocator, edge: Edge, top_to_bottom: bool) !void {
        try self.edges.append(allocator, edge);
        const edges = self.edges.items;
        if (edges.len == 1) return;
        var ix = edges.len - 1;
        while (ix > 0) {
            const prev_ix = ix - 1;
            const prev_fpos = edges[prev_ix].fpos;
            if ((top_to_bottom and prev_fpos > edge.fpos) or
                (!top_to_bottom and prev_fpos < edge.fpos))
            {
                break;
            }
            // Edges with the same position and minor direction should appear
            // before those with the major direction.
            if (prev_fpos == edge.fpos and edge.dir == self.major_dir) break;
            const prev_edge = edges[prev_ix];
            edges[ix] = prev_edge;
            ix -= 1;
        }
        edges[ix] = edge;
    }

    /// Links the given segment and edge.
    pub fn appendSegmentToEdge(self: *Axis, segment_ix: usize, edge_ix: usize) void {
        const edge = &self.edges.items[edge_ix];
        const first_ix = edge.first_ix;
        const last_ix = edge.last_ix;
        edge.last_ix = @intCast(segment_ix);
        self.segments.items[segment_ix].edge_next_ix = first_ix;
        self.segments.items[last_ix].edge_next_ix = @intCast(segment_ix);
    }
};

const max_score: i32 = 32000;
const min_score: i32 = -32000;

pub const ScriptGroup = @import("styles.zig").ScriptGroup;

/// Computes segments for the outline axis.
///
/// The script group is accepted for parity with upstream but never used (the
/// CJK round-segment pass is dead code there too).
pub fn computeSegments(
    allocator: std.mem.Allocator,
    outline: *Outline,
    axis: *Axis,
    script_group: ScriptGroup,
) !bool {
    _ = script_group;
    assignPointUvs(outline, axis.dim);
    if (!try buildSegments(allocator, outline, axis)) return false;
    adjustSegmentHeights(outline, axis);
    return true;
}

fn assignPointUvs(outline: *Outline, dim: Dimension) void {
    if (dim == .horizontal) {
        for (outline.points.items) |*point| {
            point.u = point.fx;
            point.v = point.fy;
        }
    } else {
        for (outline.points.items) |*point| {
            point.u = point.fy;
            point.v = point.fx;
        }
    }
}

fn buildSegments(allocator: std.mem.Allocator, outline: *Outline, axis: *Axis) !bool {
    const flat_threshold = @divTrunc(outline.units_per_em, 14);
    axis.segments.clearRetainingCapacity();
    const major_dir = axis.major_dir.normalize();
    var segment_dir = major_dir;
    const points = outline.points.items;
    for (outline.contours.items) |contour| {
        if (contour.last() >= points.len) continue;
        const is_single_point_contour = contour.last() == contour.first();
        var point_ix = contour.first();
        var last_ix = contour.prev(point_ix);
        var state = State{};
        var prev_state = state;
        var prev_segment_ix: ?usize = null;
        var segment_ix: usize = 0;
        // Check if we're starting on an edge and if so, find the start.
        if (points[point_ix].out_dir.isSameAxis(major_dir) and
            points[last_ix].out_dir.isSameAxis(major_dir))
        {
            last_ix = point_ix;
            while (true) {
                point_ix = contour.prev(point_ix);
                if (!points[point_ix].out_dir.isSameAxis(major_dir)) {
                    point_ix = contour.next(point_ix);
                    break;
                }
                if (point_ix == last_ix) break;
            }
        }
        last_ix = point_ix;
        var on_edge = false;
        var passed = false;
        while (true) {
            if (on_edge) {
                // Get min and max position
                const point = points[point_ix];
                state.min_pos = @min(state.min_pos, point.u);
                state.max_pos = @max(state.max_pos, point.u);
                // Get min and max coordinate and flags
                const v = point.v;
                if (v < state.min_coord) {
                    state.min_coord = v;
                    state.min_flags = point.flags;
                }
                if (v > state.max_coord) {
                    state.max_coord = v;
                    state.max_flags = point.flags;
                }
                // Get min and max coord of on-curve points
                if (point.isOnCurve()) {
                    state.min_on_coord = @min(state.min_on_coord, point.v);
                    state.max_on_coord = @max(state.max_on_coord, point.v);
                }
                if (point.out_dir != segment_dir or point_ix == last_ix) {
                    if (prev_segment_ix) |prev_ix| {
                        if (axis.segments.items[segment_ix].first_ix !=
                            axis.segments.items[prev_ix].last_ix)
                        {
                            prev_segment_ix = null;
                        }
                    }
                    if (prev_segment_ix) |prev_ix| {
                        // The points are the same, so merge the segments.
                        const prev_last = axis.segments.items[prev_ix].last_ix;
                        if (points[prev_last].in_dir == point.in_dir) {
                            // Identical directions; unify segments and
                            // update constraints.
                            state.min_pos = @min(prev_state.min_pos, state.min_pos);
                            state.max_pos = @max(prev_state.max_pos, state.max_pos);
                            if (prev_state.min_coord < state.min_coord) {
                                state.min_coord = prev_state.min_coord;
                                state.min_flags = prev_state.min_flags;
                            }
                            if (prev_state.max_coord > state.max_coord) {
                                state.max_coord = prev_state.max_coord;
                                state.max_flags = prev_state.max_flags;
                            }
                            state.min_on_coord = @min(prev_state.min_on_coord, state.min_on_coord);
                            state.max_on_coord = @max(prev_state.max_on_coord, state.max_on_coord);
                            axis.segments.items[prev_ix].last_ix = @intCast(point_ix);
                            state.applyToSegment(&axis.segments.items[prev_ix], flat_threshold);
                        } else {
                            // Different directions; use the properties of the
                            // longer segment.
                            if (@as(i32, prev_state.max_coord) - prev_state.min_coord >
                                @as(i32, state.max_coord) - state.min_coord)
                            {
                                prev_state.min_pos = @min(prev_state.min_pos, state.min_pos);
                                prev_state.max_pos = @max(prev_state.max_pos, state.max_pos);
                                axis.segments.items[prev_ix].last_ix = @intCast(point_ix);
                                axis.segments.items[prev_ix].pos =
                                    @intCast((prev_state.min_pos + prev_state.max_pos) >> 1);
                                axis.segments.items[prev_ix].delta =
                                    @intCast((prev_state.max_pos - prev_state.min_pos) >> 1);
                            } else {
                                state.min_pos = @min(state.min_pos, prev_state.min_pos);
                                state.max_pos = @max(state.max_pos, prev_state.max_pos);
                                var segment = axis.segments.items[segment_ix];
                                segment.last_ix = @intCast(point_ix);
                                state.applyToSegment(&segment, flat_threshold);
                                axis.segments.items[prev_ix] = segment;
                                prev_state = state;
                            }
                        }
                        _ = axis.segments.pop();
                    } else {
                        // Leaving an edge: finish the new segment.
                        const segment = &axis.segments.items[segment_ix];
                        segment.last_ix = @intCast(point_ix);
                        state.applyToSegment(segment, flat_threshold);
                        prev_segment_ix = segment_ix;
                        prev_state = state;
                    }
                    on_edge = false;
                }
            }
            if (point_ix == last_ix) {
                if (passed) break;
                passed = true;
            }
            const point = points[point_ix];
            if (!on_edge and (point.out_dir.isSameAxis(major_dir) or is_single_point_contour)) {
                if (axis.segments.items.len > 1000) {
                    axis.segments.clearRetainingCapacity();
                    return false;
                }
                segment_ix = axis.segments.items.len;
                segment_dir = point.out_dir;
                var segment = Segment{
                    .dir = segment_dir,
                    .first_ix = @intCast(point_ix),
                    .last_ix = @intCast(point_ix),
                    .score = max_score,
                };
                state.min_pos = point.u;
                state.max_pos = point.u;
                state.min_coord = point.v;
                state.max_coord = point.v;
                state.min_flags = point.flags;
                state.max_flags = point.flags;
                if (!point.isOnCurve()) {
                    state.min_on_coord = max_score;
                    state.max_on_coord = min_score;
                } else {
                    state.min_on_coord = point.v;
                    state.max_on_coord = point.v;
                }
                on_edge = true;
                if (is_single_point_contour) {
                    segment.pos = @intCast(state.min_pos);
                    if (!point.isOnCurve()) segment.flags.bits |= TopoFlags.round.bits;
                    segment.min_coord = @intCast(point.v);
                    segment.max_coord = @intCast(point.v);
                    segment.height = 0;
                    on_edge = false;
                }
                axis.segments.append(allocator, segment) catch return error.OutOfMemory;
            }
            point_ix = contour.next(point_ix);
        }
    }
    return true;
}

fn adjustSegmentHeights(outline: *Outline, axis: *Axis) void {
    const points = outline.points.items;
    for (axis.segments.items) |*segment| {
        const first = points[segment.first()];
        const last = points[segment.last()];
        const prev = points[first.prev()];
        const next = points[last.next()];
        if (first.v < last.v) {
            if (prev.v < first.v) {
                adjustHeight(segment, first.v, prev.v);
            }
            if (next.v > last.v) {
                adjustHeight(segment, next.v, last.v);
            }
        } else {
            if (prev.v > first.v) {
                adjustHeight(segment, prev.v, first.v);
            }
            if (next.v < last.v) {
                adjustHeight(segment, last.v, next.v);
            }
        }
    }
}

fn adjustHeight(segment: *Segment, v1: i32, v2: i32) void {
    segment.height = @intCast(@as(i32, segment.height) + ((v1 - v2) >> 1));
}

/// Capture current and previous state while computing segments.
const State = struct {
    min_pos: i32 = max_score,
    max_pos: i32 = min_score,
    min_coord: i32 = max_score,
    max_coord: i32 = min_score,
    min_flags: u8 = 0,
    max_flags: u8 = 0,
    min_on_coord: i32 = max_score,
    max_on_coord: i32 = min_score,

    fn applyToSegment(self: *const State, segment: *Segment, flat_threshold: i32) void {
        segment.pos = @intCast((self.min_pos + self.max_pos) >> 1);
        segment.delta = @intCast((self.max_pos - self.min_pos) >> 1);
        // A segment is round if either end point is a control and the length
        // of the on points in between fits within a heuristic limit.
        if ((self.min_flags & outline_mod.PointFlags.on_curve == 0 or
            self.max_flags & outline_mod.PointFlags.on_curve == 0) and
            (self.max_on_coord - self.min_on_coord) < flat_threshold)
        {
            segment.flags.bits |= TopoFlags.round.bits;
        }
        segment.min_coord = @intCast(self.min_coord);
        segment.max_coord = @intCast(self.max_coord);
        segment.height = @intCast(self.max_coord - self.min_coord);
    }
};

/// Links segments to form stems and serifs.
pub fn linkSegments(
    outline: *const Outline,
    axis: *Axis,
    scale: i32,
    script_group: ScriptGroup,
    max_width: ?i32,
) void {
    if (script_group == .default) {
        linkSegmentsDefault(outline, axis, max_width);
    } else {
        linkSegmentsCjk(outline, axis, scale);
    }
}

fn linkSegmentsDefault(outline: *const Outline, axis: *Axis, max_width_in: ?i32) void {
    const max_width = max_width_in orelse 0;
    // Heuristic value to set up a minimum for overlapping.
    const len_threshold = @max(fixed.derivedConstant(outline.units_per_em, 8), 1);
    // Heuristic value to weight lengths.
    const len_score = fixed.derivedConstant(outline.units_per_em, 6000);
    // Heuristic value to weight distances.
    const dist_score: i32 = 3000;
    const segments = axis.segments.items;
    for (0..segments.len) |ix1| {
        const seg1 = segments[ix1];
        if (seg1.dir != axis.major_dir) continue;
        const pos1 = seg1.pos;
        // Search for stems having opposite directions with seg1 to the left
        // of seg2.
        for (0..segments.len) |ix2| {
            const seg1_inner = segments[ix1];
            const seg2 = segments[ix2];
            const pos2 = seg2.pos;
            if (!seg1_inner.dir.isOpposite(seg2.dir) or pos2 <= pos1) continue;
            // Note: the min/max functions chosen here are intentional.
            const min = @max(seg1_inner.min_coord, seg2.min_coord);
            const max = @min(seg1_inner.max_coord, seg2.max_coord);
            const len: i32 = @as(i32, max) - min;
            if (len < len_threshold) continue;
            // Score: sum of the overlap and distance demerits.
            const dist: i32 = @as(i32, pos2) - pos1;
            var dist_demerit: i32 = undefined;
            if (max_width != 0) {
                // Distance demerits are based on multiples of max_width.
                const delta = @divTrunc(dist << 10, max_width) - (1 << 10);
                if (delta > 10_000) {
                    dist_demerit = max_score;
                } else if (delta > 0) {
                    dist_demerit = @divTrunc(delta * delta, dist_score);
                } else {
                    dist_demerit = 0;
                }
            } else {
                dist_demerit = dist;
            }
            const score = dist_demerit + @divTrunc(len_score, len);
            if (score < segments[ix1].score) {
                segments[ix1].score = score;
                segments[ix1].link_ix = @intCast(ix2);
            }
            if (score < segments[ix2].score) {
                segments[ix2].score = score;
                segments[ix2].link_ix = @intCast(ix1);
            }
        }
    }
    // Now compute "serif" segments.
    for (0..segments.len) |ix1| {
        const ix2 = segments[ix1].link_ix orelse continue;
        const seg2_link = segments[ix2].link_ix;
        if (seg2_link != @as(?u16, @intCast(ix1))) {
            segments[ix1].link_ix = null;
            segments[ix1].serif_ix = seg2_link;
        }
    }
}

fn linkSegmentsCjk(outline: *const Outline, axis: *Axis, scale: i32) void {
    const len_threshold = fixed.derivedConstant(outline.units_per_em, 8);
    const dist_threshold = fixed.div(64 * 3, scale);
    const segments = axis.segments.items;
    for (0..segments.len) |ix1| {
        const seg1 = segments[ix1];
        if (seg1.dir != axis.major_dir) continue;
        const pos1 = seg1.pos;
        for (0..segments.len) |ix2| {
            const seg1_inner = segments[ix1];
            const seg2 = segments[ix2];
            if (ix1 == ix2 or !seg1_inner.dir.isOpposite(seg2.dir)) continue;
            const pos2 = seg2.pos;
            const dist: i32 = @as(i32, pos2) - pos1;
            if (dist < 0) continue;
            const min = @max(seg1_inner.min_coord, seg2.min_coord);
            const max = @min(seg1_inner.max_coord, seg2.max_coord);
            const len: i32 = @as(i32, max) - min;
            if (len < len_threshold) continue;
            const checkSeg = struct {
                fn call(dist_in: i32, len_in: i32, seg: Segment) bool {
                    return (dist_in * 8 < seg.score * 9) and
                        (dist_in * 8 < seg.score * 7 or seg.len < len_in);
                }
            }.call;
            if (checkSeg(dist, len, seg1_inner)) {
                segments[ix1].score = dist;
                segments[ix1].len = len;
                segments[ix1].link_ix = @intCast(ix2);
            }
            if (checkSeg(dist, len, seg2)) {
                segments[ix2].score = dist;
                segments[ix2].len = len;
                segments[ix2].link_ix = @intCast(ix1);
            }
        }
    }
    // Now compute "serif" segments.
    for (0..segments.len) |ix1| {
        const seg1 = segments[ix1];
        if (seg1.score >= dist_threshold) continue;
        const link1 = seg1.link(segments) orelse continue;
        const link1_ix: usize = seg1.link_ix.?;
        if (link1.link_ix != @as(?u16, @intCast(ix1)) or link1.pos <= seg1.pos) continue;
        for (0..segments.len) |ix2| {
            const seg2 = segments[ix2];
            if (seg2.pos > seg1.pos or ix1 == ix2) continue;
            const link2 = seg2.link(segments) orelse continue;
            if (link2.link_ix != @as(?u16, @intCast(ix2)) or link2.pos < link1.pos) continue;
            if (seg1.pos == seg2.pos and link1.pos == link2.pos) continue;
            if (seg2.score <= seg1.score or seg1.score * 4 <= seg2.score) continue;
            if (seg1.len >= seg2.len * 3) {
                const link2_ix: usize = seg2.link_ix.?;
                for (segments) |*seg| {
                    const link_ix = seg.link_ix;
                    if (link_ix == @as(?u16, @intCast(ix2))) {
                        seg.link_ix = null;
                        seg.serif_ix = @intCast(link1_ix);
                    } else if (link_ix == @as(?u16, @intCast(link2_ix))) {
                        seg.link_ix = null;
                        seg.serif_ix = @intCast(ix1);
                    }
                }
            } else {
                segments[ix1].link_ix = null;
                segments[link1_ix].link_ix = null;
                break;
            }
        }
    }
    for (0..segments.len) |ix1| {
        const seg1 = segments[ix1];
        const seg2 = seg1.link(segments) orelse continue;
        if (seg2.link_ix != @as(?u16, @intCast(ix1))) {
            segments[ix1].link_ix = null;
            if (seg2.score < dist_threshold or seg1.score < seg2.score * 4) {
                segments[ix1].serif_ix = seg2.link_ix;
            }
        }
    }
}

/// Links segments to edges, using feature analysis for selection.
pub fn computeEdges(
    allocator: std.mem.Allocator,
    axis: *Axis,
    metrics_axis: *const metrics.ScaledAxisMetrics,
    top_to_bottom_hinting_in: bool,
    y_scale: i32,
    script_group: ScriptGroup,
) !void {
    axis.edges.clearRetainingCapacity();
    const scale = metrics_axis.scale;
    const top_to_bottom_hinting = if (axis.dim == .horizontal or script_group != .default)
        false
    else
        top_to_bottom_hinting_in;
    // Ignore horizontal segments less than 1 pixel in length.
    const segment_length_threshold: i32 = if (axis.dim == .horizontal)
        fixed.div(64, y_scale)
    else
        0;
    // Also ignore segments with a width delta larger than 0.5 pixels.
    const segment_width_threshold = fixed.div(32, scale);
    // Ensure that edge distance threshold is less than or equal to
    // 0.25 pixels.
    const initial_threshold = metrics_axis.width_metrics.edge_distance_threshold;
    const edge_distance_threshold_max: i32 = 64 / 4;
    const edge_distance_threshold: i32 = if (script_group == .default)
        fixed.div(@min(fixed.mul(initial_threshold, scale), edge_distance_threshold_max), scale)
    else blk: {
        // CJK uses a slightly different computation here.
        const threshold = fixed.mul(initial_threshold, scale);
        break :blk if (threshold > edge_distance_threshold_max)
            fixed.div(edge_distance_threshold_max, scale)
        else
            initial_threshold;
    };
    // Build the sorted table of edges by looping over all segments to find a
    // matching edge, adding a new one if not found.
    for (0..axis.segments.items.len) |segment_ix| {
        const segment = axis.segments.items[segment_ix];
        if (script_group == .default) {
            // Ignore segments that are too short, too wide or direction-less.
            if (@as(i32, segment.height) < segment_length_threshold or
                @as(i32, segment.delta) > segment_width_threshold or
                segment.dir == .none)
            {
                continue;
            }
            // Ignore serif edges that are smaller than 1.5 pixels.
            if (segment.serif_ix != null and
                (2 * @as(i32, segment.height)) < (3 * segment_length_threshold))
            {
                continue;
            }
        }
        // Look for a corresponding edge for this segment.
        var best_dist: i32 = std.math.maxInt(i32);
        var best_edge_ix: ?usize = null;
        for (0..axis.edges.items.len) |edge_ix| {
            const edge = axis.edges.items[edge_ix];
            const dist = @as(i32, @intCast(@abs(@as(i32, segment.pos) - edge.fpos)));
            if (dist < edge_distance_threshold and edge.dir == segment.dir and dist < best_dist) {
                if (script_group == .default) {
                    best_edge_ix = edge_ix;
                    break;
                }
                // For CJK, add additional checks.
                if (segment.link(axis.segments.items)) |link| {
                    // Check whether all linked segments of the candidate
                    // edge can make a single edge.
                    const first_ix: usize = edge.first_ix;
                    var seg1 = axis.segments.items[first_ix];
                    var dist2: i32 = 0;
                    while (true) {
                        if (seg1.link(axis.segments.items)) |link1| {
                            dist2 = @intCast(@abs(@as(i32, link.pos) - link1.pos));
                            if (dist2 >= edge_distance_threshold) break;
                        }
                        if (seg1.edge_next_ix == @as(?u16, @intCast(first_ix))) break;
                        if (seg1.nextInEdge(axis.segments.items)) |next| {
                            seg1 = next;
                        } else break;
                    }
                    if (dist2 >= edge_distance_threshold) continue;
                }
                best_dist = dist;
                best_edge_ix = edge_ix;
            }
        }
        if (best_edge_ix) |edge_ix| {
            axis.appendSegmentToEdge(segment_ix, edge_ix);
        } else {
            // We couldn't find an edge, so add a new one for this segment.
            const opos = fixed.mul(segment.pos, scale);
            const edge = Edge{
                .fpos = segment.pos,
                .opos = opos,
                .pos = opos,
                .dir = segment.dir,
                .first_ix = @intCast(segment_ix),
                .last_ix = @intCast(segment_ix),
            };
            try axis.insertEdge(allocator, edge, top_to_bottom_hinting);
            axis.segments.items[segment_ix].edge_next_ix = @intCast(segment_ix);
        }
    }
    if (script_group == .default) {
        // Loop again to find single point segments without a direction and
        // associate them with an existing edge if possible.
        for (0..axis.segments.items.len) |segment_ix| {
            const segment = axis.segments.items[segment_ix];
            if (segment.dir != .none) continue;
            var found: ?usize = null;
            for (axis.edges.items, 0..) |edge, ix| {
                if (@as(i32, @intCast(@abs(@as(i32, segment.pos) - edge.fpos))) <
                    edge_distance_threshold)
                {
                    found = ix;
                    break;
                }
            }
            if (found) |edge_ix| axis.appendSegmentToEdge(segment_ix, edge_ix);
        }
    }
    linkSegmentsToEdges(axis);
    computeEdgeProperties(axis);
}

/// Edges get reordered as they're built so assign edge indices to segments
/// in a second pass.
fn linkSegmentsToEdges(axis: *Axis) void {
    for (0..axis.edges.items.len) |edge_ix| {
        const edge = axis.edges.items[edge_ix];
        var ix: usize = edge.first_ix;
        const last_ix: usize = edge.last_ix;
        while (true) {
            axis.segments.items[ix].edge_ix = @intCast(edge_ix);
            if (ix == last_ix) break;
            ix = if (axis.segments.items[ix].edge_next_ix) |next| next else last_ix;
        }
    }
}

/// Computes the edge properties based on the segments that make up the edge.
fn computeEdgeProperties(axis: *Axis) void {
    for (0..axis.edges.items.len) |edge_ix| {
        var roundness: i32 = 0;
        var straightness: i32 = 0;
        const edge = axis.edges.items[edge_ix];
        var segment_ix: usize = edge.first_ix;
        const last_segment_ix: usize = edge.last_ix;
        while (true) {
            // This loop can modify the current edge; reload it.
            const edge_now = axis.edges.items[edge_ix];
            const segment = axis.segments.items[segment_ix];
            const next_segment_ix = segment.edge_next_ix;
            // Check roundness.
            if (segment.flags.contains(TopoFlags.round)) {
                roundness += 1;
            } else {
                straightness += 1;
            }
            // Check for serifs.
            var is_serif = false;
            if (segment.serif_ix) |serif_ix| {
                if (serif_ix < axis.segments.items.len) {
                    const serif = axis.segments.items[serif_ix];
                    is_serif = serif.edge_ix != null and
                        serif.edge_ix != @as(?u16, @intCast(edge_ix));
                }
            }
            // Check for links.
            if (is_serif or
                (segment.link_ix != null and
                    segment.link_ix.? < axis.segments.items.len and
                    axis.segments.items[segment.link_ix.?].edge_ix != null))
            {
                const edge2_ix = if (is_serif) edge_now.serif_ix else edge_now.link_ix;
                const segment2_ix = if (is_serif) segment.serif_ix else segment.link_ix;
                const chosen: ?u16 = if (edge2_ix != null and segment2_ix != null) blk: {
                    const edge2 = axis.edges.items[edge2_ix.?];
                    const edge_delta = @as(i32, @intCast(@abs(@as(i32, edge_now.fpos) - edge2.fpos)));
                    const segment2 = axis.segments.items[segment2_ix.?];
                    const segment_delta = @abs(@as(i32, segment.pos) - segment2.pos);
                    break :blk if (segment_delta < edge_delta)
                        segment2.edge_ix
                    else
                        edge2_ix;
                } else if (segment2_ix) |s2| axis.segments.items[s2].edge_ix else edge2_ix;
                if (chosen) |chosen_ix| {
                    if (is_serif) {
                        axis.edges.items[edge_ix].serif_ix = chosen_ix;
                        axis.edges.items[chosen_ix].flags.bits |= TopoFlags.serif.bits;
                    } else {
                        axis.edges.items[edge_ix].link_ix = chosen_ix;
                    }
                }
            }
            if (segment_ix == last_segment_ix) break;
            segment_ix = if (next_segment_ix) |next| next else last_segment_ix;
        }
        const edge_final = &axis.edges.items[edge_ix];
        edge_final.flags = .normal;
        if (roundness > 0 and roundness >= straightness) {
            edge_final.flags.bits |= TopoFlags.round.bits;
        }
        // Drop serifs for linked edges.
        if (edge_final.serif_ix != null and edge_final.link_ix != null) {
            edge_final.serif_ix = null;
        }
    }
}

/// Computes all edges which lie within blue zones.
pub fn computeBlueEdges(
    axis: *Axis,
    scale: *const metrics.Scale,
    unscaled_blues: []const metrics.UnscaledBlue,
    blues: []const metrics.ScaledBlue,
    script_group: ScriptGroup,
) void {
    // For the default script group, don't compute blues in the horizontal
    // direction.
    if (axis.dim != .vertical and script_group == .default) return;
    const axis_scale = if (axis.dim == .horizontal) scale.x_scale else scale.y_scale;
    // Initial threshold
    const initial_best_dist = @min(fixed.mul(@divTrunc(scale.units_per_em, 40), axis_scale), 64 / 2);
    for (axis.edges.items) |*edge| {
        var best_blue: ?metrics.ScaledWidth = null;
        var best_is_neutral = false;
        var best_blue_idx: ?u16 = null;
        var best_blue_is_shoot = false;
        var best_dist = initial_best_dist;
        for (unscaled_blues, blues, 0..) |*unscaled_blue, *blue, blue_ix| {
            // Ignore inactive blue zones.
            if (!blue.is_active) continue;
            const is_top = blue.zones.isTopLike();
            const is_neutral = blue.zones.isNeutral();
            const is_major_dir = edge.dir == axis.major_dir;
            // Both directions are handled for neutral blues.
            if (!(is_top != is_major_dir) and !is_neutral) continue;
            // Compare to reference position.
            var ref_pos: i32 = undefined;
            var matching_blue: metrics.ScaledWidth = undefined;
            if (script_group == .default) {
                ref_pos = unscaled_blue.position;
                matching_blue = blue.position;
            } else {
                // For CJK, take the blue with the smallest delta from the
                // edge.
                if (@abs(@as(i32, edge.fpos) - unscaled_blue.position) >
                    @abs(@as(i32, edge.fpos) - unscaled_blue.overshoot))
                {
                    ref_pos = unscaled_blue.overshoot;
                    matching_blue = blue.overshoot;
                } else {
                    ref_pos = unscaled_blue.position;
                    matching_blue = blue.position;
                }
            }
            const dist = fixed.mul(@intCast(@abs(@as(i32, edge.fpos) - ref_pos)), axis_scale);
            if (dist < best_dist) {
                best_dist = dist;
                best_blue = matching_blue;
                best_is_neutral = is_neutral;
                best_blue_idx = @intCast(blue_ix);
                best_blue_is_shoot = false;
            }
            if (script_group == .default) {
                // Now compare to the overshoot position.
                if (edge.flags.contains(TopoFlags.round) and dist != 0 and !is_neutral) {
                    const is_under_ref = @as(i32, edge.fpos) < unscaled_blue.position;
                    if (is_top != is_under_ref) {
                        const shoot_dist = fixed.mul(
                            @intCast(@abs(@as(i32, edge.fpos) - unscaled_blue.overshoot)),
                            axis_scale,
                        );
                        if (shoot_dist < best_dist) {
                            best_dist = shoot_dist;
                            best_blue = blue.overshoot;
                            best_is_neutral = is_neutral;
                            best_blue_idx = @intCast(blue_ix);
                            best_blue_is_shoot = true;
                        }
                    }
                }
            }
        }
        if (best_blue) |blue_edge| {
            edge.blue_edge = blue_edge;
            edge.blue_provenance = .{
                .index = best_blue_idx orelse 0,
                .is_shoot = best_blue_is_shoot,
            };
            if (best_is_neutral) edge.flags.bits |= TopoFlags.neutral.bits;
        }
    }
}
