//! AccessKit bridge: publishes ZUI's per-frame semantic tree
//! (`src/a11y/root.zig`) to platform accessibility APIs through the vendored
//! accesskit C ABI (`third_party/accesskit`, built with cargo, linked with
//! `-Daccesskit=true`).
//!
//! Architecture mirrors DVUI's `AccessKit.zig` and Gooey's accessibility
//! layer, with ZUI's advantages kept:
//!  - The semantic model stays framework-independent (`src/a11y/root.zig`);
//!    this module is a translation layer only (Gooey's lesson: keep the
//!    binding out of the tree code).
//!  - ZUI stable keys ARE AccessKit node ids (`u64`), and ZUI diagnoses
//!    duplicate keys per frame — AccessKit's documented duplicate-ID pitfall
//!    (nodes silently dropped in release builds) cannot happen silently.
//!  - Bounds come from the semantic tree in LOGICAL pixels, consistent with
//!    the whole pipeline.
//!
//! Ownership (gap report §5.1 fix): the bridge stores a ZUI-owned snapshot
//! (plain structs with duped strings) — never accesskit node pointers. The
//! tree-update factory constructs FRESH accesskit nodes from the snapshot on
//! every call and hands ownership to `accesskit_tree_update_push_node`, whose
//! contract takes ownership. No C node pointer survives a factory call, so
//! repeated update callbacks and publish rebuilds cannot free or resend
//! consumed nodes.
//!
//! Root attachment (gap report §5.1 fix): the factory sends a synthetic
//! WINDOW root (node id 0, matching `tree_info(root = 0)`) and attaches every
//! snapshot node whose ZUI parent is 0 (top-level semantic roots) as its
//! children. A semantically annotated frame therefore publishes a complete,
//! navigable tree from the first activation.
//!
//! Threading (per AccessKit's unix adapter docs, all handlers run on
//! non-GUI threads): publish/drain run on the UI thread; the factory reads
//! the owned snapshot under the shared mutex. Action requests are decoded
//! AT-queue time (data copied out, request freed immediately) so queued
//! copies never reference freed AccessKit memory.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const enabled = build_options.accesskit;
pub const c = if (enabled) @import("accesskit_c") else struct {};
const a11y = @import("root.zig");
const Window = @import("../app/window.zig").Window;
const zlog = @import("../core/log.zig");

const max_action_requests = 64;

/// ZUI role → AccessKit role. Pure mapping, compiled when enabled.
pub fn roleFromZui(role: a11y.Role) u8 {
    if (!enabled) unreachable;
    return switch (role) {
        .group => c.ACCESSKIT_ROLE_GROUP,
        .button => c.ACCESSKIT_ROLE_BUTTON,
        .checkbox => c.ACCESSKIT_ROLE_CHECK_BOX,
        .radio_group => c.ACCESSKIT_ROLE_RADIO_GROUP,
        .radio => c.ACCESSKIT_ROLE_RADIO_BUTTON,
        .switch_control => c.ACCESSKIT_ROLE_SWITCH,
        .slider => c.ACCESSKIT_ROLE_SLIDER,
        .progress => c.ACCESSKIT_ROLE_PROGRESS_INDICATOR,
        .text_input => c.ACCESSKIT_ROLE_TEXT_INPUT,
        .label => c.ACCESSKIT_ROLE_LABEL,
        .dialog => c.ACCESSKIT_ROLE_DIALOG,
        .list => c.ACCESSKIT_ROLE_LIST,
        .listitem => c.ACCESSKIT_ROLE_LIST_ITEM,
        .menu => c.ACCESSKIT_ROLE_MENU,
        .menuitem => c.ACCESSKIT_ROLE_MENU_ITEM,
        .menuitem_checkbox => c.ACCESSKIT_ROLE_CHECK_BOX,
        .tooltip => c.ACCESSKIT_ROLE_TOOLTIP,
        .combobox => c.ACCESSKIT_ROLE_COMBO_BOX,
        .listbox => c.ACCESSKIT_ROLE_LIST_BOX,
        .option => c.ACCESSKIT_ROLE_LIST_BOX_OPTION,
        .table => c.ACCESSKIT_ROLE_TABLE,
        .row => c.ACCESSKIT_ROLE_ROW,
        .tableheader => c.ACCESSKIT_ROLE_COLUMN_HEADER,
        .cell => c.ACCESSKIT_ROLE_CELL,
    };
}

/// ZUI action → AccessKit action.
pub fn actionFromZui(action: a11y.Action) u8 {
    if (!enabled) unreachable;
    return switch (action) {
        .activate => c.ACCESSKIT_ACTION_CLICK,
        .increment => c.ACCESSKIT_ACTION_INCREMENT,
        .decrement => c.ACCESSKIT_ACTION_DECREMENT,
        .set_value => c.ACCESSKIT_ACTION_SET_VALUE,
        .focus => c.ACCESSKIT_ACTION_FOCUS,
    };
}

/// One ZUI-owned semantic snapshot entry. Strings are duped so the snapshot
/// outlives the frame that produced it (frame text storage resets).
pub const SnapshotNode = struct {
    key: u64,
    parent: u64,
    role: a11y.Role,
    bounds: @import("../core/geometry.zig").Rect,
    name: []u8 = &.{},
    text_value: []u8 = &.{},
    states: a11y.States = .{},
    value: ?a11y.Value = null,
    actions: a11y.Actions = .{},
};

/// Queued AT action with the data extracted at queue time (the C request is
/// freed immediately in the handler, so queued copies own nothing).
pub const QueuedAction = struct {
    action: u8,
    target: u64,
    numeric_value: f64 = 0,
};

const AccesskitNode = if (enabled) c.accesskit_node else anyopaque;

/// Per-window bridge. The adapter starts lazily on the first native frame.
pub const Bridge = struct {
    adapter: Adapter = null,
    /// ZUI-owned snapshot of the last published semantic tree. Protected by
    /// `mutex`; the factory reads it from an AT thread under the same mutex.
    snapshot: []SnapshotNode = &.{},
    snapshot_allocator: ?std.mem.Allocator = null,
    focused_key: u64 = 0,
    requests: [max_action_requests]QueuedAction = undefined,
    request_count: usize = 0,
    request_drops: u64 = 0,
    status: enum { off, starting, on } = .off,
    /// Cross-thread lock for the snapshot/actions queue. AccessKit's
    /// handlers arrive on assistive-technology threads, publish/drain run
    /// on the UI thread. Brief critical sections, rare contention.
    mutex: std.atomic.Mutex = .unlocked,

    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *Bridge) void {
        self.mutex.unlock();
    }

    const Adapter = if (enabled) ?*c.accesskit_unix_adapter else ?*anyopaque;

    pub fn init() Bridge {
        return .{};
    }

    /// Create the platform adapter. The unix adapter needs no window
    /// pointer (it talks to the AT-SPI bus).
    pub fn start(self: *Bridge, win: *Window) void {
        if (!enabled) return;
        if (builtin.os.tag != .linux) return; // windows/macos adapters: next step
        self.adapter = c.accesskit_unix_adapter_new(activationHandler, self, actionHandler, self, deactivationHandler, self) orelse {
            zlog.log("a11y", "accesskit adapter creation failed; accessibility stays off", .{});
            return;
        };
        zlog.log("a11y", "accesskit unix adapter created (window {d})", .{win.id});
    }

    pub fn deinit(self: *Bridge, allocator: std.mem.Allocator) void {
        if (!enabled) return;
        if (builtin.os.tag == .linux) {
            if (self.adapter) |adapter| c.accesskit_unix_adapter_free(adapter);
            self.adapter = null;
        }
        self.freeSnapshot(allocator);
    }

    fn freeSnapshot(self: *Bridge, allocator: std.mem.Allocator) void {
        self.lock();
        defer self.unlock();
        for (self.snapshot) |*node| {
            if (node.name.len > 0) allocator.free(node.name);
            if (node.text_value.len > 0) allocator.free(node.text_value);
        }
        if (self.snapshot.len > 0) allocator.free(self.snapshot);
        self.snapshot = &.{};
        if (self.snapshot_allocator == null) self.snapshot_allocator = allocator;
    }

    /// UI thread, after the painter rebuilt the semantic tree: rebuild the
    /// ZUI-owned snapshot. No accesskit objects are constructed here; the
    /// factory builds them fresh per update. The adapter starts lazily on
    /// the first native frame.
    pub fn publish(self: *Bridge, win: *Window) void {
        if (!enabled) return;
        if (self.adapter == null and win.native_backend != null) self.start(win);
        const allocator = win.allocator orelse std.heap.page_allocator;
        const tree = &win.ui_frame.semantic_tree;
        self.lock();
        defer self.unlock();
        // The snapshot is refreshed even while .off so activation (which can
        // happen at any moment) always publishes the CURRENT tree next
        // factory call.
        for (self.snapshot) |*old| {
            if (old.name.len > 0) allocator.free(old.name);
            if (old.text_value.len > 0) allocator.free(old.text_value);
        }
        if (self.snapshot.len != tree.count) {
            if (self.snapshot.len > 0) allocator.free(self.snapshot);
            self.snapshot = allocator.alloc(SnapshotNode, tree.count) catch &.{};
            if (self.snapshot.len == 0) return;
        }
        for (tree.nodes[0..tree.count], 0..) |*node, i| {
            const name: []u8 = allocator.dupe(u8, node.properties.name) catch &.{};
            const text_value: []u8 = allocator.dupe(u8, node.properties.text_value) catch &.{};
            self.snapshot[i] = .{
                .key = node.key,
                .parent = node.parent,
                .role = node.properties.role,
                .bounds = node.bounds,
                .name = name,
                .text_value = text_value,
                .states = node.properties.states,
                .value = node.properties.value,
                .actions = node.properties.actions,
            };
        }
        // Focused semantic node: the semantic node whose focus handle is the
        // window's focused handle. Zero when none (root focus).
        self.focused_key = 0;
        for (tree.nodes[0..tree.count]) |*node| {
            if (node.focus) |handle| if (win.focused.eql(handle)) {
                self.focused_key = node.key;
            };
        }
    }

    /// UI thread, once per App.step: forward queued AT action requests into
    /// the current semantic tree.
    pub fn drain(self: *Bridge, win: *Window) void {
        if (!enabled or self.adapter == null) return;
        self.lock();
        const count = self.request_count;
        const requests = self.requests[0..count];
        self.request_count = 0;
        self.unlock();
        for (requests) |request| self.perform(request, win);
    }

    fn perform(self: *Bridge, request: QueuedAction, win: *Window) void {
        _ = self;
        const tree = &win.ui_frame.semantic_tree;
        const key: u64 = request.target;
        switch (request.action) {
            c.ACCESSKIT_ACTION_CLICK => _ = tree.perform(key, .{ .action = .activate }, win),
            c.ACCESSKIT_ACTION_INCREMENT => _ = tree.perform(key, .{ .action = .increment }, win),
            c.ACCESSKIT_ACTION_DECREMENT => _ = tree.perform(key, .{ .action = .decrement }, win),
            c.ACCESSKIT_ACTION_SET_VALUE => _ = tree.perform(key, .{ .action = .set_value, .value = request.numeric_value }, win),
            c.ACCESSKIT_ACTION_FOCUS => _ = tree.perform(key, .{ .action = .focus }, win),
            else => {},
        }
    }

    // -- accesskit callbacks (any thread) ---------------------------------
    fn activationHandler(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        self.lock();
        defer self.unlock();
        if (self.status == .off) self.status = .starting;
        // Initial tree: the synthetic window root only; the full tree
        // arrives with the next per-frame update.
        const update = c.accesskit_tree_update_with_capacity_and_focus(1, 0);
        const root = c.accesskit_node_new(c.ACCESSKIT_ROLE_WINDOW) orelse {
            c.accesskit_tree_update_free(update);
            return null;
        };
        const tree = c.accesskit_tree_info_new(0);
        c.accesskit_tree_update_set_tree_info(update, tree);
        c.accesskit_tree_update_push_node(update, 0, root);
        return update;
    }

    fn actionHandler(raw_request: ?*c.accesskit_action_request, userdata: ?*anyopaque) callconv(.c) void {
        defer c.accesskit_action_request_free(raw_request);
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        const request = raw_request orelse return;
        // Extract everything we need NOW; the C request is freed above, so
        // queued copies must not reference its memory.
        const queued: QueuedAction = .{
            .action = request.action,
            .target = request.target_node,
            .numeric_value = if (request.data.has_value and
                request.data.value.tag == c.ACCESSKIT_ACTION_DATA_NUMERIC_VALUE)
                request.data.value.unnamed_0.unnamed_2.numeric_value
            else
                0,
        };
        self.lock();
        defer self.unlock();
        if (self.request_count < max_action_requests) {
            self.requests[self.request_count] = queued;
            self.request_count += 1;
        } else {
            // Observable, never silent (gap report §5.1).
            self.request_drops += 1;
            zlog.log("a11y", "accesskit action queue full ({d}); request dropped", .{max_action_requests});
        }
    }

    fn deactivationHandler(userdata: ?*anyopaque) callconv(.c) void {
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        self.lock();
        defer self.unlock();
        self.status = .off;
    }

    /// Tree-update factory, called by the adapter from an AT thread when the
    /// platform wants a fresh tree. Builds FRESH accesskit nodes from the
    /// ZUI-owned snapshot and transfers ownership to AccessKit. A synthetic
    /// WINDOW root (node 0) carries every top-level semantic child, and each
    /// nested node is declared as a child of its snapshot parent, so
    /// annotated controls attach to the platform tree (gap report §5.1).
    /// AccessKit declares children on the PARENT: pushing a nested node
    /// without wiring its edge orphans it and the consumer rejects the whole
    /// update, so edges are wired before any node is transferred. A node
    /// whose parent is missing from the snapshot (or failed to build) falls
    /// back to the synthetic root to keep every update a valid tree.
    fn updateFactory(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        self.lock();
        defer self.unlock();
        const update = c.accesskit_tree_update_with_capacity_and_focus(self.snapshot.len + 1, self.focused_key);
        // Synthetic window root: role WINDOW, full logical bounds, children
        // attached below. NEVER null: when no frame has been published yet
        // this synthetic root alone is still a complete, valid tree update.
        const root = c.accesskit_node_new(c.ACCESSKIT_ROLE_WINDOW) orelse {
            c.accesskit_tree_update_free(update);
            return null;
        };
        var built: [a11y.capacity]?*AccesskitNode = undefined;
        @memset(&built, null);
        for (self.snapshot, 0..) |*node, i| {
            if (i >= built.len) break;
            built[i] = buildAccesskitNode(node);
        }
        for (self.snapshot, 0..) |*node, i| {
            if (i >= built.len or built[i] == null) continue;
            if (node.parent == 0) {
                c.accesskit_node_push_child(root, node.key);
                continue;
            }
            var parent_built: ?*AccesskitNode = null;
            for (self.snapshot, 0..) |*candidate, pi| {
                if (pi >= built.len) break;
                if (candidate.key == node.parent) {
                    parent_built = built[pi];
                    break;
                }
            }
            if (parent_built) |parent| {
                c.accesskit_node_push_child(parent, node.key);
            } else {
                c.accesskit_node_push_child(root, node.key);
            }
        }
        for (self.snapshot, 0..) |*node, i| {
            if (i >= built.len) break;
            if (built[i]) |ak| c.accesskit_tree_update_push_node(update, node.key, ak);
        }
        c.accesskit_tree_update_push_node(update, 0, root);
        return update;
    }

    /// Push the UI-thread snapshot to the AT (once per frame, after paint).
    pub fn updateIfActive(self: *Bridge) void {
        if (!enabled or self.adapter == null) return;
        if (builtin.os.tag == .linux) {
            c.accesskit_unix_adapter_update_if_active(self.adapter.?, updateFactory, self);
        }
    }
};

/// Build one fresh accesskit node from a snapshot entry. Ownership
/// transfers to `accesskit_tree_update_push_node`.
fn buildAccesskitNode(node: *const SnapshotNode) ?*AccesskitNode {
    const ak = c.accesskit_node_new(roleFromZui(node.role)) orelse return null;
    c.accesskit_node_set_bounds(ak, .{
        .x0 = node.bounds.x,
        .y0 = node.bounds.y,
        .x1 = node.bounds.x + @max(node.bounds.w, 1),
        .y1 = node.bounds.y + @max(node.bounds.h, 1),
    });
    if (node.name.len > 0) c.accesskit_node_set_label_with_length(ak, node.name.ptr, node.name.len);
    if (node.text_value.len > 0) c.accesskit_node_set_value_with_length(ak, node.text_value.ptr, node.text_value.len);
    const s = node.states;
    if (s.disabled) c.accesskit_node_set_disabled(ak);
    if (s.hidden) c.accesskit_node_set_hidden(ak);
    if (s.modal) c.accesskit_node_set_modal(ak);
    if (s.read_only) c.accesskit_node_set_read_only(ak);
    if (s.expanded) |expanded| c.accesskit_node_set_expanded(ak, expanded);
    if (s.selected) c.accesskit_node_set_selected(ak, true);
    if (s.checked) |checked| c.accesskit_node_set_toggled(ak, if (checked) c.ACCESSKIT_TOGGLED_TRUE else c.ACCESSKIT_TOGGLED_FALSE);
    if (node.value) |value| {
        c.accesskit_node_set_numeric_value(ak, value.current);
        c.accesskit_node_set_min_numeric_value(ak, value.min);
        c.accesskit_node_set_max_numeric_value(ak, value.max);
        if (value.step > 0) c.accesskit_node_set_numeric_value_step(ak, value.step);
    }
    if (node.actions.activate) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_CLICK);
    if (node.actions.increment) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_INCREMENT);
    if (node.actions.decrement) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_DECREMENT);
    if (node.actions.set_value) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_SET_VALUE);
    if (node.actions.focus) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_FOCUS);
    return ak;
}

test "role and action mappings compile against the vendored header" {
    if (!enabled) return error.SkipZigTest;
    // Every ZUI role maps to a real AccessKit role (u8 in the C ABI).
    _ = roleFromZui(.group);
    _ = roleFromZui(.button);
    _ = roleFromZui(.checkbox);
    _ = roleFromZui(.switch_control);
    _ = roleFromZui(.slider);
    _ = roleFromZui(.table);
    _ = roleFromZui(.row);
    _ = roleFromZui(.tableheader);
    _ = roleFromZui(.cell);
    _ = actionFromZui(.activate);
    _ = actionFromZui(.set_value);
    _ = actionFromZui(.focus);
}

test "bridge snapshot lifecycle is ownership-clean" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    var bridge = Bridge.init();
    // No adapter: publish/drain are safe no-ops and the snapshot stays empty
    // (deinit frees nothing borrowed).
    bridge.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), bridge.snapshot.len);
}
