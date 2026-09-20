//! GPUI uniform-list geometry planner. It selects visible items and scroll
//! targets; callers render those existing elements in returned index order.
const core = @import("../core/root.zig");
pub const Strategy = enum { top, center, bottom, nearest };
pub const Range = struct { start: usize, end: usize };
pub const UniformList = struct {
    count: usize,
    item_size: core.Size,
    viewport: core.Size,
    scroll_y: f32 = 0,
    flipped: bool = false,
    pub fn contentHeight(self: UniformList) f32 {
        return @as(f32, @floatFromInt(self.count)) * self.item_size.h;
    }
    pub fn visible(self: UniformList) Range {
        if (self.count == 0 or self.item_size.h <= 0) return .{ .start = 0, .end = 0 };
        const start = @min(self.count, @as(usize, @intFromFloat(@max(0, @floor(self.scroll_y / self.item_size.h)))));
        const end = @min(self.count, @as(usize, @intFromFloat(@ceil((self.scroll_y + self.viewport.h) / self.item_size.h))));
        return .{ .start = start, .end = @max(start, end) };
    }
    pub fn scrollTo(self: *UniformList, index: usize, strategy: Strategy) void {
        if (self.count == 0) return;
        const i = @min(index, self.count - 1);
        const top = @as(f32, @floatFromInt(i)) * self.item_size.h;
        const bottom = top + self.item_size.h;
        self.scroll_y = switch (strategy) {
            .top => top,
            .center => top - (self.viewport.h - self.item_size.h) / 2,
            .bottom => bottom - self.viewport.h,
            .nearest => if (top < self.scroll_y) top else if (bottom > self.scroll_y + self.viewport.h) bottom - self.viewport.h else self.scroll_y,
        };
        self.scroll_y = @max(0, @min(self.scroll_y, @max(0, self.contentHeight() - self.viewport.h)));
    }
    pub fn itemRect(self: UniformList, index: usize) core.Rect {
        const y = if (self.flipped) self.contentHeight() - (@as(f32, @floatFromInt(index + 1)) * self.item_size.h) else @as(f32, @floatFromInt(index)) * self.item_size.h;
        return core.rect(0, y - self.scroll_y, self.viewport.w, self.item_size.h);
    }
};

pub fn uniformList(count: usize, item_size: core.Size, viewport: core.Size) UniformList {
    return .{ .count = count, .item_size = item_size, .viewport = viewport };
}
test "uniform list range and strict scroll geometry are deterministic" {
    var list = UniformList{ .count = 10, .item_size = core.size(100, 20), .viewport = core.size(100, 50) };
    try @import("std").testing.expectEqual(Range{ .start = 0, .end = 3 }, list.visible());
    list.scrollTo(5, .top);
    try @import("std").testing.expectEqual(@as(f32, 100), list.scroll_y);
    try @import("std").testing.expectEqual(core.rect(0, 0, 100, 20), list.itemRect(5));
    list.flipped = true;
    try @import("std").testing.expectEqual(@as(f32, -20), list.itemRect(5).y);
}
