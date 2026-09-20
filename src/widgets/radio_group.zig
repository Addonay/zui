const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const a11y = @import("../a11y/root.zig");
const behavior = @import("behavior.zig");
const theme = @import("theme.zig");

/// One tab stop; arrows wrap selection. Option ids must be stable across reorder.
pub const RadioGroup = struct {
    const Self = @This();
    pub const Option = struct { key: u64, label: []const u8 };
    pub const Options = struct { key: u64, label: []const u8, items: []const Option, selected: usize = 0, disabled: bool = false, tokens: ?theme.Theme = null, on_change: ?e.Listener = null };
    const Target = struct { group: *Self, index: usize };
    options: Options,
    selected: usize,
    pending: ?usize = null,
    pressable: behavior.Pressable = .{},
    targets: [32]Target = undefined,
    pub fn init(_: *runtime.Context(Self), options: Options) Self {
        std.debug.assert(options.key != 0 and options.items.len > 0 and options.items.len <= 32 and options.selected < options.items.len);
        return .{ .options = options, .selected = options.selected };
    }
    fn select(self: *Self, index: usize, win: *Window) void {
        if (self.options.disabled or index >= self.options.items.len) return;
        self.selected = index;
        win.requestRender();
        if (self.options.on_change) |listener| listener.call(win);
    }
    fn down(self: *Self, index: usize, _: *Window, cx: *runtime.Context(Self)) void {
        self.pressable.setEnabled(!self.options.disabled);
        self.pending = index;
        self.pressable.pressBegin();
        cx.notify();
    }
    fn up(self: *Self, index: usize, win: *Window, cx: *runtime.Context(Self)) void {
        self.pressable.setEnabled(!self.options.disabled);
        if (self.pressable.pressEnd(behavior.releaseInside(win)) and self.pending == index) self.select(index, win);
        self.pending = null;
        cx.notify();
    }
    fn action(raw: *anyopaque, request: a11y.Request, raw_win: *anyopaque) void {
        const target: *Target = @ptrCast(@alignCast(raw));
        const self = target.group;
        self.pressable.setEnabled(!self.options.disabled);
        if (request.action == .activate and self.pressable.activate()) self.select(target.index, @ptrCast(@alignCast(raw_win)));
    }
    pub fn handleEvent(self: *Self, event: platform.Event, cx: *runtime.Context(Self)) bool {
        if (event == .window) {
            self.pressable.cancel();
            self.pending = null;
            return false;
        }
        if (event != .key or self.options.disabled) return false;
        const key = event.key;
        if (key.modifiers.ctrl or key.modifiers.alt or key.modifiers.super) return false;
        const win = cx.window orelse return false;
        if (key.key == .enter or key.key == .space) {
            if (self.pressable.keyEventResult(key.key, key.pressed, key.repeat) == .activated) self.select(self.selected, win);
            cx.notify();
            return true;
        }
        if (!key.pressed) return false;
        switch (key.key) {
            .left, .up => self.select((self.selected + self.options.items.len - 1) % self.options.items.len, win),
            .right, .down => self.select((self.selected + 1) % self.options.items.len, win),
            .home => self.select(0, win),
            .end => self.select(self.options.items.len - 1, win),
            else => return false,
        }
        cx.notify();
        return true;
    }
    pub fn render(self: *Self, win: *Window, cx: *runtime.Context(Self)) e.Element {
        const t = self.options.tokens orelse theme.current();
        const focus = cx.focusHandle();
        self.pressable.setEnabled(!self.options.disabled);
        if (!win.left_button_down or !win.focused.eql(focus)) self.pressable.cancel();
        var root = e.div().keyed(self.options.key).w(180).gap(t.spacing.xs).withFocus(focus).semantic(.{ .role = .radio_group, .name = self.options.label, .states = .{ .disabled = self.options.disabled, .focused = win.focused.eql(focus) }, .actions = .{ .focus = true } });
        for (self.options.items, 0..) |item, i| {
            self.targets[i] = .{ .group = self, .index = i };
            if (focus.owner_store) |store| e.element.currentFrame().trackOwner(&self.targets[i], store, focus.id, focus.owner_generation);
            var row = e.div().keyed(item.key).w(180).h(t.button_h).flex_row().items_center().gap(t.spacing.sm).px(t.spacing.sm).rounded(t.radii.md).bg(t.palette.surface).hover_bg(theme.stateBg(t, t.palette.surface, .hovered)).withFocus(focus)
                .on_mouse_down(cx.listenerWith(usize, Self, down, i)).on_mouse_up(cx.listenerWith(usize, Self, up, i))
                .semantic(.{ .role = .radio, .name = item.label, .states = .{ .checked = self.selected == i, .selected = self.selected == i, .disabled = self.options.disabled, .focused = win.focused.eql(focus) and self.selected == i }, .actions = .{ .activate = true, .focus = true }, .handler = .{ .target = &self.targets[i], .call_fn = action } });
            if (self.selected == i and win.focused.eql(focus)) row = row.border_2().border_color(t.palette.focus_ring);
            row = row.child(e.div().size(16).rounded_full().bg(if (self.selected == i) t.palette.accent else t.palette.track)).child(e.text(item.label, .{ .size = t.type_scale.body, .color = t.palette.fg }));
            root = root.child(row);
        }
        return root;
    }
};
