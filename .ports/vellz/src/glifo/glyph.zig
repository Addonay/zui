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
//! - Hinting (`HintingInstance`), synthetic embolden (`kurbo::expand_path`),
//!   non-empty variation coordinates and bitmap glyphs (CBDT/CBLC/sbix) are
//!   explicit `error.Unsupported`; a run whose transform would require
//!   hinting is rejected up front instead of silently rendering unhinted.
//! - Decoration (`renderDecoration`) is ported: the upstream `Vec` of merged
//!   exclusion spans lives on `GlyphPrepCache` and the Rust iterator/closure
//!   pair becomes one pass over that list.
//! - A font carrying bitmap tables rejects the whole run: upstream resolves
//!   glyphs through a COLR > bitmap > outline cascade, and a glyph without a
//!   COLR entry could fall back to a bitmap that is not ported, so the
//!   representation is never silently dropped. COLR/CPAL is ported (T4).
//! - Upstream's `OutlineCacheSession` is replaced by an explicit
//!   `*OutlineCache` threaded through the draw loop and `renderer.fillGlyph`/
//!   `strokeGlyph`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");

const paint_mod = @import("../common/paint.zig");
const sfnt = @import("tables/sfnt.zig");
const cpal_mod = @import("tables/cpal.zig");
const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
const colr = @import("colr.zig");
const outline_cache = @import("outline_cache.zig");
const atlas = @import("atlas/root.zig");
const renderer_mod = @import("renderer.zig");
const interface = @import("interface.zig");

pub const NormalizedCoord = font_mod.NormalizedCoord;
pub const FontEmbolden = outline_cache.FontEmbolden;
pub const FontInfo = outline_cache.FontInfo;
pub const FontData = font_mod.FontData;

/// Errors from glyph run preparation and drawing.
pub const Error = font_mod.Error || glyf.DrawError || error{
    /// A feature that is scoped but not ported yet: hinting, embolden,
    /// variation coordinates, and bitmap glyphs.
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
        /// Hinting is not ported yet: a run whose transform is eligible for
        /// vertical hinting fails with `error.Unsupported` when drawn. Runs
        /// that upstream would render `Direct` (no hinting applied) proceed.
        pub fn hint(self: Self, enabled: bool) Self {
            var result = self;
            result.run.hint = enabled;
            return result;
        }

        /// Set normalized variation coordinates for variable fonts.
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

/// Caches used for preparing glyph drawing.
pub const GlyphPrepCache = struct {
    /// Caches glyph outlines.
    outline_cache: outline_cache.OutlineCache = .{},
    /// Horizontal spans excluded from "ink-skipping" underlines. Cached to
    /// reuse one allocation.
    underline_exclusions: std.ArrayListUnmanaged([2]f64) = .empty,

    /// Borrow this cache bundle mutable for glyph run construction.
    pub fn asMut(self: *GlyphPrepCache) GlyphPrepCacheMut {
        return .{
            .outline_cache = &self.outline_cache,
            .underline_exclusions = &self.underline_exclusions,
        };
    }

    /// Clear the glyph preparation caches.
    pub fn clear(self: *GlyphPrepCache, allocator: std.mem.Allocator) void {
        self.outline_cache.clear(allocator);
        self.underline_exclusions.clearRetainingCapacity();
    }

    /// Maintain the glyph preparation caches.
    pub fn maintain(self: *GlyphPrepCache, allocator: std.mem.Allocator) void {
        self.outline_cache.maintain(allocator);
    }

    /// Release the cache storage.
    pub fn deinit(self: *GlyphPrepCache, allocator: std.mem.Allocator) void {
        self.outline_cache.deinit(allocator);
        self.underline_exclusions.deinit(allocator);
        self.* = .{};
    }
};

/// Mutably borrowed caches used for preparing glyph drawing.
pub const GlyphPrepCacheMut = struct {
    /// Caches glyph outlines.
    outline_cache: *outline_cache.OutlineCache,
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
    outlines: *const glyf.Outlines,
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

/// A type of glyph.
pub const GlyphType = union(enum) {
    /// An outline glyph.
    outline: GlyphOutline,
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
    outlines: glyf.Outlines,
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
    /// Variation coordinates (always empty until `gvar` lands).
    normalized_coords: []const NormalizedCoord,
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
/// Fails with `error.Unsupported` for deferred inputs: hinting, non-empty
/// variation coordinates, synthetic embolden, and fonts whose glyphs would
/// come from COLR/CPAL or bitmap tables.
pub fn prepareGlyphRun(run: GlyphRun) Error!PreparedGlyphRun {
    if (run.normalized_coords.len != 0) return error.Unsupported;
    if (!run.font_embolden.isDefault()) return error.Unsupported;

    const full_transform = run.transform.compose(run.glyph_transform orelse kurbo.Affine.IDENTITY);
    const c = full_transform.asCoeffs();
    // `t_c` (the skew coefficient) is only needed for the hinted effective
    // transform, which errors with `error.Unsupported` below.
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

    // `AbsorbScaleHinted` requires a `HintingInstance`; deferred.
    if (mode == .absorb_scale_hinted) return error.Unsupported;

    const effective_transform: kurbo.Affine = switch (mode) {
        // The scale is absorbed into the font size; remove it from the skew
        // coefficient as well so it is not applied twice.
        .absorb_scale_unhinted => kurbo.Affine.new(.{ 1.0, 0.0, 0.0, 1.0, t_e, t_f }),
        .direct => full_transform,
        .absorb_scale_hinted => unreachable,
    };

    const draw_font_size: f32 = switch (mode) {
        .absorb_scale_unhinted => run.font_size * @as(f32, @floatCast(t_d)),
        .direct => run.font_size,
        .absorb_scale_hinted => unreachable,
    };

    const font = try run.font.font();
    const upem: f32 = @floatFromInt(font.unitsPerEm());

    const face = font.face;
    if (face.table(sfnt.tag_cbdt) != null or
        face.table(sfnt.tag_cblc) != null or
        face.table(sfnt.tag_sbix) != null)
    {
        // Bitmap glyphs are deferred. Upstream runs a COLR > bitmap > outline
        // cascade per glyph; a glyph without a COLR entry on such a font would
        // fall back to the bitmap, so reject the run explicitly rather than
        // silently dropping the representation.
        return error.Unsupported;
    }

    const outlines = try font.outlines();
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
/// space to layout space Y flip. Upstream rounds the Y translation for hinted
/// runs; hinted runs are `error.Unsupported` here, so no rounding occurs.
pub fn calculateOutlineTransform(glyph: Glyph, draw_props: DrawProps) kurbo.Affine {
    return draw_props
        .positionedTransform(glyph)
        .preScaleNonUniform(1.0, -1.0);
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
            const hinted = false; // supported runs never carry a HintingInstance

            // Upstream derives the scale from the prepared run's hint state.
            // Hinted runs are rejected in `prepareGlyphRun`, so the cache
            // size is always the unhinted fill size.
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
                const raw_glyph = prepared.outlines.getGlyph(glyph.id) catch |err| switch (err) {
                    error.OutOfBounds => continue,
                    else => return err,
                };
                _ = raw_glyph;

                const cached = try self.outline_cache.getOrInsert(
                    allocator,
                    &prepared.outlines,
                    glyph.id,
                    prepared.font_info,
                    scale_props.cache_size,
                    prepared.font_embolden,
                    prepared.normalized_coords,
                    hinted,
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
            const hinted = false; // `hinting_instance.is_some()` upstream

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
                const outline_transform = calculateOutlineTransform(glyph, prepared.draw_props);
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

                // ── Outline glyphs ────────────────────────────────────────
                // The speculative check above already computed the transform
                // and key; reuse them here.
                const raw_glyph = prepared.outlines.getGlyph(glyph.id) catch |err| switch (err) {
                    // Upstream `outlines.get()` returns `None` for
                    // out-of-range glyph ids and skips them.
                    error.OutOfBounds => continue,
                    else => return err,
                };
                _ = raw_glyph;

                const cached_outline = try self.outline_cache.getOrInsert(
                    allocator,
                    &prepared.outlines,
                    glyph.id,
                    prepared.font_info,
                    scale_props.cache_size,
                    prepared.font_embolden,
                    prepared.normalized_coords,
                    hinted,
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
    run: GlyphRun,
    glyphs: anytype,
    prep_cache: GlyphPrepCacheMut,
    atlas_cacher: AtlasCacher,
) Error!GlyphRunRenderer(@TypeOf(glyphs)) {
    const prepared_run = try prepareGlyphRun(run);
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

    pub fn atlasImageSource(self: *const RecordingRenderer, page_index: u32) paint_mod.ImageSource {
        _ = self;
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
    var run_renderer = try buildRenderer(run, iterator, prep_cache.asMut(), cacher);
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

test "non-empty variation coordinates and embolden are rejected" {
    const font = try testFontData();
    const base: GlyphRun = .{
        .font = font,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    var with_coords = base;
    with_coords.normalized_coords = &.{0};
    try testing.expectError(error.Unsupported, prepareGlyphRun(with_coords));

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

test "prepare still rejects fonts with deferred bitmap tables" {
    const noto_cbtf = FontData.init(try test_fixture.notoCbtf(), 0);
    const run: GlyphRun = .{
        .font = noto_cbtf,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    try testing.expectError(error.Unsupported, prepareGlyphRun(run));
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
    var run_renderer = try buildRenderer(run, iterate(&hello_glyphs), prep_cache.asMut(), .disabled);
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
