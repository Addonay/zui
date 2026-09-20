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
const animation = @import("animation.zig");
const zlog = @import("../core/log.zig");
const a11y = @import("../a11y/root.zig");

pub const Chrome = enum {
    system,
    custom,
};

const max_spring_bindings = 128;

const SpringBinding = struct {
    occupied: bool = false,
    key: u64 = 0,
    spring: animation.Spring = undefined,
    last_ms: ?i64 = null,
    last_render: u64 = 0,
};

fn emptySpringBindings() [max_spring_bindings]SpringBinding {
    var bindings: [max_spring_bindings]SpringBinding = undefined;
    for (&bindings) |*binding| binding.* = .{};
    return bindings;
}

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

/// Stable liveness state owned by TaskRuntime and retained after Window
/// memory is reaped. Async completions use this token rather than the Window
/// allocation as their liveness authority.
pub const WindowLivenessToken = struct {
    epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    pub fn snapshot(self: *const @This()) u64 {
        return self.epoch.load(.seq_cst);
    }

    pub fn isAliveAt(self: *const @This(), expected_epoch: u64) bool {
        return self.valid.load(.seq_cst) and self.epoch.load(.seq_cst) == expected_epoch;
    }

    pub fn invalidate(self: *@This()) void {
        self.valid.store(false, .seq_cst);
        _ = self.epoch.fetchAdd(1, .seq_cst);
    }
};

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
    reduce_motion: bool = false,
    /// Bounded retained scalar springs used by element/property animation
    /// helpers. Keys are stable element/property ids supplied by callers.
    spring_bindings: [max_spring_bindings]SpringBinding = emptySpringBindings(),
    closed: bool = false,
    scene: gpu.Scene = .{},
    renderer: ?Renderer = null,
    /// Backend policy is always present; WGPU remains opt-in and only becomes
    /// active when a native integration installs submit hooks.
    render_backend: gpu.render_backend.Controller = gpu.render_backend.Controller.init(
        gpu.render_backend.select(.cpu, false, false, false),
        1,
        1,
    ),
    gpu_bridge: ?*anyopaque = null,
    gpu_bridge_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
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
    /// Modifiers carried by the most recent mouse event, readable by the
    /// mouse listener that received it (row ctrl/shift selection).
    mouse_modifiers: platform.event.Modifiers = .{},
    /// Set while dispatching the captured region's motion callback, so the
    /// drag source can tell that call apart from the hovered-region one.
    motion_from_capture: bool = false,
    /// Reset for each pointer event. Capture/bubble listeners can stop the
    /// current event without mutating the retained element tree.
    event_propagation_stopped: bool = false,
    /// Most recent scroll event delivered to this window, readable by the
    /// scroll listener that received it.
    last_scroll: platform.event.ScrollEvent = .{ .pos = .{ .x = 0, .y = 0 } },
    /// Opt-in wheel remainder. Legacy listeners consume the entire event.
    scroll_chain_requested: bool = false,
    /// Native focus is separate from retained element focus.
    native_focused: bool = true,
    /// Stable focus id of the editable element currently owning native IME
    /// input. Zero means no native text-input session is active.
    text_input_owner: u32 = 0,
    scale_factor: f32 = 1,
    native_backend: ?platform.Backend = null,
    owns_native_window: bool = false,
    /// Heap-owned Window storage attached to `scene`; kept out of Scene so
    /// custom stroke capacity does not consume the hot stack budget.
    stroke_storage: gpu.StrokeStorage = undefined,
    /// AccessKit bridge (gap §5C): publishes the semantic tree to the OS.
    /// Empty (no adapter) unless `-Daccesskit=true` built it in.
    a11y_bridge: a11y.accesskit.Bridge = a11y.accesskit.Bridge.init(),
    /// Owned by App.tasks; detached before TaskRuntime shutdown.
    task_liveness: ?*WindowLivenessToken = null,
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
        if (self.reduce_motion) return;
        if (self.native_backend) |native| {
            if (native.requestFrame()) return;
        }
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
        if (self.closed or self.reduce_motion or self.animation_deadline_us != null) return;
        const now_us = now_ms *| 1000;
        const interval: i64 = self.animation_interval_us;
        var next = (self.last_animation_target_us orelse now_us) +| interval;
        // Skip missed frames, never burst to catch up after a slow render.
        if (next <= now_us) next +|= (@divFloor(now_us - next, interval) + 1) *| interval;
        self.animation_deadline_us = next;
        self.wakeup_fn(self.app);
    }

    /// Deliver a compositor/native frame source to the normal dirty-render
    /// path. Timer-backed backends never call this method.
    pub fn animationFrameReady(self: *Window) void {
        if (self.closed) return;
        const now = self.timeMs();
        const delta = if (self.last_animation_frame_ms) |last| now - last else 0;
        self.last_animation_frame_ms = now;
        self.last_animation_target_us = null;
        self.animation_deadline_us = null;
        self.dirty = true;
        zlog.log("schedule", "window {d}: compositor animation frame interval={d}ms", .{ self.id, delta });
    }

    pub fn setReduceMotion(self: *Window, enabled: bool) void {
        self.reduce_motion = enabled;
        if (enabled) {
            self.animation_deadline_us = null;
            self.last_animation_target_us = null;
        }
        self.requestRender();
    }

    /// Advance a retained scalar spring for the current render and return its
    /// animated value. A binding is stepped at most once per render even when
    /// multiple elements read the same key. Retargeting preserves velocity,
    /// matching GPUI's `with_spring` behavior; a fresh binding starts at its
    /// target.
    pub fn springValue(self: *Window, key: u64, config: animation.SpringConfig, target: f32, epsilon: f32) f32 {
        if (key == 0) @panic("ZUI spring binding key must be nonzero");
        const now = self.timeMs();
        var free: ?*SpringBinding = null;
        for (&self.spring_bindings) |*binding| {
            if (!binding.occupied) {
                if (free == null) free = binding;
                continue;
            }
            if (binding.key != key) continue;
            if (binding.last_render == self.render_count) return binding.spring.state.position;
            binding.last_render = self.render_count;
            binding.spring.config = config;
            binding.spring.epsilon = epsilon;
            binding.spring.retarget(target);
            if (self.reduce_motion) {
                binding.spring.playback = .completed;
                _ = binding.spring.advance(0);
                binding.last_ms = now;
                return target;
            }
            const last = binding.last_ms orelse now;
            const dt = @min(0.1, @max(0, @as(f32, @floatFromInt(now - last)) / 1000));
            binding.last_ms = now;
            if (binding.spring.advance(dt)) self.requestAnimationFrame();
            return binding.spring.state.position;
        }
        const binding = free orelse {
            zlog.log("animation", "spring binding capacity exhausted for key {d}", .{key});
            return target;
        };
        binding.* = .{
            .occupied = true,
            .key = key,
            .spring = animation.Spring.init(config, target),
            .last_ms = now,
            .last_render = self.render_count,
        };
        return target;
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

    /// Stop the current pointer event's capture/bubble traversal. The flag is
    /// cleared automatically before the next pointer event.
    pub fn stopPropagation(self: *Window) void {
        self.event_propagation_stopped = true;
    }

    /// Request native IME input for the focused editable element. The owner
    /// id prevents multiple TextFields in one frame from repeatedly toggling
    /// the compositor session.
    pub fn requestTextInput(self: *Window, focus_id: u32) void {
        if (focus_id == 0 or self.closed) return;
        if (self.text_input_owner == focus_id) return;
        if (self.text_input_owner != 0) {
            if (self.native_backend) |native| _ = native.setTextInput(false);
        }
        self.text_input_owner = focus_id;
        if (self.native_backend) |native| _ = native.setTextInput(true);
    }

    pub fn updateImeCursorRect(self: *Window, rect: geometry.Rect) void {
        if (self.native_backend) |native| _ = native.setImeCursorRect(rect);
    }

    pub fn disableTextInput(self: *Window) void {
        if (self.text_input_owner == 0) return;
        if (self.native_backend) |native| _ = native.setTextInput(false);
        self.text_input_owner = 0;
    }

    /// The scroll event that just reached a scroll listener.
    pub fn scrollEvent(self: *const Window) platform.event.ScrollEvent {
        return self.last_scroll;
    }

    /// Call only inside a scroll listener to pass unconsumed line deltas to
    /// enclosing scroll regions. No call retains legacy consume-all behavior.
    pub fn chainScroll(self: *Window, dx: f32, dy: f32) void {
        self.last_scroll.dx = dx;
        self.last_scroll.dy = dy;
        self.scroll_chain_requested = dx != 0 or dy != 0;
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
        if (self.ui_frame.owner_overflow_fatal) {
            // Owner-table overflow must never degrade dispatch into
            // ungated raw callbacks (gap report §5.3): reject the frame
            // like a scene overflow instead.
            self.rejected_frames += 1;
            self.last_frame_rejected = true;
            zlog.log("window", "frame rejected: owner table overflowed fatally (window {d}); presenting overflow placeholder", .{self.id});
            self.scene.renderOverflowPlaceholder(self.bounds.rect());
        } else if (self.scene.overflowed()) {
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
        // AccessKit publish (gap §5C): snapshot the freshly built semantic
        // tree, then let the platform adapter take it when an assistive
        // technology is connected.
        self.a11y_bridge.publish(self);
        self.a11y_bridge.updateIfActive();
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
            if (region.disabled) continue;
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
        self.invalidateLiveness();
        self.cancelInteraction(.close_requested);
        self.cancelPointerCapture();
        self.left_button_down = false;
        self.disableTextInput();
    }

    /// Release frame-owned resources before the owner frees this window.
    /// Retained measure→paint text layouts are heap entries owned by the
    /// frame allocator; a window destroyed before a final `painter.paint`
    /// (which normally clears them) must not leak them.
    pub fn deinit(self: *Window) void {
        self.invalidateLiveness();
        self.cancelPointerCapture();
        self.left_button_down = false;
        self.disableTextInput();
        self.ui_frame.clearCozmicLayouts();
        self.a11y_bridge.deinit(self.allocator orelse std.heap.page_allocator);
        if (self.gpu_bridge) |bridge| {
            if (self.gpu_bridge_deinit) |destroy_bridge| destroy_bridge(bridge, self.allocator orelse std.heap.page_allocator);
            self.gpu_bridge = null;
            self.gpu_bridge_deinit = null;
        }
        if (self.owns_native_window) {
            self.native_backend.?.destroyWindow();
            self.native_backend = null;
            self.owns_native_window = false;
        }
    }

    pub fn isClosed(self: *const Window) bool {
        return self.closed;
    }

    pub fn livenessToken(self: *const Window) ?*WindowLivenessToken {
        return self.task_liveness;
    }

    /// Invalidate async work before this Window can be freed. Idempotent so
    /// close, reap, removeWindow, and final App teardown may all call it.
    pub fn invalidateLiveness(self: *Window) void {
        if (self.task_liveness) |token| token.invalidate();
    }

    /// App detaches this before TaskRuntime releases its token allocations.
    pub fn detachLivenessToken(self: *Window) void {
        self.task_liveness = null;
    }

    pub fn setRenderer(self: *Window, r: Renderer) void {
        self.renderer = r;
        self.requestRender();
    }

    pub fn renderBackend(self: *const Window) *const gpu.render_backend.Controller {
        return &self.render_backend;
    }

    pub fn activateGpuRenderer(self: *Window, hooks: gpu.render_backend.Hooks) bool {
        return self.render_backend.activateGpu(hooks);
    }

    pub fn installGpuBridge(self: *Window, bridge: *anyopaque, hooks: gpu.render_backend.Hooks, destroy_bridge: *const fn (*anyopaque, std.mem.Allocator) void) bool {
        if (!self.activateGpuRenderer(hooks)) return false;
        self.gpu_bridge = bridge;
        self.gpu_bridge_deinit = destroy_bridge;
        return true;
    }

    pub fn setRendererMinimized(self: *Window, minimized: bool) void {
        self.render_backend.setMinimized(minimized);
    }

    /// Present through the explicitly activated WGPU/Vellz path. If that
    /// path is unavailable, loses its device, or rejects a frame, the native
    /// CPU backend remains the compatibility fallback for this same frame.
    pub fn present(self: *Window, glyph_pixels: []const u8, image_pixels: []const u8) void {
        if (self.render_backend.selection.active == .wgpu) {
            if (self.render_backend.beginFrame()) |frame_id| {
                const result = self.render_backend.submit(frame_id, &self.scene, glyph_pixels, image_pixels);
                if (result == .presented) return;
            }
        }
        self.native_backend.?.present(&self.scene, glyph_pixels, image_pixels);
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

    /// Cancel pointer delivery to the previously pressed element. The
    /// physical button state remains owned by the platform event stream; a
    /// later release still clears `left_button_down`.
    pub fn cancelPointerCapture(self: *Window) void {
        self.captured_mouse_region = null;
        self.motion_from_capture = false;
    }

    /// Notify the focused widget and clear all interaction state that cannot
    /// safely survive focus loss, close, unmount, or modal replacement.
    pub fn cancelInteraction(self: *Window, reason: platform.event.WindowEvent) void {
        _ = self.focused.dispatch(.{ .window = reason }, self);
        self.cancelPointerCapture();
        self.left_button_down = false;
        self.keymap.pending_first = null;
        self.keymap.pending_single = null;
        self.keymap.pending_deadline_ms = null;
        self.requestRender();
    }

    pub fn focus(self: *Window, handle: anytype, cx: anytype) void {
        _ = cx;
        if (self.focus_scope) |scope| if (scope.modal and !scope.contains(handle.id)) return;
        self.setFocused(handle);
    }

    /// Change focus and invalidate pointer delivery owned by the old target.
    /// Widgets clear their private Pressable/text-drag latches from the new
    /// focus identity during the next render.
    pub fn setFocused(self: *Window, handle: elements.FocusHandle) void {
        if (self.focused.eql(handle)) {
            self.focused = handle;
            return;
        }
        _ = self.focused.dispatch(.{ .window = .cancelled }, self);
        self.cancelPointerCapture();
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
        if (self.focus_scope) |scope| if (scope.owner.id != 0) {
            if (!scope.owner.isLive() or !self.scopeOwnerPresent(scope.owner.id)) {
                self.focus_scope = null;
                self.cancelInteraction(.cancelled);
                self.setFocused(.{});
                self.disableTextInput();
                return;
            }
        };
        if (self.text_input_owner != 0 and self.focused.id != self.text_input_owner) self.disableTextInput();
        if (self.focused.id == 0) return;
        for (self.ui_frame.regions[0..self.ui_frame.region_count]) |region| {
            if (region.disabled) continue;
            if (region.focus) |handle| {
                if (handle.id == self.focused.id) {
                    // The owner may have been destroyed while its region
                    // slot still exists: drop focus now instead of
                    // lingering on a dead handle.
                    if (!handle.isLive()) {
                        self.setFocused(.{});
                        self.disableTextInput();
                        return;
                    }
                    self.setFocused(handle);
                    return;
                }
            }
        }
        // Focused control disappeared: clear so dead handles stop
        // receiving text/key events instead of dispatching into freed state.
        self.setFocused(.{});
        self.disableTextInput();
    }

    fn scopeOwnerPresent(self: *const Window, owner_id: u32) bool {
        for (self.ui_frame.regions[0..self.ui_frame.region_count]) |region| {
            if (region.focus) |handle| if (handle.id == owner_id and region.ownerAlive()) return true;
        }
        return false;
    }

    pub fn handleEvent(self: *Window, platform_event: platform.Event) void {
        if (self.closed) return;
        var event = platform_event;
        if (event == .targeted) {
            if (event.targeted.window_id == self.id) self.handleEvent(event.untargeted());
            return;
        }
        // Pointer positions arrive in PHYSICAL framebuffer pixels; layout,
        // regions and callbacks work in LOGICAL coordinates. One inverse
        // normalization at the window boundary keeps hit-testing, drag
        // routing, double-click distance and the cursor query in logical
        // space (fractions preserved; no integer snapping).
        if (self.scale_factor != 1) switch (event) {
            .mouse => |m| {
                var normalized = m;
                normalized.pos = .{ .x = m.pos.x / self.scale_factor, .y = m.pos.y / self.scale_factor };
                event = .{ .mouse = normalized };
            },
            .scroll => |s| {
                var normalized = s;
                normalized.pos = .{ .x = s.pos.x / self.scale_factor, .y = s.pos.y / self.scale_factor };
                event = .{ .scroll = normalized };
            },
            else => {},
        };
        if (event == .mouse) {
            self.event_propagation_stopped = false;
            for (self.ui_frame.observers[0..self.ui_frame.observer_count]) |observer| _ = observer.dispatch(event, self);
        }
        if (@import("../widgets/overlay.zig").intercept(self, event)) {
            if (event == .mouse) self.pointer_position = event.mouse.pos;
            return;
        }
        switch (event) {
            .mouse => |mouse| {
                self.pointer_position = mouse.pos;
                self.mouse_modifiers = mouse.modifiers;
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
                    if (modal_scope == null) self.setFocused(.{});
                    var i = self.ui_frame.region_count;
                    while (i > 0) {
                        i -= 1;
                        const region = self.ui_frame.regions[i];
                        if (region.disabled) continue;
                        if (!region.bounds.contains(mouse.pos)) continue;
                        // Subscription cleanup (gap §5A): regions whose
                        // owning entity was destroyed are invisible to
                        // dispatch — no focus adoption, no listener, no
                        // capture — as if unmounted.
                        if (!region.ownerAlive()) continue;
                        if (!@import("../widgets/overlay.zig").allowsRegion(self, i)) continue;
                        if (modal_scope) |scope| {
                            if (self.ui_frame.portal_count == 0) {
                                const handle = region.focus orelse continue;
                                if (!scope.contains(handle.id)) continue;
                            }
                        }
                        if (region.focus) |handle| self.setFocused(handle);
                        self.dispatchPointerDownPath(region, double_click);
                        // Arm pointer capture so motion/release continue to
                        // reach this control after the pointer leaves it.
                        const capture_up = if (region.node_index) |node_index|
                            self.ui_frame.interactionExtrasFor(self.ui_frame.nodes[node_index].interaction_ext_slot).capture_mouse_up_listener != null
                        else
                            false;
                        const capture_move = if (region.node_index) |node_index|
                            self.ui_frame.interactionExtrasFor(self.ui_frame.nodes[node_index].interaction_ext_slot).capture_mouse_move_listener != null
                        else
                            false;
                        if (region.mouse_move_listener != null or region.mouse_up_listener != null or capture_up or capture_move) {
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
                if (event == .key and self.dispatchKeyPath(event)) {
                    self.requestRender();
                    return;
                }
                if (event != .key and self.focused.dispatch(event, self)) {
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
                self.event_propagation_stopped = false;
                // Scroll goes to the topmost scrollable container under the
                // pointer; focused-element dispatch stays as the fallback.
                var handled = false;
                var inner_bounds: ?geometry.Rect = null;
                var i = self.ui_frame.region_count;
                while (i > 0) {
                    i -= 1;
                    const region = self.ui_frame.regions[i];
                    if (region.disabled) continue;
                    if (!region.bounds.contains(scroll.pos)) continue;
                    if (!region.ownerAlive()) continue;
                    if (region.scroll_listener) |listener| {
                        // Only chain outward, not into an overlapping smaller
                        // sibling. Regions are painted parent-before-child.
                        if (inner_bounds) |inner| {
                            if (region.bounds.x > inner.x or region.bounds.y > inner.y or
                                region.bounds.x + region.bounds.w < inner.x + inner.w or
                                region.bounds.y + region.bounds.h < inner.y + inner.h) continue;
                        }
                        self.scroll_chain_requested = false;
                        if (region.node_index) |_| {
                            // A retained tree owns its capture/target/bubble
                            // order. The helper also handles explicit
                            // stopPropagation and scroll chaining.
                            self.dispatchScrollPath(region);
                        } else {
                            listener.call(self);
                        }
                        handled = true;
                        if (region.node_index != null) {
                            if (!self.scroll_chain_requested) break;
                            inner_bounds = region.bounds;
                            continue;
                        }
                        if (!self.scroll_chain_requested) break;
                        inner_bounds = region.bounds;
                    }
                }
                if (!handled) {
                    _ = self.focused.dispatch(event, self);
                }
                self.requestRender();
            },
            .targeted => unreachable,
            .window => |wev| switch (wev) {
                .unfocused => {
                    self.native_focused = false;
                    self.disableTextInput();
                    self.cancelInteraction(.unfocused);
                },
                .focused => {
                    self.native_focused = true;
                    self.requestRender();
                },
                else => {},
            },
        }
    }

    fn listenerOwnerAlive(self: *const Window, listener: elements.Listener) bool {
        const owner = self.ui_frame.lookupOwner(listener.target) orelse return true;
        if (elements.element.entity_is_alive_fn) |alive| {
            return alive(owner.store, owner.id, owner.generation);
        }
        return true;
    }

    fn invokeListener(self: *Window, listener: ?elements.Listener) void {
        if (listener) |value| if (self.listenerOwnerAlive(value)) value.call(self);
    }

    fn collectPointerPath(self: *const Window, target: u16, path: *[limits.MAX_LAYOUT_ELEMENTS]u16) usize {
        var count: usize = 0;
        var current: ?u16 = target;
        while (current) |index| {
            if (index >= self.ui_frame.node_count or count >= path.len) break;
            path[count] = index;
            count += 1;
            current = self.ui_frame.parentOf(index);
        }
        return count;
    }

    fn dispatchPointerDownPath(self: *Window, region: elements.HitRegion, double_click: bool) void {
        var path: [limits.MAX_LAYOUT_ELEMENTS]u16 = undefined;
        if (region.node_index) |target| {
            const count = self.collectPointerPath(target, &path);
            var i = count;
            // Capture is root-to-target. `path` is target-to-root.
            while (i > 0) {
                i -= 1;
                const interaction = self.ui_frame.interactionExtrasFor(self.ui_frame.nodes[path[i]].interaction_ext_slot);
                self.invokeListener(interaction.capture_mouse_down_listener);
                if (self.event_propagation_stopped) return;
            }
            self.invokeListener(region.mouse_down_listener);
            if (self.event_propagation_stopped) return;
            if (double_click) {
                self.invokeListener(region.double_click_listener);
                if (self.event_propagation_stopped) return;
            }
            self.invokeListener(region.listener);
            if (self.event_propagation_stopped) return;
            // Bubble starts at the target's parent and moves toward root.
            var bubble: usize = 1;
            while (bubble < count) : (bubble += 1) {
                self.invokeListener(self.ui_frame.nodes[path[bubble]].mouse_down_listener);
                if (self.event_propagation_stopped) return;
            }
            return;
        }
        // Hand-built regions have no retained ancestry; their ordinary
        // listener remains compatible with the pre-propagation path.
        self.invokeListener(region.mouse_down_listener);
        if (self.event_propagation_stopped) return;
        if (double_click) self.invokeListener(region.double_click_listener);
        if (self.event_propagation_stopped) return;
        self.invokeListener(region.listener);
    }

    fn dispatchPointerUpPath(self: *Window, region: elements.HitRegion) void {
        var path: [limits.MAX_LAYOUT_ELEMENTS]u16 = undefined;
        if (region.node_index) |target| {
            const count = self.collectPointerPath(target, &path);
            var i = count;
            while (i > 0) {
                i -= 1;
                const interaction = self.ui_frame.interactionExtrasFor(self.ui_frame.nodes[path[i]].interaction_ext_slot);
                self.invokeListener(interaction.capture_mouse_up_listener);
                if (self.event_propagation_stopped) return;
            }
            self.invokeListener(region.mouse_up_listener);
            if (self.event_propagation_stopped) return;
            var bubble: usize = 1;
            while (bubble < count) : (bubble += 1) {
                self.invokeListener(self.ui_frame.nodes[path[bubble]].mouse_up_listener);
                if (self.event_propagation_stopped) return;
            }
            return;
        }
        self.invokeListener(region.mouse_up_listener);
    }

    fn dispatchPointerMovePath(self: *Window, region: elements.HitRegion) void {
        var path: [limits.MAX_LAYOUT_ELEMENTS]u16 = undefined;
        if (region.node_index) |target| {
            const count = self.collectPointerPath(target, &path);
            var i = count;
            while (i > 0) {
                i -= 1;
                const interaction = self.ui_frame.interactionExtrasFor(self.ui_frame.nodes[path[i]].interaction_ext_slot);
                self.invokeListener(interaction.capture_mouse_move_listener);
                if (self.event_propagation_stopped) return;
            }
            self.invokeListener(region.mouse_move_listener);
            if (self.event_propagation_stopped) return;
            var bubble: usize = 1;
            while (bubble < count) : (bubble += 1) {
                self.invokeListener(self.ui_frame.nodes[path[bubble]].mouse_move_listener);
                if (self.event_propagation_stopped) return;
            }
            return;
        }
        self.invokeListener(region.mouse_move_listener);
    }

    fn dispatchScrollPath(self: *Window, region: elements.HitRegion) void {
        const target = region.node_index orelse {
            self.invokeListener(region.scroll_listener);
            return;
        };
        var path: [limits.MAX_LAYOUT_ELEMENTS]u16 = undefined;
        const count = self.collectPointerPath(target, &path);

        // Chaining is an explicit target default action: a parent only sees
        // the event when the child reports an unconsumed remainder.
        self.scroll_chain_requested = false;
        self.invokeListener(region.scroll_listener);
        if (self.event_propagation_stopped or !self.scroll_chain_requested) return;

        var bubble: usize = 1;
        while (bubble < count) : (bubble += 1) {
            const listener = self.ui_frame.nodes[path[bubble]].scroll_listener orelse continue;
            self.scroll_chain_requested = false;
            self.invokeListener(listener);
            if (self.event_propagation_stopped or !self.scroll_chain_requested) return;
        }
    }

    /// Dispatch key events through the focused node's retained ancestry.
    /// GPUI performs this as capture (root to target), target handling, then
    /// bubble (target to root). A focused handle is retained as ZUI's target
    /// compatibility hook; listeners can stop the traversal with
    /// `Window.stopPropagation()`.
    fn dispatchKeyPath(self: *Window, event: platform.Event) bool {
        self.event_propagation_stopped = false;
        var target: ?u16 = null;
        for (self.ui_frame.regions[0..self.ui_frame.region_count]) |region| {
            if (region.focus) |handle| {
                if (handle.id == self.focused.id and region.ownerAlive() and handle.isLive()) {
                    target = region.node_index;
                    if (target != null) break;
                }
            }
        }

        if (target) |node_index| {
            var path: [limits.MAX_LAYOUT_ELEMENTS]u16 = undefined;
            const count = self.collectPointerPath(node_index, &path);
            var i = count;
            while (i > 0) {
                i -= 1;
                self.invokeListener(self.ui_frame.nodes[path[i]].capture_key_listener);
                if (self.event_propagation_stopped) return true;
            }
            if (self.focused.dispatch(event, self)) return true;
            var bubble: usize = 0;
            while (bubble < count) : (bubble += 1) {
                self.invokeListener(self.ui_frame.nodes[path[bubble]].key_listener);
                if (self.event_propagation_stopped) return true;
            }
            return false;
        }

        return self.focused.dispatch(event, self);
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
            if (region.disabled) continue;
            if (!region.bounds.contains(mouse.pos)) continue;
            if (!region.ownerAlive()) continue;
            hovered = region;
            break;
        }
        if (hovered) |region| {
            self.dispatchPointerMovePath(region);
        }
        if (self.captured_mouse_region) |captured| {
            if (!captured.ownerAlive()) {
                // A destroyed owner must lose capture immediately, even if
                // the platform never delivers the matching release.
                self.cancelPointerCapture();
                return;
            }
            const same_target = if (hovered) |h|
                (h.mouse_move_listener != null and captured.mouse_move_listener != null and
                    h.mouse_move_listener.?.target == captured.mouse_move_listener.?.target)
            else
                false;
            // A captured region whose owner was destroyed ends the drag
            // silently: no further motion reaches the freed target.
            if (!same_target and !captured.disabled and captured.ownerAlive()) {
                self.motion_from_capture = true;
                defer self.motion_from_capture = false;
                self.dispatchPointerMovePath(captured);
            }
        }
    }

    /// Release: the captured region gets the up callback (drag end), and the
    /// topmost region under the pointer handles plain releases elsewhere.
    fn dispatchMouseUp(self: *Window, mouse: platform.event.MouseEvent) void {
        if (self.captured_mouse_region) |captured| {
            if (captured.ownerAlive() and !captured.disabled) self.dispatchPointerUpPath(captured);
            self.cancelPointerCapture();
            return;
        }
        var i = self.ui_frame.region_count;
        while (i > 0) {
            i -= 1;
            const region = self.ui_frame.regions[i];
            if (region.disabled) continue;
            if (!region.bounds.contains(mouse.pos)) continue;
            if (!region.ownerAlive()) continue;
            self.dispatchPointerUpPath(region);
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

test "window springValue retains velocity and steps once per render" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();

    const win = try app.openWindow(.{ .title = "Spring" }, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    const config = animation.SpringConfig.init(170, 14, 1);
    win.render_count = 1;
    try std.testing.expectEqual(@as(f32, 0), win.springValue(0x1001, config, 0, 0.001));

    // Seed a live velocity, then retarget on a later render. A repeated read
    // in the same render must not advance the state twice.
    win.spring_bindings[0].spring.started = true;
    win.spring_bindings[0].spring.state.velocity = 4;
    win.spring_bindings[0].last_ms = win.timeMs();
    win.render_count = 2;
    const first = win.springValue(0x1001, config, 100, 0.001);
    const second = win.springValue(0x1001, config, 100, 0.001);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(f32, 4), win.spring_bindings[0].spring.state.velocity);
}

test "native text-input ownership is idempotent and clears on teardown" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{ .title = "IME" }, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);

    win.requestTextInput(41);
    try std.testing.expectEqual(@as(u32, 41), win.text_input_owner);
    // Repeating the same owner does not churn the backend session.
    win.requestTextInput(41);
    try std.testing.expectEqual(@as(u32, 41), win.text_input_owner);
    win.requestTextInput(42);
    try std.testing.expectEqual(@as(u32, 42), win.text_input_owner);
    win.disableTextInput();
    try std.testing.expectEqual(@as(u32, 0), win.text_input_owner);

    win.requestTextInput(43);
    win.close();
    try std.testing.expectEqual(@as(u32, 0), win.text_input_owner);
}

test "reduced motion snaps springs without scheduling animation" {
    const TestApp = @import("app.zig").App;
    var app = try TestApp.initHeadless(std.testing.allocator);
    defer app.deinit();

    const win = try app.openWindow(.{ .title = "Reduced motion" }, struct {
        fn draw(_: *Window, _: *gpu.Scene) void {}
    }.draw);
    win.setReduceMotion(true);
    const config = animation.SpringConfig.init(170, 14, 1);
    win.render_count = 1;
    _ = win.springValue(0x1002, config, 0, 0.001);
    win.render_count = 2;
    try std.testing.expectEqual(@as(f32, 100), win.springValue(0x1002, config, 100, 0.001));
    try std.testing.expect(win.animation_deadline_us == null);
    try std.testing.expectEqual(@as(f32, 100), win.spring_bindings[0].spring.state.position);
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

    // openWindow pushed the title straight to the window-scoped backend;
    // the connection-level root stays empty for multi-window isolation.
    const nb = app.getNullBackend().?.windows[0].?;
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
    const nb = app.getNullBackend().?.windows[0].?;
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
var propagation_log: [16]u8 = undefined;
var propagation_len: usize = 0;

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
    propagation_len = 0;
}

fn recordPropagation(_: *anyopaque, payload: *const elements.element.ListenerPayload, _: *anyopaque) void {
    if (propagation_len < propagation_log.len) {
        propagation_log[propagation_len] = payload.bytes[0];
        propagation_len += 1;
    }
}

fn propagationListener(marker: *u8, value: u8) elements.Listener {
    var payload: elements.element.ListenerPayload = .{ .bytes = @splat(0) };
    payload.bytes[0] = value;
    return .{ .target = marker, .payload = payload, .call_fn = recordPropagation };
}

fn recordScrollAndChain(target: *anyopaque, payload: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
    recordPropagation(target, payload, raw_window);
    if (payload.bytes[0] == 'C') {
        const window: *Window = @ptrCast(@alignCast(raw_window));
        window.chainScroll(0, 1);
    }
}

fn chainingPropagationListener(marker: *u8, value: u8) elements.Listener {
    var payload: elements.element.ListenerPayload = .{ .bytes = @splat(0) };
    payload.bytes[0] = value;
    return .{ .target = marker, .payload = payload, .call_fn = recordScrollAndChain };
}

fn recordAndStopPropagation(target: *anyopaque, payload: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
    recordPropagation(target, payload, raw_window);
    const window: *Window = @ptrCast(@alignCast(raw_window));
    window.stopPropagation();
}

fn stoppingPropagationListener(marker: *u8, value: u8) elements.Listener {
    var payload: elements.element.ListenerPayload = .{ .bytes = @splat(0) };
    payload.bytes[0] = value;
    return .{ .target = marker, .payload = payload, .call_fn = recordAndStopPropagation };
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

test "disabled hit regions are inert for pointer dispatch and focus" {
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
        .mouse_up_listener = .{ .target = @ptrCast(&marker), .call_fn = countUp },
        .scroll_listener = .{ .target = @ptrCast(&marker), .call_fn = countScroll },
        .focus = .{ .id = 77 },
        .disabled = true,
    };

    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false, .motion = true } });
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 10, .y = 10 }, .dy = 1 } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false } });
    try std.testing.expectEqual(@as(u32, 0), move_hits);
    try std.testing.expectEqual(@as(u32, 0), up_hits);
    try std.testing.expectEqual(@as(u32, 0), scroll_hits);
    try std.testing.expectEqual(@as(u32, 0), win.focused.id);
    try std.testing.expect(win.captured_mouse_region == null);
}

test "pointer capture and bubble phases follow element ancestry" {
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
    win.ui_frame.reset(win, .{});
    elements.element.beginFrame(&win.ui_frame);
    const target = elements.div();
    const parent = elements.div().on_mouse_down(propagationListener(&marker, 'B')).on_mouse_up(propagationListener(&marker, 'E')).on_mouse_move(propagationListener(&marker, 'H')).child(target);
    const root = elements.div().capture_mouse_down(propagationListener(&marker, 'A')).capture_mouse_up(propagationListener(&marker, 'D')).capture_mouse_move(propagationListener(&marker, 'G')).child(parent);
    _ = root;
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .node_index = target.index,
        .mouse_down_listener = propagationListener(&marker, 'C'),
        .mouse_up_listener = propagationListener(&marker, 'F'),
        .mouse_move_listener = propagationListener(&marker, 'I'),
    };

    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try std.testing.expectEqualStrings("ACB", propagation_log[0..propagation_len]);
    propagation_len = 0;
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false } });
    try std.testing.expectEqualStrings("DFE", propagation_log[0..propagation_len]);
    propagation_len = 0;
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqualStrings("GIH", propagation_log[0..propagation_len]);

    // A capture listener can stop the event before target or bubble phases.
    elements.element.endFrame();
    resetCounters();
    win.ui_frame.reset(win, .{});
    elements.element.beginFrame(&win.ui_frame);
    const blocked_target = elements.div();
    const blocked_parent = elements.div().on_mouse_down(propagationListener(&marker, 'B')).child(blocked_target);
    _ = elements.div().capture_mouse_down(stoppingPropagationListener(&marker, 'S')).child(blocked_parent);
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{ .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .node_index = blocked_target.index, .mouse_down_listener = propagationListener(&marker, 'C') };
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try std.testing.expectEqualStrings("S", propagation_log[0..propagation_len]);
    elements.element.endFrame();
}

test "keyboard dispatch follows focused ancestry in capture then bubble order" {
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
    win.ui_frame.reset(win, .{});
    elements.element.beginFrame(&win.ui_frame);
    const target = elements.div().withFocus(.{ .id = 77 }).on_key(propagationListener(&marker, 'C'));
    const parent = elements.div().on_key(propagationListener(&marker, 'B')).child(target);
    _ = elements.div().capture_key(propagationListener(&marker, 'A')).child(parent);
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .node_index = target.index,
        .focus = .{ .id = 77 },
    };
    win.focused = .{ .id = 77 };

    win.handleEvent(.{ .key = .{ .key = .a, .pressed = true } });
    try std.testing.expectEqualStrings("ACB", propagation_log[0..propagation_len]);
    elements.element.endFrame();
}

test "keyboard capture can stop propagation before the focused target" {
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
    win.ui_frame.reset(win, .{});
    elements.element.beginFrame(&win.ui_frame);
    const target = elements.div().withFocus(.{ .id = 88 }).on_key(propagationListener(&marker, 'T'));
    const parent = elements.div().child(target);
    _ = elements.div().capture_key(stoppingPropagationListener(&marker, 'S')).child(parent);
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .node_index = target.index,
        .focus = .{ .id = 88 },
    };
    win.focused = .{ .id = 88 };

    win.handleEvent(.{ .key = .{ .key = .b, .pressed = true } });
    try std.testing.expectEqualStrings("S", propagation_log[0..propagation_len]);
    elements.element.endFrame();
}

test "scroll capture, target, and chained bubble follow element ancestry" {
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
    win.ui_frame.reset(win, .{});
    elements.element.beginFrame(&win.ui_frame);
    const target = elements.div().w(100).h(100).on_scroll(chainingPropagationListener(&marker, 'C'));
    const parent = elements.div().w(100).h(100).on_scroll(propagationListener(&marker, 'B')).child(target);
    const root = elements.div().w(100).h(100).child(parent);
    elements.layout.layout(&win.ui_frame, root, .{ .w = 100, .h = 100 });
    elements.painter.paint(&win.ui_frame, root, &win.scene);
    elements.element.endFrame();
    win.updateHitRegions();
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 10, .y = 10 }, .dy = 2 } });
    try std.testing.expectEqualStrings("CB", propagation_log[0..propagation_len]);
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

test "physical pointer input is normalized into logical hit coordinates" {
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
    // Logical button at 50..100 x 40..60 (physical 100..200 x 80..120 at 2x).
    // Logical button 50..100 x 40..60 == physical 100..200 x 80..120 at 2x.
    win.scale_factor = 2;
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 50, .y = 40, .w = 50, .h = 20 },
        .mouse_move_listener = .{ .target = @ptrCast(&marker), .call_fn = countMove },
        .mouse_up_listener = .{ .target = @ptrCast(&marker), .call_fn = countUp },
    };

    // Physical motion at (150,90) -> logical (75,45): inside, one callback.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 150, .y = 90 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqual(@as(u32, 1), move_hits);
    // Normalized hover position stays logical for the cursor query.
    try std.testing.expectApproxEqAbs(@as(f32, 75), win.pointer_position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), win.pointer_position.y, 0.001);
    // Physical (90,70) -> logical (45,35), outside: no second callback.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 90, .y = 70 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqual(@as(u32, 1), move_hits);
    // Press arms capture (move listener present); release outside the
    // window's logical bounds still reaches the captured region.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 150, .y = 90 }, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 300, .y = 160 }, .button = .left, .pressed = false } });
    try std.testing.expectEqual(@as(u32, 1), up_hits);
    // 1.5x: the same logical button spans physical 75..150 x 60..90;
    // (112,68) -> logical (74.67,45.33) hits it.
    win.scale_factor = 1.5;
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 112, .y = 68 }, .button = .left, .pressed = false, .motion = true } });
    try std.testing.expectEqual(@as(u32, 2), move_hits);
}
