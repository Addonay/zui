//! Grid kernel — port of Taffy `compute/grid/` (scaffold).
//!
//! v1 scope: fixed track counts from `Style.grid_columns/rows`, uniform
//! `repeat(n, minmax)` tracks (covers GPUI subset), explicit placement via
//! `grid_{row,col}_{start,span}`, `gap_row/col`. Implicit tracks, auto
//! placement search, subgrid/masonry explicitly out (see brainstorm).
//! Track sizing (`track_sizing.rs`) + placement (`placement.rs`) land in Phase C.

const tree_mod = @import("tree.zig");
const geo = @import("geometry.zig");

/// Number of tracks after expanding repeats. Pure helper for placement math.
pub fn trackCount(repeats: []const u16) u16 {
    var n: u16 = 0;
    for (repeats) |r| n += r;
    return n;
}

/// Clamp a span to the available tracks (explicit-grid overflow rule).
pub fn clampSpan(start: u16, span: u16, total: u16) u16 {
    if (total == 0 or start >= total) return 0;
    const room = total - start;
    return @min(span, room);
}

pub fn computeGrid(
    tree: *tree_mod.LayoutTree,
    id: tree_mod.NodeId,
    input: geo.LayoutInput,
) void {
    _ = tree;
    _ = id;
    _ = input;
}

test "track count expands repeats" {
    const testing = @import("std").testing;
    const reps = [_]u16{ 2, 3 };
    try testing.expectEqual(@as(u16, 5), trackCount(&reps));
}

test "span clamps to grid edge" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u16, 2), clampSpan(1, 5, 3));
    try testing.expectEqual(@as(u16, 0), clampSpan(3, 1, 3));
}
