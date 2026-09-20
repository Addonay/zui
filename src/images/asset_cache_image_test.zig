const std = @import("std");
const asset = @import("asset_cache.zig");
const pool = @import("cache.zig");

fn releasePoolHandle(_: std.mem.Allocator, _: *pool.Handle) void {}

test "generic asset cache retains image-pool handles without replacing the pool" {
    const allocator = std.testing.allocator;
    var images = try pool.Cache.init(allocator);
    defer images.deinit(allocator);
    const Generic = asset.AssetCache(pool.Handle);
    var assets = Generic.init(allocator, .{ .release = releasePoolHandle });
    defer assets.deinit();

    const acquire = try assets.begin(asset.SourceKey.fromBytes("red.png", 1));
    var rgba: [4]u8 = .{ 255, 0, 0, 255 };
    const image = try images.place(17, &rgba, 1, 1, 1);
    try std.testing.expect(assets.complete(acquire.ticket, image));
    const retained = assets.value(acquire.ticket.handle).?.*;
    try std.testing.expect(images.validate(retained, 1));
    try std.testing.expectEqualSlices(u8, &rgba, images.pixels(retained));
}

test "image-pool completion from an old revision is rejected" {
    const allocator = std.testing.allocator;
    var images = try pool.Cache.init(allocator);
    defer images.deinit(allocator);
    const Generic = asset.AssetCache(pool.Handle);
    var assets = Generic.init(allocator, .{ .release = releasePoolHandle });
    defer assets.deinit();

    const first = try assets.begin(.{ .hash = 71 });
    try std.testing.expect(assets.cancel(first.ticket));
    const reload = try assets.reload(first.ticket.handle);
    var rgba: [4]u8 = .{ 0, 255, 0, 255 };
    const image = try images.place(72, &rgba, 1, 1, 1);
    try std.testing.expect(!assets.complete(first.ticket, image));
    try std.testing.expect(assets.complete(reload, image));
}
