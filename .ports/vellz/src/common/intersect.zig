//! Port of vello_common clip.rs (Apache-2.0 OR MIT).
//!
//! This file owns the strip-intersection algorithm only; the clip state
//! types (`ClipContext`, `ClipState`, `ClipData`, `RawClip`, `ClipFrame`)
//! live in `common/clip.zig`.
//!
//! Upstream `clip.rs` imports `strip_generator.rs` (`GenerationMode`,
//! `StripGenerator`, `StripStorage`) and vice versa, which Zig cannot express.
//! The split fixed in `docs/port-contracts.md` and `docs/cpu-pipeline.md`
//! keeps the lock-step strip intersection here; `intersect.zig` depends only
//! on strip/tile/geometry/util, and `strip_generator.zig` imports it.
//! `PathDataRef`, `StripStorage`, and `GenerationMode` live in
//! `common/strip_storage.zig`.
//!
//! The algorithm is a direct transcription of upstream `intersect_impl`:
//! row-by-row lock-step iteration over alternating strip and fill regions,
//! with three overlap cases (fill∩fill starts a gap-filled strip, strip∩fill
//! copies the strip alpha mask, strip∩strip multiplies both masks with
//! `util.normalizedMulU8`/`narrow`, equivalent to upstream
//! `normalized_mul_u8` on `u8x16`). The sentinel strip is appended only when
//! the target already contains strips, exactly matching upstream.
//!
//! Allocator contract: `intersect` appends to the caller-owned target storage
//! and takes an explicit allocator. On allocation failure the error
//! propagates and the target holds a valid prefix of the intersection (without
//! a sentinel); callers treat the render as failed.

const std = @import("std");
const simd = @import("../simd/root.zig");
const geometry = @import("geometry.zig");
const strip_mod = @import("strip.zig");
const strip_storage = @import("strip_storage.zig");
const tile_mod = @import("tile.zig");
const util = @import("util.zig");

const PathDataRef = strip_storage.PathDataRef;
const RectU16 = geometry.RectU16;
const Strip = strip_mod.Strip;
const StripStorage = strip_storage.StripStorage;
const Tile = tile_mod.Tile;
const U8x16 = simd.U8x16;

/// One 4-pixel alpha block (a tile column) in bytes.
const ALPHA_BLOCK = @as(usize, Tile.WIDTH) * Tile.HEIGHT;

/// Compute the sparse strips representation of the path that results from
/// intersecting the two input paths. Used to implement clip paths.
///
/// Upstream's `dispatch!(level, ...)` collapses to a direct call in the port
/// (single portable backend).
pub fn intersect(
    allocator: std.mem.Allocator,
    level: simd.Level,
    path_1: PathDataRef,
    path_2: PathDataRef,
    target: *StripStorage,
) !void {
    _ = level;
    try intersectImpl(allocator, path_1, path_2, target);
}

/// The implementation of the clipping algorithm using sparse strips.
///
/// Conceptually: iterate over each strip and fill region of the two paths in
/// lock step and determine all overlaps. For each overlap:
/// - two fill regions: the overlap is filled (a new strip with `fill_gap`);
/// - one strip and one fill region: copy the strip's alpha mask;
/// - two strip regions: multiply both alpha masks.
/// Regions that are not filled in either path are ignored.
fn intersectImpl(
    allocator: std.mem.Allocator,
    path_1: PathDataRef,
    path_2: PathDataRef,
    target: *StripStorage,
) !void {
    // In case either path is empty, the clip path should be empty.
    if (path_1.strips.len == 0 or path_2.strips.len == 0) return;

    // Ignore any y values that are outside the bounding box of either of the
    // two paths, as those are guaranteed to have neither fill nor strip
    // regions.
    const path_1_start_y = path_1.strips[0].stripY();
    const path_2_start_y = path_2.strips[0].stripY();
    var cur_y = @max(path_1_start_y, path_2_start_y);
    const end_y = @min(
        path_1.strips[path_1.strips.len - 1].stripY(),
        path_2.strips[path_2.strips.len - 1].stripY(),
    );

    var path_1_idx: usize = 0;
    var path_2_idx: usize = 0;

    // Use binary search to determine the first index of whichever path has a
    // smaller y to avoid a large linear scan in the first iteration of the
    // loop below in case the discrepancy is large.
    if (path_1_start_y < cur_y) {
        path_1_idx = firstStripAtOrAfter(path_1.strips, cur_y);
    } else if (path_2_start_y < cur_y) {
        path_2_idx = firstStripAtOrAfter(path_2.strips, cur_y);
    }

    var strip_state: ?StripState = null;

    // Iterate over each strip row and handle it.
    while (cur_y <= end_y) : (cur_y += 1) {
        // For each row, create two iterators that alternatingly yield the
        // strips and fill regions in that row, until the last strip has been
        // reached.
        var p1_iter = RowIterator.init(path_1, &path_1_idx, cur_y);
        var p2_iter = RowIterator.init(path_2, &path_2_idx, cur_y);

        var p1_region = p1_iter.next();
        var p2_region = p2_iter.next();

        // If at least one region is null, we reached the end of the row for
        // that path, meaning we exceeded the bounding box of that path and no
        // additional strips should be generated for that row, even if the
        // other path might still have more strips left. They are all clipped
        // away, so only consider it if both paths have a region left.
        while (p1_region != null and p2_region != null) {
            const region_1 = p1_region.?;
            const region_2 = p2_region.?;

            switch (region_1.overlapRelationship(region_2)) {
                // No overlap between the regions, so advance the iterator of
                // the region that is further behind.
                .advance => |advance| {
                    switch (advance) {
                        .left => p1_region = p1_iter.next(),
                        .right => p2_region = p2_iter.next(),
                    }
                    continue;
                },
                // We have an overlap.
                .overlap => |overlap| {
                    switch (region_1) {
                        .fill => switch (region_2) {
                            // Both regions are a fill. Flush the current strip
                            // and start a new one at the end of the overlap
                            // region setting `fill_gap` to true, so that the
                            // whole area before that is filled with a sparse
                            // fill.
                            .fill => {
                                try flushStrip(allocator, &strip_state, &target.strips, cur_y);
                                startStrip(&strip_state, target.alphas.items, overlap.end, true);
                            },
                            // One fill one strip: use the alpha mask from the
                            // strip region.
                            .strip => |s| try copyStripAlphas(
                                allocator,
                                &strip_state,
                                &target.strips,
                                &target.alphas,
                                s,
                                overlap,
                                cur_y,
                            ),
                        },
                        .strip => |s| switch (region_2) {
                            // One fill one strip: use the alpha mask from the
                            // strip region.
                            .fill => try copyStripAlphas(
                                allocator,
                                &strip_state,
                                &target.strips,
                                &target.alphas,
                                s,
                                overlap,
                                cur_y,
                            ),
                            // Two strips: multiply the opacity masks from both
                            // paths.
                            .strip => |s2| try mulStripAlphas(
                                allocator,
                                &strip_state,
                                &target.strips,
                                &target.alphas,
                                s,
                                s2,
                                overlap,
                                cur_y,
                            ),
                        },
                    }

                    // Advance the iterator of the path whose region's end is
                    // further behind.
                    switch (overlap.advance) {
                        .left => p1_region = p1_iter.next(),
                        .right => p2_region = p2_iter.next(),
                    }
                },
            }
        }

        // Flush the strip before advancing to the next strip row.
        try flushStrip(allocator, &strip_state, &target.strips, cur_y);
    }

    // Push the sentinel strip if the intersection is not empty.
    if (target.strips.items.len != 0) {
        try target.strips.append(
            allocator,
            Strip.sentinel(end_y * Tile.HEIGHT, @truncate(target.alphas.items.len)),
        );
    }
}

/// First index whose strip row is at or after `strip_y` (Rust
/// `slice::partition_point`).
fn firstStripAtOrAfter(strips: []const Strip, strip_y: u16) usize {
    // Strips are guaranteed to be sorted in ascending y (and ascending x),
    // hence why we can do this.
    var lo: usize = 0;
    var hi: usize = strips.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (strips[mid].stripY() < strip_y) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// An overlap between two regions.
const Overlap = struct {
    /// The start x coordinate.
    start: u16,
    /// The end x coordinate.
    end: u16,
    /// Whether the left or right region iterator should be advanced next.
    advance: Advance,

    fn width(self: Overlap) u16 {
        return self.end - self.start;
    }
};

const Advance = enum {
    left,
    right,
};

/// The relationship between two regions.
const OverlapRelationship = union(enum) {
    /// There is no overlap between the regions, advance the region iterator on
    /// the given side.
    advance: Advance,
    /// There is an overlap between the regions.
    overlap: Overlap,
};

const FillRegion = struct {
    start: u16,
    width: u16,
};

const StripRegion = struct {
    start: u16,
    width: u16,
    alphas: []const u8,
};

const Region = union(enum) {
    fill: FillRegion,
    strip: StripRegion,

    fn start(self: Region) u16 {
        return switch (self) {
            .fill => |fill| fill.start,
            .strip => |strip| strip.start,
        };
    }

    fn width(self: Region) u16 {
        return switch (self) {
            .fill => |fill| fill.width,
            .strip => |strip| strip.width,
        };
    }

    fn end(self: Region) u16 {
        return self.start() + self.width();
    }

    fn overlapRelationship(self: Region, other: Region) OverlapRelationship {
        if (self.end() <= other.start()) {
            return .{ .advance = .left };
        } else if (self.start() >= other.end()) {
            return .{ .advance = .right };
        } else {
            const overlap_start = @max(self.start(), other.start());
            const overlap_end = @min(self.end(), other.end());

            const shift: Advance = if (self.end() <= other.end()) .left else .right;

            return .{ .overlap = .{
                .advance = shift,
                .start = overlap_start,
                .end = overlap_end,
            } };
        }
    }
};

/// An iterator of strip and fill regions of a single strip row.
const RowIterator = struct {
    /// The path in question.
    input: PathDataRef,
    /// The strip row we want to iterate over.
    strip_y: u16,
    /// The index of the current strip.
    cur_idx: *usize,
    /// Whether the iterator should yield a strip next or not. When iterating
    /// over a row, we alternate between emitting strips and filled regions
    /// (unless the region between two strips is not filled), so this flag acts
    /// as a toggle to store what should be yielded next.
    on_strip: bool,

    fn init(input: PathDataRef, cur_idx: *usize, strip_y: u16) RowIterator {
        std.debug.assert(input.strips.len > 0);
        // Forward the index until we have found the right strip.
        while (input.strips[cur_idx.*].stripY() < strip_y) {
            cur_idx.* += 1;
        }

        return .{
            .input = input,
            .strip_y = strip_y,
            .cur_idx = cur_idx,
            .on_strip = true,
        };
    }

    fn curStrip(self: *const RowIterator) Strip {
        return self.input.strips[self.cur_idx.*];
    }

    fn nextStrip(self: *const RowIterator) Strip {
        return self.input.strips[self.cur_idx.* + 1];
    }

    fn curStripWidth(self: *const RowIterator) u16 {
        const cur = self.curStrip();
        const next_strip = self.nextStrip();
        return @intCast((next_strip.alphaIdx() - cur.alphaIdx()) / Tile.HEIGHT);
    }

    fn curStripAlphas(self: *const RowIterator) []const u8 {
        const cur = self.curStrip();
        const next_strip = self.nextStrip();
        return self.input.alphas[cur.alphaIdx()..next_strip.alphaIdx()];
    }

    fn curStripFillArea(self: *const RowIterator) ?FillRegion {
        const next_strip = self.nextStrip();

        // Note that if the next strip happens to be on the next line, it will
        // always have zero winding so we don't need to special case this.
        if (next_strip.fillGap()) {
            const cur = self.curStrip();
            const x = cur.x + self.curStripWidth();
            const width = next_strip.x - x;

            if (width > 0) {
                return .{ .start = x, .width = width };
            }
        }
        return null;
    }

    fn next(self: *RowIterator) ?Region {
        while (true) {
            // If we are currently not on a strip, yield a filled region in
            // case there is one.
            if (!self.on_strip) {
                // Flip the flag so we will yield a strip in the next
                // iteration.
                self.on_strip = true;

                // If we have a filled area, yield it and return. Otherwise,
                // do nothing and we will instead yield the next strip below.
                // In any case, advance the current index so that we point to
                // the next strip now.
                if (self.curStripFillArea()) |fill_area| {
                    self.cur_idx.* += 1;
                    return .{ .fill = fill_area };
                } else {
                    self.cur_idx.* += 1;
                }
            }

            // If we reached this point, we will yield a strip this iteration,
            // so toggle the flag so that in the next iteration, we yield a
            // filled region instead.
            self.on_strip = false;

            // If the current strip is sentinel or not within our target row,
            // terminate.
            if (self.curStrip().isSentinel() or self.curStrip().stripY() != self.strip_y) {
                return null;
            }

            // Calculate the dimensions of the strip and yield it.
            const x = self.curStrip().x;
            const width = self.curStripWidth();

            // Zero-width strips only act as markers for cheaply delimiting
            // the width of filled regions, but are not actually relevant for
            // clipping. This is assuming that zero-width strips can only
            // appear at the end of a row, see the comment in
            // `Strip::emit_culled_background`.
            if (width == 0) {
                // Upstream debug assertion: zero-width strips must only
                // appear at the end of a row.
                std.debug.assert(
                    self.nextStrip().isSentinel() or self.nextStrip().stripY() != self.strip_y,
                );

                continue;
            }

            return .{ .strip = .{
                .start = x,
                .width = width,
                .alphas = self.curStripAlphas(),
            } };
        }
    }
};

/// The data of the current strip we are building.
const StripState = struct {
    x: u16,
    alpha_idx: u32,
    fill_gap: bool,
};

fn flushStrip(
    allocator: std.mem.Allocator,
    strip_state: *?StripState,
    strips: *std.ArrayList(Strip),
    cur_y: u16,
) !void {
    if (strip_state.*) |state| {
        strip_state.* = null;
        try strips.append(
            allocator,
            Strip.new(state.x, cur_y * Tile.HEIGHT, state.alpha_idx, state.fill_gap),
        );
    }
}

fn startStrip(strip_data: *?StripState, alphas: []const u8, x: u16, fill_gap: bool) void {
    strip_data.* = .{
        .x = x,
        .alpha_idx = @truncate(alphas.len),
        .fill_gap = fill_gap,
    };
}

fn shouldCreateNewStrip(
    strip_state: *const ?StripState,
    alphas: []const u8,
    overlap_start: u16,
) bool {
    // Returns false in case we can append to the currently built strip.
    const state = strip_state.* orelse return true;
    const alpha_len: u32 = @truncate(alphas.len);
    const width: u16 = @intCast((alpha_len - state.alpha_idx) / Tile.HEIGHT);
    const strip_end = state.x + width;

    return strip_end < overlap_start - 1;
}

/// Overlap of one strip and one fill region: copy the strip's alpha mask.
fn copyStripAlphas(
    allocator: std.mem.Allocator,
    strip_state: *?StripState,
    strips: *std.ArrayList(Strip),
    alphas: *std.ArrayList(u8),
    s: StripRegion,
    overlap: Overlap,
    cur_y: u16,
) !void {
    // If possible, don't create a new strip but just extend the current one.
    if (shouldCreateNewStrip(strip_state, alphas.items, overlap.start)) {
        try flushStrip(allocator, strip_state, strips, cur_y);
        startStrip(strip_state, alphas.items, overlap.start, false);
    }

    const offset: usize = @as(usize, overlap.start - s.start) * Tile.HEIGHT;
    const len: usize = @as(usize, overlap.width()) * Tile.HEIGHT;
    try alphas.appendSlice(allocator, s.alphas[offset .. offset + len]);
}

/// Overlap of two strips: multiply the opacity masks from both paths.
fn mulStripAlphas(
    allocator: std.mem.Allocator,
    strip_state: *?StripState,
    strips: *std.ArrayList(Strip),
    alphas: *std.ArrayList(u8),
    s_region_1: StripRegion,
    s_region_2: StripRegion,
    overlap: Overlap,
    cur_y: u16,
) !void {
    // Once again, only create a new strip if we can't extend the current one.
    if (shouldCreateNewStrip(strip_state, alphas.items, overlap.start)) {
        try flushStrip(allocator, strip_state, strips, cur_y);
        startStrip(strip_state, alphas.items, overlap.start, false);
    }

    const num_blocks: usize = overlap.width() / Tile.HEIGHT;

    // Get the right alpha values for the specific position.
    const offset_1: usize = @as(usize, overlap.start - s_region_1.start) * Tile.HEIGHT;
    const offset_2: usize = @as(usize, overlap.start - s_region_2.start) * Tile.HEIGHT;

    var block: usize = 0;
    while (block < num_blocks) : (block += 1) {
        const s1 = simd.fromSlice(U8x16, s_region_1.alphas[offset_1 + block * ALPHA_BLOCK ..][0..ALPHA_BLOCK]);
        const s2 = simd.fromSlice(U8x16, s_region_2.alphas[offset_2 + block * ALPHA_BLOCK ..][0..ALPHA_BLOCK]);

        // Combine them.
        const res = util.narrow(util.normalizedMulU8(s1, s2));
        const bytes: [ALPHA_BLOCK]u8 = res;
        try alphas.appendSlice(allocator, &bytes);
    }
}

// ---------------------------------------------------------------------------
// Tests (ported from upstream `clip.rs` `#[cfg(test)]`)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pathRef(path: *const StripStorage) PathDataRef {
    return .{
        .strips = path.strips.items,
        .alphas = path.alphas.items,
        .bbox = RectU16.new(0, 0, std.math.maxInt(u16), std.math.maxInt(u16)),
    };
}

fn expectStorageEqual(expected: *const StripStorage, actual: *const StripStorage) !void {
    try testing.expectEqual(expected.generation_mode, actual.generation_mode);
    try testing.expectEqualSlices(Strip, expected.strips.items, actual.strips.items);
    try testing.expectEqualSlices(u8, expected.alphas.items, actual.alphas.items);
}

fn runTest(
    allocator: std.mem.Allocator,
    expected: *const StripStorage,
    path_1: *const StripStorage,
    path_2: *const StripStorage,
) !void {
    var write_target = StripStorage.initDefault();
    defer write_target.deinit(allocator);

    try intersect(allocator, .baseline, pathRef(path_1), pathRef(path_2), &write_target);

    try expectStorageEqual(expected, &write_target);
}

fn assertStripRegion(region: ?Region, start: u16, width: u16) !void {
    const actual = region orelse return error.TestUnexpectedResult;
    switch (actual) {
        .strip => |strip| {
            try testing.expectEqual(start, strip.start);
            try testing.expectEqual(width, strip.width);
            try testing.expectEqual(@as(usize, width) * Tile.HEIGHT, strip.alphas.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn assertFillRegion(region: ?Region, start: u16, width: u16) !void {
    const actual = region orelse return error.TestUnexpectedResult;
    switch (actual) {
        .fill => |fill| {
            try testing.expectEqual(start, fill.start);
            try testing.expectEqual(width, fill.width);
        },
        else => return error.TestUnexpectedResult,
    }
}

/// Test builder mirroring upstream's `StripBuilder`; owns one `StripStorage`.
const StripBuilder = struct {
    storage: StripStorage = StripStorage.initDefault(),

    fn deinit(self: *StripBuilder, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }

    fn addStrip(
        self: *StripBuilder,
        allocator: std.mem.Allocator,
        x: u16,
        strip_y: u16,
        end: u16,
        fill_gap: bool,
    ) !void {
        const width = end - x;
        const zeros = try allocator.alloc(u8, @as(usize, width) * Tile.HEIGHT);
        defer allocator.free(zeros);
        @memset(zeros, 0);
        try self.addStripWith(allocator, x, strip_y, end, fill_gap, zeros);
    }

    fn addStripWith(
        self: *StripBuilder,
        allocator: std.mem.Allocator,
        x: u16,
        strip_y: u16,
        end: u16,
        fill_gap: bool,
        alphas: []const u8,
    ) !void {
        const width = end - x;
        try testing.expectEqual(@as(usize, width) * Tile.HEIGHT, alphas.len);
        const idx = self.storage.alphas.items.len;
        try self.storage.strips.append(
            allocator,
            Strip.new(x, strip_y * Tile.HEIGHT, @truncate(idx), fill_gap),
        );
        try self.storage.alphas.appendSlice(allocator, alphas);
    }

    fn finish(self: *StripBuilder, allocator: std.mem.Allocator) !void {
        const last_y = self.storage.strips.items[self.storage.strips.items.len - 1].y;
        const idx = self.storage.alphas.items.len;
        try self.storage.strips.append(
            allocator,
            Strip.sentinel(last_y, @truncate(idx)),
        );
    }

    fn addRowEnd(
        self: *StripBuilder,
        allocator: std.mem.Allocator,
        strip_y: u16,
        x: u16,
        fill_gap: bool,
    ) !void {
        const idx = self.storage.alphas.items.len;
        try self.storage.strips.append(
            allocator,
            Strip.new(x, strip_y * Tile.HEIGHT, @truncate(idx), fill_gap),
        );
    }

    fn finishWithFillGapRowEnd(
        self: *StripBuilder,
        allocator: std.mem.Allocator,
        x: u16,
    ) !void {
        const last = self.storage.strips.items[self.storage.strips.items.len - 1];
        try self.addRowEnd(allocator, last.stripY(), x, true);
        try self.finish(allocator);
    }
};

test "intersect partly overlapping strips" {
    const allocator = testing.allocator;

    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStrip(allocator, 0, 0, 32, false);
    try path_1.finish(allocator);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStrip(allocator, 8, 0, 44, false);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 8, 0, 32, false);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "intersect multiple overlapping strips" {
    const allocator = testing.allocator;

    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStrip(allocator, 0, 1, 4, false);
    try path_1.addStrip(allocator, 12, 1, 20, true);
    try path_1.addStrip(allocator, 28, 1, 32, false);
    try path_1.addStrip(allocator, 44, 1, 52, true);
    try path_1.finish(allocator);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStrip(allocator, 4, 1, 8, false);
    try path_2.addStrip(allocator, 16, 1, 20, true);
    try path_2.addStrip(allocator, 24, 1, 28, false);
    try path_2.addStrip(allocator, 32, 1, 36, false);
    try path_2.addStrip(allocator, 44, 1, 48, true);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 4, 1, 8, false);
    try expected.addStrip(allocator, 12, 1, 20, true);
    try expected.addStrip(allocator, 32, 1, 36, false);
    try expected.addStrip(allocator, 44, 1, 48, true);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "multiple rows" {
    const allocator = testing.allocator;

    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStrip(allocator, 0, 0, 4, false);
    try path_1.addStrip(allocator, 16, 0, 20, true);
    try path_1.addStrip(allocator, 4, 1, 8, false);
    try path_1.addStrip(allocator, 12, 1, 24, true);
    try path_1.addStrip(allocator, 4, 2, 8, false);
    try path_1.addStrip(allocator, 16, 2, 32, true);
    try path_1.finish(allocator);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStrip(allocator, 0, 2, 4, false);
    try path_2.addStrip(allocator, 16, 2, 24, true);
    try path_2.addStrip(allocator, 8, 3, 12, false);
    try path_2.addStrip(allocator, 16, 3, 28, true);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 4, 2, 8, false);
    try expected.addStrip(allocator, 16, 2, 24, true);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "alpha buffer correct width" {
    const allocator = testing.allocator;

    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStrip(allocator, 0, 0, 4, false);
    try path_1.addStrip(allocator, 0, 1, 12, false);
    try path_1.finish(allocator);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStrip(allocator, 4, 0, 8, false);
    try path_2.addStrip(allocator, 0, 1, 4, false);
    try path_2.addStrip(allocator, 12, 1, 16, true);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 0, 1, 12, false);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "first strip at or after returns first matching strip y" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, 4, false);
    try path.addStrip(allocator, 0, 2, 4, false);
    try path.addStrip(allocator, 8, 2, 12, false);
    try path.addStrip(allocator, 16, 2, 20, false);
    try path.addStrip(allocator, 0, 4, 4, false);
    try path.addStrip(allocator, 8, 4, 12, false);
    try path.addStrip(allocator, 0, 6, 4, false);
    try path.finish(allocator);

    const strips = path.storage.strips.items;
    try testing.expectEqual(@as(usize, 0), firstStripAtOrAfter(strips, 0));
    try testing.expectEqual(@as(usize, 1), firstStripAtOrAfter(strips, 2));
    try testing.expectEqual(@as(usize, 4), firstStripAtOrAfter(strips, 3));
    try testing.expectEqual(@as(usize, 4), firstStripAtOrAfter(strips, 4));
    try testing.expectEqual(@as(usize, 6), firstStripAtOrAfter(strips, 5));
    try testing.expectEqual(@as(usize, 6), firstStripAtOrAfter(strips, 6));
    try testing.expectEqual(strips.len, firstStripAtOrAfter(strips, 7));
}

test "row iterator abort next line" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, 4, false);
    try path.addStrip(allocator, 0, 1, 4, false);
    try path.finish(allocator);

    const path_ref = pathRef(&path.storage);

    var idx: usize = 0;
    var iter = RowIterator.init(path_ref, &idx, 0);

    try testing.expect(iter.next() != null);
    try testing.expect(iter.next() == null);
}

test "row iterator row end fill gap" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, Tile.WIDTH, false);
    try path.finishWithFillGapRowEnd(allocator, 16);

    const path_ref = pathRef(&path.storage);

    var idx: usize = 0;
    var iter = RowIterator.init(path_ref, &idx, 0);

    try assertStripRegion(iter.next(), 0, Tile.WIDTH);
    try assertFillRegion(iter.next(), Tile.WIDTH, 16 - Tile.WIDTH);
    try testing.expect(iter.next() == null);
}

test "intersect strip with row end fill gap" {
    const allocator = testing.allocator;

    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStrip(allocator, 0, 0, Tile.WIDTH, false);
    try path_1.finishWithFillGapRowEnd(allocator, 16);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStrip(allocator, 8, 0, 12, false);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 8, 0, 12, false);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "intersect two row end fill gaps" {
    const allocator = testing.allocator;

    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStrip(allocator, 0, 0, 8, false);
    try path_1.finishWithFillGapRowEnd(allocator, 16);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStrip(allocator, 4, 0, 12, false);
    try path_2.finishWithFillGapRowEnd(allocator, 20);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 4, 0, 12, false);
    try expected.finishWithFillGapRowEnd(allocator, 16);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "row iterator fill gap stops at row boundary" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, 4, false);
    try path.addRowEnd(allocator, 0, 16, true);
    try path.addStrip(allocator, 0, 1, 4, false);
    try path.finish(allocator);

    const path_ref = pathRef(&path.storage);
    var idx: usize = 0;
    var iter = RowIterator.init(path_ref, &idx, 0);

    try assertStripRegion(iter.next(), 0, 4);
    try assertFillRegion(iter.next(), 4, 12);
    try testing.expect(iter.next() == null);

    var iter_row_1 = RowIterator.init(path_ref, &idx, 1);

    try assertStripRegion(iter_row_1.next(), 0, Tile.WIDTH);
    try testing.expect(iter_row_1.next() == null);
}

test "row iterator adjacent unmerged strips no fill" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, 4, false);
    try path.addStrip(allocator, 4, 0, 8, false);
    try path.finish(allocator);

    const path_ref = pathRef(&path.storage);
    var idx: usize = 0;
    var iter = RowIterator.init(path_ref, &idx, 0);

    try assertStripRegion(iter.next(), 0, 4);
    try assertStripRegion(iter.next(), 4, 4);
    try testing.expect(iter.next() == null);
}

test "row iterator adjacent unmerged strips with fill gap" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, 4, false);
    try path.addStrip(allocator, 4, 0, 8, true);
    try path.finish(allocator);

    const path_ref = pathRef(&path.storage);
    var idx: usize = 0;
    var iter = RowIterator.init(path_ref, &idx, 0);

    try assertStripRegion(iter.next(), 0, 4);
    try assertStripRegion(iter.next(), 4, 4);
    try testing.expect(iter.next() == null);
}

test "intersect adjacent unmerged strips" {
    const allocator = testing.allocator;

    var path = StripBuilder{};
    defer path.deinit(allocator);
    try path.addStrip(allocator, 0, 0, 4, false);
    try path.addStrip(allocator, 4, 0, 8, true);
    try path.finish(allocator);

    var cover = StripBuilder{};
    defer cover.deinit(allocator);
    try cover.addStrip(allocator, 0, 0, 8, false);
    try cover.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStrip(allocator, 0, 0, 8, false);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path.storage, &cover.storage);
}

test "intersect two opaque fills copies full alpha coverage" {
    const allocator = testing.allocator;

    // A full-coverage 8x8 rect intersected with a full-coverage 4x8 rect on
    // the right yields a 4x8 region whose alpha bytes are all 255 (the
    // strip∩fill and fill∩fill paths).
    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStripWith(allocator, 0, 0, 8, false, &OPAQUE_8);
    try path_1.finish(allocator);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStripWith(allocator, 4, 0, 8, false, &OPAQUE_4);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStripWith(allocator, 4, 0, 8, false, &OPAQUE_4);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

test "intersect multiplies strip alpha masks" {
    const allocator = testing.allocator;

    // Two overlapping strips with known per-column alphas: the result must be
    // `div255(a * b)` for every byte (upstream `normalized_mul_u8`).
    var path_1 = StripBuilder{};
    defer path_1.deinit(allocator);
    try path_1.addStripWith(allocator, 0, 0, 4, false, &TWOS);
    try path_1.finish(allocator);

    var path_2 = StripBuilder{};
    defer path_2.deinit(allocator);
    try path_2.addStripWith(allocator, 0, 0, 4, false, &THREES);
    try path_2.finish(allocator);

    var expected = StripBuilder{};
    defer expected.deinit(allocator);
    try expected.addStripWith(allocator, 0, 0, 4, false, &ONES);
    try expected.finish(allocator);

    try runTest(allocator, &expected.storage, &path_1.storage, &path_2.storage);
}

const OPAQUE_4: [4 * 4]u8 = @splat(255);
const OPAQUE_8: [8 * 4]u8 = @splat(255);
const ONES: [4 * 4]u8 = @splat(1);
const TWOS: [4 * 4]u8 = @splat(2);
const THREES: [4 * 4]u8 = @splat(3);

test "normalized mul u8 matches div255" {
    const a: U8x16 = @splat(255);
    const b: U8x16 = @splat(255);
    try testing.expectEqual(@as(u8, 255), util.narrow(util.normalizedMulU8(a, b))[0]);

    const zeros: U8x16 = @splat(0);
    try testing.expectEqual(@as(u8, 0), util.narrow(util.normalizedMulU8(zeros, b))[0]);

    // `(2 * 3 + 255) >> 8 == 1`.
    const twos: U8x16 = @splat(2);
    const threes: U8x16 = @splat(3);
    try testing.expectEqual(@as(u8, 1), util.narrow(util.normalizedMulU8(twos, threes))[0]);
}
