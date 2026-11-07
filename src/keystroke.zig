//! Keystrokes, modifier state and the GPUI keystroke syntax parser.
//! Port of gpui/src/platform/keystroke.rs.
//!
//! Keys are borrowed slices. `parse` returns slices into its input, so keymap
//! strings must outlive the keystroke. The only exception is a multi-character
//! key with uppercase letters (e.g. "Tab"), which must be lowercased: use
//! `parse_with_os` with a scratch buffer for those, or `parse` will fail.

const std = @import("std");
const builtin = @import("builtin");

/// Host operating system family, used for `secondary` and display/unparse spelling.
pub const OperatingSystem = enum { mac, windows, linux, free_bsd, ios, android, unknown };

/// The operating system this binary was built for.
pub fn host_os() OperatingSystem {
    return switch (builtin.os.tag) {
        .macos => .mac,
        .windows => .windows,
        .linux => .linux,
        .freebsd => .free_bsd,
        .ios => .ios,
        else => .unknown,
    };
}

/// Sentence explaining what the keystroke parser expects, starting with "Expected ...".
pub const KEYSTROKE_PARSE_EXPECTED_MESSAGE = "Expected a sequence of modifiers (`ctrl`, `alt`, `shift`, `fn`, `cmd`, `super`, or `win`) followed by a key, separated by `-`.";

/// Errors returned by the keystroke parser.
pub const ParseError = error{
    /// The source is not a valid keystroke. See `KEYSTROKE_PARSE_EXPECTED_MESSAGE`.
    InvalidKeystroke,
    /// The key needs lowercasing and no scratch buffer was supplied.
    ScratchRequired,
    /// The scratch buffer is too small for the lowercased key.
    ScratchTooSmall,
};

/// The state of the modifier keys at some point in time.
pub const Modifiers = struct {
    /// The control key.
    control: bool = false,
    /// The alt key. Sometimes also known as the 'meta' key.
    alt: bool = false,
    /// The shift key.
    shift: bool = false,
    /// The command key on macOS, the windows key on Windows, the super key on Linux.
    platform: bool = false,
    /// The function key.
    function: bool = false,

    /// Constructors for single-modifier values. Named under `ctor` because the
    /// fields `control`, `alt`, `shift` and `function` cannot share their names with methods.
    pub const ctor = struct {
        pub fn control() Modifiers {
            return .{ .control = true };
        }
        pub fn alt() Modifiers {
            return .{ .alt = true };
        }
        pub fn shift() Modifiers {
            return .{ .shift = true };
        }
        pub fn function() Modifiers {
            return .{ .function = true };
        }
    };

    /// Returns whether any modifier key is pressed.
    pub fn modified(self: Modifiers) bool {
        return self.control or self.alt or self.shift or self.platform or self.function;
    }

    /// Whether the semantically 'secondary' modifier is pressed for the host OS.
    /// On macOS this is the command key; elsewhere the control key.
    pub fn secondary(self: Modifiers) bool {
        return if (host_os() == .mac) self.platform else self.control;
    }

    /// Returns how many modifier keys are pressed.
    pub fn number_of_modifiers(self: Modifiers) u8 {
        return @as(u8, @intFromBool(self.control)) +
            @intFromBool(self.alt) +
            @intFromBool(self.shift) +
            @intFromBool(self.platform) +
            @intFromBool(self.function);
    }

    /// Returns `Modifiers` with no modifiers.
    pub fn none() Modifiers {
        return .{};
    }

    /// Returns `Modifiers` with just the command key.
    pub fn command() Modifiers {
        return .{ .platform = true };
    }

    /// Returns `Modifiers` with just the secondary key for the host OS.
    pub fn secondary_key() Modifiers {
        return if (host_os() == .mac) .{ .platform = true } else .{ .control = true };
    }

    /// Returns `Modifiers` with just the windows key.
    pub fn windows() Modifiers {
        return .{ .platform = true };
    }

    /// Returns `Modifiers` with just the super key.
    pub fn super_key() Modifiers {
        return .{ .platform = true };
    }

    /// Returns `Modifiers` with command + shift.
    pub fn command_shift() Modifiers {
        return .{ .shift = true, .platform = true };
    }

    /// Returns `Modifiers` with control + shift.
    pub fn control_shift() Modifiers {
        return .{ .shift = true, .control = true };
    }

    /// Checks if this `Modifiers` is a subset of another `Modifiers`.
    pub fn is_subset_of(self: Modifiers, other: Modifiers) bool {
        return self.bit_and(other).eql(self);
    }

    /// Returns true if both values have the same modifiers pressed.
    pub fn eql(self: Modifiers, other: Modifiers) bool {
        return self.control == other.control and
            self.alt == other.alt and
            self.shift == other.shift and
            self.platform == other.platform and
            self.function == other.function;
    }

    /// Union of two modifier sets (`|` in GPUI).
    pub fn bit_or(self: Modifiers, other: Modifiers) Modifiers {
        return .{
            .control = self.control or other.control,
            .alt = self.alt or other.alt,
            .shift = self.shift or other.shift,
            .platform = self.platform or other.platform,
            .function = self.function or other.function,
        };
    }

    /// Intersection of two modifier sets (`&` in GPUI).
    pub fn bit_and(self: Modifiers, other: Modifiers) Modifiers {
        return .{
            .control = self.control and other.control,
            .alt = self.alt and other.alt,
            .shift = self.shift and other.shift,
            .platform = self.platform and other.platform,
            .function = self.function and other.function,
        };
    }

    /// Symmetric difference of two modifier sets (`^` in GPUI).
    pub fn bit_xor(self: Modifiers, other: Modifiers) Modifiers {
        return .{
            .control = self.control != other.control,
            .alt = self.alt != other.alt,
            .shift = self.shift != other.shift,
            .platform = self.platform != other.platform,
            .function = self.function != other.function,
        };
    }
};

/// The state of the capslock key at some point in time.
pub const Capslock = struct {
    /// The capslock key is on.
    on: bool = false,
};

/// A keystroke and associated metadata generated by the platform.
pub const Keystroke = struct {
    /// The state of the modifier keys at the time the keystroke was generated.
    modifiers: Modifiers = .{},
    /// The character printed on the key that was pressed, e.g. "s" for option-s.
    key: []const u8 = "",
    /// The character that could have been typed, e.g. "ß" for option-s, null for cmd-s.
    key_char: ?[]const u8 = null,

    /// Checks whether a typed keystroke (`self`) matches a keymap binding (`target`).
    /// Also accepts the IME-produced character (`key_char`) for non-US layouts.
    pub fn should_match(self: *const Keystroke, target: *const Keystroke) bool {
        if (self.key_char) |key_char| {
            if (!std.mem.eql(u8, key_char, self.key)) {
                if (builtin.os.tag == .windows) {
                    // On Windows, if key_char is set, the typed keystroke produced the key_char.
                    if (std.mem.eql(u8, target.key, key_char) and target.modifiers.eql(.{})) return true;
                } else {
                    const ime_modifiers = Modifiers{
                        .control = self.modifiers.control,
                        .platform = self.modifiers.platform,
                    };
                    if (std.mem.eql(u8, target.key, key_char) and target.modifiers.eql(ime_modifiers)) return true;
                }
            }
        }
        return target.modifiers.eql(self.modifiers) and std.mem.eql(u8, target.key, self.key);
    }

    /// Parses a keystroke using the host OS for `secondary-`.
    /// Syntax: `[ctrl-][alt-][shift-][cmd-][fn-]key[->key_char]`.
    /// Fails for multi-character keys containing uppercase letters; use `parse_with_os`.
    pub fn parse(source: []const u8) ParseError!Keystroke {
        return parse_internal(source, host_os(), null);
    }

    /// Parses a keystroke, resolving `secondary-` with the supplied OS.
    /// `scratch` receives lowercased multi-character keys (e.g. "Tab"); may be null
    /// if the source has none. The returned key borrows `scratch` in that case.
    pub fn parse_with_os(source: []const u8, os: OperatingSystem, scratch: ?[]u8) ParseError!Keystroke {
        return parse_internal(source, os, scratch);
    }

    /// Serializes this keystroke with the host OS's modifier spelling. Caller owns the result.
    pub fn unparse(self: Keystroke, allocator: std.mem.Allocator) ![]u8 {
        return unparse_with_os(self, allocator, host_os());
    }

    /// Serializes this keystroke with the supplied OS's modifier spelling. Caller owns the result.
    pub fn unparse_with_os(self: Keystroke, allocator: std.mem.Allocator, os: OperatingSystem) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        if (self.modifiers.function) try w.writeAll("fn-");
        if (self.modifiers.control) try w.writeAll("ctrl-");
        if (self.modifiers.alt) try w.writeAll("alt-");
        if (self.modifiers.platform) try w.writeAll(switch (os) {
            .windows => "win-",
            .linux, .free_bsd, .android, .unknown => "super-",
            .mac, .ios => "cmd-",
        });
        if (self.modifiers.shift) try w.writeAll("shift-");
        try w.writeAll(self.key);
        return out.toOwnedSlice();
    }

    /// Formats this keystroke with the supplied OS's key labels, for use with `{f}`.
    pub fn display(self: *const Keystroke, os: OperatingSystem) KeystrokeDisplay {
        return .{ .modifiers = self.modifiers, .key = self.key, .os = os };
    }

    /// Returns true if the keystroke left the IME in an incomplete state.
    pub fn is_ime_in_progress(self: Keystroke) bool {
        return self.key_char == null and
            (is_printable_key(self.key) or self.key.len == 0) and
            !(self.modifiers.platform or self.modifiers.control or self.modifiers.function or self.modifiers.alt);
    }

    /// Returns whether the key itself is a modifier.
    pub fn is_modifier_key(self: Keystroke) bool {
        const names = [_][]const u8{ "shift", "control", "alt", "platform", "function" };
        for (names) |name| {
            if (std.mem.eql(u8, self.key, name)) return true;
        }
        return false;
    }

    /// Returns true if both keystrokes have the same modifiers, key and key_char.
    pub fn eql(self: Keystroke, other: Keystroke) bool {
        if (!self.modifiers.eql(other.modifiers)) return false;
        if (!std.mem.eql(u8, self.key, other.key)) return false;
        if (self.key_char) |a| {
            const b = other.key_char orelse return false;
            return std.mem.eql(u8, a, b);
        }
        return other.key_char == null;
    }

    /// The keystroke itself (GPUI `AsKeystroke::as_keystroke`). Lets code take either a `Keystroke`
    /// or a `KeybindingKeystroke`.
    pub fn as_keystroke(self: *const Keystroke) *const Keystroke {
        return self;
    }

    /// Fills in `key_char` the way a typed key would produce it, for a keystroke the platform
    /// gave none (GPUI `Keystroke::with_simulated_ime`): "space", "tab" and "enter" type their
    /// characters, a printable key types itself, and shift uppercases an ASCII letter. Any other
    /// key with shift is left as it is: GPUI's `to_uppercase` can change the length of non-ASCII
    /// text, and no static buffer here could hold that.
    pub fn with_simulated_ime(self: Keystroke) Keystroke {
        var out = self;
        if (self.key_char != null or self.modifiers.platform or self.modifiers.control or self.modifiers.function or self.modifiers.alt) {
            return out;
        }
        if (std.mem.eql(u8, self.key, "space")) {
            out.key_char = " ";
        } else if (std.mem.eql(u8, self.key, "tab")) {
            out.key_char = "\t";
        } else if (std.mem.eql(u8, self.key, "enter")) {
            out.key_char = "\n";
        } else if (self.key.len == 0 or !is_printable_key(self.key)) {
            out.key_char = null;
        } else if (self.modifiers.shift and self.key.len == 1 and std.ascii.isLower(self.key[0])) {
            const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            out.key_char = upper[self.key[0] - 'a' ..][0..1];
        } else {
            out.key_char = self.key;
        }
        return out;
    }
};

/// A keystroke as a keybinding holds it (GPUI `KeybindingKeystroke`). On Linux and the headless
/// platform it is only the keystroke; GPUI's Windows build adds display fields, which ZUI does not
/// have yet. `KeyBinding` still stores a plain `Keystroke`.
pub const KeybindingKeystroke = struct {
    inner: Keystroke,

    /// Wraps a keystroke without any platform mapping (GPUI `from_keystroke`).
    pub fn from_keystroke(keystroke: Keystroke) KeybindingKeystroke {
        return .{ .inner = keystroke };
    }

    /// Wraps a keystroke after the platform's key equivalents mapping (GPUI `new_with_mapper`).
    /// `mapper` is any value with `map_key_equivalent(Keystroke, bool) Keystroke`, such as
    /// `platform.KeyboardMapper`.
    pub fn new_with_mapper(inner: Keystroke, use_key_equivalents: bool, mapper: anytype) KeybindingKeystroke {
        return .{ .inner = mapper.map_key_equivalent(inner, use_key_equivalents) };
    }

    /// The keystroke (GPUI `AsKeystroke::as_keystroke`).
    pub fn as_keystroke(self: *const KeybindingKeystroke) *const Keystroke {
        return &self.inner;
    }

    /// Sets the modifiers (GPUI `set_modifiers`).
    pub fn set_modifiers(self: *KeybindingKeystroke, modifiers: Modifiers) void {
        self.inner.modifiers = modifiers;
    }

    /// Sets the key (GPUI `set_key`). The slice must outlive the keystroke, as `Keystroke.key` does.
    pub fn set_key(self: *KeybindingKeystroke, key: []const u8) void {
        self.inner.key = key;
    }

    /// Removes the key_char (GPUI `remove_key_char`).
    pub fn remove_key_char(self: *KeybindingKeystroke) void {
        self.inner.key_char = null;
    }

    /// Serializes this binding with the host OS's modifier spelling (GPUI `unparse`).
    pub fn unparse(self: *const KeybindingKeystroke, allocator: std.mem.Allocator, os: OperatingSystem) ![]u8 {
        return self.inner.unparse_with_os(allocator, os);
    }
};

/// A keystroke formatted for a specific OS. Use with `{f}`.
pub const KeystrokeDisplay = struct {
    modifiers: Modifiers,
    key: []const u8,
    os: OperatingSystem,

    pub fn format(self: KeystrokeDisplay, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try display_modifiers(self.modifiers, self.os, writer);
        try display_key(self.key, self.os, writer);
    }
};

/// Returns false for keys that are not printable characters (function keys, navigation keys, ...).
pub fn is_printable_key(key: []const u8) bool {
    const named = [_][]const u8{
        "backspace", "delete", "left", "right", "up",      "down",   "pageup", "pagedown",
        "insert",    "home",   "end",  "back",  "forward", "escape",
    };
    for (named) |name| {
        if (std.mem.eql(u8, key, name)) return false;
    }
    return !is_function_key(key);
}

/// True for "f1" through "f35".
fn is_function_key(key: []const u8) bool {
    if (key.len < 2 or key.len > 3 or key[0] != 'f' or key[1] == '0') return false;
    for (key[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    const n = std.fmt.parseInt(u8, key[1..], 10) catch return false;
    return n >= 1 and n <= 35;
}

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz";

fn parse_internal(source: []const u8, os: OperatingSystem, scratch: ?[]u8) ParseError!Keystroke {
    var modifiers: Modifiers = .{};
    var key: ?[]const u8 = null;
    var key_char: ?[]const u8 = null;

    var components = std.mem.splitScalar(u8, source, '-');
    while (components.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, "ctrl")) {
            modifiers.control = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "alt")) {
            modifiers.alt = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "shift")) {
            modifiers.shift = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "fn")) {
            modifiers.function = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "secondary")) {
            if (os == .mac) {
                modifiers.platform = true;
            } else {
                modifiers.control = true;
            }
            continue;
        }
        const is_platform = std.ascii.eqlIgnoreCase(component, "cmd") or
            std.ascii.eqlIgnoreCase(component, "super") or
            std.ascii.eqlIgnoreCase(component, "win");
        if (is_platform) {
            modifiers.platform = true;
            continue;
        }

        if (components.peek()) |next| {
            if (next.len == 0 and source.len > 0 and source[source.len - 1] == '-') {
                // "-" is the key itself, e.g. "ctrl--".
                key = "-";
                break;
            } else if (next.len > 1 and next[0] == '>') {
                key = component;
                key_char = next[1..];
                _ = components.next();
                continue;
            } else {
                return error.InvalidKeystroke;
            }
        }

        if (component.len == 1 and std.ascii.isUpper(component[0])) {
            // Uppercase letter means shift + lowercase letter.
            modifiers.shift = true;
        }
        key = try lower_key(component, scratch);
    }

    // A modifier used as the key itself, e.g. "shift" or "cmd" alone. Only the first is taken.
    if (key == null) {
        if (modifiers.shift) {
            modifiers.shift = false;
            key = "shift";
        } else if (modifiers.control) {
            modifiers.control = false;
            key = "control";
        } else if (modifiers.alt) {
            modifiers.alt = false;
            key = "alt";
        } else if (modifiers.platform) {
            modifiers.platform = false;
            key = "platform";
        } else if (modifiers.function) {
            modifiers.function = false;
            key = "function";
        }
    }

    return .{
        .modifiers = modifiers,
        .key = key orelse return error.InvalidKeystroke,
        .key_char = key_char,
    };
}

/// Lowercases a key component. Single letters use a static table; longer keys use `scratch`.
fn lower_key(component: []const u8, scratch: ?[]u8) ParseError![]const u8 {
    var has_upper = false;
    for (component) |c| {
        if (std.ascii.isUpper(c)) has_upper = true;
    }
    if (!has_upper) return component;
    if (component.len == 1) {
        const i = component[0] - 'A';
        return lowercase_letters[i .. i + 1];
    }
    const buf = scratch orelse return error.ScratchRequired;
    if (component.len > buf.len) return error.ScratchTooSmall;
    for (component, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..component.len];
}

fn display_modifiers(modifiers: Modifiers, os: OperatingSystem, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (modifiers.control) try w.writeAll(if (os == .mac) "^" else "ctrl-");
    if (modifiers.alt) try w.writeAll(if (os == .mac) "⌥" else "alt-");
    if (modifiers.platform) try w.writeAll(switch (os) {
        .mac => "⌘",
        .windows => "⊞",
        .linux, .free_bsd => "❖",
        .ios, .android, .unknown => "cmd-",
    });
    if (modifiers.shift) try w.writeAll(if (os == .mac) "⇧" else "shift-");
}

fn display_key(key: []const u8, os: OperatingSystem, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (os == .mac) {
        const symbols = [_][2][]const u8{
            .{ "backspace", "⌫" },
            .{ "up", "↑" },
            .{ "down", "↓" },
            .{ "left", "←" },
            .{ "right", "→" },
            .{ "tab", "⇥" },
            .{ "escape", "⎋" },
            .{ "shift", "⇧" },
            .{ "control", "⌃" },
            .{ "alt", "⌥" },
            .{ "platform", "⌘" },
        };
        for (symbols) |pair| {
            if (std.mem.eql(u8, key, pair[0])) return w.writeAll(pair[1]);
        }
    }
    if (key.len == 1) return w.writeByte(std.ascii.toUpper(key[0]));
    return w.writeAll(key);
}

test "parse modifiers and key" {
    const k = try Keystroke.parse_with_os("cmd-shift-a", .linux, null);
    try std.testing.expect(k.modifiers.platform);
    try std.testing.expect(k.modifiers.shift);
    try std.testing.expect(!k.modifiers.control);
    try std.testing.expectEqualStrings("a", k.key);
    try std.testing.expect(k.key_char == null);

    const d = try Keystroke.parse_with_os("ctrl-alt-delete", .linux, null);
    try std.testing.expect(d.modifiers.control and d.modifiers.alt);
    try std.testing.expectEqual(@as(u8, 2), d.modifiers.number_of_modifiers());
    try std.testing.expectEqualStrings("delete", d.key);
}

test "parse is case insensitive for modifiers and named keys" {
    var buf: [8]u8 = undefined;
    const t = try Keystroke.parse_with_os("CTRL-Alt-Tab", .linux, &buf);
    try std.testing.expect(t.modifiers.control and t.modifiers.alt);
    try std.testing.expectEqualStrings("tab", t.key);
    try std.testing.expectError(error.ScratchRequired, Keystroke.parse("Tab"));
}

test "parse uppercase letter adds shift" {
    const k = try Keystroke.parse_with_os("A", .linux, null);
    try std.testing.expect(k.modifiers.shift);
    try std.testing.expectEqualStrings("a", k.key);

    const c = try Keystroke.parse_with_os("cmd-A", .linux, null);
    try std.testing.expect(c.modifiers.platform and c.modifiers.shift);
    try std.testing.expectEqualStrings("a", c.key);
}

test "parse secondary depends on OS" {
    const mac = try Keystroke.parse_with_os("secondary-s", .mac, null);
    try std.testing.expect(mac.modifiers.platform);
    try std.testing.expect(!mac.modifiers.control);

    inline for (.{ OperatingSystem.linux, OperatingSystem.windows }) |os| {
        const k = try Keystroke.parse_with_os("secondary-s", os, null);
        try std.testing.expect(k.modifiers.control);
        try std.testing.expect(!k.modifiers.platform);
    }
}

test "parse dash key and modifier-as-key" {
    const dash = try Keystroke.parse_with_os("ctrl--", .linux, null);
    try std.testing.expect(dash.modifiers.control);
    try std.testing.expectEqualStrings("-", dash.key);

    const shift = try Keystroke.parse_with_os("shift", .linux, null);
    try std.testing.expectEqualStrings("shift", shift.key);
    try std.testing.expect(!shift.modifiers.shift);

    const cmd = try Keystroke.parse_with_os("cmd", .linux, null);
    try std.testing.expectEqualStrings("platform", cmd.key);
    try std.testing.expect(!cmd.modifiers.platform);
}

test "parse key_char suffix" {
    const k = try Keystroke.parse_with_os("alt-s->ß", .linux, null);
    try std.testing.expect(k.modifiers.alt);
    try std.testing.expectEqualStrings("s", k.key);
    try std.testing.expectEqualStrings("ß", k.key_char.?);
}

test "parse function keys and invalid input" {
    const f = try Keystroke.parse_with_os("fn-f1", .linux, null);
    try std.testing.expect(f.modifiers.function);
    try std.testing.expectEqualStrings("f1", f.key);

    try std.testing.expectError(error.InvalidKeystroke, Keystroke.parse_with_os("ctrl-a-b", .linux, null));
}

test "should_match accepts IME key_char" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const typed = Keystroke{ .modifiers = .{ .alt = true }, .key = "s", .key_char = "ß" };
    const binding = Keystroke{ .key = "ß" };
    try std.testing.expect(typed.should_match(&binding));

    const exact = Keystroke{ .modifiers = .{ .alt = true }, .key = "s" };
    try std.testing.expect(exact.should_match(&exact));
    try std.testing.expect(!exact.should_match(&binding));
}

test "unparse per OS" {
    const k = try Keystroke.parse_with_os("fn-ctrl-cmd-shift-a", .mac, null);
    const mac = try k.unparse_with_os(std.testing.allocator, .mac);
    defer std.testing.allocator.free(mac);
    try std.testing.expectEqualStrings("fn-ctrl-cmd-shift-a", mac);

    const linux = try k.unparse_with_os(std.testing.allocator, .linux);
    defer std.testing.allocator.free(linux);
    try std.testing.expectEqualStrings("fn-ctrl-super-shift-a", linux);
}

test "display per OS" {
    const k = try Keystroke.parse_with_os("cmd-shift-a", .mac, null);
    const mac = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{k.display(.mac)});
    defer std.testing.allocator.free(mac);
    try std.testing.expectEqualStrings("⌘⇧A", mac);

    const up = try Keystroke.parse_with_os("up", .mac, null);
    const arrow = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{up.display(.mac)});
    defer std.testing.allocator.free(arrow);
    try std.testing.expectEqualStrings("↑", arrow);
}

test "modifiers set operations" {
    const cs = Modifiers.command_shift();
    try std.testing.expect(Modifiers.ctor.shift().is_subset_of(cs));
    try std.testing.expect(!Modifiers.ctor.alt().is_subset_of(cs));
    try std.testing.expect(cs.modified());
    try std.testing.expect(!Modifiers.none().modified());
    try std.testing.expect(cs.bit_and(Modifiers.command()).eql(Modifiers.command()));
    try std.testing.expect(cs.bit_xor(Modifiers.command()).eql(Modifiers.ctor.shift()));
    try std.testing.expect(Modifiers.ctor.control().bit_or(Modifiers.ctor.alt()).number_of_modifiers() == 2);
}

test "is_printable_key and ime state" {
    try std.testing.expect(!is_printable_key("f1"));
    try std.testing.expect(!is_printable_key("f35"));
    try std.testing.expect(is_printable_key("f36"));
    try std.testing.expect(is_printable_key("a"));
    try std.testing.expect(!is_printable_key("escape"));

    const typing = Keystroke{ .key = "a" };
    try std.testing.expect(typing.is_ime_in_progress());
    const chorded = Keystroke{ .modifiers = .{ .control = true }, .key = "a" };
    try std.testing.expect(!chorded.is_ime_in_progress());
}

test "with_simulated_ime fills key_char like a typed key" {
    try std.testing.expectEqualStrings(" ", Keystroke.with_simulated_ime(.{ .key = "space" }).key_char.?);
    try std.testing.expectEqualStrings("\t", Keystroke.with_simulated_ime(.{ .key = "tab" }).key_char.?);
    try std.testing.expectEqualStrings("\n", Keystroke.with_simulated_ime(.{ .key = "enter" }).key_char.?);
    try std.testing.expectEqualStrings("a", Keystroke.with_simulated_ime(.{ .key = "a" }).key_char.?);
    try std.testing.expectEqualStrings("B", Keystroke.with_simulated_ime(.{ .key = "b", .modifiers = .{ .shift = true } }).key_char.?);
    // Not typed: escape, function keys, and chords with command, control, alt or fn.
    try std.testing.expect(Keystroke.with_simulated_ime(.{ .key = "escape" }).key_char == null);
    try std.testing.expect(Keystroke.with_simulated_ime(.{ .key = "f1" }).key_char == null);
    try std.testing.expect(Keystroke.with_simulated_ime(.{ .key = "a", .modifiers = .{ .control = true } }).key_char == null);
    try std.testing.expect(Keystroke.with_simulated_ime(.{ .key = "a", .modifiers = .{ .platform = true } }).key_char == null);
    // An existing key_char is kept.
    try std.testing.expectEqualStrings("x", Keystroke.with_simulated_ime(.{ .key = "a", .key_char = "x" }).key_char.?);
}

test "keybinding keystroke setters" {
    var ks = KeybindingKeystroke.from_keystroke(.{ .key = "a", .key_char = "a" });
    try std.testing.expectEqualStrings("a", ks.as_keystroke().key);
    ks.set_key("b");
    ks.set_modifiers(.{ .control = true });
    try std.testing.expectEqualStrings("b", ks.as_keystroke().key);
    try std.testing.expect(ks.as_keystroke().modifiers.control);
    ks.remove_key_char();
    try std.testing.expect(ks.as_keystroke().key_char == null);

    const plain: Keystroke = .{ .key = "c" };
    try std.testing.expect(plain.as_keystroke() == &plain);
}
