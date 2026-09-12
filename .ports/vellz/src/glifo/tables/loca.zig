//! The `loca` (index to location) table.
//!
//! Port of the `read-fonts` 0.41.0 `Loca` accessors: short format values are
//! halved offsets, long format values are direct offsets. `get_glyf` returns
//! `null` for a zero-length entry and errors when the offsets do not fit the
//! `glyf` table.

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const Error = error{OutOfBounds};

pub const Loca = struct {
    data: []const u8,
    is_long: bool,

    pub fn parse(data: []const u8, is_long: bool) Loca {
        return .{ .data = data, .is_long = is_long };
    }

    fn entrySize(self: Loca) usize {
        return if (self.is_long) 4 else 2;
    }

    /// Number of offsets minus one, as upstream `Loca::len` counts entries.
    pub fn len(self: Loca) usize {
        const size = self.entrySize();
        if (self.data.len % size != 0) return 0;
        return (self.data.len / size) -| 1;
    }

    /// Offset for `idx`, `null` when the table does not have that entry.
    pub fn raw(self: Loca, idx: usize) ?u32 {
        const size = self.entrySize();
        if (self.data.len % size != 0) return null;
        const off = idx * size;
        if (off + size > self.data.len) return null;
        if (self.is_long) return sfnt.readU32(self.data, off);
        return @as(u32, sfnt.readU16(self.data, off).?) * 2;
    }

    /// The raw glyph bytes for `gid`, `null` for an empty entry.
    ///
    /// Mirrors `Loca::get_glyf`: missing offsets and out-of-range slices are
    /// errors, a zero-length entry is `null`.
    pub fn glyphBytes(self: Loca, gid: u32, glyf_data: []const u8) Error!?[]const u8 {
        const start = self.raw(gid) orelse return error.OutOfBounds;
        const end = self.raw(@as(usize, gid) + 1) orelse return error.OutOfBounds;
        if (start == end) return null;
        if (start > end or end > glyf_data.len) return error.OutOfBounds;
        return glyf_data[start..end];
    }
};

test "short loca of Roboto" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const head = try @import("head.zig").Head.parse(face.table(sfnt.tag_head).?);
    try std.testing.expectEqual(@as(i16, 0), head.indexToLocFormat());
    const loca = Loca.parse(face.table(sfnt.tag_loca).?, head.indexToLocFormat() == 1);
    try std.testing.expectEqual(@as(usize, 1294), loca.len());
    try std.testing.expectEqual(@as(?u32, 0), loca.raw(0));
    // Glyph 1 is the empty space glyph in Roboto: zero-length entry.
    const glyf = face.table(sfnt.tag_glyf).?;
    try std.testing.expectEqual(@as(?[]const u8, null), try loca.glyphBytes(1, glyf));
    try std.testing.expect((try loca.glyphBytes(37, glyf)).?.len > 0);
    try std.testing.expectError(error.OutOfBounds, loca.glyphBytes(9999, glyf));
}

test "long loca reads u32 offsets" {
    const bytes = [_]u8{
        0, 0, 0, 0,
        0, 0, 0, 8,
        0, 0, 0, 8,
        0, 0, 0, 20,
    };
    const loca = Loca.parse(&bytes, true);
    try std.testing.expectEqual(@as(usize, 3), loca.len());
    try std.testing.expectEqual(@as(?u32, 8), loca.raw(1));
    const glyf: [32]u8 = @splat(0);
    try std.testing.expectEqual(@as(?[]const u8, null), try loca.glyphBytes(1, &glyf));
    try std.testing.expectEqual(@as(usize, 12), (try loca.glyphBytes(2, &glyf)).?.len);
    try std.testing.expectError(error.OutOfBounds, loca.glyphBytes(0, glyf[0..4]));
}
