const std = @import("std");
const App = @import("../app/app.zig").App;
const Window = @import("../app/window.zig").Window;
const e = @import("../elements/root.zig");
const ScrollArea = @import("scroll_area.zig").ScrollArea;

fn paint(win: *Window, entity: anytype) void {
    const frame = &win.ui_frame;
    frame.reset(win, win.pointer_position);
    win.scene.clear();
    e.element.beginFrame(frame);
    defer e.element.endFrame();
    const root = entity.toElement();
    e.layout.layout(frame, root, .{ .w = 300, .h = 500 });
    e.painter.paint(frame, root, &win.scene);
    win.updateHitRegions();
}
const VirtualList = @import("virtual_list.zig").VirtualList;
fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
fn row(raw: ?*anyopaque, _: usize, _: *Window) e.Element {
    const calls: *usize = @ptrCast(@alignCast(raw.?));
    calls.* += 1;
    return e.div().h(20);
}

test "million item list builds bounded nodes at start middle end and scrollbar jump" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    var calls: usize = 0;
    const list = app.entities.create(VirtualList, .{ .scroll = .{ .key = 500, .height = 100 }, .item_count = 1_000_000, .item_height = 20, .context = &calls, .build_item = row }, win);
    for ([_]f64{ 0, 10_000_000.25, 19_999_900 }) |offset| {
        list.readMut().scroll.model.resize(100, 20_000_000);
        _ = list.readMut().scroll.model.jump(offset);
        calls = 0;
        paint(win, list);
        // ceil(viewport/height) + partial row + 2*overscan <= 10.
        // One wrapper + one builder node per item, 4 chrome nodes.
        try t.expect(calls <= 10);
        try t.expectEqual(calls, list.read().built_range.end - list.read().built_range.start);
        try t.expect(win.ui_frame.node_count <= 24);
        try t.expectEqual(@as(usize, 0), win.ui_frame.semantic_tree.dropped);
        const semantic = win.ui_frame.semantic_tree.find(500).?;
        try t.expectEqual(@import("../a11y/root.zig").Role.list, semantic.properties.role);
        try t.expect(semantic.properties.states.scrollable);
        var visible: usize = 0;
        for (win.ui_frame.semantic_tree.nodes[0..win.ui_frame.semantic_tree.count]) |node| {
            if (node.properties.role != .listitem) continue;
            try t.expectEqual(@as(?usize, 1_000_000), node.properties.set_size);
            try t.expectEqual(@as(u64, 500), node.parent);
            if (!node.properties.states.hidden) visible += 1;
        }
        try t.expect(visible >= 5);
        std.debug.print("virtual-list: 1,000,000 items offset {d}: {d} builders, {d} nodes\n", .{ offset, calls, win.ui_frame.node_count });
    }
    try t.expect(win.ui_frame.semantic_tree.perform(500, .{ .action = .focus }, win));
    key(win, .home);
    paint(win, list);
    try t.expectEqual(@as(usize, 0), list.read().built_range.start);
    key(win, .end);
    paint(win, list);
    try t.expectEqual(@as(usize, 1_000_000), list.read().built_range.end);
    // Track click at top then drag outside maps to final item in O(1).
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 299, .y = 1 }, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 800, .y = 200 }, .button = .left, .pressed = false, .motion = true } });
    paint(win, list);
    try t.expectEqual(@as(usize, 1_000_000), list.read().built_range.end);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 800, .y = 200 }, .button = .left, .pressed = false } });
    list.readMut().options.item_count = 2;
    list.readMut().options.scroll.height = 200;
    paint(win, list);
    try t.expectEqual(@as(f64, 0), list.read().scroll.model.offset);
    try t.expectEqual(@as(usize, 2), list.read().built_range.end);
    list.readMut().options.item_count = 0;
    paint(win, list);
    try t.expectEqual(@as(usize, 0), list.read().built_range.end);
}

test "nested ScrollArea inner consumes partial deltas and chains only at edges" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    const inner = app.entities.create(ScrollArea, .{ .key = 101, .width = 200, .height = 100, .build = content }, win);
    const Entity = @TypeOf(inner);
    var inner_ref = inner;
    const outer = app.entities.create(ScrollArea, .{ .key = 102, .width = 300, .height = 200, .context = &inner_ref, .build = struct {
        fn build(raw: ?*anyopaque, _: *Window) e.Element {
            const entity: *Entity = @ptrCast(@alignCast(raw.?));
            return e.div().child(entity.toElement()).child(e.div().h(1000));
        }
    }.build }, win);
    paint(win, outer);
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 10, .y = 10 }, .dy = -1 } });
    try t.expectEqual(@as(f64, 32), inner.read().model.offset);
    try t.expectEqual(@as(f64, 0), outer.read().model.offset);
    _ = inner.readMut().model.jump(890);
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 10, .y = 10 }, .dy = -1 } });
    try t.expectEqual(@as(f64, 900), inner.read().model.offset);
    try t.expectEqual(@as(f64, 22), outer.read().model.offset);
    inner.readMut().options.chaining = .contain;
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 10, .y = 10 }, .dy = -1 } });
    try t.expectEqual(@as(f64, 22), outer.read().model.offset);
}
fn content(_: ?*anyopaque, _: *Window) e.Element {
    return e.div().w_full().child(e.div().h(500)).child(e.div().h(500));
}
fn key(win: *Window, k: @import("../platform/root.zig").event.Key) void {
    win.handleEvent(.{ .key = .{ .key = k, .pressed = true } });
}

test "ScrollArea real layout paint wheel keyboard scrollbar and resize" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    const area = app.entities.create(ScrollArea, .{ .key = 100, .width = 300, .height = 100, .build = content }, win);
    paint(win, area);
    try t.expectEqual(@as(f64, 1000), area.read().model.extent);
    try t.expectEqual(@as(f64, 900), area.read().model.maxOffset());
    win.handleEvent(.{ .scroll = .{ .pos = .{ .x = 10, .y = 10 }, .dy = -0.5 } });
    try t.expectEqual(@as(f64, 16), area.read().model.offset);
    paint(win, area);
    try t.expect(win.ui_frame.semantic_tree.find(100).?.properties.states.scrollable);
    try t.expect(win.ui_frame.semantic_tree.perform(100, .{ .action = .focus }, win));
    key(win, .space);
    try t.expectEqual(@as(f64, 116), area.read().model.offset);
    win.handleEvent(.{ .key = .{ .key = .space, .pressed = true, .modifiers = .{ .shift = true } } });
    try t.expectEqual(@as(f64, 16), area.read().model.offset);
    key(win, .end);
    try t.expectEqual(@as(f64, 900), area.read().model.offset);
    key(win, .home);
    try t.expectEqual(@as(f64, 0), area.read().model.offset);
    paint(win, area);
    // Track press captures; moving outside reaches and clamps to the end.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 299, .y = 2 }, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 900, .y = 200 }, .button = .left, .pressed = false, .motion = true } });
    try t.expectEqual(@as(f64, 900), area.read().model.offset);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 900, .y = 200 }, .button = .left, .pressed = false } });
    try t.expect(!area.read().dragging);
    area.readMut().options.height = 500;
    paint(win, area);
    try t.expectEqual(@as(f64, 500), area.read().model.offset);
    try t.expectEqual(@as(u64, 0), win.ui_frame.dropped_regions);
}
