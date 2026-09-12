//! Atlas slot and rasterization data structures.
//!
//! Port of `glifo/src/atlas/region.rs`.

const paint_mod = @import("../../common/paint.zig");
const ImageId = paint_mod.ImageId;

/// Location and metrics of a cached glyph within an atlas page.
///
/// One slot is stored per distinct (font, glyph ID, size, subpixel offset)
/// combination in `GlyphAtlas`.
pub const AtlasSlot = struct {
    /// The image ID for this glyph in the `ImageCache`.
    ///
    /// Used for deallocation and for looking up the atlas page/offset.
    image_id: ImageId,
    /// Which atlas page contains this glyph.
    page_index: u32,
    /// X position in the atlas (pixels).
    x: u16,
    /// Y position in the atlas (pixels).
    y: u16,
    /// Width of the glyph bitmap (pixels).
    width: u16,
    /// Height of the glyph bitmap (pixels).
    height: u16,
    /// Horizontal bearing (offset from glyph origin to the left edge).
    bearing_x: i16,
    /// Vertical bearing (offset from glyph origin to the top edge).
    bearing_y: i16,
};

/// Metadata for a rasterized glyph (no pixel data).
///
/// Returned by rasterization to communicate bitmap dimensions and bearing
/// offsets.
pub const RasterMetrics = struct {
    /// Width of the rasterized glyph (pixels).
    width: u16,
    /// Height of the rasterized glyph (pixels).
    height: u16,
    /// Horizontal bearing (offset from glyph origin to the left edge).
    bearing_x: i16,
    /// Vertical bearing (offset from glyph origin to the top edge).
    bearing_y: i16,
};
