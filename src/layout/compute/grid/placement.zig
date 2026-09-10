//! Grid item placement from Taffy's `compute/grid/placement.rs`.
//!
//! Placement is kept as its own stage. It first honors definite row and
//! column lines, then searches the remaining items with a sparse or dense
//! cursor according to `grid-auto-flow`. The occupancy matrix owns the
//! collision semantics, including negative implicit tracks and collision
//! jumps.

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/mod.zig");
const grid_style = @import("../../style/grid.zig");
const tree = @import("../../tree/taffy_tree.zig");
const coordinates = @import("types/coordinates.zig");
const counts = @import("types/grid_track_counts.zig");
const occupancy = @import("types/cell_occupancy.zig");

pub const PlacementCursor = struct {
    row: u16 = 0,
    column: u16 = 0,

    pub fn advance(self: *PlacementCursor, flow: grid_style.GridAutoFlow, columns: u16, rows: u16) void {
        if (flow == .column or flow == .column_dense) {
            self.row += 1;
            if (self.row >= rows) {
                self.row = 0;
                self.column += 1;
            }
        } else {
            self.column += 1;
            if (self.column >= columns) {
                self.column = 0;
                self.row += 1;
            }
        }
    }
};

pub const GridItemPlacement = struct {
    row: usize,
    column: usize,
    row_span: usize,
    column_span: usize,
};

fn advance_position(position: PlacementCursor, flow: grid_style.GridAutoFlow, columns: u16, rows: u16) PlacementCursor {
    var next = position;
    next.advance(flow, columns, rows);
    return next;
}

fn resolve_indefinite_grid_span(position: i16, span: u16) geometry.Line(coordinates.OriginZeroLine) {
    const start = coordinates.OriginZeroLine{ .value = position };
    return .{ .start = start, .end = .{ .value = position + @as(i16, @intCast(@max(span, 1))) } };
}

fn line_value(value: grid_style.GridPlacement, explicit_count: usize) ?i16 {
    return switch (value) {
        .line => |line| if (line == 0) null else if (line > 0) @intCast(@min(explicit_count, @as(usize, @intCast(line - 1)))) else @intCast(@max(@as(i32, 0), @as(i32, @intCast(explicit_count)) + line)),
        else => null,
    };
}

pub const AxisPlacement = struct {
    start: ?i16 = null,
    span: u16 = 1,
    definite: bool = false,
};

pub const ResolvedGridPlacement = struct {
    row: AxisPlacement,
    column: AxisPlacement,
    absolute: bool = false,
    excluded: bool = false,
};

fn normalize_line(value: i16, explicit_count: usize) i16 {
    if (value > 0) return @intCast(@as(usize, @intCast(value - 1)));
    return @intCast(@as(i32, @intCast(explicit_count)) + 1 + value);
}

fn resolve_named_placement(value: grid_style.GridPlacement, areas: ?grid_style.GridTemplateAreas, line_names: []const grid_style.GridTemplateLineNames, explicit_count: usize, axis: geometry.AbsoluteAxis) grid_style.GridPlacement {
    const named = switch (value) {
        .named_line => |line| line,
        else => return value,
    };
    if (named.name.len > 0) {
        var positions: [128]usize = std.mem.zeroes([128]usize);
        var position_count: usize = 0;
        for (line_names, 0..) |names, line_index| {
            for (names) |name| if (std.mem.eql(u8, name, named.name)) {
                if (position_count < positions.len) positions[position_count] = line_index;
                position_count += 1;
                break;
            };
        }
        if (position_count > 0) {
            const requested = if (named.index == 0) @as(i32, 1) else @as(i32, named.index);
            const position = if (requested > 0) @as(usize, @intCast(requested - 1)) else position_count -| @as(usize, @intCast(-requested));
            if (position < position_count) return .{ .line = @intCast(positions[position] + 1) };
        }
    }
    const suffix = if (std.mem.endsWith(u8, named.name, "-end")) "-end" else if (std.mem.endsWith(u8, named.name, "-start")) "-start" else return value;
    const base_name = named.name[0 .. named.name.len - suffix.len];
    if (areas) |area_template| for (area_template.areas) |area| if (std.mem.eql(u8, area.name, base_name)) {
        const line = if (axis == .horizontal) if (std.mem.eql(u8, suffix, "-end")) area.column_end else area.column_start else if (std.mem.eql(u8, suffix, "-end")) area.row_end else area.row_start;
        // Template-area bounds are stored in OriginZero line coordinates;
        // named CSS lines are one-based, so convert back before normalization.
        return .{ .line = @intCast(line + 1) };
    };
    const fallback = if (named.index > 0) @as(i32, @intCast(explicit_count)) + 1 + named.index else -(@as(i32, @intCast(explicit_count)) + 1 + named.index);
    return .{ .line = @intCast(@max(@as(i32, -32768), @min(@as(i32, 32767), fallback))) };
}

fn resolve_axis_placement(value: geometry.Line(grid_style.GridPlacement), explicit_count: usize, areas: ?grid_style.GridTemplateAreas, line_names: []const grid_style.GridTemplateLineNames, axis: geometry.AbsoluteAxis) AxisPlacement {
    const start_value = resolve_named_placement(value.start, areas, line_names, explicit_count, axis);
    const end_value = resolve_named_placement(value.end, areas, line_names, explicit_count, axis);
    const start_line = switch (start_value) {
        .line => |line| if (line != 0) normalize_line(line, explicit_count) else null,
        else => null,
    };
    const end_line = switch (end_value) {
        .line => |line| if (line != 0) normalize_line(line, explicit_count) else null,
        else => null,
    };
    const start_span = switch (start_value) {
        .span => |span| @max(@as(u16, 1), span),
        .named_span => |span| @max(@as(u16, 1), span.count),
        else => null,
    };
    const end_span = switch (end_value) {
        .span => |span| @max(@as(u16, 1), span),
        .named_span => |span| @max(@as(u16, 1), span.count),
        else => null,
    };
    if (start_line) |start| {
        if (end_line) |end| return .{ .start = @min(start, end), .span = @intCast(@max(@as(i16, 1), @abs(end - start))), .definite = true };
        return .{ .start = start, .span = end_span orelse start_span orelse 1, .definite = true };
    }
    if (end_line) |end| {
        const span = start_span orelse end_span orelse 1;
        return .{ .start = end - @as(i16, @intCast(span)), .span = span, .definite = true };
    }
    return .{ .span = start_span orelse end_span orelse 1, .definite = false };
}

fn span_value(value: geometry.Line(grid_style.GridPlacement)) u16 {
    return switch (value.start) {
        .span => |span| @max(@as(u16, 1), span),
        .named_span => |span| @max(@as(u16, 1), span.count),
        else => switch (value.end) {
            .span => |span| @max(@as(u16, 1), span),
            .named_span => |span| @max(@as(u16, 1), span.count),
            else => 1,
        },
    };
}

fn is_definite(value: geometry.Line(grid_style.GridPlacement)) bool {
    return grid_style.line_is_definite(value);
}

fn candidate_is_unoccupied(matrix: *const occupancy.CellOccupancyMatrix, candidate: GridItemPlacement) bool {
    const row = geometry.Line(coordinates.OriginZeroLine){ .start = .{ .value = @intCast(candidate.row) }, .end = .{ .value = @intCast(candidate.row + candidate.row_span) } };
    const column = geometry.Line(coordinates.OriginZeroLine){ .start = .{ .value = @intCast(candidate.column) }, .end = .{ .value = @intCast(candidate.column + candidate.column_span) } };
    return matrix.line_area_is_unoccupied(.horizontal, column, row);
}

fn record_grid_placement(matrix: *occupancy.CellOccupancyMatrix, candidate: GridItemPlacement, state: occupancy.CellOccupancyState) void {
    matrix.mark_area_as(
        .horizontal,
        .{ .start = .{ .value = @intCast(candidate.column) }, .end = .{ .value = @intCast(candidate.column + candidate.column_span) } },
        .{ .start = .{ .value = @intCast(candidate.row) }, .end = .{ .value = @intCast(candidate.row + candidate.row_span) } },
        state,
    );
}

/// Place the children of one grid container. The current grid entry point
/// pre-estimates enough rows and columns for ordinary in-flow items; this
/// stage also grows the occupancy matrix when a definite line reaches an
/// implicit edge, preserving the Taffy placement order.
pub fn place_grid_items(allocator: std.mem.Allocator, children: []const tree.NodeId, columns: usize, rows: usize, flow: grid_style.GridAutoFlow, tree_ref: *tree.TaffyTree, container_style: style.Style, output: *std.ArrayList(GridItemPlacement)) !void {
    return place_grid_items_with_counts(
        allocator,
        children,
        counts.TrackCounts.from_raw(0, @intCast(columns), 0),
        counts.TrackCounts.from_raw(0, @intCast(rows), 0),
        flow,
        tree_ref,
        container_style,
        output,
    );
}

/// Placement entry point used by the grid container once the implicit-grid
/// estimate has been computed. Keeping the complete counts here preserves
/// negative implicit tracks instead of flattening them into an explicit count.
pub fn place_grid_items_with_counts(allocator: std.mem.Allocator, children: []const tree.NodeId, column_counts: counts.TrackCounts, row_counts: counts.TrackCounts, flow: grid_style.GridAutoFlow, tree_ref: *tree.TaffyTree, container_style: style.Style, output: *std.ArrayList(GridItemPlacement)) !void {
    const columns = column_counts.len();
    const rows = row_counts.len();
    var matrix = occupancy.CellOccupancyMatrix.with_track_counts_using_allocator(
        allocator,
        column_counts,
        row_counts,
    );
    defer matrix.deinit();

    output.clearRetainingCapacity();
    try output.resize(allocator, children.len);
    for (output.items) |*item| item.* = .{ .row = 0, .column = 0, .row_span = 1, .column_span = 1 };
    var resolved = std.ArrayList(ResolvedGridPlacement).empty;
    defer resolved.deinit(allocator);
    for (children) |child_id| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        const row_placement = resolve_axis_placement(child.style.grid_row, row_counts.explicit, container_style.grid_template_areas, container_style.grid_template_row_names, .vertical);
        const column_placement = resolve_axis_placement(child.style.grid_column, column_counts.explicit, container_style.grid_template_areas, container_style.grid_template_column_names, .horizontal);
        try resolved.append(allocator, .{ .row = row_placement, .column = column_placement, .absolute = child.style.position == .absolute, .excluded = child.style.display == .none });
    }

    // Taffy places all fully definite items before any auto-placement pass;
    // this prevents source order from allowing an auto item to steal a cell
    // that a later definite item needs.
    for (children, 0..) |child_id, index| {
        const placement = resolved.items[index];
        if (placement.excluded) continue;
        if (placement.absolute) {
            output.items[index] = .{
                .row = if (placement.row.start) |value| line_to_track_index(value, row_counts.negative_implicit) else 0,
                .column = if (placement.column.start) |value| line_to_track_index(value, column_counts.negative_implicit) else 0,
                .row_span = if (placement.row.start == null) rows else placement.row.span,
                .column_span = if (placement.column.start == null) columns else placement.column.span,
            };
            continue;
        }
        if (placement.row.definite and placement.column.definite) {
            const definite = GridItemPlacement{
                .row = if (placement.row.start) |value| line_to_track_index(value, row_counts.negative_implicit) else 0,
                .column = if (placement.column.start) |value| line_to_track_index(value, column_counts.negative_implicit) else 0,
                .row_span = placement.row.span,
                .column_span = placement.column.span,
            };
            record_grid_placement(&matrix, definite, .definitely_placed);
            output.items[index] = definite;
        }
        _ = child_id;
    }

    var cursor = PlacementCursor{};
    for (children, 0..) |child_id, index| {
        _ = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        const item = resolved.items[index];
        if (item.excluded or item.absolute or (item.row.definite and item.column.definite)) continue;
        const row: ?usize = if (item.row.start) |value| line_to_track_index(value, row_counts.negative_implicit) else null;
        const column: ?usize = if (item.column.start) |value| line_to_track_index(value, column_counts.negative_implicit) else null;
        const row_span = item.row.span;
        const col_span = item.column.span;
        var chosen: ?GridItemPlacement = null;
        var probe = if (grid_style.is_dense(flow)) PlacementCursor{} else cursor;
        var attempts: usize = 0;
        while (attempts < children.len + columns * rows + 4) : (attempts += 1) {
            const candidate = GridItemPlacement{ .row = probe.row, .column = probe.column, .row_span = row_span, .column_span = col_span };
            const row_matches = !item.row.definite or row == null or candidate.row == row.?;
            const col_matches = !item.column.definite or column == null or candidate.column == column.?;
            if (candidate.row + candidate.row_span <= rows and candidate.column + candidate.column_span <= columns and row_matches and col_matches and candidate_is_unoccupied(&matrix, candidate)) {
                chosen = candidate;
                probe.advance(flow, @intCast(columns), @intCast(rows));
                if (!grid_style.is_dense(flow)) cursor = probe;
                break;
            }
            probe = advance_position(probe, flow, @intCast(columns), @intCast(rows));
            if ((flow == .row or flow == .row_dense) and probe.row >= rows) probe.row = @intCast(rows);
            if ((flow == .column or flow == .column_dense) and probe.column >= columns) probe.column = @intCast(columns);
        }
        const final = chosen orelse GridItemPlacement{ .row = @intCast(@max(rows, 1) - 1), .column = @intCast(@max(columns, 1) - 1), .row_span = row_span, .column_span = col_span };
        record_grid_placement(&matrix, final, .auto_placed);
        output.items[index] = final;
    }
}

fn line_to_track_index(line: i16, negative_implicit: u16) usize {
    return @intCast(@max(@as(i32, 0), @as(i32, line) + negative_implicit));
}

/// The following small helpers keep the names and boundaries of the Rust
/// placement implementation visible to later generic-tree work.
pub fn place_definite_grid_item(candidate: GridItemPlacement, matrix: *occupancy.CellOccupancyMatrix) bool {
    if (!candidate_is_unoccupied(matrix, candidate)) return false;
    record_grid_placement(matrix, candidate, .definitely_placed);
    return true;
}

pub fn place_definite_secondary_axis_item(candidate: GridItemPlacement, matrix: *occupancy.CellOccupancyMatrix) bool {
    return place_definite_grid_item(candidate, matrix);
}

pub fn place_indefinitely_positioned_item(candidate: GridItemPlacement, matrix: *occupancy.CellOccupancyMatrix) bool {
    if (!candidate_is_unoccupied(matrix, candidate)) return false;
    record_grid_placement(matrix, candidate, .auto_placed);
    return true;
}

pub fn clamp_span_to_limited_grid(span: geometry.Line(coordinates.OriginZeroLine)) geometry.Line(coordinates.OriginZeroLine) {
    return .{ .start = .{ .value = @max(coordinates.MIN_OZ_LINE, span.start.value) }, .end = .{ .value = @min(coordinates.MAX_OZ_LINE, span.end.value) } };
}

test "grid placement uses occupancy to avoid collisions" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const a = try tree_ref.new_leaf(.{});
    const b = try tree_ref.new_leaf(.{});
    var output = std.ArrayList(GridItemPlacement).empty;
    defer output.deinit(testing.allocator);
    try place_grid_items(testing.allocator, &[_]tree.NodeId{ a, b }, 2, 1, .row, &tree_ref, .{}, &output);
    try testing.expectEqual(@as(usize, 2), output.items.len);
    try testing.expect(output.items[0].column != output.items[1].column);
}

test "grid placement honors definite end lines and spans" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 3 } },
        .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
    });
    var output = std.ArrayList(GridItemPlacement).empty;
    defer output.deinit(testing.allocator);
    try place_grid_items(testing.allocator, &[_]tree.NodeId{child}, 3, 1, .row, &tree_ref, .{}, &output);
    try testing.expectEqual(@as(usize, 0), output.items[0].column);
    try testing.expectEqual(@as(usize, 2), output.items[0].column_span);
}

test "grid placement reserves definite items before auto items" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const auto_child = try tree_ref.new_leaf(.{});
    const fixed_child = try tree_ref.new_leaf(.{ .grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } }, .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } } });
    var output = std.ArrayList(GridItemPlacement).empty;
    defer output.deinit(testing.allocator);
    try place_grid_items(testing.allocator, &[_]tree.NodeId{ auto_child, fixed_child }, 2, 1, .row, &tree_ref, .{}, &output);
    try testing.expectEqual(@as(usize, 0), output.items[1].column);
    try testing.expectEqual(@as(usize, 1), output.items[0].column);
}

test "grid placement resolves template-area line names" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .grid_column = .{ .start = .{ .named_line = .{ .name = "header-start", .index = 1 } }, .end = .{ .named_line = .{ .name = "header-end", .index = 1 } } },
        .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
    });
    const areas = grid_style.GridTemplateAreas{ .areas = &[_]grid_style.GridTemplateArea{.{ .name = "header", .row_start = 0, .row_end = 1, .column_start = 0, .column_end = 2 }}, .row_count = 1, .column_count = 2 };
    var output = std.ArrayList(GridItemPlacement).empty;
    defer output.deinit(testing.allocator);
    try place_grid_items(testing.allocator, &[_]tree.NodeId{child}, 2, 1, .row, &tree_ref, .{ .grid_template_areas = areas }, &output);
    try testing.expectEqual(@as(usize, 0), output.items[0].column);
    try testing.expectEqual(@as(usize, 2), output.items[0].column_span);
}

test "grid placement resolves explicit template line names" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .grid_column = .{ .start = .{ .named_line = .{ .name = "foo", .index = 2 } }, .end = .auto } });
    const column_names = [_]grid_style.GridTemplateLineNames{
        &[_][]const u8{"foo"},
        &[_][]const u8{},
        &[_][]const u8{"foo"},
    };
    var output = std.ArrayList(GridItemPlacement).empty;
    defer output.deinit(testing.allocator);
    try place_grid_items(testing.allocator, &[_]tree.NodeId{child}, 3, 1, .row, &tree_ref, .{ .grid_template_column_names = &column_names }, &output);
    try testing.expectEqual(@as(usize, 2), output.items[0].column);
}
