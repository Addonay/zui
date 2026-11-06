//! Tests of cached views (GPUI `Entity::cached`): what must render again, what must not, and that
//! what a reused view registered still works frames after it last rendered.

const std = @import("std");
const app_mod = @import("app.zig");
const window_mod = @import("window.zig");
const interactive = @import("interactive.zig");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const action_mod = @import("action.zig");
const keymap = @import("keymap.zig");
const div_mod = @import("elements/div.zig");
const deferred = @import("elements/deferred.zig").deferred;
const TestAppContext = @import("app/test_context.zig").TestAppContext;

const App = app_mod.App;
const Context = app_mod.Context;
const Entity = app_mod.Entity;
const Window = window_mod.Window;
const Div = div_mod.Div;
const div = div_mod.div;
const px = geometry.px;
const testing = std.testing;

fn box() *div_mod.StyleBuilder {
    return div_mod.style().w(px(100)).h(px(100));
}

const Leaf = struct {
    renders: usize = 0,
    clicks: usize = 0,
    keys: usize = 0,
    saves: usize = 0,
    label: []const u8 = "hello",
    animate: bool = false,
    focus: ?window_mod.FocusHandle = null,
    with_deferred: bool = false,
    keyed: ?app_mod.EntityId = null,

    const Save = action_mod.Action("cache_test", "Save");

    pub fn render(self: *Leaf, window: *Window, cx: *Context(Leaf)) *Div {
        self.renders += 1;
        if (self.animate) window.request_animation_frame();
        self.keyed = window.use_keyed_state("keyed", cx.app, Keyed{}).entity_id();
        var el = div().id("leaf").w(px(100)).h(px(100))
            .bg(color.red())
            .hover(div_mod.style().bg(color.blue()))
            .on_click(cx.listener(on_click))
            .child(window_mod.format("{s}", .{self.label}));
        if (self.focus) |*handle| {
            el = el.key_context("Leaf").track_focus(handle).on_action(Save, cx.listener(on_save)).on_key_down(cx.listener(on_key));
        }
        if (self.with_deferred) {
            el = el.child(deferred(div().id("popup").w(px(20)).h(px(20)).bg(color.green()).on_click(cx.listener(on_click))));
        }
        return el;
    }
    fn on_click(self: *Leaf, _: *const interactive.ClickEvent, _: *Window, _: *Context(Leaf)) void {
        self.clicks += 1;
    }
    fn on_save(self: *Leaf, _: *const Save, _: *Window, _: *Context(Leaf)) void {
        self.saves += 1;
    }
    fn on_key(self: *Leaf, _: *const interactive.KeyDownEvent, _: *Window, _: *Context(Leaf)) void {
        self.keys += 1;
    }
    fn touch(_: *Leaf, cx: *Context(Leaf)) void {
        cx.notify();
    }
};

const Keyed = struct {};

/// An uncached view inside a cached one.
const Middle = struct {
    renders: usize = 0,
    inner: Entity(Leaf),

    pub fn render(self: *Middle, _: *Window, _: *Context(Middle)) *Div {
        self.renders += 1;
        return div().w(px(100)).h(px(100)).child(self.inner);
    }
};

const Root = struct {
    a: Entity(Leaf),
    b: Entity(Leaf),
    middle: ?Entity(Middle) = null,
    width: geometry.Pixels = 100,
    renders: usize = 0,

    pub fn render(self: *Root, _: *Window, _: *Context(Root)) *Div {
        self.renders += 1;
        var el = div().flex().size_full()
            .child(self.a.cached(div_mod.style().w(px(self.width)).h(px(100))))
            .child(self.b.cached(box()));
        if (self.middle) |middle| el = el.child(middle.cached(box()));
        return el;
    }
    fn touch(_: *Root, cx: *Context(Root)) void {
        cx.notify();
    }
    fn resize_a(self: *Root, cx: *Context(Root)) void {
        self.width = 200;
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Root) {
        return app.new(Root{ .a = app.new(Leaf{}), .b = app.new(Leaf{}) });
    }
    fn build_nested(_: *Window, app: *App) Entity(Root) {
        return app.new(Root{
            .a = app.new(Leaf{}),
            .b = app.new(Leaf{}),
            .middle = app.new(Middle{ .inner = app.new(Leaf{}) }),
        });
    }
    fn build_focused(_: *Window, app: *App) Entity(Root) {
        return app.new(Root{ .a = app.new(Leaf{ .focus = app.focus_handle() }), .b = app.new(Leaf{}) });
    }
    fn build_deferred(_: *Window, app: *App) Entity(Root) {
        return app.new(Root{ .a = app.new(Leaf{ .with_deferred = true }), .b = app.new(Leaf{}) });
    }
    fn build_animated(_: *Window, app: *App) Entity(Root) {
        return app.new(Root{ .a = app.new(Leaf{ .animate = true }), .b = app.new(Leaf{}) });
    }
};

fn redraw_root(root: Entity(Root), cx: *TestAppContext, frames: usize) void {
    for (0..frames) |_| {
        root.update(cx.app, Root.touch, .{});
        cx.run_until_parked();
    }
}

test "a cached view renders once, until it notifies" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, _ = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    const b = root.read(cx.app).b;
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).renders);

    redraw_root(root, &cx, 3);
    try testing.expectEqual(@as(usize, 4), root.read(cx.app).renders);
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).renders);
    try testing.expectEqual(@as(usize, 1), b.read(cx.app).renders);

    a.update(cx.app, Leaf.touch, .{});
    cx.run_until_parked();
    try testing.expectEqual(@as(usize, 2), a.read(cx.app).renders);
    try testing.expectEqual(@as(usize, 1), b.read(cx.app).renders);
}

test "a reused view draws exactly what it drew" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    const scene = vcx.window.rendered_scene();
    const quads = scene.quads.items.len;
    const sprites = scene.monochrome_sprites.items.len;
    const hitboxes = vcx.window.rendered_frame.hitboxes.items.len;
    try testing.expect(quads >= 2);
    redraw_root(root, &cx, 3);
    const after = vcx.window.rendered_scene();
    try testing.expectEqual(quads, after.quads.items.len);
    try testing.expectEqual(sprites, after.monochrome_sprites.items.len);
    try testing.expectEqual(hitboxes, vcx.window.rendered_frame.hitboxes.items.len);
}

test "a reused view still takes clicks, frames after it rendered" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    const b = root.read(cx.app).b;
    // Enough frames for the frame arena it did not render into to be reused many times over.
    redraw_root(root, &cx, 8);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).clicks);
    try testing.expectEqual(@as(usize, 0), b.read(cx.app).clicks);
    vcx.simulate_click(.{ .x = 110, .y = 10 }, .{});
    try testing.expectEqual(@as(usize, 1), b.read(cx.app).clicks);
}

test "hovering restyles only the hovered view" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    const b = root.read(cx.app).b;
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    try testing.expect(a.read(cx.app).renders >= 2);
    try testing.expectEqual(@as(usize, 1), b.read(cx.app).renders);
    const hovered = vcx.window.rendered_scene().quads.items[0].background;
    const blue = color.to_background(color.blue());
    try testing.expect(std.meta.eql(hovered, blue));

    const renders = a.read(cx.app).renders;
    vcx.simulate_mouse_move(.{ .x = 500, .y = 500 }, null, .{});
    try testing.expect(a.read(cx.app).renders > renders);
    try testing.expectEqual(@as(usize, 1), b.read(cx.app).renders);
}

test "refresh renders everything" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    vcx.window.refresh();
    cx.run_until_parked();
    try testing.expectEqual(@as(usize, 2), a.read(cx.app).renders);
    // Then caching goes on as before.
    redraw_root(root, &cx, 2);
    try testing.expectEqual(@as(usize, 2), a.read(cx.app).renders);
}

test "a change of bounds renders again" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, _ = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    const b = root.read(cx.app).b;
    root.update(cx.app, Root.resize_a, .{});
    cx.run_until_parked();
    try testing.expectEqual(@as(usize, 2), a.read(cx.app).renders);
    // `b` moved along.
    try testing.expectEqual(@as(usize, 2), b.read(cx.app).renders);
}

test "notifying a view inside a cached view renders both" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, _ = cx.add_window_view(Root.build_nested);
    const middle = root.read(cx.app).middle.?;
    const inner = middle.read(cx.app).inner;
    const a = root.read(cx.app).a;
    redraw_root(root, &cx, 2);
    try testing.expectEqual(@as(usize, 1), middle.read(cx.app).renders);
    try testing.expectEqual(@as(usize, 1), inner.read(cx.app).renders);

    inner.update(cx.app, Leaf.touch, .{});
    cx.run_until_parked();
    try testing.expectEqual(@as(usize, 2), middle.read(cx.app).renders);
    try testing.expectEqual(@as(usize, 2), inner.read(cx.app).renders);
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).renders);
}

test "a reused view keeps focus, key listeners and actions" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{keymap.KeyBinding.new("cmd-s", Leaf.Save{}, "Leaf")});
    const root, const vcx = cx.add_window_view(Root.build_focused);
    const a = root.read(cx.app).a;
    vcx.focus(a.read(cx.app).focus.?);
    cx.run_until_parked();
    const renders = a.read(cx.app).renders;
    redraw_root(root, &cx, 4);
    try testing.expectEqual(renders, a.read(cx.app).renders);
    try testing.expect(a.read(cx.app).focus.?.is_focused(vcx.window));
    try testing.expect(a.read(cx.app).focus.?.contains_focused(vcx.window, cx.app));

    vcx.simulate_keystrokes("x");
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).keys);
    vcx.simulate_keystrokes("cmd-s");
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).saves);
}

test "a reused view keeps its deferred draws" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build_deferred);
    const a = root.read(cx.app).a;
    const quads = vcx.window.rendered_scene().quads.items.len;
    try testing.expectEqual(@as(usize, 1), vcx.window.rendered_frame.deferred_draws.items.len);
    redraw_root(root, &cx, 6);
    try testing.expectEqual(@as(usize, 1), a.read(cx.app).renders);
    try testing.expectEqual(quads, vcx.window.rendered_scene().quads.items.len);
    try testing.expectEqual(@as(usize, 1), vcx.window.rendered_frame.deferred_draws.items.len);
    // The popup is at the start of `a`, over it, and its listener outlived many frames.
    vcx.simulate_click(.{ .x = 5, .y = 5 }, .{});
    try testing.expect(a.read(cx.app).clicks >= 1);
}

test "a reused view's element states survive" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    const keyed = a.read(cx.app).keyed;
    const states = vcx.window.element_states.count();
    redraw_root(root, &cx, 6);
    try testing.expectEqual(states, vcx.window.element_states.count());
    // Rendering again finds the same state.
    a.update(cx.app, Leaf.touch, .{});
    cx.run_until_parked();
    try testing.expectEqual(keyed, a.read(cx.app).keyed);
}

test "a reused view's text layouts stay cached" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    redraw_root(root, &cx, 4);
    try testing.expect(vcx.window.line_layout_cache.?.lines.previous.count() > 0);
}

test "windows keep their layouts apart" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root_one, const one = cx.add_window_view(Root.build);
    const root_two, const two = cx.add_window_view(Root.build);
    const layouts = one.window.line_layout_cache.?.lines.previous.count();
    try testing.expect(layouts > 0);
    // The other window drawing does not age this window's layouts.
    redraw_root(root_two, &cx, 4);
    try testing.expectEqual(layouts, one.window.line_layout_cache.?.lines.previous.count());
    redraw_root(root_one, &cx, 4);
    try testing.expectEqual(layouts, one.window.line_layout_cache.?.lines.previous.count());
    try testing.expect(two.window.line_layout_cache.?.lines.previous.count() > 0);
}

test "an animating view inside a cached view keeps rendering" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const handle = cx.add_window(Root.build_animated);
    const window = handle.window(cx.app).?;
    const root: Entity(Root) = .{ .entity_id_ = handle.entity_id_ };
    const a = root.read(cx.app).a;
    const b = root.read(cx.app).b;
    const renders = a.read(cx.app).renders;
    window.draw(cx.app);
    window.draw(cx.app);
    try testing.expect(a.read(cx.app).renders >= renders + 2);
    try testing.expectEqual(@as(usize, 1), b.read(cx.app).renders);
    // Stop it, or the test context never settles.
    a.as_mut(cx.app).animate = false;
    window.draw(cx.app);
}

test "a released entity is no longer replayed" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const root, const vcx = cx.add_window_view(Root.build);
    const a = root.read(cx.app).a;
    const quads = vcx.window.rendered_scene().quads.items.len;
    cx.app.release_entity(a.entity_id());
    redraw_root(root, &cx, 1);
    try testing.expect(vcx.window.rendered_scene().quads.items.len < quads);
}
