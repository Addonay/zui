//! Bounded large-document storage and visible-range text reflow.
//!
//! This is the text-system boundary used by editor-like widgets. It keeps a
//! single owned UTF-8 document under explicit byte/line limits and shapes only
//! the requested visible line window. It deliberately does not own layout,
//! GPU, or platform state.

const std = @import("std");
const engine_mod = @import("text_engine.zig");

pub const Limits = struct {
    max_bytes: usize = 8 * 1024 * 1024,
    max_lines: usize = 200_000,
};

pub const ReflowLine = struct {
    source_line: usize,
    width: f32,
    height: f32,
    glyphs: usize,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    text: []u8,
    revision: u64 = 1,
    reflow_revision: u64 = 0,
    reflowed_lines: usize = 0,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8, limits: Limits) !Document {
        if (initial.len > limits.max_bytes or countLines(initial) > limits.max_lines) return error.DocumentTooLarge;
        return .{ .allocator = allocator, .limits = limits, .text = try allocator.dupe(u8, initial) };
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn lineCount(self: *const Document) usize {
        return countLines(self.text);
    }

    pub fn replace(self: *Document, start: usize, end: usize, replacement: []const u8) !void {
        if (start > end or end > self.text.len) return error.InvalidRange;
        const next_len = self.text.len - (end - start) + replacement.len;
        if (next_len > self.limits.max_bytes) return error.DocumentTooLarge;
        var next = try self.allocator.alloc(u8, next_len);
        errdefer self.allocator.free(next);
        @memcpy(next[0..start], self.text[0..start]);
        @memcpy(next[start .. start + replacement.len], replacement);
        @memcpy(next[start + replacement.len ..], self.text[end..]);
        if (countLines(next) > self.limits.max_lines) return error.DocumentTooLarge;
        self.allocator.free(self.text);
        self.text = next;
        self.revision += 1;
    }

    /// Shape only `[first_line, end_line)`. Reflowing the same revision twice
    /// is a deterministic no-op and makes visible-window virtualization easy
    /// for callers to test.
    pub fn reflow(
        self: *Document,
        engine: *engine_mod.Engine,
        attrs: engine_mod.TextAttrs,
        first_line: usize,
        end_line: usize,
        wrap_width: ?f32,
        alloc: std.mem.Allocator,
    ) ![]ReflowLine {
        const total = self.lineCount();
        const first = @min(first_line, total);
        const last = @min(@max(first, end_line), total);
        var out: std.ArrayList(ReflowLine) = .empty;
        errdefer out.deinit(alloc);
        var line_i: usize = 0;
        var start: usize = 0;
        while (line_i < last) : (line_i += 1) {
            const end = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse self.text.len;
            if (line_i >= first) {
                var layout = try engine.layout(alloc, self.text[start..end], attrs, wrap_width);
                defer layout.deinit();
                try out.append(alloc, .{ .source_line = line_i, .width = layout.width, .height = layout.height, .glyphs = layout.glyphCount() });
            }
            start = if (end < self.text.len) end + 1 else self.text.len;
        }
        self.reflow_revision = self.revision;
        self.reflowed_lines = out.items.len;
        return out.toOwnedSlice(alloc);
    }

    fn countLines(text: []const u8) usize {
        var lines: usize = 1;
        for (text) |byte| {
            if (byte == '\n') lines += 1;
        }
        return lines;
    }
};

test "large document enforces bounds and reflows only visible lines" {
    const t = std.testing;
    var doc = try Document.init(t.allocator, "one\ntwo\nthree\nfour", .{ .max_bytes = 64, .max_lines = 8 });
    defer doc.deinit();
    try t.expectEqual(@as(usize, 4), doc.lineCount());
    try t.expectError(error.DocumentTooLarge, doc.replace(0, 0, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"));
    const engine = engine_mod.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    const rows = try doc.reflow(engine, .{ .family = "Inter", .size = 16, .line_height = 20 }, 1, 3, null, t.allocator);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqual(@as(usize, 1), rows[0].source_line);
    try t.expectEqual(@as(u64, 1), doc.reflow_revision);
}
