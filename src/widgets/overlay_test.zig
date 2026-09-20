const std = @import("std");
const t = std.testing;
const App = @import("../app/app.zig").App;
const Window = @import("../app/window.zig").Window;
const e = @import("../elements/root.zig");
const w = @import("root.zig");
const Item = @import("menu.zig").Item;
fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
fn paint(win: *Window, entities: anytype) void {
    win.ui_frame.reset(win, win.pointer_position);
    win.scene.clear();
    e.element.beginFrame(&win.ui_frame);
    defer e.element.endFrame();
    // Deliberately tiny clipped ancestor: portals must escape it.
    var root = e.div().w(320).h(40).flex_row();
    inline for (entities) |entity| root = root.child(entity.toElement());
    e.layout.layout(&win.ui_frame, root, .{ .w = 640, .h = 480 });
    e.painter.paint(&win.ui_frame, root, &win.scene);
    win.updateHitRegions();
}
fn key(win: *Window, k: @import("../platform/root.zig").event.Key) void {
    win.handleEvent(.{ .key = .{ .key = k, .pressed = true } });
}
fn click(win: *Window, x: f32, y: f32) void {
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = x, .y = y }, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = x, .y = y }, .button = .left, .pressed = false } });
}
test "portal menu opens on release, escapes clip, skips disabled, restores and dismisses" {
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    var items = [_]Item{ .{ .key = 11, .label = "One" }, .{ .key = 12, .label = "Disabled", .disabled = true }, .{ .key = 13, .label = "Check", .checked = false } };
    const menu = app.entities.create(w.Menu, .{ .key = 10, .label = "Menu", .items = &items }, win);
    paint(win, .{menu});
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try t.expect(!menu.read().overlay.open);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false } });
    paint(win, .{menu});
    const tree = &win.ui_frame.semantic_tree;
    try t.expectEqual(w.a11y.Role.menu, tree.find(menu.read().popupKey()).?.properties.role);
    try t.expect(tree.find(13).?.bounds.h > 0);
    try t.expect(tree.find(13).?.bounds.y >= 40);
    key(win, .down);
    try t.expectEqual(@as(usize, 2), menu.read().active);
    key(win, .enter);
    try t.expect(items[2].checked.?);
    try t.expect(!menu.read().overlay.open);
    try t.expectEqual(menu.focusHandle(null).id, win.focused.id);
    paint(win, .{menu});
    key(win, .enter);
    paint(win, .{menu});
    click(win, 500, 400);
    try t.expect(!menu.read().overlay.open);
    try t.expectEqual(menu.focusHandle(null).id, win.focused.id);
    paint(win, .{menu});
    key(win, .space);
    paint(win, .{menu});
    key(win, .escape);
    try t.expect(!menu.read().overlay.open);
    paint(win, .{menu});
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 20, .y = 20 }, .button = .right, .pressed = true } });
    paint(win, .{menu});
    try t.expect(menu.read().overlay.open);
    try t.expect(menu.read().at_pointer);
    key(win, .escape);
}
test "select keyboard End virtualizes large list and pointer chooses option" {
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    var items: [1000]Item = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .key = index + 100, .label = "Choice" };
    const select = app.entities.create(w.Select, .{ .key = 20, .label = "Select", .items = &items }, win);
    paint(win, .{select});
    key(win, .tab);
    key(win, .down);
    paint(win, .{select});
    key(win, .end);
    paint(win, .{select});
    try t.expect(win.ui_frame.node_count < 60);
    try t.expectEqual(@as(usize, 999), select.read().active);
    try t.expectEqual(w.a11y.Role.combobox, win.ui_frame.semantic_tree.find(20).?.properties.role);
    try t.expectEqual(w.a11y.Role.listbox, win.ui_frame.semantic_tree.find(select.read().popupKey()).?.properties.role);
    key(win, .enter);
    try t.expectEqual(@as(?usize, 999), select.read().selected);
    paint(win, .{select});
    key(win, .down);
    paint(win, .{select});
    key(win, .home);
    paint(win, .{select});
    const rect = win.ui_frame.semantic_tree.find(100).?.bounds;
    click(win, rect.x + 10, rect.y + 10);
    try t.expectEqual(@as(?usize, 0), select.read().selected);
    try t.expect(!select.read().overlay.open);
}

test "menu submenu opens with Right, navigates independently, and closes with Left" {
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    var children = [_]Item{.{ .key = 112, .label = "Child", .checked = false }};
    var items = [_]Item{ .{ .key = 111, .label = "More", .children = &children }, .{ .key = 113, .label = "Other" } };
    const menu = app.entities.create(w.Menu, .{ .key = 110, .label = "Menu", .items = &items }, win);
    paint(win, .{menu});
    click(win, 10, 10);
    paint(win, .{menu});
    key(win, .right);
    paint(win, .{menu});
    try t.expectEqual(@as(?usize, 0), menu.read().submenu_parent);
    try t.expect(win.ui_frame.semantic_tree.find(112) != null);
    key(win, .enter);
    try t.expect(children[0].checked.?);
    try t.expect(!menu.read().overlay.open);

    click(win, 10, 10);
    paint(win, .{menu});
    key(win, .right);
    key(win, .left);
    try t.expect(menu.read().submenu_parent == null);
    try t.expect(menu.read().overlay.open);
    key(win, .escape);
}
test "popover and modal Escape restore with focus trap and inert background" {
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    const pop = app.entities.create(w.Popover, .{ .key = 30, .label = "Details" }, win);
    paint(win, .{pop});
    click(win, 10, 10);
    paint(win, .{pop});
    try t.expectEqual(w.a11y.Role.dialog, win.ui_frame.semantic_tree.find(pop.read().popupKey()).?.properties.role);
    click(win, 500, 400);
    try t.expect(!pop.read().overlay.open);
    const modal = app.entities.create(w.Modal, .{ .key = 40, .label = "Confirm" }, win);
    const background = app.entities.create(w.Button, .{ .key = 50, .label = "Background" }, win);
    paint(win, .{ modal, background });
    click(win, 10, 10);
    paint(win, .{ modal, background });
    try t.expect(win.ui_frame.semantic_tree.find(modal.read().popupKey()).?.properties.states.modal);
    key(win, .tab);
    try t.expectEqual(modal.focusHandle(null).id, win.focused.id);
    click(win, 180, 10);
    try t.expectEqual(@as(u64, 0), background.read().pressable.activations);
    try t.expect(modal.read().overlay.open);
    key(win, .escape);
    try t.expect(!modal.read().overlay.open);
    try t.expectEqual(modal.focusHandle(null).id, win.focused.id);

    // Closing a modal while its trigger is pressed cancels both the widget
    // latch and Window capture before the old portal is replaced.
    click(win, 10, 10);
    paint(win, .{ modal, background });
    modal.readMut().pressable.pressBegin();
    win.captured_mouse_region = .{ .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 } };
    try t.expect(modal.read().pressable.pressed);
    modal.readMut().close(win);
    try t.expect(!modal.read().pressable.pressed);
    try t.expect(win.captured_mouse_region == null);

    // Removing an open modal without an explicit close must not leave a
    // borrowed scope constraining the next frame.
    click(win, 10, 10);
    paint(win, .{ modal, background });
    try t.expect(win.focus_scope != null);
    modal.destroy();
    paint(win, .{background});
    try t.expect(win.focus_scope == null);
}
test "tooltip hover delay focus and passive portal regions" {
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, noop);
    const tip = app.entities.create(w.Tooltip, .{ .key = 60, .label = "Help", .tip = "Helpful text" }, win);
    paint(win, .{tip});
    const baseline = win.ui_frame.region_count;
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false, .motion = true } });
    paint(win, .{tip});
    try t.expect(!tip.read().overlay.open);
    try t.expect(tip.read().deadline != null);
    const start = tip.read().deadline.? - 500;
    tip.readMut().updateAt(win, true, start + 499);
    try t.expect(!tip.read().overlay.open);
    tip.readMut().updateAt(win, true, start + 500);
    paint(win, .{tip});
    try t.expectEqual(baseline, win.ui_frame.region_count);
    try t.expectEqual(w.a11y.Role.tooltip, win.ui_frame.semantic_tree.find(tip.read().tooltipKey()).?.properties.role);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 500, .y = 400 }, .button = .left, .pressed = false, .motion = true } });
    paint(win, .{tip});
    try t.expect(!tip.read().overlay.open);
    key(win, .tab);
    paint(win, .{tip});
    try t.expect(tip.read().deadline != null);
}
test "overlay flip shift and oversized panel" {
    const rect = w.overlay.position(.{ .x = 95, .y = 90, .w = 5, .h = 10 }, .{ .w = 40, .h = 30 }, .{ .w = 100, .h = 100 }, .bottom, 4);
    try t.expectEqual(@as(f32, 60), rect.x);
    try t.expectEqual(@as(f32, 56), rect.y);
    const large = w.overlay.position(.{}, .{ .w = 400, .h = 300 }, .{ .w = 100, .h = 80 }, .center, 4);
    try t.expectEqual(@as(f32, 100), large.w);
    try t.expectEqual(@as(f32, 0), large.x);
}
