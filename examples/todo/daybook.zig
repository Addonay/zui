//! Daybook: a small native task workspace built with ZUI.
const std = @import("std");
const zui = @import("zui");

const App = zui.App;
const Context = zui.Context;
const Window = zui.Window;
const Entity = zui.Entity;
const Element = zui.Element;
const FocusHandle = zui.FocusHandle;

const theme = struct {
    const bg = zui.hex(0xeaf0f6);
    const panel = zui.hex(0xf8fafc);
    const card = zui.hex(0xffffff);
    const card_hover = zui.hex(0xe4edf7);
    const border = zui.hex(0xcbd6e3);
    const text = zui.hex(0x20344a);
    const muted = zui.hex(0x54677b);
    const faint = zui.hex(0x64758a);
    const accent = zui.hex(0x315fa4);
    const good = zui.hex(0x277060);
    const danger = zui.hex(0xa43643);
    const font = struct {
        const sans = "Noto Sans, sans-serif";
        const display = "Noto Sans Display, Noto Sans, sans-serif";
        const mono = "DejaVu Sans Mono, monospace";
    };
};

const Todo = struct {
    id: u32,
    title: zui.SharedString,
    done: bool,
};

const Filter = enum {
    all,
    active,
    done,

    fn label(self: @This()) []const u8 {
        return switch (self) {
            .all => "All",
            .active => "Active",
            .done => "Done",
        };
    }
};

// ---------------------------------------------------------------------------
// Root view.
// ---------------------------------------------------------------------------

const TodoApp = struct {
    pub const Options = struct {};
    const page_size = 4;

    alloc: std.mem.Allocator,
    todos: std.ArrayList(Todo),
    next_id: u32 = 1,
    filter: Filter = .all,
    selected: ?u32 = null,
    page: usize = 0,
    input: Entity(zui.TextField),
    focus_root: FocusHandle,

    pub fn init(cx: *Context(@This()), _: Options) @This() {
        return .{
            .alloc = cx.allocator(),
            .todos = .empty,
            .input = cx.new(zui.TextField, .{
                .placeholder = "What would you like to get done?",
                .text_color = theme.text,
                .placeholder_color = theme.muted,
                .focus_color = theme.accent,
            }),
            .focus_root = cx.focusHandle(),
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.todos.items) |todo| todo.title.release();
        self.todos.deinit(self.alloc);
    }

    // -- pure mutations. Each listener calls one of these, then cx.notify() --

    fn addFromDraft(self: *@This(), window: *Window, cx: *Context(@This())) void {
        const text = self.input.read().trimmedText();
        if (text.len == 0) {
            window.playSystemBell();
            return;
        }
        self.add(text, cx) catch return;
        self.input.update(zui.TextField.clear);
        self.filter = .all;
        self.page = (self.todos.items.len - 1) / page_size;
        cx.notify();
    }

    fn add(self: *@This(), title: []const u8, cx: *Context(@This())) !void {
        const owned_title = try zui.string(self.alloc, title);
        errdefer owned_title.release();
        try self.todos.append(self.alloc, .{ .id = self.next_id, .title = owned_title, .done = false });
        self.selected = self.next_id;
        self.next_id += 1;
        cx.notify();
    }

    fn toggle(self: *@This(), id: u32, cx: *Context(@This())) void {
        for (self.todos.items) |*t| {
            if (t.id == id) t.done = !t.done;
        }
        cx.notify();
    }

    fn remove(self: *@This(), id: u32, cx: *Context(@This())) void {
        var kept: usize = 0;
        for (self.todos.items) |t| {
            if (t.id != id) {
                self.todos.items[kept] = t;
                kept += 1;
            } else {
                t.title.release();
            }
        }
        self.todos.shrinkRetainingCapacity(kept);
        if (self.selected == id) self.selected = null;
        cx.notify();
    }

    fn setFilter(self: *@This(), f: Filter, cx: *Context(@This())) void {
        self.filter = f;
        self.page = 0;
        cx.notify();
    }

    fn clearCompleted(self: *@This(), cx: *Context(@This())) void {
        var kept: usize = 0;
        for (self.todos.items) |t| {
            if (t.done) {
                t.title.release();
            } else {
                self.todos.items[kept] = t;
                kept += 1;
            }
        }
        self.todos.shrinkRetainingCapacity(kept);
        cx.notify();
    }

    fn toggleSelected(self: *@This(), cx: *Context(@This())) void {
        if (self.selected) |id| self.toggle(id, cx);
    }

    fn removeSelected(self: *@This(), cx: *Context(@This())) void {
        if (self.selected) |id| self.remove(id, cx);
    }

    // -- derived --

    fn counts(self: *const @This()) struct { total: usize, done: usize, left: usize } {
        var done: usize = 0;
        for (self.todos.items) |t| {
            if (t.done) done += 1;
        }
        return .{ .total = self.todos.items.len, .done = done, .left = self.todos.items.len - done };
    }

    fn isVisible(self: *const @This(), t: Todo) bool {
        return switch (self.filter) {
            .all => true,
            .active => !t.done,
            .done => t.done,
        };
    }

    fn progress(self: *const @This()) f32 {
        const c = self.counts();
        if (c.total == 0) return 0;
        return @as(f32, @floatFromInt(c.done)) / @as(f32, @floatFromInt(c.total));
    }

    // -----------------------------------------------------------------------
    // Render — pure description of UI. No mutation here except via listeners.
    // -----------------------------------------------------------------------

    pub fn render(self: *@This(), window: *Window, cx: *Context(@This())) Element {
        const c = self.counts();
        const wide = window.bounds.size.w >= 800;
        var body = zui.div().flex_row().flex_1().w_full();
        if (wide) body = body.child(zui.div().flex_col().w(200).h(window.bounds.size.h - 48).p(24).gap(24).bg(theme.panel)
            .child(label("MY WORKSPACE", 11, theme.muted))
            .child(zui.div().flex_col().gap(8)
                .child(filterButton(cx, .all, self.filter, c.total))
                .child(filterButton(cx, .active, self.filter, c.left))
                .child(filterButton(cx, .done, self.filter, c.done)))
            .child(zui.spacer())
            .child(label("A little more done.", 14, theme.text))
            .child(label("One task at a time.", 12, theme.muted)));
        var content = zui.div().flex_col().flex_1().p(if (wide) 32 else 20).gap(20);
        content = content.child(zui.div().flex_row().items_center().justify_between()
            .child(zui.div().flex_col().gap(6)
                .child(zui.text("Your day, in order.", .{ .font = theme.font.display, .size = 28, .line_height = 36, .weight = .bold, .color = theme.text }))
                .child(label("Make room for what matters next.", 14, theme.muted)))
            .child(zui.div().flex_col().items_center().gap(4)
            .child(zui.textFmt("{d}", .{c.left}, .{ .font = theme.font.mono, .size = 28, .line_height = 36, .color = theme.accent }))
            .child(label("remaining", 11, theme.muted))));
        content = content.child(zui.div().flex_col().gap(8)
            .child(label("NEW TASK", 11, theme.muted))
            .child(zui.div().flex_row().items_center().gap(8).p(6).rounded_lg().bg(theme.card).border_1().border_color(theme.border)
            .child(zui.div().flex_1().child(self.input))
            .child(button("Add task", cx.listener(@This(), addFromDraft), true))));
        if (!wide) content = content.child(zui.div().flex_row().gap(8)
            .child(filterButton(cx, .all, self.filter, c.total))
            .child(filterButton(cx, .active, self.filter, c.left))
            .child(filterButton(cx, .done, self.filter, c.done)));
        content = content.child(zui.div().flex_row().items_center().justify_between()
            .child(label(switch (self.filter) {
                .all => "All tasks",
                .active => "Still to do",
                .done => "Completed",
            }, 17, theme.text))
            .child(zui.textFmt("{d} of {d} complete", .{ c.done, c.total }, .{ .font = theme.font.sans, .size = 12, .line_height = 18, .color = theme.muted })));
        content = content.child(self.renderList(cx));
        content = content.child(zui.div().flex_row().items_center().justify_between()
            .child(label("Select a task · Space to complete", 12, theme.muted))
            .child(button("Clear completed", cx.listener(@This(), clearCompleted), false)));
        body = body.child(content);
        return zui.div().flex_col().size_full().bg(theme.bg)
            .child(zui.div().flex_row().items_center().h(48).px(20).gap(10).bg(theme.panel).border_b_1().border_color(theme.border)
                .on_mouse_down(cx.listener(@This(), beginDrag))
                .on_double_click(cx.listener(@This(), toggleMaximize))
                .child(zui.div().w(4).h(20).rounded_lg().bg(theme.accent))
                .child(zui.text("daybook", .{ .font = theme.font.display, .size = 17, .line_height = 24, .weight = .bold, .color = theme.text }))
                .child(zui.spacer())
                .child(winButton(cx, "—", minimizeWindow))
                .child(winButton(cx, if (window.isMaximized()) "▢" else "□", toggleMaximize))
                .child(winButton(cx, "×", closeWindow)))
            .child(body);
    }

    fn renderList(self: *@This(), cx: *Context(@This())) Element {
        var count: usize = 0;
        for (self.todos.items) |todo| {
            if (self.isVisible(todo)) {
                count += 1;
            }
        }
        if (count == 0) return zui.div().flex_col().h(220).items_center().justify_center().gap(12).rounded_lg().bg(theme.card)
            .child(label(if (self.filter == .done) "Your finished tasks will appear here." else if (self.filter == .active) "Everything is checked off." else "Start with one small thing.", 18, theme.text))
            .child(label(if (self.filter == .all) "Write a task above, then choose Add task." else "Choose All to see your whole list.", 13, theme.muted));
        const current_page = @min(self.page, (count - 1) / page_size);
        var list = zui.div().flex_col().gap(8);
        var index: usize = 0;
        for (self.todos.items) |todo| {
            if (!self.isVisible(todo)) continue;
            if (index >= current_page * page_size and index < (current_page + 1) * page_size) list = list.child(self.renderRow(todo, cx));
            index += 1;
        }
        if (count > page_size) list = list.child(zui.div().flex_row().items_center().justify_between()
            .child(button("Previous", cx.listener(@This(), previousPage), false))
            .child(zui.textFmt("Page {d} of {d}", .{ current_page + 1, (count + page_size - 1) / page_size }, .{ .size = 12, .color = theme.muted }))
            .child(button("Next", cx.listener(@This(), nextPage), false)));
        return list;
    }

    fn renderRow(self: *@This(), todo: Todo, cx: *Context(@This())) Element {
        const selected = self.selected == todo.id;
        return zui.div().flex_row().items_center().gap(14).p(14).rounded_lg()
            .bg(if (selected) theme.card_hover else theme.card)
            .border_1().border_color(if (selected) theme.accent else theme.border)
            .hover_bg(theme.card_hover).cursor_pointer()
            .on_click(cx.listenerWith(u32, @This(), selectRow, todo.id))
            .child(zui.div().size(24).rounded_lg().border_2()
                .border_color(if (todo.done) theme.good else theme.faint)
                .bg(if (todo.done) theme.good else theme.card)
                .items_center().justify_center().cursor_pointer()
                .on_click(cx.listenerWith(u32, @This(), toggle, todo.id))
                .child(zui.when(todo.done, zui.text("✓", .{ .size = 14, .color = zui.white() }))))
            .child(zui.div().flex_1().child(zui.text(todo.title.slice(), .{
                .font = theme.font.sans,
                .size = 15,
                .line_height = 22,
                .color = if (todo.done) theme.muted else theme.text,
                .strike = todo.done,
            })))
            .child(zui.div().px(8).h(30).items_center().justify_center().rounded_lg().hover_bg(theme.border).cursor_pointer()
            .on_click(cx.listenerWith(u32, @This(), remove, todo.id))
            .child(label("Delete", 12, theme.muted)));
    }

    fn previousPage(self: *@This(), cx: *Context(@This())) void {
        self.page -|= 1;
        cx.notify();
    }
    fn nextPage(self: *@This(), cx: *Context(@This())) void {
        var count: usize = 0;
        for (self.todos.items) |todo| {
            if (self.isVisible(todo)) {
                count += 1;
            }
        }
        self.page = @min(self.page + 1, (count -| 1) / page_size);
        cx.notify();
    }
    fn selectRow(self: *@This(), id: u32, window: *Window, cx: *Context(@This())) void {
        self.selected = id;
        window.focus(self.focus_root, cx);
        cx.notify();
    }
    fn focusComposer(self: *@This(), window: *Window, cx: *Context(@This())) void {
        window.focus(self.input.focusHandle(cx), cx);
    }
    fn blurComposer(_: *@This(), window: *Window, cx: *Context(@This())) void {
        window.focus(@as(FocusHandle, .{}), cx);
    }
    fn beginDrag(_: *@This(), window: *Window, _: *Context(@This())) void {
        window.startDrag();
    }
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
    pub fn focusHandle(self: *@This(), _: *Context(@This())) FocusHandle {
        return self.focus_root;
    }
};

fn label(value: []const u8, size: f32, color: zui.Color) Element {
    return zui.text(value, .{ .font = theme.font.sans, .size = size, .line_height = size + 6, .color = color });
}
fn button(value: []const u8, listener: anytype, primary: bool) Element {
    return zui.div().h(40).px(14).items_center().justify_center().rounded_lg().cursor_pointer()
        .bg(if (primary) theme.accent else theme.panel).hover_bg(if (primary) theme.text else theme.card_hover)
        .on_click(listener).child(label(value, 13, if (primary) zui.white() else theme.muted));
}
fn filterButton(cx: *Context(TodoApp), filter: Filter, current: Filter, count: usize) Element {
    return zui.div().flex_row().h(40).px(12).gap(10).items_center().rounded_lg().cursor_pointer()
        .bg(if (filter == current) theme.card_hover else theme.panel).hover_bg(theme.card_hover)
        .on_click(cx.listenerWith(Filter, TodoApp, TodoApp.setFilter, filter))
        .child(label(filter.label(), 13, if (filter == current) theme.accent else theme.muted))
        .child(zui.textFmt("{d}", .{count}, .{ .font = theme.font.mono, .size = 12, .line_height = 18, .color = theme.muted }));
}
fn winButton(cx: *Context(TodoApp), value: []const u8, comptime handler: anytype) Element {
    return zui.div().w(34).h(30).rounded_lg().items_center().justify_center().cursor_pointer()
        .hover_bg(theme.card_hover).on_click(cx.listener(TodoApp, handler)).child(label(value, 15, theme.muted));
}

// ---------------------------------------------------------------------------
// App wiring — mirrors gpui's `application().run(|cx| cx.open_window(...))`.
// ---------------------------------------------------------------------------

fn buildRoot(window: *Window, vcx: *Context(TodoApp)) Entity(TodoApp) {
    const view = vcx.new(TodoApp, .{});
    vcx.bindKeys(TodoApp, &.{
        .{ .key = "enter", .action = "add" },
        .{ .key = "space", .action = "toggle-selected" },
        .{ .key = "delete", .action = "delete-selected" },
        .{ .key = "tab", .action = "focus-composer" },
        .{ .key = "escape", .action = "blur-composer" },
    });
    window.on_action("add", view, TodoApp.addFromDraft);
    window.on_action("toggle-selected", view, TodoApp.toggleSelected);
    window.on_action("delete-selected", view, TodoApp.removeSelected);
    window.on_action("focus-composer", view, TodoApp.focusComposer);
    window.on_action("blur-composer", view, TodoApp.blurComposer);
    seedDemo(view);
    return view;
}

/// Screenshot seed: ZUI_TODO_DEMO=1 starts with rows so empty state and
/// populated list can both be verified visually.
fn seedDemo(view: Entity(TodoApp)) void {
    if (std.c.getenv("ZUI_TODO_DEMO") == null) return;
    view.updateWith("Buy milk", TodoApp.add) catch {};
    view.updateWith("Write zig", TodoApp.add) catch {};
    view.updateWith("Ship the todo app", TodoApp.add) catch {};
    if (view.read().todos.items.len > 0) {
        view.updateWith(view.read().todos.items[0].id, TodoApp.toggle);
    }
}

fn onOpen(cx: *App) void {
    const bounds = zui.Bounds.centered(null, zui.size(960, 800), cx);
    _ = cx.openWindow(.{
        .bounds = bounds,
        .title = "Daybook",
        .min_size = zui.size(540, 740),
        // Native titlebar off: renderTitlebar above draws our own chrome
        // (icon, title, min/max/close) so the app looks identical on
        // Wayland, X11, Win32, and Cocoa.
        .chrome = .custom,
    }, buildRoot) catch |err| std.log.err("open window: {s}", .{@errorName(err)});
    cx.activate(true);
}

/// Headless snapshot: ZUI_SNAPSHOT=/path.ppm renders one frame through the
/// exact layout+painter path and dumps it as PPM. No window needed, so visual
/// regressions can be checked in CI or over ssh.
fn snapshotDimension(name: [*:0]const u8, fallback: u32) u32 {
    const raw = std.c.getenv(name) orelse return fallback;
    const value = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch return fallback;
    return if (value >= 100 and value <= 4096) value else fallback;
}

fn snapshotHeadless(gpa: std.mem.Allocator, path: []const u8) !void {
    const width = snapshotDimension("ZUI_SNAPSHOT_WIDTH", 960);
    const height = snapshotDimension("ZUI_SNAPSHOT_HEIGHT", 800);
    var app = try App.initHeadless(gpa);
    defer app.deinit();
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) } },
        .title = "Daybook",
        .min_size = zui.size(540, 740),
        .chrome = .custom,
    }, buildRoot);
    _ = app.step();

    if (std.c.getenv("ZUI_DEBUG_BOUNDS")) |raw| {
        const out_path = std.mem.span(raw);
        var path_buf: [4096]u8 = undefined;
        if (out_path.len < path_buf.len) {
            @memcpy(path_buf[0..out_path.len], out_path);
            path_buf[out_path.len] = 0;
            const name: [*:0]const u8 = path_buf[0..out_path.len :0];
            if (std.c.fopen(name, "w")) |f| {
                defer _ = std.c.fclose(f);
                var idx: usize = 0;
                while (idx < win.ui_frame.node_count) : (idx += 1) {
                    const n = &win.ui_frame.nodes[idx];
                    const kind: u8 = switch (n.kind) {
                        .container => 'C',
                        .text => 'T',
                        .spacer => 'S',
                        .image => 'I',
                    };
                    var line: [512]u8 = undefined;
                    const text_len = @min(n.text_value.len, 80);
                    const text = try std.fmt.bufPrint(&line, "node {d} kind {c} bounds {d:.1} {d:.1} {d:.1} {d:.1} text '{s}'\n", .{ idx, kind, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, n.text_value[0..text_len] });
                    if (std.c.fwrite(text.ptr, 1, text.len, f) != text.len) break;
                }
                for (win.scene.slice(), 0..) |q, qi| {
                    var line: [512]u8 = undefined;
                    const text = try std.fmt.bufPrint(&line, "quad {d} rect {d:.1} {d:.1} {d:.1} {d:.1} r={d:.1} rgba {d:.2} {d:.2} {d:.2} {d:.2}\n", .{ qi, q.x, q.y, q.w, q.h, q.radius, q.color.r, q.color.g, q.color.b, q.color.a });
                    if (std.c.fwrite(text.ptr, 1, text.len, f) != text.len) break;
                }
                for (win.scene.glyphSlice(), 0..) |g, gi| {
                    var line: [512]u8 = undefined;
                    const text = try std.fmt.bufPrint(&line, "glyph {d} pos {d:.1} {d:.1} size {d}x{d} off {d}\n", .{ gi, g.x, g.y, g.w, g.h, g.atlas_offset });
                    if (std.c.fwrite(text.ptr, 1, text.len, f) != text.len) break;
                }
                for (win.scene.imageSlice(), 0..) |b, bi| {
                    var line: [512]u8 = undefined;
                    const text = try std.fmt.bufPrint(&line, "blit {d} rect {d:.1} {d:.1} {d:.1} {d:.1} src {d}x{d} off {d}\n", .{ bi, b.x, b.y, b.w, b.h, b.src_w, b.src_h, b.pool_offset });
                    if (std.c.fwrite(text.ptr, 1, text.len, f) != text.len) break;
                }
            }
        }
    }

    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    const target = zui.gpu.software.Target.init(pixels, width, height, .rgba32);
    target.clear(theme.bg);
    target.renderScene(&win.scene, app.glyphPixels(), app.imagePixels());

    const file = file: {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const name: [*:0]const u8 = path_buf[0..path.len :0];
        break :file std.c.fopen(name, "wb") orelse return error.CannotOpenSnapshot;
    };
    defer _ = std.c.fclose(file);
    var header: [64]u8 = undefined;
    const header_text = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height });
    if (std.c.fwrite(header_text.ptr, 1, header_text.len, file) != header_text.len) return error.SnapshotWriteFailed;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (std.c.fwrite(pixels.ptr + i, 1, 3, file) != 3) return error.SnapshotWriteFailed;
    }
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

/// Headless functional test: drives synthetic mouse/key events through the
/// full backend queue → App → Window → hit-test → listener → entity path
/// and verifies state changes. Run with:
///   ZUI_TODO_DEMO=1 ZUI_SELFTEST=1 zig build run-todo
/// Exits nonzero on the first failure so CI can gate on it.
var selftest_view: ?Entity(TodoApp) = null;

fn selftestBuildRoot(window: *Window, vcx: *Context(TodoApp)) Entity(TodoApp) {
    const view = buildRoot(window, vcx);
    selftest_view = view;
    return view;
}

fn selftestHeadless(gpa: std.mem.Allocator) !void {
    const out = std.debug.print;
    var app = try App.initHeadless(gpa);
    defer app.deinit();
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 960, .h = 800 } },
        .title = "Daybook",
        .min_size = zui.size(540, 740),
        .chrome = .custom,
    }, selftestBuildRoot);
    _ = app.step(); // initial render populates hit regions
    const null_backend = app.getNullBackend() orelse return error.SelftestNeedsNullBackend;
    const view = selftest_view orelse return error.SelftestNoView;

    var failures: u32 = 0;
    const check = struct {
        fn ok(cond: bool, count: *u32, comptime fmt: []const u8, args: anytype) void {
            if (cond) {
                out("selftest PASS: " ++ fmt ++ "\n", args);
            } else {
                out("selftest FAIL: " ++ fmt ++ "\n", args);
                count.* += 1;
            }
        }
    }.ok;

    // -- 0. demo seed gave 3 todos, first done --
    check(view.read().todos.items.len == 3, &failures, "seed has 3 todos (got {d})", .{view.read().todos.items.len});
    check(view.read().todos.items[0].done, &failures, "first todo starts done", .{});

    check(win.focused.id == 0, &failures, "composer is not focused on launch", .{});
    // Click the composer through its real hit region before typing.
    var clicked_input = false;
    for (win.ui_frame.regions[0..win.ui_frame.region_count]) |region| {
        if (region.focus) |focus| {
            if (focus.id == view.read().input.focusHandle(null).id) {
                _ = null_backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = region.bounds.x + 10, .y = region.bounds.y + 10 }, .button = .left, .pressed = true } });
                clicked_input = true;
                break;
            }
        }
    }
    _ = app.step();
    check(clicked_input and win.focused.id == view.read().input.focusHandle(null).id, &failures, "click focuses composer", .{});
    // -- 1. type "Test task" into the composer.
    // Real backends emit one `.text` per physical press; `.key` alone
    // must never insert (that path is for bindings and editing keys).
    for ("Test task") |byte| {
        var text_ev = zui.platform.event.TextEvent{};
        text_ev.text[0] = byte;
        text_ev.len = 1;
        if (!null_backend.pushEvent(.{ .text = text_ev })) return error.SelftestQueueFull;
        _ = app.step();
    }
    check(std.mem.eql(u8, view.read().input.read().buffer[0..view.read().input.read().len], "Test task"), &failures, "typing fills composer", .{});

    // -- 1b. space keypress is consumed by the field: no toggle fires,
    // and (unlike the old .key-insertion path) no space is inserted --
    const selected_before = view.read().selected;
    const len_before = view.read().input.read().len;
    if (!null_backend.pushEvent(.{ .key = .{ .key = .space, .pressed = true } })) return error.SelftestQueueFull;
    _ = app.step();
    check(view.read().selected == selected_before, &failures, "space in field does not toggle", .{});
    check(view.read().input.read().len == len_before, &failures, "space key alone inserts nothing", .{});

    // -- 2. press Enter → "add" action appends the todo, clears input --
    if (!null_backend.pushEvent(.{ .key = .{ .key = .enter, .pressed = true } })) return error.SelftestQueueFull;
    _ = app.step();
    check(view.read().todos.items.len == 4, &failures, "enter adds todo (got {d})", .{view.read().todos.items.len});
    check(view.read().input.read().len == 0, &failures, "input cleared after add", .{});

    // -- 3. click the first checkbox → toggles it off --
    const box = findCheckbox(win, "Buy milk") orelse {
        check(false, &failures, "checkbox region found", .{});
        return error.SelftestFailures;
    };
    if (!null_backend.pushEvent(.{ .mouse = .{
        .pos = .{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 },
        .button = .left,
        .pressed = true,
    } })) return error.SelftestQueueFull;
    _ = app.step();
    check(!view.read().todos.items[0].done, &failures, "click toggles first todo off", .{});

    check(win.focused.id != view.read().input.focusHandle(null).id, &failures, "clicking a checkbox blurs composer", .{});

    _ = null_backend.pushEvent(.{ .key = .{ .key = .tab, .pressed = true } });
    _ = app.step();
    check(win.focused.id == view.read().input.focusHandle(null).id, &failures, "Tab focuses composer", .{});
    _ = null_backend.pushEvent(.{ .key = .{ .key = .escape, .pressed = true } });
    _ = app.step();
    check(win.focused.id == 0, &failures, "Escape releases focus", .{});
    for (0..8) |_| try view.updateWith("Another task", TodoApp.add);
    view.update(TodoApp.nextPage);
    view.update(TodoApp.nextPage);
    _ = app.step();
    check(view.read().page == 2, &failures, "long list reaches its final page", .{});
    // -- 4. UI re-rendered with regions intact --
    check(win.ui_frame.region_count > 0, &failures, "regions present after input (got {d})", .{win.ui_frame.region_count});

    if (failures > 0) return error.SelftestFailures;
    out("selftest: all checks passed\n", .{});
}

/// Locate the ~24x24 clickable checkbox region on the row showing `title`.
fn findCheckbox(win: *Window, title: []const u8) ?zui.Rect {
    var text_x: f32 = 0;
    var text_y: f32 = 0;
    var found_text = false;
    var idx: usize = 0;
    while (idx < win.ui_frame.node_count) : (idx += 1) {
        const n = &win.ui_frame.nodes[idx];
        if (n.kind == .text and std.mem.eql(u8, n.text_value, title)) {
            text_x = n.bounds.x;
            text_y = n.bounds.y + n.bounds.h / 2;
            found_text = true;
            break;
        }
    }
    if (!found_text) return null;
    for (win.ui_frame.regions[0..win.ui_frame.region_count]) |region| {
        if (region.listener == null) continue;
        const w = region.bounds.w;
        const h = region.bounds.h;
        if (w < 20 or w > 28 or h < 20 or h > 28) continue;
        const cy = region.bounds.y + h / 2;
        if (@abs(cy - text_y) < 24 and region.bounds.x < text_x) {
            return region.bounds;
        }
    }
    return null;
}

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

    const view = harness.new(TodoApp, .{});
    try view.updateWith("buy milk", TodoApp.add);
    try view.updateWith("write zig", TodoApp.add);
    try t.expectEqual(@as(usize, 2), view.read().todos.items.len);

    const id = view.read().todos.items[0].id;
    view.updateWith(id, TodoApp.toggle);
    try t.expect(view.read().todos.items[0].done);

    view.updateWith(.done, TodoApp.setFilter);
    try t.expect(!view.read().isVisible(view.read().todos.items[1]));

    view.update(TodoApp.clearCompleted);
    try t.expectEqual(@as(usize, 1), view.read().todos.items.len);
}

test "pagination clamps at list ends and resets on filtering" {
    var harness = try zui.TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const view = harness.new(TodoApp, .{});
    for (0..12) |_| try view.updateWith("Task", TodoApp.add);
    view.update(TodoApp.nextPage);
    try std.testing.expectEqual(@as(usize, 1), view.read().page);
    view.update(TodoApp.nextPage);
    view.update(TodoApp.nextPage);
    try std.testing.expectEqual(@as(usize, 2), view.read().page);
    view.updateWith(.active, TodoApp.setFilter);
    try std.testing.expectEqual(@as(usize, 0), view.read().page);
    view.update(TodoApp.previousPage);
    try std.testing.expectEqual(@as(usize, 0), view.read().page);
}
