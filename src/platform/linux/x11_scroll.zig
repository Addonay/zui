//! Smooth scrolling from XInput2 valuators, without any X11 in it. A scroll axis reports
//! an ever-growing position, so a delta needs the previous position, and that position
//! goes stale whenever the pointer leaves or the device changes: using it then would
//! produce one huge jump. Ported from gpui_linux's x11 client.
const std = @import("std");
const SCROLL_LINES = @import("input.zig").SCROLL_LINES;

pub const Axis = struct {
    valuator: ?u16 = null,
    multiplier: f32 = 0,
    /// Double, because these positions keep growing and f32 runs out of precision.
    last: ?f64 = null,
};

pub const Device = struct {
    id: c_int = 0,
    horizontal: Axis = .{},
    vertical: Axis = .{},
};

pub const Delta = struct { x: f32 = 0, y: f32 = 0 };

pub const ScrollDevices = struct {
    pub const max_devices = 32;

    devices: [max_devices]Device = undefined,
    count: usize = 0,

    /// Forgets every position, as when the pointer leaves the window.
    pub fn reset_all(self: *ScrollDevices) void {
        for (self.devices[0..self.count]) |*d| {
            d.horizontal.last = null;
            d.vertical.last = null;
        }
    }

    /// Replaces the device list after a hierarchy change. A device that stays keeps its
    /// position, since nothing moved it; only the changed ones need `forget`.
    pub fn replace(self: *ScrollDevices, new_devices: []const Device) void {
        var next: [max_devices]Device = undefined;
        const n = @min(new_devices.len, max_devices);
        for (new_devices[0..n], next[0..n]) |d, *out| {
            out.* = d;
            if (self.find(d.id)) |old| {
                out.horizontal.last = old.horizontal.last;
                out.vertical.last = old.vertical.last;
            }
        }
        self.devices = next;
        self.count = n;
    }

    fn find(self: *ScrollDevices, id: c_int) ?*Device {
        for (self.devices[0..self.count]) |*d| {
            if (d.id == id) return d;
        }
        return null;
    }

    /// The scroll from one motion event, or null when it did not scroll. `mask` says which
    /// valuators the event carries, and `values` holds only those, packed in order.
    pub fn on_motion(self: *ScrollDevices, source_id: c_int, mask: []const u8, values: []const f64) ?Delta {
        const device = self.find(source_id) orelse return null;
        const dx = axis_delta(&device.horizontal, mask, values);
        const dy = axis_delta(&device.vertical, mask, values);
        if (dx == null and dy == null) return null;
        const delta: Delta = .{ .x = dx orelse 0, .y = dy orelse 0 };
        // The end of a gesture repeats the last position. That is not a scroll.
        if (delta.x == 0 and delta.y == 0) return null;
        return delta;
    }
};

/// Builds an axis from a device's scroll class. An increment of zero means the device
/// reports nonsense: dividing by it would give infinite scrolling, so the axis is dropped.
pub fn make_axis(valuator: c_int, increment: f64) Axis {
    if (increment == 0 or !std.math.isFinite(increment) or valuator < 0) return .{};
    return .{ .valuator = @intCast(valuator), .multiplier = SCROLL_LINES / @as(f32, @floatCast(increment)) };
}

fn axis_delta(axis: *Axis, mask: []const u8, values: []const f64) ?f32 {
    const number = axis.valuator orelse return null;
    const index = valuator_index(mask, number) orelse return null;
    if (index >= values.len) return null;
    const value = values[index];
    defer axis.last = value;
    const last = axis.last orelse return null;
    return @as(f32, @floatCast(last - value)) * axis.multiplier;
}

/// Where valuator `number` sits among the event's packed values, or null if it is absent.
fn valuator_index(mask: []const u8, number: u16) ?usize {
    const byte = number / 8;
    if (byte >= mask.len) return null;
    const bit: u3 = @intCast(number % 8);
    if (mask[byte] & (@as(u8, 1) << bit) == 0) return null;
    var index: usize = 0;
    for (mask[0..byte]) |b| index += @popCount(b);
    index += @popCount(mask[byte] & ((@as(u8, 1) << bit) - 1));
    return index;
}

const testing = std.testing;

fn wheel() ScrollDevices {
    var s: ScrollDevices = .{};
    s.replace(&.{.{ .id = 7, .horizontal = make_axis(2, 120), .vertical = make_axis(3, 120) }});
    return s;
}

test "the first report only sets the position" {
    var s = wheel();
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{500}) == null);
    const d = s.on_motion(7, &.{0b0000_1000}, &.{620}).?;
    try testing.expectEqual(@as(f32, -SCROLL_LINES), d.y);
    try testing.expectEqual(@as(f32, 0), d.x);
}

test "values are packed, so an axis's index depends on what else the event carries" {
    var s = wheel();
    // Valuators 0, 1 (pointer motion) and 3 (vertical) present.
    _ = s.on_motion(7, &.{0b0000_1011}, &.{ 10, 20, 500 });
    const d = s.on_motion(7, &.{0b0000_1011}, &.{ 11, 21, 380 }).?;
    try testing.expectEqual(@as(f32, SCROLL_LINES), d.y);
}

test "plain pointer motion does not scroll, and both axes can move together" {
    var s = wheel();
    try testing.expect(s.on_motion(7, &.{0b0000_0011}, &.{ 1, 2 }) == null);
    _ = s.on_motion(7, &.{0b0000_1100}, &.{ 0, 0 });
    const d = s.on_motion(7, &.{0b0000_1100}, &.{ 60, -60 }).?;
    try testing.expectEqual(@as(f32, -SCROLL_LINES / 2), d.x);
    try testing.expectEqual(@as(f32, SCROLL_LINES / 2), d.y);
}

test "leaving and coming back does not produce a jump" {
    var s = wheel();
    _ = s.on_motion(7, &.{0b0000_1000}, &.{500});
    s.reset_all();
    // The wheel moved a long way while the pointer was elsewhere.
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{50000}) == null);
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{50120}) != null);
}

test "unknown devices and short or odd masks are ignored" {
    var s = wheel();
    try testing.expect(s.on_motion(99, &.{0b0000_1000}, &.{500}) == null);
    try testing.expect(s.on_motion(7, &.{}, &.{}) == null);
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{}) == null);
}

test "a repeated position is not a scroll" {
    var s = wheel();
    _ = s.on_motion(7, &.{0b0000_1000}, &.{500});
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{500}) == null);
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{620}) != null);
}

test "a high valuator across mask bytes" {
    var s: ScrollDevices = .{};
    s.replace(&.{.{ .id = 1, .vertical = make_axis(9, 1) }});
    _ = s.on_motion(1, &.{ 0b0000_0011, 0b0000_0010 }, &.{ 0, 0, 100 });
    const d = s.on_motion(1, &.{ 0b0000_0011, 0b0000_0010 }, &.{ 0, 0, 99 }).?;
    try testing.expectEqual(@as(f32, SCROLL_LINES), d.y);
}

test "a zero increment drops the axis instead of dividing by it" {
    try testing.expect(make_axis(3, 0).valuator == null);
    try testing.expect(make_axis(3, std.math.inf(f64)).valuator == null);
    try testing.expect(make_axis(-1, 120).valuator == null);
}

test "a negative increment means natural scrolling" {
    var s: ScrollDevices = .{};
    s.replace(&.{.{ .id = 1, .vertical = make_axis(0, -120) }});
    _ = s.on_motion(1, &.{1}, &.{0});
    try testing.expectEqual(@as(f32, SCROLL_LINES), s.on_motion(1, &.{1}, &.{120}).?.y);
}

test "replacing the device list keeps positions of devices that stayed" {
    var s = wheel();
    _ = s.on_motion(7, &.{0b0000_1000}, &.{500});
    s.replace(&.{
        .{ .id = 7, .horizontal = make_axis(2, 120), .vertical = make_axis(3, 120) },
        .{ .id = 8, .vertical = make_axis(0, 1) },
    });
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{620}) != null);
    try testing.expect(s.on_motion(8, &.{1}, &.{5}) == null);
    s.replace(&.{});
    try testing.expect(s.on_motion(7, &.{0b0000_1000}, &.{1}) == null);
}
