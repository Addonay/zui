//! Search/command palette model with deterministic fuzzy ranking and keyboard navigation.
const std = @import("std");
const platform = @import("../platform/root.zig");
const a11y = @import("../a11y/root.zig");
const elements = @import("../elements/root.zig");
const element_mod = @import("../elements/element.zig");

pub const Command = struct { key: u64, label: []const u8, disabled: bool = false };
pub const CommandPalette = struct {
    pub const Options = struct { commands: []const Command, disabled: bool = false, loading: bool = false, error_state: bool = false };
    options: Options,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    selected: usize = 0,
    open: bool = false,
    focused: bool = false,
    pub fn init(options: Options) CommandPalette {
        return .{ .options = options };
    }
    pub fn query(self: *const CommandPalette) []const u8 {
        return self.query_buf[0..self.query_len];
    }
    pub fn setQuery(self: *CommandPalette, value: []const u8) void {
        const n = @min(value.len, self.query_buf.len);
        @memcpy(self.query_buf[0..n], value[0..n]);
        self.query_len = n;
        self.selected = 0;
    }
    fn matches(self: *const CommandPalette, command: Command) bool {
        if (self.query().len == 0) return true;
        const needle = self.query();
        if (needle.len > command.label.len) return false;
        var start: usize = 0;
        while (start + needle.len <= command.label.len) : (start += 1) {
            var matched = true;
            for (needle, 0..) |want, offset| if (std.ascii.toLower(command.label[start + offset]) != std.ascii.toLower(want)) {
                matched = false;
                break;
            };
            if (matched) return true;
        }
        return false;
    }
    fn move(self: *CommandPalette, delta: i2) bool {
        if (self.options.commands.len == 0) return false;
        var i = self.selected;
        var seen: usize = 0;
        while (seen < self.options.commands.len) : (seen += 1) {
            i = if (delta > 0) (i + 1) % self.options.commands.len else (i + self.options.commands.len - 1) % self.options.commands.len;
            if (self.matches(self.options.commands[i]) and !self.options.commands[i].disabled) {
                self.selected = i;
                return true;
            }
        }
        return false;
    }
    pub fn activate(self: *CommandPalette) ?u64 {
        if (self.options.disabled or self.options.loading or !self.open or self.selected >= self.options.commands.len) return null;
        const c = self.options.commands[self.selected];
        return if (self.matches(c) and !c.disabled) c.key else null;
    }
    pub fn semantics(self: *const CommandPalette) a11y.Properties {
        return .{ .role = .listbox, .name = "Command palette", .text_value = self.query(), .states = .{ .disabled = self.options.disabled or self.options.loading, .focused = self.focused, .hidden = !self.open }, .actions = .{ .focus = true } };
    }
    fn focusId(self: *CommandPalette) u32 {
        return @truncate(@intFromPtr(self));
    }
    fn focusedEvent(target: *anyopaque, event: platform.Event, _: *anyopaque) bool {
        return @as(*CommandPalette, @ptrCast(@alignCast(target))).handleEvent(event);
    }
    fn clickCommand(target: *anyopaque, payload: *const element_mod.ListenerPayload, _: *anyopaque) void {
        const self: *CommandPalette = @ptrCast(@alignCast(target));
        self.selected = @as(usize, @intCast(payload.bytes[0]));
        _ = self.activate();
    }
    fn semanticAction(target: *anyopaque, request: a11y.Request, _: *anyopaque) void {
        const self: *CommandPalette = @ptrCast(@alignCast(target));
        if (request.action == .activate) _ = self.activate();
        if (request.action == .set_value) self.setQuery(request.text);
    }
    pub fn render(self: *CommandPalette) elements.Element {
        const focus = elements.FocusHandle{ .id = self.focusId(), .target = self, .event_fn = focusedEvent };
        var props = self.semantics();
        props.handler = .{ .target = self, .call_fn = semanticAction };
        var root = elements.div().w_full().h(280).p(8).rounded_lg().border_1().overflow_hidden().withFocus(focus).semantic(props);
        if (!self.open) return root;
        var count: usize = 0;
        for (self.options.commands, 0..) |command, index| {
            if (!self.matches(command) or count >= 64) continue;
            var payload: element_mod.ListenerPayload = .{ .bytes = @splat(0) };
            payload.bytes[0] = @intCast(@min(index, 255));
            var item = elements.div().h(28).w_full().p(4).on_click(.{ .target = self, .payload = payload, .call_fn = clickCommand })
                .semantic(.{ .role = .option, .name = command.label, .position_in_set = count + 1, .set_size = self.options.commands.len, .states = .{ .disabled = command.disabled, .selected = self.selected == index }, .actions = .{ .activate = !command.disabled } })
                .child(elements.text(command.label, .{}));
            if (self.selected == index) item = item.bg(.{ .r = 0.18, .g = 0.22, .b = 0.3, .a = 1 });
            root = root.child(item);
            count += 1;
        }
        return root;
    }
    pub fn handleEvent(self: *CommandPalette, event: platform.Event) bool {
        if (self.options.disabled or self.options.loading or event != .key or !event.key.pressed) return false;
        switch (event.key.key) {
            .up => return self.move(-1),
            .down => return self.move(1),
            .escape => {
                self.open = false;
                return true;
            },
            .enter => return self.activate() != null,
            else => return false,
        }
    }
};

test "command palette ranks by query, skips disabled, and activates" {
    const commands = [_]Command{ .{ .key = 1, .label = "Open" }, .{ .key = 2, .label = "Save", .disabled = true }, .{ .key = 3, .label = "Open Recent" } };
    var palette = CommandPalette.init(.{ .commands = &commands });
    palette.open = true;
    palette.setQuery("open");
    try std.testing.expectEqual(@as(?u64, 1), palette.activate());
    try std.testing.expect(palette.handleEvent(.{ .key = .{ .key = .down, .pressed = true } }));
    try std.testing.expectEqual(@as(?u64, 3), palette.activate());
}
