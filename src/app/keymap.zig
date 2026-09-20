//! Named actions with contextual, multi-keystroke bindings.
//!
//! Dispatch model ported from GPUI (`keymap.rs`, `keymap/binding.rs`,
//! `key_dispatch.rs`, zlib, Copyright 2023-2026 Zed Industries): bindings
//! pair one keystroke sequence with an action name plus an optional
//! context predicate (`"TodoList && mode == normal"`). The deepest
//! context-frame match wins; two-keystroke sequences (vim-style `"g g"`)
//! pend until completed or a monotonic deadline expires, at which point a
//! remembered single-key match fires.
//!
//! Zig adaptations: no trait objects (actions stay name→listener pairs on
//! `Window`), no allocation (fixed pools in `core/limits.zig`), predicates
//! compile to a fixed node array at bind time. Expiry uses monotonic
//! milliseconds, with explicit timestamps for deterministic headless tests.

const std = @import("std");
const event = @import("../platform/event.zig");
const limits = @import("../core/limits.zig");

/// One chord: physical key plus explicit modifiers.
pub const Keystroke = struct {
    key: event.Key = .unknown,
    modifiers: event.Modifiers = .{},

    pub fn eql(self: @This(), other: @This()) bool {
        return self.key == other.key and std.meta.eql(self.modifiers, other.modifiers);
    }

    pub fn fromKeyEvent(ev: event.KeyEvent) @This() {
        return .{ .key = ev.key, .modifiers = ev.modifiers };
    }
};

/// Parse `"ctrl-shift-x"`, `"cmd-s"`, `"space"`, `"enter"`. Modifiers
/// (`ctrl`/`control`, `shift`, `alt`/`option`, `super`/`cmd`/`win`) prefix
/// the key with `-`; everything is lowercase except single letters, which
/// match either case.
pub fn parseKeystroke(text: []const u8) ?Keystroke {
    var mods = event.Modifiers{};
    var rest = text;
    while (true) {
        if (std.ascii.startsWithIgnoreCase(rest, "ctrl-") or std.ascii.startsWithIgnoreCase(rest, "control-")) {
            mods.ctrl = true;
            rest = rest[std.mem.indexOfScalar(u8, rest, '-').? + 1 ..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "shift-")) {
            mods.shift = true;
            rest = rest[std.mem.indexOfScalar(u8, rest, '-').? + 1 ..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "alt-") or std.ascii.startsWithIgnoreCase(rest, "option-")) {
            mods.alt = true;
            rest = rest[std.mem.indexOfScalar(u8, rest, '-').? + 1 ..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "super-") or std.ascii.startsWithIgnoreCase(rest, "cmd-") or std.ascii.startsWithIgnoreCase(rest, "win-")) {
            mods.super = true;
            rest = rest[std.mem.indexOfScalar(u8, rest, '-').? + 1 ..];
        } else break;
    }
    const key = parseKeyName(rest) orelse return null;
    if (key == .unknown) return null;
    return .{ .key = key, .modifiers = mods };
}

/// Parse one or two whitespace-separated keystrokes (`"g g"`, `"ctrl-k"`).
pub fn parseKeystrokes(text: []const u8, out: *[2]Keystroke) ?usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, text, ' ');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (count >= out.len) return null;
        out[count] = parseKeystroke(part) orelse return null;
        count += 1;
    }
    if (count == 0) return null;
    return count;
}

/// Key names: single letters/digits plus the named set. Mirrors GPUI's
/// keystroke names where our `event.Key` has a member.
pub fn parseKeyName(name: []const u8) ?event.Key {
    if (name.len == 1) {
        const c = std.ascii.toLower(name[0]);
        if (c >= 'a' and c <= 'z') return @fromBackingInt(@intCast(@backingInt(event.Key.a) + (c - 'a')));
        if (c >= '0' and c <= '9') return @fromBackingInt(@intCast(@backingInt(event.Key.n0) + (c - '0')));
        if (c == ' ') return .space;
    }
    const table = .{
        .{ "space", event.Key.space },
        .{ "enter", event.Key.enter },
        .{ "return", event.Key.enter },
        .{ "tab", event.Key.tab },
        .{ "backspace", event.Key.backspace },
        .{ "delete", event.Key.delete },
        .{ "escape", event.Key.escape },
        .{ "esc", event.Key.escape },
        .{ "left", event.Key.left },
        .{ "right", event.Key.right },
        .{ "up", event.Key.up },
        .{ "down", event.Key.down },
        .{ "home", event.Key.home },
        .{ "end", event.Key.end },
        .{ "f1", event.Key.f1 },
        .{ "f2", event.Key.f2 },
        .{ "f3", event.Key.f3 },
        .{ "f4", event.Key.f4 },
        .{ "f5", event.Key.f5 },
        .{ "f6", event.Key.f6 },
        .{ "f7", event.Key.f7 },
        .{ "f8", event.Key.f8 },
        .{ "f9", event.Key.f9 },
        .{ "f10", event.Key.f10 },
        .{ "f11", event.Key.f11 },
        .{ "f12", event.Key.f12 },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return null;
}

// ============================================================================
// Context predicates: `TodoList && mode == normal || !Modal`
// ============================================================================

const NodeKind = enum { present, eq, neq, not, all, any };

const Node = struct {
    kind: NodeKind,
    /// Interned token storage lives in Predicate.buf.
    key: []const u8 = "",
    value: []const u8 = "",
    left: u8 = 0,
    right: u8 = 0,
};

/// Compiled predicate: fixed node array, no allocation. Empty source
/// compiles to "always true" (zero nodes).
pub const Predicate = struct {
    nodes: [limits.MAX_KEYMAP_PREDICATE_NODES]Node = undefined,
    len: u8 = 0,
    root: u8 = 0,

    pub fn isEmpty(self: *const @This()) bool {
        return self.len == 0;
    }

    pub fn compile(source: []const u8) ?Predicate {
        var p = Parser{ .text = source };
        p.skipSpaces();
        // Empty source is the "always true" predicate (zero nodes).
        if (p.pos >= p.text.len) return Predicate{};
        var out = Predicate{};
        const root = p.parseOr(&out) orelse return null;
        p.skipSpaces();
        if (p.pos != p.text.len) return null;
        out.root = root;
        return out;
    }

    /// Deepest 1-based frame depth where this holds, or null. Empty
    /// predicates match every stack at depth `stack.len` (GPUI treats
    /// context-free bindings as the deepest context).
    pub fn depthOf(self: *const @This(), stack: []const ContextFrame) ?usize {
        if (self.isEmpty()) return stack.len;
        var depth: usize = 0;
        var found = false;
        for (stack, 0..) |*frame, i| {
            if (self.evalNode(self.root, frame)) {
                depth = i + 1;
                found = true;
            }
        }
        return if (found) depth else null;
    }

    fn evalNode(self: *const @This(), idx: u8, frame: *const ContextFrame) bool {
        const n = self.nodes[idx];
        return switch (n.kind) {
            .present => frame.has(n.key),
            .eq => frame.eqlValue(n.key, n.value),
            .neq => !frame.eqlValue(n.key, n.value),
            .not => !self.evalNode(n.left, frame),
            .all => self.evalNode(n.left, frame) and self.evalNode(n.right, frame),
            .any => self.evalNode(n.left, frame) or self.evalNode(n.right, frame),
        };
    }
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipSpaces(self: *@This()) void {
        while (self.pos < self.text.len and self.text[self.pos] == ' ') : (self.pos += 1) {}
    }

    fn allocNode(self: *@This(), out: *Predicate, node: Node) ?u8 {
        _ = self;
        if (out.len >= out.nodes.len) return null;
        const idx = out.len;
        out.nodes[idx] = node;
        out.len += 1;
        return idx;
    }

    fn parseOr(self: *@This(), out: *Predicate) ?u8 {
        var left = self.parseAnd(out) orelse return null;
        while (true) {
            self.skipSpaces();
            if (!std.mem.startsWith(u8, self.text[self.pos..], "||")) break;
            self.pos += 2;
            const right = self.parseAnd(out) orelse return null;
            left = self.allocNode(out, .{ .kind = .any, .left = left, .right = right }) orelse return null;
        }
        return left;
    }

    fn parseAnd(self: *@This(), out: *Predicate) ?u8 {
        var left = self.parseUnary(out) orelse return null;
        while (true) {
            self.skipSpaces();
            if (!std.mem.startsWith(u8, self.text[self.pos..], "&&")) break;
            self.pos += 2;
            const right = self.parseUnary(out) orelse return null;
            left = self.allocNode(out, .{ .kind = .all, .left = left, .right = right }) orelse return null;
        }
        return left;
    }

    fn parseUnary(self: *@This(), out: *Predicate) ?u8 {
        self.skipSpaces();
        if (self.pos < self.text.len and self.text[self.pos] == '!') {
            // `!=` belongs to comparisons; only bare `!` negates.
            if (self.pos + 1 < self.text.len and self.text[self.pos + 1] == '=') return null;
            self.pos += 1;
            const inner = self.parseUnary(out) orelse return null;
            return self.allocNode(out, .{ .kind = .not, .left = inner });
        }
        if (self.pos < self.text.len and self.text[self.pos] == '(') {
            self.pos += 1;
            const inner = self.parseOr(out) orelse return null;
            self.skipSpaces();
            if (self.pos >= self.text.len or self.text[self.pos] != ')') return null;
            self.pos += 1;
            return inner;
        }
        return self.parseComparison(out);
    }

    fn parseIdent(self: *@This()) ?[]const u8 {
        self.skipSpaces();
        const start = self.pos;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
                self.pos += 1;
            } else break;
        }
        if (start == self.pos) return null;
        return self.text[start..self.pos];
    }

    fn parseComparison(self: *@This(), out: *Predicate) ?u8 {
        const key = self.parseIdent() orelse return null;
        const save = self.pos;
        self.skipSpaces();
        var neg = false;
        if (std.mem.startsWith(u8, self.text[self.pos..], "==")) {
            self.pos += 2;
        } else if (std.mem.startsWith(u8, self.text[self.pos..], "!=")) {
            neg = true;
            self.pos += 2;
        } else {
            self.pos = save;
            return self.allocNode(out, .{ .kind = .present, .key = key });
        }
        const value = self.parseIdent() orelse return null;
        return self.allocNode(out, .{ .kind = if (neg) .neq else .eq, .key = key, .value = value });
    }
};

/// One context frame: presence tags plus key=value pairs. Slices borrow
/// caller (usually static) strings; nothing is copied.
pub const ContextFrame = struct {
    entries: [limits.MAX_KEYMAP_CONTEXT_ENTRIES]Entry = undefined,
    len: u8 = 0,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8 = "",
    };

    pub fn has(self: *const @This(), key: []const u8) bool {
        for (self.entries[0..self.len]) |e| {
            if (std.mem.eql(u8, e.key, key)) return true;
        }
        return false;
    }

    pub fn eqlValue(self: *const @This(), key: []const u8, value: []const u8) bool {
        for (self.entries[0..self.len]) |e| {
            if (std.mem.eql(u8, e.key, key) and std.mem.eql(u8, e.value, value)) return true;
        }
        return false;
    }

    pub fn put(self: *@This(), key: []const u8, value: []const u8) bool {
        if (self.len >= self.entries.len) return false;
        self.entries[self.len] = .{ .key = key, .value = value };
        self.len += 1;
        return true;
    }
};

// ============================================================================
// Keymap
// ============================================================================

/// Approximately the old 45-frame budget at 60 Hz, independent of traffic.
pub const PENDING_TIMEOUT_MS: i64 = 750;

pub const KeyBinding = struct {
    strokes: [2]Keystroke = undefined,
    stroke_count: u2 = 1,
    action: []const u8,
    predicate: Predicate = .{},
};

/// GPUI dispatch has a distinct capture/bubble path followed by a default
/// action when no listener consumes the key. Keeping these phases explicit
/// lets platform adapters and tests agree on ordering without changing the
/// existing action-name keymap API.
pub const KeyDispatchPhase = enum { capture, target, bubble, default_action };
pub const DefaultKeyAction = enum { tab_forward, tab_backward, activate, dismiss, move_left, move_right, move_up, move_down };
pub const KeyDispatchTrace = struct {
    phases: [8]KeyDispatchPhase = undefined,
    len: u8 = 0,

    pub fn push(self: *@This(), phase: KeyDispatchPhase) void {
        if (self.len < self.phases.len) {
            self.phases[self.len] = phase;
            self.len += 1;
        }
    }
};

pub const KeyDispatchResult = struct {
    action: ?[]const u8 = null,
    default_action: ?DefaultKeyAction = null,
    consumed: bool = false,
    trace: KeyDispatchTrace = .{},
};

/// Resolve a pressed key after listeners have had their capture, target, and
/// bubble opportunities. `listener_consumed` models `stopPropagation` or a
/// handled event; default behavior is never run in that case.
pub fn dispatchWithDefault(self: *Keymap, ev: event.KeyEvent, stack: []const ContextFrame, now_ms: i64, listener_consumed: bool) KeyDispatchResult {
    var result = KeyDispatchResult{};
    result.trace.push(.capture);
    result.trace.push(.target);
    result.trace.push(.bubble);
    if (!ev.pressed) return result;
    result.action = self.dispatchAt(Keystroke.fromKeyEvent(ev), stack, now_ms);
    if (result.action != null or listener_consumed) {
        result.consumed = true;
        return result;
    }
    result.trace.push(.default_action);
    result.default_action = defaultAction(ev);
    result.consumed = result.default_action != null;
    return result;
}

pub fn defaultAction(ev: event.KeyEvent) ?DefaultKeyAction {
    if (!ev.pressed or ev.repeat) return null;
    return switch (ev.key) {
        .tab => if (ev.modifiers.shift) .tab_backward else .tab_forward,
        .enter, .space => .activate,
        .escape => .dismiss,
        .left => .move_left,
        .right => .move_right,
        .up => .move_up,
        .down => .move_down,
        else => null,
    };
}

pub const Keymap = struct {
    bindings: [limits.MAX_KEYMAP_BINDINGS]KeyBinding = undefined,
    count: u8 = 0,
    pending_first: ?Keystroke = null,
    pending_single: ?[]const u8 = null,
    pending_deadline_ms: ?i64 = null,

    /// Bind `"ctrl-s"` / `"g g"` to an action in an optional context.
    /// False when unparsable or the table is full.
    pub fn bind(self: *@This(), keystrokes: []const u8, action: []const u8, context: ?[]const u8) bool {
        if (self.count >= self.bindings.len) return false;
        var strokes: [2]Keystroke = undefined;
        const n = parseKeystrokes(keystrokes, &strokes) orelse return false;
        var predicate = Predicate{};
        if (context) |src| {
            if (src.len > 0) predicate = Predicate.compile(src) orelse return false;
        }
        self.bindings[self.count] = .{
            .strokes = strokes,
            .stroke_count = @intCast(n),
            .action = action,
            .predicate = predicate,
        };
        self.count += 1;
        return true;
    }

    pub fn nextDeadlineMs(self: *const @This()) ?i64 {
        return self.pending_deadline_ms;
    }

    /// Call before dispatching input as well as on deadline wakes, so a late
    /// second key cannot complete an expired sequence. Fires at most once.
    pub fn expire(self: *@This(), now_ms: i64) ?[]const u8 {
        const deadline = self.pending_deadline_ms orelse return null;
        if (now_ms < deadline) return null;
        self.pending_deadline_ms = null;
        self.pending_first = null;
        const single = self.pending_single;
        self.pending_single = null;
        return single;
    }

    /// Dispatch one pressed keystroke against `stack` (outermost first).
    /// Returns the action name, or null when nothing fires (including a
    /// sequence starter, which pends instead).
    pub fn dispatch(self: *@This(), stroke: Keystroke, stack: []const ContextFrame) ?[]const u8 {
        return self.dispatchAt(stroke, stack, @import("window.zig").Window.monotonicMs());
    }

    /// Caller must deliver expire(now_ms) first to preserve a deferred single
    /// action alongside the new keystroke. Window does this before dispatch.
    pub fn dispatchAt(self: *@This(), stroke: Keystroke, stack: []const ContextFrame, now_ms: i64) ?[]const u8 {
        if (self.pending_first) |first| {
            const in_time = if (self.pending_deadline_ms) |due| now_ms < due else false;
            self.pending_first = null;
            self.pending_single = null;
            self.pending_deadline_ms = null;
            // Never complete a stale sequence even if a direct caller forgot
            // to deliver expire() first (that caller loses the single action).
            if (in_time) {
                if (self.bestSequence(first, stroke, stack)) |action| return action;
            }
            // Otherwise the new keystroke starts fresh (GPUI replaces the
            // pending chord rather than queuing it).
        }
        var single: ?[]const u8 = null;
        var single_depth: usize = 0;
        var seq_starter = false;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const bnd = &self.bindings[i];
            if (bnd.stroke_count == 1) {
                if (!bnd.strokes[0].eql(stroke)) continue;
                const depth = bnd.predicate.depthOf(stack) orelse continue;
                if (single == null or depth >= single_depth) {
                    single = bnd.action;
                    single_depth = depth;
                }
            } else if (bnd.strokes[0].eql(stroke)) {
                if (bnd.predicate.depthOf(stack) != null) seq_starter = true;
            }
        }
        if (seq_starter) {
            // Ambiguous: pend the sequence, fire the single on timeout.
            self.pending_first = stroke;
            self.pending_single = single;
            self.pending_deadline_ms = now_ms +| PENDING_TIMEOUT_MS;
            return null;
        }
        return single;
    }

    fn bestSequence(self: *const @This(), first: Keystroke, second: Keystroke, stack: []const ContextFrame) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_depth: usize = 0;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const bnd = &self.bindings[i];
            if (bnd.stroke_count != 2) continue;
            if (!bnd.strokes[0].eql(first) or !bnd.strokes[1].eql(second)) continue;
            const depth = bnd.predicate.depthOf(stack) orelse continue;
            if (best == null or depth >= best_depth) {
                best = bnd.action;
                best_depth = depth;
            }
        }
        return best;
    }
};

test "keystroke parsing covers mods and names" {
    const t = std.testing;
    try t.expectEqual(event.Key.a, parseKeystroke("a").?.key);
    try t.expectEqual(event.Key.n5, parseKeystroke("5").?.key);
    try t.expectEqual(event.Key.space, parseKeystroke("space").?.key);
    try t.expectEqual(event.Key.enter, parseKeystroke("enter").?.key);
    try t.expectEqual(event.Key.f5, parseKeystroke("F5").?.key);
    const save = parseKeystroke("ctrl-shift-s").?;
    try t.expectEqual(event.Key.s, save.key);
    try t.expect(save.modifiers.ctrl and save.modifiers.shift and !save.modifiers.alt);
    const cmd = parseKeystroke("cmd-backspace").?;
    try t.expect(cmd.modifiers.super);
    try t.expect(parseKeystroke("ctrl-") == null);
    try t.expect(parseKeystroke("nope-no-key") == null);
    try t.expect(parseKeystroke("") == null);

    var pair: [2]Keystroke = undefined;
    try t.expectEqual(@as(usize, 2), parseKeystrokes("g g", &pair).?);
    try t.expectEqual(event.Key.g, pair[0].key);
    try t.expectEqual(@as(usize, 1), parseKeystrokes("ctrl-k", &pair).?);
    try t.expect(parseKeystrokes("a b c", &pair) == null);
}

test "predicates parse and evaluate with depth" {
    const t = std.testing;
    var frame = ContextFrame{};
    try t.expect(frame.put("TodoList", ""));
    try t.expect(frame.put("mode", "normal"));
    const stack = [_]ContextFrame{frame};

    const p1 = Predicate.compile("TodoList").?;
    try t.expectEqual(@as(usize, 1), p1.depthOf(&stack).?);
    const p2 = Predicate.compile("Editor").?;
    try t.expect(p2.depthOf(&stack) == null);
    const p3 = Predicate.compile("TodoList && mode == normal").?;
    try t.expectEqual(@as(usize, 1), p3.depthOf(&stack).?);
    const p4 = Predicate.compile("TodoList && mode == insert").?;
    try t.expect(p4.depthOf(&stack) == null);
    const p5 = Predicate.compile("Editor || mode != insert").?;
    try t.expectEqual(@as(usize, 1), p5.depthOf(&stack).?);
    const p6 = Predicate.compile("!Modal && (TodoList || Editor)").?;
    try t.expectEqual(@as(usize, 1), p6.depthOf(&stack).?);
    const p7 = Predicate.compile("Modal").?;
    try t.expect(p7.depthOf(&stack) == null);
    // Empty matches every stack at its full depth.
    const p8 = Predicate.compile("").?;
    try t.expectEqual(@as(usize, 1), p8.depthOf(&stack).?);
    // Deepest frame wins.
    var outer = ContextFrame{};
    try t.expect(outer.put("TodoList", ""));
    var inner = ContextFrame{};
    try t.expect(inner.put("Modal", ""));
    const two = [_]ContextFrame{ outer, inner };
    try t.expectEqual(@as(usize, 2), Predicate.compile("Modal").?.depthOf(&two).?);
    try t.expectEqual(@as(usize, 1), Predicate.compile("TodoList").?.depthOf(&two).?);
    // Failures: unbalanced, trailing operator, bad comparison.
    try t.expect(Predicate.compile("(TodoList") == null);
    try t.expect(Predicate.compile("TodoList &&") == null);
    try t.expect(Predicate.compile("mode ==") == null);
}

test "keymap dispatches deepest context first" {
    const t = std.testing;
    var map = Keymap{};
    try t.expect(map.bind("space", "toggle", null));
    try t.expect(map.bind("space", "toggle-modal", "Modal"));
    var plain = ContextFrame{};
    try t.expect(plain.put("Window", ""));
    const s0 = [_]ContextFrame{plain};
    try t.expectEqualStrings("toggle", map.dispatch(Keystroke{ .key = .space }, &s0).?);
    var modal = ContextFrame{};
    try t.expect(modal.put("Window", ""));
    try t.expect(modal.put("Modal", ""));
    const s1 = [_]ContextFrame{modal};
    try t.expectEqualStrings("toggle-modal", map.dispatch(Keystroke{ .key = .space }, &s1).?);
    // Modifiers are part of the chord.
    try t.expect(map.bind("ctrl-s", "save", null));
    const save = Keystroke{ .key = .s, .modifiers = .{ .ctrl = true } };
    try t.expectEqualStrings("save", map.dispatch(save, &s0).?);
    try t.expect(map.dispatch(Keystroke{ .key = .s }, &s0) == null);
    // Full table rejects.
    var full = Keymap{};
    full.count = limits.MAX_KEYMAP_BINDINGS;
    try t.expect(!full.bind("a", "x", null));
}

test "key sequence deadline uses elapsed milliseconds not dispatch count" {
    const t = std.testing;
    var map = Keymap{};
    try t.expect(map.bind("g g", "sequence", null));
    try t.expect(map.bind("g", "single", null));
    const g = Keystroke{ .key = .g };
    try t.expect(map.dispatchAt(g, &.{}, 1000) == null);
    try t.expectEqual(@as(?i64, 1750), map.nextDeadlineMs());
    for (0..5000) |_| try t.expect(map.expire(1000) == null);
    try t.expectEqualStrings("sequence", map.dispatchAt(g, &.{}, 1749).?);
    try t.expect(map.nextDeadlineMs() == null);
    try t.expect(map.dispatchAt(g, &.{}, 2000) == null);
    try t.expectEqualStrings("single", map.expire(2750).?);
    try t.expect(map.dispatchAt(g, &.{}, 2750) == null);
    // Even a direct caller cannot finish a stale sequence.
    try t.expect(map.dispatchAt(g, &.{}, 10_000) == null);
    try t.expectEqual(@as(?i64, 10_750), map.nextDeadlineMs());
}

test "default keyboard phases run only after unconsumed capture target bubble" {
    var map = Keymap{};
    const tab = dispatchWithDefault(&map, .{ .key = .tab, .pressed = true }, &.{}, 0, false);
    try std.testing.expectEqual(DefaultKeyAction.tab_forward, tab.default_action.?);
    try std.testing.expectEqual(@as(u8, 4), tab.trace.len);
    try std.testing.expectEqual(KeyDispatchPhase.default_action, tab.trace.phases[3]);

    const consumed = dispatchWithDefault(&map, .{ .key = .enter, .pressed = true }, &.{}, 0, true);
    try std.testing.expect(consumed.consumed);
    try std.testing.expect(consumed.default_action == null);
    try std.testing.expectEqual(@as(u8, 3), consumed.trace.len);
}

test "key binding wins before default action" {
    var map = Keymap{};
    try std.testing.expect(map.bind("enter", "submit", null));
    const result = dispatchWithDefault(&map, .{ .key = .enter, .pressed = true }, &.{}, 1, false);
    try std.testing.expectEqualStrings("submit", result.action.?);
    try std.testing.expect(result.default_action == null);
}

test "keymap sequences pend, complete, expire, and reset" {
    const t = std.testing;
    var map = Keymap{};
    try t.expect(map.bind("g g", "go", null));
    try t.expect(map.bind("g", "gee", null));
    var frame = ContextFrame{};
    try t.expect(frame.put("Window", ""));
    const stack = [_]ContextFrame{frame};
    const g = Keystroke{ .key = .g };

    // First g pends (sequence starter shadows the single).
    try t.expect(map.dispatch(g, &stack) == null);
    // Completing keystroke fires the sequence, not the single.
    try t.expectEqualStrings("go", map.dispatch(g, &stack).?);
    // Mismatched second key resets to fresh matching.
    try t.expect(map.dispatch(g, &stack) == null);
    try t.expect(map.dispatch(Keystroke{ .key = .a }, &stack) == null);
    // Pending cleared by the mismatch; plain g pends again.
    try t.expect(map.dispatch(g, &stack) == null);
    // Traffic does not consume time: repeated checks cannot expire early.
    const deadline = map.nextDeadlineMs().?;
    for (0..1000) |_| try t.expect(map.expire(deadline - 1) == null);
    try t.expectEqualStrings("gee", map.expire(deadline).?);
    try t.expect(map.nextDeadlineMs() == null);
    try t.expect(map.expire(deadline + 1) == null);
}
