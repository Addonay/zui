//! The `cmap` (character to glyph mapping) table, formats 4 and 12.
//!
//! Port of the `skrifa` 0.44.0 `charmap` selection strategy and the
//! `read-fonts` 0.41.0 `Cmap4`/`Cmap12` mapping algorithms. Format 14
//! variation sequences are out of scope for M3 T2; other formats are simply
//! never selected.

const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const PlatformId = struct {
    pub const unicode: u16 = 0;
    pub const macintosh: u16 = 1;
    pub const iso: u16 = 2;
    pub const windows: u16 = 3;
};

/// Mapping kind priority; greater wins, exactly like upstream `MappingKind`.
const MappingKind = enum(u8) {
    none = 0,
    unicode_bmp = 1,
    unicode_full = 2,
    symbol = 3,
};

pub const Subtable = union(enum) {
    format4: []const u8,
    format12: []const u8,
};

/// Selected character map for a font.
pub const Charmap = struct {
    subtable: ?Subtable = null,
    is_symbol: bool = false,
    /// `maxp.numGlyphs`, or `u16::MAX` when absent (upstream
    /// `CmapIterLimits::default_for_font`). Only used by `mappings()`.
    glyph_count: u32 = std.math.maxInt(u16),

    /// Builds a charmap from the raw `cmap` table bytes.
    pub fn init(table: ?[]const u8) Charmap {
        const data = table orelse return .{};
        if (data.len < 4) return .{};
        const num_records = sfnt.readU16(data, 2) orelse return .{};
        var best_kind: MappingKind = .none;
        var best: ?Subtable = null;
        var best_is_symbol = false;
        // Upstream walks encoding records in reverse and replaces the choice
        // only for a strictly better kind, so the highest matching index wins
        // ties.
        var i: usize = num_records;
        while (i > 0) {
            i -= 1;
            const off = 4 + 8 * i;
            const platform = sfnt.readU16(data, off) orelse continue;
            const encoding = sfnt.readU16(data, off + 2) orelse continue;
            const sub_off = sfnt.readU32(data, off + 4) orelse continue;
            if (sub_off > data.len) continue;
            const sub = data[sub_off..];
            const subtable = getSubtable(sub) orelse continue;
            const kind: MappingKind = switch (platform) {
                PlatformId.windows => switch (encoding) {
                    0 => .symbol,
                    10 => .unicode_full,
                    1 => .unicode_bmp,
                    else => .none,
                },
                PlatformId.unicode => switch (encoding) {
                    // Unicode variation sequences (format 14) are not a
                    // codepoint subtable.
                    5 => .none,
                    4 => .unicode_full,
                    else => .unicode_bmp,
                },
                PlatformId.iso => .unicode_bmp,
                else => .none,
            };
            if (@backingInt(kind) > @backingInt(best_kind)) {
                best_kind = kind;
                best = subtable;
                best_is_symbol = kind == .symbol;
            }
        }
        return .{ .subtable = best, .is_symbol = best_is_symbol };
    }

    pub fn hasMap(self: Charmap) bool {
        return self.subtable != null;
    }

    pub fn isSymbol(self: Charmap) bool {
        return self.is_symbol;
    }

    /// Maps a codepoint to a glyph id, or `null` when unmapped/`.notdef`.
    pub fn map(self: Charmap, codepoint: u32) ?u32 {
        return self.mapImpl(codepoint) orelse blk: {
            if (self.is_symbol and codepoint <= 0x00FF) {
                // Symbol fonts duplicate U+F000..F0FF at U+0000..U+00FF.
                break :blk self.mapImpl(codepoint + 0xF000);
            }
            break :blk null;
        };
    }

    fn mapImpl(self: Charmap, codepoint: u32) ?u32 {
        const gid = switch (self.subtable orelse return null) {
            .format4 => |sub| mapFormat4(sub, codepoint),
            .format12 => |sub| mapFormat12(sub, codepoint),
        } orelse return null;
        return if (gid == 0) null else gid;
    }

    /// Iterates every `(codepoint, gid)` mapping with a non-zero gid, in the
    /// same order as skrifa's `Charmap::mappings()` (`Cmap4Iter` /
    /// `Cmap12Iter`).
    pub fn mappings(self: Charmap) Mappings {
        return .{ .subtable = self.subtable, .glyph_count = self.glyph_count };
    }
};

pub const Mapping = struct { codepoint: u32, gid: u32 };

pub const Mappings = struct {
    subtable: ?Subtable,
    glyph_count: u32,
    // Format 4 state.
    f4_initialized: bool = false,
    f4_range_ix: usize = 0,
    f4_start: u32 = 0,
    f4_end: u32 = 0,
    f4_cp: u32 = 0,
    // Format 12 state.
    f12_initialized: bool = false,
    f12_group_ix: usize = 0,
    f12_start_code: u32 = 0,
    f12_ref: u32 = 0,
    f12_cp: u64 = 0,
    f12_end: u64 = 0,

    pub fn next(self: *Mappings) ?Mapping {
        const subtable = self.subtable orelse return null;
        return switch (subtable) {
            .format4 => |sub| self.nextFormat4(sub),
            .format12 => |sub| self.nextFormat12(sub),
        };
    }

    fn nextFormat4(self: *Mappings, sub: []const u8) ?Mapping {
        const seg_count_x2 = sfnt.readU16(sub, 6) orelse return null;
        const seg_count = @as(usize, seg_count_x2) / 2;
        const end_codes: U16Array = .{ .bytes = sliceArray(sub, 14, 2, seg_count) };
        const start_codes: U16Array = .{ .bytes = sliceArray(sub, 16 + 2 * seg_count, 2, seg_count) };
        if (!self.f4_initialized) {
            self.f4_initialized = true;
            if (!self.loadFormat4Range(&end_codes, &start_codes, 0)) return null;
        }
        while (true) {
            while (self.f4_cp < self.f4_end) {
                const cp = self.f4_cp;
                self.f4_cp += 1;
                const gid = lookupGlyphId4(
                    sub,
                    @truncate(cp),
                    self.f4_range_ix,
                    @truncate(self.f4_start),
                    seg_count,
                ) orelse continue;
                if (gid != 0) return .{ .codepoint = cp, .gid = gid };
            }
            self.f4_range_ix += 1;
            if (!self.loadFormat4Range(&end_codes, &start_codes, self.f4_range_ix)) return null;
        }
    }

    fn loadFormat4Range(
        self: *Mappings,
        end_codes: *const U16Array,
        start_codes: *const U16Array,
        ix: usize,
    ) bool {
        const start = start_codes.get(ix) orelse return false;
        const end = end_codes.get(ix) orelse return false;
        const next_start: u32 = start;
        const next_end: u32 = @as(u32, end) + 1;
        self.f4_start = @max(next_start, self.f4_end);
        self.f4_end = @max(next_end, self.f4_end);
        self.f4_cp = self.f4_start;
        return true;
    }

    fn nextFormat12(self: *Mappings, sub: []const u8) ?Mapping {
        if (!self.f12_initialized) {
            self.f12_initialized = true;
            if (!self.loadFormat12Group(sub, 0)) return null;
        }
        while (true) {
            while (self.f12_cp < self.f12_end) {
                const cp = self.f12_cp;
                self.f12_cp += 1;
                const gid = self.f12_ref +% (@as(u32, @truncate(cp)) -% self.f12_start_code);
                if (gid != 0) return .{ .codepoint = @truncate(cp), .gid = gid };
            }
            self.f12_group_ix += 1;
            if (!self.loadFormat12Group(sub, self.f12_group_ix)) return null;
        }
    }

    fn loadFormat12Group(self: *Mappings, sub: []const u8, ix: usize) bool {
        const num_groups = sfnt.readU32(sub, 12) orelse return false;
        if (ix >= num_groups) return false;
        const off = 16 + 12 * ix;
        const start = sfnt.readU32(sub, off) orelse return false;
        const end = sfnt.readU32(sub, off + 4) orelse return false;
        const ref = sfnt.readU32(sub, off + 8) orelse return false;
        // `CmapIterLimits::default_for_font` prunes by the glyph count and
        // the maximum Unicode scalar.
        const glyph_limit = @as(u64, self.glyph_count) -| @as(u64, ref) +| @as(u64, start);
        var end_exclusive = @as(u64, end) + 1;
        end_exclusive = @min(end_exclusive, @min(glyph_limit, 0x10FFFF));
        var range_start: u64 = start;
        if (range_start < self.f12_end) range_start = self.f12_end;
        self.f12_start_code = start;
        self.f12_ref = ref;
        self.f12_cp = range_start;
        self.f12_end = end_exclusive;
        return true;
    }
};

fn getSubtable(sub: []const u8) ?Subtable {
    const format = sfnt.readU16(sub, 0) orelse return null;
    return switch (format) {
        4 => .{ .format4 = sub },
        12 => .{ .format12 = sub },
        else => null,
    };
}

/// `read_array(..).ok().unwrap_or_default()`: the whole range must fit, else
/// the array is empty.
fn sliceArray(data: []const u8, start: usize, element_size: usize, count: usize) []const u8 {
    const len = element_size * count;
    if (start > data.len or len > data.len - start) return &.{};
    return data[start .. start + len];
}

const U16Array = struct {
    bytes: []const u8,

    fn get(self: U16Array, i: usize) ?u16 {
        return sfnt.readU16(self.bytes, i * 2);
    }

    fn len(self: U16Array) usize {
        return self.bytes.len / 2;
    }
};

fn mapFormat4(sub: []const u8, codepoint: u32) ?u32 {
    if (codepoint > 0xFFFF) return null;
    const cp: u16 = @intCast(codepoint);
    const seg_count_x2 = sfnt.readU16(sub, 6) orelse return null;
    const seg_count = @as(usize, seg_count_x2) / 2;
    // Layout (OpenType cmap format 4): endCode at 14, reservedPad, startCode,
    // idDelta, idRangeOffset, then glyphIdArray.
    const end_codes: U16Array = .{ .bytes = sliceArray(sub, 14, 2, seg_count) };
    const start_codes: U16Array = .{ .bytes = sliceArray(sub, 16 + 2 * seg_count, 2, seg_count) };
    var lo: usize = 0;
    var hi: usize = seg_count;
    while (lo < hi) {
        const i = (lo + hi) / 2;
        const start_code = start_codes.get(i) orelse return null;
        if (cp < start_code) {
            hi = i;
        } else if (cp > (end_codes.get(i) orelse return null)) {
            lo = i + 1;
        } else {
            return lookupGlyphId4(sub, cp, i, start_code, seg_count);
        }
    }
    return null;
}

fn lookupGlyphId4(
    sub: []const u8,
    cp: u16,
    index: usize,
    start_code: u16,
    seg_count: usize,
) ?u32 {
    const delta: i32 = sfnt.readI16(sub, 16 + 4 * seg_count + 2 * index) orelse return null;
    const range_offset = sfnt.readU16(sub, 16 + 6 * seg_count + 2 * index) orelse return null;
    if (range_offset == 0) {
        const sum = @as(i32, cp) + delta;
        return @as(u16, @truncate(@as(u32, @bitCast(sum))));
    }
    const id_range_offsets_len = seg_count;
    var offset = @as(usize, range_offset) / 2 + (@as(usize, cp) - @as(usize, start_code));
    offset = offset -| (id_range_offsets_len -| index);
    const glyph_id_array = glyphIdArray4(sub, seg_count);
    const gid = sfnt.readU16(glyph_id_array, offset * 2) orelse return null;
    if (gid == 0) return null;
    const sum = @as(i32, gid) + delta;
    return @as(u16, @truncate(@as(u32, @bitCast(sum))));
}

fn glyphIdArray4(sub: []const u8, seg_count: usize) []const u8 {
    const start = 16 + 8 * seg_count;
    if (start > sub.len) return &.{};
    return sliceArray(sub, start, 2, (sub.len - start) / 2);
}

fn mapFormat12(sub: []const u8, codepoint: u32) ?u32 {
    const num_groups = sfnt.readU32(sub, 12) orelse return null;
    var lo: usize = 0;
    var hi: usize = num_groups;
    while (lo < hi) {
        const i = (lo + hi) / 2;
        const off = 16 + 12 * i;
        const start = sfnt.readU32(sub, off) orelse return null;
        const end = sfnt.readU32(sub, off + 4) orelse return null;
        const glyph = sfnt.readU32(sub, off + 8) orelse return null;
        if (codepoint < start) {
            hi = i;
        } else if (codepoint > end) {
            lo = i + 1;
        } else {
            return glyph +% (codepoint -% start);
        }
    }
    return null;
}

test "cmap format 4 mappings match the oracle dump" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.roboto(), 0);
    const charmap = Charmap.init(face.table(sfnt.tag_cmap));
    try std.testing.expect(charmap.hasMap());
    try std.testing.expect(!charmap.isSymbol());
    try std.testing.expectEqual(@as(?u32, 4), charmap.map(32));
    try std.testing.expectEqual(@as(?u32, 37), charmap.map('A'));
    try std.testing.expectEqual(@as(?u32, 38), charmap.map('B'));
    try std.testing.expectEqual(@as(?u32, 62), charmap.map('Z'));
    try std.testing.expectEqual(@as(?u32, 69), charmap.map('a'));
    try std.testing.expectEqual(@as(?u32, 94), charmap.map('z'));
    try std.testing.expectEqual(@as(?u32, null), charmap.map(0x1F600));
}

test "cmap format 12 mappings match the oracle dump" {
    const fixture = @import("../test_fixture.zig");
    const face = try sfnt.Face.parse(try fixture.notoColor(), 0);
    const charmap = Charmap.init(face.table(sfnt.tag_cmap));
    // skrifa prefers the full-repertoire format 12 subtable over the BMP one.
    try std.testing.expectEqual(@as(?u32, 4), charmap.map(0x2705));
    try std.testing.expectEqual(@as(?u32, 1), charmap.map(0x1F389));
    try std.testing.expectEqual(@as(?u32, 2), charmap.map(0x1F440));
    try std.testing.expectEqual(@as(?u32, 3), charmap.map(0x1F920));
    try std.testing.expectEqual(@as(?u32, null), charmap.map('A'));
}

test "symbol subtables remap U+0000..U+00FF from U+F000..F0FF" {
    // One segment mapping U+F001 -> gid 1; platform 3 / encoding 0 selects the
    // symbol path, which also accepts codepoint 1.
    var table: [36]u8 = @splat(0);
    std.mem.writeInt(u16, table[2..4], 1, .big); // one encoding record
    std.mem.writeInt(u16, table[4..6], 3, .big); // platform 3 (Windows)
    std.mem.writeInt(u16, table[6..8], 0, .big); // encoding 0 (symbol)
    std.mem.writeInt(u32, table[8..12], 12, .big); // subtable offset
    const sub = table[12..];
    std.mem.writeInt(u16, sub[0..2], 4, .big); // format
    std.mem.writeInt(u16, sub[2..4], 24, .big); // length
    std.mem.writeInt(u16, sub[6..8], 2, .big); // segCountX2 = 1 segment
    std.mem.writeInt(u16, sub[14..16], 0xF001, .big); // endCode[0]
    std.mem.writeInt(u16, sub[18..20], 0xF001, .big); // startCode[0]
    // idDelta for U+F001 -> gid 1 is 1 - 0xF001, which wraps to 0x1000 in i16.
    std.mem.writeInt(i16, sub[20..22], @bitCast(@as(u16, 0x1000)), .big); // idDelta[0]
    std.mem.writeInt(u16, sub[22..24], 0, .big); // idRangeOffset[0]
    const charmap = Charmap.init(&table);
    try std.testing.expect(charmap.hasMap());
    try std.testing.expect(charmap.isSymbol());
    try std.testing.expectEqual(@as(?u32, 1), charmap.map(0xF001));
    try std.testing.expectEqual(@as(?u32, 1), charmap.map(1));
    try std.testing.expectEqual(@as(?u32, null), charmap.map('A'));
}

test "format 4 binary search misses and deltas" {
    // Two segments: 'A'-'B' maps by delta, 'Z' uses an idRangeOffset.
    var sub: [64]u8 = @splat(0);
    std.mem.writeInt(u16, sub[0..2], 4, .big); // format
    std.mem.writeInt(u16, sub[6..8], 4, .big); // segCountX2 = 2 segments
    std.mem.writeInt(u16, sub[14..16], 0x0042, .big); // endCode[0]
    std.mem.writeInt(u16, sub[16..18], 0x005A, .big); // endCode[1]
    // reservedPad at 18
    std.mem.writeInt(u16, sub[20..22], 0x0041, .big); // startCode[0]
    std.mem.writeInt(u16, sub[22..24], 0x005A, .big); // startCode[1]
    std.mem.writeInt(i16, sub[24..26], 1 - 0x41, .big); // idDelta[0]
    std.mem.writeInt(i16, sub[26..28], 0, .big); // idDelta[1]
    std.mem.writeInt(u16, sub[28..30], 0, .big); // idRangeOffset[0]
    std.mem.writeInt(u16, sub[30..32], 2, .big); // idRangeOffset[1] -> 32
    std.mem.writeInt(u16, sub[32..34], 7, .big); // glyphIdArray[0]
    try std.testing.expectEqual(@as(?u32, 1), mapFormat4(&sub, 'A'));
    try std.testing.expectEqual(@as(?u32, 2), mapFormat4(&sub, 'B'));
    try std.testing.expectEqual(@as(?u32, 7), mapFormat4(&sub, 'Z'));
    try std.testing.expectEqual(@as(?u32, null), mapFormat4(&sub, 'C'));
    try std.testing.expectEqual(@as(?u32, null), mapFormat4(&sub, 0x1F600));
}
