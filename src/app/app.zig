//! Application orchestration, window management, and frame loop.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");
const platform = @import("../platform/root.zig");
const gpu = @import("../gpu/root.zig");
const text_engine = @import("../fonts/text_engine.zig");
const window_mod = @import("window.zig");
const runtime = @import("runtime.zig");
const tasks = @import("tasks.zig");
const zlog = @import("../core/log.zig");
const images = @import("../images/root.zig");

pub const Window = window_mod.Window;
pub const WindowOptions = window_mod.WindowOptions;
pub const Renderer = window_mod.Renderer;
pub const TimerId = tasks.TimerId;

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
    /// Accessibility/user preference: decorative motion snaps to its target
    /// and does not request animation frames when enabled.
    reduce_motion: bool = false,
    /// Optional embedding override used by native integrations and tests;
    /// environment selection remains the default public behavior.
    renderer_mode_override: ?gpu.render_backend.Mode = null,
    /// Scoped background executor (gap §6D): worker pool + UI-thread
    /// completion queue. Heap-owned so the address workers and the asset
    /// registry observe stays stable when an App value moves (init returns
    /// by copy; only the final owner deinits). Null only when the box
    /// allocation failed — the registry then stays synchronous-pending.
    /// Drained at step start, joined in deinit before entity/cache teardown.
    tasks: ?*tasks.TaskRuntime = null,
    /// Heap-owned backend copy feeding the cross-thread task-completion
    /// wakeup. Borrowed by `tasks` until tasks.deinit; freed here after.
    task_wakeup_backend: ?*platform.Backend = null,
    /// Monotonic frame counter for `ZUI_LOG` diagnostics (a stalled
    /// counter in the log pinpoints event-loop starvation hangs).
    step_count: u64 = 0,
    /// Frames rejected for scene overflow across all windows (each was
    /// replaced by the diagnostic placeholder before present).
    rejected_frames: u64 = 0,

    /// Retains diagnostics when windows close before App.deinit.
    retired_diagnostics: @import("../debug/stats.zig").Totals = .{},

    pub fn diagnostics(self: *const App) @import("../debug/stats.zig").Snapshot {
        return @import("../debug/stats.zig").capture(self);
    }

    pub fn init(allocator: std.mem.Allocator) !App {
        var instance = try platform.createAuto(allocator, "ZUI Application", 800, 600);
        errdefer instance.deinit(allocator);
        const cache = try images.Cache.init(allocator);
        errdefer cache.deinit(allocator);
        const rt = try allocator.create(tasks.TaskRuntime);
        errdefer allocator.destroy(rt);
        rt.* = tasks.TaskRuntime.init(allocator, tasks.Options.fromEnv());
        rt.start();
        const wakeup_box = try allocator.create(platform.Backend);
        errdefer allocator.destroy(wakeup_box);
        const app: App = .{
            .allocator = allocator,
            .backend = instance.handle(),
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = instance,
            .image_cache = cache,
            .reduce_motion = reduceMotionFromEnv(),
            .tasks = rt,
            .task_wakeup_backend = wakeup_box,
        };
        wakeup_box.* = app.backend;
        rt.setWakeup(taskWakeup, wakeup_box);
        cache.assets.bindRuntime(rt);
        return app;
    }

    pub fn initHeadless(allocator: std.mem.Allocator) !App {
        const nb = try allocator.create(platform.null_backend.NullBackend);
        errdefer allocator.destroy(nb);
        nb.* = .{};
        const cache = try images.Cache.init(allocator);
        errdefer cache.deinit(allocator);
        const rt = try allocator.create(tasks.TaskRuntime);
        errdefer allocator.destroy(rt);
        rt.* = tasks.TaskRuntime.init(allocator, tasks.Options.fromEnv());
        rt.start();
        const wakeup_box = try allocator.create(platform.Backend);
        errdefer allocator.destroy(wakeup_box);
        const app: App = .{
            .allocator = allocator,
            .backend = nb.backendHandle(),
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = .{ .null_backend = nb },
            .image_cache = cache,
            .reduce_motion = reduceMotionFromEnv(),
            .tasks = rt,
            .task_wakeup_backend = wakeup_box,
        };
        wakeup_box.* = app.backend;
        rt.setWakeup(taskWakeup, wakeup_box);
        cache.assets.bindRuntime(rt);
        return app;
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, be: platform.Backend) App {
        // Infallible constructor: allocation failures degrade instead of
        // failing (a null image cache and/or null task runtime both have
        // well-defined degraded behavior: sync-pending asset registry).
        const cache = images.Cache.init(allocator) catch null;
        const rt: ?*tasks.TaskRuntime = allocator.create(tasks.TaskRuntime) catch null;
        var wakeup_box: ?*platform.Backend = null;
        if (rt) |r| {
            r.* = tasks.TaskRuntime.init(allocator, tasks.Options.fromEnv());
            r.start();
            if (cache) |c| c.assets.bindRuntime(r);
            if (allocator.create(platform.Backend) catch null) |box| {
                box.* = be;
                wakeup_box = box;
                r.setWakeup(taskWakeup, box);
            }
        }
        return .{
            .allocator = allocator,
            .backend = be,
            .entities = runtime.EntityStore.init(allocator),
            .owned_backend = null,
            .image_cache = cache,
            .reduce_motion = reduceMotionFromEnv(),
            .tasks = rt,
            .task_wakeup_backend = wakeup_box,
        };
    }

    fn taskWakeup(raw: *anyopaque) void {
        const be: *platform.Backend = @ptrCast(@alignCast(raw));
        be.wakeup();
    }

    fn reduceMotionFromEnv() bool {
        if (!builtin.link_libc) return false;
        const raw = std.c.getenv("ZUI_REDUCE_MOTION") orelse return false;
        const value = std.mem.span(raw);
        return value.len > 0 and !std.mem.eql(u8, value, "0");
    }

    /// Update the motion policy for all live windows and redraw them once so
    /// animated values snap visibly when the setting changes.
    pub fn setReduceMotion(self: *App, enabled: bool) void {
        self.reduce_motion = enabled;
        for (self.windows) |maybe_win| {
            if (maybe_win) |win| if (!win.closed) win.setReduceMotion(enabled);
        }
    }

    pub fn setRendererMode(self: *App, mode: gpu.render_backend.Mode) void {
        self.renderer_mode_override = mode;
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
        if (self.cozmic_engine) |engine| return engine.glyphs.pixels[0..engine.glyphs.storageUsed()];
        return &.{};
    }

    /// Image-cache pool backing the current frame's image entries (empty
    /// without a cache). Same lifetime rule as the glyph pool.
    pub fn imagePixels(self: *App) []const u8 {
        if (self.image_cache) |ic| return ic.pool[0..ic.used];
        return &.{};
    }

    pub fn deinit(self: *App) void {
        // TaskRuntime owns the token allocations, while Window teardown is
        // intentionally below. Detach first so Window.deinit cannot touch a
        // token after the runtime releases it.
        if (self.tasks != null) {
            for (&self.windows) |*maybe_win| {
                if (maybe_win.*) |win| {
                    win.invalidateLiveness();
                    win.detachLivenessToken();
                }
            }
        }
        // Task workers join here while entities and the image cache are
        // still alive: finished completions deliver (stale targets no-op),
        // unstarted jobs are destroyed without running. Must precede all
        // teardown below; the runtime box and wakeup box free right after
        // (no worker can signal once joined).
        if (self.tasks) |rt| {
            rt.deinit();
            self.allocator.destroy(rt);
            self.tasks = null;
        }
        if (self.task_wakeup_backend) |box| {
            self.allocator.destroy(box);
            self.task_wakeup_backend = null;
        }
        @import("../debug/stats.zig").logExit(self);
        for (&self.windows) |*maybe_win| {
            if (maybe_win.*) |win| {
                self.retired_diagnostics.add(win.diagnosticTotals());
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

    /// Schedule a one-shot application callback on the UI thread. This is
    /// the runtime-level timer primitive; window animation deadlines remain
    /// separate because they are compositor/frame-source driven.
    pub fn scheduleAt(self: *App, due_ms: i64, callback: tasks.TimerCallback, ctx: *anyopaque) !TimerId {
        return (self.tasks orelse return error.TaskRuntimeUnavailable).scheduleAt(due_ms, callback, ctx);
    }

    /// Schedule relative to the same monotonic clock used by `stepAt`.
    pub fn scheduleAfter(self: *App, delay_ms: i64, callback: tasks.TimerCallback, ctx: *anyopaque) !TimerId {
        return (self.tasks orelse return error.TaskRuntimeUnavailable).scheduleAfter(Window.monotonicMs(), delay_ms, callback, ctx);
    }

    pub fn cancelTimer(self: *App, id: TimerId) bool {
        return if (self.tasks) |rt| rt.cancelTimer(id) else false;
    }

    fn osBackend(raw: *anyopaque) platform.Backend {
        const win: *Window = @ptrCast(@alignCast(raw));
        return win.native_backend.?;
    }

    fn osSetTitle(raw: *anyopaque, title: []const u8) void {
        osBackend(raw).setTitle(title);
    }
    fn osSetCursor(raw: *anyopaque, shape: platform.CursorShape) void {
        osBackend(raw).setCursor(shape);
    }
    fn osGetClipboard(raw: *anyopaque, out: []u8) usize {
        return osBackend(raw).clipboardText(out);
    }
    fn osSetClipboard(raw: *anyopaque, text: []const u8) bool {
        return osBackend(raw).setClipboardText(text);
    }
    fn osDragWindow(raw: *anyopaque) void {
        osBackend(raw).dragWindow();
    }
    fn osMinimizeWindow(raw: *anyopaque) void {
        osBackend(raw).minimizeWindow();
    }
    fn osToggleMaximizeWindow(raw: *anyopaque) void {
        osBackend(raw).toggleMaximizeWindow();
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
        // Legacy backends have not yet split connection/window ownership.
        if (self.backend.vtable.createWindow == null and self.active_window_count > 0) {
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

        var liveness_token: ?*window_mod.WindowLivenessToken = null;
        if (self.tasks) |rt| {
            liveness_token = try rt.createWindowToken();
            errdefer rt.discardWindowToken(liveness_token.?);
        }

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);

        const bounds = options.bounds orelse geometry.Bounds{
            .origin = .{ .x = 0, .y = 0 },
            .size = self.backend.windowInfo().size,
        };

        if (bounds.size.w <= 0 or bounds.size.h <= 0 or !std.math.isFinite(bounds.size.w) or !std.math.isFinite(bounds.size.h) or bounds.size.w > 32768 or bounds.size.h > 32768) return error.InvalidWindowSize;
        const owns_native = self.backend.vtable.createWindow != null;
        const native = if (owns_native) try self.backend.createWindow(self.allocator, .{
            .id = self.next_window_id,
            .title = options.title,
            .width = @intFromFloat(bounds.size.w),
            .height = @intFromFloat(bounds.size.h),
            .decorated = options.chrome == .system,
        }) else self.backend;
        errdefer if (owns_native) native.destroyWindow();
        win.* = .{
            .native_backend = native,
            .owns_native_window = owns_native,
            .native_focused = native.windowInfo().focused,
            .scale_factor = native.windowInfo().scale_factor,
            .reduce_motion = self.reduce_motion,
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
                .ctx = win,
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
            .render_backend = gpu.render_backend.Controller.init(
                gpu.render_backend.select(
                    self.renderer_mode_override orelse gpu.render_backend.modeFromEnvironment(),
                    @import("build_options").gpu,
                    native.kind() == .wayland,
                    false,
                ),
                @intFromFloat(bounds.size.w),
                @intFromFloat(bounds.size.h),
            ),
            .images = self.image_cache,
            .cozmic_engine_fn = provideCozmicEngine,
            .cozmic_engine_ctx = self,
            .task_liveness = liveness_token,
        };
        win.scene.attachStrokeStorage(&win.stroke_storage);
        self.next_window_id += 1;

        // The environment only requests WGPU; activation requires a real
        // native surface and the optional GPU build. If either proof is
        // absent, the Window remains on its CPU backend without error.
        if (comptime @import("build_options").gpu) {
            if (win.render_backend.selection.requested == .wgpu) {
                if (native.nativeSurface()) |surface| {
                    if (gpu.app_bridge.Bridge.create(self.allocator, surface, @intFromFloat(bounds.size.w), @intFromFloat(bounds.size.h))) |gpu_bridge| {
                        if (!win.installGpuBridge(gpu_bridge, gpu_bridge.hooks(), gpu.app_bridge.Bridge.destroy)) {
                            gpu.app_bridge.Bridge.destroy(gpu_bridge, self.allocator);
                        }
                    } else |_| {
                        // A missing adapter, surface format, or native WGPU
                        // runtime is a supported CPU fallback, not a window
                        // creation failure.
                        zlog.log("gpu", "WGPU requested for window {d}, activation unavailable; using CPU", .{win.id});
                    }
                }
            }
        }

        win.inspector.enabled = @import("../debug/inspector.zig").environmentEnabled();
        win.setTitle(options.title);
        // Explicit bounds resize the native window to match (X11/Cocoa/
        // Win32 honor it; Wayland sizes via compositor configure instead).
        if (options.bounds) |explicit| {
            if (explicit.size.w > 0 and explicit.size.h > 0) {
                native.setSize(@intFromFloat(explicit.size.w), @intFromFloat(explicit.size.h));
            }
        }
        // Framed uses the OS titlebar; custom draws its own chrome.
        native.setDecorated(options.chrome == .system);

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
                win.invalidateLiveness();
                maybe_win.* = null;
                if (self.active_window_count > 0) {
                    self.active_window_count -= 1;
                }
                self.retired_diagnostics.add(win.diagnosticTotals());
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
                    win.invalidateLiveness();
                    maybe_win.* = null;
                    if (self.active_window_count > 0) {
                        self.active_window_count -= 1;
                    }
                    self.retired_diagnostics.add(win.diagnosticTotals());
                    // Window scope teardown (gap report §5.2): the mountView
                    // root and every entity created with this window die
                    // here, before the Window memory itself is freed.
                    self.entities.destroyWindowScope(win.id);
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
        const destination: ?u32 = if (ev == .targeted) ev.targeted.window_id else null;
        // Compatibility for legacy producers is deliberately single-window only.
        if (destination == null and self.liveWindowCount() != 1) return;
        for (self.windows) |maybe_win| {
            const win = maybe_win orelse continue;
            if (win.closed) continue;
            if (destination) |id| {
                if (win.id != id) continue;
            }
            const payload = ev.untargeted();
            switch (payload) {
                .window => |wev| switch (wev) {
                    .close_requested => win.close(),
                    .resized, .scale_changed => {
                        const info = win.native_backend.?.windowInfo();
                        win.bounds.size = info.size;
                        win.scale_factor = info.scale_factor;
                        win.render_backend.resize(@intFromFloat(@max(1, info.size.w)), @intFromFloat(@max(1, info.size.h)));
                        win.requestRender();
                    },
                    .frame_ready => win.animationFrameReady(),
                    .focused, .unfocused, .cancelled => win.handleEvent(payload),
                },
                else => win.handleEvent(payload),
            }
            return;
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
        const tasks_ready = if (self.tasks) |rt| rt.hasReady() else false;
        if (self.should_quit or self.event_queue.len != 0 or self.entities.dirty or self.hasDirtyWindows() or tasks_ready) return 0;
        var deadline: ?i64 = null;
        if (self.tasks) |rt| {
            if (rt.nextTimerDeadlineMs()) |value| deadline = value;
        }
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
        // Task completions marshal here, before input: worker results apply
        // to this frame's render, like drained events. Stamps the frame id
        // used for async cache pinning first.
        if (self.image_cache) |ic| ic.assets.completion_frame = self.step_count;
        if (self.tasks) |rt| rt.drainTimers(now_ms);
        if (self.tasks) |rt| rt.drainCompletions();
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
                    // §5G stage 2: upgrade the painter's 1x glyph masks to
                    // the window's density right before present. Paint and
                    // present are adjacent, so the scaled masks (which live
                    // in Engine.scaled_glyphs) cannot be evicted mid-frame;
                    // the next window's render resets it first. Backend
                    // renderers read scene glyph density per glyph.
                    if (win.cozmic_engine_fn) |provide| {
                        if (provide(win.cozmic_engine_ctx orelse win)) |engine| {
                            engine.scaleScene(&win.scene, win.scale_factor);
                        }
                    }
                    win.present(self.glyphPixels(), self.imagePixels());
                    presented += 1;
                }
            }
        }
        // Destroy windows closed during render/callbacks; dispatch above
        // already finished using them.
        self.reapClosed();
        // AccessKit action drain (gap §5C): AT requests (click/increment/
        // set_value/focus) queued from platform threads run on the UI
        // thread against each window's CURRENT semantic tree.
        for (self.windows) |maybe_win| {
            const win = maybe_win orelse continue;
            if (win.closed) continue;
            win.a11y_bridge.drain(win);
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
            // Request an unbounded wait when idle. Display backends clamp
            // pathological values defensively; native message/socket waits
            // still wake for input and task notifications. No refresh
            // feedback exists yet: Window's cadence hook defaults to 60 Hz,
            // not a claim of native vsync synchronization.
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

test "headless renderer override keeps CPU fallback when WGPU is unavailable" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    app.setRendererMode(.wgpu);
    const win = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    try t.expectEqual(gpu.render_backend.Mode.wgpu, win.renderBackend().selection.requested);
    try t.expect(win.renderBackend().usingCpu());
    try t.expectEqual(gpu.render_backend.Selection.Reason.gpu_not_compiled, win.renderBackend().selection.reason);
}

test "app timer wakes the event loop and fires on the UI step" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    _ = try app.openWindow(.{}, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    // Opening a window intentionally marks its first frame dirty. Consume
    // that initial presentation before asserting the timer-only deadline;
    // nextWaitNs must still return zero while a frame is pending.
    try t.expect(app.stepAt(100));

    var fired: u32 = 0;
    const callback = struct {
        fn call(raw: *anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    }.call;
    _ = try app.scheduleAt(250, callback, &fired);
    try t.expectEqual(@as(?u64, 150_000_000), app.nextWaitNs(100));
    try t.expect(app.stepAt(249));
    try t.expectEqual(@as(u32, 0), fired);
    try t.expect(app.stepAt(250));
    try t.expectEqual(@as(u32, 1), fired);
    try t.expect(app.nextWaitNs(250) == null);
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

test "multiwindow: two headless windows keep independent state and routes" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();

    const win_a = try app.openWindow(.{ .title = "Alpha", .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 320, .h = 240 } } }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const win_b = try app.openWindow(.{ .title = "Beta", .bounds = .{ .origin = .{ .x = 340, .y = 0 }, .size = .{ .w = 640, .h = 480 } } }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    try t.expect(win_a.id != win_b.id);

    const nb = app.getNullBackend().?;
    const native_a = nb.windows[0].?;
    const native_b = nb.windows[1].?;
    try t.expect(native_a != native_b);
    try t.expect(native_a.parent == nb);
    try t.expect(native_b.parent == nb);
    try t.expectEqualStrings("Alpha", native_a.title_buf[0..native_a.title_len]);
    try t.expectEqualStrings("Beta", native_b.title_buf[0..native_b.title_len]);
    try t.expectEqual(@as(f32, 320), native_a.size.w);
    try t.expectEqual(@as(f32, 640), native_b.size.w);
    try t.expectEqual(@as(u32, 0), native_a.presents);
    try t.expectEqual(@as(u32, 0), native_b.presents);

    // Renaming one window cannot touch the other's native title.
    win_a.setTitle("Alpha 2");
    try t.expectEqualStrings("Alpha 2", native_a.title_buf[0..native_a.title_len]);
    try t.expectEqualStrings("Beta", native_b.title_buf[0..native_b.title_len]);

    // Independent focus + scale state per window-scoped backend.
    native_b.scale_factor = 2;
    native_b.focused = false;
    try t.expectEqual(@as(f32, 1), native_a.backendHandle().windowInfo().scale_factor);
    try t.expectEqual(@as(f32, 2), native_b.backendHandle().windowInfo().scale_factor);
    try t.expect(native_a.backendHandle().windowInfo().focused);
    try t.expect(!native_b.backendHandle().windowInfo().focused);

    // Per-window presents: each window renders into its own backend surface.
    try t.expect(app.step());
    try t.expectEqual(@as(u32, 1), native_a.presents);
    try t.expectEqual(@as(u32, 1), native_b.presents);
    try t.expectEqual(@as(u32, 2), nb.presents);
}

test "multiwindow: input targets exactly the destination window" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();

    const win_a = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const win_b = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    // Both render once: per-window surfaces, connection-aggregated count.
    try t.expect(app.step());
    const nb = app.getNullBackend().?;
    const presents_a_before = nb.windows[0].?.presents;
    const presents_b_before = nb.windows[1].?.presents;

    // A key event for B's id must not reach A's scene (no render, no wake).
    _ = nb.windows[1].?.pushEvent(.{ .key = .{ .key = .b, .pressed = true } });
    _ = nb.windows[0].?.pushEvent(.{ .key = .{ .key = .a, .pressed = true } });
    try t.expect(app.step());
    // Unknown destinations are dropped silently and safely.
    _ = nb.pushEvent(.{ .targeted = .{ .window_id = 999, .payload = .{ .key = .{ .key = .c, .pressed = true } } } });
    try t.expect(app.step());
    // A plain key press does not dirty a window: targeting shows up as zero
    // re-presents for both windows and nothing lost at the connection queue.
    try t.expectEqual(presents_a_before, nb.windows[0].?.presents);
    try t.expectEqual(presents_b_before, nb.windows[1].?.presents);
    try t.expectEqual(@as(u64, 0), nb.queue.dropped);
    _ = win_a;
    _ = win_b;
}

test "multiwindow: close_requested closes only its destination" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();

    const win_a = try app.openWindow(.{ .title = "A" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const win_b = try app.openWindow(.{ .title = "B" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    // Both render once; the connection aggregates per-window presents.
    try t.expect(app.step());
    const presents_after_first = app.getNullBackend().?.presents;
    const nb = app.getNullBackend().?;

    // A close event routed to B's id closes only B. step()
    // reaps at its safe points, so B's Window object is freed when step
    // returns; liveness is observed through App and connection state.
    _ = nb.pushEvent(.{ .targeted = .{ .window_id = win_b.id, .payload = .{ .window = .close_requested } } });
    try t.expect(app.step());
    try t.expectEqual(@as(usize, 1), app.liveWindowCount());
    try t.expect(!win_a.isClosed());
    try t.expectEqualStrings("A", app.windows[0].?.title());

    const survivor = app.windows[0].?;
    try t.expect(survivor.id == win_a.id);
    survivor.requestRender();
    try t.expect(app.step());
    try t.expectEqual(presents_after_first + 1, nb.presents);

    // Closing the last window ends the scheduler: step reports false.
    _ = nb.windows[0].?.pushEvent(.{ .window = .close_requested });
    try t.expect(!app.step());
    try t.expectEqual(@as(usize, 0), app.liveWindowCount());
    for (nb.windows) |slot| try t.expect(slot == null);
}

test "multiwindow: resize and scale events stay per window" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();

    const win_a = try app.openWindow(.{ .title = "A", .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 400, .h = 300 } } }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const win_b = try app.openWindow(.{ .title = "B", .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 800, .h = 600 } } }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    const nb = app.getNullBackend().?;
    try t.expect(app.step());
    try t.expectEqual(@as(f32, 400), win_a.bounds.size.w);
    try t.expectEqual(@as(f32, 800), win_b.bounds.size.w);

    // Native resize of B only; A's bounds are untouched.
    nativeResize(nb.windows[1].?, 500, 400);
    _ = nb.windows[1].?.pushEvent(.{ .window = .resized });
    try t.expect(app.step());
    try t.expectEqual(@as(f32, 500), win_b.bounds.size.w);
    try t.expectEqual(@as(f32, 400), win_b.bounds.size.h);
    try t.expectEqual(@as(f32, 400), win_a.bounds.size.w);
    try t.expectEqual(@as(f32, 300), win_a.bounds.size.h);

    // Scale change is a per-window event: only B rescales.
    nb.windows[1].?.scale_factor = 1.5;
    _ = nb.windows[1].?.pushEvent(.{ .window = .scale_changed });
    try t.expect(app.step());
    try t.expectEqual(@as(f32, 1.5), win_b.scale_factor);
    try t.expectEqual(@as(f32, 1), win_a.scale_factor);
}

test "multiwindow: legacy untargeted events require exactly one live window" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();

    const win_a = try app.openWindow(.{ .title = "A" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const win_b = try app.openWindow(.{ .title = "B" }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    // With two live windows a legacy untargeted event is ambiguous: it is
    // dropped at routing, not broadcast to both.
    try t.expect(app.step());
    const rendered_before = win_a.render_count;
    const rendered_b_before = win_b.render_count;
    _ = app.getNullBackend().?.pushEvent(.{ .key = .{ .key = .a, .pressed = true } });
    _ = app.step();
    try t.expectEqual(rendered_before, win_a.render_count);
    try t.expectEqual(rendered_b_before, win_b.render_count);

    // A targeted variant of the same event still routes correctly.
    _ = app.getNullBackend().?.pushEvent(.{ .targeted = .{ .window_id = win_a.id, .payload = .{ .key = .{ .key = .a, .pressed = true } } } });
    try t.expect(app.step());
}

fn nativeResize(nb: *@import("../platform/null.zig").NullBackend, w: u32, h: u32) void {
    nb.size.w = @floatFromInt(w);
    nb.size.h = @floatFromInt(h);
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

test "app drives two live x11 windows with targeted input" {
    if (comptime !platform.is_linux) return;
    const x11 = platform.x11;
    if (!x11.X11Backend.isAvailable()) return;
    const t = std.testing;
    var instance = x11.X11Backend.init(t.allocator, "ZUI App Multi", 320, 200) catch |err| switch (err) {
        error.CannotOpenDisplay, error.NoDisplay => return,
        else => return err,
    };
    defer instance.deinit();

    var app = App.initWithBackend(t.allocator, instance.backendHandle());
    defer app.deinit();

    const win_a = try app.openWindow(.{ .title = "App A", .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 280, .h = 180 } } }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const win_b = try app.openWindow(.{ .title = "App B", .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 200, .h = 140 } } }, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    try t.expect(win_a.native_backend.?.ptr != win_b.native_backend.?.ptr);
    try t.expectEqualStrings("App A", win_a.title());
    try t.expectEqualStrings("App B", win_b.title());

    try t.expect(app.step());
    try t.expect(app.getNullBackend() == null); // x11, not null
    try t.expect(win_a.render_count >= 1);
    try t.expect(win_b.render_count >= 1);

    // Closing B (the deferred close path a WM close button takes) leaves A
    // alive, rendering, and presenting through its own surface.
    win_b.close();
    try t.expect(app.step());
    try t.expectEqual(@as(usize, 1), app.liveWindowCount());
    try t.expect(!win_a.isClosed());
    const renders_before = win_a.render_count;
    win_a.requestRender();
    try t.expect(app.step());
    try t.expectEqual(renders_before + 1, win_a.render_count);
}

test "app owns no font stack; the engine owns the atlas" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    // No font stack exists any more and the engine is lazy: nothing to
    // upload until the first render installs it.
    try std.testing.expect(app.cozmic_engine == null);
    try std.testing.expectEqual(@as(usize, 0), app.glyphPixels().len);
}

test "window at scale renders physical-density text and quads end to end" {
    // §5G stage 2 acceptance: through the REAL App.step wiring (render ->
    // scaleScene -> present), a 2x window (a) upgrades glyph masks to
    // per-glyph density 2 with sharp 2x raster sizes and (b) rasterizes a
    // logical 20x10 rect to 40x20 physical pixels.
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const DrawState = struct {
        count: u32 = 0,
        seed: @import("../gpu/scene.zig").Glyph,
        fn draw(ctx: ?*anyopaque, w: *Window, sc: *gpu.Scene) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.count += 1;
            _ = w;
            // Production order: the painter pushes after Window.render
            // clears; the callback runs at exactly that point.
            _ = sc.push(.{ .x = 5, .y = 5, .w = 20, .h = 10, .color = color.Color.white });
            _ = sc.pushGlyph(self.seed);
        }
    };
    var draw_state = DrawState{ .seed = undefined };
    const win = try app.openWindow(.{ .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 200, .h = 100 } } }, Renderer{ .ptr = &draw_state, .render_fn = DrawState.draw });
    const nb = app.getNullBackend().?;

    // Real corpus engine; font-independent (only mask sizes are asserted).
    // App owns it: app.deinit() frees it, so no local deinit here.
    const engine = text_engine.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    app.cozmic_engine = engine;
    app.cozmic_engine_attempted = true;

    // Seed one real painter-style 1x glyph (1x mask, logical origin) so
    // scaleScene has something to upgrade. The atlas entry persists in
    // engine.glyphs; the scene copy is pushed per frame by the draw
    // callback AFTER Window.render clears, exactly where production paint
    // runs.
    const layout = try engine.layout(t.allocator, "H", .{ .size = 16, .line_height = 20 }, null);
    var l = layout;
    defer l.deinit();
    var runs_iter = l.runs();
    var seeded: usize = 0;
    while (runs_iter.next()) |run| {
        for (run.glyphs) |glyph| {
            const physical = glyph.physical(0, 0, 1.0);
            const image = engine.cache.getImage(physical.cache_key) catch null orelse continue;
            if (image.content != .mask) continue;
            const entry = engine.glyphs.putBitmap(.{ .face_id = physical.cache_key.font_id, .glyph_id = physical.cache_key.glyph_id, .size_px = text_engine.sizeToPx(16), .x_bin = physical.cache_key.x_bin, .y_bin = physical.cache_key.y_bin, .font_weight = physical.cache_key.font_weight, .flags = physical.cache_key.flags }, image.placement.width, image.placement.height, image.placement.width, image.data.ptr, image.placement.left, image.placement.top, .mask, false) catch continue;
            // Painter placement convention (GlyphSink.glyph): the mask box
            // origin includes the bearing, y measured down from the baseline.
            draw_state.seed = .{ .x = 10 + @as(f32, @floatFromInt(entry.bearing_x)), .y = 20 - @as(f32, @floatFromInt(entry.bearing_y)), .w = entry.width, .h = entry.height, .color = color.Color.white, .atlas_offset = entry.offset, .clip = .{ .x = 0, .y = 0, .w = 200, .h = 100 } };
            seeded += 1;
            break;
        }
        if (seeded > 0) break;
    }
    try t.expect(seeded > 0);

    // Move the window to a 2x monitor before the frame.
    nb.windows[0].?.scale_factor = 2;
    win.scale_factor = 2;

    // App.step does the wiring: render() -> scaleScene() -> present() with
    // the renderer scale set. The present is a stub on null, so rasterize
    // the same post-scaleScene scene through vellz for pixel evidence.
    try t.expect(app.step());
    try t.expectEqual(@as(u32, 1), draw_state.count);
    const g = win.scene.glyphSlice()[0];
    try t.expectEqual(@as(f32, 2), g.density);
    // Re-rasterized at 32px, not stretched: hinted ink differs from 2x the
    // 16px mask (FreeType hinting is nonlinear: observed 11x12 -> 18x24).
    try t.expect(g.w > draw_state.seed.w and g.h > draw_state.seed.h);
    try t.expect(g.atlas_offset != draw_state.seed.atlas_offset); // new pool entry
    // Logical geometry untouched: the quad stays at its logical x (5, not
    // 10 physical) and the glyph pen position is preserved. The mask BOX
    // origin may shift sub-pixel when the higher-density raster has a
    // different bearing (scaleScene keeps ink aligned by pen position:
    // g.x += new_bearing/scale - old_bearing, always < 1 logical px).
    try t.expectEqual(@as(f32, 5), win.scene.slice()[0].x);
    try t.expectApproxEqAbs(draw_state.seed.x, g.x, 1.0);

    var pixels: [400 * 200 * 4]u8 = undefined;
    var renderer = gpu.vellz.Renderer.init(t.allocator);
    defer renderer.deinit();
    renderer.scale_factor = 2;
    try renderer.render(&pixels, 400, 200, .rgba32, color.Color.black, &win.scene, engine.glyphs.pixels[0..engine.glyphs.storageUsed()], &.{});
    // Physical ink at the scaled rect: 40x20 == 800 px, all opaque.
    // The upgraded glyph mask (physical box at 2x over density 2) is also
    // in the scene; pixels inside its physical box are skipped rather than
    // asserted so this test pins the QUAD mapping without coupling to the
    // glyph's hinted ink coverage.
    var ink: usize = 0;
    var stray_count: usize = 0;
    var stray: ?struct { x0: usize, y0: usize, x1: usize, y1: usize } = null;
    const gx0: i32 = @intFromFloat(@round(g.x * 2));
    const gy0: i32 = @intFromFloat(@round(g.y * 2));
    const gx1: i32 = gx0 + @as(i32, @intCast(g.w));
    const gy1: i32 = gy0 + @as(i32, @intCast(g.h));
    for (0..200) |y| {
        for (0..400) |x| {
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            const in_glyph = xi >= gx0 and xi < gx1 and yi >= gy0 and yi < gy1;
            if (x >= 10 and x < 50 and y >= 10 and y < 30) {
                try t.expectEqual(@as(u8, 255), pixels[(y * 400 + x) * 4]);
                ink += 1;
            } else if (!in_glyph) {
                if (pixels[(y * 400 + x) * 4] != 0) {
                    if (stray == null) stray = .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y };
                    const s = &stray.?;
                    s.x0 = @min(s.x0, x);
                    s.y0 = @min(s.y0, y);
                    s.x1 = @max(s.x1, x);
                    s.y1 = @max(s.y1, y);
                    stray_count += 1;
                }
            }
        }
    }
    if (stray) |s| {
        std.debug.print("stray ink: {d} px in box ({d},{d})-({d},{d}); quad=(10,10)-(30,20) glyph=({d},{d})-({d},{d})\n", .{ stray_count, s.x0, s.y0, s.x1, s.y1, gx0, gy0, gx1, gy1 });
        for (s.y0..s.y1 + 1) |yy| {
            if (yy >= 200) break;
            var xx = s.x0;
            while (xx <= s.x1 and xx < 400) : (xx += 1) {
                std.debug.print("({d},{d})={d} ", .{ xx, yy, pixels[(yy * 400 + xx) * 4] });
            }
            std.debug.print("\n", .{});
        }
    }
    try t.expectEqual(@as(usize, 0), stray_count);
    // (loop body end)
    try t.expectEqual(@as(usize, 40 * 20), ink);
    std.debug.print("dpi end-to-end: rect 20x10 logical -> physical (10,10)-(50,30) at 2x; glyph density={d}\n", .{g.density});
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

test "task completion drops a window target after close and reap" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const rt = app.tasks orelse return error.TestUnexpectedResult;
    if (rt.workerCount() == 0) return error.SkipZigTest;

    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *runtime.Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    // App-lifetime entity: it survives the window-scope reap, making the
    // window token (rather than the weak entity) the decisive gate.
    const entity = app.entities.create(Counter, .{}, null);
    const Gate = struct {
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        completions: u32 = 0,
    };
    var gate = Gate{};
    const State = struct { gate: *Gate };

    _ = try rt.spawnForEntity(
        Counter,
        entity.weak(),
        win,
        State{ .gate = &gate },
        struct {
            fn run(s: *State, _: tasks.Cancel) void {
                s.gate.started.store(true, .seq_cst);
                while (!s.gate.release.load(.seq_cst)) std.Thread.yield() catch {};
            }
        }.run,
        struct {
            fn done(_: *Counter, _: *runtime.Context(Counter), s: *State) void {
                s.gate.completions += 1;
            }
        }.done,
    );

    const Started = struct {
        fn ready(raw: *anyopaque) bool {
            const g: *Gate = @ptrCast(@alignCast(raw));
            return g.started.load(.seq_cst);
        }
    };
    var spin: usize = 0;
    while (!Started.ready(&gate) and spin < 20_000_000) : (spin += 1) {
        std.Thread.yield() catch {};
    }
    try t.expect(Started.ready(&gate));

    // The queued job still retains the old Window address, but close/reap
    // invalidates its stable token before that allocation is freed.
    win.close();
    app.reapClosed();
    try t.expectEqual(@as(usize, 0), app.active_window_count);
    gate.release.store(true, .seq_cst);

    const Ready = struct {
        fn ready(raw: *anyopaque) bool {
            return @as(*tasks.TaskRuntime, @ptrCast(@alignCast(raw))).readyCount() > 0;
        }
    };
    spin = 0;
    while (!Ready.ready(rt) and spin < 20_000_000) : (spin += 1) {
        std.Thread.yield() catch {};
    }
    try t.expect(Ready.ready(rt));
    rt.drainCompletions();

    try t.expectEqual(@as(u32, 0), gate.completions);
    try t.expectEqual(@as(u32, 0), entity.read().n);
    try t.expectEqual(@as(u64, 1), rt.dropped_stale);
    try t.expectEqual(@as(u64, 0), rt.delivered);
}

test "task runtime: close window mid-flight is safe" {
    // Gap §6D: an async asset read in flight while its window closes must
    // tear down without crashes or leaks (testing allocator enforces the
    // latter). The asset registry is app-scoped, so the delivery still
    // lands; only window-scoped entities are reaped.
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const icon = "<svg width=\"4\" height=\"2\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\" height=\"2\" fill=\"red\"/></svg>";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "thumb.svg", .data = icon });
    const path = try std.fs.path.join(t.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "thumb.svg" });
    defer t.allocator.free(path);

    // openWindow wired the runtime, so this spawns a real worker read.
    const cache = app.image_cache.?;
    const ticket = try cache.assets.requestPath(path);
    _ = ticket;

    win.close();
    app.reapClosed();
    try t.expectEqual(@as(usize, 0), app.liveWindowCount());

    // Step until the worker's delivery lands (bounded liveness wait;
    // correctness never depends on timing). step() returns false with no
    // windows but still drains completions first.
    var i: usize = 0;
    while (app.tasks.?.inFlight() > 0 and i < 20_000_000) : (i += 1) {
        _ = app.step();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 0), app.tasks.?.inFlight());
}
