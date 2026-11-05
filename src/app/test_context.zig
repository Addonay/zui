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

    /// Moves the window and reports it, as a window manager does (GPUI `on_moved`).
    pub fn simulate_move(self: *VisualTestContext, origin: Point(Pixels)) void {
        headless.HeadlessWindow.from(self.window.platform_window).move_to(origin);
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
const canvas_mod = @import("../elements/canvas.zig");
const style_cursor = @import("../style.zig").CursorStyle;
const img_mod = @import("../elements/img.zig");
const assets_mod = @import("../assets.zig");
const element_mod = @import("../element.zig");
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

fn wait_until_flushed(vcx: *VisualTestContext) !void {
    for (0..200) |_| {
        vcx.run_until_parked();
        if (!vcx.window.has_pending_keystrokes()) return;
        @import("../executor.zig").sleep_ns(5 * std.time.ns_per_ms);
    }
    return error.PendingInputNeverFlushed;
}

test "multi-stroke: a sequence runs its action and its keys reach nobody else" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("g s", Editor.Save{}, "Editor")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("g");
    try std.testing.expect(vcx.window.has_pending_keystrokes());
    try std.testing.expectEqual(@as(usize, 1), vcx.window.pending_input_keystrokes().?.len);
    try std.testing.expectEqual(@as(usize, 0), cx.read_entity(view, Editor.read_state, .{}).keys);

    vcx.simulate_keystrokes("s");
    const state = cx.read_entity(view, Editor.read_state, .{});
    try std.testing.expectEqual(@as(usize, 1), state.saves);
    try std.testing.expectEqual(@as(usize, 0), state.keys);
    try std.testing.expect(!vcx.window.has_pending_keystrokes());
}

test "multi-stroke: a wrong second key replays the first, in order" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("g s", Editor.Save{}, "Editor")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("g x");
    const state = cx.read_entity(view, Editor.read_state, .{});
    try std.testing.expectEqual(@as(usize, 0), state.saves);
    try std.testing.expectEqual(@as(usize, 2), state.keys);
    const last = view.read(cx.app);
    try std.testing.expectEqualStrings("x", last.last_key[0..last.last_key_len]);
    try std.testing.expect(!vcx.window.has_pending_keystrokes());
}

test "multi-stroke: a binding that is also a prefix fires after the timeout" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{ KeyBinding.new("g", Editor.Save{}, "Editor"), KeyBinding.new("g g", Editor.Outside{}, "Editor") });
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("g");
    try std.testing.expectEqual(@as(usize, 0), cx.read_entity(view, Editor.read_state, .{}).saves);
    try wait_until_flushed(vcx);
    const state = cx.read_entity(view, Editor.read_state, .{});
    try std.testing.expectEqual(@as(usize, 1), state.saves);
    try std.testing.expectEqual(@as(usize, 0), state.keys);
}

test "multi-stroke: without a binding of its own a prefix waits for the next key" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("ctrl-k ctrl-c", Editor.Save{}, "Editor")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("ctrl-k");
    // Past the timeout a prefix with a binding of its own would have fired by.
    @import("../executor.zig").sleep_ns(700 * std.time.ns_per_ms);
    vcx.run_until_parked();
    try std.testing.expect(vcx.window.has_pending_keystrokes());
    vcx.simulate_keystrokes("ctrl-c");
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);
}

test "multi-stroke: moving focus drops pending input" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("g s", Editor.Save{}, "Editor")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("g");
    try std.testing.expect(vcx.window.has_pending_keystrokes());
    vcx.window.blur();
    try std.testing.expect(!vcx.window.has_pending_keystrokes());
    view.read(cx.app).focus.focus(vcx.window);
    vcx.simulate_keystrokes("s");
    const state = cx.read_entity(view, Editor.read_state, .{});
    try std.testing.expectEqual(@as(usize, 0), state.saves);
    try std.testing.expectEqual(@as(usize, 1), state.keys);
}

const KeystrokeLog = struct {
    var observed: usize = 0;
    var last_had_action: bool = false;
    var intercepted: usize = 0;
    var stop: bool = false;
    var pending_changes: usize = 0;

    fn observe(event: *const app_mod.KeystrokeEvent, _: *Window, _: *App) void {
        observed += 1;
        last_had_action = event.action != null;
    }
    fn intercept(_: *const app_mod.KeystrokeEvent, window: *Window, _: *App) void {
        intercepted += 1;
        if (stop) window.stop_propagation();
    }
    fn pending_changed(_: *Window, _: *App) void {
        pending_changes += 1;
    }
};

test "keystroke observers see the action; interceptors run first and can stop bindings" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    KeystrokeLog.observed = 0;
    KeystrokeLog.intercepted = 0;
    KeystrokeLog.stop = false;
    cx.app.bind_keys(&.{KeyBinding.new("cmd-s", Editor.Save{}, "Editor")});
    _ = cx.app.observe_keystrokes(KeystrokeLog.observe);
    const interceptor = cx.app.intercept_keystrokes(KeystrokeLog.intercept);
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 1), KeystrokeLog.observed);
    try std.testing.expect(KeystrokeLog.last_had_action);
    try std.testing.expectEqual(@as(usize, 1), KeystrokeLog.intercepted);

    vcx.simulate_keystrokes("a");
    try std.testing.expectEqual(@as(usize, 2), KeystrokeLog.observed);
    try std.testing.expect(!KeystrokeLog.last_had_action);

    KeystrokeLog.stop = true;
    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);

    KeystrokeLog.stop = false;
    interceptor.unsubscribe();
    vcx.simulate_keystrokes("cmd-s");
    try std.testing.expectEqual(@as(usize, 2), cx.read_entity(view, Editor.read_state, .{}).saves);
    try std.testing.expectEqual(@as(usize, 3), KeystrokeLog.intercepted);
}

test "pending input observers run as a sequence starts and ends" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    KeystrokeLog.pending_changes = 0;
    cx.app.bind_keys(&.{KeyBinding.new("g s", Editor.Save{}, "Editor")});
    _, const vcx = cx.add_window_view(Editor.build);
    _ = cx.app.observe_pending_input(vcx.window, KeystrokeLog.pending_changed);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});

    vcx.simulate_keystrokes("g");
    try std.testing.expectEqual(@as(usize, 1), KeystrokeLog.pending_changes);
    vcx.simulate_keystrokes("s");
    try std.testing.expectEqual(@as(usize, 2), KeystrokeLog.pending_changes);
}

test "a modifier tapped alone is a keystroke; used with another key it is not" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("shift", Editor.Save{}, "Editor")});
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    const send = struct {
        fn modifiers(w: *Window, app: *App, shift: bool, control: bool) void {
            _ = w.dispatch_event(.{ .modifiers_changed = .{ .modifiers = .{ .shift = shift, .control = control } } }, app);
        }
    }.modifiers;

    send(vcx.window, cx.app, true, false);
    send(vcx.window, cx.app, false, false);
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);

    send(vcx.window, cx.app, true, false);
    vcx.simulate_keystrokes("shift-a");
    send(vcx.window, cx.app, false, false);
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);

    send(vcx.window, cx.app, true, false);
    send(vcx.window, cx.app, true, true);
    send(vcx.window, cx.app, false, false);
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, Editor.read_state, .{}).saves);
}

const OverscrollView = struct {
    var child_y: [64]f32 = undefined;
    var frames: usize = 0;

    fn record(_: void, bounds: geometry.Bounds(Pixels), _: *Window, _: *App) void {
        if (frames < child_y.len) child_y[frames] = bounds.origin.y;
        frames += 1;
    }

    pub fn render(_: *OverscrollView, _: *Window, _: *Context(OverscrollView)) *Div {
        return div().id("scroller").w(px(100)).h(px(100)).overflow_y_scroll().child(
            div().w(px(100)).h(px(300)).child(canvas_mod.canvas_fn({}, record).size_full()),
        );
    }
    fn build(_: *Window, app: *App) Entity(OverscrollView) {
        return app.new(OverscrollView{});
    }
};

test "scroll: no frame is painted past either end, and scrolling at a limit draws nothing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    OverscrollView.frames = 0;
    _, const vcx = cx.add_window_view(OverscrollView.build);
    vcx.run_until_parked();
    const pos: Point(Pixels) = .{ .x = 10, .y = 10 };

    // A first event at the top, before any limit could be known by an event.
    const at_rest = OverscrollView.frames;
    try std.testing.expect(at_rest > 0);
    vcx.simulate_scroll(pos, .{ .x = 0, .y = 50 });
    vcx.run_until_parked();
    try std.testing.expectEqual(at_rest, OverscrollView.frames);

    // Far past the bottom in one event stops exactly at the end.
    vcx.simulate_scroll(pos, .{ .x = 0, .y = -1000 });
    vcx.run_until_parked();
    try std.testing.expect(OverscrollView.frames > at_rest);
    const top = OverscrollView.child_y[0];
    try std.testing.expectEqual(top - 200, OverscrollView.child_y[OverscrollView.frames - 1]);

    // Past the bottom again: no frame.
    const at_end = OverscrollView.frames;
    vcx.simulate_scroll(pos, .{ .x = 0, .y = -50 });
    vcx.run_until_parked();
    try std.testing.expectEqual(at_end, OverscrollView.frames);

    // No frame ever left the range.
    for (OverscrollView.child_y[0..OverscrollView.frames]) |y| {
        try std.testing.expect(y <= top and y >= top - 200);
    }
}

const RemoteImageView = struct {
    var url: []const u8 = "";
    var fallbacks: usize = 0;
    var loadings: usize = 0;

    fn on_fallback() element_mod.AnyElement {
        fallbacks += 1;
        return div().into_any_element();
    }
    fn on_loading() element_mod.AnyElement {
        loadings += 1;
        return div().into_any_element();
    }

    pub fn render(_: *RemoteImageView, _: *Window, _: *Context(RemoteImageView)) *Div {
        return div().w(px(100)).h(px(100)).child(img_mod.img(url).with_loading(on_loading).with_fallback(on_fallback));
    }
    fn build(_: *Window, app: *App) Entity(RemoteImageView) {
        return app.new(RemoteImageView{});
    }
    fn reset(new_url: []const u8) void {
        url = new_url;
        fallbacks = 0;
        loadings = 0;
    }
    fn wait(vcx: *VisualTestContext, cache: *assets_mod.AssetCache) assets_mod.ImageCacheError!*assets_mod.RenderImage {
        const resource: assets_mod.Resource = .{ .uri = url };
        for (0..1000) |_| {
            vcx.run_until_parked();
            const result = cache.load_resource(.empty, resource);
            if (result != error.Loading) {
                vcx.run_until_parked();
                return result;
            }
            @import("../executor.zig").sleep_ns(5 * std.time.ns_per_ms);
        }
        return error.Loading;
    }
};

/// A 1x1 PNG.
const tiny_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

/// A 2x1 PNG.
const wide_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a\x00\x00\x00\x0e\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x04\x01\x10\xf8\x03\xfd\x4e\x95\xc1\x6f\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

const FakeHttp = struct {
    var released: std.atomic.Value(bool) = .init(false);
    var served: std.atomic.Value(u32) = .init(0);
    var body: []const u8 = tiny_png;

    /// Answers `body` once released.
    fn gated(_: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, _: []const u8) anyerror![]u8 {
        while (!released.load(.acquire)) @import("../executor.zig").sleep_ns(std.time.ns_per_ms);
        defer _ = served.fetchAdd(1, .release);
        return allocator.dupe(u8, body);
    }

    /// Answers once the test has seen the loading state.
    fn ok(_: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, _: []const u8) anyerror![]u8 {
        while (!released.load(.acquire)) @import("../executor.zig").sleep_ns(std.time.ns_per_ms);
        return allocator.dupe(u8, tiny_png);
    }
    fn broken(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8) anyerror![]u8 {
        return error.ConnectionRefused;
    }
};

test "img: a URL shows the loading placeholder, then the image in a redrawn frame" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.asset_cache.fetch_config.?.http_client = .{ .get_fn = FakeHttp.ok };
    FakeHttp.released.store(false, .release);
    RemoteImageView.reset("https://example.test/a.png");
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    const first_frames = vcx.window.frame_count;
    try std.testing.expect(RemoteImageView.loadings > 0);
    FakeHttp.released.store(true, .release);
    const image = try RemoteImageView.wait(vcx, &cx.app.asset_cache);
    try std.testing.expectEqual(@as(i32, 1), image.size(0).width);
    try std.testing.expect(vcx.window.frame_count > first_frames);
    try std.testing.expectEqual(@as(usize, 0), RemoteImageView.fallbacks);
}

test "img: a failed URL shows the fallback and is not fetched again every frame" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.asset_cache.fetch_config.?.http_client = .{ .get_fn = FakeHttp.broken };
    RemoteImageView.reset("https://example.test/gone.png");
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    try std.testing.expectError(error.FetchFailed, RemoteImageView.wait(vcx, &cx.app.asset_cache));
    try std.testing.expect(RemoteImageView.fallbacks > 0);
}

const DiskCacheFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,

    fn init() !DiskCacheFixture {
        const tmp = std.testing.tmpDir(.{});
        return .{ .tmp = tmp, .dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path }) };
    }
    fn deinit(self: *DiskCacheFixture) void {
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
    /// Loads the URL once in a throwaway app, so its bytes end up on disk.
    fn seed(self: *DiskCacheFixture, png: []const u8) !void {
        var cx = TestAppContext.init();
        defer cx.deinit();
        cx.app.asset_cache.fetch_config.?.http_client = .{ .get_fn = FakeHttp.gated };
        cx.app.asset_cache.fetch_config.?.disk_cache = .{ .dir = self.dir };
        FakeHttp.body = png;
        FakeHttp.released.store(true, .release);
        _, const vcx = cx.add_window_view(RemoteImageView.build);
        _ = try RemoteImageView.wait(vcx, &cx.app.asset_cache);
    }
    fn wait_served(vcx: *VisualTestContext, count: u32) void {
        while (FakeHttp.served.load(.acquire) < count) @import("../executor.zig").sleep_ns(std.time.ns_per_ms);
        // Long enough for the task to publish after answering.
        @import("../executor.zig").sleep_ns(50 * std.time.ns_per_ms);
        vcx.run_until_parked();
    }
};

test "img: a URL seen before shows at once, before the network answers" {
    var disk = try DiskCacheFixture.init();
    defer disk.deinit();
    RemoteImageView.reset("https://example.test/saved.png");
    try disk.seed(tiny_png);

    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.asset_cache.fetch_config.?.http_client = .{ .get_fn = FakeHttp.gated };
    cx.app.asset_cache.fetch_config.?.disk_cache = .{ .dir = disk.dir };
    FakeHttp.released.store(false, .release);
    defer FakeHttp.released.store(true, .release);
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    const first = try RemoteImageView.wait(vcx, &cx.app.asset_cache);
    try std.testing.expectEqual(@as(i32, 1), first.size(0).width);

    // The same bytes come back: the image stays, and nothing is redrawn for it.
    FakeHttp.served.store(0, .release);
    const frames = vcx.window.frame_count;
    FakeHttp.released.store(true, .release);
    DiskCacheFixture.wait_served(vcx, 1);
    try std.testing.expectEqual(first, try cx.app.asset_cache.load_resource(.empty, .{ .uri = RemoteImageView.url }));
    try std.testing.expectEqual(frames, vcx.window.frame_count);
}

test "img: a saved copy is replaced when the URL's content changed" {
    var disk = try DiskCacheFixture.init();
    defer disk.deinit();
    RemoteImageView.reset("https://example.test/changes.png");
    try disk.seed(tiny_png);

    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.asset_cache.fetch_config.?.http_client = .{ .get_fn = FakeHttp.gated };
    cx.app.asset_cache.fetch_config.?.disk_cache = .{ .dir = disk.dir };
    FakeHttp.released.store(false, .release);
    defer FakeHttp.released.store(true, .release);
    FakeHttp.body = wide_png;
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    const first = try RemoteImageView.wait(vcx, &cx.app.asset_cache);
    try std.testing.expectEqual(@as(i32, 1), first.size(0).width);

    FakeHttp.served.store(0, .release);
    FakeHttp.released.store(true, .release);
    DiskCacheFixture.wait_served(vcx, 1);
    const second = try cx.app.asset_cache.load_resource(.empty, .{ .uri = RemoteImageView.url });
    try std.testing.expectEqual(@as(i32, 2), second.size(0).width);
}

test "img: a saved copy stays when the network fails" {
    var disk = try DiskCacheFixture.init();
    defer disk.deinit();
    RemoteImageView.reset("https://example.test/offline.png");
    try disk.seed(tiny_png);

    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.asset_cache.fetch_config.?.http_client = .{ .get_fn = FakeHttp.broken };
    cx.app.asset_cache.fetch_config.?.disk_cache = .{ .dir = disk.dir };
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    const first = try RemoteImageView.wait(vcx, &cx.app.asset_cache);
    @import("../executor.zig").sleep_ns(50 * std.time.ns_per_ms);
    vcx.run_until_parked();
    try std.testing.expectEqual(first, try cx.app.asset_cache.load_resource(.empty, .{ .uri = RemoteImageView.url }));
    try std.testing.expectEqual(@as(usize, 0), RemoteImageView.fallbacks);
}

/// Answers one HTTP request with a PNG, with a redirect first.
const LocalServer = struct {
    fn respond(server: *std.Io.net.Server, io: std.Io, reply: []const u8) !void {
        var stream = try server.accept(io);
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var seen: usize = 0;
        while (seen < 4) {
            const byte = try reader.interface.takeByte();
            seen = switch (byte) {
                '\r' => if (seen == 2) 3 else 1,
                '\n' => if (seen == 3) 4 else if (seen == 1) 2 else 0,
                else => 0,
            };
        }
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(reply);
        try writer.interface.flush();
    }

    fn serve(server: *std.Io.net.Server, io: std.Io, port: u16) void {
        var redirect_buffer: [256]u8 = undefined;
        const redirect = std.fmt.bufPrint(&redirect_buffer, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/real.png\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{port}) catch unreachable;
        respond(server, io, redirect) catch return;
        var reply_buffer: [512]u8 = undefined;
        const reply = std.fmt.bufPrint(&reply_buffer, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ tiny_png.len, tiny_png }) catch unreachable;
        respond(server, io, reply) catch return;
    }
};

test "img: the built-in client fetches over a real socket and follows a redirect" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, LocalServer.serve, .{ &server, io, port });
    defer thread.join();

    var cx = TestAppContext.init();
    defer cx.deinit();
    var url_buffer: [64]u8 = undefined;
    RemoteImageView.reset(try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/a.png", .{port}));
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    const image = try RemoteImageView.wait(vcx, &cx.app.asset_cache);
    try std.testing.expectEqual(@as(i32, 1), image.size(0).width);
}

test "img: quitting does not wait for a server that never answers" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    // Connections complete in the backlog and then nothing is ever read or sent.
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var cx = TestAppContext.init();
    var url_buffer: [64]u8 = undefined;
    RemoteImageView.reset(try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/a.png", .{server.socket.address.getPort()}));
    _, const vcx = cx.add_window_view(RemoteImageView.build);
    vcx.run_until_parked();
    @import("../executor.zig").sleep_ns(50 * std.time.ns_per_ms);
    const start = @import("../executor.zig").now_ns();
    cx.deinit();
    try std.testing.expect(@import("../executor.zig").now_ns() - start < 2 * std.time.ns_per_s);
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
    pressures: usize = 0,
    last_stage: interactive.PressureStage = .zero,

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
    fn on_pressure(self: *DragPage, e: *const interactive.MousePressureEvent, _: *Window, _: *Context(DragPage)) void {
        self.pressures += 1;
        self.last_stage = e.stage;
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
                .on_pinch(cx.listener(on_pinch))
                .on_mouse_pressure(cx.listener(on_pressure)),
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

const ResizeHandle = struct {
    fn make_preview(_: *const u8, _: Point(Pixels), _: *Window, app: *App) Entity(Empty) {
        return app.new(Empty{});
    }
    const Empty = struct {
        pub fn render(_: *Empty, _: *Window, _: *Context(Empty)) *Div {
            return div();
        }
    };
    pub fn render(_: *ResizeHandle, _: *Window, _: *Context(ResizeHandle)) *Div {
        const value: u8 = 0;
        return div().size_full().cursor_text().child(
            div().id("resize-handle").w(px(4)).h_full().cursor_col_resize().on_drag(value, make_preview),
        );
    }
    fn build(_: *Window, app: *App) Entity(ResizeHandle) {
        return app.new(ResizeHandle{});
    }
};

// GPUI `test_drag_cursor_applies_before_next_paint`.
test "drag: its cursor applies before the next paint, and ends with it" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(ResizeHandle.build);
    vcx.run_until_parked();
    const hp: *headless.HeadlessPlatform = @fieldParentPtr("platform", cx.platform);
    const window = vcx.window;
    const on_handle: Point(Pixels) = .{ .x = 1, .y = 10 };
    const away: Point(Pixels) = .{ .x = 20, .y = 10 };

    // Dispatched directly, because pumping would paint a frame and hide the bug.
    _ = window.dispatch_event(.{ .mouse_move = .{ .position = on_handle } }, cx.app);
    try std.testing.expectEqual(style_cursor.resize_column, hp.cursor);
    _ = window.dispatch_event(.{ .mouse_down = .{ .position = on_handle, .button = .left } }, cx.app);
    _ = window.dispatch_event(.{ .mouse_move = .{ .position = away, .pressed_button = .left } }, cx.app);
    try std.testing.expect(cx.app.has_active_drag());
    // The pointer is over the text area now, and the frame has not been painted again.
    try std.testing.expectEqual(style_cursor.resize_column, hp.cursor);

    vcx.run_until_parked();
    try std.testing.expectEqual(style_cursor.resize_column, hp.cursor);
    _ = window.dispatch_event(.{ .mouse_up = .{ .position = away, .button = .left } }, cx.app);
    vcx.run_until_parked();
    try std.testing.expect(!cx.app.has_active_drag());
    try std.testing.expectEqual(style_cursor.i_beam, hp.cursor);
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

test "pressure: reaches the element under the pointer with its stage" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(DragPage.build);
    vcx.simulate_mouse_move(.{ .x = 120, .y = 10 }, null, .{});
    vcx.simulate_event(.{ .mouse_pressure = .{ .position = .{ .x = 120, .y = 10 }, .pressure = 0.5, .stage = .normal } });
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).pressures);
    try std.testing.expectEqual(interactive.PressureStage.normal, view.read(cx.app).last_stage);
    vcx.simulate_mouse_move(.{ .x = 280, .y = 280 }, null, .{});
    vcx.simulate_event(.{ .mouse_pressure = .{ .position = .{ .x = 280, .y = 280 }, .pressure = 0.9, .stage = .force } });
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).pressures);
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
        @import("../executor.zig").sleep_ns(5 * std.time.ns_per_ms);
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
    @import("../executor.zig").sleep_ns(40 * std.time.ns_per_ms);
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
    @import("../executor.zig").sleep_ns(30 * std.time.ns_per_ms);
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

test "menus: set_menus stores copies that get_menus returns" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    try std.testing.expect(cx.app.get_menus() == null);
    const Toggle = action_mod.Action("test", "Toggle");
    var name: [4]u8 = "File".*;
    const items = [_]platform_mod.app_menu.MenuItem{
        platform_mod.app_menu.MenuItem.action("Toggle", Toggle{}).checked(true),
        platform_mod.app_menu.MenuItem.separator_item(),
    };
    cx.app.set_menus(&.{platform_mod.app_menu.Menu.new(&name).items(&items)});
    // The stored menus are copies: changing the caller's name does not change them.
    name[0] = 'X';
    const menus = cx.app.get_menus().?;
    try std.testing.expectEqualStrings("File", menus[0].name);
    try std.testing.expectEqual(@as(usize, 2), menus[0].items.len);
    try std.testing.expect(menus[0].items[0].action_item.checked);
}

test "notifications: a response from the platform reaches the registered handler" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Seen = struct {
        var tag: [16]u8 = undefined;
        var tag_len: usize = 0;
        var action: [16]u8 = undefined;
        var action_len: usize = 0;
        fn on_response(_: u8, response: platform_mod.SystemNotificationResponse, _: *App) void {
            @memcpy(tag[0..response.tag.len], response.tag);
            tag_len = response.tag.len;
            if (response.action_id) |id| {
                @memcpy(action[0..id.len], id);
                action_len = id.len;
            }
        }
    };
    cx.app.set_app_identity("dev.test", "Test");
    // Posting and dismissing are accepted on every platform; without a backend they do nothing.
    cx.app.show_system_notification(.{ .tag = "t", .title = "T", .body = "B", .actions = &.{.{ .id = "open", .label = "Open" }} });
    cx.app.dismiss_system_notification("t");
    cx.app.dispatch_system_notification_response(.{ .tag = "none" });
    cx.app.on_system_notification_response(@as(u8, 0), Seen.on_response);
    cx.app.dispatch_system_notification_response(.{ .tag = "t", .action_id = "open" });
    try std.testing.expectEqualStrings("t", Seen.tag[0..Seen.tag_len]);
    try std.testing.expectEqualStrings("open", Seen.action[0..Seen.action_len]);
}

/// A decoded image of one 1x1 frame per entry of `delays_ms` (a GIF has one such frame per picture).
fn image_with_delays(allocator: std.mem.Allocator, delays_ms: []const u32) !*assets_mod.RenderImage {
    const frames = try allocator.alloc(assets_mod.Frame, delays_ms.len);
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |f| allocator.free(f.pixels);
        allocator.free(frames);
    }
    while (built < delays_ms.len) : (built += 1) {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, @intCast(built + 1));
        frames[built] = .{ .width = 1, .height = 1, .delay_ms = delays_ms[built], .pixels = pixels };
    }
    return assets_mod.RenderImage.new(allocator, frames);
}

const AnimatedView = struct {
    var image: *assets_mod.RenderImage = undefined;
    var with_id: bool = true;
    var last: ?*img_mod.Img = null;

    pub fn render(_: *AnimatedView, _: *Window, _: *Context(AnimatedView)) *Div {
        const i = img_mod.img(image).size(px(10));
        last = if (with_id) i.id("gif") else i;
        return div().child(last.?);
    }
    fn build(_: *Window, app: *App) Entity(AnimatedView) {
        return app.new(AnimatedView{});
    }
    fn frame() usize {
        return last.?.ext.frame_index;
    }
};

/// Opens a window without pumping frames. `add_window` runs `run_until_parked`, which keeps drawing
/// while an animation asks for frames, so a GIF would advance before the test looked at it.
fn open_unpumped(cx: *TestAppContext) struct { window: *Window } {
    const handle = cx.app.open_window(.{}, AnimatedView.build) catch unreachable;
    const window = handle.window(cx.app) orelse unreachable;
    window.draw(cx.app);
    return .{ .window = window };
}

test "gif: frames advance after their delay, and frames are requested only while animating" {
    const allocator = std.testing.allocator;
    const sleep = @import("../executor.zig").sleep_ns;
    var cx = TestAppContext.init();
    defer cx.deinit();

    // Each frame lasts 150 ms, so the first draws happen well inside its delay.
    const animated = try image_with_delays(allocator, &.{ 150, 150 });
    defer animated.deinit();
    AnimatedView.image = animated;

    AnimatedView.with_id = true;
    const vcx = open_unpumped(&cx);
    try std.testing.expectEqual(@as(usize, 0), AnimatedView.frame());
    try std.testing.expect(vcx.window.animation_requested);
    vcx.window.draw(cx.app);
    try std.testing.expectEqual(@as(usize, 0), AnimatedView.frame());

    sleep(200 * std.time.ns_per_ms);
    vcx.window.draw(cx.app);
    try std.testing.expectEqual(@as(usize, 1), AnimatedView.frame());
    try std.testing.expect(vcx.window.animation_requested);

    sleep(200 * std.time.ns_per_ms);
    vcx.window.draw(cx.app);
    try std.testing.expectEqual(@as(usize, 0), AnimatedView.frame());

    // Without an element id there is no state to advance: frame 0 forever, and no frame requests.
    AnimatedView.with_id = false;
    const anonymous = open_unpumped(&cx);
    try std.testing.expect(!anonymous.window.animation_requested);
    sleep(200 * std.time.ns_per_ms);
    anonymous.window.draw(cx.app);
    try std.testing.expectEqual(@as(usize, 0), AnimatedView.frame());
    try std.testing.expect(!anonymous.window.animation_requested);

    // A single-frame image never animates, even with an id.
    AnimatedView.with_id = true;
    const single = try image_with_delays(allocator, &.{150});
    defer single.deinit();
    AnimatedView.image = single;
    const still = open_unpumped(&cx);
    try std.testing.expect(!still.window.animation_requested);

    // Reduced motion holds the current frame and asks for nothing.
    cx.app.set_reduce_motion(true);
    AnimatedView.image = animated;
    const reduced = open_unpumped(&cx);
    sleep(200 * std.time.ns_per_ms);
    reduced.window.draw(cx.app);
    try std.testing.expect(!reduced.window.animation_requested);
    try std.testing.expectEqual(@as(usize, 0), AnimatedView.frame());
    cx.app.set_reduce_motion(false);

    // A window that is not active holds its frame too.
    reduced.window.active = false;
    reduced.window.draw(cx.app);
    try std.testing.expect(!reduced.window.animation_requested);
}

// ---------------------------------------------------------------------------
// Prompts (GPUI `window/prompts.rs`) and window observers.

/// Where the last answer went, and how often. Listeners are plain functions, so the tests share
/// these; tests run one after another.
const PromptProbe = struct {
    var answered: ?usize = null;
    var calls: usize = 0;
    var other_calls: usize = 0;
    var builder_calls: usize = 0;

    fn reset() void {
        answered = null;
        calls = 0;
        other_calls = 0;
        builder_calls = 0;
    }

    fn on_answer(response: *const window_mod.PromptResponse, _: *Window, _: *App) void {
        answered = response.index;
        calls += 1;
    }

    fn on_other_answer(_: *const window_mod.PromptResponse, _: *Window, _: *App) void {
        other_calls += 1;
    }

    fn counting_builder(
        level: window_mod.PromptLevel,
        message: []const u8,
        detail: ?[]const u8,
        answers: []const window_mod.PromptButton,
        handle: window_mod.PromptHandle,
        window: *Window,
        app: *App,
    ) window_mod.RenderablePromptHandle {
        builder_calls += 1;
        return window_mod.fallback_prompt_renderer(level, message, detail, answers, handle, window, app);
    }
};

/// Two areas that open prompts: the first has a cancel button, the second has none.
const PromptHost = struct {
    focus: window_mod.FocusHandle,

    pub fn render(self: *PromptHost, _: *Window, cx: *Context(PromptHost)) *Div {
        return div()
            .flex()
            .flex_col()
            .size_full()
            .child(div()
                .id("open")
                .track_focus(&self.focus)
                .w(px(100))
                .h(px(40))
                .on_click(cx.listener(open_with_cancel)))
            .child(div()
                .id("open-plain")
                .w(px(100))
                .h(px(40))
                .on_click(cx.listener(open_without_cancel)));
    }

    fn open_with_cancel(_: *PromptHost, _: *const ClickEvent, window: *Window, cx: *Context(PromptHost)) void {
        window.prompt(.info, "Are you sure?", null, &.{ "OK", "Cancel" }, cx.app, PromptProbe.on_answer);
    }

    fn open_without_cancel(_: *PromptHost, _: *const ClickEvent, window: *Window, cx: *Context(PromptHost)) void {
        window.prompt(.warning, "Keep going?", "Nothing to cancel here.", &.{ "Yes", "No" }, cx.app, PromptProbe.on_answer);
    }

    fn build(_: *Window, app: *App) Entity(PromptHost) {
        return app.new(PromptHost{ .focus = app.focus_handle() });
    }

    fn read_focus(self: *const PromptHost, _: *const App) window_mod.FocusHandle {
        return self.focus;
    }
};

/// The centres of the two prompt buttons. They are the last hitboxes a frame draws, since the
/// prompt is prepainted after the root view.
fn prompt_button_centers(window: *Window) [2]Point(Pixels) {
    const boxes = window.rendered_frame.hitboxes.items;
    std.debug.assert(boxes.len >= 2);
    return .{ center_of(boxes[boxes.len - 2].bounds), center_of(boxes[boxes.len - 1].bounds) };
}

fn center_of(b: geometry.Bounds(Pixels)) Point(Pixels) {
    return .{ .x = b.origin.x + b.size.width / 2, .y = b.origin.y + b.size.height / 2 };
}

test "prompt: a click answers with the button's index, closes the prompt and gives focus back" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(PromptHost.build);
    const focus = view.read(cx.app).focus;
    vcx.focus(focus);

    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expect(vcx.window.has_active_prompt());
    try std.testing.expect(!focus.is_focused(vcx.window));
    try std.testing.expectEqual(@as(?usize, null), PromptProbe.answered);

    const buttons = prompt_button_centers(vcx.window);
    vcx.simulate_click(buttons[1], .{});
    try std.testing.expectEqual(@as(?usize, 1), PromptProbe.answered);
    try std.testing.expectEqual(@as(usize, 1), PromptProbe.calls);
    try std.testing.expect(!vcx.window.has_active_prompt());
    try std.testing.expect(focus.is_focused(vcx.window));
}

test "prompt: the first button is index 0, and an answer is delivered once" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    const buttons = prompt_button_centers(vcx.window);
    vcx.simulate_click(buttons[0], .{});
    try std.testing.expectEqual(@as(?usize, 0), PromptProbe.answered);
    // The prompt is gone, so a second click on the same spot answers nothing.
    vcx.simulate_click(buttons[0], .{});
    try std.testing.expectEqual(@as(usize, 1), PromptProbe.calls);
}

test "prompt: the keyboard moves the selection with right and enter chooses it" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(PromptHost.build);
    vcx.focus(view.read(cx.app).focus);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expect(vcx.window.has_active_prompt());

    vcx.simulate_keystrokes("right enter");
    try std.testing.expectEqual(@as(?usize, 1), PromptProbe.answered);
    try std.testing.expect(!vcx.window.has_active_prompt());
}

test "prompt: enter alone chooses the first button, and left wraps to the last" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.simulate_keystrokes("left enter");
    try std.testing.expectEqual(@as(?usize, 1), PromptProbe.answered);
}

test "prompt: escape chooses the cancel button" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.simulate_keystrokes("escape");
    try std.testing.expectEqual(@as(?usize, 1), PromptProbe.answered);
    try std.testing.expect(!vcx.window.has_active_prompt());
}

test "prompt: escape without a cancel button leaves the prompt open" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 50 }, .{});
    try std.testing.expect(vcx.window.has_active_prompt());
    vcx.simulate_keystrokes("escape");
    try std.testing.expectEqual(@as(?usize, null), PromptProbe.answered);
    try std.testing.expect(vcx.window.has_active_prompt());
    // Enter still answers, with the first button.
    vcx.simulate_keystrokes("enter");
    try std.testing.expectEqual(@as(?usize, 0), PromptProbe.answered);
}

fn replace_prompt(window: *Window, app: *App) void {
    window.prompt(.critical, "Second", null, &.{ "Only", "Me" }, app, PromptProbe.on_other_answer);
}

test "prompt: a prompt replaced before its answer is never answered" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    vcx.update(replace_prompt, .{});
    vcx.run_until_parked();
    vcx.simulate_click(prompt_button_centers(vcx.window)[0], .{});
    try std.testing.expectEqual(@as(usize, 0), PromptProbe.calls);
    try std.testing.expectEqual(@as(usize, 1), PromptProbe.other_calls);
}

fn close_window_now(window: *Window, app: *App) void {
    app.close_window(window);
}

test "prompt: closing the window with a prompt open frees everything it held" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expect(vcx.window.has_active_prompt());
    // std.testing.allocator reports any arena left behind when the test ends.
    vcx.update(close_window_now, .{});
    try std.testing.expectEqual(@as(usize, 0), PromptProbe.calls);
}

test "prompt: a custom builder replaces the fallback, and the window still delivers the answer" {
    PromptProbe.reset();
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.set_prompt_builder(PromptProbe.counting_builder);
    defer cx.app.reset_prompt_builder();
    _, const vcx = cx.add_window_view(PromptHost.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expectEqual(@as(usize, 1), PromptProbe.builder_calls);
    vcx.simulate_click(prompt_button_centers(vcx.window)[0], .{});
    try std.testing.expectEqual(@as(?usize, 0), PromptProbe.answered);
}

/// Counts what a view hears about its window (GPUI `cx.observe_window_bounds` and
/// `cx.observe_window_activation`).
const BoundsWatch = struct {
    changes: usize = 0,
    activations: usize = 0,

    pub fn render(_: *BoundsWatch, _: *Window, _: *Context(BoundsWatch)) *Div {
        return div().size_full();
    }

    fn watch(_: *BoundsWatch, window: *Window, cx: *Context(BoundsWatch)) void {
        _ = cx.observe_window_bounds(window, on_bounds);
        _ = cx.observe_window_activation(window, on_activation);
    }

    fn on_bounds(self: *BoundsWatch, _: *Window, _: *Context(BoundsWatch)) void {
        self.changes += 1;
    }

    fn on_activation(self: *BoundsWatch, _: *Window, _: *Context(BoundsWatch)) void {
        self.activations += 1;
    }

    fn build(window: *Window, app: *App) Entity(BoundsWatch) {
        const view = app.new(BoundsWatch{});
        view.update(app, BoundsWatch.watch, .{window});
        return view;
    }

    fn read_changes(s: *const BoundsWatch, _: *const App) usize {
        return s.changes;
    }

    fn read_activations(s: *const BoundsWatch, _: *const App) usize {
        return s.activations;
    }
};

test "window bounds: a resize calls the observer, and a resize to the same size does not" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(BoundsWatch.build);
    try std.testing.expectEqual(@as(usize, 0), cx.read_entity(view, BoundsWatch.read_changes, .{}));

    vcx.simulate_resize(.{ .width = 320, .height = 240 });
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, BoundsWatch.read_changes, .{}));

    // Nothing changed, so the observer stays quiet, even though the platform reported a resize.
    vcx.simulate_resize(.{ .width = 320, .height = 240 });
    vcx.simulate_mouse_move(.{ .x = 5, .y = 5 }, null, .{});
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, BoundsWatch.read_changes, .{}));
}

const WindowMoves = struct {
    var moves: usize = 0;
    var last: geometry.Point(Pixels) = .{ .x = -1, .y = -1 };

    fn on_move(window: *Window, _: *App) void {
        moves += 1;
        last = window.bounds().origin;
    }
};

test "window bounds: a move reaches window observers with the new origin, and a repeat does not" {
    WindowMoves.moves = 0;
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(BoundsWatch.build);
    const subscription = vcx.window.observe_window_bounds(WindowMoves.on_move);
    defer subscription.unsubscribe();

    vcx.simulate_move(.{ .x = 40, .y = 25 });
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, BoundsWatch.read_changes, .{}));
    try std.testing.expectEqual(@as(usize, 1), WindowMoves.moves);
    try std.testing.expectEqual(@as(Pixels, 40), WindowMoves.last.x);
    try std.testing.expectEqual(@as(Pixels, 25), WindowMoves.last.y);

    // The same origin again is not a change.
    vcx.simulate_move(.{ .x = 40, .y = 25 });
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, BoundsWatch.read_changes, .{}));
    try std.testing.expectEqual(@as(usize, 1), WindowMoves.moves);

    // A move and then a resize are two changes; the window observer hears both.
    vcx.simulate_move(.{ .x = 1, .y = 1 });
    vcx.simulate_resize(.{ .width = 300, .height = 300 });
    try std.testing.expectEqual(@as(usize, 3), cx.read_entity(view, BoundsWatch.read_changes, .{}));
    try std.testing.expectEqual(@as(usize, 3), WindowMoves.moves);
}

test "window activation: observers hear each change, and a resize is not one" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(BoundsWatch.build);
    try std.testing.expectEqual(@as(usize, 0), cx.read_entity(view, BoundsWatch.read_activations, .{}));

    vcx.window.platform_window.emit_active(false);
    vcx.window.platform_window.emit_active(true);
    try std.testing.expectEqual(@as(usize, 2), cx.read_entity(view, BoundsWatch.read_activations, .{}));
    try std.testing.expect(vcx.window.is_window_active());

    vcx.simulate_resize(.{ .width = 320, .height = 240 });
    try std.testing.expectEqual(@as(usize, 2), cx.read_entity(view, BoundsWatch.read_activations, .{}));
}

// -- asset loads and image caches ----------------------------------------

const asset_cache_mod = @import("../asset_cache.zig");
const image_cache_mod = @import("../image_cache.zig");
const executor_mod = @import("../executor.zig");

/// An asset whose load waits for `gate`, then answers `source * 10`. Counts its starts.
const Slow = struct {
    pub const Source = u32;
    pub const Output = u32;
    var starts: std.atomic.Value(u32) = .init(0);
    var gate: std.atomic.Value(bool) = .init(false);

    pub fn load(source: Source, cx: *asset_cache_mod.LoadContext) Output {
        _ = starts.fetchAdd(1, .acq_rel);
        while (!gate.load(.acquire)) {
            if (cx.is_cancelled()) return 0;
            executor_mod.sleep_ns(std.time.ns_per_ms);
        }
        return source * 10;
    }

    fn reset(open: bool) void {
        starts.store(0, .release);
        gate.store(open, .release);
    }

    /// Loads run on workers, which may not have got to one yet when a frame has asked for it.
    fn wait_for_starts(count: u32) !void {
        for (0..5000) |_| {
            if (starts.load(.acquire) >= count) break;
            executor_mod.sleep_ns(std.time.ns_per_ms);
        }
        try std.testing.expectEqual(count, starts.load(.acquire));
    }
};

/// An asset whose load always fails.
const Broken = struct {
    pub const Source = u32;
    pub const Output = anyerror!u32;

    pub fn load(_: Source, _: *asset_cache_mod.LoadContext) Output {
        return error.LoadFailed;
    }
};

const SlowView = struct {
    var source: u32 = 1;
    var seen: ?u32 = null;
    var renders: usize = 0;

    pub fn render(_: *SlowView, window: *Window, cx: *Context(SlowView)) *Div {
        renders += 1;
        seen = window.use_asset(Slow, source, cx.app);
        return div();
    }
    fn build(_: *Window, app: *App) Entity(SlowView) {
        return app.new(SlowView{});
    }
    fn reset(s: u32) void {
        source = s;
        seen = null;
        renders = 0;
    }
};

const BrokenView = struct {
    var seen: ?anyerror!u32 = null;

    pub fn render(_: *BrokenView, window: *Window, cx: *Context(BrokenView)) *Div {
        seen = window.use_asset(Broken, 1, cx.app);
        return div();
    }
    fn build(_: *Window, app: *App) Entity(BrokenView) {
        return app.new(BrokenView{});
    }
};

/// Runs the app until `done` holds, for at most about five seconds.
fn pump_until(vcx: *VisualTestContext, done: *const fn () bool) !void {
    for (0..1000) |_| {
        vcx.run_until_parked();
        if (done()) return;
        executor_mod.sleep_ns(5 * std.time.ns_per_ms);
    }
    return error.TimedOut;
}

fn slow_view_has_value() bool {
    return SlowView.seen != null;
}

fn broken_view_has_value() bool {
    return BrokenView.seen != null;
}

test "use_asset: none while loading, then the value once the window redraws" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    Slow.reset(false);
    SlowView.reset(4);
    _, const vcx = cx.add_window_view(SlowView.build);
    try std.testing.expectEqual(@as(?u32, null), SlowView.seen);
    try Slow.wait_for_starts(1);

    Slow.gate.store(true, .release);
    try pump_until(vcx, slow_view_has_value);
    try std.testing.expectEqual(@as(?u32, 40), SlowView.seen);
}

test "use_asset: a load runs once per source, even across frames" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    Slow.reset(false);
    SlowView.reset(7);
    _, const vcx = cx.add_window_view(SlowView.build);
    for (0..5) |_| {
        vcx.window.refresh();
        vcx.run_until_parked();
    }
    try std.testing.expect(SlowView.renders >= 5);
    try std.testing.expectEqual(@as(u32, 1), Slow.starts.load(.acquire));

    Slow.gate.store(true, .release);
    try pump_until(vcx, slow_view_has_value);
    try std.testing.expectEqual(@as(?u32, 70), SlowView.seen);
    try std.testing.expectEqual(@as(u32, 1), Slow.starts.load(.acquire));
}

test "remove_asset: the next use loads again, and an abandoned load is dropped" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    Slow.reset(true);
    SlowView.reset(2);
    _, const vcx = cx.add_window_view(SlowView.build);
    try pump_until(vcx, slow_view_has_value);
    try std.testing.expectEqual(@as(?u32, 20), SlowView.seen);

    // Close the gate, drop the entry, and render again: a new load starts and has no value yet.
    Slow.gate.store(false, .release);
    cx.app.remove_asset(Slow, 2);
    try std.testing.expect(!cx.app.has_asset(Slow, 2));
    vcx.window.refresh();
    vcx.run_until_parked();
    try Slow.wait_for_starts(2);
    try std.testing.expectEqual(@as(?u32, null), SlowView.seen);

    // Abandon that second load while it runs; its result must not come back into the cache.
    cx.app.remove_asset(Slow, 2);
    Slow.gate.store(true, .release);
    vcx.window.refresh();
    try pump_until(vcx, slow_view_has_value);
    try std.testing.expectEqual(@as(?u32, 20), SlowView.seen);
    try std.testing.expectEqual(@as(u32, 3), Slow.starts.load(.acquire));
}

test "use_asset: a failing load is reported as a failure" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    BrokenView.seen = null;
    _, const vcx = cx.add_window_view(BrokenView.build);
    try pump_until(vcx, broken_view_has_value);
    try std.testing.expectError(error.LoadFailed, BrokenView.seen.?);
}

/// Serves one embedded image, `pixel.png`, and counts how often it is asked for.
const PixelAssets = struct {
    var loads: std.atomic.Value(u32) = .init(0);

    pub fn load(_: *PixelAssets, path: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, path, "pixel.png")) return null;
        _ = loads.fetchAdd(1, .acq_rel);
        return tiny_png;
    }
};

fn wait_for_image(cache: *image_cache_mod.RetainAllImageCache, vcx: *VisualTestContext, resource: assets_mod.Resource) !*assets_mod.RenderImage {
    for (0..1000) |_| {
        vcx.run_until_parked();
        if (cache.load(resource, vcx.window, vcx.cx.app)) |result| {
            vcx.run_until_parked();
            return result;
        }
        executor_mod.sleep_ns(5 * std.time.ns_per_ms);
    }
    return error.TimedOut;
}

test "RetainAllImageCache: keeps each image, and releases them when cleared" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    var pixels: PixelAssets = .{};
    cx.app.asset_source = assets_mod.AssetSource.from(&pixels);
    _, const vcx = cx.add_window_view(SlowView.build);

    const cache_handle = image_cache_mod.RetainAllImageCache.new(cx.app);
    const cache = cache_handle.as_mut(cx.app);
    const resource: assets_mod.Resource = .{ .embedded = "pixel.png" };
    try std.testing.expectEqual(@as(?image_cache_mod.ImageResult, null), cache.load(resource, vcx.window, cx.app));

    const first = try wait_for_image(cache, vcx, resource);
    try std.testing.expectEqual(@as(usize, 1), cache.len());
    const again = (cache.load(resource, vcx.window, cx.app).?) catch unreachable;
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(u32, 1), PixelAssets.loads.load(.acquire));

    // Clearing frees the load: one live entry fewer, not just an empty table.
    const live_before = cx.app.asset_loads.live.count();
    cache.clear(cx.app);
    try std.testing.expect(cache.is_empty());
    try std.testing.expectEqual(live_before - 1, cx.app.asset_loads.live.count());
    // The next load starts over and decodes again.
    _ = try wait_for_image(cache, vcx, resource);
    try std.testing.expectEqual(@as(u32, 2), PixelAssets.loads.load(.acquire));
    cache_handle.release(cx.app);
}

test "RetainAllImageCache: released with its entity, even while an image loads" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    var pixels: PixelAssets = .{};
    cx.app.asset_source = assets_mod.AssetSource.from(&pixels);
    _, const vcx = cx.add_window_view(SlowView.build);

    const cache_handle = image_cache_mod.RetainAllImageCache.new(cx.app);
    const cache = cache_handle.as_mut(cx.app);
    const resource: assets_mod.Resource = .{ .embedded = "pixel.png" };
    _ = cache.load(resource, vcx.window, cx.app);
    // Release while the worker may still be decoding: the late image must be freed, not kept.
    // The testing allocator reports it if it is not.
    cache_handle.release(cx.app);
    vcx.run_until_parked();
    executor_mod.sleep_ns(50 * std.time.ns_per_ms);
    vcx.run_until_parked();
}

/// An `img` inside `image_cache(...)`: the image loads through that cache, not the app's own.
const CachedImageView = struct {
    var loadings: usize = 0;
    var fallbacks: usize = 0;

    cache: Entity(image_cache_mod.RetainAllImageCache),

    pub fn render(self: *CachedImageView, _: *Window, _: *Context(CachedImageView)) *Div {
        return div().child(image_cache_mod.image_cache(self.cache).child(img_mod.img("pixel.png").with_loading(on_loading).with_fallback(on_fallback)));
    }
    fn on_loading() element_mod.AnyElement {
        loadings += 1;
        return div().into_any_element();
    }
    fn on_fallback() element_mod.AnyElement {
        fallbacks += 1;
        return div().into_any_element();
    }
    fn build(_: *Window, app: *App) Entity(CachedImageView) {
        return app.new(CachedImageView{ .cache = image_cache_mod.RetainAllImageCache.new(app) });
    }
};

test "img: an image in image_cache() loads through that cache, then redraws" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    var pixels: PixelAssets = .{};
    cx.app.asset_source = assets_mod.AssetSource.from(&pixels);
    const view, const vcx = cx.add_window_view(CachedImageView.build);
    try std.testing.expect(CachedImageView.loadings > 0);

    const cache = view.read(cx.app).cache.as_mut(cx.app);
    // The image arrives in the cache, which is what the img asked for.
    for (0..1000) |_| {
        vcx.run_until_parked();
        if (cache.len() == 1) {
            var items = cache.items.valueIterator();
            const item = items.next().?.*;
            if (item.get()) |result| {
                const image = try result;
                try std.testing.expectEqual(@as(i32, 1), image.size(0).width);
                break;
            }
        }
        executor_mod.sleep_ns(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), cache.len());
    try std.testing.expectEqual(@as(usize, 0), CachedImageView.fallbacks);
    // The app's own cache was not used for it.
    try std.testing.expectEqual(@as(usize, 0), cx.app.asset_cache.images.count());
}

test "keymap: highest_precedence_binding_for_action is the newest binding that wins in the focus context" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{
        KeyBinding.new("cmd-s", Editor.Save{}, "Editor"),
        KeyBinding.new("cmd-t", Editor.Save{}, "Editor"),
    });
    _, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    const found = vcx.window.highest_precedence_binding_for_action(Editor.Save{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("t", found.keystrokes[0].key);
}

test "keymap: a NoAction on a newer binding shadows it, so the older one is the highest precedence" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const NoAction = action_mod.NoAction;
    cx.app.bind_keys(&.{
        KeyBinding.new("cmd-s", Editor.Save{}, "Editor"),
        KeyBinding.new("cmd-t", Editor.Save{}, "Editor"),
        KeyBinding.new("cmd-t", NoAction{}, "Editor"),
    });
    _, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    const found = vcx.window.highest_precedence_binding_for_action(Editor.Save{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("s", found.keystrokes[0].key);
}

test "keymap: an action whose keys a newer, different action takes has no highest precedence" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    // Both actions are zero-sized, so only the action type tells them apart.
    cx.app.bind_keys(&.{
        KeyBinding.new("cmd-s", Editor.Save{}, "Editor"),
        KeyBinding.new("cmd-s", Editor.Outside{}, "Editor"),
    });
    _, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expect(vcx.window.highest_precedence_binding_for_action(Editor.Save{}) == null);
    const found = vcx.window.highest_precedence_binding_for_action(Editor.Outside{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("s", found.keystrokes[0].key);
}

test "keymap: highest_precedence_binding_for_action is null when the context or the binding is missing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.bind_keys(&.{KeyBinding.new("cmd-s", Editor.Save{}, "Terminal")});
    _, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expect(vcx.window.highest_precedence_binding_for_action(Editor.Save{}) == null);
    try std.testing.expect(vcx.window.highest_precedence_binding_for_action(Editor.Outside{}) == null);
}

test "actions: available_actions lists the actions on the focus path that the registry builds" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    try std.testing.expectEqual(@as(usize, 0), vcx.window.available_actions(cx.app).len);
    try cx.app.actions.register(Editor.Save);
    const available = vcx.window.available_actions(cx.app);
    try std.testing.expectEqual(@as(usize, 1), available.len);
    try std.testing.expectEqualStrings("test::Save", available[0].name);
}

test "window: capslock follows modifier events, and client inset and pointer capture read back" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(Editor.build);
    try std.testing.expect(!vcx.window.capslock().on);
    _ = vcx.window.dispatch_event(.{ .modifiers_changed = .{ .capslock = .{ .on = true } } }, cx.app);
    try std.testing.expect(vcx.window.capslock().on);
    _ = vcx.window.dispatch_event(.{ .modifiers_changed = .{ .capslock = .{ .on = false } } }, cx.app);
    try std.testing.expect(!vcx.window.capslock().on);

    try std.testing.expect(vcx.window.client_inset() == null);
    vcx.window.set_client_inset(12);
    try std.testing.expectEqual(@as(?Pixels, 12), vcx.window.client_inset());

    try std.testing.expect(vcx.window.captured_hitbox() == null);
    vcx.window.capture_pointer(42);
    try std.testing.expectEqual(@as(?u64, 42), vcx.window.captured_hitbox());
    vcx.window.release_pointer();
    try std.testing.expect(vcx.window.captured_hitbox() == null);
}

test "focus: a weak handle upgrades only while its element is rendered" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Editor.build);
    vcx.simulate_click(.{ .x = 10, .y = 10 }, .{});
    const handle = view.read(cx.app).focus;
    const weak = handle.downgrade();
    try std.testing.expect(weak.upgrade(vcx.window) != null);
    try std.testing.expect((window_mod.WeakFocusHandle{ .id = handle.id +% 1000 }).upgrade(vcx.window) == null);
}

test "focus: a ManagedView needs focus_handle and render" {
    const Popover = struct {
        pub fn focus_handle(_: *const @This()) void {}
        pub fn render(_: *@This()) void {}
    };
    comptime window_mod.assert_managed_view(Popover);
    try std.testing.expect(window_mod.is_managed_view(Popover));
    try std.testing.expect(!window_mod.is_managed_view(u8));
}

/// A text view with every optional `EntityInputHandler` method, so each one can be seen reaching it.
const RichField = struct {
    focus: FocusHandle,
    buffer: [64]u8 = @splat(0),
    len: usize = 0,
    selection: platform_mod.Range = .{ .start = 0, .end = 0 },
    pasted: usize = 0,
    rect: geometry.Bounds(Pixels) = undefined,

    pub fn render(self: *RichField, _: *Window, _: *Context(RichField)) *Div {
        return div().id("rich").w(px(100)).h(px(30)).track_focus(&self.focus);
    }
    pub fn text_for_range(self: *RichField, range: platform_mod.Range, _: *?platform_mod.Range, _: *Window, _: *Context(RichField)) ?[]const u8 {
        return self.buffer[range.start..range.end];
    }
    pub fn selected_text_range(self: *RichField, _: bool, _: *Window, _: *Context(RichField)) ?platform_mod.UTF16Selection {
        return .{ .range = self.selection, .reversed = false };
    }
    pub fn marked_text_range(_: *RichField, _: *Window, _: *Context(RichField)) ?platform_mod.Range {
        return null;
    }
    pub fn unmark_text(_: *RichField, _: *Window, _: *Context(RichField)) void {}
    pub fn replace_text_in_range(self: *RichField, _: ?platform_mod.Range, text: []const u8, _: *Window, _: *Context(RichField)) void {
        const n = @min(text.len, self.buffer.len - self.len);
        @memcpy(self.buffer[self.len..][0..n], text[0..n]);
        self.len += n;
        self.selection = .{ .start = self.len, .end = self.len };
    }
    pub fn replace_and_mark_text_in_range(_: *RichField, _: ?platform_mod.Range, _: []const u8, _: ?platform_mod.Range, _: *Window, _: *Context(RichField)) void {}
    pub fn bounds_for_range(_: *RichField, _: platform_mod.Range, element_bounds: geometry.Bounds(Pixels), _: *Window, _: *Context(RichField)) ?geometry.Bounds(Pixels) {
        return element_bounds;
    }
    pub fn character_index_for_point(_: *RichField, _: Point(Pixels), _: *Window, _: *Context(RichField)) ?usize {
        return null;
    }
    pub fn paste(self: *RichField, item: platform_mod.ClipboardItem, window: *Window, cx: *Context(RichField)) void {
        self.pasted += 1;
        if (item.text()) |text| self.replace_text_in_range(null, text, window, cx);
    }
    /// One rectangle per selected character, ten pixels wide, starting at the character's offset.
    pub fn selection_bounds_for_range(self: *RichField, range: platform_mod.Range, element_bounds: geometry.Bounds(Pixels), _: *Window, _: *Context(RichField)) []const geometry.Bounds(Pixels) {
        self.rect = .{
            .origin = .{ .x = element_bounds.origin.x + @as(Pixels, @floatFromInt(range.start)) * 10, .y = element_bounds.origin.y },
            .size = .{ .width = @as(Pixels, @floatFromInt(range.end - range.start)) * 10, .height = element_bounds.size.height },
        };
        return (&self.rect)[0..1];
    }
    pub fn set_selected_text_range(self: *RichField, range: platform_mod.Range, _: *Window, _: *Context(RichField)) void {
        self.selection = range;
    }
    pub fn text_length_utf16(self: *RichField, _: *Window, _: *Context(RichField)) ?usize {
        return self.len;
    }
    pub fn text_input_configuration(_: *RichField, _: *Window, _: *Context(RichField)) platform_mod.TextInputConfiguration {
        return .{ .input_action = .search };
    }
    pub fn text_input_editable_range(self: *RichField, _: *Window, _: *Context(RichField)) ?platform_mod.Range {
        return .{ .start = 0, .end = self.len };
    }
    fn build(_: *Window, app: *App) Entity(RichField) {
        return app.new(RichField{ .focus = app.focus_handle() });
    }
    fn read_text(s: *const RichField, _: *const App) []const u8 {
        return s.buffer[0..s.len];
    }
    fn pasted_count(s: *const RichField, _: *const App) usize {
        return s.pasted;
    }
};

test "input: paste, selection, length and configuration reach the view's own methods" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(RichField.build);
    vcx.run_until_parked();
    const bounds: geometry.Bounds(Pixels) = .{ .origin = .{ .x = 5, .y = 6 }, .size = .{ .width = 100, .height = 20 } };
    var handler = input_mod.ElementInputHandler(RichField).new(bounds, view).platform_input_handler();

    handler.paste(platform_mod.ClipboardItem.new_string("abcd"), vcx.window, cx.app);
    try std.testing.expectEqual(@as(usize, 1), cx.read_entity(view, RichField.pasted_count, .{}));
    try std.testing.expectEqualStrings("abcd", cx.read_entity(view, RichField.read_text, .{}));
    try std.testing.expectEqual(@as(?usize, 4), handler.text_length_utf16(vcx.window, cx.app));

    handler.set_selected_text_range(.{ .start = 1, .end = 3 }, vcx.window, cx.app);
    const selection = handler.selected_text_range(true, vcx.window, cx.app).?;
    try std.testing.expectEqual(@as(usize, 1), selection.range.start);
    try std.testing.expectEqual(@as(usize, 3), selection.range.end);

    const rects = handler.selection_bounds_for_range(.{ .start = 1, .end = 3 }, bounds, vcx.window, cx.app);
    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(@as(Pixels, 15), rects[0].origin.x);
    try std.testing.expectEqual(@as(Pixels, 20), rects[0].size.width);

    try std.testing.expectEqual(platform_mod.TextInputAction.search, handler.text_input_configuration(vcx.window, cx.app).input_action);
    const editable = handler.text_input_editable_range(vcx.window, cx.app).?;
    try std.testing.expectEqual(@as(usize, 4), editable.end);
}

test "input: a view without the optional methods gets GPUI's defaults" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ImeField.build);
    vcx.run_until_parked();
    const bounds: geometry.Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 20 } };
    var handler = input_mod.ElementInputHandler(ImeField).new(bounds, view).platform_input_handler();

    // The default paste replaces the range with the clipboard text.
    handler.paste(platform_mod.ClipboardItem.new_string("abc"), vcx.window, cx.app);
    try std.testing.expectEqualStrings("abc", cx.read_entity(view, ImeField.read_text, .{}));
    try std.testing.expect(handler.text_length_utf16(vcx.window, cx.app) == null);
    try std.testing.expectEqual(@as(usize, 0), handler.selection_bounds_for_range(.{ .start = 0, .end = 1 }, bounds, vcx.window, cx.app).len);
    try std.testing.expect(handler.text_input_editable_range(vcx.window, cx.app) == null);
    handler.set_selected_text_range(.{ .start = 0, .end = 1 }, vcx.window, cx.app);
    try std.testing.expectEqual(platform_mod.TextInputAction.unspecified, handler.text_input_configuration(vcx.window, cx.app).input_action);
}

// ---------------------------------------------------------------------------
// Context (GPUI `app/context.rs`): observers, releases, globals, deferred work,
// focus listeners, quit hooks, and the async contexts that go with them.

/// An entity that observes itself and can be told to stop.
const SelfWatch = struct {
    value: usize = 0,
    self_seen: usize = 0,
    sub: ?app_mod.Subscription = null,

    fn watch(self: *SelfWatch, cx: *Context(SelfWatch)) void {
        self.sub = cx.observe_self(on_change);
    }
    fn on_change(self: *SelfWatch, _: *Context(SelfWatch)) void {
        self.self_seen += 1;
    }
    fn stop(self: *SelfWatch, _: *Context(SelfWatch)) void {
        if (self.sub) |s| s.unsubscribe();
        self.sub = null;
    }
    fn bump(self: *SelfWatch, cx: *Context(SelfWatch)) void {
        self.value += 1;
        cx.notify();
    }
};

test "context: observe_self runs on each notify, until it is unsubscribed" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const watch = cx.new(SelfWatch{});
    cx.update_entity(watch, SelfWatch.watch, .{});
    cx.update_entity(watch, SelfWatch.bump, .{});
    cx.update_entity(watch, SelfWatch.bump, .{});
    try std.testing.expectEqual(@as(usize, 2), watch.read(cx.app).self_seen);
    cx.update_entity(watch, SelfWatch.stop, .{});
    cx.update_entity(watch, SelfWatch.bump, .{});
    try std.testing.expectEqual(@as(usize, 2), watch.read(cx.app).self_seen);
    try std.testing.expectEqual(@as(usize, 3), watch.read(cx.app).value);
}

/// An entity that emits, and subscribes to its own events.
const Chatty = struct {
    pub const Event = struct { amount: usize };
    received: usize = 0,
    sub: ?app_mod.Subscription = null,

    fn watch(self: *Chatty, cx: *Context(Chatty)) void {
        self.sub = cx.subscribe_self(on_event);
    }
    fn on_event(self: *Chatty, ev: *const Event, _: *Context(Chatty)) void {
        self.received += ev.amount;
    }
    fn say(_: *Chatty, cx: *Context(Chatty)) void {
        cx.emit(.{ .amount = 2 });
    }
    fn stop(self: *Chatty, _: *Context(Chatty)) void {
        if (self.sub) |s| s.unsubscribe();
        self.sub = null;
    }
};

test "context: subscribe_self receives the entity's own events, until unsubscribed" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const chatty = cx.new(Chatty{});
    cx.update_entity(chatty, Chatty.watch, .{});
    cx.update_entity(chatty, Chatty.say, .{});
    cx.update_entity(chatty, Chatty.say, .{});
    try std.testing.expectEqual(@as(usize, 4), chatty.read(cx.app).received);
    cx.update_entity(chatty, Chatty.stop, .{});
    cx.update_entity(chatty, Chatty.say, .{});
    try std.testing.expectEqual(@as(usize, 4), chatty.read(cx.app).received);
}

const ReleaseTarget = struct {
    id: u8 = 0,
};

/// Watches another entity's release, and can stop watching.
const Mourner = struct {
    released: usize = 0,
    sub: ?app_mod.Subscription = null,

    fn watch(self: *Mourner, target: Entity(ReleaseTarget), cx: *Context(Mourner)) void {
        self.sub = cx.observe_release(target, on_released);
    }
    fn on_released(self: *Mourner, released: *ReleaseTarget, _: *Context(Mourner)) void {
        if (released.id == 9) self.released += 1;
    }
    fn stop(self: *Mourner, _: *Context(Mourner)) void {
        if (self.sub) |s| s.unsubscribe();
        self.sub = null;
    }
};

test "context: observe_release runs once when the entity is released, and not after unsubscribe" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const target = cx.new(ReleaseTarget{ .id = 9 });
    const other = cx.new(ReleaseTarget{ .id = 9 });
    const mourner = cx.new(Mourner{});
    cx.update_entity(mourner, Mourner.watch, .{target});
    // A second mourner that stops before the release must hear nothing.
    const quiet = cx.new(Mourner{});
    cx.update_entity(quiet, Mourner.watch, .{other});
    cx.update_entity(quiet, Mourner.stop, .{});

    target.release(cx.app);
    try std.testing.expectEqual(@as(usize, 1), mourner.read(cx.app).released);
    other.release(cx.app);
    try std.testing.expectEqual(@as(usize, 0), quiet.read(cx.app).released);
}

/// A view that watches things in its window: another entity, a global, and its own release.
const WindowWatch = struct {
    window_calls: usize = 0,
    window_matches: bool = false,
    sub_a: ?app_mod.Subscription = null,
    sub_b: ?app_mod.Subscription = null,
    sub_global: ?app_mod.Subscription = null,
    expected: ?*Window = null,

    pub fn render(_: *WindowWatch, _: *Window, _: *Context(WindowWatch)) *Div {
        return div().size_full();
    }

    fn build(window: *Window, app: *App) Entity(WindowWatch) {
        return app.new(WindowWatch{ .expected = window });
    }

    fn note(self: *WindowWatch, window: *Window) void {
        self.window_calls += 1;
        self.window_matches = self.window_matches or window == self.expected.?;
    }

    fn watch_release_in(self: *WindowWatch, a: Entity(ReleaseTarget), b: Entity(ReleaseTarget), window: *Window, cx: *Context(WindowWatch)) void {
        self.sub_a = cx.observe_release_in(a, window, on_release_a);
        self.sub_b = cx.observe_release_in(b, window, on_release_a);
        if (self.sub_b) |s| s.unsubscribe();
        self.sub_b = null;
    }
    fn on_release_a(self: *WindowWatch, _: *ReleaseTarget, window: *Window, _: *Context(WindowWatch)) void {
        self.note(window);
    }

    fn watch_global(self: *WindowWatch, window: *Window, cx: *Context(WindowWatch)) void {
        self.sub_global = cx.observe_global_in(Setting, window, on_global);
    }
    fn on_global(self: *WindowWatch, window: *Window, _: *Context(WindowWatch)) void {
        self.note(window);
    }
    fn stop_global(self: *WindowWatch, _: *Context(WindowWatch)) void {
        if (self.sub_global) |s| s.unsubscribe();
        self.sub_global = null;
    }
};

const Setting = struct { n: u32 = 0 };

test "context: observe_release_in and observe_global_in run with their window, and stop when unsubscribed" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(WindowWatch.build);
    const a = cx.new(ReleaseTarget{ .id = 1 });
    const b = cx.new(ReleaseTarget{ .id = 2 });
    cx.update_entity(view, WindowWatch.watch_release_in, .{ a, b, vcx.window });

    // Released with its window open: runs once, with that window.
    a.release(cx.app);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).window_calls);
    try std.testing.expect(view.read(cx.app).window_matches);
    // The second watch was unsubscribed before its release, so it never ran.
    b.release(cx.app);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).window_calls);

    // The global observer runs on each change, with the window, until it is unsubscribed.
    cx.update_entity(view, WindowWatch.watch_global, .{ vcx.window });
    cx.app.set_global(Setting{ .n = 1 });
    cx.app.set_global(Setting{ .n = 2 });
    try std.testing.expectEqual(@as(usize, 3), view.read(cx.app).window_calls);
    cx.update_entity(view, WindowWatch.stop_global, .{});
    cx.app.set_global(Setting{ .n = 3 });
    try std.testing.expectEqual(@as(usize, 3), view.read(cx.app).window_calls);
}

/// Observes another entity with its window (GPUI `observe_in`).
const ObserveIn = struct {
    calls: usize = 0,
    saw_window: ?*Window = null,
    sub: ?app_mod.Subscription = null,

    pub fn render(_: *ObserveIn, _: *Window, _: *Context(ObserveIn)) *Div {
        return div().size_full();
    }
    fn watch(self: *ObserveIn, target: Entity(ReleaseTarget), window: *Window, cx: *Context(ObserveIn)) void {
        self.sub = cx.observe_in(target, window, on_change);
    }
    fn on_change(self: *ObserveIn, _: Entity(ReleaseTarget), window: *Window, _: *Context(ObserveIn)) void {
        self.calls += 1;
        self.saw_window = window;
    }
    fn stop(self: *ObserveIn, _: *Context(ObserveIn)) void {
        if (self.sub) |s| s.unsubscribe();
        self.sub = null;
    }
    fn build(_: *Window, app: *App) Entity(ObserveIn) {
        return app.new(ObserveIn{});
    }
};

test "context: observe_in runs when the observed entity notifies, with the window it was given" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(ObserveIn.build);
    const target = cx.new(ReleaseTarget{});
    cx.update_entity(view, ObserveIn.watch, .{ target, vcx.window });
    cx.update_entity(target, struct {
        fn poke(_: *ReleaseTarget, c: *Context(ReleaseTarget)) void {
            c.notify();
        }
    }.poke, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).calls);
    try std.testing.expectEqual(vcx.window, view.read(cx.app).saw_window.?);
    cx.update_entity(view, ObserveIn.stop, .{});
    cx.update_entity(target, struct {
        fn poke(_: *ReleaseTarget, c: *Context(ReleaseTarget)) void {
            c.notify();
        }
    }.poke, .{});
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).calls);
}

/// Defers work to the end of an update, with its window (GPUI `defer_in`).
const Deferred = struct {
    ran: usize = 0,
    ran_with_window: bool = false,

    pub fn render(_: *Deferred, _: *Window, _: *Context(Deferred)) *Div {
        return div().size_full();
    }
    fn build(_: *Window, app: *App) Entity(Deferred) {
        return app.new(Deferred{});
    }
    fn start(self: *Deferred, window: *Window, cx: *Context(Deferred)) void {
        self.ran = 0;
        cx.defer_in(window, finish);
    }
    fn finish(self: *Deferred, window: *Window, _: *Context(Deferred)) void {
        self.ran += 1;
        self.ran_with_window = window.handle_id == 0;
    }
};

test "context: defer_in runs at the end of the update, with the window" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(Deferred.build);
    cx.update_entity(view, Deferred.start, .{vcx.window});
    // The update has ended, so the deferred work has run exactly once.
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).ran);
    try std.testing.expect(view.read(cx.app).ran_with_window);
}

/// Holds two focus handles, one inside the other, and a sibling (GPUI focus listeners).
const FocusWatch = struct {
    outer: window_mod.FocusHandle,
    inner: window_mod.FocusHandle,
    other: window_mod.FocusHandle,
    focused: usize = 0,
    blurred: usize = 0,
    focus_in: usize = 0,
    focus_out: usize = 0,
    focus_out_blurred_inner: bool = false,
    lost: usize = 0,
    lost_unsubscribed: usize = 0,
    lost_sub: ?app_mod.Subscription = null,

    pub fn render(self: *FocusWatch, _: *Window, _: *Context(FocusWatch)) *Div {
        return div().size_full()
            .child(div().id("outer").size(px(100)).track_focus(&self.outer).child(div().id("inner").size(px(20)).track_focus(&self.inner)))
            .child(div().id("other").size(px(100)).track_focus(&self.other));
    }

    fn build(_: *Window, app: *App) Entity(FocusWatch) {
        return app.new(FocusWatch{ .outer = app.focus_handle(), .inner = app.focus_handle(), .other = app.focus_handle() });
    }

    fn watch(self: *FocusWatch, window: *Window, cx: *Context(FocusWatch)) void {
        _ = cx.on_focus(self.outer, window, on_focused);
        _ = cx.on_blur(self.outer, window, on_blurred);
        _ = cx.on_focus_in(self.outer, window, on_focus_in);
        _ = cx.on_focus_out(self.outer, window, on_focus_out);
        _ = cx.on_focus_lost(window, on_lost);
        self.lost_sub = cx.on_focus_lost(window, on_lost_unsubscribed);
        if (self.lost_sub) |s| s.unsubscribe();
        self.lost_sub = null;
    }
    fn on_focused(self: *FocusWatch, _: *Window, _: *Context(FocusWatch)) void {
        self.focused += 1;
    }
    fn on_blurred(self: *FocusWatch, _: *Window, _: *Context(FocusWatch)) void {
        self.blurred += 1;
    }
    fn on_focus_in(self: *FocusWatch, _: *Window, _: *Context(FocusWatch)) void {
        self.focus_in += 1;
    }
    fn on_focus_out(self: *FocusWatch, event: app_mod.FocusOutEvent, _: *Window, _: *Context(FocusWatch)) void {
        self.focus_out += 1;
        self.focus_out_blurred_inner = event.blurred.id == self.inner.id;
    }
    fn on_lost(self: *FocusWatch, _: *Window, _: *Context(FocusWatch)) void {
        self.lost += 1;
    }
    fn on_lost_unsubscribed(self: *FocusWatch, _: *Window, _: *Context(FocusWatch)) void {
        self.lost_unsubscribed += 1;
    }
};

test "context: focus listeners fire on the focus changes they are for, and only those" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(FocusWatch.build);
    cx.update_entity(view, FocusWatch.watch, .{vcx.window});
    const s = view.read(cx.app);
    const outer = s.outer;
    const inner = s.inner;
    const other = s.other;

    // Focus moves into the inner handle. `outer` gains focus from its subtree (on_focus_in), but
    // the focused element is `inner`, so on_focus(outer) must not fire.
    vcx.focus(inner);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).focus_in);
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).focused);

    // Focus moves to a sibling: `outer` loses focus through its descendant. on_focus_out reports
    // the element that lost it, the inner handle, and on_blur(outer) does not fire.
    vcx.focus(other);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).focus_out);
    try std.testing.expect(view.read(cx.app).focus_out_blurred_inner);
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).blurred);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).focus_in);

    // Focus returns to `outer` itself: on_focus fires, and on_focus_in fires again.
    vcx.focus(outer);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).focused);
    try std.testing.expectEqual(@as(usize, 2), view.read(cx.app).focus_in);

    // Nothing focused any more: on_blur(outer) and on_focus_lost fire, and the unsubscribed
    // listener stays silent.
    vcx.window.blur();
    vcx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).blurred);
    try std.testing.expectEqual(@as(usize, 2), view.read(cx.app).focus_out);
    try std.testing.expectEqual(@as(usize, 1), view.read(cx.app).lost);
    try std.testing.expectEqual(@as(usize, 0), view.read(cx.app).lost_unsubscribed);
}

/// Entity with a quit hook, and a second one that unsubscribes before the quit.
const Quitter = struct {
    quits: usize = 0,
    sub: ?app_mod.Subscription = null,

    fn watch(self: *Quitter, cx: *Context(Quitter)) void {
        self.sub = cx.on_app_quit(on_quit);
    }
    fn on_quit(self: *Quitter, _: *Context(Quitter)) void {
        self.quits += 1;
    }
    fn stop(self: *Quitter, _: *Context(Quitter)) void {
        if (self.sub) |s| s.unsubscribe();
        self.sub = null;
    }
};

test "context: on_app_quit runs once at shutdown, not on quit, and not after unsubscribe" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const kept = cx.new(Quitter{});
    cx.update_entity(kept, Quitter.watch, .{});
    const dropped = cx.new(Quitter{});
    cx.update_entity(dropped, Quitter.watch, .{});
    cx.update_entity(dropped, Quitter.stop, .{});

    // quit asks the platform to stop; the hooks run at shutdown, when the loop has ended.
    cx.app.quit();
    try std.testing.expectEqual(@as(usize, 0), kept.read(cx.app).quits);
    cx.app.shutdown();
    try std.testing.expectEqual(@as(usize, 1), kept.read(cx.app).quits);
    try std.testing.expectEqual(@as(usize, 0), dropped.read(cx.app).quits);
    // Once only: a second shutdown does nothing.
    cx.app.shutdown();
    try std.testing.expectEqual(@as(usize, 1), kept.read(cx.app).quits);
}

/// A view that starts async work with its window (GPUI `spawn_in`).
const Spawner = struct {
    pub fn render(_: *Spawner, _: *Window, _: *Context(Spawner)) *Div {
        return div().size_full();
    }
    fn build(_: *Window, app: *App) Entity(Spawner) {
        return app.new(Spawner{});
    }
    fn start(_: *Spawner, window: *Window, cx: *Context(Spawner)) void {
        var task = cx.spawn_in(window, Work.run, .{});
        task.detach();
    }
};

const Work = struct {
    var calls: usize = 0;
    var err: ?anyerror = null;

    fn note(_: *Window, _: *App) void {
        calls += 1;
    }
    fn run(_: app_mod.WeakEntity(Spawner), wcx: app_mod.AsyncWindowContext) void {
        wcx.update(note, .{}) catch |e| {
            err = e;
            return;
        };
    }
};

test "context: spawn_in runs with a window context, which fails once the window is closed" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    Work.calls = 0;
    Work.err = null;

    // The window is open when the work runs: its update reaches the window.
    const view, const vcx = cx.add_window_view(Spawner.build);
    cx.update_entity(view, Spawner.start, .{vcx.window});
    cx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), Work.calls);
    try std.testing.expectEqual(@as(?anyerror, null), Work.err);

    // Closed before the work runs: the update fails instead of touching a dead window.
    const view2, const vcx2 = cx.add_window_view(Spawner.build);
    cx.update_entity(view2, Spawner.start, .{vcx2.window});
    cx.app.close_window(vcx2.window);
    cx.run_until_parked();
    try std.testing.expectEqual(@as(usize, 1), Work.calls);
    try std.testing.expectEqual(@as(?anyerror, error.WindowClosed), Work.err);
}

/// Counts the entities created after it is set up (GPUI `observe_new`).
const NewProbe = struct {
    var seen: usize = 0;
    var seen_without_window: usize = 0;

    fn on_new(m: *Model, window: ?*Window, _: *Context(Model)) void {
        seen += 1;
        if (window == null) seen_without_window += 1;
        m.value = 5;
    }
};

test "app: observe_new runs for each new entity of the type, until unsubscribed" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    NewProbe.seen = 0;
    NewProbe.seen_without_window = 0;
    const sub = cx.app.observe_new(Model, NewProbe.on_new);
    const first = cx.new(Model{});
    try std.testing.expectEqual(@as(usize, 5), first.read(cx.app).value);
    _ = cx.new(Model{});
    try std.testing.expectEqual(@as(usize, 2), NewProbe.seen);
    try std.testing.expectEqual(@as(usize, 2), NewProbe.seen_without_window);
    sub.unsubscribe();
    _ = cx.new(Model{});
    try std.testing.expectEqual(@as(usize, 2), NewProbe.seen);
}

test "entities: AnyWeakEntity upgrades while the entity lives, and not after release" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const model = cx.new(Model{});
    const weak = model.into_any().downgrade();
    try std.testing.expect(weak.is_upgradable(cx.app));
    try std.testing.expect(weak.upgrade(cx.app) != null);
    try std.testing.expect(weak.downcast(Model) != null);
    try std.testing.expect(weak.downcast(Chatty) == null);
    model.release(cx.app);
    try std.testing.expect(!weak.is_upgradable(cx.app));
    try std.testing.expect(weak.upgrade(cx.app) == null);
}

test "app: quit mode decides whether closing the last window quits" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const quit_requested = struct {
        fn get(c: *TestAppContext) bool {
            return headless.HeadlessPlatform.from(c.platform).quit_requested;
        }
    }.get;

    // Explicit: closing the last window never quits by itself.
    cx.app.set_quit_mode(.explicit);
    _, const first = cx.add_window_view(WindowWatch.build);
    cx.app.close_window(first.window);
    try std.testing.expect(!quit_requested(&cx));

    // last_window_closed: quits on every platform.
    cx.app.set_quit_mode(.last_window_closed);
    _, const second = cx.add_window_view(WindowWatch.build);
    cx.app.close_window(second.window);
    try std.testing.expect(quit_requested(&cx));
}

test "app: find_display returns the display with that id, or null" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const displays = cx.app.displays();
    try std.testing.expect(displays.len > 0);
    const found = cx.app.find_display(displays[0].id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(displays[0].id, found.id);
    try std.testing.expect(cx.app.find_display(displays[0].id +% 1000) == null);
}

test "async: read_global reads a set global and fails while it is unset" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Read = struct {
        fn get(s: *const Setting, _: *App) u32 {
            return s.n;
        }
    };
    const async_app = cx.app.to_async();
    try std.testing.expectError(error.GlobalNotFound, async_app.read_global(Setting, Read.get, .{}));
    try std.testing.expectEqual(@as(?u32, null), async_app.try_read_global(Setting, Read.get, .{}));
    cx.app.set_global(Setting{ .n = 4 });
    try std.testing.expectEqual(@as(u32, 4), try async_app.read_global(Setting, Read.get, .{}));
    try std.testing.expectEqual(@as(?u32, 4), async_app.try_read_global(Setting, Read.get, .{}));
}

test "app: global_mut returns the global for writing" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.set_global(Setting{ .n = 1 });
    cx.app.global_mut(Setting).n = 7;
    try std.testing.expectEqual(@as(u32, 7), cx.app.global(Setting).n);
}

test "app: update_default_global sets the default first, then updates it" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Bump = struct {
        fn run(s: *Setting, _: *App) u32 {
            s.n += 1;
            return s.n;
        }
    };
    try std.testing.expectEqual(@as(u32, 1), cx.app.update_default_global(Setting, Bump.run));
    try std.testing.expectEqual(@as(u32, 2), cx.app.update_default_global(Setting, Bump.run));
}

test "app: background_spawn runs on a worker and its result can be waited for" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const Double = struct {
        fn run(x: u32) u32 {
            return x * 2;
        }
    };
    var task = cx.app.background_spawn(Double.run, .{@as(u32, 21)});
    try std.testing.expectEqual(@as(u32, 42), task.wait());
}
