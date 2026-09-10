//! HarfBuzz shaping over a FreeType face (frame path: zero allocation).
//!
//! `Shaper` borrows a sized `face.Face` and reuses one HarfBuzz buffer, so
//! `shape()`/`measure()` allocate nothing after `init`. Positions come from
//! the `hb-ft` bridge (`hb_ft_font_create_referenced`), which tracks the
//! FreeType size: call `setPixelSize()` here (not on the face directly) so
//! HarfBuzz is re-synced via `hb_ft_font_changed` before the next shape.
//!
//! Units: with the `hb-ft` bridge synced to a pixel size, advances and
//! offsets arrive in 26.6 fixed point, hence the `/ 64` below. The
//! calibration test pins this against raw FreeType advances and will fail
//! loudly if a HarfBuzz build ever reports different units.

const std = @import("std");
const dl = @import("../platform/dl.zig");
const tb = @import("../text/bindings.zig");
const limits = @import("../core/limits.zig");
const tables = @import("tables.zig");
const face_mod = @import("face.zig");

/// One shaped glyph: where the pen moves and where the ink sits.
pub const ShapedGlyph = struct {
    glyph_id: u32,
    /// Pen advance in pixels (26.6 hb units / 64).
    advance_px: f32,
    /// Ink offset in pixels relative to the pen dot.
    offset_px: [2]f32,
    /// Byte index of the source cluster.
    cluster: u32,
};

pub const ShapeResult = struct {
    glyphs: []const ShapedGlyph,
    /// Total pen advance: what `measure()` returns and what the renderer
    /// must use for placement so measurement matches output.
    advance_px: f32,
    /// True when the run exceeded `MAX_GLYPHS_PER_RUN` and was cut.
    truncated: bool,
};

pub const Shaper = struct {
    lib: dl.Library,
    hb: tables.HarfBuzzApi,
    font: *tb.hb_font_t,
    buffer: *tb.hb_buffer_t,
    face: *face_mod.Face,
    storage: [limits.MAX_GLYPHS_PER_RUN]ShapedGlyph = undefined,

    pub fn init(f: *face_mod.Face) !Shaper {
        var lib = dl.Library.open(tables.harfbuzz_lib_names) orelse return error.HarfBuzzUnavailable;
        errdefer lib.close();
        const hb = tables.HarfBuzzApi.load(lib) orelse return error.HarfBuzzSymbolsMissing;
        const font = hb.ft_font_create_referenced(f.handle) orelse return error.HarfBuzzFontFailed;
        errdefer hb.font_destroy(font);
        const buffer = hb.buffer_create() orelse return error.HarfBuzzBufferFailed;
        return .{ .lib = lib, .hb = hb, .font = font, .buffer = buffer, .face = f };
    }

    pub fn deinit(self: *Shaper) void {
        self.hb.buffer_destroy(self.buffer);
        self.hb.font_destroy(self.font);
        self.lib.close();
    }

    /// Size the face and re-sync HarfBuzz to it. Always size through here.
    /// Skips both calls when already at `px` (hot path: same size repeats
    /// across nodes every frame).
    pub fn setPixelSize(self: *Shaper, px: u32) !void {
        if (px == self.face.pixel_size) return;
        try self.face.setPixelSize(px);
        self.hb.ft_font_changed(self.font);
    }

    pub fn shape(self: *Shaper, text: []const u8) ShapeResult {
        return self.shapeDir(text, .HB_DIRECTION_INVALID);
    }

    pub fn shapeDir(self: *Shaper, text: []const u8, dir: tb.hb_direction_t) ShapeResult {
        self.hb.buffer_reset(self.buffer);
        if (dir != .HB_DIRECTION_INVALID) {
            self.hb.buffer_set_direction(self.buffer, dir);
        }
        const capped = if (text.len > std.math.maxInt(c_int)) text[0..std.math.maxInt(c_int)] else text;
        self.hb.buffer_add_utf8(self.buffer, capped.ptr, @intCast(capped.len), 0, -1);
        self.hb.buffer_guess_segment_properties(self.buffer);
        self.hb.shape(self.font, self.buffer, null, 0);

        var info_len: c_uint = 0;
        var pos_len: c_uint = 0;
        const infos = self.hb.buffer_get_glyph_infos(self.buffer, &info_len);
        const positions = self.hb.buffer_get_glyph_positions(self.buffer, &pos_len);
        const count = @min(info_len, pos_len);
        const kept = @min(count, limits.MAX_GLYPHS_PER_RUN);

        var total: f32 = 0;
        var i: u32 = 0;
        while (i < kept) : (i += 1) {
            const adv = @as(f32, @floatFromInt(positions[i].x_advance)) / 64.0;
            total += adv;
            self.storage[i] = .{
                .glyph_id = infos[i].codepoint,
                .advance_px = adv,
                .offset_px = .{
                    @as(f32, @floatFromInt(positions[i].x_offset)) / 64.0,
                    @as(f32, @floatFromInt(positions[i].y_offset)) / 64.0,
                },
                .cluster = infos[i].cluster,
            };
        }
        return .{
            .glyphs = self.storage[0..kept],
            .advance_px = total,
            .truncated = count > kept,
        };
    }

    /// Advance width of a run. Same numbers the renderer places with, so
    /// measurement matches output by construction.
    pub fn measure(self: *Shaper, text: []const u8) f32 {
        return self.shape(text).advance_px;
    }
};

/// Build a sized sans shaper for tests. Caller owns all three; teardown in
/// reverse order: shaper, face, freetype, discovery.
pub fn testShaper(
    d: *discovery_mod.Discovery,
    ft: *face_mod.FreeType,
    face_out: *face_mod.Face,
    shaper_out: *Shaper,
    px: u32,
) !void {
    var match = try d.findSans();
    face_out.* = try face_mod.Face.open(ft, &match, 1);
    errdefer face_out.deinit();
    shaper_out.* = try Shaper.init(face_out);
    errdefer shaper_out.deinit();
    try shaper_out.setPixelSize(px);
}

const discovery_mod = @import("discovery.zig");

test "shaper calibration: hb advances match freetype advances" {
    const t = std.testing;
    if (!tables.HarfBuzzApi.isAvailable() or !tables.FreeTypeApi.isAvailable() or !tables.FontconfigApi.isAvailable()) return;
    var d = try discovery_mod.Discovery.init();
    defer d.deinit();
    var ft = try face_mod.FreeType.init();
    defer ft.deinit();
    var fc: face_mod.Face = undefined;
    var sh: Shaper = undefined;
    try testShaper(&d, &ft, &fc, &sh, 16);
    defer sh.deinit();
    defer fc.deinit();

    const run = sh.shape("Hello");
    try t.expect(!run.truncated);
    try t.expectEqual(@as(usize, 5), run.glyphs.len);

    var ft_sum: f32 = 0;
    for ("Hello") |byte| {
        ft_sum += try fc.advancePx(byte);
    }
    std.debug.print("hb total={d:.3} ft total={d:.3}\n", .{ run.advance_px, ft_sum });
    try t.expectApproxEqAbs(ft_sum, run.advance_px, 1.0);
    try t.expectApproxEqAbs(run.advance_px, sh.measure("Hello"), 0.0001);
}

test "shaping fixtures: ligature, rtl, empty" {
    const t = std.testing;
    if (!tables.HarfBuzzApi.isAvailable() or !tables.FreeTypeApi.isAvailable() or !tables.FontconfigApi.isAvailable()) return;
    var d = try discovery_mod.Discovery.init();
    defer d.deinit();
    var ft = try face_mod.FreeType.init();
    defer ft.deinit();
    var fc: face_mod.Face = undefined;
    var sh: Shaper = undefined;
    try testShaper(&d, &ft, &fc, &sh, 16);
    defer sh.deinit();
    defer fc.deinit();

    // "fi" kerns/ligates in most text faces: never more glyphs than chars.
    const fi = sh.shape("fi");
    try t.expect(fi.glyphs.len <= 2 and fi.glyphs.len >= 1);
    try t.expect(fi.advance_px > 0);

    // RTL text shapes without errors; advances stay sane.
    const ar = sh.shapeDir("مرحبا", .HB_DIRECTION_RTL);
    try t.expect(ar.glyphs.len > 0);
    try t.expect(ar.advance_px > 0);

    const empty = sh.shape("");
    try t.expectEqual(@as(usize, 0), empty.glyphs.len);
    try t.expectEqual(@as(f32, 0), empty.advance_px);
    try t.expect(!empty.truncated);
}
