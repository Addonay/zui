//! Platform layer: windowing, events, identity.
//!
//! Windowing lives here — there is no separate top-level `windowing/`
//! folder. Per-OS native backends live in `linux/`, `macos/`, `windows/`
//! and implement the same `backend.VTable`. Shared code stays here; OS
//! headers and `dlopen` tables stay in those folders, following the
//! per-platform-module split common to portable window toolkits.
//!
//! GPU drivers live in `gpu/` (Vulkan/Metal/D3D12 are cross-OS APIs, so
//! they are not duplicated per platform). Surface handles created here are
//! handed to `gpu/device.zig` as opaque `SurfaceHandle`s.

pub const backend = @import("backend.zig");
pub const event = @import("event.zig");
pub const id = @import("id.zig");
pub const null_backend = @import("null.zig");
pub const dl = @import("dl.zig");
pub const linux = @import("linux/mod.zig");
pub const macos = @import("macos/mod.zig");
pub const windows = @import("windows/mod.zig");

// Stable aliases: these modules moved into `linux/`; re-exported so
// existing `platform.wayland` / `platform.x11` / `platform.evdev` paths
// keep working.
pub const evdev = linux.evdev;
pub const x11 = linux.x11;
pub const wayland = linux.wayland;

const std = @import("std");
const builtin = @import("builtin");

pub const Backend = backend.Backend;
pub const BackendKind = backend.BackendKind;
pub const CursorShape = backend.CursorShape;
pub const ResizeEdge = backend.ResizeEdge;
pub const VTable = backend.VTable;
pub const Event = event.Event;
pub const EventQueue = event.EventQueue;
pub const Id = id.Id;

pub const BackendInstance = union(enum) {
    wayland: *wayland.WaylandBackend,
    x11: *x11.X11Backend,
    cocoa: *macos.CocoaBackend,
    win32: *windows.Win32Backend,
    null_backend: *null_backend.NullBackend,

    pub fn handle(self: BackendInstance) Backend {
        return switch (self) {
            .wayland => |w| w.backendHandle(),
            .x11 => |x| x.backendHandle(),
            .cocoa => |c| c.backendHandle(),
            .win32 => |w| w.backendHandle(),
            .null_backend => |n| n.backendHandle(),
        };
    }

    pub fn deinit(self: *BackendInstance, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .wayland => |w| w.deinit(),
            .x11 => |x| x.deinit(),
            .cocoa => |c| c.deinit(),
            .win32 => |w| w.deinit(),
            .null_backend => |n| allocator.destroy(n),
        }
    }
};

pub fn createAuto(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !BackendInstance {
    // Driver-override for tests and ssh sessions:
    // ZUI_BACKEND=wayland|x11|null pins the backend, anything else (or
    // unset) keeps the probe order below.
    if (builtin.link_libc) {
        if (std.c.getenv("ZUI_BACKEND")) |raw| {
            const want = std.mem.span(raw);
            if (std.mem.eql(u8, want, "wayland")) {
                if (wayland.WaylandBackend.isAvailable()) {
                    if (wayland.WaylandBackend.init(allocator, title, width, height)) |w| {
                        return .{ .wayland = w };
                    } else |_| {}
                }
                return error.BackendUnavailable;
            }
            if (std.mem.eql(u8, want, "x11")) {
                if (x11.X11Backend.isAvailable()) {
                    if (x11.X11Backend.init(allocator, title, width, height)) |x| {
                        return .{ .x11 = x };
                    } else |_| {}
                }
                return error.BackendUnavailable;
            }
            if (std.mem.eql(u8, want, "null")) {
                const nb = try allocator.create(null_backend.NullBackend);
                nb.* = .{};
                return .{ .null_backend = nb };
            }
        }
    }

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

    if (builtin.os.tag == .macos and macos.CocoaBackend.isAvailable()) {
        if (macos.CocoaBackend.init(allocator, title, width, height)) |c| {
            return .{ .cocoa = c };
        } else |_| {}
    }

    if (builtin.os.tag == .windows and windows.Win32Backend.isAvailable()) {
        if (windows.Win32Backend.init(allocator, title, width, height)) |w| {
            return .{ .win32 = w };
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
    _ = @import("linux/mod.zig");
    _ = @import("macos/mod.zig");
    _ = @import("windows/mod.zig");
}
