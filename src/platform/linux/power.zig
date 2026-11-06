//! The power mode from power-profiles-daemon on the system bus (GPUI `gpui_linux/linux/power.rs`).
//!
//! - The bus is connected once, by `start`, which the platform calls as it runs. A missing bus or
//!   daemon leaves the mode `unknown`, which is what GPUI reports; nothing retries and nothing blocks.
//! - The active profile is read from each service in turn order (UPower's name first, then the older
//!   net.hadess one). The first service that answers decides the mode.
//! - `PropertiesChanged` on the profile object and `NameOwnerChanged` for either name ask for the
//!   profile again. A request that arrives while one is in flight is run once the replies are in.
//! - The listener runs only when the mode differs from the one last reported.

const std = @import("std");
const dbus = @import("dbus.zig");
const platform = @import("../../platform.zig");

const PowerMode = platform.PowerMode;

const Service = struct {
    name: []const u8,
    path: []const u8,
};

/// The UPower namespace replaced net.hadess in power-profiles-daemon 0.20; older daemons only
/// answer under the second name.
const services = [_]Service{
    .{ .name = "org.freedesktop.UPower.PowerProfiles", .path = "/org/freedesktop/UPower/PowerProfiles" },
    .{ .name = "net.hadess.PowerProfiles", .path = "/net/hadess/PowerProfiles" },
};
const properties_interface = "org.freedesktop.DBus.Properties";

/// Maps a profile name from power-profiles-daemon. Unknown names are `unknown`, not a guess.
pub fn power_mode_from_profile(profile: []const u8) PowerMode {
    if (std.mem.eql(u8, profile, "power-saver")) return .low_power;
    if (std.mem.eql(u8, profile, "balanced")) return .balanced;
    if (std.mem.eql(u8, profile, "performance")) return .high_power;
    return .unknown;
}

/// Answers for one service, given to the reply handler of its Get call.
const Reply = struct {
    state: *State,
    index: usize,

    fn on_reply(self: *Reply, msg: *const dbus.Message) void {
        self.state.on_reply(self.index, msg);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    /// The bus to connect to. Null means the system bus; tests point it at a fake one.
    bus_address: ?[]const u8 = null,
    bus: ?*dbus.Connection = null,
    started: bool = false,
    /// Set after the first failure is logged; later failures are not logged.
    warned: bool = false,
    mode: PowerMode = .unknown,
    listener: ?Listener = null,
    replies: [services.len]Reply = undefined,
    /// The answer of each service to the latest query, null where it failed.
    answers: [services.len]?PowerMode = @splat(null),
    /// Replies still due for the latest query.
    outstanding: usize = 0,
    /// A profile change arrived while a query was in flight, so another query follows it.
    requery: bool = false,

    pub const Listener = platform.PowerListener;

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.drop_bus();
    }

    /// Registers the listener; a later call replaces the earlier one.
    pub fn on_change(self: *State, listener: Listener) void {
        self.listener = listener;
    }

    pub fn current(self: *const State) PowerMode {
        return self.mode;
    }

    /// Connects, subscribes and asks for the profile. Runs once; later calls do nothing.
    pub fn start(self: *State) void {
        if (self.started) return;
        self.started = true;
        const bus = self.connect_bus() orelse return;
        self.bus = bus;
        bus.add_listener(dbus.Handler.of(self, on_signal)) catch |err| return self.fail_start(err);
        for (services, 0..) |service, i| {
            self.replies[i] = .{ .state = self, .index = i };
            var props_buf: [256]u8 = undefined;
            const props_rule = std.fmt.bufPrint(
                &props_buf,
                "type='signal',sender='{s}',interface='{s}',member='PropertiesChanged',path='{s}'",
                .{ service.name, properties_interface, service.path },
            ) catch unreachable;
            bus.add_match(props_rule) catch |err| return self.fail_start(err);
            var owner_buf: [256]u8 = undefined;
            const owner_rule = std.fmt.bufPrint(
                &owner_buf,
                "type='signal',sender='{s}',interface='{s}',member='NameOwnerChanged',arg0='{s}'",
                .{ dbus.bus_name, dbus.bus_interface, service.name },
            ) catch unreachable;
            bus.add_match(owner_rule) catch |err| return self.fail_start(err);
        }
        self.refresh();
    }

    pub fn bus_socket(self: *const State) c_int {
        return if (self.bus) |bus| bus.socket() else -1;
    }

    pub fn bus_events(self: *const State) i16 {
        return if (self.bus) |bus| bus.poll_events() else 0;
    }

    /// Handles the events `poll` reported for `bus_socket()`. A lost bus leaves the mode unknown.
    pub fn on_bus_poll(self: *State, revents: i16) void {
        const bus = self.bus orelse return;
        bus.on_poll(revents);
        if (bus.is_failed()) {
            self.report("lost the system bus: {s}", .{@errorName(bus.failure orelse error.Disconnected)});
            self.drop_bus();
            self.set_mode(.unknown);
        }
    }

    fn connect_bus(self: *State) ?*dbus.Connection {
        const connected = if (self.bus_address) |address|
            dbus.Connection.connect(self.allocator, address)
        else
            dbus.Connection.connect_system(self.allocator);
        return connected catch |err| {
            self.report("no system bus ({s})", .{@errorName(err)});
            return null;
        };
    }

    fn fail_start(self: *State, err: anyerror) void {
        self.report("cannot watch power profiles: {s}", .{@errorName(err)});
        self.drop_bus();
    }

    fn drop_bus(self: *State) void {
        if (self.bus) |bus| bus.deinit();
        self.bus = null;
        self.outstanding = 0;
        self.requery = false;
    }

    fn report(self: *State, comptime fmt: []const u8, args: anytype) void {
        if (self.warned) return;
        self.warned = true;
        std.log.warn("power profiles: " ++ fmt ++ " (later failures are not logged)", args);
    }

    /// Asks every service for its active profile. Replies come back through `on_reply`.
    fn refresh(self: *State) void {
        const bus = self.bus orelse return;
        self.answers = @splat(null);
        self.outstanding = services.len;
        for (services, 0..) |service, i| {
            const sent = self.get_profile(bus, service, &self.replies[i]);
            if (!sent) {
                self.outstanding -= 1;
            }
        }
        if (self.outstanding == 0) self.settle();
    }

    fn get_profile(self: *State, bus: *dbus.Connection, service: Service, reply: *Reply) bool {
        var enc = dbus.Encoder.init(self.allocator);
        defer enc.deinit();
        enc.string(service.name) catch return false;
        enc.string("ActiveProfile") catch return false;
        _ = bus.call(.{
            .kind = .method_call,
            .destination = service.name,
            .path = service.path,
            .interface = properties_interface,
            .member = "Get",
            .signature = "ss",
        }, enc.written(), dbus.Handler.of(reply, Reply.on_reply)) catch return false;
        return true;
    }

    fn on_reply(self: *State, index: usize, msg: *const dbus.Message) void {
        self.answers[index] = profile_mode(msg);
        self.outstanding -= 1;
        if (self.outstanding == 0) self.settle();
    }

    /// Runs once every reply of a query is in: a queued request starts again, otherwise the first
    /// answer decides the mode, as GPUI's loop does.
    fn settle(self: *State) void {
        if (self.requery) {
            self.requery = false;
            return self.refresh();
        }
        var mode: PowerMode = .unknown;
        for (self.answers) |answer| {
            if (answer) |found| {
                mode = found;
                break;
            }
        }
        self.set_mode(mode);
    }

    fn on_signal(self: *State, msg: *const dbus.Message) void {
        if (msg.header.kind != .signal) return;
        const member = msg.header.member orelse return;
        const relevant = if (std.mem.eql(u8, member, "PropertiesChanged"))
            is_profile_change(msg)
        else if (std.mem.eql(u8, member, "NameOwnerChanged"))
            is_owner_change(msg)
        else
            false;
        if (!relevant) return;
        if (self.outstanding > 0) {
            self.requery = true;
        } else {
            self.refresh();
        }
    }

    fn set_mode(self: *State, mode: PowerMode) void {
        if (mode == self.mode) return;
        self.mode = mode;
        if (self.listener) |listener| listener.func(listener.ctx);
    }
};

/// The mode a Get reply carries. Anything else (an error, a body of another shape) is null.
fn profile_mode(msg: *const dbus.Message) ?PowerMode {
    if (msg.header.kind != .method_return or msg.body.len != 1) return null;
    const profile = switch (msg.body[0]) {
        .variant => |v| switch (v.value.*) {
            .string => |s| s,
            else => return null,
        },
        else => return null,
    };
    return power_mode_from_profile(profile);
}

/// PropertiesChanged(interface, changed, invalidated) from one of our services, on its object path.
fn is_profile_change(msg: *const dbus.Message) bool {
    const path = msg.header.path orelse return false;
    const interface = first_string(msg) orelse return false;
    for (services) |service| {
        if (std.mem.eql(u8, path, service.path) and std.mem.eql(u8, interface, service.name)) return true;
    }
    return false;
}

/// NameOwnerChanged(name, old_owner, new_owner) for one of our services.
fn is_owner_change(msg: *const dbus.Message) bool {
    const name = first_string(msg) orelse return false;
    for (services) |service| {
        if (std.mem.eql(u8, name, service.name)) return true;
    }
    return false;
}

fn first_string(msg: *const dbus.Message) ?[]const u8 {
    if (msg.body.len == 0) return null;
    return switch (msg.body[0]) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------------------------
// Tests against a fake system bus (see dbus_test_server.zig).

const testing = std.testing;
const linux = std.os.linux;
const ts = @import("dbus_test_server.zig");
const Server = ts.Server;

/// What the fake daemon was asked and what it answers.
const Daemon = struct {
    /// The profile the UPower name answers with. Null makes it refuse, as a missing service does.
    upower_profile: ?[]const u8 = "balanced",
    /// Whether the older name answers.
    hadess_profile: ?[]const u8 = null,
    gets: usize = 0,
    matches: usize = 0,
    failure: ?[]const u8 = null,
};

fn serve_system(listener: c_int, daemon: *Daemon, signal_profile: ?[]const u8) void {
    const rc = linux.accept(listener, null, null);
    if (linux.errno(rc) != .SUCCESS) {
        daemon.failure = "accept";
        return;
    }
    const fd: c_int = @intCast(rc);
    defer _ = linux.close(fd);
    const timeout = linux.timeval{ .sec = 3, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));

    var server = Server{ .fd = fd, .gpa = testing.allocator };
    defer server.deinit();
    serve_bus(&server, daemon, signal_profile) catch |err| {
        daemon.failure = @errorName(err);
    };
}

fn serve_bus(server: *Server, daemon: *Daemon, signal_profile: ?[]const u8) !void {
    const gpa = server.gpa;
    var line_buf: [256]u8 = undefined;
    const auth = try server.read_line(&line_buf);
    if (!std.mem.startsWith(u8, auth, "\x00AUTH EXTERNAL ")) return error.BadAuth;
    try server.write("OK 0123456789abcdef0123456789abcdef\r\n");
    if (!std.mem.eql(u8, try server.read_line(&line_buf), "BEGIN")) return error.BadBegin;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const hello = try server.next_message(a);
    if (!std.mem.eql(u8, hello.header.member orelse "", "Hello")) return error.BadHello;
    var name_enc = dbus.Encoder.init(gpa);
    defer name_enc.deinit();
    try name_enc.string(":1.7");
    try server.reply(hello, "s", name_enc.written());

    // Four match rules: a PropertiesChanged and a NameOwnerChanged rule for each service.
    for (0..4) |_| {
        const add = try server.next_message(a);
        if (!std.mem.eql(u8, add.header.member orelse "", "AddMatch")) return error.BadAddMatch;
        daemon.matches += 1;
        try server.reply(add, "", "");
    }

    try answer_gets(server, daemon, a);
    // A profile change from the daemon makes the client ask both names again.
    if (signal_profile) |profile| {
        try server.signal_at(services[0].path, properties_interface, "PropertiesChanged", "sa{sv}as", try properties_body(a, services[0].name));
        daemon.upower_profile = profile;
        try answer_gets(server, daemon, a);
    }
    // Stay until the client closes, so that it reads every reply before the connection ends.
    server.fill() catch {};
}

/// Answers the two Get calls of one query, each by its destination.
fn answer_gets(server: *Server, daemon: *Daemon, arena: std.mem.Allocator) !void {
    var pending: usize = services.len;
    while (pending > 0) : (pending -= 1) {
        const get = try server.next_message(arena);
        if (!std.mem.eql(u8, get.header.member orelse "", "Get")) return error.BadGet;
        daemon.gets += 1;
        const destination = get.header.destination orelse return error.BadDestination;
        const profile = if (std.mem.eql(u8, destination, services[0].name))
            daemon.upower_profile
        else if (std.mem.eql(u8, destination, services[1].name))
            daemon.hadess_profile
        else
            return error.BadDestination;
        try reply_profile(server, get, profile);
    }
}

fn properties_body(gpa: std.mem.Allocator, interface: []const u8) ![]const u8 {
    var enc = dbus.Encoder.init(gpa);
    errdefer enc.deinit();
    try enc.string(interface);
    try enc.value(.{ .array = .{ .element = "{sv}", .items = &.{} } });
    try enc.value(.{ .array = .{ .element = "s", .items = &.{} } });
    return enc.written();
}

fn reply_profile(server: *Server, call: dbus.Message, profile: ?[]const u8) !void {
    const gpa = server.gpa;
    const text = profile orelse return server.reply_error(call, "org.freedesktop.DBus.Error.ServiceUnknown");
    var enc = dbus.Encoder.init(gpa);
    defer enc.deinit();
    const inner = dbus.Value{ .string = text };
    try enc.value(.{ .variant = .{ .signature = "s", .value = &inner } });
    try server.reply(call, "v", enc.written());
}

/// Counts what the listener is told.
const Counter = struct {
    changes: usize = 0,
    fn changed(raw: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(raw));
        self.changes += 1;
    }
};

/// Starts `state` against a fake daemon and pumps the bus until `counter` has seen `wanted` changes
/// and the last query has settled. The client closes first, so the daemon thread can finish.
fn run_daemon(state: *State, daemon: *Daemon, signal_profile: ?[]const u8, counter: *const Counter, wanted: usize) !void {
    var name_buf: [64]u8 = undefined;
    const name = ts.unique_name(&name_buf, "zui-power-test");
    const listener = try ts.listen_abstract(name);
    defer _ = linux.close(listener);
    var addr_buf: [96]u8 = undefined;
    state.bus_address = try ts.abstract_address(&addr_buf, name);
    const thread = try std.Thread.spawn(.{}, serve_system, .{ listener, daemon, signal_profile });
    state.start();
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) {
        const fd = state.bus_socket();
        if (fd < 0) break;
        var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = state.bus_events(), .revents = 0 }};
        _ = std.posix.poll(&pfd, 50) catch 0;
        state.on_bus_poll(pfd[0].revents);
        if (counter.changes >= wanted and state.outstanding == 0 and !state.requery) break;
    }
    state.drop_bus();
    thread.join();
}

test "power mode: profile names map as GPUI maps them" {
    try testing.expectEqual(PowerMode.low_power, power_mode_from_profile("power-saver"));
    try testing.expectEqual(PowerMode.balanced, power_mode_from_profile("balanced"));
    try testing.expectEqual(PowerMode.high_power, power_mode_from_profile("performance"));
    try testing.expectEqual(PowerMode.unknown, power_mode_from_profile("turbo"));
    try testing.expectEqual(PowerMode.unknown, power_mode_from_profile(""));
}

test "power mode: an unreachable bus leaves the mode unknown and does not crash" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.bus_address = "unix:path=/nonexistent/zui-power-test/bus";
    state.start();
    try testing.expectEqual(PowerMode.unknown, state.current());
    try testing.expectEqual(@as(c_int, -1), state.bus_socket());
    state.start();
}

test "power mode: a non-unix address is ignored" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.bus_address = "tcp:host=127.0.0.1,port=1";
    state.start();
    try testing.expectEqual(PowerMode.unknown, state.current());
}

test "power mode: reads the profile, then follows a change from the daemon" {
    var counter = Counter{};
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.on_change(.{ .ctx = &counter, .func = Counter.changed });
    var daemon = Daemon{ .upower_profile = "balanced", .hadess_profile = null };
    // The daemon answers with a second profile after its signal.
    try run_daemon(&state, &daemon, "power-saver", &counter, 2);
    if (daemon.failure) |f| {
        std.debug.print("fake system bus: {s}\n", .{f});
        return error.FakeBusFailed;
    }
    try testing.expectEqual(@as(usize, 4), daemon.matches);
    try testing.expectEqual(PowerMode.low_power, state.current());
    try testing.expectEqual(@as(usize, 2), counter.changes);
    try testing.expectEqual(@as(usize, 4), daemon.gets);
}

test "power mode: the older daemon name answers when the UPower name does not" {
    var counter = Counter{};
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.on_change(.{ .ctx = &counter, .func = Counter.changed });
    var daemon = Daemon{ .upower_profile = null, .hadess_profile = "performance" };
    try run_daemon(&state, &daemon, null, &counter, 1);
    if (daemon.failure) |f| {
        std.debug.print("fake system bus: {s}\n", .{f});
        return error.FakeBusFailed;
    }
    try testing.expectEqual(PowerMode.high_power, state.current());
    try testing.expectEqual(@as(usize, 1), counter.changes);
}

test "power mode: when no service answers the mode is unknown" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var counter = Counter{};
    state.on_change(.{ .ctx = &counter, .func = Counter.changed });
    var daemon = Daemon{ .upower_profile = null, .hadess_profile = null };
    try run_daemon(&state, &daemon, null, &counter, 0);
    try testing.expectEqual(@as(usize, 0), counter.changes);
    if (daemon.failure) |f| {
        std.debug.print("fake system bus: {s}\n", .{f});
        return error.FakeBusFailed;
    }
    try testing.expectEqual(PowerMode.unknown, state.current());
}
