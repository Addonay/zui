//! Normalized input events.
//!
//! Why normalize here: SDL backends never push raw OS events; they call
//! `SDL_Send*` which owns focus, dedup, and keymap before queueing.
//! ZUI copies that split: per-platform files translate to these structs,
//! the core queue owns ordering and overflow policy.

const std = @import("std");
const limits = @import("../core/limits.zig");
const geometry = @import("../core/geometry.zig");

pub const MouseButton = enum(u8) {
    left,
    middle,
    right,
    back,
    forward,
};

pub const Key = enum(u16) {
    unknown = 0,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    n0,
    n1,
    n2,
    n3,
    n4,
    n5,
    n6,
    n7,
    n8,
    n9,
    enter,
    space,
    tab,
    backspace,
    escape,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,
};

pub const MouseEvent = struct {
    pos: geometry.Point,
    button: MouseButton,
    pressed: bool,
    /// True for pointer motion (hover/drag); false for button presses and
    /// releases, which are otherwise indistinguishable on the wire.
    motion: bool = false,
    modifiers: Modifiers = .{},
    /// Milliseconds since an arbitrary monotonic epoch, from the OS event
    /// timestamp (Wayland/X11 both provide these). Zero means unknown —
    /// Window treats untimed presses as singles, never doubles. Tests
    /// synthesize timestamps for deterministic double-click coverage.
    time_ms: i64 = 0,
};

pub const KeyEvent = struct {
    key: Key,
    pressed: bool,
    modifiers: Modifiers = .{},
    repeat: bool = false,
};

pub const ScrollEvent = struct {
    pos: geometry.Point,
    /// Lines scrolled; positive dy scrolls up, positive dx scrolls right.
    /// Fractional values carry pixel-precise trackpad deltas.
    dx: f32 = 0,
    dy: f32 = 0,
    modifiers: Modifiers = .{},
};

pub const TextEvent = struct {
    text: [32]u8 = std.mem.zeroes([32]u8),
    len: u8 = 0,

    pub fn slice(self: *const @This()) []const u8 {
        std.debug.assert(self.len <= self.text.len);
        return self.text[0..self.len];
    }
};

pub const WindowEvent = enum {
    close_requested,
    resized,
    focused,
    unfocused,
};

pub const Event = union(enum) {
    mouse: MouseEvent,
    key: KeyEvent,
    text: TextEvent,
    scroll: ScrollEvent,
    window: WindowEvent,
};

/// Fixed ring queue. Push fails fast when full so producers notice
/// dropped input instead of growing under load.
pub const EventQueue = struct {
    buf: [limits.MAX_EVENTS_PER_FRAME]Event = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *@This(), ev: Event) bool {
        if (self.len >= self.buf.len) return false;
        self.buf[(self.head + self.len) % self.buf.len] = ev;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *@This()) ?Event {
        if (self.len == 0) return null;
        const ev = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        return ev;
    }

    pub fn clear(self: *@This()) void {
        self.head = 0;
        self.len = 0;
    }
};

test "event queue preserves order and reports overflow" {
    var q = EventQueue{};
    try std.testing.expect(q.pop() == null);
    try std.testing.expect(q.push(.{ .window = .close_requested }));
    try std.testing.expect(q.push(.{ .window = .focused }));
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expect(q.pop() != null);
    try std.testing.expect(q.pop() != null);
    try std.testing.expect(q.pop() == null);
}
