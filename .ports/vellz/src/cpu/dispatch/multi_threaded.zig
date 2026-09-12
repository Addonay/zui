//! Port of vello_cpu src/dispatch/multi_threaded.rs (Apache-2.0 OR MIT).
//!
//! A dispatcher for multi-threaded rendering. The Zig port replaces rayon's
//! thread pool and crossbeam/ordered-channel with a fixed set of persistent
//! `std.Thread` workers:
//!
//! - The main thread records draw commands into `AllocationGroup`s and sends
//!   batches of `RenderTask`s through a mutex/condvar queue.
//! - Workers generate strips and commands and publish results into in-order
//!   completion slots; the main thread records them in task order, so the
//!   recorded scene is identical to the single-threaded dispatcher's.
//! - Fine rasterization splits the target into disjoint strip-row `Region`s
//!   (row splitting mirrors upstream's `par_iter_mut`) claimed by workers with
//!   an atomic cursor. Regions are independent, so the pixel output does not
//!   depend on which worker processed a row.
//!
//! Upstream lifecycle notes are preserved: a `RenderTask`/`AllocationGroup` is
//! moved main -> worker -> main and recycled through `Allocations`;
//! `registerTask` batches work up to `cost.COST_THRESHOLD`; `flush` closes the
//! run, blocks until every task has been recorded, and only then is the
//! dispatcher "flushed" for rasterization and reset.
//!
//! Deliberate divergences (`adapt`):
//!
//! - Upstream is infallible (allocation failure aborts the process). This port
//!   returns `error.OutOfMemory` (and typed errors instead of panics for
//!   underflow / filters / u8); failed calls leave the dispatcher in a defined
//!   state and never queue a half-recorded draw.
//! - Upstream drains finished commands opportunistically after each batch; the
//!   port drains at `flush` so the `registerTask` failure path stays
//!   transactional. Task ordering and recorded output are unchanged.
//! - Upstream creates the per-thread `Fine`/`DepthBuffer` per rasterize call;
//!   the port keeps them in each worker for reuse. No output difference.
//! - Filter layers and `optimize_speed` return `error.Unsupported` (the
//!   upstream multi-threaded limitations), never a silent fallback to the
//!   single-threaded dispatcher; the u8 kernel is reached only through
//!   `single_threaded.zig`.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");
const encode_mod = @import("../../common/encode.zig");
const filter_data_mod = @import("../../common/filter.zig");
const clip_mod = @import("../../common/clip.zig");
const geometry = @import("../../common/geometry.zig");
const mask_mod = @import("../../common/mask.zig");
const paint_mod = @import("../../common/paint.zig");
const pixmap_mod = @import("../../common/pixmap.zig");
const record = @import("../../common/record.zig");
const strip_mod = @import("../../common/strip.zig");
const strip_generator = @import("../../common/strip_generator.zig");
const strip_storage = @import("../../common/strip_storage.zig");
const coarse = @import("../coarse/mod.zig");
const filter_mod = @import("../filter.zig");
const fine_mod = @import("../fine/mod.zig");
const cpu_record = @import("../record.zig");
const region_mod = @import("../region.zig");
const settings_mod = @import("../settings.zig");
const cost = @import("multi_threaded/cost.zig");
const sync = @import("multi_threaded/sync.zig");
const task = @import("multi_threaded/task.zig");
const worker_mod = @import("multi_threaded/worker.zig");

const BlendMode = peniko.BlendMode;
const ClipContext = clip_mod.ClipContext;
const CommandBucketer = coarse.CommandBucketer;
const CommandRecorder = record.CommandRecorder(cpu_record.RecordedFill);
const Fill = peniko.Fill;
const FilterContext = filter_mod.FilterContext;
const LayerClip = record.LayerClip;
const LayerProps = record.LayerProps;
const Mask = mask_mod.Mask;
const Paint = paint_mod.Paint;
const PathDataRef = strip_storage.PathDataRef;
const PixmapMut = pixmap_mod.PixmapMut;
const RasterizerSettings = settings_mod.RasterizerSettings;
const RecordedFill = cpu_record.RecordedFill;
const RectU16 = geometry.RectU16;
const Strip = strip_mod.Strip;
const StripGenerator = strip_generator.StripGenerator;
const StripStorage = strip_storage.StripStorage;
const TargetInit = worker_mod.FineTargetInit;

// Re-exported batch types (defined in `multi_threaded/task.zig`).
pub const AllocationGroup = task.AllocationGroup;
pub const ClipPathRef = task.ClipPathRef;
pub const FillPath = task.FillPath;
pub const OwnedClip = task.OwnedClip;
pub const PushLayer = task.PushLayer;
pub const RecordedCommand = task.RecordedCommand;
pub const RecordedCommandTask = task.RecordedCommandTask;
pub const RenderTask = task.RenderTask;
pub const RenderTaskType = task.RenderTaskType;
pub const StrokePath = task.StrokePath;

/// A pool of reusable buffers (upstream `AllocationManager`).
///
/// `get` pops a cleared buffer (or a fresh empty one); `put` clears the buffer
/// and pushes it back. If the pool cannot retain the buffer it is released
/// instead of leaked (upstream cannot fail).
fn AllocationManager(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Recycled buffers; all cleared.
        entries: std.ArrayList(T) = .empty,

        /// Get a cleared buffer from the pool.
        fn get(self: *Self) T {
            return self.entries.pop() orelse T.empty;
        }

        /// Return a buffer to the pool.
        fn put(self: *Self, allocator: std.mem.Allocator, allocation: T) void {
            var value = allocation;
            value.clearRetainingCapacity();
            self.entries.append(allocator, value) catch {
                value.deinit(allocator);
            };
        }

        /// Release every pooled buffer.
        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.entries.items) |*entry| entry.deinit(allocator);
            self.entries.deinit(allocator);
        }
    };
}

/// Reusable allocation pools for render batches (upstream `Allocations`).
pub const Allocations = struct {
    /// Render tasks of a batch.
    render_tasks: AllocationManager(std.ArrayList(task.RenderTaskType)) = .{},
    /// Path store of a batch.
    paths: AllocationManager(std.ArrayList(kurbo.PathEl)) = .{},
    /// Strips produced by a worker.
    strips: AllocationManager(std.ArrayList(Strip)) = .{},
    /// Commands produced by a worker.
    recorded_commands: AllocationManager(std.ArrayList(task.RecordedCommand)) = .{},

    fn get(self: *Allocations) task.AllocationGroup {
        return .{
            .render_tasks = self.render_tasks.get(),
            .path = self.paths.get(),
            .strips = self.strips.get(),
            .recorded_commands = self.recorded_commands.get(),
        };
    }

    fn put(self: *Allocations, allocator: std.mem.Allocator, allocation: task.AllocationGroup) void {
        self.render_tasks.put(allocator, allocation.render_tasks);
        self.paths.put(allocator, allocation.path);
        self.strips.put(allocator, allocation.strips);
        self.recorded_commands.put(allocator, allocation.recorded_commands);
    }

    fn deinit(self: *Allocations, allocator: std.mem.Allocator) void {
        self.render_tasks.deinit(allocator);
        self.paths.deinit(allocator);
        self.strips.deinit(allocator);
        self.recorded_commands.deinit(allocator);
    }
};

/// State shared with the worker threads (upstream channels + `MaybePresent`
/// alpha storage merged into one synchronised value; the Zig port keeps alpha
/// buffers in the workers instead, see `Worker.strip_storage`).
const SharedState = struct {
    /// Allocator for the job queue (thread-safe; supplied by the caller).
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    /// Signals workers that work (tasks, a run end, a raster job, shutdown)
    /// is available.
    work_cond: sync.Condition = .{},
    /// Signals the main thread that results are ready or workers parked.
    done_cond: sync.Condition = .{},
    /// Pending render tasks; `task_head` is the first unconsumed entry.
    tasks: std.ArrayList(task.RenderTask) = .empty,
    task_head: usize = 0,
    /// True between `closeRun` and the next `openRun`; workers park on it.
    batch_ended: bool = true,
    shutdown: bool = false,
    /// Number of workers currently parked (idle between runs or running a
    /// raster job).
    workers_idle: usize = 0,
    /// In-order result slots; `completions[idx - completion_base]` receives the
    /// result for task `idx`. Grown by the main thread under the mutex.
    completions: []?task.RecordedCommandTask = &.{},
    /// Task index of `completions[0]`.
    completion_base: u32 = 0,
    /// Active parallel rasterization job, if any.
    raster_job: ?*worker_mod.RasterizeJob = null,
    /// Incremented for every raster job; workers run a job when their
    /// last-seen epoch differs.
    raster_epoch: u32 = 0,
    raster_workers_done: usize = 0,
    raster_workers_expected: usize = 0,

    fn enqueueTask(self: *SharedState, allocator: std.mem.Allocator, render_task: *const task.RenderTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Compact the consumed prefix so the queue does not grow forever.
        if (self.task_head == self.tasks.items.len) {
            self.tasks.clearRetainingCapacity();
            self.task_head = 0;
        }
        try self.tasks.ensureUnusedCapacity(allocator, 1);
        self.tasks.appendAssumeCapacity(render_task.*);
        self.work_cond.broadcast();
    }
};

/// A dispatcher for multi-threaded rendering (upstream
/// `MultiThreadedDispatcher`).
pub const MultiThreadedDispatcher = struct {
    /// The dispatcher's allocator (stored because fine rasterization scratch
    /// lives in worker-owned `Fine` values).
    allocator: std.mem.Allocator,
    /// Coarse bucketer; only touched by the main thread while workers are
    /// parked (upstream wraps it in a `Mutex` for `&self` rasterization).
    bucketer: CommandBucketer,
    /// Clip state for the main thread's clip-path rasterization.
    clip_context: ClipContext,
    /// Recorder for root command streams, plus layer metadata.
    recorder: CommandRecorder,
    /// Global strip storage; alphas stay in the worker that produced them.
    strip_storage: StripStorage,
    /// Strip generator used for clip paths on the main thread.
    strip_generator: StripGenerator,
    /// Worker states, one per thread (index == thread id).
    workers: []worker_mod.Worker,
    /// Worker threads.
    threads: []std.Thread,
    /// Shared queue/completion/rasterization state.
    shared: *SharedState,
    /// Reusable allocation pools.
    allocations: Allocations,
    /// The batch currently being filled by the main thread.
    allocation_group: task.AllocationGroup,
    /// Scratch views of the worker alpha buffers for `FineResources`.
    alpha_views: std.ArrayList([]const u8),
    /// Accumulated cost of the current batch.
    batch_cost: f32,
    /// Index the next render task will receive.
    task_idx: u32,
    /// Index of the next result to record, in task order.
    next_result_idx: u32,
    /// Whether a run is open (`!shared.batch_ended`).
    run_open: bool,
    /// Whether every pending task has been recorded and workers parked.
    flushed: bool,
    /// Number of currently open layers.
    layer_depth: usize,
    /// SIMD level.
    level: simd.Level,
    /// Number of worker threads.
    num_threads: u16,

    /// Create a multi-threaded dispatcher with `num_threads` workers.
    ///
    /// `num_threads` must be in `1..=255` (thread ids are `u8` like upstream).
    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        num_threads: u16,
        level: simd.Level,
    ) !MultiThreadedDispatcher {
        if (num_threads == 0) return error.NoThreads;
        if (num_threads > 255) return error.TooManyThreads;

        const shared = try allocator.create(SharedState);
        errdefer allocator.destroy(shared);
        shared.* = .{ .allocator = allocator };

        const workers = try allocator.alloc(worker_mod.Worker, num_threads);
        errdefer allocator.free(workers);
        var workers_initialized: usize = 0;
        errdefer for (workers[0..workers_initialized]) |*worker| worker.deinit(allocator);
        for (workers, 0..) |*worker, i| {
            worker.* = worker_mod.Worker.init(allocator, width, height, @intCast(i), level);
            workers_initialized += 1;
        }

        const threads = try allocator.alloc(std.Thread, num_threads);
        errdefer allocator.free(threads);
        var spawned: usize = 0;
        errdefer {
            shared.mutex.lock();
            shared.shutdown = true;
            shared.work_cond.broadcast();
            shared.mutex.unlock();
            for (threads[0..spawned]) |thread| thread.join();
        }
        while (spawned < num_threads) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{
                &workers[spawned],
                shared,
            });
        }

        var bucketer = try CommandBucketer.init(allocator, width, height);
        errdefer bucketer.deinit(allocator);

        var main_strip_generator = StripGenerator.init(allocator, width, height, level);
        errdefer main_strip_generator.deinit(allocator);

        var recorder = CommandRecorder.new(width, height);
        errdefer recorder.deinit(allocator);

        var clip_context = ClipContext.init();
        errdefer clip_context.deinit(allocator);

        var alpha_views = std.ArrayList([]const u8).empty;
        errdefer alpha_views.deinit(allocator);
        try alpha_views.resize(allocator, num_threads);

        return .{
            .allocator = allocator,
            .bucketer = bucketer,
            .clip_context = clip_context,
            .recorder = recorder,
            .strip_storage = StripStorage.init(.append),
            .strip_generator = main_strip_generator,
            .workers = workers,
            .threads = threads,
            .shared = shared,
            .allocations = .{},
            .allocation_group = .{},
            .alpha_views = alpha_views,
            .batch_cost = 0.0,
            .task_idx = 0,
            .next_result_idx = 0,
            .run_open = false,
            .flushed = true,
            .layer_depth = 0,
            .level = level,
            .num_threads = num_threads,
        };
    }

    /// Flush pending work, stop the workers, and release every owned buffer.
    pub fn deinit(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) void {
        self.abortPending(allocator);

        const shared = self.shared;
        shared.mutex.lock();
        shared.shutdown = true;
        shared.batch_ended = true;
        shared.work_cond.broadcast();
        shared.done_cond.broadcast();
        shared.mutex.unlock();

        for (self.threads) |thread| thread.join();
        for (self.workers) |*worker| worker.deinit(allocator);
        allocator.free(self.threads);
        allocator.free(self.workers);

        shared.tasks.deinit(allocator);
        if (shared.completions.len > 0) allocator.free(shared.completions);
        allocator.destroy(shared);

        self.bucketer.deinit(allocator);
        self.clip_context.deinit(allocator);
        self.recorder.deinit(allocator);
        self.strip_storage.deinit(allocator);
        self.strip_generator.deinit(allocator);
        self.allocation_group.deinit(allocator);
        self.allocations.deinit(allocator);
        self.alpha_views.deinit(allocator);
        self.* = undefined;
    }

    /// Whether any layers are currently open.
    pub fn hasLayers(self: *const MultiThreadedDispatcher) bool {
        return self.layer_depth != 0;
    }

    /// Whether this dispatcher uses multiple threads (always true here).
    pub fn isMultiThreaded(_: *const MultiThreadedDispatcher) bool {
        return true;
    }

    // ------------------------------------------------------------ recording

    /// Fill a path (upstream `fill_path`).
    pub fn fillPath(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: Fill,
        transform: kurbo.Affine,
        paint: Paint,
        blend_mode: BlendMode,
        aliasing_threshold: ?u8,
        mask: ?*const Mask,
    ) !void {
        const start: u32 = @truncate(self.allocation_group.path.items.len);
        try self.allocation_group.path.appendSlice(allocator, path);
        errdefer self.allocation_group.path.shrinkRetainingCapacity(start);
        const end: u32 = @truncate(self.allocation_group.path.items.len);

        var owned_mask: ?Mask = if (mask) |current| current.clone() else null;
        errdefer if (owned_mask) |owned| owned.deinit(allocator);

        try self.registerTask(allocator, .{ .fill_path = .{
            .path_range = .{ .start = start, .end = end },
            .transform = transform,
            .paint = paint,
            .fill_rule = fill_rule,
            .blend_mode = blend_mode,
            .aliasing_threshold = aliasing_threshold,
            .mask = owned_mask,
        } });
        owned_mask = null;
    }

    /// Stroke a path (upstream `stroke_path`).
    pub fn strokePath(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        stroke: *const kurbo.Stroke,
        transform: kurbo.Affine,
        paint: Paint,
        blend_mode: BlendMode,
        aliasing_threshold: ?u8,
        mask: ?*const Mask,
    ) !void {
        const start: u32 = @truncate(self.allocation_group.path.items.len);
        try self.allocation_group.path.appendSlice(allocator, path);
        errdefer self.allocation_group.path.shrinkRetainingCapacity(start);
        const end: u32 = @truncate(self.allocation_group.path.items.len);

        var owned_mask: ?Mask = if (mask) |current| current.clone() else null;
        errdefer if (owned_mask) |owned| owned.deinit(allocator);

        try self.registerTask(allocator, .{
            .stroke_path = .{
                .path_range = .{ .start = start, .end = end },
                .transform = transform,
                .paint = paint,
                // The Zig `Stroke` owns no heap memory; a value copy is upstream's
                // clone.
                .stroke = stroke.*,
                .blend_mode = blend_mode,
                .aliasing_threshold = aliasing_threshold,
                .mask = owned_mask,
            },
        });
        owned_mask = null;
    }

    /// Fill a pixel-aligned rectangle (upstream `fill_rect_fast` falls back to
    /// path-based rendering for multi-threading).
    pub fn fillRectFast(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        rect: *const kurbo.Rect,
        paint: Paint,
        blend_mode: BlendMode,
        mask: ?*const Mask,
    ) !void {
        const start: u32 = @truncate(self.allocation_group.path.items.len);
        try self.allocation_group.path.ensureUnusedCapacity(allocator, 5);
        self.allocation_group.path.appendSliceAssumeCapacity(&[_]kurbo.PathEl{
            .{ .MoveTo = kurbo.Point.new(rect.x0, rect.y0) },
            .{ .LineTo = kurbo.Point.new(rect.x1, rect.y0) },
            .{ .LineTo = kurbo.Point.new(rect.x1, rect.y1) },
            .{ .LineTo = kurbo.Point.new(rect.x0, rect.y1) },
            .ClosePath,
        });
        errdefer self.allocation_group.path.shrinkRetainingCapacity(start);
        const end: u32 = @truncate(self.allocation_group.path.items.len);

        var owned_mask: ?Mask = if (mask) |current| current.clone() else null;
        errdefer if (owned_mask) |owned| owned.deinit(allocator);

        try self.registerTask(allocator, .{ .fill_path = .{
            .path_range = .{ .start = start, .end = end },
            .transform = kurbo.Affine.IDENTITY,
            .paint = paint,
            .fill_rule = .non_zero,
            .blend_mode = blend_mode,
            .aliasing_threshold = null,
            .mask = owned_mask,
        } });
        owned_mask = null;
    }

    /// Push a layer (upstream `push_layer`).
    ///
    /// `mask` and `filter_data` ownership transfer on success; on failure
    /// they are released here (the caller must not release them again),
    /// matching the single-threaded dispatcher's contract and upstream's
    /// by-value `Option<FilterData>`.
    pub fn pushLayer(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        clip_path: ?[]const kurbo.PathEl,
        fill_rule: Fill,
        clip_transform: kurbo.Affine,
        blend_mode: BlendMode,
        opacity: f32,
        aliasing_threshold: ?u8,
        mask: ?Mask,
        filter_data: ?filter_data_mod.FilterData,
    ) !void {
        var pending_filter = filter_data;
        errdefer if (pending_filter) |*owned| owned.deinit(allocator);

        // Upstream: `unimplemented!("Filter effects are not yet supported in
        // multi-threaded rendering")`. The typed error is intentional: never
        // silently fall back to the single-threaded filter path.
        if (pending_filter != null) return error.Unsupported;
        pending_filter = null;

        var pending_mask = mask;
        errdefer if (pending_mask) |owned| owned.deinit(allocator);

        var clip: ?task.ClipPathRef = null;
        if (clip_path) |path| {
            const start: u32 = @truncate(self.allocation_group.path.items.len);
            try self.allocation_group.path.appendSlice(allocator, path);
            errdefer self.allocation_group.path.shrinkRetainingCapacity(start);
            clip = .{
                .path_range = .{ .start = start, .end = @truncate(self.allocation_group.path.items.len) },
                .transform = clip_transform,
            };
        }

        try self.registerTask(allocator, .{ .push_layer = .{
            .clip_path = clip,
            .blend_mode = blend_mode,
            .opacity = opacity,
            .mask = pending_mask,
            .fill_rule = fill_rule,
            .aliasing_threshold = aliasing_threshold,
        } });
        pending_mask = null;
        self.layer_depth += 1;
    }

    /// Pop the last-pushed layer (upstream `pop_layer`).
    pub fn popLayer(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) !void {
        if (self.layer_depth == 0) return error.NoActiveLayer;
        try self.registerTask(allocator, .{ .pop_layer = {} });
        self.layer_depth -= 1;
    }

    /// Push a clip path (upstream `push_clip_path`).
    ///
    /// Pending render tasks are sent first so they keep the clip that was
    /// active when they were recorded.
    pub fn pushClipPath(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        fill_rule: Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
    ) !void {
        try self.flushTasks(allocator);
        try self.clip_context.pushClip(
            allocator,
            path,
            &self.strip_generator,
            fill_rule,
            transform,
            aliasing_threshold,
        );
    }

    /// Pop the last clip path (upstream `pop_clip_path`).
    pub fn popClipPath(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) !void {
        try self.flushTasks(allocator);
        try self.clip_context.popClip();
    }

    /// Reset the dispatcher for a new scene (upstream `reset`).
    pub fn reset(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) !void {
        try self.flush(allocator);

        self.clip_context.reset();
        self.recorder.reset(allocator, width, height);
        self.strip_storage.clear();
        self.allocation_group.clear();
        self.batch_cost = 0.0;
        self.task_idx = 0;
        self.next_result_idx = 0;
        self.layer_depth = 0;
        self.run_open = false;
        self.flushed = true;

        try self.strip_generator.reset(allocator, width, height);

        // All tasks are recorded and every worker is parked; reset worker
        // scratch and the completion window under the shared mutex.
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        for (self.workers) |*worker| try worker.reset(allocator, width, height);
        shared.tasks.clearRetainingCapacity();
        shared.task_head = 0;
        shared.completion_base = 0;
        if (shared.completions.len > 0) @memset(shared.completions, null);
        shared.raster_job = null;
    }

    /// Flush pending operations.
    ///
    /// Blocks until every worker task has been generated and recorded, and all
    /// workers are parked. Must be called before `rasterize` in MT mode;
    /// upstream panics otherwise, this port returns `error.NotFlushed`.
    pub fn flush(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) !void {
        if (self.flushed) return;

        try self.flushTasks(allocator);
        if (self.run_open) self.closeRun();

        // Drain any results left over from an earlier failed flush as well as
        // the results of the run that just ended.
        if (self.next_result_idx < self.task_idx) {
            self.recordFinishedCommands(allocator, false) catch |err| {
                // Workers keep draining; a later flush (or deinit) finishes the
                // recording. Do not mark the dispatcher flushed.
                return err;
            };
        }

        try self.waitWorkersIdle();
        self.compactCompletions();
        self.flushed = true;
    }

    // ------------------------------------------------------------- internals

    /// Register a render task; on success the task (and its owned mask, if
    /// any) belongs to the dispatcher. On failure nothing is registered and
    /// the caller still owns the task's resources.
    fn registerTask(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        render_task: task.RenderTaskType,
    ) !void {
        self.flushed = false;
        if (!self.run_open) self.openRun();

        const task_cost = cost.estimateRenderTaskCost(&render_task, self.allocation_group.path.items);
        try self.allocation_group.render_tasks.append(allocator, render_task);
        self.batch_cost += task_cost;

        if (self.batch_cost > cost.COST_THRESHOLD) {
            self.flushTasks(allocator) catch |err| {
                // The flush failure is an enqueue failure: the whole batch
                // (including this task) is still pending. Drop the new task so
                // a failed draw is never rendered by a later flush.
                const popped = self.allocation_group.render_tasks.pop().?;
                _ = popped; // The caller's `errdefer` releases it.
                self.batch_cost -= task_cost;
                return err;
            };
        }
    }

    /// Open a run: workers stop parking and start consuming tasks.
    fn openRun(self: *MultiThreadedDispatcher) void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.batch_ended = false;
        shared.work_cond.broadcast();
        self.run_open = true;
    }

    /// Close the current run: workers finish the queue and park.
    fn closeRun(self: *MultiThreadedDispatcher) void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.batch_ended = true;
        shared.work_cond.broadcast();
        self.run_open = false;
    }

    /// Send the pending batch to the workers (upstream `send_pending_tasks`).
    ///
    /// On failure nothing observable changes: the batch stays in
    /// `allocation_group` and no task index is consumed.
    fn flushTasks(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) !void {
        if (self.allocation_group.render_tasks.items.len == 0) return;
        if (!self.run_open) self.openRun();

        const idx = self.task_idx;
        try self.ensureCompletionCapacity(allocator, idx);

        const clip: ?task.OwnedClip = if (self.clip_context.get()) |path_data|
            try task.OwnedClip.dupe(allocator, path_data)
        else
            null;
        errdefer if (clip) |owned| owned.deinit(allocator);

        var render_task = task.RenderTask{
            .idx = idx,
            .clip_path = clip,
            .allocation_group = self.allocation_group,
        };
        try self.shared.enqueueTask(allocator, &render_task);

        // Ownership moved into the queue.
        self.task_idx += 1;
        self.allocation_group = self.allocations.get();
        self.batch_cost = 0.0;
    }

    /// Grow the completion window so task `idx` has a slot.
    fn ensureCompletionCapacity(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        idx: u32,
    ) !void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();

        const slot: usize = idx - shared.completion_base;
        if (slot < shared.completions.len) return;

        const required = slot + 1;
        const new_len = std.math.ceilPowerOfTwo(usize, @max(required, 64)) catch required;
        const new_slots = try allocator.alloc(?task.RecordedCommandTask, new_len);
        @memset(new_slots, null);
        @memcpy(new_slots[0..shared.completions.len], shared.completions);
        if (shared.completions.len > 0) allocator.free(shared.completions);
        shared.completions = new_slots;
    }

    /// Take the next in-order result while `shared.mutex` is held; returns
    /// null when the task has not completed yet.
    fn takeNextResultLocked(self: *MultiThreadedDispatcher) ?task.RecordedCommandTask {
        const shared = self.shared;
        if (self.next_result_idx >= self.task_idx) return null;
        const slot: usize = self.next_result_idx - shared.completion_base;
        const result = shared.completions[slot] orelse return null;
        shared.completions[slot] = null;
        self.next_result_idx += 1;
        return result;
    }

    /// Record finished worker commands on the main thread in task order
    /// (upstream `record_finished_commands`).
    ///
    /// `abort_empty` mirrors upstream: when true the call returns if no result
    /// is ready; otherwise it blocks until every sent task has been received.
    /// The result check and the wait share the same lock acquisition so a
    /// result arriving just before the wait cannot be missed.
    fn recordFinishedCommands(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        abort_empty: bool,
    ) !void {
        const shared = self.shared;
        while (true) {
            shared.mutex.lock();
            if (self.takeNextResultLocked()) |result| {
                shared.mutex.unlock();
                try self.recordResult(allocator, result);
                continue;
            }
            if (self.next_result_idx >= self.task_idx or abort_empty) {
                shared.mutex.unlock();
                return;
            }
            shared.done_cond.wait(&shared.mutex);
            shared.mutex.unlock();
        }
    }

    /// Append worker strips to the global strip storage.
    fn appendStrips(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        strips: []const Strip,
    ) !record.Range(usize) {
        const start = self.strip_storage.strips.items.len;
        try self.strip_storage.strips.appendSlice(allocator, strips);
        return .{ .start = start, .end = self.strip_storage.strips.items.len };
    }

    /// Record one finished batch (upstream the body of
    /// `record_finished_commands`).
    fn recordResult(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        result: task.RecordedCommandTask,
    ) !void {
        var group = result.allocation_group;
        defer {
            // Release masks of commands that were not moved into the recorder
            // (already-moved ones were nulled); idempotent.
            group.releaseResources(allocator);
            self.allocations.put(allocator, group);
        }

        if (result.err) |err| return err;

        for (group.recorded_commands.items) |*command| {
            switch (command.*) {
                .render_path => |*render_path| {
                    const worker_strips = group.strips.items[render_path.strips.start..render_path.strips.end];
                    const global_range = try self.appendStrips(allocator, worker_strips);
                    const strips = self.strip_storage.strips.items[global_range.start..global_range.end];

                    const draw = RecordedFill.new(
                        render_path.thread_id,
                        .{ .start = global_range.start, .end = global_range.end },
                        render_path.paint,
                        render_path.blend_mode,
                        render_path.mask,
                    );
                    render_path.mask = null;
                    self.recorder.pushDraw(allocator, draw, strips) catch |err| {
                        if (draw.mask) |owned| owned.deinit(allocator);
                        return err;
                    };
                },
                .push_layer => |*push| {
                    var clip: ?LayerClip = null;
                    if (push.clip_path) |worker_range| {
                        const worker_strips = group.strips.items[worker_range.start..worker_range.end];
                        const global_range = try self.appendStrips(allocator, worker_strips);
                        clip = .{
                            .strip_range = record.Range(usize).new(global_range.start, global_range.end),
                            .thread_idx = push.thread_id,
                            .bbox = push.clip_bbox orelse RectU16.ZERO,
                        };
                    }

                    const props = LayerProps{
                        .blend_mode = push.blend_mode,
                        .opacity = push.opacity,
                        .mask = push.mask,
                        .clip_path = clip,
                    };
                    push.mask = null;
                    self.recorder.pushLayer(allocator, props, null) catch |err| {
                        if (props.mask) |owned| owned.deinit(allocator);
                        return err;
                    };
                },
                .pop_layer => {
                    const popped = self.recorder.popLayer() catch |err| return err;
                    switch (popped) {
                        .regular => {},
                        // Filter layers are rejected by `pushLayer`; a recorded
                        // filter node can only appear through direct recorder
                        // use and stays unsupported.
                        .filter => return error.Unsupported,
                    }
                },
            }
        }
    }

    /// Block until every worker has parked.
    fn waitWorkersIdle(self: *MultiThreadedDispatcher) !void {
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        while (shared.workers_idle < self.num_threads) {
            shared.done_cond.wait(&shared.mutex);
        }
    }

    /// Reset the completion window once every result has been recorded.
    fn compactCompletions(self: *MultiThreadedDispatcher) void {
        std.debug.assert(self.next_result_idx >= self.task_idx);
        const shared = self.shared;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.completion_base = self.next_result_idx;
        if (shared.completions.len > 0) @memset(shared.completions, null);
    }

    /// Release every pending task/result without recording it; used by
    /// `deinit`. Blocks until in-flight work has returned to the main thread.
    fn abortPending(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) void {
        if (self.run_open) self.closeRun();

        const shared = self.shared;
        while (true) {
            shared.mutex.lock();
            if (self.takeNextResultLocked()) |result| {
                shared.mutex.unlock();
                var group = result.allocation_group;
                group.releaseResources(allocator);
                self.allocations.put(allocator, group);
                continue;
            }
            if (self.next_result_idx >= self.task_idx) {
                shared.mutex.unlock();
                break;
            }
            shared.done_cond.wait(&shared.mutex);
            shared.mutex.unlock();
        }

        // Unsent pending batch.
        self.allocation_group.releaseResources(allocator);
        self.allocation_group.clear();
        self.run_open = false;
        self.flushed = true;
        self.compactCompletions();
    }

    // ------------------------------------------------------------ rasterize

    /// Rasterize the recorded scene (upstream `rasterize`).
    ///
    /// The u8 kernel (`optimize_speed`) is a separate port; this dispatcher
    /// returns `error.Unsupported` for it rather than silently using f32.
    pub fn rasterize(
        self: *MultiThreadedDispatcher,
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
            // The u8 pipeline is a separate M4 port. Never fall back silently
            // to f32.
            .optimize_speed => return error.Unsupported,
        }
    }

    /// Rasterize using the f32 kernel (upstream `rasterize_f32`).
    fn rasterizeF32(
        self: *MultiThreadedDispatcher,
        allocator: std.mem.Allocator,
        target: *PixmapMut,
        scene_width: u16,
        scene_height: u16,
        settings: RasterizerSettings,
        encoded_paints: []encode_mod.EncodedPaint,
        image_resolver: paint_mod.ImageResolver,
    ) !void {
        if (!self.flushed) return error.NotFlushed;

        // Divergence: upstream's `OnceLock` gradient LUTs synchronize
        // on-demand initialization. This port builds the f32 LUTs on the main
        // thread before workers start, so workers only read them and no lock
        // is needed in the hot path. The bytes are identical either way.
        for (encoded_paints) |*encoded| {
            switch (encoded.*) {
                .gradient => |*gradient| _ = try gradient.f32Lut(allocator),
                else => {},
            }
        }

        const target_init: TargetInit = settings.target_init.map(paint_mod.PremulColor.fromAlphaColor);
        const params = fine_mod.FineRenderParams{
            .scene_size = .{ scene_width, scene_height },
            .target_offset = .{ settings.offset.x, settings.offset.y },
        };

        // Upstream uses `FilterContext::new(0)` here: multi-threaded dispatch
        // does not support filter layers.
        var filters = try FilterContext.init(allocator, 0);
        defer filters.deinit(allocator);
        const bucket_start = if (settings.timings) |t| t.now_ns() else 0;
        try self.bucketer.reset(allocator, RectU16.new(0, 0, scene_width, scene_height));
        try self.bucketer.bucketCommands(
            allocator,
            self.recorder.nodes.items,
            self.recorder.draws.items,
            self.recorder.layers.items,
            self.strip_storage.strips.items,
            encoded_paints,
            &filters,
        );
        if (settings.timings) |t| t.bucket_ns += t.now_ns() - bucket_start;

        try self.refreshAlphaViews(allocator);
        const no_filter_paints = [_]encode_mod.EncodedPaint{};
        const resources = fine_mod.FineResources{
            .alpha_buffers = self.alpha_views.items,
            .encoded_paints = encoded_paints,
            .filter_paints = &no_filter_paints,
            .image_resolver = image_resolver,
        };

        var regions = try region_mod.Regions.init(
            allocator,
            target,
            params.scene_size,
            params.target_offset,
            self.bucketer.rows().len,
        );
        defer regions.deinit(allocator);

        var job = worker_mod.RasterizeJob{
            .regions = regions.regions.items,
            .bucketer = &self.bucketer,
            .resources = resources,
            .target_init = target_init,
            .root_is_blend_target = self.recorder.root_is_blend_target,
        };

        const fine_start = if (settings.timings) |t| t.now_ns() else 0;
        try self.rasterizeParallel(&job);
        if (settings.timings) |t| t.fine_ns += t.now_ns() - fine_start;
        if (job.firstError()) |err| return err;
    }

    /// Point `alpha_views[i]` at worker `i`'s alpha buffer. Workers are parked
    /// after `flush`, so this is a race-free read.
    fn refreshAlphaViews(self: *MultiThreadedDispatcher, allocator: std.mem.Allocator) !void {
        try self.alpha_views.resize(allocator, self.num_threads);
        for (self.workers, 0..) |*worker, i| {
            self.alpha_views.items[i] = worker.strip_storage.alphas.items;
        }
    }

    /// Run a parallel rasterization job on all worker threads and wait for it.
    fn rasterizeParallel(
        self: *MultiThreadedDispatcher,
        job: *worker_mod.RasterizeJob,
    ) !void {
        const shared = self.shared;

        shared.mutex.lock();
        while (shared.workers_idle < self.num_threads) {
            shared.done_cond.wait(&shared.mutex);
        }
        shared.raster_job = job;
        shared.raster_workers_done = 0;
        shared.raster_workers_expected = self.num_threads;
        shared.raster_epoch +%= 1;
        shared.work_cond.broadcast();
        shared.mutex.unlock();

        shared.mutex.lock();
        while (shared.raster_workers_done < shared.raster_workers_expected) {
            shared.done_cond.wait(&shared.mutex);
        }
        shared.raster_job = null;
        shared.mutex.unlock();
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// The differential/dispatch tests live in `dispatch/mod.zig` (Dispatcher
// selection) and `cpu/render.zig` (full RenderContext scenes); these cover the
// dispatcher internals directly.
// ---------------------------------------------------------------------------

const testing = std.testing;
const palette = peniko.palette.css;

// Port of the upstream `allocations` test (`multi_threaded.rs`): repeated
// record/flush cycles must reuse exactly one allocation group per pool.
test "allocation groups are reused across flush cycles" {
    const allocator = testing.allocator;
    var dispatcher = try MultiThreadedDispatcher.init(allocator, 100, 100, 4, .baseline);
    defer dispatcher.deinit(allocator);

    for (0..20) |_| {
        var path = try kurbo.Rect.new(0.0, 0.0, 50.0, 50.0).toPath(0.1, allocator);
        defer path.deinit(allocator);
        try dispatcher.fillPath(
            allocator,
            path.elements.items,
            .non_zero,
            kurbo.Affine.IDENTITY,
            Paint.fromAlphaColor(palette.BLUE),
            BlendMode.default,
            null,
            null,
        );
        try dispatcher.flush(allocator);
    }

    try testing.expectEqual(
        @as(usize, 1),
        dispatcher.allocations.paths.entries.items.len,
    );
    try testing.expectEqual(
        @as(usize, 1),
        dispatcher.allocations.strips.entries.items.len,
    );
    try testing.expectEqual(
        @as(usize, 1),
        dispatcher.allocations.render_tasks.entries.items.len,
    );
    try testing.expectEqual(
        @as(usize, 1),
        dispatcher.allocations.recorded_commands.entries.items.len,
    );
}

test "thread-count limits are explicit errors" {
    const allocator = testing.allocator;
    try testing.expectError(
        error.NoThreads,
        MultiThreadedDispatcher.init(allocator, 8, 8, 0, .baseline),
    );
    try testing.expectError(
        error.TooManyThreads,
        MultiThreadedDispatcher.init(allocator, 8, 8, 256, .baseline),
    );
}

/// Worker thread entry point.
///
/// Active phase: consume queued render tasks and publish results into the
/// in-order completion slots. Parked phase (after `closeRun`): run raster jobs
/// as they are published, otherwise wait for the next run or shutdown.
fn workerMain(worker: *worker_mod.Worker, shared: *SharedState) void {
    var last_raster_epoch: u32 = 0;

    while (true) {
        shared.mutex.lock();

        while (shared.task_head == shared.tasks.items.len and
            !shared.batch_ended and
            !shared.shutdown)
        {
            shared.work_cond.wait(&shared.mutex);
        }
        if (shared.shutdown) {
            shared.mutex.unlock();
            return;
        }

        if (shared.task_head < shared.tasks.items.len) {
            const render_task = shared.tasks.items[shared.task_head];
            shared.task_head += 1;
            shared.mutex.unlock();

            const result = worker.runRenderTask(worker.allocator, render_task);

            shared.mutex.lock();
            const slot: usize = result.task_idx - shared.completion_base;
            std.debug.assert(slot < shared.completions.len);
            shared.completions[slot] = result;
            shared.done_cond.broadcast();
            shared.mutex.unlock();
            continue;
        }

        // Parked phase. Leave it when there is queued work, a new run opened,
        // a raster job arrived, or the dispatcher is shutting down. The queue
        // check is essential: `openRun` and `closeRun` can both happen while a
        // worker is still waking up, so `batch_ended` alone is not a reliable
        // "no work" signal.
        shared.workers_idle += 1;
        shared.done_cond.broadcast();

        while (!shared.shutdown) {
            if (shared.task_head < shared.tasks.items.len) break;
            if (shared.raster_job != null and shared.raster_epoch != last_raster_epoch) {
                last_raster_epoch = shared.raster_epoch;
                const raster_job = shared.raster_job.?;
                shared.mutex.unlock();
                worker.runRasterJob(raster_job);
                shared.mutex.lock();
                shared.raster_workers_done += 1;
                shared.done_cond.broadcast();
                continue;
            }
            if (!shared.batch_ended) break;
            shared.work_cond.wait(&shared.mutex);
        }

        shared.workers_idle -= 1;
        shared.mutex.unlock();

        if (shared.shutdown) return;
        // Either a new run opened or the queue has work; loop for tasks.
    }
}

test "filter layers and optimize_speed stay typed errors (no fallback)" {
    const allocator = testing.allocator;
    const filter_effects = @import("../../common/filter_effects.zig");

    var dispatcher = try MultiThreadedDispatcher.init(allocator, 8, 8, 2, .baseline);
    defer dispatcher.deinit(allocator);

    // Filter layers: upstream `unimplemented!` becomes a typed error, and the
    // owned `FilterData` is released by the rejected call.
    const filter = try filter_effects.Filter.fromPrimitive(allocator, .{
        .flood = .{ .color = palette.RED },
    });
    const filter_data = filter_data_mod.FilterData.new(filter, kurbo.Affine.IDENTITY);
    try testing.expectError(
        error.Unsupported,
        dispatcher.pushLayer(
            allocator,
            null,
            .non_zero,
            kurbo.Affine.IDENTITY,
            BlendMode.default,
            1.0,
            null,
            null,
            filter_data,
        ),
    );
    try testing.expect(!dispatcher.hasLayers());
    try testing.expect(dispatcher.isMultiThreaded());

    // `optimize_speed` is single-threaded only (upstream limitation): the MT
    // rasterizer must not silently render it with the f32 kernel.
    var pixmap = try pixmap_mod.Pixmap.init(allocator, 8, 8);
    defer pixmap.deinit(allocator);
    var target = pixmap.asMut();
    try dispatcher.flush(allocator);
    try testing.expectError(
        error.Unsupported,
        dispatcher.rasterize(
            allocator,
            &target,
            8,
            8,
            .{
                .render_mode = .optimize_speed,
                .target_init = .{ .clear = peniko.Color.TRANSPARENT },
                .pixel_format = .rgba8,
                .offset = .{ .x = 0, .y = 0 },
            },
            &.{},
            paint_mod.NO_OP_IMAGE_RESOLVER,
        ),
    );
}
