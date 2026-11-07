//! System notifications over the freedesktop notification service (`org.freedesktop.Notifications`)
//! on the session bus. GPUI's Linux platform does the same through notify-rust; here the D-Bus
//! client in `dbus.zig` does it directly.
//!
//! - The session bus is connected on the first notification, never earlier.
//! - A notification keeps its tag: posting the same tag again passes the server's id back as
//!   `replaces_id`, so the old notification is replaced. A second post while the first is still
//!   waiting for its reply is kept and sent once the reply has come.
//! - Dismissing a tag closes its notification with `CloseNotification`.
//! - Body clicks come back as the `default` action (a null `action_id`), buttons as their index.
//! - A missing bus, or a server that refuses, is logged once and then ignored. Nothing here can
//!   block the window or stop the event loop.

const std = @import("std");
const dbus = @import("dbus.zig");
const platform = @import("../../platform.zig");

const service = "org.freedesktop.Notifications";
const object_path = "/org/freedesktop/Notifications";
/// The XDG action key sent when the body is clicked (GPUI's `DEFAULT_ACTION`).
const default_action = "default";
/// Buttons are sent as `zui-<index>`, so action ids never reach the bus.
const action_key_prefix = "zui-";
const notify_signature = "susssasa{sv}i";
const match_rule = "type='signal',sender='org.freedesktop.Notifications'," ++
    "interface='org.freedesktop.Notifications',path='/org/freedesktop/Notifications'";

/// Most notifications tracked at once. Each is a server id until it is closed.
const max_records = 64;
/// Buttons beyond this are dropped; desktops show a handful at most.
const max_actions = 8;

/// One `show` call: owned copies of everything sent with a Notify.
const Post = struct {
    title: []const u8,
    body: []const u8,
    /// Action ids, by index. `labels[i]` is the text shown for `ids[i]`.
    ids: []const []const u8,
    labels: []const []const u8,

    fn free(self: Post, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.body);
        free_list(gpa, self.ids);
        free_list(gpa, self.labels);
    }

    fn init(gpa: std.mem.Allocator, n: platform.SystemNotification) !Post {
        const title = try gpa.dupe(u8, n.title);
        errdefer gpa.free(title);
        const body = try gpa.dupe(u8, n.body);
        errdefer gpa.free(body);
        const actions = n.actions[0..@min(n.actions.len, max_actions)];
        const ids = try gpa.alloc([]const u8, actions.len);
        var ids_done: usize = 0;
        errdefer {
            for (ids[0..ids_done]) |s| gpa.free(s);
            gpa.free(ids);
        }
        for (actions, 0..) |action, i| {
            ids[i] = try gpa.dupe(u8, action.id);
            ids_done = i + 1;
        }
        const labels = try gpa.alloc([]const u8, actions.len);
        var labels_done: usize = 0;
        errdefer {
            for (labels[0..labels_done]) |s| gpa.free(s);
            gpa.free(labels);
        }
        for (actions, 0..) |action, i| {
            labels[i] = try gpa.dupe(u8, action.label);
            labels_done = i + 1;
        }
        return .{ .title = title, .body = body, .ids = ids, .labels = labels };
    }
};

/// A notification the server may be showing, or is about to show.
const Record = struct {
    tag: []u8,
    /// The server's id: 0 until the first Notify is answered.
    id: u32 = 0,
    /// Action ids of the notification the server holds, by index.
    actions: []const []const u8 = &.{},
    /// A Notify for this tag is waiting for its reply.
    in_flight: bool = false,
    /// `dismiss` ran while in flight: close the notification when its id arrives.
    dismissed: bool = false,
    /// The newest post that arrived while in flight; it replaces `id` once it is sent.
    next: ?Post = null,

    fn free(self: *Record, gpa: std.mem.Allocator) void {
        gpa.free(self.tag);
        free_list(gpa, self.actions);
        if (self.next) |p| p.free(gpa);
    }
};

/// The context of one Notify: its reply handler needs the tag and the action ids it was sent with.
const NotifyCall = struct {
    state: *State,
    tag: []u8,
    ids: []const []const u8,
};

fn free_list(gpa: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn dupe_list(gpa: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try gpa.alloc([]const u8, items.len);
    var done: usize = 0;
    errdefer free_list(gpa, out[0..done]);
    for (items, 0..) |item, i| {
        out[i] = try gpa.dupe(u8, item);
        done = i + 1;
    }
    return out;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    /// The name sent as `app_name` (GPUI's `set_app_identity` name), owned.
    app_name: ?[]u8 = null,
    /// The bus to connect to. Null means the session bus; tests point it at a fake one.
    bus_address: ?[]const u8 = null,
    bus: ?*dbus.Connection = null,
    /// True once the session bus cannot be found at all. Nothing is retried then.
    no_bus: bool = false,
    /// True while the bus is delivering messages. A connection must not be freed then.
    dispatching: bool = false,
    /// Set after the first failure is logged; later failures are not logged.
    warned: bool = false,
    records: std.ArrayList(Record) = .empty,
    /// Notify calls waiting for a reply, owned here so a dropped bus cannot leak them.
    calls: std.ArrayList(*NotifyCall) = .empty,
    /// Receives each response (GPUI's `on_system_notification_response` callback).
    respond_ctx: *anyopaque,
    respond_fn: *const fn (*anyopaque, platform.SystemNotificationResponse) void,

    pub fn init(
        allocator: std.mem.Allocator,
        respond_ctx: *anyopaque,
        respond_fn: *const fn (*anyopaque, platform.SystemNotificationResponse) void,
    ) State {
        return .{ .allocator = allocator, .respond_ctx = respond_ctx, .respond_fn = respond_fn };
    }

    pub fn deinit(self: *State) void {
        const gpa = self.allocator;
        self.drop_bus();
        for (self.records.items) |*rec| rec.free(gpa);
        self.records.deinit(gpa);
        self.calls.deinit(gpa);
        if (self.app_name) |n| gpa.free(n);
    }

    pub fn set_app_name(self: *State, name: []const u8) void {
        const copy = self.allocator.dupe(u8, name) catch return;
        if (self.app_name) |old| self.allocator.free(old);
        self.app_name = copy;
    }

    /// Posts `notification`. A tag that is already shown replaces that notification.
    pub fn show(self: *State, notification: platform.SystemNotification) void {
        const gpa = self.allocator;
        const bus = self.connect_bus() orelse return;
        const post = Post.init(gpa, notification) catch |err| {
            return self.report("cannot post a notification: {s}", .{@errorName(err)});
        };
        const idx = self.find_or_add(notification.tag) catch |err| {
            post.free(gpa);
            return self.report("cannot post a notification: {s}", .{@errorName(err)});
        };
        const rec = &self.records.items[idx];
        rec.dismissed = false;
        if (rec.in_flight) {
            if (rec.next) |old| old.free(gpa);
            rec.next = post;
            return;
        }
        self.send(bus, idx, post);
    }

    /// Closes the notification posted with `tag`, if it is still shown.
    pub fn dismiss(self: *State, tag: []const u8) void {
        const idx = self.find(tag) orelse return;
        const rec = &self.records.items[idx];
        if (rec.in_flight) {
            rec.dismissed = true;
            if (rec.next) |p| p.free(self.allocator);
            rec.next = null;
            return;
        }
        if (rec.id != 0) {
            if (self.bus) |bus| {
                if (!bus.is_failed()) self.close_id(bus, rec.id);
            }
        }
        self.remove(idx);
    }

    /// The socket to poll for bus traffic, or -1 when there is no bus.
    pub fn bus_socket(self: *const State) c_int {
        return if (self.bus) |bus| bus.socket() else -1;
    }

    /// The poll events the bus needs now.
    pub fn bus_events(self: *const State) i16 {
        return if (self.bus) |bus| bus.poll_events() else 0;
    }

    /// Handles the events `poll` reported for `bus_socket()`.
    pub fn on_bus_poll(self: *State, revents: i16) void {
        const bus = self.bus orelse return;
        self.dispatching = true;
        bus.on_poll(revents);
        self.dispatching = false;
        if (bus.is_failed()) {
            self.report("lost the session bus: {s}", .{@errorName(bus.failure orelse error.Disconnected)});
            self.drop_bus();
        }
    }

    fn report(self: *State, comptime fmt: []const u8, args: anytype) void {
        if (self.warned) return;
        self.warned = true;
        std.log.warn("system notifications: " ++ fmt ++ " (later failures are not logged)", args);
    }

    /// The connected bus, connecting on first use. Null when there is none.
    fn connect_bus(self: *State) ?*dbus.Connection {
        if (self.bus) |bus| {
            if (!bus.is_failed()) return bus;
            // A connection is freed only outside its own dispatch; `on_bus_poll` does that.
            if (self.dispatching) return null;
            self.drop_bus();
        }
        if (self.no_bus) return null;

        const bus = (if (self.bus_address) |address|
            dbus.Connection.connect(self.allocator, address)
        else
            dbus.Connection.connect_session(self.allocator)) catch |err| {
            if (err == error.BadAddress) self.no_bus = true;
            self.report("no session bus ({s})", .{@errorName(err)});
            return null;
        };
        bus.add_listener(dbus.Handler.of(self, on_signal)) catch |err| {
            bus.deinit();
            self.report("cannot listen on the session bus: {s}", .{@errorName(err)});
            return null;
        };
        bus.add_match(match_rule) catch |err| {
            bus.deinit();
            self.report("cannot subscribe on the session bus: {s}", .{@errorName(err)});
            return null;
        };
        self.bus = bus;
        return bus;
    }

    /// Closes the bus and forgets every notification, since their ids mean nothing without it.
    fn drop_bus(self: *State) void {
        const gpa = self.allocator;
        if (self.bus) |bus| bus.deinit();
        self.bus = null;
        for (self.calls.items) |call| {
            gpa.free(call.tag);
            free_list(gpa, call.ids);
            gpa.destroy(call);
        }
        self.calls.clearRetainingCapacity();
        for (self.records.items) |*rec| rec.free(gpa);
        self.records.clearRetainingCapacity();
    }

    fn find(self: *State, tag: []const u8) ?usize {
        for (self.records.items, 0..) |rec, i| {
            if (std.mem.eql(u8, rec.tag, tag)) return i;
        }
        return null;
    }

    fn find_by_id(self: *State, id: u32) ?usize {
        for (self.records.items, 0..) |rec, i| {
            if (rec.id == id and id != 0) return i;
        }
        return null;
    }

    fn find_or_add(self: *State, tag: []const u8) !usize {
        if (self.find(tag)) |i| return i;
        if (self.records.items.len >= max_records) return error.TooManyNotifications;
        const copy = try self.allocator.dupe(u8, tag);
        errdefer self.allocator.free(copy);
        try self.records.append(self.allocator, .{ .tag = copy });
        return self.records.items.len - 1;
    }

    fn remove(self: *State, idx: usize) void {
        var rec = self.records.orderedRemove(idx);
        rec.free(self.allocator);
    }

    /// Sends a Notify for the record at `idx`. Takes ownership of `post`.
    fn send(self: *State, bus: *dbus.Connection, idx: usize, post: Post) void {
        defer post.free(self.allocator);
        const gpa = self.allocator;
        const rec = &self.records.items[idx];

        const call = gpa.create(NotifyCall) catch |err| return self.send_failed(idx, err);
        const tag = gpa.dupe(u8, rec.tag) catch |err| {
            gpa.destroy(call);
            return self.send_failed(idx, err);
        };
        const ids = dupe_list(gpa, post.ids) catch |err| {
            gpa.free(tag);
            gpa.destroy(call);
            return self.send_failed(idx, err);
        };
        call.* = .{ .state = self, .tag = tag, .ids = ids };

        var enc = dbus.Encoder.init(gpa);
        defer enc.deinit();
        encode_notify(&enc, self.app_name orelse "", rec.id, post) catch |err| {
            self.finish_call(call);
            return self.send_failed(idx, err);
        };
        // Listed before the call, so a failed append leaves nothing in flight.
        self.calls.append(gpa, call) catch |err| {
            self.finish_call(call);
            return self.send_failed(idx, err);
        };
        _ = bus.call(.{
            .kind = .method_call,
            .destination = service,
            .path = object_path,
            .interface = service,
            .member = "Notify",
            .signature = notify_signature,
        }, enc.written(), dbus.Handler.of(call, on_notify_reply)) catch |err| {
            self.finish_call(call);
            return self.send_failed(idx, err);
        };
        rec.in_flight = true;
    }

    fn send_failed(self: *State, idx: usize, err: anyerror) void {
        self.report("cannot post a notification: {s}", .{@errorName(err)});
        const rec = &self.records.items[idx];
        if (rec.id == 0) self.remove(idx);
    }

    fn finish_call(self: *State, call: *NotifyCall) void {
        for (self.calls.items, 0..) |c, i| {
            if (c == call) {
                _ = self.calls.swapRemove(i);
                break;
            }
        }
        const gpa = self.allocator;
        gpa.free(call.tag);
        free_list(gpa, call.ids);
        gpa.destroy(call);
    }

    fn close_id(self: *State, bus: *dbus.Connection, id: u32) void {
        var enc = dbus.Encoder.init(self.allocator);
        defer enc.deinit();
        enc.uint32(id) catch return;
        _ = bus.call(.{
            .kind = .method_call,
            .flags = dbus.flag_no_reply_expected,
            .destination = service,
            .path = object_path,
            .interface = service,
            .member = "CloseNotification",
            .signature = "u",
        }, enc.written(), null) catch |err| {
            self.report("cannot close a notification: {s}", .{@errorName(err)});
        };
    }

    /// Runs when the server answers a Notify.
    fn on_notify_reply(call: *NotifyCall, msg: *const dbus.Message) void {
        const self = call.state;
        defer self.finish_call(call);
        const gpa = self.allocator;

        const idx = self.find(call.tag);
        const id: ?u32 = if (msg.header.kind == .method_return and msg.body.len == 1) as_u32(msg.body[0]) else null;
        if (id == null or id.? == 0) {
            const reason = msg.header.error_name orelse "no notification id";
            self.report("the notification server refused a notification: {s}", .{reason});
            if (idx) |i| self.settle(i);
            return;
        }

        const new_id = id.?;
        const i = idx orelse {
            // Nothing wants this notification any more (its record was dropped), so close it.
            if (self.bus) |bus| {
                if (!bus.is_failed()) self.close_id(bus, new_id);
            }
            return;
        };
        const rec = &self.records.items[i];
        rec.in_flight = false;
        if (rec.dismissed) {
            if (self.bus) |bus| {
                if (!bus.is_failed()) self.close_id(bus, new_id);
            }
            self.remove(i);
            return;
        }
        rec.id = new_id;
        free_list(gpa, rec.actions);
        rec.actions = call.ids;
        call.ids = &.{};
        self.settle(i);
    }

    /// The Notify for record `idx` is answered (or failed). Sends the newer post that waited for it,
    /// if there is one. Otherwise a record with no server id is dropped, since nothing shows it.
    fn settle(self: *State, idx: usize) void {
        const gpa = self.allocator;
        const rec = &self.records.items[idx];
        rec.in_flight = false;
        if (rec.next) |next| {
            rec.next = null;
            if (self.bus) |bus| {
                if (!bus.is_failed()) return self.send(bus, idx, next);
            }
            next.free(gpa);
        }
        if (self.records.items[idx].id == 0) self.remove(idx);
    }

    /// Runs for every signal the bus delivers. Only the notification service's signals matter.
    fn on_signal(self: *State, msg: *const dbus.Message) void {
        const interface = msg.header.interface orelse return;
        const path = msg.header.path orelse return;
        const member = msg.header.member orelse return;
        if (!std.mem.eql(u8, interface, service) or !std.mem.eql(u8, path, object_path)) return;

        if (std.mem.eql(u8, member, "NotificationClosed")) {
            if (!std.mem.eql(u8, msg.header.signature, "uu")) return;
            const id = as_u32(msg.body[0]) orelse return;
            if (self.find_by_id(id)) |idx| self.remove(idx);
        } else if (std.mem.eql(u8, member, "ActionInvoked")) {
            if (!std.mem.eql(u8, msg.header.signature, "us")) return;
            const id = as_u32(msg.body[0]) orelse return;
            const key = as_string_value(msg.body[1]) orelse return;
            const idx = self.find_by_id(id) orelse return;
            // Read the record before responding: the handler may change the records.
            const rec = &self.records.items[idx];
            if (std.mem.eql(u8, key, default_action)) return self.respond(rec.tag, null);
            const i = action_index(key, rec.actions.len) orelse return;
            self.respond(self.records.items[idx].tag, self.records.items[idx].actions[i]);
        }
    }

    /// Hands a response to the platform. The strings are copies, valid during the call only.
    fn respond(self: *State, tag: []const u8, action: ?[]const u8) void {
        const gpa = self.allocator;
        const tag_copy = gpa.dupe(u8, tag) catch return;
        defer gpa.free(tag_copy);
        const action_copy: ?[]u8 = if (action) |a| (gpa.dupe(u8, a) catch return) else null;
        defer if (action_copy) |a| gpa.free(a);
        self.respond_fn(self.respond_ctx, .{ .tag = tag_copy, .action_id = action_copy });
    }
};

fn as_u32(v: dbus.Value) ?u32 {
    return switch (v) {
        .uint32 => |n| n,
        else => null,
    };
}

fn as_i32(v: dbus.Value) ?i32 {
    return switch (v) {
        .int32 => |n| n,
        else => null,
    };
}

fn as_string_value(v: dbus.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// The index a `zui-<n>` key stands for, if it is one of the `count` buttons.
fn action_index(key: []const u8, count: usize) ?usize {
    if (!std.mem.startsWith(u8, key, action_key_prefix)) return null;
    const n = std.fmt.parseInt(usize, key[action_key_prefix.len..], 10) catch return null;
    return if (n < count) n else null;
}

fn encode_notify(enc: *dbus.Encoder, app_name: []const u8, replaces: u32, post: Post) dbus.Error!void {
    try enc.string(app_name);
    try enc.uint32(replaces);
    try enc.string(""); // no icon
    try enc.string(post.title);
    try enc.string(post.body);
    // Actions are key/label pairs. The body click comes first, as GPUI sends it.
    try enc.begin_array("s");
    try enc.string(default_action);
    try enc.string(default_action);
    for (post.labels, 0..) |label, i| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ action_key_prefix, i }) catch unreachable;
        try enc.string(key);
        try enc.string(label);
    }
    try enc.end_array();
    try enc.begin_array("{sv}"); // hints: none
    try enc.end_array();
    try enc.int32(-1); // the server's default timeout
}

// ---------------------------------------------------------------------------------------------
// Tests: a fake bus on an abstract socket, in a thread, that plays the server side.

const testing = std.testing;
const linux = std.os.linux;
const ts = @import("dbus_test_server.zig");
const Server = ts.Server;

/// What the fake server saw and whether it matched the script.
const Script = struct {
    /// Refuse the first Notify with an error instead of answering it.
    refuse: bool = false,
    failure: ?[]const u8 = null,
    notifies: usize = 0,
    closes: usize = 0,
};

fn as_string(v: dbus.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.BadArguments,
    };
}

/// Checks a Notify call against what the test expects, argument by argument.
fn expect_notify(msg: dbus.Message, replaces: u32, title: []const u8, body: []const u8, actions: []const []const u8) !void {
    const h = msg.header;
    if (h.kind != .method_call) return error.NotACall;
    if (!std.mem.eql(u8, h.destination orelse "", service)) return error.BadDestination;
    if (!std.mem.eql(u8, h.path orelse "", object_path)) return error.BadPath;
    if (!std.mem.eql(u8, h.interface orelse "", service)) return error.BadInterface;
    if (!std.mem.eql(u8, h.member orelse "", "Notify")) return error.BadMember;
    if (!std.mem.eql(u8, h.signature, notify_signature)) return error.BadSignature;
    if (msg.body.len != 8) return error.BadArguments;
    if (!std.mem.eql(u8, try as_string(msg.body[0]), "zui-test")) return error.BadAppName;
    if ((as_u32(msg.body[1]) orelse return error.BadReplacesId) != replaces) return error.BadReplacesId;
    if (!std.mem.eql(u8, try as_string(msg.body[2]), "")) return error.BadIcon;
    if (!std.mem.eql(u8, try as_string(msg.body[3]), title)) return error.BadSummary;
    if (!std.mem.eql(u8, try as_string(msg.body[4]), body)) return error.BadBody;
    const got = msg.body[5].array.items;
    if (got.len != actions.len) return error.BadActions;
    for (actions, 0..) |want, i| {
        if (!std.mem.eql(u8, try as_string(got[i]), want)) return error.BadActions;
    }
    if (msg.body[6].array.items.len != 0) return error.BadHints;
    if ((as_i32(msg.body[7]) orelse return error.BadTimeout) != -1) return error.BadTimeout;
}

fn serve_session(server: *Server, script: *Script) !void {
    const gpa = server.gpa;
    var line_buf: [256]u8 = undefined;
    const auth = try server.read_line(&line_buf);
    if (!std.mem.startsWith(u8, auth, "\x00AUTH EXTERNAL ")) return error.BadAuth;
    try server.write("OK 0123456789abcdef0123456789abcdef\r\n");
    if (!std.mem.eql(u8, try server.read_line(&line_buf), "BEGIN")) return error.BadBegin;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Hello, then AddMatch, which needs the rule the client subscribes with.
    const hello = try server.next_message(a);
    if (!std.mem.eql(u8, hello.header.member orelse "", "Hello")) return error.BadHello;
    var name_enc = dbus.Encoder.init(gpa);
    defer name_enc.deinit();
    try name_enc.string(":1.5");
    try server.reply(hello, "s", name_enc.written());

    const add_match = try server.next_message(a);
    if (!std.mem.eql(u8, add_match.header.member orelse "", "AddMatch")) return error.BadAddMatch;
    if (!std.mem.eql(u8, try as_string(add_match.body[0]), match_rule)) return error.BadMatchRule;
    try server.reply(add_match, "", "");

    // First post: a new notification with two buttons.
    const first = try server.next_message(a);
    script.notifies += 1;
    if (script.refuse) {
        try expect_notify(first, 0, "T1", "B1", &.{ "default", "default" });
        return server.reply_error(first, "org.freedesktop.DBus.Error.ServiceUnknown");
    }
    try expect_notify(first, 0, "T1", "B1", &.{ "default", "default", "zui-0", "Open", "zui-1", "Snooze" });
    var id_enc = dbus.Encoder.init(gpa);
    defer id_enc.deinit();
    try id_enc.uint32(42);
    try server.reply(first, "u", id_enc.written());
    var invoked = dbus.Encoder.init(gpa);
    defer invoked.deinit();
    try invoked.uint32(42);
    try invoked.string("zui-0");
    try server.signal_at(object_path, service, "ActionInvoked", "us", invoked.written());

    // Second post with the same tag: it must replace id 42, and it has no buttons.
    const second = try server.next_message(a);
    script.notifies += 1;
    try expect_notify(second, 42, "T2", "B2", &.{ "default", "default" });
    try server.reply(second, "u", id_enc.written());
    var clicked = dbus.Encoder.init(gpa);
    defer clicked.deinit();
    try clicked.uint32(42);
    try clicked.string("default");
    try server.signal_at(object_path, service, "ActionInvoked", "us", clicked.written());

    // Dismiss: CloseNotification for 42, sent without a reply.
    const close = try server.next_message(a);
    script.closes += 1;
    if (!std.mem.eql(u8, close.header.member orelse "", "CloseNotification")) return error.BadClose;
    if (close.body.len != 1 or (as_u32(close.body[0]) orelse 0) != 42) return error.BadClose;
    if (close.header.flags & dbus.flag_no_reply_expected == 0) return error.BadClose;
}

fn serve(listener: c_int, script: *Script) void {
    defer _ = linux.close(listener);
    const rc = linux.accept(listener, null, null);
    if (linux.errno(rc) != .SUCCESS) {
        script.failure = "accept";
        return;
    }
    const fd: c_int = @intCast(rc);
    defer _ = linux.close(fd);
    // A client that stops talking must not hang the test.
    const timeout = linux.timeval{ .sec = 3, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));

    var server = Server{ .fd = fd, .gpa = testing.allocator };
    defer server.deinit();
    serve_session(&server, script) catch |err| {
        script.failure = @errorName(err);
    };
}

/// Records the responses the state hands the platform.
const Recorder = struct {
    count: usize = 0,
    tags: [4][16]u8 = undefined,
    actions: [4]?[16]u8 = .{ null, null, null, null },

    fn respond(raw: *anyopaque, response: platform.SystemNotificationResponse) void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        if (self.count == self.tags.len) return;
        @memcpy(self.tags[self.count][0..response.tag.len], response.tag);
        if (response.action_id) |action| {
            var copy = std.mem.zeroes([16]u8);
            @memcpy(copy[0..action.len], action);
            self.actions[self.count] = copy;
        }
        self.count += 1;
    }
};

/// Polls the bus until `done` is true, or fails after a bounded number of rounds.
fn pump(state: *State, done: *const fn (*State) bool) !void {
    var rounds: usize = 0;
    while (!done(state)) : (rounds += 1) {
        if (rounds > 200) return error.TimedOut;
        const fd = state.bus_socket();
        if (fd < 0) return error.NoBus;
        var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = state.bus_events(), .revents = 0 }};
        _ = std.posix.poll(&pfd, 50) catch 0;
        state.on_bus_poll(pfd[0].revents);
    }
}

fn run_script(script: *Script, state: *State, body: *const fn (*State) anyerror!void) !void {
    var name_buf: [64]u8 = undefined;
    const name = ts.unique_name(&name_buf, "zui-notify-test");
    const listener = try ts.listen_abstract(name);
    var addr_buf: [96]u8 = undefined;
    state.bus_address = try ts.abstract_address(&addr_buf, name);
    const thread = try std.Thread.spawn(.{}, serve, .{ listener, script });
    defer thread.join();
    try body(state);
}

test "system notifications: end to end against a fake bus" {
    var recorder = Recorder{};
    var state = State.init(testing.allocator, &recorder, Recorder.respond);
    defer state.deinit();
    state.set_app_name("zui-test");
    var script = Script{};

    const body = struct {
        fn run(s: *State) anyerror!void {
            s.show(.{ .tag = "t", .title = "T1", .body = "B1", .actions = &.{
                .{ .id = "open", .label = "Open" },
                .{ .id = "snooze", .label = "Snooze" },
            } });
            try pump(s, struct {
                fn done(st: *State) bool {
                    return st.records.items.len == 1 and st.records.items[0].id == 42;
                }
            }.done);
            s.show(.{ .tag = "t", .title = "T2", .body = "B2" });
            try pump(s, struct {
                fn done(st: *State) bool {
                    return st.records.items.len == 1 and st.records.items[0].id == 42 and st.records.items[0].actions.len == 0;
                }
            }.done);
            s.dismiss("t");
        }
    }.run;
    try run_script(&script, &state, body);

    if (script.failure) |f| {
        std.debug.print("fake bus: {s}\n", .{f});
        return error.FakeBusFailed;
    }
    try testing.expectEqual(@as(usize, 2), script.notifies);
    try testing.expectEqual(@as(usize, 1), script.closes);
    try testing.expectEqual(@as(usize, 2), recorder.count);
    try testing.expectEqualStrings("t", recorder.tags[0][0..1]);
    try testing.expectEqualStrings("open", recorder.actions[0].?[0..4]);
    try testing.expectEqualStrings("t", recorder.tags[1][0..1]);
    try testing.expect(recorder.actions[1] == null);
    try testing.expectEqual(@as(usize, 0), state.records.items.len);
}

test "system notifications: a refusing server is ignored" {
    var recorder = Recorder{};
    var state = State.init(testing.allocator, &recorder, Recorder.respond);
    defer state.deinit();
    state.set_app_name("zui-test");
    var script = Script{ .refuse = true };

    const body = struct {
        fn run(s: *State) anyerror!void {
            s.show(.{ .tag = "t", .title = "T1", .body = "B1" });
            try pump(s, struct {
                fn done(st: *State) bool {
                    return st.records.items.len == 0;
                }
            }.done);
        }
    }.run;
    try run_script(&script, &state, body);

    if (script.failure) |f| {
        std.debug.print("fake bus: {s}\n", .{f});
        return error.FakeBusFailed;
    }
    try testing.expectEqual(@as(usize, 1), script.notifies);
    try testing.expectEqual(@as(usize, 0), recorder.count);
}

test "system notifications: a missing bus does nothing and does not crash" {
    var recorder = Recorder{};
    var state = State.init(testing.allocator, &recorder, Recorder.respond);
    defer state.deinit();
    state.bus_address = "unix:path=/nonexistent/zui-test-no-bus";
    state.show(.{ .tag = "t", .title = "T1", .body = "B1" });
    state.show(.{ .tag = "t", .title = "T2", .body = "B2" });
    state.dismiss("t");
    try testing.expect(state.bus == null);
    try testing.expectEqual(@as(c_int, -1), state.bus_socket());
    try testing.expectEqual(@as(usize, 0), state.records.items.len);
    try testing.expectEqual(@as(usize, 0), recorder.count);
    state.on_bus_poll(0);
}

test "system notifications: an address with no unix transport is permanent" {
    var recorder = Recorder{};
    var state = State.init(testing.allocator, &recorder, Recorder.respond);
    defer state.deinit();
    state.bus_address = "tcp:host=example.invalid,port=1";
    state.show(.{ .tag = "t", .title = "T1", .body = "B1" });
    try testing.expect(state.no_bus);
    try testing.expect(state.bus == null);
}

test "system notifications: action keys" {
    try testing.expectEqual(@as(?usize, null), action_index("default", 2));
    try testing.expectEqual(@as(?usize, 1), action_index("zui-1", 2));
    try testing.expectEqual(@as(?usize, null), action_index("zui-2", 2));
    try testing.expectEqual(@as(?usize, null), action_index("zui-x", 2));
    try testing.expectEqual(@as(?usize, null), action_index("open", 2));
}
