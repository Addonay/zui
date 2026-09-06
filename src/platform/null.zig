//! Headless backend for tests and CI.
//!
//! Why null first: GLFW's `null_*` files are the minimal ~200-line
//! reference every real backend copies. ZUI does the same: `NullBackend`
//! implements the full `VTable` with no OS calls so the event loop,
//! scene, and future harness run everywhere.

const backend = @import("backend.zig");
const event = @import("event.zig");
const geometry = @import("../core/geometry.zig");
const gpu = @import("../gpu/root.zig");

pub const NullBackend = struct {
    queue: event.EventQueue = .{},
    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1,
    wakeups: u32 = 0,
    presents: u32 = 0,

    const vtable: backend.VTable = .{
        .kind = kindFn,
        .poll = pollFn,
        .waitTimeoutNs = waitFn,
        .wakeup = wakeupFn,
        .windowInfo = infoFn,
        .present = presentFn,
    };

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
        return .{ .size = self.size, .scale_factor = self.scale_factor };
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene) void {
        _ = scene;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.presents += 1;
    }
};

test "null backend reports kind and window info" {
    const std = @import("std");
    var n = NullBackend{};
    const b = n.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.null, b.kind());
    try std.testing.expectEqual(@as(f32, 800), b.windowInfo().size.w);
    b.wakeup();
    try std.testing.expectEqual(@as(u32, 1), n.wakeups);
}

test "null backend poll transfers events and present increments count" {
    const std = @import("std");
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
    b.present(&sc);
    try std.testing.expectEqual(@as(u32, 1), n.presents);
}
