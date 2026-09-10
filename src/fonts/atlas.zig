//! Glyph atlas: fixed-capacity cache from rasterized glyphs (frame path).
//!
//! Keys are `(face_id, glyph_id, pixel_size)`. Coverage bytes live in one
//! bump-allocated pool. Exhaustion clears immediately only when the atlas
//! holds no entries; otherwise the eviction defers to the next beginFrame
//! (one paint per window, after the previous frame presented) and the
//! overflowing put reports AtlasFull — already-emitted glyphs keep valid
//! pool bytes, so a frame can never corrupt its own text. Full-clear is the
//! right v0 policy: UI text re-rasterizes the working set within a frame or
//! two, and LRU bookkeeping would cost more than it saves at 1024 entries.
//! Counters expose hits/misses/evictions/drops for tuning.
//!
//! Copying honors FreeType pitch sign (bottom-up bitmaps) and 1-bit sources
//! via `face.expandMonoRow`. All methods are heap-free.

const std = @import("std");
const limits = @import("../core/limits.zig");
const face_mod = @import("face.zig");

pub const AtlasKey = struct {
    face_id: u32,
    glyph_id: u32,
    size_px: u16,
    /// Synthetic-embolden variant. Bold ink differs from regular ink, so it
    /// needs its own entry; advances are shared (shaped, unemboldened).
    bold: bool = false,
};

pub const AtlasEntry = struct {
    key: AtlasKey,
    /// Pixels into `Atlas.pixels`.
    offset: u32,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    /// Hinted advance from rasterization. Fallback for unshaped use only:
    /// positioned runs must place with `Shaper` advances (fractional,
    /// kerned), which `measure()` returns.
    advance_px: f32,
};

pub const Atlas = struct {
    entries: [limits.MAX_ATLAS_GLYPHS]AtlasEntry = undefined,
    entry_count: usize = 0,
    pixels: [limits.MAX_ATLAS_PIXELS]u8 = undefined,
    pixels_used: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    /// Overflow deferred past emitted glyphs; cleared at beginFrame, which
    /// runs once per window paint — after the previous window presented, so
    /// no live frame references the old bytes. Counts as an eviction then.
    pending_eviction: bool = false,
    /// Glyphs skipped by AtlasFull this frame (pen still advanced, so text
    /// keeps its shape and heals next frame). Observable, not silent.
    overflow_drops: u64 = 0,

    pub fn clear(self: *Atlas) void {
        self.entry_count = 0;
        self.pixels_used = 0;
        self.pending_eviction = false;
    }

    pub fn get(self: *Atlas, key: AtlasKey) ?*const AtlasEntry {
        for (self.entries[0..self.entry_count]) |*e| {
            if (e.key.face_id == key.face_id and e.key.glyph_id == key.glyph_id and e.key.size_px == key.size_px and e.key.bold == key.bold) {
                self.hits += 1;
                return e;
            }
        }
        self.misses += 1;
        return null;
    }

    pub fn coverage(self: *const Atlas, entry: *const AtlasEntry) []const u8 {
        const bytes = @as(usize, entry.width) * entry.height;
        return self.pixels[entry.offset..][0..bytes];
    }

    /// Insert a rasterized glyph. A single glyph larger than the whole pool
    /// is rejected with `error.GlyphTooLarge` instead of thrashing.
    /// Exhaustion clears immediately ONLY when the atlas holds no entries
    /// (nothing can reference the pool); otherwise it defers the eviction
    /// to the next beginFrame and returns `error.AtlasFull` WITHOUT
    /// clearing — already-emitted glyphs keep valid pool bytes, the caller
    /// skips this glyph (pen advances, shape preserved), and the frame heals
    /// next frame. A permanently oversized working set degrades to holes +
    /// a growing overflow_drops counter instead of corruption.
    /// `embolden` applies a 1px synthetic-bold dilation for semibold/bold
    /// weights (ink only; advances stay shaped so measure still matches).
    pub fn put(self: *Atlas, key: AtlasKey, raster: *const face_mod.Raster, embolden: bool) !*const AtlasEntry {
        const bytes = @as(usize, raster.width) * raster.height;
        if (bytes > limits.MAX_ATLAS_PIXELS) return error.GlyphTooLarge;
        if (self.entry_count >= limits.MAX_ATLAS_GLYPHS or self.pixels_used + bytes > limits.MAX_ATLAS_PIXELS) {
            if (self.entry_count == 0) {
                self.clear();
                self.evictions += 1;
            } else {
                self.pending_eviction = true;
                self.overflow_drops += 1;
                return error.AtlasFull;
            }
        }
        const offset = self.pixels_used;
        if (bytes > 0) {
            copyBitmap(
                self.pixels[offset..][0..bytes],
                raster.pixels,
                raster.width,
                raster.height,
                raster.pitch,
                raster.kind,
                embolden,
            );
        }
        self.pixels_used += bytes;
        const slot = &self.entries[self.entry_count];
        slot.* = .{
            .key = key,
            .offset = @intCast(offset),
            .width = raster.width,
            .height = raster.height,
            .bearing_x = raster.bearing_x,
            .bearing_y = raster.bearing_y,
            .advance_px = raster.advance_px,
        };
        self.entry_count += 1;
        return slot;
    }

    /// Frame boundary. Call once per window paint before any put: applies a
    /// deferred eviction (safe — the previous frame already presented).
    /// Idempotent and cheap.
    pub fn beginFrame(self: *Atlas) void {
        if (self.pending_eviction) {
            self.entry_count = 0;
            self.pixels_used = 0;
            self.pending_eviction = false;
            self.evictions += 1;
        }
    }
};

/// Copy a FreeType bitmap into flat top-down 8-bit coverage. Handles
/// positive/negative pitch and 1-bit sources. `embolden` spreads ink one
/// pixel right (synthetic bold for semibold/bold weights). Pure and fully
/// testable.
pub fn copyBitmap(dst: []u8, src: [*]const u8, width: u32, height: u32, pitch: c_int, kind: face_mod.BitmapKind, embolden: bool) void {
    if (width == 0 or height == 0) return;
    std.debug.assert(dst.len >= @as(usize, width) * height);
    const stride: usize = @as(usize, @intCast(@abs(pitch)));
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        // Negative pitch = bottom-up storage; row 0 stays on top.
        const src_row: usize = if (pitch >= 0)
            @as(usize, y) * stride
        else
            @as(usize, height - 1 - y) * stride;
        const dst_row: usize = @as(usize, y) * width;
        switch (kind) {
            .gray => @memcpy(dst[dst_row..][0..width], src[src_row..][0..width]),
            .mono => face_mod.expandMonoRow(dst[dst_row..][0..width], src[src_row..], width),
            .empty => @memset(dst[dst_row..][0..width], 0),
        }
        if (embolden) dilateRow(dst[dst_row..][0..width], dst[dst_row..][0..width], width);
    }
}

/// One-pixel horizontal max-filter: each pixel takes the max of itself and
/// its right neighbor, thickening vertical stems the way
/// `FT_GlyphSlot_Embolden` does (without touching metrics). Iterates left
/// to right so the ahead-read always sees pre-dilation values, making
/// aliased in-place use safe.
pub fn dilateRow(dst: []u8, src: []const u8, width: u32) void {
    std.debug.assert(dst.len >= width and src.len >= width);
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const peer = if (x + 1 < width) src[x + 1] else 0;
        dst[x] = @max(src[x], peer);
    }
}

test "atlas put/get/coverage round-trip" {
    const t = std.testing;
    var atlas = Atlas{};
    const px = [_]u8{ 0, 128, 255, 64 };
    const raster = face_mod.Raster{
        .width = 2,
        .height = 2,
        .pitch = 2,
        .bearing_x = 1,
        .bearing_y = 9,
        .advance_px = 10.5,
        .kind = .gray,
        .pixels = &px,
    };
    const key = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16 };
    try t.expect(atlas.get(key) == null); // miss counted
    const entry = try atlas.put(key, &raster, false);
    try t.expectEqual(@as(u32, 2), entry.width);
    try t.expectEqual(@as(f32, 10.5), entry.advance_px);
    const hit = atlas.get(key).?;
    try t.expectEqualSlices(u8, &px, atlas.coverage(hit));
    try t.expectEqual(@as(u64, 1), atlas.hits);
    try t.expectEqual(@as(u64, 1), atlas.misses);
    try t.expectEqual(@as(u64, 0), atlas.evictions);
}

test "atlas defers eviction past emitted entries" {
    const t = std.testing;
    var atlas = Atlas{};
    // Fill the entry table with empty glyphs (no pixel cost).
    const blank = face_mod.Raster{
        .width = 0,
        .height = 0,
        .pitch = 0,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_px = 5,
        .kind = .empty,
        .pixels = @as([*]const u8, @ptrCast(&face_mod.empty_coverage)),
    };
    var i: u32 = 0;
    while (i < limits.MAX_ATLAS_GLYPHS) : (i += 1) {
        _ = try atlas.put(.{ .face_id = 1, .glyph_id = i, .size_px = 16 }, &blank, false);
    }
    try t.expectEqual(@as(usize, limits.MAX_ATLAS_GLYPHS), atlas.entry_count);
    // Table full with live entries: report AtlasFull, change nothing.
    try t.expectError(error.AtlasFull, atlas.put(.{ .face_id = 1, .glyph_id = 99999, .size_px = 16 }, &blank, false));
    try t.expectEqual(@as(usize, limits.MAX_ATLAS_GLYPHS), atlas.entry_count);
    try t.expect(atlas.get(.{ .face_id = 1, .glyph_id = 0, .size_px = 16 }) != null);
    try t.expectEqual(@as(u64, 0), atlas.evictions);
    try t.expectEqual(@as(u64, 1), atlas.overflow_drops);
    try t.expect(atlas.pending_eviction);
    // Next frame boundary applies the eviction; the table accepts again.
    atlas.beginFrame();
    try t.expectEqual(@as(u64, 1), atlas.evictions);
    try t.expect(!atlas.pending_eviction);
    _ = try atlas.put(.{ .face_id = 1, .glyph_id = 99999, .size_px = 16 }, &blank, false);
    try t.expectEqual(@as(usize, 1), atlas.entry_count);
    // beginFrame without pending eviction is a no-op.
    atlas.beginFrame();
    try t.expectEqual(@as(u64, 1), atlas.evictions);
}

test "atlas overflow keeps earlier pool bytes valid" {
    // M2 gate: a frame exceeding capacity must not corrupt glyphs it
    // already emitted. Two ~600KB puts overflow the 1MB pool; the second
    // reports AtlasFull and the first entry's bytes stay intact.
    const t = std.testing;
    var atlas = Atlas{};
    const big_bytes = 600 * 1024;
    const px_a = try t.allocator.alloc(u8, big_bytes);
    defer t.allocator.free(px_a);
    @memset(px_a, 0xA5);
    const raster_a = face_mod.Raster{
        .width = 600,
        .height = 1024,
        .pitch = 600,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_px = 600,
        .kind = .gray,
        .pixels = px_a.ptr,
    };
    const entry_a = try atlas.put(.{ .face_id = 1, .glyph_id = 1, .size_px = 16 }, &raster_a, false);
    const offset_a = entry_a.offset;
    const px_b = try t.allocator.alloc(u8, big_bytes);
    defer t.allocator.free(px_b);
    @memset(px_b, 0x5A);
    const raster_b = face_mod.Raster{
        .width = 600,
        .height = 1024,
        .pitch = 600,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_px = 600,
        .kind = .gray,
        .pixels = px_b.ptr,
    };
    try t.expectError(error.AtlasFull, atlas.put(.{ .face_id = 1, .glyph_id = 2, .size_px = 16 }, &raster_b, false));
    // Earlier entry still resolves with untouched bytes.
    const hit = atlas.get(.{ .face_id = 1, .glyph_id = 1, .size_px = 16 }).?;
    try t.expectEqual(offset_a, hit.offset);
    for (atlas.coverage(hit)) |v| try t.expectEqual(@as(u8, 0xA5), v);
    // Next frame heals: clear applies, the big glyph fits again.
    atlas.beginFrame();
    _ = try atlas.put(.{ .face_id = 1, .glyph_id = 2, .size_px = 16 }, &raster_b, false);
}

test "copyBitmap honors negative pitch" {
    const t = std.testing;
    // Two rows stored bottom-up: first stored row is the visual bottom.
    const src = [_]u8{ 10, 20, 30, 40 };
    var dst: [4]u8 = undefined;
    copyBitmap(&dst, &src, 2, 2, -2, .gray, false);
    try t.expectEqualSlices(u8, &[_]u8{ 30, 40, 10, 20 }, &dst);
}

test "oversized glyph is rejected, not thrashed" {
    const t = std.testing;
    var atlas = Atlas{};
    const raster = face_mod.Raster{
        .width = 8192,
        .height = 8192,
        .pitch = 8192,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_px = 0,
        .kind = .gray,
        .pixels = @as([*]const u8, @ptrCast(&face_mod.empty_coverage)),
    };
    try t.expectError(error.GlyphTooLarge, atlas.put(.{ .face_id = 1, .glyph_id = 7, .size_px = 16 }, &raster, false));
    try t.expectEqual(@as(u64, 0), atlas.evictions);
}

test "dilateRow spreads ink one pixel right" {
    const t = std.testing;
    // Single-pixel stem in a 4-wide row.
    var row = [_]u8{ 0, 255, 0, 0 };
    dilateRow(&row, &row, 4);
    try t.expectEqualSlices(u8, &[_]u8{ 255, 255, 0, 0 }, &row);
    // Empty stays empty; full stays full.
    var empty = [_]u8{ 0, 0, 0 };
    dilateRow(&empty, &empty, 3);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, &empty);
    // Right edge has no neighbor to spread into.
    var edge = [_]u8{ 0, 0, 200 };
    dilateRow(&edge, &edge, 3);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 200, 200 }, &edge);
}

test "embolden path thickens cached coverage" {
    const t = std.testing;
    var atlas = Atlas{};
    const px = [_]u8{ 0, 255, 0, 0, 255, 0 };
    const raster = face_mod.Raster{
        .width = 3,
        .height = 2,
        .pitch = 3,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_px = 5,
        .kind = .gray,
        .pixels = &px,
    };
    const plain = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16 };
    const bold = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16, .bold = true };
    const e_plain = try atlas.put(plain, &raster, false);
    const e_bold = try atlas.put(bold, &raster, true);
    // Same glyph, two cache entries with different ink...
    try t.expect(atlas.get(plain) != null);
    try t.expect(atlas.get(bold) != null);
    try t.expectEqual(@as(usize, 2), atlas.entry_count);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 0, 255, 0 }, atlas.coverage(e_plain));
    try t.expectEqualSlices(u8, &[_]u8{ 255, 255, 0, 255, 255, 0 }, atlas.coverage(e_bold));
}
