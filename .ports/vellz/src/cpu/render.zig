//! Port of vello_cpu src/render.rs (public API subset) (Apache-2.0 OR MIT).
//!
//! `RenderContext` is the main entry point for CPU drawing: it maintains the
//! current render state (transforms, paint, stroke, fill rule, ...), records
//! drawing commands through the selected dispatcher, and rasterizes the
//! recorded scene into a `Pixmap`.
//!
//! Scope:
//!
//! - **Solid, gradient and image paints.** `setPaint` accepts a
//!   `peniko.Color` or a `common.paint.PaintType`; gradients and images are
//!   encoded into `encoded_paints` at draw time (M2) and rasterized by the
//!   fine painters. `fillBlurredRoundedRect` encodes an analytic blurred
//!   rounded rectangle paint.
//! - **Layers**: `pushClipLayer`/`pushBlendLayer`/`pushOpacityLayer`/
//!   `pushLayer` support clip/opacity/blend layers, and `pushLayer` accepts a
//!   filter. A `setFilterEffect` filter wraps each subsequent draw in a
//!   recorded filter layer (upstream `with_optional_filter`); the filter
//!   itself stays set until `resetFilterEffect`.
//! - **Path-level masks** (`set_mask`/`reset_mask` upstream) are M2, matching
//!   their `RecordedFill.mask` seam in `cpu/record.zig`.
//! - **Multi-threaded rendering (M4).** `RenderSettings.num_threads > 0`
//!   selects `dispatch.multi_threaded`; the multi-threaded f32 output is
//!   byte-identical to the single-threaded output. `flush` is fallible for
//!   multi-threaded dispatch (upstream panics on allocation failure) and must
//!   be called before `renderWith`; otherwise `renderWith` returns
//!   `error.NotFlushed`. Filter layers and the u8 (`optimize_speed`) kernel
//!   stay `error.Unsupported` in both dispatch paths.
//!
//! Settings types (`RenderMode`, `PixelFormat`, `RenderSettings`,
//! `RasterizerSettings`, `TargetInit`) are defined in `cpu/settings.zig` and
//! re-exported here so the public path matches upstream `vello_cpu`; the
//! dispatchers import the leaf module directly, which avoids an import cycle
//! (`render.zig` imports the dispatch vtable).
//!
//! Error policy: where upstream asserts or panics (`render` with unclosed
//! layers, `pop_layer` without a layer) this port returns typed errors from
//! fallible methods; the infallible public signatures (`popLayer`,
//! `popClipPath`, `reset`) assert in debug builds and keep the context defined
//! in release builds.
//!
//! `reset` deliberately does **not** clear `filter` or `aliasing_threshold`;
//! upstream leaves both in effect across resets, and state-holding callers
//! rely on that.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const blurred_rounded_rect_mod = @import("../common/blurred_rounded_rect.zig");
const encode_mod = @import("../common/encode.zig");
const filter_data_mod = @import("../common/filter.zig");
const filter_effects = @import("../common/filter_effects.zig");
const mask_mod = @import("../common/mask.zig");
const paint_mod = @import("../common/paint.zig");
const pixmap_mod = @import("../common/pixmap.zig");
const shared_mod = @import("../common/shared.zig");
const render_state_mod = @import("../common/render_state.zig");
const transforms_mod = @import("../common/transforms.zig");
const common_util = @import("../common/util.zig");
const settings_mod = @import("settings.zig");
const dispatch_mod = @import("dispatch/mod.zig");

pub const RenderMode = settings_mod.RenderMode;
pub const PixelFormat = settings_mod.PixelFormat;
pub const RenderSettings = settings_mod.RenderSettings;
pub const RasterizerSettings = settings_mod.RasterizerSettings;
pub const TargetInit = settings_mod.TargetInit;
pub const Offset = settings_mod.Offset;

const Filter = filter_effects.Filter;
const Paint = paint_mod.Paint;
const PaintType = paint_mod.PaintType;
const ImageId = paint_mod.ImageId;
const Mask = mask_mod.Mask;
const Pixmap = pixmap_mod.Pixmap;
const PremulColor = paint_mod.PremulColor;
const PixmapMut = pixmap_mod.PixmapMut;
const RenderState = render_state_mod.RenderState;
const RootTransforms = transforms_mod.RootTransforms;

/// Base of the reserved atlas-page image-ID range (upstream
/// `ATLAS_IMAGE_ID_BASE`). User images use ids below this value.
pub const ATLAS_IMAGE_ID_BASE: u32 = 0x7fff_ffff;

/// Maps opaque `ImageId`s to pixmap data (upstream `ImageRegistry`).
///
/// Ownership: `register` takes ownership of the passed handle; `resolve`
/// returns a new owned handle (a refcount bump, as upstream clones the
/// `Arc`); `destroy`/`clear`/`deinit` release the registry's handles.
pub const ImageRegistry = struct {
    images: std.AutoHashMapUnmanaged(u32, shared_mod.Shared(Pixmap)) = .empty,
    next_id: u32 = 0,

    pub const RegisterError = error{ ImageIdExhausted, OutOfMemory };

    /// Register `pixmap` and return its id. Ownership of `pixmap` moves into
    /// the registry on success; on error the caller keeps it.
    pub fn register(
        self: *ImageRegistry,
        allocator: std.mem.Allocator,
        pixmap: shared_mod.Shared(Pixmap),
    ) RegisterError!ImageId {
        if (self.next_id >= ATLAS_IMAGE_ID_BASE) return error.ImageIdExhausted;
        const id = self.next_id;
        try self.images.put(allocator, id, pixmap);
        self.next_id += 1;
        return ImageId.new(id);
    }

    /// Remove and release the image with `id`. Returns whether it existed.
    pub fn destroy(
        self: *ImageRegistry,
        allocator: std.mem.Allocator,
        id: ImageId,
    ) bool {
        const entry = self.images.fetchRemove(id.asU32()) orelse return false;
        const handle = entry.value;
        handle.release(allocator);
        return true;
    }

    /// Look up `id`, returning a new owned handle or null.
    pub fn resolve(self: *const ImageRegistry, id: ImageId) ?shared_mod.Shared(Pixmap) {
        const handle = self.images.get(id.asU32()) orelse return null;
        return handle.clone();
    }

    /// Release every registered image; ids restart at zero.
    pub fn clear(self: *ImageRegistry, allocator: std.mem.Allocator) void {
        var it = self.images.valueIterator();
        while (it.next()) |handle_ptr| {
            handle_ptr.release(allocator);
        }
        self.images.clearRetainingCapacity();
        self.next_id = 0;
    }

    /// Release every image and the map storage.
    pub fn deinit(self: *ImageRegistry, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.images.deinit(allocator);
    }
};

/// Persistent resources required by the CPU renderer.
///
/// Create one instance per renderer and reuse it across scenes. The image
/// registry backs `ImageSource.opaque_id` resolution; glyph caches (M3) are
/// added here without changing the public lifecycle.
pub const Resources = struct {
    /// Registry for `ImageSource.opaque_id` paints.
    image_registry: ImageRegistry = .{},

    /// Create a new set of renderer resources.
    pub fn init() Resources {
        return .{};
    }

    /// Release owned resources.
    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.image_registry.deinit(allocator);
    }

    /// Register a pixmap and return its opaque id. Ownership moves into the
    /// registry on success.
    pub fn registerImage(
        self: *Resources,
        allocator: std.mem.Allocator,
        pixmap: shared_mod.Shared(Pixmap),
    ) ImageRegistry.RegisterError!ImageId {
        return self.image_registry.register(allocator, pixmap);
    }

    /// Release a registered image (upstream `destroy_image`).
    pub fn destroyImage(
        self: *Resources,
        allocator: std.mem.Allocator,
        id: ImageId,
    ) bool {
        return self.image_registry.destroy(allocator, id);
    }

    /// Resolve an opaque id to an owned pixmap handle (upstream `resolve_image`).
    pub fn resolveImage(self: *const Resources, id: ImageId) ?shared_mod.Shared(Pixmap) {
        return self.image_registry.resolve(id);
    }

    /// Release all registered images (upstream `clear_images`).
    pub fn clearImages(self: *Resources, allocator: std.mem.Allocator) void {
        self.image_registry.clear(allocator);
    }

    /// Build an `ImageResolver` view of this registry.
    pub fn imageResolver(self: *const Resources) paint_mod.ImageResolver {
        return .{ .resolveFn = resolveErased, .context = self };
    }

    fn resolveErased(context: ?*const anyopaque, id: ImageId) ?shared_mod.Shared(Pixmap) {
        const self: *const Resources = @ptrCast(@alignCast(context orelse return null));
        return self.resolveImage(id);
    }
};

/// A render context for CPU-based 2D graphics rendering.
pub const RenderContext = struct {
    /// The allocator this context was created with (used by infallible
    /// signatures that still need to release memory, e.g. `reset`).
    allocator: std.mem.Allocator,
    /// Width of the render target in pixels.
    ///
    /// Named `scene_width` because Zig cannot have a field and a method with
    /// the same name; the upstream accessor `width()` is preserved.
    scene_width: u16,
    /// Height of the render target in pixels.
    ///
    /// Named `scene_height` for the same reason as `scene_width`.
    scene_height: u16,
    /// The current rendering state.
    state: RenderState,
    /// Stack of root transforms (one entry per pushed layer, plus the base).
    root_transforms: RootTransforms,
    /// Optional threshold for aliasing.
    aliasing_threshold: ?u8,
    /// The current paint-level filter effect.
    ///
    /// While set, every draw operation records its own filter layer with a
    /// clone of this filter (upstream `with_optional_filter`). Owned handle:
    /// the context releases it on `deinit`, `resetFilterEffect`, or
    /// replacement by `setFilterEffect`.
    filter: ?Filter,
    /// The path-level mask applied to subsequent draws (upstream `mask`).
    /// Owned; `Mask` is reference-counted so `setMask`/`resetMask` are cheap.
    mask: ?Mask,
    /// The settings this context was created with.
    render_settings: RenderSettings,
    /// The selected dispatcher (single- or multi-threaded). The concrete
    /// implementation is heap-allocated so this context stays movable; see
    /// `cpu/dispatch/mod.zig`.
    dispatcher: dispatch_mod.Dispatcher,
    /// Temporary path buffer to avoid repeated allocations.
    temp_path: std.ArrayList(kurbo.PathEl),
    /// Encoded gradient/image paints produced by `encodeCurrentPaint`.
    ///
    /// Each draw appends the encoding of the current paint (upstream does the
    /// same: methods take `&mut self` and the list is cleared by `reset`).
    encoded_paints: std.ArrayList(encode_mod.EncodedPaint),

    /// Create a new render context with the given width and height in pixels.
    pub fn init(
        allocator: std.mem.Allocator,
        init_width: u16,
        init_height: u16,
        settings: RenderSettings,
    ) !RenderContext {
        var root_transforms = try RootTransforms.init(allocator);
        errdefer root_transforms.deinit(allocator);

        var dispatcher = try dispatch_mod.Dispatcher.create(
            allocator,
            init_width,
            init_height,
            settings,
        );
        errdefer dispatcher.destroy(allocator);

        return .{
            .allocator = allocator,
            .scene_width = init_width,
            .scene_height = init_height,
            .state = RenderState.default,
            .root_transforms = root_transforms,
            .aliasing_threshold = null,
            .filter = null,
            .mask = null,
            .render_settings = settings,
            .dispatcher = dispatcher,
            .temp_path = .empty,
            .encoded_paints = .empty,
        };
    }

    /// Release the encoded paints and their owned gradient/image payloads.
    fn clearEncodedPaints(self: *RenderContext) void {
        for (self.encoded_paints.items) |*encoded| encoded.deinit(self.allocator);
        self.encoded_paints.clearRetainingCapacity();
    }

    /// Release every owned buffer, including any recorded layer resources, the
    /// owned `filter` effect, and any owned gradient/image paint payload.
    pub fn deinit(self: *RenderContext, allocator: std.mem.Allocator) void {
        self.dispatcher.destroy(allocator);
        self.root_transforms.deinit(allocator);
        self.temp_path.deinit(allocator);
        self.clearEncodedPaints();
        self.encoded_paints.deinit(allocator);
        self.state.paint.deinit(allocator);
        if (self.filter) |filter| filter.deinit(allocator);
        if (self.mask) |mask| mask.deinit(allocator);
        self.* = undefined;
    }

    /// Reset the render context for a new scene, keeping its size.
    ///
    /// Upstream intentionally leaves `filter` and `aliasing_threshold` intact;
    /// this port does the same. The recorded scene, render state, root
    /// transforms, and temporary path are cleared.
    pub fn reset(self: *RenderContext) void {
        self.dispatcher.reset(self.allocator, self.scene_width, self.scene_height) catch |err| {
            // `reset` without a size change only frees/clears retained buffers
            // (see `Dispatcher.reset`), so an allocation failure can only come
            // from a pathological allocator; the context stays defined.
            std.debug.assert(err == error.OutOfMemory);
        };
        self.root_transforms.reset(self.allocator) catch |err| {
            std.debug.assert(err == error.OutOfMemory);
        };
        self.temp_path.clearRetainingCapacity();
        self.clearEncodedPaints();
        self.state.paint.deinit(self.allocator);
        if (self.mask) |mask| mask.deinit(self.allocator);
        self.mask = null;
        self.state.reset();
    }

    /// Reset the render context and update the scene size.
    ///
    /// Unlike `reset`, resizing can allocate, so this variant is fallible.
    pub fn resetAndResize(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        new_width: u16,
        new_height: u16,
    ) !void {
        // Commit the new size only after the fallible resets succeeded.
        try self.dispatcher.reset(allocator, new_width, new_height);
        try self.root_transforms.reset(allocator);
        self.scene_width = new_width;
        self.scene_height = new_height;
        self.temp_path.clearRetainingCapacity();
        self.clearEncodedPaints();
        self.state.paint.deinit(allocator);
        self.state.reset();
    }

    /// Return the width of the scene.
    pub fn width(self: *const RenderContext) u16 {
        return self.scene_width;
    }

    /// Return the height of the scene.
    pub fn height(self: *const RenderContext) u16 {
        return self.scene_height;
    }

    /// Return the render settings used by this context.
    pub fn renderSettings(self: *const RenderContext) *const RenderSettings {
        return &self.render_settings;
    }

    /// Whether rendering is currently configured to run in multi-threaded
    /// mode (`RenderSettings.num_threads > 0`).
    pub fn isMultiThreaded(self: *const RenderContext) bool {
        return self.dispatcher.isMultiThreaded();
    }

    // -------------------------------------------------------------- state

    /// Set the current transform.
    pub fn setTransform(self: *RenderContext, new_transform: kurbo.Affine) void {
        self.state.transforms.setTransform(new_transform);
    }

    /// Get the current transform.
    pub fn transform(self: *const RenderContext) kurbo.Affine {
        return self.state.transforms.getTransform();
    }

    /// Reset the current transform.
    pub fn resetTransform(self: *RenderContext) void {
        self.state.transforms.resetTransform();
    }

    /// Set the current paint transform.
    pub fn setPaintTransform(self: *RenderContext, paint_transform: kurbo.Affine) void {
        self.state.transforms.setPaintTransform(paint_transform);
    }

    /// Get the current paint transform.
    pub fn paintTransform(self: *const RenderContext) kurbo.Affine {
        return self.state.transforms.paintTransform();
    }

    /// Reset the current paint transform.
    pub fn resetPaintTransform(self: *RenderContext) void {
        self.state.transforms.resetPaintTransform();
    }

    /// Set the current paint.
    ///
    /// Accepts a `peniko.Color` (straight-alpha sRGB) or a
    /// `common.paint.PaintType`. Gradients and images are encoded into
    /// `encoded_paints` when a draw operation uses them. Ownership of an owned
    /// `PaintType` payload transfers to the context; the caller must not
    /// release it afterwards, and the new value must not alias the currently
    /// stored paint.
    pub fn setPaint(self: *RenderContext, new_paint: anytype) void {
        self.state.paint.deinit(self.allocator);
        switch (@TypeOf(new_paint)) {
            peniko.Color => self.state.paint = PaintType.fromAlphaColor(new_paint),
            PaintType => self.state.paint = new_paint,
            else => @compileError(
                "setPaint expects peniko.Color or common.paint.PaintType",
            ),
        }
    }

    /// Get the current paint.
    pub fn paint(self: *const RenderContext) *const PaintType {
        return &self.state.paint;
    }

    /// Set the current fill rule.
    pub fn setFillRule(self: *RenderContext, fill_rule: peniko.Fill) void {
        self.state.fill_rule = fill_rule;
    }

    /// Get the current fill rule.
    pub fn fillRule(self: *const RenderContext) peniko.Fill {
        return self.state.fill_rule;
    }

    /// Set the current stroke.
    pub fn setStroke(self: *RenderContext, new_stroke: kurbo.Stroke) void {
        self.state.stroke = new_stroke;
    }

    /// Get the current stroke.
    pub fn stroke(self: *const RenderContext) *const kurbo.Stroke {
        return &self.state.stroke;
    }

    /// Set the blend mode that should be used when drawing objects.
    pub fn setBlendMode(self: *RenderContext, blend_mode: peniko.BlendMode) void {
        self.state.blend_mode = blend_mode;
    }

    /// Get the currently active blend mode.
    pub fn blendMode(self: *const RenderContext) peniko.BlendMode {
        return self.state.blend_mode;
    }

    /// Set the aliasing threshold.
    ///
    /// `null` (the default and recommended option) enables anti-aliasing.
    /// Otherwise a pixel is fully painted when its coverage is at least the
    /// threshold (0..255) and not painted at all below it.
    pub fn setAliasingThreshold(self: *RenderContext, aliasing_threshold: ?u8) void {
        self.aliasing_threshold = aliasing_threshold;
    }

    /// Get the aliasing threshold.
    pub fn aliasingThreshold(self: *const RenderContext) ?u8 {
        return self.aliasing_threshold;
    }

    /// Apply a filter to the current paint (affects the next drawn elements).
    ///
    /// This sets a filter that will be applied to the next drawn element; to
    /// apply a filter to multiple elements, use `pushLayer` (or
    /// `pushFilterLayer`). The context takes ownership of `filter`.
    pub fn setFilterEffect(self: *RenderContext, filter: Filter) void {
        if (self.filter) |old| old.deinit(self.allocator);
        self.filter = filter;
    }

    /// Reset the current filter effect, releasing the owned filter.
    pub fn resetFilterEffect(self: *RenderContext) void {
        if (self.filter) |filter| filter.deinit(self.allocator);
        self.filter = null;
    }

    /// Push a filter layer that affects all subsequent drawing operations
    /// (upstream `push_filter_layer`).
    pub fn pushFilterLayer(self: *RenderContext, allocator: std.mem.Allocator, filter: Filter) !void {
        try self.pushLayer(allocator, null, null, null, null, filter);
    }

    /// Encode the current paint into `encoded_paints` (upstream
    /// `encode_current_paint`).
    ///
    /// Solid paints return directly; gradients and images append an encoded
    /// paint and return its `IndexedPaint`. Upstream clones the stored paint
    /// before encoding (its encoders take ownership of the metadata); this
    /// port borrows the stored paint and lets the encoders clone what they
    /// retain.
    fn encodeCurrentPaint(self: *RenderContext) encode_mod.Error!Paint {
        switch (self.state.paint) {
            .solid => |color| return Paint.fromAlphaColor(color),
            .gradient => |*gradient| {
                const paint_transform = self.root_transforms
                    .effectivePaintTransform(self.state.transforms);
                return encode_mod.encodeInto(
                    gradient,
                    self.allocator,
                    &self.encoded_paints,
                    paint_transform,
                    null,
                );
            },
            .image => |*image| {
                const paint_transform = self.root_transforms
                    .effectivePaintTransform(self.state.transforms);
                return encode_mod.encodeInto(
                    image,
                    self.allocator,
                    &self.encoded_paints,
                    paint_transform,
                    self.state.tint,
                );
            },
        }
    }

    fn rectToTempPath(self: *RenderContext, allocator: std.mem.Allocator, rect: kurbo.Rect) !void {
        const elements = [_]kurbo.PathEl{
            .{ .MoveTo = kurbo.Point.new(rect.x0, rect.y0) },
            .{ .LineTo = kurbo.Point.new(rect.x1, rect.y0) },
            .{ .LineTo = kurbo.Point.new(rect.x1, rect.y1) },
            .{ .LineTo = kurbo.Point.new(rect.x0, rect.y1) },
            .ClosePath,
        };
        self.temp_path.clearRetainingCapacity();
        try self.temp_path.appendSlice(allocator, &elements);
    }

    // ------------------------------------------------------- drawing ops

    /// Fill a path.
    pub fn fillPath(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        if (self.filter) |filter| {
            try self.pushLayer(allocator, null, null, null, null, filter.clone());
            errdefer self.popLayer();
            try self.fillPathInner(allocator, path);
            self.popLayer();
        } else {
            try self.fillPathInner(allocator, path);
        }
    }

    fn fillPathInner(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        const encoded_paint = try self.encodeCurrentPaint();
        const path_transform = self.root_transforms.effectivePathTransform(self.state.transforms);
        try self.dispatcher.fillPath(
            allocator,
            path,
            self.state.fill_rule,
            path_transform,
            encoded_paint,
            self.state.blend_mode,
            self.aliasing_threshold,
            self.currentMask(),
        );
    }

    /// Stroke a path.
    pub fn strokePath(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        if (self.filter) |filter| {
            try self.pushLayer(allocator, null, null, null, null, filter.clone());
            errdefer self.popLayer();
            try self.strokePathInner(allocator, path);
            self.popLayer();
        } else {
            try self.strokePathInner(allocator, path);
        }
    }

    fn strokePathInner(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        const encoded_paint = try self.encodeCurrentPaint();
        const path_transform = self.root_transforms.effectivePathTransform(self.state.transforms);
        try self.dispatcher.strokePath(
            allocator,
            path,
            &self.state.stroke,
            path_transform,
            encoded_paint,
            self.state.blend_mode,
            self.aliasing_threshold,
            self.currentMask(),
        );
    }

    /// Fill a rectangle.
    pub fn fillRect(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
    ) !void {
        if (self.filter) |filter| {
            try self.pushLayer(allocator, null, null, null, null, filter.clone());
            errdefer self.popLayer();
            try self.fillRectInner(allocator, rect);
            self.popLayer();
        } else {
            try self.fillRectInner(allocator, rect);
        }
    }

    fn fillRectInner(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
    ) !void {
        const encoded_paint = try self.encodeCurrentPaint();
        const path_transform = self.root_transforms.effectivePathTransform(self.state.transforms);

        // Fast path: an axis-aligned transform with anti-aliasing enabled can
        // be rasterized as a pixel-aligned rectangle.
        if (common_util.isAxisAligned(path_transform) and self.aliasing_threshold == null) {
            const transformed_rect = path_transform.transformRectBbox(rect);
            try self.dispatcher.fillRectFast(
                allocator,
                &transformed_rect,
                encoded_paint,
                self.state.blend_mode,
                self.currentMask(),
            );
            return;
        }

        // Fall back to path-based rendering for rotated/skewed transforms or
        // aliasing thresholds.
        try self.rectToTempPath(allocator, rect);
        try self.dispatcher.fillPath(
            allocator,
            self.temp_path.items,
            self.state.fill_rule,
            path_transform,
            encoded_paint,
            self.state.blend_mode,
            self.aliasing_threshold,
            self.currentMask(),
        );
    }

    /// Stroke a rectangle.
    pub fn strokeRect(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
    ) !void {
        if (self.filter) |filter| {
            try self.pushLayer(allocator, null, null, null, null, filter.clone());
            errdefer self.popLayer();
            try self.strokeRectInner(allocator, rect);
            self.popLayer();
        } else {
            try self.strokeRectInner(allocator, rect);
        }
    }

    fn strokeRectInner(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
    ) !void {
        try self.rectToTempPath(allocator, rect);
        const encoded_paint = try self.encodeCurrentPaint();
        const path_transform = self.root_transforms.effectivePathTransform(self.state.transforms);
        try self.dispatcher.strokePath(
            allocator,
            self.temp_path.items,
            &self.state.stroke,
            path_transform,
            encoded_paint,
            self.state.blend_mode,
            self.aliasing_threshold,
            self.currentMask(),
        );
    }

    /// Fill a blurred rounded rectangle (upstream `fill_blurred_rounded_rect`).
    ///
    /// When `invert` is `true`, the inverse (`1 - alpha`) of the blur coverage
    /// is painted: the paint is fully opaque outside the blurred rectangle and
    /// fades to transparent inside it (inset box shadows). Only a solid paint
    /// is used; image/gradient paints fall back to black, like upstream.
    pub fn fillBlurredRoundedRect(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        rect: kurbo.Rect,
        radius: f32,
        std_dev: f32,
        invert: bool,
    ) !void {
        const abs_rect = rect.abs();
        const color = switch (self.state.paint) {
            .solid => |solid| solid,
            // Fallback to black when attempting to blur a rectangle with an
            // image/gradient paint.
            else => peniko.Color.BLACK,
        };

        const blurred_rect = blurred_rounded_rect_mod.BlurredRoundedRectangle{
            .rect = abs_rect,
            .color = color,
            .radius = radius,
            .std_dev = std_dev,
            .invert = invert,
        };

        // The impulse response of a Gaussian filter is infinite; for
        // performance, cut it off at 2.5 sigma.
        const kernel_size: f64 = 2.5 * @as(f64, std_dev);
        const inflated_rect = abs_rect.inflate(kernel_size, kernel_size);
        const path_transform = self.root_transforms.effectivePathTransform(self.state.transforms);
        const paint_transform = self.root_transforms.effectivePaintTransform(self.state.transforms);

        try self.rectToTempPath(allocator, inflated_rect);

        const encoded_paint = try encode_mod.encodeBlurredRoundedRectangle(
            &blurred_rect,
            self.allocator,
            &self.encoded_paints,
            paint_transform,
            null,
        );
        try self.dispatcher.fillPath(
            allocator,
            self.temp_path.items,
            .non_zero,
            path_transform,
            encoded_paint,
            self.state.blend_mode,
            self.aliasing_threshold,
            self.currentMask(),
        );
    }

    // --------------------------------------------------------------- mask

    /// Borrow the current path-level mask for a draw call.
    fn currentMask(self: *RenderContext) ?*const Mask {
        return if (self.mask) |*m| m else null;
    }

    /// Set the mask applied to all subsequent draws (upstream `set_mask`).
    /// The context takes ownership of `mask`.
    pub fn setMask(self: *RenderContext, mask: Mask) void {
        if (self.mask) |old| old.deinit(self.allocator);
        self.mask = mask;
    }

    /// Remove the current path-level mask (upstream `reset_mask`).
    pub fn resetMask(self: *RenderContext) void {
        if (self.mask) |old| old.deinit(self.allocator);
        self.mask = null;
    }

    /// Push an isolated layer masked by `mask` (upstream `push_mask_layer`).
    pub fn pushMaskLayer(self: *RenderContext, allocator: std.mem.Allocator, mask: Mask) !void {
        try self.pushLayer(allocator, null, null, null, mask, null);
    }

    // ------------------------------------------------------------ layers

    /// Push a new layer with the given properties.
    ///
    /// `mask`, when provided, must have the same dimensions as the render
    /// context; otherwise it is ignored (and released), matching upstream.
    /// `mask` and `filter` are consumed: on success ownership transfers to the
    /// recorder, on failure both are released here, so do not release them
    /// again. A non-null `filter` pushes a filter layer, which shifts the
    /// recorded contents by the filter's source shift and stores a
    /// `FilterData` for later rasterization.
    pub fn pushLayer(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        clip_path: ?[]const kurbo.PathEl,
        blend_mode: ?peniko.BlendMode,
        opacity: ?f32,
        mask: ?Mask,
        filter: ?Filter,
    ) !void {
        const blend = blend_mode orelse peniko.BlendMode.default;
        const alpha = std.math.clamp(opacity orelse 1.0, 0.0, 1.0);
        const layer_transform = self.root_transforms.effectivePathTransform(self.state.transforms);

        // `FilterData::new` takes ownership of the filter handle.
        var pending_filter = filter;
        errdefer if (pending_filter) |f| f.deinit(allocator);
        var filter_data: ?filter_data_mod.FilterData = null;
        if (pending_filter) |f| {
            pending_filter = null;
            filter_data = filter_data_mod.FilterData.new(f, layer_transform);
        }
        errdefer if (filter_data) |*data| data.deinit(allocator);

        // The relative root transform is identity except for filter layers:
        // their contents are shifted by the source shift so that negative
        // scene coordinates do not need to be rendered, and
        // `FilterLayerPlacement` undoes the shift when the layer is
        // composited back into the parent.
        const relative_transform: kurbo.Affine = if (filter_data) |data| blk: {
            const shift = data.sourceShift();
            break :blk kurbo.Affine.translate(kurbo.Vec2.new(
                @floatFromInt(shift[0]),
                @floatFromInt(shift[1]),
            ));
        } else kurbo.Affine.IDENTITY;

        self.root_transforms.pushRoot(allocator, relative_transform) catch |err| {
            // The caller transferred `mask` into this call; release it.
            if (mask) |m| m.deinit(allocator);
            return err;
        };
        errdefer self.root_transforms.popRoot();

        var effective_mask: ?Mask = null;
        if (mask) |m| {
            if (m.width() == self.scene_width and m.height() == self.scene_height) {
                effective_mask = m;
            } else {
                // Upstream silently drops mismatched masks; release ours so it
                // is not leaked.
                m.deinit(allocator);
            }
        }

        // The dispatcher takes ownership of `filter_data` on success; it
        // releases it (together with `effective_mask`) on failure.
        const filter_arg = filter_data;
        filter_data = null;
        try self.dispatcher.pushLayer(
            allocator,
            clip_path,
            self.state.fill_rule,
            layer_transform,
            blend,
            alpha,
            self.aliasing_threshold,
            effective_mask,
            filter_arg,
        );
    }

    /// Push a new clip layer.
    ///
    /// See the upstream `clipping` example for how this differs from
    /// `pushClipPath`: a clip layer clips everything drawn until `popLayer`,
    /// while `pushClipPath` affects all subsequent draws until `popClipPath`.
    pub fn pushClipLayer(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        try self.pushLayer(allocator, path, null, null, null, null);
    }

    /// Push a new blend layer.
    pub fn pushBlendLayer(self: *RenderContext, blend_mode: peniko.BlendMode) !void {
        try self.pushLayer(self.allocator, null, blend_mode, null, null, null);
    }

    /// Push a new opacity layer.
    pub fn pushOpacityLayer(self: *RenderContext, opacity: f32) !void {
        try self.pushLayer(self.allocator, null, null, opacity, null, null);
    }

    /// Pop the last-pushed layer.
    ///
    /// Underflow is a programming error (upstream panics); it is asserted in
    /// debug builds only because the upstream signature is infallible.
    pub fn popLayer(self: *RenderContext) void {
        self.dispatcher.popLayer(self.allocator) catch |err| {
            std.debug.assert(err == error.NoActiveLayer);
        };
        self.root_transforms.popRoot();
    }

    // -------------------------------------------------------------- clips

    /// Push a new clip path to the clip stack.
    ///
    /// Unlike `pushClipLayer`, pending pushed clip paths may remain open when
    /// the render finishes.
    pub fn pushClipPath(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        // Upstream uses `clip_path_transform`, which intentionally does not
        // apply root transforms (clipping handles viewport shifts separately).
        const clip_transform = self.state.transforms.clipPathTransform();
        try self.dispatcher.pushClipPath(
            allocator,
            path,
            self.state.fill_rule,
            clip_transform,
            self.aliasing_threshold,
        );
    }

    /// Pop a clip path from the clip stack.
    ///
    /// Underflow and allocation failure are programming/allocation errors
    /// (upstream panics); they are asserted in debug builds because the
    /// upstream signature is infallible.
    pub fn popClipPath(self: *RenderContext) void {
        self.dispatcher.popClipPath(self.allocator) catch |err| {
            std.debug.assert(err == error.OutOfMemory or err == error.ClipStackUnderflow);
        };
    }

    // ------------------------------------------------------------ render

    /// Flush any pending operations.
    ///
    /// A no-op for the single-threaded dispatcher. For multi-threaded
    /// rendering this blocks until all recorded commands are generated and
    /// must be called before `renderWith`; it is fallible because upstream
    /// aborts on allocation failure while this port returns `error.OutOfMemory`.
    pub fn flush(self: *RenderContext) !void {
        try self.dispatcher.flush(self.allocator);
    }

    /// Render the current context into a target using default rasterizer
    /// settings.
    ///
    /// Note: the default rasterizer mode is `optimize_speed`, which selects
    /// the u8 pipeline (upstream parity). Pass
    /// `RasterizerSettings{ .render_mode = .optimize_quality }` to
    /// `renderWith` for the f32 pipeline; the two pipelines are not
    /// byte-equal in general (see `tests/README.md`).
    pub fn render(
        self: *RenderContext,
        pixmap: *Pixmap,
        resources: *Resources,
    ) !void {
        try self.renderWith(pixmap, resources, RasterizerSettings.default);
    }

    /// Render the current context into a target using custom rasterizer
    /// settings.
    ///
    /// `RasterizerSettings.offset` positions the scene origin inside the
    /// pixmap; content outside the scene rect (`0..width`, `0..height`) is
    /// clipped away. With `TargetInit.clear`, the whole pixmap (including
    /// padding outside the scene rect) is cleared, exactly like upstream.
    pub fn renderWith(
        self: *RenderContext,
        pixmap: *Pixmap,
        resources: *Resources,
        settings: RasterizerSettings,
    ) !void {
        // Upstream asserts `!dispatcher.has_layers()`; unclosed layers are
        // reported as a typed error here.
        if (self.dispatcher.hasLayers()) return error.UnclosedLayers;

        var target = pixmap.asMut();
        const target_fully_covered = settings.offset.x == 0 and
            settings.offset.y == 0 and
            self.scene_width >= target.width and
            self.scene_height >= target.height;

        switch (settings.target_init) {
            .clear => |color| {
                const premul = PremulColor.fromAlphaColor(color);
                // If the scene covers the whole pixmap, packing clears
                // everything anyway; otherwise the whole target (including
                // padding) is cleared up front.
                if (!target_fully_covered) {
                    fillTarget(&target, premul);
                }
                target.setMayHaveTransparency(!premul.isOpaque());
            },
            // Whatever the current transparency hint is can be preserved.
            .src_over => {},
        }

        try self.dispatcher.rasterize(
            self.allocator,
            &target,
            self.scene_width,
            self.scene_height,
            settings,
            self.encoded_paints.items,
            resources.imageResolver(),
        );
    }
};

/// Fill the whole target with a premultiplied color.
fn fillTarget(target: *PixmapMut, color: PremulColor) void {
    const pixel = color.asPremulRgba8();
    const bytes = [4]u8{ pixel.r, pixel.g, pixel.b, pixel.a };
    const data = target.dataMut();
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        @memcpy(data[i..][0..4], &bytes);
    }
}

// ---------------------------------------------------------------------------
// Tests (end-to-end M1 gate path plus ports of the upstream render.rs tests)
// ---------------------------------------------------------------------------

const testing = std.testing;
const palette = peniko.palette.css;

const GRAY = peniko.PremulRgba8{ .r = 9, .g = 10, .b = 11, .a = 255 };

fn premulU8(color: peniko.Color) peniko.PremulRgba8 {
    return color.premultiply().toRgba8();
}

fn transparentPixel() peniko.PremulRgba8 {
    return peniko.PremulRgba8.fromU32(0);
}

/// Quality-mode settings for tests that pin f32 bytes (the corpus gate also
/// runs in this mode).
fn qualitySettings() RasterizerSettings {
    return .{
        .render_mode = .optimize_quality,
        .target_init = .{ .clear = peniko.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    };
}

fn solidPixmap(width: u16, height: u16, color: peniko.PremulRgba8) !Pixmap {
    var pixmap = try Pixmap.init(testing.allocator, width, height);
    for (pixmap.dataMut()) |*pixel| pixel.* = color;
    return pixmap;
}

fn expectPixel(pixmap: *const Pixmap, x: u16, y: u16, expected: peniko.PremulRgba8) !void {
    const actual = pixmap.sample(x, y);
    if (!std.meta.eql(actual, expected)) {
        std.debug.print(
            "pixel ({d}, {d}): expected {any}, got {any}\n",
            .{ x, y, expected, actual },
        );
        return error.TestUnexpectedResult;
    }
}

fn rectElements(rect: kurbo.Rect) [5]kurbo.PathEl {
    return .{
        .{ .MoveTo = kurbo.Point.new(rect.x0, rect.y0) },
        .{ .LineTo = kurbo.Point.new(rect.x1, rect.y0) },
        .{ .LineTo = kurbo.Point.new(rect.x1, rect.y1) },
        .{ .LineTo = kurbo.Point.new(rect.x0, rect.y1) },
        .ClosePath,
    };
}

test "doc example: magenta rect on 10x5 context" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 10, 5, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 10, 5);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.MAGENTA);
    try ctx.fillRect(allocator, kurbo.Rect.new(3.0, 1.0, 7.0, 4.0));
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    const magenta = premulU8(palette.MAGENTA);
    const transparent = transparentPixel();
    for (0..5) |y| {
        for (0..10) |x| {
            const inside = x >= 3 and x < 7 and y >= 1 and y < 4;
            try expectPixel(&pixmap, @intCast(x), @intCast(y), if (inside) magenta else transparent);
        }
    }
}

test "overlapping translucent rects composite in premultiplied space" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 2, 1);
    defer pixmap.deinit(allocator);

    const rect = kurbo.Rect.new(0.0, 0.0, 2.0, 1.0);
    ctx.setPaint(palette.RED.withAlpha(0.5));
    try ctx.fillRect(allocator, rect);
    ctx.setPaint(palette.BLUE.withAlpha(0.5));
    try ctx.fillRect(allocator, rect);
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // red 0.5 then blue 0.5:
    //   r = 0    + 0.5*0.5 = 0.25 -> 64
    //   b = 0.5  + 0   *0.5 = 0.5  -> 128
    //   a = 0.5  + 0.5 *0.5 = 0.75 -> 191
    const expected = peniko.PremulRgba8{ .r = 64, .g = 0, .b = 128, .a = 191 };
    try expectPixel(&pixmap, 0, 0, expected);
    try expectPixel(&pixmap, 1, 0, expected);
}

test "nested clip paths intersect" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    const outer = rectElements(kurbo.Rect.new(0.0, 0.0, 3.0, 3.0));
    const inner = rectElements(kurbo.Rect.new(2.0, 2.0, 4.0, 4.0));
    try ctx.pushClipPath(allocator, &outer);
    try ctx.pushClipPath(allocator, &inner);
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 4.0, 4.0));
    ctx.popClipPath();
    ctx.popClipPath();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The intersection is the single pixel (2, 2).
    const red = premulU8(palette.RED);
    const transparent = transparentPixel();
    for (0..4) |y| {
        for (0..4) |x| {
            const inside = x == 2 and y == 2;
            try expectPixel(&pixmap, @intCast(x), @intCast(y), if (inside) red else transparent);
        }
    }
}

test "clip layer composites only inside the clip" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    const clip = rectElements(kurbo.Rect.new(1.0, 1.0, 3.0, 3.0));
    try ctx.pushClipLayer(allocator, &clip);
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 4.0, 4.0));
    ctx.popLayer();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    const red = premulU8(palette.RED);
    const transparent = transparentPixel();
    for (0..4) |y| {
        for (0..4) |x| {
            const inside = x >= 1 and x < 3 and y >= 1 and y < 3;
            try expectPixel(&pixmap, @intCast(x), @intCast(y), if (inside) red else transparent);
        }
    }
}

test "opacity layer scales coverage" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 1, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 1, 1);
    defer pixmap.deinit(allocator);

    try ctx.pushOpacityLayer(0.5);
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 1.0, 1.0));
    ctx.popLayer();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The opaque red is scaled by 0.5 as a whole layer, then composited over
    // transparent black: (128, 0, 0, 128).
    try expectPixel(&pixmap, 0, 0, .{ .r = 128, .g = 0, .b = 0, .a = 128 });
}

test "blend layer multiplies against the isolated scene" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 1, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try solidPixmap(1, 1, premulU8(palette.BLUE));
    defer pixmap.deinit(allocator);

    // Root content: opaque green. Then a multiply layer with opaque red.
    ctx.setPaint(peniko.Color.fromRgb8(0, 255, 0));
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 1.0, 1.0));
    try ctx.pushBlendLayer(peniko.BlendMode.from(peniko.Mix.multiply));
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 1.0, 1.0));
    ctx.popLayer();
    try ctx.flush();

    var settings = qualitySettings();
    settings.target_init = .src_over;
    try ctx.renderWith(&pixmap, &resources, settings);

    // red * green = black; the backdrop is isolated, so the multiply never
    // touches the existing blue target.
    try expectPixel(&pixmap, 0, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "path-level mask is applied to draws and cleared by resetMask" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 2, 1);
    defer pixmap.deinit(allocator);

    ctx.setMask(try Mask.fromParts(allocator, &.{ 0, 255 }, 2, 1));
    defer ctx.resetMask();
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 1.0));
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The mask zeroes the left pixel and leaves the right one opaque.
    try expectPixel(&pixmap, 0, 0, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try expectPixel(&pixmap, 1, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });

    // `resetMask` drops the mask for subsequent draws on a fresh target.
    ctx.resetMask();
    var pixmap2 = try Pixmap.init(allocator, 2, 1);
    defer pixmap2.deinit(allocator);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 1.0));
    try ctx.flush();
    try ctx.renderWith(&pixmap2, &resources, qualitySettings());
    try expectPixel(&pixmap2, 0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
}

test "layer mask is sampled per row" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 2, 1);
    defer pixmap.deinit(allocator);

    // The mask is owned by the recorder after a successful `pushLayer`.
    const mask = try Mask.fromParts(allocator, &.{ 0, 255 }, 2, 1);
    try ctx.pushLayer(allocator, null, null, null, mask, null);
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 1.0));
    ctx.popLayer();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    try expectPixel(&pixmap, 0, 0, transparentPixel());
    try expectPixel(&pixmap, 1, 0, premulU8(palette.RED));
}

test "degenerate zero-area rect draws nothing" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(1.0, 1.0, 1.0, 3.0));
    try ctx.fillRect(allocator, kurbo.Rect.new(1.0, 1.0, 3.0, 1.0));
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    for (0..4) |y| {
        for (0..4) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), transparentPixel());
        }
    }
}

test "empty scene leaves a cleared target" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 3, 2, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 3, 2);
    defer pixmap.deinit(allocator);

    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    for (0..2) |y| {
        for (0..3) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), transparentPixel());
        }
    }
}

test "empty scene composited over an existing target with src over" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 2, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try solidPixmap(2, 2, GRAY);
    defer pixmap.deinit(allocator);

    var settings = qualitySettings();
    settings.target_init = .src_over;
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, settings);

    for (0..2) |y| {
        for (0..2) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), GRAY);
        }
    }
}

test "render with offset clears pixels outside the scene" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 2, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try solidPixmap(4, 3, GRAY);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0));
    try ctx.flush();

    var settings = qualitySettings();
    settings.offset = .{ .x = 1, .y = 1 };
    try ctx.renderWith(&pixmap, &resources, settings);

    const red = premulU8(palette.RED);
    const transparent = transparentPixel();
    for (0..3) |y| {
        for (0..4) |x| {
            const inside = x >= 1 and x <= 2 and y >= 1 and y <= 2;
            try expectPixel(&pixmap, @intCast(x), @intCast(y), if (inside) red else transparent);
        }
    }
}

test "render preserves target under translucent draw with src over" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 1, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try solidPixmap(1, 1, premulU8(palette.BLUE));
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED.withAlpha(0.5));
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 1.0, 1.0));
    try ctx.flush();

    var settings = qualitySettings();
    settings.target_init = .src_over;
    try ctx.renderWith(&pixmap, &resources, settings);

    // 50% opaque red over opaque blue with f32 blending:
    //   r = 0.5 + 0*0.5 = 0.5 -> 128
    //   b = 0   + 1*0.5 = 0.5 -> 128
    //   a = 0.5 + 1*0.5 = 1.0 -> 255
    try expectPixel(&pixmap, 0, 0, .{ .r = 128, .g = 0, .b = 128, .a = 255 });
}

test "opaque clear updates the transparency hint" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 1, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 1, 1);
    defer pixmap.deinit(allocator);

    try ctx.flush();
    var settings = qualitySettings();
    settings.target_init = .{ .clear = palette.BLUE };
    try ctx.renderWith(&pixmap, &resources, settings);

    try testing.expect(!pixmap.mayHaveTransparency());
    try expectPixel(&pixmap, 0, 0, premulU8(palette.BLUE));
}

test "translucent clear updates the transparency hint" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 1, 1, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try solidPixmap(1, 1, premulU8(palette.BLUE));
    defer pixmap.deinit(allocator);

    const clear_color = palette.RED.withAlpha(0.5);
    try ctx.flush();
    var settings = qualitySettings();
    settings.target_init = .{ .clear = clear_color };
    try ctx.renderWith(&pixmap, &resources, settings);

    try testing.expect(pixmap.mayHaveTransparency());
    try expectPixel(&pixmap, 0, 0, premulU8(clear_color));
}

test "render fails with unclosed layers" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 2, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);

    try ctx.pushOpacityLayer(0.5);
    try testing.expectError(
        error.UnclosedLayers,
        ctx.renderWith(&pixmap, &resources, qualitySettings()),
    );
    ctx.popLayer();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
}

test "default render mode uses the u8 pipeline and matches f32 on opaque fills" {
    const allocator = testing.allocator;

    const renderMode = struct {
        fn call(
            mode: RenderMode,
            allocator_: std.mem.Allocator,
            pixmap: *Pixmap,
            resources: *Resources,
        ) !void {
            var ctx = try RenderContext.init(allocator_, 4, 4, RenderSettings.default);
            defer ctx.deinit(allocator_);

            ctx.setPaint(palette.RED);
            try ctx.fillRect(allocator_, kurbo.Rect.new(0.0, 0.0, 4.0, 4.0));
            try ctx.flush();
            if (mode == .optimize_speed) {
                // `render` uses `RasterizerSettings.default`.
                try ctx.render(pixmap, resources);
            } else {
                try ctx.renderWith(pixmap, resources, qualitySettings());
            }
        }
    }.call;

    var resources = Resources.init();
    defer resources.deinit(allocator);

    var speed_pixmap = try Pixmap.init(allocator, 4, 4);
    defer speed_pixmap.deinit(allocator);
    var quality_pixmap = try Pixmap.init(allocator, 4, 4);
    defer quality_pixmap.deinit(allocator);

    try renderMode(.optimize_speed, allocator, &speed_pixmap, &resources);
    try renderMode(.optimize_quality, allocator, &quality_pixmap, &resources);

    // Opaque fills are exact in both pipelines.
    try testing.expectEqualSlices(
        u8,
        quality_pixmap.dataAsU8Slice(),
        speed_pixmap.dataAsU8Slice(),
    );
    try expectPixel(&speed_pixmap, 0, 0, premulU8(palette.RED));
}

test "reset keeps aliasing threshold and filter state" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 2, 2, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);

    ctx.setAliasingThreshold(128);
    ctx.setFilterEffect(try filter_effects.Filter.fromPrimitive(allocator, .{
        .flood = .{ .color = peniko.palette.css.RED },
    }));

    ctx.reset();
    try testing.expectEqual(@as(?u8, 128), ctx.aliasingThreshold());
    try testing.expect(ctx.filter != null);

    // The filter survives the reset (upstream behavior) and wraps subsequent
    // draws in filter layers: the flood filter replaces the layer contents
    // with red before compositing.
    ctx.setPaint(palette.BLUE);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0));
    ctx.resetFilterEffect();
    try testing.expect(ctx.filter == null);

    // The recorded scene is cleared, so the context is reusable.
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    try expectPixel(&pixmap, 0, 0, premulU8(palette.RED));
}

// ---------------------------------------------------------------------------
// Filter end-to-end tests
// ---------------------------------------------------------------------------

test "set filter effect wraps a draw in a flood filter layer" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.BLUE);
    ctx.setFilterEffect(try filter_effects.Filter.fromPrimitive(allocator, .{
        .flood = .{ .color = peniko.palette.css.GREEN },
    }));
    try ctx.fillRect(allocator, kurbo.Rect.new(1.0, 1.0, 3.0, 3.0));
    ctx.resetFilterEffect();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // Filter layers are tile-aligned: the drawn rect's strips span the whole
    // 4x4 tile, so the flood-filled pixmap covers the full layer area.
    const green = premulU8(palette.GREEN);
    for (0..4) |y| {
        for (0..4) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), green);
        }
    }
}

test "set filter effect wraps a draw in an offset filter layer" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    ctx.setFilterEffect(try filter_effects.Filter.fromPrimitive(allocator, .{
        .offset = .{ .dx = 1.0, .dy = 1.0 },
    }));
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0));
    ctx.resetFilterEffect();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The red square moved from (0,0)-(2,2) to (1,1)-(3,3).
    const red = premulU8(palette.RED);
    const transparent = transparentPixel();
    for (0..4) |y| {
        for (0..4) |x| {
            const inside = x >= 1 and x < 3 and y >= 1 and y < 3;
            try expectPixel(&pixmap, @intCast(x), @intCast(y), if (inside) red else transparent);
        }
    }
}

test "gaussian blur filter spreads an opaque rect" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 16, 16, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 16, 16);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    ctx.setFilterEffect(try filter_effects.Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 2.0, .edge_mode = .duplicate },
    }));
    try ctx.fillRect(allocator, kurbo.Rect.new(4.0, 4.0, 12.0, 12.0));
    ctx.resetFilterEffect();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // Center retains full coverage, edges are partially covered, and the
    // blur bleeds outside the source rectangle.
    try testing.expect(pixmap.sample(8, 8).a > 200);
    try testing.expect(pixmap.sample(8, 3).a > 0);
    try testing.expect(pixmap.sample(8, 0).a < pixmap.sample(8, 3).a);
    try testing.expect(pixmap.sample(0, 0).a < pixmap.sample(8, 3).a);
}

test "drop shadow filter composites the shadow and original" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 8, 8, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 8, 8);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    ctx.setFilterEffect(try filter_effects.Filter.fromPrimitive(allocator, .{
        .drop_shadow = .{
            .dx = 2.0,
            .dy = 2.0,
            .std_deviation = 0.0,
            .color = peniko.palette.css.BLUE,
            .edge_mode = .none,
        },
    }));
    try ctx.fillRect(allocator, kurbo.Rect.new(1.0, 1.0, 3.0, 3.0));
    ctx.resetFilterEffect();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The original red is composited over the blue shadow at its position...
    try expectPixel(&pixmap, 1, 1, premulU8(palette.RED));
    // ...and the shadow shows through at the offset position.
    try expectPixel(&pixmap, 3, 3, premulU8(palette.BLUE));
    try expectPixel(&pixmap, 0, 0, transparentPixel());
}

test "push layer accepts a filter with opacity and clip" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 8, 8, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 8, 8);
    defer pixmap.deinit(allocator);

    const filter = try filter_effects.Filter.fromPrimitive(allocator, .{
        .flood = .{ .color = peniko.palette.css.GREEN },
    });
    const clip = rectElements(kurbo.Rect.new(0.0, 0.0, 4.0, 8.0));
    try ctx.pushLayer(allocator, &clip, null, 0.5, null, filter);
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 8.0, 8.0));
    ctx.popLayer();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The flood filter fills the layer with the CSS `green` flood color
    // (#008000), the clip keeps the left half, and the 0.5 opacity scales the
    // composited result.
    const expected = peniko.PremulRgba8{ .r = 0, .g = 64, .b = 0, .a = 128 };
    try expectPixel(&pixmap, 1, 1, expected);
    try expectPixel(&pixmap, 6, 1, transparentPixel());
}

test "multi primitive filter graphs fail with a typed error" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    const filter = try filter_effects.Filter.fromPrimitive(allocator, .{
        .flood = .{ .color = peniko.palette.css.RED },
    });
    defer filter.deinit(allocator);
    _ = try filter.graph.get().add(allocator, .{
        .gaussian_blur = .{ .std_deviation = 1.0, .edge_mode = .none },
    }, null);

    ctx.setPaint(palette.BLUE);
    ctx.setFilterEffect(filter.clone());
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 4.0, 4.0));
    ctx.resetFilterEffect();
    try ctx.flush();
    try testing.expectError(
        error.Unsupported,
        ctx.renderWith(&pixmap, &resources, qualitySettings()),
    );
}

test "reset and resize update the scene size" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 8, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 8);
    defer pixmap.deinit(allocator);

    try ctx.resetAndResize(allocator, 4, 8);
    try testing.expectEqual(@as(u16, 4), ctx.width());
    try testing.expectEqual(@as(u16, 8), ctx.height());

    ctx.setPaint(palette.BLUE);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 4.0, 8.0));
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    for (0..8) |y| {
        for (0..4) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), premulU8(palette.BLUE));
        }
    }
}

test "path fill and stroke render through the recorded pipeline" {
    const allocator = testing.allocator;
    var ctx = try RenderContext.init(allocator, 4, 4, RenderSettings.default);
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);

    const rect = rectElements(kurbo.Rect.new(0.0, 0.0, 4.0, 4.0));
    ctx.setPaint(palette.RED);
    try ctx.fillPath(allocator, &rect);
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    for (0..4) |y| {
        for (0..4) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), premulU8(palette.RED));
        }
    }
}

test "gradient and image paints render through the indexed path" {
    const allocator = testing.allocator;

    // Gradient: two identical opaque stops make the result constant no matter
    // the sampled t values, so this exercises encode -> fine painting without
    // duplicating the gradient math.
    {
        var ctx = try RenderContext.init(allocator, 2, 2, RenderSettings.default);
        defer ctx.deinit(allocator);
        var resources = Resources.init();
        defer resources.deinit(allocator);
        var pixmap = try Pixmap.init(allocator, 2, 2);
        defer pixmap.deinit(allocator);

        const stops = [_]peniko.ColorStop{
            .{ .offset = 0.0, .color = palette.RED },
            .{ .offset = 1.0, .color = palette.RED },
        };
        var gradient = peniko.Gradient{};
        gradient.stops = try peniko.ColorStops.fromSlice(allocator, &stops);
        // Ownership moves into the context and is released by `deinit`.
        ctx.setPaint(PaintType.fromGradient(gradient));
        try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0));
        try ctx.flush();
        try ctx.renderWith(&pixmap, &resources, qualitySettings());

        for (0..2) |y| {
            for (0..2) |x| {
                try expectPixel(&pixmap, @intCast(x), @intCast(y), premulU8(palette.RED));
            }
        }
    }

    // Image: a 1x1 opaque red pixmap registered through `Resources` and
    // referenced by opaque id (resolved at rasterization time).
    {
        var ctx = try RenderContext.init(allocator, 2, 2, RenderSettings.default);
        defer ctx.deinit(allocator);
        var resources = Resources.init();
        defer resources.deinit(allocator);
        var pixmap = try Pixmap.init(allocator, 2, 2);
        defer pixmap.deinit(allocator);

        var image_pixmap = try Pixmap.init(allocator, 1, 1);
        image_pixmap.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
        // Ownership of the pixels moves into the shared handle (the same
        // convention as `Resources.registerImage`).
        const handle = try shared_mod.Shared(Pixmap).create(allocator, image_pixmap);
        const id = try resources.registerImage(allocator, handle);

        const image_paint = paint_mod.Image{
            .image = paint_mod.ImageSource.initOpaqueIdWithTransparencyHint(id, false),
            .sampler = .{},
        };
        ctx.setPaint(PaintType.fromImage(image_paint));
        try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0));
        try ctx.flush();
        try ctx.renderWith(&pixmap, &resources, qualitySettings());

        for (0..2) |y| {
            for (0..2) |x| {
                try expectPixel(&pixmap, @intCast(x), @intCast(y), premulU8(palette.RED));
            }
        }
    }
}

test "image registry round-trip, resolver view, exhaustion, and clear" {
    const allocator = testing.allocator;
    var resources = Resources.init();
    defer resources.deinit(allocator);

    var pixmap = try Pixmap.init(allocator, 1, 1);
    pixmap.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    const handle = try shared_mod.Shared(Pixmap).create(allocator, pixmap);

    const id = try resources.registerImage(allocator, handle);
    const resolved = resources.resolveImage(id) orelse return error.TestUnexpectedResult;
    defer resolved.release(allocator);
    try testing.expectEqual(@as(u8, 255), resolved.get().sample(0, 0).r);

    // The resolver view resolves through the same registry.
    var resolver = resources.imageResolver();
    const via_resolver = resolver.resolve(id) orelse return error.TestUnexpectedResult;
    defer via_resolver.release(allocator);
    try testing.expect(via_resolver.get() == resolved.get());

    // Destroy releases the registry's handle; the caller's retained handles
    // stay valid.
    try testing.expect(resources.destroyImage(allocator, id));
    try testing.expect(!resources.destroyImage(allocator, id));
    try testing.expect(resources.resolveImage(id) == null);
    try testing.expectEqual(@as(u8, 255), resolved.get().sample(0, 0).r);

    // Exhausted ids fail without consuming the caller's handle.
    resources.image_registry.next_id = ATLAS_IMAGE_ID_BASE;
    const pending = try shared_mod.Shared(Pixmap).create(allocator, try Pixmap.init(allocator, 1, 1));
    try testing.expectError(error.ImageIdExhausted, resources.registerImage(allocator, pending));
    pending.release(allocator);

    // clear() resets ids and releases outstanding registrations.
    resources.image_registry.next_id = 0;
    const second = try shared_mod.Shared(Pixmap).create(allocator, try Pixmap.init(allocator, 1, 1));
    const id2 = try resources.registerImage(allocator, second);
    try testing.expectEqual(@as(u32, 0), id2.asU32());
    resources.clearImages(allocator);
    try testing.expect(resources.resolveImage(id2) == null);
    const id3 = try resources.registerImage(
        allocator,
        try shared_mod.Shared(Pixmap).create(allocator, try Pixmap.init(allocator, 1, 1)),
    );
    try testing.expectEqual(@as(u32, 0), id3.asU32());
}

// ---------------------------------------------------------------------------
// M4: multi-threaded dispatch (upstream render.rs multithreading tests plus a
// single-vs-multi byte-exact differential)
// ---------------------------------------------------------------------------

const MT_SCENE_SIZE: u16 = 64;

fn mtSettings(num_threads: u16) RenderSettings {
    return .{ .level = .baseline, .num_threads = num_threads };
}

/// A pointer to the five-pointed-star path used by the differential scene
/// (self-intersecting under `NonZero`, so winding bookkeeping and per-column
/// alpha coverage are exercised in addition to plain fills).
fn starElements() [12]kurbo.PathEl {
    var elements: [12]kurbo.PathEl = undefined;
    const cx: f64 = 32.0;
    const cy: f64 = 32.0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const radius: f64 = if (i % 2 == 0) 26.0 else 11.0;
        const angle = -std.math.pi / 2.0 + @as(f64, @floatFromInt(i)) * std.math.pi / 5.0;
        const p = kurbo.Point.new(
            cx + radius * @cos(angle),
            cy + radius * @sin(angle),
        );
        elements[i] = if (i == 0) .{ .MoveTo = p } else .{ .LineTo = p };
    }
    elements[10] = .{ .LineTo = elements[0].MoveTo };
    elements[11] = .ClosePath;
    return elements;
}

/// Record the differential test scene: gradient background, registered image,
/// translucent overlap, opacity and multiply layers, a path-level mask, a clip
/// path and a self-intersecting star fill. Every paint kind and task kind the
/// dispatcher supports is represented.
fn buildDifferentialScene(
    ctx: *RenderContext,
    allocator: std.mem.Allocator,
    resources: *Resources,
) !void {
    const size_f: f64 = @floatFromInt(MT_SCENE_SIZE);

    // Linear gradient over the whole scene (three stops).
    const stops = [_]peniko.ColorStop{
        .{ .offset = 0.0, .color = palette.BLUE },
        .{ .offset = 0.35, .color = palette.RED },
        .{ .offset = 1.0, .color = peniko.Color.fromRgba8(0, 255, 128, 200) },
    };
    var gradient = peniko.Gradient{};
    gradient.stops = try peniko.ColorStops.fromSlice(allocator, &stops);
    ctx.setPaint(PaintType.fromGradient(gradient));
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, size_f, size_f));

    // Registered image paint.
    var image_pixmap = try Pixmap.init(allocator, 2, 2);
    image_pixmap.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    image_pixmap.setPixel(1, 0, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    image_pixmap.setPixel(0, 1, .{ .r = 0, .g = 0, .b = 255, .a = 255 });
    image_pixmap.setPixel(1, 1, .{ .r = 255, .g = 255, .b = 0, .a = 128 });
    const handle = try shared_mod.Shared(Pixmap).create(allocator, image_pixmap);
    const image_id = try resources.registerImage(allocator, handle);
    ctx.setPaint(PaintType.fromImage(paint_mod.Image{
        .image = paint_mod.ImageSource.initOpaqueIdWithTransparencyHint(image_id, true),
        .sampler = .{ .quality = .high },
    }));
    try ctx.fillRect(allocator, kurbo.Rect.new(4.0, 4.0, 30.0, 30.0));

    // Overlapping translucent solid fills.
    ctx.setPaint(palette.GREEN.withAlpha(0.5));
    try ctx.fillRect(allocator, kurbo.Rect.new(10.5, 10.5, 40.25, 40.25));
    ctx.setPaint(palette.MAGENTA.withAlpha(0.4));
    try ctx.fillRect(allocator, kurbo.Rect.new(24.75, 6.5, 56.0, 38.0));

    // Opacity layer.
    try ctx.pushOpacityLayer(0.6);
    ctx.setPaint(palette.YELLOW);
    try ctx.fillRect(allocator, kurbo.Rect.new(2.5, 44.25, 30.0, 60.75));
    ctx.popLayer();

    // Multiply blend layer.
    try ctx.pushBlendLayer(peniko.BlendMode.from(peniko.Mix.multiply));
    ctx.setPaint(peniko.Color.fromRgb8(120, 200, 255));
    try ctx.fillRect(allocator, kurbo.Rect.new(30.25, 30.25, 62.0, 62.0));
    ctx.popLayer();

    // Path-level mask on one draw (same size as the context).
    const mask_data = try allocator.alloc(u8, @as(usize, MT_SCENE_SIZE) * MT_SCENE_SIZE);
    defer allocator.free(mask_data);
    for (mask_data, 0..) |*value, index| {
        value.* = @truncate((index * 37) & 0xff);
    }
    ctx.setMask(try Mask.fromParts(allocator, mask_data, MT_SCENE_SIZE, MT_SCENE_SIZE));
    const star = starElements();
    ctx.setPaint(palette.WHITE.withAlpha(0.75));
    try ctx.fillPath(allocator, &star);
    ctx.resetMask();

    // Clip path + a round-capped stroke inside it.
    const clip = rectElements(kurbo.Rect.new(3.0, 3.0, 61.0, 33.0));
    try ctx.pushClipPath(allocator, &clip);
    var stroke = kurbo.Stroke.new(3.5);
    stroke = stroke.withCaps(.round);
    ctx.setStroke(stroke);
    const line = [_]kurbo.PathEl{
        .{ .MoveTo = kurbo.Point.new(6.0, 18.0) },
        .{ .LineTo = kurbo.Point.new(58.0, 18.0) },
    };
    ctx.setPaint(palette.BLACK);
    try ctx.strokePath(allocator, &line);
    ctx.popClipPath();
}

/// Render `buildDifferentialScene` with the requested thread count.
fn renderDifferentialScene(
    allocator: std.mem.Allocator,
    num_threads: u16,
) !Pixmap {
    var ctx = try RenderContext.init(
        allocator,
        MT_SCENE_SIZE,
        MT_SCENE_SIZE,
        mtSettings(num_threads),
    );
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, MT_SCENE_SIZE, MT_SCENE_SIZE);
    errdefer pixmap.deinit(allocator);

    try buildDifferentialScene(&ctx, allocator, &resources);
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    return pixmap;
}

test "multi-threaded f32 output matches single-threaded byte for byte" {
    const allocator = testing.allocator;

    var reference = try renderDifferentialScene(allocator, 0);
    defer reference.deinit(allocator);

    var threads: u16 = 1;
    while (threads <= 4) : (threads += 1) {
        var actual = try renderDifferentialScene(allocator, threads);
        defer actual.deinit(allocator);
        try testing.expectEqualSlices(
            u8,
            reference.dataAsU8Slice(),
            actual.dataAsU8Slice(),
        );
    }
}

test "multi-threaded dispatch reports is_multi_threaded" {
    const allocator = testing.allocator;

    {
        var ctx = try RenderContext.init(allocator, 8, 8, mtSettings(2));
        defer ctx.deinit(allocator);
        try testing.expect(ctx.isMultiThreaded());
    }
    {
        var ctx = try RenderContext.init(allocator, 8, 8, mtSettings(0));
        defer ctx.deinit(allocator);
        try testing.expect(!ctx.isMultiThreaded());
    }
}

// The following tests are ports of the `#[cfg(feature = "multithreading")]`
// tests in upstream `render.rs`.

test "multithreaded crash after reset" {
    const allocator = testing.allocator;

    var pixmap = try Pixmap.init(allocator, 200, 200);
    defer pixmap.deinit(allocator);

    var resources = Resources.init();
    defer resources.deinit(allocator);

    var ctx = try RenderContext.init(allocator, 200, 200, mtSettings(1));
    defer ctx.deinit(allocator);

    ctx.reset();
    ctx.setPaint(palette.BLACK);
    try ctx.fillPath(allocator, &rectElements(kurbo.Rect.new(0.0, 0.0, 100.0, 100.0)));
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    try testing.expectEqual(premulU8(palette.BLACK), pixmap.sample(50, 50));
    try testing.expectEqual(transparentPixel(), pixmap.sample(150, 150));
}

test "multithreaded render empty frame after reset" {
    const allocator = testing.allocator;

    var ctx = try RenderContext.init(allocator, 100, 100, mtSettings(4));
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 100, 100);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 100.0, 100.0));
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    try testing.expectEqual(premulU8(palette.RED), pixmap.sample(50, 50));

    ctx.reset();
    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    for (0..100) |y| {
        for (0..100) |x| {
            try expectPixel(&pixmap, @intCast(x), @intCast(y), transparentPixel());
        }
    }
}

test "multithreaded push clip path before draw" {
    const allocator = testing.allocator;

    var ctx = try RenderContext.init(allocator, 100, 100, mtSettings(1));
    defer ctx.deinit(allocator);

    const clip = rectElements(kurbo.Rect.new(0.0, 0.0, 50.0, 50.0));
    try ctx.pushClipPath(allocator, &clip);
    try ctx.flush();
    ctx.popClipPath();
    try ctx.flush();
}

test "multithreaded reset with pending tasks" {
    const allocator = testing.allocator;

    var ctx = try RenderContext.init(allocator, 100, 100, mtSettings(4));
    defer ctx.deinit(allocator);

    // Note: this only exercises batch sends once the cost threshold is
    // crossed, matching the upstream test's note.
    for (0..300) |_| {
        try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 100.0, 100.0));
    }

    ctx.reset();
}

test "multithreaded drop with pending tasks" {
    const allocator = testing.allocator;

    for (0..10) |_| {
        var ctx = try RenderContext.init(allocator, 100, 100, mtSettings(4));
        defer ctx.deinit(allocator);

        for (0..300) |_| {
            try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 100.0, 100.0));
        }
    }
}

test "multithreaded render before flush returns a typed error" {
    const allocator = testing.allocator;

    var ctx = try RenderContext.init(allocator, 16, 16, mtSettings(2));
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 16, 16);
    defer pixmap.deinit(allocator);

    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 16.0, 16.0));
    try testing.expectError(
        error.NotFlushed,
        ctx.renderWith(&pixmap, &resources, qualitySettings()),
    );

    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    try expectPixel(&pixmap, 0, 0, premulU8(palette.RED));
}
