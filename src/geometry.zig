//! Geometry primitives: units, points, sizes, bounds, edges, corners and lengths.
//! Port of gpui/src/geometry.rs.

const std = @import("std");
const math = std.math;
const testing = std.testing;

pub const Pixels = f32;
pub const ScaledPixels = f32;
pub const DevicePixels = i32;

/// Placeholder until the platform display module exists.
pub const DisplayId = u32;

/// Axis in a 2D cartesian space.
pub const Axis = enum {
    horizontal,
    vertical,

    /// Swap this axis to the opposite axis.
    pub inline fn invert(self: Axis) Axis {
        return switch (self) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
    }
};

/// A position of a box in a 2D space, used for alignment and anchoring.
pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    top_center,
    bottom_center,
    left_center,
    right_center,

    pub fn opposite(self: Anchor) Anchor {
        return switch (self) {
            .top_left => .bottom_right,
            .top_right => .bottom_left,
            .bottom_left => .top_right,
            .bottom_right => .top_left,
            .top_center => .bottom_center,
            .bottom_center => .top_center,
            .left_center => .right_center,
            .right_center => .left_center,
        };
    }

    pub fn other_side_along(self: Anchor, axis: Axis) Anchor {
        return switch (axis) {
            .vertical => switch (self) {
                .top_left => .bottom_left,
                .top_right => .bottom_right,
                .bottom_left => .top_left,
                .bottom_right => .top_right,
                .top_center => .bottom_center,
                .bottom_center => .top_center,
                .left_center => .left_center,
                .right_center => .right_center,
            },
            .horizontal => switch (self) {
                .top_left => .top_right,
                .top_right => .top_left,
                .bottom_left => .bottom_right,
                .bottom_right => .bottom_left,
                .top_center => .top_center,
                .bottom_center => .bottom_center,
                .left_center => .right_center,
                .right_center => .left_center,
            },
        };
    }

    pub inline fn is_center(self: Anchor) bool {
        return switch (self) {
            .top_center, .bottom_center, .left_center, .right_center => true,
            else => false,
        };
    }

    pub inline fn is_bottom(self: Anchor) bool {
        return switch (self) {
            .bottom_center, .bottom_left, .bottom_right => true,
            else => false,
        };
    }
};

/// One of the four corners of a box.
pub const Corner = enum {
    top_left,
    top_right,
    bottom_right,
    bottom_left,
};

/// Returns `0` for numeric types, or the type's `default` declaration.
fn fieldDefault(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int, .float => 0,
        .optional => null,
        .bool => false,
        .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "default")) T.default else undefined,
        else => undefined,
    };
}

/// Maps comptime literals to `f32` so `point(1, 2)` yields a `Point(f32)`.
fn Coord(comptime T: type) type {
    return switch (T) {
        comptime_float, comptime_int => f32,
        else => T,
    };
}

/// Divides, truncating integers toward zero as Rust's `/` does.
inline fn divide(numerator: anytype, denominator: anytype) @TypeOf(numerator) {
    return switch (@typeInfo(@TypeOf(numerator))) {
        .int => @divTrunc(numerator, denominator),
        else => numerator / denominator,
    };
}

/// Halves a numeric value, truncating integers toward zero.
pub inline fn half(value: anytype) @TypeOf(value) {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => @divTrunc(value, 2),
        .float => value / 2,
        else => @compileError("half is only defined for numeric types"),
    };
}

/// Describes a location in a 2D cartesian space.
pub fn Point(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The x coordinate of the point.
        x: T = fieldDefault(T),
        /// The y coordinate of the point.
        y: T = fieldDefault(T),

        pub inline fn new(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        /// Transforms the point to a `Point(U)` by applying `f` to both coordinates.
        pub fn map(self: Self, comptime U: type, f: fn (T) U) Point(U) {
            return .{ .x = f(self.x), .y = f(self.y) };
        }

        /// Scales the point by a factor, producing scaled pixel coordinates.
        pub inline fn scale(self: Self, factor: f32) Point(ScaledPixels) {
            return .{ .x = self.x * factor, .y = self.y * factor };
        }

        /// Euclidean distance from the origin to this point.
        pub fn magnitude(self: Self) f64 {
            const squared_sum = self.x * self.x + self.y * self.y;
            return @sqrt(@as(f64, squared_sum));
        }

        /// Position of this point relative to `origin`.
        pub inline fn relative_to(self: Self, origin: Self) Self {
            return .{ .x = self.x - origin.x, .y = self.y - origin.y };
        }

        /// Component-wise maximum of `self` and `other`.
        pub inline fn max(self: Self, other: Self) Self {
            return .{
                .x = if (self.x > other.x) self.x else other.x,
                .y = if (self.y > other.y) self.y else other.y,
            };
        }

        /// Component-wise minimum of `self` and `other`.
        pub inline fn min(self: Self, other: Self) Self {
            return .{
                .x = if (self.x <= other.x) self.x else other.x,
                .y = if (self.y <= other.y) self.y else other.y,
            };
        }

        /// Constrains the point to the range `[min_point, max_point]`.
        pub inline fn clamp(self: Self, min_point: Self, max_point: Self) Self {
            return self.max(min_point).min(max_point);
        }

        pub inline fn add(self: Self, rhs: Self) Self {
            return .{ .x = self.x + rhs.x, .y = self.y + rhs.y };
        }

        pub inline fn sub(self: Self, rhs: Self) Self {
            return .{ .x = self.x - rhs.x, .y = self.y - rhs.y };
        }

        pub inline fn mul(self: Self, rhs: T) Self {
            return .{ .x = self.x * rhs, .y = self.y * rhs };
        }

        pub inline fn div(self: Self, rhs: T) Self {
            return .{ .x = divide(self.x, rhs), .y = divide(self.y, rhs) };
        }

        pub inline fn neg(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y };
        }

        pub inline fn eq(self: Self, other: Self) bool {
            return self.x == other.x and self.y == other.y;
        }

        pub inline fn along(self: Self, axis: Axis) T {
            return switch (axis) {
                .horizontal => self.x,
                .vertical => self.y,
            };
        }

        pub inline fn apply_along(self: Self, axis: Axis, f: fn (T) T) Self {
            return switch (axis) {
                .horizontal => .{ .x = f(self.x), .y = self.y },
                .vertical => .{ .x = self.x, .y = f(self.y) },
            };
        }
    };
}

/// Constructs a `Point` with the given coordinates.
pub inline fn point(x: anytype, y: @TypeOf(x)) Point(Coord(@TypeOf(x))) {
    return .{ .x = x, .y = y };
}

/// A two-dimensional size with width and height.
pub fn Size(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The width component of the size.
        width: T = fieldDefault(T),
        /// The height component of the size.
        height: T = fieldDefault(T),

        pub inline fn new(width: T, height: T) Self {
            return .{ .width = width, .height = height };
        }

        /// Width and height multiplied together.
        pub inline fn area(self: Self) T {
            return self.width * self.height;
        }

        /// Applies `f` to width and height, producing a `Size(U)`.
        pub fn map(self: Self, comptime U: type, f: fn (T) U) Size(U) {
            return .{ .width = f(self.width), .height = f(self.height) };
        }

        /// Center point of the size, measured from the origin.
        pub inline fn center(self: Self) Point(T) {
            return .{ .x = half(self.width), .y = half(self.height) };
        }

        /// Scales width and height by a factor.
        pub inline fn scale(self: Self, factor: f32) Size(ScaledPixels) {
            return .{ .width = self.width * factor, .height = self.height * factor };
        }

        /// Converts physical to logical pixels.
        pub inline fn to_pixels(self: Size(DevicePixels), scale_factor: f32) Size(Pixels) {
            return .{
                .width = @as(f32, @floatFromInt(self.width)) / scale_factor,
                .height = @as(f32, @floatFromInt(self.height)) / scale_factor,
            };
        }

        /// Converts logical to physical pixels.
        pub inline fn to_device_pixels(self: Size(Pixels), scale_factor: f32) Size(DevicePixels) {
            return .{
                .width = @intFromFloat(@round(self.width * scale_factor)),
                .height = @intFromFloat(@round(self.height * scale_factor)),
            };
        }

        pub inline fn along(self: Self, axis: Axis) T {
            return switch (axis) {
                .horizontal => self.width,
                .vertical => self.height,
            };
        }

        pub inline fn apply_along(self: Self, axis: Axis, f: fn (T) T) Self {
            return switch (axis) {
                .horizontal => .{ .width = f(self.width), .height = self.height },
                .vertical => .{ .width = self.width, .height = f(self.height) },
            };
        }

        /// Component-wise maximum of `self` and `other`.
        pub inline fn max(self: Self, other: Self) Self {
            return .{
                .width = if (self.width >= other.width) self.width else other.width,
                .height = if (self.height >= other.height) self.height else other.height,
            };
        }

        /// Component-wise minimum of `self` and `other`.
        pub inline fn min(self: Self, other: Self) Self {
            return .{
                .width = if (self.width >= other.width) other.width else self.width,
                .height = if (self.height >= other.height) other.height else self.height,
            };
        }

        pub inline fn add(self: Self, rhs: Self) Self {
            return .{ .width = self.width + rhs.width, .height = self.height + rhs.height };
        }

        pub inline fn sub(self: Self, rhs: Self) Self {
            return .{ .width = self.width - rhs.width, .height = self.height - rhs.height };
        }

        pub inline fn mul(self: Self, rhs: T) Self {
            return .{ .width = self.width * rhs, .height = self.height * rhs };
        }

        pub inline fn div(self: Self, rhs: T) Self {
            return .{ .width = divide(self.width, rhs), .height = divide(self.height, rhs) };
        }

        pub inline fn neg(self: Self) Self {
            return .{ .width = -self.width, .height = -self.height };
        }

        pub inline fn eq(self: Self, other: Self) bool {
            return self.width == other.width and self.height == other.height;
        }

        /// A size whose width and height are both zero.
        pub inline fn zero() Self {
            return .{ .width = 0, .height = 0 };
        }

        /// A `Size<Length>` filling the available space in both dimensions.
        pub inline fn full() Size(Length) {
            return .{ .width = to_length(relative(1)), .height = to_length(relative(1)) };
        }

        /// A `Size<Length>` with both dimensions set to `auto`.
        pub inline fn auto() Size(Length) {
            return .{ .width = .auto, .height = .auto };
        }
    };
}

/// Constructs a `Size` with the given width and height.
pub inline fn size(width: anytype, height: @TypeOf(width)) Size(Coord(@TypeOf(width))) {
    return .{ .width = width, .height = height };
}

/// A rectangle described by an origin (top-left corner) and a size.
pub fn Bounds(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The origin point of this area.
        origin: Point(T) = .{},
        /// The size of the rectangle.
        size: Size(T) = .{},

        pub inline fn new(origin: Point(T), sz: Size(T)) Self {
            return .{ .origin = origin, .size = sz };
        }

        pub inline fn eq(self: Self, other: Self) bool {
            return self.origin.eq(other.origin) and self.size.eq(other.size);
        }

        /// Constructs a `Bounds` from its top-left and bottom-right corners.
        pub inline fn from_corners(upper_left: Point(T), lower_right: Point(T)) Self {
            return .{
                .origin = .{ .x = upper_left.x, .y = upper_left.y },
                .size = .{ .width = lower_right.x - upper_left.x, .height = lower_right.y - upper_left.y },
            };
        }

        /// Constructs bounds where `corner` is placed at `origin`.
        pub inline fn from_anchor_and_size(anchor: Anchor, origin: Point(T), sz: Size(T)) Self {
            const new_origin: Point(T) = switch (anchor) {
                .top_left => origin,
                .top_right => .{ .x = origin.x - sz.width, .y = origin.y },
                .bottom_left => .{ .x = origin.x, .y = origin.y - sz.height },
                .bottom_right => .{ .x = origin.x - sz.width, .y = origin.y - sz.height },
                .top_center => .{ .x = origin.x - half(sz.width), .y = origin.y },
                .bottom_center => .{ .x = origin.x - half(sz.width), .y = origin.y - sz.height },
                .left_center => .{ .x = origin.x, .y = origin.y - half(sz.height) },
                .right_center => .{ .x = origin.x - sz.width, .y = origin.y - half(sz.height) },
            };
            return .{ .origin = new_origin, .size = sz };
        }

        /// Creates bounds of `sz` centered at `center`.
        pub inline fn centered_at(center_point: Point(T), sz: Size(T)) Self {
            return .{
                .origin = .{ .x = center_point.x - half(sz.width), .y = center_point.y - half(sz.height) },
                .size = sz,
            };
        }

        pub inline fn top(self: Self) T {
            return self.origin.y;
        }

        pub inline fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }

        pub inline fn left(self: Self) T {
            return self.origin.x;
        }

        pub inline fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }

        pub inline fn top_left(self: Self) Point(T) {
            return self.origin;
        }

        pub inline fn top_right(self: Self) Point(T) {
            return .{ .x = self.origin.x + self.size.width, .y = self.origin.y };
        }

        pub inline fn bottom_right(self: Self) Point(T) {
            return .{ .x = self.origin.x + self.size.width, .y = self.origin.y + self.size.height };
        }

        pub inline fn bottom_left(self: Self) Point(T) {
            return .{ .x = self.origin.x, .y = self.origin.y + self.size.height };
        }

        pub inline fn top_center(self: Self) Point(T) {
            return .{ .x = self.origin.x + half(self.size.width), .y = self.origin.y };
        }

        pub inline fn bottom_center(self: Self) Point(T) {
            return .{ .x = self.origin.x + half(self.size.width), .y = self.origin.y + self.size.height };
        }

        pub inline fn left_center(self: Self) Point(T) {
            return .{ .x = self.origin.x, .y = self.origin.y + half(self.size.height) };
        }

        pub inline fn right_center(self: Self) Point(T) {
            return .{ .x = self.origin.x + self.size.width, .y = self.origin.y + half(self.size.height) };
        }

        /// Center point of the bounds.
        pub inline fn center(self: Self) Point(T) {
            return .{
                .x = self.origin.x + half(self.size.width),
                .y = self.origin.y + half(self.size.height),
            };
        }

        /// Sum of width and height.
        pub inline fn half_perimeter(self: Self) T {
            return self.size.width + self.size.height;
        }

        /// Returns the requested corner or edge midpoint.
        pub inline fn corner(self: Self, anchor: Anchor) Point(T) {
            return switch (anchor) {
                .top_left => self.origin,
                .top_right => self.top_right(),
                .bottom_left => self.bottom_left(),
                .bottom_right => self.bottom_right(),
                .top_center => self.top_center(),
                .bottom_center => self.bottom_center(),
                .left_center => self.left_center(),
                .right_center => self.right_center(),
            };
        }

        /// Grows the bounds by `amount` in every direction.
        pub inline fn dilate(self: Self, amount: T) Self {
            const double_amount = amount + amount;
            return .{
                .origin = self.origin.sub(.{ .x = amount, .y = amount }),
                .size = self.size.add(.{ .width = double_amount, .height = double_amount }),
            };
        }

        /// Shrinks the bounds by `amount` in every direction.
        pub inline fn inset(self: Self, amount: T) Self {
            return self.dilate(-amount);
        }

        /// Extends the bounds by different amounts on each side.
        pub inline fn extend(self: Self, amount: Edges(T)) Self {
            return .{
                .origin = self.origin.sub(.{ .x = amount.left, .y = amount.top }),
                .size = self.size.add(.{
                    .width = amount.left + amount.right,
                    .height = amount.top + amount.bottom,
                }),
            };
        }

        /// Whether the two bounds overlap in area.
        pub inline fn intersects(self: Self, other: Self) bool {
            const my_lower_right = self.bottom_right();
            const their_lower_right = other.bottom_right();
            return self.origin.x < their_lower_right.x and
                my_lower_right.x > other.origin.x and
                self.origin.y < their_lower_right.y and
                my_lower_right.y > other.origin.y;
        }

        /// Overlapping region of two bounds; zero-sized if they do not intersect.
        pub inline fn intersect(self: Self, other: Self) Self {
            const upper_left = self.origin.max(other.origin);
            const lower_right = self.bottom_right().min(other.bottom_right()).max(upper_left);
            return from_corners(upper_left, lower_right);
        }

        /// Smallest bounds containing both `self` and `other`.
        // `union` is a Zig keyword, so the method uses quoted identifier syntax.
        pub inline fn @"union"(self: Self, other: Self) Self {
            const top_left_point = self.origin.min(other.origin);
            const lower_right = self.bottom_right().max(other.bottom_right());
            return from_corners(top_left_point, lower_right);
        }

        /// Space between `self` and the edges of `outer`.
        pub inline fn space_within(self: Self, outer: Self) Edges(T) {
            return .{
                .top = self.top() - outer.top(),
                .right = outer.right() - self.right(),
                .bottom = outer.bottom() - self.bottom(),
                .left = self.left() - outer.left(),
            };
        }

        /// Whether `point` lies inside the bounds, including the top and left edges.
        pub inline fn contains(self: Self, point_to_check: Point(T)) bool {
            return point_to_check.x >= self.origin.x and
                point_to_check.x < self.origin.x + self.size.width and
                point_to_check.y >= self.origin.y and
                point_to_check.y < self.origin.y + self.size.height;
        }

        /// Whether these bounds are entirely enclosed by `other`.
        pub inline fn is_contained_within(self: Self, other: Self) bool {
            return other.contains(self.origin) and other.contains(self.bottom_right());
        }

        /// Converts `point` to the coordinate space of these bounds, or null if outside.
        pub inline fn localize(self: Self, point_to_localize: Point(T)) ?Point(T) {
            if (!self.contains(point_to_localize)) return null;
            return point_to_localize.relative_to(self.origin);
        }

        /// True if either width or height is less than or equal to zero.
        pub inline fn is_empty(self: Self) bool {
            return self.size.width <= 0 or self.size.height <= 0;
        }

        /// Applies `f` to origin and size, producing `Bounds(U)`.
        pub fn map(self: Self, comptime U: type, f: fn (T) U) Bounds(U) {
            return .{ .origin = self.origin.map(U, f), .size = self.size.map(U, f) };
        }

        /// Applies `f` to the origin only.
        pub inline fn map_origin(self: Self, f: fn (T) T) Self {
            return .{ .origin = self.origin.map(T, f), .size = self.size };
        }

        /// Applies `f` to the size only.
        pub inline fn map_size(self: Self, f: fn (T) T) Self {
            return .{ .origin = self.origin, .size = self.size.map(T, f) };
        }

        /// Scales origin and size by `factor` (display scaling).
        pub inline fn scale(self: Self, factor: f32) Bounds(ScaledPixels) {
            return .{ .origin = self.origin.scale(factor), .size = self.size.scale(factor) };
        }

        /// Converts logical to physical pixels.
        pub inline fn to_device_pixels(self: Bounds(Pixels), factor: f32) Bounds(DevicePixels) {
            return .{
                .origin = .{
                    .x = @intFromFloat(@round(self.origin.x * factor)),
                    .y = @intFromFloat(@round(self.origin.y * factor)),
                },
                .size = self.size.to_device_pixels(factor),
            };
        }

        /// Converts physical to logical pixels.
        pub inline fn to_pixels(self: Bounds(DevicePixels), scale_factor: f32) Bounds(Pixels) {
            return .{
                .origin = .{
                    .x = @as(f32, @floatFromInt(self.origin.x)) / scale_factor,
                    .y = @as(f32, @floatFromInt(self.origin.y)) / scale_factor,
                },
                .size = self.size.to_pixels(scale_factor),
            };
        }

        /// Bounds of `sz` centered in the display, or the default 1920x1080 display.
        /// `display_id` is ignored until display lookup is ported.
        pub fn centered(display_id: ?DisplayId, sz: Size(Pixels), cx: anytype) Bounds(Pixels) {
            _ = display_id;
            const display_size: Size(Pixels) = if (comptime has_primary_display_size(@TypeOf(cx)))
                cx.primary_display_size()
            else
                size(1920, 1080);
            const visible: Bounds(Pixels) = .{ .origin = point(0, 0), .size = display_size };
            return Bounds(Pixels).centered_at(visible.center(), sz.min(visible.size));
        }

        /// Bounds covering the primary display, or a 1024x768 window if no display is known.
        /// `display_id` is ignored until display lookup is ported.
        pub fn maximized(display_id: ?DisplayId, cx: anytype) Bounds(Pixels) {
            _ = display_id;
            if (comptime has_primary_display_size(@TypeOf(cx))) {
                return .{ .origin = point(0, 0), .size = cx.primary_display_size() };
            }
            return .{ .origin = point(0, 0), .size = size(1024, 768) };
        }
    };
}

fn has_primary_display_size(comptime Context: type) bool {
    const Child = switch (@typeInfo(Context)) {
        .pointer => |pointer| pointer.child,
        else => Context,
    };
    return switch (@typeInfo(Child)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(Child, "primary_display_size"),
        else => false,
    };
}

/// Constructs a `Bounds` from an origin and a size.
pub inline fn bounds(origin: anytype, sz: anytype) Bounds(@TypeOf(origin.x)) {
    return .{ .origin = origin, .size = sz };
}

/// Edge sizes of a box, such as padding or margin.
pub fn Edges(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The size of the top edge.
        top: T = fieldDefault(T),
        /// The size of the right edge.
        right: T = fieldDefault(T),
        /// The size of the bottom edge.
        bottom: T = fieldDefault(T),
        /// The size of the left edge.
        left: T = fieldDefault(T),

        /// All four edges set to `value`.
        pub inline fn all(value: T) Self {
            return .{ .top = value, .right = value, .bottom = value, .left = value };
        }

        /// Applies `f` to each edge, producing `Edges(U)`.
        pub fn map(self: Self, comptime U: type, f: fn (T) U) Edges(U) {
            return .{ .top = f(self.top), .right = f(self.right), .bottom = f(self.bottom), .left = f(self.left) };
        }

        /// True if `predicate` holds for any edge.
        pub fn any(self: Self, predicate: fn (T) bool) bool {
            return predicate(self.top) or predicate(self.right) or predicate(self.bottom) or predicate(self.left);
        }

        /// True if every edge is zero.
        pub inline fn is_empty(self: Self) bool {
            return self.top == 0 and self.right == 0 and self.bottom == 0 and self.left == 0;
        }

        /// Edges with every side set to zero pixels, in the type `T` requires.
        pub inline fn zero() Self {
            const zero_value: T = switch (T) {
                Length, DefiniteLength, AbsoluteLength => from_pixels(T, 0),
                else => 0,
            };
            return .{ .top = zero_value, .right = zero_value, .bottom = zero_value, .left = zero_value };
        }

        /// Edges with every side set to `auto`. Only meaningful for `Edges(Length)`.
        pub inline fn auto() Self {
            return .{ .top = .auto, .right = .auto, .bottom = .auto, .left = .auto };
        }

        pub inline fn mul(self: Self, rhs: Self) Self {
            return .{
                .top = self.top * rhs.top,
                .right = self.right * rhs.right,
                .bottom = self.bottom * rhs.bottom,
                .left = self.left * rhs.left,
            };
        }

        /// Converts to pixels. Pass `.{ rem_size }` for `Edges(AbsoluteLength)` or
        /// `.{ parent_size, rem_size }` for `Edges(DefiniteLength)`.
        pub fn to_pixels(self: Self, args: anytype) Edges(Pixels) {
            if (comptime T == AbsoluteLength) {
                const rem_size: Pixels = args[0];
                return .{
                    .top = self.top.to_pixels(rem_size),
                    .right = self.right.to_pixels(rem_size),
                    .bottom = self.bottom.to_pixels(rem_size),
                    .left = self.left.to_pixels(rem_size),
                };
            } else {
                const parent_size: Size(AbsoluteLength) = args[0];
                const rem_size: Pixels = args[1];
                return .{
                    .top = self.top.to_pixels(parent_size.height, rem_size),
                    .right = self.right.to_pixels(parent_size.width, rem_size),
                    .bottom = self.bottom.to_pixels(parent_size.height, rem_size),
                    .left = self.left.to_pixels(parent_size.width, rem_size),
                };
            }
        }

        /// Scales every edge by `factor`.
        pub fn scale(self: Edges(Pixels), factor: f32) Edges(ScaledPixels) {
            return .{
                .top = self.top * factor,
                .right = self.right * factor,
                .bottom = self.bottom * factor,
                .left = self.left * factor,
            };
        }

        /// Largest edge.
        pub fn max(self: Edges(Pixels)) Pixels {
            return @max(@max(self.top, self.right), @max(self.bottom, self.left));
        }
    };
}

/// Corner radii or per-corner values of a box.
pub fn Corners(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The value at the top left corner.
        top_left: T = fieldDefault(T),
        /// The value at the top right corner.
        top_right: T = fieldDefault(T),
        /// The value at the bottom right corner.
        bottom_right: T = fieldDefault(T),
        /// The value at the bottom left corner.
        bottom_left: T = fieldDefault(T),

        /// All four corners set to `value`.
        pub inline fn all(value: T) Self {
            return .{ .top_left = value, .top_right = value, .bottom_right = value, .bottom_left = value };
        }

        /// Value at `anchor`; edge anchors return the average of the two corners.
        pub inline fn corner(self: Self, anchor: Anchor) T {
            return switch (anchor) {
                .top_left => self.top_left,
                .top_right => self.top_right,
                .bottom_left => self.bottom_left,
                .bottom_right => self.bottom_right,
                .top_center => half(self.top_left + self.top_right),
                .bottom_center => half(self.bottom_left + self.bottom_right),
                .left_center => half(self.top_left + self.bottom_left),
                .right_center => half(self.top_right + self.bottom_right),
            };
        }

        /// Applies `f` to each corner, producing `Corners(U)`.
        pub fn map(self: Self, comptime U: type, f: fn (T) U) Corners(U) {
            return .{
                .top_left = f(self.top_left),
                .top_right = f(self.top_right),
                .bottom_right = f(self.bottom_right),
                .bottom_left = f(self.bottom_left),
            };
        }

        /// Limits each radius to half the smaller side of `sz`.
        pub fn clamp_radii_for_quad_size(self: Self, sz: Size(T)) Self {
            const max_radius = @min(sz.width, sz.height) / 2;
            return .{
                .top_left = @min(self.top_left, max_radius),
                .top_right = @min(self.top_right, max_radius),
                .bottom_right = @min(self.bottom_right, max_radius),
                .bottom_left = @min(self.bottom_left, max_radius),
            };
        }

        pub inline fn mul(self: Self, rhs: Self) Self {
            return .{
                .top_left = self.top_left * rhs.top_left,
                .top_right = self.top_right * rhs.top_right,
                .bottom_right = self.bottom_right * rhs.bottom_right,
                .bottom_left = self.bottom_left * rhs.bottom_left,
            };
        }

        /// Converts absolute lengths to pixels.
        pub fn to_pixels(self: Corners(AbsoluteLength), rem_size: Pixels) Corners(Pixels) {
            return .{
                .top_left = self.top_left.to_pixels(rem_size),
                .top_right = self.top_right.to_pixels(rem_size),
                .bottom_right = self.bottom_right.to_pixels(rem_size),
                .bottom_left = self.bottom_left.to_pixels(rem_size),
            };
        }

        /// Scales every corner by `factor`.
        pub fn scale(self: Corners(Pixels), factor: f32) Corners(ScaledPixels) {
            return .{
                .top_left = self.top_left * factor,
                .top_right = self.top_right * factor,
                .bottom_right = self.bottom_right * factor,
                .bottom_left = self.bottom_left * factor,
            };
        }

        /// Largest corner value.
        pub fn max(self: Corners(Pixels)) Pixels {
            return @max(@max(self.top_left, self.top_right), @max(self.bottom_right, self.bottom_left));
        }
    };
}

/// Scale-independent length in rems, resolved against the rem size.
pub const Rems = struct {
    value: f32,

    pub inline fn to_pixels(self: Rems, rem_size: Pixels) Pixels {
        return self.value * rem_size;
    }
};

/// Constructs a `Rems` length.
pub inline fn rems(value: f32) Rems {
    return .{ .value = value };
}

/// A length that does not depend on the parent: pixels or rems.
pub const AbsoluteLength = union(enum) {
    pixels: Pixels,
    rems: Rems,

    pub const default: AbsoluteLength = .{ .pixels = 0 };

    pub inline fn is_zero(self: AbsoluteLength) bool {
        return switch (self) {
            .pixels => |pixels| pixels == 0,
            .rems => |rem_value| rem_value.value == 0,
        };
    }

    pub inline fn to_pixels(self: AbsoluteLength, rem_size: Pixels) Pixels {
        return switch (self) {
            .pixels => |pixels| pixels,
            .rems => |rem_value| rem_value.to_pixels(rem_size),
        };
    }

    pub inline fn to_rems(self: AbsoluteLength, rem_size: Pixels) Rems {
        return switch (self) {
            .pixels => |pixels| .{ .value = pixels / rem_size },
            .rems => |rem_value| rem_value,
        };
    }
};

/// A length that is either absolute or a fraction of the parent.
pub const DefiniteLength = union(enum) {
    absolute: AbsoluteLength,
    /// Fraction of the parent's size, usually between 0 and 1.
    fraction: f32,

    pub const default: DefiniteLength = .{ .absolute = AbsoluteLength.default };

    pub inline fn is_zero(self: DefiniteLength) bool {
        return switch (self) {
            .absolute => |absolute_length| absolute_length.is_zero(),
            .fraction => |fraction| fraction == 0,
        };
    }

    /// Resolves to pixels against `base_size` (for fractions) and `rem_size`.
    pub inline fn to_pixels(self: DefiniteLength, base_size: AbsoluteLength, rem_size: Pixels) Pixels {
        return switch (self) {
            .absolute => |absolute_length| absolute_length.to_pixels(rem_size),
            .fraction => |fraction| switch (base_size) {
                .pixels => |base_pixels| base_pixels * fraction,
                .rems => |base_rems| base_rems.to_pixels(rem_size) * fraction,
            },
        };
    }
};

/// A CSS-like length: a definite length or `auto`.
pub const Length = union(enum) {
    definite: DefiniteLength,
    auto,

    pub const default: Length = .{ .definite = DefiniteLength.default };

    pub inline fn is_zero(self: Length) bool {
        return switch (self) {
            .definite => |definite_length| definite_length.is_zero(),
            .auto => false,
        };
    }
};

/// A fraction of the parent's size.
pub inline fn relative(fraction: f32) DefiniteLength {
    return .{ .fraction = fraction };
}

/// The golden ratio as a fraction of the parent.
pub inline fn phi() DefiniteLength {
    return relative(1.618_034);
}

/// Constructs a logical pixel value.
pub inline fn px(value: f32) Pixels {
    return value;
}

/// The `auto` length.
pub inline fn auto() Length {
    return .auto;
}

/// A fraction of a full turn (GPUI `Percentage`). Arithmetic on it is not ported.
pub const Percentage = struct {
    value: f32,

    /// The angle in radians: a full turn is `tau`.
    pub fn to_radians(self: Percentage) f32 {
        return self.value * std.math.tau;
    }
};

/// A fraction of a full turn, from 0 to 1 (GPUI `percentage`).
pub fn percentage(value: f32) Percentage {
    std.debug.assert(value >= 0 and value <= 1);
    return .{ .value = value };
}

/// An angle in radians from a plain `f32` or a `Percentage` (GPUI `Into<Radians>`).
pub fn to_radians(value: anytype) f32 {
    return switch (@TypeOf(value)) {
        Percentage => value.to_radians(),
        else => value,
    };
}

/// Converts a pixel value, length type or number to `Length`.
pub fn to_length(value: anytype) Length {
    const Value = @TypeOf(value);
    if (Value == Length) return value;
    if (Value == DefiniteLength) return .{ .definite = value };
    return .{ .definite = to_definite_length(value) };
}

/// Converts a pixel value, rems, absolute length or number to `DefiniteLength`.
pub fn to_definite_length(value: anytype) DefiniteLength {
    const Value = @TypeOf(value);
    if (Value == DefiniteLength) return value;
    return .{ .absolute = to_absolute_length(value) };
}

/// Converts pixels, rems or a number to `AbsoluteLength`.
pub fn to_absolute_length(value: anytype) AbsoluteLength {
    const Value = @TypeOf(value);
    if (Value == AbsoluteLength) return value;
    if (Value == Rems) return .{ .rems = value };
    return switch (@typeInfo(Value)) {
        .float, .comptime_float => .{ .pixels = @as(f32, value) },
        .int, .comptime_int => .{ .pixels = @floatFromInt(value) },
        else => @compileError("cannot convert " ++ @typeName(Value) ++ " to AbsoluteLength"),
    };
}

/// Converts a number of pixels to one of the length types.
fn from_pixels(comptime T: type, value: Pixels) T {
    return switch (T) {
        Length => to_length(value),
        DefiniteLength => to_definite_length(value),
        AbsoluteLength => to_absolute_length(value),
        else => @compileError("from_pixels: unsupported length type " ++ @typeName(T)),
    };
}

/// Converts pixels to `i32`, truncating toward zero and saturating at the bounds (NaN becomes 0).
pub fn pixels_to_i32(value: Pixels) i32 {
    if (math.isNan(value)) return 0;
    if (value >= @as(f32, @floatFromInt(math.maxInt(i32)))) return math.maxInt(i32);
    if (value <= @as(f32, @floatFromInt(math.minInt(i32)))) return math.minInt(i32);
    return @intFromFloat(value);
}

test "percentage is a fraction of a full turn" {
    try std.testing.expectApproxEqAbs(std.math.pi, percentage(0.5).to_radians(), 1e-6);
    try std.testing.expectApproxEqAbs(std.math.tau, percentage(1).to_radians(), 1e-6);
    try std.testing.expectEqual(@as(f32, 2.0), to_radians(@as(f32, 2.0)));
}

test "pixels_to_i32" {
    const cases = [_]struct { f32, i32 }{
        .{ 12.9, 12 },
        .{ -12.9, -12 },
        .{ math.floatMax(f32), math.maxInt(i32) },
        .{ -math.floatMax(f32), math.minInt(i32) },
        .{ math.inf(f32), math.maxInt(i32) },
        .{ -math.inf(f32), math.minInt(i32) },
        .{ math.nan(f32), 0 },
    };
    for (cases) |case| {
        try testing.expectEqual(case[1], pixels_to_i32(px(case[0])));
    }
}

test "axis invert" {
    try testing.expectEqual(Axis.vertical, Axis.horizontal.invert());
    try testing.expectEqual(Axis.horizontal, Axis.vertical.invert());
}

test "point constructors and operators" {
    const p = point(10, 20);
    try testing.expectEqual(@as(f32, 10), p.x);
    try testing.expectEqual(@as(f32, 20), p.y);

    const q = Point(i32).new(3, 4);
    try testing.expect(q.add(q).eq(.{ .x = 6, .y = 8 }));
    try testing.expect(q.sub(q).eq(.{ .x = 0, .y = 0 }));
    try testing.expect(q.neg().eq(.{ .x = -3, .y = -4 }));
    try testing.expect(q.mul(2).eq(.{ .x = 6, .y = 8 }));
    try testing.expect(q.div(2).eq(.{ .x = 1, .y = 2 }));
}

test "point magnitude and scale" {
    const p = Point(Pixels){ .x = px(3), .y = px(4) };
    try testing.expectEqual(@as(f64, 5.0), p.magnitude());
    const scaled = p.scale(1.5);
    try testing.expectEqual(@as(f32, 4.5), scaled.x);
    try testing.expectEqual(@as(f32, 6.0), scaled.y);
}

test "point max min clamp" {
    const p1 = Point(i32){ .x = 3, .y = 7 };
    const p2 = Point(i32){ .x = 5, .y = 2 };
    try testing.expect(p1.max(p2).eq(.{ .x = 5, .y = 7 }));
    try testing.expect(p1.min(p2).eq(.{ .x = 3, .y = 2 }));

    const p = Point(i32){ .x = 10, .y = 20 };
    const lo = Point(i32){ .x = 0, .y = 5 };
    const hi = Point(i32){ .x = 15, .y = 25 };
    try testing.expect(p.clamp(lo, hi).eq(.{ .x = 10, .y = 20 }));
    const out = Point(i32){ .x = -5, .y = 30 };
    try testing.expect(out.clamp(lo, hi).eq(.{ .x = 0, .y = 25 }));
}

test "point along and relative_to" {
    const p = point(@as(f32, 2), @as(f32, 9));
    try testing.expectEqual(@as(f32, 2), p.along(.horizontal));
    try testing.expectEqual(@as(f32, 9), p.along(.vertical));
    const moved = p.apply_along(.vertical, struct {
        fn f(v: f32) f32 {
            return v + 1;
        }
    }.f);
    try testing.expectEqual(@as(f32, 10), moved.y);
    try testing.expect(p.relative_to(point(@as(f32, 1), @as(f32, 1))).eq(.{ .x = 1, .y = 8 }));
}

test "size basics" {
    const s = size(30, 40);
    try testing.expect(s.max(size(50, 20)).eq(.{ .width = 50, .height = 40 }));
    try testing.expect(s.min(size(50, 20)).eq(.{ .width = 30, .height = 20 }));
    try testing.expectEqual(@as(f32, 1200), size(30, 40).area());
    try testing.expect(Size(i32).new(10, 20).center().eq(.{ .x = 5, .y = 10 }));
    try testing.expect(Size(i32).zero().eq(.{ .width = 0, .height = 0 }));
}

test "size scale and device pixels" {
    const s = Size(Pixels){ .width = px(100), .height = px(50) };
    const scaled = s.scale(2.0);
    try testing.expectEqual(@as(f32, 200), scaled.width);
    try testing.expectEqual(@as(f32, 100), scaled.height);

    const device = s.to_device_pixels(1.5);
    try testing.expectEqual(@as(DevicePixels, 150), device.width);
    try testing.expectEqual(@as(DevicePixels, 75), device.height);
    try testing.expectEqual(@as(f32, 100), device.to_pixels(1.5).width);
}

test "size full and auto" {
    const full = Size(Length).full();
    try testing.expectEqual(to_length(relative(1)), full.width);
    try testing.expectEqual(Length.auto, Size(Length).auto().height);
}

test "bounds from corners and edges" {
    const b = Bounds(i32).from_corners(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 20 });
    try testing.expectEqual(@as(i32, 10), b.size.width);
    try testing.expectEqual(@as(i32, 20), b.size.height);
    try testing.expect(b.top_right().eq(.{ .x = 10, .y = 0 }));
    try testing.expect(b.bottom_right().eq(.{ .x = 10, .y = 20 }));
    try testing.expect(b.bottom_left().eq(.{ .x = 0, .y = 20 }));
    try testing.expect(b.center().eq(.{ .x = 5, .y = 10 }));
    try testing.expectEqual(@as(i32, 30), b.half_perimeter());
    try testing.expect(b.corner(.bottom_left).eq(.{ .x = 0, .y = 20 }));
    try testing.expect(b.corner(.right_center).eq(.{ .x = 10, .y = 10 }));
}

test "bounds intersects" {
    const bounds1 = Bounds(f32){ .origin = .{ .x = 0.0, .y = 0.0 }, .size = .{ .width = 5.0, .height = 5.0 } };
    const bounds2 = Bounds(f32){ .origin = .{ .x = 4.0, .y = 4.0 }, .size = .{ .width = 5.0, .height = 5.0 } };
    const bounds3 = Bounds(f32){ .origin = .{ .x = 10.0, .y = 10.0 }, .size = .{ .width = 5.0, .height = 5.0 } };

    try testing.expect(bounds1.intersects(bounds2));
    try testing.expect(!bounds1.intersects(bounds3));
    try testing.expect(bounds1.intersects(bounds1));
}

fn rect(x: i32, y: i32, w: i32, h: i32) Bounds(i32) {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "bounds intersect and union" {
    const b1 = rect(0, 0, 10, 10);
    const b2 = rect(5, 5, 10, 10);
    const b3 = rect(20, 20, 10, 10);

    try testing.expect(b1.intersect(b2).eq(rect(5, 5, 5, 5)));
    try testing.expectEqual(@as(i32, 0), b1.intersect(b3).size.width);
    try testing.expect(b1.@"union"(b2).eq(rect(0, 0, 15, 15)));
    try testing.expect(b1.@"union"(rect(5, 5, 15, 15)).eq(rect(0, 0, 20, 20)));
}

test "bounds dilate and inset" {
    const b = rect(10, 10, 10, 10);
    try testing.expect(b.dilate(5).eq(rect(5, 5, 20, 20)));
    try testing.expect(b.inset(2).eq(rect(12, 12, 6, 6)));
    const extended = b.extend(Edges(i32){ .top = 1, .right = 2, .bottom = 3, .left = 4 });
    try testing.expect(extended.eq(rect(6, 9, 16, 14)));
}

test "bounds contains" {
    const outer = Bounds(i32).new(.{ .x = 0, .y = 0 }, .{ .width = 20, .height = 20 });
    const inner = Bounds(i32).new(.{ .x = 5, .y = 5 }, .{ .width = 10, .height = 10 });
    const overlapping = Bounds(i32).new(.{ .x = 15, .y = 15 }, .{ .width = 10, .height = 10 });

    try testing.expect(outer.contains(.{ .x = 5, .y = 5 }));
    try testing.expect(!outer.contains(.{ .x = 25, .y = 25 }));
    try testing.expect(inner.is_contained_within(outer));
    try testing.expect(!overlapping.is_contained_within(outer));
    try testing.expectEqual(@as(?Point(i32), .{ .x = 5, .y = 5 }), inner.localize(.{ .x = 10, .y = 10 }));
    try testing.expectEqual(@as(?Point(i32), null), inner.localize(.{ .x = 0, .y = 0 }));
}

test "bounds space_within and is_empty" {
    const outer = Bounds(i32).new(.{ .x = 0, .y = 0 }, .{ .width = 20, .height = 20 });
    const inner = Bounds(i32).new(.{ .x = 5, .y = 5 }, .{ .width = 10, .height = 10 });
    const space = inner.space_within(outer);
    try testing.expectEqual(@as(i32, 5), space.top);
    try testing.expectEqual(@as(i32, 5), space.right);
    try testing.expectEqual(@as(i32, 5), space.bottom);
    try testing.expectEqual(@as(i32, 5), space.left);
    try testing.expect(!inner.is_empty());
    try testing.expect(Bounds(i32).new(.{ .x = 0, .y = 0 }, .{ .width = 0, .height = 3 }).is_empty());
}

test "bounds map and scale" {
    const b = Bounds(f32){ .origin = point(@as(f32, 10), @as(f32, 10)), .size = size(@as(f32, 10), @as(f32, 20)) };
    const scaled = b.scale(2.0);
    try testing.expect(scaled.origin.eq(.{ .x = 20, .y = 20 }));
    try testing.expect(scaled.size.eq(.{ .width = 20, .height = 40 }));

    const mapped = b.map_origin(struct {
        fn f(v: f32) f32 {
            return v * 1.5;
        }
    }.f);
    try testing.expect(mapped.origin.eq(.{ .x = 15, .y = 15 }));
    try testing.expect(mapped.size.eq(b.size));
}

test "bounds device pixels round trip" {
    const b = Bounds(Pixels){ .origin = point(px(10), px(20)), .size = size(px(30), px(40)) };
    const device = b.to_device_pixels(2.0);
    try testing.expect(device.origin.eq(.{ .x = 20, .y = 40 }));
    try testing.expect(device.size.eq(.{ .width = 60, .height = 80 }));
    try testing.expect(device.to_pixels(2.0).eq(b));
}

test "edges helpers" {
    const e = Edges(i32).all(10);
    try testing.expectEqual(@as(i32, 10), e.left);
    try testing.expect(!e.is_empty());
    try testing.expect(Edges(i32).zero().is_empty());

    const mapped = e.map(f32, struct {
        fn f(v: i32) f32 {
            return @as(f32, @floatFromInt(v)) * 1.5;
        }
    }.f);
    try testing.expectEqual(@as(f32, 15), mapped.top);

    const values = Edges(i32){ .top = 10, .right = 0, .bottom = 5, .left = 0 };
    try testing.expect(values.any(struct {
        fn f(v: i32) bool {
            return v == 0;
        }
    }.f));
    try testing.expect(!values.any(struct {
        fn f(v: i32) bool {
            return v > 10;
        }
    }.f));
}

test "edges to_pixels" {
    const absolute = Edges(AbsoluteLength){
        .top = .{ .pixels = px(10) },
        .right = .{ .rems = rems(1) },
        .bottom = .{ .pixels = px(20) },
        .left = .{ .rems = rems(2) },
    };
    const in_pixels = absolute.to_pixels(.{px(16)});
    try testing.expectEqual(@as(f32, 10), in_pixels.top);
    try testing.expectEqual(@as(f32, 16), in_pixels.right);
    try testing.expectEqual(@as(f32, 20), in_pixels.bottom);
    try testing.expectEqual(@as(f32, 32), in_pixels.left);

    const definite = Edges(DefiniteLength){
        .top = .{ .absolute = .{ .pixels = px(10) } },
        .right = relative(0.5),
        .bottom = .{ .absolute = .{ .rems = rems(2) } },
        .left = relative(0.25),
    };
    const parent = Size(AbsoluteLength){ .width = .{ .pixels = px(200) }, .height = .{ .pixels = px(100) } };
    const definite_in_pixels = definite.to_pixels(.{ parent, px(16) });
    try testing.expectEqual(@as(f32, 10), definite_in_pixels.top);
    try testing.expectEqual(@as(f32, 100), definite_in_pixels.right);
    try testing.expectEqual(@as(f32, 32), definite_in_pixels.bottom);
    try testing.expectEqual(@as(f32, 50), definite_in_pixels.left);
}

test "corners helpers" {
    const c = Corners(Pixels).all(px(4));
    try testing.expectEqual(@as(f32, 4), c.bottom_left);
    try testing.expectEqual(@as(f32, 4), c.corner(.top_center));
    try testing.expectEqual(@as(f32, 4), c.max());
    try testing.expectEqual(@as(f32, 8), c.scale(2.0).top_left);

    const radii = Corners(Pixels){ .top_left = 50, .top_right = 5, .bottom_right = 50, .bottom_left = 5 };
    const clamped = radii.clamp_radii_for_quad_size(size(px(20), px(40)));
    try testing.expectEqual(@as(f32, 10), clamped.top_left);
    try testing.expectEqual(@as(f32, 5), clamped.top_right);
}

test "to_length conversions" {
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .pixels = 3 } } }, to_length(@as(f32, 3)));
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .pixels = 3 } } }, to_length(3));
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .rems = rems(2) } } }, to_length(rems(2)));
    try testing.expectEqual(Length{ .definite = .{ .fraction = 0.5 } }, to_length(relative(0.5)));
    try testing.expectEqual(Length.auto, to_length(auto()));
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 7 } }, to_definite_length(px(7)));
    try testing.expectEqual(AbsoluteLength{ .rems = rems(1.5) }, to_absolute_length(rems(1.5)));
}

test "length resolution" {
    try testing.expectEqual(@as(f32, 50), relative(0.25).to_pixels(.{ .pixels = px(200) }, 16));
    try testing.expectEqual(@as(f32, 16), relative(0.5).to_pixels(.{ .rems = rems(2) }, 16));
    try testing.expectEqual(@as(f32, 32), (AbsoluteLength{ .rems = rems(2) }).to_pixels(16));
    try testing.expect(relative(0).is_zero());
    try testing.expect(!auto().is_zero());
    try testing.expectEqual(DefiniteLength{ .fraction = 1.618_034 }, phi());
}
