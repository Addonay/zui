//! Grid item records from Taffy's `compute/grid/types/grid_item.rs`.
//!
//! Placement is resolved before track sizing. The record therefore keeps both
//! OriginZero line coordinates and the odd/even GridTrackVec indexes, plus the
//! style and contribution caches consumed by the sizing phases.

const geometry = @import("../../../geometry.zig");
const style = @import("../../../style/mod.zig");
const available = @import("../../../style/available_space.zig");
const coordinates = @import("coordinates.zig");
const grid_track = @import("grid_track.zig");

pub const TrackRange = struct { start: usize, end: usize };

pub const GridItem = struct {
    node: u32 = 0,
    source_order: u16 = 0,
    row: geometry.Line(coordinates.OriginZeroLine) = .{ .start = .{ .value = 0 }, .end = .{ .value = 1 } },
    column: geometry.Line(coordinates.OriginZeroLine) = .{ .start = .{ .value = 0 }, .end = .{ .value = 1 } },
    row_start: i16 = 0,
    row_end: i16 = 1,
    column_start: i16 = 0,
    column_end: i16 = 1,
    is_compressible_replaced: bool = false,
    overflow: geometry.Point(style.Overflow) = .{ .x = .visible, .y = .visible },
    box_sizing: style.BoxSizing = .border_box,
    size: geometry.Size(style.dimension.Dimension) = .{ .width = .auto, .height = .auto },
    min_size: geometry.Size(style.dimension.LengthPercentageAuto) = .{ .width = .auto(), .height = .auto() },
    max_size: geometry.Size(style.dimension.LengthPercentageAuto) = .{ .width = .auto(), .height = .auto() },
    aspect_ratio: ?f32 = null,
    padding: geometry.Rect(style.dimension.LengthPercentage) = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .zero() },
    border: geometry.Rect(style.dimension.LengthPercentage) = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .zero() },
    margin: geometry.Rect(style.dimension.LengthPercentageAuto) = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .zero() },
    align_self: style.alignment.AlignSelf = style.alignment.AlignSelf.stretch,
    justify_self: style.alignment.JustifySelf = style.alignment.JustifySelf.stretch,
    baseline: ?f32 = null,
    baseline_shim: f32 = 0,
    row_indexes: geometry.Line(u16) = .{ .start = 0, .end = 2 },
    column_indexes: geometry.Line(u16) = .{ .start = 0, .end = 2 },
    crosses_flexible_row: bool = false,
    crosses_flexible_column: bool = false,
    crosses_intrinsic_row: bool = false,
    crosses_intrinsic_column: bool = false,
    grid_area_size_cache: ?geometry.Size(?f32) = null,
    min_content_contribution_cache: geometry.Size(?f32) = .{ .width = null, .height = null },
    minimum_contribution_cache: geometry.Size(?f32) = .{ .width = null, .height = null },
    max_content_contribution_cache: geometry.Size(?f32) = .{ .width = null, .height = null },
    measured_intrinsic_size: geometry.Size(?f32) = .{ .width = null, .height = null },
    y_position: f32 = 0,
    height: f32 = 0,

    pub fn new_with_placement_style_and_order(node: u32, column: geometry.Line(coordinates.OriginZeroLine), row: geometry.Line(coordinates.OriginZeroLine), item_style: style.Style, parent_align_items: style.alignment.AlignItems, parent_justify_items: style.alignment.AlignItems, source_order: u16) GridItem {
        return .{
            .node = node,
            .source_order = source_order,
            .row = row,
            .column = column,
            .row_start = row.start.value,
            .row_end = row.end.value,
            .column_start = column.start.value,
            .column_end = column.end.value,
            .is_compressible_replaced = item_style.item_is_replaced,
            .overflow = item_style.overflow,
            .box_sizing = item_style.box_sizing,
            .size = item_style.size,
            .min_size = item_style.min_size,
            .max_size = item_style.max_size,
            .aspect_ratio = item_style.aspect_ratio,
            .padding = item_style.padding,
            .border = item_style.border,
            .margin = item_style.margin,
            .align_self = item_style.align_self orelse parent_align_items,
            .justify_self = item_style.justify_self orelse parent_justify_items,
        };
    }

    pub fn has_auto_block_margin(self: GridItem) bool {
        return self.margin.top.is_auto() or self.margin.bottom.is_auto();
    }

    pub fn has_cyclic_block_size_dependency(self: GridItem) bool {
        return self.size.height.into_raw().uses_percentage() and (self.crosses_intrinsic_row or self.crosses_flexible_row);
    }

    pub fn participates_in_baseline_alignment(self: GridItem) bool {
        return self.align_self.keyword == .baseline and !self.has_auto_block_margin() and !self.has_cyclic_block_size_dependency();
    }

    pub fn placement(self: GridItem, axis: geometry.AbstractAxis) geometry.Line(coordinates.OriginZeroLine) {
        return if (axis == .block) self.row else self.column;
    }
    pub fn placement_indexes(self: GridItem, axis: geometry.AbstractAxis) geometry.Line(u16) {
        return if (axis == .block) self.row_indexes else self.column_indexes;
    }

    pub fn track_range_excluding_lines(self: GridItem, axis: geometry.AbstractAxis) TrackRange {
        const indexes = self.placement_indexes(axis);
        return .{ .start = indexes.start + 1, .end = indexes.end };
    }

    pub fn spans_track_matching(self: GridItem, axis: geometry.AbstractAxis, tracks: []const grid_track.GridTrack, predicate: *const fn (grid_track.GridTrack) bool) bool {
        const range = self.track_range_excluding_lines(axis);
        if (range.end > tracks.len or range.start >= range.end) return false;
        for (tracks[range.start..range.end]) |track| if (predicate(track)) return true;
        return false;
    }

    pub fn span(self: GridItem, axis: geometry.AbstractAxis) u16 {
        const placement_value = self.placement(axis);
        return coordinates.line_origin_zero_span(placement_value);
    }

    pub fn span_horizontal(self: GridItem) u16 {
        return self.span(.inline_axis);
    }
    pub fn span_vertical(self: GridItem) u16 {
        return self.span(.block);
    }

    pub fn crosses_flexible_track(self: GridItem, axis: geometry.AbstractAxis) bool {
        return if (axis == .inline_axis) self.crosses_flexible_column else self.crosses_flexible_row;
    }
    pub fn crosses_intrinsic_track(self: GridItem, axis: geometry.AbstractAxis) bool {
        return if (axis == .inline_axis) self.crosses_intrinsic_column else self.crosses_intrinsic_row;
    }

    pub fn spanned_track_limit(self: GridItem, axis: geometry.AbstractAxis, tracks: []const grid_track.GridTrack, parent_size: ?f32) ?f32 {
        const range = self.track_range_excluding_lines(axis);
        if (range.end > tracks.len or range.start >= range.end) return null;
        var total: f32 = 0;
        for (tracks[range.start..range.end]) |track| total += track.max_track_sizing_function.definite_limit(parent_size) orelse return null;
        return total;
    }

    pub fn spanned_fixed_track_limit(self: GridItem, axis: geometry.AbstractAxis, tracks: []const grid_track.GridTrack, parent_size: ?f32) ?f32 {
        return self.spanned_track_limit(axis, tracks, parent_size);
    }

    pub fn known_dimensions(self: GridItem, area_dimensions: geometry.Size(?f32)) geometry.Size(?f32) {
        const padding = self.padding.map(geometry.F32Size, struct {
            fn resolve(value: style.dimension.LengthPercentage) f32 {
                return value.resolve(0);
            }
        }.resolve);
        const border = self.border.map(geometry.F32Size, struct {
            fn resolve(value: style.dimension.LengthPercentage) f32 {
                return value.resolve(0);
            }
        }.resolve);
        const box_adjustment = if (self.box_sizing == .content_box) padding.add(border) else geometry.F32Size{ .width = 0, .height = 0 };
        var result = geometry.Size(?f32){ .width = self.size.width.resolve(area_dimensions.width), .height = self.size.height.resolve(area_dimensions.height) };
        result = .{ .width = if (result.width) |value| value + box_adjustment.width else null, .height = if (result.height) |value| value + box_adjustment.height else null };
        if (result.width == null and !self.margin.left.is_auto() and !self.margin.right.is_auto() and self.justify_self.keyword == .stretch) result.width = area_dimensions.width;
        if (result.height == null and !self.margin.top.is_auto() and !self.margin.bottom.is_auto() and self.align_self.keyword == .stretch) result.height = area_dimensions.height;
        if (result.width == null) result.width = self.min_size.width.resolve(area_dimensions.width);
        if (result.height == null) result.height = self.min_size.height.resolve(area_dimensions.height);
        return result.maybe_apply_aspect_ratio(self.aspect_ratio);
    }

    pub fn grid_area_size(self: GridItem, axis: geometry.AbstractAxis, area_size: geometry.Size(?f32)) geometry.Size(?f32) {
        _ = self;
        _ = axis;
        return area_size;
    }

    /// Resolve an item's grid area from the alternating line/track vectors.
    /// An axis is definite only when every spanned track has a definite fixed
    /// min and max sizing function; the other axis remains unresolved until
    /// the corresponding track phase has produced a provisional size.
    pub fn grid_area_size_for_tracks(self: GridItem, axis: geometry.AbstractAxis, axis_tracks: []const grid_track.GridTrack, other_axis_tracks: []const grid_track.GridTrack, available_size: geometry.Size(?f32)) geometry.Size(?f32) {
        var result = geometry.Size(?f32){ .width = null, .height = null };
        const own_range = self.track_range_excluding_lines(axis);
        const other_range = self.track_range_excluding_lines(axis.other());
        if (own_range.end <= axis_tracks.len and own_range.start < own_range.end) {
            var definite = true;
            var total: f32 = 0;
            for (axis_tracks[own_range.start..own_range.end]) |track| {
                const min_value = track.min_track_sizing_function.definite_value(available_size.get(axis));
                const max_value = track.max_track_sizing_function.definite_value(available_size.get(axis));
                if (min_value == null or max_value == null or min_value.? != max_value.?) definite = false;
                total += track.base_size;
            }
            if (definite) result.set(axis, total);
        }
        if (other_range.end <= other_axis_tracks.len and other_range.start < other_range.end) {
            var total: f32 = 0;
            for (other_axis_tracks[other_range.start..other_range.end]) |track| {
                total += track.base_size + track.content_alignment_adjustment;
            }
            result.set(axis.other(), total);
        }
        return result;
    }
    pub fn grid_area_size_cached(self: *GridItem, axis: geometry.AbstractAxis, area_size: geometry.Size(?f32)) geometry.Size(?f32) {
        if (self.grid_area_size_cache) |cached| return cached;
        const result = self.grid_area_size(axis, area_size);
        self.grid_area_size_cache = result;
        return result;
    }

    pub fn margins_axis_sums_with_baseline_shims(self: GridItem, inner_node_width: ?f32) geometry.Size(f32) {
        return .{
            .width = (self.margin.left.resolve(0) orelse 0) + (self.margin.right.resolve(0) orelse 0),
            .height = (self.margin.top.resolve(inner_node_width orelse 0) orelse 0) + (self.margin.bottom.resolve(inner_node_width orelse 0) orelse 0) + self.baseline_shim,
        };
    }

    pub fn min_content_contribution(self: *GridItem, axis: geometry.AbstractAxis, available_size: f32) f32 {
        if (self.min_content_contribution_cache.get(axis)) |value| return value;
        if (self.measured_intrinsic_size.get(axis)) |value| {
            self.min_content_contribution_cache.set(axis, value);
            return value;
        }
        const styled = self.size.get(axis).resolve(available_size);
        const minimum = self.min_size.get(axis).resolve(available_size);
        const result = styled orelse minimum orelse available_size;
        self.min_content_contribution_cache.set(axis, result);
        return result;
    }
    pub fn min_content_contribution_cached(self: *GridItem, axis: geometry.AbstractAxis, available_size: f32) f32 {
        return self.min_content_contribution(axis, available_size);
    }
    pub fn max_content_contribution(self: *GridItem, axis: geometry.AbstractAxis, available_size: f32) f32 {
        if (self.max_content_contribution_cache.get(axis)) |value| return value;
        if (self.measured_intrinsic_size.get(axis)) |value| {
            self.max_content_contribution_cache.set(axis, value);
            return value;
        }
        const styled = self.size.get(axis).resolve(available_size);
        const result = styled orelse available_size;
        self.max_content_contribution_cache.set(axis, result);
        return result;
    }
    pub fn max_content_contribution_cached(self: *GridItem, axis: geometry.AbstractAxis, available_size: f32) f32 {
        return self.max_content_contribution(axis, available_size);
    }
    pub fn minimum_contribution(self: *GridItem, axis: geometry.AbstractAxis, available_size: f32) f32 {
        if (self.minimum_contribution_cache.get(axis)) |value| return value;
        if (self.overflow.get(axis).maybe_into_automatic_min_size()) |value| {
            self.minimum_contribution_cache.set(axis, value);
            return value;
        }
        const result = self.min_size.get(axis).resolve(available_size) orelse self.min_content_contribution(axis, available_size);
        self.minimum_contribution_cache.set(axis, result);
        return result;
    }
    pub fn minimum_contribution_cached(self: *GridItem, axis: geometry.AbstractAxis, available_size: f32) f32 {
        return self.minimum_contribution(axis, available_size);
    }

    pub fn keyword_adjusted_available_space(self: GridItem, axis: geometry.AbstractAxis, value: available.AvailableSpace) available.AvailableSpace {
        const dimension = self.size.get(axis);
        if (!dimension.is_sizing_keyword()) return value;
        return switch (dimension.value) {
            .min_content => .min_content,
            .max_content, .fit_content, .fit_content_length, .fit_content_percent => .max_content,
            else => value,
        };
    }

    pub fn set_measured_intrinsic_size(self: *GridItem, size: geometry.Size(?f32)) void {
        self.measured_intrinsic_size = size;
        self.min_content_contribution_cache = .{ .width = null, .height = null };
        self.minimum_contribution_cache = .{ .width = null, .height = null };
        self.max_content_contribution_cache = .{ .width = null, .height = null };
    }
};

test "grid item retains placement and contribution caches" {
    const testing = @import("std").testing;
    var item = GridItem.new_with_placement_style_and_order(
        7,
        .{ .start = .{ .value = 1 }, .end = .{ .value = 3 } },
        .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } },
        .{},
        style.alignment.AlignItems.start,
        style.alignment.AlignItems.stretch,
        2,
    );
    try testing.expectEqual(@as(u16, 2), item.span(.inline_axis));
    try testing.expectEqual(@as(u16, 2), item.span(.block));
    try testing.expect(!item.has_auto_block_margin());
    try testing.expectEqual(@as(f32, 14), item.min_content_contribution_cached(.inline_axis, 14));
    try testing.expectEqual(@as(f32, 17), item.max_content_contribution_cached(.inline_axis, 17));
}
