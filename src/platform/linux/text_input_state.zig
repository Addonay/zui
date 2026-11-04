//! The double-buffered state of zwp_text_input_v3, without any Wayland in it, so its
//! rules can be tested against event streams. Events fill pending state; `done` turns
//! them into what the application must do, in the order the protocol requires.
//!
//! Protocol rules this encodes:
//! - Pending state does not survive a `done`.
//! - A `done` with a stale serial is applied like any other. The client only refrains
//!   from sending new state until a serial matches. (foot drops such events, which loses
//!   committed text; GPUI and the spec do not.)
//! - Preedit cursor offsets are UTF-8 bytes on the wire and -1 when hidden. Offsets are
//!   untrusted: anything out of range or inside a character is treated as hidden.
const std = @import("std");
const input_mod = @import("../../input.zig");
const Range = @import("../../platform.zig").Range;

pub const Done = struct {
    /// Remove the current composition before anything else happens.
    clear_preedit: bool,
    /// Text to insert. It replaces the composition, if `clear_preedit` did not.
    commit: ?[]u8,
    /// New composition, and the caret inside it in UTF-16 code units.
    preedit: ?[]u8,
    preedit_selected: ?Range,
    /// True when the compositor has seen all our commits, so state may be sent.
    serial_matches: bool,
};

pub const TextInputState = struct {
    allocator: std.mem.Allocator,
    /// Commit requests issued on the object. `done` carries this count back.
    commits: u32 = 0,
    pending_preedit: ?[]u8 = null,
    pending_begin: i32 = -1,
    pending_end: i32 = -1,
    pending_commit: ?[]u8 = null,
    /// A composition is on screen.
    composing: bool = false,

    pub fn deinit(self: *TextInputState) void {
        self.clear_pending();
    }

    pub fn clear_pending(self: *TextInputState) void {
        if (self.pending_preedit) |t| self.allocator.free(t);
        if (self.pending_commit) |t| self.allocator.free(t);
        self.pending_preedit = null;
        self.pending_commit = null;
        self.pending_begin = -1;
        self.pending_end = -1;
    }

    /// `enable` resets everything but the commit count, which counts the object's lifetime.
    pub fn reset(self: *TextInputState) void {
        self.clear_pending();
        self.composing = false;
    }

    pub fn on_preedit(self: *TextInputState, text: ?[]const u8, begin: i32, end: i32) void {
        if (self.pending_preedit) |t| self.allocator.free(t);
        self.pending_preedit = null;
        // An empty preedit means none.
        if (text) |t| {
            if (t.len > 0) self.pending_preedit = self.allocator.dupe(u8, t) catch null;
        }
        self.pending_begin = begin;
        self.pending_end = end;
    }

    pub fn on_commit(self: *TextInputState, text: ?[]const u8) void {
        if (self.pending_commit) |t| self.allocator.free(t);
        self.pending_commit = null;
        if (text) |t| {
            if (t.len > 0) self.pending_commit = self.allocator.dupe(u8, t) catch null;
        }
    }

    /// Consumes the pending state. The caller frees the result with `free_done`.
    pub fn on_done(self: *TextInputState, serial: u32) Done {
        const preedit = self.pending_preedit;
        const commit = self.pending_commit;
        const selected = if (preedit) |p| preedit_range(p, self.pending_begin, self.pending_end) else null;
        const result: Done = .{
            // A commit replaces the composition by itself; clearing first would only flicker.
            .clear_preedit = self.composing and commit == null and preedit == null,
            .commit = commit,
            .preedit = preedit,
            .preedit_selected = selected,
            .serial_matches = serial == self.commits,
        };
        self.pending_preedit = null;
        self.pending_commit = null;
        self.pending_begin = -1;
        self.pending_end = -1;
        self.composing = preedit != null;
        return result;
    }

    pub fn free_done(self: *TextInputState, done: Done) void {
        if (done.commit) |t| self.allocator.free(t);
        if (done.preedit) |t| self.allocator.free(t);
    }
};

/// Converts wire offsets to a UTF-16 range, or null when hidden or invalid.
fn preedit_range(text: []const u8, begin: i32, end: i32) ?Range {
    if (begin < 0 or end < 0 or begin > end) return null;
    const b: usize = @intCast(begin);
    const e: usize = @intCast(end);
    if (e > text.len) return null;
    if (!on_char_boundary(text, b) or !on_char_boundary(text, e)) return null;
    return .{ .start = input_mod.utf16_len(text[0..b]), .end = input_mod.utf16_len(text[0..e]) };
}

fn on_char_boundary(text: []const u8, index: usize) bool {
    if (index == text.len) return true;
    return text[index] & 0xc0 != 0x80;
}

const testing = std.testing;

test "preedit, then commit, then nothing" {
    var s: TextInputState = .{ .allocator = testing.allocator };
    defer s.deinit();

    s.on_preedit("ni", 2, 2);
    var d = s.on_done(0);
    try testing.expectEqualStrings("ni", d.preedit.?);
    try testing.expectEqual(Range{ .start = 2, .end = 2 }, d.preedit_selected.?);
    try testing.expect(!d.clear_preedit and d.commit == null and d.serial_matches);
    s.free_done(d);
    try testing.expect(s.composing);

    // The IM commits: the commit replaces the composition, so no separate clear.
    s.on_commit("\u{4f60}");
    d = s.on_done(0);
    try testing.expectEqualStrings("\u{4f60}", d.commit.?);
    try testing.expect(d.preedit == null and !d.clear_preedit);
    s.free_done(d);
    try testing.expect(!s.composing);

    // A done with no changes does nothing.
    d = s.on_done(0);
    try testing.expect(d.preedit == null and d.commit == null and !d.clear_preedit);
    s.free_done(d);
}

test "cancelling a composition clears it" {
    var s: TextInputState = .{ .allocator = testing.allocator };
    defer s.deinit();
    s.on_preedit("ni", -1, -1);
    s.free_done(s.on_done(0));
    // The IM sends a done with nothing pending, or an empty preedit: both mean gone.
    s.on_preedit("", 0, 0);
    const d = s.on_done(0);
    try testing.expect(d.clear_preedit and d.preedit == null);
    s.free_done(d);
    try testing.expect(!s.composing);
}

test "a commit and a new preedit in one done" {
    var s: TextInputState = .{ .allocator = testing.allocator };
    defer s.deinit();
    s.on_preedit("a", 1, 1);
    s.free_done(s.on_done(0));
    s.on_commit("\u{e9}");
    s.on_preedit("b", 1, 1);
    const d = s.on_done(0);
    try testing.expectEqualStrings("\u{e9}", d.commit.?);
    try testing.expectEqualStrings("b", d.preedit.?);
    s.free_done(d);
    try testing.expect(s.composing);
}

test "pending state is replaced, not accumulated, and does not leak between dones" {
    var s: TextInputState = .{ .allocator = testing.allocator };
    defer s.deinit();
    s.on_preedit("first", 0, 0);
    s.on_preedit("second", 6, 6);
    s.on_commit("one");
    s.on_commit("two");
    var d = s.on_done(0);
    try testing.expectEqualStrings("second", d.preedit.?);
    try testing.expectEqualStrings("two", d.commit.?);
    s.free_done(d);
    d = s.on_done(0);
    try testing.expect(d.commit == null and d.preedit == null);
    try testing.expect(d.clear_preedit); // "second" was on screen and nothing replaced it.
    s.free_done(d);
}

test "a stale serial still applies text but must not send state" {
    var s: TextInputState = .{ .allocator = testing.allocator };
    defer s.deinit();
    s.commits = 3;
    s.on_commit("kept");
    const d = s.on_done(2);
    try testing.expectEqualStrings("kept", d.commit.?);
    try testing.expect(!d.serial_matches);
    s.free_done(d);
}

test "preedit cursor offsets are bytes on the wire and UTF-16 for the app" {
    // U+4F60 is 3 bytes and 1 unit; U+1F600 is 4 bytes and 2 units.
    const text = "\u{4f60}\u{1f600}x";
    try testing.expectEqual(Range{ .start = 1, .end = 3 }, preedit_range(text, 3, 7).?);
    try testing.expectEqual(Range{ .start = 4, .end = 4 }, preedit_range(text, 8, 8).?);
    // Hidden.
    try testing.expect(preedit_range(text, -1, -1) == null);
    try testing.expect(preedit_range(text, 0, -1) == null);
    // Hostile or buggy input methods: inside a character, reversed, past the end.
    try testing.expect(preedit_range(text, 1, 3) == null);
    try testing.expect(preedit_range(text, 7, 3) == null);
    try testing.expect(preedit_range(text, 0, 99) == null);
}

test "reset drops pending text and composition" {
    var s: TextInputState = .{ .allocator = testing.allocator, .commits = 5 };
    defer s.deinit();
    s.on_preedit("x", 1, 1);
    s.free_done(s.on_done(5));
    s.on_commit("lost");
    s.reset();
    try testing.expect(!s.composing and s.pending_commit == null);
    try testing.expectEqual(@as(u32, 5), s.commits);
}
