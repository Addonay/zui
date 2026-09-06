//! Stable widget/element identity.
//!
//! Why FNV over `@src()`: immediate-mode toolkits (DVUI) derive identity
//! from call-site file/line/col plus a parent id so ids survive across
//! frames without storing widget trees. We copy that decision for ZUI's
//! future retained-element map: same call site + same parent = same id.

const std = @import("std");

pub const Id = u64;
pub const NO_PARENT: Id = 0;

fn fnv1a(bytes: []const u8, seed: u64) u64 {
    var h: u64 = seed ^ 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn extend(parent: Id, file: []const u8, line: u32, col: u32, extra: u64) Id {
    var h = fnv1a(file, parent);
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], line, .little);
    std.mem.writeInt(u32, buf[4..8], col, .little);
    std.mem.writeInt(u64, buf[4..12], extra, .little);
    h = fnv1a(buf[0..4], h);
    h = fnv1a(buf[4..12], h);
    return if (h == 0) 1 else h;
}

pub fn fromSrc(parent: Id, src: std.builtin.SourceLocation, extra: u64) Id {
    return extend(parent, src.file, src.line, src.column, extra);
}

test "ids are deterministic and parent-sensitive" {
    const a = extend(0, "foo.zig", 10, 5, 0);
    const b = extend(0, "foo.zig", 10, 5, 0);
    const c = extend(1, "foo.zig", 10, 5, 0);
    const d = extend(0, "foo.zig", 10, 5, 1);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expect(a != d);
}
