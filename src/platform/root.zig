//! Platform layer: windowing, events, identity.
//!
//! Per-OS backends (`wayland`, `x11`, `cocoa`, `win32`) will live next to
//! `null.zig` and implement the same `backend.VTable`. Shared code stays
//! here; OS headers and `dlopen` tables stay in those files, mirroring
//! SDL's `src/video/<name>/` split and GLFW's `*_platform.h` pattern.

pub const backend = @import("backend.zig");
pub const event = @import("event.zig");
pub const id = @import("id.zig");
pub const null_backend = @import("null.zig");
pub const dl = @import("dl.zig");
pub const x11 = @import("x11.zig");
pub const wayland = @import("wayland.zig");

const std = @import("std");

pub const Backend = backend.Backend;
pub const BackendKind = backend.BackendKind;
pub const VTable = backend.VTable;
pub const Event = event.Event;
pub const EventQueue = event.EventQueue;
pub const Id = id.Id;

pub const BackendInstance = union(enum) {
    wayland: *wayland.WaylandBackend,
    x11: *x11.X11Backend,
    null_backend: *null_backend.NullBackend,

    pub fn handle(self: BackendInstance) Backend {
        return switch (self) {
            .wayland => |w| w.backendHandle(),
            .x11 => |x| x.backendHandle(),
            .null_backend => |n| n.backendHandle(),
        };
    }

    pub fn deinit(self: *BackendInstance, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .wayland => |w| w.deinit(),
            .x11 => |x| x.deinit(),
            .null_backend => |n| allocator.destroy(n),
        }
    }
};

pub fn createAuto(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !BackendInstance {
    if (wayland.WaylandBackend.isAvailable()) {
        if (wayland.WaylandBackend.init(allocator, title, width, height)) |w| {
            return .{ .wayland = w };
        } else |_| {}
    }

    if (x11.X11Backend.isAvailable()) {
        if (x11.X11Backend.init(allocator, title, width, height)) |x| {
            return .{ .x11 = x };
        } else |_| {}
    }

    const nb = try allocator.create(null_backend.NullBackend);
    nb.* = .{};
    return .{ .null_backend = nb };
}

test {
    _ = @import("backend.zig");
    _ = @import("event.zig");
    _ = @import("id.zig");
    _ = @import("null.zig");
    _ = @import("dl.zig");
    _ = @import("x11.zig");
    _ = @import("wayland.zig");
}
