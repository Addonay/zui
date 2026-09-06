//! X11 windowing and software presentation backend.
//!
//! Connects to an X11 server via dlopen'd libX11.so without compile-time headers.
//! Manages native window creation, event dispatch, and software frame presentation
//! via XPutImage.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const event = @import("event.zig");
const geometry = @import("../core/geometry.zig");
const gpu = @import("../gpu/root.zig");
const dl = @import("dl.zig");

// X11 Types
const Display = opaque {};
const Visual = opaque {};
const GC = ?*anyopaque;
const Window = c_ulong;
const Drawable = c_ulong;
const Atom = c_ulong;
const Bool = c_int;
const Status = c_int;

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
    event: Window,
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
    event: Window,
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
    event: Window,
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
    event: Window,
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

const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
};

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
    gc: GC,
    wm_delete_window: Atom,
    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1.0,
    focused: bool = true,
    presents: u32 = 0,
    wakeups: u32 = 0,
    pixels: []u8,
    image: ?*XImage = null,

    const vtable: backend.VTable = .{
        .kind = kindFn,
        .poll = pollFn,
        .waitTimeoutNs = waitFn,
        .wakeup = wakeupFn,
        .windowInfo = infoFn,
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

        const screen = api.XDefaultScreen(dpy);
        const root = api.XRootWindow(dpy, screen);
        const win = api.XCreateSimpleWindow(dpy, root, 0, 0, width, height, 0, 0, 0);
        errdefer _ = api.XDestroyWindow(dpy, win);

        _ = api.XStoreName(dpy, win, title);

        const wm_protocols = api.XInternAtom(dpy, "WM_PROTOCOLS", 0);
        const wm_delete = api.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = wm_protocols;
        _ = api.XSetWMProtocols(dpy, win, &[1]Atom{wm_delete}, 1);

        const mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask | FocusChangeMask;
        _ = api.XSelectInput(dpy, win, mask);

        const gc = api.XDefaultGC(dpy, screen);
        _ = api.XMapWindow(dpy, win);
        _ = api.XFlush(dpy);

        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

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
            .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
            .scale_factor = 1.0,
            .focused = true,
            .presents = 0,
            .wakeups = 0,
            .pixels = pixels,
            .image = null,
        };

        self.recreateImage();
        return self;
    }

    pub fn deinit(self: *X11Backend) void {
        self.destroyImage();
        self.allocator.free(self.pixels);
        _ = self.api.XDestroyWindow(self.display, self.window);
        _ = self.api.XCloseDisplay(self.display);
        self.lib.close();
        self.allocator.destroy(self);
    }

    pub fn backendHandle(self: *X11Backend) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
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
        var ev: XEvent = undefined;

        while (self.api.XPending(self.display) > 0) {
            _ = self.api.XNextEvent(self.display, &ev);
            switch (ev.type) {
                ClientMessage => {
                    const client = ev.xclient;
                    if (client.data.l[0] == @as(c_long, @bitCast(self.wm_delete_window))) {
                        _ = out.push(.{ .window = .close_requested });
                    }
                },
                ConfigureNotify => {
                    const cfg = ev.xconfigure;
                    const w = @as(f32, @floatFromInt(cfg.width));
                    const h = @as(f32, @floatFromInt(cfg.height));
                    if (w != self.size.w or h != self.size.h) {
                        self.size.w = w;
                        self.size.h = h;
                        const new_sz = @as(usize, @intCast(cfg.width)) * @as(usize, @intCast(cfg.height)) * 4;
                        if (new_sz != self.pixels.len) {
                            if (self.allocator.realloc(self.pixels, new_sz)) |new_buf| {
                                self.pixels = new_buf;
                                self.recreateImage();
                            } else |_| {}
                        }
                        _ = out.push(.{ .window = .resized });
                    }
                },
                FocusIn => {
                    self.focused = true;
                    _ = out.push(.{ .window = .focused });
                },
                FocusOut => {
                    self.focused = false;
                    _ = out.push(.{ .window = .unfocused });
                },
                ButtonPress, ButtonRelease => {
                    const b = ev.xbutton;
                    const btn: event.MouseButton = switch (b.button) {
                        1 => .left,
                        2 => .middle,
                        3 => .right,
                        8 => .back,
                        9 => .forward,
                        else => .left,
                    };
                    _ = out.push(.{
                        .mouse = .{
                            .pos = .{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) },
                            .button = btn,
                            .pressed = (ev.type == ButtonPress),
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
                        },
                    });
                },
                KeyPress, KeyRelease => {
                    const k = ev.xkey;
                    const mapped_key = mapX11Keycode(k.keycode);
                    _ = out.push(.{
                        .key = .{
                            .key = mapped_key,
                            .pressed = (ev.type == KeyPress),
                        },
                    });
                },
                else => {},
            }
        }
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
    }

    fn wakeupFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.wakeups += 1;
        _ = self.api.XFlush(self.display);
    }

    fn infoFn(ptr: *anyopaque) backend.WindowInfo {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .size = self.size,
            .scale_factor = self.scale_factor,
            .focused = self.focused,
        };
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const w: u32 = @intFromFloat(self.size.w);
        const h: u32 = @intFromFloat(self.size.h);

        const target = gpu.software.Target.init(self.pixels, w, h, .bgra32);
        // Default fashion dark background (theme.bg = #0e0e13)
        target.clear(gpu.software.Color.hex(0x0e0e13));
        target.renderScene(scene);

        if (self.image) |img| {
            _ = self.api.XPutImage(self.display, self.window, self.gc, img, 0, 0, 0, 0, w, h);
            _ = self.api.XFlush(self.display);
        }
        self.presents += 1;
    }
};

fn mapX11Keycode(kc: c_uint) event.Key {
    return switch (kc) {
        9 => .escape,
        36 => .enter,
        65 => .space,
        22 => .backspace,
        23 => .tab,
        111 => .up,
        116 => .down,
        113 => .left,
        114 => .right,
        119 => .delete,
        110 => .home,
        115 => .end,
        38 => .a,
        56 => .b,
        54 => .c,
        40 => .d,
        26 => .e,
        41 => .f,
        42 => .g,
        43 => .h,
        31 => .i,
        44 => .j,
        45 => .k,
        46 => .l,
        58 => .m,
        57 => .n,
        32 => .o,
        33 => .p,
        24 => .q,
        27 => .r,
        39 => .s,
        28 => .t,
        30 => .u,
        55 => .v,
        25 => .w,
        53 => .x,
        29 => .y,
        52 => .z,
        19 => .n0,
        10 => .n1,
        11 => .n2,
        12 => .n3,
        13 => .n4,
        14 => .n5,
        15 => .n6,
        16 => .n7,
        17 => .n8,
        18 => .n9,
        else => .unknown,
    };
}

test "x11 availability and creation" {
    if (!X11Backend.isAvailable()) return;

    var b = try X11Backend.init(std.testing.allocator, "ZUI X11 Test", 200, 150);
    defer b.deinit();

    const handle = b.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.x11, handle.kind());
    try std.testing.expectEqual(@as(f32, 200), handle.windowInfo().size.w);
    try std.testing.expectEqual(@as(f32, 150), handle.windowInfo().size.h);

    var sc = gpu.Scene{};
    _ = sc.push(.{ .x = 10, .y = 10, .w = 80, .h = 80, .color = gpu.software.Color.hex(0xFF0000) });
    handle.present(&sc);
    try std.testing.expectEqual(@as(u32, 1), b.presents);
}
