//! Cache key for glyph bitmaps stored in the atlas.
//!
//! Port of `glifo/src/atlas/key.rs`. `GlyphCacheKey` captures every parameter
//! that affects the visual appearance of a rasterized glyph — font identity,
//! size, hinting, subpixel position, COLR context color, and variable-font
//! coordinates. Two keys that compare equal produce identical bitmaps and can
//! safely share a single atlas entry.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - `AlphaColor<Srgb>` becomes `vellz.peniko.Color`; `SmallVec<[i16; 4]>`
//!   becomes a borrowed `[]const NormalizedCoord` because non-empty variation
//!   coordinates are `error.Unsupported` in this port (the key is only ever
//!   built with an empty slice until `gvar` lands).
//! - Upstream's manual `Hash`/`PartialEq` use a pre-packed premultiplied
//!   RGBA8 `u32`; this port keeps the same field set with a fixed-seed Wyhash
//!   context (upstream uses `foldhash` fixed seed 0). Iteration order is not
//!   part of the pixel contract (atlas slots are disjoint and sampled at
//!   integer offsets).

const std = @import("std");
const paint_mod = @import("../../peniko/root.zig");

pub const NormalizedCoord = i16;

/// Number of horizontal subpixel quantization buckets (valid range: 1–253).
///
/// Higher values improve rendering quality at the cost of more atlas entries
/// per glyph. Common values: 1 (disabled), 2, 4 (default), 8.
pub const SUBPIXEL_BUCKETS: u8 = 4;

/// Sentinel `subpixel_x` for COLR glyph cache entries.
///
/// `quantizeSubpixel` returns values in `0..SUBPIXEL_BUCKETS`, so values above
/// that range can never appear in an outline key. Distinct sentinels for COLR
/// and bitmap entries prevent cache collisions between glyph types that would
/// otherwise produce identical keys.
pub const SUBPIXEL_COLR: u8 = SUBPIXEL_BUCKETS;

/// Sentinel `subpixel_x` for bitmap glyph cache entries. See `SUBPIXEL_COLR`.
pub const SUBPIXEL_BITMAP: u8 = SUBPIXEL_BUCKETS + 1;

/// Unique identifier for a cached glyph bitmap.
///
/// `var_coords` is deliberately excluded from the hash/equality because the
/// upstream `GlyphAtlas` uses a two-level map partitioned by variation
/// coordinates. This port only supports empty coordinates (variation deltas
/// are deferred), so the exclusion is currently unobservable.
pub const GlyphCacheKey = struct {
    /// Unique identifier for the font blob.
    font_id: u64,
    /// Index within a font collection (TTC).
    font_index: u32,
    /// Glyph index within the font.
    glyph_id: u32,
    /// Font size as f32 bits (exact match, no quantization).
    size_bits: u32,
    /// Whether hinting was applied.
    hinted: bool,
    /// Horizontal subpixel bucket (`0..SUBPIXEL_BUCKETS`), or a sentinel for
    /// non-outline glyphs.
    subpixel_x: u8,
    /// Context color for COLR glyphs; not part of hash/equality.
    context_color: paint_mod.Color,
    /// Pre-packed context color (premultiplied RGBA8 as u32) used in
    /// hash/equality.
    context_color_packed: u32,
    /// Synthetic embolden amount (f32 bits), x axis. Non-zero is
    /// `error.Unsupported` until kurbo `expand_path` is ported.
    embolden_x_bits: u32,
    /// Synthetic embolden amount (f32 bits), y axis.
    embolden_y_bits: u32,
    /// Join style discriminant for synthetic embolden.
    embolden_join_bits: u8,
    /// Miter limit (f32 bits) for synthetic embolden.
    embolden_miter_limit_bits: u32,
    /// Tolerance (f32 bits) for synthetic embolden.
    embolden_tolerance_bits: u32,
    /// Variation coordinates for variable fonts; excluded from hash/equality.
    var_coords: []const NormalizedCoord = &.{},
};

/// creates a new cache key.
///
/// `fractional_x` (the fractional pixel offset) is quantized into
/// `SUBPIXEL_BUCKETS` buckets, so nearby positions share the same entry.
pub fn newKey(
    font_id: u64,
    font_index: u32,
    glyph_id: u32,
    size: f32,
    hinted: bool,
    fractional_x: f32,
    context_color: paint_mod.Color,
    context_color_packed: u32,
    embolden: @import("../outline_cache.zig").FontEmbolden,
    var_coords: []const NormalizedCoord,
) GlyphCacheKey {
    return .{
        .font_id = font_id,
        .font_index = font_index,
        .glyph_id = glyph_id,
        .size_bits = @bitCast(size),
        .hinted = hinted,
        .subpixel_x = quantizeSubpixel(fractional_x),
        .context_color = context_color,
        .context_color_packed = context_color_packed,
        .embolden_x_bits = f32Bits(embolden.amount[0]),
        .embolden_y_bits = f32Bits(embolden.amount[1]),
        .embolden_join_bits = joinBits(embolden.join),
        .embolden_miter_limit_bits = f32Bits(@floatCast(embolden.miter_limit)),
        .embolden_tolerance_bits = f32Bits(@floatCast(embolden.tolerance)),
        .var_coords = var_coords,
    };
}

fn f32Bits(value: f64) u32 {
    return @bitCast(@as(f32, @floatCast(value)));
}

/// Upstream `join_bits`: `Bevel => 0, Miter => 1, Round => 2`.
pub fn joinBits(join: @import("../../kurbo/root.zig").Join) u8 {
    return switch (join) {
        .bevel => 0,
        .miter => 1,
        .round => 2,
    };
}

/// Premultiply and pack an RGBA color into a `u32` for bitwise
/// hashing/comparison.
pub fn packColor(color: paint_mod.Color) u32 {
    return color.premultiply().toRgba8().toU32();
}

/// Quantize a fractional pixel offset into one of `SUBPIXEL_BUCKETS` buckets.
///
/// Values near 1.0 (>= 0.875 with 4 buckets) are clamped to the last bucket
/// rather than wrapping to 0, keeping the worst-case error to 0.125px.
pub fn quantizeSubpixel(frac: f32) u8 {
    const truncated = @trunc(frac);
    const normalized = frac - truncated;
    const adjusted = if (normalized < 0.0) normalized + 1.0 else normalized;
    const scaled = @round(adjusted * @as(f32, @floatFromInt(SUBPIXEL_BUCKETS)));
    if (scaled <= 0.0) return 0;
    const bucket: u8 = @intFromFloat(@min(scaled, 255.0));
    return @min(bucket, SUBPIXEL_BUCKETS - 1);
}

/// Convert a quantized bucket index back to the fractional pixel offset it
/// represents.
pub fn subpixelOffset(quantized: u8) f32 {
    return @as(f32, @floatFromInt(quantized)) / @as(f32, @floatFromInt(SUBPIXEL_BUCKETS));
}

/// Deterministic hasher for glyph cache keys. Only the fields upstream hashes
/// participate; `context_color` and `var_coords` are excluded by design.
pub const KeyContext = struct {
    pub fn hash(_: KeyContext, key: GlyphCacheKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.font_id));
        h.update(std.mem.asBytes(&key.font_index));
        h.update(std.mem.asBytes(&key.glyph_id));
        h.update(std.mem.asBytes(&key.size_bits));
        h.update(std.mem.asBytes(&key.hinted));
        h.update(std.mem.asBytes(&key.subpixel_x));
        h.update(std.mem.asBytes(&key.context_color_packed));
        h.update(std.mem.asBytes(&key.embolden_x_bits));
        h.update(std.mem.asBytes(&key.embolden_y_bits));
        h.update(std.mem.asBytes(&key.embolden_join_bits));
        h.update(std.mem.asBytes(&key.embolden_miter_limit_bits));
        h.update(std.mem.asBytes(&key.embolden_tolerance_bits));
        return h.final();
    }

    pub fn eql(_: KeyContext, a: GlyphCacheKey, b: GlyphCacheKey) bool {
        return a.font_id == b.font_id and
            a.font_index == b.font_index and
            a.glyph_id == b.glyph_id and
            a.size_bits == b.size_bits and
            a.hinted == b.hinted and
            a.subpixel_x == b.subpixel_x and
            a.context_color_packed == b.context_color_packed and
            a.embolden_x_bits == b.embolden_x_bits and
            a.embolden_y_bits == b.embolden_y_bits and
            a.embolden_join_bits == b.embolden_join_bits and
            a.embolden_miter_limit_bits == b.embolden_miter_limit_bits and
            a.embolden_tolerance_bits == b.embolden_tolerance_bits;
    }
};

const testing = std.testing;

test "quantize_subpixel bucket boundaries" {
    try testing.expectEqual(@as(u8, 0), quantizeSubpixel(0.0));
    try testing.expectEqual(@as(u8, 0), quantizeSubpixel(0.1));
    try testing.expectEqual(@as(u8, 1), quantizeSubpixel(0.2));
    try testing.expectEqual(@as(u8, 1), quantizeSubpixel(0.25));
    try testing.expectEqual(@as(u8, 2), quantizeSubpixel(0.4));
    try testing.expectEqual(@as(u8, 2), quantizeSubpixel(0.5));
    try testing.expectEqual(@as(u8, 2), quantizeSubpixel(0.6));
    try testing.expectEqual(@as(u8, 3), quantizeSubpixel(0.7));
    try testing.expectEqual(@as(u8, 3), quantizeSubpixel(0.75));
    try testing.expectEqual(@as(u8, 3), quantizeSubpixel(0.9));
    try testing.expectEqual(@as(u8, 0), quantizeSubpixel(1.0));
    // Negative fractions use Rust's `fract` (truncation toward zero) and are
    // normalized into `0..1` before quantization.
    try testing.expectEqual(@as(u8, 3), quantizeSubpixel(-0.1));
    try testing.expectEqual(@as(u8, 2), quantizeSubpixel(-0.5));
}

test "subpixel_offset round trips bucket representatives" {
    try testing.expectEqual(@as(f32, 0.0), subpixelOffset(0));
    try testing.expectEqual(@as(f32, 0.25), subpixelOffset(1));
    try testing.expectEqual(@as(f32, 0.5), subpixelOffset(2));
    try testing.expectEqual(@as(f32, 0.75), subpixelOffset(3));
}

test "key equality ignores context color value and var coords" {
    const color = paint_mod.Color.BLACK;
    const packed_color = packColor(color);
    const embolden = @import("../outline_cache.zig").FontEmbolden{};
    const key1 = newKey(1, 0, 42, 16.0, true, 0.3, color, packed_color, embolden, &.{});
    const key2 = newKey(1, 0, 42, 16.0, true, 0.3, color, packed_color, embolden, &.{});
    const ctx = KeyContext{};
    try testing.expect(ctx.eql(key1, key2));
    try testing.expectEqual(ctx.hash(key1), ctx.hash(key2));

    const red = paint_mod.Color.fromRgba8(255, 0, 0, 255);
    const key3 = newKey(1, 0, 42, 16.0, true, 0.3, red, packColor(red), embolden, &.{});
    try testing.expect(!ctx.eql(key1, key3));

    const key4 = newKey(1, 0, 42, 16.0, true, 0.3, color, packed_color, embolden, &.{100});
    try testing.expect(ctx.eql(key1, key4));
}

test "outline colr bitmap keys never collide" {
    const color = paint_mod.Color.BLACK;
    const packed_color = packColor(color);
    const embolden = @import("../outline_cache.zig").FontEmbolden{};
    const outline_key = newKey(1, 0, 42, 16.0, false, 0.0, color, packed_color, embolden, &.{});
    var colr_key = newKey(1, 0, 42, 16.0, false, 0.0, color, packed_color, embolden, &.{});
    colr_key.subpixel_x = SUBPIXEL_COLR;
    var bitmap_key = newKey(1, 0, 42, 16.0, false, 0.0, color, packed_color, embolden, &.{});
    bitmap_key.subpixel_x = SUBPIXEL_BITMAP;
    const ctx = KeyContext{};
    try testing.expect(!ctx.eql(outline_key, colr_key));
    try testing.expect(!ctx.eql(outline_key, bitmap_key));
    try testing.expect(!ctx.eql(colr_key, bitmap_key));
}

test "sentinels unreachable by quantize" {
    var i: u16 = 0;
    while (i <= 255) : (i += 1) {
        const bucket = quantizeSubpixel(@as(f32, @floatFromInt(i)) / 255.0);
        try testing.expect(bucket < SUBPIXEL_BUCKETS);
    }
}
