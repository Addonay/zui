//! Processing and drawing glyphs.
//!
//! Port of `glifo/src/glyph.rs`. This module owns run preparation
//! (`GlyphRunBuilder`/`prepareGlyphRun`), the outline/COLR draw loop, and the
//! `GlyphPrepCache` bundle. The per-glyph rasterization and atlas insertion
//! logic lives in `renderer.zig`; COLR paint traversal lives in `colr.zig`.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - Trait objects become comptime duck typing; `renderer.zig`'s functions
//!   take `renderer: anytype` and `interface.zig` documents/validates the
//!   method set. Allocating sink methods take the allocator and return
//!   `!void` (upstream aborts on allocation failure).
//! - Iterators are plain values with a `next() ?Glyph` method and are not
//!   required to be cloneable: the decoration pass drains the run's iterator
//!   once instead of cloning it.
//! - TrueType hinting is ported (M3 G3b): `prepareGlyphRunWithCache` consults
//!   the 16-entry LRU `HintCache` for eligible transforms,
//!   `hinting.HintingInstance` runs `fpgm`/`prep` once per (font, size), and
//!   glyph outlines are drawn through the interpreter keyed by the hint
//!   instance. `Engine::AutoFallback` selects the autohinter for
//!   instruction-less fonts; interpreter failures are `error.HintError`, and
//!   neither engine ever silently renders unhinted.
//! - Glyphs resolve through the upstream COLR > bitmap > outline cascade:
//!   COLR/CPAL is ported (T4) and embedded bitmaps (`sbix`/`CBDT`/`EBDT`) are
//!   ported (T5); `Bgra`/`Mask` bitmap payloads and undecodable PNGs fall
//!   through to the outline branch exactly like upstream's `.ok()`-filtered
//!   `Pixmap::from_png`. Outlines resolve through `outlines.zig` (`glyf` or
//!   the CFF/CFF2 charstring interpreter); a face with neither a supported
//!   outline source nor a bitmap strike is rejected.
//! - Decoration (`renderDecoration`) is ported: the upstream `Vec` of merged
//!   exclusion spans lives on `GlyphPrepCache` and the Rust iterator/closure
//!   pair becomes one pass over that list.
//! - Variation coordinates are ported: they are forwarded to `skrifa`-style
//!   `gvar` deltas, hint-instance setup (`cvar`) and the second-level outline
//!   and atlas cache maps. Synthetic embolden (`kurbo::expand_path`) remains
//!   an explicit `error.Unsupported`.
//! - Upstream's `OutlineCacheSession` is replaced by an explicit
//!   `*OutlineCache` threaded through the draw loop and `renderer.fillGlyph`/
//!   `strokeGlyph`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");

const paint_mod = @import("../common/paint.zig");
const pixmap_mod = @import("../common/pixmap.zig");
const shared_mod = @import("../common/shared.zig");
const sfnt = @import("tables/sfnt.zig");
const bitmap_mod = @import("tables/bitmap.zig");
const cpal_mod = @import("tables/cpal.zig");
const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
const hinting = @import("hinting.zig");
const colr = @import("colr.zig");
const png_mod = @import("png.zig");
const outline_cache = @import("outline_cache.zig");
const atlas = @import("atlas/root.zig");
const renderer_mod = @import("renderer.zig");
const interface = @import("interface.zig");

/// A shared, reference-counted pixmap (upstream `Arc<Pixmap>`).
pub const SharedPixmap = shared_mod.Shared(pixmap_mod.Pixmap);

pub const NormalizedCoord = font_mod.NormalizedCoord;
pub const FontEmbolden = outline_cache.FontEmbolden;
pub const FontInfo = outline_cache.FontInfo;
pub const FontData = font_mod.FontData;

const outlines_mod = @import("outlines.zig");

/// Errors from glyph run preparation and drawing.
pub const Error = font_mod.Error || outlines_mod.DrawError || error{
    /// Features still scoped out: synthetic embolden (`kurbo::expand_path`),
    /// CFF hinting, the autohinter, and COLRv1 variation deltas.
    Unsupported,
};

/// Positioned glyph.
pub const Glyph = struct {
    /// The font-specific identifier for this glyph.
    ///
    /// This ID is specific to the font being used and corresponds to the
    /// glyph index within that font. It is *not* a Unicode code point.
    id: u32 = 0,
    /// X-offset in run, relative to the transform.
    x: f32 = 0.0,
    /// Y-offset in run, relative to the transform.
    y: f32 = 0.0,
};

/// A slice-backed glyph iterator (`Iterator<Item = Glyph>` upstream).
pub const GlyphSliceIterator = struct {
    glyphs: []const Glyph,
    index: usize = 0,

    pub fn next(self: *GlyphSliceIterator) ?Glyph {
        if (self.index >= self.glyphs.len) return null;
        const glyph = self.glyphs[self.index];
        self.index += 1;
        return glyph;
    }
};

/// Wrap a glyph slice in the iterator the run builders consume.
pub fn iterate(glyphs: []const Glyph) GlyphSliceIterator {
    return .{ .glyphs = glyphs };
}

/// Rendering style for glyphs.
pub const Style = enum {
    /// Fill the glyph.
    fill,
    /// Stroke the glyph.
    stroke,
};

/// A sequence of glyphs with shared rendering properties.
pub const GlyphRun = struct {
    /// Font for all glyphs in the run.
    font: FontData,
    /// Size of the font in pixels per em.
    font_size: f32 = 16.0,
    /// Synthetic embolden settings.
    font_embolden: FontEmbolden = .{},
    /// Global transform.
    transform: kurbo.Affine,
    /// Paint transform for the glyph run in scene space.
    scene_paint_transform: kurbo.Affine,
    /// Per-glyph transform; use `Affine.skew(x, 0)` to simulate italics.
    glyph_transform: ?kurbo.Affine = null,
    /// Normalized variation coordinates for variable fonts.
    normalized_coords: []const NormalizedCoord = &.{},
    /// Controls whether font hinting is enabled.
    hint: bool = true,
};

/// Builder for configuring and drawing glyphs.
///
/// `Backend` is the `GlyphRunBackend` implementation (for the CPU renderer,
/// `cpu.text.CpuGlyphRunBackend`). All setters return a new builder value,
/// mirroring upstream's consuming builder.
pub fn GlyphRunBuilder(comptime Backend: type) type {
    return struct {
        const Self = @This();

        run: GlyphRun,
        backend: Backend,

        /// Creates a new builder for drawing glyphs with a pre-bound backend.
        pub fn new(
            font: FontData,
            transform: kurbo.Affine,
            paint_transform: kurbo.Affine,
            backend: Backend,
        ) Self {
            return .{
                .run = .{
                    .font = font,
                    .font_size = 16.0,
                    .transform = transform,
                    // Keep in sync with upstream `GlyphRunBuilder::new`.
                    .scene_paint_transform = transform.compose(paint_transform),
                },
                .backend = backend,
            };
        }

        /// Set the font size in pixels per em.
        pub fn fontSize(self: Self, size: f32) Self {
            var result = self;
            result.run.font_size = size;
            return result;
        }

        /// Set synthetic embolden settings.
        pub fn fontEmbolden(self: Self, embolden: FontEmbolden) Self {
            var result = self;
            result.run.font_embolden = embolden;
            return result;
        }

        /// Set the per-glyph transform.
        pub fn glyphTransform(self: Self, transform: kurbo.Affine) Self {
            var result = self;
            result.run.glyph_transform = transform;
            return result;
        }

        /// Set whether font hinting is enabled.
        ///
        /// Eligible runs go through the TrueType interpreter (M3 G3b) and are
        /// cached in `HintCache` by font, size and coordinates. Autohinter-
        /// only fonts fail with `error.Unsupported` when drawn.
        pub fn hint(self: Self, enabled: bool) Self {
            var result = self;
            result.run.hint = enabled;
            return result;
        }

        /// Set normalized variation coordinates for variable fonts.
        ///
        /// `coords` is a slice of F2Dot14 `i16` values (`glifo`'s
        /// `NormalizedCoord`), borrowed for the lifetime of the run. Empty or
        /// all-zero coordinates take the static path; on a font without variation
        /// tables they are a no-op.
        pub fn normalizedCoords(self: Self, coords: []const NormalizedCoord) Self {
            var result = self;
            result.run.normalized_coords = coords;
            return result;
        }

        /// Enable or disable the glyph atlas cache.
        pub fn atlasCache(self: Self, enabled: bool) Self {
            return .{ .run = self.run, .backend = self.backend.atlasCache(enabled) };
        }

        /// Fill the glyphs using the current settings.
        pub fn fillGlyphs(self: Self, allocator: std.mem.Allocator, glyphs: anytype) !void {
            return self.backend.fillGlyphs(allocator, self.run, glyphs);
        }

        /// Stroke the glyphs using the current settings.
        pub fn strokeGlyphs(self: Self, allocator: std.mem.Allocator, glyphs: anytype) !void {
            return self.backend.strokeGlyphs(allocator, self.run, glyphs);
        }

        /// Render a decoration (underline/overline/strikethrough) with
        /// skip-ink behavior, using the builder's current run settings.
        ///
        /// `x_range` is the horizontal span in run space; `baseline_y`,
        /// `offset` and `size` place the line relative to the baseline
        /// (positive `offset` points up, font space) and `buffer` widens each
        /// glyph's ink exclusion zone. See `GlyphRunRenderer.renderDecoration`.
        pub fn renderDecoration(
            self: Self,
            allocator: std.mem.Allocator,
            glyphs: anytype,
            x_range: [2]f32,
            baseline_y: f32,
            offset: f32,
            size: f32,
            buffer: f32,
        ) !void {
            return self.backend.renderDecoration(
                allocator,
                self.run,
                glyphs,
                x_range,
                baseline_y,
                offset,
                size,
                buffer,
            );
        }
    };
}

/// LRU cache for hinting instances, ported from `glifo`'s `HintCache`.
///
/// Regenerating hinting data is low to medium cost, so a 16-entry linear
/// search cache is enough. Upstream's `get` returns `None` when an instance
/// cannot be configured and then silently draws unhinted; this port reports
/// the typed error instead, so a hinted run is never approximated.
pub const HintCache = struct {
    /// We keep this small to enable a simple LRU cache with a linear search.
    pub const max_cached_hint_instances: usize = 16;

    entries: std.ArrayList(HintEntry) = .empty,
    serial: u64 = 0,

    const HintEntry = struct {
        font_id: u64,
        font_index: u32,
        size: f32,
        instance: hinting.HintingInstance,
        serial: u64,
    };

    /// Release every cached instance and the entry list.
    pub fn deinit(self: *HintCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// Drop every cached instance.
    pub fn clear(self: *HintCache, allocator: std.mem.Allocator) void {
        _ = allocator;
        for (self.entries.items) |*entry| entry.instance.deinit();
        self.entries.clearRetainingCapacity();
        self.serial = 0;
    }

    /// Returns a hinting instance configured for `(font, size, coords)`,
    /// reusing an exact match or reconfiguring the least-recently-used entry
    /// when full.
    pub fn get(
        self: *HintCache,
        allocator: std.mem.Allocator,
        font_id: u64,
        font_index: u32,
        outlines: *const outlines_mod.Outlines,
        size: f32,
        coords: []const i16,
    ) Error!*hinting.HintingInstance {
        if (!outlines.supportsHinting()) return error.Unsupported;
        for (self.entries.items) |*entry| {
            if (entry.font_id == font_id and
                entry.font_index == font_index and
                entry.size == size and
                std.mem.eql(i16, entry.instance.location(), coords))
            {
                self.serial += 1;
                entry.serial = self.serial;
                return &entry.instance;
            }
        }
        if (self.entries.items.len >= max_cached_hint_instances) {
            // Evict the least recently used entry and reconfigure it.
            var lru: usize = 0;
            var lru_serial: u64 = std.math.maxInt(u64);
            for (self.entries.items, 0..) |entry, ix| {
                if (entry.serial < lru_serial) {
                    lru_serial = entry.serial;
                    lru = ix;
                }
            }
            const entry = &self.entries.items[lru];
            try hinting.reconfigure(
                &entry.instance,
                allocator,
                outlines,
                size,
                coords,
                glyf.glifo_hint_target,
            );
            entry.font_id = font_id;
            entry.font_index = font_index;
            entry.size = size;
            self.serial += 1;
            entry.serial = self.serial;
            return &entry.instance;
        }
        var instance = try hinting.create(allocator, outlines, size, coords, glyf.glifo_hint_target);
        errdefer instance.deinit();
        try self.entries.append(allocator, .{
            .font_id = font_id,
            .font_index = font_index,
            .size = size,
            .instance = instance,
            .serial = 0,
        });
        self.serial += 1;
        const entry = &self.entries.items[self.entries.items.len - 1];
        entry.serial = self.serial;
        return &entry.instance;
    }
};

/// Caches used for preparing glyph drawing.
pub const GlyphPrepCache = struct {
    /// Caches glyph outlines.
    outline_cache: outline_cache.OutlineCache = .{},
    /// Caches hinting instances (upstream `HintCache`).
    hint_cache: HintCache = .{},
    /// Horizontal spans excluded from "ink-skipping" underlines. Cached to
    /// reuse one allocation.
    underline_exclusions: std.ArrayListUnmanaged([2]f64) = .empty,

    /// Borrow this cache bundle mutable for glyph run construction.
    pub fn asMut(self: *GlyphPrepCache) GlyphPrepCacheMut {
        return .{
            .outline_cache = &self.outline_cache,
            .hint_cache = &self.hint_cache,
            .underline_exclusions = &self.underline_exclusions,
        };
    }

    /// Clear the glyph preparation caches.
    pub fn clear(self: *GlyphPrepCache, allocator: std.mem.Allocator) void {
        self.outline_cache.clear(allocator);
        self.hint_cache.clear(allocator);
        self.underline_exclusions.clearRetainingCapacity();
    }

    /// Maintain the glyph preparation caches.
    pub fn maintain(self: *GlyphPrepCache, allocator: std.mem.Allocator) void {
        self.outline_cache.maintain(allocator);
    }

    /// Release the cache storage.
    pub fn deinit(self: *GlyphPrepCache, allocator: std.mem.Allocator) void {
        self.outline_cache.deinit(allocator);
        self.hint_cache.deinit(allocator);
        self.underline_exclusions.deinit(allocator);
        self.* = .{};
    }
};

/// Mutably borrowed caches used for preparing glyph drawing.
pub const GlyphPrepCacheMut = struct {
    /// Caches glyph outlines.
    outline_cache: *outline_cache.OutlineCache,
    /// Caches hinting instances.
    hint_cache: *HintCache,
    /// Horizontal spans excluded from "ink-skipping" underlines.
    underline_exclusions: *std.ArrayListUnmanaged([2]f64),
};

/// Determines whether atlas-backed glyph caching is available for a draw.
pub const AtlasCacher = union(enum) {
    /// Draw directly without using the atlas cache.
    disabled,
    /// Enable atlas-backed caching using the provided glyph atlas and image
    /// allocator.
    enabled: struct {
        glyph_atlas: *atlas.GlyphAtlas,
        image_cache: *atlas.ImageCache,
    },

    /// The eviction configuration when caching is enabled.
    pub fn config(self: AtlasCacher) ?atlas.GlyphCacheConfig {
        return switch (self) {
            .disabled => null,
            .enabled => |*e| e.glyph_atlas.eviction_config,
        };
    }

    /// Look up a cached glyph slot.
    pub fn get(self: *AtlasCacher, key: atlas.GlyphCacheKey) ?atlas.AtlasSlot {
        return switch (self.*) {
            .disabled => null,
            .enabled => |*e| e.glyph_atlas.get(key),
        };
    }
};

/// A glyph defined by a path (its outline) and a local transform.
pub const GlyphOutline = struct {
    /// The path of the glyph (borrowed; owned by the outline cache).
    path: *const kurbo.BezPath,
    /// Precise bounding box of the path at the cached outline size.
    bbox: kurbo.Rect,
    /// Scale from the cached outline size to the requested draw size.
    scale: f64,
};

/// A glyph defined by a COLR glyph description.
///
/// Upstream renders these into an intermediate pixmap and then samples that
/// into the scene; this port draws the paint graph directly through the
/// renderer, or records it into the glyph atlas.
pub const GlyphColr = struct {
    /// The parsed color glyph (borrowed from the font blob).
    color_glyph: colr.ColorGlyph,
    /// The face's `CPAL` table, or `null` (palette lookups then fall back to
    /// `BLACK`, matching upstream's `cpal().ok()?`).
    cpal: ?cpal_mod.Cpal,
    /// TrueType outlines used to resolve COLRv1 clip glyphs.
    outlines: *const outlines_mod.Outlines,
    /// Basic metadata about the font.
    font_info: FontInfo,
    /// The transform to apply to the glyph.
    draw_transform: kurbo.Affine,
    /// The rectangular area (in intermediate-pixmap units) that holds the
    /// rendered representation of the COLR glyph.
    area: kurbo.Rect,
    /// Width of the intermediate pixmap in pixels.
    pix_width: u16,
    /// Height of the intermediate pixmap in pixels.
    pix_height: u16,
    /// Whether the paint graph uses a non-default blend mode.
    has_non_default_blend: bool,
};

/// A glyph defined by a bitmap.
pub const GlyphBitmap = struct {
    /// The decoded, premultiplied pixmap of the glyph.
    pixmap: SharedPixmap,
    /// The rectangular area that should be filled with the bitmap when
    /// painting (`0, 0, width, height`).
    area: kurbo.Rect,
};

/// A type of glyph.
pub const GlyphType = union(enum) {
    /// An outline glyph.
    outline: GlyphOutline,
    /// A bitmap glyph.
    bitmap: GlyphBitmap,
    /// A COLR glyph.
    colr: GlyphColr,
};

/// A glyph prepared for rendering.
pub const PreparedGlyph = struct {
    /// The glyph representation chosen by the COLR > bitmap > outline cascade.
    glyph_type: GlyphType,
    /// Per-glyph outline transform: maps the draw-unit glyph (after font-size
    /// absorption) to scene coordinates.
    outline_transform: kurbo.Affine,
    /// The transform of the paint relative to the outline transform.
    relative_paint_transform: kurbo.Affine,
    /// Cache key for renderers that implement glyph caching; `null` when the
    /// glyph cannot be cached.
    cache_key: ?atlas.GlyphCacheKey = null,
};

/// Properties for turning glyph-local positions into final draw transforms.
pub const DrawProps = struct {
    /// A positioning transform for the glyph (translation already absorbed).
    positioning_transform: kurbo.Affine,
    /// A transform to apply to the glyph after positioning.
    effective_transform: kurbo.Affine,
    /// The actual font size used for drawing and caching.
    font_size: f32,

    /// Compute the final glyph transform for `glyph`.
    pub fn positionedTransform(self: DrawProps, glyph: Glyph) kurbo.Affine {
        // First, determine the "coarse" location of the glyph by applying the
        // scaling/skewing of the original run transform to the glyph position.
        // `positioning_transform` has a zero translation, so only the scaling
        // and skewing factors are relevant.
        const translation = self.positioning_transform.transformPoint(
            kurbo.Point.new(@as(f64, glyph.x), @as(f64, glyph.y)),
        );

        // Now apply the final draw transform on top, which also considers the
        // original glyph transform.
        return kurbo.Affine.translate(translation.toVec2()).compose(self.effective_transform);
    }
};

/// A prepared run ready for the draw loop.
pub const PreparedGlyphRun = struct {
    /// The underlying font data.
    font: FontData,
    /// Basic metadata about the underlying font.
    font_info: FontInfo,
    /// The parsed TrueType outlines (upstream `font_ref.outline_glyphs()`).
    /// Empty when the face has no `glyf` table (bitmap-only faces).
    outlines: outlines_mod.Outlines,
    /// Whether `outlines` came from a real `glyf` table. Faces without `glyf`
    /// (bitmap-only, or CFF + bitmaps) have no ported outline source, so
    /// `false` skips the outline branch instead of parsing an empty `loca`
    /// (upstream's CFF fallback is not ported).
    has_outlines: bool = true,
    /// The embedded bitmap strikes (upstream `font_ref.bitmap_strikes()`).
    bitmap_strikes: bitmap_mod.Strikes,
    /// The parsed color glyphs (upstream `font_ref.color_glyphs()`).
    color_glyphs: colr.ColorGlyphCollection,
    /// The face's `CPAL` table, or `null`.
    cpal: ?cpal_mod.Cpal,
    /// The original run size supplied by the caller.
    run_size: f32,
    /// Synthetic embolden settings.
    font_embolden: FontEmbolden,
    /// The original per-glyph transform supplied by the caller.
    glyph_transform: ?kurbo.Affine,
    /// Properties for turning glyph-local positions into final transforms.
    draw_props: DrawProps,
    /// The original transform for the paint in scene space.
    scene_paint_transform: kurbo.Affine,
    /// Normalized variation coordinates (`i16` F2Dot14 bits), borrowed from
    /// the caller like upstream's `GlyphRun<'a>`.
    normalized_coords: []const NormalizedCoord,
    /// Hinting instance for this run; `null` when the run is unhinted (or the
    /// effective transform is `Direct`, which never hints upstream).
    hinting_instance: ?*hinting.HintingInstance = null,
};

/// The scale at which an outline is cached and the factor to the draw size.
pub const GlyphScaleProperties = struct {
    /// The size at which the outline was cached.
    cache_size: f32,
    /// The scale factor applied to the cached outline at draw time.
    draw_scale: f64,

    /// Compute the cache/draw split for a run.
    pub fn new(draw_font_size: f32, upem: f32, hinted: bool, style: Style) GlyphScaleProperties {
        if (hinted or style == .stroke) {
            // Hinting is scale-dependent, and stroke widths would be affected
            // by an absorbed scale; keep the original font size in both cases.
            return .{ .cache_size = draw_font_size, .draw_scale = 1.0 };
        }
        return .{
            .cache_size = upem,
            // Upstream divides in f32 and widens the result to f64.
            .draw_scale = @as(f64, draw_font_size / upem),
        };
    }
};

/// Prepare a glyph run for rendering.
///
/// Fails with `error.Unsupported` for deferred inputs: synthetic embolden
/// and faces without any glyph source the port can render (CFF/CFF2-only, or
/// no bitmap strike either). Hinted runs whose transform would absorb a
/// uniform vertical scale need a hint cache and are rejected by this entry
/// point; variation coordinates are carried on the prepared run (and are a
/// no-op without variation tables, like upstream).
pub fn prepareGlyphRun(run: GlyphRun) Error!PreparedGlyphRun {
    // No hint cache: hinted-scale absorption is rejected with
    // `error.Unsupported` (the allocator is never used).
    return prepareGlyphRunWithCache(run, null, std.heap.page_allocator);
}

/// `prepareGlyphRun` with a hint cache for hinted-scale absorption.
pub fn prepareGlyphRunWithCache(
    run: GlyphRun,
    hint_cache: ?*HintCache,
    allocator: std.mem.Allocator,
) Error!PreparedGlyphRun {
    if (!run.font_embolden.isDefault()) return error.Unsupported;

    const full_transform = run.transform.compose(run.glyph_transform orelse kurbo.Affine.IDENTITY);
    const c = full_transform.asCoeffs();
    // `t_c` (the skew coefficient) is only needed for the hinted effective
    // transform.
    const t_c = c[2];
    const t_d = c[3];
    const t_e = c[4];
    const t_f = c[5];

    const Mode = enum {
        /// No absorption: the font size stays the same and the effective
        /// transform is the concatenation of run and glyph transforms.
        direct,
        /// The uniform scale has been absorbed into the font size; unhinted.
        absorb_scale_unhinted,
        /// The uniform scale has been absorbed, but hinting is required.
        absorb_scale_hinted,
    };

    const mode: Mode = if (!run.hint)
        (if (util_isPositiveUniformScaleWithoutSkew(full_transform))
            .absorb_scale_unhinted
        else
            .direct)
    else if (util_isPositiveUniformScaleWithoutVerticalSkew(full_transform))
        .absorb_scale_hinted
    else
        .direct;

    var effective_transform: kurbo.Affine = undefined;
    var draw_font_size: f32 = undefined;
    var hinting_instance: ?*hinting.HintingInstance = null;
    switch (mode) {
        // The scale is absorbed into the font size; remove it from the skew
        // coefficient as well so it is not applied twice.
        .absorb_scale_unhinted => {
            effective_transform = kurbo.Affine.new(.{ 1.0, 0.0, 0.0, 1.0, t_e, t_f });
            draw_font_size = run.font_size * @as(f32, @floatCast(t_d));
        },
        .direct => {
            effective_transform = full_transform;
            draw_font_size = run.font_size;
        },
        .absorb_scale_hinted => {
            const vertical_font_size = run.font_size * @as(f32, @floatCast(t_d));
            const cache = hint_cache orelse return error.Unsupported;
            const hinted_font = try run.font.font();
            const hinted_outlines = try hinted_font.outlines();
            hinting_instance = try cache.get(
                allocator,
                @intFromPtr(run.font.blob.ptr),
                run.font.index,
                &hinted_outlines,
                vertical_font_size,
                run.normalized_coords,
            );
            // The scale has been absorbed into the font size, so remove it
            // from the skew coefficient as well: otherwise the skew would be
            // applied twice (once via the larger outline, once via the
            // transform). The translation stays as-is.
            effective_transform = kurbo.Affine.new(.{ 1.0, 0.0, t_c / t_d, 1.0, t_e, t_f });
            draw_font_size = vertical_font_size;
        },
    }

    const font = try run.font.font();
    const upem: f32 = @floatFromInt(font.unitsPerEm());

    const face = font.face;
    const bitmap_strikes = font.bitmapStrikes();

    // Faces without `glyf`/CFF outlines (bitmap-only faces) keep an empty
    // outline collection, like upstream's `outline_glyphs()`.
    var has_outlines = true;
    const outlines = font.outlines() catch |err| switch (err) {
        error.Unsupported => blk: {
            if (bitmap_strikes.isEmpty()) return error.Unsupported;
            has_outlines = false;
            break :blk outlines_mod.Outlines.empty(font);
        },
        else => return err,
    };
    const color_glyphs = colr.ColorGlyphCollection.init(face);
    const cpal = if (face.table(sfnt.tag_cpal)) |data| cpal_mod.Cpal.parse(data) else null;

    return .{
        .font = run.font,
        .font_info = .{
            .id = @intFromPtr(run.font.blob.ptr),
            .index = run.font.index,
            .upem = upem,
        },
        .outlines = outlines,
        .has_outlines = has_outlines,
        .bitmap_strikes = bitmap_strikes,
        .color_glyphs = color_glyphs,
        .cpal = cpal,
        .run_size = run.font_size,
        .font_embolden = run.font_embolden,
        .glyph_transform = run.glyph_transform,
        .draw_props = .{
            .positioning_transform = run.transform.withTranslation(kurbo.Vec2.ZERO),
            .effective_transform = effective_transform,
            .font_size = draw_font_size,
        },
        .scene_paint_transform = run.scene_paint_transform,
        .normalized_coords = run.normalized_coords,
        .hinting_instance = hinting_instance,
    };
}

// `util.zig` predicates are free functions; aliases keep the transcribed
// upstream branch text readable.
fn util_isPositiveUniformScaleWithoutSkew(a: kurbo.Affine) bool {
    return @import("util.zig").isPositiveUniformScaleWithoutSkew(a);
}

fn util_isPositiveUniformScaleWithoutVerticalSkew(a: kurbo.Affine) bool {
    return @import("util.zig").isPositiveUniformScaleWithoutVerticalSkew(a);
}

/// Calculate transform for outline glyphs.
///
/// Applies the glyph position, the run's effective transform, and the font
/// space to layout space Y flip. For hinted runs the Y translation is snapped
/// to the pixel grid (`calculate_outline_transform` upstream) so it does not
/// interfere with the interpreter's grid fitting.
pub fn calculateOutlineTransform(
    glyph: Glyph,
    draw_props: DrawProps,
    hinted: bool,
) kurbo.Affine {
    var transform = draw_props
        .positionedTransform(glyph)
        .preScaleNonUniform(1.0, -1.0);
    if (hinted) {
        const c = transform.asCoeffs();
        transform = kurbo.Affine.new(.{ c[0], c[1], c[2], c[3], c[4], @round(c[5]) });
    }
    return transform;
}

/// Helper struct containing computed COLR glyph metrics.
const ColrMetrics = struct {
    /// Base transform with glyph position applied.
    transform: kurbo.Affine,
    /// Scaled bounding box in device coordinates.
    scaled_bbox: kurbo.Rect,
    /// Scale factor for the x axis.
    scale_factor_x: f64,
    /// Scale factor for the y axis.
    scale_factor_y: f64,
    /// Font-size scale (`font_size / upem`).
    font_size_scale: f64,
    /// Whether the glyph paint graph uses a non-default blend mode.
    has_non_default_blend: bool,
};

/// `x_y_advances`: the images of the unit vectors under the scale/skew part of
/// the transform.
fn xYAdvances(transform: kurbo.Affine) [2]kurbo.Vec2 {
    const c = transform.asCoeffs();
    const scale_skew = kurbo.Affine.new(.{ c[0], c[1], c[2], c[3], 0.0, 0.0 });
    const x_advance = scale_skew.transformPoint(kurbo.Point.new(1.0, 0.0));
    const y_advance = scale_skew.transformPoint(kurbo.Point.new(0.0, 1.0));
    return .{
        kurbo.Vec2.new(x_advance.x, x_advance.y),
        kurbo.Vec2.new(y_advance.x, y_advance.y),
    };
}

/// Calculate COLR glyph metrics (scale factors, bounding box, etc.),
/// mirroring `glifo::glyph::calculate_colr_metrics`.
fn calculateColrMetrics(
    allocator: std.mem.Allocator,
    prepared: *const PreparedGlyphRun,
    glyph: Glyph,
    color_glyph: colr.ColorGlyph,
    outline_cache_ref: *outline_cache.OutlineCache,
) !ColrMetrics {
    // The scale factor we need to apply to scale from font units to our font
    // size. Upstream divides in f32 and widens the result to f64.
    const font_size_scale: f64 = @as(f64, prepared.draw_props.font_size / prepared.font_info.upem);
    const transform = prepared.draw_props.positionedTransform(glyph);

    // Estimate the size of the intermediate pixmap: one pixel per device
    // pixel, from the scaling/skewing factor of each axis.
    const advances = xYAdvances(transform.preScale(font_size_scale));
    const scale_factor_x = advances[0].length();
    const scale_factor_y = advances[1].length();

    const colr_info = try colr.getColrInfo(
        allocator,
        color_glyph,
        &prepared.outlines,
        outline_cache_ref,
        prepared.font_info,
    );
    // The clip bbox from the COLR table has the highest priority; otherwise
    // use the conservative bbox determined by the extractor.
    const clip_bbox: ?kurbo.Rect = if (color_glyph.boundingBox()) |cb|
        colr.convertBoundingBox(cb)
    else
        null;
    const bbox = clip_bbox orelse colr_info.bbox orelse kurbo.Rect.ZERO;

    const scaled_bbox = kurbo.Rect.new(
        bbox.x0 * scale_factor_x,
        bbox.y0 * scale_factor_y,
        bbox.x1 * scale_factor_x,
        bbox.y1 * scale_factor_y,
    );

    return .{
        .transform = transform,
        .scaled_bbox = scaled_bbox,
        .scale_factor_x = scale_factor_x,
        .scale_factor_y = scale_factor_y,
        .font_size_scale = font_size_scale,
        .has_non_default_blend = colr_info.has_non_default_blend,
    };
}

/// Calculate transform for COLR glyphs, mirroring
/// `glifo::glyph::calculate_colr_transform`.
fn calculateColrTransform(metrics: *const ColrMetrics) kurbo.Affine {
    return metrics.transform
        // Flip the intermediate image on the y axis (COLR glyphs are drawn
        // upside down in font space).
        .compose(kurbo.Affine.scaleNonUniform(1.0, -1.0))
        // Un-apply the run transform (it is applied later by the render
        // context) while keeping the glyph-size scale.
        .compose(kurbo.Affine.scaleNonUniform(
            metrics.font_size_scale / metrics.scale_factor_x,
            metrics.font_size_scale / metrics.scale_factor_y,
        ))
        // Shift the pixmap back so the bbox aligns with the glyph position.
        .compose(kurbo.Affine.translate(kurbo.Vec2.new(
        metrics.scaled_bbox.x0,
        metrics.scaled_bbox.y0,
    )));
}

/// Create COLR glyph data with intermediate texture parameters.
fn createColrGlyph(
    prepared: *const PreparedGlyphRun,
    metrics: *const ColrMetrics,
    color_glyph: colr.ColorGlyph,
) GlyphColr {
    const pix_width = satU16(@ceil(metrics.scaled_bbox.width()));
    const pix_height = satU16(@ceil(metrics.scaled_bbox.height()));

    const draw_transform = kurbo.Affine
        .translate(kurbo.Vec2.new(-metrics.scaled_bbox.x0, -metrics.scaled_bbox.y0))
        .compose(kurbo.Affine.scaleNonUniform(metrics.scale_factor_x, metrics.scale_factor_y));

    const area = kurbo.Rect.new(
        0.0,
        0.0,
        metrics.scaled_bbox.width(),
        metrics.scaled_bbox.height(),
    );

    return .{
        .color_glyph = color_glyph,
        .cpal = prepared.cpal,
        .outlines = &prepared.outlines,
        .font_info = prepared.font_info,
        .draw_transform = draw_transform,
        .area = area,
        .pix_width = pix_width,
        .pix_height = pix_height,
        .has_non_default_blend = metrics.has_non_default_blend,
    };
}

/// Rust `f64 as u16` semantics: saturating, NaN becomes 0.
fn satU16(value: f64) u16 {
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(std.math.clamp(value, 0.0, 65535.0));
}

/// Decode a bitmap glyph's payload into a premultiplied pixmap.
///
/// Mirrors upstream `glifo`: only PNG payloads are rendered; `Bgra`/`Mask`
/// payloads and PNG decode failures fall through to the outline branch
/// (upstream `Pixmap::from_png(..).ok()` → `None`). Allocation failures
/// propagate instead of being swallowed.
pub fn decodeBitmapPixmap(
    allocator: std.mem.Allocator,
    bitmap_glyph: *const bitmap_mod.BitmapGlyph,
) !?SharedPixmap {
    const png_data = switch (bitmap_glyph.data) {
        .png => |data| data,
        // The others are not worth implementing for now (unless we can find a
        // test case), they should be very rare.
        .bgra, .mask => return null,
    };
    const decoded = png_mod.decode(allocator, png_data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(decoded.pixels);

    var pixmap = pixmap_mod.Pixmap.fromParts(
        allocator,
        decoded.pixels,
        decoded.width,
        decoded.height,
        .{ .alpha_type = .alpha, .may_have_transparency = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDataLength => return null,
    };
    errdefer pixmap.deinit(allocator);
    return try SharedPixmap.create(allocator, pixmap);
}

/// Create bitmap glyph data: wrap the decoded pixmap with its display area.
///
/// The caller transfers one reference to `pixmap` (the returned value owns
/// it).
pub fn createBitmapGlyph(pixmap: SharedPixmap) GlyphBitmap {
    // The scale factor already accounts for ppem, so the area is just the
    // size of the actual image.
    return .{
        .pixmap = pixmap,
        .area = kurbo.Rect.new(
            0.0,
            0.0,
            @floatFromInt(pixmap.get().width),
            @floatFromInt(pixmap.get().height),
        ),
    };
}

/// Calculate the final positioning transform for a bitmap glyph, mirroring
/// `glifo::glyph::calculate_bitmap_transform`.
pub fn calculateBitmapTransform(
    glyph: Glyph,
    pixmap: *const pixmap_mod.Pixmap,
    draw_props: DrawProps,
    font_size: f32,
    upem: f32,
    bitmap_glyph: *const bitmap_mod.BitmapGlyph,
    bitmap_format: ?bitmap_mod.Format,
) kurbo.Affine {
    const x_scale_factor = font_size / bitmap_glyph.ppem_x;
    const y_scale_factor = font_size / bitmap_glyph.ppem_y;
    const font_units_to_size = font_size / upem;

    // CoreText appears to special-case Apple Color Emoji, adding a 100 font
    // unit vertical offset. We do the same, but only when the vertical offset
    // is 0 to avoid incorrect rendering if Apple ever encodes it directly.
    const bearing_y = if (bitmap_glyph.bearing_y == 0.0 and bitmap_format == .sbix)
        100.0
    else
        bitmap_glyph.bearing_y;

    const origin_shift = switch (bitmap_glyph.placement_origin) {
        .top_left => kurbo.Vec2.ZERO,
        .bottom_left => kurbo.Vec2.new(
            0.0,
            -@as(f64, @floatFromInt(pixmap.height)),
        ),
    };

    return draw_props
        .positionedTransform(glyph)
        // Apply outer bearings.
        .preTranslate(kurbo.Vec2.new(
            -bitmap_glyph.bearing_x * font_units_to_size,
            bearing_y * font_units_to_size,
        ))
        // Scale to pixel space.
        .preScaleNonUniform(x_scale_factor, y_scale_factor)
        // Apply inner bearings.
        .preTranslate(kurbo.Vec2.new(
            -bitmap_glyph.inner_bearing_x,
            -bitmap_glyph.inner_bearing_y,
        ))
        .preTranslate(origin_shift);
}

/// Renderer state for one prepared run.
///
/// `Glyphs` is any type with `pub fn next(self: *Glyphs) ?Glyph` (see
/// `GlyphSliceIterator`).
pub fn GlyphRunRenderer(comptime Glyphs: type) type {
    return struct {
        const Self = @This();

        prepared_run: PreparedGlyphRun,
        outline_cache: *outline_cache.OutlineCache,
        /// Horizontal spans excluded from "ink-skipping" decorations; reused
        /// across draws (upstream `underline_span_cache`).
        underline_span_cache: *std.ArrayListUnmanaged([2]f64),
        glyph_iterator: Glyphs,
        atlas_cacher: AtlasCacher,

        /// Fill the glyphs with the current configuration.
        pub fn fillGlyphs(self: *Self, allocator: std.mem.Allocator, renderer: anytype) !void {
            try self.drawGlyphs(allocator, .fill, renderer);
        }

        /// Stroke the glyphs with the current configuration.
        pub fn strokeGlyphs(self: *Self, allocator: std.mem.Allocator, renderer: anytype) !void {
            try self.drawGlyphs(allocator, .stroke, renderer);
        }

        /// Return the scaling factor that should be applied to the stroke
        /// width when stroking this glyph run.
        pub fn strokeAdjustment(self: *const Self) f64 {
            const run_size = self.prepared_run.run_size;
            if (run_size == 0.0) return 1.0;
            return @as(f64, self.prepared_run.draw_props.font_size / run_size);
        }

        /// Render a decoration (like an underline) that skips over glyph
        /// descenders.
        ///
        /// Implements `text-decoration-skip-ink`-like behavior: the line is
        /// interrupted where it would overlap glyph outlines. `x_range` is the
        /// horizontal span in run space; `baseline_y` places it vertically;
        /// `offset` (positive = above the baseline, font space) and `size`
        /// give its position and thickness; `buffer` widens each exclusion.
        pub fn renderDecoration(
            self: *Self,
            allocator: std.mem.Allocator,
            x_range: [2]f32,
            baseline_y: f32,
            offset: f32,
            size: f32,
            buffer: f32,
            renderer: anytype,
        ) !void {
            interface.assertGlyphRenderer(@TypeOf(renderer.*));
            try self.decorationSpans(
                allocator,
                x_range,
                baseline_y,
                offset,
                size,
                buffer,
                renderer,
            );
        }

        /// Port of upstream `GlyphRunRenderer::decoration_spans`.
        ///
        /// The upstream method returns a lazy iterator over the merged
        /// exclusion list and `render_decoration` drains it into
        /// `fill_rect` calls. Here the collection and the emission are one
        /// pass; the numeric order of the emitted rectangles is identical.
        fn decorationSpans(
            self: *Self,
            allocator: std.mem.Allocator,
            x_range: [2]f32,
            baseline_y: f32,
            offset: f32,
            size: f32,
            buffer: f32,
            renderer: anytype,
        ) !void {
            const prepared = &self.prepared_run;
            const hinting_instance = prepared.hinting_instance;
            const hinted = hinting_instance != null;

            // Upstream derives the scale from the prepared run's hint state.
            const scale_props = GlyphScaleProperties.new(
                prepared.draw_props.font_size,
                prepared.font_info.upem,
                hinted,
                .fill,
            );
            // adapt: upstream widens an f32 division (`run_size / cache_size`)
            // to f64; keep the intermediate in f32.
            const outline_to_nominal_scale: f64 = @as(f64, prepared.run_size / scale_props.cache_size);
            const glyph_transform = prepared.glyph_transform orelse kurbo.Affine.IDENTITY;
            const outline_transform = glyph_transform
                .compose(kurbo.Affine.scaleNonUniform(1.0, -1.0))
                .compose(kurbo.Affine.scale(outline_to_nominal_scale));

            const buffer_f: f64 = @floatCast(buffer);
            const x0: f64 = @floatCast(x_range[0]);
            const x1: f64 = @floatCast(x_range[1]);
            const layout_y0: f64 = @floatCast(-offset);
            const layout_y1: f64 = @floatCast(-offset + size);

            // Collect and merge exclusion zones from all glyphs.
            self.underline_span_cache.clearRetainingCapacity();

            while (self.glyph_iterator.next()) |glyph| {
                // Upstream `outlines.get()` returns `None` for glyph ids the
                // font does not contain and skips them.
                if (!prepared.outlines.hasGlyph(glyph.id)) continue;

                const cached = try self.outline_cache.getOrInsert(
                    allocator,
                    &prepared.outlines,
                    glyph.id,
                    prepared.font_info,
                    scale_props.cache_size,
                    prepared.font_embolden,
                    prepared.normalized_coords,
                    hinting_instance,
                );

                // If the glyph's bounding box doesn't intersect the decoration
                // at all, skip the (much more expensive) segment intersections.
                // Only the y-extent of the transformed bbox is needed:
                // y' = b*x + d*y + f.
                const c = outline_transform.asCoeffs();
                const b = c[1];
                const d = c[3];
                const f = c[5];
                const bx0 = b * cached.bbox.x0;
                const bx1 = b * cached.bbox.x1;
                const dy0 = d * cached.bbox.y0;
                const dy1 = d * cached.bbox.y1;
                const y_min = f + @min(bx0, bx1) + @min(dy0, dy1);
                const y_max = f + @max(bx0, bx1) + @max(dy0, dy1);
                if (y_max < layout_y0 or y_min > layout_y1) continue;

                var rect = kurbo.Rect.new(
                    std.math.inf(f64),
                    layout_y0,
                    -std.math.inf(f64),
                    layout_y1,
                );

                var segments = cached.path.segments();
                while (segments.next()) |segment| {
                    const transformed = segment.transform(outline_transform);
                    expandRectWithSegment(&rect, transformed, layout_y0, layout_y1);
                }

                // Add glyph position and buffer, then clip to the decoration
                // x-range.
                const glyph_x: f64 = @floatCast(glyph.x);
                const excl_start = @max(rect.x0 + glyph_x - buffer_f, x0);
                const excl_end = @min(rect.x1 + glyph_x + buffer_f, x1);

                // Skip if no valid exclusion (empty intersection or outside
                // the x-range).
                if (excl_start >= excl_end) continue;

                // Insert in sorted order and merge with overlapping ranges.
                try insertAndMergeRange(
                    self.underline_span_cache,
                    allocator,
                    excl_start,
                    excl_end,
                );
            }

            // Draw decoration segments, skipping the exclusion zones.
            const y0 = @as(f64, @floatCast(baseline_y)) + layout_y0;
            const y1 = @as(f64, @floatCast(baseline_y)) + layout_y1;

            var current_x = x0;
            for (self.underline_span_cache.items) |range| {
                // adapt: upstream emits the pre-exclusion rectangle
                // unconditionally (it may be empty or inverted); only the
                // trailing rectangle is width-filtered.
                try renderer.fillRect(allocator, kurbo.Rect.new(current_x, y0, range[0], y1));
                current_x = range[1];
            }

            const final_rect = kurbo.Rect.new(current_x, y0, x1, y1);
            if (final_rect.width() > 0.0) {
                try renderer.fillRect(allocator, final_rect);
            }
        }

        fn drawGlyphs(
            self: *Self,
            allocator: std.mem.Allocator,
            style: Style,
            renderer: anytype,
        ) !void {
            interface.assertGlyphRenderer(@TypeOf(renderer.*));

            const prepared = &self.prepared_run;
            const hinted = prepared.hinting_instance != null;

            const cache_config = self.atlas_cacher.config();
            const colr_bitmap_cache_enabled = if (cache_config) |config|
                self.prepared_run.draw_props.font_size <= config.max_cached_font_size
            else
                false;
            const outline_cache_enabled = colr_bitmap_cache_enabled and
                style == .fill and
                switch (renderer.currentPaint().*) {
                    .solid => true,
                    else => false,
                };

            const scale_props = GlyphScaleProperties.new(
                prepared.draw_props.font_size,
                prepared.font_info.upem,
                hinted,
                style,
            );

            while (self.glyph_iterator.next()) |glyph| {
                // ── Speculative outline cache check ───────────────────────
                // ~99% of glyphs are outlines. The transform and cache key
                // are pure arithmetic, so probe the cache before the
                // expensive COLR lookup. On a miss both are reused by the
                // outline branch below.
                const outline_transform = calculateOutlineTransform(glyph, prepared.draw_props, hinted);
                const outline_draw_transform = outline_transform.preScale(scale_props.draw_scale);

                var outline_cache_key: ?atlas.GlyphCacheKey = null;
                if (outline_cache_enabled) {
                    const fractional_x = outline_transform.translation().x;
                    outline_cache_key = atlas.key.newKey(
                        prepared.font_info.id,
                        prepared.font_info.index,
                        glyph.id,
                        prepared.draw_props.font_size,
                        hinted,
                        @as(f32, @floatCast(fractional_x - @trunc(fractional_x))),
                        peniko.Color.BLACK,
                        atlas.key.packColor(peniko.Color.BLACK),
                        prepared.font_embolden,
                        prepared.normalized_coords,
                    );
                    if (self.atlas_cacher.get(outline_cache_key.?)) |cached_slot| {
                        try renderer_mod.renderCachedGlyph(
                            allocator,
                            renderer,
                            cached_slot,
                            outline_transform,
                            .outline,
                        );
                        continue;
                    }
                }

                // ── COLR glyphs ───────────────────────────────────────────
                if (prepared.color_glyphs.get(glyph.id)) |color_glyph| {
                    // `Var*` records in a COLRv1 paint graph are resolved
                    // against the run's coordinates by `skrifa` when the COLR
                    // table carries a variation store. That
                    // `ItemVariationStore` path is not ported, so non-default
                    // coordinates are a typed error rather than a
                    // default-variation approximation. Without a store (or
                    // for COLRv0) variation deltas are always zero and the
                    // coordinates are an exact no-op, like upstream.
                    if (color_glyph.format() == .colr_v1 and
                        color_glyph.colr.hasVarStore() and
                        glyf.effectiveCoords(prepared.normalized_coords).len != 0)
                    {
                        return error.Unsupported;
                    }
                    const metrics = try calculateColrMetrics(
                        allocator,
                        prepared,
                        glyph,
                        color_glyph,
                        self.outline_cache,
                    );
                    const colr_transform = calculateColrTransform(&metrics);

                    // COLR glyphs are never hinted and have no sub-pixel
                    // offset; the context color is part of the key because it
                    // affects painted layers.
                    const context_color = renderer_mod.contextColor(renderer.currentPaint());
                    const colr_cache_key: ?atlas.GlyphCacheKey = if (colr_bitmap_cache_enabled) blk: {
                        var key = atlas.key.newKey(
                            prepared.font_info.id,
                            prepared.font_info.index,
                            glyph.id,
                            prepared.draw_props.font_size,
                            false,
                            0.0,
                            context_color,
                            atlas.key.packColor(context_color),
                            FontEmbolden{},
                            prepared.normalized_coords,
                        );
                        key.subpixel_x = atlas.key.SUBPIXEL_COLR;
                        break :blk key;
                    } else null;

                    if (colr_cache_key) |key| {
                        if (self.atlas_cacher.get(key)) |cached_slot| {
                            // Use fractional scaled-bbox dimensions to
                            // preserve sub-pixel accuracy.
                            const area = kurbo.Rect.new(
                                0.0,
                                0.0,
                                metrics.scaled_bbox.width(),
                                metrics.scaled_bbox.height(),
                            );
                            try renderer_mod.renderCachedGlyph(
                                allocator,
                                renderer,
                                cached_slot,
                                colr_transform,
                                .{ .colr = area },
                            );
                            continue;
                        }
                    }

                    // Cache miss: rasterize the COLR glyph from scratch.
                    const prepared_glyph: PreparedGlyph = .{
                        .glyph_type = .{ .colr = createColrGlyph(prepared, &metrics, color_glyph) },
                        .outline_transform = colr_transform,
                        .relative_paint_transform = kurbo.Affine.IDENTITY,
                        .cache_key = colr_cache_key,
                    };
                    switch (style) {
                        .fill => try renderer_mod.fillGlyph(
                            allocator,
                            renderer,
                            &prepared_glyph,
                            &self.atlas_cacher,
                            self.outline_cache,
                        ),
                        .stroke => try renderer_mod.strokeGlyph(
                            allocator,
                            renderer,
                            &prepared_glyph,
                            &self.atlas_cacher,
                            self.outline_cache,
                        ),
                    }
                    continue;
                }

                // ── Bitmap glyphs ─────────────────────────────────────────
                if (prepared.bitmap_strikes.glyphForSize(
                    prepared.draw_props.font_size,
                    glyph.id,
                )) |bitmap_glyph| {
                    if (try decodeBitmapPixmap(allocator, &bitmap_glyph)) |pixmap| {
                        defer pixmap.release(allocator);

                        // Bitmaps use the strike's own ppem, not the run's,
                        // because the image was pre-rendered at that size.
                        const bitmap_ppem = bitmap_glyph.ppem_x;
                        const bitmap_transform = calculateBitmapTransform(
                            glyph,
                            pixmap.get(),
                            prepared.draw_props,
                            prepared.draw_props.font_size,
                            prepared.font_info.upem,
                            &bitmap_glyph,
                            prepared.bitmap_strikes.format(),
                        );

                        // Bitmaps are not hinted and have no sub-pixel offset
                        // or context color; variation coordinates are
                        // irrelevant for fixed strikes.
                        const bitmap_cache_key: ?atlas.GlyphCacheKey =
                            if (colr_bitmap_cache_enabled) blk: {
                                var key = atlas.key.newKey(
                                    prepared.font_info.id,
                                    prepared.font_info.index,
                                    glyph.id,
                                    bitmap_ppem,
                                    false,
                                    0.0,
                                    peniko.Color.BLACK,
                                    atlas.key.packColor(peniko.Color.BLACK),
                                    FontEmbolden{},
                                    &.{},
                                );
                                key.subpixel_x = atlas.key.SUBPIXEL_BITMAP;
                                break :blk key;
                            } else null;

                        if (bitmap_cache_key) |key| {
                            if (self.atlas_cacher.get(key)) |cached_slot| {
                                try renderer_mod.renderCachedGlyph(
                                    allocator,
                                    renderer,
                                    cached_slot,
                                    bitmap_transform,
                                    .bitmap,
                                );
                                continue;
                            }
                        }

                        // Cache miss: wrap the decoded pixmap for rendering.
                        // The reference is released after the draw, so a
                        // pending upload (which retains its own reference)
                        // survives into the next frame.
                        const pixmap_reference = pixmap.clone();
                        defer pixmap_reference.release(allocator);
                        const prepared_glyph: PreparedGlyph = .{
                            .glyph_type = .{ .bitmap = createBitmapGlyph(pixmap_reference) },
                            .outline_transform = bitmap_transform,
                            .relative_paint_transform = kurbo.Affine.IDENTITY,
                            .cache_key = bitmap_cache_key,
                        };
                        switch (style) {
                            .fill => try renderer_mod.fillGlyph(
                                allocator,
                                renderer,
                                &prepared_glyph,
                                &self.atlas_cacher,
                                self.outline_cache,
                            ),
                            .stroke => try renderer_mod.strokeGlyph(
                                allocator,
                                renderer,
                                &prepared_glyph,
                                &self.atlas_cacher,
                                self.outline_cache,
                            ),
                        }
                        continue;
                    }
                }

                // ── Outline glyphs ────────────────────────────────────────
                // A bitmap-only face has an empty outline collection; every
                // lookup reports `OutOfBounds` and the glyph is skipped, like
                // upstream's empty `OutlineGlyphCollection`.
                if (!prepared.has_outlines) continue;
                // The speculative check above already computed the transform
                // and key; reuse them here.
                // Upstream `outlines.get()` returns `None` for out-of-range
                // glyph ids and skips them.
                if (!prepared.outlines.hasGlyph(glyph.id)) continue;

                const cached_outline = try self.outline_cache.getOrInsert(
                    allocator,
                    &prepared.outlines,
                    glyph.id,
                    prepared.font_info,
                    scale_props.cache_size,
                    prepared.font_embolden,
                    prepared.normalized_coords,
                    prepared.hinting_instance,
                );

                const relative_paint_transform = outline_draw_transform
                    .inverse()
                    .compose(prepared.scene_paint_transform);

                const prepared_glyph: PreparedGlyph = .{
                    .glyph_type = .{ .outline = .{
                        .path = cached_outline.path,
                        .bbox = cached_outline.bbox,
                        .scale = scale_props.draw_scale,
                    } },
                    .outline_transform = outline_transform,
                    .relative_paint_transform = relative_paint_transform,
                    .cache_key = outline_cache_key,
                };

                switch (style) {
                    .fill => try renderer_mod.fillGlyph(
                        allocator,
                        renderer,
                        &prepared_glyph,
                        &self.atlas_cacher,
                        self.outline_cache,
                    ),
                    .stroke => try renderer_mod.strokeGlyph(
                        allocator,
                        renderer,
                        &prepared_glyph,
                        &self.atlas_cacher,
                        self.outline_cache,
                    ),
                }
            }
        }
    };
}

/// Insert a range into a sorted list, merging with any overlapping ranges.
///
/// Port of upstream `insert_and_merge_range`; `ranges` stays sorted and
/// non-overlapping. The allocator is explicit because the Zig `Vec` is
/// `ArrayListUnmanaged`.
fn insertAndMergeRange(
    ranges: *std.ArrayListUnmanaged([2]f64),
    allocator: std.mem.Allocator,
    start: f64,
    end: f64,
) std.mem.Allocator.Error!void {
    // Search backwards from the end to find the insertion point. Glyphs come
    // in visual (left-to-right) order, so new ranges are usually at or near
    // the end, making this O(1) in the common case.
    var insert_pos: usize = 0;
    var i = ranges.items.len;
    while (i > 0) {
        i -= 1;
        if (ranges.items[i][0] <= start) {
            insert_pos = i + 1;
            break;
        }
    }

    // Check whether the previous range overlaps the new one.
    const merge_start = if (insert_pos > 0 and ranges.items[insert_pos - 1][1] >= start)
        insert_pos - 1
    else
        insert_pos;

    // Find all overlapping ranges and compute the merged bounds.
    var new_end = end;
    var j = merge_start;
    while (j < ranges.items.len and ranges.items[j][0] <= end) : (j += 1) {
        new_end = @max(new_end, ranges.items[j][1]);
    }
    var merge_end = merge_start;
    while (merge_end < ranges.items.len and ranges.items[merge_end][0] <= new_end) {
        merge_end += 1;
    }

    // Replace the overlapping ranges with the merged range.
    if (merge_start < merge_end) {
        const new_start = @min(start, ranges.items[merge_start][0]);
        try ranges.replaceRange(
            allocator,
            merge_start,
            merge_end - merge_start,
            &.{.{ new_start, new_end }},
        );
    } else {
        try ranges.insert(allocator, insert_pos, .{ start, end });
    }
}

/// Expand `rect`'s x-bounds by where `seg` intersects the decoration's top
/// and bottom lines.
///
/// Port of upstream `expand_rect_with_segment`. The bounds are deliberately
/// rough (control-point hull plus intersection with two horizontal lines):
/// this matches upstream's skip-ink geometry, not a tight bbox.
fn expandRectWithSegment(
    rect: *kurbo.Rect,
    seg: kurbo.PathSeg,
    y_start: f64,
    y_end: f64,
) void {
    var x_min: f64 = undefined;
    var x_max: f64 = undefined;
    var y_min: f64 = undefined;
    var y_max: f64 = undefined;
    switch (seg) {
        .Line => |line| {
            x_min = @min(line.p0.x, line.p1.x);
            x_max = @max(line.p0.x, line.p1.x);
            y_min = @min(line.p0.y, line.p1.y);
            y_max = @max(line.p0.y, line.p1.y);
        },
        .Quad => |quad| {
            x_min = @min(@min(quad.p0.x, quad.p1.x), quad.p2.x);
            x_max = @max(@max(quad.p0.x, quad.p1.x), quad.p2.x);
            y_min = @min(@min(quad.p0.y, quad.p1.y), quad.p2.y);
            y_max = @max(@max(quad.p0.y, quad.p1.y), quad.p2.y);
        },
        .Cubic => |cubic| {
            x_min = @min(@min(@min(cubic.p0.x, cubic.p1.x), cubic.p2.x), cubic.p3.x);
            x_max = @max(@max(@max(cubic.p0.x, cubic.p1.x), cubic.p2.x), cubic.p3.x);
            y_min = @min(@min(@min(cubic.p0.y, cubic.p1.y), cubic.p2.y), cubic.p3.y);
            y_max = @max(@max(@max(cubic.p0.y, cubic.p1.y), cubic.p2.y), cubic.p3.y);
        },
    }
    // Skip segments entirely outside the y-span.
    if (y_max < y_start or y_min > y_end) return;

    // Only the x-intersections matter. The intersection methods do not work
    // on infinitely long lines, so construct a "long enough" line based on
    // the segment bounds (expanded for a little error).
    x_min -= 1.0;
    x_max += 1.0;
    const top_line = kurbo.Line.new(
        kurbo.Point.new(x_min, y_start),
        kurbo.Point.new(x_max, y_start),
    );
    const bottom_line = kurbo.Line.new(
        kurbo.Point.new(x_min, y_end),
        kurbo.Point.new(x_max, y_end),
    );

    const top_intersections = seg.intersectLine(top_line);
    for (top_intersections.slice()) |intersection| {
        const point = top_line.eval(intersection.line_t);
        // There might be slight inaccuracy calculating `point` from `line_t`,
        // so only the x-values are adjusted (upstream `union_pt` would also
        // expand y).
        rect.x0 = @min(rect.x0, point.x);
        rect.x1 = @max(rect.x1, point.x);
    }

    const bottom_intersections = seg.intersectLine(bottom_line);
    for (bottom_intersections.slice()) |intersection| {
        const point = bottom_line.eval(intersection.line_t);
        rect.x0 = @min(rect.x0, point.x);
        rect.x1 = @max(rect.x1, point.x);
    }

    // Also check segment endpoints that lie within the y-range.
    const endpoints: [2]kurbo.Point = switch (seg) {
        .Line => |line| .{ line.p0, line.p1 },
        .Quad => |quad| .{ quad.p0, quad.p2 },
        .Cubic => |cubic| .{ cubic.p0, cubic.p3 },
    };
    for (endpoints) |point| {
        if (point.y >= y_start and point.y <= y_end) {
            rect.x0 = @min(rect.x0, point.x);
            rect.x1 = @max(rect.x1, point.x);
        }
    }
}

/// Build a renderer for a glyph run.
///
/// `glyphs` is any iterator value with `next() ?Glyph`; `prep_cache` and
/// `atlas_cacher` borrow their owners for the duration of the draw.
pub fn buildRenderer(
    allocator: std.mem.Allocator,
    run: GlyphRun,
    glyphs: anytype,
    prep_cache: GlyphPrepCacheMut,
    atlas_cacher: AtlasCacher,
) Error!GlyphRunRenderer(@TypeOf(glyphs)) {
    const prepared_run = try prepareGlyphRunWithCache(run, prep_cache.hint_cache, allocator);
    return .{
        .prepared_run = prepared_run,
        .outline_cache = prep_cache.outline_cache,
        .underline_span_cache = prep_cache.underline_exclusions,
        .glyph_iterator = glyphs,
        .atlas_cacher = atlas_cacher,
    };
}

// --------------------------------------------------------------------- tests

const testing = std.testing;
const test_fixture = @import("test_fixture.zig");

fn testFontData() !FontData {
    return FontData.init(try test_fixture.roboto(), 0);
}

/// Minimal renderer recording draws (upstream `NoopRenderer` in `glyph.rs`).
const RecordingRenderer = struct {
    transform: kurbo.Affine = kurbo.Affine.IDENTITY,
    paint: paint_mod.PaintType = paint_mod.PaintType.fromAlphaColor(peniko.Color.BLACK),
    paint_transform: kurbo.Affine = kurbo.Affine.IDENTITY,
    fill_count: usize = 0,
    stroke_count: usize = 0,
    fill_rect_count: usize = 0,
    tint: ?paint_mod.Tint = null,
    last_fill_rect: kurbo.Rect = kurbo.Rect.ZERO,
    /// Every rectangle passed to `fillRect`, in call order (decoration spans
    /// include empty/inverted pre-exclusion rectangles, like upstream).
    fill_rects: std.ArrayListUnmanaged(kurbo.Rect) = .empty,

    pub fn saveState(self: *RecordingRenderer) !RenderStateClone {
        return .{
            .transform = self.transform,
            .paint = try self.paint.clone(std.testing.allocator),
            .paint_transform = self.paint_transform,
            .tint = self.tint,
        };
    }

    pub fn restoreState(self: *RecordingRenderer, state: RenderStateClone) void {
        self.paint.deinit(std.testing.allocator);
        self.transform = state.transform;
        self.paint = state.paint;
        self.paint_transform = state.paint_transform;
        self.tint = state.tint;
    }

    pub const RenderStateClone = struct {
        transform: kurbo.Affine,
        paint: paint_mod.PaintType,
        paint_transform: kurbo.Affine,
        tint: ?paint_mod.Tint,
    };

    pub fn setTransform(self: *RecordingRenderer, t: kurbo.Affine) void {
        self.transform = t;
    }

    pub fn setPaintTransform(self: *RecordingRenderer, t: kurbo.Affine) void {
        self.paint_transform = t;
    }

    pub fn setPaint(self: *RecordingRenderer, paint: paint_mod.PaintType) void {
        // Tests run under the testing allocator; free the previous owned
        // payload (gradients from COLR paints) like `RenderContext.setPaint`.
        self.paint.deinit(std.testing.allocator);
        self.paint = paint;
    }

    /// Release the currently held paint payload and recorded decoration
    /// rectangles at test end.
    pub fn deinit(self: *RecordingRenderer) void {
        self.paint.deinit(std.testing.allocator);
        self.paint = paint_mod.PaintType.fromAlphaColor(peniko.Color.BLACK);
        self.fill_rects.deinit(std.testing.allocator);
        self.fill_rects = .empty;
    }

    pub fn fillPath(self: *RecordingRenderer, allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void {
        _ = allocator;
        _ = path;
        self.fill_count += 1;
    }

    pub fn strokePath(self: *RecordingRenderer, allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void {
        _ = allocator;
        _ = path;
        self.stroke_count += 1;
    }

    pub fn fillRect(self: *RecordingRenderer, allocator: std.mem.Allocator, rect: kurbo.Rect) !void {
        self.last_fill_rect = rect;
        self.fill_rect_count += 1;
        try self.fill_rects.append(allocator, rect);
    }

    pub fn pushClipLayer(self: *RecordingRenderer, allocator: std.mem.Allocator, clip: []const kurbo.PathEl) !void {
        _ = self;
        _ = allocator;
        _ = clip;
    }

    pub fn pushClipPath(self: *RecordingRenderer, allocator: std.mem.Allocator, clip: []const kurbo.PathEl) !void {
        _ = self;
        _ = allocator;
        _ = clip;
    }

    pub fn pushBlendLayer(self: *RecordingRenderer, blend_mode: peniko.BlendMode) !void {
        _ = self;
        _ = blend_mode;
    }

    pub fn popLayer(self: *RecordingRenderer) void {
        _ = self;
    }

    pub fn popClipPath(self: *RecordingRenderer) void {
        _ = self;
    }

    pub fn setTint(self: *RecordingRenderer, tint: ?paint_mod.Tint) void {
        self.tint = tint;
    }

    pub fn currentPaint(self: *const RecordingRenderer) *const paint_mod.PaintType {
        return &self.paint;
    }

    pub fn atlasImageSource(
        self: *const RecordingRenderer,
        image_id: u32,
        page_index: u32,
    ) paint_mod.ImageSource {
        _ = self;
        _ = image_id;
        return paint_mod.ImageSource.initOpaqueId(paint_mod.ImageId.new(page_index));
    }

    pub fn atlasPaintTransform(self: *const RecordingRenderer, x: u16, y: u16) kurbo.Affine {
        _ = self;
        return kurbo.Affine.translate(kurbo.Vec2.new(
            -@as(f64, @floatFromInt(x)),
            -@as(f64, @floatFromInt(y)),
        ));
    }

    pub fn width(self: *const RecordingRenderer) u16 {
        _ = self;
        return 64;
    }

    pub fn height(self: *const RecordingRenderer) u16 {
        _ = self;
        return 64;
    }
};

fn drawTestGlyph(
    allocator: std.mem.Allocator,
    font: FontData,
    glyph: Glyph,
    atlas_cache_enabled: bool,
    style: Style,
    renderer: *RecordingRenderer,
    prep_cache: *GlyphPrepCache,
    glyph_atlas: *atlas.GlyphAtlas,
    image_cache: *atlas.ImageCache,
) !void {
    const transform = kurbo.Affine.translate(kurbo.Vec2.new(0.0, 20.0));
    const run: GlyphRun = .{
        .font = font,
        .font_size = 20.0,
        .transform = transform,
        .scene_paint_transform = transform,
        .hint = false,
    };
    const cacher: AtlasCacher = if (atlas_cache_enabled)
        .{ .enabled = .{ .glyph_atlas = glyph_atlas, .image_cache = image_cache } }
    else
        .disabled;
    const iterator = iterate(&.{glyph});
    var run_renderer = try buildRenderer(allocator, run, iterator, prep_cache.asMut(), cacher);
    switch (style) {
        .fill => try run_renderer.fillGlyphs(allocator, renderer),
        .stroke => try run_renderer.strokeGlyphs(allocator, renderer),
    }
}

fn ensureCache(style: Style) !void {
    const allocator = testing.allocator;
    const font = try testFontData();
    const glyph = Glyph{ .id = 37 };

    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    try drawTestGlyph(allocator, font, glyph, true, style, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expectEqual(@as(u64, 0), glyph_atlas.cacheHits());
    try testing.expect(glyph_atlas.cacheMisses() > 0);

    try drawTestGlyph(allocator, font, glyph, true, style, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expectEqual(@as(u64, 1), glyph_atlas.cacheHits());
    try testing.expect(glyph_atlas.cacheMisses() > 0);
}

fn ensureNoCache(style: Style, atlas_cache_enabled: bool) !void {
    const allocator = testing.allocator;
    const font = try testFontData();
    const glyph = Glyph{ .id = 37 };

    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    try drawTestGlyph(allocator, font, glyph, atlas_cache_enabled, style, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 0), glyph_atlas.len());
    try testing.expectEqual(@as(u64, 0), glyph_atlas.cacheHits());
    try testing.expectEqual(@as(u64, 0), glyph_atlas.cacheMisses());
}

test "outline glyph is cached when atlas cache is enabled" {
    try ensureCache(.fill);
}

test "outline glyph is not cached when atlas cache is disabled" {
    try ensureNoCache(.fill, false);
}

test "stroked outline glyph is not cached" {
    try ensureNoCache(.stroke, true);
    try ensureNoCache(.stroke, false);
}

test "hinted run is rejected with Unsupported" {
    const allocator = testing.allocator;
    const font = try testFontData();
    const run: GlyphRun = .{
        .font = font,
        .font_size = 20.0,
        .transform = kurbo.Affine.translate(kurbo.Vec2.new(0.0, 20.0)),
        .scene_paint_transform = kurbo.Affine.translate(kurbo.Vec2.new(0.0, 20.0)),
        .hint = true,
    };
    try testing.expectError(error.Unsupported, prepareGlyphRun(run));
    _ = allocator;
}

test "non-empty variation coordinates are accepted and embolden is rejected" {
    const font = try testFontData();
    const base: GlyphRun = .{
        .font = font,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    // Roboto has no `gvar`, so coordinates are a no-op but must not fail.
    var with_coords = base;
    with_coords.normalized_coords = &.{0};
    const prepared = try prepareGlyphRun(with_coords);
    try testing.expectEqualSlices(
        NormalizedCoord,
        &.{0},
        prepared.normalized_coords,
    );

    var with_embolden = base;
    with_embolden.font_embolden = FontEmbolden.new(.{ 1.0, 0.0 });
    try testing.expectError(error.Unsupported, prepareGlyphRun(with_embolden));
}

test "unhinted run absorbs uniform scale" {
    const font = try testFontData();
    const run: GlyphRun = .{
        .font = font,
        .font_size = 10.0,
        .transform = kurbo.Affine.scale(2.0),
        .scene_paint_transform = kurbo.Affine.scale(2.0),
        .hint = false,
    };
    const prepared = try prepareGlyphRun(run);
    try testing.expectEqual(@as(f32, 20.0), prepared.draw_props.font_size);
    try testing.expectEqualDeep(
        kurbo.Affine.IDENTITY.asCoeffs(),
        prepared.draw_props.effective_transform.asCoeffs(),
    );
    // Transformation order: glyph positions are scaled by the original run
    // transform, outlines by the absorbed draw transform.
    const placement = prepared.draw_props.positionedTransform(.{ .x = 3.0, .y = 0.0 });
    try testing.expectEqual(@as(f64, 6.0), placement.c[4]);
    try testing.expectEqual(@as(f64, 0.0), placement.c[5]);
}

test "prepare accepts COLR fonts and exposes their color glyphs" {
    const noto_colr = FontData.init(try test_fixture.notoColor(), 0);
    const run: GlyphRun = .{
        .font = noto_colr,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    const prepared = try prepareGlyphRun(run);
    // "✅" is glyph 2 in the subset and is a COLRv1 glyph.
    try testing.expect(prepared.color_glyphs.get(2) != null);
    try testing.expect(prepared.cpal != null);
    try testing.expect(prepared.color_glyphs.get(3) != null);
}

test "prepare accepts bitmap fonts and exposes their strikes" {
    const noto_cbtf = FontData.init(try test_fixture.notoCbtf(), 0);
    const run: GlyphRun = .{
        .font = noto_cbtf,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    const prepared = try prepareGlyphRun(run);
    // The subset has no `glyf`/`loca`, so the outline collection is empty and
    // the cascade resolves glyphs through the CBDT strike.
    try testing.expect(!prepared.has_outlines);
    try testing.expectEqual(bitmap_mod.Format.cbdt, prepared.bitmap_strikes.format().?);
    try testing.expectEqual(@as(usize, 1), prepared.bitmap_strikes.len());
    try testing.expect(prepared.bitmap_strikes.glyphForSize(50.0, 2) != null);
}

test "bitmap glyphs decode to premultiplied pixmaps" {
    const allocator = testing.allocator;
    const font = try font_mod.Font.init(try test_fixture.notoCbtf(), 0);
    const strikes = font.bitmapStrikes();
    const bitmap_glyph = strikes.glyphForSize(50.0, 1).?;

    const pixmap = (try decodeBitmapPixmap(allocator, &bitmap_glyph)).?;
    defer pixmap.release(allocator);
    try testing.expectEqual(@as(u16, 136), pixmap.get().width);
    try testing.expectEqual(@as(u16, 128), pixmap.get().height);
    try testing.expect(pixmap.get().mayHaveTransparency());

    // `Bgra`/`Mask` payloads are skipped (upstream returns `None`), so the
    // caller can fall through to the outline branch.
    var bgra_glyph = bitmap_glyph;
    bgra_glyph.data = .{ .bgra = &.{} };
    try testing.expect((try decodeBitmapPixmap(allocator, &bgra_glyph)) == null);
    var mask_glyph = bitmap_glyph;
    mask_glyph.data = .{ .mask = .{ .bpp = 1, .is_packed = false, .data = &.{} } };
    try testing.expect((try decodeBitmapPixmap(allocator, &mask_glyph)) == null);
}

fn drawBitmapTestGlyph(
    allocator: std.mem.Allocator,
    glyph_id: u32,
    atlas_cache_enabled: bool,
    renderer: *RecordingRenderer,
    prep_cache: *GlyphPrepCache,
    glyph_atlas: *atlas.GlyphAtlas,
    image_cache: *atlas.ImageCache,
) !void {
    const font = FontData.init(try test_fixture.notoCbtf(), 0);
    const transform = kurbo.Affine.translate(kurbo.Vec2.new(0.0, 20.0));
    const run: GlyphRun = .{
        .font = font,
        .font_size = 20.0,
        .transform = transform,
        .scene_paint_transform = transform,
        .hint = false,
    };
    const cacher: AtlasCacher = if (atlas_cache_enabled)
        .{ .enabled = .{ .glyph_atlas = glyph_atlas, .image_cache = image_cache } }
    else
        .disabled;
    const glyphs = [_]Glyph{.{ .id = glyph_id }};
    const iterator = iterate(&glyphs);
    var run_renderer = try buildRenderer(allocator, run, iterator, prep_cache.asMut(), cacher);
    try run_renderer.fillGlyphs(allocator, renderer);
}

test "bitmap glyph with the atlas cache queues an upload and hits next draw" {
    const allocator = testing.allocator;
    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    try drawBitmapTestGlyph(allocator, 2, true, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expectEqual(@as(usize, 1), glyph_atlas.pendingUploads().len);
    try testing.expectEqual(@as(u64, 0), glyph_atlas.cacheHits());
    try testing.expectEqual(@as(usize, 1), renderer.fill_rect_count);
    // The slot is the decoded pixmap size (136x128), not the strike metrics.
    try testing.expectEqual(@as(u16, 136), glyph_atlas.pendingUploads()[0].atlas_slot.width);

    try drawBitmapTestGlyph(allocator, 2, true, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expectEqual(@as(u64, 1), glyph_atlas.cacheHits());
    try testing.expectEqual(@as(usize, 1), glyph_atlas.pendingUploads().len);
    try testing.expectEqual(@as(usize, 2), renderer.fill_rect_count);

    // Dropping the queued upload releases its pixmap reference.
    glyph_atlas.clearPendingUploads(allocator);
    try testing.expectEqual(@as(usize, 0), glyph_atlas.pendingUploads().len);
}

test "bitmap glyph without the atlas cache draws directly" {
    const allocator = testing.allocator;
    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    try drawBitmapTestGlyph(allocator, 2, false, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 0), glyph_atlas.len());
    try testing.expectEqual(@as(usize, 0), glyph_atlas.pendingUploads().len);
    try testing.expectEqual(@as(usize, 1), renderer.fill_rect_count);
}

fn ensureColrCache() !void {
    const allocator = testing.allocator;
    const font = FontData.init(try test_fixture.notoColor(), 0);
    const glyph = Glyph{ .id = 2 };

    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    try drawTestGlyph(allocator, font, glyph, true, .fill, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expect(glyph_atlas.cacheMisses() > 0);

    try drawTestGlyph(allocator, font, glyph, true, .fill, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expectEqual(@as(u64, 1), glyph_atlas.cacheHits());
}

fn drawTestGlyphVariation(
    allocator: std.mem.Allocator,
    font: FontData,
    glyph: Glyph,
    coords: []const NormalizedCoord,
    renderer: *RecordingRenderer,
    prep_cache: *GlyphPrepCache,
    glyph_atlas: *atlas.GlyphAtlas,
    image_cache: *atlas.ImageCache,
) !void {
    const transform = kurbo.Affine.translate(kurbo.Vec2.new(0.0, 20.0));
    const run: GlyphRun = .{
        .font = font,
        .font_size = 20.0,
        .transform = transform,
        .scene_paint_transform = transform,
        .hint = false,
        .normalized_coords = coords,
    };
    const cacher: AtlasCacher = .{ .enabled = .{
        .glyph_atlas = glyph_atlas,
        .image_cache = image_cache,
    } };
    const iterator = iterate(&.{glyph});
    var run_renderer = try buildRenderer(allocator, run, iterator, prep_cache.asMut(), cacher);
    try run_renderer.fillGlyphs(allocator, renderer);
}

test "colr v1 variation stores reject non-default coordinates" {
    const allocator = testing.allocator;
    var blob = try allocator.dupe(u8, try test_fixture.colrTestGlyphs());
    defer allocator.free(blob);
    // The pinned COLRv1 test font carries no variation store (it is not a
    // variable font), so point `itemVariationStoreOffset` (COLR v1 header
    // bytes 30..34) at the header itself: present, never dereferenced by the
    // gate. This is the only fixture path that reaches the typed error.
    const face = try sfnt.Face.parse(blob, 0);
    var i: usize = 0;
    var colr_offset: usize = 0;
    while (i < face.num_tables) : (i += 1) {
        const record = face.recordAt(i) orelse break;
        if (std.mem.eql(u8, &record.tag, &sfnt.tag_colr)) {
            colr_offset = record.offset;
            break;
        }
    }
    try testing.expect(colr_offset != 0);
    blob[colr_offset + 30] = 0;
    blob[colr_offset + 31] = 0;
    blob[colr_offset + 32] = 0;
    blob[colr_offset + 33] = 34;
    const font = FontData.init(blob, 0);
    // Glyph 8 is a COLRv1 paint-graph base glyph in the test font.
    const glyph = Glyph{ .id = 8 };

    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    // Default coordinates still draw (nothing varies).
    try drawTestGlyphVariation(
        allocator,
        font,
        glyph,
        &.{},
        &renderer,
        &prep_cache,
        &glyph_atlas,
        &image_cache,
    );
    // Variable `Var*` deltas are not ported: reject instead of approximating.
    try testing.expectError(error.Unsupported, drawTestGlyphVariation(
        allocator,
        font,
        glyph,
        &.{0x4000},
        &renderer,
        &prep_cache,
        &glyph_atlas,
        &image_cache,
    ));
}

test "colr glyphs without a variation store treat coordinates as a no-op" {
    const allocator = testing.allocator;
    const font = FontData.init(try test_fixture.notoColor(), 0);
    const glyph = Glyph{ .id = 2 };

    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    // Noto's COLRv1 carries no variation store and the font has no
    // variation tables, so the coordinate slice only selects the variable
    // cache map.
    try drawTestGlyphVariation(
        allocator,
        font,
        glyph,
        &.{0x4000},
        &renderer,
        &prep_cache,
        &glyph_atlas,
        &image_cache,
    );
    try testing.expect(renderer.fill_rect_count > 0);
    try testing.expectEqual(@as(usize, 1), glyph_atlas.len());
    try testing.expectEqual(@as(usize, 1), glyph_atlas.variable_entries.count());
}

test "colr glyph is cached when atlas cache is enabled" {
    try ensureColrCache();
}

test "colr glyph is not cached when atlas cache is disabled" {
    const allocator = testing.allocator;
    const font = FontData.init(try test_fixture.notoColor(), 0);
    const glyph = Glyph{ .id = 2 };

    var renderer = RecordingRenderer{};
    defer renderer.deinit();
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);
    var glyph_atlas = atlas.GlyphAtlas.init();
    defer glyph_atlas.deinit(allocator);
    var image_cache = try atlas.ImageCache.initWithConfig(allocator, .{ .atlas_size = .{ 512, 512 } });
    defer image_cache.deinit(allocator);

    try drawTestGlyph(allocator, font, glyph, false, .fill, &renderer, &prep_cache, &glyph_atlas, &image_cache);
    try testing.expectEqual(@as(usize, 0), glyph_atlas.len());
    try testing.expectEqual(@as(u64, 0), glyph_atlas.cacheMisses());
}

// ------------------------------------------------------------ decoration

/// Glyphs of the first `glyph_run` in
/// `tests/scenes/glyph_run_decoration_offset_values_300x180.json`
/// (`font_size = 30`, `offset = -6`, `size = 1.5`, `buffer = 1.5`,
/// `x_range = [0, 176.408203]`).
const decoration_skip_ink_glyphs = [_]Glyph{
    .{ .id = 44, .x = 0.0, .y = 0.0 },
    .{ .id = 69, .x = 21.386719, .y = 0.0 },
    .{ .id = 84, .x = 37.705078, .y = 0.0 },
    .{ .id = 84, .x = 54.536133, .y = 0.0 },
    .{ .id = 93, .x = 71.367188, .y = 0.0 },
    .{ .id = 4, .x = 85.561523, .y = 0.0 },
    .{ .id = 78, .x = 92.988281, .y = 0.0 },
    .{ .id = 83, .x = 100.151367, .y = 0.0 },
    .{ .id = 93, .x = 117.260742, .y = 0.0 },
    .{ .id = 74, .x = 131.455078, .y = 0.0 },
    .{ .id = 89, .x = 141.870117, .y = 0.0 },
    .{ .id = 80, .x = 158.408203, .y = 0.0 },
};

/// Expected `fillRect` sequence for the glyphs above, in call order, as f64
/// bit patterns captured from the pinned oracle:
///
///     tools/oracle-rs/target/release/vellz-oracle --dump-decoration \
///         --scene tests/scenes/glyph_run_decoration_offset_values_300x180.json
///
/// The first five rectangles are the gaps before each skip-ink exclusion; the
/// last one is the trailing rectangle after the final descender.
const decoration_skip_ink_expected = [_][4]u64{
    .{ 0x0000000000000000, 0x4018000000000000, 0x404320c000000000, 0x401e000000000000 },
    .{ 0x4045fba000000000, 0x4018000000000000, 0x404b8b2000000000, 0x401e000000000000 },
    .{ 0x404e660000000000, 0x4018000000000000, 0x4051c64000000000, 0x401e000000000000 },
    .{ 0x40535fd5cabc9f67, 0x4018000000000000, 0x4056a25000000000, 0x401e000000000000 },
    .{ 0x40585232c5545386, 0x4018000000000000, 0x405d3f7000000000, 0x401e000000000000 },
    .{ 0x405ed905cabc9f67, 0x4018000000000000, 0x40660d1000000000, 0x401e000000000000 },
};

test "decoration skip-ink spans match the pinned oracle" {
    const allocator = testing.allocator;
    const font = try testFontData();
    var renderer = RecordingRenderer{};
    defer renderer.fill_rects.deinit(allocator);
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);

    const run: GlyphRun = .{
        .font = font,
        .font_size = 30.0,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    var run_renderer = try buildRenderer(
        allocator,
        run,
        iterate(&decoration_skip_ink_glyphs),
        prep_cache.asMut(),
        .disabled,
    );
    try run_renderer.renderDecoration(
        allocator,
        .{ 0.0, 176.408203 },
        0.0,
        -6.0,
        1.5,
        1.5,
        &renderer,
    );

    try testing.expectEqual(decoration_skip_ink_expected.len, renderer.fill_rects.items.len);
    for (decoration_skip_ink_expected, renderer.fill_rects.items) |expected, rect| {
        const actual: [4]u64 = .{
            @bitCast(rect.x0),
            @bitCast(rect.y0),
            @bitCast(rect.x1),
            @bitCast(rect.y1),
        };
        try testing.expectEqualDeep(expected, actual);
    }
}

test "decoration with no descenders emits one trailing rectangle" {
    const allocator = testing.allocator;
    const font = try testFontData();
    var renderer = RecordingRenderer{};
    defer renderer.fill_rects.deinit(allocator);
    var prep_cache = GlyphPrepCache{};
    defer prep_cache.deinit(allocator);

    // "HELLO" glyphs from
    // `tests/scenes/glyph_run_decoration_no_descenders_180x70.json`
    // (font_size 50, offset -2, size 2, buffer 1.5, x_range [0, 147.871094]).
    const hello_glyphs = [_]Glyph{
        .{ .id = 44, .x = 0.0, .y = 0.0 },
        .{ .id = 41, .x = 35.644531, .y = 0.0 },
        .{ .id = 48, .x = 64.0625, .y = 0.0 },
        .{ .id = 48, .x = 90.966797, .y = 0.0 },
        .{ .id = 51, .x = 117.871094, .y = 0.0 },
    };
    const run: GlyphRun = .{
        .font = font,
        .font_size = 50.0,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    var run_renderer = try buildRenderer(allocator, run, iterate(&hello_glyphs), prep_cache.asMut(), .disabled);
    try run_renderer.renderDecoration(
        allocator,
        .{ 0.0, 147.871094 },
        0.0,
        -2.0,
        2.0,
        1.5,
        &renderer,
    );

    try testing.expectEqual(@as(usize, 1), renderer.fill_rects.items.len);
    const rect = renderer.fill_rects.items[0];
    try testing.expectEqual(@as(f64, 0.0), rect.x0);
    try testing.expectEqual(@as(f64, 2.0), rect.y0);
    try testing.expectEqual(@as(f64, 147.87109375), rect.x1);
    try testing.expectEqual(@as(f64, 4.0), rect.y1);
}

test "decoration exclusion ranges insert and merge like upstream" {
    const allocator = testing.allocator;
    var ranges: std.ArrayListUnmanaged([2]f64) = .empty;
    defer ranges.deinit(allocator);

    try insertAndMergeRange(&ranges, allocator, 2.0, 3.0);
    try testing.expectEqualDeep([2]f64{ 2.0, 3.0 }, ranges.items[0]);

    // Overlapping insert grows both bounds.
    try insertAndMergeRange(&ranges, allocator, 1.0, 5.0);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqualDeep([2]f64{ 1.0, 5.0 }, ranges.items[0]);

    // Insert before the first range.
    try insertAndMergeRange(&ranges, allocator, 0.5, 1.5);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqualDeep([2]f64{ 0.5, 5.0 }, ranges.items[0]);

    // Non-overlapping insert appends and keeps sorted order.
    try insertAndMergeRange(&ranges, allocator, 6.0, 7.0);
    try testing.expectEqual(@as(usize, 2), ranges.items.len);
    try testing.expectEqualDeep([2]f64{ 6.0, 7.0 }, ranges.items[1]);

    // An insert bridging two ranges merges them into one.
    try insertAndMergeRange(&ranges, allocator, 4.0, 6.5);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqualDeep([2]f64{ 0.5, 7.0 }, ranges.items[0]);

    // An insert touching (but not crossing) the previous range's end merges.
    try insertAndMergeRange(&ranges, allocator, 7.0, 8.5);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqualDeep([2]f64{ 0.5, 8.5 }, ranges.items[0]);
}

test "decoration segment expansion matches upstream skip-ink geometry" {
    var rect = kurbo.Rect.new(std.math.inf(f64), 2.0, -std.math.inf(f64), 4.0);
    const diagonal = kurbo.PathSeg{ .Line = kurbo.Line.new(
        kurbo.Point.new(0.0, 0.0),
        kurbo.Point.new(10.0, 10.0),
    ) };
    expandRectWithSegment(&rect, diagonal, 2.0, 4.0);
    // Crosses the y = 2 and y = 4 lines at x = 2 and x = 4.
    try testing.expectEqual(@as(f64, 2.0), rect.x0);
    try testing.expectEqual(@as(f64, 4.0), rect.x1);
    // The decoration's y bounds are never expanded.
    try testing.expectEqual(@as(f64, 2.0), rect.y0);
    try testing.expectEqual(@as(f64, 4.0), rect.y1);

    // A horizontal segment inside the span only contributes its endpoints
    // (coincident with the probe lines, so the intersections return none).
    const horizontal = kurbo.PathSeg{ .Line = kurbo.Line.new(
        kurbo.Point.new(5.0, 2.0),
        kurbo.Point.new(7.0, 2.0),
    ) };
    expandRectWithSegment(&rect, horizontal, 2.0, 4.0);
    try testing.expectEqual(@as(f64, 2.0), rect.x0);
    try testing.expectEqual(@as(f64, 7.0), rect.x1);

    // Segments entirely above/below the span are ignored.
    const below = kurbo.PathSeg{ .Line = kurbo.Line.new(
        kurbo.Point.new(-100.0, 10.0),
        kurbo.Point.new(100.0, 20.0),
    ) };
    expandRectWithSegment(&rect, below, 2.0, 4.0);
    try testing.expectEqual(@as(f64, 2.0), rect.x0);
    try testing.expectEqual(@as(f64, 7.0), rect.x1);
}

test "hint cache configures, reuses and reconfigures instances" {
    const allocator = testing.allocator;
    const font = FontData.init(try test_fixture.roboto(), 0);
    const parsed = try font.font();
    const outlines = try parsed.outlines();
    const font_id = @intFromPtr(font.blob.ptr);

    var cache = HintCache{};
    defer cache.deinit(allocator);

    const first = try cache.get(allocator, font_id, 0, &outlines, 16.0, &.{});
    try testing.expect(first.isEnabled());
    const second = try cache.get(allocator, font_id, 0, &outlines, 16.0, &.{});
    try testing.expectEqual(first, second);
    const other_size = try cache.get(allocator, font_id, 0, &outlines, 24.0, &.{});
    try testing.expect(other_size != first);
    try testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try testing.expectEqual(@as(f32, 24.0), other_size.size);

    cache.clear(allocator);
    try testing.expectEqual(@as(usize, 0), cache.entries.items.len);
}

test "hinted run preparation configures a hint instance" {
    const allocator = testing.allocator;
    const font = FontData.init(try test_fixture.roboto(), 0);
    const run: GlyphRun = .{
        .font = font,
        .font_size = 16.0,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = true,
    };
    // Without a cache the hinted-scale absorption stays a typed error.
    try testing.expectError(error.Unsupported, prepareGlyphRun(run));

    var cache = HintCache{};
    defer cache.deinit(allocator);
    const prepared = try prepareGlyphRunWithCache(run, &cache, allocator);
    try testing.expect(prepared.hinting_instance != null);
    try testing.expect(prepared.hinting_instance.?.isEnabled());
    try testing.expectEqual(@as(usize, 1), cache.entries.items.len);
}

test "bitmap transform applies outer/inner bearings, scale and origin" {
    const allocator = testing.allocator;
    var pixmap = try pixmap_mod.Pixmap.init(allocator, 4, 2);
    defer pixmap.deinit(allocator);

    const draw_props: DrawProps = .{
        .positioning_transform = kurbo.Affine.IDENTITY,
        .effective_transform = kurbo.Affine.IDENTITY,
        .font_size = 20.0,
    };
    const glyph = Glyph{ .id = 1, .x = 0.0, .y = 0.0 };
    const base: bitmap_mod.BitmapGlyph = .{
        .data = .{ .png = &.{} },
        .bearing_x = 5.0,
        .bearing_y = 25.0,
        .inner_bearing_x = 1.0,
        .inner_bearing_y = 3.0,
        .ppem_x = 10.0,
        .ppem_y = 10.0,
        .advance = null,
        .width = 4,
        .height = 2,
        .placement_origin = .top_left,
    };

    // font_size / ppem = 2 (scale), bearing_x/y in font units of 1/upem=0.02.
    const top_left = calculateBitmapTransform(
        glyph,
        &pixmap,
        draw_props,
        20.0,
        1000.0,
        &base,
        .cbdt,
    );
    // x' = -0.1 + 2*(x - 1); y' = 0.5 + 2*(y - 3).
    try testing.expectEqual(@as(f64, 2.0), top_left.asCoeffs()[0]);
    // Bearing offsets are computed in f32 and widened, so allow 1e-6.
    try testing.expectApproxEqAbs(@as(f64, -2.1), top_left.asCoeffs()[4], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -5.5), top_left.asCoeffs()[5], 1e-6);

    // Bottom-left origins shift down by the pixmap height (2 px * scale 2).
    var bottom_left = base;
    bottom_left.placement_origin = .bottom_left;
    const shifted = calculateBitmapTransform(
        glyph,
        &pixmap,
        draw_props,
        20.0,
        1000.0,
        &bottom_left,
        .cbdt,
    );
    try testing.expectApproxEqAbs(@as(f64, -9.5), shifted.asCoeffs()[5], 1e-6);

    // `sbix` strikes with a zero outer bearing get CoreText's 100-unit offset.
    var sbix = base;
    sbix.bearing_y = 0.0;
    const sbix_transform = calculateBitmapTransform(
        glyph,
        &pixmap,
        draw_props,
        20.0,
        1000.0,
        &sbix,
        .sbix,
    );
    // y' = 2.0 + 2*(y - 3).
    try testing.expectApproxEqAbs(@as(f64, -4.0), sbix_transform.asCoeffs()[5], 1e-6);
    const cbdt_zero = calculateBitmapTransform(
        glyph,
        &pixmap,
        draw_props,
        20.0,
        1000.0,
        &sbix,
        .cbdt,
    );
    try testing.expectApproxEqAbs(@as(f64, -6.0), cbdt_zero.asCoeffs()[5], 1e-6);

    // Glyph positions feed `positionedTransform` in scaled device units.
    const positioned = calculateBitmapTransform(
        .{ .id = 1, .x = 3.0, .y = 0.0 },
        &pixmap,
        draw_props,
        20.0,
        1000.0,
        &base,
        .cbdt,
    );
    try testing.expectApproxEqAbs(@as(f64, 0.9), positioned.asCoeffs()[4], 1e-6);
}
