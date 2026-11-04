//! Wayland backend (GPUI `gpui_linux` wayland module). One `WaylandConnection` owns
//! the wl_display, seat and clipboard; each platform window is an xdg_toplevel
//! surface with double-buffered wl_shm storage. Frames are paced by
//! wl_surface.frame callbacks.

const std = @import("std");
const geometry = @import("../../geometry.zig");
const platform = @import("../../platform.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const interactive = @import("../../interactive.zig");
const window_mod = @import("../../window.zig");
const color = @import("../../color.zig");
const keystroke = @import("../../keystroke.zig");
const cpu = @import("../../renderer/cpu.zig");
const window_renderer = @import("../../renderer/window_renderer.zig");
const proto = @import("wayland_proto.zig");
const dl = @import("dl.zig");
const xkb = @import("xkb.zig");
const input = @import("input.zig");

const Pixels = geometry.Pixels;
const PxPoint = geometry.Point(Pixels);
const PxSize = geometry.Size(Pixels);
const PxBounds = geometry.Bounds(Pixels);
const Display = platform.Display;
const CursorStyle = platform.CursorStyle;
const MouseButton = interactive.MouseButton;
const Hsla = color.Hsla;

/// Window background used when a frame is cleared (GPUI default dark theme).
const clear_color: Hsla = color.to_hsla(color.rgb(0x0e0e13));

/// wl_output events (version 3 is bound: geometry, mode, done, scale).
const OutputListener = extern struct {
    geometry: ?*const fn (?*anyopaque, *anyopaque, i32, i32, i32, i32, i32, ?[*:0]const u8, ?[*:0]const u8, i32) callconv(.c) void = null,
    mode: ?*const fn (?*anyopaque, *anyopaque, u32, i32, i32, i32) callconv(.c) void = null,
    done: ?*const fn (?*anyopaque, *anyopaque) callconv(.c) void = null,
    scale: ?*const fn (?*anyopaque, *anyopaque, i32) callconv(.c) void = null,
};

const max_outputs = 8;

const Output = struct {
    proxy: ?*anyopaque = null,
    name: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    scale: i32 = 1,
    /// Pending mode values, committed on `done`.
    pending_w: i32 = 0,
    pending_h: i32 = 0,
};

/// Clipboard and selection MIME types we offer and accept.
const MIME_UTF8: [*:0]const u8 = "text/plain;charset=utf-8";
const MIME_TEXT_UTF8: [*:0]const u8 = "UTF8_STRING";
const MIME_TEXT: [*:0]const u8 = "text/plain";
const MIME_STRING: [*:0]const u8 = "STRING";

/// Key repeat state: the held key's resolved name and text, re-emitted on a timer.
const Repeat = struct {
    key_buf: [32]u8 = undefined,
    key_len: u8 = 0,
    text: [32]u8 = undefined,
    text_len: u8 = 0,
    code: u32 = 0,
    active: bool = false,
    next_ms: i64 = 0,
};

/// Tracks a selection's offers: the newest announced one and the one in effect.
const OfferSlot = struct {
    incoming: ?*anyopaque = null,
    incoming_mimes: u8 = 0,
    current: ?*anyopaque = null,
    mimes: u8 = 0,
};

/// One axis of pending wheel input, flushed once per pointer frame.
const Axis = struct {
    /// Continuous delta in logical pixels (decoded from wl_fixed).
    value: f32 = 0,
    discrete: i32 = 0,
    v120: i32 = 0,
};

/// The compositor connection. Owns globals, seat devices, clipboard and cursors.
pub const WaylandConnection = struct {
    allocator: std.mem.Allocator,
    lib: dl.Library,
    api: proto.WaylandApi,
    display: *proto.Display,
    registry: *proto.Registry,

    compositor: ?*proto.Compositor = null,
    shm: ?*proto.Shm = null,
    wm_base: ?*proto.XdgWmBase = null,
    gpu_context: ?*window_renderer.GpuContext = null,
    gpu_probed: bool = false,
    compose: ?xkb.Compose = null,
    cursor_shape_manager: ?*proto.CursorShapeManager = null,
    cursor_shape_device: ?*proto.CursorShapeDevice = null,
    primary_manager: ?*proto.PrimaryDeviceManager = null,
    primary_device: ?*proto.PrimaryDevice = null,
    primary_source: ?*proto.PrimarySource = null,
    primary_slot: OfferSlot = .{},
    primary_offer_text: ?[]u8 = null,
    primary_read: ?[]u8 = null,
    owning_primary: bool = false,
    clipboard_slot: OfferSlot = .{},
    seat: ?*proto.Seat = null,
    seat_caps: u32 = 0,
    pointer: ?*proto.Pointer = null,
    keyboard: ?*proto.Keyboard = null,
    ddm: ?*proto.DataDeviceManager = null,
    data_device: ?*proto.DataDevice = null,
    dec_manager: ?*proto.DecorationManager = null,
    viewporter: ?*anyopaque = null,
    frac_manager: ?*anyopaque = null,
    outputs: [max_outputs]Output = @splat(.{}),
    output_count: usize = 0,
    displays_: [max_outputs]Display = undefined,
    display_count: usize = 0,

    xkb: ?xkb.Xkb = null,
    cursor_lib: ?dl.Library = null,
    cursor_api: ?proto.CursorApi = null,
    cursor_theme: ?*proto.CursorTheme = null,
    cursor_surface: ?*proto.Surface = null,

    windows: std.ArrayList(*WaylandWindow) = .empty,
    keyboard_focus: ?*WaylandWindow = null,
    pointer_focus: ?*WaylandWindow = null,
    pointer_pos: PxPoint = .{ .x = 0, .y = 0 },
    pointer_enter_serial: u32 = 0,
    last_serial: u32 = 0,
    pressed: ?MouseButton = null,
    click: input.ClickTracker = .{},
    cursor_style: CursorStyle = .arrow,
    mods: u32 = 0,
    mods_reported: u32 = 0,
    axis_v: Axis = .{},
    axis_h: Axis = .{},
    repeat_rate: i32 = 0,
    repeat_delay_ms: i64 = 0,
    repeat: Repeat = .{},

    /// Text we offer as the clipboard owner.
    clip_offer: ?[]u8 = null,
    owning_selection: bool = false,
    data_source: ?*proto.DataSource = null,
    /// Storage for the last text read from the clipboard.
    clip_read: ?[]u8 = null,

    dead: bool = false,

    const reg_listener: proto.RegistryListener = .{ .global = registryGlobal, .global_remove = registryGlobalRemove };
    const seat_listener: proto.SeatListener = .{ .capabilities = seatCapabilities, .name = seatName };
    const pointer_listener: proto.PointerListener = .{
        .enter = pointerEnter,
        .leave = pointerLeave,
        .motion = pointerMotion,
        .button = pointerButton,
        .axis = pointerAxis,
        .frame = pointerFrame,
        .axis_source = pointerNoopSource,
        .axis_stop = pointerNoopStop,
        .axis_discrete = pointerAxisDiscrete,
        .axis_value120 = pointerAxisValue120,
        .axis_relative_direction = pointerNoopDirection,
    };
    const keyboard_listener: proto.KeyboardListener = .{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardModifiers,
        .repeat_info = keyboardRepeatInfo,
    };
    const output_listener: OutputListener = .{ .geometry = outputGeometry, .mode = outputMode, .done = outputDone, .scale = outputScale };
    const data_device_listener: proto.DataDeviceListener = .{
        .data_offer = dataDeviceOffer,
        .enter = dataDeviceEnter,
        .leave = dataDeviceLeave,
        .motion = dataDeviceMotion,
        .drop = dataDeviceDrop,
        .selection = dataDeviceSelection,
    };
    const primary_device_listener: proto.PrimaryDeviceListener = .{ .data_offer = primaryDeviceOffer, .selection = primaryDeviceSelection };
    const primary_offer_listener: proto.PrimaryOfferListener = .{ .offer = primaryOfferOffer };
    const primary_source_listener: proto.PrimarySourceListener = .{ .send = primarySourceSend, .cancelled = primarySourceCancelled };
    const data_offer_listener: proto.DataOfferListener = .{ .offer = dataOfferOffer };
    const data_source_listener: proto.DataSourceListener = .{ .target = dataSourceTarget, .send = dataSourceSend, .cancelled = dataSourceCancelled };
    const wm_listener: proto.XdgWmBaseListener = .{ .ping = xdgPing };

    /// Connects to the compositor named by WAYLAND_DISPLAY.
    pub fn connect(allocator: std.mem.Allocator) !*WaylandConnection {
        if (std.c.getenv("WAYLAND_DISPLAY") == null) return error.NoWaylandDisplay;
        var lib = dl.Library.open(&.{ "libwayland-client.so.0", "libwayland-client.so" }) orelse return error.LibraryNotFound;
        const api = proto.WaylandApi.load(lib) orelse {
            lib.close();
            return error.MissingSymbols;
        };
        const display = api.wl_display_connect(null) orelse {
            lib.close();
            return error.CannotConnect;
        };
        const reg_raw = api.wl_proxy_marshal_flags(@ptrCast(display), 1, api.wl_registry_interface, api.wl_proxy_get_version(@ptrCast(display)), 0);
        const registry: *proto.Registry = @ptrCast(reg_raw orelse {
            api.wl_display_disconnect(display);
            lib.close();
            return error.CannotGetRegistry;
        });

        const self = allocator.create(WaylandConnection) catch {
            api.wl_display_disconnect(display);
            lib.close();
            return error.OutOfMemory;
        };
        self.* = .{ .allocator = allocator, .lib = lib, .api = api, .display = display, .registry = registry };
        _ = api.wl_proxy_add_listener(@ptrCast(registry), &reg_listener, self);
        _ = api.wl_display_roundtrip(display);
        if (self.compositor == null or self.shm == null or self.wm_base == null) {
            self.deinit();
            return error.MissingWaylandGlobals;
        }
        _ = api.wl_proxy_add_listener(@ptrCast(self.wm_base.?), &wm_listener, self);
        if (self.seat) |seat| _ = api.wl_proxy_add_listener(@ptrCast(seat), &seat_listener, self);
        _ = api.wl_display_roundtrip(display);
        self.ensure_seat_devices();
        _ = api.wl_display_roundtrip(display);

        self.xkb = xkb.Xkb.init() catch null;
        self.load_cursor_theme();
        self.compose = xkb.Compose.init();
        return self;
    }

    fn load_cursor_theme(self: *WaylandConnection) void {
        const shm = self.shm orelse return;
        var clib = dl.Library.open(proto.cursor_lib_names) orelse return;
        const capi = proto.CursorApi.load(clib) orelse {
            clib.close();
            return;
        };
        const theme = capi.theme_load(null, 24, shm) orelse {
            clib.close();
            return;
        };
        const comp = self.compositor orelse {
            capi.theme_destroy(theme);
            clib.close();
            return;
        };
        const surf_raw = self.api.wl_proxy_marshal_flags(@ptrCast(comp), 0, self.api.wl_surface_interface, self.api.wl_proxy_get_version(@ptrCast(comp)), 0, @as(?*anyopaque, null));
        self.cursor_surface = @ptrCast(surf_raw);
        self.cursor_lib = clib;
        self.cursor_api = capi;
        self.cursor_theme = theme;
    }

    pub fn fd(self: *WaylandConnection) c_int {
        return self.api.wl_display_get_fd(self.display);
    }

    pub fn is_dead(self: *const WaylandConnection) bool {
        return self.dead;
    }

    /// Before blocking: drains queued events and arms the read. Returns true when
    /// events were dispatched: they may have asked for a frame, so the caller must go
    /// round its loop instead of blocking. Mesa's WSI reads the socket during swapchain
    /// calls, which leaves our events queued with nothing left to wake the poll.
    pub fn prepare_wait(self: *WaylandConnection) bool {
        var dispatched = false;
        if (self.api.wl_display_prepare_read) |prepare| {
            while (prepare(self.display) != 0) {
                if (self.api.wl_display_dispatch_pending(self.display) > 0) dispatched = true;
            }
        } else if (self.api.wl_display_dispatch_pending(self.display) > 0) {
            dispatched = true;
        }
        _ = self.api.wl_display_flush(self.display);
        return dispatched;
    }

    /// After waiting: reads the socket if it was readable, then dispatches.
    pub fn finish_wait(self: *WaylandConnection, readable: bool) void {
        if (self.api.wl_display_read_events) |read_ev| {
            const cancel = self.api.wl_display_cancel_read orelse return;
            if (readable) {
                if (read_ev(self.display) != 0) self.dead = true;
            } else {
                _ = cancel(self.display);
            }
        }
        if (self.api.wl_display_dispatch_pending(self.display) < 0) self.dead = true;
        if (self.api.wl_display_get_error(self.display) != 0) self.dead = true;
        _ = self.api.wl_display_flush(self.display);
    }

    pub fn flush(self: *WaylandConnection) void {
        _ = self.api.wl_display_flush(self.display);
    }

    /// Milliseconds until the next key repeat, or null when no key is held.
    pub fn repeat_timeout(self: *const WaylandConnection, now: i64) ?i32 {
        if (!self.repeat.active or self.repeat_rate == 0) return null;
        return @intCast(@max(0, self.repeat.next_ms - now));
    }

    /// Emits synthetic repeats for a held key and requests frames for windows
    /// that asked for one (their callback is not in flight).
    pub fn pump(self: *WaylandConnection) void {
        self.tick_repeat();
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            const w = self.windows.items[i];
            if (w.frame_wanted and w.frame_callback == null and w.configured and !w.closed) w.emit_frame();
        }
        self.flush();
    }

    /// Removes windows closed by the app or the compositor, freeing their memory.
    pub fn reap(self: *WaylandConnection) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const w = self.windows.items[i];
            if (w.closed) {
                _ = self.windows.swapRemove(i);
                w.free();
            } else i += 1;
        }
    }

    pub fn live_windows(self: *const WaylandConnection) usize {
        var n: usize = 0;
        for (self.windows.items) |w| {
            if (!w.closed) n += 1;
        }
        return n;
    }

    /// Outputs as displays. Falls back to one 1920x1080 display before any
    /// wl_output mode has arrived.
    pub fn displays(self: *WaylandConnection) []const Display {
        self.display_count = 0;
        for (self.outputs[0..self.output_count], 0..) |out, i| {
            const scale: f32 = @floatFromInt(out.scale);
            const w: f32 = if (out.width > 0) @as(f32, @floatFromInt(out.width)) / scale else 1920;
            const h: f32 = if (out.height > 0) @as(f32, @floatFromInt(out.height)) / scale else 1080;
            self.displays_[self.display_count] = .{ .id = @intCast(i), .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } }, .scale_factor = scale };
            self.display_count += 1;
        }
        if (self.display_count == 0) {
            self.displays_[0] = .{ .id = 0, .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1920, .height = 1080 } } };
            self.display_count = 1;
        }
        return self.displays_[0..self.display_count];
    }

    pub fn deinit(self: *WaylandConnection) void {
        for (self.windows.items) |w| w.free_protocol();
        for (self.windows.items) |w| w.free();
        self.windows.deinit(self.allocator);
        if (self.gpu_context) |ctx| ctx.destroy();
        if (self.clip_offer) |c| self.allocator.free(c);
        if (self.clip_read) |c| self.allocator.free(c);
        if (self.primary_offer_text) |c| self.allocator.free(c);
        if (self.primary_read) |c| self.allocator.free(c);
        if (self.compose) |*c| c.deinit();
        if (self.clipboard_slot.current) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.primary_slot.current) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.primary_source) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.primary_device) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.primary_manager) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.cursor_shape_device) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.cursor_shape_manager) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.data_source) |ds| self.api.wl_proxy_destroy(@ptrCast(ds));
        if (self.data_device) |dd| self.api.wl_proxy_destroy(@ptrCast(dd));
        if (self.ddm) |m| self.api.wl_proxy_destroy(@ptrCast(m));
        if (self.dec_manager) |m| self.api.wl_proxy_destroy(@ptrCast(m));
        if (self.cursor_surface) |s| self.api.wl_proxy_destroy(@ptrCast(s));
        if (self.cursor_theme) |t| if (self.cursor_api) |c| c.theme_destroy(t);
        if (self.cursor_lib) |*c| c.close();
        if (self.xkb) |*x| x.deinit();
        if (self.pointer) |p| self.api.wl_proxy_destroy(@ptrCast(p));
        if (self.keyboard) |k| self.api.wl_proxy_destroy(@ptrCast(k));
        if (self.seat) |s| self.api.wl_proxy_destroy(@ptrCast(s));
        if (self.shm) |s| self.api.wl_proxy_destroy(@ptrCast(s));
        if (self.wm_base) |w| self.api.wl_proxy_destroy(@ptrCast(w));
        if (self.compositor) |c| self.api.wl_proxy_destroy(@ptrCast(c));
        self.api.wl_proxy_destroy(@ptrCast(self.registry));
        self.api.wl_display_disconnect(self.display);
        self.lib.close();
        self.allocator.destroy(self);
    }

    // -- window creation -------------------------------------------------

    fn create_gpu_window(self: *WaylandConnection, w: *WaylandWindow) ?window_renderer.GpuWindow {
        if (!self.gpu_probed) {
            self.gpu_probed = true;
            self.gpu_context = window_renderer.GpuContext.create(self.allocator, .wayland);
        }
        const ctx = self.gpu_context orelse return null;
        return window_renderer.GpuWindow.create(ctx, .{ .wayland = .{ .display = @ptrCast(self.display), .surface = @ptrCast(w.surface.?) } }, w.phys_w(), w.phys_h(), .{ .externally_paced = true });
    }

    pub fn open_window(self: *WaylandConnection, options: window_mod.WindowOptions) !*WaylandWindow {
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
        const w = try self.allocator.create(WaylandWindow);
        const bounds: PxBounds = if (options.window_bounds) |wb| wb.get_bounds() else .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1280, .height = 800 } };
        const scale = input.env_scale() orelse self.max_output_scale();
        w.* = .{
            .allocator = self.allocator,
            .conn = self,
            .size = bounds.size,
            .scale = scale,
            .atlas = atlas_mod.CpuAtlas.init(self.allocator),
            .renderer = cpu.CpuRenderer.init(self.allocator),
            .decorated = options.titlebar != null,
        };
        w.create_surface(options) catch |err| {
            w.closed = true;
            w.free_protocol();
            w.free();
            return err;
        };
        w.gpu_window = self.create_gpu_window(w);
        self.windows.appendAssumeCapacity(w);
        self.flush();
        return w;
    }

    /// Largest advertised output scale; windows start at this integer scale
    /// until fractional-scale-v1 reports the preferred one.
    fn max_output_scale(self: *const WaylandConnection) f32 {
        var best: i32 = 1;
        for (self.outputs[0..self.output_count]) |out| best = @max(best, out.scale);
        return @floatFromInt(best);
    }

    fn find_window(self: *WaylandConnection, surface: *proto.Surface) ?*WaylandWindow {
        for (self.windows.items) |w| {
            if (!w.closed and w.surface == surface) return w;
        }
        return null;
    }

    fn release_focus(self: *WaylandConnection, w: *WaylandWindow) void {
        if (self.keyboard_focus == w) self.keyboard_focus = null;
        if (self.pointer_focus == w) self.pointer_focus = null;
    }

    // -- seat ------------------------------------------------------------

    fn ensure_seat_devices(self: *WaylandConnection) void {
        const seat = self.seat orelse return;
        if (self.pointer == null and (self.seat_caps & proto.WL_SEAT_CAP_POINTER) != 0) {
            const ver = @min(self.api.wl_proxy_get_version(@ptrCast(seat)), @as(u32, @intCast(self.api.wl_pointer_interface.version)));
            if (self.api.wl_proxy_marshal_flags(@ptrCast(seat), 0, self.api.wl_pointer_interface, ver, 0, @as(?*anyopaque, null))) |p| {
                self.pointer = @ptrCast(p);
                _ = self.api.wl_proxy_add_listener(p, &pointer_listener, self);
            }
        }
        if (self.keyboard == null and (self.seat_caps & proto.WL_SEAT_CAP_KEYBOARD) != 0) {
            const ver = @min(self.api.wl_proxy_get_version(@ptrCast(seat)), @as(u32, @intCast(self.api.wl_keyboard_interface.version)));
            if (self.api.wl_proxy_marshal_flags(@ptrCast(seat), 1, self.api.wl_keyboard_interface, ver, 0, @as(?*anyopaque, null))) |k| {
                self.keyboard = @ptrCast(k);
                _ = self.api.wl_proxy_add_listener(k, &keyboard_listener, self);
            }
        }
        if (self.data_device == null and self.ddm != null) {
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.ddm.?), 1, &proto.data_device_interface, 1, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(seat)));
            if (raw) |dd| {
                self.data_device = @ptrCast(dd);
                _ = self.api.wl_proxy_add_listener(dd, &data_device_listener, self);
            }
        }
        if (self.primary_device == null and self.primary_manager != null) {
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.primary_manager.?), 1, &proto.primary_device_interface, 1, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(seat)));
            if (raw) |dd| {
                self.primary_device = @ptrCast(dd);
                _ = self.api.wl_proxy_add_listener(dd, &primary_device_listener, self);
            }
        }
    }

    fn tick_repeat(self: *WaylandConnection) void {
        if (!self.repeat.active or self.repeat_rate == 0) return;
        const step = input.repeat_step(input.now_ms(), self.repeat.next_ms, @divTrunc(1000, @as(i64, self.repeat_rate)));
        self.repeat.next_ms = step.next_ms;
        const w = self.keyboard_focus orelse return;
        const key = self.repeat.key_buf[0..self.repeat.key_len];
        const text: ?[]const u8 = if (self.repeat.text_len > 0) self.repeat.text[0..self.repeat.text_len] else null;
        for (0..step.count) |_| w.emit_key(key, text, true, true);
    }

    fn emit_modifiers(self: *WaylandConnection) void {
        if (self.mods == self.mods_reported) return;
        self.mods_reported = self.mods;
        const w = self.keyboard_focus orelse return;
        _ = w.base.emit_input(.{ .modifiers_changed = .{ .modifiers = input.modifiers(self.mods) } });
    }

    fn handle_key(self: *WaylandConnection, code: u32, pressed: bool) void {
        const w = self.keyboard_focus orelse return;
        const shift = (self.mods & input.MOD_SHIFT) != 0;
        var name: ?[]const u8 = null;
        var text_buf: [32]u8 = undefined;
        var text: ?[]const u8 = null;
        var keysym: u32 = 0;
        if (self.xkb) |*x| {
            if (x.hasLiveState()) {
                keysym = x.keysym(code + 8);
                name = input.key_name_for_keysym(keysym);
                if (pressed) {
                    const n = x.utf8(code + 8, &text_buf);
                    if (n > 0) text = text_buf[0..n];
                }
            }
        }
        if (name == null) {
            if (input.evdev_key(code, shift)) |info| {
                name = info.name;
                if (pressed) {
                    if (info.char) |c| {
                        text_buf[0] = c;
                        text = text_buf[0..1];
                    }
                }
            }
        }
        var composed_buf: [32]u8 = undefined;
        if (pressed and keysym != 0 and !input.is_modifier_keysym(keysym)) {
            if (self.compose) |*c| switch (c.feed(keysym, &composed_buf)) {
                .composing => text = null,
                .composed => |t| {
                    // As in GPUI the key becomes the result, so a binding on the
                    // sequence's last key does not fire.
                    text = t;
                    name = t;
                },
                .nothing, .cancelled => {},
            };
        }
        const key_name = name orelse return;
        w.emit_key(key_name, text, pressed, false);
        if (pressed and !isModifierCode(code) and self.repeat_rate > 0) {
            self.repeat = .{ .code = code, .active = true, .next_ms = input.now_ms() + self.repeat_delay_ms };
            const key_len = @min(key_name.len, self.repeat.key_buf.len);
            @memcpy(self.repeat.key_buf[0..key_len], key_name[0..key_len]);
            self.repeat.key_len = @intCast(key_len);
            if (text) |t| {
                const text_len = @min(t.len, self.repeat.text.len);
                @memcpy(self.repeat.text[0..text_len], t[0..text_len]);
                self.repeat.text_len = @intCast(text_len);
            }
        } else if (!pressed and self.repeat.active and self.repeat.code == code) {
            self.repeat.active = false;
        }
    }

    fn isModifierCode(code: u32) bool {
        return switch (code) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
    }

    fn set_pointer_position(self: *WaylandConnection, sx: i32, sy: i32) void {
        self.pointer_pos = .{ .x = proto.wlFixedToFloat(sx), .y = proto.wlFixedToFloat(sy) };
    }

    fn apply_cursor(self: *WaylandConnection) void {
        const pointer = self.pointer orelse return;
        if (self.pointer_enter_serial == 0 or self.pointer_focus == null) return;
        if (self.cursor_style == .none) {
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(pointer), 0, null, self.api.wl_proxy_get_version(@ptrCast(pointer)), 0, self.pointer_enter_serial, @as(?*anyopaque, null), @as(i32, 0), @as(i32, 0));
            return;
        }
        // Prefer the compositor's own cursors: they follow its theme and scale exactly.
        if (self.cursor_shape_device == null) {
            if (self.cursor_shape_manager) |manager| {
                const raw = self.api.wl_proxy_marshal_flags(@ptrCast(manager), 1, &proto.cursor_shape_device_interface, 1, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(pointer)));
                self.cursor_shape_device = @ptrCast(raw);
            }
        }
        if (self.cursor_shape_device) |device| {
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(device), 1, null, 1, 0, self.pointer_enter_serial, cursorShape(self.cursor_style));
            return;
        }
        const capi = self.cursor_api orelse return;
        const theme = self.cursor_theme orelse return;
        const surface = self.cursor_surface orelse return;
        const cursor = capi.theme_get_cursor(theme, cursorName(self.cursor_style)) orelse capi.theme_get_cursor(theme, "left_ptr") orelse return;
        if (cursor.image_count == 0) return;
        const image = cursor.images[0];
        const buffer = capi.image_get_buffer(image) orelse return;
        const sv = self.api.wl_proxy_get_version(@ptrCast(surface));
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 1, null, sv, 0, buffer, @as(i32, 0), @as(i32, 0));
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 2, null, sv, 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(image.width)), @as(i32, @intCast(image.height)));
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 6, null, sv, 0);
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(pointer), 0, null, self.api.wl_proxy_get_version(@ptrCast(pointer)), 0, self.pointer_enter_serial, @as(*anyopaque, @ptrCast(surface)), @as(i32, @intCast(image.hotspot_x)), @as(i32, @intCast(image.hotspot_y)));
    }

    fn flush_axes(self: *WaylandConnection) void {
        const dy = axisLines(self.axis_v, true);
        const dx = axisLines(self.axis_h, false);
        self.axis_v = .{};
        self.axis_h = .{};
        const w = self.pointer_focus orelse return;
        if (dx == null and dy == null) return;
        _ = w.base.emit_input(.{ .scroll_wheel = .{
            .position = self.pointer_pos,
            .delta = .{ .lines = .{ .x = dx orelse 0, .y = dy orelse 0 } },
            .modifiers = input.modifiers(self.mods),
            .source = .pointer,
        } });
    }

    /// Scroll lines for one axis. High-resolution steps win, then discrete
    /// notches, then continuous pixels (about 10 per notch). Positive is up.
    fn axisLines(axis: Axis, vertical: bool) ?f32 {
        if (axis.v120 == 0 and axis.discrete == 0 and axis.value == 0) return null;
        var lines: f32 = if (axis.v120 != 0)
            @as(f32, @floatFromInt(axis.v120)) / 120.0
        else if (axis.discrete != 0)
            @floatFromInt(axis.discrete)
        else
            axis.value / 10.0;
        if (vertical) lines = -lines;
        return lines;
    }

    // -- clipboard -------------------------------------------------------

    /// Makes `offer` the selection's current offer and destroys the one it replaces.
    fn commit_offer(self: *WaylandConnection, slot: *OfferSlot, offer: anytype, destroy_opcode: u32) void {
        const incoming: ?*anyopaque = if (offer) |o| @ptrCast(o) else null;
        if (slot.current) |old| {
            if (old != incoming) _ = self.api.wl_proxy_marshal_flags(@ptrCast(old), destroy_opcode, null, 1, 1);
        }
        slot.current = incoming;
        slot.mimes = if (incoming != null and slot.incoming == incoming) slot.incoming_mimes else 0;
    }

    fn offer_mime_bit(mime: []const u8) u8 {
        if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return 1 << 0;
        if (std.mem.eql(u8, mime, "UTF8_STRING")) return 1 << 1;
        if (std.mem.eql(u8, mime, "text/plain")) return 1 << 2;
        if (std.mem.eql(u8, mime, "STRING")) return 1 << 3;
        return 0;
    }

    fn best_offer_mime(mimes: u8) ?[*:0]const u8 {
        if (mimes & (1 << 0) != 0) return MIME_UTF8;
        if (mimes & (1 << 1) != 0) return MIME_TEXT_UTF8;
        if (mimes & (1 << 2) != 0) return MIME_TEXT;
        if (mimes & (1 << 3) != 0) return MIME_STRING;
        return null;
    }

    pub fn set_clipboard(self: *WaylandConnection, text: []const u8) bool {
        const ddm = self.ddm orelse return false;
        const dd = self.data_device orelse return false;
        if (self.last_serial == 0) return false;
        const copy = self.allocator.dupe(u8, text) catch return false;
        if (self.clip_offer) |old| self.allocator.free(old);
        self.clip_offer = copy;
        if (self.data_source) |ds| self.api.wl_proxy_destroy(@ptrCast(ds));
        self.data_source = null;
        const raw = self.api.wl_proxy_marshal_flags(@ptrCast(ddm), 0, &proto.data_source_interface, 1, 0, @as(?*anyopaque, null));
        const source: *proto.DataSource = @ptrCast(raw orelse return false);
        _ = self.api.wl_proxy_add_listener(@ptrCast(source), &data_source_listener, self);
        for ([_][*:0]const u8{ MIME_UTF8, MIME_TEXT_UTF8, MIME_TEXT, MIME_STRING }) |mime| {
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(source), 0, null, 1, 0, mime);
        }
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(dd), 1, null, 1, 0, @as(*anyopaque, @ptrCast(source)), self.last_serial);
        self.data_source = source;
        self.owning_selection = true;
        _ = self.api.wl_display_flush(self.display);
        return true;
    }

    pub fn get_clipboard(self: *WaylandConnection) ?[]const u8 {
        if (self.owning_selection) {
            return self.clip_offer;
        }
        _ = self.api.wl_display_roundtrip(self.display);
        const offer = self.clipboard_slot.current orelse return null;
        const mime = best_offer_mime(self.clipboard_slot.mimes) orelse return null;
        return self.read_offer(offer, 1, mime, &self.clip_read);
    }

    pub fn set_primary(self: *WaylandConnection, text: []const u8) bool {
        const manager = self.primary_manager orelse return false;
        const device = self.primary_device orelse return false;
        if (self.last_serial == 0) return false;
        const copy = self.allocator.dupe(u8, text) catch return false;
        if (self.primary_offer_text) |old| self.allocator.free(old);
        self.primary_offer_text = copy;
        if (self.primary_source) |old| self.api.wl_proxy_destroy(@ptrCast(old));
        self.primary_source = null;
        const raw = self.api.wl_proxy_marshal_flags(@ptrCast(manager), 0, &proto.primary_source_interface, 1, 0, @as(?*anyopaque, null));
        const source: *proto.PrimarySource = @ptrCast(raw orelse return false);
        _ = self.api.wl_proxy_add_listener(@ptrCast(source), &primary_source_listener, self);
        for ([_][*:0]const u8{ MIME_UTF8, MIME_TEXT_UTF8, MIME_TEXT, MIME_STRING }) |mime| {
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(source), 0, null, 1, 0, mime);
        }
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(device), 0, null, 1, 0, @as(*anyopaque, @ptrCast(source)), self.last_serial);
        self.primary_source = source;
        self.owning_primary = true;
        _ = self.api.wl_display_flush(self.display);
        return true;
    }

    pub fn get_primary(self: *WaylandConnection) ?[]const u8 {
        if (self.owning_primary) return self.primary_offer_text;
        _ = self.api.wl_display_roundtrip(self.display);
        const offer = self.primary_slot.current orelse return null;
        const mime = best_offer_mime(self.primary_slot.mimes) orelse return null;
        return self.read_offer(offer, 0, mime, &self.primary_read);
    }

    /// Asks the selection owner for its text through a pipe. `receive_opcode` is the
    /// offer's `receive` request. The result stays valid until the next read into `slot`.
    fn read_offer(self: *WaylandConnection, offer: *anyopaque, receive_opcode: u32, mime: [*:0]const u8, slot: *?[]u8) ?[]const u8 {
        var fds: [2]c_int = .{ -1, -1 };
        if (std.os.linux.pipe(&fds) != 0) return null;
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), receive_opcode, null, 1, 0, mime, fds[1]);
        _ = std.os.linux.close(fds[1]);
        _ = self.api.wl_display_flush(self.display);
        defer _ = std.os.linux.close(fds[0]);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        const deadline = input.now_ms() + 1000;
        var chunk: [4096]u8 = undefined;
        while (input.now_ms() < deadline and out.items.len < 1 << 20) {
            var pfd = [1]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfd, 25) catch 0;
            if (ready > 0) {
                const n = std.os.linux.read(fds[0], &chunk, chunk.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                out.appendSlice(self.allocator, chunk[0..n]) catch return null;
            } else {
                _ = self.api.wl_display_dispatch_pending(self.display);
            }
        }
        if (slot.*) |old| self.allocator.free(old);
        slot.* = self.allocator.dupe(u8, out.items) catch null;
        return slot.*;
    }

    // -- cursor and displays --------------------------------------------

    pub fn set_cursor_style(self: *WaylandConnection, style: CursorStyle) void {
        // Windows report their cursor every frame; the compositor only needs changes.
        // A new pointer enter re-applies it, because the compositor resets it then.
        if (style == self.cursor_style) return;
        self.cursor_style = style;
        self.apply_cursor();
        self.flush();
    }
};

/// `wp_cursor_shape_device_v1.shape` for a style, as in gpui_linux `to_shape`.
fn cursorShape(style: CursorStyle) u32 {
    return switch (style) {
        .arrow, .none => 1,
        .context_menu => 2,
        .pointing_hand => 4,
        .crosshair => 8,
        .i_beam => 9,
        .i_beam_cursor_for_vertical_layout => 10,
        .drag_link => 11,
        .drag_copy => 12,
        .operation_not_allowed => 15,
        .open_hand => 16,
        .closed_hand => 17,
        .resize_right => 18,
        .resize_up => 19,
        .resize_down => 22,
        .resize_left => 25,
        .resize_left_right => 26,
        .resize_up_down => 27,
        .resize_up_right_down_left => 28,
        .resize_up_left_down_right => 29,
        .resize_column => 30,
        .resize_row => 31,
    };
}

fn cursorName(style: CursorStyle) [*:0]const u8 {
    return switch (style) {
        .arrow, .context_menu, .drag_link, .drag_copy, .operation_not_allowed => "left_ptr",
        .i_beam, .i_beam_cursor_for_vertical_layout => "xterm",
        .crosshair => "crosshair",
        .pointing_hand => "hand2",
        .open_hand => "hand1",
        .closed_hand => "grabbing",
        .resize_left, .resize_right, .resize_left_right, .resize_column => "sb_h_double_arrow",
        .resize_up, .resize_down, .resize_up_down, .resize_row => "sb_v_double_arrow",
        .resize_up_left_down_right => "bottom_right_corner",
        .resize_up_right_down_left => "bottom_left_corner",
        .none => "left_ptr",
    };
}

// -- registry and globals -----------------------------------------------

fn registryGlobal(data: ?*anyopaque, reg: *proto.Registry, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
    const self: *WaylandConnection = @ptrCast(@alignCast(data.?));
    const api = self.api;
    const iface_name = std.mem.span(iface);
    if (std.mem.eql(u8, iface_name, "wl_compositor")) {
        const ver: u32 = @min(version, 4);
        self.compositor = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, api.wl_compositor_interface, ver, 0, name, api.wl_compositor_interface.name, ver, api.wl_compositor_interface));
    } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
        self.shm = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, api.wl_shm_interface, @as(u32, 1), 0, name, api.wl_shm_interface.name, @as(u32, 1), api.wl_shm_interface));
    } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
        const ver: u32 = @min(version, 5);
        self.wm_base = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.xdg_wm_base_interface, ver, 0, name, proto.xdg_wm_base_interface.name, ver, &proto.xdg_wm_base_interface));
    } else if (std.mem.eql(u8, iface_name, "wl_seat")) {
        const ver: u32 = @min(version, 5);
        self.seat = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, api.wl_seat_interface, ver, 0, name, api.wl_seat_interface.name, ver, api.wl_seat_interface));
    } else if (std.mem.eql(u8, iface_name, "wl_data_device_manager")) {
        self.ddm = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.data_device_manager_interface, @as(u32, 1), 0, name, proto.data_device_manager_interface.name, @as(u32, 1), &proto.data_device_manager_interface));
    } else if (std.mem.eql(u8, iface_name, "zxdg_decoration_manager_v1")) {
        self.dec_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.decoration_manager_interface, @as(u32, 1), 0, name, proto.decoration_manager_interface.name, @as(u32, 1), &proto.decoration_manager_interface));
    } else if (std.mem.eql(u8, iface_name, "wp_viewporter")) {
        self.viewporter = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.viewporter_interface, @as(u32, 1), 0, name, proto.viewporter_interface.name, @as(u32, 1), &proto.viewporter_interface);
    } else if (std.mem.eql(u8, iface_name, "wp_fractional_scale_manager_v1")) {
        self.frac_manager = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.fractional_scale_manager_interface, @as(u32, 1), 0, name, proto.fractional_scale_manager_interface.name, @as(u32, 1), &proto.fractional_scale_manager_interface);
    } else if (std.mem.eql(u8, iface_name, "wp_cursor_shape_manager_v1")) {
        self.cursor_shape_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.cursor_shape_manager_interface, @as(u32, 1), 0, name, proto.cursor_shape_manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "zwp_primary_selection_device_manager_v1")) {
        self.primary_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.primary_device_manager_interface, @as(u32, 1), 0, name, proto.primary_device_manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "wl_output")) {
        if (self.output_count < max_outputs) {
            const ver: u32 = @min(version, 3);
            const out_iface = self.lib.lookup(*const proto.Interface, "wl_output_interface") orelse return;
            const proxy = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, out_iface, ver, 0, name, out_iface.name, ver, out_iface);
            if (proxy) |p| {
                self.outputs[self.output_count] = .{ .proxy = p, .name = name };
                _ = api.wl_proxy_add_listener(p, &WaylandConnection.output_listener, &self.outputs[self.output_count]);
                self.output_count += 1;
            }
        }
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: *proto.Registry, _: u32) callconv(.c) void {}

fn seatCapabilities(data: ?*anyopaque, _: *proto.Seat, caps: u32) callconv(.c) void {
    const self: *WaylandConnection = @ptrCast(@alignCast(data.?));
    self.seat_caps = caps;
    self.ensure_seat_devices();
}

fn seatName(_: ?*anyopaque, _: *proto.Seat, _: [*:0]const u8) callconv(.c) void {}

fn outputGeometry(_: ?*anyopaque, _: *anyopaque, _: i32, _: i32, _: i32, _: i32, _: i32, _: ?[*:0]const u8, _: ?[*:0]const u8, _: i32) callconv(.c) void {}

fn outputMode(data: ?*anyopaque, _: *anyopaque, flags: u32, w: i32, h: i32, _: i32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data.?));
    if (flags & 1 != 0) { // current mode
        out.pending_w = w;
        out.pending_h = h;
    }
}

fn outputDone(data: ?*anyopaque, _: *anyopaque) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data.?));
    out.width = out.pending_w;
    out.height = out.pending_h;
}

fn outputScale(data: ?*anyopaque, _: *anyopaque, factor: i32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data.?));
    out.scale = @max(1, factor);
}

// -- pointer ------------------------------------------------------------

fn pointerConn(data: ?*anyopaque) *WaylandConnection {
    return @ptrCast(@alignCast(data.?));
}

fn pointerEnter(data: ?*anyopaque, _: *proto.Pointer, serial: u32, surface: *proto.Surface, sx: i32, sy: i32) callconv(.c) void {
    const self = pointerConn(data);
    self.last_serial = serial;
    self.pointer_enter_serial = serial;
    self.pointer_focus = self.find_window(surface) orelse return;
    self.set_pointer_position(sx, sy);
    const w = self.pointer_focus.?;
    w.base.emit_hover(true);
    _ = w.base.emit_input(.{ .mouse_move = .{
        .position = self.pointer_pos,
        .pressed_button = self.pressed,
        .modifiers = input.modifiers(self.mods),
    } });
    self.apply_cursor();
    self.flush();
}

fn pointerLeave(data: ?*anyopaque, _: *proto.Pointer, _: u32, surface: *proto.Surface) callconv(.c) void {
    const self = pointerConn(data);
    const w = self.find_window(surface) orelse return;
    if (self.pointer_focus != w) return;
    _ = w.base.emit_input(.{ .mouse_exited = .{
        .position = self.pointer_pos,
        .pressed_button = self.pressed,
        .modifiers = input.modifiers(self.mods),
    } });
    self.pointer_focus = null;
    self.pressed = null;
    self.axis_v = .{};
    self.axis_h = .{};
    w.base.emit_hover(false);
}

fn pointerMotion(data: ?*anyopaque, _: *proto.Pointer, _: u32, sx: i32, sy: i32) callconv(.c) void {
    const self = pointerConn(data);
    const w = self.pointer_focus orelse return;
    self.set_pointer_position(sx, sy);
    _ = w.base.emit_input(.{ .mouse_move = .{
        .position = self.pointer_pos,
        .pressed_button = self.pressed,
        .modifiers = input.modifiers(self.mods),
    } });
}

fn pointerButton(data: ?*anyopaque, _: *proto.Pointer, serial: u32, _: u32, code: u32, state: u32) callconv(.c) void {
    const self = pointerConn(data);
    self.last_serial = serial;
    const w = self.pointer_focus orelse return;
    const button = input.evdev_button(code) orelse return;
    const pressed = state == 1;
    if (pressed) {
        self.pressed = button;
        const count = self.click.press(button, self.pointer_pos);
        _ = w.base.emit_input(.{ .mouse_down = .{
            .button = button,
            .position = self.pointer_pos,
            .modifiers = input.modifiers(self.mods),
            .click_count = count,
        } });
    } else {
        if (self.pressed) |p| if (p.eql(button)) {
            self.pressed = null;
        };
        _ = w.base.emit_input(.{ .mouse_up = .{
            .button = button,
            .position = self.pointer_pos,
            .modifiers = input.modifiers(self.mods),
            .click_count = self.click.count,
        } });
    }
}

fn pointerAxis(data: ?*anyopaque, _: *proto.Pointer, _: u32, axis: u32, value: i32) callconv(.c) void {
    const self = pointerConn(data);
    const px = proto.wlFixedToFloat(value);
    if (axis == 0) self.axis_v.value = px else self.axis_h.value = px;
}

fn pointerAxisDiscrete(data: ?*anyopaque, _: *proto.Pointer, axis: u32, discrete: i32) callconv(.c) void {
    const self = pointerConn(data);
    if (axis == 0) self.axis_v.discrete = discrete else self.axis_h.discrete = discrete;
}

fn pointerAxisValue120(data: ?*anyopaque, _: *proto.Pointer, axis: u32, v120: i32) callconv(.c) void {
    const self = pointerConn(data);
    if (axis == 0) self.axis_v.v120 = v120 else self.axis_h.v120 = v120;
}

fn pointerFrame(data: ?*anyopaque, _: *proto.Pointer) callconv(.c) void {
    pointerConn(data).flush_axes();
}

fn pointerNoopSource(_: ?*anyopaque, _: *proto.Pointer, _: u32) callconv(.c) void {}
fn pointerNoopStop(_: ?*anyopaque, _: *proto.Pointer, _: u32, _: u32) callconv(.c) void {}
fn pointerNoopDirection(_: ?*anyopaque, _: *proto.Pointer, _: u32, _: u32) callconv(.c) void {}

// -- keyboard -----------------------------------------------------------

fn keyboardKeymap(data: ?*anyopaque, _: *proto.Keyboard, format: u32, fd_: i32, size: u32) callconv(.c) void {
    const self = pointerConn(data);
    if (fd_ < 0) return;
    defer _ = std.os.linux.close(fd_);
    if (format != proto.WL_KEYMAP_FORMAT_XKB_V1 or size == 0 or size > 4 * 1024 * 1024) return;
    const x = if (self.xkb) |*x| x else return;
    const map = std.os.linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd_, 0);
    if (@as(isize, @bitCast(map)) < 0) return;
    const bytes: [*]const u8 = @ptrFromInt(map);
    defer _ = std.os.linux.munmap(bytes, size);
    x.setKeymapBuffer(bytes, size) catch {
        self.xkb = null;
    };
}

fn keyboardEnter(data: ?*anyopaque, _: *proto.Keyboard, serial: u32, surface: *proto.Surface, _: ?*anyopaque) callconv(.c) void {
    const self = pointerConn(data);
    self.last_serial = serial;
    if (self.keyboard_focus) |old| old.base.emit_active(false);
    self.keyboard_focus = self.find_window(surface);
    if (self.keyboard_focus) |w| w.base.emit_active(true);
}

fn keyboardLeave(data: ?*anyopaque, _: *proto.Keyboard, _: u32, surface: *proto.Surface) callconv(.c) void {
    const self = pointerConn(data);
    const w = self.find_window(surface) orelse return;
    if (self.keyboard_focus != w) return;
    self.keyboard_focus = null;
    self.repeat.active = false;
    if (self.compose) |*c| c.reset();
    w.base.emit_active(false);
}

fn keyboardKey(data: ?*anyopaque, _: *proto.Keyboard, serial: u32, _: u32, code: u32, state: u32) callconv(.c) void {
    const self = pointerConn(data);
    self.last_serial = serial;
    const pressed = state == 1;
    if (self.xkb) |*x| {
        if (x.hasLiveState()) x.updateKey(code + 8, pressed);
    }
    self.handle_key(code, pressed);
}

fn keyboardModifiers(data: ?*anyopaque, _: *proto.Keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
    const self = pointerConn(data);
    self.mods = depressed | latched;
    if (self.xkb) |*x| x.syncModifiers(depressed, latched, locked, group);
    self.emit_modifiers();
}

fn keyboardRepeatInfo(data: ?*anyopaque, _: *proto.Keyboard, rate: i32, delay: i32) callconv(.c) void {
    const self = pointerConn(data);
    if (rate > 0 and delay >= 0) {
        self.repeat_rate = rate;
        self.repeat_delay_ms = delay;
    } else {
        self.repeat_rate = 0;
        self.repeat.active = false;
    }
}

// -- data device (clipboard) --------------------------------------------

fn dataOfferOffer(data: ?*anyopaque, _: *proto.DataOffer, mime: [*:0]const u8) callconv(.c) void {
    const self = pointerConn(data);
    self.clipboard_slot.incoming_mimes |= WaylandConnection.offer_mime_bit(std.mem.span(mime));
}

fn dataDeviceOffer(data: ?*anyopaque, _: *proto.DataDevice, offer: *proto.DataOffer) callconv(.c) void {
    const self = pointerConn(data);
    self.clipboard_slot.incoming = offer;
    self.clipboard_slot.incoming_mimes = 0;
    _ = self.api.wl_proxy_add_listener(@ptrCast(offer), &WaylandConnection.data_offer_listener, self);
}

fn dataDeviceEnter(_: ?*anyopaque, _: *proto.DataDevice, _: u32, _: *proto.Surface, _: i32, _: i32, _: ?*proto.DataOffer) callconv(.c) void {}
fn dataDeviceLeave(_: ?*anyopaque, _: *proto.DataDevice) callconv(.c) void {}
fn dataDeviceMotion(_: ?*anyopaque, _: *proto.DataDevice, _: u32, _: i32, _: i32) callconv(.c) void {}
fn dataDeviceDrop(_: ?*anyopaque, _: *proto.DataDevice) callconv(.c) void {}

fn dataDeviceSelection(data: ?*anyopaque, _: *proto.DataDevice, offer: ?*proto.DataOffer) callconv(.c) void {
    const self = pointerConn(data);
    // wl_data_offer.destroy is request 2. Ownership ends with the source's `cancelled`.
    self.commit_offer(&self.clipboard_slot, offer, 2);
}

fn primaryOfferOffer(data: ?*anyopaque, _: *proto.PrimaryOffer, mime: [*:0]const u8) callconv(.c) void {
    const self = pointerConn(data);
    self.primary_slot.incoming_mimes |= WaylandConnection.offer_mime_bit(std.mem.span(mime));
}

fn primaryDeviceOffer(data: ?*anyopaque, _: *proto.PrimaryDevice, offer: *proto.PrimaryOffer) callconv(.c) void {
    const self = pointerConn(data);
    self.primary_slot.incoming = offer;
    self.primary_slot.incoming_mimes = 0;
    _ = self.api.wl_proxy_add_listener(@ptrCast(offer), &WaylandConnection.primary_offer_listener, self);
}

fn primaryDeviceSelection(data: ?*anyopaque, _: *proto.PrimaryDevice, offer: ?*proto.PrimaryOffer) callconv(.c) void {
    const self = pointerConn(data);
    self.commit_offer(&self.primary_slot, offer, 1);
}

fn primarySourceSend(data: ?*anyopaque, _: *proto.PrimarySource, _: [*:0]const u8, fd_: i32) callconv(.c) void {
    const self = pointerConn(data);
    write_all_and_close(fd_, self.primary_offer_text);
}

fn primarySourceCancelled(data: ?*anyopaque, source: *proto.PrimarySource) callconv(.c) void {
    const self = pointerConn(data);
    self.owning_primary = false;
    if (self.primary_source == source) {
        self.api.wl_proxy_destroy(@ptrCast(source));
        self.primary_source = null;
    }
}

fn write_all_and_close(fd_: i32, maybe_text: ?[]const u8) void {
    defer _ = std.os.linux.close(fd_);
    const text = maybe_text orelse return;
    var off: usize = 0;
    while (off < text.len) {
        const n = std.os.linux.write(fd_, text[off..].ptr, text.len - off);
        if (@as(isize, @bitCast(n)) <= 0) break;
        off += n;
    }
}

fn dataSourceTarget(_: ?*anyopaque, _: *proto.DataSource, _: ?[*:0]const u8) callconv(.c) void {}

fn dataSourceSend(data: ?*anyopaque, _: *proto.DataSource, _: [*:0]const u8, fd_: i32) callconv(.c) void {
    const self = pointerConn(data);
    write_all_and_close(fd_, self.clip_offer);
}

fn dataSourceCancelled(data: ?*anyopaque, source: *proto.DataSource) callconv(.c) void {
    const self = pointerConn(data);
    self.owning_selection = false;
    if (self.data_source == source) {
        self.api.wl_proxy_destroy(@ptrCast(source));
        self.data_source = null;
    }
}

// -- xdg shell ------------------------------------------------------------

fn xdgPing(data: ?*anyopaque, wm: *proto.XdgWmBase, serial: u32) callconv(.c) void {
    const self = pointerConn(data);
    _ = self.api.wl_proxy_marshal_flags(@ptrCast(wm), 3, null, self.api.wl_proxy_get_version(@ptrCast(wm)), 0, serial);
}

// -- windows ----------------------------------------------------------------

/// A wl_shm buffer pair entry. `busy` is set on commit and cleared by release.
const ShmBuffer = struct {
    buf: ?*proto.Buffer = null,
    pixels: ?[]u8 = null,
    fd: c_int = -1,
    w: u32 = 0,
    h: u32 = 0,
    busy: bool = false,
};

const PendingConfigure = struct {
    width: i32 = 0,
    height: i32 = 0,
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
};

pub const WaylandWindow = struct {
    base: platform.PlatformWindow = .{ .vtable = &vtable },
    allocator: std.mem.Allocator,
    conn: *WaylandConnection,
    surface: ?*proto.Surface = null,
    xdg_surface: ?*proto.XdgSurface = null,
    xdg_toplevel: ?*proto.XdgToplevel = null,
    decoration: ?*proto.Decoration = null,
    viewport: ?*anyopaque = null,
    frac_scale: ?*anyopaque = null,
    opaque_region: ?*proto.Region = null,
    frame_callback: ?*proto.Callback = null,
    bufs: [2]ShmBuffer = .{ .{}, .{} },
    /// Logical size as configured by the compositor (or requested at creation).
    size: PxSize,
    /// Device scale: fractional when viewporter is available, else an integer.
    scale: f32 = 1,
    decorated: bool = true,
    fractional: bool = false,
    configured: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    frame_wanted: bool = false,
    drew: bool = false,
    closed: bool = false,
    atlas: atlas_mod.CpuAtlas,
    renderer: cpu.CpuRenderer,
    /// Set when this window draws with the GPU; `atlas` and `renderer` then stay idle.
    gpu_window: ?window_renderer.GpuWindow = null,
    /// State from xdg_toplevel.configure, applied atomically by xdg_surface.configure.
    pending_configure: PendingConfigure = .{},
    /// Interactive resizes apply at most once per frame, as in GPUI.
    resize_throttle: bool = false,

    const vtable: platform.PlatformWindow.VTable = .{
        .bounds = bounds,
        .content_size = contentSize,
        .scale_factor = scaleFactor,
        .request_frame = requestFrame,
        .draw = draw,
        .sprite_atlas = spriteAtlas,
        .set_title = setTitle,
        .minimize = minimize,
        .zoom = zoom,
        .toggle_fullscreen = toggleFullscreen,
        .start_window_move = startWindowMove,
        .close = close,
    };

    const xs_listener: proto.XdgSurfaceListener = .{ .configure = xdgSurfaceConfigure };
    const top_listener: proto.XdgToplevelListener = .{ .configure = xdgToplevelConfigure, .close = xdgToplevelClose, .configure_bounds = xdgNoopBounds, .wm_capabilities = xdgNoopCaps };
    const callback_listener: proto.WlCallbackListener = .{ .done = frameDone };
    const buffer_listener: proto.WlBufferListener = .{ .release = bufferRelease };
    const deco_listener: proto.DecorationListener = .{ .configure = decorationConfigure };
    const frac_listener: proto.FractionalScaleListener = .{ .preferred_scale = fractionalPreferredScale };

    pub fn from(p: *platform.PlatformWindow) *WaylandWindow {
        return @fieldParentPtr("base", p);
    }

    fn api(self: *WaylandWindow) *const proto.WaylandApi {
        return &self.conn.api;
    }

    fn create_surface(self: *WaylandWindow, options: window_mod.WindowOptions) !void {
        const c = self.conn;
        const a = &c.api;
        const compositor = c.compositor orelse return error.MissingWaylandGlobals;
        const wm_base = c.wm_base orelse return error.MissingWaylandGlobals;
        const surf_raw = a.wl_proxy_marshal_flags(@ptrCast(compositor), 0, a.wl_surface_interface, a.wl_proxy_get_version(@ptrCast(compositor)), 0, @as(?*anyopaque, null));
        self.surface = @ptrCast(surf_raw orelse return error.CannotCreateSurface);
        const surface = self.surface.?;

        if (c.viewporter) |vm| {
            const vp = a.wl_proxy_marshal_flags(@ptrCast(vm), 1, &proto.viewport_interface, a.wl_proxy_get_version(@ptrCast(vm)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(surface)));
            self.viewport = vp;
        }
        if (c.frac_manager) |fm| if (c.viewporter != null) {
            self.frac_scale = a.wl_proxy_marshal_flags(@ptrCast(fm), 1, &proto.fractional_scale_interface, a.wl_proxy_get_version(@ptrCast(fm)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(surface)));
            if (self.frac_scale) |f| _ = a.wl_proxy_add_listener(f, &frac_listener, self);
        };
        self.fractional = self.viewport != null;
        if (!self.fractional) self.scale = @max(1, @round(self.scale));

        self.update_opaque_region();

        const xs_raw = a.wl_proxy_marshal_flags(@ptrCast(wm_base), 2, &proto.xdg_surface_interface, a.wl_proxy_get_version(@ptrCast(wm_base)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(surface)));
        self.xdg_surface = @ptrCast(xs_raw orelse return error.CannotCreateXdgSurface);
        const xs = self.xdg_surface.?;
        _ = a.wl_proxy_add_listener(@ptrCast(xs), &xs_listener, self);

        const top_raw = a.wl_proxy_marshal_flags(@ptrCast(xs), 1, &proto.xdg_toplevel_interface, a.wl_proxy_get_version(@ptrCast(xs)), 0, @as(?*anyopaque, null));
        self.xdg_toplevel = @ptrCast(top_raw orelse return error.CannotCreateToplevel);
        const top = self.xdg_toplevel.?;
        _ = a.wl_proxy_add_listener(@ptrCast(top), &top_listener, self);

        if (options.titlebar) |t| if (t.title) |title| self.set_title(title);
        if (options.app_id) |app_id| {
            var buf: [256]u8 = undefined;
            const n = @min(app_id.len, buf.len - 1);
            @memcpy(buf[0..n], app_id[0..n]);
            buf[n] = 0;
            _ = a.wl_proxy_marshal_flags(@ptrCast(top), 3, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as([*:0]const u8, @ptrCast(&buf)));
        }
        if (c.dec_manager) |dm| {
            if (a.wl_proxy_marshal_flags(@ptrCast(dm), 1, &proto.decoration_interface, a.wl_proxy_get_version(@ptrCast(dm)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(top)))) |d| {
                self.decoration = @ptrCast(d);
                _ = a.wl_proxy_add_listener(d, &deco_listener, self);
                self.apply_decoration_mode();
            }
        }
        // Empty commit asks the compositor for the first configure.
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 6, null, a.wl_proxy_get_version(@ptrCast(surface)), 0);
        self.apply_buffer_scale();
    }

    fn apply_decoration_mode(self: *WaylandWindow) void {
        const deco = self.decoration orelse return;
        const a = self.api();
        if (self.decorated) {
            _ = a.wl_proxy_marshal_flags(@ptrCast(deco), 1, null, 1, 0, proto.DECOR_MODE_SERVER_SIDE);
        } else {
            _ = a.wl_proxy_marshal_flags(@ptrCast(deco), 1, null, 1, 0, proto.DECOR_MODE_CLIENT_SIDE);
        }
    }

    /// Declares the whole surface opaque so compositors skip blending it.
    fn update_opaque_region(self: *WaylandWindow) void {
        const surface = self.surface orelse return;
        const c = self.conn;
        const a = &c.api;
        const compositor = c.compositor orelse return;
        if (self.opaque_region) |r| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(r), 0, null, a.wl_proxy_get_version(@ptrCast(r)), 1);
            self.opaque_region = null;
        }
        const reg_raw = a.wl_proxy_marshal_flags(@ptrCast(compositor), 1, a.wl_region_interface, a.wl_proxy_get_version(@ptrCast(compositor)), 0, @as(?*anyopaque, null));
        const region: *proto.Region = @ptrCast(reg_raw orelse return);
        self.opaque_region = region;
        const w: i32 = @intFromFloat(self.size.width);
        const h: i32 = @intFromFloat(self.size.height);
        _ = a.wl_proxy_marshal_flags(@ptrCast(region), 1, null, a.wl_proxy_get_version(@ptrCast(region)), 0, @as(i32, 0), @as(i32, 0), w, h);
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 4, null, a.wl_proxy_get_version(@ptrCast(surface)), 0, @as(?*anyopaque, @ptrCast(region)));
    }

    fn apply_buffer_scale(self: *WaylandWindow) void {
        const surface = self.surface orelse return;
        const a = self.api();
        if (self.viewport) |vp| {
            _ = a.wl_proxy_marshal_flags(vp, 2, null, 1, 0, @as(i32, @intFromFloat(self.size.width)), @as(i32, @intFromFloat(self.size.height)));
        } else {
            _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 8, null, a.wl_proxy_get_version(@ptrCast(surface)), 0, @as(i32, @intFromFloat(self.scale)));
        }
    }

    /// Physical framebuffer dimensions (logical size times device scale).
    fn phys_w(self: *const WaylandWindow) u32 {
        return @intFromFloat(@max(1, @round(self.size.width * self.scale)));
    }
    fn phys_h(self: *const WaylandWindow) u32 {
        return @intFromFloat(@max(1, @round(self.size.height * self.scale)));
    }

    fn set_title(self: *WaylandWindow, title: []const u8) void {
        const top = self.xdg_toplevel orelse return;
        var buf: [512]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(top), 2, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as([*:0]const u8, @ptrCast(&buf)));
    }

    // -- frames and buffers -------------------------------------------------

    /// Emits request_frame and arms a frame callback. Commits even when the
    /// app did not draw, so the callback can complete.
    fn emit_frame(self: *WaylandWindow) void {
        const a = self.api();
        self.frame_wanted = false;
        self.drew = false;
        if (self.surface) |surface| {
            if (a.wl_proxy_marshal_flags(@ptrCast(surface), 3, &proto.wl_callback_interface, a.wl_proxy_get_version(@ptrCast(surface)), 0)) |cb| {
                self.frame_callback = @ptrCast(cb);
                _ = a.wl_proxy_add_listener(cb, &callback_listener, self);
            }
        }
        self.base.emit_request_frame(.{});
        if (!self.drew) self.commit_surface();
        self.conn.flush();
    }

    fn commit_surface(self: *WaylandWindow) void {
        const surface = self.surface orelse return;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 6, null, a.wl_proxy_get_version(@ptrCast(surface)), 0);
    }

    fn frameDone(data: ?*anyopaque, callback: *proto.Callback, _: u32) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (self.frame_callback == callback) self.frame_callback = null;
        self.resize_throttle = false;
        self.conn.api.wl_proxy_destroy(@ptrCast(callback));
    }

    fn bufferRelease(data: ?*anyopaque, buf: *proto.Buffer) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        for (&self.bufs) |*e| {
            if (e.buf != buf) continue;
            e.busy = false;
            if (e.w != self.phys_w() or e.h != self.phys_h()) self.destroy_entry(e);
            return;
        }
    }

    fn alloc_entry(self: *WaylandWindow, e: *ShmBuffer, w: u32, h: u32) !void {
        const a = self.api();
        const shm = self.conn.shm orelse return error.NoShmGlobal;
        const stride = w * 4;
        const size = @as(usize, stride) * h;
        const fd_raw = std.os.linux.memfd_create("zui-wayland-shm", 0);
        if (@as(isize, @bitCast(fd_raw)) < 0) return error.MemfdFailed;
        const fd_: c_int = @intCast(fd_raw);
        errdefer _ = std.os.linux.close(fd_);
        if (std.os.linux.ftruncate(fd_, @intCast(size)) != 0) return error.FtruncateFailed;
        const map = std.os.linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd_, 0);
        if (@as(isize, @bitCast(map)) < 0) return error.MmapFailed;
        const px: [*]u8 = @ptrFromInt(map);
        errdefer _ = std.os.linux.munmap(px, size);

        const pool_raw = a.wl_proxy_marshal_flags(@ptrCast(shm), 0, a.wl_shm_pool_interface, a.wl_proxy_get_version(@ptrCast(shm)), 0, @as(?*anyopaque, null), fd_, @as(i32, @intCast(size)));
        const pool: *anyopaque = pool_raw orelse return error.CannotCreateShmPool;
        defer _ = a.wl_proxy_marshal_flags(pool, 1, null, a.wl_proxy_get_version(pool), 1);
        // wl_shm_pool.create_buffer; format 0 is ARGB8888 (bytes B, G, R, A).
        const buf_raw = a.wl_proxy_marshal_flags(pool, 0, a.wl_buffer_interface, a.wl_proxy_get_version(pool), 0, @as(?*anyopaque, null), @as(i32, 0), @as(i32, @intCast(w)), @as(i32, @intCast(h)), @as(i32, @intCast(stride)), @as(u32, 0));
        const buf: *proto.Buffer = @ptrCast(buf_raw orelse return error.CannotCreateBuffer);
        _ = a.wl_proxy_add_listener(@ptrCast(buf), &buffer_listener, self);
        e.* = .{ .buf = buf, .pixels = px[0..size], .fd = fd_, .w = w, .h = h, .busy = false };
    }

    fn destroy_entry(self: *WaylandWindow, e: *ShmBuffer) void {
        const a = self.api();
        if (e.buf) |b| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(b), 0, null, a.wl_proxy_get_version(@ptrCast(b)), 1);
            e.buf = null;
        }
        if (e.pixels) |px| {
            _ = std.os.linux.munmap(px.ptr, px.len);
            e.pixels = null;
        }
        if (e.fd >= 0) {
            _ = std.os.linux.close(e.fd);
            e.fd = -1;
        }
        e.busy = false;
        e.w = 0;
        e.h = 0;
    }

    /// Returns an idle buffer of the physical size, allocating one if needed.
    fn acquire(self: *WaylandWindow, w: u32, h: u32) ?*ShmBuffer {
        for (&self.bufs) |*e| {
            if (!e.busy and e.buf != null and e.w == w and e.h == h) return e;
        }
        for (&self.bufs) |*e| {
            if (e.busy) continue;
            if (e.buf != null) self.destroy_entry(e);
            self.alloc_entry(e, w, h) catch |err| {
                std.log.warn("wayland: buffer {d}x{d} failed: {s}", .{ w, h, @errorName(err) });
                return null;
            };
            return e;
        }
        return null;
    }

    // -- vtable -------------------------------------------------------------

    fn bounds(p: *platform.PlatformWindow) PxBounds {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = from(p).size };
    }
    fn contentSize(p: *platform.PlatformWindow) PxSize {
        return from(p).size;
    }
    fn scaleFactor(p: *platform.PlatformWindow) f32 {
        return from(p).scale;
    }
    fn requestFrame(p: *platform.PlatformWindow) void {
        from(p).frame_wanted = true;
    }
    fn spriteAtlas(p: *platform.PlatformWindow) atlas_mod.PlatformAtlas {
        const self = from(p);
        if (self.gpu_window) |*g| return g.ctx.sprite_atlas();
        return self.atlas.platform_atlas();
    }
    fn setTitle(p: *platform.PlatformWindow, title: []const u8) void {
        from(p).set_title(title);
    }
    fn minimize(p: *platform.PlatformWindow) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        _ = self.api().wl_proxy_marshal_flags(@ptrCast(top), 13, null, self.api().wl_proxy_get_version(@ptrCast(top)), 0);
        self.conn.flush();
    }
    fn zoom(p: *platform.PlatformWindow) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        const opcode: u32 = if (self.maximized) 10 else 9;
        _ = self.api().wl_proxy_marshal_flags(@ptrCast(top), opcode, null, self.api().wl_proxy_get_version(@ptrCast(top)), 0);
        self.conn.flush();
    }
    fn toggleFullscreen(p: *platform.PlatformWindow) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        const a = self.api();
        if (self.fullscreen) {
            _ = a.wl_proxy_marshal_flags(@ptrCast(top), 12, null, a.wl_proxy_get_version(@ptrCast(top)), 0);
        } else {
            _ = a.wl_proxy_marshal_flags(@ptrCast(top), 11, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as(?*anyopaque, null));
        }
        self.conn.flush();
    }
    fn startWindowMove(p: *platform.PlatformWindow) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        const seat = self.conn.seat orelse return;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(top), 5, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as(*anyopaque, @ptrCast(seat)), self.conn.last_serial);
        self.conn.flush();
    }

    fn draw(p: *platform.PlatformWindow, scene: *const scene_mod.Scene) void {
        const self = from(p);
        if (self.closed or !self.configured) return;
        const pw = self.phys_w();
        const ph = self.phys_h();
        if (self.gpu_window) |*g| {
            // The present commits the surface, including the frame callback of emit_frame.
            if (g.draw(scene, clear_color, pw, ph)) self.drew = true else self.frame_wanted = true;
            self.conn.flush();
            return;
        }
        const entry = self.acquire(pw, ph) orelse {
            self.frame_wanted = true;
            return;
        };
        const pixels = entry.pixels.?;
        const fb: cpu.Framebuffer = .{ .pixels = pixels, .width = pw, .height = ph, .stride = pw * 4, .format = .bgra8 };
        self.renderer.draw(scene, &self.atlas, fb, clear_color);
        const a = self.api();
        const surface = self.surface orelse return;
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 1, null, a.wl_proxy_get_version(@ptrCast(surface)), 0, @as(?*anyopaque, @ptrCast(entry.buf.?)), @as(i32, 0), @as(i32, 0));
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 2, null, a.wl_proxy_get_version(@ptrCast(surface)), 0, @as(i32, 0), @as(i32, 0), @as(i32, @intFromFloat(self.size.width)), @as(i32, @intFromFloat(self.size.height)));
        entry.busy = true;
        self.drew = true;
        self.commit_surface();
        self.conn.flush();
    }

    fn close(p: *platform.PlatformWindow) void {
        from(p).close_now();
    }

    /// Emits a key press or release with the current modifiers.
    pub fn emit_key(self: *WaylandWindow, name: []const u8, text: ?[]const u8, pressed: bool, held: bool) void {
        const ks = input.make_keystroke(name, text, input.modifiers(self.conn.mods));
        if (pressed) {
            _ = self.base.emit_input(.{ .key_down = .{ .keystroke = ks, .is_held = held } });
        } else {
            _ = self.base.emit_input(.{ .key_up = .{ .keystroke = ks } });
        }
    }

    /// Marks the window closed and releases its compositor objects. Memory is
    /// freed by `WaylandConnection.reap`, so callers may still be inside its events.
    pub fn close_now(self: *WaylandWindow) void {
        if (self.closed) return;
        self.closed = true;
        self.frame_wanted = false;
        self.conn.release_focus(self);
        self.free_protocol();
        self.conn.flush();
    }

    fn free_protocol(self: *WaylandWindow) void {
        const a = &self.conn.api;
        // The Vulkan surface must die before the wl_surface it wraps.
        if (self.gpu_window) |*g| {
            g.deinit();
            self.gpu_window = null;
        }
        if (self.frame_callback) |cb| {
            a.wl_proxy_destroy(@ptrCast(cb));
            self.frame_callback = null;
        }
        if (self.viewport) |vp| {
            _ = a.wl_proxy_marshal_flags(vp, 0, null, a.wl_proxy_get_version(vp), 1);
            self.viewport = null;
        }
        if (self.frac_scale) |f| {
            _ = a.wl_proxy_marshal_flags(f, 0, null, a.wl_proxy_get_version(f), 1);
            self.frac_scale = null;
        }
        if (self.decoration) |d| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(d), 0, null, a.wl_proxy_get_version(@ptrCast(d)), 1);
            self.decoration = null;
        }
        if (self.xdg_toplevel) |t| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(t), 0, null, a.wl_proxy_get_version(@ptrCast(t)), 1);
            self.xdg_toplevel = null;
        }
        if (self.xdg_surface) |xs| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(xs), 0, null, a.wl_proxy_get_version(@ptrCast(xs)), 1);
            self.xdg_surface = null;
        }
        if (self.opaque_region) |r| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(r), 0, null, a.wl_proxy_get_version(@ptrCast(r)), 1);
            self.opaque_region = null;
        }
        for (&self.bufs) |*e| self.destroy_entry(e);
        if (self.surface) |s| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(s), 0, null, a.wl_proxy_get_version(@ptrCast(s)), 1);
            self.surface = null;
        }
        self.configured = false;
    }

    /// Frees a closed window. Called only from `WaylandConnection.reap`.
    pub fn free(self: *WaylandWindow) void {
        if (!self.closed) self.close_now();
        self.atlas.deinit();
        self.renderer.deinit();
        self.allocator.destroy(self);
    }

    // -- xdg callbacks --------------------------------------------------

    fn xdgSurfaceConfigure(data: ?*anyopaque, xs: *proto.XdgSurface, serial: u32) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        const a = self.api();
        const pending = self.pending_configure;
        self.maximized = pending.maximized;
        self.fullscreen = pending.fullscreen;
        if (!(pending.resizing and self.resize_throttle)) {
            if (pending.resizing) self.resize_throttle = true;
            self.apply_configured_size(pending.width, pending.height);
        }
        _ = a.wl_proxy_marshal_flags(@ptrCast(xs), 4, null, a.wl_proxy_get_version(@ptrCast(xs)), 0, serial);
        const first = !self.configured;
        self.configured = true;
        if (first) {
            self.update_opaque_region();
            self.frame_wanted = true;
        }
    }

    fn apply_configured_size(self: *WaylandWindow, width: i32, height: i32) void {
        if (self.closed or width <= 0 or height <= 0) return;
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        if (w == self.size.width and h == self.size.height) return;
        self.size = .{ .width = w, .height = h };
        self.apply_buffer_scale();
        self.update_opaque_region();
        self.base.emit_resize(self.size, self.scale);
        // Arms the frame callback that releases `resize_throttle`.
        self.frame_wanted = true;
    }

    fn xdgToplevelConfigure(data: ?*anyopaque, _: *proto.XdgToplevel, width: i32, height: i32, states: ?*anyopaque) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (self.closed) return;
        var pending: PendingConfigure = .{ .width = width, .height = height };
        if (states) |raw| {
            const arr: *const proto.WlArray = @ptrCast(@alignCast(raw));
            if (arr.data) |items| {
                for (0..arr.size / 4) |i| switch (items[i]) {
                    proto.XDG_STATE_MAXIMIZED => pending.maximized = true,
                    2 => pending.fullscreen = true, // xdg_toplevel.state.fullscreen
                    3 => pending.resizing = true, // xdg_toplevel.state.resizing
                    else => {},
                };
            }
        }
        self.pending_configure = pending;
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: *proto.XdgToplevel) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (self.closed) return;
        if (self.base.emit_should_close()) {
            self.base.emit_close();
        }
    }

    fn xdgNoopBounds(_: ?*anyopaque, _: *proto.XdgToplevel, _: i32, _: i32) callconv(.c) void {}
    fn xdgNoopCaps(_: ?*anyopaque, _: *proto.XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    fn decorationConfigure(_: ?*anyopaque, _: *proto.Decoration, _: u32) callconv(.c) void {}

    /// Preferred scale in 1/120 units (fractional-scale-v1).
    fn fractionalPreferredScale(data: ?*anyopaque, _: *anyopaque, wire: u32) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        const s = @as(f32, @floatFromInt(wire)) / 120.0;
        if (s < 0.25 or s > 8.0 or s == self.scale) return;
        self.scale = s;
        self.base.emit_resize(self.size, self.scale);
    }
};

test "wheel axis: wayland positive is down, lines are negated to positive-up" {
    try std.testing.expectEqual(@as(f32, -1), WaylandConnection.axisLines(.{ .v120 = 120 }, true).?);
    try std.testing.expectEqual(@as(f32, 1), WaylandConnection.axisLines(.{ .v120 = -120 }, true).?);
    try std.testing.expectEqual(@as(f32, 2), WaylandConnection.axisLines(.{ .discrete = -2 }, true).?);
    try std.testing.expectEqual(@as(f32, -1), WaylandConnection.axisLines(.{ .value = 10 }, true).?);
    try std.testing.expect(WaylandConnection.axisLines(.{}, true) == null);
}
