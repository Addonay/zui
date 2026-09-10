//! Grid track and item alignment from Taffy's `compute/grid/alignment.rs`.

const geometry = @import("../../geometry.zig");
const alignment = @import("../common/alignment.zig");
const style = @import("../../style/mod.zig");
const style_alignment = @import("../../style/alignment.zig");
const track_types = @import("types/grid_track.zig");
const track_sizing = @import("track_sizing.zig");

pub const TrackAlignment = struct {
    start: f32 = 0,
    gap: f32 = 0,
};

/// Align a row/column track list inside its available content size. Unlike
/// flex, Grid treats authored gaps as part of the track run and distributes
/// only the remaining free space around/between tracks.
pub fn align_track_sizes(container_size: ?f32, tracks: []track_sizing.Track, authored_gap: f32, alignment_style: style_alignment.AlignContent) TrackAlignment {
    var active_count: usize = 0;
    for (tracks) |track| {
        if (!track.is_collapsed) active_count += 1;
    }
    var used: f32 = if (active_count > 1) authored_gap * @as(f32, @floatFromInt(active_count - 1)) else 0;
    for (tracks) |track| used += track.size;
    const free_space = @max(0, (container_size orelse used) - used);
    const keyword = alignment.apply_alignment_fallback(free_space, tracks.len, alignment_style);
    if (keyword == .stretch and free_space > 0) {
        var auto_count: usize = 0;
        for (tracks) |track| {
            if (!track.is_collapsed and track.fr == 0 and track.max == null) auto_count += 1;
        }
        if (auto_count > 0) {
            const share = free_space / @as(f32, @floatFromInt(auto_count));
            for (tracks) |*track| {
                if (!track.is_collapsed and track.fr == 0 and track.max == null) track.size += share;
            }
        }
    }
    const start = alignment.compute_alignment_offset(free_space, active_count, authored_gap, keyword, false, true);
    const extra_gap = if (active_count <= 1) 0 else switch (keyword) {
        .space_between => free_space / @as(f32, @floatFromInt(active_count - 1)),
        .space_around => free_space / @as(f32, @floatFromInt(active_count)),
        .space_evenly => free_space / @as(f32, @floatFromInt(active_count + 1)),
        else => 0,
    };
    return .{ .start = start, .gap = authored_gap + extra_gap };
}

/// Align tracks inside the grid content box. Grid gaps are already represented
/// as gutter tracks, so the alignment calculation receives a zero gap just as
/// Taffy does.
pub fn align_tracks(grid_content_size: f32, padding: geometry.Line(f32), border: geometry.Line(f32), tracks: []track_types.GridTrack, track_alignment: style_alignment.AlignContent, axis_is_reversed: bool) void {
    var used_size: f32 = 0;
    var track_count: usize = 0;
    for (tracks, 0..) |track, index| {
        used_size += track.base_size;
        if (index % 2 == 1 and !track.is_collapsed) track_count += 1;
    }
    const free_space = grid_content_size - used_size;
    var keyword = alignment.apply_alignment_fallback(free_space, track_count, track_alignment);
    if (axis_is_reversed) keyword = style_alignment.reversed(keyword);
    const origin = padding.start + border.start;
    var offset = origin;
    var seen = false;
    for (tracks, 0..) |*track, index| {
        const is_gutter = index % 2 == 0;
        const is_track = !is_gutter and !track.is_collapsed;
        const first = is_track and !seen;
        const adjustment = if (is_track) alignment.compute_alignment_offset(free_space, track_count, 0, keyword, false, first) else 0;
        track.offset = offset + adjustment;
        offset += adjustment + track.base_size;
        if (is_track) seen = true;
    }
}

/// Align one item's border box in one grid area. Auto margins consume free
/// space before `align-self`/`justify-self`, and safe alignment falls back to
/// start when the item overflows its area.
pub fn align_item_within_area(grid_area: geometry.Line(f32), alignment_style: style_alignment.AlignItems, resolved_size: f32, position: style.Position, inset: geometry.Line(?f32), margin: geometry.Line(?f32), baseline_shim: f32, direction: style.Direction) struct { start: f32, margin: geometry.Line(f32) } {
    const area_size = @max(grid_area.end - grid_area.start, 0);
    const non_auto = geometry.Line(f32){ .start = (margin.start orelse 0) + baseline_shim, .end = margin.end orelse 0 };
    const free_space = @max(area_size - resolved_size - non_auto.sum(), 0);
    const auto_count: f32 = @floatFromInt(@as(u8, @intFromBool(margin.start == null)) + @as(u8, @intFromBool(margin.end == null)));
    const auto_size = if (auto_count > 0) free_space / auto_count else 0;
    const resolved_margin = geometry.Line(f32){ .start = (margin.start orelse auto_size) + baseline_shim, .end = margin.end orelse auto_size };
    const overflows = resolved_size + non_auto.sum() > area_size;
    const keyword = alignment.resolve_self_alignment_safety(alignment_style, overflows);

    const alignment_offset = switch (keyword) {
        .start, .flex_start, .baseline, .stretch => if (direction == .rtl) area_size - resolved_size - resolved_margin.end else resolved_margin.start,
        .end, .flex_end => if (direction == .rtl) resolved_margin.start else area_size - resolved_size - resolved_margin.end,
        .center => (area_size - resolved_size + resolved_margin.start - resolved_margin.end) / 2,
        .self_start, .self_end => 0,
    };
    const positioned_offset = if (position == .absolute) if (inset.start) |start| start + non_auto.start else if (inset.end) |end| area_size - end - resolved_size - non_auto.end else alignment_offset else alignment_offset;
    var start = grid_area.start + positioned_offset;
    if (position == .relative) start += if (direction == .rtl) (inset.end orelse -(inset.start orelse 0)) else (inset.start orelse -(inset.end orelse 0));
    return .{ .start = start, .margin = resolved_margin };
}

/// Convenience form used by callers that already computed the item's area.
pub fn align_and_position_item(area: geometry.Rect(f32), horizontal: style_alignment.AlignItems, vertical: style_alignment.AlignItems, size: geometry.Size(f32), position: style.Position, direction: style.Direction) geometry.Point(f32) {
    const x = align_item_within_area(.{ .start = area.left, .end = area.right }, horizontal, size.width, position, .{ .start = null, .end = null }, .{ .start = null, .end = null }, 0, direction).start;
    const y = align_item_within_area(.{ .start = area.top, .end = area.bottom }, vertical, size.height, position, .{ .start = null, .end = null }, .{ .start = null, .end = null }, 0, .ltr).start;
    return .{ .x = x, .y = y };
}

pub fn align_track_content(free_space: f32, item_count: usize, track_alignment: style_alignment.AlignContent) f32 {
    return alignment.compute_alignment_offset(free_space, item_count, 0, alignment.apply_alignment_fallback(free_space, item_count, track_alignment), false, true);
}
