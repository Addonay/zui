//! Wheel and touchpad scrolling on Wayland, without any Wayland in it. A wl_pointer frame
//! can carry several axis events, and fingers report pixels while wheels report steps.
//! Rules from gpui_linux, with accumulation of repeated events from SDL3.
const std = @import("std");
const SCROLL_LINES = @import("input.zig").SCROLL_LINES;

/// wl_pointer.axis_source.
pub const AxisSource = enum(u32) { wheel = 0, finger = 1, continuous = 2, wheel_tilt = 3 };

/// wl_pointer.axis.
pub const vertical_axis: u32 = 0;
pub const horizontal_axis: u32 = 1;

/// Touchpad movement is scaled like this in GPUI.
const pixel_multiplier: f32 = 3.0;

pub const Scroll = union(enum) {
    pixels: struct { x: f32, y: f32 },
    lines: struct { x: f32, y: f32 },
};

const Axis = struct {
    value: f32 = 0,
    has_value: bool = false,
    discrete: i32 = 0,
    value120: i32 = 0,
};

pub const AxisFrame = struct {
    /// Persists across frames: compositors need not repeat it. Wheels are the safe default,
    /// because they ignore the continuous value that every source also sends.
    source: AxisSource = .wheel,
    vertical: Axis = .{},
    horizontal: Axis = .{},

    fn axis(self: *AxisFrame, which: u32) ?*Axis {
        return switch (which) {
            vertical_axis => &self.vertical,
            horizontal_axis => &self.horizontal,
            else => null,
        };
    }

    pub fn on_source(self: *AxisFrame, source: u32) void {
        self.source = std.enums.fromInt(AxisSource, source) orelse return;
    }
    pub fn on_axis(self: *AxisFrame, which: u32, value: f32) void {
        const a = self.axis(which) orelse return;
        a.value += value;
        a.has_value = true;
    }
    pub fn on_discrete(self: *AxisFrame, which: u32, count: i32) void {
        const a = self.axis(which) orelse return;
        a.discrete +|= count;
    }
    pub fn on_value120(self: *AxisFrame, which: u32, value: i32) void {
        const a = self.axis(which) orelse return;
        a.value120 +|= value;
    }

    /// Ends the frame. Wayland's positive means down and right, ZUI's means up and left.
    /// Shift turns vertical scrolling horizontal, as in GPUI.
    pub fn take(self: *AxisFrame, shift: bool) ?Scroll {
        const v = self.vertical;
        const h = self.horizontal;
        self.vertical = .{};
        self.horizontal = .{};

        if (self.source != .wheel and self.source != .wheel_tilt and (v.has_value or h.has_value)) {
            const dx = (0 - h.value) * pixel_multiplier;
            const dy = (0 - v.value) * pixel_multiplier;
            if (dx == 0 and dy == 0) return null; // The end of a gesture.
            return .{ .pixels = if (shift) .{ .x = dy + dx, .y = 0 } else .{ .x = dx, .y = dy } };
        }
        const dx = 0 - steps(h);
        const dy = 0 - steps(v);
        if (dx == 0 and dy == 0) return null;
        return .{ .lines = if (shift) .{ .x = dy + dx, .y = 0 } else .{ .x = dx, .y = dy } };
    }

    fn steps(a: Axis) f32 {
        // High resolution wheels report through value120, older ones through discrete.
        if (a.value120 != 0) return @as(f32, @floatFromInt(a.value120)) / 120.0 * SCROLL_LINES;
        return @as(f32, @floatFromInt(a.discrete)) * SCROLL_LINES;
    }
};

const testing = std.testing;

test "a wheel notch scrolls lines, and its continuous value is ignored" {
    var f: AxisFrame = .{};
    f.on_source(0);
    f.on_axis(vertical_axis, 15);
    f.on_discrete(vertical_axis, 1);
    const s = f.take(false).?;
    try testing.expectEqual(-SCROLL_LINES, s.lines.y);
    try testing.expectEqual(@as(f32, 0), s.lines.x);
}

test "high resolution wheels: partial notches, and value120 beats discrete" {
    var f: AxisFrame = .{};
    f.on_value120(vertical_axis, 60);
    try testing.expectEqual(-SCROLL_LINES / 2, f.take(false).?.lines.y);
    f.on_value120(vertical_axis, 120);
    f.on_discrete(vertical_axis, 1);
    try testing.expectEqual(-SCROLL_LINES, f.take(false).?.lines.y);
}

test "several events in one frame accumulate" {
    var f: AxisFrame = .{};
    f.on_value120(vertical_axis, 60);
    f.on_value120(vertical_axis, 60);
    try testing.expectEqual(-SCROLL_LINES, f.take(false).?.lines.y);
    f.on_source(1);
    f.on_axis(vertical_axis, 1);
    f.on_axis(vertical_axis, 2);
    try testing.expectEqual(@as(f32, -9), f.take(false).?.pixels.y);
}

test "fingers scroll pixels on both axes" {
    var f: AxisFrame = .{};
    f.on_source(1);
    f.on_axis(vertical_axis, 2);
    f.on_axis(horizontal_axis, -4);
    const s = f.take(false).?;
    try testing.expectEqual(@as(f32, -6), s.pixels.y);
    try testing.expectEqual(@as(f32, 12), s.pixels.x);
}

test "the source persists until it changes" {
    var f: AxisFrame = .{};
    f.on_source(1);
    f.on_axis(vertical_axis, 1);
    _ = f.take(false);
    f.on_axis(vertical_axis, 1);
    try testing.expect(f.take(false).? == .pixels);
    f.on_source(0);
    f.on_discrete(vertical_axis, 1);
    try testing.expect(f.take(false).? == .lines);
}

test "the end of a gesture is not a scroll" {
    var f: AxisFrame = .{};
    f.on_source(1);
    f.on_axis(vertical_axis, 0);
    try testing.expect(f.take(false) == null);
    try testing.expect(f.take(false) == null);
}

test "shift sends vertical scrolling sideways" {
    var f: AxisFrame = .{};
    f.on_discrete(vertical_axis, 1);
    const s = f.take(true).?;
    try testing.expectEqual(-SCROLL_LINES, s.lines.x);
    try testing.expectEqual(@as(f32, 0), s.lines.y);
}

test "unknown sources and axes from a newer compositor are ignored" {
    var f: AxisFrame = .{ .source = .finger };
    f.on_source(99);
    try testing.expectEqual(AxisSource.finger, f.source);
    f.on_axis(7, 5);
    f.on_discrete(7, 5);
    try testing.expect(f.take(false) == null);
}

test "steps saturate instead of overflowing" {
    var f: AxisFrame = .{};
    f.on_discrete(vertical_axis, std.math.maxInt(i32));
    f.on_discrete(vertical_axis, std.math.maxInt(i32));
    try testing.expect(f.take(false) != null);
}
