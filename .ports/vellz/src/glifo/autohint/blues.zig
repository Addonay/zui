//! Blue zone (alignment zone) computation.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/metrics/blues.rs`. Blue values
//! are derived from the script's blue character sets by scanning raw
//! unscaled outlines for extreme points and classifying the segment as flat
//! or round.

const std = @import("std");
const glyf = @import("../glyf.zig");
const metrics = @import("metrics.zig");
const shaper_mod = @import("shaper.zig");
const styles = @import("styles.zig");

const UnscaledBlue = metrics.UnscaledBlue;
const UnscaledBlues = metrics.UnscaledBlues;
const BlueZones = metrics.BlueZones;
const max_blues = metrics.max_blues;
/// Longest blue string in the generated tables.
const blue_string_max_len = 64;

/// Sink buffer of raw unscaled points used for blue extraction.
const BlueOutline = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayListUnmanaged(glyf.UnscaledSinkPoint) = .empty,

    fn deinit(self: *BlueOutline) void {
        self.points.deinit(self.allocator);
        self.points = .empty;
    }

    fn clear(self: *BlueOutline) void {
        self.points.clearRetainingCapacity();
    }

    pub fn tryReserve(self: *BlueOutline, additional: usize) glyf.DrawError!void {
        self.points.ensureUnusedCapacity(self.allocator, additional) catch {
            return error.OutOfMemory;
        };
    }

    pub fn push(self: *BlueOutline, point: glyf.UnscaledSinkPoint) glyf.DrawError!void {
        self.points.append(self.allocator, point) catch return error.OutOfMemory;
    }

    fn asSlice(self: *const BlueOutline) []const glyf.UnscaledSinkPoint {
        return self.points.items;
    }

    /// Returns the range of contour points and the index of the point within
    /// that contour for the last point where `f` returns true.
    fn findLastContour(
        self: *const BlueOutline,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), *const glyf.UnscaledSinkPoint) bool,
    ) ?struct { first: usize, last: usize, point: usize } {
        const points = self.points.items;
        if (points.len == 0) return null;
        var best_first: usize = 0;
        var best_last: usize = 0;
        var best_point: usize = 0;
        var cur_first: usize = 0;
        var cur_last: usize = 0;
        var found_best_in_cur_contour = false;
        for (points, 0..) |*point, point_ix| {
            if (point.is_contour_start) {
                if (found_best_in_cur_contour) {
                    best_first = cur_first;
                    best_last = cur_last;
                }
                cur_first = point_ix;
                cur_last = point_ix;
                found_best_in_cur_contour = false;
                if (point_ix + 1 < points.len and points[point_ix + 1].is_contour_start) continue;
                if (point_ix + 1 >= points.len) continue;
            }
            cur_last += 1;
            if (f(ctx, point)) {
                best_point = point_ix - cur_first;
                found_best_in_cur_contour = true;
            }
        }
        if (found_best_in_cur_contour) {
            best_first = cur_first;
            best_last = cur_last;
        }
        if (best_first < best_last) {
            return .{ .first = best_first, .last = best_last, .point = best_point };
        }
        return null;
    }
};

/// Computes unscaled blues values for each axis.
pub fn computeUnscaledBlues(
    allocator: std.mem.Allocator,
    shaper: *const shaper_mod.Shaper,
    outlines: *const glyf.Outlines,
    style: *const styles.StyleClass,
) glyf.DrawError![2]UnscaledBlues {
    switch (style.script.group) {
        .default => {
            // Default group doesn't have horizontal blues.
            return .{ .{}, try computeDefaultBlues(allocator, shaper, outlines, style) };
        },
        .cjk => return computeCjkBlues(allocator, shaper, outlines, style),
        // Indic group doesn't use blue values (yet).
        .indic => return .{ .{}, .{} },
        _ => return .{ .{}, .{} },
    }
}

fn computeDefaultBlues(
    allocator: std.mem.Allocator,
    shaper: *const shaper_mod.Shaper,
    outlines: *const glyf.Outlines,
    style: *const styles.StyleClass,
) glyf.DrawError!UnscaledBlues {
    var blues = UnscaledBlues{};
    var outline_buf = BlueOutline{ .allocator = allocator };
    defer outline_buf.deinit();
    var flats: [blue_string_max_len]i32 = undefined;
    var rounds: [blue_string_max_len]i32 = undefined;
    const units_per_em: i32 = outlines.unitsPerEm();
    const flat_threshold = @divTrunc(units_per_em, 14);
    var cluster_shaper = shaper.clusterShaper(style);
    var shaped_cluster = shaper_mod.ShapedCluster.empty;
    defer shaped_cluster.deinit(allocator);
    // Walk over each of the blue character sets for this script.
    for (style.script.blues) |blue_pair| {
        const blue_zones = blue_pair.zones;
        var acc = BlueAcc{ .ascender = std.math.minInt(i32), .descender = std.math.maxInt(i32) };
        var n_flats: usize = 0;
        var n_rounds: usize = 0;
        var clusters = std.mem.splitScalar(u8, blue_pair.chars, ' ');
        while (clusters.next()) |cluster| {
            var best_y_extremum: i32 = if (blue_zones.isTop()) std.math.minInt(i32) else std.math.maxInt(i32);
            var best_is_round = false;
            try cluster_shaper.shape(allocator, cluster, &shaped_cluster);
            for (shaped_cluster.items) |shaped| {
                if (shaped.id == 0) continue;
                const glyph = outlines.getGlyph(shaped.id) catch continue;
                if (glyph == null) continue;
                const y_offset = shaped.y_offset;
                outline_buf.clear();
                if (outlines.drawUnscaled(allocator, shaped.id, &outline_buf)) |_| {} else |_| {
                    continue;
                }
                const points = outline_buf.asSlice();
                // Reject glyphs that can't produce any rendering.
                if (points.len <= 2) continue;
                // Find the extreme point depending on whether this is a top
                // or bottom blue.
                const is_top_like = blue_zones.isTopLike();
                var best_ctx = BestYCtx{
                    .acc = &acc,
                    .best_y = null,
                    .y_offset = y_offset,
                    .top = is_top_like,
                };
                const best = if (is_top_like)
                    outline_buf.findLastContour(&best_ctx, bestYTop)
                else
                    outline_buf.findLastContour(&best_ctx, bestYBottom);
                const best_contour_and_point = best orelse continue;
                const best_points = points[best_contour_and_point.first..best_contour_and_point.last];
                const best_point_ix = best_contour_and_point.point;
                // best_y is guaranteed to be set when a contour matched.
                var best_y: i32 = @intCast(best_ctx.best_y orelse continue);
                const best_x: i32 = best_points[best_point_ix].x;
                // Determine whether the point belongs to a straight or round
                // segment by examining the previous and next points.
                var on_point_first: ?usize = if (isOnCurve(best_points[best_point_ix]))
                    best_point_ix
                else
                    null;
                var on_point_last: ?usize = on_point_first;
                var segment_first = best_point_ix;
                var segment_last = best_point_ix;
                // Look for the previous and next points on the contour that
                // are not on the same Y coordinate, then threshold
                // "closeness".
                var back = cycleBackward(best_points.len, best_point_ix);
                while (back.next()) |entry| {
                    const prev = best_points[entry.ix];
                    const dist = @as(i32, @intCast(@abs(@as(i32, prev.y) - best_y)));
                    // Allow a small distance or angle (20 == ~2.9 degrees).
                    if (dist > 5 and @as(i32, @intCast(@abs(@as(i32, prev.x) - best_x))) <= (20 * dist)) break;
                    segment_first = entry.ix;
                    if (isOnCurve(prev)) {
                        on_point_first = entry.ix;
                        if (on_point_last == null) on_point_last = entry.ix;
                    }
                }
                var next_ix: usize = 0;
                var forward = cycleForward(best_points.len, best_point_ix);
                while (forward.next()) |entry| {
                    const next = best_points[entry.ix];
                    // Save next_ix which is used in the "long" blue
                    // computation later.
                    next_ix = entry.ix;
                    const dist = @as(i32, @intCast(@abs(@as(i32, next.y) - best_y)));
                    if (dist > 5 and @as(i32, @intCast(@abs(@as(i32, next.x) - best_x))) <= (20 * dist)) break;
                    segment_last = entry.ix;
                    if (isOnCurve(next)) {
                        on_point_last = entry.ix;
                        if (on_point_first == null) on_point_first = entry.ix;
                    }
                }
                if (blue_zones.isLong()) {
                    // FreeType's long-blue handling for Hebrew-style serifs.
                    const length_threshold = @divTrunc(units_per_em, 25);
                    const dist = @as(i32, @intCast(@abs(@as(i32, best_points[segment_last].x) -
                        best_points[segment_first].x)));
                    if (dist < length_threshold and
                        satisfiesMinLongSegmentLen(segment_first, segment_last, best_points.len - 1))
                    {
                        // Heuristic threshold value.
                        const height_threshold = @divTrunc(units_per_em, 4);
                        // Find the previous point with a different x value.
                        var prev_ix = best_point_ix;
                        var back2 = cycleBackward(best_points.len, best_point_ix);
                        while (back2.next()) |entry| {
                            if (best_points[entry.ix].x != best_x) {
                                prev_ix = entry.ix;
                                break;
                            }
                        }
                        // Skip for degenerate case.
                        if (prev_ix == best_point_ix) continue;
                        const is_ltr = best_points[prev_ix].x < best_x;
                        var first = segment_last;
                        var last = first;
                        var p_first: ?usize = null;
                        var p_last: ?usize = null;
                        var hit = false;
                        while (true) {
                            if (!hit) {
                                // No hit; adjust first point.
                                first = last;
                                // Also adjust first and last on-curve point.
                                if (isOnCurve(best_points[first])) {
                                    p_first = first;
                                    p_last = first;
                                } else {
                                    p_first = null;
                                    p_last = null;
                                }
                                hit = true;
                            }
                            if (last < best_points.len - 1) {
                                last += 1;
                            } else {
                                last = 0;
                            }
                            if (@as(i32, @intCast(@abs(best_y - @as(i32, best_points[first].y)))) > height_threshold) {
                                // Vertical distance too large.
                                hit = false;
                                continue;
                            }
                            const dy: i32 = @intCast(@abs(@as(i32, best_points[last].y) -
                                best_points[first].y));
                            if (dy > 5 and
                                @as(i32, @intCast(@abs(@as(i32, best_points[last].x) - best_points[first].x))) <= 20 * dy)
                            {
                                hit = false;
                                if (last == segment_first) break;
                                continue;
                            }
                            if (isOnCurve(best_points[last])) {
                                p_last = last;
                                if (p_first == null) p_first = last;
                            }
                            const first_x: i32 = best_points[first].x;
                            const last_x: i32 = best_points[last].x;
                            const is_cur_ltr = first_x < last_x;
                            const dx: i32 = @intCast(@abs(last_x - first_x));
                            if (is_cur_ltr == is_ltr and dx >= length_threshold) {
                                while (true) {
                                    if (last < best_points.len - 1) {
                                        last += 1;
                                    } else {
                                        last = 0;
                                    }
                                    const dy2: i32 = @intCast(@abs(@as(i32, best_points[last].y) -
                                        best_points[first].y));
                                    if (dy2 > 5 and
                                        @as(i32, @intCast(@abs(@as(i32, best_points[next_ix].x) -
                                            best_points[first].x))) <= 20 * dy)
                                    {
                                        if (last > 0) {
                                            last -= 1;
                                        } else {
                                            last = best_points.len - 1;
                                        }
                                        break;
                                    }
                                    p_last = last;
                                    if (isOnCurve(best_points[last])) {
                                        p_last = last;
                                        if (p_first == null) p_first = last;
                                    }
                                    if (last == segment_first) break;
                                }
                                best_y = best_points[first].y;
                                segment_first = first;
                                segment_last = last;
                                on_point_first = p_first;
                                on_point_last = p_last;
                                break;
                            }
                            if (last == segment_first) break;
                        }
                    }
                }
                best_y += y_offset;
                // Is the segment round?
                // 1. Horizontal distance between first and last on-curve
                //    point larger than the flat threshold: flat.
                // 2. Either first or last point of the segment is off-curve:
                //    round.
                const is_round = blk: {
                    if (on_point_first != null and on_point_last != null) {
                        const first = on_point_first.?;
                        const last = on_point_last.?;
                        if (@as(i32, @intCast(@abs(@as(i32, best_points[last].x) -
                            best_points[first].x))) > flat_threshold)
                        {
                            break :blk false;
                        }
                    }
                    break :blk !isOnCurve(best_points[segment_first]) or
                        !isOnCurve(best_points[segment_last]);
                };
                if (is_round and blue_zones.isNeutral()) {
                    // Ignore round segments for the neutral zone.
                    continue;
                }
                if (blue_zones.isTop()) {
                    if (best_y > best_y_extremum) {
                        best_y_extremum = best_y;
                        best_is_round = is_round;
                    }
                } else if (best_y < best_y_extremum) {
                    best_y_extremum = best_y;
                    best_is_round = is_round;
                }
            }
            if (best_y_extremum != std.math.minInt(i32) and
                best_y_extremum != std.math.maxInt(i32))
            {
                if (best_is_round) {
                    if (n_rounds < rounds.len) {
                        rounds[n_rounds] = best_y_extremum;
                        n_rounds += 1;
                    }
                } else {
                    if (n_flats < flats.len) {
                        flats[n_flats] = best_y_extremum;
                        n_flats += 1;
                    }
                }
            }
        }
        if (n_flats == 0 and n_rounds == 0) continue;
        std.mem.sort(i32, rounds[0..n_rounds], {}, std.sort.asc(i32));
        std.mem.sort(i32, flats[0..n_flats], {}, std.sort.asc(i32));
        var blue_ref: i32 = undefined;
        var blue_shoot: i32 = undefined;
        if (n_flats == 0) {
            const value = rounds[n_rounds / 2];
            blue_ref = value;
            blue_shoot = value;
        } else if (n_rounds == 0) {
            const value = flats[n_flats / 2];
            blue_ref = value;
            blue_shoot = value;
        } else {
            blue_ref = flats[n_flats / 2];
            blue_shoot = rounds[n_rounds / 2];
        }
        if (blue_shoot != blue_ref) {
            const over_ref = blue_shoot > blue_ref;
            if (blue_zones.isTopLike() != over_ref) {
                const value = @divTrunc(blue_shoot + blue_ref, 2);
                blue_ref = value;
                blue_shoot = value;
            }
        }
        var blue_value = UnscaledBlue{
            .position = blue_ref,
            .overshoot = blue_shoot,
            .ascender = acc.ascender,
            .descender = acc.descender,
            .zones = blue_zones.retainTopLikeOrNeutral(),
        };
        if (blue_zones.isXHeight()) {
            blue_value.zones = blue_value.zones.unionWith(BlueZones.adjustment);
        }
        _ = blues.push(blue_value);
    }
    // Sort bottoms.
    var sorted_indices: [max_blues]usize = undefined;
    for (&sorted_indices, 0..) |*value, ix| value.* = ix;
    const blue_values = blues.asMutSlice();
    const len = blue_values.len;
    if (len == 0) return blues;
    // Sort from bottom to top.
    var outer: usize = 1;
    while (outer < len) : (outer += 1) {
        var j = outer;
        while (j >= 1) : (j -= 1) {
            const first = blue_values[sorted_indices[j - 1]];
            const second = blue_values[sorted_indices[j]];
            const a = if (first.zones.isTopLike()) first.position else first.overshoot;
            const b = if (second.zones.isTopLike()) second.position else second.overshoot;
            if (b >= a) break;
            std.mem.swap(usize, &sorted_indices[j], &sorted_indices[j - 1]);
        }
    }
    // And adjust tops.
    for (0..len - 1) |i| {
        const index1 = sorted_indices[i];
        const index2 = sorted_indices[i + 1];
        const first = blue_values[index1];
        const second = blue_values[index2];
        const a = if (first.zones.isTopLike()) first.overshoot else first.position;
        const b = if (second.zones.isTopLike()) second.overshoot else second.position;
        if (a > b) {
            if (first.zones.isTopLike()) {
                blue_values[index1].overshoot = b;
            } else {
                blue_values[index1].position = b;
            }
        }
    }
    return blues;
}

fn computeCjkBlues(
    allocator: std.mem.Allocator,
    shaper: *const shaper_mod.Shaper,
    outlines: *const glyf.Outlines,
    style: *const styles.StyleClass,
) glyf.DrawError![2]UnscaledBlues {
    var blues = [2]UnscaledBlues{ .{}, .{} };
    var outline_buf = BlueOutline{ .allocator = allocator };
    defer outline_buf.deinit();
    var flats: [blue_string_max_len]i32 = undefined;
    var fills: [blue_string_max_len]i32 = undefined;
    var cluster_shaper = shaper.clusterShaper(style);
    var shaped_cluster = shaper_mod.ShapedCluster.empty;
    defer shaped_cluster.deinit(allocator);
    for (style.script.blues) |blue_pair| {
        const blue_zones = blue_pair.zones;
        const is_horizontal = blue_zones.isHorizontal();
        // Horizontal blue zones are disabled in FreeType.
        if (is_horizontal) continue;
        const is_right = blue_zones.isRight();
        const is_top = blue_zones.isTop();
        const blues_axis = &blues[if (!is_horizontal) @as(usize, 1) else 0];
        if (blues_axis.len >= max_blues) continue;
        var n_flats: usize = 0;
        var n_fills: usize = 0;
        var is_fill = true;
        var clusters = std.mem.splitScalar(u8, blue_pair.chars, ' ');
        while (clusters.next()) |cluster| {
            // The '|' character switches to flat values.
            if (std.mem.eql(u8, cluster, "|")) {
                is_fill = false;
                continue;
            }
            try cluster_shaper.shape(allocator, cluster, &shaped_cluster);
            for (shaped_cluster.items) |shaped| {
                if (shaped.id == 0) continue;
                const glyph = outlines.getGlyph(shaped.id) catch continue;
                if (glyph == null) continue;
                outline_buf.clear();
                if (outlines.drawUnscaled(allocator, shaped.id, &outline_buf)) |_| {} else |_| {
                    continue;
                }
                const points = outline_buf.asSlice();
                if (points.len <= 2) continue;
                // Find an extrema.
                var best_pos: i16 = points[0].y;
                for (points) |point| {
                    const pos = if (is_horizontal) point.x else point.y;
                    if ((is_horizontal and is_right) or (!is_horizontal and is_top)) {
                        if (pos > best_pos) best_pos = pos;
                    } else {
                        if (pos < best_pos) best_pos = pos;
                    }
                }
                if (is_fill) {
                    if (n_fills < fills.len) {
                        fills[n_fills] = best_pos;
                        n_fills += 1;
                    }
                } else {
                    if (n_flats < flats.len) {
                        flats[n_flats] = best_pos;
                        n_flats += 1;
                    }
                }
            }
        }
        if (n_flats == 0 and n_fills == 0) continue;
        std.mem.sort(i32, fills[0..n_fills], {}, std.sort.asc(i32));
        std.mem.sort(i32, flats[0..n_flats], {}, std.sort.asc(i32));
        var blue_ref: i32 = undefined;
        var blue_shoot: i32 = undefined;
        if (n_flats == 0) {
            const value: i32 = fills[n_fills / 2];
            blue_ref = value;
            blue_shoot = value;
        } else if (n_fills == 0) {
            const value: i32 = flats[n_flats / 2];
            blue_ref = value;
            blue_shoot = value;
        } else {
            blue_ref = fills[n_fills / 2];
            blue_shoot = flats[n_flats / 2];
        }
        // Make sure blue_ref >= blue_shoot for top/right or vice versa for
        // bottom left.
        if (blue_shoot != blue_ref) {
            const under_ref = blue_shoot < blue_ref;
            if (blue_zones.isTop() != under_ref) {
                blue_ref = @divTrunc(blue_shoot + blue_ref, 2);
                blue_shoot = blue_ref;
            }
        }
        _ = blues_axis.push(.{
            .position = blue_ref,
            .overshoot = blue_shoot,
            .ascender = 0,
            .descender = 0,
            .zones = blue_zones.intersect(BlueZones.top),
        });
    }
    return blues;
}

fn isOnCurve(point: glyf.UnscaledSinkPoint) bool {
    return point.flags & 0x01 != 0;
}

const BlueAcc = struct {
    ascender: i32,
    descender: i32,
};

const BestYCtx = struct {
    acc: *BlueAcc,
    best_y: ?i16,
    y_offset: i32,
    top: bool,
};

fn bestYTop(ctx: *BestYCtx, point: *const glyf.UnscaledSinkPoint) bool {
    if (ctx.best_y == null or point.y > ctx.best_y.?) {
        ctx.best_y = point.y;
        ctx.acc.ascender = @max(ctx.acc.ascender, @as(i32, point.y) + ctx.y_offset);
        return true;
    }
    ctx.acc.descender = @min(ctx.acc.descender, @as(i32, point.y) + ctx.y_offset);
    return false;
}

fn bestYBottom(ctx: *BestYCtx, point: *const glyf.UnscaledSinkPoint) bool {
    if (ctx.best_y == null or point.y < ctx.best_y.?) {
        ctx.best_y = point.y;
        ctx.acc.descender = @min(ctx.acc.descender, @as(i32, point.y) + ctx.y_offset);
        return true;
    }
    ctx.acc.ascender = @max(ctx.acc.ascender, @as(i32, point.y) + ctx.y_offset);
    return false;
}

/// Given inclusive indices and a contour length, returns true if the segment
/// is of sufficient size to test for bumps when detecting "long" alignment
/// zones.
fn satisfiesMinLongSegmentLen(first_ix: usize, last_ix: usize, contour_last: usize) bool {
    const inclusive_diff = if (first_ix <= last_ix)
        last_ix - first_ix
    else
        contour_last - first_ix + 1 + last_ix;
    return inclusive_diff + 2 <= contour_last;
}

const CycleEntry = struct { ix: usize };

fn cycleForward(len: usize, start: usize) CycleIterator {
    return .{ .len = len, .start = (start + 1) % @max(len, 1), .forward = true, .ix = 0 };
}

fn cycleBackward(len: usize, start: usize) CycleIterator {
    return .{ .len = len, .start = start, .forward = false, .ix = 0 };
}

const CycleIterator = struct {
    len: usize,
    start: usize,
    forward: bool,
    ix: usize,

    fn next(self: *CycleIterator) ?CycleEntry {
        if (self.len == 0 or self.ix >= self.len) return null;
        const real_ix = if (self.forward)
            (self.ix + self.start) % self.len
        else
            (self.start +% self.len -% 1 -% self.ix) % self.len;
        self.ix += 1;
        return .{ .ix = real_ix };
    }
};

test "cycle iterators match upstream" {
    const items = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var forward = cycleForward(items.len, 5);
    var seen: [8]usize = undefined;
    var n: usize = 0;
    while (forward.next()) |entry| : (n += 1) seen[n] = entry.ix;
    try std.testing.expectEqualSlices(usize, &[_]usize{ 6, 7, 0, 1, 2, 3, 4, 5 }, seen[0..n]);

    var backward = cycleBackward(items.len, 5);
    n = 0;
    while (backward.next()) |entry| : (n += 1) seen[n] = entry.ix;
    try std.testing.expectEqualSlices(usize, &[_]usize{ 4, 3, 2, 1, 0, 7, 6, 5 }, seen[0..n]);

    var empty = cycleForward(0, 5);
    try std.testing.expect(empty.next() == null);
}

test "long segment length avoids overflow" {
    try std.testing.expect(satisfiesMinLongSegmentLen(22, 0, 22));
}
