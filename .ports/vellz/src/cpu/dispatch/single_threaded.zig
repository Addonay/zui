//! Port of vello_cpu src/dispatch/single_threaded.rs (Apache-2.0 OR MIT).
//!
//! The single-threaded dispatcher records fill commands from a path/stroke/rect
//! API into a `CommandRecorder`, then buckets and rasterizes them with the f32
//! fine kernel.
//!
//! M1 scope and deferrals:
//!
//! - `rasterize` only selects the f32 kernel (`F32Kernel`). Upstream with the
//!   `u8_pipeline` feature picks the u8 kernel for `RenderMode.optimize_speed`;
//!   that kernel is M4, so the speed mode returns `error.Unsupported` instead
//!   of silently rendering with different precision.
//! - `rasterizeFilterLayers` returns an empty `FilterContext` (M2). Filter
//!   layers cannot be recorded through this dispatcher either:
//!   `pushLayer` rejects a non-null `filter_data` with `error.Unsupported`, so
//!   the bucketer never sees a filter node.
//! - Multi-threaded dispatch is M4; there is no vtable yet and this type is
//!   used directly by `cpu/render.zig`.
//!
//! Ownership/allocator note: the dispatcher owns the bucketer, viewport,
//! recorder, and strip storage; every method that can grow them takes the
//! allocator explicitly and `init`/`deinit` are a pair. Masks are borrowed
//! (`?*const Mask`); the caller must keep them alive until rasterization.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");
const encode_mod = @import("../../common/encode.zig");
const filter_data_mod = @import("../../common/filter.zig");
const geometry = @import("../../common/geometry.zig");
const mask_mod = @import("../../common/mask.zig");
const paint_mod = @import("../../common/paint.zig");
const pixmap_mod = @import("../../common/pixmap.zig");
const record = @import("../../common/record.zig");
const strip_mod = @import("../../common/strip.zig");
const strip_generator = @import("../../common/strip_generator.zig");
const strip_storage = @import("../../common/strip_storage.zig");
const target_mod = @import("../../common/target.zig");
const viewport_mod = @import("../../common/viewport.zig");
const coarse = @import("../coarse/mod.zig");
const filter_mod = @import("../filter.zig");
const fine_mod = @import("../fine/mod.zig");
const cpu_record = @import("../record.zig");
const region_mod = @import("../region.zig");
const settings_mod = @import("../settings.zig");

const BlendMode = peniko.BlendMode;
const CommandBucketer = coarse.CommandBucketer;
const CommandRecorder = record.CommandRecorder(cpu_record.RecordedFill);
const DepthBuffer = coarse.DepthBuffer;
const F32Kernel = fine_mod.F32Kernel;
const Fill = peniko.Fill;
const FilterContext = filter_mod.FilterContext;
const Fine = fine_mod.Fine;
const FineResources = fine_mod.FineResources;
const LayerClip = record.LayerClip;
const LayerProps = record.LayerProps;
const Mask = mask_mod.Mask;
const Node = record.Node;
const Paint = paint_mod.Paint;
const PathDataRef = strip_storage.PathDataRef;
const PixmapMut = pixmap_mod.PixmapMut;
const PremulColor = paint_mod.PremulColor;
const RecordedFill = cpu_record.RecordedFill;
const Region = region_mod.Region;
const Regions = region_mod.Regions;
const RasterizerSettings = settings_mod.RasterizerSettings;
const RectU16 = geometry.RectU16;
const StripGenerator = strip_generator.StripGenerator;
const StripStorage = strip_storage.StripStorage;
const TargetInit = target_mod.TargetInit(PremulColor);
const ViewportState = viewport_mod.ViewportState;

/// Per-target parameters for fine rasterization (upstream
/// `FineRenderParams`).
pub const FineRenderParams = struct {
    /// Size of the scene in pixels.
    scene_size: [2]u16,
    /// Offset in the destination pixmap where the scene origin is placed.
    target_offset: [2]u16,
};

/// Single-threaded implementation of the rendering dispatcher.
pub const SingleThreadedDispatcher = struct {
    /// Reusable coarse bucketer that converts recorded commands into per-row
    /// render commands.
    bucketer: CommandBucketer,
    /// Viewport state.
    viewport: ViewportState,
    /// Recorder for root command streams, plus layer metadata.
    recorder: CommandRecorder,
    /// Storage for generated strips and alpha coverage data.
    strip_storage: StripStorage,
    /// SIMD level for fearless-SIMD dispatch.
    level: simd.Level,

    /// Create a new dispatcher for the given dimensions.
    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        level: simd.Level,
    ) !SingleThreadedDispatcher {
        var bucketer = try CommandBucketer.init(allocator, width, height);
        errdefer bucketer.deinit(allocator);

        var viewport = ViewportState.init(allocator, width, height, level);
        errdefer viewport.deinit(allocator);

        var recorder = CommandRecorder.new(width, height);
        errdefer recorder.deinit(allocator);

        return .{
            .bucketer = bucketer,
            .viewport = viewport,
            .recorder = recorder,
            .strip_storage = StripStorage.init(.append),
            .level = level,
        };
    }

    /// Release every owned buffer.
    pub fn deinit(self: *SingleThreadedDispatcher, allocator: std.mem.Allocator) void {
        self.bucketer.deinit(allocator);
        self.viewport.deinit(allocator);
        self.recorder.deinit(allocator);
        self.strip_storage.deinit(allocator);
        self.* = undefined;
    }

    /// Whether any layers are currently open.
    pub fn hasLayers(self: *const SingleThreadedDispatcher) bool {
        return self.recorder.hasLayers();
    }

    /// Whether this dispatcher uses multiple threads (always false here).
    pub fn isMultiThreaded(_: *const SingleThreadedDispatcher) bool {
        return false;
    }

    fn recordFill(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        strip_start: usize,
        paint: Paint,
        blend_mode: BlendMode,
        mask: ?*const Mask,
    ) !void {
        const strip_end = self.strip_storage.strips.items.len;
        const strip_range = cpu_record.StripRange{ .start = strip_start, .end = strip_end };
        const strips = self.strip_storage.strips.items[strip_start..strip_end];

        // The recording owns its mask handle (upstream clones the `Arc`), so
        // it stays valid even if the context later replaces or resets its
        // current mask.
        const owned_mask: ?Mask = if (mask) |m| m.clone() else null;
        errdefer if (owned_mask) |m| m.deinit(allocator);

        const draw = RecordedFill.new(0, strip_range, paint, blend_mode, owned_mask);
        try self.recorder.pushDraw(allocator, draw, strips);
    }

    /// Fill a path (upstream `fill_path`).
    pub fn fillPath(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: Fill,
        transform: kurbo.Affine,
        paint: Paint,
        blend_mode: BlendMode,
        aliasing_threshold: ?u8,
        mask: ?*const Mask,
    ) !void {
        const strip_start = self.strip_storage.strips.items.len;
        const Ctx = struct {
            allocator: std.mem.Allocator,
            path: []const kurbo.PathEl,
            fill_rule: Fill,
            transform: kurbo.Affine,
            aliasing_threshold: ?u8,
            storage: *StripStorage,

            fn run(
                ctx: *@This(),
                generator: *StripGenerator,
                clip_path: ?PathDataRef,
            ) !void {
                try generator.generateFilledPath(
                    ctx.allocator,
                    ctx.path,
                    ctx.fill_rule,
                    ctx.transform,
                    ctx.aliasing_threshold,
                    ctx.storage,
                    clip_path,
                );
            }
        };

        var ctx = Ctx{
            .allocator = allocator,
            .path = path,
            .fill_rule = fill_rule,
            .transform = transform,
            .aliasing_threshold = aliasing_threshold,
            .storage = &self.strip_storage,
        };
        try self.viewport.withGeneratorAndClip(&ctx, Ctx.run);
        try self.recordFill(allocator, strip_start, paint, blend_mode, mask);
    }

    /// Stroke a path (upstream `stroke_path`).
    pub fn strokePath(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        stroke: *const kurbo.Stroke,
        transform: kurbo.Affine,
        paint: Paint,
        blend_mode: BlendMode,
        aliasing_threshold: ?u8,
        mask: ?*const Mask,
    ) !void {
        const strip_start = self.strip_storage.strips.items.len;
        const Ctx = struct {
            allocator: std.mem.Allocator,
            path: []const kurbo.PathEl,
            stroke: *const kurbo.Stroke,
            transform: kurbo.Affine,
            aliasing_threshold: ?u8,
            storage: *StripStorage,

            fn run(
                ctx: *@This(),
                generator: *StripGenerator,
                clip_path: ?PathDataRef,
            ) !void {
                try generator.generateStrokedPath(
                    ctx.allocator,
                    ctx.path,
                    ctx.stroke,
                    ctx.transform,
                    ctx.aliasing_threshold,
                    ctx.storage,
                    clip_path,
                );
            }
        };

        var ctx = Ctx{
            .allocator = allocator,
            .path = path,
            .stroke = stroke,
            .transform = transform,
            .aliasing_threshold = aliasing_threshold,
            .storage = &self.strip_storage,
        };
        try self.viewport.withGeneratorAndClip(&ctx, Ctx.run);
        try self.recordFill(allocator, strip_start, paint, blend_mode, mask);
    }

    /// Fill a pixel-aligned rectangle with the current paint (upstream
    /// `fill_rect_fast`).
    pub fn fillRectFast(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        rect: *const kurbo.Rect,
        paint: Paint,
        blend_mode: BlendMode,
        mask: ?*const Mask,
    ) !void {
        const strip_start = self.strip_storage.strips.items.len;
        const Ctx = struct {
            allocator: std.mem.Allocator,
            rect: kurbo.Rect,
            storage: *StripStorage,

            fn run(
                ctx: *@This(),
                generator: *StripGenerator,
                clip_path: ?PathDataRef,
            ) !void {
                try generator.generateFilledRectFast(
                    ctx.allocator,
                    ctx.rect,
                    ctx.storage,
                    clip_path,
                );
            }
        };

        var ctx = Ctx{
            .allocator = allocator,
            .rect = rect.*,
            .storage = &self.strip_storage,
        };
        try self.viewport.withGeneratorAndClip(&ctx, Ctx.run);
        try self.recordFill(allocator, strip_start, paint, blend_mode, mask);
    }

    /// Push a layer (upstream `push_layer`).
    ///
    /// M1 rejects filter layers (`filter_data != null`) with
    /// `error.Unsupported`; regular layers record their clip path strips and
    /// hand the layer properties to the recorder.
    ///
    /// `mask` is consumed by this call: on success ownership transfers to the
    /// recorder, on failure it is released here (like upstream's `Drop` on
    /// error).
    pub fn pushLayer(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        clip_path: ?[]const kurbo.PathEl,
        fill_rule: Fill,
        clip_transform: kurbo.Affine,
        blend_mode: BlendMode,
        opacity: f32,
        aliasing_threshold: ?u8,
        mask: ?Mask,
        filter_data: ?*const filter_data_mod.FilterData,
    ) !void {
        // `mask` was transferred into this call; release it on every error
        // path until the recorder takes ownership.
        var pending_mask = mask;
        errdefer if (pending_mask) |owned| owned.deinit(allocator);

        if (filter_data != null) return error.Unsupported;

        var clip: ?LayerClip = null;
        if (clip_path) |path| {
            const strip_start = self.strip_storage.strips.items.len;
            const Ctx = struct {
                allocator: std.mem.Allocator,
                path: []const kurbo.PathEl,
                fill_rule: Fill,
                transform: kurbo.Affine,
                aliasing_threshold: ?u8,
                storage: *StripStorage,

                fn run(
                    ctx: *@This(),
                    generator: *StripGenerator,
                    clip_path_ref: ?PathDataRef,
                ) !void {
                    try generator.generateFilledPath(
                        ctx.allocator,
                        ctx.path,
                        ctx.fill_rule,
                        ctx.transform,
                        ctx.aliasing_threshold,
                        ctx.storage,
                        clip_path_ref,
                    );
                }
            };

            var ctx = Ctx{
                .allocator = allocator,
                .path = path,
                .fill_rule = fill_rule,
                .transform = clip_transform,
                .aliasing_threshold = aliasing_threshold,
                .storage = &self.strip_storage,
            };
            try self.viewport.withGeneratorAndClip(&ctx, Ctx.run);

            const clip_strips = self.strip_storage.strips.items[strip_start..];
            clip = .{
                .strip_range = .{ .start = strip_start, .end = self.strip_storage.strips.items.len },
                .thread_idx = 0,
                .bbox = strip_mod.stripBbox(clip_strips) orelse RectU16.ZERO,
            };
        }

        const props = LayerProps{
            .blend_mode = blend_mode,
            .opacity = opacity,
            .mask = pending_mask,
            .clip_path = clip,
        };
        pending_mask = null;
        self.recorder.pushLayer(allocator, props, null) catch |err| {
            // The recorder did not take ownership; release the mask here.
            if (props.mask) |owned| owned.deinit(allocator);
            return err;
        };
    }

    /// Pop the last-pushed layer (upstream `pop_layer`).
    pub fn popLayer(self: *SingleThreadedDispatcher, allocator: std.mem.Allocator) !void {
        _ = allocator; // M2: `.filter` pops the root viewport.
        const popped = try self.recorder.popLayer();
        switch (popped) {
            .regular => {},
            // Filter layers are rejected in `pushLayer`, so a recorded filter
            // layer can only appear through a direct recorder use.
            .filter => return error.Unsupported,
        }
    }

    /// Reset the dispatcher for a new scene (upstream `reset`).
    pub fn reset(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) !void {
        // The bucketer is reset on demand during rasterization.
        self.recorder.reset(allocator, width, height);
        self.strip_storage.clear();
        try self.viewport.reset(allocator, width, height);
    }

    /// Flush pending operations. Always a no-op for single-threaded dispatch.
    pub fn flush(_: *SingleThreadedDispatcher) void {}

    /// Push a clip path (upstream `push_clip_path`).
    pub fn pushClipPath(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
    ) !void {
        try self.viewport.pushClip(allocator, path, fill_rule, transform, aliasing_threshold);
    }

    /// Pop a clip path (upstream `pop_clip_path`).
    ///
    /// Underflow is a programming error (upstream panics); it is only asserted
    /// in debug builds because the public API is infallible.
    pub fn popClipPath(self: *SingleThreadedDispatcher) void {
        self.viewport.popClip() catch |err| {
            std.debug.assert(err == error.ClipStackUnderflow);
        };
    }

    /// Rasterize the recorded scene into `target` (upstream `rasterize`).
    ///
    /// `encoded_paints` are the scene's encoded gradient/image paints (owned
    /// by the caller); `image_resolver` resolves `ImageSource.opaque_id`
    /// paints.
    pub fn rasterize(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        target: *PixmapMut,
        scene_width: u16,
        scene_height: u16,
        settings: RasterizerSettings,
        encoded_paints: []encode_mod.EncodedPaint,
        image_resolver: paint_mod.ImageResolver,
    ) !void {
        switch (settings.render_mode) {
            .optimize_quality => try self.rasterizeF32(
                allocator,
                target,
                scene_width,
                scene_height,
                settings,
                encoded_paints,
                image_resolver,
            ),
            // The u8 pipeline is M4. Never fall back silently to f32.
            .optimize_speed => return error.Unsupported,
        }
    }

    /// Rasterize using the f32 precision pipeline (upstream `rasterize_f32`
    /// with only the `f32_pipeline` feature enabled).
    fn rasterizeF32(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        target: *PixmapMut,
        scene_width: u16,
        scene_height: u16,
        settings: RasterizerSettings,
        encoded_paints: []encode_mod.EncodedPaint,
        image_resolver: paint_mod.ImageResolver,
    ) !void {
        const filter_ctx = self.rasterizeFilterLayers();
        const target_init = settings.target_init.map(PremulColor.fromAlphaColor);
        const params = FineRenderParams{
            .scene_size = .{ scene_width, scene_height },
            .target_offset = .{ settings.offset.x, settings.offset.y },
        };

        try self.bucketAndRasterize(
            allocator,
            self.recorder.nodes.items,
            RectU16.new(0, 0, scene_width, scene_height),
            &filter_ctx,
            target,
            params,
            target_init,
            self.recorder.root_is_blend_target,
            encoded_paints,
            image_resolver,
        );
    }

    /// Rasterize every recorded filter layer (M2).
    ///
    /// M1 never records a filter layer (see `pushLayer`), so this returns an
    /// empty context. The M2 port iterates `recorder.filter_layers` in reverse,
    /// renders each layer into its placement pixmap, applies the filter, and
    /// stores the result with `FilterContext.setLayer`.
    fn rasterizeFilterLayers(self: *const SingleThreadedDispatcher) FilterContext {
        return FilterContext.init(self.recorder.layers.items.len);
    }

    fn bucketAndRasterize(
        self: *SingleThreadedDispatcher,
        allocator: std.mem.Allocator,
        cmds: []const Node,
        viewport: RectU16,
        filter_ctx: *const FilterContext,
        target: *PixmapMut,
        params: FineRenderParams,
        target_init: TargetInit,
        root_is_blend_target: bool,
        encoded_paints: []encode_mod.EncodedPaint,
        image_resolver: paint_mod.ImageResolver,
    ) !void {
        try self.bucketer.reset(allocator, viewport);
        try self.bucketer.bucketCommands(
            allocator,
            cmds,
            self.recorder.draws.items,
            self.recorder.layers.items,
            self.strip_storage.strips.items,
            encoded_paints,
            filter_ctx,
        );

        const alpha_buffers = [_][]const u8{self.strip_storage.alphas.items};
        // Filter layers are still deferred, so no encoded filter paints exist
        // yet; upstream reads them from the bucketer.
        const no_filter_paints = [_]encode_mod.EncodedPaint{};
        const resources = FineResources{
            .alpha_buffers = &alpha_buffers,
            .encoded_paints = encoded_paints,
            .filter_paints = &no_filter_paints,
            .image_resolver = image_resolver,
        };

        var regions = try Regions.init(
            allocator,
            target,
            params.scene_size,
            params.target_offset,
            self.bucketer.rows().len,
        );
        defer regions.deinit(allocator);

        var fine = try Fine(F32Kernel).init(self.level, allocator, self.bucketer.width);
        defer fine.deinit();
        var depth_buffer = try DepthBuffer.init(allocator, self.bucketer.width);
        defer depth_buffer.deinit(allocator);

        const Ctx = struct {
            fine: *Fine(F32Kernel),
            depth_buffer: *DepthBuffer,
            bucketer: *const CommandBucketer,
            resources: FineResources,
            target_init: TargetInit,
            root_is_blend_target: bool,
            err: ?fine_mod.Error = null,

            pub fn call(ctx: *@This(), region: *Region) void {
                if (ctx.err != null) return;
                fine_mod.rasterizeRegion(
                    F32Kernel,
                    ctx.fine,
                    ctx.depth_buffer,
                    region,
                    ctx.bucketer,
                    ctx.resources,
                    ctx.target_init,
                    ctx.root_is_blend_target,
                ) catch |err| {
                    ctx.err = err;
                };
            }
        };

        var ctx = Ctx{
            .fine = &fine,
            .depth_buffer = &depth_buffer,
            .bucketer = &self.bucketer,
            .resources = resources,
            .target_init = target_init,
            .root_is_blend_target = root_is_blend_target,
        };
        regions.update(&ctx);
        if (ctx.err) |err| return err;
    }
};

// ---------------------------------------------------------------------------
// Tests (port of the upstream `#[cfg(test)]` module)
// ---------------------------------------------------------------------------

const testing = std.testing;
const palette = peniko.palette.css;

test "buffers cleared on reset" {
    const allocator = testing.allocator;
    var dispatcher = try SingleThreadedDispatcher.init(allocator, 100, 100, .baseline);
    defer dispatcher.deinit(allocator);

    // Render a simple shape to populate the internal buffers.
    var path = try kurbo.Rect.new(0.0, 0.0, 50.0, 50.0).toPath(0.1, allocator);
    defer path.deinit(allocator);
    try dispatcher.fillPath(
        allocator,
        path.elements.items,
        Fill.non_zero,
        kurbo.Affine.IDENTITY,
        Paint.fromAlphaColor(palette.BLUE),
        BlendMode.default,
        null,
        null,
    );

    try testing.expect(dispatcher.strip_storage.strips.items.len != 0);
    try testing.expect(dispatcher.recorder.nodes.items.len != 0);

    try dispatcher.reset(allocator, 100, 100);

    try testing.expectEqual(@as(usize, 0), dispatcher.strip_storage.strips.items.len);
    try testing.expectEqual(@as(usize, 0), dispatcher.strip_storage.alphas.items.len);
    try testing.expectEqual(@as(usize, 0), dispatcher.recorder.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), dispatcher.recorder.layers.items.len);
    try testing.expect(!dispatcher.viewport.hasRootViewports());
}

test "fill rect fast records strips and rejects filter layers" {
    const allocator = testing.allocator;
    var dispatcher = try SingleThreadedDispatcher.init(allocator, 16, 8, .baseline);
    defer dispatcher.deinit(allocator);

    try dispatcher.fillRectFast(
        allocator,
        &kurbo.Rect.new(2.0, 1.0, 6.0, 5.0),
        Paint.fromAlphaColor(palette.RED),
        BlendMode.default,
        null,
    );
    try testing.expectEqual(@as(usize, 1), dispatcher.recorder.draws.items.len);
    try testing.expect(dispatcher.strip_storage.strips.items.len >= 2);

    // A filter layer is rejected before any recorder state changes.
    var filter = try @import("../../common/filter_effects.zig").Filter.fromPrimitive(
        allocator,
        .{ .gaussian_blur = .{ .std_deviation = 1.0, .edge_mode = .none } },
    );
    defer filter.deinit(allocator);
    var filter_data = @import("../../common/filter.zig").FilterData.new(
        filter.clone(),
        kurbo.Affine.IDENTITY,
    );
    defer filter_data.deinit(allocator);

    try testing.expectError(
        error.Unsupported,
        dispatcher.pushLayer(
            allocator,
            null,
            Fill.non_zero,
            kurbo.Affine.IDENTITY,
            BlendMode.default,
            1.0,
            null,
            null,
            &filter_data,
        ),
    );
    try testing.expect(!dispatcher.hasLayers());
    try testing.expectEqual(@as(usize, 0), dispatcher.recorder.layers.items.len);
}
