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
    pub fn priority(self: *Deferred, value: usize) *Deferred {
        self.priority_value = value;
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
    _ = element.priority(3);
    try std.testing.expectEqual(@as(usize, 3), element.priority_value);
    try std.testing.expect(element.child == null);
}

const TestAppContext = @import("../app/test_context.zig").TestAppContext;
const div_mod = @import("div.zig");

/// A root view whose only child is a deferred element.
const DeferredTestView = struct {
    pub fn render(_: *DeferredTestView, _: *Window, _: *app_mod.Context(DeferredTestView)) *div_mod.Div {
        return div_mod.div().size_full().child(
            deferred(div_mod.div().id("deferred-child").w(geometry.px(50)).h(geometry.px(40))).priority(2),
        );
    }

    fn build(_: *Window, app: *app_mod.App) app_mod.Entity(DeferredTestView) {
        return app.new(DeferredTestView{});
    }
};

test "deferred: the child is laid out and drawn in its place" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(DeferredTestView.build);

    for (vcx.window.rendered_frame.hitboxes.items) |hitbox| {
        if (hitbox.bounds.size.width == 50 and hitbox.bounds.size.height == 40) {
            try std.testing.expectEqual(@as(Pixels, 0), hitbox.bounds.origin.x);
            try std.testing.expectEqual(@as(Pixels, 0), hitbox.bounds.origin.y);
            return;
        }
    }
    return error.TestExpectedEqual;
}
