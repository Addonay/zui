//! Input translation shared by the Linux backends: key naming (GPUI
//! `keystroke_from_xkb` rules), modifier masks, mouse buttons, click
//! counting and the monotonic clock.

const std = @import("std");
const interactive = @import("../../interactive.zig");
const keystroke = @import("../../keystroke.zig");
const geometry = @import("../../geometry.zig");

pub const Modifiers = keystroke.Modifiers;
pub const Keystroke = keystroke.Keystroke;
pub const MouseButton = interactive.MouseButton;

/// Modifier bits shared by X11 `state` and `wl_keyboard.modifiers` (xkb indices).
pub const MOD_SHIFT: u32 = 1 << 0;
pub const MOD_CONTROL: u32 = 1 << 2;
pub const MOD_ALT: u32 = 1 << 3;
pub const MOD_SUPER: u32 = 1 << 6;

pub fn modifiers(mask: u32) Modifiers {
    return .{
        .shift = mask & MOD_SHIFT != 0,
        .control = mask & MOD_CONTROL != 0,
        .alt = mask & MOD_ALT != 0,
        .platform = mask & MOD_SUPER != 0,
    };
}

/// Linux evdev button codes (linux/input-event-codes.h).
pub fn evdev_button(code: u32) ?MouseButton {
    return switch (code) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        0x113 => .{ .navigate = .back },
        0x114 => .{ .navigate = .forward },
        0x115 => .{ .navigate = .forward },
        0x116 => .{ .navigate = .back },
        else => null,
    };
}

/// X11 core button numbers. 4-7 are wheel steps and are handled as scroll.
pub fn x11_button(code: u32) ?MouseButton {
    return switch (code) {
        1 => .left,
        2 => .middle,
        3 => .right,
        8 => .{ .navigate = .back },
        9 => .{ .navigate = .forward },
        else => null,
    };
}

/// Monotonic milliseconds (click timing, key repeat, frame pacing).
pub fn now_ms() i64 {
    var ts = std.mem.zeroes(std.os.linux.timespec);
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Static one-character strings for printable ASCII (0x20..0x7e).
const ascii_strings: [95][1]u8 = blk: {
    var t: [95][1]u8 = undefined;
    for (&t, 0..) |*s, i| s.* = .{@as(u8, 0x20 + i)};
    break :blk t;
};

fn ascii_slice(c: u8) []const u8 {
    return &ascii_strings[c - 0x20];
}

/// Key name for a printable ASCII byte: lowercase letters, others unchanged.
fn name_for_char(c: u8) []const u8 {
    return ascii_slice(std.ascii.toLower(c));
}

/// A key resolved from a keysym or an evdev code: its normalized name and the
/// text it types (null for non-printable keys).
pub const KeyInfo = struct {
    name: []const u8,
    char: ?u8 = null,
};

/// Keysyms for keys with a normalized GPUI name. Printable ASCII maps to the
/// lowercase character, controls map to their GPUI names.
pub fn key_name_for_keysym(sym: u32) ?[]const u8 {
    return switch (sym) {
        0x20 => "space",
        0x21...0x7e => name_for_char(@intCast(sym)),
        0xff08 => "backspace",
        0xff09, 0xfe20 => "tab",
        0xff0d, 0xff8d => "enter",
        0xff1b => "escape",
        0xffff => "delete",
        0xff50 => "home",
        0xff51 => "left",
        0xff52 => "up",
        0xff53 => "right",
        0xff54 => "down",
        0xff55 => "pageup",
        0xff56 => "pagedown",
        0xff57 => "end",
        0xff63 => "insert",
        0xff80 => "space",
        0xff89 => "tab",
        0xffaa => "*",
        0xffab => "+",
        0xffad => "-",
        0xffae => ".",
        0xffaf => "/",
        0xffb0...0xffb9 => ascii_slice(@intCast(0x30 + sym - 0xffb0)),
        0xffbe...0xffd5 => fkey_names[sym - 0xffbe],
        else => null,
    };
}

const fkey_names = [_][]const u8{
    "f1",  "f2",  "f3",  "f4",  "f5",  "f6",  "f7",  "f8",  "f9",  "f10", "f11", "f12",
    "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24",
};

/// True for Shift, Control, Alt, Super and friends: they never join compose sequences.
pub fn is_modifier_keysym(sym: u32) bool {
    return (sym >= 0xffe1 and sym <= 0xffee) or (sym >= 0xfe01 and sym <= 0xfe0f) or sym == 0xff7e or sym == 0xff7f;
}

/// How many key repeats are due at `now`, and when the next one is. Repeats are scheduled
/// from the previous deadline, not from `now`, so a late wakeup does not slow the rate.
/// After a long stall the backlog is dropped instead of flooding the app.
pub const RepeatStep = struct { count: u32, next_ms: i64 };
pub const max_repeat_burst: u32 = 8;

pub fn repeat_step(now: i64, next_ms: i64, interval_ms: i64) RepeatStep {
    if (now < next_ms) return .{ .count = 0, .next_ms = next_ms };
    const interval = @max(interval_ms, 1);
    const count = @divFloor(now - next_ms, interval) + 1;
    if (count > max_repeat_burst) return .{ .count = max_repeat_burst, .next_ms = now + interval };
    return .{ .count = @intCast(count), .next_ms = next_ms + count * interval };
}

test "key repeat keeps its rate across late wakeups" {
    try std.testing.expectEqual(RepeatStep{ .count = 0, .next_ms = 100 }, repeat_step(99, 100, 25));
    try std.testing.expectEqual(RepeatStep{ .count = 1, .next_ms = 125 }, repeat_step(100, 100, 25));
    // 7 ms late: the next deadline does not move.
    try std.testing.expectEqual(RepeatStep{ .count = 1, .next_ms = 125 }, repeat_step(107, 100, 25));
    // Two periods late: both are delivered.
    try std.testing.expectEqual(RepeatStep{ .count = 3, .next_ms = 175 }, repeat_step(150, 100, 25));
    // A long stall drops the backlog.
    try std.testing.expectEqual(RepeatStep{ .count = max_repeat_burst, .next_ms = 5025 }, repeat_step(5000, 100, 25));
}

test "modifier keysyms" {
    try std.testing.expect(is_modifier_keysym(0xffe1)); // Shift_L
    try std.testing.expect(is_modifier_keysym(0xfe03)); // ISO_Level3_Shift
    try std.testing.expect(!is_modifier_keysym('a'));
    try std.testing.expect(!is_modifier_keysym(0xfe51)); // dead_acute
}

/// UTF-8 text for a keysym (printable only). Returns a slice into `buf`.
pub fn utf8_for_keysym(sym: u32, buf: *[4]u8) ?[]const u8 {
    const cp: u21 = switch (sym) {
        0x20...0x7e => @intCast(sym),
        0xa0...0xff => @intCast(sym),
        0xffb0...0xffb9 => @intCast(0x30 + sym - 0xffb0),
        0xffaa => '*',
        0xffab => '+',
        0xffad => '-',
        0xffae => '.',
        0xffaf => '/',
        0x01000000...0x0110ffff => @intCast(sym - 0x01000000),
        else => return null,
    };
    const n = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..n];
}

/// Text for an evdev key under the US layout (fallback without xkbcommon).
pub fn evdev_key(code: u32, shift: bool) ?KeyInfo {
    if (code >= evdev_table.len) return null;
    const e = evdev_table[code];
    if (e.name.len == 0 and e.plain == 0) return null;
    if (e.plain == 0) return .{ .name = e.name };
    const c = if (shift and e.shifted != 0) e.shifted else e.plain;
    const name = if (e.name.len > 0) e.name else name_for_char(c);
    return .{ .name = name, .char = c };
}

const Entry = struct {
    name: []const u8 = "",
    plain: u8 = 0,
    shifted: u8 = 0,
};

fn ch(plain: u8, shifted: u8) Entry {
    return .{ .plain = plain, .shifted = shifted };
}

fn named(name: []const u8) Entry {
    return .{ .name = name };
}

/// evdev keycode (without the +8 X/xkb offset) to US-layout entry.
const evdev_table: [256]Entry = blk: {
    var t: [256]Entry = undefined;
    for (&t) |*e| e.* = .{};
    t[1] = named("escape");
    t[2] = ch('1', '!');
    t[3] = ch('2', '@');
    t[4] = ch('3', '#');
    t[5] = ch('4', '$');
    t[6] = ch('5', '%');
    t[7] = ch('6', '^');
    t[8] = ch('7', '&');
    t[9] = ch('8', '*');
    t[10] = ch('9', '(');
    t[11] = ch('0', ')');
    t[12] = ch('-', '_');
    t[13] = ch('=', '+');
    t[14] = named("backspace");
    t[15] = named("tab");
    const qwerty = "qwertyuiop";
    for (qwerty, 0..) |c, i| t[16 + i] = ch(c, std.ascii.toUpper(c));
    t[26] = ch('[', '{');
    t[27] = ch(']', '}');
    t[28] = named("enter");
    const asdf = "asdfghjkl";
    for (asdf, 0..) |c, i| t[30 + i] = ch(c, std.ascii.toUpper(c));
    t[39] = ch(';', ':');
    t[40] = ch('\'', '"');
    t[41] = ch('`', '~');
    t[43] = ch('\\', '|');
    const zxcv = "zxcvbnm";
    for (zxcv, 0..) |c, i| t[44 + i] = ch(c, std.ascii.toUpper(c));
    t[51] = ch(',', '<');
    t[52] = ch('.', '>');
    t[53] = ch('/', '?');
    t[57] = .{ .name = "space", .plain = ' ', .shifted = ' ' };
    t[59] = named("f1");
    t[60] = named("f2");
    t[61] = named("f3");
    t[62] = named("f4");
    t[63] = named("f5");
    t[64] = named("f6");
    t[65] = named("f7");
    t[66] = named("f8");
    t[67] = named("f9");
    t[68] = named("f10");
    t[87] = named("f11");
    t[88] = named("f12");
    t[96] = named("enter");
    t[102] = named("home");
    t[103] = named("up");
    t[104] = named("pageup");
    t[105] = named("left");
    t[106] = named("right");
    t[107] = named("end");
    t[108] = named("down");
    t[109] = named("pagedown");
    t[110] = named("insert");
    t[111] = named("delete");
    break :blk t;
};

/// Builds a keystroke from a resolved name and typed text. Like GPUI, shift
/// is dropped for keys without case (digits, symbols) and text that is a
/// control character is not reported as `key_char`.
pub fn make_keystroke(name: []const u8, text: ?[]const u8, mods: Modifiers) Keystroke {
    var m = mods;
    if (name.len == 1 and !std.ascii.isAlphabetic(name[0])) m.shift = false;
    var key_char: ?[]const u8 = null;
    if (text) |t| {
        if (t.len > 0 and !(t.len == 1 and (t[0] < 0x20 or t[0] == 0x7f))) key_char = t;
    }
    return .{ .modifiers = m, .key = name, .key_char = key_char };
}

/// Converts a Latin-1 byte (X11 `XLookupString` output) to UTF-8.
pub fn latin1_to_utf8(byte: u8, buf: *[4]u8) []const u8 {
    if (byte < 0x80) {
        buf[0] = byte;
        return buf[0..1];
    }
    const n = std.unicode.utf8Encode(@as(u21, byte), buf) catch return buf[0..0];
    return buf[0..n];
}

/// Double-click detection (GPUI counts clicks within the system interval).
pub const ClickTracker = struct {
    const interval_ms: i64 = 500;
    const slop: f32 = 4;

    button: ?MouseButton = null,
    time_ms: i64 = 0,
    pos: geometry.Point(geometry.Pixels) = .{ .x = 0, .y = 0 },
    count: usize = 0,

    /// Registers a press and returns its click count (1 for a single click).
    pub fn press(self: *ClickTracker, button: MouseButton, pos: geometry.Point(geometry.Pixels)) usize {
        const now = now_ms();
        const near = @abs(pos.x - self.pos.x) <= slop and @abs(pos.y - self.pos.y) <= slop;
        const same = if (self.button) |b| b.eql(button) else false;
        if (same and near and now - self.time_ms <= interval_ms) {
            self.count += 1;
        } else {
            self.count = 1;
        }
        self.button = button;
        self.time_ms = now;
        self.pos = pos;
        return self.count;
    }
};

test "keysym naming matches GPUI keystroke names" {
    try std.testing.expectEqualStrings("a", key_name_for_keysym('A').?);
    try std.testing.expectEqualStrings("1", key_name_for_keysym('1').?);
    try std.testing.expectEqualStrings("space", key_name_for_keysym(0x20).?);
    try std.testing.expectEqualStrings("enter", key_name_for_keysym(0xff0d).?);
    try std.testing.expectEqualStrings("backspace", key_name_for_keysym(0xff08).?);
    try std.testing.expectEqualStrings("escape", key_name_for_keysym(0xff1b).?);
    try std.testing.expectEqualStrings("f1", key_name_for_keysym(0xffbe).?);
    try std.testing.expectEqualStrings("f12", key_name_for_keysym(0xffc9).?);
    try std.testing.expect(key_name_for_keysym(0xffe1) == null);
}

test "evdev fallback resolves letters and shifted symbols" {
    const a = evdev_key(30, false).?;
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expectEqual(@as(u8, 'a'), a.char.?);
    const bang = evdev_key(2, true).?;
    try std.testing.expectEqualStrings("!", bang.name);
    try std.testing.expectEqual(@as(u8, '!'), bang.char.?);
    try std.testing.expectEqualStrings("enter", evdev_key(28, false).?.name);
    try std.testing.expect(evdev_key(28, false).?.char == null);
}

test "keystroke drops shift for symbols and control text" {
    const ks = make_keystroke("!", "!", .{ .shift = true });
    try std.testing.expect(!ks.modifiers.shift);
    try std.testing.expectEqualStrings("!", ks.key_char.?);
    const tab = make_keystroke("tab", "\t", .{});
    try std.testing.expect(tab.key_char == null);
}

test "click tracker counts repeated presses" {
    var t = ClickTracker{};
    const p: geometry.Point(geometry.Pixels) = .{ .x = 10, .y = 10 };
    try std.testing.expectEqual(@as(usize, 1), t.press(.left, p));
    try std.testing.expectEqual(@as(usize, 2), t.press(.left, p));
    try std.testing.expectEqual(@as(usize, 1), t.press(.right, p));
}

/// Device scale forced by ZUI_SCALE, then GDK_SCALE. Null when neither is set.
pub fn env_scale() ?f32 {
    if (std.c.getenv("ZUI_SCALE")) |v| {
        const f = std.fmt.parseFloat(f32, std.mem.span(v)) catch return null;
        if (f >= 0.25 and f <= 8) return f;
    }
    if (std.c.getenv("GDK_SCALE")) |v| {
        const i = std.fmt.parseInt(u32, std.mem.span(v), 10) catch return null;
        if (i >= 1 and i <= 8) return @floatFromInt(i);
    }
    return null;
}
