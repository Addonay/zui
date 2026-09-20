//! Focus traversal, scopes, and modal trap/restore (§5C).
//!
//! Window delegates unmodified Tab/Shift-Tab to this module before focused
//! dispatch. Modal hosts use pushScope/popScope; the traversal list follows
//! paint order (`ui_frame.regions`), deduplicating shared focus handles.
//! Disabled/hidden semantic targets and dead owners are excluded.

const std = @import("std");
const elements = @import("../elements/root.zig");
const Window = @import("../app/window.zig").Window;

/// A focus scope: a subset of focus ids that traversal is constrained to.
/// `modal` marks a trap (dialog): movement wraps inside and never leaves;
/// non-modal scopes (toolbars, sidebars) behave the same until the host
/// calls `restore` or focuses elsewhere directly. `restore_to` is the
/// focus that was live when the scope opened.
pub const Scope = struct {
    ids: []const u32 = &.{},
    modal: bool = false,
    restore_to: elements.FocusHandle = .{},
    /// Optional owner for portal-backed scopes. A nonzero owner lets Window
    /// clear the scope safely when the overlay entity is destroyed or absent
    /// from a later frame, without dereferencing stale `ids` storage.
    owner: elements.FocusHandle = .{},

    pub fn contains(self: Scope, id: u32) bool {
        for (self.ids) |candidate| if (candidate == id) return true;
        return false;
    }
};

/// Stable tab-stop description mirroring GPUI's grouped tab-stop ordering.
/// Lower indices come first; insertion order breaks ties deterministically.
pub const TabStop = struct { id: u32, tab_index: i32 = 0, insertion: usize = 0 };
pub const TraversalEvent = enum { begin, candidate, skipped, focused, wrapped, end };
pub const TraversalTrace = struct {
    events: [128]TraversalEvent = undefined,
    ids: [128]u32 = undefined,
    len: usize = 0,
    pub fn record(self: *@This(), event: TraversalEvent, id: u32) void {
        if (self.len >= self.events.len) return;
        self.events[self.len] = event;
        self.ids[self.len] = id;
        self.len += 1;
    }
};

/// Sort an explicit tab-stop list without allocation. Negative indices are
/// intentionally placed after ordinary stops, matching GPUI's “not in the
/// normal tab order” convention while retaining deterministic traversal.
pub fn orderTabStops(stops: []TabStop) void {
    var i: usize = 1;
    while (i < stops.len) : (i += 1) {
        const value = stops[i];
        var j = i;
        while (j > 0 and tabBefore(value, stops[j - 1])) : (j -= 1) stops[j] = stops[j - 1];
        stops[j] = value;
    }
}

fn tabBefore(a: TabStop, b: TabStop) bool {
    const ai: i64 = if (a.tab_index < 0) std.math.maxInt(i32) else a.tab_index;
    const bi: i64 = if (b.tab_index < 0) std.math.maxInt(i32) else b.tab_index;
    return ai < bi or (ai == bi and a.insertion < b.insertion);
}

pub fn traverseTabStops(stops: []TabStop, current: ?u32, backwards: bool, trace: ?*TraversalTrace) ?u32 {
    if (stops.len == 0) return null;
    orderTabStops(stops);
    if (trace) |out| out.record(.begin, current orelse 0);
    var index: usize = if (current) |id| blk: {
        for (stops, 0..) |stop, i| if (stop.id == id) break :blk i;
        break :blk if (backwards) 0 else stops.len - 1;
    } else if (backwards) stops.len else 0;
    const start = index;
    while (true) {
        if (backwards) {
            if (index == 0) index = stops.len - 1 else index -= 1;
        } else index = (index + 1) % stops.len;
        if (trace) |out| out.record(.candidate, stops[index].id);
        if (stops[index].tab_index >= 0) {
            if (index == start and current != null) {
                if (trace) |out| out.record(.wrapped, stops[index].id);
            }
            if (trace) |out| {
                out.record(.focused, stops[index].id);
                out.record(.end, stops[index].id);
            }
            return stops[index].id;
        }
        if (trace) |out| out.record(.skipped, stops[index].id);
        if (index == start) break;
    }
    if (trace) |out| out.record(.end, 0);
    return null;
}

pub fn moveFocusTraced(win: *Window, scope: ?Scope, delta: i2, trace: *TraversalTrace) bool {
    trace.record(.begin, win.focused.id);
    const moved = moveFocus(win, scope, delta);
    trace.record(if (moved) .focused else .end, if (moved) win.focused.id else 0);
    return moved;
}

/// Collect focusable ids in paint order: regions carrying a focus handle
/// whose owner is still live, deduplicated (one control may own several
/// regions). Returns the count written to `out`.
pub fn collectIds(win: *const Window, out: []u32) usize {
    var n: usize = 0;
    for (win.ui_frame.regions[0..win.ui_frame.region_count]) |region| {
        const handle = region.focus orelse continue;
        if (!region.ownerAlive()) continue;
        if (!handle.isLive()) continue;
        if (handle.id == 0 or !eligible(win, handle.id)) continue;
        var dup = false;
        for (out[0..n]) |seen| if (seen == handle.id) {
            dup = true;
            break;
        };
        if (dup) continue;
        if (n >= out.len) break;
        out[n] = handle.id;
        n += 1;
    }
    return n;
}

/// Move focus one step (`delta` = +1 next, -1 previous) over the scope ids
/// when a scope is given, otherwise over every focusable region. Wraps.
/// Returns true when focus moved (or was already the only candidate).
pub fn moveFocus(win: *Window, scope: ?Scope, delta: i2) bool {
    var buf: [512]u32 = undefined;
    const n = collectIds(win, &buf);
    if (n == 0) return false;

    var list: []u32 = buf[0..n];
    var scoped: [512]u32 = undefined;
    if (scope) |s| {
        var m: usize = 0;
        // Scope order follows paint order, not the scope's id order, so
        // trapping a dialog keeps its visual tab order.
        for (list) |id| if (s.contains(id)) {
            scoped[m] = id;
            m += 1;
        };
        if (m == 0) return false;
        list = scoped[0..m];
    }

    var current: usize = 0;
    var found = false;
    for (list, 0..) |id, i| if (id == win.focused.id) {
        current = i;
        found = true;
        break;
    };
    const next = if (!found)
        (if (delta > 0) @as(usize, 0) else list.len - 1)
    else if (delta > 0)
        (current + 1) % list.len
    else
        (current + list.len - 1) % list.len;
    return focusId(win, list[next]);
}

/// Focus the region owning `id`. False when no live region carries it.
pub fn focusId(win: *Window, id: u32) bool {
    if (!eligible(win, id)) return false;
    for (win.ui_frame.regions[0..win.ui_frame.region_count]) |region| {
        const handle = region.focus orelse continue;
        if (handle.id != id) continue;
        if (!region.ownerAlive()) continue;
        if (!handle.isLive()) continue;
        win.setFocused(handle);
        win.requestRender();
        return true;
    }
    return false;
}

fn eligible(win: *const Window, id: u32) bool {
    for (win.ui_frame.semantic_tree.nodes[0..win.ui_frame.semantic_tree.count]) |node| {
        if (node.focus) |handle| if (handle.id == id) return !node.properties.states.disabled and !node.properties.states.hidden;
    }
    return true;
}

/// Save this token to support nested modal scopes; ids remain host-owned.
pub const ScopeToken = struct { previous: ?Scope, restore_to: elements.FocusHandle };
pub fn pushScope(win: *Window, ids: []const u32, modal: bool) ScopeToken {
    const token = ScopeToken{ .previous = win.focus_scope, .restore_to = win.focused };
    win.focus_scope = .{ .ids = ids, .modal = modal, .restore_to = win.focused };
    if (!focusNext(win, win.focus_scope)) win.setFocused(.{});
    return token;
}
pub fn popScope(win: *Window, token: ScopeToken) void {
    win.focus_scope = token.previous;
    if (!focusId(win, token.restore_to.id)) {
        win.setFocused(.{});
        _ = focusNext(win, win.focus_scope);
    }
    win.requestRender();
}

pub fn focusNext(win: *Window, scope: ?Scope) bool {
    return moveFocus(win, scope, 1);
}

pub fn focusPrev(win: *Window, scope: ?Scope) bool {
    return moveFocus(win, scope, -1);
}

/// Tab entry point for views: call when a Tab keypress was not consumed by
/// the focused control (or when nothing is focused). Moves within `scope`
/// when given and reports whether focus moved.
pub fn handleTab(win: *Window, shift: bool, scope: ?Scope) bool {
    return moveFocus(win, scope, if (shift) -1 else 1);
}

/// Close a scope: return focus to the handle that was live when it opened,
/// falling back to the first scope id when that handle died.
pub fn restore(win: *Window, scope: Scope) bool {
    if (scope.restore_to.id != 0 and scope.restore_to.isLive()) {
        if (focusId(win, scope.restore_to.id)) return true;
    }
    if (scope.ids.len > 0) return focusId(win, scope.ids[0]);
    return false;
}

test "tab order follows paint order with wrap" {
    const t = std.testing;
    const App = @import("../app/app.zig").App;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *(@import("../gpu/root.zig").Scene)) void {}
    }.noop);

    win.ui_frame.region_count = 3;
    win.ui_frame.regions[0] = .{ .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .focus = .{ .id = 11 } };
    win.ui_frame.regions[1] = .{ .bounds = .{ .x = 0, .y = 20, .w = 10, .h = 10 }, .focus = .{ .id = 22 } };
    win.ui_frame.regions[2] = .{ .bounds = .{ .x = 0, .y = 40, .w = 10, .h = 10 }, .focus = .{ .id = 33 } };

    try t.expect(handleTab(win, false, null));
    try t.expectEqual(@as(u32, 11), win.focused.id);
    try t.expect(handleTab(win, false, null));
    try t.expectEqual(@as(u32, 22), win.focused.id);
    try t.expect(handleTab(win, true, null));
    try t.expectEqual(@as(u32, 11), win.focused.id);
    // Shift-Tab from the first wraps to the last.
    try t.expect(handleTab(win, true, null));
    try t.expectEqual(@as(u32, 33), win.focused.id);
    // Tab from the last wraps to the first.
    try t.expect(handleTab(win, false, null));
    try t.expectEqual(@as(u32, 11), win.focused.id);
}

test "dead regions are skipped, duplicates coalesce" {
    const t = std.testing;
    const App = @import("../app/app.zig").App;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *(@import("../gpu/root.zig").Scene)) void {}
    }.noop);

    win.ui_frame.region_count = 4;
    win.ui_frame.regions[0] = .{ .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .focus = .{ .id = 5 } };
    win.ui_frame.regions[1] = .{ .bounds = .{ .x = 0, .y = 10, .w = 10, .h = 10 } }; // no focus: skipped
    win.ui_frame.regions[2] = .{ .bounds = .{ .x = 0, .y = 20, .w = 10, .h = 10 }, .focus = .{ .id = 5 } }; // dup: coalesced
    win.ui_frame.regions[3] = .{ .bounds = .{ .x = 0, .y = 30, .w = 10, .h = 10 }, .focus = .{ .id = 7 } };

    var buf: [8]u32 = undefined;
    try t.expectEqual(@as(usize, 2), collectIds(win, &buf));
    try t.expectEqual(@as(u32, 5), buf[0]);
    try t.expectEqual(@as(u32, 7), buf[1]);
}

test "modal scope traps and restores" {
    const t = std.testing;
    const App = @import("../app/app.zig").App;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *(@import("../gpu/root.zig").Scene)) void {}
    }.noop);

    win.ui_frame.region_count = 3;
    win.ui_frame.regions[0] = .{ .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .focus = .{ .id = 1 } };
    win.ui_frame.regions[1] = .{ .bounds = .{ .x = 0, .y = 20, .w = 10, .h = 10 }, .focus = .{ .id = 2 } };
    win.ui_frame.regions[2] = .{ .bounds = .{ .x = 0, .y = 40, .w = 10, .h = 10 }, .focus = .{ .id = 3 } };
    win.focused = .{ .id = 1 };

    const ids = [_]u32{ 2, 3 };
    const scope = Scope{ .ids = &ids, .modal = true, .restore_to = win.focused };
    // Traversal never leaves the dialog: wraps 2 -> 3 -> 2.
    try t.expect(focusNext(win, scope));
    try t.expectEqual(@as(u32, 2), win.focused.id);
    try t.expect(focusNext(win, scope));
    try t.expectEqual(@as(u32, 3), win.focused.id);
    try t.expect(focusNext(win, scope));
    try t.expectEqual(@as(u32, 2), win.focused.id);
    try t.expect(focusPrev(win, scope));
    try t.expectEqual(@as(u32, 3), win.focused.id);
    // Closing restores the pre-dialog focus.
    try t.expect(restore(win, scope));
    try t.expectEqual(@as(u32, 1), win.focused.id);
}

test "tab stops sort by index and emit deterministic traversal trace" {
    var stops = [_]TabStop{
        .{ .id = 30, .tab_index = 2, .insertion = 2 },
        .{ .id = 10, .tab_index = 0, .insertion = 1 },
        .{ .id = 20, .tab_index = -1, .insertion = 0 },
        .{ .id = 11, .tab_index = 0, .insertion = 3 },
    };
    var trace = TraversalTrace{};
    try std.testing.expectEqual(@as(?u32, 11), traverseTabStops(&stops, 10, false, &trace));
    try std.testing.expectEqual(@as(u32, 10), stops[0].id);
    try std.testing.expectEqual(@as(u32, 11), stops[1].id);
    try std.testing.expectEqual(@as(u32, 30), stops[2].id);
    try std.testing.expectEqual(@as(u32, 20), stops[3].id);
    try std.testing.expectEqual(TraversalEvent.begin, trace.events[0]);
    try std.testing.expectEqual(TraversalEvent.focused, trace.events[2]);
    try std.testing.expectEqual(TraversalEvent.end, trace.events[3]);
}
