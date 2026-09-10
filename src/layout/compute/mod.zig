//! Taffy `compute/mod.rs` module root.

const std = @import("std");

pub const block = @import("block.zig");
pub const common = @import("common/mod.zig");
pub const flexbox = @import("flexbox.zig");
pub const float = @import("float.zig");
pub const grid = @import("grid/mod.zig");
pub const leaf = @import("leaf.zig");

const geometry = @import("../geometry.zig");
const style = @import("../style/mod.zig");
const available = @import("../style/available_space.zig");
const tree = @import("../tree/taffy_tree.zig");
const tree_layout = @import("../tree/layout.zig");

pub const ComputeError = error{ InvalidParentNode, InvalidChildNode, InvalidInputNode, ChildIndexOutOfBounds, InvalidLayoutMode, OutOfMemory };

/// Compute one child and memoize its complete layout input/output pair.
/// Taffy separates this operation from the algorithms so custom trees can
/// reuse the cache contract; the concrete tree does the same.
pub fn compute_cached_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, input: tree_layout.LayoutInput) ComputeError!tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    if (!node_data.dirty) if (node_data.cache.get(input)) |output| return output;
    var output = try compute_child_layout(tree_ref, node_id, input);
    output.scrollable_overflow_rect = compute_node_scrollable_overflow(tree_ref, node_id, output.size);
    if (tree_ref.node(node_id)) |updated| {
        updated.unrounded_layout.size = output.size;
        updated.unrounded_layout.scrollable_overflow_rect = output.scrollable_overflow_rect;
        updated.final_layout = updated.unrounded_layout;
        updated.cache.store(input, output);
        updated.dirty = false;
    }
    return output;
}

fn compute_node_scrollable_overflow(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, size: geometry.Size(f32)) geometry.Rect(f32) {
    const node_data = tree_ref.node(node_id) orelse return .{ .left = 0, .right = size.width, .top = 0, .bottom = size.height };
    var result = geometry.Rect(f32){ .left = 0, .right = size.width, .top = 0, .bottom = size.height };
    const parent_scroll_container = node_data.style.overflow.x.is_scroll_container() or node_data.style.overflow.y.is_scroll_container();
    for (node_data.children.items) |child_id| {
        const child = tree_ref.node(child_id) orelse continue;
        const child_contribution = common.scrollable_overflow.compute_scrollable_overflow_contribution(
            child.unrounded_layout.location,
            child.unrounded_layout.size,
            child.unrounded_layout.scrollable_overflow_rect,
            child.style.overflow,
            child.style.contain,
            parent_scroll_container,
        );
        result.left = @min(result.left, child_contribution.left);
        result.right = @max(result.right, child_contribution.right);
        result.top = @min(result.top, child_contribution.top);
        result.bottom = @max(result.bottom, child_contribution.bottom);
    }
    return result;
}

/// Dispatch according to `Style.display`. Container bodies remain in their
/// source-mapped modules; the dispatcher must not duplicate their algorithms.
pub fn compute_child_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, input: tree_layout.LayoutInput) ComputeError!tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    if (node_data.style.display == .none) return compute_hidden_layout(tree_ref, node_id);
    if (node_data.children.items.len == 0) return leaf.compute_leaf_layout(input, node_data.style, node_data.measure_context, node_data.measure);

    // Taffy's low-level algorithms request child layouts through
    // `LayoutPartialTree::compute_child_layout`. The dynamic Zig tree has no
    // Rust trait object, so the dispatcher performs that same recursive visit
    // before handing the already-measured children to a container kernel.
    const parent_width = input.known_dimensions.width orelse input.parent_size.width orelse input.available_space.width.into_option();
    const parent_height = input.known_dimensions.height orelse input.parent_size.height orelse input.available_space.height.into_option();
    for (node_data.children.items) |child_id| {
        _ = try compute_cached_layout(tree_ref, child_id, .{
            .run_mode = .perform_layout,
            .sizing_mode = input.sizing_mode,
            .axis = .both,
            .known_dimensions = .{ .width = null, .height = null },
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = .{ .width = parent_width, .height = parent_height },
            .available_space = input.available_space,
            .vertical_margins_are_collapsible = .{ .start = false, .end = false },
        });
    }
    return switch (node_data.style.display) {
        .flex => flexbox.compute_flexbox_layout(tree_ref, node_id, input),
        .grid => grid.compute_grid_layout(tree_ref, node_id, input),
        .block, .flow_root => block.compute_block_layout(tree_ref, node_id, input, null),
        .none => tree_layout.LayoutOutput.hidden,
    };
}

/// Root wrapper corresponding to Taffy's `compute_root_layout`.
pub fn compute_root_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, available_space: geometry.Size(available.AvailableSpace)) ComputeError!tree_layout.LayoutOutput {
    const input = tree_layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = available_space.width.into_option(), .height = available_space.height.into_option() },
        .available_space = available_space,
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    const output = try compute_cached_layout(tree_ref, node_id, input);
    if (tree_ref.node(node_id)) |node_data| {
        const width = available_space.width.into_option() orelse output.size.width;
        const parent_width = available_space.width.into_option() orelse width;
        const padding = geometry.Rect(f32){
            .left = node_data.style.padding.left.resolve(parent_width),
            .right = node_data.style.padding.right.resolve(parent_width),
            .top = node_data.style.padding.top.resolve(parent_width),
            .bottom = node_data.style.padding.bottom.resolve(parent_width),
        };
        const border = geometry.Rect(f32){
            .left = node_data.style.border.left.resolve(parent_width),
            .right = node_data.style.border.right.resolve(parent_width),
            .top = node_data.style.border.top.resolve(parent_width),
            .bottom = node_data.style.border.bottom.resolve(parent_width),
        };
        node_data.unrounded_layout.location = .{ .x = if (node_data.style.direction == .rtl) @max(0, width - output.size.width) else 0, .y = 0 };
        node_data.unrounded_layout.padding = padding;
        node_data.unrounded_layout.border = border;
        node_data.unrounded_layout.scrollable_overflow_rect = output.scrollable_overflow_rect;
        node_data.final_layout = node_data.unrounded_layout;
    }
    return output;
}

pub fn compute_hidden_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId) ComputeError!tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    node_data.cache.clear();
    node_data.unrounded_layout = .with_order(0);
    node_data.final_layout = .with_order(0);
    for (node_data.children.items) |child_id| _ = try compute_hidden_layout(tree_ref, child_id);
    return tree_layout.LayoutOutput.hidden;
}

pub fn round_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId) !void {
    try round_layout_inner(tree_ref, node_id, 0, 0);
}

pub fn round_layout_inner(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, cumulative_x: f32, cumulative_y: f32) !void {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    const unrounded = node_data.unrounded_layout;
    const absolute_x = cumulative_x + unrounded.location.x;
    const absolute_y = cumulative_y + unrounded.location.y;
    var rounded = unrounded;
    rounded.location.x = @round(unrounded.location.x);
    rounded.location.y = @round(unrounded.location.y);
    rounded.size.width = @round(absolute_x + unrounded.size.width) - @round(absolute_x);
    rounded.size.height = @round(absolute_y + unrounded.size.height) - @round(absolute_y);
    rounded.border.left = @round(absolute_x + unrounded.border.left) - @round(absolute_x);
    rounded.border.right = @round(absolute_x + unrounded.size.width) - @round(absolute_x + unrounded.size.width - unrounded.border.right);
    rounded.border.top = @round(absolute_y + unrounded.border.top) - @round(absolute_y);
    rounded.border.bottom = @round(absolute_y + unrounded.size.height) - @round(absolute_y + unrounded.size.height - unrounded.border.bottom);
    rounded.padding.left = @round(absolute_x + unrounded.padding.left) - @round(absolute_x);
    rounded.padding.right = @round(absolute_x + unrounded.size.width) - @round(absolute_x + unrounded.size.width - unrounded.padding.right);
    rounded.padding.top = @round(absolute_y + unrounded.padding.top) - @round(absolute_y);
    rounded.padding.bottom = @round(absolute_y + unrounded.size.height) - @round(absolute_y + unrounded.size.height - unrounded.padding.bottom);
    rounded.scrollable_overflow_rect.left = @round(absolute_x + unrounded.scrollable_overflow_rect.left) - @round(absolute_x);
    rounded.scrollable_overflow_rect.right = @round(absolute_x + unrounded.scrollable_overflow_rect.right) - @round(absolute_x);
    rounded.scrollable_overflow_rect.top = @round(absolute_y + unrounded.scrollable_overflow_rect.top) - @round(absolute_y);
    rounded.scrollable_overflow_rect.bottom = @round(absolute_y + unrounded.scrollable_overflow_rect.bottom) - @round(absolute_y);
    rounded.scrollbar_size.width = @round(unrounded.scrollbar_size.width);
    rounded.scrollbar_size.height = @round(unrounded.scrollbar_size.height);
    node_data.final_layout = rounded;
    for (node_data.children.items) |child_id| try round_layout_inner(tree_ref, child_id, absolute_x, absolute_y);
}

test {
    _ = geometry.Size(f32);
    _ = style.Style{};
}

test "root dispatcher executes the first flex layout path" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_a = try tree_ref.new_leaf(.{ .size = .{ .width = .{ .value = .{ .length = 20 } }, .height = .{ .value = .{ .length = 10 } } } });
    const child_b = try tree_ref.new_leaf(.{ .size = .{ .width = .{ .value = .{ .length = 30 } }, .height = .{ .value = .{ .length = 10 } } } });
    const root = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{ child_a, child_b });
    _ = try compute_root_layout(&tree_ref, root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(child_a)).size.width);
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(child_b)).location.x);
}

test "root dispatcher executes the first grid layout path" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .size = .{ .width = .{ .value = .{ .length = 10 } }, .height = .{ .value = .{ .length = 10 } } } });
    const columns = [_]style.grid.GridTemplateComponent{
        .{ .single = style.grid.TrackSizingFunction.from_length(40) },
        .{ .single = style.grid.TrackSizingFunction.from_fr(1) },
    };
    const rows = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_length(20) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows }, &[_]tree.NodeId{child});
    _ = try compute_root_layout(&tree_ref, root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(child)).size.width);
}

test "layout propagation records descendant scrollable overflow" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .size = .{ .width = .length(100), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(50), .height = .length(20) } }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 50 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 100), (try tree_ref.layout_of(root)).scrollable_overflow_rect.right);
}

test "root layout positions RTL roots against available width" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const root = try tree_ref.new_leaf(.{ .display = .block, .direction = .rtl, .size = .{ .width = .length(50), .height = .length(20) } });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 50), (try tree_ref.layout_of(root)).location.x);
}

test "display none recursively hides descendants" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(20) } });
    const child = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{ .display = .none, .size = .{ .width = .length(50), .height = .length(50) } }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(root)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(grandchild)).size.width);
}

test "container min and max sizes clamp algorithm output" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const flex_root = try tree_ref.new_leaf(.{
        .size = .{ .width = .length(20), .height = .length(10) },
        .min_size = .{ .width = .length(50), .height = .auto() },
        .max_size = .{ .width = .length(60), .height = .auto() },
    });
    try tree_ref.compute_layout(flex_root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 50), (try tree_ref.layout_of(flex_root)).size.width);
}

test "container content-box sizes include padding and border in outer layout" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const root = try tree_ref.new_leaf(.{
        .display = .block,
        .box_sizing = .content_box,
        .size = .{ .width = .length(50), .height = .length(20) },
        .padding = .{ .left = .length(5), .right = .length(5), .top = .length(2), .bottom = .length(2) },
        .border = .{ .left = .length(1), .right = .length(1), .top = .length(1), .bottom = .length(1) },
    });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    const result = try tree_ref.layout_of(root);
    try testing.expectEqual(@as(f32, 62), result.size.width);
    try testing.expectEqual(@as(f32, 26), result.size.height);
}

test {
    _ = @import("block.zig");
    _ = @import("common/mod.zig");
    _ = @import("flexbox.zig");
    _ = @import("float.zig");
    _ = @import("grid/mod.zig");
    _ = @import("leaf.zig");
}
