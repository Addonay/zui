//! Window lifecycle, rendering target, and geometry bounds.

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");
const gpu = @import("../gpu/root.zig");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const text_engine = @import("../fonts/text_engine.zig");
const images = @import("../images/root.zig");
const keymap = @import("keymap.zig");

pub const Chrome = enum {
    system,
    custom,
};

/// Native window operations installed by `App.openWindow`. Backends hold
/// one native window; every call pushes straight through.
pub const OsHooks = struct {
    ctx: *anyopaque,
    setTitle: *const fn (*anyopaque, []const u8) void,
    setCursor: *const fn (*anyopaque, platform.CursorShape) void,
    getClipboard: *const fn (*anyopaque, []u8) usize,
    setClipboard: *const fn (*anyopaque, []const u8) bool,
    dragWindow: *const fn (*anyopaque) void,
    minimizeWindow: *const fn (*anyopaque) void,
    toggleMaximizeWindow: *const fn (*anyopaque) void,
};

pub const WindowOptions = struct {
    title: []const u8 = "ZUI Window",
    bounds: ?geometry.Bounds = null,
    min_size: ?geometry.Size = null,
    max_size: ?geometry.Size = null,
    chrome: Chrome = .system,
};

pub const RenderFn = *const fn (ctx: ?*anyopaque, window: *Window, scene: *gpu.Scene) void;

pub const Renderer = struct {
    ptr: ?*anyopaque = null,
    render_fn: RenderFn,

    pub fn call(self: @This(), window: *Window, scene: *gpu.Scene) void {
        self.render_fn(self.ptr, window, scene);
    }
};

pub const Window = struct {
    id: u32,
    app: *anyopaque,
    wakeup_fn: *const fn (*anyopaque) void,
    remove_fn: *const fn (*anyopaque, *Window) void,
    /// Allocator for cold frame work (image file reads/decodes).
    allocator: ?std.mem.Allocator = null,
    os: ?OsHooks = null,
    cursor_shape: platform.CursorShape = .default,
    bounds: geometry.Bounds,
    min_size: ?geometry.Size = null,
    max_size: ?geometry.Size = null,
    chrome: Chrome = .system,
    maximized: bool = false,
    last_click_ms: i64 = 0,
    last_click_pos: geometry.Point = .{ .x = -10000, .y = -10000 },
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    dirty: bool = true,
    closed: bool = false,
    scene: gpu.Scene = .{},
    renderer: ?Renderer = null,
    /// Last App.step_count that rendered this window; feeds image-cache
    /// pinning so eviction never drops the current frame's entries.
    frame_id: u64 = 0,
    ui_frame: elements.Frame = .{},
    /// Borrowed image cache (owned by `App`, null headless-without-cache).
    /// Fed to the frame each render for img()/svg() resolution.
    images: ?*images.Cache = null,
    /// Optional provider for the App-owned cozmic engine. Called once per
    /// element frame; null leaves text with no engine (draws nothing).
    cozmic_engine_fn: ?*const fn (*anyopaque) ?*text_engine.Engine = null,
    cozmic_engine_ctx: ?*anyopaque = null,
    pointer_position: geometry.Point = .{ .x = -10000, .y = -10000 },
    focused: elements.FocusHandle = .{},
    keymap: keymap.Keymap = .{},
    /// Window-level context tags (outermost keymap frame, after "Window").
    context_tags: [4][]const u8 = undefined,
    context_tag_count: usize = 0,
    actions: [32]Action = undefined,
    action_count: usize = 0,

    pub fn title(self: *const Window) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn setTitle(self: *Window, new_title: []const u8) void {
        const tlen = @min(new_title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..tlen], new_title[0..tlen]);
        self.title_len = tlen;
        if (self.os) |os| os.setTitle(os.ctx, self.title());
    }

    /// Push a cursor shape, filtered so repeats don't hammer the server.
    pub fn setCursorShape(self: *Window, shape: platform.CursorShape) void {
        if (shape == self.cursor_shape) return;
        self.cursor_shape = shape;
        if (self.os) |os| os.setCursor(os.ctx, shape);
    }

    pub fn readClipboard(self: *Window, out: []u8) usize {
        if (self.os) |os| return os.getClipboard(os.ctx, out);
        return 0;
    }

    pub fn writeClipboard(self: *Window, text: []const u8) bool {
        if (self.os) |os| return os.setClipboard(os.ctx, text);
        return false;
    }

    pub fn requestRender(self: *Window) void {
        if (self.closed) return;
        self.dirty = true;
        self.wakeup_fn(self.app);
    }

    pub fn markDirty(self: *Window) void {
        self.requestRender();
    }

    pub fn render(self: *Window) void {
        // Clear before user code so a requestRender() during rendering
        // schedules another frame instead of being swallowed.
        self.dirty = false;
        self.scene.clear();
        if (self.renderer) |r| {
            r.call(self, &self.scene);
        }
        // Regions were rebuilt above; refresh the cursor for a stationary
        // pointer sitting over changed content.
        self.updateHoverCursor();
    }

    /// Cursor follows hover, not focus: topmost region under the pointer
    /// with a cursor opinion wins, otherwise the default arrow. Called on
    /// mouse input and after every render.
    pub fn updateHoverCursor(self: *Window) void {
        var i = self.ui_frame.region_count;
        while (i > 0) {
            i -= 1;
            const region = self.ui_frame.regions[i];
            if (!region.bounds.contains(self.pointer_position)) continue;
            if (region.cursor) |shape| {
                self.setCursorShape(shape);
                return;
            }
        }
        self.setCursorShape(.default);
    }

    /// Mark closed; destruction is deferred to `App.reapClosed` at a safe
    /// point after dispatch/render. Calling close from inside a listener
    /// or action is safe: the caller keeps using `self` until the sweep.
    pub fn close(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
    }

    /// Release frame-owned resources before the owner frees this window.
    /// Retained measure→paint text layouts are heap entries owned by the
    /// frame allocator; a window destroyed before a final `painter.paint`
    /// (which normally clears them) must not leak them.
    pub fn deinit(self: *Window) void {
        self.ui_frame.clearCozmicLayouts();
    }

    pub fn isClosed(self: *const Window) bool {
        return self.closed;
    }

    pub fn setRenderer(self: *Window, r: Renderer) void {
        self.renderer = r;
        self.requestRender();
    }

    pub fn getScene(self: *Window) *gpu.Scene {
        return &self.scene;
    }

    pub fn getSceneConst(self: *const Window) *const gpu.Scene {
        return &self.scene;
    }

    pub fn attachRenderer(self: *Window, target: anytype) void {
        const T = @TypeOf(target);
        if (T == Renderer) {
            self.renderer = target;
        } else if (T == ?Renderer) {
            self.renderer = target;
        } else {
            const info = @typeInfo(T);
            switch (info) {
                .@"fn" => |fn_info| {
                    if (fn_info.param_types.len == 2) {
                        if (fn_info.param_types[1] == *gpu.Scene or fn_info.param_types[1] == ?*gpu.Scene) {
                            const S = struct {
                                fn call(_: ?*anyopaque, w: *Window, sc: *gpu.Scene) void {
                                    target(w, sc);
                                }
                            };
                            self.renderer = .{ .ptr = null, .render_fn = S.call };
                        }
                    } else if (fn_info.param_types.len == 1) {
                        if (fn_info.param_types[0] == *Window) {
                            const S = struct {
                                fn call(_: ?*anyopaque, w: *Window, _: *gpu.Scene) void {
                                    target(w);
                                }
                            };
                            self.renderer = .{ .ptr = null, .render_fn = S.call };
                        }
                    }
                },
                .pointer => |ptr_info| {
                    if (@typeInfo(ptr_info.child) == .@"struct" and @hasDecl(ptr_info.child, "render")) {
                        const S = struct {
                            fn call(ctx: ?*anyopaque, w: *Window, sc: *gpu.Scene) void {
                                const obj: *ptr_info.child = @ptrCast(@alignCast(ctx.?));
                                const render_fn_info = @typeInfo(@TypeOf(ptr_info.child.render)).@"fn";
                                if (render_fn_info.param_types.len == 3) {
                                    obj.render(w, sc);
                                } else if (render_fn_info.param_types.len == 2) {
                                    if (render_fn_info.param_types[1] == *gpu.Scene) {
                                        obj.render(sc);
                                    } else {
                                        obj.render(w);
                                    }
                                } else {
                                    obj.render();
                                }
                            }
                        };
                        self.renderer = .{ .ptr = target, .render_fn = S.call };
                    }
                },
                else => {},
            }
        }
    }

    pub fn playSystemBell(self: *Window) void {
        _ = self;
    }

    /// Ask the backend to begin a native window drag (used by custom
    /// titlebars for frameless move).
    pub fn startDrag(self: *Window) void {
        if (self.os) |os| os.dragWindow(os.ctx);
    }

    pub fn minimize(self: *Window) void {
        if (self.os) |os| os.minimizeWindow(os.ctx);
    }

    pub fn toggleMaximize(self: *Window) void {
        self.maximized = !self.maximized;
        if (self.os) |os| os.toggleMaximizeWindow(os.ctx);
        self.requestRender();
    }

    pub fn isMaximized(self: *const Window) bool {
        return self.maximized;
    }

    pub fn focus(self: *Window, handle: anytype, cx: anytype) void {
        _ = cx;
        self.focused = handle;
        self.requestRender();
    }

    pub fn on_action(self: *Window, name: []const u8, target: anytype, comptime action: anytype) void {
        if (self.action_count >= self.actions.len) return;
        self.actions[self.action_count] = .{ .name = name, .listener = target.actionListener(action) };
        self.action_count += 1;
    }

    pub fn addKeyBinding(self: *Window, key_name: []const u8, action: []const u8) void {
        // Legacy single-key form: no modifiers, global context. Richer
        // chords/sequences go through bindKeystrokes.
        _ = self.keymap.bind(key_name, action, null);
    }

    /// Bind `"ctrl-s"` / `"g g"` to an action in an optional context
    /// (`"TodoList && mode == normal"`). False when unparsable or full.
    pub fn bindKeystrokes(self: *Window, keys: []const u8, action: []const u8, context: ?[]const u8) bool {
        return self.keymap.bind(keys, action, context);
    }

    pub fn pushContextTag(self: *Window, tag: []const u8) void {
        if (self.context_tag_count >= self.context_tags.len) return;
        self.context_tags[self.context_tag_count] = tag;
        self.context_tag_count += 1;
    }

    pub fn clearContextTags(self: *Window) void {
        self.context_tag_count = 0;
    }

    pub fn updateHitRegions(self: *Window) void {
        if (self.focused.id == 0) return;
        for (self.ui_frame.regions[0..self.ui_frame.region_count]) |region| {
            if (region.focus) |handle| {
                if (handle.id == self.focused.id) {
                    self.focused = handle;
                    return;
                }
            }
        }
        // Focused control disappeared: clear so dead handles stop
        // receiving text/key events instead of dispatching into freed state.
        self.focused = .{};
    }

    pub fn handleEvent(self: *Window, event: platform.Event) void {
        if (self.closed) return;
        switch (event) {
            .mouse => |mouse| {
                self.pointer_position = mouse.pos;
                self.updateHoverCursor();
                if (mouse.pressed and mouse.button == .left) {
                    // Double-click needs wall time, which lives with the OS
                    // backend (both Wayland and X11 timestamp input). Events
                    // carry it in `time_ms`; zero means unknown and never
                    // doubles, which keeps headless tests deterministic.
                    // Seed history on the first timed press so the second
                    // press can double even when starting from zero.
                    const had_prior = self.last_click_ms > 0;
                    const timed = mouse.time_ms > 0;
                    const double_click = timed and had_prior and mouse.time_ms - self.last_click_ms < 400 and
                        @abs(mouse.pos.x - self.last_click_pos.x) < 6 and
                        @abs(mouse.pos.y - self.last_click_pos.y) < 6;
                    if (timed) {
                        self.last_click_ms = mouse.time_ms;
                        self.last_click_pos = mouse.pos;
                    }
                    // Clicking outside a focusable control releases keyboard focus.
                    self.focused = .{};
                    var i = self.ui_frame.region_count;
                    while (i > 0) {
                        i -= 1;
                        const region = self.ui_frame.regions[i];
                        if (!region.bounds.contains(mouse.pos)) continue;
                        if (region.focus) |handle| self.focused = handle;
                        if (region.mouse_down_listener) |listener| listener.call(self);
                        if (double_click) {
                            if (region.double_click_listener) |listener| listener.call(self);
                        }
                        if (region.listener) |listener| listener.call(self);
                        break;
                    }
                }
                self.requestRender();
            },
            .key, .text => {
                if (self.focused.dispatch(event, self)) {
                    self.requestRender();
                    return;
                }
                switch (event) {
                    .key => |key_event| if (key_event.pressed) self.dispatchKeyAction(key_event.key, key_event.modifiers),
                    .text => {},
                    else => unreachable,
                }
            },
            .scroll => |scroll| {
                self.pointer_position = scroll.pos;
                self.updateHoverCursor();
                if (self.focused.dispatch(event, self)) {
                    self.requestRender();
                    return;
                }
                self.requestRender();
            },
            .window => {},
        }
    }

    fn dispatchKeyAction(self: *Window, key: platform.event.Key, modifiers: platform.event.Modifiers) void {
        var frame = keymap.ContextFrame{};
        _ = frame.put("Window", "");
        for (self.context_tags[0..self.context_tag_count]) |tag| {
            _ = frame.put(tag, "");
        }
        const stack = [_]keymap.ContextFrame{frame};
        const stroke = keymap.Keystroke{ .key = key, .modifiers = modifiers };
        const action_name = self.keymap.dispatch(stroke, &stack) orelse return;
        self.fireAction(action_name);
    }

    pub fn fireAction(self: *Window, action_name: []const u8) void {
        for (self.actions[0..self.action_count]) |action| {
            if (std.mem.eql(u8, action.name, action_name)) {
                action.listener.call(self);
                return;
            }
        }
    }
};

const Action = struct {
    name: []const u8,
    listener: elements.Listener,
};

test "window basic properties and render" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.init(std.testing.allocator);
    defer app.deinit();

    const win = try app.openWindow(.{
        .title = "Test Win",
        .bounds = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .w = 640, .h = 480 } },
    }, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc.push(.{ .x = 0, .y = 0, .w = 100, .h = 100, .color = color.Color.white });
        }
    }.draw);

    try std.testing.expectEqualStrings("Test Win", win.title());
    try std.testing.expectEqual(@as(f32, 640), win.bounds.size.w);
    try std.testing.expect(win.dirty);

    win.render();
    try std.testing.expect(!win.dirty);
    try std.testing.expectEqual(@as(usize, 1), win.scene.slice().len);
    try std.testing.expectEqual(@as(f32, 100), win.scene.slice()[0].w);

    win.requestRender();
    try std.testing.expect(win.dirty);
}

test "window os hooks push title cursor and clipboard" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{ .title = "Hooked" }, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);

    // openWindow pushed the title straight to the backend.
    const nb = app.getNullBackend().?;
    try std.testing.expectEqualStrings("Hooked", nb.title_buf[0..nb.title_len]);
    win.setTitle("Renamed");
    try std.testing.expectEqualStrings("Renamed", nb.title_buf[0..nb.title_len]);

    // Cursor pushes filter repeats.
    win.setCursorShape(.text);
    try std.testing.expectEqual(platform.CursorShape.text, nb.cursor);
    win.setCursorShape(.text);
    win.setCursorShape(.default);
    try std.testing.expectEqual(platform.CursorShape.default, nb.cursor);

    // Clipboard round-trips through the backend store.
    try std.testing.expect(win.writeClipboard("hello"));
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", out[0..win.readClipboard(&out)]);
}

test "hover cursor follows topmost region opinion" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);
    const nb = app.getNullBackend().?;

    win.ui_frame.region_count = 2;
    win.ui_frame.regions[0] = .{ .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 } };
    win.ui_frame.regions[1] = .{ .bounds = .{ .x = 10, .y = 10, .w = 20, .h = 20 }, .cursor = .pointer };
    // Over the inner region: pointer cursor wins (topmost).
    win.pointer_position = .{ .x = 15, .y = 15 };
    win.updateHoverCursor();
    try std.testing.expectEqual(platform.CursorShape.pointer, nb.cursor);
    // Over the outer region only: no opinion -> default arrow.
    win.pointer_position = .{ .x = 50, .y = 50 };
    win.updateHoverCursor();
    try std.testing.expectEqual(platform.CursorShape.default, nb.cursor);
    // Outside everything: default arrow.
    win.pointer_position = .{ .x = 500, .y = 500 };
    win.updateHoverCursor();
    try std.testing.expectEqual(platform.CursorShape.default, nb.cursor);
}

test "stale focus clears when its region disappears" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);

    win.focused = .{ .id = 42 };
    win.ui_frame.region_count = 0;
    win.updateHitRegions();
    try std.testing.expectEqual(@as(u32, 0), win.focused.id);
}

test "double-click history seeds from zero" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);

    var doubles: u32 = 0;
    const S = struct {
        var count: *u32 = undefined;
        fn onDouble(_: *anyopaque, _: *const elements.element.ListenerPayload, _: *anyopaque) void {
            count.* += 1;
        }
    };
    S.count = &doubles;
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = geometry.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .double_click_listener = .{ .target = win, .call_fn = S.onDouble },
    };

    const press = struct {
        fn at(w: *Window, t: i64) void {
            w.handleEvent(.{ .mouse = .{
                .pos = .{ .x = 10, .y = 10 },
                .button = .left,
                .pressed = true,
                .time_ms = t,
            } });
        }
    }.at;
    press(win, 100);
    // First timed press seeds history even from a zero start.
    try std.testing.expectEqual(@as(i64, 100), win.last_click_ms);
    try std.testing.expectEqual(@as(u32, 0), doubles);
    press(win, 300);
    try std.testing.expectEqual(@as(u32, 1), doubles);
}
