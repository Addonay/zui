//! Port of kurbo 0.13.1 `rect.rs` (Apache-2.0 OR MIT).
//!
//! Shape duck typing (upstream `impl Shape for Rect`):
//! `toPath(self, tolerance, allocator) !BezPath`, `boundingBox() Rect`,
//! `area() f64`, `perimeter(accuracy) f64`, `winding(pt) i32`,
//! `contains(pt) bool`. `toPath` allocates with the supplied allocator and
//! returns an owned `BezPath` (call `deinit` on it).
//!
//! Zig has no operator overloading, so upstream operators are methods:
//! `addVec` (`Rect + Vec2`), `subVec` (`Rect - Vec2`), `subRect`
//! (`Rect - Rect -> Insets`).
//!
//! Omissions: `to_rounded_rect`/`to_ellipse` (RoundedRect/Ellipse are outside
//! this port's scope), the `mint` conversions and the `Axis` accessors.

const std = @import("std");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Size = @import("size.zig").Size;
const Insets = @import("insets.zig").Insets;
const bezpath = @import("bezpath.zig");
const BezPath = bezpath.BezPath;
const PathEl = bezpath.PathEl;

/// A rectangle.
pub const Rect = struct {
    /// The minimum x coordinate (left edge).
    x0: f64,
    /// The minimum y coordinate (top edge in y-down spaces).
    y0: f64,
    /// The maximum x coordinate (right edge).
    x1: f64,
    /// The maximum y coordinate (bottom edge in y-down spaces).
    y1: f64,

    /// The empty rectangle at the origin.
    pub const ZERO: Rect = Rect.new(0.0, 0.0, 0.0, 0.0);

    /// A new rectangle from minimum and maximum coordinates.
    pub inline fn new(x0: f64, y0: f64, x1: f64, y1: f64) Rect {
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    /// A new rectangle from two points.
    ///
    /// The result will have non-negative width and height.
    pub inline fn fromPoints(p0: Point, p1: Point) Rect {
        return Rect.new(p0.x, p0.y, p1.x, p1.y).abs();
    }

    /// A new rectangle from origin and size.
    ///
    /// The result will have non-negative width and height.
    pub inline fn fromOriginSize(origin_pt: Point, sz: Size) Rect {
        return Rect.fromPoints(origin_pt, origin_pt.addVec(sz.toVec2()));
    }

    /// A new rectangle from center and size.
    pub inline fn fromCenterSize(center_pt: Point, sz: Size) Rect {
        const half = sz.mul(0.5);
        return Rect.new(
            center_pt.x - half.width,
            center_pt.y - half.height,
            center_pt.x + half.width,
            center_pt.y + half.height,
        );
    }

    /// Create a new `Rect` with the same size as `self` and a new origin.
    pub inline fn withOrigin(self: Rect, origin_pt: Point) Rect {
        return Rect.fromOriginSize(origin_pt, self.size());
    }

    /// Create a new `Rect` with the same origin as `self` and a new size.
    pub inline fn withSize(self: Rect, sz: Size) Rect {
        return Rect.fromOriginSize(self.origin(), sz);
    }

    /// Create a new `Rect` by applying the `Insets`.
    ///
    /// This will not preserve negative width and height.
    pub inline fn inset(self: Rect, insets: Insets) Rect {
        return insets.addRect(self);
    }

    /// The width of the rectangle.
    ///
    /// Note: nothing forbids negative width.
    pub inline fn width(self: Rect) f64 {
        return self.x1 - self.x0;
    }

    /// The height of the rectangle.
    ///
    /// Note: nothing forbids negative height.
    pub inline fn height(self: Rect) f64 {
        return self.y1 - self.y0;
    }

    /// Returns the minimum value for the x-coordinate of the rectangle.
    pub inline fn minX(self: Rect) f64 {
        return @min(self.x0, self.x1);
    }

    /// Returns the maximum value for the x-coordinate of the rectangle.
    pub inline fn maxX(self: Rect) f64 {
        return @max(self.x0, self.x1);
    }

    /// Returns the minimum value for the y-coordinate of the rectangle.
    pub inline fn minY(self: Rect) f64 {
        return @min(self.y0, self.y1);
    }

    /// Returns the maximum value for the y-coordinate of the rectangle.
    pub inline fn maxY(self: Rect) f64 {
        return @max(self.y0, self.y1);
    }

    /// The origin of the rectangle.
    ///
    /// This is the top left corner in a y-down space and with non-negative
    /// width and height.
    pub inline fn origin(self: Rect) Point {
        return Point.new(self.x0, self.y0);
    }

    /// The size of the rectangle.
    pub inline fn size(self: Rect) Size {
        return Size.new(self.width(), self.height());
    }

    /// The area of the rectangle.
    pub inline fn area(self: Rect) f64 {
        return self.width() * self.height();
    }

    /// Whether this rectangle has zero area.
    pub inline fn isZeroArea(self: Rect) bool {
        return self.area() == 0.0;
    }

    /// The center point of the rectangle.
    pub inline fn center(self: Rect) Point {
        return Point.new(0.5 * (self.x0 + self.x1), 0.5 * (self.y0 + self.y1));
    }

    /// Returns `true` if `point` lies within `self`.
    pub inline fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x0 and point.x < self.x1 and
            point.y >= self.y0 and point.y < self.y1;
    }

    /// Take absolute value of width and height.
    ///
    /// The resulting rect has the same extents as the original, but is
    /// guaranteed to have non-negative width and height.
    pub inline fn abs(self: Rect) Rect {
        return Rect.new(
            @min(self.x0, self.x1),
            @min(self.y0, self.y1),
            @max(self.x0, self.x1),
            @max(self.y0, self.y1),
        );
    }

    /// The smallest rectangle enclosing two rectangles.
    ///
    /// Results are valid only if width and height are non-negative.
    pub inline fn unionWith(self: Rect, other: Rect) Rect {
        return Rect.new(
            @min(self.x0, other.x0),
            @min(self.y0, other.y0),
            @max(self.x1, other.x1),
            @max(self.y1, other.y1),
        );
    }

    /// Compute the union with one point.
    ///
    /// This method includes the perimeter of zero-area rectangles.
    pub inline fn unionPt(self: Rect, pt: Point) Rect {
        return Rect.new(
            @min(self.x0, pt.x),
            @min(self.y0, pt.y),
            @max(self.x1, pt.x),
            @max(self.y1, pt.y),
        );
    }

    /// The intersection of two rectangles.
    ///
    /// The result always has non-negative width and height.
    pub inline fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x0, other.x0);
        const y0 = @max(self.y0, other.y0);
        const x1 = @min(self.x1, other.x1);
        const y1 = @min(self.y1, other.y1);
        return Rect.new(x0, y0, @max(x1, x0), @max(y1, y0));
    }

    /// Determines whether this rectangle overlaps with another in any way.
    ///
    /// The edge of the rectangle is considered to be part of itself, meaning
    /// that two rectangles that share an edge overlap.
    pub inline fn overlaps(self: Rect, other: Rect) bool {
        return self.x0 <= other.x1 and self.x1 >= other.x0 and
            self.y0 <= other.y1 and self.y1 >= other.y0;
    }

    /// Returns whether this rectangle contains another rectangle.
    pub inline fn containsRect(self: Rect, other: Rect) bool {
        return self.x0 <= other.x0 and self.y0 <= other.y0 and
            self.x1 >= other.x1 and self.y1 >= other.y1;
    }

    /// Expand a rectangle by a constant amount in both directions.
    pub inline fn inflate(self: Rect, delta_width: f64, delta_height: f64) Rect {
        return Rect.new(
            self.x0 - delta_width,
            self.y0 - delta_height,
            self.x1 + delta_width,
            self.y1 + delta_height,
        );
    }

    /// Returns a new `Rect` with each coordinate value rounded to the nearest
    /// integer.
    pub inline fn round(self: Rect) Rect {
        return Rect.new(@round(self.x0), @round(self.y0), @round(self.x1), @round(self.y1));
    }

    /// Returns a new `Rect` with each coordinate value rounded up.
    pub inline fn ceil(self: Rect) Rect {
        return Rect.new(@ceil(self.x0), @ceil(self.y0), @ceil(self.x1), @ceil(self.y1));
    }

    /// Returns a new `Rect` with each coordinate value rounded down.
    pub inline fn floor(self: Rect) Rect {
        return Rect.new(@floor(self.x0), @floor(self.y0), @floor(self.x1), @floor(self.y1));
    }

    /// Returns the smallest possible `Rect` with integer coordinates that is
    /// a superset of `self`.
    pub inline fn expand(self: Rect) Rect {
        const x0 = if (self.x0 < self.x1) @floor(self.x0) else @ceil(self.x0);
        const x1 = if (self.x0 < self.x1) @ceil(self.x1) else @floor(self.x1);
        const y0 = if (self.y0 < self.y1) @floor(self.y0) else @ceil(self.y0);
        const y1 = if (self.y0 < self.y1) @ceil(self.y1) else @floor(self.y1);
        return Rect.new(x0, y0, x1, y1);
    }

    /// Returns the biggest possible `Rect` with integer coordinates that is a
    /// subset of `self`.
    pub inline fn trunc(self: Rect) Rect {
        const x0 = if (self.x0 < self.x1) @ceil(self.x0) else @floor(self.x0);
        const x1 = if (self.x0 < self.x1) @floor(self.x1) else @ceil(self.x1);
        const y0 = if (self.y0 < self.y1) @ceil(self.y0) else @floor(self.y0);
        const y1 = if (self.y0 < self.y1) @floor(self.y1) else @ceil(self.y1);
        return Rect.new(x0, y0, x1, y1);
    }

    /// Scales the `Rect` by `factor` with respect to the origin (0, 0).
    pub inline fn scaleFromOrigin(self: Rect, factor: f64) Rect {
        return Rect.new(self.x0 * factor, self.y0 * factor, self.x1 * factor, self.y1 * factor);
    }

    /// The aspect ratio of this `Rect`, defined as width divided by height.
    pub inline fn aspectRatioWidth(self: Rect) f64 {
        return self.size().aspectRatioWidth();
    }

    /// The inverse of the aspect ratio (height/width).
    ///
    /// Deprecated upstream; kept for parity.
    pub inline fn aspectRatio(self: Rect) f64 {
        return self.size().aspectRatio();
    }

    /// Returns the largest possible `Rect` with the given `aspect_ratio`
    /// (width/height) that is fully contained in `self`, centered if smaller.
    pub inline fn inscribedRectWithAspectRatio(self: Rect, aspect_ratio: f64) Rect {
        const self_size = self.size();
        const self_aspect = self_size.aspectRatioWidth();

        // If `self_aspect` is NaN then we're the 0x0 rectangle (or have NaN).
        // We don't want NaNs in the output for the 0x0 rectangle.
        if (std.math.isNan(self_aspect) or @abs(self_aspect - aspect_ratio) < 1e-9) {
            return self;
        } else if (@abs(self_aspect) < @abs(aspect_ratio)) {
            // Our width/height is less than the requested width/height.
            // Shrink y to fit.
            const new_height = self_size.width * (1.0 / aspect_ratio);
            const gap = (self_size.height - new_height) * 0.5;
            return Rect.new(self.x0, self.y0 + gap, self.x1, self.y1 - gap);
        } else {
            // Shrink x to fit.
            const new_width = self_size.height * aspect_ratio;
            const gap = (self_size.width - new_width) * 0.5;
            return Rect.new(self.x0 + gap, self.y0, self.x1 - gap, self.y1);
        }
    }

    /// Deprecated upstream: takes an inverse aspect ratio (height/width).
    pub inline fn containedRectWithAspectRatio(self: Rect, inverse_aspect_ratio: f64) Rect {
        return self.inscribedRectWithAspectRatio(1.0 / inverse_aspect_ratio);
    }

    /// Is this rectangle finite?
    pub inline fn isFinite(self: Rect) bool {
        return std.math.isFinite(self.x0) and std.math.isFinite(self.x1) and
            std.math.isFinite(self.y0) and std.math.isFinite(self.y1);
    }

    /// Is this rectangle `NaN`?
    pub inline fn isNan(self: Rect) bool {
        return std.math.isNan(self.x0) or std.math.isNan(self.y0) or
            std.math.isNan(self.x1) or std.math.isNan(self.y1);
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Rect + Vec2`.
    pub inline fn addVec(self: Rect, v: Vec2) Rect {
        return Rect.new(self.x0 + v.x, self.y0 + v.y, self.x1 + v.x, self.y1 + v.y);
    }

    /// Upstream `Rect - Vec2`.
    pub inline fn subVec(self: Rect, v: Vec2) Rect {
        return Rect.new(self.x0 - v.x, self.y0 - v.y, self.x1 - v.x, self.y1 - v.y);
    }

    /// Upstream `Rect - Rect -> Insets`.
    pub inline fn subRect(self: Rect, other: Rect) Insets {
        return Insets.new(
            other.x0 - self.x0,
            other.y0 - self.y0,
            self.x1 - other.x1,
            self.y1 - other.y1,
        );
    }

    // ------------------------------------------------- shape duck typing

    /// Convert to a `BezPath`.
    ///
    /// Allocates a `BezPath` with `allocator`; the caller owns it and must
    /// call `BezPath.deinit`.
    ///
    /// Upstream `Shape::path_elements` for `Rect` yields
    /// MoveTo/LineTo/LineTo/LineTo/ClosePath.
    pub fn toPath(self: Rect, tolerance: f64, allocator: std.mem.Allocator) !BezPath {
        _ = tolerance;
        var path = BezPath.init();
        errdefer path.deinit(allocator);
        try path.append(allocator, PathEl.moveTo(Point.new(self.x0, self.y0)));
        try path.append(allocator, PathEl.lineTo(Point.new(self.x1, self.y0)));
        try path.append(allocator, PathEl.lineTo(Point.new(self.x1, self.y1)));
        try path.append(allocator, PathEl.lineTo(Point.new(self.x0, self.y1)));
        try path.append(allocator, PathEl.closePath());
        return path;
    }

    /// The smallest rectangle that encloses the shape.
    pub inline fn boundingBox(self: Rect) Rect {
        return self.abs();
    }

    /// Total length of the perimeter.
    pub inline fn perimeter(self: Rect, accuracy: f64) f64 {
        _ = accuracy;
        return 2.0 * (@abs(self.width()) + @abs(self.height()));
    }

    /// The winding number of a point.
    ///
    /// Designed so that if the plane is tiled with rectangles, the winding
    /// number will be nonzero for exactly one of them.
    pub inline fn winding(self: Rect, pt: Point) i32 {
        const xmin = @min(self.x0, self.x1);
        const xmax = @max(self.x0, self.x1);
        const ymin = @min(self.y0, self.y1);
        const ymax = @max(self.y0, self.y1);
        if (pt.x >= xmin and pt.x < xmax and pt.y >= ymin and pt.y < ymax) {
            if ((self.x1 > self.x0) != (self.y1 > self.y0)) {
                return -1;
            }
            return 1;
        }
        return 0;
    }
};

test "rect area_sign" {
    const testing = std.testing;
    const r = Rect.new(0.0, 0.0, 10.0, 10.0);
    const center = r.center();
    try testing.expect(@abs(r.area() - 100.0) < 1e-7);
    try testing.expectEqual(@as(i32, 1), r.winding(center));

    var p = try r.toPath(1e-9, testing.allocator);
    defer p.deinit(testing.allocator);
    try testing.expect(@abs(r.area() - p.area()) < 1e-7);
    try testing.expectEqual(r.winding(center), p.winding(center));

    const r_flip = Rect.new(0.0, 10.0, 10.0, 0.0);
    try testing.expect(@abs(r_flip.area() + 100.0) < 1e-7);
    try testing.expectEqual(@as(i32, -1), r_flip.winding(Point.new(5.0, 5.0)));

    var p_flip = try r_flip.toPath(1e-9, testing.allocator);
    defer p_flip.deinit(testing.allocator);
    try testing.expect(@abs(r_flip.area() - p_flip.area()) < 1e-7);
    try testing.expectEqual(r_flip.winding(center), p_flip.winding(center));
}

test "rect contained_rect_with_aspect_ratio" {
    const testing = std.testing;
    const case = struct {
        fn check(outer: [4]f64, aspect_ratio: f64, expected: [4]f64) !void {
            const outer_rect = Rect.new(outer[0], outer[1], outer[2], outer[3]);
            const expected_rect = Rect.new(expected[0], expected[1], expected[2], expected[3]);
            try testing.expectEqualDeep(expected_rect, outer_rect.containedRectWithAspectRatio(aspect_ratio));
            try testing.expect(
                @abs(expected_rect.size().width) <= @abs(outer_rect.size().width) and
                    @abs(expected_rect.size().width) <= @abs(outer_rect.size().height),
            );
        }
    }.check;
    // squares (different point orderings)
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 1.0, [4]f64{ 0.0, 5.0, 10.0, 15.0 });
    try case([4]f64{ 0.0, 20.0, 10.0, 0.0 }, 1.0, [4]f64{ 0.0, 5.0, 10.0, 15.0 });
    try case([4]f64{ 10.0, 0.0, 0.0, 20.0 }, 1.0, [4]f64{ 10.0, 15.0, 0.0, 5.0 });
    try case([4]f64{ 10.0, 20.0, 0.0, 0.0 }, 1.0, [4]f64{ 10.0, 15.0, 0.0, 5.0 });
    // non-square
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 0.5, [4]f64{ 0.0, 7.5, 10.0, 12.5 });
    // same aspect ratio
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 2.0, [4]f64{ 0.0, 0.0, 10.0, 20.0 });
    // negative aspect ratio
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, -1.0, [4]f64{ 0.0, 15.0, 10.0, 5.0 });
    // infinite aspect ratio
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, std.math.inf(f64), [4]f64{ 5.0, 0.0, 5.0, 20.0 });
    // zero aspect ratio
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 0.0, [4]f64{ 0.0, 10.0, 10.0, 10.0 });
    // zero width rect
    try case([4]f64{ 0.0, 0.0, 0.0, 20.0 }, 1.0, [4]f64{ 0.0, 10.0, 0.0, 10.0 });
    // many zeros
    try case([4]f64{ 0.0, 0.0, 0.0, 20.0 }, 0.0, [4]f64{ 0.0, 10.0, 0.0, 10.0 });
    // everything zero
    try case([4]f64{ 0.0, 0.0, 0.0, 0.0 }, 0.0, [4]f64{ 0.0, 0.0, 0.0, 0.0 });
}

test "rect inscribed_rect_with_aspect_ratio" {
    const testing = std.testing;
    const case = struct {
        fn check(outer: [4]f64, aspect_ratio: f64, expected: [4]f64) !void {
            const outer_rect = Rect.new(outer[0], outer[1], outer[2], outer[3]);
            const expected_rect = Rect.new(expected[0], expected[1], expected[2], expected[3]);
            try testing.expectEqualDeep(expected_rect, outer_rect.inscribedRectWithAspectRatio(aspect_ratio));
        }
    }.check;
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 1.0, [4]f64{ 0.0, 5.0, 10.0, 15.0 });
    try case([4]f64{ 0.0, 20.0, 10.0, 0.0 }, 1.0, [4]f64{ 0.0, 5.0, 10.0, 15.0 });
    try case([4]f64{ 10.0, 0.0, 0.0, 20.0 }, 1.0, [4]f64{ 10.0, 15.0, 0.0, 5.0 });
    try case([4]f64{ 10.0, 20.0, 0.0, 0.0 }, 1.0, [4]f64{ 10.0, 15.0, 0.0, 5.0 });
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 0.5, [4]f64{ 0.0, 0.0, 10.0, 20.0 });
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 2.0, [4]f64{ 0.0, 7.5, 10.0, 12.5 });
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, -1.0, [4]f64{ 0.0, 15.0, 10.0, 5.0 });
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, std.math.inf(f64), [4]f64{ 0.0, 10.0, 10.0, 10.0 });
    try case([4]f64{ 0.0, 0.0, 10.0, 20.0 }, 0.0, [4]f64{ 5.0, 0.0, 5.0, 20.0 });
    try case([4]f64{ 0.0, 0.0, 0.0, 20.0 }, 1.0, [4]f64{ 0.0, 10.0, 0.0, 10.0 });
    try case([4]f64{ 0.0, 0.0, 0.0, 20.0 }, 0.0, [4]f64{ 0.0, 0.0, 0.0, 20.0 });
    try case([4]f64{ 0.0, 0.0, 20.0, 0.0 }, 0.0, [4]f64{ 10.0, 0.0, 10.0, 0.0 });
    try case([4]f64{ 0.0, 0.0, 0.0, 0.0 }, 0.0, [4]f64{ 0.0, 0.0, 0.0, 0.0 });
}

test "rect overlaps and contains" {
    const testing = std.testing;
    const outer = Rect.new(0.0, 0.0, 10.0, 10.0);
    const inner = Rect.new(2.0, 2.0, 4.0, 4.0);
    try testing.expect(outer.overlaps(inner));
    try testing.expect(outer.containsRect(inner));

    const overlapping = Rect.new(5.0, 5.0, 15.0, 15.0);
    try testing.expect(outer.overlaps(overlapping));
    try testing.expect(!outer.containsRect(overlapping));

    const disjoint = Rect.new(11.0, 11.0, 15.0, 15.0);
    try testing.expect(!outer.overlaps(disjoint));
    try testing.expect(!outer.containsRect(disjoint));

    // Sharing an edge counts as overlapping.
    const sharing = Rect.new(10.0, 0.0, 20.0, 10.0);
    try testing.expect(outer.overlaps(sharing));

    const negative = Rect.new(-10.0, -10.0, -5.0, -5.0);
    try testing.expect(!outer.overlaps(negative));
}

test "rect intersect zero and expand/trunc" {
    const testing = std.testing;
    // These rectangles don't overlap vertically.
    const a = Rect.new(25.0, 101.0, 200.0, 130.0);
    const b = Rect.new(0.0, 0.0, 100.0, 100.0);
    for ([2]Rect{ a.intersect(b), b.intersect(a) }) |intersection| {
        try testing.expectEqual(@as(f64, 25.0), intersection.x0);
        try testing.expectEqual(@as(f64, 100.0), intersection.x1);
        try testing.expectEqual(@as(f64, 0.0), intersection.area());
        try testing.expectEqual(intersection.y0, intersection.y1);
    }

    try testing.expectEqualDeep(
        Rect.new(3.0, 3.0, 6.0, 5.0),
        Rect.new(3.3, 3.6, 5.6, 4.1).expand(),
    );
    try testing.expectEqualDeep(
        Rect.new(-4.0, -4.0, 6.0, 5.0),
        Rect.new(-3.3, -3.6, 5.6, 4.1).expand(),
    );
    try testing.expectEqualDeep(
        Rect.new(4.0, 4.0, 5.0, 4.0),
        Rect.new(3.3, 3.6, 5.6, 4.1).trunc(),
    );
}

test "rect aspect_ratio_width" {
    const testing = std.testing;
    try testing.expect(@abs(Rect.new(0.0, 0.0, 1.0, 1.0).aspectRatioWidth() - 1.0) < 1e-6);
    try testing.expect(@abs(Rect.new(0.0, 0.0, 16.0, 10.0).aspectRatioWidth() - 1.6) < 1e-6);
    try testing.expect(@abs(Rect.new(0.0, 0.0, 1920.0, 1080.0).aspectRatioWidth() - (16.0 / 9.0)) < 1e-6);
}
