//! ZUI Todo — a retained, GPUI-inspired example.
//!
//! This is the design target for `zui`, a naive Zig port of GPUI's ideas:
//!   - one foreground thread owns all state (`App`, `Context`, `Window`)
//!   - state lives in `Entity(T)` handles, views are `T` with `render()`
//!   - UI is built from small value-type elements (`div()`, `text()`, ...)
//!     with Tailwind-like chained styles, laid out with flexbox
//!   - interaction is `cx.listener()` + `on_click` / `on_action`, then `cx.notify()`
//!
//! It exercises the naive retained core: entities, flex elements, software
//! painting, focus, pointer listeners, key bindings, and a text field.
//!
//! Run:
//!   zig build run-todo

const std = @import("std");
const zui = @import("zui");

const App = zui.App;
const Context = zui.Context;
const Window = zui.Window;
const Entity = zui.Entity;
const Element = zui.Element;
const FocusHandle = zui.FocusHandle;

// ---------------------------------------------------------------------------
// Theme — fashionable dark, one accent gradient, generous radius.
// ---------------------------------------------------------------------------

const theme = struct {
    const bg = zui.hex(0x0e0e13);
    const panel = zui.hex(0x17181f);
    const card = zui.hex(0x1e1f2a);
    const card_hover = zui.hex(0x262736);
    const border = zui.hex(0xffffff18);
    const text = zui.hex(0xf2f2f5);
    const muted = zui.hex(0x9b9bab);
    const faint = zui.hex(0x5d5d6e);
    const accent = zui.hex(0x7c5cff);
    const accent_hi = zui.hex(0x46d5e8);
    const good = zui.hex(0x3ddc84);
    const danger = zui.hex(0xff5d5d);

    // One sans stack, one mono stack. Every size below is paired with a
    // line height — bare sizes with default leading are what made the
    // old UI look off — and numerals always render in mono tabular so
    // counts don't jitter as they change.
    const font = struct {
        const sans = "Inter, SF Pro Text, Segoe UI, Noto Sans, sans-serif";
        const mono = "JetBrains Mono, SF Mono, Cascadia Code, Menlo, monospace";
    };
};

// ---------------------------------------------------------------------------
// Model — plain Zig, no UI imports, trivially testable.
// ---------------------------------------------------------------------------

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

    alloc: std.mem.Allocator,
    todos: std.ArrayList(Todo),
    next_id: u32 = 1,
    filter: Filter = .all,
    selected: ?u32 = null,
    input: Entity(zui.TextField),
    focus_root: FocusHandle,

    pub fn init(cx: *Context(@This()), _: Options) @This() {
        return .{
            .alloc = cx.allocator(),
            .todos = .empty,
            .input = cx.new(zui.TextField, .{
                .placeholder = "What needs doing?  Press Enter to add",
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

        return zui.div()
            .flex_col()
            .size_full()
            .bg(theme.bg)
            .child(self.renderBackdrop())
            .child(self.renderTitlebar(window, cx))
            .child(zui.div()
            .flex_col()
            .flex_1()
            .w_full()
            .items_center()
            .child(zui.div()
            .flex_col()
            .gap(16)
            .w(560)
            .max_w_full()
            .p(24)
            .child(self.renderHeader(c.total, c.done, c.left))
            .child(self.renderComposer(cx))
            .child(self.renderFilterBar(c, cx))
            .child(self.renderList(cx))
            .child(self.renderFooter(c, cx))));
    }

    // Custom chrome: icon + title on the left, window controls on the
    // right. The bar itself starts a native drag; buttons hit-test first
    // (deepest child wins) so clicks on them never start a drag.
    fn renderTitlebar(self: *@This(), window: *Window, cx: *Context(@This())) Element {
        _ = self;
        const maximized = window.isMaximized();
        return zui.div()
            .flex_row()
            .items_center()
            .h(44)
            .w_full()
            .pl(12)
            .pr(8)
            .gap(8)
            .bg(theme.panel)
            .border_b_1()
            .border_color(theme.border)
            .on_mouse_down(cx.listener(@This(), beginDrag))
            .on_double_click(cx.listener(@This(), toggleMaximize))
            .child(appIcon())
            .child(zui.text("Tasks", .{ .font = theme.font.sans, .size = 13, .line_height = 18, .weight = .semibold, .color = theme.text }))
            .child(zui.spacer())
            .child(winButton(cx, "—", TodoApp.minimizeWindow, false))
            .child(winButton(cx, if (maximized) "▢" else "□", TodoApp.toggleMaximize, false))
            .child(winButton(cx, "×", TodoApp.closeWindow, true));
    }

    fn beginDrag(self: *@This(), window: *Window, cx: *Context(@This())) void {
        _ = self;
        _ = cx;
        window.startDrag();
    }

    fn closeWindow(self: *@This(), window: *Window, cx: *Context(@This())) void {
        _ = self;
        _ = cx;
        window.close();
    }

    fn minimizeWindow(self: *@This(), window: *Window, cx: *Context(@This())) void {
        _ = self;
        _ = cx;
        window.minimize();
    }

    fn toggleMaximize(self: *@This(), window: *Window, cx: *Context(@This())) void {
        _ = self;
        window.toggleMaximize();
        cx.notify(); // re-render so the □/▢ glyph swaps
    }

    fn renderBackdrop(self: *@This()) Element {
        _ = self;
        // Naive v0: two blurred gradient blobs. The real painter can just
        // draw two large rounded quads with blur; no shader graph needed.
        return zui.div()
            .absolute()
            .inset(0)
            .child(zui.div().absolute().top(-120).left(-80).size(420).rounded_full().bg(theme.accent).opacity(0.22).blur(120))
            .child(zui.div().absolute().top(-60).right(-100).size(380).rounded_full().bg(theme.accent_hi).opacity(0.16).blur(120));
    }

    fn renderHeader(self: *@This(), total: usize, done: usize, left: usize) Element {
        _ = left;
        return zui.div().flex_col().gap(10).pt(28)
            .child(zui.div().flex_row().items_center().justify_between()
            .child(zui.div().flex_row().items_center().gap(10)
                .child(zui.div().size(36).rounded_xl().bg_gradient(theme.accent, theme.accent_hi).items_center().justify_center()
                    .child(zui.text("✦", .{ .font = theme.font.sans, .size = 18, .line_height = 18, .color = zui.white() })))
                .child(zui.div().flex_col()
                .child(display("Tasks"))
                .child(caption(zui.formatToday(), theme.muted))))
            .child(zui.div().flex_row().items_center().gap(8)
            .child(numeral("{d}/{d} done", .{ done, total }))
            .child(zui.progressBar(self.progress(), 96))));
    }

    fn renderComposer(self: *@This(), cx: *Context(@This())) Element {
        return zui.div()
            .flex_row()
            .items_center()
            .gap(10)
            .p(10)
            .rounded_2xl()
            .bg(theme.panel)
            .border_1()
            .border_color(theme.border)
            .shadow_lg()
            .child(zui.div().flex_1()
                .child(self.input))
            .child(zui.div()
            .h(40)
            .px(18)
            .rounded_xl()
            .bg_gradient(theme.accent, theme.accent_hi)
            .items_center()
            .justify_center()
            .cursor_pointer()
            .hover_bg(theme.accent_hi)
            .on_click(cx.listener(@This(), addFromDraft))
            .child(zui.text("+  Add", .{ .font = theme.font.sans, .size = 14, .line_height = 20, .weight = .semibold, .color = zui.white() })));
    }

    fn renderFilterBar(self: *@This(), c: anytype, cx: *Context(@This())) Element {
        return zui.div().flex_row().items_center().gap(8)
            .child(filterPill(cx, .all, self.filter, c.total))
            .child(filterPill(cx, .active, self.filter, c.left))
            .child(filterPill(cx, .done, self.filter, c.done))
            .child(zui.spacer())
            .child(numeral("{d} left", .{c.left}));
    }

    fn renderList(self: *@This(), cx: *Context(@This())) Element {
        var visible_count: usize = 0;
        for (self.todos.items) |t| {
            if (self.isVisible(t)) visible_count += 1;
        }

        if (self.todos.items.len == 0) {
            return emptyState("A calm, empty list", "Capture your first task above and press Enter.");
        }
        if (visible_count == 0) {
            return emptyState("Nothing under this filter", "Switch filters to see the rest of your tasks.");
        }

        return zui.div().flex_col().gap(10).children(self.todos.items, @This(), renderRow, cx);
    }

    fn renderRow(self: *@This(), todo: Todo, cx: *Context(@This())) ?Element {
        if (!self.isVisible(todo)) return null;
        const is_selected = if (self.selected) |s| s == todo.id else false;

        return zui.div()
            .flex_row()
            .items_center()
            .gap(12)
            .p(12)
            .pl(14)
            .rounded_2xl()
            .bg(if (is_selected) theme.card_hover else theme.card)
            .border_1()
            .border_color(if (is_selected) theme.accent else theme.border)
            .hover_bg(theme.card_hover)
            .on_click(cx.listenerWith(u32, @This(), selectRow, todo.id))
            .child(checkBox(cx, self, todo))
            .child(zui.div().flex_col().flex_1().gap(2)
                .child(zui.text(todo.title.slice(), .{
                    .font = theme.font.sans,
                    .size = 15,
                    .line_height = 22,
                    .color = if (todo.done) theme.faint else theme.text,
                    .strike = todo.done,
                }))
                .child(zui.textFmt("#{d}  ·  tap space to toggle", .{todo.id}, .{ .font = theme.font.mono, .size = 12, .line_height = 16, .color = theme.faint })))
            .child(zui.div()
            .size(30)
            .rounded_lg()
            .items_center()
            .justify_center()
            .text_color(theme.muted)
            .hover_bg(theme.danger)
            .cursor_pointer()
            .on_click(cx.listenerWith(u32, @This(), remove, todo.id))
            .child(zui.text("×", .{ .font = theme.font.sans, .size = 18, .line_height = 18 })));
    }

    fn selectRow(self: *@This(), id: u32, window: *Window, cx: *Context(@This())) void {
        self.selected = id;
        window.focus(self.focus_root, cx);
        cx.notify();
    }

    fn renderFooter(self: *@This(), c: anytype, cx: *Context(@This())) Element {
        return zui.div().flex_col().gap(10).pt(4)
            .child(zui.progressTrack(self.progress()))
            .child(zui.div().flex_row().items_center().justify_between()
            .child(numeral("{d} of {d} complete", .{ c.done, c.total }))
            .child(zui.div()
            .px(12)
            .h(32)
            .rounded_lg()
            .items_center()
            .justify_center()
            .border_1()
            .border_color(theme.border)
            .text_color(theme.muted)
            .cursor_pointer()
            .hover_border(theme.faint)
            .on_click(cx.listener(@This(), clearCompleted))
            .child(zui.text("Clear completed", .{ .font = theme.font.sans, .size = 13, .line_height = 18 }))));
    }

    pub fn focusHandle(self: *@This(), cx: *Context(@This())) FocusHandle {
        _ = cx;
        return self.focus_root;
    }
};

// ---------------------------------------------------------------------------
// Small components — all value types, `renderOnce`-style.
// ---------------------------------------------------------------------------

// Type helpers: every size ships with a line height and a stack, so text
// never falls back to platform-default leading.
fn display(str: []const u8) Element {
    return zui.text(str, .{ .font = theme.font.sans, .size = 26, .line_height = 32, .tracking = -0.4, .weight = .bold, .color = theme.text });
}

fn caption(str: []const u8, color: @TypeOf(theme.text)) Element {
    return zui.text(str, .{ .font = theme.font.sans, .size = 13, .line_height = 18, .color = color });
}

fn numeral(comptime fmt: []const u8, args: anytype) Element {
    return zui.textFmt(fmt, args, .{ .font = theme.font.mono, .size = 12, .line_height = 16, .color = theme.muted });
}

fn appIcon() Element {
    return zui.div().size(22).rounded_lg().bg_gradient(theme.accent, theme.accent_hi).items_center().justify_center()
        .child(zui.text("✓", .{ .font = theme.font.sans, .size = 13, .line_height = 13, .weight = .bold, .color = zui.white() }));
}

fn winButton(cx: *Context(TodoApp), glyph: []const u8, handler: fn (*TodoApp, *Window, *Context(TodoApp)) void, danger: bool) Element {
    return zui.div()
        .w(40)
        .h(28)
        .rounded_lg()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .bg(zui.transparent())
        .hover_bg(if (danger) theme.danger else theme.card_hover)
        .on_click(cx.listener(TodoApp, handler))
        .child(zui.text(glyph, .{ .font = theme.font.sans, .size = 13, .line_height = 13, .color = theme.muted }));
}

fn filterPill(cx: *Context(TodoApp), f: Filter, active_filter: Filter, n: usize) Element {
    const active = f == active_filter;
    return zui.div()
        .flex_row()
        .items_center()
        .gap(8)
        .h(32)
        .px(14)
        .rounded_full()
        .cursor_pointer()
        .bg(if (active) theme.text else theme.panel)
        .text_color(if (active) theme.bg else theme.muted)
        .border_1()
        .border_color(if (active) theme.text else theme.border)
        .hover_bg(if (active) theme.text else theme.card_hover)
        .on_click(cx.listenerWith(Filter, TodoApp, TodoApp.setFilter, f))
        .child(zui.text(f.label(), .{ .font = theme.font.sans, .size = 13, .line_height = 18, .weight = .medium }))
        .child(zui.div()
        .px(8)
        .h(20)
        .rounded_full()
        .bg(if (active) zui.hex(0x00000022) else zui.hex(0xffffff14))
        .items_center()
        .justify_center()
        .child(zui.textFmt("{d}", .{n}, .{ .font = theme.font.mono, .size = 12, .line_height = 16, .weight = .semibold })));
}

fn checkBox(cx: *Context(TodoApp), app: *TodoApp, todo: Todo) Element {
    _ = app;
    return zui.div()
        .size(24)
        .rounded_full()
        .border_2()
        .border_color(if (todo.done) theme.good else theme.faint)
        .bg(if (todo.done) theme.good else zui.transparent())
        .items_center()
        .justify_center()
        .cursor_pointer()
        .on_click(cx.listenerWith(u32, TodoApp, TodoApp.toggle, todo.id))
        .child(zui.when(todo.done, zui.text("✓", .{ .font = theme.font.sans, .size = 14, .line_height = 14, .color = zui.hex(0x0b1510), .weight = .bold })));
}

fn emptyState(title: []const u8, body: []const u8) Element {
    return zui.div()
        .flex_col()
        .items_center()
        .justify_center()
        .gap(8)
        .py(48)
        .rounded_2xl()
        .bg(theme.panel)
        .border_dashed()
        .border_1()
        .border_color(theme.border)
        .child(zui.div().size(48).rounded_2xl().bg(theme.card).items_center().justify_center()
            .child(zui.text("○", .{ .font = theme.font.sans, .size = 22, .line_height = 22, .color = theme.faint })))
        .child(zui.text(title, .{ .font = theme.font.sans, .size = 15, .line_height = 22, .weight = .semibold, .color = theme.text }))
        .child(zui.text(body, .{ .font = theme.font.sans, .size = 13, .line_height = 20, .color = theme.muted }));
}

// ---------------------------------------------------------------------------
// App wiring — mirrors gpui's `application().run(|cx| cx.open_window(...))`.
// ---------------------------------------------------------------------------

fn onOpen(cx: *App) void {
    const bounds = zui.Bounds.centered(null, zui.size(680, 760), cx);
    _ = cx.openWindow(.{
        .bounds = bounds,
        .title = "Tasks — zui",
        .min_size = zui.size(440, 520),
        // Native titlebar off: renderTitlebar above draws our own chrome
        // (icon, title, min/max/close) so the app looks identical on
        // Wayland, X11, Win32, and Cocoa.
        .chrome = .custom,
    }, struct {
        fn build(window: *Window, vcx: *Context(TodoApp)) Entity(TodoApp) {
            // Focus the composer on launch, like gpui's `window.focus(...)`.
            const view = vcx.new(TodoApp, .{});
            window.focus(view.read().input.focusHandle(vcx), vcx);
            vcx.bindKeys(TodoApp, &.{
                .{ .key = "enter", .action = "add" },
                .{ .key = "space", .action = "toggle-selected" },
                .{ .key = "backspace", .action = "delete-selected" },
            });
            window.on_action("add", view, TodoApp.addFromDraft);
            window.on_action("toggle-selected", view, TodoApp.toggleSelected);
            window.on_action("delete-selected", view, TodoApp.removeSelected);
            return view;
        }
    }.build) catch |err| std.log.err("open window: {s}", .{@errorName(err)});
    cx.activate(true);
}

pub fn main(init: std.process.Init) !void {
    var app = try App.init(init.gpa);
    defer app.deinit();

    app.run(onOpen);
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
