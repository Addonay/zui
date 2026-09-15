//! Simple pages for every sidebar destination.

const std = @import("std");
const zui = @import("zui");

const cards = @import("cards.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

const Dash = @import("main.zig").Dash;
const Page = @import("main.zig").Page;

const Item = struct {
    name: []const u8,
    meta: []const u8,
    done: bool,
    glyph: []const u8,
};

const LIFECYCLE = [_]Item{
    .{ .name = "Ideation", .meta = "8 documents", .done = true, .glyph = icons.list_details },
    .{ .name = "Design review", .meta = "4 documents", .done = true, .glyph = icons.list_details },
    .{ .name = "Build", .meta = "12 documents", .done = false, .glyph = icons.list_details },
    .{ .name = "QA", .meta = "6 documents", .done = false, .glyph = icons.list_details },
    .{ .name = "Launch", .meta = "2 documents", .done = false, .glyph = icons.list_details },
};

const PROJECTS = [_]Item{
    .{ .name = "Apollo Dashboard", .meta = "Owner: Eddie Lake", .done = false, .glyph = icons.folder },
    .{ .name = "Borealis API", .meta = "Owner: Jamik Tashpulatov", .done = true, .glyph = icons.folder },
    .{ .name = "Cascade Editor", .meta = "Owner: Sarah Chen", .done = true, .glyph = icons.folder },
    .{ .name = "Dune Analytics", .meta = "Owner: Raj Patel", .done = false, .glyph = icons.folder },
};

const LIBRARY = [_]Item{
    .{ .name = "Visitors (daily)", .meta = "91 rows · 2 series", .done = true, .glyph = icons.database },
    .{ .name = "Document outline", .meta = "68 rows · 7 columns", .done = true, .glyph = icons.database },
    .{ .name = "Customer accounts", .meta = "45,678 rows", .done = false, .glyph = icons.database },
    .{ .name = "Revenue by plan", .meta = "12 rows", .done = true, .glyph = icons.database },
};

const REPORTS = [_]Item{
    .{ .name = "Weekly traffic digest", .meta = "Generated 2 days ago", .done = true, .glyph = icons.report },
    .{ .name = "Monthly revenue", .meta = "Generated last week", .done = true, .glyph = icons.report },
    .{ .name = "Retention cohort", .meta = "Generating…", .done = false, .glyph = icons.report },
};

const WORD_ASSISTANT = [_]Item{
    .{ .name = "Executive summary", .meta = "Edited 3 hours ago", .done = true, .glyph = icons.file_word },
    .{ .name = "Technical approach", .meta = "Edited yesterday", .done = true, .glyph = icons.file_word },
    .{ .name = "Design brief", .meta = "Draft", .done = false, .glyph = icons.file_word },
};

const MORE = [_]Item{
    .{ .name = "Integrations", .meta = "12 connected apps", .done = true, .glyph = icons.help },
    .{ .name = "Audit log", .meta = "1,204 events", .done = true, .glyph = icons.help },
    .{ .name = "API keys", .meta = "3 active keys", .done = false, .glyph = icons.help },
};

const TEAM = [_]struct { name: []const u8, role: []const u8, email: []const u8 }{
    .{ .name = "Eddie Lake", .role = "Product", .email = "eddie@example.com" },
    .{ .name = "Jamik Tashpulatov", .role = "Engineering", .email = "jamik@example.com" },
    .{ .name = "Sarah Chen", .role = "Design", .email = "sarah@example.com" },
    .{ .name = "Raj Patel", .role = "Data", .email = "raj@example.com" },
};

const FAQ = [_]struct { question: []const u8, answer: []const u8 }{
    .{ .question = "How do I invite a teammate?", .answer = "Open Team in the sidebar, then use the invite action on the member list." },
    .{ .question = "Where do exports land?", .answer = "Reports keeps every generated export with its creation date." },
    .{ .question = "Can I change the reporting window?", .answer = "Yes — the Total Visitors card switches between 3 months, 30 and 7 days." },
    .{ .question = "Is my data live?", .answer = "The dashboard is a demo dataset, but every control is wired end to end." },
};

pub fn render(dash: *Dash, body_width: f32, cx: *zui.Context(Dash)) zui.Element {
    const body = switch (dash.page) {
        .dashboard => zui.div(),
        .analytics => zui.div().flex_col().gap(24).child(cards.metrics(body_width)).child(cards.chartCard(dash, body_width, cx)),
        .lifecycle => listPage(&LIFECYCLE),
        .projects => listPage(&PROJECTS),
        .data_library => listPage(&LIBRARY),
        .reports => listPage(&REPORTS),
        .word_assistant => listPage(&WORD_ASSISTANT),
        .more => listPage(&MORE),
        .team => teamPage(),
        .settings => settingsPage(dash, cx),
        .get_help => faqPage(),
        .search => searchPage(dash, cx),
    };

    return zui.div().flex_col().gap(24)
        .child(zui.div().flex_col().gap(4)
            .child(ui.strong(dash.page.title(), 24, theme.text))
            .child(ui.label(dash.page.description(), 14, theme.muted)))
        .child(body);
}

fn listPage(items: []const Item) zui.Element {
    var list = zui.div().flex_col().rounded_xl().border_1().border_color(theme.border);
    for (items) |item| {
        var row = zui.div().flex_row().items_center().gap(14).h(64).px(20)
            .border_b_1().border_color(theme.border)
            .child(ui.icon(item.glyph, 18, theme.nav_text))
            .child(zui.div().flex_col().flex_1().gap(2)
                .child(ui.strong(item.name, 14, theme.text))
                .child(ui.label(item.meta, 13, theme.muted)));
        row = if (item.done)
            row.child(zui.div().flex_row().items_center().gap(6).h(24).px(8).rounded_full().border_1().border_color(theme.card_border)
                .child(ui.icon(icons.circle_check_filled, 14, theme.green))
                .child(ui.label("Done", 13, theme.body)))
        else
            row.child(zui.div().flex_row().items_center().gap(6).h(24).px(8).rounded_full().border_1().border_color(theme.card_border)
                .child(ui.icon(icons.loader, 14, theme.muted))
                .child(ui.label("In Process", 13, theme.body)));
        list = list.child(row);
    }
    return list;
}

fn teamPage() zui.Element {
    var grid = zui.div().flex_row().gap(16);
    for (&TEAM) |*member| {
        grid = grid.child(zui.div().flex_row().items_center().gap(14).w(360).p(20).rounded_xl()
            .bg(theme.card_metric).border_1().border_color(theme.card_border)
            .child(zui.div().size(40).rounded_full().bg(theme.card_border)
                .flex_row().items_center().justify_center()
                .child(ui.strong(initials(member.name), 14, theme.text)))
            .child(zui.div().flex_col().gap(2)
                .child(ui.strong(member.name, 14, theme.text))
                .child(ui.label(member.role, 13, theme.muted))
                .child(ui.label(member.email, 13, theme.faint))));
    }
    return grid;
}

fn initials(name: []const u8) []const u8 {
    // Two initials from a "First Last" name, returned as a view into the name.
    var first: usize = 0;
    while (first < name.len and name[first] == ' ') first += 1;
    var last_start = name.len;
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == ' ' and i + 1 < name.len) {
            last_start = i + 1;
            break;
        }
    }
    if (last_start < name.len and last_start > first) return name[first .. first + 1];
    return name[first .. @min(first + 1, name.len)];
}

fn settingsPage(dash: *Dash, cx: *zui.Context(Dash)) zui.Element {
    const rows = [_]struct { title: []const u8, hint: []const u8 }{
        .{ .title = "Notifications", .hint = "Weekly digest and mentions" },
        .{ .title = "Dark appearance", .hint = "Follow the dashboard theme" },
        .{ .title = "Compact tables", .hint = "Tighter rows in every table" },
    };
    var list = zui.div().flex_col().rounded_xl().border_1().border_color(theme.border);
    for (&rows, 0..) |*row, index| {
        list = list.child(zui.div().flex_row().items_center().justify_between().h(64).px(20)
            .border_b_1().border_color(theme.border)
            .child(zui.div().flex_col().gap(2)
                .child(ui.strong(row.title, 14, theme.text))
                .child(ui.label(row.hint, 13, theme.muted)))
            .child(switchTrack(dash, index, cx)));
    }
    return list;
}

fn switchTrack(dash: *Dash, index: usize, cx: *zui.Context(Dash)) zui.Element {
    const on = dash.settings[index];
    return zui.div().flex_row().items_center().w(36).h(20).rounded_full().p(2).cursor_pointer()
        .bg(if (on) theme.primary else theme.card_border)
        .on_click(cx.listenerWith(usize, Dash, toggleSetting, index))
        .child(zui.when(on, zui.spacer()))
        .child(zui.div().size(16).rounded_full().bg(if (on) theme.primary_foreground else theme.muted))
        .child(zui.when(!on, zui.spacer()));
}

fn toggleSetting(dash: *Dash, index: usize, _: *zui.Context(Dash)) void {
    dash.settings[index] = !dash.settings[index];
}

fn faqPage() zui.Element {
    var list = zui.div().flex_col().gap(12);
    for (&FAQ) |*entry| {
        list = list.child(zui.div().flex_col().gap(6).p(20).rounded_xl()
            .bg(theme.card_metric).border_1().border_color(theme.card_border)
            .child(ui.strong(entry.question, 14, theme.text))
            .child(ui.label(entry.answer, 14, theme.muted)));
    }
    return list;
}

fn searchPage(dash: *Dash, cx: *zui.Context(Dash)) zui.Element {
    const query = dash.search.read().trimmedText();
    var list = zui.div().flex_col().rounded_xl().border_1().border_color(theme.border);
    var results: usize = 0;
    inline for (.{
        Page.dashboard,    Page.lifecycle,      Page.analytics,
        Page.projects,     Page.team,           Page.data_library,
        Page.reports,      Page.word_assistant, Page.more,
        Page.settings,     Page.get_help,
    }) |page| {
        if (query.len == 0 or containsIgnoreCase(page.title(), query) or containsIgnoreCase(page.description(), query)) {
            results += 1;
            list = list.child(zui.div().flex_row().items_center().gap(14).h(56).px(20)
                .cursor_pointer().hover_bg(theme.hover)
                .on_click(cx.listenerWith(Page, Dash, openPage, page))
                .child(ui.icon(icons.search, 16, theme.muted))
                .child(ui.strong(page.title(), 14, theme.text))
                .child(ui.label(page.description(), 13, theme.muted)));
        }
    }
    return zui.div().flex_col().gap(16)
        .child(zui.div().w(420).child(dash.search.toElement()))
        .child(if (results == 0)
            zui.div().p(20).child(ui.label("No matches. Try “visitors”, “team” or “reports”.", 14, theme.muted))
        else
            list);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (haystack[i..][0..needle.len], needle) |h, n| {
            if (std.ascii.toLower(h) != std.ascii.toLower(n)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn openPage(dash: *Dash, page: Page, cx: *zui.Context(Dash)) void {
    dash.page = page;
    dash.active_nav = page.navIndex();
    cx.notify();
}
