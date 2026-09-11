//! Real HarfBuzz shaping backend for `shape.zig`'s `ShapeAdapter` seam.
//!
//! Built on the vendored `harfbuzz` binding module (`src/harfbuzz/`, exposed
//! as the `harfbuzz` build module): blobs, faces, fonts and buffers go through
//! `hb.Blob` / `hb.Face` / `hb.Font` / `hb.Buffer`, and shaping through
//! `hb.shape`. Only APIs the wrapper does not surface are called through
//! `hb.c.hb_*` (face creation/upem); the font queries the wrapper also lacks
//! live as thin methods in `harfbuzz/font.zig` instead of hand-written externs
//! here.
//!
//! Ownership: `Backend.addFont` copies the font bytes and owns the copy until
//! `deinit`, which destroys HarfBuzz fonts/faces *before* freeing those bytes.
//! Values returned by `Backend.adapter()` borrow the backend: the backend must
//! outlive the adapter and every shaping call through it.
//!
//! Failure policy: the vtable error set is fixed by `shape.zig`
//! (`ShapeError`) and has no "font not found" member, so shaping through an
//! unregistered font id panics with a descriptive message instead of
//! silently returning an empty run. `fallback_font` returns `null` (font
//! fallback is not wired to a font database yet), so the only valid id is the
//! one returned by `primary_font` after a successful `addFont`.
//!
//! Wiring point in `shape.zig`: replace `CharmapAdapter` with
//! `Backend.adapter()`; `shapeFallback`/`shapeRun` already implement plan
//! caching, tab rewrite, missing-glyph collection and end adjustment around
//! this vtable.

const std = @import("std");
const attrs_mod = @import("attrs.zig");
const shape_mod = @import("shape.zig");
const hb = @import("harfbuzz");

/// Runtime HarfBuzz version string, e.g. `"14.1.0"`.
pub fn version() []const u8 {
    return hb.versionString();
}

// ---------------------------------------------------------------------------
// Backend
// ---------------------------------------------------------------------------

/// A registered font: a copy of the font bytes plus the HarfBuzz objects
/// built from them. `ascent`/`descent` are EM units (descent positive, per
/// `shape.rs:157` advanced-path convention); `monospace_width` is the
/// caller-supplied advance of a space in EM units.
pub const FontEntry = struct {
    id: u32,
    blob: []u8,
    face: hb.Face,
    font: hb.Font,
    upem: u32,
    ascent: f32,
    descent: f32,
    monospace_width: ?f32,
    monospaced: bool,
    italic_or_oblique: bool,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    buffer: hb.Buffer,
    entries: std.ArrayList(FontEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        const buffer = hb.Buffer.create() catch return error.OutOfMemory;
        return .{ .allocator = allocator, .buffer = buffer };
    }

    pub fn deinit(self: *Backend) void {
        for (self.entries.items) |*e| self.destroyEntry(e);
        self.entries.deinit(self.allocator);
        self.buffer.destroy();
    }

    /// Register font `bytes` (face `index` inside a collection) under `id`.
    /// The bytes are copied; the caller keeps ownership of `bytes`.
    ///
    /// `monospace_em_width` is the advance of a space in EM units supplied by
    /// the caller (see `FontEntry.monospace_width`); passing `null` marks the
    /// font as proportional. Registering an existing `id` replaces the old
    /// entry.
    pub fn addFont(
        self: *Backend,
        id: u32,
        bytes: []const u8,
        index: u32,
        italic_or_oblique: bool,
        monospace_em_width: ?f32,
    ) !void {
        var entry = try self.makeEntry(id, bytes, index, italic_or_oblique, monospace_em_width);
        for (self.entries.items) |*old| {
            if (old.id == id) {
                self.destroyEntry(old);
                old.* = entry;
                return;
            }
        }
        self.entries.append(self.allocator, entry) catch |err| {
            self.destroyEntry(&entry);
            return err;
        };
    }

    fn makeEntry(
        self: *Backend,
        id: u32,
        bytes: []const u8,
        index: u32,
        italic_or_oblique: bool,
        monospace_em_width: ?f32,
    ) !FontEntry {
        if (bytes.len == 0 or bytes.len > std.math.maxInt(c_uint)) return error.InvalidFont;
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);

        // READONLY: the blob does not own or modify `owned`; the backend
        // frees it in deinit() after the face is destroyed.
        var blob = hb.Blob.create(owned, .readonly) catch return error.OutOfMemory;
        defer blob.destroy();

        // No wrapper constructor exists for `hb_face_create`.
        var face = hb.Face{
            .handle = hb.c.hb_face_create(blob.handle, @intCast(index)) orelse
                return error.InvalidFont,
        };
        errdefer face.destroy();

        const upem = hb.c.hb_face_get_upem(face.handle);
        if (upem == 0) return error.InvalidFont;

        var font = hb.Font.create(face) catch return error.OutOfMemory;
        errdefer font.destroy();
        std.debug.assert(font.setOtFuncs());
        font.setScale(upem, upem);

        // Scale read-back doubles as an ABI smoke test for set/get scale.
        var x_scale: c_int = 0;
        var y_scale: c_int = 0;
        font.getScale(&x_scale, &y_scale);
        std.debug.assert(x_scale == @as(c_int, @intCast(upem)) and
            y_scale == @as(c_int, @intCast(upem)));

        const upem_f: f32 = @floatFromInt(upem);
        var ascent: f32 = 0.8;
        var descent: f32 = 0.2;
        var extents: hb.c.hb_font_extents_t = undefined;
        if (font.getHExtents(&extents)) {
            ascent = @as(f32, @floatFromInt(extents.ascender)) / upem_f;
            // HarfBuzz reports the descender negative; `shape.rs:157` negates
            // the font descender for the advanced shaping path, so store the
            // positive EM descent the layout engine expects.
            descent = -@as(f32, @floatFromInt(extents.descender)) / upem_f;
        }

        return .{
            .id = id,
            .blob = owned,
            .face = face,
            .font = font,
            .upem = upem,
            .ascent = ascent,
            .descent = descent,
            .monospace_width = monospace_em_width,
            .monospaced = monospace_em_width != null,
            .italic_or_oblique = italic_or_oblique,
        };
    }

    fn destroyEntry(self: *Backend, entry: *FontEntry) void {
        entry.font.destroy();
        entry.face.destroy();
        self.allocator.free(entry.blob);
    }

    fn entryFor(self: *Backend, font: shape_mod.FontId) *FontEntry {
        for (self.entries.items) |*e| {
            if (e.id == font) return e;
        }
        std.debug.panic("hb_backend: font id {d} is not registered; call addFont first", .{font});
    }

    /// Borrowing adapter over this backend. `fallback_font` is not wired yet
    /// and always returns `null`; `primary_font` is the first registered
    /// entry's id (0 when the backend is empty).
    pub fn adapter(self: *Backend) shape_mod.ShapeAdapter {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ---------------------------------------------------------------------------
// ShapeAdapter vtable
// ---------------------------------------------------------------------------

const vtable: shape_mod.ShapeAdapter.VTable = .{
    .shape_run = shapeRunFn,
    .map_glyph = mapGlyphFn,
    .advance_em = advanceEmFn,
    .font_metrics = fontMetricsFn,
    .primary_font = primaryFontFn,
    .fallback_font = fallbackFontFn,
    .probe_pair = probePairFn,
};

fn shapeRunImpl(
    self: *Backend,
    alloc: std.mem.Allocator,
    font: shape_mod.FontId,
    text: []const u8,
    rtl: bool,
) shape_mod.ShapeError![]shape_mod.ShapedRunGlyph {
    if (text.len == 0) return alloc.alloc(shape_mod.ShapedRunGlyph, 0);
    std.debug.assert(text.len <= std.math.maxInt(c_int));
    const entry = self.entryFor(font);

    self.buffer.reset();
    self.buffer.setDirection(if (rtl) .rtl else .ltr);
    self.buffer.addUTF8(text);
    self.buffer.guessSegmentProperties();
    hb.shape(entry.font, self.buffer, null);

    const len = self.buffer.getLength();
    const infos = self.buffer.getGlyphInfos();
    // `hb_buffer_get_glyph_positions` only returns NULL from a buffer message
    // callback (never our case) or for an empty buffer; the old extern-based
    // code asserted on a length mismatch and skipped the copy loop instead of
    // indexing a null pointer.
    const positions_opt = self.buffer.getGlyphPositions();
    std.debug.assert(len == infos.len and (positions_opt != null or len == 0));

    var out: std.ArrayList(shape_mod.ShapedRunGlyph) = .empty;
    errdefer out.deinit(alloc);
    const count: usize = @intCast(len);
    try out.ensureTotalCapacity(alloc, count);
    if (positions_opt) |positions| {
        std.debug.assert(count == positions.len);
        const upem_f: f32 = @floatFromInt(entry.upem);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const info = infos[i];
            const pos = positions[i];
            // HarfBuzz emits horizontal runs in visual order (RTL clusters run
            // right-to-left), matching the CharmapAdapter convention that
            // `adjustGlyphEnds` and the BiDi reorder rely on.
            out.appendAssumeCapacity(.{
                .glyph_id = if (info.codepoint > std.math.maxInt(u16)) 0 else @intCast(info.codepoint),
                .cluster = info.cluster,
                .x_advance = @as(f32, @floatFromInt(pos.x_advance)) / upem_f,
                .y_advance = @as(f32, @floatFromInt(pos.y_advance)) / upem_f,
                .x_offset = @as(f32, @floatFromInt(pos.x_offset)) / upem_f,
                .y_offset = @as(f32, @floatFromInt(pos.y_offset)) / upem_f,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn shapeRunFn(
    ptr: *anyopaque,
    alloc: std.mem.Allocator,
    font: shape_mod.FontId,
    text: []const u8,
    rtl: bool,
) shape_mod.ShapeError![]shape_mod.ShapedRunGlyph {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    return shapeRunImpl(self, alloc, font, text, rtl);
}

fn mapGlyphImpl(self: *Backend, font: shape_mod.FontId, cp: u21) u16 {
    const entry = self.entryFor(font);
    const glyph = entry.font.getNominalGlyph(cp) orelse return 0;
    // The seam stores glyph ids as u16; oversized ids are reported missing.
    if (glyph > std.math.maxInt(u16)) return 0;
    return @intCast(glyph);
}

fn mapGlyphFn(ptr: *anyopaque, font: shape_mod.FontId, cp: u21) u16 {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    return mapGlyphImpl(self, font, cp);
}

fn advanceEmFn(ptr: *anyopaque, font: shape_mod.FontId, glyph_id: u16) f32 {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    const entry = self.entryFor(font);
    const advance = entry.font.getHAdvance(glyph_id);
    return @as(f32, @floatFromInt(advance)) / @as(f32, @floatFromInt(entry.upem));
}

fn fontMetricsFn(ptr: *anyopaque, font: shape_mod.FontId) shape_mod.ShapingFontMetrics {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    const entry = self.entryFor(font);
    return .{
        .ascent = entry.ascent,
        .descent = entry.descent,
        .monospace_width = entry.monospace_width,
        .italic_or_oblique = entry.italic_or_oblique,
        .monospaced = entry.monospaced,
    };
}

fn primaryFontFn(ptr: *anyopaque) shape_mod.FontId {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    if (self.entries.items.len == 0) return 0;
    return self.entries.items[0].id;
}

/// Font fallback is not wired to a font database yet: always exhausted.
fn fallbackFontFn(ptr: *anyopaque, script: shape_mod.Script, attempt: usize) ?shape_mod.FontId {
    _ = ptr;
    _ = script;
    _ = attempt;
    return null;
}

fn probePairFn(ptr: *anyopaque, font: shape_mod.FontId, c1: u21, c2: u21) shape_mod.ProbeResult {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    const charmap_ids: [2]u16 = .{ mapGlyphImpl(self, font, c1), mapGlyphImpl(self, font, c2) };
    var pair: [8]u8 = undefined;
    var n: usize = 0;
    n += @as(usize, std.unicode.utf8Encode(c1, pair[n..]) catch 0);
    n += @as(usize, std.unicode.utf8Encode(c2, pair[n..]) catch 0);
    if (n == 0) return .{ .count = 0, .shaped_ids = .{ 0, 0 }, .charmap_ids = charmap_ids };

    const shaped = shapeRunImpl(self, self.allocator, font, pair[0..n], false) catch {
        // Conservative: count < 2 makes `probeKeepsPair` keep the pair joined.
        return .{ .count = 0, .shaped_ids = .{ 0, 0 }, .charmap_ids = charmap_ids };
    };
    defer self.allocator.free(shaped);

    var result: shape_mod.ProbeResult = .{ .count = shaped.len, .charmap_ids = charmap_ids };
    if (shaped.len >= 1) result.shaped_ids[0] = shaped[0].glyph_id;
    if (shaped.len >= 2) result.shaped_ids[1] = shaped[1].glyph_id;
    return result;
}

// ===========================================================================
// Tests
// ===========================================================================

/// Load a checked-in font fixture from the package `tests/fonts` directory.
/// Returns `error.SkipZigTest` only when the fixture file is absent.
fn readFixture(alloc: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    const candidates = [_][]const u8{
        "tests/fonts/" ++ name,
        "../tests/fonts/" ++ name,
        "src/../tests/fonts/" ++ name,
    };
    for (candidates) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(1 << 24))) |bytes| {
            return bytes;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
    }
    return error.SkipZigTest;
}

fn addFixtureFont(
    backend: *Backend,
    alloc: std.mem.Allocator,
    comptime name: []const u8,
    id: shape_mod.FontId,
    italic_or_oblique: bool,
    mono_width: ?f32,
) !void {
    const bytes = try readFixture(alloc, name);
    defer alloc.free(bytes);
    try backend.addFont(id, bytes, 0, italic_or_oblique, mono_width);
}

fn testAttrsList(alloc: std.mem.Allocator) !attrs_mod.AttrsList {
    var defaults = attrs_mod.Attrs.init(alloc);
    defer defaults.deinit();
    return attrs_mod.AttrsList.init(alloc, &defaults);
}

test "HarfBuzz link probe: version string and addFont" {
    try std.testing.expect(version().len > 0);

    const alloc = std.testing.allocator;
    const bytes = try readFixture(alloc, "Inter-Regular.ttf");
    defer alloc.free(bytes);

    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try backend.addFont(shape_mod.PRIMARY_FONT_ID, bytes, 0, false, null);
    try std.testing.expectEqual(@as(usize, 1), backend.entries.items.len);
    const entry = backend.entries.items[0];
    try std.testing.expect(entry.upem > 0);
    try std.testing.expect(entry.ascent > 0);
    try std.testing.expect(entry.descent > 0);
    try std.testing.expect(!entry.monospaced);
    try std.testing.expect(entry.monospace_width == null);
}

test "translated hb_glyph_info_t/hb_glyph_position_t ABI sizes" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(hb.c.hb_glyph_info_t));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(hb.c.hb_glyph_position_t));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(hb.c.hb_font_extents_t));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(hb.c.hb_glyph_info_t, "codepoint"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(hb.c.hb_glyph_info_t, "cluster"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(hb.c.hb_glyph_position_t, "x_advance"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(hb.c.hb_glyph_position_t, "y_offset"));
}

test "Inter LTR: shapeRun yields 5 advancing glyphs for Hello" {
    const alloc = std.testing.allocator;
    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try addFixtureFont(&backend, alloc, "Inter-Regular.ttf", shape_mod.PRIMARY_FONT_ID, false, null);

    const adapter = backend.adapter();
    const glyphs = try adapter.shapeRun(alloc, shape_mod.PRIMARY_FONT_ID, "Hello", false);
    defer alloc.free(glyphs);

    try std.testing.expectEqual(@as(usize, 5), glyphs.len);
    var prev_cluster: ?usize = null;
    for (glyphs) |g| {
        try std.testing.expect(g.glyph_id != 0);
        try std.testing.expect(g.x_advance > 0);
        try std.testing.expectEqual(@as(f32, 0), g.y_advance);
        if (prev_cluster) |prev| try std.testing.expect(g.cluster > prev);
        prev_cluster = g.cluster;
    }
    try std.testing.expectEqual(@as(usize, 0), glyphs[0].cluster);
    try std.testing.expectEqual(@as(usize, 4), glyphs[4].cluster);
}

test "vendored harfbuzz wrapper: Inter Hello shapes to 5 glyphs, adapter parity" {
    const alloc = std.testing.allocator;
    const bytes = try readFixture(alloc, "Inter-Regular.ttf");
    defer alloc.free(bytes);

    // Drive the wrapper's high-level API directly: Blob -> Face -> Font ->
    // Buffer -> shape.
    var blob = try hb.Blob.create(bytes, .readonly);
    defer blob.destroy();
    var face = hb.Face{
        .handle = hb.c.hb_face_create(blob.handle, 0) orelse
            return error.SkipZigTest,
    };
    defer face.destroy();
    var font = try hb.Font.create(face);
    defer font.destroy();
    try std.testing.expect(font.setOtFuncs());
    const upem = hb.c.hb_face_get_upem(face.handle);
    font.setScale(upem, upem);

    var buffer = try hb.Buffer.create();
    defer buffer.destroy();
    buffer.addUTF8("Hello");
    buffer.guessSegmentProperties();
    hb.shape(font, buffer, null);

    const infos = buffer.getGlyphInfos();
    try std.testing.expectEqual(@as(usize, 5), infos.len);
    for (infos) |info| try std.testing.expect(info.codepoint != 0);
    const positions = buffer.getGlyphPositions() orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 5), positions.len);
    for (positions) |pos| try std.testing.expect(pos.x_advance > 0);

    // The adapter must produce the same glyph ids in the same order.
    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try addFixtureFont(&backend, alloc, "Inter-Regular.ttf", shape_mod.PRIMARY_FONT_ID, false, null);
    const shaped = try backend.adapter().shapeRun(alloc, shape_mod.PRIMARY_FONT_ID, "Hello", false);
    defer alloc.free(shaped);
    try std.testing.expectEqual(@as(usize, 5), shaped.len);
    for (shaped, infos) |glyph, info| {
        try std.testing.expectEqual(@as(u32, glyph.glyph_id), info.codepoint);
    }
}

test "NotoSansArabic RTL: contextual forms, visual order" {
    const alloc = std.testing.allocator;
    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try addFixtureFont(&backend, alloc, "NotoSansArabic.ttf", shape_mod.PRIMARY_FONT_ID, false, null);

    const adapter = backend.adapter();
    // "مرحبا" (marhaba). Observed with the checked-in font + HarfBuzz
    // 14.1.0: exactly 5 contextual forms (uniFE8E FE92 FEA3 FEAE FEE3), no
    // required ligature, emitted in visual order with byte clusters 8..0.
    const text = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}";
    const glyphs = try adapter.shapeRun(alloc, shape_mod.PRIMARY_FONT_ID, text, true);
    defer alloc.free(glyphs);

    try std.testing.expectEqual(@as(usize, 5), glyphs.len);
    for (glyphs) |g| {
        try std.testing.expect(g.glyph_id != 0);
        try std.testing.expect(g.x_advance > 0);
    }
    var prev_cluster: usize = std.math.maxInt(usize);
    for (glyphs) |g| {
        try std.testing.expect(g.cluster < prev_cluster);
        prev_cluster = g.cluster;
    }
    try std.testing.expectEqual(@as(usize, 8), glyphs[0].cluster);
    try std.testing.expectEqual(@as(usize, 0), glyphs[4].cluster);
}

test "map_glyph, advance_em and font_metrics for Inter" {
    const alloc = std.testing.allocator;
    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try addFixtureFont(&backend, alloc, "Inter-Regular.ttf", shape_mod.PRIMARY_FONT_ID, false, null);

    const adapter = backend.adapter();
    const glyph_a = adapter.mapGlyph(shape_mod.PRIMARY_FONT_ID, 'A');
    try std.testing.expect(glyph_a != 0);
    try std.testing.expect(adapter.advanceEm(shape_mod.PRIMARY_FONT_ID, glyph_a) > 0);
    // Missing codepoints map to .notdef (0).
    try std.testing.expectEqual(@as(u16, 0), adapter.mapGlyph(shape_mod.PRIMARY_FONT_ID, 0x10FFFD));

    const metrics = adapter.fontMetrics(shape_mod.PRIMARY_FONT_ID);
    try std.testing.expect(metrics.ascent > 0);
    try std.testing.expect(metrics.descent > 0);
    try std.testing.expect(metrics.monospace_width == null);
    try std.testing.expect(!metrics.monospaced);
    try std.testing.expect(!metrics.italic_or_oblique);
    try std.testing.expectEqual(shape_mod.PRIMARY_FONT_ID, adapter.primaryFont());
    try std.testing.expectEqual(@as(?shape_mod.FontId, null), adapter.fallbackFont(.latin, 0));
}

test "probe_pair reports shaped and charmap ids" {
    const alloc = std.testing.allocator;
    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try addFixtureFont(&backend, alloc, "Inter-Regular.ttf", shape_mod.PRIMARY_FONT_ID, false, null);

    const adapter = backend.adapter();
    const probe = adapter.probePair(shape_mod.PRIMARY_FONT_ID, 'a', 'b');
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expect(probe.shaped_ids[0] != 0);
    try std.testing.expect(probe.shaped_ids[1] != 0);
    try std.testing.expectEqual(probe.charmap_ids[0], probe.shaped_ids[0]);
    try std.testing.expectEqual(probe.charmap_ids[1], probe.shaped_ids[1]);
}

test "integration: ShapeLine.build + layoutToBuffer over HarfBuzz" {
    const alloc = std.testing.allocator;
    var backend = try Backend.init(alloc);
    defer backend.deinit();
    try addFixtureFont(&backend, alloc, "Inter-Regular.ttf", shape_mod.PRIMARY_FONT_ID, false, null);

    var attrs = try testAttrsList(alloc);
    defer attrs.deinit();
    var buf = shape_mod.ShapeBuffer.init();
    defer buf.deinit(alloc);
    var line = shape_mod.ShapeLine{};
    defer line.deinit(alloc);

    try line.build(alloc, backend.adapter(), &buf, "hello world", &attrs, .advanced, 4, .left_to_right);
    try std.testing.expectEqual(@as(usize, 1), line.spans.len);
    // "hello", the peeled space, "world".
    try std.testing.expectEqual(@as(usize, 3), line.spans[0].words.len);
    var glyph_count: usize = 0;
    for (line.spans[0].words) |w| glyph_count += w.glyphs.len;
    try std.testing.expectEqual(@as(usize, 11), glyph_count);

    var out: std.ArrayList(shape_mod.LayoutLine) = .empty;
    defer {
        for (out.items) |*l| l.deinit();
        out.deinit(alloc);
    }
    try line.layoutToBuffer(alloc, &buf, 16, null, .none, .{ .none = {} }, null, &out, null, .disabled);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].glyphs.items.len > 0);
    try std.testing.expect(out.items[0].w > 0);
}
