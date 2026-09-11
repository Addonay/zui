//! Port of vello_common geometry.rs (Apache-2.0 OR MIT).
//!
//! Integer geometry only: upstream deliberately keeps `SizeU16`, `PaddingU16`,
//! and `RectU16` separate from the floating-point `kurbo` types so that
//! tile/strip/viewport bookkeeping is exact.
//!
//! Ownership/allocator note: all types here are plain values; they own no heap
//! memory and never take an allocator. `RectU16.asRect` returns a borrowed-by-
//! value `kurbo.Rect`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");

/// A size represented by two 16-bit unsigned integers.
pub const SizeU16 = struct {
    /// The packed width and height, in `[width, height]` order.
    value: [2]u16,

    /// A zero size.
    pub const ZERO: SizeU16 = .{ .value = .{ 0, 0 } };

    /// Create a new square size.
    pub fn new(size: u16) SizeU16 {
        return .{ .value = .{ size, size } };
    }

    /// Create a new size from its width and height.
    pub fn fromWh(w: u16, h: u16) SizeU16 {
        return .{ .value = .{ w, h } };
    }

    /// Build a size from the upstream `[u16; 2]` representation.
    pub fn from(value: [2]u16) SizeU16 {
        return .{ .value = value };
    }

    /// Return the upstream `[u16; 2]` representation.
    pub fn toArray(self: SizeU16) [2]u16 {
        return self.value;
    }

    /// The width of this size.
    pub fn width(self: SizeU16) u16 {
        return self.value[0];
    }

    /// The height of this size.
    pub fn height(self: SizeU16) u16 {
        return self.value[1];
    }

    /// Return the maximum of the two sizes.
    pub fn max(self: SizeU16, other: SizeU16) SizeU16 {
        return .fromWh(@max(self.width(), other.width()), @max(self.height(), other.height()));
    }

    /// Return the minimum of the two sizes.
    pub fn min(self: SizeU16, other: SizeU16) SizeU16 {
        return .fromWh(@min(self.width(), other.width()), @min(self.height(), other.height()));
    }

    /// Clamp both dimensions to the given range.
    pub fn clamp(self: SizeU16, min_value: u16, max_value: u16) SizeU16 {
        return .fromWh(
            std.math.clamp(self.width(), min_value, max_value),
            std.math.clamp(self.height(), min_value, max_value),
        );
    }

    /// Add the same value to both dimensions, returning `null` on overflow.
    pub fn checkedAdd(self: SizeU16, value: u16) ?SizeU16 {
        const w = std.math.add(u16, self.width(), value) catch return null;
        const h = std.math.add(u16, self.height(), value) catch return null;
        return .fromWh(w, h);
    }

    /// Add two sizes component-wise.
    ///
    /// Upstream `impl Add for SizeU16` asserts on overflow, because it cannot
    /// happen for the sizes the renderer uses; this port panics in safe builds
    /// for the same reason.
    pub fn add(self: SizeU16, rhs: SizeU16) SizeU16 {
        const new_width = std.math.add(u16, self.width(), rhs.width()) catch
            @panic("SizeU16 addition overflow");
        const new_height = std.math.add(u16, self.height(), rhs.height()) catch
            @panic("SizeU16 addition overflow");
        return .fromWh(new_width, new_height);
    }

    /// Add the same value to both dimensions.
    ///
    /// Upstream expresses this as `impl Add<u16>`; Zig has no operator
    /// overloading, so it is a named method.
    pub fn addScalar(self: SizeU16, rhs: u16) SizeU16 {
        return self.add(SizeU16.new(rhs));
    }

    /// Build a size from a rectangle's dimensions.
    pub fn fromRect(rect: RectU16) SizeU16 {
        return .fromWh(rect.width(), rect.height());
    }
};

/// Padding for the four sides of a region.
pub const PaddingU16 = struct {
    /// The left padding.
    left: u16,
    /// The top padding.
    top: u16,
    /// The right padding.
    right: u16,
    /// The bottom padding.
    bottom: u16,

    /// Padding with all sides set to zero.
    pub const ZERO: PaddingU16 = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

    /// Create padding from its left, top, right, and bottom amounts.
    pub fn new(left: u16, top: u16, right: u16, bottom: u16) PaddingU16 {
        return .{ .left = left, .top = top, .right = right, .bottom = bottom };
    }
};

/// An axis-aligned rectangle with `u16` coordinates, stored as two corners
/// `(x0, y0)` and `(x1, y1)`.
///
/// `(x0, y0)` is the top-left (minimum) corner and `(x1, y1)` is the
/// bottom-right (maximum) corner. The rectangle is considered to be empty when
/// `x0 >= x1` or `y0 >= y1`.
pub const RectU16 = struct {
    /// The minimum x coordinate (left edge).
    x0: u16,
    /// The minimum y coordinate (top edge).
    y0: u16,
    /// The maximum x coordinate (right edge, exclusive).
    x1: u16,
    /// The maximum y coordinate (bottom edge, exclusive).
    y1: u16,

    /// A rectangle with all coordinates set to zero.
    pub const ZERO: RectU16 = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    /// An empty, maximally inverted rectangle, useful as a starting value for
    /// incremental union operations.
    ///
    /// Has `(x0, y0) = (u16::MAX, u16::MAX)` and `(x1, y1) = (0, 0)`.
    pub const INVERTED: RectU16 = .{
        .x0 = std.math.maxInt(u16),
        .y0 = std.math.maxInt(u16),
        .x1 = 0,
        .y1 = 0,
    };

    /// Create a new rectangle from its corner coordinates.
    pub fn new(x0: u16, y0: u16, x1: u16, y1: u16) RectU16 {
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    /// The width of the rectangle (`x1 - x0`), saturating at zero.
    pub fn width(self: RectU16) u16 {
        return self.x1 -| self.x0;
    }

    /// The height of the rectangle (`y1 - y0`), saturating at zero.
    pub fn height(self: RectU16) u16 {
        return self.y1 -| self.y0;
    }

    /// Returns `true` if the rectangle has zero area (`x0 >= x1` or
    /// `y0 >= y1`).
    pub fn isEmpty(self: RectU16) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }

    /// Check if a point `(x, y)` is contained within this rectangle.
    ///
    /// Returns `true` if `x0 <= x < x1` and `y0 <= y < y1`.
    pub fn contains(self: RectU16, x: u16, y: u16) bool {
        return (x >= self.x0) and (x < self.x1) and (y >= self.y0) and (y < self.y1);
    }

    /// Compute the intersection of two rectangles.
    ///
    /// The result may have zero area if the rectangles do not overlap, but is
    /// never inverted.
    pub fn intersect(self: RectU16, other: RectU16) RectU16 {
        const x0 = @max(self.x0, other.x0);
        const y0 = @max(self.y0, other.y0);
        const x1 = @min(self.x1, other.x1);
        const y1 = @min(self.y1, other.y1);
        return .new(x0, y0, @max(x1, x0), @max(y1, y0));
    }

    /// Expand this rectangle by the given left, top, right, and bottom padding.
    pub fn expand(self: RectU16, padding: PaddingU16) RectU16 {
        return .{
            .x0 = self.x0 -| padding.left,
            .y0 = self.y0 -| padding.top,
            .x1 = self.x1 +| padding.right,
            .y1 = self.y1 +| padding.bottom,
        };
    }

    /// Return this rectangle relative to `origin`, clamping negative
    /// coordinates to zero.
    pub fn relativeToOrigin(self: RectU16, origin: [2]u16) RectU16 {
        return self.shift(.{
            -@as(i32, origin[0]),
            -@as(i32, origin[1]),
        });
    }

    /// Return a shifted version of the rectangle, clamping negative
    /// coordinates to zero.
    pub fn shift(self: RectU16, delta: [2]i32) RectU16 {
        return .{
            .x0 = clampShifted(self.x0, delta[0]),
            .y0 = clampShifted(self.y0, delta[1]),
            .x1 = clampShifted(self.x1, delta[0]),
            .y1 = clampShifted(self.y1, delta[1]),
        };
    }

    /// Expand this rectangle to also cover `other` (union in place).
    ///
    /// The union of `self` with `RectU16.INVERTED` returns `self`. Upstream
    /// names this `union`; that is a Zig keyword, so the method is
    /// `unionWith`.
    pub fn unionWith(self: *RectU16, other: RectU16) void {
        self.x0 = @min(self.x0, other.x0);
        self.y0 = @min(self.y0, other.y0);
        self.x1 = @max(self.x1, other.x1);
        self.y1 = @max(self.y1, other.y1);
    }

    /// Return the rect as a `kurbo.Rect`.
    pub fn asRect(self: RectU16) kurbo.Rect {
        return kurbo.Rect.new(
            @floatFromInt(self.x0),
            @floatFromInt(self.y0),
            @floatFromInt(self.x1),
            @floatFromInt(self.y1),
        );
    }

    /// Convert this rectangle to a `SizeU16` of its dimensions.
    pub fn toSizeU16(self: RectU16) SizeU16 {
        return SizeU16.fromWh(self.width(), self.height());
    }
};

fn clampShifted(value: u16, delta: i32) u16 {
    const shifted = @as(i32, value) +| delta;
    return @intCast(std.math.clamp(shifted, 0, std.math.maxInt(u16)));
}

test "rect_u16_relative_to_origin" {
    const rect = RectU16.new(10, 20, 30, 40);

    try std.testing.expectEqual(RectU16.new(5, 8, 25, 28), rect.relativeToOrigin(.{ 5, 12 }));
}

test "rect_u16_relative_to_origin_clamps_to_zero" {
    const rect = RectU16.new(10, 20, 30, 40);

    try std.testing.expectEqual(RectU16.new(0, 0, 10, 5), rect.relativeToOrigin(.{ 20, 35 }));
}

test "disjoint_intersection_is_empty_but_not_inverted" {
    const intersection = RectU16.new(0, 0, 4, 4).intersect(RectU16.new(8, 1, 12, 3));

    try std.testing.expectEqual(RectU16.new(8, 1, 8, 3), intersection);
    try std.testing.expect(intersection.isEmpty());
    try std.testing.expect(intersection.x0 <= intersection.x1);
    try std.testing.expect(intersection.y0 <= intersection.y1);
}

test "size_u16_helpers" {
    const size = SizeU16.fromWh(3, 5);
    try std.testing.expectEqual(@as(u16, 3), size.width());
    try std.testing.expectEqual(@as(u16, 5), size.height());
    try std.testing.expectEqual(SizeU16.fromWh(4, 5), size.max(SizeU16.fromWh(4, 2)));
    try std.testing.expectEqual(SizeU16.fromWh(2, 5), size.min(SizeU16.fromWh(2, 9)));
    try std.testing.expectEqual(SizeU16.fromWh(3, 4), size.clamp(2, 4));
    try std.testing.expectEqual(@as(?SizeU16, SizeU16.fromWh(5, 7)), size.checkedAdd(2));
    try std.testing.expectEqual(
        @as(?SizeU16, null),
        SizeU16.fromWh(std.math.maxInt(u16), 0).checkedAdd(1),
    );
    try std.testing.expectEqual(SizeU16.fromWh(6, 8), size.addScalar(3));
    try std.testing.expectEqual(SizeU16.fromWh(3, 5), RectU16.new(0, 0, 3, 5).toSizeU16());
}

test "rect_u16_union_expand_contains_and_as_rect" {
    var union_rect = RectU16.INVERTED;
    union_rect.unionWith(RectU16.new(4, 4, 8, 8));
    union_rect.unionWith(RectU16.new(1, 2, 3, 9));
    try std.testing.expectEqual(RectU16.new(1, 2, 8, 9), union_rect);
    try std.testing.expect(union_rect.contains(1, 2));
    try std.testing.expect(!union_rect.contains(8, 2));

    try std.testing.expectEqual(
        RectU16.new(0, 1, 10, 9),
        RectU16.new(1, 2, 9, 8).expand(PaddingU16.new(1, 1, 1, 1)),
    );
    try std.testing.expectEqual(
        RectU16.new(0, 0, 1, 1),
        RectU16.new(0, 0, 1, 1).expand(PaddingU16.ZERO),
    );

    const rect = RectU16.new(1, 2, 3, 4).asRect();
    try std.testing.expectEqual(kurbo.Rect.new(1.0, 2.0, 3.0, 4.0), rect);
}
