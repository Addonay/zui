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
//! Text uses the existing explicit-width-only Cozmic wrap contract, NOT an
//! inferred available-width wrap. Leaves are measured once before compute
//! (even fully definite leaves, for measure→paint handoff); callbacks consume
//! those existing text/image measurements. Images retain intrinsic aspect
//! derivation for one explicit axis. No asset I/O is added here.
//!
//! Unsupported/deferred semantics are enumerated below, not CSS promises.
//! Paint/listener fields pass through unchanged; scroll is a post-layout
//! translation of normal descendants, not a Zlay overflow/scrollbar model.
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
    "column flex_wrap (ignored, like legacy; only rows wrap)",
    "offsets on non-absolute nodes (ignored, like legacy)",
    "leaf padding (ignored, like legacy; only containers consume padding)",
    "legacy overflow clamping of explicit sizes (Zlay retains authored size)",
    "full main axis with indefinite parent (Zlay percentage resolution)",
    "legacy grow weights summing below 1 (Zlay distributes only that fraction)",
    "legacy wrapped-row double padding measurement and explicit grow clamping",
    "available-width text reflow (only explicit text width wraps)",
    "public grid, min/max/intrinsic constraints, shrink/basis controls, baselines, reverse flow and CSS overflow",
};

pub fn useZlayLayout() bool {
    if (!builtin.link_libc) return false;
    const value = std.c.getenv("ZUI_LAYOUT") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "zlay");
}

pub fn translateStyle(node: *const element.Node, parent: ?*const element.Node) S.Style {
    const s = node.style;
    var out = S.Style{};
    out.flex_direction = if (s.direction == .row) .row else .column;
    out.flex_wrap = if (s.flex_wrap and s.direction == .row) .wrap else .no_wrap;
    out.flex_shrink = 0;
    out.flex_grow = s.flex_grow;
    out.min_size = .{ .width = LPA.length(0), .height = LPA.length(0) };
    if (s.flex_grow > 0 and (parent == null or !parent.?.style.flex_wrap)) out.flex_basis = D.length(0);
    out.align_items = if (s.alignment == .center) .center else .start;
    out.align_content = .start;
    out.justify_content = switch (s.justify) {
        .start => .start,
        .center => .center,
        .between => .space_between,
    };
    out.gap = .{ .width = LP.length(s.gap), .height = LP.length(s.gap) };
    if (node.kind == .container) out.padding = .{
        .left = LP.length(s.padding.left),
        .right = LP.length(s.padding.right),
        .top = LP.length(s.padding.top),
        .bottom = LP.length(s.padding.bottom),
    };
    out.size.width = if (s.width orelse s.square) |v| D.length(v) else if (s.full_width) D.percent(1) else .auto;
    out.size.height = if (s.height orelse s.square) |v| D.length(v) else if (s.full_height) D.percent(1) else .auto;
    if (s.max_width_full) out.max_size.width = LPA.percent(1);
    if (parent) |p| {
        if (p.style.direction == .column and node.kind == .container and s.width == null and s.square == null)
            out.align_self = .stretch;
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

const MeasureContext = struct { frame: *element.Frame, index: u16 };
fn measure(context: ?*anyopaque, input: zlay.tree.LayoutInput, _: NodeId, style: *const S.Style) zlay.tree.LayoutOutput {
    return zlay.compute.leaf.compute_leaf_layout(input, style, context, measureSize);
}

fn measureSize(context: ?*anyopaque, known: zlay.geometry.Size(?f32), _: zlay.geometry.Size(S.available_space.AvailableSpace)) zlay.geometry.Size(f32) {
    const size: core.Size = if (context) |ptr| blk: {
        const ctx: *MeasureContext = @ptrCast(@alignCast(ptr));
        break :blk ctx.frame.nodes[ctx.index].measured;
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
        var style = translateStyle(n, if (parents[i]) |p| &frame.nodes[p] else null);
        if (i == root.index) {
            style.size.width = D.length(@min(n.style.width orelse n.style.square orelse viewport.w, viewport.w));
            style.size.height = D.length(@min(n.style.height orelse n.style.square orelse viewport.h, viewport.h));
        }
        contexts[i] = .{ .frame = frame, .index = @intCast(i) };
        if (n.kind == .text or n.kind == .image) {
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
    if (n.kind != .text and n.kind != .image) n.measured = .{ .w = box.size.width, .h = box.size.height };
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
