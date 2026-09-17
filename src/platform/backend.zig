//! Backend interface shared by every windowing/GPU target.
//!
//! Why a vtable: cross-platform toolkits fill one fn-pointer table per
//! backend and probe in priority order. Zig gets the same with an explicit
//! `VTable` + `Backend` fat pointer, plus a comptime backend list.
//! Backends translate OS events into `event.Event`; they never own the
//! queue.

const geometry = @import("../core/geometry.zig");
const event = @import("event.zig");
const gpu = @import("../gpu/root.zig");
const std = @import("std");

pub const BackendKind = enum {
    null,
    wayland,
    x11,
    cocoa,
    win32,
    web,
};

pub const WindowInfo = struct {
    size: geometry.Size,
    scale_factor: f32 = 1,
    focused: bool = true,
};

/// §5G scale acquisition shared by native backends: `ZUI_SCALE` (fractional,
/// e.g. 1.5) wins, then the desktop convention `GDK_SCALE` (integer), then
/// 1.0. Clamped to a sane range so a bad env value cannot explode buffers.
/// Compositor/OS-reported per-monitor scale (Wayland fractional-scale-v1,
/// RandR) is layered on top by the backend that can observe it.
pub fn envScaleFactor() f32 {
    if (std.c.getenv("ZUI_SCALE")) |raw| {
        const v = std.fmt.parseFloat(f32, std.mem.span(raw)) catch 0;
        if (v >= 0.5 and v <= 8.0) return v;
    }
    if (std.c.getenv("GDK_SCALE")) |raw| {
        const v = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch 0;
        if (v >= 1 and v <= 8) return @floatFromInt(v);
    }
    return 1.0;
}

/// Native pointer shapes. Every backend implements all three; where the
/// compositor owns the cursor (Wayland) the backend resolves the shape
/// through the system theme, elsewhere through native cursor APIs.
pub const CursorShape = enum {
    default,
    text,
    pointer,
};

/// Window edge for interactive resize. Ordinals match the
/// `_NET_WM_MOVERESIZE` action codes (0-7) so X11 passes them through.
pub const ResizeEdge = enum(u32) {
    top_left = 0,
    top = 1,
    top_right = 2,
    right = 3,
    bottom_right = 4,
    bottom = 5,
    bottom_left = 6,
    left = 7,
};

pub const WindowOptions = struct {
    id: u32,
    title: []const u8,
    width: u32,
    height: u32,
    decorated: bool = true,
};

pub const VTable = struct {
    /// Connection creates a window-scoped handle. Null means legacy single-window backend.
    createWindow: ?*const fn (*anyopaque, @import("std").mem.Allocator, WindowOptions) anyerror!Backend = null,
    /// Only called on a successfully created window-scoped handle, at a safe reap point.
    destroyWindow: ?*const fn (*anyopaque) void = null,
    kind: *const fn (*anyopaque) BackendKind,
    poll: *const fn (*anyopaque, *event.EventQueue) void,
    waitTimeoutNs: *const fn (*anyopaque, u64) void,
    wakeup: *const fn (*anyopaque) void,
    windowInfo: *const fn (*anyopaque) WindowInfo,
    /// Push a new title to the native window (taskbar/window list).
    /// Called at creation and on every `Window.setTitle`.
    setTitle: *const fn (*anyopaque, []const u8) void,
    /// Request a native window size (client area, logical pixels).
    /// X11/Cocoa/Win32 honor it; Wayland ignores it (the compositor owns
    /// sizing and answers with configure events instead).
    setSize: *const fn (*anyopaque, u32, u32) void,
    /// Framed (server/native titlebar) vs frameless (app-drawn chrome).
    /// Wayland negotiates client-side decorations, X11 sets motif hints,
    /// Cocoa switches the titlebar mode, Win32 restyles the frame.
    setDecorated: *const fn (*anyopaque, bool) void,
    /// Begin a native window drag using the last input serial/position.
    /// Custom titlebars call this on mouse-down.
    dragWindow: *const fn (*anyopaque) void,
    /// Begin a native edge resize using the last input serial/position.
    resizeWindow: *const fn (*anyopaque, ResizeEdge) void,
    /// Minimize to taskbar/dock.
    minimizeWindow: *const fn (*anyopaque) void,
    /// Toggle maximized/restored. Tracks state from configure/size events.
    toggleMaximizeWindow: *const fn (*anyopaque) void,
    /// Switch the native pointer shape.
    setCursor: *const fn (*anyopaque, CursorShape) void,
    /// Copy `text` into the system clipboard. False when unavailable.
    setClipboardText: *const fn (*anyopaque, []const u8) bool,
    /// Paste system clipboard UTF-8 into `out`. Returns bytes written;
    /// zero means empty or unavailable. Never exceeds `out.len`.
    clipboardText: *const fn (*anyopaque, []u8) usize,
    /// `glyph_pixels` is the font atlas pool backing `Scene` glyph entries
    /// (empty when fonts are unavailable). `image_pixels` is the App
    /// image-cache pool backing `Scene` image entries (empty headless).
    /// Backends forward both to the software rasterizer; the null backend
    /// ignores them.
    present: *const fn (*anyopaque, *const gpu.Scene, []const u8, []const u8) void,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn createWindow(self: Backend, allocator: @import("std").mem.Allocator, options: WindowOptions) !Backend {
        const create = self.vtable.createWindow orelse return error.MultipleNativeWindowsNotSupported;
        return create(self.ptr, allocator, options);
    }

    pub fn destroyWindow(self: Backend) void {
        if (self.vtable.destroyWindow) |destroy| destroy(self.ptr);
    }

    pub fn kind(self: @This()) BackendKind {
        return self.vtable.kind(self.ptr);
    }

    pub fn poll(self: @This(), queue: *event.EventQueue) void {
        self.vtable.poll(self.ptr, queue);
    }

    pub fn waitTimeoutNs(self: @This(), ns: u64) void {
        self.vtable.waitTimeoutNs(self.ptr, ns);
    }

    pub fn wakeup(self: @This()) void {
        self.vtable.wakeup(self.ptr);
    }

    pub fn windowInfo(self: @This()) WindowInfo {
        return self.vtable.windowInfo(self.ptr);
    }

    pub fn setTitle(self: @This(), title: []const u8) void {
        self.vtable.setTitle(self.ptr, title);
    }

    pub fn setSize(self: @This(), w: u32, h: u32) void {
        self.vtable.setSize(self.ptr, w, h);
    }

    pub fn setDecorated(self: @This(), decorated: bool) void {
        self.vtable.setDecorated(self.ptr, decorated);
    }

    pub fn dragWindow(self: @This()) void {
        self.vtable.dragWindow(self.ptr);
    }

    pub fn resizeWindow(self: @This(), edge: ResizeEdge) void {
        self.vtable.resizeWindow(self.ptr, edge);
    }

    pub fn minimizeWindow(self: @This()) void {
        self.vtable.minimizeWindow(self.ptr);
    }

    pub fn toggleMaximizeWindow(self: @This()) void {
        self.vtable.toggleMaximizeWindow(self.ptr);
    }

    pub fn setCursor(self: @This(), shape: CursorShape) void {
        self.vtable.setCursor(self.ptr, shape);
    }

    pub fn setClipboardText(self: @This(), text: []const u8) bool {
        return self.vtable.setClipboardText(self.ptr, text);
    }

    pub fn clipboardText(self: @This(), out: []u8) usize {
        return self.vtable.clipboardText(self.ptr, out);
    }

    pub fn present(self: @This(), scene: *const gpu.Scene, glyph_pixels: []const u8, image_pixels: []const u8) void {
        self.vtable.present(self.ptr, scene, glyph_pixels, image_pixels);
    }
};

/// Priority order for probing: try the native compositor first, fall
/// back to X11, always have null for headless.
pub fn preferredOrder() [3]BackendKind {
    return .{ .wayland, .x11, .null };
}

test "preferred order ends with null fallback" {
    const order = preferredOrder();
    try @import("std").testing.expectEqual(BackendKind.null, order[order.len - 1]);
}
