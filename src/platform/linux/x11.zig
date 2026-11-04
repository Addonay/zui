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
const xkb = @import("xkb.zig");
const xim_preedit = @import("xim_preedit.zig");
const x11_scroll = @import("x11_scroll.zig");
const xdnd = @import("xdnd.zig");

extern "c" fn setlocale(category: c_int, locale: ?[*:0]const u8) ?[*:0]const u8;
const LC_CTYPE: c_int = 0;
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
const im_retry_interval_ms: i64 = 1000;
const im_retry_count: u32 = 60;
const window_event_mask: c_long = proto.ExposureMask | proto.KeyPressMask | proto.KeyReleaseMask | proto.ButtonPressMask | proto.ButtonReleaseMask | proto.PointerMotionMask | proto.StructureNotifyMask | proto.FocusChangeMask | proto.EnterWindowMask | proto.LeaveWindowMask | proto.VisibilityChangeMask;

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
    net_wm_sync_request: Atom = 0,
    net_wm_sync_request_counter: Atom = 0,
    xdnd_aware: Atom = 0,
    xdnd_enter: Atom = 0,
    xdnd_position: Atom = 0,
    xdnd_status: Atom = 0,
    xdnd_leave: Atom = 0,
    xdnd_drop: Atom = 0,
    xdnd_finished: Atom = 0,
    xdnd_selection: Atom = 0,
    xdnd_type_list: Atom = 0,
    xdnd_action_copy: Atom = 0,
    xdnd_data: Atom = 0,
    text_uri_list: Atom = 0,
};

/// XDND protocol version we speak.
const xdnd_version: c_long = 5;

/// One file drag in progress over a window of ours.
const DragSession = struct {
    source: XWindow = 0,
    window: ?*X11Window = null,
    /// Empty when the source offers nothing we understand: the drag is then refused.
    has_uri_list: bool = false,
    requested: bool = false,
    /// `paths` holds the files and the window has been told about them.
    entered: bool = false,
    position: PxPoint = .{ .x = 0, .y = 0 },
    /// The drop arrived before the data did, so it finishes when the data lands.
    drop_pending: bool = false,
    paths: []const []const u8 = &.{},
};

/// A monitor's rectangle and how often it refreshes.
const CrtcRate = struct { x: c_int, y: c_int, w: c_int, h: c_int, interval_ms: i64 };

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
    compose: ?xkb.Compose = null,
    xi_lib: ?dl.Library = null,
    xi_api: ?proto.XiApi = null,
    xi_opcode: c_int = 0,
    xi_has_gestures: bool = false,
    pinch_scale: f32 = 1,
    scroll_devices: x11_scroll.ScrollDevices = .{},
    xrandr_lib: ?dl.Library = null,
    xrandr_api: ?proto.XrandrApi = null,
    xrandr_event_base: c_int = 0,
    crtc_rates: [16]CrtcRate = undefined,
    crtc_count: usize = 0,
    xext_lib: ?dl.Library = null,
    xsync_api: ?proto.XsyncApi = null,
    drag: DragSession = .{},
    /// Null without an input method. Set from XMODIFIERS; see `open_im`.
    xim_api: ?proto.XimApi = null,
    im: ?*proto.XIM = null,
    /// The style contexts are created with: inline composition, or the IM's own window.
    im_style: c_ulong = 0,
    im_callback_registered: bool = false,
    /// After the server dies. Xlib's instantiate callback fires only once per registration,
    /// and a new registration fires at once while the dead server is still advertised, so
    /// it cannot announce a restart. Reconnecting is retried on a timer instead, for a while.
    im_retries_left: u32 = 0,
    im_next_retry_ms: i64 = 0,
    /// The physical key held down, to tell auto-repeat from a new press.
    held_keycode: u32 = 0,
    primary_offer: ?[]const u8 = null,
    owning_primary: bool = false,
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
        if (api.XkbSetDetectableAutoRepeat) |set_detectable| _ = set_detectable(dpy, 1, null);
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
            .net_wm_sync_request = api.XInternAtom(dpy, "_NET_WM_SYNC_REQUEST", 0),
            .net_wm_sync_request_counter = api.XInternAtom(dpy, "_NET_WM_SYNC_REQUEST_COUNTER", 0),
            .xdnd_aware = api.XInternAtom(dpy, "XdndAware", 0),
            .xdnd_enter = api.XInternAtom(dpy, "XdndEnter", 0),
            .xdnd_position = api.XInternAtom(dpy, "XdndPosition", 0),
            .xdnd_status = api.XInternAtom(dpy, "XdndStatus", 0),
            .xdnd_leave = api.XInternAtom(dpy, "XdndLeave", 0),
            .xdnd_drop = api.XInternAtom(dpy, "XdndDrop", 0),
            .xdnd_finished = api.XInternAtom(dpy, "XdndFinished", 0),
            .xdnd_selection = api.XInternAtom(dpy, "XdndSelection", 0),
            .xdnd_type_list = api.XInternAtom(dpy, "XdndTypeList", 0),
            .xdnd_action_copy = api.XInternAtom(dpy, "XdndActionCopy", 0),
            .xdnd_data = api.XInternAtom(dpy, "ZUI_XDND_DATA", 0),
            .text_uri_list = api.XInternAtom(dpy, "text/uri-list", 0),
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
        self.compose = xkb.Compose.init();
        self.init_input_method();
        self.init_xinput();
        self.init_xrandr();
        self.init_xsync();
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
            if (!w.frame_wanted or w.closed or !w.visible) continue;
            const due: i32 = @intCast(@max(0, w.last_frame_ms + w.frame_interval_ms - now));
            best = if (best) |b| @min(b, due) else due;
        }
        // Wake up for reconnect attempts too, or an idle window would never make them.
        if (self.im_retries_left > 0) {
            const due: i32 = @intCast(@max(0, self.im_next_retry_ms - now));
            best = if (best) |b| @min(b, due) else due;
        }
        return best;
    }

    pub fn pump(self: *X11Connection) void {
        const now = input.now_ms();
        self.retry_input_method(now);
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            const w = self.windows.items[i];
            if (w.frame_wanted and !w.closed and w.visible and now - w.last_frame_ms >= w.frame_interval_ms) {
                w.frame_wanted = false;
                w.last_frame_ms = now;
                w.base.emit_request_frame(.{});
                // Whether or not the app had anything to draw, the frame for this size is done.
                w.acknowledge_sync();
            } else if (!w.visible and !w.closed) {
                // A window nobody can see must not make the window manager wait for it.
                w.acknowledge_sync();
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
        self.close_input_method();
        self.reset_drag();
        if (self.gpu_context) |ctx| ctx.destroy();
        for (self.cursors) |c| {
            if (c != 0) _ = self.api.XFreeCursor(self.display, c);
        }
        if (self.clip_offer) |c| self.allocator.free(c);
        if (self.clip_read) |c| self.allocator.free(c);
        if (self.primary_offer) |c| self.allocator.free(c);
        if (self.compose) |*c| c.deinit();
        _ = self.api.XDestroyWindow(self.display, self.helper);
        _ = self.api.XCloseDisplay(self.display);
        // Only now: these libraries register close hooks with Xlib, which XCloseDisplay calls.
        if (self.xi_lib) |*l| l.close();
        if (self.xrandr_lib) |*l| l.close();
        if (self.xext_lib) |*l| l.close();
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
        // Every window takes file drags. Whether an element wants them is decided later.
        var dnd_version: c_ulong = @intCast(xdnd_version);
        _ = a.XChangeProperty(self.display, x, self.atoms.xdnd_aware, proto.XA_ATOM, 32, 0, @ptrCast(&dnd_version), 1);
        var protocols = [3]Atom{ self.atoms.wm_delete_window, self.atoms.net_wm_ping, self.atoms.net_wm_sync_request };
        var protocol_count: c_int = 2;
        if (self.xsync_api) |sync| {
            w.sync_counter = sync.XSyncCreateCounter(self.display, .{ .hi = 0, .lo = 0 });
            if (w.sync_counter != 0) {
                var counter: c_ulong = w.sync_counter;
                _ = a.XChangeProperty(self.display, x, self.atoms.net_wm_sync_request_counter, proto.XA_CARDINAL, 32, 0, @ptrCast(&counter), 1);
                protocol_count = 3;
            }
        }
        _ = a.XSetWMProtocols(self.display, x, &protocols, protocol_count);
        if (options.titlebar == null) self.set_decorations(x, false);
        _ = a.XSelectInput(self.display, x, window_event_mask);
        self.select_xinput(x);
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
        // Windows report their cursor every frame; new windows apply it when created.
        if (style == self.cursor_style) return;
        self.cursor_style = style;
        for (self.windows.items) |w| w.apply_cursor();
        self.flush();
    }

    // -- events ----------------------------------------------------------

    fn translate(self: *X11Connection, ev_in: XEvent) void {
        var ev = ev_in;
        // Every event goes through the input method first: it talks to its server with
        // ordinary events, and takes the keys it wants. This includes the time with no
        // server, since Xlib learns of one starting from an event filtered here.
        if (self.xim_api) |x| {
            if (x.XFilterEvent(&ev, 0) != 0) return;
        }
        switch (ev.type) {
            proto.SelectionRequest => return self.serve_selection(ev.xselectionrequest),
            // The layout changed; Xlib keeps its old key map until told otherwise.
            proto.MappingNotify => {
                var mapping = ev.xmapping;
                _ = self.api.XRefreshKeyboardMapping(&mapping);
                return;
            },
            proto.SelectionClear => {
                self.selection_lost(ev.xselectionclear.selection);
                return;
            },
            proto.SelectionNotify => {
                if (ev.xselection.selection == self.atoms.xdnd_selection) self.on_drag_data(ev.xselection);
                return;
            },
            proto.GenericEvent => return self.on_generic_event(&ev),
            else => {},
        }
        if (self.xrandr_api) |x| {
            const kind = ev.type - self.xrandr_event_base;
            if (kind == proto.RRScreenChangeNotify or kind == proto.RRNotify) {
                _ = x.XRRUpdateConfiguration(&ev);
                self.refresh_crtcs();
                for (self.windows.items) |win| win.update_frame_interval();
                return;
            }
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
                if (self.on_drag_message(w, client)) return;
                if (client.message_type != self.atoms.wm_protocols) return;
                const kind: Atom = @intCast(client.data.l[0]);
                if (kind == self.atoms.net_wm_sync_request) {
                    w.pending_sync = .{
                        .lo = @truncate(@as(c_ulong, @bitCast(client.data.l[2]))),
                        .hi = @truncate(client.data.l[3]),
                    };
                    // The configure may not change the size, and the counter must still move.
                    w.frame_wanted = true;
                    return;
                }
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
                w.update_frame_interval();
            },
            proto.VisibilityNotify => {
                w.visible = ev.xvisibility.state != proto.VisibilityFullyObscured;
                if (w.visible) w.frame_wanted = true;
            },
            proto.MapNotify => {
                w.visible = true;
                w.frame_wanted = true;
            },
            proto.UnmapNotify => w.visible = false,
            proto.Expose => {
                if (ev.xexpose.count == 0) w.frame_wanted = true;
            },
            proto.FocusIn => {
                w.focused = true;
                w.sync_ic_focus();
                w.base.emit_active(true);
            },
            proto.FocusOut => {
                w.focused = false;
                w.sync_ic_focus();
                if (self.compose) |*c| c.cancel_preedit(&w.base);
                w.cancel_ic_composition();
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
        if (pressed) {
            if (self.compose) |*c| c.commit_preedit(&w.base);
            w.commit_ic_composition();
        }
        const pos = w.logical(b.x, b.y);
        const mods = input.modifiers(b.state);
        if (b.button >= 4 and b.button <= 7) {
            if (!pressed) return;
            const dx: f32 = switch (b.button) {
                6 => input.SCROLL_LINES,
                7 => -input.SCROLL_LINES,
                else => 0,
            };
            const dy: f32 = switch (b.button) {
                4 => input.SCROLL_LINES,
                5 => -input.SCROLL_LINES,
                else => 0,
            };
            self.emit_scroll(w, pos, .{ .x = dx, .y = dy }, mods);
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
        // Presses go through the input context when a field is composing with an IM, and
        // the IM has already handled dead keys, so xkb compose stays out of the way.
        const ic_active = pressed and w.ic != null and w.wants_ime;
        if (ic_active) {
            if (self.on_ic_key(w, &k, &keysym)) return;
        }
        const n: usize = @intCast(@max(0, self.api.XLookupString(&k, &buf, @intCast(buf.len), &keysym, null)));
        const shift = (ev.state & input.MOD_SHIFT) != 0;
        var name: ?[]const u8 = input.key_name_for_keysym(@intCast(keysym));
        if (name == null) {
            if (ev.keycode >= 8) {
                if (input.evdev_key(ev.keycode - 8, shift)) |info| name = info.name;
            }
        }
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
        var text: ?[]const u8 = if (text_len > 0) text_buf[0..text_len] else null;
        var composed_buf: [32]u8 = undefined;
        // With detectable auto-repeat a held key sends presses and no releases.
        const held = pressed and self.held_keycode == ev.keycode;
        if (pressed) {
            self.held_keycode = ev.keycode;
        } else if (self.held_keycode == ev.keycode) {
            self.held_keycode = 0;
        }
        var replaces_preedit = false;
        if (!ic_active and pressed and !held and keysym != 0 and !input.is_modifier_keysym(@intCast(keysym))) {
            if (self.compose) |*c| replaces_preedit = c.process_key(&w.base, @intCast(keysym), &composed_buf, &text, &name);
        }
        const key_name = name orelse return;
        w.emit_key(key_name, text, pressed, held);
        if (replaces_preedit) self.compose.?.finish_composed(&w.base);
    }

    // -- XInput2 -------------------------------------------------------------

    /// Asks for XInput2 pointer events, which carry smooth scrolling and fractional
    /// positions. Without libXi or XI 2.1 the core events keep working as they are.
    fn init_xinput(self: *X11Connection) void {
        var lib = dl.Library.open(&.{ "libXi.so.6", "libXi.so" }) orelse return;
        const x = proto.XiApi.load(lib) orelse {
            lib.close();
            return;
        };
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        var major: c_int = 2;
        var minor: c_int = 4;
        if (self.api.XQueryExtension(self.display, "XInputExtension", &self.xi_opcode, &event_base, &error_base) == 0 or
            x.XIQueryVersion(self.display, &major, &minor) != 0 or major < 2 or (major == 2 and minor < 1))
        {
            lib.close();
            return;
        }
        self.xi_lib = lib;
        self.xi_api = x;
        // The server answers with what it has: pinch needs 2.4.
        self.xi_has_gestures = major > 2 or minor >= 4;
        var hierarchy_bits: [2]u8 = @splat(0);
        set_mask_bit(&hierarchy_bits, proto.XI_HierarchyChanged);
        var mask: proto.XIEventMask = .{ .deviceid = proto.XIAllDevices, .mask_len = hierarchy_bits.len, .mask = &hierarchy_bits };
        _ = x.XISelectEvents(self.display, self.root, @ptrCast(&mask), 1);
        self.query_scroll_devices();
    }

    fn select_xinput(self: *X11Connection, window: XWindow) void {
        const x = self.xi_api orelse return;
        var bits: [4]u8 = @splat(0);
        for ([_]c_int{ proto.XI_Motion, proto.XI_ButtonPress, proto.XI_ButtonRelease, proto.XI_Enter, proto.XI_Leave, proto.XI_DeviceChanged }) |event| {
            set_mask_bit(&bits, event);
        }
        // An older server rejects a mask naming events it does not know.
        if (self.xi_has_gestures) {
            for ([_]c_int{ proto.XI_GesturePinchBegin, proto.XI_GesturePinchUpdate, proto.XI_GesturePinchEnd }) |event| {
                set_mask_bit(&bits, event);
            }
        }
        var mask: proto.XIEventMask = .{ .deviceid = proto.XIAllMasterDevices, .mask_len = if (self.xi_has_gestures) 4 else 2, .mask = &bits };
        _ = x.XISelectEvents(self.display, window, @ptrCast(&mask), 1);
    }

    fn set_mask_bit(bits: []u8, event: c_int) void {
        const e: usize = @intCast(event);
        bits[e / 8] |= @as(u8, 1) << @intCast(e % 8);
    }

    fn query_scroll_devices(self: *X11Connection) void {
        const x = self.xi_api orelse return;
        var count: c_int = 0;
        const infos = x.XIQueryDevice(self.display, proto.XIAllDevices, &count) orelse return;
        defer x.XIFreeDeviceInfo(infos);
        var devices: [x11_scroll.ScrollDevices.max_devices]x11_scroll.Device = undefined;
        var n: usize = 0;
        for (infos[0..@intCast(@max(count, 0))]) |info| {
            if (info.use != proto.XISlavePointer or n == devices.len) continue;
            var device: x11_scroll.Device = .{ .id = info.deviceid };
            const classes = info.classes orelse continue;
            for (classes[0..@intCast(@max(info.num_classes, 0))]) |class| {
                if (class.type != proto.XIScrollClass) continue;
                const scroll: *const proto.XIScrollClassInfo = @ptrCast(@alignCast(class));
                const axis = x11_scroll.make_axis(scroll.number, scroll.increment);
                if (scroll.scroll_type == proto.XIScrollTypeVertical) device.vertical = axis;
                if (scroll.scroll_type == proto.XIScrollTypeHorizontal) device.horizontal = axis;
            }
            if (device.vertical.valuator == null and device.horizontal.valuator == null) continue;
            devices[n] = device;
            n += 1;
        }
        self.scroll_devices.replace(devices[0..n]);
    }

    fn on_generic_event(self: *X11Connection, ev: *XEvent) void {
        if (self.xi_api == null or ev.xcookie.extension != self.xi_opcode) return;
        // A cookie's data is only available for the most recent event, so an event held
        // back during a clipboard wait comes up empty. It is dropped, which at worst loses
        // a motion: buttons there are rare, as the wait only lasts during a paste.
        if (self.api.XGetEventData(self.display, &ev.xcookie) == 0) return;
        defer self.api.XFreeEventData(self.display, &ev.xcookie);
        const data = ev.xcookie.data orelse return;
        switch (ev.xcookie.evtype) {
            proto.XI_Motion, proto.XI_ButtonPress, proto.XI_ButtonRelease => {
                const e: *const proto.XIDeviceEvent = @ptrCast(@alignCast(data));
                const w = self.find_window(e.event) orelse return;
                self.on_xi_device_event(w, e);
            },
            proto.XI_Enter, proto.XI_Leave => {
                const e: *const proto.XIEnterEvent = @ptrCast(@alignCast(data));
                // A position taken before leaving would turn into one huge scroll on return.
                self.scroll_devices.reset_all();
                // Grabs produce crossings too; the pointer did not really go anywhere.
                if (e.mode != proto.NotifyNormal) return;
                const w = self.find_window(e.event) orelse return;
                if (ev.xcookie.evtype == proto.XI_Enter) {
                    w.base.emit_hover(true);
                } else {
                    _ = w.base.emit_input(.{ .mouse_exited = .{
                        .position = w.logical_f(e.event_x, e.event_y),
                        .pressed_button = self.pressed,
                        .modifiers = input.modifiers(@bitCast(e.mods.effective)),
                    } });
                    w.base.emit_hover(false);
                }
            },
            // The physical device behind the pointer changed, and its axes with it.
            proto.XI_DeviceChanged => {
                self.query_scroll_devices();
                self.scroll_devices.reset_all();
            },
            proto.XI_HierarchyChanged => self.query_scroll_devices(),
            proto.XI_GesturePinchBegin, proto.XI_GesturePinchUpdate, proto.XI_GesturePinchEnd => {
                const e: *const proto.XIGesturePinchEvent = @ptrCast(@alignCast(data));
                const w = self.find_window(e.event) orelse return;
                const delta: f32, const phase: interactive.TouchPhase = switch (ev.xcookie.evtype) {
                    proto.XI_GesturePinchBegin => blk: {
                        self.pinch_scale = 1;
                        break :blk .{ 0, .started };
                    },
                    proto.XI_GesturePinchUpdate => blk: {
                        // Events carry the total scale, and ZUI wants the change.
                        const next: f32 = @floatCast(e.scale);
                        const change = next - self.pinch_scale;
                        self.pinch_scale = next;
                        break :blk .{ change, .moved };
                    },
                    else => .{ 0, .ended },
                };
                _ = w.base.emit_input(.{ .pinch = .{
                    .position = w.logical_f(e.event_x, e.event_y),
                    .delta = delta,
                    .modifiers = input.modifiers(@bitCast(e.mods.effective)),
                    .phase = phase,
                } });
            },
            else => {},
        }
    }

    fn on_xi_device_event(self: *X11Connection, w: *X11Window, e: *const proto.XIDeviceEvent) void {
        const state: c_uint = @bitCast(e.mods.effective);
        self.note_mods(state);
        const pos = w.logical_f(e.event_x, e.event_y);
        const mods = input.modifiers(state);
        switch (e.evtype) {
            proto.XI_Motion => {
                const mask = if (e.valuators.mask) |m| m[0..@intCast(@max(e.valuators.mask_len, 0))] else &[_]u8{};
                // Scrolling also arrives as motion: the pointer only moved if axis 0 or 1 did.
                if (mask.len > 0 and mask[0] & 3 != 0) {
                    _ = w.base.emit_input(.{ .mouse_move = .{ .position = pos, .pressed_button = self.pressed, .modifiers = mods } });
                }
                if (e.valuators.values) |values| {
                    const value_count = count_bits(mask);
                    if (self.scroll_devices.on_motion(e.sourceid, mask, values[0..value_count])) |delta| {
                        self.emit_scroll(w, pos, .{ .x = delta.x, .y = delta.y }, mods);
                    }
                }
            },
            proto.XI_ButtonPress, proto.XI_ButtonRelease => {
                // Wheels report through valuators and also as emulated buttons 4 to 7, for
                // old clients. Using both would scroll twice. Other emulated buttons come
                // from touch screens and are the only report of those presses.
                if (e.detail >= 4 and e.detail <= 7 and e.flags & proto.XIPointerEmulated != 0) return;
                var b = std.mem.zeroes(proto.XButtonEvent);
                b.x = @intFromFloat(std.math.clamp(@round(e.event_x), -1e9, 1e9));
                b.y = @intFromFloat(std.math.clamp(@round(e.event_y), -1e9, 1e9));
                b.x_root = @intFromFloat(std.math.clamp(@round(e.root_x), -1e9, 1e9));
                b.y_root = @intFromFloat(std.math.clamp(@round(e.root_y), -1e9, 1e9));
                b.state = state;
                b.button = @intCast(@max(e.detail, 0));
                self.on_button(w, b, e.evtype == proto.XI_ButtonPress);
            },
            else => {},
        }
    }

    fn count_bits(mask: []const u8) usize {
        var n: usize = 0;
        for (mask) |b| n += @popCount(b);
        return n;
    }

    /// Shift turns vertical scrolling horizontal, as in GPUI.
    fn emit_scroll(_: *X11Connection, w: *X11Window, pos: PxPoint, delta: x11_scroll.Delta, mods: input.Modifiers) void {
        const lines: x11_scroll.Delta = if (mods.shift) .{ .x = delta.y, .y = 0 } else delta;
        _ = w.base.emit_input(.{ .scroll_wheel = .{ .position = pos, .delta = .{ .lines = .{ .x = lines.x, .y = lines.y } }, .modifiers = mods } });
    }

    // -- RandR ----------------------------------------------------------------

    /// Learns each monitor's refresh rate, so animation runs at the display's real rate.
    fn init_xrandr(self: *X11Connection) void {
        var lib = dl.Library.open(&.{ "libXrandr.so.2", "libXrandr.so" }) orelse return;
        const x = proto.XrandrApi.load(lib) orelse {
            lib.close();
            return;
        };
        var error_base: c_int = 0;
        if (x.XRRQueryExtension(self.display, &self.xrandr_event_base, &error_base) == 0) {
            lib.close();
            return;
        }
        self.xrandr_lib = lib;
        self.xrandr_api = x;
        x.XRRSelectInput(self.display, self.root, proto.RRScreenChangeNotifyMask | proto.RRCrtcChangeNotifyMask);
        self.refresh_crtcs();
    }

    fn refresh_crtcs(self: *X11Connection) void {
        const x = self.xrandr_api orelse return;
        self.crtc_count = 0;
        const res = x.XRRGetScreenResourcesCurrent(self.display, self.root) orelse return;
        defer x.XRRFreeScreenResources(res);
        const crtcs = res.crtcs orelse return;
        const modes = res.modes orelse return;
        for (crtcs[0..@intCast(@max(res.ncrtc, 0))]) |crtc| {
            if (self.crtc_count == self.crtc_rates.len) break;
            const info = x.XRRGetCrtcInfo(self.display, res, crtc) orelse continue;
            defer x.XRRFreeCrtcInfo(info);
            if (info.mode == 0) continue; // Off.
            var interval = input.default_frame_interval_ms;
            for (modes[0..@intCast(@max(res.nmode, 0))]) |mode| {
                if (mode.id != info.mode) continue;
                interval = input.frame_interval_ms(mode.dotClock, mode.hTotal, mode.vTotal, mode.modeFlags);
                break;
            }
            self.crtc_rates[self.crtc_count] = .{ .x = info.x, .y = info.y, .w = @intCast(info.width), .h = @intCast(info.height), .interval_ms = interval };
            self.crtc_count += 1;
        }
    }

    /// The refresh interval of the monitor holding a root-relative point. Off every monitor,
    /// the fastest one wins, so nothing ends up slower than it needs to be.
    fn interval_at(self: *const X11Connection, x: c_int, y: c_int) i64 {
        var fastest: ?i64 = null;
        for (self.crtc_rates[0..self.crtc_count]) |c| {
            if (x >= c.x and y >= c.y and x < c.x + c.w and y < c.y + c.h) return c.interval_ms;
            fastest = if (fastest) |f| @min(f, c.interval_ms) else c.interval_ms;
        }
        return fastest orelse input.default_frame_interval_ms;
    }

    // -- XSync ----------------------------------------------------------------

    fn init_xsync(self: *X11Connection) void {
        var lib = dl.Library.open(&.{ "libXext.so.6", "libXext.so" }) orelse return;
        const x = proto.XsyncApi.load(lib) orelse {
            lib.close();
            return;
        };
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        var major: c_int = 0;
        var minor: c_int = 0;
        if (x.XSyncQueryExtension(self.display, &event_base, &error_base) == 0 or x.XSyncInitialize(self.display, &major, &minor) == 0) {
            lib.close();
            return;
        }
        self.xext_lib = lib;
        self.xsync_api = x;
    }

    // -- file drags (XDND) ----------------------------------------------------

    /// Handles an Xdnd client message. False means it was something else.
    fn on_drag_message(self: *X11Connection, w: *X11Window, client: proto.XClientMessageEvent) bool {
        const kind = client.message_type;
        const l = client.data.l;
        if (kind == self.atoms.xdnd_enter) {
            self.reset_drag();
            self.drag.source = @bitCast(l[0]);
            self.drag.window = w;
            self.drag.has_uri_list = self.source_offers_uri_list(l);
        } else if (kind == self.atoms.xdnd_position) {
            if (!self.is_drag_source(l[0]) or self.drag.window != w) return true;
            const root_pos: c_ulong = @bitCast(l[2]);
            var wx: c_int = 0;
            var wy: c_int = 0;
            var child: XWindow = 0;
            _ = self.api.XTranslateCoordinates(self.display, self.root, w.x_window, @intCast((root_pos >> 16) & 0xffff), @intCast(root_pos & 0xffff), &wx, &wy, &child);
            self.drag.position = w.logical(wx, wy);
            if (self.drag.has_uri_list and !self.drag.requested) {
                self.drag.requested = true;
                _ = self.api.XConvertSelection(self.display, self.atoms.xdnd_selection, self.atoms.text_uri_list, self.atoms.xdnd_data, w.x_window, @bitCast(l[3]));
            }
            if (self.drag.entered) {
                _ = w.base.emit_input(.{ .file_drop = .{ .pending = .{ .position = self.drag.position } } });
            }
            self.send_drag_message(self.atoms.xdnd_status, w.x_window, .{ @bitCast(w.x_window), if (self.drag.has_uri_list) 1 else 0, 0, 0, @bitCast(self.atoms.xdnd_action_copy) });
        } else if (kind == self.atoms.xdnd_leave) {
            if (!self.is_drag_source(l[0])) return true;
            if (self.drag.entered) _ = w.base.emit_input(.{ .file_drop = .exited });
            self.reset_drag();
        } else if (kind == self.atoms.xdnd_drop) {
            if (!self.is_drag_source(l[0])) return true;
            if (self.drag.entered) {
                self.finish_drag(w, true);
            } else if (self.drag.requested) {
                self.drag.drop_pending = true;
            } else {
                self.finish_drag(w, false);
            }
        } else {
            return false;
        }
        self.flush();
        return true;
    }

    fn is_drag_source(self: *const X11Connection, value: c_long) bool {
        return self.drag.source != 0 and self.drag.source == @as(XWindow, @bitCast(value));
    }

    /// Up to three types fit in the message; more are in a property on the source.
    fn source_offers_uri_list(self: *X11Connection, l: [5]c_long) bool {
        for (l[2..5]) |t| {
            if (@as(Atom, @bitCast(t)) == self.atoms.text_uri_list) return true;
        }
        if (@as(c_ulong, @bitCast(l[1])) & 1 == 0) return false;
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var prop: [*]u8 = undefined;
        const rc = self.api.XGetWindowProperty(self.display, @bitCast(l[0]), self.atoms.xdnd_type_list, 0, 1024, 0, proto.XA_ATOM, &actual_type, &actual_format, &nitems, &after, &prop);
        if (rc != 0 or actual_type != proto.XA_ATOM or actual_format != 32) return false;
        defer _ = self.api.XFree(prop);
        const atoms: [*]const c_ulong = @ptrCast(@alignCast(prop));
        for (atoms[0..@intCast(nitems)]) |t| {
            if (t == self.atoms.text_uri_list) return true;
        }
        return false;
    }

    /// The file list arrived. GPUI reads the first 4 KB of it, which truncates long
    /// selections, so this takes it all, up to 16 MB.
    fn on_drag_data(self: *X11Connection, note: proto.XSelectionEvent) void {
        const w = self.drag.window orelse return;
        if (note.requestor != w.x_window or self.drag.entered) return;
        if (note.property != 0) self.read_drag_paths(w);
        if (self.drag.paths.len > 0) {
            self.drag.entered = true;
            _ = w.base.emit_input(.{ .file_drop = .{ .entered = .{ .position = self.drag.position, .paths = .{ .items = self.drag.paths } } } });
        } else {
            self.drag.has_uri_list = false;
        }
        if (self.drag.drop_pending) self.finish_drag(w, self.drag.entered);
        self.flush();
    }

    fn read_drag_paths(self: *X11Connection, w: *X11Window) void {
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var prop: [*]u8 = undefined;
        const rc = self.api.XGetWindowProperty(self.display, w.x_window, self.atoms.xdnd_data, 0, 4 * 1024 * 1024, 1, 0, &actual_type, &actual_format, &nitems, &after, &prop);
        if (rc != 0 or actual_type == 0) return;
        defer _ = self.api.XFree(prop);
        // INCR means a list over the server's request limit, and is not worth supporting.
        if (actual_format != 8 or actual_type == self.atoms.incr) return;
        self.drag.paths = xdnd.parse_uri_list(self.allocator, prop[0..@intCast(nitems)]) catch &.{};
    }

    fn finish_drag(self: *X11Connection, w: *X11Window, accepted: bool) void {
        if (accepted) _ = w.base.emit_input(.{ .file_drop = .{ .submit = .{ .position = self.drag.position } } });
        self.send_drag_message(self.atoms.xdnd_finished, w.x_window, .{ @bitCast(w.x_window), if (accepted) 1 else 0, if (accepted) @bitCast(self.atoms.xdnd_action_copy) else 0, 0, 0 });
        self.reset_drag();
    }

    fn send_drag_message(self: *X11Connection, kind: Atom, _: XWindow, data: [5]c_long) void {
        var ev = std.mem.zeroes(XEvent);
        ev.xclient = std.mem.zeroes(proto.XClientMessageEvent);
        ev.xclient.type = proto.ClientMessage;
        ev.xclient.window = self.drag.source;
        ev.xclient.message_type = kind;
        ev.xclient.format = 32;
        ev.xclient.data.l = data;
        _ = self.api.XSendEvent(self.display, self.drag.source, 0, 0, &ev);
    }

    fn reset_drag(self: *X11Connection) void {
        if (self.drag.paths.len > 0) xdnd.free_paths(self.allocator, self.drag.paths);
        self.drag = .{};
    }

    // -- input method -------------------------------------------------------

    /// Connects to the input method named by XMODIFIERS. Without one there is no point in
    /// XIM: Xlib's built-in method only does compose, and xkb compose does that better,
    /// with the sequence showing inline. The locale is set only around the open, as SDL3
    /// does, so the application's number and date formatting stay untouched.
    fn init_input_method(self: *X11Connection) void {
        const mods = std.mem.span(std.c.getenv("XMODIFIERS") orelse return);
        const at = std.mem.indexOf(u8, mods, "@im=") orelse return;
        const name = mods[at + 4..];
        if (name.len == 0 or std.mem.startsWith(u8, name, "none") or std.mem.startsWith(u8, name, "local")) return;
        self.xim_api = proto.XimApi.load(self.lib) orelse return;
        self.open_im();
        // Also covers an IM that starts after us, or restarts.
        if (self.xim_api) |x| {
            self.im_callback_registered = x.XRegisterIMInstantiateCallback(self.display, null, null, null, @ptrCast(&imInstantiated), self) != 0;
        }
    }

    fn open_im(self: *X11Connection) void {
        const x = self.xim_api orelse return;
        if (self.im != null) return;
        var saved: [128]u8 = undefined;
        var saved_ptr: ?[*:0]const u8 = null;
        if (setlocale(LC_CTYPE, null)) |current| {
            const text = std.mem.span(current);
            if (text.len < saved.len) {
                @memcpy(saved[0..text.len], text);
                saved[text.len] = 0;
                saved_ptr = @ptrCast(&saved);
            }
        }
        _ = setlocale(LC_CTYPE, "");
        defer if (saved_ptr) |p| {
            _ = setlocale(LC_CTYPE, p);
        };
        if (x.XSupportsLocale() == 0) return;
        _ = x.XSetLocaleModifiers("");
        const im = x.XOpenIM(self.display, null, null, null) orelse return;

        var styles: ?*proto.XIMStyles = null;
        if (x.XGetIMValues(im, @as([*:0]const u8, "queryInputStyle"), &styles, @as(?*anyopaque, null)) != null or styles == null) {
            _ = x.XCloseIM(im);
            return;
        }
        defer _ = x.XFree(styles);
        var chosen: c_ulong = 0;
        for (styles.?.supported_styles[0..styles.?.count_styles]) |style| {
            if (style == (proto.XIMPreeditCallbacks | proto.XIMStatusNothing)) {
                chosen = style;
                break;
            }
            if (style == (proto.XIMPreeditNothing | proto.XIMStatusNothing)) chosen = style;
        }
        if (chosen == 0) {
            _ = x.XCloseIM(im);
            return;
        }
        var destroy: proto.XIMCallback = .{ .client_data = self, .callback = @ptrCast(&imDestroyed) };
        _ = x.XSetIMValues(im, @as([*:0]const u8, "destroyCallback"), &destroy, @as(?*anyopaque, null));
        self.im = im;
        self.im_style = chosen;
        // A restarted server finds fields already waiting: give them contexts and focus.
        for (self.windows.items) |w| {
            if (!w.wants_ime or w.closed) continue;
            w.ensure_ic();
            w.sync_ic_focus();
            if (w.base.ime_area()) |area| w.set_ime_spot(area);
        }
    }

    fn retry_input_method(self: *X11Connection, now: i64) void {
        if (self.im_retries_left == 0 or now < self.im_next_retry_ms) return;
        self.im_retries_left -= 1;
        self.im_next_retry_ms = now + im_retry_interval_ms;
        self.open_im();
        if (self.im != null) self.im_retries_left = 0;
    }

    fn close_input_method(self: *X11Connection) void {
        const x = self.xim_api orelse return;
        if (self.im_callback_registered) {
            _ = x.XUnregisterIMInstantiateCallback(self.display, null, null, null, @ptrCast(&imInstantiated), self);
        }
        if (self.im) |im| _ = x.XCloseIM(im);
        self.im = null;
    }

    fn imInstantiated(_: *proto.Display, client: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *X11Connection = @ptrCast(@alignCast(client.?));
        self.open_im();
    }

    /// The server went away. Xlib has already destroyed the contexts.
    fn imDestroyed(_: *proto.XIM, client: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *X11Connection = @ptrCast(@alignCast(client.?));
        self.im = null;
        self.im_retries_left = im_retry_count;
        self.im_next_retry_ms = input.now_ms() + im_retry_interval_ms;
        for (self.windows.items) |w| w.ic_lost();
    }

    /// Handles a press through the input context. True means nothing is left to do.
    /// False means the key has no text from the IM and takes the normal path.
    fn on_ic_key(self: *X11Connection, w: *X11Window, k: *proto.XKeyEvent, keysym: *c_ulong) bool {
        const x = self.xim_api.?;
        var stack: [256]u8 = undefined;
        var buf: []u8 = &stack;
        var status: c_int = 0;
        var n = x.Xutf8LookupString(w.ic.?, k, buf.ptr, @intCast(buf.len), keysym, &status);
        var heap: ?[]u8 = null;
        defer if (heap) |h| self.allocator.free(h);
        if (status == proto.XBufferOverflow) {
            heap = self.allocator.alloc(u8, @intCast(n + 1)) catch return true;
            buf = heap.?;
            n = x.Xutf8LookupString(w.ic.?, k, buf.ptr, @intCast(buf.len), keysym, &status);
        }
        if (status == proto.XLookupNone) return true;
        if (status == proto.XLookupKeySym) return false;
        const text = buf[0..@intCast(@max(n, 0))];
        if (text.len == 0) return status == proto.XLookupChars;
        // Commits from the IM carry no key. A real key with plain text takes the normal
        // path so bindings see it, which also looks up the same character again.
        if (status == proto.XLookupChars or k.keycode == 0) {
            w.ic_composition_ended();
            w.base.emit_ime(.{ .insert_text = text });
            return true;
        }
        return false;
    }

    // -- clipboard ----------------------------------------------------------

    pub fn set_clipboard(self: *X11Connection, text: []const u8) bool {
        const copy = self.allocator.dupe(u8, text) catch return false;
        if (self.clip_offer) |old| self.allocator.free(old);
        self.clip_offer = copy;
        self.owning_selection = self.claim_selection(self.atoms.clipboard);
        return self.owning_selection;
    }

    pub fn set_primary(self: *X11Connection, text: []const u8) bool {
        const copy = self.allocator.dupe(u8, text) catch return false;
        if (self.primary_offer) |old| self.allocator.free(old);
        self.primary_offer = copy;
        self.owning_primary = self.claim_selection(proto.XA_PRIMARY);
        return self.owning_primary;
    }

    fn claim_selection(self: *X11Connection, selection: Atom) bool {
        _ = self.api.XSetSelectionOwner(self.display, selection, self.helper, proto.CURRENT_TIME);
        const owned = self.api.XGetSelectionOwner(self.display, selection) == self.helper;
        self.flush();
        return owned;
    }

    fn selection_lost(self: *X11Connection, selection: Atom) void {
        if (selection == proto.XA_PRIMARY) {
            self.owning_primary = false;
        } else {
            self.owning_selection = false;
        }
    }

    /// Answers a paste request for text we own; anything else is refused.
    fn serve_selection(self: *X11Connection, req: proto.XSelectionRequestEvent) void {
        const is_primary = req.selection == proto.XA_PRIMARY;
        if (is_primary and !self.owning_primary) return;
        if (!is_primary and (req.selection != self.atoms.clipboard or !self.owning_selection)) return;
        var notify = std.mem.zeroes(proto.XSelectionEvent);
        notify.type = proto.SelectionNotify;
        notify.display = self.display;
        notify.requestor = req.requestor;
        notify.selection = req.selection;
        notify.target = req.target;
        notify.time = req.time;
        const text = (if (is_primary) self.primary_offer else self.clip_offer) orelse "";
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
        return self.request_selection(self.atoms.clipboard);
    }

    pub fn get_primary(self: *X11Connection) ?[]const u8 {
        if (self.owning_primary) return self.primary_offer;
        return self.request_selection(proto.XA_PRIMARY);
    }

    fn request_selection(self: *X11Connection, selection: Atom) ?[]const u8 {
        if (self.api.XGetSelectionOwner(self.display, selection) == 0) return null;
        _ = self.api.XConvertSelection(self.display, selection, self.atoms.utf8_string, self.atoms.paste, self.helper, proto.CURRENT_TIME);
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
                        // A drag's data can land in the middle of a paste.
                        if (note.selection == self.atoms.xdnd_selection) {
                            self.on_drag_data(note);
                            continue;
                        }
                        if (note.selection != selection or note.property == 0) return null;
                        return self.read_paste_property();
                    },
                    proto.SelectionRequest => self.serve_selection(ev.xselectionrequest),
                    proto.SelectionClear => self.selection_lost(ev.xselectionclear.selection),
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
    frame_interval_ms: i64 = input.default_frame_interval_ms,
    /// False while unmapped or fully covered: no frames then, as in GPUI.
    visible: bool = true,
    /// _NET_WM_SYNC_REQUEST: the window manager waits for this counter during resizes.
    sync_counter: c_ulong = 0,
    pending_sync: ?proto.XSyncValue = null,
    focused: bool = false,
    destroyed_by_server: bool = false,
    closed: bool = false,
    atlas: atlas_mod.CpuAtlas,
    renderer: cpu.CpuRenderer,
    /// Set when this window draws with the GPU; `atlas` and `renderer` then stay idle.
    gpu_window: ?window_renderer.GpuWindow = null,
    /// A focused field in this window accepts text.
    wants_ime: bool = false,
    ic: ?*proto.XIC = null,
    /// Stable storage: Xlib keeps pointers into these for the context's lifetime.
    ic_callbacks: [4]proto.XIMCallback = undefined,
    preedit: ?xim_preedit.XimPreedit = null,
    ime_spot: ?[2]i16 = null,

    fn playSystemBell(p: *platform.PlatformWindow) void {
        const conn = from(p).conn;
        _ = conn.api.XBell(conn.display, 0);
        conn.flush();
    }

    const vtable: platform.PlatformWindow.VTable = .{
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
        .start_window_move = startWindowMove,
        .resize = resize,
        .close = close,
    };

    pub fn from(p: *platform.PlatformWindow) *X11Window {
        return @fieldParentPtr("base", p);
    }

    /// Logical point from physical window coordinates.
    fn logical_f(self: *const X11Window, x: f64, y: f64) PxPoint {
        return .{ .x = @as(f32, @floatCast(x)) / self.scale, .y = @as(f32, @floatCast(y)) / self.scale };
    }

    /// Tells the window manager the frame for its last configure is finished. GPUI does
    /// this when the configure arrives, which lets the frame tear; this waits for the draw.
    fn acknowledge_sync(self: *X11Window) void {
        const value = self.pending_sync orelse return;
        self.pending_sync = null;
        const sync = self.conn.xsync_api orelse return;
        if (self.sync_counter == 0) return;
        _ = sync.XSyncSetCounter(self.conn.display, self.sync_counter, value);
        self.conn.flush();
    }

    /// Follows the monitor under the window's center. One monitor needs no round trip.
    fn update_frame_interval(self: *X11Window) void {
        const conn = self.conn;
        if (conn.crtc_count == 0 or self.closed or self.destroyed_by_server) return;
        if (conn.crtc_count == 1) {
            self.frame_interval_ms = conn.crtc_rates[0].interval_ms;
            return;
        }
        const dims = self.physical();
        var rx: c_int = 0;
        var ry: c_int = 0;
        var child: XWindow = 0;
        if (conn.api.XTranslateCoordinates(conn.display, self.x_window, conn.root, @intCast(dims.w / 2), @intCast(dims.h / 2), &rx, &ry, &child) == 0) return;
        self.frame_interval_ms = conn.interval_at(rx, ry);
    }

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
    fn updateImeEnabled(p: *platform.PlatformWindow, enabled: bool) void {
        const self = from(p);
        self.wants_ime = enabled;
        if (enabled) self.ensure_ic();
        self.sync_ic_focus();
        if (!enabled) self.cancel_ic_composition();
        if (enabled) if (self.base.ime_area()) |area| self.set_ime_spot(area);
        self.conn.flush();
    }

    fn updateImePosition(p: *platform.PlatformWindow, area: PxBounds) void {
        from(p).set_ime_spot(area);
    }

    /// Candidate windows open below the point. Skipped while composing, so they stay put
    /// while the user chooses.
    fn set_ime_spot(self: *X11Window, area: PxBounds) void {
        const x = self.conn.xim_api orelse return;
        const ic = self.ic orelse return;
        if (self.preedit) |*pre| if (!pre.is_empty()) return;
        const spot: [2]i16 = .{
            @intFromFloat(std.math.clamp(@round(area.origin.x * self.scale), -32768, 32767)),
            @intFromFloat(std.math.clamp(@round((area.origin.y + area.size.height) * self.scale), -32768, 32767)),
        };
        if (self.ime_spot) |old| if (old[0] == spot[0] and old[1] == spot[1]) return;
        self.ime_spot = spot;
        var point: proto.XPointS = .{ .x = spot[0], .y = spot[1] };
        const list = x.XVaCreateNestedList(0, @as([*:0]const u8, "spotLocation"), &point, @as(?*anyopaque, null)) orelse return;
        defer _ = x.XFree(list);
        _ = x.XSetICValues(ic, @as([*:0]const u8, "preeditAttributes"), list, @as(?*anyopaque, null));
        self.conn.flush();
    }

    /// Creates the input context on first use, and subscribes to what the IM asks for.
    fn ensure_ic(self: *X11Window) void {
        if (self.ic != null or self.closed) return;
        const conn = self.conn;
        const x = conn.xim_api orelse return;
        const im = conn.im orelse return;
        const client: c_ulong = self.x_window;
        const style = conn.im_style;
        const client_name: [*:0]const u8 = "clientWindow";
        const focus_name: [*:0]const u8 = "focusWindow";
        const style_name: [*:0]const u8 = "inputStyle";
        const end: ?*anyopaque = null;
        if (style & proto.XIMPreeditCallbacks != 0) {
            self.ic_callbacks = .{
                .{ .client_data = self, .callback = @ptrCast(&preeditStart) },
                .{ .client_data = self, .callback = @ptrCast(&preeditDone) },
                .{ .client_data = self, .callback = @ptrCast(&preeditDraw) },
                .{ .client_data = self, .callback = @ptrCast(&preeditCaret) },
            };
            const list = x.XVaCreateNestedList(
                0,
                @as([*:0]const u8, "preeditStartCallback"),
                &self.ic_callbacks[0],
                @as([*:0]const u8, "preeditDoneCallback"),
                &self.ic_callbacks[1],
                @as([*:0]const u8, "preeditDrawCallback"),
                &self.ic_callbacks[2],
                @as([*:0]const u8, "preeditCaretCallback"),
                &self.ic_callbacks[3],
                end,
            ) orelse return;
            defer _ = x.XFree(list);
            self.ic = x.XCreateIC(im, style_name, style, client_name, client, focus_name, client, @as([*:0]const u8, "preeditAttributes"), list, end);
        } else {
            self.ic = x.XCreateIC(im, style_name, style, client_name, client, focus_name, client, end);
        }
        const ic = self.ic orelse return;
        var filter: c_long = 0;
        if (x.XGetICValues(ic, @as([*:0]const u8, "filterEvents"), &filter, end) == null and filter != 0) {
            _ = conn.api.XSelectInput(conn.display, self.x_window, window_event_mask | filter);
        }
        if (self.preedit == null) self.preedit = .{ .allocator = self.allocator };
    }

    fn sync_ic_focus(self: *X11Window) void {
        const x = self.conn.xim_api orelse return;
        const ic = self.ic orelse return;
        if (self.wants_ime and self.focused) x.XSetICFocus(ic) else x.XUnsetICFocus(ic);
    }

    /// Ends a composition: the IM forgets it, and the field drops the text.
    fn cancel_ic_composition(self: *X11Window) void {
        const pre = if (self.preedit) |*p| p else return;
        if (pre.is_empty()) return;
        pre.clear();
        self.reset_ic();
        self.base.emit_ime(.delete_text);
    }

    /// Ends a composition, keeping its text in the field. A click does this.
    pub fn commit_ic_composition(self: *X11Window) void {
        const pre = if (self.preedit) |*p| p else return;
        if (pre.is_empty()) return;
        pre.clear();
        self.reset_ic();
        self.base.emit_ime(.unmark_text);
    }

    fn reset_ic(self: *X11Window) void {
        const x = self.conn.xim_api orelse return;
        const ic = self.ic orelse return;
        if (x.Xutf8ResetIC(ic)) |text| _ = x.XFree(text);
    }

    /// The next commit replaces the composition in the field, so only our copy clears here.
    fn ic_composition_ended(self: *X11Window) void {
        if (self.preedit) |*p| p.clear();
    }

    /// The IM went away: anything composing cannot finish, so it goes too.
    fn ic_lost(self: *X11Window) void {
        self.ic = null;
        self.ime_spot = null;
        if (self.preedit) |*pre| {
            if (!pre.is_empty()) {
                pre.clear();
                self.base.emit_ime(.delete_text);
            }
        }
    }

    fn preeditStart(_: *proto.XIC, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        return -1; // No limit on the composition's length.
    }

    fn preeditDone(_: *proto.XIC, client: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *X11Window = @ptrCast(@alignCast(client.?));
        const pre = if (self.preedit) |*p| p else return;
        if (pre.is_empty()) return;
        pre.clear();
        self.base.emit_ime(.delete_text);
    }

    fn preeditDraw(_: *proto.XIC, client: ?*anyopaque, data: *proto.XIMPreeditDrawCallbackStruct) callconv(.c) void {
        const self: *X11Window = @ptrCast(@alignCast(client.?));
        const pre = if (self.preedit) |*p| p else return;
        const had = !pre.is_empty();
        var insert: ?[]const u8 = null;
        var wide_buf: std.ArrayList(u8) = .empty;
        defer wide_buf.deinit(self.allocator);
        if (data.text) |t| {
            if (t.encoding_is_wchar != 0) {
                // Length counts characters here; UTF-8 text gets its own length below.
                if (t.string.wide_char) |wide| {
                    for (wide[0..t.length]) |c| {
                        var enc: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(@max(c, 0)), &enc) catch continue;
                        wide_buf.appendSlice(self.allocator, enc[0..len]) catch break;
                    }
                }
                insert = wide_buf.items;
            } else if (t.string.multi_byte) |mb| {
                // Input methods misreport `length`, as SDL3 found. The string is terminated.
                insert = std.mem.span(mb);
            }
        }
        pre.apply(data.chg_first, data.chg_length, insert, data.caret);
        if (pre.is_empty()) {
            if (had) self.base.emit_ime(.delete_text);
        } else {
            self.base.emit_ime(.{ .set_marked_text = .{ .text = pre.text.items, .selected = pre.selected() } });
        }
    }

    fn preeditCaret(_: *proto.XIC, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

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
        if (self.ic) |ic| {
            if (self.conn.xim_api) |x| x.XDestroyIC(ic);
            self.ic = null;
        }
        if (self.conn.drag.window == self) self.conn.reset_drag();
        if (self.sync_counter != 0) {
            if (self.conn.xsync_api) |sync| _ = sync.XSyncDestroyCounter(self.conn.display, self.sync_counter);
            self.sync_counter = 0;
        }
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
        if (self.preedit) |*p| p.deinit();
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
