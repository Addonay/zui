//! The `maxp` (maximum profile) table.
//!
//! Port of the `read-fonts` 0.41.0 generated accessors used by the outline
//! pipeline. `numGlyphs` is required; the version 1.0 maxima are optional and
//! read only when the bytes are present (matching `Option<u16>` in upstream).

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const Maxp = struct {
    data: []const u8,

    pub const min_size = 6;

    pub fn parse(data: []const u8) sfnt.Error!Maxp {
        if (data.len < min_size) return error.Truncated;
        return .{ .data = data };
    }

    pub fn version(self: Maxp) u32 {
        return sfnt.readU32(self.data, 0).?;
    }

    pub fn numGlyphs(self: Maxp) u16 {
        return sfnt.readU16(self.data, 4).?;
    }

    pub fn maxPoints(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 6);
    }

    pub fn maxContours(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 8);
    }

    pub fn maxCompositePoints(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 10);
    }

    pub fn maxCompositeContours(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 12);
    }

    pub fn maxZones(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 14);
    }

    pub fn maxTwilightPoints(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 16);
    }

    pub fn maxStorage(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 18);
    }

    pub fn maxFunctionDefs(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 20);
    }

    pub fn maxInstructionDefs(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 22);
    }

    pub fn maxStackElements(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 24);
    }

    pub fn maxSizeOfInstructions(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 26);
    }

    pub fn maxComponentElements(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 28);
    }

    pub fn maxComponentDepth(self: Maxp) ?u16 {
        return sfnt.readU16(self.data, 30);
    }
};

test "maxp of Roboto" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const maxp = try Maxp.parse(face.table(sfnt.tag_maxp).?);
    try std.testing.expectEqual(@as(u32, 0x00010000), maxp.version());
    try std.testing.expectEqual(@as(u16, 1294), maxp.numGlyphs());
    try std.testing.expectEqual(@as(?u16, 1), maxp.maxComponentDepth());
}
