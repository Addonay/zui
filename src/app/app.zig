//! Application orchestration, window management, and frame loop.

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");
const platform = @import("../platform/root.zig");
const gpu = @import("../gpu/root.zig");
const fonts = @import("../fonts/root.zig");
const window_mod = @import("window.zig");
const runtime = @import("runtime.zig");
const zlog = @import("../core/log.zig");
const images = @import("../images/root.zig");

pub const Window = window_mod.Window;
pub const WindowOptions = window_mod.WindowOptions;
pub const Renderer = window_mod.Renderer;

pub const App = struct {
    allocator: std.mem.Allocator,
    backend: platform.Backend,
    entities: runtime.EntityStore,
    owned_backend: ?platform.BackendInstance = null,
    /// Owned font stack (null without system fonts → bitmap fallback).
    /// Borrowed by windows/frames per render; never grows after init.
    fonts: ?*fonts.Collection = null,
    /// Owned decoded-image pool (always present; empty until first image).
    /// Borrowed by windows/frames per render like the font stack.
    image_cache: ?*images.Cache = null,
    windows: [limits.MAX_WINDOWS]?*Window = @splat(null),
    active_window_count: usize = 0,
    next_window_id: u32 = 1,
    event_queue: platform.EventQueue = .{},
    should_quit: bool = false,
    is_active: bool = false,
    /// Monotonic frame counter for `ZUI_LOG` diagnostics (a stalled
    /// counter in the log pinpoints event-loop starvation hangs).
    step_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !App {
        var instance = try platform.createAuto(allocator, "ZUI Application", 800, 600);
        return .{
            .allocator = allocator,
            .backend = instance.handle(),
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = instance,
            .fonts = try initFonts(allocator),
            .image_cache = try images.Cache.init(allocator),
        };
    }

    pub fn initHeadless(allocator: std.mem.Allocator) !App {
        const nb = try allocator.create(platform.null_backend.NullBackend);
        nb.* = .{};
        return .{
            .allocator = allocator,
            .backend = nb.backendHandle(),
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = .{ .null_backend = nb },
            .fonts = try initFonts(allocator),
            .image_cache = try images.Cache.init(allocator),
        };
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, be: platform.Backend) App {
        return .{
            .allocator = allocator,
            .backend = be,
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = null,
            .fonts = initFonts(allocator) catch null,
            .image_cache = images.Cache.init(allocator) catch null,
        };
    }

    fn initFonts(allocator: std.mem.Allocator) !?*fonts.Collection {
        // Font failure degrades to the bitmap fallback; only allocator OOM
        // propagates. Stack-first ordering keeps this leak-free.
        const stack = fonts.Collection.init() catch return null;
        const owned = try allocator.create(fonts.Collection);
        owned.* = stack;
        return owned;
    }

    /// Atlas pixel pool backing the current frame's glyph entries (empty
    /// without fonts). Valid only until the next render mutates the atlas.
    pub fn glyphPixels(self: *App) []const u8 {
        if (self.fonts) |fc| return fc.glyphs.pixels[0..fc.glyphs.pixels_used];
        return &.{};
    }

    /// Image-cache pool backing the current frame's image entries (empty
    /// without a cache). Same lifetime rule as the glyph pool.
    pub fn imagePixels(self: *App) []const u8 {
        if (self.image_cache) |ic| return ic.pool[0..ic.used];
        return &.{};
    }

    pub fn deinit(self: *App) void {
        for (&self.windows) |*maybe_win| {
            if (maybe_win.*) |win| {
                self.allocator.destroy(win);
                maybe_win.* = null;
            }
        }
        self.active_window_count = 0;
        self.entities.deinit();
        if (self.fonts) |fc| {
            fc.deinit();
            self.allocator.destroy(fc);
            self.fonts = null;
        }
        if (self.image_cache) |ic| {
            ic.deinit(self.allocator);
            self.image_cache = null;
        }
        if (self.owned_backend) |*be| {
            be.deinit(self.allocator);
            self.owned_backend = null;
        }
    }

    pub fn getNullBackend(self: *App) ?*platform.null_backend.NullBackend {
        if (self.owned_backend) |ob| {
            switch (ob) {
                .null_backend => |nb| return nb,
                else => return null,
            }
        }
        return null;
    }

    pub fn wakeup(self: *App) void {
        self.backend.wakeup();
    }

    fn osSetTitle(raw: *anyopaque, title: []const u8) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.backend.setTitle(title);
    }

    fn osSetCursor(raw: *anyopaque, shape: platform.CursorShape) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.backend.setCursor(shape);
    }

    fn osGetClipboard(raw: *anyopaque, out: []u8) usize {
        const app: *App = @ptrCast(@alignCast(raw));
        return app.backend.clipboardText(out);
    }

    fn osSetClipboard(raw: *anyopaque, text: []const u8) bool {
        const app: *App = @ptrCast(@alignCast(raw));
        return app.backend.setClipboardText(text);
    }

    fn osDragWindow(raw: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.backend.dragWindow();
    }

    fn osMinimizeWindow(raw: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.backend.minimizeWindow();
    }

    fn osToggleMaximizeWindow(raw: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.backend.toggleMaximizeWindow();
    }

    pub fn activate(self: *App, ignoring_other_apps: bool) void {
        _ = ignoring_other_apps;
        self.is_active = true;
    }

    pub fn isActive(self: *const App) bool {
        return self.is_active;
    }

    pub fn quit(self: *App) void {
        self.should_quit = true;
    }

    pub fn openWindow(self: *App, options: WindowOptions, build_or_render: anytype) !*Window {
        var slot: ?usize = null;
        for (&self.windows, 0..) |maybe_win, i| {
            if (maybe_win == null) {
                slot = i;
                break;
            }
        }
        const idx = slot orelse return error.TooManyWindows;

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);

        const bounds = options.bounds orelse geometry.Bounds{
            .origin = .{ .x = 0, .y = 0 },
            .size = self.backend.windowInfo().size,
        };

        win.* = .{
            .id = self.next_window_id,
            .app = self,
            .allocator = self.allocator,
            .wakeup_fn = struct {
                fn call(raw: *anyopaque) void {
                    const app: *App = @ptrCast(@alignCast(raw));
                    app.wakeup();
                }
            }.call,
            .remove_fn = struct {
                fn call(raw: *anyopaque, window: *Window) void {
                    const app: *App = @ptrCast(@alignCast(raw));
                    app.removeWindow(window);
                }
            }.call,
            .os = .{
                .ctx = self,
                .setTitle = osSetTitle,
                .setCursor = osSetCursor,
                .getClipboard = osGetClipboard,
                .setClipboard = osSetClipboard,
                .dragWindow = osDragWindow,
                .minimizeWindow = osMinimizeWindow,
                .toggleMaximizeWindow = osToggleMaximizeWindow,
            },
            .bounds = bounds,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .chrome = options.chrome,
            .dirty = true,
            .closed = false,
            .scene = .{},
            .renderer = null,
            .fonts = self.fonts,
            .images = self.image_cache,
        };
        self.next_window_id += 1;

        win.setTitle(options.title);
        // Explicit bounds resize the native window to match (X11/Cocoa/
        // Win32 honor it; Wayland sizes via compositor configure instead).
        if (options.bounds) |explicit| {
            if (explicit.size.w > 0 and explicit.size.h > 0) {
                self.backend.setSize(@intFromFloat(explicit.size.w), @intFromFloat(explicit.size.h));
            }
        }
        // Framed uses the OS titlebar; custom draws its own chrome.
        self.backend.setDecorated(options.chrome == .system);

        self.windows[idx] = win;
        self.active_window_count += 1;

        const Target = @TypeOf(build_or_render);
        if (@typeInfo(Target) == .@"fn" and @typeInfo(Target).@"fn".return_type.? != void) {
            runtime.mountView(&self.entities, win, build_or_render);
        } else {
            win.attachRenderer(build_or_render);
        }
        return win;
    }

    pub fn removeWindow(self: *App, win: *Window) void {
        for (&self.windows) |*maybe_win| {
            if (maybe_win.* == win) {
                maybe_win.* = null;
                if (self.active_window_count > 0) {
                    self.active_window_count -= 1;
                }
                self.allocator.destroy(win);
                break;
            }
        }
    }

    pub fn closeFirstWindow(self: *App) void {
        for (&self.windows) |*maybe_win| {
            if (maybe_win.*) |win| {
                win.close();
                break;
            }
        }
    }

    pub fn handleEvent(self: *App, ev: platform.Event) void {
        switch (ev) {
            .window => |wev| switch (wev) {
                .close_requested => {
                    self.closeFirstWindow();
                },
                .resized => {
                    const info = self.backend.windowInfo();
                    for (&self.windows) |*maybe_win| {
                        if (maybe_win.*) |win| {
                            win.bounds.size = info.size;
                            win.requestRender();
                        }
                    }
                },
                .focused, .unfocused => {},
            },
            .mouse, .key, .text, .scroll => {
                for (&self.windows) |*maybe_win| {
                    if (maybe_win.*) |win| win.handleEvent(ev);
                }
            },
        }
    }

    pub fn hasDirtyWindows(self: *const App) bool {
        for (&self.windows) |maybe_win| {
            if (maybe_win) |win| {
                if (win.dirty and !win.closed) return true;
            }
        }
        return false;
    }

    pub fn step(self: *App) bool {
        // 1. Poll events from backend into app's event queue
        self.backend.poll(&self.event_queue);
        const qlen = self.event_queue.len;

        // 2. Process events
        while (self.event_queue.pop()) |ev| {
            self.handleEvent(ev);
        }

        if (self.should_quit or self.active_window_count == 0) {
            return false;
        }

        // 3. Render dirty windows & present. Each window renders and
        // presents adjacently: glyph entries borrow atlas pool bytes that a
        // later window's render could evict, so present must follow render
        // before any other window paints.
        var presented: usize = 0;
        for (&self.windows) |*maybe_win| {
            if (maybe_win.*) |win| {
                // Pending key sequences expire on a tick budget; expiry
                // fires a remembered single-key action, if any.
                if (win.keymap.tick()) |action_name| win.fireAction(action_name);
                if (win.dirty and !win.closed) {
                    win.frame_id = self.step_count;
                    win.render();
                    self.backend.present(&win.scene, self.glyphPixels(), self.imagePixels());
                    presented += 1;
                }
            }
        }

        self.step_count += 1;
        zlog.log("app", "step {d}: {d} queued events, {d} presented", .{ self.step_count, qlen, presented });
        return !self.should_quit and self.active_window_count > 0;
    }

    pub fn run(self: *App, onOpen: ?*const fn (*App) void) void {
        zlog.log("app", "run: backend={s}", .{@tagName(self.backend.kind())});
        if (onOpen) |cb| {
            cb(self);
        }
        zlog.log("app", "run: {d} window(s) open, entering loop", .{self.active_window_count});
        while (self.step()) {
            if (self.should_quit or self.active_window_count == 0) break;
            if (self.backend.kind() == .null) {
                if (self.event_queue.len == 0 and !self.hasDirtyWindows()) {
                    break;
                }
            } else {
                self.backend.waitTimeoutNs(16_000_000);
            }
        }
    }
};

test "app lifecycle and window capacity" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), app.active_window_count);
    app.activate(true);
    try std.testing.expect(app.isActive());

    // Open windows up to limit
    var wins: [limits.MAX_WINDOWS]*Window = undefined;
    for (0..limits.MAX_WINDOWS) |i| {
        wins[i] = try app.openWindow(.{ .title = "Test" }, struct {
            fn noop(_: *Window, _: *gpu.Scene) void {}
        }.noop);
    }
    try std.testing.expectEqual(@as(usize, limits.MAX_WINDOWS), app.active_window_count);

    // Overflow should fail
    try std.testing.expectError(error.TooManyWindows, app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop));

    // Close one window and ensure a new one can be opened
    wins[0].close();
    try std.testing.expectEqual(@as(usize, limits.MAX_WINDOWS - 1), app.active_window_count);

    const replacement = try app.openWindow(.{ .title = "Replacement" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    try std.testing.expectEqualStrings("Replacement", replacement.title());
    try std.testing.expectEqual(@as(usize, limits.MAX_WINDOWS), app.active_window_count);
}

test "frame loop on null backend drives 3 frames and asserts scene contents" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    const FrameState = struct {
        frame: u32 = 0,

        fn render(ctx: ?*anyopaque, window: *Window, scene: *gpu.Scene) void {
            _ = window;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.frame += 1;

            switch (self.frame) {
                1 => {
                    _ = scene.push(.{
                        .x = 0,
                        .y = 0,
                        .w = 10,
                        .h = 10,
                        .color = color.Color.hex(0xFF0000),
                    });
                },
                2 => {
                    _ = scene.push(.{
                        .x = 5,
                        .y = 5,
                        .w = 20,
                        .h = 20,
                        .color = color.Color.hex(0x00FF00),
                    });
                    _ = scene.push(.{
                        .x = 25,
                        .y = 25,
                        .w = 15,
                        .h = 15,
                        .color = color.Color.hex(0x112233),
                    });
                },
                3 => {
                    _ = scene.push(.{
                        .x = 10,
                        .y = 10,
                        .w = 30,
                        .h = 30,
                        .color = color.Color.hex(0x0000FF),
                    });
                },
                else => {},
            }
        }
    };

    var state = FrameState{};
    const win = try app.openWindow(.{
        .title = "Frame Loop Test",
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 800, .h = 600 } },
    }, Renderer{
        .ptr = &state,
        .render_fn = FrameState.render,
    });

    // --- Frame 1 ---
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 1), state.frame);
    try std.testing.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);
    {
        const quads = win.scene.slice();
        try std.testing.expectEqual(@as(usize, 1), quads.len);
        try std.testing.expectEqual(@as(f32, 0), quads[0].x);
        try std.testing.expectEqual(@as(f32, 10), quads[0].w);
        try std.testing.expectEqual(color.Color.hex(0xFF0000), quads[0].color);
    }

    // --- Frame 2 ---
    win.requestRender();
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 2), state.frame);
    try std.testing.expectEqual(@as(u32, 2), app.getNullBackend().?.presents);
    {
        const quads = win.scene.slice();
        try std.testing.expectEqual(@as(usize, 2), quads.len);
        try std.testing.expectEqual(@as(f32, 5), quads[0].x);
        try std.testing.expectEqual(@as(f32, 20), quads[0].w);
        try std.testing.expectEqual(color.Color.hex(0x00FF00), quads[0].color);
        try std.testing.expectEqual(@as(f32, 25), quads[1].x);
        try std.testing.expectEqual(@as(f32, 15), quads[1].w);
        try std.testing.expectEqual(color.Color.hex(0x112233), quads[1].color);
    }

    // --- Frame 3 ---
    win.requestRender();
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 3), state.frame);
    try std.testing.expectEqual(@as(u32, 3), app.getNullBackend().?.presents);
    {
        const quads = win.scene.slice();
        try std.testing.expectEqual(@as(usize, 1), quads.len);
        try std.testing.expectEqual(@as(f32, 10), quads[0].x);
        try std.testing.expectEqual(@as(f32, 30), quads[0].w);
        try std.testing.expectEqual(color.Color.hex(0x0000FF), quads[0].color);
    }
}

test "non-dirty window skips render and present" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    var renders: u32 = 0;
    const S = struct {
        fn draw(ctx: ?*anyopaque, _: *Window, sc: *gpu.Scene) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
            _ = sc.push(.{ .x = 0, .y = 0, .w = 50, .h = 50, .color = color.Color.white });
        }
    };

    _ = try app.openWindow(.{}, Renderer{ .ptr = &renders, .render_fn = S.draw });

    // First frame renders
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 1), renders);
    try std.testing.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);

    // Second step without marking dirty should NOT re-render
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 1), renders);
    try std.testing.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);
}

test "close_requested event terminates frame loop when all windows closed" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    _ = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    try std.testing.expectEqual(@as(usize, 1), app.active_window_count);

    // Send close_requested via backend queue
    _ = app.getNullBackend().?.pushEvent(.{ .window = .close_requested });

    // Next step processes the event, closes the window, and returns false
    const cont = app.step();
    try std.testing.expect(!cont);
    try std.testing.expectEqual(@as(usize, 0), app.active_window_count);
}

test "app.run onOpen runs initial frame" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    const State = struct {
        var opened: bool = false;
        fn onOpen(a: *App) void {
            opened = true;
            _ = a.openWindow(.{ .title = "Run Win" }, struct {
                fn draw(_: *Window, sc: *gpu.Scene) void {
                    _ = sc.push(.{ .x = 0, .y = 0, .w = 100, .h = 100, .color = color.Color.white });
                }
            }.draw) catch unreachable;
        }
    };

    State.opened = false;
    app.run(State.onOpen);
    try std.testing.expect(State.opened);
    try std.testing.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);
}

test "app auto probe initializes available backend" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    const k = app.backend.kind();
    try std.testing.expect(k == .wayland or k == .x11 or k == .null);
}

test "app owns the font stack when system fonts exist" {
    const font_tables = @import("../fonts/root.zig").tables;
    if (!font_tables.FontconfigApi.isAvailable() or !font_tables.FreeTypeApi.isAvailable() or !font_tables.HarfBuzzApi.isAvailable()) return;
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    try std.testing.expect(app.fonts != null);
    try std.testing.expectEqual(@as(usize, 0), app.glyphPixels().len);
}
