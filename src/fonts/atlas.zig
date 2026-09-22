//! Glyph atlas: fixed-capacity cache from rasterized glyph bitmaps (frame path).
//!
//! Keys mirror cozmic's full raster key: `(face_id, glyph_id, size_px,
//! x_bin, y_bin, font_weight, flags)` plus a `synthetic_bold` variant flag.
//! `face_id` is the cozmic `FontId` that shaped the glyph. Subpixel bins and
//! the weight/flags matter because they change the rasterized image (FreeType
//! transform offsets, variable-font `wght` design coordinates, hinting), so
//! entries must never alias across them. Rasterization itself belongs to
//! cozmic (`SwashCache.getImage`); this atlas only stores already-rasterized
//! 8-bit coverage. Coverage bytes live in one bump-allocated pool.
//! Exhaustion clears immediately only when the atlas holds no entries;
//! otherwise the eviction defers to the next beginFrame (one paint per
//! window, after the previous frame presented) and the overflowing put
//! reports AtlasFull — already-emitted glyphs keep valid pool bytes, so a
//! frame can never corrupt its own text. Full-clear is the right v0 policy:
//! UI text re-rasterizes the working set within a frame or two, and LRU
//! bookkeeping would cost more than it saves at 1024 entries. Counters
//! expose hits/misses/evictions/drops for tuning.
//!
//! Coverage masks and RGBA color glyphs use separate bounded pools. The
//! coverage API still rejects color input with `error.ColorUnsupported`, so
//! callers cannot accidentally reinterpret RGBA bytes as a mask; color input
//! enters only through `putColorBitmap`.
//!
//! Rows are copied top-down; `stride` is the source row pitch in bytes and
//! must be at least `width`. All methods are heap-free.

const std = @import("std");
const cozmic = @import("cozmic");
const limits = @import("../core/limits.zig");

/// Canonical cozmic key metadata (owner: `cozmic.glyph_cache`), re-exported
/// so painters can mirror a raster key without importing cozmic directly.
pub const SubpixelBin = cozmic.glyph_cache.SubpixelBin;
pub const CacheKeyFlags = cozmic.glyph_cache.CacheKeyFlags;

pub const AtlasKey = struct {
    face_id: u32,
    glyph_id: u32,
    size_px: u16,
    /// Density-specific raster size bits (exact f32 font size the
    /// rasterizer used); zero identifies legacy 1x keys. Fractional scales
    /// must never alias the 1x mask, and 1.5x must never alias 2x.
    raster_size_bits: u32 = 0,
    /// Subpixel bin of the raster position. Coverage and placement differ
    /// per bin (`FT_Set_Transform` offsets), so bins need their own entries.
    x_bin: SubpixelBin = .zero,
    y_bin: SubpixelBin = .zero,
    /// Weight handed to the rasterizer; variable faces rasterize different
    /// ink per weight, so 400/500/600/700 must not alias.
    font_weight: u16 = 400,
    /// Raster flags (fake italic / hinting / pixel font) that change ink.
    flags: CacheKeyFlags = .{},
    /// Synthetic-embolden variant (1px dilation at upload). Kept separate
    /// from `font_weight` so a dilated entry never aliases the same weight's
    /// undilated ink; dilation is applied per entry only when this is set.
    synthetic_bold: bool = false,

    /// Field-wise equality, including the packed flag bits.
    pub fn eql(a: AtlasKey, b: AtlasKey) bool {
        return a.face_id == b.face_id and
            a.glyph_id == b.glyph_id and
            a.size_px == b.size_px and
            a.raster_size_bits == b.raster_size_bits and
            a.x_bin == b.x_bin and
            a.y_bin == b.y_bin and
            a.font_weight == b.font_weight and
            CacheKeyFlags.eql(a.flags, b.flags) and
            a.synthetic_bold == b.synthetic_bold;
    }
};

pub const AtlasEntry = struct {
    key: AtlasKey,
    /// Pixels into `Atlas.pixels`.
    offset: u32,
    width: u32,
    height: u32,
    /// Raster placement of the bitmap's left edge relative to the glyph
    /// origin (SwashCache `placement.left` / FreeType `bitmap_left`).
    bearing_x: i32,
    /// Raster placement of the bitmap's top edge relative to the baseline,
    /// positive up (SwashCache `placement.top` / FreeType `bitmap_top`).
    bearing_y: i32,
    content: BitmapContent = .mask,
};

/// Supported bitmap encodings for the coverage API.
pub const BitmapContent = enum {
    /// 8-bit coverage, one byte per pixel (`stride` bytes per row).
    mask,
    /// 32-bit RGBA / premultiplied BGRA. Rejected by `putBitmap`; the pool
    /// cannot hold color ink without corrupting mask rendering.
    color,
};

pub const Atlas = struct {
    const index_empty: u16 = std.math.maxInt(u16);
    const index_capacity: usize = limits.MAX_ATLAS_GLYPHS * 2;
    const index_mask: usize = index_capacity - 1;

    entries: [limits.MAX_ATLAS_GLYPHS]AtlasEntry = undefined,
    /// Open-addressed key index for the fixed entry array. The old linear
    /// scan made every warm glyph lookup O(entry_count); this keeps the same
    /// allocation-free bounded storage while making the common lookup O(1).
    index_slots: [index_capacity]u16 = @splat(index_empty),
    entry_count: usize = 0,
    /// Mask bytes occupy the first pool; color RGBA bytes use the second
    /// half and are addressed by absolute offsets so the presenter still
    /// receives one contiguous glyph byte slice.
    pixels: [limits.MAX_ATLAS_PIXELS * 2]u8 = undefined,
    pixels_used: usize = 0,
    color_pixels_used: usize = 0,
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
        self.index_slots = @splat(index_empty);
        self.pixels_used = 0;
        self.color_pixels_used = 0;
        self.pending_eviction = false;
    }

    pub fn get(self: *Atlas, key: AtlasKey) ?*const AtlasEntry {
        if (self.entry_count == 0) {
            self.misses += 1;
            return null;
        }
        var slot = hashKey(key) & index_mask;
        var probes: usize = 0;
        while (probes < index_capacity) : ({
            slot = (slot + 1) & index_mask;
            probes += 1;
        }) {
            const raw = self.index_slots[slot];
            if (raw == index_empty) break;
            const entry_index: usize = @intCast(raw);
            if (entry_index < self.entry_count and AtlasKey.eql(self.entries[entry_index].key, key)) {
                self.hits += 1;
                return &self.entries[entry_index];
            }
        }
        self.misses += 1;
        return null;
    }

    fn hashKey(key: AtlasKey) u64 {
        // Nine-round FNV-1a over every key field. A packed-word splitmix
        // variant was measured with callgrind and cost ~900K *more*
        // instructions per warm frame (the packing shifts + extensions
        // outweigh the saved multiplies), so this chain stays.
        var hash: u64 = 14695981039346656037;
        inline for ([_]u64{
            key.face_id,
            key.glyph_id,
            key.size_px,
            key.raster_size_bits,
            @backingInt(key.x_bin),
            @backingInt(key.y_bin),
            key.font_weight,
            key.flags.bits,
            if (key.synthetic_bold) 1 else 0,
        }) |value| {
            hash = (hash ^ value) *% 1099511628211;
        }
        return hash;
    }

    fn indexInsert(self: *Atlas, key: AtlasKey, entry_index: usize) void {
        var slot = hashKey(key) & index_mask;
        var probes: usize = 0;
        while (probes < index_capacity) : ({
            slot = (slot + 1) & index_mask;
            probes += 1;
        }) {
            const raw = self.index_slots[slot];
            if (raw == index_empty) {
                self.index_slots[slot] = @intCast(entry_index);
                return;
            }
            const existing: usize = @intCast(raw);
            if (existing < self.entry_count and AtlasKey.eql(self.entries[existing].key, key)) return;
        }
        // The index is twice the entry capacity, so this is unreachable under
        // the bounded table contract. A future capacity change should still
        // retain the existing storage rather than corrupting it.
    }

    pub fn coverage(self: *const Atlas, entry: *const AtlasEntry) []const u8 {
        std.debug.assert(entry.content == .mask);
        const bytes = @as(usize, entry.width) * entry.height;
        return self.pixels[entry.offset..][0..bytes];
    }

    pub fn colorPixels(self: *const Atlas, entry: *const AtlasEntry) []const u8 {
        std.debug.assert(entry.content == .color);
        const bytes = @as(usize, entry.width) * entry.height * 4;
        return self.pixels[entry.offset..][0..bytes];
    }

    /// Insert an already-rasterized glyph bitmap. `data` must hold
    /// `height * stride` readable bytes; `stride >= width` is required.
    ///
    /// A single glyph larger than the whole pool is rejected with
    /// `error.GlyphTooLarge` instead of thrashing. Exhaustion clears
    /// immediately ONLY when the atlas holds no entries (nothing can
    /// reference the pool); otherwise it defers the eviction to the next
    /// beginFrame and returns `error.AtlasFull` WITHOUT clearing —
    /// already-emitted glyphs keep valid pool bytes, the caller skips this
    /// glyph (advance already shaped), and the frame heals next frame. A
    /// permanently oversized working set degrades to holes + a growing
    /// overflow_drops counter instead of corruption.
    ///
    /// `embolden` applies a 1px synthetic-bold dilation for semibold/bold
    /// weights (ink only; advances stay shaped so measure still matches).
    /// Callers must set `key.synthetic_bold` when passing `embolden = true`,
    /// so dilated and undilated entries stay distinct.
    /// `content == .color` returns `error.ColorUnsupported` without writing
    /// pool bytes; callers should use `putColorBitmap` for RGBA data.
    pub fn putBitmap(
        self: *Atlas,
        key: AtlasKey,
        width: u32,
        height: u32,
        stride: usize,
        data: [*]const u8,
        bearing_x: i32,
        bearing_y: i32,
        content: BitmapContent,
        embolden: bool,
    ) !*const AtlasEntry {
        if (content == .color) return error.ColorUnsupported;
        if (stride < width) return error.InvalidBitmap;
        const bytes = @as(usize, width) * height;
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
            copyBitmap(self.pixels[offset..][0..bytes], data, width, height, stride, embolden);
        }
        self.pixels_used += bytes;
        const slot = &self.entries[self.entry_count];
        slot.* = .{
            .key = key,
            .offset = @intCast(offset),
            .width = width,
            .height = height,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .content = .mask,
        };
        self.entry_count += 1;
        self.indexInsert(key, self.entry_count - 1);
        return slot;
    }

    /// Insert straight RGBA color glyph bytes into the separate color pool.
    /// The absolute offset keeps mask and color entries in one presenter slice
    /// without allowing either representation to alias the other.
    pub fn putColorBitmap(
        self: *Atlas,
        key: AtlasKey,
        width: u32,
        height: u32,
        data: [*]const u8,
        bearing_x: i32,
        bearing_y: i32,
    ) !*const AtlasEntry {
        const bytes = @as(usize, width) * height * 4;
        if (bytes > limits.MAX_ATLAS_PIXELS) return error.GlyphTooLarge;
        if (self.entry_count >= limits.MAX_ATLAS_GLYPHS or self.color_pixels_used + bytes > limits.MAX_ATLAS_PIXELS) {
            if (self.entry_count == 0) {
                self.clear();
                self.evictions += 1;
            } else {
                self.pending_eviction = true;
                self.overflow_drops += 1;
                return error.AtlasFull;
            }
        }
        const offset = @as(usize, limits.MAX_ATLAS_PIXELS) + self.color_pixels_used;
        if (bytes > 0) @memcpy(self.pixels[offset..][0..bytes], data[0..bytes]);
        self.color_pixels_used += bytes;
        const slot = &self.entries[self.entry_count];
        slot.* = .{
            .key = key,
            .offset = @intCast(offset),
            .width = width,
            .height = height,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .content = .color,
        };
        self.entry_count += 1;
        self.indexInsert(key, self.entry_count - 1);
        return slot;
    }

    pub fn storageUsed(self: *const Atlas) usize {
        return if (self.color_pixels_used > 0)
            @as(usize, limits.MAX_ATLAS_PIXELS) + self.color_pixels_used
        else
            self.pixels_used;
    }

    /// Frame boundary. Call once per window paint before any put: applies a
    /// deferred eviction (safe — the previous frame already presented).
    /// Idempotent and cheap.
    pub fn beginFrame(self: *Atlas) void {
        if (self.pending_eviction) {
            self.clear();
            self.evictions += 1;
        }
    }
};

/// Copy a top-down 8-bit coverage bitmap into flat rows. `src` rows are
/// `stride` bytes apart; `dst` rows are tight (`width` bytes). `embolden`
/// spreads ink one pixel right (synthetic bold for semibold/bold weights).
/// Pure and fully testable.
pub fn copyBitmap(dst: []u8, src: [*]const u8, width: u32, height: u32, stride: usize, embolden: bool) void {
    if (width == 0 or height == 0) return;
    std.debug.assert(stride >= width);
    std.debug.assert(dst.len >= @as(usize, width) * height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row: usize = @as(usize, y) * stride;
        const dst_row: usize = @as(usize, y) * width;
        @memcpy(dst[dst_row..][0..width], src[src_row..][0..width]);
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

test "atlas putBitmap/get/coverage round-trip" {
    const t = std.testing;
    var atlas = Atlas{};
    const px = [_]u8{ 0, 128, 255, 64 };
    const key = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16 };
    try t.expect(atlas.get(key) == null); // miss counted
    const entry = try atlas.putBitmap(key, 2, 2, 2, &px, 1, 9, .mask, false);
    try t.expectEqual(@as(u32, 2), entry.width);
    try t.expectEqual(@as(i32, 1), entry.bearing_x);
    try t.expectEqual(@as(i32, 9), entry.bearing_y);
    const hit = atlas.get(key).?;
    try t.expectEqualSlices(u8, &px, atlas.coverage(hit));
    try t.expectEqual(@as(u64, 1), atlas.hits);
    try t.expectEqual(@as(u64, 1), atlas.misses);
    try t.expectEqual(@as(u64, 0), atlas.evictions);
}

test "atlas keeps color RGBA bytes in a separate pool" {
    const t = std.testing;
    var atlas = Atlas{};
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const key = AtlasKey{ .face_id = 2, .glyph_id = 77, .size_px = 24 };
    const entry = try atlas.putColorBitmap(key, 2, 1, &rgba, 3, 11);
    try t.expectEqual(BitmapContent.color, entry.content);
    try t.expectEqual(@as(usize, limits.MAX_ATLAS_PIXELS), @as(usize, entry.offset));
    try t.expectEqualSlices(u8, &rgba, atlas.colorPixels(entry));
    try t.expectEqual(@as(usize, limits.MAX_ATLAS_PIXELS) + rgba.len, atlas.storageUsed());
}

test "atlas defers eviction past emitted entries" {
    const t = std.testing;
    var atlas = Atlas{};
    const blank = [_]u8{0};
    // Fill the entry table with empty glyphs (no pixel cost).
    var i: u32 = 0;
    while (i < limits.MAX_ATLAS_GLYPHS) : (i += 1) {
        _ = try atlas.putBitmap(.{ .face_id = 1, .glyph_id = i, .size_px = 16 }, 0, 0, 0, &blank, 0, 0, .mask, false);
    }
    try t.expectEqual(@as(usize, limits.MAX_ATLAS_GLYPHS), atlas.entry_count);
    // Table full with live entries: report AtlasFull, change nothing.
    try t.expectError(error.AtlasFull, atlas.putBitmap(.{ .face_id = 1, .glyph_id = 99999, .size_px = 16 }, 0, 0, 0, &blank, 0, 0, .mask, false));
    try t.expectEqual(@as(usize, limits.MAX_ATLAS_GLYPHS), atlas.entry_count);
    try t.expect(atlas.get(.{ .face_id = 1, .glyph_id = 0, .size_px = 16 }) != null);
    try t.expectEqual(@as(u64, 0), atlas.evictions);
    try t.expectEqual(@as(u64, 1), atlas.overflow_drops);
    try t.expect(atlas.pending_eviction);
    // Next frame boundary applies the eviction; the table accepts again.
    atlas.beginFrame();
    try t.expectEqual(@as(u64, 1), atlas.evictions);
    try t.expect(!atlas.pending_eviction);
    _ = try atlas.putBitmap(.{ .face_id = 1, .glyph_id = 99999, .size_px = 16 }, 0, 0, 0, &blank, 0, 0, .mask, false);
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
    const entry_a = try atlas.putBitmap(.{ .face_id = 1, .glyph_id = 1, .size_px = 16 }, 600, 1024, 600, px_a.ptr, 0, 0, .mask, false);
    const offset_a = entry_a.offset;
    const px_b = try t.allocator.alloc(u8, big_bytes);
    defer t.allocator.free(px_b);
    @memset(px_b, 0x5A);
    try t.expectError(error.AtlasFull, atlas.putBitmap(.{ .face_id = 1, .glyph_id = 2, .size_px = 16 }, 600, 1024, 600, px_b.ptr, 0, 0, .mask, false));
    // Earlier entry still resolves with untouched bytes.
    const hit = atlas.get(.{ .face_id = 1, .glyph_id = 1, .size_px = 16 }).?;
    try t.expectEqual(offset_a, hit.offset);
    for (atlas.coverage(hit)) |v| try t.expectEqual(@as(u8, 0xA5), v);
    // Next frame heals: clear applies, the big glyph fits again.
    atlas.beginFrame();
    _ = try atlas.putBitmap(.{ .face_id = 1, .glyph_id = 2, .size_px = 16 }, 600, 1024, 600, px_b.ptr, 0, 0, .mask, false);
}

test "copyBitmap honors stride and emboldens rows" {
    const t = std.testing;
    // Two rows with one byte of padding after each row.
    const src = [_]u8{ 10, 20, 99, 30, 40, 99 };
    var dst: [4]u8 = undefined;
    copyBitmap(&dst, &src, 2, 2, 3, false);
    try t.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 40 }, &dst);
    // Embolden: each pixel takes the max of itself and its right neighbor.
    copyBitmap(&dst, &src, 2, 2, 3, true);
    try t.expectEqualSlices(u8, &[_]u8{ 20, 20, 40, 40 }, &dst);
}

test "oversized glyph is rejected, not thrashed" {
    const t = std.testing;
    var atlas = Atlas{};
    const blank = [_]u8{0};
    try t.expectError(error.GlyphTooLarge, atlas.putBitmap(.{ .face_id = 1, .glyph_id = 7, .size_px = 16 }, 8192, 8192, 8192, &blank, 0, 0, .mask, false));
    try t.expectEqual(@as(u64, 0), atlas.evictions);
}

test "stride smaller than width is rejected" {
    const t = std.testing;
    var atlas = Atlas{};
    const px = [_]u8{ 1, 2 };
    try t.expectError(
        error.InvalidBitmap,
        atlas.putBitmap(.{ .face_id = 1, .glyph_id = 3, .size_px = 16 }, 2, 1, 1, &px, 0, 0, .mask, false),
    );
    try t.expectEqual(@as(usize, 0), atlas.entry_count);
}

test "color bitmaps are rejected as a miss" {
    const t = std.testing;
    var atlas = Atlas{};
    const rgba = [_]u8{ 1, 2, 3, 4 };
    try t.expectError(
        error.ColorUnsupported,
        atlas.putBitmap(.{ .face_id = 1, .glyph_id = 9, .size_px = 16 }, 1, 1, 4, &rgba, 0, 0, .color, false),
    );
    // Nothing entered the pool: a later lookup stays a miss and repaint
    // cannot reuse color bytes as coverage.
    try t.expect(atlas.get(.{ .face_id = 1, .glyph_id = 9, .size_px = 16 }) == null);
    try t.expectEqual(@as(usize, 0), atlas.entry_count);
    try t.expectEqual(@as(usize, 0), atlas.pixels_used);
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

test "atlas keys distinguish subpixel bins, weights, flags and dilation" {
    // Regression: the key used to be (face, glyph, size, bold), so the first
    // raster at a given size aliased every later subpixel bin and weight.
    const t = std.testing;
    var atlas = Atlas{};
    const px = [_]u8{7};
    const base = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16 };
    var bin = base;
    bin.x_bin = .two;
    bin.y_bin = .one;
    var weight = base;
    weight.font_weight = 700;
    var flags = base;
    flags.flags = .fake_italic;
    var bold = base;
    bold.synthetic_bold = true;

    const keys = [_]AtlasKey{ base, bin, weight, flags, bold };
    for (keys) |key| _ = try atlas.putBitmap(key, 1, 1, 1, &px, 0, 0, .mask, key.synthetic_bold);
    try t.expectEqual(@as(usize, keys.len), atlas.entry_count);
    for (keys) |key| try t.expect(atlas.get(key) != null);
    // Explicitly: the bin variant is a distinct key even at the same size.
    try t.expect(!AtlasKey.eql(base, bin));
    try t.expect(AtlasKey.eql(base, base));
}

test "embolden path thickens cached coverage" {
    const t = std.testing;
    var atlas = Atlas{};
    const px = [_]u8{ 0, 255, 0, 0, 255, 0 };
    const plain = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16 };
    const bold = AtlasKey{ .face_id = 1, .glyph_id = 65, .size_px = 16, .synthetic_bold = true };
    const e_plain = try atlas.putBitmap(plain, 3, 2, 3, &px, 0, 0, .mask, false);
    const e_bold = try atlas.putBitmap(bold, 3, 2, 3, &px, 0, 0, .mask, true);
    // Same glyph, two cache entries with different ink...
    try t.expect(atlas.get(plain) != null);
    try t.expect(atlas.get(bold) != null);
    try t.expectEqual(@as(usize, 2), atlas.entry_count);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 0, 255, 0 }, atlas.coverage(e_plain));
    try t.expectEqualSlices(u8, &[_]u8{ 255, 255, 0, 255, 255, 0 }, atlas.coverage(e_bold));
}
