//! The keyboard layout of an X server, read through libxkbcommon-x11 (dlopen, never linked).
//!
//! GPUI reads the layout the same way, over an xcb connection. ZUI keeps its Xlib connection, and
//! borrows the xcb connection Xlib exposes through `XGetXCBConnection`. Both libraries are optional:
//! without them `Keyboard.open` returns null and the layout stays "unknown".

const std = @import("std");
const dl = @import("dl.zig");
const xkb = @import("xkb.zig");

const xkb_x11_lib_names: []const [*:0]const u8 = &.{ "libxkbcommon-x11.so.0", "libxkbcommon-x11.so" };
const xcb_lib_names: []const [*:0]const u8 = &.{ "libX11-xcb.so.1", "libX11-xcb.so" };

const SetupFn = *const fn (?*anyopaque, u16, u16, c_uint, ?*u16, ?*u16, ?*u8, ?*u8) callconv(.c) c_int;
const CoreDeviceIdFn = *const fn (?*anyopaque) callconv(.c) i32;
const KeymapNewFn = *const fn (*xkb.Context, ?*anyopaque, i32, c_uint) callconv(.c) ?*xkb.Keymap;
const StateNewFn = *const fn (*xkb.Keymap, ?*anyopaque, i32) callconv(.c) ?*xkb.State;
const GetXcbConnectionFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

/// The layout source of one X connection: the keymap of the core keyboard, compiled once and
/// compiled again when the server says the mapping changed.
pub const Keyboard = struct {
    xkb_lib: dl.Library,
    x11_lib: dl.Library,
    xcb_lib: dl.Library,
    api: xkb.XkbApi,
    ctx: *xkb.Context,
    /// The `xcb_connection_t` of the Xlib display. Owned by Xlib.
    xcb: *anyopaque,
    device: i32,
    keymap_new: KeymapNewFn,
    state_new: StateNewFn,
    keymap: ?*xkb.Keymap = null,

    /// `dpy` is the Xlib `Display*`. Null when a library or symbol is missing, or the server has no XKB.
    pub fn open(dpy: *anyopaque) ?Keyboard {
        var xkb_lib = dl.Library.open(xkb.xkb_lib_names) orelse return null;
        const api = xkb.XkbApi.load(xkb_lib) orelse {
            xkb_lib.close();
            return null;
        };
        var x11_lib = dl.Library.open(xkb_x11_lib_names) orelse {
            xkb_lib.close();
            return null;
        };
        var xcb_lib = dl.Library.open(xcb_lib_names) orelse {
            x11_lib.close();
            xkb_lib.close();
            return null;
        };
        const setup = x11_lib.lookup(SetupFn, "xkb_x11_setup_xkb_extension");
        const device_id = x11_lib.lookup(CoreDeviceIdFn, "xkb_x11_get_core_keyboard_device_id");
        const keymap_new = x11_lib.lookup(KeymapNewFn, "xkb_x11_keymap_new_from_device");
        const state_new = x11_lib.lookup(StateNewFn, "xkb_x11_state_new_from_device");
        const get_xcb = xcb_lib.lookup(GetXcbConnectionFn, "XGetXCBConnection");
        const ready = setup != null and device_id != null and keymap_new != null and state_new != null and get_xcb != null;
        const xcb = if (ready) get_xcb.?(dpy) else null;
        const ctx = api.context_new(0);
        const connected = xcb != null and ctx != null and setup.?(xcb, 1, 0, 0, null, null, null, null) != 0;
        if (!connected) {
            if (ctx) |c| api.context_unref(c);
            xcb_lib.close();
            x11_lib.close();
            xkb_lib.close();
            return null;
        }
        const device = device_id.?(xcb);
        if (device < 0) {
            api.context_unref(ctx.?);
            xcb_lib.close();
            x11_lib.close();
            xkb_lib.close();
            return null;
        }
        var self: Keyboard = .{
            .xkb_lib = xkb_lib,
            .x11_lib = x11_lib,
            .xcb_lib = xcb_lib,
            .api = api,
            .ctx = ctx.?,
            .xcb = xcb.?,
            .device = device,
            .keymap_new = keymap_new.?,
            .state_new = state_new.?,
        };
        self.keymap_changed();
        return self;
    }

    pub fn deinit(self: *Keyboard) void {
        if (self.keymap) |k| self.api.keymap_unref(k);
        self.api.context_unref(self.ctx);
        self.xcb_lib.close();
        self.x11_lib.close();
        self.xkb_lib.close();
    }

    /// The server's keyboard mapping changed: compile the keymap again.
    pub fn keymap_changed(self: *Keyboard) void {
        const fresh = self.keymap_new(self.ctx, self.xcb, self.device, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (self.keymap) |old| self.api.keymap_unref(old);
        self.keymap = fresh;
    }

    /// The layout in effect now, such as "English (US)". The name is in the keymap, so copy it.
    /// Null when there is no keymap. The state is asked from the server each time, since a group
    /// switch changes it without a keymap event.
    pub fn layout_name(self: *Keyboard) ?[]const u8 {
        const keymap = self.keymap orelse return null;
        const st = self.state_new(keymap, self.xcb, self.device) orelse return null;
        defer self.api.state_unref(st);
        const index = self.api.state_serialize_layout(st, xkb.XKB_STATE_LAYOUT_EFFECTIVE);
        const name = self.api.keymap_layout_get_name(keymap, index) orelse return null;
        return std.mem.span(name);
    }
};
