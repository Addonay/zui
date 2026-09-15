//! Wayland windowing and presentation backend.
//!
//! Connects to a Wayland compositor via dlopen'd libwayland-client without compile-time headers.
//! Manages native window creation via XDG shell, input dispatch via wl_seat, and frame
//! presentation via wl_shm shared memory buffers and the software rasterizer.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const event = @import("../event.zig");
const evdev = @import("evdev.zig");
const xkb = @import("xkb.zig");
const geometry = @import("../../core/geometry.zig");
const limits = @import("../../core/limits.zig");
const zlog = @import("../../core/log.zig");
const gpu = @import("../../gpu/root.zig");
const dl = @import("../dl.zig");

// Opaque Wayland protocol handles
const Display = opaque {};
const Registry = opaque {};
const Compositor = opaque {};
const Surface = opaque {};
const Region = opaque {};
const Shm = opaque {};
const ShmPool = opaque {};
const Buffer = opaque {};
const Seat = opaque {};
const Pointer = opaque {};
const Keyboard = opaque {};
const XdgWmBase = opaque {};
const XdgSurface = opaque {};
const XdgToplevel = opaque {};
const DataDeviceManager = opaque {};
const DataDevice = opaque {};
const DataOffer = opaque {};
const DataSource = opaque {};
const DecorationManager = opaque {};
const Decoration = opaque {};
const CursorTheme = opaque {};
/// Cursor entry: image array layout verified against wayland-cursor.h
/// (image_count, then images pointer; name follows and is unread).
const CursorHandle = extern struct {
    image_count: c_uint,
    images: [*]*CursorImage,
};
/// Opaque cursor frame; only hotspot/size are read (verified layout
/// against wayland-cursor.h), the buffer comes from `image_get_buffer`.
const CursorImage = extern struct {
    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    delay: u32,
};
const CursorEntry = extern struct {
    image_count: c_uint,
    images: [*]*CursorImage,
};

/// One wl_shm-backed frame buffer. `busy` is set on commit and cleared
/// by the compositor's `release` event; only idle entries may be
/// destroyed or reused.
const ShmBuffer = struct {
    buf: ?*Buffer = null,
    pixels: ?[]u8 = null,
    fd: c_int = -1,
    size: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    busy: bool = false,
};

/// wl_buffer listener: single `release` event (opcode 0).
const WlBufferListener = extern struct {
    release: ?*const fn (?*anyopaque, *Buffer) callconv(.c) void = null,
};

const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const anyopaque,
    event_count: c_int,
    events: ?*const anyopaque,
};

const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const anyopaque,
};

// Listeners
const RegistryListener = extern struct {
    global: ?*const fn (?*anyopaque, *Registry, u32, [*:0]const u8, u32) callconv(.c) void = null,
    global_remove: ?*const fn (?*anyopaque, *Registry, u32) callconv(.c) void = null,
};

const XdgWmBaseListener = extern struct {
    ping: ?*const fn (?*anyopaque, *XdgWmBase, u32) callconv(.c) void = null,
};

const XdgSurfaceListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgSurface, u32) callconv(.c) void = null,
};

const XdgToplevelListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgToplevel, i32, i32, ?*anyopaque) callconv(.c) void = null,
    close: ?*const fn (?*anyopaque, *XdgToplevel) callconv(.c) void = null,
    configure_bounds: ?*const fn (?*anyopaque, *XdgToplevel, i32, i32) callconv(.c) void = null,
    wm_capabilities: ?*const fn (?*anyopaque, *XdgToplevel, ?*anyopaque) callconv(.c) void = null,
};

/// Client/server decoration negotiation (xdg-decoration-unstable-v1).
/// Opcodes and mode values verified against the protocol XML in
/// wayland-protocols 0.32 (also vendored under ~/.cargo).
const DecorationListener = extern struct {
    configure: ?*const fn (?*anyopaque, *Decoration, u32) callconv(.c) void = null,
};

const DECOR_MODE_CLIENT_SIDE: u32 = 1;
const DECOR_MODE_SERVER_SIDE: u32 = 2;

/// xdg_toplevel.resize edge codes (protocol enum, NOT the _NET order —
/// see resizeEdgeCode for the mapping from ResizeEdge).
const XDG_RESIZE_NONE: u32 = 0;
const XDG_RESIZE_TOP: u32 = 1;
const XDG_RESIZE_BOTTOM: u32 = 2;
const XDG_RESIZE_LEFT: u32 = 4;
const XDG_RESIZE_TOP_LEFT: u32 = 5;
const XDG_RESIZE_BOTTOM_LEFT: u32 = 6;
const XDG_RESIZE_RIGHT: u32 = 8;
const XDG_RESIZE_TOP_RIGHT: u32 = 9;
const XDG_RESIZE_BOTTOM_RIGHT: u32 = 10;

/// xdg_toplevel.configure state 1 (verified against xdg-shell.xml).
const XDG_STATE_MAXIMIZED: u32 = 1;

/// wl_array header for the states array in configure events.
const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?[*]const u32,
};

const SeatListener = extern struct {
    capabilities: ?*const fn (?*anyopaque, *Seat, u32) callconv(.c) void = null,
    name: ?*const fn (?*anyopaque, *Seat, [*:0]const u8) callconv(.c) void = null,
};

/// Data-device (clipboard) protocol. Opcodes verified against
/// wayland-client-protocol.h; bound at version 1 so only v1 events exist.
const DataOfferListener = extern struct {
    offer: ?*const fn (?*anyopaque, *DataOffer, [*:0]const u8) callconv(.c) void = null,
};

const DataSourceListener = extern struct {
    target: ?*const fn (?*anyopaque, *DataSource, ?[*:0]const u8) callconv(.c) void = null,
    send: ?*const fn (?*anyopaque, *DataSource, [*:0]const u8, i32) callconv(.c) void = null,
    cancelled: ?*const fn (?*anyopaque, *DataSource) callconv(.c) void = null,
};

const DataDeviceListener = extern struct {
    data_offer: ?*const fn (?*anyopaque, *DataDevice, *DataOffer) callconv(.c) void = null,
    enter: ?*const fn (?*anyopaque, *DataDevice, u32, *Surface, i32, i32, ?*DataOffer) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *DataDevice) callconv(.c) void = null,
    motion: ?*const fn (?*anyopaque, *DataDevice, u32, i32, i32) callconv(.c) void = null,
    drop: ?*const fn (?*anyopaque, *DataDevice) callconv(.c) void = null,
    selection: ?*const fn (?*anyopaque, *DataDevice, ?*DataOffer) callconv(.c) void = null,
};

const data_offer_events = [_]Message{
    .{ .name = "offer", .signature = "s", .types = null },
};
const data_offer_methods = [_]Message{
    .{ .name = "accept", .signature = "u?s", .types = null },
    .{ .name = "receive", .signature = "sh", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
};
const data_offer_interface: Interface = .{
    .name = "wl_data_offer",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&data_offer_methods),
    .event_count = 1,
    .events = @ptrCast(&data_offer_events),
};

const data_source_events = [_]Message{
    .{ .name = "target", .signature = "?s", .types = null },
    .{ .name = "send", .signature = "sh", .types = null },
    .{ .name = "cancelled", .signature = "", .types = null },
};
const data_source_methods = [_]Message{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
};
const data_source_interface: Interface = .{
    .name = "wl_data_source",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&data_source_methods),
    .event_count = 3,
    .events = @ptrCast(&data_source_events),
};

const data_device_events = [_]Message{
    .{ .name = "data_offer", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&data_offer_interface)} },
    // NOTE: events carrying object args MUST have a non-null types array:
    // libwayland evaluates `message->types[i]` before null-checking the
    // entry, so a null array faults on any id present in the object map
    // (this crashed on the first data_offer/selection after focus).
    // Entries may be null individually to skip verification (used for the
    // lib-owned wl_surface, which has no static table here).
    .{ .name = "enter", .signature = "uoff?o", .types = &[_]?*const anyopaque{ null, null, null, null, @ptrCast(&data_offer_interface) } },
    .{ .name = "leave", .signature = "", .types = null },
    .{ .name = "motion", .signature = "uff", .types = null },
    .{ .name = "drop", .signature = "", .types = null },
    .{ .name = "selection", .signature = "?o", .types = &[_]?*const anyopaque{@ptrCast(&data_offer_interface)} },
};
const data_device_methods = [_]Message{
    .{ .name = "start_drag", .signature = "oo?ou", .types = null },
    .{ .name = "set_selection", .signature = "?ou", .types = null },
    .{ .name = "release", .signature = "", .types = null },
};
const data_device_interface: Interface = .{
    .name = "wl_data_device",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&data_device_methods),
    .event_count = 6,
    .events = @ptrCast(&data_device_events),
};

const data_device_manager_methods = [_]Message{
    .{ .name = "create_data_source", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&data_source_interface)} },
    .{ .name = "get_data_device", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&data_device_interface), null } },
};
const data_device_manager_interface: Interface = .{
    .name = "wl_data_device_manager",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&data_device_manager_methods),
    .event_count = 0,
    .events = null,
};

/// Seat capability bits (wl_seat.capabilities).
const WL_SEAT_CAP_POINTER: u32 = 1;
const WL_SEAT_CAP_KEYBOARD: u32 = 2;

/// Linux button codes (from linux/input-event-codes.h).
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
const BTN_FORWARD: u32 = 0x115;
const BTN_BACK: u32 = 0x116;

/// XKB modifier mask bits (also what wl_keyboard.modifiers reports).
const XKB_MOD_SHIFT: u32 = 1 << 0;

/// Keymap formats (wl_keyboard.keymap). We use evdev tables instead of
/// xkbcommon (same tradeoff as gooey's reference backend), so the fd is
/// closed immediately to avoid leaking one fd per keymap event.
const WL_KEYMAP_FORMAT_XKB_V1: u32 = 1;

fn wlFixedToFloat(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}

const KeyboardListener = extern struct {
    keymap: ?*const fn (?*anyopaque, *Keyboard, u32, i32, u32) callconv(.c) void = null,
    enter: ?*const fn (?*anyopaque, *Keyboard, u32, *Surface, ?*anyopaque) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *Keyboard, u32, *Surface) callconv(.c) void = null,
    key: ?*const fn (?*anyopaque, *Keyboard, u32, u32, u32, u32) callconv(.c) void = null,
    modifiers: ?*const fn (?*anyopaque, *Keyboard, u32, u32, u32, u32, u32) callconv(.c) void = null,
    repeat_info: ?*const fn (?*anyopaque, *Keyboard, i32, i32) callconv(.c) void = null,
};

const PointerListener = extern struct {
    enter: ?*const fn (?*anyopaque, *Pointer, u32, *Surface, i32, i32) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *Pointer, u32, *Surface) callconv(.c) void = null,
    motion: ?*const fn (?*anyopaque, *Pointer, u32, i32, i32) callconv(.c) void = null,
    button: ?*const fn (?*anyopaque, *Pointer, u32, u32, u32, u32) callconv(.c) void = null,
    axis: ?*const fn (?*anyopaque, *Pointer, u32, u32, i32) callconv(.c) void = null,
    frame: ?*const fn (?*anyopaque, *Pointer) callconv(.c) void = null,
    axis_source: ?*const fn (?*anyopaque, *Pointer, u32) callconv(.c) void = null,
    axis_stop: ?*const fn (?*anyopaque, *Pointer, u32, u32) callconv(.c) void = null,
    axis_discrete: ?*const fn (?*anyopaque, *Pointer, u32, i32) callconv(.c) void = null,
    axis_value120: ?*const fn (?*anyopaque, *Pointer, u32, i32) callconv(.c) void = null,
    axis_relative_direction: ?*const fn (?*anyopaque, *Pointer, u32, u32) callconv(.c) void = null,
};

// XDG Shell Protocol Interfaces (manual definitions since not in libwayland-client)
const xdg_surface_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};
const xdg_surface_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&xdg_toplevel_interface)} },
    .{ .name = "get_popup", .signature = "noo", .types = null },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};
const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 5,
    .method_count = 5,
    .methods = @ptrCast(&xdg_surface_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_surface_events),
};

const xdg_toplevel_events = [_]Message{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "a", .types = null },
};
const xdg_toplevel_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = null },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_app_id", .signature = "s", .types = null },
    .{ .name = "show_window_menu", .signature = "ouii", .types = null },
    .{ .name = "move", .signature = "ou", .types = null },
    .{ .name = "resize", .signature = "ouu", .types = null },
    .{ .name = "set_max_size", .signature = "ii", .types = null },
    .{ .name = "set_min_size", .signature = "ii", .types = null },
    .{ .name = "set_maximized", .signature = "", .types = null },
    .{ .name = "unset_maximized", .signature = "", .types = null },
    .{ .name = "set_fullscreen", .signature = "o", .types = null },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};
const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 5,
    .method_count = 14,
    .methods = @ptrCast(&xdg_toplevel_methods),
    .event_count = 4,
    .events = @ptrCast(&xdg_toplevel_events),
};

const decoration_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};
const decoration_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_mode", .signature = "u", .types = null },
    .{ .name = "unset_mode", .signature = "", .types = null },
};
const decoration_interface: Interface = .{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&decoration_methods),
    .event_count = 1,
    .events = @ptrCast(&decoration_events),
};

const decoration_manager_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel_decoration", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&decoration_interface), null } },
};
const decoration_manager_interface: Interface = .{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&decoration_manager_methods),
    .event_count = 0,
    .events = null,
};

const xdg_wm_base_events = [_]Message{
    .{ .name = "ping", .signature = "u", .types = null },
};
const xdg_wm_base_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = null },
    .{ .name = "get_xdg_surface", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&xdg_surface_interface), null } },
    .{ .name = "pong", .signature = "u", .types = null },
};
const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 5,
    .method_count = 4,
    .methods = @ptrCast(&xdg_wm_base_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_wm_base_events),
};

const WaylandApi = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    wl_display_disconnect: *const fn (*Display) callconv(.c) void,
    wl_display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    wl_display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    wl_display_flush: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_fd: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_error: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_protocol_error: *const fn (*Display, ?*?*const Interface, ?*u32) callconv(.c) u32,
    wl_proxy_get_interface: *const fn (*anyopaque) callconv(.c) ?*const Interface,
    /// Socket-drain trio for the non-blocking event loop. Long-stable
    /// libwayland API, but loaded optionally so ancient clients still
    /// start (without them pings starve — see drainEvents).
    wl_display_prepare_read: ?*const fn (*Display) callconv(.c) c_int = null,
    wl_display_read_events: ?*const fn (*Display) callconv(.c) c_int = null,
    wl_display_cancel_read: ?*const fn (*Display) callconv(.c) void = null,
    wl_proxy_marshal_flags: *const fn (*anyopaque, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*anyopaque,
    wl_proxy_add_listener: *const fn (*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (*anyopaque) callconv(.c) void,
    wl_proxy_get_version: *const fn (*anyopaque) callconv(.c) u32,

    // Core interfaces
    wl_registry_interface: *const Interface,
    wl_compositor_interface: *const Interface,
    wl_shm_interface: *const Interface,
    wl_shm_pool_interface: *const Interface,
    wl_buffer_interface: *const Interface,
    wl_surface_interface: *const Interface,
    wl_region_interface: *const Interface,
    wl_seat_interface: *const Interface,
    wl_pointer_interface: *const Interface,
    wl_keyboard_interface: *const Interface,

    fn load(lib: dl.Library) ?WaylandApi {
        return .{
            .wl_display_connect = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "wl_display_connect") orelse return null,
            .wl_display_disconnect = lib.lookup(*const fn (*Display) callconv(.c) void, "wl_display_disconnect") orelse return null,
            .wl_display_roundtrip = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_roundtrip") orelse return null,
            .wl_display_dispatch_pending = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_dispatch_pending") orelse return null,
            .wl_display_flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_flush") orelse return null,
            .wl_display_get_fd = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_get_fd") orelse return null,
            .wl_display_get_error = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_get_error") orelse return null,
            .wl_display_get_protocol_error = lib.lookup(*const fn (*Display, ?*?*const Interface, ?*u32) callconv(.c) u32, "wl_display_get_protocol_error") orelse return null,
            .wl_proxy_get_interface = lib.lookup(*const fn (*anyopaque) callconv(.c) ?*const Interface, "wl_proxy_get_interface") orelse return null,
            .wl_display_prepare_read = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_prepare_read"),
            .wl_display_read_events = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_read_events"),
            .wl_display_cancel_read = lib.lookup(*const fn (*Display) callconv(.c) void, "wl_display_cancel_read"),
            .wl_proxy_marshal_flags = lib.lookup(*const fn (*anyopaque, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*anyopaque, "wl_proxy_marshal_flags") orelse return null,
            .wl_proxy_add_listener = lib.lookup(*const fn (*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) c_int, "wl_proxy_add_listener") orelse return null,
            .wl_proxy_destroy = lib.lookup(*const fn (*anyopaque) callconv(.c) void, "wl_proxy_destroy") orelse return null,
            .wl_proxy_get_version = lib.lookup(*const fn (*anyopaque) callconv(.c) u32, "wl_proxy_get_version") orelse return null,

            .wl_registry_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_registry_interface")))) orelse return null,
            .wl_compositor_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_compositor_interface")))) orelse return null,
            .wl_shm_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_shm_interface")))) orelse return null,
            .wl_shm_pool_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_shm_pool_interface")))) orelse return null,
            .wl_buffer_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_buffer_interface")))) orelse return null,
            .wl_surface_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_surface_interface")))) orelse return null,
            .wl_region_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_region_interface")))) orelse return null,
            .wl_seat_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_seat_interface")))) orelse return null,
            .wl_pointer_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_pointer_interface")))) orelse return null,
            .wl_keyboard_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_keyboard_interface")))) orelse return null,
        };
    }
};

/// libwayland-cursor table: themed system cursors without parsing
/// Xcursor files ourselves. Optional — without it the compositor keeps
/// its default cursor, which is correct behavior, just not shaped.
const CursorApi = struct {
    theme_load: *const fn (?[*:0]const u8, c_int, *Shm) callconv(.c) ?*CursorTheme,
    theme_destroy: *const fn (*CursorTheme) callconv(.c) void,
    theme_get_cursor: *const fn (*CursorTheme, [*:0]const u8) callconv(.c) ?*CursorHandle,
    image_get_buffer: *const fn (*CursorImage) callconv(.c) ?*Buffer,
    cursor_frame: *const fn (*CursorHandle, u32) callconv(.c) c_int,

    fn load(lib: dl.Library) ?CursorApi {
        return .{
            .theme_load = lib.lookup(*const fn (?[*:0]const u8, c_int, *Shm) callconv(.c) ?*CursorTheme, "wl_cursor_theme_load") orelse return null,
            .theme_destroy = lib.lookup(*const fn (*CursorTheme) callconv(.c) void, "wl_cursor_theme_destroy") orelse return null,
            .theme_get_cursor = lib.lookup(*const fn (*CursorTheme, [*:0]const u8) callconv(.c) ?*CursorHandle, "wl_cursor_theme_get_cursor") orelse return null,
            .image_get_buffer = lib.lookup(*const fn (*CursorImage) callconv(.c) ?*Buffer, "wl_cursor_image_get_buffer") orelse return null,
            .cursor_frame = lib.lookup(*const fn (*CursorHandle, u32) callconv(.c) c_int, "wl_cursor_frame") orelse return null,
        };
    }
};

pub const cursor_lib_names: []const [*:0]const u8 = &.{ "libwayland-cursor.so.0", "libwayland-cursor.so" };

pub const WaylandBackend = struct {
    allocator: std.mem.Allocator,
    lib: dl.Library,
    api: WaylandApi,
    /// Vellz-backed frame renderer, persistent across presents.
    renderer: gpu.vellz.Renderer,

    display: *Display,
    registry: *Registry,
    compositor: ?*Compositor = null,
    shm: ?*Shm = null,
    wm_base: ?*XdgWmBase = null,
    seat: ?*Seat = null,
    pointer: ?*Pointer = null,
    keyboard: ?*Keyboard = null,
    seat_caps: u32 = 0,
    mods_mask: u32 = 0,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// Layout-correct keyboard translation. Null without libxkbcommon —
    /// the evdev US tables cover that case.
    xkb: ?xkb.Xkb = null,
    /// Client-side key repeat (compositors send one press; repeats are our
    /// job — GPUI does the same with timers). X11 needs none of this: the
    /// server repeats natively.
    repeat_evdev: ?u32 = null,
    repeat_next_ms: i64 = 0,
    repeat_interval_ms: i64 = 0,
    repeat_delay_ms: i64 = 0,
    repeat_rate: u32 = 0,

    surface: ?*Surface = null,
    xdg_surface: ?*XdgSurface = null,
    xdg_toplevel: ?*XdgToplevel = null,
    opaque_region: ?*Region = null,

    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1.0,
    focused: bool = true,
    configured: bool = false,
    presents: u32 = 0,
    wakeups: u32 = 0,

    // SHM pixel buffers. The compositor may hold a committed buffer
    // across frames, so entries are release-tracked: destroying a busy
    // buffer makes its late `release` event reference a dead id, which
    // faults connection handling. Two entries let us render the next
    // frame while the compositor still scans out the previous one.
    bufs: [2]ShmBuffer = .{ .{}, .{} },
    target_queue: ?*event.EventQueue = null,
    /// Gated `ZUI_DEBUG_EVENTS` input logging (read once at init).
    debug_events: bool = false,
    // Serial of the last pointer/keyboard enter; selection ownership
    // requires one (compositors reject serial-less set_selection).
    last_serial: u32 = 0,
    pointer_inside: bool = false,
    // Scroll accumulators, flushed as one ScrollEvent per pointer frame.
    // axis: 0 = vertical, 1 = horizontal (protocol order).
    axis_v: i32 = 0,
    axis_h: i32 = 0,
    disc_v: i32 = 0,
    disc_h: i32 = 0,
    // High-resolution steps (wl_pointer.axis_value120, v8+), in 1/120ths
    // of a wheel notch.
    v120_v: i32 = 0,
    v120_h: i32 = 0,
    // Clipboard (data-device) state.
    ddm: ?*DataDeviceManager = null,
    data_device: ?*DataDevice = null,
    data_source: ?*DataSource = null,
    offered: [limits.MAX_CLIPBOARD_BYTES]u8 = std.mem.zeroes([limits.MAX_CLIPBOARD_BYTES]u8),
    offered_len: usize = 0,
    owning_selection: bool = false,
    cur_offer: ?*DataOffer = null,
    /// Bitmask of text mimes on the current offer (see offerMimeBit).
    offer_mimes: u8 = 0,
    // Themed cursor state (all optional; absence keeps the default).
    cursor_lib: ?dl.Library = null,
    cursor_api: ?CursorApi = null,
    cursor_theme: ?*CursorTheme = null,
    cursor_surface: ?*Surface = null,
    cursor_shape: backend.CursorShape = .default,
    // Chrome state.
    dec_manager: ?*DecorationManager = null,
    decoration: ?*Decoration = null,
    decorated: bool = true,
    deco_mode: u32 = 0, // last configure mode; 0 = unknown yet
    maximized: bool = false,

    const vtable: backend.VTable = .{
        .kind = kindFn,
        .poll = pollFn,
        .waitTimeoutNs = waitFn,
        .wakeup = wakeupFn,
        .windowInfo = infoFn,
        .setTitle = titleFn,
        .setSize = sizeFn,
        .setDecorated = decoratedFn,
        .dragWindow = dragFn,
        .resizeWindow = resizeFn,
        .minimizeWindow = minimizeFn,
        .toggleMaximizeWindow = maximizeFn,
        .setCursor = cursorFn,
        .setClipboardText = setClipboardFn,
        .clipboardText = getClipboardFn,
        .present = presentFn,
    };

    fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
        if (!builtin.link_libc) return null;
        return std.c.getenv(name);
    }

    pub fn isAvailable() bool {
        if (!builtin.link_libc) return false;
        if (getenv("WAYLAND_DISPLAY") == null) return false;
        var lib = dl.Library.open(&.{ "libwayland-client.so.0", "libwayland-client.so" }) orelse return false;
        defer lib.close();
        return WaylandApi.load(lib) != null;
    }

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !*WaylandBackend {
        if (!builtin.link_libc) return error.LibcNotLinked;
        if (getenv("WAYLAND_DISPLAY") == null) return error.NoWaylandDisplay;

        const lib = dl.Library.open(&.{ "libwayland-client.so.0", "libwayland-client.so" }) orelse return error.LibraryNotFound;
        errdefer {
            var l = lib;
            l.close();
        }

        const api = WaylandApi.load(lib) orelse return error.MissingSymbols;

        const dpy = api.wl_display_connect(null) orelse return error.CannotConnectWayland;
        errdefer api.wl_display_disconnect(dpy);

        const reg_raw = api.wl_proxy_marshal_flags(@ptrCast(dpy), 1, api.wl_registry_interface, api.wl_proxy_get_version(@ptrCast(dpy)), 0);
        const reg: *Registry = @ptrCast(reg_raw orelse return error.CannotGetRegistry);

        const self = try allocator.create(WaylandBackend);
        self.* = .{
            .allocator = allocator,
            .lib = lib,
            .api = api,
            .display = dpy,
            .registry = reg,
            .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
            .debug_events = getenv("ZUI_DEBUG_EVENTS") != null,
            .renderer = gpu.vellz.Renderer.init(allocator),
        };

        // Attach registry listener
        _ = api.wl_proxy_add_listener(@ptrCast(reg), &default_reg_listener, self);
        _ = api.wl_display_roundtrip(dpy);

        if (self.compositor == null or self.shm == null) {
            self.deinit();
            return error.MissingWaylandGlobals;
        }

        // Listen for seat capabilities, then create input devices. The
        // second roundtrip delivers caps synchronously at startup; pollFn
        // re-runs ensureSeatDevices for hot-plugged seats.
        if (self.seat) |seat| {
            _ = api.wl_proxy_add_listener(@ptrCast(seat), &default_seat_listener, self);
        }
        _ = api.wl_display_roundtrip(dpy);
        self.ensureSeatDevices();

        // Layout-correct typing when libxkbcommon exists; evdev fallback
        // otherwise. Failure degrades, never aborts init.
        self.xkb = xkb.Xkb.init() catch null;

        // Themed cursors when libwayland-cursor exists; absence keeps the
        // compositor default (correct, just unshaped).
        if (self.shm) |shm| {
            if (dl.Library.open(cursor_lib_names)) |clib| {
                if (CursorApi.load(clib)) |capi| {
                    if (capi.theme_load(null, 24, shm)) |theme| {
                        self.cursor_lib = clib;
                        self.cursor_api = capi;
                        self.cursor_theme = theme;
                        const csurf_raw = api.wl_proxy_marshal_flags(@ptrCast(self.compositor.?), 0, api.wl_surface_interface, api.wl_proxy_get_version(@ptrCast(self.compositor.?)), 0, @as(?*anyopaque, null));
                        self.cursor_surface = @ptrCast(csurf_raw);
                    } else {
                        var c = clib;
                        c.close();
                    }
                } else {
                    var c = clib;
                    c.close();
                }
            }
        }

        // Create surface
        const surf_raw = api.wl_proxy_marshal_flags(@ptrCast(self.compositor.?), 0, api.wl_surface_interface, api.wl_proxy_get_version(@ptrCast(self.compositor.?)), 0, @as(?*anyopaque, null));
        self.surface = @ptrCast(surf_raw);

        // Tell the compositor every pixel is opaque. Without an opaque
        // region KWin treats the surface as translucent (translucency/blur/
        // contrast pipelines engage) — XWayland always sets one, which is
        // why the X11 backend never showed this class of issue.
        self.updateOpaqueRegion(width, height);

        // Create XDG surface if wm_base is available
        if (self.wm_base) |wm| {
            _ = api.wl_proxy_add_listener(@ptrCast(wm), &default_wm_listener, self);

            const xdg_surf_raw = api.wl_proxy_marshal_flags(@ptrCast(wm), 2, &xdg_surface_interface, api.wl_proxy_get_version(@ptrCast(wm)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(self.surface.?)));
            self.xdg_surface = @ptrCast(xdg_surf_raw);

            if (self.xdg_surface) |xs| {
                _ = api.wl_proxy_add_listener(@ptrCast(xs), &default_xs_listener, self);

                const top_raw = api.wl_proxy_marshal_flags(@ptrCast(xs), 1, &xdg_toplevel_interface, api.wl_proxy_get_version(@ptrCast(xs)), 0, @as(?*anyopaque, null));
                self.xdg_toplevel = @ptrCast(top_raw);

                if (self.xdg_toplevel) |top| {
                    _ = api.wl_proxy_add_listener(@ptrCast(top), &default_top_listener, self);

                    self.pushTitle(title);
                    // Decoration object for later setDecorated calls; the
                    // mode applies below once everything exists.
                    if (self.dec_manager) |dm| {
                        // get_toplevel_decoration is opcode 1.
                        const draw = api.wl_proxy_marshal_flags(@ptrCast(dm), 1, &decoration_interface, 1, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(top)));
                        if (draw) |d| {
                            self.decoration = @ptrCast(d);
                            _ = api.wl_proxy_add_listener(@ptrCast(d), &default_decoration_listener, self);
                            self.applyDecorations();
                        }
                    }
                    // Opcode 3 is set_app_id: reverse-DNS window identity for
                    // taskbar grouping and focus-stealing policy. Without it
                    // compositors classify the surface as anonymous.
                    const app_id: [*:0]const u8 = "dev.zui.todo";
                    _ = api.wl_proxy_marshal_flags(@ptrCast(top), 3, null, api.wl_proxy_get_version(@ptrCast(top)), 0, app_id);
                }
            }
        }

        // Allocate initial shm buffer
        try self.recreateBuffer(width, height);

        // Commit surface and roundtrip to initiate configure
        _ = api.wl_proxy_marshal_flags(@ptrCast(self.surface.?), 6, null, api.wl_proxy_get_version(@ptrCast(self.surface.?)), 0);
        _ = api.wl_display_roundtrip(dpy);

        return self;
    }

    pub fn deinit(self: *WaylandBackend) void {
        self.renderer.deinit();
        self.destroyBuffer();

        if (self.decoration) |d| {
            self.api.wl_proxy_destroy(@ptrCast(d));
            self.decoration = null;
        }
        if (self.dec_manager) |dm| {
            self.api.wl_proxy_destroy(@ptrCast(dm));
            self.dec_manager = null;
        }

        if (self.data_source) |ds| {
            self.api.wl_proxy_destroy(@ptrCast(ds));
            self.data_source = null;
        }
        if (self.data_device) |dd| {
            // wl_data_device.release is opcode 2.
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(dd), 2, null, 1, 0);
            self.api.wl_proxy_destroy(@ptrCast(dd));
            self.data_device = null;
        }
        if (self.ddm) |m| {
            self.api.wl_proxy_destroy(@ptrCast(m));
            self.ddm = null;
        }
        if (self.cursor_surface) |cs| {
            self.api.wl_proxy_destroy(@ptrCast(cs));
            self.cursor_surface = null;
        }
        if (self.cursor_theme) |theme| {
            if (self.cursor_api) |capi| capi.theme_destroy(theme);
            self.cursor_theme = null;
        }
        if (self.cursor_lib) |*clib| {
            clib.close();
            self.cursor_lib = null;
        }

        if (self.opaque_region) |r| {
            self.api.wl_proxy_destroy(@ptrCast(r));
            self.opaque_region = null;
        }
        if (self.pointer) |p| self.api.wl_proxy_destroy(@ptrCast(p));
        if (self.keyboard) |k| self.api.wl_proxy_destroy(@ptrCast(k));
        if (self.xkb) |*x| {
            x.deinit();
            self.xkb = null;
        }
        if (self.xdg_toplevel) |t| self.api.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |xs| self.api.wl_proxy_destroy(@ptrCast(xs));
        if (self.surface) |s| self.api.wl_proxy_destroy(@ptrCast(s));
        if (self.wm_base) |w| self.api.wl_proxy_destroy(@ptrCast(w));
        if (self.seat) |st| self.api.wl_proxy_destroy(@ptrCast(st));
        if (self.shm) |sh| self.api.wl_proxy_destroy(@ptrCast(sh));
        if (self.compositor) |c| self.api.wl_proxy_destroy(@ptrCast(c));

        self.api.wl_proxy_destroy(@ptrCast(self.registry));
        self.api.wl_display_disconnect(self.display);
        self.lib.close();
        self.allocator.destroy(self);
    }

    pub fn backendHandle(self: *WaylandBackend) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// (Re)declare the whole surface opaque. wl_compositor.create_region
    /// is opcode 1, wl_region.add is opcode 1, wl_surface.set_opaque_region
    /// is opcode 4. Takes effect on the next commit.
    fn updateOpaqueRegion(self: *WaylandBackend, width: u32, height: u32) void {
        const surface = self.surface orelse return;
        if (self.opaque_region) |r| {
            self.api.wl_proxy_destroy(@ptrCast(r));
            self.opaque_region = null;
        }
        // wl_compositor.create_region(new id region), opcode 1.
        const reg_raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.compositor.?), 1, self.api.wl_region_interface, self.api.wl_proxy_get_version(@ptrCast(self.compositor.?)), 0, @as(?*anyopaque, null));
        const region: *Region = @ptrCast(reg_raw orelse return);
        self.opaque_region = region;
        // wl_region.add(x, y, w, h), opcode 1.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(region), 1, null, self.api.wl_proxy_get_version(@ptrCast(region)), 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)));
        // wl_surface.set_opaque_region(region), opcode 4.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 4, null, self.api.wl_proxy_get_version(@ptrCast(surface)), 0, @as(?*anyopaque, @ptrCast(region)));
    }

    fn recreateBuffer(self: *WaylandBackend, width: u32, height: u32) !void {
        // Resize: drop idle entries of the old size (busy ones are
        // destroyed on release once stale), then top the pool back up.
        for (&self.bufs) |*e| {
            if (!e.busy and e.buf != null and (e.w != width or e.h != height)) self.destroyEntry(e);
        }
        var i: usize = 0;
        while (i < self.bufs.len) : (i += 1) {
            if (self.bufs[i].buf == null) try self.allocEntry(&self.bufs[i], width, height);
        }
    }

    fn allocEntry(self: *WaylandBackend, e: *ShmBuffer, width: u32, height: u32) !void {
        const stride = width * 4;
        const buf_size = @as(usize, stride) * height;

        const fd = std.os.linux.memfd_create("zui-wayland-shm", 0);
        if (fd < 0) return error.MemfdFailed;
        errdefer _ = std.os.linux.close(@intCast(fd));

        const trunc_res = std.os.linux.ftruncate(@intCast(fd), @intCast(buf_size));
        if (trunc_res != 0) return error.FtruncateFailed;

        const map_res = std.os.linux.mmap(null, buf_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, @intCast(fd), 0);
        const ptr: [*]u8 = @ptrFromInt(map_res);
        e.pixels = ptr[0..buf_size];
        e.fd = @intCast(fd);
        e.size = buf_size;
        e.w = width;
        e.h = height;
        e.busy = false;
        errdefer {
            _ = std.os.linux.munmap(ptr, buf_size);
            e.pixels = null;
        }

        // wl_shm::create_pool is opcode 0
        const pool_raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.shm.?), 0, self.api.wl_shm_pool_interface, self.api.wl_proxy_get_version(@ptrCast(self.shm.?)), 0, @as(?*anyopaque, null), @as(i32, @intCast(fd)), @as(i32, @intCast(buf_size)));
        const pool: *ShmPool = @ptrCast(pool_raw orelse return error.CannotCreateShmPool);
        defer self.api.wl_proxy_destroy(@ptrCast(pool));

        // wl_shm_pool::create_buffer is opcode 0. Format 0 is WL_SHM_FORMAT_ARGB8888
        const buf_raw = self.api.wl_proxy_marshal_flags(@ptrCast(pool), 0, self.api.wl_buffer_interface, self.api.wl_proxy_get_version(@ptrCast(pool)), 0, @as(?*anyopaque, null), @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)), @as(i32, @intCast(stride)), @as(u32, 0));
        const b: *Buffer = @ptrCast(buf_raw orelse return error.CannotCreateBuffer);
        e.buf = b;
        _ = self.api.wl_proxy_add_listener(@ptrCast(b), &default_buffer_listener, self);
    }

    fn destroyEntry(self: *WaylandBackend, e: *ShmBuffer) void {
        if (e.buf) |b| {
            self.api.wl_proxy_destroy(@ptrCast(b));
            e.buf = null;
        }
        if (e.pixels) |px| {
            _ = std.os.linux.munmap(px.ptr, e.size);
            e.pixels = null;
        }
        if (e.fd >= 0) {
            _ = std.os.linux.close(e.fd);
            e.fd = -1;
        }
        e.size = 0;
        e.busy = false;
    }

    /// compositor is done with the buffer: reusable, unless a resize
    /// made it stale — then destroy it now (it is idle by definition).
    fn bufferRelease(data: ?*anyopaque, buf: *Buffer) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        for (&self.bufs) |*e| {
            if (e.buf == buf) {
                e.busy = false;
                const cw: u32 = @intFromFloat(self.size.w);
                const ch: u32 = @intFromFloat(self.size.h);
                if (e.w != cw or e.h != ch) {
                    zlog.log("wayland", "release: dropping stale {d}x{d} buffer", .{ e.w, e.h });
                    self.destroyEntry(e);
                }
                return;
            }
        }
        zlog.log("wayland", "release for unknown buffer (already destroyed?)", .{});
    }

    fn destroyBuffer(self: *WaylandBackend) void {
        for (&self.bufs) |*e| self.destroyEntry(e);
    }

    // Callbacks
    fn registryGlobal(data: ?*anyopaque, reg: *Registry, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const iface_name = std.mem.span(iface);

        if (std.mem.eql(u8, iface_name, "wl_compositor")) {
            const ver: u32 = @min(version, 4);
            const comp = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, self.api.wl_compositor_interface, ver, 0, name, self.api.wl_compositor_interface.name, ver, self.api.wl_compositor_interface);
            self.compositor = @ptrCast(comp);
        } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
            const one: u32 = 1;
            const sh = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, self.api.wl_shm_interface, one, 0, name, self.api.wl_shm_interface.name, one, self.api.wl_shm_interface);
            self.shm = @ptrCast(sh);
        } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
            const ver: u32 = @min(version, 5);
            const wm = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &xdg_wm_base_interface, ver, 0, name, xdg_wm_base_interface.name, ver, &xdg_wm_base_interface);
            self.wm_base = @ptrCast(wm);
        } else if (std.mem.eql(u8, iface_name, "wl_seat")) {
            const ver: u32 = @min(version, 5);
            const st = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, self.api.wl_seat_interface, ver, 0, name, self.api.wl_seat_interface.name, ver, self.api.wl_seat_interface);
            self.seat = @ptrCast(st);
        } else if (std.mem.eql(u8, iface_name, "wl_data_device_manager")) {
            const one: u32 = 1;
            const ddm = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &data_device_manager_interface, one, 0, name, data_device_manager_interface.name, one, &data_device_manager_interface);
            self.ddm = @ptrCast(ddm);
        } else if (std.mem.eql(u8, iface_name, "zxdg_decoration_manager_v1")) {
            const one: u32 = 1;
            const dm = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &decoration_manager_interface, one, 0, name, decoration_manager_interface.name, one, &decoration_manager_interface);
            self.dec_manager = @ptrCast(dm);
        }
    }

    fn registryGlobalRemove(_: ?*anyopaque, _: *Registry, _: u32) callconv(.c) void {}

    /// Create pointer/keyboard objects once the seat reports capabilities.
    /// Compositors version the child object after the seat resource, so a
    /// v5 seat still yields v5 pointer events (axis_source/axis_stop/…).
    /// The listener tables below handle every event slot; the version
    /// requested here mirrors the parent like the generated C stubs do.
    fn ensureSeatDevices(self: *WaylandBackend) void {
        const seat = self.seat orelse return;
        if (self.pointer == null and (self.seat_caps & WL_SEAT_CAP_POINTER) != 0) {
            // wl_seat.get_pointer is opcode 0.
            const pointer_version = @min(self.api.wl_proxy_get_version(@ptrCast(seat)), @as(u32, @intCast(self.api.wl_pointer_interface.version)));
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(seat), 0, self.api.wl_pointer_interface, pointer_version, 0, @as(?*anyopaque, null));
            if (raw) |p| {
                self.pointer = @ptrCast(p);
                _ = self.api.wl_proxy_add_listener(@ptrCast(p), &default_pointer_listener, self);
            }
        }
        if (self.keyboard == null and (self.seat_caps & WL_SEAT_CAP_KEYBOARD) != 0) {
            // wl_seat.get_keyboard is opcode 1.
            const keyboard_version = @min(self.api.wl_proxy_get_version(@ptrCast(seat)), @as(u32, @intCast(self.api.wl_keyboard_interface.version)));
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(seat), 1, self.api.wl_keyboard_interface, keyboard_version, 0, @as(?*anyopaque, null));
            if (raw) |k| {
                self.keyboard = @ptrCast(k);
                _ = self.api.wl_proxy_add_listener(@ptrCast(k), &default_keyboard_listener, self);
            }
        }
        if (self.data_device == null and self.ddm != null) {
            // wl_data_device_manager.get_data_device is opcode 1.
            const raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.ddm.?), 1, &data_device_interface, 1, 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(seat)));
            if (raw) |dd| {
                self.data_device = @ptrCast(dd);
                const stored = self.api.wl_proxy_get_interface(dd);
                zlog.log("wayland", "data_device created: want={x} got={x} name={s}", .{ @intFromPtr(&data_device_interface), @intFromPtr(stored), if (stored) |s| std.mem.span(s.name) else "<null>" });
                _ = self.api.wl_proxy_add_listener(@ptrCast(dd), &default_data_device_listener, self);
            }
        }
    }

    fn pushInputEvent(self: *WaylandBackend, ev: event.Event) void {
        if (self.target_queue) |q| {
            _ = q.push(ev);
        }
    }

    fn seatCapabilities(data: ?*anyopaque, _: *Seat, caps: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.seat_caps = caps;
        self.ensureSeatDevices();
    }

    fn seatName(_: ?*anyopaque, _: *Seat, _: [*:0]const u8) callconv(.c) void {}

    fn pointerEnter(data: ?*anyopaque, _: *Pointer, serial: u32, _: *Surface, sx: i32, sy: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.last_serial = serial;
        self.pointer_inside = true;
        self.pointer_x = wlFixedToFloat(sx);
        self.pointer_y = wlFixedToFloat(sy);
        self.applyCursor();
        self.pushInputEvent(.{ .mouse = .{
            .pos = .{ .x = self.pointer_x, .y = self.pointer_y },
            .button = .left,
            .pressed = false,
            .motion = true,
            .modifiers = evdev.modifiersFromMask(self.mods_mask),
        } });
    }

    fn pointerLeave(data: ?*anyopaque, _: *Pointer, _: u32, _: *Surface) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.pointer_inside = false;
    }

    fn pointerMotion(data: ?*anyopaque, _: *Pointer, time: u32, sx: i32, sy: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.pointer_x = wlFixedToFloat(sx);
        self.pointer_y = wlFixedToFloat(sy);
        self.pushInputEvent(.{ .mouse = .{
            .pos = .{ .x = self.pointer_x, .y = self.pointer_y },
            .button = .left,
            .pressed = false,
            .motion = true,
            .modifiers = evdev.modifiersFromMask(self.mods_mask),
            .time_ms = time,
        } });
    }

    fn pointerButton(data: ?*anyopaque, _: *Pointer, _: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const btn = waylandMouseButton(button) orelse return;
        self.pushInputEvent(.{ .mouse = .{
            .pos = .{ .x = self.pointer_x, .y = self.pointer_y },
            .button = btn,
            .pressed = state == 1,
            .modifiers = evdev.modifiersFromMask(self.mods_mask),
            .time_ms = time,
        } });
    }

    /// Linux button code → normalized button. Null for wheel/unknown codes
    /// (wheel is scroll, not clicks — see the X11 backend note). Pure for
    /// testability.
    fn waylandMouseButton(code: u32) ?event.MouseButton {
        return switch (code) {
            BTN_LEFT => .left,
            BTN_RIGHT => .right,
            BTN_MIDDLE => .middle,
            BTN_FORWARD => .forward,
            BTN_BACK => .back,
            else => null,
        };
    }

    /// Axis values → scroll lines. High-resolution steps (1/120th of a
    /// notch) win, then legacy discrete steps, then the continuous value
    /// (≈10 units per click) scaled down. Vertical positive means down on
    /// the wire; our dy positive is up. Pure for testability.
    fn axisScrollLines(v120: i32, discrete: i32, value: i32, is_vertical: bool) f32 {
        var lines: f32 = if (v120 != 0)
            @as(f32, @floatFromInt(v120)) / 120.0
        else if (discrete != 0)
            @floatFromInt(discrete)
        else
            @as(f32, @floatFromInt(value)) / 10.0;
        if (is_vertical) lines = -lines;
        return lines;
    }

    /// Axis number → scroll lines for plain discrete/continuous input.
    fn axisLines(discrete: i32, value: i32, is_vertical: bool) f32 {
        return axisScrollLines(0, discrete, value, is_vertical);
    }

    fn pointerAxis(data: ?*anyopaque, _: *Pointer, time: u32, axis: u32, value: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        _ = time;
        if (axis == 0) {
            self.axis_v = value;
        } else {
            self.axis_h = value;
        }
    }

    fn pointerAxisDiscrete(data: ?*anyopaque, _: *Pointer, axis: u32, discrete: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (axis == 0) {
            self.disc_v = discrete;
        } else {
            self.disc_h = discrete;
        }
    }

    /// High-resolution wheel steps (v8+): positive is down/right, same
    /// wire convention as axis and axis_discrete.
    fn pointerAxisValue120(data: ?*anyopaque, _: *Pointer, axis: u32, value120: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (axis == 0) {
            self.v120_v = value120;
        } else {
            self.v120_h = value120;
        }
    }

    /// The axis source (wheel, finger, tablet tool...) does not change how
    /// deltas become lines, but the slot must be non-null: libwayland aborts
    /// the process when a v5 compositor sends it and the listener is null.
    fn pointerAxisSource(_: ?*anyopaque, _: *Pointer, _: u32) callconv(.c) void {}

    /// Gesture end marker. pointerFrame already flushes the accumulated
    /// deltas on every frame, so there is nothing left to do here.
    fn pointerAxisStop(_: ?*anyopaque, _: *Pointer, _: u32, _: u32) callconv(.c) void {}

    /// v9 scroll direction hint (natural vs. traditional wheels). Mirrors
    /// the compositor-resolved axis deltas we already consume, so ignore it.
    fn pointerAxisRelativeDirection(_: ?*anyopaque, _: *Pointer, _: u32, _: u32) callconv(.c) void {}

    fn pointerFrame(data: ?*anyopaque, _: *Pointer) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const dy = axisScrollLines(self.v120_v, self.disc_v, self.axis_v, true);
        const dx = axisScrollLines(self.v120_h, self.disc_h, self.axis_h, false);
        self.axis_v = 0;
        self.axis_h = 0;
        self.disc_v = 0;
        self.disc_h = 0;
        self.v120_v = 0;
        self.v120_h = 0;
        if (dx != 0 or dy != 0) {
            self.pushInputEvent(.{ .scroll = .{
                .pos = .{ .x = self.pointer_x, .y = self.pointer_y },
                .dx = dx,
                .dy = dy,
                .modifiers = evdev.modifiersFromMask(self.mods_mask),
            } });
        }
    }

    fn keyboardKeymap(data: ?*anyopaque, _: *Keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        // The fd must be closed on every path — it leaks otherwise.
        if (fd < 0) return;
        defer _ = std.os.linux.close(fd);
        if (self.xkb) |*x| {
            if (format != WL_KEYMAP_FORMAT_XKB_V1) return;
            if (size == 0 or size > 4 * 1024 * 1024) return;
            const map = std.os.linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
            if (@as(isize, @bitCast(map)) < 0) return;
            const bytes: [*]const u8 = @ptrFromInt(map);
            defer _ = std.os.linux.munmap(bytes, size);
            x.setKeymapBuffer(bytes, size) catch |err| {
                if (self.debug_events) {
                    std.debug.print("wayland xkb keymap compile failed: {s}\n", .{@errorName(err)});
                }
            };
            if (self.debug_events and x.hasLiveState()) {
                std.debug.print("wayland xkb keymap live ({d} bytes)\n", .{size});
            }
        }
    }

    fn keyboardEnter(data: ?*anyopaque, _: *Keyboard, serial: u32, _: *Surface, _: ?*anyopaque) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.last_serial = serial;
        self.focused = true;
        self.pushInputEvent(.{ .window = .focused });
    }

    fn keyboardLeave(data: ?*anyopaque, _: *Keyboard, _: u32, _: *Surface) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.focused = false;
        self.repeat_evdev = null; // no stuck repeats after focus loss
        self.pushInputEvent(.{ .window = .unfocused });
    }

    /// Shared press/release translation for real transitions and repeat
    /// ticks. xkb order: the caller updates key state first (real events),
    /// repeats only re-read it.
    fn emitKeycode(self: *WaylandBackend, evdev_code: u32, pressed: bool, repeat: bool) void {
        const xkb_code = evdev_code + 8;
        const mods = evdev.modifiersFromMask(self.mods_mask);
        // evdev mapping is the default; xkb overrides it when live.
        var mapped: event.Key = evdev.keyFromEvdev(evdev_code);
        var text_len: usize = 0;
        var text_buf: [32]u8 = undefined;
        if (self.xkb) |*x| {
            if (x.hasLiveState()) {
                const sym = x.keysym(xkb_code);
                if (sym != xkb.XKB_KEY_NoSymbol) mapped = xkb.keyFromKeysym(sym);
                if (pressed) {
                    const n = x.utf8(xkb_code, text_buf[0..]);
                    if (isPrintableText(text_buf[0..n])) text_len = n;
                }
            } else if (pressed) {
                const shift = (self.mods_mask & XKB_MOD_SHIFT) != 0;
                if (evdev.charFromEvdev(evdev_code, shift)) |byte| {
                    text_buf[0] = byte;
                    text_len = 1;
                }
            }
        } else if (pressed) {
            const shift = (self.mods_mask & XKB_MOD_SHIFT) != 0;
            if (evdev.charFromEvdev(evdev_code, shift)) |byte| {
                text_buf[0] = byte;
                text_len = 1;
            }
        }
        self.pushInputEvent(.{ .key = .{
            .key = mapped,
            .pressed = pressed,
            .modifiers = mods,
            .repeat = repeat,
        } });
        if (pressed and text_len > 0) {
            var text_ev = event.TextEvent{};
            @memcpy(text_ev.text[0..text_len], text_buf[0..text_len]);
            text_ev.len = @intCast(text_len);
            self.pushInputEvent(.{ .text = text_ev });
        }
    }

    /// Printable-text rule shared by both translation paths (mirrors the
    /// X11 backend's filter so typing behaves identically everywhere).
    fn isPrintableText(bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > 32) return false;
        if (bytes.len == 1 and bytes[0] == '\t') return true;
        return bytes[0] >= 0x20 and bytes[0] != 0x7f;
    }

    fn keyboardKey(data: ?*anyopaque, _: *Keyboard, _: u32, time: u32, key: u32, state: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        _ = time;
        // wl_keyboard.key carries evdev codes; only xkbcommon needs +8.
        const evdev_code = key;
        const pressed = state == 1;
        if (self.xkb) |*x| {
            if (x.hasLiveState()) x.updateKey(key + 8, pressed);
        }
        self.emitKeycode(evdev_code, pressed, false);
        if (pressed) {
            // Arm client-side repeat on the wall clock (compositor event
            // timestamps live on a different epoch — never mix them).
            // Modifiers never repeat (mirrors toolkit behavior).
            if (!evdev.isModifier(evdev_code) and self.repeat_rate > 0) {
                self.repeat_evdev = evdev_code;
                self.repeat_next_ms = wallMs() + self.repeat_delay_ms;
            }
        } else if (self.repeat_evdev == evdev_code) {
            self.repeat_evdev = null;
        }
    }

    fn keyboardModifiers(data: ?*anyopaque, _: *Keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.mods_mask = depressed | latched;
        if (self.xkb) |*x| x.syncModifiers(depressed, latched, locked, group);
    }

    // -- clipboard (data-device) -----------------------------------------

    const MIME_UTF8: [*:0]const u8 = "UTF8_STRING";
    const MIME_TEXT_UTF8: [*:0]const u8 = "text/plain;charset=utf-8";
    const MIME_TEXT: [*:0]const u8 = "text/plain";
    const MIME_STRING: [*:0]const u8 = "STRING";

    /// Bit for offer_mimes per text mime, best first for receive choice.
    fn offerMimeBit(mime: []const u8) u8 {
        if (std.mem.eql(u8, mime, "UTF8_STRING")) return 1 << 0;
        if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return 1 << 1;
        if (std.mem.eql(u8, mime, "text/plain")) return 1 << 2;
        if (std.mem.eql(u8, mime, "TEXT")) return 1 << 3;
        if (std.mem.eql(u8, mime, "STRING")) return 1 << 4;
        return 0;
    }

    fn bestOfferMime(mimes: u8) ?[*:0]const u8 {
        if (mimes & (1 << 0) != 0) return MIME_UTF8;
        if (mimes & (1 << 1) != 0) return MIME_TEXT_UTF8;
        if (mimes & (1 << 2) != 0) return MIME_TEXT;
        if (mimes & (1 << 3) != 0) return MIME_TEXT;
        if (mimes & (1 << 4) != 0) return MIME_STRING;
        return null;
    }

    fn dataOfferOffer(data: ?*anyopaque, _: *DataOffer, mime: [*:0]const u8) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.offer_mimes |= offerMimeBit(std.mem.span(mime));
    }

    fn dataDeviceOffer(data: ?*anyopaque, _: *DataDevice, offer: *DataOffer) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.cur_offer = offer;
        self.offer_mimes = 0;
        _ = self.api.wl_proxy_add_listener(@ptrCast(offer), &default_data_offer_listener, self);
    }

    fn dataDeviceEnter(_: ?*anyopaque, _: *DataDevice, _: u32, _: *Surface, _: i32, _: i32, _: ?*DataOffer) callconv(.c) void {}
    fn dataDeviceLeave(_: ?*anyopaque, _: *DataDevice) callconv(.c) void {}
    fn dataDeviceMotion(_: ?*anyopaque, _: *DataDevice, _: u32, _: i32, _: i32) callconv(.c) void {}
    fn dataDeviceDrop(_: ?*anyopaque, _: *DataDevice) callconv(.c) void {}

    fn dataDeviceSelection(data: ?*anyopaque, _: *DataDevice, offer: ?*DataOffer) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.cur_offer = offer;
        if (offer == null) self.offer_mimes = 0;
    }

    fn dataSourceTarget(_: ?*anyopaque, _: *DataSource, _: ?[*:0]const u8) callconv(.c) void {}

    fn dataSourceSend(data: ?*anyopaque, _: *DataSource, _: [*:0]const u8, fd: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        defer _ = std.os.linux.close(fd);
        if (fd < 0) return;
        var off: usize = 0;
        while (off < self.offered_len) {
            const slice = self.offered[off..self.offered_len];
            const n = std.os.linux.write(fd, slice.ptr, slice.len);
            if (@as(isize, @bitCast(n)) <= 0) break;
            off += n;
        }
    }

    fn dataSourceCancelled(data: ?*anyopaque, source: *DataSource) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.owning_selection = false;
        if (self.data_source == source) {
            self.api.wl_proxy_destroy(@ptrCast(source));
            self.data_source = null;
        }
    }

    /// Monotonic milliseconds for clipboard/paste deadlines.
    fn nowMs() i64 {
        var ts = std.mem.zeroes(std.os.linux.timespec);
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
    }

    fn setClipboardFn(ptr: *anyopaque, text: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ddm = self.ddm orelse return false;
        if (self.last_serial == 0) return false;
        const n = @min(text.len, self.offered.len);
        @memcpy(self.offered[0..n], text[0..n]);
        self.offered_len = n;
        if (self.data_source) |ds| {
            self.api.wl_proxy_destroy(@ptrCast(ds));
            self.data_source = null;
        }
        // wl_data_device_manager.create_data_source is opcode 0.
        const raw = self.api.wl_proxy_marshal_flags(@ptrCast(ddm), 0, &data_source_interface, 1, 0, @as(?*anyopaque, null));
        const source: *DataSource = @ptrCast(raw orelse return false);
        _ = self.api.wl_proxy_add_listener(@ptrCast(source), &default_data_source_listener, self);
        // wl_data_source.offer is opcode 0.
        for ([3][*:0]const u8{ MIME_UTF8, MIME_TEXT_UTF8, MIME_TEXT }) |mime| {
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(source), 0, null, 1, 0, mime);
        }
        // wl_data_device.set_selection is opcode 1.
        const dd = self.data_device orelse return false;
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(dd), 1, null, 1, 0, @as(*anyopaque, @ptrCast(source)), self.last_serial);
        _ = self.api.wl_display_flush(self.display);
        self.data_source = source;
        self.owning_selection = true;
        return true;
    }

    fn getClipboardFn(ptr: *anyopaque, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (out.len == 0) return 0;
        if (self.owning_selection) {
            const n = @min(self.offered_len, out.len);
            @memcpy(out[0..n], self.offered[0..n]);
            return n;
        }
        const dd = self.data_device orelse return 0;
        _ = dd;
        // Collect the current offer first (selection events arrive here).
        _ = self.api.wl_display_roundtrip(self.display);
        const offer = self.cur_offer orelse return 0;
        const mime = bestOfferMime(self.offer_mimes) orelse return 0;
        var fds: [2]c_int = .{ -1, -1 };
        if (std.os.linux.pipe(&fds) != 0) return 0;
        // wl_data_offer.receive is opcode 1.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(offer), 1, null, 1, 0, mime, fds[1]);
        _ = std.os.linux.close(fds[1]);
        _ = self.api.wl_display_flush(self.display);
        defer _ = std.os.linux.close(fds[0]);
        // Drain until EOF or a 1s deadline, dispatching so pongs and
        // input keep flowing while we wait.
        var total: usize = 0;
        const deadline = nowMs() + 1000;
        while (total < out.len and nowMs() < deadline) {
            var pfd = [1]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfd, 25) catch 0;
            if (ready > 0) {
                const left = out[total..];
                const n = std.os.linux.read(fds[0], left.ptr, left.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                total += n;
                continue;
            }
            _ = self.api.wl_display_dispatch_pending(self.display);
        }
        return total;
    }

    // -- title + cursor -------------------------------------------------

    /// (Re)push the window title: xdg_toplevel.set_title is opcode 2.
    fn pushTitle(self: *@This(), title: [*:0]const u8) void {
        const top = self.xdg_toplevel orelse return;
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(top), 2, null, self.api.wl_proxy_get_version(@ptrCast(top)), 0, title);
        _ = self.api.wl_display_flush(self.display);
    }

    fn titleFn(ptr: *anyopaque, title: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var buf: [512]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        self.pushTitle(@ptrCast(&buf));
    }

    fn cursorThemeName(shape: backend.CursorShape) [*:0]const u8 {
        return switch (shape) {
            .default => "left_ptr",
            .text => "xterm",
            .pointer => "hand2",
        };
    }

    /// Attach the themed cursor image for the current shape. Needs a
    /// pointer-enter serial; reuses the last one while inside.
    fn applyCursor(self: *@This()) void {
        const capi = self.cursor_api orelse return;
        const theme = self.cursor_theme orelse return;
        const pointer = self.pointer orelse return;
        const surface = self.cursor_surface orelse return;
        if (!self.pointer_inside or self.last_serial == 0) return;
        const cursor = capi.theme_get_cursor(theme, cursorThemeName(self.cursor_shape)) orelse return;
        if (cursor.image_count == 0) return;
        const image = cursor.images[0];
        const buffer = capi.image_get_buffer(image) orelse return;
        // wl_surface.attach/damage/commit are opcodes 1/2/6 (see presentFn).
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 1, null, self.api.wl_proxy_get_version(@ptrCast(surface)), 0, buffer, @as(i32, 0), @as(i32, 0));
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 2, null, self.api.wl_proxy_get_version(@ptrCast(surface)), 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(image.width)), @as(i32, @intCast(image.height)));
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(surface), 6, null, self.api.wl_proxy_get_version(@ptrCast(surface)), 0);
        // wl_pointer.set_cursor is opcode 0.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(pointer), 0, null, 1, 0, self.last_serial, @as(*anyopaque, @ptrCast(surface)), @as(i32, @intCast(image.hotspot_x)), @as(i32, @intCast(image.hotspot_y)));
        _ = self.api.wl_display_flush(self.display);
    }

    fn cursorFn(ptr: *anyopaque, shape: backend.CursorShape) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.cursor_shape = shape;
        self.applyCursor();
    }

    // -- chrome ---------------------------------------------------------

    /// ResizeEdge (shared _NET order) → xdg_toplevel.resize codes.
    fn resizeEdgeCode(edge: backend.ResizeEdge) u32 {
        return switch (edge) {
            .top_left => XDG_RESIZE_TOP_LEFT,
            .top => XDG_RESIZE_TOP,
            .top_right => XDG_RESIZE_TOP_RIGHT,
            .right => XDG_RESIZE_RIGHT,
            .bottom_right => XDG_RESIZE_BOTTOM_RIGHT,
            .bottom => XDG_RESIZE_BOTTOM,
            .bottom_left => XDG_RESIZE_BOTTOM_LEFT,
            .left => XDG_RESIZE_LEFT,
        };
    }

    fn decorationConfigure(data: ?*anyopaque, _: *Decoration, mode: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.deco_mode = mode;
    }

    /// Push the current decorated flag: client-side for app-drawn chrome,
    /// unset (compositor default) for framed.
    fn applyDecorations(self: *@This()) void {
        const deco = self.decoration orelse return;
        if (self.decorated) {
            // unset_mode is opcode 2.
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(deco), 2, null, 1, 0);
        } else {
            // set_mode is opcode 1.
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(deco), 1, null, 1, 0, DECOR_MODE_CLIENT_SIDE);
        }
        _ = self.api.wl_display_flush(self.display);
    }

    fn decoratedFn(ptr: *anyopaque, decorated: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.decorated = decorated;
        self.applyDecorations();
    }

    fn dragFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const seat = self.seat orelse return;
        const top = self.xdg_toplevel orelse return;
        if (self.last_serial == 0) return;
        // xdg_toplevel.move is opcode 5.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(top), 5, null, self.api.wl_proxy_get_version(@ptrCast(top)), 0, @as(*anyopaque, @ptrCast(seat)), self.last_serial);
        _ = self.api.wl_display_flush(self.display);
    }

    fn resizeFn(ptr: *anyopaque, edge: backend.ResizeEdge) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const seat = self.seat orelse return;
        const top = self.xdg_toplevel orelse return;
        if (self.last_serial == 0) return;
        // xdg_toplevel.resize is opcode 6.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(top), 6, null, self.api.wl_proxy_get_version(@ptrCast(top)), 0, @as(*anyopaque, @ptrCast(seat)), self.last_serial, resizeEdgeCode(edge));
        _ = self.api.wl_display_flush(self.display);
    }

    fn minimizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const top = self.xdg_toplevel orelse return;
        // xdg_toplevel.set_minimized is opcode 13.
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(top), 13, null, self.api.wl_proxy_get_version(@ptrCast(top)), 0);
        _ = self.api.wl_display_flush(self.display);
    }

    fn maximizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const top = self.xdg_toplevel orelse return;
        const ver = self.api.wl_proxy_get_version(@ptrCast(top));
        if (self.maximized) {
            // unset_maximized is opcode 10.
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(top), 10, null, ver, 0);
        } else {
            // set_maximized is opcode 9.
            _ = self.api.wl_proxy_marshal_flags(@ptrCast(top), 9, null, ver, 0);
        }
        _ = self.api.wl_display_flush(self.display);
    }

    /// Wayland sizing is compositor-owned: there is no client resize
    /// request, so this records nothing and sends nothing. The compositor
    /// answers with configure events, which resize buffers and emit
    /// .resized through the normal path.
    fn sizeFn(_: *anyopaque, _: u32, _: u32) void {}

    fn keyboardRepeatInfo(data: ?*anyopaque, _: *Keyboard, rate: i32, delay: i32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        // Compositors send 0/0 when repeat is disabled; negative is nonsense.
        if (rate > 0 and delay >= 0) {
            self.repeat_rate = @intCast(rate);
            self.repeat_interval_ms = @max(1, @divTrunc(1000, @as(i64, rate)));
            self.repeat_delay_ms = delay;
        } else {
            self.repeat_rate = 0;
            self.repeat_evdev = null;
        }
    }

    /// Wall-clock milliseconds via gettimeofday (gooey watcher pattern).
    /// Repeat timing only — never mixed with compositor event timestamps,
    /// which live on a different epoch (see keyboardKey).
    fn wallMs() i64 {
        var tv: std.c.timeval = undefined;
        if (std.c.gettimeofday(&tv, null) != 0) return 0;
        return tv.sec * std.time.ms_per_s + @divTrunc(tv.usec, std.time.us_per_ms);
    }

    /// Emit synthetic repeats for a held key. Runs at the head of poll so
    /// repeats interleave with fresh compositor input in arrival order.
    fn tickRepeat(self: *WaylandBackend) void {
        const evdev_code = self.repeat_evdev orelse return;
        if (self.repeat_rate == 0) return;
        const now = wallMs();
        if (now < self.repeat_next_ms) return;
        self.repeat_next_ms = now + self.repeat_interval_ms;
        self.emitKeycode(evdev_code, true, true);
    }

    fn xdgPing(data: ?*anyopaque, wm: *XdgWmBase, serial: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        zlog.log("wayland", "ping {d} -> pong", .{serial});
        // Opcode 3 is pong on xdg_wm_base
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(wm), 3, null, self.api.wl_proxy_get_version(@ptrCast(wm)), 0, serial);
    }

    fn xdgSurfaceConfigure(data: ?*anyopaque, xs: *XdgSurface, serial: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.configured = true;
        // Opcode 4 is ack_configure on xdg_surface
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(xs), 4, null, self.api.wl_proxy_get_version(@ptrCast(xs)), 0, serial);
    }

    fn xdgToplevelConfigure(data: ?*anyopaque, _: *XdgToplevel, width: i32, height: i32, states: ?*anyopaque) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        // The states array is double-buffered compositor truth: maximized
        // bit drives toggleMaximizeWindow without local drift.
        if (states) |raw| {
            const arr: *const WlArray = @ptrCast(@alignCast(raw));
            const count = arr.size / 4;
            var i: usize = 0;
            var maxed = false;
            if (arr.data) |items| {
                while (i < count) : (i += 1) {
                    if (items[i] == XDG_STATE_MAXIMIZED) maxed = true;
                }
            }
            self.maximized = maxed;
        }
        if (width > 0 and height > 0) {
            const w: f32 = @floatFromInt(width);
            const h: f32 = @floatFromInt(height);
            if (w != self.size.w or h != self.size.h) {
                zlog.log("wayland", "configure {d}x{d} (was {d:.0}x{d:.0})", .{ width, height, self.size.w, self.size.h });
                self.size.w = w;
                self.size.h = h;
                self.recreateBuffer(@intCast(width), @intCast(height)) catch |err| {
                    zlog.log("wayland", "recreateBuffer {d}x{d} failed: {s}", .{ width, height, @errorName(err) });
                };
                self.updateOpaqueRegion(@intCast(width), @intCast(height));
                if (self.target_queue) |q| {
                    _ = q.push(.{ .window = .resized });
                }
            }
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: *XdgToplevel) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.target_queue) |q| {
            _ = q.push(.{ .window = .close_requested });
        }
    }

    fn xdgToplevelConfigureBounds(_: ?*anyopaque, _: *XdgToplevel, _: i32, _: i32) callconv(.c) void {}

    fn xdgToplevelWmCapabilities(_: ?*anyopaque, _: *XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    const default_reg_listener = RegistryListener{
        .global = registryGlobal,
        .global_remove = registryGlobalRemove,
    };

    const default_seat_listener = SeatListener{
        .capabilities = seatCapabilities,
        .name = seatName,
    };

    const default_pointer_listener = PointerListener{
        .enter = pointerEnter,
        .leave = pointerLeave,
        .motion = pointerMotion,
        .button = pointerButton,
        .axis = pointerAxis,
        .frame = pointerFrame,
        .axis_source = pointerAxisSource,
        .axis_stop = pointerAxisStop,
        .axis_discrete = pointerAxisDiscrete,
        .axis_value120 = pointerAxisValue120,
        .axis_relative_direction = pointerAxisRelativeDirection,
    };

    const default_keyboard_listener = KeyboardListener{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardModifiers,
        .repeat_info = keyboardRepeatInfo,
    };

    const default_data_offer_listener = DataOfferListener{
        .offer = dataOfferOffer,
    };

    const default_data_source_listener = DataSourceListener{
        .target = dataSourceTarget,
        .send = dataSourceSend,
        .cancelled = dataSourceCancelled,
    };

    const default_buffer_listener = WlBufferListener{
        .release = bufferRelease,
    };

    const default_data_device_listener = DataDeviceListener{
        .data_offer = dataDeviceOffer,
        .enter = dataDeviceEnter,
        .leave = dataDeviceLeave,
        .motion = dataDeviceMotion,
        .drop = dataDeviceDrop,
        .selection = dataDeviceSelection,
    };

    const default_decoration_listener = DecorationListener{
        .configure = decorationConfigure,
    };

    const default_wm_listener = XdgWmBaseListener{
        .ping = xdgPing,
    };

    const default_xs_listener = XdgSurfaceListener{
        .configure = xdgSurfaceConfigure,
    };

    const default_top_listener = XdgToplevelListener{
        .configure = xdgToplevelConfigure,
        .close = xdgToplevelClose,
        .configure_bounds = xdgToplevelConfigureBounds,
        .wm_capabilities = xdgToplevelWmCapabilities,
    };

    // Backend vtable functions
    fn kindFn(_: *anyopaque) backend.BackendKind {
        return .wayland;
    }

    fn pollFn(ptr: *anyopaque, out: *event.EventQueue) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.target_queue = out;
        self.ensureSeatDevices();
        self.tickRepeat();
        const before = out.len;
        self.drainEvents();
        _ = self.api.wl_display_dispatch_pending(self.display);
        _ = self.api.wl_display_flush(self.display);
        if (out.len != before) zlog.log("wayland", "poll: +{d} events (total {d})", .{ out.len - before, out.len });
    }

    /// Non-blocking socket drain. `dispatch_pending` alone only serves
    /// already-buffered events — without this read step pings and
    /// configures pile up unread and the compositor marks us
    /// "Not Responding" after its ping timeout (~2s observed on GNOME).
    fn drainEvents(self: *@This()) void {
        const prepare = self.api.wl_display_prepare_read orelse return;
        const read_ev = self.api.wl_display_read_events orelse return;
        const cancel = self.api.wl_display_cancel_read orelse return;
        // Queued events waiting? Dispatch them first, then read fresh ones.
        if (prepare(self.display) != 0) {
            _ = self.api.wl_display_dispatch_pending(self.display);
            if (prepare(self.display) != 0) return;
        }
        const fd = self.api.wl_display_get_fd(self.display);
        var pfd = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 0) catch 0;
        if (ready > 0) {
            const pre_err = self.api.wl_display_get_error(self.display);
            var perr_iface: ?*const Interface = null;
            var perr_id: u32 = 0;
            const perr_code = self.api.wl_display_get_protocol_error(self.display, &perr_iface, &perr_id);
            zlog.log("wayland", "drain: readable, pre-err={d} proto-err={d} id={d} iface={x}", .{ pre_err, perr_code, perr_id, @intFromPtr(perr_iface) });
            if (read_ev(self.display) != 0) {
                _ = cancel(self.display);
                return;
            }
            const n = self.api.wl_display_dispatch_pending(self.display);
            zlog.log("wayland", "drain: read socket, dispatched {d}", .{n});
        } else {
            _ = cancel(self.display);
        }
    }

    fn waitFn(ptr: *anyopaque, ns: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self.api.wl_display_flush(self.display);
        const fd = self.api.wl_display_get_fd(self.display);
        var pfd = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ms: i32 = @intCast(@min(ns / 1_000_000, 1000));
        _ = std.posix.poll(&pfd, ms) catch 0;
        // Bound idle spin: if the display fd stays readable with nothing to
        // dispatch, poll returns instantly and App.run busy-loops (~98% CPU
        // observed). A short unconditional yield keeps idle near zero with
        // negligible input-latency cost (empty poll = portable sleep).
        _ = std.posix.poll(&.{}, 4) catch 0;
    }

    fn wakeupFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.wakeups += 1;
        _ = self.api.wl_display_flush(self.display);
    }

    fn infoFn(ptr: *anyopaque) backend.WindowInfo {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .size = self.size,
            .scale_factor = self.scale_factor,
            .focused = self.focused,
        };
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene, glyph_pixels: []const u8, image_pixels: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const w: u32 = @intFromFloat(self.size.w);
        const h: u32 = @intFromFloat(self.size.h);
        // Lazily (re)fill the pool so a configure that arrived without
        // buffers (or a release that dropped a stale entry) heals here.
        self.recreateBuffer(w, h) catch |err| {
            zlog.log("wayland", "present SKIP: no buffer for {d}x{d}: {s}", .{ w, h, @errorName(err) });
            return;
        };
        var slot: ?*ShmBuffer = null;
        for (&self.bufs) |*e| {
            if (!e.busy and e.buf != null and e.w == w and e.h == h) {
                slot = e;
                break;
            }
        }
        const e = slot orelse {
            zlog.log("wayland", "present SKIP: both buffers busy (compositor backpressure)", .{});
            return;
        };
        {
            const px = e.pixels.?;
            zlog.log("wayland", "present {d}x{d} quads={d} glyphs={d}", .{ w, h, scene.slice().len, scene.glyphSlice().len });
            if (std.c.getenv("ZUI_COLOR_BARS") != null) {
                // Diagnostic: three full-width bands. If the compositor
                // shows R/G/B correctly the buffer path is innocent.
                var y: u32 = 0;
                while (y < h) : (y += 1) {
                    const c = if (y < h / 3)
                        gpu.vellz.Color.rgb(1, 0, 0)
                    else if (y < 2 * h / 3)
                        gpu.vellz.Color.rgb(0, 1, 0)
                    else
                        gpu.vellz.Color.rgb(0, 0, 1);
                    var x: u32 = 0;
                    while (x < w) : (x += 1) {
                        const off = (@as(usize, y) * w + x) * 4;
                        px[off] = @intFromFloat(c.b * 255);
                        px[off + 1] = @intFromFloat(c.g * 255);
                        px[off + 2] = @intFromFloat(c.r * 255);
                        px[off + 3] = 255;
                    }
                }
            } else {
                self.renderer.render(px, w, h, .argb32, gpu.vellz.Color.hex(0x0e0e13), scene, glyph_pixels, image_pixels) catch |err| {
                    zlog.log("wayland", "vellz render failed: {s}", .{@errorName(err)});
                    return;
                };
            }
            if (std.c.getenv("ZUI_MAGENTA_FRAME") != null) {
                // Diagnostic: magenta 2px frame so screenshots reveal the
                // exact window rect for sampling.
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    var yy: u32 = 0;
                    while (yy < 2) : (yy += 1) {
                        for ([2]u32{ yy, h - 1 - yy }) |yyy| {
                            const off = (@as(usize, yyy) * w + x) * 4;
                            px[off] = 255;
                            px[off + 1] = 0;
                            px[off + 2] = 255;
                            px[off + 3] = 255;
                        }
                    }
                }
                var y: u32 = 0;
                while (y < h) : (y += 1) {
                    var xx: u32 = 0;
                    while (xx < 2) : (xx += 1) {
                        for ([2]u32{ xx, w - 1 - xx }) |xxx| {
                            const off = (@as(usize, y) * w + xxx) * 4;
                            px[off] = 255;
                            px[off + 1] = 0;
                            px[off + 2] = 255;
                            px[off + 3] = 255;
                        }
                    }
                }
            }

            if (self.surface) |s| {
                if (e.buf) |b| {
                    // Opcode 1: wl_surface::attach(buffer, x=0, y=0)
                    _ = self.api.wl_proxy_marshal_flags(@ptrCast(s), 1, null, self.api.wl_proxy_get_version(@ptrCast(s)), 0, b, @as(i32, 0), @as(i32, 0));
                    // Opcode 2: wl_surface::damage(x=0, y=0, w, h)
                    _ = self.api.wl_proxy_marshal_flags(@ptrCast(s), 2, null, self.api.wl_proxy_get_version(@ptrCast(s)), 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(w)), @as(i32, @intCast(h)));
                    // Opcode 6: wl_surface::commit()
                    _ = self.api.wl_proxy_marshal_flags(@ptrCast(s), 6, null, self.api.wl_proxy_get_version(@ptrCast(s)), 0);
                    _ = self.api.wl_display_flush(self.display);
                    e.busy = true;
                }
            }
        }
        self.presents += 1;
    }
};

test "wayland availability and initialization" {
    if (!WaylandBackend.isAvailable()) return;

    var b = WaylandBackend.init(std.testing.allocator, "ZUI Wayland Test", 320, 240) catch |err| switch (err) {
        error.CannotConnectWayland => return,
        else => return err,
    };
    defer b.deinit();

    const handle = b.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.wayland, handle.kind());
    try std.testing.expectEqual(@as(f32, 320), handle.windowInfo().size.w);
    try std.testing.expectEqual(@as(f32, 240), handle.windowInfo().size.h);

    var sc = gpu.Scene{};
    _ = sc.push(.{ .x = 10, .y = 10, .w = 100, .h = 100, .color = gpu.vellz.Color.hex(0x00FF00) });
    handle.present(&sc, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), b.presents);
}

test "wayland seat spawns pointer and keyboard" {
    // Runs against the real compositor when present: proves capability
    // discovery, device creation, and listener attach end to end. Event
    // callbacks themselves need a human (or uinput) to fire real input.
    if (!WaylandBackend.isAvailable()) return;

    var b = WaylandBackend.init(std.testing.allocator, "ZUI Wayland Input Test", 320, 240) catch |err| switch (err) {
        error.CannotConnectWayland => return,
        else => return err,
    };
    defer b.deinit();

    if ((b.seat_caps & WL_SEAT_CAP_POINTER) != 0) {
        try std.testing.expect(b.pointer != null);
    }
    if ((b.seat_caps & WL_SEAT_CAP_KEYBOARD) != 0) {
        try std.testing.expect(b.keyboard != null);
    }
}

test "wayland button codes and fixed-point conversion" {
    try std.testing.expectEqual(event.MouseButton.left, WaylandBackend.waylandMouseButton(BTN_LEFT));
    try std.testing.expectEqual(event.MouseButton.right, WaylandBackend.waylandMouseButton(BTN_RIGHT));
    try std.testing.expectEqual(event.MouseButton.middle, WaylandBackend.waylandMouseButton(BTN_MIDDLE));
    try std.testing.expectEqual(event.MouseButton.forward, WaylandBackend.waylandMouseButton(BTN_FORWARD).?);
    try std.testing.expectEqual(event.MouseButton.back, WaylandBackend.waylandMouseButton(BTN_BACK).?);
    try std.testing.expect(WaylandBackend.waylandMouseButton(0x999) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), wlFixedToFloat(384), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), wlFixedToFloat(-512), 0.0001);
}

test "wayland key emission and repeat bookkeeping" {
    const t = std.testing;
    // Bare backend value: emitKeycode/tickRepeat only touch the queue,
    // modifiers, xkb handle, and repeat fields — never display/api/lib.
    var b = WaylandBackend{
        .allocator = t.allocator,
        .lib = undefined,
        .api = undefined,
        .renderer = gpu.vellz.Renderer.init(t.allocator),
        .display = @ptrFromInt(1),
        .registry = @ptrFromInt(2),
    };
    var q = event.EventQueue{};
    b.target_queue = &q;

    // evdev fallback path (no xkb): press emits key + text.
    b.emitKeycode(30, true, false);
    const first = q.pop().?;
    try t.expectEqual(event.Key.a, first.key.key);
    try t.expect(first.key.pressed and !first.key.repeat);
    const first_text = q.pop().?;
    try t.expectEqualStrings("a", first_text.text.slice());
    try t.expect(q.pop() == null);

    // Release emits bare key, no text.
    b.emitKeycode(30, false, false);
    const rel = q.pop().?;
    try t.expect(!rel.key.pressed);
    try t.expect(q.pop() == null);

    // Repeat armed by keyboardKey, fired by tickRepeat, cleared on release.
    b.repeat_rate = 30;
    b.repeat_interval_ms = 33;
    b.repeat_delay_ms = 500;
    WaylandBackend.keyboardKey(@ptrCast(&b), @ptrCast(@alignCast(@as(*Keyboard, @ptrFromInt(4)))), 0, 0, 30, 1);
    try t.expectEqual(@as(?u32, 30), b.repeat_evdev);
    _ = q.pop();
    _ = q.pop();
    // Not due yet: delay is 500ms out.
    b.tickRepeat();
    try t.expect(q.pop() == null);
    // Force due: repeats with the flag set, plus text.
    b.repeat_next_ms = 0;
    b.tickRepeat();
    const rep = q.pop().?;
    try t.expect(rep.key.pressed and rep.key.repeat);
    try t.expectEqual(event.Key.a, rep.key.key);
    const rep_text = q.pop().?;
    try t.expectEqualStrings("a", rep_text.text.slice());
    // Release disarms.
    WaylandBackend.keyboardKey(@ptrCast(&b), @ptrCast(@alignCast(@as(*Keyboard, @ptrFromInt(4)))), 0, 0, 30, 0);
    try t.expect(b.repeat_evdev == null);
    _ = q.pop();
    b.tickRepeat();
    try t.expect(q.pop() == null);

    // xkb branch: same emission contract through a live keymap.
    if (xkb.XkbApi.isAvailable()) {
        var x = try xkb.Xkb.init();
        x.setKeymapString(xkb.us_test_keymap) catch {
            x.deinit();
            return;
        };
        x.updateKey(38, true);
        // Move into the backend (single owner from here on).
        b.xkb = x;
        b.emitKeycode(30, true, false);
        const xk = q.pop().?;
        try t.expectEqual(event.Key.a, xk.key.key);
        const xt = q.pop().?;
        try t.expectEqualStrings("a", xt.text.slice());
        if (b.xkb) |*bx| bx.deinit();
        b.xkb = null;
    }
}

test "wayland wire keycodes translate reported letters and editing keys" {
    var b = WaylandBackend{
        .allocator = std.testing.allocator,
        .lib = undefined,
        .api = undefined,
        .renderer = gpu.vellz.Renderer.init(std.testing.allocator),
        .display = @ptrFromInt(1),
        .registry = @ptrFromInt(2),
    };
    var q = event.EventQueue{};
    b.target_queue = &q;
    defer if (b.xkb) |*x| x.deinit();
    // Exercise actual protocol callbacks, first fallback then live XKB.
    for (0..2) |mode| {
        if (mode == 1) {
            b.xkb = try xkb.Xkb.init();
            try b.xkb.?.setKeymapString(xkb.us_test_keymap);
        }
        const codes = [_]u32{ 49, 17, 18, 14, 105, 106, 111 };
        const keys = [_]event.Key{ .n, .w, .e, .backspace, .left, .right, .delete };
        for (codes, keys, 0..) |code, expected, i| {
            WaylandBackend.keyboardKey(@ptrCast(&b), @ptrFromInt(4), 0, 0, code, 1);
            try std.testing.expectEqual(expected, q.pop().?.key.key);
            if (i < 3) try std.testing.expectEqualStrings(([_][]const u8{ "n", "w", "e" })[i], q.pop().?.text.slice());
            try std.testing.expect(q.pop() == null);
            WaylandBackend.keyboardKey(@ptrCast(&b), @ptrFromInt(4), 0, 0, code, 0);
            try std.testing.expect(!q.pop().?.key.pressed);
            try std.testing.expect(q.pop() == null);
        }
    }
}

test "wayland scroll lines prefer discrete steps" {
    // Wheel click up: discrete -1 on the vertical axis → +1 line (dy up).
    try std.testing.expectApproxEqAbs(@as(f32, 1), WaylandBackend.axisLines(-1, -10, true), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -2), WaylandBackend.axisLines(2, 20, true), 0.0001);
    // No discrete steps: continuous value scales at 10 units per line.
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), WaylandBackend.axisLines(0, 15, false), 0.0001);
    // Wire -10 on the vertical axis means "up", i.e. +1 line.
    try std.testing.expectApproxEqAbs(@as(f32, 1), WaylandBackend.axisLines(0, -10, true), 0.0001);
}

test "wayland scroll lines prefer high-resolution steps" {
    // One notch down in axis_value120 units (positive is down) → -1 line.
    try std.testing.expectApproxEqAbs(@as(f32, -1), WaylandBackend.axisScrollLines(120, 0, 0, true), 0.0001);
    // Half a notch up.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), WaylandBackend.axisScrollLines(-60, 0, 0, true), 0.0001);
    // v120 wins when the continuous value arrives alongside it.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), WaylandBackend.axisScrollLines(-60, 1, 10, true), 0.0001);
    // Without v120, discrete wins; without either, continuous / 10.
    try std.testing.expectApproxEqAbs(@as(f32, -2), WaylandBackend.axisScrollLines(0, 2, 20, true), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), WaylandBackend.axisScrollLines(0, 0, 15, false), 0.0001);
}

test "wayland pointer listener covers every event slot" {
    // libwayland aborts the process when an incoming event maps to a null
    // listener slot (this is how scrolling used to crash on v5 seats), so
    // every slot through axis_relative_direction must be populated.
    inline for (@typeInfo(PointerListener).@"struct".field_names) |field| {
        try std.testing.expect(@field(WaylandBackend.default_pointer_listener, field) != null);
    }
}

test "wayland scroll survives axis_source and high-resolution steps" {
    const t = std.testing;
    // Bare backend value: the scroll callbacks only touch accumulators and
    // the target queue, never display/api/lib.
    var b = WaylandBackend{
        .allocator = t.allocator,
        .lib = undefined,
        .api = undefined,
        .renderer = gpu.vellz.Renderer.init(t.allocator),
        .display = @ptrFromInt(1),
        .registry = @ptrFromInt(2),
    };
    var q = event.EventQueue{};
    b.target_queue = &q;
    const ptr: *Pointer = @ptrFromInt(4);

    // A v5 compositor announces the axis source before the deltas; that
    // listener slot used to be null and libwayland aborted the process.
    WaylandBackend.pointerAxisSource(@ptrCast(&b), ptr, 0);
    // One notch down in high-resolution units, flushed by the frame.
    WaylandBackend.pointerAxisValue120(@ptrCast(&b), ptr, 0, 120);
    WaylandBackend.pointerFrame(@ptrCast(&b), ptr);
    const ev = q.pop() orelse return error.MissingScrollEvent;
    switch (ev) {
        .scroll => |s| try t.expectApproxEqAbs(@as(f32, -1), s.dy, 0.0001),
        else => return error.UnexpectedEvent,
    }
    try t.expect(q.pop() == null);

    // The stop marker arrives after the frame and must be a harmless no-op.
    WaylandBackend.pointerAxisStop(@ptrCast(&b), ptr, 0, 0);
    try t.expect(q.pop() == null);
}

test "wayland clipboard mime preference order" {
    try std.testing.expectEqual(@as(u8, 1), WaylandBackend.offerMimeBit("UTF8_STRING"));
    try std.testing.expect(WaylandBackend.offerMimeBit("image/png") == 0);
    try std.testing.expectEqualStrings("UTF8_STRING", std.mem.span(WaylandBackend.bestOfferMime(0b00011).?));
    try std.testing.expectEqualStrings("text/plain", std.mem.span(WaylandBackend.bestOfferMime(0b00100).?));
    try std.testing.expect(WaylandBackend.bestOfferMime(0) == null);
}

test "wayland cursor theme names" {
    try std.testing.expectEqualStrings("left_ptr", std.mem.span(WaylandBackend.cursorThemeName(.default)));
    try std.testing.expectEqualStrings("xterm", std.mem.span(WaylandBackend.cursorThemeName(.text)));
    try std.testing.expectEqualStrings("hand2", std.mem.span(WaylandBackend.cursorThemeName(.pointer)));
}

test "wayland decoration protocol values match the spec XML" {
    try std.testing.expectEqual(@as(u32, 1), DECOR_MODE_CLIENT_SIDE);
    try std.testing.expectEqual(@as(u32, 2), DECOR_MODE_SERVER_SIDE);
    try std.testing.expectEqual(@as(u32, 1), XDG_STATE_MAXIMIZED);
    // ResizeEdge (shared _NET order) translates to xdg codes.
    try std.testing.expectEqual(XDG_RESIZE_TOP_LEFT, WaylandBackend.resizeEdgeCode(.top_left));
    try std.testing.expectEqual(XDG_RESIZE_TOP, WaylandBackend.resizeEdgeCode(.top));
    try std.testing.expectEqual(XDG_RESIZE_TOP_RIGHT, WaylandBackend.resizeEdgeCode(.top_right));
    try std.testing.expectEqual(XDG_RESIZE_RIGHT, WaylandBackend.resizeEdgeCode(.right));
    try std.testing.expectEqual(XDG_RESIZE_BOTTOM_RIGHT, WaylandBackend.resizeEdgeCode(.bottom_right));
    try std.testing.expectEqual(XDG_RESIZE_BOTTOM, WaylandBackend.resizeEdgeCode(.bottom));
    try std.testing.expectEqual(XDG_RESIZE_BOTTOM_LEFT, WaylandBackend.resizeEdgeCode(.bottom_left));
    try std.testing.expectEqual(XDG_RESIZE_LEFT, WaylandBackend.resizeEdgeCode(.left));
}

test "xdg_toplevel request opcodes match the stable protocol" {
    try std.testing.expectEqual(@as(usize, 14), xdg_toplevel_methods.len);
    try std.testing.expectEqual(@as(c_int, 14), xdg_toplevel_interface.method_count);
    try std.testing.expectEqualStrings("set_maximized", std.mem.span(xdg_toplevel_methods[9].name));
    try std.testing.expectEqualStrings("unset_maximized", std.mem.span(xdg_toplevel_methods[10].name));
    try std.testing.expectEqualStrings("set_fullscreen", std.mem.span(xdg_toplevel_methods[11].name));
    try std.testing.expectEqualStrings("unset_fullscreen", std.mem.span(xdg_toplevel_methods[12].name));
    try std.testing.expectEqualStrings("set_minimized", std.mem.span(xdg_toplevel_methods[13].name));
}
