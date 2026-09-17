const std = @import("std");
const App = @import("../app/app.zig").App;
const Window = @import("../app/window.zig").Window;
const runtime = @import("../app/runtime.zig");
const e = @import("../elements/root.zig");

const vt = @import("virtual_table.zig");
const a11y = @import("../a11y/root.zig");
const geometry = @import("../core/geometry.zig");

const ROWS = 1_000_000;
const ROW_H: f64 = 20;
const VIEW_W: f32 = 300;
const VIEW_H: f32 = 200;
const COLS = [_]vt.Column{ .{ .name = "Name", .width = 100 }, .{ .name = "Size", .width = 80 } };

const Data = struct {
    builds: usize = 0,
    sorts: usize = 0,
    last_sort: ?vt.SortRequest = null,
    activations: usize = 0,
    last_active_row: ?usize = null,
    revision: u64 = 0,
};

fn cell(ctx: ?*anyopaque, row: usize, col: usize, _: *Window) e.Element {
    const data: *Data = @ptrCast(@alignCast(ctx.?));
    data.builds += 1;
    _ = row;
    const text = switch (col) {
        0 => "row",
        else => "px",
    };
    return e.div().w(COLS[col].width).h(@floatCast(ROW_H)).flex_row().items_center().px(6)
        .child(e.text(text, .{ .size = 12 }));
}

fn rowKeyFn(_: ?*anyopaque, row: usize) u64 {
    return 0x51db0 + row;
}

fn sortChanged(ctx: ?*anyopaque, request: vt.SortRequest, win: *Window) void {
    const data: *Data = @ptrCast(@alignCast(ctx.?));
    data.sorts += 1;
    data.last_sort = request;
    data.revision += 1;
    win.requestRender();
}

fn activateRow(ctx: ?*anyopaque, row: usize, _: *Window) void {
    const data: *Data = @ptrCast(@alignCast(ctx.?));
    data.activations += 1;
    data.last_active_row = row;
}

fn makeEntities(app: *App, win: *Window, data: *Data) runtime.Entity(vt.VirtualTable) {
    return app.entities.create(vt.VirtualTable, .{
        .key = 42,
        .width = VIEW_W,
        .height = VIEW_H,
        .columns = &COLS,
        .row_count = ROWS,
        .row_height = ROW_H,
        .context = data,
        .build_cell = cell,
        .row_key = rowKeyFn,
        .sort_changed = sortChanged,
        .activate = activateRow,
    }, win);
}

fn paint(win: *Window, entities: anytype) void {
    const frame = &win.ui_frame;
    frame.reset(win, win.pointer_position);
    win.scene.clear();
    e.element.beginFrame(frame);
    defer e.element.endFrame();
    var root = e.div().w(VIEW_W).h(VIEW_H);
    inline for (entities) |entity| root = root.child(entity.toElement());
    e.layout.layout(frame, root, .{ .w = VIEW_W, .h = VIEW_H });
    e.painter.paint(frame, root, &win.scene);
    win.updateHitRegions();
}

fn key(win: *Window, k: @import("../platform/root.zig").event.Key, ctrl: bool, shift: bool) void {
    win.handleEvent(.{ .key = .{ .key = k, .pressed = true, .modifiers = .{ .ctrl = ctrl, .shift = shift } } });
}

fn clickRow(win: *Window, table: *vt.VirtualTable, row: usize, ctrl: bool, shift: bool, keep: anytype) void {
    // Row geometry: header_height then offset into the scrolled rows.
    const y = table.options.header_height + @as(f32, @floatCast(@as(f64, @floatFromInt(row)) * ROW_H - table.model.offset)) + 10;
    const pos = geometry.Point{ .x = 10, .y = y };
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = true, .modifiers = .{ .ctrl = ctrl, .shift = shift } } });
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = false, .modifiers = .{ .ctrl = ctrl, .shift = shift } } });
    paint(win, keep);
}

test "virtual table: bounded virtualization, selection, sort, activation" {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
    }.noop);
    var data = Data{};
    const table_entity = makeEntities(&app, win, &data);
    const table = table_entity.readMut();
    paint(win, .{table_entity});
    // Keyboard input reaches the focused handle; focus the table first.
    win.focused = table_entity.focusHandle(null);

    // Virtualization bounds: 1M rows build only visible + overscan rows
    // (2 cells per row).
    try t.expect(table.model.offset == 0);
    const visible_rows = @as(usize, @intFromFloat(@ceil(VIEW_H / ROW_H))) + 2;
    const visible = visible_rows * COLS.len;
    try t.expect(data.builds <= visible);
    try t.expect(data.builds > 0);

    // Header semantic nodes + first row nodes exist.
    const tree = &win.ui_frame.semantic_tree;
    try t.expect(tree.find(0x51db0 + 0) != null); // keyed row 0
    const header = tree.find(0x51db0 + 42); // root key
    _ = header;

    // Click row 0 selects it; Enter activates.
    clickRow(win, table, 0, false, false, .{table_entity});
    try t.expect(table.selection.isSelected(0));
    // Press-inside/release-inside activates (behavior semantics), so the
    // click has already activated row 0; Enter re-activates the active row.
    key(win, .enter, false, false);
    try t.expectEqual(@as(usize, 2), data.activations);
    try t.expectEqual(@as(usize, 0), data.last_active_row.?);

    // Arrow moves the active row and scrolls it into view.
    const builds_before = data.builds;
    key(win, .down, false, false);
    try t.expectEqual(@as(usize, 1), table.selection.active);
    key(win, .end, false, false);
    try t.expectEqual(ROWS - 1, table.selection.active);
    // Scrolled to the end: builder work stays bounded.
    try t.expect(data.builds - builds_before <= visible + COLS.len * 2);
    try t.expect(table.model.offset > 0);
    paint(win, .{table_entity}); // regions follow the scrolled rows

    // Shift-extends a range from the anchor.
    key(win, .up, false, true);
    try t.expect(table.selection.isSelected(ROWS - 1));
    try t.expect(table.selection.isSelected(table.selection.anchor));
    paint(win, .{table_entity});

    // Ctrl toggles the active row (ROWS-2, fully visible after the shift
    // extension scrolled it to the viewport bottom) out of the selection.
    clickRow(win, table, ROWS - 2, true, false, .{table_entity});
    try t.expect(!table.selection.isSelected(ROWS - 2));
    clickRow(win, table, ROWS - 2, true, false, .{table_entity});
    try t.expect(table.selection.isSelected(ROWS - 2));

    // Ctrl+A selects everything with ONE bounded range.
    key(win, .a, true, false);
    try t.expectEqual(@as(usize, 1), table.selection.count);
    try t.expect(table.selection.isSelected(0));
    try t.expect(table.selection.isSelected(ROWS - 1));

    // Header sort click reports to the host; second click reverses.
    const header_top = win.ui_frame.regions[0];
    _ = header_top;
    // Click the first column header (top-left of the table).
    const pos = geometry.Point{ .x = 10, .y = 10 };
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = false } });
    paint(win, .{table_entity});
    try t.expectEqual(@as(usize, 1), data.sorts);
    try t.expectEqual(@as(usize, 0), data.last_sort.?.column);
    try t.expect(data.last_sort.?.ascending);
    _ = table_entity.readMut();
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = true } });
    win.handleEvent(.{ .mouse = .{ .pos = pos, .button = .left, .pressed = false } });
    paint(win, .{table_entity});
    try t.expectEqual(@as(usize, 2), data.sorts);
    try t.expect(!data.last_sort.?.ascending);

    // Resize re-clamps scroll and keeps virtualization bounded.
    table_entity.readMut().updateOptions(.{
        .key = 42,
        .width = VIEW_W,
        .height = 100,
        .columns = &COLS,
        .row_count = ROWS,
        .row_height = ROW_H,
        .context = &data,
        .build_cell = cell,
        .row_key = rowKeyFn,
        .sort_changed = sortChanged,
        .activate = activateRow,
    });
    const before_resize = data.builds;
    paint(win, .{table_entity});
    try t.expect(table.model.offset <= table.model.maxOffset());
    // 100px viewport: ~5 visible rows + 2 overscan each side, 2 cells per row.
    try t.expect(data.builds - before_resize <= 9 * COLS.len);

    // A11y: table role + selected/active row states.
    const root_node = win.ui_frame.semantic_tree.find(42) orelse return error.TestUnexpectedResult;
    try t.expectEqual(a11y.Role.table, root_node.properties.role);
}
