//! The "Documents" header bar at the top of the inset panel.

const zui = @import("zui");

const icons = @import("icons.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

const Dash = @import("main.zig").Dash;

pub fn render(dash: *Dash, title: []const u8, cx: *zui.Context(Dash)) zui.Element {
    _ = dash;
    return zui.div().flex_row().items_center().h(48).px(16).gap(12)
        .border_b_1().border_color(theme.border)
        .child(zui.div().size(28).flex_row().items_center().justify_center().rounded_lg()
            .cursor_pointer().hover_bg(theme.hover)
            .on_click(cx.listener(Dash, toggleSidebar))
            .child(ui.icon(icons.layout_sidebar, 17, theme.muted)))
        .child(zui.div().w(1).h(16).bg(theme.border))
        .child(ui.strong(title, 16, theme.text))
        .child(zui.spacer())
        .child(zui.div().flex_row().items_center().h(32).px(12).rounded_lg()
            .cursor_pointer().hover_bg(theme.hover)
            .child(ui.label("GitHub", 14, theme.text)));
}

fn toggleSidebar(dash: *Dash, _: *zui.Window, cx: *zui.Context(Dash)) void {
    dash.sidebar_open = !dash.sidebar_open;
    cx.notify();
}
