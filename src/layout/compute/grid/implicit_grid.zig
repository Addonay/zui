//! Implicit grid sizing estimates from Taffy's `compute/grid/implicit_grid.rs`.

const geometry = @import("../../geometry.zig");
const grid_style = @import("../../style/grid.zig");
const tree = @import("../../tree/taffy_tree.zig");
const coordinates = @import("types/coordinates.zig");
const counts = @import("types/grid_track_counts.zig");

pub const ImplicitGrid = struct {
    rows: u16 = 0,
    columns: u16 = 0,
};

pub const GridSizeEstimate = struct {
    columns: counts.TrackCounts,
    rows: counts.TrackCounts,
};

pub const KnownChildPositions = struct {
    col_min: i16 = 0,
    col_max: i16 = 0,
    col_max_span: u16 = 0,
    row_min: i16 = 0,
    row_max: i16 = 0,
    row_max_span: u16 = 0,
};

fn line_min_max_span(line: geometry.Line(grid_style.GridPlacement), explicit_count: u16) struct { min: i16, max: i16, span: u16 } {
    const start = grid_style.into_origin_zero_placement_ignoring_named(line.start, explicit_count);
    const end = grid_style.into_origin_zero_placement_ignoring_named(line.end, explicit_count);
    const start_line: ?i16 = switch (start) {
        .line => |value| value,
        else => null,
    };
    const end_line: ?i16 = switch (end) {
        .line => |value| value,
        else => null,
    };
    const span = grid_style.line_indefinite_span(line);
    if (start_line) |start_value| {
        if (end_line) |end_value| return .{ .min = @min(start_value, end_value), .max = @max(start_value, end_value) + (if (start_value == end_value) @as(i16, 1) else 0), .span = 1 };
        return .{ .min = start_value, .max = start_value + @as(i16, @intCast(span)), .span = 1 };
    }
    if (end_line) |end_value| return .{ .min = end_value - @as(i16, @intCast(span)), .max = end_value, .span = 1 };
    return .{ .min = 0, .max = 0, .span = span };
}

/// Compute a conservative count estimate before auto-placement. Definite
/// negative lines contribute negative implicit tracks; spans contribute the
/// minimum positive track capacity required for the item.
pub fn compute_grid_size_estimate(explicit_col_count: u16, explicit_row_count: u16, children: []const tree.NodeId, tree_ref: *const tree.TaffyTree) GridSizeEstimate {
    const known = get_known_child_positions(children, tree_ref, explicit_col_count, explicit_row_count);
    const col_min = known.col_min;
    const col_max = known.col_max;
    const col_span = known.col_max_span;
    const row_min = known.row_min;
    const row_max = known.row_max;
    const row_span = known.row_max_span;
    const col_negative: u16 = if (col_min < 0) @intCast(-@as(i32, col_min)) else 0;
    const row_negative: u16 = if (row_min < 0) @intCast(-@as(i32, row_min)) else 0;
    var col_positive: u16 = if (col_max > @as(i16, @intCast(explicit_col_count))) @intCast(@as(i32, col_max) - explicit_col_count) else 0;
    var row_positive: u16 = if (row_max > @as(i16, @intCast(explicit_row_count))) @intCast(@as(i32, row_max) - explicit_row_count) else 0;
    if (@as(u32, col_negative) + explicit_col_count + col_positive < col_span) col_positive = col_span -| explicit_col_count -| col_negative;
    if (@as(u32, row_negative) + explicit_row_count + row_positive < row_span) row_positive = row_span -| explicit_row_count -| row_negative;
    return .{
        .columns = counts.TrackCounts.from_raw(col_negative, explicit_col_count, col_positive),
        .rows = counts.TrackCounts.from_raw(row_negative, explicit_row_count, row_positive),
    };
}

pub fn get_known_child_positions(children: []const tree.NodeId, tree_ref: *const tree.TaffyTree, explicit_col_count: u16, explicit_row_count: u16) KnownChildPositions {
    var result = KnownChildPositions{};
    for (children) |child_id| {
        const child = tree_ref.node_const(child_id) orelse continue;
        if (child.style.display == .none or child.style.position == .absolute) continue;
        const col = line_min_max_span(child.style.grid_column, explicit_col_count);
        const row = line_min_max_span(child.style.grid_row, explicit_row_count);
        result.col_min = @min(result.col_min, col.min);
        result.col_max = @max(result.col_max, col.max);
        result.col_max_span = @max(result.col_max_span, col.span);
        result.row_min = @min(result.row_min, row.min);
        result.row_max = @max(result.row_max, row.max);
        result.row_max_span = @max(result.row_max_span, row.span);
    }
    return result;
}

pub fn child_min_line_max_line_span(line: geometry.Line(grid_style.GridPlacement), explicit_count: u16) struct { min: i16, max: i16, span: u16 } {
    return line_min_max_span(line, explicit_count);
}

test "implicit grid estimates negative lines and spans" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .grid_column = .{ .start = .{ .line = -6 }, .end = .auto } });
    const estimate = compute_grid_size_estimate(4, 2, &[_]tree.NodeId{child}, &tree_ref);
    try testing.expectEqual(@as(u16, 1), estimate.columns.negative_implicit);
}
