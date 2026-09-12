//! Port of `vello_gpu/src/schedule/mod.rs` (Apache-2.0 OR MIT).
//!
//! The scheduler consumes the recorded command graph and produces an
//! executable, dependency-ordered plan of GPU operations (draw, filter,
//! blend, clear) with atlas-allocated intermediate texture regions.
//!
//! # Adaptation from upstream
//!
//! Upstream batches operations into "rounds" that share a fixed pair of
//! texture pages, because a wgpu render pass can only bind one page per
//! parity. This port executes one pass per operation and binds the exact
//! pages each operation needs, so the round/stage bookkeeping is not required
//! for correctness. What the port does preserve from
//! `schedule/{mod,round,allocate,cursor}.rs`:
//!
//! - bottom-up, lazy allocation with the even/odd parity ping-pong,
//! - `vellz.common.multi_atlas` (guillotiere) pages with the same padded
//!   region requests and filter padding,
//! - dependency order: child layers are scheduled before their parent
//!   composes them, filters run after their layer's draws, non-default
//!   blends run after both parent and child are ready,
//! - release semantics: a released region is cleared and returned to its
//!   page, so the next allocation sees transparent contents,
//! - the shared scratch texture for blends and drop-shadow copies.
//!
//! Everything unsupported by this port is a typed error; there is no silent
//! fallback.
//!
//! CPU-safe: imports only `vellz.common` and the CPU-safe GPU layout modules.

const std = @import("std");
const common = @import("../../common/root.zig");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");
const allocate = @import("allocate.zig");
const blend_mod = @import("../blend.zig");
const draw_mod = @import("../draw.zig");
const filter_mod = @import("../filter.zig");
const paint_mod = @import("../paint.zig");
const scene_mod = @import("../scene.zig");
const target_mod = @import("../target.zig");

const AllocatedTextureRegion = allocate.AllocatedTextureRegion;
const BlendOp = blend_mod.BlendOp;
const Draw = draw_mod.Draw;
const DrawBuilder = draw_mod.DrawBuilder;
const DrawBuffers = draw_mod.DrawBuffers;
const DrawState = draw_mod.DrawState;
const ExternalTextureRun = draw_mod.ExternalTextureRun;
const FilterContext = filter_mod.FilterContext;
const FilterOp = filter_mod.FilterOp;
const FilterTextureRegions = filter_mod.FilterTextureRegions;
const LayerClip = common.record.LayerClip;
const LayerProps = common.record.LayerProps;
const LayerTextureId = target_mod.LayerTextureId;
const LayerTextureRegion = target_mod.LayerTextureRegion;
const Node = common.record.Node;
const PaintResolver = paint_mod.PaintResolver;
const PreparedGpuFilter = filter_mod.PreparedGpuFilter;
const RecordedDraw = scene_mod.RecordedDraw;
const RecordedLayer = common.record.RecordedLayer;
const RecordedLayerKind = common.record.RecordedLayerKind;
const RectU16 = common.geometry.RectU16;
const RootTarget = target_mod.RootTarget;
const SizeU16 = common.geometry.SizeU16;
const StripStorage = common.strip_storage.StripStorage;
const TextureParity = target_mod.TextureParity;
const TextureRegion = target_mod.TextureRegion;
const CommandRecorder = common.record.CommandRecorder;

/// Errors from scheduling a scene. `Unsupported` covers feature shapes the
/// schedule milestone does not implement; `UnsupportedCapability` covers
/// resource limits (region larger than a texture page, filter data texture
/// overflow); `LimitReached` reports the configured intermediate texture
/// count limit.
pub const Error = std.mem.Allocator.Error || error{
    Unsupported,
    LimitReached,
    UnsupportedCapability,
    MissingTextureBinding,
    TextureFeedbackLoop,
    /// An `ImageSource.opaque_id` paint has no allocation in the image cache.
    MissingImage,
};

/// Counts of allocated or required intermediate textures.
pub const IntermediateTextureAllocations = struct {
    /// Number of layer texture pages included for each parity.
    layer_pages: [2]usize = .{ 0, 0 },
    /// Whether the shared scratch texture is included.
    scratch: bool = false,

    /// Total number of physical textures represented by these allocations.
    pub fn textureCount(self: IntermediateTextureAllocations) usize {
        return self.layer_pages[0] + self.layer_pages[1] + @intFromBool(self.scratch);
    }
};

/// Intermediate textures required to execute a `Schedule`.
pub const IntermediateTextureRequirements = struct {
    /// Dimensions shared by every intermediate texture.
    size: SizeU16,
    /// Intermediate texture allocations required by the schedule.
    allocations: IntermediateTextureAllocations,

    /// Validate the requirements against an existing allocation set and a
    /// configured limit.
    pub fn validate(
        self: IntermediateTextureRequirements,
        existing: IntermediateTextureAllocations,
        max_textures: ?usize,
    ) Error!void {
        const combined = IntermediateTextureAllocations{
            .layer_pages = .{
                @max(self.allocations.layer_pages[0], existing.layer_pages[0]),
                @max(self.allocations.layer_pages[1], existing.layer_pages[1]),
            },
            .scratch = self.allocations.scratch or existing.scratch,
        };
        if (max_textures) |max| {
            const retained = combined.textureCount();
            if (retained > max) {
                std.debug.print(
                    "vellz-gpu: schedule needs {d} intermediate textures, limit is {d}\n",
                    .{ retained, max },
                );
                return error.LimitReached;
            }
        }
    }
};

/// The concrete target a draw renders into.
pub const TargetId = union(enum) {
    /// The user-provided root surface.
    root: RootTarget,
    /// An intermediate layer texture page.
    layer: LayerTextureId,
};

/// One scheduled draw pass and its texture bindings.
pub const DrawOp = struct {
    /// Destination of the draw.
    target: TargetId,
    /// Child layer sampled by the draw, if any.
    child: ?LayerTextureId = null,
    /// Strip ranges, external runs, and child-layer flag.
    draw: Draw,

    /// Release the draw's range storage.
    pub fn deinit(self: *DrawOp, allocator: std.mem.Allocator) void {
        self.draw.deinit(allocator);
    }
};

/// One scheduled region clear (used to release allocations transparently).
pub const ClearOp = struct {
    /// Texture page containing the region.
    target: LayerTextureId,
    /// Region to clear.
    rect: RectU16,
};

/// One executable operation in dependency order.
pub const Op = union(enum) {
    draw: DrawOp,
    filter: FilterOp,
    blend: BlendOp,
    clear: ClearOp,
};

/// A dependency-ordered rendering plan with its intermediate texture
/// requirements.
pub const Schedule = struct {
    allocator: std.mem.Allocator,
    /// Root output target.
    root_target: RootTarget,
    /// Whether root opaque strips may use the depth buffer.
    use_depth_buffer: bool,
    /// Operations in execution order (opaque strips execute separately, first).
    ops: std.ArrayList(Op),
    /// Shared strip and external-run storage referenced by draw ops.
    draw_buffers: DrawBuffers,
    /// Clip strips referenced by blend ops.
    blend_strips: std.ArrayList(blend_mod.BlendStrip),
    /// Encoded filter blocks (uploaded to the filter data texture).
    filter_context: FilterContext,
    /// Intermediate texture requirements.
    allocations: IntermediateTextureAllocations,
    /// Page dimensions.
    texture_size: SizeU16,

    /// Release every operation and buffer.
    pub fn deinit(self: *Schedule) void {
        for (self.ops.items) |*op| {
            switch (op.*) {
                .draw => |*draw_op| draw_op.deinit(self.allocator),
                else => {},
            }
        }
        self.ops.deinit(self.allocator);
        self.draw_buffers.deinit(self.allocator);
        self.blend_strips.deinit(self.allocator);
        self.filter_context.deinit(self.allocator);
        self.* = undefined;
    }

    /// Whether the root has opaque strips to render first.
    pub fn hasOpaqueStrips(self: *const Schedule) bool {
        return !self.draw_buffers.opaque_draw.isEmpty();
    }
};

/// Build a schedule for `scene`.
pub fn schedule(
    allocator: std.mem.Allocator,
    scene: *const scene_mod.Scene,
    root_output_target: RootTarget,
    use_depth_buffer: bool,
    paint_resolver: PaintResolver,
    texture_size: SizeU16,
    max_textures: ?usize,
) Error!Schedule {
    var scheduler = Scheduler{
        .allocator = allocator,
        .recorder = &scene.recorder,
        .scene_bbox = RectU16.new(
            0,
            0,
            // Scene size is already snapped to tile coordinates.
            scene.recorder.scene_size.width(),
            scene.recorder.scene_size.height(),
        ),
        .strip_storage = &scene.strip_storage,
        .root_render_target = root_output_target,
        .use_depth_buffer = use_depth_buffer,
        .paint_resolver = paint_resolver,
        .atlases = allocate.Atlases.init(texture_size),
        .ops = .empty,
        .draw_buffers = .{},
        .blend_strips = .empty,
        .filter_context = .{},
        .page_counts = .{ 0, 0 },
    };
    errdefer scheduler.deinit();

    try scheduler.build();

    const requirements = IntermediateTextureRequirements{
        .size = texture_size,
        .allocations = .{
            .layer_pages = scheduler.page_counts,
            .scratch = scheduler.atlases.scratchTexture(),
        },
    };
    try requirements.validate(.{ .layer_pages = .{ 0, 0 }, .scratch = false }, max_textures);

    // The page count is all the schedule needs from the atlas allocator;
    // release its free lists now.
    scheduler.atlases.deinit(allocator);

    return .{
        .allocator = allocator,
        .root_target = root_output_target,
        .use_depth_buffer = use_depth_buffer,
        .ops = scheduler.ops,
        .draw_buffers = scheduler.draw_buffers,
        .blend_strips = scheduler.blend_strips,
        .filter_context = scheduler.filter_context,
        .allocations = requirements.allocations,
        .texture_size = texture_size,
    };
}

/// Maps a rendered layer allocation to the region sampled by its parent.
const LayerSamplePlacement = struct {
    /// Offset within the rendered layer at which the sampled region begins.
    src_offset: [2]u16,
    /// Bounds where the sampled region is placed in the parent.
    dest_bbox: RectU16,

    fn regular(bbox: RectU16) LayerSamplePlacement {
        return .{ .src_offset = .{ 0, 0 }, .dest_bbox = bbox };
    }

    fn filter(placement: common.filter.FilterLayerPlacement) LayerSamplePlacement {
        return .{
            .src_offset = .{ placement.src_x, placement.src_y },
            .dest_bbox = placement.dest_bbox,
        };
    }

    fn resolve(self: LayerSamplePlacement, allocation: LayerTextureRegion) LayerTextureRegion {
        const x0 = allocation.texture.rect.x0 + self.src_offset[0];
        const y0 = allocation.texture.rect.y0 + self.src_offset[1];
        return .{
            .texture = .{
                .target = allocation.texture.target,
                .rect = RectU16.new(
                    x0,
                    y0,
                    x0 + self.dest_bbox.width(),
                    y0 + self.dest_bbox.height(),
                ),
            },
            .layer_bbox = self.dest_bbox,
        };
    }
};

/// A layer that has been scheduled and can be sampled by its parent.
const ScheduledLayer = struct {
    /// Atlas allocation retained until the parent finishes sampling.
    allocation: AllocatedTextureRegion,
    /// Texture region and scene-space bounds sampled by the parent.
    sample_region: LayerTextureRegion,
};

/// A recorded child node paired with its scheduled layer contents.
const PreparedChild = struct {
    /// Composition properties recorded on the child invocation.
    props: *const LayerProps,
    /// Scheduled contents to compose into the parent.
    layer: ScheduledLayer,
};

/// A recorded layer whose intermediate target may not have been allocated yet.
const OpenLayer = struct {
    /// Recorded command nodes belonging to the layer.
    cmds: []const Node,
    /// Layer kind, including filter data when applicable.
    kind: *const RecordedLayerKind,
    /// Texture group into which this layer must be allocated.
    texture_parity: TextureParity,
    /// Bounds that must be rendered into the layer allocation.
    bbox: RectU16,
    /// Placement used when the completed layer is sampled by its parent.
    sample_placement: LayerSamplePlacement,
    /// Lazily allocated target and its scheduling state.
    target: ?LayerTarget,
};

/// Allocated render target and state associated with an open layer.
const LayerTarget = struct {
    /// Atlas allocation backing the layer.
    allocation: AllocatedTextureRegion,
    /// Prepared filter applied after the layer's draws, if any.
    filter: ?PreparedGpuFilter,
    /// Draw state for the layer.
    state: TargetScheduleState,
};

/// Draw-target indirection so the draw builder works for both the root and
/// layer regions (upstream's `DrawTarget` trait).
pub const DrawTarget = union(enum) {
    root: RootTarget,
    layer: LayerTextureRegion,

    /// Whether opaque strips may use this target's depth buffer.
    pub fn enableDepth(self: DrawTarget) bool {
        return switch (self) {
            .root => |root| root.enableDepth(),
            .layer => false,
        };
    }

    /// Positional shift applied to all geometry for this target.
    pub fn geometryShift(self: DrawTarget) [2]i32 {
        return switch (self) {
            .root => |root| root.geometryShift(),
            .layer => |layer| layer.geometryShift(),
        };
    }
};

/// State for scheduling draws to a specific target.
const TargetScheduleState = struct {
    /// The underlying draw state.
    draw_state: DrawState(DrawTarget),

    fn init(target: DrawTarget, target_bbox: RectU16, use_depth_buffer: bool) TargetScheduleState {
        return .{ .draw_state = DrawState(DrawTarget).init(target, target_bbox, use_depth_buffer) };
    }

    fn layer(region: LayerTextureRegion) TargetScheduleState {
        return TargetScheduleState.init(.{ .layer = region }, region.layer_bbox, false);
    }
};

/// Plans concrete, executable operations from a recorded scene.
const Scheduler = struct {
    allocator: std.mem.Allocator,
    recorder: *const CommandRecorder(RecordedDraw),
    scene_bbox: RectU16,
    strip_storage: *const StripStorage,
    root_render_target: RootTarget,
    use_depth_buffer: bool,
    paint_resolver: PaintResolver,
    atlases: allocate.Atlases,
    ops: std.ArrayList(Op),
    draw_buffers: DrawBuffers,
    blend_strips: std.ArrayList(blend_mod.BlendStrip),
    filter_context: FilterContext,
    page_counts: [2]usize,

    fn deinit(self: *Scheduler) void {
        for (self.ops.items) |*op| {
            switch (op.*) {
                .draw => |*draw_op| draw_op.deinit(self.allocator),
                else => {},
            }
        }
        self.ops.deinit(self.allocator);
        self.draw_buffers.deinit(self.allocator);
        self.blend_strips.deinit(self.allocator);
        self.filter_context.deinit(self.allocator);
        self.atlases.deinit(self.allocator);
        self.* = undefined;
    }

    fn build(self: *Scheduler) Error!void {
        var root_state = TargetScheduleState.init(
            .{ .root = self.root_render_target },
            self.scene_bbox,
            self.use_depth_buffer,
        );

        if (self.recorder.root_is_blend_target) {
            // The user-provided target cannot be sampled; render everything
            // into an intermediate root layer, then blit it back.
            const root_kind: RecordedLayerKind = .regular;
            var layer = OpenLayer{
                .cmds = self.recorder.nodes.items,
                .kind = &root_kind,
                .texture_parity = .odd,
                .bbox = self.scene_bbox,
                .sample_placement = LayerSamplePlacement.regular(self.scene_bbox),
                .target = null,
            };
            const scheduled = try self.scheduleLayer(&layer);

            var ctx = LayerFillContext{
                .scheduler = self,
                .layer = &scheduled,
                .props = null,
            };
            try self.buildDraw(&root_state, &scheduled, &ctx);
            try self.releaseAllocation(scheduled.allocation);
        } else {
            for (self.recorder.nodes.items) |*cmd| {
                try self.pushDraws(cmd, &root_state);
                if (try self.scheduleChildLayer(cmd, self.scene_bbox)) |child| {
                    try self.composeSimpleLayer(&child, &root_state);
                }
            }
        }

        // The strips should be rendered front-to-back.
        self.draw_buffers.opaque_draw.reverse();
    }

    /// Append a recorded draw range to a new draw pass for the target.
    fn pushDraws(self: *Scheduler, cmd: *const Node, state: *TargetScheduleState) Error!void {
        if (cmd.draws.isEmpty()) return;
        var ctx = PushDrawsContext{
            .scheduler = self,
            .draws = self.recorder.draws.items[cmd.draws.start..cmd.draws.end],
        };
        try self.buildDraw(state, null, &ctx);
    }

    /// Encapsulate the draw-builder closure, append the resulting draw op if
    /// it produced any strips, and return it.
    fn buildDraw(
        self: *Scheduler,
        state: *TargetScheduleState,
        sampled_layer: ?*const ScheduledLayer,
        context: anytype,
    ) Error!void {
        var op_draw = Draw{};
        errdefer op_draw.deinit(self.allocator);
        var builder = DrawBuilder(DrawTarget).init(&op_draw, &self.draw_buffers, &state.draw_state);
        try context.run(&builder);

        if (op_draw.strip_ranges.len() == 0) {
            op_draw.deinit(self.allocator);
            return;
        }

        const child: ?LayerTextureId = if (op_draw.has_child_layer) blk: {
            const sample = sampled_layer orelse return error.Unsupported;
            break :blk sample.sample_region.texture.target;
        } else null;

        try self.ops.append(self.allocator, .{ .draw = .{
            .target = switch (state.draw_state.target) {
                .root => |root| .{ .root = root },
                .layer => |layer| .{ .layer = layer.texture.target },
            },
            .child = child,
            .draw = op_draw,
        } });
    }

    /// Resolve and schedule the optional child layer referenced by a command
    /// node.
    fn scheduleChildLayer(
        self: *Scheduler,
        cmd: *const Node,
        parent_bounds: RectU16,
    ) Error!?PreparedChild {
        const layer_id = cmd.layer orelse return null;
        const layer = &self.recorder.layers.items[layer_id];

        var bbox = layer.bbox;
        if (bbox.isEmpty()) {
            if (layer.props.blend_mode.isDestructive()) {
                // Unlike in the non-destructive case, empty *destructive*
                // layers are not a no-op; the whole parent region is cleared.
                bbox = parent_bounds;
            } else {
                return null;
            }
        }

        // Filters must be applied to the whole region before clips; other
        // layers can be reduced to the clip bbox.
        if (std.meta.activeTag(layer.kind) == .regular) {
            if (layer.props.clip_path) |clip| bbox = bbox.intersect(clip.bbox);
        }
        if (bbox.isEmpty()) return null;

        var open = self.openLayer(layer, bbox);
        const scheduled = try self.scheduleLayer(&open);
        return .{ .props = &layer.props, .layer = scheduled };
    }

    /// Create an unallocated scheduling view of a recorded layer.
    fn openLayer(self: *Scheduler, layer: *const RecordedLayer, bbox: RectU16) OpenLayer {
        const sample_placement = switch (layer.kind) {
            .regular => LayerSamplePlacement.regular(bbox),
            .filter => |filter_kind| LayerSamplePlacement.filter(filter_kind.placement),
        };
        return .{
            .cmds = layer.nodes.items,
            .kind = &layer.kind,
            .texture_parity = self.layerTextureParity(layer.depth),
            .bbox = bbox,
            .sample_placement = sample_placement,
            .target = null,
        };
    }

    /// Select the texture group for a recorded layer depth.
    fn layerTextureParity(self: *Scheduler, layer_depth: usize) TextureParity {
        return TextureParity.fromParity(layer_depth + @intFromBool(self.recorder.root_is_blend_target));
    }

    /// Schedule an open layer bottom-up and return its completed allocation.
    fn scheduleLayer(self: *Scheduler, layer: *OpenLayer) Error!ScheduledLayer {
        for (layer.cmds) |*cmd| {
            // Keep this before pushing any draws: allocating lazily is what
            // makes the traversal bottom-up with respect to memory.
            const child = try self.scheduleChildLayer(cmd, layer.sample_placement.dest_bbox);
            const target = try self.ensureLayerTarget(layer);
            try self.pushDraws(cmd, &target.state);
            if (child) |*prepared| {
                try self.composeLayer(prepared, &target.state);
            }
        }

        // Even without commands, make sure the target exists.
        const target = try self.ensureLayerTarget(layer);
        const region = target.state.draw_state.target.layer;

        if (target.filter) |prepared| {
            const temporary_request = allocate.LayerAllocationRequest.new(
                region.texture.rect,
                layer.kind.*,
                layer.texture_parity.opposite(),
            );
            const temporary = try self.allocateLayer(temporary_request);
            if (prepared.data.needsCopyPass()) self.atlases.requireScratchTexture();

            try self.ops.append(self.allocator, .{ .filter = .{
                .textures = FilterTextureRegions.new(region.texture, temporary.region),
                .filter_data_offset = prepared.data_offset,
                .gpu_filter = prepared.data,
            } });
            try self.releaseAllocation(temporary);
        }

        return .{
            .allocation = target.allocation,
            .sample_region = layer.sample_placement.resolve(region),
        };
    }

    /// Lazily allocate a target for an open layer.
    fn ensureLayerTarget(self: *Scheduler, layer: *OpenLayer) Error!*LayerTarget {
        if (layer.target == null) {
            var prepared_filter: ?PreparedGpuFilter = null;
            if (std.meta.activeTag(layer.kind.*) == .filter) {
                prepared_filter = try self.filter_context.push(
                    self.allocator,
                    &layer.kind.filter.filter_data,
                );
            }

            const request = allocate.LayerAllocationRequest.new(
                layer.bbox,
                layer.kind.*,
                layer.texture_parity,
            );
            const allocation = try self.allocateLayer(request);
            const region = LayerTextureRegion{
                .texture = allocation.region,
                .layer_bbox = layer.bbox,
            };
            layer.target = .{
                .allocation = allocation,
                .filter = prepared_filter,
                .state = TargetScheduleState.layer(region),
            };
        }
        return &layer.target.?;
    }

    /// Allocate a layer region, adding a page only when the existing pages
    /// cannot satisfy the request.
    fn allocateLayer(self: *Scheduler, request: allocate.LayerAllocationRequest) Error!AllocatedTextureRegion {
        const maybe_allocation = self.atlases.allocateLayer(self.allocator, request) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The padded allocation size overflowed the u16 atlas domain.
            error.TooLarge => return error.UnsupportedCapability,
        };
        if (maybe_allocation) |allocation| {
            self.notePage(allocation.region.target);
            return allocation;
        }

        try self.atlases.addLayerAtlas(self.allocator, request.texture_parity);
        self.page_counts[request.texture_parity.getParity()] += 1;

        const size = self.atlases.textureSize();
        const requested = request.allocationSize() orelse {
            std.debug.print("vellz-gpu: layer allocation size overflowed\n", .{});
            return error.UnsupportedCapability;
        };
        const second_try = self.atlases.allocateLayer(self.allocator, request) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.UnsupportedCapability,
        };
        const allocation = second_try orelse {
            std.debug.print(
                "vellz-gpu: layer {d}x{d} exceeds the {d}x{d} texture page size\n",
                .{ requested.width(), requested.height(), size.width(), size.height() },
            );
            return error.UnsupportedCapability;
        };
        self.notePage(allocation.region.target);
        return allocation;
    }

    fn notePage(self: *Scheduler, id: LayerTextureId) void {
        const parity = id.texture_parity.getParity();
        self.page_counts[parity] = @max(self.page_counts[parity], @as(usize, id.page_index) + 1);
    }

    /// Clear and release an allocation, appending the clear op after all
    /// readers in the plan.
    fn releaseAllocation(self: *Scheduler, allocation: AllocatedTextureRegion) Error!void {
        const clear_region = allocation.clearRegion();
        try self.ops.append(self.allocator, .{ .clear = .{
            .target = clear_region.target,
            .rect = clear_region.rect,
        } });
        self.atlases.deallocate(self.allocator, allocation) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.UnsupportedCapability,
        };
    }

    /// Compose a rendered child into a parent layer.
    fn composeLayer(
        self: *Scheduler,
        child: *const PreparedChild,
        parent_state: *TargetScheduleState,
    ) Error!void {
        const blend_mode = child.props.blend_mode;
        const opacity = child.props.opacity;

        if (isDefaultBlendMode(blend_mode)) {
            return self.composeSimpleLayer(child, parent_state);
        }

        // Non-default blending needs both the child and the existing parent
        // contents, so it is a separate blend operation.
        const parent_region = parent_state.draw_state.target.layer;
        const child_region = child.layer.sample_region.cropTo(parent_region.layer_bbox);

        // Destructive blends must process the whole parent; non-destructive
        // blends only the (smaller) child region.
        var blend_bbox = if (blend_mode.isDestructive())
            parent_region.layer_bbox
        else
            child_region.layer_bbox;
        if (child.props.clip_path) |clip_path| {
            blend_bbox = blend_bbox.intersect(clip_path.bbox);
        }
        if (blend_bbox.isEmpty()) {
            try self.releaseAllocation(child.layer.allocation);
            return;
        }

        var clip_range: ?common.record.Range(u32) = null;
        if (child.props.clip_path) |clip_path| {
            const start = self.blend_strips.items.len;
            const strips = self.strip_storage.strips.items[clip_path.strip_range.start..clip_path.strip_range.end];
            var ctx = BlendStripContext{
                .scheduler = self,
                .geometry_shift = parent_region.geometryShift(),
            };
            common.strip.visitStripFillSegments(strips, draw_mod.toTileBounds(blend_bbox), &ctx, true, true);
            if (ctx.err) |err| return err;
            clip_range = .{ .start = @intCast(start), .end = @intCast(self.blend_strips.items.len) };
        }

        self.atlases.requireScratchTexture();
        try self.ops.append(self.allocator, .{ .blend = .{
            .parent_region = parent_region,
            .child_region = child_region,
            .blend_bbox = blend_bbox,
            .blend_mode = blend_mode,
            .opacity = opacity,
            .clip_strips = clip_range,
        } });

        try self.releaseAllocation(child.layer.allocation);
    }

    /// Compose a completed child by drawing it directly into its parent using
    /// source-over.
    fn composeSimpleLayer(
        self: *Scheduler,
        child: *const PreparedChild,
        parent_state: *TargetScheduleState,
    ) Error!void {
        var ctx = LayerFillContext{
            .scheduler = self,
            .layer = &child.layer,
            .props = child.props,
        };
        try self.buildDraw(parent_state, &child.layer, &ctx);
        try self.releaseAllocation(child.layer.allocation);
    }
};

fn isDefaultBlendMode(blend_mode: peniko.BlendMode) bool {
    return blend_mode.mix == .normal and blend_mode.compose == .src_over;
}

const PushDrawsContext = struct {
    scheduler: *Scheduler,
    draws: []const RecordedDraw,

    fn run(self: *@This(), builder: anytype) Error!void {
        for (self.draws) |*recorded| {
            try builder.pushDraw(
                self.scheduler.allocator,
                recorded,
                self.scheduler.strip_storage,
                self.scheduler.paint_resolver,
            );
        }
    }
};

const LayerFillContext = struct {
    scheduler: *Scheduler,
    layer: *const ScheduledLayer,
    props: ?*const LayerProps,

    fn run(self: *@This(), builder: anytype) Error!void {
        const opacity = if (self.props) |props| props.opacity else 1.0;
        const clip_path: ?*const LayerClip = if (self.props) |props| blk: {
            if (props.clip_path) |*clip| break :blk clip;
            break :blk null;
        } else null;
        try builder.pushLayerFill(
            self.scheduler.allocator,
            self.layer.sample_region,
            opacity,
            clip_path,
            self.scheduler.strip_storage,
        );
    }
};

const BlendStripContext = struct {
    scheduler: *Scheduler,
    geometry_shift: [2]i32,
    err: ?Error = null,

    pub fn onAlphaSegment(self: *@This(), segment: common.strip.StripAlphaFillSegment) void {
        self.push(segment.fill, segment.alpha_idx / @as(u32, common.tile.Tile.HEIGHT));
    }

    pub fn onFillSegment(self: *@This(), segment: common.strip.StripFillSegment) void {
        self.push(segment, null);
    }

    fn push(self: *@This(), segment: common.strip.StripFillSegment, alpha_col_idx: ?u32) void {
        if (self.err != null) return;
        const shifted = segment.shift(self.geometry_shift);
        self.scheduler.blend_strips.append(
            self.scheduler.allocator,
            .{ .rect = shifted, .alpha_col_idx = alpha_col_idx },
        ) catch |err| {
            self.err = err;
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty scene schedules no operations" {
    const allocator = testing.allocator;
    var scene = try scene_mod.Scene.init(allocator, 64, 64);
    defer scene.deinit();

    var plan = try schedule(
        allocator,
        &scene,
        .user_surface,
        true,
        PaintResolver.solid_only,
        SizeU16.new(64),
        null,
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 0), plan.ops.items.len);
    try testing.expectEqual(@as(usize, 0), plan.allocations.layer_pages[0]);
    try testing.expectEqual(@as(usize, 0), plan.allocations.layer_pages[1]);
    try testing.expect(!plan.allocations.scratch);
}

test "clip and opacity layers schedule draws and a release clear" {
    const allocator = testing.allocator;
    var scene = try scene_mod.Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.setPaint(common.paint.PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(255, 0, 0)));
    try scene.fillRect(&kurbo.Rect.new(0, 0, 64, 64));

    var clip_path = try kurbo.Rect.new(4, 4, 60, 60).toPath(0.1, allocator);
    defer clip_path.deinit(allocator);
    try scene.pushClipLayer(clip_path.elements.items);
    scene.setPaint(common.paint.PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(0, 0, 255)));
    try scene.fillRect(&kurbo.Rect.new(0, 0, 64, 64));
    try scene.popLayer();

    var plan = try schedule(
        allocator,
        &scene,
        .user_surface,
        true,
        PaintResolver.solid_only,
        SizeU16.new(64),
        null,
    );
    defer plan.deinit();

    // The opaque background goes to the root opaque pass; the plan holds the
    // layer's own draw and the root composition draw.
    try testing.expectEqual(@as(usize, 1), plan.draw_buffers.opaque_draw.strips.items.len);
    var draw_count: usize = 0;
    var clear_count: usize = 0;
    for (plan.ops.items) |op| {
        switch (op) {
            .draw => |draw_op| {
                draw_count += 1;
                if (draw_op.child != null) {
                    try testing.expectEqual(LayerTextureId.new(.odd, 0), draw_op.child.?);
                }
            },
            .clear => clear_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), draw_count);
    try testing.expectEqual(@as(usize, 1), clear_count);
    try testing.expectEqual(@as(usize, 1), plan.allocations.layer_pages[1]);
    try testing.expectEqual(@as(usize, 0), plan.allocations.layer_pages[0]);
    // The clear must come after the layer fill that samples the child.
    try testing.expect(std.meta.activeTag(plan.ops.items[plan.ops.items.len - 1]) == .clear);
}

test "non-default blend requires the scratch texture" {
    const allocator = testing.allocator;
    var scene = try scene_mod.Scene.init(allocator, 64, 64);
    defer scene.deinit();

    scene.setPaint(common.paint.PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(255, 0, 0)));
    try scene.fillRect(&kurbo.Rect.new(0, 0, 64, 64));

    try scene.pushBlendLayer(peniko.BlendMode.from(peniko.Mix.multiply));
    scene.setPaint(common.paint.PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(0, 0, 255)));
    try scene.fillRect(&kurbo.Rect.new(8, 8, 56, 56));
    try scene.popLayer();

    var plan = try schedule(
        allocator,
        &scene,
        .user_surface,
        true,
        PaintResolver.solid_only,
        SizeU16.new(64),
        null,
    );
    defer plan.deinit();

    try testing.expect(plan.allocations.scratch);
    var blend_count: usize = 0;
    for (plan.ops.items) |op| {
        if (std.meta.activeTag(op) == .blend) blend_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), blend_count);
}
