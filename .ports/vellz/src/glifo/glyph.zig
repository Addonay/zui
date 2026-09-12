//! Processing and drawing glyphs.
//!
//! Port of `glifo/src/glyph.rs` (outline subset). This module owns run
//! preparation (`GlyphRunBuilder`/`prepareGlyphRun`), the outline draw loop,
//! and the `GlyphPrepCache` bundle. The per-glyph rasterization and atlas
//! insertion logic lives in `renderer.zig`.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - Trait objects become comptime duck typing; `renderer.zig`'s functions
//!   take `renderer: anytype` and `interface.zig` documents/validates the
//!   method set. Allocating sink methods take the allocator and return
//!   `!void` (upstream aborts on allocation failure).
//! - Iterators are plain values with a `next() ?Glyph` method and are not
//!   required to be cloneable: the decoration path that needed cloning is
//!   deferred.
//! - Hinting (`HintingInstance`), synthetic embolden (`kurbo::expand_path`),
//!   non-empty variation coordinates, COLR/CPAL and bitmap glyphs are
//!   explicit `error.Unsupported`; a run whose transform would require
//!   hinting is rejected up front instead of silently rendering unhinted.
//! - Upstream decides between COLR, bitmap and outline per glyph; this port
//!   rejects fonts carrying COLR/CBDT/CBLC/sbix tables at run preparation
//!   (typed error, never a silently dropped glyph).

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");

const paint_mod = @import("../common/paint.zig");
const sfnt = @import("tables/sfnt.zig");
const font_mod = @import("font.zig");
const glyf = @import("glyf.zig");
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
    /// variation coordinates, COLR/CPAL, bitmap glyphs, decoration.
    Unsupported,
    /// The glyph iterator yielded without a glyph (internal).
    EmptyGlyphRun,
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

        /// Render a decoration (underline/strikethrough) with skip-ink
        /// behavior. Deferred with a typed error until T5.
        pub fn renderDecoration(self: Self, allocator: std.mem.Allocator, glyphs: anytype) !void {
            _ = self;
            _ = allocator;
            _ = glyphs;
            return error.Unsupported;
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

/// A glyph prepared for rendering.
pub const PreparedGlyph = struct {
    /// The glyph outline.
    outline: GlyphOutline,
    /// Per-glyph outline transform: maps the draw-unit glyph outline (after
    /// font-size absorption) to scene coordinates.
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
    if (face.table(sfnt.tag_colr) != null or
        face.table(sfnt.tag_cbdt) != null or
        face.table(sfnt.tag_cblc) != null or
        face.table(sfnt.tag_sbix) != null)
    {
        // The per-glyph priority cascade (COLR > bitmap > outline) is part of
        // T4/bitmap support; reject the run explicitly rather than silently
        // dropping the color/bitmap representation.
        return error.Unsupported;
    }

    const outlines = try font.outlines();

    return .{
        .font = run.font,
        .font_info = .{
            .id = @intFromPtr(run.font.blob.ptr),
            .index = run.font.index,
            .upem = upem,
        },
        .outlines = outlines,
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

/// Renderer state for one prepared run.
///
/// `Glyphs` is any type with `pub fn next(self: *Glyphs) ?Glyph` (see
/// `GlyphSliceIterator`).
pub fn GlyphRunRenderer(comptime Glyphs: type) type {
    return struct {
        const Self = @This();

        prepared_run: PreparedGlyphRun,
        outline_cache: *outline_cache.OutlineCache,
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

        /// Render a decoration with skip-ink behavior. Deferred until T5.
        pub fn renderDecoration(self: *Self, allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            return error.Unsupported;
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
                // NOTE: the upstream speculative outline cache check probes
                // before COLR/bitmap lookups; this port has no COLR/bitmap
                // path yet, so the transform and key are computed once.
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

                // Outline glyph (COLR/bitmap are rejected in
                // `prepareGlyphRun`).
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
                    .outline = .{
                        .path = cached_outline.path,
                        .bbox = cached_outline.bbox,
                        .scale = scale_props.draw_scale,
                    },
                    .outline_transform = outline_transform,
                    .relative_paint_transform = relative_paint_transform,
                    .cache_key = outline_cache_key,
                };

                switch (style) {
                    .fill => try renderer_mod.fillGlyph(allocator, renderer, &prepared_glyph, &self.atlas_cacher),
                    .stroke => try renderer_mod.strokeGlyph(allocator, renderer, &prepared_glyph, &self.atlas_cacher),
                }
            }
        }
    };
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

    pub fn saveState(self: *RecordingRenderer) !RenderStateClone {
        return .{
            .transform = self.transform,
            .paint = self.paint,
            .paint_transform = self.paint_transform,
            .tint = self.tint,
        };
    }

    pub fn restoreState(self: *RecordingRenderer, state: RenderStateClone) void {
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
        self.paint = paint;
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
        _ = allocator;
        self.last_fill_rect = rect;
        self.fill_rect_count += 1;
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

test "prepare reveals outline coverage and rejects color fonts" {
    const noto_colr = FontData.init(try test_fixture.notoColor(), 0);
    const run: GlyphRun = .{
        .font = noto_colr,
        .transform = kurbo.Affine.IDENTITY,
        .scene_paint_transform = kurbo.Affine.IDENTITY,
        .hint = false,
    };
    try testing.expectError(error.Unsupported, prepareGlyphRun(run));
}
