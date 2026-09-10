//! CSS Grid container algorithm, ported from Taffy's `compute/grid/mod.rs`.
//!
//! The implementation keeps Taffy's three conceptual stages explicit:
//! placement, track sizing, and item alignment. Track templates are expanded
//! into owned working vectors, implicit tracks are appended when placement
//! requires them, and fractional tracks receive the remaining definite space.
//! Named-line resolution and detailed grid diagnostics remain represented by
//! their source-mapped types and are wired into the subsequent port pass.

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/mod.zig");
const grid_style = @import("../../style/grid.zig");
const grid_item_type = @import("types/grid_item.zig");
const grid_track_type = @import("types/grid_track.zig");
const coordinates = @import("types/coordinates.zig");
const tree = @import("../../tree/taffy_tree.zig");
const tree_layout = @import("../../tree/layout.zig");
const grid_counts = @import("types/grid_track_counts.zig");

pub const types = @import("types/mod.zig");
pub const alignment = @import("alignment.zig");
pub const explicit_grid = @import("explicit_grid.zig");
pub const implicit_grid = @import("implicit_grid.zig");
pub const placement = @import("placement.zig");
pub const track_sizing = @import("track_sizing.zig");
pub const util = @import("util/mod.zig");

pub const DetailedGridTracksInfo = struct {
    sizes: []const f32 = &.{},
    positions: []const geometry.Line(f32) = &.{},
    negative_implicit_tracks: u16 = 0,
    explicit_tracks: u16 = 0,
    positive_implicit_tracks: u16 = 0,
    empty_axis_line: ?f32 = null,
    line_names: []const []const []const u8 = &.{},

    pub fn names_for_line(self: DetailedGridTracksInfo, index: usize) []const []const u8 {
        return if (index < self.line_names.len) self.line_names[index] else &.{};
    }

    pub fn iter_line_names(self: DetailedGridTracksInfo, index: usize) []const []const u8 {
        return self.names_for_line(index);
    }

    pub fn positions_from_grid_track_layout(allocator: std.mem.Allocator, tracks: []const grid_track_type.GridTrack) ![]geometry.Line(f32) {
        var positions = std.ArrayList(geometry.Line(f32)).empty;
        for (tracks) |track| if (track.kind == .track and !track.is_collapsed) try positions.append(allocator, .{ .start = track.offset, .end = track.offset + track.base_size });
        return positions.toOwnedSlice(allocator);
    }

    pub fn from_grid_tracks_and_track_count(allocator: std.mem.Allocator, counts: grid_counts.TrackCounts, tracks: []const grid_track_type.GridTrack, line_names: []const []const []const u8) !DetailedGridTracksInfo {
        const positions = try positions_from_grid_track_layout(allocator, tracks);
        var sizes = try allocator.alloc(f32, positions.len);
        for (positions, 0..) |position, index| sizes[index] = position.end - position.start;
        return .{
            .sizes = sizes,
            .positions = positions,
            .negative_implicit_tracks = counts.negative_implicit,
            .explicit_tracks = counts.explicit,
            .positive_implicit_tracks = counts.positive_implicit,
            .empty_axis_line = if (positions.len == 0 and tracks.len > 0) tracks[0].offset else null,
            .line_names = line_names,
        };
    }

    pub fn resolve_absolute_grid_axis(self: DetailedGridTracksInfo, placement_value: geometry.Line(grid_style.GridPlacement), padding_start: f32, padding_end: f32, is_reversed: bool) geometry.Line(f32) {
        const counts = grid_counts.TrackCounts.from_raw(self.negative_implicit_tracks, self.explicit_tracks, self.positive_implicit_tracks);
        const resolved = grid_style.line_resolve_absolutely_positioned_grid_tracks(placement_value, self.explicit_tracks);
        const min_line = -@as(i16, @intCast(self.negative_implicit_tracks));
        const max_line = @as(i16, @intCast(self.explicit_tracks + self.positive_implicit_tracks));
        const start = if (resolved.start) |line| blk: {
            if (line >= min_line and line <= max_line) {
                const index = grid_track_index_for_line(line, counts);
                break :blk if (index < self.positions.len) (if (is_reversed) self.positions[index].end else self.positions[index].start) else (self.empty_axis_line orelse padding_start);
            }
            break :blk self.empty_axis_line orelse padding_start;
        } else if (is_reversed) padding_end else padding_start;
        const end = if (resolved.end) |line| blk: {
            if (line >= min_line and line <= max_line and line > min_line) {
                const index = grid_track_index_for_line(line - 1, counts);
                break :blk if (index < self.positions.len) (if (is_reversed) self.positions[index].start else self.positions[index].end) else (self.empty_axis_line orelse padding_end);
            }
            break :blk self.empty_axis_line orelse padding_end;
        } else if (is_reversed) padding_start else padding_end;
        return .{ .start = @min(start, end), .end = @max(start, end) };
    }

    pub fn write_track_list(self: DetailedGridTracksInfo, writer: anytype) !void {
        if (self.positions.len == 0) return writer.writeAll("none");
        for (self.positions, 0..) |position, index| {
            const names = self.names_for_line(index);
            if (names.len > 0) {
                try writer.writeAll("[");
                for (names, 0..) |name, name_index| {
                    if (name_index > 0) try writer.writeAll(" ");
                    try writer.writeAll(name);
                }
                try writer.writeAll("] ");
            }
            try writer.print("{d}px", .{position.end - position.start});
            if (index + 1 < self.positions.len) try writer.writeAll(" ");
        }
        const trailing = self.names_for_line(self.positions.len);
        if (trailing.len > 0) {
            try writer.writeAll(" [");
            for (trailing, 0..) |name, index| {
                if (index > 0) try writer.writeAll(" ");
                try writer.writeAll(name);
            }
            try writer.writeAll("]");
        }
    }

    pub fn to_track_list_string(self: DetailedGridTracksInfo) []const u8 {
        var output = std.ArrayList(u8).empty;
        self.write_track_list(output.writer(std.heap.page_allocator)) catch @panic("Taffy detailed grid string allocation failed");
        return output.toOwnedSlice(std.heap.page_allocator) catch @panic("Taffy detailed grid string allocation failed");
    }
};

pub const DetailedGridItemsInfo = struct {
    row_start: u16 = 1,
    row_end: u16 = 2,
    column_start: u16 = 1,
    column_end: u16 = 2,
};
pub const DetailedGridInfo = struct {
    rows: DetailedGridTracksInfo = .{},
    columns: DetailedGridTracksInfo = .{},
    items: []const DetailedGridItemsInfo = &.{},

    pub fn write_grid_template_rows(self: DetailedGridInfo, writer: anytype) !void {
        return self.rows.write_track_list(writer);
    }
    pub fn write_grid_template_columns(self: DetailedGridInfo, writer: anytype) !void {
        return self.columns.write_track_list(writer);
    }
    pub fn grid_template_rows(self: DetailedGridInfo) []const u8 {
        return self.rows.to_track_list_string();
    }
    pub fn grid_template_columns(self: DetailedGridInfo) []const u8 {
        return self.columns.to_track_list_string();
    }

    pub fn item_grid_area(self: DetailedGridInfo, index: usize) ?struct { location: geometry.Point(f32), size: geometry.Size(f32) } {
        const item = if (index < self.items.len) self.items[index] else return null;
        const column_start = if (item.column_start > 0 and item.column_start - 1 < self.columns.positions.len) self.columns.positions[item.column_start - 1] else return null;
        const column_end = if (item.column_end > 1 and item.column_end - 2 < self.columns.positions.len) self.columns.positions[item.column_end - 2] else return null;
        const row_start = if (item.row_start > 0 and item.row_start - 1 < self.rows.positions.len) self.rows.positions[item.row_start - 1] else return null;
        const row_end = if (item.row_end > 1 and item.row_end - 2 < self.rows.positions.len) self.rows.positions[item.row_end - 2] else return null;
        return .{ .location = .{ .x = @min(column_start.start, column_end.start), .y = row_start.start }, .size = .{ .width = @max(column_start.end, column_end.end) - @min(column_start.start, column_end.start), .height = row_end.end - row_start.start } };
    }

    pub fn resolve_absolute_grid_area(self: DetailedGridInfo, grid_row: geometry.Line(grid_style.GridPlacement), grid_column: geometry.Line(grid_style.GridPlacement), direction: style.Direction, padding_box: geometry.Rect(f32)) geometry.Rect(f32) {
        const columns = self.columns.resolve_absolute_grid_axis(grid_column, padding_box.left, padding_box.right, direction == .rtl);
        const rows = self.rows.resolve_absolute_grid_axis(grid_row, padding_box.top, padding_box.bottom, false);
        return .{ .left = columns.start, .right = columns.end, .top = rows.start, .bottom = rows.end };
    }
};

fn grid_track_index_for_line(line: i16, counts: grid_counts.TrackCounts) usize {
    const index = @as(i32, line) + counts.negative_implicit;
    return if (index < 0) 0 else @intCast(index);
}

const Track = track_sizing.Track;

const Placement = placement.GridItemPlacement;

/// Taffy's grid entry point. Children are measured by the dispatcher before
/// entering here, just as `LayoutPartialTree::compute_child_layout` feeds the
/// Rust algorithm's intrinsic contribution passes.
pub fn compute_grid_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, inputs: tree_layout.LayoutInput) !tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    const node_style = node_data.style;
    const parent_width = inputs.parent_size.width orelse inputs.available_space.width.into_option() orelse 0;
    const padding = resolve_edges(node_style.padding, parent_width);
    const border = resolve_edges(node_style.border, parent_width);
    const inset = add_edges(padding, border);

    var columns = std.ArrayList(Track).empty;
    defer columns.deinit(tree_ref.allocator);
    var rows = std.ArrayList(Track).empty;
    defer rows.deinit(tree_ref.allocator);
    const styled_width = node_style.size.width.resolve(parent_width);
    const styled_height = node_style.size.height.resolve(inputs.parent_size.height);
    const styled_width_adjusted = if (node_style.box_sizing == .content_box) if (styled_width) |value| value + inset.horizontal_axis_sum() else null else styled_width;
    const styled_height_adjusted = if (node_style.box_sizing == .content_box) if (styled_height) |value| value + inset.vertical_axis_sum() else null else styled_height;
    const available_width_for_template = inputs.known_dimensions.width orelse styled_width_adjusted orelse inputs.available_space.width.into_option();
    const available_height_for_template = inputs.known_dimensions.height orelse styled_height_adjusted orelse inputs.available_space.height.into_option();
    const explicit_columns = explicit_grid.compute_explicit_grid_size_in_axis(node_style.grid_template_columns, available_width_for_template, .max_repetitions_that_do_not_overflow, gap_value(node_style.gap.width, parent_width));
    const explicit_rows = explicit_grid.compute_explicit_grid_size_in_axis(node_style.grid_template_rows, available_height_for_template, .max_repetitions_that_do_not_overflow, gap_value(node_style.gap.height, parent_width));
    try expand_template(tree_ref.allocator, &columns, node_style.grid_template_columns, explicit_columns.auto_repetitions);
    try expand_template(tree_ref.allocator, &rows, node_style.grid_template_rows, explicit_rows.auto_repetitions);
    if (node_style.grid_template_areas) |areas| {
        while (columns.items.len < areas.column_count) try columns.append(tree_ref.allocator, .{});
        while (rows.items.len < areas.row_count) try rows.append(tree_ref.allocator, .{});
    }

    const estimate = implicit_grid.compute_grid_size_estimate(explicit_columns.track_count, explicit_rows.track_count, node_data.children.items, tree_ref);
    try prepend_implicit_tracks(tree_ref.allocator, &columns, estimate.columns.negative_implicit, node_style.grid_auto_columns);
    try prepend_implicit_tracks(tree_ref.allocator, &rows, estimate.rows.negative_implicit, node_style.grid_auto_rows);
    try append_auto_tracks(tree_ref.allocator, &columns, estimate.columns.len(), node_style.grid_auto_columns);
    try append_auto_tracks(tree_ref.allocator, &rows, estimate.rows.len(), node_style.grid_auto_rows);
    if (columns.items.len == 0) try append_auto_track(tree_ref.allocator, &columns, node_style.grid_auto_columns, 0);
    if (rows.items.len == 0) try append_auto_track(tree_ref.allocator, &rows, node_style.grid_auto_rows, 0);

    const children = node_data.children.items;
    if (node_style.grid_auto_flow == .column or node_style.grid_auto_flow == .column_dense) {
        while (columns.items.len * rows.items.len < children.len) try append_auto_track(tree_ref.allocator, &columns, node_style.grid_auto_columns, columns.items.len);
    } else {
        while (columns.items.len * rows.items.len < children.len) try append_auto_track(tree_ref.allocator, &rows, node_style.grid_auto_rows, rows.items.len);
    }

    var placements = std.ArrayList(Placement).empty;
    defer placements.deinit(tree_ref.allocator);
    const placement_column_counts = types.grid_track_counts.TrackCounts.from_raw(
        estimate.columns.negative_implicit,
        explicit_columns.track_count,
        @intCast(columns.items.len -| estimate.columns.negative_implicit -| explicit_columns.track_count),
    );
    const placement_row_counts = types.grid_track_counts.TrackCounts.from_raw(
        estimate.rows.negative_implicit,
        explicit_rows.track_count,
        @intCast(rows.items.len -| estimate.rows.negative_implicit -| explicit_rows.track_count),
    );
    try placement.place_grid_items_with_counts(tree_ref.allocator, children, placement_column_counts, placement_row_counts, node_style.grid_auto_flow, tree_ref, node_style, &placements);
    collapse_empty_auto_fit_tracks(columns.items, children, placements.items, true, tree_ref);
    collapse_empty_auto_fit_tracks(rows.items, children, placements.items, false, tree_ref);

    const available_width = inputs.known_dimensions.width orelse styled_width_adjusted orelse inputs.available_space.width.into_option();
    const available_height = inputs.known_dimensions.height orelse styled_height_adjusted orelse inputs.available_space.height.into_option();
    // Track sizing (and the alignment free-space math below) runs against
    // the CONTENT box, like Taffy's inner_available_space: fr tracks and
    // stretch distribution must not see padding/border. The outer size and
    // item placement add the inset back explicitly.
    const inner_width = if (available_width) |w| @max(0, w - inset.horizontal_axis_sum()) else null;
    const inner_height = if (available_height) |h| @max(0, h - inset.vertical_axis_sum()) else null;
    const column_width = try size_tracks(tree_ref.allocator, &columns, inner_width, gap_value(node_style.gap.width, parent_width), children, placements.items, true, tree_ref);
    const row_height = try size_tracks(tree_ref.allocator, &rows, inner_height, gap_value(node_style.gap.height, parent_width), children, placements.items, false, tree_ref);

    const content_size = geometry.Size(f32){ .width = column_width, .height = row_height };
    const outer = geometry.Size(f32){
        .width = style.dimension.clamp_resolved_size(inputs.known_dimensions.width orelse available_width orelse content_size.width + inset.horizontal_axis_sum(), node_style.min_size.width, node_style.max_size.width, parent_width),
        .height = style.dimension.clamp_resolved_size(inputs.known_dimensions.height orelse available_height orelse content_size.height + inset.vertical_axis_sum(), node_style.min_size.height, node_style.max_size.height, inputs.parent_size.height orelse content_size.height),
    };
    const column_alignment = alignment.align_track_sizes(inner_width, columns.items, gap_value(node_style.gap.width, parent_width), node_style.justify_content orelse style.alignment.AlignContent.stretch);
    const row_alignment = alignment.align_track_sizes(inner_height, rows.items, gap_value(node_style.gap.height, parent_width), node_style.align_content orelse style.alignment.AlignContent.stretch);
    try place_children(tree_ref, children, placements.items, columns.items, rows.items, column_alignment.gap, row_alignment.gap, column_alignment.start, row_alignment.start, inset, node_style);
    node_data.unrounded_layout.size = outer;
    node_data.unrounded_layout.padding = padding;
    node_data.unrounded_layout.border = border;
    node_data.final_layout = node_data.unrounded_layout;
    return tree_layout.LayoutOutput.from_outer_size(outer);
}

fn expand_template(allocator: std.mem.Allocator, output: *std.ArrayList(Track), template: []const grid_style.GridTemplateComponent, auto_repetition_count: u16) !void {
    for (template) |component| switch (component) {
        .single => |track| try append_track_marked(allocator, output, track, false),
        .repeat => |repetition| switch (repetition.count) {
            .count => |count| for (0..count) |_| for (repetition.tracks) |track| try append_track_marked(allocator, output, track, false),
            .auto_fit => for (0..@max(auto_repetition_count, 1)) |_| for (repetition.tracks) |track| try append_track_marked(allocator, output, track, true),
            .auto_fill => for (0..@max(auto_repetition_count, 1)) |_| for (repetition.tracks) |track| try append_track_marked(allocator, output, track, false),
        },
    };
}

fn append_track(allocator: std.mem.Allocator, output: *std.ArrayList(Track), function: grid_style.TrackSizingFunction) !void {
    return append_track_marked(allocator, output, function, false);
}

fn append_track_marked(allocator: std.mem.Allocator, output: *std.ArrayList(Track), function: grid_style.TrackSizingFunction, is_auto_fit: bool) !void {
    const min_value = switch (function.min.value) {
        .length => |value| @max(0, value),
        else => 0,
    };
    const max_value: ?f32 = switch (function.max.value) {
        .length => |value| @max(0, value),
        .percent => null,
        .fr => null,
        else => null,
    };
    const fr = switch (function.max.value) {
        .fr => |value| @max(0, value),
        else => 0,
    };
    try output.append(allocator, .{ .min = min_value, .max = max_value, .fr = fr, .size = min_value, .min_sizing = function.min, .max_sizing = function.max, .is_auto_fit = is_auto_fit });
}

fn append_auto_track(allocator: std.mem.Allocator, output: *std.ArrayList(Track), auto_tracks: []const grid_style.TrackSizingFunction, index: usize) !void {
    const function = if (auto_tracks.len == 0) grid_style.TrackSizingFunction.auto else auto_tracks[index % auto_tracks.len];
    try append_track(allocator, output, function);
}

fn append_auto_tracks(allocator: std.mem.Allocator, output: *std.ArrayList(Track), target_len: usize, auto_tracks: []const grid_style.TrackSizingFunction) !void {
    while (output.items.len < target_len) try append_auto_track(allocator, output, auto_tracks, output.items.len);
}

fn prepend_implicit_tracks(allocator: std.mem.Allocator, output: *std.ArrayList(Track), count: u16, auto_tracks: []const grid_style.TrackSizingFunction) !void {
    if (count == 0) return;
    var prefix = std.ArrayList(Track).empty;
    defer prefix.deinit(allocator);
    const auto_count = if (auto_tracks.len == 0) @as(usize, 1) else auto_tracks.len;
    const offset = if (auto_tracks.len == 0) 0 else auto_tracks.len - (@as(usize, count) % auto_tracks.len);
    for (0..count) |index| {
        const function = if (auto_tracks.len == 0) grid_style.TrackSizingFunction.auto else auto_tracks[(offset + index) % auto_count];
        try append_track(allocator, &prefix, function);
    }
    try prefix.appendSlice(allocator, output.items);
    output.clearRetainingCapacity();
    try output.appendSlice(allocator, prefix.items);
}

fn collapse_empty_auto_fit_tracks(tracks: []Track, children: []const tree.NodeId, placements: []const Placement, horizontal: bool, tree_ref: *tree.TaffyTree) void {
    if (tracks.len == 0) return;
    var occupied = std.heap.page_allocator.alloc(bool, tracks.len) catch @panic("Taffy auto-fit occupancy allocation failed");
    defer std.heap.page_allocator.free(occupied);
    @memset(occupied, false);
    for (children, placements) |child_id, placement_value| {
        const child = tree_ref.node(child_id) orelse continue;
        if (child.style.display == .none or child.style.position == .absolute) continue;
        const start = if (horizontal) placement_value.column else placement_value.row;
        const span = if (horizontal) placement_value.column_span else placement_value.row_span;
        const bounded_start = @min(start, occupied.len);
        const bounded_end = @min(start + span, occupied.len);
        for (occupied[bounded_start..bounded_end]) |*value| value.* = true;
    }
    for (tracks, 0..) |*track, index| {
        if (track.is_auto_fit and !occupied[index]) {
            track.is_collapsed = true;
            track.min = 0;
            track.max = 0;
            track.fr = 0;
            track.size = 0;
        }
    }
}

fn place_items(allocator: std.mem.Allocator, children: []const tree.NodeId, columns: usize, rows: usize, flow: grid_style.GridAutoFlow, tree_ref: *tree.TaffyTree, output: *std.ArrayList(Placement)) !void {
    _ = allocator;
    for (children) |child_id| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        const row = explicit_line(child.style.grid_row.start, rows);
        const column = explicit_line(child.style.grid_column.start, columns);
        const row_span = placement_span(child.style.grid_row);
        const column_span = placement_span(child.style.grid_column);
        var placement_value = Placement{ .row = row orelse 0, .column = column orelse 0, .row_span = row_span, .column_span = column_span };
        if (row == null or column == null) {
            var cursor: usize = 0;
            while (true) : (cursor += 1) {
                const candidate = if (flow == .column or flow == .column_dense)
                    Placement{ .row = cursor % rows, .column = cursor / rows, .row_span = row_span, .column_span = column_span }
                else
                    Placement{ .row = cursor / columns, .column = cursor % columns, .row_span = row_span, .column_span = column_span };
                if (candidate.row < rows and candidate.column < columns and (row == null or row.? == candidate.row) and (column == null or column.? == candidate.column) and !collides(output.items, candidate)) {
                    placement_value = candidate;
                    break;
                }
                if (cursor > rows * columns + children.len + 1) break;
            }
        }
        try output.append(tree_ref.allocator, placement_value);
    }
}

fn explicit_line(value: grid_style.GridPlacement, count: usize) ?usize {
    return switch (value) {
        .line => |line| if (line > 0) @min(count - 1, @as(usize, @intCast(line - 1))) else if (line < 0) @min(count - 1, @as(usize, @intCast(@as(i16, @intCast(count)) + line))) else null,
        else => null,
    };
}

fn placement_span(value: geometry.Line(grid_style.GridPlacement)) usize {
    return switch (value.end) {
        .span => |span| @max(@as(usize, 1), span),
        else => switch (value.start) {
            .span => |span| @max(@as(usize, 1), span),
            else => 1,
        },
    };
}

fn collides(existing: []const Placement, candidate: Placement) bool {
    for (existing) |other| {
        if (candidate.column < other.column + other.column_span and candidate.column + candidate.column_span > other.column and candidate.row < other.row + other.row_span and candidate.row + candidate.row_span > other.row) return true;
    }
    return false;
}

fn size_tracks(allocator: std.mem.Allocator, tracks: *std.ArrayList(Track), available_space: ?f32, gap: f32, children: []const tree.NodeId, placements: []const Placement, horizontal: bool, tree_ref: *tree.TaffyTree) !f32 {
    // Keep the public grid path's compact Track records for alignment and
    // diagnostics, but run sizing through the alternating GridTrack vector
    // used by Taffy's real track-sizing algorithm. The leading/trailing
    // gutter records are important: item line indexes point at lines, not at
    // the compact list of only content tracks.
    var phase_tracks = std.ArrayList(grid_track_type.GridTrack).empty;
    defer phase_tracks.deinit(allocator);
    try phase_tracks.append(allocator, grid_track_type.GridTrack.gutter(style.dimension.LengthPercentage.length(gap)));
    for (tracks.items) |track| {
        var phase_track = grid_track_type.GridTrack.new(track.min_sizing, track.max_sizing);
        if (track.is_collapsed) phase_track.collapse();
        try phase_tracks.append(allocator, phase_track);
        try phase_tracks.append(allocator, grid_track_type.GridTrack.gutter(style.dimension.LengthPercentage.length(gap)));
    }

    var grid_items = std.ArrayList(grid_item_type.GridItem).empty;
    defer grid_items.deinit(allocator);
    for (children, placements) |child_id, placement_value| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        if (child.style.display == .none) continue;
        // Absolutely positioned children are laid out against the resolved
        // grid area later and never contribute intrinsic track sizes.
        if (child.style.position == .absolute) continue;
        const row = geometry.Line(coordinates.OriginZeroLine){
            .start = .{ .value = @intCast(placement_value.row) },
            .end = .{ .value = @intCast(placement_value.row + placement_value.row_span) },
        };
        const column = geometry.Line(coordinates.OriginZeroLine){
            .start = .{ .value = @intCast(placement_value.column) },
            .end = .{ .value = @intCast(placement_value.column + placement_value.column_span) },
        };
        var item = grid_item_type.GridItem.new_with_placement_style_and_order(
            child_id,
            column,
            row,
            child.style,
            child.style.align_items orelse style.alignment.AlignItems.stretch,
            child.style.justify_items orelse style.alignment.AlignItems.stretch,
            @intCast(grid_items.items.len),
        );
        item.column_indexes = .{ .start = @intCast(placement_value.column * 2), .end = @intCast((placement_value.column + placement_value.column_span) * 2) };
        item.row_indexes = .{ .start = @intCast(placement_value.row * 2), .end = @intCast((placement_value.row + placement_value.row_span) * 2) };
        const intrinsic_output = try tree_ref.compute_child_layout(child_id, .{
            .run_mode = .compute_size,
            .sizing_mode = .inherent_size,
            .axis = if (horizontal) .horizontal else .vertical,
            .known_dimensions = .{ .width = null, .height = null },
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = .{ .width = available_space, .height = null },
            .available_space = .{ .width = .max_content, .height = .max_content },
            .vertical_margins_are_collapsible = .{ .start = false, .end = false },
        });
        const measured = if (horizontal) intrinsic_output.size.width else intrinsic_output.size.height;
        if (horizontal) {
            item.minimum_contribution_cache.width = measured;
            item.min_content_contribution_cache.width = measured;
            item.max_content_contribution_cache.width = measured;
        } else {
            item.minimum_contribution_cache.height = measured;
            item.min_content_contribution_cache.height = measured;
            item.max_content_contribution_cache.height = measured;
        }
        try grid_items.append(allocator, item);
    }
    const constraint: style.available_space.AvailableSpace = if (available_space) |value| .{ .definite = value } else .max_content;
    const total = track_sizing.grid_track_sizing_algorithm(phase_tracks.items, grid_items.items, .{
        .axis = if (horizontal) .inline_axis else .block,
        .available_space = constraint,
        .percentage_basis = available_space,
        .stretch_auto_tracks = false,
    });
    for (tracks.items, 0..) |*track, index| track.size = phase_tracks.items[index * 2 + 1].base_size;
    return total;
}

fn track_total(tracks: []const Track, gap: f32) f32 {
    var total = gap * @as(f32, @floatFromInt(if (tracks.len > 1) tracks.len - 1 else 0));
    for (tracks) |track| total += track.size;
    return total;
}

fn place_children(tree_ref: *tree.TaffyTree, children: []const tree.NodeId, placements: []const Placement, columns: []const Track, rows: []const Track, gap_col: f32, gap_row: f32, column_offset: f32, row_offset: f32, inset: geometry.Rect(f32), container: style.Style) !void {
    for (children, placements) |child_id, placement_value| {
        const child = tree_ref.node(child_id) orelse continue;
        if (child.style.display == .none) continue;
        const col_end = @min(columns.len, placement_value.column + placement_value.column_span);
        const row_end = @min(rows.len, placement_value.row + placement_value.row_span);
        const x = inset.left + column_offset + preceding_track_extent(columns, placement_value.column, gap_col);
        const y = inset.top + row_offset + preceding_track_extent(rows, placement_value.row, gap_row);
        const width = track_area_extent(columns, placement_value.column, col_end, gap_col);
        const height = track_area_extent(rows, placement_value.row, row_end, gap_row);
        const horizontal_margin = geometry.Line(?f32){ .start = child.style.margin.left.resolve(width), .end = child.style.margin.right.resolve(width) };
        const vertical_margin = geometry.Line(?f32){ .start = child.style.margin.top.resolve(width), .end = child.style.margin.bottom.resolve(width) };
        const horizontal_alignment = child.style.justify_self orelse container.justify_items orelse style.alignment.AlignItems.stretch;
        const vertical_alignment = child.style.align_self orelse container.align_items orelse style.alignment.AlignItems.stretch;
        const raw_width = child.style.size.width.resolve(width) orelse if (horizontal_alignment.keyword == .stretch and horizontal_margin.start != null and horizontal_margin.end != null) @max(0, width - horizontal_margin.start.? - horizontal_margin.end.?) else child.unrounded_layout.size.width;
        const raw_height = child.style.size.height.resolve(height) orelse if (vertical_alignment.keyword == .stretch and vertical_margin.start != null and vertical_margin.end != null) @max(0, height - vertical_margin.start.? - vertical_margin.end.?) else child.unrounded_layout.size.height;
        // Grid items clamp to min/max like every other box (Taffy resolves
        // min/max against the grid area): a min-width 60 child in a fixed
        // 40 track lays out at 60, not 40.
        const child_width = style.dimension.clamp_resolved_size(raw_width, child.style.min_size.width, child.style.max_size.width, width);
        const child_height = style.dimension.clamp_resolved_size(raw_height, child.style.min_size.height, child.style.max_size.height, height);
        // Track sizing establishes the containing block for the item. Run the
        // child dispatcher with those resolved outer dimensions so percentage
        // descendants and nested flex/grid containers see the grid area rather
        // than the grid container's preliminary available space.
        _ = try tree_ref.compute_child_layout(child_id, .{
            .run_mode = .perform_layout,
            .sizing_mode = .inherent_size,
            .axis = .both,
            .known_dimensions = .{ .width = child_width, .height = child_height },
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = .{ .width = width, .height = height },
            .available_space = .{ .width = .{ .definite = width }, .height = .{ .definite = height } },
            .vertical_margins_are_collapsible = .{ .start = false, .end = false },
        });
        const positioned_x = alignment.align_item_within_area(.{ .start = x, .end = x + width }, horizontal_alignment, child_width, child.style.position, .{ .start = child.style.inset.left.resolve(width), .end = child.style.inset.right.resolve(width) }, horizontal_margin, 0, container.direction);
        const positioned_y = alignment.align_item_within_area(.{ .start = y, .end = y + height }, vertical_alignment, child_height, child.style.position, .{ .start = child.style.inset.top.resolve(height), .end = child.style.inset.bottom.resolve(height) }, vertical_margin, 0, .ltr);
        child.unrounded_layout.location = .{ .x = positioned_x.start, .y = positioned_y.start };
        child.unrounded_layout.size = .{ .width = child_width, .height = child_height };
        child.final_layout = child.unrounded_layout;
    }
}

fn preceding_track_extent(tracks: []const Track, end: usize, gap: f32) f32 {
    // Sizes of the active tracks before `end`, plus one gap per preceding
    // active track: track `end` sits AFTER the gap that follows track
    // `end - 1`. (The old loop only added gaps between tracks inside the
    // prefix, dropping the gap before track `end` itself — a 40px track
    // with a 10px gap put the next column at x=40 instead of x=50.)
    // Collapsed (auto-fit empty) tracks vanish entirely, size and gap.
    var result: f32 = 0;
    var active: usize = 0;
    const bounded = @min(end, tracks.len);
    for (tracks[0..bounded]) |track| {
        if (track.is_collapsed) continue;
        result += track.size;
        active += 1;
    }
    if (active > 0 and end < tracks.len) {
        result += gap * @as(f32, @floatFromInt(active));
    } else if (active > 1) {
        // Past-the-end fallback (should not happen: placements are bounded
        // by the track count): count only gaps strictly inside the prefix.
        result += gap * @as(f32, @floatFromInt(active - 1));
    }
    return result;
}

fn track_area_extent(tracks: []const Track, start: usize, end: usize, gap: f32) f32 {
    var result: f32 = 0;
    var active: usize = 0;
    const bounded_start = @min(start, tracks.len);
    const bounded_end = @min(end, tracks.len);
    if (bounded_start >= bounded_end) return 0;
    for (tracks[bounded_start..bounded_end]) |track| {
        if (track.is_collapsed) continue;
        if (active > 0) result += gap;
        result += track.size;
        active += 1;
    }
    return result;
}

fn resolve_edges(value: geometry.Rect(style.dimension.LengthPercentage), basis: f32) geometry.Rect(f32) {
    return .{ .left = value.left.resolve(basis), .right = value.right.resolve(basis), .top = value.top.resolve(basis), .bottom = value.bottom.resolve(basis) };
}

fn add_edges(a: geometry.Rect(f32), b: geometry.Rect(f32)) geometry.Rect(f32) {
    return .{ .left = a.left + b.left, .right = a.right + b.right, .top = a.top + b.top, .bottom = a.bottom + b.bottom };
}
fn gap_value(value: style.dimension.LengthPercentage, basis: f32) f32 {
    return @max(0, value.resolve(basis));
}

test {
    _ = @import("alignment.zig");
    _ = @import("explicit_grid.zig");
    _ = @import("implicit_grid.zig");
    _ = @import("placement.zig");
    _ = @import("track_sizing.zig");
    _ = @import("types/mod.zig");
}

test "grid track alignment distributes inline free space" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const columns = [_]grid_style.GridTemplateComponent{.{ .single = grid_style.TrackSizingFunction.from_length(20) }};
    const rows = [_]grid_style.GridTemplateComponent{.{ .single = grid_style.TrackSizingFunction.from_length(10) }};
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
        .justify_content = style.alignment.AlignContent.center,
    }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).location.x);
}

test "grid auto rows size implicit tracks from grid-auto-rows" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const auto_rows = [_]grid_style.TrackSizingFunction{grid_style.TrackSizingFunction.from_length(20)};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_auto_rows = &auto_rows }, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(second)).location.y);
}

test "grid absolute children use their resolved grid area" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .position = .absolute,
        .inset = .{ .left = .length(5), .right = .auto(), .top = .length(7), .bottom = .auto() },
        .size = .{ .width = .length(20), .height = .length(10) },
        .grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 3 } },
        .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
    });
    const columns = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_length(40) },
        .{ .single = grid_style.TrackSizingFunction.from_length(40) },
    };
    const rows = [_]grid_style.GridTemplateComponent{.{ .single = grid_style.TrackSizingFunction.from_length(30) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    const result = try tree_ref.layout_of(child);
    try testing.expectEqual(@as(f32, 5), result.location.x);
    try testing.expectEqual(@as(f32, 7), result.location.y);
}

test "grid preserves a negative implicit column during placement" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .size = .{ .width = .length(10), .height = .length(10) },
        .grid_column = .{ .start = .{ .line = -4 }, .end = .auto },
        .grid_row = .{ .start = .{ .line = 1 }, .end = .auto },
    });
    const columns = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_length(20) },
        .{ .single = grid_style.TrackSizingFunction.from_length(20) },
    };
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(child)).location.x);
}

test "grid child layout receives resolved area for percentage descendants" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .{ .value = .{ .percent = 1 } }, .height = .length(10) } });
    const child = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .{ .value = .{ .percent = 0.5 } }, .height = .length(20) } }, &[_]tree.NodeId{grandchild});
    const columns = [_]grid_style.GridTemplateComponent{.{ .single = grid_style.TrackSizingFunction.from_length(80) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(grandchild)).size.width);
}

test "detailed grid tracks resolve absolute grid areas" {
    const testing = std.testing;
    var tracks = [_]types.grid_track.GridTrack{
        types.grid_track.GridTrack.gutter(.zero()),
        types.grid_track.GridTrack.new(.length(20), .length(20)),
        types.grid_track.GridTrack.gutter(.zero()),
        types.grid_track.GridTrack.new(.length(30), .length(30)),
        types.grid_track.GridTrack.gutter(.zero()),
    };
    tracks[1].offset = 0;
    tracks[1].base_size = 20;
    tracks[3].offset = 20;
    tracks[3].base_size = 30;
    const info = try DetailedGridTracksInfo.from_grid_tracks_and_track_count(
        testing.allocator,
        types.grid_track_counts.TrackCounts.from_raw(0, 2, 0),
        &tracks,
        &[_][]const []const u8{ &.{}, &.{}, &.{} },
    );
    defer testing.allocator.free(info.positions);
    defer testing.allocator.free(info.sizes);
    const area = info.resolve_absolute_grid_axis(.{ .start = .{ .line = 1 }, .end = .{ .line = 3 } }, 0, 50, false);
    try testing.expectEqual(@as(f32, 0), area.start);
    try testing.expectEqual(@as(f32, 50), area.end);
}

test "grid excludes display-none children from placement" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const hidden = try tree_ref.new_leaf(.{ .display = .none, .size = .{ .width = .length(90), .height = .length(10) } });
    const visible = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .grid }, &[_]tree.NodeId{ hidden, visible });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(visible)).location.x);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(hidden)).size.width);
}

test "grid auto-fit collapses tracks with no placed item" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{});
    var tracks = [_]Track{
        .{ .min = 20, .size = 20, .is_auto_fit = true },
        .{ .min = 20, .size = 20, .is_auto_fit = true },
    };
    const placements = [_]Placement{.{ .row = 0, .column = 0, .row_span = 1, .column_span = 1 }};
    collapse_empty_auto_fit_tracks(&tracks, &[_]tree.NodeId{child}, &placements, true, &tree_ref);
    try testing.expect(!tracks[0].is_collapsed);
    try testing.expect(tracks[1].is_collapsed);
    try testing.expectEqual(@as(?f32, 0), tracks[1].max);
}

test "grid gap offsets the second column" {
    // Oracle (vendored Taffy 0.14): tracks 40px + 20px with a 10px gap put
    // the second column at x=50, not x=40.
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .size = .{ .width = .length(40), .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const columns = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_length(40) },
        .{ .single = grid_style.TrackSizingFunction.from_length(20) },
    };
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .grid_template_columns = &columns,
        .gap = .{ .width = style.dimension.LengthPercentage.length(10), .height = style.dimension.LengthPercentage.length(0) },
    }, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(first)).location.x);
    try testing.expectEqual(@as(f32, 50), (try tree_ref.layout_of(second)).location.x);
}

test "grid fr track subtracts container padding" {
    // Oracle: 100px border-box grid with 10px horizontal padding and one
    // 1fr track gives the child 80px, not 100px.
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{});
    const columns = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_fr(1) },
    };
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .size = .{ .width = .length(100), .height = .length(20) },
        .padding = .{
            .left = style.dimension.LengthPercentage.length(10),
            .right = style.dimension.LengthPercentage.length(10),
            .top = style.dimension.LengthPercentage.length(0),
            .bottom = style.dimension.LengthPercentage.length(0),
        },
        .grid_template_columns = &columns,
    }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 80), (try tree_ref.layout_of(child)).size.width);
}

test "grid child min-width clamps a smaller fixed track" {
    // Oracle: a child with min-width 60px in a fixed 40px track lays out
    // at 60px, not 40px.
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .min_size = .{ .width = style.dimension.LengthPercentageAuto.length(60), .height = style.dimension.LengthPercentageAuto.auto() },
    });
    const columns = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_length(40) },
    };
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .grid_template_columns = &columns,
    }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 60), (try tree_ref.layout_of(child)).size.width);
}
