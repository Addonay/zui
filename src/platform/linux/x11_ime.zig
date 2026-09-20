//! Pure XIM state/conversion helpers.
//!
//! Xlib reports preedit replacement ranges in Unicode-character units while
//! ZUI's composition protocol uses UTF-8 byte offsets. This file deliberately
//! has no Xlib or ZUI-module dependencies so its malformed-input behavior can
//! be tested independently of a display, IM server, or the rest of the app.

const std = @import("std");

pub fn utf8ByteOffsetForChars(bytes: []const u8, char_index: usize) ?usize {
    var offset: usize = 0;
    var chars: usize = 0;
    while (offset < bytes.len and chars < char_index) : (chars += 1) {
        const width = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return null;
        if (offset + width > bytes.len) return null;
        offset += width;
    }
    return if (chars == char_index) offset else null;
}

/// Apply XIM's character-count change range to an existing UTF-8 preedit.
/// A negative first/length is XIM's whole-preedit replacement convention.
pub fn applyPreeditChange(out: *[256]u8, current: []const u8, chg_first: c_int, chg_length: c_int, replacement: []const u8) ?usize {
    if (!std.unicode.utf8ValidateSlice(current) or !std.unicode.utf8ValidateSlice(replacement)) return null;
    const first: usize = if (chg_first < 0) 0 else @intCast(chg_first);
    const removed: usize = if (chg_first < 0 or chg_length < 0) std.math.maxInt(usize) else @intCast(chg_length);
    const start = utf8ByteOffsetForChars(current, first) orelse return null;
    const end = if (removed == std.math.maxInt(usize)) current.len else (utf8ByteOffsetForChars(current, first + removed) orelse return null);
    if (end < start or start > current.len or end > current.len) return null;
    const new_len = start + replacement.len + (current.len - end);
    if (new_len > out.len) return null;
    @memcpy(out[0..start], current[0..start]);
    @memcpy(out[start .. start + replacement.len], replacement);
    @memcpy(out[start + replacement.len .. new_len], current[end..]);
    return new_len;
}

pub fn lookupHasText(status: c_int) bool {
    return status == 2 or status == 4; // XLookupChars or XLookupBoth.
}

test "xim preedit changes translate character ranges to UTF-8 bytes" {
    var out: [256]u8 = undefined;
    const len = applyPreeditChange(&out, "aé中", 1, 1, "xy") orelse return error.InvalidPreedit;
    try std.testing.expectEqualStrings("axy中", out[0..len]);

    const clear_len = applyPreeditChange(&out, out[0..len], -1, -1, "") orelse return error.InvalidPreedit;
    try std.testing.expectEqual(@as(usize, 0), clear_len);
}

test "xim preedit conversion rejects malformed UTF-8 and oversized changes" {
    var out: [256]u8 = undefined;
    try std.testing.expect(applyPreeditChange(&out, &[_]u8{0xff}, 0, 0, "x") == null);
    var too_large: [257]u8 = undefined;
    @memset(&too_large, 'x');
    try std.testing.expect(applyPreeditChange(&out, "", 0, 0, &too_large) == null);
}

test "xim lookup status preserves committed text variants" {
    try std.testing.expect(lookupHasText(2));
    try std.testing.expect(lookupHasText(4));
    try std.testing.expect(!lookupHasText(1));
}
