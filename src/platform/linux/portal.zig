//! The desktop portals (`org.freedesktop.portal.Desktop`) on the session bus: the settings that
//! GPUI's `xdg_desktop_portal.rs` reads (color scheme, cursor theme and size), the file chooser
//! (`prompt_for_paths`, `prompt_for_new_path`) and OpenURI (`open_uri`). GPUI uses the `ashpd` crate
//! for these; here `dbus.zig` does the calls directly.
//!
//! Like `system_notifications.zig`, the connection is polled by the event loop and never blocks on a
//! reply. Each portal request is answered once with an `Outcome`, from the loop: the request's
//! `Response` signal, or an error when the portal is missing, refuses, or the bus is lost. Nothing
//! waits on a dead service.
//!
//! A request's answer can come before its method reply has been read. Such a response waits in
//! `early` until the reply names its request object.

const std = @import("std");
const dbus = @import("dbus.zig");
const platform = @import("../../platform.zig");

const service = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const request_prefix = "/org/freedesktop/portal/desktop/request/";
const file_chooser = "org.freedesktop.portal.FileChooser";
const open_uri_interface = "org.freedesktop.portal.OpenURI";
const settings_interface = "org.freedesktop.portal.Settings";
const request_interface = "org.freedesktop.portal.Request";

const appearance_namespace = "org.freedesktop.appearance";
const color_scheme_key = "color-scheme";
const desktop_namespace = "org.gnome.desktop.interface";
const cursor_theme_key = "cursor-theme";
const cursor_size_key = "cursor-size";

const response_rule = "type='signal',sender='org.freedesktop.portal.Desktop'," ++
    "interface='org.freedesktop.portal.Request',member='Response'";
const setting_rule = "type='signal',sender='org.freedesktop.portal.Desktop'," ++
    "interface='org.freedesktop.portal.Settings',member='SettingChanged'";

/// Most responses kept while their reply is still on its way. Responses of other applications also
/// pass through here, so the list is short and the oldest is dropped.
const max_early = 8;

/// The answer to one portal request.
pub const Outcome = union(enum) {
    /// The user answered with these URIs (`file://` for files), in the portal's order. Empty when
    /// the request returns no results, as OpenURI does. Valid during the callback only.
    answered: []const []const u8,
    /// The user dismissed the dialog (response code 1).
    cancelled,
    /// The request was not made, the portal refused it, or it failed (response code 2).
    failed: anyerror,
};

/// Receives the outcome of a request. `call` runs on the caller's thread, from the event loop, or
/// from the call itself when the request cannot be made at all.
pub const Completion = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, Outcome) void,

    pub fn call(self: Completion, outcome: Outcome) void {
        self.func(self.ctx, outcome);
    }
};

/// A desktop setting the portal reports (GPUI's `xdg_desktop_portal::Event`).
pub const Setting = union(enum) {
    color_scheme: platform.WindowAppearance,
    /// The cursor theme's name. Valid during the callback only.
    cursor_theme: []const u8,
    cursor_size: u32,
};

/// Receives settings as they are read and as they change. Valid for the state's lifetime.
pub const SettingListener = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, Setting) void,
};

pub const Error = error{
    /// No session bus address is set, or the bus cannot be reached.
    NoSessionBus,
    /// The bus has no service for the portal (it is not installed or not running).
    PortalUnavailable,
    /// The portal answered with an error, or refused the call.
    PortalRefused,
    /// A reply or response does not have the shape the specification gives it.
    MalformedReply,
    /// The bus was lost while the request was waiting for its answer.
    Disconnected,
};

/// Options of a file chooser request (GPUI's `PathPromptOptions`, and the save dialog's name).
pub const OpenOptions = struct {
    title: []const u8,
    accept_label: ?[]const u8 = null,
    /// Choose directories rather than files (`directories` in GPUI's options).
    directory: bool = false,
    multiple: bool = false,
};

pub const SaveOptions = struct {
    title: []const u8,
    accept_label: ?[]const u8 = null,
    /// The folder the dialog starts in. Sent as NUL-terminated bytes, as the portal wants.
    current_folder: ?[]const u8 = null,
    current_name: ?[]const u8 = null,
};

/// One request, from the call until its answer. Owned by the state from the call until it finishes.
const Request = struct {
    state: *State,
    /// Null when nothing waits for the answer: its failures are then logged instead.
    completion: ?Completion,
    /// The request object's path, from the reply. Null until the reply arrives.
    handle: ?[]u8 = null,
};

/// A response that arrived before its reply. Its URIs are copied out of the message.
const Early = struct {
    handle: []u8,
    outcome: Outcome,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    /// The bus to connect to. Null means the session bus; tests point it at a fake one.
    bus_address: ?[]const u8 = null,
    bus: ?*dbus.Connection = null,
    /// True once the session bus cannot be found at all. Nothing is retried then.
    no_bus: bool = false,
    /// True while the bus is delivering messages. A connection must not be freed then.
    dispatching: bool = false,
    /// Set after the first failure is logged; later failures are not logged.
    warned: bool = false,
    listener: SettingListener,
    pending: std.ArrayList(*Request) = .empty,
    early: std.ArrayList(Early) = .empty,
    /// Makes each request's `handle_token` unique.
    tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, listener: SettingListener) State {
        return .{ .allocator = allocator, .listener = listener };
    }

    /// Closes the bus. Requests still waiting are freed without an answer: nothing is delivered
    /// while the app is shutting down.
    pub fn deinit(self: *State) void {
        if (self.bus) |bus| bus.deinit();
        self.bus = null;
        for (self.pending.items) |req| {
            if (req.handle) |h| self.allocator.free(h);
            self.allocator.destroy(req);
        }
        self.pending.deinit(self.allocator);
        self.drop_early();
        self.early.deinit(self.allocator);
    }

    /// Connects to the session bus, subscribes to the portal's signals and reads the settings. Safe
    /// to call again; a connection already up is kept.
    pub fn start(self: *State) void {
        _ = self.connect_bus();
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

    /// Asks the file chooser for paths. The outcome is `answered` with `file://` URIs, which
    /// `file_uri_to_path` turns into paths.
    pub fn open_file(self: *State, options: OpenOptions, completion: Completion) void {
        var opts: [5]Option = undefined;
        var n: usize = 0;
        if (options.accept_label) |label| {
            opts[n] = .{ .key = "accept_label", .value = .{ .string = label } };
            n += 1;
        }
        opts[n] = .{ .key = "modal", .value = .{ .boolean = true } };
        n += 1;
        opts[n] = .{ .key = "multiple", .value = .{ .boolean = options.multiple } };
        n += 1;
        opts[n] = .{ .key = "directory", .value = .{ .boolean = options.directory } };
        n += 1;
        self.send_request(file_chooser, "OpenFile", "", options.title, opts[0..n], completion);
    }

    /// Asks the file chooser for a new file's path, starting in `options.current_folder`.
    pub fn save_file(self: *State, options: SaveOptions, completion: Completion) void {
        var opts: [5]Option = undefined;
        var n: usize = 0;
        if (options.accept_label) |label| {
            opts[n] = .{ .key = "accept_label", .value = .{ .string = label } };
            n += 1;
        }
        opts[n] = .{ .key = "modal", .value = .{ .boolean = true } };
        n += 1;
        if (options.current_folder) |folder| {
            opts[n] = .{ .key = "current_folder", .value = .{ .bytes = folder } };
            n += 1;
        }
        if (options.current_name) |name| {
            opts[n] = .{ .key = "current_name", .value = .{ .string = name } };
            n += 1;
        }
        self.send_request(file_chooser, "SaveFile", "", options.title, opts[0..n], completion);
    }

    /// Asks the desktop to open `uri` (OpenURI). The outcome is `answered` with no URIs, or `failed`.
    pub fn open_uri(self: *State, uri: []const u8, completion: ?Completion) void {
        self.send_request(open_uri_interface, "OpenURI", "", uri, &.{}, completion);
    }

    fn report(self: *State, comptime fmt: []const u8, args: anytype) void {
        if (self.warned) return;
        self.warned = true;
        std.log.warn("desktop portal: " ++ fmt ++ " (later failures are not logged)", args);
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
        self.bus = bus;
        self.setup(bus) catch |err| {
            self.drop_bus();
            self.report("cannot subscribe on the session bus: {s}", .{@errorName(err)});
            return null;
        };
        return bus;
    }

    /// Subscribes to the signals and reads the settings. Their replies are handled as they come.
    fn setup(self: *State, bus: *dbus.Connection) dbus.Error!void {
        try bus.add_listener(dbus.Handler.of(self, on_signal));
        try bus.add_match(response_rule);
        try bus.add_match(setting_rule);
        try read_setting(bus, appearance_namespace, color_scheme_key, dbus.Handler.of(self, on_read_color_scheme));
        try read_setting(bus, desktop_namespace, cursor_theme_key, dbus.Handler.of(self, on_read_cursor_theme));
        try read_setting(bus, desktop_namespace, cursor_size_key, dbus.Handler.of(self, on_read_cursor_size));
    }

    fn read_setting(bus: *dbus.Connection, namespace: []const u8, key: []const u8, handler: dbus.Handler) dbus.Error!void {
        var enc = dbus.Encoder.init(bus.allocator);
        defer enc.deinit();
        try enc.string(namespace);
        try enc.string(key);
        _ = try bus.call(.{
            .kind = .method_call,
            .destination = service,
            .path = portal_path,
            .interface = settings_interface,
            .member = "Read",
            .signature = "ss",
        }, enc.written(), handler);
    }

    /// Closes the bus and answers every request that waits on it with `Disconnected`.
    fn drop_bus(self: *State) void {
        if (self.bus) |bus| bus.deinit();
        self.bus = null;
        self.drop_early();
        // Taken first, so an answer that starts a new request sees a clean list.
        var waiting = self.pending;
        self.pending = .empty;
        for (waiting.items) |req| self.finish(req, .{ .failed = error.Disconnected });
        waiting.deinit(self.allocator);
    }

    fn drop_early(self: *State) void {
        for (self.early.items) |e| {
            self.allocator.free(e.handle);
            free_outcome(self.allocator, e.outcome);
        }
        self.early.clearRetainingCapacity();
    }

    /// Makes a request: the method call, then its answer through `Response`.
    fn send_request(
        self: *State,
        interface: []const u8,
        member: []const u8,
        parent_window: []const u8,
        first: []const u8,
        options: []const Option,
        completion: ?Completion,
    ) void {
        const req = self.allocator.create(Request) catch {
            return fail_now(completion, error.OutOfMemory);
        };
        req.* = .{ .state = self, .completion = completion };

        const bus = self.connect_bus() orelse {
            self.allocator.destroy(req);
            return fail_now(completion, error.NoSessionBus);
        };
        self.pending.append(self.allocator, req) catch {
            self.allocator.destroy(req);
            return fail_now(completion, error.OutOfMemory);
        };

        self.tokens +%= 1;
        var token_buf: [48]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "zui_{d}_{d}", .{ std.os.linux.getpid(), self.tokens }) catch unreachable;
        var all: [8]Option = undefined;
        all[0] = .{ .key = "handle_token", .value = .{ .string = token } };
        @memcpy(all[1..][0..options.len], options);

        var enc = dbus.Encoder.init(self.allocator);
        defer enc.deinit();
        encode_body(&enc, parent_window, first, all[0 .. options.len + 1]) catch |err| {
            return self.fail_request(req, err);
        };
        _ = bus.call(.{
            .kind = .method_call,
            .destination = service,
            .path = portal_path,
            .interface = interface,
            .member = member,
            .signature = "ssa{sv}",
        }, enc.written(), dbus.Handler.of(req, on_reply)) catch |err| {
            return self.fail_request(req, err);
        };
    }

    /// Ends a request that has not been answered by the portal.
    fn fail_request(self: *State, req: *Request, err: anyerror) void {
        self.remove_pending(req);
        self.finish(req, .{ .failed = err });
    }

    /// A request that failed before it was sent. Nothing is waiting for it, so only its failure
    /// is logged when there is no completion.
    fn fail_now(completion: ?Completion, err: anyerror) void {
        if (completion) |c| return c.call(.{ .failed = err });
        std.log.warn("desktop portal: request failed: {s}", .{@errorName(err)});
    }

    fn remove_pending(self: *State, req: *Request) void {
        for (self.pending.items, 0..) |r, i| {
            if (r == req) {
                _ = self.pending.swapRemove(i);
                return;
            }
        }
    }

    /// Delivers the outcome and frees the request. The request must already be off `pending`.
    fn finish(self: *State, req: *Request, outcome: Outcome) void {
        if (req.completion) |c| {
            c.call(outcome);
        } else switch (outcome) {
            .failed => |err| std.log.warn("desktop portal: request failed: {s}", .{@errorName(err)}),
            .answered, .cancelled => {},
        }
        if (req.handle) |h| self.allocator.free(h);
        self.allocator.destroy(req);
    }

    /// Runs for the method reply of a request: the request object's path, or the error.
    fn on_reply(req: *Request, msg: *const dbus.Message) void {
        const self = req.state;
        const path = reply_path(msg) catch |err| return self.fail_request(req, err);
        if (self.take_early(path)) |e| {
            self.allocator.free(e.handle);
            self.remove_pending(req);
            self.finish(req, e.outcome);
            free_outcome(self.allocator, e.outcome);
            return;
        }
        req.handle = self.allocator.dupe(u8, path) catch {
            return self.fail_request(req, error.OutOfMemory);
        };
    }

    /// Runs for every signal that reaches the connection. Only the portal's signals matter.
    fn on_signal(self: *State, msg: *const dbus.Message) void {
        const interface = msg.header.interface orelse return;
        const member = msg.header.member orelse return;
        if (std.mem.eql(u8, interface, request_interface) and std.mem.eql(u8, member, "Response")) {
            self.on_response(msg);
        } else if (std.mem.eql(u8, interface, settings_interface) and std.mem.eql(u8, member, "SettingChanged")) {
            self.on_setting_changed(msg);
        }
    }

    fn on_response(self: *State, msg: *const dbus.Message) void {
        const path = msg.header.path orelse return;
        if (!std.mem.startsWith(u8, path, request_prefix)) return;
        const outcome = parse_response(self.allocator, msg) catch |err| Outcome{ .failed = err };

        for (self.pending.items, 0..) |req, i| {
            const handle = req.handle orelse continue;
            if (!std.mem.eql(u8, handle, path)) continue;
            _ = self.pending.swapRemove(i);
            self.finish(req, outcome);
            free_outcome(self.allocator, outcome);
            return;
        }
        self.stash_early(path, outcome);
    }

    fn stash_early(self: *State, path: []const u8, outcome: Outcome) void {
        const handle = self.allocator.dupe(u8, path) catch {
            free_outcome(self.allocator, outcome);
            return;
        };
        if (self.early.items.len == max_early) {
            const oldest = self.early.orderedRemove(0);
            self.allocator.free(oldest.handle);
            free_outcome(self.allocator, oldest.outcome);
        }
        self.early.append(self.allocator, .{ .handle = handle, .outcome = outcome }) catch {
            self.allocator.free(handle);
            free_outcome(self.allocator, outcome);
        };
    }

    fn take_early(self: *State, path: []const u8) ?Early {
        for (self.early.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.handle, path)) return self.early.orderedRemove(i);
        }
        return null;
    }

    fn on_setting_changed(self: *State, msg: *const dbus.Message) void {
        if (!std.mem.eql(u8, msg.header.signature, "ssv")) return;
        const ns = as_string(msg.body[0]) orelse return;
        const key = as_string(msg.body[1]) orelse return;
        const setting = to_setting(ns, key, unwrap(msg.body[2])) orelse return;
        self.listener.func(self.listener.ctx, setting);
    }

    fn on_read(self: *State, namespace: []const u8, key: []const u8, msg: *const dbus.Message) void {
        if (msg.header.kind != .method_return or msg.body.len != 1) return;
        // Read answers with a variant; anything else is malformed and ignored.
        if (msg.body[0] != .variant) return;
        const setting = to_setting(namespace, key, unwrap(msg.body[0])) orelse return;
        self.listener.func(self.listener.ctx, setting);
    }

    fn on_read_color_scheme(self: *State, msg: *const dbus.Message) void {
        self.on_read(appearance_namespace, color_scheme_key, msg);
    }

    fn on_read_cursor_theme(self: *State, msg: *const dbus.Message) void {
        self.on_read(desktop_namespace, cursor_theme_key, msg);
    }

    fn on_read_cursor_size(self: *State, msg: *const dbus.Message) void {
        self.on_read(desktop_namespace, cursor_size_key, msg);
    }
};

// ---------------------------------------------------------------------------------------------
// Encoding

const OptionValue = union(enum) {
    string: []const u8,
    boolean: bool,
    /// Bytes sent as `ay` with a terminating NUL, as the portal wants for paths.
    bytes: []const u8,
};

const Option = struct {
    key: []const u8,
    value: OptionValue,
};

/// Writes `parent_window`, `first` and the options as `ssa{sv}`.
fn encode_body(enc: *dbus.Encoder, parent_window: []const u8, first: []const u8, options: []const Option) dbus.Error!void {
    try enc.string(parent_window);
    try enc.string(first);
    try enc.begin_array("{sv}");
    for (options) |opt| {
        try enc.begin_dict_entry();
        try enc.string(opt.key);
        switch (opt.value) {
            .string => |s| {
                try enc.begin_variant("s");
                try enc.string(s);
                try enc.end_variant();
            },
            .boolean => |b| {
                try enc.begin_variant("b");
                try enc.boolean(b);
                try enc.end_variant();
            },
            .bytes => |b| {
                try enc.begin_variant("ay");
                try enc.begin_array("y");
                for (b) |c| try enc.byte(c);
                try enc.byte(0);
                try enc.end_array();
                try enc.end_variant();
            },
        }
        try enc.end_dict_entry();
    }
    try enc.end_array();
}

// ---------------------------------------------------------------------------------------------
// Decoding

fn as_string(v: dbus.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// The value inside any variants around `v`. The settings portal wraps a value in one variant, and
/// `Read` wraps it in two.
fn unwrap(v: dbus.Value) dbus.Value {
    var cur = v;
    while (true) {
        switch (cur) {
            .variant => |var_| cur = var_.value.*,
            else => return cur,
        }
    }
}

/// The setting `key` of `namespace` as its value, when it is one this state reports.
fn to_setting(namespace: []const u8, key: []const u8, value: dbus.Value) ?Setting {
    if (std.mem.eql(u8, namespace, appearance_namespace) and std.mem.eql(u8, key, color_scheme_key)) {
        // 1 prefers dark, 2 prefers light, 0 has no preference, which GPUI shows as light.
        const scheme = switch (value) {
            .uint32 => |n| n,
            else => return null,
        };
        return .{ .color_scheme = if (scheme == 1) .dark else .light };
    }
    if (std.mem.eql(u8, namespace, desktop_namespace) and std.mem.eql(u8, key, cursor_theme_key)) {
        return .{ .cursor_theme = as_string(value) orelse return null };
    }
    if (std.mem.eql(u8, namespace, desktop_namespace) and std.mem.eql(u8, key, cursor_size_key)) {
        const size = switch (value) {
            .int32 => |n| n,
            else => return null,
        };
        if (size <= 0) return null;
        return .{ .cursor_size = @intCast(size) };
    }
    return null;
}

/// The request object's path a reply names.
fn reply_path(msg: *const dbus.Message) Error![]const u8 {
    if (msg.header.kind == .error_reply) return error_for(msg.header.error_name);
    if (msg.header.kind != .method_return) return error.MalformedReply;
    if (msg.body.len != 1) return error.MalformedReply;
    const path = switch (msg.body[0]) {
        .object_path => |p| p,
        else => return error.MalformedReply,
    };
    if (!dbus.valid_object_path(path)) return error.MalformedReply;
    return path;
}

/// What a method error means: no service on the bus is "unavailable"; anything else is a refusal.
fn error_for(name: ?[]const u8) Error {
    const n = name orelse return error.PortalRefused;
    const unavailable = [_][]const u8{
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
        "org.freedesktop.DBus.Error.UnknownObject",
        "org.freedesktop.DBus.Error.UnknownInterface",
        "org.freedesktop.DBus.Error.UnknownMethod",
    };
    for (unavailable) |u| {
        if (std.mem.eql(u8, n, u)) return error.PortalUnavailable;
    }
    return error.PortalRefused;
}

/// Reads a `Response` signal (`ua{sv}`) into an outcome whose URIs are copies.
fn parse_response(gpa: std.mem.Allocator, msg: *const dbus.Message) !Outcome {
    if (!std.mem.eql(u8, msg.header.signature, "ua{sv}")) return .{ .failed = error.MalformedReply };
    const code = switch (msg.body[0]) {
        .uint32 => |c| c,
        else => return .{ .failed = error.MalformedReply },
    };
    switch (code) {
        0 => {
            const uris = try read_uris(gpa, msg.body[1]);
            return .{ .answered = uris };
        },
        1 => return .cancelled,
        // 2 is "other error"; any other code is not in the specification.
        else => return .{ .failed = error.PortalRefused },
    }
}

/// The `uris` entry of the results dictionary, copied out. Absent means no URIs.
fn read_uris(gpa: std.mem.Allocator, results: dbus.Value) ![]const []const u8 {
    const entries = switch (results) {
        .array => |a| a.items,
        else => return error.MalformedReply,
    };
    for (entries) |entry| {
        const kv = switch (entry) {
            .dict_entry => |e| e,
            else => return error.MalformedReply,
        };
        const key = as_string(kv.key.*) orelse return error.MalformedReply;
        if (!std.mem.eql(u8, key, "uris")) continue;
        const list = switch (unwrap(kv.value.*)) {
            .array => |a| a,
            else => return error.MalformedReply,
        };
        if (!std.mem.eql(u8, list.element, "s")) return error.MalformedReply;
        const out = try gpa.alloc([]const u8, list.items.len);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |s| gpa.free(s);
            gpa.free(out);
        }
        for (list.items, 0..) |item, i| {
            const s = as_string(item) orelse return error.MalformedReply;
            out[i] = try gpa.dupe(u8, s);
            done = i + 1;
        }
        return out;
    }
    return &.{};
}

fn free_outcome(gpa: std.mem.Allocator, outcome: Outcome) void {
    switch (outcome) {
        .answered => |uris| {
            // An empty list is a constant, not an allocation.
            if (uris.len == 0) return;
            for (uris) |s| gpa.free(s);
            gpa.free(uris);
        },
        .cancelled, .failed => {},
    }
}

/// The local path of a `file:` URI, percent-decoded into `buf`, as the `url` crate's `to_file_path`
/// gives it. Null for any other scheme, a host other than empty or `localhost`, a path that is not
/// absolute, or a path that does not fit `buf`. A query or fragment is not part of the path.
pub fn file_uri_to_path(uri: []const u8, buf: []u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(uri, "file:")) return null;
    var rest = uri["file:".len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const host = rest[0..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
        rest = rest[slash..];
    }
    if (rest.len == 0 or rest[0] != '/') return null;
    if (std.mem.indexOfAny(u8, rest, "?#")) |cut| rest = rest[0..cut];

    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) {
        if (n >= buf.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = hex_value(rest[i + 1]);
            const lo = hex_value(rest[i + 2]);
            if (hi != null and lo != null) {
                buf[n] = hi.? << 4 | lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        buf[n] = rest[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

fn hex_value(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------------------------
// Tests: a fake portal on an abstract socket, in a thread. It checks each call the state makes,
// argument by argument, and answers the way the script says.

const testing = std.testing;
const linux = std.os.linux;
const ts = @import("dbus_test_server.zig");
const Server = ts.Server;

/// What the fake portal does, and what it found wrong with the calls it saw.
const Script = struct {
    /// The color scheme the fake reports on `Read` (1 dark, 2 light, 0 no preference).
    scheme: u32 = 2,
    /// Answer the color scheme read with a bare value instead of a variant.
    read_malformed: bool = false,
    /// After the color scheme read, send `SettingChanged` with this scheme.
    change_to: ?u32 = null,
    /// Refuse each request with this error name instead of answering it.
    request_error: ?[]const u8 = null,
    /// The request method the client must call, the first string it must send, and the options
    /// it must send, rendered by `render_options` (handle_token excluded).
    expect_member: []const u8 = "",
    expect_first: []const u8 = "",
    expect_options: []const u8 = "",
    /// The response code and URIs the request's `Response` carries.
    response_code: u32 = 0,
    response_uris: []const []const u8 = &.{},
    /// Send the URIs as a string instead of an array of strings.
    uris_malformed: bool = false,
    /// Send `Response` before the method reply, as a portal may.
    response_before_reply: bool = false,
    /// Close the connection when the request arrives, without answering it.
    drop_on_request: bool = false,
    /// Set when the client did not do what the script expects. Read after the server has stopped.
    failure: ?[]const u8 = null,
};

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
        // The client closing the connection is how every test ends.
        if (err != error.EndOfStream) script.failure = @errorName(err);
    };
}

fn serve_session(server: *Server, script: *Script) !void {
    var line_buf: [256]u8 = undefined;
    const auth = try server.read_line(&line_buf);
    if (!std.mem.startsWith(u8, auth, "\x00AUTH EXTERNAL ")) return error.BadAuth;
    try server.write("OK 0123456789abcdef0123456789abcdef\r\n");
    if (!std.mem.eql(u8, try server.read_line(&line_buf), "BEGIN")) return error.BadBegin;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const msg = try server.next_message(arena.allocator());
        if (msg.header.kind != .method_call) continue;
        const member = msg.header.member orelse "";
        if (std.mem.eql(u8, member, "Hello")) {
            var name = dbus.Encoder.init(testing.allocator);
            defer name.deinit();
            try name.string(":1.7");
            try server.reply(msg, "s", name.written());
        } else if (std.mem.eql(u8, member, "AddMatch")) {
            try server.reply(msg, "", "");
        } else if (std.mem.eql(u8, member, "Read")) {
            try answer_read(server, msg, script);
        } else {
            if (!try answer_request(server, msg, script)) return;
        }
    }
}

/// Answers `Settings.Read`, checking its arguments.
fn answer_read(server: *Server, msg: dbus.Message, script: *Script) !void {
    if (!std.mem.eql(u8, msg.header.interface orelse "", settings_interface)) return error.BadInterface;
    if (!std.mem.eql(u8, msg.header.signature, "ss")) return error.BadSignature;
    const ns = try test_string(msg.body[0]);
    const key = try test_string(msg.body[1]);
    var enc = dbus.Encoder.init(testing.allocator);
    defer enc.deinit();
    if (std.mem.eql(u8, ns, appearance_namespace) and std.mem.eql(u8, key, color_scheme_key)) {
        if (script.read_malformed) {
            try enc.uint32(script.scheme);
            try server.reply(msg, "u", enc.written());
        } else {
            try enc.begin_variant("v");
            try enc.begin_variant("u");
            try enc.uint32(script.scheme);
            try enc.end_variant();
            try enc.end_variant();
            try server.reply(msg, "v", enc.written());
        }
        if (script.change_to) |scheme| {
            var change = dbus.Encoder.init(testing.allocator);
            defer change.deinit();
            try change.string(appearance_namespace);
            try change.string(color_scheme_key);
            try change.begin_variant("u");
            try change.uint32(scheme);
            try change.end_variant();
            try server.signal_at(portal_path, settings_interface, "SettingChanged", "ssv", change.written());
        }
    } else if (std.mem.eql(u8, ns, desktop_namespace) and std.mem.eql(u8, key, cursor_theme_key)) {
        try enc.begin_variant("v");
        try enc.begin_variant("s");
        try enc.string("Adwaita");
        try enc.end_variant();
        try enc.end_variant();
        try server.reply(msg, "v", enc.written());
    } else if (std.mem.eql(u8, ns, desktop_namespace) and std.mem.eql(u8, key, cursor_size_key)) {
        try enc.begin_variant("v");
        try enc.begin_variant("i");
        try enc.int32(24);
        try enc.end_variant();
        try enc.end_variant();
        try server.reply(msg, "v", enc.written());
    } else {
        try server.reply_error(msg, "org.freedesktop.portal.Error.NotFound");
    }
}

/// Answers one of the three requests. Returns false when the connection is to be closed.
fn answer_request(server: *Server, msg: dbus.Message, script: *Script) !bool {
    const member = msg.header.member orelse "";
    const want_interface: []const u8 = if (std.mem.eql(u8, member, "OpenURI")) open_uri_interface else file_chooser;
    const known = std.mem.eql(u8, member, "OpenFile") or std.mem.eql(u8, member, "SaveFile") or std.mem.eql(u8, member, "OpenURI");
    if (!known) {
        try server.reply_error(msg, "org.freedesktop.DBus.Error.UnknownMethod");
        return true;
    }
    if (!std.mem.eql(u8, member, script.expect_member)) return bad(script, "unexpected method");
    if (!std.mem.eql(u8, msg.header.destination orelse "", service)) return bad(script, "destination");
    if (!std.mem.eql(u8, msg.header.path orelse "", portal_path)) return bad(script, "object path");
    if (!std.mem.eql(u8, msg.header.interface orelse "", want_interface)) return bad(script, "interface");
    if (!std.mem.eql(u8, msg.header.signature, "ssa{sv}")) return bad(script, "signature");
    if (msg.body.len != 3) return bad(script, "argument count");
    if (!std.mem.eql(u8, try test_string(msg.body[0]), "")) return bad(script, "parent window");
    if (!std.mem.eql(u8, try test_string(msg.body[1]), script.expect_first)) return bad(script, "first argument");

    const token = find_token(msg.body[2]) orelse return bad(script, "handle_token missing");
    if (!std.mem.startsWith(u8, token, "zui_") or std.mem.indexOfAny(u8, token, "/ ") != null) {
        return bad(script, "handle_token");
    }
    const rendered = try render_options(testing.allocator, msg.body[2]);
    defer testing.allocator.free(rendered);
    if (!std.mem.eql(u8, rendered, script.expect_options)) {
        std.debug.print("portal test: options were {s}\n", .{rendered});
        return bad(script, "options");
    }

    if (script.request_error) |name| {
        try server.reply_error(msg, name);
        return true;
    }
    if (script.drop_on_request) return false;

    var handle_buf: [160]u8 = undefined;
    const handle = try std.fmt.bufPrint(&handle_buf, "{s}1_7/{s}", .{ request_prefix, token });
    var handle_enc = dbus.Encoder.init(testing.allocator);
    defer handle_enc.deinit();
    try handle_enc.object_path(handle);
    if (script.response_before_reply) {
        try send_response(server, handle, script);
        try server.reply(msg, "o", handle_enc.written());
    } else {
        try server.reply(msg, "o", handle_enc.written());
        try send_response(server, handle, script);
    }
    return true;
}

fn bad(script: *Script, what: []const u8) bool {
    script.failure = what;
    return false;
}

fn send_response(server: *Server, handle: []const u8, script: *Script) !void {
    var enc = dbus.Encoder.init(testing.allocator);
    defer enc.deinit();
    try enc.uint32(script.response_code);
    try enc.begin_array("{sv}");
    if (script.response_code == 0) {
        try enc.begin_dict_entry();
        try enc.string("uris");
        if (script.uris_malformed) {
            try enc.begin_variant("s");
            try enc.string("not a list");
            try enc.end_variant();
        } else {
            try enc.begin_variant("as");
            try enc.begin_array("s");
            for (script.response_uris) |u| try enc.string(u);
            try enc.end_array();
            try enc.end_variant();
        }
        try enc.end_dict_entry();
    }
    try enc.end_array();
    try server.signal_at(handle, request_interface, "Response", "ua{sv}", enc.written());
}

fn test_string(v: dbus.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .object_path => |s| s,
        else => error.BadArguments,
    };
}

/// The `handle_token` option's value, if the call has one.
fn find_token(options: dbus.Value) ?[]const u8 {
    for (options.array.items) |entry| {
        const kv = entry.dict_entry;
        if (!std.mem.eql(u8, kv.key.string, "handle_token")) continue;
        return as_string(unwrap(kv.value.*));
    }
    return null;
}

/// The options as `key=type:value` pairs in the order sent, without `handle_token`. Bytes are
/// shown with their NUL as `|`.
fn render_options(gpa: std.mem.Allocator, options: dbus.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (options.array.items) |entry| {
        const kv = entry.dict_entry;
        if (std.mem.eql(u8, kv.key.string, "handle_token")) continue;
        if (out.items.len > 0) try out.append(gpa, ';');
        try out.appendSlice(gpa, kv.key.string);
        try out.append(gpa, '=');
        switch (unwrap(kv.value.*)) {
            .string => |s| {
                try out.appendSlice(gpa, "s:");
                try out.appendSlice(gpa, s);
            },
            .boolean => |b| try out.appendSlice(gpa, if (b) "b:true" else "b:false"),
            .array => |a| {
                try out.appendSlice(gpa, "ay:");
                for (a.items) |byte| try out.append(gpa, if (byte.byte == 0) '|' else byte.byte);
            },
            else => try out.appendSlice(gpa, "?"),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Copies what a completion receives, so the test can read it after the callback.
const Recorder = struct {
    done: bool = false,
    cancelled: bool = false,
    err: ?anyerror = null,
    count: usize = 0,
    uris: [4][256]u8 = undefined,
    lens: [4]usize = @splat(0),

    fn on_outcome(ctx: *anyopaque, outcome: Outcome) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.done = true;
        switch (outcome) {
            .answered => |uris| {
                self.count = uris.len;
                for (uris, 0..) |u, i| {
                    @memcpy(self.uris[i][0..u.len], u);
                    self.lens[i] = u.len;
                }
            },
            .cancelled => self.cancelled = true,
            .failed => |e| self.err = e,
        }
    }

    fn completion(self: *Recorder) Completion {
        return .{ .ctx = self, .func = on_outcome };
    }

    fn uri(self: *const Recorder, i: usize) []const u8 {
        return self.uris[i][0..self.lens[i]];
    }

    fn is_done(self: *Recorder) bool {
        return self.done;
    }
};

/// Records the settings the state reports.
const Settings = struct {
    scheme: ?platform.WindowAppearance = null,
    scheme_count: usize = 0,
    theme: [64]u8 = undefined,
    theme_len: ?usize = null,
    size: ?u32 = null,

    fn on_setting(ctx: *anyopaque, setting: Setting) void {
        const self: *Settings = @ptrCast(@alignCast(ctx));
        switch (setting) {
            .color_scheme => |a| {
                self.scheme = a;
                self.scheme_count += 1;
            },
            .cursor_theme => |name| {
                @memcpy(self.theme[0..name.len], name);
                self.theme_len = name.len;
            },
            .cursor_size => |n| self.size = n,
        }
    }

    fn listener(self: *Settings) SettingListener {
        return .{ .ctx = self, .func = on_setting };
    }

    /// The last setting the fake portal sends on start-up is the cursor size.
    fn is_read(self: *Settings) bool {
        return self.size != null;
    }
};

/// Pumps the state's connection until `done(ctx)`, or fails after a bounded number of rounds.
fn pump(state: *State, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    var rounds: usize = 0;
    while (!done(ctx)) : (rounds += 1) {
        if (rounds > 200) return error.TimedOut;
        const fd = state.bus_socket();
        if (fd < 0) return error.NoBus;
        var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = state.bus_events(), .revents = 0 }};
        _ = std.posix.poll(&pfd, 50) catch 0;
        state.on_bus_poll(pfd[0].revents);
    }
}

fn no_pending(state: *State) bool {
    return state.pending.items.len == 0;
}

/// A fake portal in a thread, and a state pointed at it. `thread.join` must run after
/// `state.deinit`, since the server waits for the client to close. The state keeps the address
/// for reconnects, so `Fake` must not move while the state uses it.
const Fake = struct {
    thread: std.Thread = undefined,
    addr_buf: [96]u8 = undefined,

    fn start(self: *Fake, script: *Script, state: *State, settings: *Settings) !void {
        var name_buf: [64]u8 = undefined;
        const name = ts.unique_name(&name_buf, "zui-portal-test");
        const listener = try ts.listen_abstract(name);
        state.* = State.init(testing.allocator, settings.listener());
        state.bus_address = try ts.abstract_address(&self.addr_buf, name);
        self.thread = try std.Thread.spawn(.{}, serve, .{ listener, script });
        state.start();
    }
};

/// Runs the client side of one test. The fake portal has stopped when this returns.
fn client_open_file(script: *Script, settings: *Settings, rec: *Recorder, options: OpenOptions) !void {
    var state: State = undefined;
    var fake: Fake = .{};
    try fake.start(script, &state, settings);
    defer fake.thread.join();
    defer state.deinit();
    state.open_file(options, rec.completion());
    try pump(&state, rec, Recorder.is_done);
}

test "portal: open file sends the documented arguments and returns the chosen files" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "accept_label=s:Pick;modal=b:true;multiple=b:true;directory=b:false",
        .response_uris = &.{ "file:///tmp/caf%C3%A9%20x.txt", "file:///tmp/plain" },
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File", .accept_label = "Pick", .multiple = true });
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expect(rec.err == null and !rec.cancelled);
    try testing.expectEqual(@as(usize, 2), rec.count);
    try testing.expectEqualStrings("file:///tmp/caf%C3%A9%20x.txt", rec.uri(0));
    var path_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/caf\u{e9} x.txt", file_uri_to_path(rec.uri(0), &path_buf).?);
    try testing.expectEqualStrings("/tmp/plain", file_uri_to_path(rec.uri(1), &path_buf).?);
}

test "portal: a cancelled dialog is cancelled, not an error" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open Folder",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:true",
        .response_code = 1,
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open Folder", .directory = true });
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expect(rec.cancelled);
    try testing.expectEqual(@as(?anyerror, null), rec.err);
}

test "portal: a refused dialog (response 2) is an error" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:false",
        .response_code = 2,
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File" });
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(@as(?anyerror, error.PortalRefused), rec.err);
}

test "portal: a missing portal answers unavailable, without waiting" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:false",
        .request_error = "org.freedesktop.DBus.Error.ServiceUnknown",
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File" });
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(@as(?anyerror, error.PortalUnavailable), rec.err);
}

test "portal: a refusing portal (any other error) is an error" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:false",
        .request_error = "org.freedesktop.portal.Error.NotAllowed",
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File" });
    try testing.expectEqual(@as(?anyerror, error.PortalRefused), rec.err);
}

test "portal: a response that arrives before its reply is still delivered" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:false",
        .response_before_reply = true,
        .response_uris = &.{"file:///tmp/early"},
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File" });
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(@as(usize, 1), rec.count);
    try testing.expectEqualStrings("file:///tmp/early", rec.uri(0));
}

test "portal: a malformed response is an error, not a list of paths" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:false",
        .response_uris = &.{"file:///tmp/x"},
        .uris_malformed = true,
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File" });
    try testing.expectEqual(@as(?anyerror, error.MalformedReply), rec.err);
    try testing.expectEqual(@as(usize, 0), rec.count);
}

test "portal: a lost bus fails the request that waits on it" {
    var script = Script{
        .expect_member = "OpenFile",
        .expect_first = "Open File",
        .expect_options = "modal=b:true;multiple=b:false;directory=b:false",
        .drop_on_request = true,
    };
    var settings = Settings{};
    var rec = Recorder{};
    try client_open_file(&script, &settings, &rec, .{ .title = "Open File" });
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(@as(?anyerror, error.Disconnected), rec.err);
}

test "portal: save file sends the folder as NUL-terminated bytes and the name" {
    var script = Script{
        .expect_member = "SaveFile",
        .expect_first = "Save File",
        .expect_options = "accept_label=s:Save;modal=b:true;current_folder=ay:/tmp/docs|;current_name=s:a.txt",
        .response_uris = &.{"file:///tmp/docs/a.txt"},
    };
    var settings = Settings{};
    var state: State = undefined;
    var rec = Recorder{};
    {
        var fake: Fake = .{};
        try fake.start(&script, &state, &settings);
        defer fake.thread.join();
        defer state.deinit();
        state.save_file(.{ .title = "Save File", .accept_label = "Save", .current_folder = "/tmp/docs", .current_name = "a.txt" }, rec.completion());
        try pump(&state, &rec, Recorder.is_done);
    }
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(@as(?anyerror, null), rec.err);
    try testing.expectEqualStrings("file:///tmp/docs/a.txt", rec.uri(0));
}

test "portal: open uri sends the uri, and its answer is not needed" {
    var script = Script{
        .expect_member = "OpenURI",
        .expect_first = "https://example.com/a?b=c",
        .expect_options = "",
    };
    var settings = Settings{};
    var state: State = undefined;
    {
        var fake: Fake = .{};
        try fake.start(&script, &state, &settings);
        defer fake.thread.join();
        defer state.deinit();
        state.open_uri("https://example.com/a?b=c", null);
        try pump(&state, &state, no_pending);
    }
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
}

test "portal: no session bus fails the request at once" {
    var settings = Settings{};
    var state = State.init(testing.allocator, settings.listener());
    defer state.deinit();
    state.bus_address = "unix:path=/nonexistent/zui-portal-test-no-bus";
    var rec = Recorder{};
    state.open_file(.{ .title = "Open File" }, rec.completion());
    try testing.expectEqual(@as(?anyerror, error.NoSessionBus), rec.err);
    try testing.expectEqual(@as(c_int, -1), state.bus_socket());
    try testing.expectEqual(@as(usize, 0), state.pending.items.len);
}

test "portal: the color scheme is read, then followed when it changes" {
    var script = Script{ .scheme = 1, .change_to = 2 };
    var settings = Settings{};
    var state: State = undefined;
    {
        var fake: Fake = .{};
        try fake.start(&script, &state, &settings);
        defer fake.thread.join();
        defer state.deinit();
        try pump(&state, &settings, Settings.is_read);
        try pump(&state, &settings, struct {
            fn done(s: *Settings) bool {
                return s.scheme_count >= 2;
            }
        }.done);
    }
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(platform.WindowAppearance.light, settings.scheme.?);
    try testing.expectEqualStrings("Adwaita", settings.theme[0..settings.theme_len.?]);
    try testing.expectEqual(@as(?u32, 24), settings.size);
}

test "portal: a malformed color scheme reply is ignored, the other settings still arrive" {
    var script = Script{ .scheme = 1, .read_malformed = true };
    var settings = Settings{};
    var state: State = undefined;
    {
        var fake: Fake = .{};
        try fake.start(&script, &state, &settings);
        defer fake.thread.join();
        defer state.deinit();
        try pump(&state, &settings, Settings.is_read);
    }
    try testing.expectEqual(@as(?[]const u8, null), script.failure);
    try testing.expectEqual(@as(usize, 0), settings.scheme_count);
    try testing.expectEqualStrings("Adwaita", settings.theme[0..settings.theme_len.?]);
}

test "portal: file URIs become paths, percent-decoded, and other URIs are not paths" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/a b", file_uri_to_path("file:///tmp/a%20b", &buf).?);
    try testing.expectEqualStrings("/tmp/caf\u{e9}", file_uri_to_path("file:///tmp/caf%C3%A9", &buf).?);
    try testing.expectEqualStrings("/a/b", file_uri_to_path("file://localhost/a/b", &buf).?);
    try testing.expectEqualStrings("/a/b", file_uri_to_path("file:/a/b", &buf).?);
    try testing.expectEqualStrings("/x", file_uri_to_path("FILE:///x", &buf).?);
    try testing.expectEqualStrings("/a/b", file_uri_to_path("file:///a/b?query#frag", &buf).?);
    try testing.expectEqualStrings("/a/b/c", file_uri_to_path("file:///a%2Fb/c", &buf).?);
    try testing.expectEqualStrings("/a%zz", file_uri_to_path("file:///a%zz", &buf).?);
    try testing.expectEqualStrings("/caf\u{e9}", file_uri_to_path("file:///caf\u{e9}", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), file_uri_to_path("file://other.host/a", &buf));
    try testing.expectEqual(@as(?[]const u8, null), file_uri_to_path("https://example.com/a", &buf));
    try testing.expectEqual(@as(?[]const u8, null), file_uri_to_path("file:relative", &buf));
    try testing.expectEqual(@as(?[]const u8, null), file_uri_to_path("file:///long", buf[0..3]));
}
