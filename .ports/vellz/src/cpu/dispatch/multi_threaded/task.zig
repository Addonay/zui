//! Port of the shared types from vello_cpu
//! src/dispatch/multi_threaded.rs (Apache-2.0 OR MIT).
//!
//! Upstream declares `AllocationGroup`, `RenderTask`, `RenderTaskType`,
//! `RecordedCommand`, and `RecordedCommandTask` in `multi_threaded.rs`; the
//! `worker` and `cost` submodules import them from the parent. Zig cannot
//! express that import cycle, so this leaf module owns the shared types and
//! `multi_threaded.zig` re-exports them (the same split used by
//! `common/strip_storage.zig`).
//!
//! Ownership: a `RenderTask`/`AllocationGroup` is a move-only bundle of
//! `std.ArrayList`s plus owned mask handles and (for clip paths) owned strip
//! and alpha copies. Ownership travels main -> worker -> main; every helper
//! here documents which side releases what. `record.Range(u32)` mirrors
//! upstream's `Range<u32>`.

const std = @import("std");
const kurbo = @import("../../../kurbo/root.zig");
const peniko = @import("../../../peniko/root.zig");
const geometry = @import("../../../common/geometry.zig");
const mask_mod = @import("../../../common/mask.zig");
const paint_mod = @import("../../../common/paint.zig");
const record = @import("../../../common/record.zig");
const strip_mod = @import("../../../common/strip.zig");
const strip_storage = @import("../../../common/strip_storage.zig");

const Mask = mask_mod.Mask;
const Paint = paint_mod.Paint;
const PathDataRef = strip_storage.PathDataRef;
const RectU16 = geometry.RectU16;
const Strip = strip_mod.Strip;

/// Upstream's `Range<u32>` (path-element and strip ranges inside a batch).
pub const Range = record.Range(u32);

/// A path range plus the clip transform it must be generated with, stored in
/// the task's shared path buffer (upstream `RenderTaskType::PushLayer`
/// clip_path tuple).
pub const ClipPathRef = struct {
    /// Range of `AllocationGroup.path` elements belonging to the clip path.
    path_range: record.Range(u32),
    /// Transform to apply while generating the clip path.
    transform: kurbo.Affine,
};

/// A fill task for a worker (upstream `RenderTaskType::FillPath`).
pub const FillPath = struct {
    /// Range of `AllocationGroup.path` elements to flatten.
    path_range: record.Range(u32),
    /// Transform from path space to scene space.
    transform: kurbo.Affine,
    /// Paint to record with the generated strips.
    paint: Paint,
    /// Fill rule for the path.
    fill_rule: peniko.Fill,
    /// Blend mode applied directly by this draw.
    blend_mode: peniko.BlendMode,
    /// Optional aliasing threshold.
    aliasing_threshold: ?u8,
    /// Owned mask handle for this draw.
    mask: ?Mask,
};

/// A stroke task for a worker (upstream `RenderTaskType::StrokePath`).
pub const StrokePath = struct {
    /// Range of `AllocationGroup.path` elements to stroke.
    path_range: record.Range(u32),
    /// Transform from path space to scene space.
    transform: kurbo.Affine,
    /// Paint to record with the generated strips.
    paint: Paint,
    /// Stroke style (upstream clones the `Stroke`; the Zig `Stroke` owns no
    /// heap memory, so a value copy is the clone).
    stroke: kurbo.Stroke,
    /// Blend mode applied directly by this draw.
    blend_mode: peniko.BlendMode,
    /// Optional aliasing threshold.
    aliasing_threshold: ?u8,
    /// Owned mask handle for this draw.
    mask: ?Mask,
};

/// A layer push task for a worker (upstream `RenderTaskType::PushLayer`).
pub const PushLayer = struct {
    /// Optional clip path and its transform.
    clip_path: ?ClipPathRef,
    /// Blend mode used when compositing the layer.
    blend_mode: peniko.BlendMode,
    /// Opacity applied when compositing the layer.
    opacity: f32,
    /// Owned mask handle for the layer.
    mask: ?Mask,
    /// Fill rule for the clip path.
    fill_rule: peniko.Fill,
    /// Optional aliasing threshold for the clip path.
    aliasing_threshold: ?u8,
};

/// One unit of path-generation work for a worker (upstream `RenderTaskType`).
pub const RenderTaskType = union(enum) {
    fill_path: FillPath,
    stroke_path: StrokePath,
    push_layer: PushLayer,
    pop_layer,

    /// Release any owned mask handle held by this task.
    ///
    /// Processed tasks move their mask into a `RecordedCommand` (whose mask is
    /// released by the main thread); unprocessed tasks on an aborted batch are
    /// released by the worker through this helper.
    pub fn releaseResources(self: *RenderTaskType, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .fill_path => |*task| if (task.mask) |mask| {
                mask.deinit(allocator);
                task.mask = null;
            },
            .stroke_path => |*task| if (task.mask) |mask| {
                mask.deinit(allocator);
                task.mask = null;
            },
            .push_layer => |*task| if (task.mask) |mask| {
                mask.deinit(allocator);
                task.mask = null;
            },
            .pop_layer => {},
        }
    }
};

/// The strips and alphas of the clip path active when a batch of render tasks
/// was sent (upstream `OwnedClip`).
///
/// The buffers are owned copies so workers can keep using them after the main
/// thread pushes or pops clips; the worker frees them when the task is done.
pub const OwnedClip = struct {
    /// Owned strip copy.
    strips: []Strip,
    /// Owned alpha copy.
    alphas: []u8,
    /// Coarse bounding box already intersected with the viewport.
    bbox: RectU16,

    /// Create owned copies of `path_data` with `allocator`.
    pub fn dupe(allocator: std.mem.Allocator, path_data: PathDataRef) std.mem.Allocator.Error!OwnedClip {
        const strips = try allocator.dupe(Strip, path_data.strips);
        errdefer allocator.free(strips);
        const alphas = try allocator.dupe(u8, path_data.alphas);
        errdefer allocator.free(alphas);
        return .{ .strips = strips, .alphas = alphas, .bbox = path_data.bbox };
    }

    /// Release both owned buffers.
    pub fn deinit(self: OwnedClip, allocator: std.mem.Allocator) void {
        allocator.free(self.strips);
        allocator.free(self.alphas);
    }

    /// Borrow this clip for strip generation.
    pub fn asPathDataRef(self: *const OwnedClip) PathDataRef {
        return .{ .strips = self.strips, .alphas = self.alphas, .bbox = self.bbox };
    }
};

/// A command generated by a worker, recorded by the main thread
/// (upstream `RecordedCommand`).
pub const RecordedCommand = union(enum) {
    /// A path fill whose strips are in the batch's `strips` buffer.
    render_path: RenderPathCommand,
    /// A layer push, optionally with a generated clip path.
    push_layer: PushLayerCommand,
    /// A layer pop.
    pop_layer,

    /// Release any owned mask handle held by this command.
    pub fn releaseResources(self: *RecordedCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .render_path => |*command| if (command.mask) |mask| {
                mask.deinit(allocator);
                command.mask = null;
            },
            .push_layer => |*command| if (command.mask) |mask| {
                mask.deinit(allocator);
                command.mask = null;
            },
            .pop_layer => {},
        }
    }
};

/// A recorded path fill (upstream `RecordedCommand::RenderPath`).
pub const RenderPathCommand = struct {
    /// Worker that generated the strips (selects the alpha buffer).
    thread_id: u8,
    /// Range of the batch's `strips` buffer.
    strips: record.Range(u32),
    /// Blend mode applied directly by this draw.
    blend_mode: peniko.BlendMode,
    /// Paint for this draw.
    paint: Paint,
    /// Owned mask handle; moved into the recorded fill by the main thread.
    mask: ?Mask,
};

/// A recorded layer push (upstream `RecordedCommand::PushLayer`).
pub const PushLayerCommand = struct {
    /// Worker that generated the clip strips, if any.
    thread_id: u8,
    /// Range of the batch's `strips` buffer for the clip path, if any.
    clip_path: ?record.Range(u32),
    /// Bounding box of the clip path; present iff `clip_path` is present.
    clip_bbox: ?RectU16,
    /// Blend mode used when compositing the layer.
    blend_mode: peniko.BlendMode,
    /// Opacity applied when compositing the layer.
    opacity: f32,
    /// Owned mask handle; moved into the recorded layer by the main thread.
    mask: ?Mask,
};

/// A batch of render tasks plus the path buffer their ranges refer to
/// (upstream `RenderTask`).
pub const RenderTask = struct {
    /// Ordering index; results are recorded in this order.
    idx: u32,
    /// Owned snapshot of the active clip path, if any.
    clip_path: ?OwnedClip,
    /// Paths, tasks, and (after processing) strips and generated commands.
    allocation_group: AllocationGroup,
};

/// The result of processing one `RenderTask` (upstream
/// `RecordedCommandTask`).
pub const RecordedCommandTask = struct {
    /// Index of the originating task.
    task_idx: u32,
    /// The batch, now carrying generated strips and commands.
    allocation_group: AllocationGroup,
    /// The first error hit while generating the batch, if any. Upstream is
    /// infallible (OOM aborts); this port reports the error to the main thread
    /// and drops the batch explicitly.
    err: ?anyerror = null,
};

/// The allocations that travel with one batch of render tasks
/// (upstream `AllocationGroup`).
pub const AllocationGroup = struct {
    /// Path elements referenced by the task ranges.
    path: std.ArrayList(kurbo.PathEl) = .empty,
    /// Pending tasks.
    render_tasks: std.ArrayList(RenderTaskType) = .empty,
    /// Strips generated for this batch.
    strips: std.ArrayList(Strip) = .empty,
    /// Commands generated for this batch.
    recorded_commands: std.ArrayList(RecordedCommand) = .empty,

    /// Clear all four buffers, retaining capacity (upstream `AllocationGroup::clear`).
    pub fn clear(self: *AllocationGroup) void {
        self.path.clearRetainingCapacity();
        self.render_tasks.clearRetainingCapacity();
        self.strips.clearRetainingCapacity();
        self.recorded_commands.clearRetainingCapacity();
    }

    /// Release all four buffers.
    pub fn deinit(self: *AllocationGroup, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        self.render_tasks.deinit(allocator);
        self.strips.deinit(allocator);
        self.recorded_commands.deinit(allocator);
    }

    /// Release the masks of every unprocessed task and unrecorded command
    /// (abort path only; the normal path moves both into the recorder).
    pub fn releaseResources(self: *AllocationGroup, allocator: std.mem.Allocator) void {
        for (self.render_tasks.items) |*task| task.releaseResources(allocator);
        for (self.recorded_commands.items) |*command| command.releaseResources(allocator);
    }
};

test "allocation group clear and release resources" {
    const allocator = std.testing.allocator;

    var group = AllocationGroup{};
    defer group.deinit(allocator);

    var mask = try Mask.fromParts(allocator, &[_]u8{255}, 1, 1);
    try group.render_tasks.append(allocator, .{ .fill_path = .{
        .path_range = .{ .start = 0, .end = 0 },
        .transform = kurbo.Affine.IDENTITY,
        .paint = Paint.fromAlphaColor(peniko.Color.BLACK),
        .fill_rule = .non_zero,
        .blend_mode = peniko.BlendMode.default,
        .aliasing_threshold = null,
        .mask = mask,
    } });
    mask = try Mask.fromParts(allocator, &[_]u8{255}, 1, 1);
    try group.recorded_commands.append(allocator, .{ .push_layer = .{
        .thread_id = 0,
        .clip_path = null,
        .clip_bbox = null,
        .blend_mode = peniko.BlendMode.default,
        .opacity = 1.0,
        .mask = mask,
    } });

    // Releasing twice must not double-free: the handles are nulled.
    group.releaseResources(allocator);
    group.releaseResources(allocator);
    group.clear();
    try std.testing.expectEqual(@as(usize, 0), group.render_tasks.items.len);
    try std.testing.expectEqual(@as(usize, 0), group.recorded_commands.items.len);
}

test "owned clip copies outlive the source and round-trips a path data ref" {
    const allocator = std.testing.allocator;

    const strips = [_]Strip{Strip.new(0, 0, 0, false)};
    const source = PathDataRef{
        .strips = &strips,
        .alphas = &[_]u8{1},
        .bbox = RectU16.new(0, 0, 4, 4),
    };

    const clip = try OwnedClip.dupe(allocator, source);
    defer clip.deinit(allocator);

    const borrowed = clip.asPathDataRef();
    try std.testing.expectEqual(@as(usize, 1), borrowed.strips.len);
    try std.testing.expectEqual(@as(usize, 1), borrowed.alphas.len);
    try std.testing.expectEqual(RectU16.new(0, 0, 4, 4), borrowed.bbox);
    try std.testing.expect(borrowed.strips.ptr != source.strips.ptr);
}
