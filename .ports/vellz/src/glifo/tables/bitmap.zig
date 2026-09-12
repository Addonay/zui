//! Embedded bitmap table parsing: `CBDT`/`CBLC`, `EBDT`/`EBLC` and `sbix`.
//!
//! Hand-written subset of `read-fonts` 0.41.0's `tables/bitmap.rs` +
//! `generated_bitmap.rs` plus the `skrifa 0.44.0` `src/bitmap.rs` facade
//! (`BitmapStrikes`/`BitmapStrike`/`BitmapGlyph`/`BitmapData`/`MaskData`).
//!
//! Layout equivalence notes:
//! - Every `Offset32` in these tables is relative to the start of the table
//!   the offset lives in, matching `read-fonts`; index-subtable offsets are
//!   relative to the containing `CBLC`/`EBLC`. `sbix` glyph-data offsets are
//!   relative to the strike record, as `read-fonts` resolves them.
//! - Strike selection is transcribed from `skrifa::bitmap::BitmapStrikes`:
//!   `sbix` wins over `CBDT`, which wins over `EBDT`, and `glyph_for_size`
//!   prefers an exact match, then the nearest larger strike, then the nearest
//!   smaller one (per available glyph, not per strike).
//! - Malformed data degrades exactly like the upstream call sites: table
//!   constructors fail (`ok()?` → `null`), a missing glyph or unreadable
//!   record is `null`, and bitmap records whose content format `glifo` never
//!   renders (composites, bit-aligned 32bpp) are `null`.
//! - `EBDT` is not a color table, so PNG image formats 17/18/19 are only read
//!   from `CBDT`, matching `bitmap_data(.., is_color)`.
//! - Variation coordinates are irrelevant to fixed bitmap strikes; the glyph
//!   run layer routes bitmap cache keys through the static map exactly like
//!   upstream (`var_coords: SmallVec::new()`).

const std = @import("std");

const sfnt = @import("sfnt.zig");
const font_mod = @import("../font.zig");

pub const GlyphId = font_mod.GlyphId;

/// The format (or table) containing the data backing a set of bitmap strikes.
pub const Format = enum {
    sbix,
    cbdt,
    ebdt,
};

/// The origin point for drawing a bitmap glyph.
pub const Origin = enum {
    top_left,
    bottom_left,
};

/// Content format of one bitmap record (`read-fonts::BitmapDataFormat`).
pub const DataFormat = enum {
    bit_aligned,
    byte_aligned,
    png,
};

/// Errors from `MaskData.decode`/`decodeToSlice`
/// (`skrifa::bitmap::MaskDataDecodeError`).
pub const MaskDataDecodeError = error{
    /// The width and height product overflows `usize`.
    SizeOverflow,
    /// The data buffer is too small for the given dimensions and bit depth.
    InvalidDimensions,
};

/// A single-channel alpha mask.
pub const MaskData = struct {
    /// Number of bits per pixel. Always 1, 2, 4 or 8.
    bpp: u8,
    /// True if each row of the data is bit-aligned; otherwise each row is
    /// padded to the next byte.
    is_packed: bool,
    /// Raw bitmap data.
    data: []const u8,

    /// Decode into `dst`, which must hold at least `width * height` bytes.
    /// Each value is scaled to the 0–255 range.
    pub fn decodeToSlice(
        self: MaskData,
        width: u32,
        height: u32,
        dst: []u8,
    ) MaskDataDecodeError!void {
        const w: usize = width;
        const h: usize = height;
        const total_pixels = std.math.mul(usize, w, h) catch return error.SizeOverflow;
        if (total_pixels == 0) return;
        if (dst.len < total_pixels) return error.InvalidDimensions;
        const out = dst[0..total_pixels];

        const bits: usize = self.bpp;
        if (!self.is_packed) {
            // Byte-aligned: each row is padded to a byte boundary.
            const row_bits = std.math.mul(usize, w, bits) catch return error.SizeOverflow;
            const row_bytes = (row_bits + 7) / 8;
            const expected = std.math.mul(usize, row_bytes, h) catch return error.SizeOverflow;
            if (self.data.len < expected) return error.InvalidDimensions;
            var dst_idx: usize = 0;
            switch (self.bpp) {
                1 => {
                    var row: usize = 0;
                    while (row < h) : (row += 1) {
                        const row_data = self.data[row * row_bytes ..];
                        var x: usize = 0;
                        while (x < w) : (x += 1) {
                            const shift: u3 = @intCast((~x) & 7);
                            out[dst_idx] = ((row_data[x >> 3] >> shift) & 1) * 255;
                            dst_idx += 1;
                        }
                    }
                },
                2 => {
                    var row: usize = 0;
                    while (row < h) : (row += 1) {
                        const row_data = self.data[row * row_bytes ..];
                        var x: usize = 0;
                        while (x < w) : (x += 1) {
                            const shift: u3 = @intCast((~(x * 2)) & 6);
                            out[dst_idx] = ((row_data[x >> 2] >> shift) & 3) * 85;
                            dst_idx += 1;
                        }
                    }
                },
                4 => {
                    var row: usize = 0;
                    while (row < h) : (row += 1) {
                        const row_data = self.data[row * row_bytes ..];
                        var x: usize = 0;
                        while (x < w) : (x += 1) {
                            const shift: u3 = @intCast((~(x * 4)) & 4);
                            out[dst_idx] = ((row_data[x >> 1] >> shift) & 15) * 17;
                            dst_idx += 1;
                        }
                    }
                },
                8 => {
                    var row: usize = 0;
                    while (row < h) : (row += 1) {
                        const row_data = self.data[row * row_bytes ..];
                        @memcpy(out[dst_idx .. dst_idx + w], row_data[0..w]);
                        dst_idx += w;
                    }
                },
                else => return error.InvalidDimensions,
            }
        } else {
            // Bit-aligned: pixels are tightly packed with no row padding.
            const total_bits = std.math.mul(usize, total_pixels, bits) catch
                return error.SizeOverflow;
            const expected = (total_bits + 7) / 8;
            if (self.data.len < expected) return error.InvalidDimensions;
            switch (self.bpp) {
                1 => {
                    for (out, 0..) |*pixel, x| {
                        const shift: u3 = @intCast((~x) & 7);
                        pixel.* = ((self.data[x >> 3] >> shift) & 1) * 255;
                    }
                },
                2 => {
                    for (out, 0..) |*pixel, x| {
                        const shift: u3 = @intCast((~(x * 2)) & 6);
                        pixel.* = ((self.data[x >> 2] >> shift) & 3) * 85;
                    }
                },
                4 => {
                    for (out, 0..) |*pixel, x| {
                        const shift: u3 = @intCast((~(x * 4)) & 4);
                        pixel.* = ((self.data[x >> 1] >> shift) & 15) * 17;
                    }
                },
                8 => @memcpy(out, self.data[0..total_pixels]),
                else => return error.InvalidDimensions,
            }
        }
    }

    /// Decode into a newly allocated `width * height` buffer.
    pub fn decode(
        self: MaskData,
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
    ) (MaskDataDecodeError || std.mem.Allocator.Error)![]u8 {
        const total_pixels = std.math.mul(usize, width, height) catch
            return error.SizeOverflow;
        const dst = try allocator.alloc(u8, total_pixels);
        errdefer allocator.free(dst);
        @memset(dst, 0);
        try self.decodeToSlice(width, height, dst);
        return dst;
    }
};

/// The content of a bitmap record (`skrifa::bitmap::BitmapData`).
pub const BitmapData = union(enum) {
    /// Uncompressed 32-bit color data, pre-multiplied BGRA.
    bgra: []const u8,
    /// Compressed PNG data.
    png: []const u8,
    /// Single-channel alpha mask data.
    mask: MaskData,
};

/// A parsed glyph bitmap (`skrifa::bitmap::BitmapGlyph`).
pub const BitmapGlyph = struct {
    /// The underlying data of the bitmap glyph.
    data: BitmapData,
    /// Outer glyph bearing in the x direction, in font units.
    bearing_x: f32,
    /// Outer glyph bearing in the y direction, in font units.
    bearing_y: f32,
    /// Inner glyph bearing in the x direction, in pixels.
    inner_bearing_x: f32,
    /// Inner glyph bearing in the y direction, in pixels.
    inner_bearing_y: f32,
    /// The assumed pixels-per-em in the x direction.
    ppem_x: f32,
    /// The assumed pixels-per-em in the y direction.
    ppem_y: f32,
    /// The horizontal advance width of the bitmap glyph in pixels.
    advance: ?f32,
    /// The number of columns in the bitmap.
    width: u32,
    /// The number of rows in the bitmap.
    height: u32,
    /// The placement origin of the bitmap.
    placement_origin: Origin,
};

/// `SmallGlyphMetrics` (`read-fonts`).
pub const SmallGlyphMetrics = struct {
    height: u8,
    width: u8,
    bearing_x: i8,
    bearing_y: i8,
    advance: u8,

    fn parse(data: []const u8) ?SmallGlyphMetrics {
        if (data.len < 5) return null;
        return .{
            .height = data[0],
            .width = data[1],
            .bearing_x = @bitCast(data[2]),
            .bearing_y = @bitCast(data[3]),
            .advance = data[4],
        };
    }
};

/// `BigGlyphMetrics` (`read-fonts`).
pub const BigGlyphMetrics = struct {
    height: u8,
    width: u8,
    hori_bearing_x: i8,
    hori_bearing_y: i8,
    hori_advance: u8,
    vert_bearing_x: i8,
    vert_bearing_y: i8,
    vert_advance: u8,

    fn parse(data: []const u8) ?BigGlyphMetrics {
        if (data.len < 8) return null;
        return .{
            .height = data[0],
            .width = data[1],
            .hori_bearing_x = @bitCast(data[2]),
            .hori_bearing_y = @bitCast(data[3]),
            .hori_advance = data[4],
            .vert_bearing_x = @bitCast(data[5]),
            .vert_bearing_y = @bitCast(data[6]),
            .vert_advance = data[7],
        };
    }
};

/// Metrics of one bitmap record (`read-fonts::BitmapMetrics`).
pub const Metrics = union(enum) {
    small: SmallGlyphMetrics,
    big: BigGlyphMetrics,
};

/// Strikes from `sbix`, `CBDT`/`CBLC` or `EBDT`/`EBLC`.
pub const Strikes = struct {
    font: font_mod.Font,
    kind: Kind,

    const Kind = union(enum) {
        none,
        sbix: Sbix,
        cbdt: Bdt,
        ebdt: Bdt,
    };

    /// Creates a new `Strikes` for the given font, preferring `sbix`, then
    /// `CBDT`, then `EBDT`.
    pub fn init(font: font_mod.Font) Strikes {
        const formats = [_]Format{ .sbix, .cbdt, .ebdt };
        for (formats) |bitmap_format| {
            if (withFormat(font, bitmap_format)) |strikes| return strikes;
        }
        return .{ .font = font, .kind = .none };
    }

    /// Creates strikes for a specific format, or `null` when the tables for
    /// that format are not available.
    pub fn withFormat(font: font_mod.Font, bitmap_format: Format) ?Strikes {
        const kind: ?Kind = switch (bitmap_format) {
            .sbix => blk: {
                const data = font.face.table(sfnt.tag_sbix) orelse break :blk null;
                const sbix = Sbix.parse(data, font.numGlyphs()) orelse break :blk null;
                break :blk .{ .sbix = sbix };
            },
            .cbdt => blk: {
                const location = font.face.table(sfnt.tag_cblc) orelse break :blk null;
                const data = font.face.table(sfnt.tag_cbdt) orelse break :blk null;
                if (!Bdt.valid(location)) break :blk null;
                break :blk .{ .cbdt = Bdt{ .location = location, .data = data } };
            },
            .ebdt => blk: {
                const location = font.face.table(sfnt.tag_eblc) orelse break :blk null;
                const data = font.face.table(sfnt.tag_ebdt) orelse break :blk null;
                if (!Bdt.valid(location)) break :blk null;
                break :blk .{ .ebdt = Bdt{ .location = location, .data = data } };
            },
        };
        return .{ .font = font, .kind = kind orelse return null };
    }

    /// The format backing this set of strikes, or `null` when empty.
    pub fn format(self: Strikes) ?Format {
        return switch (self.kind) {
            .none => null,
            .sbix => .sbix,
            .cbdt => .cbdt,
            .ebdt => .ebdt,
        };
    }

    /// Number of available strikes.
    pub fn len(self: Strikes) usize {
        return switch (self.kind) {
            .none => 0,
            .sbix => |sbix| sbix.strikeCount(),
            .cbdt => |tables| tables.bitmapSizeCount(),
            .ebdt => |tables| tables.bitmapSizeCount(),
        };
    }

    /// Returns true when there are no available strikes.
    pub fn isEmpty(self: Strikes) bool {
        return self.len() == 0;
    }

    /// The strike at `index`, if present and valid.
    pub fn get(self: Strikes, index: usize) ?Strike {
        return switch (self.kind) {
            .none => null,
            .sbix => |sbix| blk: {
                const strike = sbix.strike(index) orelse break :blk null;
                break :blk .{ .strikes = self, .kind = .{ .sbix = strike } };
            },
            .cbdt => |tables| blk: {
                const size = tables.bitmapSize(index) orelse break :blk null;
                break :blk .{ .strikes = self, .kind = .{ .cbdt = .{
                    .size = size,
                    .tables = tables,
                } } };
            },
            .ebdt => |tables| blk: {
                const size = tables.bitmapSize(index) orelse break :blk null;
                break :blk .{ .strikes = self, .kind = .{ .ebdt = .{
                    .size = size,
                    .tables = tables,
                } } };
            },
        };
    }

    /// Returns the best matching glyph for the given size and glyph id.
    ///
    /// "Best" means a glyph of the exact size, nearest larger size, or nearest
    /// smaller size, in that order. `ppem` is the requested pixels-per-em;
    /// `null` means an unscaled request and selects the largest strike.
    pub fn glyphForSize(self: Strikes, ppem: ?f32, glyph_id: GlyphId) ?BitmapGlyph {
        const size = ppem orelse std.math.floatMax(f32);
        var best: ?BitmapGlyph = null;
        var index: usize = 0;
        while (index < self.len()) : (index += 1) {
            const entry = self.get(index) orelse continue;
            const entry_size = entry.ppem();
            if (best) |current| {
                const best_size = current.ppem_y;
                if ((entry_size >= size and entry_size < best_size) or
                    (best_size < size and entry_size > best_size))
                {
                    best = entry.get(glyph_id) orelse current;
                }
            } else {
                best = entry.get(glyph_id);
            }
        }
        return best;
    }
};

/// One bitmap strike of a specific size.
pub const Strike = struct {
    strikes: Strikes,
    kind: Kind,

    const Kind = union(enum) {
        sbix: SbixStrike,
        cbdt: struct { size: BitmapSize, tables: Bdt },
        ebdt: struct { size: BitmapSize, tables: Bdt },
    };

    /// The pixels-per-em of this strike.
    pub fn ppem(self: Strike) f32 {
        return switch (self.kind) {
            // Upstream notes the original implementation also considers
            // `ppem_y`; `skrifa` uses the single `sbix` ppem.
            .sbix => |strike| @floatFromInt(strike.ppem()),
            .cbdt => |entry| @floatFromInt(entry.size.ppem_y),
            .ebdt => |entry| @floatFromInt(entry.size.ppem_y),
        };
    }

    /// A bitmap glyph for `glyph_id`, if available in this strike.
    pub fn get(self: Strike, glyph_id: GlyphId) ?BitmapGlyph {
        return switch (self.kind) {
            .sbix => |strike| sbixGlyph(self.strikes.font, strike, glyph_id),
            .cbdt => |entry| bdtGlyph(entry.tables, entry.size, glyph_id, true),
            .ebdt => |entry| bdtGlyph(entry.tables, entry.size, glyph_id, false),
        };
    }
};

// ------------------------------------------------------------------- sbix

/// Parsed `sbix` table (`read-fonts::tables::sbix::Sbix`).
pub const Sbix = struct {
    data: []const u8,
    num_glyphs: u16,

    pub fn parse(data: []const u8, num_glyphs: u16) ?Sbix {
        if (data.len < 8) return null;
        return .{ .data = data, .num_glyphs = num_glyphs };
    }

    /// Declared number of strikes (`num_strikes`), validated like
    /// `read-fonts`' `strike_offsets()`: an offsets array that does not fit
    /// the table reads as empty.
    pub fn strikeCount(self: Sbix) usize {
        const declared = sfnt.readU32(self.data, 4) orelse return 0;
        const end = std.math.add(usize, 8, std.math.mul(usize, declared, 4) catch
            return 0) catch return 0;
        if (end > self.data.len) return 0;
        return declared;
    }

    /// Resolves strike `index`; offsets are relative to the table start.
    pub fn strike(self: Sbix, index: usize) ?SbixStrike {
        if (index >= self.strikeCount()) return null;
        const offset = sfnt.readU32(self.data, 8 + 4 * index) orelse return null;
        if (offset > self.data.len) return null;
        const strike_data = self.data[offset..];
        if (strike_data.len < 4) return null;
        return .{ .data = strike_data, .num_glyphs = self.num_glyphs };
    }
};

/// One `sbix` strike (`read-fonts::tables::sbix::Strike`).
pub const SbixStrike = struct {
    /// Bytes from the start of the `sbix` table, sliced at the strike record;
    /// glyph-data offsets are relative to that strike record.
    data: []const u8,
    num_glyphs: u16,

    pub fn ppem(self: SbixStrike) u16 {
        return sfnt.readU16(self.data, 0) orelse 0;
    }

    pub fn ppi(self: SbixStrike) u16 {
        return sfnt.readU16(self.data, 2) orelse 0;
    }

    /// Resolves the glyph record at `glyph_id`.
    pub fn glyphData(self: SbixStrike, glyph_id: GlyphId) ?SbixGlyphData {
        const index: usize = glyph_id;
        const count: usize = self.num_glyphs;
        if (index > count) return null;
        const start = sfnt.readU32(self.data, 4 + 4 * index) orelse return null;
        const end = sfnt.readU32(self.data, 4 + 4 * (index + 1)) orelse return null;
        if (start == end) return null;
        if (end < start or end > self.data.len) return null;
        const data = self.data[start..end];
        if (data.len < 8) return null;
        return .{
            .origin_offset_x = sfnt.readI16(data, 0) orelse 0,
            .origin_offset_y = sfnt.readI16(data, 2) orelse 0,
            .graphic_type = data[4..8].*,
            .data = data[8..],
        };
    }
};

/// One `sbix` glyph record (`read-fonts::tables::sbix::GlyphData`).
pub const SbixGlyphData = struct {
    origin_offset_x: i16,
    origin_offset_y: i16,
    graphic_type: sfnt.Tag,
    data: []const u8,
};

/// `skrifa::BitmapStrike::get` for `sbix` strikes.
fn sbixGlyph(font: font_mod.Font, strike: SbixStrike, glyph_id: GlyphId) ?BitmapGlyph {
    const glyph = strike.glyphData(glyph_id) orelse return null;
    if (!std.mem.eql(u8, &glyph.graphic_type, "png ")) return null;

    // Note: this calculation does not entirely correspond to the description
    // in the specification, but it matches Skia's fontations port (which was
    // tested against CoreText), and `skrifa` copies it verbatim.
    const glyf_bb = glyphYMin(font, glyph_id);
    const lsb = if (font.hmtx) |hmtx|
        @as(f32, @floatFromInt(hmtx.sideBearing(glyph_id) orelse 0))
    else
        0.0;
    const ppem: f32 = @floatFromInt(strike.ppem());
    const png_data = glyph.data;
    // PNG format: 8-byte header, IHDR chunk (4-byte length, 4-byte type),
    // width, height (big-endian u32).
    if (png_data.len < 24) return null;
    const width = sfnt.readU32(png_data, 16) orelse return null;
    const height = sfnt.readU32(png_data, 20) orelse return null;
    return .{
        .data = .{ .png = glyph.data },
        .bearing_x = lsb,
        .bearing_y = glyf_bb,
        .inner_bearing_x = @floatFromInt(glyph.origin_offset_x),
        .inner_bearing_y = @floatFromInt(glyph.origin_offset_y),
        .ppem_x = ppem,
        .ppem_y = ppem,
        .width = width,
        .height = height,
        .advance = null,
        .placement_origin = .bottom_left,
    };
}

/// `glyph_metrics(Size::unscaled()).bounds(gid)` y-min in font units, or 0
/// when the face has no `glyf` outline for the glyph.
fn glyphYMin(font: font_mod.Font, glyph_id: GlyphId) f32 {
    const outlines = font.outlines() catch return 0.0;
    const glyph = outlines.getGlyph(glyph_id) catch return 0.0;
    if (glyph) |value| return @floatFromInt(value.yMin());
    return 0.0;
}

// ------------------------------------------------------------ CBDT / EBDT

/// `CBLC`/`EBLC` location table plus its `CBDT`/`EBDT` data table.
pub const Bdt = struct {
    /// The `CBLC`/`EBLC` bytes (offsets are resolved against these).
    location: []const u8,
    /// The `CBDT`/`EBDT` bytes (image data).
    data: []const u8,

    /// `read-fonts::Cblc::read`/`Eblc::read` only require the header.
    fn valid(location: []const u8) bool {
        return location.len >= 8;
    }

    /// `bitmap_sizes().len()`: all-or-nothing, like `read_array().ok()
    /// .unwrap_or_default()`.
    fn bitmapSizeCount(self: Bdt) usize {
        const declared = sfnt.readU32(self.location, 4) orelse return 0;
        const end = std.math.add(usize, 8, std.math.mul(usize, declared, 48) catch
            return 0) catch return 0;
        if (end > self.location.len) return 0;
        return declared;
    }

    /// One `BitmapSize` record, if present.
    fn bitmapSize(self: Bdt, index: usize) ?BitmapSize {
        const offset = 8 + 48 * index;
        if (offset + 48 > self.location.len) return null;
        const data = self.location[offset..][0..48];
        return .{
            .record_offset = offset,
            .start_glyph_index = sfnt.readU16(data, 40).?,
            .end_glyph_index = sfnt.readU16(data, 42).?,
            .ppem_x = data[44],
            .ppem_y = data[45],
            .bit_depth = data[46],
        };
    }

    /// Resolves the location of `glyph_id`'s record
    /// (`read-fonts::BitmapSize::location`).
    fn resolveLocation(self: Bdt, size: BitmapSize, glyph_id: GlyphId) ?BitmapLocation {
        if (glyph_id < size.start_glyph_index or glyph_id > size.end_glyph_index) {
            return null;
        }
        const list_offset = sfnt.readU32(self.location, size.record_offset) orelse return null;
        const list_size = sfnt.readU32(self.location, size.record_offset + 4) orelse return null;
        const record_count = sfnt.readU32(self.location, size.record_offset + 8) orelse
            return null;

        const start: usize = list_offset;
        const end = std.math.add(usize, start, list_size) catch return null;
        if (end > self.location.len) return null;
        const list = self.location[start..end];

        var record_index: usize = 0;
        while (record_index < record_count) : (record_index += 1) {
            const record_offset = record_index * 8;
            if (record_offset + 8 > list.len) return null;
            const first = sfnt.readU16(list, record_offset).?;
            const last = sfnt.readU16(list, record_offset + 2).?;
            const additional_offset = sfnt.readU32(list, record_offset + 4).?;
            if (glyph_id < first or glyph_id > last) continue;
            const glyph_ix: usize = glyph_id - first;
            const subtable_offset = std.math.add(usize, start, additional_offset) catch
                return null;
            if (subtable_offset + 8 > self.location.len) return null;
            const subtable = self.location[subtable_offset..];
            const format = sfnt.readU16(subtable, 0).?;
            const image_format = sfnt.readU16(subtable, 2).?;
            var result = BitmapLocation{
                .format = image_format,
                .bit_depth = size.bit_depth,
            };
            switch (format) {
                1 => {
                    const image_data_offset = sfnt.readU32(subtable, 4) orelse return null;
                    const offset_start = sfnt.readU32(subtable, 8 + 4 * glyph_ix) orelse
                        return null;
                    const offset_end = sfnt.readU32(subtable, 8 + 4 * (glyph_ix + 1)) orelse
                        return null;
                    const data_start = std.math.add(usize, image_data_offset, offset_start) catch
                        return null;
                    const data_end = std.math.add(usize, image_data_offset, offset_end) catch
                        return null;
                    if (data_end < data_start) return null;
                    result.data_offset = data_start;
                    result.data_size = data_end - data_start;
                },
                2 => {
                    const image_size = sfnt.readU32(subtable, 8) orelse return null;
                    result.data_size = image_size;
                    const image_data_offset = sfnt.readU32(subtable, 4) orelse return null;
                    const advance = std.math.mul(usize, glyph_ix, image_size) catch return null;
                    result.data_offset = std.math.add(usize, image_data_offset, advance) catch
                        return null;
                    result.metrics = BigGlyphMetrics.parse(subtable[12..]) orelse return null;
                },
                3 => {
                    const image_data_offset = sfnt.readU32(subtable, 4) orelse return null;
                    const offset_start = sfnt.readU16(subtable, 8 + 2 * glyph_ix) orelse
                        return null;
                    const offset_end = sfnt.readU16(subtable, 8 + 2 * (glyph_ix + 1)) orelse
                        return null;
                    const data_start = std.math.add(usize, image_data_offset, offset_start) catch
                        return null;
                    const data_end = std.math.add(usize, image_data_offset, offset_end) catch
                        return null;
                    if (data_end < data_start) return null;
                    result.data_offset = data_start;
                    result.data_size = data_end - data_start;
                },
                4 => {
                    const num_glyphs = sfnt.readU32(subtable, 4) orelse return null;
                    const pair_index = binarySearchGlyphPair(
                        subtable,
                        num_glyphs,
                        glyph_id,
                    ) orelse return null;
                    // `read-fonts` resolves the end bound through
                    // `array.get(ix + 1)`, which fails for the last entry.
                    if (pair_index + 1 >= num_glyphs) return null;
                    const pair_offset = 8 + 4 * pair_index;
                    const next_offset = 8 + 4 * (pair_index + 1);
                    const data_start = sfnt.readU16(subtable, pair_offset + 2) orelse return null;
                    const data_end = sfnt.readU16(subtable, next_offset + 2) orelse return null;
                    if (data_end < data_start) return null;
                    result.data_offset = data_start;
                    result.data_size = data_end - data_start;
                },
                5 => {
                    const image_data_offset = sfnt.readU32(subtable, 4) orelse return null;
                    const image_size = sfnt.readU32(subtable, 8) orelse return null;
                    const num_glyphs = sfnt.readU32(subtable, 20) orelse return null;
                    const array_index = binarySearchGlyphIds(
                        subtable[24..],
                        num_glyphs,
                        glyph_id,
                    ) orelse return null;
                    result.data_size = image_size;
                    const advance = std.math.mul(usize, array_index, image_size) catch
                        return null;
                    result.data_offset = std.math.add(usize, image_data_offset, advance) catch
                        return null;
                    result.metrics = BigGlyphMetrics.parse(subtable[12..]) orelse return null;
                },
                else => return null,
            }
            return result;
        }
        return null;
    }

    /// Resolves the record content for `location`
    /// (`read-fonts::bitmap_data`).
    fn bitmapData(self: Bdt, location: BitmapLocation, is_color: bool) ?ParsedData {
        if (location.data_offset > self.data.len) return null;
        const end = std.math.add(usize, location.data_offset, location.data_size) catch
            return null;
        if (end > self.data.len) return null;
        const image_data = self.data[location.data_offset..end];
        return switch (location.format) {
            // Small metrics, byte-aligned data.
            1 => blk: {
                const metrics = SmallGlyphMetrics.parse(image_data) orelse break :blk null;
                const pitch = ((@as(usize, metrics.width) * location.bit_depth) + 7) / 8;
                const data = readBytes(image_data, 5, pitch * @as(usize, metrics.height)) orelse
                    break :blk null;
                break :blk .{
                    .metrics = .{ .small = metrics },
                    .format = .byte_aligned,
                    .data = data,
                };
            },
            // Small metrics, bit-aligned data.
            2 => blk: {
                const metrics = SmallGlyphMetrics.parse(image_data) orelse break :blk null;
                const bits = @as(usize, metrics.width) * location.bit_depth;
                const len = (bits * @as(usize, metrics.height) + 7) / 8;
                const data = readBytes(image_data, 5, len) orelse break :blk null;
                break :blk .{
                    .metrics = .{ .small = metrics },
                    .format = .bit_aligned,
                    .data = data,
                };
            },
            // Metrics in EBLC/CBLC, bit-aligned image data only.
            5 => blk: {
                const metrics = location.metrics orelse break :blk null;
                const bits = @as(usize, metrics.width) * location.bit_depth;
                const len = (bits * @as(usize, metrics.height) + 7) / 8;
                const data = readBytes(image_data, 0, len) orelse break :blk null;
                break :blk .{
                    .metrics = .{ .big = metrics },
                    .format = .bit_aligned,
                    .data = data,
                };
            },
            // Big metrics, byte-aligned data.
            6 => blk: {
                const metrics = BigGlyphMetrics.parse(image_data) orelse break :blk null;
                const pitch = ((@as(usize, metrics.width) * location.bit_depth) + 7) / 8;
                const data = readBytes(image_data, 8, pitch * @as(usize, metrics.height)) orelse
                    break :blk null;
                break :blk .{
                    .metrics = .{ .big = metrics },
                    .format = .byte_aligned,
                    .data = data,
                };
            },
            // Big metrics, bit-aligned data.
            7 => blk: {
                const metrics = BigGlyphMetrics.parse(image_data) orelse break :blk null;
                const bits = @as(usize, metrics.width) * location.bit_depth;
                const len = (bits * @as(usize, metrics.height) + 7) / 8;
                const data = readBytes(image_data, 8, len) orelse break :blk null;
                break :blk .{
                    .metrics = .{ .big = metrics },
                    .format = .bit_aligned,
                    .data = data,
                };
            },
            // Composite formats 8/9: `from_bdt` rejects them.
            8, 9 => null,
            // Small metrics, PNG image data (color tables only).
            17 => if (!is_color) null else blk: {
                const metrics = SmallGlyphMetrics.parse(image_data) orelse break :blk null;
                const len = sfnt.readU32(image_data, 5) orelse break :blk null;
                const data = readBytes(image_data, 9, len) orelse break :blk null;
                break :blk .{
                    .metrics = .{ .small = metrics },
                    .format = .png,
                    .data = data,
                };
            },
            // Big metrics, PNG image data (color tables only).
            18 => if (!is_color) null else blk: {
                const metrics = BigGlyphMetrics.parse(image_data) orelse break :blk null;
                const len = sfnt.readU32(image_data, 8) orelse break :blk null;
                const data = readBytes(image_data, 12, len) orelse break :blk null;
                break :blk .{
                    .metrics = .{ .big = metrics },
                    .format = .png,
                    .data = data,
                };
            },
            // Metrics in CBLC, PNG image data (color tables only).
            19 => if (!is_color) null else blk: {
                const metrics = location.metrics orelse break :blk null;
                const len = sfnt.readU32(image_data, 0) orelse break :blk null;
                const data = readBytes(image_data, 4, len) orelse break :blk null;
                break :blk .{
                    .metrics = .{ .big = metrics },
                    .format = .png,
                    .data = data,
                };
            },
            else => null,
        };
    }
};

/// Binary-search the sparse `IndexSubtable4` glyph array for `glyph_id`,
/// returning the array index (whose `sbit_offset` and the next entry's bound
/// the glyph's data). Mirrors `read-fonts`' `binary_search_by`.
fn binarySearchGlyphPair(data: []const u8, count: u32, glyph_id: GlyphId) ?usize {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const offset = 8 + 4 * mid;
        const value = sfnt.readU16(data, offset) orelse return null;
        if (value == glyph_id) return mid;
        if (value < glyph_id) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// Binary-search an `IndexSubtable5` glyph-id array (u16, sorted).
fn binarySearchGlyphIds(data: []const u8, count: u32, glyph_id: GlyphId) ?usize {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const value = sfnt.readU16(data, 2 * mid) orelse return null;
        if (value == glyph_id) return mid;
        if (value < glyph_id) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// `read-fonts::BitmapSize` (only the fields the scaler reads).
pub const BitmapSize = struct {
    /// Byte offset of the 48-byte record within the location table, used to
    /// resolve the index-subtable list.
    record_offset: usize,
    start_glyph_index: u16,
    end_glyph_index: u16,
    ppem_x: u8,
    ppem_y: u8,
    bit_depth: u8,
};

/// `read-fonts::BitmapLocation`.
pub const BitmapLocation = struct {
    format: u16 = 0,
    data_offset: usize = 0,
    data_size: usize = 0,
    bit_depth: u8 = 0,
    metrics: ?BigGlyphMetrics = null,
};

/// `read-fonts::BitmapData` before `skrifa`'s format filtering.
pub const ParsedData = struct {
    metrics: Metrics,
    format: DataFormat,
    data: []const u8,
};

fn bdtGlyph(
    tables: Bdt,
    size: BitmapSize,
    glyph_id: GlyphId,
    is_color: bool,
) ?BitmapGlyph {
    const location = tables.resolveLocation(size, glyph_id) orelse return null;
    const parsed = tables.bitmapData(location, is_color) orelse return null;
    return fromBdt(size, parsed);
}

/// `skrifa::bitmap::BitmapGlyph::from_bdt`.
fn fromBdt(size: BitmapSize, parsed: ParsedData) ?BitmapGlyph {
    const metrics = switch (parsed.metrics) {
        .small => |small| BdtMetrics{
            .inner_bearing_x = @floatFromInt(small.bearing_x),
            .inner_bearing_y = @floatFromInt(small.bearing_y),
            .advance = @floatFromInt(small.advance),
            .width = small.width,
            .height = small.height,
        },
        .big => |big| BdtMetrics{
            .inner_bearing_x = @floatFromInt(big.hori_bearing_x),
            .inner_bearing_y = @floatFromInt(big.hori_bearing_y),
            .advance = @floatFromInt(big.hori_advance),
            .width = big.width,
            .height = big.height,
        },
    };
    const bpp = size.bit_depth;
    const data: BitmapData = switch (bpp) {
        32 => switch (parsed.format) {
            .png => .{ .png = parsed.data },
            .byte_aligned => .{ .bgra = parsed.data },
            .bit_aligned => return null,
        },
        1, 2, 4, 8 => switch (parsed.format) {
            .byte_aligned => .{ .mask = .{
                .bpp = bpp,
                .is_packed = false,
                .data = parsed.data,
            } },
            .bit_aligned => .{ .mask = .{
                .bpp = bpp,
                .is_packed = true,
                .data = parsed.data,
            } },
            .png => return null,
        },
        // All other bit depth values are invalid.
        else => return null,
    };
    return .{
        .data = data,
        .bearing_x = 0.0,
        .bearing_y = 0.0,
        .inner_bearing_x = metrics.inner_bearing_x,
        .inner_bearing_y = metrics.inner_bearing_y,
        .ppem_x = @floatFromInt(size.ppem_x),
        .ppem_y = @floatFromInt(size.ppem_y),
        .width = metrics.width,
        .height = metrics.height,
        .advance = metrics.advance,
        .placement_origin = .top_left,
    };
}

const BdtMetrics = struct {
    inner_bearing_x: f32,
    inner_bearing_y: f32,
    advance: f32,
    width: u32,
    height: u32,
};

fn readBytes(data: []const u8, offset: usize, len: usize) ?[]const u8 {
    const end = std.math.add(usize, offset, len) catch return null;
    if (end > data.len) return null;
    return data[offset..end];
}

// --------------------------------------------------------------------- tests

const testing = std.testing;
const test_fixture = @import("../test_fixture.zig");

test "CBDT fixture exposes one 109 ppem colour strike" {
    const font = try font_mod.Font.init(try test_fixture.notoCbtf(), 0);
    const strikes = Strikes.init(font);
    try testing.expectEqual(Format.cbdt, strikes.format().?);
    try testing.expectEqual(@as(usize, 1), strikes.len());
    try testing.expect(!strikes.isEmpty());

    const strike = strikes.get(0).?;
    try testing.expectEqual(@as(f32, 109.0), strike.ppem());
}

test "CBDT glyph records carry PNG data and small metrics" {
    const font = try font_mod.Font.init(try test_fixture.notoCbtf(), 0);
    const strikes = Strikes.init(font);
    const strike = strikes.get(0).?;

    const glyph = strike.get(1).?;
    try testing.expectEqual(@as(u32, 136), glyph.width);
    try testing.expectEqual(@as(u32, 128), glyph.height);
    try testing.expectEqual(@as(f32, 0.0), glyph.bearing_x);
    try testing.expectEqual(@as(f32, 0.0), glyph.bearing_y);
    try testing.expectEqual(@as(f32, 0.0), glyph.inner_bearing_x);
    try testing.expectEqual(@as(f32, 101.0), glyph.inner_bearing_y);
    try testing.expectEqual(@as(?f32, 136.0), glyph.advance);
    try testing.expectEqual(Origin.top_left, glyph.placement_origin);
    try testing.expectEqual(@as(f32, 109.0), glyph.ppem_x);

    switch (glyph.data) {
        .png => |data| {
            try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", data[0..8]);
            // IHDR width/height for glyph 1.
            try testing.expectEqual(@as(u32, 136), sfnt.readU32(data, 16).?);
            try testing.expectEqual(@as(u32, 128), sfnt.readU32(data, 20).?);
        },
        else => return error.TestUnexpectedResult,
    }

    // Missing glyph ids are absent.
    try testing.expect(strike.get(0) == null);
    try testing.expect(strike.get(5) == null);
}

test "CBDT strike selection prefers exact, then larger, then smaller" {
    const font = try font_mod.Font.init(try test_fixture.notoCbtf(), 0);
    const strikes = Strikes.init(font);

    // The fixture has a single strike, so every request resolves to it as
    // long as the glyph exists in it.
    try testing.expectEqual(@as(f32, 109.0), strikes.glyphForSize(50.0, 1).?.ppem_x);
    try testing.expectEqual(@as(f32, 109.0), strikes.glyphForSize(109.0, 1).?.ppem_x);
    try testing.expectEqual(@as(f32, 109.0), strikes.glyphForSize(400.0, 1).?.ppem_x);
    try testing.expect(strikes.glyphForSize(400.0, 0) == null);
}

test "sbix header, strike and glyph records resolve offsets from the table" {
    // Synthetic sbix: header, one strike with two glyph records.
    const png = [_]u8{
        0x89, 'P',  'N',  'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03,
    };
    var glyph_record: [8]u8 = undefined;
    std.mem.writeInt(i16, glyph_record[0..2], 4, .big);
    std.mem.writeInt(i16, glyph_record[2..4], -27, .big);
    @memcpy(glyph_record[4..8], "png ");
    const glyph_data = glyph_record ++ png;

    const strike_offset: u32 = 12 + 4; // header (version/flags/count) + one offset
    var table: [strike_offset + 8 + 4 * 3 + glyph_data.len]u8 = @splat(0);
    std.mem.writeInt(u16, table[0..2], 1, .big);
    std.mem.writeInt(u16, table[2..4], 1, .big);
    std.mem.writeInt(u32, table[4..8], 1, .big);
    std.mem.writeInt(u32, table[8..12], strike_offset, .big);
    std.mem.writeInt(u16, table[strike_offset..][0..2], 109, .big);
    std.mem.writeInt(u16, table[strike_offset + 2 ..][0..2], 144, .big);
    // Glyph 0 and 1 are empty; glyph 2 holds the record.
    const record_offset: u32 = 20;
    std.mem.writeInt(u32, table[strike_offset + 4 ..][0..4], 0, .big);
    std.mem.writeInt(u32, table[strike_offset + 8 ..][0..4], 0, .big);
    std.mem.writeInt(u32, table[strike_offset + 12 ..][0..4], record_offset, .big);
    std.mem.writeInt(
        u32,
        table[strike_offset + 16 ..][0..4],
        record_offset + @as(u32, @intCast(glyph_data.len)),
        .big,
    );
    @memcpy(table[strike_offset + record_offset ..][0..glyph_data.len], &glyph_data);

    const sbix = Sbix.parse(&table, 2).?;
    try testing.expectEqual(@as(usize, 1), sbix.strikeCount());
    const strike = sbix.strike(0).?;
    try testing.expectEqual(@as(u16, 109), strike.ppem());
    try testing.expect(strike.glyphData(0) == null);
    try testing.expect(strike.glyphData(3) == null);

    const glyph = strike.glyphData(2).?;
    try testing.expectEqual(@as(i16, 4), glyph.origin_offset_x);
    try testing.expectEqual(@as(i16, -27), glyph.origin_offset_y);
    try testing.expectEqualSlices(u8, "png ", &glyph.graphic_type);
    try testing.expectEqualSlices(u8, &png, glyph.data);
    // Out-of-range glyph ids are rejected before the offsets are read.
    try testing.expect(strike.glyphData(6) == null);
}

test "mask decode matches the skrifa vectors" {
    // 4×2, 1 bpp, byte-aligned.
    const mask_1 = MaskData{ .bpp = 1, .is_packed = false, .data = &.{ 0xA0, 0x50 } };
    var out_1: [8]u8 = undefined;
    try mask_1.decodeToSlice(4, 2, &out_1);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 255, 0, 0, 255, 0, 255 }, &out_1);

    // 4×1, 2 bpp, byte-aligned.
    const mask_2 = MaskData{ .bpp = 2, .is_packed = false, .data = &.{0xE4} };
    var out_2: [4]u8 = undefined;
    try mask_2.decodeToSlice(4, 1, &out_2);
    try testing.expectEqualSlices(u8, &.{ 255, 170, 85, 0 }, &out_2);

    // 3×2, 4 bpp, byte-aligned.
    const mask_4 = MaskData{ .bpp = 4, .is_packed = false, .data = &.{ 0xF8, 0x40, 0x05, 0xA0 } };
    var out_4: [6]u8 = undefined;
    try mask_4.decodeToSlice(3, 2, &out_4);
    try testing.expectEqualSlices(u8, &.{ 255, 136, 68, 0, 85, 170 }, &out_4);

    // 3×3, 1 bpp, bit-aligned.
    const packed_1 = MaskData{ .bpp = 1, .is_packed = true, .data = &.{ 0xAB, 0x00 } };
    var out_p1: [9]u8 = undefined;
    try packed_1.decodeToSlice(3, 3, &out_p1);
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 255, 0, 255, 0, 255, 255, 0 },
        &out_p1,
    );

    // 5×2, 2 bpp, bit-aligned.
    const packed_2 = MaskData{ .bpp = 2, .is_packed = true, .data = &.{ 0xE4, 0xC6, 0xC0 } };
    var out_p2: [10]u8 = undefined;
    try packed_2.decodeToSlice(5, 2, &out_p2);
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 170, 85, 0, 255, 0, 85, 170, 255, 0 },
        &out_p2,
    );

    // Error cases: zero dimensions succeed, short buffers report
    // InvalidDimensions.
    const empty = MaskData{ .bpp = 8, .is_packed = false, .data = &.{} };
    var none: [0]u8 = .{};
    try empty.decodeToSlice(0, 0, &none);
    const short = MaskData{ .bpp = 8, .is_packed = false, .data = &.{ 1, 2, 3 } };
    var too_small: [4]u8 = undefined;
    try testing.expectError(error.InvalidDimensions, short.decodeToSlice(4, 2, &too_small));
    const packed_short = MaskData{ .bpp = 1, .is_packed = true, .data = &.{0xFF} };
    var dst: [9]u8 = undefined;
    try testing.expectError(error.InvalidDimensions, packed_short.decodeToSlice(3, 3, &dst));
    const allocated = try mask_1.decode(testing.allocator, 4, 2);
    defer testing.allocator.free(allocated);
    try testing.expectEqualSlices(u8, &out_1, allocated);
}

/// One synthetic `CBLC` strike: ppem plus the inclusive glyph-id range the
/// `BitmapSize` record advertises (the range drives per-strike availability).
const TestStrike = struct {
    ppem: u8,
    start_gid: u16,
    end_gid: u16,
};

/// Builds a minimal sfnt blob with `CBLC`/`CBDT` tables for `strikes` and
/// `glyph_count` identical 13-byte format-18 records (8 big-metrics bytes,
/// a 4-byte PNG length and one payload byte).
///
/// Index subtables all use format 2 (identical metrics, image format 18) so
/// the nearest-strike fold can be exercised without a real colour bitmap font.
fn buildSyntheticBitmapFont(
    allocator: std.mem.Allocator,
    strikes: []const TestStrike,
    glyph_count: usize,
) ![]u8 {
    const image_size: u32 = 13;
    const image_data_offset: u32 = 0;

    // CBDT: one record per glyph.
    const cbdt_len: usize = @as(usize, image_size) * glyph_count;
    const cbdt = try allocator.alloc(u8, cbdt_len);
    defer allocator.free(cbdt);
    @memset(cbdt, 0);
    for (0..glyph_count) |i| {
        const record = cbdt[i * image_size ..][0..image_size];
        record[0] = 32; // big metrics height
        record[1] = 32; // big metrics width
        record[2] = 1; // hori_bearing_x
        record[3] = 30; // hori_bearing_y
        record[4] = 32; // hori_advance
        std.mem.writeInt(u32, record[8..12], 1, .big);
        record[12] = 0xAB;
    }

    // CBLC: header, records, then one array record + format-2 subtable per
    // strike.
    const record_size = 48;
    const array_size = 8;
    const subtable_size = 20;
    const per_strike = array_size + subtable_size;
    const cblc_len = 8 + record_size * strikes.len + per_strike * strikes.len;
    const cblc = try allocator.alloc(u8, cblc_len);
    defer allocator.free(cblc);
    @memset(cblc, 0);
    std.mem.writeInt(u16, cblc[0..2], 3, .big);
    std.mem.writeInt(u32, cblc[4..8], @intCast(strikes.len), .big);
    for (strikes, 0..) |strike, i| {
        const record = cblc[8 + i * record_size ..][0..record_size];
        const list_offset: u32 = @intCast(8 + record_size * strikes.len + i * per_strike);
        std.mem.writeInt(u32, record[0..4], list_offset, .big);
        std.mem.writeInt(u32, record[4..8], array_size + subtable_size, .big);
        std.mem.writeInt(u32, record[8..12], 1, .big);
        std.mem.writeInt(u16, record[40..42], strike.start_gid, .big);
        std.mem.writeInt(u16, record[42..44], strike.end_gid, .big);
        record[44] = strike.ppem;
        record[45] = strike.ppem;
        record[46] = 32;
        record[47] = 1;

        const list = cblc[list_offset..];
        std.mem.writeInt(u16, list[0..2], strike.start_gid, .big);
        std.mem.writeInt(u16, list[2..4], strike.end_gid, .big);
        std.mem.writeInt(u32, list[4..8], array_size, .big);
        const subtable = list[array_size..];
        std.mem.writeInt(u16, subtable[0..2], 2, .big);
        std.mem.writeInt(u16, subtable[2..4], 18, .big);
        std.mem.writeInt(u32, subtable[4..8], image_data_offset, .big);
        std.mem.writeInt(u32, subtable[8..12], image_size, .big);
        subtable[12] = 32; // big metrics height
        subtable[13] = 32;
        subtable[14] = 1;
        subtable[15] = 30;
        subtable[16] = 32;
    }

    // Assemble the sfnt directory + tables.
    const header_size = 12 + 2 * 16;
    const cblc_offset = header_size;
    const cbdt_offset = cblc_offset + cblc_len;
    const blob = try allocator.alloc(u8, cbdt_offset + cbdt_len);
    @memset(blob, 0);
    std.mem.writeInt(u32, blob[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, blob[4..6], 2, .big);
    const record0 = blob[12..28];
    @memcpy(record0[0..4], "CBLC");
    std.mem.writeInt(u32, record0[8..12], @intCast(cblc_offset), .big);
    std.mem.writeInt(u32, record0[12..16], @intCast(cblc_len), .big);
    const record1 = blob[28..44];
    @memcpy(record1[0..4], "CBDT");
    std.mem.writeInt(u32, record1[8..12], @intCast(cbdt_offset), .big);
    std.mem.writeInt(u32, record1[12..16], @intCast(cbdt_len), .big);
    @memcpy(blob[cblc_offset .. cblc_offset + cblc_len], cblc);
    @memcpy(blob[cbdt_offset .. cbdt_offset + cbdt_len], cbdt);
    return blob;
}

test "nearest-strike selection mirrors skrifa for exact, larger and smaller" {
    const allocator = testing.allocator;
    const strikes_spec = [_]TestStrike{
        .{ .ppem = 16, .start_gid = 1, .end_gid = 3 },
        .{ .ppem = 64, .start_gid = 1, .end_gid = 3 },
        .{ .ppem = 128, .start_gid = 1, .end_gid = 3 },
    };
    const blob = try buildSyntheticBitmapFont(allocator, &strikes_spec, 3);
    defer allocator.free(blob);

    const font = try font_mod.Font.init(blob, 0);
    const strikes = Strikes.init(font);
    try testing.expectEqual(Format.cbdt, strikes.format().?);
    try testing.expectEqual(@as(usize, 3), strikes.len());
    try testing.expectEqual(@as(f32, 16.0), strikes.get(0).?.ppem());
    try testing.expectEqual(@as(f32, 64.0), strikes.get(1).?.ppem());
    try testing.expectEqual(@as(f32, 128.0), strikes.get(2).?.ppem());

    // Exact match, nearest larger, nearest smaller, unscaled (largest).
    try testing.expectEqual(@as(f32, 16.0), strikes.glyphForSize(16.0, 2).?.ppem_x);
    try testing.expectEqual(@as(f32, 64.0), strikes.glyphForSize(17.0, 2).?.ppem_x);
    try testing.expectEqual(@as(f32, 64.0), strikes.glyphForSize(60.0, 2).?.ppem_x);
    try testing.expectEqual(@as(f32, 128.0), strikes.glyphForSize(100.0, 2).?.ppem_x);
    try testing.expectEqual(@as(f32, 128.0), strikes.glyphForSize(null, 2).?.ppem_x);

    // Format-18 big metrics flow into the glyph record; `CBDT` is a colour
    // table, and the synthetic records are `PNG` payloads.
    const glyph = strikes.glyphForSize(16.0, 2).?;
    try testing.expectEqual(@as(u32, 32), glyph.width);
    try testing.expectEqual(@as(u32, 32), glyph.height);
    try testing.expectEqual(@as(f32, 1.0), glyph.inner_bearing_x);
    try testing.expectEqual(@as(f32, 30.0), glyph.inner_bearing_y);
    try testing.expectEqual(@as(?f32, 32.0), glyph.advance);
    try testing.expectEqual(Origin.top_left, glyph.placement_origin);
    switch (glyph.data) {
        .png => |data| try testing.expectEqualSlices(u8, &.{0xAB}, data),
        else => return error.TestUnexpectedResult,
    }

    // No EBLC/EBDT tables: the EBDT format yields no strikes.
    try testing.expect(Strikes.withFormat(font, .ebdt) == null);
    try testing.expect(Strikes.withFormat(font, .sbix) == null);
}

test "EBDT content formats reject PNG and expose masks" {
    // Format 18 (big metrics, PNG) is color-only: the EBDT path (is_color =
    // false) must return null, while the same record decodes for CBDT.
    var png_record: [14]u8 = @splat(0);
    png_record[0] = 2; // big metrics height
    png_record[1] = 3; // big metrics width
    std.mem.writeInt(u32, png_record[8..12], 1, .big);
    png_record[12] = 0x5A;
    const png_tables = Bdt{ .location = &.{}, .data = &png_record };
    const png_location = BitmapLocation{
        .format = 18,
        .data_offset = 0,
        .data_size = png_record.len,
        .bit_depth = 32,
    };
    try testing.expect(png_tables.bitmapData(png_location, false) == null);
    const color = png_tables.bitmapData(png_location, true).?;
    try testing.expectEqual(DataFormat.png, color.format);
    try testing.expectEqualSlices(u8, &.{0x5A}, color.data);

    // Format 2 (small metrics, bit-aligned data) is the mask path: bit depth
    // 8 gives one byte per pixel, tightly packed.
    const mask_record = [_]u8{ 2, 3, 0, 2, 3, 10, 20, 30, 40, 50, 60 };
    const mask_tables = Bdt{ .location = &.{}, .data = &mask_record };
    const parsed = mask_tables.bitmapData(.{
        .format = 2,
        .data_offset = 0,
        .data_size = mask_record.len,
        .bit_depth = 8,
    }, false).?;
    try testing.expectEqual(DataFormat.bit_aligned, parsed.format);
    const glyph = fromBdt(.{
        .record_offset = 0,
        .start_glyph_index = 1,
        .end_glyph_index = 1,
        .ppem_x = 16,
        .ppem_y = 16,
        .bit_depth = 8,
    }, parsed).?;
    switch (glyph.data) {
        .mask => |mask| {
            try testing.expectEqual(@as(u8, 8), mask.bpp);
            try testing.expect(mask.is_packed);
            const decoded = try mask.decode(testing.allocator, 3, 2);
            defer testing.allocator.free(decoded);
            try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, decoded);
        },
        else => return error.TestUnexpectedResult,
    }

    // Composite formats are rejected by `from_bdt`.
    const composite = Bdt{ .location = &.{}, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    try testing.expect(composite.bitmapData(.{
        .format = 9,
        .data_offset = 0,
        .data_size = 10,
        .bit_depth = 1,
    }, false) == null);
}

/// Builds a minimal sfnt blob with `sbix` + `maxp` (2 glyphs) tables: one
/// 109 ppem strike whose glyph 1 is a PNG record and glyph 0 is empty.
fn buildSyntheticSbixFont(allocator: std.mem.Allocator) ![]u8 {
    // 24-byte PNG prefix: signature, IHDR length/type, width, height.
    var png: [24]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 136, .big);
    std.mem.writeInt(u32, png[20..24], 128, .big);

    var glyph_record: [32]u8 = @splat(0);
    std.mem.writeInt(i16, glyph_record[0..2], 4, .big);
    std.mem.writeInt(i16, glyph_record[2..4], -27, .big);
    @memcpy(glyph_record[4..8], "png ");
    @memcpy(glyph_record[8..32], &png);

    const strike_header = 4 + 4 * 3;
    const sbix_len = 12 + strike_header + glyph_record.len;
    const sbix = try allocator.alloc(u8, sbix_len);
    defer allocator.free(sbix);
    @memset(sbix, 0);
    std.mem.writeInt(u16, sbix[0..2], 1, .big);
    std.mem.writeInt(u16, sbix[2..4], 1, .big);
    std.mem.writeInt(u32, sbix[4..8], 1, .big);
    std.mem.writeInt(u32, sbix[8..12], 12, .big);
    const strike = sbix[12..];
    std.mem.writeInt(u16, strike[0..2], 109, .big);
    std.mem.writeInt(u16, strike[2..4], 72, .big);
    std.mem.writeInt(u32, strike[4..8], 0, .big); // glyph 0: empty
    std.mem.writeInt(u32, strike[8..12], strike_header, .big); // glyph 1 start
    std.mem.writeInt(
        u32,
        strike[12..16],
        strike_header + @as(u32, @intCast(glyph_record.len)),
        .big,
    );
    @memcpy(strike[strike_header..][0..glyph_record.len], &glyph_record);

    var maxp: [6]u8 = @splat(0);
    std.mem.writeInt(u32, maxp[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, maxp[4..6], 2, .big);

    const header_size = 12 + 2 * 16;
    const sbix_offset = header_size;
    const maxp_offset = sbix_offset + sbix_len;
    const blob = try allocator.alloc(u8, maxp_offset + maxp.len);
    @memset(blob, 0);
    std.mem.writeInt(u32, blob[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, blob[4..6], 2, .big);
    const sbix_record = blob[12..28];
    @memcpy(sbix_record[0..4], "sbix");
    std.mem.writeInt(u32, sbix_record[8..12], @intCast(sbix_offset), .big);
    std.mem.writeInt(u32, sbix_record[12..16], @intCast(sbix_len), .big);
    const maxp_record = blob[28..44];
    @memcpy(maxp_record[0..4], "maxp");
    std.mem.writeInt(u32, maxp_record[8..12], @intCast(maxp_offset), .big);
    std.mem.writeInt(u32, maxp_record[12..16], maxp.len, .big);
    @memcpy(blob[sbix_offset .. sbix_offset + sbix_len], sbix);
    @memcpy(blob[maxp_offset..], &maxp);
    return blob;
}

test "sbix strikes resolve glyph records through the font" {
    const allocator = testing.allocator;
    const blob = try buildSyntheticSbixFont(allocator);
    defer allocator.free(blob);

    const font = try font_mod.Font.init(blob, 0);
    const strikes = Strikes.init(font);
    try testing.expectEqual(Format.sbix, strikes.format().?);
    try testing.expectEqual(@as(usize, 1), strikes.len());
    try testing.expectEqual(@as(f32, 109.0), strikes.get(0).?.ppem());

    // Glyph 0 is empty, glyph 1 is present; both resolve through the strike.
    try testing.expect(strikes.glyphForSize(50.0, 0) == null);
    const glyph = strikes.glyphForSize(50.0, 1).?;
    try testing.expectEqual(@as(f32, 4.0), glyph.inner_bearing_x);
    try testing.expectEqual(@as(f32, -27.0), glyph.inner_bearing_y);
    try testing.expectEqual(@as(f32, 0.0), glyph.bearing_x);
    try testing.expectEqual(@as(f32, 0.0), glyph.bearing_y);
    try testing.expectEqual(@as(f32, 109.0), glyph.ppem_x);
    try testing.expectEqual(@as(f32, 109.0), glyph.ppem_y);
    try testing.expectEqual(@as(u32, 136), glyph.width);
    try testing.expectEqual(@as(u32, 128), glyph.height);
    try testing.expectEqual(Origin.bottom_left, glyph.placement_origin);
    switch (glyph.data) {
        .png => |data| try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", data[0..8]),
        else => return error.TestUnexpectedResult,
    }

    // No CBLC/CBDT tables: those formats yield no strikes.
    try testing.expect(Strikes.withFormat(font, .cbdt) == null);
    try testing.expect(Strikes.withFormat(font, .ebdt) == null);
}
