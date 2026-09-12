//! `vellz.glifo` — glyph outline loading for text rendering.
//!
//! Port of `glifo 0.3.0`'s font/outline side (`glifo/src/glyph.rs` outline
//! cache plus `skrifa 0.44.0`'s `glyf` scaler), staged per
//! `.ports/vellz/docs/glifo-m3-plan.md` task T2. The module is
//! self-contained: it borrows a font blob, parses the small sfnt subset, and
//! produces `vellz.kurbo` path elements that are **bit-identical** to the
//! pinned upstream `PathStyle::FreeType` output.
//!
//! # Surface
//!
//! - `FontData { blob, index }` / `Font` — face selection (sfnt + TTC),
//!   `head`/`maxp`/`hhea`/`hmtx` metrics, `cmap` formats 4 + 12, and
//!   `outlines()` for the TrueType scaler.
//! - `Outlines` — unhinted `glyf` outlines: `outline(gid)` for point/contour
//!   totals, `draw(allocator, gid, settings, pen)` for scaling + path
//!   emission with `DrawSettings{ size, coords, path_style }` and
//!   `AdjustedMetrics{ has_overlaps, lsb, advance_width }`.
//! - `pen.PathElementPen` — records raw f32 `PathElement`s (the oracle dump
//!   sink); `pen.PathPen` — records into a `vellz.kurbo.BezPath`.
//! - `OutlineCache` — glifo's outline cache keyed by
//!   `(font id, face index, gid, size bits, embolden bits, hint)` with
//!   upstream's `maintain()`/`clear()` eviction policy.
//! - `NormalizedCoord = i16` and `FontEmbolden` — carried in cache keys for
//!   API parity; non-default values are rejected with `error.Unsupported`.
//! - `util` — the `glifo` float/affine predicates (`FloatExt`/`AffineExt`)
//!   T3 needs for run preparation.
//!
//! # Fixed-point contract
//!
//! Unhinted scaling runs through 16.16 `Fixed`/26.6 `F26Dot6` exactly like
//! `skrifa` and only converts to `f32` at the pen boundary. `glyf.zig`
//! documents the individual formulas. Do not replace them with f32 math.
//!
//! # Deferred with typed errors
//!
//! Hinting (`HintingInstance`, interpreter), autohinting, `gvar`/`HVAR`/`avar`
//! variation deltas (any non-empty coords), CFF/CFF2, CBDT/CBLC/sbix bitmaps,
//! and synthetic embolden are all `error.Unsupported`. None are approximated.
//!
//! # Oracle comparison
//!
//! `tools/oracle-rs --dump-glyphs` / `--dump-cmap` print the pinned
//! `skrifa` output as f32 bit patterns; `tools/vellz_cli.zig` has the same
//! modes and `tools/compare_glyphs.sh` diffs them. The committed corpus and
//! per-vector hashes live in `tests/fixtures/glyphs/`.

const std = @import("std");

pub const tables = @import("tables/root.zig");
pub const font = @import("font.zig");
pub const glyf = @import("glyf.zig");
pub const pen = @import("pen.zig");
pub const outline_cache = @import("outline_cache.zig");
pub const util = @import("util.zig");
pub const dump = @import("dump.zig");
pub const atlas = @import("atlas/root.zig");
pub const interface = @import("interface.zig");
pub const glyph = @import("glyph.zig");
pub const renderer = @import("renderer.zig");

pub const FontData = font.FontData;
pub const Font = font.Font;
pub const GlyphId = font.GlyphId;
pub const NormalizedCoord = font.NormalizedCoord;
pub const Charmap = font.Charmap;

pub const Outlines = glyf.Outlines;
pub const Outline = glyf.Outline;
pub const DrawSettings = glyf.DrawSettings;
pub const DrawError = glyf.DrawError;
pub const AdjustedMetrics = glyf.AdjustedMetrics;
pub const PathStyle = glyf.PathStyle;
pub const Scale26Dot6 = glyf.Scale26Dot6;

pub const PathElement = pen.PathElement;
pub const PathElementPen = pen.PathElementPen;
pub const PathPen = pen.PathPen;

pub const OutlineCache = outline_cache.OutlineCache;
pub const OutlineKey = outline_cache.OutlineKey;
pub const CachedOutline = outline_cache.CachedOutline;
pub const FontInfo = outline_cache.FontInfo;
pub const FontEmbolden = outline_cache.FontEmbolden;

pub const Glyph = glyph.Glyph;
pub const GlyphRun = glyph.GlyphRun;
pub const GlyphRunBuilder = glyph.GlyphRunBuilder;
pub const GlyphRunRenderer = glyph.GlyphRunRenderer;
pub const GlyphPrepCache = glyph.GlyphPrepCache;
pub const GlyphPrepCacheMut = glyph.GlyphPrepCacheMut;
pub const AtlasCacher = glyph.AtlasCacher;
pub const GlyphScaleProperties = glyph.GlyphScaleProperties;
pub const DrawProps = glyph.DrawProps;
pub const PreparedGlyph = glyph.PreparedGlyph;
pub const GlyphOutline = glyph.GlyphOutline;
pub const GlyphSliceIterator = glyph.GlyphSliceIterator;
pub const iterate = glyph.iterate;
pub const prepareGlyphRun = glyph.prepareGlyphRun;
pub const buildRenderer = glyph.buildRenderer;

pub const AtlasSlot = atlas.AtlasSlot;
pub const RasterMetrics = atlas.RasterMetrics;
pub const GlyphCacheKey = atlas.GlyphCacheKey;
pub const GlyphAtlas = atlas.GlyphAtlas;
pub const GlyphCacheConfig = atlas.GlyphCacheConfig;
pub const ImageCache = atlas.ImageCache;
pub const AtlasConfig = atlas.AtlasConfig;
pub const GLYPH_PADDING = atlas.GLYPH_PADDING;
pub const AtlasCommand = atlas.AtlasCommand;
pub const AtlasCommandRecorder = atlas.AtlasCommandRecorder;
pub const AtlasPaint = atlas.AtlasPaint;
pub const PendingClearRect = atlas.PendingClearRect;
pub const SUBPIXEL_BUCKETS = atlas.SUBPIXEL_BUCKETS;

pub const DrawSink = interface;
pub const GlyphRenderer = interface;

test {
    _ = tables;
    _ = font;
    _ = glyf;
    _ = pen;
    _ = outline_cache;
    _ = util;
    _ = dump;
    _ = atlas;
    _ = interface;
    _ = glyph;
    _ = renderer;
}
