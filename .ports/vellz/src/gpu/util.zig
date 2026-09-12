//! Port of `vello_gpu/src/util.rs` (Apache-2.0 OR MIT).
//!
//! This file owns the instance packing helpers and the `Ranges`/`RangedSlice`
//! selection view used by `draw.zig` to describe the alpha strips of one draw
//! pass. `DimensionConstraints` (`util.rs`'s other half) is a window-sizing
//! helper with no consumer in the vellz port; it is omitted until one exists.
//!
//! Allocator contract: `Ranges` owns one unmanaged `ArrayList`; callers pass
//! the allocator to `push`/`deinit`.

const std = @import("std");

/// Pack a `u16` pair into a `u32` with `x` in the low 16 bits and `y` in the
/// high 16 bits (the layout consumed by the strip/blend/copy shaders).
pub fn packU16Pair(x: u16, y: u16) u32 {
    return @as(u32, x) | (@as(u32, y) << 16);
}

/// Unpack the `u16` pair produced by [`packU16Pair`].
pub fn unpackU16Pair(value: u32) [2]u16 {
    return .{ @truncate(value), @truncate(value >> 16) };
}

/// Round an opacity in `0.0..1.0` to the normalized `u8` range, clamping and
/// rounding exactly like upstream (`(clamped * 255.0).round() as u8`).
pub fn packOpacity(opacity: f32) u8 {
    const clamped = std.math.clamp(opacity, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

/// A half-open index range (upstream `core::ops::Range<usize>`).
pub const IndexRange = struct {
    /// First index, inclusive.
    start: usize,
    /// End index, exclusive.
    end: usize,

    /// The number of selected values.
    pub fn len(self: IndexRange) usize {
        return self.end - self.start;
    }
};

/// Coalesced ranges selecting values from a shared buffer
/// (upstream `util.rs::Ranges`).
///
/// Adjacent insertions are merged; `total_len` tracks the number of selected
/// values across all ranges without walking them.
pub const Ranges = struct {
    /// Non-contiguous ranges, with adjacent insertions merged.
    ranges: std.ArrayListUnmanaged(IndexRange) = .empty,
    /// Total number of selected values across all ranges.
    total_len: usize = 0,

    /// Release the range list.
    pub fn deinit(self: *Ranges, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.* = .{};
    }

    /// Drop all ranges, keeping the allocation.
    pub fn clear(self: *Ranges) void {
        self.ranges.clearRetainingCapacity();
        self.total_len = 0;
    }

    /// Append a range, merging it with the previous one when adjacent.
    pub fn push(self: *Ranges, allocator: std.mem.Allocator, range: IndexRange) !void {
        self.total_len += range.len();
        if (self.ranges.items.len > 0) {
            const last = &self.ranges.items[self.ranges.items.len - 1];
            if (last.end == range.start) {
                last.end = range.end;
                return;
            }
        }
        try self.ranges.append(allocator, range);
    }

    /// Total number of selected values across all ranges.
    pub fn len(self: *const Ranges) usize {
        return self.total_len;
    }

    /// Whether no values are selected.
    pub fn isEmpty(self: *const Ranges) bool {
        return self.total_len == 0;
    }
};

/// Append `value` to `list` and record its index in `ranges`
/// (upstream `VecExt::push_ranged`).
pub fn pushRanged(
    comptime T: type,
    list: *std.ArrayList(T),
    ranges: *Ranges,
    allocator: std.mem.Allocator,
    value: T,
) !void {
    try list.append(allocator, value);
    const end = list.items.len;
    try ranges.push(allocator, .{ .start = end - 1, .end = end });
}

/// Read-only view of values selected from a shared buffer by [`Ranges`]
/// (upstream `util.rs::RangedSlice`).
pub fn RangedSlice(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Shared buffer from which values are selected.
        buffer: []const T = &.{},
        /// Ranges selecting values from `buffer`.
        ranges: []const IndexRange = &.{},
        /// Total number of selected values.
        total_len: usize = 0,

        /// An empty selection.
        pub const empty: Self = .{};

        /// Build a view of `buffer` selected by `ranges`.
        pub fn init(buffer: []const T, ranges: *const Ranges) Self {
            return .{
                .buffer = buffer,
                .ranges = ranges.ranges.items,
                .total_len = ranges.total_len,
            };
        }

        /// Total number of selected values.
        pub fn len(self: Self) usize {
            return self.total_len;
        }

        /// Whether the view selects no values.
        pub fn isEmpty(self: Self) bool {
            return self.total_len == 0;
        }

        /// Iterate over the backing ranges as slices.
        pub fn slices(self: Self) Slices {
            return .{ .view = self, .index = 0 };
        }

        /// Iterate over every selected value in range order.
        pub fn iter(self: Self) Iter {
            return .{ .view = self };
        }

        /// Append every selected value to `out` in range order.
        pub fn appendTo(self: Self, allocator: std.mem.Allocator, out: *std.ArrayList(T)) !void {
            for (self.ranges) |range| {
                try out.appendSlice(allocator, self.buffer[range.start..range.end]);
            }
        }

        /// Slice iterator state (`slices`).
        pub const Slices = struct {
            view: Self,
            index: usize,

            pub fn next(self: *Slices) ?[]const T {
                if (self.index >= self.view.ranges.len) return null;
                const range = self.view.ranges[self.index];
                self.index += 1;
                return self.view.buffer[range.start..range.end];
            }
        };

        /// Value iterator state (`iter`).
        pub const Iter = struct {
            view: Self,
            slice_index: usize = 0,
            item_index: usize = 0,

            pub fn next(self: *Iter) ?*const T {
                while (self.slice_index < self.view.ranges.len) {
                    const range = self.view.ranges[self.slice_index];
                    if (self.item_index < range.len()) {
                        const item = &self.view.buffer[range.start + self.item_index];
                        self.item_index += 1;
                        return item;
                    }
                    self.slice_index += 1;
                    self.item_index = 0;
                }
                return null;
            }
        };
    };
}

test "pack_u16_pair round trip" {
    try std.testing.expectEqual(@as(u32, 0x0000_0001), packU16Pair(1, 0));
    try std.testing.expectEqual(@as(u32, 0x0001_0000), packU16Pair(0, 1));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), packU16Pair(0x5678, 0x1234));
    try std.testing.expectEqual([2]u16{ 0x5678, 0x1234 }, unpackU16Pair(0x1234_5678));
    try std.testing.expectEqual([2]u16{ 0xFFFF, 0xFFFF }, unpackU16Pair(0xFFFF_FFFF));
}

test "pack_opacity clamps and rounds" {
    try std.testing.expectEqual(@as(u8, 0), packOpacity(0.0));
    try std.testing.expectEqual(@as(u8, 255), packOpacity(1.0));
    try std.testing.expectEqual(@as(u8, 128), packOpacity(0.5));
    try std.testing.expectEqual(@as(u8, 0), packOpacity(-1.0));
    try std.testing.expectEqual(@as(u8, 255), packOpacity(2.0));
    // Upstream uses round-half-away-from-zero: 0.5/255 * 255 = 0.5 -> 1.
    try std.testing.expectEqual(@as(u8, 1), packOpacity(0.5 / 255.0));
}

test "ranged slices select coalesced ranges" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u32) = .empty;
    defer buffer.deinit(allocator);
    var selected: Ranges = .{};
    defer selected.deinit(allocator);
    var other: Ranges = .{};
    defer other.deinit(allocator);

    try pushRanged(u32, &buffer, &selected, allocator, 1);
    try pushRanged(u32, &buffer, &selected, allocator, 2);
    try pushRanged(u32, &buffer, &other, allocator, 10);
    try pushRanged(u32, &buffer, &selected, allocator, 3);
    try pushRanged(u32, &buffer, &selected, allocator, 4);
    try pushRanged(u32, &buffer, &selected, allocator, 5);
    try pushRanged(u32, &buffer, &other, allocator, 11);
    try pushRanged(u32, &buffer, &other, allocator, 12);
    try pushRanged(u32, &buffer, &selected, allocator, 6);

    const view = RangedSlice(u32).init(buffer.items, &selected);
    try std.testing.expectEqual(@as(usize, 6), view.len());
    try std.testing.expectEqual(@as(usize, 3), selected.ranges.items.len);

    var slices = view.slices();
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, slices.next().?);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, slices.next().?);
    try std.testing.expectEqualSlices(u32, &.{6}, slices.next().?);
    try std.testing.expectEqual(@as(?[]const u32, null), slices.next());

    var iter = view.iter();
    var expected: u32 = 1;
    while (iter.next()) |value| : (expected += 1) {
        try std.testing.expectEqual(expected, value.*);
    }
    try std.testing.expectEqual(@as(u32, 7), expected);

    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(allocator);
    try view.appendTo(allocator, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6 }, flat.items);
}

test "ranges clear resets selection" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u32) = .empty;
    defer buffer.deinit(allocator);
    var ranges: Ranges = .{};
    defer ranges.deinit(allocator);

    try pushRanged(u32, &buffer, &ranges, allocator, 1);
    try pushRanged(u32, &buffer, &ranges, allocator, 2);
    ranges.clear();

    try std.testing.expectEqual(@as(usize, 0), ranges.len());
    try std.testing.expect(RangedSlice(u32).init(buffer.items, &ranges).isEmpty());

    try pushRanged(u32, &buffer, &ranges, allocator, 3);
    const view = RangedSlice(u32).init(buffer.items, &ranges);
    try std.testing.expectEqual(@as(usize, 1), view.len());
    var single_iter = view.iter();
    try std.testing.expectEqual(@as(u32, 3), single_iter.next().?.*);
}
