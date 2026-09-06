//! Block-flow kernel.
//!
//! Taffy's block algorithm has many web-layout details (margin collapsing,
//! floats, clearance and fragmentation). ZUI's UI tree needs the stable core:
//! normal-flow children stack vertically, auto widths stretch to the content
//! width, explicit widths remain explicit, and gaps/margins are preserved.
//! Margin collapsing is intentionally disabled; summing margins is predictable
//! for component authors and matches the rest of ZUI's fixed-capacity model.

const std = @import("std");
const tree_mod = @import("tree.zig");
const style_mod = @import("style.zig");
const geo = @import("geometry.zig");

pub const max_items: usize = tree_mod.max_nodes;

pub const BlockContent = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub fn stackHeight(heights: []const f32, gap: f32) f32 {
    if (heights.len == 0) return 0;
    var total: f32 = 0;
    for (heights) |height| total += height;
    return total + gap * @as(f32, @floatFromInt(heights.len - 1));
}

/// Read-only intrinsic block contribution from measured children.
pub fn contentSize(tree: *const tree_mod.LayoutTree, in_flow: []const tree_mod.NodeId, gap: f32) BlockContent {
    var result = BlockContent{};
    for (in_flow, 0..) |id, i| {
        const child = tree.nodes[id];
        result.width = @max(result.width, child.layout.w + child.style.margin.left + child.style.margin.right);
        result.height += child.layout.h + child.style.margin.top + child.style.margin.bottom;
        if (i > 0) result.height += gap;
    }
    return result;
}

/// Arrange children relative to the parent's content-box origin.
pub fn arrange(tree: *tree_mod.LayoutTree, container: style_mod.Style, in_flow: []const tree_mod.NodeId, final_width: f32, gap: f32) void {
    var cursor: f32 = 0;
    for (in_flow, 0..) |id, i| {
        const cs = tree.nodes[id].style;
        const m = cs.margin;
        if (i > 0) cursor += gap;
        cursor += m.top;

        const auto_width = cs.isAutoOnAxis(true);
        const width = if (auto_width) @max(0, final_width - m.left - m.right) else tree.nodes[id].layout.w;
        tree.nodes[id].layout.w = clampWidth(cs, width, final_width);
        tree.nodes[id].layout.x = m.left;
        tree.nodes[id].layout.y = cursor;
        cursor += tree.nodes[id].layout.h + m.bottom;
    }
    _ = container;
}

fn clampWidth(cs: style_mod.Style, value: f32, parent_width: f32) f32 {
    const minimum = @max(0, cs.min_width.resolve(parent_width) orelse 0);
    const maximum = cs.max_width.resolve(parent_width) orelse std.math.inf(f32);
    return @min(@max(minimum, maximum), @max(minimum, value));
}

/// Arrange-only compatibility entry point retained from the initial scaffold.
pub fn computeBlock(tree: *tree_mod.LayoutTree, id: tree_mod.NodeId, input: geo.LayoutInput) void {
    var ids: [max_items]tree_mod.NodeId = undefined;
    var count: usize = 0;
    var child = tree.nodes[id].first_child;
    while (child) |child_id| : (child = tree.nodes[child_id].next_sibling) {
        if (tree.nodes[child_id].style.position != .absolute and tree.nodes[child_id].style.display != .none) {
            ids[count] = child_id;
            count += 1;
        }
    }
    const natural = contentSize(tree, ids[0..count], 0);
    const width = input.known.w orelse input.available.w.opt() orelse natural.width;
    const height = input.known.h orelse input.available.h.opt() orelse natural.height;
    tree.nodes[id].layout.w = @max(0, width);
    tree.nodes[id].layout.h = @max(0, height);
    arrange(tree, tree.nodes[id].style, ids[0..count], width, 0);
}

test "block stacks with gap" {
    const hs = [_]f32{ 20, 30 };
    try std.testing.expectEqual(@as(f32, 55), stackHeight(&hs, 5));
}

test "block content includes margins" {
    var tree = tree_mod.LayoutTree{};
    const a = tree.newLeaf(.{ .size = .{ .w = 30, .h = 20 }, .margin = .{ .left = 2, .right = 3, .top = 4, .bottom = 5 } });
    const b = tree.newLeaf(.{ .size = .{ .w = 10, .h = 7 } });
    const root = tree.newWithChildren(.{}, &[_]tree_mod.NodeId{ a, b });
    _ = root;
    tree.nodes[a].layout = .{ .w = 30, .h = 20 };
    tree.nodes[b].layout = .{ .w = 10, .h = 7 };
    const content = contentSize(&tree, &[_]tree_mod.NodeId{ a, b }, 3);
    try std.testing.expectEqual(@as(f32, 35), content.width);
    try std.testing.expectEqual(@as(f32, 39), content.height);
}
