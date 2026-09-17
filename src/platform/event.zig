//! Normalized input events.
//!
//! Why normalize here: SDL backends never push raw OS events; they call
//! `SDL_Send*` which owns focus, dedup, and keymap before queueing.
//! ZUI copies that split: per-platform files translate to these structs,
//! the core queue owns ordering and overflow policy.

const std = @import("std");
const limits = @import("../core/limits.zig");
const geometry = @import("../core/geometry.zig");
const zlog = @import("../core/log.zig");

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

/// Fixed ring queue with an explicit overflow policy (gap §3).
/// Capacity is `limits.MAX_EVENTS_PER_FRAME` (256). Producers historically
/// ignored `push()` failure, silently losing input under load. The policy:
///
/// - Critical events are never silently dropped: key-up, mouse button-up,
///   text commit (IME composition-commit), window close, and focus loss
///   (unfocused). `pushCritical` evicts the oldest coalescable event
///   (motion/resize) to make room; only a queue with no coalescable victim
///   fails, and then it logs + counts `critical_overflow` and returns an
///   error so the producer must notice.
/// - Coalescable events (pointer motion, window resize) merge: when full,
///   an incoming motion replaces the newest queued motion (same for
///   resize) instead of growing or dropping criticals. Counts `coalesced`.
/// - Everything else (key-down, button-down, focus-gain, scroll) is
///   droppable under pressure: counted in `dropped` and reported false.
///   Scroll is droppable (not coalesced: deltas do not merge safely here).
///
/// Counters are observable budgets (never reset by `clear()`); see the
/// capacity policy in `core/limits.zig`.
pub const EventQueue = struct {
    buf: [limits.MAX_EVENTS_PER_FRAME]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    /// Droppable non-critical events discarded while full.
    dropped: u64 = 0,
    /// Motion/resize arrivals merged into a queued peer while full.
    coalesced: u64 = 0,
    /// Coalescable victims evicted to admit a critical event.
    critical_evictions: u64 = 0,
    /// Critical events that found no coalescable victim (logged, errored).
    critical_overflow: u64 = 0,

    /// Events that must not disappear: releases, commits, close, focus loss.
    pub fn isCritical(ev: Event) bool {
        return switch (ev) {
            .key => |k| !k.pressed,
            .mouse => |m| !m.motion and !m.pressed,
            .text => true,
            .scroll => false,
            .window => |w| switch (w) {
                .close_requested, .unfocused => true,
                .resized, .focused => false,
            },
        };
    }

    /// Events safe to merge under pressure: motion and resize. Latest state
    /// wins; no closure/commit semantics are lost by replacing a peer.
    pub fn isCoalescable(ev: Event) bool {
        return switch (ev) {
            .mouse => |m| m.motion,
            .window => |w| w == .resized,
            else => false,
        };
    }

    fn sameCoalesceKind(a: Event, b: Event) bool {
        return switch (a) {
            .mouse => |m| m.motion and switch (b) {
                .mouse => |n| n.motion,
                else => false,
            },
            .window => |w| w == .resized and switch (b) {
                .window => |v| v == .resized,
                else => false,
            },
            else => false,
        };
    }

    fn at(self: *const @This(), logical: usize) Event {
        return self.buf[(self.head + logical) % self.buf.len];
    }

    fn setAt(self: *@This(), logical: usize, ev: Event) void {
        self.buf[(self.head + logical) % self.buf.len] = ev;
    }

    fn removeAt(self: *@This(), logical: usize) void {
        var i = logical;
        while (i + 1 < self.len) : (i += 1) {
            self.setAt(i, self.at(i + 1));
        }
        self.len -= 1;
    }

    /// Merge `ev` into the newest queued peer of the same coalesce kind.
    /// Returns true when a peer was replaced.
    fn coalesceInto(self: *@This(), ev: Event) bool {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            if (sameCoalesceKind(self.at(i), ev)) {
                self.setAt(i, ev);
                self.coalesced += 1;
                return true;
            }
        }
        return false;
    }

    /// Drop the oldest coalescable entry to free one slot. Returns true
    /// when a victim was evicted.
    fn evictOldestCoalescable(self: *@This()) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (isCoalescable(self.at(i))) {
                self.removeAt(i);
                self.critical_evictions += 1;
                return true;
            }
        }
        return false;
    }

    fn pushSlot(self: *@This(), ev: Event) void {
        self.buf[(self.head + self.len) % self.buf.len] = ev;
        self.len += 1;
    }

    /// Legacy push: never grows; applies the overflow policy. Critical
    /// arrivals route through `pushCritical` (evict-then-insert); returns
    /// false only when the event was dropped (counted + logged) so legacy
    /// producers that ignore the result still leave an observable trace.
    pub fn push(self: *@This(), ev: Event) bool {
        if (self.len < self.buf.len) {
            self.pushSlot(ev);
            return true;
        }
        if (isCoalescable(ev)) {
            if (self.coalesceInto(ev)) return true;
            self.dropped += 1;
            zlog.log("event", "queue full ({d}); coalescable dropped with no peer", .{self.buf.len});
            return false;
        }
        if (isCritical(ev)) {
            self.pushCritical(ev) catch return false;
            return true;
        }
        self.dropped += 1;
        zlog.log("event", "queue full ({d}); droppable event discarded", .{self.buf.len});
        return false;
    }

    /// Critical push: evicts the oldest coalescable motion/resize to make
    /// room. Fails with `error.CriticalEventDropped` (plus log + counter)
    /// only when the full queue holds no coalescable victim — the producer
    /// must notice; the event is never silently lost.
    pub const CriticalError = error{CriticalEventDropped};

    pub fn pushCritical(self: *@This(), ev: Event) CriticalError!void {
        if (self.len < self.buf.len) {
            self.pushSlot(ev);
            return;
        }
        // A full queue may still hold a mergeable peer for coalescable
        // criticals (none today — criticals are not coalescable — but keep
        // the order: merge before evict).
        if (isCoalescable(ev)) {
            if (self.coalesceInto(ev)) return;
        }
        if (self.evictOldestCoalescable()) {
            self.pushSlot(ev);
            return;
        }
        self.critical_overflow += 1;
        zlog.log("event", "queue full ({d}); CRITICAL event dropped, no coalescable victim", .{self.buf.len});
        return CriticalError.CriticalEventDropped;
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

test "full queue coalesces motion instead of growing" {
    var q = EventQueue{};
    // Fill with motion events (coalescable).
    var i: usize = 0;
    while (i < q.buf.len) : (i += 1) {
        try std.testing.expect(q.push(.{ .mouse = .{
            .pos = .{ .x = @floatFromInt(i), .y = 0 },
            .button = .left,
            .pressed = false,
            .motion = true,
        } }));
    }
    try std.testing.expectEqual(q.buf.len, q.len);
    // A fresh motion merges into a queued peer: admitted, length stable.
    try std.testing.expect(q.push(.{ .mouse = .{
        .pos = .{ .x = 9999, .y = 9999 },
        .button = .left,
        .pressed = false,
        .motion = true,
    } }));
    try std.testing.expectEqual(q.buf.len, q.len);
    try std.testing.expectEqual(@as(u64, 1), q.coalesced);
    // The newest motion peer carries the fresh position.
    var found_fresh = false;
    var j: usize = 0;
    while (j < q.len) : (j += 1) {
        const ev = q.buf[(q.head + j) % q.buf.len];
        if (ev == .mouse and ev.mouse.pos.x == 9999) found_fresh = true;
    }
    try std.testing.expect(found_fresh);
}

test "critical events evict motion to make room" {
    var q = EventQueue{};
    // One motion victim + the rest droppable key-downs.
    try std.testing.expect(q.push(.{ .mouse = .{
        .pos = .{ .x = 1, .y = 1 },
        .button = .left,
        .pressed = false,
        .motion = true,
    } }));
    var i: usize = 1;
    while (i < q.buf.len) : (i += 1) {
        try std.testing.expect(q.push(.{ .key = .{ .key = .a, .pressed = true } }));
    }
    try std.testing.expectEqual(q.buf.len, q.len);
    // Key-up is critical: evicts the motion, keeps length at capacity.
    try std.testing.expect(q.push(.{ .key = .{ .key = .a, .pressed = false } }));
    try std.testing.expectEqual(q.buf.len, q.len);
    try std.testing.expectEqual(@as(u64, 1), q.critical_evictions);
    // No motion survives; the critical key-up is queued.
    var saw_motion = false;
    var saw_keyup = false;
    var j: usize = 0;
    while (j < q.len) : (j += 1) {
        const ev = q.buf[(q.head + j) % q.buf.len];
        if (ev == .mouse) saw_motion = true;
        if (ev == .key and !ev.key.pressed) saw_keyup = true;
    }
    try std.testing.expect(!saw_motion);
    try std.testing.expect(saw_keyup);
}

test "critical with no victim errors instead of silent loss" {
    var q = EventQueue{};
    // Fill entirely with critical key-ups (nothing coalescable to evict).
    var i: usize = 0;
    while (i < q.buf.len) : (i += 1) {
        try std.testing.expect(q.push(.{ .key = .{ .key = .a, .pressed = false } }));
    }
    // Another critical cannot be admitted: error + counter, never silent.
    try std.testing.expectError(error.CriticalEventDropped, q.pushCritical(.{ .window = .close_requested }));
    try std.testing.expectEqual(@as(u64, 1), q.critical_overflow);
    try std.testing.expectEqual(q.buf.len, q.len);
    // And the legacy push reports false for the same arrival.
    try std.testing.expect(!q.push(.{ .window = .close_requested }));
    try std.testing.expectEqual(@as(u64, 2), q.critical_overflow);
    // Droppable arrivals under pressure count and report false.
    var r = EventQueue{};
    var k: usize = 0;
    while (k < r.buf.len) : (k += 1) {
        _ = r.push(.{ .key = .{ .key = .a, .pressed = true } });
    }
    try std.testing.expect(!r.push(.{ .key = .{ .key = .b, .pressed = true } }));
    try std.testing.expectEqual(@as(u64, 1), r.dropped);
}
