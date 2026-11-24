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
    /// GPUI name for `priority`.
    pub const with_priority = priority;

    pub fn request_layout(self: *Deferred, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        const child = self.child orelse unreachable;
        return .{ child.request_layout(window, cx), {} };
    }

    pub fn prepaint(self: *Deferred, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *void, window: *Window, _: *App) void {
        const child = self.child orelse unreachable;
        self.child = null;
        window.defer_draw(child, window.element_offset(), self.priority_value, null);
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
    _ = element.with_priority(5);
    try std.testing.expectEqual(@as(usize, 5), element.priority_value);
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

const DeferredActionView = struct {
    const Save = @import("../action.zig").Action("test", "DeferredSave");

    parent_focus: window_mod.FocusHandle,
    child_focus: window_mod.FocusHandle,
    saves: usize = 0,
    field_saves: usize = 0,
    renders: usize = 0,

    pub fn render(self: *DeferredActionView, _: *Window, cx: *app_mod.Context(DeferredActionView)) *div_mod.Div {
        self.renders += 1;
        const field = window_mod.frame_arena().create(PaintActionField) catch @panic("out of memory");
        field.* = .{
            .view = self,
            .child = element_mod.into_any_element(div_mod.div().id("field").size(40).track_focus(&self.child_focus)),
        };
        return div_mod.div().size_full().id("panel").track_focus(&self.parent_focus)
            .key_context("Panel").on_action(Save, cx.listener(save))
            .child(deferred(deferred(field)));
    }

    fn save(self: *DeferredActionView, _: *const Save, _: *Window, _: *app_mod.Context(DeferredActionView)) void {
        self.saves += 1;
    }
};

const PaintActionField = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    view: *DeferredActionView,
    child: AnyElement,

    pub fn request_layout(self: *PaintActionField, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        return .{ self.child.request_layout(window, cx), {} };
    }

    pub fn prepaint(self: *PaintActionField, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }

    pub fn paint(self: *PaintActionField, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *void, _: *void, window: *Window, cx: *App) void {
        window.on_action(app_mod.type_id(DeferredActionView.Save), self.view, on_save);
        self.child.paint(window, cx);
    }

    fn on_save(ctx: *anyopaque, _: *const anyopaque, phase: window_mod.DispatchPhase, _: *Window, cx: *App) void {
        if (phase != .bubble) return;
        const view: *DeferredActionView = @ptrCast(@alignCast(ctx));
        view.field_saves += 1;
        cx.propagate();
    }
};

const CachedDeferredRoot = struct {
    panel: app_mod.Entity(DeferredActionView),

    pub fn render(self: *CachedDeferredRoot, _: *Window, _: *app_mod.Context(CachedDeferredRoot)) *div_mod.Div {
        return div_mod.div().size_full().child(self.panel.cached(div_mod.style().size_full()));
    }

    fn build(_: *Window, app: *App) app_mod.Entity(CachedDeferredRoot) {
        const panel = app.new(DeferredActionView{
            .parent_focus = app.focus_handle(),
            .child_focus = app.focus_handle(),
        });
        return app.new(CachedDeferredRoot{ .panel = panel });
    }
};

test "deferred: nested draws keep their focus and key ancestors after cache replay" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const KeyBinding = @import("../keymap.zig").KeyBinding;
    cx.app.bind_keys(&.{KeyBinding.new("cmd-s", DeferredActionView.Save{}, "Panel")});

    const root, const vcx = cx.add_window_view(CachedDeferredRoot.build);
    const panel = root.read(cx.app).panel;
    const child_focus = panel.read(cx.app).child_focus;
    child_focus.focus(vcx.window);
    vcx.run_until_parked();

    try std.testing.expect(panel.read(cx.app).parent_focus.contains_focused(vcx.window, cx.app));
    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 1), panel.read(cx.app).saves);
    try std.testing.expectEqual(@as(usize, 1), panel.read(cx.app).field_saves);

    const renders = panel.read(cx.app).renders;
    vcx.window.draw(cx.app);
    try std.testing.expectEqual(renders, panel.read(cx.app).renders);
    try std.testing.expect(panel.read(cx.app).parent_focus.contains_focused(vcx.window, cx.app));
    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 2), panel.read(cx.app).saves);
    try std.testing.expectEqual(@as(usize, 2), panel.read(cx.app).field_saves);
}

test "deferred: content mask clips hitboxes during prepaint" {
    const canvas_mod = @import("canvas.zig");
    const MaskedOverlayView = struct {
        clicks: usize = 0,

        fn on_bg_click(self: *@This(), _: *const @import("../interactive.zig").MouseDownEvent, _: *Window, _: *app_mod.Context(@This())) void {
            self.clicks += 1;
        }

        fn prepaint_overlay(_: void, b: Bounds(Pixels), window: *Window, cx: *App) void {
            const overlay = element_mod.into_any_element(div_mod.div().size(200).occlude());
            _ = overlay.layout_as_root(.{ .width = .min_content, .height = .min_content }, window, cx);
            const mask: window_mod.ContentMask(Pixels) = .{
                .bounds = .{ .origin = b.origin, .size = .{ .width = 100, .height = 200 } },
            };
            window.defer_draw(overlay, b.origin, 1, mask);
        }

        fn paint_overlay(_: void, _: Bounds(Pixels), _: *void, _: *Window, _: *App) void {}

        pub fn render(_: *@This(), _: *Window, cx: *app_mod.Context(@This())) *div_mod.Div {
            return div_mod.div()
                .size_full()
                .child(
                    div_mod.div()
                        .absolute()
                        .size(200)
                        .on_mouse_down(.left, cx.listener(on_bg_click)),
                )
                .child(canvas_mod.canvas({}, prepaint_overlay, paint_overlay).size_full());
        }

        fn build(_: *Window, app: *App) app_mod.Entity(@This()) {
            return app.new(@This(){});
        }
    };

    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(MaskedOverlayView.build);
    vcx.run_until_parked();

    vcx.simulate_click(.{ .x = 50, .y = 50 }, .{});
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).clicks);

    vcx.simulate_click(.{ .x = 150, .y = 50 }, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).clicks);
}
