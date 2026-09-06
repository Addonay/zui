//! Wayland windowing and presentation backend.
//!
//! Connects to a Wayland compositor via dlopen'd libwayland-client without compile-time headers.
//! Manages native window creation via XDG shell, input dispatch via wl_seat, and frame
//! presentation via wl_shm shared memory buffers and the software rasterizer.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const event = @import("event.zig");
const geometry = @import("../core/geometry.zig");
const gpu = @import("../gpu/root.zig");
const dl = @import("dl.zig");

// Opaque Wayland protocol handles
const Display = opaque {};
const Registry = opaque {};
const Compositor = opaque {};
const Surface = opaque {};
const Shm = opaque {};
const ShmPool = opaque {};
const Buffer = opaque {};
const Seat = opaque {};
const Pointer = opaque {};
const Keyboard = opaque {};
const XdgWmBase = opaque {};
const XdgSurface = opaque {};
const XdgToplevel = opaque {};

const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const anyopaque,
    event_count: c_int,
    events: ?*const anyopaque,
};

const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?*const ?*const anyopaque,
};

// Listeners
const RegistryListener = extern struct {
    global: ?*const fn (?*anyopaque, *Registry, u32, [*:0]const u8, u32) callconv(.c) void = null,
    global_remove: ?*const fn (?*anyopaque, *Registry, u32) callconv(.c) void = null,
};

const XdgWmBaseListener = extern struct {
    ping: ?*const fn (?*anyopaque, *XdgWmBase, u32) callconv(.c) void = null,
};

const XdgSurfaceListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgSurface, u32) callconv(.c) void = null,
};

const XdgToplevelListener = extern struct {
    configure: ?*const fn (?*anyopaque, *XdgToplevel, i32, i32, ?*anyopaque) callconv(.c) void = null,
    close: ?*const fn (?*anyopaque, *XdgToplevel) callconv(.c) void = null,
    configure_bounds: ?*const fn (?*anyopaque, *XdgToplevel, i32, i32) callconv(.c) void = null,
    wm_capabilities: ?*const fn (?*anyopaque, *XdgToplevel, ?*anyopaque) callconv(.c) void = null,
};

const SeatListener = extern struct {
    capabilities: ?*const fn (?*anyopaque, *Seat, u32) callconv(.c) void = null,
    name: ?*const fn (?*anyopaque, *Seat, [*:0]const u8) callconv(.c) void = null,
};

const PointerListener = extern struct {
    enter: ?*const fn (?*anyopaque, *Pointer, u32, *Surface, i32, i32) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *Pointer, u32, *Surface) callconv(.c) void = null,
    motion: ?*const fn (?*anyopaque, *Pointer, u32, i32, i32) callconv(.c) void = null,
    button: ?*const fn (?*anyopaque, *Pointer, u32, u32, u32, u32) callconv(.c) void = null,
    axis: ?*const fn (?*anyopaque, *Pointer, u32, u32, i32) callconv(.c) void = null,
    frame: ?*const fn (?*anyopaque, *Pointer) callconv(.c) void = null,
    axis_source: ?*const fn (?*anyopaque, *Pointer, u32) callconv(.c) void = null,
    axis_stop: ?*const fn (?*anyopaque, *Pointer, u32, u32) callconv(.c) void = null,
    axis_discrete: ?*const fn (?*anyopaque, *Pointer, u32, i32) callconv(.c) void = null,
};

// XDG Shell Protocol Interfaces (manual definitions since not in libwayland-client)
const xdg_surface_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};
const xdg_surface_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = null },
    .{ .name = "get_popup", .signature = "noo", .types = null },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};
const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 5,
    .method_count = 5,
    .methods = @ptrCast(&xdg_surface_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_surface_events),
};

const xdg_toplevel_events = [_]Message{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "a", .types = null },
};
const xdg_toplevel_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = null },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_app_id", .signature = "s", .types = null },
};
const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 5,
    .method_count = 4,
    .methods = @ptrCast(&xdg_toplevel_methods),
    .event_count = 4,
    .events = @ptrCast(&xdg_toplevel_events),
};

const xdg_wm_base_events = [_]Message{
    .{ .name = "ping", .signature = "u", .types = null },
};
const xdg_wm_base_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = null },
    .{ .name = "get_xdg_surface", .signature = "no", .types = null },
    .{ .name = "pong", .signature = "u", .types = null },
};
const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 5,
    .method_count = 4,
    .methods = @ptrCast(&xdg_wm_base_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_wm_base_events),
};

const WaylandApi = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    wl_display_disconnect: *const fn (*Display) callconv(.c) void,
    wl_display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    wl_display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    wl_display_flush: *const fn (*Display) callconv(.c) c_int,
    wl_display_get_fd: *const fn (*Display) callconv(.c) c_int,
    wl_proxy_marshal_flags: *const fn (*anyopaque, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*anyopaque,
    wl_proxy_add_listener: *const fn (*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_destroy: *const fn (*anyopaque) callconv(.c) void,
    wl_proxy_get_version: *const fn (*anyopaque) callconv(.c) u32,

    // Core interfaces
    wl_registry_interface: *const Interface,
    wl_compositor_interface: *const Interface,
    wl_shm_interface: *const Interface,
    wl_shm_pool_interface: *const Interface,
    wl_buffer_interface: *const Interface,
    wl_surface_interface: *const Interface,
    wl_seat_interface: *const Interface,

    fn load(lib: dl.Library) ?WaylandApi {
        return .{
            .wl_display_connect = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "wl_display_connect") orelse return null,
            .wl_display_disconnect = lib.lookup(*const fn (*Display) callconv(.c) void, "wl_display_disconnect") orelse return null,
            .wl_display_roundtrip = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_roundtrip") orelse return null,
            .wl_display_dispatch_pending = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_dispatch_pending") orelse return null,
            .wl_display_flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_flush") orelse return null,
            .wl_display_get_fd = lib.lookup(*const fn (*Display) callconv(.c) c_int, "wl_display_get_fd") orelse return null,
            .wl_proxy_marshal_flags = lib.lookup(*const fn (*anyopaque, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*anyopaque, "wl_proxy_marshal_flags") orelse return null,
            .wl_proxy_add_listener = lib.lookup(*const fn (*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) c_int, "wl_proxy_add_listener") orelse return null,
            .wl_proxy_destroy = lib.lookup(*const fn (*anyopaque) callconv(.c) void, "wl_proxy_destroy") orelse return null,
            .wl_proxy_get_version = lib.lookup(*const fn (*anyopaque) callconv(.c) u32, "wl_proxy_get_version") orelse return null,

            .wl_registry_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_registry_interface")))) orelse return null,
            .wl_compositor_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_compositor_interface")))) orelse return null,
            .wl_shm_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_shm_interface")))) orelse return null,
            .wl_shm_pool_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_shm_pool_interface")))) orelse return null,
            .wl_buffer_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_buffer_interface")))) orelse return null,
            .wl_surface_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_surface_interface")))) orelse return null,
            .wl_seat_interface = @as(?*const Interface, @ptrCast(@alignCast(lib.lookup(*anyopaque, "wl_seat_interface")))) orelse return null,
        };
    }
};

pub const WaylandBackend = struct {
    allocator: std.mem.Allocator,
    lib: dl.Library,
    api: WaylandApi,

    display: *Display,
    registry: *Registry,
    compositor: ?*Compositor = null,
    shm: ?*Shm = null,
    wm_base: ?*XdgWmBase = null,
    seat: ?*Seat = null,
    pointer: ?*Pointer = null,

    surface: ?*Surface = null,
    xdg_surface: ?*XdgSurface = null,
    xdg_toplevel: ?*XdgToplevel = null,

    size: geometry.Size = .{ .w = 800, .h = 600 },
    scale_factor: f32 = 1.0,
    focused: bool = true,
    configured: bool = false,
    presents: u32 = 0,
    wakeups: u32 = 0,

    // SHM Pixel buffer
    shm_fd: c_int = -1,
    shm_size: usize = 0,
    pixels: ?[]u8 = null,
    buffer: ?*Buffer = null,
    target_queue: ?*event.EventQueue = null,

    const vtable: backend.VTable = .{
        .kind = kindFn,
        .poll = pollFn,
        .waitTimeoutNs = waitFn,
        .wakeup = wakeupFn,
        .windowInfo = infoFn,
        .present = presentFn,
    };

    fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
        if (!builtin.link_libc) return null;
        return std.c.getenv(name);
    }

    pub fn isAvailable() bool {
        if (!builtin.link_libc) return false;
        if (getenv("WAYLAND_DISPLAY") == null) return false;
        var lib = dl.Library.open(&.{ "libwayland-client.so.0", "libwayland-client.so" }) orelse return false;
        defer lib.close();
        return WaylandApi.load(lib) != null;
    }

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !*WaylandBackend {
        if (!builtin.link_libc) return error.LibcNotLinked;
        if (getenv("WAYLAND_DISPLAY") == null) return error.NoWaylandDisplay;

        const lib = dl.Library.open(&.{ "libwayland-client.so.0", "libwayland-client.so" }) orelse return error.LibraryNotFound;
        errdefer {
            var l = lib;
            l.close();
        }

        const api = WaylandApi.load(lib) orelse return error.MissingSymbols;

        const dpy = api.wl_display_connect(null) orelse return error.CannotConnectWayland;
        errdefer api.wl_display_disconnect(dpy);

        const reg_raw = api.wl_proxy_marshal_flags(@ptrCast(dpy), 1, api.wl_registry_interface, api.wl_proxy_get_version(@ptrCast(dpy)), 0);
        const reg: *Registry = @ptrCast(reg_raw orelse return error.CannotGetRegistry);

        const self = try allocator.create(WaylandBackend);
        self.* = .{
            .allocator = allocator,
            .lib = lib,
            .api = api,
            .display = dpy,
            .registry = reg,
            .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
        };

        // Attach registry listener
        _ = api.wl_proxy_add_listener(@ptrCast(reg), &default_reg_listener, self);
        _ = api.wl_display_roundtrip(dpy);

        if (self.compositor == null or self.shm == null) {
            self.deinit();
            return error.MissingWaylandGlobals;
        }

        // Create surface
        const surf_raw = api.wl_proxy_marshal_flags(@ptrCast(self.compositor.?), 0, api.wl_surface_interface, api.wl_proxy_get_version(@ptrCast(self.compositor.?)), 0, @as(?*anyopaque, null));
        self.surface = @ptrCast(surf_raw);

        // Create XDG surface if wm_base is available
        if (self.wm_base) |wm| {
            _ = api.wl_proxy_add_listener(@ptrCast(wm), &default_wm_listener, self);

            const xdg_surf_raw = api.wl_proxy_marshal_flags(@ptrCast(wm), 2, &xdg_surface_interface, api.wl_proxy_get_version(@ptrCast(wm)), 0, @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(self.surface.?)));
            self.xdg_surface = @ptrCast(xdg_surf_raw);

            if (self.xdg_surface) |xs| {
                _ = api.wl_proxy_add_listener(@ptrCast(xs), &default_xs_listener, self);

                const top_raw = api.wl_proxy_marshal_flags(@ptrCast(xs), 1, &xdg_toplevel_interface, api.wl_proxy_get_version(@ptrCast(xs)), 0, @as(?*anyopaque, null));
                self.xdg_toplevel = @ptrCast(top_raw);

                if (self.xdg_toplevel) |top| {
                    _ = api.wl_proxy_add_listener(@ptrCast(top), &default_top_listener, self);

                    // Opcode 2 is set_title on xdg_toplevel
                    _ = api.wl_proxy_marshal_flags(@ptrCast(top), 2, null, api.wl_proxy_get_version(@ptrCast(top)), 0, title);
                }
            }
        }

        // Allocate initial shm buffer
        try self.recreateBuffer(width, height);

        // Commit surface and roundtrip to initiate configure
        _ = api.wl_proxy_marshal_flags(@ptrCast(self.surface.?), 6, null, api.wl_proxy_get_version(@ptrCast(self.surface.?)), 0);
        _ = api.wl_display_roundtrip(dpy);

        return self;
    }

    pub fn deinit(self: *WaylandBackend) void {
        self.destroyBuffer();

        if (self.pointer) |p| self.api.wl_proxy_destroy(@ptrCast(p));
        if (self.xdg_toplevel) |t| self.api.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |xs| self.api.wl_proxy_destroy(@ptrCast(xs));
        if (self.surface) |s| self.api.wl_proxy_destroy(@ptrCast(s));
        if (self.wm_base) |w| self.api.wl_proxy_destroy(@ptrCast(w));
        if (self.seat) |st| self.api.wl_proxy_destroy(@ptrCast(st));
        if (self.shm) |sh| self.api.wl_proxy_destroy(@ptrCast(sh));
        if (self.compositor) |c| self.api.wl_proxy_destroy(@ptrCast(c));

        self.api.wl_proxy_destroy(@ptrCast(self.registry));
        self.api.wl_display_disconnect(self.display);
        self.lib.close();
        self.allocator.destroy(self);
    }

    pub fn backendHandle(self: *WaylandBackend) backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recreateBuffer(self: *WaylandBackend, width: u32, height: u32) !void {
        self.destroyBuffer();

        const stride = width * 4;
        const buf_size = @as(usize, stride) * height;

        const fd = std.os.linux.memfd_create("zui-wayland-shm", 0);
        if (fd < 0) return error.MemfdFailed;
        errdefer _ = std.os.linux.close(@intCast(fd));

        const trunc_res = std.os.linux.ftruncate(@intCast(fd), @intCast(buf_size));
        if (trunc_res != 0) return error.FtruncateFailed;

        const map_res = std.os.linux.mmap(null, buf_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, @intCast(fd), 0);
        const ptr: [*]u8 = @ptrFromInt(map_res);
        self.pixels = ptr[0..buf_size];
        self.shm_fd = @intCast(fd);
        self.shm_size = buf_size;

        // wl_shm::create_pool is opcode 0
        const pool_raw = self.api.wl_proxy_marshal_flags(@ptrCast(self.shm.?), 0, self.api.wl_shm_pool_interface, self.api.wl_proxy_get_version(@ptrCast(self.shm.?)), 0, @as(?*anyopaque, null), @as(i32, @intCast(fd)), @as(i32, @intCast(buf_size)));
        const pool: *ShmPool = @ptrCast(pool_raw orelse return error.CannotCreateShmPool);
        defer self.api.wl_proxy_destroy(@ptrCast(pool));

        // wl_shm_pool::create_buffer is opcode 0. Format 0 is WL_SHM_FORMAT_ARGB8888
        const buf_raw = self.api.wl_proxy_marshal_flags(@ptrCast(pool), 0, self.api.wl_buffer_interface, self.api.wl_proxy_get_version(@ptrCast(pool)), 0, @as(?*anyopaque, null), @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)), @as(i32, @intCast(stride)), @as(u32, 0));
        self.buffer = @ptrCast(buf_raw);
    }

    fn destroyBuffer(self: *WaylandBackend) void {
        if (self.buffer) |buf| {
            self.api.wl_proxy_destroy(@ptrCast(buf));
            self.buffer = null;
        }
        if (self.pixels) |px| {
            _ = std.os.linux.munmap(px.ptr, self.shm_size);
            self.pixels = null;
        }
        if (self.shm_fd >= 0) {
            _ = std.os.linux.close(self.shm_fd);
            self.shm_fd = -1;
        }
    }

    // Callbacks
    fn registryGlobal(data: ?*anyopaque, reg: *Registry, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const iface_name = std.mem.span(iface);

        if (std.mem.eql(u8, iface_name, "wl_compositor")) {
            const ver: u32 = @min(version, 4);
            const comp = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, self.api.wl_compositor_interface, ver, 0, name, self.api.wl_compositor_interface.name, ver, self.api.wl_compositor_interface);
            self.compositor = @ptrCast(comp);
        } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
            const one: u32 = 1;
            const sh = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, self.api.wl_shm_interface, one, 0, name, self.api.wl_shm_interface.name, one, self.api.wl_shm_interface);
            self.shm = @ptrCast(sh);
        } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
            const ver: u32 = @min(version, 5);
            const wm = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, &xdg_wm_base_interface, ver, 0, name, xdg_wm_base_interface.name, ver, &xdg_wm_base_interface);
            self.wm_base = @ptrCast(wm);
        } else if (std.mem.eql(u8, iface_name, "wl_seat")) {
            const ver: u32 = @min(version, 5);
            const st = self.api.wl_proxy_marshal_flags(@ptrCast(reg), 0, self.api.wl_seat_interface, ver, 0, name, self.api.wl_seat_interface.name, ver, self.api.wl_seat_interface);
            self.seat = @ptrCast(st);
        }
    }

    fn registryGlobalRemove(_: ?*anyopaque, _: *Registry, _: u32) callconv(.c) void {}

    fn xdgPing(data: ?*anyopaque, wm: *XdgWmBase, serial: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        // Opcode 3 is pong on xdg_wm_base
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(wm), 3, null, self.api.wl_proxy_get_version(@ptrCast(wm)), 0, serial);
    }

    fn xdgSurfaceConfigure(data: ?*anyopaque, xs: *XdgSurface, serial: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.configured = true;
        // Opcode 4 is ack_configure on xdg_surface
        _ = self.api.wl_proxy_marshal_flags(@ptrCast(xs), 4, null, self.api.wl_proxy_get_version(@ptrCast(xs)), 0, serial);
    }

    fn xdgToplevelConfigure(data: ?*anyopaque, _: *XdgToplevel, width: i32, height: i32, _: ?*anyopaque) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (width > 0 and height > 0) {
            const w: f32 = @floatFromInt(width);
            const h: f32 = @floatFromInt(height);
            if (w != self.size.w or h != self.size.h) {
                self.size.w = w;
                self.size.h = h;
                self.recreateBuffer(@intCast(width), @intCast(height)) catch {};
                if (self.target_queue) |q| {
                    _ = q.push(.{ .window = .resized });
                }
            }
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: *XdgToplevel) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.target_queue) |q| {
            _ = q.push(.{ .window = .close_requested });
        }
    }

    fn xdgToplevelConfigureBounds(_: ?*anyopaque, _: *XdgToplevel, _: i32, _: i32) callconv(.c) void {}

    fn xdgToplevelWmCapabilities(_: ?*anyopaque, _: *XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    const default_reg_listener = RegistryListener{
        .global = registryGlobal,
        .global_remove = registryGlobalRemove,
    };

    const default_wm_listener = XdgWmBaseListener{
        .ping = xdgPing,
    };

    const default_xs_listener = XdgSurfaceListener{
        .configure = xdgSurfaceConfigure,
    };

    const default_top_listener = XdgToplevelListener{
        .configure = xdgToplevelConfigure,
        .close = xdgToplevelClose,
        .configure_bounds = xdgToplevelConfigureBounds,
        .wm_capabilities = xdgToplevelWmCapabilities,
    };

    // Backend vtable functions
    fn kindFn(_: *anyopaque) backend.BackendKind {
        return .wayland;
    }

    fn pollFn(ptr: *anyopaque, out: *event.EventQueue) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.target_queue = out;
        _ = self.api.wl_display_dispatch_pending(self.display);
        _ = self.api.wl_display_flush(self.display);
    }

    fn waitFn(ptr: *anyopaque, ns: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self.api.wl_display_flush(self.display);
        const fd = self.api.wl_display_get_fd(self.display);
        var pfd = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ms: i32 = @intCast(@min(ns / 1_000_000, 1000));
        _ = std.posix.poll(&pfd, ms) catch 0;
    }

    fn wakeupFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.wakeups += 1;
        _ = self.api.wl_display_flush(self.display);
    }

    fn infoFn(ptr: *anyopaque) backend.WindowInfo {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .size = self.size,
            .scale_factor = self.scale_factor,
            .focused = self.focused,
        };
    }

    fn presentFn(ptr: *anyopaque, scene: *const gpu.Scene) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const w: u32 = @intFromFloat(self.size.w);
        const h: u32 = @intFromFloat(self.size.h);

        if (self.pixels) |px| {
            const target = gpu.software.Target.init(px, w, h, .argb32);
            target.clear(gpu.software.Color.hex(0x0e0e13)); // theme.bg
            target.renderScene(scene);

            if (self.surface) |s| {
                if (self.buffer) |b| {
                    // Opcode 1: wl_surface::attach(buffer, x=0, y=0)
                    _ = self.api.wl_proxy_marshal_flags(@ptrCast(s), 1, null, self.api.wl_proxy_get_version(@ptrCast(s)), 0, b, @as(i32, 0), @as(i32, 0));
                    // Opcode 2: wl_surface::damage(x=0, y=0, w, h)
                    _ = self.api.wl_proxy_marshal_flags(@ptrCast(s), 2, null, self.api.wl_proxy_get_version(@ptrCast(s)), 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(w)), @as(i32, @intCast(h)));
                    // Opcode 6: wl_surface::commit()
                    _ = self.api.wl_proxy_marshal_flags(@ptrCast(s), 6, null, self.api.wl_proxy_get_version(@ptrCast(s)), 0);
                    _ = self.api.wl_display_flush(self.display);
                }
            }
        }
        self.presents += 1;
    }
};

test "wayland availability and initialization" {
    if (!WaylandBackend.isAvailable()) return;

    var b = try WaylandBackend.init(std.testing.allocator, "ZUI Wayland Test", 320, 240);
    defer b.deinit();

    const handle = b.backendHandle();
    try std.testing.expectEqual(backend.BackendKind.wayland, handle.kind());
    try std.testing.expectEqual(@as(f32, 320), handle.windowInfo().size.w);
    try std.testing.expectEqual(@as(f32, 240), handle.windowInfo().size.h);

    var sc = gpu.Scene{};
    _ = sc.push(.{ .x = 10, .y = 10, .w = 100, .h = 100, .color = gpu.software.Color.hex(0x00FF00) });
    handle.present(&sc);
    try std.testing.expectEqual(@as(u32, 1), b.presents);
}
