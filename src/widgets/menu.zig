//! Menu and select-only combobox share a bounded, keyboard-operated popup.
//! Items are borrowed; keys must be unique. Submenus are bounded to one child
//! level so keyboard and pointer navigation remain deterministic.
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const ov = @import("overlay.zig");
const theme = @import("theme.zig");
const behavior = @import("behavior.zig");
pub const Menu = Choice(false);
pub const Select = Choice(true);
pub const ComboBox = Select;
pub const ContextMenu = Menu;
pub const Item = struct { key: u64, label: []const u8, disabled: bool = false, checked: ?bool = null, submenu: bool = false, children: ?[]Item = null };
pub fn Choice(comptime select: bool) type {
    return struct {
        const Self = @This();
        pub const Options = struct {
            key: u64,
            label: []const u8,
            items: []Item,
            width: f32 = 200,
            row_height: f32 = 32,
            visible_rows: usize = 8,
            on_change: ?e.Listener = null,
            tokens: ?theme.Theme = null,
        };
        options: Options,
        overlay: ov.State = .{},
        active: usize = 0,
        selected: ?usize = null,
        first: usize = 0,
        activated: ?usize = null,
        pressable: behavior.Pressable = .{},
        pressed_item: ?usize = null,
        pressed_submenu: bool = false,
        submenu_parent: ?usize = null,
        submenu_active: usize = 0,
        submenu_first: usize = 0,
        at_pointer: bool = false,
        pub fn init(_: *runtime.Context(Self), options: Options) Self {
            std.debug.assert(options.row_height > 0 and options.visible_rows > 0);
            return .{ .options = options };
        }
        pub fn popupKey(self: *const Self) u64 {
            return platform.id.fromSrc(self.options.key, @src(), 0);
        }
        pub fn open(self: *Self, win: *Window) void {
            self.at_pointer = false;
            self.overlay.show(win);
            self.active = self.selected orelse 0;
            if (self.options.items.len > 0 and self.options.items[self.active].disabled) self.move(1);
        }
        /// Context-menu entry point for a host's right-click handler; positions
        /// at a window-local point rather than attaching to the trigger.
        pub fn openAt(self: *Self, win: *Window, point: @import("../core/geometry.zig").Point) void {
            self.open(win);
            self.at_pointer = true;
            self.overlay.anchor = .{ .x = point.x, .y = point.y };
        }
        pub fn close(self: *Self, win: *Window) void {
            self.closeSubmenu();
            self.overlay.close(win);
        }
        fn closeSubmenu(self: *Self) void {
            self.submenu_parent = null;
            self.submenu_active = 0;
            self.submenu_first = 0;
            self.pressed_submenu = false;
        }
        fn openSubmenu(self: *Self) bool {
            if (self.active >= self.options.items.len) return false;
            const children = self.options.items[self.active].children orelse return false;
            if (children.len == 0) return false;
            self.submenu_parent = self.active;
            self.submenu_active = 0;
            self.submenu_first = 0;
            self.moveSubmenu(1);
            return true;
        }
        fn move(self: *Self, delta: i2) void {
            const n = self.options.items.len;
            if (n == 0) return;
            for (0..n) |_| {
                self.active = if (delta > 0) (self.active + 1) % n else (self.active + n - 1) % n;
                if (!self.options.items[self.active].disabled) break;
            }
            if (self.active < self.first) self.first = self.active;
            if (self.active >= self.first + self.options.visible_rows) self.first = self.active + 1 - self.options.visible_rows;
        }
        fn moveSubmenu(self: *Self, delta: i2) void {
            const parent = self.submenu_parent orelse return;
            const items = self.options.items[parent].children orelse return;
            if (items.len == 0) return;
            for (0..items.len) |_| {
                self.submenu_active = if (delta > 0) (self.submenu_active + 1) % items.len else (self.submenu_active + items.len - 1) % items.len;
                if (!items[self.submenu_active].disabled) break;
            }
            if (self.submenu_active < self.submenu_first) self.submenu_first = self.submenu_active;
            if (self.submenu_active >= self.submenu_first + self.options.visible_rows) self.submenu_first = self.submenu_active + 1 - self.options.visible_rows;
        }
        fn activate(self: *Self, win: *Window) void {
            var items = self.options.items;
            var index = self.active;
            if (self.submenu_parent) |parent| {
                items = self.options.items[parent].children orelse return;
                index = self.submenu_active;
            }
            if (index >= items.len or items[index].disabled) return;
            const item = &items[index];
            if (item.children) |children| if (children.len > 0) {
                if (self.submenu_parent == null) _ = self.openSubmenu();
                return;
            };
            if (item.submenu) return;
            if (item.checked) |checked| item.checked = !checked;
            self.activated = index;
            if (select and self.submenu_parent == null) self.selected = index;
            self.close(win);
            if (self.options.on_change) |callback| callback.call(win);
        }
        fn down(self: *Self, _: *Window, _: *runtime.Context(Self)) void {
            self.pressable.pressBegin();
        }
        fn up(self: *Self, win: *Window, _: *runtime.Context(Self)) void {
            if (self.pressable.pressEnd(behavior.releaseInside(win))) {
                if (self.overlay.open) self.close(win) else self.open(win);
            }
        }
        const Hit = struct { index: usize, submenu: bool };
        fn rowAt(self: *Self, win: *Window) ?Hit {
            if (!self.overlay.rect.contains(win.pointer_position)) return null;
            const in_submenu = self.submenu_parent != null and win.pointer_position.x >= self.overlay.rect.x + self.options.width;
            const items = if (in_submenu) (self.options.items[self.submenu_parent.?].children orelse return null) else self.options.items;
            const row: usize = @intFromFloat(@max(0, @floor((win.pointer_position.y - self.overlay.rect.y) / self.options.row_height)));
            const first = if (in_submenu) self.submenu_first else self.first;
            const index = first + row;
            return if (index < items.len) .{ .index = index, .submenu = in_submenu } else null;
        }
        fn itemDown(self: *Self, win: *Window, _: *runtime.Context(Self)) void {
            self.pressed_item = if (self.rowAt(win)) |hit| hit.index else null;
            self.pressed_submenu = if (self.rowAt(win)) |hit| hit.submenu else false;
        }
        fn itemUp(self: *Self, win: *Window, _: *runtime.Context(Self)) void {
            defer {
                self.pressed_item = null;
                self.pressed_submenu = false;
            }
            if (self.pressed_item) |index| if (self.rowAt(win)) |hit| if (hit.index == index and hit.submenu == self.pressed_submenu) {
                if (hit.submenu) self.submenu_active = index else self.active = index;
                self.activate(win);
            };
        }
        fn wheel(self: *Self, win: *Window, _: *runtime.Context(Self)) void {
            const n = self.options.items.len;
            if (win.last_scroll.dy < 0) self.first = @min(n -| self.options.visible_rows, self.first + 1) else self.first -|= 1;
        }
        pub fn handleEvent(self: *Self, event: platform.Event, cx: *runtime.Context(Self)) bool {
            if (event == .window) {
                self.pressable.cancel();
                self.pressed_item = null;
                return false;
            }
            if (event == .mouse) {
                const win = cx.window orelse return false;
                if (event.mouse.button == .right and event.mouse.pressed and !event.mouse.motion and ov.bounds(win, self.options.key).contains(event.mouse.pos)) {
                    self.openAt(win, event.mouse.pos);
                    return true;
                }
                return false;
            }
            if (event != .key or !event.key.pressed) return false;
            const win = cx.window orelse return false;
            const key = event.key.key;
            if (!self.overlay.open) {
                if (key == .enter or key == .space or key == .down or key == .up or (key == .f10 and event.key.modifiers.shift)) {
                    self.open(win);
                    return true;
                }
                return false;
            }
            switch (key) {
                .down => if (self.submenu_parent != null) self.moveSubmenu(1) else self.move(1),
                .up => if (self.submenu_parent != null) self.moveSubmenu(-1) else self.move(-1),
                .right => if (self.submenu_parent == null) {
                    _ = self.openSubmenu();
                },
                .left => if (self.submenu_parent != null) self.closeSubmenu() else self.close(win),
                .home => {
                    self.active = self.options.items.len -| 1;
                    self.move(1);
                },
                .end => {
                    self.active = 0;
                    self.move(-1);
                },
                .enter, .space => if (!event.key.repeat) self.activate(win),
                .escape => self.close(win),
                else => return false,
            }
            win.requestRender();
            return true;
        }
        fn semanticAction(raw: *anyopaque, _: @import("../a11y/root.zig").Request, raw_win: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.open(@ptrCast(@alignCast(raw_win)));
        }
        pub fn render(self: *Self, win: *Window, cx: *runtime.Context(Self)) e.Element {
            const t = self.options.tokens orelse theme.current();
            const handle = cx.focusHandle();
            if (!win.left_button_down or !win.focused.eql(handle)) {
                self.pressable.cancel();
                self.pressed_item = null;
            }
            const frame = e.element.currentFrame();
            if (!select and frame.observer_count < frame.observers.len) {
                frame.observers[frame.observer_count] = handle;
                frame.observer_count += 1;
            }
            if (handle.owner_store) |store| e.element.currentFrame().trackOwner(self, store, handle.id, handle.owner_generation);
            const label = if (select and self.selected != null and self.selected.? < self.options.items.len) self.options.items[self.selected.?].label else self.options.label;
            const trigger = e.div().keyed(self.options.key).w(self.options.width).h(t.button_h).bg(t.palette.surface).withFocus(handle)
                .on_mouse_down(cx.listener(Self, down)).on_mouse_up(cx.listener(Self, up))
                .semantic(.{ .role = if (select) .combobox else .button, .name = self.options.label, .text_value = label, .controls = self.popupKey(), .states = .{ .expanded = self.overlay.open }, .actions = .{ .activate = true, .focus = true }, .handler = .{ .target = self, .call_fn = semanticAction } })
                .child(e.text(label, .{ .size = t.type_scale.body, .color = t.palette.fg }));
            if (self.overlay.open) {
                self.overlay.anchor_key = if (self.at_pointer) 0 else self.options.key;
                const outer_rows = @min(self.options.items.len, self.options.visible_rows);
                const submenu_items = if (self.submenu_parent) |parent| self.options.items[parent].children else null;
                const submenu_rows = if (submenu_items) |items| @min(items.len, self.options.visible_rows) else 0;
                const columns: f32 = if (submenu_items != null) 2 else 1;
                self.overlay.size = .{ .w = self.options.width * columns, .h = @as(f32, @floatFromInt(@max(outer_rows, submenu_rows))) * self.options.row_height };
                var outer = e.div().w(self.options.width).h(@as(f32, @floatFromInt(outer_rows))).flex_col().on_scroll(cx.listener(Self, wheel));
                // Fixed-height windowing: O(visible rows), no invisible builders.
                self.first = @min(self.first, self.options.items.len -| self.options.visible_rows);
                if (submenu_items != null) {
                    for (self.first..@min(self.options.items.len, self.first + self.options.visible_rows)) |index| {
                        const item = self.options.items[index];
                        const row = e.div().keyed(item.key).w(self.options.width).h(self.options.row_height).flex_row().items_center().gap(t.spacing.sm)
                            .bg(if (index == self.active and self.submenu_parent == null) t.palette.track else t.palette.surface_raised)
                            .on_mouse_down(cx.listener(Self, itemDown)).on_mouse_up(cx.listener(Self, itemUp)).withFocus(handle)
                            .semantic(.{ .role = if (select) .option else if (item.checked != null) .menuitem_checkbox else .menuitem, .name = item.label, .states = .{ .disabled = item.disabled, .checked = item.checked, .selected = if (select) self.selected == index else index == self.active }, .position_in_set = index + 1, .set_size = self.options.items.len })
                            .child(e.text(if (item.checked == true) "✓" else "", .{ .size = t.type_scale.body, .color = t.palette.fg }))
                            .child(e.text(item.label, .{ .size = t.type_scale.body, .color = if (item.disabled) t.palette.muted else t.palette.fg }))
                            .child(e.text(if (item.children != null or item.submenu) "›" else "", .{ .size = t.type_scale.body, .color = t.palette.muted }));
                        outer = outer.child(row);
                    }
                }
                var panel = e.div().keyed(self.popupKey()).bg(t.palette.surface_raised).withFocus(handle)
                    .semantic(.{ .role = if (select) .listbox else .menu, .name = self.options.label, .active_descendant = if (self.active < self.options.items.len) self.options.items[self.active].key else 0 });
                if (submenu_items) |items| {
                    panel = panel.w(self.overlay.size.w).h(self.overlay.size.h).flex_row().child(outer);
                    var child_panel = e.div().w(self.options.width).h(@as(f32, @floatFromInt(submenu_rows))).flex_col().on_scroll(cx.listener(Self, wheel));
                    self.submenu_first = @min(self.submenu_first, items.len -| self.options.visible_rows);
                    for (self.submenu_first..@min(items.len, self.submenu_first + self.options.visible_rows)) |index| {
                        const item = items[index];
                        const row = e.div().keyed(item.key).w(self.options.width).h(self.options.row_height).flex_row().items_center().gap(t.spacing.sm)
                            .bg(if (index == self.submenu_active) t.palette.track else t.palette.surface_raised)
                            .on_mouse_down(cx.listener(Self, itemDown)).on_mouse_up(cx.listener(Self, itemUp)).withFocus(handle)
                            .semantic(.{ .role = if (select) .option else .menuitem, .name = item.label, .states = .{ .disabled = item.disabled, .selected = index == self.submenu_active }, .position_in_set = index + 1, .set_size = items.len })
                            .child(e.text(item.label, .{ .size = t.type_scale.body, .color = if (item.disabled) t.palette.muted else t.palette.fg }));
                        child_panel = child_panel.child(row);
                    }
                    panel = panel.child(child_panel);
                } else {
                    // Preserve the original single-column portal tree. This
                    // keeps row measurement independent of the two-column
                    // submenu wrapper and its flex constraints.
                    for (self.first..@min(self.options.items.len, self.first + self.options.visible_rows)) |index| {
                        const item = self.options.items[index];
                        const row = e.div().keyed(item.key).w(self.options.width).h(self.options.row_height).flex_row().items_center().gap(t.spacing.sm)
                            .bg(if (index == self.active) t.palette.track else t.palette.surface_raised)
                            .on_mouse_down(cx.listener(Self, itemDown)).on_mouse_up(cx.listener(Self, itemUp)).withFocus(handle)
                            .semantic(.{ .role = if (select) .option else if (item.checked != null) .menuitem_checkbox else .menuitem, .name = item.label, .states = .{ .disabled = item.disabled, .checked = item.checked, .selected = if (select) self.selected == index else index == self.active }, .position_in_set = index + 1, .set_size = self.options.items.len })
                            .child(e.text(if (item.checked == true) "✓" else "", .{ .size = t.type_scale.body, .color = t.palette.fg }))
                            .child(e.text(item.label, .{ .size = t.type_scale.body, .color = if (item.disabled) t.palette.muted else t.palette.fg }))
                            .child(e.text(if (item.children != null or item.submenu) "›" else "", .{ .size = t.type_scale.body, .color = t.palette.muted }));
                        panel = panel.child(row);
                    }
                }
                self.overlay.portal(win, handle, panel);
            }
            return trigger;
        }
    };
}
