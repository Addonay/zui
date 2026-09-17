//! One-dimensional logical-pixel scrolling shared by scroll containers/lists.
const std = @import("std");
const Key = @import("../platform/root.zig").event.Key;

pub const ScrollModel = struct {
    offset: f64 = 0,
    viewport: f64 = 0,
    extent: f64 = 0,

    pub fn maxOffset(self: ScrollModel) f64 {
        return @max(0, self.extent - self.viewport);
    }
    pub fn resize(self: *ScrollModel, viewport: f64, extent: f64) void {
        self.viewport = finitePositive(viewport);
        self.extent = finitePositive(extent);
        _ = self.jump(self.offset);
    }
    pub fn jump(self: *ScrollModel, offset: f64) bool {
        if (!std.math.isFinite(offset)) return false;
        const next = std.math.clamp(offset, 0, self.maxOffset());
        const changed = next != self.offset;
        self.offset = next;
        return changed;
    }
    /// Returns unconsumed pixels, including a partial delta crossing an edge.
    pub fn scroll(self: *ScrollModel, delta: f64) f64 {
        if (!std.math.isFinite(delta)) return 0;
        const before = self.offset;
        _ = self.jump(before + delta);
        return delta - (self.offset - before);
    }
    pub const Page = enum { up, down };
    pub fn page(self: *ScrollModel, direction: Page) void {
        _ = self.scroll(if (direction == .up) -self.viewport else self.viewport);
    }
    pub fn key(self: *ScrollModel, k: Key, line: f64) bool {
        // The current platform Key enum lacks PageUp/PageDown. Pick them up
        // automatically when the platform owner adds the canonical variants.
        if (comptime @hasField(Key, "page_up")) if (k == .page_up) {
            self.page(.up);
            return true;
        };
        if (comptime @hasField(Key, "page_down")) if (k == .page_down) {
            self.page(.down);
            return true;
        };
        switch (k) {
            .home => _ = self.jump(0),
            .end => _ = self.jump(self.maxOffset()),
            .up => _ = self.scroll(-line),
            .down => _ = self.scroll(line),
            else => return false,
        }
        return true;
    }
    pub const Thumb = struct { start: f64, length: f64, travel: f64 };
    pub fn thumb(self: ScrollModel, track: f64, minimum: f64) Thumb {
        const length = if (self.extent <= 0) track else @min(track, @max(minimum, track * self.viewport / self.extent));
        const travel = @max(0, track - length);
        return .{ .start = if (self.maxOffset() > 0) travel * self.offset / self.maxOffset() else 0, .length = length, .travel = travel };
    }
    fn finitePositive(n: f64) f64 {
        return if (std.math.isFinite(n)) @max(0, n) else 0;
    }
};

test "scroll model bounds, remainder, proportional thumb and resize reclamp" {
    const t = std.testing;
    var m = ScrollModel{};
    m.resize(100, 1000);
    try t.expectEqual(@as(f64, 0), m.scroll(850));
    try t.expectEqual(@as(f64, 50), m.scroll(100));
    try t.expectEqual(@as(f64, 900), m.offset);
    const thumb = m.thumb(100, 0);
    try t.expectEqual(@as(f64, 10), thumb.length);
    try t.expectEqual(@as(f64, 90), thumb.start);
    m.resize(500, 700);
    try t.expectEqual(@as(f64, 200), m.offset);
    try t.expect(m.key(.home, 20));
    try t.expectEqual(@as(f64, -50), m.scroll(-50));
    m.resize(1000, 100);
    try t.expectEqual(@as(f64, 0), m.maxOffset());
    try t.expect(!m.jump(std.math.nan(f64)));
}
