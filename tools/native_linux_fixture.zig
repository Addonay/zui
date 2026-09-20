//! Platform-independent event fixtures for the native Linux validation probe.
//!
//! These tests validate the event contracts exercised by the checked-in
//! Wayland/X11 adapters. They deliberately do not claim compositor, XIM, or
//! AT-SPI success; live claims come only from native_linux_probe.sh.

const std = @import("std");

const EventKind = enum { preedit, commit, cancel, caret, clipboard, drag_enter, drag_drop, close, reopen };

const Trace = struct {
    events: [16]EventKind = undefined,
    len: usize = 0,
    preedit: [128]u8 = undefined,
    preedit_len: usize = 0,
    committed: [128]u8 = undefined,
    committed_len: usize = 0,
    caret_start: usize = 0,
    caret_end: usize = 0,

    fn push(self: *Trace, kind: EventKind) void {
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = kind;
        self.len += 1;
    }

    fn setPreedit(self: *Trace, text: []const u8, start: usize, end: usize) !void {
        if (!std.unicode.utf8ValidateSlice(text) or text.len > self.preedit.len) return error.InvalidPreedit;
        self.preedit_len = text.len;
        @memcpy(self.preedit[0..text.len], text);
        self.caret_start = clampCharBoundary(text, start);
        self.caret_end = clampCharBoundary(text, end);
        self.push(.preedit);
        self.push(.caret);
    }

    fn commit(self: *Trace, text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text) or text.len > self.committed.len) return error.InvalidCommit;
        self.committed_len = text.len;
        @memcpy(self.committed[0..text.len], text);
        self.preedit_len = 0;
        self.caret_start = 0;
        self.caret_end = 0;
        self.push(.commit);
    }

    fn cancel(self: *Trace) void {
        self.preedit_len = 0;
        self.caret_start = 0;
        self.caret_end = 0;
        self.push(.cancel);
    }

    fn closeReopen(self: *Trace) void {
        self.push(.close);
        self.push(.reopen);
    }
};

/// Return a UTF-8 scalar boundary at or before `offset`.
fn clampCharBoundary(text: []const u8, offset: usize) usize {
    var n = @min(offset, text.len);
    while (n > 0 and n < text.len and (text[n] & 0xc0) == 0x80) n -= 1;
    return n;
}

test "text-input-v3 fixture preserves preedit caret, commit, and cancel order" {
    var trace = Trace{};
    try trace.setPreedit("aé", 2, 99);
    try std.testing.expectEqualStrings("aé", trace.preedit[0..trace.preedit_len]);
    try std.testing.expectEqual(@as(usize, 1), trace.caret_start);
    try std.testing.expectEqual(@as(usize, 3), trace.caret_end);
    try trace.commit("完成");
    try std.testing.expectEqualStrings("完成", trace.committed[0..trace.committed_len]);
    try trace.setPreedit("候", 3, 3);
    trace.cancel();
    try std.testing.expectEqual(@as(usize, 0), trace.preedit_len);
    try std.testing.expectEqualSlices(EventKind, &.{ .preedit, .caret, .commit, .preedit, .caret, .cancel }, trace.events[0..trace.len]);
}

test "native fixture clamps malformed caret offsets without inventing text" {
    var trace = Trace{};
    try trace.setPreedit("中", 1, 2);
    try std.testing.expectEqual(@as(usize, 0), trace.caret_start);
    try std.testing.expectEqual(@as(usize, 0), trace.caret_end);
    try std.testing.expectError(error.InvalidPreedit, trace.setPreedit(&.{0xff}, 0, 0));
}

test "clipboard and drag-drop fixture keeps native event order explicit" {
    var trace = Trace{};
    trace.push(.clipboard);
    trace.push(.drag_enter);
    trace.push(.drag_drop);
    trace.closeReopen();
    try std.testing.expectEqualSlices(EventKind, &.{ .clipboard, .drag_enter, .drag_drop, .close, .reopen }, trace.events[0..trace.len]);
}
