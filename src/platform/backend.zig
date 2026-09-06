//! Backend interface shared by every windowing/GPU target.
//!
//! Why a vtable: SDL's `SDL_VideoDevice` and GLFW's `_GLFWplatform` are
//! both plain fn-pointer tables filled per-backend and probed in priority
//! order. Zig gets the same with an explicit `VTable` + `Backend` fat
//! pointer, plus a comptime backend list. Backends translate OS events
//! into `event.Event`; they never own the queue.

const geometry = @import("../core/geometry.zig");
const event = @import("event.zig");
const gpu = @import("../gpu/root.zig");

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

pub const VTable = struct {
    kind: *const fn (*anyopaque) BackendKind,
    poll: *const fn (*anyopaque, *event.EventQueue) void,
    waitTimeoutNs: *const fn (*anyopaque, u64) void,
    wakeup: *const fn (*anyopaque) void,
    windowInfo: *const fn (*anyopaque) WindowInfo,
    present: *const fn (*anyopaque, *const gpu.Scene) void,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

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

    pub fn present(self: @This(), scene: *const gpu.Scene) void {
        self.vtable.present(self.ptr, scene);
    }
};

/// Priority order for probing, mirroring SDL/GLFW: try the native
/// compositor first, fall back to X11, always have null for headless.
pub fn preferredOrder() [3]BackendKind {
    return .{ .wayland, .x11, .null };
}

test "preferred order ends with null fallback" {
    const order = preferredOrder();
    try @import("std").testing.expectEqual(BackendKind.null, order[order.len - 1]);
}
