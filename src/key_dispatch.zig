//! Key dispatch: the per-frame tree of nodes that key and action listeners, key contexts, focus
//! ids and tab stops hang off (GPUI key_dispatch.rs and tab_stop.rs).
//!
//! Nodes are pushed while the element tree is prepainted. Node 0 is the root (the first node
//! pushed). A node records its listeners, its `KeyContext` and an optional focus id. Dispatch
//! walks from the focused node up to the root; the keymap is consulted with the context stack
//! collected along that path.
//!
//! Nodes live in one array. `clear` keeps every node's listener capacity for the next frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const Window = @import("window.zig").Window;
const App = app_mod.App;
const TypeId = app_mod.TypeId;

pub const KeyContext = @import("keymap_context.zig").KeyContext;

/// Index of a node within a `DispatchTree`. Not stable across frames.
pub const DispatchNodeId = u32;

/// Whether a listener runs while the event travels down (`capture`) or up (`bubble`).
pub const DispatchPhase = enum {
    capture,
    bubble,

    pub fn is_bubble(self: DispatchPhase) bool {
        return self == .bubble;
    }

    pub fn is_capture(self: DispatchPhase) bool {
        return self == .capture;
    }
};

pub const ActionFn = *const fn (ctx: *anyopaque, action: *const anyopaque, phase: DispatchPhase, window: *Window, cx: *App) void;
pub const KeyListenerFn = *const fn (ctx: *anyopaque, event: *const anyopaque, phase: DispatchPhase, window: *Window, cx: *App) void;

pub const KeyListener = struct {
    event_type: TypeId,
    ctx: *anyopaque,
    func: KeyListenerFn,
};

pub const ActionListener = struct {
    action_type: TypeId,
    ctx: *anyopaque,
    func: ActionFn,
};

pub const DispatchNode = struct {
    parent: ?DispatchNodeId = null,
    key_listeners: std.ArrayList(KeyListener) = .empty,
    action_listeners: std.ArrayList(ActionListener) = .empty,
    context: ?KeyContext = null,
    focus_id: ?u64 = null,
    tab_index: isize = 0,
    tab_stop: bool = false,

    /// Clears the node for reuse, keeping listener capacity.
    fn reset(self: *DispatchNode, parent: ?DispatchNodeId) void {
        self.parent = parent;
        self.key_listeners.clearRetainingCapacity();
        self.action_listeners.clearRetainingCapacity();
        self.context = null;
        self.focus_id = null;
        self.tab_index = 0;
        self.tab_stop = false;
    }
};

fn oom() noreturn {
    @panic("out of memory");
}

pub const DispatchTree = struct {
    gpa: Allocator,
    /// Node storage. Only the first `count` entries are live; the rest are reusable.
    nodes: std.ArrayList(DispatchNode) = .empty,
    count: usize = 0,
    node_stack: std.ArrayList(DispatchNodeId) = .empty,
    focusable: std.AutoHashMapUnmanaged(u64, DispatchNodeId) = .empty,

    pub fn init(gpa: Allocator) DispatchTree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DispatchTree) void {
        for (self.nodes.items) |*n| {
            n.key_listeners.deinit(self.gpa);
            n.action_listeners.deinit(self.gpa);
        }
        self.nodes.deinit(self.gpa);
        self.node_stack.deinit(self.gpa);
        self.focusable.deinit(self.gpa);
    }

    /// Empties the tree for the next frame, keeping allocated capacity.
    pub fn clear(self: *DispatchTree) void {
        self.count = 0;
        self.node_stack.clearRetainingCapacity();
        self.focusable.clearRetainingCapacity();
    }

    /// Number of live nodes.
    pub fn len(self: *const DispatchTree) usize {
        return self.count;
    }

    /// Pushes a child of the active node (or a root if none is active) and makes it active.
    pub fn push_node(self: *DispatchTree) void {
        const parent: ?DispatchNodeId = if (self.node_stack.items.len > 0)
            self.node_stack.items[self.node_stack.items.len - 1]
        else
            null;
        const id: DispatchNodeId = @intCast(self.count);
        if (self.count < self.nodes.items.len) {
            self.nodes.items[self.count].reset(parent);
        } else {
            self.nodes.append(self.gpa, .{ .parent = parent }) catch oom();
        }
        self.count += 1;
        self.node_stack.append(self.gpa, id) catch oom();
    }

    /// Makes the parent of the active node active again.
    pub fn pop_node(self: *DispatchTree) void {
        std.debug.assert(self.node_stack.items.len > 0);
        _ = self.node_stack.pop();
    }

    /// The active (most recently pushed, not yet popped) node.
    pub fn active_node_id(self: *const DispatchTree) DispatchNodeId {
        std.debug.assert(self.node_stack.items.len > 0);
        return self.node_stack.items[self.node_stack.items.len - 1];
    }

    fn active_node(self: *DispatchTree) *DispatchNode {
        return &self.nodes.items[self.active_node_id()];
    }

    /// Sets the key context of the active node.
    pub fn set_key_context(self: *DispatchTree, context: KeyContext) void {
        self.active_node().context = context;
    }

    /// Marks the active node as focusable with the given id and tab order.
    pub fn set_focus_id(self: *DispatchTree, id: u64, tab_index: isize, tab_stop: bool) void {
        const node_id = self.active_node_id();
        const active = &self.nodes.items[node_id];
        active.focus_id = id;
        active.tab_index = tab_index;
        active.tab_stop = tab_stop;
        self.focusable.put(self.gpa, id, node_id) catch oom();
    }

    /// Attaches a key listener to the active node.
    pub fn on_key_event(self: *DispatchTree, listener: KeyListener) void {
        self.active_node().key_listeners.append(self.gpa, listener) catch oom();
    }

    /// Attaches an action listener to the active node.
    pub fn on_action(self: *DispatchTree, listener: ActionListener) void {
        self.active_node().action_listeners.append(self.gpa, listener) catch oom();
    }

    /// The node with this id. The returned pointer is valid until the next `push_node`.
    pub fn node(self: *const DispatchTree, id: DispatchNodeId) *DispatchNode {
        std.debug.assert(id < self.count);
        return &self.nodes.items[id];
    }

    /// Whether the focus `child` is `parent` or lies beneath it.
    pub fn focus_contains(self: *const DispatchTree, parent: u64, child: u64) bool {
        if (parent == child) return true;
        const parent_node = self.focusable.get(parent) orelse return false;
        var current = self.focusable.get(child);
        while (current) |id| {
            if (id == parent_node) return true;
            current = self.nodes.items[id].parent;
        }
        return false;
    }

    /// Root-to-focused path of node ids. If `focus_id` is null or unknown, the path is just the
    /// root (or empty if there are no nodes). The caller frees the slice with `allocator`.
    pub fn dispatch_path(self: *const DispatchTree, focus_id: ?u64, allocator: Allocator) []DispatchNodeId {
        var start: ?DispatchNodeId = null;
        if (focus_id) |fid| start = self.focusable.get(fid);
        if (start == null and self.count > 0) start = 0;

        var path: std.ArrayList(DispatchNodeId) = .empty;
        errdefer path.deinit(allocator);
        var current = start;
        while (current) |id| {
            path.append(allocator, id) catch oom();
            current = self.nodes.items[id].parent;
        }
        std.mem.reverse(DispatchNodeId, path.items);
        return path.toOwnedSlice(allocator) catch oom();
    }

    /// The key contexts along `path`, root first. The caller frees the slice with `allocator`.
    pub fn context_stack(self: *const DispatchTree, path: []const DispatchNodeId, allocator: Allocator) []KeyContext {
        var out: std.ArrayList(KeyContext) = .empty;
        errdefer out.deinit(allocator);
        for (path) |id| {
            if (self.nodes.items[id].context) |ctx| out.append(allocator, ctx) catch oom();
        }
        return out.toOwnedSlice(allocator) catch oom();
    }

    /// The next (`forward`) or previous focusable tab stop after `current`, wrapping around.
    /// Stops are ordered by `tab_index`, then by tree order, as in GPUI's tab_stop.rs. Without a
    /// current focus (or if it is unknown) this returns the first, or last when going backward.
    pub fn next_tab_stop(self: *const DispatchTree, current: ?u64, forward: bool) ?u64 {
        const cur: ?TabKey = if (current) |fid| blk: {
            const nid = self.focusable.get(fid) orelse break :blk null;
            break :blk TabKey.of(&self.nodes.items[nid], nid);
        } else null;

        var nearest: ?Candidate = null;
        var extreme: ?Candidate = null;
        for (self.nodes.items[0..self.count], 0..) |*n, i| {
            if (!n.tab_stop) continue;
            const focus = n.focus_id orelse continue;
            const key = TabKey.of(n, @intCast(i));
            const cand = Candidate{ .key = key, .focus = focus };

            // Overall extreme: first stop going forward, last going backward (wrap target).
            if (extreme) |e| {
                const better = if (forward) key.less(e.key) else e.key.less(key);
                if (better) extreme = cand;
            } else {
                extreme = cand;
            }

            // Nearest stop strictly after (forward) or before (backward) the current one.
            if (cur) |c| {
                const in_direction = if (forward) c.less(key) else key.less(c);
                if (in_direction) {
                    if (nearest) |near| {
                        const closer = if (forward) key.less(near.key) else near.key.less(key);
                        if (closer) nearest = cand;
                    } else {
                        nearest = cand;
                    }
                }
            }
        }
        if (nearest) |c| return c.focus;
        if (extreme) |c| return c.focus;
        return null;
    }

    const TabKey = struct {
        tab_index: isize,
        node: DispatchNodeId,

        fn of(n: *const DispatchNode, id: DispatchNodeId) TabKey {
            return .{ .tab_index = n.tab_index, .node = id };
        }

        fn less(a: TabKey, b: TabKey) bool {
            if (a.tab_index != b.tab_index) return a.tab_index < b.tab_index;
            return a.node < b.node;
        }
    };

    const Candidate = struct { key: TabKey, focus: u64 };
};

// ---------------------------------------------------------------------------
// Tests (ported from GPUI tab_stop.rs, plus path and focus checks)

const testing = std.testing;

/// Builds a flat tree: root node 0 with one child per focus handle.
const Builder = struct {
    tree: DispatchTree,
    next_focus: u64 = 1,

    fn init() Builder {
        var b = Builder{ .tree = DispatchTree.init(testing.allocator) };
        b.tree.push_node(); // root
        return b;
    }

    fn deinit(self: *Builder) void {
        self.tree.deinit();
    }

    /// Adds a focusable child of the root and returns its focus id.
    fn handle(self: *Builder, tab_index: isize, tab_stop: bool) u64 {
        const id = self.next_focus;
        self.next_focus += 1;
        self.tree.push_node();
        self.tree.set_focus_id(id, tab_index, tab_stop);
        self.tree.pop_node();
        return id;
    }

    /// Adds a child that is not focusable.
    fn plain(self: *Builder) void {
        self.tree.push_node();
        self.tree.pop_node();
    }
};

test "tab handles follow tab_index then tree order" {
    var b = Builder.init();
    defer b.deinit();
    const h0 = b.handle(0, true);
    const h1 = b.handle(1, true);
    const h2 = b.handle(1, true);
    _ = b.handle(0, false); // not a stop, plain focus
    const h4 = b.handle(2, false);
    const h5 = b.handle(0, true);
    const h6 = b.handle(2, true);
    _ = h4;

    const expected = [_]u64{ h0, h5, h1, h2, h6 };

    var prev: ?u64 = null;
    for (expected) |want| {
        const got = b.tree.next_tab_stop(prev, true).?;
        try testing.expectEqual(want, got);
        prev = got;
    }
    try testing.expectEqual(@as(?u64, h0), b.tree.next_tab_stop(null, true));
    try testing.expectEqual(@as(?u64, h6), b.tree.next_tab_stop(null, false));
    try testing.expectEqual(@as(?u64, h5), b.tree.next_tab_stop(h0, true));
    try testing.expectEqual(@as(?u64, h1), b.tree.next_tab_stop(h5, true));
    try testing.expectEqual(@as(?u64, h2), b.tree.next_tab_stop(h1, true));
    try testing.expectEqual(@as(?u64, h6), b.tree.next_tab_stop(h2, true));
    try testing.expectEqual(@as(?u64, h0), b.tree.next_tab_stop(h6, true));

    // Backward.
    try testing.expectEqual(@as(?u64, h6), b.tree.next_tab_stop(h0, false));
    try testing.expectEqual(@as(?u64, h0), b.tree.next_tab_stop(h5, false));
    try testing.expectEqual(@as(?u64, h5), b.tree.next_tab_stop(h1, false));
    try testing.expectEqual(@as(?u64, h1), b.tree.next_tab_stop(h2, false));
    try testing.expectEqual(@as(?u64, h2), b.tree.next_tab_stop(h6, false));
}

test "tab stops skip non-stops, including as the origin" {
    var b = Builder.init();
    defer b.deinit();
    const non_stop_1 = b.handle(1, false);
    const stop_2 = b.handle(2, true);
    try testing.expectEqual(@as(?u64, stop_2), b.tree.next_tab_stop(non_stop_1, true));
    const stop_0 = b.handle(0, true);
    _ = b.handle(0, false);
    try testing.expectEqual(@as(?u64, stop_2), b.tree.next_tab_stop(stop_0, true));
}

test "tab stops with no stops return null" {
    var b = Builder.init();
    defer b.deinit();
    _ = b.handle(0, false);
    try testing.expectEqual(@as(?u64, null), b.tree.next_tab_stop(null, true));
}

test "single tab stop cycles to itself" {
    var b = Builder.init();
    defer b.deinit();
    const only = b.handle(0, true);
    try testing.expectEqual(@as(?u64, only), b.tree.next_tab_stop(only, true));
    try testing.expectEqual(@as(?u64, only), b.tree.next_tab_stop(only, false));
}

test "dispatch path, context stack and focus containment" {
    var tree = DispatchTree.init(testing.allocator);
    defer tree.deinit();

    tree.push_node(); // 0: root
    tree.set_key_context(KeyContext.parse("Workspace") catch unreachable);
    tree.push_node(); // 1: pane, focusable
    tree.set_focus_id(10, 0, false);
    tree.push_node(); // 2: editor, focusable, with context
    tree.set_focus_id(20, 0, true);
    tree.set_key_context(KeyContext.parse("Editor vim_mode=normal") catch unreachable);
    tree.pop_node(); // back to pane
    tree.pop_node(); // back to root
    tree.push_node(); // 3: sibling of the pane, no focus and no context
    tree.pop_node();

    try testing.expectEqual(@as(usize, 4), tree.len());
    try testing.expectEqual(@as(?DispatchNodeId, 0), tree.node(3).parent);

    const path = tree.dispatch_path(20, testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualSlices(DispatchNodeId, &.{ 0, 1, 2 }, path);

    const contexts = tree.context_stack(path, testing.allocator);
    defer testing.allocator.free(contexts);
    try testing.expectEqual(@as(usize, 2), contexts.len);
    try testing.expect(contexts[0].contains("Workspace"));
    try testing.expectEqualStrings("normal", contexts[1].get("vim_mode").?);

    // Unknown or missing focus falls back to the root.
    const root_only = tree.dispatch_path(null, testing.allocator);
    defer testing.allocator.free(root_only);
    try testing.expectEqualSlices(DispatchNodeId, &.{0}, root_only);
    const unknown = tree.dispatch_path(99, testing.allocator);
    defer testing.allocator.free(unknown);
    try testing.expectEqualSlices(DispatchNodeId, &.{0}, unknown);

    try testing.expect(tree.focus_contains(10, 20));
    try testing.expect(tree.focus_contains(20, 20));
    try testing.expect(!tree.focus_contains(20, 10));
    try testing.expect(!tree.focus_contains(10, 99));
}

test "clear reuses node storage" {
    var b = Builder.init();
    defer b.deinit();
    _ = b.handle(0, true);
    const cap_before = b.tree.nodes.capacity;
    b.tree.clear();
    try testing.expectEqual(@as(usize, 0), b.tree.len());
    try testing.expectEqual(@as(?u64, null), b.tree.next_tab_stop(null, true));
    b.tree.push_node();
    try testing.expectEqual(@as(DispatchNodeId, 0), b.tree.active_node_id());
    try testing.expect(b.tree.nodes.capacity >= cap_before);
}
