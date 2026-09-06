//! CSS Grid kernel: placement plus fixed, intrinsic and fractional tracks.
//!
//! Taffy's grid implementation is split across `compute/grid/placement.rs`
//! and `track_sizing.rs`. This file keeps that same separation conceptually:
//! `placeItems` resolves explicit coordinates and auto-flow into a dense
//! occupancy map, then `resolveTracks` performs the track-sizing phases.
//!
//! Supported track forms are fixed lengths, percentages, `auto`, intrinsic
//! keywords, `minmax()` through `GridTrack.min/max`, integer `repeat`, and
//! fractional tracks through `GridTrack.fr`. Implicit tracks are created as
//! needed by auto-placement. Subgrid, masonry, named lines and auto-fit/auto-
//! fill are intentionally not represented by the compact public style type.
//! Every working buffer is fixed-capacity and owned by `ComputeTree`.

const std = @import("std");
const tree_mod = @import("tree.zig");
const style_mod = @import("style.zig");
const geo = @import("geometry.zig");

pub const max_items: usize = tree_mod.max_nodes;
pub const max_tracks: usize = 512;

pub const GridContent = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const GridScratch = struct {
    item_ids: [max_items]tree_mod.NodeId = undefined,
    row_start: [max_items]u16 = undefined,
    col_start: [max_items]u16 = undefined,
    row_span: [max_items]u16 = undefined,
    col_span: [max_items]u16 = undefined,
    col_min: [max_tracks]f32 = undefined,
    col_max: [max_tracks]f32 = undefined,
    col_fr: [max_tracks]f32 = undefined,
    col_size: [max_tracks]f32 = undefined,
    row_min: [max_tracks]f32 = undefined,
    row_max: [max_tracks]f32 = undefined,
    row_fr: [max_tracks]f32 = undefined,
    row_size: [max_tracks]f32 = undefined,
    occupied: [max_tracks * max_tracks]bool = undefined,
};

/// Number of tracks after expanding a list of repeat counts.
pub fn trackCount(repeats: []const u16) u16 {
    var count: u16 = 0;
    for (repeats) |repeat| count +%= repeat;
    return count;
}

/// Clamp a span to the explicit grid edge. `start` is zero-based.
pub fn clampSpan(start: u16, span: u16, total: u16) u16 {
    if (total == 0 or start >= total) return 0;
    return @min(span, total - start);
}

/// Arrange grid children and return the content-box size used by the tracks.
/// A `null` available axis is intrinsic; a definite axis fills its available
/// content size with fractional tracks after intrinsic contributions.
pub fn arrange(
    tree: *tree_mod.LayoutTree,
    container: style_mod.Style,
    in_flow: []const tree_mod.NodeId,
    available_width: ?f32,
    available_height: ?f32,
    gap_col: f32,
    gap_row: f32,
    scratch: *GridScratch,
) GridContent {
    const item_count = in_flow.len;
    std.debug.assert(item_count <= max_items);
    const defaults = defaultTrackCounts(container, item_count);
    var cols = defaults.cols;
    var rows = defaults.rows;
    for (in_flow) |id| {
        const child = tree.nodes[id].style;
        if (child.grid_col_start) |start| {
            if (start > 0) {
                cols = @max(cols, @as(usize, @intCast(start - 1)) + @max(@as(usize, 1), child.grid_col_span));
            }
        }
        if (child.grid_row_start) |start| {
            if (start > 0) {
                rows = @max(rows, @as(usize, @intCast(start - 1)) + @max(@as(usize, 1), child.grid_row_span));
            }
        }
    }
    // Auto-placement creates implicit tracks after the explicit template.
    // Ensure the occupancy map has enough rows/columns for every source-order
    // item before placement begins (spans and explicit starts are accounted
    // for above; this is the common overflow case).
    if (container.grid_auto_flow.isColumn()) {
        cols = @max(cols, (item_count + rows - 1) / rows);
    } else {
        rows = @max(rows, (item_count + cols - 1) / cols);
    }
    cols = @min(cols, max_tracks);
    rows = @min(rows, max_tracks);
    cols = expandAxis(container.grid_columns, cols, available_width, scratch.col_min[0..max_tracks], scratch.col_max[0..max_tracks], scratch.col_fr[0..max_tracks]);
    rows = expandAxis(container.grid_rows, rows, available_height, scratch.row_min[0..max_tracks], scratch.row_max[0..max_tracks], scratch.row_fr[0..max_tracks]);
    if (cols == 0) cols = 1;
    if (rows == 0) rows = 1;

    for (0..rows) |row| {
        for (0..cols) |col| {
            scratch.occupied[row * max_tracks + col] = false;
        }
    }
    placeItems(tree, in_flow, cols, rows, container.grid_auto_flow, scratch);

    const width = resolveAxis(tree, in_flow, true, cols, available_width, gap_col, scratch, .{ .min = scratch.col_min[0..cols], .max = scratch.col_max[0..cols], .fr = scratch.col_fr[0..cols], .size = scratch.col_size[0..cols] });
    const height = resolveAxis(tree, in_flow, false, rows, available_height, gap_row, scratch, .{ .min = scratch.row_min[0..rows], .max = scratch.row_max[0..rows], .fr = scratch.row_fr[0..rows], .size = scratch.row_size[0..rows] });

    placeChildren(tree, container, in_flow, cols, rows, width, height, gap_col, gap_row, scratch);
    return .{ .width = width, .height = height };
}

fn defaultTrackCounts(style: style_mod.Style, items: usize) struct { cols: usize, rows: usize } {
    const explicit_cols = expandedCount(style.grid_columns);
    const explicit_rows = expandedCount(style.grid_rows);
    var cols = if (explicit_cols > 0) explicit_cols else if (style.grid_auto_flow.isColumn()) @max(@as(usize, 1), items) else 1;
    var rows = if (explicit_rows > 0) explicit_rows else if (style.grid_auto_flow.isColumn()) 1 else @max(@as(usize, 1), (items + cols - 1) / cols);
    cols = @min(cols, max_tracks);
    rows = @min(rows, max_tracks);
    return .{ .cols = cols, .rows = rows };
}

fn expandedCount(tracks: []const style_mod.GridTrack) usize {
    var count: usize = 0;
    for (tracks) |track| count += track.repeat;
    return @min(count, max_tracks);
}

fn expandAxis(tracks: []const style_mod.GridTrack, implicit_count: usize, available: ?f32, mins: []f32, maxs: []f32, frs: []f32) usize {
    const explicit = expandedCount(tracks);
    const count = @min(@max(explicit, implicit_count), max_tracks);
    var out: usize = 0;
    for (tracks) |track| {
        var repeat: usize = 0;
        while (repeat < track.repeat and out < count) : (repeat += 1) {
            mins[out] = dimensionMin(track.min, available);
            maxs[out] = dimensionMax(track.max, available);
            frs[out] = @max(0, track.fr);
            out += 1;
        }
        if (out == count) break;
    }
    while (out < count) : (out += 1) {
        mins[out] = 0;
        maxs[out] = std.math.inf(f32);
        frs[out] = 0;
    }
    return count;
}

fn dimensionMin(dimension: style_mod.Dimension, available: ?f32) f32 {
    return switch (dimension) {
        .length => |value| @max(0, value),
        .percent => |fraction| if (available) |extent| @max(0, extent * fraction) else 0,
        else => 0,
    };
}

fn dimensionMax(dimension: style_mod.Dimension, available: ?f32) f32 {
    return switch (dimension) {
        .length => |value| @max(0, value),
        .percent => |fraction| if (available) |extent| @max(0, extent * fraction) else std.math.inf(f32),
        .auto, .min_content => std.math.inf(f32),
        .max_content => std.math.inf(f32),
    };
}

const AxisBuffers = struct {
    min: []f32,
    max: []f32,
    fr: []f32,
    size: []f32,
};

fn resolveAxis(
    tree: *tree_mod.LayoutTree,
    items: []const tree_mod.NodeId,
    horizontal: bool,
    count: usize,
    available: ?f32,
    gap: f32,
    scratch: *GridScratch,
    buffers: AxisBuffers,
) f32 {
    for (0..count) |i| buffers.size[i] = @max(0, buffers.min[i]);

    // Intrinsic contributions from spanning items. A deficit is shared by
    // tracks that are not fixed; if every track is fixed the item overflows,
    // exactly as a CSS fixed track does.
    for (items, 0..) |id, item_index| {
        const start = if (horizontal) scratch.col_start[item_index] else scratch.row_start[item_index];
        const span = if (horizontal) scratch.col_span[item_index] else scratch.row_span[item_index];
        const desired = itemOuter(tree, id, horizontal);
        const end = @min(count, @as(usize, start) + span);
        if (end <= start) continue;
        var current: f32 = gap * @as(f32, @floatFromInt(if (span > 1) span - 1 else 0));
        for (start..end) |track| current += buffers.size[track];
        if (desired <= current) continue;
        const deficit = desired - current;
        var growable: usize = 0;
        for (start..end) |track| {
            if (buffers.fr[track] > 0 or !std.math.isFinite(buffers.max[track])) growable += 1;
        }
        if (growable == 0) continue;
        const share = deficit / @as(f32, @floatFromInt(growable));
        for (start..end) |track| {
            if (buffers.fr[track] > 0 or !std.math.isFinite(buffers.max[track])) buffers.size[track] += share;
        }
    }

    var total: f32 = gap * @as(f32, @floatFromInt(if (count > 1) count - 1 else 0));
    for (0..count) |i| total += buffers.size[i];
    if (available) |extent| {
        const free = extent - total;
        if (free > 0) {
            var fr_total: f32 = 0;
            var auto_count: usize = 0;
            for (0..count) |i| {
                fr_total += buffers.fr[i];
                if (buffers.fr[i] == 0 and !std.math.isFinite(buffers.max[i])) auto_count += 1;
            }
            if (fr_total > 0) {
                for (0..count) |i| {
                    if (buffers.fr[i] > 0) buffers.size[i] += free * buffers.fr[i] / fr_total;
                }
            } else if (auto_count > 0) {
                const share = free / @as(f32, @floatFromInt(auto_count));
                for (0..count) |i| {
                    if (buffers.fr[i] == 0 and !std.math.isFinite(buffers.max[i])) buffers.size[i] += share;
                }
            }
        } else if (free < 0) {
            var shrink_total: f32 = 0;
            for (0..count) |i| {
                if (buffers.fr[i] > 0 or !std.math.isFinite(buffers.max[i])) shrink_total += buffers.size[i];
            }
            if (shrink_total > 0) for (0..count) |i| {
                if (buffers.fr[i] > 0 or !std.math.isFinite(buffers.max[i])) buffers.size[i] = @max(0, buffers.size[i] + free * buffers.size[i] / shrink_total);
            };
        }
    }

    total = gap * @as(f32, @floatFromInt(if (count > 1) count - 1 else 0));
    for (0..count) |i| {
        buffers.size[i] = @max(buffers.min[i], @min(buffers.max[i], buffers.size[i]));
        total += buffers.size[i];
    }
    return total;
}

fn itemOuter(tree: *const tree_mod.LayoutTree, id: tree_mod.NodeId, horizontal: bool) f32 {
    const node = tree.nodes[id];
    return if (horizontal)
        node.layout.w + node.style.margin.left + node.style.margin.right
    else
        node.layout.h + node.style.margin.top + node.style.margin.bottom;
}

fn placeItems(tree: *const tree_mod.LayoutTree, items: []const tree_mod.NodeId, cols: usize, rows: usize, flow: style_mod.GridAutoFlow, scratch: *GridScratch) void {
    var sparse_cursor: usize = 0;
    for (items, 0..) |id, i| {
        scratch.item_ids[i] = id;
        scratch.row_span[i] = @max(@as(u16, 1), tree.nodes[id].style.grid_row_span);
        scratch.col_span[i] = @max(@as(u16, 1), tree.nodes[id].style.grid_col_span);
        const style = tree.nodes[id].style;
        scratch.row_start[i] = resolveLine(style.grid_row_start, rows);
        scratch.col_start[i] = resolveLine(style.grid_col_start, cols);
        const row_auto = style.grid_row_start == null;
        const col_auto = style.grid_col_start == null;
        if (!row_auto and !col_auto) {
            occupy(scratch.row_start[i], scratch.col_start[i], scratch.row_span[i], scratch.col_span[i], rows, cols, scratch);
            if (!flow.isDense()) sparse_cursor = @max(sparse_cursor, @as(usize, scratch.row_start[i]) * cols + scratch.col_start[i] + scratch.col_span[i]);
            continue;
        }

        var cursor: usize = if (flow.isDense()) 0 else sparse_cursor;
        var found = false;
        while (!found) {
            const r = if (flow.isColumn()) cursor % rows else cursor / cols;
            const c = if (flow.isColumn()) cursor / rows else cursor % cols;
            if (r < rows and c < cols and (row_auto or r == scratch.row_start[i]) and (col_auto or c == scratch.col_start[i]) and fits(@intCast(r), @intCast(c), scratch.row_span[i], scratch.col_span[i], rows, cols, scratch)) {
                scratch.row_start[i] = if (row_auto) @intCast(r) else scratch.row_start[i];
                scratch.col_start[i] = if (col_auto) @intCast(c) else scratch.col_start[i];
                occupy(scratch.row_start[i], scratch.col_start[i], scratch.row_span[i], scratch.col_span[i], rows, cols, scratch);
                if (!flow.isDense()) sparse_cursor = cursor + 1;
                found = true;
            } else {
                cursor += 1;
                if (cursor >= rows * cols + 1) {
                    // Fixed-cap overflow: put the item at the final legal
                    // cell; its measured size may overflow, but indices stay
                    // memory-safe and deterministic.
                    scratch.row_start[i] = @intCast(@min(rows - 1, if (flow.isColumn()) cursor % rows else cursor / cols));
                    scratch.col_start[i] = @intCast(@min(cols - 1, if (flow.isColumn()) cursor / rows else cursor % cols));
                    occupyClipped(scratch.row_start[i], scratch.col_start[i], scratch.row_span[i], scratch.col_span[i], rows, cols, scratch);
                    if (!flow.isDense()) sparse_cursor = cursor + 1;
                    found = true;
                }
            }
        }
    }
}

fn cursorFor(flow: style_mod.GridAutoFlow, scratch: *const GridScratch, item_index: usize) usize {
    if (item_index == 0) return 0;
    var cursor: usize = 0;
    for (0..item_index) |i| {
        cursor = if (flow.isColumn()) @as(usize, scratch.row_start[i]) + scratch.row_span[i] else @as(usize, scratch.col_start[i]) + scratch.col_span[i];
    }
    return cursor;
}

fn resolveLine(line: ?i16, track_count: usize) u16 {
    if (line) |value| {
        if (value > 0) return @intCast(@min(track_count - 1, @as(usize, @intCast(value - 1))));
        if (value < 0) {
            const magnitude: usize = @intCast(-value);
            return @intCast(if (magnitude > track_count) 0 else track_count - magnitude);
        }
    }
    return 0;
}

fn fits(row: u16, col: u16, row_span: u16, col_span: u16, rows: usize, cols: usize, scratch: *const GridScratch) bool {
    if (@as(usize, row) >= rows or @as(usize, col) >= cols) return false;
    const row_end = @min(rows, @as(usize, row) + row_span);
    const col_end = @min(cols, @as(usize, col) + col_span);
    if (row_end <= row or col_end <= col) return false;
    for (@as(usize, row)..row_end) |r| {
        for (@as(usize, col)..col_end) |c| {
            if (scratch.occupied[r * max_tracks + c]) return false;
        }
    }
    return true;
}

fn occupy(row: u16, col: u16, row_span: u16, col_span: u16, rows: usize, cols: usize, scratch: *GridScratch) void {
    const row_end = @min(rows, @as(usize, row) + row_span);
    const col_end = @min(cols, @as(usize, col) + col_span);
    for (@as(usize, row)..row_end) |r| {
        for (@as(usize, col)..col_end) |c| scratch.occupied[r * max_tracks + c] = true;
    }
}

fn occupyClipped(row: u16, col: u16, row_span: u16, col_span: u16, rows: usize, cols: usize, scratch: *GridScratch) void {
    occupy(@min(row, @as(u16, @intCast(rows - 1))), @min(col, @as(u16, @intCast(cols - 1))), row_span, col_span, rows, cols, scratch);
}

fn placeChildren(tree: *tree_mod.LayoutTree, container: style_mod.Style, items: []const tree_mod.NodeId, cols: usize, rows: usize, width: f32, height: f32, gap_col: f32, gap_row: f32, scratch: *const GridScratch) void {
    const col_offset = alignmentOffset(container.justify_content, width - axisTotal(scratch.col_size[0..cols], gap_col));
    const row_offset = alignmentOffset(container.align_content, height - axisTotal(scratch.row_size[0..rows], gap_row));
    for (items, 0..) |id, i| {
        const cs = tree.nodes[id].style;
        const row = @as(usize, scratch.row_start[i]);
        const col = @as(usize, scratch.col_start[i]);
        if (row >= rows or col >= cols) continue;
        const row_end = @min(rows, row + scratch.row_span[i]);
        const col_end = @min(cols, col + scratch.col_span[i]);
        var x = col_offset;
        for (0..col) |track| x += scratch.col_size[track] + gap_col;
        var y = row_offset;
        for (0..row) |track| y += scratch.row_size[track] + gap_row;
        var area_w = gap_col * @as(f32, @floatFromInt(if (col_end > col) col_end - col - 1 else 0));
        var area_h = gap_row * @as(f32, @floatFromInt(if (row_end > row) row_end - row - 1 else 0));
        for (col..col_end) |track| area_w += scratch.col_size[track];
        for (row..row_end) |track| area_h += scratch.row_size[track];

        const auto_w = cs.isAutoOnAxis(true);
        const auto_h = cs.isAutoOnAxis(false);
        const m = cs.margin;
        const vertical_alignment = container.effectiveAlign(cs.align_self);
        const child_width = if (auto_w and !cs.margin_left_auto and !cs.margin_right_auto) @max(0, area_w - m.left - m.right) else tree.nodes[id].layout.w;
        const child_height = if (auto_h and vertical_alignment == .stretch and !cs.margin_top_auto and !cs.margin_bottom_auto) @max(0, area_h - m.top - m.bottom) else tree.nodes[id].layout.h;
        tree.nodes[id].layout.w = child_width;
        tree.nodes[id].layout.h = child_height;
        const free_width = area_w - child_width - m.left - m.right;
        const free_height = area_h - child_height - m.top - m.bottom;
        const horizontal_item_offset = if (free_width > 0) switch (container.justify_content) {
            .end, .flex_end => free_width,
            .center => free_width / 2,
            else => 0,
        } else 0;
        const vertical_item_offset = if (free_height > 0) switch (vertical_alignment) {
            .end, .flex_end => free_height,
            .center => free_height / 2,
            else => 0,
        } else 0;
        tree.nodes[id].layout.x = x + m.left + horizontal_item_offset;
        tree.nodes[id].layout.y = y + m.top + vertical_item_offset;
    }
}

fn axisTotal(sizes: []const f32, gap: f32) f32 {
    var total: f32 = gap * @as(f32, @floatFromInt(if (sizes.len > 1) sizes.len - 1 else 0));
    for (sizes) |size| total += size;
    return total;
}

fn alignmentOffset(alignment: anytype, free_value: f32) f32 {
    const free = @max(0, free_value);
    return switch (alignment) {
        .end, .flex_end => free,
        .center => free / 2,
        else => 0,
    };
}

/// Arrange-only compatibility entry point retained from the initial scaffold.
pub fn computeGrid(tree: *tree_mod.LayoutTree, id: tree_mod.NodeId, input: geo.LayoutInput) void {
    var ids: [max_items]tree_mod.NodeId = undefined;
    var count: usize = 0;
    var child = tree.nodes[id].first_child;
    while (child) |child_id| : (child = tree.nodes[child_id].next_sibling) {
        if (tree.nodes[child_id].style.position != .absolute and tree.nodes[child_id].style.display != .none) {
            ids[count] = child_id;
            count += 1;
        }
    }
    var scratch = GridScratch{};
    const result = arrange(tree, tree.nodes[id].style, ids[0..count], input.known.w orelse input.available.w.opt(), input.known.h orelse input.available.h.opt(), 0, 0, &scratch);
    tree.nodes[id].layout.w = result.width;
    tree.nodes[id].layout.h = result.height;
}

test "track count expands repeats" {
    const repeats = [_]u16{ 2, 3 };
    try std.testing.expectEqual(@as(u16, 5), trackCount(&repeats));
}

test "span clamps to grid edge" {
    try std.testing.expectEqual(@as(u16, 2), clampSpan(1, 5, 3));
    try std.testing.expectEqual(@as(u16, 0), clampSpan(3, 1, 3));
}

test "fixed grid track resolution is deterministic" {
    var tree = tree_mod.LayoutTree{};
    const a = tree.newLeaf(.{});
    const b = tree.newLeaf(.{});
    var cols = [_]style_mod.GridTrack{ style_mod.GridTrack.fixed(40), style_mod.GridTrack.fixed(60) };
    const style = style_mod.Style{ .display = .grid, .grid_columns = &cols };
    var scratch = GridScratch{};
    const result = arrange(&tree, style, &[_]tree_mod.NodeId{ a, b }, 100, 20, 0, 0, &scratch);
    try std.testing.expectEqual(@as(f32, 100), result.width);
    try std.testing.expectEqual(@as(f32, 40), tree.nodes[a].layout.w);
    try std.testing.expectEqual(@as(f32, 60), tree.nodes[b].layout.w);
}
