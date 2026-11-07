//! The composition text of an X input method. XIM sends edits, not strings: replace
//! `chg_length` characters at `chg_first` with some text. Positions count characters,
//! and input methods get them wrong often enough that everything here is clamped, as
//! SDL3 does. Kept free of X11 so it can be tested.
const std = @import("std");
const Range = @import("../../platform.zig").Range;
const utf16_len = @import("../../input.zig").utf16_len;

pub const XimPreedit = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Caret position in characters.
    caret: usize = 0,

    pub fn deinit(self: *XimPreedit) void {
        self.text.deinit(self.allocator);
    }

    pub fn clear(self: *XimPreedit) void {
        self.text.clearRetainingCapacity();
        self.caret = 0;
    }

    pub fn is_empty(self: *const XimPreedit) bool {
        return self.text.items.len == 0;
    }

    /// Applies one draw callback. Negative values and out-of-range positions are clamped.
    /// Text that is not valid UTF-8 (a non-UTF-8 locale) is dropped, leaving the rest intact.
    pub fn apply(self: *XimPreedit, chg_first: c_int, chg_length: c_int, insert: ?[]const u8, caret: c_int) void {
        const total = self.char_count();
        const first: usize = @min(@as(usize, @intCast(@max(chg_first, 0))), total);
        const length: usize = @min(@as(usize, @intCast(@max(chg_length, 0))), total - first);
        const start = self.byte_offset(first);
        const end = self.byte_offset(first + length);
        const replacement: []const u8 = if (insert) |t| (if (std.unicode.utf8ValidateSlice(t)) t else "") else "";
        self.text.replaceRange(self.allocator, start, end - start, replacement) catch return;
        self.caret = @min(@as(usize, @intCast(@max(caret, 0))), self.char_count());
    }

    /// The caret as a UTF-16 range inside the text.
    pub fn selected(self: *const XimPreedit) Range {
        const units = utf16_len(self.text.items[0..self.byte_offset(self.caret)]);
        return .{ .start = units, .end = units };
    }

    fn char_count(self: *const XimPreedit) usize {
        return std.unicode.utf8CountCodepoints(self.text.items) catch self.text.items.len;
    }

    fn byte_offset(self: *const XimPreedit, chars: usize) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (i < self.text.items.len and n < chars) : (n += 1) {
            i += std.unicode.utf8ByteSequenceLength(self.text.items[i]) catch 1;
        }
        return @min(i, self.text.items.len);
    }
};

const testing = std.testing;

test "draws build, edit and shrink the text by characters" {
    var p: XimPreedit = .{ .allocator = testing.allocator };
    defer p.deinit();
    p.apply(0, 0, "ni", 2);
    try testing.expectEqualStrings("ni", p.text.items);
    p.apply(2, 0, "hao", 5);
    try testing.expectEqualStrings("nihao", p.text.items);
    // Multi-byte: positions are characters, not bytes.
    p.apply(0, 2, "\u{4f60}", 1);
    try testing.expectEqualStrings("\u{4f60}hao", p.text.items);
    p.apply(1, 1, null, 1);
    try testing.expectEqualStrings("\u{4f60}ao", p.text.items);
    p.apply(0, 3, null, 0);
    try testing.expect(p.is_empty());
}

test "the caret is reported in UTF-16 units" {
    var p: XimPreedit = .{ .allocator = testing.allocator };
    defer p.deinit();
    p.apply(0, 0, "\u{1f600}a", 1);
    try testing.expectEqual(Range{ .start = 2, .end = 2 }, p.selected());
    p.apply(0, 0, null, 2);
    try testing.expectEqual(Range{ .start = 3, .end = 3 }, p.selected());
}

test "bad positions from input methods are clamped" {
    var p: XimPreedit = .{ .allocator = testing.allocator };
    defer p.deinit();
    p.apply(0, 0, "abc", 3);
    p.apply(99, 99, "d", 99);
    try testing.expectEqualStrings("abcd", p.text.items);
    try testing.expectEqual(@as(usize, 4), p.caret);
    p.apply(-5, -5, "x", -1);
    try testing.expectEqualStrings("xabcd", p.text.items);
    try testing.expectEqual(@as(usize, 0), p.caret);
    p.apply(1, 999, null, 0);
    try testing.expectEqualStrings("x", p.text.items);
}

test "invalid text is dropped without disturbing the rest" {
    var p: XimPreedit = .{ .allocator = testing.allocator };
    defer p.deinit();
    p.apply(0, 0, "ok", 2);
    p.apply(2, 0, "\xff\xfe", 2);
    try testing.expectEqualStrings("ok", p.text.items);
}
