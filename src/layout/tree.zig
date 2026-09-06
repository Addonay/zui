//! Node tree: zero-alloc storage for the layout forest.
//!
//! Ports the storage half of Taffy's `tree/taffy_tree.rs` (the `TaffyTree`
//! node table) and the traversal half of `tree/traits.rs`
//! (`TraversePartialTree`: parent/child/sibling queries).
//!
//! ## Layout (SoA, not AoS)
//!
//! Nodes live in one fixed pool, `nodes: [MAX_LAYOUT_ELEMENTS]Node`, indexed
//! by `u16` [`NodeId`]. Children form a singly-linked sibling list
//! (`first_child` / `next_sibling` + `last_child` for O(1) append), exactly
//! like Taffy's `children: Vec<NodeId>` but without per-node allocation.
//! Parallel concerns — cached sizes ([`cache.NodeCache`]), measure hooks
//! ([`measure.LeafMeasure`]), kernel scratch — live in *sibling arrays* in
//! `compute.zig`, not in [`Node`], so the hot `Node` struct stays small and
//! the tree module never imports the kernels (no import cycle).
//!
//! ## Memory budget
//!
//! `Node` is ~64 bytes; 4096 nodes ≈ 256 KiB of BSS. There is deliberately
//! no `remove`/`free`: trees are rebuilt per frame from the element layer
//! (`Frame` arena) and `reset()` reuses the pool. This matches the
//! frame-arena discipline in `core/limits.zig`: zero allocation after init.
//!
//! ## Dirty tracking
//!
//! Every structural or style edit marks the node *and all ancestors* dirty
//! via [`LayoutTree.markDirty`] (Yoga-style `markDirtyAndPropagate`). The
//! walk stops at [`max_depth`] with a panic rather than silent stack
//! overflow — depth is bounded by construction (`MAX_NESTED_COMPONENTS`).
//! Size *caching* is a separate layer ([`cache`]): dirty nodes recompute,
//! clean nodes with a matching key reuse their size, and the placement walk
//! always runs so child origins stay correct after a parent moves.

const core = @import("../core/root.zig");
const style_mod = @import("style.zig");
const geo = @import("geometry.zig");

/// Index into [`LayoutTree.nodes`]. `u16` covers the 4096-node cap with room
/// to spare and keeps child links at 2 bytes each.
pub const NodeId = u16;

/// Absent link (no parent / no sibling / no child).
pub const null_id: ?NodeId = null;

/// Pool capacity. Mirrors `core.limits.MAX_LAYOUT_ELEMENTS`; kept as a local
/// alias so array lengths can use it in type position.
pub const max_nodes: usize = core.limits.MAX_LAYOUT_ELEMENTS;

/// Recursion guard. Mirrors `core.limits.MAX_NESTED_COMPONENTS`; both the
/// tree walk and the compute dispatcher enforce it.
pub const max_depth: usize = core.limits.MAX_NESTED_COMPONENTS;

/// One layout node: style input, tree links, layout output, dirty flag.
///
/// - `style` is the *only* input the kernels read (plus measure hooks).
/// - `layout` coordinates are relative to the parent's padding-box origin
///   (see [`geo.Layout`]); the dispatcher adds the parent origin.
/// - `layout.w/h` doubles as the "measured size" mailbox between the
///   measure pass and the arrange pass inside one `computeNode` call.
/// - `measure_index` is reserved for a future interned measure-table; today
///   `compute.zig` keys hooks by `NodeId` directly. Kept (not removed) so
///   serialized trees stay forward-compatible.
pub const Node = struct {
    style: style_mod.Style = .{},
    parent: ?NodeId = null,
    first_child: ?NodeId = null,
    last_child: ?NodeId = null,
    next_sibling: ?NodeId = null,
    layout: geo.Layout = .{},
    dirty: bool = true,
    measure_index: ?u32 = null,
};

/// The layout forest. One instance per window/frame; reuse via [`reset`].
pub const LayoutTree = struct {
    /// Dense pool: live nodes occupy `nodes[0..count]`, in creation order.
    /// `undefined` until written — only indices below `count` may be read,
    /// which `newLeaf` guarantees by bumping `count` after writing.
    nodes: [max_nodes]Node = undefined,
    count: usize = 0,

    /// Drop all nodes, keeping the backing store. O(1).
    pub fn reset(self: *LayoutTree) void {
        self.count = 0;
    }

    /// Number of live nodes.
    pub fn len(self: *const LayoutTree) usize {
        return self.count;
    }

    /// Create a leaf node (no children yet). Panics at capacity with a
    /// message telling the user which cap to raise — silent truncation
    /// would produce overlapping widgets that are miserable to debug.
    pub fn newLeaf(self: *LayoutTree, s: style_mod.Style) NodeId {
        if (self.count >= max_nodes) @panic("ZUI layout node limit exceeded (raise MAX_LAYOUT_ELEMENTS)");
        const id: NodeId = @intCast(self.count);
        self.count += 1;
        self.nodes[id] = .{ .style = s, .dirty = true };
        return id;
    }

    /// Create a node with children attached in order.
    pub fn newWithChildren(self: *LayoutTree, s: style_mod.Style, children: []const NodeId) NodeId {
        const id = self.newLeaf(s);
        for (children) |c| self.attach(id, c);
        return id;
    }

    /// Append `child` to `parent`'s child list (O(1) via `last_child`).
    /// Marks ancestors dirty. The child must be parent-less (fresh from
    /// `newLeaf`); reparenting is done by building a new tree per frame.
    pub fn attach(self: *LayoutTree, parent: NodeId, child: NodeId) void {
        std.debug.assert(child != parent);
        const p = &self.nodes[parent];
        self.nodes[child].parent = parent;
        self.nodes[child].next_sibling = null;
        if (p.last_child) |last| {
            self.nodes[last].next_sibling = child;
        } else {
            p.first_child = child;
        }
        p.last_child = child;
        self.markDirty(parent);
    }

    /// Count children by walking the sibling list. O(n) — fine for tests
    /// and tree building; kernels walk the list directly instead.
    pub fn childCount(self: *const LayoutTree, id: NodeId) usize {
        var n: usize = 0;
        var c = self.nodes[id].first_child;
        while (c) |ci| : (c = self.nodes[ci].next_sibling) n += 1;
        return n;
    }

    /// True for nodes with no children (measure-hook candidates).
    pub fn isLeaf(self: *const LayoutTree, id: NodeId) bool {
        return self.nodes[id].first_child == null;
    }

    /// Mark `id` and all ancestors dirty (Yoga `markDirtyAndPropagate`).
    /// Panics past [`max_depth`] instead of overflowing the call stack.
    pub fn markDirty(self: *LayoutTree, id: NodeId) void {
        var cur: ?NodeId = id;
        var depth: usize = 0;
        while (cur) |ci| : (cur = self.nodes[ci].parent) {
            self.nodes[ci].dirty = true;
            depth += 1;
            if (depth > max_depth) @panic("ZUI layout depth exceeded (raise MAX_NESTED_COMPONENTS?)");
        }
    }

    /// Clear the dirty flag after a successful compute.
    pub fn markClean(self: *LayoutTree, id: NodeId) void {
        self.nodes[id].dirty = false;
    }

    pub fn isDirty(self: *const LayoutTree, id: NodeId) bool {
        return self.nodes[id].dirty;
    }

    /// Replace a node's style (e.g. hover state) and dirty the subtree.
    /// Cheaper than rebuilding the tree for state flips.
    pub fn setStyle(self: *LayoutTree, id: NodeId, s: style_mod.Style) void {
        self.nodes[id].style = s;
        self.markDirty(id);
    }
};

const std = @import("std");

test "tree attach links siblings in order" {
    const testing = std.testing;
    var t = LayoutTree{};
    const root = t.newLeaf(.{});
    const a = t.newLeaf(.{});
    const b = t.newLeaf(.{});
    t.attach(root, a);
    t.attach(root, b);
    try testing.expectEqual(@as(usize, 2), t.childCount(root));
    try testing.expect(t.isDirty(root));
    try testing.expectEqual(a, t.nodes[root].first_child.?);
    try testing.expectEqual(b, t.nodes[root].last_child.?);
    try testing.expectEqual(b, t.nodes[a].next_sibling.?);
    try testing.expect(t.nodes[b].next_sibling == null);
    try testing.expectEqual(root, t.nodes[a].parent.?);
}

test "tree new with children preserves order" {
    const testing = std.testing;
    var t = LayoutTree{};
    const a = t.newLeaf(.{});
    const b = t.newLeaf(.{});
    const kids = [_]NodeId{ a, b };
    const root = t.newWithChildren(.{}, &kids);
    try testing.expectEqual(@as(usize, 2), t.childCount(root));
    try testing.expectEqual(a, t.nodes[root].first_child.?);
}

test "tree leaf detection" {
    const testing = std.testing;
    var t = LayoutTree{};
    const root = t.newLeaf(.{});
    const kid = t.newLeaf(.{});
    try testing.expect(t.isLeaf(root));
    t.attach(root, kid);
    try testing.expect(!t.isLeaf(root));
    try testing.expect(t.isLeaf(kid));
}

test "tree set style dirties ancestors" {
    const testing = std.testing;
    var t = LayoutTree{};
    const root = t.newLeaf(.{});
    const kid = t.newLeaf(.{});
    t.attach(root, kid);
    t.markClean(root);
    t.markClean(kid);
    try testing.expect(!t.isDirty(root));
    t.setStyle(kid, .{ .flex_grow = 1 });
    try testing.expect(t.isDirty(kid));
    try testing.expect(t.isDirty(root));
    try testing.expectEqual(@as(f32, 1), t.nodes[kid].style.flex_grow);
}

test "tree reset reuses pool" {
    const testing = std.testing;
    var t = LayoutTree{};
    _ = t.newLeaf(.{});
    _ = t.newLeaf(.{});
    try testing.expectEqual(@as(usize, 2), t.len());
    t.reset();
    try testing.expectEqual(@as(usize, 0), t.len());
    const r = t.newLeaf(.{});
    try testing.expectEqual(@as(NodeId, 0), r);
}
