const std = @import("std");
const t = std.testing;
const images = @import("root.zig");
const tasks = @import("../app/tasks.zig");
const e = @import("../elements/element.zig");
const painter = @import("../elements/painter.zig");
const layout = @import("../elements/layout.zig");
const gpu = @import("../gpu/root.zig");
const Color = @import("../core/color.zig").Color;
const icon = "<svg width=\"4\" height=\"2\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\" height=\"2\" fill=\"red\"/></svg>";

fn pathFor(tmp: anytype, name: []const u8) ![]u8 {
    return std.fs.path.join(t.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

test "ready path builds and paints 100 frames without read hash or decode" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "image.svg", .data = icon });
    const path = try pathFor(tmp, "image.svg");
    defer t.allocator.free(path);
    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const asset = try cache.assets.preloadPath(path, 0);
    try t.expectEqual(images.service.State.ready, cache.assets.metadata(asset).?.state);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.reads);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.hashes);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.decodes);
    // Removing the actual source makes any hidden repeated read fail too.
    try tmp.dir.deleteFile(t.io, "image.svg");
    const before = cache.assets.counters;
    const frame = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    for (1..101) |i| {
        frame.reset(@ptrFromInt(1), .{});
        frame.images = cache;
        frame.frame_id = i;
        e.beginFrame(frame);
        const root = e.imgPath(path);
        try t.expectEqual(@as(f32, 4), frame.nodes[root.index].image.intrinsic_w);
        try t.expectEqual(@as(f32, 2), frame.nodes[root.index].image.intrinsic_h);
        layout.layout(frame, root, .{ .w = 8, .h = 8 });
        scene.* = .{};
        painter.paint(frame, root, scene);
        e.endFrame();
        try t.expectEqual(@as(usize, 1), scene.imageSlice().len);
        try t.expectEqual(@as(u64, 0), frame.image_placeholders);
        try t.expectEqualDeep(before, cache.assets.counters);
        _ = try cache.assets.preloadPath(path, i); // convenience also hits path registry
    }
    std.debug.print("assets: 100 ready frames; reads 1->1, hashes 1->1, decodes 1->1\n", .{});
}

test "missing and corrupt paths cache failure and paint visible pixels" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // Valid BMP signature but deliberately corrupt body.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "corrupt.bmp", .data = "BMcorrupt" });
    const missing = try pathFor(tmp, "missing.png");
    defer t.allocator.free(missing);
    const corrupt = try pathFor(tmp, "corrupt.bmp");
    defer t.allocator.free(corrupt);
    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const frame = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    for ([_][]const u8{ missing, corrupt }) |path| {
        const handle = try cache.assets.preloadPath(path, 0);
        const metadata = cache.assets.metadata(handle).?;
        try t.expectEqual(images.service.State.failed, metadata.state);
        try t.expect(metadata.failure != null);
        const before = cache.assets.counters;
        for (1..11) |i| {
            _ = try cache.assets.preloadPath(path, i);
            frame.reset(@ptrFromInt(1), .{});
            frame.images = cache;
            frame.frame_id = i;
            e.beginFrame(frame);
            const root = e.imgPath(path);
            layout.layout(frame, root, .{ .w = 24, .h = 24 });
            scene.* = .{};
            painter.paint(frame, root, scene);
            e.endFrame();
            try t.expectEqual(@as(u64, 1), frame.image_placeholders);
            try t.expectEqual(@as(usize, 0), scene.imageSlice().len);
            try t.expectEqual(@as(usize, 3), scene.slice().len);
            try t.expectEqualDeep(before, cache.assets.counters);
        }
        var pixels: [24 * 24 * 4]u8 = undefined;
        var renderer = gpu.vellz.Renderer.init(t.allocator);
        defer renderer.deinit();
        try renderer.render(&pixels, 24, 24, .rgba32, Color.hex(0), scene, &.{}, &.{});
        try t.expect(pixels[(12 * 24 + 12) * 4] > 200);
    }
    try t.expectEqual(@as(u64, 2), cache.assets.counters.reads);
    try t.expectEqual(@as(u64, 2), cache.assets.counters.failures);
}

test "content dedup across paths and bytes plus explicit reload" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    var first: ?images.Handle = null;
    for ([_][]const u8{ "a.svg", "b.svg" }) |name| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = icon });
        const path = try pathFor(tmp, name);
        defer t.allocator.free(path);
        const handle = try cache.assets.preloadPath(path, 0);
        const pixels = cache.assets.resolve(handle, 0).?;
        if (first) |old| try t.expectEqualDeep(old, pixels) else first = pixels;
    }
    const embedded = try cache.assets.preloadBytes(icon, 0);
    try t.expectEqualDeep(first.?, cache.assets.resolve(embedded, 0).?);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.decodes);
    const ticket = try cache.assets.reload(embedded);
    try t.expectEqual(images.service.State.loading, cache.assets.metadata(embedded).?.state);
    try t.expect(cache.assets.complete(ticket, icon, 1));
    try t.expectEqual(images.service.State.ready, cache.assets.metadata(embedded).?.state);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.decodes);
}

test "small budgets reject sources and dimensions before decode and reclaim registry" {    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const service = &cache.assets;
    service.budget.count = 1;
    service.budget.source_bytes = 4;
    const too_big = try service.preloadBytes(icon, 0);
    try t.expectEqual(error.SourceTooLarge, service.metadata(too_big).?.failure.?);
    try t.expectError(error.AssetTableFull, service.requestPath("a"));
    try t.expectEqual(@as(u64, 0), service.counters.decodes);
    service.release(too_big);
    service.budget.source_bytes = 1024;
    service.budget.dimension = 2;
    const too_wide = try service.preloadBytes(icon, 0);
    try t.expectEqual(error.TooLarge, service.metadata(too_wide).?.failure.?);
    try t.expectEqual(@as(u64, 0), service.counters.decodes);
    service.release(too_wide);
    try t.expectEqual(@as(usize, 0), service.retained_bytes);
    service.budget.dimension = 100;
    const ready = try service.preloadBytes(icon, 0);
    try t.expect(service.resolve(ready, 1) != null);
    // Force pool reset with a different full-pool image, between frames.
    const big = try t.allocator.alloc(u8, cache.pool.len);
    defer t.allocator.free(big);
    @memset(big, 0);
    _ = try cache.place(123, big, 2048, 2048, 2);
    try t.expect(service.resolve(ready, 2) == null);
    try t.expectEqual(error.Evicted, service.metadata(ready).?.failure.?);
    // Stable asset identity remains valid; explicit completion restores pixels.
    const reload = try service.reload(ready);
    try t.expect(service.complete(reload, icon, 3));
    try t.expect(service.resolve(ready, 3) != null);
}

test "async requestPath loads in a worker and ready assets never re-read" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "image.svg", .data = icon });
    const path = try pathFor(tmp, "image.svg");
    defer t.allocator.free(path);
    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    var rt = tasks.TaskRuntime.init(t.allocator, .{ .workers = 2 });
    defer rt.deinit();
    rt.start();
    cache.assets.bindRuntime(&rt);
    cache.assets.completion_frame = 7;

    const ticket = try cache.assets.requestPath(path);
    try t.expectEqual(images.service.State.loading, cache.assets.metadata(ticket.handle).?.state);
    // A repeat request dedups into the single flight: no second worker job.
    const again = try cache.assets.requestPath(path);
    try t.expectEqual(ticket.handle.slot, again.handle.slot);
    try t.expectEqual(@as(u64, 1), rt.submitted);

    // Bounded wait for the worker read plus UI-thread delivery (drain is
    // the UI thread here; correctness never depends on timing).
    var i: usize = 0;
    while (cache.assets.isPending(ticket) and i < 20_000_000) : (i += 1) {
        rt.drainCompletions();
        std.Thread.yield() catch {};
    }
    try t.expect(!cache.assets.isPending(ticket));
    const md = cache.assets.metadata(ticket.handle).?;
    try t.expectEqual(images.service.State.ready, md.state);
    try t.expectEqual(@as(f32, 4), md.w);
    try t.expectEqual(@as(f32, 2), md.h);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.reads);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.hashes);
    try t.expectEqual(@as(u64, 1), cache.assets.counters.decodes);
    try t.expect(cache.assets.resolve(ticket.handle, 8) != null);
    try t.expectEqual(@as(usize, 0), rt.inFlight());

    // Removing the source proves ready assets never re-read: resolve and
    // metadata stay ready with counters frozen.
    try tmp.dir.deleteFile(t.io, "image.svg");
    const before = cache.assets.counters;
    for (9..19) |frame| {
        try t.expect(cache.assets.resolve(ticket.handle, frame) != null);
        try t.expectEqual(images.service.State.ready, cache.assets.metadata(ticket.handle).?.state);
    }
    try t.expectEqualDeep(before, cache.assets.counters);
}

test "async requestPath over the task limit fails explicitly" {
    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    var rt = tasks.TaskRuntime.init(t.allocator, .{ .workers = 1, .max_in_flight = 1 });
    defer rt.deinit();
    rt.start();
    cache.assets.bindRuntime(&rt);

    // Occupy the single slot with a gated job submitted directly, so the
    // asset read has nowhere to go.
    const Gate = struct {
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var gate = Gate{};
    const Nop = struct {
        gate: *Gate,
    };
    const nop = try t.allocator.create(Nop);
    errdefer t.allocator.destroy(nop);
    nop.* = .{ .gate = &gate };
    _ = try rt.spawnRaw(nop, .{
        .run = struct {
            fn r(raw: *anyopaque, _: tasks.Cancel) void {
                const b: *Nop = @ptrCast(@alignCast(raw));
                while (!b.gate.release.load(.seq_cst)) std.Thread.yield() catch {};
            }
        }.r,
        .complete = struct {
            fn c(_: *anyopaque) void {}
        }.c,
        .destroy = struct {
            fn d(raw: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*Nop, @ptrCast(@alignCast(raw))));
            }
        }.d,
    });

    // Over-limit: explicit error AND an explicit failed entry — never silent.
    try t.expectError(error.TaskQueueFull, cache.assets.requestPath("gated.png"));
    const handle = cache.assets.findPath("gated.png") orelse return error.TestExpectedHandle;
    const md = cache.assets.metadata(handle).?;
    try t.expectEqual(images.service.State.failed, md.state);
    try t.expectEqual(error.TaskQueueFull, md.failure.?);
    try t.expectEqual(@as(u64, 1), rt.rejected_full);

    // Release the gate; teardown stays clean under the testing allocator.
    gate.release.store(true, .seq_cst);
    var i: usize = 0;
    while (rt.inFlight() > 0 and i < 20_000_000) : (i += 1) {
        rt.drainCompletions();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 0), rt.inFlight());
}

test "async cancellation rejects the worker read before dispatch" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "image.svg", .data = icon });
    const path = try pathFor(tmp, "image.svg");
    defer t.allocator.free(path);
    const cache = try images.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    var rt = tasks.TaskRuntime.init(t.allocator, .{ .workers = 2 });
    defer rt.deinit();
    rt.start();
    cache.assets.bindRuntime(&rt);

    const ticket = try cache.assets.requestPath(path);
    try t.expect(cache.assets.cancel(ticket));
    // The worker may still read the file, but neither the alive probe nor
    // the completion dispatch accepts the stale ticket: no decode, no
    // ready state, no completion count.
    var i: usize = 0;
    while (rt.inFlight() > 0 and i < 20_000_000) : (i += 1) {
        rt.drainCompletions();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(images.service.State.failed, cache.assets.metadata(ticket.handle).?.state);
    try t.expectEqual(error.Cancelled, cache.assets.metadata(ticket.handle).?.failure.?);
    try t.expect(!cache.assets.complete(ticket, icon, 1));
    try t.expectEqual(@as(u64, 0), cache.assets.counters.hashes);
    try t.expectEqual(@as(u64, 0), cache.assets.counters.decodes);
    try t.expectEqual(@as(u64, 0), cache.assets.counters.completions);
}
