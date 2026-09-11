//! FreeType-backed raster registry: the seam between glyph cache keys and
//! real glyph bitmaps.
//!
//! `swash_cache.SwashCache` originally rasterized through `FallbackRaster`, a
//! solid-mask stand-in with no font bytes. `Raster` here owns what FreeType
//! needs (one `FT_Library` plus faces keyed by cozmic `font_id`) and turns a
//! `glyph_cache.CacheKey`'s font/glyph/size/flags into a
//! `raster_ft.Rendered`. Attach it with `SwashCache.setRaster` and
//! `getImage`/`withPixels` serve real coverage masks; with nothing attached
//! the cache keeps its previous stand-in behaviour.
//!
//! ## Lifetime and ownership
//!
//! - `addFont` **copies** `bytes`: `raster_ft.Face.initMemory` borrows the
//!   buffer for the lifetime of the face, so the caller keeps ownership of
//!   its slice. The copy lives in the matching `FaceEntry` and is freed after
//!   `Face.deinit` (order matters: FreeType must never see freed bytes).
//! - `raster_ft.Face` stores a pointer to the `Raster.library` field, so a
//!   `Raster` must not be moved or copied after the first `addFont`. `init`
//!   returning by value is safe because it cannot have faces yet; keep the
//!   value pinned afterwards (a local or allocated `Raster`, not a temporary).
//! - `Rendered.bitmap` borrows the FreeType glyph slot and is invalidated by
//!   the next `rasterize` call. The one consumer (`SwashCache`) copies it into
//!   its own image immediately.
//! - Not thread-safe, like the underlying FreeType objects: one `Raster` per
//!   thread, or serialize access externally.

const std = @import("std");
const raster_ft = @import("raster_ft.zig");
const glyph_cache = @import("glyph_cache.zig");
const font_system = @import("font_system.zig");

/// One registered font: the cozmic id, the owned byte copy FreeType borrows,
/// and the live face.
pub const FaceEntry = struct {
    font_id: u32,
    /// Owned copy of the bytes passed to `Raster.addFont` (see module docs).
    bytes: []u8,
    face: raster_ft.Face,

    fn destroy(self: *FaceEntry, allocator: std.mem.Allocator) void {
        self.face.deinit();
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Registry of FreeType faces, one per cozmic `font_id`.
pub const Raster = struct {
    allocator: std.mem.Allocator,
    library: raster_ft.Library,
    faces: std.ArrayList(FaceEntry) = .empty,

    /// Create an empty registry. `deinit` must be called exactly once.
    pub fn init(allocator: std.mem.Allocator) !Raster {
        return .{
            .allocator = allocator,
            .library = try raster_ft.Library.init(),
        };
    }

    pub fn deinit(self: *Raster) void {
        for (self.faces.items) |*entry| entry.destroy(self.allocator);
        self.faces.deinit(self.allocator);
        self.library.deinit();
        self.* = undefined;
    }

    /// Register (or replace) the font bytes for `font_id`; `index` selects a
    /// face inside a collection (`0` for a single-face file).
    ///
    /// The bytes are copied and stay alive for the lifetime of the entry. A
    /// repeated `font_id` replaces the previous entry (last registration
    /// wins), matching `shape_hb.Backend.addFont`.
    pub fn addFont(self: *Raster, font_id: u32, bytes: []const u8, index: i32) !void {
        var entry = try self.makeEntry(font_id, bytes, index);
        errdefer entry.destroy(self.allocator);
        for (self.faces.items) |*old| {
            if (old.font_id == font_id) {
                old.destroy(self.allocator);
                old.* = entry;
                return;
            }
        }
        try self.faces.append(self.allocator, entry);
    }

    /// Register every id in `ids` from `fs.fontBytes`.
    ///
    /// `FontSystem` cannot enumerate registered ids, so the caller passes the
    /// explicit list (typically the ids it handed to `FontSystem.addFontData`).
    /// All ids are validated first, so a typo cannot leave a half-populated
    /// registry; an id with no bytes fails with `error.FontNotRegistered`.
    pub fn addFromFontSystem(
        self: *Raster,
        fs: *const font_system.FontSystem,
        ids: []const u32,
    ) !void {
        for (ids) |id| {
            if (fs.fontBytes(id) == null) return error.FontNotRegistered;
        }
        for (ids) |id| {
            const bytes = fs.fontBytes(id) orelse return error.FontNotRegistered;
            try self.addFont(id, bytes, 0);
        }
    }

    /// Borrowed face for `font_id`, or `null` when the id is not registered.
    pub fn getFace(self: *Raster, font_id: u32) ?*raster_ft.Face {
        for (self.faces.items) |*entry| {
            if (entry.font_id == font_id) return &entry.face;
        }
        return null;
    }

    /// Rasterize `glyph_id` at `font_size` pixels.
    ///
    /// The size is rounded to whole pixels and clamped to at least 1 (FreeType
    /// rejects zero sizes). Hinting is FreeType's default; `DISABLE_HINTING`
    /// adds `FT_LOAD_NO_HINTING`. Rendering is `FT_RENDER_MODE_NORMAL` (8-bit
    /// gray coverage).
    ///
    /// Returns `null` when `font_id` is not registered; other failures (bad
    /// glyph id, FreeType failure) propagate. The caller owns nothing: the
    /// returned bitmap borrows the face's glyph slot and is invalidated by the
    /// next `rasterize` call on the same font.
    pub fn rasterize(
        self: *Raster,
        font_id: u32,
        glyph_id: u16,
        font_size: f32,
        flags: glyph_cache.CacheKeyFlags,
    ) !?raster_ft.Rendered {
        const face = self.getFace(font_id) orelse return null;
        var load_flags: c_int = raster_ft.FT_LOAD_DEFAULT;
        if (flags.contains(glyph_cache.CacheKeyFlags.DISABLE_HINTING)) {
            load_flags |= raster_ft.FT_LOAD_NO_HINTING;
        }
        return try face.loadRenderFlags(glyph_id, pixelSize(font_size), load_flags);
    }

    fn makeEntry(self: *Raster, font_id: u32, bytes: []const u8, index: i32) !FaceEntry {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        const face = try raster_ft.Face.initMemory(&self.library, owned, index);
        return .{ .font_id = font_id, .bytes = owned, .face = face };
    }
};

/// Round `font_size` to the nearest whole pixel and clamp to
/// `[1, maxInt(u16)]`; NaN maps to the minimum. FreeType's
/// `FT_Set_Pixel_Sizes` rejects zero, so the floor is load-bearing.
pub fn pixelSize(font_size: f32) u16 {
    if (std.math.isNan(font_size)) return 1;
    const rounded = @round(font_size);
    if (!(rounded >= 1.0)) return 1; // also covers -inf
    const max: f32 = @floatFromInt(std.math.maxInt(u16));
    if (rounded >= max) return std.math.maxInt(u16);
    return @intFromFloat(rounded);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn readTestFont(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fonts/Inter-Regular.ttf",
        allocator,
        .limited(1 << 24),
    );
}

fn countNonZero(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| {
        if (b != 0) n += 1;
    }
    return n;
}

/// Glyph id for `codepoint` from a throwaway FreeType face over `bytes`
/// (the production path also uses FreeType's charmap via HarfBuzz, so the ids
/// agree for this font).
fn glyphId(bytes: []const u8, codepoint: u32) !u16 {
    var lib = try raster_ft.Library.init();
    defer lib.deinit();
    var face = try raster_ft.Face.initMemory(&lib, bytes, 0);
    defer face.deinit();
    const id = face.charIndex(codepoint);
    if (id == 0) return error.TestUnexpectedResult;
    return @intCast(id);
}

test "rasterize 'A' at 16px and 32px; unknown font id is a miss" {
    const allocator = testing.allocator;
    const bytes = try readTestFont(allocator);
    defer allocator.free(bytes);

    var raster = try Raster.init(allocator);
    defer raster.deinit();
    try raster.addFont(7, bytes, 0);
    const glyph = try glyphId(bytes, 'A');

    const small = (try raster.rasterize(7, glyph, 16.0, .{})).?;
    try testing.expectEqual(raster_ft.FT_PIXEL_MODE_GRAY, small.pixel_mode);
    try testing.expect(small.width > 0);
    try testing.expect(small.height > 0);
    try testing.expect(small.advance_x > 0);
    try testing.expect(countNonZero(small.bitmap) > 0);
    // Capture scalar copies: the bitmap borrows the slot and the next call
    // invalidates it.
    const small_w = small.width;
    const small_h = small.height;
    const small_cov = countNonZero(small.bitmap);
    const small_advance = small.advance_x;

    const large = (try raster.rasterize(7, glyph, 32.0, .{})).?;
    try testing.expect(large.width > small_w);
    try testing.expect(large.height > small_h);
    try testing.expect(countNonZero(large.bitmap) > small_cov);
    try testing.expect(large.advance_x > small_advance);

    // Unknown font id: explicit miss, not an error.
    try testing.expect(try raster.rasterize(99, glyph, 16.0, .{}) == null);

    // DISABLE_HINTING goes through the same load path and stays gray.
    const unhinted = (try raster.rasterize(
        7,
        glyph,
        32.0,
        glyph_cache.CacheKeyFlags.DISABLE_HINTING,
    )).?;
    try testing.expectEqual(raster_ft.FT_PIXEL_MODE_GRAY, unhinted.pixel_mode);
    try testing.expect(unhinted.width > 0 and unhinted.height > 0);
}

test "addFont replaces an id and addFromFontSystem validates first" {
    const allocator = testing.allocator;
    const bytes = try readTestFont(allocator);
    defer allocator.free(bytes);

    var raster = try Raster.init(allocator);
    defer raster.deinit();

    // Re-registration replaces the old entry (same face, new copy).
    try raster.addFont(3, bytes, 0);
    try raster.addFont(3, bytes, 0);
    try testing.expectEqual(@as(usize, 1), raster.faces.items.len);

    var fs = try font_system.FontSystem.init(allocator);
    defer fs.deinit();
    try fs.addFontData(3, bytes, 0, false, null);

    try raster.addFromFontSystem(&fs, &.{3});
    const glyph = raster.getFace(3).?.charIndex('A');
    const rendered = (try raster.rasterize(3, @intCast(glyph), 12.0, .{})) orelse
        return error.TestUnexpectedResult;
    try testing.expect(rendered.width > 0 and rendered.height > 0);

    // An unregistered id is rejected before any registration happens.
    try testing.expectError(
        error.FontNotRegistered,
        raster.addFromFontSystem(&fs, &.{ 3, 12345 }),
    );
    try testing.expect(raster.getFace(12345) == null);
}

test "pixelSize rounds to whole pixels and clamps to at least one" {
    try testing.expectEqual(@as(u16, 1), pixelSize(0.0));
    try testing.expectEqual(@as(u16, 1), pixelSize(0.4));
    try testing.expectEqual(@as(u16, 1), pixelSize(0.5)); // ties round away from zero
    try testing.expectEqual(@as(u16, 16), pixelSize(16.4));
    try testing.expectEqual(@as(u16, 17), pixelSize(16.6));
    try testing.expectEqual(@as(u16, 1), pixelSize(-5.0));
    try testing.expectEqual(@as(u16, 1), pixelSize(std.math.nan(f32)));
    try testing.expectEqual(std.math.maxInt(u16), pixelSize(std.math.inf(f32)));
    try testing.expectEqual(std.math.maxInt(u16), pixelSize(1e9));
}
