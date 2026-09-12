//! Glyph bitmap atlas cache for efficient text rendering.
//!
//! Port of `glifo/src/atlas/mod.rs`. The module provides:
//! - Rasterize glyphs once and reuse the bitmaps for subsequent draws.
//! - Pack glyph bitmaps into shared atlas images using guillotiere.
//! - Stable glyph keys for reliable cache hits.
//! - Multiple atlas pages for scalability.
//! - Simple age-based eviction.

pub const cache = @import("cache.zig");
pub const commands = @import("commands.zig");
pub const key = @import("key.zig");
pub const region = @import("region.zig");

pub const AtlasConfig = @import("../../common/multi_atlas.zig").AtlasConfig;
pub const ImageCache = @import("../../common/image_cache.zig").ImageCache;
pub const GLYPH_PADDING = cache.GLYPH_PADDING;
pub const GlyphAtlas = cache.GlyphAtlas;
pub const GlyphCacheConfig = cache.GlyphCacheConfig;
pub const GlyphCacheEntry = cache.GlyphCacheEntry;
pub const PendingClearRect = cache.PendingClearRect;
pub const AtlasCommand = commands.AtlasCommand;
pub const AtlasCommandRecorder = commands.AtlasCommandRecorder;
pub const AtlasPaint = commands.AtlasPaint;
pub const GlyphCacheKey = key.GlyphCacheKey;
pub const SUBPIXEL_BUCKETS = key.SUBPIXEL_BUCKETS;
pub const SUBPIXEL_COLR = key.SUBPIXEL_COLR;
pub const SUBPIXEL_BITMAP = key.SUBPIXEL_BITMAP;
pub const subpixelOffset = key.subpixelOffset;
pub const packColor = key.packColor;
pub const AtlasSlot = region.AtlasSlot;
pub const RasterMetrics = region.RasterMetrics;

test {
    _ = cache;
    _ = commands;
    _ = key;
    _ = region;
}
