//! Dash: a shadcn-style dark analytics dashboard built with ZUI.
//!
//! Run it with `zig build run-dash`.
//! Headless snapshot: `ZUI_SNAPSHOT=/tmp/dash.ppm zig build run-dash`
//! (size via `ZUI_SNAPSHOT_WIDTH` / `ZUI_SNAPSHOT_HEIGHT`).

const std = @import("std");
const zui = @import("zui");

const App = zui.App;
const Context = zui.Context;
const Window = zui.Window;
const Element = zui.Element;
const Entity = zui.Entity;

const cards = @import("cards.zig");
const chart = @import("chart.zig");
const data = @import("data.zig");
const header = @import("header.zig");
const icons = @import("icons.zig");
const pages = @import("pages.zig");
const sidebar = @import("sidebar.zig");
const table = @import("table.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

pub const Range = enum {
    months90,
    days30,
    days7,

    pub fn label(self: Range) []const u8 {
        return switch (self) {
            .months90 => "Last 3 months",
            .days30 => "Last 30 days",
            .days7 => "Last 7 days",
        };
    }

    pub fn description(self: Range) []const u8 {
        return switch (self) {
            .months90 => "Total for the last 3 months",
            .days30 => "Total for the last 30 days",
            .days7 => "Total for the last 7 days",
        };
    }

    /// The trailing slice of the full series this window covers.
    pub fn days(self: Range, all: []const data.Day) []const data.Day {
        const count: usize = switch (self) {
            .months90 => all.len,
            .days30 => 30,
            .days7 => 7,
        };
        return all[all.len - count ..];
    }
};

pub const Tab = enum {
    outline,
    past_performance,
    key_personnel,
    focus_documents,

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .outline => "Outline",
            .past_performance => "Past Performance",
            .key_personnel => "Key Personnel",
            .focus_documents => "Focus Documents",
        };
    }

    pub fn matches(self: Tab, row: *const data.Row) bool {
        return switch (self) {
            .outline => true,
            .past_performance => row.status == .done,
            .key_personnel => !std.mem.eql(u8, row.reviewer, "Assign reviewer"),
            .focus_documents => std.mem.eql(u8, row.section_type, "Narrative"),
        };
    }

    pub fn count(self: Tab) usize {
        var total: usize = 0;
        for (&data.ROWS) |*row| {
            if (self.matches(row)) total += 1;
        }
        return total;
    }
};

pub const Page = enum {
    dashboard,
    lifecycle,
    analytics,
    projects,
    team,
    data_library,
    reports,
    word_assistant,
    more,
    settings,
    get_help,
    search,

    pub fn fromNav(index: usize) Page {
        return switch (index) {
            1 => .lifecycle,
            2 => .analytics,
            3 => .projects,
            4 => .team,
            5 => .data_library,
            6 => .reports,
            7 => .word_assistant,
            8 => .more,
            9 => .settings,
            10 => .get_help,
            11 => .search,
            else => .dashboard,
        };
    }

    pub fn navIndex(self: Page) usize {
        return switch (self) {
            .dashboard => 0,
            .lifecycle => 1,
            .analytics => 2,
            .projects => 3,
            .team => 4,
            .data_library => 5,
            .reports => 6,
            .word_assistant => 7,
            .more => 8,
            .settings => 9,
            .get_help => 10,
            .search => 11,
        };
    }

    pub fn title(self: Page) []const u8 {
        return switch (self) {
            .dashboard => "Dashboard",
            .lifecycle => "Lifecycle",
            .analytics => "Analytics",
            .projects => "Projects",
            .team => "Team",
            .data_library => "Data Library",
            .reports => "Reports",
            .word_assistant => "Word Assistant",
            .more => "More",
            .settings => "Settings",
            .get_help => "Get Help",
            .search => "Search",
        };
    }

    pub fn description(self: Page) []const u8 {
        return switch (self) {
            .dashboard => "Overview of your workspace",
            .lifecycle => "Every document by its stage",
            .analytics => "How visitors move through the product",
            .projects => "Active projects and their owners",
            .team => "People with access to this workspace",
            .data_library => "Datasets available to your team",
            .reports => "Generated reports and exports",
            .word_assistant => "Documents drafted with the assistant",
            .more => "Everything else in this workspace",
            .settings => "Workspace preferences",
            .get_help => "Answers to common questions",
            .search => "Find pages, documents and actions",
        };
    }
};

pub const Dash = struct {
    pub const Options = struct {};

    alloc: std.mem.Allocator,
    chart_svg: ?[]u8 = null,
    chart_sources: [3]?[]u8 = @splat(null),
    sidebar_open: bool = true,
    range: Range = .months90,
    tab: Tab = .outline,
    page: Page = .dashboard,
    active_nav: usize = 0,
    checked: [data.ROWS.len]bool = std.mem.zeroes([data.ROWS.len]bool),
    /// Runtime row order (drag reordering), a copy of the static table.
    rows: [data.ROWS.len]data.Row = data.ROWS,
    settings: [3]bool = .{ true, true, false },
    /// Vertical page scroll offset, driven by wheel events on the page.
    scroll_y: f32 = 0,
    /// Row drag: the row index being dragged and the last pointer position
    /// (for the floating ghost), or null when idle.
    drag_index: ?usize = null,
    drag_active: bool = false,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    drag_press_y: f32 = 0,
    /// Rotating loader SVG for the "In Process" spinner, rebuilt each frame
    /// while frames are animating.
    /// Plot height the cached SVG was built for; a width change invalidates.
    chart_h: f32 = 250,
    spinner_buf: [1024]u8 = undefined,
    spinner_len: usize = 0,
    /// Search field on the Search page.
    search: Entity(zui.TextField),

    pub fn init(cx: *Context(@This()), _: Options) @This() {
        return .{
            .alloc = cx.allocator(),
            .search = cx.new(zui.TextField, .{ .placeholder = "Search pages…", .padding = 8 }),
        };
    }

    /// Reorder a row (and its checked flag) taking the target's slot.
    pub fn setScroll(self: *@This(), value: f32) void {
        self.scroll_y = @max(0, value);
    }

    pub fn moveRow(self: *@This(), from: usize, to: usize) void {
        if (from == to) return;
        const row = self.rows[from];
        const checked = self.checked[from];
        if (from < to) {
            var i = from;
            while (i < to) : (i += 1) {
                self.rows[i] = self.rows[i + 1];
                self.checked[i] = self.checked[i + 1];
            }
        } else {
            var i = from;
            while (i > to) : (i -= 1) {
                self.rows[i] = self.rows[i - 1];
                self.checked[i] = self.checked[i - 1];
            }
        }
        self.rows[to] = row;
        self.checked[to] = checked;
    }

    fn dragGhost(self: *const @This()) Element {
        const row = if (self.drag_index) |index| self.rows[index] else return zui.div();
        return zui.div().absolute()
            .left(self.drag_x - 340)
            .top(self.drag_y - 26)
            .w(680)
            .h(52)
            .flex_row()
            .items_center()
            .px(16)
            .gap(12)
            .rounded_lg()
            .bg(theme.card_metric)
            .border_1()
            .border_color(theme.primary)
            .child(ui.icon(icons.grip_vertical, 16, theme.faint))
            .child(ui.strong(row.header, 14, theme.text))
            .child(zui.spacer())
            .child(ui.label(row.reviewer, 14, theme.muted));
    }

    pub fn spinner(self: *const @This()) []const u8 {
        return self.spinner_buf[0..self.spinner_len];
    }

    /// Rebuild the rotating loader glyph for the current frame time.
    fn refreshSpinner(self: *@This(), window: *Window) void {
        const phase = @divTrunc(@mod(window.timeMs(), 800), 50);
        self.buildSpinner(@as(f64, @floatFromInt(phase)) * 22.5);
    }

    fn buildSpinner(self: *@This(), angle: f64) void {
        const open_end = std.mem.indexOfScalar(u8, icons.loader, '>') orelse return;
        const close_start = std.mem.lastIndexOf(u8, icons.loader, "</svg>") orelse return;
        const body = icons.loader[open_end + 1 .. close_start];
        const head = std.fmt.bufPrint(self.spinner_buf[0..], "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><g transform=\"rotate({d:.1} 12 12)\">", .{angle}) catch {
            self.spinner_len = 0;
            return;
        };
        const tail = "</g></svg>";
        if (head.len + body.len + tail.len > self.spinner_buf.len) {
            self.spinner_len = 0;
            return;
        }
        @memcpy(self.spinner_buf[head.len..][0..body.len], body);
        @memcpy(self.spinner_buf[head.len + body.len ..][0..tail.len], tail);
        self.spinner_len = head.len + body.len + tail.len;
    }

    /// Approximate content height, for clamping the page scroll.
    fn contentHeight(self: *const @This()) f32 {
        var visible: f32 = 0;
        for (&data.ROWS) |*row| {
            if (self.tab.matches(row)) visible += 1;
        }
        if (self.page != .dashboard) return 900;
        return 24 + 184 + 24 + 470 + 24 + 36 + 16 + 40 + visible * 52 + 40;
    }

    fn onPageScroll(self: *@This(), window: *Window, cx: *Context(@This())) void {
        const viewport = window.bounds.size.h - 34 - 8 - 48;
        const max = @max(0, self.contentHeight() - viewport);
        self.scroll_y = std.math.clamp(self.scroll_y - window.scrollEvent().dy * 45, 0, max);
        cx.notify();
    }

    pub fn resetDrag(self: *@This()) void {
        self.drag_index = null;
        self.drag_active = false;
    }

    pub fn deinit(self: *@This()) void {
        for (self.chart_sources) |source| if (source) |bytes| self.alloc.free(bytes);
    }

    /// All image work happens before the first view frame. SVG variants use
    /// intrinsic resolution; layout scales them without rasterizing in paint.
    fn preloadAssets(self: *@This(), cache: *zui.images.Cache) !void {
        inline for (comptime std.meta.declarations(icons)) |decl| {
            _ = try cache.assets.preloadBytes(@field(icons, decl), 0);
        }
        inline for (.{ Range.months90, Range.days30, Range.days7 }, 0..) |range, i| {
            const bytes = try chart.build(self.alloc, range.days(&data.DAYS), 250);
            self.chart_sources[i] = bytes;
            _ = try cache.assets.preloadBytes(bytes, 0);
        }
        for (0..16) |phase| {
            self.buildSpinner(@as(f64, @floatFromInt(phase)) * 22.5);
            _ = try cache.assets.preloadBytes(self.spinner(), 0);
        }
    }

    /// Plot height for the current page width (mirrors the reference's flat
    /// 250px chart at full width; narrower pages keep the same aspect).
    pub fn plotHeight(self: *const @This(), body_width: f32) f32 {
        _ = self;
        return std.math.clamp(body_width / 5.8, 170, 260);
    }

    pub fn setRange(self: *@This(), value: Range) void {
        self.range = value;
    }

    fn ensureChart(self: *@This(), height: f32) void {
        self.chart_h = height;
        self.chart_svg = self.chart_sources[@intFromEnum(self.range)];
    }

    // -- window chrome -----------------------------------------------------

    fn closeWindow(_: *@This(), window: *Window, _: *Context(@This())) void {
        window.close();
    }

    fn minimizeWindow(_: *@This(), window: *Window, _: *Context(@This())) void {
        window.minimize();
    }

    fn toggleMaximize(_: *@This(), window: *Window, cx: *Context(@This())) void {
        window.toggleMaximize();
        cx.notify();
    }

    fn beginDrag(_: *@This(), window: *Window, _: *Context(@This())) void {
        window.startDrag();
    }

    fn controlButton(glyph: Element) Element {
        return zui.div().size(28).flex_row().items_center().justify_center().rounded_lg()
            .cursor_pointer().hover_bg(theme.hover)
            .child(glyph);
    }

    pub fn render(self: *@This(), window: *Window, cx: *Context(@This())) Element {
        const win = window.bounds.size;
        const page_width = if (self.sidebar_open) win.w - 296 else win.w - 16;
        const body_width = @max(200, page_width - 32);
        self.ensureChart(self.plotHeight(body_width));
        // The status pills spin while any "In Process" row exists; the
        // frame loop keeps drawing until the app stops asking.
        if (self.page == .dashboard) {
            self.refreshSpinner(window);
            window.requestAnimationFrame();
        }
        const title_height: f32 = 34;
        const body_height = win.h - title_height;

        const titlebar = zui.div().flex_row().items_center().h(title_height).w_full().px(12)
            .bg(theme.page)
            .border_b_1().border_color(theme.border)
            .on_mouse_down(cx.listener(@This(), beginDrag))
            .child(ui.label("Dash", 13, theme.muted))
            .child(zui.spacer())
            .child(controlButton(zui.div().w(12).h(2).rounded_full().bg(theme.body))
                .on_click(cx.listener(@This(), minimizeWindow)))
            .child(controlButton(zui.div().size(10).rounded_lg().border_1().border_color(theme.body))
                .on_click(cx.listener(@This(), toggleMaximize)))
            .child(controlButton(zui.text("✕", .{ .font = theme.font, .size = 12, .line_height = 14, .color = theme.body }))
                .on_click(cx.listener(@This(), closeWindow)));

        const title = if (self.page == .dashboard) "Documents" else self.page.title();

        var row = zui.div().flex_row().h(body_height);
        if (self.sidebar_open) {
            row = row.child(sidebar.render(self, body_height, cx));
        }
        row = row.child(self.panel(title, body_height, body_width, cx));

        var page = zui.div().flex_col().size_full().bg(theme.page)
            .child(titlebar)
            .child(row);
        if (self.drag_active) page = page.child(self.dragGhost());
        return page;
    }

    fn panel(self: *@This(), title: []const u8, height: f32, body_width: f32, cx: *Context(@This())) Element {
        const left = if (self.sidebar_open) @as(f32, 0) else 8;
        var inner = zui.div().flex_col().size_full().rounded_xl().bg(theme.panel)
            .child(header.render(self, title, cx));

        const body = if (self.page == .dashboard)
            zui.div().flex_col().px(16).pt(24).gap(24)
                .child(cards.metrics(body_width))
                .child(cards.chartCard(self, body_width, cx))
                .child(table.render(self, cx))
        else
            zui.div().flex_col().px(16).pt(24).gap(24)
                .child(pages.render(self, body_width, cx));

        inner = inner.child(
            // Wheel-scrollable page: the container clips (every container
            // does), `scroll_y` translates the content, and the scroll
            // listener owns the offset clamp.
            zui.div().w_full().h(height - 48).scroll_y(self.scroll_y)
                .on_scroll(cx.listener(@This(), onPageScroll))
                .child(body),
        );

        return zui.div().flex_1().h(height).p(8).pl(left)
            .child(inner);
    }
};

// ---------------------------------------------------------------------------
// App wiring
// ---------------------------------------------------------------------------

fn buildRoot(window: *Window, vcx: *Context(Dash)) Entity(Dash) {
    const view = vcx.new(Dash, .{});
    if (window.images) |cache| view.readMut().preloadAssets(cache) catch |err| {
        std.log.err("asset preload: {s}", .{@errorName(err)});
    };
    return view;
}

fn onOpen(cx: *App) void {
    const bounds = zui.Bounds.centered(null, zui.size(1600, 1000), cx);
    _ = cx.openWindow(.{
        .bounds = bounds,
        .title = "Dash",
        .min_size = zui.size(1100, 700),
        .chrome = .custom,
    }, buildRoot) catch |err| std.log.err("open window: {s}", .{@errorName(err)});
    cx.activate(true);
}

// ---------------------------------------------------------------------------
// Headless snapshot
// ---------------------------------------------------------------------------

fn snapshotDimension(name: [*:0]const u8, fallback: u32) u32 {
    const raw = std.c.getenv(name) orelse return fallback;
    const value = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch return fallback;
    return if (value >= 100 and value <= 4096) value else fallback;
}

fn snapshotHeadless(gpa: std.mem.Allocator, path: []const u8) !void {
    const width = snapshotDimension("ZUI_SNAPSHOT_WIDTH", 1600);
    const height = snapshotDimension("ZUI_SNAPSHOT_HEIGHT", 1000);
    var app = try App.initHeadless(gpa);
    defer app.deinit();
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) } },
        .title = "Dash",
        .min_size = zui.size(1100, 700),
        .chrome = .custom,
    }, buildRoot);
    _ = app.step();

    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    var renderer = zui.gpu.vellz.Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.render(pixels, width, height, .rgba32, theme.page, &win.scene, app.glyphPixels(), app.imagePixels());

    const file = file: {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const name: [*:0]const u8 = path_buf[0..path.len :0];
        break :file std.c.fopen(name, "wb") orelse return error.CannotOpenSnapshot;
    };
    defer _ = std.c.fclose(file);
    var header_buf: [64]u8 = undefined;
    const header_text = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });
    if (std.c.fwrite(header_text.ptr, 1, header_text.len, file) != header_text.len) return error.SnapshotWriteFailed;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (std.c.fwrite(pixels.ptr + i, 1, 3, file) != 3) return error.SnapshotWriteFailed;
    }
}

var selftest_view: ?Entity(Dash) = null;

fn selftestBuildRoot(window: *Window, vcx: *Context(Dash)) Entity(Dash) {
    const view = buildRoot(window, vcx);
    selftest_view = view;
    return view;
}

fn click(backend: anytype, x: f32, y: f32) void {
    _ = backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = x, .y = y }, .button = .left, .pressed = true } });
    _ = backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = x, .y = y }, .button = .left, .pressed = false } });
}

/// Headless functional test: drives synthetic clicks through the full
/// backend queue -> App -> Window -> hit-test -> listener -> entity path and
/// verifies the dashboard state changes. Run with:
///   ZUI_BACKEND=null ZUI_SELFTEST=1 zig build run-dash
/// Exits nonzero on the first failure so CI can gate on it.
fn selftestHeadless(gpa: std.mem.Allocator) !void {
    const out = std.debug.print;
    var app = try App.initHeadless(gpa);
    defer app.deinit();
    _ = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 1600, .h = 1000 } },
        .title = "Dash",
        .min_size = zui.size(1100, 700),
        .chrome = .custom,
    }, selftestBuildRoot);
    _ = app.step(); // initial frame populates hit regions
    const backend = app.getNullBackend() orelse return error.SelftestNeedsNullBackend;
    const view = selftest_view orelse return error.SelftestNoView;

    var failures: u32 = 0;
    const check = struct {
        fn ok(cond: bool, count: *u32, comptime fmt: []const u8, args: anytype) void {
            if (cond) {
                std.debug.print("selftest PASS: " ++ fmt ++ "\n", args);
            } else {
                std.debug.print("selftest FAIL: " ++ fmt ++ "\n", args);
                count.* += 1;
            }
        }
    }.ok;

    // -- sidebar toggle (header's panel button) --
    click(backend, 331, 66);
    _ = app.step();
    check(!view.read().sidebar_open, &failures, "panel button closes the sidebar", .{});
    click(backend, 43, 66);
    _ = app.step();
    check(view.read().sidebar_open, &failures, "panel button reopens the sidebar", .{});

    // -- chart range control --
    check(view.read().range == .months90, &failures, "chart starts on 3 months", .{});
    click(backend, 1396, 363);
    _ = app.step();
    check(view.read().range == .days30, &failures, "30-day segment switches the range", .{});
    click(backend, 1507, 363);
    _ = app.step();
    check(view.read().range == .days7, &failures, "7-day segment switches the range", .{});
    click(backend, 1282, 363);
    _ = app.step();
    check(view.read().range == .months90, &failures, "3-month segment restores the range", .{});

    // -- table tabs filter rows --
    check(view.read().tab == .outline, &failures, "table starts on Outline", .{});
    click(backend, 446, 698);
    _ = app.step();
    check(view.read().tab == .past_performance, &failures, "Past Performance tab activates", .{});
    click(backend, 340, 698);
    _ = app.step();
    check(view.read().tab == .outline, &failures, "Outline tab restores", .{});

    // -- row checkbox toggles --
    check(!view.read().checked[0], &failures, "first row starts unchecked", .{});
    click(backend, 363, 798);
    _ = app.step();
    check(view.read().checked[0], &failures, "row checkbox toggles on", .{});
    click(backend, 363, 798);
    _ = app.step();
    check(!view.read().checked[0], &failures, "row checkbox toggles off", .{});

    // -- row drag reorders the table (mouse down, move, release) --
    const first_id = view.read().rows[0].id;
    const second_id = view.read().rows[1].id;
    _ = backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = 700, .y = 798 }, .button = .left, .pressed = true } });
    _ = app.step();
    _ = backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = 700, .y = 815 }, .button = .left, .pressed = false, .motion = true } });
    _ = app.step();
    _ = backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = 700, .y = 850 }, .button = .left, .pressed = false, .motion = true } });
    _ = app.step();
    _ = backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = 700, .y = 850 }, .button = .left, .pressed = false } });
    _ = app.step();
    check(view.read().rows[0].id == second_id and view.read().rows[1].id == first_id, &failures, "dragging a row swaps it into the hovered slot", .{});
    check(view.read().drag_index == null, &failures, "release clears the drag state", .{});

    // -- the page scrolls with the wheel --
    _ = backend.pushEvent(.{ .scroll = .{ .pos = .{ .x = 800, .y = 600 }, .dy = -3 } });
    _ = app.step();
    check(view.read().scroll_y > 0, &failures, "wheel scrolls the page", .{});
    view.value.scroll_y = 0;

    // -- the In Process spinner is generated --
    _ = app.step();
    check(std.mem.indexOf(u8, view.read().spinner(), "rotate(") != null, &failures, "spinner svg is built with a rotation", .{});

    // -- sidebar navigation opens pages --
    check(view.read().page == .dashboard, &failures, "starts on the dashboard", .{});
    click(backend, 150, 197);
    _ = app.step();
    check(view.read().page == .lifecycle and view.read().active_nav == 1, &failures, "Lifecycle opens its page", .{});
    click(backend, 150, 233);
    _ = app.step();
    check(view.read().page == .analytics, &failures, "Analytics opens its page", .{});
    click(backend, 150, 155);
    _ = app.step();
    check(view.read().page == .dashboard, &failures, "Dashboard returns", .{});

    // -- search page filters by the typed text --
    click(backend, 150, 916);
    _ = app.step();
    check(view.read().page == .search, &failures, "Search opens its page", .{});
    click(backend, 500, 205);
    _ = app.step();
    var text_ev = std.mem.zeroes(zui.platform.event.TextEvent);
    const typed = "team";
    @memcpy(text_ev.text[0..typed.len], typed);
    text_ev.len = typed.len;
    _ = backend.pushEvent(.{ .text = text_ev });
    _ = app.step();
    const query = view.read().search.read();
    check(std.mem.eql(u8, query.trimmedText(), typed), &failures, "search field receives typed text", .{});

    if (failures != 0) {
        out("selftest: {d} failure(s)\n", .{failures});
        return error.SelftestFailed;
    }
    out("selftest: all checks passed\n", .{});
}

pub fn main(init: std.process.Init) !void {
    if (std.c.getenv("ZUI_SNAPSHOT")) |raw| {
        try snapshotHeadless(init.gpa, std.mem.span(raw));
        return;
    }
    if (std.c.getenv("ZUI_SELFTEST") != null) {
        try selftestHeadless(init.gpa);
        return;
    }
    var app = try App.init(init.gpa);
    defer app.deinit();
    app.run(onOpen);
}

test {
    std.testing.refAllDecls(@This());
    _ = chart;
}
