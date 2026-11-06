//! Wayland client protocol layer: libwayland-client / libwayland-cursor
//! loaded with dlopen, plus hand-written interface tables for the core,
//! xdg-shell, xdg-decoration, viewporter, fractional-scale, text-input-v3 and
//! data-device protocols. Nothing here links against wayland at build time.
//! Opcodes and layouts were verified against the protocol XML.

pub const std = @import("std");
pub const dl = @import("dl.zig");

pub const Display = opaque {};
pub const Registry = opaque {};
pub const Compositor = opaque {};
pub const Surface = opaque {};
pub const Region = opaque {};
pub const Shm = opaque {};
pub const ShmPool = opaque {};
pub const Buffer = opaque {};
pub const Callback = opaque {};
pub const Seat = opaque {};
pub const Pointer = opaque {};
pub const Keyboard = opaque {};
pub const XdgWmBase = opaque {};
pub const XdgSurface = opaque {};
pub const XdgToplevel = opaque {};
pub const XdgPopup = opaque {};
pub const XdgPositioner = opaque {};
pub const DataDeviceManager = opaque {};
pub const DataDevice = opaque {};
pub const DataOffer = opaque {};
pub const DataSource = opaque {};
pub const DecorationManager = opaque {};
pub const Decoration = opaque {};
pub const CursorTheme = opaque {};
pub const TextInputManager = opaque {};
pub const TextInput = opaque {};
pub const PrimaryDeviceManager = opaque {};
pub const PrimaryDevice = opaque {};
pub const PrimaryOffer = opaque {};
pub const PrimarySource = opaque {};
pub const CursorShapeManager = opaque {};
pub const CursorShapeDevice = opaque {};
/// Cursor entry: image array layout verified against wayland-cursor.h
/// (image_count, then images pointer; name follows and is unread).
pub const CursorHandle = extern struct {
    image_count: c_uint,
    images: [*]*CursorImage,
};
/// Opaque cursor frame; only hotspot/size are read (verified layout
/// against wayland-cursor.h), the buffer comes from `image_get_buffer`.
pub const CursorImage = extern struct {
    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    delay: u32,
};
pub const CursorEntry = extern struct {
    image_count: c_uint,
    images: [*]*CursorImage,
};

/// One wl_shm-backed frame buffer. `busy` is set on commit and cleared
/// by the compositor's `release` event; only idle entries may be
/// destroyed or reused.
pub const ShmBuffer = struct {
    buf: ?*Buffer = null,
    pixels: ?[]u8 = null,
    fd: c_int = -1,
    size: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    busy: bool = false,
};

/// wl_buffer listener: single `release` event (opcode 0).
pub const WlBufferListener = extern struct {
    release: ?*const fn (?*anyopaque, *Buffer) callconv(.c) void = null,
};

pub const WlCallbackListener = extern struct {
    done: ?*const fn (?*anyopaque, *Callback, u32) callconv(.c) void = null,
};

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const anyopaque,
    event_count: c_int,
    events: ?*const anyopaque,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const anyopaque,
};

// wl_surface.frame creates a one-shot wl_callback that fires when the
// compositor has displayed the committed surface. The core library exports
// wl_callback_interface, but keeping this tiny event table local avoids
// another mandatory dynamic symbol lookup.
pub const wl_callback_events = [_]Message{
    .{ .name = "done", .signature = "u", .types = null },
};
pub const wl_callback_interface: Interface = .{
    .name = "wl_callback",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 1,
    .events = @ptrCast(&wl_callback_events),
};

// Listeners
pub const RegistryListener = extern struct {
    global: ?*const fn (?*anyopaque, *Registry, u32, [*:0]const u8, u32) callconv(.c) void = null,
    global_remove: ?*const fn (?*anyopaque, *Registry, u32) callconv(.c) void = null,
};

pub const XdgWmBaseListener = extern struct {
    ping: ?*const fn (?*anyopaque, *XdgWmBase, u32) callconv(.c) void = null,
};

pub const XdgSurfaceListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgSurface, u32) callconv(.c) void = null,
};

/// xdg_popup events (xdg-shell v7). `configure` carries the popup's size in logical pixels.
pub const XdgPopupListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgPopup, i32, i32, i32, i32) callconv(.c) void = null,
    popup_done: ?*const fn (?*anyopaque, *XdgPopup) callconv(.c) void = null,
    repositioned: ?*const fn (?*anyopaque, *XdgPopup, u32) callconv(.c) void = null,
};

pub const XdgToplevelListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgToplevel, i32, i32, ?*anyopaque) callconv(.c) void = null,
    close: ?*const fn (?*anyopaque, *XdgToplevel) callconv(.c) void = null,
    configure_bounds: ?*const fn (?*anyopaque, *XdgToplevel, i32, i32) callconv(.c) void = null,
    wm_capabilities: ?*const fn (?*anyopaque, *XdgToplevel, ?*anyopaque) callconv(.c) void = null,
};

/// Client/server decoration negotiation (xdg-decoration-unstable-v1).
/// Opcodes and mode values verified against the protocol XML in
/// wayland-protocols 0.32 (also vendored under ~/.cargo).
pub const DecorationListener = extern struct {
    configure: ?*const fn (?*anyopaque, *Decoration, u32) callconv(.c) void = null,
};

/// §5G DPI: fractional-scale-v1 preferred_scale. Wire value is scale*120.
pub const FractionalScaleListener = extern struct {
    preferred_scale: ?*const fn (?*anyopaque, *anyopaque, u32) callconv(.c) void = null,
};

/// zwp_text_input_v3 is optional. Keep its wire description local so the
/// backend remains usable on compositors that do not advertise the global.
pub const TextInputListener = extern struct {
    // Surfaces are nullable: some compositors have been seen sending null here.
    enter: ?*const fn (?*anyopaque, *TextInput, ?*Surface) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *TextInput, ?*Surface) callconv(.c) void = null,
    preedit_string: ?*const fn (?*anyopaque, *TextInput, ?[*:0]const u8, i32, i32) callconv(.c) void = null,
    commit_string: ?*const fn (?*anyopaque, *TextInput, ?[*:0]const u8) callconv(.c) void = null,
    delete_surrounding_text: ?*const fn (?*anyopaque, *TextInput, u32, u32) callconv(.c) void = null,
    done: ?*const fn (?*anyopaque, *TextInput, u32) callconv(.c) void = null,
};

pub const DECOR_MODE_CLIENT_SIDE: u32 = 1;
pub const DECOR_MODE_SERVER_SIDE: u32 = 2;

/// xdg_toplevel.resize edge codes (protocol enum, NOT the _NET order —
/// see resizeEdgeCode for the mapping from ResizeEdge).
pub const XDG_RESIZE_NONE: u32 = 0;
pub const XDG_RESIZE_TOP: u32 = 1;
pub const XDG_RESIZE_BOTTOM: u32 = 2;
pub const XDG_RESIZE_LEFT: u32 = 4;
pub const XDG_RESIZE_TOP_LEFT: u32 = 5;
pub const XDG_RESIZE_BOTTOM_LEFT: u32 = 6;
pub const XDG_RESIZE_RIGHT: u32 = 8;
pub const XDG_RESIZE_TOP_RIGHT: u32 = 9;
pub const XDG_RESIZE_BOTTOM_RIGHT: u32 = 10;

/// xdg_toplevel.configure state 1 (verified against xdg-shell.xml).
pub const XDG_STATE_MAXIMIZED: u32 = 1;

/// wl_array header for the states array in configure events.
pub const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?[*]const u32,
};

pub const SeatListener = extern struct {
    capabilities: ?*const fn (?*anyopaque, *Seat, u32) callconv(.c) void = null,
    name: ?*const fn (?*anyopaque, *Seat, [*:0]const u8) callconv(.c) void = null,
};

/// Data-device (clipboard) protocol. Opcodes verified against
/// wayland-client-protocol.h; bound at version 1 so only v1 events exist.
pub const DataOfferListener = extern struct {
    offer: ?*const fn (?*anyopaque, *DataOffer, [*:0]const u8) callconv(.c) void = null,
    source_actions: ?*const fn (?*anyopaque, *DataOffer, u32) callconv(.c) void = null,
    action: ?*const fn (?*anyopaque, *DataOffer, u32) callconv(.c) void = null,
};

pub const DataSourceListener = extern struct {
    target: ?*const fn (?*anyopaque, *DataSource, ?[*:0]const u8) callconv(.c) void = null,
    send: ?*const fn (?*anyopaque, *DataSource, [*:0]const u8, i32) callconv(.c) void = null,
    cancelled: ?*const fn (?*anyopaque, *DataSource) callconv(.c) void = null,
    dnd_drop_performed: ?*const fn (?*anyopaque, *DataSource) callconv(.c) void = null,
    dnd_finished: ?*const fn (?*anyopaque, *DataSource) callconv(.c) void = null,
    action: ?*const fn (?*anyopaque, *DataSource, u32) callconv(.c) void = null,
};

pub const DataDeviceListener = extern struct {
    data_offer: ?*const fn (?*anyopaque, *DataDevice, *DataOffer) callconv(.c) void = null,
    enter: ?*const fn (?*anyopaque, *DataDevice, u32, *Surface, i32, i32, ?*DataOffer) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *DataDevice) callconv(.c) void = null,
    motion: ?*const fn (?*anyopaque, *DataDevice, u32, i32, i32) callconv(.c) void = null,
    drop: ?*const fn (?*anyopaque, *DataDevice) callconv(.c) void = null,
    selection: ?*const fn (?*anyopaque, *DataDevice, ?*DataOffer) callconv(.c) void = null,
};

pub const data_offer_events = [_]Message{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "source_actions", .signature = "3u", .types = null },
    .{ .name = "action", .signature = "3u", .types = null },
};
pub const data_offer_methods = [_]Message{
    .{ .name = "accept", .signature = "u?s", .types = null },
    .{ .name = "receive", .signature = "sh", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "finish", .signature = "3", .types = null },
    .{ .name = "set_actions", .signature = "3uu", .types = null },
};
pub const data_offer_interface: Interface = .{
    .name = "wl_data_offer",
    .version = 3,
    .method_count = 5,
    .methods = @ptrCast(&data_offer_methods),
    .event_count = 3,
    .events = @ptrCast(&data_offer_events),
};

pub const data_source_events = [_]Message{
    .{ .name = "target", .signature = "?s", .types = null },
    .{ .name = "send", .signature = "sh", .types = null },
    .{ .name = "cancelled", .signature = "", .types = null },
    .{ .name = "dnd_drop_performed", .signature = "3", .types = null },
    .{ .name = "dnd_finished", .signature = "3", .types = null },
    .{ .name = "action", .signature = "3u", .types = null },
};
pub const data_source_methods = [_]Message{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_actions", .signature = "3u", .types = null },
};
pub const data_source_interface: Interface = .{
    .name = "wl_data_source",
    .version = 3,
    .method_count = 3,
    .methods = @ptrCast(&data_source_methods),
    .event_count = 6,
    .events = @ptrCast(&data_source_events),
};

pub const data_device_events = [_]Message{
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
pub const data_device_methods = [_]Message{
    .{ .name = "start_drag", .signature = "?oo?ou", .types = null },
    .{ .name = "set_selection", .signature = "?ou", .types = null },
    .{ .name = "release", .signature = "2", .types = null },
};
pub const data_device_interface: Interface = .{
    .name = "wl_data_device",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&data_device_methods),
    .event_count = 6,
    .events = @ptrCast(&data_device_events),
};

// -- zwp_primary_selection_unstable_v1 ---------------------------------------

pub const PrimaryOfferListener = extern struct {
    offer: *const fn (?*anyopaque, *PrimaryOffer, [*:0]const u8) callconv(.c) void,
};
pub const PrimarySourceListener = extern struct {
    send: *const fn (?*anyopaque, *PrimarySource, [*:0]const u8, i32) callconv(.c) void,
    cancelled: *const fn (?*anyopaque, *PrimarySource) callconv(.c) void,
};
pub const PrimaryDeviceListener = extern struct {
    data_offer: *const fn (?*anyopaque, *PrimaryDevice, *PrimaryOffer) callconv(.c) void,
    selection: *const fn (?*anyopaque, *PrimaryDevice, ?*PrimaryOffer) callconv(.c) void,
};

pub const primary_offer_events = [_]Message{.{ .name = "offer", .signature = "s", .types = null }};
pub const primary_offer_methods = [_]Message{
    .{ .name = "receive", .signature = "sh", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
};
pub const primary_offer_interface: Interface = .{
    .name = "zwp_primary_selection_offer_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&primary_offer_methods),
    .event_count = 1,
    .events = @ptrCast(&primary_offer_events),
};
pub const primary_source_events = [_]Message{
    .{ .name = "send", .signature = "sh", .types = null },
    .{ .name = "cancelled", .signature = "", .types = null },
};
pub const primary_source_methods = [_]Message{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
};
pub const primary_source_interface: Interface = .{
    .name = "zwp_primary_selection_source_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&primary_source_methods),
    .event_count = 2,
    .events = @ptrCast(&primary_source_events),
};
pub const primary_device_events = [_]Message{
    .{ .name = "data_offer", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&primary_offer_interface)} },
    .{ .name = "selection", .signature = "?o", .types = &[_]?*const anyopaque{@ptrCast(&primary_offer_interface)} },
};
pub const primary_device_methods = [_]Message{
    .{ .name = "set_selection", .signature = "?ou", .types = &[_]?*const anyopaque{ @ptrCast(&primary_source_interface), null } },
    .{ .name = "destroy", .signature = "", .types = null },
};
pub const primary_device_interface: Interface = .{
    .name = "zwp_primary_selection_device_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&primary_device_methods),
    .event_count = 2,
    .events = @ptrCast(&primary_device_events),
};
pub const primary_device_manager_methods = [_]Message{
    .{ .name = "create_source", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&primary_source_interface)} },
    .{ .name = "get_device", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&primary_device_interface), null } },
    .{ .name = "destroy", .signature = "", .types = null },
};
pub const primary_device_manager_interface: Interface = .{
    .name = "zwp_primary_selection_device_manager_v1",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&primary_device_manager_methods),
    .event_count = 0,
    .events = null,
};

// -- zwp_pointer_gestures_v1 ---------------------------------------------------

pub const PointerGestures = opaque {};
pub const PointerGesturePinch = opaque {};
pub const PointerGesturePinchListener = extern struct {
    begin: *const fn (?*anyopaque, *PointerGesturePinch, u32, u32, ?*Surface, u32) callconv(.c) void,
    update: *const fn (?*anyopaque, *PointerGesturePinch, u32, i32, i32, i32, i32) callconv(.c) void,
    end: *const fn (?*anyopaque, *PointerGesturePinch, u32, u32, i32) callconv(.c) void,
};
pub const pointer_gesture_pinch_methods = [_]Message{.{ .name = "destroy", .signature = "", .types = null }};
pub const pointer_gesture_pinch_events = [_]Message{
    .{ .name = "begin", .signature = "uuou", .types = &[_]?*const anyopaque{ null, null, null, null } },
    .{ .name = "update", .signature = "uffff", .types = null },
    .{ .name = "end", .signature = "uui", .types = null },
};
pub const pointer_gesture_pinch_interface: Interface = .{
    .name = "zwp_pointer_gesture_pinch_v1",
    .version = 1,
    .method_count = 1,
    .methods = @ptrCast(&pointer_gesture_pinch_methods),
    .event_count = 3,
    .events = @ptrCast(&pointer_gesture_pinch_events),
};
pub const pointer_gestures_methods = [_]Message{
    .{ .name = "get_swipe_gesture", .signature = "no", .types = &[_]?*const anyopaque{ null, null } },
    .{ .name = "get_pinch_gesture", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&pointer_gesture_pinch_interface), null } },
};
pub const pointer_gestures_interface: Interface = .{
    .name = "zwp_pointer_gestures_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&pointer_gestures_methods),
    .event_count = 0,
    .events = null,
};

// -- xdg_system_bell_v1 -------------------------------------------------------

pub const SystemBell = opaque {};
pub const system_bell_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "ring", .signature = "?o", .types = &[_]?*const anyopaque{null} },
};
pub const system_bell_interface: Interface = .{
    .name = "xdg_system_bell_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&system_bell_methods),
    .event_count = 0,
    .events = null,
};

// -- wp_cursor_shape_v1 -------------------------------------------------------

pub const cursor_shape_device_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_shape", .signature = "uu", .types = null },
};
pub const cursor_shape_device_interface: Interface = .{
    .name = "wp_cursor_shape_device_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&cursor_shape_device_methods),
    .event_count = 0,
    .events = null,
};
pub const cursor_shape_manager_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_pointer", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&cursor_shape_device_interface), null } },
    .{ .name = "get_tablet_tool_v2", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&cursor_shape_device_interface), null } },
};
pub const cursor_shape_manager_interface: Interface = .{
    .name = "wp_cursor_shape_manager_v1",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&cursor_shape_manager_methods),
    .event_count = 0,
    .events = null,
};

pub const data_device_manager_methods = [_]Message{
    .{ .name = "create_data_source", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&data_source_interface)} },
    .{ .name = "get_data_device", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&data_device_interface), null } },
};
pub const data_device_manager_interface: Interface = .{
    .name = "wl_data_device_manager",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&data_device_manager_methods),
    .event_count = 0,
    .events = null,
};

/// Seat capability bits (wl_seat.capabilities).
pub const WL_SEAT_CAP_POINTER: u32 = 1;
pub const WL_SEAT_CAP_KEYBOARD: u32 = 2;

/// Linux button codes (from linux/input-event-codes.h).
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;
pub const BTN_FORWARD: u32 = 0x115;
pub const BTN_BACK: u32 = 0x116;

/// XKB modifier mask bits (also what wl_keyboard.modifiers reports).
pub const XKB_MOD_SHIFT: u32 = 1 << 0;

/// Keymap formats (wl_keyboard.keymap). We use evdev tables instead of
/// xkbcommon (same tradeoff as gooey's reference backend), so the fd is
/// closed immediately to avoid leaking one fd per keymap event.
pub const WL_KEYMAP_FORMAT_XKB_V1: u32 = 1;

pub fn wlFixedToFloat(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}

pub const KeyboardListener = extern struct {
    keymap: ?*const fn (?*anyopaque, *Keyboard, u32, i32, u32) callconv(.c) void = null,
    enter: ?*const fn (?*anyopaque, *Keyboard, u32, *Surface, ?*anyopaque) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *Keyboard, u32, *Surface) callconv(.c) void = null,
    key: ?*const fn (?*anyopaque, *Keyboard, u32, u32, u32, u32) callconv(.c) void = null,
    modifiers: ?*const fn (?*anyopaque, *Keyboard, u32, u32, u32, u32, u32) callconv(.c) void = null,
    repeat_info: ?*const fn (?*anyopaque, *Keyboard, i32, i32) callconv(.c) void = null,
};

pub const PointerListener = extern struct {
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
pub const xdg_surface_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};
pub const xdg_surface_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&xdg_toplevel_interface)} },
    // Types in argument order: the new xdg_popup, then the parent (nullable) and the positioner.
    .{ .name = "get_popup", .signature = "n?oo", .types = &[_]?*const anyopaque{ @ptrCast(&xdg_popup_interface), @ptrCast(&xdg_surface_interface), @ptrCast(&xdg_positioner_interface) } },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};
pub const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 7,
    .method_count = 5,
    .methods = @ptrCast(&xdg_surface_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_surface_events),
};

pub const xdg_toplevel_events = [_]Message{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "4ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "5a", .types = null },
};
pub const xdg_toplevel_methods = [_]Message{
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
    .{ .name = "set_fullscreen", .signature = "?o", .types = null },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};
pub const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 7,
    .method_count = 14,
    .methods = @ptrCast(&xdg_toplevel_methods),
    .event_count = 4,
    .events = @ptrCast(&xdg_toplevel_events),
};

// xdg_positioner (xdg-shell v7): the placement of a popup relative to its parent. Requests are
// numbered as the XML orders them; `set_reactive` and the parent-size requests are since v3.
pub const xdg_positioner_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_size", .signature = "ii", .types = null },
    .{ .name = "set_anchor_rect", .signature = "iiii", .types = null },
    .{ .name = "set_anchor", .signature = "u", .types = null },
    .{ .name = "set_gravity", .signature = "u", .types = null },
    .{ .name = "set_constraint_adjustment", .signature = "u", .types = null },
    .{ .name = "set_offset", .signature = "ii", .types = null },
    .{ .name = "set_reactive", .signature = "", .types = null },
    .{ .name = "set_parent_size", .signature = "ii", .types = null },
    .{ .name = "set_parent_configure", .signature = "u", .types = null },
};
pub const xdg_positioner_interface: Interface = .{
    .name = "xdg_positioner",
    .version = 7,
    .method_count = 10,
    .methods = @ptrCast(&xdg_positioner_methods),
    .event_count = 0,
    .events = null,
};

// xdg_popup (xdg-shell v7): `reposition` and `repositioned` are since v3.
pub const xdg_popup_events = [_]Message{
    .{ .name = "configure", .signature = "iiii", .types = null },
    .{ .name = "popup_done", .signature = "", .types = null },
    .{ .name = "repositioned", .signature = "u", .types = null },
};
pub const xdg_popup_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "grab", .signature = "ou", .types = null },
    .{ .name = "reposition", .signature = "ou", .types = null },
};
pub const xdg_popup_interface: Interface = .{
    .name = "xdg_popup",
    .version = 7,
    .method_count = 3,
    .methods = @ptrCast(&xdg_popup_methods),
    .event_count = 3,
    .events = @ptrCast(&xdg_popup_events),
};

pub const decoration_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};
pub const decoration_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_mode", .signature = "u", .types = null },
    .{ .name = "unset_mode", .signature = "", .types = null },
};
pub const decoration_interface: Interface = .{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&decoration_methods),
    .event_count = 1,
    .events = @ptrCast(&decoration_events),
};

pub const decoration_manager_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel_decoration", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&decoration_interface), null } },
};
pub const decoration_manager_interface: Interface = .{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&decoration_manager_methods),
    .event_count = 0,
    .events = null,
};

// §5G DPI: viewporter + fractional-scale-v1. With fractional scale the
// compositor scales the PHYSICAL buffer down to the logical destination
// rect, so the app rasterizes sharp at any fractional density.
pub const viewport_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_source", .signature = "ffff", .types = null },
    .{ .name = "set_destination", .signature = "ii", .types = null },
};
pub const viewport_interface: Interface = .{
    .name = "wp_viewport",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&viewport_methods),
    .event_count = 0,
    .events = null,
};

pub const viewporter_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_viewport", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&viewport_interface), null } },
};
pub const viewporter_interface: Interface = .{
    .name = "wp_viewporter",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&viewporter_methods),
    .event_count = 0,
    .events = null,
};

pub const fractional_scale_events = [_]Message{
    .{ .name = "preferred_scale", .signature = "u", .types = null },
};
pub const fractional_scale_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
};
pub const fractional_scale_interface: Interface = .{
    .name = "wp_fractional_scale_v1",
    .version = 1,
    .method_count = 1,
    .methods = @ptrCast(&fractional_scale_methods),
    .event_count = 1,
    .events = @ptrCast(&fractional_scale_events),
};

pub const fractional_scale_manager_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_fractional_scale", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&fractional_scale_interface), null } },
};
pub const fractional_scale_manager_interface: Interface = .{
    .name = "wp_fractional_scale_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&fractional_scale_manager_methods),
    .event_count = 0,
    .events = null,
};

pub const text_input_events = [_]Message{
    .{ .name = "enter", .signature = "o", .types = &[_]?*const anyopaque{null} },
    .{ .name = "leave", .signature = "o", .types = &[_]?*const anyopaque{null} },
    .{ .name = "preedit_string", .signature = "?sii", .types = null },
    .{ .name = "commit_string", .signature = "?s", .types = null },
    .{ .name = "delete_surrounding_text", .signature = "uu", .types = null },
    .{ .name = "done", .signature = "u", .types = null },
};
pub const text_input_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "enable", .signature = "", .types = null },
    .{ .name = "disable", .signature = "", .types = null },
    .{ .name = "set_surrounding_text", .signature = "sii", .types = null },
    .{ .name = "set_text_change_cause", .signature = "u", .types = null },
    .{ .name = "set_content_type", .signature = "uu", .types = null },
    .{ .name = "set_cursor_rectangle", .signature = "iiii", .types = null },
    .{ .name = "commit", .signature = "", .types = null },
};
pub const text_input_interface: Interface = .{
    .name = "zwp_text_input_v3",
    .version = 1,
    .method_count = 8,
    .methods = @ptrCast(&text_input_methods),
    .event_count = 6,
    .events = @ptrCast(&text_input_events),
};
pub const text_input_manager_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_text_input", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&text_input_interface), null } },
};
pub const text_input_manager_interface: Interface = .{
    .name = "zwp_text_input_manager_v3",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&text_input_manager_methods),
    .event_count = 0,
    .events = null,
};

pub const xdg_wm_base_events = [_]Message{
    .{ .name = "ping", .signature = "u", .types = null },
};
pub const xdg_wm_base_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    // A new_id argument needs its interface in `types`: libwayland reads it when marshalling, and
    // a null table segfaults (found live, on the first popup).
    .{ .name = "create_positioner", .signature = "n", .types = &[_]?*const anyopaque{@ptrCast(&xdg_positioner_interface)} },
    .{ .name = "get_xdg_surface", .signature = "no", .types = &[_]?*const anyopaque{ @ptrCast(&xdg_surface_interface), null } },
    .{ .name = "pong", .signature = "u", .types = null },
};
pub const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 7,
    .method_count = 4,
    .methods = @ptrCast(&xdg_wm_base_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_wm_base_events),
};

pub const WaylandApi = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    wl_display_disconnect: *const fn (*Display) callconv(.c) void,
    wl_display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    wl_display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    wl_display_flush: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_fd: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_error: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_protocol_error: *const fn (*Display, ?*?*const Interface, ?*u32) callconv(.c) u32,
    /// Debug-only; absent from some libwayland builds (1.22 exports wl_proxy_get_class instead).
    wl_proxy_get_interface: ?*const fn (*anyopaque) callconv(.c) ?*const Interface = null,
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

    pub fn load(lib: dl.Library) ?WaylandApi {
        return .{
            .wl_display_connect = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "wl_display_connect") orelse return null,
            .wl_display_disconnect = lib.lookup(*const fn (*Display) callconv(.c) void, "wl_display_disconnect") orelse return null,
            .wl_display_roundtrip = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_roundtrip") orelse return null,
            .wl_display_dispatch_pending = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_dispatch_pending") orelse return null,
            .wl_display_flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_flush") orelse return null,
            .wl_display_get_fd = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_get_fd") orelse return null,
            .wl_display_get_error = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_get_error") orelse return null,
            .wl_display_get_protocol_error = lib.lookup(*const fn (*Display, ?*?*const Interface, ?*u32) callconv(.c) u32, "wl_display_get_protocol_error") orelse return null,
            .wl_proxy_get_interface = lib.lookup(*const fn (*anyopaque) callconv(.c) ?*const Interface, "wl_proxy_get_interface"),
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
pub const CursorApi = struct {
    theme_load: *const fn (?[*:0]const u8, c_int, *Shm) callconv(.c) ?*CursorTheme,
    theme_destroy: *const fn (*CursorTheme) callconv(.c) void,
    theme_get_cursor: *const fn (*CursorTheme, [*:0]const u8) callconv(.c) ?*CursorHandle,
    image_get_buffer: *const fn (*CursorImage) callconv(.c) ?*Buffer,
    cursor_frame: *const fn (*CursorHandle, u32) callconv(.c) c_int,

    pub fn load(lib: dl.Library) ?CursorApi {
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
