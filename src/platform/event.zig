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

/// All protocol ranges are UTF-8 byte offsets, half-open. Native adapters
/// must convert UTF-16 offsets explicitly. No borrowed strings enter the queue.
pub const TextRange = struct { start: usize = 0, end: usize = 0 };
pub const CompositionText = struct {
    bytes: [256]u8 = @splat(0),
    len: u16 = 0,
    /// Selection within preedit, not within surrounding committed text.
    marked: TextRange = .{},
    /// Optional replacement in committed surrounding text (UTF-8 bytes).
    replacement: ?TextRange = null,
    pub fn init(text: []const u8) !CompositionText {
        if (text.len > 256) return error.TextTooLong;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        var result = CompositionText{};
        @memcpy(result.bytes[0..text.len], text);
        result.len = @intCast(text.len);
        result.marked = .{ .start = text.len, .end = text.len };
        return result;
    }
    pub fn slice(self: *const CompositionText) ?[]const u8 {
        if (self.len > self.bytes.len) return null;
        const text = self.bytes[0..self.len];
        if (!std.unicode.utf8ValidateSlice(text)) return null;
        if (self.marked.start > self.marked.end or self.marked.end > text.len) return null;
        for ([_]usize{ self.marked.start, self.marked.end }) |i| {
            if (i < text.len and text[i] & 0xc0 == 0x80) return null;
        }
        return text;
    }
};
pub const CompositionEvent = union(enum) {
    preedit: CompositionText,
    commit: CompositionText,
    cancel,
};

/// GPUI-compatible phases for direct contacts. A contact is hit-tested on
/// `started`; subsequent phases retain that target until ended/cancelled.
pub const TouchPhase = enum { started, moved, ended, cancelled };
pub const TouchId = u64;
pub const PointerKind = enum { finger, pen, eraser };

pub const TouchEvent = struct {
    id: TouchId,
    phase: TouchPhase,
    pos: geometry.Point,
    predicted_pos: ?geometry.Point = null,
    force: ?f32 = null,
    kind: PointerKind = .finger,
};

pub const PenEvent = struct {
    id: TouchId,
    phase: TouchPhase,
    pos: geometry.Point,
    pressure: f32 = 0,
    tilt_x: f32 = 0,
    tilt_y: f32 = 0,
    twist: f32 = 0,
    buttons: u8 = 0,
    modifiers: Modifiers = .{},
};

pub const PressureStage = enum { zero, normal, force };
pub const PressureEvent = struct {
    pos: geometry.Point,
    pressure: f32,
    stage: PressureStage = .normal,
    modifiers: Modifiers = .{},
};

pub const PinchEvent = struct {
    pos: geometry.Point,
    delta: f32,
    phase: TouchPhase,
    modifiers: Modifiers = .{},
};

/// File paths are copied into the event envelope; platform adapters never
/// put borrowed OS strings into the queue. This keeps drag/drop delivery
/// deterministic and bounded in headless tests.
pub const ExternalPath = struct { bytes: [256]u8 = std.mem.zeroes([256]u8), len: u16 = 0 };
pub const DragDropKind = enum { entered, over, dropped, exited, ended };
pub const DragDropEvent = struct {
    kind: DragDropKind,
    pos: geometry.Point = .{},
    paths: [8]ExternalPath = undefined,
    path_count: u8 = 0,

    pub fn addPath(self: *@This(), path_bytes: []const u8) !void {
        if (self.path_count >= self.paths.len) return error.TooManyPaths;
        if (path_bytes.len > self.paths[0].bytes.len) return error.PathTooLong;
        if (std.mem.indexOfScalar(u8, path_bytes, 0) != null) return error.InvalidPath;
        const slot = &self.paths[self.path_count];
        @memcpy(slot.bytes[0..path_bytes.len], path_bytes);
        slot.len = @intCast(path_bytes.len);
        self.path_count += 1;
    }

    pub fn path(self: *const @This(), index: usize) ?[]const u8 {
        if (index >= self.path_count) return null;
        const slot = &self.paths[index];
        return slot.bytes[0..slot.len];
    }
};

/// Additive rich input envelope. The legacy `Event` union below intentionally
/// remains stable; platform adapters can translate this envelope at the
/// window boundary once a consumer opts in.
pub const InputEvent = union(enum) {
    touch: TouchEvent,
    pen: PenEvent,
    pressure: PressureEvent,
    pinch: PinchEvent,
    drag_drop: DragDropEvent,
};

pub const GestureKind = enum { none, tap, long_press, pan, pinch };
pub const GestureTuning = struct {
    touch_slop: f32 = 8,
    long_press_ms: i64 = 500,
    multi_tap_ms: i64 = 400,
    multi_tap_slop: f32 = 16,
};

pub const GestureOutput = union(enum) {
    none,
    tap: struct { pos: geometry.Point, count: u8, long_press: bool },
    pan: struct { pos: geometry.Point, delta: geometry.Point, phase: TouchPhase },
    pinch: struct { pos: geometry.Point, scale_delta: f32, phase: TouchPhase },
};

/// Small, allocation-free recognizer for two contacts. It models GPUI’s
/// target-retention and tap/pan/pinch competition, while leaving scrolling
/// physics to scroll containers.
pub const GestureRecognizer = struct {
    tuning: GestureTuning = .{},
    first: ?Contact = null,
    second: ?Contact = null,
    last_tap_pos: geometry.Point = .{},
    last_tap_ms: i64 = std.math.minInt(i64),
    tap_count: u8 = 0,
    kind: GestureKind = .none,

    const Contact = struct { id: TouchId, start: geometry.Point, pos: geometry.Point, start_ms: i64 };

    pub fn update(self: *@This(), ev: TouchEvent, now_ms: i64) GestureOutput {
        switch (ev.phase) {
            .started => return self.start(ev, now_ms),
            .moved => {},
            .ended, .cancelled => return self.finish(ev, now_ms),
        }
        const contact = self.find(ev.id) orelse return .none;
        const previous = contact.pos;
        if (self.second != null) {
            self.kind = .pinch;
            const old_a = self.first.?.pos;
            const old_b = self.second.?.pos;
            const a: geometry.Point = if (self.first.?.id == ev.id) ev.pos else old_a;
            const b: geometry.Point = if (self.second.?.id == ev.id) ev.pos else old_b;
            const old_dist = distance(old_a, old_b);
            const new_dist = distance(a, b);
            const center: geometry.Point = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
            if (self.first.?.id == ev.id) self.first.?.pos = ev.pos else self.second.?.pos = ev.pos;
            return .{ .pinch = .{ .pos = center, .scale_delta = if (old_dist == 0) 0 else new_dist / old_dist - 1, .phase = .moved } };
        }
        if (self.kind == .none and distance(contact.start, ev.pos) > self.tuning.touch_slop) self.kind = .pan;
        if (self.first.?.id == ev.id) self.first.?.pos = ev.pos else self.second.?.pos = ev.pos;
        if (self.kind == .pan) return .{ .pan = .{ .pos = ev.pos, .delta = .{ .x = ev.pos.x - previous.x, .y = ev.pos.y - previous.y }, .phase = .moved } };
        return .none;
    }

    fn start(self: *@This(), ev: TouchEvent, now_ms: i64) GestureOutput {
        const c = Contact{ .id = ev.id, .start = ev.pos, .pos = ev.pos, .start_ms = now_ms };
        if (self.first == null) self.first = c else if (self.second == null) {
            self.second = c;
            self.kind = .pinch;
        } else return .none;
        return .none;
    }

    fn finish(self: *@This(), ev: TouchEvent, now_ms: i64) GestureOutput {
        const c = self.find(ev.id) orelse return .none;
        const elapsed = now_ms - c.start_ms;
        const was_pinch = self.second != null;
        const was_pan = self.kind == .pan;
        self.remove(ev.id);
        if (was_pinch) {
            self.kind = if (self.first != null) .pan else .none;
            return .{ .pinch = .{ .pos = ev.pos, .scale_delta = 0, .phase = ev.phase } };
        }
        if (was_pan) {
            self.kind = .none;
            return .{ .pan = .{ .pos = ev.pos, .delta = .{}, .phase = ev.phase } };
        }
        if (ev.phase == .ended) {
            const long = elapsed >= self.tuning.long_press_ms;
            const repeated = self.last_tap_ms != std.math.minInt(i64) and now_ms >= self.last_tap_ms and now_ms - self.last_tap_ms <= self.tuning.multi_tap_ms and distance(self.last_tap_pos, ev.pos) <= self.tuning.multi_tap_slop;
            if (repeated) self.tap_count +|= 1 else self.tap_count = 1;
            self.last_tap_pos = ev.pos;
            self.last_tap_ms = now_ms;
            return .{ .tap = .{ .pos = ev.pos, .count = self.tap_count, .long_press = long } };
        }
        self.kind = .none;
        return .none;
    }

    fn find(self: *@This(), id: TouchId) ?*Contact {
        if (self.first) |*c| if (c.id == id) return c;
        if (self.second) |*c| if (c.id == id) return c;
        return null;
    }
    fn remove(self: *@This(), id: TouchId) void {
        if (self.first != null and self.first.?.id == id) {
            self.first = self.second;
            self.second = null;
        } else if (self.second != null and self.second.?.id == id) self.second = null;
    }
    fn distance(a: geometry.Point, b: geometry.Point) f32 {
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        return @sqrt(dx * dx + dy * dy);
    }
};
/// Consumer supplies window-local logical pixels; backend converts to native
/// screen coordinates/DPI. Optional and headless-safe, called after placement.
pub const CaretReporter = struct {
    context: ?*anyopaque = null,
    report: ?*const fn (?*anyopaque, geometry.Rect) void = null,
    pub fn update(self: CaretReporter, rect: geometry.Rect) void {
        if (self.report) |callback| callback(self.context, rect);
    }
};

pub const WindowEvent = enum {
    close_requested,
    resized,
    focused,
    unfocused,
    /// Framework-internal cancellation for an unmounted/modal-replaced
    /// interaction. Native backends never emit this event.
    cancelled,
    scale_changed,
    /// Compositor-delivered animation frame aligned with native presentation.
    frame_ready,
};

pub const EventPayload = union(enum) {
    mouse: MouseEvent,
    key: KeyEvent,
    text: TextEvent,
    composition: CompositionEvent,
    scroll: ScrollEvent,
    window: WindowEvent,
};

pub const Event = union(enum) {
    /// Explicit destination. Untargeted legacy events are accepted by App only
    /// when exactly one live window exists; they are never broadcast.
    targeted: struct { window_id: u32, payload: EventPayload },
    mouse: MouseEvent,
    key: KeyEvent,
    text: TextEvent,
    composition: CompositionEvent,
    scroll: ScrollEvent,
    window: WindowEvent,

    pub fn forWindow(self: Event, window_id: u32) Event {
        return switch (self) {
            .targeted => |envelope| .{ .targeted = .{ .window_id = window_id, .payload = envelope.payload } },
            inline else => |payload, tag| .{ .targeted = .{ .window_id = window_id, .payload = @unionInit(EventPayload, @tagName(tag), payload) } },
        };
    }

    pub fn untargeted(self: Event) Event {
        return switch (self) {
            .targeted => |envelope| switch (envelope.payload) {
                inline else => |payload, tag| @unionInit(Event, @tagName(tag), payload),
            },
            else => self,
        };
    }

    /// Destination for routing: null for legacy untargeted events.
    pub fn targetWindowId(self: Event) ?u32 {
        return if (self == .targeted) self.targeted.window_id else null;
    }
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
            .targeted => isCritical(ev.untargeted()),
            .key => |k| !k.pressed,
            .mouse => |m| !m.motion and !m.pressed,
            .text => true,
            .composition => |c| switch (c) {
                .commit, .cancel => true,
                .preedit => false,
            },
            .scroll => false,
            .window => |w| switch (w) {
                .close_requested, .unfocused, .cancelled, .frame_ready => true,
                .resized, .focused, .scale_changed => false,
            },
        };
    }

    /// Events safe to merge under pressure: motion and resize. Latest state
    /// wins; no closure/commit semantics are lost by replacing a peer.
    pub fn isCoalescable(ev: Event) bool {
        return switch (ev) {
            .targeted => isCoalescable(ev.untargeted()),
            .mouse => |m| m.motion,
            .window => |w| w == .resized,
            else => false,
        };
    }

    fn sameCoalesceKind(a: Event, b: Event) bool {
        // Never replace another window's latest state under queue pressure.
        if (a == .targeted or b == .targeted) {
            if (a != .targeted or b != .targeted) return false;
            if (a.targeted.window_id != b.targeted.window_id) return false;
            return sameCoalesceKind(a.untargeted(), b.untargeted());
        }
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

    /// Producer-side escalation (gap report §5.4): critical events (close,
    /// key/button release, focus loss, composition commit) that could not
    /// be enqueued — even after evicting coalescable motion — are printed
    /// unconditionally and counted on the queue. Producers call this
    /// instead of discarding the result; the failure is never silent.
    pub fn pushCriticalEscalated(self: *@This(), ev: Event, where: []const u8) void {
        self.pushCritical(ev) catch {
            @import("../core/log.zig").critical("event", "{s} lost a critical event ({s}); input state may be stuck", .{ where, @tagName(ev.untargeted()) });
        };
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

test "composition protocol validates payloads, owns bytes and retains queue policy" {
    const t = std.testing;
    var input = [_]u8{ 'a', 'b' };
    const payload = try CompositionText.init(&input);
    input[0] = 'z';
    try t.expectEqualStrings("ab", payload.slice().?);
    var invalid = try CompositionText.init("é");
    invalid.marked.start = 1;
    try t.expect(invalid.slice() == null);
    const huge: [257]u8 = @splat('a');
    try t.expectError(error.TextTooLong, CompositionText.init(&huge));
    try t.expectError(error.InvalidUtf8, CompositionText.init("\xff"));
    var q = EventQueue{};
    try t.expect(q.push(.{ .composition = .{ .preedit = payload } }));
    try t.expect(q.push(.{ .composition = .{ .commit = payload } }));
    try t.expect(q.push(.{ .composition = .cancel }));
    try t.expect(q.pop().?.composition == .preedit);
    try t.expect(q.pop().?.composition == .commit);
    try t.expect(q.pop().?.composition == .cancel);
    try t.expect(EventQueue.isCritical(.{ .composition = .{ .commit = payload } }));
    try t.expect(EventQueue.isCritical(.{ .composition = .cancel }));
    try t.expect(!EventQueue.isCoalescable(.{ .composition = .{ .preedit = payload } }));
    var rect: geometry.Rect = .{};
    const reporter = CaretReporter{ .context = &rect, .report = struct {
        fn report(ctx: ?*anyopaque, r: geometry.Rect) void {
            const out: *geometry.Rect = @ptrCast(@alignCast(ctx.?));
            out.* = r;
        }
    }.report };
    reporter.update(.{ .x = 12, .y = 20, .w = 1, .h = 18 });
    try t.expectEqual(@as(f32, 12), rect.x);
}

test "rich pointer vocabulary preserves touch target and recognizes gestures" {
    const t = std.testing;
    var recognizer = GestureRecognizer{};
    try t.expect(recognizer.update(.{ .id = 7, .phase = .started, .pos = .{ .x = 10, .y = 10 } }, 0) == .none);
    const pan = recognizer.update(.{ .id = 7, .phase = .moved, .pos = .{ .x = 30, .y = 10 } }, 10);
    try t.expect(pan == .pan);
    try t.expectEqual(@as(f32, 20), pan.pan.delta.x);
    const end = recognizer.update(.{ .id = 7, .phase = .ended, .pos = .{ .x = 30, .y = 10 } }, 20);
    try t.expect(end.pan.phase == .ended);

    var taps = GestureRecognizer{};
    _ = taps.update(.{ .id = 1, .phase = .started, .pos = .{ .x = 2, .y = 2 } }, 100);
    const tap = taps.update(.{ .id = 1, .phase = .ended, .pos = .{ .x = 2, .y = 2 } }, 120);
    try t.expectEqual(@as(u8, 1), tap.tap.count);
    _ = taps.update(.{ .id = 2, .phase = .started, .pos = .{ .x = 3, .y = 2 } }, 200);
    const tap2 = taps.update(.{ .id = 2, .phase = .ended, .pos = .{ .x = 3, .y = 2 } }, 220);
    try t.expectEqual(@as(u8, 2), tap2.tap.count);
}

test "drag drop paths are owned and bounded" {
    var ev = DragDropEvent{ .kind = .entered };
    try ev.addPath("/tmp/a.txt");
    try std.testing.expectEqualStrings("/tmp/a.txt", ev.path(0).?);
    var long_path: [257]u8 = undefined;
    @memset(&long_path, 'x');
    try std.testing.expectError(error.PathTooLong, ev.addPath(&long_path));
}
