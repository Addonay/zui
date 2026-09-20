//! Daybook: a small native task workspace built with ZUI.
const std = @import("std");
const zui = @import("zui");
const shadcn = @import("shadcn-zui");
const theme = @import("theme.zig");
const model = @import("model.zig");
const a11y = @import("a11y.zig");

const App = zui.App;
const Context = zui.Context;
const Window = zui.Window;
const Entity = zui.Entity;
const Element = zui.Element;
const FocusHandle = zui.FocusHandle;

const Todo = model.Todo;
const Filter = model.Filter;
const page_size = model.page_size;
const A11yTarget = a11y.Target;
pub const a11y_key = a11y.key;
const a11yFocusDispatch = a11y.focusDispatch;
const a11ySemanticActivate = a11y.semanticActivate;

// ---------------------------------------------------------------------------
// Root view.
// ---------------------------------------------------------------------------

pub const TodoApp = struct {
    pub const Options = struct {};

    alloc: std.mem.Allocator,
    todos: std.ArrayList(Todo),
    next_id: u32 = 1,
    filter: Filter = .all,
    selected: ?u32 = null,
    page: usize = 0,
    input: Entity(zui.TextField),
    focus_root: FocusHandle,
    a11y_targets: [64]A11yTarget = @splat(.{}),
    a11y_count: usize = 0,

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

    pub fn add(self: *@This(), title: []const u8, cx: *Context(@This())) !void {
        const owned_title = try zui.string(self.alloc, title);
        errdefer owned_title.release();
        try self.todos.append(self.alloc, .{ .id = self.next_id, .title = owned_title, .done = false });
        self.selected = self.next_id;
        self.next_id += 1;
        cx.notify();
    }

    pub fn toggle(self: *@This(), id: u32, cx: *Context(@This())) void {
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

    pub fn setFilter(self: *@This(), f: Filter, cx: *Context(@This())) void {
        self.filter = f;
        self.page = 0;
        cx.notify();
    }

    pub fn clearCompleted(self: *@This(), cx: *Context(@This())) void {
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

    fn counts(self: *const @This()) model.Counts {
        return model.counts(self.todos.items);
    }

    pub fn isVisible(self: *const @This(), t: Todo) bool {
        return model.visible(self.filter, t);
    }

    const A11ySlot = struct {
        handle: FocusHandle,
        target: *A11yTarget,
    };

    /// Claim one per-frame activation slot for `key` and return its focus
    /// handle plus handler target. The focus id IS the stable key, so the
    /// tab stop, the semantic node and the bridge snapshot id agree.
    fn a11ySlot(self: *@This(), cx: *Context(@This()), key: u64, listener: zui.Listener) A11ySlot {
        std.debug.assert(self.a11y_count < self.a11y_targets.len);
        const owner = cx.focusHandle();
        const slot = &self.a11y_targets[self.a11y_count];
        self.a11y_count += 1;
        if (slot.key != key) slot.space_pending = false;
        slot.key = key;
        slot.listener = listener;
        if (owner.owner_store) |store| zui.elements.element.currentFrame().trackOwner(slot, store, owner.id, owner.owner_generation);
        // Hand-built handle: the tab-stop id is the stable control key, NOT
        // an entity id, so it carries no owner gate (FocusHandle.isLive
        // probes `id` as an entity). Liveness still holds: hit regions gate
        // on the click listener's TodoApp owner, and semantic perform gates
        // on the tracked slot owner above.
        return .{
            .handle = .{
                .id = @truncate(key),
                .target = slot,
                .event_fn = a11yFocusDispatch,
            },
            .target = slot,
        };
    }

    fn isFocused(window: *Window, handle: FocusHandle) bool {
        return window.focused.eql(handle);
    }

    /// Focus ring: a transparent 1px border that turns accent when focused,
    /// so keyboard position is always visible without shifting layout.
    fn focusRing(el: Element, focused: bool) Element {
        return el.border_1().border_color(if (focused) theme.accent else zui.transparent());
    }

    fn composer(self: *@This(), window: *Window) Element {
        const input_handle = self.input.focusHandle(null);
        const draft = self.input.read();
        return zui.div().flex_1()
            .keyed(a11y_key.composer)
            .withFocus(input_handle)
            .semantic(.{
                .role = .text_input,
                .name = "New task",
                .text_value = draft.buffer[0..draft.len],
                .states = .{ .focused = isFocused(window, input_handle) },
                .actions = .{ .focus = true },
            })
            .child(self.input);
    }

    fn uiButton(self: *@This(), window: *Window, cx: *Context(@This()), key: u64, value: []const u8, listener: zui.Listener, primary: bool, disabled: bool) Element {
        const slot = self.a11ySlot(cx, key, listener);
        const focused = isFocused(window, slot.handle);
        var button = shadcn.Button.init(value)
            .variant(if (primary) .primary else .outline)
            .size(.md)
            .disabled(disabled);
        if (buttonIcon(value)) |icon| button = button.leadingIcon(icon);
        return focusRing(zui.div().items_center().justify_center().cursor_pointer()
            .keyed(key)
            .withFocus(slot.handle)
            .semantic(.{
                .role = .button,
                .name = value,
                .states = .{ .disabled = disabled, .focused = focused },
                .actions = .{ .activate = !disabled, .focus = true },
                .handler = .{ .target = slot.target, .call_fn = a11ySemanticActivate },
            })
            .on_click(listener), focused)
            .child(button.render());
    }

    fn buttonIcon(value: []const u8) ?shadcn.components.icon.Name {
        if (std.mem.eql(u8, value, "Add task")) return shadcn.components.icon.semantic.plus;
        if (std.mem.eql(u8, value, "Clear completed")) return shadcn.components.icon.semantic.check;
        if (std.mem.eql(u8, value, "Previous")) return shadcn.components.icon.semantic.chevron_left;
        if (std.mem.eql(u8, value, "Next")) return shadcn.components.icon.semantic.chevron_right;
        return null;
    }

    fn filterTab(self: *@This(), window: *Window, cx: *Context(@This()), filter: Filter, current: Filter, count: usize) Element {
        const key: u64 = switch (filter) {
            .all => a11y_key.filter_all,
            .active => a11y_key.filter_active,
            .done => a11y_key.filter_done,
        };
        const listener = cx.listenerWith(Filter, TodoApp, TodoApp.setFilter, filter);
        const slot = self.a11ySlot(cx, key, listener);
        const focused = isFocused(window, slot.handle);
        const icon = filterIcon(filter);
        return focusRing(zui.div().flex_row().h(40).px(12).gap(10).items_center().rounded_lg().cursor_pointer()
            .bg(if (filter == current) theme.moss_soft else theme.sidebar).hover_bg(theme.paper_hover)
            .keyed(key)
            .withFocus(slot.handle)
            .semantic(.{
                .role = .button,
                .name = filter.label(),
                .states = .{ .selected = filter == current, .focused = focused },
                .actions = .{ .activate = true, .focus = true },
                .handler = .{ .target = slot.target, .call_fn = a11ySemanticActivate },
            })
            .on_click(listener), focused)
            .child(shadcn.components.icon.render(icon, 15, if (filter == current) theme.terracotta else theme.muted))
            .child(label(filter.label(), 13, if (filter == current) theme.accent else theme.muted))
            .child(zui.textFmt("{d}", .{count}, .{ .font = theme.font.body, .size = 12, .line_height = 18, .color = theme.muted }));
    }

    fn filterIcon(filter: Filter) shadcn.components.icon.Name {
        return switch (filter) {
            .all => shadcn.components.icon.Name.list,
            .active => shadcn.components.icon.Name.circle,
            .done => shadcn.components.icon.semantic.check,
        };
    }

    fn winChrome(self: *@This(), window: *Window, cx: *Context(@This()), key: u64, value: []const u8, name: []const u8, comptime handler: anytype) Element {
        const listener = cx.listener(TodoApp, handler);
        const slot = self.a11ySlot(cx, key, listener);
        const focused = isFocused(window, slot.handle);
        return focusRing(zui.div().w(34).h(30).rounded_lg().items_center().justify_center().cursor_pointer()
            .hover_bg(theme.card_hover)
            .keyed(key)
            .withFocus(slot.handle)
            .semantic(.{
                .role = .button,
                .name = name,
                .states = .{ .focused = focused },
                .actions = .{ .activate = true, .focus = true },
                .handler = .{ .target = slot.target, .call_fn = a11ySemanticActivate },
            })
            .on_click(listener), focused).child(label(value, 15, theme.muted));
    }

    // -----------------------------------------------------------------------
    // Render — pure description of UI. No mutation here except via listeners.
    // -----------------------------------------------------------------------

    pub fn render(self: *@This(), window: *Window, cx: *Context(@This())) Element {
        self.a11y_count = 0; // per-frame activation slots; see a11ySlot
        const c = model.counts(self.todos.items);
        const wide = window.bounds.size.w >= 800;
        const content_width = @min(720, @max(0, window.bounds.size.w - 40));
        var content = zui.div().flex_col().w(content_width).p(if (wide) 40 else 20).gap(16);
        content = content.child(zui.div().flex_row().items_end().justify_between()
            .child(zui.div().flex_col().gap(4)
                .child(theme.mono("TODAY / TASKS", 10, theme.terracotta))
                .child(theme.display("Today", 32, theme.ink))
                .child(theme.label("A small list for what matters next.", 14, theme.muted)))
            .child(zui.textFmt("{d} open", .{c.left}, .{ .font = theme.font.body, .size = 15, .line_height = 20, .color = theme.terracotta })));
        content = content.child(zui.div().flex_col().gap(8)
            .child(theme.mono("ADD TO THE LIST", 10, theme.muted))
            .child(zui.div().flex_row().items_center().gap(8).p(6).rounded_lg().bg(theme.paper).border_1().border_color(theme.line)
            .child(zui.div().w(26).h(26).items_center().justify_center().rounded_lg().bg(theme.terracotta_soft)
                .child(shadcn.components.icon.render(shadcn.components.icon.semantic.plus, 16, theme.terracotta)))
            .child(self.composer(window))
            .child(self.uiButton(window, cx, a11y_key.add, "Add task", cx.listener(@This(), addFromDraft), true, false))));
        content = content.child(zui.div().flex_row().gap(8)
            .child(self.filterTab(window, cx, .all, self.filter, c.total))
            .child(self.filterTab(window, cx, .active, self.filter, c.left))
            .child(self.filterTab(window, cx, .done, self.filter, c.done)));
        content = content.child(zui.div().flex_row().items_center().justify_between()
            .child(theme.display(switch (self.filter) {
                .all => "Tasks",
                .active => "Open",
                .done => "Done",
            }, 20, theme.ink))
            .child(zui.textFmt("{d} of {d} complete", .{ c.done, c.total }, .{ .font = theme.font.body, .size = 11, .line_height = 18, .color = theme.muted })));
        content = content.child(self.renderList(window, cx));
        content = content.child(zui.div().flex_row().items_center().justify_between()
            .child(theme.label("Select a task · Space completes it", 12, theme.muted))
            .child(self.uiButton(window, cx, a11y_key.clear, "Clear completed", cx.listener(@This(), clearCompleted), false, false)));
        return zui.div().flex_col().size_full().bg(theme.bg)
            .child(zui.div().flex_row().items_center().h(56).px(22).gap(10).bg(theme.sidebar).border_b_1().border_color(theme.line)
                .on_mouse_down(cx.listener(@This(), beginDrag))
                .on_double_click(cx.listener(@This(), toggleMaximize))
                .child(zui.div().w(4).h(24).bg(theme.terracotta))
                .child(theme.display("daybook", 18, theme.ink))
                .child(zui.spacer())
                .child(self.winChrome(window, cx, a11y_key.win_min, "—", "Minimize", minimizeWindow))
                .child(self.winChrome(window, cx, a11y_key.win_max, if (window.isMaximized()) "▢" else "□", if (window.isMaximized()) "Restore" else "Maximize", toggleMaximize))
                .child(self.winChrome(window, cx, a11y_key.win_close, "×", "Close", closeWindow)))
            .child(zui.div().flex_1().w_full().items_center().child(content));
    }

    fn renderList(self: *@This(), window: *Window, cx: *Context(@This())) Element {
        var count: usize = 0;
        for (self.todos.items) |todo| {
            if (self.isVisible(todo)) {
                count += 1;
            }
        }
        if (count == 0) return zui.div().flex_col().h(240).items_center().justify_center().gap(10).rounded_lg().bg(theme.paper).border_1().border_color(theme.line)
            .keyed(a11y_key.empty)
            .semantic(.{ .role = .group, .name = "No tasks" })
            .child(theme.display(if (self.filter == .done) "Nothing finished yet." else if (self.filter == .active) "Everything is checked off." else "Start with one small thing.", 24, theme.ink))
            .child(theme.label(if (self.filter == .all) "Write a task above and it will land here." else "Choose All to see your whole list.", 13, theme.muted));
        const current_page = @min(self.page, (count - 1) / page_size);
        const last_page = (count - 1) / page_size;
        var list = zui.div().flex_col().gap(8)
            .keyed(a11y_key.list)
            .semantic(.{ .role = .list, .name = "Tasks" });
        var index: usize = 0;
        for (self.todos.items) |todo| {
            if (!self.isVisible(todo)) continue;
            if (index >= current_page * page_size and index < (current_page + 1) * page_size) list = list.child(self.renderRow(window, cx, todo));
            index += 1;
        }
        if (count > page_size) list = list.child(zui.div().flex_row().items_center().justify_between()
            .child(self.uiButton(window, cx, a11y_key.prev, "Previous", cx.listener(@This(), previousPage), false, current_page == 0))
            .child(zui.textFmt("Page {d} of {d}", .{ current_page + 1, (count + page_size - 1) / page_size }, .{ .size = 12, .color = theme.muted }))
            .child(self.uiButton(window, cx, a11y_key.next, "Next", cx.listener(@This(), nextPage), false, current_page == last_page)));
        return list;
    }

    fn renderRow(self: *@This(), window: *Window, cx: *Context(@This()), todo: Todo) Element {
        const selected = self.selected == todo.id;
        const row_key = a11y_key.row(todo.id);
        const check_key = a11y_key.check(todo.id);
        const del_key = a11y_key.del(todo.id);
        const select_listener = cx.listenerWith(u32, @This(), selectRow, todo.id);
        const toggle_listener = cx.listenerWith(u32, @This(), toggle, todo.id);
        const remove_listener = cx.listenerWith(u32, @This(), remove, todo.id);
        const row_slot = self.a11ySlot(cx, row_key, select_listener);
        const check_slot = self.a11ySlot(cx, check_key, toggle_listener);
        const del_slot = self.a11ySlot(cx, del_key, remove_listener);
        const row_focused = isFocused(window, row_slot.handle);
        const check_focused = isFocused(window, check_slot.handle);
        const del_focused = isFocused(window, del_slot.handle);
        const checkbox = shadcn.Checkbox.init().checked(todo.done).size(26).onToggle(toggle_listener).render();
        const delete_button = shadcn.IconButton.init(shadcn.components.icon.semantic.trash).variant(.ghost).size(32, 16).render();
        var del_name_buf: [128]u8 = undefined;
        const del_name = std.fmt.bufPrint(&del_name_buf, "Delete {s}", .{todo.title.slice()}) catch "Delete";
        return zui.div().flex_row().items_center().gap(12).p(12).rounded_lg()
            .bg(if (selected) theme.terracotta_soft else theme.paper)
            .border_1().border_color(if (selected or row_focused) theme.accent else theme.border)
            .keyed(row_key)
            .withFocus(row_slot.handle)
            .semantic(.{
                .role = .listitem,
                .name = todo.title.slice(),
                .states = .{ .selected = selected, .focused = row_focused },
                .actions = .{ .activate = true, .focus = true },
                .handler = .{ .target = row_slot.target, .call_fn = a11ySemanticActivate },
            })
            .hover_bg(theme.paper_hover).cursor_pointer()
            .on_click(select_listener)
            .child(zui.div().items_center().justify_center()
                .keyed(check_key)
                .withFocus(check_slot.handle)
                .semantic(.{
                    .role = .checkbox,
                    .name = todo.title.slice(),
                    .states = .{ .checked = todo.done, .focused = check_focused },
                    .actions = .{ .activate = true, .focus = true },
                    .handler = .{ .target = check_slot.target, .call_fn = a11ySemanticActivate },
                })
                .items_center().justify_center().cursor_pointer()
                .on_click(toggle_listener)
                .child(checkbox))
            .child(zui.div().flex_1().child(zui.text(todo.title.slice(), .{
                .font = theme.font.sans,
                .size = 15,
                .line_height = 22,
                .color = if (todo.done) theme.muted else theme.text,
                .strike = todo.done,
            })))
            .child(focusRing(zui.div().items_center().justify_center().cursor_pointer()
            .keyed(del_key)
            .withFocus(del_slot.handle)
            .semantic(.{
                .role = .button,
                .name = del_name,
                .states = .{ .focused = del_focused },
                .actions = .{ .activate = true, .focus = true },
                .handler = .{ .target = del_slot.target, .call_fn = a11ySemanticActivate },
            })
            .on_click(remove_listener), del_focused)
            .child(delete_button));
    }

    pub fn previousPage(self: *@This(), cx: *Context(@This())) void {
        self.page -|= 1;
        cx.notify();
    }
    pub fn nextPage(self: *@This(), cx: *Context(@This())) void {
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

// ---------------------------------------------------------------------------
// App wiring — mirrors gpui's `application().run(|cx| cx.open_window(...))`.
// ---------------------------------------------------------------------------

fn preloadShadcnIcons(cache: *zui.images.Cache) !void {
    inline for (.{
        shadcn.components.icon.semantic.plus,
        shadcn.components.icon.semantic.check,
        shadcn.components.icon.Name.list,
        shadcn.components.icon.Name.circle,
        shadcn.components.icon.semantic.trash,
        shadcn.components.icon.semantic.chevron_left,
        shadcn.components.icon.semantic.chevron_right,
    }) |icon| {
        _ = try cache.assets.preloadBytes(shadcn.components.icon.bytes(icon), 0);
    }
}

fn buildRoot(window: *Window, vcx: *Context(TodoApp)) Entity(TodoApp) {
    const view = vcx.new(TodoApp, .{});
    if (window.images) |cache| preloadShadcnIcons(cache) catch |err| std.log.err("shadcn icon preload: {s}", .{@errorName(err)});
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
    seedDemo(view, std.c.getenv("ZUI_TODO_DEMO") != null);
    return view;
}

/// Optional screenshot/selftest seed. A normal launch starts empty so the
/// empty-state guidance is the first-run experience.
fn seedDemo(view: Entity(TodoApp), enabled: bool) void {
    if (!enabled) return;
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
                        .custom => 'X',
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
    var renderer = zui.gpu.vellz.Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.render(pixels, width, height, .rgba32, theme.bg, &win.scene, app.glyphPixels(), app.imagePixels());

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
    if (!null_backend.pushEvent(.{ .key = .{ .key = .space, .pressed = false } })) return error.SelftestQueueFull;
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

    // -- 3b. every annotated control is a Tab stop: cycle the full order and
    // confirm the composer, Add, a row checkbox and Clear are all reached.
    const input_id = view.read().input.focusHandle(null).id;
    var saw_composer = false;
    var saw_add = false;
    var saw_clear = false;
    var saw_check = false;
    const first_check = a11y_key.check(view.read().todos.items[0].id);
    for (0..48) |_| {
        _ = null_backend.pushEvent(.{ .key = .{ .key = .tab, .pressed = true } });
        _ = app.step();
        const fid = win.focused.id;
        if (fid == input_id) saw_composer = true;
        if (fid == a11y_key.add) saw_add = true;
        if (fid == a11y_key.clear) saw_clear = true;
        if (fid == first_check) saw_check = true;
    }
    check(saw_composer and saw_add and saw_clear and saw_check, &failures, "tab cycles all annotated stops", .{});
    // Shift-Tab moves without sticking.
    const before_shift = win.focused.id;
    _ = null_backend.pushEvent(.{ .key = .{ .key = .tab, .pressed = true, .modifiers = .{ .shift = true } } });
    _ = app.step();
    check(win.focused.id != before_shift, &failures, "shift-tab moves focus", .{});
    // -- 3c. keyboard operability: focus a row delete through semantics,
    // then Space removes that row through the focused key path.
    const del_key = a11y_key.del(view.read().todos.items[0].id);
    check(win.ui_frame.semantic_tree.perform(del_key, .{ .action = .focus }, win), &failures, "semantic focus reaches delete", .{});
    _ = app.step();
    if (!null_backend.pushEvent(.{ .key = .{ .key = .space, .pressed = true } })) return error.SelftestQueueFull;
    _ = app.step();
    if (!null_backend.pushEvent(.{ .key = .{ .key = .space, .pressed = false } })) return error.SelftestQueueFull;
    _ = app.step();
    check(view.read().todos.items.len == 3, &failures, "space on focused delete removes row (got {d})", .{view.read().todos.items.len});
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

pub fn a11yFixture() !struct {
    app: App,
    win: *Window,
    view: Entity(TodoApp),
} {
    const t = std.testing;
    var app = try App.initHeadless(t.allocator);
    selftest_view = null;
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 960, .h = 800 } },
        .title = "Daybook",
        .min_size = zui.size(540, 740),
        .chrome = .custom,
    }, selftestBuildRoot);
    const view = selftest_view orelse return error.SelftestNoView;
    seedDemo(view, true);
    try view.updateWith("Buy milk", TodoApp.add);
    try view.updateWith("Write zig", TodoApp.add);
    view.updateWith(view.read().todos.items[0].id, TodoApp.toggle);
    _ = app.step();
    return .{ .app = app, .win = win, .view = view };
}
