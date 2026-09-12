//! Minimal sfnt/TTC container parsing.
//!
//! Port of the `read-fonts` 0.41.0 `FontRef`/`TableDirectory` subset needed by
//! the `glifo` outline pipeline: face selection in a TTC, the offset table,
//! table records, and tag lookup. Records are read lazily straight out of the
//! original blob; out-of-bounds tables resolve to `null` exactly like
//! `FontRef::table_data`, they are not a parse error.
//!
//! Deliberately not ported: table checksums, `WOFF`/`WOFF2`, data-source
//! abstraction, and the generated table machinery (see
//! `.ports/vellz/docs/glifo-m3-plan.md` §2).
//!
//! Table lookup is a linear first-match scan; `read-fonts` binary-searches
//! directories it detected as sorted. Only fonts with duplicate records
//! (malformed) can observe the difference.

const std = @import("std");

pub const Error = error{
    /// Fewer bytes than the structure needs.
    Truncated,
    /// Offset table has an unknown `sfntVersion`.
    InvalidSfnt,
    /// `ttcf` header or a face offset inside it is malformed.
    InvalidTtc,
    /// Requested face index is not present.
    NoSuchFace,
};

/// Four-byte table/encoding tag.
pub const Tag = [4]u8;

pub const tag_head = Tag{ 'h', 'e', 'a', 'd' };
pub const tag_hhea = Tag{ 'h', 'h', 'e', 'a' };
pub const tag_hmtx = Tag{ 'h', 'm', 't', 'x' };
pub const tag_maxp = Tag{ 'm', 'a', 'x', 'p' };
pub const tag_cmap = Tag{ 'c', 'm', 'a', 'p' };
pub const tag_loca = Tag{ 'l', 'o', 'c', 'a' };
pub const tag_glyf = Tag{ 'g', 'l', 'y', 'f' };
/// TrueType instruction tables (M3 hinting).
pub const tag_fpgm = Tag{ 'f', 'p', 'g', 'm' };
pub const tag_prep = Tag{ 'p', 'r', 'e', 'p' };
pub const tag_cvt = Tag{ 'c', 'v', 't', ' ' };
pub const tag_os2 = Tag{ 'O', 'S', '/', '2' };
pub const tag_hdmx = Tag{ 'h', 'd', 'm', 'x' };
/// Color/bitmap tables used to detect deferred glyph sources (T4/T3b).
pub const tag_colr = Tag{ 'C', 'O', 'L', 'R' };
pub const tag_cpal = Tag{ 'C', 'P', 'A', 'L' };
pub const tag_cbdt = Tag{ 'C', 'B', 'D', 'T' };
pub const tag_cblc = Tag{ 'C', 'B', 'L', 'C' };
pub const tag_sbix = Tag{ 's', 'b', 'i', 'x' };
pub const tag_ebdt = Tag{ 'E', 'B', 'D', 'T' };
pub const tag_eblc = Tag{ 'E', 'B', 'L', 'C' };
pub const tag_cff = Tag{ 'C', 'F', 'F', ' ' };
pub const tag_cff2 = Tag{ 'C', 'F', 'F', '2' };
pub const tag_hvar = Tag{ 'H', 'V', 'A', 'R' };

pub const sfnt_version_true: u32 = 0x00010000;
pub const sfnt_version_otto: u32 = 0x4F54544F; // "OTTO"
pub const sfnt_version_true_apple: u32 = 0x74727565; // "true"
pub const ttc_tag: u32 = 0x74746366; // "ttcf"

pub const TableRecord = struct {
    tag: Tag,
    checksum: u32,
    offset: u32,
    length: u32,
};

/// A single face inside a font blob.
///
/// Holds the whole blob (TTC table offsets are relative to the file start, not
/// the face directory) plus the offset of this face's offset table.
pub const Face = struct {
    data: []const u8,
    index: u32,
    directory_offset: usize,
    num_tables: u16,
    in_ttc: bool,

    /// Parses the face at `index`. A single-font file only accepts index 0.
    pub fn parse(data: []const u8, index: u32) Error!Face {
        var directory_offset: usize = 0;
        var in_ttc = false;
        if (data.len >= 12 and readU32(data, 0).? == ttc_tag) {
            in_ttc = true;
            const num_fonts = readU32(data, 8) orelse return error.Truncated;
            if (index >= num_fonts) return error.NoSuchFace;
            const face_offset = readU32(data, 12 + 4 * @as(usize, index)) orelse
                return error.InvalidTtc;
            if (face_offset > std.math.maxInt(usize) - 12) return error.InvalidTtc;
            directory_offset = face_offset;
        } else if (index != 0) {
            return error.NoSuchFace;
        }
        if (directory_offset + 12 > data.len) return error.Truncated;
        const version = readU32(data, directory_offset).?;
        if (version != sfnt_version_true and
            version != sfnt_version_otto and
            version != sfnt_version_true_apple)
        {
            return error.InvalidSfnt;
        }
        const num_tables = readU16(data, directory_offset + 4) orelse return error.Truncated;
        return .{
            .data = data,
            .index = index,
            .directory_offset = directory_offset,
            .num_tables = num_tables,
            .in_ttc = in_ttc,
        };
    }

    /// Record `i` of the offset table, or `null` when the directory is short.
    pub fn recordAt(self: Face, i: usize) ?TableRecord {
        if (i >= self.num_tables) return null;
        const off = self.directory_offset + 12 + 16 * i;
        if (off + 16 > self.data.len) return null;
        return .{
            .tag = self.data[off..][0..4].*,
            .checksum = readU32(self.data, off + 4).?,
            .offset = readU32(self.data, off + 8).?,
            .length = readU32(self.data, off + 12).?,
        };
    }

    /// Returns the table bytes for `tag`, or `null` when absent/invalid.
    ///
    /// Mirrors `read-fonts`' `FontRef::table_data`: a zero offset or a slice
    /// outside the blob is `null`, never an error.
    pub fn table(self: Face, tag: Tag) ?[]const u8 {
        var i: usize = 0;
        while (i < self.num_tables) : (i += 1) {
            const record = self.recordAt(i) orelse return null;
            if (!std.mem.eql(u8, &record.tag, &tag)) continue;
            if (record.offset == 0) return null;
            const start: usize = record.offset;
            const end = start + @as(usize, record.length);
            if (end < start or end > self.data.len) return null;
            return self.data[start..end];
        }
        return null;
    }
};

pub fn readU16(data: []const u8, off: usize) ?u16 {
    if (off + 2 > data.len) return null;
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

pub fn readI16(data: []const u8, off: usize) ?i16 {
    if (off + 2 > data.len) return null;
    return std.mem.readInt(i16, data[off..][0..2], .big);
}

pub fn readU32(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

test "parse single font and find tables" {
    const fixture = @import("../test_fixture.zig");
    const data = try fixture.roboto();
    const face = try Face.parse(data, 0);
    try std.testing.expect(!face.in_ttc);
    try std.testing.expectEqual(@as(u16, 18), face.num_tables);
    try std.testing.expect(face.table(tag_head) != null);
    try std.testing.expect(face.table(tag_glyf) != null);
    try std.testing.expect(face.table(Tag{ 'n', 'o', 'p', 'e' }) == null);
    // 'head' is a fixed 54-byte table.
    try std.testing.expectEqual(@as(usize, 54), face.table(tag_head).?.len);
}

test "parse rejects non-fonts and missing faces" {
    const fixture = @import("../test_fixture.zig");
    const data = try fixture.roboto();
    try std.testing.expectError(error.NoSuchFace, Face.parse(data, 1));
    try std.testing.expectError(error.Truncated, Face.parse("nope", 0));
    try std.testing.expectError(error.Truncated, Face.parse(&.{ 0, 1, 0, 0 }, 0));
    var bad_version: [16]u8 = data[0..16].*;
    bad_version[0] = 0xDE;
    try std.testing.expectError(error.InvalidSfnt, Face.parse(&bad_version, 0));
}

test "table lookup tolerates a truncated directory" {
    const fixture = @import("../test_fixture.zig");
    const data = try fixture.roboto();
    var truncated: [64]u8 = data[0..64].*;
    // Keep the 17 records advertised but only the first one present.
    std.mem.writeInt(u16, truncated[4..6], 17, .big);
    try std.testing.expect((try Face.parse(&truncated, 0)).table(tag_glyf) == null);
}

/// Builds a two-face TTC that shares one table directory and all tables, the
/// layout `read-fonts` reads with `FontRef::from_index`.
fn buildSharedTtc(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const face = try Face.parse(data, 0);
    const dir_size = 12 + 16 * @as(usize, face.num_tables);
    const ttc_header_size = 12 + 4 * 2;
    const face_offset = ttc_header_size;
    const data_offset = face_offset + dir_size;
    const ttc = try allocator.alloc(u8, data_offset + data.len);
    @memset(ttc, 0);
    @memcpy(ttc[0..4], "ttcf");
    std.mem.writeInt(u32, ttc[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, ttc[8..12], 2, .big);
    std.mem.writeInt(u32, ttc[12..16], face_offset, .big);
    std.mem.writeInt(u32, ttc[16..20], face_offset, .big);
    @memcpy(ttc[face_offset .. face_offset + dir_size], data[0..dir_size]);
    var i: usize = 0;
    while (i < face.num_tables) : (i += 1) {
        const record = face_offset + 12 + 16 * i;
        const table_offset = std.mem.readInt(u32, ttc[record + 8 ..][0..4], .big);
        std.mem.writeInt(u32, ttc[record + 8 ..][0..4], table_offset + @as(u32, @intCast(data_offset)), .big);
    }
    @memcpy(ttc[data_offset..], data);
    return ttc;
}

test "ttc faces share tables and outline identically" {
    const std_testing = std.testing;
    const fixture = @import("../test_fixture.zig");
    const data = try fixture.roboto();
    const ttc = try buildSharedTtc(std_testing.allocator, data);
    defer std_testing.allocator.free(ttc);

    const face0 = try Face.parse(ttc, 0);
    const face1 = try Face.parse(ttc, 1);
    try std_testing.expect(face0.in_ttc and face1.in_ttc);
    try std_testing.expectEqual(face0.table(tag_glyf).?.ptr, face1.table(tag_glyf).?.ptr);
    try std_testing.expectError(error.NoSuchFace, Face.parse(ttc, 2));

    const font_mod = @import("../font.zig");
    const pen_mod = @import("../pen.zig");
    const font = try font_mod.Font.init(ttc, 1);
    const outlines = try font.outlines();
    var pen = pen_mod.PathElementPen.init(std_testing.allocator);
    defer pen.deinit();
    _ = try outlines.draw(std_testing.allocator, 37, .{ .size = 16.0 }, &pen);

    const plain = try font_mod.Font.init(data, 0);
    const plain_outlines = try plain.outlines();
    var plain_pen = pen_mod.PathElementPen.init(std_testing.allocator);
    defer plain_pen.deinit();
    _ = try plain_outlines.draw(std_testing.allocator, 37, .{ .size = 16.0 }, &plain_pen);

    try std_testing.expectEqual(plain_pen.elements.items.len, pen.elements.items.len);
    for (plain_pen.elements.items, pen.elements.items) |expected, actual| {
        try std_testing.expect(expected.eql(actual));
    }
}
