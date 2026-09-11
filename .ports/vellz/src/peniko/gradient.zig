//! Port of peniko 0.6.1 gradient.rs and brush.rs (`Extend`) (Apache-2.0 OR
//! MIT).
//!
//! Upstream stores stop colors as `DynamicColor` (a color space tag plus
//! components). This port only implements the sRGB color space, so a stop is
//! an `AlphaColor(Srgb)`; `Gradient.interpolation_cs` and
//! `Gradient.hue_direction` are kept so the structure still matches upstream
//! and future color spaces can slot in.
//!
//! `ColorStops` owns a heap slice; every allocating operation takes the
//! allocator explicitly and `deinit`/`clone` are the only free/store paths.

const std = @import("std");
const color = @import("color.zig");
const kurbo = @import("../kurbo/root.zig");

pub const AlphaColor = color.AlphaColor;
pub const Srgb = color.Srgb;
pub const Color = color.Color;
pub const ColorSpaceTag = color.ColorSpaceTag;
pub const HueDirection = color.HueDirection;

/// Gradient positions use the canonical `kurbo.Point` (peniko 0.6.1
/// re-exports kurbo; there is exactly one point type in vellz).
pub const Point = kurbo.Point;

/// Defines how a brush is extended when the content does not fill a shape.
pub const Extend = enum(u8) {
    /// Repeats the edge color of the brush (the default).
    pad = 0,
    /// Repeats the brush.
    repeat = 1,
    /// Reflects the brush.
    reflect = 2,

    /// The upstream `Default` implementation: [`Extend.pad`].
    pub const default: Extend = .pad;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: Extend) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back into an extend mode, or `null` if it is
    /// unknown.
    pub fn fromU8(value: u8) ?Extend {
        if (value > 2) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Defines how color channels are handled when interpolating between
/// transparent colors.
pub const InterpolationAlphaSpace = enum(u8) {
    /// Color channels are premultiplied by alpha (the default).
    premultiplied = 0,
    /// Color channels are not premultiplied (HTML canvas behavior).
    unpremultiplied = 1,

    /// The upstream `Default` implementation:
    /// [`InterpolationAlphaSpace.premultiplied`].
    pub const default: InterpolationAlphaSpace = .premultiplied;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: InterpolationAlphaSpace) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back, or `null` if it is unknown.
    pub fn fromU8(value: u8) ?InterpolationAlphaSpace {
        if (value > 1) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// Offset and color of a transition point in a [`Gradient`].
pub const ColorStop = struct {
    /// Normalized offset of the stop.
    offset: f32,
    /// Color at the specified offset.
    color: AlphaColor(Srgb),

    /// Create a stop from an offset and a straight-alpha sRGB color.
    pub fn init(offset: f32, stop_color: AlphaColor(Srgb)) ColorStop {
        return .{ .offset = offset, .color = stop_color };
    }

    /// Return the color stop with the alpha component set to `alpha`.
    pub fn withAlpha(self: ColorStop, alpha: f32) ColorStop {
        return .{ .offset = self.offset, .color = self.color.withAlpha(alpha) };
    }

    /// Return the color stop with the alpha component multiplied by `alpha`.
    pub fn multiplyAlpha(self: ColorStop, alpha: f32) ColorStop {
        return .{ .offset = self.offset, .color = self.color.multiplyAlpha(alpha) };
    }
};

/// Collection of color stops.
///
/// Owns its backing allocation. The allocator is recorded on first allocation
/// and used by `deinit`; mutations additionally take the allocator explicitly
/// so no global allocator is implied.
pub const ColorStops = struct {
    /// The used elements.
    items: []ColorStop = &.{},
    /// Allocated capacity in elements.
    capacity: usize = 0,
    /// Allocator owning the backing memory, if any.
    allocator: ?std.mem.Allocator = null,

    /// An empty, unbound collection.
    pub const empty: ColorStops = .{};

    /// Construct an empty collection bound to `allocator`.
    pub fn init(allocator: std.mem.Allocator) ColorStops {
        return .{ .allocator = allocator };
    }

    /// Free the backing allocation. Safe to call on an empty collection.
    pub fn deinit(self: *ColorStops) void {
        if (self.capacity == 0) {
            self.* = .{};
            return;
        }
        const allocator = self.allocator.?;
        allocator.free(self.items.ptr[0..self.capacity]);
        self.* = .{};
    }

    /// The stops as a slice.
    pub fn asSlice(self: *const ColorStops) []const ColorStop {
        return self.items;
    }

    /// The number of stops.
    pub fn len(self: *const ColorStops) usize {
        return self.items.len;
    }

    /// Whether the collection is empty.
    pub fn isEmpty(self: *const ColorStops) bool {
        return self.items.len == 0;
    }

    /// Reset the used length to zero, keeping the allocation for reuse.
    pub fn clear(self: *ColorStops) void {
        self.items = self.items[0..0];
    }

    fn checkAllocator(self: *const ColorStops, allocator: std.mem.Allocator) void {
        if (self.allocator) |existing| {
            std.debug.assert(existing.ptr == allocator.ptr);
            std.debug.assert(existing.vtable == allocator.vtable);
        }
    }

    fn ensureCapacity(self: *ColorStops, allocator: std.mem.Allocator, needed: usize) !void {
        if (self.capacity >= needed) return;
        self.checkAllocator(allocator);

        var new_capacity: usize = if (self.capacity == 0) 4 else self.capacity *| 2;
        if (new_capacity < needed) new_capacity = needed;

        const old: []ColorStop = if (self.capacity == 0)
            self.items[0..0]
        else
            self.items.ptr[0..self.capacity];
        const new_memory = try allocator.realloc(old, new_capacity);
        self.items = new_memory[0..self.items.len];
        self.capacity = new_capacity;
        self.allocator = allocator;
    }

    /// Reserve room for `additional` more stops.
    pub fn ensureUnusedCapacity(
        self: *ColorStops,
        allocator: std.mem.Allocator,
        additional: usize,
    ) !void {
        const required = std.math.add(usize, self.items.len, additional) catch
            return error.OutOfMemory;
        try self.ensureCapacity(allocator, required);
    }

    /// Append one stop.
    pub fn append(self: *ColorStops, allocator: std.mem.Allocator, stop: ColorStop) !void {
        try self.ensureCapacity(allocator, self.items.len + 1);
        self.items.ptr[self.items.len] = stop;
        self.items = self.items.ptr[0 .. self.items.len + 1];
    }

    /// Append every stop in `stops`.
    pub fn appendSlice(
        self: *ColorStops,
        allocator: std.mem.Allocator,
        stops: []const ColorStop,
    ) !void {
        if (stops.len == 0) return;
        const required = std.math.add(usize, self.items.len, stops.len) catch
            return error.OutOfMemory;
        try self.ensureCapacity(allocator, required);
        // `stops` may alias `self.items` (e.g. appending a sub-slice of self),
        // so this must be a forward copy, not @memcpy.
        std.mem.copyForwards(ColorStop, self.items.ptr[self.items.len..][0..stops.len], stops);
        self.items = self.items.ptr[0 .. self.items.len + stops.len];
    }

    /// Copy a slice of stops into a new collection.
    pub fn fromSlice(allocator: std.mem.Allocator, stops: []const ColorStop) !ColorStops {
        var result = ColorStops.init(allocator);
        errdefer result.deinit();
        try result.appendSlice(allocator, stops);
        return result;
    }

    /// Copy a slice of straight-alpha sRGB colors into a new collection,
    /// distributing them evenly over `[0, 1]` (upstream `ColorStopsSource for
    /// &[AlphaColor<CS>]`).
    pub fn fromColors(allocator: std.mem.Allocator, colors: []const AlphaColor(Srgb)) !ColorStops {
        var result = ColorStops.init(allocator);
        errdefer result.deinit();
        if (colors.len == 0) return result;

        const denominator: f32 = @floatFromInt(@max(colors.len - 1, 1));
        try result.ensureCapacity(allocator, colors.len);
        for (colors, 0..) |c, i| {
            const offset = @as(f32, @floatFromInt(i)) / denominator;
            result.appendAssumeCapacity(.{ .offset = offset, .color = c });
        }
        return result;
    }

    fn appendAssumeCapacity(self: *ColorStops, stop: ColorStop) void {
        std.debug.assert(self.items.len < self.capacity);
        self.items.ptr[self.items.len] = stop;
        self.items = self.items.ptr[0 .. self.items.len + 1];
    }

    /// Deep-copy the stops using `allocator`.
    pub fn clone(self: *const ColorStops, allocator: std.mem.Allocator) !ColorStops {
        return fromSlice(allocator, self.items);
    }
};

/// Parameters that define the position of a linear gradient.
pub const LinearGradientPosition = struct {
    /// Starting point.
    start: Point = kurbo.Point.ZERO,
    /// Ending point.
    end: Point = kurbo.Point.ZERO,

    /// Create a linear gradient position for the specified start and end
    /// points.
    pub fn new(start: Point, end: Point) LinearGradientPosition {
        return .{ .start = start, .end = end };
    }
};

/// Parameters that define the position of a radial gradient.
pub const RadialGradientPosition = struct {
    /// Center of the start circle.
    start_center: Point = kurbo.Point.ZERO,
    /// Radius of the start circle.
    start_radius: f32 = 0.0,
    /// Center of the end circle.
    end_center: Point = kurbo.Point.ZERO,
    /// Radius of the end circle.
    end_radius: f32 = 0.0,

    /// Create a radial gradient position for the specified center and radius.
    pub fn new(center: Point, radius: f32) RadialGradientPosition {
        return .{
            .start_center = center,
            .start_radius = 0.0,
            .end_center = center,
            .end_radius = radius,
        };
    }

    /// Create a two-point radial gradient position.
    pub fn newTwoPoint(
        start_center: Point,
        start_radius: f32,
        end_center: Point,
        end_radius: f32,
    ) RadialGradientPosition {
        return .{
            .start_center = start_center,
            .start_radius = start_radius,
            .end_center = end_center,
            .end_radius = end_radius,
        };
    }
};

/// Parameters that define the position of a sweep gradient.
///
/// A positive increase in a sweep angle rotates a positive X direction into
/// positive Y (clockwise in a Y-down coordinate system).
pub const SweepGradientPosition = struct {
    /// Center point.
    center: Point = kurbo.Point.ZERO,
    /// Start angle in radians, measuring from the positive X-axis.
    start_angle: f32 = 0.0,
    /// End angle in radians, measuring from the positive X-axis.
    end_angle: f32 = 0.0,

    /// Create a sweep gradient for the specified center and angles.
    pub fn new(center: Point, start_angle: f32, end_angle: f32) SweepGradientPosition {
        return .{ .center = center, .start_angle = start_angle, .end_angle = end_angle };
    }
};

/// Properties for the supported gradient types.
pub const GradientKind = union(enum) {
    /// Transitions between colors along a line.
    linear: LinearGradientPosition,
    /// Transitions between colors radiating from an origin.
    radial: RadialGradientPosition,
    /// Transitions between colors rotating around a center point.
    sweep: SweepGradientPosition,
};

/// Definition of a gradient that transitions between two or more colors.
///
/// Zig has no move semantics: builder methods follow upstream's by-value
/// signatures, and `withStops`/`withColors` free the receiver's stops on
/// success. Treat the receiver as consumed by those calls.
pub const Gradient = struct {
    /// Kind and properties of the gradient.
    kind: GradientKind = .{ .linear = .{} },
    /// Extend mode.
    extend: Extend = .pad,
    /// The color space to be used for interpolation (defaults to sRGB).
    interpolation_cs: ColorSpaceTag = DEFAULT_INTERPOLATION_COLOR_SPACE,
    /// Direction for hue interpolation in cylindrical color spaces.
    hue_direction: HueDirection = .shorter,
    /// Alpha space used for interpolation.
    interpolation_alpha_space: InterpolationAlphaSpace = .premultiplied,
    /// Color stop collection.
    stops: ColorStops = .{},

    /// The upstream `Default` implementation.
    pub const default: Gradient = .{};

    /// Creates a new linear gradient for the specified start and end points.
    pub fn newLinear(start: Point, end: Point) Gradient {
        return .{ .kind = .{ .linear = LinearGradientPosition.new(start, end) } };
    }

    /// Creates a new radial gradient for the specified center and radius.
    pub fn newRadial(center: Point, radius: f32) Gradient {
        return .{ .kind = .{ .radial = RadialGradientPosition.new(center, radius) } };
    }

    /// Creates a new two-point radial gradient.
    pub fn newTwoPointRadial(
        start_center: Point,
        start_radius: f32,
        end_center: Point,
        end_radius: f32,
    ) Gradient {
        return .{
            .kind = .{ .radial = RadialGradientPosition.newTwoPoint(
                start_center,
                start_radius,
                end_center,
                end_radius,
            ) },
        };
    }

    /// Creates a new sweep gradient for the specified center and angles.
    pub fn newSweep(center: Point, start_angle: f32, end_angle: f32) Gradient {
        return .{ .kind = .{ .sweep = SweepGradientPosition.new(center, start_angle, end_angle) } };
    }

    /// Set the gradient extend mode.
    pub fn withExtend(self: Gradient, mode: Extend) Gradient {
        var result = self;
        result.extend = mode;
        return result;
    }

    /// Set the interpolation color space.
    pub fn withInterpolationCs(self: Gradient, interpolation_cs: ColorSpaceTag) Gradient {
        var result = self;
        result.interpolation_cs = interpolation_cs;
        return result;
    }

    /// Set the interpolation alpha space.
    pub fn withInterpolationAlphaSpace(
        self: Gradient,
        interpolation_alpha_space: InterpolationAlphaSpace,
    ) Gradient {
        var result = self;
        result.interpolation_alpha_space = interpolation_alpha_space;
        return result;
    }

    /// Set the hue direction used in cylindrical color spaces.
    pub fn withHueDirection(self: Gradient, hue_direction: HueDirection) Gradient {
        var result = self;
        result.hue_direction = hue_direction;
        return result;
    }

    /// Replace the color stops with a copy of `stops`.
    ///
    /// Consumes `self`: on success the previous stop allocation (if any) is
    /// freed. The caller must not use the old value afterwards. On allocation
    /// failure `self` is left untouched.
    pub fn withStops(
        self: Gradient,
        allocator: std.mem.Allocator,
        stops: []const ColorStop,
    ) !Gradient {
        const new_stops = try ColorStops.fromSlice(allocator, stops);
        var result = self;
        result.stops.deinit();
        result.stops = new_stops;
        return result;
    }

    /// Replace the color stops with evenly-spaced stops built from `colors`.
    ///
    /// Consumes `self`; see [`Gradient.withStops`].
    pub fn withColors(
        self: Gradient,
        allocator: std.mem.Allocator,
        colors: []const AlphaColor(Srgb),
    ) !Gradient {
        const new_stops = try ColorStops.fromColors(allocator, colors);
        var result = self;
        result.stops.deinit();
        result.stops = new_stops;
        return result;
    }

    /// Return a copy of the gradient with the alpha component for all stops
    /// set to `alpha`.
    ///
    /// ADAPTED: upstream takes `self` by value (move semantics); Zig cannot
    /// express that, so this allocates a deep copy and leaves `self`
    /// untouched. The caller owns the result and frees it with `deinit`.
    pub fn withAlpha(self: *const Gradient, allocator: std.mem.Allocator, alpha: f32) !Gradient {
        const result = try self.clone(allocator);
        for (result.stops.items) |*stop| {
            stop.* = stop.withAlpha(alpha);
        }
        return result;
    }

    /// Return a copy of the gradient with the alpha component for all stops
    /// multiplied by `alpha`.
    ///
    /// ADAPTED: see [`Gradient.withAlpha`].
    pub fn multiplyAlpha(
        self: *const Gradient,
        allocator: std.mem.Allocator,
        alpha: f32,
    ) !Gradient {
        const result = try self.clone(allocator);
        for (result.stops.items) |*stop| {
            stop.* = stop.multiplyAlpha(alpha);
        }
        return result;
    }

    /// Deep-copy the gradient (including its stops) using `allocator`.
    pub fn clone(self: *const Gradient, allocator: std.mem.Allocator) !Gradient {
        var result = self.*;
        result.stops = try self.stops.clone(allocator);
        return result;
    }

    /// Free the stop allocation.
    pub fn deinit(self: *Gradient) void {
        self.stops.deinit();
    }
};

/// The default for `Gradient.interpolation_cs`; upstream keeps this private so
/// it can change in the future.
const DEFAULT_INTERPOLATION_COLOR_SPACE: ColorSpaceTag = .srgb;

test "extend default and discriminants" {
    try std.testing.expectEqual(Extend.pad, Extend.default);
    inline for (.{ Extend.pad, Extend.repeat, Extend.reflect }) |mode| {
        try std.testing.expectEqual(mode, Extend.fromU8(mode.toU8()).?);
    }
    try std.testing.expectEqual(@as(?Extend, null), Extend.fromU8(3));
}

test "interpolation alpha space default and discriminants" {
    try std.testing.expectEqual(
        InterpolationAlphaSpace.premultiplied,
        InterpolationAlphaSpace.default,
    );
    try std.testing.expectEqual(
        InterpolationAlphaSpace.unpremultiplied,
        InterpolationAlphaSpace.fromU8(1).?,
    );
    try std.testing.expectEqual(@as(?InterpolationAlphaSpace, null), InterpolationAlphaSpace.fromU8(2));
}

test "gradient default matches upstream" {
    const gradient = Gradient.default;
    try std.testing.expectEqual(GradientKind{ .linear = .{} }, gradient.kind);
    try std.testing.expectEqual(Extend.pad, gradient.extend);
    try std.testing.expectEqual(ColorSpaceTag.srgb, gradient.interpolation_cs);
    try std.testing.expectEqual(HueDirection.shorter, gradient.hue_direction);
    try std.testing.expectEqual(
        InterpolationAlphaSpace.premultiplied,
        gradient.interpolation_alpha_space,
    );
    try std.testing.expect(gradient.stops.isEmpty());
}

test "gradient constructors and builders" {
    const start = Point.new(1.0, 2.0);
    const end = Point.new(3.0, 4.0);
    var linear = Gradient.newLinear(start, end);
    try std.testing.expectEqual(LinearGradientPosition{ .start = start, .end = end }, linear.kind.linear);
    linear = linear.withExtend(.reflect);
    try std.testing.expectEqual(Extend.reflect, linear.extend);
    linear = linear.withInterpolationCs(.linear_srgb);
    try std.testing.expectEqual(ColorSpaceTag.linear_srgb, linear.interpolation_cs);
    linear = linear.withHueDirection(.longer);
    try std.testing.expectEqual(HueDirection.longer, linear.hue_direction);
    linear = linear.withInterpolationAlphaSpace(.unpremultiplied);
    try std.testing.expectEqual(
        InterpolationAlphaSpace.unpremultiplied,
        linear.interpolation_alpha_space,
    );

    const radial = Gradient.newRadial(Point.new(5.0, 6.0), 2.5);
    try std.testing.expectEqual(
        RadialGradientPosition{
            .start_center = Point.new(5.0, 6.0),
            .start_radius = 0.0,
            .end_center = Point.new(5.0, 6.0),
            .end_radius = 2.5,
        },
        radial.kind.radial,
    );

    const two_point = Gradient.newTwoPointRadial(Point.new(0.0, 0.0), 1.0, Point.new(2.0, 3.0), 4.0);
    try std.testing.expectEqual(@as(f32, 1.0), two_point.kind.radial.start_radius);
    try std.testing.expectEqual(@as(f32, 4.0), two_point.kind.radial.end_radius);

    const sweep = Gradient.newSweep(Point.new(7.0, 8.0), 0.25, 1.5);
    try std.testing.expectEqual(
        SweepGradientPosition{ .center = Point.new(7.0, 8.0), .start_angle = 0.25, .end_angle = 1.5 },
        sweep.kind.sweep,
    );
}

test "color stop alpha operations" {
    const stop = ColorStop.init(0.25, AlphaColor(Srgb).fromRgb8(255, 0, 0));
    try std.testing.expectEqual(@as(f32, 0.25), stop.withAlpha(0.5).offset);
    try std.testing.expectEqual(@as(f32, 0.5), stop.withAlpha(0.5).color.components[3]);
    try std.testing.expectEqual(@as(f32, 0.25), stop.multiplyAlpha(0.25).color.components[3]);
}

test "color stops own their memory" {
    const allocator = std.testing.allocator;
    const stops = [_]ColorStop{
        ColorStop.init(0.0, color.palette.css.RED),
        ColorStop.init(0.5, color.palette.css.LIME),
        ColorStop.init(1.0, color.palette.css.BLUE),
    };

    var owned = try ColorStops.fromSlice(allocator, &stops);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 3), owned.len());
    try std.testing.expectEqual(@as(f32, 0.0), owned.asSlice()[0].offset);
    try std.testing.expectEqual(@as(f32, 0.5), owned.asSlice()[1].offset);
    try std.testing.expectEqual(@as(f32, 1.0), owned.asSlice()[2].offset);

    var cloned = try owned.clone(allocator);
    defer cloned.deinit();
    try std.testing.expectEqualSlices(ColorStop, owned.asSlice(), cloned.asSlice());

    // Clear keeps the allocation for reuse; capacity is unchanged.
    const capacity = owned.capacity;
    owned.clear();
    try std.testing.expect(owned.isEmpty());
    try std.testing.expectEqual(capacity, owned.capacity);
    try owned.append(allocator, ColorStop.init(0.75, color.palette.css.WHITE));
    try std.testing.expectEqual(@as(usize, 1), owned.len());
}

test "color stops from colors" {
    const allocator = std.testing.allocator;
    const colors = [_]AlphaColor(Srgb){
        color.palette.css.RED,
        color.palette.css.GREEN,
        color.palette.css.BLUE,
    };
    var stops = try ColorStops.fromColors(allocator, &colors);
    defer stops.deinit();
    try std.testing.expectEqual(@as(usize, 3), stops.len());
    try std.testing.expectEqual(@as(f32, 0.0), stops.asSlice()[0].offset);
    try std.testing.expectEqual(@as(f32, 0.5), stops.asSlice()[1].offset);
    try std.testing.expectEqual(@as(f32, 1.0), stops.asSlice()[2].offset);

    const single = [_]AlphaColor(Srgb){color.palette.css.RED};
    var one = try ColorStops.fromColors(allocator, &single);
    defer one.deinit();
    try std.testing.expectEqual(@as(f32, 0.0), one.asSlice()[0].offset);
}

test "gradient stops lifecycle" {
    const allocator = std.testing.allocator;
    var gradient = Gradient.default;
    gradient = try gradient.withColors(allocator, &.{
        color.palette.css.RED,
        color.palette.css.BLUE,
    });
    defer gradient.deinit();
    try std.testing.expectEqual(@as(usize, 2), gradient.stops.len());

    var alpha_gradient = try gradient.withAlpha(allocator, 0.25);
    defer alpha_gradient.deinit();
    try std.testing.expectEqual(@as(f32, 0.25), alpha_gradient.stops.asSlice()[0].color.components[3]);
    try std.testing.expectEqual(@as(f32, 0.25), alpha_gradient.stops.asSlice()[1].color.components[3]);
    // The original is untouched (deep copy, not aliasing).
    try std.testing.expectEqual(@as(f32, 1.0), gradient.stops.asSlice()[0].color.components[3]);

    var multiplied = try alpha_gradient.multiplyAlpha(allocator, 0.5);
    defer multiplied.deinit();
    try std.testing.expectEqual(@as(f32, 0.125), multiplied.stops.asSlice()[0].color.components[3]);

    var cloned = try gradient.clone(allocator);
    defer cloned.deinit();
    try std.testing.expectEqualSlices(ColorStop, gradient.stops.asSlice(), cloned.stops.asSlice());

    // Replacing stops with a slice keeps exactly the new stops.
    const replacement = [_]ColorStop{ColorStop.init(0.5, color.palette.css.WHITE)};
    gradient = try gradient.withStops(allocator, &replacement);
    try std.testing.expectEqual(@as(usize, 1), gradient.stops.len());
    try std.testing.expectEqual(@as(f32, 0.5), gradient.stops.asSlice()[0].offset);

    // Replacing with an empty slice frees everything.
    gradient = try gradient.withStops(allocator, &.{});
    try std.testing.expect(gradient.stops.isEmpty());
}
