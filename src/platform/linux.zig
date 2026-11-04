//! Linux platform (GPUI `gpui_linux`): Wayland when WAYLAND_DISPLAY is set and
//! libwayland-client loads, else X11 when DISPLAY is set. Both are loaded with
//! dlopen, so the binary has no link-time dependency on either.

const std = @import("std");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");
const input = @import("linux/input.zig");
pub const wayland = @import("linux/wayland.zig");
pub const x11 = @import("linux/x11.zig");

extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;
const EFD_CLOEXEC: c_int = 0o2000000;
const EFD_NONBLOCK: c_int = 0o4000;

/// The active display connection.
pub const Backend = union(enum) {
    wayland: *wayland.WaylandConnection,
    x11: *x11.X11Connection,

    fn fd(self: Backend) c_int {
        return switch (self) {
            inline else => |c| c.fd(),
        };
    }
    /// A descriptor the backend is reading without blocking, such as a drag's file list.
    fn extra_fd(self: Backend) c_int {
        return switch (self) {
            .wayland => |c| c.extra_fd(),
            .x11 => -1,
        };
    }
    fn on_extra_fd(self: Backend) void {
        switch (self) {
            .wayland => |c| c.on_extra_fd(),
            .x11 => {},
        }
    }
    fn prepare_wait(self: Backend) bool {
        return switch (self) {
            inline else => |c| c.prepare_wait(),
        };
    }
    fn finish_wait(self: Backend, readable: bool) void {
        switch (self) {
            inline else => |c| c.finish_wait(readable),
        }
    }
    fn timeout(self: Backend, now: i64) ?i32 {
        return switch (self) {
            .wayland => |c| c.repeat_timeout(now),
            .x11 => |c| c.frame_timeout(now),
        };
    }
    fn pump(self: Backend) void {
        switch (self) {
            inline else => |c| c.pump(),
        }
    }
    fn reap(self: Backend) void {
        switch (self) {
            inline else => |c| c.reap(),
        }
    }
    fn live_windows(self: Backend) usize {
        return switch (self) {
            inline else => |c| c.live_windows(),
        };
    }
    fn is_dead(self: Backend) bool {
        return switch (self) {
            inline else => |c| c.is_dead(),
        };
    }
    fn deinit(self: Backend) void {
        switch (self) {
            inline else => |c| c.deinit(),
        }
    }
};

pub const LinuxPlatform = struct {
    allocator: std.mem.Allocator,
    platform: platform.Platform = .{ .vtable = &vtable },
    backend: Backend,
    /// Written by `wake` from any thread; drained by the event loop.
    wake_fd: c_int,
    quit_requested: bool = false,
    /// True once a window has been opened; the loop exits when the last one closes.
    ever_opened: bool = false,
    app: ?*app_mod.App = null,

    const vtable: platform.Platform.VTable = .{
        .run = run,
        .quit = quit,
        .deinit = deinit,
        .open_window = openWindow,
        .wake = wake,
        .displays = displays,
        .set_cursor_style = setCursorStyle,
        .write_to_clipboard = writeClipboard,
        .read_from_clipboard = readClipboard,
        .write_to_primary = writePrimary,
        .read_from_primary = readPrimary,
    };

    pub fn from(p: *platform.Platform) *LinuxPlatform {
        return @fieldParentPtr("platform", p);
    }

    fn run(p: *platform.Platform, app: *app_mod.App, on_launch: *const fn (*anyopaque) void) void {
        const self = from(p);
        self.app = app;
        on_launch(app);
        while (true) {
            _ = app.foreground_executor().run_pending();
            self.backend.pump();
            self.backend.reap();
            if (self.quit_requested) break;
            if (self.ever_opened and self.backend.live_windows() == 0) break;
            if (self.backend.is_dead()) {
                std.log.err("linux: display connection lost", .{});
                break;
            }
            self.wait_once();
        }
    }

    /// Blocks until the display has events, a wakeup arrives, or a frame or
    /// key-repeat deadline passes; then dispatches what is ready.
    fn wait_once(self: *LinuxPlatform) void {
        const now = input.now_ms();
        const timeout = self.backend.timeout(now) orelse -1;
        const has_pending = self.backend.prepare_wait();
        // Poll ignores a negative descriptor.
        var fds = [3]std.posix.pollfd{
            .{ .fd = self.backend.fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.backend.extra_fd(), .events = std.posix.POLL.IN, .revents = 0 },
        };
        if (!has_pending) {
            _ = std.posix.poll(&fds, timeout) catch 0;
        }
        self.backend.finish_wait(fds[0].revents != 0);
        if (fds[2].revents != 0) self.backend.on_extra_fd();
        if (fds[1].revents != 0) {
            var buf: u64 = 0;
            _ = std.os.linux.read(self.wake_fd, @ptrCast(&buf), 8);
        }
    }

    fn quit(p: *platform.Platform) void {
        const self = from(p);
        self.quit_requested = true;
        wake(p);
    }

    fn deinit(p: *platform.Platform) void {
        const self = from(p);
        self.backend.deinit();
        _ = std.os.linux.close(self.wake_fd);
        self.allocator.destroy(self);
    }

    fn wake(p: *platform.Platform) void {
        const self = from(p);
        var one: u64 = 1;
        _ = std.os.linux.write(self.wake_fd, @ptrCast(&one), 8);
    }

    fn openWindow(p: *platform.Platform, options: window_mod.WindowOptions) anyerror!*platform.PlatformWindow {
        const self = from(p);
        const w: *platform.PlatformWindow = switch (self.backend) {
            .wayland => |c| &(try c.open_window(options)).base,
            .x11 => |c| &(try c.open_window(options)).base,
        };
        self.ever_opened = true;
        return w;
    }

    fn displays(p: *platform.Platform) []const platform.Display {
        return switch (from(p).backend) {
            .wayland => |c| c.displays(),
            .x11 => |c| c.displays(),
        };
    }

    fn setCursorStyle(p: *platform.Platform, style: platform.CursorStyle) void {
        switch (from(p).backend) {
            .wayland => |c| c.set_cursor_style(style),
            .x11 => |c| c.set_cursor_style(style),
        }
    }

    fn writeClipboard(p: *platform.Platform, item: platform.ClipboardItem) void {
        const text = item.text() orelse return;
        switch (from(p).backend) {
            .wayland => |c| _ = c.set_clipboard(text),
            .x11 => |c| _ = c.set_clipboard(text),
        }
    }

    fn writePrimary(p: *platform.Platform, item: platform.ClipboardItem) void {
        const text = item.text() orelse return;
        switch (from(p).backend) {
            .wayland => |c| _ = c.set_primary(text),
            .x11 => |c| _ = c.set_primary(text),
        }
    }

    fn readPrimary(p: *platform.Platform) ?platform.ClipboardItem {
        const text = switch (from(p).backend) {
            .wayland => |c| c.get_primary(),
            .x11 => |c| c.get_primary(),
        } orelse return null;
        return .new_string(text);
    }

    fn readClipboard(p: *platform.Platform) ?platform.ClipboardItem {
        const text = switch (from(p).backend) {
            .wayland => |c| c.get_clipboard(),
            .x11 => |c| c.get_clipboard(),
        } orelse return null;
        return .new_string(text);
    }
};

/// Picks the best display connection: Wayland, then X11.
pub fn create(allocator: std.mem.Allocator) !*platform.Platform {
    const backend: Backend = blk: {
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            if (wayland.WaylandConnection.connect(allocator)) |c| {
                break :blk .{ .wayland = c };
            } else |err| {
                std.log.warn("linux: wayland unavailable ({s}), trying X11", .{@errorName(err)});
            }
        }
        if (std.c.getenv("DISPLAY") != null) {
            if (x11.X11Connection.connect(allocator)) |c| {
                break :blk .{ .x11 = c };
            } else |err| {
                std.log.warn("linux: X11 unavailable ({s})", .{@errorName(err)});
            }
        }
        return error.NoDisplay;
    };
    errdefer backend.deinit();
    const efd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (efd < 0) return error.EventFdFailed;
    const self = try allocator.create(LinuxPlatform);
    self.* = .{ .allocator = allocator, .backend = backend, .wake_fd = efd };
    return &self.platform;
}
