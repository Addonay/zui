//! Port of kurbo 0.13.1 `size.rs` (Apache-2.0 OR MIT).
//!
//! Zig has no operator overloading, so upstream operators are methods:
//! `add` (`+`), `sub` (`-`), `mul` (`* f64`), `div` (`/ f64`).
//!
//! Omissions: `RoundedRect` conversions (out of scope for this port) and the
//! `Axis`-indexed accessors (`Axis` is not part of this port's surface).

const std = @import("std");
const common = @import("common.zig");
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;

/// A 2D size.
pub const Size = struct {
    /// The width.
    width: f64,
    /// The height.
    height: f64,

    /// A size with zero width or height.
    pub const ZERO: Size = Size.new(0.0, 0.0);

    /// A size with width and height set to infinity.
    pub const INFINITY: Size = Size.new(std.math.inf(f64), std.math.inf(f64));

    /// Create a new `Size` with the provided `width` and `height`.
    pub inline fn new(width: f64, height: f64) Size {
        return .{ .width = width, .height = height };
    }

    /// Returns the max of `width` and `height`.
    pub inline fn maxSide(self: Size) f64 {
        return @max(self.width, self.height);
    }

    /// Returns the min of `width` and `height`.
    pub inline fn minSide(self: Size) f64 {
        return @min(self.width, self.height);
    }

    /// The area covered by this size.
    pub inline fn area(self: Size) f64 {
        return self.width * self.height;
    }

    /// Whether this size has zero area.
    pub inline fn isZeroArea(self: Size) bool {
        return self.area() == 0.0;
    }

    /// Returns the component-wise minimum of `self` and `other`.
    pub inline fn min(self: Size, other: Size) Size {
        return .{
            .width = @min(self.width, other.width),
            .height = @min(self.height, other.height),
        };
    }

    /// Returns the component-wise maximum of `self` and `other`.
    pub inline fn max(self: Size, other: Size) Size {
        return .{
            .width = @max(self.width, other.width),
            .height = @max(self.height, other.height),
        };
    }

    /// Returns a new size bounded by `min` and `max`.
    pub inline fn clamp(self: Size, min_size: Size, max_size: Size) Size {
        return self.max(min_size).min(max_size);
    }

    /// Convert this size into a `Vec2`.
    pub inline fn toVec2(self: Size) Vec2 {
        return Vec2.new(self.width, self.height);
    }

    /// Convert this `Size` into a `Rect` with origin `(0.0, 0.0)`.
    pub inline fn toRect(self: Size) Rect {
        return Rect.new(0.0, 0.0, self.width, self.height);
    }

    /// Returns a new `Size` with `width` and `height` rounded to the nearest
    /// integer.
    pub inline fn round(self: Size) Size {
        return Size.new(@round(self.width), @round(self.height));
    }

    /// Returns a new `Size` with `width` and `height` rounded up.
    pub inline fn ceil(self: Size) Size {
        return Size.new(@ceil(self.width), @ceil(self.height));
    }

    /// Returns a new `Size` with `width` and `height` rounded down.
    pub inline fn floor(self: Size) Size {
        return Size.new(@floor(self.width), @floor(self.height));
    }

    /// Returns a new `Size` with `width` and `height` rounded away from zero.
    pub inline fn expand(self: Size) Size {
        return Size.new(common.expand(self.width), common.expand(self.height));
    }

    /// Returns a new `Size` with `width` and `height` rounded toward zero.
    pub inline fn trunc(self: Size) Size {
        return Size.new(@trunc(self.width), @trunc(self.height));
    }

    /// Returns the aspect ratio of a rectangle with this size (width/height).
    ///
    /// If the height is `0`, the output will be `sign(self.width) * infinity`.
    /// If width and height are both `0`, the output is `NaN`.
    pub inline fn aspectRatioWidth(self: Size) f64 {
        return self.width / self.height;
    }

    /// The inverse of the aspect ratio (height/width).
    ///
    /// Deprecated upstream in favor of `aspectRatioWidth` because it returns a
    /// potentially unexpected value; kept for parity.
    pub inline fn aspectRatio(self: Size) f64 {
        return self.height / self.width;
    }

    /// Is this size finite?
    pub inline fn isFinite(self: Size) bool {
        return std.math.isFinite(self.width) and std.math.isFinite(self.height);
    }

    /// Is this size `NaN`?
    pub inline fn isNan(self: Size) bool {
        return std.math.isNan(self.width) or std.math.isNan(self.height);
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Size + Size`.
    pub inline fn add(self: Size, other: Size) Size {
        return .{ .width = self.width + other.width, .height = self.height + other.height };
    }

    /// Upstream `Size - Size`.
    pub inline fn sub(self: Size, other: Size) Size {
        return .{ .width = self.width - other.width, .height = self.height - other.height };
    }

    /// Upstream `Size * f64`.
    pub inline fn mul(self: Size, other: f64) Size {
        return .{ .width = self.width * other, .height = self.height * other };
    }

    /// Upstream `Size / f64`.
    pub inline fn div(self: Size, other: f64) Size {
        return .{ .width = self.width / other, .height = self.height / other };
    }
};

test "size aspect_ratio_width" {
    const testing = std.testing;
    const s = Size.new(1.0, 1.0);
    try testing.expect(@abs(s.aspectRatioWidth() - 1.0) < 1e-6);

    // 3:2 film (mm)
    const film = Size.new(36.0, 24.0);
    try testing.expect(@abs(film.aspectRatioWidth() - 1.5) < 1e-6);
    // 4k screen
    const screen = Size.new(3840.0, 2160.0);
    try testing.expect(@abs(screen.aspectRatioWidth() - (16.0 / 9.0)) < 1e-6);
}

test "size min max clamp and area" {
    const testing = std.testing;
    const this = Size.new(0.0, 100.0);
    const other = Size.new(10.0, 10.0);
    try testing.expectEqualDeep(Size.new(0.0, 10.0), this.min(other));
    try testing.expectEqualDeep(Size.new(10.0, 100.0), this.max(other));
    try testing.expectEqualDeep(Size.new(10.0, 50.0), this.clamp(Size.new(10.0, 10.0), Size.new(50.0, 50.0)));
    try testing.expectEqual(@as(f64, 0.0), this.area());
    try testing.expect(this.isZeroArea());
    try testing.expect(!Size.new(2.0, 3.0).isZeroArea());
    try testing.expect(Size.ZERO.isZeroArea());
}
