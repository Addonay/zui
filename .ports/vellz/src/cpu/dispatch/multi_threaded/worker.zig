//! Port of vello_cpu src/dispatch/multi_threaded/worker.rs (Apache-2.0 OR MIT).
//!
//! One `Worker` owns the per-thread strip generation state (upstream
//! `StripGenerator` + `StripStorage` + `thread_id`). Zig `std.Thread`
//! workers are persistent for the dispatcher's lifetime, so the worker also
//! owns the fine-rasterization scratch (`Fine`/`DepthBuffer`, upstream creates
//! these per rasterize call through a rayon `ThreadLocal`).
//!
//! Allocator contract: the worker stores the dispatcher's allocator (needed
//! because upstream's infallible per-thread state has no allocator parameter)
//! and also takes one explicitly on the entry points that can grow buffers.
//! `deinit` releases every buffer; `reset` keeps capacity.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const geometry = @import("../../../common/geometry.zig");
const paint_mod = @import("../../../common/paint.zig");
const strip_mod = @import("../../../common/strip.zig");
const strip_generator = @import("../../../common/strip_generator.zig");
const strip_storage = @import("../../../common/strip_storage.zig");
const target_mod = @import("../../../common/target.zig");
const coarse = @import("../../coarse/mod.zig");
const fine_mod = @import("../../fine/mod.zig");
const region_mod = @import("../../region.zig");
const task = @import("task.zig");

const DepthBuffer = coarse.DepthBuffer;
const Fine = fine_mod.Fine;
const F32Kernel = fine_mod.F32Kernel;
const FineResources = fine_mod.FineResources;
const PathDataRef = strip_storage.PathDataRef;
const RectU16 = geometry.RectU16;
const Region = region_mod.Region;
const RecordedCommandTask = task.RecordedCommandTask;
const RenderTask = task.RenderTask;
const RenderTaskType = task.RenderTaskType;
const CommandBucketer = coarse.CommandBucketer;
const StripGenerator = strip_generator.StripGenerator;
const StripStorage = strip_storage.StripStorage;

/// `TargetInit` instantiated for the fine rasterizer's premultiplied clear
/// color (the public `settings.TargetInit` uses straight-alpha colors and is
/// mapped before rasterization).
pub const FineTargetInit = target_mod.TargetInit(paint_mod.PremulColor);

/// A parallel fine-rasterization job over disjoint pixmap regions.
///
/// The main thread owns the job struct and the `Regions` storage; every worker
/// claims region indices with an atomic cursor (upstream does the same through
/// `rayon`'s `par_iter_mut`). The first error is latched so the main thread can
/// report a typed error after all workers have stopped.
pub const RasterizeJob = struct {
    /// The disjoint strip-row regions to rasterize.
    regions: []Region,
    /// Index of the next region to claim.
    next_region: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// The bucketed command stream shared by all rows.
    bucketer: *const CommandBucketer,
    /// Resources for fine rasterization.
    resources: FineResources,
    /// How the destination is initialized before drawing.
    target_init: FineTargetInit,
    /// Whether the root is the target of a non-default blending operation.
    root_is_blend_target: bool,
    /// Latched error code; 0 means no error.
    err_code: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    /// Record the first error, ignoring later ones (all regions abort the
    /// same render, so downstream errors add no information).
    pub fn setError(self: *RasterizeJob, err: anyerror) void {
        _ = self.err_code.cmpxchgStrong(0, @intFromError(err), .acq_rel, .acquire);
    }

    /// Return the latched error, if any.
    pub fn firstError(self: *RasterizeJob) ?anyerror {
        const code = self.err_code.load(.acquire);
        if (code == 0) return null;
        const err: anyerror = @errorFromInt(code);
        return err;
    }
};

/// The per-thread state used by the multi-threaded dispatcher
/// (upstream `Worker`).
pub const Worker = struct {
    /// The dispatcher's allocator, used by fine rasterization scratch.
    allocator: std.mem.Allocator,
    /// The SIMD level used for strip generation and fine rasterization.
    level: simd.Level,
    /// Zero-based worker index (selects the alpha buffer).
    thread_id: u8,
    /// Strip generator for this thread.
    strip_generator: StripGenerator,
    /// Strip and alpha storage for this thread.
    ///
    /// Unlike upstream, the alpha buffer stays in the worker between flush and
    /// the next run: the main thread only borrows it for rasterization while
    /// workers are parked (see `MultiThreadedDispatcher.rasterizeF32`).
    strip_storage: StripStorage,
    /// Lazily created fine rasterizer (one per worker, reused across
    /// rasterize calls; upstream recreates it per call).
    fine: ?Fine(F32Kernel) = null,
    /// Lazily created depth buffer matching `fine`.
    depth: ?DepthBuffer = null,

    /// Create a worker for a `width` x `height` viewport.
    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        thread_id: u8,
        level: simd.Level,
    ) Worker {
        return .{
            .allocator = allocator,
            .level = level,
            .thread_id = thread_id,
            .strip_generator = StripGenerator.init(allocator, width, height, level),
            .strip_storage = StripStorage.initDefault(),
        };
    }

    /// Release every owned buffer, including rasterization scratch.
    pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
        self.strip_generator.deinit(allocator);
        self.strip_storage.deinit(allocator);
        if (self.fine) |*fine| fine.deinit();
        if (self.depth) |*depth| depth.deinit(allocator);
        self.* = undefined;
    }

    /// Resize the strip generator for a new scene and clear this worker's
    /// alpha scratch (upstream `Worker::reset` + the dispatcher's
    /// `alpha_storage` clear).
    pub fn reset(self: *Worker, allocator: std.mem.Allocator, width: u16, height: u16) !void {
        try self.strip_generator.reset(allocator, width, height);
        self.strip_storage.strips.clearRetainingCapacity();
        self.strip_storage.alphas.clearRetainingCapacity();
    }

    /// Process one render task and return it with generated strips and
    /// commands (upstream `Worker::run_render_task`).
    ///
    /// The returned task always owns the same buffers it was given (moved, not
    /// copied). `err` is set by the first failing sub-task; unprocessed
    /// sub-tasks have their owned mask handles released here, and the main
    /// thread releases the generated commands on the error path.
    pub fn runRenderTask(
        self: *Worker,
        allocator: std.mem.Allocator,
        render_task: RenderTask,
    ) RecordedCommandTask {
        var group = render_task.allocation_group;
        var err: ?anyerror = null;

        const path_clip: ?PathDataRef = if (render_task.clip_path) |*clip|
            clip.asPathDataRef()
        else
            null;

        // Upstream clears the worker's strip buffer and switches it back to
        // append mode before every batch.
        self.strip_storage.strips.clearRetainingCapacity();
        self.strip_storage.setGenerationMode(.append);

        var i: usize = 0;
        while (i < group.render_tasks.items.len) : (i += 1) {
            // Copy the sub-task: masks are refcounted handles whose ownership
            // is moved into the generated command (the stale bits in
            // `render_tasks` are never released).
            const sub_task = group.render_tasks.items[i];
            self.runTask(allocator, &group, sub_task, path_clip) catch |error_value| {
                err = error_value;
                break;
            };
        }

        if (err != null) {
            // Release the failing sub-task and everything after it.
            for (group.render_tasks.items[i..]) |*sub_task| sub_task.releaseResources(allocator);
        }

        if (render_task.clip_path) |clip| clip.deinit(allocator);

        // Swap this batch's generated strips with the worker's reusable
        // buffer (upstream `std::mem::replace`).
        const taken_strips = self.strip_storage.strips;
        self.strip_storage.strips = group.strips;
        group.strips = taken_strips;

        group.render_tasks.clearRetainingCapacity();
        group.path.clearRetainingCapacity();

        return .{
            .task_idx = render_task.idx,
            .allocation_group = group,
            .err = err,
        };
    }

    fn runTask(
        self: *Worker,
        allocator: std.mem.Allocator,
        group: *task.AllocationGroup,
        render_task: RenderTaskType,
        path_clip: ?PathDataRef,
    ) !void {
        switch (render_task) {
            .fill_path => |fill| {
                const start: u32 = @truncate(self.strip_storage.strips.items.len);
                const path = group.path.items[fill.path_range.start..fill.path_range.end];
                try self.strip_generator.generateFilledPath(
                    allocator,
                    path,
                    fill.fill_rule,
                    fill.transform,
                    fill.aliasing_threshold,
                    &self.strip_storage,
                    path_clip,
                );
                const end: u32 = @truncate(self.strip_storage.strips.items.len);

                try group.recorded_commands.append(allocator, .{ .render_path = .{
                    .thread_id = self.thread_id,
                    .strips = .{ .start = start, .end = end },
                    .blend_mode = fill.blend_mode,
                    .paint = fill.paint,
                    .mask = fill.mask,
                } });
            },
            .stroke_path => |stroke| {
                const start: u32 = @truncate(self.strip_storage.strips.items.len);
                const path = group.path.items[stroke.path_range.start..stroke.path_range.end];
                try self.strip_generator.generateStrokedPath(
                    allocator,
                    path,
                    &stroke.stroke,
                    stroke.transform,
                    stroke.aliasing_threshold,
                    &self.strip_storage,
                    path_clip,
                );
                const end: u32 = @truncate(self.strip_storage.strips.items.len);

                try group.recorded_commands.append(allocator, .{ .render_path = .{
                    .thread_id = self.thread_id,
                    .strips = .{ .start = start, .end = end },
                    .blend_mode = stroke.blend_mode,
                    .paint = stroke.paint,
                    .mask = stroke.mask,
                } });
            },
            .push_layer => |layer| {
                var clip_path_range: ?task.Range = null;
                var clip_bbox: ?RectU16 = null;
                if (layer.clip_path) |clip| {
                    const start: u32 = @truncate(self.strip_storage.strips.items.len);
                    const path = group.path.items[clip.path_range.start..clip.path_range.end];
                    try self.strip_generator.generateFilledPath(
                        allocator,
                        path,
                        layer.fill_rule,
                        clip.transform,
                        layer.aliasing_threshold,
                        &self.strip_storage,
                        path_clip,
                    );
                    const end: u32 = @truncate(self.strip_storage.strips.items.len);
                    clip_path_range = .{ .start = start, .end = end };
                    clip_bbox = strip_mod.stripBbox(
                        self.strip_storage.strips.items[start..end],
                    ) orelse RectU16.ZERO;
                }

                try group.recorded_commands.append(allocator, .{ .push_layer = .{
                    .thread_id = self.thread_id,
                    .clip_path = clip_path_range,
                    .clip_bbox = clip_bbox,
                    .blend_mode = layer.blend_mode,
                    .opacity = layer.opacity,
                    .mask = layer.mask,
                } });
            },
            .pop_layer => {
                try group.recorded_commands.append(allocator, .{ .pop_layer = {} });
            },
        }
    }

    /// Rasterize regions of `job` until the shared cursor is exhausted
    /// (upstream's `par_iter_mut` body with a `ThreadLocal` Fine/Depth).
    pub fn runRasterJob(self: *Worker, job: *RasterizeJob) void {
        while (true) {
            const index = job.next_region.fetchAdd(1, .monotonic);
            if (index >= job.regions.len) break;

            self.rasterizeRegion(job, &job.regions[index]) catch |err| {
                job.setError(err);
                break;
            };
        }
    }

    fn rasterizeRegion(self: *Worker, job: *RasterizeJob, region: *Region) !void {
        if (self.fine == null) {
            self.fine = try Fine(F32Kernel).init(self.level, self.allocator, job.bucketer.width);
        }
        if (self.depth == null) {
            self.depth = try DepthBuffer.init(self.allocator, job.bucketer.width);
        }

        try fine_mod.rasterizeRegion(
            F32Kernel,
            &self.fine.?,
            &self.depth.?,
            region,
            job.bucketer,
            job.resources,
            job.target_init,
            job.root_is_blend_target,
        );
    }
};
