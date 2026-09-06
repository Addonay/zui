const std = @import("std");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const limits = @import("../core/limits.zig");

pub const TextField = struct {
    pub const Options = struct {
        placeholder: []const u8 = "",
    };

    buffer: [limits.MAX_TEXT_LEN]u8 = undefined,
    len: usize = 0,
    placeholder: []const u8,

    pub fn init(_: *runtime.Context(TextField), options: Options) TextField {
        return .{ .placeholder = options.placeholder };
    }

    pub fn trimmedText(self: *const TextField) []const u8 {
        return std.mem.trim(u8, self.buffer[0..self.len], " \t\r\n");
    }

    pub fn clear(self: *TextField, cx: *runtime.Context(TextField)) void {
        self.len = 0;
        cx.notify();
    }

    pub fn render(self: *TextField, window: *@import("../app/window.zig").Window, cx: *runtime.Context(TextField)) elements.Element {
        const focused = window.focused.eql(cx.focusHandle());
        const value = if (self.len == 0) self.placeholder else self.buffer[0..self.len];
        const color = if (self.len == 0) @import("../core/color.zig").Color.hex(0x6f7082) else @import("../core/color.zig").Color.hex(0xf2f2f5);
        var field = elements.div().h(40).size_full().px(8).items_center()
            .rounded_lg()
            .border_1()
            .border_color(if (focused) @import("../core/color.zig").Color.hex(0x7c5cff) else @import("../core/color.zig").Color.transparent)
            .child(elements.text(value, .{ .size = 14, .color = color }));
        if (focused and self.len > 0) {
            const cursor_x = @as(f32, @floatFromInt(self.len)) * 8.96 + 8;
            field = field.child(elements.div().absolute().left(cursor_x).top(10).w(1).h(20).bg(@import("../core/color.zig").Color.hex(0x46d5e8)));
        }
        return field.withFocus(cx.focusHandle());
    }

    pub fn handleEvent(self: *TextField, event: platform.Event, cx: *runtime.Context(TextField)) bool {
        switch (event) {
            .text => |text_event| {
                self.append(text_event.slice());
                cx.notify();
                return true;
            },
            .key => |key_event| {
                if (!key_event.pressed) return false;
                switch (key_event.key) {
                    .backspace => {
                        self.removeLastCodepoint();
                        cx.notify();
                        return true;
                    },
                    .space => {
                        self.append(" ");
                        cx.notify();
                        return true;
                    },
                    .enter, .escape, .tab => return false,
                    else => {},
                }
                if (asciiForKey(key_event.key, key_event.modifiers.shift)) |byte| {
                    var bytes = [1]u8{byte};
                    self.append(&bytes);
                    cx.notify();
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn append(self: *TextField, bytes: []const u8) void {
        const available = self.buffer.len - self.len;
        const count = @min(available, bytes.len);
        @memcpy(self.buffer[self.len..][0..count], bytes[0..count]);
        self.len += count;
    }

    fn removeLastCodepoint(self: *TextField) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and (self.buffer[self.len] & 0xc0) == 0x80) self.len -= 1;
    }
};

fn asciiForKey(key: platform.event.Key, shift: bool) ?u8 {
    const value: ?u8 = switch (key) {
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .n0 => '0',
        .n1 => '1',
        .n2 => '2',
        .n3 => '3',
        .n4 => '4',
        .n5 => '5',
        .n6 => '6',
        .n7 => '7',
        .n8 => '8',
        .n9 => '9',
        else => null,
    };
    if (value) |byte| {
        if (shift and byte >= 'a' and byte <= 'z') return byte - ('a' - 'A');
        return byte;
    }
    return null;
}
