//! Font loading: face selection, table access, and the `glifo`-facing
//! `Font`/`FontData` values.
//!
//! Mirrors the `glifo 0.3.0` shape (`FontData { blob, index }`) without the
//! `Shared`/`FontBlob` registry, which lands with the renderer. A `Font` is a
//! cheap value: it borrows the caller's blob and parses only the tables the
//! outline pipeline needs (`head`, `maxp`, `hhea`, `hmtx`; `loca`/`glyf`/
//! `cmap` are resolved on demand).
//!
//! Unsupported inputs are explicit: CFF/CFF2 outlines and variable-font
//! instances fail with `error.Unsupported` instead of being approximated (see
//! `.ports/vellz/docs/glifo-m3-plan.md` §2). Bitmap-only faces have no
//! `outlines()` but expose their embedded strikes through `bitmapStrikes()`.

const std = @import("std");

const sfnt = @import("tables/sfnt.zig");
const head_mod = @import("tables/head.zig");
const maxp_mod = @import("tables/maxp.zig");
const hhea_mod = @import("tables/hhea.zig");
const hmtx_mod = @import("tables/hmtx.zig");
const cmap_mod = @import("tables/cmap.zig");
const bitmap_mod = @import("tables/bitmap.zig");
const glyf_mod = @import("glyf.zig");

pub const Head = head_mod.Head;
pub const Maxp = maxp_mod.Maxp;
pub const Hhea = hhea_mod.Hhea;
pub const Hmtx = hmtx_mod.Hmtx;
pub const Charmap = cmap_mod.Charmap;

/// Glyph identifier; 0 is `.notdef`.
pub const GlyphId = u32;
pub const NOTDEF: GlyphId = 0;

/// Normalized variation coordinate in 2.14 fixed point, matching `glifo`'s
/// `NormalizedCoord` alias for `skrifa::instance::NormalizedCoord`.
pub const NormalizedCoord = i16;

pub const Error = sfnt.Error || error{
    /// The requested feature is not ported yet (CFF, bitmaps, variations).
    Unsupported,
};

/// A font blob plus a face index. Cloneable; `font()` parses the face.
pub const FontData = struct {
    blob: []const u8,
    index: u32 = 0,

    pub fn init(blob: []const u8, index: u32) FontData {
        return .{ .blob = blob, .index = index };
    }

    pub fn font(self: FontData) Error!Font {
        return Font.init(self.blob, self.index);
    }
};

/// A parsed face.
pub const Font = struct {
    face: sfnt.Face,
    head: ?Head = null,
    maxp: ?Maxp = null,
    hhea: ?Hhea = null,
    hmtx: ?Hmtx = null,

    /// Parses face `index` of `blob`. Tables are optional here; `outlines()`
    /// reports what the outline pipeline actually requires.
    pub fn init(blob: []const u8, face_index: u32) Error!Font {
        const face = try sfnt.Face.parse(blob, face_index);
        return .{
            .face = face,
            .head = if (face.table(sfnt.tag_head)) |data| Head.parse(data) catch null else null,
            .maxp = if (face.table(sfnt.tag_maxp)) |data| Maxp.parse(data) catch null else null,
            .hhea = if (face.table(sfnt.tag_hhea)) |data| Hhea.parse(data) catch null else null,
            .hmtx = blk: {
                const hhea = if (face.table(sfnt.tag_hhea)) |data|
                    (Hhea.parse(data) catch null)
                else
                    null;
                const table = face.table(sfnt.tag_hmtx) orelse break :blk null;
                break :blk Hmtx.parse(table, if (hhea) |h| h.numberOfHMetrics() else 0);
            },
        };
    }

    pub fn faceIndex(self: Font) u32 {
        return self.face.index;
    }

    pub fn unitsPerEm(self: Font) u16 {
        return if (self.head) |head| head.unitsPerEm() else 0;
    }

    pub fn numGlyphs(self: Font) u16 {
        return if (self.maxp) |maxp| maxp.numGlyphs() else 0;
    }

    pub fn charmap(self: Font) Charmap {
        var map = Charmap.init(self.face.table(sfnt.tag_cmap));
        map.glyph_count = self.numGlyphs();
        return map;
    }

    /// Left side bearing in font units, or 0 when absent.
    pub fn lsb(self: Font, gid: GlyphId) i32 {
        if (self.hmtx) |hmtx| {
            if (hmtx.sideBearing(gid)) |value| return value;
        }
        return 0;
    }

    /// Advance width in font units, or 0 when absent.
    pub fn advanceWidth(self: Font, gid: GlyphId) i32 {
        if (self.hmtx) |hmtx| {
            if (hmtx.advance(gid)) |value| return value;
        }
        return 0;
    }

    /// Advance width in font units; `null` when the glyph is outside the
    /// `hmtx` records (mirrors `GlyphMetrics::advance_width`).
    pub fn advanceWidthOpt(self: Font, gid: GlyphId) ?i32 {
        if (gid >= self.numGlyphs()) return null;
        const hmtx = self.hmtx orelse return null;
        const value = hmtx.advance(gid) orelse return null;
        return value;
    }

    /// `FontRef::attributes().style != Style::Normal`: OS/2 `fsSelection`
    /// italic/oblique when present, else `head.macStyle` italic.
    pub fn isItalic(self: Font) bool {
        if (self.face.table(sfnt.tag_os2)) |os2| {
            const fs_selection = sfnt.readU16(os2, 62) orelse 0;
            const italic: u16 = 1 << 0;
            const oblique: u16 = 1 << 9;
            return fs_selection & (italic | oblique) != 0;
        }
        if (self.face.table(sfnt.tag_head)) |head| {
            const mac_style = sfnt.readU16(head, 44) orelse 0;
            const mac_italic: u16 = 1 << 1;
            return mac_style & mac_italic != 0;
        }
        return false;
    }

    /// `post.isFixedPitch() != 0` (the byte at offset 12 of `post`).
    pub fn isFixedPitch(self: Font) bool {
        const post = self.face.table(sfnt.tag_post) orelse return false;
        const value = sfnt.readU32(post, 12) orelse return false;
        return value != 0;
    }

    /// Builds the `glyf` outline scaler for this face.
    ///
    /// Fails with `error.Unsupported` for fonts without TrueType outlines
    /// (CFF/CFF2, bitmap-only, or missing metrics tables).
    pub fn outlines(self: Font) Error!glyf_mod.Outlines {
        const head = self.head orelse return error.Unsupported;
        const maxp = self.maxp orelse return error.Unsupported;
        _ = self.hhea orelse return error.Unsupported;
        _ = self.hmtx orelse return error.Unsupported;
        const loca_data = self.face.table(sfnt.tag_loca) orelse return error.Unsupported;
        const glyf_data = self.face.table(sfnt.tag_glyf) orelse return error.Unsupported;
        return glyf_mod.Outlines.init(self, head, maxp, loca_data, glyf_data);
    }

    /// Embedded bitmap strikes (`sbix` > `CBDT` > `EBDT`), or an empty set.
    pub fn bitmapStrikes(self: Font) bitmap_mod.Strikes {
        return bitmap_mod.Strikes.init(self);
    }
};

test "Roboto face parses with the expected metrics" {
    const fixture = @import("test_fixture.zig");
    const font = try Font.init(try fixture.roboto(), 0);
    try std.testing.expectEqual(@as(u16, 2048), font.unitsPerEm());
    try std.testing.expectEqual(@as(u16, 1294), font.numGlyphs());
    try std.testing.expectEqual(@as(i32, 1336), font.advanceWidth(37));
    try std.testing.expectEqual(@as(i32, 28), font.lsb(37));
    _ = try font.outlines();
}

test "bitmap-only and CFF-only faces report Unsupported" {
    const fixture = @import("test_fixture.zig");
    const bitmap_font = try Font.init(try fixture.notoCbtf(), 0);
    try std.testing.expectError(error.Unsupported, bitmap_font.outlines());

    // A CFF face has no `glyf`/`loca`; Roboto with those records renamed away
    // stands in for one.
    var blob = try std.testing.allocator.dupe(u8, try fixture.roboto());
    defer std.testing.allocator.free(blob);
    const face = try sfnt.Face.parse(blob, 0);
    var i: usize = 0;
    while (i < face.num_tables) : (i += 1) {
        const off = face.directory_offset + 12 + 16 * i;
        const tag = blob[off..][0..4];
        if (std.mem.eql(u8, tag, "loca") or std.mem.eql(u8, tag, "glyf")) {
            @memcpy(tag, "zzzz");
        }
    }
    const cff_like = try Font.init(blob, 0);
    try std.testing.expectError(error.Unsupported, cff_like.outlines());
}
