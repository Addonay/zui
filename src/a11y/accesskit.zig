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
const max_action_text = 1024;

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
        .set_text_selection => c.ACCESSKIT_ACTION_SET_TEXT_SELECTION,
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
    /// UTF-8 byte length for each Unicode scalar in text_value.
    character_lengths: []u8 = &.{},
    character_positions: []f32 = &.{},
    character_widths: []f32 = &.{},
    /// Source byte ranges for the character-indexed geometry. AccessKit
    /// consumes positions/widths; ZUI retains ranges for richer framework
    /// consumers and deterministic editing diagnostics.
    text_ranges: []a11y.TextRange = &.{},
    states: a11y.States = .{},
    value: ?a11y.Value = null,
    text_selection: ?a11y.TextSelection = null,
    /// Stable semantic relationships carried through to AccessKit. A zero
    /// id means that the relationship is absent, matching Properties.
    labelled_by: u64 = 0,
    described_by: u64 = 0,
    controls: u64 = 0,
    active_descendant: u64 = 0,
    position_in_set: ?usize = null,
    set_size: ?usize = null,
    actions: a11y.Actions = .{},
};

/// Queued AT action with the data extracted at queue time (the C request is
/// freed immediately in the handler, so queued copies own nothing).
pub const QueuedAction = struct {
    action: u8,
    target: u64,
    numeric_value: f64 = 0,
    text: [max_action_text]u8 = undefined,
    text_len: u16 = 0,
    selection: ?a11y.TextSelection = null,
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
    /// Number of semantic frames rejected because the producer reported an
    /// incomplete tree. The last known-good snapshot remains published.
    snapshot_rejections: u64 = 0,
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
    /// Create the platform adapter. Only for REAL native backends: a
    /// headless (null-backend) window has no screen reader attached, and
    /// spawning the adapter's AT threads there only widens the teardown
    /// race documented on `deinit` for zero benefit.
    pub fn start(self: *Bridge, win: *Window) void {
        if (!enabled) return;
        if (builtin.os.tag != .linux) return; // windows/macos adapters: next step
        const backend = win.native_backend orelse return;
        if (backend.kind() == .null) return;
        self.adapter = c.accesskit_unix_adapter_new(activationHandler, self, actionHandler, self, deactivationHandler, self) orelse {
            zlog.log("a11y", "accesskit adapter creation failed; accessibility stays off", .{});
            return;
        };
        zlog.log("a11y", "accesskit unix adapter created (window {d})", .{win.id});
    }

    pub fn deinit(self: *Bridge, allocator: std.mem.Allocator) void {
        if (!enabled) return;
        // RESIDUAL RACE (honest limitation, see docs/A11Y_PLAN.md): the
        // vendored C ABI has no join/quiesce, so an assistive-technology
        // thread inside a callback at this exact instant can touch this
        // Bridge after it is freed. The adapter only ever starts on real
        // native backends (see `start`), so headless runs never spawn AT
        // threads; live, app exit races an almost-always-idle callback.
        // Upstream fix: a join API, or immortal callback state (leaked).
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
            if (node.character_lengths.len > 0) allocator.free(node.character_lengths);
            if (node.character_positions.len > 0) allocator.free(node.character_positions);
            if (node.character_widths.len > 0) allocator.free(node.character_widths);
            if (node.text_ranges.len > 0) allocator.free(node.text_ranges);
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
        if (tree.dropped != 0 or tree.duplicate_keys != 0 or tree.unkeyed != 0 or tree.invalid_utf8 != 0) {
            self.snapshot_rejections += 1;
            zlog.log("a11y", "semantic snapshot rejected: incomplete tree (dropped={d}, duplicate_keys={d}, unkeyed={d}, invalid_utf8={d})", .{ tree.dropped, tree.duplicate_keys, tree.unkeyed, tree.invalid_utf8 });
            return;
        }
        // The snapshot is refreshed even while .off so activation (which can
        // happen at any moment) always publishes the CURRENT tree next
        // factory call.
        for (self.snapshot) |*old| {
            if (old.name.len > 0) allocator.free(old.name);
            if (old.text_value.len > 0) allocator.free(old.text_value);
            if (old.character_lengths.len > 0) allocator.free(old.character_lengths);
            if (old.character_positions.len > 0) allocator.free(old.character_positions);
            if (old.character_widths.len > 0) allocator.free(old.character_widths);
            if (old.text_ranges.len > 0) allocator.free(old.text_ranges);
        }
        if (self.snapshot.len != tree.count) {
            if (self.snapshot.len > 0) allocator.free(self.snapshot);
            self.snapshot = allocator.alloc(SnapshotNode, tree.count) catch &.{};
            if (self.snapshot.len == 0) return;
        }
        for (tree.nodes[0..tree.count], 0..) |*node, i| {
            const name: []u8 = allocator.dupe(u8, node.properties.name) catch &.{};
            const text_value: []u8 = allocator.dupe(u8, node.properties.text_value) catch &.{};
            const character_lengths: []u8 = makeCharacterLengths(allocator, text_value) catch &.{};
            var character_positions: []f32 = &.{};
            var character_widths: []f32 = &.{};
            var text_ranges: []a11y.TextRange = &.{};
            var text_selection: ?a11y.TextSelection = null;
            for (win.ui_frame.nodes[0..win.ui_frame.node_count], 0..) |frame_node, frame_index| {
                if (frame_node.stable_key == node.key) {
                    text_selection = win.ui_frame.textSelectionForNode(@intCast(frame_index));
                    if (win.ui_frame.textGeometryForNode(@intCast(frame_index))) |geometry| {
                        character_positions = allocator.dupe(f32, geometry.positions) catch &.{};
                        character_widths = allocator.dupe(f32, geometry.widths) catch &.{};
                        text_ranges = allocator.dupe(a11y.TextRange, geometry.ranges) catch &.{};
                    }
                    break;
                }
            }
            self.snapshot[i] = .{
                .key = node.key,
                .parent = node.parent,
                .role = node.properties.role,
                .bounds = node.bounds,
                .name = name,
                .text_value = text_value,
                .character_lengths = character_lengths,
                .character_positions = character_positions,
                .character_widths = character_widths,
                .text_ranges = text_ranges,
                .states = node.properties.states,
                .value = node.properties.value,
                .text_selection = text_selection,
                .labelled_by = node.properties.labelled_by,
                .described_by = node.properties.described_by,
                .controls = node.properties.controls,
                .active_descendant = node.properties.active_descendant,
                .position_in_set = node.properties.position_in_set,
                .set_size = node.properties.set_size,
                .actions = node.properties.actions,
            };
        }
        // Focused semantic node: the semantic node whose focus handle is the
        // window's focused handle. GPUI reports an active descendant as the
        // platform focus when the focused container claims one of its actual
        // descendants, so apply the same rule here.
        self.focused_key = 0;
        for (tree.nodes[0..tree.count]) |*node| {
            if (node.focus) |handle| if (win.focused.eql(handle)) {
                self.focused_key = node.key;
                if (node.properties.active_descendant != 0 and
                    snapshotContainsDescendant(self.snapshot, node.key, node.properties.active_descendant))
                    self.focused_key = node.properties.active_descendant;
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
            c.ACCESSKIT_ACTION_SET_VALUE => _ = tree.perform(key, .{ .action = .set_value, .value = request.numeric_value, .text = request.text[0..request.text_len] }, win),
            c.ACCESSKIT_ACTION_SET_TEXT_SELECTION => _ = tree.perform(key, .{ .action = .set_text_selection, .selection = request.selection }, win),
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
        var queued: QueuedAction = .{
            .action = request.action,
            .target = request.target_node,
            .numeric_value = if (request.data.has_value and
                request.data.value.tag == c.ACCESSKIT_ACTION_DATA_NUMERIC_VALUE)
                request.data.value.unnamed_0.unnamed_2.numeric_value
            else
                0,
        };
        if (request.data.has_value and request.data.value.tag == c.ACCESSKIT_ACTION_DATA_VALUE) {
            if (request.data.value.unnamed_0.unnamed_1.value) |value| {
                const bytes = std.mem.span(value);
                const len = @min(bytes.len, max_action_text);
                @memcpy(queued.text[0..len], bytes[0..len]);
                queued.text_len = @intCast(len);
            }
        }
        if (request.data.has_value and request.data.value.tag == c.ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION) {
            const selection = request.data.value.unnamed_0.unnamed_7.set_text_selection;
            queued.selection = .{
                .anchor = @intCast(selection.anchor.character_index),
                .focus = @intCast(selection.focus.character_index),
            };
        }
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

fn makeCharacterLengths(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return &.{};
    var count: usize = 0;
    var byte: usize = 0;
    while (byte < text.len) : (count += 1) {
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }
    const lengths = try allocator.alloc(u8, count);
    byte = 0;
    var index: usize = 0;
    while (byte < text.len) : (index += 1) {
        const length = std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
        lengths[index] = length;
        byte += length;
    }
    return lengths;
}

fn snapshotContainsDescendant(snapshot: []const SnapshotNode, ancestor: u64, candidate: u64) bool {
    if (ancestor == candidate or candidate == 0) return false;
    var current = candidate;
    var steps: usize = 0;
    while (current != 0 and steps < snapshot.len) : (steps += 1) {
        var parent: ?u64 = null;
        for (snapshot) |node| if (node.key == current) {
            parent = node.parent;
            break;
        };
        const p = parent orelse return false;
        if (p == ancestor) return true;
        current = p;
    }
    return false;
}

fn scalarCount(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    }
    return count;
}

fn clampSelection(selection: a11y.TextSelection, text: []const u8) a11y.TextSelection {
    const count = scalarCount(text);
    return .{
        .anchor = @intCast(@min(@as(usize, selection.anchor), count)),
        .focus = @intCast(@min(@as(usize, selection.focus), count)),
    };
}

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
    if (node.character_lengths.len > 0) c.accesskit_node_set_character_lengths(ak, node.character_lengths.len, node.character_lengths.ptr);
    if (node.character_positions.len > 0 and node.character_positions.len == node.character_widths.len) {
        c.accesskit_node_set_character_positions(ak, node.character_positions.len, node.character_positions.ptr);
        c.accesskit_node_set_character_widths(ak, node.character_widths.len, node.character_widths.ptr);
    }
    if (node.text_selection) |selection| {
        const safe_selection = clampSelection(selection, node.text_value);
        c.accesskit_node_set_text_selection(ak, .{
            .anchor = .{ .node = node.key, .character_index = safe_selection.anchor },
            .focus = .{ .node = node.key, .character_index = safe_selection.focus },
        });
    }
    if (node.labelled_by != 0) c.accesskit_node_push_labelled_by(ak, node.labelled_by);
    if (node.described_by != 0) c.accesskit_node_push_described_by(ak, node.described_by);
    if (node.controls != 0) {
        const ids = [_]c.accesskit_node_id{node.controls};
        c.accesskit_node_set_controls(ak, ids.len, &ids);
    }
    if (node.active_descendant != 0) c.accesskit_node_set_active_descendant(ak, node.active_descendant);
    if (node.position_in_set) |position| c.accesskit_node_set_position_in_set(ak, position);
    if (node.set_size) |size| c.accesskit_node_set_size_of_set(ak, size);
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
    if (node.actions.set_text_selection) c.accesskit_node_add_action(ak, c.ACCESSKIT_ACTION_SET_TEXT_SELECTION);
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
    _ = actionFromZui(.set_text_selection);
    _ = actionFromZui(.focus);
}

test "accesskit character lengths preserve UTF-8 scalar byte widths" {
    const lengths = try makeCharacterLengths(std.testing.allocator, "Aé你");
    defer std.testing.allocator.free(lengths);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, lengths);
}

test "accesskit selection clamps to UTF-8 scalar boundaries" {
    const selection = clampSelection(.{ .anchor = 99, .focus = 2 }, "Aé你");
    try std.testing.expectEqual(@as(u32, 3), selection.anchor);
    try std.testing.expectEqual(@as(u32, 2), selection.focus);
}

test "active descendant focus only accepts a real descendant" {
    const bounds = @import("../core/geometry.zig").Rect{};
    const snapshot = [_]SnapshotNode{
        .{ .key = 10, .parent = 0, .role = .listbox, .bounds = bounds },
        .{ .key = 11, .parent = 10, .role = .option, .bounds = bounds },
        .{ .key = 12, .parent = 0, .role = .option, .bounds = bounds },
    };
    try std.testing.expect(snapshotContainsDescendant(&snapshot, 10, 11));
    try std.testing.expect(!snapshotContainsDescendant(&snapshot, 10, 12));
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

test "bridge rejects incomplete semantic snapshots without replacing the last good one" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    const TestApp = @import("../app/app.zig").App;
    var app = try TestApp.initHeadless(t.allocator);
    defer app.deinit();

    const win = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *@import("../gpu/scene.zig").Scene) void {}
    }.draw);
    const tree = &win.ui_frame.semantic_tree;
    tree.* = .{};
    tree.nodes[0] = .{
        .key = 7,
        .parent = 0,
        .bounds = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .properties = .{ .role = .button, .name = "last-good" },
    };
    tree.count = 1;

    win.a11y_bridge.publish(win);
    try t.expectEqual(@as(u64, 0), win.a11y_bridge.snapshot_rejections);
    try t.expectEqualStrings("last-good", win.a11y_bridge.snapshot[0].name);

    tree.nodes[0].properties.name = "rejected-dropped";
    tree.dropped = 1;
    win.a11y_bridge.publish(win);
    tree.dropped = 0;

    tree.nodes[0].properties.name = "rejected-duplicate";
    tree.duplicate_keys = 1;
    win.a11y_bridge.publish(win);
    tree.duplicate_keys = 0;

    tree.nodes[0].properties.name = "rejected-unkeyed";
    tree.unkeyed = 1;
    win.a11y_bridge.publish(win);
    tree.unkeyed = 0;

    try t.expectEqual(@as(u64, 3), win.a11y_bridge.snapshot_rejections);
    try t.expectEqual(@as(usize, 1), win.a11y_bridge.snapshot.len);
    try t.expectEqualStrings("last-good", win.a11y_bridge.snapshot[0].name);
}
