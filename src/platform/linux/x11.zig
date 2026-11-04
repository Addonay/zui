//! X11 backend (GPUI `gpui_linux` x11 module). One `X11Connection` owns the
//! Display, atoms, cursors and clipboard; each platform window is a top-level
//! X window drawn with the CPU renderer into an XImage (ZPixmap, 32 bpp) and
//! put with XPutImage. Frames are paced at about 60 Hz.

const std = @import("std");
const geometry = @import("../../geometry.zig");
const platform = @import("../../platform.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const interactive = @import("../../interactive.zig");
const window_mod = @import("../../window.zig");
const color = @import("../../color.zig");
const cpu = @import("../../renderer/cpu.zig");
const window_renderer = @import("../../renderer/window_renderer.zig");
const proto = @import("x11_proto.zig");
const dl = @import("dl.zig");
const input = @import("input.zig");

const Pixels = geometry.Pixels;
const PxPoint = geometry.Point(Pixels);
const PxSize = geometry.Size(Pixels);
const PxBounds = geometry.Bounds(Pixels);
const CursorStyle = platform.CursorStyle;
const MouseButton = interactive.MouseButton;
const Display = platform.Display;
const XWindow = proto.Window;
const Atom = proto.Atom;
const Cursor = proto.Cursor;
const XEvent = proto.XEvent;

const clear_color: color.Hsla = color.to_hsla(color.rgb(0x0e0e13));
const frame_interval_ms: i64 = 16;

/// Atoms interned once per connection.
const Atoms = struct {
    clipboard: Atom = 0,
    utf8_string: Atom = 0,
    targets: Atom = 0,
    text: Atom = 0,
    incr: Atom = 0,
    net_wm_name: Atom = 0,
    motif_hints: Atom = 0,
    wm_protocols: Atom = 0,
    wm_delete_window: Atom = 0,
    net_wm_ping: Atom = 0,
    net_wm_state: Atom = 0,
    net_wm_state_maximized_vert: Atom = 0,
    net_wm_state_maximized_horz: Atom = 0,
    net_wm_state_fullscreen: Atom = 0,
    net_wm_moveresize: Atom = 0,
    paste: Atom = 0,
};

/// Latched Xlib error handler: a failed request is logged and dropped rather
/// than exiting the process (Xlib's default would kill every window).
fn errorHandler(_: ?*proto.Display, _: ?*anyopaque) callconv(.c) c_int {
    std.log.warn("x11: protocol error (request dropped)", .{});
    return 0;
}

pub const X11Connection = struct {
    allocator: std.mem.Allocator,
    lib: dl.Library,
    api: proto.Api,
    display: *proto.Display,
    screen: c_int,
    root: XWindow,
    gpu_context: ?*window_renderer.GpuContext = null,
    gpu_probed: bool = false,
    /// Hidden window that owns the clipboard and receives selection replies.
    helper: XWindow,
    atoms: Atoms,
    windows: std.ArrayList(*X11Window) = .empty,
    cursors: [@typeInfo(CursorStyle).@"enum".field_names.len]Cursor = @splat(0),
    cursor_style: CursorStyle = .arrow,
    scale: f32 = 1,
    mods: u32 = 0,
    click: input.ClickTracker = .{},
    pressed: ?MouseButton = null,
    /// Root position of the last button press (for window move drags).
    press_root: [2]c_long = .{ 0, 0 },
    /// Events read during a synchronous clipboard request, replayed later.
    stash: [64]XEvent = undefined,
    stash_len: usize = 0,
    clip_offer: ?[]u8 = null,
    owning_selection: bool = false,
    clip_read: ?[]u8 = null,
    dead: bool = false,
    display_storage: [1]Display = undefined,

    /// Connects to the X server named by DISPLAY.
    pub fn connect(allocator: std.mem.Allocator) !*X11Connection {
        if (std.c.getenv("DISPLAY") == null) return error.NoDisplay;
        var lib = dl.Library.open(&.{ "libX11.so.6", "libX11.so" }) orelse return error.LibraryNotFound;
        const api = proto.Api.load(lib) orelse {
            lib.close();
            return error.MissingSymbols;
        };
        const dpy = api.XOpenDisplay(null) orelse {
            lib.close();
            return error.CannotOpenDisplay;
        };
        _ = api.XSetErrorHandler(errorHandler);
        const screen = api.XDefaultScreen(dpy);
        const root = api.XRootWindow(dpy, screen);
        const helper = api.XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0);
        const atoms: Atoms = .{
            .clipboard = api.XInternAtom(dpy, "CLIPBOARD", 0),
            .utf8_string = api.XInternAtom(dpy, "UTF8_STRING", 0),
            .targets = api.XInternAtom(dpy, "TARGETS", 0),
            .text = api.XInternAtom(dpy, "TEXT", 0),
            .incr = api.XInternAtom(dpy, "INCR", 0),
            .net_wm_name = api.XInternAtom(dpy, "_NET_WM_NAME", 0),
            .motif_hints = api.XInternAtom(dpy, "_MOTIF_WM_HINTS", 0),
            .wm_protocols = api.XInternAtom(dpy, "WM_PROTOCOLS", 0),
            .wm_delete_window = api.XInternAtom(dpy, "WM_DELETE_WINDOW", 0),
            .net_wm_ping = api.XInternAtom(dpy, "_NET_WM_PING", 0),
            .net_wm_state = api.XInternAtom(dpy, "_NET_WM_STATE", 0),
            .net_wm_state_maximized_vert = api.XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_VERT", 0),
            .net_wm_state_maximized_horz = api.XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", 0),
            .net_wm_state_fullscreen = api.XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", 0),
            .net_wm_moveresize = api.XInternAtom(dpy, "_NET_WM_MOVERESIZE", 0),
            .paste = api.XInternAtom(dpy, "ZUI_PASTE", 0),
        };
        const self = allocator.create(X11Connection) catch {
            _ = api.XCloseDisplay(dpy);
            lib.close();
            return error.OutOfMemory;
        };
        self.* = .{
            .allocator = allocator,
            .lib = lib,
            .api = api,
            .display = dpy,
            .screen = screen,
            .root = root,
            .helper = helper,
            .atoms = atoms,
            .scale = input.env_scale() orelse xftScale(api, dpy),
        };
        return self;
    }

    /// Scale from the Xft.dpi resource (96 dpi is 1x). Falls back to 1.
    fn xftScale(api: proto.Api, dpy: *proto.Display) f32 {
        const rm = api.XResourceManagerString orelse return 1;
        const text = rm(dpy) orelse return 1;
        const s = std.mem.span(text);
        const key = "Xft.dpi:";
        const at = std.mem.indexOf(u8, s, key) orelse return 1;
        var rest = std.mem.trimStart(u8, s[at + key.len ..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
        rest = rest[0..end];
        const dpi = std.fmt.parseFloat(f32, rest) catch return 1;
        if (dpi < 48 or dpi > 960) return 1;
        return @max(1, @round(dpi / 96.0 * 4) / 4);
    }

    pub fn fd(self: *X11Connection) c_int {
        return self.api.XConnectionNumber(self.display);
    }

    pub fn is_dead(self: *const X11Connection) bool {
        return self.dead;
    }

    /// True when events are already queued and the caller must not block.
    pub fn prepare_wait(self: *X11Connection) bool {
        _ = self.api.XFlush(self.display);
        return self.api.XPending(self.display) > 0;
    }

    pub fn finish_wait(self: *X11Connection, readable: bool) void {
        _ = readable;
        var ev: XEvent = undefined;
        while (self.stash_len > 0) {
            self.stash_len -= 1;
            self.translate(self.stash[self.stash_len]);
        }
        while (self.api.XPending(self.display) > 0) {
            _ = self.api.XNextEvent(self.display, &ev);
            self.translate(ev);
        }
        _ = self.api.XFlush(self.display);
    }

    pub fn flush(self: *X11Connection) void {
        _ = self.api.XFlush(self.display);
    }

    /// Milliseconds until the earliest frame a window wants, or null.
    pub fn frame_timeout(self: *const X11Connection, now: i64) ?i32 {
        var best: ?i32 = null;
        for (self.windows.items) |w| {
            if (!w.frame_wanted or w.closed) continue;
            const due: i32 = @intCast(@max(0, w.last_frame_ms + frame_interval_ms - now));
            best = if (best) |b| @min(b, due) else due;
        }
        return best;
    }

    pub fn pump(self: *X11Connection) void {
        const now = input.now_ms();
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            const w = self.windows.items[i];
            if (w.frame_wanted and !w.closed and now - w.last_frame_ms >= frame_interval_ms) {
                w.frame_wanted = false;
                w.last_frame_ms = now;
                w.base.emit_request_frame(.{});
            }
        }
        self.flush();
    }

    pub fn reap(self: *X11Connection) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const w = self.windows.items[i];
            if (w.closed) {
                _ = self.windows.swapRemove(i);
                w.free();
            } else i += 1;
        }
    }

    pub fn live_windows(self: *const X11Connection) usize {
        var n: usize = 0;
        for (self.windows.items) |w| {
            if (!w.closed) n += 1;
        }
        return n;
    }

    pub fn displays(self: *X11Connection) []const Display {
        const w = self.api.XDisplayWidth(self.display, self.screen);
        const h = self.api.XDisplayHeight(self.display, self.screen);
        const out = &self.display_storage;
        out[0] = .{
            .id = 0,
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @as(f32, @floatFromInt(w)) / self.scale, .height = @as(f32, @floatFromInt(h)) / self.scale } },
            .scale_factor = self.scale,
        };
        return out[0..1];
    }

    pub fn deinit(self: *X11Connection) void {
        for (self.windows.items) |w| w.close_now();
        for (self.windows.items) |w| w.free();
        self.windows.deinit(self.allocator);
        if (self.gpu_context) |ctx| ctx.destroy();
        for (self.cursors) |c| {
            if (c != 0) _ = self.api.XFreeCursor(self.display, c);
        }
        if (self.clip_offer) |c| self.allocator.free(c);
        if (self.clip_read) |c| self.allocator.free(c);
        _ = self.api.XDestroyWindow(self.display, self.helper);
        _ = self.api.XCloseDisplay(self.display);
        self.lib.close();
        self.allocator.destroy(self);
    }

    // -- windows ----------------------------------------------------------

    pub fn open_window(self: *X11Connection, options: window_mod.WindowOptions) !*X11Window {
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
        const b: PxBounds = if (options.window_bounds) |wb| wb.get_bounds() else .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1280, .height = 800 } };
        const w = try self.allocator.create(X11Window);
        w.* = .{
            .allocator = self.allocator,
            .conn = self,
            .size = b.size,
            .scale = self.scale,
            .atlas = atlas_mod.CpuAtlas.init(self.allocator),
            .renderer = cpu.CpuRenderer.init(self.allocator),
        };
        const a = &self.api;
        const pw: c_uint = @intFromFloat(@max(1, @round(b.size.width * self.scale)));
        const ph: c_uint = @intFromFloat(@max(1, @round(b.size.height * self.scale)));
        const x = a.XCreateSimpleWindow(self.display, self.root, 0, 0, pw, ph, 0, 0, 0);
        w.x_window = x;
        var title_buf: [512]u8 = undefined;
        const title_src: []const u8 = if (options.titlebar) |t| (t.title orelse "ZUI") else "ZUI";
        const tn = @min(title_src.len, title_buf.len - 1);
        @memcpy(title_buf[0..tn], title_src[0..tn]);
        title_buf[tn] = 0;
        const title: [*:0]const u8 = @ptrCast(&title_buf);
        _ = a.XStoreName(self.display, x, title);
        _ = a.XChangeProperty(self.display, x, self.atoms.net_wm_name, self.atoms.utf8_string, 8, 0, title, @intCast(tn));
        var protocols = [2]Atom{ self.atoms.wm_delete_window, self.atoms.net_wm_ping };
        _ = a.XSetWMProtocols(self.display, x, &protocols, 2);
        if (options.titlebar == null) self.set_decorations(x, false);
        const mask: c_long = proto.ExposureMask | proto.KeyPressMask | proto.KeyReleaseMask | proto.ButtonPressMask | proto.ButtonReleaseMask | proto.PointerMotionMask | proto.StructureNotifyMask | proto.FocusChangeMask | proto.EnterWindowMask | proto.LeaveWindowMask;
        _ = a.XSelectInput(self.display, x, mask);
        if (options.show) _ = a.XMapWindow(self.display, x);
        w.frame_wanted = true;
        if (!self.gpu_probed) {
            self.gpu_probed = true;
            self.gpu_context = window_renderer.GpuContext.create(self.allocator, .x11);
        }
        if (self.gpu_context) |ctx| {
            w.gpu_window = window_renderer.GpuWindow.create(ctx, .{ .x11 = .{ .display = @ptrCast(self.display), .window = x } }, pw, ph, .{});
        }
        self.windows.appendAssumeCapacity(w);
        w.apply_cursor();
        self.flush();
        return w;
    }

    /// Motif hints: turn off the window manager's frame (decorations = 0).
    fn set_decorations(self: *X11Connection, x: XWindow, decorated: bool) void {
        var hints = [5]c_long{ 2, 0, if (decorated) 1 else 0, 0, 0 };
        _ = self.api.XChangeProperty(self.display, x, self.atoms.motif_hints, self.atoms.motif_hints, 32, 0, @ptrCast(&hints), 5);
    }

    fn find_window(self: *X11Connection, native: XWindow) ?*X11Window {
        for (self.windows.items) |w| {
            if (!w.closed and w.x_window == native) return w;
        }
        return null;
    }

    fn cursor_glyph(style: CursorStyle) c_uint {
        return switch (style) {
            .arrow, .context_menu, .drag_copy, .none => proto.XC_left_ptr,
            .i_beam, .i_beam_cursor_for_vertical_layout => proto.XC_xterm,
            .crosshair => proto.XC_crosshair,
            .pointing_hand, .drag_link => proto.XC_hand2,
            .open_hand => proto.XC_hand2,
            .closed_hand => proto.XC_hand1,
            .resize_left => proto.XC_left_side,
            .resize_right => proto.XC_right_side,
            .resize_left_right, .resize_column => proto.XC_sb_h_double_arrow,
            .resize_up => proto.XC_top_side,
            .resize_down => proto.XC_bottom_side,
            .resize_up_down, .resize_row => proto.XC_sb_v_double_arrow,
            .resize_up_left_down_right => proto.XC_bottom_right_corner,
            .resize_up_right_down_left => proto.XC_bottom_left_corner,
            .operation_not_allowed => proto.XC_X_cursor,
        };
    }

    /// The cursor object for a style, created on first use.
    fn cursor_for(self: *X11Connection, style: CursorStyle) Cursor {
        const idx = @backingInt(style);
        if (self.cursors[idx] == 0) {
            self.cursors[idx] = self.api.XCreateFontCursor(self.display, cursor_glyph(style));
        }
        return self.cursors[idx];
    }

    pub fn set_cursor_style(self: *X11Connection, style: CursorStyle) void {
        self.cursor_style = style;
        for (self.windows.items) |w| w.apply_cursor();
        self.flush();
    }

    // -- events ----------------------------------------------------------

    fn translate(self: *X11Connection, ev: XEvent) void {
        switch (ev.type) {
            proto.SelectionRequest => return self.serve_selection(ev.xselectionrequest),
            proto.SelectionClear => {
                self.owning_selection = false;
                return;
            },
            proto.SelectionNotify => return,
            else => {},
        }
        const native: XWindow = switch (ev.type) {
            proto.ConfigureNotify => ev.xconfigure.window,
            else => ev.xany.window,
        };
        const w = self.find_window(native) orelse return;
        switch (ev.type) {
            proto.DestroyNotify => {
                w.destroyed_by_server = true;
                w.request_close();
            },
            proto.ClientMessage => {
                const client = ev.xclient;
                if (client.message_type != self.atoms.wm_protocols) return;
                const kind: Atom = @intCast(client.data.l[0]);
                if (kind == self.atoms.net_wm_ping) {
                    var reply = client;
                    reply.window = self.root;
                    var out: XEvent = undefined;
                    @memset(std.mem.asBytes(&out), 0);
                    @memcpy(std.mem.asBytes(&out)[0..@sizeOf(proto.XClientMessageEvent)], std.mem.asBytes(&reply));
                    _ = self.api.XSendEvent(self.display, self.root, 0, proto.SubstructureRedirectMask | proto.SubstructureNotifyMask, &out);
                } else if (kind == self.atoms.wm_delete_window) {
                    w.request_close();
                }
            },
            proto.ConfigureNotify => {
                const cfg = ev.xconfigure;
                w.on_configure(@intCast(@max(0, cfg.width)), @intCast(@max(0, cfg.height)));
            },
            proto.Expose => {
                if (ev.xexpose.count == 0) w.frame_wanted = true;
            },
            proto.FocusIn => {
                w.focused = true;
                w.base.emit_active(true);
            },
            proto.FocusOut => {
                w.focused = false;
                w.base.emit_active(false);
            },
            proto.EnterNotify => {
                w.base.emit_hover(true);
            },
            proto.LeaveNotify => {
                w.base.emit_hover(false);
                _ = w.base.emit_input(.{ .mouse_exited = .{ .position = w.logical(ev.xcrossing.x, ev.xcrossing.y), .modifiers = input.modifiers(self.mods) } });
            },
            proto.MotionNotify => {
                const m = ev.xmotion;
                self.note_mods(m.state);
                _ = w.base.emit_input(.{ .mouse_move = .{
                    .position = w.logical(m.x, m.y),
                    .pressed_button = self.pressed,
                    .modifiers = input.modifiers(m.state),
                } });
            },
            proto.ButtonPress, proto.ButtonRelease => self.on_button(w, ev.xbutton, ev.type == proto.ButtonPress),
            proto.KeyPress, proto.KeyRelease => self.on_key(w, ev.xkey, ev.type == proto.KeyPress),
            else => {},
        }
    }

    fn note_mods(self: *X11Connection, state: c_uint) void {
        const m = @as(u32, state) & 0xff;
        if (m == self.mods) return;
        self.mods = m;
        _ = self.active_window_for_mods();
    }

    /// Reports a modifier change to the focused window.
    fn active_window_for_mods(self: *X11Connection) ?*X11Window {
        for (self.windows.items) |w| {
            if (w.focused and !w.closed) {
                _ = w.base.emit_input(.{ .modifiers_changed = .{ .modifiers = input.modifiers(self.mods) } });
                return w;
            }
        }
        return null;
    }

    fn on_button(self: *X11Connection, w: *X11Window, b: proto.XButtonEvent, pressed: bool) void {
        self.note_mods(b.state);
        const pos = w.logical(b.x, b.y);
        const mods = input.modifiers(b.state);
        if (b.button >= 4 and b.button <= 7) {
            if (!pressed) return;
            const dx: f32 = switch (b.button) {
                6 => -1,
                7 => 1,
                else => 0,
            };
            const dy: f32 = switch (b.button) {
                4 => 1,
                5 => -1,
                else => 0,
            };
            _ = w.base.emit_input(.{ .scroll_wheel = .{ .position = pos, .delta = .{ .lines = .{ .x = dx, .y = dy } }, .modifiers = mods } });
            return;
        }
        const button = input.x11_button(b.button) orelse return;
        if (pressed) {
            self.press_root = .{ @intCast(b.x_root), @intCast(b.y_root) };
            self.pressed = button;
            const count = self.click.press(button, pos);
            _ = w.base.emit_input(.{ .mouse_down = .{ .button = button, .position = pos, .modifiers = mods, .click_count = count } });
        } else {
            if (self.pressed) |p| if (p.eql(button)) {
                self.pressed = null;
            };
            _ = w.base.emit_input(.{ .mouse_up = .{ .button = button, .position = pos, .modifiers = mods, .click_count = self.click.count } });
        }
    }

    fn on_key(self: *X11Connection, w: *X11Window, ev: proto.XKeyEvent, pressed: bool) void {
        self.note_mods(ev.state);
        var k = ev;
        var keysym: c_ulong = 0;
        var buf: [32]u8 = undefined;
        const n: usize = @intCast(@max(0, self.api.XLookupString(&k, &buf, @intCast(buf.len), &keysym, null)));
        const shift = (ev.state & input.MOD_SHIFT) != 0;
        var name: ?[]const u8 = input.key_name_for_keysym(@intCast(keysym));
        if (name == null) {
            if (ev.keycode >= 8) {
                if (input.evdev_key(ev.keycode - 8, shift)) |info| name = info.name;
            }
        }
        const key_name = name orelse return;
        var text_buf: [64]u8 = undefined;
        var text_len: usize = 0;
        if (pressed) {
            // Like xkb's utf8 query, the keysym's text ignores Control, so
            // ctrl-a types "a" (GPUI behavior). Fall back to XLookupString's
            // Latin-1 bytes for keysyms without a direct text form.
            var tmp: [4]u8 = undefined;
            if (input.utf8_for_keysym(@intCast(keysym), &tmp)) |t| {
                @memcpy(text_buf[0..t.len], t);
                text_len = t.len;
            } else {
                for (buf[0..@min(n, buf.len)]) |byte| {
                    const enc = input.latin1_to_utf8(byte, &tmp);
                    if (text_len + enc.len > text_buf.len) break;
                    @memcpy(text_buf[text_len..][0..enc.len], enc);
                    text_len += enc.len;
                }
            }
        }
        const text: ?[]const u8 = if (text_len > 0) text_buf[0..text_len] else null;
        w.emit_key(key_name, text, pressed, false);
    }

    // -- clipboard ----------------------------------------------------------

    pub fn set_clipboard(self: *X11Connection, text: []const u8) bool {
        const copy = self.allocator.dupe(u8, text) catch return false;
        if (self.clip_offer) |old| self.allocator.free(old);
        self.clip_offer = copy;
        _ = self.api.XSetSelectionOwner(self.display, self.atoms.clipboard, self.helper, proto.CURRENT_TIME);
        self.owning_selection = self.api.XGetSelectionOwner(self.display, self.atoms.clipboard) == self.helper;
        self.flush();
        return self.owning_selection;
    }

    /// Answers a paste request for text we own; anything else is refused.
    fn serve_selection(self: *X11Connection, req: proto.XSelectionRequestEvent) void {
        if (req.selection != self.atoms.clipboard or !self.owning_selection) return;
        var notify = std.mem.zeroes(proto.XSelectionEvent);
        notify.type = proto.SelectionNotify;
        notify.display = self.display;
        notify.requestor = req.requestor;
        notify.selection = req.selection;
        notify.target = req.target;
        notify.time = req.time;
        const text = self.clip_offer orelse "";
        if (req.target == self.atoms.targets) {
            const supported = [_]Atom{ self.atoms.targets, self.atoms.utf8_string, proto.XA_STRING, self.atoms.text };
            _ = self.api.XChangeProperty(self.display, req.requestor, req.property, proto.XA_ATOM, 32, proto.PROP_MODE_REPLACE, @ptrCast(&supported), 4);
            notify.property = req.property;
        } else if (req.target == self.atoms.utf8_string or req.target == proto.XA_STRING or req.target == self.atoms.text) {
            _ = self.api.XChangeProperty(self.display, req.requestor, req.property, req.target, 8, proto.PROP_MODE_REPLACE, text.ptr, @intCast(text.len));
            notify.property = req.property;
        } else {
            notify.property = 0;
        }
        var ev = std.mem.zeroes(XEvent);
        @memcpy(std.mem.asBytes(&ev)[0..@sizeOf(proto.XSelectionEvent)], std.mem.asBytes(&notify));
        _ = self.api.XSendEvent(self.display, req.requestor, 0, 0, &ev);
        self.flush();
    }

    /// Requests the clipboard as UTF-8 and waits up to 500 ms for the reply.
    pub fn get_clipboard(self: *X11Connection) ?[]const u8 {
        if (self.owning_selection) return self.clip_offer;
        if (self.api.XGetSelectionOwner(self.display, self.atoms.clipboard) == 0) return null;
        _ = self.api.XConvertSelection(self.display, self.atoms.clipboard, self.atoms.utf8_string, self.atoms.paste, self.helper, proto.CURRENT_TIME);
        self.flush();
        const deadline = input.now_ms() + 500;
        var ev: XEvent = undefined;
        while (input.now_ms() < deadline) {
            var pfd = [1]std.posix.pollfd{.{ .fd = self.fd(), .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&pfd, 25) catch 0;
            while (self.api.XPending(self.display) > 0) {
                _ = self.api.XNextEvent(self.display, &ev);
                switch (ev.type) {
                    proto.SelectionNotify => {
                        const note = ev.xselection;
                        if (note.selection != self.atoms.clipboard or note.property == 0) return null;
                        return self.read_paste_property();
                    },
                    proto.SelectionRequest => self.serve_selection(ev.xselectionrequest),
                    proto.SelectionClear => {
                        self.owning_selection = false;
                    },
                    else => {
                        if (self.stash_len < self.stash.len) {
                            self.stash[self.stash_len] = ev;
                            self.stash_len += 1;
                        }
                    },
                }
            }
        }
        return null;
    }

    fn read_paste_property(self: *X11Connection) ?[]const u8 {
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var prop: [*]u8 = undefined;
        // Read up to 1 MiB of property data in one request.
        const rc = self.api.XGetWindowProperty(self.display, self.helper, self.atoms.paste, 0, 256 * 1024, 1, proto.XA_ANY_PROPERTY_TYPE, &actual_type, &actual_format, &nitems, &after, &prop);
        if (rc != 0 or actual_format != 8) return null;
        defer _ = self.api.XFree(prop);
        if (actual_type == self.atoms.incr) return null;
        if (self.clip_read) |old| self.allocator.free(old);
        self.clip_read = self.allocator.dupe(u8, prop[0..@intCast(nitems)]) catch null;
        return self.clip_read;
    }
};

pub const X11Window = struct {
    base: platform.PlatformWindow = .{ .vtable = &vtable },
    allocator: std.mem.Allocator,
    conn: *X11Connection,
    x_window: XWindow = 0,
    /// Logical size; the OS window and buffers are `size * scale` physical pixels.
    size: PxSize,
    scale: f32,
    /// XImage whose data is malloc'd (XDestroyImage frees it).
    image: ?*proto.XImage = null,
    image_w: u32 = 0,
    image_h: u32 = 0,
    frame_wanted: bool = false,
    last_frame_ms: i64 = 0,
    focused: bool = false,
    destroyed_by_server: bool = false,
    closed: bool = false,
    atlas: atlas_mod.CpuAtlas,
    renderer: cpu.CpuRenderer,
    /// Set when this window draws with the GPU; `atlas` and `renderer` then stay idle.
    gpu_window: ?window_renderer.GpuWindow = null,

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
        .resize = resize,
        .close = close,
    };

    pub fn from(p: *platform.PlatformWindow) *X11Window {
        return @fieldParentPtr("base", p);
    }

    /// Logical point from physical window coordinates.
    fn logical(self: *const X11Window, x: c_int, y: c_int) PxPoint {
        return .{ .x = @as(f32, @floatFromInt(x)) / self.scale, .y = @as(f32, @floatFromInt(y)) / self.scale };
    }

    pub fn emit_key(self: *X11Window, name: []const u8, text: ?[]const u8, pressed: bool, held: bool) void {
        const ks = input.make_keystroke(name, text, input.modifiers(self.conn.mods));
        if (pressed) {
            _ = self.base.emit_input(.{ .key_down = .{ .keystroke = ks, .is_held = held } });
        } else {
            _ = self.base.emit_input(.{ .key_up = .{ .keystroke = ks } });
        }
    }

    fn apply_cursor(self: *X11Window) void {
        const conn = self.conn;
        if (self.destroyed_by_server or self.closed) return;
        const c = conn.cursor_for(conn.cursor_style);
        _ = conn.api.XDefineCursor(conn.display, self.x_window, c);
    }

    fn on_configure(self: *X11Window, pw: u32, ph: u32) void {
        const logical_w = @as(f32, @floatFromInt(pw)) / self.scale;
        const logical_h = @as(f32, @floatFromInt(ph)) / self.scale;
        if (logical_w == self.size.width and logical_h == self.size.height) return;
        self.size = .{ .width = @round(logical_w), .height = @round(logical_h) };
        self.base.emit_resize(self.size, self.scale);
    }

    fn request_close(self: *X11Window) void {
        if (self.closed) return;
        if (self.base.emit_should_close()) self.base.emit_close();
    }

    fn physical(self: *const X11Window) struct { w: u32, h: u32 } {
        return .{
            .w = @intFromFloat(@max(1, @round(self.size.width * self.scale))),
            .h = @intFromFloat(@max(1, @round(self.size.height * self.scale))),
        };
    }

    /// Makes sure the XImage matches the physical size, reallocating on change.
    fn ensure_image(self: *X11Window, w: u32, h: u32) bool {
        if (self.image != null and self.image_w == w and self.image_h == h) return true;
        const conn = self.conn;
        const a = &conn.api;
        if (self.image) |img| {
            _ = a.XDestroyImage(img); // frees the pixel buffer too
            self.image = null;
        }
        const bytes = @as(usize, w) * h * 4;
        const data: ?*anyopaque = std.c.malloc(bytes);
        const px: [*]u8 = @ptrCast(data orelse return false);
        const visual = a.XDefaultVisual(conn.display, conn.screen);
        const depth = a.XDefaultDepth(conn.display, conn.screen);
        const img = a.XCreateImage(conn.display, visual, @intCast(depth), proto.ZPixmap, 0, px, w, h, 32, @intCast(w * 4)) orelse {
            std.c.free(data);
            return false;
        };
        self.image = img;
        self.image_w = w;
        self.image_h = h;
        return true;
    }

    fn draw(p: *platform.PlatformWindow, scene: *const scene_mod.Scene) void {
        const self = from(p);
        if (self.closed or self.destroyed_by_server) return;
        const dims = self.physical();
        if (self.gpu_window) |*g| {
            if (!g.draw(scene, clear_color, dims.w, dims.h)) self.frame_wanted = true;
            self.conn.flush();
            return;
        }
        if (!self.ensure_image(dims.w, dims.h)) return;
        const img = self.image.?;
        const pixels = img.data.?[0 .. @as(usize, dims.w) * dims.h * 4];
        const fb: cpu.Framebuffer = .{ .pixels = pixels, .width = dims.w, .height = dims.h, .stride = dims.w * 4, .format = .bgra8 };
        self.renderer.draw(scene, &self.atlas, fb, clear_color);
        const conn = self.conn;
        const gc = conn.api.XDefaultGC(conn.display, conn.screen);
        _ = conn.api.XPutImage(conn.display, self.x_window, gc, img, 0, 0, 0, 0, dims.w, dims.h);
        conn.flush();
    }

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
        const self = from(p);
        var buf: [512]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        const conn = self.conn;
        _ = conn.api.XChangeProperty(conn.display, self.x_window, conn.atoms.net_wm_name, conn.atoms.utf8_string, 8, proto.PROP_MODE_REPLACE, &buf, @intCast(n));
        _ = conn.api.XStoreName(conn.display, self.x_window, @ptrCast(&buf));
        conn.flush();
    }
    fn minimize(p: *platform.PlatformWindow) void {
        const self = from(p);
        _ = self.conn.api.XIconifyWindow(self.conn.display, self.x_window, self.conn.screen);
        self.conn.flush();
    }
    fn zoom(p: *platform.PlatformWindow) void {
        from(p).send_state(2, from(p).conn.atoms.net_wm_state_maximized_vert, from(p).conn.atoms.net_wm_state_maximized_horz);
    }
    fn toggleFullscreen(p: *platform.PlatformWindow) void {
        from(p).send_state(2, from(p).conn.atoms.net_wm_state_fullscreen, 0);
    }

    /// _NET_WM_STATE client message: action 2 toggles the given properties.
    fn send_state(self: *X11Window, action: c_long, a1: Atom, a2: Atom) void {
        const conn = self.conn;
        var ev = std.mem.zeroes(XEvent);
        ev.xclient = .{ .type = proto.ClientMessage, .serial = 0, .send_event = 1, .display = conn.display, .window = self.x_window, .message_type = conn.atoms.net_wm_state, .format = 32, .data = .{ .l = .{ action, @intCast(a1), @intCast(a2), 1, 0 } } };
        _ = conn.api.XSendEvent(conn.display, conn.root, 0, proto.SubstructureRedirectMask | proto.SubstructureNotifyMask, &ev);
        conn.flush();
    }

    fn startWindowMove(p: *platform.PlatformWindow) void {
        const self = from(p);
        const conn = self.conn;
        var ev = std.mem.zeroes(XEvent);
        // _NET_WM_MOVERESIZE with direction 8 (move) at the last press position.
        ev.xclient = .{ .type = proto.ClientMessage, .serial = 0, .send_event = 1, .display = conn.display, .window = self.x_window, .message_type = conn.atoms.net_wm_moveresize, .format = 32, .data = .{ .l = .{ conn.press_root[0], conn.press_root[1], 8, 1, 1 } } };
        _ = conn.api.XSendEvent(conn.display, conn.root, 0, proto.SubstructureRedirectMask | proto.SubstructureNotifyMask, &ev);
        conn.flush();
    }

    fn resize(p: *platform.PlatformWindow, size: PxSize) void {
        const self = from(p);
        const dims = @as(c_uint, @intFromFloat(@max(1, @round(size.width * self.scale))));
        const dims_h = @as(c_uint, @intFromFloat(@max(1, @round(size.height * self.scale))));
        _ = self.conn.api.XResizeWindow(self.conn.display, self.x_window, dims, dims_h);
        self.conn.flush();
    }

    fn close(p: *platform.PlatformWindow) void {
        from(p).close_now();
    }

    /// Marks the window closed and destroys its X window. Memory is freed by
    /// `X11Connection.reap`, so callers inside an event may still touch it.
    pub fn close_now(self: *X11Window) void {
        if (self.closed) return;
        self.closed = true;
        self.frame_wanted = false;
        // The Vulkan surface must die before the X window it wraps.
        if (self.gpu_window) |*g| {
            g.deinit();
            self.gpu_window = null;
        }
        if (!self.destroyed_by_server) {
            _ = self.conn.api.XDestroyWindow(self.conn.display, self.x_window);
        }
        self.conn.flush();
    }

    /// Frees a closed window. Called only from `X11Connection.reap`.
    pub fn free(self: *X11Window) void {
        if (!self.closed) self.close_now();
        if (self.image) |img| {
            _ = self.conn.api.XDestroyImage(img);
            self.image = null;
        }
        self.atlas.deinit();
        self.renderer.deinit();
        self.allocator.destroy(self);
    }
};

test "x11 cursor styles use cursorfont glyphs" {
    try std.testing.expectEqual(proto.XC_left_ptr, X11Connection.cursor_glyph(.arrow));
    try std.testing.expectEqual(proto.XC_xterm, X11Connection.cursor_glyph(.i_beam));
    try std.testing.expectEqual(proto.XC_hand2, X11Connection.cursor_glyph(.pointing_hand));
}
