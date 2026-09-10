//! Win32 backend: user32 message pump, GDI software present, clipboard.
//!
//! Window class registration, `CreateWindowExW`, a `PeekMessageW` pump
//! mapping `WM_*` to normalized events (`WM_CHAR` UTF-16 is the text path,
//! like X11's `XLookupString`), DIB-section software presentation, system
//! clipboard, and cursors. Only Windows constructs it (`isAvailable()` is
//! false elsewhere).

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const bindings = @import("bindings.zig");
const event = @import("../event.zig");
const geometry = @import("../../core/geometry.zig");
const limits = @import("../../core/limits.zig");
const gpu = @import("../../gpu/root.zig");
const dl = @import("../dl.zig");

const b = bindings;

/// Virtual-key → normalized key. Pure for testability. Values are the
/// stable WinUser.h ABI.
fn vkToKey(vk: u32) event.Key {
    return switch (vk) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .home, // page up has no normalized key; nearest nav key
        0x22 => .end, // page down likewise
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x2D => .unknown, // insert: no normalized key
        0x2E => .delete,
        0x30 => .n0,
        0x31 => .n1,
        0x32 => .n2,
        0x33 => .n3,
        0x34 => .n4,
        0x35 => .n5,
        0x36 => .n6,
        0x37 => .n7,
        0x38 => .n8,
        0x39 => .n9,
        0x41 => .a,
        0x42 => .b,
        0x43 => .c,
        0x44 => .d,
        0x45 => .e,
        0x46 => .f,
        0x47 => .g,
        0x48 => .h,
        0x49 => .i,
        0x4A => .j,
        0x4B => .k,
        0x4C => .l,
        0x4D => .m,
        0x4E => .n,
        0x4F => .o,
        0x50 => .p,
        0x51 => .q,
        0x52 => .r,
        0x53 => .s,
        0x54 => .t,
        0x55 => .u,
        0x56 => .v,
        0x57 => .w,
        0x58 => .x,
        0x59 => .y,
        0x5A => .z,
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        else => .unknown,
    };
}

/// One UTF-16 unit (plus optional lead surrogate state) → UTF-8 bytes in
/// `out`. Returns bytes written; stores an unmatched lead for the next
/// call. Pure for testability.
fn utf16UnitToUtf8(unit: u16, lead: *?u16, out: []u8) usize {
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        lead.* = unit;
        return 0;
    }
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        if (lead.*) |hi| {
            lead.* = null;
            const cp: u21 = 0x10000 + (@as(u21, hi - 0xD800) << 10) + (unit - 0xDC00);
            return std.unicode.utf8Encode(cp, out) catch 0;
        }
        return 0; // stray trail surrogate: drop
    }
    lead.* = null;
    return std.unicode.utf8Encode(unit, out) catch 0;
}

/// Encode UTF-8 as UTF-16 units (for SetWindowTextW / clipboard offers).
/// Returns units written, excluding the NUL terminator always appended
/// when room allows.
fn utf8ToUtf16(text: []const u8, out: []u16) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n + 1 < out.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..@min(i + seq_len, text.len)]) catch {
            i += 1;
            continue;
        };
        i += seq_len;
        if (cp < 0x10000) {
            out[n] = @intCast(cp);
            n += 1;
        } else if (n + 2 < out.len) {
            const v = cp - 0x10000;
            out[n] = @intCast(0xD800 + (v >> 10));
            out[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
    }
    if (n < out.len) out[n] = 0;
    return n;
}

fn modifiersFromWparam(wparam: b.WPARAM) event.Modifiers {
    return .{
        .shift = wparam & b.MK_SHIFT != 0,
        .ctrl = wparam & b.MK_CONTROL != 0,
        .alt = false, // Alt arrives via SYSKEY messages; tracked below
        .super = false,
    };
}

pub const Win32Backend = struct {
    allocator: std.mem.Allocator,
    user32: dl.Library,
    kernel32: dl.Library,
    gdi32: dl.Library,
    api: b.User32Api,
    kernel: b.KernelApi,
    gdi: b.GdiApi,
    hwnd: b.HWND,
    class_atom: b.ATOM,
    instance: b.HINSTANCE,
    mem_dc: ?*anyopaque = null,
    dib_section: ?*anyopaque = null,
    dib_bits: ?*anyopaque = null,
    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1.0,
    focused: bool = true,
    presents: u32 = 0,
    wakeups: u32 = 0,
    pixels: []u8,
    cursor_shape: backend.CursorShape = .default,
    decorated: bool = true,
    cursor: b.HCURSOR = null,
    alt_held: bool = false,
    wheel_remainder: i32 = 0,
    utf16_lead: ?u16 = null,
    title_utf16: [256]u16 = std.mem.zeroes([256]u16),
    target_queue: ?*event.EventQueue = null,
    debug_events: bool = false,

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

    /// File-scope active backend for the window procedure (single native
    /// window per backend, matching the Wayland/X11 structs).
    var active: ?*Win32Backend = null;

    pub fn isAvailable() bool {
        return builtin.os.tag == .windows;
    }

    fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
        if (!builtin.link_libc) return null;
        return std.c.getenv(name);
    }

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !*Win32Backend {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var user32 = dl.Library.open(&.{"user32.dll"}) orelse return error.LibraryNotFound;
        errdefer user32.close();
        var kernel32 = dl.Library.open(&.{"kernel32.dll"}) orelse return error.LibraryNotFound;
        errdefer kernel32.close();
        var gdi32 = dl.Library.open(&.{"gdi32.dll"}) orelse return error.LibraryNotFound;
        errdefer gdi32.close();
        var api = b.User32Api.load(user32) orelse return error.MissingSymbols;
        api.GetDpiForWindow = user32.lookup(@FieldType(b.User32Api, "GetDpiForWindow"), "GetDpiForWindow");
        const kernel = b.KernelApi.load(kernel32) orelse return error.MissingSymbols;
        const gdi = b.GdiApi.load(gdi32) orelse return error.MissingSymbols;

        const instance = api.GetModuleHandleW(null);
        const class_name = [_:0]u16{ 'Z', 'U', 'I', 'W', 'i', 'n', 'd', 'o', 'w', 0 };
        const wc = b.WNDCLASSEXW{
            .cbSize = @sizeOf(b.WNDCLASSEXW),
            .style = b.CS_HREDRAW | b.CS_VREDRAW | b.CS_OWNDC,
            .lpfnWndProc = @ptrCast(&wndProc),
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = null, // we manage the cursor via WM_SETCURSOR
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = &class_name,
            .hIconSm = null,
        };
        const atom = api.RegisterClassExW(&wc);
        if (atom == 0) return error.RegisterClassFailed;

        // Client area, not window frame, gets the requested size.
        var rect = b.RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        _ = api.AdjustWindowRect(&rect, b.WS_OVERLAPPEDWINDOW | b.WS_VISIBLE, 0);

        const self = try allocator.create(Win32Backend);
        errdefer allocator.destroy(self);
        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

        self.* = .{
            .allocator = allocator,
            .user32 = user32,
            .kernel32 = kernel32,
            .gdi32 = gdi32,
            .api = api,
            .kernel = kernel,
            .gdi = gdi,
            .hwnd = null,
            .class_atom = atom,
            .instance = instance,
            .pixels = pixels,
            .debug_events = getenv("ZUI_DEBUG_EVENTS") != null,
        };
        active = self;

        const hwnd = api.CreateWindowExW(0, &class_name, title, b.WS_OVERLAPPEDWINDOW | b.WS_VISIBLE, 100, 100, rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null);
        if (hwnd == null) {
            active = null;
            return error.CreateWindowFailed;
        }
        self.hwnd = hwnd;
        _ = api.SetWindowLongPtrW(hwnd, b.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        _ = api.ShowWindow(hwnd, b.SW_SHOW);
        // Per-monitor DPI when available (Win10+); 96 → scale 1 otherwise.
        if (api.GetDpiForWindow) |dpiFn| {
            const dpi = dpiFn(hwnd);
            if (dpi > 0) self.scale_factor = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
        self.recreateDib();
        return self;
    }

    pub fn deinit(self: *Win32Backend) void {
        if (active == self) active = null;
        self.destroyDib();
        if (self.hwnd) |hwnd| {
            _ = self.api.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        _ = self.api.UnregisterClassW(&[_:0]u16{ 'Z', 'U', 'I', 'W', 'i', 'n', 'd', 'o', 'w', 0 }, self.instance);
        self.allocator.free(self.pixels);
        self.user32.close();
        self.kernel32.close();
        self.gdi32.close();
        self.allocator.destroy(self);
    }

    pub fn backendHandle(self: *Win32Backend) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recreateDib(self: *Win32Backend) void {
        self.destroyDib();
        const w: u32 = @intFromFloat(self.size.w);
        const h: u32 = @intFromFloat(self.size.h);
        if (w == 0 or h == 0 or self.hwnd == null) return;
        var info = std.mem.zeroes(b.BITMAPINFO);
        info.header.biSize = @sizeOf(b.BITMAPINFOHEADER);
        info.header.biWidth = @intCast(w);
        info.header.biHeight = -@as(i32, @intCast(h)); // top-down
        info.header.biPlanes = 1;
        info.header.biBitCount = 32;
        info.header.biCompression = b.BI_RGB;
        const hdc = self.api.GetDC(self.hwnd);
        if (hdc == null) return;
        defer _ = self.api.ReleaseDC(self.hwnd, hdc);
        var bits: ?*anyopaque = null;
        const section = self.gdi.CreateDIBSection(hdc, &info, b.DIB_RGB_COLORS, &bits, null, 0);
        if (section == null or bits == null) return;
        const mem_dc = self.gdi.CreateCompatibleDC(hdc);
        if (mem_dc == null) {
            _ = self.gdi.DeleteObject(section);
            return;
        }
        _ = self.gdi.SelectObject(mem_dc, section);
        self.mem_dc = mem_dc;
        self.dib_section = section;
        self.dib_bits = bits;
    }

    fn destroyDib(self: *Win32Backend) void {
        if (self.mem_dc) |dc| {
            _ = self.gdi.DeleteDC(dc);
            self.mem_dc = null;
        }
        if (self.dib_section) |s| {
            _ = self.gdi.DeleteObject(s);
            self.dib_section = null;
            self.dib_bits = null;
        }
    }

    fn pushEvent(self: *Win32Backend, ev: event.Event) void {
        if (self.target_queue) |q| {
            _ = q.push(ev);
        }
    }

    fn clientPos(lparam: b.LPARAM) geometry.Point {
        const x: i16 = @truncate(lparam);
        const y: i16 = @truncate(lparam >> 16);
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }

    // -- window procedure ----------------------------------------------

    fn wndProc(hwnd: b.HWND, msg: b.UINT, wparam: b.WPARAM, lparam: b.LPARAM) callconv(.c) b.LRESULT {
        const self = active;
        // Route to the backend before any translation; DefWindowProc owns
        // everything we don't explicitly handle.
        switch (msg) {
            b.WM_CLOSE => {
                if (self) |s| s.pushEvent(.{ .window = .close_requested });
                return 0;
            },
            b.WM_SIZE => {
                if (self) |s| {
                    const w: u32 = @intCast(lparam & 0xFFFF);
                    const h: u32 = @intCast((lparam >> 16) & 0xFFFF);
                    if (w > 0 and h > 0 and (@as(f32, @floatFromInt(w)) != s.size.w or @as(f32, @floatFromInt(h)) != s.size.h)) {
                        s.size.w = @floatFromInt(w);
                        s.size.h = @floatFromInt(h);
                        const npx = @as(usize, w) * h * 4;
                        if (npx != s.pixels.len) {
                            if (s.allocator.realloc(s.pixels, npx)) |buf| {
                                s.pixels = buf;
                                s.recreateDib();
                            } else |_| {}
                        }
                        s.pushEvent(.{ .window = .resized });
                    }
                }
                return 0;
            },
            b.WM_SETFOCUS => {
                if (self) |s| {
                    s.focused = true;
                    s.pushEvent(.{ .window = .focused });
                }
                return 0;
            },
            b.WM_KILLFOCUS => {
                if (self) |s| {
                    s.focused = false;
                    s.pushEvent(.{ .window = .unfocused });
                }
                return 0;
            },
            b.WM_SETCURSOR => {
                if (self) |s| {
                    s.applyCursor();
                    return 1;
                }
                return 0;
            },
            b.WM_KEYDOWN, b.WM_SYSKEYDOWN => {
                if (self) |s| {
                    const vk: u32 = @truncate(wparam);
                    const repeat = (lparam >> 30) & 1 == 1;
                    if (vk == b.VK_MENU) s.alt_held = true;
                    var mods = modifiersFromWparam(wparam);
                    mods.alt = s.alt_held;
                    s.pushEvent(.{ .key = .{ .key = vkToKey(vk), .pressed = true, .modifiers = mods, .repeat = repeat } });
                }
                return 0;
            },
            b.WM_KEYUP, b.WM_SYSKEYUP => {
                if (self) |s| {
                    const vk: u32 = @truncate(wparam);
                    if (vk == b.VK_MENU) s.alt_held = false;
                    var mods = modifiersFromWparam(wparam);
                    mods.alt = s.alt_held;
                    s.pushEvent(.{ .key = .{ .key = vkToKey(vk), .pressed = false, .modifiers = mods } });
                }
                return 0;
            },
            b.WM_CHAR => {
                if (self) |s| {
                    const unit: u16 = @truncate(wparam);
                    // Control characters are actions (.key covers them).
                    if (unit < 0x20 and unit != '\t') return 0;
                    var buf: [4]u8 = undefined;
                    const n = utf16UnitToUtf8(unit, &s.utf16_lead, &buf);
                    if (n > 0) {
                        var text_ev = event.TextEvent{};
                        @memcpy(text_ev.text[0..n], buf[0..n]);
                        text_ev.len = @intCast(n);
                        s.pushEvent(.{ .text = text_ev });
                    }
                }
                return 0;
            },
            b.WM_LBUTTONDOWN => {
                if (self) |s| {
                    _ = s.api.SetCapture(s.hwnd);
                    s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .left, .pressed = true, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                }
                return 0;
            },
            b.WM_LBUTTONUP => {
                if (self) |s| {
                    _ = s.api.ReleaseCapture();
                    s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .left, .pressed = false, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                }
                return 0;
            },
            b.WM_RBUTTONDOWN => {
                if (self) |s| s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .right, .pressed = true, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                return 0;
            },
            b.WM_RBUTTONUP => {
                if (self) |s| s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .right, .pressed = false, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                return 0;
            },
            b.WM_MBUTTONDOWN => {
                if (self) |s| s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .middle, .pressed = true, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                return 0;
            },
            b.WM_MBUTTONUP => {
                if (self) |s| s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .middle, .pressed = false, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                return 0;
            },
            b.WM_MOUSEMOVE => {
                if (self) |s| s.pushEvent(.{ .mouse = .{ .pos = clientPos(lparam), .button = .left, .pressed = false, .modifiers = modifiersFromWparam(wparam), .time_ms = timeMs() } });
                return 0;
            },
            b.WM_MOUSEWHEEL, b.WM_MOUSEHWHEEL => {
                if (self) |s| {
                    const delta: i16 = @truncate(wparam >> 16);
                    s.wheel_remainder += delta;
                    const lines = @divTrunc(s.wheel_remainder, @as(i32, b.WHEEL_DELTA));
                    s.wheel_remainder -= lines * @as(i32, b.WHEEL_DELTA);
                    if (lines != 0) {
                        const f: f32 = @floatFromInt(lines);
                        s.pushEvent(.{ .scroll = .{
                            .pos = clientPos(lparam),
                            .dx = if (msg == b.WM_MOUSEHWHEEL) f else 0,
                            .dy = if (msg == b.WM_MOUSEHWHEEL) 0 else f,
                            .modifiers = modifiersFromWparam(wparam),
                        } });
                    }
                }
                return 0;
            },
            b.WM_PAINT => {
                // Re-blit the backbuffer (occlusion/restore repaints).
                if (self) |s| s.blitBackbuffer();
                return 0;
            },
            b.WM_NCHITTEST => {
                // Frameless edge resize: map an 8px border to hit codes so
                // the OS runs the modal resize loop natively. Decorated
                // windows fall through to DefWindowProc below.
                if (self) |s| {
                    if (!s.decorated) {
                        if (s.hitResizeEdge(lparam)) |code| return code;
                        return b.HTCLIENT;
                    }
                }
            },
            else => {},
        }
        if (self) |s| return s.api.DefWindowProcW(hwnd, msg, wparam, lparam);
        return 0;
    }

    fn timeMs() i64 {
        return @divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms);
    }

    /// Pure frameless border hit-test: 8px edges map to resize codes.
    fn hitEdge(rect_l: i32, rect_t: i32, rect_r: i32, rect_b: i32, x: i32, y: i32) ?backend.ResizeEdge {
        const border: i32 = 8;
        const near_left = x >= rect_l and x < rect_l + border;
        const near_right = x < rect_r and x >= rect_r - border;
        const near_top = y >= rect_t and y < rect_t + border;
        const near_bottom = y < rect_b and y >= rect_b - border;
        if (near_top and near_left) return .top_left;
        if (near_top and near_right) return .top_right;
        if (near_bottom and near_left) return .bottom_left;
        if (near_bottom and near_right) return .bottom_right;
        if (near_top) return .top;
        if (near_bottom) return .bottom;
        if (near_left) return .left;
        if (near_right) return .right;
        return null;
    }

    fn hitCodeForEdge(edge: backend.ResizeEdge) b.LRESULT {
        return switch (edge) {
            .top_left => b.HTTOPLEFT,
            .top => b.HTTOP,
            .top_right => b.HTTOPRIGHT,
            .right => b.HTRIGHT,
            .bottom_right => b.HTBOTTOMRIGHT,
            .bottom => b.HTBOTTOM,
            .bottom_left => b.HTBOTTOMLEFT,
            .left => b.HTLEFT,
        };
    }

    fn hitResizeEdge(self: *Win32Backend, lparam: b.LPARAM) ?b.LRESULT {
        const hwnd = self.hwnd orelse return null;
        var rect: b.RECT = undefined;
        if (self.api.GetWindowRect(hwnd, &rect) == 0) return null;
        const x: i32 = @truncate(lparam);
        const y: i32 = @truncate(lparam >> 16);
        const edge = hitEdge(rect.left, rect.top, rect.right, rect.bottom, x, y) orelse return null;
        return hitCodeForEdge(edge);
    }
    fn blitBackbuffer(self: *Win32Backend) void {
        const hwnd = self.hwnd orelse return;
        const dc = self.mem_dc orelse return;
        const hdc = self.api.GetDC(hwnd);
        if (hdc == null) return;
        defer _ = self.api.ReleaseDC(hwnd, hdc);
        const w: c_int = @intFromFloat(self.size.w);
        const h: c_int = @intFromFloat(self.size.h);
        _ = self.gdi.BitBlt(hdc, 0, 0, w, h, dc, 0, 0, b.SRCCOPY);
    }

    fn applyCursor(self: *Win32Backend) void {
        const idc: u16 = switch (self.cursor_shape) {
            .default => b.IDC_ARROW,
            .text => b.IDC_IBEAM,
            .pointer => b.IDC_HAND,
        };
        const cursor = self.api.LoadCursorW(null, @ptrFromInt(@as(usize, idc)));
        self.cursor = cursor;
        _ = self.api.SetCursor(cursor);
    }

    // -- vtable ----------------------------------------------------------

    fn kindFn(_: *anyopaque) backend.BackendKind {
        return .win32;
    }

    fn pollFn(ptr: *anyopaque, out: *event.EventQueue) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.target_queue = out;
        var msg: b.MSG = undefined;
        while (self.api.PeekMessageW(&msg, null, 0, 0, b.PM_REMOVE) != 0) {
            _ = self.api.TranslateMessage(&msg);
            _ = self.api.DispatchMessageW(&msg);
        }
    }

    fn waitFn(ptr: *anyopaque, ns: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        // Sleep until input; without MsgWaitForMultipleObjects linked, a
        // bounded sleep keeps idle near zero (same tradeoff as the yield
        // guards on Wayland/X11).
        self.kernel.Sleep(@intCast(@min(ns / 1_000_000, 4)));
    }

    fn wakeupFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.wakeups += 1;
    }

    fn infoFn(ptr: *anyopaque) backend.WindowInfo {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{ .size = self.size, .scale_factor = self.scale_factor, .focused = self.focused };
    }

    fn titleFn(ptr: *anyopaque, title: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const n = utf8ToUtf16(title, &self.title_utf16);
        _ = n;
        if (self.hwnd) |hwnd| _ = self.api.SetWindowTextW(hwnd, @ptrCast(&self.title_utf16));
    }

    /// Resize the client area; WM_SIZE resizes our buffers through the
    /// same path as a user resize.
    fn sizeFn(ptr: *anyopaque, w: u32, h: u32) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        if (w == 0 or h == 0) return;
        var rect = b.RECT{ .left = 0, .top = 0, .right = @intCast(w), .bottom = @intCast(h) };
        _ = self.api.AdjustWindowRect(&rect, b.WS_OVERLAPPEDWINDOW, 0);
        _ = self.api.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, b.SWP_NOMOVE | b.SWP_NOZORDER);
    }

    fn cursorFn(ptr: *anyopaque, shape: backend.CursorShape) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.cursor_shape = shape;
        self.applyCursor();
    }

    /// Strip caption + thick frame for app-drawn chrome (keeping sysmenu
    /// and min/max boxes for taskbar behavior), then reframe the window.
    fn decoratedFn(ptr: *anyopaque, decorated: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse {
            self.decorated = decorated;
            return;
        };
        self.decorated = decorated;
        const current: b.DWORD = @truncate(@as(u64, @bitCast(self.api.GetWindowLongPtrW(hwnd, b.GWL_STYLE))));
        var next = current;
        if (decorated) {
            next |= b.WS_CAPTION | b.WS_THICKFRAME;
        } else {
            next &= ~(b.WS_CAPTION | b.WS_THICKFRAME);
        }
        _ = self.api.SetWindowLongPtrW(hwnd, b.GWL_STYLE, @as(isize, next));
        _ = self.api.SetWindowPos(hwnd, null, 0, 0, 0, 0, b.SWP_NOMOVE | b.SWP_NOSIZE | b.SWP_NOZORDER | b.SWP_FRAMECHANGED);
    }

    fn dragFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        _ = self.api.ReleaseCapture();
        _ = self.api.SendMessageW(hwnd, b.WM_NCLBUTTONDOWN, b.HTCAPTION, 0);
    }

    fn resizeFn(ptr: *anyopaque, edge: backend.ResizeEdge) void {
        // Frameless resize runs through WM_NCHITTEST under the cursor, not
        // through an explicit begin call: the app's edge zones already
        // return hit codes, so the OS loop starts on its own. Record only.
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = edge;
    }

    fn minimizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        _ = self.api.ShowWindow(hwnd, b.SW_MINIMIZE);
    }

    fn maximizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return;
        if (self.api.IsZoomed(hwnd) != 0) {
            _ = self.api.ShowWindow(hwnd, b.SW_RESTORE);
        } else {
            _ = self.api.ShowWindow(hwnd, b.SW_MAXIMIZE);
        }
    }

    fn setClipboardFn(ptr: *anyopaque, text: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const hwnd = self.hwnd orelse return false;
        var wide: [limits.MAX_CLIPBOARD_BYTES]u16 = std.mem.zeroes([limits.MAX_CLIPBOARD_BYTES]u16);
        const units = utf8ToUtf16(text, &wide);
        const bytes = (units + 1) * 2;
        if (self.api.OpenClipboard(hwnd) == 0) return false;
        defer _ = self.api.CloseClipboard();
        _ = self.api.EmptyClipboard();
        const mem = self.kernel.GlobalAlloc(b.GMEM_MOVEABLE, bytes) orelse return false;
        const locked = self.kernel.GlobalLock(mem) orelse {
            _ = self.kernel.GlobalFree(mem);
            return false;
        };
        @memcpy(@as([*]u16, @ptrCast(@alignCast(locked)))[0 .. units + 1], wide[0 .. units + 1]);
        _ = self.kernel.GlobalUnlock(mem);
        return self.api.SetClipboardData(b.CF_UNICODETEXT, mem) != null;
    }

    fn getClipboardFn(ptr: *anyopaque, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (out.len == 0) return 0;
        const hwnd = self.hwnd orelse return 0;
        if (self.api.OpenClipboard(hwnd) == 0) return 0;
        defer _ = self.api.CloseClipboard();
        if (self.api.IsClipboardFormatAvailable(b.CF_UNICODETEXT) == 0) return 0;
        const mem = self.api.GetClipboardData(b.CF_UNICODETEXT) orelse return 0;
        const locked = self.kernel.GlobalLock(mem) orelse return 0;
        defer _ = self.kernel.GlobalUnlock(mem);
        const wide: [*:0]const u16 = @ptrCast(@alignCast(locked));
        var total: usize = 0;
        var i: usize = 0;
        var lead: ?u16 = null;
        while (wide[i] != 0 and total < out.len) : (i += 1) {
            var buf: [4]u8 = undefined;
            const n = utf16UnitToUtf8(wide[i], &lead, &buf);
            const take = @min(n, out.len - total);
            @memcpy(out[total..][0..take], buf[0..take]);
            total += take;
        }
        return total;
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene, glyph_pixels: []const u8, image_pixels: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const w: u32 = @intFromFloat(self.size.w);
        const h: u32 = @intFromFloat(self.size.h);
        // Rasterize into the DIB directly when present (top-down BGRA
        // matches the software .bgra32 layout byte for byte).
        if (self.dib_bits) |bits| {
            const px: [*]u8 = @ptrCast(bits);
            const target = gpu.software.Target.init(px[0 .. @as(usize, w) * h * 4], w, h, .bgra32);
            target.clear(gpu.software.Color.hex(0x0e0e13));
            target.renderScene(scene, glyph_pixels, image_pixels);
        } else {
            const target = gpu.software.Target.init(self.pixels, w, h, .bgra32);
            target.clear(gpu.software.Color.hex(0x0e0e13));
            target.renderScene(scene, glyph_pixels, image_pixels);
        }
        self.blitBackbuffer();
        self.presents += 1;
    }
};

test "win32 stub reports kind but constructs nowhere" {
    var backend_instance = Win32Backend{
        .allocator = std.testing.allocator,
        .user32 = undefined,
        .kernel32 = undefined,
        .gdi32 = undefined,
        .api = undefined,
        .kernel = undefined,
        .gdi = undefined,
        .hwnd = null,
        .class_atom = 0,
        .instance = null,
        .pixels = undefined,
        .size = .{ .w = 64, .h = 64 },
    };
    const handle = backend_instance.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.win32, handle.kind());
    try std.testing.expect(!Win32Backend.isAvailable());
    if (builtin.os.tag != .windows) {
        try std.testing.expectError(error.UnsupportedPlatform, Win32Backend.init(std.testing.allocator, "t", 100, 100));
    }
    // Software fallback path needs real pixels even headless.
    var buf: [64 * 64 * 4]u8 = std.mem.zeroes([64 * 64 * 4]u8);
    backend_instance.pixels = &buf;
    backend_instance.size = .{ .w = 64, .h = 64 };
    const scene = gpu.Scene{};
    handle.present(&scene, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), backend_instance.presents);
}

test "win32 virtual keys map WinUser ABI" {
    try std.testing.expectEqual(event.Key.backspace, vkToKey(0x08));
    try std.testing.expectEqual(event.Key.enter, vkToKey(0x0D));
    try std.testing.expectEqual(event.Key.escape, vkToKey(0x1B));
    try std.testing.expectEqual(event.Key.space, vkToKey(0x20));
    try std.testing.expectEqual(event.Key.a, vkToKey(0x41));
    try std.testing.expectEqual(event.Key.z, vkToKey(0x5A));
    try std.testing.expectEqual(event.Key.n0, vkToKey(0x30));
    try std.testing.expectEqual(event.Key.left, vkToKey(0x25));
    try std.testing.expectEqual(event.Key.delete, vkToKey(0x2E));
    try std.testing.expectEqual(event.Key.f1, vkToKey(0x70));
    try std.testing.expectEqual(event.Key.f12, vkToKey(0x7B));
    // Modifiers have no normalized key (they live in Modifiers).
    try std.testing.expectEqual(event.Key.unknown, vkToKey(0xA0));
    try std.testing.expectEqual(event.Key.unknown, vkToKey(0x5B));
    try std.testing.expectEqual(event.Key.unknown, vkToKey(0x2D));
}

test "win32 UTF-16 text path round-trips incl. astral planes" {
    var lead: ?u16 = null;
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), utf16UnitToUtf8('A', &lead, &buf));
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
    // U+1F600 split across two WM_CHAR messages.
    try std.testing.expectEqual(@as(usize, 0), utf16UnitToUtf8(0xD83D, &lead, &buf));
    try std.testing.expect(lead != null);
    const n = utf16UnitToUtf8(0xDE00, &lead, &buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("😀", buf[0..n]);
    try std.testing.expect(lead == null);
    // Stray trail surrogate drops without bytes.
    try std.testing.expectEqual(@as(usize, 0), utf16UnitToUtf8(0xDE00, &lead, &buf));

    var wide: [16]u16 = undefined;
    const units = utf8ToUtf16("A😀", &wide);
    try std.testing.expectEqual(@as(usize, 3), units);
    try std.testing.expectEqual(@as(u16, 'A'), wide[0]);
    try std.testing.expectEqual(@as(u16, 0xD83D), wide[1]);
    try std.testing.expectEqual(@as(u16, 0xDE00), wide[2]);
    try std.testing.expectEqual(@as(u16, 0), wide[3]);
}

test "win32 frameless border hit-test maps edges" {
    // 800x600 window: corners win over edges, edges over client.
    try std.testing.expectEqual(backend.ResizeEdge.top_left, Win32Backend.hitEdge(0, 0, 800, 600, 3, 3).?);
    try std.testing.expectEqual(backend.ResizeEdge.bottom_right, Win32Backend.hitEdge(0, 0, 800, 600, 797, 597).?);
    try std.testing.expectEqual(backend.ResizeEdge.top, Win32Backend.hitEdge(0, 0, 800, 600, 400, 2).?);
    try std.testing.expectEqual(backend.ResizeEdge.bottom, Win32Backend.hitEdge(0, 0, 800, 600, 400, 597).?);
    try std.testing.expectEqual(backend.ResizeEdge.left, Win32Backend.hitEdge(0, 0, 800, 600, 2, 300).?);
    try std.testing.expectEqual(backend.ResizeEdge.right, Win32Backend.hitEdge(0, 0, 800, 600, 797, 300).?);
    try std.testing.expect(Win32Backend.hitEdge(0, 0, 800, 600, 400, 300) == null);
    try std.testing.expectEqual(b.HTTOPLEFT, Win32Backend.hitCodeForEdge(.top_left));
    try std.testing.expectEqual(b.HTBOTTOM, Win32Backend.hitCodeForEdge(.bottom));
    try std.testing.expectEqual(b.HTRIGHT, Win32Backend.hitCodeForEdge(.right));
}
