const std = @import("std");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const limits = @import("../core/limits.zig");

pub const TextField = struct {
    pub const Options = struct {
        placeholder: []const u8 = "",
        text_color: @import("../core/color.zig").Color = .hex(0xf2f2f5),
        placeholder_color: @import("../core/color.zig").Color = .hex(0x6f7082),
        focus_color: @import("../core/color.zig").Color = .hex(0x7c5cff),
    };

    buffer: [limits.MAX_TEXT_LEN]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,
    placeholder: []const u8,
    options: Options,

    pub fn init(_: *runtime.Context(TextField), options: Options) TextField {
        return .{ .placeholder = options.placeholder, .options = options };
    }

    pub fn trimmedText(self: *const TextField) []const u8 {
        return std.mem.trim(u8, self.buffer[0..self.len], " \t\r\n");
    }

    pub fn clear(self: *TextField, cx: *runtime.Context(TextField)) void {
        self.len = 0;
        self.caret = 0;
        cx.notify();
    }

    pub fn render(self: *TextField, window: *@import("../app/window.zig").Window, cx: *runtime.Context(TextField)) elements.Element {
        const focused = window.focused.eql(cx.focusHandle());
        const value = if (self.len == 0) self.placeholder else self.buffer[0..self.len];
        const color = if (self.len == 0) self.options.placeholder_color else self.options.text_color;
        var field = elements.div().flex_row().h(40).size_full().px(8).items_center()
            .rounded_lg()
            .cursor_text()
            .border_1()
            .border_color(if (focused) self.options.focus_color else @import("../core/color.zig").Color.transparent)
            .child(elements.text(value, .{ .size = 14, .color = color }));
        if (focused) {
            // Shaped width when fonts are present so the caret tracks the
            // ink; bitmap estimate otherwise (same fallback as measure).
            const text_w = if (window.fonts) |fc|
                fc.measureText(self.buffer[0..self.caret], 14, 0, "")
            else
                @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(self.buffer[0..self.caret]) catch 0)) * elements.element.textAdvance(14, 0, .normal);
            const cursor_x = text_w + 8;
            field = field.child(elements.div().absolute().left(cursor_x).top(10).w(1).h(20).bg(self.options.focus_color));
        }
        return field.withFocus(cx.focusHandle());
    }

    pub fn handleEvent(self: *TextField, event: platform.Event, cx: *runtime.Context(TextField)) bool {
        switch (event) {
            // Insertion lives here exclusively. Backends emit `.text` for
            // printable input (X11 XLookupString, Wayland evdev table) and
            // `.key` for physical keys, so the `.key` branch below must not
            // insert or every keystroke lands twice.
            .text => |text_event| {
                self.append(text_event.slice());
                cx.notify();
                return true;
            },
            .key => |key_event| {
                if (!key_event.pressed) return false;
                // Clipboard shortcuts (Ctrl on Linux/Windows, Cmd on macOS).
                // They run before the editing switch and consume the key so
                // no binding or text insertion fires for them.
                if (key_event.modifiers.ctrl or key_event.modifiers.super) {
                    switch (key_event.key) {
                        .v => {
                            if (cx.window) |win| {
                                var paste: [limits.MAX_TEXT_LEN]u8 = undefined;
                                const n = win.readClipboard(&paste);
                                if (n > 0) {
                                    self.append(paste[0..n]);
                                    cx.notify();
                                }
                            }
                            return true;
                        },
                        .c => {
                            if (cx.window) |win| _ = win.writeClipboard(self.buffer[0..self.len]);
                            return true;
                        },
                        .x => {
                            if (cx.window) |win| _ = win.writeClipboard(self.buffer[0..self.len]);
                            self.len = 0;
                            self.caret = 0;
                            cx.notify();
                            return true;
                        },
                        else => {},
                    }
                }
                switch (key_event.key) {
                    .left, .right, .home, .end => {
                        self.caret = switch (key_event.key) {
                            .left => self.previousBoundary(),
                            .right => self.nextBoundary(),
                            .home => 0,
                            .end => self.len,
                            else => unreachable,
                        };
                        cx.notify();
                        return true;
                    },
                    .delete => {
                        self.erase(self.caret, self.nextBoundary());
                        cx.notify();
                        return true;
                    },
                    .backspace => {
                        const start = self.previousBoundary();
                        self.erase(start, self.caret);
                        self.caret = start;
                        cx.notify();
                        return true;
                    },
                    // Consumed without inserting: the matching `.text`
                    // event does the insertion. Returning true keeps the
                    // window from firing the space key binding mid-typing.
                    .space => return true,
                    .enter, .escape, .tab => return false,
                    else => {},
                }
                return false;
            },
            else => {},
        }
        return false;
    }

    fn append(self: *TextField, bytes: []const u8) void {
        // Accept whole UTF-8 codepoints only, including at capacity. A field
        // is single-line: pasted newlines and control bytes are ignored.
        if (!std.unicode.utf8ValidateSlice(bytes)) return;
        var i: usize = 0;
        while (i < bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return;
            defer i += n;
            if (bytes[i] < 0x20 or bytes[i] == 0x7f) continue;
            if (n > self.buffer.len - self.len) break;
            std.mem.copyBackwards(u8, self.buffer[self.caret + n .. self.len + n], self.buffer[self.caret..self.len]);
            @memcpy(self.buffer[self.caret..][0..n], bytes[i..][0..n]);
            self.len += n;
            self.caret += n;
        }
    }

    fn previousBoundary(self: *const TextField) usize {
        if (self.caret == 0) return 0;
        var pos = self.caret - 1;
        while (pos > 0 and (self.buffer[pos] & 0xc0) == 0x80) pos -= 1;
        return pos;
    }

    fn nextBoundary(self: *const TextField) usize {
        if (self.caret == self.len) return self.len;
        var pos = self.caret + 1;
        while (pos < self.len and (self.buffer[pos] & 0xc0) == 0x80) pos += 1;
        return pos;
    }

    fn erase(self: *TextField, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer[start .. self.len - (end - start)], self.buffer[end..self.len]);
        self.len -= end - start;
    }
};

test "insertion comes from text events only, never key events" {
    const t = std.testing;
    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{ .placeholder = "ph" }, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();

    // Printable insertion arrives as `.text` (X11 XLookupString, Wayland
    // evdev table) and is consumed.
    var tev = platform.event.TextEvent{};
    tev.text[0] = 'A';
    tev.len = 1;
    try t.expect(field.handleEvent(.{ .text = tev }, &cx));
    try t.expectEqual(@as(usize, 1), field.len);

    // The physical `.key` for the same letter must not insert again.
    try t.expect(!field.handleEvent(.{ .key = .{ .key = .a, .pressed = true } }, &cx));
    try t.expectEqual(@as(usize, 1), field.len);

    // Space is consumed (blocks the window space binding) but inserts
    // nothing — its `.text` twin does the inserting.
    try t.expect(field.handleEvent(.{ .key = .{ .key = .space, .pressed = true } }, &cx));
    try t.expectEqual(@as(usize, 1), field.len);

    // Editing keys still work; action keys fall through to bindings.
    try t.expect(field.handleEvent(.{ .key = .{ .key = .backspace, .pressed = true } }, &cx));
    try t.expectEqual(@as(usize, 0), field.len);
    try t.expect(!field.handleEvent(.{ .key = .{ .key = .enter, .pressed = true } }, &cx));
    try t.expect(!field.handleEvent(.{ .key = .{ .key = .a, .pressed = false } }, &cx));
}

test "clipboard shortcuts need a window and stay headless-safe" {
    const t = std.testing;
    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{ .placeholder = "ph" }, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();

    // No window attached: shortcuts consume the key but move no bytes.
    const ctrl_v = platform.event.KeyEvent{ .key = .v, .pressed = true, .modifiers = .{ .ctrl = true } };
    try t.expect(field.handleEvent(.{ .key = ctrl_v }, &cx));
    try t.expectEqual(@as(usize, 0), field.len);
}

test "caret editing preserves UTF-8 and inserts in the middle" {
    var store = runtime.EntityStore.init(std.testing.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{}, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();
    field.append("aé🙂z");
    for ([_]platform.event.Key{ .left, .left, .backspace, .delete }) |key| {
        try std.testing.expect(field.handleEvent(.{ .key = .{ .key = key, .pressed = true } }, &cx));
    }
    try std.testing.expectEqualStrings("az", field.buffer[0..field.len]);
    field.append("é");
    try std.testing.expectEqualStrings("aéz", field.buffer[0..field.len]);
    try std.testing.expectEqual(@as(usize, 3), field.caret);
    field.clear(&cx);
    try std.testing.expectEqual(@as(usize, 0), field.caret);
    field.append("\n\tA\r");
    try std.testing.expectEqualStrings("A", field.buffer[0..field.len]);
    field.clear(&cx);
    @memset(field.buffer[0 .. field.buffer.len - 1], 'a');
    field.len = field.buffer.len - 1;
    field.caret = field.len;
    field.append("é");
    try std.testing.expectEqual(field.buffer.len - 1, field.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.buffer[0..field.len]));
}
