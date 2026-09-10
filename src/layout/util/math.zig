//! Direct-port home for Taffy's `util/math.rs`.

pub const MaybeMath = struct {};

pub fn f32_max(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

pub fn f32_min(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

pub fn maybe_max(a: ?f32, b: ?f32) ?f32 {
    if (a) |left| if (b) |right| return @max(left, right);
    return a orelse b;
}

pub fn maybe_min(a: ?f32, b: ?f32) ?f32 {
    if (a) |left| if (b) |right| return @min(left, right);
    return a;
}

pub fn option_maybe_min(lhs: ?f32, rhs: ?f32) ?f32 {
    if (lhs) |left| if (rhs) |right| return @min(left, right);
    return lhs;
}

pub fn option_maybe_max(lhs: ?f32, rhs: ?f32) ?f32 {
    if (lhs) |left| if (rhs) |right| return @max(left, right);
    return lhs;
}

pub fn option_maybe_clamp(value: ?f32, minimum: ?f32, maximum: ?f32) ?f32 {
    if (value) |number| return @min(maximum orelse number, @max(minimum orelse number, number));
    return null;
}

pub fn option_maybe_add(lhs: ?f32, rhs: ?f32) ?f32 {
    if (lhs) |left| if (rhs) |right| return left + right;
    return lhs;
}

pub fn option_maybe_sub(lhs: ?f32, rhs: ?f32) ?f32 {
    if (lhs) |left| if (rhs) |right| return left - right;
    return lhs;
}

pub fn maybe_clamp(value: ?f32, minimum: ?f32, maximum: ?f32) ?f32 {
    return option_maybe_clamp(value, minimum, maximum);
}

pub fn maybe_add(lhs: ?f32, rhs: ?f32) ?f32 {
    return option_maybe_add(lhs, rhs);
}
pub fn maybe_sub(lhs: ?f32, rhs: ?f32) ?f32 {
    return option_maybe_sub(lhs, rhs);
}

pub fn f32_maybe_min(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| @min(lhs, value) else lhs;
}
pub fn f32_maybe_max(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| @max(lhs, value) else lhs;
}
pub fn f32_maybe_clamp(value: f32, minimum: ?f32, maximum: ?f32) f32 {
    return @min(maximum orelse value, @max(minimum orelse value, value));
}
pub fn f32_maybe_add(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| lhs + value else lhs;
}
pub fn f32_maybe_sub(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| lhs - value else lhs;
}

pub fn available_maybe_min(value: @import("../style/available_space.zig").AvailableSpace, rhs: ?f32) @import("../style/available_space.zig").AvailableSpace {
    return switch (value) {
        .definite => |number| if (rhs) |right| .{ .definite = @min(number, right) } else .{ .definite = number },
        .min_content => if (rhs) |right| .{ .definite = right } else .min_content,
        .max_content => if (rhs) |right| .{ .definite = right } else .max_content,
    };
}

pub fn available_maybe_max(value: @import("../style/available_space.zig").AvailableSpace, rhs: ?f32) @import("../style/available_space.zig").AvailableSpace {
    return switch (value) {
        .definite => |number| if (rhs) |right| .{ .definite = @max(number, right) } else .{ .definite = number },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

pub fn available_maybe_clamp(value: @import("../style/available_space.zig").AvailableSpace, minimum: ?f32, maximum: ?f32) @import("../style/available_space.zig").AvailableSpace {
    return switch (value) {
        .definite => |number| .{ .definite = @min(maximum orelse number, @max(minimum orelse number, number)) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

pub fn available_maybe_add(value: @import("../style/available_space.zig").AvailableSpace, rhs: ?f32) @import("../style/available_space.zig").AvailableSpace {
    return switch (value) {
        .definite => |number| .{ .definite = number + (rhs orelse 0) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

pub fn available_maybe_sub(value: @import("../style/available_space.zig").AvailableSpace, rhs: ?f32) @import("../style/available_space.zig").AvailableSpace {
    return switch (value) {
        .definite => |number| .{ .definite = number - (rhs orelse 0) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

pub fn optional_size_maybe_min(value: @import("../geometry.zig").Size(?f32), rhs: @import("../geometry.zig").Size(?f32)) @import("../geometry.zig").Size(?f32) {
    return .{ .width = maybe_min(value.width, rhs.width), .height = maybe_min(value.height, rhs.height) };
}

pub fn optional_size_maybe_max(value: @import("../geometry.zig").Size(?f32), rhs: @import("../geometry.zig").Size(?f32)) @import("../geometry.zig").Size(?f32) {
    return .{ .width = maybe_max(value.width, rhs.width), .height = maybe_max(value.height, rhs.height) };
}

pub fn optional_size_maybe_clamp(value: @import("../geometry.zig").Size(?f32), minimum: @import("../geometry.zig").Size(?f32), maximum: @import("../geometry.zig").Size(?f32)) @import("../geometry.zig").Size(?f32) {
    return .{ .width = option_maybe_clamp(value.width, minimum.width, maximum.width), .height = option_maybe_clamp(value.height, minimum.height, maximum.height) };
}

pub fn optional_size_maybe_add(value: @import("../geometry.zig").Size(?f32), rhs: @import("../geometry.zig").Size(?f32)) @import("../geometry.zig").Size(?f32) {
    return .{ .width = option_maybe_add(value.width, rhs.width), .height = option_maybe_add(value.height, rhs.height) };
}

pub fn optional_size_maybe_sub(value: @import("../geometry.zig").Size(?f32), rhs: @import("../geometry.zig").Size(?f32)) @import("../geometry.zig").Size(?f32) {
    return .{ .width = option_maybe_sub(value.width, rhs.width), .height = option_maybe_sub(value.height, rhs.height) };
}

test "MaybeMath overloads preserve optional and intrinsic constraints" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(?f32, 3), maybe_min(3, null));
    try testing.expectEqual(@as(?f32, 5), maybe_max(null, 5));
    const size = optional_size_maybe_add(.{ .width = 3, .height = null }, .{ .width = 2, .height = 4 });
    try testing.expectEqual(@as(?f32, 5), size.width);
    try testing.expect(size.height == null);
    const intrinsic = available_maybe_sub(.max_content, 10);
    try testing.expect(intrinsic == .max_content);
}
