//! Flexbox kernel: line formation, flexible-length resolution and alignment.
//!
//! This is a deliberately small, allocation-free implementation of the
//! parts of CSS Flexbox used by Taffy's normal UI workloads. The dispatcher
//! performs the recursive measure pass; this file consumes already measured
//! children and arranges them in a definite content box.
//!
//! The implementation follows Taffy's flexbox phases in the same order:
//! collect items, form lines, resolve flexible lengths, size lines, distribute
//! `align-content`, and finally resolve margins and alignment. `baseline`
//! falls back to `flex-start` because the compact measure ABI has no baseline
//! metadata yet.

const std = @import("std");
const tree_mod = @import("tree.zig");
const style_mod = @import("style.zig");
const geo = @import("geometry.zig");

pub const max_items: usize = tree_mod.max_nodes;

pub const FlexContent = struct {
    main: f32 = 0,
    cross: f32 = 0,
};

/// Scratch is owned by `ComputeTree`, so recursive layout never allocates or
/// places a 4096-item working set on the call stack.
pub const ArrangeScratch = struct {
    ids: [max_items]tree_mod.NodeId = undefined,
    base: [max_items]f32 = undefined,
    target: [max_items]f32 = undefined,
    line_of: [max_items]u16 = undefined,
    line_start: [max_items]u16 = undefined,
    line_end: [max_items]u16 = undefined,
    line_cross: [max_items]f32 = undefined,
    line_offset: [max_items]f32 = undefined,
    frozen: [max_items]bool = undefined,
    main_pos: [max_items]f32 = undefined,
    outer: [max_items]f32 = undefined,
};

pub fn childOuterMain(tree: *const tree_mod.LayoutTree, id: tree_mod.NodeId, is_row: bool) f32 {
    const n = tree.nodes[id];
    const m = n.style.margin;
    return if (is_row) n.layout.w + m.left + m.right else n.layout.h + m.top + m.bottom;
}

pub fn childOuterCross(tree: *const tree_mod.LayoutTree, id: tree_mod.NodeId, is_row: bool) f32 {
    const n = tree.nodes[id];
    const m = n.style.margin;
    return if (is_row) n.layout.h + m.top + m.bottom else n.layout.w + m.left + m.right;
}

/// Sum item sizes and the gap between adjacent items.
pub fn mainAxisBase(sizes: []const f32, gap: f32) f32 {
    if (sizes.len == 0) return 0;
    var total: f32 = 0;
    for (sizes) |size| total += size;
    return total + gap * @as(f32, @floatFromInt(sizes.len - 1));
}

/// Distribute positive free space by grow factors. `out` receives final
/// sizes, not just the delta.
pub fn distributeGrow(base: []const f32, grows: []const f32, remaining: f32, out: []f32) void {
    std.debug.assert(base.len == grows.len and grows.len == out.len);
    var total: f32 = 0;
    for (grows) |grow| total += @max(0, grow);
    for (base, grows, out) |b, grow, *result| {
        result.* = if (remaining > 0 and total > 0 and grow > 0) b + remaining * grow / total else b;
    }
}

/// Remove a positive deficit using the scaled-shrink factor `basis * shrink`.
pub fn distributeShrink(base: []const f32, shrinks: []const f32, deficit: f32, out: []f32) void {
    std.debug.assert(base.len == shrinks.len and shrinks.len == out.len);
    var total: f32 = 0;
    for (base, shrinks) |b, shrink| total += @max(0, b) * @max(0, shrink);
    for (base, shrinks, out) |b, shrink, *result| {
        const scaled = @max(0, b) * @max(0, shrink);
        result.* = if (deficit > 0 and total > 0 and scaled > 0) @max(0, b - deficit * scaled / total) else b;
    }
}

/// Compatibility helper for callers that do not need a gap-aware line break.
pub fn collectLines(
    mains: []const f32,
    limit: ?f32,
    min_content: bool,
    line_of: []u16,
    line_starts: ?[]u16,
    line_ends: ?[]u16,
) u16 {
    return collectLinesWithGap(mains, limit, 0, min_content, line_of, line_starts, line_ends);
}

/// Greedy line formation. A first item is always admitted even when it is
/// wider than the limit, matching browser/Taffy behavior. Intrinsic
/// min-content formation gives each item its own line.
pub fn collectLinesWithGap(
    mains: []const f32,
    limit: ?f32,
    gap: f32,
    min_content: bool,
    line_of: []u16,
    line_starts: ?[]u16,
    line_ends: ?[]u16,
) u16 {
    std.debug.assert(mains.len == line_of.len);
    if (mains.len == 0) return 0;

    if (min_content) {
        for (line_of, 0..) |*line, i| line.* = @intCast(i);
        if (line_starts) |starts| {
            for (starts[0..mains.len], 0..) |*value, i| value.* = @intCast(i);
        }
        if (line_ends) |ends| {
            for (ends[0..mains.len], 0..) |*value, i| value.* = @intCast(i + 1);
        }
        return @intCast(mains.len);
    }

    const max_limit = limit orelse std.math.inf(f32);
    var line_count: usize = 1;
    var line_start: usize = 0;
    var used: f32 = 0;
    for (mains, 0..) |main, i| {
        const candidate = if (i == line_start) main else used + gap + main;
        if (i != line_start and candidate > max_limit) {
            line_count += 1;
            line_start = i;
            used = main;
        } else {
            used = candidate;
        }
        line_of[i] = @intCast(line_count - 1);
    }

    if (line_starts) |starts| {
        starts[0] = 0;
        var line: usize = 1;
        for (line_of, 0..) |line_index, i| {
            if (line_index == line) {
                starts[line] = @intCast(i);
                line += 1;
            }
        }
    }
    if (line_ends) |ends| {
        var line: usize = 0;
        for (line_of, 0..) |line_index, i| {
            if (line_index != line) {
                ends[line] = @intCast(i);
                line = line_index;
            }
        }
        ends[line] = @intCast(mains.len);
    }
    return @intCast(line_count);
}

/// Read-only intrinsic contribution of already measured children.
pub fn contentSize(
    tree: *const tree_mod.LayoutTree,
    in_flow: []const tree_mod.NodeId,
    is_row: bool,
    main_available: ?f32,
    min_content: bool,
    gap_main: f32,
    gap_cross: f32,
) FlexContent {
    if (in_flow.len == 0) return .{};
    var mains: [max_items]f32 = undefined;
    var lines: [max_items]u16 = undefined;
    const n = @min(in_flow.len, max_items);
    for (in_flow[0..n], 0..) |id, i| mains[i] = childOuterMain(tree, id, is_row);
    const count = collectLinesWithGap(mains[0..n], main_available, gap_main, min_content, lines[0..n], null, null);

    var result = FlexContent{};
    var line: u16 = 0;
    while (line < count) : (line += 1) {
        var line_main: f32 = 0;
        var line_cross: f32 = 0;
        var item_count: usize = 0;
        for (in_flow[0..n], 0..) |id, i| {
            if (lines[i] != line) continue;
            line_main += mains[i];
            line_cross = @max(line_cross, childOuterCross(tree, id, is_row));
            item_count += 1;
        }
        if (item_count > 1) line_main += gap_main * @as(f32, @floatFromInt(item_count - 1));
        result.main = @max(result.main, line_main);
        result.cross += line_cross;
    }
    if (count > 1) result.cross += gap_cross * @as(f32, @floatFromInt(count - 1));
    if (in_flow.len > n) for (in_flow[n..]) |id| {
        result.main = @max(result.main, childOuterMain(tree, id, is_row));
        result.cross += childOuterCross(tree, id, is_row) + gap_cross;
    };
    return result;
}

/// Arrange measured in-flow children into a definite content box.
pub fn arrange(
    tree: *tree_mod.LayoutTree,
    container: style_mod.Style,
    in_flow: []const tree_mod.NodeId,
    final_main: f32,
    final_cross: f32,
    gap_main: f32,
    gap_cross: f32,
    scratch: *ArrangeScratch,
) void {
    const n = in_flow.len;
    if (n == 0) return;
    std.debug.assert(n <= max_items);
    const is_row = container.flex_direction.isRow();
    const reverse = container.flex_direction.isReverse() or (is_row and container.direction == .rtl);
    const wrap = container.flex_wrap != .no_wrap;

    for (in_flow, 0..) |id, i| {
        scratch.ids[i] = id;
        const child = tree.nodes[id].style;
        const measured_main = if (is_row) tree.nodes[id].layout.w else tree.nodes[id].layout.h;
        scratch.base[i] = @max(0, resolveBasis(child, is_row, measured_main, final_main));
        scratch.target[i] = scratch.base[i];
        const m = child.margin;
        scratch.outer[i] = scratch.base[i] + if (is_row) m.left + m.right else m.top + m.bottom;
    }

    const line_count = collectLinesWithGap(
        scratch.outer[0..n],
        if (wrap) final_main else null,
        gap_main,
        false,
        scratch.line_of[0..n],
        scratch.line_start[0..n],
        scratch.line_end[0..n],
    );

    var line: u16 = 0;
    while (line < line_count) : (line += 1) {
        resolveLine(tree, scratch, scratch.line_start[line], scratch.line_end[line], is_row, final_main, gap_main, line);
    }

    distributeLines(container, final_cross, gap_cross, scratch.line_cross[0..line_count], scratch.line_offset[0..line_count], container.flex_wrap == .wrap_reverse);

    line = 0;
    while (line < line_count) : (line += 1) {
        const start = scratch.line_start[line];
        const end = scratch.line_end[line];
        positionLine(tree, container, scratch.ids[start..end], scratch.target[start..end], is_row, reverse, final_main, gap_main, scratch.line_cross[line], scratch.line_offset[line]);
    }
}

fn resolveBasis(cs: style_mod.Style, is_row: bool, measured_main: f32, final_main: f32) f32 {
    if (!cs.flex_basis.isAuto()) return cs.flex_basis.resolve(final_main) orelse measured_main;
    const dimension = if (is_row) cs.width else cs.height;
    if (!dimension.isAuto()) return dimension.resolve(final_main) orelse measured_main;
    const legacy = if (is_row) cs.size.w else cs.size.h;
    return if (legacy != 0) legacy else measured_main;
}

fn resolveMinMax(cs: style_mod.Style, is_row: bool, parent_main: f32) struct { min: f32, max: f32 } {
    const min_dim = if (is_row) cs.min_width else cs.min_height;
    const max_dim = if (is_row) cs.max_width else cs.max_height;
    const minimum = min_dim.resolve(parent_main) orelse 0;
    const maximum = max_dim.resolve(parent_main) orelse std.math.inf(f32);
    return .{ .min = @max(0, minimum), .max = @max(@max(0, minimum), maximum) };
}

/// Freeze min/max violators and redistribute free space among the remaining
/// items. The bounded loop is the same termination idea as Taffy's loop, but
/// uses only fixed scratch arrays.
fn resolveLine(
    tree: *tree_mod.LayoutTree,
    scratch: *ArrangeScratch,
    start: u16,
    end: u16,
    is_row: bool,
    final_main: f32,
    gap_main: f32,
    line_index: u16,
) void {
    const count = end - start;
    for (scratch.frozen[start..end]) |*frozen| frozen.* = false;

    var iteration: usize = 0;
    while (iteration <= count) : (iteration += 1) {
        var used_fixed: f32 = 0;
        var active_base: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink: f32 = 0;
        var active_count: usize = 0;
        for (start..end) |i| {
            const cs = tree.nodes[scratch.ids[i]].style;
            const margin = if (is_row) cs.margin.left + cs.margin.right else cs.margin.top + cs.margin.bottom;
            if (scratch.frozen[i]) {
                used_fixed += scratch.target[i] + margin;
            } else {
                active_count += 1;
                active_base += scratch.base[i];
                total_grow += @max(0, cs.flex_grow);
                total_shrink += @max(0, scratch.base[i]) * @max(0, cs.flex_shrink);
            }
        }
        if (count > 1) used_fixed += gap_main * @as(f32, @floatFromInt(count - 1));
        const remaining = final_main - used_fixed - active_base;
        if (active_count == 0 or (remaining > 0 and total_grow == 0) or (remaining < 0 and total_shrink == 0)) break;

        var any_violation = false;
        for (start..end) |i| {
            if (scratch.frozen[i]) continue;
            const cs = tree.nodes[scratch.ids[i]].style;
            var target = scratch.base[i];
            if (remaining > 0 and total_grow > 0) {
                target += remaining * @max(0, cs.flex_grow) / total_grow;
            } else if (remaining < 0 and total_shrink > 0) {
                const scaled = @max(0, scratch.base[i]) * @max(0, cs.flex_shrink);
                target = @max(0, target + remaining * scaled / total_shrink);
            }
            const limits = resolveMinMax(cs, is_row, final_main);
            const clamped = clamp(target, limits.min, limits.max);
            scratch.target[i] = clamped;
            if (clamped != target) {
                scratch.frozen[i] = true;
                any_violation = true;
            }
        }
        if (!any_violation) break;
    }

    var cross: f32 = 0;
    for (start..end) |i| {
        const id = scratch.ids[i];
        const cs = tree.nodes[id].style;
        const margin = if (is_row) cs.margin.top + cs.margin.bottom else cs.margin.left + cs.margin.right;
        const size = if (is_row) tree.nodes[id].layout.h else tree.nodes[id].layout.w;
        cross = @max(cross, size + margin);
    }
    scratch.line_cross[line_index] = cross;
}

fn clamp(value: f32, low: f32, high: f32) f32 {
    return @min(high, @max(low, value));
}

fn distributeLines(style: style_mod.Style, final_cross: f32, gap: f32, crosses: []f32, offsets: []f32, wrap: bool) void {
    if (crosses.len == 0) return;
    var total: f32 = 0;
    for (crosses) |cross| total += cross;
    if (crosses.len > 1) total += gap * @as(f32, @floatFromInt(crosses.len - 1));
    var free = final_cross - total;
    if (free < 0) free = 0;

    var start: f32 = 0;
    var step = gap;
    switch (style.align_content) {
        .start, .flex_start => {},
        .end, .flex_end => start = free,
        .center => start = free / 2,
        .space_between => {
            if (crosses.len > 1) step += free / @as(f32, @floatFromInt(crosses.len - 1)) else start = free / 2;
        },
        .space_around => {
            const each = free / @as(f32, @floatFromInt(crosses.len));
            start = each / 2;
            step += each;
        },
        .space_evenly => {
            const each = free / @as(f32, @floatFromInt(crosses.len + 1));
            start = each;
            step += each;
        },
        .stretch => {
            const each = free / @as(f32, @floatFromInt(crosses.len));
            for (crosses) |*cross| cross.* += each;
        },
    }

    var cursor = start;
    for (crosses, offsets) |cross, *offset| {
        offset.* = cursor;
        cursor += cross + step;
    }
    if (wrap) {
        for (crosses, offsets) |cross, *offset| offset.* = final_cross - offset.* - cross;
    }
}

fn positionLine(
    tree: *tree_mod.LayoutTree,
    container: style_mod.Style,
    ids: []const tree_mod.NodeId,
    targets: []const f32,
    is_row: bool,
    reverse: bool,
    final_main: f32,
    gap_main: f32,
    line_cross: f32,
    line_offset: f32,
) void {
    const count = ids.len;
    if (count == 0) return;

    // Publish the resolved main sizes before calculating positions. The
    // dispatcher uses these values as the child's final assigned size during
    // the subsequent nested reflow.
    for (ids, targets) |id, target| {
        if (is_row) tree.nodes[id].layout.w = target else tree.nodes[id].layout.h = target;
    }

    var used: f32 = gap_main * @as(f32, @floatFromInt(if (count > 1) count - 1 else 0));
    var auto_count: usize = 0;
    for (ids, targets) |id, target| {
        const cs = tree.nodes[id].style;
        const m = cs.margin;
        used += target + if (is_row) m.left + m.right else m.top + m.bottom;
        if (is_row) {
            if (cs.margin_left_auto) auto_count += 1;
            if (cs.margin_right_auto) auto_count += 1;
        } else {
            if (cs.margin_top_auto) auto_count += 1;
            if (cs.margin_bottom_auto) auto_count += 1;
        }
    }

    const free = final_main - used;
    const auto_share = if (auto_count > 0 and free > 0) free / @as(f32, @floatFromInt(auto_count)) else 0;
    var justify_gap = gap_main;
    var cursor: f32 = 0;
    if (auto_count == 0 or free <= 0) switch (container.justify_content) {
        .start, .flex_start => {},
        .end, .flex_end => cursor = @max(0, free),
        .center => cursor = @max(0, free / 2),
        .space_between => {
            if (count > 1 and free > 0) justify_gap += free / @as(f32, @floatFromInt(count - 1)) else cursor = @max(0, free / 2);
        },
        .space_around => if (free > 0) {
            const each = free / @as(f32, @floatFromInt(count));
            cursor = each / 2;
            justify_gap += each;
        },
        .space_evenly => if (free > 0) {
            const each = free / @as(f32, @floatFromInt(count + 1));
            cursor = each;
            justify_gap += each;
        },
    };

    var positions: [max_items]f32 = undefined;
    for (ids, targets, 0..) |id, target, i| {
        const cs = tree.nodes[id].style;
        const m = cs.margin;
        const lead_auto = if (is_row) cs.margin_left_auto else cs.margin_top_auto;
        const trail_auto = if (is_row) cs.margin_right_auto else cs.margin_bottom_auto;
        cursor += (if (is_row) m.left else m.top) + if (lead_auto) auto_share else 0;
        positions[i] = cursor;
        cursor += target + (if (is_row) m.right else m.bottom) + if (trail_auto) auto_share else 0;
        if (i + 1 < count) cursor += justify_gap;
    }
    if (reverse) for (ids, 0..) |id, i| {
        const m = tree.nodes[id].style.margin;
        const lead = if (is_row) m.left else m.top;
        const trail = if (is_row) m.right else m.bottom;
        positions[i] = final_main - positions[i] - targets[i] - lead - trail + lead;
    };

    for (ids, 0..) |id, i| {
        const cs = tree.nodes[id].style;
        const m = cs.margin;
        const cross_alignment = container.effectiveAlign(cs.align_self);
        const lead_margin = if (is_row) m.top else m.left;
        const trail_margin = if (is_row) m.bottom else m.right;
        const lead_auto = if (is_row) cs.margin_top_auto else cs.margin_left_auto;
        const trail_auto = if (is_row) cs.margin_bottom_auto else cs.margin_right_auto;
        var cross_size = if (is_row) tree.nodes[id].layout.h else tree.nodes[id].layout.w;
        const cross_auto = cs.isAutoOnAxis(!is_row);
        if (cross_alignment == .stretch and cross_auto and !lead_auto and !trail_auto) {
            cross_size = clamp(line_cross - lead_margin - trail_margin, crossMin(cs, is_row, line_cross), crossMax(cs, is_row, line_cross));
            if (is_row) tree.nodes[id].layout.h = cross_size else tree.nodes[id].layout.w = cross_size;
        }
        const free_cross = line_cross - cross_size - lead_margin - trail_margin;
        var cross_pos = line_offset + lead_margin;
        if (lead_auto and trail_auto and free_cross > 0) cross_pos += free_cross / 2 else if (lead_auto and free_cross > 0) cross_pos += free_cross else if (!lead_auto and !trail_auto) switch (cross_alignment) {
            .end, .flex_end => cross_pos += @max(0, free_cross),
            .center => cross_pos += @max(0, free_cross / 2),
            else => {},
        };

        if (is_row) {
            tree.nodes[id].layout.x = positions[i];
            tree.nodes[id].layout.y = cross_pos;
        } else {
            tree.nodes[id].layout.x = cross_pos;
            tree.nodes[id].layout.y = positions[i];
        }
    }
}

fn crossMin(cs: style_mod.Style, is_row: bool, parent_cross: f32) f32 {
    return @max(0, (if (is_row) cs.min_height else cs.min_width).resolve(parent_cross) orelse 0);
}

fn crossMax(cs: style_mod.Style, is_row: bool, parent_cross: f32) f32 {
    const maximum = (if (is_row) cs.max_height else cs.max_width).resolve(parent_cross) orelse std.math.inf(f32);
    return @max(crossMin(cs, is_row, parent_cross), maximum);
}

/// Arrange-only compatibility entry point. The dispatcher uses `arrange`
/// after recursive measurement; this preserves the scaffold's public API.
pub fn computeFlex(tree: *tree_mod.LayoutTree, id: tree_mod.NodeId, input: geo.LayoutInput) void {
    var ids: [max_items]tree_mod.NodeId = undefined;
    var count: usize = 0;
    var child = tree.nodes[id].first_child;
    while (child) |child_id| : (child = tree.nodes[child_id].next_sibling) {
        if (tree.nodes[child_id].style.position != .absolute and tree.nodes[child_id].style.display != .none) {
            ids[count] = child_id;
            count += 1;
        }
    }
    const row = tree.nodes[id].style.flex_direction.isRow();
    const natural = contentSize(tree, ids[0..count], row, null, false, 0, 0);
    const width = input.known.w orelse input.available.w.opt() orelse if (row) natural.main else natural.cross;
    const height = input.known.h orelse input.available.h.opt() orelse if (row) natural.cross else natural.main;
    tree.nodes[id].layout.w = @max(0, width);
    tree.nodes[id].layout.h = @max(0, height);
    var scratch = ArrangeScratch{};
    arrange(tree, tree.nodes[id].style, ids[0..count], if (row) width else height, if (row) height else width, 0, 0, &scratch);
}

test "main axis sums with gap" {
    const sizes = [_]f32{ 10, 20, 30 };
    try std.testing.expectEqual(@as(f32, 70), mainAxisBase(&sizes, 5));
    try std.testing.expectEqual(@as(f32, 0), mainAxisBase(&.{}, 5));
}

test "grow and shrink use flex factors" {
    const base = [_]f32{ 0, 0 };
    const grows = [_]f32{ 1, 3 };
    var grown = [_]f32{ 0, 0 };
    distributeGrow(&base, &grows, 100, &grown);
    try std.testing.expectEqual(@as(f32, 25), grown[0]);
    try std.testing.expectEqual(@as(f32, 75), grown[1]);

    const widths = [_]f32{ 100, 300 };
    const shrink = [_]f32{ 1, 1 };
    var reduced = [_]f32{ 0, 0 };
    distributeShrink(&widths, &shrink, 200, &reduced);
    try std.testing.expectApproxEqAbs(@as(f32, 50), reduced[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), reduced[1], 0.001);
}

test "line collection includes gaps and admits oversized first item" {
    const mains = [_]f32{ 80, 80, 30 };
    var lines = [_]u16{ 99, 99, 99 };
    var starts = [_]u16{ 99, 99, 99 };
    var ends = [_]u16{ 99, 99, 99 };
    const count = collectLinesWithGap(&mains, 100, 5, false, &lines, &starts, &ends);
    try std.testing.expectEqual(@as(u16, 3), count);
    try std.testing.expectEqual(@as(u16, 0), lines[0]);
    try std.testing.expectEqual(@as(u16, 1), lines[1]);
    try std.testing.expectEqual(@as(u16, 2), lines[2]);
    try std.testing.expectEqual(@as(u16, 2), starts[2]);
    try std.testing.expectEqual(@as(u16, 3), ends[2]);
}

test "intrinsic min content gives each item its own contribution" {
    const mains = [_]f32{ 20, 80 };
    var lines = [_]u16{ 99, 99 };
    try std.testing.expectEqual(@as(u16, 2), collectLines(&mains, null, true, &lines, null, null));
    try std.testing.expectEqual(@as(u16, 1), lines[1]);
}
