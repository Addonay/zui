//! Experimental, bounded-rebuild ZUI → Zlay adapter (gap §5D).
//!
//! Box sizing: logical f32 units; explicit w/h/square are BORDER boxes,
//! including padding. Borders are paint-only overlays, as in legacy ZUI;
//! they do not consume layout space. Full axes are 100% of parent content.
//! Auto containers in columns stretch on the cross axis. No flex shrink;
//! growing non-wrapped items use a zero basis, wrapped rows use auto basis.
//! Explicit dimensions take precedence over square/full axes. Root auto axes
//! fill the viewport. Unlike legacy, explicit overflowing sizes aren't clamped
//! to the remaining slot, and percentage axes need a definite parent size.
//!
//! Fractional rounding: disabled in Zlay. Preserve f32 positions and sizes,
//! including fractional viewport origins; no independent edge/size snapping.
//! Rasterization owns physical pixel rounding; agreement tolerance is 0.001
//! logical units (not a license to hide whole-pixel geometry differences).
//!
//! Text leaves reflow against a definite parent available width while
//! intrinsic min/max-content probes remain unwrapped. Leaves are measured once
//! before compute (even fully definite leaves, for measure→paint handoff);
//! callbacks consume those existing text/image measurements. Images retain
//! intrinsic aspect derivation for one explicit axis. No asset I/O is added.
//!
//! Unsupported/deferred semantics are enumerated below, not CSS promises.
//! Paint/listener fields pass through unchanged; scroll offsets remain a
//! post-layout translation of normal descendants, while Zlay's scrollbar
//! gutter and scroll-region outputs are retained on each node.
//! Trees/context storage live only for a single call; no stable-ID caching.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const element = @import("element.zig");
const legacy = @import("layout.zig");
const text_engine = @import("text_engine.zig");
const zlay = @import("layout");
const S = zlay.style;
const D = S.dimension.Dimension;
const LP = S.dimension.LengthPercentage;
const LPA = S.dimension.LengthPercentageAuto;
const Tree = zlay.tree.TaffyTree;
const NodeId = zlay.tree.NodeId;

pub const pin = "dbce9266163ba5400385693aebd86c0726464a94";
pub const agreement_tolerance: f32 = 0.001;
pub const unsupported: []const []const u8 = &.{
    "legacy overflow clamping of explicit sizes (Zlay retains authored size)",
    "full main axis with indefinite parent (Zlay percentage resolution)",
    "column flex_wrap (ignored, like legacy; only rows wrap)",
    "leaf padding (ignored, like legacy; only containers consume padding)",
    "legacy grow weights summing below 1 (Zlay distributes only that fraction)",
    "legacy wrapped-row double padding measurement and explicit grow clamping",
};

pub fn useZlayLayout() bool {
    if (!builtin.link_libc) return true;
    const value = std.c.getenv("ZUI_LAYOUT") orelse return true;
    // Zlay is the canonical path. Keep an explicit legacy escape hatch for
    // migration/debugging and for consumers that have not completed their
    // style-contract audit yet.
    return !std.mem.eql(u8, std.mem.span(value), "legacy");
}

pub fn translateStyle(node: *const element.Node, parent: ?*const element.Node) S.Style {
    return translateStyleWithExtras(node, parent, .{});
}

pub fn translateStyleWithFrame(frame: *element.Frame, node: *const element.Node, parent: ?*const element.Node) S.Style {
    var out = translateStyleWithExtras(node, parent, frame.styleExtrasFor(node.style_ext_slot));
    const extras = frame.styleExtrasFor(node.style_ext_slot);
    if (extras.grid_column_count > 0 or extras.grid_row_count > 0 or extras.grid_auto_flow != .row) {
        out.display = .grid;
        if (extras.grid_column_count > 0) out.grid_template_columns = frame.gridColumnsFor(node.style_ext_slot);
        if (extras.grid_row_count > 0) out.grid_template_rows = frame.gridRowsFor(node.style_ext_slot);
        out.grid_auto_flow = switch (extras.grid_auto_flow) {
            .row => .row,
            .column => .column,
            .row_dense => .row_dense,
            .column_dense => .column_dense,
        };
    }
    out.grid_template_column_names = frame.gridColumnNamesFor(node.style_ext_slot);
    out.grid_template_row_names = frame.gridRowNamesFor(node.style_ext_slot);
    out.grid_column = .{ .start = gridPlacement(extras.grid_column.start), .end = gridPlacement(extras.grid_column.end) };
    out.grid_row = .{ .start = gridPlacement(extras.grid_row.start), .end = gridPlacement(extras.grid_row.end) };
    return out;
}

fn translateStyleWithExtras(node: *const element.Node, parent: ?*const element.Node, extras: element.StyleExtras) S.Style {
    const s = node.style;
    var out = S.Style{};
    out.flex_direction = switch (s.direction) {
        .row => .row,
        .column => .column,
        .row_reverse => .row_reverse,
        .column_reverse => .column_reverse,
    };
    const row_direction = s.direction == .row or s.direction == .row_reverse;
    out.flex_wrap = if (s.flex_wrap and row_direction)
        (if (s.flex_wrap_reverse) .wrap_reverse else .wrap)
    else
        .no_wrap;
    out.flex_shrink = s.flex_shrink;
    out.flex_grow = s.flex_grow;
    out.min_size = .{ .width = LPA.length(0), .height = LPA.length(0) };
    if (extras.min_width) |value| out.min_size.width = LPA.length(value);
    if (extras.min_height) |value| out.min_size.height = LPA.length(value);
    if (extras.min_width_percent) |value| out.min_size.width = LPA.percent(value);
    if (extras.min_height_percent) |value| out.min_size.height = LPA.percent(value);
    if (extras.max_width) |value| out.max_size.width = LPA.length(value);
    if (extras.max_height) |value| out.max_size.height = LPA.length(value);
    if (extras.max_width_percent) |value| out.max_size.width = LPA.percent(value);
    if (extras.max_height_percent) |value| out.max_size.height = LPA.percent(value);
    out.aspect_ratio = extras.aspect_ratio;
    if (s.flex_basis) |basis| {
        out.flex_basis = D.length(basis);
    } else if (s.flex_grow > 0 and (parent == null or !parent.?.style.flex_wrap)) {
        out.flex_basis = D.length(0);
    }
    out.align_items = switch (s.alignment) {
        .start => .flex_start,
        .center => .center,
        .end => .flex_end,
        .stretch => .stretch,
        .baseline => .baseline,
    };
    out.align_content = switch (s.align_content) {
        .start => .start,
        .center => .center,
        .end => .end,
        .stretch => .stretch,
        .between => .space_between,
        .around => .space_around,
        .evenly => .space_evenly,
    };
    out.justify_content = switch (s.justify) {
        .start => .flex_start,
        .center => .center,
        .end => .flex_end,
        .between => .space_between,
        .around => .space_around,
        .evenly => .space_evenly,
    };
    out.gap = .{ .width = LP.length(s.gap), .height = LP.length(s.gap) };
    out.overflow = .{ .x = overflow(s.overflow_x), .y = overflow(s.overflow_y) };
    out.scrollbar_width = s.scrollbar_width;
    if (node.kind == .container) out.padding = .{
        .left = LP.length(s.padding.left),
        .right = LP.length(s.padding.right),
        .top = LP.length(s.padding.top),
        .bottom = LP.length(s.padding.bottom),
    };
    out.size.width = if (s.width orelse s.square) |v| D.length(v) else if (extras.width_percent) |p| D.percent(p) else if (s.full_width) D.percent(1) else intrinsic(extras.width_intrinsic);
    out.size.height = if (s.height orelse s.square) |v| D.length(v) else if (extras.height_percent) |p| D.percent(p) else if (s.full_height) D.percent(1) else intrinsic(extras.height_intrinsic);
    if (s.max_width_full) out.max_size.width = LPA.percent(1);
    if (parent) |p| {
        const parent_column = p.style.direction == .column or p.style.direction == .column_reverse;
        if (parent_column and node.kind == .container and s.width == null and s.square == null)
            out.align_self = .stretch;
    }
    // Keep measured leaves intrinsic in a column cross axis. Stretching text,
    // images, or custom content changes strike decorations, hit regions, and
    // sibling spacing compared with ZUI's established layout contract.
    if ((node.kind == .text or node.kind == .image or node.kind == .custom) and
        (parent == null or parent.?.style.alignment == .stretch))
    {
        out.align_self = .flex_start;
    }
    if (s.absolute) {
        out.position = .absolute;
        if (s.inset_value) |v| {
            out.inset = .{ .left = LPA.length(v), .right = LPA.length(v), .top = LPA.length(v), .bottom = LPA.length(v) };
        } else {
            // Legacy right wins over left. No implicit opposing zero offset:
            // that would incorrectly stretch intrinsic absolute children.
            out.inset.left = if (s.right == null) LPA.length(s.left orelse 0) else LPA.auto();
            out.inset.right = if (s.right) |v| LPA.length(v) else LPA.auto();
            out.inset.top = LPA.length(s.top orelse 0);
        }
    }
    return out;
}

fn gridPlacement(value: element.GridPlacement) S.grid.GridPlacement {
    return switch (value) {
        .auto => .auto,
        .line => |line| S.grid.GridPlacement.from_line_index(line),
        .span => |span| S.grid.GridPlacement.from_span(span),
        .named_line => |named| S.grid.GridPlacement.from_named_line(named.name, named.index),
        .named_span => |named| S.grid.GridPlacement.from_named_span(named.name, named.count),
    };
}

fn overflow(value: element.Overflow) S.Overflow {
    return switch (value) {
        .visible => .visible,
        .clip => .clip,
        .hidden => .hidden,
        .scroll => .scroll,
    };
}

fn intrinsic(value: ?element.IntrinsicSize) D {
    return switch (value orelse .auto) {
        .auto => .auto,
        .min_content => D.min_content,
        .max_content => D.max_content,
        .stretch => D.stretch,
    };
}

const MeasureContext = struct { frame: *element.Frame, index: u16 };
fn measure(context: ?*anyopaque, input: zlay.tree.LayoutInput, _: NodeId, style: *const S.Style) zlay.tree.LayoutOutput {
    var output = zlay.compute.leaf.compute_leaf_layout(input, style, context, measureSize);
    if (context) |ptr| {
        const ctx: *MeasureContext = @ptrCast(@alignCast(ptr));
        const node = &ctx.frame.nodes[ctx.index];
        output.baselines = .{ .first = node.baseline, .last = node.last_baseline };
    }
    return output;
}

fn measureSize(context: ?*anyopaque, known: zlay.geometry.Size(?f32), available: zlay.geometry.Size(S.available_space.AvailableSpace)) zlay.geometry.Size(f32) {
    const size: core.Size = if (context) |ptr| blk: {
        const ctx: *MeasureContext = @ptrCast(@alignCast(ptr));
        const node = &ctx.frame.nodes[ctx.index];
        const extras = ctx.frame.styleExtrasFor(node.style_ext_slot);
        // GPUI measures text against the definite width supplied by its
        // parent, including percentage-resolved widths.  ZUI's retained
        // text cache keys on node.style.width, so commit the resolved width
        // before shaping; this keeps the later paint lookup exact and avoids
        // a second unconstrained shape. Intrinsic (min/max-content) probes
        // remain unbounded because Zlay deliberately reports those as such.
        if (node.kind == .text and node.style.width == null and extras.width_percent != null and ctx.frame.parentOf(ctx.index) != null) {
            const width = known.width orelse available.width.into_option();
            if (width) |resolved_width| {
                node.style.width = resolved_width;
                _ = legacy.measure(ctx.frame, ctx.index);
            }
        }
        break :blk node.measured;
    } else .{};
    return .{ .width = known.width orelse size.w, .height = known.height orelse size.h };
}

/// Errors propagate to the dispatcher; no partially copied geometry on a
/// compute failure. The dispatcher logs before falling back to legacy.
pub fn layout(frame: *element.Frame, root: element.Element, viewport: core.Rect) !void {
    const alloc = text_engine.frameAllocator(frame);
    var tree = Tree.init(alloc);
    defer tree.deinit();
    tree.disable_rounding();
    const ids = try alloc.alloc(NodeId, frame.node_count);
    defer alloc.free(ids);
    const contexts = try alloc.alloc(MeasureContext, frame.node_count);
    defer alloc.free(contexts);
    const parents = try alloc.alloc(?u16, frame.node_count);
    defer alloc.free(parents);
    @memset(parents, null);
    for (frame.nodes[0..frame.node_count], 0..) |n, i| {
        var child = n.first_child;
        while (child) |c| : (child = frame.nodes[c].next_sibling) parents[c] = @intCast(i);
    }
    for (frame.nodes[0..frame.node_count], 0..) |*n, i| {
        var style = translateStyleWithFrame(frame, n, if (parents[i]) |p| &frame.nodes[p] else null);
        if (i == root.index) {
            const extras = frame.styleExtrasFor(n.style_ext_slot);
            style.size.width = if (n.style.width orelse n.style.square) |value|
                D.length(@min(value, viewport.w))
            else if (extras.width_percent) |percent|
                D.percent(percent)
            else
                D.length(viewport.w);
            style.size.height = if (n.style.height orelse n.style.square) |value|
                D.length(@min(value, viewport.h))
            else if (extras.height_percent) |percent|
                D.percent(percent)
            else
                D.length(viewport.h);
        }
        contexts[i] = .{ .frame = frame, .index = @intCast(i) };
        if (n.kind == .text or n.kind == .image or n.kind == .custom) {
            _ = legacy.measure(frame, @intCast(i));
            ids[i] = try tree.new_leaf_with_context(style, &contexts[i]);
        } else ids[i] = try tree.new_leaf(style);
    }
    for (frame.nodes[0..frame.node_count], 0..) |n, i| {
        var child = n.first_child;
        while (child) |c| : (child = frame.nodes[c].next_sibling) try tree.add_child(ids[i], ids[c]);
    }
    try tree.compute_layout_with_measure(ids[root.index], .{ .width = .{ .definite = viewport.w }, .height = .{ .definite = viewport.h } }, measure);
    try copyBounds(&tree, ids, frame, root.index, .{ .x = viewport.x, .y = viewport.y });
}

fn copyBounds(tree: *Tree, ids: []const NodeId, frame: *element.Frame, index: u16, origin: core.Point) anyerror!void {
    const box = try tree.layout(ids[index]);
    const n = &frame.nodes[index];
    n.bounds = .{ .x = origin.x + box.location.x, .y = origin.y + box.location.y, .w = box.size.width, .h = box.size.height };
    n.scrollable_overflow = .{ .x = box.scrollable_overflow_rect.left, .y = box.scrollable_overflow_rect.top, .w = box.scrollable_overflow_rect.right - box.scrollable_overflow_rect.left, .h = box.scrollable_overflow_rect.bottom - box.scrollable_overflow_rect.top };
    n.scrollbar_size = .{ .w = box.scrollbar_size.width, .h = box.scrollbar_size.height };
    if (n.kind != .text and n.kind != .image and n.kind != .custom) n.measured = .{ .w = box.size.width, .h = box.size.height };
    var child = n.first_child;
    while (child) |c| : (child = frame.nodes[c].next_sibling) {
        const absolute = frame.nodes[c].style.absolute;
        try copyBounds(tree, ids, frame, c, .{
            .x = n.bounds.x - (if (absolute) @as(f32, 0) else n.style.scroll_x),
            .y = n.bounds.y - (if (absolute) @as(f32, 0) else n.style.scroll_y),
        });
    }
}

test {
    _ = @import("zlay_adapter_test.zig");
}
