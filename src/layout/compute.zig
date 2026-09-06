//! Dispatcher — port of Taffy `compute/mod.rs` (scaffold).
//!
//! Owns the parallel `NodeCache` pool, picks kernel by `Style.display`,
//! threads `LayoutInput` down and writes `Layout` up. Absolute-positioned
//! subtrees are scoped here (Taffy #917 pattern) so flex/grid kernels never
//! see them in normal flow.

const core = @import("../core/root.zig");
const tree_mod = @import("tree.zig");
const geo = @import("geometry.zig");
const cache_mod = @import("cache.zig");
const flex_mod = @import("flex.zig");
const grid_mod = @import("grid.zig");
const block_mod = @import("block.zig");

pub const ComputeTree = struct {
    tree: tree_mod.LayoutTree = .{},
    caches: [tree_mod.max_nodes]cache_mod.NodeCache = undefined,

    pub fn init() ComputeTree {
        var self = ComputeTree{};
        self.reset();
        return self;
    }

    pub fn reset(self: *ComputeTree) void {
        self.tree.reset();
        for (&self.caches) |*c| c.clear();
    }

    pub fn computeRoot(self: *ComputeTree, root: tree_mod.NodeId, available: core.Size) void {
        const input = geo.LayoutInput{
            .known = .{ .w = available.w, .h = available.h },
            .available = .{ .w = .{ .definite = available.w }, .h = .{ .definite = available.h } },
        };
        self.compute(root, input, 0);
    }

    fn compute(self: *ComputeTree, id: tree_mod.NodeId, input: geo.LayoutInput, depth: usize) void {
        if (depth > tree_mod.max_depth) @panic("ZUI layout depth exceeded");
        const node = &self.tree.nodes[id];
        if (node.style.display == .none) {
            node.layout = .{};
            self.tree.markClean(id);
            return;
        }
        // Cache probe (Taffy `compute_cached_layout`).
        const key = cache_mod.CacheKey{
            .known_w = input.known.w,
            .known_h = input.known.h,
            .avail_w = input.available.w,
            .avail_h = input.available.h,
            .sizing = input.sizing_mode,
        };
        if (!node.dirty) {
            if (self.caches[id].get(key)) |hit| {
                node.layout.w = hit.w;
                node.layout.h = hit.h;
                return;
            }
        }
        switch (node.style.display) {
            .flex => flex_mod.computeFlex(&self.tree, id, input),
            .grid => grid_mod.computeGrid(&self.tree, id, input),
            .block => block_mod.computeBlock(&self.tree, id, input),
            .none => unreachable,
        }
        self.caches[id].put(key, .{ .w = node.layout.w, .h = node.layout.h });
        self.tree.markClean(id);
    }
};

test "dispatcher hides display:none" {
    const testing = @import("std").testing;
    var ct = ComputeTree.init();
    const id = ct.tree.newLeaf(.{ .display = .none });
    ct.computeRoot(id, .{ .w = 100, .h = 100 });
    try testing.expectEqual(@as(f32, 0), ct.tree.nodes[id].layout.w);
}
