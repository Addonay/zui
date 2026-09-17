const std = @import("std");
const App = @import("../app/app.zig").App;
const Window = @import("../app/window.zig").Window;
const runtime = @import("../app/runtime.zig");
const elements = @import("../elements/root.zig");
const Scene = @import("../gpu/scene.zig").Scene;
const inspector = @import("inspector.zig");

const View = struct {
    pub const Options = struct {};
    pub fn init(_: *runtime.Context(View), _: Options) View {
        return .{};
    }
    pub fn render(_: *View, _: *Window, _: *runtime.Context(View)) elements.Element {
        return elements.div().keyed(101).w(100).h(80)
            .semantic(.{ .role = .group, .name = "Panel" })
            .child(elements.text("Save \"now\"\n", .{}).keyed(202).w(40).h(20)
            .withFocus(.{ .id = 7 }).semantic(.{ .role = .button, .name = "Save" }));
    }
};
fn build(_: *Window, cx: *runtime.Context(View)) runtime.Entity(View) {
    return cx.new(View, .{});
}

test "headless inspector captures tree keys bounds semantics and escaped JSON" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, build);
    // Deterministic geometry without requiring installed fonts.
    win.cozmic_engine_fn = null;
    win.focused = .{ .id = 7 };
    var captured: std.Io.Writer.Allocating = .init(t.allocator);
    defer captured.deinit();
    win.setInspector(.{ .enabled = true, .sink = .{ .context = &captured, .write = struct {
        fn write(raw: *anyopaque, bytes: []const u8) !void {
            const writer: *std.Io.Writer.Allocating = @ptrCast(@alignCast(raw));
            try writer.writer.writeAll(bytes);
        }
    }.write } });
    try t.expect(app.step());
    const line = captured.written();
    try t.expect(line[line.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try t.expectEqualStrings("zui.frame", object.get("type").?.string);
    const nodes = object.get("elements").?.array.items;
    try t.expectEqual(@as(usize, 2), nodes.len);
    try t.expectEqual(@as(i64, 101), nodes[0].object.get("stable_key").?.integer);
    try t.expectEqual(@as(i64, 202), nodes[1].object.get("stable_key").?.integer);
    try t.expectEqualStrings("button", nodes[1].object.get("semantic").?.object.get("role").?.string);
    try t.expectEqualStrings("Save", nodes[1].object.get("semantic").?.object.get("name").?.string);
    try t.expectEqualStrings("Save \"now\"\n", nodes[1].object.get("text_preview").?.string);
    try t.expect(nodes[1].object.get("focused").?.bool);
    try t.expectEqual(@as(f32, 100), win.ui_frame.nodes[0].bounds.w);
    try t.expectEqual(@as(f32, 80), win.ui_frame.nodes[0].bounds.h);
    const expected = try std.json.Stringify.valueAlloc(t.allocator, win.ui_frame.nodes[0].bounds, .{});
    defer t.allocator.free(expected);
    try t.expect(std.mem.indexOf(u8, line, expected) != null);
    try t.expectEqual(@as(usize, 1), object.get("hit_regions").?.array.items.len);
    try t.expect(win.diagnostics().durations.layout_ns != null);
    try t.expect(win.diagnostics().durations.paint_ns != null);
    win.setInspector(.{});
    const before = win.scene.len;
    win.setDebugOverlay(.{ .bounds = true, .hit_regions = true, .focus = true });
    try t.expect(app.step());
    try t.expectEqual(before + 4, win.scene.len);
    try t.expectEqual(@as(f32, 2), win.scene.slice()[win.scene.len - 1].border_width);
    try t.expectEqual(@as(usize, 1), win.ui_frame.region_count);
    try t.expectEqual(@as(u64, 0), win.scene.dropped);
}

test "diagnostics aggregate actual scene failure and image eviction across close" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn draw(_: *Window, scene: *Scene) void {
            scene.command_len = scene.commands.len;
            _ = scene.push(.{ .x = 0, .y = 0, .w = 1, .h = 1, .color = .white });
        }
    }.draw);
    const cache = app.image_cache.?;
    const first = try cache.place(1, &.{ 255, 0, 0, 255 }, 1, 1, 1);
    for (1..cache.entries.len) |i| _ = try cache.place(i + 1, &.{ 0, 0, 0, 255 }, 1, 1, 1);
    _ = try cache.place(999, &.{ 0, 0, 0, 255 }, 1, 1, 2);
    try t.expect(!cache.validate(first, 2));
    try t.expect(app.step());
    for (0..app.event_queue.buf.len) |_| _ = app.event_queue.push(.{ .window = .resized });
    try t.expect(app.event_queue.push(.{ .window = .resized }));
    try t.expect(!app.event_queue.push(.{ .key = .{ .key = .a, .pressed = true } }));
    const snapshot = app.diagnostics();
    try t.expectEqual(@as(u64, 1), snapshot.event_coalesced);
    try t.expectEqual(@as(u64, 1), snapshot.event_drops);
    try t.expectEqual(@as(u64, 1), snapshot.totals.scene_dropped);
    try t.expectEqual(@as(u64, 1), snapshot.rejected_frames);
    try t.expectEqual(@as(u64, 1), snapshot.image_evictions);
    try t.expectEqual(@as(u64, 1), snapshot.image_stale_drops);
    try t.expect(snapshot.image_pool_used > 0);
    try t.expectEqual(cache.entries.len, snapshot.image_entries);
    win.close();
    app.reapClosed();
    try t.expectEqual(@as(u64, 1), app.diagnostics().totals.frames);
    try t.expectEqual(@as(u64, 1), app.diagnostics().totals.scene_dropped);
}

test "overlay exhaustion skips diagnostic ink without scene drops" {
    const t = std.testing;
    const frame = try t.allocator.create(elements.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.node_count = 1;
    frame.nodes[0] = .{ .bounds = .{ .w = 10, .h = 10 } };
    const scene = try t.allocator.create(Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    scene.command_len = scene.commands.len;
    try t.expectEqual(@as(u64, 1), inspector.paintOverlay(frame, scene, 0, .{ .bounds = true }));
    try t.expectEqual(@as(u64, 0), scene.dropped);
}
