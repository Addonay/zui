//! Port of GPUI's `examples/toggle_headless.rs`.
//!
//! Differences from the Rust version:
//! - Commands come from stdin on a reader thread that queues lines behind a mutex. The app takes
//!   one line per tick, every 25 ms on the foreground executor, as the Rust `cx.spawn` loop does
//!   with its timer.
//! - Rust awaits `request_windowing` and then opens the window. ZUI has no async, so the switch is
//!   a `Task` that the tick polls: a command waits until the switch it started has finished.
//! - Zig has no closures, so the window builder reads the todos from a module variable that is
//!   set before the first window opens.
//! - Output goes through `std.debug.print`, as in the other examples.
//! - Linux uses `linux_platform` with every mode, as GPUI's `gpui_platform::linux` does; other
//!   systems use `Application.new()`.

const std = @import("std");
const builtin = @import("builtin");
const gpui = @import("zui");
const App = gpui.App;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const Subscription = gpui.Subscription;
const Window = gpui.Window;
const WindowId = gpui.WindowId;
const WindowOptions = gpui.WindowOptions;
const WindowingRequest = gpui.WindowingRequest;
const WindowingModes = gpui.WindowingModes;
const GraphicalEnvironment = gpui.GraphicalEnvironment;
const div = gpui.div;
const rgb = gpui.rgb;

const usage: []const u8 = if (builtin.os.tag == .linux)
    "commands: ls | create [message] | open [DISPLAY=… WAYLAND_DISPLAY=… XDG_RUNTIME_DIR=… XDG_ACTIVATION_TOKEN=…] | close | quit"
else
    "commands: ls | create [message] | open | close | quit";

const Todo = struct {
    message: []const u8,
};

const Todos = struct {
    items: std.ArrayList(Entity(Todo)) = .empty,
    window: ?WindowId = null,

    fn push(self: *Todos, todo: Entity(Todo), _: *Context(Todos)) void {
        self.items.append(g_allocator, todo) catch @panic("OOM");
    }

    fn set_window(self: *Todos, id: WindowId, _: *Context(Todos)) void {
        self.window = id;
    }

    fn take_window(self: *Todos, _: *Context(Todos)) ?WindowId {
        const id = self.window;
        self.window = null;
        return id;
    }
};

const TodoWindow = struct {
    todos: Entity(Todos),
    _todos_subscription: Subscription,

    /// Built by `cx.new(TodoWindow.init)`: observing the todos needs the window's own context.
    fn init(cx: *Context(TodoWindow)) TodoWindow {
        const todos = g_todos.?;
        return .{
            .todos = todos,
            ._todos_subscription = cx.observe(todos, on_todos_changed),
        };
    }

    fn on_todos_changed(self: *TodoWindow, _: Entity(Todos), cx: *Context(TodoWindow)) void {
        _ = self;
        cx.notify();
    }

    pub fn render(self: *TodoWindow, _: *Window, cx: *Context(TodoWindow)) *Div {
        const app = cx.app;
        const items = self.todos.read(app).items.items;
        var root = div()
            .size_full()
            .bg(rgb(0xffffff))
            .text_color(rgb(0x202020))
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .child("Switchable display todos")
            .child("Use the terminal: create [message], ls, close, open, quit");
        if (items.len == 0) root = root.child("No todos yet. Type `create` in the terminal.");
        for (items, 0..) |todo, index| {
            root = root.child(describe_todo(index, todo, app));
        }
        return root;
    }
};

/// English, Chinese, Japanese and Korean for a word, then an emoji for it.
const sample_todos = [_][]const u8{
    "milk / 牛奶 / 牛乳 / 우유 🥛",
    "apple / 苹果 / りんご / 사과 🍎",
    "cat / 猫 / ねこ / 고양이 🐱",
    "book / 书 / 本 / 책 📚",
    "rain / 雨 / あめ / 비 🌧️",
};

fn describe_todo(index: usize, todo: Entity(Todo), app: *App) []const u8 {
    const todo_reference = todo.read(app);
    return gpui.format("{d} - {s} - entity {x}", .{ index, todo_reference.message, todo.entity_id().as_u64() });
}

fn print_todos(todos: Entity(Todos), app: *App) void {
    const items = todos.read(app).items.items;
    if (items.len == 0) std.debug.print("no todos\n", .{});
    for (items, 0..) |todo, index| {
        std.debug.print("{s}\n", .{describe_todo(index, todo, app)});
    }
}

fn build_todo_window(_: *Window, app: *App) Entity(TodoWindow) {
    return app.new(TodoWindow.init);
}

/// The todos the window builder reads (Zig has no closures to capture them).
var g_todos: ?Entity(Todos) = null;
/// The subscription that clears the window handle when it closes. Kept for the process.
var g_window_closed: ?Subscription = null;

fn open_window(todos: Entity(Todos), app: *App) !void {
    if (todos.read(app).window != null) return;

    const options: WindowOptions = .{
        .titlebar = .{ .title = "Switchable display todos" },
    };
    g_todos = todos;
    const handle = try app.open_window(options, build_todo_window);
    // On macOS, making the window key does not activate the app over the terminal.
    app.activate(true);
    if (handle.window(app)) |window| window.activate_window();
    todos.update(app, Todos.set_window, .{handle.window_id});
}

/// Builds the environment for `open`: the given `NAME=value` pairs, or this process's environment
/// when none are given. Its strings borrow `arguments`, which the app copies when it switches.
fn display_environment(arguments: []const u8) !GraphicalEnvironment {
    if (std.mem.trim(u8, arguments, " \t").len == 0) return gpui.platform.detect_graphical_environment();
    var environment: GraphicalEnvironment = .{};
    var parts = std.mem.tokenizeAny(u8, arguments, " \t");
    while (parts.next()) |assignment| {
        const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse {
            std.debug.print("expected NAME=value, got \"{s}\"\n", .{assignment});
            return error.BadAssignment;
        };
        const name = assignment[0..eq];
        const value = assignment[eq + 1 ..];
        if (std.mem.eql(u8, name, "WAYLAND_DISPLAY")) {
            environment.wayland_display = value;
        } else if (std.mem.eql(u8, name, "DISPLAY")) {
            environment.x11_display = value;
        } else if (std.mem.eql(u8, name, "XDG_RUNTIME_DIR")) {
            environment.xdg_runtime_dir = value;
        } else if (std.mem.eql(u8, name, "XDG_ACTIVATION_TOKEN")) {
            environment.activation_token = value;
        } else {
            std.debug.print("unknown display variable {s}\n", .{name});
            return error.UnknownVariable;
        }
    }
    return environment;
}

/// Runs one command. Returns the windowing switch it asks for, if any.
fn handle_command(command: []const u8, todos: Entity(Todos), app: *App) !?WindowingRequest {
    const split = std.mem.indexOfScalar(u8, command, ' ');
    const name = if (split) |i| command[0..i] else command;
    const arguments = if (split) |i| command[i + 1 ..] else "";
    if (std.mem.eql(u8, name, "ls")) {
        print_todos(todos, app);
    } else if (std.mem.eql(u8, name, "create")) {
        // A sample with CJK text and an emoji, so that drawing todos exercises color glyph
        // rasterization, which uses the GPU devices a switch to windowed mode creates.
        const count = todos.read(app).items.items.len;
        const sample = sample_todos[count % sample_todos.len];
        const message = if (std.mem.trim(u8, arguments, " \t").len == 0)
            sample
        else
            gpui.format("{s} · {s}", .{ arguments, sample });
        const todo = app.new(Todo{ .message = message });
        todos.update(app, Todos.push, .{todo});
        std.debug.print("todo added, total {d}\n", .{todos.read(app).items.items.len});
    } else if (std.mem.eql(u8, name, "open")) {
        return WindowingRequest{ .windowed = try display_environment(arguments) };
    } else if (std.mem.eql(u8, name, "close")) {
        const window_id = todos.update(app, Todos.take_window, .{});
        if (window_id) |id| {
            if (app.window_by_id(id)) |window| window.remove_window();
        }
        return .headless;
    } else if (std.mem.eql(u8, name, "quit")) {
        app.quit();
    } else if (name.len != 0) {
        std.debug.print("{s}\n", .{usage});
    }
    return null;
}

/// The switch a command started, which `tick` polls until it finishes (ZUI has no `await`).
const Transition = struct {
    task: gpui.Task(anyerror!void),
    /// Opens the window once a switch to windowed mode succeeds.
    open_after: bool,
};

var g_transition: ?Transition = null;
var g_app: ?*App = null;

fn print_mode(app: *App) void {
    const mode: []const u8 = if (app.graphical_environment() == null)
        "headless"
    else if (app.compositor_name().len == 0)
        "windowed"
    else
        app.compositor_name();
    std.debug.print("mode: {s}\n", .{mode});
}

/// Starts the command's work: a switch, or the window it needs. Returns whether it started a switch.
fn run_command(command: []const u8, todos: Entity(Todos), app: *App) void {
    const maybe_request = handle_command(command, todos, app) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return;
    };
    const request = maybe_request orelse return;
    switch (request) {
        .headless => {
            if (app.graphical_environment() != null) {
                g_transition = .{ .task = app.request_windowing(request), .open_after = false };
                return;
            }
        },
        .windowed => {
            // Switching fails while windowed, so `open` then just opens the window.
            if (app.graphical_environment() == null) {
                g_transition = .{ .task = app.request_windowing(request), .open_after = true };
                return;
            }
            open_window(todos, app) catch |err| std.debug.print("error: {s}\n", .{@errorName(err)});
        },
    }
    print_mode(app);
}

/// Takes the next command when no switch is in progress, and finishes the switch in progress first.
fn process(todos: Entity(Todos), app: *App) void {
    if (g_transition) |*transition| {
        const result = transition.task.get() orelse return;
        const open_after = transition.open_after;
        g_transition = null;
        if (result) |_| {
            if (open_after) open_window(todos, app) catch |err| std.debug.print("error: {s}\n", .{@errorName(err)});
        } else |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        print_mode(app);
        return;
    }
    if (pending_lines.items.len == 0) return;
    const line = pending_lines.orderedRemove(0);
    defer g_allocator.free(line);
    run_command(line, todos, app);
}

var g_allocator: std.mem.Allocator = std.heap.smp_allocator;
var pending_lines: std.ArrayList([]u8) = .empty;
var queue_lines: std.ArrayList([]u8) = .empty;
var queue_mutex: std.Io.Mutex = .init;

fn queue_line(line: []u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);
    queue_lines.append(g_allocator, line) catch @panic("OOM");
}

/// Reads stdin on its own thread and queues each line (GPUI's `io::stdin().lines()` thread). A read
/// error ends the thread, and the app keeps running.
fn read_stdin() void {
    var line: std.ArrayList(u8) = .empty;
    var buffer: [256]u8 = undefined;
    while (true) {
        const count = std.posix.read(std.posix.STDIN_FILENO, &buffer) catch |err| {
            std.debug.print("stdin error: {s}\n", .{@errorName(err)});
            break;
        };
        if (count == 0) break;
        for (buffer[0..count]) |byte| {
            if (byte == '\n') {
                queue_line(line.toOwnedSlice(g_allocator) catch @panic("OOM"));
            } else {
                line.append(g_allocator, byte) catch @panic("OOM");
            }
        }
    }
    line.deinit(g_allocator);
}

/// Moves queued lines to `pending_lines`, then handles one command or finishes a switch.
fn tick(app: *App) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    queue_mutex.lockUncancelable(io);
    for (queue_lines.items) |line| pending_lines.append(g_allocator, line) catch @panic("OOM");
    queue_lines.clearRetainingCapacity();
    queue_mutex.unlock(io);

    if (g_todos) |todos| process(todos, app);
    app.background_executor().after(app.foreground_executor(), 25 * std.time.ns_per_ms, tick, app);
}

fn on_window_closed(app: *App, id: WindowId) void {
    const todos = g_todos orelse return;
    const current = todos.read(app).window orelse return;
    if (current == id) _ = todos.update(app, Todos.take_window, .{});
}

fn run_example(app: *App) void {
    const todos = app.new(Todos{});
    g_todos = todos;
    g_app = app;
    g_window_closed = app.on_window_closed(on_window_closed);

    const reader = std.Thread.spawn(.{}, read_stdin, .{}) catch @panic("failed to start the stdin reader");
    reader.detach();

    std.debug.print("{s}\n", .{usage});
    tick(app);
}

pub fn main() void {
    const application = if (builtin.os.tag == .linux) blk: {
        const platform = gpui.linux_platform(g_allocator, WindowingModes.all()) catch |err|
            std.debug.panic("failed to create the Linux platform: {s}", .{@errorName(err)});
        break :blk gpui.Application.with_platform(g_allocator, platform);
    } else gpui.Application.new();
    application
        .with_windowing(.headless)
        .with_quit_mode(.explicit)
        .run(run_example);
}
