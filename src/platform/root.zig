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
pub const services = @import("services.zig");
pub const mobile = @import("mobile.zig");
pub const native_window_services = @import("native_window_services.zig");

const std = @import("std");
const builtin = @import("builtin");

/// Comptime platform selection: a foreign target never instantiates another
/// OS's backend. Its modules are not imported, its payload type is an inert
/// stub, and `createAuto` never references it — so cross-target compiles
/// (`zig build check -Dtarget=<triple>`) never analyze OS-specific bodies.
/// Runtime probing (`isAvailable`) only chooses among compiled-in backends.
pub const target_tag = builtin.target.os.tag;
pub const is_linux = target_tag == .linux;
pub const is_macos = target_tag == .macos;
pub const is_windows = target_tag == .windows;

pub const linux = if (is_linux) @import("linux/mod.zig") else struct {};
pub const macos = if (is_macos) @import("macos/mod.zig") else struct {};
pub const windows = if (is_windows) @import("windows/mod.zig") else struct {};

// Stable aliases: these modules moved into `linux/`; re-exported so
// existing `platform.wayland` / `platform.x11` / `platform.evdev` paths
// keep working. On non-Linux targets they are empty on purpose: a stray
// `platform.x11` reference must fail at comptime instead of leaking Linux
// ABI asserts into a foreign build.
pub const evdev = if (is_linux) linux.evdev else struct {};
pub const x11 = if (is_linux) linux.x11 else struct {};
pub const wayland = if (is_linux) linux.wayland else struct {};

/// Stand-in payload for backends of other operating systems. A variant
/// carrying it can never be constructed (`createAuto` only builds native
/// backends); `handle`/`deinit` treat it as unreachable. The type exists
/// only so the union shape stays uniform across targets.
const ForeignBackend = struct {
    _never: u8 = 0,
};

const WaylandBackend = if (is_linux) linux.wayland.WaylandBackend else ForeignBackend;
const X11Backend = if (is_linux) linux.x11.X11Backend else ForeignBackend;
const CocoaBackend = if (is_macos) macos.CocoaBackend else ForeignBackend;
const Win32Backend = if (is_windows) windows.Win32Backend else ForeignBackend;

pub const Backend = backend.Backend;
pub const BackendKind = backend.BackendKind;
pub const CursorShape = backend.CursorShape;
pub const ResizeEdge = backend.ResizeEdge;
pub const VTable = backend.VTable;
pub const Event = event.Event;
pub const EventQueue = event.EventQueue;
pub const Id = id.Id;

pub const BackendInstance = union(enum) {
    wayland: *WaylandBackend,
    x11: *X11Backend,
    cocoa: *CocoaBackend,
    win32: *Win32Backend,
    null_backend: *null_backend.NullBackend,

    pub fn handle(self: BackendInstance) Backend {
        return switch (self) {
            // Each arm only touches its payload on the matching target;
            // the other branch is discarded at comptime, so foreign
            // backend bodies are never analyzed.
            .wayland => |w| if (is_linux) w.backendHandle() else unreachable,
            .x11 => |x| if (is_linux) x.backendHandle() else unreachable,
            .cocoa => |c| if (is_macos) c.backendHandle() else unreachable,
            .win32 => |w| if (is_windows) w.backendHandle() else unreachable,
            .null_backend => |n| n.backendHandle(),
        };
    }

    pub fn deinit(self: *BackendInstance, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .wayland => |w| if (is_linux) w.deinit() else unreachable,
            .x11 => |x| if (is_linux) x.deinit() else unreachable,
            .cocoa => |c| if (is_macos) c.deinit() else unreachable,
            .win32 => |w| if (is_windows) w.deinit() else unreachable,
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
                if (is_linux) {
                    if (wayland.WaylandBackend.isAvailable()) {
                        if (wayland.WaylandBackend.init(allocator, title, width, height)) |w| {
                            return .{ .wayland = w };
                        } else |_| {}
                    }
                }
                return error.BackendUnavailable;
            }
            if (std.mem.eql(u8, want, "x11")) {
                if (is_linux) {
                    if (x11.X11Backend.isAvailable()) {
                        if (x11.X11Backend.init(allocator, title, width, height)) |x| {
                            return .{ .x11 = x };
                        } else |_| {}
                    }
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

    if (is_linux) {
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
    }

    if (is_macos) {
        if (macos.CocoaBackend.isAvailable()) {
            if (macos.CocoaBackend.init(allocator, title, width, height)) |c| {
                return .{ .cocoa = c };
            } else |_| {}
        }
    }

    if (is_windows) {
        if (windows.Win32Backend.isAvailable()) {
            if (windows.Win32Backend.init(allocator, title, width, height)) |w| {
                return .{ .win32 = w };
            } else |_| {}
        }
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
    _ = @import("services.zig");
    _ = @import("mobile.zig");
    _ = @import("native_window_services.zig");
    // Only the native backend module is compiled in: foreign modules carry
    // OS-specific bodies (and ABI pins) that must not be analyzed here.
    if (is_linux) _ = @import("linux/mod.zig");
    if (is_macos) _ = @import("macos/mod.zig");
    if (is_windows) _ = @import("windows/mod.zig");
}
