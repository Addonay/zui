//! Window lifecycle, rendering target, and geometry bounds.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const color = @import("../core/color.zig");
const gpu = @import("../gpu/root.zig");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const text_engine = @import("../fonts/text_engine.zig");
const images = @import("../images/root.zig");
const keymap = @import("keymap.zig");
const zlog = @import("../core/log.zig");

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
    /// One-shot render timer and animation request, owned by this window.
    render_deadline_ms: ?i64 = null,
    animation_deadline_us: ?i64 = null,
    last_animation_target_us: ?i64 = null,
    last_animation_frame_ms: ?i64 = null,
    /// Display cadence hook. Native refresh feedback can set this value;
    /// current backend interface exposes none, so default explicitly to 60 Hz.
    animation_interval_us: u32 = 16_667,
    closed: bool = false,
    scene: gpu.Scene = .{},
    renderer: ?Renderer = null,
    /// Frames rejected for scene overflow since creation (overflowed scene
    /// replaced by the diagnostic placeholder; see `render`). A nonzero
    /// count means the user saw magenta, not missing content.
    rejected_frames: u64 = 0,
    /// True when the most recent `render()` rejected its frame. Cleared by
    /// the next render; lets `App.step` log/count without re-inspecting.
    last_frame_rejected: bool = false,
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
    /// Region armed by the last left press. Motion and release keep routing
    /// to it even when the pointer leaves its bounds (pointer capture).
    captured_mouse_region: ?elements.HitRegion = null,
    /// True while the left mouse button is held.
    left_button_down: bool = false,
    /// Set while dispatching the captured region's motion callback, so the
    /// drag source can tell that call apart from the hovered-region one.
    motion_from_capture: bool = false,
    /// Most recent scroll event delivered to this window, readable by the
    /// scroll listener that received it.
    last_scroll: platform.event.ScrollEvent = .{ .pos = .{ .x = 0, .y = 0 } },
    focused: elements.FocusHandle = .{},
    /// Optional borrowed focus scope; host owns its ids until popScope.
    focus_scope: ?@import("../widgets/focus.zig").Scope = null,
    keymap: keymap.Keymap = .{},
    /// Window-level context tags (outermost keymap frame, after "Window").
    context_tags: [4][]const u8 = undefined,
    context_tag_count: usize = 0,
    actions: [32]Action = undefined,
    action_count: usize = 0,

    /// Opt-in diagnostics; no extra wakeups or frame deadlines.
    inspector: @import("../debug/inspector.zig").Options = .{},
    debug_overlay: @import("../debug/inspector.zig").Overlay = .{},
    render_count: u64 = 0,
    frame_durations: @import("../debug/stats.zig").Durations = .{},
    total_layout_ns: u64 = 0,
    total_paint_ns: u64 = 0,
    overlay_skipped: u64 = 0,
    inspector_failures: u64 = 0,

    pub fn setInspector(self: *Window, options: @import("../debug/inspector.zig").Options) void {
        self.inspector = options;
        self.requestRender();
    }

    pub fn setDebugOverlay(self: *Window, options: @import("../debug/inspector.zig").Overlay) void {
        self.debug_overlay = options;
        self.requestRender();
    }

    pub fn diagnostics(self: *const Window) @import("../debug/stats.zig").WindowStats {
        return .{ .frames = self.render_count, .rejected_frames = self.rejected_frames, .scene = @import("../debug/stats.zig").SceneStats.capture(&self.scene), .durations = self.frame_durations, .dropped_regions = self.ui_frame.dropped_regions, .duplicate_keys = self.ui_frame.duplicate_keys, .overlay_skipped = self.overlay_skipped, .inspector_failures = self.inspector_failures };
    }

    pub fn diagnosticTotals(self: *const Window) @import("../debug/stats.zig").Totals {
        return .{ .frames = self.render_count, .rejected_frames = self.rejected_frames, .scene_dropped = self.scene.dropped, .dropped_regions = self.ui_frame.dropped_regions, .layout_ns = self.total_layout_ns, .paint_ns = self.total_paint_ns, .overlay_skipped = self.overlay_skipped, .inspector_failures = self.inspector_failures };
    }

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

    /// One-shot animation request. Re-request from render while active;
    /// unlike requestRender this does not make the window immediately dirty.
    pub fn requestAnimationFrame(self: *Window) void {
        self.requestAnimationAt(self.timeMs());
    }

    pub fn requestAnimation(self: *Window) void {
        self.requestAnimationFrame();
    }

    /// Host/display-feedback hook, in microseconds (e.g. 8333 for 120 Hz).
    /// Cadence is accumulated at sub-ms precision; waits round upward to ms.
    pub fn setAnimationIntervalUs(self: *Window, interval_us: u32) void {
        self.animation_interval_us = @max(interval_us, 1000);
        self.last_animation_target_us = null;
        self.animation_deadline_us = null;
        self.requestAnimationFrame();
    }

    pub fn requestAnimationAt(self: *Window, now_ms: i64) void {
        if (self.closed or self.animation_deadline_us != null) return;
        const now_us = now_ms *| 1000;
        const interval: i64 = self.animation_interval_us;
        var next = (self.last_animation_target_us orelse now_us) +| interval;
        // Skip missed frames, never burst to catch up after a slow render.
        if (next <= now_us) next +|= (@divFloor(now_us - next, interval) + 1) *| interval;
        self.animation_deadline_us = next;
        self.wakeup_fn(self.app);
    }

    pub fn nextFrameDeadlineMs(self: *const Window) ?i64 {
        const us = self.animation_deadline_us orelse return null;
        return @divFloor(us, 1000) + @as(i64, if (@mod(us, 1000) != 0) 1 else 0);
    }

    /// Earliest one-shot render timer wins. Closing the window cancels it.
    pub fn requestRenderAt(self: *Window, deadline_ms: i64) void {
        if (self.closed) return;
        if (self.render_deadline_ms) |old| {
            if (old <= deadline_ms) return;
        }
        self.render_deadline_ms = deadline_ms;
        self.wakeup_fn(self.app);
    }

    /// Monotonic clock in milliseconds, for animation progress.
    /// Windows has no clock_gettime, so it uses the performance counter;
    /// every other target uses CLOCK.MONOTONIC. (This snapshot's std.time
    /// carries only constants — no nanoTimestamp — hence the branch.)
    pub fn timeMs(self: *const Window) i64 {
        _ = self;
        return monotonicMs();
    }

    /// Portable monotonic milliseconds. The Windows branch is discarded at
    /// comptime on other targets (and vice versa), so neither side's
    /// OS-specific symbols leak into foreign builds.
    pub fn monotonicMs() i64 {
        if (builtin.target.os.tag == .windows) {
            var counter: std.os.windows.LARGE_INTEGER = undefined;
            var freq: std.os.windows.LARGE_INTEGER = undefined;
            if (std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq).toBool() and
                std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() and
                freq > 0)
            {
                return @divTrunc(counter * 1000, freq);
            }
            return 0;
        } else {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) == 0) {
                return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
            }
            return 0;
        }
    }

    /// Pointer position in window coordinates (updated on every mouse event).
    pub fn pointerPosition(self: *const Window) geometry.Point {
        return self.pointer_position;
    }

    /// True while the left mouse button is held.
    pub fn mouseIsDown(self: *const Window) bool {
        return self.left_button_down;
    }

    /// True while the captured (drag source) region is receiving the motion
    /// callback; false for the hovered region under the pointer.
    pub fn motionFromCapture(self: *const Window) bool {
        return self.motion_from_capture;
    }

    /// The scroll event that just reached a scroll listener.
    pub fn scrollEvent(self: *const Window) platform.event.ScrollEvent {
        return self.last_scroll;
    }

    pub fn markDirty(self: *Window) void {
        self.requestRender();
    }

    pub fn render(self: *Window) void {
        // Clear before user code so a requestRender() during rendering
        // schedules another frame instead of being swallowed.
        self.dirty = false;
        self.scene.clear();
        self.frame_durations = .{};
        self.render_count += 1;
        if (self.renderer) |r| {
            r.call(self, &self.scene);
        }
        // Frame overflow policy (gap report §3): an overflowed scene is
        // REJECTED, never presented partial. Substitute the diagnostic
        // placeholder so the backend always receives a complete frame;
        // the rejection stays observable via `rejected_frames`,
        // `last_frame_rejected`, and the scene's own drop counters.
        self.last_frame_rejected = false;
        if (self.scene.overflowed()) {
            const drops = self.scene.dropped_frame;
            self.rejected_frames += 1;
            self.last_frame_rejected = true;
            zlog.log("window", "frame rejected: {d} scene pushes dropped (window {d}); presenting overflow placeholder", .{ drops, self.id });
            self.scene.renderOverflowPlaceholder(self.bounds.rect());
        }
        self.total_layout_ns += self.frame_durations.layout_ns orelse 0;
        self.total_paint_ns += self.frame_durations.paint_ns orelse 0;
        // Snapshot application ink before optional debug ink changes counts.
        @import("../debug/inspector.zig").emit(self);
        if (!self.last_frame_rejected) {
            self.overlay_skipped += @import("../debug/inspector.zig").paintOverlay(&self.ui_frame, &self.scene, self.focused.id, self.debug_overlay);
        }
        // Regions were rebuilt above; refresh the cursor for a stationary
        // pointer sitting over changed content.
        self.updateHoverCursor();
    }

    /// True when the last `render()` rejected its frame for overflow.
    pub fn frameRejected(self: *const Window) bool {
        return self.last_frame_rejected;
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
        var entry: Action = .{ .name = name, .listener = target.actionListener(action) };
        // Entity targets carry their subscription inline (see Action), so
        // `fireAction` can skip actions whose owner was destroyed.
        if (@hasDecl(@TypeOf(target), "is_entity")) {
            entry.owner_store = target.header.store;
            entry.owner_id = target.header.id;
            entry.owner_generation = target.header.generation;
        }
        self.actions[self.action_count] = entry;
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
                    // The owner may have been destroyed while its region
                    // slot still exists: drop focus now instead of
                    // lingering on a dead handle.
                    if (!handle.isLive()) {
                        self.focused = .{};
                        return;
                    }
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
                if (mouse.motion) {
                    self.dispatchMouseMotion(mouse);
                } else if (mouse.pressed and mouse.button == .left) {
                    self.left_button_down = true;
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
                    // A modal scope preserves focus and rejects background hits.
                    const modal_scope = if (self.focus_scope) |scope| (if (scope.modal) scope else null) else null;
                    if (modal_scope == null) self.focused = .{};
                    var i = self.ui_frame.region_count;
                    while (i > 0) {
                        i -= 1;
                        const region = self.ui_frame.regions[i];
                        if (!region.bounds.contains(mouse.pos)) continue;
                        // Subscription cleanup (gap §5A): regions whose
                        // owning entity was destroyed are invisible to
                        // dispatch — no focus adoption, no listener, no
                        // capture — as if unmounted.
                        if (!region.ownerAlive()) continue;
                        if (modal_scope) |scope| {
                            const handle = region.focus orelse continue;
                            if (!scope.contains(handle.id)) continue;
                        }
                        if (region.focus) |handle| self.focused = handle;
                        if (region.mouse_down_listener) |listener| listener.call(self);
                        if (double_click) {
                            if (region.double_click_listener) |listener| listener.call(self);
                        }
                        if (region.listener) |listener| listener.call(self);
                        // Arm pointer capture so motion/release continue to
                        // reach this control after the pointer leaves it.
                        if (region.mouse_move_listener != null or region.mouse_up_listener != null) {
                            self.captured_mouse_region = region;
                        }
                        break;
                    }
                } else if (!mouse.pressed and mouse.button == .left) {
                    self.left_button_down = false;
                    self.dispatchMouseUp(mouse);
                    self.captured_mouse_region = null;
                }
                self.requestRender();
            },
            .key, .text, .composition => {
                // Tab is a foundation default action, not a widget shortcut.
                if (event == .key and event.key.key == .tab and !event.key.modifiers.ctrl and !event.key.modifiers.alt and !event.key.modifiers.super) {
                    if (event.key.pressed) _ = @import("../widgets/focus.zig").handleTab(self, event.key.modifiers.shift, self.focus_scope);
                    return;
                }
                if (self.focused.dispatch(event, self)) {
                    self.requestRender();
                    return;
                }
                switch (event) {
                    .key => |key_event| if (key_event.pressed) self.dispatchKeyAction(key_event.key, key_event.modifiers),
                    .text, .composition => {},
                    else => unreachable,
                }
            },
            .scroll => |scroll| {
                self.pointer_position = scroll.pos;
                self.updateHoverCursor();
                self.last_scroll = scroll;
                // Scroll goes to the topmost scrollable container under the
                // pointer; focused-element dispatch stays as the fallback.
                var handled = false;
                var i = self.ui_frame.region_count;
                while (i > 0) {
                    i -= 1;
                    const region = self.ui_frame.regions[i];
                    if (!region.bounds.contains(scroll.pos)) continue;
                    if (!region.ownerAlive()) continue;
                    if (region.scroll_listener) |listener| {
                        listener.call(self);
                        handled = true;
                        break;
                    }
                }
                if (!handled) {
                    _ = self.focused.dispatch(event, self);
                }
                self.requestRender();
            },
            .window => {},
        }
    }

    /// Motion: the topmost region under the pointer gets a move callback
    /// (hover tracking), and the captured region gets one too (drag source)
    /// unless it is the same target.
    fn dispatchMouseMotion(self: *Window, mouse: platform.event.MouseEvent) void {
        var hovered: ?elements.HitRegion = null;
        var i = self.ui_frame.region_count;
        while (i > 0) {
            i -= 1;
            const region = self.ui_frame.regions[i];
            if (!region.bounds.contains(mouse.pos)) continue;
            if (!region.ownerAlive()) continue;
            hovered = region;
            break;
        }
        if (hovered) |region| {
            if (region.mouse_move_listener) |listener| listener.call(self);
        }
        if (self.captured_mouse_region) |captured| {
            const same_target = if (hovered) |h|
                (h.mouse_move_listener != null and captured.mouse_move_listener != null and
                    h.mouse_move_listener.?.target == captured.mouse_move_listener.?.target)
            else
                false;
            // A captured region whose owner was destroyed ends the drag
            // silently: no further motion reaches the freed target.
            if (!same_target and captured.ownerAlive()) {
                self.motion_from_capture = true;
                defer self.motion_from_capture = false;
                if (captured.mouse_move_listener) |listener| listener.call(self);
            }
        }
    }

    /// Release: the captured region gets the up callback (drag end), and the
    /// topmost region under the pointer handles plain releases elsewhere.
    fn dispatchMouseUp(self: *Window, mouse: platform.event.MouseEvent) void {
        if (self.captured_mouse_region) |captured| {
            if (captured.ownerAlive()) {
                if (captured.mouse_up_listener) |listener| listener.call(self);
            }
            return;
        }
        var i = self.ui_frame.region_count;
        while (i > 0) {
            i -= 1;
            const region = self.ui_frame.regions[i];
            if (!region.bounds.contains(mouse.pos)) continue;
            if (!region.ownerAlive()) continue;
            if (region.mouse_up_listener) |listener| listener.call(self);
            break;
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
        const now_ms = self.timeMs();
        if (self.keymap.expire(now_ms)) |expired| self.fireAction(expired);
        if (self.closed) return;
        const action_name = self.keymap.dispatchAt(stroke, &stack, now_ms) orelse return;
        self.fireAction(action_name);
    }

    pub fn fireAction(self: *Window, action_name: []const u8) void {
        for (self.actions[0..self.action_count]) |action| {
            if (std.mem.eql(u8, action.name, action_name)) {
                // Window-level subscription cleanup (gap §5A): actions
                // owned by a destroyed entity never fire.
                if (action.owner_store) |store| {
                    if (elements.element.entity_is_alive_fn) |alive| {
                        if (!alive(store, action.owner_id, action.owner_generation)) return;
                    }
                }
                action.listener.call(self);
                return;
            }
        }
    }
};

const Action = struct {
    name: []const u8,
    listener: elements.Listener,
    /// Owning entity subscription, populated by `on_action` when the
    /// target is an entity. Heap-side (one Window, ≤32 actions), so the
    /// hot `Listener` struct stays lean.
    owner_store: ?*anyopaque = null,
    owner_id: u32 = 0,
    owner_generation: u32 = 0,
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

test "overflowed frame is rejected with a placeholder, never partial" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();

    const win = try app.openWindow(.{
        .title = "Overflow",
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 100, .h = 80 } },
    }, struct {
        fn draw(_: *Window, sc: *gpu.Scene) void {
            var i: usize = 0;
            while (i < gpu.scene.MAX_COMMANDS_PER_FRAME + 10) : (i += 1) {
                _ = sc.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = color.Color.white });
            }
        }
    }.draw);

    win.render();
    try std.testing.expect(win.frameRejected());
    try std.testing.expectEqual(@as(u64, 1), win.rejected_frames);
    // Placeholder, not partial: exactly the two diagnostic quads covering
    // the window, and the scene still reports the rejection it replaced.
    try std.testing.expectEqual(@as(usize, 2), win.scene.slice().len);
    try std.testing.expectEqual(@as(f32, 100), win.scene.slice()[0].w);
    try std.testing.expectEqual(@as(f32, 80), win.scene.slice()[0].h);
    try std.testing.expectEqual(@as(usize, 2), win.scene.commandSlice().len);
    try std.testing.expect(win.scene.overflowed());
    try std.testing.expectEqual(@as(u64, 10), win.scene.dropped);
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

var move_hits: u32 = 0;
var up_hits: u32 = 0;
var scroll_hits: u32 = 0;
var last_scroll_dy: f32 = 0;

fn countMove(_: *anyopaque, _: *const elements.element.ListenerPayload, _: *anyopaque) void {
    move_hits += 1;
}

fn countUp(_: *anyopaque, _: *const elements.element.ListenerPayload, _: *anyopaque) void {
    up_hits += 1;
}

fn countScroll(_: *anyopaque, _: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
    scroll_hits += 1;
    const w: *Window = @ptrCast(@alignCast(raw_window));
    last_scroll_dy = w.scrollEvent().dy;
}

fn resetCounters() void {
    move_hits = 0;
    up_hits = 0;
    scroll_hits = 0;
    last_scroll_dy = 0;
}

test "mouse motion reaches the region under the pointer" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);
    resetCounters();

    var marker: u8 = 0;
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .mouse_move_listener = .{ .target = @ptrCast(&marker), .call_fn = countMove },
    };

    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqual(@as(u32, 1), move_hits);
    // Outside every region: no dispatch.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 500, .y = 500 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqual(@as(u32, 1), move_hits);
}

test "press captures motion and release outside the source region" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);
    resetCounters();

    var marker: u8 = 0;
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 },
        .mouse_move_listener = .{ .target = @ptrCast(&marker), .call_fn = countMove },
        .mouse_up_listener = .{ .target = @ptrCast(&marker), .call_fn = countUp },
    };

    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try std.testing.expect(win.mouseIsDown());
    // Motion far outside still reaches the captured region (drag source).
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 900, .y = 900 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqual(@as(u32, 1), move_hits);
    // Release outside still ends the drag on the captured region.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 900, .y = 900 }, .button = .left, .pressed = false } });
    try std.testing.expectEqual(@as(u32, 1), up_hits);
    try std.testing.expect(!win.mouseIsDown());
    // Capture cleared: a second release does nothing.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 900, .y = 900 }, .button = .left, .pressed = false } });
    try std.testing.expectEqual(@as(u32, 1), up_hits);
}

test "scroll dispatches to the scrollable region under the pointer" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(w: *Window, sc: *gpu.Scene) void {
            _ = w;
            _ = sc;
        }
    }.draw);
    resetCounters();

    var marker: u8 = 0;
    win.ui_frame.region_count = 2;
    // A non-scrollable top region and a scrollable one beneath it.
    win.ui_frame.regions[0] = .{ .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 200 } };
    win.ui_frame.regions[1] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        .scroll_listener = .{ .target = @ptrCast(&marker), .call_fn = countScroll },
    };
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 50, .y = 50 }, .dy = 3 } });
    try std.testing.expectEqual(@as(u32, 1), scroll_hits);
    try std.testing.expectEqual(@as(f32, 3), last_scroll_dy);
    // Outside: nothing.
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 500, .y = 500 }, .dy = 1 } });
    try std.testing.expectEqual(@as(u32, 1), scroll_hits);
}
