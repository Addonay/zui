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

    pub fn contains(self: Scope, id: u32) bool {
        for (self.ids) |candidate| if (candidate == id) return true;
        return false;
    }
};

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
        win.focused = handle;
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
    if (!focusNext(win, win.focus_scope)) win.focused = .{};
    return token;
}
pub fn popScope(win: *Window, token: ScopeToken) void {
    win.focus_scope = token.previous;
    if (!focusId(win, token.restore_to.id)) {
        win.focused = .{};
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
