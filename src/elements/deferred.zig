//! Deferred structural elements: retain layout identity, schedule paint order.
const std = @import("std");
const element = @import("element.zig");

pub const Max = 32;
pub const Record = struct { child: element.Element, priority: usize = 0, sequence: u32 = 0, torn_down: bool = false };
pub const Queue = struct {
    records: [Max]Record = undefined,
    len: usize = 0,
    next_sequence: u32 = 0,
    pub fn enqueue(self: *Queue, child: element.Element, priority: usize) bool {
        if (self.len == Max) return false;
        self.records[self.len] = .{ .child = child, .priority = priority, .sequence = self.next_sequence };
        self.len += 1;
        self.next_sequence += 1;
        return true;
    }
    pub fn ordered(self: *const Queue, out: *[Max]u8) []const u8 {
        var n: usize = 0;
        while (n < self.len) : (n += 1) out[n] = @intCast(n);
        std.sort.heap(u8, out[0..self.len], self, less);
        return out[0..self.len];
    }
    pub fn teardown(self: *Queue) void {
        for (self.records[0..self.len]) |*record| record.torn_down = true;
        self.len = 0;
    }
    fn less(ctx: *const Queue, a: u8, b: u8) bool {
        const x = ctx.records[a];
        const y = ctx.records[b];
        return if (x.priority == y.priority) x.sequence < y.sequence else x.priority < y.priority;
    }
};

test "deferred order is stable and teardown is observable" {
    var queue = Queue{};
    var frame = element.Frame{};
    frame.reset(undefined, .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const a = element.div();
    const b = element.div();
    try @import("std").testing.expect(queue.enqueue(a, 1));
    try @import("std").testing.expect(queue.enqueue(b, 3));
    try @import("std").testing.expect(queue.enqueue(a, 3));
    var order: [Max]u8 = undefined;
    const sorted = queue.ordered(&order);
    try @import("std").testing.expectEqual(@as(u8, 0), sorted[0]);
    try @import("std").testing.expectEqual(@as(u8, 1), sorted[1]);
    try @import("std").testing.expectEqual(@as(u8, 2), sorted[2]);
    queue.teardown();
    try @import("std").testing.expect(queue.len == 0);
}
