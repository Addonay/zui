//! Bounded profiler records suitable for deterministic headless tests.
//!
//! This is intentionally a record/counter layer, not a native sampling
//! profiler.  Callers provide timestamps, making the output reproducible and
//! keeping platform clocks, threads, and presentation out of unit tests.
const std = @import("std");

pub const max_records: usize = 256;
pub const max_label_bytes: usize = 48;

pub const Kind = enum(u8) { counter, duration };

pub const Record = struct {
    kind: Kind = .counter,
    label: [max_label_bytes]u8 = std.mem.zeroes([max_label_bytes]u8),
    label_len: u8 = 0,
    value_ns: u64 = 0,
    value: u64 = 0,

    pub fn labelSlice(self: *const @This()) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const Span = struct {
    label: [max_label_bytes]u8 = std.mem.zeroes([max_label_bytes]u8),
    label_len: u8 = 0,
    started_ns: u64 = 0,
    active: bool = false,

    pub fn labelSlice(self: *const @This()) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const Recorder = struct {
    records: [max_records]Record = undefined,
    len: usize = 0,
    dropped: u64 = 0,

    pub fn clear(self: *@This()) void {
        self.len = 0;
        self.dropped = 0;
    }

    pub fn begin(self: *const @This(), label: []const u8, started_ns: u64) Span {
        _ = self;
        const copied = @min(label.len, max_label_bytes);
        var result = Span{ .started_ns = started_ns, .active = true, .label_len = @intCast(copied) };
        @memcpy(result.label[0..copied], label[0..copied]);
        return result;
    }

    pub fn end(self: *@This(), span: *Span, ended_ns: u64) bool {
        if (!span.active) return false;
        const elapsed = ended_ns -| span.started_ns;
        span.active = false;
        return self.duration(span.labelSlice(), elapsed);
    }

    pub fn counter(self: *@This(), label: []const u8, value: u64) bool {
        return self.append(.counter, label, 0, value);
    }

    pub fn duration(self: *@This(), label: []const u8, value_ns: u64) bool {
        return self.append(.duration, label, value_ns, 0);
    }

    fn append(self: *@This(), kind: Kind, label: []const u8, value_ns: u64, value: u64) bool {
        if (self.len >= self.records.len) {
            self.dropped += 1;
            return false;
        }
        const copied = @min(label.len, max_label_bytes);
        self.records[self.len] = .{
            .kind = kind,
            .label = blk: {
                var bytes = std.mem.zeroes([max_label_bytes]u8);
                @memcpy(bytes[0..copied], label[0..copied]);
                break :blk bytes;
            },
            .label_len = @intCast(copied),
            .value_ns = value_ns,
            .value = value,
        };
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const @This()) []const Record {
        return self.records[0..self.len];
    }

    pub fn digest(self: *const @This()) u64 {
        var hash: u64 = 14695981039346656037;
        hashU64(&hash, self.dropped);
        hashU64(&hash, self.len);
        for (self.slice()) |record| {
            hashU64(&hash, @backingInt(record.kind));
            hashU64(&hash, record.label_len);
            for (record.labelSlice()) |byte| hashU64(&hash, byte);
            hashU64(&hash, record.value_ns);
            hashU64(&hash, record.value);
        }
        return hash;
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

test "profiler records deterministic counters and injected span timing" {
    var profiler = Recorder{};
    var span = profiler.begin("layout", 100);
    try std.testing.expect(profiler.end(&span, 145));
    try std.testing.expect(profiler.counter("frames", 3));
    try std.testing.expectEqual(@as(u64, 45), profiler.records[0].value_ns);
    try std.testing.expectEqual(@as(u64, 3), profiler.records[1].value);
    try std.testing.expect(!profiler.end(&span, 200));
}

test "profiler record storage is bounded" {
    var profiler = Recorder{};
    for (0..max_records + 1) |_| _ = profiler.counter("x", 1);
    try std.testing.expectEqual(max_records, profiler.len);
    try std.testing.expectEqual(@as(u64, 1), profiler.dropped);
}
