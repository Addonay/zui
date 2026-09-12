//! Shared glyph rendering logic for rendering backends.
//!
//! Port of `glifo/src/renderer.rs` (outline subset). Fills and strokes
//! prepared glyphs, using the glyph atlas when possible and falling back to
//! direct rendering otherwise, and replays recorded atlas commands into a
//! `DrawSink`.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - Backends are comptime duck typed (`renderer: anytype`); `interface.zig`
//!   compiles the documented method set.
//! - Allocating draw calls take the allocator and return `!void`.
//! - Bitmap and COLR atlas paths are deferred (typed `error.Unsupported` in
//!   `glyph.zig`/`fillGlyph`), so `CachedGlyphType` currently has only the
//!   outline variant.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const paint_mod = @import("../common/paint.zig");
const util = @import("util.zig");
const glyph = @import("glyph.zig");
const atlas = @import("atlas/root.zig");
const interface = @import("interface.zig");

const Affine = kurbo.Affine;
const BezPath = kurbo.BezPath;
const Rect = kurbo.Rect;
const AtlasSlot = atlas.AtlasSlot;
const GlyphAtlas = atlas.GlyphAtlas;
const ImageCache = atlas.ImageCache;
const GlyphCacheKey = atlas.GlyphCacheKey;
const RasterMetrics = atlas.RasterMetrics;
const AtlasCacher = glyph.AtlasCacher;
const GlyphOutline = glyph.GlyphOutline;
const PreparedGlyph = glyph.PreparedGlyph;

/// Outcome of a cache-first render attempt.
const CacheResult = enum {
    /// Glyph was rasterised, stored in the atlas, and drawn.
    cached_and_rendered,
    /// Transform contains rotation or skew — cannot be cached at a single
    /// raster resolution; the caller must render directly.
    unsupported_transform,
    /// Atlas allocator could not fit the glyph.
    atlas_full,
};

/// The context color extracted from a renderer's current paint (BLACK for
/// non-solid paints, matching upstream `get_context_color`).
pub fn contextColor(paint: *const paint_mod.PaintType) peniko.Color {
    return switch (paint.*) {
        .solid => |color| color,
        else => peniko.Color.BLACK,
    };
}

/// Fill a prepared glyph, using the glyph atlas when possible and falling back
/// to direct rendering otherwise.
pub fn fillGlyph(
    allocator: std.mem.Allocator,
    renderer: anytype,
    prepared: *const PreparedGlyph,
    atlas_cacher: *AtlasCacher,
) !void {
    interface.assertGlyphRenderer(@TypeOf(renderer.*));

    switch (atlas_cacher.*) {
        .disabled => {
            try fillUncachedOutline(allocator, renderer, prepared);
        },
        .enabled => |*e| {
            if (prepared.cache_key) |key| {
                const tint_color = contextColor(renderer.currentPaint());
                if (try insertAndRenderOutline(
                    allocator,
                    renderer,
                    &prepared.outline,
                    prepared.outline_transform,
                    key,
                    e.glyph_atlas,
                    e.image_cache,
                    tint_color,
                ) == .cached_and_rendered) {
                    return;
                }
            }
            try fillUncachedOutline(allocator, renderer, prepared);
        },
    }
}

/// Stroke a prepared glyph, using the glyph atlas when possible and falling
/// back to direct rendering otherwise. Stroked outlines are never cached
/// (upstream: cache keys do not carry stroke parameters).
pub fn strokeGlyph(
    allocator: std.mem.Allocator,
    renderer: anytype,
    prepared: *const PreparedGlyph,
    atlas_cacher: *AtlasCacher,
) !void {
    interface.assertGlyphRenderer(@TypeOf(renderer.*));

    switch (atlas_cacher.*) {
        .disabled => {
            try strokeUncachedOutline(allocator, renderer, prepared);
        },
        .enabled => |*e| {
            if (prepared.cache_key) |key| {
                const tint_color = contextColor(renderer.currentPaint());
                if (try insertAndRenderOutline(
                    allocator,
                    renderer,
                    &prepared.outline,
                    prepared.outline_transform,
                    key,
                    e.glyph_atlas,
                    e.image_cache,
                    tint_color,
                ) == .cached_and_rendered) {
                    return;
                }
            }
            try strokeUncachedOutline(allocator, renderer, prepared);
        },
    }
}

fn fillUncachedOutline(
    allocator: std.mem.Allocator,
    renderer: anytype,
    prepared: *const PreparedGlyph,
) !void {
    const state = try renderer.saveState();
    defer renderer.restoreState(state);
    renderer.setTransform(prepared.outline_transform.preScale(prepared.outline.scale));
    renderer.setPaintTransform(prepared.relative_paint_transform);
    try renderer.fillPath(allocator, prepared.outline.path.elementsSlice());
}

fn strokeUncachedOutline(
    allocator: std.mem.Allocator,
    renderer: anytype,
    prepared: *const PreparedGlyph,
) !void {
    const state = try renderer.saveState();
    defer renderer.restoreState(state);
    renderer.setTransform(prepared.outline_transform.preScale(prepared.outline.scale));
    renderer.setPaintTransform(prepared.relative_paint_transform);
    try renderer.strokePath(allocator, prepared.outline.path.elementsSlice());
}

/// Type hint for cached glyph rendering.
pub const CachedGlyphType = enum {
    /// An outline glyph cached in the atlas.
    outline,
};

/// Render a cached glyph from the atlas.
pub fn renderCachedGlyph(
    allocator: std.mem.Allocator,
    renderer: anytype,
    cached_slot: AtlasSlot,
    transform: Affine,
    glyph_type: CachedGlyphType,
) !void {
    switch (glyph_type) {
        .outline => {
            const tint = contextColor(renderer.currentPaint());
            try renderOutlineGlyphFromAtlas(allocator, renderer, cached_slot, transform, tint);
        },
    }
}

/// Render from the atlas, constructing the appropriate image from the slot.
fn renderFromAtlas(
    allocator: std.mem.Allocator,
    renderer: anytype,
    atlas_slot: AtlasSlot,
    rect_transform: Affine,
    area: Rect,
    quality: peniko.ImageQuality,
    tint: ?paint_mod.Tint,
) !void {
    const paint_transform = renderer.atlasPaintTransform(atlas_slot.x, atlas_slot.y);
    const image_source = renderer.atlasImageSource(atlas_slot.page_index);
    const image = paint_mod.Image{
        .image = image_source,
        .sampler = .{
            .x_extend = .pad,
            .y_extend = .pad,
            .quality = quality,
            .alpha = 1.0,
        },
    };

    const state = try renderer.saveState();
    defer renderer.restoreState(state);
    renderer.setTint(tint);
    renderer.setTransform(rect_transform);
    renderer.setPaint(paint_mod.PaintType.fromImage(image));
    renderer.setPaintTransform(paint_transform);
    try renderer.fillRect(allocator, area);
    renderer.setTint(null);
}

/// Record outline glyph draw commands into the atlas command recorder.
fn renderOutlineToAtlas(
    allocator: std.mem.Allocator,
    path: *const BezPath,
    scale: f64,
    subpixel_offset: f32,
    recorder: *atlas.AtlasCommandRecorder,
    atlas_slot: AtlasSlot,
    raster_metrics: RasterMetrics,
) !void {
    const outline_transform = Affine
        .scaleNonUniform(scale, -scale)
        .thenTranslate(kurbo.Vec2.new(
            @as(f64, @floatFromInt(atlas_slot.x)) -
                @as(f64, @floatFromInt(raster_metrics.bearing_x)) +
                @as(f64, subpixel_offset),
            @as(f64, @floatFromInt(atlas_slot.y)) -
                @as(f64, @floatFromInt(raster_metrics.bearing_y)),
        ));
    try recorder.setTransform(allocator, outline_transform);
    try recorder.setPaint(allocator, .{ .solid = peniko.Color.BLACK });
    try recorder.fillPath(allocator, path);
}

/// Insert an outline glyph into the atlas and render it from there.
fn insertAndRenderOutline(
    allocator: std.mem.Allocator,
    renderer: anytype,
    outline: *const GlyphOutline,
    outline_transform: Affine,
    cache_key: GlyphCacheKey,
    glyph_atlas: *GlyphAtlas,
    image_cache: *ImageCache,
    tint_color: peniko.Color,
) !CacheResult {
    if (!supportsAtlasCaching(&outline_transform, .outline)) {
        return .unsupported_transform;
    }

    const bounds = scaleFromOrigin(outline.bbox, outline.scale);
    const raster_metrics = calculateRasterMetrics(&bounds);
    const subpixel = atlas.subpixelOffset(cache_key.subpixel_x);

    const insert_result = (try glyph_atlas.insert(allocator, image_cache, cache_key, raster_metrics)) orelse
        return .atlas_full;

    try renderOutlineToAtlas(
        allocator,
        outline.path,
        outline.scale,
        subpixel,
        insert_result.recorder,
        insert_result.slot,
        raster_metrics,
    );

    try renderOutlineGlyphFromAtlas(allocator, renderer, insert_result.slot, outline_transform, tint_color);
    return .cached_and_rendered;
}

/// Render an outline glyph from the atlas using bearing-based positioning.
fn renderOutlineGlyphFromAtlas(
    allocator: std.mem.Allocator,
    renderer: anytype,
    atlas_slot: AtlasSlot,
    outline_transform: Affine,
    tint_color: peniko.Color,
) !void {
    const c = outline_transform.asCoeffs();
    const rect_transform = Affine.translate(kurbo.Vec2.new(
        @floor(c[4]) + @as(f64, @floatFromInt(atlas_slot.bearing_x)),
        @floor(c[5]) + @as(f64, @floatFromInt(atlas_slot.bearing_y)),
    ));
    const area = Rect.new(
        0.0,
        0.0,
        @as(f64, @floatFromInt(atlas_slot.width)),
        @as(f64, @floatFromInt(atlas_slot.height)),
    );
    try renderFromAtlas(
        allocator,
        renderer,
        atlas_slot,
        rect_transform,
        area,
        .low,
        .{ .color = tint_color, .mode = .alpha_mask },
    );
}

/// Scale a rectangle's coordinates by `scale` (upstream
/// `Rect::scale_from_origin`).
fn scaleFromOrigin(rect: Rect, scale: f64) Rect {
    return Rect.new(rect.x0 * scale, rect.y0 * scale, rect.x1 * scale, rect.y1 * scale);
}

/// Calculate raster metrics (pixel bounds, bearings) from a glyph bounding
/// box. Mirrors upstream's floor/ceil rounding; the width gets an extra pixel
/// for the horizontal subpixel offset.
pub fn calculateRasterMetrics(bounds: *const Rect) RasterMetrics {
    const min_x = satI32(@floor(bounds.x0));
    const max_x = satI32(@ceil(bounds.x1) + 1.0);
    // Y is flipped: font Y up -> screen Y down.
    const flipped_min_y = satI32(@floor(-bounds.y1));
    const flipped_max_y = satI32(@ceil(-bounds.y0));

    const width = satU16(@as(f64, @floatFromInt(max_x - min_x)));
    const height = satU16(@as(f64, @floatFromInt(flipped_max_y - flipped_min_y)));

    return .{
        .width = width,
        .height = height,
        .bearing_x = satI16(@floatFromInt(min_x)),
        .bearing_y = satI16(@floatFromInt(flipped_min_y)),
    };
}

/// Choose image sampling quality based on downscale factor.
pub fn qualityForScale(transform: Affine) peniko.ImageQuality {
    const c = transform.asCoeffs();
    if (c[0] < 0.5 or c[3] < 0.5) return .high;
    return .medium;
}

/// Choose image sampling quality based on skew presence.
pub fn qualityForSkew(transform: Affine) peniko.ImageQuality {
    if (util.hasSkew(transform)) return .medium;
    return .low;
}

/// Replay recorded atlas commands into a `DrawSink`.
pub fn replayAtlasCommands(
    allocator: std.mem.Allocator,
    recorder: *atlas.AtlasCommandRecorder,
    target: anytype,
) !void {
    interface.assertDrawSink(@TypeOf(target.*));
    for (recorder.commands.items) |*command| {
        switch (command.*) {
            .set_transform => |t| target.setTransform(t),
            .set_paint => |paint| {
                const resolved = try paint.toPaintType(allocator);
                target.setPaint(resolved);
            },
            .set_paint_transform => |t| target.setPaintTransform(t),
            .fill_path => |path| try target.fillPath(allocator, path.elementsSlice()),
            .fill_rect => |rect| try target.fillRect(allocator, rect),
            .push_clip_layer => |clip| try target.pushClipLayer(allocator, clip.elementsSlice()),
            .push_clip_path => |clip| try target.pushClipPath(allocator, clip.elementsSlice()),
            .push_blend_layer => |blend| try target.pushBlendLayer(blend),
            .pop_layer => target.popLayer(),
            .pop_clip_path => target.popClipPath(),
        }
    }
}

/// Returns `true` if the transform is safe for atlas-cached glyph rendering.
pub fn supportsAtlasCaching(transform: *const Affine, glyph_type: CachedGlyphType) bool {
    _ = glyph_type;
    // Upstream supports y-mirroring for outlines (the flip is expected) but
    // not x-mirroring.
    const c = transform.asCoeffs();
    return !util.hasNonUnitSkewOrScale(transform.*) and
        isSignPositive(c[0]) and
        !isSignPositive(c[3]);
}

fn isSignPositive(value: f64) bool {
    return (@as(u64, @bitCast(value)) >> 63) == 0;
}

/// Rust `as i32` semantics: saturating, NaN becomes 0.
fn satI32(value: f64) i32 {
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(std.math.clamp(value, -2147483648.0, 2147483647.0));
}

/// Rust `as i16` semantics: saturating, NaN becomes 0.
fn satI16(value: f64) i16 {
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(std.math.clamp(value, -32768.0, 32767.0));
}

/// Rust `as u16` semantics: saturating, NaN becomes 0.
fn satU16(value: f64) u16 {
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(std.math.clamp(value, 0.0, 65535.0));
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "raster metrics floor/ceil with y flip" {
    const bounds = Rect.new(1.25, -3.5, 10.5, 0.25);
    const metrics = calculateRasterMetrics(&bounds);
    // min_x = 1, max_x = 11 + 1 = 12 -> width 11
    try testing.expectEqual(@as(u16, 11), metrics.width);
    try testing.expectEqual(@as(i16, 1), metrics.bearing_x);
    // flipped_min_y = floor(-0.25) = -1
    // flipped_max_y = ceil(3.5) = 4 -> height 5
    try testing.expectEqual(@as(u16, 5), metrics.height);
    try testing.expectEqual(@as(i16, -1), metrics.bearing_y);
}

test "atlas caching support mirrors upstream predicates" {
    // Outline transforms always carry the font-space Y flip, so a unit-scale
    // transform with positive Y (e.g. identity) is not cacheable.
    try testing.expect(!supportsAtlasCaching(&Affine.IDENTITY, .outline));
    try testing.expect(supportsAtlasCaching(
        &Affine.scaleNonUniform(1.0, -1.0),
        .outline,
    ));
    try testing.expect(!supportsAtlasCaching(&Affine.scale(2.0), .outline));
    try testing.expect(!supportsAtlasCaching(
        &Affine.skew(0.2, 0.0),
        .outline,
    ));
    try testing.expect(!supportsAtlasCaching(
        &Affine.scaleNonUniform(-1.0, -1.0),
        .outline,
    ));
    try testing.expect(!supportsAtlasCaching(
        &Affine.scaleNonUniform(1.0, 1.0),
        .outline,
    ));
}

test "quality selection" {
    try testing.expectEqual(peniko.ImageQuality.high, qualityForScale(Affine.scale(0.25)));
    try testing.expectEqual(peniko.ImageQuality.medium, qualityForScale(Affine.scale(2.0)));
    try testing.expectEqual(peniko.ImageQuality.medium, qualityForSkew(Affine.skew(0.1, 0.0)));
    try testing.expectEqual(peniko.ImageQuality.low, qualityForSkew(Affine.IDENTITY));
}
