//! FreeType font faces: open, size, rasterize (init-time + atlas fill).
//!
//! `FreeType` owns the `dlopen`ed library. `Face` borrows it (a copy of the
//! function table) and owns one `FT_Face`; the `FreeType` must outlive its
//! faces. `rasterize()` returns a view into FreeType-owned memory that stays
//! valid only until the next `rasterize()`/`advancePx()` call on the same
//! face — the atlas copies out of it immediately, and tests checksum it
//! before touching the face again.

const std = @import("std");
const dl = @import("../platform/dl.zig");
const tb = @import("../text/bindings.zig");
const tables = @import("tables.zig");
const discovery = @import("discovery.zig");

pub const FreeType = struct {
    lib: dl.Library,
    api: tables.FreeTypeApi,
    handle: tb.FT_Library,

    pub fn init() !FreeType {
        var lib = dl.Library.open(tables.freetype_lib_names) orelse return error.FreeTypeUnavailable;
        errdefer lib.close();
        const api = tables.FreeTypeApi.load(lib) orelse return error.FreeTypeSymbolsMissing;
        var handle: tb.FT_Library = undefined;
        if (api.init(&handle) != 0) return error.FreeTypeInitFailed;
        return .{ .lib = lib, .api = api, .handle = handle };
    }

    pub fn deinit(self: *FreeType) void {
        _ = self.api.done(self.handle);
        self.lib.close();
    }
};

pub const BitmapKind = enum {
    /// 8-bit grayscale coverage (the common case for UI text).
    gray,
    /// 1-bit coverage; expand with `expandMonoRow` before caching.
    mono,
    /// No pixels (space, control, empty outline) — advance still applies.
    empty,
};

/// A rasterized glyph. `pixels` points at FreeType-owned memory: copy it
/// before the next call on this face. Rows are `pitch` bytes apart and may
/// run bottom-up when `pitch` is negative.
pub const Raster = struct {
    width: u32,
    height: u32,
    pitch: c_int,
    bearing_x: i32,
    bearing_y: i32,
    advance_px: f32,
    kind: BitmapKind,
    pixels: [*]const u8,
};

/// Expand one 1-bit FreeType row to 8-bit coverage (0 or 255 per pixel).
/// Pure helper so the MONO path is testable without system libraries.
pub fn expandMonoRow(dst: []u8, src: [*]const u8, width: u32) void {
    std.debug.assert(dst.len >= width);
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const byte = src[x / 8];
        const bit: u3 = @intCast(7 - (x % 8));
        dst[x] = if (((byte >> bit) & 1) == 1) 255 else 0;
    }
}

pub const LineMetrics = struct {
    ascender_px: f32,
    descender_px: f32,
    height_px: f32,
};

/// Shared zero byte backing empty rasters (space has no pixels to point at).
pub const empty_coverage: u8 = 0;

pub const Face = struct {
    api: tables.FreeTypeApi,
    handle: tb.FT_Face,
    id: u32,
    pixel_size: u32 = 0,

    pub fn open(ft: *FreeType, match: *discovery.Match, id: u32) !Face {
        var handle: tb.FT_Face = undefined;
        if (ft.api.new_face(ft.handle, match.pathZ(), match.index, &handle) != 0) {
            return error.OpenFaceFailed;
        }
        return .{ .api = ft.api, .handle = handle, .id = id };
    }

    pub fn deinit(self: *Face) void {
        _ = self.api.done_face(self.handle);
    }

    pub fn setPixelSize(self: *Face, px: u32) !void {
        if (px == 0 or px > 256) return error.BadPixelSize;
        // Early-out: FreeType size state persists, so re-requesting the
        // current size is a no-op. This keeps per-frame re-sizing of hot
        // faces to one cheap integer compare.
        if (px == self.pixel_size) return;
        if (self.api.set_pixel_sizes(self.handle, 0, px) != 0) return error.SetPixelSizeFailed;
        self.pixel_size = px;
    }

    pub fn glyphIndex(self: *Face, codepoint: u21) u32 {
        return self.api.get_char_index(self.handle, codepoint);
    }

    pub fn hasKerning(self: *Face) bool {
        return tb.hasKerning(self.handle);
    }

    /// Horizontal advance without rasterizing (for measurement fast paths).
    pub fn advancePx(self: *Face, codepoint: u21) !f32 {
        if (self.api.load_char(self.handle, codepoint, tb.FT_LOAD_DEFAULT) != 0) {
            return error.LoadGlyphFailed;
        }
        return tb.f26dot6ToFloat(self.handle.glyph.advance.x);
    }

    /// Kern adjustment in pixels to add between two glyph ids (0 if none).
    pub fn kernPx(self: *Face, left_glyph: u32, right_glyph: u32) f32 {
        if (!self.hasKerning() or left_glyph == 0 or right_glyph == 0) return 0;
        var delta: tb.FT_Vector = .{ .x = 0, .y = 0 };
        if (self.api.get_kerning(self.handle, left_glyph, right_glyph, tb.FT_KERNING_DEFAULT, &delta) != 0) {
            return 0;
        }
        return tb.f26dot6ToFloat(delta.x);
    }

    pub fn lineMetrics(self: *Face) LineMetrics {
        const m = self.handle.size.metrics;
        return .{
            .ascender_px = tb.f26dot6ToFloat(m.ascender),
            .descender_px = tb.f26dot6ToFloat(m.descender),
            .height_px = tb.f26dot6ToFloat(m.height),
        };
    }

    /// Load + render one codepoint. See the lifetime note on `Raster`.
    pub fn rasterize(self: *Face, codepoint: u21) !Raster {
        if (self.api.load_char(self.handle, codepoint, tb.FT_LOAD_RENDER) != 0) {
            return error.LoadGlyphFailed;
        }
        return self.slotRaster();
    }

    /// Load + render one shaped glyph id (HarfBuzz output). Same lifetime.
    pub fn rasterizeGlyphId(self: *Face, glyph_id: u32) !Raster {
        if (self.api.load_glyph(self.handle, glyph_id, tb.FT_LOAD_RENDER) != 0) {
            return error.LoadGlyphFailed;
        }
        return self.slotRaster();
    }

    fn slotRaster(self: *Face) !Raster {
        const slot = self.handle.glyph;
        const advance = tb.f26dot6ToFloat(slot.advance.x);
        const bitmap = slot.bitmap;
        if (bitmap.width == 0 or bitmap.rows == 0) {
            return .{
                .width = 0,
                .height = 0,
                .pitch = 0,
                .bearing_x = slot.bitmap_left,
                .bearing_y = slot.bitmap_top,
                .advance_px = advance,
                .kind = .empty,
                .pixels = @as([*]const u8, @ptrCast(&empty_coverage)),
            };
        }
        const kind: BitmapKind = switch (bitmap.pixel_mode) {
            .FT_PIXEL_MODE_GRAY => .gray,
            .FT_PIXEL_MODE_MONO => .mono,
            else => return error.UnsupportedPixelMode,
        };
        return .{
            .width = bitmap.width,
            .height = bitmap.rows,
            .pitch = bitmap.pitch,
            .bearing_x = slot.bitmap_left,
            .bearing_y = slot.bitmap_top,
            .advance_px = advance,
            .kind = kind,
            .pixels = bitmap.buffer,
        };
    }
};

test "mono row expansion" {
    const t = std.testing;
    // Bits 1000_0000 1000_0000...: pixels 0 and 8 set.
    const src = [_]u8{ 0b1000_0001, 0b0000_0000 };
    var dst: [16]u8 = undefined;
    expandMonoRow(&dst, &src, 16);
    try t.expectEqual(@as(u8, 255), dst[0]);
    try t.expectEqual(@as(u8, 0), dst[1]);
    try t.expectEqual(@as(u8, 255), dst[7]);
    for (dst[8..]) |v| try t.expectEqual(@as(u8, 0), v);
}

test "fixed-point helpers round-trip" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 1.5), tb.f26dot6ToFloat(96), 0.0001);
    try t.expectEqual(@as(tb.FT_F26Dot6, 96), tb.floatToF26dot6(1.5));
}

test "face opens, sizes, and rasterizes" {
    const t = std.testing;
    if (!tables.FreeTypeApi.isAvailable() or !tables.FontconfigApi.isAvailable()) return;
    var d = try discovery.Discovery.init();
    defer d.deinit();
    var ft = try FreeType.init();
    defer ft.deinit();

    var match = try d.findSans();
    var face = try Face.open(&ft, &match, 1);
    defer face.deinit();
    try face.setPixelSize(16);

    const a = try face.rasterize('A');
    try t.expect(a.width > 0 and a.height > 0);
    try t.expect(a.advance_px > 0);
    try t.expect(a.kind == .gray or a.kind == .mono);
    // Coverage must be nonzero somewhere in the bitmap.
    var covered = false;
    if (a.kind == .gray) {
        const rows: usize = a.height;
        var y: usize = 0;
        while (y < rows) : (y += 1) {
            const off: usize = y * @as(usize, @intCast(@abs(a.pitch)));
            for (a.pixels[off..][0..a.width]) |v| {
                if (v != 0) {
                    covered = true;
                    break;
                }
            }
            if (covered) break;
        }
        try t.expect(covered);
    }

    // Space: no pixels, but a positive advance.
    const sp = try face.rasterize(' ');
    try t.expect(sp.kind == .empty);
    try t.expect(sp.advance_px > 0);

    // Advance fast path agrees with the rasterized advance.
    try t.expectApproxEqAbs(a.advance_px, try face.advancePx('A'), 0.01);

    const lm = face.lineMetrics();
    try t.expect(lm.ascender_px > 0);
    try t.expect(lm.descender_px < 0);
    try t.expect(lm.height_px > 0);
}

test "face rejects bad pixel sizes" {
    const t = std.testing;
    if (!tables.FreeTypeApi.isAvailable() or !tables.FontconfigApi.isAvailable()) return;
    var d = try discovery.Discovery.init();
    defer d.deinit();
    var ft = try FreeType.init();
    defer ft.deinit();
    var match = try d.findSans();
    var face = try Face.open(&ft, &match, 1);
    defer face.deinit();
    try t.expectError(error.BadPixelSize, face.setPixelSize(0));
    try t.expectError(error.BadPixelSize, face.setPixelSize(512));
}
