const std = @import("std");
const asset = @import("asset_cache.zig");

const Cache = asset.AssetCache(u32);

fn noRelease(_: std.mem.Allocator, _: *u32) void {}

test "generic cache deduplicates sources and keeps stable handles" {
    var cache = Cache.init(std.testing.allocator, .{ .release = noRelease });
    defer cache.deinit();
    const source = asset.SourceKey.fromBytes("icon.svg", 1);
    const first = try cache.begin(source);
    const again = try cache.begin(source);
    try std.testing.expect(first.started);
    try std.testing.expect(!again.started);
    try std.testing.expectEqual(first.ticket.handle, again.ticket.handle);
    try std.testing.expect(cache.complete(first.ticket, 7));
    try std.testing.expectEqual(@as(u32, 7), cache.value(first.ticket.handle).?.*);
}

test "asset source starts only the first deduplicated load" {
    var cache = Cache.init(std.testing.allocator, .{ .release = noRelease });
    defer cache.deinit();
    const Probe = struct {
        starts: u32 = 0,
        ticket: ?asset.Ticket = null,
        fn start(raw: *anyopaque, ticket: asset.Ticket) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
            self.ticket = ticket;
        }
    };
    var probe = Probe{};
    const Source = asset.AssetSource(Cache);
    const source = Source{ .context = &probe, .start_fn = Probe.start };
    _ = try source.request(&cache, .{ .hash = 55 });
    _ = try source.request(&cache, .{ .hash = 55 });
    try std.testing.expectEqual(@as(u32, 1), probe.starts);
    try std.testing.expect(probe.ticket != null);
}

test "generic cache rejects cancellation and stale completions" {
    var cache = Cache.init(std.testing.allocator, .{ .release = noRelease });
    defer cache.deinit();
    const ticket = (try cache.begin(.{ .hash = 10 })).ticket;
    try std.testing.expect(cache.cancel(ticket));
    try std.testing.expect(!cache.complete(ticket, 1));
    try std.testing.expectEqual(asset.Failure.cancelled, cache.metadata(ticket.handle).?.failure.?);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.stale_completions);
}

test "generic cache reloads without changing source handle" {
    var cache = Cache.init(std.testing.allocator, .{ .release = noRelease });
    defer cache.deinit();
    const handle = (try cache.begin(.{ .hash = 11 })).ticket.handle;
    const old = cache.metadata(handle).?.revision;
    try std.testing.expect(cache.complete(.{ .handle = handle, .revision = old }, 3));
    const reload = try cache.reload(handle);
    try std.testing.expectEqual(handle, reload.handle);
    try std.testing.expect(reload.revision != old);
    try std.testing.expect(cache.complete(reload, 9));
    try std.testing.expectEqual(@as(u32, 9), cache.value(handle).?.*);
}

test "generic cache evicts unretained entries but preserves retained ones" {
    var cache = Cache.init(std.testing.allocator, .{ .release = noRelease });
    cache.budget.count = 2;
    defer cache.deinit();
    const a = (try cache.begin(.{ .hash = 1 })).ticket;
    const b = (try cache.begin(.{ .hash = 2 })).ticket;
    try std.testing.expect(cache.complete(a, 1));
    try std.testing.expect(cache.complete(b, 2));
    try std.testing.expect(cache.retain(a.handle));
    const c = try cache.begin(.{ .hash = 3 });
    try std.testing.expect(cache.metadata(a.handle) != null);
    try std.testing.expect(cache.complete(c.ticket, 3));
    try std.testing.expect(cache.stats.evictions > 0);
    try std.testing.expectEqual(@as(u32, 1), cache.value(a.handle).?.*);
}

test "generic cache close rejects in-flight completion" {
    var cache = Cache.init(std.testing.allocator, .{ .release = noRelease });
    const ticket = (try cache.begin(.{ .hash = 99 })).ticket;
    cache.close();
    try std.testing.expect(cache.isClosed());
    try std.testing.expect(!cache.complete(ticket, 42));
    try std.testing.expectEqual(asset.Failure.closed, cache.metadata(ticket.handle).?.failure.?);
    cache.deinit();
}
