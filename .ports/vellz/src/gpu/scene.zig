//! Port of `vello_gpu/src/scene.rs` (root solid-fill subset) (Apache-2.0 OR
//! MIT).
//!
//! `Scene` collects draw commands, generates analytic-AA strips through
//! `vellz.common` (`ViewportState` + `StripGenerator` + `StripStorage`), and
//! records them in a `CommandRecorder` for the GPU draw encoder.
//!
//! Supported by the first strip-pass milestone:
//! - transforms (scene + paint), fill rule, aliasing threshold
//! - solid paints and the rectangle fast path
//! - filled and stroked paths
//! - clip paths (`pushClipPath`/`popClipPath`)
//!
//! Not implemented yet, and rejected with `error.Unsupported` rather than
//! falling back to an approximation: indexed paints (gradients, images) and
//! layers (blend/opacity/filter/mask/clip layers). Both need the encoded-paint
//! and schedule milestones.

const std = @import("std");
const simd = @import("../simd/root.zig");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const common = @import("../common/root.zig");

const Fill = peniko.Fill;
const Paint = common.paint.Paint;
const PaintType = common.paint.PaintType;
const Rect = kurbo.Rect;
const RectU16 = common.geometry.RectU16;
const RenderState = common.render_state.RenderState;
const Strip = common.strip.Strip;
const StripGenerator = common.strip_generator.StripGenerator;
const StripStorage = common.strip_storage.StripStorage;
const Transforms = common.transforms.Transforms;
const ViewportState = common.viewport.ViewportState;

/// Default tolerance for curve flattening.
pub const DEFAULT_TOLERANCE: f64 = 0.1;

/// Errors from `Scene` operations. `Unsupported` covers the features listed in
/// the file header; the remaining names are invalid-usage errors surfaced as
/// typed errors by `vellz.common` (upstream panics).
pub const Error = std.mem.Allocator.Error || error{
    Unsupported,
    RootViewportStackUnderflow,
    ClipStackUnderflow,
    NoActiveLayer,
};

/// Path or rectangle draw retained by the scene recorder.
pub const RecordedDraw = union(enum) {
    /// Path represented by generated strips.
    path: RecordedPath,
    /// Rectangle retained for the direct GPU rectangle path.
    rect: RecordedRect,

    /// The draw bounding box in tile-aligned pixel coordinates.
    pub fn bbox(self: *const RecordedDraw, strips: []const Strip) ?RectU16 {
        return switch (self.*) {
            .path => common.strip.stripBbox(strips),
            .rect => |recorded| blk: {
                const rect = recorded.rect;
                if (rect.isZeroArea()) break :blk null;
                const bounds = RectU16.new(
                    @intFromFloat(@floor(rect.x0)),
                    @intFromFloat(@floor(rect.y0)),
                    @intFromFloat(@ceil(rect.x1)),
                    @intFromFloat(@ceil(rect.y1)),
                );
                break :blk common.util.RectExt.snapToTileCoordinates(bounds);
            },
        };
    }

    /// Recorded draws never carry a directly applied blend mode.
    pub fn blendMode(self: *const RecordedDraw) ?peniko.BlendMode {
        _ = self;
        return null;
    }
};

/// Recorded path strips and their paint.
pub const RecordedPath = struct {
    /// Range selecting the path's strips from scene strip storage.
    strips: common.record.Range(usize),
    /// Paint applied to the path.
    paint: Paint,
};

/// Recorded rectangle and its paint.
pub const RecordedRect = struct {
    /// Rectangle in scene coordinates.
    rect: Rect,
    /// Paint applied to the rectangle.
    paint: Paint,
};

// ---------------------------------------------------------------------------
// Strip generation contexts
//
// Zig has no closures, so `ViewportState.withGeneratorAndClip` takes an
// explicit context value with a `run` function (the same adaptation as the
// common viewport API).
// ---------------------------------------------------------------------------

const PathGenContext = struct {
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    fill_rule: Fill,
    transform: kurbo.Affine,
    aliasing_threshold: ?u8,
    storage: *StripStorage,

    fn run(
        self: *PathGenContext,
        generator: *StripGenerator,
        clip_path: ?common.strip_storage.PathDataRef,
    ) !void {
        try generator.generateFilledPath(
            self.allocator,
            self.path,
            self.fill_rule,
            self.transform,
            self.aliasing_threshold,
            self.storage,
            clip_path,
        );
    }
};

const StrokeGenContext = struct {
    allocator: std.mem.Allocator,
    path: []const kurbo.PathEl,
    stroke: *const kurbo.Stroke,
    transform: kurbo.Affine,
    aliasing_threshold: ?u8,
    storage: *StripStorage,

    fn run(
        self: *StrokeGenContext,
        generator: *StripGenerator,
        clip_path: ?common.strip_storage.PathDataRef,
    ) !void {
        try generator.generateStrokedPath(
            self.allocator,
            self.path,
            self.stroke,
            self.transform,
            self.aliasing_threshold,
            self.storage,
            clip_path,
        );
    }
};

const RectGenContext = struct {
    allocator: std.mem.Allocator,
    rect: Rect,
    storage: *StripStorage,

    fn run(
        self: *RectGenContext,
        generator: *StripGenerator,
        clip_path: ?common.strip_storage.PathDataRef,
    ) !void {
        try generator.generateFilledRectFast(
            self.allocator,
            self.rect,
            self.storage,
            clip_path,
        );
    }
};

/// A render context for hybrid CPU/GPU rendering.
///
/// Matches the upstream `Scene` field set needed for root draws; the
/// `encoded_paints`, `filter`, and layer stacks arrive with their milestones.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    /// Width of the rendering surface in pixels.
    width: u16,
    /// Height of the rendering surface in pixels.
    height: u16,
    /// Viewport-dependent path and clip generation state.
    viewport_state: ViewportState,
    /// Current paint, fill rule, stroke, and transforms.
    render_state: RenderState,
    /// Root transform stack.
    root_transforms: common.transforms.RootTransforms,
    /// Optional aliasing threshold (binarizes coverage at the given value).
    aliasing_threshold: ?u8,
    /// Whether the current paint is visible (e.g. alpha > 0).
    paint_visible: bool,
    /// Storage for generated strips and alpha values.
    strip_storage: StripStorage,
    /// The command recorder.
    recorder: common.record.CommandRecorder(RecordedDraw),

    /// Create a scene at the default (fallback) SIMD level.
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Scene {
        return initWithLevel(allocator, width, height, simd.Level.fallback);
    }

    /// Create a scene with a specific SIMD level.
    pub fn initWithLevel(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        level: simd.Level,
    ) !Scene {
        var scene: Scene = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .viewport_state = ViewportState.init(allocator, width, height, level),
            .render_state = RenderState.default,
            .root_transforms = try common.transforms.RootTransforms.init(allocator),
            .aliasing_threshold = null,
            .paint_visible = true,
            .strip_storage = StripStorage.init(.append),
            .recorder = common.record.CommandRecorder(RecordedDraw).new(width, height),
        };
        scene.setPaintVisible();
        return scene;
    }

    /// Release every owned buffer.
    pub fn deinit(self: *Scene) void {
        self.viewport_state.deinit(self.allocator);
        self.root_transforms.deinit(self.allocator);
        self.strip_storage.deinit(self.allocator);
        self.recorder.deinit(self.allocator);
        self.* = undefined;
    }

    /// Width of the render context.
    pub fn sceneWidth(self: *const Scene) u16 {
        return self.width;
    }

    /// Height of the render context.
    pub fn sceneHeight(self: *const Scene) u16 {
        return self.height;
    }

    fn activeRect(self: *const Scene) Rect {
        return Rect.new(
            0.0,
            0.0,
            @floatFromInt(self.viewport_state.width()),
            @floatFromInt(self.viewport_state.height()),
        );
    }

    fn transforms(self: *const Scene) Transforms {
        return self.render_state.transforms;
    }

    fn effectivePathTransform(self: *const Scene) kurbo.Affine {
        return self.root_transforms.effectivePathTransform(self.transforms());
    }

    fn effectivePaintTransform(self: *const Scene) kurbo.Affine {
        return self.root_transforms.effectivePaintTransform(self.transforms());
    }

    /// Encode the current paint into a drawable `Paint`.
    ///
    /// Solid colors convert directly. Gradients and images need the
    /// encoded-paint milestone, so they return `error.Unsupported`.
    fn encodeCurrentPaint(self: *const Scene) Error!Paint {
        _ = self.effectivePaintTransform();
        return switch (self.render_state.paint) {
            .solid => |color| Paint.fromAlphaColor(color),
            .gradient, .image => error.Unsupported,
        };
    }

    /// Fill a path with the current paint and fill rule.
    pub fn fillPath(self: *Scene, path: []const kurbo.PathEl) Error!void {
        if (!self.paint_visible) return;
        const paint = try self.encodeCurrentPaint();
        try self.fillPathWith(
            path,
            self.effectivePathTransform(),
            self.render_state.fill_rule,
            paint,
        );
    }

    /// Build strips for a filled path with the given properties and record the
    /// draw.
    pub fn fillPathWith(
        self: *Scene,
        path: []const kurbo.PathEl,
        transform: kurbo.Affine,
        fill_rule: Fill,
        paint: Paint,
    ) Error!void {
        if (!self.paint_visible) return;
        var ctx = PathGenContext{
            .allocator = self.allocator,
            .path = path,
            .fill_rule = fill_rule,
            .transform = transform,
            .aliasing_threshold = self.aliasing_threshold,
            .storage = &self.strip_storage,
        };
        try self.recordGeneratedPath(paint, &ctx, PathGenContext.run);
    }

    /// Stroke a path with the current paint and stroke settings.
    pub fn strokePath(self: *Scene, path: []const kurbo.PathEl) Error!void {
        if (!self.paint_visible) return;
        const paint = try self.encodeCurrentPaint();
        var ctx = StrokeGenContext{
            .allocator = self.allocator,
            .path = path,
            .stroke = &self.render_state.stroke,
            .transform = self.effectivePathTransform(),
            .aliasing_threshold = self.aliasing_threshold,
            .storage = &self.strip_storage,
        };
        try self.recordGeneratedPath(paint, &ctx, StrokeGenContext.run);
    }

    /// Fill a rectangle with the current paint and fill rule.
    pub fn fillRect(self: *Scene, rect: *const Rect) Error!void {
        if (!self.paint_visible or rect.isZeroArea()) return;

        const paint = try self.encodeCurrentPaint();

        if (self.fastRectBounds(rect)) |bounds| {
            try self.recorder.pushDraw(
                self.allocator,
                .{ .rect = .{ .rect = bounds, .paint = paint } },
                &.{},
            );
            return;
        }

        const transform = self.effectivePathTransform();
        if (common.util.isAxisAligned(transform) and self.aliasing_threshold == null) {
            var ctx = RectGenContext{
                .allocator = self.allocator,
                .rect = transform.transformRectBbox(rect.*),
                .storage = &self.strip_storage,
            };
            try self.recordGeneratedPath(paint, &ctx, RectGenContext.run);
        } else {
            // TODO: Use a temporary storage for rect paths, like in `vello_cpu`.
            var path = rect.toPath(DEFAULT_TOLERANCE, self.allocator) catch |err| return err;
            defer path.deinit(self.allocator);
            try self.fillPathWith(
                path.elements.items,
                transform,
                self.render_state.fill_rule,
                paint,
            );
        }
    }

    /// Stroke a rectangle with the current paint and stroke settings.
    pub fn strokeRect(self: *Scene, rect: *const Rect) Error!void {
        var path = rect.toPath(DEFAULT_TOLERANCE, self.allocator) catch |err| return err;
        defer path.deinit(self.allocator);
        try self.strokePath(path.elements.items);
    }

    /// Push a new clip path to the clip stack.
    pub fn pushClipPath(self: *Scene, path: []const kurbo.PathEl) Error!void {
        const transform = self.transforms().clipPathTransform();
        try self.viewport_state.pushClip(
            self.allocator,
            path,
            self.render_state.fill_rule,
            transform,
            self.aliasing_threshold,
        );
    }

    /// Pop a clip path from the clip stack.
    pub fn popClipPath(self: *Scene) Error!void {
        try self.viewport_state.popClip();
    }

    /// Push a new clip layer.
    ///
    /// Layer scheduling is not ported yet; this returns `error.Unsupported`
    /// instead of drawing without the layer semantics.
    pub fn pushClipLayer(self: *Scene, path: []const kurbo.PathEl) Error!void {
        _ = self;
        _ = path;
        return error.Unsupported;
    }

    /// Push a new blend layer (blend modes need the schedule milestone).
    pub fn pushBlendLayer(self: *Scene, blend_mode: peniko.BlendMode) Error!void {
        _ = self;
        _ = blend_mode;
        return error.Unsupported;
    }

    /// Push a new opacity layer (layer scheduling milestone).
    pub fn pushOpacityLayer(self: *Scene, opacity: f32) Error!void {
        _ = self;
        _ = opacity;
        return error.Unsupported;
    }

    /// Pop the last pushed layer (layer scheduling milestone).
    pub fn popLayer(self: *Scene) Error!void {
        _ = self;
        return error.Unsupported;
    }

    /// Set the blend mode for subsequent rendering operations.
    pub fn setBlendMode(self: *Scene, blend_mode: peniko.BlendMode) Error!void {
        if (blend_mode.isDestructive()) return error.Unsupported;
        self.render_state.blend_mode = blend_mode;
    }

    /// Set the stroke settings for subsequent stroke operations.
    pub fn setStroke(self: *Scene, stroke: kurbo.Stroke) void {
        self.render_state.stroke = stroke;
    }

    /// Set the paint for subsequent rendering operations.
    pub fn setPaint(self: *Scene, paint: PaintType) void {
        self.render_state.paint = paint;
        self.setPaintVisible();
    }

    fn setPaintVisible(self: *Scene) void {
        self.paint_visible = switch (self.render_state.paint) {
            .solid => |color| color.components[3] != 0.0,
            .gradient, .image => true,
        };
    }

    /// Get the current paint.
    pub fn currentPaint(self: *const Scene) PaintType {
        return self.render_state.paint;
    }

    /// Set the current paint transform.
    pub fn setPaintTransform(self: *Scene, paint_transform: kurbo.Affine) void {
        self.render_state.transforms.setPaintTransform(paint_transform);
    }

    /// Reset the current paint transform.
    pub fn resetPaintTransform(self: *Scene) void {
        self.render_state.transforms.resetPaintTransform();
    }

    /// Set the fill rule for subsequent fill operations.
    pub fn setFillRule(self: *Scene, fill_rule: Fill) void {
        self.render_state.fill_rule = fill_rule;
    }

    /// Set the transform for subsequent rendering operations.
    pub fn setTransform(self: *Scene, transform: kurbo.Affine) void {
        self.render_state.transforms.setTransform(transform);
    }

    /// Reset the transform to identity.
    pub fn resetTransform(self: *Scene) void {
        self.render_state.transforms.resetTransform();
    }

    /// Set the aliasing threshold (`null` enables analytic AA).
    pub fn setAliasingThreshold(self: *Scene, aliasing_threshold: ?u8) void {
        self.aliasing_threshold = aliasing_threshold;
    }

    /// Reset the scene and update its size.
    pub fn resetAndResize(self: *Scene, width: u16, height: u16) Error!void {
        self.width = width;
        self.height = height;
        return self.reset();
    }

    /// Reset the scene to its default state.
    pub fn reset(self: *Scene) Error!void {
        try self.viewport_state.reset(self.allocator, self.width, self.height);
        self.strip_storage.clear();
        try self.root_transforms.reset(self.allocator);
        self.render_state.reset();
        self.setPaintVisible();
        self.recorder.reset(self.allocator, self.width, self.height);
        self.aliasing_threshold = null;
    }

    /// Whether strips can be emitted directly without a clip or threshold.
    fn canEmitFastStrips(self: *const Scene) bool {
        return self.viewport_state.clip() == null and self.aliasing_threshold == null;
    }

    fn fastRectBounds(self: *const Scene, rect: *const Rect) ?Rect {
        if (!self.canEmitFastStrips()) return null;

        // Skewed (and, for now, rotated) rectangles take the strip path.
        const transform = self.effectivePathTransform();
        if (!common.util.isAxisAligned(transform)) return null;

        const transformed = transform.transformRectBbox(rect.*).intersect(self.activeRect());
        if (transformed.isZeroArea()) return null;
        return transformed;
    }

    /// Run `generate` with the viewport's generator and clip, then record the
    /// produced strips if any.
    fn recordGeneratedPath(
        self: *Scene,
        paint: Paint,
        context: anytype,
        comptime generate: anytype,
    ) Error!void {
        const strip_start = self.strip_storage.strips.items.len;
        // The generation callbacks only fail with allocation errors; map the
        // erased error set explicitly so the Scene error set stays small and
        // nothing is silently swallowed.
        self.viewport_state.withGeneratorAndClip(context, generate) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.RootViewportStackUnderflow) return error.RootViewportStackUnderflow;
            if (err == error.ClipStackUnderflow) return error.ClipStackUnderflow;
            if (err == error.NoActiveLayer) return error.NoActiveLayer;
            return error.Unsupported;
        };
        const strip_end = self.strip_storage.strips.items.len;
        if (strip_end == strip_start) return;

        const strips = common.record.Range(usize).new(strip_start, strip_end);
        try self.recorder.pushDraw(
            self.allocator,
            .{ .path = .{ .strips = strips, .paint = paint } },
            self.strip_storage.strips.items[strips.start..strips.end],
        );
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "scene records a fast axis-aligned rect" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    const paint = peniko.color.Color.fromRgba8(30, 80, 200, 255);
    scene.setPaint(PaintType.fromAlphaColor(paint));
    try scene.fillRect(&Rect.new(8.25, 10.5, 48.75, 50.25));

    try testing.expectEqual(@as(usize, 1), scene.recorder.draws.items.len);
    const draw = scene.recorder.draws.items[0];
    try testing.expect(std.meta.activeTag(draw) == .rect);
    // `fast_rect_bounds` clips to the 64x64 viewport.
    try testing.expectEqual(Rect.new(8.25, 10.5, 48.75, 50.25), draw.rect.rect);
    // The fast path emits no strips.
    try testing.expectEqual(@as(usize, 0), scene.strip_storage.strips.items.len);
}

test "scene path fill generates strips and records a path draw" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.setFillRule(.even_odd);
    scene.setPaint(PaintType.fromAlphaColor(peniko.color.Color.BLACK));
    var path = try kurbo.bezpath.fromSvg(
        allocator,
        "M10 10 L50 10 L50 50 L10 50 Z M20 20 L20 40 L40 40 L40 20 Z",
    );
    defer path.deinit(allocator);
    try scene.fillPath(path.elements.items);

    try testing.expectEqual(@as(usize, 1), scene.recorder.draws.items.len);
    const draw = scene.recorder.draws.items[0];
    try testing.expect(std.meta.activeTag(draw) == .path);
    try testing.expect(scene.strip_storage.strips.items.len > 0);
    try testing.expectEqual(
        common.record.Range(usize).new(0, scene.strip_storage.strips.items.len),
        draw.path.strips,
    );
}

test "empty path is not recorded" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    try scene.fillPath(&.{});
    try testing.expectEqual(@as(usize, 0), scene.recorder.draws.items.len);
    try testing.expectEqual(@as(usize, 0), scene.recorder.nodes.items.len);
}

test "transparent paint makes the scene a no-op" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.setPaint(PaintType.fromAlphaColor(peniko.color.Color.TRANSPARENT));
    try scene.fillRect(&Rect.new(0, 0, 10, 10));
    try testing.expectEqual(@as(usize, 0), scene.recorder.draws.items.len);
}

test "gradient paint is unsupported until encoded paints land" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.render_state.paint = .{ .gradient = undefined };
    try testing.expectError(error.Unsupported, scene.fillRect(&Rect.new(0, 0, 10, 10)));
    try testing.expectError(error.Unsupported, scene.pushOpacityLayer(0.5));
}

test "reset clears draws and size" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 8, 4);
    defer scene.deinit();

    scene.setPaint(PaintType.fromAlphaColor(peniko.color.Color.BLACK));
    try scene.fillRect(&Rect.new(0, 0, 8, 4));
    try testing.expectEqual(@as(usize, 1), scene.recorder.draws.items.len);

    try scene.resetAndResize(4, 8);
    try testing.expectEqual(@as(usize, 0), scene.recorder.draws.items.len);
    try testing.expectEqual(@as(u16, 4), scene.width);
    try testing.expectEqual(@as(u16, 8), scene.height);

    try scene.fillRect(&Rect.new(0, 0, 8, 8));
    const draw = scene.recorder.draws.items[0];
    try testing.expectEqual(Rect.new(0, 0, 4, 8), draw.rect.rect);
}

test "transform_rotate stays on the path branch and bbox is clipped" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.setPaint(PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(250, 250, 250)));
    try scene.fillRect(&Rect.new(0, 0, 64, 64));

    const affine = kurbo.Affine.new(.{
        0.8660254037844387,
        0.5,
        -0.5,
        0.8660254037844387,
        20.287187078897962,
        -11.712812921102034,
    });
    scene.setTransform(affine);
    scene.setPaint(PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(16, 160, 96)));
    try scene.fillRect(&Rect.new(16, 16, 48, 48));

    try testing.expectEqual(@as(usize, 2), scene.recorder.draws.items.len);
    const rotated = scene.recorder.draws.items[1];
    // A rotated rectangle cannot take the fast path, so it is recorded as a
    // generated path and its transformed bbox is clipped to the viewport
    // before strip generation.
    try testing.expect(std.meta.activeTag(rotated) == .path);
    try testing.expect(scene.strip_storage.strips.items.len > 0);
}
