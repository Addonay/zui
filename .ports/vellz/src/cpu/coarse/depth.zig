//! Port of vello_cpu src/coarse/depth.rs (Apache-2.0 OR MIT).
//!
//! CPU-based depth buffers.
//!
//! Unlike GPUs, a per-pixel depth buffer is not feasible on the CPU. Vertically,
//! one depth entry covers a range of `Tile::HEIGHT` pixels (all commands run at
//! this height); horizontally the width is `DEPTH_BUCKET_WIDTH`, chosen
//! empirically as a good compromise across paint types.
//!
//! Once all strips have been collected they are split into opaque fills aligned
//! to the depth bucket width, and all other fills. During rasterization the
//! opaque strips are rendered front-to-back, consulting and updating the depth
//! buffer; the remaining strips are rendered back-to-front, again comparing
//! against the depth buffer.
//!
//! Ownership/allocator note: `DepthBuffer` owns its bucket array and takes an
//! explicit allocator in `init`/`deinit`. Callback context values are
//! caller-owned plain values; callbacks are context structs with a `call`
//! method because Zig has no closures.

const std = @import("std");
const util = @import("../util.zig");

pub const Span = util.Span;

/// The tile width the depth buckets are aligned to.
const TILE_WIDTH = util.TILE_WIDTH;

/// Width of a depth bucket in pixels.
pub const DEPTH_BUCKET_WIDTH: u16 = 128;

const DEPTH_BUCKET_TILE_WIDTH: u16 = DEPTH_BUCKET_WIDTH / TILE_WIDTH;

comptime {
    if (DEPTH_BUCKET_WIDTH % TILE_WIDTH != 0) {
        @compileError("depth bucket width must be a multiple of tile width");
    }
}

/// Invoke a callback context object.
///
/// Callbacks are context structs with a `call` method. When `call` returns an
/// error union its errors propagate; plain `void` callbacks produce an empty
/// inferred error set, so every `forEach*` call site uses `try` uniformly.
inline fn invoke(ctx: anytype, arg: anytype) !void {
    const C = @TypeOf(ctx);
    const R = @typeInfo(@TypeOf(C.call)).@"fn".return_type.?;
    if (comptime @typeInfo(R) == .error_union) {
        try ctx.call(arg);
    } else {
        ctx.call(arg);
    }
}

/// A horizontal range in depth-bucket coordinates.
pub const BucketRange = struct {
    /// The first bucket (inclusive).
    start: u16,
    /// The exclusive end bucket.
    end: u16,

    /// Create a new bucket range.
    pub fn new(start: u16, end: u16) BucketRange {
        return .{ .start = start, .end = end };
    }

    /// The pixel span covered by this bucket range.
    pub fn span(self: BucketRange) Span {
        const x = self.start * DEPTH_BUCKET_WIDTH;
        return Span.new(x, (self.end - self.start) * DEPTH_BUCKET_WIDTH);
    }
};

/// A segment of a split opaque span.
pub const DepthSegment = union(enum) {
    /// An opaque span that cannot be tracked in the depth buffer because it is
    /// not aligned to whole depth buckets.
    regular: Span,
    /// An opaque span that is aligned and can therefore be rendered
    /// front-to-back with depth-buffer write enabled.
    opaque_fill: BucketRange,
};

/// Splits a tile-aligned span into regular edge spans and a depth-trackable
/// opaque middle span.
///
/// `cb` is a context struct with a `call(DepthSegment) void` method.
pub fn splitOpaqueSpan(span: Span, cb: anytype) void {
    std.debug.assert(
        span.pixelX() % TILE_WIDTH == 0 and span.pixelEnd() % TILE_WIDTH == 0,
    );

    const x = span.tileX();
    const end = span.tileEnd();
    const aligned_x = nextMultipleOf(x, DEPTH_BUCKET_TILE_WIDTH);
    const aligned_end = (end / DEPTH_BUCKET_TILE_WIDTH) * DEPTH_BUCKET_TILE_WIDTH;

    if (aligned_x >= aligned_end) {
        cb.call(.{ .regular = span });
        return;
    }

    if (x < aligned_x) {
        cb.call(.{ .regular = Span.newTile(x, aligned_x - x) });
    }

    if (aligned_x < aligned_end) {
        cb.call(.{ .opaque_fill = BucketRange.new(
            aligned_x / DEPTH_BUCKET_TILE_WIDTH,
            aligned_end / DEPTH_BUCKET_TILE_WIDTH,
        ) });
    }

    if (aligned_end < end) {
        cb.call(.{ .regular = Span.newTile(aligned_end, end - aligned_end) });
    }
}

fn nextMultipleOf(value: u16, multiple: u16) u16 {
    if (value % multiple == 0) return value;
    // Both operands are small (tile units), so this cannot overflow.
    return value + (multiple - value % multiple);
}

/// Coarse state for the depth buffer.
pub const DepthState = struct {
    /// Coarse union of all depth-tracked opaque spans in this row.
    bounds: ?Span = null,
    /// Maximum draw ID of any depth-trackable opaque command in this row.
    ///
    /// Draw IDs start at 1, so 0 represents "no opaque command".
    max_draw_id: u32 = 0,

    /// Reset to the empty state (upstream `Default`).
    pub fn reset(self: *DepthState) void {
        self.* = .{};
    }

    /// Include a depth-tracked opaque span in the coarse bounds.
    pub fn includeSpan(self: *DepthState, span: Span, draw_id: u32) void {
        if (self.bounds) |*bounds| {
            bounds.extend(span);
        } else {
            self.bounds = span;
        }

        self.max_draw_id = @max(self.max_draw_id, draw_id);
    }

    /// Returns whether this draw can skip consulting the depth buffer.
    ///
    /// This is the case when there is no overlap between the span and the
    /// coarse span of the current depth buffer.
    pub fn canSkip(self: DepthState, span: Span, draw_id: u32) bool {
        if (draw_id >= self.max_draw_id) {
            return true;
        }

        const opaque_bounds = self.bounds orelse return true;

        const opaque_start = opaque_bounds.tileX();
        const opaque_end = opaque_bounds.tileEnd();
        const x = span.tileX();
        const end = span.tileEnd();

        return x >= opaque_end or end <= opaque_start;
    }
};

/// Coarse depth buffer storing the maximum draw ID per depth bucket.
///
/// Entries of 0 mean "no opaque content written here yet".
pub const DepthBuffer = struct {
    /// One entry per `DEPTH_BUCKET_WIDTH` pixels, or fewer at the right edge.
    data: std.ArrayList(u32),

    /// Create a depth buffer for a target of `buffer_width` pixels.
    pub fn init(allocator: std.mem.Allocator, buffer_width: u16) std.mem.Allocator.Error!DepthBuffer {
        var data = std.ArrayList(u32).empty;
        errdefer data.deinit(allocator);
        try data.resize(allocator, divCeilUsize(buffer_width, DEPTH_BUCKET_WIDTH));
        @memset(data.items, 0);
        return .{ .data = data };
    }

    /// Release the bucket storage.
    pub fn deinit(self: *DepthBuffer, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = undefined;
    }

    /// Calls `ctx.call(span)` for every subspan of `span` that is not covered
    /// by any entry in the depth buffer.
    pub fn forEachUnsetRun(self: *const DepthBuffer, span: Span, ctx: anytype) !void {
        const bucket_range = self.range(span);
        var idx = bucket_range[0];
        const depth_end = bucket_range[1];
        while (self.nextUnsetRun(&idx, depth_end, span)) |run| {
            try invoke(ctx, run.span);
        }
    }

    /// Calls `ctx.call(bucket_range)` for every bucket run in `bucket_range`
    /// that is not covered by any entry in the depth buffer, and then marks the
    /// newly covered buckets in the depth buffer.
    pub fn forEachUnsetRunAndWrite(self: *DepthBuffer, bucket_range: BucketRange, draw_id: u32, ctx: anytype) !void {
        const bounds = bucket_range.span();
        var idx: usize = bucket_range.start;
        const depth_end: usize = bucket_range.end;

        while (self.nextUnsetRun(&idx, depth_end, bounds)) |run| {
            try invoke(ctx, BucketRange.new(@intCast(run.start), @intCast(run.end)));
            self.mark(run.start, run.end, draw_id);
        }
    }

    /// Calls `ctx.call(span)` for every subspan of `span` that should be
    /// considered as visible assuming the given draw ID.
    pub fn forEachVisibleRun(self: *const DepthBuffer, span: Span, draw_id: u32, ctx: anytype) !void {
        const bucket_range = self.range(span);
        var idx = bucket_range[0];
        const depth_end = bucket_range[1];

        while (self.nextVisibleRun(&idx, depth_end, draw_id, span)) |visible| {
            try invoke(ctx, visible);
        }
    }

    /// Returns the depth-bucket index range touched by `span`.
    fn range(self: *const DepthBuffer, span: Span) [2]usize {
        const start = @as(usize, span.pixelX() / DEPTH_BUCKET_WIDTH);
        const end = @min(
            @as(usize, divCeilU16(span.pixelEnd(), DEPTH_BUCKET_WIDTH)),
            self.data.items.len,
        );
        return .{ start, end };
    }

    /// Reset all buckets to "unset".
    pub fn clear(self: *DepthBuffer) void {
        @memset(self.data.items, 0);
    }

    fn mark(self: *DepthBuffer, start: usize, end: usize, draw_id: u32) void {
        @memset(self.data.items[start..end], draw_id);
    }

    const UnsetRun = struct {
        span: Span,
        start: usize,
        end: usize,
    };

    /// Finds the next consecutive run of unset depth buckets.
    ///
    /// Upstream returns `None` when the run's *bucket span* does not intersect
    /// `bounds` (which can only happen for a run that starts beyond `bounds`);
    /// that behavior is preserved.
    fn nextUnsetRun(self: *const DepthBuffer, idx: *usize, end: usize, bounds: Span) ?UnsetRun {
        while (idx.* < end and self.data.items[idx.*] != 0) {
            idx.* += 1;
        }

        const run_start = idx.*;
        while (idx.* < end and self.data.items[idx.*] == 0) {
            idx.* += 1;
        }

        if (run_start == idx.*) {
            return null;
        }

        const clipped = bucketSpan(run_start, idx.*).intersect(bounds) orelse return null;
        return .{ .span = clipped, .start = run_start, .end = idx.* };
    }

    /// Finds the next consecutive run visible to `draw_id`.
    fn nextVisibleRun(self: *const DepthBuffer, idx: *usize, end: usize, draw_id: u32, bounds: Span) ?Span {
        while (idx.* < end and self.data.items[idx.*] > draw_id) {
            idx.* += 1;
        }

        const run_start = idx.*;
        while (idx.* < end and self.data.items[idx.*] <= draw_id) {
            idx.* += 1;
        }

        if (run_start == idx.*) {
            return null;
        }

        return bucketSpan(run_start, idx.*).intersect(bounds);
    }
};

fn bucketSpan(start: usize, end: usize) Span {
    const x: u16 = @intCast(start * DEPTH_BUCKET_WIDTH);
    const width: u16 = @intCast((end - start) * DEPTH_BUCKET_WIDTH);
    return Span.new(x, width);
}

fn divCeilU16(value: u16, divisor: u16) u16 {
    if (value % divisor == 0) return value / divisor;
    return value / divisor + 1;
}

fn divCeilUsize(value: u16, divisor: u16) usize {
    return @as(usize, divCeilU16(value, divisor));
}

// ---------------------------------------------------------------------------
// Tests (ports of the upstream `#[cfg(test)]` module)
// ---------------------------------------------------------------------------

const testing = std.testing;

const SegmentCollector = struct {
    segments: *std.ArrayList(DepthSegment),
    fn call(self: @This(), segment: DepthSegment) void {
        self.segments.append(testing.allocator, segment) catch unreachable;
    }
};

const SpanCollector = struct {
    spans: *std.ArrayList(Span),
    fn call(self: @This(), span: Span) void {
        self.spans.append(testing.allocator, span) catch unreachable;
    }
};

const PairCollector = struct {
    runs: *std.ArrayList([2]usize),
    fn call(self: @This(), span: Span) void {
        self.runs.append(testing.allocator, .{
            @as(usize, span.pixelX() / DEPTH_BUCKET_WIDTH),
            @as(usize, span.pixelEnd() / DEPTH_BUCKET_WIDTH),
        }) catch unreachable;
    }
};

const NoopBucketCollector = struct {
    fn call(_: @This(), _: BucketRange) void {}
};

fn buffer(allocator: std.mem.Allocator, bucket_count: usize) !DepthBuffer {
    return DepthBuffer.init(allocator, @as(u16, @intCast(bucket_count)) * DEPTH_BUCKET_WIDTH);
}

fn buckets(start: usize, end: usize) Span {
    return bucketSpan(start, end);
}

fn visibleRuns(allocator: std.mem.Allocator, depth: *const DepthBuffer, span: Span, draw_id: u32) !std.ArrayList([2]usize) {
    var runs = std.ArrayList([2]usize).empty;
    errdefer runs.deinit(allocator);
    try depth.forEachVisibleRun(span, draw_id, PairCollector{ .runs = &runs });
    return runs;
}

fn unsetRuns(allocator: std.mem.Allocator, depth: *const DepthBuffer, span: Span) !std.ArrayList([2]usize) {
    var runs = std.ArrayList([2]usize).empty;
    errdefer runs.deinit(allocator);
    try depth.forEachUnsetRun(span, PairCollector{ .runs = &runs });
    return runs;
}

fn writeBuckets(depth: *DepthBuffer, start: usize, end: usize, draw_id: u32) !void {
    try depth.forEachUnsetRunAndWrite(
        BucketRange.new(@intCast(start), @intCast(end)),
        draw_id,
        NoopBucketCollector{},
    );
}

fn expectRuns(expected: []const [2]usize, actual: *const std.ArrayList([2]usize)) !void {
    try testing.expectEqualSlices([2]usize, expected, actual.items);
}

test "split_opaque_span_extracts_aligned_middle" {
    const allocator = testing.allocator;
    var segments = std.ArrayList(DepthSegment).empty;
    defer segments.deinit(allocator);

    splitOpaqueSpan(Span.new(4, DEPTH_BUCKET_WIDTH * 3), SegmentCollector{ .segments = &segments });

    try testing.expectEqual(@as(usize, 3), segments.items.len);
    try testing.expectEqual(
        DepthSegment{ .regular = Span.new(4, DEPTH_BUCKET_WIDTH - 4) },
        segments.items[0],
    );
    try testing.expectEqual(
        DepthSegment{ .opaque_fill = BucketRange.new(1, 3) },
        segments.items[1],
    );
    try testing.expectEqual(
        DepthSegment{ .regular = Span.new(DEPTH_BUCKET_WIDTH * 3, 4) },
        segments.items[2],
    );
}

test "depth_state_skips_when_no_later_overlapping_opaque_draw_exists" {
    var state = DepthState{};
    const opaque_span = buckets(1, 2);
    state.includeSpan(opaque_span, 7);

    try testing.expect(state.canSkip(buckets(0, 1), 1));
    try testing.expect(state.canSkip(opaque_span, 7));
    try testing.expect(!state.canSkip(opaque_span, 6));

    state.reset();
    try testing.expect(state.canSkip(opaque_span, 1));
}

test "visible_runs_skip_interleaved_later_draws" {
    const allocator = testing.allocator;
    var depth = try buffer(allocator, 5);
    defer depth.deinit(allocator);

    try writeBuckets(&depth, 1, 2, 10);
    try writeBuckets(&depth, 3, 4, 10);

    var visible = try visibleRuns(allocator, &depth, buckets(0, 5), 9);
    defer visible.deinit(allocator);
    try expectRuns(&[_][2]usize{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 } }, &visible);

    var all = try visibleRuns(allocator, &depth, buckets(0, 5), 10);
    defer all.deinit(allocator);
    try expectRuns(&[_][2]usize{.{ 0, 5 }}, &all);
}

test "unset_runs_and_writes_fill_interleaved_gaps" {
    const allocator = testing.allocator;
    var depth = try buffer(allocator, 5);
    defer depth.deinit(allocator);

    try writeBuckets(&depth, 1, 2, 10);
    try writeBuckets(&depth, 3, 4, 10);

    var unset = try unsetRuns(allocator, &depth, buckets(0, 5));
    defer unset.deinit(allocator);
    try expectRuns(&[_][2]usize{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 } }, &unset);

    const WrittenCollector = struct {
        runs: *std.ArrayList([2]usize),
        fn call(self: @This(), range: BucketRange) void {
            self.runs.append(testing.allocator, .{
                @as(usize, range.start),
                @as(usize, range.end),
            }) catch unreachable;
        }
    };

    var written = std.ArrayList([2]usize).empty;
    defer written.deinit(allocator);
    try depth.forEachUnsetRunAndWrite(
        BucketRange.new(0, 5),
        7,
        WrittenCollector{ .runs = &written },
    );
    try expectRuns(&[_][2]usize{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 } }, &written);

    try testing.expectEqualSlices(u32, &[_]u32{ 7, 10, 7, 10, 7 }, depth.data.items);
}

test "visible_and_unset_runs_are_limited_to_the_requested_span" {
    const allocator = testing.allocator;
    var depth = try buffer(allocator, 6);
    defer depth.deinit(allocator);

    try writeBuckets(&depth, 1, 2, 10);
    try writeBuckets(&depth, 4, 5, 10);

    var visible = try visibleRuns(allocator, &depth, buckets(2, 5), 9);
    defer visible.deinit(allocator);
    try expectRuns(&[_][2]usize{.{ 2, 4 }}, &visible);

    var unset = try unsetRuns(allocator, &depth, buckets(2, 5));
    defer unset.deinit(allocator);
    try expectRuns(&[_][2]usize{.{ 2, 4 }}, &unset);
}

test "unset_runs_clip_to_unaligned_requested_span" {
    const allocator = testing.allocator;
    var depth = try buffer(allocator, 3);
    defer depth.deinit(allocator);

    const span = Span.new(7, DEPTH_BUCKET_WIDTH + 13);
    const PixelSpanCollector = struct {
        runs: *std.ArrayList([2]u16),
        fn call(self: @This(), s: Span) void {
            self.runs.append(testing.allocator, .{ s.pixelX(), s.pixelEnd() }) catch unreachable;
        }
    };

    var runs = std.ArrayList([2]u16).empty;
    defer runs.deinit(allocator);
    try depth.forEachUnsetRun(span, PixelSpanCollector{ .runs = &runs });

    try testing.expectEqualSlices([2]u16, &[_][2]u16{
        .{ 7, DEPTH_BUCKET_WIDTH + 20 },
    }, runs.items);
}

test "visible_runs_only_skip_buckets_with_later_draw_ids" {
    const allocator = testing.allocator;
    var depth = try buffer(allocator, 6);
    defer depth.deinit(allocator);

    try writeBuckets(&depth, 0, 1, 4);
    try writeBuckets(&depth, 1, 2, 9);
    try writeBuckets(&depth, 2, 3, 6);
    try writeBuckets(&depth, 3, 4, 12);
    try writeBuckets(&depth, 5, 6, 2);

    var visible = try visibleRuns(allocator, &depth, buckets(0, 6), 6);
    defer visible.deinit(allocator);
    try expectRuns(&[_][2]usize{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 6 } }, &visible);
}

test "clear_resets_all_buckets" {
    const allocator = testing.allocator;
    var depth = try buffer(allocator, 3);
    defer depth.deinit(allocator);

    try writeBuckets(&depth, 0, 3, 10);
    depth.clear();

    try testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0 }, depth.data.items);
}

test "depth_buffer_clamps_to_buffer_width" {
    const allocator = testing.allocator;
    var depth = try DepthBuffer.init(allocator, 10);
    defer depth.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), depth.data.items.len);

    var runs = std.ArrayList(Span).empty;
    defer runs.deinit(allocator);
    try depth.forEachUnsetRun(Span.new(0, 200), SpanCollector{ .spans = &runs });
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(Span.new(0, DEPTH_BUCKET_WIDTH), runs.items[0]);
}

test "bucket_range_span" {
    try testing.expectEqual(Span.new(256, 128), BucketRange.new(2, 3).span());
}
