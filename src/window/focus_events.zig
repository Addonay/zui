//! Port of GPUI's focus listeners (`window.rs`: `WindowFocusEvent`, `focus_listeners`,
//! `focus_lost_listeners`, `FocusOutEvent`). `Context.on_focus`, `on_blur`, `on_focus_in`,
//! `on_focus_out` and `on_focus_lost` register here.
//!
//! GPUI compares the focus path of the frame just drawn with the one before it, at the end of
//! `Window::draw`, and tells the listeners about the change. Do the same here: `Window.draw` calls
//! `focus_path` before it swaps frames, and `after_draw` after.

const std = @import("std");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const Frame = window_mod.Frame;
const FocusId = window_mod.FocusId;
pub const FocusHandle = window_mod.FocusHandle;

/// What changed in focus (GPUI `WindowFocusEvent`). Each path runs from the root to the focused
/// element, and is empty while the window is inactive.
pub const FocusEvent = struct {
    previous_focus_path: []const FocusId,
    current_focus_path: []const FocusId,

    /// Whether `focus_id` or one beneath it gained focus (GPUI `is_focus_in`).
    pub fn is_focus_in(self: FocusEvent, focus_id: FocusId) bool {
        return !contains(self.previous_focus_path, focus_id) and contains(self.current_focus_path, focus_id);
    }

    /// Whether `focus_id` or one beneath it lost focus (GPUI `is_focus_out`).
    pub fn is_focus_out(self: FocusEvent, focus_id: FocusId) bool {
        return contains(self.previous_focus_path, focus_id) and !contains(self.current_focus_path, focus_id);
    }
};

/// Given to `on_focus_out` listeners (GPUI `FocusOutEvent`): the element that lost focus.
/// ZUI focus handles are plain ids, so the handle never dangles and needs no upgrade.
pub const FocusOutEvent = struct {
    blurred: FocusHandle,
};

/// What the focus subscribers of a window are given. Valid only during the call.
pub const Payload = struct {
    event: *const FocusEvent,
    window: *Window,
};

fn contains(path: []const FocusId, id: FocusId) bool {
    for (path) |p| if (p == id) return true;
    return false;
}

/// The last element of a focus path, which is the focused element itself (GPUI `path.last()`).
pub fn last(path: []const FocusId) ?FocusId {
    if (path.len == 0) return null;
    return path[path.len - 1];
}

/// The focus path of `frame`: the focusable elements from the root down to the focused one, the
/// focused one last. Empty if nothing is focused. The caller frees it with `allocator`.
pub fn focus_path(frame: *const Frame, allocator: std.mem.Allocator) []FocusId {
    var out: std.ArrayList(FocusId) = .empty;
    const tree = &frame.dispatch_tree;
    var current = if (frame.focus) |focus| tree.focusable.get(focus) else null;
    while (current) |node_id| {
        const node = tree.nodes.items[node_id];
        if (node.focus_id) |id| out.append(allocator, id) catch @panic("out of memory");
        current = node.parent;
    }
    std.mem.reverse(FocusId, out.items);
    return out.toOwnedSlice(allocator) catch @panic("out of memory");
}

/// Compares the focus of the frame just drawn (`window.rendered_frame`) with `previous`, the
/// focus path of the frame it replaced, and runs the focus listeners of `window` if it changed.
/// Takes ownership of `previous`. Called by `Window.draw`.
pub fn after_draw(window: *Window, cx: *App, previous: []FocusId, previous_active: bool) void {
    const allocator = window.allocator;
    defer allocator.free(previous);
    const current = focus_path(&window.rendered_frame, allocator);
    defer allocator.free(current);
    const current_active = window.rendered_frame.window_active;
    if (std.mem.eql(FocusId, previous, current) and previous_active == current_active) return;

    const event: FocusEvent = .{
        .previous_focus_path = if (previous_active) previous else &.{},
        .current_focus_path = if (current_active) current else &.{},
    };
    const payload: Payload = .{ .event = &event, .window = window };
    // GPUI runs the lost listeners first, and it does so on the raw paths: an inactive window
    // still counts as losing its focus.
    if (previous.len > 0 and current.len == 0) {
        cx.dispatch_window_payload(.focus_lost, window, &payload);
    }
    cx.dispatch_window_payload(.focus, window, &payload);
}
