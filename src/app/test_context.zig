//! Port of GPUI `app/test_context.rs`: `TestAppContext` and `VisualTestContext`.
//!
//! Both run on the headless platform. Frames and foreground work are pumped by
//! `run_until_parked`, and input is injected through `Window.dispatch_event`,
//! so tests exercise the same dispatch paths as a real platform.

const std = @import("std");
const input_mod = @import("../input.zig");
const view_mod = @import("../view.zig");
const color_mod = @import("../color.zig");
const headless_mod = @import("../platform/headless.zig");
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
        if (ks.key_char == null and !ks.modifiers.control and !ks.modifiers.platform and ks.key.len == 1) {
            ks.key_char = if (ks.modifiers.shift and std.ascii.isLower(ks.key[0])) shifted_letter(ks.key[0]) else ks.key;
        }
        _ = window.dispatch_event(.{ .key_down = .{ .keystroke = ks } }, self.app);
        _ = window.dispatch_event(.{ .key_up = .{ .keystroke = ks } }, self.app);
    }

    fn shifted_letter(c: u8) []const u8 {
        const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        return upper[c - 'a' ..][0..1];
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

test "windows: closing a window releases its root view" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const handle = cx.add_window(Counter.build);
    const root = (try handle.root(cx.app));
    const weak = root.downgrade();
    const win = handle.window(cx.app) orelse return error.TestUnexpectedResult;
    cx.app.close_window(win);
    try std.testing.expect(weak.upgrade(cx.app) == null);
    try std.testing.expect(handle.window(cx.app) == null);
}

/// A parent and child both handle clicks; the child stops propagation.
const Nested = struct {
    parent_clicks: usize = 0,
    child_clicks: usize = 0,

    pub fn render(_: *Nested, _: *Window, cx: *Context(Nested)) *Div {
        return div().id("parent").w(px(200)).h(px(200)).on_click(cx.listener(on_parent_click))
            .child(div().id("child").w(px(50)).h(px(50)).on_click(cx.listener(on_child_click)));
    }
    fn on_parent_click(self: *Nested, _: *const ClickEvent, _: *Window, _: *Context(Nested)) void {
        self.parent_clicks += 1;
    }
    fn on_child_click(self: *Nested, _: *const ClickEvent, window: *Window, _: *Context(Nested)) void {
        self.child_clicks += 1;
        window.stop_propagation();
    }
    fn build(_: *Window, app: *App) Entity(Nested) {
        return app.new(Nested{});
    }
    fn read_clicks(s: *const Nested, _: *const App) struct { parent: usize, child: usize } {
        return .{ .parent = s.parent_clicks, .child = s.child_clicks };
    }
};

test "mouse: stop_propagation keeps a click from reaching the parent" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Nested.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    var clicks = cx.read_entity(view, Nested.read_clicks, .{});
    try std.testing.expectEqual(@as(usize, 1), clicks.child);
    try std.testing.expectEqual(@as(usize, 0), clicks.parent);

    vcx.simulate_click(.{ .x = 100, .y = 100 }, .{});
    clicks = cx.read_entity(view, Nested.read_clicks, .{});
    try std.testing.expectEqual(@as(usize, 1), clicks.parent);
}

/// A text field that receives typed text through a `PlatformInputHandler` registered each frame.
const TextField = struct {
    focus: FocusHandle,
    buffer: [64]u8 = @splat(0),
    len: usize = 0,

    const input_vtable: platform_mod.PlatformInputHandler.VTable = .{
        .selected_text_range = selected_text_range,
        .marked_text_range = marked_text_range,
        .text_for_range = text_for_range,
        .replace_text_in_range = replace_text_in_range,
        .replace_and_mark_text_in_range = replace_and_mark_text_in_range,
        .unmark_text = unmark_text,
        .bounds_for_range = bounds_for_range,
        .character_index_for_point = character_index_for_point,
        .accepts_text_input = accepts_text_input,
    };

    fn from_ctx(ctx: *anyopaque) *TextField {
        return @ptrCast(@alignCast(ctx));
    }
    fn selected_text_range(_: *anyopaque, _: bool, _: *Window, _: *App) ?platform_mod.UTF16Selection {
        return null;
    }
    fn marked_text_range(_: *anyopaque, _: *Window, _: *App) ?platform_mod.Range {
        return null;
    }
    fn text_for_range(_: *anyopaque, _: platform_mod.Range, _: *?platform_mod.Range, _: *Window, _: *App) ?[]const u8 {
        return null;
    }
    fn replace_text_in_range(ctx: *anyopaque, _: ?platform_mod.Range, text: []const u8, _: *Window, cx: *App) void {
        const self = from_ctx(ctx);
        const n = @min(text.len, self.buffer.len - self.len);
        @memcpy(self.buffer[self.len..][0..n], text[0..n]);
        self.len += n;
        cx.refresh_windows();
    }
    fn replace_and_mark_text_in_range(_: *anyopaque, _: ?platform_mod.Range, _: []const u8, _: ?platform_mod.Range, _: *Window, _: *App) void {}
    fn unmark_text(_: *anyopaque, _: *Window, _: *App) void {}
    fn bounds_for_range(_: *anyopaque, _: platform_mod.Range, _: *Window, _: *App) ?geometry.Bounds(Pixels) {
        return null;
    }
    fn character_index_for_point(_: *anyopaque, _: Point(Pixels), _: *Window, _: *App) ?usize {
        return null;
    }
    fn accepts_text_input(_: *anyopaque, _: *Window, _: *App) bool {
        return true;
    }

    pub fn render(self: *TextField, window: *Window, cx: *Context(TextField)) *Div {
        // Input handlers are registered during the frame, while the field is focused.
        window.handle_input(&self.focus, platform_mod.PlatformInputHandler{ .ctx = self, .vtable = &input_vtable }, cx.app);
        return div().id("field").w(px(100)).h(px(30)).track_focus(&self.focus);
    }
    fn build(_: *Window, app: *App) Entity(TextField) {
        return app.new(TextField{ .focus = app.focus_handle() });
    }
    fn read_text(s: *const TextField, _: *const App) []const u8 {
        return s.buffer[0..s.len];
    }
};

test "keystrokes: typed text is delivered to the focused input handler" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(TextField.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.simulate_input("hi");
    try std.testing.expectEqualStrings("hi", cx.read_entity(view, TextField.read_text, .{}));
    vcx.simulate_keystrokes("shift-a");
    try std.testing.expectEqualStrings("hiA", cx.read_entity(view, TextField.read_text, .{}));
    vcx.simulate_keystrokes("cmd-a");
    try std.testing.expectEqualStrings("hiA", cx.read_entity(view, TextField.read_text, .{}));
}

/// A field holding ASCII text with a composition, through `ElementInputHandler`. Two focus
/// handles let tests move focus between fields of the same view.
const ImeField = struct {
    focus: FocusHandle,
    other_focus: FocusHandle,
    buffer: [64]u8 = @splat(0),
    len: usize = 0,
    marked: ?platform_mod.Range = null,
    caret: usize = 0,
    accepts: bool = true,

    pub fn render(self: *ImeField, window: *Window, cx: *Context(ImeField)) *Div {
        const bounds: geometry.Bounds(Pixels) = .{ .origin = .{ .x = 5, .y = 7 }, .size = .{ .width = 100, .height = 20 } };
        window.handle_input(&self.focus, input_mod.ElementInputHandler(ImeField).new(bounds, cx.entity()), cx);
        window.handle_input(&self.other_focus, input_mod.ElementInputHandler(ImeField).new(bounds, cx.entity()), cx);
        return div().w(px(100)).h(px(30)).track_focus(&self.focus).child(div().w(px(10)).h(px(10)).track_focus(&self.other_focus));
    }

    pub fn text_for_range(self: *ImeField, range: platform_mod.Range, _: *?platform_mod.Range, _: *Window, _: *Context(ImeField)) ?[]const u8 {
        return self.buffer[range.start..range.end];
    }
    pub fn selected_text_range(self: *ImeField, _: bool, _: *Window, _: *Context(ImeField)) ?platform_mod.UTF16Selection {
        return .{ .range = .{ .start = self.caret, .end = self.caret } };
    }
    pub fn marked_text_range(self: *ImeField, _: *Window, _: *Context(ImeField)) ?platform_mod.Range {
        return self.marked;
    }
    pub fn unmark_text(self: *ImeField, _: *Window, _: *Context(ImeField)) void {
        self.marked = null;
    }
    pub fn replace_text_in_range(self: *ImeField, range: ?platform_mod.Range, text: []const u8, _: *Window, _: *Context(ImeField)) void {
        const r = range orelse self.marked orelse platform_mod.Range{ .start = self.caret, .end = self.caret };
        self.splice(r, text);
        self.marked = null;
    }
    pub fn replace_and_mark_text_in_range(self: *ImeField, range: ?platform_mod.Range, text: []const u8, new_selected: ?platform_mod.Range, _: *Window, _: *Context(ImeField)) void {
        const r = range orelse self.marked orelse platform_mod.Range{ .start = self.caret, .end = self.caret };
        self.splice(r, text);
        self.marked = if (text.len > 0) .{ .start = r.start, .end = r.start + text.len } else null;
        if (new_selected) |sel| self.caret = r.start + sel.end;
    }
    pub fn bounds_for_range(_: *ImeField, range: platform_mod.Range, element_bounds: geometry.Bounds(Pixels), _: *Window, _: *Context(ImeField)) ?geometry.Bounds(Pixels) {
        return .{ .origin = .{ .x = element_bounds.origin.x + @as(f32, @floatFromInt(range.start)) * 10, .y = element_bounds.origin.y }, .size = .{ .width = 0, .height = 20 } };
    }
    pub fn character_index_for_point(_: *ImeField, _: Point(Pixels), _: *Window, _: *Context(ImeField)) ?usize {
        return 0;
    }
    pub fn accepts_text_input(self: *ImeField, _: *Window, _: *Context(ImeField)) bool {
        return self.accepts;
    }

    fn splice(self: *ImeField, r: platform_mod.Range, text: []const u8) void {
        const tail_len = self.len - r.end;
        std.mem.copyForwards(u8, self.buffer[r.start + text.len..], self.buffer[r.end..self.len]);
        @memcpy(self.buffer[r.start..][0..text.len], text);
        self.len = r.start + text.len + tail_len;
        self.caret = r.start + text.len;
    }

    fn build(_: *Window, app: *App) Entity(ImeField) {
        return app.new(ImeField{ .focus = app.focus_handle(), .other_focus = app.focus_handle() });
    }
    fn read_text(s: *const ImeField, _: *const App) []const u8 {
        return s.buffer[0..s.len];
    }
    fn read_marked(s: *const ImeField, _: *const App) ?platform_mod.Range {
        return s.marked;
    }
    fn ime(vcx: *VisualTestContext, input: platform_mod.ImeInput) void {
        vcx.window.platform_window.emit_ime(input);
        vcx.cx.app.flush_effects();
    }
    fn headless(vcx: *VisualTestContext) *headless_mod.HeadlessWindow {
        return @fieldParentPtr("base", vcx.window.platform_window);
    }
};

const NestedFocus = struct {
    outer: FocusHandle,
    inner: FocusHandle,

    pub fn render(self: *NestedFocus, _: *Window, _: *Context(NestedFocus)) *Div {
        return div().id("outer").size(px(100)).track_focus(&self.outer).child(div().id("inner").size(px(20)).track_focus(&self.inner));
    }
    fn build(_: *Window, app: *App) Entity(NestedFocus) {
        return app.new(NestedFocus{ .outer = app.focus_handle(), .inner = app.focus_handle() });
    }
};

test "focus: clicking a focusable child keeps focus from its focusable parent" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(NestedFocus.build);
    vcx.simulate_click(.{ .x = 5, .y = 5 }, .{});
    try std.testing.expect(view.read(cx.app).inner.is_focused(vcx.window));
    try std.testing.expect(!view.read(cx.app).outer.is_focused(vcx.window));
    // Outside the child, the parent takes it.
    vcx.simulate_click(.{ .x = 50, .y = 50 }, .{});
    try std.testing.expect(view.read(cx.app).outer.is_focused(vcx.window));
}

test "input: a composition replaces itself and commits in place" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    vcx.focus(view.read(cx.app).focus);
    vcx.simulate_input("ab");

    ImeField.ime(vcx, .{ .set_marked_text = .{ .text = "n" } });
    try std.testing.expectEqualStrings("abn", cx.read_entity(view, ImeField.read_text, .{}));
    ImeField.ime(vcx, .{ .set_marked_text = .{ .text = "ni" } });
    try std.testing.expectEqualStrings("abni", cx.read_entity(view, ImeField.read_text, .{}));
    try std.testing.expectEqual(platform_mod.Range{ .start = 2, .end = 4 }, cx.read_entity(view, ImeField.read_marked, .{}).?);

    // Committing replaces the composition, wherever the caret is.
    ImeField.ime(vcx, .{ .insert_text = "XY" });
    try std.testing.expectEqualStrings("abXY", cx.read_entity(view, ImeField.read_text, .{}));
    try std.testing.expect(cx.read_entity(view, ImeField.read_marked, .{}) == null);

    // A typed key replaces a composition too: that is how a composed dead key lands.
    ImeField.ime(vcx, .{ .set_marked_text = .{ .text = "'" } });
    vcx.simulate_input("e");
    try std.testing.expectEqualStrings("abXYe", cx.read_entity(view, ImeField.read_text, .{}));
}

test "input: cancelling and accepting a composition" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    vcx.focus(view.read(cx.app).focus);
    vcx.simulate_input("a");

    ImeField.ime(vcx, .{ .set_marked_text = .{ .text = "zz" } });
    ImeField.ime(vcx, .delete_text);
    try std.testing.expectEqualStrings("a", cx.read_entity(view, ImeField.read_text, .{}));
    // With nothing marked, deleting must not touch the text.
    ImeField.ime(vcx, .delete_text);
    try std.testing.expectEqualStrings("a", cx.read_entity(view, ImeField.read_text, .{}));

    ImeField.ime(vcx, .{ .set_marked_text = .{ .text = "q" } });
    ImeField.ime(vcx, .unmark_text);
    try std.testing.expectEqualStrings("aq", cx.read_entity(view, ImeField.read_text, .{}));
    try std.testing.expect(cx.read_entity(view, ImeField.read_marked, .{}) == null);
}

test "input: the platform hears about every change of focused field" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    const win = ImeField.headless(vcx);
    try std.testing.expect(!win.ime_enabled);

    vcx.focus(view.read(cx.app).focus);
    vcx.run_until_parked();
    try std.testing.expect(win.ime_enabled);
    try std.testing.expectEqual(@as(u32, 1), win.ime_enabled_changes);

    // Redrawing the same field says nothing new.
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(u32, 1), win.ime_enabled_changes);

    // Moving between two text fields: off, then on again, as text-input-v3 requires.
    vcx.focus(view.read(cx.app).other_focus);
    vcx.run_until_parked();
    try std.testing.expect(win.ime_enabled);
    try std.testing.expectEqual(@as(u32, 3), win.ime_enabled_changes);

    vcx.window.blur();
    vcx.run_until_parked();
    try std.testing.expect(!win.ime_enabled);
}

test "input: a field that refuses text disables the input method" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    const win = ImeField.headless(vcx);
    vcx.focus(view.read(cx.app).focus);
    vcx.run_until_parked();
    try std.testing.expect(win.ime_enabled);

    view.as_mut(cx.app).accepts = false;
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(!win.ime_enabled);
}

test "input: candidates follow the caret, and the composition start while composing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    const win = ImeField.headless(vcx);
    vcx.focus(view.read(cx.app).focus);
    vcx.run_until_parked();
    vcx.simulate_input("ab");

    vcx.window.invalidate_character_coordinates();
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(f32, 25), win.ime_position.?.origin.x);

    ImeField.ime(vcx, .{ .set_marked_text = .{ .text = "xyz" } });
    const area = win.base.ime_area().?;
    try std.testing.expectEqual(@as(f32, 25), area.origin.x);
}

test "input: the caret position reaches the input method after typing, without being asked" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    const win = ImeField.headless(vcx);
    vcx.focus(view.read(cx.app).focus);
    vcx.run_until_parked();
    vcx.simulate_input("abc");
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(f32, 35), win.ime_position.?.origin.x);

    // Text set by the application only counts once the view says so.
    win.ime_position = null;
    view.as_mut(cx.app).caret = 1;
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(win.ime_position == null);
    vcx.window.notify_text_input_changed(&view.read(cx.app).focus);
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(f32, 15), win.ime_position.?.origin.x);

    // Notifications about a field without focus are ignored.
    win.ime_position = null;
    vcx.window.notify_text_input_changed(&view.read(cx.app).other_focus);
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(win.ime_position == null);
}

const DragField = struct {
    released_outside: usize = 0,
    released_inside: usize = 0,

    pub fn render(_: *DragField, _: *Window, cx: *Context(DragField)) *Div {
        return div().size(px(200)).child(
            div().id("field").size(px(20)).on_mouse_up(.left, cx.listener(on_inside)).on_mouse_up_out(.left, cx.listener(on_outside)),
        );
    }
    fn on_inside(self: *DragField, _: *const interactive.MouseUpEvent, _: *Window, _: *Context(DragField)) void {
        self.released_inside += 1;
    }
    fn on_outside(self: *DragField, _: *const interactive.MouseUpEvent, _: *Window, _: *Context(DragField)) void {
        self.released_outside += 1;
    }
    fn build(_: *Window, app: *App) Entity(DragField) {
        return app.new(DragField{});
    }
};

test "div: on_mouse_up_out fires only for releases outside the element" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragField.build);
    vcx.simulate_click(.{ .x = 5, .y = 5 }, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).released_inside);
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).released_outside);
    vcx.simulate_click(.{ .x = 100, .y = 100 }, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).released_inside);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).released_outside);
}

test "input: a released view reads as an empty field instead of crashing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    vcx.focus(view.read(cx.app).focus);
    vcx.run_until_parked();
    var handler = input_mod.ElementInputHandler(ImeField).new(.{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 1 } }, view).platform_input_handler();
    // An id that was never allocated stands in for a view released after painting.
    const dead = input_mod.ElementInputHandler(ImeField);
    const stale: *dead = @ptrCast(@alignCast(handler.ctx));
    stale.view = .{ .entity_id_ = @enumFromInt(0x7fffffff) };
    try std.testing.expect(!handler.accepts_text_input(vcx.window, cx.app));
    try std.testing.expect(handler.selected_text_range(true, vcx.window, cx.app) == null);
    handler.replace_text_in_range(null, "x", vcx.window, cx.app);
    try std.testing.expect(handler.selected_bounds(vcx.window, cx.app) == null);
}

const Payload = struct { n: u32 };

const DragPreview = struct {
    n: u32,
    pub fn render(_: *DragPreview, _: *Window, _: *Context(DragPreview)) *Div {
        return div().w(px(10)).h(px(10)).bg(color_mod.red());
    }
};

const DragPage = struct {
    dropped: ?u32 = null,
    drops: usize = 0,
    clicks: usize = 0,
    aux_clicks: usize = 0,
    previews_made: usize = 0,
    files: usize = 0,
    file_name: [64]u8 = undefined,
    file_name_len: usize = 0,
    allow: bool = true,
    pinches: usize = 0,

    var allow_drop: bool = true;

    fn make_preview(value: *const Payload, _: Point(Pixels), _: *Window, cx: *App) Entity(DragPreview) {
        return cx.new(DragPreview{ .n = value.n });
    }
    fn refuse(_: app_mod.AnyDragValue, _: *Window, _: *App) bool {
        return allow_drop;
    }
    fn on_drop(self: *DragPage, value: *const Payload, _: *Window, _: *Context(DragPage)) void {
        self.dropped = value.n;
        self.drops += 1;
    }
    fn on_files(self: *DragPage, value: *const interactive.ExternalPaths, _: *Window, _: *Context(DragPage)) void {
        self.files = value.items.len;
        // Paths belong to the platform, so a handler that keeps them copies them.
        const first = value.items[0];
        self.file_name_len = @min(first.len, self.file_name.len);
        @memcpy(self.file_name[0..self.file_name_len], first[0..self.file_name_len]);
    }
    fn on_click(self: *DragPage, _: *const interactive.ClickEvent, _: *Window, _: *Context(DragPage)) void {
        self.clicks += 1;
    }
    fn on_aux(self: *DragPage, _: *const interactive.ClickEvent, _: *Window, _: *Context(DragPage)) void {
        self.aux_clicks += 1;
    }
    fn on_pinch(self: *DragPage, _: *const interactive.PinchEvent, _: *Window, _: *Context(DragPage)) void {
        self.pinches += 1;
    }
    pub fn render(_: *DragPage, _: *Window, cx: *Context(DragPage)) *Div {
        return div().size(px(300)).child(
            div().id("source").absolute().left(px(0)).top(px(0)).w(px(50)).h(px(50))
                .on_drag(Payload{ .n = 7 }, make_preview)
                .on_click(cx.listener(on_click))
                .on_aux_click(cx.listener(on_aux)),
        ).child(
            div().id("target").absolute().left(px(100)).top(px(0)).w(px(50)).h(px(50))
                .on_drop(Payload, cx.listener(on_drop))
                .on_drop(interactive.ExternalPaths, cx.listener(on_files))
                .on_pinch(cx.listener(on_pinch)),
        ).child(
            div().id("picky").absolute().left(px(200)).top(px(0)).w(px(50)).h(px(50))
                .can_drop(refuse)
                .on_drop(Payload, cx.listener(on_drop)),
        );
    }
    fn build(_: *Window, app: *App) Entity(DragPage) {
        return app.new(DragPage{});
    }
};

fn start_drag(vcx: *VisualTestContext) void {
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.simulate_mouse_down(.{ .x = 10, .y = 10 }, .left, .{});
    vcx.simulate_mouse_move(.{ .x = 30, .y = 10 }, .left, .{});
    vcx.run_until_parked();
}

test "drag: dropping on a target delivers the value and ends the drag" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    start_drag(vcx);
    try std.testing.expect(cx.app.has_active_drag());
    vcx.simulate_mouse_move(.{ .x = 120, .y = 10 }, .left, .{});
    vcx.run_until_parked();
    vcx.simulate_mouse_up(.{ .x = 120, .y = 10 }, .left, .{});
    vcx.run_until_parked();
    try std.testing.expect(!cx.app.has_active_drag());
    try std.testing.expectEqual(@as(?u32, 7), view.read(cx.app).dropped);
    // Starting a drag is not a click.
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).clicks);
}

test "drag: a release away from any target cancels without delivering" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    start_drag(vcx);
    vcx.simulate_mouse_move(.{ .x = 280, .y = 280 }, .left, .{});
    vcx.simulate_mouse_up(.{ .x = 280, .y = 280 }, .left, .{});
    vcx.run_until_parked();
    try std.testing.expect(!cx.app.has_active_drag());
    try std.testing.expect(view.read(cx.app).dropped == null);
}

test "drag: small jitter stays a click, and only the threshold starts a drag" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.simulate_mouse_down(.{ .x = 10, .y = 10 }, .left, .{});
    vcx.simulate_mouse_move(.{ .x = 11, .y = 11 }, .left, .{});
    try std.testing.expect(!cx.app.has_active_drag());
    vcx.simulate_mouse_up(.{ .x = 11, .y = 11 }, .left, .{});
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).clicks);
}

test "drag: moving the pointer without a press does not start one" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(DragPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.simulate_mouse_move(.{ .x = 40, .y = 40 }, null, .{});
    try std.testing.expect(!cx.app.has_active_drag());
    // A press and release elsewhere clears any state before moving back over.
    vcx.simulate_mouse_down(.{ .x = 10, .y = 10 }, .left, .{});
    vcx.simulate_mouse_up(.{ .x = 280, .y = 280 }, .left, .{});
    vcx.simulate_mouse_move(.{ .x = 30, .y = 30 }, null, .{});
    try std.testing.expect(!cx.app.has_active_drag());
}

test "drag: can_drop refuses the value, and the drag still ends" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    DragPage.allow_drop = false;
    defer DragPage.allow_drop = true;
    const view, const vcx = cx.add_window_view(DragPage.build);
    start_drag(vcx);
    vcx.simulate_mouse_move(.{ .x = 220, .y = 10 }, .left, .{});
    vcx.simulate_mouse_up(.{ .x = 220, .y = 10 }, .left, .{});
    vcx.run_until_parked();
    try std.testing.expect(view.read(cx.app).dropped == null);
    try std.testing.expect(!cx.app.has_active_drag());
}

test "drag: the preview draws at the pointer, and stop_active_drag cancels it" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(DragPage.build);
    const before = vcx.window.rendered_frame.scene.quads.items.len;
    start_drag(vcx);
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(vcx.window.rendered_frame.scene.quads.items.len > before);
    try std.testing.expect(cx.app.stop_active_drag(vcx.window));
    try std.testing.expect(!cx.app.stop_active_drag(vcx.window));
}

test "clicks: other buttons reach on_aux_click, not on_click" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.simulate_mouse_down(.{ .x = 10, .y = 10 }, .right, .{});
    vcx.simulate_mouse_up(.{ .x = 10, .y = 10 }, .right, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).aux_clicks);
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).clicks);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).clicks);
}

test "file drags: paths reach on_drop like any other drag" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    const paths = [_][]const u8{ "/tmp/a.txt", "/tmp/b.png" };
    vcx.simulate_event(.{ .file_drop = .{ .entered = .{ .position = .{ .x = 120, .y = 10 }, .paths = .{ .items = &paths } } } });
    try std.testing.expect(cx.app.has_active_drag());
    vcx.run_until_parked();
    vcx.simulate_event(.{ .file_drop = .{ .pending = .{ .position = .{ .x = 125, .y = 12 } } } });
    vcx.run_until_parked();
    vcx.simulate_event(.{ .file_drop = .{ .submit = .{ .position = .{ .x = 125, .y = 12 } } } });
    vcx.run_until_parked();
    try std.testing.expect(!cx.app.has_active_drag());
    try std.testing.expectEqual(@as(usize, 2), view.read(cx.app).files);
    const page = view.read(cx.app);
    try std.testing.expectEqualStrings("/tmp/a.txt", page.file_name[0..page.file_name_len]);
}

test "file drags: leaving the window ends the drag and drops nothing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    const paths = [_][]const u8{"/tmp/a.txt"};
    vcx.simulate_event(.{ .file_drop = .{ .entered = .{ .position = .{ .x = 120, .y = 10 }, .paths = .{ .items = &paths } } } });
    vcx.simulate_event(.{ .file_drop = .exited });
    vcx.run_until_parked();
    try std.testing.expect(!cx.app.has_active_drag());
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).files);
}

test "pinch: reaches the element under the pointer" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    vcx.simulate_mouse_move(.{ .x = 120, .y = 10 }, null, .{});
    vcx.simulate_event(.{ .pinch = .{ .position = .{ .x = 120, .y = 10 }, .delta = 0.1 } });
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).pinches);
    vcx.simulate_mouse_move(.{ .x = 280, .y = 280 }, null, .{});
    vcx.simulate_event(.{ .pinch = .{ .position = .{ .x = 280, .y = 280 }, .delta = 0.1 } });
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).pinches);
}

const TooltipView = struct {
    pub fn render(_: *TooltipView, _: *Window, _: *Context(TooltipView)) *Div {
        return div().w(px(40)).h(px(20)).bg(color_mod.red());
    }
};

const TooltipPage = struct {
    show_button: bool = true,
    hoverable: bool = false,

    fn build_tip(_: *Window, cx: *App) view_mod.AnyView {
        return view_mod.AnyView.from(cx.new(TooltipView{}));
    }
    pub fn render(self: *TooltipPage, _: *Window, _: *Context(TooltipPage)) *Div {
        const root = div().size(px(300));
        if (self.show_button) {
            const button = div().id("button").absolute().left(px(0)).top(px(0)).w(px(50)).h(px(50)).tooltip_show_delay(1);
            _ = if (self.hoverable) button.hoverable_tooltip(build_tip) else button.tooltip(build_tip);
            _ = root.child(button);
        }
        return root;
    }
    fn build(_: *Window, app: *App) Entity(TooltipPage) {
        return app.new(TooltipPage{});
    }
};

fn wait_for_tooltip(vcx: *VisualTestContext, wanted: bool) !void {
    for (0..200) |_| {
        vcx.run_until_parked();
        if ((vcx.window.tooltip_bounds != null) == wanted) return;
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.TooltipTimedOut;
}

test "tooltip: shows after the delay and closes when the pointer leaves" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(TooltipPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.run_until_parked();
    try wait_for_tooltip(vcx, true);
    try std.testing.expectEqual(@as(f32, 11), vcx.window.tooltip_bounds.?.origin.x);
    vcx.simulate_mouse_move(.{ .x = 200, .y = 200 }, null, .{});
    try wait_for_tooltip(vcx, false);
}

test "tooltip: leaving before the delay means it never shows" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(TooltipPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.simulate_mouse_move(.{ .x = 200, .y = 200 }, null, .{});
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 40 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
    vcx.run_until_parked();
    try std.testing.expect(vcx.window.tooltip_bounds == null);
}

test "tooltip: a press closes it, and does not bring it back" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(TooltipPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    try wait_for_tooltip(vcx, true);
    vcx.simulate_mouse_down(.{ .x = 10, .y = 10 }, .left, .{});
    try wait_for_tooltip(vcx, false);
    vcx.simulate_mouse_up(.{ .x = 10, .y = 10 }, .left, .{});
    vcx.run_until_parked();
}

test "tooltip: its element disappearing while it shows closes it safely" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(TooltipPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    try wait_for_tooltip(vcx, true);
    view.as_mut(cx.app).show_button = false;
    vcx.window.refresh();
    try wait_for_tooltip(vcx, false);
}

test "tooltip: a timer firing after its element is gone does nothing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(TooltipPage.build);
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    view.as_mut(cx.app).show_button = false;
    vcx.window.refresh();
    vcx.run_until_parked();
    vcx.window.refresh();
    vcx.run_until_parked();
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
    vcx.run_until_parked();
    try std.testing.expect(vcx.window.tooltip_bounds == null);
}

test "tooltip: a hoverable one survives the pointer moving onto it" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(TooltipPage.build);
    view.as_mut(cx.app).hoverable = true;
    vcx.window.refresh();
    vcx.run_until_parked();
    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    try wait_for_tooltip(vcx, true);
    const b = vcx.window.tooltip_bounds.?;
    // Off the button, onto the tooltip. The tooltip starts at the pointer, inside the button,
    // so go to its far corner, moved past the button with the tooltip still there.
    vcx.simulate_mouse_move(.{ .x = b.origin.x + b.size.width - 1, .y = b.origin.y + 1 }, null, .{});
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(vcx.window.tooltip_bounds != null);
}

test "tooltip placement stays inside the window" {
    const viewport: geometry.Size(Pixels) = .{ .width = 100, .height = 100 };
    const tip: geometry.Size(Pixels) = .{ .width = 30, .height = 20 };
    const place = window_mod.tooltip_origin;
    try std.testing.expectEqual(@as(f32, 11), place(.{ .x = 10, .y = 10 }, tip, viewport).x);
    // Past the right and bottom edges it flips to the other side of the pointer.
    const corner = place(.{ .x = 95, .y = 95 }, tip, viewport);
    try std.testing.expectEqual(@as(f32, 64), corner.x);
    try std.testing.expectEqual(@as(f32, 74), corner.y);
    // Bigger than the window: pinned to the start rather than off screen.
    const huge = place(.{ .x = 5, .y = 5 }, .{ .width = 500, .height = 500 }, viewport);
    try std.testing.expectEqual(@as(f32, 0), huge.x);
    try std.testing.expectEqual(@as(f32, 0), huge.y);
}

test "VisualTestContext: focus, update, mouse move and dispatch_action" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Editor.build);
    const handle = view.read(cx.app).focus;
    vcx.focus(handle);
    try std.testing.expect(handle.is_focused(vcx.window));

    const saves = vcx.update(struct {
        fn f(window: *Window, _: *App) bool {
            return window.is_action_available(app_mod.type_id(Editor.Save));
        }
    }.f, .{});
    try std.testing.expect(saves);

    vcx.simulate_mouse_move(.{ .x = 10, .y = 10 }, null, .{});
    vcx.dispatch_action(Editor.Save{});
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);
}

test "TestAppContext: public API compiles and an extra window opens" {
    std.testing.refAllDecls(TestAppContext);
    std.testing.refAllDecls(VisualTestContext);
    var cx = TestAppContext.init();
    defer cx.deinit();
    _ = cx.add_window_with_options(.{ .titlebar = null }, Counter.build);
    _ = cx.executor();
    _ = cx.foreground_executor();
    _ = cx.background_executor();
    try std.testing.expectEqual(@as(usize, 1), cx.app.windows.items.len);
}
