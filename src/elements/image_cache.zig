//! Fixed-capacity image-cache scope. Loading is caller-owned; entries provide
//! deduplication, readiness, eviction, and release hooks without GPU coupling.
const std = @import("std");
pub const Max = 64;
pub const State = enum { loading, ready, failed };
pub const Entry = struct { key: u64, state: State, token: u64 };
pub const Cache = struct {
    entries: [Max]Entry = undefined,
    len: usize = 0,
    evictions: u64 = 0,
    releases: u64 = 0,
    pub fn begin(self: *Cache, key: u64, token: u64) ?*Entry {
        if (self.find(key)) |entry| return entry;
        if (self.len == Max) self.evict();
        self.entries[self.len] = .{ .key = key, .state = .loading, .token = token };
        self.len += 1;
        return &self.entries[self.len - 1];
    }
    pub fn complete(self: *Cache, key: u64, state: State) bool {
        if (self.find(key)) |entry| {
            entry.state = state;
            return true;
        }
        return false;
    }
    pub fn remove(self: *Cache, key: u64) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) if (self.entries[i].key == key) {
            self.releases += 1;
            self.entries[i] = self.entries[self.len - 1];
            self.len -= 1;
            return true;
        };
        return false;
    }
    pub fn clear(self: *Cache) void {
        self.releases += self.len;
        self.len = 0;
    }
    fn find(self: *Cache, key: u64) ?*Entry {
        for (self.entries[0..self.len]) |*entry| if (entry.key == key) return entry;
        return null;
    }
    fn evict(self: *Cache) void {
        if (self.len == 0) return;
        self.releases += 1;
        self.evictions += 1;
        self.entries[0] = self.entries[self.len - 1];
        self.len -= 1;
    }
};

pub fn imageCache() Cache {
    return .{};
}
test "image cache deduplicates and releases on eviction" {
    var cache = Cache{};
    _ = cache.begin(1, 10);
    _ = cache.begin(1, 99);
    try @import("std").testing.expectEqual(@as(usize, 1), cache.len);
    try @import("std").testing.expect(cache.complete(1, .ready));
    try @import("std").testing.expect(cache.remove(1));
    try @import("std").testing.expectEqual(@as(u64, 1), cache.releases);
}

test "image cache scope is retained by the element tree" {
    const t = @import("std").testing;
    const element = @import("element.zig");
    var frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(frame);
    defer element.endFrame();
    var cache = try @import("../images/root.zig").Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const scoped = element.withImageCache(cache, element.div().w(20).h(20));
    try t.expect(frame.nodes[scoped.index].image_cache_scope == cache);
}

test "scoped image cache supplies paint resources independently of frame cache" {
    const t = @import("std").testing;
    const element = @import("element.zig");
    const gpu = @import("../gpu/root.zig");
    var frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.frame_id = 1;
    frame.reset(@ptrFromInt(1), .{});
    frame.frame_id = 1;
    element.beginFrame(frame);
    defer element.endFrame();
    var cache = try @import("../images/root.zig").Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const handle = try cache.place(0xCAFE, &pixels, 2, 2, 1);
    const scoped = element.withImageCache(cache, element.imgHandle(handle).w(20).h(20));
    @import("layout.zig").layout(frame, scoped, .{ .w = 20, .h = 20 });
    var scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    var strokes: gpu.StrokeStorage = undefined;
    scene.attachStrokeStorage(&strokes);
    @import("painter.zig").paint(frame, scoped, scene);
    try t.expectEqual(@as(usize, 1), scene.imageSlice().len);
    try t.expectEqual(@as(u64, 0), frame.image_placeholders);
}
