//! Linux platform (GPUI `gpui_linux`): Wayland when WAYLAND_DISPLAY is set and
//! libwayland-client loads, else X11 when DISPLAY is set. Both are loaded with
//! dlopen, so the binary has no link-time dependency on either.

const std = @import("std");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");
const input = @import("linux/input.zig");
const system_notifications = @import("linux/system_notifications.zig");
const power = @import("linux/power.zig");
const portal = @import("linux/portal.zig");
const launch = @import("linux/launch.zig");
const headless = @import("headless.zig");
pub const wayland = @import("linux/wayland.zig");
pub const x11 = @import("linux/x11.zig");

extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;
const EFD_CLOEXEC: c_int = 0o2000000;
const EFD_NONBLOCK: c_int = 0o4000;

/// The connection the platform uses right now (GPUI `DisplayConnection`). Headless is a
/// `HeadlessPlatform` used as the state of a platform with no display: its windows lay out and take
/// input but draw nothing, and it has no cursor, clipboard selection or layout of its own.
pub const Backend = union(enum) {
    headless: *headless.HeadlessPlatform,
    wayland: *wayland.WaylandConnection,
    x11: *x11.X11Connection,

    /// Frame interval used while a headless window wants a frame, in milliseconds (about 60 Hz).
    /// Headless has no display to pace frames.
    ///
    /// Deliberately naive: a fixed timer, not the refresh rate of any display. A faster version
    /// would wait for a real frame clock.
    const headless_frame_ms: i32 = 16;

    fn fd(self: Backend) c_int {
        return switch (self) {
            .headless => -1,
            .wayland => |c| c.fd(),
            .x11 => |c| c.fd(),
        };
    }
    /// A descriptor the backend is reading without blocking, such as a drag's file list.
    fn extra_fd(self: Backend) c_int {
        return switch (self) {
            .headless, .x11 => -1,
            .wayland => |c| c.extra_fd(),
        };
    }
    fn on_extra_fd(self: Backend) void {
        switch (self) {
            .wayland => |c| c.on_extra_fd(),
            .headless, .x11 => {},
        }
    }
    fn prepare_wait(self: Backend) bool {
        return switch (self) {
            .headless => false,
            .wayland => |c| c.prepare_wait(),
            .x11 => |c| c.prepare_wait(),
        };
    }
    fn finish_wait(self: Backend, readable: bool) void {
        switch (self) {
            .headless => {},
            .wayland => |c| c.finish_wait(readable),
            .x11 => |c| c.finish_wait(readable),
        }
    }
    fn timeout(self: Backend, now: i64) ?i32 {
        return switch (self) {
            .headless => |h| if (h.frames_pending()) headless_frame_ms else null,
            .wayland => |c| c.repeat_timeout(now),
            .x11 => |c| c.frame_timeout(now),
        };
    }
    /// Draws what the backend has to draw. Headless windows draw their requested frames here.
    fn pump(self: Backend) void {
        switch (self) {
            .headless => |h| {
                h.promote_draw_requests();
                _ = h.draw_requested_frames();
            },
            .wayland => |c| c.pump(),
            .x11 => |c| c.pump(),
        }
    }
    fn reap(self: Backend) void {
        switch (self) {
            .headless => {},
            .wayland => |c| c.reap(),
            .x11 => |c| c.reap(),
        }
    }
    fn live_windows(self: Backend) usize {
        return switch (self) {
            .headless => |h| h.windows.items.len,
            .wayland => |c| c.live_windows(),
            .x11 => |c| c.live_windows(),
        };
    }
    fn is_dead(self: Backend) bool {
        return switch (self) {
            .headless => false,
            .wayland => |c| c.is_dead(),
            .x11 => |c| c.is_dead(),
        };
    }
    /// Releases the connection. Headless state is freed with its windows, which must be closed first.
    fn deinit(self: Backend) void {
        switch (self) {
            .headless => |h| h.platform.deinit(),
            .wayland => |c| c.deinit(),
            .x11 => |c| c.deinit(),
        }
    }
    fn window_appearance(self: Backend) platform.WindowAppearance {
        return switch (self) {
            .headless => |h| h.appearance,
            .wayland => |c| c.appearance_,
            .x11 => |c| c.appearance_,
        };
    }
    fn emit_button_layout_changed(self: Backend) void {
        switch (self) {
            .headless => |h| for (h.windows.items) |w| w.base.emit_button_layout_changed(),
            .wayland => |c| for (c.windows.items) |w| w.base.emit_button_layout_changed(),
            .x11 => |c| for (c.windows.items) |w| w.base.emit_button_layout_changed(),
        }
    }
    fn set_appearance(self: Backend, appearance: platform.WindowAppearance) void {
        switch (self) {
            .headless => |h| h.set_window_appearance(appearance),
            .wayland => |c| c.set_appearance(appearance),
            .x11 => |c| c.set_appearance(appearance),
        }
    }
    /// A headless platform draws no cursor, so there is no theme to load and nothing to resize.
    /// X11 manages the cursor itself, as in GPUI, so only Wayland reloads its theme.
    fn set_cursor_theme(self: Backend, name: []const u8) void {
        switch (self) {
            .headless => {},
            .wayland => |c| c.set_cursor_theme(name),
            .x11 => {},
        }
    }
    fn set_cursor_size(self: Backend, size: u32) void {
        switch (self) {
            .headless => {},
            .wayland => |c| c.set_cursor_size(size),
            .x11 => {},
        }
    }
};

/// The display server a windowed mode connects to (GPUI picks Wayland, then X11, from the environment).
const BackendKind = enum { wayland, x11 };

fn is_set(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0;
}

/// Whether one of the allowed display servers is named in `environment` (GPUI `select_backend`).
fn names_allowed_server(allowed: platform.WindowingModes, environment: platform.GraphicalEnvironment) bool {
    return (allowed.wayland and is_set(environment.wayland_display)) or (allowed.x11 and is_set(environment.x11_display));
}

pub const LinuxPlatform = struct {
    allocator: std.mem.Allocator,
    platform: platform.Platform = .{ .vtable = &vtable },
    backend: Backend,
    /// Written by `wake` from any thread; drained by the event loop.
    wake_fd: c_int,
    quit_requested: bool = false,
    /// The modes this platform may start in or switch to (GPUI `allowed_modes`).
    allowed_modes: platform.WindowingModes,
    /// The mode to start in, applied by `run`. Windowed in the process's own environment when unset.
    initial_windowing: ?platform.OwnedWindowingRequest = null,
    /// Set while the loop pumps the backend. A switch then fails: it would close the connection whose
    /// events are being dispatched. The App only switches from the foreground executor, so this is a
    /// guard for code that runs an event handler by hand.
    dispatching: bool = false,
    app: ?*app_mod.App = null,
    /// Menus are stored, as in GPUI's Linux platform, but Linux has no menu bar to draw them in.
    menus: platform.app_menu.MenuStore = .{},
    /// System notifications over the session bus. Connects on the first notification, and any
    /// failure there stays inside it: nothing here can close a window.
    notifications: system_notifications.State,
    /// The desktop portals: the settings (appearance, cursor), file dialogs and OpenURI. Started in `run`.
    portal: portal.State,
    /// The power mode from power-profiles-daemon on the system bus. Started in `run`.
    power: power.State,
    /// Starts the programs the platform runs. Tests replace it, so no test starts a program.
    launcher: launch.Launcher = .{},
    /// The titlebar button layout: GPUI's fallback until the settings portal reports the desktop's.
    button_layout: platform.WindowButtonLayout = platform.WindowButtonLayout.linux_default(),
    /// Where `app_path` writes the path of the executable.
    app_path_buf: [4096]u8 = undefined,

    const vtable: platform.Platform.VTable = .{
        .run = run,
        .quit = quit,
        .deinit = deinit,
        .open_window = openWindow,
        .button_layout = buttonLayout,
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
        .power_mode = powerMode,
        .on_power_mode_change = onPowerModeChange,
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
        .set_initial_windowing = setInitialWindowing,
        .request_windowing = requestWindowing,
    };

    fn powerMode(p: *platform.Platform) platform.PowerMode {
        return from(p).power.current();
    }

    fn onPowerModeChange(p: *platform.Platform, listener: platform.PowerListener) void {
        from(p).power.on_change(listener);
    }

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
            .button_layout => |text| self.set_button_layout(text),
        }
    }

    /// Stores the layout the desktop reports and tells every window, as GPUI does on each event.
    /// Text that does not parse falls back to GPUI's default layout.
    fn set_button_layout(self: *LinuxPlatform, text: []const u8) void {
        self.button_layout = platform.WindowButtonLayout.parse(text) catch |err| blk: {
            std.log.warn("linux: button layout {s}: {s}", .{ text, @errorName(err) });
            break :blk platform.WindowButtonLayout.linux_default();
        };
        self.backend.emit_button_layout_changed();
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

    /// Headless has no compositor, so its name is empty, as on platforms without one (GPUI
    /// `compositor_name` on a headless platform).
    fn compositorName(p: *platform.Platform) []const u8 {
        return switch (from(p).backend) {
            .headless => "",
            .wayland => "Wayland",
            .x11 => "X11",
        };
    }

    /// The variables of the display server this connection uses (GPUI `graphical_environment`).
    /// The activation token is never kept: the connection has used it.
    fn graphicalEnvironment(p: *platform.Platform) ?platform.GraphicalEnvironment {
        // Headless is connected to no display server, so there is no environment to report.
        if (std.meta.activeTag(from(p).backend) == .headless) return null;
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
            .headless, .wayland => null,
            .x11 => |c| c.window_stack(),
        };
    }

    /// Headless draws no cursor, so there is nothing to hide.
    fn hideCursorUntilMouseMoves(p: *platform.Platform) void {
        switch (from(p).backend) {
            .headless => {},
            .wayland => |c| c.hide_cursor_until_mouse_moves(),
            .x11 => |c| c.hide_cursor_until_mouse_moves(),
        }
    }

    /// Headless draws no cursor, so it is never hidden.
    fn isCursorVisible(p: *platform.Platform) bool {
        return switch (from(p).backend) {
            .headless => true,
            .wayland => |c| c.is_cursor_visible(),
            .x11 => |c| c.is_cursor_visible(),
        };
    }

    fn keyboardLayout(p: *platform.Platform) platform.KeyboardLayout {
        return switch (from(p).backend) {
            .headless => |h| h.platform.keyboard_layout(),
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
        connect_initially(self);
        self.portal.start();
        self.power.start();
        on_launch(app);
        while (true) {
            _ = app.foreground_executor().run_pending();
            self.dispatching = true;
            self.backend.pump();
            self.backend.reap();
            self.dispatching = false;
            // The loop ends when the App quits, as GPUI's does: closing the last window quits only
            // under the app's quit mode, so an app with `QuitMode.explicit` keeps running headless.
            if (self.quit_requested) break;
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
        var fds = [6]std.posix.pollfd{
            .{ .fd = self.backend.fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.backend.extra_fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.notifications.bus_socket(), .events = self.notifications.bus_events(), .revents = 0 },
            .{ .fd = self.portal.bus_socket(), .events = self.portal.bus_events(), .revents = 0 },
            .{ .fd = self.power.bus_socket(), .events = self.power.bus_events(), .revents = 0 },
        };
        if (!has_pending) {
            _ = std.posix.poll(&fds, timeout) catch 0;
        }
        self.backend.finish_wait(fds[0].revents != 0);
        if (fds[2].revents != 0) self.backend.on_extra_fd();
        if (fds[3].revents != 0) self.notifications.on_bus_poll(fds[3].revents);
        if (fds[4].revents != 0) self.portal.on_bus_poll(fds[4].revents);
        if (fds[5].revents != 0) self.power.on_bus_poll(fds[5].revents);
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
        if (self.initial_windowing) |owned| owned.deinit();
        self.initial_windowing = null;
        _ = std.os.linux.close(self.wake_fd);
        self.menus.deinit();
        self.notifications.deinit();
        self.portal.deinit();
        self.power.deinit();
        self.allocator.destroy(self);
    }

    fn wake(p: *platform.Platform) void {
        const self = from(p);
        var one: u64 = 1;
        _ = std.os.linux.write(self.wake_fd, @ptrCast(&one), 8);
    }

    /// The layout the settings portal reported, or GPUI's fallback until it does.
    fn buttonLayout(p: *platform.Platform) ?platform.WindowButtonLayout {
        return from(p).button_layout;
    }

    /// Headless windows are plain windows: like the headless platform, they take no parent, so popups
    /// open as ordinary windows there.
    fn openWindow(p: *platform.Platform, options: window_mod.WindowOptions, parent: ?*platform.PlatformWindow) anyerror!*platform.PlatformWindow {
        const self = from(p);
        return switch (self.backend) {
            .headless => |h| h.open_window_base(options),
            .wayland => |c| &(try c.open_window(options, parent)).base,
            .x11 => |c| &(try c.open_window(options)).base,
        };
    }

    fn displays(p: *platform.Platform) []const platform.Display {
        return switch (from(p).backend) {
            .headless => |h| h.platform.displays(),
            .wayland => |c| c.displays(),
            .x11 => |c| c.displays(),
        };
    }

    fn setCursorStyle(p: *platform.Platform, style: platform.CursorStyle) void {
        switch (from(p).backend) {
            .headless => |h| h.platform.set_cursor_style(style),
            .wayland => |c| c.set_cursor_style(style),
            .x11 => |c| c.set_cursor_style(style),
        }
    }

    fn writeClipboard(p: *platform.Platform, item: platform.ClipboardItem) void {
        const text = item.text() orelse return;
        switch (from(p).backend) {
            .headless => |h| h.platform.write_to_clipboard(item),
            .wayland => |c| _ = c.set_clipboard(text),
            .x11 => |c| _ = c.set_clipboard(text),
        }
    }

    /// Headless has no selection to write to, so the write is dropped, as GPUI drops it where no
    /// selection exists.
    fn writePrimary(p: *platform.Platform, item: platform.ClipboardItem) void {
        const text = item.text() orelse return;
        switch (from(p).backend) {
            .headless => {},
            .wayland => |c| _ = c.set_primary(text),
            .x11 => |c| _ = c.set_primary(text),
        }
    }

    fn readPrimary(p: *platform.Platform) ?platform.ClipboardItem {
        const text = switch (from(p).backend) {
            .headless => return null,
            .wayland => |c| c.get_primary(),
            .x11 => |c| c.get_primary(),
        } orelse return null;
        return .new_string(text);
    }

    fn readClipboard(p: *platform.Platform) ?platform.ClipboardItem {
        const text = switch (from(p).backend) {
            .headless => |h| return h.platform.read_from_clipboard(),
            .wayland => |c| c.get_clipboard(),
            .x11 => |c| c.get_clipboard(),
        } orelse return null;
        return .new_string(text);
    }
};

/// Makes a headless platform's state: a `HeadlessPlatform` with no displays, since a headless Linux
/// platform reports none (GPUI's headless platform has no outputs).
fn headless_state(allocator: std.mem.Allocator) *headless.HeadlessPlatform {
    const state = headless.HeadlessPlatform.from(headless.HeadlessPlatform.create(allocator));
    state.display_count = 0;
    return state;
}

/// Creates the Linux platform, allowed to start or switch to the modes in `allowed_modes` (GPUI
/// `linux_platform`). It starts headless: `run` connects it to the display its initial mode names, so
/// a platform created without a display can switch to one later. It connects to nothing here.
pub fn create(allocator: std.mem.Allocator, allowed_modes: platform.WindowingModes) !*platform.Platform {
    const efd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (efd < 0) return error.EventFdFailed;
    errdefer _ = std.os.linux.close(efd);
    const self = try allocator.create(LinuxPlatform);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .backend = .{ .headless = headless_state(allocator) },
        .wake_fd = efd,
        .allowed_modes = allowed_modes,
        .notifications = system_notifications.State.init(allocator, self, LinuxPlatform.deliverNotification),
        .portal = portal.State.init(allocator, .{ .ctx = self, .func = LinuxPlatform.onSetting }),
        .power = power.State.init(allocator),
    };
    return &self.platform;
}

/// Starts the platform in its initial mode (GPUI `connect_initially`). GPUI panics when the initial
/// display server cannot be reached; ZUI logs it and stays headless when headless is allowed, since an
/// app that can run headless should still start. It panics only when headless is not allowed.
fn connect_initially(self: *LinuxPlatform) void {
    const owned = self.initial_windowing;
    self.initial_windowing = null;
    defer if (owned) |o| o.deinit();
    const request: platform.WindowingRequest = if (owned) |o| o.request else .{ .windowed = platform.detect_graphical_environment() };
    switch (request) {
        .headless => return,
        .windowed => |environment| {
            if (!names_allowed_server(self.allowed_modes, environment)) {
                if (self.allowed_modes.headless) return;
                std.debug.panic("{any} does not allow headless mode, and no allowed display server was given", .{self.allowed_modes});
            }
            const next = connect_any(self, environment) catch |err| {
                if (self.allowed_modes.headless) {
                    std.log.warn("linux: display server unavailable ({s}); running headless", .{@errorName(err)});
                    return;
                }
                std.debug.panic("linux: cannot connect to the display server: {s}", .{@errorName(err)});
            };
            replace_backend(self, next);
        },
    }
}

/// Connects to the first allowed display server the environment names, Wayland before X11 (GPUI
/// `DisplayConnection::new`). Falls back to X11 when Wayland names a server that cannot be reached,
/// as ZUI always has. Returns the last error when neither connects.
fn connect_any(self: *LinuxPlatform, environment: platform.GraphicalEnvironment) !Backend {
    var last_error: anyerror = error.NoAllowedDisplayServer;
    if (self.allowed_modes.wayland and is_set(environment.wayland_display)) {
        if (connect(self, .wayland, environment)) |connection| {
            return connection;
        } else |err| last_error = err;
    }
    if (self.allowed_modes.x11 and is_set(environment.x11_display)) {
        if (connect(self, .x11, environment)) |connection| {
            return connection;
        } else |err| last_error = err;
    }
    return last_error;
}

/// Connects to the display server `kind` names in `environment` (GPUI `WaylandConnection::attach` and
/// `X11Client::new`). The connection is attached to this platform, so its windows report to it.
fn connect(self: *LinuxPlatform, kind: BackendKind, environment: platform.GraphicalEnvironment) !Backend {
    switch (kind) {
        .wayland => {
            const socket = try wayland_socket_path(self.allocator, environment);
            defer self.allocator.free(socket);
            const connection = try wayland.WaylandConnection.connect(self.allocator, socket);
            connection.platform_ = &self.platform;
            return .{ .wayland = connection };
        },
        .x11 => {
            const display = environment.x11_display orelse return error.NoDisplay;
            const name = try self.allocator.dupeSentinel(u8, display, 0);
            defer self.allocator.free(name);
            const connection = try x11.X11Connection.connect(self.allocator, name);
            connection.platform_ = &self.platform;
            return .{ .x11 = connection };
        },
    }
}

/// The Wayland socket path the environment names: an absolute path as it is, or a name relative to
/// `XDG_RUNTIME_DIR`. Resolved here so that connecting never reads the process environment.
fn wayland_socket_path(allocator: std.mem.Allocator, environment: platform.GraphicalEnvironment) ![:0]u8 {
    const name = environment.wayland_display orelse return error.NoWaylandDisplay;
    if (std.fs.path.isAbsolute(name)) return allocator.dupeSentinel(u8, name, 0);
    const runtime_dir = environment.xdg_runtime_dir orelse return error.NoRuntimeDir;
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_dir, name }, 0);
}

/// Installs `next` as the connection, then drops the previous one. The new connection is installed
/// first, since dropping a connection can call back into the platform. Displays and the keyboard
/// layout belong to the connection, so the app is told they may have changed.
///
/// Deliberately naive: every switch tears the connection down and connects again, including a
/// switch to headless, which builds a new headless state. A faster version would keep the old
/// connection alive while it is unused.
fn replace_backend(self: *LinuxPlatform, next: Backend) void {
    const previous = self.backend;
    self.backend = next;
    previous.deinit();
    self.platform.emit_keyboard_layout_changed();
    self.platform.emit_displays_changed();
}

/// Validates a switch and applies it now (GPUI `Platform::request_windowing`). The App calls this
/// from the foreground executor, between event-loop iterations, so no event source is mid-dispatch.
fn request_mode(self: *LinuxPlatform, request: platform.WindowingRequest) !void {
    if (self.dispatching) return error.WindowingDuringDispatch;
    if (self.backend.live_windows() > 0) return error.WindowsAreOpen;
    switch (request) {
        .headless => {
            if (!self.allowed_modes.headless) return error.HeadlessNotAllowed;
            if (std.meta.activeTag(self.backend) == .headless) return error.AlreadyHeadless;
            replace_backend(self, .{ .headless = headless_state(self.allocator) });
        },
        .windowed => |environment| {
            if (std.meta.activeTag(self.backend) != .headless) return error.AlreadyWindowed;
            if (!names_allowed_server(self.allowed_modes, environment)) return error.NoAllowedDisplayServer;
            replace_backend(self, try connect_any(self, environment));
        },
    }
}

fn setInitialWindowing(p: *platform.Platform, request: platform.WindowingRequest) anyerror!void {
    const self = LinuxPlatform.from(p);
    switch (request) {
        .headless => if (!self.allowed_modes.headless) return error.HeadlessNotAllowed,
        .windowed => |environment| if (!names_allowed_server(self.allowed_modes, environment) and !self.allowed_modes.headless) {
            return error.NoAllowedDisplayServer;
        },
    }
    const owned = try platform.OwnedWindowingRequest.dupe(self.allocator, request);
    if (self.initial_windowing) |previous| previous.deinit();
    self.initial_windowing = owned;
}

fn requestWindowing(p: *platform.Platform, request: platform.WindowingRequest) anyerror!void {
    return request_mode(LinuxPlatform.from(p), request);
}

// A socket path that does not exist, so that connecting fails without reaching any real session.
const missing_wayland = platform.GraphicalEnvironment{ .wayland_display = "/zui-test/wayland-display-does-not-exist" };

test "display_modes_limit_switching: a headless-only platform refuses a display (GPUI display_modes_limit_switching)" {
    const p = try create(std.testing.allocator, platform.WindowingModes.HEADLESS);
    defer p.deinit();
    const self = LinuxPlatform.from(p);
    try std.testing.expectError(error.NoAllowedDisplayServer, request_mode(self, .{ .windowed = missing_wayland }));
    try std.testing.expectError(error.AlreadyHeadless, request_mode(self, .headless));
    try std.testing.expect(p.graphical_environment() == null);
    try std.testing.expectEqualStrings("", p.compositor_name());
}

test "failed attach preserves the headless platform and allows a retry (GPUI failed_wayland_attach_preserves_headless_app_and_allows_retry)" {
    const p = try create(std.testing.allocator, .all());
    defer p.deinit();
    const self = LinuxPlatform.from(p);
    for (0..2) |_| {
        if (request_mode(self, .{ .windowed = missing_wayland })) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
        try std.testing.expect(std.meta.activeTag(self.backend) == .headless);
    }
}

test "headless windows block switching until they close (GPUI headless_windows_block_switching_to_a_display_server)" {
    const p = try create(std.testing.allocator, .all());
    defer p.deinit();
    const self = LinuxPlatform.from(p);
    const window = try p.open_window(.{}, null);
    try std.testing.expectError(error.WindowsAreOpen, request_mode(self, .{ .windowed = missing_wayland }));
    window.close();
    if (request_mode(self, .{ .windowed = missing_wayland })) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "the initial windowed mode falls back to headless when no display is named and headless is allowed" {
    const p = try create(std.testing.allocator, .all());
    defer p.deinit();
    try p.set_initial_windowing(.{ .windowed = .{} });
    connect_initially(LinuxPlatform.from(p));
    try std.testing.expect(std.meta.activeTag(LinuxPlatform.from(p).backend) == .headless);
}

test "set_initial_windowing refuses a mode the platform does not allow (GPUI with_windowing)" {
    const p = try create(std.testing.allocator, platform.WindowingModes.X11);
    defer p.deinit();
    try std.testing.expectError(error.HeadlessNotAllowed, p.set_initial_windowing(.headless));
}

test "a headless window asks for frames that the loop draws, then stops asking" {
    const p = try create(std.testing.allocator, .all());
    defer p.deinit();
    const self = LinuxPlatform.from(p);
    _ = try p.open_window(.{}, null);
    try std.testing.expect(self.backend.timeout(0) != null);
    self.backend.pump();
    try std.testing.expect(self.backend.timeout(0) == null);
}
