//! Port of vello_cpu src/render.rs (public API subset) (Apache-2.0 OR MIT).
//!
//! `RenderContext` is the main entry point for CPU drawing: it maintains the
//! current render state (transforms, paint, stroke, fill rule, ...), records
//! drawing commands through the single-threaded dispatcher, and rasterizes the
//! recorded scene into a `Pixmap`.
//!
//! Scope:
//!
//! - **Solid, gradient and image paints.** `setPaint` accepts a
//!   `peniko.Color` or a `common.paint.PaintType`; gradients and images are
//!   encoded into `encoded_paints` at draw time (M2) and rasterized by the
//!   fine painters. Blurred rounded rects remain `error.Unsupported`.
//! - **Regular layers only.** `pushClipLayer`/`pushBlendLayer`/
//!   `pushOpacityLayer`/`pushLayer` support clip/opacity/blend layers;
//!   `pushLayer` rejects a non-null filter with `error.Unsupported`.
//! - **Path-level masks** (`set_mask`/`reset_mask` upstream) are M2, matching
//!   their `RecordedFill.mask` seam in `cpu/record.zig`.
//! - Multi-threaded rendering is M4; `RenderSettings.num_threads` is ignored
//!   and rendering always uses the single-threaded dispatcher.
//!
//! Settings types (`RenderMode`, `PixelFormat`, `RenderSettings`,
//! `RasterizerSettings`, `TargetInit`) are defined in `cpu/settings.zig` and
//! re-exported here so the public path matches upstream `vello_cpu`; the
//! dispatcher imports the leaf module directly, which avoids an import cycle
//! (`render.zig` imports the dispatcher).
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
const encode_mod = @import("../common/encode.zig");
const filter_effects = @import("../common/filter_effects.zig");
const mask_mod = @import("../common/mask.zig");
const paint_mod = @import("../common/paint.zig");
const pixmap_mod = @import("../common/pixmap.zig");
const shared_mod = @import("../common/shared.zig");
const render_state_mod = @import("../common/render_state.zig");
const transforms_mod = @import("../common/transforms.zig");
const common_util = @import("../common/util.zig");
const settings_mod = @import("settings.zig");
const single_threaded = @import("dispatch/single_threaded.zig");

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
    /// The current paint-level filter effect (M2; draws fail while set).
    ///
    /// Owned handle: the context releases it on `deinit`,
    /// `resetFilterEffect`, or replacement by `setFilterEffect`.
    filter: ?Filter,
    /// The path-level mask applied to subsequent draws (upstream `mask`).
    /// Owned; `Mask` is reference-counted so `setMask`/`resetMask` are cheap.
    mask: ?Mask,
    /// The settings this context was created with.
    render_settings: RenderSettings,
    /// The single-threaded dispatcher (multi-threaded dispatch is M4).
    dispatcher: single_threaded.SingleThreadedDispatcher,
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

        var dispatcher = try single_threaded.SingleThreadedDispatcher.init(
            allocator,
            init_width,
            init_height,
            settings.level,
        );
        errdefer dispatcher.deinit(allocator);

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
        self.dispatcher.deinit(allocator);
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
    /// mode (always false until M4).
    pub fn isMultiThreaded(_: *const RenderContext) bool {
        return false;
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
    /// M2: while a filter is set, every draw fails with `error.Unsupported`
    /// (upstream wraps the draw in a filter layer). The context takes
    /// ownership of `filter`.
    pub fn setFilterEffect(self: *RenderContext, filter: Filter) void {
        if (self.filter) |old| old.deinit(self.allocator);
        self.filter = filter;
    }

    /// Reset the current filter effect, releasing the owned filter.
    pub fn resetFilterEffect(self: *RenderContext) void {
        if (self.filter) |filter| filter.deinit(self.allocator);
        self.filter = null;
    }

    // ------------------------------------------------------- drawing ops

    fn rejectFilter(self: *const RenderContext) !void {
        if (self.filter != null) return error.Unsupported;
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

    /// Fill a path.
    pub fn fillPath(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
    ) !void {
        try self.rejectFilter();
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
        try self.rejectFilter();
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
        try self.rejectFilter();
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
        try self.rejectFilter();
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
    /// `mask` is consumed whenever `filter` is null: on success ownership
    /// transfers to the recorder, on failure it is released here, so do not
    /// release it again. A non-null `filter` is M2 and makes this method fail
    /// with `error.Unsupported` before touching `mask`; ownership of both
    /// `mask` and `filter` then stays with the caller.
    pub fn pushLayer(
        self: *RenderContext,
        allocator: std.mem.Allocator,
        clip_path: ?[]const kurbo.PathEl,
        blend_mode: ?peniko.BlendMode,
        opacity: ?f32,
        mask: ?Mask,
        filter: ?Filter,
    ) !void {
        if (filter != null) return error.Unsupported;

        const blend = blend_mode orelse peniko.BlendMode.default;
        const alpha = std.math.clamp(opacity orelse 1.0, 0.0, 1.0);
        const layer_transform = self.root_transforms.effectivePathTransform(self.state.transforms);

        // The relative root transform is only non-identity for filter layers
        // (which are rejected above), but the push/pop bracket is always kept
        // so layer nesting matches upstream.
        self.root_transforms.pushRoot(allocator, kurbo.Affine.IDENTITY) catch |err| {
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

        try self.dispatcher.pushLayer(
            allocator,
            clip_path,
            self.state.fill_rule,
            layer_transform,
            blend,
            alpha,
            self.aliasing_threshold,
            effective_mask,
            null,
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
    pub fn popClipPath(self: *RenderContext) void {
        self.dispatcher.popClipPath();
    }

    // ------------------------------------------------------------ render

    /// Flush any pending operations.
    ///
    /// Always a no-op for the single-threaded dispatcher; callers may keep
    /// calling it (upstream recommends it) when switching to M4.
    pub fn flush(self: *RenderContext) void {
        self.dispatcher.flush();
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
    ctx.flush();
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
    ctx.flush();
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
    ctx.flush();
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
    ctx.flush();
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
    ctx.flush();
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
    ctx.flush();

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
    ctx.flush();
    try ctx.renderWith(&pixmap, &resources, qualitySettings());

    // The mask zeroes the left pixel and leaves the right one opaque.
    try expectPixel(&pixmap, 0, 0, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try expectPixel(&pixmap, 1, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });

    // `resetMask` drops the mask for subsequent draws on a fresh target.
    ctx.resetMask();
    var pixmap2 = try Pixmap.init(allocator, 2, 1);
    defer pixmap2.deinit(allocator);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 1.0));
    ctx.flush();
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
    ctx.flush();
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
    ctx.flush();
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

    ctx.flush();
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
    ctx.flush();
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
    ctx.flush();

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
    ctx.flush();

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

    ctx.flush();
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
    ctx.flush();
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
            ctx.flush();
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

    ctx.setAliasingThreshold(128);
    ctx.setFilterEffect(try filter_effects.Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 1.0, .edge_mode = .none },
    }));

    ctx.reset();
    try testing.expectEqual(@as(?u8, 128), ctx.aliasingThreshold());
    try testing.expect(ctx.filter != null);

    // While the filter is set, every draw fails explicitly (M2); the filter
    // itself survives the reset (upstream behavior).
    try testing.expectError(
        error.Unsupported,
        ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0)),
    );
    ctx.resetFilterEffect();
    try testing.expect(ctx.filter == null);

    // The recorded scene is cleared, so the context is reusable.
    var resources = Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    ctx.setPaint(palette.RED);
    try ctx.fillRect(allocator, kurbo.Rect.new(0.0, 0.0, 2.0, 2.0));
    try ctx.renderWith(&pixmap, &resources, qualitySettings());
    try expectPixel(&pixmap, 0, 0, premulU8(palette.RED));
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
    ctx.flush();
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
    ctx.flush();
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
        ctx.flush();
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
        ctx.flush();
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
