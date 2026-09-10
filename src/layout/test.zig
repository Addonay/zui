//! Taffy `src/test.rs` porting workspace.
//!
//! Taffy's shared measurement utilities used by hand-written and fixture tests.

pub const fixture_tolerance: f32 = 0.1;

const geometry = @import("geometry.zig");
const available = @import("style/available_space.zig");
const std = @import("std");

pub fn roughly_equal(expected: f32, actual: f32) bool {
    return @abs(expected - actual) < fixture_tolerance;
}

pub const WritingMode = enum { horizontal, vertical };
pub const AspectRatioMeasureData = struct {
    width: f32,
    height_ratio: f32,

    pub fn measure(self: AspectRatioMeasureData, known: geometry.Size(?f32)) geometry.Size(f32) {
        const width = known.width orelse self.width;
        const height = known.height orelse width * self.height_ratio;
        return .{ .width = width, .height = height };
    }
};

pub const AhemTextMeasureData = struct {
    text: []const u8,
    writing_mode: WritingMode = .horizontal,

    pub fn measure(self: AhemTextMeasureData, known: geometry.Size(?f32), space: geometry.Size(available.AvailableSpace)) geometry.Size(f32) {
        const inline_axis = if (self.writing_mode == .horizontal) geometry.AbsoluteAxis.horizontal else geometry.AbsoluteAxis.vertical;
        const block_axis = inline_axis.other_axis();
        var line_count: usize = 1;
        var min_line_length: usize = 0;
        var max_line_length: usize = 0;
        // Ahem fixtures use U+200B as a wrapping opportunity. Work directly
        // on UTF-8 bytes here: the delimiter bytes are unambiguous and the
        // test font measures one ASCII codepoint as a 10px advance.
        var start: usize = 0;
        while (start <= self.text.len) {
            const rest = self.text[start..];
            const delimiter = std.mem.indexOf(u8, rest, "\xE2\x80\x8B");
            const line = if (delimiter) |offset| rest[0..offset] else rest;
            min_line_length = @max(min_line_length, line.len);
            max_line_length += line.len;
            if (delimiter) |offset| start += offset + 3 else break;
        }
        const inline_known = known.get_abs(inline_axis);
        const inline_space = switch (space.get_abs(inline_axis)) {
            .min_content => @as(f32, @floatFromInt(min_line_length)) * 10,
            .max_content => @as(f32, @floatFromInt(max_line_length)) * 10,
            .definite => |value| @min(value, @as(f32, @floatFromInt(max_line_length)) * 10),
        };
        const inline_size = @max(inline_known orelse inline_space, @as(f32, @floatFromInt(min_line_length)) * 10);
        const inline_line_length = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(inline_size / 10))));
        if (max_line_length > 0) {
            line_count = 0;
            var current: usize = 0;
            for (0..max_line_length) |index| {
                if (current + 1 > inline_line_length) {
                    line_count += 1;
                    current = 0;
                }
                current += 1;
                _ = index;
            }
            if (current > 0) line_count += 1;
        }
        const block_known = known.get_abs(block_axis);
        const block_size = block_known orelse @as(f32, @floatFromInt(line_count)) * 10;
        return if (self.writing_mode == .horizontal) .{ .width = inline_size, .height = block_size } else .{ .width = block_size, .height = inline_size };
    }
};

pub const TestMeasureData = union(enum) {
    zero,
    fixed: geometry.Size(f32),
    aspect_ratio: AspectRatioMeasureData,
    ahem_text: AhemTextMeasureData,
};

pub const TestNodeContext = struct {
    count: usize = 0,
    measure_data: TestMeasureData = .zero,

    pub fn new(measure_data: TestMeasureData) TestNodeContext {
        return .{ .measure_data = measure_data };
    }
    pub fn zero() TestNodeContext {
        return new(.zero);
    }
    pub fn fixed(size: geometry.Size(f32)) TestNodeContext {
        return new(.{ .fixed = size });
    }
    pub fn aspect_ratio(width: f32, height_ratio: f32) TestNodeContext {
        return new(.{ .aspect_ratio = .{ .width = width, .height_ratio = height_ratio } });
    }
    pub fn ahem_text(text: []const u8, writing_mode: WritingMode) TestNodeContext {
        return new(.{ .ahem_text = .{ .text = text, .writing_mode = writing_mode } });
    }
};

pub fn test_measure_function(context_pointer: ?*anyopaque, known_dimensions: geometry.Size(?f32), available_space: geometry.Size(available.AvailableSpace)) geometry.Size(f32) {
    if (known_dimensions.width != null and known_dimensions.height != null) return .{ .width = known_dimensions.width.?, .height = known_dimensions.height.? };
    const context = if (context_pointer) |pointer| @as(*TestNodeContext, @ptrCast(@alignCast(pointer))) else return .{ .width = known_dimensions.width orelse 0, .height = known_dimensions.height orelse 0 };
    context.count += 1;
    const measured = switch (context.measure_data) {
        .zero => geometry.F32Size{ .width = 0, .height = 0 },
        .fixed => |size| size,
        .aspect_ratio => |data| data.measure(known_dimensions),
        .ahem_text => |data| data.measure(known_dimensions, available_space),
    };
    return .{ .width = known_dimensions.width orelse measured.width, .height = known_dimensions.height orelse measured.height };
}

test "shared test measurement contexts preserve intrinsic and known dimensions" {
    const testing = std.testing;
    var context = TestNodeContext.fixed(.{ .width = 30, .height = 12 });
    const context_ptr: *anyopaque = @ptrCast(&context);
    const measured = test_measure_function(context_ptr, .{ .width = null, .height = null }, .{ .width = .max_content, .height = .max_content });
    try testing.expectEqual(@as(f32, 30), measured.width);
    try testing.expectEqual(@as(f32, 12), measured.height);
    try testing.expectEqual(@as(usize, 1), context.count);
    const known = test_measure_function(context_ptr, .{ .width = 7, .height = 8 }, .{ .width = .max_content, .height = .max_content });
    try testing.expectEqual(@as(f32, 7), known.width);
    try testing.expectEqual(@as(f32, 8), known.height);
    try testing.expectEqual(@as(usize, 1), context.count);
}
