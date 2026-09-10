//! Linux evdev keycode tables shared by the Wayland and X11 backends.
//!
//! Pattern ported from gooey's `platform/linux/input.zig` (MIT, Duane
//! Bester): Linux evdev codes are the stable numbering — Wayland's
//! `wl_keyboard.key` reports evdev+8 and X11 keycodes are evdev+8 too — so
//! one table serves both backends. US-QWERTY text mapping, same documented
//! limitation as the reference (full xkbcommon would be needed for other
//! layouts); symbols beyond ASCII arrive via X11's `XLookupString`.

const std = @import("std");
const event = @import("../event.zig");

/// Linux evdev keycodes (from linux/input-event-codes.h). Only keys our
/// `event.Key` enum or US text mapping can express.
pub const evdev = struct {
    pub const KEY_ESC: u32 = 1;
    pub const KEY_1: u32 = 2;
    pub const KEY_2: u32 = 3;
    pub const KEY_3: u32 = 4;
    pub const KEY_4: u32 = 5;
    pub const KEY_5: u32 = 6;
    pub const KEY_6: u32 = 7;
    pub const KEY_7: u32 = 8;
    pub const KEY_8: u32 = 9;
    pub const KEY_9: u32 = 10;
    pub const KEY_0: u32 = 11;
    pub const KEY_MINUS: u32 = 12;
    pub const KEY_EQUAL: u32 = 13;
    pub const KEY_BACKSPACE: u32 = 14;
    pub const KEY_TAB: u32 = 15;
    pub const KEY_Q: u32 = 16;
    pub const KEY_W: u32 = 17;
    pub const KEY_E: u32 = 18;
    pub const KEY_R: u32 = 19;
    pub const KEY_T: u32 = 20;
    pub const KEY_Y: u32 = 21;
    pub const KEY_U: u32 = 22;
    pub const KEY_I: u32 = 23;
    pub const KEY_O: u32 = 24;
    pub const KEY_P: u32 = 25;
    pub const KEY_LEFTBRACE: u32 = 26;
    pub const KEY_RIGHTBRACE: u32 = 27;
    pub const KEY_ENTER: u32 = 28;
    pub const KEY_LEFTCTRL: u32 = 29;
    pub const KEY_A: u32 = 30;
    pub const KEY_S: u32 = 31;
    pub const KEY_D: u32 = 32;
    pub const KEY_F: u32 = 33;
    pub const KEY_G: u32 = 34;
    pub const KEY_H: u32 = 35;
    pub const KEY_J: u32 = 36;
    pub const KEY_K: u32 = 37;
    pub const KEY_L: u32 = 38;
    pub const KEY_SEMICOLON: u32 = 39;
    pub const KEY_APOSTROPHE: u32 = 40;
    pub const KEY_GRAVE: u32 = 41;
    pub const KEY_LEFTSHIFT: u32 = 42;
    pub const KEY_BACKSLASH: u32 = 43;
    pub const KEY_Z: u32 = 44;
    pub const KEY_X: u32 = 45;
    pub const KEY_C: u32 = 46;
    pub const KEY_V: u32 = 47;
    pub const KEY_B: u32 = 48;
    pub const KEY_N: u32 = 49;
    pub const KEY_M: u32 = 50;
    pub const KEY_COMMA: u32 = 51;
    pub const KEY_DOT: u32 = 52;
    pub const KEY_SLASH: u32 = 53;
    pub const KEY_RIGHTSHIFT: u32 = 54;
    pub const KEY_LEFTALT: u32 = 56;
    pub const KEY_SPACE: u32 = 57;
    pub const KEY_F1: u32 = 59;
    pub const KEY_F2: u32 = 60;
    pub const KEY_F3: u32 = 61;
    pub const KEY_F4: u32 = 62;
    pub const KEY_F5: u32 = 63;
    pub const KEY_F6: u32 = 64;
    pub const KEY_F7: u32 = 65;
    pub const KEY_F8: u32 = 66;
    pub const KEY_F9: u32 = 67;
    pub const KEY_F10: u32 = 68;
    pub const KEY_HOME: u32 = 102;
    pub const KEY_UP: u32 = 103;
    pub const KEY_PAGEUP: u32 = 104;
    pub const KEY_LEFT: u32 = 105;
    pub const KEY_RIGHT: u32 = 106;
    pub const KEY_END: u32 = 107;
    pub const KEY_DOWN: u32 = 108;
    pub const KEY_PAGEDOWN: u32 = 109;
    pub const KEY_DELETE: u32 = 111;
    pub const KEY_F11: u32 = 87;
    pub const KEY_F12: u32 = 88;
    pub const KEY_RIGHTCTRL: u32 = 97;
    pub const KEY_RIGHTALT: u32 = 100;
    pub const KEY_LEFTMETA: u32 = 125;
    pub const KEY_RIGHTMETA: u32 = 126;
    pub const KEY_KP1: u32 = 79;
    pub const KEY_KP2: u32 = 80;
    pub const KEY_KP3: u32 = 81;
    pub const KEY_KP0: u32 = 82;
    pub const KEY_KPDOT: u32 = 83;
    pub const KEY_KPENTER: u32 = 96;
};

/// Standard XKB modifier bit positions. Wayland's `wl_keyboard.modifiers`
/// and X11's key/button `state` share these low bits (Shift=bit0,
/// Ctrl=bit2, Alt/Mod1=bit3, Super/Mod4=bit6).
pub const xkb_mod = struct {
    pub const SHIFT: u32 = 1 << 0;
    pub const CAPS: u32 = 1 << 1;
    pub const CTRL: u32 = 1 << 2;
    pub const ALT: u32 = 1 << 3;
    pub const SUPER: u32 = 1 << 6;
};

/// Build our `Modifiers` from an XKB/X11 modifier mask.
pub fn modifiersFromMask(mask: u32) event.Modifiers {
    return .{
        .shift = (mask & xkb_mod.SHIFT) != 0,
        .ctrl = (mask & xkb_mod.CTRL) != 0,
        .alt = (mask & xkb_mod.ALT) != 0,
        .super = (mask & xkb_mod.SUPER) != 0,
    };
}

/// Map an evdev keycode to our normalized `Key`. Returns `.unknown` for
/// keys we have no binding use for (modifiers, keypad, paging).
pub fn keyFromEvdev(code: u32) event.Key {
    return switch (code) {
        evdev.KEY_A => .a,
        evdev.KEY_B => .b,
        evdev.KEY_C => .c,
        evdev.KEY_D => .d,
        evdev.KEY_E => .e,
        evdev.KEY_F => .f,
        evdev.KEY_G => .g,
        evdev.KEY_H => .h,
        evdev.KEY_I => .i,
        evdev.KEY_J => .j,
        evdev.KEY_K => .k,
        evdev.KEY_L => .l,
        evdev.KEY_M => .m,
        evdev.KEY_N => .n,
        evdev.KEY_O => .o,
        evdev.KEY_P => .p,
        evdev.KEY_Q => .q,
        evdev.KEY_R => .r,
        evdev.KEY_S => .s,
        evdev.KEY_T => .t,
        evdev.KEY_U => .u,
        evdev.KEY_V => .v,
        evdev.KEY_W => .w,
        evdev.KEY_X => .x,
        evdev.KEY_Y => .y,
        evdev.KEY_Z => .z,
        evdev.KEY_1 => .n1,
        evdev.KEY_2 => .n2,
        evdev.KEY_3 => .n3,
        evdev.KEY_4 => .n4,
        evdev.KEY_5 => .n5,
        evdev.KEY_6 => .n6,
        evdev.KEY_7 => .n7,
        evdev.KEY_8 => .n8,
        evdev.KEY_9 => .n9,
        evdev.KEY_0 => .n0,
        evdev.KEY_ENTER, evdev.KEY_KPENTER => .enter,
        evdev.KEY_SPACE => .space,
        evdev.KEY_TAB => .tab,
        evdev.KEY_BACKSPACE => .backspace,
        evdev.KEY_ESC => .escape,
        evdev.KEY_DELETE => .delete,
        evdev.KEY_LEFT => .left,
        evdev.KEY_RIGHT => .right,
        evdev.KEY_UP => .up,
        evdev.KEY_DOWN => .down,
        evdev.KEY_HOME => .home,
        evdev.KEY_END => .end,
        evdev.KEY_F1 => .f1,
        evdev.KEY_F2 => .f2,
        evdev.KEY_F3 => .f3,
        evdev.KEY_F4 => .f4,
        evdev.KEY_F5 => .f5,
        evdev.KEY_F6 => .f6,
        evdev.KEY_F7 => .f7,
        evdev.KEY_F8 => .f8,
        evdev.KEY_F9 => .f9,
        evdev.KEY_F10 => .f10,
        evdev.KEY_F11 => .f11,
        evdev.KEY_F12 => .f12,
        else => .unknown,
    };
}

/// Map an evdev keycode + shift to a printable ASCII byte (US QWERTY).
/// Null for non-printable keys. Backends push this as `.text`; the `.key`
/// event stays purely physical for shortcuts and bindings.
pub fn charFromEvdev(code: u32, shift: bool) ?u8 {
    return switch (code) {
        evdev.KEY_A => if (shift) 'A' else 'a',
        evdev.KEY_B => if (shift) 'B' else 'b',
        evdev.KEY_C => if (shift) 'C' else 'c',
        evdev.KEY_D => if (shift) 'D' else 'd',
        evdev.KEY_E => if (shift) 'E' else 'e',
        evdev.KEY_F => if (shift) 'F' else 'f',
        evdev.KEY_G => if (shift) 'G' else 'g',
        evdev.KEY_H => if (shift) 'H' else 'h',
        evdev.KEY_I => if (shift) 'I' else 'i',
        evdev.KEY_J => if (shift) 'J' else 'j',
        evdev.KEY_K => if (shift) 'K' else 'k',
        evdev.KEY_L => if (shift) 'L' else 'l',
        evdev.KEY_M => if (shift) 'M' else 'm',
        evdev.KEY_N => if (shift) 'N' else 'n',
        evdev.KEY_O => if (shift) 'O' else 'o',
        evdev.KEY_P => if (shift) 'P' else 'p',
        evdev.KEY_Q => if (shift) 'Q' else 'q',
        evdev.KEY_R => if (shift) 'R' else 'r',
        evdev.KEY_S => if (shift) 'S' else 's',
        evdev.KEY_T => if (shift) 'T' else 't',
        evdev.KEY_U => if (shift) 'U' else 'u',
        evdev.KEY_V => if (shift) 'V' else 'v',
        evdev.KEY_W => if (shift) 'W' else 'w',
        evdev.KEY_X => if (shift) 'X' else 'x',
        evdev.KEY_Y => if (shift) 'Y' else 'y',
        evdev.KEY_Z => if (shift) 'Z' else 'z',
        evdev.KEY_1 => if (shift) '!' else '1',
        evdev.KEY_2 => if (shift) '@' else '2',
        evdev.KEY_3 => if (shift) '#' else '3',
        evdev.KEY_4 => if (shift) '$' else '4',
        evdev.KEY_5 => if (shift) '%' else '5',
        evdev.KEY_6 => if (shift) '^' else '6',
        evdev.KEY_7 => if (shift) '&' else '7',
        evdev.KEY_8 => if (shift) '*' else '8',
        evdev.KEY_9 => if (shift) '(' else '9',
        evdev.KEY_0 => if (shift) ')' else '0',
        evdev.KEY_MINUS => if (shift) '_' else '-',
        evdev.KEY_EQUAL => if (shift) '+' else '=',
        evdev.KEY_LEFTBRACE => if (shift) '{' else '[',
        evdev.KEY_RIGHTBRACE => if (shift) '}' else ']',
        evdev.KEY_SEMICOLON => if (shift) ':' else ';',
        evdev.KEY_APOSTROPHE => if (shift) '"' else '\'',
        evdev.KEY_GRAVE => if (shift) '~' else '`',
        evdev.KEY_BACKSLASH => if (shift) '|' else '\\',
        evdev.KEY_COMMA => if (shift) '<' else ',',
        evdev.KEY_DOT => if (shift) '>' else '.',
        evdev.KEY_SLASH => if (shift) '?' else '/',
        evdev.KEY_SPACE => ' ',
        evdev.KEY_TAB => '\t',
        evdev.KEY_KP1 => '1',
        evdev.KEY_KP2 => '2',
        evdev.KEY_KP3 => '3',
        evdev.KEY_KP0 => '0',
        evdev.KEY_KPDOT => '.',
        else => null,
    };
}

/// True for modifier keys, which never produce text or key repeat.
pub fn isModifier(code: u32) bool {
    return switch (code) {
        evdev.KEY_LEFTSHIFT,
        evdev.KEY_RIGHTSHIFT,
        evdev.KEY_LEFTCTRL,
        evdev.KEY_RIGHTCTRL,
        evdev.KEY_LEFTALT,
        evdev.KEY_RIGHTALT,
        evdev.KEY_LEFTMETA,
        evdev.KEY_RIGHTMETA,
        => true,
        else => false,
    };
}

test "evdev letters map both cases" {
    try std.testing.expectEqual(event.Key.a, keyFromEvdev(evdev.KEY_A));
    try std.testing.expectEqual(event.Key.z, keyFromEvdev(evdev.KEY_Z));
    try std.testing.expectEqual(event.Key.enter, keyFromEvdev(evdev.KEY_ENTER));
    try std.testing.expectEqual(event.Key.enter, keyFromEvdev(evdev.KEY_KPENTER));
    try std.testing.expectEqual(event.Key.f1, keyFromEvdev(evdev.KEY_F1));
    try std.testing.expectEqual(event.Key.unknown, keyFromEvdev(evdev.KEY_LEFTSHIFT));
    try std.testing.expectEqual(event.Key.unknown, keyFromEvdev(999));
}

test "evdev text respects shift" {
    try std.testing.expectEqual(@as(?u8, 'a'), charFromEvdev(evdev.KEY_A, false));
    try std.testing.expectEqual(@as(?u8, 'A'), charFromEvdev(evdev.KEY_A, true));
    try std.testing.expectEqual(@as(?u8, '1'), charFromEvdev(evdev.KEY_1, false));
    try std.testing.expectEqual(@as(?u8, '!'), charFromEvdev(evdev.KEY_1, true));
    try std.testing.expectEqual(@as(?u8, '?'), charFromEvdev(evdev.KEY_SLASH, true));
    try std.testing.expectEqual(@as(?u8, null), charFromEvdev(evdev.KEY_ENTER, false));
    try std.testing.expectEqual(@as(?u8, null), charFromEvdev(evdev.KEY_F5, false));
}

test "modifier mask decodes xkb bits" {
    const mods = modifiersFromMask((1 << 0) | (1 << 2));
    try std.testing.expect(mods.shift and mods.ctrl);
    try std.testing.expect(!mods.alt and !mods.super);
    const alt = modifiersFromMask(1 << 3);
    try std.testing.expect(alt.alt);
}

test "modifier detection covers both hands" {
    try std.testing.expect(isModifier(evdev.KEY_LEFTSHIFT));
    try std.testing.expect(isModifier(evdev.KEY_RIGHTCTRL));
    try std.testing.expect(isModifier(evdev.KEY_LEFTMETA));
    try std.testing.expect(!isModifier(evdev.KEY_A));
    try std.testing.expect(!isModifier(evdev.KEY_SPACE));
}
