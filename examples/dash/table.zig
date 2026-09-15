//! Tabs and the document table below the chart.

const zui = @import("zui");

const data = @import("data.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

const Dash = @import("main.zig").Dash;
const Tab = @import("main.zig").Tab;

pub fn render(dash: *Dash, cx: *zui.Context(Dash)) zui.Element {
    var table = zui.div().flex_col().rounded_lg()
        .border_1().border_color(theme.border)
        .child(headerRow(dash, cx));

    for (&dash.rows, 0..) |*row, index| {
        if (!dash.tab.matches(row)) continue;
        table = table.child(bodyRow(dash, index, row, cx));
    }

    return zui.div().flex_col().gap(16)
        .child(toolbar(dash, cx))
        .child(table);
}

fn toolbar(dash: *Dash, cx: *zui.Context(Dash)) zui.Element {
    var tabs = zui.div().flex_row().items_center().p(2).gap(2).rounded_lg().bg(theme.table_head);
    inline for (.{ Tab.outline, Tab.past_performance, Tab.key_personnel, Tab.focus_documents }) |value| {
        tabs = tabs.child(tabButton(dash, value, cx));
    }
    return zui.div().flex_row().items_center().justify_between()
        .child(tabs)
        .child(zui.div().flex_row().items_center().gap(8)
            .child(outlineButton(icons.layout_columns, "Customize Columns", true))
            .child(outlineButton(icons.plus, "Add Section", false)));
}

fn tabButton(dash: *Dash, value: Tab, cx: *zui.Context(Dash)) zui.Element {
    const active = dash.tab == value;
    var item = zui.div().flex_row().items_center().gap(6).h(32).px(12).rounded_lg().cursor_pointer()
        .on_click(cx.listenerWith(Tab, Dash, setTab, value));
    item = if (active) item.bg(theme.tab_active) else item.hover_bg(theme.hover);
    item = item.child(ui.label(value.label(), 14, if (active) theme.text else theme.muted));
    if (value != .outline) {
        item = item.child(zui.div().flex_row().items_center().justify_center().h(18).px(5).rounded_full().bg(theme.card_border)
            .child(ui.label(countLabel(value), 11, theme.text)));
    }
    return item;
}

const std = @import("std");

/// The three badge counts are static, so they are formatted once at comptime.
const TAB_COUNT_LABELS = [4][]const u8{
    "",
    std.fmt.comptimePrint("{d}", .{Tab.past_performance.count()}),
    std.fmt.comptimePrint("{d}", .{Tab.key_personnel.count()}),
    std.fmt.comptimePrint("{d}", .{Tab.focus_documents.count()}),
};

fn countLabel(value: Tab) []const u8 {
    return TAB_COUNT_LABELS[@intFromEnum(value)];
}

fn outlineButton(glyph: []const u8, name: []const u8, caret: bool) zui.Element {
    var button = zui.div().flex_row().items_center().gap(6).h(32).px(10).rounded_lg()
        .border_1().border_color(theme.card_border).bg(theme.card)
        .cursor_pointer().hover_bg(theme.hover)
        .child(ui.icon(glyph, 14, theme.body))
        .child(ui.label(name, 14, theme.body));
    if (caret) button = button.child(ui.icon(icons.chevron_down, 14, theme.muted));
    return button;
}

fn headerRow(dash: *Dash, cx: *zui.Context(Dash)) zui.Element {
    _ = dash;
    return zui.div().flex_row().items_center().h(40).px(16).gap(20).bg(theme.table_head)
        .child(zui.div().w(16))
        .child(zui.div().size(16).border_1().border_color(theme.card_border).bg(theme.panel)
            .cursor_pointer()
            .on_click(cx.listener(Dash, toggleAll)))
        .child(zui.div().flex_1().child(ui.strong("Header", 14, theme.text)))
        .child(zui.div().w(210).child(ui.strong("Section Type", 14, theme.text)))
        .child(zui.div().w(180).child(ui.strong("Status", 14, theme.text)))
        .child(zui.div().w(90).child(ui.strong("Target", 14, theme.text)))
        .child(zui.div().w(70).child(ui.strong("Limit", 14, theme.text)))
        .child(zui.div().w(160).child(ui.strong("Reviewer", 14, theme.text)))
        .child(zui.div().w(16));
}

fn bodyRow(dash: *Dash, index: usize, row: *const data.Row, cx: *zui.Context(Dash)) zui.Element {
    const dragging = dash.drag_index != null and dash.drag_index.? == index and dash.drag_active;
    var checkbox = zui.div().size(16).border_1()
        .border_color(if (dash.checked[index]) theme.primary else theme.card_border)
        .bg(if (dash.checked[index]) theme.primary else theme.panel)
        .cursor_pointer()
        .on_click(cx.listenerWith(usize, Dash, toggleRow, index));
    if (dash.checked[index]) {
        checkbox = checkbox.child(ui.icon(icons.circle_check_filled, 11, theme.panel));
    }

    const grip = zui.div().flex_row().items_center().justify_center().size(20).rounded_lg()
        .cursor_pointer()
        .hover_bg(theme.hover)
        .on_mouse_down(cx.listenerWith(usize, Dash, beginRowDrag, index))
        .on_mouse_move(cx.listenerWith(usize, Dash, moveRowDrag, index))
        .on_mouse_up(cx.listener(Dash, endRowDrag))
        .child(ui.icon(icons.grip_vertical, 16, theme.faint));

    var row_el = zui.div().flex_row().items_center().h(52).px(16).gap(20)
        .border_b_1().border_color(theme.border);
    if (dragging) row_el = row_el.opacity(0.35);
    row_el = row_el
        .on_mouse_down(cx.listenerWith(usize, Dash, beginRowDrag, index))
        .on_mouse_move(cx.listenerWith(usize, Dash, moveRowDrag, index))
        .on_mouse_up(cx.listener(Dash, endRowDrag));
    return row_el.child(grip)
        .child(checkbox)
        .child(zui.div().flex_1().child(ui.strong(row.header, 14, theme.text)))
        .child(zui.div().w(210).child(sectionBadge(row.section_type)))
        .child(zui.div().w(180).child(statusBadge(dash, row.status)))
        .child(zui.div().w(90).child(ui.label(row.target, 14, theme.text)))
        .child(zui.div().w(70).child(ui.label(row.limit, 14, theme.text)))
        .child(zui.div().w(160).child(ui.label(row.reviewer, 14, theme.text)))
        .child(ui.icon(icons.dots_vertical, 16, theme.muted));
}

fn sectionBadge(name: []const u8) zui.Element {
    return zui.div().flex_row().items_center().h(22).px(8).rounded_full()
        .border_1().border_color(theme.card_border)
        .child(ui.label(name, 12, theme.body));
}

fn statusBadge(dash: *Dash, status: data.Status) zui.Element {
    return zui.div().flex_row().items_center().gap(6).h(24).px(8).rounded_full()
        .border_1().border_color(theme.card_border)
        .child(switch (status) {
            .done => ui.icon(icons.circle_check_filled, 14, theme.green),
            .in_process => zui.svg(dash.spinner()).size(14).tint(theme.muted),
        })
        .child(ui.label(switch (status) {
            .done => "Done",
            .in_process => "In Process",
        }, 14, theme.body));
}

fn beginRowDrag(dash: *Dash, index: usize, window: *zui.Window, _: *zui.Context(Dash)) void {
    dash.drag_index = index;
    dash.drag_active = false;
    const pointer = window.pointerPosition();
    dash.drag_x = pointer.x;
    dash.drag_y = pointer.y;
    dash.drag_press_y = pointer.y;
}

fn moveRowDrag(dash: *Dash, index: usize, window: *zui.Window, cx: *zui.Context(Dash)) void {
    const drag_index = dash.drag_index orelse return;
    const pointer = window.pointerPosition();
    dash.drag_x = pointer.x;
    dash.drag_y = pointer.y;
    // The drag source also gets this callback (pointer capture); it only
    // tracks the ghost. Reordering happens from the hovered row's pass.
    if (window.motionFromCapture()) return;
    if (!dash.drag_active) {
        if (@abs(pointer.y - dash.drag_press_y) < 4) return;
        dash.drag_active = true;
    }
    if (index == drag_index) return;
    // Live reorder: the dragged row takes the hovered row's slot.
    dash.moveRow(drag_index, index);
    dash.drag_index = index;
    cx.notify();
}

fn endRowDrag(dash: *Dash, _: *zui.Window, cx: *zui.Context(Dash)) void {
    if (dash.drag_index == null and !dash.drag_active) return;
    dash.resetDrag();
    cx.notify();
}

fn setTab(dash: *Dash, value: Tab, cx: *zui.Context(Dash)) void {
    dash.tab = value;
    cx.notify();
}

fn toggleRow(dash: *Dash, index: usize, cx: *zui.Context(Dash)) void {
    dash.checked[index] = !dash.checked[index];
    cx.notify();
}

fn toggleAll(dash: *Dash, _: *zui.Window, cx: *zui.Context(Dash)) void {
    var all = true;
    for (&dash.rows, 0..) |*row, index| {
        if (dash.tab.matches(row) and !dash.checked[index]) all = false;
    }
    const target = !all;
    for (&dash.rows, 0..) |*row, index| {
        if (dash.tab.matches(row)) dash.checked[index] = target;
    }
    cx.notify();
}
