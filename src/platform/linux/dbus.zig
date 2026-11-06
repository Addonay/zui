//! A D-Bus client over a Unix socket: the wire format of the D-Bus specification, the SASL
//! EXTERNAL handshake, method calls matched to their replies by serial, and signals. No libdbus and
//! no dlopen. Used for desktop services such as notifications; file dialogs and the settings portal
//! will use it too.
//!
//! The connection never blocks the UI thread. The socket is non-blocking once connected (the connect
//! itself waits at most one second, and only when the bus has a full listen queue). The owner polls
//! `Connection.socket()` with `poll_events()` from its main loop and passes the result to `on_poll`,
//! which writes what is queued, reads what has arrived and runs the replies and signal handlers.
//! Handlers run on the caller's thread, from inside `on_poll`.
//!
//! Input is untrusted. Every length, nesting depth, array size and value count is bounded (the
//! `max_*` constants are below the specification's limits), every string is checked for UTF-8 and
//! NUL, and any violation is an error. A malformed message fails the connection, as the
//! specification requires.

const std = @import("std");
const linux = std.os.linux;

/// Largest message accepted, header and body together. The specification allows 128 MiB.
pub const max_message_bytes: usize = 8 * 1024 * 1024;
/// Deepest nesting of arrays, structs, dict entries and variants.
pub const max_depth: usize = 32;
/// Longest signature (the specification's limit, which is also the one the wire format enforces).
pub const max_signature_bytes: usize = 255;
/// Most items one array may hold when decoded.
pub const max_array_items: usize = 1 << 16;
/// Most values one message may decode to, which bounds the memory a message can take.
pub const max_values_per_message: usize = 1 << 18;
/// Longest line during authentication.
pub const max_auth_line_bytes: usize = 1024;
/// Most method calls waiting for a reply at once.
pub const max_pending_calls: usize = 256;
/// Most signal handlers on one connection.
pub const max_listeners: usize = 8;

pub const bus_name = "org.freedesktop.DBus";
pub const bus_path = "/org/freedesktop/DBus";
pub const bus_interface = "org.freedesktop.DBus";

pub const Error = error{
    /// The bytes do not follow the wire format.
    Malformed,
    /// The bytes end before the message says they should.
    Truncated,
    /// A length, a count or the whole message is over its limit.
    TooLarge,
    /// Containers nest deeper than `max_depth`.
    TooDeep,
    /// A signature is not a valid sequence of complete types.
    BadSignature,
    /// A value this client cannot carry, such as a Unix file descriptor.
    Unsupported,
    /// The address is not a usable `unix:` address.
    BadAddress,
    ConnectFailed,
    AuthFailed,
    /// The peer closed the connection, or the connection failed earlier.
    Disconnected,
    IoFailed,
    TooManyPending,
    TooManyListeners,
} || std.mem.Allocator.Error;

/// The message type byte. Values this client does not know are kept and then ignored, as the
/// specification asks.
pub const Kind = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
    _,
};

pub const flag_no_reply_expected: u8 = 0x1;
pub const flag_no_auto_start: u8 = 0x2;

/// A value of the wire format. Strings and arrays point into the arena that decoded them.
pub const Value = union(enum) {
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    /// `element` is the signature of the items; `items` may be empty.
    array: Array,
    structure: []const Value,
    dict_entry: DictEntry,
    variant: Variant,

    pub const Array = struct {
        element: []const u8,
        items: []const Value,
    };
    pub const DictEntry = struct {
        key: *const Value,
        value: *const Value,
    };
    pub const Variant = struct {
        signature: []const u8,
        value: *const Value,
    };
};

/// The fixed and header fields of a message.
pub const Header = struct {
    kind: Kind,
    flags: u8 = 0,
    serial: u32 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    /// The body signature. Empty when the body is empty.
    signature: []const u8 = "",
};

/// A decoded message. Everything it refers to lives in the arena passed to `parse`.
pub const Message = struct {
    header: Header,
    body: []const Value,
};

// ---------------------------------------------------------------------------------------------
// Signatures

fn alignment_of(code: u8) usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

fn is_basic(code: u8) bool {
    return switch (code) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h' => true,
        else => false,
    };
}

fn align_up(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

/// The length of the complete type at the start of `sig`. `dict_ok` is true only directly inside
/// an array, the one place a dict entry may appear.
fn type_len(sig: []const u8, depth: usize, dict_ok: bool) Error!usize {
    if (depth > max_depth) return error.TooDeep;
    if (sig.len == 0) return error.BadSignature;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return 1,
        'a' => {
            if (sig.len < 2) return error.BadSignature;
            return 1 + try type_len(sig[1..], depth + 1, sig[1] == '{');
        },
        '(' => {
            var i: usize = 1;
            while (i < sig.len and sig[i] != ')') i += try type_len(sig[i..], depth + 1, false);
            if (i >= sig.len or i == 1) return error.BadSignature;
            return i + 1;
        },
        '{' => {
            if (!dict_ok or sig.len < 2 or !is_basic(sig[1])) return error.BadSignature;
            const close = 2 + try type_len(sig[2..], depth + 1, false);
            if (close >= sig.len or sig[close] != '}') return error.BadSignature;
            return close + 1;
        },
        else => return error.BadSignature,
    }
}

/// Checks that `sig` is a sequence of complete types, at most `max_signature_bytes` long.
pub fn validate_signature(sig: []const u8) Error!void {
    if (sig.len > max_signature_bytes) return error.BadSignature;
    var i: usize = 0;
    while (i < sig.len) i += try type_len(sig[i..], 0, false);
}

/// Checks that `sig` is exactly one complete type (what a variant carries).
fn validate_single(sig: []const u8) Error!void {
    if (sig.len == 0 or sig.len > max_signature_bytes) return error.BadSignature;
    if ((try type_len(sig, 0, false)) != sig.len) return error.BadSignature;
}

/// Object paths: `/`, or `/` separated non-empty elements of `[A-Za-z0-9_]`, with no trailing `/`.
pub fn valid_object_path(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (path.len == 1) return true;
    var after_slash = true;
    for (path[1..]) |c| {
        if (c == '/') {
            if (after_slash) return false;
            after_slash = true;
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            after_slash = false;
        } else {
            return false;
        }
    }
    return !after_slash;
}

// ---------------------------------------------------------------------------------------------
// Decoding

fn read_u32(bytes: []const u8, big: bool) u32 {
    return std.mem.readInt(u32, bytes[0..4], if (big) .big else .little);
}

fn byte_order(b: u8) Error!bool {
    return switch (b) {
        'l' => false,
        'B' => true,
        else => error.Malformed,
    };
}

/// The number of bytes of the message that starts at `prefix[0]`, from its fixed header. Returns
/// `error.Truncated` while the fixed header itself is incomplete, so a reader knows to wait.
pub fn frame_length(prefix: []const u8) Error!usize {
    if (prefix.len < 16) return error.Truncated;
    const big = try byte_order(prefix[0]);
    if (prefix[3] != 1) return error.Malformed;
    const body_len = read_u32(prefix[4..8], big);
    const fields_len = read_u32(prefix[12..16], big);
    if (body_len > max_message_bytes or fields_len > max_message_bytes) return error.TooLarge;
    // The fixed part is 16 bytes, a multiple of 8, so the body starts after the padded fields.
    const body_start = 16 + align_up(fields_len, 8);
    const total = body_start + body_len;
    if (total > max_message_bytes) return error.TooLarge;
    return total;
}

const Reader = struct {
    data: []const u8,
    pos: usize,
    /// Reads stop here: the end of the message, or of the array being read.
    end: usize,
    big: bool,
    arena: std.mem.Allocator,
    values_left: usize,

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.end - self.pos) return error.Truncated;
        const s = self.data[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn align_to(self: *Reader, a: usize) Error!void {
        const next = align_up(self.pos, a);
        if (next > self.end) return error.Truncated;
        self.pos = next;
    }

    fn u8_(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn uint(self: *Reader, comptime T: type) Error!T {
        try self.align_to(@sizeOf(T));
        const b: *const [@sizeOf(T)]u8 = (try self.take(@sizeOf(T)))[0..@sizeOf(T)];
        return std.mem.readInt(T, b, if (self.big) .big else .little);
    }

    fn spend(self: *Reader) Error!void {
        if (self.values_left == 0) return error.TooLarge;
        self.values_left -= 1;
    }

    fn read_string(self: *Reader) Error![]const u8 {
        const len = try self.uint(u32);
        if (len > max_message_bytes) return error.TooLarge;
        const s = try self.take(len);
        if ((try self.u8_()) != 0) return error.Malformed;
        if (!std.unicode.utf8ValidateSlice(s) or std.mem.indexOfScalar(u8, s, 0) != null) {
            return error.Malformed;
        }
        return s;
    }

    fn read_object_path(self: *Reader) Error![]const u8 {
        const s = try self.read_string();
        if (!valid_object_path(s)) return error.Malformed;
        return s;
    }

    fn read_signature(self: *Reader) Error![]const u8 {
        const len = try self.u8_();
        const s = try self.take(len);
        if ((try self.u8_()) != 0) return error.Malformed;
        try validate_signature(s);
        return s;
    }

    /// Reads one value whose type is `sig`, which is exactly one complete type.
    fn read_value(self: *Reader, sig: []const u8, depth: usize) Error!Value {
        if (depth > max_depth) return error.TooDeep;
        if (sig.len == 0) return error.BadSignature;
        try self.spend();
        return switch (sig[0]) {
            'y' => .{ .byte = try self.u8_() },
            'b' => blk: {
                const v = try self.uint(u32);
                if (v > 1) return error.Malformed;
                break :blk .{ .boolean = v == 1 };
            },
            'n' => .{ .int16 = @bitCast(try self.uint(u16)) },
            'q' => .{ .uint16 = try self.uint(u16) },
            'i' => .{ .int32 = @bitCast(try self.uint(u32)) },
            'u' => .{ .uint32 = try self.uint(u32) },
            'x' => .{ .int64 = @bitCast(try self.uint(u64)) },
            't' => .{ .uint64 = try self.uint(u64) },
            'd' => .{ .double = @bitCast(try self.uint(u64)) },
            's' => .{ .string = try self.read_string() },
            'o' => .{ .object_path = try self.read_object_path() },
            'g' => .{ .signature = try self.read_signature() },
            'h' => error.Unsupported,
            'v' => try self.read_variant(depth),
            'a' => try self.read_array(sig, depth),
            '(' => try self.read_struct(sig, depth),
            '{' => try self.read_dict_entry(sig, depth),
            else => error.BadSignature,
        };
    }

    fn read_variant(self: *Reader, depth: usize) Error!Value {
        const sig = try self.read_signature();
        try validate_single(sig);
        const inner = try self.arena.create(Value);
        inner.* = try self.read_value(sig, depth + 1);
        return .{ .variant = .{ .signature = sig, .value = inner } };
    }

    fn read_array(self: *Reader, sig: []const u8, depth: usize) Error!Value {
        const element = sig[1..];
        const len = try self.uint(u32);
        if (len > max_message_bytes) return error.TooLarge;
        // The padding before the first element is not part of the length.
        try self.align_to(alignment_of(element[0]));
        if (len > self.end - self.pos) return error.Truncated;
        const array_end = self.pos + len;
        const saved_end = self.end;
        self.end = array_end;
        defer self.end = saved_end;

        var items: std.ArrayList(Value) = .empty;
        while (self.pos < array_end) {
            if (items.items.len >= max_array_items) return error.TooLarge;
            try items.append(self.arena, try self.read_value(element, depth + 1));
        }
        return .{ .array = .{ .element = element, .items = try items.toOwnedSlice(self.arena) } };
    }

    fn read_struct(self: *Reader, sig: []const u8, depth: usize) Error!Value {
        try self.align_to(8);
        const inner = sig[1 .. sig.len - 1];
        var fields: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (i < inner.len) {
            const n = try type_len(inner[i..], depth + 1, false);
            try fields.append(self.arena, try self.read_value(inner[i .. i + n], depth + 1));
            i += n;
        }
        return .{ .structure = try fields.toOwnedSlice(self.arena) };
    }

    fn read_dict_entry(self: *Reader, sig: []const u8, depth: usize) Error!Value {
        try self.align_to(8);
        const key = try self.arena.create(Value);
        key.* = try self.read_value(sig[1..2], depth + 1);
        const value = try self.arena.create(Value);
        value.* = try self.read_value(sig[2 .. sig.len - 1], depth + 1);
        return .{ .dict_entry = .{ .key = key, .value = value } };
    }

    /// Reads a sequence of complete types, as the body of a message is.
    fn read_all(self: *Reader, sig: []const u8) Error![]const Value {
        var values: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (i < sig.len) {
            const n = try type_len(sig[i..], 0, false);
            try values.append(self.arena, try self.read_value(sig[i .. i + n], 0));
            i += n;
        }
        return values.toOwnedSlice(self.arena);
    }
};

fn payload(v: Value.Variant, comptime tag: std.meta.Tag(Value)) Error!@FieldType(Value, @tagName(tag)) {
    return switch (v.value.*) {
        tag => |p| p,
        else => error.Malformed,
    };
}

fn header_from_fields(header: *Header, fields: Value) Error!void {
    var seen = std.mem.zeroes([10]bool);
    for (fields.array.items) |item| {
        const pair = item.structure;
        const code = pair[0].byte;
        const v = pair[1].variant;
        const expect: []const u8 = switch (code) {
            0 => return error.Malformed,
            1 => "o",
            2, 3, 4, 6, 7 => "s",
            5, 9 => "u",
            8 => "g",
            else => continue, // unknown fields are skipped
        };
        if (!std.mem.eql(u8, v.signature, expect)) return error.Malformed;
        if (seen[code]) return error.Malformed;
        seen[code] = true;
        switch (code) {
            1 => header.path = try payload(v, .object_path),
            2 => header.interface = try payload(v, .string),
            3 => header.member = try payload(v, .string),
            4 => header.error_name = try payload(v, .string),
            5 => header.reply_serial = try payload(v, .uint32),
            6 => header.destination = try payload(v, .string),
            7 => header.sender = try payload(v, .string),
            8 => header.signature = try payload(v, .signature),
            9 => if ((try payload(v, .uint32)) != 0) return error.Unsupported,
            else => unreachable,
        }
    }
}

fn check_required(header: Header) Error!void {
    switch (header.kind) {
        .method_call => if (header.path == null or header.member == null) return error.Malformed,
        .signal => if (header.path == null or header.interface == null or header.member == null) {
            return error.Malformed;
        },
        .error_reply => if (header.error_name == null or header.reply_serial == null) {
            return error.Malformed;
        },
        .method_return => if (header.reply_serial == null) return error.Malformed,
        _ => {},
    }
}

/// Decodes exactly one message: `bytes` must be the whole message. The message is copied into
/// `arena` first, so `bytes` may be reused and the result stays valid until the arena is freed.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!Message {
    const total = try frame_length(bytes);
    if (bytes.len < total) return error.Truncated;
    if (bytes.len > total) return error.Malformed;
    const owned = try arena.dupe(u8, bytes);

    const big = try byte_order(owned[0]);
    if (owned[1] == 0) return error.Malformed;
    const serial = read_u32(owned[8..12], big);
    if (serial == 0) return error.Malformed;
    const body_len = read_u32(owned[4..8], big);
    const body_start = total - body_len;

    var r = Reader{
        .data = owned,
        .pos = 12,
        .end = body_start,
        .big = big,
        .arena = arena,
        .values_left = max_values_per_message,
    };
    const fields = try r.read_value("a(yv)", 0);
    var header = Header{ .kind = @enumFromInt(owned[1]), .flags = owned[2], .serial = serial };
    try header_from_fields(&header, fields);
    try check_required(header);

    r.pos = body_start;
    r.end = owned.len;
    const body = try r.read_all(header.signature);
    if (r.pos != owned.len) return error.Malformed;
    return .{ .header = header, .body = body };
}

// ---------------------------------------------------------------------------------------------
// Encoding

/// Builds a message body (or any sequence of values) in the wire format. Everything is written
/// little-endian. Alignment is measured from the start of the buffer, so a body encoded here can be
/// appended to a message whose body starts on an 8-byte boundary, which `encode` guarantees.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    frames: [max_depth]Frame = undefined,
    depth: usize = 0,

    const Container = enum { array, structure, dict_entry, variant };
    const Frame = struct {
        kind: Container,
        /// For arrays: where the length goes, and where the data starts.
        len_at: usize = 0,
        start: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn written(self: *const Encoder) []const u8 {
        return self.bytes.items;
    }

    pub fn pad(self: *Encoder, a: usize) Error!void {
        while (self.bytes.items.len % a != 0) try self.bytes.append(self.allocator, 0);
    }

    fn put(self: *Encoder, comptime T: type, v: T) Error!void {
        try self.pad(@sizeOf(T));
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try self.bytes.appendSlice(self.allocator, &buf);
    }

    fn push(self: *Encoder, kind: Container, len_at: usize, start: usize) Error!void {
        if (self.depth == max_depth) return error.TooDeep;
        self.frames[self.depth] = .{ .kind = kind, .len_at = len_at, .start = start };
        self.depth += 1;
    }

    fn pop(self: *Encoder, kind: Container) Error!Frame {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != kind) return error.Malformed;
        self.depth -= 1;
        return self.frames[self.depth];
    }

    pub fn byte(self: *Encoder, v: u8) Error!void {
        try self.bytes.append(self.allocator, v);
    }

    pub fn boolean(self: *Encoder, v: bool) Error!void {
        try self.put(u32, @intFromBool(v));
    }

    pub fn int16(self: *Encoder, v: i16) Error!void {
        try self.put(i16, v);
    }

    pub fn uint16(self: *Encoder, v: u16) Error!void {
        try self.put(u16, v);
    }

    pub fn int32(self: *Encoder, v: i32) Error!void {
        try self.put(i32, v);
    }

    pub fn uint32(self: *Encoder, v: u32) Error!void {
        try self.put(u32, v);
    }

    pub fn int64(self: *Encoder, v: i64) Error!void {
        try self.put(i64, v);
    }

    pub fn uint64(self: *Encoder, v: u64) Error!void {
        try self.put(u64, v);
    }

    pub fn double(self: *Encoder, v: f64) Error!void {
        try self.put(u64, @bitCast(v));
    }

    /// A string: `u32` length, the bytes, a NUL. It must be UTF-8 without NUL.
    pub fn string(self: *Encoder, s: []const u8) Error!void {
        if (s.len > max_message_bytes) return error.TooLarge;
        if (std.mem.indexOfScalar(u8, s, 0) != null or !std.unicode.utf8ValidateSlice(s)) {
            return error.Malformed;
        }
        try self.put(u32, @intCast(s.len));
        try self.bytes.appendSlice(self.allocator, s);
        try self.bytes.append(self.allocator, 0);
    }

    pub fn object_path(self: *Encoder, path: []const u8) Error!void {
        if (!valid_object_path(path)) return error.Malformed;
        try self.string(path);
    }

    /// A signature: `u8` length, the bytes, a NUL.
    pub fn signature(self: *Encoder, sig: []const u8) Error!void {
        try validate_signature(sig);
        try self.byte(@intCast(sig.len));
        try self.bytes.appendSlice(self.allocator, sig);
        try self.bytes.append(self.allocator, 0);
    }

    /// Opens an array whose items have the type `element`. Close it with `end_array`.
    pub fn begin_array(self: *Encoder, element: []const u8) Error!void {
        try validate_single_or_dict(element);
        try self.pad(4);
        const len_at = self.bytes.items.len;
        try self.put(u32, 0);
        try self.pad(alignment_of(element[0]));
        try self.push(.array, len_at, self.bytes.items.len);
    }

    pub fn end_array(self: *Encoder) Error!void {
        const frame = try self.pop(.array);
        const len = self.bytes.items.len - frame.start;
        if (len > max_message_bytes) return error.TooLarge;
        std.mem.writeInt(u32, self.bytes.items[frame.len_at..][0..4], @intCast(len), .little);
    }

    pub fn begin_struct(self: *Encoder) Error!void {
        try self.pad(8);
        try self.push(.structure, 0, 0);
    }

    pub fn end_struct(self: *Encoder) Error!void {
        _ = try self.pop(.structure);
    }

    pub fn begin_dict_entry(self: *Encoder) Error!void {
        try self.pad(8);
        try self.push(.dict_entry, 0, 0);
    }

    pub fn end_dict_entry(self: *Encoder) Error!void {
        _ = try self.pop(.dict_entry);
    }

    /// Opens a variant holding a value of type `sig`. Close it with `end_variant`.
    pub fn begin_variant(self: *Encoder, sig: []const u8) Error!void {
        try validate_single(sig);
        try self.signature(sig);
        try self.push(.variant, 0, 0);
    }

    pub fn end_variant(self: *Encoder) Error!void {
        _ = try self.pop(.variant);
    }

    /// Writes a whole value. Arrays, structs, dict entries and variants are written recursively.
    pub fn value(self: *Encoder, v: Value) Error!void {
        switch (v) {
            .byte => |x| try self.byte(x),
            .boolean => |x| try self.boolean(x),
            .int16 => |x| try self.int16(x),
            .uint16 => |x| try self.uint16(x),
            .int32 => |x| try self.int32(x),
            .uint32 => |x| try self.uint32(x),
            .int64 => |x| try self.int64(x),
            .uint64 => |x| try self.uint64(x),
            .double => |x| try self.double(x),
            .string => |s| try self.string(s),
            .object_path => |s| try self.object_path(s),
            .signature => |s| try self.signature(s),
            .array => |a| {
                try self.begin_array(a.element);
                for (a.items) |item| try self.value(item);
                try self.end_array();
            },
            .structure => |fields| {
                try self.begin_struct();
                for (fields) |field| try self.value(field);
                try self.end_struct();
            },
            .dict_entry => |e| {
                try self.begin_dict_entry();
                try self.value(e.key.*);
                try self.value(e.value.*);
                try self.end_dict_entry();
            },
            .variant => |var_| {
                try self.begin_variant(var_.signature);
                try self.value(var_.value.*);
                try self.end_variant();
            },
        }
    }
};

/// An array element may be a dict entry, which no other type may be.
fn validate_single_or_dict(element: []const u8) Error!void {
    if (element.len == 0 or element.len > max_signature_bytes) return error.BadSignature;
    if ((try type_len(element, 0, true)) != element.len) return error.BadSignature;
}

fn put_field(enc: *Encoder, code: u8, sig: []const u8, v: Value) Error!void {
    try enc.begin_struct();
    try enc.byte(code);
    try enc.begin_variant(sig);
    try enc.value(v);
    try enc.end_variant();
    try enc.end_struct();
}

/// Builds one whole message: the fixed header, the header fields and the body, which must already be
/// encoded for `header.signature` (see `Encoder`). The caller frees the result.
pub fn encode(allocator: std.mem.Allocator, header: Header, body: []const u8) Error![]u8 {
    if (header.serial == 0) return error.Malformed;
    switch (header.kind) {
        .method_call => if (header.path == null or header.member == null) return error.Malformed,
        .signal => if (header.path == null or header.interface == null or header.member == null) {
            return error.Malformed;
        },
        .error_reply => if (header.error_name == null or header.reply_serial == null) {
            return error.Malformed;
        },
        .method_return => if (header.reply_serial == null) return error.Malformed,
        _ => return error.Malformed,
    }
    if (body.len > max_message_bytes) return error.TooLarge;
    try validate_signature(header.signature);

    var enc = Encoder.init(allocator);
    errdefer enc.deinit();
    // Endianness, type, flags, version, body length (patched below), serial.
    try enc.bytes.appendSlice(allocator, &.{ 'l', @intFromEnum(header.kind), header.flags, 1, 0, 0, 0, 0 });
    try enc.put(u32, header.serial);

    try enc.begin_array("(yv)");
    if (header.path) |v| try put_field(&enc, 1, "o", .{ .object_path = v });
    if (header.destination) |v| try put_field(&enc, 6, "s", .{ .string = v });
    if (header.interface) |v| try put_field(&enc, 2, "s", .{ .string = v });
    if (header.member) |v| try put_field(&enc, 3, "s", .{ .string = v });
    if (header.error_name) |v| try put_field(&enc, 4, "s", .{ .string = v });
    if (header.reply_serial) |v| try put_field(&enc, 5, "u", .{ .uint32 = v });
    if (header.sender) |v| try put_field(&enc, 7, "s", .{ .string = v });
    if (header.signature.len > 0) try put_field(&enc, 8, "g", .{ .signature = header.signature });
    try enc.end_array();

    try enc.pad(8);
    if (enc.bytes.items.len + body.len > max_message_bytes) return error.TooLarge;
    try enc.bytes.appendSlice(allocator, body);
    std.mem.writeInt(u32, enc.bytes.items[4..8], @intCast(body.len), .little);
    return enc.bytes.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------------------------
// Addresses

pub const UnixAddress = struct {
    path: []const u8,
    /// A Linux abstract socket name (no file in the file system).
    is_abstract: bool,
};

/// sun_path is 108 bytes; one more is the NUL, or the leading NUL of an abstract name.
const max_path_bytes = 107;

fn hex_digit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decodes the `%XX` escapes of an address value into `out`.
fn unescape(raw: []const u8, out: []u8) Error![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (n >= out.len) return error.BadAddress;
        if (raw[i] == '%') {
            if (i + 2 >= raw.len) return error.BadAddress;
            const hi = hex_digit(raw[i + 1]) orelse return error.BadAddress;
            const lo = hex_digit(raw[i + 2]) orelse return error.BadAddress;
            out[n] = hi << 4 | lo;
            i += 3;
        } else {
            out[n] = raw[i];
            i += 1;
        }
        n += 1;
    }
    return out[0..n];
}

/// Finds the first `unix:` transport in a `DBUS_SESSION_BUS_ADDRESS` style list (`;` separated,
/// `key=value` pairs after `unix:` separated by `,`). `buf` holds the decoded path.
pub fn find_unix_address(list: []const u8, buf: []u8) Error!UnixAddress {
    var entries = std.mem.splitScalar(u8, list, ';');
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "unix:")) continue;
        var pairs = std.mem.splitScalar(u8, entry["unix:".len..], ',');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const is_abstract = std.mem.eql(u8, key, "abstract");
            if (!is_abstract and !std.mem.eql(u8, key, "path")) continue;
            const path = try unescape(pair[eq + 1 ..], buf);
            if (path.len == 0 or path.len > max_path_bytes) return error.BadAddress;
            return .{ .path = path, .is_abstract = is_abstract };
        }
    }
    return error.BadAddress;
}

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

fn open_socket(addr: UnixAddress) Error!c_int {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
    const fd: c_int = @intCast(rc);
    errdefer _ = linux.close(fd);

    // A full listen queue makes connect wait. The bus is local, so one second is generous, and it
    // is the only time this client can block.
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));

    var sa = SockaddrUn{ .family = linux.AF.UNIX, .path = std.mem.zeroes([108]u8) };
    const name_start: usize = if (addr.is_abstract) 1 else 0;
    @memcpy(sa.path[name_start..][0..addr.path.len], addr.path);
    // Abstract names have no terminating NUL, which is what makes their length exact.
    const name_len = if (addr.is_abstract) 1 + addr.path.len else addr.path.len + 1;
    const len: u32 = @intCast(@offsetOf(SockaddrUn, "path") + name_len);
    if (linux.errno(linux.connect(fd, @ptrCast(&sa), len)) != .SUCCESS) return error.ConnectFailed;

    const o_nonblock: usize = 0o4000;
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.ConnectFailed;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | o_nonblock)) != .SUCCESS) {
        return error.ConnectFailed;
    }
    return fd;
}

// ---------------------------------------------------------------------------------------------
// Connection

/// A callback for a reply or a signal. Create one with `Handler.of`.
pub const Handler = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, *const Message) void,

    /// `ctx` must be a pointer; `f` receives it back with the message.
    pub fn of(ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Message) void) Handler {
        const Ptr = @TypeOf(ctx);
        comptime if (@typeInfo(Ptr) != .pointer) @compileError("a Handler context must be a pointer");
        const Thunk = struct {
            fn call(raw: *anyopaque, msg: *const Message) void {
                f(@ptrCast(@alignCast(raw)), msg);
            }
        };
        return .{ .ctx = @ptrCast(ctx), .func = Thunk.call };
    }

    fn invoke(self: Handler, msg: *const Message) void {
        self.func(self.ctx, msg);
    }
};

const auth_ok_prefix = "OK ";

pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    state: State,
    /// Why the connection failed, once it has.
    failure: ?Error = null,
    /// Bytes waiting to be written, from `out_pos` on.
    out: std.ArrayList(u8) = .empty,
    out_pos: usize = 0,
    /// Messages sent before authentication finished. They follow BEGIN.
    queued: std.ArrayList(u8) = .empty,
    /// Bytes read and not yet parsed, from `in_pos` on.
    in: std.ArrayList(u8) = .empty,
    in_pos: usize = 0,
    /// Serial 1 is reserved for Hello, which is sent first.
    next_serial: u32 = 1,
    pending: std.AutoHashMapUnmanaged(u32, Handler) = .empty,
    listeners: [max_listeners]Handler = undefined,
    listener_count: usize = 0,

    pub const State = enum { authenticating, ready, failed };

    /// Connects to the first `unix:` address in `addresses` and starts the handshake. Returns at
    /// once; the handshake finishes as the socket becomes ready in `on_poll`.
    pub fn connect(allocator: std.mem.Allocator, addresses: []const u8) Error!*Connection {
        var buf: [256]u8 = undefined;
        const addr = try find_unix_address(addresses, &buf);
        const fd = try open_socket(addr);
        const self = allocator.create(Connection) catch |err| {
            _ = linux.close(fd);
            return err;
        };
        self.* = .{ .allocator = allocator, .fd = fd, .state = .authenticating };
        // From here on `deinit` owns the socket and the allocation.
        errdefer self.deinit();

        var uid_buf: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()}) catch unreachable;
        try self.out.appendSlice(allocator, "\x00AUTH EXTERNAL ");
        for (uid) |c| {
            try self.out.append(allocator, "0123456789abcdef"[c >> 4]);
            try self.out.append(allocator, "0123456789abcdef"[c & 15]);
        }
        try self.out.appendSlice(allocator, "\r\n");

        _ = try self.call(.{ .kind = .method_call, .destination = bus_name, .path = bus_path, .interface = bus_interface, .member = "Hello" }, &.{}, null);
        self.flush();
        return self;
    }

    /// Connects to the session bus named by DBUS_SESSION_BUS_ADDRESS, or to the default socket under
    /// XDG_RUNTIME_DIR when that is unset.
    pub fn connect_session(allocator: std.mem.Allocator) Error!*Connection {
        if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS")) |v| return connect(allocator, std.mem.span(v));
        const runtime = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.BadAddress;
        var buf: [512]u8 = undefined;
        const address = std.fmt.bufPrint(&buf, "unix:path={s}/bus", .{std.mem.span(runtime)}) catch return error.BadAddress;
        return connect(allocator, address);
    }

    pub fn deinit(self: *Connection) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.out.deinit(self.allocator);
        self.queued.deinit(self.allocator);
        self.in.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn socket(self: *const Connection) c_int {
        return self.fd;
    }

    /// The poll events the connection needs now.
    pub fn poll_events(self: *const Connection) i16 {
        if (self.state == .failed) return 0;
        var events: i16 = std.posix.POLL.IN;
        if (self.out_pos < self.out.items.len) events |= std.posix.POLL.OUT;
        return events;
    }

    pub fn is_failed(self: *const Connection) bool {
        return self.state == .failed;
    }

    /// Handles the events `poll` reported for `socket()`.
    pub fn on_poll(self: *Connection, revents: i16) void {
        if (self.state == .failed) return;
        if ((revents & std.posix.POLL.NVAL) != 0) return self.fail(error.Disconnected);
        if ((revents & std.posix.POLL.OUT) != 0) self.flush();
        const readable = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP;
        if (self.state != .failed and (revents & readable) != 0) {
            self.read_input();
        }
    }

    /// Sends a method call (or any message) and returns its serial. `reply` runs when the matching
    /// method return or error arrives. Pass null for `reply` when no reply is wanted.
    pub fn call(self: *Connection, header: Header, body: []const u8, reply: ?Handler) Error!u32 {
        if (self.state == .failed) return error.Disconnected;
        var h = header;
        h.serial = self.next_serial;
        const bytes = try encode(self.allocator, h, body);
        defer self.allocator.free(bytes);

        if (reply) |r| {
            if (self.pending.count() >= max_pending_calls) return error.TooManyPending;
            try self.pending.put(self.allocator, h.serial, r);
        }
        errdefer if (reply != null) {
            _ = self.pending.remove(h.serial);
        };
        if (self.state == .ready) {
            try self.out.appendSlice(self.allocator, bytes);
        } else {
            try self.queued.appendSlice(self.allocator, bytes);
        }
        self.next_serial = if (self.next_serial == std.math.maxInt(u32)) 2 else self.next_serial + 1;
        if (self.state == .ready) self.flush();
        return h.serial;
    }

    /// Runs `handler` for every signal that reaches the connection. Filter by interface, member and
    /// path in the handler. Signals only arrive for the match rules added with `add_match`.
    pub fn add_listener(self: *Connection, handler: Handler) Error!void {
        if (self.listener_count == max_listeners) return error.TooManyListeners;
        self.listeners[self.listener_count] = handler;
        self.listener_count += 1;
    }

    /// Asks the bus to send the signals matching `rule` (for example
    /// `type='signal',interface='x.y'`).
    pub fn add_match(self: *Connection, rule: []const u8) Error!void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();
        try enc.string(rule);
        _ = try self.call(.{
            .kind = .method_call,
            .destination = bus_name,
            .path = bus_path,
            .interface = bus_interface,
            .member = "AddMatch",
            .signature = "s",
        }, enc.written(), null);
        self.flush();
    }

    fn fail(self: *Connection, err: Error) void {
        self.state = .failed;
        self.failure = err;
    }

    fn flush(self: *Connection) void {
        while (self.out_pos < self.out.items.len) {
            const rest = self.out.items[self.out_pos..];
            // Not `write`: on a socket whose peer has gone, that raises SIGPIPE and kills the app.
            const rc = linux.sendto(self.fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => self.out_pos += rc,
                .AGAIN => return,
                .INTR => continue,
                else => return self.fail(error.IoFailed),
            }
        }
        self.out.clearRetainingCapacity();
        self.out_pos = 0;
    }

    fn read_input(self: *Connection) void {
        while (self.state != .failed) {
            self.in.ensureUnusedCapacity(self.allocator, 4096) catch return self.fail(error.OutOfMemory);
            const spare = self.in.unusedCapacitySlice();
            const rc = linux.read(self.fd, spare.ptr, spare.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return self.fail(error.Disconnected);
                    self.in.items.len += rc;
                    self.process_input();
                },
                .AGAIN => return,
                .INTR => continue,
                else => return self.fail(error.IoFailed),
            }
        }
    }

    /// Consumes whatever complete lines or messages are buffered.
    fn process_input(self: *Connection) void {
        while (self.state != .failed) {
            const rest = self.in.items[self.in_pos..];
            if (self.state == .authenticating) {
                const eol = std.mem.indexOf(u8, rest, "\r\n") orelse {
                    if (rest.len > max_auth_line_bytes) self.fail(error.AuthFailed);
                    break;
                };
                const line = rest[0..eol];
                self.in_pos += eol + 2;
                if (!std.mem.startsWith(u8, line, auth_ok_prefix)) return self.fail(error.AuthFailed);
                self.out.appendSlice(self.allocator, "BEGIN\r\n") catch return self.fail(error.OutOfMemory);
                self.out.appendSlice(self.allocator, self.queued.items) catch return self.fail(error.OutOfMemory);
                self.queued.clearRetainingCapacity();
                self.state = .ready;
                self.flush();
            } else {
                const total = frame_length(rest) catch |err| switch (err) {
                    error.Truncated => break,
                    else => return self.fail(err),
                };
                if (rest.len < total) break;
                self.dispatch_frame(rest[0..total]);
                self.in_pos += total;
            }
        }
        self.compact_input();
    }

    fn compact_input(self: *Connection) void {
        if (self.in_pos == 0) return;
        const remaining = self.in.items.len - self.in_pos;
        std.mem.copyForwards(u8, self.in.items[0..remaining], self.in.items[self.in_pos..]);
        self.in.items.len = remaining;
        self.in_pos = 0;
    }

    fn dispatch_frame(self: *Connection, bytes: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const msg = parse(arena.allocator(), bytes) catch |err| return self.fail(err);
        self.dispatch(&msg);
    }

    fn dispatch(self: *Connection, msg: *const Message) void {
        switch (msg.header.kind) {
            .method_return, .error_reply => {
                const serial = msg.header.reply_serial orelse return;
                if (self.pending.fetchRemove(serial)) |entry| entry.value.invoke(msg);
            },
            .signal => {
                var i: usize = 0;
                while (i < self.listener_count) : (i += 1) self.listeners[i].invoke(msg);
            },
            .method_call => {
                // Nothing is exported here, so say so instead of leaving the caller waiting.
                if (msg.header.flags & flag_no_reply_expected != 0) return;
                const sender = msg.header.sender orelse return;
                self.send_unknown_method(sender, msg.header.serial);
            },
            _ => {},
        }
    }

    fn send_unknown_method(self: *Connection, destination: []const u8, serial: u32) void {
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();
        enc.string("Unknown method") catch return;
        const bytes = encode(self.allocator, .{
            .kind = .error_reply,
            .flags = flag_no_reply_expected,
            .serial = self.next_serial,
            .destination = destination,
            .error_name = "org.freedesktop.DBus.Error.UnknownMethod",
            .reply_serial = serial,
            .signature = "s",
        }, enc.written()) catch return;
        defer self.allocator.free(bytes);
        self.next_serial = if (self.next_serial == std.math.maxInt(u32)) 2 else self.next_serial + 1;
        self.out.appendSlice(self.allocator, bytes) catch return self.fail(error.OutOfMemory);
        self.flush();
    }
};

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "writing to a bus that has gone fails the connection instead of raising SIGPIPE" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)));
    _ = linux.close(fds[1]);
    const connection = try testing.allocator.create(Connection);
    connection.* = .{ .allocator = testing.allocator, .fd = fds[0], .state = .ready };
    defer connection.deinit();
    try connection.out.appendSlice(testing.allocator, "bytes for nobody");
    // With `write`, the test process dies here.
    connection.flush();
    try testing.expect(connection.is_failed());
}

fn unhex(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    var out: [hex.len / 2]u8 = undefined;
    for (&out, 0..) |*b, i| {
        b.* = (hex_digit(hex[2 * i]).? << 4) | hex_digit(hex[2 * i + 1]).?;
    }
    return out;
}

// Captured with dbus-monitor on a private session bus, from libdbus clients: the Notify call
// (sender field added by the bus), the bus's UnknownInterface reply to it, and a Mixed call with
// every kind of container.
const notify_call_hex = "6c0100016c000000030000009d00000001016f00150000002f6f72672f667265656465736b746f702f4442757300000006017300140000006f72672e667265656465736b746f702e4442757300000000020173001d0000006f72672e667265656465736b746f702e4e6f74696669636174696f6e7300000003017300060000004e6f746966790000080167000d73757373736173617b73767d6900000000000007017300040000003a312e3100000000030000007a756900030000000000000000000000050000005469746c6500000004000000426f6479000000002d0000000700000064656661756c74000700000064656661756c7400040000006f70656e00000000040000004f70656e000000000000000000000000ffffffff";
const unknown_iface_reply_hex = "6c0301013b000000060000007500000006017300040000003a312e3100000000040173002b0000006f72672e667265656465736b746f702e444275732e4572726f722e556e6b6e6f776e496e7465726661636500000000000501750005000000080167000173000007017300140000006f72672e667265656465736b746f702e4442757300000000360000006f72672e667265656465736b746f702e4442757320646f6573206e6f7420756e6465727374616e64206d657373616765204d6978656400";
const mixed_call_hex = "6c01000134000000050000008500000001016f00150000002f6f72672f667265656465736b746f702f4442757300000006017300140000006f72672e667265656465736b746f702e44427573000000000201730003000000782e79000000000003017300050000004d69786564000000080167000d7978646128797129617b73767d00000000000007017300040000003a312e31000000000100000000000000fbffffffffffffff000000000000f83f0400000000000000020003000c000000010000006b00016e00000900";

test "dbus: signatures" {
    try validate_signature("");
    try validate_signature("susssasa{sv}i");
    try validate_signature("a(yv)");
    try validate_signature("yxda(yq)a{sv}");
    try testing.expectError(error.BadSignature, validate_signature("("));
    try testing.expectError(error.BadSignature, validate_signature("()"));
    try testing.expectError(error.BadSignature, validate_signature("a"));
    try testing.expectError(error.BadSignature, validate_signature("{sv}"));
    try testing.expectError(error.BadSignature, validate_signature("{vs}"));
    try testing.expectError(error.BadSignature, validate_signature("(y"));
    try testing.expectError(error.BadSignature, validate_signature("z"));
    try testing.expectError(error.BadSignature, validate_signature("}"));
    var deep: [34]u8 = undefined;
    @memset(deep[0..33], 'a');
    deep[33] = 'y';
    try testing.expectError(error.TooDeep, validate_signature(&deep));
    try validate_signature(deep[1..]);
    var long: [256]u8 = undefined;
    @memset(&long, 'y');
    try testing.expectError(error.BadSignature, validate_signature(&long));
}

test "dbus: object paths" {
    try testing.expect(valid_object_path("/"));
    try testing.expect(valid_object_path("/org/freedesktop/Notifications"));
    try testing.expect(!valid_object_path(""));
    try testing.expect(!valid_object_path("org"));
    try testing.expect(!valid_object_path("/a/"));
    try testing.expect(!valid_object_path("/a//b"));
    try testing.expect(!valid_object_path("/a-b"));
}

test "dbus: addresses" {
    var buf: [256]u8 = undefined;
    const plain = try find_unix_address("unix:path=/run/user/1000/bus,guid=abc", &buf);
    try testing.expectEqualStrings("/run/user/1000/bus", plain.path);
    try testing.expect(!plain.is_abstract);

    const abstract = try find_unix_address("tcp:host=x,port=1;unix:abstract=zui%2Dtest", &buf);
    try testing.expectEqualStrings("zui-test", abstract.path);
    try testing.expect(abstract.is_abstract);

    try testing.expectError(error.BadAddress, find_unix_address("tcp:host=x", &buf));
    try testing.expectError(error.BadAddress, find_unix_address("unix:path=", &buf));
    try testing.expectError(error.BadAddress, find_unix_address("unix:path=/a%2", &buf));
    try testing.expectError(error.BadAddress, find_unix_address("unix:path=/a%zz", &buf));
    var short: [4]u8 = undefined;
    try testing.expectError(error.BadAddress, find_unix_address("unix:path=/a/long/path", &short));
    var too_long: [128]u8 = undefined;
    @memcpy(too_long[0..11], "unix:path=/");
    @memset(too_long[11..], 'a');
    try testing.expectError(error.BadAddress, find_unix_address(&too_long, &buf));
}

test "dbus: reference notify call decodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = unhex(notify_call_hex);
    const msg = try parse(arena.allocator(), &bytes);
    try testing.expectEqual(Kind.method_call, msg.header.kind);
    try testing.expectEqual(@as(u32, 3), msg.header.serial);
    try testing.expectEqualStrings("/org/freedesktop/DBus", msg.header.path.?);
    try testing.expectEqualStrings("org.freedesktop.DBus", msg.header.destination.?);
    try testing.expectEqualStrings("Notify", msg.header.member.?);
    try testing.expectEqualStrings(":1.1", msg.header.sender.?);
    try testing.expectEqualStrings("susssasa{sv}i", msg.header.signature);
    try testing.expectEqual(@as(usize, 8), msg.body.len);
    try testing.expectEqualStrings("zui", msg.body[0].string);
    try testing.expectEqual(@as(u32, 3), msg.body[1].uint32);
    try testing.expectEqualStrings("", msg.body[2].string);
    try testing.expectEqualStrings("Title", msg.body[3].string);
    try testing.expectEqualStrings("Body", msg.body[4].string);
    const actions = msg.body[5].array;
    try testing.expectEqualStrings("s", actions.element);
    try testing.expectEqual(@as(usize, 4), actions.items.len);
    try testing.expectEqualStrings("default", actions.items[0].string);
    try testing.expectEqualStrings("Open", actions.items[3].string);
    try testing.expectEqual(@as(usize, 0), msg.body[6].array.items.len);
    try testing.expectEqual(@as(i32, -1), msg.body[7].int32);
}

test "dbus: reference error reply and mixed call decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const err_bytes = unhex(unknown_iface_reply_hex);
    const err = try parse(arena.allocator(), &err_bytes);
    try testing.expectEqual(Kind.error_reply, err.header.kind);
    try testing.expectEqual(@as(u32, 6), err.header.serial);
    try testing.expectEqual(@as(u32, 5), err.header.reply_serial.?);
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownInterface", err.header.error_name.?);
    try testing.expectEqualStrings("org.freedesktop.DBus does not understand message Mixed", err.body[0].string);

    const mixed_bytes = unhex(mixed_call_hex);
    const mixed = try parse(arena.allocator(), &mixed_bytes);
    try testing.expectEqualStrings("yxda(yq)a{sv}", mixed.header.signature);
    try testing.expectEqual(@as(u8, 1), mixed.body[0].byte);
    try testing.expectEqual(@as(i64, -5), mixed.body[1].int64);
    try testing.expectEqual(@as(f64, 1.5), mixed.body[2].double);
    const pairs = mixed.body[3].array;
    try testing.expectEqualStrings("(yq)", pairs.element);
    try testing.expectEqual(@as(u8, 2), pairs.items[0].structure[0].byte);
    try testing.expectEqual(@as(u16, 3), pairs.items[0].structure[1].uint16);
    const dict = mixed.body[4].array;
    try testing.expectEqualStrings("{sv}", dict.element);
    try testing.expectEqualStrings("k", dict.items[0].dict_entry.key.string);
    try testing.expectEqual(@as(i16, 9), dict.items[0].dict_entry.value.variant.value.int16);
}

test "dbus: encoding reproduces the reference bodies byte for byte" {
    // The notify call: the body must match what libdbus put on the wire.
    const notify_bytes = unhex(notify_call_hex);
    const notify_body = reference_body(&notify_bytes);
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    try enc.string("zui");
    try enc.uint32(3);
    try enc.string("");
    try enc.string("Title");
    try enc.string("Body");
    try enc.begin_array("s");
    try enc.string("default");
    try enc.string("default");
    try enc.string("open");
    try enc.string("Open");
    try enc.end_array();
    try enc.begin_array("{sv}");
    try enc.end_array();
    try enc.int32(-1);
    try testing.expectEqualSlices(u8, notify_body, enc.written());

    // The mixed call: nested arrays, a struct, a dict with a variant.
    const mixed_bytes = unhex(mixed_call_hex);
    const mixed_body = reference_body(&mixed_bytes);
    var enc2 = Encoder.init(testing.allocator);
    defer enc2.deinit();
    try enc2.byte(1);
    try enc2.int64(-5);
    try enc2.double(1.5);
    try enc2.begin_array("(yq)");
    try enc2.begin_struct();
    try enc2.byte(2);
    try enc2.uint16(3);
    try enc2.end_struct();
    try enc2.end_array();
    try enc2.begin_array("{sv}");
    try enc2.begin_dict_entry();
    try enc2.string("k");
    try enc2.begin_variant("n");
    try enc2.int16(9);
    try enc2.end_variant();
    try enc2.end_dict_entry();
    try enc2.end_array();
    try testing.expectEqualSlices(u8, mixed_body, enc2.written());
}

/// The body of a whole reference message: the last `body_len` bytes.
fn reference_body(msg: []const u8) []const u8 {
    const body_len = std.mem.readInt(u32, msg[4..8], .little);
    return msg[msg.len - body_len ..];
}

test "dbus: encoded message parses back with the same fields" {
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    try enc.string("zui");
    try enc.uint32(7);
    const bytes = try encode(testing.allocator, .{
        .kind = .method_call,
        .serial = 9,
        .destination = "org.example",
        .path = "/org/example",
        .interface = "org.example.If",
        .member = "Do",
        .signature = "su",
    }, enc.written());
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = try parse(arena.allocator(), bytes);
    try testing.expectEqual(@as(u32, 9), msg.header.serial);
    try testing.expectEqualStrings("org.example", msg.header.destination.?);
    try testing.expectEqualStrings("org.example.If", msg.header.interface.?);
    try testing.expectEqualStrings("zui", msg.body[0].string);
    try testing.expectEqual(@as(u32, 7), msg.body[1].uint32);
}

test "dbus: every truncated prefix of a reference message is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const vectors = [_][]const u8{ &unhex(notify_call_hex), &unhex(unknown_iface_reply_hex), &unhex(mixed_call_hex) };
    for (vectors) |full| {
        var n: usize = 0;
        while (n < full.len) : (n += 1) {
            if (parse(arena.allocator(), full[0..n])) |_| {
                return error.TestUnexpectedResult;
            } else |_| {}
        }
        // The whole message parses; a message with one byte too many does not.
        _ = try parse(arena.allocator(), full);
        var extra: [400]u8 = undefined;
        @memcpy(extra[0..full.len], full);
        extra[full.len] = 0;
        try testing.expectError(error.Malformed, parse(arena.allocator(), extra[0 .. full.len + 1]));
    }
}

test "dbus: corrupted reference messages never panic or leak" {
    const vectors = [_][]const u8{ &unhex(notify_call_hex), &unhex(unknown_iface_reply_hex), &unhex(mixed_call_hex) };

    // Structural bytes. Each change must be rejected.
    for (vectors) |full| {
        var copy: [400]u8 = undefined;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Byte order, message type 0, version 2, zero serial.
        const structural = [_]struct { at: usize, value: u8 }{
            .{ .at = 0, .value = 'x' },
            .{ .at = 1, .value = 0 },
            .{ .at = 3, .value = 2 },
            .{ .at = 8, .value = 0 },
        };
        for (structural) |c| {
            @memcpy(copy[0..full.len], full);
            copy[c.at] = c.value;
            try testing.expect(std.meta.isError(parse(a, copy[0..full.len])));
        }
        // A body length one byte too large or too small.
        @memcpy(copy[0..full.len], full);
        copy[4] +%= 1;
        try testing.expect(std.meta.isError(parse(a, copy[0..full.len])));
        @memcpy(copy[0..full.len], full);
        copy[4] -%= 1;
        try testing.expect(std.meta.isError(parse(a, copy[0..full.len])));
    }

    // Random damage with a fixed seed: anything may happen but a panic or a leak. Most damage is
    // caught; the rest decodes to some other valid message.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var rejected: usize = 0;
    var iteration: usize = 0;
    while (iteration < 4000) : (iteration += 1) {
        const full = vectors[iteration % vectors.len];
        var copy: [400]u8 = undefined;
        @memcpy(copy[0..full.len], full);
        const hits = random.intRangeAtMost(usize, 1, 3);
        for (0..hits) |_| {
            const at = random.uintLessThan(usize, full.len);
            copy[at] = random.int(u8);
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        if (parse(arena.allocator(), copy[0..full.len])) |_| {} else |_| rejected += 1;
    }
    try testing.expect(rejected > 1000);
}

test "dbus: bounded values and depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A signature nested past the limit is refused before any value is read.
    var deep: [max_depth + 2]u8 = undefined;
    @memset(deep[0 .. max_depth + 1], 'a');
    deep[max_depth + 1] = 'y';
    try testing.expectError(error.TooDeep, validate_signature(deep[0..]));

    // An array whose declared length runs past the message is truncated, not read.
    const bytes = [_]u8{ 'l', 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0xff, 0xff, 0xff, 0x7f } ++ std.mem.zeroes([8]u8);
    try testing.expectError(error.TooLarge, parse(arena.allocator(), &bytes));
}

test "dbus: header rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A method call without a member is malformed.
    const bytes = try encode(testing.allocator, .{ .kind = .method_call, .serial = 1, .path = "/a", .member = "M" }, "");
    defer testing.allocator.free(bytes);
    _ = try parse(arena.allocator(), bytes);
    try testing.expectError(error.Malformed, encode(testing.allocator, .{ .kind = .method_call, .serial = 1, .path = "/a" }, ""));
    try testing.expectError(error.Malformed, encode(testing.allocator, .{ .kind = .signal, .serial = 1, .path = "/a", .member = "M" }, ""));
    try testing.expectError(error.Malformed, encode(testing.allocator, .{ .kind = .method_return, .serial = 0, .reply_serial = 1 }, ""));
}
