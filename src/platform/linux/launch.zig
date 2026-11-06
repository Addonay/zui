//! Starting programs for the Linux platform: the launchers GPUI's `open_uri`, `reveal_path` and
//! `open_with_system` run (the `open` crate 5.3, which GPUI links), and the restart script of
//! `restart`.
//!
//! Every program the platform starts goes through `Launcher`. Its functions are pointers, so a test
//! replaces them with a recorder and no program is ever started by a test.

const std = @import("std");
const platform = @import("../../platform.zig");

/// A program to start. `argv[0]` is looked up in PATH.
pub const Command = struct {
    argv: []const []const u8,
    /// The display variables to set, as GPUI's `GraphicalEnvironment::apply_to` does. Unset ones
    /// are removed from the child's environment.
    environment: platform.GraphicalEnvironment = .{},
};

pub const Launcher = struct {
    ctx: ?*anyopaque = null,
    /// Starts the command and waits for it. Returns its exit code.
    run: *const fn (ctx: ?*anyopaque, command: Command) anyerror!u8 = run_and_wait,
    /// Starts the command in a process group of its own, and does not wait for it.
    start: *const fn (ctx: ?*anyopaque, command: Command) anyerror!void = start_detached,
};

/// The programs `open_uri` tries in order (the `open` crate's list for Linux, without WSL).
const open_programs = [_][]const []const u8{
    &.{"xdg-open"},
    &.{ "gio", "open" },
    &.{"gnome-open"},
    &.{"kde-open"},
};

/// Opens `path` (a file, a directory or a URI) with the first launcher that exits successfully.
/// Returns whether one did.
pub fn open_with_launchers(launcher: Launcher, path: []const u8, environment: platform.GraphicalEnvironment) bool {
    for (open_programs) |prefix| {
        var argv: [3][]const u8 = undefined;
        @memcpy(argv[0..prefix.len], prefix);
        argv[prefix.len] = path;
        const command = Command{ .argv = argv[0 .. prefix.len + 1], .environment = environment };
        const code = launcher.run(launcher.ctx, command) catch |err| {
            std.log.warn("failed to open with {s}: {s}", .{ prefix[0], @errorName(err) });
            continue;
        };
        if (code == 0) return true;
        std.log.warn("{s} exited with status {d}", .{ prefix[0], code });
    }
    return false;
}

/// Opens `path` with xdg-open alone (GPUI's `open_with_system`), logging a failure.
pub fn open_with_system(launcher: Launcher, path: []const u8, environment: platform.GraphicalEnvironment) void {
    const argv = [_][]const u8{ "xdg-open", path };
    const code = launcher.run(launcher.ctx, .{ .argv = &argv, .environment = environment }) catch |err| {
        return std.log.warn("failed to run xdg-open: {s}", .{@errorName(err)});
    };
    if (code != 0) std.log.warn("xdg-open exited with status {d}", .{code});
}

/// Starts the restart script (GPUI's `restart`): it waits for `pid` to exit, then runs `app_path`
/// with `arguments`. The caller quits once this returns without error.
pub fn restart(launcher: Launcher, gpa: std.mem.Allocator, pid: u32, app_path: []const u8, arguments: []const []const u8) !void {
    const pid_text = try std.fmt.allocPrint(gpa, "{d}", .{pid});
    defer gpa.free(pid_text);
    const argv = try gpa.alloc([]const u8, 6 + arguments.len);
    defer gpa.free(argv);
    argv[0] = "/usr/bin/env";
    argv[1] = "bash";
    argv[2] = "-c";
    argv[3] = restart_script;
    argv[4] = pid_text;
    argv[5] = app_path;
    @memcpy(argv[6..], arguments);
    try launcher.start(launcher.ctx, .{ .argv = argv });
}

/// `$0` is the pid, `$1` the app, the rest are its arguments. The arguments are never interpolated
/// into the script, so they cannot change what runs.
const restart_script =
    \\while kill -0 "$0" 2>/dev/null; do
    \\    sleep 0.1
    \\done
    \\app_path="$1"
    \\shift
    \\"$app_path" "$@"
;

fn run_and_wait(_: ?*anyopaque, command: Command) anyerror!u8 {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environment = try environment_map(std.heap.smp_allocator, command.environment);
    defer environment.deinit();
    var child = try std.process.spawn(io, .{ .argv = command.argv, .environ_map = &environment });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn start_detached(_: ?*anyopaque, command: Command) anyerror!void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environment = try environment_map(std.heap.smp_allocator, command.environment);
    defer environment.deinit();
    _ = try std.process.spawn(io, .{
        .argv = command.argv,
        .environ_map = &environment,
        .pgid = 0,
    });
}

/// This process's environment, with the display variables of `graphical` set or removed.
fn environment_map(gpa: std.mem.Allocator, graphical: platform.GraphicalEnvironment) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        try map.put(pair[0..eq], pair[eq + 1 ..]);
    }
    try set_or_remove(&map, "WAYLAND_DISPLAY", graphical.wayland_display);
    try set_or_remove(&map, "DISPLAY", graphical.x11_display);
    try set_or_remove(&map, "XDG_RUNTIME_DIR", graphical.xdg_runtime_dir);
    return map;
}

fn set_or_remove(map: *std.process.Environ.Map, name: []const u8, value: ?[]const u8) !void {
    if (value) |v| return map.put(name, v);
    _ = map.swapRemove(name);
}

test "launch: open_with_launchers tries each launcher in order until one succeeds" {
    const Recorder = struct {
        argvs: [4][3][]const u8 = undefined,
        lens: [4]usize = @splat(0),
        calls: usize = 0,

        fn run(raw: ?*anyopaque, command: Command) anyerror!u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.calls == self.argvs.len) return error.TooManyCalls;
            @memcpy(self.argvs[self.calls][0..command.argv.len], command.argv);
            self.lens[self.calls] = command.argv.len;
            self.calls += 1;
            // The first launcher is missing; the second opens the file.
            if (self.calls == 1) return error.FileNotFound;
            return 0;
        }
    };
    var recorder = Recorder{};
    const launcher = Launcher{ .ctx = &recorder, .run = Recorder.run };
    try std.testing.expect(open_with_launchers(launcher, "/tmp/a.txt", .{}));
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqual(@as(usize, 2), recorder.lens[0]);
    try std.testing.expectEqualStrings("xdg-open", recorder.argvs[0][0]);
    try std.testing.expectEqualStrings("/tmp/a.txt", recorder.argvs[0][1]);
    try std.testing.expectEqual(@as(usize, 3), recorder.lens[1]);
    try std.testing.expectEqualStrings("gio", recorder.argvs[1][0]);
    try std.testing.expectEqualStrings("open", recorder.argvs[1][1]);
    try std.testing.expectEqualStrings("/tmp/a.txt", recorder.argvs[1][2]);
}

test "launch: when every launcher fails, open_with_launchers reports false after all four" {
    const Failing = struct {
        calls: usize = 0,

        fn run(raw: ?*anyopaque, _: Command) anyerror!u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return 3;
        }
    };
    var failing = Failing{};
    const launcher = Launcher{ .ctx = &failing, .run = Failing.run };
    try std.testing.expect(!open_with_launchers(launcher, "https://example.com", .{}));
    try std.testing.expectEqual(@as(usize, 4), failing.calls);
}

test "launch: open_with_system runs xdg-open alone, with the display variables" {
    const Recorder = struct {
        calls: usize = 0,
        argv_len: usize = 0,
        program: []const u8 = "",
        wayland: ?[]const u8 = null,

        fn run(raw: ?*anyopaque, command: Command) anyerror!u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.argv_len = command.argv.len;
            self.program = command.argv[0];
            self.wayland = command.environment.wayland_display;
            return 0;
        }
    };
    var recorder = Recorder{};
    const launcher = Launcher{ .ctx = &recorder, .run = Recorder.run };
    open_with_system(launcher, "/tmp/doc.pdf", .{ .wayland_display = "wayland-1" });
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(usize, 2), recorder.argv_len);
    try std.testing.expectEqualStrings("xdg-open", recorder.program);
    try std.testing.expectEqualStrings("wayland-1", recorder.wayland.?);
}

test "launch: restart runs the script with the pid, the app and its arguments, without waiting" {
    const Recorder = struct {
        started: usize = 0,
        waited: usize = 0,
        argv: [8][]const u8 = undefined,
        text: [8][256]u8 = undefined,
        len: usize = 0,

        fn run(_: ?*anyopaque, _: Command) anyerror!u8 {
            return error.NotExpected;
        }

        fn start(raw: ?*anyopaque, command: Command) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.started += 1;
            // The restart script's strings are freed when `restart` returns, so they are copied.
            self.len = command.argv.len;
            for (command.argv, 0..) |arg, i| {
                @memcpy(self.text[i][0..arg.len], arg);
                self.argv[i] = self.text[i][0..arg.len];
            }
        }
    };
    var recorder = Recorder{};
    const launcher = Launcher{ .ctx = &recorder, .run = Recorder.run, .start = Recorder.start };
    const args = [_][]const u8{ "--new-window", "a b" };
    try restart(launcher, std.testing.allocator, 4242, "/opt/zui/app", &args);
    try std.testing.expectEqual(@as(usize, 1), recorder.started);
    try std.testing.expectEqual(@as(usize, 0), recorder.waited);
    try std.testing.expectEqual(@as(usize, 8), recorder.len);
    try std.testing.expectEqualStrings("/usr/bin/env", recorder.argv[0]);
    try std.testing.expectEqualStrings("bash", recorder.argv[1]);
    try std.testing.expectEqualStrings("-c", recorder.argv[2]);
    try std.testing.expectEqualStrings(restart_script, recorder.argv[3]);
    try std.testing.expectEqualStrings("4242", recorder.argv[4]);
    try std.testing.expectEqualStrings("/opt/zui/app", recorder.argv[5]);
    try std.testing.expectEqualStrings("--new-window", recorder.argv[6]);
    try std.testing.expectEqualStrings("a b", recorder.argv[7]);
}

test "launch: a missing program is an error from the default launcher, and nothing is started" {
    // The name cannot exist on PATH, so no program runs.
    const command = Command{ .argv = &.{"zui-no-such-program-for-launch-test"} };
    const launcher = Launcher{};
    try std.testing.expectError(error.FileNotFound, launcher.run(launcher.ctx, command));
}
