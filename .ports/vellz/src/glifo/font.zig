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
const gvar_mod = @import("tables/gvar.zig");
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

/// Rust `f32 as i16` for the coordinate conversion: saturating, NaN maps to 0.
fn saturatingF32ToI16(value: f32) i16 {
    if (std.math.isNan(value)) return 0;
    if (value >= 32768.0) return std.math.maxInt(i16);
    if (value <= -32768.0) return std.math.minInt(i16);
    return @intFromFloat(value);
}

/// `F2Dot14::from_f32`: `(x * 16384 + (sign ? 1 : 0) - 0.5) as i16`, the
/// conversion upstream applies to user-facing normalized coordinates
/// (round half away from zero, then a saturating cast).
pub fn f2dot14FromF32(value: f32) NormalizedCoord {
    const frac: f32 = (if (std.math.signbit(value)) @as(f32, 0.0) else @as(f32, 1.0)) - 0.5;
    return saturatingF32ToI16(value * 16384.0 + frac);
}

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
        return Charmap.init(self.face.table(sfnt.tag_cmap));
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

    /// The parsed `gvar` table, or `null` when absent/malformed.
    ///
    /// Mirrors `FontRef::gvar().ok()`: a table shorter than the 20-byte header
    /// (or an unparsable offset array) is treated as "no variations", not an
    /// error, so a broken variation table never blocks static outlines.
    pub fn gvar(self: Font) ?gvar_mod.Gvar {
        const data = self.face.table(sfnt.tag_gvar) orelse return null;
        return gvar_mod.Gvar.parse(data) catch null;
    }

    /// The parsed `cvar` table, or `null` when absent/malformed.
    pub fn cvar(self: Font) ?gvar_mod.Cvar {
        const data = self.face.table(sfnt.tag_cvar) orelse return null;
        return gvar_mod.Cvar.parse(data) catch null;
    }

    /// True when a usable `HVAR` table is present.
    ///
    /// The `glyf` scaler only consults HVAR's *presence* to mirror FreeType's
    /// different rounding of phantom-point gvar deltas; the advances
    /// themselves come from the phantom points. Requires the 20-byte header
    /// (`Hvar::read`'s minimum), like `FontRef::hvar().ok()`.
    pub fn hasHvar(self: Font) bool {
        const data = self.face.table(sfnt.tag_hvar) orelse return false;
        return data.len >= 20;
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
