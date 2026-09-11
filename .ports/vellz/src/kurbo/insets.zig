//! Port of kurbo 0.13.1 `insets.rs` (Apache-2.0 OR MIT).
//!
//! Zig has no operator overloading, so upstream operators are methods:
//! `neg` (unary `-`), `add`/`sub` (`Insets ± Insets`), `mul`/`div` (by `f64`),
//! `addRect` (`Insets + Rect`), `subRect` (`Insets - Rect`).
//!
//! A positive inset represents increased distance from the center of a rect.

const std = @import("std");
const Rect = @import("rect.zig").Rect;
const Size = @import("size.zig").Size;

/// Insets from the edges of a rectangle.
///
/// The inset value for each edge can be thought of as a delta computed from
/// the center of the rect to that edge. For instance, with an inset of `2.0`
/// on the x-axis, a rectangle with the origin `(0.0, 0.0)` with that inset
/// added will have the new origin at `(-2.0, 0.0)`.
pub const Insets = struct {
    /// The minimum x coordinate (left edge).
    x0: f64,
    /// The minimum y coordinate (top edge in y-down spaces).
    y0: f64,
    /// The maximum x coordinate (right edge).
    x1: f64,
    /// The maximum y coordinate (bottom edge in y-down spaces).
    y1: f64,

    /// Zeroed insets.
    pub const ZERO: Insets = Insets.uniform(0.0);

    /// New uniform insets.
    pub inline fn uniform(d: f64) Insets {
        return .{ .x0 = d, .y0 = d, .x1 = d, .y1 = d };
    }

    /// New insets with uniform values along each axis.
    pub inline fn uniformXy(x: f64, y: f64) Insets {
        return .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y };
    }

    /// New insets. The ordering of the arguments is "left, top, right,
    /// bottom", assuming a y-down coordinate space.
    pub inline fn new(x0: f64, y0: f64, x1: f64, y1: f64) Insets {
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    /// The total delta on the x-axis represented by these insets.
    pub inline fn xValue(self: Insets) f64 {
        return self.x0 + self.x1;
    }

    /// The total delta on the y-axis represented by these insets.
    pub inline fn yValue(self: Insets) f64 {
        return self.y0 + self.y1;
    }

    /// Returns the total delta represented by these insets as a `Size`.
    pub inline fn size(self: Insets) Size {
        return Size.new(self.xValue(), self.yValue());
    }

    /// Return `true` iff all values are nonnegative.
    pub inline fn areNonnegative(self: Insets) bool {
        return self.x0 >= 0.0 and self.y0 >= 0.0 and self.x1 >= 0.0 and self.y1 >= 0.0;
    }

    /// Return new `Insets` with all negative values replaced with `0.0`.
    pub inline fn nonnegative(self: Insets) Insets {
        return .{
            .x0 = @max(self.x0, 0.0),
            .y0 = @max(self.y0, 0.0),
            .x1 = @max(self.x1, 0.0),
            .y1 = @max(self.y1, 0.0),
        };
    }

    /// Are these insets finite?
    pub inline fn isFinite(self: Insets) bool {
        return std.math.isFinite(self.x0) and std.math.isFinite(self.y0) and
            std.math.isFinite(self.x1) and std.math.isFinite(self.y1);
    }

    /// Are these insets `NaN`?
    pub inline fn isNan(self: Insets) bool {
        return std.math.isNan(self.x0) or std.math.isNan(self.y0) or
            std.math.isNan(self.x1) or std.math.isNan(self.y1);
    }

    /// Returns the component-wise minimum of `self` and `other`.
    pub inline fn min(self: Insets, other: Insets) Insets {
        return .{
            .x0 = @min(self.x0, other.x0),
            .y0 = @min(self.y0, other.y0),
            .x1 = @min(self.x1, other.x1),
            .y1 = @min(self.y1, other.y1),
        };
    }

    /// Returns the component-wise maximum of `self` and `other`.
    pub inline fn max(self: Insets, other: Insets) Insets {
        return .{
            .x0 = @max(self.x0, other.x0),
            .y0 = @max(self.y0, other.y0),
            .x1 = @max(self.x1, other.x1),
            .y1 = @max(self.y1, other.y1),
        };
    }

    // ------------------------------------------------------------ operators

    /// Upstream unary `-Insets`.
    pub inline fn neg(self: Insets) Insets {
        return Insets.new(-self.x0, -self.y0, -self.x1, -self.y1);
    }

    /// Upstream `Insets + Insets`.
    pub inline fn add(self: Insets, other: Insets) Insets {
        return .{
            .x0 = self.x0 + other.x0,
            .y0 = self.y0 + other.y0,
            .x1 = self.x1 + other.x1,
            .y1 = self.y1 + other.y1,
        };
    }

    /// Upstream `Insets - Insets`.
    pub inline fn sub(self: Insets, other: Insets) Insets {
        return .{
            .x0 = self.x0 - other.x0,
            .y0 = self.y0 - other.y0,
            .x1 = self.x1 - other.x1,
            .y1 = self.y1 - other.y1,
        };
    }

    /// Upstream `Insets + Rect`.
    ///
    /// Operates on the absolute rectangle, so existing negative widths and
    /// heights are ignored.
    pub inline fn addRect(self: Insets, other: Rect) Rect {
        const abs_other = other.abs();
        return Rect.new(
            abs_other.x0 - self.x0,
            abs_other.y0 - self.y0,
            abs_other.x1 + self.x1,
            abs_other.y1 + self.y1,
        );
    }

    /// Upstream `Insets - Rect`.
    pub inline fn subRect(self: Insets, other: Rect) Rect {
        return self.neg().addRect(other);
    }

    /// Upstream `Insets * f64`.
    pub inline fn mul(self: Insets, rhs: f64) Insets {
        return Insets.new(self.x0 * rhs, self.y0 * rhs, self.x1 * rhs, self.y1 * rhs);
    }

    /// Upstream `Insets / f64`.
    pub inline fn div(self: Insets, rhs: f64) Insets {
        return Insets.new(self.x0 / rhs, self.y0 / rhs, self.x1 / rhs, self.y1 / rhs);
    }
};

test "insets x_value and y_value" {
    const testing = std.testing;
    const insets = Insets.uniformXy(3.0, 8.0);
    try testing.expectEqual(@as(f64, 6.0), insets.xValue());
    try testing.expectEqual(@as(f64, 16.0), insets.yValue());

    const mixed = Insets.new(5.0, 10.0, -12.0, 4.0);
    try testing.expectEqual(@as(f64, -7.0), mixed.xValue());
    try testing.expectEqual(@as(f64, 14.0), mixed.yValue());
}

test "insets add to rect" {
    const testing = std.testing;
    const rect = Rect.fromOriginSize(.{ .x = 0.0, .y = 0.0 }, .{ .width = 10.0, .height = 10.0 });
    const insets = Insets.uniformXy(3.0, 0.0);
    const inset_rect = insets.addRect(rect);
    try testing.expectEqual(@as(f64, 16.0), inset_rect.width());
    try testing.expectEqual(@as(f64, -3.0), inset_rect.x0);

    // Ignore existing negative widths and heights.
    const flipped = Rect.new(7.0, 11.0, 0.0, 0.0);
    try testing.expectEqual(@as(f64, -7.0), flipped.width());
    const inset_flipped = Insets.uniformXy(0.0, 1.0).addRect(flipped);
    try testing.expectEqual(@as(f64, 7.0), inset_flipped.width());
    try testing.expectEqual(@as(f64, 0.0), inset_flipped.x0);
    try testing.expectEqual(@as(f64, 13.0), inset_flipped.height());
}

test "insets nonnegative and min max" {
    const testing = std.testing;
    const insets = Insets.new(-10.0, 3.0, -0.2, 4.0);
    const nonnegative = insets.nonnegative();
    try testing.expectEqual(@as(f64, 0.0), nonnegative.xValue());
    try testing.expectEqual(@as(f64, 7.0), nonnegative.yValue());
    try testing.expect(!insets.areNonnegative());
    try testing.expect(nonnegative.areNonnegative());

    const a = Insets.new(1.0, 2.0, 3.0, 4.0);
    const b = Insets.new(4.0, 3.0, 2.0, 1.0);
    try testing.expectEqualDeep(Insets.new(1.0, 2.0, 2.0, 1.0), a.min(b));
    try testing.expectEqualDeep(Insets.new(4.0, 3.0, 3.0, 4.0), a.max(b));
}
