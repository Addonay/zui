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
const canvas_mod = @import("../elements/canvas.zig");
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
    try std.testing.expectEqual(@as(u32, 1), Slow.starts.load(.acquire));

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
    try std.testing.expectEqual(@as(u32, 2), Slow.starts.load(.acquire));
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
