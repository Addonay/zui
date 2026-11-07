//! The server side of a fake D-Bus bus, for tests. A test listens on an abstract socket, points a
//! `dbus.Connection` at it, and answers from a thread with `Server`. Shared by the notification and
//! portal tests, so both speak the same wire format from the same code.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus.zig");

/// Answers on the bus side of a connection, one message at a time.
pub const Server = struct {
    fd: c_int,
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    next_serial: u32 = 100,

    pub fn deinit(self: *Server) void {
        self.buf.deinit(self.gpa);
    }

    /// Reads more bytes; fails rather than block forever if the client goes quiet.
    pub fn fill(self: *Server) !void {
        try self.buf.ensureUnusedCapacity(self.gpa, 4096);
        const spare = self.buf.unusedCapacitySlice();
        const rc = linux.read(self.fd, spare.ptr, spare.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                self.buf.items.len += rc;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }

    /// Reads one line of the authentication phase into `out`. Compacting the buffer would overwrite
    /// the line, so the line is copied out first.
    pub fn read_line(self: *Server, out: []u8) ![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buf.items, "\r\n")) |eol| {
                if (eol > out.len) return error.LineTooLong;
                @memcpy(out[0..eol], self.buf.items[0..eol]);
                const rest = self.buf.items[eol + 2 ..];
                std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
                self.buf.items.len = rest.len;
                return out[0..eol];
            }
            try self.fill();
        }
    }

    pub fn next_message(self: *Server, arena: std.mem.Allocator) !dbus.Message {
        while (true) {
            if (self.buf.items.len >= 16) {
                if (dbus.frame_length(self.buf.items)) |total| {
                    if (self.buf.items.len >= total) {
                        const msg = try dbus.parse(arena, self.buf.items[0..total]);
                        const rest = self.buf.items[total..];
                        std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
                        self.buf.items.len = rest.len;
                        return msg;
                    }
                } else |err| if (err != error.Truncated) return err;
            }
            try self.fill();
        }
    }

    pub fn write(self: *Server, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(self.fd, bytes[off..].ptr, bytes.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
    }

    pub fn take_serial(self: *Server) u32 {
        self.next_serial += 1;
        return self.next_serial;
    }

    /// A method return with `body`, whose signature is `body_sig`.
    pub fn reply(self: *Server, call: dbus.Message, body_sig: []const u8, body: []const u8) !void {
        const bytes = try dbus.encode(self.gpa, .{
            .kind = .method_return,
            .serial = self.take_serial(),
            .reply_serial = call.header.serial,
            .signature = body_sig,
        }, body);
        defer self.gpa.free(bytes);
        try self.write(bytes);
    }

    /// An error reply named `name`, with the text "refused" as its one string.
    pub fn reply_error(self: *Server, call: dbus.Message, name: []const u8) !void {
        var enc = dbus.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.string("refused");
        const bytes = try dbus.encode(self.gpa, .{
            .kind = .error_reply,
            .serial = self.take_serial(),
            .reply_serial = call.header.serial,
            .error_name = name,
            .signature = "s",
        }, enc.written());
        defer self.gpa.free(bytes);
        try self.write(bytes);
    }

    /// A signal `member` of `interface` sent from `path`, as the sender of a bus name would send it.
    pub fn signal_at(self: *Server, path: []const u8, interface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !void {
        const bytes = try dbus.encode(self.gpa, .{
            .kind = .signal,
            .serial = self.take_serial(),
            .path = path,
            .interface = interface,
            .member = member,
            .signature = sig,
        }, body);
        defer self.gpa.free(bytes);
        try self.write(bytes);
    }
};

pub const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

/// Listens on a fresh abstract socket named `name`. The name must be unique per test run.
pub fn listen_abstract(name: []const u8) !c_int {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: c_int = @intCast(rc);
    errdefer _ = linux.close(fd);
    var sa = SockaddrUn{ .family = linux.AF.UNIX, .path = std.mem.zeroes([108]u8) };
    @memcpy(sa.path[1..][0..name.len], name);
    const len: u32 = @intCast(@offsetOf(SockaddrUn, "path") + 1 + name.len);
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), len)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 1)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

var test_counter: std.atomic.Value(u32) = .init(0);

/// A fresh abstract socket name in `buf`, unique in this process and across processes.
pub fn unique_name(buf: []u8, prefix: []const u8) []const u8 {
    const n = test_counter.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buf, "{s}-{d}-{d}", .{ prefix, linux.getpid(), n }) catch unreachable;
}

/// The `unix:abstract=` address of a listener made by `listen_abstract`.
pub fn abstract_address(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "unix:abstract={s}", .{name});
}
