//! The `head` (font header) table.
//!
//! Port of the `read-fonts` 0.41.0 generated accessors used by the outline
//! pipeline: `unitsPerEm`, `indexToLocFormat`, and `flags`. Field offsets are
//! the OpenType `head` layout; only the front 54 bytes the table validates
//! (`Head::MIN_SIZE`) are required.

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const Head = struct {
    data: []const u8,

    pub const min_size = 54;

    pub fn parse(data: []const u8) sfnt.Error!Head {
        if (data.len < min_size) return error.Truncated;
        return .{ .data = data };
    }

    /// Bit 3 (`FORCE_INTEGER_PPEM`): ppem is rounded before hinting.
    pub const flag_force_integer_ppem: u16 = 0x0008;

    pub fn unitsPerEm(self: Head) u16 {
        return sfnt.readU16(self.data, 18).?;
    }

    pub fn indexToLocFormat(self: Head) i16 {
        return sfnt.readI16(self.data, 50).?;
    }

    pub fn flags(self: Head) u16 {
        return sfnt.readU16(self.data, 16).?;
    }

    pub fn forceIntegerPpem(self: Head) bool {
        return (self.flags() & flag_force_integer_ppem) != 0;
    }
};

test "head of Roboto" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const head = try Head.parse(face.table(sfnt.tag_head).?);
    try std.testing.expectEqual(@as(u16, 2048), head.unitsPerEm());
    try std.testing.expectEqual(@as(i16, 0), head.indexToLocFormat());
    // Roboto sets FORCE_INTEGER_PPEM (bit 3); it only affects hinted scaling.
    try std.testing.expect(head.forceIntegerPpem());
}
