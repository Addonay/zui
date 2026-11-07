//! Port of GPUI `text_system/line_wrapper.rs`: wraps and truncates text to a width.
//!
//! Character advances come from a `WidthSource`, so the wrapper runs against the
//! real `TextSystem` (via `TextSystem.line_wrapper`) and against fixed widths in tests.
//! Break opportunities use cozmic's UAX #14 iterator and grapheme starts use UAX #29.

const std = @import("std");
const cozmic = @import("cozmic");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");

const Pixels = geometry.Pixels;
const TextRun = style.TextRun;

/// Determines whether to truncate text from the start or end.
pub const TruncateFrom = enum {
    start,
    end,
    /// Truncate from the middle, preserving the start and end.
    middle,
};

/// Controls how soft-wrapped continuation lines are indented.
pub const IndentAdjustment = union(enum) {
    /// No indent: continuation lines start at column 0.
    no_indent,
    /// Match the original line's leading whitespace.
    same_indent,
    /// Add N extra columns of indent (in space-character widths).
    extra_columns: u32,
};

/// A piece of a line to wrap: text, or an inline element of fixed width.
pub const LineFragment = union(enum) {
    text: []const u8,
    element: struct { width: Pixels, len_utf8: usize },

    pub fn text_fragment(text: []const u8) LineFragment {
        return .{ .text = text };
    }
    pub fn element_fragment(width: Pixels, len_utf8: usize) LineFragment {
        return .{ .element = .{ .width = width, .len_utf8 = len_utf8 } };
    }
};

/// A boundary between two lines of text.
pub const Boundary = struct {
    /// The byte index of the first character of the next line.
    ix: usize,
    /// The indent of the next line, in space columns.
    next_indent: u32,

    pub fn new(ix: usize, next_indent: u32) Boundary {
        return .{ .ix = ix, .next_indent = next_indent };
    }
};

/// Source of character advances (GPUI uses `TextSystem::layout_width`).
pub const WidthSource = struct {
    ctx: *anyopaque,
    width_fn: *const fn (ctx: *anyopaque, font_id: u32, font_size: Pixels, ch: u21) Pixels,

    pub fn width(self: WidthSource, font_id: u32, font_size: Pixels, ch: u21) Pixels {
        return self.width_fn(self.ctx, font_id, font_size, ch);
    }
};

/// Cached character widths for one font and size.
pub const CharWidthCache = struct {
    ascii: [128]?Pixels = @splat(null),
    other: std.AutoHashMapUnmanaged(u21, Pixels) = .empty,

    pub fn deinit(self: *CharWidthCache, allocator: std.mem.Allocator) void {
        self.other.deinit(allocator);
    }
};

/// Wraps lines of text to a width with one font and size.
pub const LineWrapper = struct {
    /// Maximum indent that can be applied to a line.
    pub const MAX_INDENT: u32 = 256;

    allocator: std.mem.Allocator,
    font_id: u32,
    font_size: Pixels,
    widths: WidthSource,
    char_widths: *CharWidthCache,
    text_buffer: std.ArrayList(u8) = .empty,
    break_scratch: std.ArrayList(usize) = .empty,
    grapheme_scratch: std.ArrayList(usize) = .empty,

    pub fn init(allocator: std.mem.Allocator, font_id: u32, font_size: Pixels, widths: WidthSource, char_widths: *CharWidthCache) LineWrapper {
        return .{
            .allocator = allocator,
            .font_id = font_id,
            .font_size = font_size,
            .widths = widths,
            .char_widths = char_widths,
        };
    }

    pub fn deinit(self: *LineWrapper) void {
        self.text_buffer.deinit(self.allocator);
        self.break_scratch.deinit(self.allocator);
        self.grapheme_scratch.deinit(self.allocator);
    }

    /// Advance of one character with this wrapper's font and size (cached).
    pub fn width_for_char(self: *LineWrapper, c: u21) Pixels {
        if (c < 128) {
            if (self.char_widths.ascii[c]) |w| return w;
            const w = self.widths.width(self.font_id, self.font_size, c);
            self.char_widths.ascii[c] = w;
            return w;
        }
        if (self.char_widths.other.get(c)) |w| return w;
        const w = self.widths.width(self.font_id, self.font_size, c);
        self.char_widths.other.put(self.allocator, c, w) catch {};
        return w;
    }

    /// Wraps `fragments` to `wrap_width`, yielding the boundaries after which a line breaks.
    /// The iterator borrows this wrapper's scratch buffers until the next call to `wrap_line`.
    pub fn wrap_line(
        self: *LineWrapper,
        fragments: []const LineFragment,
        wrap_width: Pixels,
        indent_adjustment: IndentAdjustment,
    ) !WrapIter {
        self.text_buffer.clearRetainingCapacity();
        for (fragments) |fragment| switch (fragment) {
            .text => |t| try self.text_buffer.appendSlice(self.allocator, t),
            // Placeholder bytes keep inline elements attached to adjacent words.
            .element => |e| try self.text_buffer.appendNTimes(self.allocator, 'a', e.len_utf8),
        };
        const text = self.text_buffer.items;
        self.break_scratch.clearRetainingCapacity();
        try break_indices_into(self.allocator, text, &self.break_scratch);
        self.grapheme_scratch.clearRetainingCapacity();
        var graphemes = cozmic.unicode.graphemeIndices(text);
        while (graphemes.next()) |start| try self.grapheme_scratch.append(self.allocator, start);
        return .{
            .wrapper = self,
            .fragments = fragments,
            .text = text,
            .breaks = self.break_scratch.items,
            .graphemes = self.grapheme_scratch.items,
            .wrap_width = wrap_width,
            .indent_adjustment = indent_adjustment,
        };
    }

    /// Returns the truncation index in `line`, or null when `line` fits.
    pub fn should_truncate_line(self: *LineWrapper, line: []const u8, truncate_width: Pixels, truncation_affix: []const u8, truncate_from: TruncateFrom) ?usize {
        var width: Pixels = 0;
        const suffix_width = self.affix_width(truncation_affix);
        var truncate_ix: usize = 0;
        switch (truncate_from) {
            .start => {
                var ix = line.len;
                while (ix > 0) {
                    const start = prev_char_start(line, ix);
                    const c = decode_at(line, start);
                    ix = start;
                    if (width + suffix_width < truncate_width) truncate_ix = ix;
                    width += self.width_for_char(c);
                    if (@floor(width) > truncate_width) return truncate_ix;
                }
            },
            .end => {
                var it = Chars.init(line);
                while (it.next()) |ch| {
                    if (width + suffix_width < truncate_width) truncate_ix = ch.ix;
                    width += self.width_for_char(ch.c);
                    if (@floor(width) > truncate_width) return truncate_ix;
                }
            },
            .middle => {},
        }
        return null;
    }

    fn should_truncate_line_middle(self: *LineWrapper, line: []const u8, truncate_width: Pixels, truncation_affix: []const u8) ?[2]usize {
        const suffix_width = self.affix_width(truncation_affix);
        var total_width: Pixels = 0;
        var it = Chars.init(line);
        while (it.next()) |ch| total_width += self.width_for_char(ch.c);
        if (total_width <= truncate_width) return null;

        const content_budget = truncate_width - suffix_width;
        if (content_budget <= 0) return .{ 0, line.len };

        const front_budget = content_budget * (2.0 / 3.0);
        const back_budget = content_budget - front_budget;

        var front_width: Pixels = 0;
        var front_end_ix: usize = 0;
        it = Chars.init(line);
        while (it.next()) |ch| {
            const char_width = self.width_for_char(ch.c);
            if (front_width + char_width > front_budget) break;
            front_width += char_width;
            front_end_ix = ch.ix + ch.len;
        }

        var back_width: Pixels = 0;
        var back_start_ix: usize = line.len;
        var ix = line.len;
        while (ix > 0) {
            const start = prev_char_start(line, ix);
            const char_width = self.width_for_char(decode_at(line, start));
            if (back_width + char_width > back_budget) break;
            back_width += char_width;
            back_start_ix = start;
            ix = start;
        }

        if (front_end_ix >= back_start_ix) return .{ 0, line.len };
        return .{ front_end_ix, back_start_ix };
    }

    /// Truncates `line` to `truncate_width`, appending `truncation_affix`.
    /// Returns the borrowed inputs when no truncation is needed; otherwise allocates
    /// the new text and runs from `allocator`.
    pub fn truncate_line(
        self: *LineWrapper,
        allocator: std.mem.Allocator,
        line: []const u8,
        truncate_width: Pixels,
        truncation_affix: []const u8,
        runs: []const TextRun,
        truncate_from: TruncateFrom,
    ) !Truncated {
        if (truncate_from == .middle) {
            if (self.should_truncate_line_middle(line, truncate_width, truncation_affix)) |range| {
                const front_end_ix, const back_start_ix = range;
                const result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ line[0..front_end_ix], truncation_affix, line[back_start_ix..] });
                const out_runs = try allocator.dupe(TextRun, runs);
                const new_runs = try update_runs_after_middle_truncation(allocator, truncation_affix, out_runs, front_end_ix, back_start_ix);
                return .{ .text = result, .runs = new_runs, .changed = true };
            }
            return .{ .text = line, .runs = runs, .changed = false };
        }

        if (self.should_truncate_line(line, truncate_width, truncation_affix, truncate_from)) |truncate_ix| {
            const result = switch (truncate_from) {
                .start => try std.fmt.allocPrint(allocator, "{s}{s}", .{ truncation_affix, line[ceil_char_boundary(line, truncate_ix + 1)..] }),
                .end => blk: {
                    const kept = trim_end_punct_space(line[0..truncate_ix]);
                    break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ kept, truncation_affix });
                },
                .middle => unreachable,
            };
            const out_runs = try allocator.dupe(TextRun, runs);
            const new_runs = try update_runs_after_truncation(allocator, result, truncation_affix, out_runs, truncate_from);
            return .{ .text = result, .runs = new_runs, .changed = true };
        }
        return .{ .text = line, .runs = runs, .changed = false };
    }

    /// Truncates text to fit `max_lines` wrapped lines at `wrap_width`, appending `truncation_affix`
    /// on the last line when it overflows. For `max_lines <= 1` this is `truncate_line`.
    pub fn truncate_wrapped_line(
        self: *LineWrapper,
        allocator: std.mem.Allocator,
        text: []const u8,
        wrap_width: Pixels,
        max_lines: usize,
        truncation_affix: []const u8,
        runs: []const TextRun,
        truncate_from: TruncateFrom,
    ) !Truncated {
        if (max_lines <= 1 or truncate_from == .start) {
            return self.truncate_line(allocator, text, wrap_width * @as(f32, @floatFromInt(max_lines)), truncation_affix, runs, truncate_from);
        }
        if (truncate_from == .middle) {
            return self.truncate_line(allocator, text, wrap_width, truncation_affix, runs, truncate_from);
        }

        const affix_w = self.affix_width(truncation_affix);
        var width: Pixels = 0;
        var line: usize = 0;
        var first_non_whitespace_ix: ?usize = null;
        var last_candidate_ix: usize = 0;
        var last_candidate_width: Pixels = 0;
        var last_wrap_ix: usize = 0;
        var indent: ?u32 = null;
        var truncate_ix: usize = 0;

        var breaks: std.ArrayList(usize) = .empty;
        defer breaks.deinit(self.allocator);
        try break_indices_into(self.allocator, text, &breaks);
        var break_ix: usize = 0;

        var it = Chars.init(text);
        while (it.next()) |ch| {
            const ix = ch.ix;
            const c = ch.c;
            // Consume boundaries on newlines too, so skipping an empty line does not
            // leave the iterator stuck before subsequent text.
            const is_break = break_ix < breaks.items.len and breaks.items[break_ix] == ix;
            if (is_break) break_ix += 1;
            if (c == '\n') {
                if (line >= max_lines - 1 and !is_blank(text[ix + 1 ..])) {
                    // Newline on the last allowed line with real content below. Truncate here.
                    const truncated = trim_end_punct_space(text[0..truncate_ix]);
                    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ truncated, truncation_affix });
                    const out_runs = try allocator.dupe(TextRun, runs);
                    const new_runs = try update_runs_after_truncation(allocator, result, truncation_affix, out_runs, .end);
                    return .{ .text = result, .runs = new_runs, .changed = true };
                }
                // Newline before the last line: it consumes a line.
                line += 1;
                width = 0;
                first_non_whitespace_ix = null;
                last_candidate_ix = 0;
                last_candidate_width = 0;
                last_wrap_ix = ix + 1;
                indent = null;
                truncate_ix = ix + 1;
                continue;
            }

            const char_width = self.width_for_char(c);

            if (is_break and first_non_whitespace_ix != null) {
                last_candidate_ix = ix;
                last_candidate_width = width;
            }

            if (c != ' ' and first_non_whitespace_ix == null) first_non_whitespace_ix = ix;

            width += char_width;

            if (line < max_lines - 1) {
                // Before the last line: replicate wrap_line's boundary logic.
                if (width > wrap_width and ix > last_wrap_ix) {
                    if (indent == null) {
                        if (first_non_whitespace_ix) |fnw| {
                            indent = @intCast(@min(@as(usize, LineWrapper.MAX_INDENT), fnw -| last_wrap_ix));
                        }
                    }
                    if (last_candidate_ix > last_wrap_ix) {
                        last_wrap_ix = last_candidate_ix;
                        width -= last_candidate_width;
                        last_candidate_ix = 0;
                    } else {
                        last_wrap_ix = ix;
                        width = char_width;
                    }
                    if (indent) |ind| width += self.width_for_char(' ') * @as(f32, @floatFromInt(ind));
                    line += 1;
                    truncate_ix = last_wrap_ix;
                }
            } else {
                // On the last line: track the furthest point where the affix still fits,
                // and stop as soon as the line overflows.
                if (width + affix_w <= wrap_width) truncate_ix = ix + it.last_len;
                if (width > wrap_width) {
                    const truncated = trim_end_punct_space(text[0..truncate_ix]);
                    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ truncated, truncation_affix });
                    const out_runs = try allocator.dupe(TextRun, runs);
                    const new_runs = try update_runs_after_truncation(allocator, result, truncation_affix, out_runs, .end);
                    return .{ .text = result, .runs = new_runs, .changed = true };
                }
            }
        }

        // Text fits within max_lines without truncation.
        return .{ .text = text, .runs = runs, .changed = false };
    }

    fn affix_width(self: *LineWrapper, affix: []const u8) Pixels {
        var total: Pixels = 0;
        var it = Chars.init(affix);
        while (it.next()) |ch| total += self.width_for_char(ch.c);
        return total;
    }
};

/// Result of a truncation. Borrows `text`/`runs` when `changed` is false, otherwise
/// both are allocated by the caller's allocator.
pub const Truncated = struct {
    text: []const u8,
    runs: []const TextRun,
    changed: bool,
};

/// Iterator returned by `LineWrapper.wrap_line`.
pub const WrapIter = struct {
    wrapper: *LineWrapper,
    fragments: []const LineFragment,
    frag_ix: usize = 0,
    /// The current text fragment and the byte offset into it.
    frag_pos: usize = 0,
    text: []const u8,
    breaks: []const usize,
    graphemes: []const usize,
    wrap_width: Pixels,
    indent_adjustment: IndentAdjustment,

    index: usize = 0,
    grapheme_ix: usize = 0,
    break_ix: usize = 0,
    width: Pixels = 0,
    first_non_whitespace_ix: ?usize = null,
    base_indent: ?u32 = null,
    last_candidate_ix: usize = 0,
    last_candidate_width: Pixels = 0,
    last_wrap_ix: usize = 0,
    grapheme_index: usize = 0,
    width_before_grapheme: Pixels = 0,

    const Candidate = struct {
        c: u21,
        len_utf8_: usize,
        element_width: ?Pixels = null,

        /// Bytes this candidate takes up in the text (GPUI `WrapBoundaryCandidate::len_utf8`).
        pub fn len_utf8(self: Candidate) usize {
            return self.len_utf8_;
        }
    };

    fn next_candidate(self: *WrapIter) ?Candidate {
        while (self.frag_ix < self.fragments.len) {
            switch (self.fragments[self.frag_ix]) {
                .text => |t| {
                    if (self.frag_pos < t.len) {
                        const n = utf8_len_at(t, self.frag_pos);
                        const c = decode_at(t, self.frag_pos);
                        self.frag_pos += n;
                        return .{ .c = c, .len_utf8_ = n };
                    }
                    self.frag_ix += 1;
                    self.frag_pos = 0;
                },
                .element => |e| {
                    self.frag_ix += 1;
                    return .{ .c = 0, .len_utf8_ = e.len_utf8, .element_width = e.width };
                },
            }
        }
        return null;
    }

    /// The next wrap boundary, or null when the remaining text fits.
    pub fn next(self: *WrapIter) ?Boundary {
        const w = self.wrapper;
        while (self.next_candidate()) |cand| {
            const ix = self.index;
            self.index += cand.len_utf8();

            while (self.grapheme_ix < self.graphemes.len and self.graphemes[self.grapheme_ix] < ix) self.grapheme_ix += 1;
            const is_grapheme_boundary = self.grapheme_ix < self.graphemes.len and self.graphemes[self.grapheme_ix] == ix;
            if (is_grapheme_boundary) {
                self.grapheme_ix += 1;
                self.grapheme_index = ix;
                self.width_before_grapheme = self.width;
            }
            const is_break = self.break_ix < self.breaks.len and self.breaks[self.break_ix] == ix;
            if (is_break) self.break_ix += 1;
            if (is_break and is_grapheme_boundary and self.first_non_whitespace_ix != null) {
                self.last_candidate_ix = ix;
                self.last_candidate_width = self.width;
            }

            var item_width: Pixels = undefined;
            if (cand.element_width) |ew| {
                if (self.first_non_whitespace_ix == null) self.first_non_whitespace_ix = ix;
                item_width = ew;
            } else {
                if (cand.c == '\n') continue;
                if (cand.c != ' ' and self.first_non_whitespace_ix == null) self.first_non_whitespace_ix = ix;
                item_width = w.width_for_char(cand.c);
            }

            self.width += item_width;
            if (self.width > self.wrap_width and self.grapheme_index > self.last_wrap_ix) {
                const wrap_at_candidate = self.last_candidate_ix > self.last_wrap_ix and self.width - self.last_candidate_width <= self.wrap_width;
                const carried_width = if (wrap_at_candidate) self.width - self.last_candidate_width else self.width - self.width_before_grapheme;

                // Base indentation comes from the first non-whitespace character and is kept
                // for all later wrap rows.
                if (self.base_indent == null) {
                    if (self.first_non_whitespace_ix) |fnw| {
                        self.base_indent = @intCast(@min(@as(usize, LineWrapper.MAX_INDENT), fnw -| self.last_wrap_ix));
                    }
                }

                const next_indent: u32 = switch (self.indent_adjustment) {
                    .no_indent => 0,
                    .same_indent => self.base_indent orelse 0,
                    .extra_columns => |extra| blk: {
                        const base = self.base_indent orelse break :blk 0;
                        const candidate = base +| extra;
                        const candidate_indent_width = w.width_for_char(' ') * @as(f32, @floatFromInt(candidate));
                        // Reserve headroom for the carried suffix (and two columns for a full-width character).
                        const min_headroom = @max(carried_width, w.width_for_char(' ') * 2.0);
                        if (candidate_indent_width + min_headroom > self.wrap_width) break :blk 0;
                        break :blk @min(LineWrapper.MAX_INDENT, candidate);
                    },
                };

                if (wrap_at_candidate) {
                    self.last_wrap_ix = self.last_candidate_ix;
                    self.width -= self.last_candidate_width;
                    self.width_before_grapheme -= self.last_candidate_width;
                } else {
                    // An oversized grapheme stays intact, even if it exceeds the line width.
                    self.last_wrap_ix = self.grapheme_index;
                    self.width -= self.width_before_grapheme;
                    self.width_before_grapheme = 0;
                }
                self.last_candidate_ix = 0;

                const indent_width = w.width_for_char(' ') * @as(f32, @floatFromInt(next_indent));
                self.width += indent_width;
                self.width_before_grapheme += indent_width;
                return Boundary.new(self.last_wrap_ix, next_indent);
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Helpers.

/// Appends the UAX #14 break offsets of `text` to `out` (includes `text.len`).
pub fn break_indices_into(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(usize)) !void {
    var it = cozmic.unicode.lineBreakOpportunities(text);
    while (it.next()) |b| try out.append(allocator, b.offset);
}

/// Decodes the code point starting at byte `i` of `s` (invalid bytes decode to U+FFFD).
fn decode_at(s: []const u8, i: usize) u21 {
    const n = utf8_len_at(s, i);
    if (i + n > s.len) return 0xFFFD;
    return std.unicode.utf8Decode(s[i .. i + n]) catch 0xFFFD;
}

/// Length in bytes of the sequence starting at `i` (1 for invalid lead bytes).
fn utf8_len_at(s: []const u8, i: usize) usize {
    return std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
}

/// Start byte of the character that ends right before byte `end`.
fn prev_char_start(s: []const u8, end: usize) usize {
    var i = end - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Smallest char boundary `>= i` (like `str::ceil_char_boundary`).
fn ceil_char_boundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i;
    while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
    return j;
}

/// Iterates `(byte index, code point, byte length)` of a UTF-8 string.
const Chars = struct {
    s: []const u8,
    pos: usize = 0,
    last_len: usize = 0,

    const Item = struct { ix: usize, c: u21, len: usize };

    fn init(s: []const u8) Chars {
        return .{ .s = s };
    }

    fn next(self: *Chars) ?Item {
        if (self.pos >= self.s.len) return null;
        const ix = self.pos;
        const n = utf8_len_at(self.s, ix);
        const len = @min(n, self.s.len - ix);
        const c = decode_at(self.s, ix);
        self.pos += len;
        self.last_len = len;
        return .{ .ix = ix, .c = c, .len = len };
    }
};

fn is_blank(s: []const u8) bool {
    for (s) |b| {
        if (!std.ascii.isWhitespace(b)) return false;
    }
    return true;
}

/// Trims trailing whitespace and ASCII punctuation (`trim_end_matches`).
fn trim_end_punct_space(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const b = s[end - 1];
        if (std.ascii.isWhitespace(b) or std.ascii.isPunctuation(b)) {
            end -= 1;
        } else break;
    }
    return s[0..end];
}

/// Rewrites run lengths after end/start truncation so they cover `result` exactly.
fn update_runs_after_truncation(
    allocator: std.mem.Allocator,
    result: []const u8,
    ellipsis: []const u8,
    runs: []TextRun,
    truncate_from: TruncateFrom,
) ![]const TextRun {
    _ = allocator;
    var truncate_at = result.len - ellipsis.len;
    switch (truncate_from) {
        .start => {
            var keep_from: usize = 0;
            var i = runs.len;
            while (i > 0) {
                i -= 1;
                const run = &runs[i];
                if (run.len <= truncate_at) {
                    truncate_at -= run.len;
                } else {
                    run.len = truncate_at + ellipsis.len;
                    keep_from = i;
                    break;
                }
            } else keep_from = 0;
            return runs[keep_from..];
        },
        .end => {
            for (runs, 0..) |*run, run_index| {
                if (run.len <= truncate_at) {
                    truncate_at -= run.len;
                } else {
                    run.len = truncate_at + ellipsis.len;
                    return runs[0 .. run_index + 1];
                }
            }
            return runs;
        },
        .middle => unreachable,
    }
}

/// Builds the runs for a middle truncation: front runs, the ellipsis, then back runs.
fn update_runs_after_middle_truncation(
    allocator: std.mem.Allocator,
    ellipsis: []const u8,
    original: []TextRun,
    front_end_ix: usize,
    back_start_ix: usize,
) ![]const TextRun {
    var result: std.ArrayList(TextRun) = .empty;
    errdefer result.deinit(allocator);

    // Front segment [0, front_end_ix) + ellipsis.
    var front_remaining = front_end_ix;
    var front_done = false;
    for (original) |run| {
        if (front_done) break;
        if (run.len <= front_remaining) {
            try result.append(allocator, run);
            front_remaining -= run.len;
        } else {
            var partial = run;
            partial.len = front_remaining + ellipsis.len;
            try result.append(allocator, partial);
            front_done = true;
        }
    }
    if (!front_done) {
        // front_end_ix landed on a run boundary: extend the last front run,
        // or, when the front is empty, start with the first run's style.
        if (result.items.len > 0) {
            result.items[result.items.len - 1].len += ellipsis.len;
        } else if (original.len > 0) {
            var affix_run = original[0];
            affix_run.len = ellipsis.len;
            try result.append(allocator, affix_run);
        }
    }

    // Back segment [back_start_ix, total): skip runs entirely in the removed middle.
    var byte_pos: usize = 0;
    for (original) |run| {
        const run_end = byte_pos + run.len;
        if (run_end > back_start_ix) {
            if (byte_pos < back_start_ix) {
                var partial = run;
                partial.len = run_end - back_start_ix;
                try result.append(allocator, partial);
            } else {
                try result.append(allocator, run);
            }
        }
        byte_pos = run_end;
    }
    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests. Widths are a fixed 10px per character, which matches the monospace font
// the GPUI tests wrap with.

const testing = std.testing;
const TEST_COLOR: @import("../color.zig").Hsla = .{ .h = 0, .s = 0, .l = 0, .a = 1 };

/// Every character advances `width` pixels (the context is a `*const Pixels`).
fn fake_width(ctx: *anyopaque, _: u32, _: Pixels, _: u21) Pixels {
    const w: *const Pixels = @ptrCast(@alignCast(ctx));
    return w.*;
}

fn test_wrapper(cw: *CharWidthCache, char_width: *const Pixels) LineWrapper {
    return LineWrapper.init(testing.allocator, 0, 16.0, .{ .ctx = @constCast(char_width), .width_fn = fake_width }, cw);
}

/// Runs of the given byte lengths, all with the same style.
fn runs_of(buf: []TextRun, lens: []const usize) []TextRun {
    for (lens, 0..) |len, i| buf[i] = .{ .len = len, .font = .{}, .color = TEST_COLOR };
    return buf[0..lens.len];
}

fn collect(it: *WrapIter, out: []Boundary) []Boundary {
    var n: usize = 0;
    while (it.next()) |b| : (n += 1) out[n] = b;
    return out[0..n];
}

test "wrap_line breaks at word boundaries" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var buf: [16]Boundary = undefined;

    var it = try w.wrap_line(&.{LineFragment.text_fragment("aa bbb cccc ddddd eeee")}, 72, .same_indent);
    try testing.expectEqualSlices(Boundary, &.{ Boundary.new(7, 0), Boundary.new(12, 0), Boundary.new(18, 0) }, collect(&it, &buf));

    it = try w.wrap_line(&.{LineFragment.text_fragment("aaa aaaaaaaaaaaaaaaaaa")}, 72, .same_indent);
    try testing.expectEqualSlices(Boundary, &.{ Boundary.new(4, 0), Boundary.new(11, 0), Boundary.new(18, 0) }, collect(&it, &buf));

    it = try w.wrap_line(&.{LineFragment.text_fragment("     aaaaaaa")}, 72, .same_indent);
    try testing.expectEqualSlices(Boundary, &.{ Boundary.new(7, 5), Boundary.new(9, 5), Boundary.new(11, 5) }, collect(&it, &buf));

    it = try w.wrap_line(&.{LineFragment.text_fragment("                            ")}, 72, .same_indent);
    try testing.expectEqualSlices(Boundary, &.{ Boundary.new(7, 0), Boundary.new(14, 0), Boundary.new(21, 0) }, collect(&it, &buf));
}

test "wrap_line with no indent drops continuation indentation" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var buf: [16]Boundary = undefined;
    // 12 columns at 10px in a 72px line: one break after 7 columns, and the rest fits.
    var it = try w.wrap_line(&.{LineFragment.text_fragment("     aaaaaaa")}, 72, .no_indent);
    try testing.expectEqualSlices(Boundary, &.{Boundary.new(7, 0)}, collect(&it, &buf));
}

test "wrap_line keeps elements attached to adjacent words" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var buf: [16]Boundary = undefined;
    // A 20px element between "ab" and "cd" is one unbreakable unit with them.
    const frags = [_]LineFragment{
        LineFragment.text_fragment("ab "),
        LineFragment.element_fragment(20, 1),
        LineFragment.text_fragment("cd ef"),
    };
    var it = try w.wrap_line(&frags, 40, .same_indent);
    const got = collect(&it, &buf);
    try testing.expect(got.len >= 1);
    try testing.expectEqual(@as(usize, 3), got[0].ix);
}

test "wrap_line never splits a grapheme cluster" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var buf: [16]Boundary = undefined;
    // "e" + combining acute accent is one grapheme; every wrap must land on a grapheme start.
    const text = "xxxxxxe\u{301}yyyyy";
    var starts: [32]usize = undefined;
    var n: usize = 0;
    var gi = cozmic.unicode.graphemeIndices(text);
    while (gi.next()) |s| : (n += 1) starts[n] = s;
    var it = try w.wrap_line(&.{LineFragment.text_fragment(text)}, 60, .no_indent);
    for (collect(&it, &buf)) |b| {
        var found = b.ix == text.len;
        for (starts[0..n]) |s| found = found or s == b.ix;
        try testing.expect(found);
    }
}

test "should_truncate_line end and start" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    // "…" is one 10px character. End: "abc" overflows at 'd' (40px > 35px), keeping "ab" (index 2).
    try testing.expectEqual(@as(?usize, 2), w.should_truncate_line("abcdef", 35, "…", .end));
    try testing.expectEqual(@as(?usize, null), w.should_truncate_line("abc", 60, "…", .end));
    // Start: scanning back from 'f', overflow at 'c' keeps the tail from index 3.
    try testing.expectEqual(@as(?usize, 3), w.should_truncate_line("abcdef", 35, "…", .start));
}

test "truncate_line end replaces the tail with the affix" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runs = [_]TextRun{.{ .len = 6, .font = .{}, .color = TEST_COLOR }};
    // "..." is 30px; with a 45px budget only 'a' fits before the affix.
    const t = try w.truncate_line(a, "abcdef", 45, "...", &runs, .end);
    try testing.expect(t.changed);
    try testing.expectEqualStrings("a...", t.text);
    try testing.expectEqual(@as(usize, 4), t.runs[0].len);
}

test "truncate_line leaves short text borrowed" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var runs = [_]TextRun{.{ .len = 3, .font = .{}, .color = TEST_COLOR }};
    const t = try w.truncate_line(testing.allocator, "abc", 100, "...", &runs, .end);
    try testing.expect(!t.changed);
    try testing.expectEqualStrings("abc", t.text);
}

test "truncate_line start keeps the tail" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var runs = [_]TextRun{.{ .len = 6, .font = .{}, .color = TEST_COLOR }};
    const t = try w.truncate_line(arena.allocator(), "abcdef", 35, "..", &runs, .start);
    // ".." is 20px: scanning back from 'f' keeps "f" (overflow at 'd'), so the result is "..f".
    try testing.expectEqualStrings("..f", t.text);
}

test "truncate_line middle keeps both ends" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var runs = [_]TextRun{.{ .len = 10, .font = .{}, .color = TEST_COLOR }};
    const t = try w.truncate_line(arena.allocator(), "abcdefghij", 70, "…", &runs, .middle);
    try testing.expect(t.changed);
    try testing.expect(std.mem.startsWith(u8, t.text, "ab"));
    try testing.expect(std.mem.endsWith(u8, t.text, "ij"));
    try testing.expect(std.mem.indexOf(u8, t.text, "…") != null);
    var total: usize = 0;
    for (t.runs) |r| total += r.len;
    try testing.expectEqual(t.text.len, total);
}

test "truncate_wrapped_line stops at max_lines and appends the affix" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "aa bb cc dd ee ff gg hh ii jj";
    var runs = [_]TextRun{.{ .len = text.len, .font = .{}, .color = TEST_COLOR }};
    const t = try w.truncate_wrapped_line(arena.allocator(), text, 60, 2, "...", &runs, .end);
    try testing.expect(t.changed);
    try testing.expect(std.mem.endsWith(u8, t.text, "..."));
}

test "truncate_wrapped_line without overflow returns the input" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 10;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var runs = [_]TextRun{.{ .len = 5, .font = .{}, .color = TEST_COLOR }};
    const t = try w.truncate_wrapped_line(testing.allocator, "ab cd", 200, 3, "...", &runs, .end);
    try testing.expect(!t.changed);
}

test "truncate_line end across several runs keeps each run's share of the text" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    // ZedMono at 16px advances 9.6px per character, as in GPUI's calibration.
    const cell: Pixels = 9.6;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { lens: []const usize, expected: []const u8, result_lens: []const usize, width: Pixels }{
        .{ .lens = &.{12}, .expected = "abcd…", .result_lens = &.{7}, .width = 50 },
        .{ .lens = &.{ 4, 4, 4 }, .expected = "abcdef…", .result_lens = &.{ 4, 5 }, .width = 70 },
        .{ .lens = &.{ 4, 4, 4 }, .expected = "abcdefgh…", .result_lens = &.{ 4, 4, 3 }, .width = 90 },
    };
    for (cases) |c| {
        var buf: [8]TextRun = undefined;
        const runs = runs_of(&buf, c.lens);
        const t = try w.truncate_line(arena.allocator(), "abcdefghijkl", c.width, "…", runs, .end);
        try testing.expectEqualStrings(c.expected, t.text);
        try testing.expectEqual(c.result_lens.len, t.runs.len);
        for (t.runs, c.result_lens) |run, want| try testing.expectEqual(want, run.len);
    }
}

test "update_runs_after_truncation trims runs to the result length" {
    const cases = [_]struct { result: []const u8, lens: []const usize, expected: []const usize }{
        .{ .result = "abcd…", .lens = &.{12}, .expected = &.{7} },
        .{ .result = "abcdef…", .lens = &.{ 4, 4, 4 }, .expected = &.{ 4, 5 } },
        .{ .result = "abcdefgh…", .lens = &.{ 4, 4, 4 }, .expected = &.{ 4, 4, 3 } },
    };
    for (cases) |c| {
        var buf: [8]TextRun = undefined;
        const runs = runs_of(&buf, c.lens);
        // The end case returns a prefix of `runs`, so nothing is allocated.
        const out = try update_runs_after_truncation(testing.allocator, c.result, "…", runs, .end);
        try testing.expectEqual(c.expected.len, out.len);
        for (out, c.expected) |run, want| try testing.expectEqual(want, run.len);
    }
}

test "wrap_line with extra columns keeps a fitting indent and drops an overflowing one" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 9.6;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var buf: [16]Boundary = undefined;
    // 6 base columns plus 8 extra overflow a 10-column line, so the indent falls back to 0.
    var it = try w.wrap_line(&.{LineFragment.text_fragment("      ab cd ef gh")}, cell * 10, .{ .extra_columns = 8 });
    try testing.expectEqualSlices(Boundary, &.{Boundary.new(9, 0)}, collect(&it, &buf));
}

test "multiline truncation fits within the requested wrapped lines" {
    var cw: CharWidthCache = .{};
    defer cw.deinit(testing.allocator);
    const cell: Pixels = 9.6;
    var w = test_wrapper(&cw, &cell);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "aa bbbbbb cccccc dddddd eeee ffff";
    var buf: [4]TextRun = undefined;
    const runs = runs_of(&buf, &.{text.len});
    const t = try w.truncate_wrapped_line(arena.allocator(), text, 72, 2, "\u{2026}", runs, .end);
    try testing.expect(t.changed);
    var wrap_buf: [16]Boundary = undefined;
    var it = try w.wrap_line(&.{LineFragment.text_fragment(t.text)}, 72, .same_indent);
    try testing.expect(collect(&it, &wrap_buf).len < 2);
}
