//! High-value conformance cases for the layout kernels.
//!
//! These are hand-written, allocation-free counterparts to the vendored
//! Taffy fixture families. They focus on observable geometry and constraints,
//! so a regression reports the exact feature that changed instead of only
//! saying that a large snapshot differs.

const std = @import("std");
const compute_mod = @import("../compute.zig");
const style_mod = @import("../style.zig");
const tree_mod = @import("../tree.zig");

fn fixedTree(style: style_mod.Style, child_styles: []const style_mod.Style, viewport_w: f32, viewport_h: f32) compute_mod.ComputeTree {
    var result = compute_mod.ComputeTree.init();
    var children: [tree_mod.max_nodes]tree_mod.NodeId = undefined;
    for (child_styles, 0..) |child_style, i| {
        children[i] = result.tree.newLeaf(child_style);
    }
    const root = result.tree.newWithChildren(style, children[0..child_styles.len]);
    result.computeRoot(root, .{ .w = viewport_w, .h = viewport_h });
    return result;
}

test "conformance: fixed row and column preserve order" {
    const row = fixedTree(.{ .flex_direction = .row }, &[_]style_mod.Style{
        .{ .size = .{ .w = 20, .h = 10 } },
        .{ .size = .{ .w = 30, .h = 15 } },
    }, 100, 40);
    try std.testing.expectEqual(@as(f32, 0), row.tree.nodes[0].layout.x);
    try std.testing.expectEqual(@as(f32, 20), row.tree.nodes[1].layout.x);

    const column = fixedTree(.{ .flex_direction = .column }, &[_]style_mod.Style{
        .{ .size = .{ .w = 20, .h = 10 } },
        .{ .size = .{ .w = 30, .h = 15 } },
    }, 100, 40);
    try std.testing.expectEqual(@as(f32, 0), column.tree.nodes[0].layout.y);
    try std.testing.expectEqual(@as(f32, 10), column.tree.nodes[1].layout.y);
}

test "conformance: grow, shrink and min constraints" {
    var ct = compute_mod.ComputeTree.init();
    const a = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 }, .flex_grow = 1 });
    const b = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 }, .flex_grow = 3 });
    const root = ct.tree.newWithChildren(.{ .flex_direction = .row }, &[_]tree_mod.NodeId{ a, b });
    ct.computeRoot(root, .{ .w = 110, .h = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 32.5), ct.tree.nodes[a].layout.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 77.5), ct.tree.nodes[b].layout.w, 0.001);

    var shrink = compute_mod.ComputeTree.init();
    const wide_a = shrink.tree.newLeaf(.{ .size = .{ .w = 100, .h = 10 }, .flex_shrink = 1 });
    const wide_b = shrink.tree.newLeaf(.{ .size = .{ .w = 100, .h = 10 }, .flex_shrink = 1, .min_width = .{ .length = 95 } });
    const shrink_root = shrink.tree.newWithChildren(.{ .flex_direction = .row }, &[_]tree_mod.NodeId{ wide_a, wide_b });
    shrink.computeRoot(shrink_root, .{ .w = 150, .h = 20 });
    try std.testing.expectEqual(@as(f32, 95), shrink.tree.nodes[wide_b].layout.w);
    try std.testing.expectEqual(@as(f32, 55), shrink.tree.nodes[wide_a].layout.w);
}

test "conformance: gaps, justify, align and auto margins" {
    var ct = compute_mod.ComputeTree.init();
    const a = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 } });
    const b = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 }, .margin_left_auto = true });
    const root = ct.tree.newWithChildren(.{ .flex_direction = .row, .gap_col = .{ .length = 5 }, .align_items = .center }, &[_]tree_mod.NodeId{ a, b });
    ct.computeRoot(root, .{ .w = 100, .h = 40 });
    try std.testing.expectEqual(@as(f32, 0), ct.tree.nodes[a].layout.x);
    try std.testing.expectEqual(@as(f32, 90), ct.tree.nodes[b].layout.x);
    try std.testing.expectEqual(@as(f32, 15), ct.tree.nodes[a].layout.y);
}

test "conformance: wrapping and reverse direction" {
    var ct = compute_mod.ComputeTree.init();
    const a = ct.tree.newLeaf(.{ .size = .{ .w = 60, .h = 10 } });
    const b = ct.tree.newLeaf(.{ .size = .{ .w = 60, .h = 20 } });
    const c = ct.tree.newLeaf(.{ .size = .{ .w = 20, .h = 30 } });
    const root = ct.tree.newWithChildren(.{ .flex_direction = .row, .flex_wrap = .wrap, .align_content = .start }, &[_]tree_mod.NodeId{ a, b, c });
    ct.computeRoot(root, .{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 10), ct.tree.nodes[b].layout.y);
    try std.testing.expectEqual(@as(f32, 10), ct.tree.nodes[c].layout.y);

    var reverse = compute_mod.ComputeTree.init();
    const first = reverse.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 } });
    const second = reverse.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 } });
    const reverse_root = reverse.tree.newWithChildren(.{ .flex_direction = .row_reverse }, &[_]tree_mod.NodeId{ first, second });
    reverse.computeRoot(reverse_root, .{ .w = 100, .h = 20 });
    try std.testing.expectEqual(@as(f32, 90), reverse.tree.nodes[first].layout.x);
    try std.testing.expectEqual(@as(f32, 80), reverse.tree.nodes[second].layout.x);
}

test "conformance: box sizing, percentage dimensions and aspect ratio" {
    var ct = compute_mod.ComputeTree.init();
    const child = ct.tree.newLeaf(.{ .width = .{ .percent = 0.5 }, .height = .{ .length = 10 }, .aspect_ratio = 2 });
    const root = ct.tree.newWithChildren(.{ .padding = .all(5) }, &[_]tree_mod.NodeId{child});
    ct.computeRoot(root, .{ .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 45), ct.tree.nodes[child].layout.w);
    try std.testing.expectEqual(@as(f32, 10), ct.tree.nodes[child].layout.h);
    try std.testing.expectEqual(@as(f32, 5), ct.tree.nodes[child].layout.x);
}

test "conformance: block margins and absolute insets" {
    var ct = compute_mod.ComputeTree.init();
    const a = ct.tree.newLeaf(.{ .size = .{ .w = 20, .h = 10 }, .margin = .{ .top = 3, .bottom = 4 } });
    const b = ct.tree.newLeaf(.{ .size = .{ .w = 20, .h = 8 } });
    const abs = ct.tree.newLeaf(.{ .position = .absolute, .size = .{ .w = 10, .h = 5 }, .inset_left = .{ .length = 7 }, .inset_top = .{ .length = 9 } });
    const root = ct.tree.newWithChildren(.{ .display = .block }, &[_]tree_mod.NodeId{ a, b, abs });
    ct.computeRoot(root, .{ .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 3), ct.tree.nodes[a].layout.y);
    try std.testing.expectEqual(@as(f32, 17), ct.tree.nodes[b].layout.y);
    try std.testing.expectEqual(@as(f32, 7), ct.tree.nodes[abs].layout.x);
    try std.testing.expectEqual(@as(f32, 9), ct.tree.nodes[abs].layout.y);
}

test "conformance: grid fixed, fractional, span and implicit placement" {
    var ct = compute_mod.ComputeTree.init();
    var columns = [_]style_mod.GridTrack{ style_mod.GridTrack.fixed(40), style_mod.GridTrack.flex(1), style_mod.GridTrack.fixed(20) };
    var rows = [_]style_mod.GridTrack{ style_mod.GridTrack.fixed(10), style_mod.GridTrack.flex(1) };
    const a = ct.tree.newLeaf(.{});
    const b = ct.tree.newLeaf(.{ .grid_col_start = 2, .grid_col_span = 2 });
    const c = ct.tree.newLeaf(.{ .grid_row_start = 2, .grid_col_start = 1 });
    const root = ct.tree.newWithChildren(.{ .display = .grid, .grid_columns = &columns, .grid_rows = &rows, .gap_col = .{ .length = 5 }, .gap_row = .{ .length = 3 } }, &[_]tree_mod.NodeId{ a, b, c });
    ct.computeRoot(root, .{ .w = 200, .h = 100 });
    try std.testing.expectEqual(@as(f32, 0), ct.tree.nodes[a].layout.x);
    try std.testing.expectEqual(@as(f32, 45), ct.tree.nodes[b].layout.x);
    try std.testing.expectEqual(@as(f32, 13), ct.tree.nodes[c].layout.y);
    try std.testing.expect(ct.tree.nodes[b].layout.w > 20);
}

test "conformance: display none clears a subtree and cache invalidates" {
    var ct = compute_mod.ComputeTree.init();
    const grandchild = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 10 } });
    const child = ct.tree.newWithChildren(.{}, &[_]tree_mod.NodeId{grandchild});
    const root = ct.tree.newWithChildren(.{}, &[_]tree_mod.NodeId{child});
    ct.computeRoot(root, .{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 10), ct.tree.nodes[grandchild].layout.w);
    ct.tree.setStyle(child, .{ .display = .none });
    ct.computeRoot(root, .{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 0), ct.tree.nodes[child].layout.w);
    try std.testing.expectEqual(@as(f32, 0), ct.tree.nodes[grandchild].layout.w);
}
