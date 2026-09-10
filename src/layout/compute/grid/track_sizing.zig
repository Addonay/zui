//! Grid track sizing primitives from Taffy's `compute/grid/track_sizing.rs`.
//!
//! The public stage operates on the same base-size/growth-limit/flexible
//! length vocabulary as the Rust algorithm. Intrinsic item contributions are
//! accumulated by the grid entry point before this stage distributes free
//! space; this keeps the phase boundary explicit and makes each phase
//! testable in isolation.

const std = @import("std");
const style = @import("../../style/grid.zig");
const available = @import("../../style/available_space.zig");
const grid_track = @import("types/grid_track.zig");
const grid_item = @import("types/grid_item.zig");
const track_counts = @import("types/grid_track_counts.zig");
const coordinates = @import("types/coordinates.zig");

pub const TrackSizingPhase = enum {
    initialize,
    intrinsic_minimums,
    content_based_minimums,
    max_content_limits,
    flexible_lengths,
};

pub const Track = struct {
    min: f32 = 0,
    max: ?f32 = null,
    fr: f32 = 0,
    size: f32 = 0,
    offset: f32 = 0,
    min_sizing: style.MinTrackSizingFunction = .auto,
    max_sizing: style.MaxTrackSizingFunction = .auto,
    is_collapsed: bool = false,
    is_auto_fit: bool = false,
};

pub const IntrinsicContributionType = enum { minimum, min_content, max_content };

pub const ItemBatch = struct {
    items: []grid_item.GridItem,
    crosses_flexible: bool,
};

/// The values needed by the CSS Grid track-sizing phases. Taffy passes these
/// through its tree traits; the concrete Zig tree exposes them as a record so
/// the phase order stays visible and independently testable.
pub const GridTrackSizingInput = struct {
    axis: @import("../../geometry.zig").AbstractAxis = .inline_axis,
    available_space: available.AvailableSpace = .max_content,
    percentage_basis: ?f32 = null,
    minimum_size: ?f32 = null,
    maximum_size: ?f32 = null,
    stretch_auto_tracks: bool = false,
};

pub const ItemBatcher = struct {
    axis: @import("../../geometry.zig").AbstractAxis,
    index: usize = 0,

    pub fn new(axis: @import("../../geometry.zig").AbstractAxis) ItemBatcher {
        return .{ .axis = axis };
    }

    pub fn next(self: *ItemBatcher, items: []grid_item.GridItem) ?ItemBatch {
        if (self.index >= items.len) return null;
        const start = self.index;
        const flex = items[start].crosses_flexible_track(self.axis);
        self.index += 1;
        while (self.index < items.len and items[self.index].crosses_flexible_track(self.axis) == flex and items[self.index].span(self.axis) == items[start].span(self.axis)) : (self.index += 1) {}
        return .{ .items = items[start..self.index], .crosses_flexible = flex };
    }
};

/// Initialize each track's base size from its minimum and then resolve
/// percentage/flexible/fixed free-space behavior. The function deliberately
/// accepts already-grown sizes: intrinsic contributions have precedence over
/// the authored minimum, as in Taffy's later grid phases.
pub fn compute_track_sizes(tracks: []Track, available_space: ?f32, gap: f32) f32 {
    for (tracks) |*track| {
        if (available_space) |basis| {
            if (track.min_sizing.definite_value(basis)) |minimum| track.min = @max(track.min, minimum);
            if (track.max_sizing.definite_value(basis)) |maximum| track.max = maximum;
            if (track.max_sizing.is_fit_content()) {
                const fit_limit = switch (track.max_sizing.value) {
                    .fit_content_length => |value| value,
                    .fit_content_percent => |value| basis * value,
                    else => std.math.inf(f32),
                };
                track.max = if (track.max) |maximum| @min(maximum, fit_limit) else fit_limit;
            }
        }
        track.size = @max(track.size, track.min);
        if (track.max) |maximum| track.size = @min(track.size, @max(maximum, track.min));
    }

    var total = track_total(tracks, gap);
    if (available_space) |available_value| {
        const free = available_value - total;
        if (free > 0) {
            var flexible_sum: f32 = 0;
            for (tracks) |track| flexible_sum += @max(0, track.fr);
            if (flexible_sum > 0) {
                for (tracks) |*track| {
                    if (track.fr > 0) track.size += free * track.fr / flexible_sum;
                }
            }
        } else if (free < 0) {
            var shrinkable: f32 = 0;
            for (tracks) |track| {
                if (track.max == null or track.fr > 0) shrinkable += @max(track.size, 0);
            }
            if (shrinkable > 0) for (tracks) |*track| {
                if (track.max == null or track.fr > 0) track.size = @max(track.min, track.size + free * track.size / shrinkable);
            };
        }
        total = track_total(tracks, gap);
    }
    return total;
}

/// Complete first-pass track-sizing stage. This keeps Taffy's phase order
/// explicit: initialize base sizes, apply the definite container constraint,
/// resolve flexible tracks, then return the occupied axis size.
pub fn track_sizing_algorithm(tracks: []Track, available_space: available.AvailableSpace, gap: f32) f32 {
    var requires_initialization = true;
    for (tracks) |track| if (track.size != 0) {
        requires_initialization = false;
        break;
    };
    if (requires_initialization) initialize_track_sizes(tracks);
    const definite = available_space.into_option();
    return compute_track_sizes(tracks, definite, gap);
}

fn track_total(tracks: []const Track, gap: f32) f32 {
    var result = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;
    for (tracks) |track| result += track.size;
    return result;
}

pub fn cmp_by_cross_flex_then_span_then_start(a: grid_item.GridItem, b: grid_item.GridItem, axis: @import("../../geometry.zig").AbstractAxis) bool {
    if (a.crosses_flexible_track(axis) != b.crosses_flexible_track(axis)) return !a.crosses_flexible_track(axis);
    if (a.span(axis) != b.span(axis)) return a.span(axis) < b.span(axis);
    return a.placement(axis).start.value < b.placement(axis).start.value;
}

pub fn sort_grid_items_for_intrinsic_sizing(items: []grid_item.GridItem, axis: @import("../../geometry.zig").AbstractAxis) void {
    std.sort.heap(grid_item.GridItem, items, axis, struct {
        fn lessThan(context: @import("../../geometry.zig").AbstractAxis, lhs: grid_item.GridItem, rhs: grid_item.GridItem) bool {
            return cmp_by_cross_flex_then_span_then_start(lhs, rhs, context);
        }
    }.lessThan);
}

pub fn compute_alignment_gutter_adjustment(free_space: f32, track_count: usize) f32 {
    return if (track_count == 0) 0 else free_space / @as(f32, @floatFromInt(track_count));
}

pub fn resolve_item_track_indexes(items: []grid_item.GridItem, column_counts: track_counts.TrackCounts, row_counts: track_counts.TrackCounts) void {
    for (items) |*item| {
        item.column_indexes = .{
            .start = @intCast(coordinates.origin_zero_line_into_track_vec_index_with_counts(item.column.start, column_counts)),
            .end = @intCast(coordinates.origin_zero_line_into_track_vec_index_with_counts(item.column.end, column_counts)),
        };
        item.row_indexes = .{
            .start = @intCast(coordinates.origin_zero_line_into_track_vec_index_with_counts(item.row.start, row_counts)),
            .end = @intCast(coordinates.origin_zero_line_into_track_vec_index_with_counts(item.row.end, row_counts)),
        };
    }
}

pub fn determine_if_item_crosses_flexible_or_intrinsic_tracks(items: []grid_item.GridItem, columns: []const grid_track.GridTrack, rows: []const grid_track.GridTrack) void {
    for (items) |*item| {
        const column_range = grid_item.TrackRange{ .start = @intCast(@max(@as(i16, 0), item.column.start.value)), .end = @intCast(@max(@as(i16, 0), item.column.end.value)) };
        const row_range = grid_item.TrackRange{ .start = @intCast(@max(@as(i16, 0), item.row.start.value)), .end = @intCast(@max(@as(i16, 0), item.row.end.value)) };
        item.crosses_flexible_column = range_has_track(column_range, columns, true, false);
        item.crosses_intrinsic_column = range_has_track(column_range, columns, false, true);
        item.crosses_flexible_row = range_has_track(row_range, rows, true, false);
        item.crosses_intrinsic_row = range_has_track(row_range, rows, false, true);
    }
}

fn range_has_track(range: grid_item.TrackRange, tracks: []const grid_track.GridTrack, flexible: bool, intrinsic: bool) bool {
    if (range.start >= range.end or range.end > tracks.len) return false;
    for (tracks[range.start..range.end]) |track| {
        if (flexible and track.is_flexible()) return true;
        if (intrinsic and track.has_intrinsic_sizing_function()) return true;
    }
    return false;
}

pub fn initialize_track_sizes(tracks: []Track) void {
    for (tracks) |*track| track.size = @max(track.min, 0);
}

pub fn flush_planned_base_size_increases(tracks: []grid_track.GridTrack) void {
    for (tracks) |*track| {
        track.base_size += @max(track.base_size_planned_increase, 0);
        track.base_size_planned_increase = 0;
    }
}

pub fn flush_planned_growth_limit_increases(tracks: []grid_track.GridTrack, set_infinitely_growable: bool) void {
    for (tracks) |*track| {
        track.growth_limit += @max(track.growth_limit_planned_increase, 0);
        track.growth_limit_planned_increase = 0;
        if (set_infinitely_growable) track.infinitely_growable = true;
    }
}

pub fn crossed_flex_factor_sum(tracks: []const grid_track.GridTrack) f32 {
    var result: f32 = 0;
    for (tracks) |track| result += track.flex_factor();
    return result;
}

pub fn find_size_of_fr(tracks: []const grid_track.GridTrack, space_to_fill: f32) f32 {
    const factor = crossed_flex_factor_sum(tracks);
    return if (factor > 0) @max(space_to_fill, 0) / factor else 0;
}

pub fn stretch_auto_tracks(tracks: []Track, free_space: f32) void {
    var count: usize = 0;
    for (tracks) |track| {
        if (track.fr == 0 and track.max == null) count += 1;
    }
    if (count == 0) return;
    const share = free_space / @as(f32, @floatFromInt(count));
    for (tracks) |*track| {
        if (track.fr == 0 and track.max == null) track.size += share;
    }
}

pub fn distribute_space_up_to_limits(tracks: []Track, free_space: f32) void {
    if (free_space <= 0) return;
    for (tracks) |*track| {
        if (track.max) |maximum| {
            const amount = @min(free_space, @max(0, maximum - track.size));
            track.size += amount;
        }
    }
}

/// Distribute an item's intrinsic contribution across eligible tracks. The
/// Rust algorithm has several predicate/limit closures; this Zig form keeps
/// the same phase boundary while accepting a simple eligibility callback.
pub fn distribute_item_space_to_base_size(tracks: []grid_track.GridTrack, space: f32, predicate: *const fn (grid_track.GridTrack) bool) void {
    if (space <= 0) return;
    var eligible: usize = 0;
    for (tracks) |track| {
        if (predicate(track)) eligible += 1;
    }
    if (eligible == 0) return;
    const share = space / @as(f32, @floatFromInt(eligible));
    for (tracks) |*track| if (predicate(track)) {
        const limit = @max(track.growth_limit, track.base_size);
        track.base_size += @min(share, @max(0, limit - track.base_size));
    };
}

pub fn distribute_item_space_to_base_size_inner(tracks: []grid_track.GridTrack, space: f32, predicate: *const fn (grid_track.GridTrack) bool) void {
    distribute_item_space_to_base_size(tracks, space, predicate);
}

pub fn distribute_item_space_to_growth_limit(tracks: []grid_track.GridTrack, space: f32, predicate: *const fn (grid_track.GridTrack) bool) void {
    if (space <= 0) return;
    var eligible: usize = 0;
    for (tracks) |track| {
        if (predicate(track)) eligible += 1;
    }
    if (eligible == 0) return;
    const share = space / @as(f32, @floatFromInt(eligible));
    for (tracks) |*track| if (predicate(track)) {
        track.growth_limit = @max(track.base_size, track.growth_limit + share);
    };
}

pub fn maximise_tracks(tracks: []grid_track.GridTrack, available_space: ?f32) void {
    const available_size_value = available_space orelse return;
    var used: f32 = 0;
    var expandable: usize = 0;
    for (tracks) |track| {
        used += track.base_size;
        if (track.growth_limit > track.base_size and !track.is_collapsed) expandable += 1;
    }
    if (expandable == 0 or available_size_value <= used) return;
    distribute_item_space_to_growth_limit(tracks, available_size_value - used, struct {
        fn eligible(track: grid_track.GridTrack) bool {
            return track.growth_limit > track.base_size and !track.is_collapsed;
        }
    }.eligible);
    for (tracks) |*track| track.base_size = @min(track.growth_limit, track.base_size + @max(0, available_size_value - used) / @as(f32, @floatFromInt(expandable)));
}

pub fn expand_flexible_tracks(tracks: []grid_track.GridTrack, available_space: ?f32) void {
    const available_size_value = available_space orelse return;
    const factor = crossed_flex_factor_sum(tracks);
    if (factor <= 0) return;
    const fr_size = find_size_of_fr(tracks, available_size_value);
    for (tracks) |*track| {
        if (track.is_flexible()) track.base_size = @max(track.base_size, fr_size * track.flex_factor());
    }
}

test "track sizing distributes flexible free space" {
    const testing = std.testing;
    var tracks = [_]Track{ .{ .min = 10, .fr = 1 }, .{ .min = 10, .fr = 2 } };
    const total = compute_track_sizes(&tracks, 70, 0);
    try testing.expectApproxEqAbs(@as(f32, 70), total, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 26.666666), tracks[0].size, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 43.333334), tracks[1].size, 0.001);
}

test "track sizing resolves item indexes and crossing flags" {
    const testing = std.testing;
    var items = [_]grid_item.GridItem{.{
        .column = .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } },
        .row = .{ .start = .{ .value = 0 }, .end = .{ .value = 1 } },
    }};
    var columns = [_]grid_track.GridTrack{ grid_track.GridTrack.new(.auto, .fr(1)), grid_track.GridTrack.new(.auto, .max_content) };
    var rows = [_]grid_track.GridTrack{grid_track.GridTrack.new(.auto, .auto)};
    resolve_item_track_indexes(&items, track_counts.TrackCounts.from_raw(0, 2, 0), track_counts.TrackCounts.from_raw(0, 1, 0));
    determine_if_item_crosses_flexible_or_intrinsic_tracks(&items, &columns, &rows);
    try testing.expectEqual(@as(u16, 0), items[0].column_indexes.start);
    try testing.expect(items[0].crosses_flexible_column);
    try testing.expect(items[0].crosses_intrinsic_column);
}

test "track sizing retains percentage and fit-content limits" {
    const testing = std.testing;
    var tracks = [_]Track{
        .{ .min_sizing = style.MinTrackSizingFunction.percent(0.25), .max_sizing = style.MaxTrackSizingFunction.percent(0.5) },
        .{ .min_sizing = .auto, .max_sizing = style.MaxTrackSizingFunction.fit_content_length(30) },
    };
    _ = compute_track_sizes(&tracks, 100, 0);
    try testing.expectEqual(@as(f32, 25), tracks[0].size);
    try testing.expectEqual(@as(f32, 0), tracks[1].size);
    try testing.expectEqual(@as(?f32, 50), tracks[0].max);
}

pub fn resolve_available_space(value: available.AvailableSpace, used: f32) f32 {
    return value.compute_free_space(used);
}

pub fn track_style_is_intrinsic(value: style.TrackSizingFunction) bool {
    return value.min.is_intrinsic() or value.max.is_intrinsic();
}

/// Initialise the real Taffy `GridTrack` records. Fixed minimums become base
/// sizes, fixed maximums become growth limits, and intrinsic/flexible maxima
/// begin unbounded. Gutters are represented by records too, so callers can
/// use one coordinate space for line indexes and tracks.
pub fn initialize_grid_track_sizes(tracks: []grid_track.GridTrack, percentage_basis: ?f32) void {
    for (tracks) |*track| {
        track.base_size = track.min_track_sizing_function.definite_value(percentage_basis) orelse 0;
        track.growth_limit = track.max_track_sizing_function.definite_value(percentage_basis) orelse std.math.inf(f32);
        if (track.growth_limit < track.base_size) track.growth_limit = track.base_size;
        track.base_size_planned_increase = 0;
        track.growth_limit_planned_increase = 0;
        track.item_incurred_increase = 0;
        track.infinitely_growable = false;
    }
}

fn track_is_intrinsic_for_minimum(track: grid_track.GridTrack, available_space: available.AvailableSpace, percentage_basis: ?f32) bool {
    if (track.kind == .gutter) return false;
    if (track.min_track_sizing_function.is_intrinsic()) return true;
    // CSS Grid treats unresolved percentage minimums as min-content while the
    // container itself is indefinite. This is an observable browser/Taffy
    // quirk and is not equivalent to simply resolving them to zero.
    return percentage_basis == null and available_space != .definite and track.min_track_sizing_function.uses_percentage();
}

fn track_is_intrinsic_for_growth(track: grid_track.GridTrack, percentage_basis: ?f32) bool {
    if (track.kind == .gutter) return false;
    return track.max_track_sizing_function.is_intrinsic() or (percentage_basis == null and track.max_track_sizing_function.uses_percentage());
}

fn actual_track_indexes(tracks: []const grid_track.GridTrack, range: grid_item.TrackRange) usize {
    var count: usize = 0;
    const bounded_end = @min(range.end, tracks.len);
    if (range.start >= bounded_end) return 0;
    for (tracks[range.start..bounded_end]) |track| {
        if (track.kind == .track and !track.is_collapsed) count += 1;
    }
    return count;
}

fn sum_actual_base_sizes(tracks: []const grid_track.GridTrack, range: grid_item.TrackRange) f32 {
    var total: f32 = 0;
    const bounded_end = @min(range.end, tracks.len);
    if (range.start >= bounded_end) return 0;
    for (tracks[range.start..bounded_end]) |track| {
        if (track.kind == .track and !track.is_collapsed) total += track.base_size;
    }
    return total;
}

fn distribute_intrinsic_deficit(tracks: []grid_track.GridTrack, range: grid_item.TrackRange, deficit: f32, only_intrinsic: bool, available_space: available.AvailableSpace, percentage_basis: ?f32) void {
    if (deficit <= 0) return;
    var eligible: usize = 0;
    const bounded_end = @min(range.end, tracks.len);
    if (range.start >= bounded_end) return;
    for (tracks[range.start..bounded_end]) |track| {
        if (track.kind == .track and !track.is_collapsed and (!only_intrinsic or track_is_intrinsic_for_minimum(track, available_space, percentage_basis))) eligible += 1;
    }
    if (eligible == 0 and only_intrinsic) {
        distribute_intrinsic_deficit(tracks, range, deficit, false, available_space, percentage_basis);
        return;
    }
    if (eligible == 0) return;
    const share = deficit / @as(f32, @floatFromInt(eligible));
    for (tracks[range.start..bounded_end]) |*track| {
        if (track.kind == .track and !track.is_collapsed and (!only_intrinsic or track_is_intrinsic_for_minimum(track.*, available_space, percentage_basis))) {
            const limit = if (track.growth_limit == std.math.inf(f32)) std.math.inf(f32) else @max(track.growth_limit, track.base_size);
            track.base_size = @min(limit, track.base_size + share);
        }
    }
}

fn item_contribution(item: *grid_item.GridItem, axis: @import("../../geometry.zig").AbstractAxis, kind: IntrinsicContributionType, available_size: f32) f32 {
    return switch (kind) {
        .minimum => item.minimum_contribution_cached(axis, available_size),
        .min_content => item.min_content_contribution_cached(axis, available_size),
        .max_content => item.max_content_contribution_cached(axis, available_size),
    };
}

/// Resolve intrinsic contributions for the concrete `GridItem` records. This
/// is the compact Zig form of Taffy's 11.5 pass: one-track items establish
/// base sizes first, then spanning items distribute their excess over the
/// intrinsic tracks they cross, and finally intrinsic growth limits are
/// raised from min-/max-content contributions.
pub fn resolve_intrinsic_grid_track_sizes(
    tracks: []grid_track.GridTrack,
    items: []grid_item.GridItem,
    axis: @import("../../geometry.zig").AbstractAxis,
    input: GridTrackSizingInput,
) void {
    // Taffy sorts by flexible-crossing status, span, then source position.
    // The caller retains source order; the result is independent of the order
    // here because each contribution is monotonic, so a stable insertion sort
    // is unnecessary for this pass.
    sort_grid_items_for_intrinsic_sizing(items, axis);
    for (items) |*item| {
        const range = item.track_range_excluding_lines(axis);
        if (range.end > tracks.len or range.start >= range.end) continue;
        const span = actual_track_indexes(tracks, range);
        if (span == 0) continue;
        const min_contribution = item_contribution(item, axis, .minimum, sum_actual_base_sizes(tracks, range));
        const min_content = item_contribution(item, axis, .min_content, sum_actual_base_sizes(tracks, range));
        const max_content = item_contribution(item, axis, .max_content, sum_actual_base_sizes(tracks, range));

        if (span == 1) {
            for (tracks[range.start..range.end]) |*track| if (track.kind == .track and !track.is_collapsed) {
                if (track_is_intrinsic_for_minimum(track.*, input.available_space, input.percentage_basis)) {
                    const contribution = if (track.min_track_sizing_function.is_min_content()) min_content else if (track.min_track_sizing_function.is_max_content()) max_content else min_contribution;
                    track.base_size = @max(track.base_size, contribution);
                }
                if (track_is_intrinsic_for_growth(track.*, input.percentage_basis)) {
                    const contribution = if (track.max_track_sizing_function.is_max_content_alike()) max_content else min_content;
                    const fit_limit = track.fit_content_limit(input.percentage_basis);
                    track.growth_limit = @max(track.growth_limit, @min(contribution, fit_limit));
                }
            };
        } else {
            const current = sum_actual_base_sizes(tracks, range);
            const target = @max(min_contribution, min_content);
            distribute_intrinsic_deficit(tracks, range, target - current, true, input.available_space, input.percentage_basis);
            var max_target = @max(max_content, target);
            const max_limit = item.spanned_track_limit(axis, tracks, input.percentage_basis) orelse max_target;
            max_target = @min(max_target, max_limit);
            var growth_sum: f32 = 0;
            for (tracks[range.start..range.end]) |track| {
                if (track.kind == .track and !track.is_collapsed) growth_sum += track.growth_limit;
            }
            if (max_target > growth_sum) {
                const share = (max_target - growth_sum) / @as(f32, @floatFromInt(span));
                for (tracks[range.start..range.end]) |*track| {
                    if (track.kind == .track and !track.is_collapsed) track.growth_limit = @max(track.growth_limit, track.base_size + share);
                }
            }
        }
    }
    for (tracks) |*track| {
        if (track.growth_limit < track.base_size) track.growth_limit = track.base_size;
        track.base_size_planned_increase = 0;
        track.growth_limit_planned_increase = 0;
    }
}

/// CSS Grid's `find_size_of_fr` with the restart rule for flexible tracks
/// whose base size is already larger than the naive fraction.
pub fn find_grid_fr_size(tracks: []const grid_track.GridTrack, space_to_fill: f32) f32 {
    if (space_to_fill <= 0) return 0;
    var hypothetical = std.math.inf(f32);
    var previous = hypothetical;
    var iteration: usize = 0;
    while (iteration <= tracks.len) : (iteration += 1) {
        var used: f32 = 0;
        var factor: f32 = 0;
        for (tracks) |track| {
            if (track.is_flexible() and track.flex_factor() * hypothetical >= track.base_size) factor += track.flex_factor() else used += track.base_size;
        }
        previous = hypothetical;
        hypothetical = (space_to_fill - used) / @max(factor, 1);
        var valid = true;
        for (tracks) |track| if (track.is_flexible()) {
            const factor_value = track.flex_factor();
            if (factor_value * hypothetical < track.base_size and factor_value * previous >= track.base_size) valid = false;
        };
        if (valid) break;
    }
    return @max(hypothetical, 0);
}

/// Distribute positive free space only across finite growth limits. Infinite
/// intrinsic tracks are deliberately skipped here; CSS Grid reserves them for
/// the later flexible/auto-stretch phases.
pub fn maximise_grid_tracks(tracks: []grid_track.GridTrack, available_size: ?f32) void {
    const available_value = available_size orelse return;
    var remaining = available_value - sum_grid_track_base_sizes(tracks);
    if (remaining <= 0) return;
    var iteration: usize = 0;
    while (remaining > 0.000001 and iteration <= tracks.len) : (iteration += 1) {
        var eligible: usize = 0;
        for (tracks) |track| {
            if (track.kind == .track and !track.is_collapsed and track.growth_limit != std.math.inf(f32) and track.growth_limit > track.base_size) eligible += 1;
        }
        if (eligible == 0) break;
        const share = remaining / @as(f32, @floatFromInt(eligible));
        var distributed: f32 = 0;
        for (tracks) |*track| {
            if (track.kind != .track or track.is_collapsed or track.growth_limit == std.math.inf(f32) or track.growth_limit <= track.base_size) continue;
            const amount = @min(share, track.growth_limit - track.base_size);
            track.base_size += amount;
            distributed += amount;
        }
        if (distributed <= 0) break;
        remaining -= distributed;
    }
}

fn sum_grid_track_base_sizes(tracks: []const grid_track.GridTrack) f32 {
    var result: f32 = 0;
    for (tracks) |track| result += track.base_size;
    return result;
}

/// Run the real GridTrack phase sequence for callers that have already done
/// placement. Gutters participate in sums but never receive intrinsic item
/// contributions or auto-track stretch.
pub fn grid_track_sizing_algorithm(tracks: []grid_track.GridTrack, items: []grid_item.GridItem, input: GridTrackSizingInput) f32 {
    initialize_grid_track_sizes(tracks, input.percentage_basis);
    resolve_intrinsic_grid_track_sizes(tracks, items, input.axis, input);

    const available_value = input.available_space.into_option();
    if (available_value) |available_size| {
        // 11.6 Maximise Tracks: only finite growth limits participate.
        maximise_grid_tracks(tracks, available_size);
        const free = available_size - sum_grid_track_base_sizes(tracks);
        if (free > 0 and crossed_flex_factor_sum(tracks) > 0) {
            const fr_size = find_grid_fr_size(tracks, available_size);
            for (tracks) |*track| {
                if (track.is_flexible()) track.base_size = @max(track.base_size, fr_size * track.flex_factor());
            }
        }
    }

    if (input.stretch_auto_tracks) {
        const basis = available_value orelse input.minimum_size orelse 0;
        var used: f32 = 0;
        var count: usize = 0;
        for (tracks) |track| {
            used += track.base_size;
            if (track.kind == .track and track.max_track_sizing_function.is_auto()) count += 1;
        }
        if (count > 0 and basis > used) {
            const share = (basis - used) / @as(f32, @floatFromInt(count));
            for (tracks) |*track| {
                if (track.kind == .track and track.max_track_sizing_function.is_auto()) track.base_size += share;
            }
        }
    }
    var total: f32 = 0;
    for (tracks) |track| total += track.base_size;
    return total;
}

/// Convert finalized base sizes into line coordinates. The gutter records are
/// intentionally included, exactly as Taffy's alternating `GridTrackVec`.
pub fn compute_grid_track_offsets(tracks: []grid_track.GridTrack, gap: f32) void {
    var cursor: f32 = 0;
    for (tracks) |*track| {
        track.offset = cursor;
        cursor += track.base_size;
        if (track.kind == .track) cursor += gap;
    }
}

test "grid intrinsic tracks grow for single and spanning contributions" {
    const testing = std.testing;
    var tracks = [_]grid_track.GridTrack{
        grid_track.GridTrack.gutter(.zero()),
        grid_track.GridTrack.new(.auto, .auto),
        grid_track.GridTrack.gutter(.zero()),
        grid_track.GridTrack.new(.auto, .auto),
        grid_track.GridTrack.gutter(.zero()),
    };
    var items = [_]grid_item.GridItem{
        .{ .column = .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } }, .column_indexes = .{ .start = 0, .end = 4 }, .min_content_contribution_cache = .{ .width = 70, .height = null }, .minimum_contribution_cache = .{ .width = 50, .height = null }, .max_content_contribution_cache = .{ .width = 90, .height = null } },
    };
    initialize_grid_track_sizes(&tracks, null);
    resolve_intrinsic_grid_track_sizes(&tracks, &items, .inline_axis, .{ .available_space = .max_content });
    try testing.expectApproxEqAbs(@as(f32, 35), tracks[1].base_size, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 35), tracks[3].base_size, 0.001);
}

test "grid fr sizing restarts around an oversized base track" {
    const testing = std.testing;
    var tracks = [_]grid_track.GridTrack{
        grid_track.GridTrack.new(.zero, style.MaxTrackSizingFunction.fr(1)),
        grid_track.GridTrack.gutter(.zero()),
        grid_track.GridTrack.new(.length(80), style.MaxTrackSizingFunction.fr(1)),
    };
    _ = grid_track_sizing_algorithm(&tracks, &[_]grid_item.GridItem{}, .{ .available_space = .{ .definite = 100 } });
    try testing.expect(tracks[0].base_size >= 10);
    try testing.expect(tracks[2].base_size >= 80);
}

test "grid maximization skips infinite intrinsic limits until stretch" {
    const testing = std.testing;
    var tracks = [_]grid_track.GridTrack{
        grid_track.GridTrack.gutter(.zero()),
        grid_track.GridTrack.new(.auto, .auto),
        grid_track.GridTrack.gutter(.zero()),
        grid_track.GridTrack.new(.length(20), .length(20)),
        grid_track.GridTrack.gutter(.zero()),
    };
    _ = grid_track_sizing_algorithm(&tracks, &[_]grid_item.GridItem{}, .{ .axis = .inline_axis, .available_space = .{ .definite = 100 }, .stretch_auto_tracks = false });
    try testing.expectEqual(@as(f32, 0), tracks[1].base_size);
    try testing.expectEqual(@as(f32, 20), tracks[3].base_size);
    _ = grid_track_sizing_algorithm(&tracks, &[_]grid_item.GridItem{}, .{ .axis = .inline_axis, .available_space = .{ .definite = 100 }, .stretch_auto_tracks = true });
    try testing.expectEqual(@as(f32, 80), tracks[1].base_size);
}
