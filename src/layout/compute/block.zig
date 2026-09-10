//! CSS block layout port of Taffy's `compute/block.rs`.
//!
//! The block file is intentionally verbose because the margin-collapse and
//! block-formatting-context state is not reducible to a vertical stack. These
//! records and method names follow Taffy's source. Any port section that has
//! The records and phase boundaries remain explicit so the block algorithm
//! can be compared directly with the Rust implementation.

const geometry = @import("../geometry.zig");
const style = @import("../style/mod.zig");
const tree = @import("../tree/taffy_tree.zig");
const tree_layout = @import("../tree/layout.zig");
const float_layout = @import("float.zig");
const sizing_keyword = @import("common/sizing_keyword.zig");

pub const ContentSlot = float_layout.ContentSlot;
pub const BfcSlot = float_layout.BfcSlot;

/// Context for positioning Block and Float boxes within a block formatting
/// context. The optional pointer keeps the first port copyable while still
/// documenting Rust's lifetime relationship.
pub const BlockFormattingContext = struct {
    float_context: float_layout.FloatContext = .{},

    pub fn new() BlockFormattingContext {
        return .{};
    }

    pub fn default() BlockFormattingContext {
        return .{};
    }

    pub fn root_block_context(self: *BlockFormattingContext) BlockContext {
        return .{ .bfc = self, .is_root = true };
    }
};

pub const BlockContext = struct {
    bfc: *BlockFormattingContext,
    y_offset: f32 = 0,
    insets: [2]f32 = .{ 0, 0 },
    content_box_insets: [2]f32 = .{ 0, 0 },
    float_content_height: f32 = -std.math.inf(f32),
    is_root: bool = false,
    adjoining_floats: [2]bool = .{ false, false },
    top_adjoining_floats_state: ?[2]bool = null,

    pub fn sub_context(self: *BlockContext, additional_y_offset: f32, child_insets: [2]f32) BlockContext {
        return .{
            .bfc = self.bfc,
            .y_offset = self.y_offset + additional_y_offset,
            .insets = .{ self.insets[0] + child_insets[0], self.insets[1] + child_insets[1] },
            .content_box_insets = .{ self.insets[0] + child_insets[0], self.insets[1] + child_insets[1] },
            .float_content_height = -std.math.inf(f32),
            .is_root = false,
            .adjoining_floats = self.adjoining_floats,
        };
    }

    pub fn is_bfc_root(self: BlockContext) bool {
        return self.is_root;
    }
    pub fn set_width(self: *BlockContext, width: f32) void {
        self.bfc.float_context.set_width(width);
    }
    pub fn apply_content_box_inset(self: *BlockContext, insets: [2]f32) void {
        self.content_box_insets = .{ self.insets[0] + insets[0], self.insets[1] + insets[1] };
    }
    pub fn has_floats(self: BlockContext) bool {
        return self.bfc.float_context.has_floats();
    }
    pub fn has_active_floats(self: BlockContext, min_y: f32) bool {
        return self.bfc.float_context.has_active_floats(min_y + self.y_offset);
    }
    pub fn place_floated_box(self: *BlockContext, box_size: geometry.Size(f32), min_y: f32, direction: style.float.FloatDirection, clear: style.float.Clear, adjoins: bool) geometry.Point(f32) {
        if (adjoins) self.adjoining_floats[@backingInt(direction)] = true;
        var position = self.bfc.float_context.place_floated_box(box_size, min_y + self.y_offset, self.content_box_insets, direction, clear);
        position.y -= self.y_offset;
        position.x -= self.insets[0];
        self.float_content_height = @max(self.float_content_height, position.y + box_size.height);
        return position;
    }
    pub fn find_content_slot(self: BlockContext, min_y: f32, clear: style.float.Clear, after: ?usize) ContentSlot {
        var slot = self.bfc.float_context.find_content_slot(min_y + self.y_offset, self.content_box_insets, clear, after);
        slot.y -= self.y_offset;
        slot.x -= self.insets[0];
        return slot;
    }
    pub fn find_bfc_slot(self: BlockContext, min_y: f32, margins: [2]f32, direction: style.Direction, clear: style.float.Clear, after: ?usize) BfcSlot {
        var slot = self.bfc.float_context.find_bfc_slot(min_y + self.y_offset, self.content_box_insets, margins, direction, clear, after);
        slot.y -= self.y_offset;
        slot.x -= self.insets[0];
        return slot;
    }
    pub fn cleared_threshold(self: BlockContext, clear: style.float.Clear) ?f32 {
        return if (self.bfc.float_context.cleared_threshold(clear)) |threshold| threshold - self.y_offset else null;
    }
    pub fn has_adjoining_float(self: BlockContext, clear: style.float.Clear) bool {
        return switch (clear) {
            .left => self.adjoining_floats[0],
            .right => self.adjoining_floats[1],
            .both => self.adjoining_floats[0] or self.adjoining_floats[1],
            .none => false,
        };
    }
    pub fn floated_content_height_contribution(self: BlockContext) f32 {
        return self.float_content_height;
    }

    pub fn float_content_contribution(self: BlockContext) f32 {
        return self.float_content_height;
    }

    fn merge_adjoining_floats(self: *BlockContext, flags: [2]bool) void {
        self.adjoining_floats[0] = self.adjoining_floats[0] or flags[0];
        self.adjoining_floats[1] = self.adjoining_floats[1] or flags[1];
    }

    fn commit_strut(self: *BlockContext) void {
        if (self.top_adjoining_floats_state == null) self.top_adjoining_floats_state = self.adjoining_floats;
        self.adjoining_floats = .{ false, false };
    }

    pub fn top_adjoining_floats(self: BlockContext) [2]bool {
        return self.top_adjoining_floats_state orelse self.adjoining_floats;
    }

    fn add_child_floated_content_height_contribution(self: *BlockContext, contribution: f32) void {
        self.float_content_height = @max(self.float_content_height, contribution);
    }
};

pub const BlockItem = struct {
    node_id: tree.NodeId,
    order: u32 = 0,
    is_table: bool = false,
    is_replaced: bool = false,
    is_in_same_bfc: bool = false,
    size_style: geometry.Size(style.dimension.Dimension) = .{ .width = .auto, .height = .auto },
    size: geometry.Size(?f32) = .{ .width = null, .height = null },
    min_size: geometry.Size(?f32) = .{ .width = null, .height = null },
    max_size: geometry.Size(?f32) = .{ .width = null, .height = null },
    overflow: geometry.Point(style.Overflow) = .{ .x = .visible, .y = .visible },
    contain: style.Contain = .{},
    scrollbar_width: f32 = 0,
    position: style.Position = .relative,
    inset: geometry.Rect(style.dimension.LengthPercentageAuto) = .{ .left = .auto(), .right = .auto(), .top = .auto(), .bottom = .auto() },
    margin: geometry.Rect(style.dimension.LengthPercentageAuto) = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .zero() },
    padding: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    border: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    padding_border_sum: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    computed_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    static_position: geometry.Point(f32) = .{ .x = 0, .y = 0 },
    can_be_collapsed_through: bool = false,
    final_layout: ?tree_layout.Layout = null,
};

pub fn compute_block_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, inputs: tree_layout.LayoutInput, block_context: ?*BlockContext) !tree_layout.LayoutOutput {
    _ = block_context;
    return compute_inner(tree_ref, node_id, inputs);
}

fn compute_inner(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, inputs: tree_layout.LayoutInput) !tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    const node_style = node_data.style;
    var items = try generate_item_list(tree_ref, node_id);
    defer items.deinit(tree_ref.allocator);
    const parent_width = inputs.parent_size.width orelse inputs.available_space.width.into_option() orelse 0;
    const padding = resolve_edges(node_style.padding, parent_width);
    const border = resolve_edges(node_style.border, parent_width);
    const inset = add_edges(padding, border);
    const content_available_width = @max(0, (inputs.available_space.width.into_option() orelse 0) - inset.horizontal_axis_sum());

    var natural_width: f32 = 0;
    var natural_height: f32 = 0;
    var previous_bottom_margin = tree_layout.CollapsibleMarginSet.zero;
    for (node_data.children.items) |child_id| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        if (child.style.display == .none or child.style.position == .absolute) continue;
        const margins = resolve_auto_edges(child.style.margin, parent_width);
        natural_width = @max(natural_width, child.unrounded_layout.size.width + margins.left + margins.right);
        const collapsed_top = previous_bottom_margin.collapse_with_margin(margins.top).resolve();
        natural_height += collapsed_top + child.unrounded_layout.size.height;
        previous_bottom_margin = tree_layout.CollapsibleMarginSet.from_margin(margins.bottom);
    }
    natural_height += previous_bottom_margin.resolve();

    const styled_width = node_style.size.width.resolve(inputs.parent_size.width);
    const styled_height = node_style.size.height.resolve(inputs.parent_size.height);
    const styled_width_adjusted = if (node_style.box_sizing == .content_box) if (styled_width) |value| value + inset.horizontal_axis_sum() else null else styled_width;
    const styled_height_adjusted = if (node_style.box_sizing == .content_box) if (styled_height) |value| value + inset.vertical_axis_sum() else null else styled_height;
    const width_unclamped = inputs.known_dimensions.width orelse styled_width_adjusted orelse inputs.available_space.width.into_option() orelse determine_content_based_container_width(natural_width, inset);
    const height_unclamped = inputs.known_dimensions.height orelse styled_height_adjusted orelse natural_height + inset.vertical_axis_sum();
    const width = style.dimension.clamp_resolved_size(width_unclamped, node_style.min_size.width, node_style.max_size.width, parent_width);
    const height = style.dimension.clamp_resolved_size(height_unclamped, node_style.min_size.height, node_style.max_size.height, inputs.parent_size.height orelse height_unclamped);
    const outer = geometry.Size(f32){ .width = @max(inset.horizontal_axis_sum(), width), .height = @max(inset.vertical_axis_sum(), height) };
    const content_width = @max(0, outer.width - inset.horizontal_axis_sum());
    node_data.unrounded_layout.size = outer;
    node_data.unrounded_layout.padding = padding;
    node_data.unrounded_layout.border = border;

    var formatting_context = BlockFormattingContext.new();
    defer formatting_context.float_context.deinit(tree_ref.allocator);
    formatting_context.float_context.set_width(content_width);
    var block_context = formatting_context.root_block_context();
    block_context.apply_content_box_inset(.{ inset.left, inset.right });
    try perform_final_layout_on_in_flow_children(tree_ref, node_id, content_width, parent_width, inset, &block_context);
    perform_absolute_layout_on_absolute_children(tree_ref, node_id, content_width, @max(0, outer.height - inset.vertical_axis_sum()), inset);

    node_data.final_layout = node_data.unrounded_layout;
    _ = content_available_width;
    _ = items.items.len;
    return tree_layout.LayoutOutput.from_outer_size(outer);
}

fn generate_item_list(tree_ref: *tree.TaffyTree, node_id: tree.NodeId) !std.ArrayList(BlockItem) {
    var result = std.ArrayList(BlockItem).empty;
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    for (node_data.children.items, 0..) |child_id, order| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        try result.append(tree_ref.allocator, .{
            .node_id = child_id,
            .order = @intCast(order),
            .is_table = child.style.item_is_table,
            .is_replaced = child.style.item_is_replaced,
            .size_style = child.style.size,
            .min_size = .{ .width = child.style.min_size.width.resolve(0), .height = child.style.min_size.height.resolve(0) },
            .max_size = .{ .width = child.style.max_size.width.resolve(0), .height = child.style.max_size.height.resolve(0) },
            .overflow = child.style.overflow,
            .contain = child.style.contain,
            .scrollbar_width = child.style.scrollbar_width,
            .position = child.style.position,
            .inset = child.style.inset,
            .margin = child.style.margin,
            .can_be_collapsed_through = child.style.display == .block,
        });
    }
    return result;
}

fn resolve_stretch_height(item: *BlockItem, available_height: f32) void {
    item.computed_size.height = @max(0, available_height - item.padding_border_sum.height);
}

fn determine_content_based_container_width(natural_width: f32, inset: geometry.Rect(f32)) f32 {
    return @max(inset.horizontal_axis_sum(), natural_width + inset.horizontal_axis_sum());
}

fn perform_final_layout_on_in_flow_children(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, content_width: f32, parent_width: f32, inset: geometry.Rect(f32), block_context: *BlockContext) !void {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    var cursor_y = inset.top;
    var previous_bottom_margin = tree_layout.CollapsibleMarginSet.zero;
    for (node_data.children.items, 0..) |child_id, order| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        if (child.style.display == .none or child.style.position == .absolute) continue;
        const margins = resolve_auto_edges(child.style.margin, parent_width);
        if (style.float.float_direction(child.style.float)) |direction| {
            const float_width = child.style.size.width.resolve(content_width) orelse child.unrounded_layout.size.width;
            const float_height = child.style.size.height.resolve(content_width) orelse child.unrounded_layout.size.height;
            const position = block_context.place_floated_box(.{ .width = @max(0, float_width), .height = @max(0, float_height) }, cursor_y, direction, child.style.clear, false);
            _ = try tree_ref.compute_child_layout(child_id, .{
                .run_mode = .perform_layout,
                .sizing_mode = .inherent_size,
                .axis = .both,
                .known_dimensions = .{ .width = float_width, .height = float_height },
                .known_dimensions_are_definite = .{ .width = true, .height = true },
                .parent_size = .{ .width = content_width, .height = null },
                .available_space = .{ .width = .{ .definite = content_width }, .height = .max_content },
                .vertical_margins_are_collapsible = .{ .start = false, .end = false },
            });
            child.unrounded_layout.order = @intCast(order);
            child.unrounded_layout.location = .{ .x = position.x, .y = inset.top + position.y };
            child.unrounded_layout.size = .{ .width = @max(0, float_width), .height = @max(0, float_height) };
            child.final_layout = child.unrounded_layout;
            continue;
        }
        cursor_y += previous_bottom_margin.collapse_with_margin(margins.top).resolve();
        const content_slot = block_context.find_content_slot(cursor_y, child.style.clear, null);
        cursor_y = @max(cursor_y, content_slot.y);
        const child_width = child.style.size.width.resolve(content_slot.width) orelse @max(0, content_slot.width - margins.left - margins.right);
        const measured = try tree_ref.compute_child_layout(child_id, .{
            .run_mode = .perform_layout,
            .sizing_mode = .inherent_size,
            .axis = .both,
            .known_dimensions = .{ .width = child_width, .height = null },
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = .{ .width = content_slot.width, .height = null },
            .available_space = .{ .width = .{ .definite = content_slot.width }, .height = .max_content },
            .vertical_margins_are_collapsible = .{ .start = false, .end = false },
        });
        child.unrounded_layout.order = @intCast(order);
        child.unrounded_layout.location = .{ .x = content_slot.x + margins.left, .y = cursor_y };
        child.unrounded_layout.size = measured.size;
        child.unrounded_layout.size.width = @max(0, child_width);
        child.final_layout = child.unrounded_layout;
        cursor_y += child.unrounded_layout.size.height;
        previous_bottom_margin = tree_layout.CollapsibleMarginSet.from_margin(margins.bottom);
    }
}

fn perform_absolute_layout_on_absolute_children(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, content_width: f32, content_height: f32, inset: geometry.Rect(f32)) void {
    const node_data = tree_ref.node(node_id) orelse return;
    for (node_data.children.items, 0..) |child_id, order| {
        const child = tree_ref.node(child_id) orelse continue;
        if (child.style.position == .absolute) place_absolute_child(child, content_width, content_height, inset, @intCast(order));
    }
}

fn resolve_edges(value: geometry.Rect(style.dimension.LengthPercentage), basis: f32) geometry.Rect(f32) {
    return .{ .left = value.left.resolve(basis), .right = value.right.resolve(basis), .top = value.top.resolve(basis), .bottom = value.bottom.resolve(basis) };
}

fn resolve_auto_edges(value: geometry.Rect(style.dimension.LengthPercentageAuto), basis: f32) geometry.Rect(f32) {
    return .{ .left = value.left.resolve(basis) orelse 0, .right = value.right.resolve(basis) orelse 0, .top = value.top.resolve(basis) orelse 0, .bottom = value.bottom.resolve(basis) orelse 0 };
}

fn add_edges(a: geometry.Rect(f32), b: geometry.Rect(f32)) geometry.Rect(f32) {
    return .{ .left = a.left + b.left, .right = a.right + b.right, .top = a.top + b.top, .bottom = a.bottom + b.bottom };
}

fn place_absolute_child(child: *tree.NodeData, content_width: f32, content_height: f32, inset: geometry.Rect(f32), order: u32) void {
    var known_dimensions = geometry.Size(?f32){ .width = null, .height = null };
    sizing_keyword.resolve_absolute_sizing_keywords(
        &known_dimensions,
        child.style.size,
        .{ .width = content_width, .height = content_height },
        .{ .left = child.style.inset.left.resolve(content_width), .right = child.style.inset.right.resolve(content_width), .top = child.style.inset.top.resolve(content_height), .bottom = child.style.inset.bottom.resolve(content_height) },
        .{ .left = child.style.margin.left.resolve(content_width), .right = child.style.margin.right.resolve(content_width), .top = child.style.margin.top.resolve(content_width), .bottom = child.style.margin.bottom.resolve(content_width) },
    );
    if (known_dimensions.width) |value| child.unrounded_layout.size.width = value;
    if (known_dimensions.height) |value| child.unrounded_layout.size.height = value;
    const left = child.style.inset.left.resolve(content_width);
    const right = child.style.inset.right.resolve(content_width);
    const top = child.style.inset.top.resolve(content_height);
    const bottom = child.style.inset.bottom.resolve(content_height);
    const margins = resolve_auto_edges(child.style.margin, content_width);
    child.unrounded_layout.order = order;
    child.unrounded_layout.location.x = inset.left + (left orelse if (right) |value| content_width - value - child.unrounded_layout.size.width else 0) + margins.left;
    child.unrounded_layout.location.y = inset.top + (top orelse if (bottom) |value| content_height - value - child.unrounded_layout.size.height else 0) + margins.top;
    child.final_layout = child.unrounded_layout;
}

test "block flow collapses adjacent vertical margins" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .length(20) },
    });
    const second = try tree_ref.new_leaf(.{
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .zero(), .right = .zero(), .top = .length(10), .bottom = .zero() },
    });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .auto } }, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
    try testing.expectEqual(@as(f32, 30), (try tree_ref.layout_of(second)).location.y);
}

test "block child layout receives resolved width for percentage descendants" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .{ .value = .{ .percent = 1 } }, .height = .length(10) } });
    const child = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .{ .value = .{ .percent = 0.5 } }, .height = .auto }, .margin = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .zero() } }, &[_]tree.NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{ .display = .block }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(grandchild)).size.width);
}

test "block flow places floated children through the float context" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .float = .left, .size = .{ .width = .length(30), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(40) } }, &[_]tree.NodeId{floated});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    const result = try tree_ref.layout_of(floated);
    try testing.expectEqual(@as(f32, 0), result.location.x);
    try testing.expectEqual(@as(f32, 30), result.size.width);
}

test "block in-flow content uses the remaining float slot" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .float = .left, .size = .{ .width = .length(60), .height = .length(20) } });
    const content = try tree_ref.new_leaf(.{ .size = .{ .width = .auto, .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(40) } }, &[_]tree.NodeId{ floated, content });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    const result = try tree_ref.layout_of(content);
    try testing.expectEqual(@as(f32, 60), result.location.x);
    try testing.expectEqual(@as(f32, 40), result.size.width);
}

test "block floats honor horizontal content-box insets" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .float = .left, .size = .{ .width = .length(20), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .padding = .{ .left = .length(10), .right = .zero(), .top = .zero(), .bottom = .zero() }, .size = .{ .width = .length(100), .height = .length(30) } }, &[_]tree.NodeId{floated});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(floated)).location.x);
}

const std = @import("std");
