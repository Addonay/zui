//! Keyboard/selection contract for tabs. Rendering is deliberately left to the caller.
const std = @import("std");
const platform = @import("../platform/root.zig");
const a11y = @import("../a11y/root.zig");
const elements = @import("../elements/root.zig");
const element_mod = @import("../elements/element.zig");

pub const Tab = struct { key: u64, label: []const u8, disabled: bool = false };
pub const Tabs = struct {
    pub const Options = struct { tabs: []const Tab, selected: usize = 0, disabled: bool = false, loading: bool = false, error_state: bool = false };
    options: Options,
    selected: usize,
    focused: bool = false,
    fn focusId(self: *Tabs) u32 {
        return @truncate(@intFromPtr(self));
    }
    fn focusedEvent(target: *anyopaque, event: platform.Event, _: *anyopaque) bool {
        return @as(*Tabs, @ptrCast(@alignCast(target))).handleEvent(event);
    }
    fn clickTab(target: *anyopaque, payload: *const element_mod.ListenerPayload, _: *anyopaque) void {
        const self: *Tabs = @ptrCast(@alignCast(target));
        const index = @as(usize, @intCast(payload.bytes[0]));
        _ = self.select(index);
    }
    fn semanticAction(target: *anyopaque, request: a11y.Request, _: *anyopaque) void {
        const self: *Tabs = @ptrCast(@alignCast(target));
        if (request.action == .activate) _ = self.select(self.selected);
    }
    pub fn render(self: *Tabs) elements.Element {
        const focus = elements.FocusHandle{ .id = self.focusId(), .target = self, .event_fn = focusedEvent };
        var root = elements.div().flex_row().w_full().h(36).gap(2).withFocus(focus)
            .semantic(.{ .role = .list, .name = "Tabs", .states = .{ .disabled = self.options.disabled or self.options.loading, .focused = self.focused }, .actions = .{ .activate = !self.options.disabled and !self.options.loading, .focus = true }, .handler = .{ .target = self, .call_fn = semanticAction } });
        for (self.options.tabs, 0..) |tab, index| {
            var payload: element_mod.ListenerPayload = .{ .bytes = @splat(0) };
            payload.bytes[0] = @intCast(@min(index, 255));
            var item = elements.div().h_full().px(10).items_center().on_click(.{ .target = self, .payload = payload, .call_fn = clickTab })
                .semantic(self.tabSemantics(index)).child(elements.text(tab.label, .{}));
            if (self.selected == index) item = item.border_b_1();
            root = root.child(item);
        }
        return root;
    }
    pub fn init(options: Options) Tabs {
        var self = Tabs{ .options = options, .selected = 0 };
        self.selected = self.nextEnabled(options.selected, 1) orelse 0;
        return self;
    }
    fn nextEnabled(self: *const Tabs, from: usize, delta: i2) ?usize {
        if (self.options.tabs.len == 0) return null;
        var i = from % self.options.tabs.len;
        var n: usize = 0;
        while (n < self.options.tabs.len) : (n += 1) {
            if (!self.options.tabs[i].disabled) return i;
            i = if (delta > 0) (i + 1) % self.options.tabs.len else (i + self.options.tabs.len - 1) % self.options.tabs.len;
        }
        return null;
    }
    pub fn select(self: *Tabs, index: usize) bool {
        if (self.options.disabled or self.options.loading or index >= self.options.tabs.len or self.options.tabs[index].disabled) return false;
        self.selected = index;
        return true;
    }
    pub fn tabSemantics(self: *const Tabs, index: usize) a11y.Properties {
        const item = self.options.tabs[index];
        return .{ .role = .option, .name = item.label, .position_in_set = index + 1, .set_size = self.options.tabs.len, .states = .{ .disabled = self.options.disabled or item.disabled, .selected = self.selected == index, .focused = self.focused and self.selected == index }, .actions = .{ .activate = !self.options.disabled and !self.options.loading and !item.disabled, .focus = true } };
    }
    pub fn handleEvent(self: *Tabs, event: platform.Event) bool {
        if (self.options.disabled or self.options.loading or self.options.tabs.len == 0 or event != .key) return false;
        const key = event.key;
        if (!key.pressed) return false;
        const target = switch (key.key) {
            .left => self.nextEnabled((self.selected + self.options.tabs.len - 1) % self.options.tabs.len, -1),
            .right => self.nextEnabled((self.selected + 1) % self.options.tabs.len, 1),
            .home => self.nextEnabled(0, 1),
            .end => self.nextEnabled(self.options.tabs.len - 1, -1),
            else => null,
        } orelse return false;
        return self.select(target);
    }
};

test "tabs skip disabled tabs and gate loading" {
    const tabs = [_]Tab{ .{ .key = 1, .label = "A" }, .{ .key = 2, .label = "B", .disabled = true }, .{ .key = 3, .label = "C" } };
    var widget = Tabs.init(.{ .tabs = &tabs });
    try std.testing.expect(widget.handleEvent(.{ .key = .{ .key = .right, .pressed = true } }));
    try std.testing.expectEqual(@as(usize, 2), widget.selected);
    widget.options.loading = true;
    try std.testing.expect(!widget.handleEvent(.{ .key = .{ .key = .left, .pressed = true } }));
}
