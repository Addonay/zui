//! Bounded, deterministic frame/event traces for headless tests.
//!
//! GPUI's test and profiler infrastructure makes scheduling and observed
//! frame behavior inspectable.  This module provides the renderer-neutral
//! part of that contract: callers record normalized events with an explicit
//! timestamp, while comparisons can ignore timing and compare only the
//! deterministic event sequence.
const std = @import("std");

pub const max_records: usize = 256;
pub const max_label_bytes: usize = 48;

pub const Kind = enum(u8) {
    frame_begin,
    event,
    layout,
    paint,
    present,
    frame_end,
    marker,
};

pub const Record = struct {
    timestamp_ns: u64 = 0,
    frame: u32 = 0,
    kind: Kind = .marker,
    code: u16 = 0,
    value: u64 = 0,
    aux: u64 = 0,
    label: [max_label_bytes]u8 = std.mem.zeroes([max_label_bytes]u8),
    label_len: u8 = 0,

    pub fn labelSlice(self: *const @This()) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const Trace = struct {
    records: [max_records]Record = undefined,
    len: usize = 0,
    dropped: u64 = 0,

    pub fn clear(self: *@This()) void {
        self.len = 0;
        self.dropped = 0;
    }

    /// Adds one normalized record. Labels are deliberately truncated at the
    /// fixed bound so a trace cannot grow because of user-provided text.
    pub fn append(self: *@This(), timestamp_ns: u64, frame: u32, kind: Kind, code: u16, value: u64, aux: u64, label: []const u8) bool {
        if (self.len >= self.records.len) {
            self.dropped += 1;
            return false;
        }
        const copied = @min(label.len, max_label_bytes);
        self.records[self.len] = .{
            .timestamp_ns = timestamp_ns,
            .frame = frame,
            .kind = kind,
            .code = code,
            .value = value,
            .aux = aux,
            .label = blk: {
                var bytes = std.mem.zeroes([max_label_bytes]u8);
                @memcpy(bytes[0..copied], label[0..copied]);
                break :blk bytes;
            },
            .label_len = @intCast(copied),
        };
        self.len += 1;
        return true;
    }

    pub fn frameBegin(self: *@This(), timestamp_ns: u64, frame: u32) bool {
        return self.append(timestamp_ns, frame, .frame_begin, 0, 0, 0, "");
    }

    pub fn frameEnd(self: *@This(), timestamp_ns: u64, frame: u32) bool {
        return self.append(timestamp_ns, frame, .frame_end, 0, 0, 0, "");
    }

    pub fn event(self: *@This(), timestamp_ns: u64, frame: u32, code: u16, value: u64, aux: u64) bool {
        return self.append(timestamp_ns, frame, .event, code, value, aux, "");
    }

    pub fn slice(self: *const @This()) []const Record {
        return self.records[0..self.len];
    }

    /// FNV-1a over the logical trace. Timing is optional because frame/event
    /// golden tests should not fail when the same work runs at another speed.
    pub fn digest(self: *const @This(), include_timing: bool) u64 {
        var hash: u64 = 14695981039346656037;
        hashU64(&hash, self.dropped);
        hashU64(&hash, self.len);
        for (self.slice()) |record| {
            if (include_timing) hashU64(&hash, record.timestamp_ns);
            hashU64(&hash, record.frame);
            hashU64(&hash, @backingInt(record.kind));
            hashU64(&hash, record.code);
            hashU64(&hash, record.value);
            hashU64(&hash, record.aux);
            hashU64(&hash, record.label_len);
            for (record.labelSlice()) |byte| hashU64(&hash, byte);
        }
        return hash;
    }

    pub fn eqlDeterministic(self: *const @This(), other: *const @This()) bool {
        return self.digest(false) == other.digest(false);
    }
};

fn hashU64(hash: *u64, value: anytype) void {
    var v: u64 = @intCast(value);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        hash.* ^= v & 0xff;
        hash.* *%= 1099511628211;
        v >>= 8;
    }
}

test "deterministic trace ignores timestamps but preserves order and overflow" {
    var first = Trace{};
    var second = Trace{};
    try std.testing.expect(first.frameBegin(10, 1));
    try std.testing.expect(first.event(20, 1, 7, 11, 12));
    try std.testing.expect(first.frameEnd(30, 1));
    try std.testing.expect(second.frameBegin(1000, 1));
    try std.testing.expect(second.event(2000, 1, 7, 11, 12));
    try std.testing.expect(second.frameEnd(3000, 1));
    try std.testing.expect(first.eqlDeterministic(&second));
    try std.testing.expect(first.digest(true) != second.digest(true));
    first.clear();
    for (0..max_records + 1) |i| _ = first.append(0, @intCast(i), .marker, 0, 0, 0, "bounded");
    try std.testing.expectEqual(@as(u64, 1), first.dropped);
}

test "trace labels are bounded and copied" {
    var trace = Trace{};
    var label: [max_label_bytes + 10]u8 = undefined;
    @memset(&label, 'x');
    try std.testing.expect(trace.append(0, 0, .marker, 0, 0, 0, &label));
    try std.testing.expectEqual(max_label_bytes, trace.records[0].labelSlice().len);
}
