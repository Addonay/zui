//! Renderer-independent, bounded editing. Offsets are UTF-8 bytes; newline
//! storage and vertical movement are opt-in for multiline fields.
const std = @import("std");
const cozmic = @import("cozmic");
const unicode = @import("cozmic").unicode;
pub const Model = struct {
    pub const capacity = @import("../core/limits.zig").MAX_TEXT_LEN;
    pub const history_limit = 16;
    pub const Selection = struct {
        anchor: usize = 0,
        active: usize = 0,
        pub fn start(s: Selection) usize {
            return @min(s.anchor, s.active);
        }
        pub fn end(s: Selection) usize {
            return @max(s.anchor, s.active);
        }
    };
    const Snapshot = struct { buffer: [capacity]u8, len: usize, selection: Selection };
    buffer: [capacity]u8 = @splat(0),
    len: usize = 0,
    selection: Selection = .{},
    input_limit: usize = capacity,
    undo_stack: [history_limit]Snapshot = undefined,
    redo_stack: [history_limit]Snapshot = undefined,
    undo_len: usize = 0,
    redo_len: usize = 0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Newline-aware editing is opt-in so existing single-line fields retain
    /// their historical control filtering.
    allow_newlines: bool = false,
    preferred_column: ?usize = null,

    pub fn text(self: *const Model) []const u8 {
        return self.buffer[0..self.len];
    }
    pub fn selected(self: *const Model) []const u8 {
        return self.buffer[self.selection.start()..self.selection.end()];
    }
    fn snapshot(self: *const Model) Snapshot {
        return .{ .buffer = self.buffer, .len = self.len, .selection = self.selection };
    }
    fn restore(self: *Model, s: Snapshot) void {
        self.buffer = s.buffer;
        self.len = s.len;
        self.selection = s.selection;
    }
    fn push(stack: *[history_limit]Snapshot, len: *usize, s: Snapshot) void {
        if (len.* == history_limit) {
            std.mem.copyForwards(Snapshot, stack[0 .. history_limit - 1], stack[1..]);
            len.* -= 1;
        }
        stack[len.*] = s;
        len.* += 1;
    }
    fn remember(self: *Model) void {
        push(&self.undo_stack, &self.undo_len, self.snapshot());
        self.redo_len = 0;
    }
    pub fn undo(self: *Model) void {
        if (self.undo_len == 0) return;
        push(&self.redo_stack, &self.redo_len, self.snapshot());
        self.undo_len -= 1;
        self.restore(self.undo_stack[self.undo_len]);
    }
    pub fn redo(self: *Model) void {
        if (self.redo_len == 0) return;
        push(&self.undo_stack, &self.undo_len, self.snapshot());
        self.redo_len -= 1;
        self.restore(self.redo_stack[self.redo_len]);
    }
    pub fn snap(self: *const Model, index: usize) usize {
        const i = @min(index, self.len);
        return if (unicode.isGraphemeBoundary(self.text(), i)) i else unicode.prevGraphemeStart(self.text(), i);
    }
    pub fn place(self: *Model, index: usize, extend: bool) void {
        self.selection.active = self.snap(index);
        if (!extend) self.selection.anchor = self.selection.active;
        self.preferred_column = null;
    }
    pub fn selectAll(self: *Model) void {
        self.selection = .{ .active = self.len };
    }
    pub const Motion = enum { previous, next, word_previous, word_next, line_start, line_end, up, down };
    pub fn move(self: *Model, motion: Motion, extend: bool) void {
        const i = self.selection.active;
        const target = switch (motion) {
            .previous => if (!extend and self.selected().len > 0) self.selection.start() else unicode.prevGraphemeStart(self.text(), i),
            .next => if (!extend and self.selected().len > 0) self.selection.end() else unicode.nextGraphemeEnd(self.text(), i),
            .word_previous, .word_next => self.wordBoundary(i, motion == .word_next),
            .line_start => self.lineStart(i),
            .line_end => self.lineEnd(i),
            .up, .down => return self.moveVertical(motion == .down, extend),
        };
        self.place(target, extend);
    }
    fn lineStart(self: *const Model, index: usize) usize {
        var i = @min(index, self.len);
        while (i > 0 and self.buffer[i - 1] != '\n') : (i -= 1) {}
        return i;
    }
    fn lineEnd(self: *const Model, index: usize) usize {
        var i = @min(index, self.len);
        while (i < self.len and self.buffer[i] != '\n') : (i += 1) {}
        return i;
    }
    fn lineNumber(self: *const Model, index: usize) usize {
        var line: usize = 0;
        for (self.buffer[0..@min(index, self.len)]) |byte| {
            if (byte == '\n') line += 1;
        }
        return line;
    }
    fn lineStartForNumber(self: *const Model, wanted: usize) usize {
        if (wanted == 0) return 0;
        var line: usize = 0;
        for (self.buffer[0..self.len], 0..) |byte, i| {
            if (byte == '\n') {
                line += 1;
                if (line == wanted) return i + 1;
            }
        }
        return self.len;
    }
    fn graphemeColumn(self: *const Model, index: usize) usize {
        const start = self.lineStart(index);
        var count: usize = 0;
        var it = unicode.graphemeIndices(self.text()[start..@min(index, self.lineEnd(index))]);
        while (it.next()) |_| count += 1;
        return count;
    }
    fn indexAtColumn(self: *const Model, start: usize, column: usize) usize {
        const end = self.lineEnd(start);
        var it = unicode.graphemeIndices(self.text()[start..end]);
        var count: usize = 0;
        var offset: usize = start;
        while (count < column) : (count += 1) {
            _ = it.next() orelse return end;
            offset = start + it.pos;
        }
        return offset;
    }
    fn moveVertical(self: *Model, down: bool, extend: bool) void {
        if (!self.allow_newlines) return;
        const current_line = self.lineNumber(self.selection.active);
        const target_line = if (down) current_line + 1 else current_line -| 1;
        if (!down and current_line == 0) return;
        if (down and target_line == current_line) return;
        const column = self.preferred_column orelse self.graphemeColumn(self.selection.active);
        self.preferred_column = column;
        self.place(self.indexAtColumn(self.lineStartForNumber(target_line), column), extend);
        self.preferred_column = column;
    }
    pub fn cursor(self: *const Model, index: usize) cozmic.Cursor {
        const clamped = self.snap(index);
        return .{ .line = @intCast(self.lineNumber(clamped)), .index = clamped - self.lineStart(clamped) };
    }
    pub fn indexOfCursor(self: *const Model, position: cozmic.Cursor) usize {
        return self.snap(self.lineStartForNumber(position.line) + position.index);
    }
    pub fn lineCount(self: *const Model) usize {
        var count: usize = 1;
        for (self.text()) |byte| {
            if (byte == '\n') count += 1;
        }
        return count;
    }
    fn wordBoundary(self: *const Model, i: usize, forward: bool) usize {
        var it = unicode.wordBounds(self.text());
        var previous: usize = 0;
        while (it.next()) |r| {
            if (!unicode.isWordRange(self.text(), r)) continue;
            if (forward and r.end > i) return r.end;
            if (!forward and r.start >= i) break;
            previous = r.start;
        }
        return if (forward) self.len else previous;
    }
    /// A paste is one undo transaction. Reject invalid UTF-8; truncate only at
    /// whole graphemes. Controls are filtered before segmentation.
    pub fn insert(self: *Model, bytes: []const u8) void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return;
        var clean: [capacity]u8 = undefined;
        var n: usize = 0;
        var it = unicode.graphemeIndices(bytes);
        const available = @min(self.input_limit, capacity) -| (self.len - self.selected().len);
        while (it.next()) |start| {
            const cluster = bytes[start..it.pos];
            const is_newline = cluster.len == 1 and cluster[0] == '\n';
            if ((cluster[0] < 0x20 and (!self.allow_newlines or !is_newline)) or cluster[0] == 0x7f) continue;
            if (cluster.len > available - n) break;
            @memcpy(clean[n..][0..cluster.len], cluster);
            n += cluster.len;
        }
        if (n == 0) return;
        self.remember();
        self.replaceSelection(clean[0..n]);
    }
    fn replaceSelection(self: *Model, bytes: []const u8) void {
        const start = self.selection.start();
        const end = self.selection.end();
        const tail_len = self.len - end;
        if (start + bytes.len > end) std.mem.copyBackwards(u8, self.buffer[start + bytes.len ..][0..tail_len], self.buffer[end..self.len]) else std.mem.copyForwards(u8, self.buffer[start + bytes.len ..][0..tail_len], self.buffer[end..self.len]);
        @memcpy(self.buffer[start..][0..bytes.len], bytes);
        self.len = start + bytes.len + tail_len;
        // Joining inserted text to a suffix can merge clusters; never leave
        // the caret inside that new cluster.
        const end_insert = start + bytes.len;
        self.place(if (unicode.isGraphemeBoundary(self.text(), end_insert)) end_insert else unicode.nextGraphemeEnd(self.text(), end_insert), false);
    }
    pub fn delete(self: *Model, backward: bool) void {
        const before = self.snapshot();
        if (self.selected().len == 0) {
            self.selection.anchor = if (backward) unicode.prevGraphemeStart(self.text(), self.selection.active) else unicode.nextGraphemeEnd(self.text(), self.selection.active);
        }
        if (self.selected().len == 0) return;
        push(&self.undo_stack, &self.undo_len, before);
        self.redo_len = 0;
        self.replaceSelection("");
    }
    pub fn ensureCaretVisible(self: *Model, x: f32, width: f32) void {
        if (x < self.scroll_x) self.scroll_x = x;
        if (x > self.scroll_x + @max(0, width - 1)) self.scroll_x = x - @max(0, width - 1);
        self.scroll_x = @max(0, self.scroll_x);
    }
    pub fn ensureCaretVisibleVertical(self: *Model, y: f32, height: f32) void {
        if (y < self.scroll_y) self.scroll_y = y;
        if (y > self.scroll_y + @max(0, height - 1)) self.scroll_y = y - @max(0, height - 1);
        self.scroll_y = @max(0, self.scroll_y);
    }
};

test "grapheme editing removes combining marks and emoji sequences atomically" {
    var m = Model{};
    m.insert("a\u{301}👩🏽‍💻🇳🇿z");
    m.move(.previous, false);
    m.delete(true);
    try std.testing.expectEqualStrings("a\u{301}👩🏽‍💻z", m.text());
    m.delete(true);
    m.delete(true);
    try std.testing.expectEqualStrings("z", m.text());
}

test "selection replacement undo redo bounded history and long paste" {
    var m = Model{};
    m.insert("Latin שלום");
    m.move(.word_previous, true);
    try std.testing.expectEqualStrings("שלום", m.selected());
    m.insert("world");
    try std.testing.expectEqualStrings("Latin world", m.text());
    m.undo();
    try std.testing.expectEqualStrings("שלום", m.selected());
    m.redo();
    try std.testing.expectEqualStrings("Latin world", m.text());
    m.selectAll();
    m.delete(false);
    const long: [2048]u8 = @splat('a');
    m.insert(&long);
    try std.testing.expectEqual(Model.capacity, m.len);
    m.undo();
    try std.testing.expectEqualStrings("", m.text());
    for (0..30) |_| m.insert("x");
    try std.testing.expectEqual(Model.history_limit, m.undo_len);
    for (0..30) |_| m.undo();
    try std.testing.expectEqual(@as(usize, 14), m.len);
    m.insert("y");
    try std.testing.expectEqual(@as(usize, 0), m.redo_len);
    m.ensureCaretVisible(500, 100);
    try std.testing.expectEqual(@as(f32, 401), m.scroll_x);
    m.ensureCaretVisible(0, 100);
    try std.testing.expectEqual(@as(f32, 0), m.scroll_x);
}

test "multiline mode preserves newlines and moves by grapheme column" {
    var m = Model{ .allow_newlines = true };
    m.insert("one\ntwo\nthree");
    try std.testing.expectEqual(@as(usize, 3), m.lineCount());
    m.place(m.len, false);
    m.move(.line_start, false);
    try std.testing.expectEqual(@as(usize, 8), m.selection.active);
    m.place(m.len, false);
    m.move(.up, false);
    try std.testing.expectEqual(@as(usize, 7), m.selection.active);
    m.move(.up, false);
    try std.testing.expectEqual(@as(usize, 3), m.selection.active);
    m.place(3, false);
    m.move(.down, false);
    try std.testing.expectEqual(@as(usize, 7), m.selection.active);
    try std.testing.expectEqual(@as(usize, 1), m.cursor(m.selection.active).line);
}
