//! Headless backend for tests and CI.
//!
//! Why null first: minimal headless reference backends (~200 lines) are
//! the template every real backend copies. ZUI does the same: `NullBackend`
//! implements the full `VTable` with no OS calls so the event loop,
//! scene, and future harness run everywhere.

const std = @import("std");
const backend = @import("backend.zig");
const event = @import("event.zig");
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const gpu = @import("../gpu/root.zig");

pub const NullBackend = struct {
    parent: ?*NullBackend = null,
    allocator: ?std.mem.Allocator = null,
    window_id: u32 = 0,
    focused: bool = true,
    windows: [limits.MAX_WINDOWS]?*NullBackend = @splat(null),
    queue: event.EventQueue = .{},
    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1,
    wakeups: u32 = 0,
    presents: u32 = 0,
    title_buf: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    cursor: backend.CursorShape = .default,
    clipboard_buf: [limits.MAX_CLIPBOARD_BYTES]u8 = std.mem.zeroes([limits.MAX_CLIPBOARD_BYTES]u8),
    clipboard_len: usize = 0,
    decorated: bool = true,
    maximized: bool = false,

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

    fn createWindowFn(ptr: *anyopaque, allocator: std.mem.Allocator, options: backend.WindowOptions) !backend.Backend {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        for (&self.windows) |*slot| {
            if (slot.* != null) continue;
            const child = try allocator.create(NullBackend);
            child.* = .{ .parent = self, .allocator = allocator, .window_id = options.id,
                .size = .{ .w = @floatFromInt(options.width), .h = @floatFromInt(options.height) },
                .decorated = options.decorated };
            child.backendHandle().setTitle(options.title);
            slot.* = child;
            return child.backendHandle();
        }
        return error.TooManyWindows;
    }

    fn destroyWindowFn(ptr: *anyopaque) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        const parent = self.parent orelse return;
        for (&parent.windows) |*slot| {
            if (slot.* == self) slot.* = null;
        }
        self.allocator.?.destroy(self);
    }

    pub fn backendHandle(self: *@This()) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn pushEvent(self: *@This(), ev: event.Event) bool {
        return self.queue.push(ev);
    }

    fn kindFn(ptr: *anyopaque) backend.BackendKind {
        _ = ptr;
        return .null;
    }

    fn pollFn(ptr: *anyopaque, out: *event.EventQueue) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        while (self.queue.pop()) |ev| {
            _ = out.push(ev);
        }
        for (self.windows) |slot| {
            if (slot) |child| while (child.queue.pop()) |ev| {
                _ = out.push(ev.forWindow(child.window_id));
            };
        }
    }

    fn waitFn(ptr: *anyopaque, ns: u64) void {
        _ = ns;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
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
        const n = @min(title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..n], title[0..n]);
        self.title_len = n;
    }

    fn cursorFn(ptr: *anyopaque, shape: backend.CursorShape) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.cursor = shape;
    }

    fn sizeFn(ptr: *anyopaque, w: u32, h: u32) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.size.w = @floatFromInt(w);
        self.size.h = @floatFromInt(h);
    }

    fn decoratedFn(ptr: *anyopaque, decorated: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.decorated = decorated;
    }

    fn dragFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
    }

    fn resizeFn(ptr: *anyopaque, edge: backend.ResizeEdge) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = edge;
    }

    fn minimizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
    }

    fn maximizeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.maximized = !self.maximized;
    }

    fn setClipboardFn(ptr: *anyopaque, text: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const n = @min(text.len, self.clipboard_buf.len);
        @memcpy(self.clipboard_buf[0..n], text[0..n]);
        self.clipboard_len = n;
        return true;
    }

    fn getClipboardFn(ptr: *anyopaque, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const n = @min(self.clipboard_len, out.len);
        @memcpy(out[0..n], self.clipboard_buf[0..n]);
        return n;
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene, glyph_pixels: []const u8, image_pixels: []const u8) void {
        _ = scene;
        _ = glyph_pixels;
        _ = image_pixels;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.presents += 1;
        // Connection-level total: window-scoped presents aggregate upward so
        // App-level diagnostics keep observing one counter.
        if (self.parent) |parent| parent.presents += 1;
    }
};

test "null backend reports kind and window info" {
    var n = NullBackend{};
    const b = n.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.null, b.kind());
    try std.testing.expectEqual(@as(f32, 800), b.windowInfo().size.w);
    b.wakeup();
    try std.testing.expectEqual(@as(u32, 1), n.wakeups);
}

test "null backend poll transfers events and present increments count" {
    var n = NullBackend{};
    const b = n.backendHandle();
    try std.testing.expect(n.pushEvent(.{ .window = .close_requested }));
    try std.testing.expect(n.pushEvent(.{ .window = .focused }));
    try std.testing.expectEqual(@as(usize, 2), n.queue.len);

    var q = event.EventQueue{};
    b.poll(&q);
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqual(@as(usize, 0), n.queue.len);

    const sc = gpu.Scene{};
    try std.testing.expectEqual(@as(u32, 0), n.presents);
    b.present(&sc, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 1), n.presents);
}

test "null backend title cursor and clipboard round-trip" {
    var n = NullBackend{};
    const b = n.backendHandle();
    b.setTitle("Tasks — zui");
    try std.testing.expectEqualStrings("Tasks — zui", n.title_buf[0..n.title_len]);
    b.setCursor(.text);
    try std.testing.expectEqual(backend.CursorShape.text, n.cursor);
    try std.testing.expect(b.setClipboardText("Buy eggs"));
    var out: [32]u8 = undefined;
    const count = b.clipboardText(&out);
    try std.testing.expectEqualStrings("Buy eggs", out[0..count]);
    try std.testing.expectEqual(@as(usize, 0), b.clipboardText(&.{}));
    b.setDecorated(false);
    try std.testing.expect(!n.decorated);
    b.setDecorated(true);
    try std.testing.expect(n.decorated);
    b.toggleMaximizeWindow();
    try std.testing.expect(n.maximized);
    b.toggleMaximizeWindow();
    try std.testing.expect(!n.maximized);
}
