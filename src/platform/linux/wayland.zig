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
const text_input_state = @import("text_input_state.zig");
const wayland_scroll = @import("wayland_scroll.zig");
const xdnd = @import("xdnd.zig");
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

/// The clear of a frame: the window color for an opaque window, transparent for others (GPUI clears
/// a transparent window to transparent and leaves the content to the app).
fn frame_clear(background: window_mod.WindowBackgroundAppearance) Hsla {
    return if (background == .@"opaque") clear_color else color.transparent_black();
}

/// A pixel rectangle in surface coordinates.
pub const IRect = struct { x: i32, y: i32, width: i32, height: i32 };

fn clamp_radius(radius: f32, area: IRect) i32 {
    // Pixels::to_i32 truncates. The radius is capped to what fits in the area; the cap of 2^30 keeps
    // the float-to-int conversion in range for any radius (NaN and negatives mean none).
    const r: i32 = if (radius > 0) @intFromFloat(@min(radius, 1 << 30)) else 0;
    return @min(r, @min(@divTrunc(area.width, 2), @divTrunc(area.height, 2)));
}

/// How far a rounded corner of `radius` cuts into row `row` from its outer edge.
fn corner_inset(radius: i32, row: i32) i32 {
    if (row >= radius) return 0;
    const r: f64 = @floatFromInt(radius);
    const y = r - (@as(f64, @floatFromInt(row)) + 0.5);
    const x = @sqrt(r * r - y * y);
    return @intFromFloat(@ceil(r - x - 0.5));
}

/// Calls `add` with rectangles covering `area` with its corners rounded by `radii` (GPUI
/// `add_rounded_rect`): one-pixel rows along each rounded edge, then the middle band.
pub fn add_rounded_rect(area: IRect, radii: geometry.Corners(f32), context: anytype, comptime add: fn (@TypeOf(context), IRect) void) void {
    if (area.width <= 0 or area.height <= 0) return;
    const top_left = clamp_radius(radii.top_left, area);
    const top_right = clamp_radius(radii.top_right, area);
    const bottom_left = clamp_radius(radii.bottom_left, area);
    const bottom_right = clamp_radius(radii.bottom_right, area);

    const corners = [2]struct { left: i32, right: i32, bottom: bool }{
        .{ .left = top_left, .right = top_right, .bottom = false },
        .{ .left = bottom_left, .right = bottom_right, .bottom = true },
    };
    for (corners) |corner| {
        var row: i32 = 0;
        while (row < @max(corner.left, corner.right)) : (row += 1) {
            const left_inset = corner_inset(corner.left, row);
            const right_inset = corner_inset(corner.right, row);
            const width = area.width - left_inset - right_inset;
            if (width <= 0) continue;
            const y = if (corner.bottom) area.y + area.height - row - 1 else area.y + row;
            add(context, .{ .x = area.x + left_inset, .y = y, .width = width, .height = 1 });
        }
    }

    const top_height = @max(top_left, top_right);
    const bottom_height = @max(bottom_left, bottom_right);
    const height = area.height - top_height - bottom_height;
    if (height > 0) add(context, .{ .x = area.x, .y = area.y + top_height, .width = area.width, .height = height });
}

/// wl_output events (version 4 is bound: geometry, mode, done, scale, name). `description` is
/// opcode 5, which is listed so that libwayland indexes the rest correctly.
const OutputListener = extern struct {
    geometry: ?*const fn (?*anyopaque, *anyopaque, i32, i32, i32, i32, i32, ?[*:0]const u8, ?[*:0]const u8, i32) callconv(.c) void = null,
    mode: ?*const fn (?*anyopaque, *anyopaque, u32, i32, i32, i32) callconv(.c) void = null,
    done: ?*const fn (?*anyopaque, *anyopaque) callconv(.c) void = null,
    scale: ?*const fn (?*anyopaque, *anyopaque, i32) callconv(.c) void = null,
    name: ?*const fn (?*anyopaque, *anyopaque, ?[*:0]const u8) callconv(.c) void = null,
    description: ?*const fn (?*anyopaque, *anyopaque, ?[*:0]const u8) callconv(.c) void = null,
};

const max_outputs = 8;

const Output = struct {
    /// Null for a free slot. A removed output's slot is cleared, never shifted: its address is the
    /// listener's data.
    proxy: ?*anyopaque = null,
    /// The registry name of the global. It is stable for the output's life, so it is the display id.
    name: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    scale: i32 = 1,
    /// Pending mode values, committed on `done`.
    pending_w: i32 = 0,
    pending_h: i32 = 0,
    /// The current mode's refresh rate in millihertz, 0 when unknown (wl_output.mode `refresh`).
    refresh_mhz: i32 = 0,
    /// Version 5 of the name the output announced (wl_output.name), as GPUI's display `uuid`. Null
    /// until the name arrives, or for an output that never names itself.
    uuid: ?platform.Uuid = null,
    pending_refresh_mhz: i32 = 0,
    /// The connection that owns this output; `done` reports changes through it.
    conn: ?*WaylandConnection = null,
};

/// wl_surface events, so a window learns which outputs it is on (GPUI `display`).
const SurfaceListener = extern struct {
    enter: ?*const fn (?*anyopaque, *anyopaque, *anyopaque) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *anyopaque, *anyopaque) callconv(.c) void = null,
    // Versions 4 and 6 add two more events. The listener must list them, since libwayland indexes by opcode.
    preferred_buffer_scale: ?*const fn (?*anyopaque, *anyopaque, i32) callconv(.c) void = null,
    preferred_buffer_transform: ?*const fn (?*anyopaque, *anyopaque, u32) callconv(.c) void = null,
};

const surface_listener: SurfaceListener = .{ .enter = surfaceEnter, .leave = surfaceLeave };

const background_effect_manager_listener: proto.BackgroundEffectManagerListener = .{ .capabilities = backgroundEffectCapabilities };

fn backgroundEffectCapabilities(_: ?*anyopaque, _: *anyopaque, _: u32) callconv(.c) void {}

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

const MIME_URI_LIST: [*:0]const u8 = "text/uri-list";
const mime_bit_uri_list: u8 = 1 << 4;
const dnd_action_none: u32 = 0;
const dnd_action_copy: u32 = 1;
/// A source that sends nothing for this long is given up on, so it cannot hang a drag.
const drag_read_timeout_ms: i64 = 4000;
const drag_read_limit: usize = 16 * 1024 * 1024;

/// One file drag in progress over a window of ours.
const DragSession = struct {
    offer: ?*proto.DataOffer = null,
    window: ?*WaylandWindow = null,
    position: PxPoint = .{ .x = 0, .y = 0 },
    /// The offer has a file list and we accepted it. Finishing is an error otherwise.
    accepted: bool = false,
    /// What the compositor chose. Finishing with none is an error too.
    action: u32 = dnd_action_none,
    /// The pipe the file list arrives through, read without blocking.
    read_fd: c_int = -1,
    read_deadline_ms: i64 = 0,
    data: std.ArrayList(u8) = .empty,
    paths: []const []const u8 = &.{},
    /// The window has been told about the files.
    entered: bool = false,
    /// The drop came first. Leave no longer cancels: the data can still be read, and the
    /// drop completes when it lands.
    drop_pending: bool = false,
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
    system_bell: ?*proto.SystemBell = null,
    text_input_manager: ?*proto.TextInputManager = null,
    text_input: ?*proto.TextInput = null,
    /// Double-buffered text input events; see text_input_state.zig.
    text_input_state: text_input_state.TextInputState = undefined,
    /// The window the compositor says has text-input focus. Tracked apart from keyboard
    /// focus because the two `enter` events can arrive in either order.
    text_input_window: ?*WaylandWindow = null,
    text_input_enabled: bool = false,
    /// Dedupes the rectangle: re-sending it can make an input method redraw and answer.
    last_ime_rect: ?[4]i32 = null,
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
    /// ext-background-effect-v1's manager, for blurred windows. Null when the compositor lacks it.
    background_effects: ?*anyopaque = null,
    outputs: [max_outputs]Output = @splat(.{}),
    displays_: [max_outputs]Display = undefined,
    display_count: usize = 0,
    /// The platform to report display changes to, once it is connected (see `LinuxPlatform.create`).
    platform_: ?*platform.Platform = null,
    /// The layout of the keymap the compositor sent, as last reported.
    layout: xkb.LayoutName = .{},
    /// Set by `hide_cursor_until_mouse_moves`; mouse motion clears it.
    cursor_hidden: bool = false,

    xkb: ?xkb.Xkb = null,
    cursor_lib: ?dl.Library = null,
    cursor_api: ?proto.CursorApi = null,
    cursor_theme: ?*proto.CursorTheme = null,
    /// The cursor theme's name from the desktop settings, NUL-terminated; empty is the default theme.
    cursor_theme_name: [64:0]u8 = std.mem.zeroes([64:0]u8),
    /// The cursor size from the desktop settings, in pixels.
    cursor_size: u32 = 24,
    /// The window appearance the desktop asked for (GPUI `common.appearance`).
    appearance_: platform.WindowAppearance = .light,
    cursor_surface: ?*proto.Surface = null,

    windows: std.ArrayList(*WaylandWindow) = .empty,
    keyboard_focus: ?*WaylandWindow = null,
    pointer_focus: ?*WaylandWindow = null,
    pointer_pos: PxPoint = .{ .x = 0, .y = 0 },
    pointer_enter_serial: u32 = 0,
    last_serial: u32 = 0,
    /// Serial of the last button or key press, which a popup grab must name (GPUI keeps the
    /// same, not the enter events that `last_serial` also takes).
    last_press_serial: u32 = 0,
    pressed: ?MouseButton = null,
    click: input.ClickTracker = .{},
    cursor_style: CursorStyle = .arrow,
    mods: u32 = 0,
    mods_reported: u32 = 0,
    axis_frame: wayland_scroll.AxisFrame = .{},
    drag: DragSession = .{},
    drag_serial: u32 = 0,
    ddm_version: u32 = 1,
    pointer_gestures: ?*proto.PointerGestures = null,
    pinch_gesture: ?*proto.PointerGesturePinch = null,
    /// The scale reported by the last pinch update: events carry totals, ZUI wants changes.
    pinch_scale: f32 = 1,
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
        .axis_source = pointerAxisSource,
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
    const output_listener: OutputListener = .{ .geometry = outputGeometry, .mode = outputMode, .done = outputDone, .scale = outputScale, .name = outputName };
    const data_device_listener: proto.DataDeviceListener = .{
        .data_offer = dataDeviceOffer,
        .enter = dataDeviceEnter,
        .leave = dataDeviceLeave,
        .motion = dataDeviceMotion,
        .drop = dataDeviceDrop,
        .selection = dataDeviceSelection,
    };
    const text_input_listener: proto.TextInputListener = .{
        .enter = textInputEnter,
        .leave = textInputLeave,
        .preedit_string = textInputPreedit,
        .commit_string = textInputCommit,
        .delete_surrounding_text = textInputDeleteSurrounding,
        .done = textInputDone,
    };
    const primary_device_listener: proto.PrimaryDeviceListener = .{ .data_offer = primaryDeviceOffer, .selection = primaryDeviceSelection };
    const primary_offer_listener: proto.PrimaryOfferListener = .{ .offer = primaryOfferOffer };
    const primary_source_listener: proto.PrimarySourceListener = .{ .send = primarySourceSend, .cancelled = primarySourceCancelled };
    const data_offer_listener: proto.DataOfferListener = .{ .offer = dataOfferOffer, .source_actions = dataOfferSourceActions, .action = dataOfferAction };
    const pinch_listener: proto.PointerGesturePinchListener = .{ .begin = pinchBegin, .update = pinchUpdate, .end = pinchEnd };
    const data_source_listener: proto.DataSourceListener = .{ .target = dataSourceTarget, .send = dataSourceSend, .cancelled = dataSourceCancelled, .dnd_drop_performed = dataSourceDndNoop, .dnd_finished = dataSourceDndNoop, .action = dataSourceActionNoop };
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
        self.text_input_state = .{ .allocator = self.allocator };
        return self;
    }

    fn cursor_theme_ptr(self: *const WaylandConnection) ?[*:0]const u8 {
        if (self.cursor_theme_name[0] == 0) return null;
        return &self.cursor_theme_name;
    }

    /// Loads the cursor theme again with the settings' name and size (GPUI `cursor.set_theme` and `set_size`).
    fn reload_cursor_theme(self: *WaylandConnection) void {
        const api = self.cursor_api orelse return;
        const shm = self.shm orelse return;
        const theme = api.theme_load(self.cursor_theme_ptr(), @intCast(self.cursor_size), shm) orelse return;
        if (self.cursor_theme) |old| api.theme_destroy(old);
        self.cursor_theme = theme;
    }

    pub fn set_cursor_theme(self: *WaylandConnection, name: []const u8) void {
        const n = @min(name.len, self.cursor_theme_name.len);
        @memcpy(self.cursor_theme_name[0..n], name[0..n]);
        self.cursor_theme_name[n] = 0;
        self.reload_cursor_theme();
    }

    pub fn set_cursor_size(self: *WaylandConnection, size: u32) void {
        if (size == self.cursor_size) return;
        self.cursor_size = size;
        self.reload_cursor_theme();
    }

    /// Tells every window the appearance changed. Each window reads it back from `appearance_`.
    pub fn set_appearance(self: *WaylandConnection, appearance: platform.WindowAppearance) void {
        if (self.appearance_ == appearance) return;
        self.appearance_ = appearance;
        for (self.windows.items) |w| w.base.emit_appearance_changed();
    }

    fn load_cursor_theme(self: *WaylandConnection) void {
        const shm = self.shm orelse return;
        var clib = dl.Library.open(proto.cursor_lib_names) orelse return;
        const capi = proto.CursorApi.load(clib) orelse {
            clib.close();
            return;
        };
        const theme = capi.theme_load(self.cursor_theme_ptr(), @intCast(self.cursor_size), shm) orelse {
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
        var best: ?i64 = null;
        if (self.repeat.active and self.repeat_rate != 0) best = @max(0, self.repeat.next_ms - now);
        if (self.drag.read_fd >= 0) {
            const due = @max(0, self.drag.read_deadline_ms - now);
            best = if (best) |b| @min(b, due) else due;
        }
        return if (best) |b| @intCast(b) else null;
    }

    /// Emits synthetic repeats for a held key and requests frames for windows
    /// that asked for one (their callback is not in flight).
    pub fn pump(self: *WaylandConnection) void {
        self.tick_repeat();
        self.check_drag_timeout(input.now_ms());
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

    /// Reads the layout now in effect and tells the app if it changed (GPUI `handle_keyboard_layout_change`).
    fn refresh_keyboard_layout(self: *WaylandConnection) void {
        const name: []const u8 = if (self.xkb) |*x| x.layout_name() orelse "unknown" else "unknown";
        if (!self.layout.set(name)) return;
        if (self.platform_) |p| p.emit_keyboard_layout_changed();
    }

    /// The layout in effect, as of the last keymap or modifiers event.
    pub fn keyboard_layout(self: *const WaylandConnection) platform.KeyboardLayout {
        return self.layout.get();
    }

    /// Outputs as displays. Falls back to one 1920x1080 display before any
    /// wl_output mode has arrived.
    pub fn displays(self: *WaylandConnection) []const Display {
        self.display_count = 0;
        for (self.outputs) |out| {
            if (out.proxy == null) continue;
            const scale: f32 = @floatFromInt(out.scale);
            const w: f32 = if (out.width > 0) @as(f32, @floatFromInt(out.width)) / scale else 1920;
            const h: f32 = if (out.height > 0) @as(f32, @floatFromInt(out.height)) / scale else 1080;
            // wl_output reports millihertz; the platform wants nanoseconds between refreshes.
            const refresh_interval: ?u64 = if (out.refresh_mhz > 0) @intCast(@divTrunc(@as(i64, 1_000_000_000_000), out.refresh_mhz)) else null;
            self.displays_[self.display_count] = .{ .id = out.name, .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } }, .scale_factor = scale, .refresh_interval = refresh_interval, .uuid_bytes = out.uuid };
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
        self.text_input_state.deinit();
        if (self.text_input) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.text_input_manager) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.system_bell) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        self.reset_drag();
        self.drag.data.deinit(self.allocator);
        if (self.pinch_gesture) |o| self.api.wl_proxy_destroy(@ptrCast(o));
        if (self.pointer_gestures) |o| self.api.wl_proxy_destroy(@ptrCast(o));
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
        if (self.background_effects) |m| self.api.wl_proxy_destroy(m);
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
        return window_renderer.GpuWindow.create(ctx, .{ .wayland = .{ .display = @ptrCast(self.display), .surface = @ptrCast(w.surface.?) } }, w.phys_w(), w.phys_h(), .{ .externally_paced = true, .transparent = w.background_appearance != .@"opaque" });
    }

    pub fn open_window(self: *WaylandConnection, options: window_mod.WindowOptions, parent: ?*platform.PlatformWindow) !*WaylandWindow {
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
            // Server decorations unless the app asks for client ones; without a request,
            // a window with a titlebar gets the compositor's frame and one without gets none.
            .decorated = if (options.window_decorations) |d| d == .server else options.titlebar != null,
            .background_appearance = options.window_background,
        };
        w.create_surface(options, if (parent) |p| WaylandWindow.from(p) else null) catch |err| {
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
        for (self.outputs) |out| {
            if (out.proxy != null) best = @max(best, out.scale);
        }
        return @floatFromInt(best);
    }

    fn find_window(self: *WaylandConnection, surface: *proto.Surface) ?*WaylandWindow {
        for (self.windows.items) |w| {
            if (!w.closed and w.surface == surface) return w;
        }
        return null;
    }

    // -- text input --------------------------------------------------------

    fn text_input_request(self: *WaylandConnection, opcode: u32) void {
        const ti = self.text_input orelse return;
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(ti), opcode, null, 1, 0);
    }

    fn text_input_commit(self: *WaylandConnection) void {
        self.text_input_request(7);
        self.text_input_state.commits +%= 1;
    }

    /// Makes the protocol's enabled state match what the focused window wants.
    fn sync_text_input(self: *WaylandConnection) void {
        const ti = self.text_input orelse return;
        const want = if (self.text_input_window) |w| w.wants_ime else false;
        if (want == self.text_input_enabled) return;
        self.text_input_enabled = want;
        self.last_ime_rect = null;
        self.text_input_state.reset();
        if (want) {
            self.text_input_request(1); // enable
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(ti), 5, null, 1, 0, @as(u32, 0), @as(u32, 0)); // normal content
            if (self.text_input_window.?.base.ime_area()) |area| self.set_ime_rect(area);
        } else {
            self.text_input_request(2); // disable
        }
        self.text_input_commit();
        self.flush();
    }

    /// Queues the rectangle unless unchanged. Returns true when a commit is needed.
    fn set_ime_rect(self: *WaylandConnection, area: PxBounds) void {
        const ti = self.text_input orelse return;
        const rect = ime_rect(area);
        if (self.last_ime_rect) |last| {
            if (std.mem.eql(i32, &last, &rect)) return;
        }
        self.last_ime_rect = rect;
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(ti), 6, null, 1, 0, rect[0], rect[1], rect[2], rect[3]);
    }

    /// Moves candidate windows to `area`, unless a composition is on screen: moving
    /// them then is left to `done`, or they jump while the user is choosing.
    fn update_ime_position(self: *WaylandConnection, window: *WaylandWindow, area: PxBounds) void {
        if (!self.text_input_enabled or self.text_input_window != window) return;
        if (self.text_input_state.composing) return;
        const before = self.last_ime_rect;
        self.set_ime_rect(area);
        if (before == null or !std.mem.eql(i32, &before.?, &self.last_ime_rect.?)) {
            self.text_input_commit();
            self.flush();
        }
    }

    /// A click ends any composition and keeps its text; the input method must also forget
    /// it, and text-input-v3 has no reset request, so it gets disabled and enabled again.
    fn commit_composition(self: *WaylandConnection) void {
        const w = self.keyboard_focus orelse return;
        if (self.text_input_state.composing and self.text_input_enabled) {
            self.text_input_enabled = false;
            self.sync_text_input_after_reset();
            w.base.emit_ime(.unmark_text);
        } else if (self.compose) |*c| {
            c.commit_preedit(&w.base);
        }
    }

    fn sync_text_input_after_reset(self: *WaylandConnection) void {
        self.text_input_request(2);
        self.text_input_commit();
        self.sync_text_input();
    }

    fn release_focus(self: *WaylandConnection, w: *WaylandWindow) void {
        if (self.drag.window == w) {
            self.drag.window = null;
            self.reset_drag();
        }
        if (self.text_input_window == w) {
            self.text_input_window = null;
            self.sync_text_input();
        }
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
                if (self.pointer_gestures) |g| {
                    const raw = self.api.wl_proxy_marshal_flags(@ptrCast(g), 1, &proto.pointer_gesture_pinch_interface, 1, 0, @as(?*anyopaque, null), p);
                    if (raw) |pinch| {
                        self.pinch_gesture = @ptrCast(pinch);
                        _ = self.api.wl_proxy_add_listener(pinch, @ptrCast(&pinch_listener), self);
                    }
                }
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
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.ddm.?), 1, &proto.data_device_interface, self.ddm_version, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(seat)));
            if (raw) |dd| {
                self.data_device = @ptrCast(dd);
                _ = self.api.wl_proxy_add_listener(dd, &data_device_listener, self);
            }
        }
        if (self.text_input == null and self.text_input_manager != null and (self.seat_caps & proto.WL_SEAT_CAP_KEYBOARD) != 0) {
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.text_input_manager.?), 1, &proto.text_input_interface, 1, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(seat)));
            if (raw) |ti| {
                self.text_input = @ptrCast(ti);
                self.text_input_state.commits = 0;
                _ = self.api.wl_proxy_add_listener(ti, &text_input_listener, self);
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
        var replaces_preedit = false;
        if (pressed and keysym != 0 and !input.is_modifier_keysym(keysym)) {
            if (self.compose) |*c| replaces_preedit = c.process_key(&w.base, keysym, &composed_buf, &text, &name);
        }
        const key_name = name orelse return;
        w.emit_key(key_name, text, pressed, false);
        if (replaces_preedit) self.compose.?.finish_composed(&w.base);
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

    /// Hides the cursor until the pointer moves (GPUI `hide_cursor_until_mouse_moves`).
    pub fn hide_cursor_until_mouse_moves(self: *WaylandConnection) void {
        if (self.cursor_hidden or self.pointer_focus == null) return;
        self.cursor_hidden = true;
        self.apply_cursor();
    }

    pub fn is_cursor_visible(self: *const WaylandConnection) bool {
        return !self.cursor_hidden;
    }

    fn apply_cursor(self: *WaylandConnection) void {
        const pointer = self.pointer orelse return;
        if (self.pointer_enter_serial == 0 or self.pointer_focus == null) return;
        if (self.cursor_style == .none or self.cursor_hidden) {
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
        const mods = input.modifiers(self.mods);
        const scroll = self.axis_frame.take(mods.shift) orelse return;
        const w = self.pointer_focus orelse return;
        _ = w.base.emit_input(.{ .scroll_wheel = .{
            .position = self.pointer_pos,
            .delta = switch (scroll) {
                .pixels => |d| .{ .pixels = .{ .x = d.x, .y = d.y } },
                .lines => |d| .{ .lines = .{ .x = d.x, .y = d.y } },
            },
            .modifiers = mods,
            .source = .pointer,
        } });
    }

    // -- file drags ---------------------------------------------------------

    pub fn extra_fd(self: *const WaylandConnection) c_int {
        return self.drag.read_fd;
    }

    /// Reads what is available of the file list. The source runs at its own pace, and
    /// waiting for it here would freeze the window, so this never blocks.
    pub fn on_extra_fd(self: *WaylandConnection) void {
        var chunk: [8192]u8 = undefined;
        while (self.drag.read_fd >= 0) {
            const n: isize = @bitCast(std.os.linux.read(self.drag.read_fd, &chunk, chunk.len));
            if (n == -@as(isize, @intFromEnum(std.os.linux.E.AGAIN))) return;
            if (n == -@as(isize, @intFromEnum(std.os.linux.E.INTR))) continue;
            if (n <= 0) return self.finish_drag_read(n == 0);
            self.drag.data.appendSlice(self.allocator, chunk[0..@intCast(n)]) catch return self.finish_drag_read(false);
            if (self.drag.data.items.len > drag_read_limit) return self.finish_drag_read(false);
        }
    }

    fn close_drag_pipe(self: *WaylandConnection) void {
        if (self.drag.read_fd >= 0) _ = std.os.linux.close(self.drag.read_fd);
        self.drag.read_fd = -1;
        self.drag.data.clearRetainingCapacity();
    }

    fn finish_drag_read(self: *WaylandConnection, ok: bool) void {
        const w = self.drag.window;
        if (ok) self.drag.paths = xdnd.parse_uri_list(self.allocator, self.drag.data.items) catch &.{};
        self.close_drag_pipe();
        if (w) |window| {
            if (self.drag.paths.len > 0) {
                self.drag.entered = true;
                _ = window.base.emit_input(.{ .file_drop = .{ .entered = .{ .position = self.drag.position, .paths = .{ .items = self.drag.paths } } } });
            } else if (self.drag.offer) |offer| {
                // Text, not files: refuse it, so the source shows a refused drop.
                self.accept_drag_mime(offer, null);
                self.drag.accepted = false;
            }
        }
        if (self.drag.drop_pending) self.complete_drop();
        self.flush();
    }

    fn accept_drag_mime(self: *WaylandConnection, offer: *proto.DataOffer, mime: ?[*:0]const u8) void {
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), 0, null, 1, 0, self.drag_serial, mime);
    }

    fn start_drag(self: *WaylandConnection, w: *WaylandWindow, offer: *proto.DataOffer, mimes: u8) void {
        self.drag.offer = offer;
        self.drag.window = w;
        if (mimes & mime_bit_uri_list == 0) {
            self.accept_drag_mime(offer, null);
            return;
        }
        self.accept_drag_mime(offer, MIME_URI_LIST);
        self.drag.accepted = true;
        // Copy only. A move would have the source delete the user's files once dropped,
        // and elements receiving paths do not promise to have taken them.
        if (self.ddm_version >= 3) {
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), 4, null, self.ddm_version, 0, dnd_action_copy, dnd_action_copy);
        } else {
            self.drag.action = dnd_action_copy;
        }
        var fds: [2]i32 = .{ -1, -1 };
        if (@as(isize, @bitCast(std.os.linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }))) != 0) return;
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), 1, null, 1, 0, MIME_URI_LIST, fds[1]);
        _ = std.os.linux.close(fds[1]);
        self.drag.read_fd = fds[0];
        self.drag.read_deadline_ms = input.now_ms() + drag_read_timeout_ms;
    }

    /// Ends the session and releases everything. An offer still held is simply destroyed.
    fn reset_drag(self: *WaylandConnection) void {
        self.close_drag_pipe();
        if (self.drag.offer) |offer| _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), 2, null, 1, 1);
        if (self.drag.paths.len > 0) xdnd.free_paths(self.allocator, self.drag.paths);
        var data = self.drag.data;
        data.clearRetainingCapacity();
        self.drag = .{ .data = data };
    }

    fn complete_drop(self: *WaylandConnection) void {
        const w = self.drag.window orelse return self.reset_drag();
        if (self.drag.entered) {
            _ = w.base.emit_input(.{ .file_drop = .{ .submit = .{ .position = self.drag.position } } });
        }
        // Finishing without an accepted type and a chosen action is a protocol error.
        if (self.drag.offer) |offer| {
            if (self.ddm_version >= 3 and self.drag.entered and self.drag.accepted and self.drag.action != dnd_action_none) {
                _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), 3, null, self.ddm_version, 0);
            }
        }
        self.reset_drag();
    }

    fn check_drag_timeout(self: *WaylandConnection, now: i64) void {
        if (self.drag.read_fd >= 0 and now >= self.drag.read_deadline_ms) self.finish_drag_read(false);
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
        if (std.mem.eql(u8, mime, "text/uri-list")) return mime_bit_uri_list;
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
        const raw = self.api.wl_proxy_marshal_flags(@ptrCast(ddm), 0, &proto.data_source_interface, self.ddm_version, 0, @as(?*anyopaque, null));
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

/// Surface-local integer rectangle for an IME area. Zero sizes are bumped to 1, since
/// a caret range has no width and some input methods ignore empty rectangles.
fn ime_rect(area: PxBounds) [4]i32 {
    return .{
        @intFromFloat(@round(area.origin.x)),
        @intFromFloat(@round(area.origin.y)),
        @max(1, @as(i32, @intFromFloat(@round(area.size.width)))),
        @max(1, @as(i32, @intFromFloat(@round(area.size.height)))),
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
        // The highest xdg-shell this build knows (v7). wm_capabilities needs v5; older compositors
        // send none, and the window keeps GPUI's default of every control.
        const ver: u32 = @min(version, 7);
        self.wm_base = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.xdg_wm_base_interface, ver, 0, name, proto.xdg_wm_base_interface.name, ver, &proto.xdg_wm_base_interface));
    } else if (std.mem.eql(u8, iface_name, "wl_seat")) {
        // Version 8 brings high resolution wheels. Newer keyboards can repeat keys on their
        // own, which the repeat timer here would then double, so this stops at 9.
        const ver: u32 = @min(version, 9);
        self.seat = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, api.wl_seat_interface, ver, 0, name, api.wl_seat_interface.name, ver, api.wl_seat_interface));
    } else if (std.mem.eql(u8, iface_name, "wl_data_device_manager")) {
        const ver: u32 = @min(version, 3);
        self.ddm_version = ver;
        self.ddm = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.data_device_manager_interface, ver, 0, name, proto.data_device_manager_interface.name, ver, @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "zwp_pointer_gestures_v1")) {
        self.pointer_gestures = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.pointer_gestures_interface, @as(u32, 1), 0, name, proto.pointer_gestures_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "zxdg_decoration_manager_v1")) {
        self.dec_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.decoration_manager_interface, @as(u32, 1), 0, name, proto.decoration_manager_interface.name, @as(u32, 1), &proto.decoration_manager_interface));
    } else if (std.mem.eql(u8, iface_name, "wp_viewporter")) {
        self.viewporter = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.viewporter_interface, @as(u32, 1), 0, name, proto.viewporter_interface.name, @as(u32, 1), &proto.viewporter_interface);
    } else if (std.mem.eql(u8, iface_name, "ext_background_effect_manager_v1")) {
        const manager = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.background_effect_manager_interface, @as(u32, 1), 0, name, proto.background_effect_manager_interface.name, @as(u32, 1), &proto.background_effect_manager_interface);
        if (manager) |m| {
            self.background_effects = m;
            _ = api.wl_proxy_add_listener(m, &background_effect_manager_listener, null);
        }
    } else if (std.mem.eql(u8, iface_name, "wp_fractional_scale_manager_v1")) {
        self.frac_manager = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.fractional_scale_manager_interface, @as(u32, 1), 0, name, proto.fractional_scale_manager_interface.name, @as(u32, 1), &proto.fractional_scale_manager_interface);
    } else if (std.mem.eql(u8, iface_name, "xdg_system_bell_v1")) {
        self.system_bell = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.system_bell_interface, @as(u32, 1), 0, name, proto.system_bell_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "zwp_text_input_manager_v3")) {
        self.text_input_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.text_input_manager_interface, @as(u32, 1), 0, name, proto.text_input_manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "wp_cursor_shape_manager_v1")) {
        self.cursor_shape_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.cursor_shape_manager_interface, @as(u32, 1), 0, name, proto.cursor_shape_manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "zwp_primary_selection_device_manager_v1")) {
        self.primary_manager = @ptrCast(api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &proto.primary_device_manager_interface, @as(u32, 1), 0, name, proto.primary_device_manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)));
    } else if (std.mem.eql(u8, iface_name, "wl_output")) {
        if (free_output_slot(self)) |slot| {
            const ver: u32 = @min(version, 4);
            const out_iface = self.lib.lookup(*const proto.Interface, "wl_output_interface") orelse return;
            const proxy = api.wl_proxy_marshal_flags(@ptrCast(reg), 0, out_iface, ver, 0, name, out_iface.name, ver, out_iface);
            if (proxy) |p| {
                self.outputs[slot] = .{ .proxy = p, .name = name, .conn = self };
                _ = api.wl_proxy_add_listener(p, &WaylandConnection.output_listener, &self.outputs[slot]);
            }
        }
    }
}

fn registryGlobalRemove(data: ?*anyopaque, _: *proto.Registry, name: u32) callconv(.c) void {
    const self: *WaylandConnection = @ptrCast(@alignCast(data.?));
    for (&self.outputs) |*out| {
        if (out.proxy == null or out.name != name) continue;
        // Compositors send `leave` for the windows on it first, so no window still names it.
        self.api.wl_proxy_destroy(out.proxy.?);
        out.* = .{};
        report_displays_changed(self);
        return;
    }
}

fn free_output_slot(self: *WaylandConnection) ?usize {
    for (self.outputs, 0..) |out, i| if (out.proxy == null) return i;
    return null;
}

/// Tells the platform the outputs changed, so the app can diff its displays.
fn report_displays_changed(self: *WaylandConnection) void {
    if (self.platform_) |p| p.emit_displays_changed();
}

fn seatCapabilities(data: ?*anyopaque, _: *proto.Seat, caps: u32) callconv(.c) void {
    const self: *WaylandConnection = @ptrCast(@alignCast(data.?));
    self.seat_caps = caps;
    self.ensure_seat_devices();
}

fn seatName(_: ?*anyopaque, _: *proto.Seat, _: [*:0]const u8) callconv(.c) void {}

fn outputGeometry(_: ?*anyopaque, _: *anyopaque, _: i32, _: i32, _: i32, _: i32, _: i32, _: ?[*:0]const u8, _: ?[*:0]const u8, _: i32) callconv(.c) void {}

/// wl_output.name: the output's name (for example "DP-1"), from which the display's uuid is made
/// the way GPUI's Wayland display does it: a version 5 UUID over the DNS namespace.
fn outputName(data: ?*anyopaque, _: *anyopaque, name: ?[*:0]const u8) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data.?));
    const n = name orelse return;
    out.uuid = platform.uuid_v5(platform.uuid_namespace_dns, std.mem.span(n));
}

fn outputMode(data: ?*anyopaque, _: *anyopaque, flags: u32, w: i32, h: i32, refresh: i32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data.?));
    if (flags & 1 != 0) { // current mode
        out.pending_w = w;
        out.pending_h = h;
        out.pending_refresh_mhz = refresh;
    }
}

fn outputDone(data: ?*anyopaque, _: *anyopaque) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data.?));
    const changed = out.width != out.pending_w or out.height != out.pending_h or out.refresh_mhz != out.pending_refresh_mhz;
    out.width = out.pending_w;
    out.height = out.pending_h;
    out.refresh_mhz = out.pending_refresh_mhz;
    if (changed) if (out.conn) |c| report_displays_changed(c);
}

/// The registry name of the output with this `wl_output` proxy, if it is one we know.
fn output_name(self: *WaylandConnection, proxy: *anyopaque) ?u32 {
    for (self.outputs) |out| if (out.proxy != null and out.proxy == proxy) return out.name;
    return null;
}

fn surfaceEnter(data: ?*anyopaque, _: *anyopaque, output: *anyopaque) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    const name = output_name(self.conn, output) orelse return;
    for (self.entered_outputs[0..self.entered_count]) |n| if (n == name) return;
    if (self.entered_count == self.entered_outputs.len) return;
    self.entered_outputs[self.entered_count] = name;
    self.entered_count += 1;
    self.update_display_id();
}

fn surfaceLeave(data: ?*anyopaque, _: *anyopaque, output: *anyopaque) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    const name = output_name(self.conn, output) orelse return;
    for (self.entered_outputs[0..self.entered_count], 0..) |n, i| {
        if (n != name) continue;
        var j = i;
        while (j + 1 < self.entered_count) : (j += 1) self.entered_outputs[j] = self.entered_outputs[j + 1];
        self.entered_count -= 1;
        self.update_display_id();
        return;
    }
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
    const source = self.axis_frame.source;
            self.axis_frame = .{ .source = source };
    w.base.emit_hover(false);
}

fn pointerMotion(data: ?*anyopaque, _: *proto.Pointer, _: u32, sx: i32, sy: i32) callconv(.c) void {
    const self = pointerConn(data);
    if (self.cursor_hidden) {
        self.cursor_hidden = false;
        self.apply_cursor();
    }
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
        self.last_press_serial = serial;
        self.commit_composition();
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
    pointerConn(data).axis_frame.on_axis(axis, proto.wlFixedToFloat(value));
}

fn pointerAxisDiscrete(data: ?*anyopaque, _: *proto.Pointer, axis: u32, discrete: i32) callconv(.c) void {
    pointerConn(data).axis_frame.on_discrete(axis, discrete);
}

fn pointerAxisValue120(data: ?*anyopaque, _: *proto.Pointer, axis: u32, v120: i32) callconv(.c) void {
    pointerConn(data).axis_frame.on_value120(axis, v120);
}

fn pointerAxisSource(data: ?*anyopaque, _: *proto.Pointer, source: u32) callconv(.c) void {
    pointerConn(data).axis_frame.on_source(source);
}

fn pointerFrame(data: ?*anyopaque, _: *proto.Pointer) callconv(.c) void {
    pointerConn(data).flush_axes();
}

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
    self.refresh_keyboard_layout();
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
    if (self.compose) |*c| c.cancel_preedit(&w.base);
    w.base.emit_active(false);
}

fn keyboardKey(data: ?*anyopaque, _: *proto.Keyboard, serial: u32, _: u32, code: u32, state: u32) callconv(.c) void {
    const self = pointerConn(data);
    self.last_serial = serial;
    const pressed = state == 1;
    if (pressed) self.last_press_serial = serial;
    if (self.xkb) |*x| {
        if (x.hasLiveState()) x.updateKey(code + 8, pressed);
    }
    self.handle_key(code, pressed);
}

fn keyboardModifiers(data: ?*anyopaque, _: *proto.Keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
    const self = pointerConn(data);
    self.mods = depressed | latched;
    if (self.xkb) |*x| x.syncModifiers(depressed, latched, locked, group);
    // The group is part of the modifiers, so a layout switch arrives here.
    self.refresh_keyboard_layout();
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

fn dataDeviceEnter(data: ?*anyopaque, _: *proto.DataDevice, serial: u32, surface: *proto.Surface, x: i32, y: i32, offer: ?*proto.DataOffer) callconv(.c) void {
    const self = pointerConn(data);
    self.drag_serial = serial;
    // This offer belongs to the drag, not the clipboard.
    var mimes: u8 = 0;
    if (offer != null and self.clipboard_slot.incoming == @as(?*anyopaque, @ptrCast(offer))) {
        mimes = self.clipboard_slot.incoming_mimes;
        self.clipboard_slot.incoming = null;
        self.clipboard_slot.incoming_mimes = 0;
    }
    // A compositor can move on to a new enter without a leave.
    if (self.drag.window) |old| {
        if (self.drag.entered) _ = old.base.emit_input(.{ .file_drop = .exited });
    }
    self.reset_drag();
    const o = offer orelse return;
    const w = self.find_window(surface) orelse {
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(o), 2, null, 1, 1);
        return;
    };
    self.drag.position = .{ .x = proto.wlFixedToFloat(x), .y = proto.wlFixedToFloat(y) };
    self.start_drag(w, o, mimes);
    self.flush();
}

fn dataDeviceLeave(data: ?*anyopaque, _: *proto.DataDevice) callconv(.c) void {
    const self = pointerConn(data);
    // Compositors also send leave after a drop, and the drop is still being completed.
    if (self.drag.drop_pending) return;
    if (self.drag.window) |w| {
        if (self.drag.entered) _ = w.base.emit_input(.{ .file_drop = .exited });
    }
    self.reset_drag();
}

fn dataDeviceMotion(data: ?*anyopaque, _: *proto.DataDevice, _: u32, x: i32, y: i32) callconv(.c) void {
    const self = pointerConn(data);
    const w = self.drag.window orelse return;
    self.drag.position = .{ .x = proto.wlFixedToFloat(x), .y = proto.wlFixedToFloat(y) };
    if (self.drag.entered) _ = w.base.emit_input(.{ .file_drop = .{ .pending = .{ .position = self.drag.position } } });
}

fn dataDeviceDrop(data: ?*anyopaque, _: *proto.DataDevice) callconv(.c) void {
    const self = pointerConn(data);
    if (self.drag.read_fd >= 0) {
        self.drag.drop_pending = true;
        return;
    }
    self.complete_drop();
    self.flush();
}

fn dataOfferSourceActions(_: ?*anyopaque, _: *proto.DataOffer, _: u32) callconv(.c) void {}

fn dataOfferAction(data: ?*anyopaque, offer: *proto.DataOffer, action: u32) callconv(.c) void {
    const self = pointerConn(data);
    if (self.drag.offer == offer) self.drag.action = action;
}

fn dataSourceDndNoop(_: ?*anyopaque, _: *proto.DataSource) callconv(.c) void {}
fn dataSourceActionNoop(_: ?*anyopaque, _: *proto.DataSource, _: u32) callconv(.c) void {}

// -- pinch gesture --------------------------------------------------------

fn emit_pinch(self: *WaylandConnection, delta: f32, phase: interactive.TouchPhase) void {
    const w = self.pointer_focus orelse return;
    _ = w.base.emit_input(.{ .pinch = .{ .position = self.pointer_pos, .delta = delta, .modifiers = input.modifiers(self.mods), .phase = phase } });
}

fn pinchBegin(data: ?*anyopaque, _: *proto.PointerGesturePinch, _: u32, _: u32, _: ?*proto.Surface, _: u32) callconv(.c) void {
    const self = pointerConn(data);
    self.pinch_scale = 1;
    emit_pinch(self, 0, .started);
}

fn pinchUpdate(data: ?*anyopaque, _: *proto.PointerGesturePinch, _: u32, _: i32, _: i32, scale: i32, _: i32) callconv(.c) void {
    const self = pointerConn(data);
    const next = proto.wlFixedToFloat(scale);
    const delta = next - self.pinch_scale;
    self.pinch_scale = next;
    emit_pinch(self, delta, .moved);
}

fn pinchEnd(data: ?*anyopaque, _: *proto.PointerGesturePinch, _: u32, _: u32, _: i32) callconv(.c) void {
    const self = pointerConn(data);
    self.pinch_scale = 1;
    emit_pinch(self, 0, .ended);
}

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

fn textInputEnter(data: ?*anyopaque, _: *proto.TextInput, surface: ?*proto.Surface) callconv(.c) void {
    const self = pointerConn(data);
    const s = surface orelse return;
    self.text_input_window = self.find_window(s);
    self.sync_text_input();
}

fn textInputLeave(data: ?*anyopaque, _: *proto.TextInput, _: ?*proto.Surface) callconv(.c) void {
    const self = pointerConn(data);
    const w = self.text_input_window;
    const composing = self.text_input_state.composing;
    self.text_input_window = null;
    self.sync_text_input();
    if (composing) if (w) |window| window.base.emit_ime(.delete_text);
}

fn textInputPreedit(data: ?*anyopaque, _: *proto.TextInput, text: ?[*:0]const u8, begin: i32, end: i32) callconv(.c) void {
    const self = pointerConn(data);
    self.text_input_state.on_preedit(if (text) |t| std.mem.span(t) else null, begin, end);
}

fn textInputCommit(data: ?*anyopaque, _: *proto.TextInput, text: ?[*:0]const u8) callconv(.c) void {
    const self = pointerConn(data);
    self.text_input_state.on_commit(if (text) |t| std.mem.span(t) else null);
}

/// We never send surrounding text, so input methods have no business asking for this.
fn textInputDeleteSurrounding(_: ?*anyopaque, _: *proto.TextInput, _: u32, _: u32) callconv(.c) void {}

fn textInputDone(data: ?*anyopaque, _: *proto.TextInput, serial: u32) callconv(.c) void {
    const self = pointerConn(data);
    const done = self.text_input_state.on_done(serial);
    defer self.text_input_state.free_done(done);
    const w = self.text_input_window orelse return;
    if (done.clear_preedit) w.base.emit_ime(.delete_text);
    if (done.commit) |text| {
        // IBus takes plain keys too. A one-byte commit goes through as a key press, so
        // bindings on letters keep working, as in GPUI.
        if (text.len == 1) {
            _ = w.base.emit_input(.{ .key_down = .{ .keystroke = .{ .key = text, .key_char = text } } });
        } else {
            w.base.emit_ime(.{ .insert_text = text });
        }
    }
    if (done.preedit) |text| w.base.emit_ime(.{ .set_marked_text = .{ .text = text, .selected = done.preedit_selected } });
    // State may only be sent once the compositor has caught up with our commits.
    if (done.serial_matches and self.text_input_enabled) {
        if (w.base.ime_area()) |area| {
            const before = self.last_ime_rect;
            self.set_ime_rect(area);
            if (before == null or !std.mem.eql(i32, &before.?, &self.last_ime_rect.?)) {
                self.text_input_commit();
                self.flush();
            }
        }
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
    suspended: bool = false,
    tiling: platform.Tiling = .{},
};

pub const WaylandWindow = struct {
    base: platform.PlatformWindow = .{ .vtable = &vtable },
    /// Which edges the compositor tiled the window against (xdg_toplevel states 5 to 8).
    tiling: platform.Tiling = .{},
    /// `hidden` while the compositor says the window is suspended (xdg_toplevel state 9).
    visibility_: platform.WindowVisibility = .visible,
    /// The outputs the surface is on, in the order it entered them. The first is its display.
    entered_outputs: [max_outputs]u32 = undefined,
    entered_count: usize = 0,
    /// The display id of `entered_outputs[0]`, as last reported to the platform window's callbacks.
    display_id_: ?u32 = null,
    /// Shadow area of a client-decorated window (set_client_inset); null when never set.
    client_inset: ?f32 = null,
    allocator: std.mem.Allocator,
    conn: *WaylandConnection,
    surface: ?*proto.Surface = null,
    xdg_surface: ?*proto.XdgSurface = null,
    xdg_toplevel: ?*proto.XdgToplevel = null,
    /// Set instead of `xdg_toplevel` for an `AnchoredPopup` window.
    xdg_popup: ?*proto.XdgPopup = null,
    /// What the window manager lets the window do, from xdg_toplevel.wm_capabilities (GPUI
    /// `window_controls`). It is staged in `in_progress_controls` and applied at the next
    /// xdg_surface.configure, as GPUI does.
    window_controls_: platform.WindowControls = .{},
    in_progress_controls: ?platform.WindowControls = null,
    decoration: ?*proto.Decoration = null,
    viewport: ?*anyopaque = null,
    frac_scale: ?*anyopaque = null,
    opaque_region: ?*proto.Region = null,
    /// The window's background (GPUI `window_background`, then `set_background_appearance`).
    background_appearance: window_mod.WindowBackgroundAppearance = .@"opaque",
    /// ext-background-effect's object for this surface, while the window is blurred.
    background_effect: ?*anyopaque = null,
    /// Corner radii of the client-drawn window, for the blur region (`set_client_corner_radii`).
    client_corner_radii: geometry.Corners(Pixels) = .{},
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
    /// A focused field in this window accepts text.
    wants_ime: bool = false,
    /// Interactive resizes apply at most once per frame, as in GPUI.
    resize_throttle: bool = false,

    fn updateImeEnabled(p: *platform.PlatformWindow, enabled: bool) void {
        const self = from(p);
        self.wants_ime = enabled;
        self.conn.sync_text_input();
    }

    fn updateImePosition(p: *platform.PlatformWindow, area: PxBounds) void {
        const self = from(p);
        self.conn.update_ime_position(self, area);
    }

    fn playSystemBell(p: *platform.PlatformWindow) void {
        const self = from(p);
        const bell = self.conn.system_bell orelse return;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(bell), 1, null, 1, 0, @as(?*anyopaque, @ptrCast(self.surface)));
        self.conn.flush();
    }

    fn windowAppearance(p: *platform.PlatformWindow) platform.WindowAppearance {
        return from_base(p).conn.appearance_;
    }

    const vtable: platform.PlatformWindow.VTable = .{
        .appearance = windowAppearance,
        .play_system_bell = playSystemBell,
        .update_ime_enabled = updateImeEnabled,
        .update_ime_position = updateImePosition,
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
        .is_maximized = isMaximized,
        .is_fullscreen = isFullscreen,
        .set_app_id = setAppId,
        .request_decorations = requestDecorations,
        .start_window_move = startWindowMove,
        .start_window_resize = startWindowResize,
        .show_window_menu = showWindowMenu,
        .window_decorations = windowDecorations,
        .set_client_inset = setClientInset,
        .set_background_appearance = setBackgroundAppearance,
        .background_appearance = backgroundAppearance,
        .set_client_corner_radii = setClientCornerRadii,
        .close = close,
        .visibility = windowVisibility,
        .display_id = windowDisplayId,
        .gpu_specs = windowGpuSpecs,
        .window_controls = windowControls,
    };

    const xs_listener: proto.XdgSurfaceListener = .{ .configure = xdgSurfaceConfigure };
    const top_listener: proto.XdgToplevelListener = .{ .configure = xdgToplevelConfigure, .close = xdgToplevelClose, .configure_bounds = xdgNoopBounds, .wm_capabilities = xdgWmCapabilities };
    const popup_listener: proto.XdgPopupListener = .{ .configure = xdgPopupConfigure, .popup_done = xdgPopupDone, .repositioned = xdgPopupRepositioned };
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

    fn create_surface(self: *WaylandWindow, options: window_mod.WindowOptions, parent: ?*WaylandWindow) !void {
        const c = self.conn;
        const a = &c.api;
        const compositor = c.compositor orelse return error.MissingWaylandGlobals;
        const wm_base = c.wm_base orelse return error.MissingWaylandGlobals;
        const surf_raw = a.wl_proxy_marshal_flags(@ptrCast(compositor), 0, a.wl_surface_interface, a.wl_proxy_get_version(@ptrCast(compositor)), 0, @as(?*anyopaque, null));
        self.surface = @ptrCast(surf_raw orelse return error.CannotCreateSurface);
        const surface = self.surface.?;
        _ = a.wl_proxy_add_listener(@ptrCast(surface), &surface_listener, self);

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

        self.update_regions();

        const xs_raw = a.wl_proxy_marshal_flags(@ptrCast(wm_base), 2, &proto.xdg_surface_interface, a.wl_proxy_get_version(@ptrCast(wm_base)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(surface)));
        self.xdg_surface = @ptrCast(xs_raw orelse return error.CannotCreateXdgSurface);
        const xs = self.xdg_surface.?;
        _ = a.wl_proxy_add_listener(@ptrCast(xs), &xs_listener, self);

        if (options.kind == .anchored_popup) {
            try self.create_popup_role(wm_base, xs, options, parent orelse return error.PopupParentNotFound);
        } else {
            try self.create_toplevel_role(c, xs, options);
        }
        // Empty commit asks the compositor for the first configure.
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 6, null, a.wl_proxy_get_version(@ptrCast(surface)), 0);
        self.apply_buffer_scale();
    }

    /// The xdg_toplevel role of an ordinary window: title, app id and the decoration request.
    fn create_toplevel_role(self: *WaylandWindow, c: *WaylandConnection, xs: *proto.XdgSurface, options: window_mod.WindowOptions) !void {
        const a = &c.api;
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
    }

    /// The xdg_popup role (GPUI `WindowKind::AnchoredPopup`): a positioner places the popup
    /// relative to the parent's xdg_surface, and a grab makes it a menu that the compositor
    /// dismisses on outside clicks.
    fn create_popup_role(self: *WaylandWindow, wm_base: *proto.XdgWmBase, xs: *proto.XdgSurface, options: window_mod.WindowOptions, parent: *WaylandWindow) !void {
        const c = self.conn;
        const a = &c.api;
        const parent_xs = parent.xdg_surface orelse return error.PopupParentNotFound;
        const popup_opts = options.kind.anchored_popup;
        const positioner_raw = a.wl_proxy_marshal_flags(@ptrCast(wm_base), 1, &proto.xdg_positioner_interface, a.wl_proxy_get_version(@ptrCast(wm_base)), 0, @as(?*anyopaque, null));
        const positioner: *proto.XdgPositioner = @ptrCast(positioner_raw orelse return error.CannotCreatePositioner);
        self.position_popup(positioner, popup_opts, parent);

        const popup_raw = a.wl_proxy_marshal_flags(@ptrCast(xs), 2, &proto.xdg_popup_interface, a.wl_proxy_get_version(@ptrCast(xs)), 0, @as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(parent_xs)), @as(*anyopaque, @ptrCast(positioner)));
        self.xdg_popup = @ptrCast(popup_raw orelse return error.CannotCreatePopup);
        const popup = self.xdg_popup.?;
        _ = a.wl_proxy_add_listener(@ptrCast(popup), &popup_listener, self);

        // A grab must name a press, or the compositor dismisses the popup at once (GPUI picks the
        // newest press serial, or no grab before any press).
        if (popup_opts.grab and c.last_press_serial != 0) {
            if (c.seat) |seat| {
                _ = a.wl_proxy_marshal_flags(@ptrCast(popup), 1, null, a.wl_proxy_get_version(@ptrCast(popup)), 0, @as(*anyopaque, @ptrCast(seat)), c.last_press_serial);
            }
        }
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 0, null, a.wl_proxy_get_version(@ptrCast(positioner)), 1);
    }

    /// The window geometry in surface coordinates: the surface without a client-drawn shadow
    /// (what `apply_window_geometry` sets). Popups are placed relative to it.
    fn window_geometry(self: *const WaylandWindow) PxBounds {
        const inset: f32 = self.client_inset orelse 0;
        const left: f32 = if (self.tiling.left) 0 else inset;
        const right: f32 = if (self.tiling.right) 0 else inset;
        const top: f32 = if (self.tiling.top) 0 else inset;
        const bottom: f32 = if (self.tiling.bottom) 0 else inset;
        return .{
            .origin = .{ .x = left, .y = top },
            .size = .{ .width = self.size.width - left - right, .height = self.size.height - top - bottom },
        };
    }

    /// Fills the positioner for `popup` (size, anchor rectangle, anchor, gravity, adjustment and
    /// offset), with the anchor rectangle clamped into the parent's geometry as gpui_linux does.
    fn position_popup(self: *WaylandWindow, positioner: *proto.XdgPositioner, popup: platform.PopupOptions, parent: *WaylandWindow) void {
        const a = self.api();
        const v = a.wl_proxy_get_version(@ptrCast(positioner));
        // A zero or negative size is a protocol error.
        const w: i32 = @intFromFloat(@max(1, self.size.width));
        const h: i32 = @intFromFloat(@max(1, self.size.height));
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 1, null, v, 0, w, h);
        const r = platform.popup.anchor_rect_in_geometry(popup.anchor_rect, parent.window_geometry());
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 2, null, v, 0, r[0], r[1], r[2], r[3]);
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 3, null, v, 0, platform.popup.xdg_anchor(popup.anchor));
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 4, null, v, 0, platform.popup.xdg_gravity(popup.gravity));
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 5, null, v, 0, popup.constraint_adjustment.bits());
        _ = a.wl_proxy_marshal_flags(@ptrCast(positioner), 6, null, v, 0, @as(i32, @intFromFloat(popup.offset.x)), @as(i32, @intFromFloat(popup.offset.y)));
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

    /// The surface's opaque and blur regions, as they must be for its background (GPUI `update_window`).
    fn update_regions(self: *WaylandWindow) void {
        self.update_opaque_region();
        self.update_blur_region();
    }

    /// Declares the whole surface opaque so compositors skip blending it. A transparent or blurred
    /// window has no such area: the region is cleared, so the compositor blends the whole surface.
    fn update_opaque_region(self: *WaylandWindow) void {
        const surface = self.surface orelse return;
        const c = self.conn;
        const a = &c.api;
        const compositor = c.compositor orelse return;
        if (self.opaque_region) |r| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(r), 0, null, a.wl_proxy_get_version(@ptrCast(r)), 1);
            self.opaque_region = null;
        }
        if (self.background_appearance != .@"opaque") {
            _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 4, null, a.wl_proxy_get_version(@ptrCast(surface)), 0, @as(?*anyopaque, null));
            return;
        }
        const reg_raw = a.wl_proxy_marshal_flags(@ptrCast(compositor), 1, a.wl_region_interface, a.wl_proxy_get_version(@ptrCast(compositor)), 0, @as(?*anyopaque, null));
        const region: *proto.Region = @ptrCast(reg_raw orelse return);
        self.opaque_region = region;
        const w: i32 = @intFromFloat(self.size.width);
        const h: i32 = @intFromFloat(self.size.height);
        _ = a.wl_proxy_marshal_flags(@ptrCast(region), 1, null, a.wl_proxy_get_version(@ptrCast(region)), 0, @as(i32, 0), @as(i32, 0), w, h);
        _ = a.wl_proxy_marshal_flags(@ptrCast(surface), 4, null, a.wl_proxy_get_version(@ptrCast(surface)), 0, @as(?*anyopaque, @ptrCast(region)));
    }

    /// The blur behind a blurred window: its visible area with the client's corner radii, through
    /// ext-background-effect (GPUI `update_window`). Without the protocol the window is only
    /// transparent, as in GPUI; the kde-blur fallback GPUI has is not ported.
    fn update_blur_region(self: *WaylandWindow) void {
        const surface = self.surface orelse return;
        const c = self.conn;
        const a = &c.api;
        const manager = c.background_effects orelse return;
        if (self.background_appearance != .blurred) {
            if (self.background_effect) |effect| {
                _ = a.wl_proxy_marshal_flags(effect, 0, null, a.wl_proxy_get_version(effect), 1);
                self.background_effect = null;
            }
            return;
        }
        if (self.background_effect == null) {
            self.background_effect = a.wl_proxy_marshal_flags(manager, 1, &proto.background_effect_surface_interface, a.wl_proxy_get_version(manager), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(surface)));
        }
        const effect = self.background_effect orelse return;
        const compositor = c.compositor orelse return;
        const region_raw = a.wl_proxy_marshal_flags(@ptrCast(compositor), 1, a.wl_region_interface, a.wl_proxy_get_version(@ptrCast(compositor)), 0, @as(?*anyopaque, null));
        const region: *proto.Region = @ptrCast(region_raw orelse return);
        const geo = self.window_geometry();
        const area: IRect = .{
            .x = @intFromFloat(geo.origin.x),
            .y = @intFromFloat(geo.origin.y),
            .width = @max(0, @as(i32, @intFromFloat(geo.size.width))),
            .height = @max(0, @as(i32, @intFromFloat(geo.size.height))),
        };
        const Adder = struct {
            a: *const proto.WaylandApi,
            region: *proto.Region,
            fn add(self_: @This(), r: IRect) void {
                _ = self_.a.wl_proxy_marshal_flags(@ptrCast(self_.region), 1, null, self_.a.wl_proxy_get_version(@ptrCast(self_.region)), 0, r.x, r.y, r.width, r.height);
            }
        };
        add_rounded_rect(area, self.client_corner_radii, Adder{ .a = a, .region = region }, Adder.add);
        // set_blur_region copies the region, so it can be destroyed at once.
        _ = a.wl_proxy_marshal_flags(effect, 1, null, a.wl_proxy_get_version(effect), 0, @as(*anyopaque, @ptrCast(region)));
        _ = a.wl_proxy_marshal_flags(@ptrCast(region), 0, null, a.wl_proxy_get_version(@ptrCast(region)), 1);
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
    /// The compositor's maximized state, from xdg_toplevel.configure (GPUI `is_maximized`).
    fn isMaximized(p: *platform.PlatformWindow) bool {
        return from(p).maximized;
    }
    /// The compositor's fullscreen state, from xdg_toplevel.configure (GPUI `is_fullscreen`).
    fn isFullscreen(p: *platform.PlatformWindow) bool {
        return from(p).fullscreen;
    }

    /// xdg_toplevel.set_app_id (GPUI `set_app_id`). The window is not told again when it is
    /// recreated, since ZUI never recreates a toplevel.
    fn setAppId(p: *platform.PlatformWindow, app_id: []const u8) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        const z = self.allocator.dupeSentinel(u8, app_id, 0) catch return;
        defer self.allocator.free(z);
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(top), 3, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as([*:0]const u8, z.ptr));
        self.conn.flush();
    }

    /// Server or client decorations through xdg-decoration (GPUI `request_decorations`). Without
    /// the decoration manager only client decorations exist, as in GPUI.
    fn requestDecorations(p: *platform.PlatformWindow, decorations: window_mod.WindowDecorations) void {
        const self = from(p);
        self.decorated = decorations == .server;
        if (self.decoration == null) return;
        self.apply_decoration_mode();
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

    /// xdg_toplevel.resize from the last press (GPUI `start_window_resize`).
    fn startWindowResize(p: *platform.PlatformWindow, edge: platform.ResizeEdge) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        const seat = self.conn.seat orelse return;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(top), 6, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as(*anyopaque, @ptrCast(seat)), self.conn.last_serial, resize_edge_code(edge));
        self.conn.flush();
    }

    /// xdg_toplevel.resize_edge values (GPUI `ResizeEdgeWaylandExt::to_xdg`).
    fn resize_edge_code(edge: platform.ResizeEdge) u32 {
        return switch (edge) {
            .top => 1,
            .bottom => 2,
            .left => 4,
            .top_left => 5,
            .bottom_left => 6,
            .right => 8,
            .top_right => 9,
            .bottom_right => 10,
        };
    }

    /// xdg_toplevel.show_window_menu at a position in the window (GPUI `show_window_menu`).
    fn showWindowMenu(p: *platform.PlatformWindow, position: PxPoint) void {
        const self = from(p);
        const top = self.xdg_toplevel orelse return;
        const seat = self.conn.seat orelse return;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(top), 4, null, a.wl_proxy_get_version(@ptrCast(top)), 0, @as(*anyopaque, @ptrCast(seat)), self.conn.last_serial, @as(i32, @intFromFloat(position.x)), @as(i32, @intFromFloat(position.y)));
        self.conn.flush();
    }

    fn windowDecorations(p: *platform.PlatformWindow) platform.Decorations {
        const self = from(p);
        // Without a decoration object the compositor draws nothing, so the app must.
        if (self.decorated and self.decoration != null) return .server;
        return .{ .client = .{ .tiling = self.tiling } };
    }

    fn setClientInset(p: *platform.PlatformWindow, inset: Pixels) void {
        const self = from(p);
        self.client_inset = inset;
        self.apply_window_geometry();
        self.conn.flush();
    }

    /// GPUI `set_background_appearance`. The renderer, the opaque region and the blur follow.
    fn setBackgroundAppearance(p: *platform.PlatformWindow, appearance: window_mod.WindowBackgroundAppearance) void {
        const self = from(p);
        if (self.background_appearance == appearance) return;
        self.background_appearance = appearance;
        if (self.gpu_window) |*g| g.set_transparent(appearance != .@"opaque");
        self.update_regions();
        self.conn.flush();
    }

    fn backgroundAppearance(p: *platform.PlatformWindow) window_mod.WindowBackgroundAppearance {
        return from(p).background_appearance;
    }

    /// GPUI `set_client_corner_radii`: only the blur region uses them.
    fn setClientCornerRadii(p: *platform.PlatformWindow, radii: geometry.Corners(Pixels)) void {
        const self = from(p);
        if (std.meta.eql(self.client_corner_radii, radii)) return;
        self.client_corner_radii = radii;
        self.update_blur_region();
        self.conn.flush();
    }

    /// xdg_surface.set_window_geometry: the window without the client-drawn shadow. Tiled edges
    /// have no shadow, so they keep their full extent.
    fn apply_window_geometry(self: *WaylandWindow) void {
        const inset = self.client_inset orelse return;
        const xs = self.xdg_surface orelse return;
        const left: f32 = if (self.tiling.left) 0 else inset;
        const right: f32 = if (self.tiling.right) 0 else inset;
        const top: f32 = if (self.tiling.top) 0 else inset;
        const bottom: f32 = if (self.tiling.bottom) 0 else inset;
        const w = self.size.width - left - right;
        const h = self.size.height - top - bottom;
        if (w <= 0 or h <= 0) return;
        const a = self.api();
        _ = a.wl_proxy_marshal_flags(@ptrCast(xs), 3, null, a.wl_proxy_get_version(@ptrCast(xs)), 0, @as(i32, @intFromFloat(left)), @as(i32, @intFromFloat(top)), @as(i32, @intFromFloat(w)), @as(i32, @intFromFloat(h)));
    }

    fn draw(p: *platform.PlatformWindow, scene: *const scene_mod.Scene) void {
        const self = from(p);
        if (self.closed or !self.configured) return;
        const pw = self.phys_w();
        const ph = self.phys_h();
        if (self.gpu_window) |*g| {
            // The present commits the surface, including the frame callback of emit_frame.
            if (g.draw(scene, frame_clear(self.background_appearance), pw, ph)) self.drew = true else self.frame_wanted = true;
            self.conn.flush();
            return;
        }
        const entry = self.acquire(pw, ph) orelse {
            self.frame_wanted = true;
            return;
        };
        const pixels = entry.pixels.?;
        const fb: cpu.Framebuffer = .{ .pixels = pixels, .width = pw, .height = ph, .stride = pw * 4, .format = .bgra8 };
        self.renderer.draw(scene, &self.atlas, fb, frame_clear(self.background_appearance));
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
        // A popup's role object must go before the xdg_surface it is built on.
        if (self.xdg_popup) |p| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(p), 0, null, a.wl_proxy_get_version(@ptrCast(p)), 1);
            self.xdg_popup = null;
        }
        if (self.xdg_toplevel) |t| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(t), 0, null, a.wl_proxy_get_version(@ptrCast(t)), 1);
            self.xdg_toplevel = null;
        }
        if (self.xdg_surface) |xs| {
            _ = a.wl_proxy_marshal_flags(@ptrCast(xs), 0, null, a.wl_proxy_get_version(@ptrCast(xs)), 1);
            self.xdg_surface = null;
        }
        // The effect object must go before the surface it belongs to.
        if (self.background_effect) |effect| {
            _ = a.wl_proxy_marshal_flags(effect, 0, null, a.wl_proxy_get_version(effect), 1);
            self.background_effect = null;
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
        if (self.in_progress_controls) |controls| {
            self.window_controls_ = controls;
            self.in_progress_controls = null;
        }
        const pending = self.pending_configure;
        self.maximized = pending.maximized;
        self.fullscreen = pending.fullscreen;
        self.tiling = pending.tiling;
        self.set_visibility(if (pending.suspended) .hidden else .visible);
        if (!(pending.resizing and self.resize_throttle)) {
            if (pending.resizing) self.resize_throttle = true;
            self.apply_configured_size(pending.width, pending.height);
        }
        self.apply_window_geometry();
        _ = a.wl_proxy_marshal_flags(@ptrCast(xs), 4, null, a.wl_proxy_get_version(@ptrCast(xs)), 0, serial);
        const first = !self.configured;
        self.configured = true;
        if (first) {
            self.update_regions();
            self.frame_wanted = true;
        }
    }

    fn set_visibility(self: *WaylandWindow, v: platform.WindowVisibility) void {
        if (self.visibility_ == v) return;
        self.visibility_ = v;
        self.base.emit_visibility_changed();
    }

    /// The display is the output the surface entered first. Reports a change.
    fn update_display_id(self: *WaylandWindow) void {
        const now: ?u32 = if (self.entered_count > 0) self.entered_outputs[0] else null;
        if (now == self.display_id_) return;
        self.display_id_ = now;
        self.base.emit_display_changed();
    }

    fn windowVisibility(p: *platform.PlatformWindow) platform.WindowVisibility {
        return from_base(p).visibility_;
    }

    fn windowDisplayId(p: *platform.PlatformWindow) ?platform.DisplayId {
        return from_base(p).display_id_;
    }

    fn windowGpuSpecs(p: *platform.PlatformWindow) ?platform.GpuSpecs {
        const self = from_base(p);
        if (self.gpu_window) |*g| return g.gpu_specs();
        return null;
    }

    fn from_base(p: *platform.PlatformWindow) *WaylandWindow {
        return @fieldParentPtr("base", p);
    }

    fn apply_configured_size(self: *WaylandWindow, width: i32, height: i32) void {
        if (self.closed or width <= 0 or height <= 0) return;
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        if (w == self.size.width and h == self.size.height) return;
        self.size = .{ .width = w, .height = h };
        self.apply_buffer_scale();
        self.update_regions();
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
                    5 => pending.tiling.left = true, // xdg_toplevel.state.tiled_left
                    6 => pending.tiling.right = true, // xdg_toplevel.state.tiled_right
                    7 => pending.tiling.top = true, // xdg_toplevel.state.tiled_top
                    8 => pending.tiling.bottom = true, // xdg_toplevel.state.tiled_bottom
                    9 => pending.suspended = true, // xdg_toplevel.state.suspended (xdg-shell v6)
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

    /// xdg_toplevel.wm_capabilities (since v5): an array of u32 values, each naming a control the
    /// compositor offers (window_menu 1, maximize 2, fullscreen 3, minimize 4). Anything not named is
    /// not offered.
    fn xdgWmCapabilities(data: ?*anyopaque, _: *proto.XdgToplevel, raw: ?*anyopaque) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (raw) |p| {
            const arr: *const proto.WlArray = @ptrCast(@alignCast(p));
            if (arr.data) |items| {
                self.in_progress_controls = window_controls_from_capabilities(items[0 .. arr.size / 4]);
            }
        } else {
            self.in_progress_controls = window_controls_from_capabilities(&.{});
        }
    }

    /// The controls named by an xdg_toplevel.wm_capabilities array (window_menu 1, maximize 2,
    /// fullscreen 3, minimize 4). Anything not named is not offered, as gpui_linux reads it.
    pub fn window_controls_from_capabilities(values: []const u32) platform.WindowControls {
        var controls: platform.WindowControls = .{ .fullscreen = false, .maximize = false, .minimize = false, .window_menu = false };
        for (values) |v| switch (v) {
            1 => controls.window_menu = true,
            2 => controls.maximize = true,
            3 => controls.fullscreen = true,
            4 => controls.minimize = true,
            else => {},
        };
        return controls;
    }

    fn windowControls(p: *platform.PlatformWindow) platform.WindowControls {
        return from(p).window_controls_;
    }

    /// xdg_popup.configure: the popup's size. The position is the compositor's to choose.
    fn xdgPopupConfigure(data: ?*anyopaque, _: *proto.XdgPopup, _: i32, _: i32, width: i32, height: i32) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (self.closed) return;
        self.pending_configure = .{ .width = width, .height = height };
    }

    /// xdg_popup.popup_done: the compositor dismissed the popup (a grab was clicked outside, or
    /// its parent went away). Closes it like a toplevel's close request.
    fn xdgPopupDone(data: ?*anyopaque, _: *proto.XdgPopup) callconv(.c) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (self.closed) return;
        if (self.base.emit_should_close()) self.base.emit_close();
    }

    fn xdgPopupRepositioned(_: ?*anyopaque, _: *proto.XdgPopup, _: u32) callconv(.c) void {}

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

test "wm_capabilities names the controls the compositor offers" {
    const all = WaylandWindow.window_controls_from_capabilities(&.{ 1, 2, 3, 4 });
    try std.testing.expect(all.window_menu and all.maximize and all.fullscreen and all.minimize);

    // Only what is named is offered: a compositor without maximize lacks it.
    const some = WaylandWindow.window_controls_from_capabilities(&.{ 4, 1 });
    try std.testing.expect(some.minimize and some.window_menu);
    try std.testing.expect(!some.maximize and !some.fullscreen);

    // An empty array (a compositor that offers nothing) offers no control.
    const none = WaylandWindow.window_controls_from_capabilities(&.{});
    try std.testing.expect(!none.minimize and !none.maximize and !none.fullscreen and !none.window_menu);

    // Unknown values are ignored.
    const unknown = WaylandWindow.window_controls_from_capabilities(&.{ 99, 2 });
    try std.testing.expect(unknown.maximize and !unknown.minimize);
}

test "popup anchor rectangle is taken in the parent's window geometry" {
    // A geometry 10 px in from the surface origin: an anchor at the origin is clamped to the
    // geometry's first pixel, and its size is cut to fit inside it.
    const geo: PxBounds = .{ .origin = .{ .x = 10, .y = 10 }, .size = .{ .width = 300, .height = 200 } };
    const anchor: PxBounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 20, .height = 20 } };
    const r = platform.popup.anchor_rect_in_geometry(anchor, geo);
    try std.testing.expectEqual([4]i32{ 0, 0, 10, 10 }, r);
}

const RoundedCollector = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(IRect) = .empty,

    fn add(self: *RoundedCollector, r: IRect) void {
        self.list.append(self.gpa, r) catch unreachable;
    }

    fn deinit(self: *RoundedCollector) void {
        self.list.deinit(self.gpa);
    }
};

fn rounded_rects(area: IRect, radii: geometry.Corners(f32)) ![]IRect {
    var c: RoundedCollector = .{ .gpa = std.testing.allocator };
    defer c.deinit();
    add_rounded_rect(area, radii, &c, RoundedCollector.add);
    return std.testing.allocator.dupe(IRect, c.list.items);
}

test "rounded blur rects: square corners give one rectangle" {
    const rects = try rounded_rects(.{ .x = 10, .y = 20, .width = 8, .height = 8 }, .{});
    defer std.testing.allocator.free(rects);
    try std.testing.expectEqualSlices(IRect, &.{.{ .x = 10, .y = 20, .width = 8, .height = 8 }}, rects);
}

test "rounded blur rects: independent corners, as gpui_linux" {
    const rects = try rounded_rects(.{ .x = 10, .y = 20, .width = 8, .height = 8 }, .{ .top_left = 4, .top_right = 0, .bottom_left = 0, .bottom_right = 4 });
    defer std.testing.allocator.free(rects);
    const want = [_]IRect{
        .{ .x = 12, .y = 20, .width = 6, .height = 1 },
        .{ .x = 11, .y = 21, .width = 7, .height = 1 },
        .{ .x = 10, .y = 22, .width = 8, .height = 1 },
        .{ .x = 10, .y = 23, .width = 8, .height = 1 },
        .{ .x = 10, .y = 27, .width = 6, .height = 1 },
        .{ .x = 10, .y = 26, .width = 7, .height = 1 },
        .{ .x = 10, .y = 25, .width = 8, .height = 1 },
        .{ .x = 10, .y = 24, .width = 8, .height = 1 },
    };
    try std.testing.expectEqualSlices(IRect, &want, rects);
}

test "rounded blur rects: radii are clamped to the area and negative radii mean none" {
    const area: IRect = .{ .x = 10, .y = 20, .width = 10, .height = 6 };
    const huge = try rounded_rects(area, .{ .top_left = 100, .top_right = 100, .bottom_left = 100, .bottom_right = 100 });
    defer std.testing.allocator.free(huge);
    const three = try rounded_rects(area, .{ .top_left = 3, .top_right = 3, .bottom_left = 3, .bottom_right = 3 });
    defer std.testing.allocator.free(three);
    try std.testing.expectEqualSlices(IRect, three, huge);
    const negative = try rounded_rects(area, .{ .top_left = -1, .top_right = -1, .bottom_left = -1, .bottom_right = -1 });
    defer std.testing.allocator.free(negative);
    const none = try rounded_rects(area, .{});
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualSlices(IRect, none, negative);
}

test "rounded blur rects: an empty area has no rectangles" {
    for ([_][2]i32{ .{ 0, 10 }, .{ 10, 0 }, .{ -1, 10 }, .{ 10, -1 } }) |d| {
        const rects = try rounded_rects(.{ .x = 10, .y = 20, .width = d[0], .height = d[1] }, .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 });
        defer std.testing.allocator.free(rects);
        try std.testing.expectEqual(@as(usize, 0), rects.len);
    }
}

