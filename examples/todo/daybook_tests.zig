//! Behavioral and accessibility tests for the Daybook example.
const std = @import("std");
const zui = @import("zui");
const daybook = @import("daybook.zig");

// ---------------------------------------------------------------------------
// Pure-model tests — no window needed, same as gpui would encourage.
// ---------------------------------------------------------------------------

test "toggle / filter / clear are pure" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    // Note: ideal test harness gives us a headless Context for free,
    // so entities + listeners can be driven without opening a window.
    var harness = try zui.TestHarness.init(arena.allocator());
    defer harness.deinit();

    const view = harness.new(daybook.TodoApp, .{});
    try view.updateWith("buy milk", daybook.TodoApp.add);
    try view.updateWith("write zig", daybook.TodoApp.add);
    try t.expectEqual(@as(usize, 2), view.read().todos.items.len);

    const id = view.read().todos.items[0].id;
    view.updateWith(id, daybook.TodoApp.toggle);
    try t.expect(view.read().todos.items[0].done);

    view.updateWith(.done, daybook.TodoApp.setFilter);
    try t.expect(!view.read().isVisible(view.read().todos.items[1]));

    view.update(daybook.TodoApp.clearCompleted);
    try t.expectEqual(@as(usize, 1), view.read().todos.items.len);
}

test "pagination clamps at list ends and resets on filtering" {
    var harness = try zui.TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const view = harness.new(daybook.TodoApp, .{});
    for (0..12) |_| try view.updateWith("Task", daybook.TodoApp.add);
    view.update(daybook.TodoApp.nextPage);
    try std.testing.expectEqual(@as(usize, 1), view.read().page);
    view.update(daybook.TodoApp.nextPage);
    view.update(daybook.TodoApp.nextPage);
    try std.testing.expectEqual(@as(usize, 2), view.read().page);
    view.updateWith(.active, daybook.TodoApp.setFilter);
    try std.testing.expectEqual(@as(usize, 0), view.read().page);
    view.update(daybook.TodoApp.previousPage);
    try std.testing.expectEqual(@as(usize, 0), view.read().page);
}

// ---------------------------------------------------------------------------
// Accessibility selftests (gap report §5.1 exit gate, headless): the shipped
// demo publishes an annotated, actionable semantic tree — composer as
// text_input, rows as listitem/checkbox with checked state, buttons with the
// activate action — and Tree.perform toggles a row. The bridge snapshot test
// additionally proves the root-attachment invariant the AccessKit factory
// relies on (top-level nodes carry parent 0).
// ---------------------------------------------------------------------------

// Accessibility bridge and semantic-tree coverage.
test "annotated demo publishes actionable semantics" {
    const t = std.testing;
    var fixture = try daybook.a11yFixture();
    defer fixture.app.deinit();
    const win = fixture.win;
    const view = fixture.view;
    const tree = &win.ui_frame.semantic_tree;

    // Composer: text_input role, top-level root for the bridge.
    const composer = tree.find(daybook.a11y_key.composer) orelse return error.MissingComposer;
    try t.expectEqual(zui.a11y.Role.text_input, composer.properties.role);
    try t.expectEqual(@as(u64, 0), composer.parent);
    try t.expectEqualStrings("New task", composer.properties.name);

    // List with listitem rows; checkboxes carry checked state and sit under
    // their row, deletes are buttons under their row.
    const list = tree.find(daybook.a11y_key.list) orelse return error.MissingList;
    try t.expectEqual(zui.a11y.Role.list, list.properties.role);
    // Pagination/virtualization publishes the current page's rows to the
    // semantic tree; off-page rows are intentionally not present until the
    // user navigates to that page.
    var visible_rows: usize = 0;
    for (view.read().todos.items) |todo| {
        const row = tree.find(daybook.a11y_key.row(todo.id)) orelse continue;
        visible_rows += 1;
        try t.expectEqual(zui.a11y.Role.listitem, row.properties.role);
        try t.expectEqual(daybook.a11y_key.list, row.parent);
        try t.expectEqualStrings(todo.title.slice(), row.properties.name);
        const check_node = tree.find(daybook.a11y_key.check(todo.id)) orelse return error.MissingCheck;
        try t.expectEqual(zui.a11y.Role.checkbox, check_node.properties.role);
        try t.expectEqual(daybook.a11y_key.row(todo.id), check_node.parent);
        try t.expectEqual(todo.done, check_node.properties.states.checked orelse false);
        try t.expect(check_node.properties.actions.activate);
        const del = tree.find(daybook.a11y_key.del(todo.id)) orelse return error.MissingDel;
        try t.expectEqual(zui.a11y.Role.button, del.properties.role);
        try t.expectEqual(daybook.a11y_key.row(todo.id), del.parent);
        try t.expect(del.properties.actions.activate);
    }
    try t.expectEqual(@as(usize, @min(view.read().todos.items.len, 4)), visible_rows);

    // Static buttons: button role, activate action, top-level roots.
    for ([_]u64{ daybook.a11y_key.add, daybook.a11y_key.clear, daybook.a11y_key.filter_all, daybook.a11y_key.filter_active, daybook.a11y_key.filter_done, daybook.a11y_key.win_min, daybook.a11y_key.win_max, daybook.a11y_key.win_close }) |key| {
        const node = tree.find(key) orelse return error.MissingButton;
        try t.expectEqual(zui.a11y.Role.button, node.properties.role);
        try t.expect(node.properties.actions.activate);
        try t.expectEqual(@as(u64, 0), node.parent);
    }

    // Root-attachment invariant (what accesskit.zig updateFactory attaches
    // under node 0): every parent is 0 or another live node key.
    for (tree.nodes[0..tree.count]) |*node| {
        if (node.parent == 0) continue;
        try t.expect(tree.find(node.parent) != null);
    }
    try t.expect(tree.count > 10);

    // Semantic activation toggles the row and the next frame reflects it.
    const first = view.read().todos.items[0].id;
    const before_delete = view.read().todos.items.len;
    const was = view.read().todos.items[0].done;
    try t.expect(tree.perform(daybook.a11y_key.check(first), .{ .action = .activate }, win));
    try t.expect(view.read().todos.items[0].done != was);
    _ = fixture.app.step();
    const refreshed = tree.find(daybook.a11y_key.check(first)) orelse return error.MissingCheck;
    try t.expectEqual(!was, refreshed.properties.states.checked orelse true);

    // Semantic focus reaches a control; Space on the focused control acts.
    try t.expect(tree.perform(daybook.a11y_key.del(first), .{ .action = .focus }, win));
    try t.expectEqual(daybook.a11y_key.del(first), @as(u64, win.focused.id));
    win.handleEvent(.{ .key = .{ .key = .space, .pressed = true } });
    win.handleEvent(.{ .key = .{ .key = .space, .pressed = false } });
    try t.expectEqual(before_delete - 1, view.read().todos.items.len);
}

test "bridge snapshot carries annotated roots" {
    const t = std.testing;
    if (!zui.a11y.accesskit.enabled) return error.SkipZigTest;
    var fixture = try daybook.a11yFixture();
    defer fixture.app.deinit();
    const win = fixture.win;
    const view = fixture.view;

    var bridge = zui.a11y.accesskit.Bridge.init();
    const alloc = win.allocator orelse t.allocator;
    defer bridge.deinit(alloc);
    // Focus the composer so the snapshot records a focused key.
    win.focused = view.read().input.focusHandle(null);
    bridge.publish(win);

    try t.expect(bridge.snapshot.len > 0);
    var saw_input = false;
    var saw_button = false;
    var saw_check = false;
    var saw_item = false;
    var saw_list = false;
    var top_level: usize = 0;
    for (bridge.snapshot) |*node| {
        if (node.parent == 0) top_level += 1 else {
            var parent_found = false;
            for (bridge.snapshot) |*other| if (other.key == node.parent) {
                parent_found = true;
                break;
            };
            try t.expect(parent_found);
        }
        switch (node.role) {
            .text_input => saw_input = true,
            .button => saw_button = true,
            .checkbox => saw_check = true,
            .listitem => saw_item = true,
            .list => saw_list = true,
            else => {},
        }
    }
    try t.expect(saw_input and saw_button and saw_check and saw_item and saw_list);
    try t.expect(top_level > 0);
    try t.expectEqual(daybook.a11y_key.composer, bridge.focused_key);
}
