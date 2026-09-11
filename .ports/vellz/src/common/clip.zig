//! Port of vello_common clip.rs (Apache-2.0 OR MIT).
//!
//! Clip state management: `ClipContext` owns the strip storage of the active
//! clip stack, `ClipState` wraps it with the raw path data and the root
//! viewport frames needed to rebuild the clip context when a filter layer
//! shifts the coordinate system.
//!
//! Cycle-split note: upstream `clip.rs` also owns the strip intersection
//! algorithm and `PathDataRef`; in this port those live in
//! `common/intersect.zig` and `common/strip_storage.zig` (see
//! `docs/port-contracts.md`). `intersect` is re-exported here so upstream
//! call sites keep working.
//!
//! Error policy: upstream `pop_clip`/`pop_root_viewport` panic on stack
//! underflow; this port returns `error.ClipStackUnderflow` /
//! `error.RootViewportStackUnderflow`. Allocation failure propagates
//! (`error.OutOfMemory`); every mutating operation reserves its output
//! capacity before publishing state, so a failed push/pop leaves the clip
//! stack unchanged. A failed rebuild leaves the active context empty (never
//! partially applied), and the caller is expected to abort the render.
//!
//! Allocator contract: `ClipContext`/`ClipState` own their storage and take
//! an explicit allocator on `init`-adjacent operations, `deinit`, and every
//! operation that can grow a buffer. The pool of reusable clip contexts is a
//! pure allocation optimization; if returning a context to it fails the
//! context is freed instead of leaked.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const geometry = @import("geometry.zig");
const intersect_mod = @import("intersect.zig");
const strip = @import("strip.zig");
const strip_generator = @import("strip_generator.zig");
const strip_storage = @import("strip_storage.zig");
const util = @import("util.zig");

const Fill = peniko.Fill;
const RectU16 = geometry.RectU16;
const Strip = strip.Strip;
const StripGenerator = strip_generator.StripGenerator;
const StripStorage = strip_storage.StripStorage;

/// Borrowed data of a stripped path (owned by `strip_storage.zig`; re-exported
/// here to match the upstream `clip::PathDataRef` import path).
pub const PathDataRef = strip_storage.PathDataRef;

/// Compute the sparse strips representation of the intersection of the two
/// input paths (owned by `intersect.zig`; re-exported to match upstream).
pub const intersect = intersect_mod.intersect;

/// Errors from the clip stack operations.
pub const Error = error{
    ClipStackUnderflow,
    RootViewportStackUnderflow,
    /// A generated clip path failed with an error outside the allocator set.
    /// `flatten`'s callback ABI types its errors as `anyerror`; this variant
    /// keeps such an error visible instead of dropping it.
    ClipGenerationFailed,
} || std.mem.Allocator.Error;

/// `slice::get(start..).unwrap_or(&[])`: an empty slice when `start` is out of
/// bounds.
fn sliceFrom(comptime T: type, items: []const T, start: u32) []const T {
    const idx: usize = @intCast(start);
    if (idx <= items.len) return items[idx..];
    return items[0..0];
}

/// The location of one clip path's data in the clip context's storage.
const ClipData = struct {
    alpha_start: u32,
    strip_start: u32,

    /// A coarse bounding box of the clip path in pixel coordinates.
    ///
    /// These bounds have already been intersected with the viewport.
    bbox: RectU16,

    fn toPathDataRef(self: ClipData, storage: *const StripStorage) PathDataRef {
        return .{
            .strips = sliceFrom(Strip, storage.strips.items, self.strip_start),
            .alphas = sliceFrom(u8, storage.alphas.items, self.alpha_start),
            .bbox = self.bbox,
        };
    }
};

/// A context for managing clip stacks.
pub const ClipContext = struct {
    /// The strips and alphas of all active clip paths. Always in `append`
    /// generation mode.
    storage: StripStorage,
    /// Scratch storage used while generating a new clip path.
    temp_storage: StripStorage,
    /// One entry per pushed clip path.
    clip_stack: std.ArrayList(ClipData),

    /// Create a new clip context.
    pub fn init() ClipContext {
        var main_storage = StripStorage.initDefault();
        main_storage.setGenerationMode(.append);
        return .{
            .storage = main_storage,
            .temp_storage = StripStorage.initDefault(),
            .clip_stack = .empty,
        };
    }

    /// Release both storages and the clip stack.
    pub fn deinit(self: *ClipContext, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
        self.temp_storage.deinit(allocator);
        self.clip_stack.deinit(allocator);
        self.* = undefined;
    }

    /// `Clear` implementation for `util.Pool` (upstream `impl Clear for
    /// ClipContext`).
    pub fn clear(self: *ClipContext) void {
        self.reset();
    }

    /// Reset the clip context, keeping allocated capacity.
    pub fn reset(self: *ClipContext) void {
        self.clip_stack.clearRetainingCapacity();
        self.storage.clear();
        self.temp_storage.clear();
    }

    /// Get the data of the current clip path.
    pub fn get(self: *const ClipContext) ?PathDataRef {
        if (self.clip_stack.items.len == 0) return null;
        return self.clip_stack.items[self.clip_stack.items.len - 1].toPathDataRef(&self.storage);
    }

    /// Push a new clip path to the stack.
    ///
    /// The new clip is generated into `strip_generator` as a filled path
    /// intersected with the current clip, then appended to `storage`.
    pub fn pushClip(
        self: *ClipContext,
        allocator: std.mem.Allocator,
        clip_path: []const kurbo.PathEl,
        strip_generator_ptr: *StripGenerator,
        fill_rule: Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
    ) Error!void {
        self.temp_storage.clear();

        const alpha_start: u32 = @truncate(self.storage.alphas.items.len);
        const strip_start: u32 = @truncate(self.storage.strips.items.len);

        const existing_clip = self.get();

        strip_generator_ptr.generateFilledPath(
            allocator,
            clip_path,
            fill_rule,
            transform,
            aliasing_threshold,
            &self.temp_storage,
            existing_clip,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The generator's error set is `anyerror` because `flatten`'s
            // callback ABI is untyped; the generation path can only produce
            // allocation errors. Surface anything else rather than dropping
            // it.
            else => return error.ClipGenerationFailed,
        };

        const bbox = strip.stripBbox(self.temp_storage.strips.items) orelse RectU16.ZERO;
        const clip_data = ClipData{
            .alpha_start = alpha_start,
            .strip_start = strip_start,
            .bbox = bbox,
        };

        // Reserve the stack slot first, so the storage extension and the
        // stack push cannot fail independently.
        try self.clip_stack.ensureUnusedCapacity(allocator, 1);
        try self.storage.extend(allocator, &self.temp_storage);
        self.clip_stack.appendAssumeCapacity(clip_data);
    }

    /// Pop the most recent clip path.
    pub fn popClip(self: *ClipContext) Error!void {
        const data = self.clip_stack.pop() orelse return error.ClipStackUnderflow;

        const strips_len: usize = self.storage.strips.items.len;
        const alphas_len: usize = self.storage.alphas.items.len;
        self.storage.strips.shrinkRetainingCapacity(@min(@as(usize, data.strip_start), strips_len));
        self.storage.alphas.shrinkRetainingCapacity(@min(@as(usize, data.alpha_start), alphas_len));
    }
};

/// Raw data of a previously pushed clip path.
const RawClip = struct {
    /// The range of elements in `ClipState.path_elements` belonging to this
    /// clip path. Upstream stores a `Range<usize>`; Zig keeps the two bounds.
    path_start: usize,
    path_end: usize,
    fill_rule: Fill,
    transform: kurbo.Affine,
    aliasing_threshold: ?u8,
};

/// A frame containing clipping-relevant state for the root layer or a filter
/// layer.
const ClipFrame = struct {
    /// The clip context of the parent.
    parent_context: ClipContext,
    /// The accumulated source shift of the current layer.
    source_shift: kurbo.Affine,
    /// The current revision of the clipping state.
    clip_revision: u64,
};

/// State for managing clip paths across multiple viewports.
///
/// This wrapper exists because clips are eagerly flattened into strips against
/// the viewport they were pushed in, so when a filter layer shifts the
/// coordinate system the clip context has to be regenerated for that layer.
pub const ClipState = struct {
    /// The currently active clip context.
    context: ClipContext,
    /// A pool of reusable clip contexts.
    context_pool: util.Pool(ClipContext),
    /// A flat buffer of path elements storing the original path data of clip
    /// paths.
    path_elements: std.ArrayList(kurbo.PathEl),
    /// Raw data of the currently active stack of clip paths.
    raw_clips: std.ArrayList(RawClip),
    /// Stack of pushed clip frames.
    frames: std.ArrayList(ClipFrame),
    /// The current revision.
    revision: u64,

    /// Create a new clip state.
    pub fn init() ClipState {
        return .{
            .context = ClipContext.init(),
            .context_pool = util.Pool(ClipContext).init(true),
            .path_elements = .empty,
            .raw_clips = .empty,
            .frames = .empty,
            .revision = 0,
        };
    }

    /// Release the context, the pooled contexts, and all frames.
    pub fn deinit(self: *ClipState, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        for (self.context_pool.entries.items) |*entry| {
            entry.deinit(allocator);
        }
        self.context_pool.deinit(allocator);
        for (self.frames.items) |*frame| {
            frame.parent_context.deinit(allocator);
        }
        self.path_elements.deinit(allocator);
        self.raw_clips.deinit(allocator);
        self.frames.deinit(allocator);
        self.* = undefined;
    }

    /// Return the current clip path.
    pub fn get(self: *const ClipState) ?PathDataRef {
        return self.context.get();
    }

    /// Push a new root viewport.
    ///
    /// The active clip context is replaced by a fresh one rebuilt for the new
    /// accumulated `source_shift`; on failure the parent context is restored
    /// and the frame is not pushed.
    pub fn pushRootViewport(
        self: *ClipState,
        allocator: std.mem.Allocator,
        source_shift: [2]u16,
        strip_generator_ptr: *StripGenerator,
    ) Error!void {
        try self.frames.ensureUnusedCapacity(allocator, 1);

        const parent_context = self.context;
        self.context = self.context_pool.take(ClipContext.init());

        const shift_translation = kurbo.Affine.translate(kurbo.Vec2.new(
            @floatFromInt(source_shift[0]),
            @floatFromInt(source_shift[1]),
        ));
        const shift = shift_translation.compose(self.activeShift());
        self.frames.appendAssumeCapacity(.{
            .parent_context = parent_context,
            .source_shift = shift,
            .clip_revision = self.revision,
        });

        self.rebuildContext(allocator, strip_generator_ptr) catch |err| {
            // Roll back so the caller sees an unchanged clip stack.
            const failed_context = self.context;
            _ = self.frames.pop();
            self.context = parent_context;
            self.submitContext(allocator, failed_context);
            return err;
        };
    }

    /// Pop the last root viewport.
    ///
    /// If clip paths were pushed or popped since the frame was created, the
    /// parent context is rebuilt; otherwise it is reused as-is.
    pub fn popRootViewport(
        self: *ClipState,
        allocator: std.mem.Allocator,
        strip_generator_ptr: *StripGenerator,
    ) Error!void {
        const frame = self.frames.pop() orelse return error.RootViewportStackUnderflow;

        const filter_context = self.context;
        self.context = frame.parent_context;
        self.submitContext(allocator, filter_context);

        if (self.revision != frame.clip_revision) {
            try self.rebuildContext(allocator, strip_generator_ptr);
        }
    }

    /// Push a clip path.
    pub fn pushClip(
        self: *ClipState,
        allocator: std.mem.Allocator,
        path: []const kurbo.PathEl,
        strip_generator_ptr: *StripGenerator,
        fill_rule: Fill,
        transform: kurbo.Affine,
        aliasing_threshold: ?u8,
    ) Error!void {
        const path_start = self.path_elements.items.len;

        // Reserve the path elements and the raw clip up front so the context
        // push and the raw-clip publication cannot fail independently.
        try self.path_elements.ensureUnusedCapacity(allocator, path.len);
        try self.raw_clips.ensureUnusedCapacity(allocator, 1);
        self.path_elements.appendSliceAssumeCapacity(path);
        errdefer self.path_elements.shrinkRetainingCapacity(path_start);
        const path_end = self.path_elements.items.len;

        const clip_transform = self.activeShift().compose(transform);

        try self.context.pushClip(
            allocator,
            self.path_elements.items[path_start..path_end],
            strip_generator_ptr,
            fill_rule,
            clip_transform,
            aliasing_threshold,
        );

        self.raw_clips.appendAssumeCapacity(.{
            .path_start = path_start,
            .path_end = path_end,
            .fill_rule = fill_rule,
            .transform = transform,
            .aliasing_threshold = aliasing_threshold,
        });
        self.revision +%= 1;
    }

    /// Pop the active clip path.
    pub fn popClip(self: *ClipState) Error!void {
        if (self.raw_clips.items.len == 0) return error.ClipStackUnderflow;

        // Pop the context first so an inconsistent stack cannot truncate the
        // raw path buffer.
        try self.context.popClip();

        const raw_clip = self.raw_clips.items[self.raw_clips.items.len - 1];
        self.raw_clips.shrinkRetainingCapacity(self.raw_clips.items.len - 1);
        self.path_elements.shrinkRetainingCapacity(raw_clip.path_start);
        self.revision +%= 1;
    }

    /// Reset the clip state.
    pub fn reset(self: *ClipState, allocator: std.mem.Allocator) void {
        self.context.reset();
        for (self.frames.items) |*frame| {
            self.submitContext(allocator, frame.parent_context);
        }
        self.frames.clearRetainingCapacity();
        self.path_elements.clearRetainingCapacity();
        self.raw_clips.clearRetainingCapacity();
        self.revision = 0;
    }

    fn activeShift(self: *const ClipState) kurbo.Affine {
        if (self.frames.items.len == 0) return kurbo.Affine.IDENTITY;
        return self.frames.items[self.frames.items.len - 1].source_shift;
    }

    fn rebuildContext(
        self: *ClipState,
        allocator: std.mem.Allocator,
        strip_generator_ptr: *StripGenerator,
    ) Error!void {
        self.context.reset();
        // A failed rebuild must not leave a partially applied clip stack.
        errdefer self.context.reset();

        const active_shift = self.activeShift();
        for (self.raw_clips.items) |raw_clip| {
            try self.context.pushClip(
                allocator,
                self.path_elements.items[raw_clip.path_start..raw_clip.path_end],
                strip_generator_ptr,
                raw_clip.fill_rule,
                active_shift.compose(raw_clip.transform),
                raw_clip.aliasing_threshold,
            );
        }
    }

    /// Return a context to the pool, freeing it if the pool cannot retain it.
    ///
    /// The pool is only an optimization, so a failed submission is not an
    /// error; the context's allocations are released instead of leaked.
    fn submitContext(self: *ClipState, allocator: std.mem.Allocator, context: ClipContext) void {
        var entry = context;
        self.context_pool.submit(allocator, entry) catch {
            entry.deinit(allocator);
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// Upstream has no `#[cfg(test)]` in the parts of `clip.rs` ported here (its
// tests cover the intersection algorithm, ported in `intersect.zig`). These
// are the focused tests required by the port plan.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "clip context push pop and empty path" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 64, 64, .baseline);
    defer generator.deinit(allocator);
    var ctx = ClipContext.init();
    defer ctx.deinit(allocator);

    try testing.expect(ctx.get() == null);

    var path = try kurbo.Rect.new(4.0, 4.0, 20.0, 20.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try ctx.pushClip(
        allocator,
        path.elementsSlice(),
        &generator,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );

    const data = ctx.get() orelse return error.TestUnexpectedResult;
    try testing.expect(data.strips.len > 0);
    // Tile-aligned coarse bbox; the right-edge marker strip extends it by one
    // tile (the path's right edge is at x = 20).
    try testing.expectEqual(RectU16.new(4, 4, 24, 20), data.bbox);
    try testing.expectEqual(data.bbox, strip.stripBbox(ctx.storage.strips.items).?);

    try ctx.popClip();
    try testing.expect(ctx.get() == null);
    try testing.expect(ctx.storage.isEmpty());

    // An empty path still pushes a clip entry (upstream `unwrap_or(ZERO)`).
    try ctx.pushClip(allocator, &.{}, &generator, .non_zero, kurbo.Affine.IDENTITY, null);
    const empty = ctx.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), empty.strips.len);
    try testing.expectEqual(RectU16.ZERO, empty.bbox);
    try ctx.popClip();
    try testing.expect(ctx.get() == null);
}

test "nested clips shrink the region" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 64, 64, .baseline);
    defer generator.deinit(allocator);
    var ctx = ClipContext.init();
    defer ctx.deinit(allocator);

    var outer_path = try kurbo.Rect.new(0.0, 0.0, 16.0, 16.0).toPath(0.1, allocator);
    defer outer_path.deinit(allocator);
    var inner_path = try kurbo.Rect.new(4.0, 4.0, 12.0, 12.0).toPath(0.1, allocator);
    defer inner_path.deinit(allocator);

    try ctx.pushClip(
        allocator,
        outer_path.elementsSlice(),
        &generator,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    const outer = ctx.get() orelse return error.TestUnexpectedResult;
    const outer_bbox = outer.bbox;

    try ctx.pushClip(
        allocator,
        inner_path.elementsSlice(),
        &generator,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    const inner = ctx.get() orelse return error.TestUnexpectedResult;

    // The inner 4..12 rect wins over the outer 0..16 rect.
    try testing.expectEqual(RectU16.new(4, 4, 16, 12), inner.bbox);
    try testing.expect(inner.strips.len > 0);
    try testing.expect(inner.bbox.x0 >= outer_bbox.x0);
    try testing.expect(inner.bbox.y0 >= outer_bbox.y0);
    try testing.expect(inner.bbox.x1 <= outer_bbox.x1);
    try testing.expect(inner.bbox.y1 <= outer_bbox.y1);

    // The stored clip data is the intersection, not the raw inner path.
    try testing.expectEqual(inner.bbox, strip.stripBbox(ctx.storage.strips.items[ctx.storage.strips.items.len - inner.strips.len ..]).?);

    try ctx.popClip();
    const restored = ctx.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(outer_bbox, restored.bbox);
    try testing.expectEqual(outer.strips.len, restored.strips.len);
    try testing.expectEqual(outer.alphas.len, restored.alphas.len);

    try ctx.popClip();
    try testing.expect(ctx.get() == null);
}

test "clip state push and pop with transform" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 64, 64, .baseline);
    defer generator.deinit(allocator);
    var state = ClipState.init();
    defer state.deinit(allocator);

    var path = try kurbo.Rect.new(0.0, 0.0, 8.0, 8.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try state.pushClip(
        allocator,
        path.elementsSlice(),
        &generator,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    const unshifted = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(0, 0, 12, 8), unshifted.bbox);
    try testing.expectEqual(@as(usize, path.elements.items.len), state.path_elements.items.len);
    try testing.expectEqual(@as(usize, 1), state.raw_clips.items.len);

    // The transform is composed after the active shift (identity here).
    const translated = kurbo.Affine.translate(kurbo.Vec2.new(8.0, 0.0));
    try state.pushClip(
        allocator,
        path.elementsSlice(),
        &generator,
        .non_zero,
        translated,
        null,
    );
    const shifted = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(8, 0, 12, 8), shifted.bbox);

    try state.popClip();
    const restored = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(unshifted.bbox, restored.bbox);
    try testing.expectEqual(@as(usize, path.elements.items.len), state.path_elements.items.len);
    try testing.expectEqual(@as(usize, 1), state.raw_clips.items.len);

    try state.popClip();
    try testing.expect(state.get() == null);
    try testing.expectEqual(@as(usize, 0), state.path_elements.items.len);
    try testing.expectEqual(@as(usize, 0), state.raw_clips.items.len);

    // Underflow is a typed error, and the state is unchanged.
    try testing.expectError(error.ClipStackUnderflow, state.popClip());
}

test "clip state root viewport rebuilds clips with the source shift" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 64, 64, .baseline);
    defer generator.deinit(allocator);
    var state = ClipState.init();
    defer state.deinit(allocator);

    var path = try kurbo.Rect.new(0.0, 0.0, 8.0, 8.0).toPath(0.1, allocator);
    defer path.deinit(allocator);

    try state.pushClip(
        allocator,
        path.elementsSlice(),
        &generator,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    const parent = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(0, 0, 12, 8), parent.bbox);
    const revision_before = state.revision;

    // Pushing a root viewport shifts all clips by the source shift.
    try state.pushRootViewport(allocator, .{ 4, 4 }, &generator);
    const shifted = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(4, 4, 16, 12), shifted.bbox);
    try testing.expectEqual(revision_before, state.revision);

    // A clip pushed inside the shifted viewport is also shifted.
    try state.pushClip(
        allocator,
        path.elementsSlice(),
        &generator,
        .non_zero,
        kurbo.Affine.IDENTITY,
        null,
    );
    const nested = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(4, 4, 16, 12), nested.bbox);

    // Popping the viewport rebuilds the parent context with the identity
    // shift, dropping the nested clip.
    try state.popRootViewport(allocator, &generator);
    try testing.expectEqual(revision_before + 1, state.revision);
    const rebuilt_parent = state.get() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(RectU16.new(0, 0, 12, 8), rebuilt_parent.bbox);

    try testing.expectError(error.RootViewportStackUnderflow, state.popRootViewport(allocator, &generator));

    state.reset(allocator);
    try testing.expect(state.get() == null);
    try testing.expectEqual(@as(usize, 0), state.frames.items.len);
    try testing.expectEqual(@as(u64, 0), state.revision);
}

test "clip state reset returns frames to the pool" {
    const allocator = testing.allocator;

    var generator = StripGenerator.init(allocator, 32, 32, .baseline);
    defer generator.deinit(allocator);
    var state = ClipState.init();
    defer state.deinit(allocator);

    // Push two frames, then reset: the frames' parent contexts must end up
    // in the pool (or be freed), and the state must be reusable.
    try state.pushRootViewport(allocator, .{ 2, 2 }, &generator);
    try state.pushRootViewport(allocator, .{ 2, 2 }, &generator);
    try testing.expectEqual(@as(usize, 2), state.frames.items.len);

    state.reset(allocator);
    try testing.expectEqual(@as(usize, 0), state.frames.items.len);
    try testing.expectEqual(@as(usize, 0), state.path_elements.items.len);
    try testing.expectEqual(@as(usize, 0), state.raw_clips.items.len);
    try testing.expectEqual(@as(usize, 2), state.context_pool.entries.items.len);
    try testing.expect(state.get() == null);
}

test "clip context push clip allocation failure safety" {
    const Runs = struct {
        fn run(allocator: std.mem.Allocator, path: []const kurbo.PathEl) !void {
            var generator = StripGenerator.init(allocator, 64, 64, .baseline);
            defer generator.deinit(allocator);
            var ctx = ClipContext.init();
            defer ctx.deinit(allocator);

            try ctx.pushClip(
                allocator,
                path,
                &generator,
                .non_zero,
                kurbo.Affine.IDENTITY,
                null,
            );
            const first = ctx.get() orelse return error.TestUnexpectedResult;
            try std.testing.expect(first.strips.len > 0);

            // The second push intersects against the first clip, exercising
            // the generator + intersect allocation paths.
            try ctx.pushClip(
                allocator,
                path,
                &generator,
                .non_zero,
                kurbo.Affine.IDENTITY,
                null,
            );
            try ctx.popClip();
            try ctx.popClip();
            try std.testing.expect(ctx.get() == null);
        }
    };

    const rect_els = [_]kurbo.PathEl{
        kurbo.PathEl.moveTo(kurbo.Point.new(2.0, 3.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(30.0, 3.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(30.0, 27.0)),
        kurbo.PathEl.lineTo(kurbo.Point.new(2.0, 27.0)),
        kurbo.PathEl.closePath(),
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runs.run, .{&rect_els});
}
