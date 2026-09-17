//! Application orchestration, window management, and frame loop.

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");
const platform = @import("../platform/root.zig");
const gpu = @import("../gpu/root.zig");
const text_engine = @import("../fonts/text_engine.zig");
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
    /// Owned decoded-image pool (always present; empty until first image).
    /// Borrowed by windows/frames per render like the engine.
    image_cache: ?*images.Cache = null,
    /// Owned cozmic text engine. Created lazily on the first frame; init
    /// failure is non-fatal (text draws nothing) and counted in
    /// `cozmic_engine_failures`. The engine owns the glyph atlas, so it must
    /// be deinitialized before any window/frame that borrows it is reused.
    cozmic_engine: ?*text_engine.Engine = null,
    /// True once creation was attempted, so a failed init is not retried on
    /// every frame.
    cozmic_engine_attempted: bool = false,
    /// Failed cozmic engine inits (text stays empty). Observable.
    cozmic_engine_failures: u64 = 0,
    windows: [limits.MAX_WINDOWS]?*Window = @splat(null),
    active_window_count: usize = 0,
    next_window_id: u32 = 1,
    event_queue: platform.EventQueue = .{},
    should_quit: bool = false,
    is_active: bool = false,
    /// Monotonic frame counter for `ZUI_LOG` diagnostics (a stalled
    /// counter in the log pinpoints event-loop starvation hangs).
    step_count: u64 = 0,
    /// Frames rejected for scene overflow across all windows (each was
    /// replaced by the diagnostic placeholder before present).
    rejected_frames: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !App {
        var instance = try platform.createAuto(allocator, "ZUI Application", 800, 600);
        errdefer instance.deinit(allocator);
        const cache = try images.Cache.init(allocator);
        return .{
            .allocator = allocator,
            .backend = instance.handle(),
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = instance,
            .image_cache = cache,
        };
    }

    pub fn initHeadless(allocator: std.mem.Allocator) !App {
        const nb = try allocator.create(platform.null_backend.NullBackend);
        errdefer allocator.destroy(nb);
        nb.* = .{};
        const cache = try images.Cache.init(allocator);
        return .{
            .allocator = allocator,
            .backend = nb.backendHandle(),
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = .{ .null_backend = nb },
            .image_cache = cache,
        };
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, be: platform.Backend) App {
        return .{
            .allocator = allocator,
            .backend = be,
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = null,
            .image_cache = images.Cache.init(allocator) catch null,
        };
    }

    /// Lazily create (once) the App-owned cozmic engine. Returns null when
    /// creation already failed or host system fonts are unavailable — both
    /// non-fatal: text then draws nothing and the failure count stays
    /// observable.
    pub fn ensureCozmicEngine(self: *App) ?*text_engine.Engine {
        if (self.cozmic_engine) |engine| return engine;
        if (self.cozmic_engine_attempted) return null;
        self.cozmic_engine_attempted = true;
        const engine = text_engine.Engine.initSystem(self.allocator) catch |err| {
            self.cozmic_engine_failures += 1;
            zlog.log("cozmic", "text engine init failed: {s}; text draws nothing", .{@errorName(err)});
            return null;
        };
        self.cozmic_engine = engine;
        zlog.log("cozmic", "text engine ready ({d} faces)", .{engine.fs.db.len()});
        return engine;
    }

    fn provideCozmicEngine(raw: *anyopaque) ?*text_engine.Engine {
        const app: *App = @ptrCast(@alignCast(raw));
        return app.ensureCozmicEngine();
    }

    /// Atlas pixel pool backing the current frame's glyph entries (empty
    /// before the lazy engine init or after an init failure). Valid only
    /// until the next render mutates the atlas.
    pub fn glyphPixels(self: *App) []const u8 {
        if (self.cozmic_engine) |engine| return engine.glyphs.pixels[0..engine.glyphs.pixels_used];
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
                win.deinit();
                self.allocator.destroy(win);
                maybe_win.* = null;
            }
        }
        self.active_window_count = 0;
        self.entities.deinit();
        if (self.cozmic_engine) |engine| {
            engine.deinit();
            self.cozmic_engine = null;
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

    /// Completion producers must signal this after publishing ready work.
    /// EventQueue itself is UI-thread-owned and does not signal a wake.
    /// This does not make App/Window mutation thread-safe.
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
        // One native window per connection until per-window surfaces land
        // (plan M5). Null/headless keeps N logical windows for tests.
        if (self.backend.kind() != .null and self.liveWindowCount() > 0) {
            return error.MultipleNativeWindowsNotSupported;
        }
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
            .images = self.image_cache,
            .cozmic_engine_fn = provideCozmicEngine,
            .cozmic_engine_ctx = self,
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
        // Legacy immediate destroy; prefer close()+reapClosed(). Kept for
        // explicit teardown outside dispatch. Never call from inside an
        // event listener: use win.close() so dispatch can keep using self.
        for (&self.windows) |*maybe_win| {
            if (maybe_win.* == win) {
                maybe_win.* = null;
                if (self.active_window_count > 0) {
                    self.active_window_count -= 1;
                }
                win.deinit();
                self.allocator.destroy(win);
                break;
            }
        }
    }

    /// Live (non-null, non-closed) window count.
    pub fn liveWindowCount(self: *const App) usize {
        var n: usize = 0;
        for (&self.windows) |maybe_win| {
            if (maybe_win) |win| {
                if (!win.closed) n += 1;
            }
        }
        return n;
    }

    /// Destroy windows marked closed. Called at safe points in step()
    /// (after dispatch, after present); also callable directly in tests.
    pub fn reapClosed(self: *App) void {
        for (&self.windows) |*maybe_win| {
            if (maybe_win.*) |win| {
                if (win.closed) {
                    maybe_win.* = null;
                    if (self.active_window_count > 0) {
                        self.active_window_count -= 1;
                    }
                    win.deinit();
                    self.allocator.destroy(win);
                }
            }
        }
    }

    pub fn closeFirstWindow(self: *App) void {
        for (&self.windows) |*maybe_win| {
            if (maybe_win.*) |win| {
                if (win.closed) continue;
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
                            if (win.closed) continue;
                            win.bounds.size = info.size;
                            win.requestRender();
                        }
                    }
                },
                .focused, .unfocused => {},
            },
            .mouse, .key, .text, .composition, .scroll => {
                for (&self.windows) |*maybe_win| {
                    if (maybe_win.*) |win| {
                        if (win.closed) continue;
                        win.handleEvent(ev);
                    }
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

    /// Null means indefinite idle; zero means work is already ready. This
    /// computation never introduces a periodic idle deadline.
    pub fn nextWaitNs(self: *const App, now_ms: i64) ?u64 {
        if (self.should_quit or self.event_queue.len != 0 or self.entities.dirty or self.hasDirtyWindows()) return 0;
        var deadline: ?i64 = null;
        for (self.windows) |maybe_win| {
            const win = maybe_win orelse continue;
            if (win.closed) return 0;
            for ([_]?i64{ win.keymap.nextDeadlineMs(), win.nextFrameDeadlineMs(), win.render_deadline_ms }) |candidate| {
                if (candidate) |value| deadline = if (deadline) |old| @min(old, value) else value;
            }
        }
        const due = deadline orelse return null;
        return @as(u64, @intCast(@max(0, due -| now_ms))) *| 1_000_000;
    }

    pub fn step(self: *App) bool {
        return self.stepAt(Window.monotonicMs());
    }

    /// Explicit monotonic time for deterministic scheduler tests/embedding.
    pub fn stepAt(self: *App, now_ms: i64) bool {
        // Expire before input: late second keys must not complete a chord.
        for (self.windows) |maybe_win| {
            const win = maybe_win orelse continue;
            if (!win.closed) {
                if (win.keymap.expire(now_ms)) |action_name| win.fireAction(action_name);
            }
        }
        // 1. Poll events from backend into app's event queue
        self.backend.poll(&self.event_queue);
        const qlen = self.event_queue.len;

        // 2. Process events
        while (self.event_queue.pop()) |ev| {
            self.handleEvent(ev);
        }
        // Destroy windows closed during dispatch before further work.
        self.reapClosed();

        // 2b. Entity mutation outside a window context (Entity.update with
        // no window) only sets EntityStore.dirty. Fan out conservatively to
        // all live windows so the mutation visibly redraws. Clear before
        // rendering so invalidations during render schedule the next frame.
        if (self.entities.dirty) {
            self.entities.dirty = false;
            for (&self.windows) |*maybe_win| {
                if (maybe_win.*) |win| {
                    if (!win.closed) win.requestRender();
                }
            }
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
                if (win.closed) continue;
                if (win.render_deadline_ms) |due| {
                    if (due <= now_ms) {
                        win.render_deadline_ms = null;
                        win.dirty = true;
                    }
                }
                if (win.nextFrameDeadlineMs()) |due| {
                    if (due <= now_ms) {
                        win.last_animation_target_us = win.animation_deadline_us;
                        win.animation_deadline_us = null;
                        win.dirty = true;
                        const delta = if (win.last_animation_frame_ms) |last| now_ms - last else 0;
                        zlog.log("schedule", "window {d}: animation interval={d}ms target={d}us late={d}ms", .{ win.id, delta, win.animation_interval_us, now_ms - due });
                        win.last_animation_frame_ms = now_ms;
                    }
                }
                if (win.dirty and !win.closed) {
                    win.frame_id = self.step_count;
                    win.render();
                    if (win.frameRejected()) {
                        // The scene was partial; Window.render already
                        // substituted the complete diagnostic placeholder,
                        // so this present is honest. Count it here too so a
                        // log scan finds every rejection in one place.
                        self.rejected_frames += 1;
                        zlog.log("app", "step {d}: window {d} frame rejected for overflow ({d} dropped); presented placeholder", .{ self.step_count, win.id, win.scene.dropped_frame });
                    }
                    self.backend.present(&win.scene, self.glyphPixels(), self.imagePixels());
                    presented += 1;
                }
            }
        }
        // Destroy windows closed during render/callbacks; dispatch above
        // already finished using them.
        self.reapClosed();

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
        var idle_wakes: u64 = 0;
        var idle_wait_ms: i64 = 0;
        while (self.step()) {
            if (self.should_quit or self.active_window_count == 0) break;
            const before = Window.monotonicMs();
            const wait_ns = self.nextWaitNs(before);
            if (wait_ns != null and wait_ns.? == 0) continue;
            // Null has no blocking primitive. Return to the embedding host,
            // which can advance stepAt at the reported deadline; never spin.
            if (self.backend.kind() == .null) break;
            // Request an unbounded wait when idle. Existing backend limits
            // degrade this explicitly: X11/Wayland/Cocoa clamp to 1 s, Win32
            // has only a 4 ms Sleep (not an event wait). Linux also adds 4 ms
            // and wakeup only flushes. Removing those limits / supplying real
            // completion wake handles requires backend changes, out of scope
            // here. No refresh feedback exists yet: Window's cadence hook
            // defaults to 60 Hz, not a claim of native vsync synchronization.
            self.backend.waitTimeoutNs(wait_ns orelse std.math.maxInt(u64));
            if (wait_ns == null) {
                idle_wakes += 1;
                idle_wait_ms += @max(0, Window.monotonicMs() - before);
                const rate = @as(f64, @floatFromInt(idle_wakes)) * 1000 / @as(f64, @floatFromInt(@max(1, idle_wait_ms)));
                zlog.log("schedule", "idle wakes={d} waited={d}ms rate={d:.2}/s", .{ idle_wakes, idle_wait_ms, rate });
            }
        }
    }
};

test "scheduler idle has no deadline and queued input is immediately ready" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    try t.expectEqual(@as(?u64, 0), app.nextWaitNs(100));
    try t.expect(app.stepAt(100));
    for (0..1000) |i| try t.expect(app.nextWaitNs(@intCast(100 + i)) == null);
    try t.expect(app.event_queue.push(.{ .mouse = .{ .pos = .{}, .button = .left, .pressed = true } }));
    try t.expectEqual(@as(?u64, 0), app.nextWaitNs(200));
    try t.expect(app.stepAt(200));
    try t.expectEqual(@as(u32, 2), app.getNullBackend().?.presents);
    win.requestRenderAt(300);
    win.requestRenderAt(400); // later requests cannot postpone an earlier one
    try t.expectEqual(@as(?u64, 100_000_000), app.nextWaitNs(200));
    try t.expect(app.stepAt(299));
    try t.expectEqual(@as(u32, 2), app.getNullBackend().?.presents);
    try t.expectEqual(@as(?u64, 0), app.nextWaitNs(300));
    try t.expect(app.stepAt(300));
    try t.expectEqual(@as(u32, 3), app.getNullBackend().?.presents);
    try t.expect(app.nextWaitNs(300) == null);
}

test "key expiry participates in earliest deadline and fires once without frames" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    try t.expect(app.stepAt(100));
    try t.expect(win.bindKeystrokes("g", "single", null));
    try t.expect(win.bindKeystrokes("g g", "sequence", null));
    var fired: u32 = 0;
    win.actions[0] = .{ .name = "single", .listener = .{ .target = &fired, .call_fn = struct {
        fn call(raw: *anyopaque, _: *const @import("../elements/element.zig").ListenerPayload, _: *anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    }.call } };
    win.action_count = 1;
    try t.expect(win.keymap.dispatchAt(.{ .key = .g }, &.{}, 100) == null);
    try t.expectEqual(@as(?u64, 750_000_000), app.nextWaitNs(100));
    try t.expect(app.stepAt(849));
    try t.expectEqual(@as(u32, 0), fired);
    try t.expect(app.stepAt(850));
    try t.expectEqual(@as(u32, 1), fired);
    try t.expect(app.nextWaitNs(850) == null);
    try t.expect(app.stepAt(10_000));
    try t.expectEqual(@as(u32, 1), fired);
    try t.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);
}

test "animation deadlines retain cadence, coalesce and skip missed frames" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    try t.expect(app.stepAt(100));
    win.animation_interval_us = 8333;
    win.requestAnimationAt(100);
    win.requestAnimationAt(101);
    try t.expect(!win.dirty);
    try t.expectEqual(@as(?i64, 109), win.nextFrameDeadlineMs());
    try t.expectEqual(@as(?u64, 9_000_000), app.nextWaitNs(100));
    try t.expect(app.stepAt(108));
    try t.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);
    try t.expect(app.stepAt(109));
    try t.expectEqual(@as(u32, 2), app.getNullBackend().?.presents);
    try t.expect(app.nextWaitNs(109) == null); // one shot
    win.requestAnimationAt(109);
    try t.expectEqual(@as(?i64, 117), win.nextFrameDeadlineMs());
    try t.expect(app.stepAt(200)); // slow frame, not a catch-up burst
    win.requestAnimationAt(200);
    try t.expect(win.nextFrameDeadlineMs().? > 200);
    win.close();
    app.reapClosed();
    try t.expect(app.nextWaitNs(200) == null);
}

test "run forwards nearest deadline to platform wait" {
    const t = std.testing;
    var nb = platform.null_backend.NullBackend{};
    var vtable = nb.backendHandle().vtable.*;
    const Harness = struct {
        var timeout: u64 = 0;
        fn kind(_: *anyopaque) platform.BackendKind {
            return .web;
        }
        fn wait(ptr: *anyopaque, ns: u64) void {
            timeout = ns;
            const backend: *platform.null_backend.NullBackend = @ptrCast(@alignCast(ptr));
            _ = backend.pushEvent(.{ .window = .close_requested });
        }
        fn draw(w: *Window, _: *gpu.Scene) void {
            w.requestRenderAt(w.timeMs() + 5000);
        }
    };
    Harness.timeout = 0;
    vtable.kind = Harness.kind;
    vtable.waitTimeoutNs = Harness.wait;
    var app = App.initWithBackend(t.allocator, .{ .ptr = &nb, .vtable = &vtable });
    defer app.deinit();
    _ = try app.openWindow(.{}, Harness.draw);
    app.run(null);
    try t.expect(Harness.timeout > 0 and Harness.timeout <= 5_000_000_000);
    try t.expectEqual(@as(u32, 1), nb.presents);
}

test "run passes idle sentinel to platform and wakes on input" {
    const t = std.testing;
    var nb = platform.null_backend.NullBackend{};
    const base = nb.backendHandle();
    var vtable = base.vtable.*;
    const Harness = struct {
        var waits: usize = 0;
        var timeout: u64 = 0;
        fn kind(_: *anyopaque) platform.BackendKind {
            return .web;
        }
        fn wait(ptr: *anyopaque, ns: u64) void {
            waits += 1;
            timeout = ns;
            const backend: *platform.null_backend.NullBackend = @ptrCast(@alignCast(ptr));
            _ = backend.pushEvent(.{ .window = .close_requested });
        }
    };
    Harness.waits = 0;
    vtable.kind = Harness.kind;
    vtable.waitTimeoutNs = Harness.wait;
    var app = App.initWithBackend(t.allocator, .{ .ptr = &nb, .vtable = &vtable });
    defer app.deinit();
    _ = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    app.run(null);
    try t.expectEqual(@as(usize, 1), Harness.waits);
    try t.expectEqual(std.math.maxInt(u64), Harness.timeout);
    try t.expectEqual(@as(u32, 1), nb.presents);
    try t.expectEqual(@as(usize, 0), app.liveWindowCount());
}

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

    // Close one window and ensure a new one can be opened. Close is
    // deferred: the slot frees on the reap sweep, not inside the call.
    wins[0].close();
    try std.testing.expect(wins[0].isClosed());
    try std.testing.expectEqual(@as(usize, limits.MAX_WINDOWS), app.active_window_count);
    app.reapClosed();
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

test "overflowed frame presents the placeholder and counts the rejection" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    const S = struct {
        fn draw(_: ?*anyopaque, _: *Window, sc: *gpu.Scene) void {
            var i: usize = 0;
            while (i < gpu.scene.MAX_COMMANDS_PER_FRAME + 5) : (i += 1) {
                _ = sc.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = color.Color.white });
            }
        }
    };
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 50, .h = 40 } },
    }, Renderer{ .ptr = null, .render_fn = S.draw });

    try std.testing.expect(app.step());
    // Rejected at the window, counted at the app, and the backend still
    // got exactly one COMPLETE frame (the 2-quad placeholder).
    try std.testing.expect(win.frameRejected());
    try std.testing.expectEqual(@as(u64, 1), win.rejected_frames);
    try std.testing.expectEqual(@as(u64, 1), app.rejected_frames);
    try std.testing.expectEqual(@as(u32, 1), app.getNullBackend().?.presents);
    try std.testing.expectEqual(@as(usize, 2), win.scene.slice().len);
    try std.testing.expectEqual(@as(f32, 50), win.scene.slice()[0].w);
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

test "app owns no font stack; the engine owns the atlas" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    // No font stack exists any more and the engine is lazy: nothing to
    // upload until the first render installs it.
    try std.testing.expect(app.cozmic_engine == null);
    try std.testing.expectEqual(@as(usize, 0), app.glyphPixels().len);
}

test "cozmic engine wiring installs the App-owned engine" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{ .title = "Engine" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    // The window provider is always wired; creation is lazy and a host
    // without system fonts records a non-fatal failure (text draws nothing).
    try std.testing.expect(win.cozmic_engine_fn != null);
    const ctx = win.cozmic_engine_ctx orelse return error.TestUnexpectedResult;
    const engine = win.cozmic_engine_fn.?(ctx);
    if (engine) |e| {
        try std.testing.expect(e == app.cozmic_engine.?);
        try std.testing.expectEqual(@as(u64, 0), app.cozmic_engine_failures);
    } else {
        try std.testing.expectEqual(@as(u64, 1), app.cozmic_engine_failures);
    }
    // A second attempt is memoized: no new failures even without fonts.
    try std.testing.expectEqual(engine, app.ensureCozmicEngine());
    try std.testing.expectEqual(@as(u64, if (engine == null) 1 else 0), app.cozmic_engine_failures);
}

test "window teardown frees retained text layouts" {
    // Regression: `reapClosed`/`removeWindow` used to destroy the window
    // without clearing the frame's measure→paint layouts, leaking a shaped
    // cozmic buffer per window torn down before a paint. The testing
    // allocator fails this test unless `Window.deinit` frees the entry.
    const t = std.testing;
    const elements = @import("../elements/root.zig");

    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const engine = text_engine.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();

    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    // Build and measure text on the window frame but stop before paint, so
    // the retained layout is still live when the window is torn down.
    const frame = &win.ui_frame;
    frame.reset(win, .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    elements.element.beginFrame(frame);
    const root = elements.text("retained layout", .{ .size = 14 });
    elements.layout.layout(frame, root, .{ .w = 200, .h = 60 });
    try t.expect(frame.nodes[root.index].cozmic_layout != null);
    elements.element.endFrame();

    win.close();
    app.reapClosed();
    try t.expectEqual(@as(usize, 0), app.active_window_count);
}

test "close defers destruction until reap" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    const win = try app.openWindow(.{ .title = "Deferred" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    win.close();
    // Still allocated: events are ignored but the pointer stays valid.
    try std.testing.expect(win.isClosed());
    try std.testing.expectEqual(@as(usize, 1), app.active_window_count);
    win.handleEvent(.{ .mouse = .{
        .pos = .{ .x = 0, .y = 0 },
        .button = .left,
        .pressed = true,
    } });
    app.reapClosed();
    try std.testing.expectEqual(@as(usize, 0), app.active_window_count);
}

test "entity update outside events schedules a render" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    var renders: u32 = 0;
    const S = struct {
        fn draw(ctx: ?*anyopaque, _: *Window, sc: *gpu.Scene) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
            _ = sc.push(.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = color.Color.white });
        }
    };
    _ = try app.openWindow(.{}, Renderer{ .ptr = &renders, .render_fn = S.draw });

    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 1), renders);
    // Idle step renders nothing.
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 1), renders);

    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *runtime.Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    const e = app.entities.create(Counter, .{}, null);
    e.update(struct {
        fn bump(v: *Counter) void {
            v.n += 1;
        }
    }.bump);
    try std.testing.expectEqual(@as(u32, 1), e.read().n);
    // No window was touched, but the store dirty bit must fan out.
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 2), renders);
}

test "requestRender during render schedules another frame" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();

    const S = struct {
        var calls: u32 = 0;
        fn draw(_: ?*anyopaque, w: *Window, sc: *gpu.Scene) void {
            _ = sc.push(.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = color.Color.white });
            calls += 1;
            if (calls == 1) w.requestRender();
        }
    };
    S.calls = 0;
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            S.draw(null, w, sc);
        }
    }.draw);

    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 1), S.calls);
    // The in-render invalidation survived instead of being swallowed.
    try std.testing.expect(win.dirty);
    try std.testing.expect(app.step());
    try std.testing.expectEqual(@as(u32, 2), S.calls);
}
