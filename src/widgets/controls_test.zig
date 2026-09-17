const std = @import("std");
const App = @import("../app/app.zig").App;
const Window = @import("../app/window.zig").Window;
const runtime = @import("../app/runtime.zig");
const e = @import("../elements/root.zig");
const c = @import("controls.zig");
const focus = @import("focus.zig");
const RadioGroup = @import("radio_group.zig").RadioGroup;

fn paint(win: *Window, entities: anytype) void {
    const frame = &win.ui_frame;
    frame.reset(win, win.pointer_position);
    win.scene.clear();
    e.element.beginFrame(frame);
    defer e.element.endFrame();
    var root = e.div().w(300).h(500).gap(4);
    inline for (entities) |entity| root = root.child(entity.toElement());
    e.layout.layout(frame, root, .{ .w = 300, .h = 500 });
    e.painter.paint(frame, root, &win.scene);
    win.updateHitRegions();
}
fn key(win: *Window, k: @import("../platform/root.zig").event.Key, shift: bool) void {
    win.handleEvent(.{ .key = .{ .key = k, .pressed = true, .modifiers = .{ .shift = shift } } });
}
fn click(win: *Window, bounds: @import("../core/geometry.zig").Rect) void {
    const pos = @import("../core/geometry.zig").Point{ .x = bounds.x + 10, .y = bounds.y + 10 };
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = false } });
}

test "keyboard-only form traversal, scopes, disabled controls and all semantic roles" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
    }.noop);
    const button = app.entities.create(c.Button, .{ .key = 100, .label = "Submit" }, win);
    const checkbox = app.entities.create(c.Checkbox, .{ .key = 200, .label = "Accept" }, win);
    const toggle = app.entities.create(c.Switch, .{ .key = 300, .label = "Notifications" }, win);
    const slider = app.entities.create(c.Slider, .{ .key = 400, .label = "Volume" }, win);
    const progress = app.entities.create(c.Progress, .{ .key = 500, .label = "Upload", .value = 0.4 }, win);
    const radio = app.entities.create(RadioGroup, .{ .key = 600, .label = "Plan", .items = &.{ .{ .key = 601, .label = "Basic" }, .{ .key = 602, .label = "Pro" } } }, win);
    const disabled = app.entities.create(c.Button, .{ .key = 700, .label = "Unavailable", .disabled = true }, win);
    const controls = .{ button, checkbox, toggle, slider, progress, radio, disabled };
    paint(win, controls);
    const tree = &win.ui_frame.semantic_tree;
    try std.testing.expectEqual(@as(usize, 9), tree.count);
    try std.testing.expectEqual(@as(u64, 600), tree.find(601).?.parent);
    try std.testing.expectEqual(@import("../a11y/root.zig").Role.switch_control, tree.find(300).?.properties.role);
    inline for (.{ button, checkbox, toggle, slider, progress, radio }) |entity| {
        key(win, .tab, false);
        try std.testing.expectEqual(entity.focusHandle(null).id, win.focused.id);
    }
    key(win, .tab, false); // disabled is skipped, wrap
    try std.testing.expectEqual(button.focusHandle(null).id, win.focused.id);
    key(win, .tab, true);
    try std.testing.expectEqual(radio.focusHandle(null).id, win.focused.id);
    key(win, .right, false);
    try std.testing.expectEqual(@as(usize, 1), radio.read().selected);
    key(win, .right, false);
    try std.testing.expectEqual(@as(usize, 0), radio.read().selected);
    const ids = [_]u32{ checkbox.focusHandle(null).id, toggle.focusHandle(null).id };
    const token = focus.pushScope(win, &ids, true);
    click(win, tree.find(100).?.bounds); // background button cannot steal modal focus
    try std.testing.expectEqual(checkbox.focusHandle(null).id, win.focused.id);
    key(win, .tab, true); // first -> last within trap
    try std.testing.expectEqual(toggle.focusHandle(null).id, win.focused.id);
    key(win, .tab, false);
    try std.testing.expectEqual(checkbox.focusHandle(null).id, win.focused.id);
    key(win, .space, false);
    try std.testing.expect(checkbox.read().checked);
    focus.popScope(win, token);
    try std.testing.expectEqual(radio.focusHandle(null).id, win.focused.id);
    try std.testing.expect(tree.perform(300, .{ .action = .activate }, win));
    try std.testing.expect(toggle.read().checked);
    try std.testing.expect(tree.perform(400, .{ .action = .set_value, .value = 0.56 }, win));
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), slider.read().value, 0.0001);
    try std.testing.expect(tree.perform(400, .{ .action = .focus }, win));
    key(win, .end, false);
    try std.testing.expectEqual(@as(f64, 1), slider.read().value);
    key(win, .home, false);
    try std.testing.expectEqual(@as(f64, 0), slider.read().value);
    key(win, .right, false);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), slider.read().value, 0.0001);
    try std.testing.expect(!tree.perform(500, .{ .action = .activate }, win));
    try std.testing.expect(!tree.perform(700, .{ .action = .activate }, win));
    click(win, tree.find(200).?.bounds);
    try std.testing.expect(!checkbox.read().checked);
    click(win, tree.find(300).?.bounds);
    try std.testing.expect(!toggle.read().checked);
    click(win, tree.find(602).?.bounds);
    try std.testing.expectEqual(@as(usize, 1), radio.read().selected);
    try std.testing.expect(tree.perform(601, .{ .action = .activate }, win));
    try std.testing.expectEqual(@as(usize, 0), radio.read().selected);
    click(win, tree.find(400).?.bounds);
    try std.testing.expect(slider.read().value <= 0.1);
    // Reorder siblings: ids remain stable, parent/bounds/values rebuilt.
    paint(win, .{ toggle, checkbox, progress, slider, radio, button, disabled });
    try std.testing.expect(tree.find(300).?.bounds.y < tree.find(200).?.bounds.y);
    try std.testing.expectEqual(@as(f64, 0.4), tree.find(500).?.properties.value.?.current);
    // Focus ring comes from the selected theme token, not an invisible state.
    _ = focus.focusId(win, button.focusHandle(null).id);
    paint(win, controls);
    var saw_ring = false;
    for (win.ui_frame.nodes[0..win.ui_frame.node_count]) |node| if (node.stable_key == 100) {
        saw_ring = node.style.border_width == @import("theme.zig").current().focus_ring_width;
    };
    try std.testing.expect(saw_ring);
    // All candidates disabled: bounded traversal returns without looping.
    paint(win, .{disabled});
    key(win, .tab, false);
    try std.testing.expectEqual(@as(u32, 0), win.focused.id);
    key(win, .tab, true);
    try std.testing.expectEqual(@as(u32, 0), win.focused.id);
    paint(win, .{button});
    try std.testing.expect(tree.find(300) == null);
    try std.testing.expect(!tree.perform(300, .{ .action = .activate }, win));
}

test "rendered button pointer keyboard and semantic actions converge" {
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
    }.noop);
    const button = app.entities.create(c.Button, .{ .key = 10, .label = "Save" }, win);
    const frame = &win.ui_frame;
    frame.reset(win, .{});
    e.element.beginFrame(frame);
    const root = button.toElement();
    e.layout.layout(frame, root, .{ .w = 160, .h = 36 });
    e.painter.paint(frame, root, &win.scene);
    e.element.endFrame();
    try std.testing.expectEqualStrings("Save", frame.semantic_tree.find(10).?.properties.name);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try std.testing.expectEqual(@as(u64, 0), button.read().pressable.activations);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 500, .y = 10 }, .button = .left, .pressed = false } });
    try std.testing.expectEqual(@as(u64, 0), button.read().pressable.activations);
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = false } });
    win.handleEvent(.{ .key = .{ .key = .enter, .pressed = true } });
    win.handleEvent(.{ .key = .{ .key = .space, .pressed = true } });
    try std.testing.expect(frame.semantic_tree.perform(10, .{ .action = .activate }, win));
    try std.testing.expectEqual(@as(u64, 4), button.read().pressable.activations);
    button.destroy();
    try std.testing.expect(!frame.semantic_tree.perform(10, .{ .action = .activate }, win));
}
