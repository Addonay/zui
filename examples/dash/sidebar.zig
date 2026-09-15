//! Left navigation sidebar, mirroring the `dashboard-01` block.

const zui = @import("zui");

const icons = @import("icons.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

const Dash = @import("main.zig").Dash;
const Page = @import("main.zig").Page;

pub fn render(dash: *Dash, height: f32, cx: *zui.Context(Dash)) zui.Element {
    var side = zui.div().flex_col().w(288).h(height).p(16).bg(theme.page);

    // Brand.
    side = side.child(zui.div().flex_row().items_center().h(48).px(8).gap(10)
        .child(ui.icon(icons.inner_shadow_top, 20, theme.text))
        .child(ui.strong("Acme Inc.", 16, theme.text)));

    // Quick create + mail.
    side = side.child(zui.div().flex_row().items_center().gap(8).pt(8)
        .child(zui.div().flex_1().flex_row().items_center().h(32).px(8).gap(10).rounded_lg().bg(theme.primary).cursor_pointer()
            .hover_bg(theme.white)
            .on_click(cx.listener(Dash, quickCreate))
            .child(ui.icon(icons.circle_plus_filled, 18, theme.primary_foreground))
            .child(ui.strong("Quick Create", 14, theme.primary_foreground)))
        .child(zui.div().size(32).flex_row().items_center().justify_center().rounded_lg().bg(theme.card_metric).border_1().border_color(theme.card_border)
            .cursor_pointer().hover_bg(theme.hover)
            .on_click(cx.listener(Dash, inbox))
            .child(ui.icon(icons.mail, 16, theme.body))));

    // Primary navigation.
    var primary = zui.div().flex_col().gap(4).pt(8);
    primary = primary.child(navItem(dash, 0, "Dashboard", icons.dashboard, cx));
    primary = primary.child(navItem(dash, 1, "Lifecycle", icons.list_details, cx));
    primary = primary.child(navItem(dash, 2, "Analytics", icons.chart_bar, cx));
    primary = primary.child(navItem(dash, 3, "Projects", icons.folder, cx));
    primary = primary.child(navItem(dash, 4, "Team", icons.users, cx));
    side = side.child(primary);

    // Documents group.
    var documents = zui.div().flex_col()
        .child(zui.div().p(8).pt(24).pl(12).child(ui.label("Documents", 13, theme.muted)));
    var docs_menu = zui.div().flex_col().gap(4);
    docs_menu = docs_menu.child(navItem(dash, 5, "Data Library", icons.database, cx));
    docs_menu = docs_menu.child(navItem(dash, 6, "Reports", icons.report, cx));
    docs_menu = docs_menu.child(navItem(dash, 7, "Word Assistant", icons.file_word, cx));
    docs_menu = docs_menu.child(navItem(dash, 8, "More", icons.dots, cx));
    side = side.child(documents.child(docs_menu));

    side = side.child(zui.spacer());

    // Secondary navigation.
    var secondary = zui.div().flex_col().gap(4);
    secondary = secondary.child(navItem(dash, 9, "Settings", icons.settings, cx));
    secondary = secondary.child(navItem(dash, 10, "Get Help", icons.help, cx));
    secondary = secondary.child(navItem(dash, 11, "Search", icons.search, cx));
    side = side.child(secondary);

    // Account footer.
    side = side.child(zui.div().flex_row().items_center().gap(10).pt(12)
        .child(zui.img(icons.avatar).size(32).rounded_lg().object_fit(.fill))
        .child(zui.div().flex_col().flex_1().gap(1)
            .child(ui.strong("shadcn", 14, theme.text))
            .child(ui.label("m@example.com", 12, theme.muted)))
        .child(ui.icon(icons.dots_vertical, 16, theme.muted)));

    return side;
}

fn navItem(dash: *Dash, index: usize, name: []const u8, glyph: []const u8, cx: *zui.Context(Dash)) zui.Element {
    const active = dash.active_nav == index;
    var item = zui.div().flex_row().items_center().gap(12).h(32).px(12).rounded_lg().cursor_pointer()
        .on_click(cx.listenerWith(usize, Dash, navClick, index));
    item = if (active) item.bg(theme.hover) else item.hover_bg(theme.hover);
    return item
        .child(ui.icon(glyph, 16, if (active) theme.text else theme.nav_text))
        .child(ui.label(name, 14, if (active) theme.text else theme.nav_text));
}

fn navClick(dash: *Dash, index: usize, cx: *zui.Context(Dash)) void {
    dash.active_nav = index;
    dash.page = Page.fromNav(index);
    cx.notify();
}

fn quickCreate(_: *Dash, _: *zui.Window, _: *zui.Context(Dash)) void {}

fn inbox(_: *Dash, _: *zui.Window, _: *zui.Context(Dash)) void {}
