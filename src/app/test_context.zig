//! Port of GPUI `app/test_context.rs`: `TestAppContext` and `VisualTestContext`.
//!
//! Both run on the headless platform. Frames and foreground work are pumped by
//! `run_until_parked`, and input is injected through `Window.dispatch_event`,
//! so tests exercise the same dispatch paths as a real platform.

const std = @import("std");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");
const interactive = @import("../interactive.zig");
const keystroke_mod = @import("../keystroke.zig");
const action_mod = @import("../action.zig");
const platform_mod = @import("../platform.zig");
const geometry = @import("../geometry.zig");
const headless = @import("../platform/headless.zig");

const App = app_mod.App;
const Entity = app_mod.Entity;
const Window = window_mod.Window;
const WindowHandle = window_mod.WindowHandle;
const WindowOptions = window_mod.WindowOptions;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Keystroke = keystroke_mod.Keystroke;
const Modifiers = keystroke_mod.Modifiers;
const MouseButton = interactive.MouseButton;
const PlatformInput = interactive.PlatformInput;

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// A test application: a headless `App` plus helpers to pump it (GPUI `TestAppContext`).
pub const TestAppContext = struct {
    allocator: std.mem.Allocator,
    platform: *platform_mod.Platform,
    app: *App,
    visual_contexts: std.ArrayList(*VisualTestContext) = .empty,

    /// Creates a headless app backed by `std.testing.allocator`.
    pub fn init() TestAppContext {
        return with_allocator(std.testing.allocator);
    }

    pub fn with_allocator(allocator: std.mem.Allocator) TestAppContext {
        const platform = headless.HeadlessPlatform.create(allocator);
        const app = App.init(allocator, platform) catch @panic("failed to create test app");
        return .{ .allocator = allocator, .platform = platform, .app = app };
    }

    pub fn deinit(self: *TestAppContext) void {
        for (self.visual_contexts.items) |v| self.allocator.destroy(v);
        self.visual_contexts.deinit(self.allocator);
        self.app.deinit();
        self.platform.deinit();
    }

    /// Runs `f(args..., *App)` (GPUI `update`).
    pub fn update(self: *TestAppContext, comptime f: anytype, args: anytype) ReturnOf(f) {
        return self.app.update(f, args);
    }

    /// Runs `f(*const App, args...)`-style reads: `f(args..., *const App)` (GPUI `read`).
    pub fn read(self: *TestAppContext, comptime f: anytype, args: anytype) ReturnOf(f) {
        return @call(.auto, f, args ++ .{@as(*const App, self.app)});
    }

    /// Creates an entity (GPUI `cx.new`).
    pub fn new(self: *TestAppContext, initializer: anytype) Entity(app_mod.EntityTypeOf(@TypeOf(initializer))) {
        return self.app.new(initializer);
    }

    /// Runs `f(*const T, args..., *const App)` on an entity's state (GPUI `read_entity`).
    pub fn read_entity(self: *TestAppContext, handle: anytype, comptime f: anytype, args: anytype) ReturnOf(f) {
        const state = handle.read(self.app);
        return @call(.auto, f, .{state} ++ args ++ .{@as(*const App, self.app)});
    }

    /// Runs `f(*T, args..., *Context(T))` on an entity (GPUI `update_entity`).
    pub fn update_entity(self: *TestAppContext, handle: anytype, comptime f: anytype, args: anytype) ReturnOf(f) {
        return handle.update(self.app, f, args);
    }

    /// Opens a window whose root view is built by `build_root(window, app)` (GPUI `add_window`).
    /// The first frame is drawn before returning, so input can be dispatched immediately.
    pub fn add_window(self: *TestAppContext, comptime build_root: anytype) WindowHandle(window_mod.RootViewType(build_root)) {
        return self.add_window_with_options(.{}, build_root);
    }

    pub fn add_window_with_options(self: *TestAppContext, options: WindowOptions, comptime build_root: anytype) WindowHandle(window_mod.RootViewType(build_root)) {
        const handle = self.app.open_window(options, build_root) catch @panic("failed to open test window");
        self.run_until_parked();
        return handle;
    }

    /// Opens a window and returns its root view together with a `VisualTestContext` for it
    /// (GPUI `add_window_view`). The visual context is owned by this `TestAppContext`, so
    /// this `TestAppContext` must not be moved after the call.
    pub fn add_window_view(self: *TestAppContext, comptime build_root: anytype) struct { Entity(window_mod.RootViewType(build_root)), *VisualTestContext } {
        const handle = self.add_window(build_root);
        const visual = self.allocator.create(VisualTestContext) catch @panic("OOM");
        visual.* = .{ .window = handle.window(self.app) orelse unreachable, .cx = self };
        self.visual_contexts.append(self.allocator, visual) catch @panic("OOM");
        return .{ .{ .entity_id_ = handle.entity_id_ }, visual };
    }

    /// Pumps foreground work and frames until nothing is left to do (GPUI `run_until_parked`).
    pub fn run_until_parked(self: *TestAppContext) void {
        headless.HeadlessPlatform.from(self.platform).run_until_idle(self.app);
    }

    pub fn executor(self: *TestAppContext) *@import("../executor.zig").BackgroundExecutor {
        return self.app.background_executor();
    }

    pub fn foreground_executor(self: *TestAppContext) *@import("../executor.zig").ForegroundExecutor {
        return self.app.foreground_executor();
    }

    pub fn background_executor(self: *TestAppContext) *@import("../executor.zig").BackgroundExecutor {
        return self.app.background_executor();
    }

    /// Dispatches `action` along the focus path of `window` (GPUI `dispatch_action`).
    pub fn dispatch_action(self: *TestAppContext, window: *Window, action: anytype) void {
        window.dispatch_action(action_mod.box_action(self.app.effect_arena.allocator(), action), self.app);
        self.run_until_parked();
    }

    /// Types a space-separated keystroke sequence such as `"cmd-s a b"` (GPUI `simulate_keystrokes`).
    pub fn simulate_keystrokes(self: *TestAppContext, window: *Window, keystrokes: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, keystrokes, ' ');
        while (it.next()) |source| {
            const ks = Keystroke.parse(source) catch |err| std.debug.panic("invalid keystroke '{s}': {s}", .{ source, @errorName(err) });
            self.dispatch_keystroke(window, ks);
        }
        self.run_until_parked();
    }

    /// Types text, one character per keystroke (GPUI `simulate_input`).
    pub fn simulate_input(self: *TestAppContext, window: *Window, input: []const u8) void {
        var i: usize = 0;
        while (i < input.len) {
            const len = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
            const end = @min(i + len, input.len);
            const text = input[i..end];
            self.dispatch_keystroke(window, .{ .key = text, .key_char = text });
            i = end;
        }
        self.run_until_parked();
    }

    /// Sends a key-down followed by a key-up. Printable keys without command or control
    /// modifiers also deliver their text, as the platform would.
    pub fn dispatch_keystroke(self: *TestAppContext, window: *Window, keystroke: Keystroke) void {
        var ks = keystroke;
        if (ks.key_char == null and !ks.modifiers.control and !ks.modifiers.platform and ks.key.len == 1) ks.key_char = ks.key;
        _ = window.dispatch_event(.{ .key_down = .{ .keystroke = ks } }, self.app);
        _ = window.dispatch_event(.{ .key_up = .{ .keystroke = ks } }, self.app);
    }

    pub fn write_to_clipboard(self: *TestAppContext, item: platform_mod.ClipboardItem) void {
        self.app.write_to_clipboard(item);
    }

    pub fn read_from_clipboard(self: *TestAppContext) ?platform_mod.ClipboardItem {
        return self.app.read_from_clipboard();
    }
};

/// A window-scoped test context that simulates platform input (GPUI `VisualTestContext`).
pub const VisualTestContext = struct {
    window: *Window,
    cx: *TestAppContext,

    pub fn simulate_event(self: *VisualTestContext, event: PlatformInput) void {
        _ = self.window.dispatch_event(event, self.cx.app);
        self.cx.run_until_parked();
    }

    pub fn simulate_mouse_move(self: *VisualTestContext, position: Point(Pixels), button: ?MouseButton, modifiers: Modifiers) void {
        self.simulate_event(.{ .mouse_move = .{ .position = position, .modifiers = modifiers, .pressed_button = button } });
    }

    pub fn simulate_mouse_down(self: *VisualTestContext, position: Point(Pixels), button: MouseButton, modifiers: Modifiers) void {
        self.simulate_event(.{ .mouse_down = .{ .position = position, .button = button, .modifiers = modifiers, .click_count = 1 } });
    }

    pub fn simulate_mouse_up(self: *VisualTestContext, position: Point(Pixels), button: MouseButton, modifiers: Modifiers) void {
        self.simulate_event(.{ .mouse_up = .{ .position = position, .button = button, .modifiers = modifiers, .click_count = 1 } });
    }

    /// A left click: mouse down then mouse up at `position`.
    pub fn simulate_click(self: *VisualTestContext, position: Point(Pixels), modifiers: Modifiers) void {
        self.simulate_mouse_down(position, .left, modifiers);
        self.simulate_mouse_up(position, .left, modifiers);
    }

    pub fn simulate_scroll(self: *VisualTestContext, position: Point(Pixels), delta: Point(Pixels)) void {
        self.simulate_event(.{ .scroll_wheel = .{ .position = position, .delta = .{ .pixels = delta }, .modifiers = .{} } });
    }

    pub fn simulate_keystrokes(self: *VisualTestContext, keystrokes: []const u8) void {
        self.cx.simulate_keystrokes(self.window, keystrokes);
    }

    pub fn simulate_input(self: *VisualTestContext, input: []const u8) void {
        self.cx.simulate_input(self.window, input);
    }

    /// Resizes the window and redraws (GPUI `simulate_resize`).
    pub fn simulate_resize(self: *VisualTestContext, s: Size(Pixels)) void {
        self.window.platform_window.resize(s);
        self.cx.run_until_parked();
    }

    pub fn dispatch_action(self: *VisualTestContext, action: anytype) void {
        self.cx.dispatch_action(self.window, action);
    }

    pub fn focus(self: *VisualTestContext, handle: window_mod.FocusHandle) void {
        self.window.focus(handle);
        self.cx.run_until_parked();
    }

    /// Runs `f(window, app)` against the window (GPUI `update`).
    pub fn update(self: *VisualTestContext, comptime f: anytype, args: anytype) ReturnOf(f) {
        const r = @call(.auto, f, args ++ .{ self.window, self.cx.app });
        self.cx.app.flush_effects();
        return r;
    }

    pub fn run_until_parked(self: *VisualTestContext) void {
        self.cx.run_until_parked();
    }
};

test "TestAppContext: new, update and read entities" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Tally = struct {
        n: usize = 0,
        fn inc(self: *@This(), by: usize, _: *app_mod.Context(@This())) void {
            self.n += by;
        }
        fn read_n(self: *const @This(), _: *const App) usize {
            return self.n;
        }
    };
    const counter = cx.new(Tally{});
    cx.update_entity(counter, Tally.inc, .{@as(usize, 2)});
    cx.update_entity(counter, Tally.inc, .{@as(usize, 3)});
    try std.testing.expectEqual(@as(usize, 5), cx.read_entity(counter, Tally.read_n, .{}));
}

// ---------------------------------------------------------------------------
// Integration tests: ports of GPUI's app.rs / window.rs / interactive.rs / div.rs tests.

const div_mod = @import("../elements/div.zig");
const Div = div_mod.Div;
const Context = app_mod.Context;
const Subscription = app_mod.Subscription;
const ClickEvent = interactive.ClickEvent;
const KeyDownEvent = interactive.KeyDownEvent;
const FocusHandle = window_mod.FocusHandle;
const div = div_mod.div;
const px = geometry.px;
const rgb = @import("../color.zig").rgb;
const red = @import("../color.zig").red;
const keymap_mod = @import("../keymap.zig");
const KeyBinding = keymap_mod.KeyBinding;
const Action = action_mod.Action;

const Model = struct {
    pub const Event = union(enum) { changed: usize };
    value: usize = 0,
    releases: usize = 0,

    fn bump(self: *Model, cx: *Context(Model)) void {
        self.value += 1;
        cx.emit(.{ .changed = self.value });
        cx.notify();
    }
};

const Observer = struct {
    seen: usize = 0,
    events: usize = 0,
    last_value: usize = 0,
    released: bool = false,
    subs: [2]?Subscription = .{ null, null },

    fn watch(self: *Observer, target: Entity(Model), cx: *Context(Observer)) void {
        self.subs[0] = cx.observe(target, on_change);
        self.subs[1] = cx.subscribe(target, on_event);
    }
    fn on_change(self: *Observer, _: Entity(Model), _: *Context(Observer)) void {
        self.seen += 1;
    }
    fn on_event(self: *Observer, _: Entity(Model), ev: *const Model.Event, _: *Context(Observer)) void {
        self.events += 1;
        self.last_value = ev.changed;
    }
    fn on_released(self: *Observer, _: *Context(Observer)) void {
        self.released = true;
    }
};

test "entities: observe, subscribe, emit and release" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const model = cx.new(Model{});
    const observer = cx.new(Observer{});
    cx.update_entity(observer, Observer.watch, .{model});

    cx.update_entity(model, Model.bump, .{});
    cx.update_entity(model, Model.bump, .{});
    cx.run_until_parked();

    const state = observer.read(cx.app);
    try std.testing.expectEqual(@as(usize, 2), state.seen);
    try std.testing.expectEqual(@as(usize, 2), state.events);
    try std.testing.expectEqual(@as(usize, 2), state.last_value);

    const weak = model.downgrade();
    model.release(cx.app);
    try std.testing.expect(weak.upgrade(cx.app) == null);
}

test "entities: release listeners run before the state is dropped" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Released = struct {
        var count: usize = 0;
        fn on_release(_: *App, _: app_mod.EntityId, _: usize, payload: ?*const anyopaque) bool {
            const state: *const Model = @ptrCast(@alignCast(payload.?));
            if (state.value == 7) count += 1;
            return false;
        }
    };
    Released.count = 0;
    const model = cx.new(Model{ .value = 7 });
    var sub = cx.app.add_release_listener(model.entity_id(), Released.on_release);
    defer sub.unsubscribe();
    model.release(cx.app);
    try std.testing.expectEqual(@as(usize, 1), Released.count);
    try std.testing.expect(model.downgrade().upgrade(cx.app) == null);
}

test "entities: notify from outside the app observes via App.observe" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const model = cx.new(Model{});
    const Tally = struct {
        var count: usize = 0;
        fn on(_: Entity(Model), _: *App) void {
            count += 1;
        }
    };
    Tally.count = 0;
    var sub = cx.app.observe(model, Tally.on);
    defer sub.unsubscribe();
    cx.update_entity(model, Model.bump, .{});
    cx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), Tally.count);
    sub.unsubscribe();
    cx.update_entity(model, Model.bump, .{});
    try std.testing.expectEqual(@as(usize, 1), Tally.count);
}

const Theme = struct { dark: bool = false };

test "globals: set, update and observe" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    try std.testing.expect(!cx.app.has_global(Theme));
    cx.app.set_global(Theme{ .dark = false });
    cx.app.update_global(Theme, struct {
        fn f(t: *Theme, _: *App) void {
            t.dark = true;
        }
    }.f);
    try std.testing.expect(cx.app.global(Theme).dark);

    const Seen = struct {
        var changes: usize = 0;
        fn on(_: *App) void {
            changes += 1;
        }
    };
    Seen.changes = 0;
    var sub = cx.app.observe_global(Theme, Seen.on);
    defer sub.unsubscribe();
    cx.app.set_global(Theme{ .dark = false });
    try std.testing.expectEqual(@as(usize, 1), Seen.changes);
    try std.testing.expect(!cx.app.global(Theme).dark);
    cx.app.remove_global(Theme);
    try std.testing.expect(!cx.app.has_global(Theme));
}

/// A view with a clickable button (`.id("btn").on_click(cx.listener(...))`).
const Counter = struct {
    count: usize = 0,

    pub fn render(self: *Counter, _: *Window, cx: *Context(Counter)) *Div {
        _ = self;
        return div().id("btn").w(px(100)).h(px(100)).on_click(cx.listener(on_click));
    }
    fn on_click(self: *Counter, _: *const ClickEvent, _: *Window, cx: *Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Counter) {
        return app.new(Counter{});
    }
    fn read_count(s: *const Counter, _: *const App) usize {
        return s.count;
    }
};

test "windows: draw a view and deliver a click to on_click" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Counter.build);
    try std.testing.expect(vcx.window.frame_count > 0);
    try std.testing.expect(vcx.window.rendered_frame.hitboxes.items.len > 0);

    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Counter.read_count, .{}));

    // Clicks outside the button are ignored.
    vcx.simulate_click(.{ .x = 500, .y = 500 }, .{});
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Counter.read_count, .{}));
}

test "windows: a click is only delivered when mouse down and up both hit" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Counter.build);
    vcx.simulate_mouse_down(.{ .x = 10, .y = 10 }, .left, .{});
    vcx.simulate_mouse_up(.{ .x = 500, .y = 500 }, .left, .{});
    try std.testing.expectEqual(@as(usize, 0), cx.read_entity(view, Counter.read_count, .{}));
}

/// Tracks hover with `on_hover` and restyles on hover with `.hover(...)`.
const Hover = struct {
    hovered: bool = false,
    hover_changes: usize = 0,

    pub fn render(_: *Hover, _: *Window, cx: *Context(Hover)) *Div {
        return div().id("hover").w(px(100)).h(px(100)).bg(rgb(0x00ff00))
            .hover(div_mod.style().bg(red()))
            .on_hover(cx.listener(on_hover));
    }
    fn on_hover(self: *Hover, hovered: *const bool, _: *Window, cx: *Context(Hover)) void {
        self.hovered = hovered.*;
        self.hover_changes += 1;
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Hover) {
        return app.new(Hover{});
    }
};

fn scene_has_quad_color(window: *const Window, color: @import("../color.zig").Hsla) bool {
    for (window.rendered_frame.scene.quads.items) |q| {
        if (std.meta.eql(q.background.solid, color)) return true;
    }
    return false;
}

test "hover: on_hover fires and the hover style is repainted" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Hover.build);
    try std.testing.expect(scene_has_quad_color(vcx.window, rgb(0x00ff00).to_hsla()));

    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    try std.testing.expect(view.read(cx.app).hovered);
    try std.testing.expect(scene_has_quad_color(vcx.window, red()));
    try std.testing.expect(!scene_has_quad_color(vcx.window, rgb(0x00ff00).to_hsla()));

    vcx.simulate_mouse_move(.{ .x = 500, .y = 500 }, null, .{});
    try std.testing.expect(!view.read(cx.app).hovered);
    try std.testing.expect(scene_has_quad_color(vcx.window, rgb(0x00ff00).to_hsla()));
    try std.testing.expectEqual(@as(usize, 2), view.read(cx.app).hover_changes);
}

/// A focusable field with a key context, actions and key listeners.
const Editor = struct {
    focus: FocusHandle,
    saves: usize = 0,
    keys: usize = 0,
    last_key: [8]u8 = @splat(0),
    last_key_len: usize = 0,
    clicks: usize = 0,

    const Save = Action("test", "Save");
    const Outside = Action("test", "Outside");

    pub fn render(self: *Editor, _: *Window, cx: *Context(Editor)) *Div {
        return div().id("editor").w(px(100)).h(px(100))
            .key_context("Editor")
            .track_focus(&self.focus)
            .on_action(Save, cx.listener(on_save))
            .on_key_down(cx.listener(on_key_down));
    }
    fn on_save(self: *Editor, _: *const Save, _: *Window, cx: *Context(Editor)) void {
        self.saves += 1;
        cx.notify();
    }
    fn on_key_down(self: *Editor, ev: *const KeyDownEvent, _: *Window, _: *Context(Editor)) void {
        self.keys += 1;
        const key = ev.keystroke.key;
        const n = @min(key.len, self.last_key.len);
        @memcpy(self.last_key[0..n], key[0..n]);
        self.last_key_len = n;
    }
    fn build(_: *Window, app: *App) Entity(Editor) {
        return app.new(Editor{ .focus = app.focus_handle() });
    }
    fn read_state(s: *const Editor, _: *const App) struct { saves: usize, keys: usize } {
        return .{ .saves = s.saves, .keys = s.keys };
    }
};

test "focus: track_focus is focused by a click" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Editor.build);
    try std.testing.expect(vcx.window.focused(cx.app) == null);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    const handle = view.read(cx.app).focus;
    try std.testing.expect(handle.is_focused(vcx.window));
}

test "actions: key binding dispatches to on_action on the focused element" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("cmd-s", Editor.Save{}, "Editor")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("cmd-s");
    const state = cx.read_entity(view, Editor.read_state, .{});
    try std.testing.expectEqual(@as(usize, 1), state.saves);
}

test "actions: dispatch_action reaches on_action on the focus path" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.dispatch_action(Editor.Save{});
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);
}

test "keystrokes: simulate_keystrokes delivers key down events with their text" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.simulate_keystrokes("a b");
    const state = cx.read_entity(view, Editor.read_state, .{});
    try std.testing.expectEqual(@as(usize, 2), state.keys);
    try std.testing.expectEqualStrings("b", cx.read_entity(view, struct {
        fn f(s: *const Editor, _: *const App) []const u8 {
            return s.last_key[0..s.last_key_len];
        }
    }.f, .{}));
}

/// A view whose child overflows a fixed-height scroll container.
const Scroller = struct {
    scroll: div_mod.ScrollHandle,

    pub fn render(self: *Scroller, _: *Window, _: *Context(Scroller)) *Div {
        const d = div().id("scroller").w(px(100)).h(px(100)).overflow_hidden().track_scroll(&self.scroll);
        d.style().overflow = .{ .x = .hidden, .y = .scroll };
        return d.child(div().w(px(100)).h(px(500)));
    }
    fn build(_: *Window, app: *App) Entity(Scroller) {
        return app.new(Scroller{ .scroll = div_mod.ScrollHandle.new(std.heap.page_allocator) });
    }
};

test "scroll: wheel events move the tracked scroll offset, clamped to the content" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Scroller.build);
    const handle = view.read(cx.app).scroll;
    vcx.simulate_scroll(.{ .x = 10, .y = 10 }, .{ .x = 0, .y = -30 });
    try std.testing.expectEqual(@as(Pixels, -30), handle.offset().y);
    vcx.simulate_scroll(.{ .x = 10, .y = 10 }, .{ .x = 0, .y = -10000 });
    try std.testing.expectEqual(-handle.max_offset().height, handle.offset().y);
}

/// A panel with an `on_mouse_down_out` listener.
const Panel = struct {
    outside: usize = 0,

    pub fn render(_: *Panel, _: *Window, cx: *Context(Panel)) *Div {
        return div().w(px(400)).h(px(400)).child(
            div().id("panel").w(px(100)).h(px(100)).on_mouse_down_out(cx.listener(on_out)),
        );
    }
    fn on_out(self: *Panel, _: *const interactive.MouseDownEvent, _: *Window, cx: *Context(Panel)) void {
        self.outside += 1;
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Panel) {
        return app.new(Panel{});
    }
};

test "mouse: on_mouse_down_out fires only for presses outside the element" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Panel.build);
    vcx.simulate_mouse_down(.{ .x = 50, .y = 50 }, .left, .{});
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).outside);
    vcx.simulate_mouse_down(.{ .x = 300, .y = 300 }, .left, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).outside);
}

test "clipboard: write then read round-trips through the headless platform" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    try std.testing.expect(cx.read_from_clipboard() == null);
    cx.write_to_clipboard(platform_mod.ClipboardItem.new_string("hello"));
    try std.testing.expectEqualStrings("hello", cx.read_from_clipboard().?.text().?);
}

test "windows: simulate_resize updates the viewport" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(Counter.build);
    vcx.simulate_resize(.{ .width = 320, .height = 240 });
    try std.testing.expectEqual(@as(Pixels, 320), vcx.window.viewport_size.width);
    try std.testing.expectEqual(@as(Pixels, 240), vcx.window.viewport_size.height);
}

/// Re-renders from state: the quad width tracks `count`, so a repaint after `notify` is observable.
const Growing = struct {
    count: usize = 0,

    pub fn render(self: *Growing, _: *Window, cx: *Context(Growing)) *Div {
        return div().id("grow").h(px(50)).w(px(@floatFromInt(100 + self.count))).bg(red()).on_click(cx.listener(on_click));
    }
    fn on_click(self: *Growing, _: *const ClickEvent, _: *Window, cx: *Context(Growing)) void {
        self.count += 1;
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Growing) {
        return app.new(Growing{});
    }
};

fn scene_has_quad_width(window: *const Window, width: f32) bool {
    for (window.rendered_frame.scene.quads.items) |q| {
        if (q.bounds.size.width == width) return true;
    }
    return false;
}

test "windows: notify re-renders the view with new state" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(Growing.build);
    try std.testing.expect(scene_has_quad_width(vcx.window, 100));
    vcx.simulate_click(.{ .x = 5, .y = 5 }, .{});
    try std.testing.expect(scene_has_quad_width(vcx.window, 101));
    try std.testing.expect(!scene_has_quad_width(vcx.window, 100));
}

test "actions: a key binding whose context does not match is ignored" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("cmd-s", Editor.Save{}, "Terminal")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 0), cx.read_entity(view, Editor.read_state, .{}).saves);
}

test "actions: an unhandled action falls back to App.on_action" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Global = struct {
        var hits: usize = 0;
        fn on_save(_: *const Editor.Save, _: *App) void {
            hits += 1;
        }
    };
    Global.hits = 0;
    cx.app.on_action(Editor.Save, Global.on_save);
    cx.app.bind_keys(&.{KeyBinding.new("cmd-s", Editor.Save{}, null)});
    _, const vcx = cx.add_window_view(Counter.build);
    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 1), Global.hits);
}

test "windows: WindowHandle.update mutates the root view with window access" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const handle = cx.add_window(Counter.build);
    const Setter = struct {
        fn set(self: *Counter, value: usize, window: *Window, _: *Context(Counter)) void {
            self.count = value;
            window.refresh();
        }
    };
    try handle.update(cx.app, Setter.set, .{@as(usize, 42)});
    const root = (try handle.root(cx.app));
    try std.testing.expectEqual(@as(usize, 42), root.read(cx.app).count);
}

test "tasks: foreground spawn runs during run_until_parked" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Done = struct {
        fn work(value: usize) usize {
            return value * 2;
        }
    };
    var task = cx.app.foreground_executor().spawn(Done.work, .{@as(usize, 21)});
    cx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 42), task.get().?);
}

test "globals: update_global from a context notifies observers" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.set_global(Theme{});
    const Seen = struct {
        var changes: usize = 0;
        fn on(_: *App) void {
            changes += 1;
        }
    };
    Seen.changes = 0;
    var sub = cx.app.observe_global(Theme, Seen.on);
    defer sub.unsubscribe();
    _ = cx.app.update_global(Theme, struct {
        fn f(t: *Theme, _: *App) void {
            t.dark = true;
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 1), Seen.changes);
}
