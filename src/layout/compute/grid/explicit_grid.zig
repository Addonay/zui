//! Explicit grid initialization from Taffy's `compute/grid/explicit_grid.rs`.

const std = @import("std");
const grid_style = @import("../../style/grid.zig");
const track_types = @import("types/grid_track.zig");
const counts = @import("types/grid_track_counts.zig");

pub const AutoRepeatStrategy = enum {
    max_repetitions_that_do_not_overflow,
    min_repetitions_that_do_overflow,
};

pub const ExplicitGridSize = struct {
    auto_repetitions: u16 = 0,
    track_count: u16 = 0,
};

fn track_definite_value(function: grid_style.TrackSizingFunction, parent_size: ?f32) f32 {
    const maximum = function.max.definite_value(parent_size) orelse function.min.definite_value(parent_size) orelse 0;
    const minimum = function.min.definite_value(parent_size) orelse 0;
    return @max(maximum, minimum);
}

/// Count explicit tracks, validating the same restrictions Taffy applies to
/// auto-repeat definitions: at most one auto-repeat and fixed-size repeated
/// tracks. A zero-track repetition makes the whole template invalid.
pub fn compute_explicit_grid_size_in_axis(template: []const grid_style.GridTemplateComponent, auto_fit_container_size: ?f32, strategy: AutoRepeatStrategy, axis_gap: f32) ExplicitGridSize {
    if (template.len == 0) return .{};
    var non_auto_track_count: u32 = 0;
    var insertion_point: u32 = 0;
    var auto_repeat_count: u16 = 0;
    var repeated_track_count: u16 = 0;
    var repeated_track_used_space: f32 = 0;
    var valid = true;

    for (template) |component| switch (component) {
        .single => |track| {
            non_auto_track_count = @min(non_auto_track_count + 1, @as(u32, 10_000));
            insertion_point = @min(insertion_point + 1, @as(u32, 10_000));
            if (auto_repeat_count > 0 and !track.has_fixed_component()) valid = false;
        },
        .repeat => |repeat| {
            if (repeat.tracks.len == 0) valid = false;
            switch (repeat.count) {
                .count => |count| {
                    const added = @as(u32, count) * @as(u32, @intCast(repeat.tracks.len));
                    non_auto_track_count = @min(non_auto_track_count + added, @as(u32, 10_000));
                    insertion_point = @min(insertion_point + added, @as(u32, 10_000));
                    if (auto_repeat_count > 0) {
                        for (repeat.tracks) |track| {
                            if (!track.has_fixed_component()) valid = false;
                        }
                    }
                },
                .auto_fit, .auto_fill => {
                    auto_repeat_count += 1;
                    if (auto_repeat_count > 1) valid = false;
                    repeated_track_count = @intCast(@min(repeat.tracks.len, @as(usize, 65_535)));
                    for (repeat.tracks) |track| {
                        if (!track.has_fixed_component()) valid = false;
                        repeated_track_used_space += track_definite_value(track, auto_fit_container_size);
                    }
                },
            }
        },
    };
    if (auto_repeat_count > 0) for (template) |component| switch (component) {
        .single => |track| {
            if (!track.has_fixed_component()) valid = false;
        },
        .repeat => |repeat| {
            for (repeat.tracks) |track| {
                if (!track.has_fixed_component()) valid = false;
            }
        },
    };
    if (auto_repeat_count == 0) {
        for (template) |component| switch (component) {
            .single => |track| if (!track.has_fixed_component()) {},
            .repeat => {},
        };
        return if (valid) .{ .track_count = @intCast(@min(non_auto_track_count, @as(u32, 10_000))) } else .{};
    }
    if (!valid or repeated_track_count == 0) return .{};

    var repetitions: u32 = 1;
    if (auto_fit_container_size) |container_size| {
        var non_repeating_used_space: f32 = 0;
        for (template) |component| switch (component) {
            .single => |track| non_repeating_used_space += track_definite_value(track, auto_fit_container_size),
            .repeat => |repeat| switch (repeat.count) {
                .count => |count| {
                    for (repeat.tracks) |track| {
                        non_repeating_used_space += track_definite_value(track, auto_fit_container_size) * @as(f32, @floatFromInt(count));
                    }
                },
                .auto_fit, .auto_fill => {},
            },
        };
        const first_repetition = non_repeating_used_space + repeated_track_used_space + axis_gap * @as(f32, @floatFromInt((non_auto_track_count + repeated_track_count) -| 1));
        if (first_repetition <= container_size) {
            const per_repetition = repeated_track_used_space + @as(f32, @floatFromInt(repeated_track_count)) * axis_gap;
            if (per_repetition > 0) {
                const fit = (container_size - first_repetition) / per_repetition;
                repetitions = switch (strategy) {
                    .max_repetitions_that_do_not_overflow => @as(u32, @intFromFloat(@floor(fit))) + 1,
                    .min_repetitions_that_do_overflow => @as(u32, @intFromFloat(@ceil(fit))) + 1,
                };
            }
        }
    }
    const remaining_tracks = @as(u32, 10_000) -| insertion_point;
    const max_repetitions = if (remaining_tracks == 0) 0 else (remaining_tracks + repeated_track_count - 1) / repeated_track_count;
    repetitions = @min(@max(repetitions, 1), max_repetitions);
    return .{ .auto_repetitions = @intCast(repetitions), .track_count = @intCast(@min(non_auto_track_count + @as(u32, repeated_track_count) * repetitions, @as(u32, 10_000))) };
}

/// Build the alternating line/track vector used by the track-sizing stage.
pub fn initialize_grid_tracks(allocator: std.mem.Allocator, output: *std.ArrayList(track_types.GridTrack), template: []const grid_style.GridTemplateComponent, auto_tracks: []const grid_style.TrackSizingFunction, counts_value: counts.TrackCounts, axis_gap: grid_style.MinTrackSizingFunction, auto_repetition_count: u16) !void {
    _ = axis_gap;
    output.clearRetainingCapacity();
    try output.append(allocator, track_types.GridTrack.gutter(.zero()));
    var explicit_index: usize = 0;
    try create_implicit_tracks(allocator, output, counts_value.negative_implicit, auto_tracks, explicit_index);
    explicit_index += counts_value.negative_implicit;
    for (template) |component| switch (component) {
        .single => |value| if (explicit_index < counts_value.negative_implicit + counts_value.explicit) {
            try output.append(allocator, track_types.GridTrack.new(value.min, value.max));
            try output.append(allocator, track_types.GridTrack.gutter(.zero()));
            explicit_index += 1;
        },
        .repeat => |repeat| {
            const repetitions: usize = switch (repeat.count) {
                .count => |value| value,
                .auto_fit, .auto_fill => auto_repetition_count,
            };
            for (0..repetitions) |_| for (repeat.tracks) |value| if (explicit_index < counts_value.negative_implicit + counts_value.explicit) {
                try output.append(allocator, track_types.GridTrack.new(value.min, value.max));
                try output.append(allocator, track_types.GridTrack.gutter(.zero()));
                explicit_index += 1;
            };
        },
    };
    try create_implicit_tracks(allocator, output, counts_value.positive_implicit, auto_tracks, explicit_index);
}

pub fn create_implicit_tracks(allocator: std.mem.Allocator, output: *std.ArrayList(track_types.GridTrack), count: u16, auto_tracks: []const grid_style.TrackSizingFunction, start_index: usize) !void {
    const auto_count = if (auto_tracks.len == 0) @as(usize, 1) else auto_tracks.len;
    for (0..count, 0..) |_, index| {
        const value = if (auto_tracks.len == 0) grid_style.TrackSizingFunction.auto else auto_tracks[(start_index + index) % auto_count];
        try output.append(allocator, track_types.GridTrack.new(value.min, value.max));
        try output.append(allocator, track_types.GridTrack.gutter(.zero()));
    }
}

test "explicit grid sizing counts fixed and auto-repeat tracks" {
    const testing = std.testing;
    const template = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_length(20) },
        .{ .repeat = .{ .count = .auto_fill, .tracks = &[_]grid_style.TrackSizingFunction{grid_style.TrackSizingFunction.from_length(10)} } },
    };
    const size = compute_explicit_grid_size_in_axis(&template, 100, .max_repetitions_that_do_not_overflow, 0);
    try testing.expect(size.auto_repetitions >= 1);
    try testing.expect(size.track_count >= 2);
}

test "explicit grid auto-repeat math matches CSS fit rules" {
    const testing = std.testing;
    const exact = [_]grid_style.GridTemplateComponent{.{ .repeat = .{ .count = .auto_fill, .tracks = &[_]grid_style.TrackSizingFunction{grid_style.TrackSizingFunction.from_length(40)} } }};
    const exact_size = compute_explicit_grid_size_in_axis(&exact, 120, .max_repetitions_that_do_not_overflow, 0);
    try testing.expectEqual(@as(u16, 3), exact_size.auto_repetitions);
    try testing.expectEqual(@as(u16, 3), exact_size.track_count);

    const gapped_size = compute_explicit_grid_size_in_axis(&exact, 130, .max_repetitions_that_do_not_overflow, 10);
    try testing.expectEqual(@as(u16, 2), gapped_size.auto_repetitions);

    const invalid = [_]grid_style.GridTemplateComponent{.{ .repeat = .{ .count = .auto_fill, .tracks = &[_]grid_style.TrackSizingFunction{grid_style.TrackSizingFunction.from_fr(1)} } }};
    try testing.expectEqual(@as(u16, 0), compute_explicit_grid_size_in_axis(&invalid, 200, .max_repetitions_that_do_not_overflow, 0).track_count);

    const zero_repeat = [_]grid_style.GridTemplateComponent{.{ .repeat = .{ .count = .auto_fill, .tracks = &[_]grid_style.TrackSizingFunction{} } }};
    try testing.expectEqual(@as(u16, 0), compute_explicit_grid_size_in_axis(&zero_repeat, 200, .max_repetitions_that_do_not_overflow, 0).track_count);
}
