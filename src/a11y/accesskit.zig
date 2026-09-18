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
//!    the whole pipeline (DVUI used physical; ZUI's contract is logical).
//!
//! Threading (per AccessKit's unix adapter docs, all handlers run on
//! non-GUI threads): the UI thread builds accesskit nodes into `nodes`
//! under `mutex` during publish; the tree-update factory reads only that
//! map; action requests queue under `mutex` and are drained on the UI
//! thread into `a11y.Tree.perform`.
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

/// ZUI action → AccessKit action. Returns null for the read-only Progress
/// (no activate action is advertised, so nothing maps).
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

/// Per-window bridge. Created lazily on native windows (`start`); the unix
/// adapter exists for Linux/BSD; Windows/macOS adapters are the documented
/// next step (their branches compile only with AccessKit enabled on those
/// targets, which the current CI does not exercise).
pub const Bridge = struct {
    adapter: Adapter = null,
    /// UI-thread snapshot of the last frame's semantic nodes, keyed by the
    /// ZUI stable key (== AccessKit node id). Protected by `mutex`; the
    /// tree-update factory reads it from an AT thread under the same mutex.
    nodes: NodeMap = .empty,
    requests: [max_action_requests]ActionRequest = undefined,
    request_count: usize = 0,
    status: enum { off, starting, on } = .off,
    /// Cross-thread lock for the snapshot/actions queues. AccessKit's
    /// handlers arrive on assistive-technology threads, publish/drain run
    /// on the UI thread. `std.atomic.Mutex` is the process snapshot's
    /// lock-free primitive: brief critical sections, rare contention.
    mutex: std.atomic.Mutex = .unlocked,

    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *Bridge) void {
        self.mutex.unlock();
    }

    const Adapter = if (enabled) ?*c.accesskit_unix_adapter else ?*anyopaque;
    const AccesskitNode = if (enabled) c.accesskit_node else anyopaque;
    const NodeMap = std.AutoHashMapUnmanaged(u64, *AccesskitNode);

    pub fn init() Bridge {
        return .{};
    }

    /// Create the platform adapter. Unix adapter needs no window pointer
    /// (it talks to the AT-SPI bus), so it works headless too.
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
        self.clearNodes(allocator);
    }

    fn clearNodes(self: *Bridge, allocator: std.mem.Allocator) void {
        self.lock();
        defer self.unlock();
        var it = self.nodes.iterator();
        while (it.next()) |item| c.accesskit_node_free(item.value_ptr.*);
        self.nodes.deinit(allocator);
        self.nodes = .{};
    }

    /// UI thread, after the painter rebuilt the semantic tree: snapshot
    /// every node into an accesskit node. The AT-visible tree update is
    /// pushed from this snapshot by the factory callback.
    pub fn publish(self: *Bridge, win: *Window) void {
        if (!enabled) return;
        if (self.adapter == null and win.native_backend != null) self.start(win);
        if (self.adapter == null) return;
        const allocator = win.allocator orelse std.heap.page_allocator;
        const tree = &win.ui_frame.semantic_tree;
        self.lock();
        defer self.unlock();
        switch (self.status) {
            .off => return, // activation handler sets .starting when an AT connects
            .starting => self.status = .on,
            .on => {},
        }
        // Rebuild the snapshot; ownership of previous nodes transfers here.
        var it = self.nodes.iterator();
        while (it.next()) |item| c.accesskit_node_free(item.value_ptr.*);
        self.nodes.clearRetainingCapacity();
        for (tree.nodes[0..tree.count]) |*node| {
            const ak = a11yNode(node) orelse continue;
            self.nodes.put(allocator, node.key, ak) catch {
                c.accesskit_node_free(ak);
                continue;
            };
        }
        // Parent-child edges from the ZUI tree (stable keys both sides).
        for (tree.nodes[0..tree.count]) |*node| {
            if (node.parent == 0) continue;
            const parent = self.nodes.get(node.parent) orelse continue;
            c.accesskit_node_push_child(parent, node.key);
        }
        if (builtin.os.tag == .linux) {
            // Root window bounds (X11 only; Wayland cannot know them).
            c.accesskit_unix_adapter_set_root_window_bounds(self.adapter.?, .{
                .x0 = 0,
                .y0 = 0,
                .x1 = @as(f64, win.bounds.size.w),
                .y1 = @as(f64, win.bounds.size.h),
            }, .{ .x0 = 0, .y0 = 0, .x1 = @as(f64, win.bounds.size.w), .y1 = @as(f64, win.bounds.size.h) });
        }
    }

    /// UI thread, once per App.step: forward queued AT action requests into
    /// the current semantic tree. Requests queue from any thread.
    pub fn drain(self: *Bridge, win: *Window) void {
        if (!enabled or self.adapter == null) return;
        self.lock();
        const count = self.request_count;
        const requests = self.requests[0..count];
        self.request_count = 0;
        self.unlock();
        for (requests) |request| self.perform(request, win);
    }

    fn perform(self: *Bridge, request: ActionRequest, win: *Window) void {
        _ = self;
        const tree = &win.ui_frame.semantic_tree;
        const key: u64 = request.target_node;
        switch (request.action) {
            c.ACCESSKIT_ACTION_CLICK => _ = tree.perform(key, .{ .action = .activate }, win),
            c.ACCESSKIT_ACTION_INCREMENT => _ = tree.perform(key, .{ .action = .increment }, win),
            c.ACCESSKIT_ACTION_DECREMENT => _ = tree.perform(key, .{ .action = .decrement }, win),
            c.ACCESSKIT_ACTION_SET_VALUE => {
                if (request.data.has_value) {
                    const value: f64 = switch (request.data.value.tag) {
                        c.ACCESSKIT_ACTION_DATA_NUMERIC_VALUE => request.data.value.unnamed_0.unnamed_2.numeric_value,
                        else => 0,
                    };
                    _ = tree.perform(key, .{ .action = .set_value, .value = value }, win);
                }
            },
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
        const root = c.accesskit_node_new(c.ACCESSKIT_ROLE_WINDOW);
        const tree = c.accesskit_tree_info_new(0);
        const update = c.accesskit_tree_update_with_capacity_and_focus(1, 0);
        c.accesskit_tree_update_set_tree_info(update, tree);
        c.accesskit_tree_update_push_node(update, 0, root);
        return update;
    }

    fn actionHandler(raw_request: ?*c.accesskit_action_request, userdata: ?*anyopaque) callconv(.c) void {
        defer c.accesskit_action_request_free(raw_request);
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        const request = raw_request orelse return;
        self.lock();
        defer self.unlock();
        if (self.request_count < max_action_requests) {
            self.requests[self.request_count] = request.*;
            self.request_count += 1;
        }
    }

    fn deactivationHandler(userdata: ?*anyopaque) callconv(.c) void {
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        self.lock();
        defer self.unlock();
        self.status = .off;
    }

    /// Tree-update factory, called by the adapter from an AT thread when the
    /// platform wants a fresh tree. Pushes the snapshot built on the UI
    /// thread; AccessKit takes ownership of every node.
    fn updateFactory(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        self.lock();
        defer self.unlock();
        if (self.status != .on) return null;
        const update = c.accesskit_tree_update_with_capacity_and_focus(self.nodes.count() + 1, 0);
        const tree = c.accesskit_tree_info_new(0);
        c.accesskit_tree_update_set_tree_info(update, tree);
        var it = self.nodes.iterator();
        while (it.next()) |item| {
            c.accesskit_tree_update_push_node(update, item.key_ptr.*, item.value_ptr.*);
        }
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

/// Build one accesskit node from a ZUI semantic node. Caller frees (or the
/// bridge map takes ownership).
fn a11yNode(node: *const a11y.Node) ?*c.accesskit_node {
    const ak = c.accesskit_node_new(roleFromZui(node.properties.role));
    c.accesskit_node_set_bounds(ak, .{
        .x0 = node.bounds.x,
        .y0 = node.bounds.y,
        .x1 = node.bounds.x + @max(node.bounds.w, 1),
        .y1 = node.bounds.y + @max(node.bounds.h, 1),
    });
    if (node.properties.name.len > 0) c.accesskit_node_set_label_with_length(ak, node.properties.name.ptr, node.properties.name.len);
    if (node.properties.text_value.len > 0) c.accesskit_node_set_value_with_length(ak, node.properties.text_value.ptr, node.properties.text_value.len);
    const s = node.properties.states;
    if (s.disabled) c.accesskit_node_set_disabled(ak);
    if (s.hidden) c.accesskit_node_set_hidden(ak);
    if (s.modal) c.accesskit_node_set_modal(ak);
    if (s.read_only) c.accesskit_node_set_read_only(ak);
    if (s.expanded) |expanded| c.accesskit_node_set_expanded(ak, expanded);
    if (s.selected) c.accesskit_node_set_selected(ak, true);
    if (s.checked) |checked| c.accesskit_node_set_toggled(ak, if (checked) c.ACCESSKIT_TOGGLED_TRUE else c.ACCESSKIT_TOGGLED_FALSE);
    if (node.properties.value) |value| {
        c.accesskit_node_set_numeric_value(ak, value.current);
        c.accesskit_node_set_min_numeric_value(ak, value.min);
        c.accesskit_node_set_max_numeric_value(ak, value.max);
        if (value.step > 0) c.accesskit_node_set_numeric_value_step(ak, value.step);
    }
    if (node.properties.actions.activate) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_CLICK);
    if (node.properties.actions.increment) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_INCREMENT);
    if (node.properties.actions.decrement) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_DECREMENT);
    if (node.properties.actions.set_value) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_SET_VALUE);
    if (node.properties.actions.focus) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_FOCUS);
    return ak;
}

const ActionRequest = if (enabled) c.accesskit_action_request else struct {};

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
