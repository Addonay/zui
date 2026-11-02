//! Port of GPUI `elements/deferred.rs`: delays the layout-independent paint of a
//! child until after its ancestors, keeping the child in the current layout tree.

const std = @import("std");
const geometry = @import("../geometry.zig");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const taffy = @import("../taffy.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const LayoutId = taffy.LayoutId;
const AnyElement = element_mod.AnyElement;
const GlobalElementId = element_mod.GlobalElementId;

/// An element that delays painting its child until after all of its ancestors (GPUI `Deferred`).
pub const Deferred = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    child: ?AnyElement = null,
    priority_value: usize = 0,

    /// Sets the drawing order relative to other deferred elements; higher values draw on top.
    pub fn with_priority(self: *Deferred, priority: usize) *Deferred {
        self.priority_value = priority;
        return self;
    }

    pub fn request_layout(self: *Deferred, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        const child = self.child orelse unreachable;
        return .{ child.request_layout(window, cx), {} };
    }

    pub fn prepaint(self: *Deferred, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *void, window: *Window, _: *App) void {
        const child = self.child orelse unreachable;
        self.child = null;
        window.defer_draw(child, window.element_offset(), self.priority_value);
    }

    pub fn paint(_: *Deferred, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *void, _: *void, _: *Window, _: *App) void {}
};

/// GPUI `deferred(child)`: builds a `Deferred` element around `child`.
pub fn deferred(child: anytype) *Deferred {
    const element = window_mod.frame_arena().create(Deferred) catch @panic("out of memory");
    element.* = .{ .child = element_mod.into_any_element(child) };
    return element;
}

test "deferred stores its child and priority" {
    var element: Deferred = .{};
    _ = element.with_priority(3);
    try std.testing.expectEqual(@as(usize, 3), element.priority_value);
    try std.testing.expect(element.child == null);
}
