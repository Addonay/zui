//! Xlib protocol layer: libX11 loaded with dlopen. Event and XImage layouts
//! follow Xlib.h (checked by the comptime pins below). Nothing links against
//! libX11 at build time.

pub const std = @import("std");
pub const builtin = @import("builtin");
pub const dl = @import("dl.zig");

pub const Display = opaque {};
pub const Visual = opaque {};
pub const GC = ?*anyopaque;
pub const Window = c_ulong;
pub const Drawable = c_ulong;
pub const Atom = c_ulong;
pub const Bool = c_int;
pub const Status = c_int;
pub const Cursor = c_ulong;
pub const Time = c_ulong;
pub const XPointer = ?*anyopaque;

pub const XImage = extern struct {
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
pub const KeyPress: c_int = 2;
pub const KeyRelease: c_int = 3;
pub const ButtonPress: c_int = 4;
pub const ButtonRelease: c_int = 5;
pub const MotionNotify: c_int = 6;
pub const FocusIn: c_int = 9;
pub const FocusOut: c_int = 10;
pub const DestroyNotify: c_int = 17;
pub const ConfigureNotify: c_int = 22;
pub const ClientMessage: c_int = 33;

pub const XConfigureEvent = extern struct {
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

pub const XClientMessageEvent = extern struct {
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

pub const XButtonEvent = extern struct {
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

pub const XMotionEvent = extern struct {
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

pub const XKeyEvent = extern struct {
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

pub const XSelectionRequestEvent = extern struct {
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

pub const XSelectionEvent = extern struct {
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

pub const XAnyEvent = extern struct {
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
pub const XErrorHandler = ?*const fn (?*Display, ?*anyopaque) callconv(.c) c_int;

/// §5G scale acquisition: shared contract in `backend.envScaleFactor`
pub const XEvent = extern union {
    type: c_int,
    xany: XAnyEvent,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    xcrossing: XCrossingEvent,
    xexpose: XExposeEvent,
    xselection: XSelectionEvent,
    xselectionrequest: XSelectionRequestEvent,
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
pub const SelectionClear: c_int = 29;
pub const SelectionRequest: c_int = 30;
pub const SelectionNotify: c_int = 31;

pub const XA_PRIMARY: Atom = 1;
pub const XA_ATOM: Atom = 4;
pub const XA_STRING: Atom = 31;
pub const XA_ANY_PROPERTY_TYPE: Atom = 0;
pub const PROP_MODE_REPLACE: c_int = 0;
pub const CURRENT_TIME: Time = 0;

// Cursor-font glyphs (verified against /usr/include/X11/cursorfont.h).
// No extra library: these live in libX11 itself.
pub const XC_LEFT_PTR: c_uint = 68;
pub const XC_XTERM: c_uint = 152;
pub const XC_HAND2: c_uint = 60;

// Event masks
pub const ExposureMask: c_long = 1 << 15;
pub const KeyPressMask: c_long = 1 << 0;
pub const KeyReleaseMask: c_long = 1 << 1;
pub const ButtonPressMask: c_long = 1 << 2;
pub const ButtonReleaseMask: c_long = 1 << 3;
pub const PointerMotionMask: c_long = 1 << 6;
pub const StructureNotifyMask: c_long = 1 << 17;
pub const FocusChangeMask: c_long = 1 << 21;

pub const Expose: c_int = 12;
pub const ZPixmap: c_int = 2;

pub const XExposeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    count: c_int,
};

pub const EnterNotify: c_int = 7;
pub const LeaveNotify: c_int = 8;
pub const EnterWindowMask: c_long = 1 << 4;
pub const LeaveWindowMask: c_long = 1 << 5;
pub const SubstructureRedirectMask: c_long = 1 << 20;
pub const SubstructureNotifyMask: c_long = 1 << 19;

pub const XCrossingEvent = extern struct {
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
    mode: c_int,
    detail: c_int,
    same_screen: Bool,
    focus: Bool,
    state: c_uint,
};

pub const XC_X_cursor: c_uint = 0;
pub const XC_crosshair: c_uint = 34;
pub const XC_hand1: c_uint = 58;
pub const XC_hand2: c_uint = 60;
pub const XC_left_ptr: c_uint = 68;
pub const XC_xterm: c_uint = 152;
pub const XC_fleur: c_uint = 52;
pub const XC_sb_h_double_arrow: c_uint = 108;
pub const XC_sb_v_double_arrow: c_uint = 116;
pub const XC_top_left_corner: c_uint = 134;
pub const XC_top_right_corner: c_uint = 136;
pub const XC_bottom_left_corner: c_uint = 12;
pub const XC_bottom_right_corner: c_uint = 14;
pub const XC_left_side: c_uint = 70;
pub const XC_right_side: c_uint = 96;
pub const XC_top_side: c_uint = 138;
pub const XC_bottom_side: c_uint = 16;

pub const Api = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultScreen: *const fn (*Display) callconv(.c) c_int,
    XRootWindow: *const fn (*Display, c_int) callconv(.c) Window,
    XDisplayWidth: *const fn (*Display, c_int) callconv(.c) c_int,
    XDisplayHeight: *const fn (*Display, c_int) callconv(.c) c_int,
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
    XSync: *const fn (*Display, Bool) callconv(.c) c_int,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XLookupString: *const fn (*XKeyEvent, [*]u8, c_int, ?*c_ulong, ?*anyopaque) callconv(.c) c_int,
    XKeycodeToKeysym: ?*const fn (*Display, c_uint, c_int) callconv(.c) c_ulong = null,
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
    XResourceManagerString: ?*const fn (*Display) callconv(.c) ?[*:0]const u8 = null,
    XGetInputFocus: ?*const fn (*Display, *Window, *c_int) callconv(.c) c_int = null,

    pub fn load(lib: dl.Library) ?Api {
        return .{
            .XOpenDisplay = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "XOpenDisplay") orelse return null,
            .XCloseDisplay = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XCloseDisplay") orelse return null,
            .XDefaultScreen = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XDefaultScreen") orelse return null,
            .XRootWindow = lib.lookup(*const fn (*Display, c_int) callconv(.c) Window, "XRootWindow") orelse return null,
            .XDisplayWidth = lib.lookup(*const fn (*Display, c_int) callconv(.c) c_int, "XDisplayWidth") orelse return null,
            .XDisplayHeight = lib.lookup(*const fn (*Display, c_int) callconv(.c) c_int, "XDisplayHeight") orelse return null,
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
            .XSync = lib.lookup(*const fn (*Display, Bool) callconv(.c) c_int, "XSync") orelse return null,
            .XConnectionNumber = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XConnectionNumber") orelse return null,
            .XLookupString = lib.lookup(*const fn (*XKeyEvent, [*]u8, c_int, ?*c_ulong, ?*anyopaque) callconv(.c) c_int, "XLookupString") orelse return null,
            .XKeycodeToKeysym = lib.lookup(*const fn (*Display, c_uint, c_int) callconv(.c) c_ulong, "XKeycodeToKeysym"),
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
            .XResourceManagerString = lib.lookup(*const fn (*Display) callconv(.c) ?[*:0]const u8, "XResourceManagerString"),
            .XGetInputFocus = lib.lookup(*const fn (*Display, *Window, *c_int) callconv(.c) c_int, "XGetInputFocus"),
        };
    }
};
