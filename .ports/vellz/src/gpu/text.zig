//! Port of `vello_gpu/src/text.rs` (Apache-2.0 OR MIT).
//!
//! Vello GPU glyph rendering backend: the `DrawSink`/`GlyphRenderer` surface
//! for the hybrid `Scene` plus the `GlyphRunBackend` that drives `glifo`'s
//! build/draw loop into that scene.
//!
//! Unlike the CPU backend, no local `Pixmap` storage is allocated here — the
//! backend renderer owns the atlas textures and receives pixel data through
//! `glifo`'s pending-upload queue (`Resources` + `backend/renderer.zig`).
//!
//! # Port adaptations (deliberate divergences)
//!
//! - Upstream implements the traits directly on `Scene`. Zig methods cannot
//!   be overloaded, and `glifo`'s duck-typed contract calls
//!   `fillPath(allocator, ..)`/`fillRect(allocator, ..)` while `Scene` exposes
//!   the narrower `fillPath(path)`/`fillRect(*Rect)`; the adapter
//!   `SceneSink` forwards the calls and records underflow errors that the
//!   contract cannot propagate (`popLayer`/`popClipPath` return `void`).
//! - `atlasImageSource` receives `(image_id, page_index)`. The GPU resolves
//!   the `ImageId` in the shared image atlas cache; the CPU resolves the page
//!   index in its `ImageRegistry`. The call site was extended so both backends
//!   get the identity they need (see `glifo/renderer.zig`).
//! - `atlasPaintTransform` ignores the slot coordinates and returns the
//!   `GLYPH_PADDING` translation, exactly like upstream `vello_gpu` (the
//!   image's atlas offset already positions the sample).

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const common = @import("../common/root.zig");
const glifo = @import("../glifo/root.zig");
const resources_mod = @import("resources.zig");
const scene_mod = @import("scene.zig");

const ImageId = common.paint.ImageId;
const ImageSource = common.paint.ImageSource;
const PaintType = common.paint.PaintType;
const RenderState = common.render_state.RenderState;
const Scene = scene_mod.Scene;
const Tint = common.paint.Tint;

/// Shared, pointer-sized error slot for contract methods that return `void`.
pub const SinkState = struct {
    /// First error recorded by a `void`/lossy contract method.
    error_value: ?anyerror = null,

    /// Store the first error, keeping later ones from overwriting it.
    pub fn record(self: *SinkState, err: anyerror) void {
        if (self.error_value == null) self.error_value = err;
    }
};

/// `DrawSink` + `GlyphRenderer` implementation over the hybrid `Scene`.
pub const SceneSink = struct {
    /// Scene receiving the glyph draws.
    scene: *Scene,
    /// Shared error slot (the sink is passed by value through `glifo`).
    state: *SinkState,
    /// Resources providing the image atlas uploader for uncached bitmap
    /// glyphs; null keeps the pixmap source (which fails loudly later).
    resources: ?*resources_mod.Resources = null,

    /// Clone the scene's render state (upstream `save_current_state`).
    pub fn saveState(self: *SceneSink) std.mem.Allocator.Error!RenderState {
        var state = self.scene.render_state;
        state.paint = try state.paint.clone(self.scene.allocator);
        return state;
    }

    /// Restore a previously saved render state, releasing the current paint
    /// (upstream `restore_state`, which also refreshes `paint_visible`).
    pub fn restoreState(self: *SceneSink, state: RenderState) void {
        // `setPaint` releases the old paint and refreshes `paint_visible`.
        self.scene.setPaint(state.paint);
        self.scene.render_state.stroke = state.stroke;
        self.scene.render_state.fill_rule = state.fill_rule;
        self.scene.render_state.blend_mode = state.blend_mode;
        self.scene.render_state.tint = state.tint;
        self.scene.render_state.transforms = state.transforms;
    }

    pub fn setTransform(self: *SceneSink, transform: kurbo.Affine) void {
        self.scene.setTransform(transform);
    }

    pub fn setPaintTransform(self: *SceneSink, transform: kurbo.Affine) void {
        self.scene.setPaintTransform(transform);
    }

    /// Takes ownership of `paint` (gradients/images own heap resources).
    ///
    /// A `Pixmap` image source (the uncached bitmap glyph path) is uploaded
    /// into the image atlas and rewritten to `opaque_id`; upstream
    /// `vello_gpu` panics for pixmap sources, this port resolves them through
    /// the shared atlas instead.
    pub fn setPaint(self: *SceneSink, paint_in: PaintType) void {
        var paint = paint_in;
        switch (paint) {
            .image => |*image| {
                if (image.image == .pixmap) {
                    const resources = self.resources orelse {
                        self.scene.setPaint(paint);
                        return;
                    };
                    const uploader = resources.glyph_uploader orelse {
                        self.scene.setPaint(paint);
                        return;
                    };
                    const sampler = image.sampler;
                    const pixmap = image.image.pixmap.get();
                    const image_id = uploader.upload(pixmap) catch |err| {
                        self.state.record(err);
                        paint.deinit(self.scene.allocator);
                        return;
                    };
                    // Release the pixmap handle owned by the incoming paint.
                    paint.deinit(self.scene.allocator);
                    self.scene.setPaint(PaintType.fromImage(.{
                        .image = ImageSource.initOpaqueId(image_id),
                        .sampler = sampler,
                    }));
                    return;
                }
            },
            else => {},
        }
        self.scene.setPaint(paint);
    }

    pub fn fillPath(
        self: *SceneSink,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        _ = allocator;
        try self.scene.fillPath(path);
    }

    pub fn strokePath(
        self: *SceneSink,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        _ = allocator;
        try self.scene.strokePath(path);
    }

    pub fn fillRect(
        self: *SceneSink,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
    ) !void {
        _ = allocator;
        try self.scene.fillRect(&rect);
    }

    pub fn pushClipLayer(
        self: *SceneSink,
        allocator: std.mem.Allocator,
        clip: []const kurbo.PathEl,
    ) !void {
        _ = allocator;
        try self.scene.pushClipLayer(clip);
    }

    pub fn pushClipPath(
        self: *SceneSink,
        allocator: std.mem.Allocator,
        clip: []const kurbo.PathEl,
    ) !void {
        _ = allocator;
        try self.scene.pushClipPath(clip);
    }

    pub fn pushBlendLayer(self: *SceneSink, blend_mode: peniko.BlendMode) !void {
        try self.scene.pushBlendLayer(blend_mode);
    }

    pub fn popLayer(self: *SceneSink) void {
        self.scene.popLayer() catch |err| self.state.record(err);
    }

    pub fn popClipPath(self: *SceneSink) void {
        self.scene.popClipPath() catch |err| self.state.record(err);
    }

    pub fn setTint(self: *SceneSink, tint: ?Tint) void {
        self.scene.setTint(tint);
    }

    pub fn currentPaint(self: *const SceneSink) *const PaintType {
        return &self.scene.render_state.paint;
    }

    /// Resolve an atlas glyph allocation to its image-atlas id (upstream
    /// `atlas_image_source`). The CPU backend uses `page_index` instead; both
    /// are passed so neither backend has to reverse-engineer the other's id.
    pub fn atlasImageSource(self: *const SceneSink, image_id: u32, page_index: u32) ImageSource {
        _ = self;
        _ = page_index;
        return ImageSource.initOpaqueId(ImageId.new(image_id));
    }

    /// The cached-glyph sample offset: the image's atlas offset already
    /// positions the sample, so only the transparent padding is translated
    /// (upstream `vello_gpu::text::atlas_paint_transform`).
    pub fn atlasPaintTransform(self: *const SceneSink, x: u16, y: u16) kurbo.Affine {
        _ = self;
        _ = x;
        _ = y;
        return kurbo.Affine.translate(kurbo.Vec2.new(
            -@as(f64, @floatFromInt(glifo.GLYPH_PADDING)),
            -@as(f64, @floatFromInt(glifo.GLYPH_PADDING)),
        ));
    }

    pub fn width(self: *const SceneSink) u16 {
        return self.scene.sceneWidth();
    }

    pub fn height(self: *const SceneSink) u16 {
        return self.scene.sceneHeight();
    }
};

/// A GPU glyph run backend (upstream `HybridGlyphRunBackend`).
pub const HybridGlyphRunBackend = struct {
    /// Scene receiving the glyph draws.
    scene: *Scene,
    /// Persistent resources owning the glyph caches and atlas.
    resources: *resources_mod.Resources,
    /// Whether atlas-backed glyph caching is enabled for this run.
    atlas_cache_enabled: bool = false,

    /// The `glifo.GlyphRunBuilder` specialization for this backend (upstream
    /// `pub type GlyphRunBuilder<'a>`).
    pub const GlyphRunBuilder = glifo.GlyphRunBuilder(HybridGlyphRunBackend);

    /// Enable or disable atlas-backed glyph caching for the glyph run.
    pub fn atlasCache(self: HybridGlyphRunBackend, enabled: bool) HybridGlyphRunBackend {
        var result = self;
        result.atlas_cache_enabled = enabled;
        return result;
    }

    fn renderGlyphs(
        self: HybridGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
        style: glifo.glyph.Style,
    ) !void {
        var cacher: glifo.AtlasCacher = .disabled;
        if (self.atlas_cache_enabled) {
            try self.resources.ensureGlyphResources();
            const glyph_resources = &self.resources.glyph_resources.?;
            cacher = .{ .enabled = .{
                .glyph_atlas = &glyph_resources.glyph_atlas,
                .image_cache = &self.resources.image_cache,
            } };
        }

        var run_renderer = try glifo.buildRenderer(
            allocator,
            run,
            glyphs,
            self.resources.glyph_prep_cache.asMut(),
            cacher,
        );

        var sink_state = SinkState{};
        var sink = SceneSink{
            .scene = self.scene,
            .state = &sink_state,
            .resources = self.resources,
        };

        switch (style) {
            .fill => try run_renderer.fillGlyphs(allocator, &sink),
            .stroke => {
                const adjustment = run_renderer.strokeAdjustment();
                const original_width = self.scene.render_state.stroke.width;
                self.scene.render_state.stroke.width *= adjustment;
                defer self.scene.render_state.stroke.width = original_width;
                try run_renderer.strokeGlyphs(allocator, &sink);
            },
        }

        if (sink_state.error_value) |err| return err;
    }

    /// Fill the glyph sequence using the backend's configured state.
    pub fn fillGlyphs(
        self: HybridGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !void {
        try self.renderGlyphs(allocator, run, glyphs, .fill);
    }

    /// Stroke the glyph sequence using the backend's configured state.
    pub fn strokeGlyphs(
        self: HybridGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !void {
        try self.renderGlyphs(allocator, run, glyphs, .stroke);
    }

    /// Render a decoration (underline/overline/strikethrough) with skip-ink
    /// behavior into the scene, using the backend's run settings.
    pub fn renderDecoration(
        self: HybridGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
        x_range: [2]f32,
        baseline_y: f32,
        offset: f32,
        size: f32,
        buffer: f32,
    ) !void {
        var cacher: glifo.AtlasCacher = .disabled;
        if (self.atlas_cache_enabled) {
            try self.resources.ensureGlyphResources();
            const glyph_resources = &self.resources.glyph_resources.?;
            cacher = .{ .enabled = .{
                .glyph_atlas = &glyph_resources.glyph_atlas,
                .image_cache = &self.resources.image_cache,
            } };
        }

        var run_renderer = try glifo.buildRenderer(
            allocator,
            run,
            glyphs,
            self.resources.glyph_prep_cache.asMut(),
            cacher,
        );

        var sink_state = SinkState{};
        var sink = SceneSink{
            .scene = self.scene,
            .state = &sink_state,
            .resources = self.resources,
        };
        try run_renderer.renderDecoration(
            allocator,
            x_range,
            baseline_y,
            offset,
            size,
            buffer,
            &sink,
        );
        if (sink_state.error_value) |err| return err;
    }
};

/// Creates a builder for drawing a run of glyphs that share attributes
/// (upstream `Scene::glyph_run`; kept here to avoid a module import cycle
/// between `scene.zig` and `text.zig`).
pub fn glyphRun(
    scene: *Scene,
    resources: *resources_mod.Resources,
    font: glifo.FontData,
) HybridGlyphRunBackend.GlyphRunBuilder {
    return HybridGlyphRunBackend.GlyphRunBuilder.new(
        font,
        scene.render_state.transforms.getTransform(),
        scene.render_state.transforms.paintTransform(),
        .{
            .scene = scene,
            .resources = resources,
        },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "scene sink clones and restores render state" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 32, 32);
    defer scene.deinit();

    const red = common.paint.PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(255, 0, 0));
    scene.setPaint(red);
    scene.setTransform(kurbo.Affine.translate(kurbo.Vec2.new(3, 4)));

    var sink_state = SinkState{};
    var sink = SceneSink{ .scene = &scene, .state = &sink_state };

    const saved = try sink.saveState();
    sink.setTransform(kurbo.Affine.IDENTITY);
    sink.setPaint(common.paint.PaintType.fromAlphaColor(peniko.color.Color.BLACK));
    sink.restoreState(saved);

    try testing.expectEqual(red, scene.currentPaint());
    try testing.expectEqual(kurbo.Affine.translate(kurbo.Vec2.new(3, 4)), scene.render_state.transforms.getTransform());
}

test "scene sink records layer underflow instead of dropping it" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 8, 8);
    defer scene.deinit();

    var sink_state = SinkState{};
    var sink = SceneSink{ .scene = &scene, .state = &sink_state };
    sink.popLayer();
    try testing.expectEqual(scene_mod.Error.NoActiveLayer, sink_state.error_value.?);
}

test "atlas paint transform only applies glyph padding" {
    var sink_state = SinkState{};
    var scene = try Scene.init(testing.allocator, 8, 8);
    defer scene.deinit();
    const sink = SceneSink{ .scene = &scene, .state = &sink_state };

    const transform = sink.atlasPaintTransform(17, 23);
    const expected = kurbo.Affine.translate(kurbo.Vec2.new(
        -@as(f64, @floatFromInt(glifo.GLYPH_PADDING)),
        -@as(f64, @floatFromInt(glifo.GLYPH_PADDING)),
    ));
    try testing.expectEqual(expected, transform);
    try testing.expect(sink.atlasImageSource(7, 2).opaque_id.id.asU32() == 7);
}
