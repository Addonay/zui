//! Port of `vello_gpu/src/scene.rs` (Apache-2.0 OR MIT).
//!
//! `Scene` collects draw commands, generates analytic-AA strips through
//! `vellz.common` (`ViewportState` + `StripGenerator` + `StripStorage`), and
//! records them in a `CommandRecorder` for the GPU draw encoder.
//!
//! Supported:
//! - transforms (scene + paint), fill rule, aliasing threshold
//! - solid paints and the rectangle fast path
//! - filled and stroked paths
//! - clip paths (`pushClipPath`/`popClipPath`)
//! - indexed paints (gradients, images, blurred rounded rects) through
//!   `common.encode` into `encoded_paints`
//! - layers: clip, blend, opacity, and filter layers, plus the implicit
//!   per-draw layer created by `setFilterEffect`
//!
//! Mask layers are a documented local adapt: upstream `vello_gpu` has no mask
//! sampling path and panics, so this port multiplies the rendered layer
//! region by an uploaded mask texture in a dedicated pass before compositing
//! (`gpu/mask.zig`, `shaders/mask.wgsl`, `backend/renderer.zig`).

const std = @import("std");
const simd = @import("../simd/root.zig");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const common = @import("../common/root.zig");

const Fill = peniko.Fill;
const Filter = common.filter_effects.Filter;
const FilterData = common.filter.FilterData;
const LayerClip = common.record.LayerClip;
const LayerProps = common.record.LayerProps;
const Mask = common.mask.Mask;
const Paint = common.paint.Paint;
const PaintType = common.paint.PaintType;
const Rect = kurbo.Rect;
const RectU16 = common.geometry.RectU16;
const RenderState = common.render_state.RenderState;
const Strip = common.strip.Strip;
const StripGenerator = common.strip_generator.StripGenerator;
const StripStorage = common.strip_storage.StripStorage;
const Tile = common.tile.Tile;
const Transforms = common.transforms.Transforms;
const ViewportState = common.viewport.ViewportState;

/// Default tolerance for curve flattening.
pub const DEFAULT_TOLERANCE: f64 = 0.1;

/// Errors from `Scene` operations. `Unsupported` covers the features listed in
/// the file header; the remaining names are invalid-usage errors surfaced as
/// typed errors by `vellz.common` (upstream panics).
pub const Error = std.mem.Allocator.Error || error{
    Unsupported,
    TooManyPaints,
    RootViewportStackUnderflow,
    ClipStackUnderflow,
    ClipGenerationFailed,
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
                    // The CPU fast-rect fast path emits sparse strips whose
                    // bbox includes one extra tile column to the right of
                    // `floor(x1)` (and a tile-snapped `ceil(y1)` below).
                    // Layer extents must match the CPU oracle's pixmap bboxes,
                    // so mirror that rule instead of a plain tile snap.
                    extraRightTile(@intFromFloat(@floor(rect.x1))),
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
/// Matches the upstream `Scene` field set needed by the schedule milestone.
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
    /// Storage for encoded non-solid paint data.
    encoded_paints: std.ArrayList(common.encode.EncodedPaint),
    /// Whether the current paint is visible (e.g. alpha > 0).
    paint_visible: bool,
    /// Current filter effect applied to individual draw operations.
    filter: ?Filter,
    /// Current tint applied to image paints.
    tint: ?common.paint.Tint,
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
            .encoded_paints = .empty,
            .paint_visible = true,
            .filter = null,
            .tint = null,
            .strip_storage = StripStorage.init(.append),
            .recorder = common.record.CommandRecorder(RecordedDraw).new(width, height),
        };
        scene.setPaintVisible();
        return scene;
    }

    /// Release every owned buffer.
    pub fn deinit(self: *Scene) void {
        for (self.encoded_paints.items) |*paint| paint.deinit(self.allocator);
        self.encoded_paints.deinit(self.allocator);
        self.render_state.paint.deinit(self.allocator);
        if (self.filter) |filter| filter.deinit(self.allocator);
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
    /// Solid colors convert directly; gradients, images, and blurred rounded
    /// rects are encoded into `encoded_paints` and referenced by index.
    fn encodeCurrentPaint(self: *Scene) Error!Paint {
        const transform = self.effectivePaintTransform();
        return switch (self.render_state.paint) {
            .solid => |color| Paint.fromAlphaColor(color),
            .gradient => |gradient| common.encode.EncodeExt.encodeInto(
                gradient,
                self.allocator,
                &self.encoded_paints,
                transform,
                null,
            ) catch |err| return mapEncodeError(err),
            .image => |image| common.encode.EncodeExt.encodeInto(
                image,
                self.allocator,
                &self.encoded_paints,
                transform,
                self.tint,
            ) catch |err| return mapEncodeError(err),
        };
    }

    /// Run a draw operation, implicitly wrapping it in a layer when a
    /// non-default blend mode or filter effect is active (upstream
    /// `with_optional_filter_or_blend_layer`).
    fn withOptionalFilterOrBlendLayer(self: *Scene, context: anytype) Error!void {
        const blend_mode = self.render_state.blend_mode;
        const has_blend = !isDefaultBlendMode(blend_mode);
        const filter = if (self.filter) |filter| filter.clone() else null;

        if (!has_blend and filter == null) {
            return context.run(self);
        }

        try self.pushLayer(
            null,
            if (has_blend) blend_mode else null,
            null,
            null,
            filter,
        );
        if (context.run(self)) |_| {
            try self.popLayer();
        } else |err| {
            self.popLayer() catch {};
            return err;
        }
    }

    /// Fill a path with the current paint and fill rule.
    pub fn fillPath(self: *Scene, path: []const kurbo.PathEl) Error!void {
        if (!self.paint_visible) return;
        var ctx = FillPathContext{ .path = path };
        try self.withOptionalFilterOrBlendLayer(&ctx);
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
        var ctx = StrokePathContext{ .path = path };
        try self.withOptionalFilterOrBlendLayer(&ctx);
    }

    /// Fill a rectangle with the current paint and fill rule.
    pub fn fillRect(self: *Scene, rect: *const Rect) Error!void {
        if (!self.paint_visible or rect.isZeroArea()) return;
        var ctx = FillRectContext{ .rect = rect.* };
        try self.withOptionalFilterOrBlendLayer(&ctx);
    }

    /// Stroke a rectangle with the current paint and stroke settings.
    pub fn strokeRect(self: *Scene, rect: *const Rect) Error!void {
        var path = rect.toPath(DEFAULT_TOLERANCE, self.allocator) catch |err| return err;
        defer path.deinit(self.allocator);
        try self.strokePath(path.elements.items);
    }

    /// Fill a blurred rounded rectangle with the current paint color.
    ///
    /// Blurred rounded rectangles are analytic paints, not filters: the
    /// coverage is evaluated in the render shader.
    pub fn fillBlurredRoundedRect(
        self: *Scene,
        rect_in: Rect,
        radius: f32,
        std_dev: f32,
        invert: bool,
    ) Error!void {
        if (!self.paint_visible) return;
        var ctx = BlurredRectContext{
            .rect = rect_in.abs(),
            .radius = radius,
            .std_dev = std_dev,
            .invert = invert,
        };
        try self.withOptionalFilterOrBlendLayer(&ctx);
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

    /// Push a new layer with the given properties.
    ///
    /// `filter` and `mask` transfer ownership to the scene on success and are
    /// released on error. A mask whose dimensions do not match the scene is
    /// silently dropped (upstream behavior; see `RenderContext::pushLayer`).
    pub fn pushLayer(
        self: *Scene,
        path: ?[]const kurbo.PathEl,
        blend_mode: ?peniko.BlendMode,
        opacity: ?f32,
        mask: ?Mask,
        filter: ?Filter,
    ) Error!void {
        const layer_transform = self.effectivePathTransform();
        var filter_data: ?FilterData = if (filter) |owned| FilterData.new(owned, layer_transform) else null;
        errdefer if (filter_data) |*data| data.deinit(self.allocator);

        var effective_mask: ?Mask = mask;
        if (effective_mask) |owned| {
            if (owned.width() != self.width or owned.height() != self.height) {
                // Upstream silently drops mismatched masks; release ours so it
                // is not leaked.
                owned.deinit(self.allocator);
                effective_mask = null;
            }
        }
        errdefer if (effective_mask) |owned| owned.deinit(self.allocator);

        const relative_root_transform = if (filter_data) |data| blk: {
            const shift = data.sourceShift();
            break :blk kurbo.Affine.translate(kurbo.Vec2.new(
                @floatFromInt(shift[0]),
                @floatFromInt(shift[1]),
            ));
        } else kurbo.Affine.IDENTITY;

        try self.root_transforms.pushRoot(self.allocator, relative_root_transform);
        errdefer self.root_transforms.popRoot();
        if (filter_data) |*data| {
            try self.viewport_state.pushRootViewport(self.allocator, data);
            errdefer self.viewport_state.popRootViewport(self.allocator) catch {};
        }

        var clip_path: ?LayerClip = null;
        if (path) |clip| {
            const strip_start = self.strip_storage.strips.items.len;
            var ctx = PathGenContext{
                .allocator = self.allocator,
                .path = clip,
                .fill_rule = self.render_state.fill_rule,
                .transform = layer_transform,
                .aliasing_threshold = self.aliasing_threshold,
                .storage = &self.strip_storage,
            };
            self.viewport_state.withGeneratorAndClip(&ctx, PathGenContext.run) catch |err| {
                return mapViewportError(err);
            };
            const strip_end = self.strip_storage.strips.items.len;
            clip_path = .{
                .strip_range = common.record.Range(usize).new(strip_start, strip_end),
                .thread_idx = 0,
                .bbox = common.strip.stripBbox(self.strip_storage.strips.items[strip_start..strip_end]) orelse
                    RectU16.ZERO,
            };
        }

        try self.recorder.pushLayer(self.allocator, .{
            .blend_mode = blend_mode orelse peniko.BlendMode.default,
            .opacity = opacity orelse 1.0,
            .mask = effective_mask,
            .clip_path = clip_path,
        }, filter_data);
        // Ownership of the filter graph and mask transferred to the recorder.
        filter_data = null;
        effective_mask = null;
    }

    /// Push a new clip layer.
    pub fn pushClipLayer(self: *Scene, path: []const kurbo.PathEl) Error!void {
        return self.pushLayer(path, null, null, null, null);
    }

    /// Push a new blend layer.
    pub fn pushBlendLayer(self: *Scene, blend_mode: peniko.BlendMode) Error!void {
        return self.pushLayer(null, blend_mode, null, null, null);
    }

    /// Push a new opacity layer.
    pub fn pushOpacityLayer(self: *Scene, opacity: f32) Error!void {
        return self.pushLayer(null, null, opacity, null, null);
    }

    /// Push a new filter layer.
    pub fn pushFilterLayer(self: *Scene, filter: Filter) Error!void {
        return self.pushLayer(null, null, null, null, filter);
    }

    /// Push a new mask layer.
    ///
    /// The mask must match the scene dimensions; otherwise it is dropped
    /// exactly like the CPU renderer (`RenderContext::pushLayer`).
    pub fn pushMaskLayer(self: *Scene, mask: Mask) Error!void {
        return self.pushLayer(null, null, null, mask, null);
    }

    /// Pop the last pushed layer.
    pub fn popLayer(self: *Scene) Error!void {
        const popped = self.recorder.popLayer() catch |err| switch (err) {
            error.NoActiveLayer => return error.NoActiveLayer,
        };
        if (popped == .filter) {
            try self.viewport_state.popRootViewport(self.allocator);
        }
        self.root_transforms.popRoot();
    }

    /// Set a filter effect applied to subsequent draws (each draw gets its own
    /// implicit filter layer; upstream `set_filter_effect`).
    pub fn setFilterEffect(self: *Scene, filter: Filter) void {
        if (self.filter) |previous| previous.deinit(self.allocator);
        self.filter = filter;
    }

    /// Clear the current filter effect.
    pub fn resetFilterEffect(self: *Scene) void {
        if (self.filter) |previous| previous.deinit(self.allocator);
        self.filter = null;
    }

    /// Set the tint for subsequent image paints.
    pub fn setTint(self: *Scene, tint: ?common.paint.Tint) void {
        self.tint = tint;
    }

    /// Clear the tint.
    pub fn resetTint(self: *Scene) void {
        self.tint = null;
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
    ///
    /// Takes ownership of `paint` (gradients/images own heap resources) and
    /// releases the previously set paint.
    pub fn setPaint(self: *Scene, paint: PaintType) void {
        self.render_state.paint.deinit(self.allocator);
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
        for (self.encoded_paints.items) |*paint| paint.deinit(self.allocator);
        self.encoded_paints.clearRetainingCapacity();
        try self.root_transforms.reset(self.allocator);
        self.render_state.paint.deinit(self.allocator);
        self.render_state.reset();
        self.setPaintVisible();
        if (self.filter) |filter| filter.deinit(self.allocator);
        self.filter = null;
        self.tint = null;
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
            return mapViewportError(err);
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

/// Upstream `blend_mode == BlendMode::default()` (a Zig struct comparison
/// would compare every field, so name it).
fn isDefaultBlendMode(blend_mode: peniko.BlendMode) bool {
    return blend_mode.mix == .normal and blend_mode.compose == .src_over;
}

/// Map an erased viewport/recorder error into the Scene error set.
fn mapViewportError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RootViewportStackUnderflow => error.RootViewportStackUnderflow,
        error.ClipStackUnderflow => error.ClipStackUnderflow,
        error.ClipGenerationFailed => error.ClipGenerationFailed,
        error.NoActiveLayer => error.NoActiveLayer,
        else => error.Unsupported,
    };
}

/// Map a paint-encoder error into the Scene error set.
fn mapEncodeError(err: common.encode.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyPaints => error.TooManyPaints,
        error.Unsupported => error.Unsupported,
    };
}

/// Draw context for `fillPath`.
const FillPathContext = struct {
    path: []const kurbo.PathEl,

    fn run(self: *@This(), scene: *Scene) Error!void {
        const paint = try scene.encodeCurrentPaint();
        try scene.fillPathWith(
            self.path,
            scene.effectivePathTransform(),
            scene.render_state.fill_rule,
            paint,
        );
    }
};

/// Draw context for `strokePath`.
const StrokePathContext = struct {
    path: []const kurbo.PathEl,

    fn run(self: *@This(), scene: *Scene) Error!void {
        const paint = try scene.encodeCurrentPaint();
        var ctx = StrokeGenContext{
            .allocator = scene.allocator,
            .path = self.path,
            .stroke = &scene.render_state.stroke,
            .transform = scene.effectivePathTransform(),
            .aliasing_threshold = scene.aliasing_threshold,
            .storage = &scene.strip_storage,
        };
        try scene.recordGeneratedPath(paint, &ctx, StrokeGenContext.run);
    }
};

/// Draw context for `fillRect`.
const FillRectContext = struct {
    rect: Rect,

    fn run(self: *@This(), scene: *Scene) Error!void {
        const rect = self.rect;
        if (rect.isZeroArea()) return;

        const paint = try scene.encodeCurrentPaint();

        if (scene.fastRectBounds(&rect)) |bounds| {
            try scene.recorder.pushDraw(
                scene.allocator,
                .{ .rect = .{ .rect = bounds, .paint = paint } },
                &.{},
            );
            return;
        }

        const transform = scene.effectivePathTransform();
        if (common.util.isAxisAligned(transform) and scene.aliasing_threshold == null) {
            var ctx = RectGenContext{
                .allocator = scene.allocator,
                .rect = transform.transformRectBbox(rect),
                .storage = &scene.strip_storage,
            };
            try scene.recordGeneratedPath(paint, &ctx, RectGenContext.run);
        } else {
            // TODO: Use a temporary storage for rect paths, like in `vello_cpu`.
            var path = rect.toPath(DEFAULT_TOLERANCE, scene.allocator) catch |err| return err;
            defer path.deinit(scene.allocator);
            try scene.fillPathWith(
                path.elements.items,
                transform,
                scene.render_state.fill_rule,
                paint,
            );
        }
    }
};

/// Draw context for `fillBlurredRoundedRect`.
const BlurredRectContext = struct {
    rect: Rect,
    radius: f32,
    std_dev: f32,
    invert: bool,

    fn run(self: *@This(), scene: *Scene) Error!void {
        const rect = self.rect;
        const color: peniko.color.Color = switch (scene.render_state.paint) {
            .solid => |solid| solid,
            else => peniko.palette.css.BLACK,
        };
        const blurred = common.blurred_rounded_rect.BlurredRoundedRectangle{
            .rect = rect,
            .color = color,
            .radius = self.radius,
            .std_dev = self.std_dev,
            .invert = self.invert,
        };
        const paint = common.encode.encodeBlurredRoundedRectangle(
            &blurred,
            scene.allocator,
            &scene.encoded_paints,
            scene.effectivePaintTransform(),
            null,
        ) catch |err| return mapEncodeError(err);

        const kernel_size = 2.5 * @as(f64, self.std_dev);
        const inflated_rect = rect.inflate(kernel_size, kernel_size);
        if (scene.fastRectBounds(&inflated_rect)) |bounds| {
            try scene.recorder.pushDraw(
                scene.allocator,
                .{ .rect = .{ .rect = bounds, .paint = paint } },
                &.{},
            );
            return;
        }

        const path_transform = scene.effectivePathTransform();
        if (common.util.isAxisAligned(path_transform) and scene.aliasing_threshold == null) {
            var ctx = RectGenContext{
                .allocator = scene.allocator,
                .rect = path_transform.transformRectBbox(inflated_rect),
                .storage = &scene.strip_storage,
            };
            try scene.recordGeneratedPath(paint, &ctx, RectGenContext.run);
        } else {
            var path = inflated_rect.toPath(DEFAULT_TOLERANCE, scene.allocator) catch |err| return err;
            defer path.deinit(scene.allocator);
            try scene.fillPathWith(
                path.elements.items,
                path_transform,
                .non_zero,
                paint,
            );
        }
    }
};


/// `floor(x1)` extended by one `Tile.WIDTH` column, saturating at `u16`
/// (mirrors the CPU sparse-strip bbox for fast rectangles).
fn extraRightTile(x1: u16) u16 {
    const columns = x1 / Tile.WIDTH;
    const value = std.math.mul(u16, columns + 1, Tile.WIDTH) catch
        return std.math.maxInt(u16);
    return value;
}

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

test "gradient paint encodes into encoded_paints" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    var gradient: peniko.Gradient = .{};
    gradient.kind = .{ .linear = peniko.LinearGradientPosition.new(
        kurbo.Point.new(0, 0),
        kurbo.Point.new(64, 0),
    ) };
    gradient.stops = try peniko.ColorStops.fromSlice(allocator, &.{
        .{ .offset = 0.0, .color = peniko.color.Color.fromRgb8(255, 0, 0) },
        .{ .offset = 1.0, .color = peniko.color.Color.fromRgb8(0, 0, 255) },
    });
    scene.setPaint(PaintType.fromGradient(gradient));
    try scene.fillRect(&Rect.new(0, 0, 64, 64));

    try testing.expectEqual(@as(usize, 1), scene.encoded_paints.items.len);
    try testing.expectEqual(@as(usize, 1), scene.recorder.draws.items.len);
    try testing.expect(std.meta.activeTag(scene.recorder.draws.items[0].rect.paint) == .indexed);
}

test "opacity layer wraps draws in an implicit layer" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.setPaint(PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(10, 20, 30)));
    try scene.fillRect(&Rect.new(0, 0, 64, 64));

    try scene.pushOpacityLayer(0.5);
    try scene.fillRect(&Rect.new(8, 8, 56, 56));
    try scene.popLayer();

    try testing.expectEqual(@as(usize, 1), scene.recorder.layers.items.len);
    const props = scene.recorder.layers.items[0].props;
    try testing.expectEqual(@as(f32, 0.5), props.opacity);
}

test "mismatched mask layer is dropped and matching mask is recorded" {
    const allocator = testing.allocator;
    var scene = try Scene.init(allocator, 64, 64);
    defer scene.deinit();

    // Upstream drops masks that do not match the scene dimensions.
    const small = try Mask.fromParts(allocator, &.{ 255, 0, 0, 255 }, 2, 2);
    try scene.pushMaskLayer(small);
    try testing.expect(scene.recorder.layers.items[0].props.mask == null);
    try scene.popLayer();

    const matching = try Mask.fromParts(allocator, &.{ 255, 128, 64, 0 }, 2, 2);
    // Resize the scene to the mask dimensions so it is retained.
    try scene.resetAndResize(2, 2);
    try scene.pushMaskLayer(matching);
    try testing.expect(scene.recorder.layers.items[0].props.mask != null);
    try scene.popLayer();
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
