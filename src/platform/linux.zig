//! Linux platform (GPUI `gpui_linux`): Wayland when WAYLAND_DISPLAY is set and
//! libwayland-client loads, else X11 when DISPLAY is set. Both are loaded with
//! dlopen, so the binary has no link-time dependency on either.

const std = @import("std");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");
const input = @import("linux/input.zig");
const system_notifications = @import("linux/system_notifications.zig");
const portal = @import("linux/portal.zig");
const launch = @import("linux/launch.zig");
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
    fn window_appearance(self: Backend) platform.WindowAppearance {
        return switch (self) {
            .wayland => |c| c.appearance_,
            .x11 => |c| c.appearance_,
        };
    }
    fn set_appearance(self: Backend, appearance: platform.WindowAppearance) void {
        switch (self) {
            .wayland => |c| c.set_appearance(appearance),
            .x11 => |c| c.set_appearance(appearance),
        }
    }
    /// X11 manages the cursor itself, as in GPUI, so only Wayland reloads its theme.
    fn set_cursor_theme(self: Backend, name: []const u8) void {
        switch (self) {
            .wayland => |c| c.set_cursor_theme(name),
            .x11 => {},
        }
    }
    fn set_cursor_size(self: Backend, size: u32) void {
        switch (self) {
            .wayland => |c| c.set_cursor_size(size),
            .x11 => {},
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
    /// Menus are stored, as in GPUI's Linux platform, but Linux has no menu bar to draw them in.
    menus: platform.app_menu.MenuStore = .{},
    /// System notifications over the session bus. Connects on the first notification, and any
    /// failure there stays inside it: nothing here can close a window.
    notifications: system_notifications.State,
    /// The desktop portals: the settings (appearance, cursor), file dialogs and OpenURI. Started in `run`.
    portal: portal.State,
    /// Starts the programs the platform runs. Tests replace it, so no test starts a program.
    launcher: launch.Launcher = .{},
    /// Where `app_path` writes the path of the executable.
    app_path_buf: [4096]u8 = undefined,

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
        .set_menus = setMenus,
        .get_menus = getMenus,
        .keyboard_layout = keyboardLayout,
        .compositor_name = compositorName,
        .graphical_environment = graphicalEnvironment,
        .window_stack = windowStack,
        .hide_cursor_until_mouse_moves = hideCursorUntilMouseMoves,
        .is_cursor_visible = isCursorVisible,
        .set_app_identity = setAppIdentity,
        .show_system_notification = showNotification,
        .dismiss_system_notification = dismissNotification,
        .open_url = openUrl,
        .window_appearance = windowAppearance,
        .prompt_for_paths = promptForPaths,
        .prompt_for_new_path = promptForNewPath,
        .reveal_path = revealPath,
        .open_with_system = openWithSystem,
        .restart = restartApp,
        .app_path = appPath,
    };

    fn windowAppearance(p: *platform.Platform) platform.WindowAppearance {
        return from(p).backend.window_appearance();
    }

    /// The desktop's settings as the portal reports them (GPUI's `XDPEventSource` handler).
    fn onSetting(raw: *anyopaque, setting: portal.Setting) void {
        const self: *LinuxPlatform = @ptrCast(@alignCast(raw));
        switch (setting) {
            .color_scheme => |appearance| self.backend.set_appearance(appearance),
            .cursor_theme => |name| self.backend.set_cursor_theme(name),
            .cursor_size => |size| self.backend.set_cursor_size(size),
        }
    }

    /// A file chooser's answer goes back to the caller's completion, then the dialog is freed.
    const PathsDialog = struct {
        gpa: std.mem.Allocator,
        completion: platform.PathsCompletion,

        fn complete(raw: *anyopaque, outcome: portal.Outcome) void {
            const dialog: *PathsDialog = @ptrCast(@alignCast(raw));
            const gpa = dialog.gpa;
            defer gpa.destroy(dialog);
            switch (outcome) {
                .cancelled => dialog.completion.call(null),
                .failed => |err| dialog.completion.call(err),
                .answered => |uris| {
                    var arena = std.heap.ArenaAllocator.init(gpa);
                    defer arena.deinit();
                    const paths = collect_paths(arena.allocator(), uris) catch |err| return dialog.completion.call(err);
                    dialog.completion.call(paths);
                },
            }
        }
    };

    /// The `file://` URIs as local paths. Other URIs are left out, as GPUI leaves them out.
    fn collect_paths(arena: std.mem.Allocator, uris: []const []const u8) ![]const []const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        for (uris) |uri| {
            var buf: [4096]u8 = undefined;
            const path = portal.file_uri_to_path(uri, &buf) orelse continue;
            try paths.append(arena, try arena.dupe(u8, path));
        }
        return paths.items;
    }

    const PathDialog = struct {
        gpa: std.mem.Allocator,
        completion: platform.PathCompletion,

        fn complete(raw: *anyopaque, outcome: portal.Outcome) void {
            const dialog: *PathDialog = @ptrCast(@alignCast(raw));
            const gpa = dialog.gpa;
            defer gpa.destroy(dialog);
            switch (outcome) {
                .cancelled => dialog.completion.call(null),
                .failed => |err| dialog.completion.call(err),
                .answered => |uris| {
                    if (uris.len == 0) return dialog.completion.call(null);
                    // The buffer lives for this call, which is as long as the completion's path is valid.
                    var buf: [4096]u8 = undefined;
                    const path = portal.file_uri_to_path(uris[0], &buf) orelse return dialog.completion.call(null);
                    dialog.completion.call(path);
                },
            }
        }
    };

    fn promptForPaths(p: *platform.Platform, options: platform.PathPromptOptions, completion: platform.PathsCompletion) void {
        const self = from(p);
        const dialog = self.allocator.create(PathsDialog) catch return completion.call(error.OutOfMemory);
        dialog.* = .{ .gpa = self.allocator, .completion = completion };
        self.portal.open_file(.{
            .title = if (options.directories) "Open Folder" else "Open File",
            .accept_label = options.prompt,
            .directory = options.directories,
            .multiple = options.multiple,
        }, .{ .ctx = dialog, .func = PathsDialog.complete });
    }

    fn promptForNewPath(p: *platform.Platform, directory: []const u8, suggested_name: ?[]const u8, completion: platform.PathCompletion) void {
        const self = from(p);
        const dialog = self.allocator.create(PathDialog) catch return completion.call(error.OutOfMemory);
        dialog.* = .{ .gpa = self.allocator, .completion = completion };
        self.portal.save_file(.{
            .title = "Save File",
            .current_folder = directory,
            .current_name = suggested_name,
        }, .{ .ctx = dialog, .func = PathDialog.complete });
    }

    /// Opens a URL the way GPUI does: the launchers first, then the OpenURI portal. The launchers
    /// run on a background thread; the portal is only used on the main thread.
    fn openUrl(p: *platform.Platform, url: []const u8) void {
        const self = from(p);
        const app = self.app orelse return std.log.warn("open_url before the app runs", .{});
        const copy = self.allocator.dupe(u8, url) catch return;
        var task = app.background_executor().spawn(openUrlInBackground, .{ self, copy, graphicalEnvironment(p) orelse platform.GraphicalEnvironment{} });
        task.detach();
    }

    fn openUrlInBackground(self: *LinuxPlatform, url: []u8, environment: platform.GraphicalEnvironment) void {
        if (launch.open_with_launchers(self.launcher, url, environment)) return self.allocator.free(url);
        const app = self.app orelse return self.allocator.free(url);
        var task = app.foreground_executor().to_send().spawn(openUriOnMain, .{ self, url });
        task.detach();
    }

    fn openUriOnMain(self: *LinuxPlatform, url: []u8) void {
        defer self.allocator.free(url);
        self.portal.open_uri(url, null);
    }

    fn openWithSystem(p: *platform.Platform, path: []const u8) void {
        const self = from(p);
        const app = self.app orelse return std.log.warn("open_with_system before the app runs", .{});
        const copy = self.allocator.dupe(u8, path) catch return;
        var task = app.background_executor().spawn(openWithSystemInBackground, .{ self, copy, graphicalEnvironment(p) orelse platform.GraphicalEnvironment{} });
        task.detach();
    }

    fn openWithSystemInBackground(self: *LinuxPlatform, path: []u8, environment: platform.GraphicalEnvironment) void {
        defer self.allocator.free(path);
        launch.open_with_system(self.launcher, path, environment);
    }

    /// Shows the directory of `path` (the path itself when it is one), as GPUI does when the portal
    /// cannot. GPUI tries the OpenDirectory portal first, which needs a file descriptor sent over
    /// D-Bus; `dbus.zig` cannot send one yet.
    fn revealPath(p: *platform.Platform, path: []const u8) void {
        const self = from(p);
        const app = self.app orelse return std.log.warn("reveal_path before the app runs", .{});
        const copy = self.allocator.dupe(u8, path) catch return;
        var task = app.background_executor().spawn(revealPathInBackground, .{ self, copy, graphicalEnvironment(p) orelse platform.GraphicalEnvironment{} });
        task.detach();
    }

    fn revealPathInBackground(self: *LinuxPlatform, path: []u8, environment: platform.GraphicalEnvironment) void {
        defer self.allocator.free(path);
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
        const io = threaded.io();
        const is_directory = if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| stat.kind == .directory else |_| false;
        const directory = if (is_directory) path else std.fs.path.dirname(path) orelse "";
        _ = launch.open_with_launchers(self.launcher, directory, environment);
    }

    /// Starts a new process running the app (GPUI's `restart`), then quits this one. The new
    /// process waits for this one to exit first.
    fn restartApp(p: *platform.Platform, binary_path: ?[]const u8, arguments: []const []const u8) void {
        const self = from(p);
        const path = binary_path orelse (appPath(p) catch |err| {
            return std.log.err("cannot restart: no app path ({s})", .{@errorName(err)});
        });
        const pid: u32 = @intCast(std.os.linux.getpid());
        launch.restart(self.launcher, self.allocator, pid, path, arguments) catch |err| {
            return std.log.err("failed to start the restart script: {s}", .{@errorName(err)});
        };
        quit(p);
    }

    fn appPath(p: *platform.Platform) anyerror![]const u8 {
        const self = from(p);
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
        const len = try std.process.executablePath(threaded.io(), &self.app_path_buf);
        return self.app_path_buf[0..len];
    }

    fn compositorName(p: *platform.Platform) []const u8 {
        return switch (from(p).backend) {
            .wayland => "Wayland",
            .x11 => "X11",
        };
    }

    /// The variables of the display server this connection uses (GPUI `graphical_environment`).
    /// The activation token is never kept: the connection has used it.
    fn graphicalEnvironment(p: *platform.Platform) ?platform.GraphicalEnvironment {
        const is_wayland = std.meta.activeTag(from(p).backend) == .wayland;
        return .{
            .wayland_display = if (is_wayland) envValue("WAYLAND_DISPLAY") else null,
            .x11_display = if (is_wayland) null else envValue("DISPLAY"),
            .xdg_runtime_dir = envValue("XDG_RUNTIME_DIR"),
        };
    }

    fn envValue(name: [*:0]const u8) ?[]const u8 {
        const v = std.c.getenv(name) orelse return null;
        return std.mem.span(v);
    }

    /// Wayland has no window stack a client can read (GPUI's Wayland returns none too).
    fn windowStack(p: *platform.Platform) ?[]const *platform.PlatformWindow {
        return switch (from(p).backend) {
            .wayland => null,
            .x11 => |c| c.window_stack(),
        };
    }

    fn hideCursorUntilMouseMoves(p: *platform.Platform) void {
        switch (from(p).backend) {
            .wayland => |c| c.hide_cursor_until_mouse_moves(),
            .x11 => |c| c.hide_cursor_until_mouse_moves(),
        }
    }

    fn isCursorVisible(p: *platform.Platform) bool {
        return switch (from(p).backend) {
            .wayland => |c| c.is_cursor_visible(),
            .x11 => |c| c.is_cursor_visible(),
        };
    }

    fn keyboardLayout(p: *platform.Platform) platform.KeyboardLayout {
        return switch (from(p).backend) {
            .wayland => |c| c.keyboard_layout(),
            .x11 => |c| c.keyboard_layout(),
        };
    }


    fn setAppIdentity(p: *platform.Platform, _: []const u8, name: []const u8) void {
        from(p).notifications.set_app_name(name);
    }

    fn showNotification(p: *platform.Platform, notification: platform.SystemNotification) void {
        from(p).notifications.show(notification);
    }

    fn dismissNotification(p: *platform.Platform, tag: []const u8) void {
        from(p).notifications.dismiss(tag);
    }

    /// Where notification responses go: to the app, on the main thread, from the event loop.
    fn deliverNotification(raw: *anyopaque, response: platform.SystemNotificationResponse) void {
        const self: *LinuxPlatform = @ptrCast(@alignCast(raw));
        if (self.app) |app| app.dispatch_system_notification_response(response);
    }

    fn setMenus(p: *platform.Platform, menus: []const platform.app_menu.Menu) void {
        from(p).menus.set(from(p).allocator, menus);
    }

    fn getMenus(p: *platform.Platform) ?[]const platform.app_menu.OwnedMenu {
        return from(p).menus.get();
    }

    pub fn from(p: *platform.Platform) *LinuxPlatform {
        return @fieldParentPtr("platform", p);
    }

    fn run(p: *platform.Platform, app: *app_mod.App, on_launch: *const fn (*anyopaque) void) void {
        const self = from(p);
        self.app = app;
        self.portal.start();
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
        var fds = [5]std.posix.pollfd{
            .{ .fd = self.backend.fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.backend.extra_fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.notifications.bus_socket(), .events = self.notifications.bus_events(), .revents = 0 },
            .{ .fd = self.portal.bus_socket(), .events = self.portal.bus_events(), .revents = 0 },
        };
        if (!has_pending) {
            _ = std.posix.poll(&fds, timeout) catch 0;
        }
        self.backend.finish_wait(fds[0].revents != 0);
        if (fds[2].revents != 0) self.backend.on_extra_fd();
        if (fds[3].revents != 0) self.notifications.on_bus_poll(fds[3].revents);
        if (fds[4].revents != 0) self.portal.on_bus_poll(fds[4].revents);
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
        self.menus.deinit();
        self.notifications.deinit();
        self.portal.deinit();
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
    self.* = .{
        .allocator = allocator,
        .backend = backend,
        .wake_fd = efd,
        .notifications = system_notifications.State.init(allocator, self, LinuxPlatform.deliverNotification),
        .portal = portal.State.init(allocator, .{ .ctx = self, .func = LinuxPlatform.onSetting }),
    };
    // Outputs that change after this point are reported to the app through the platform.
    switch (self.backend) {
        .wayland => |c| c.platform_ = &self.platform,
        .x11 => |c| c.platform_ = &self.platform,
    }
    return &self.platform;
}
