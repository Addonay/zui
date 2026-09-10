//! Computes size using styles and measure functions.
//!
//! Direct port of Taffy's `src/compute/leaf.rs`. Keep the order of operations
//! visible: resolve edge values, select sizing mode, reserve scroll gutters,
//! build available-space constraints, invoke the measure callback, then clamp
//! and apply aspect ratio. Do not move style resolution into the caller: the
//! same leaf function is used by flex, grid, block and absolute layout.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/mod.zig");
const available = @import("../style/available_space.zig");
const tree_layout = @import("../tree/layout.zig");
const traits = @import("../tree/traits.zig");

pub const MeasureFunc = traits.MeasureFunc;

/// Compute a leaf's output from a Taffy-style input and measure callback.
pub fn compute_leaf_layout(
    inputs: tree_layout.LayoutInput,
    node_style: style.Style,
    context: ?*anyopaque,
    measure_function: ?MeasureFunc,
) tree_layout.LayoutOutput {
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;

    // Taffy resolves horizontal and vertical percentage padding/border against
    // the containing block's inline size (width), including vertical values.
    const padding = resolve_edges(node_style.padding, parent_size.width orelse 0);
    const border = resolve_edges(node_style.border, parent_size.width orelse 0);
    const margin = resolve_auto_edges(node_style.margin, parent_size.width orelse 0);
    const padding_border = add_edges(padding, border);
    const padding_border_sum = geometry.F32Size{
        .width = padding_border.horizontal_axis_sum(),
        .height = padding_border.vertical_axis_sum(),
    };
    const box_sizing_adjustment = if (node_style.box_sizing == .content_box) padding_border_sum else geometry.F32Size{ .width = 0, .height = 0 };
    // For ComputeSize, styles are ignored except for known dimensions. For
    // InherentSize, style size/min/max and aspect-ratio participate.
    var node_size = known_dimensions;
    var node_min_size = geometry.OptionalF32Size{ .width = null, .height = null };
    var node_max_size = geometry.OptionalF32Size{ .width = null, .height = null };
    var aspect_ratio: ?f32 = null;
    if (inputs.sizing_mode == .inherent_size) {
        aspect_ratio = node_style.aspect_ratio;
        const resolved_style = resolve_dimensions(node_style.size, parent_size);
        const resolved_min = resolve_auto_dimensions(node_style.min_size, parent_size);
        const resolved_max = resolve_auto_dimensions(node_style.max_size, parent_size);
        node_size = optional_or(known_dimensions, optional_add(resolved_style, box_sizing_adjustment));
        node_min_size = optional_add(resolved_min, box_sizing_adjustment);
        node_max_size = optional_add(resolved_max, box_sizing_adjustment);
    }

    const node_size_with_ratio = optional_apply_aspect(node_size, aspect_ratio);
    const min_max_definite = optional_min_max(node_min_size, node_max_size);
    const styled_based_known_dimensions = optional_max(
        optional_max(node_size_with_ratio, min_max_definite),
        known_dimensions,
    );

    const has_styles_preventing_collapse = !node_style.is_block() or
        node_style.overflow.x.is_scroll_container() or
        node_style.overflow.y.is_scroll_container() or
        node_style.position == .absolute or
        node_style.contain.establishes_independent_formatting_context() or
        padding.top > 0 or padding.bottom > 0 or border.top > 0 or border.bottom > 0 or
        (node_size_with_ratio.height orelse 0) > 0 or
        (node_min_size.height orelse 0) > 0;

    if (inputs.run_mode == .compute_size and has_styles_preventing_collapse and styled_based_known_dimensions.width != null and styled_based_known_dimensions.height != null) {
        const resolved = optional_clamp(styled_based_known_dimensions, node_min_size, node_max_size);
        const size = geometry.F32Size{ .width = @max(resolved.width orelse 0, padding_border_sum.width), .height = @max(resolved.height orelse 0, padding_border_sum.height) };
        return .{ .size = size, .baselines = .none, .top_margin = .zero, .bottom_margin = .zero, .margins_can_collapse_through = false };
    }

    var content_box_inset = padding_border;
    const scrollbar_gutter = geometry.Point(f32){
        .x = if (node_style.overflow.y == .scroll) node_style.scrollbar_width else 0,
        .y = if (node_style.overflow.x == .scroll) node_style.scrollbar_width else 0,
    };
    content_box_inset.right += scrollbar_gutter.x;
    content_box_inset.bottom += scrollbar_gutter.y;

    const available_space = geometry.Size(available.AvailableSpace){
        .width = available_for_axis(known_dimensions.width, node_size_with_ratio.width, inputs.available_space.width, node_min_size.width, node_max_size.width, content_box_inset.horizontal_axis_sum() + margin.left + margin.right),
        .height = available_for_axis(known_dimensions.height, node_size_with_ratio.height, inputs.available_space.height, node_min_size.height, node_max_size.height, content_box_inset.vertical_axis_sum() + margin.top + margin.bottom),
    };

    const measured = if (measure_function) |function|
        function(if (inputs.run_mode == .compute_size) context else context, if (inputs.run_mode == .compute_size) known_dimensions else .{ .width = null, .height = null }, available_space)
    else
        geometry.F32Size{ .width = 0, .height = 0 };

    var clamped = optional_or(known_dimensions, node_size_with_ratio);
    if (clamped.width == null) clamped.width = measured.width + content_box_inset.horizontal_axis_sum();
    if (clamped.height == null) clamped.height = measured.height + content_box_inset.vertical_axis_sum();
    clamped = optional_clamp(clamped, node_min_size, node_max_size);
    var size = geometry.F32Size{ .width = clamped.width orelse 0, .height = clamped.height orelse 0 };
    if (aspect_ratio) |ratio| {
        if (ratio > 0) size.height = @max(size.height, size.width / ratio);
    } else {}
    size.width = @max(size.width, padding_border_sum.width);
    size.height = @max(size.height, padding_border_sum.height);

    const is_scroll_container = node_style.overflow.x.is_scroll_container() or node_style.overflow.y.is_scroll_container();
    const start_padding = if (node_style.direction == .rtl) padding.right else padding.left;
    const end_padding = if (node_style.direction == .rtl) padding.left else padding.right;
    const scrollable_overflow = geometry.Rect(f32){
        .left = 0,
        .right = start_padding + measured.width + if (is_scroll_container) end_padding else 0,
        .top = 0,
        .bottom = padding.top + measured.height + if (is_scroll_container) padding.bottom else 0,
    };
    return .{
        .size = size,
        .scrollable_overflow_rect = scrollable_overflow,
        .baselines = .none,
        .top_margin = if (has_styles_preventing_collapse or size.height != 0 or measured.height != 0) .zero else tree_layout.CollapsibleMarginSet.from_margin(margin.top),
        .bottom_margin = if (has_styles_preventing_collapse or size.height != 0 or measured.height != 0) .zero else tree_layout.CollapsibleMarginSet.from_margin(margin.bottom),
        .margins_can_collapse_through = !has_styles_preventing_collapse and size.height == 0 and measured.height == 0,
    };
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

fn resolve_dimensions(value: geometry.Size(style.dimension.Dimension), parent: geometry.Size(?f32)) geometry.OptionalF32Size {
    return .{ .width = value.width.resolve(parent.width), .height = value.height.resolve(parent.height) };
}

fn resolve_auto_dimensions(value: geometry.Size(style.dimension.LengthPercentageAuto), parent: geometry.Size(?f32)) geometry.OptionalF32Size {
    return .{ .width = value.width.resolve(parent.width orelse 0), .height = value.height.resolve(parent.height orelse 0) };
}

fn optional_or(a: geometry.OptionalF32Size, b: geometry.OptionalF32Size) geometry.OptionalF32Size {
    return .{ .width = a.width orelse b.width, .height = a.height orelse b.height };
}

fn optional_add(value: geometry.OptionalF32Size, add: geometry.F32Size) geometry.OptionalF32Size {
    return .{ .width = if (value.width) |v| v + add.width else null, .height = if (value.height) |v| v + add.height else null };
}

fn optional_apply_aspect(value: geometry.OptionalF32Size, ratio: ?f32) geometry.OptionalF32Size {
    if (ratio) |r| if (r > 0) {
        if (value.width) |width| if (value.height == null) return .{ .width = width, .height = width / r };
        if (value.height) |height| if (value.width == null) return .{ .width = height * r, .height = height };
    };
    return value;
}

fn optional_min_max(minimum: geometry.OptionalF32Size, maximum: geometry.OptionalF32Size) geometry.OptionalF32Size {
    return .{
        .width = if (minimum.width) |min| if (maximum.width) |max| if (max <= min) min else null else null else null,
        .height = if (minimum.height) |min| if (maximum.height) |max| if (max <= min) min else null else null else null,
    };
}

fn optional_max(a: geometry.OptionalF32Size, b: geometry.OptionalF32Size) geometry.OptionalF32Size {
    return .{ .width = max_optional(a.width, b.width), .height = max_optional(a.height, b.height) };
}

fn max_optional(a: ?f32, b: ?f32) ?f32 {
    if (a) |left| if (b) |right| return @max(left, right);
    return a orelse b;
}

fn optional_clamp(value: geometry.OptionalF32Size, minimum: geometry.OptionalF32Size, maximum: geometry.OptionalF32Size) geometry.OptionalF32Size {
    return .{ .width = clamp_optional(value.width, minimum.width, maximum.width), .height = clamp_optional(value.height, minimum.height, maximum.height) };
}

fn clamp_optional(value: ?f32, minimum: ?f32, maximum: ?f32) ?f32 {
    if (value) |v| return @min(maximum orelse std.math.inf(f32), @max(minimum orelse 0, v));
    return null;
}

fn available_for_axis(known: ?f32, styled: ?f32, original: available.AvailableSpace, minimum: ?f32, maximum: ?f32, inset: f32) available.AvailableSpace {
    if (known) |value| return .{ .definite = @max(0, value - inset) };
    if (styled) |value| return .{ .definite = @max(0, value - inset) };
    return switch (original) {
        .definite => |value| .{ .definite = @max(0, @min(maximum orelse value, @max(minimum orelse 0, value)) - inset) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

test "leaf sizing resolves known and measured axes" {
    const testing = std.testing;
    const input = tree_layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 100, .height = 100 },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    const result = compute_leaf_layout(input, .{ .size = .{ .width = style.dimension.Dimension.length(30), .height = style.dimension.Dimension.length(20) } }, null, null);
    try testing.expectEqual(@as(f32, 30), result.size.width);
    try testing.expectEqual(@as(f32, 20), result.size.height);
}

test "zero-height block leaves preserve collapsible resolved margins" {
    const testing = std.testing;
    const input = tree_layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 100, .height = 100 },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } },
        .vertical_margins_are_collapsible = .{ .start = true, .end = true },
    };
    const result = compute_leaf_layout(input, .{
        .display = .block,
        .margin = .{ .left = .zero(), .right = .zero(), .top = .length(5), .bottom = .length(7) },
    }, null, null);
    try testing.expect(result.margins_can_collapse_through);
    try testing.expectEqual(@as(f32, 5), result.top_margin.resolve());
    try testing.expectEqual(@as(f32, 7), result.bottom_margin.resolve());
}
