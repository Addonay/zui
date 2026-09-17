//! X11 windowing and software presentation backend.
//!
//! Connects to an X11 server via dlopen'd libX11.so without compile-time headers.
//! Manages native window creation, event dispatch, and software frame presentation
//! via XPutImage.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const event = @import("../event.zig");
const evdev = @import("evdev.zig");
const geometry = @import("../../core/geometry.zig");
const limits = @import("../../core/limits.zig");
const zlog = @import("../../core/log.zig");
const gpu = @import("../../gpu/root.zig");
const dl = @import("../dl.zig");

// X11 Types
const Display = opaque {};
const Visual = opaque {};
const GC = ?*anyopaque;
const Window = c_ulong;
const Drawable = c_ulong;
const Atom = c_ulong;
const Bool = c_int;
const Status = c_int;
const Cursor = c_ulong;
const Time = c_ulong;

const XImage = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    data: ?[*]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    obdata: ?*anyopaque,
    f: extern struct {
        create_image: ?*anyopaque,
        destroy_image: *const fn (?*XImage) callconv(.c) c_int,
        get_pixel: ?*anyopaque,
        put_pixel: ?*anyopaque,
        sub_image: ?*anyopaque,
        add_pixel: ?*anyopaque,
    },
};

// Common X11 event types
const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const FocusIn: c_int = 9;
const FocusOut: c_int = 10;
const DestroyNotify: c_int = 17;
const ConfigureNotify: c_int = 22;
const ClientMessage: c_int = 33;

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: Bool,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]u8,
        s: [10]c_short,
        l: [5]c_long,
    },
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};

const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: Bool,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

const XSelectionRequestEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};

const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};

const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
};

/// Xlib's default error handler exits the process on any protocol error.
/// With multiple windows, an in-flight request racing an external destroy
/// (BadDrawable/BadWindow on XPutImage) would kill EVERY window. GTK/Qt
/// install a non-fatal handler: log, ignore, keep servicing the other
/// windows. Signature per Xlib.h (no XErrorEvent struct needed — we only
/// log the opcode and serial).
const XErrorHandler = ?*const fn (?*Display, ?*anyopaque) callconv(.c) c_int;

/// Non-fatal Xlib error hook installed at connection init. Returns 0
/// (error consumed): the failed request is dropped, the connection and all
/// other windows keep running. Per-error details would need the real
/// XErrorEvent struct; the opcode+serial log line covers diagnosis.
fn x11ErrorHandler(dpy: ?*Display, err: ?*anyopaque) callconv(.c) c_int {
    _ = dpy;
    _ = err;
    zlog.log("x11", "non-fatal X protocol error (request dropped)", .{});
    return 0;
}

const XEvent = extern union {
    type: c_int,
    xany: XAnyEvent,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    pad: [24]c_long,
};

// Static ABI pins, measured against /usr/include/X11/Xlib.h (see xoffsets
// probe): button/key/motion/client events have NO `event` field — only
// Configure and Any do. A phantom field here once shifted every tail field
// +8 (buttons read as garbage, XLookupString typed garbage), so these pins
// exist to catch exactly that class of mistake.
comptime {
    // Xlib pins below assume the LP64 Linux ABI (c_long is 64-bit). This
    // backend only ever runs on Linux, and foreign-target builds never
    // import this module (see platform/root.zig) — but guard the pins
    // anyway so a stray import fails safe instead of tripping a
    // target-invalid assertion (e.g. Windows LLP64 where c_long is 32-bit).
    if (builtin.target.os.tag == .linux) {
        std.debug.assert(@sizeOf(XEvent) == 192);
    std.debug.assert(@sizeOf(XButtonEvent) == 96);
    std.debug.assert(@offsetOf(XButtonEvent, "window") == 32);
    std.debug.assert(@offsetOf(XButtonEvent, "time") == 56);
    std.debug.assert(@offsetOf(XButtonEvent, "x") == 64);
    std.debug.assert(@offsetOf(XButtonEvent, "y") == 68);
    std.debug.assert(@offsetOf(XButtonEvent, "x_root") == 72);
    std.debug.assert(@offsetOf(XButtonEvent, "y_root") == 76);
    std.debug.assert(@offsetOf(XButtonEvent, "state") == 80);
    std.debug.assert(@offsetOf(XButtonEvent, "button") == 84);
    std.debug.assert(@offsetOf(XButtonEvent, "same_screen") == 88);
    std.debug.assert(@offsetOf(XKeyEvent, "keycode") == 84);
    std.debug.assert(@offsetOf(XKeyEvent, "state") == 80);
    std.debug.assert(@offsetOf(XKeyEvent, "time") == 56);
    std.debug.assert(@offsetOf(XMotionEvent, "x") == 64);
    std.debug.assert(@offsetOf(XMotionEvent, "state") == 80);
    std.debug.assert(@offsetOf(XClientMessageEvent, "window") == 32);
    std.debug.assert(@offsetOf(XClientMessageEvent, "data") == 56);
    std.debug.assert(@offsetOf(XConfigureEvent, "event") == 32);
    std.debug.assert(@offsetOf(XConfigureEvent, "window") == 40);
    std.debug.assert(@offsetOf(XConfigureEvent, "width") == 56);
    std.debug.assert(@offsetOf(XConfigureEvent, "height") == 60);
    // Selection request layout follows Xlib.h field order (sequential
    // native words after the standard 32-byte event prefix).
    std.debug.assert(@offsetOf(XSelectionRequestEvent, "requestor") == 40);
    std.debug.assert(@offsetOf(XSelectionRequestEvent, "selection") == 48);
    std.debug.assert(@offsetOf(XSelectionRequestEvent, "target") == 56);
    std.debug.assert(@offsetOf(XSelectionRequestEvent, "property") == 64);
    std.debug.assert(@offsetOf(XSelectionRequestEvent, "time") == 72);
    std.debug.assert(@sizeOf(XSelectionRequestEvent) == 80);
    }
}

// Selection protocol (verified against /usr/include/X11/X.h).
const SelectionClear: c_int = 29;
const SelectionRequest: c_int = 30;
const SelectionNotify: c_int = 31;

const XA_PRIMARY: Atom = 1;
const XA_ATOM: Atom = 4;
const XA_STRING: Atom = 31;
const XA_ANY_PROPERTY_TYPE: Atom = 0;
const PROP_MODE_REPLACE: c_int = 0;
const CURRENT_TIME: Time = 0;

// Cursor-font glyphs (verified against /usr/include/X11/cursorfont.h).
// No extra library: these live in libX11 itself.
const XC_LEFT_PTR: c_uint = 68;
const XC_XTERM: c_uint = 152;
const XC_HAND2: c_uint = 60;

// Event masks
const ExposureMask: c_long = 1 << 15;
const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const StructureNotifyMask: c_long = 1 << 17;
const FocusChangeMask: c_long = 1 << 21;

const X11Api = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultScreen: *const fn (*Display) callconv(.c) c_int,
    XRootWindow: *const fn (*Display, c_int) callconv(.c) Window,
    XCreateSimpleWindow: *const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window,
    XSelectInput: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    XMapWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XDestroyWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XStoreName: *const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, Bool) callconv(.c) Atom,
    XSetWMProtocols: *const fn (*Display, Window, [*]const Atom, c_int) callconv(.c) Status,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XDefaultGC: *const fn (*Display, c_int) callconv(.c) GC,
    XDefaultVisual: *const fn (*Display, c_int) callconv(.c) *Visual,
    XDefaultDepth: *const fn (*Display, c_int) callconv(.c) c_int,
    XCreateImage: *const fn (*Display, *Visual, c_uint, c_int, c_int, ?[*]u8, c_uint, c_uint, c_int, c_int) callconv(.c) ?*XImage,
    XDestroyImage: *const fn (*XImage) callconv(.c) c_int,
    XPutImage: *const fn (*Display, Drawable, GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) callconv(.c) c_int,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XLookupString: *const fn (*XKeyEvent, [*]u8, c_int, ?*c_ulong, ?*anyopaque) callconv(.c) c_int,
    XChangeProperty: *const fn (*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
    XDeleteProperty: *const fn (*Display, Window, Atom) callconv(.c) c_int,
    XGetWindowProperty: *const fn (*Display, Window, Atom, c_long, c_long, Bool, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *[*]u8) callconv(.c) c_int,
    XFree: *const fn (*anyopaque) callconv(.c) c_int,
    XConvertSelection: *const fn (*Display, Atom, Atom, Atom, Window, Time) callconv(.c) c_int,
    XSetSelectionOwner: *const fn (*Display, Atom, Window, Time) callconv(.c) c_int,
    XGetSelectionOwner: *const fn (*Display, Atom) callconv(.c) Window,
    XSendEvent: *const fn (*Display, Window, Bool, c_long, *XEvent) callconv(.c) Status,
    XCreateFontCursor: *const fn (*Display, c_uint) callconv(.c) Cursor,
    XDefineCursor: *const fn (*Display, Window, Cursor) callconv(.c) c_int,
    XFreeCursor: *const fn (*Display, Cursor) callconv(.c) c_int,
    XResizeWindow: *const fn (*Display, Window, c_uint, c_uint) callconv(.c) c_int,
    XIconifyWindow: *const fn (*Display, Window, c_int) callconv(.c) c_int,
    XSetErrorHandler: *const fn (XErrorHandler) callconv(.c) XErrorHandler,

    fn load(lib: dl.Library) ?X11Api {
        return .{
            .XOpenDisplay = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "XOpenDisplay") orelse return null,
            .XCloseDisplay = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XCloseDisplay") orelse return null,
            .XDefaultScreen = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XDefaultScreen") orelse return null,
            .XRootWindow = lib.lookup(*const fn (*Display, c_int) callconv(.c) Window, "XRootWindow") orelse return null,
            .XCreateSimpleWindow = lib.lookup(*const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window, "XCreateSimpleWindow") orelse return null,
            .XSelectInput = lib.lookup(*const fn (*Display, Window, c_long) callconv(.c) c_int, "XSelectInput") orelse return null,
            .XMapWindow = lib.lookup(*const fn (*Display, Window) callconv(.c) c_int, "XMapWindow") orelse return null,
            .XDestroyWindow = lib.lookup(*const fn (*Display, Window) callconv(.c) c_int, "XDestroyWindow") orelse return null,
            .XStoreName = lib.lookup(*const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int, "XStoreName") orelse return null,
            .XInternAtom = lib.lookup(*const fn (*Display, [*:0]const u8, Bool) callconv(.c) Atom, "XInternAtom") orelse return null,
            .XSetWMProtocols = lib.lookup(*const fn (*Display, Window, [*]const Atom, c_int) callconv(.c) Status, "XSetWMProtocols") orelse return null,
            .XPending = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XPending") orelse return null,
            .XNextEvent = lib.lookup(*const fn (*Display, *XEvent) callconv(.c) c_int, "XNextEvent") orelse return null,
            .XDefaultGC = lib.lookup(*const fn (*Display, c_int) callconv(.c) GC, "XDefaultGC") orelse return null,
            .XDefaultVisual = lib.lookup(*const fn (*Display, c_int) callconv(.c) *Visual, "XDefaultVisual") orelse return null,
            .XDefaultDepth = lib.lookup(*const fn (*Display, c_int) callconv(.c) c_int, "XDefaultDepth") orelse return null,
            .XCreateImage = lib.lookup(*const fn (*Display, *Visual, c_uint, c_int, c_int, ?[*]u8, c_uint, c_uint, c_int, c_int) callconv(.c) ?*XImage, "XCreateImage") orelse return null,
            .XDestroyImage = lib.lookup(*const fn (*XImage) callconv(.c) c_int, "XDestroyImage") orelse return null,
            .XPutImage = lib.lookup(*const fn (*Display, Drawable, GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) callconv(.c) c_int, "XPutImage") orelse return null,
            .XFlush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XFlush") orelse return null,
            .XConnectionNumber = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XConnectionNumber") orelse return null,
            .XLookupString = lib.lookup(*const fn (*XKeyEvent, [*]u8, c_int, ?*c_ulong, ?*anyopaque) callconv(.c) c_int, "XLookupString") orelse return null,
            .XChangeProperty = lib.lookup(*const fn (*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int, "XChangeProperty") orelse return null,
            .XDeleteProperty = lib.lookup(*const fn (*Display, Window, Atom) callconv(.c) c_int, "XDeleteProperty") orelse return null,
            .XGetWindowProperty = lib.lookup(*const fn (*Display, Window, Atom, c_long, c_long, Bool, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *[*]u8) callconv(.c) c_int, "XGetWindowProperty") orelse return null,
            .XFree = lib.lookup(*const fn (*anyopaque) callconv(.c) c_int, "XFree") orelse return null,
            .XConvertSelection = lib.lookup(*const fn (*Display, Atom, Atom, Atom, Window, Time) callconv(.c) c_int, "XConvertSelection") orelse return null,
            .XSetSelectionOwner = lib.lookup(*const fn (*Display, Atom, Window, Time) callconv(.c) c_int, "XSetSelectionOwner") orelse return null,
            .XGetSelectionOwner = lib.lookup(*const fn (*Display, Atom) callconv(.c) Window, "XGetSelectionOwner") orelse return null,
            .XSendEvent = lib.lookup(*const fn (*Display, Window, Bool, c_long, *XEvent) callconv(.c) Status, "XSendEvent") orelse return null,
            .XCreateFontCursor = lib.lookup(*const fn (*Display, c_uint) callconv(.c) Cursor, "XCreateFontCursor") orelse return null,
            .XDefineCursor = lib.lookup(*const fn (*Display, Window, Cursor) callconv(.c) c_int, "XDefineCursor") orelse return null,
            .XFreeCursor = lib.lookup(*const fn (*Display, Cursor) callconv(.c) c_int, "XFreeCursor") orelse return null,
            .XResizeWindow = lib.lookup(*const fn (*Display, Window, c_uint, c_uint) callconv(.c) c_int, "XResizeWindow") orelse return null,
            .XIconifyWindow = lib.lookup(*const fn (*Display, Window, c_int) callconv(.c) c_int, "XIconifyWindow") orelse return null,
            .XSetErrorHandler = lib.lookup(*const fn (XErrorHandler) callconv(.c) XErrorHandler, "XSetErrorHandler") orelse return null,
        };
    }
};

pub const X11Backend = struct {
    allocator: std.mem.Allocator,
    lib: dl.Library,
    api: X11Api,
    display: *Display,
    screen: c_int,
    window: Window,
    /// Connection role: primary window (App-level handle) or a secondary
    /// window-scoped handle sharing this connection. `windows` holds the
    /// secondary native windows keyed by connection slot.
    window_id: u32 = 0,
    parent: ?*X11Backend = null,
    windows: [limits.MAX_WINDOWS]?*X11Backend = @splat(null),
    /// The X server destroyed this window out from under us (an external
    /// XDestroyWindow, e.g. `xdotool windowclose`). Skip XDestroyWindow on
    /// teardown and stop presenting to the dead drawable.
    destroyed_by_server: bool = false,
    gc: GC,
    wm_delete_window: Atom,
    wm_protocols: Atom = 0,
    net_wm_ping: Atom = 0,
    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1.0,
    focused: bool = true,
    presents: u32 = 0,
    wakeups: u32 = 0,
    pixels: []u8,
    image: ?*XImage = null,
    /// Vellz-backed frame renderer, persistent across presents.
    renderer: gpu.vellz.Renderer,
    /// Gated `ZUI_DEBUG_EVENTS` input logging (read once at init).
    debug_events: bool = false,
    // Clipboard + selection state.
    atom_clipboard: Atom = 0,
    atom_utf8_string: Atom = 0,
    atom_targets: Atom = 0,
    atom_text: Atom = 0,
    atom_net_wm_name: Atom = 0,
    atom_incr: Atom = 0,
    atom_motif_hints: Atom = 0,
    atom_net_wm_state: Atom = 0,
    atom_net_wm_maximized_vert: Atom = 0,
    atom_net_wm_maximized_horz: Atom = 0,
    atom_net_wm_moveresize: Atom = 0,
    root: Window = 0,
    /// Last button press position, for move/resize drags.
    last_button: c_uint = 1,
    last_root_x: c_int = 0,
    last_root_y: c_int = 0,
    offered: [limits.MAX_CLIPBOARD_BYTES]u8 = std.mem.zeroes([limits.MAX_CLIPBOARD_BYTES]u8),
    offered_len: usize = 0,
    owning_selection: bool = false,
    paste_prop: Atom = 0,
    /// Raw server events that arrived during a synchronous paste pump;
    /// replayed through translateOne on the next poll.
    raw_stash: [64][192]u8 = std.mem.zeroes([64][192]u8),
    raw_stash_len: usize = 0,
    /// Cached font cursors indexed by CursorShape ordinal (0 = unset).
    cursors: [3]Cursor = .{ 0, 0, 0 },

    const vtable: backend.VTable = .{
        .createWindow = createWindowFn,
        .destroyWindow = destroyWindowFn,
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
        if (getenv("DISPLAY") == null) return false;
        var lib = dl.Library.open(&.{ "libX11.so.6", "libX11.so" }) orelse return false;
        defer lib.close();
        return X11Api.load(lib) != null;
    }

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !*X11Backend {
        if (!builtin.link_libc) return error.LibcNotLinked;
        if (getenv("DISPLAY") == null) return error.NoDisplay;

        const lib = dl.Library.open(&.{ "libX11.so.6", "libX11.so" }) orelse return error.LibraryNotFound;
        errdefer {
            var l = lib;
            l.close();
        }

        const api = X11Api.load(lib) orelse return error.MissingSymbols;

        const dpy = api.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        errdefer _ = api.XCloseDisplay(dpy);

        // Non-fatal protocol errors: Xlib's default handler exits the
        // process, which with multiple windows means one window racing an
        // external destroy kills them all.
        _ = api.XSetErrorHandler(x11ErrorHandler);

        const screen = api.XDefaultScreen(dpy);
        const root = api.XRootWindow(dpy, screen);
        const win = api.XCreateSimpleWindow(dpy, root, 0, 0, width, height, 0, 0, 0);
        errdefer _ = api.XDestroyWindow(dpy, win);

        _ = api.XStoreName(dpy, win, title);

        const atom_clipboard = api.XInternAtom(dpy, "CLIPBOARD", 0);
        const atom_utf8 = api.XInternAtom(dpy, "UTF8_STRING", 0);
        const atom_targets = api.XInternAtom(dpy, "TARGETS", 0);
        const atom_text = api.XInternAtom(dpy, "TEXT", 0);
        const atom_net_wm_name = api.XInternAtom(dpy, "_NET_WM_NAME", 0);
        const atom_incr = api.XInternAtom(dpy, "INCR", 0);
        const atom_motif_hints = api.XInternAtom(dpy, "_MOTIF_WM_HINTS", 0);
        const atom_net_wm_state = api.XInternAtom(dpy, "_NET_WM_STATE", 0);
        const atom_net_wm_maximized_vert = api.XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_VERT", 0);
        const atom_net_wm_maximized_horz = api.XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", 0);
        const atom_net_wm_moveresize = api.XInternAtom(dpy, "_NET_WM_MOVERESIZE", 0);
        // UTF-8 taskbar/window-list title alongside the Latin-1 XStoreName.
        _ = api.XChangeProperty(dpy, win, atom_net_wm_name, atom_utf8, 8, PROP_MODE_REPLACE, title, @intCast(std.mem.len(title)));

        const wm_protocols = api.XInternAtom(dpy, "WM_PROTOCOLS", 0);
        const wm_delete = api.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        const net_wm_ping = api.XInternAtom(dpy, "_NET_WM_PING", 0);
        // Advertise both close and ping: without _NET_WM_PING the window
        // manager gets no liveness reply and flags us "Not Responding".
        _ = api.XSetWMProtocols(dpy, win, &[2]Atom{ wm_delete, net_wm_ping }, 2);

        const mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask | FocusChangeMask;
        _ = api.XSelectInput(dpy, win, mask);

        const gc = api.XDefaultGC(dpy, screen);
        _ = api.XMapWindow(dpy, win);
        _ = api.XFlush(dpy);

        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

        // Set the App-supplied title on the first (primary) window, keeping
        // the uniform window-options path: connection struct carries id 0.
        _ = api.XStoreName(dpy, win, title);

        const self = try allocator.create(X11Backend);
        self.* = .{
            .allocator = allocator,
            .lib = lib,
            .api = api,
            .display = dpy,
            .screen = screen,
            .window = win,
            .gc = gc,
            .wm_delete_window = wm_delete,
            .wm_protocols = wm_protocols,
            .net_wm_ping = net_wm_ping,
            .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
            .scale_factor = 1.0,
            .focused = true,
            .presents = 0,
            .wakeups = 0,
            .pixels = pixels,
            .image = null,
            .renderer = gpu.vellz.Renderer.init(allocator),
            .debug_events = getenv("ZUI_DEBUG_EVENTS") != null,
            .window_id = 0,
            .atom_clipboard = atom_clipboard,
            .atom_utf8_string = atom_utf8,
            .atom_targets = atom_targets,
            .atom_text = atom_text,
            .atom_net_wm_name = atom_net_wm_name,
            .atom_incr = atom_incr,
            .atom_motif_hints = atom_motif_hints,
            .atom_net_wm_state = atom_net_wm_state,
            .atom_net_wm_maximized_vert = atom_net_wm_maximized_vert,
            .atom_net_wm_maximized_horz = atom_net_wm_maximized_horz,
            .atom_net_wm_moveresize = atom_net_wm_moveresize,
            .root = root,
            .paste_prop = api.XInternAtom(dpy, "ZUI_PASTE", 0),
        };

        self.recreateImage();
        return self;
    }

    pub fn deinit(self: *X11Backend) void {
        // Window-scoped children own their X windows and framebuffers;
        // destroy them before the connection goes away.
        for (&self.windows) |*slot| {
            if (slot.*) |child| {
                slot.* = null;
                child.teardownWindow();
            }
        }
        self.renderer.deinit();
        self.destroyImage();
        for (self.cursors) |c| {
            if (c != 0) _ = self.api.XFreeCursor(self.display, c);
        }
        self.allocator.free(self.pixels);
        // Primary window may also have been destroyed externally.
        if (!self.destroyed_by_server) {
            _ = self.api.XDestroyWindow(self.display, self.window);
        }
        _ = self.api.XCloseDisplay(self.display);
        self.lib.close();
        self.allocator.destroy(self);
    }

    pub fn backendHandle(self: *X11Backend) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Mint one more native window on this shared connection. The returned
    /// Backend is window-scoped: it owns its own X window, framebuffer,
    /// renderer, scale, focus, and input routing, but shares the display
    /// connection, atoms, cursors and clipboard selection with the
    /// primary. A null createWindow on other legacy backends keeps them
    /// single-window; X11 gets the full multi-window path.
    fn createWindowFn(ptr: *anyopaque, allocator: std.mem.Allocator, options: backend.WindowOptions) !backend.Backend {
        _ = allocator; // children reuse the connection's allocator
        const self: *X11Backend = @ptrCast(@alignCast(ptr));
        if (self.parent != null) return error.NotAConnection; // only the primary mints windows
        // First logical window adopts the init-created native window so the
        // connection never orphans its primary surface.
        if (self.window_id == 0) {
            self.window_id = options.id;
            const handle = self.backendHandle();
            handle.setTitle(options.title);
            handle.setDecorated(options.decorated);
            if (options.width != @as(u32, @intFromFloat(self.size.w)) or options.height != @as(u32, @intFromFloat(self.size.h))) {
                handle.setSize(options.width, options.height);
                self.size.w = @floatFromInt(options.width);
                self.size.h = @floatFromInt(options.height);
                const new_sz = @as(usize, options.width) * @as(usize, options.height) * 4;
                if (new_sz != self.pixels.len) {
                    if (self.allocator.realloc(self.pixels, new_sz)) |new_buf| {
                        self.pixels = new_buf;
                        self.recreateImage();
                    } else |_| {}
                }
            }
            return handle;
        }
        var slot: ?usize = null;
        for (&self.windows, 0..) |maybe, i| {
            if (maybe == null) {
                slot = i;
                break;
            }
        }
        const idx = slot orelse return error.TooManyWindows;
        const child = try createWindowOnConnection(self, options);
        self.windows[idx] = child;
        return child.backendHandle();
    }

    /// Shared creation path used by init (first window) and createWindowFn.
    /// Keeps window options (id/title/size/decorated) uniform for both.
    fn createWindowOnConnection(connection: *X11Backend, options: backend.WindowOptions) !*X11Backend {
        const api = connection.api;
        const dpy = connection.display;
        const win = api.XCreateSimpleWindow(dpy, connection.root, 0, 0, options.width, options.height, 0, 0, 0);
        errdefer _ = api.XDestroyWindow(dpy, win);
        // Latin-1 fallback title via stack buffer (titles are bounded by
        // WindowOptions), then the UTF-8 _NET_WM_NAME property.
        var zbuf: [256]u8 = undefined;
        const zlen = @min(options.title.len, zbuf.len - 1);
        @memcpy(zbuf[0..zlen], options.title[0..zlen]);
        zbuf[zlen] = 0;
        _ = api.XStoreName(dpy, win, @ptrCast(&zbuf));
        _ = api.XChangeProperty(dpy, win, connection.atom_net_wm_name, connection.atom_utf8_string, 8, PROP_MODE_REPLACE, options.title.ptr, @intCast(options.title.len));
        _ = api.XSetWMProtocols(dpy, win, &[2]Atom{ connection.wm_delete_window, connection.net_wm_ping }, 2);
        const mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask | FocusChangeMask;
        _ = api.XSelectInput(dpy, win, mask);
        _ = api.XMapWindow(dpy, win);
        _ = api.XFlush(dpy);
        errdefer _ = api.XDestroyWindow(dpy, win);

        const pixels = try connection.allocator.alloc(u8, @as(usize, options.width) * options.height * 4);
        errdefer connection.allocator.free(pixels);
        @memset(pixels, 0);

        const child = try connection.allocator.create(X11Backend);
        errdefer connection.allocator.destroy(child);
        child.* = .{
            .allocator = connection.allocator,
            .lib = connection.lib,
            .api = api,
            .display = dpy,
            .screen = connection.screen,
            .window = win,
            .gc = connection.gc,
            .wm_delete_window = connection.wm_delete_window,
            .wm_protocols = connection.wm_protocols,
            .net_wm_ping = connection.net_wm_ping,
            .size = .{ .w = @floatFromInt(options.width), .h = @floatFromInt(options.height) },
            .scale_factor = connection.scale_factor,
            .focused = false,
            .presents = 0,
            .wakeups = 0,
            .pixels = pixels,
            .image = null,
            .renderer = gpu.vellz.Renderer.init(connection.allocator),
            .debug_events = connection.debug_events,
            .window_id = options.id,
            .parent = connection,
            .atom_clipboard = connection.atom_clipboard,
            .atom_utf8_string = connection.atom_utf8_string,
            .atom_targets = connection.atom_targets,
            .atom_text = connection.atom_text,
            .atom_net_wm_name = connection.atom_net_wm_name,
            .atom_incr = connection.atom_incr,
            .atom_motif_hints = connection.atom_motif_hints,
            .atom_net_wm_state = connection.atom_net_wm_state,
            .atom_net_wm_maximized_vert = connection.atom_net_wm_maximized_vert,
            .atom_net_wm_maximized_horz = connection.atom_net_wm_maximized_horz,
            .atom_net_wm_moveresize = connection.atom_net_wm_moveresize,
            .root = connection.root,
            .paste_prop = connection.paste_prop,
        };
        child.recreateImage();
        return child;
    }

    /// Destroy a window-scoped handle. Never closes the shared connection.
    fn destroyWindowFn(ptr: *anyopaque) void {
        const self: *X11Backend = @ptrCast(@alignCast(ptr));
        const parent = self.parent orelse {
            // Adopted primary window: reap only the native window; the
            // renderer, framebuffer and connection are released once in
            // deinit (this handle IS the connection struct).
            if (!self.destroyed_by_server) {
                _ = self.api.XDestroyWindow(self.display, self.window);
            }
            self.destroyed_by_server = true;
            return;
        };
        for (&parent.windows) |*slot| {
            if (slot.* == self) {
                slot.* = null;
                break;
            }
        }
        self.teardownWindow();
    }

    /// Release per-window resources but keep the shared connection alive.
    fn teardownWindow(self: *X11Backend) void {
        self.renderer.deinit();
        self.destroyImage();
        self.allocator.free(self.pixels);
        // The server already destroyed this window (DestroyNotify): a
        // second XDestroyWindow would raise an async BadWindow error.
        if (!self.destroyed_by_server) {
            _ = self.api.XDestroyWindow(self.display, self.window);
        }
        self.allocator.destroy(self);
    }

    fn destroyImage(self: *X11Backend) void {
        if (self.image) |img| {
            img.data = null; // Do not let XDestroyImage free our allocator slice
            _ = self.api.XDestroyImage(img);
            self.image = null;
        }
    }

    fn recreateImage(self: *X11Backend) void {
        self.destroyImage();
        const vis = self.api.XDefaultVisual(self.display, self.screen);
        const depth = self.api.XDefaultDepth(self.display, self.screen);
        const w: c_uint = @intFromFloat(self.size.w);
        const h: c_uint = @intFromFloat(self.size.h);
        self.image = self.api.XCreateImage(self.display, vis, @intCast(depth), 2, 0, self.pixels.ptr, w, h, 32, 0);
    }

    fn kindFn(ptr: *anyopaque) backend.BackendKind {
        _ = ptr;
        return .x11;
    }

    fn pollFn(ptr: *anyopaque, out: *event.EventQueue) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        // Raw events stashed during a synchronous paste replay first so
        // input order survives the nested pump. Partial replay compacts.
        var ri: usize = 0;
        while (ri < self.raw_stash_len and out.len < limits.MAX_EVENTS_PER_FRAME) : (ri += 1) {
            const sev: XEvent = std.mem.bytesAsValue(XEvent, &self.raw_stash[ri]).*;
            self.translateOne(sev, out);
        }
        if (ri > 0) {
            var dst: usize = 0;
            while (ri + dst < self.raw_stash_len) : (dst += 1) {
                self.raw_stash[dst] = self.raw_stash[ri + dst];
            }
            self.raw_stash_len -= ri;
        }

        var ev: XEvent = undefined;
        while (self.api.XPending(self.display) > 0 and out.len < limits.MAX_EVENTS_PER_FRAME) {
            _ = self.api.XNextEvent(self.display, &ev);
            if (self.debug_events) {
                std.debug.print("x11 event type={d}\n", .{ev.type});
            }
            self.translateOne(ev, out);
        }
    }

    /// Translate one server event. Shared by poll and the synchronous
    /// paste pump (which stashes raw events for replay instead).
    /// Each event is tagged with its native window id (targeted envelope);
    /// per-window state (size, focus, framebuffer) is updated on the
    /// owning window-scoped handle before translation.
    fn translateOne(self: *@This(), ev: XEvent, out: *event.EventQueue) void {
        // Route by native window: the translated event is pushed as a
        // targeted envelope for its owning window handle. Foreign or
        // already-destroyed native ids are dropped, never misrouted.
        // Route by native window. ConfigureNotify (and friends with an
        // `event` field) carry the destination in `window` at a different
        // offset than XAnyEvent — read the union member matching the type.
        const native: Window = switch (ev.type) {
            ConfigureNotify => ev.xconfigure.window,
            else => ev.xany.window,
        };
        const owner: *X11Backend = self.lookupWindow(native) orelse return;
        switch (ev.type) {
            DestroyNotify => {
                // Someone else destroyed our window. Mark the handle dead,
                // skip our own XDestroyWindow in teardown, and surface a
                // normal close to the app so it reaps the logical window.
                owner.destroyed_by_server = true;
                owner.pushTargeted(out, .{ .window = .close_requested });
            },
            ClientMessage => {
                const client = ev.xclient;
                if (client.message_type == self.wm_protocols) {
                    if (client.data.l[0] == @as(c_long, @bitCast(self.net_wm_ping))) {
                        // WM liveness ping: echo it back to the root window
                        // or we get flagged "Not Responding".
                        zlog.log("x11", "ping -> pong", .{});
                        var reply = client;
                        reply.window = self.root;
                        var rev: XEvent = undefined;
                        @memset(std.mem.asBytes(&rev), 0);
                        @memcpy(std.mem.asBytes(&rev)[0..@sizeOf(XClientMessageEvent)], std.mem.asBytes(&reply));
                        const mask: c_long = (1 << 20) | (1 << 21); // SubstructureRedirect|Notify
                        _ = self.api.XSendEvent(self.display, self.root, 0, mask, &rev);
                        _ = self.api.XFlush(self.display);
                    } else if (client.data.l[0] == @as(c_long, @bitCast(self.wm_delete_window))) {
                        owner.pushTargeted(out, .{ .window = .close_requested });
                    }
                } else if (client.data.l[0] == @as(c_long, @bitCast(self.wm_delete_window))) {
                    owner.pushTargeted(out, .{ .window = .close_requested });
                }
            },
            ConfigureNotify => {
                const cfg = ev.xconfigure;
                const w = @as(f32, @floatFromInt(cfg.width));
                const h = @as(f32, @floatFromInt(cfg.height));
                if (w != owner.size.w or h != owner.size.h) {
                    owner.size.w = w;
                    owner.size.h = h;
                    const new_sz = @as(usize, @intCast(cfg.width)) * @as(usize, @intCast(cfg.height)) * 4;
                    if (new_sz != owner.pixels.len) {
                        if (owner.allocator.realloc(owner.pixels, new_sz)) |new_buf| {
                            owner.pixels = new_buf;
                            owner.recreateImage();
                        } else |_| {}
                    }
                    owner.pushTargeted(out, .{ .window = .resized });
                }
            },
            FocusIn => {
                owner.focused = true;
                owner.pushTargeted(out, .{ .window = .focused });
            },
            FocusOut => {
                owner.focused = false;
                owner.pushTargeted(out, .{ .window = .unfocused });
            },
            SelectionRequest => {
                var req: XSelectionRequestEvent = undefined;
                @memcpy(std.mem.asBytes(&req), std.mem.asBytes(&ev)[0..@sizeOf(XSelectionRequestEvent)]);
                self.serveSelection(req);
            },
            SelectionClear => {
                // Another client took CLIPBOARD; our offer is dead.
                self.owning_selection = false;
            },
            SelectionNotify => {}, // consumed by the paste pump; stray ones are noise
            ButtonPress, ButtonRelease => {
                const b = ev.xbutton;
                if (self.debug_events) {
                    std.debug.print("x11 button raw={d} time={d} pos={d},{d} pressed={}\n", .{ b.button, b.time, b.x, b.y, ev.type == ButtonPress });
                }
                // Remember the press for titlebar drags/resizes.
                if (ev.type == ButtonPress) {
                    self.last_button = b.button;
                    self.last_root_x = b.x_root;
                    self.last_root_y = b.y_root;
                }
                // Wheel buttons are scroll lines, never clicks: emitting
                // `.left` for them used to toggle checkboxes while
                // scrolling. Release halves of wheel pairs are silent.
                if (wheelScroll(b.button)) |delta| {
                    if (ev.type == ButtonPress) {
                        owner.pushTargeted(out, .{ .scroll = .{
                            .pos = .{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) },
                            .dx = delta.dx,
                            .dy = delta.dy,
                            .modifiers = evdev.modifiersFromMask(b.state),
                        } });
                    }
                    return;
                }
                const btn: event.MouseButton = switch (b.button) {
                    1 => .left,
                    2 => .middle,
                    3 => .right,
                    8 => .back,
                    9 => .forward,
                    else => return,
                };
                _ = out.push(.{
                    .mouse = .{
                        .pos = .{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) },
                        .button = btn,
                        .pressed = (ev.type == ButtonPress),
                        .modifiers = evdev.modifiersFromMask(b.state),
                        .time_ms = @intCast(b.time),
                    },
                });
            },
            MotionNotify => {
                const m = ev.xmotion;
                _ = out.push(.{
                    .mouse = .{
                        .pos = .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) },
                        .button = .left,
                        .pressed = false,
                        .motion = true,
                        .modifiers = evdev.modifiersFromMask(m.state),
                        .time_ms = @intCast(m.time),
                    },
                });
            },
            KeyPress, KeyRelease => {
                var k = ev.xkey;
                // X11 keycodes are evdev+8; guard cheap keyboards that
                // report below the offset.
                const mapped_key = if (k.keycode >= 8)
                    evdev.keyFromEvdev(k.keycode - 8)
                else
                    event.Key.unknown;
                if (self.debug_events) {
                    std.debug.print("x11 keycode={d} mapped={s} pressed={}\n", .{ k.keycode, @tagName(mapped_key), ev.type == KeyPress });
                }
                const mods = evdev.modifiersFromMask(k.state);
                _ = out.push(.{
                    .key = .{
                        .key = mapped_key,
                        .pressed = (ev.type == KeyPress),
                        .modifiers = mods,
                    },
                });
                // Printable text via the server keymap (shift-aware
                // capitals, digits, punctuation, UTF-8 locales). Press
                // only: releases carry no new text. A fuller XIC +
                // Xutf8LookupString path can replace this later.
                if (ev.type == KeyPress) {
                    var buf: [32]u8 = undefined;
                    const n = self.api.XLookupString(&k, &buf, buf.len, null, null);
                    if (n > 0) {
                        // Control characters (e.g. \r from Enter) are
                        // actions, not text — the .key event covers them.
                        const count: usize = @intCast(@min(n, 31));
                        var printable = true;
                        for (buf[0..count]) |byte| {
                            if (byte < 0x20 and byte != '\t') {
                                printable = false;
                                break;
                            }
                        }
                        if (printable) {
                            var text_ev = event.TextEvent{};
                            @memcpy(text_ev.text[0..count], buf[0..count]);
                            text_ev.len = @intCast(count);
                            _ = out.push(.{ .text = text_ev });
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// Map a native X window id to its owning backend handle, or null when
    /// the id belongs to a foreign or already-destroyed window (those are
    /// dropped instead of misrouted).
    fn lookupWindow(self: *X11Backend, native: Window) ?*X11Backend {
        if (native == self.window) return self;
        for (self.windows) |maybe| {
            if (maybe) |child| {
                if (child.window == native) return child;
            }
        }
        return null;
    }

    /// Push one translated event as a targeted envelope for this window.
    fn pushTargeted(owner: *X11Backend, out: *event.EventQueue, ev: event.EventPayload) void {
        _ = out.push(.{ .targeted = .{ .window_id = owner.window_id, .payload = ev } });
    }

    fn waitFn(ptr: *anyopaque, ns: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const fd = self.api.XConnectionNumber(self.display);
        var pfd = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ms: i32 = @intCast(@min(ns / 1_000_000, 1000));
        _ = std.posix.poll(&pfd, ms) catch 0;
        // Same idle-spin guard as the Wayland backend (see wayland.zig).
        _ = std.posix.poll(&.{}, 4) catch 0;
    }

    fn wakeupFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.wakeups += 1;
        _ = self.api.XFlush(self.display);
    }

    /// Wheel buttons → scroll lines. Pure for testability. Positive dy
    /// scrolls up, positive dx scrolls right.
    fn wheelScroll(button: c_uint) ?struct { dx: f32, dy: f32 } {
        return switch (button) {
            4 => .{ .dx = 0, .dy = 1 },
            5 => .{ .dx = 0, .dy = -1 },
            6 => .{ .dx = -1, .dy = 0 },
            7 => .{ .dx = 1, .dy = 0 },
            else => null,
        };
    }

    fn cursorGlyph(shape: backend.CursorShape) c_uint {
        return switch (shape) {
            .default => XC_LEFT_PTR,
            .text => XC_XTERM,
            .pointer => XC_HAND2,
        };
    }

    fn titleFn(ptr: *anyopaque, title: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var buf: [512]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        const ztitle: [*:0]const u8 = @ptrCast(&buf);
        _ = self.api.XStoreName(self.display, self.window, ztitle);
        _ = self.api.XChangeProperty(self.display, self.window, self.atom_net_wm_name, self.atom_utf8_string, 8, PROP_MODE_REPLACE, buf[0..n].ptr, @intCast(n));
        _ = self.api.XFlush(self.display);
    }

    fn cursorFn(ptr: *anyopaque, shape: backend.CursorShape) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const idx = @backingInt(shape);
        if (self.cursors[idx] == 0) {
            self.cursors[idx] = self.api.XCreateFontCursor(self.display, cursorGlyph(shape));
        }
        _ = self.api.XDefineCursor(self.display, self.window, self.cursors[idx]);
        _ = self.api.XFlush(self.display);
    }

    /// Ask the server to resize; the ConfigureNotify round-trip resizes
    /// our buffers and emits .resized like a user resize.
    fn sizeFn(ptr: *anyopaque, w: u32, h: u32) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (w == 0 or h == 0) return;
        _ = self.api.XResizeWindow(self.display, self.window, w, h);
        _ = self.api.XFlush(self.display);
    }

    /// Toggle server decorations through Motif hints (flags=2 selects the
    /// decorations field; 0 strips them for app-drawn chrome).
    fn decoratedFn(ptr: *anyopaque, decorated: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hints = [_]c_long{ 2, 0, if (decorated) 1 else 0, 0, 0 };
        _ = self.api.XChangeProperty(self.display, self.window, self.atom_motif_hints, self.atom_motif_hints, 32, PROP_MODE_REPLACE, @as([*]const u8, @ptrCast(&hints)), 5);
        _ = self.api.XFlush(self.display);
    }

    /// Forward a _NET_WM_MOVERESIZE client message to the root window.
    /// `action` 8 moves; 0-7 resize per ResizeEdge ordinals (shared).
    fn moveResize(self: *@This(), action: u32) void {
        var ev = std.mem.zeroes(XEvent);
        var msg = std.mem.zeroes(XClientMessageEvent);
        msg.type = ClientMessage;
        msg.display = self.display;
        msg.window = self.window;
        msg.message_type = self.atom_net_wm_moveresize;
        msg.format = 32;
        msg.data.l[0] = self.last_root_x;
        msg.data.l[1] = self.last_root_y;
        msg.data.l[2] = @intCast(action);
        msg.data.l[3] = @intCast(self.last_button);
        msg.data.l[4] = 1; // normal application source
        @memcpy(std.mem.asBytes(&ev)[0..@sizeOf(XClientMessageEvent)], std.mem.asBytes(&msg));
        // SubstructureNotify + SubstructureRedirect on the root window.
        const mask: c_long = (1 << 19) | (1 << 20);
        _ = self.api.XSendEvent(self.display, self.root, 0, mask, &ev);
        _ = self.api.XFlush(self.display);
    }

    fn dragFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.moveResize(8);
    }

    fn resizeFn(ptr: *anyopaque, edge: backend.ResizeEdge) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.moveResize(@backingInt(edge));
    }

    fn minimizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self.api.XIconifyWindow(self.display, self.window, 0);
        _ = self.api.XFlush(self.display);
    }

    /// Toggle maximized with the _NET_WM_STATE action=2 (toggle), so no
    /// local state tracking can drift from the WM.
    fn maximizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var ev = std.mem.zeroes(XEvent);
        var msg = std.mem.zeroes(XClientMessageEvent);
        msg.type = ClientMessage;
        msg.display = self.display;
        msg.window = self.window;
        msg.message_type = self.atom_net_wm_state;
        msg.format = 32;
        msg.data.l[0] = 2; // _NET_WM_STATE_TOGGLE
        msg.data.l[1] = @bitCast(self.atom_net_wm_maximized_vert);
        msg.data.l[2] = @bitCast(self.atom_net_wm_maximized_horz);
        @memcpy(std.mem.asBytes(&ev)[0..@sizeOf(XClientMessageEvent)], std.mem.asBytes(&msg));
        const mask: c_long = (1 << 19) | (1 << 20);
        _ = self.api.XSendEvent(self.display, self.root, 0, mask, &ev);
        _ = self.api.XFlush(self.display);
    }

    fn setClipboardFn(ptr: *anyopaque, text: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const n = @min(text.len, self.offered.len);
        @memcpy(self.offered[0..n], text[0..n]);
        self.offered_len = n;
        _ = self.api.XSetSelectionOwner(self.display, self.atom_clipboard, self.window, CURRENT_TIME);
        self.owning_selection = self.api.XGetSelectionOwner(self.display, self.atom_clipboard) == self.window;
        return self.owning_selection;
    }

    /// Answer a paste request for text we own. TARGETS advertises what we
    /// serve; anything else is refused with property=None.
    fn serveSelection(self: *@This(), req: XSelectionRequestEvent) void {
        if (req.selection != self.atom_clipboard or !self.owning_selection) return;
        var notify = std.mem.zeroes(XSelectionEvent);
        notify.type = SelectionNotify;
        notify.display = self.display;
        notify.requestor = req.requestor;
        notify.selection = req.selection;
        notify.target = req.target;
        notify.time = req.time;
        if (req.target == self.atom_targets) {
            const supported = [_]Atom{ self.atom_targets, self.atom_utf8_string, XA_STRING, self.atom_text };
            _ = self.api.XChangeProperty(self.display, req.requestor, req.property, XA_ATOM, 32, PROP_MODE_REPLACE, @as([*]const u8, @ptrCast(&supported)), 4);
            notify.property = req.property;
        } else if (req.target == self.atom_utf8_string or req.target == XA_STRING or req.target == self.atom_text) {
            _ = self.api.XChangeProperty(self.display, req.requestor, req.property, req.target, 8, PROP_MODE_REPLACE, self.offered[0..self.offered_len].ptr, @intCast(self.offered_len));
            notify.property = req.property;
        } else {
            notify.property = 0; // None: refuse conversions we don't do
        }
        var ev = std.mem.zeroes(XEvent);
        @memcpy(std.mem.asBytes(&ev)[0..@sizeOf(XSelectionEvent)], std.mem.asBytes(&notify));
        _ = self.api.XSendEvent(self.display, req.requestor, 0, 0, &ev);
        _ = self.api.XFlush(self.display);
    }

    /// Monotonic milliseconds for paste deadlines.
    fn nowMs() i64 {
        var ts = std.mem.zeroes(std.os.linux.timespec);
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
    }

    fn getClipboardFn(ptr: *anyopaque, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (out.len == 0) return 0;
        // Fast path: we own the selection, no round-trip needed.
        if (self.owning_selection) {
            const n = @min(self.offered_len, out.len);
            @memcpy(out[0..n], self.offered[0..n]);
            return n;
        }
        if (self.api.XGetSelectionOwner(self.display, self.atom_clipboard) == 0) return 0;
        _ = self.api.XConvertSelection(self.display, self.atom_clipboard, self.atom_utf8_string, self.paste_prop, self.window, CURRENT_TIME);
        _ = self.api.XFlush(self.display);

        // Nested pump: serve our own requests, stash everything else raw
        // for replay, stop at our SelectionNotify or a 500ms deadline.
        const deadline = nowMs() + 500;
        var ev: XEvent = undefined;
        while (nowMs() < deadline) {
            const fd = self.api.XConnectionNumber(self.display);
            var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&pfd, 25) catch 0;
            while (self.api.XPending(self.display) > 0) {
                _ = self.api.XNextEvent(self.display, &ev);
                if (ev.type == SelectionNotify) {
                    var note: XSelectionEvent = undefined;
                    @memcpy(std.mem.asBytes(&note), std.mem.asBytes(&ev)[0..@sizeOf(XSelectionEvent)]);
                    if (note.selection != self.atom_clipboard or note.property == 0) return 0;
                    return self.readPastedProperty(out);
                } else if (ev.type == SelectionRequest) {
                    var req: XSelectionRequestEvent = undefined;
                    @memcpy(std.mem.asBytes(&req), std.mem.asBytes(&ev)[0..@sizeOf(XSelectionRequestEvent)]);
                    self.serveSelection(req);
                } else if (ev.type == SelectionClear) {
                    self.owning_selection = false;
                } else if (self.raw_stash_len < self.raw_stash.len) {
                    @memcpy(&self.raw_stash[self.raw_stash_len], std.mem.asBytes(&ev));
                    self.raw_stash_len += 1;
                }
            }
        }
        return 0;
    }

    /// Read the converted paste property the owner just wrote us. INCR
    /// (chunked) transfers are refused by returning zero — our cap keeps
    /// offers small and requestors fall back gracefully.
    fn readPastedProperty(self: *@This(), out: []u8) usize {
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*]u8 = undefined;
        const want_longs: c_long = @intCast((out.len + 3) / 4);
        const rc = self.api.XGetWindowProperty(self.display, self.window, self.paste_prop, 0, want_longs, 0, XA_ANY_PROPERTY_TYPE, &actual_type, &actual_format, &nitems, &bytes_after, &prop);
        _ = self.api.XDeleteProperty(self.display, self.window, self.paste_prop);
        if (rc != 0 or actual_format != 8) return 0;
        // INCR atom signals chunked transfer, which we decline.
        if (actual_type == self.atom_incr) {
            _ = self.api.XFree(prop);
            return 0;
        }
        const n = @min(@as(usize, @intCast(nitems)), out.len);
        @memcpy(out[0..n], prop[0..n]);
        _ = self.api.XFree(prop);
        return n;
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

        // Default fashion dark background (theme.bg = #0e0e13)
        self.renderer.render(self.pixels, w, h, .bgra32, gpu.vellz.Color.hex(0x0e0e13), scene, glyph_pixels, image_pixels) catch |err| {
            zlog.log("x11", "vellz render failed: {s}", .{@errorName(err)});
            return;
        };

        if (self.destroyed_by_server) return;
        if (self.image) |img| {
            _ = self.api.XPutImage(self.display, self.window, self.gc, img, 0, 0, 0, 0, w, h);
            _ = self.api.XFlush(self.display);
        }
        self.presents += 1;
        // Connection-level total: window-scoped presents aggregate upward
        // (same policy as the null backend) so App diagnostics observe one
        // counter.
        if (self.parent) |parent| parent.presents += 1;
    }
};

test "x11 availability and creation" {
    if (!X11Backend.isAvailable()) return;

    var b = X11Backend.init(std.testing.allocator, "ZUI X11 Test", 200, 150) catch |err| switch (err) {
        error.CannotOpenDisplay => return,
        else => return err,
    };
    defer b.deinit();

    const handle = b.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.x11, handle.kind());
    try std.testing.expectEqual(@as(f32, 200), handle.windowInfo().size.w);
    try std.testing.expectEqual(@as(f32, 150), handle.windowInfo().size.h);

    var sc = gpu.Scene{};
    _ = sc.push(.{ .x = 10, .y = 10, .w = 80, .h = 80, .color = gpu.vellz.Color.hex(0xFF0000) });
    handle.present(&sc, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), b.presents);
}

test "x11 wheel buttons map to scroll lines" {
    try std.testing.expectEqual(@as(f32, 1), X11Backend.wheelScroll(4).?.dy);
    try std.testing.expectEqual(@as(f32, -1), X11Backend.wheelScroll(5).?.dy);
    try std.testing.expectEqual(@as(f32, -1), X11Backend.wheelScroll(6).?.dx);
    try std.testing.expectEqual(@as(f32, 1), X11Backend.wheelScroll(7).?.dx);
    try std.testing.expect(X11Backend.wheelScroll(1) == null);
    try std.testing.expect(X11Backend.wheelScroll(8) == null);
}

test "x11 cursor shapes use verified font glyphs" {
    try std.testing.expectEqual(@as(c_uint, 68), X11Backend.cursorGlyph(.default));
    try std.testing.expectEqual(@as(c_uint, 152), X11Backend.cursorGlyph(.text));
    try std.testing.expectEqual(@as(c_uint, 60), X11Backend.cursorGlyph(.pointer));
}

test "x11 selection protocol constants match X.h" {
    try std.testing.expectEqual(@as(c_int, 29), SelectionClear);
    try std.testing.expectEqual(@as(c_int, 30), SelectionRequest);
    try std.testing.expectEqual(@as(c_int, 31), SelectionNotify);
    try std.testing.expectEqual(@as(Atom, 1), XA_PRIMARY);
    try std.testing.expectEqual(@as(Atom, 4), XA_ATOM);
    try std.testing.expectEqual(@as(Atom, 31), XA_STRING);
    try std.testing.expectEqual(@as(c_int, 0), PROP_MODE_REPLACE);
}

test "x11 multiwindow: two native windows with independent state and routing" {
    if (!X11Backend.isAvailable()) return;
    const t = std.testing;
    var b = X11Backend.init(t.allocator, "ZUI X11 Multi", 240, 160) catch |err| switch (err) {
        error.CannotOpenDisplay => return,
        else => return err,
    };
    defer b.deinit();
    const conn = b.backendHandle();

    // The init-created window becomes the first logical window (adopted in
    // place); the second createWindow mints a fresh native window on the
    // shared connection.
    const w1 = try conn.createWindow(t.allocator, .{ .id = 7, .title = "One", .width = 200, .height = 120, .decorated = true });
    const w2 = try conn.createWindow(t.allocator, .{ .id = 9, .title = "Two", .width = 300, .height = 180, .decorated = false });

    try t.expect(w1.ptr == conn.ptr); // primary window handle is the connection struct
    try t.expect(w2.ptr != conn.ptr);
    try t.expectEqual(backend.BackendKind.x11, w1.kind());
    try t.expectEqual(backend.BackendKind.x11, w2.kind());
    try t.expectEqual(@as(u32, 7), b.window_id);
    try t.expectEqual(@as(u32, 9), b.windows[0].?.window_id);
    try t.expect(b.windows[0].?.display == b.display);
    try t.expectEqual(@as(f32, 200), w1.windowInfo().size.w);
    try t.expectEqual(@as(f32, 300), w2.windowInfo().size.w);
    try t.expectEqual(@as(f32, 120), w1.windowInfo().size.h);
    try t.expectEqual(@as(f32, 180), w2.windowInfo().size.h);

    // Per-window framebuffers: distinct pixel pools, independent presents.
    var sc = gpu.Scene{};
    _ = sc.push(.{ .x = 0, .y = 0, .w = 5, .h = 5, .color = gpu.vellz.Color.hex(0xFF0000) });
    w1.present(&sc, &.{}, &.{});
    try t.expectEqual(@as(u32, 1), b.presents);
    try t.expectEqual(@as(u32, 0), b.windows[0].?.presents);
    w2.present(&sc, &.{}, &.{});
    try t.expectEqual(@as(u32, 2), b.presents);
    try t.expectEqual(@as(u32, 1), b.windows[0].?.presents);

    // Event routing by native window: a synthetic ConfigureNotify for w2
    // emits exactly one targeted resize for window 9 and resizes only w2.
    var q = event.EventQueue{};
    var cfg = std.mem.zeroes(XEvent);
    cfg.type = ConfigureNotify;
    cfg.xconfigure.window = b.windows[0].?.window;
    cfg.xconfigure.width = 333;
    cfg.xconfigure.height = 222;
    b.translateOne(cfg, &q);
    try t.expectEqual(@as(usize, 1), q.len);
    const routed = q.pop().?;
    try t.expectEqual(@as(u32, 9), routed.targetWindowId().?);
    try t.expectEqual(@as(f32, 333), w2.windowInfo().size.w);
    try t.expectEqual(@as(f32, 200), w1.windowInfo().size.w);

    // Destroying w2 leaves w1 fully alive and frees the slot.
    w2.destroyWindow();
    try t.expect(b.windows[0] == null);
    try t.expectEqual(@as(f32, 200), w1.windowInfo().size.w);
    // The id can be reused by a later createWindow.
    const w3 = try conn.createWindow(t.allocator, .{ .id = 9, .title = "Again", .width = 100, .height = 90, .decorated = true });
    try t.expect(b.windows[0] != null);
    try t.expectEqual(@as(u32, 9), b.windows[0].?.window_id);
    w3.destroyWindow();
    try t.expect(b.windows[0] == null);
}

test "x11 repeated open/close cycles leave no ghost windows or leaks" {
    if (!X11Backend.isAvailable()) return;
    const t = std.testing;
    var b = X11Backend.init(t.allocator, "ZUI X11 Cycle", 200, 150) catch |err| switch (err) {
        error.CannotOpenDisplay => return,
        else => return err,
    };
    defer b.deinit();
    const conn = b.backendHandle();

    // Cycle: adopt primary (id 1), mint a second (id 2), destroy the
    // primary, mint a replacement on the same connection struct, destroy
    // both. Each round-trip must free every native window it created.
    const p1 = try conn.createWindow(t.allocator, .{ .id = 1, .title = "Cycle A", .width = 160, .height = 120, .decorated = true });
    const c1 = try conn.createWindow(t.allocator, .{ .id = 2, .title = "Cycle B", .width = 120, .height = 90, .decorated = true });
    try t.expect(b.windows[0] != null);
    try t.expectEqual(@as(u32, 1), b.window_id); // primary adopted id 1

    p1.destroyWindow(); // adopted primary: native window reaped in place
    try t.expectEqual(@as(f32, 120), c1.windowInfo().size.w);

    // The primary slot is spent after its first adoption: later windows are
    // always fresh children (App renders each through its own handle, so
    // the connection's own window fields are never presented again).
    const p2 = try conn.createWindow(t.allocator, .{ .id = 3, .title = "Cycle C", .width = 100, .height = 80, .decorated = true });
    try t.expect(p2.ptr != conn.ptr);
    try t.expectEqual(@as(f32, 100), p2.windowInfo().size.w);
    c1.destroyWindow();
    p2.destroyWindow();
    for (b.windows) |slot| try t.expect(slot == null);
    try t.expect(b.destroyed_by_server); // adopted-primary destroy marked it
}
test "x11 external destroy surfaces close and skips native teardown" {
    if (!X11Backend.isAvailable()) return;
    const t = std.testing;
    var b = X11Backend.init(t.allocator, "ZUI X11 Ext", 200, 150) catch |err| switch (err) {
        error.CannotOpenDisplay => return,
        else => return err,
    };
    defer b.deinit();
    const conn = b.backendHandle();
    // First createWindow adopts the primary init-created window.
    const w2 = try conn.createWindow(t.allocator, .{ .id = 5, .title = "Victim", .width = 120, .height = 90, .decorated = true });
    const victim: *X11Backend = @ptrCast(@alignCast(w2.ptr));
    try t.expectEqual(@as(u32, 5), victim.window_id);

    // Simulate the server destroying the window behind our back (external
    // XDestroyWindow): DestroyNotify must (1) mark the handle dead, (2)
    // emit a targeted close for the app, and (3) make present a no-op so
    // no X_PutImage reaches the dead drawable.
    var q = event.EventQueue{};
    var dn = std.mem.zeroes(XEvent);
    dn.type = DestroyNotify;
    dn.xany.window = victim.window;
    b.translateOne(dn, &q);
    try t.expectEqual(@as(usize, 1), q.len);
    const closed = q.pop().?;
    try t.expectEqual(@as(u32, 5), closed.targetWindowId().?);
    try t.expect(closed.untargeted() == .window and closed.untargeted().window == .close_requested);
    try t.expect(victim.destroyed_by_server);
    // Presenting to the dead drawable must be a silent no-op (no crash,
    // no counter): the guard runs before any X request is queued.
    var sc = gpu.Scene{};
    _ = sc.push(.{ .x = 0, .y = 0, .w = 4, .h = 4, .color = gpu.vellz.Color.hex(0x00FF00) });
    w2.present(&sc, &.{}, &.{});
    try t.expectEqual(@as(u32, 0), victim.presents);

    // Reaping through destroyWindow must NOT call XDestroyWindow again
    // (would be an async BadWindow); the adopted primary handle survives
    // (it is the connection struct itself) with the flag still set.
    w2.destroyWindow();
    try t.expect(victim.destroyed_by_server);
}
