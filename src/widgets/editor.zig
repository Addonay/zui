//! Bounded editor primitive shared by TextArea and editor-like consumers.
//! This is intentionally renderer-independent: callers may compose its state
//! with any element tree without inheriting a painted editor shell.
const std = @import("std");
const platform = @import("../platform/root.zig");
const limits = @import("../core/limits.zig");
const a11y = @import("../a11y/root.zig");
const elements = @import("../elements/root.zig");
const element_mod = @import("../elements/element.zig");

pub const Editor = struct {
    pub const Capacity = limits.MAX_TEXT_LEN;
    text_buf: [Capacity]u8 = undefined,
    len: usize = 0,
    anchor: usize = 0,
    active: usize = 0,
    disabled: bool = false,
    loading: bool = false,
    error_state: bool = false,
    multiline: bool = true,
    focused: bool = false,

    pub fn init(initial: []const u8, multiline: bool) Editor {
        var self = Editor{ .multiline = multiline };
        self.replaceAll(initial);
        return self;
    }
    pub fn text(self: *const Editor) []const u8 {
        return self.text_buf[0..self.len];
    }
    pub fn selected(self: *const Editor) []const u8 {
        return self.text()[self.start()..self.end()];
    }
    pub fn start(self: *const Editor) usize {
        return @min(self.anchor, self.active);
    }
    pub fn end(self: *const Editor) usize {
        return @max(self.anchor, self.active);
    }
    pub fn replaceAll(self: *Editor, value: []const u8) void {
        const n = @min(value.len, Capacity);
        @memcpy(self.text_buf[0..n], value[0..n]);
        self.len = n;
        self.anchor = n;
        self.active = n;
        self.clamp();
    }
    fn clamp(self: *Editor) void {
        self.anchor = self.snap(@min(self.anchor, self.len));
        self.active = self.snap(@min(self.active, self.len));
    }
    fn snap(self: *const Editor, index: usize) usize {
        var i = @min(index, self.len);
        while (i > 0 and !std.unicode.utf8ValidateSlice(self.text()[0..i])) : (i -= 1) {}
        return i;
    }
    fn previous(self: *const Editor, index: usize) usize {
        if (index == 0) return 0;
        var i = index - 1;
        while (i > 0 and (self.text()[i] & 0xc0) == 0x80) : (i -= 1) {}
        return i;
    }
    fn next(self: *const Editor, index: usize) usize {
        if (index >= self.len) return self.len;
        return index + (std.unicode.utf8ByteSequenceLength(self.text()[index]) catch 1);
    }
    pub fn setSelection(self: *Editor, anchor: usize, active: usize) void {
        self.anchor = anchor;
        self.active = active;
        self.clamp();
    }

    pub fn byteIndexForCharacter(self: *const Editor, character: u32) usize {
        var byte: usize = 0;
        var count: u32 = 0;
        while (byte < self.len and count < character) : (count += 1) {
            byte += std.unicode.utf8ByteSequenceLength(self.text()[byte]) catch 1;
        }
        return @min(byte, self.len);
    }

    pub fn characterIndex(self: *const Editor, byte_index: usize) u32 {
        return @intCast(std.unicode.utf8CountCodepoints(self.text()[0..@min(byte_index, self.len)]) catch 0);
    }
    pub fn selectAll(self: *Editor) void {
        self.anchor = 0;
        self.active = self.len;
    }
    pub fn semanticProperties(self: *const Editor, label: []const u8) a11y.Properties {
        return .{ .role = .text_input, .name = label, .text_value = self.text(), .states = .{ .disabled = self.disabled, .focused = self.focused }, .actions = .{ .focus = true, .set_value = !self.disabled and !self.loading, .set_text_selection = !self.disabled and !self.loading } };
    }
    fn focusId(self: *Editor) u32 {
        return @truncate(@intFromPtr(self));
    }
    fn focusedEvent(target: *anyopaque, event: platform.Event, _: *anyopaque) bool {
        return @as(*Editor, @ptrCast(@alignCast(target))).handleEvent(event);
    }
    fn semanticAction(target: *anyopaque, request: a11y.Request, _: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(target));
        switch (request.action) {
            .set_value => self.replaceAll(request.text),
            .set_text_selection => if (request.selection) |selection| self.setSelection(self.byteIndexForCharacter(selection.anchor), self.byteIndexForCharacter(selection.focus)),
            else => {},
        }
    }
    pub fn render(self: *Editor, label: []const u8) elements.Element {
        const focus = elements.FocusHandle{ .id = self.focusId(), .target = self, .event_fn = focusedEvent };
        var props = self.semanticProperties(label);
        props.handler = .{ .target = self, .call_fn = semanticAction };
        return elements.div().w_full().h(24).p(4).rounded_lg().border_1().withFocus(focus)
            .semantic(props).child(elements.text(self.text(), .{}));
    }
    pub fn insert(self: *Editor, bytes: []const u8) bool {
        if (self.disabled or self.loading or (bytes.len == 0 and self.start() == self.end())) return false;
        if (!self.multiline and std.mem.indexOfScalar(u8, bytes, '\n') != null) return false;
        const replacement = self.end() - self.start();
        if (bytes.len > Capacity - (self.len - replacement)) return false;
        const a = self.start();
        const b = self.end();
        std.mem.copyBackwards(u8, self.text_buf[a + bytes.len ..][0 .. self.len - b], self.text_buf[b..self.len]);
        @memcpy(self.text_buf[a..][0..bytes.len], bytes);
        self.len = self.len - replacement + bytes.len;
        self.anchor = a + bytes.len;
        self.active = self.anchor;
        return true;
    }
    pub fn backspace(self: *Editor) bool {
        if (self.disabled or self.loading) return false;
        if (self.start() != self.end()) return self.insert("");
        if (self.active == 0) return false;
        self.anchor = self.previous(self.active);
        self.active = self.active;
        return self.insert("");
    }
    pub fn delete(self: *Editor) bool {
        if (self.disabled or self.loading) return false;
        if (self.start() != self.end()) return self.insert("");
        if (self.active >= self.len) return false;
        self.anchor = self.active;
        self.active = self.next(self.active);
        return self.insert("");
    }
    pub fn move(self: *Editor, key: platform.event.Key, extend: bool) bool {
        if (self.disabled or self.loading) return false;
        var destination = self.active;
        switch (key) {
            .left => destination = self.previous(destination),
            .right => destination = self.next(destination),
            .home => destination = 0,
            .end => destination = self.len,
            else => return false,
        }
        if (extend) self.active = destination else self.anchor = destination;
        self.active = destination;
        if (!extend) self.anchor = destination;
        return true;
    }
    pub fn handleEvent(self: *Editor, event: platform.Event) bool {
        switch (event) {
            .text => |ev| return self.insert(ev.slice()),
            .key => |key| {
                if (!key.pressed or key.modifiers.alt or key.modifiers.super) return false;
                return switch (key.key) {
                    .backspace => self.backspace(),
                    .delete => self.delete(),
                    .left, .right, .home, .end => self.move(key.key, key.modifiers.shift),
                    .a => if (key.modifiers.ctrl) blk: {
                        self.selectAll();
                        break :blk true;
                    } else false,
                    else => false,
                };
            },
            else => return false,
        }
    }
};

test "editor is grapheme-safe, bounded, and gates disabled/loading input" {
    var ed = Editor.init("a🙂c", true);
    ed.anchor = 5;
    ed.active = 5;
    try std.testing.expect(ed.backspace());
    try std.testing.expectEqualStrings("ac", ed.text());
    ed.loading = true;
    try std.testing.expect(!ed.insert("x"));
    ed.loading = false;
    ed.disabled = true;
    try std.testing.expect(!ed.delete());
}
