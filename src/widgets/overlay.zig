//! Frame-local portals escape ancestor clipping and paint after ordinary siblings.
//! Retain State at a stable address; close before removing its owner. Portal
//! registrations borrow generation-checked focus handles, never raw callbacks.
const std = @import("std");
const e = @import("../elements/root.zig");
const g = @import("../core/geometry.zig");
const Window = @import("../app/window.zig").Window;
const focus = @import("focus.zig");
const platform = @import("../platform/root.zig");
pub const Placement = enum { bottom, top, left, right, center };
pub fn position(anchor: g.Rect, size: g.Size, viewport: g.Size, placement: Placement, gap: f32) g.Rect {
    const w = @min(@max(0, size.w), @max(0, viewport.w));
    const h = @min(@max(0, size.h), @max(0, viewport.h));
    var x = anchor.x;
    var y = anchor.y + anchor.h + gap;
    switch (placement) {
        .bottom => {
            if (y + h > viewport.h and anchor.y - gap - h >= 0) y = anchor.y - gap - h;
        },
        .top => {
            y = anchor.y - gap - h;
            if (y < 0) y = anchor.y + anchor.h + gap;
        },
        .left => {
            x = anchor.x - w - gap;
            y = anchor.y;
            if (x < 0) x = anchor.x + anchor.w + gap;
        },
        .right => {
            x = anchor.x + anchor.w + gap;
            y = anchor.y;
            if (x + w > viewport.w) x = anchor.x - w - gap;
        },
        .center => {
            x = (viewport.w - w) / 2;
            y = (viewport.h - h) / 2;
        },
    }
    return .{ .x = std.math.clamp(x, 0, @max(0, viewport.w - w)), .y = std.math.clamp(y, 0, @max(0, viewport.h - h)), .w = w, .h = h };
}
pub fn bounds(win: *Window, key: u64) g.Rect {
    for (win.ui_frame.nodes[0..win.ui_frame.node_count]) |node| if (node.stable_key == key) return node.bounds;
    return .{};
}
pub const State = struct {
    open: bool = false,
    modal: bool = false,
    dismiss_outside: bool = true,
    dismiss_escape: bool = true,
    capture_focus: bool = true,
    rect: g.Rect = .{},
    anchor_key: u64 = 0,
    anchor: g.Rect = .{},
    size: g.Size = .{ .w = 240, .h = 180 },
    placement: Placement = .bottom,
    token: ?focus.ScopeToken = null,
    ids: [512]u32 = undefined,
    id_count: usize = 0,
    restore: e.FocusHandle = .{},
    pub fn show(self: *State, win: *Window) void {
        if (self.open) return;
        self.open = true;
        self.restore = win.focused;
        win.requestRender();
    }
    pub fn close(self: *State, win: *Window) void {
        if (!self.open) return;
        self.open = false;
        win.cancelInteraction(.cancelled);
        if (self.token) |token| focus.popScope(win, token);
        self.token = null;
        win.requestRender();
    }
    pub fn portal(self: *State, win: *Window, handle: e.FocusHandle, panel: e.Element) void {
        if (!self.open) return;
        const frame = e.element.currentFrame();
        std.debug.assert(frame.portal_count < frame.portals.len);
        self.rect = position(if (self.anchor_key != 0) bounds(win, self.anchor_key) else self.anchor, self.size, win.bounds.size, self.placement, 4);
        const root = e.div().w(win.bounds.size.w).h(win.bounds.size.h).child(panel.absolute().left(self.rect.x).top(self.rect.y).w(self.rect.w).h(self.rect.h));
        frame.portals[frame.portal_count] = .{ .root = root, .state = self, .owner = handle };
        frame.portal_count += 1;
    }
};
pub const Portal = struct { root: e.Element, state: *State, owner: e.FocusHandle, region_start: usize = 0, region_end: usize = 0 };
/// Called after all portal regions exist. Modal gating includes non-focusable
/// descendants by region range; Tab ids include only actual focusable children.
pub fn sync(win: *Window) void {
    const frame = &win.ui_frame;
    for (frame.portals[0..frame.portal_count]) |portal| {
        if (!portal.owner.isLive()) continue;
        const state = portal.state;
        if (!state.open or !state.capture_focus) continue;
        state.id_count = 0;
        for (frame.regions[portal.region_start..portal.region_end]) |region| if (region.focus) |handle| {
            var duplicate = false;
            for (state.ids[0..state.id_count]) |id| {
                if (id == handle.id) duplicate = true;
            }
            if (!duplicate and state.id_count < state.ids.len) {
                state.ids[state.id_count] = handle.id;
                state.id_count += 1;
            }
        };
        if (state.token == null) {
            state.token = focus.pushScope(win, state.ids[0..state.id_count], state.modal);
            state.token.?.restore_to = state.restore;
            if (win.focus_scope) |*scope| scope.owner = portal.owner;
        } else if (win.focus_scope) |scope| {
            if (scope.ids.ptr == &state.ids) {
                win.focus_scope.?.ids = state.ids[0..state.id_count];
                win.focus_scope.?.owner = portal.owner;
            }
        }
    }
}
pub fn intercept(win: *Window, event: platform.Event) bool {
    var i = win.ui_frame.portal_count;
    while (i > 0) {
        i -= 1;
        const portal = win.ui_frame.portals[i];
        if (!portal.owner.isLive()) continue;
        const state = portal.state;
        if (!state.open or !state.capture_focus) continue;
        if (event == .key and event.key.pressed and event.key.key == .escape and state.dismiss_escape) {
            state.close(win);
            return true;
        }
        if (event == .mouse and !event.mouse.motion and event.mouse.pressed and !state.rect.contains(event.mouse.pos)) {
            if (state.dismiss_outside) state.close(win);
            return true; // Never click through a dismissed surface.
        }
        if (state.modal and event == .scroll and !state.rect.contains(event.scroll.pos)) return true;
        if (state.modal and event == .mouse and event.mouse.motion and !state.rect.contains(event.mouse.pos)) return true;
        break;
    }
    return false;
}
pub fn allowsRegion(win: *const Window, index: usize) bool {
    var i = win.ui_frame.portal_count;
    while (i > 0) {
        i -= 1;
        const p = win.ui_frame.portals[i];
        if (p.owner.isLive() and p.state.open and p.state.modal) return index >= p.region_start and index < p.region_end;
    }
    return true;
}
