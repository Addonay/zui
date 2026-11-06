//! Port of the window-control types in GPUI `platform.rs`: `WindowControls` (what the window
//! manager can do), `WindowButton` and `WindowButtonLayout` (which buttons a client-drawn
//! titlebar shows, in GNOME's `button-layout` syntax).

const std = @import("std");

/// A type of window control area that corresponds to the platform window (GPUI
/// `WindowControlArea`, which GPUI keeps in window.rs).
pub const WindowControlArea = enum {
    /// An area that allows dragging of the platform window.
    drag,
    /// An area that allows closing of the platform window.
    close,
    /// An area that allows maximizing of the platform window.
    max,
    /// An area that allows minimizing of the platform window.
    min,
};

/// What window controls this platform supports (GPUI `WindowControls`). The default says
/// everything is supported, as GPUI does until the platform says otherwise.
pub const WindowControls = struct {
    /// Whether this platform supports fullscreen.
    fullscreen: bool = true,
    /// Whether this platform supports maximize.
    maximize: bool = true,
    /// Whether this platform supports minimize.
    minimize: bool = true,
    /// Whether this platform supports a window menu.
    window_menu: bool = true,
};

/// A window control button type used in `WindowButtonLayout` (GPUI `WindowButton`).
pub const WindowButton = enum {
    minimize,
    maximize,
    close,

    /// A stable element id for rendering this button (GPUI `WindowButton::id`).
    pub fn id(self: WindowButton) []const u8 {
        return switch (self) {
            .minimize => "minimize",
            .maximize => "maximize",
            .close => "close",
        };
    }

    fn index(self: WindowButton) usize {
        return switch (self) {
            .minimize => 0,
            .maximize => 1,
            .close => 2,
        };
    }
};

/// Maximum number of `WindowButton`s per side in the titlebar (GPUI `MAX_BUTTONS_PER_SIDE`).
pub const MAX_BUTTONS_PER_SIDE = 3;

pub const ButtonSide = [MAX_BUTTONS_PER_SIDE]?WindowButton;

/// Which `WindowButton`s appear on each side of the titlebar (GPUI `WindowButtonLayout`). On
/// Linux it comes from the desktop's `button-layout` setting.
pub const WindowButtonLayout = struct {
    /// Buttons on the left side of the titlebar.
    left: ButtonSide = .{ null, null, null },
    /// Buttons on the right side of the titlebar.
    right: ButtonSide = .{ null, null, null },

    pub const ParseError = error{NoValidButtons};

    /// Zed's built-in fallback layout for Linux titlebars (GPUI `linux_default`).
    pub fn linux_default() WindowButtonLayout {
        return .{
            .left = .{ null, null, null },
            .right = .{ .minimize, .maximize, .close },
        };
    }

    /// Parses a GNOME-style `button-layout` string such as `"close,minimize:maximize"` (GPUI
    /// `WindowButtonLayout::parse`). Unknown and repeated names are skipped; a string with no
    /// usable button at all is an error, so the caller can keep its default.
    pub fn parse(layout_string: []const u8) ParseError!WindowButtonLayout {
        var seen: [MAX_BUTTONS_PER_SIDE]bool = @splat(false);
        var unrecognized: usize = 0;
        const split = std.mem.indexOfScalar(u8, layout_string, ':');
        const left_str = if (split) |i| layout_string[0..i] else "";
        const right_str = if (split) |i| layout_string[i + 1 ..] else layout_string;
        const layout: WindowButtonLayout = .{
            .left = parseSide(left_str, &seen, &unrecognized),
            .right = parseSide(right_str, &seen, &unrecognized),
        };
        if (unrecognized > 0 and layout.isEmpty()) return error.NoValidButtons;
        return layout;
    }

    fn isEmpty(self: WindowButtonLayout) bool {
        for (self.left) |b| if (b != null) return false;
        for (self.right) |b| if (b != null) return false;
        return true;
    }

    fn parseSide(s: []const u8, seen: *[MAX_BUTTONS_PER_SIDE]bool, unrecognized: *usize) ButtonSide {
        var result: ButtonSide = .{ null, null, null };
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            const button: WindowButton = if (std.mem.eql(u8, name, "minimize"))
                .minimize
            else if (std.mem.eql(u8, name, "maximize"))
                .maximize
            else if (std.mem.eql(u8, name, "close"))
                .close
            else {
                unrecognized.* += 1;
                continue;
            };
            if (seen[button.index()]) continue;
            if (i < MAX_BUTTONS_PER_SIDE) {
                result[i] = button;
                seen[button.index()] = true;
                i += 1;
            }
        }
        return result;
    }

    /// Formats the layout back into a `button-layout` string, into `buf` (GPUI `format`).
    pub fn format(self: WindowButtonLayout, buf: []u8) []const u8 {
        var n: usize = 0;
        n = formatSide(self.left, buf, n);
        if (n < buf.len) {
            buf[n] = ':';
            n += 1;
        }
        n = formatSide(self.right, buf, n);
        return buf[0..n];
    }

    fn formatSide(side: ButtonSide, buf: []u8, start: usize) usize {
        var n = start;
        var first = true;
        for (side) |maybe| {
            const button = maybe orelse continue;
            if (!first) {
                if (n < buf.len) buf[n] = ',';
                n += 1;
            }
            first = false;
            const name = button.id();
            const end = @min(buf.len, n + name.len);
            if (n < end) @memcpy(buf[n..end], name[0 .. end - n]);
            n += name.len;
        }
        return n;
    }
};

test "parse standard layout" {
    const layout = try WindowButtonLayout.parse("close,minimize:maximize");
    try std.testing.expectEqualDeep(ButtonSide{ .close, .minimize, null }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ .maximize, null, null }, layout.right);
}

test "parse right only" {
    const layout = try WindowButtonLayout.parse("minimize,maximize,close");
    try std.testing.expectEqualDeep(ButtonSide{ null, null, null }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ .minimize, .maximize, .close }, layout.right);
}

test "parse left only" {
    const layout = try WindowButtonLayout.parse("close,minimize,maximize:");
    try std.testing.expectEqualDeep(ButtonSide{ .close, .minimize, .maximize }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ null, null, null }, layout.right);
}

test "parse with whitespace" {
    const layout = try WindowButtonLayout.parse(" close , minimize : maximize ");
    try std.testing.expectEqualDeep(ButtonSide{ .close, .minimize, null }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ .maximize, null, null }, layout.right);
}

test "parse empty and intentionally empty" {
    const empty = try WindowButtonLayout.parse("");
    try std.testing.expectEqualDeep(WindowButtonLayout{}, empty);
    const colon = try WindowButtonLayout.parse(":");
    try std.testing.expectEqualDeep(WindowButtonLayout{}, colon);
}

test "parse skips invalid buttons" {
    const layout = try WindowButtonLayout.parse("close,invalid,minimize:maximize,foo");
    try std.testing.expectEqualDeep(ButtonSide{ .close, .minimize, null }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ .maximize, null, null }, layout.right);
}

test "parse deduplicates buttons on one side" {
    const layout = try WindowButtonLayout.parse("close,close,minimize");
    try std.testing.expectEqualDeep(ButtonSide{ .close, .minimize, null }, layout.right);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(":close,minimize", layout.format(&buf));
}

test "parse deduplicates buttons across sides" {
    const layout = try WindowButtonLayout.parse("close:maximize,close,minimize");
    try std.testing.expectEqualDeep(ButtonSide{ .close, null, null }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ .maximize, .minimize, null }, layout.right);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("close:maximize,minimize", layout.format(&buf));
}

test "parse gnome and elementary styles" {
    const gnome = try WindowButtonLayout.parse("close");
    try std.testing.expectEqualDeep(ButtonSide{ null, null, null }, gnome.left);
    try std.testing.expectEqualDeep(ButtonSide{ .close, null, null }, gnome.right);
    const elementary = try WindowButtonLayout.parse("close:maximize");
    try std.testing.expectEqualDeep(ButtonSide{ .close, null, null }, elementary.left);
    try std.testing.expectEqualDeep(ButtonSide{ .maximize, null, null }, elementary.right);
}

test "round trip through format" {
    const cases = [_][]const u8{ "close:minimize,maximize", "minimize,maximize,close:", ":close", "close:", "close:maximize", ":" };
    for (cases) |case| {
        const layout = try WindowButtonLayout.parse(case);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(case, layout.format(&buf));
    }
}

test "linux default layout" {
    const layout = WindowButtonLayout.linux_default();
    try std.testing.expectEqualDeep(ButtonSide{ null, null, null }, layout.left);
    try std.testing.expectEqualDeep(ButtonSide{ .minimize, .maximize, .close }, layout.right);
    var buf: [64]u8 = undefined;
    const round = try WindowButtonLayout.parse(layout.format(&buf));
    try std.testing.expectEqualDeep(layout, round);
}

test "parse fails when nothing usable is named" {
    try std.testing.expectError(error.NoValidButtons, WindowButtonLayout.parse("asdfghjkl"));
}

test "window controls default to everything supported" {
    const c: WindowControls = .{};
    try std.testing.expect(c.fullscreen and c.maximize and c.minimize and c.window_menu);
}
