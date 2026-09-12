//! The `hhea` (horizontal header) table.
//!
//! Port of the `read-fonts` 0.41.0 generated accessors used by the outline
//! pipeline. `numberOfHMetrics` is required by `hmtx`; ascender/descender feed
//! only the vertical phantom points (unused by the unhinted horizontal path
//! but parsed for API parity).

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const Hhea = struct {
    data: []const u8,

    pub const min_size = 36;

    pub fn parse(data: []const u8) sfnt.Error!Hhea {
        if (data.len < min_size) return error.Truncated;
        return .{ .data = data };
    }

    pub fn ascender(self: Hhea) i16 {
        return sfnt.readI16(self.data, 4).?;
    }

    pub fn descender(self: Hhea) i16 {
        return sfnt.readI16(self.data, 6).?;
    }

    pub fn lineGap(self: Hhea) i16 {
        return sfnt.readI16(self.data, 8).?;
    }

    pub fn advanceWidthMax(self: Hhea) u16 {
        return sfnt.readU16(self.data, 10).?;
    }

    pub fn numberOfHMetrics(self: Hhea) u16 {
        return sfnt.readU16(self.data, 34).?;
    }
};

test "hhea of Roboto" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const hhea = try Hhea.parse(face.table(sfnt.tag_hhea).?);
    try std.testing.expectEqual(@as(u16, 1294), hhea.numberOfHMetrics());
    try std.testing.expectEqual(@as(i16, 1900), hhea.ascender());
}
