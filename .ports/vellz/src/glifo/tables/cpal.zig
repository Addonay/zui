//! CPAL (Color Palette) table parsing.
//!
//! Hand-written subset of the `read-fonts` 0.41.0 generated accessors for the
//! fields the COLR pipeline consumes: header counts, the raw color-record
//! array, and the per-palette start indices. `ColorPalettes` machinery (palette
//! types, labels, name IDs) is not ported; upstream `glifo`'s `ColrPainter`
//! indexes the raw `color_records_array` directly, so that is all that is
//! observable.
//!
//! Degradation matches `read-fonts`: a zero/malformed offset or a truncated
//! array resolves to "absent" (`null`), never a parse error. Upstream would
//! return `None` from `color_records_array()` and the COLR painter falls back
//! to `BLACK`; an out-of-range `palette_index` panics upstream and is treated
//! as `null` here (malformed-font divergence, documented in `colr.zig`).

const std = @import("std");
const sfnt = @import("sfnt.zig");

/// One CPAL color record. The on-disk order is BGRA (OpenType spec).
pub const ColorRecord = extern struct {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8,
};

/// Parsed `CPAL` table borrowing the font blob.
pub const Cpal = struct {
    /// The whole `CPAL` table.
    data: []const u8,

    /// Parse `data` as a `CPAL` table; `null` when the fixed header is absent.
    pub fn parse(data: []const u8) ?Cpal {
        if (data.len < 12) return null;
        return .{ .data = data };
    }

    pub fn version(self: Cpal) u16 {
        return sfnt.readU16(self.data, 0) orelse 0;
    }

    pub fn numPaletteEntries(self: Cpal) u16 {
        return sfnt.readU16(self.data, 2) orelse 0;
    }

    pub fn numPalettes(self: Cpal) u16 {
        return sfnt.readU16(self.data, 4) orelse 0;
    }

    pub fn numColorRecords(self: Cpal) u16 {
        return sfnt.readU16(self.data, 6) orelse 0;
    }

    /// The combined color-record array, or `null` when the offset is zero or
    /// the declared record count does not fit.
    pub fn colorRecords(self: Cpal) ?[]const ColorRecord {
        const count = self.numColorRecords();
        const off = sfnt.readU32(self.data, 8) orelse return null;
        if (off == 0) return null;
        const len: usize = @as(usize, count) * @sizeOf(ColorRecord);
        if (off > self.data.len or len > self.data.len - off) return null;
        const bytes = self.data[off .. off + len];
        return std.mem.bytesAsSlice(ColorRecord, bytes);
    }

    /// Raw byte slice of the per-palette first-record indices, or `null` when
    /// the declared `numPalettes` entries do not fit after the fixed header.
    ///
    /// Only used by tests/validation: the COLR painter follows upstream and
    /// indexes `colorRecords` directly (there is no palette-selection API in
    /// `glifo 0.3.0`), so this accessor is not on the render path.
    pub fn colorRecordIndicesBytes(self: Cpal) ?[]const u8 {
        const count = self.numPalettes();
        const len: usize = @as(usize, count) * 2;
        const start: usize = 12;
        if (start > self.data.len or len > self.data.len - start) return null;
        return self.data[start .. start + len];
    }

    /// Per-palette first-record index `i`, or `null` when out of range.
    pub fn colorRecordIndex(self: Cpal, i: usize) ?u16 {
        const bytes = self.colorRecordIndicesBytes() orelse return null;
        return sfnt.readU16(bytes, i * 2);
    }
};

const testing = std.testing;
const test_fixture = @import("../test_fixture.zig");

test "noto color emoji cpal header parses" {
    const data = try test_fixture.notoColor();
    const face = try sfnt.Face.parse(data, 0);
    const table = face.table(sfnt.tag_cpal) orelse return error.TestUnexpectedResult;
    const cpal = Cpal.parse(table) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), cpal.version());
    try testing.expectEqual(@as(u16, 30), cpal.numPaletteEntries());
    try testing.expectEqual(@as(u16, 1), cpal.numPalettes());
    try testing.expectEqual(@as(u16, 30), cpal.numColorRecords());
    const records = cpal.colorRecords() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 30), records.len);
    // Noto's first palette entry is opaque blue-ish (BGRA on disk).
    try testing.expectEqual(@as(u8, 3), records[0].red);
    try testing.expectEqual(@as(u8, 169), records[0].green);
    try testing.expectEqual(@as(u8, 244), records[0].blue);
    try testing.expectEqual(@as(u8, 255), records[0].alpha);
}

test "malformed cpal resolves to absent" {
    try testing.expect(Cpal.parse("nope") == null);
    const data = try test_fixture.notoColor();
    const face = try sfnt.Face.parse(data, 0);
    const table = face.table(sfnt.tag_cpal).?;
    // Zero the color-record offset: absent, not an error.
    const copy = try testing.allocator.dupe(u8, table);
    defer testing.allocator.free(copy);
    std.mem.writeInt(u32, copy[8..12], 0, .big);
    const cpal = Cpal.parse(copy).?;
    try testing.expect(cpal.colorRecords() == null);
}
