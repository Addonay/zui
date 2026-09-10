//! System font stack: discovery, rasterization, shaping, atlas.
//!
//! Pipeline (all runtime-`dlopen`ed, never linked):
//! ```text
//! Discovery (fontconfig) → Face (freetype) → Shaper (harfbuzz) → Atlas
//!      family → file          file → bitmaps     text → advances   glyph cache
//! ```
//!
//! Frame path: `Shaper.shape`/`measure` and `Atlas.get`/`put` allocate
//! nothing. `Collection.measureText` is what layout calls; the painter
//! shapes the same way and places with the same advances, so measurement
//! matches output by construction. Without the system libs every
//! constructor returns an `error.*Unavailable` and integration tests skip,
//! so headless CI stays green.

const std = @import("std");
pub const tables = @import("tables.zig");
pub const discovery = @import("discovery.zig");
pub const face = @import("face.zig");
pub const shaper = @import("shaper.zig");
pub const atlas = @import("atlas.zig");

pub const Discovery = discovery.Discovery;
pub const Match = discovery.Match;
pub const Weight = discovery.Weight;
pub const Slant = discovery.Slant;
pub const FreeType = face.FreeType;
pub const Face = face.Face;
pub const Raster = face.Raster;
pub const Shaper = shaper.Shaper;
pub const ShapeResult = shaper.ShapeResult;
pub const Atlas = atlas.Atlas;

/// One owned copy of the whole stack. Init-time only; frames borrow it.
///
/// ~1.1MB with the atlas pixel pool inline: heap-allocate (App embeds it
/// behind a pointer; tests use the allocator). Never stack a Collection
/// with a Frame and a Scene in one function — see the "hot frame structs
/// stay within stack budget" test in elements/painter.zig.
///
/// Holds both UI families (ids 1/2): `faceFor`/`shaperFor` pick mono when
/// the text style names one (e.g. `"JetBrains Mono, ..."`), sans otherwise.
/// `symbols` (id 3, optional) covers dingbats the UI faces lack (✓✦○);
/// the painter substitutes it per glyph when shaping yields `.notdef`.
pub const Collection = struct {
    discovery_state: Discovery,
    freetype: FreeType,
    sans: Face,
    mono: Face,
    symbols: ?Face,
    sans_shaper: Shaper,
    mono_shaper: Shaper,
    glyphs: Atlas,

    /// Candidate symbol families in preference order. Scored at init by
    /// coverage of the UI's symbol set; the best wins, the rest close.
    pub const symbol_candidates: []const [*:0]const u8 = &.{
        "Noto Sans Symbols 2",
        "Noto Sans Symbols",
        "Symbola",
        "DejaVu Sans",
    };

    /// Codepoints the UI needs beyond text faces (checkbox, badges,
    /// titlebar, empty state, middle dot).
    pub const symbol_set: []const u21 = &.{ 0x2713, 0x2726, 0x25CB, 0x00D7, 0x2014, 0x25A1, 0x25A2, 0x00B7 };

    pub fn init() !Collection {
        var discovery_state = try Discovery.init();
        errdefer discovery_state.deinit();
        var freetype = try FreeType.init();
        errdefer freetype.deinit();
        var sans_match = try discovery_state.findSans();
        var sans = try Face.open(&freetype, &sans_match, 1);
        errdefer sans.deinit();
        var mono_match = try discovery_state.findMono();
        var mono = try Face.open(&freetype, &mono_match, 2);
        errdefer mono.deinit();
        var sans_shaper = try Shaper.init(&sans);
        errdefer sans_shaper.deinit();
        var mono_shaper = try Shaper.init(&mono);
        errdefer mono_shaper.deinit();
        const symbols = pickSymbols(&discovery_state, &freetype);
        return .{
            .discovery_state = discovery_state,
            .freetype = freetype,
            .sans = sans,
            .mono = mono,
            .symbols = symbols,
            .sans_shaper = sans_shaper,
            .mono_shaper = mono_shaper,
            .glyphs = .{},
        };
    }

    /// Best-scoring symbol face, or null when nothing installed covers the
    /// set (UI then shows `.notdef` tofu for those codepoints).
    fn pickSymbols(d: *Discovery, ft: *FreeType) ?Face {
        var best: ?Face = null;
        var best_score: usize = 0;
        for (symbol_candidates) |family| {
            var match = d.find(family, .regular, .roman) catch continue;
            var candidate = Face.open(ft, &match, 3) catch continue;
            var score: usize = 0;
            for (symbol_set) |cp| {
                if (candidate.glyphIndex(cp) != 0) score += 1;
            }
            if (score > best_score) {
                if (best) |*old| old.deinit();
                best = candidate;
                best_score = score;
            } else {
                candidate.deinit();
            }
        }
        return best;
    }

    pub fn deinit(self: *Collection) void {
        self.sans_shaper.deinit();
        self.mono_shaper.deinit();
        self.sans.deinit();
        self.mono.deinit();
        if (self.symbols) |*sym| sym.deinit();
        self.freetype.deinit();
        self.discovery_state.deinit();
    }

    pub fn faceFor(self: *Collection, font_name: []const u8) *Face {
        return if (isMonoFontName(font_name)) &self.mono else &self.sans;
    }

    pub fn shaperFor(self: *Collection, font_name: []const u8) *Shaper {
        return if (isMonoFontName(font_name)) &self.mono_shaper else &self.sans_shaper;
    }

    /// Shaped advance width in pixels. Never fails: sizing is clamped and
    /// shaping falls back to a proportional estimate only if FreeType itself
    /// errors mid-frame (which it cannot do after a successful `setPixelSize`
    /// warm-up, but the layout path cannot return errors regardless).
    pub fn measureText(self: *Collection, text: []const u8, size: f32, tracking: f32, font_name: []const u8) f32 {
        const shaper_obj = self.shaperFor(font_name);
        shaper_obj.setPixelSize(sizeToPx(size)) catch {
            return estimateWidth(text, size, tracking);
        };
        const run = shaper_obj.shape(text);
        return run.advance_px + tracking * @as(f32, @floatFromInt(countCodepoints(text)));
    }
};

/// UI pixel size → integer FreeType pixel size. Pure and shared by measure
/// and paint so both sides size identically (atlas keys match).
pub fn sizeToPx(size: f32) u32 {
    const rounded = @as(i32, @intFromFloat(@round(size)));
    return @intCast(std.math.clamp(rounded, 1, 256));
}

/// Case-insensitive `"mono"` substring: matches `"JetBrains Mono, ..."`,
/// `"monospace"`, `"Noto Sans Mono"`, etc.
pub fn isMonoFontName(name: []const u8) bool {
    if (name.len < 4) return false;
    var i: usize = 0;
    while (i + 4 <= name.len) : (i += 1) {
        const s = name[i..][0..4];
        if ((s[0] == 'm' or s[0] == 'M') and
            (s[1] == 'o' or s[1] == 'O') and
            (s[2] == 'n' or s[2] == 'N') and
            (s[3] == 'o' or s[3] == 'O'))
        {
            return true;
        }
    }
    return false;
}

fn countCodepoints(text: []const u8) usize {
    var n: usize = 0;
    for (text) |byte| {
        if ((byte & 0xc0) != 0x80) n += 1;
    }
    return n;
}

/// Last-resort width when sizing fails mid-frame. Mirrors the bitmap
/// fallback advance (0.75em) so output degrades to the old estimate.
fn estimateWidth(text: []const u8, size: f32, tracking: f32) f32 {
    return @as(f32, @floatFromInt(countCodepoints(text))) * (size * 0.75 + tracking);
}

test {
    _ = @import("tables.zig");
    _ = @import("discovery.zig");
    _ = @import("face.zig");
    _ = @import("shaper.zig");
    _ = @import("atlas.zig");
}

test "mono name detection" {
    const t = std.testing;
    try t.expect(isMonoFontName("JetBrains Mono, SF Mono, monospace"));
    try t.expect(isMonoFontName("monospace"));
    try t.expect(isMonoFontName("Noto Sans MONO"));
    try t.expect(!isMonoFontName("Inter, sans-serif"));
    try t.expect(!isMonoFontName(""));
    try t.expect(!isMonoFontName("mon"));
}

test "sizeToPx rounds and clamps" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 14), sizeToPx(14));
    try t.expectEqual(@as(u32, 14), sizeToPx(13.6));
    try t.expectEqual(@as(u32, 1), sizeToPx(0.2));
    try t.expectEqual(@as(u32, 256), sizeToPx(999));
}

test "end to end: shape, rasterize, cache, measure" {
    const t = std.testing;
    if (!tables.FontconfigApi.isAvailable() or !tables.FreeTypeApi.isAvailable() or !tables.HarfBuzzApi.isAvailable()) return;

    // Heap-allocated: Collection.init() needs ~8.7MB of Debug frame (see
    // the "hot frame structs stay within stack budget" test in
    // elements/painter.zig); keep test frames small.
    const stack = try t.allocator.create(Collection);
    defer t.allocator.destroy(stack);
    stack.* = try Collection.init();
    defer stack.deinit();
    try stack.sans_shaper.setPixelSize(16);

    // 1. Shape real UI copy.
    const run = stack.sans_shaper.shape("Hello, world!");
    try t.expect(!run.truncated);
    try t.expect(run.glyphs.len > 0);
    try t.expect(run.advance_px > 0);

    // 2. Every shaped glyph rasterizes and caches; second pass hits.
    for (run.glyphs) |g| {
        const key = atlas.AtlasKey{ .face_id = stack.sans.id, .glyph_id = g.glyph_id, .size_px = 16 };
        if (stack.glyphs.get(key) == null) {
            const raster = try stack.sans.rasterizeGlyphId(g.glyph_id);
            _ = try stack.glyphs.put(key, &raster, false);
        }
    }
    const misses_before = stack.glyphs.misses;
    for (run.glyphs) |g| {
        const key = atlas.AtlasKey{ .face_id = stack.sans.id, .glyph_id = g.glyph_id, .size_px = 16 };
        try t.expect(stack.glyphs.get(key) != null);
    }
    // No new misses on the second pass: the working set stuck.
    try t.expectEqual(misses_before, stack.glyphs.misses);

    // 3. Cached advances track the shaped advances. They are not bit-exact
    // by design: shaping yields unhinted fractional advances (kerning
    // included) while rasterized bitmaps are hinted to integer pixels.
    // Positioned runs MUST place with the shaped advances (and `measure()`
    // returns exactly those); the cached advance is a fallback for
    // unshaped/single-glyph use. Tolerances below catch unit mistakes
    // (e.g. a wrong 26.6 divisor is off by 64x) without overfitting.
    var cached_sum: f32 = 0;
    for (run.glyphs) |g| {
        const key = atlas.AtlasKey{ .face_id = stack.sans.id, .glyph_id = g.glyph_id, .size_px = 16 };
        const cached = stack.glyphs.get(key).?.advance_px;
        try t.expectApproxEqAbs(g.advance_px, cached, 0.6);
        cached_sum += cached;
    }
    try t.expectApproxEqAbs(run.advance_px, cached_sum, 1.5);
    try t.expectApproxEqAbs(run.advance_px, stack.sans_shaper.measure("Hello, world!"), 0.0001);
}

test "measureText matches shaped advances plus tracking" {
    const t = std.testing;
    if (!tables.FontconfigApi.isAvailable() or !tables.FreeTypeApi.isAvailable() or !tables.HarfBuzzApi.isAvailable()) return;

    // Heap-allocated: see "end to end" above.
    const stack = try t.allocator.create(Collection);
    defer t.allocator.destroy(stack);
    stack.* = try Collection.init();
    defer stack.deinit();

    const text = "Tasks 123";
    const tracking: f32 = 1.5;
    const px = sizeToPx(14);
    try stack.sans_shaper.setPixelSize(px);
    const want = stack.sans_shaper.measure(text) + tracking * 9;
    try t.expectApproxEqAbs(want, stack.measureText(text, 14, tracking, "Inter, sans-serif"), 0.0001);
    // Mono family routes to the mono shaper.
    try stack.mono_shaper.setPixelSize(px);
    const mono_want = stack.mono_shaper.measure(text) + tracking * 9;
    try t.expectApproxEqAbs(mono_want, stack.measureText(text, 14, tracking, "JetBrains Mono, monospace"), 0.0001);
}

/// Coverage count of `symbol_set` in a face. Test diagnostics only.
fn scoreOf(stack: *Collection) usize {
    var n: usize = 0;
    for (Collection.symbol_set) |cp| {
        if (stack.symbols.?.glyphIndex(cp) != 0) n += 1;
    }
    return n;
}

test "symbol fallback covers the ui symbol set" {
    const t = std.testing;
    if (!tables.FontconfigApi.isAvailable() or !tables.FreeTypeApi.isAvailable() or !tables.HarfBuzzApi.isAvailable()) return;

    // Heap-allocated: see "end to end" above.
    const stack = try t.allocator.create(Collection);
    defer t.allocator.destroy(stack);
    stack.* = try Collection.init();
    defer stack.deinit();
    if (stack.symbols == null) return; // nothing installed: UI shows tofu
    std.debug.print("symbols face picked for {d}/{d} UI symbols\n", .{ scoreOf(stack), Collection.symbol_set.len });

    // The sans face genuinely lacks these (why the fallback exists)...
    try t.expectEqual(@as(u32, 0), stack.sans.glyphIndex(0x2726));
    // ...and the picked fallback resolves every UI symbol.
    for (Collection.symbol_set) |cp| {
        try t.expect(stack.symbols.?.glyphIndex(cp) != 0);
    }
    // Fallback glyphs rasterize with ink at UI sizes.
    try stack.symbols.?.setPixelSize(16);
    const check = try stack.symbols.?.rasterize(0x2713);
    try t.expect(check.width > 0 and check.height > 0);
}
