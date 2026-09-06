//! Recursive layout dispatcher.
//!
//! This module owns the engine's stateful part: fixed pools for the tree,
//! measurement hooks, cache entries and kernel scratch. Kernels remain mostly
//! pure and allocation-free; the dispatcher supplies their recursive
//! constraints and performs the final absolute-position pass.
//!
//! The data flow follows Taffy/Yoga's constraints-down, sizes-up model:
//!
//! ```text
//! parent constraints -> child measure/layout -> parent intrinsic size
//!                     -> parent arrange -> child final-size reflow
//! ```
//!
//! A node cache stores only a size for a complete `{known, available,
//! sizing_mode}` input. Positions are intentionally not cached: a parent may
//! move while its clean subtree keeps the same local geometry. Dirty state
//! propagates through ancestors, so a changed style or measure context cannot
//! leave a stale parent size behind.

const std = @import("std");
const core = @import("../core/root.zig");
const tree_mod = @import("tree.zig");
const style_mod = @import("style.zig");
const geo = @import("geometry.zig");
const cache_mod = @import("cache.zig");
const measure_mod = @import("measure.zig");
const flex_mod = @import("flex.zig");
const grid_mod = @import("grid.zig");
const block_mod = @import("block.zig");

pub const ComputeTree = struct {
    tree: tree_mod.LayoutTree = .{},
    caches: [tree_mod.max_nodes]cache_mod.NodeCache = undefined,
    measures: [tree_mod.max_nodes]measure_mod.LeafMeasure = undefined,
    prior_width: [tree_mod.max_nodes]f32 = undefined,
    prior_height: [tree_mod.max_nodes]f32 = undefined,
    flow_ids: [tree_mod.max_nodes]tree_mod.NodeId = undefined,
    flex_scratch: flex_mod.ArrangeScratch = .{},
    grid_scratch: grid_mod.GridScratch = .{},

    /// Construct and initialize every validity bit. The arrays themselves are
    /// fixed storage; `init` does not allocate.
    pub fn init() ComputeTree {
        var self = ComputeTree{};
        self.reset();
        return self;
    }

    /// Reuse the fixed pools for a new tree/frame.
    pub fn reset(self: *ComputeTree) void {
        self.tree.reset();
        for (&self.caches) |*cache| cache.clear();
        for (&self.measures) |*hook| hook.* = .{};
    }

    /// Install or replace a leaf measure hook. Hook generations are owned by
    /// the caller; changing the hook is itself a layout-affecting mutation.
    pub fn setMeasure(self: *ComputeTree, id: tree_mod.NodeId, value: measure_mod.LeafMeasure) void {
        self.measures[id] = value;
        self.tree.markDirty(id);
    }

    pub fn measure(self: *const ComputeTree, id: tree_mod.NodeId) measure_mod.LeafMeasure {
        return self.measures[id];
    }

    /// Compute a root against a definite viewport. Root dimensions are known
    /// dimensions, matching `TaffyTree::compute_layout(root, size)`.
    pub fn computeRoot(self: *ComputeTree, root: tree_mod.NodeId, available: core.Size) void {
        self.computeNode(root, .{
            .known = .{ .w = @max(0, available.w), .h = @max(0, available.h) },
            .available = .{ .w = .{ .definite = @max(0, available.w) }, .h = .{ .definite = @max(0, available.h) } },
        }, 0);
        self.tree.nodes[root].layout.x = 0;
        self.tree.nodes[root].layout.y = 0;
    }

    /// Public intrinsic entry point for callers that need a content-size
    /// probe without changing the node's root origin.
    pub fn compute(self: *ComputeTree, id: tree_mod.NodeId, input: geo.LayoutInput) void {
        self.computeNode(id, input, 0);
    }

    fn computeNode(self: *ComputeTree, id: tree_mod.NodeId, input: geo.LayoutInput, depth: usize) void {
        if (depth > tree_mod.max_depth) @panic("ZUI layout depth exceeded (raise MAX_NESTED_COMPONENTS?)");

        if (self.tree.nodes[id].style.display == .none) {
            self.clearSubtree(id, depth);
            return;
        }

        const key = cache_mod.CacheKey.fromInput(input);
        if (!self.tree.nodes[id].dirty) {
            if (self.caches[id].get(key)) |hit| {
                self.tree.nodes[id].layout.w = hit.w;
                self.tree.nodes[id].layout.h = hit.h;
                return;
            }
        }

        const style = self.tree.nodes[id].style;
        const inset = styleInsets(style);
        const declared_w = resolvedOuter(style, true, input, null);
        const declared_h = resolvedOuter(style, false, input, null);
        const available_w = childAvailable(input.available.w, inset.horizontal());
        const available_h = childAvailable(input.available.h, inset.vertical());

        if (self.tree.isLeaf(id)) {
            self.layoutLeaf(id, style, input, declared_w, declared_h, inset);
            self.caches[id].put(key, self.tree.nodes[id].layout.size());
            self.tree.markClean(id);
            return;
        }

        // First measure all children. Absolute children are measured too, but
        // are excluded from normal-flow line formation below.
        var child = self.tree.nodes[id].first_child;
        while (child) |child_id| : (child = self.tree.nodes[child_id].next_sibling) {
            const child_input = geo.LayoutInput{ .available = .{ .w = available_w, .h = available_h }, .sizing_mode = input.sizing_mode };
            self.computeNode(child_id, child_input, depth + 1);
        }

        const flow_count = self.collectFlow(id);
        const flow = self.flow_ids[0..flow_count];
        const gap_col = resolveLengthPercentage(style.gap_col, available_w.opt() orelse 0);
        const gap_row = resolveLengthPercentage(style.gap_row, available_w.opt() orelse 0);
        const is_row = style.flex_direction.isRow();
        const natural = self.naturalSize(id, style, flow, input, available_w, available_h, gap_col, gap_row, is_row);

        var width = declared_w orelse natural.w + inset.horizontal();
        var height = declared_h orelse natural.h + inset.vertical();
        if (style.aspect_ratio) |ratio| if (ratio > 0) {
            if (declared_w != null and declared_h == null) height = @max(0, (width - inset.horizontal()) / ratio) + inset.vertical();
            if (declared_h != null and declared_w == null) width = @max(0, (height - inset.vertical()) * ratio) + inset.horizontal();
        };
        width = clampOuter(style, true, width, input.available.w, inset.horizontal());
        height = clampOuter(style, false, height, input.available.h, inset.vertical());
        self.tree.nodes[id].layout.w = @max(0, width);
        self.tree.nodes[id].layout.h = @max(0, height);

        const content_w = innerExtent(width, inset.horizontal());
        const content_h = innerExtent(height, inset.vertical());
        // A child reached with no known dimensions is in the parent's
        // intrinsic measure pass. Its size is needed now, but its descendants
        // do not need final origins until the parent has resolved flex/grid
        // growth and cross-axis stretch. Deferring that reflow prevents a
        // deep one-child tree from recursively laying out the same subtree at
        // every ancestor (an exponential cold-layout trap).
        const defer_child_reflow = input.known.w == null and input.known.h == null;
        for (flow) |child_id| {
            self.prior_width[child_id] = self.tree.nodes[child_id].layout.w;
            self.prior_height[child_id] = self.tree.nodes[child_id].layout.h;
        }
        switch (style.display) {
            .flex => {
                flex_mod.arrange(self.tree_ptr(), style, flow, if (is_row) content_w else content_h, if (is_row) content_h else content_w, if (is_row) gap_col else gap_row, if (is_row) gap_row else gap_col, &self.flex_scratch);
            },
            .block => block_mod.arrange(self.tree_ptr(), style, flow, content_w, gap_row),
            .grid => _ = grid_mod.arrange(self.tree_ptr(), style, flow, content_w, content_h, gap_col, gap_row, &self.grid_scratch),
            .none => unreachable,
        }

        // Kernels use a zero-based content origin. Publish child locations
        // relative to the parent's border-box and then reflow every child
        // with its final assigned size so nested text/containers see the
        // actual width after grow/stretch/grid placement.
        const origin_x = inset.left;
        const origin_y = inset.top;
        if (!defer_child_reflow) {
            self.offsetAndReflowFlow(id, origin_x, origin_y, depth + 1);
            self.placeAbsoluteChildren(id, content_w, content_h, origin_x, origin_y, available_w, available_h, depth + 1);
        }

        self.caches[id].put(key, self.tree.nodes[id].layout.size());
        self.tree.markClean(id);
    }

    fn tree_ptr(self: *ComputeTree) *tree_mod.LayoutTree {
        return &self.tree;
    }

    fn collectFlow(self: *ComputeTree, id: tree_mod.NodeId) usize {
        var count: usize = 0;
        var child = self.tree.nodes[id].first_child;
        while (child) |child_id| : (child = self.tree.nodes[child_id].next_sibling) {
            const child_style = self.tree.nodes[child_id].style;
            if (child_style.display != .none and child_style.position != .absolute) {
                self.flow_ids[count] = child_id;
                count += 1;
            }
        }
        return count;
    }

    fn naturalSize(
        self: *ComputeTree,
        id: tree_mod.NodeId,
        style: style_mod.Style,
        flow: []const tree_mod.NodeId,
        input: geo.LayoutInput,
        available_w: geo.AvailableSpace,
        available_h: geo.AvailableSpace,
        gap_col: f32,
        gap_row: f32,
        is_row: bool,
    ) core.Size {
        _ = id;
        switch (style.display) {
            .flex => {
                const intrinsic = flex_mod.contentSize(
                    self.tree_ptr(),
                    flow,
                    is_row,
                    null,
                    if ((if (is_row) available_w else available_h) == .min_content) true else input.sizing_mode == .inherent,
                    if (is_row) gap_col else gap_row,
                    if (is_row) gap_row else gap_col,
                );
                return if (is_row) .{ .w = intrinsic.main, .h = intrinsic.cross } else .{ .w = intrinsic.cross, .h = intrinsic.main };
            },
            .block => {
                const intrinsic = block_mod.contentSize(self.tree_ptr(), flow, gap_row);
                return .{ .w = intrinsic.width, .h = intrinsic.height };
            },
            .grid => {
                // The grid arrange pass is also its intrinsic track-sizing
                // pass when both available axes are null. Its child origins
                // are provisional and are overwritten after final sizing.
                const intrinsic = grid_mod.arrange(self.tree_ptr(), style, flow, available_w.opt(), available_h.opt(), gap_col, gap_row, &self.grid_scratch);
                return .{ .w = intrinsic.width, .h = intrinsic.height };
            },
            .none => return .{},
        }
    }

    fn layoutLeaf(self: *ComputeTree, id: tree_mod.NodeId, style: style_mod.Style, input: geo.LayoutInput, declared_w: ?f32, declared_h: ?f32, inset: style_mod.Edges) void {
        const known = geo.KnownDimensions{
            .w = if (declared_w) |value| @max(0, value - inset.horizontal()) else null,
            .h = if (declared_h) |value| @max(0, value - inset.vertical()) else null,
        };
        const fallback = core.Size{
            .w = if (style.size.w != 0) @max(0, style.size.w - inset.horizontal()) else 0,
            .h = if (style.size.h != 0) @max(0, style.size.h - inset.vertical()) else 0,
        };
        const measured = self.measures[id].measure(known, input.available, fallback);
        var width = declared_w orelse measured.w + inset.horizontal();
        var height = declared_h orelse measured.h + inset.vertical();
        if (style.aspect_ratio) |ratio| if (ratio > 0) {
            if (declared_w != null and declared_h == null) height = @max(0, width - inset.horizontal()) / ratio + inset.vertical();
            if (declared_h != null and declared_w == null) width = @max(0, height - inset.vertical()) * ratio + inset.horizontal();
        };
        width = clampOuter(style, true, width, input.available.w, inset.horizontal());
        height = clampOuter(style, false, height, input.available.h, inset.vertical());
        self.tree.nodes[id].layout.w = @max(0, width);
        self.tree.nodes[id].layout.h = @max(0, height);
    }

    fn offsetAndReflowFlow(self: *ComputeTree, parent: tree_mod.NodeId, origin_x: f32, origin_y: f32, depth: usize) void {
        var child = self.tree.nodes[parent].first_child;
        while (child) |child_id| {
            const next = self.tree.nodes[child_id].next_sibling;
            const child_style = self.tree.nodes[child_id].style;
            if (child_style.display == .none or child_style.position == .absolute) {
                child = next;
                continue;
            }
            self.tree.nodes[child_id].layout.x += origin_x;
            self.tree.nodes[child_id].layout.y += origin_y;
            const old_x = self.tree.nodes[child_id].layout.x;
            const old_y = self.tree.nodes[child_id].layout.y;
            const width = self.tree.nodes[child_id].layout.w;
            const height = self.tree.nodes[child_id].layout.h;
            // If the assigned size did not change and the child is clean,
            // its previous internal arrangement remains valid. Avoiding an
            // unconditional subtree reflow is what keeps deep balanced trees
            // linear rather than multiplying work once per ancestor.
            const needs_reflow = self.tree.isDirty(child_id) or width != self.prior_width[child_id] or height != self.prior_height[child_id];
            if (needs_reflow) self.computeNode(child_id, .{
                .known = .{ .w = width, .h = height },
                .available = .{ .w = .{ .definite = width }, .h = .{ .definite = height } },
            }, depth);
            self.tree.nodes[child_id].layout.x = old_x;
            self.tree.nodes[child_id].layout.y = old_y;
            child = next;
        }
    }

    fn placeAbsoluteChildren(self: *ComputeTree, parent: tree_mod.NodeId, content_w: f32, content_h: f32, origin_x: f32, origin_y: f32, available_w: geo.AvailableSpace, available_h: geo.AvailableSpace, depth: usize) void {
        var child = self.tree.nodes[parent].first_child;
        while (child) |child_id| : (child = self.tree.nodes[child_id].next_sibling) {
            const style = self.tree.nodes[child_id].style;
            if (style.display == .none or style.position != .absolute) continue;

            const left = if (style.inset_left) |value| resolveLengthPercentage(value, content_w) else null;
            const right = if (style.inset_right) |value| resolveLengthPercentage(value, content_w) else null;
            const top = if (style.inset_top) |value| resolveLengthPercentage(value, content_h) else null;
            const bottom = if (style.inset_bottom) |value| resolveLengthPercentage(value, content_h) else null;
            const margin = style.margin;
            const known_w = if (left != null and right != null and style.width.isAuto()) @max(0, content_w - left.? - right.? - margin.left - margin.right) else null;
            const known_h = if (top != null and bottom != null and style.height.isAuto()) @max(0, content_h - top.? - bottom.? - margin.top - margin.bottom) else null;
            self.computeNode(child_id, .{
                .known = .{ .w = known_w, .h = known_h },
                .available = .{ .w = .{ .definite = content_w }, .h = .{ .definite = content_h } },
            }, depth);

            const x = if (left) |value| value + margin.left else if (right) |value| content_w - value - self.tree.nodes[child_id].layout.w - margin.right else margin.left;
            const y = if (top) |value| value + margin.top else if (bottom) |value| content_h - value - self.tree.nodes[child_id].layout.h - margin.bottom else margin.top;
            self.tree.nodes[child_id].layout.x = origin_x + x;
            self.tree.nodes[child_id].layout.y = origin_y + y;
            _ = available_w;
            _ = available_h;
        }
    }

    fn clearSubtree(self: *ComputeTree, id: tree_mod.NodeId, depth: usize) void {
        if (depth > tree_mod.max_depth) @panic("ZUI layout depth exceeded");
        self.tree.nodes[id].layout = .{};
        self.tree.nodes[id].dirty = false;
        var child = self.tree.nodes[id].first_child;
        while (child) |child_id| : (child = self.tree.nodes[child_id].next_sibling) self.clearSubtree(child_id, depth + 1);
    }
};

fn styleInsets(style: style_mod.Style) style_mod.Edges {
    return .{
        .top = style.padding.top + style.border.top,
        .right = style.padding.right + style.border.right,
        .bottom = style.padding.bottom + style.border.bottom,
        .left = style.padding.left + style.border.left,
    };
}

fn innerExtent(outer: f32, inset: f32) f32 {
    return @max(0, outer - inset);
}

fn childAvailable(space: geo.AvailableSpace, inset: f32) geo.AvailableSpace {
    return switch (space) {
        .definite => |value| .{ .definite = @max(0, value - inset) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

fn resolveLengthPercentage(value: style_mod.LengthPercentage, parent: f32) f32 {
    return @max(0, value.resolve(parent));
}

fn resolvedOuter(style: style_mod.Style, horizontal: bool, input: geo.LayoutInput, fallback: ?f32) ?f32 {
    const known = if (horizontal) input.known.w else input.known.h;
    if (known) |value| return @max(0, value);
    const parent = if (horizontal) input.available.w.opt() else input.available.h.opt();
    const dimension = if (horizontal) style.width else style.height;
    if (dimension.resolve(parent)) |value| return toOuter(style, horizontal, value);
    const legacy = if (horizontal) style.size.w else style.size.h;
    if (legacy != 0) return @max(0, legacy);
    return fallback;
}

fn toOuter(style: style_mod.Style, horizontal: bool, value: f32) f32 {
    if (style.box_sizing == .content_box) {
        const inset = styleInsets(style);
        return @max(0, value + if (horizontal) inset.horizontal() else inset.vertical());
    }
    return @max(0, value);
}

fn clampOuter(style: style_mod.Style, horizontal: bool, value: f32, available: geo.AvailableSpace, inset: f32) f32 {
    const parent = available.opt();
    const minimum_dim = if (horizontal) style.min_width else style.min_height;
    const maximum_dim = if (horizontal) style.max_width else style.max_height;
    const minimum = if (minimum_dim.resolve(parent)) |v| toOuter(style, horizontal, v) else 0;
    const maximum = if (maximum_dim.resolve(parent)) |v| toOuter(style, horizontal, v) else std.math.inf(f32);
    var result = @min(@max(minimum, maximum), @max(minimum, value));
    if (available == .definite and value == 0 and inset > 0) result = @max(result, 0);
    return result;
}

test "dispatcher hides display none descendants" {
    var ct = ComputeTree.init();
    const child = ct.tree.newLeaf(.{ .size = .{ .w = 40, .h = 20 } });
    const root = ct.tree.newWithChildren(.{ .display = .flex }, &[_]tree_mod.NodeId{child});
    ct.computeRoot(root, .{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 40), ct.tree.nodes[child].layout.w);
    ct.tree.setStyle(child, .{ .display = .none, .size = .{ .w = 40, .h = 20 } });
    ct.computeRoot(root, .{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 0), ct.tree.nodes[child].layout.w);
}

test "dispatcher lays out a fixed row with gap and grow" {
    var ct = ComputeTree.init();
    const a = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 20 } });
    const b = ct.tree.newLeaf(.{ .size = .{ .w = 10, .h = 20 }, .flex_grow = 1 });
    const root = ct.tree.newWithChildren(.{ .display = .flex, .flex_direction = .row, .gap_col = .{ .length = 10 } }, &[_]tree_mod.NodeId{ a, b });
    ct.computeRoot(root, .{ .w = 100, .h = 40 });
    try std.testing.expectEqual(@as(f32, 10), ct.tree.nodes[a].layout.w);
    try std.testing.expectApproxEqAbs(@as(f32, 80), ct.tree.nodes[b].layout.w, 0.001);
    try std.testing.expectEqual(@as(f32, 20), ct.tree.nodes[b].layout.x);
}

test "dispatcher applies padding and nested reflow" {
    var ct = ComputeTree.init();
    const child = ct.tree.newLeaf(.{ .width = .auto, .height = .{ .length = 10 } });
    const root = ct.tree.newWithChildren(.{ .display = .block, .padding = .all(5) }, &[_]tree_mod.NodeId{child});
    ct.computeRoot(root, .{ .w = 100, .h = 40 });
    try std.testing.expectEqual(@as(f32, 90), ct.tree.nodes[child].layout.w);
    try std.testing.expectEqual(@as(f32, 5), ct.tree.nodes[child].layout.x);
    try std.testing.expectEqual(@as(f32, 5), ct.tree.nodes[child].layout.y);
}

test "dispatcher places absolute child from right and bottom" {
    var ct = ComputeTree.init();
    const child = ct.tree.newLeaf(.{ .position = .absolute, .size = .{ .w = 20, .h = 10 }, .inset_right = .{ .length = 3 }, .inset_bottom = .{ .length = 4 } });
    const root = ct.tree.newWithChildren(.{ .display = .block }, &[_]tree_mod.NodeId{child});
    ct.computeRoot(root, .{ .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 77), ct.tree.nodes[child].layout.x);
    try std.testing.expectEqual(@as(f32, 36), ct.tree.nodes[child].layout.y);
}
