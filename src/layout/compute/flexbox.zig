//! CSS Flexbox layout algorithm.
//!
//! This file follows Taffy's `compute/flexbox.rs` phase order. The first
//! compiling implementation keeps the same intermediate records and names;
//! storage may differ where Zig requires it, but the phase boundaries and fixture
//! semantics.
//!
//! Phase order:
//! 1. resolve container constants and generate flex items;
//! 2. determine available main/cross space;
//! 3. determine flex base and hypothetical main sizes;
//! 4. collect items into lines;
//! 5. determine the container main size;
//! 6. resolve flexible lengths and freeze min/max violations;
//! 7. determine hypothetical and used cross sizes;
//! 8. align lines and perform the final layout pass.
//!
//! `baseline` uses the first measured baseline when supplied by a future
//! measure context and otherwise follows Taffy's no-baseline fallback. The
//! The compact callback ABI carries the available baseline fallback explicitly.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/mod.zig");
const flex_style = @import("../style/flex.zig");
const tree = @import("../tree/taffy_tree.zig");
const tree_layout = @import("../tree/layout.zig");
const alignment = @import("common/alignment.zig");

pub const FlexItem = struct {
    node: tree.NodeId,
    order: u32 = 0,
    size: geometry.Size(?f32) = .{ .width = null, .height = null },
    size_style: geometry.Size(style.dimension.Dimension) = .{ .width = .auto, .height = .auto },
    min_size: geometry.Size(?f32) = .{ .width = null, .height = null },
    max_size: geometry.Size(?f32) = .{ .width = null, .height = null },
    aspect_ratio: ?f32 = null,
    align_self: style.alignment.AlignSelf = style.alignment.AlignItems.stretch,
    overflow: geometry.Point(style.Overflow) = .{ .x = .visible, .y = .visible },
    contain: style.Contain = .{},
    scrollbar_width: f32 = 0,
    flex_shrink: f32 = 1,
    flex_grow: f32 = 0,
    flex_basis_is_definite: bool = false,
    resolved_minimum_main_size: f32 = 0,
    inset: geometry.Rect(?f32) = .{ .left = null, .right = null, .top = null, .bottom = null },
    margin: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    margin_is_auto: geometry.Rect(bool) = .{ .left = false, .right = false, .top = false, .bottom = false },
    padding: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    border: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    flex_basis: f32 = 0,
    inner_flex_basis: f32 = 0,
    violation: f32 = 0,
    frozen: bool = false,
    content_flex_fraction: f32 = 0,
    hypothetical_inner_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    hypothetical_outer_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    target_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    outer_target_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    baseline: f32 = 0,
    offset_main: f32 = 0,
    offset_cross: f32 = 0,

    pub fn is_scroll_container(self: FlexItem) bool {
        return self.overflow.x.is_scroll_container() or self.overflow.y.is_scroll_container();
    }

    pub fn participates_in_baseline_alignment(self: FlexItem, direction: flex_style.FlexDirection) bool {
        return self.align_self.keyword == .baseline and
            !self.margin_is_auto.cross_start(direction) and
            !self.margin_is_auto.cross_end(direction);
    }
};

pub const FlexLine = struct {
    items: []FlexItem,
    cross_size: f32 = 0,
    offset_cross: f32 = 0,
};

pub const AlgoConstants = struct {
    dir: flex_style.FlexDirection,
    layout_direction: style.Direction,
    is_row: bool,
    is_column: bool,
    is_wrap: bool,
    is_wrap_reverse: bool,
    min_size: geometry.Size(?f32),
    max_size: geometry.Size(?f32),
    margin: geometry.Rect(f32),
    border: geometry.Rect(f32),
    content_box_inset: geometry.Rect(f32),
    scrollbar_gutter: geometry.Point(f32),
    gap: geometry.Size(f32),
    align_items: style.alignment.AlignItems,
    align_content: style.alignment.AlignContent,
    justify_content: ?style.alignment.JustifyContent,
    node_outer_size: geometry.Size(?f32),
    node_inner_size: geometry.Size(?f32),
    known_main_size_is_definite: bool,
    has_definite_main_size: bool,
    has_definite_cross_size: bool,
    cross_axis_available_space_is_definite: bool,
    container_size: geometry.Size(f32),
    inner_container_size: geometry.Size(f32),

    pub fn divided_cross_space(self: AlgoConstants, available_space: f32) f32 {
        _ = self;
        return available_space;
    }
};

pub fn compute_flexbox_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, inputs: tree_layout.LayoutInput) !tree_layout.LayoutOutput {
    const node_style = try tree_ref.style_of(node_id);
    if (node_style.display != .flex) return error.InvalidLayoutMode;
    return compute_preliminary(tree_ref, node_id, inputs);
}

/// Taffy 9.1.1–9.1.2 preliminary flex pass. Children have already been
/// measured by `compute/mod.zig`; this function resolves their flex items and
/// runs the remaining phases in order.
fn compute_preliminary(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, inputs: tree_layout.LayoutInput) !tree_layout.LayoutOutput {
    const node_style = try tree_ref.style_of(node_id);
    const parent_width = inputs.parent_size.width orelse inputs.available_space.width.into_option();
    const parent_height = inputs.parent_size.height orelse inputs.available_space.height.into_option();
    const padding = resolve_edges(node_style.padding, parent_width orelse 0);
    const border = resolve_edges(node_style.border, parent_width orelse 0);
    const inset = add_edges(padding, border);
    const row = flex_style.is_row(node_style.flex_direction);
    const gap = geometry.Size(f32){ .width = node_style.gap.width.resolve(parent_width orelse 0), .height = node_style.gap.height.resolve(parent_width orelse 0) };

    var items = try generate_anonymous_flex_items(tree_ref, node_id, row, parent_width, parent_height, inset);
    defer items.deinit(tree_ref.allocator);
    const constants = compute_constants(node_style, inputs, padding, border, gap);
    const available_main_cross = determine_available_space(constants, inputs.available_space);
    _ = available_main_cross;

    const natural = natural_size(items.items, row, gap, inset);
    const styled_width = node_style.size.width.resolve(parent_width);
    const styled_height = node_style.size.height.resolve(parent_height);
    const styled_width_adjusted = if (node_style.box_sizing == .content_box) if (styled_width) |value| value + inset.horizontal_axis_sum() else null else styled_width;
    const styled_height_adjusted = if (node_style.box_sizing == .content_box) if (styled_height) |value| value + inset.vertical_axis_sum() else null else styled_height;
    const width_unclamped = inputs.known_dimensions.width orelse styled_width_adjusted orelse inputs.available_space.width.into_option() orelse natural.width + inset.horizontal_axis_sum();
    const height_unclamped = inputs.known_dimensions.height orelse styled_height_adjusted orelse inputs.available_space.height.into_option() orelse natural.height + inset.vertical_axis_sum();
    const width = style.dimension.clamp_resolved_size(width_unclamped, node_style.min_size.width, node_style.max_size.width, parent_width orelse width_unclamped);
    const height = style.dimension.clamp_resolved_size(height_unclamped, node_style.min_size.height, node_style.max_size.height, parent_height orelse height_unclamped);
    const outer = geometry.Size(f32){ .width = @max(inset.horizontal_axis_sum(), width), .height = @max(inset.vertical_axis_sum(), height) };
    const content = geometry.Size(f32){ .width = @max(0, outer.width - inset.horizontal_axis_sum()), .height = @max(0, outer.height - inset.vertical_axis_sum()) };
    _ = determine_container_main_size(constants, content, natural, row);
    calculate_children_base_lines(items.items, row);

    const flex_lines = if (flex_style.is_balance(node_style.flex_wrap))
        try collect_balanced_flex_lines(tree_ref.allocator, items.items, node_style.flex_wrap, row, gap, content, node_style.flex_line_count)
    else
        try collect_flex_lines(tree_ref.allocator, items.items, node_style.flex_wrap, row, gap, content);
    defer {
        for (flex_lines) |line| tree_ref.allocator.free(line.items);
        tree_ref.allocator.free(flex_lines);
    }
    for (flex_lines) |*line| {
        line.cross_size = line_cross_size(line.items, row);
    }
    const cross_available = if (row) content.height else content.width;
    const cross_gap = if (row) gap.height else gap.width;
    var used_cross: f32 = if (flex_lines.len > 1) cross_gap * @as(f32, @floatFromInt(flex_lines.len - 1)) else 0;
    for (flex_lines) |line| used_cross += line.cross_size;
    const cross_free = cross_available - used_cross;
    const align_content = node_style.align_content orelse style.alignment.AlignContent.stretch;
    const align_keyword = alignment.apply_alignment_fallback(cross_free, flex_lines.len, align_content);
    const stretch_extra = if (align_keyword == .stretch and cross_free > 0) cross_free / @as(f32, @floatFromInt(flex_lines.len)) else 0;
    const distributed_line_gap = cross_gap + if (flex_lines.len <= 1 or cross_free <= 0) 0 else switch (align_keyword) {
        .space_between => cross_free / @as(f32, @floatFromInt(flex_lines.len - 1)),
        .space_around => cross_free / @as(f32, @floatFromInt(flex_lines.len)),
        .space_evenly => cross_free / @as(f32, @floatFromInt(flex_lines.len + 1)),
        else => 0,
    };
    const leading_offset = alignment.compute_alignment_offset(cross_free, flex_lines.len, cross_gap, align_keyword, false, true);
    var cross_cursor: f32 = if (flex_style.is_reverse_wrap(node_style.flex_wrap)) cross_available - leading_offset else leading_offset;
    for (flex_lines) |*line| {
        const line_cross = line.cross_size + stretch_extra;
        resolve_flexible_lengths(line.items, content, row, gap, node_style);
        calculate_cross_sizes(line.items, row, node_style, gap, line_cross);
        const line_offset = if (flex_style.is_reverse_wrap(node_style.flex_wrap)) blk: {
            cross_cursor -= line_cross;
            cross_cursor -= distributed_line_gap;
            const offset = cross_cursor + distributed_line_gap;
            break :blk offset;
        } else blk: {
            const offset = cross_cursor;
            cross_cursor += line_cross + distributed_line_gap;
            break :blk offset;
        };
        try final_layout_pass(tree_ref, line.items, outer, content, row, gap, node_style, inset, line_offset, line_cross);
    }
    perform_absolute_layout_on_absolute_children(tree_ref, node_id, content, inset);
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    node_data.unrounded_layout.size = outer;
    node_data.unrounded_layout.border = border;
    node_data.unrounded_layout.padding = padding;
    node_data.final_layout = node_data.unrounded_layout;
    return tree_layout.LayoutOutput.from_outer_size(outer);
}

fn compute_constants(node_style: style.Style, inputs: tree_layout.LayoutInput, padding: geometry.Rect(f32), border: geometry.Rect(f32), gap: geometry.Size(f32)) AlgoConstants {
    const direction = node_style.flex_direction;
    const is_row = flex_style.is_row(direction);
    const node_outer_size = inputs.known_dimensions;
    const node_inner_size = geometry.Size(?f32){
        .width = if (node_outer_size.width) |value| @max(0, value - padding.horizontal_axis_sum() - border.horizontal_axis_sum()) else null,
        .height = if (node_outer_size.height) |value| @max(0, value - padding.vertical_axis_sum() - border.vertical_axis_sum()) else null,
    };
    return .{
        .dir = direction,
        .layout_direction = node_style.direction,
        .is_row = is_row,
        .is_column = !is_row,
        .is_wrap = flex_style.is_multi_line(node_style.flex_wrap),
        .is_wrap_reverse = flex_style.is_reverse_wrap(node_style.flex_wrap),
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .border = border,
        .content_box_inset = padding.add(border),
        .scrollbar_gutter = .{ .x = 0, .y = 0 },
        .gap = gap,
        .align_items = node_style.align_items orelse style.alignment.AlignItems.stretch,
        .align_content = node_style.align_content orelse style.alignment.AlignContent.stretch,
        .justify_content = node_style.justify_content,
        .node_outer_size = node_outer_size,
        .node_inner_size = node_inner_size,
        .known_main_size_is_definite = if (is_row) inputs.known_dimensions_are_definite.width else inputs.known_dimensions_are_definite.height,
        .has_definite_main_size = if (is_row) node_outer_size.width != null else node_outer_size.height != null,
        .has_definite_cross_size = if (is_row) node_outer_size.height != null else node_outer_size.width != null,
        .cross_axis_available_space_is_definite = if (is_row) inputs.available_space.height.is_definite() else inputs.available_space.width.is_definite(),
        .container_size = .{ .width = node_outer_size.width orelse 0, .height = node_outer_size.height orelse 0 },
        .inner_container_size = .{ .width = node_inner_size.width orelse 0, .height = node_inner_size.height orelse 0 },
    };
}

fn determine_available_space(constants: AlgoConstants, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) geometry.Size(@import("../style/available_space.zig").AvailableSpace) {
    _ = constants;
    return available_space;
}

fn content_size_hint(inputs: tree_layout.LayoutInput) geometry.Size(f32) {
    return .{ .width = inputs.known_dimensions.width orelse inputs.available_space.width.into_option() orelse 0, .height = inputs.known_dimensions.height orelse inputs.available_space.height.into_option() orelse 0 };
}

fn generate_anonymous_flex_items(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, row: bool, parent_width: ?f32, parent_height: ?f32, inset: geometry.Rect(f32)) !std.ArrayList(FlexItem) {
    var items = std.ArrayList(FlexItem).empty;
    const children = (tree_ref.node(node_id) orelse return error.InvalidInputNode).children.items;
    for (children, 0..) |child_id, order| {
        const child = tree_ref.node(child_id) orelse return error.InvalidChildNode;
        if (child.style.display == .none or child.style.position == .absolute) continue;
        const measured = child.unrounded_layout.size;
        const margin = resolve_auto_edges(child.style.margin, parent_width orelse 0);
        const margin_auto = auto_edges(child.style.margin);
        const basis_style = child.style.flex_basis;
        const basis = basis_style.resolve(if (row) parent_width else parent_height) orelse if (row) measured.width else measured.height;
        const min_size = resolve_auto_dimensions(child.style.min_size, parent_width, parent_height);
        const max_size = resolve_auto_dimensions(child.style.max_size, parent_width, parent_height);
        var item = FlexItem{
            .node = child_id,
            .order = @intCast(order),
            .size = .{ .width = measured.width, .height = measured.height },
            .size_style = child.style.size,
            .min_size = min_size,
            .max_size = max_size,
            .aspect_ratio = child.style.aspect_ratio,
            .align_self = child.style.align_self orelse style.alignment.AlignItems.stretch,
            .overflow = child.style.overflow,
            .contain = child.style.contain,
            .scrollbar_width = child.style.scrollbar_width,
            .flex_shrink = child.style.flex_shrink,
            .flex_grow = child.style.flex_grow,
            .flex_basis_is_definite = basis_style.is_definite(),
            .resolved_minimum_main_size = if (row) min_size.width orelse 0 else min_size.height orelse 0,
            .margin = margin,
            .margin_is_auto = margin_auto,
            .padding = resolve_edges(child.style.padding, parent_width orelse 0),
            .border = resolve_edges(child.style.border, parent_width orelse 0),
            .flex_basis = @max(0, basis),
            .inner_flex_basis = @max(0, basis - if (row) inset.horizontal_axis_sum() else inset.vertical_axis_sum()),
            .hypothetical_inner_size = measured,
            .hypothetical_outer_size = .{ .width = measured.width + margin.left + margin.right, .height = measured.height + margin.top + margin.bottom },
            .target_size = measured,
        };
        determine_flex_base_size(&item, row);
        try items.append(tree_ref.allocator, item);
    }
    return items;
}

fn determine_flex_base_size(item: *FlexItem, row: bool) void {
    const main_size = (if (row) item.size.width else item.size.height) orelse 0;
    if (!item.flex_basis_is_definite and main_size > 0) item.flex_basis = main_size;
    item.inner_flex_basis = @max(0, item.flex_basis);
}

fn item_known_dimension_definiteness(constants: AlgoConstants, item: FlexItem) geometry.Size(bool) {
    _ = constants;
    return .{ .width = item.size.width != null, .height = item.size.height != null };
}

fn determine_container_main_size(constants: AlgoConstants, content: geometry.Size(f32), natural: geometry.Size(f32), row: bool) f32 {
    if (constants.has_definite_main_size) return if (row) content.width else content.height;
    return if (row) natural.width else natural.height;
}

fn determine_hypothetical_cross_size(item: FlexItem, row: bool) f32 {
    const value = if (row) item.hypothetical_inner_size.height else item.hypothetical_inner_size.width;
    const min_value = if (row) item.min_size.height else item.min_size.width;
    const max_value = if (row) item.max_size.height else item.max_size.width;
    return @min(max_value orelse value, @max(min_value orelse 0, value));
}

fn calculate_children_base_lines(items: []FlexItem, row: bool) void {
    for (items) |*item| item.baseline = determine_hypothetical_cross_size(item.*, row);
}

fn calculate_cross_size(items: []const FlexItem, row: bool) f32 {
    return line_cross_size(items, row);
}

fn handle_align_content_stretch(lines: []FlexLine, free_space: f32) void {
    if (free_space <= 0 or lines.len == 0) return;
    const share = free_space / @as(f32, @floatFromInt(lines.len));
    for (lines) |*line| line.cross_size += share;
}

fn determine_used_cross_size(items: []const FlexItem, row: bool) f32 {
    return line_cross_size(items, row);
}

fn distribute_remaining_free_space(items: []FlexItem, free_space: f32, row: bool) void {
    if (items.len == 0 or free_space == 0) return;
    const share = free_space / @as(f32, @floatFromInt(items.len));
    for (items) |*item| if (!item.frozen) {
        if (row) item.target_size.width += share else item.target_size.height += share;
    };
}

fn resolve_cross_axis_auto_margins(items: []FlexItem, row: bool, free_space: f32) void {
    if (free_space <= 0) return;
    var count: usize = 0;
    for (items) |item| {
        if (row) {
            if (item.margin_is_auto.top) count += 1;
            if (item.margin_is_auto.bottom) count += 1;
        } else {
            if (item.margin_is_auto.left) count += 1;
            if (item.margin_is_auto.right) count += 1;
        }
    }
    if (count == 0) return;
    const share = free_space / @as(f32, @floatFromInt(count));
    for (items) |*item| {
        if (row) {
            if (item.margin_is_auto.top) item.margin.top = share;
            if (item.margin_is_auto.bottom) item.margin.bottom = share;
        } else {
            if (item.margin_is_auto.left) item.margin.left = share;
            if (item.margin_is_auto.right) item.margin.right = share;
        }
    }
}

fn align_flex_items_along_cross_axis(items: []FlexItem, row: bool, line_cross: f32) void {
    for (items) |*item| {
        const cross = determine_hypothetical_cross_size(item.*, row);
        const margins = if (row) item.margin.top + item.margin.bottom else item.margin.left + item.margin.right;
        const free_space = @max(0, line_cross - cross - margins);
        item.offset_cross = switch (item.align_self.keyword) {
            .end, .flex_end => free_space,
            .center => free_space / 2,
            else => 0,
        };
    }
}

fn determine_container_cross_size(items: []const FlexItem, row: bool, available: f32) f32 {
    return @max(available, line_cross_size(items, row));
}

fn align_flex_lines_per_align_content(lines: []FlexLine, free_space: f32, alignment_style: style.alignment.AlignContentKeyword) f32 {
    const offset = alignment.compute_alignment_offset(free_space, lines.len, 0, alignment_style, false, true);
    if (alignment_style == .stretch) handle_align_content_stretch(lines, free_space);
    return offset;
}

fn sum_axis_gaps(gap: f32, item_count: usize) f32 {
    return if (item_count > 1) gap * @as(f32, @floatFromInt(item_count - 1)) else 0;
}

fn collect_flex_lines(allocator: std.mem.Allocator, items: []const FlexItem, wrap: flex_style.FlexWrap, row: bool, gap: geometry.Size(f32), content: geometry.Size(f32)) ![]FlexLine {
    const available_main = if (row) content.width else content.height;
    const main_gap = if (row) gap.width else gap.height;
    const should_wrap = flex_style.is_multi_line(wrap) and available_main > 0;
    var line_count: usize = 1;
    var used: f32 = 0;
    for (items, 0..) |item, index| {
        const item_main = item.flex_basis + if (row) item.margin.left + item.margin.right else item.margin.top + item.margin.bottom;
        const candidate = used + item_main + if (index == 0 or used == 0) 0 else main_gap;
        if (should_wrap and used > 0 and candidate > available_main) {
            line_count += 1;
            used = item_main;
        } else {
            used = candidate;
        }
    }

    const lines = try allocator.alloc(FlexLine, line_count);
    var starts = try allocator.alloc(usize, line_count + 1);
    defer allocator.free(starts);
    starts[0] = 0;
    var current_line: usize = 0;
    used = 0;
    for (items, 0..) |item, index| {
        const item_main = item.flex_basis + if (row) item.margin.left + item.margin.right else item.margin.top + item.margin.bottom;
        const candidate = used + item_main + if (index == starts[current_line] or used == 0) 0 else main_gap;
        if (should_wrap and used > 0 and candidate > available_main) {
            current_line += 1;
            starts[current_line] = index;
            used = item_main;
        } else {
            used = candidate;
        }
    }
    starts[line_count] = items.len;
    for (0..line_count) |line_index| {
        const start = starts[line_index];
        const end = starts[line_index + 1];
        const line_items = try allocator.alloc(FlexItem, end - start);
        @memcpy(line_items, items[start..end]);
        lines[line_index] = .{ .items = line_items };
    }
    return lines;
}

/// Prefix sums and constraints shared by the Rust balance implementation's
/// scoring and readback phases. Sizes are kept as f64 so squared costs do not
/// lose the tie-breaking behavior of the reference algorithm.
pub const LineSizes = struct {
    sums: []f64,
    zero_items: []bool,
    gap_between_items: f64,
    limit: f64,

    pub fn item_count(self: LineSizes) usize {
        return self.sums.len;
    }

    pub fn is_zero_item(self: LineSizes, index: usize) bool {
        return self.zero_items[index];
    }

    /// Return the size of the inclusive item range `start..end`.
    pub fn line_size(self: LineSizes, start: usize, end: usize) f64 {
        const before = if (start == 0) 0 else self.sums[start - 1];
        return self.sums[end] - before - self.gap_between_items;
    }

    pub fn line_cost(self: LineSizes, start: usize, end: usize) f64 {
        const size = self.line_size(start, end);
        if (end > start and size > self.limit) return std.math.inf(f64);
        return size * size;
    }
};

fn to_size(value: f32) f64 {
    if (std.math.isNan(value)) return 0;
    return @floatCast(@max(0, @min(value, std.math.floatMax(f32))));
}

fn make_line_sizes(allocator: std.mem.Allocator, items: []const FlexItem, row: bool, gap: f32, limit: f32) !LineSizes {
    var sums = try allocator.alloc(f64, items.len);
    errdefer allocator.free(sums);
    var zeros = try allocator.alloc(bool, items.len);
    errdefer allocator.free(zeros);
    var sum: f64 = 0;
    const gap_value: f64 = to_size(gap);
    for (items, 0..) |item, index| {
        const item_size = if (row) item.hypothetical_outer_size.width else item.hypothetical_outer_size.height;
        const sized = to_size(item_size);
        sum += sized + gap_value;
        sums[index] = sum;
        zeros[index] = sized == 0;
    }
    return .{ .sums = sums, .zero_items = zeros, .gap_between_items = gap_value, .limit = if (std.math.isInf(limit)) std.math.inf(f64) else @floatCast(limit) };
}

/// Greedy line count used by the balance algorithm to determine the smallest
/// valid number of lines before applying the requested `flex-line-count`.
pub fn greedy_line_count(sizes: LineSizes) usize {
    if (sizes.item_count() == 0) return 0;
    var count: usize = 1;
    var start: usize = 0;
    while (start < sizes.item_count()) {
        var end = start;
        while (end < sizes.item_count() and sizes.line_size(start, end) <= sizes.limit) : (end += 1) {}
        if (end == start) end += 1;
        start = end;
        if (start < sizes.item_count()) count += 1;
    }
    return count;
}

fn zero_boundary_valid(sizes: LineSizes, min_errors: []const f64, lines: usize, start: usize, end: usize) bool {
    if (end + 1 >= sizes.item_count() or !sizes.is_zero_item(end + 1)) return true;
    var glued = end + 1;
    while (glued <= sizes.item_count() - lines and sizes.line_size(start, glued) <= sizes.limit) : (glued += 1) {
        if (min_errors[(lines - 2) * sizes.item_count() + glued + 1] != std.math.inf(f64)) return false;
    }
    return true;
}

/// Naive dynamic-programming oracle retained as a named port of Taffy's test
/// helper. It is intentionally separate from the optimized readback function
/// so future balance changes can compare both implementations.
pub fn naive_line_item_counts(allocator: std.mem.Allocator, item_sizes: []const f32, line_limit: f32, gap: f32, min_line_count: usize) ![]usize {
    if (item_sizes.len == 0) return allocator.alloc(usize, 0);
    var sums = try allocator.alloc(f64, item_sizes.len);
    defer allocator.free(sums);
    var zeros = try allocator.alloc(bool, item_sizes.len);
    defer allocator.free(zeros);
    var sum: f64 = 0;
    const gap_value = to_size(gap);
    for (item_sizes, 0..) |value, index| {
        const sized = to_size(value);
        sum += sized + gap_value;
        sums[index] = sum;
        zeros[index] = sized == 0;
    }
    const sizes = LineSizes{ .sums = sums, .zero_items = zeros, .gap_between_items = gap_value, .limit = @floatCast(line_limit) };
    const item_count = item_sizes.len;
    const line_count = @max(greedy_line_count(sizes), @min(@max(min_line_count, 1), item_count));
    var errors = try allocator.alloc(f64, (line_count + 1) * item_count);
    defer allocator.free(errors);
    @memset(errors, std.math.inf(f64));
    for (0..item_count) |start| errors[start] = sizes.line_cost(start, item_count - 1);
    for (2..line_count + 1) |lines| {
        const row_start = (lines - 1) * item_count;
        const previous = (lines - 2) * item_count;
        for (0..item_count) |start| {
            if (item_count - start < lines) continue;
            var end = start;
            while (end + lines <= item_count) : (end += 1) {
                const cost = sizes.line_cost(start, end);
                if (cost == std.math.inf(f64)) break;
                if (!zero_boundary_valid(sizes, errors, lines, start, end)) continue;
                errors[row_start + start] = @min(errors[row_start + start], cost + errors[previous + end + 1]);
            }
        }
    }
    var result = try allocator.alloc(usize, line_count);
    var start: usize = 0;
    var output_index: usize = 0;
    while (output_index < line_count) : (output_index += 1) {
        const lines_after = line_count - output_index - 1;
        const target = errors[lines_after * item_count + start];
        var end = item_count - 1 - lines_after;
        while (true) {
            const cost = sizes.line_cost(start, end);
            const remaining = if (lines_after == 0) 0 else errors[(lines_after - 1) * item_count + end + 1];
            if (cost != std.math.inf(f64) and zero_boundary_valid(sizes, errors, lines_after + 1, start, end) and cost + remaining == target) break;
            if (end == start) break;
            end -= 1;
        }
        result[output_index] = end - start + 1;
        start = end + 1;
    }
    return result;
}

/// Balance contiguous flex items by minimizing the sum of squared line sizes.
/// This is O(lines * items^2), matching the reference oracle first; the
/// divide-and-conquer optimization can be added once the same tie behavior is
/// covered by the Zig fixture suite.
pub fn balanced_line_item_counts(allocator: std.mem.Allocator, item_sizes: []const f32, line_limit: f32, gap: f32, min_line_count: usize) ![]usize {
    return naive_line_item_counts(allocator, item_sizes, line_limit, gap, min_line_count);
}

fn collect_balanced_flex_lines(allocator: std.mem.Allocator, items: []const FlexItem, wrap: flex_style.FlexWrap, row: bool, gap: geometry.Size(f32), content: geometry.Size(f32), min_line_count: u16) ![]FlexLine {
    if (items.len == 0) return allocator.alloc(FlexLine, 0);
    const main_gap = if (row) gap.width else gap.height;
    const main_limit = if (row) content.width else content.height;
    const sizes = try make_line_sizes(allocator, items, row, main_gap, main_limit);
    defer {
        allocator.free(sizes.sums);
        allocator.free(sizes.zero_items);
    }
    var item_sizes = try allocator.alloc(f32, items.len);
    defer allocator.free(item_sizes);
    for (items, 0..) |item, index| item_sizes[index] = if (row) item.hypothetical_outer_size.width else item.hypothetical_outer_size.height;
    const counts = try balanced_line_item_counts(allocator, item_sizes, main_limit, main_gap, min_line_count);
    defer allocator.free(counts);
    var lines = try allocator.alloc(FlexLine, counts.len);
    var start: usize = 0;
    for (counts, 0..) |count, index| {
        const line_items = try allocator.alloc(FlexItem, count);
        @memcpy(line_items, items[start .. start + count]);
        lines[index] = .{ .items = line_items };
        start += count;
    }
    _ = wrap;
    return lines;
}

fn line_cross_size(items: []const FlexItem, row: bool) f32 {
    var result: f32 = 0;
    for (items) |item| result = @max(result, if (row) item.hypothetical_outer_size.height else item.hypothetical_outer_size.width);
    return result;
}

fn natural_size(items: []const FlexItem, row: bool, gap: geometry.Size(f32), inset: geometry.Rect(f32)) geometry.Size(f32) {
    _ = inset;
    var main: f32 = 0;
    var cross: f32 = 0;
    for (items, 0..) |item, index| {
        if (index != 0) main += if (row) gap.width else gap.height;
        main += item.flex_basis + if (row) item.margin.left + item.margin.right else item.margin.top + item.margin.bottom;
        cross = @max(cross, if (row) item.hypothetical_outer_size.height else item.hypothetical_outer_size.width);
    }
    return if (row) .{ .width = main, .height = cross } else .{ .width = cross, .height = main };
}

fn resolve_flexible_lengths(items: []FlexItem, content: geometry.Size(f32), row: bool, gap: geometry.Size(f32), container: style.Style) void {
    if (items.len == 0) return;
    const available_main = if (row) content.width else content.height;
    const main_gap = if (row) gap.width else gap.height;
    for (items) |*item| {
        item.target_size = .{ .width = item.size.width orelse 0, .height = item.size.height orelse 0 };
        item.frozen = false;
        item.violation = 0;
    }
    var iteration: usize = 0;
    while (iteration < items.len + 2) : (iteration += 1) {
        var used: f32 = if (items.len > 1) main_gap * @as(f32, @floatFromInt(items.len - 1)) else 0;
        var grow_total: f32 = 0;
        var shrink_total: f32 = 0;
        for (items) |item| {
            const margin = if (row) item.margin.left + item.margin.right else item.margin.top + item.margin.bottom;
            used += if (item.frozen) flex_item_main_target(item, row) else item.flex_basis;
            used += margin;
            if (!item.frozen) {
                grow_total += @max(0, item.flex_grow);
                shrink_total += @max(0, item.flex_basis * item.flex_shrink);
            }
        }
        const free = available_main - used;
        if (@abs(free) < 0.0001 or (free >= 0 and grow_total == 0) or (free < 0 and shrink_total == 0)) {
            for (items) |*item| {
                if (!item.frozen) item.frozen = true;
            }
            break;
        }
        var froze_any = false;
        for (items) |*item| {
            if (item.frozen) continue;
            const proposed = if (free > 0)
                item.flex_basis + free * @max(0, item.flex_grow) / grow_total
            else
                item.flex_basis + free * @max(0, item.flex_basis * item.flex_shrink) / shrink_total;
            const min_value = if (row) item.min_size.width else item.min_size.height;
            const max_value = if (row) item.max_size.width else item.max_size.height;
            const target = @min(max_value orelse proposed, @max(min_value orelse 0, proposed));
            item.violation = target - proposed;
            if (row) item.target_size.width = target else item.target_size.height = target;
            if (@abs(target - proposed) > 0.0001) {
                item.frozen = true;
                froze_any = true;
            }
        }
        if (!froze_any) {
            for (items) |*item| item.frozen = true;
        }
    }
    _ = container;
}

fn flex_item_main_target(item: FlexItem, row: bool) f32 {
    return if (row) item.target_size.width else item.target_size.height;
}

fn calculate_cross_sizes(items: []FlexItem, row: bool, container: style.Style, gap: geometry.Size(f32), line_cross: f32) void {
    _ = gap;
    const cross_available = line_cross;
    for (items) |*item| {
        const alignment_value = item.align_self;
        const auto_cross = if (row) item.size_style.height.value == .auto else item.size_style.width.value == .auto;
        if (alignment_value.keyword == .stretch and auto_cross and cross_available > 0) {
            if (row) item.target_size.height = @max(0, cross_available - item.margin.top - item.margin.bottom) else item.target_size.width = @max(0, cross_available - item.margin.left - item.margin.right);
        }
        item.baseline = if (row) item.target_size.height else item.target_size.width;
    }
    _ = container;
}

fn final_layout_pass(tree_ref: *tree.TaffyTree, items: []FlexItem, outer: geometry.Size(f32), content: geometry.Size(f32), row: bool, gap: geometry.Size(f32), container: style.Style, inset: geometry.Rect(f32), line_offset: f32, line_cross: f32) !void {
    _ = outer;
    var used: f32 = 0;
    var auto_margin_count: usize = 0;
    for (items) |item| used += if (row) item.target_size.width + item.margin.left + item.margin.right else item.target_size.height + item.margin.top + item.margin.bottom;
    for (items) |item| {
        if (row) {
            if (item.margin_is_auto.left) auto_margin_count += 1;
            if (item.margin_is_auto.right) auto_margin_count += 1;
        } else {
            if (item.margin_is_auto.top) auto_margin_count += 1;
            if (item.margin_is_auto.bottom) auto_margin_count += 1;
        }
    }
    if (items.len > 1) used += (if (row) gap.width else gap.height) * @as(f32, @floatFromInt(items.len - 1));
    const main_available = if (row) content.width else content.height;
    const free = @max(0, main_available - used);
    const auto_margin_size = if (auto_margin_count > 0) free / @as(f32, @floatFromInt(auto_margin_count)) else 0;
    const justify = container.justify_content orelse style.alignment.JustifyContent.start;
    const justify_free = if (auto_margin_count > 0) 0 else free;
    const main_gap = if (row) gap.width else gap.height;
    const distributed_gap = main_gap + if (items.len <= 1 or auto_margin_count > 0) 0 else switch (justify.keyword) {
        .space_between => justify_free / @as(f32, @floatFromInt(items.len - 1)),
        .space_around => justify_free / @as(f32, @floatFromInt(items.len)),
        .space_evenly => justify_free / @as(f32, @floatFromInt(items.len + 1)),
        else => 0,
    };
    const start = alignment.compute_alignment_offset(justify_free, items.len, main_gap, justify.keyword, false, true);
    const reverse = flex_style.is_reverse(container.flex_direction);
    var cursor = if (reverse) main_available - start else start;
    for (items) |*item| {
        _ = try tree_ref.compute_child_layout(item.node, .{
            .run_mode = .perform_layout,
            .sizing_mode = .inherent_size,
            .axis = .both,
            .known_dimensions = .{ .width = item.target_size.width, .height = item.target_size.height },
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = .{ .width = content.width, .height = content.height },
            .available_space = .{ .width = .{ .definite = content.width }, .height = .{ .definite = content.height } },
            .vertical_margins_are_collapsible = .{ .start = false, .end = false },
        });
        const node_data = tree_ref.node(item.node) orelse continue;
        const main_margin_start = if (row) item.margin.left else item.margin.top;
        const main_margin_end = if (row) item.margin.right else item.margin.bottom;
        const auto_start = if (row) item.margin_is_auto.left else item.margin_is_auto.top;
        const auto_end = if (row) item.margin_is_auto.right else item.margin_is_auto.bottom;
        const resolved_margin_start = if (auto_start) auto_margin_size else main_margin_start;
        const resolved_margin_end = if (auto_end) auto_margin_size else main_margin_end;
        const item_main_size = if (row) item.target_size.width else item.target_size.height;
        const main_position = if (reverse) blk: {
            cursor -= resolved_margin_start;
            const position = cursor - item_main_size;
            cursor -= item_main_size + resolved_margin_end + distributed_gap;
            break :blk position;
        } else blk: {
            cursor += resolved_margin_start;
            const position = cursor;
            cursor += item_main_size + resolved_margin_end + distributed_gap;
            break :blk position;
        };
        const cross_size = if (row) item.target_size.height else item.target_size.width;
        const cross_available = line_cross;
        const cross_margin_start = if (row) item.margin.top else item.margin.left;
        const cross_margin_end = if (row) item.margin.bottom else item.margin.right;
        const cross_auto_start = if (row) item.margin_is_auto.top else item.margin_is_auto.left;
        const cross_auto_end = if (row) item.margin_is_auto.bottom else item.margin_is_auto.right;
        const non_auto_cross_margin = cross_margin_start + cross_margin_end;
        const cross_free = @max(0, cross_available - cross_size - non_auto_cross_margin);
        const cross_auto_count: usize = @intFromBool(cross_auto_start) + @intFromBool(cross_auto_end);
        const cross_auto_space = if (cross_auto_count > 0) cross_free / @as(f32, @floatFromInt(cross_auto_count)) else 0;
        const resolved_cross_start = if (cross_auto_start) cross_auto_space else cross_margin_start;
        const cross_overflows = cross_size + non_auto_cross_margin > cross_available;
        const cross_keyword = alignment.resolve_self_alignment_safety(item.align_self, cross_overflows);
        const alignment_offset = if (cross_auto_count > 0) 0 else switch (cross_keyword) {
            .end, .flex_end => cross_free,
            .center => cross_free / 2,
            else => 0,
        };
        node_data.unrounded_layout.location = if (row)
            .{ .x = inset.left + main_position, .y = inset.top + line_offset + resolved_cross_start + alignment_offset }
        else
            .{ .x = inset.left + resolved_cross_start + alignment_offset, .y = inset.top + line_offset + main_position };
        node_data.unrounded_layout.size = item.target_size;
        node_data.final_layout = node_data.unrounded_layout;
    }
}

/// Flex absolute-positioned children are removed from flex-line collection,
/// then laid out against the flex container's padding-box. Both insets win
/// over the child's intrinsic size when they are simultaneously specified.
fn perform_absolute_layout_on_absolute_children(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, content: geometry.Size(f32), inset: geometry.Rect(f32)) void {
    const parent = tree_ref.node(node_id) orelse return;
    for (parent.children.items, 0..) |child_id, order| {
        const child = tree_ref.node(child_id) orelse continue;
        if (child.style.position != .absolute) continue;
        const margin = resolve_auto_edges(child.style.margin, content.width);
        const left = child.style.inset.left.resolve(content.width);
        const right = child.style.inset.right.resolve(content.width);
        const top = child.style.inset.top.resolve(content.height);
        const bottom = child.style.inset.bottom.resolve(content.height);
        const width = if (child.style.size.width.resolve(content.width)) |value| value else if (left != null and right != null) @max(0, content.width - left.? - right.? - margin.left - margin.right) else child.unrounded_layout.size.width;
        const height = if (child.style.size.height.resolve(content.height)) |value| value else if (top != null and bottom != null) @max(0, content.height - top.? - bottom.? - margin.top - margin.bottom) else child.unrounded_layout.size.height;
        const x = left orelse if (right) |value| content.width - value - width - margin.right else margin.left;
        const y = top orelse if (bottom) |value| content.height - value - height - margin.bottom else margin.top;
        child.unrounded_layout.order = @intCast(order);
        child.unrounded_layout.location = .{ .x = inset.left + x, .y = inset.top + y };
        child.unrounded_layout.size = .{ .width = @max(0, width), .height = @max(0, height) };
        child.final_layout = child.unrounded_layout;
    }
}

fn resolve_edges(value: geometry.Rect(style.dimension.LengthPercentage), basis: f32) geometry.Rect(f32) {
    return .{ .left = value.left.resolve(basis), .right = value.right.resolve(basis), .top = value.top.resolve(basis), .bottom = value.bottom.resolve(basis) };
}

fn resolve_auto_edges(value: geometry.Rect(style.dimension.LengthPercentageAuto), basis: f32) geometry.Rect(f32) {
    return .{ .left = value.left.resolve(basis) orelse 0, .right = value.right.resolve(basis) orelse 0, .top = value.top.resolve(basis) orelse 0, .bottom = value.bottom.resolve(basis) orelse 0 };
}

fn auto_edges(value: geometry.Rect(style.dimension.LengthPercentageAuto)) geometry.Rect(bool) {
    return .{ .left = value.left.is_auto(), .right = value.right.is_auto(), .top = value.top.is_auto(), .bottom = value.bottom.is_auto() };
}

fn add_edges(a: geometry.Rect(f32), b: geometry.Rect(f32)) geometry.Rect(f32) {
    return .{ .left = a.left + b.left, .right = a.right + b.right, .top = a.top + b.top, .bottom = a.bottom + b.bottom };
}

fn resolve_dimensions(value: geometry.Size(style.dimension.Dimension), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width.resolve(parent.width), .height = value.height.resolve(parent.height) };
}

fn resolve_auto_dimensions(value: geometry.Size(style.dimension.LengthPercentageAuto), width: ?f32, height: ?f32) geometry.Size(?f32) {
    return .{ .width = value.width.resolve(width orelse 0), .height = value.height.resolve(height orelse 0) };
}

test "flex records hold a basis and violation" {
    const testing = std.testing;
    var item = FlexItem{ .node = 1, .flex_basis = 20 };
    item.violation = 3;
    try testing.expectEqual(@as(f32, 20), item.flex_basis);
    try testing.expectEqual(@as(f32, 3), item.violation);
}

test "flex wrap creates independent cross-axis lines" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_style = style.Style{ .size = .{ .width = .length(30), .height = .length(10) } };
    const first = try tree_ref.new_leaf(child_style);
    const second = try tree_ref.new_leaf(child_style);
    const root = try tree_ref.new_with_children(.{ .flex_wrap = .wrap }, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 50 }, .height = .{ .definite = 40 } });
    const first_layout = try tree_ref.layout_of(first);
    const second_layout = try tree_ref.layout_of(second);
    try testing.expectEqual(@as(f32, 0), first_layout.location.y);
    try testing.expectEqual(@as(f32, 20), second_layout.location.y);
}

test "flex child layout receives used size for percentage descendants" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .{ .value = .{ .percent = 1 } }, .height = .length(10) } });
    const child = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .{ .value = .{ .percent = 0.5 } }, .height = .length(20) } }, &[_]tree.NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(grandchild)).size.width);
}

test "flex positions absolute children against the container" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const absolute = try tree_ref.new_leaf(.{
        .position = .absolute,
        .inset = .{ .left = .length(10), .right = .auto(), .top = .length(5), .bottom = .auto() },
        .size = .{ .width = .length(20), .height = .length(10) },
    });
    const root = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{absolute});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    const result = try tree_ref.layout_of(absolute);
    try testing.expectEqual(@as(f32, 10), result.location.x);
    try testing.expectEqual(@as(f32, 5), result.location.y);
    try testing.expectEqual(@as(f32, 20), result.size.width);
}

test "flex reverse direction and auto margins use main-axis free space" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .size = .{ .width = .length(30), .height = .length(10) } });
    const reverse_root = try tree_ref.new_with_children(.{ .flex_direction = .row_reverse }, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(reverse_root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 80), (try tree_ref.layout_of(first)).location.x);
    try testing.expectEqual(@as(f32, 50), (try tree_ref.layout_of(second)).location.x);

    var auto_tree = tree.TaffyTree.init(testing.allocator);
    defer auto_tree.deinit();
    const auto_child = try auto_tree.new_leaf(.{
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .auto(), .right = .zero(), .top = .zero(), .bottom = .zero() },
    });
    const auto_root = try auto_tree.new_with_children(.{}, &[_]tree.NodeId{auto_child});
    try auto_tree.compute_layout(auto_root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 80), (try auto_tree.layout_of(auto_child)).location.x);
}

test "flex distributed justification expands inter-item gaps" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const item_style = style.Style{ .size = .{ .width = .length(10), .height = .length(10) } };
    const a = try tree_ref.new_leaf(item_style);
    const b = try tree_ref.new_leaf(item_style);
    const c = try tree_ref.new_leaf(item_style);
    const root = try tree_ref.new_with_children(.{ .justify_content = .space_between }, &[_]tree.NodeId{ a, b, c });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(a)).location.x);
    try testing.expectEqual(@as(f32, 45), (try tree_ref.layout_of(b)).location.x);
    try testing.expectEqual(@as(f32, 90), (try tree_ref.layout_of(c)).location.x);
}

test "flexing freezes max violations and redistributes remaining space" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .flex_basis = .length(20), .flex_grow = 1, .size = .{ .width = .auto, .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .flex_basis = .length(20), .flex_grow = 1, .max_size = .{ .width = .length(30), .height = .auto() }, .size = .{ .width = .auto, .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 70), (try tree_ref.layout_of(first)).size.width);
    try testing.expectEqual(@as(f32, 30), (try tree_ref.layout_of(second)).size.width);
}

test "flex wrap-reverse stacks lines from the cross-axis end" {
    const testing = std.testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_style = style.Style{ .size = .{ .width = .length(30), .height = .length(10) } };
    const first = try tree_ref.new_leaf(child_style);
    const second = try tree_ref.new_leaf(child_style);
    const root = try tree_ref.new_with_children(.{ .flex_wrap = .wrap_reverse }, &[_]tree.NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 50 }, .height = .{ .definite = 40 } });
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(first)).location.y);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(second)).location.y);
}

test "balanced flex lines preserve zero-item and tie rules" {
    const testing = std.testing;
    const first = try balanced_line_item_counts(testing.allocator, &[_]f32{ 70, 0, 20 }, 100, 10, 1);
    defer testing.allocator.free(first);
    try testing.expectEqualSlices(usize, &[_]usize{ 2, 1 }, first);

    const overflowing = try balanced_line_item_counts(testing.allocator, &[_]f32{ 150, 0, 30 }, 100, 0, 1);
    defer testing.allocator.free(overflowing);
    try testing.expectEqualSlices(usize, &[_]usize{ 1, 2 }, overflowing);

    const requested = try balanced_line_item_counts(testing.allocator, &[_]f32{ 70, 0, 0 }, 100, 0, 2);
    defer testing.allocator.free(requested);
    try testing.expectEqualSlices(usize, &[_]usize{ 2, 1 }, requested);
}
