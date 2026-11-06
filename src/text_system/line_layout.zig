//! Port of GPUI `text_system/line_layout.rs`: shaped lines, wrapped lines and the
//! two-frame `LineLayoutCache`.
//!
//! The cache keeps the layouts used in the current frame and the previous one. A
//! layout that is requested again moves into the current frame at no cost; anything
//! unused for a full frame is freed by `finish_frame`. A layout returned by the cache
//! therefore stays valid for the frame it was requested in and the next one.

const std = @import("std");
const geometry = @import("../geometry.zig");
const text_system = @import("../text_system.zig");
const line_wrapper = @import("line_wrapper.zig");
const line_mod = @import("line.zig");
const style = @import("../style.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");

const Allocator = std.mem.Allocator;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const TextAlign = style.TextAlign;
const DecorationRun = line_mod.DecorationRun;
const Window = window_mod.Window;
const App = app_mod.App;
const FontId = text_system.FontId;
const GlyphId = text_system.GlyphId;

/// A run of text with a single font (GPUI `FontRun`).
pub const FontRun = struct {
    /// Length of the run in UTF-8 bytes.
    len: usize,
    font_id: FontId,
};

/// A single glyph, ready to paint.
pub const ShapedGlyph = struct {
    /// The glyph id within the font of its run.
    id: GlyphId,
    /// The position of this glyph in its containing line.
    position: Point(Pixels),
    /// The byte index of this glyph's cluster in the original text.
    index: usize,
    /// Whether this glyph is a color (emoji) glyph.
    is_emoji: bool,
};

/// Glyphs that share one font.
pub const ShapedRun = struct {
    font_id: FontId,
    glyphs: []ShapedGlyph,
};

/// Result of a position lookup: `ok` for an exact match, `err` for the nearest valid index
/// (GPUI `Result<usize, usize>`).
pub const IndexResult = union(enum) {
    ok: usize,
    err: usize,

    pub fn index(self: IndexResult) usize {
        return switch (self) {
            .ok, .err => |i| i,
        };
    }
};

/// A laid out and styled line of text (GPUI `LineLayout`).
pub const LineLayout = struct {
    /// The font size for this line.
    font_size: Pixels = 0,
    /// The width of the line.
    width: Pixels = 0,
    /// The ascent of the line.
    ascent: Pixels = 0,
    /// The descent of the line.
    descent: Pixels = 0,
    /// The shaped runs that make up this line.
    runs: []ShapedRun = &.{},
    /// The length of the line in UTF-8 bytes.
    len: usize = 0,
    /// The text that was shaped. Owned by the cache entry that holds this layout.
    text: []const u8 = &.{},

    /// The byte index of the character at `x`, or null when `x` is past the line.
    pub fn index_for_x(self: *const LineLayout, x: Pixels) ?usize {
        if (x >= self.width) return null;
        var r = self.runs.len;
        while (r > 0) {
            r -= 1;
            const glyphs = self.runs[r].glyphs;
            var g = glyphs.len;
            while (g > 0) {
                g -= 1;
                if (glyphs[g].position.x <= x) return glyphs[g].index;
            }
        }
        return 0;
    }

    /// The character boundary closest to `x` (for keyboard navigation).
    pub fn closest_index_for_x(self: *const LineLayout, x: Pixels) usize {
        var prev_index: usize = 0;
        var prev_x: Pixels = 0;
        for (self.runs) |run| {
            for (run.glyphs) |glyph| {
                if (glyph.position.x >= x) {
                    if (glyph.position.x - x < x - prev_x) return glyph.index;
                    return prev_index;
                }
                prev_index = glyph.index;
                prev_x = glyph.position.x;
            }
        }
        if (self.len == 1) return if (x > self.width / 2.0) 1 else 0;
        return self.len;
    }

    /// The x position of the character at byte `index`.
    pub fn x_for_index(self: *const LineLayout, index: usize) Pixels {
        for (self.runs) |run| {
            for (run.glyphs) |glyph| {
                if (glyph.index >= index) return glyph.position.x;
            }
        }
        return self.width;
    }

    /// The font of the glyph at byte `index`.
    pub fn font_id_for_index(self: *const LineLayout, index: usize) ?FontId {
        for (self.runs) |run| {
            for (run.glyphs) |glyph| {
                if (glyph.index >= index) return run.font_id;
            }
        }
        return null;
    }

    /// Frees the runs and text of a layout created with `allocator`.
    pub fn deinit(self: *LineLayout, allocator: Allocator) void {
        for (self.runs) |run| allocator.free(run.glyphs);
        allocator.free(self.runs);
        allocator.free(self.text);
        self.* = .{};
    }

    /// Splits the layout at byte `byte_index` into `(prefix, suffix)` (GPUI `LineLayout::split_at`).
    ///
    /// - `prefix` keeps the glyphs for bytes `[0, byte_index)` at their positions. Its width is the
    ///   x-advance up to the split point.
    /// - `suffix` keeps the glyphs for bytes `[byte_index, len)`, shifted left so its first glyph is at
    ///   x=0, with byte indices rebased to 0.
    ///
    /// Both halves copy `font_size`, `ascent` and `descent`. Their runs are allocated with `allocator`
    /// and hold no text: `text` is empty.
    pub fn split_at(self: *const LineLayout, allocator: Allocator, byte_index: usize) !struct { LineLayout, LineLayout } {
        const x_offset = self.x_for_index(byte_index);

        var left_runs: std.ArrayList(ShapedRun) = .empty;
        errdefer {
            for (left_runs.items) |run| allocator.free(run.glyphs);
            left_runs.deinit(allocator);
        }
        var right_runs: std.ArrayList(ShapedRun) = .empty;
        errdefer {
            for (right_runs.items) |run| allocator.free(run.glyphs);
            right_runs.deinit(allocator);
        }

        for (self.runs) |run| {
            // The same search as GPUI's `partition_point`, which the suffix's order depends on for glyphs
            // that shaping put out of byte order.
            const split_pos = partition_point_glyphs(run.glyphs, byte_index);

            if (split_pos > 0) {
                const glyphs = try allocator.dupe(ShapedGlyph, run.glyphs[0..split_pos]);
                errdefer allocator.free(glyphs);
                try left_runs.append(allocator, .{ .font_id = run.font_id, .glyphs = glyphs });
            }
            if (split_pos < run.glyphs.len) {
                const glyphs = try allocator.alloc(ShapedGlyph, run.glyphs.len - split_pos);
                errdefer allocator.free(glyphs);
                for (run.glyphs[split_pos..], glyphs) |g, *out| {
                    out.* = .{
                        .id = g.id,
                        .position = .{ .x = g.position.x - x_offset, .y = g.position.y },
                        .index = g.index - byte_index,
                        .is_emoji = g.is_emoji,
                    };
                }
                try right_runs.append(allocator, .{ .font_id = run.font_id, .glyphs = glyphs });
            }
        }

        const left_owned = try left_runs.toOwnedSlice(allocator);
        errdefer {
            for (left_owned) |run| allocator.free(run.glyphs);
            allocator.free(left_owned);
        }
        const right_owned = try right_runs.toOwnedSlice(allocator);
        const left: LineLayout = .{
            .font_size = self.font_size,
            .width = x_offset,
            .ascent = self.ascent,
            .descent = self.descent,
            .runs = left_owned,
            .len = byte_index,
        };
        const right: LineLayout = .{
            .font_size = self.font_size,
            .width = self.width - x_offset,
            .ascent = self.ascent,
            .descent = self.descent,
            .runs = right_owned,
            .len = self.len - byte_index,
        };
        return .{ left, right };
    }

    /// Paints this layout at `origin` (GPUI `LineLayout::paint`). `decoration_runs` color the glyphs and
    /// draw the underlines and strikethroughs.
    pub fn paint(
        self: *const LineLayout,
        origin: Point(Pixels),
        line_height: Pixels,
        text_align: TextAlign,
        align_width: ?Pixels,
        decoration_runs: []const DecorationRun,
        window: *Window,
        cx: *App,
    ) !void {
        return line_mod.paint_layout(self, origin, line_height, text_align, align_width, decoration_runs, window, cx);
    }

    /// Paints the background colors of this layout at `origin` (GPUI `LineLayout::paint_background`).
    pub fn paint_background(
        self: *const LineLayout,
        origin: Point(Pixels),
        line_height: Pixels,
        text_align: TextAlign,
        align_width: ?Pixels,
        decoration_runs: []const DecorationRun,
        window: *Window,
        cx: *App,
    ) !void {
        return line_mod.paint_layout_background(self, origin, line_height, text_align, align_width, decoration_runs, window, cx);
    }
};

/// A glyph index pair marking where a wrapped line breaks (GPUI `WrapBoundary`).
pub const WrapBoundary = struct {
    /// The index in `runs` of the run just before the wrap.
    run_ix: usize,
    /// The index in that run's glyphs of the glyph just before the wrap.
    glyph_ix: usize,

    /// Lexicographic order on (run, glyph), as in GPUI's derived `Ord`.
    pub fn lt(a: WrapBoundary, b: WrapBoundary) bool {
        if (a.run_ix != b.run_ix) return a.run_ix < b.run_ix;
        return a.glyph_ix < b.glyph_ix;
    }
    pub fn eql(a: WrapBoundary, b: WrapBoundary) bool {
        return a.run_ix == b.run_ix and a.glyph_ix == b.glyph_ix;
    }
};

/// A line of text wrapped to a width (GPUI `WrappedLineLayout`).
pub const WrappedLineLayout = struct {
    /// The line layout before wrapping. Owned by the line cache.
    unwrapped_layout: *const LineLayout = undefined,
    /// Where the line was wrapped. Owned by the cache entry.
    boundaries: []WrapBoundary = &.{},
    /// The width the line was wrapped to, if any.
    wrap_width: ?Pixels = null,
    /// The text of this line. Owned by the cache entry.
    text: []const u8 = &.{},

    pub fn deinit(self: *WrappedLineLayout, allocator: Allocator) void {
        allocator.free(self.boundaries);
        allocator.free(self.text);
        self.* = .{};
    }

    /// The boundaries at which the line was wrapped (GPUI `wrap_boundaries`). The field is `boundaries`
    /// because Zig does not allow a field and a method of the same name.
    pub fn wrap_boundaries(self: *const WrappedLineLayout) []const WrapBoundary {
        return self.boundaries;
    }

    /// The length of the underlying text in UTF-8 bytes.
    pub fn len(self: *const WrappedLineLayout) usize {
        return self.unwrapped_layout.len;
    }

    /// The width of this line, whether or not it was wrapped.
    pub fn width(self: *const WrappedLineLayout) Pixels {
        return @min(self.wrap_width orelse std.math.floatMax(Pixels), self.unwrapped_layout.width);
    }

    /// The size of the wrapped text for `line_height`.
    pub fn size(self: *const WrappedLineLayout, line_height: Pixels) Size(Pixels) {
        return .{
            .width = self.width(),
            .height = line_height * @as(f32, @floatFromInt(self.boundaries.len + 1)),
        };
    }

    pub fn ascent(self: *const WrappedLineLayout) Pixels {
        return self.unwrapped_layout.ascent;
    }

    pub fn descent(self: *const WrappedLineLayout) Pixels {
        return self.unwrapped_layout.descent;
    }

    pub fn font_size(self: *const WrappedLineLayout) Pixels {
        return self.unwrapped_layout.font_size;
    }

    /// The runs of this line, before wrapping.
    pub fn runs(self: *const WrappedLineLayout) []const ShapedRun {
        return self.unwrapped_layout.runs;
    }

    /// The byte index for `position`, where `position` is relative to the line origin.
    pub fn index_for_position(self: *const WrappedLineLayout, position: Point(Pixels), line_height: Pixels) IndexResult {
        return self.index_for_position_impl(position, line_height, false);
    }

    /// The character boundary closest to `position`, where `position` is relative to the line origin.
    pub fn closest_index_for_position(self: *const WrappedLineLayout, position: Point(Pixels), line_height: Pixels) IndexResult {
        return self.index_for_position_impl(position, line_height, true);
    }

    fn index_for_position_impl(self: *const WrappedLineLayout, position: Point(Pixels), line_height: Pixels, closest: bool) IndexResult {
        const q = position.y / line_height;
        const wrapped_line_ix: usize = if (q > 0) @intFromFloat(@trunc(q)) else 0;

        var wrapped_line_start_index: usize = 0;
        var wrapped_line_start_x: Pixels = 0;
        if (wrapped_line_ix > 0) {
            if (wrapped_line_ix - 1 >= self.boundaries.len) return .{ .err = 0 };
            const b = self.boundaries[wrapped_line_ix - 1];
            const glyph = self.unwrapped_layout.runs[b.run_ix].glyphs[b.glyph_ix];
            wrapped_line_start_index = glyph.index;
            wrapped_line_start_x = glyph.position.x;
        }

        var wrapped_line_end_index: usize = undefined;
        var wrapped_line_end_x: Pixels = undefined;
        if (wrapped_line_ix < self.boundaries.len) {
            const b = self.boundaries[wrapped_line_ix];
            const glyph = self.unwrapped_layout.runs[b.run_ix].glyphs[b.glyph_ix];
            wrapped_line_end_index = glyph.index;
            wrapped_line_end_x = glyph.position.x;
        } else {
            wrapped_line_end_index = self.unwrapped_layout.len;
            wrapped_line_end_x = self.unwrapped_layout.width;
        }

        const x = position.x + wrapped_line_start_x;
        if (x < wrapped_line_start_x) return .{ .err = wrapped_line_start_index };
        if (x >= wrapped_line_end_x) return .{ .err = wrapped_line_end_index };
        if (closest) return .{ .ok = self.unwrapped_layout.closest_index_for_x(x) };
        // The shaper can place a trailing zero-width boundary glyph slightly past the
        // line's width, so the row can extend past where `index_for_x` has glyphs.
        if (self.unwrapped_layout.index_for_x(x)) |ix| return .{ .ok = ix };
        return .{ .err = wrapped_line_end_index };
    }

    /// The position of the byte `index` relative to the line origin, for `line_height`.
    pub fn position_for_index(self: *const WrappedLineLayout, index: usize, line_height: Pixels) ?Point(Pixels) {
        var line_start_ix: usize = 0;
        var ix: usize = 0;
        while (ix <= self.boundaries.len) : (ix += 1) {
            const line_end_ix: usize = if (ix < self.boundaries.len) blk: {
                const b = self.boundaries[ix];
                break :blk self.unwrapped_layout.runs[b.run_ix].glyphs[b.glyph_ix].index;
            } else self.len();
            const line_y = @as(f32, @floatFromInt(ix)) * line_height;
            if (index < line_start_ix) {
                break;
            } else if (index > line_end_ix) {
                line_start_ix = line_end_ix;
                continue;
            } else {
                const line_start_x = self.unwrapped_layout.x_for_index(line_start_ix);
                const x = self.unwrapped_layout.x_for_index(index) - line_start_x;
                return .{ .x = x, .y = line_y };
            }
        }
        return null;
    }
};

/// Scratch space reused by wrap-boundary computation.
pub const WrapScratch = struct {
    glyph_indices: std.AutoHashMapUnmanaged(usize, void) = .empty,
    break_indices: std.ArrayList(usize) = .empty,
    items: std.ArrayList(Item) = .empty,

    const Item = struct { boundary: WrapBoundary, index: usize, x: Pixels };

    pub fn deinit(self: *WrapScratch, allocator: Allocator) void {
        self.glyph_indices.deinit(allocator);
        self.break_indices.deinit(allocator);
        self.items.deinit(allocator);
    }
};

/// Finds where `layout` (shaped from `text`) must wrap at `wrap_width`. Returns owned boundaries.
pub fn compute_wrap_boundaries(
    allocator: Allocator,
    layout: *const LineLayout,
    text: []const u8,
    wrap_width: Pixels,
    max_lines: ?usize,
    scratch: *WrapScratch,
) ![]WrapBoundary {
    // Shaping can combine characters across a line-break opportunity, so ignore the
    // break opportunities that would separate those characters.
    scratch.glyph_indices.clearRetainingCapacity();
    for (layout.runs) |run| for (run.glyphs) |glyph| try scratch.glyph_indices.put(allocator, glyph.index, {});
    scratch.break_indices.clearRetainingCapacity();
    var breaks: std.ArrayList(usize) = .empty;
    defer breaks.deinit(allocator);
    try line_wrapper.break_indices_into(allocator, text, &breaks);
    for (breaks.items) |b| {
        if (scratch.glyph_indices.contains(b)) try scratch.break_indices.append(allocator, b);
    }
    const break_indices = scratch.break_indices.items;

    // Flatten the glyphs, dropping consecutive glyphs that share a cluster index.
    scratch.items.clearRetainingCapacity();
    for (layout.runs, 0..) |run, run_ix| {
        for (run.glyphs, 0..) |glyph, glyph_ix| {
            const item: WrapScratch.Item = .{
                .boundary = .{ .run_ix = run_ix, .glyph_ix = glyph_ix },
                .index = glyph.index,
                .x = glyph.position.x,
            };
            if (scratch.items.items.len > 0 and scratch.items.items[scratch.items.items.len - 1].index == glyph.index) continue;
            try scratch.items.append(allocator, item);
        }
    }
    const items = scratch.items.items;

    var boundaries: std.ArrayList(WrapBoundary) = .empty;
    errdefer boundaries.deinit(allocator);
    var current_segment: ?struct { start: usize, end: usize } = null;
    var last_candidate: ?WrapBoundary = null;
    var last_candidate_x: Pixels = 0;
    var last_boundary: WrapBoundary = .{ .run_ix = 0, .glyph_ix = 0 };
    var last_boundary_x: Pixels = 0;

    for (items, 0..) |item, i| {
        const index = item.index;
        const byte = text[index];
        if (byte == '\n') continue;

        const in_segment = if (current_segment) |seg| (index >= seg.start and index < seg.end) else false;
        if (byte != ' ' and !in_segment) {
            // Detect transitions between line-break segments rather than matching glyph
            // indices directly, to accommodate RTL text.
            const segment = partition_point(break_indices, index);
            if (current_segment != null) {
                last_candidate = item.boundary;
                last_candidate_x = item.x;
            }
            const start: usize = if (segment > 0) break_indices[segment - 1] else 0;
            const end: usize = if (segment < break_indices.len) break_indices[segment] else text.len;
            current_segment = .{ .start = start, .end = end };
        }

        const next_x: Pixels = if (i + 1 < items.len) items[i + 1].x else layout.width;
        const width = next_x - last_boundary_x;

        if (width > wrap_width and WrapBoundary.lt(last_boundary, item.boundary)) {
            // When line_clamp is used, limit the number of lines.
            if (max_lines) |max| {
                if (boundaries.items.len >= max -| 1) break;
            }
            if (last_candidate) |cand| {
                last_boundary = cand;
                last_boundary_x = last_candidate_x;
                last_candidate = null;
            } else {
                last_boundary = item.boundary;
                last_boundary_x = item.x;
            }
            try boundaries.append(allocator, last_boundary);
        }
    }
    return boundaries.toOwnedSlice(allocator);
}

/// Number of entries in sorted `breaks` that are `<= index`.
fn partition_point(breaks: []const usize, index: usize) usize {
    var lo: usize = 0;
    var hi: usize = breaks.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (breaks[mid] <= index) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Shifts glyphs so each occupies one `force_width` cell, leaving zero-advance combining
/// marks on their base's cell (GPUI `apply_force_width_to_layout`).
pub fn apply_force_width_to_layout(layout: *LineLayout, force_width: Pixels) void {
    var glyph_pos: usize = 0;
    // -inf ensures the first glyph is always classified as a base.
    var last_base_shaped_x: Pixels = -std.math.inf(f32);
    var last_base_actual_x: Pixels = 0;

    for (layout.runs) |run| {
        for (run.glyphs) |*glyph| {
            const shaped_x = glyph.position.x;
            if (shaped_x > last_base_shaped_x + force_width * 0.5) {
                const forced_x = @as(f32, @floatFromInt(glyph_pos)) * force_width;
                if (@abs(shaped_x - forced_x) > 1.0) glyph.position.x = forced_x;
                last_base_shaped_x = shaped_x;
                last_base_actual_x = glyph.position.x;
                glyph_pos += 1;
            } else {
                glyph.position.x = last_base_actual_x + (shaped_x - last_base_shaped_x);
            }
        }
    }
}

/// Two frames of cached values keyed by a request (text, font size, runs, wrap and force widths).
fn FrameCache(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Key = struct {
            text: []const u8,
            font_size: Pixels,
            runs: []const FontRun,
            wrap_width: ?Pixels,
            force_width: ?Pixels,
        };

        pub const Entry = struct {
            hash: u64,
            font_size: Pixels,
            runs: []FontRun,
            wrap_width: ?Pixels,
            force_width: ?Pixels,
            value: V,
        };

        current: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
        previous: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
        /// Entries that collided with a hash already in use; they live for the same two frames.
        current_extra: std.ArrayList(*Entry) = .empty,
        previous_extra: std.ArrayList(*Entry) = .empty,

        fn hash_key(k: Key) u64 {
            var h = std.hash.Wyhash.init(0x5a17_c0de);
            h.update(k.text);
            h.update(std.mem.asBytes(&k.font_size));
            for (k.runs) |run| {
                h.update(std.mem.asBytes(&run.len));
                h.update(std.mem.asBytes(&run.font_id));
            }
            h.update(std.mem.asBytes(&k.wrap_width));
            h.update(std.mem.asBytes(&k.force_width));
            return h.final();
        }

        fn matches(e: *const Entry, k: Key) bool {
            if (e.font_size != k.font_size or e.wrap_width != k.wrap_width or e.force_width != k.force_width) return false;
            if (e.runs.len != k.runs.len) return false;
            for (e.runs, k.runs) |a, b| {
                if (a.len != b.len or a.font_id != b.font_id) return false;
            }
            return std.mem.eql(u8, e.value.text, k.text);
        }

        /// Finds `k` in the current frame, or moves it from the previous frame into the current one.
        fn take(self: *Self, allocator: Allocator, h: u64, k: Key) !?*Entry {
            if (self.current.get(h)) |e| {
                if (matches(e, k)) return e;
            }
            if (self.previous.get(h)) |e| {
                if (matches(e, k)) {
                    _ = self.previous.remove(h);
                    try self.insert(allocator, e);
                    return e;
                }
            }
            return null;
        }

        fn insert(self: *Self, allocator: Allocator, e: *Entry) !void {
            if (self.current.contains(e.hash)) {
                try self.current_extra.append(allocator, e);
            } else {
                try self.current.put(allocator, e.hash, e);
            }
        }

        /// Frees everything not used in the frame that just ended, then rotates the frames.
        fn finish(self: *Self, allocator: Allocator) void {
            var it = self.previous.valueIterator();
            while (it.next()) |e| destroy(allocator, e.*);
            self.previous.clearRetainingCapacity();
            for (self.previous_extra.items) |e| destroy(allocator, e);
            self.previous_extra.clearRetainingCapacity();

            std.mem.swap(std.AutoHashMapUnmanaged(u64, *Entry), &self.previous, &self.current);
            std.mem.swap(std.ArrayList(*Entry), &self.previous_extra, &self.current_extra);
        }

        fn destroy(allocator: Allocator, e: *Entry) void {
            e.value.deinit(allocator);
            allocator.free(e.runs);
            allocator.destroy(e);
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            var it = self.current.valueIterator();
            while (it.next()) |e| destroy(allocator, e.*);
            var pit = self.previous.valueIterator();
            while (pit.next()) |e| destroy(allocator, e.*);
            for (self.current_extra.items) |e| destroy(allocator, e);
            for (self.previous_extra.items) |e| destroy(allocator, e);
            self.current.deinit(allocator);
            self.previous.deinit(allocator);
            self.current_extra.deinit(allocator);
            self.previous_extra.deinit(allocator);
        }
    };
}

/// Shapes lines of text and caches the results across frames (GPUI `LineLayoutCache`).
pub const LineLayoutCache = struct {
    /// Shapes one unwrapped line. The returned layout's `text` is set by the cache.
    pub const Shaper = struct {
        ctx: *anyopaque,
        shape_fn: *const fn (ctx: *anyopaque, allocator: Allocator, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) anyerror!LineLayout,
    };

    allocator: Allocator,
    shaper: Shaper,
    lines: FrameCache(LineLayout) = .{},
    wrapped: FrameCache(WrappedLineLayout) = .{},
    wrap_scratch: WrapScratch = .{},

    pub fn init(allocator: Allocator, shaper: Shaper) LineLayoutCache {
        return .{ .allocator = allocator, .shaper = shaper };
    }

    pub fn deinit(self: *LineLayoutCache) void {
        self.lines.deinit(self.allocator);
        self.wrapped.deinit(self.allocator);
        self.wrap_scratch.deinit(self.allocator);
    }

    /// Shapes `text` without wrapping, reusing a cached layout when one exists.
    pub fn layout_line(self: *LineLayoutCache, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) !*const LineLayout {
        const key: @TypeOf(self.lines).Key = .{ .text = text, .font_size = font_size, .runs = runs, .wrap_width = null, .force_width = force_width };
        const h = @TypeOf(self.lines).hash_key(key);
        if (try self.lines.take(self.allocator, h, key)) |e| return &e.value;

        var layout = try self.shaper.shape_fn(self.shaper.ctx, self.allocator, text, font_size, runs, force_width);
        errdefer layout.deinit(self.allocator);
        layout.text = try self.allocator.dupe(u8, text);
        if (force_width) |fw| apply_force_width_to_layout(&layout, fw);

        const e = try self.allocator.create(@TypeOf(self.lines).Entry);
        errdefer self.allocator.destroy(e);
        const owned_runs = try self.allocator.dupe(FontRun, runs);
        errdefer self.allocator.free(owned_runs);
        e.* = .{ .hash = h, .font_size = font_size, .runs = owned_runs, .wrap_width = null, .force_width = force_width, .value = layout };
        try self.lines.insert(self.allocator, e);
        return &e.value;
    }

    /// Shapes `text` and wraps it to `wrap_width`, reusing a cached result when one exists.
    /// With `max_lines`, wrapping stops after that many lines when first computed.
    pub fn layout_wrapped_line(
        self: *LineLayoutCache,
        text: []const u8,
        font_size: Pixels,
        runs: []const FontRun,
        wrap_width: ?Pixels,
        max_lines: ?usize,
    ) !*const WrappedLineLayout {
        const Wrapped = FrameCache(WrappedLineLayout);
        const key: Wrapped.Key = .{ .text = text, .font_size = font_size, .runs = runs, .wrap_width = wrap_width, .force_width = null };
        const h = Wrapped.hash_key(key);
        // The unwrapped layout must stay alive as long as this entry does, so fetch it
        // (which also moves it into the current frame) on every request.
        if (try self.wrapped.take(self.allocator, h, key)) |e| {
            e.value.unwrapped_layout = try self.layout_line(text, font_size, runs, null);
            return &e.value;
        }

        const unwrapped = try self.layout_line(text, font_size, runs, null);
        const boundaries: []WrapBoundary = if (wrap_width) |ww|
            try compute_wrap_boundaries(self.allocator, unwrapped, text, ww, max_lines, &self.wrap_scratch)
        else
            try self.allocator.alloc(WrapBoundary, 0);
        errdefer self.allocator.free(boundaries);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_runs = try self.allocator.dupe(FontRun, runs);
        errdefer self.allocator.free(owned_runs);

        const e = try self.allocator.create(Wrapped.Entry);
        errdefer self.allocator.destroy(e);
        e.* = .{
            .hash = h,
            .font_size = font_size,
            .runs = owned_runs,
            .wrap_width = wrap_width,
            .force_width = null,
            .value = .{ .unwrapped_layout = unwrapped, .boundaries = boundaries, .wrap_width = wrap_width, .text = owned_text },
        };
        try self.wrapped.insert(self.allocator, e);
        return &e.value;
    }

    /// Ends the frame: frees layouts unused since the previous frame and rotates the caches.
    pub fn finish_frame(self: *LineLayoutCache) void {
        // Wrapped entries reference unwrapped layouts, so free them first.
        self.wrapped.finish(self.allocator);
        self.lines.finish(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests (ported from GPUI's line_layout tests, which need no font system).

const testing = std.testing;

fn glyph_at(x: f32, index: usize) ShapedGlyph {
    return .{ .id = 0, .position = .{ .x = x, .y = 0 }, .index = index, .is_emoji = false };
}

/// A single-run layout over `glyphs` (the caller frees it with `free_test_layout`).
fn make_layout(glyphs: []ShapedGlyph) !LineLayout {
    const runs = try testing.allocator.alloc(ShapedRun, 1);
    runs[0] = .{ .font_id = 0, .glyphs = try testing.allocator.dupe(ShapedGlyph, glyphs) };
    return .{ .font_size = 16, .width = 100, .ascent = 12, .descent = 4, .runs = runs, .len = 0 };
}

fn free_test_layout(layout: *LineLayout) void {
    for (layout.runs) |run| testing.allocator.free(run.glyphs);
    testing.allocator.free(layout.runs);
}

fn glyph_x_positions(layout: *const LineLayout, out: []f32) []f32 {
    for (layout.runs[0].glyphs, 0..) |g, i| out[i] = g.position.x;
    return out[0..layout.runs[0].glyphs.len];
}

test "wrap preserves shaped clusters" {
    var glyphs = [_]ShapedGlyph{ glyph_at(0, 0), glyph_at(5, 0), glyph_at(10, 3), glyph_at(15, 3) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    layout.width = 20;
    layout.len = "你好".len;
    var scratch: WrapScratch = .{};
    defer scratch.deinit(testing.allocator);
    const b = try compute_wrap_boundaries(testing.allocator, &layout, "你好", 15, null, &scratch);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(WrapBoundary, &.{.{ .run_ix = 0, .glyph_ix = 2 }}, b);

    var glyphs2 = [_]ShapedGlyph{ glyph_at(0, 0), glyph_at(10, 0) };
    var layout2 = try make_layout(&glyphs2);
    defer free_test_layout(&layout2);
    layout2.width = 20;
    layout2.len = 1;
    const b2 = try compute_wrap_boundaries(testing.allocator, &layout2, "a", 10, null, &scratch);
    defer testing.allocator.free(b2);
    try testing.expectEqual(@as(usize, 0), b2.len);
}

test "wrap right-to-left text" {
    const cases = [_]struct { text: []const u8, indices: []const usize, expected: []const usize }{
        .{ .text = "אבג דהו", .indices = &.{ 11, 9, 7, 6, 4, 2, 0 }, .expected = &.{4} },
        .{ .text = "a אבג b", .indices = &.{ 0, 1, 6, 4, 2, 8, 9 }, .expected = &.{ 2, 6 } },
    };
    var scratch: WrapScratch = .{};
    defer scratch.deinit(testing.allocator);
    for (cases) |c| {
        var glyphs: [16]ShapedGlyph = undefined;
        for (c.indices, 0..) |index, pos| glyphs[pos] = glyph_at(@as(f32, @floatFromInt(pos)) * 10, index);
        var layout = try make_layout(glyphs[0..c.indices.len]);
        defer free_test_layout(&layout);
        layout.width = @as(f32, @floatFromInt(c.indices.len)) * 10;
        layout.len = c.text.len;
        const b = try compute_wrap_boundaries(testing.allocator, &layout, c.text, 40, null, &scratch);
        defer testing.allocator.free(b);
        try testing.expectEqual(c.expected.len, b.len);
        for (c.expected, b) |want, got| try testing.expectEqual(want, got.glyph_ix);
    }
}

test "wrap ignores breaks inside shaped clusters" {
    const text = "x a-bcde";
    const indices = [_]usize{ 0, 1, 2, 5, 6, 7 };
    var glyphs: [6]ShapedGlyph = undefined;
    for (indices, 0..) |index, i| glyphs[i] = glyph_at(@as(f32, @floatFromInt(index)) * 10, index);
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    layout.width = 80;
    layout.len = text.len;
    var scratch: WrapScratch = .{};
    defer scratch.deinit(testing.allocator);
    const b = try compute_wrap_boundaries(testing.allocator, &layout, text, 60, null, &scratch);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(WrapBoundary, &.{.{ .run_ix = 0, .glyph_ix = 2 }}, b);
}

test "force width leaves latin unchanged" {
    var glyphs = [_]ShapedGlyph{ glyph_at(0, 0), glyph_at(8, 1), glyph_at(16, 2) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    apply_force_width_to_layout(&layout, 8);
    var buf: [3]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{ 0, 8, 16 }, glyph_x_positions(&layout, &buf));
}

test "force width does not advance combining marks" {
    // Thai "กี": base consonant and combining vowel both at x=0.
    var glyphs = [_]ShapedGlyph{ glyph_at(0, 0), glyph_at(0, 3) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    apply_force_width_to_layout(&layout, 8);
    var buf: [2]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{ 0, 0 }, glyph_x_positions(&layout, &buf));
}

test "force width places a base after a combining mark" {
    var glyphs = [_]ShapedGlyph{ glyph_at(0, 0), glyph_at(0, 3), glyph_at(8, 6) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    apply_force_width_to_layout(&layout, 8);
    var buf: [3]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{ 0, 0, 8 }, glyph_x_positions(&layout, &buf));
}

test "force width corrects drifted base positions" {
    // Glyphs more than 1px off the cell grid are moved onto it; the first is within tolerance.
    var glyphs = [_]ShapedGlyph{ glyph_at(0.5, 0), glyph_at(10.2, 1), glyph_at(19.8, 2) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    apply_force_width_to_layout(&layout, 8);
    var buf: [3]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{ 0.5, 8, 16 }, glyph_x_positions(&layout, &buf));
}

test "force width keeps a combining mark on a within-tolerance base" {
    var glyphs = [_]ShapedGlyph{ glyph_at(0.5, 0), glyph_at(0.5, 3) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    apply_force_width_to_layout(&layout, 8);
    var buf: [2]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, glyph_x_positions(&layout, &buf));
}

test "index_for_x and x_for_index" {
    var glyphs = [_]ShapedGlyph{ glyph_at(0, 0), glyph_at(8, 1), glyph_at(16, 2) };
    var layout = try make_layout(&glyphs);
    defer free_test_layout(&layout);
    layout.len = 3;
    try testing.expectEqual(@as(?usize, 1), layout.index_for_x(9));
    try testing.expectEqual(@as(?usize, null), layout.index_for_x(100));
    try testing.expectEqual(@as(f32, 8), layout.x_for_index(1));
    try testing.expectEqual(@as(f32, 100), layout.x_for_index(3));
    try testing.expectEqual(@as(usize, 2), layout.closest_index_for_x(13));
}

/// Test shaper: one 8px glyph per byte, so cache tests need no font system.
fn test_shape(ctx: *anyopaque, allocator: Allocator, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) anyerror!LineLayout {
    _ = ctx;
    _ = runs;
    _ = force_width;
    const glyphs = try allocator.alloc(ShapedGlyph, text.len);
    for (glyphs, 0..) |*g, i| g.* = glyph_at(@as(f32, @floatFromInt(i)) * 8, i);
    const runs_out = try allocator.alloc(ShapedRun, 1);
    runs_out[0] = .{ .font_id = 0, .glyphs = glyphs };
    return .{ .font_size = font_size, .width = @as(f32, @floatFromInt(text.len)) * 8, .ascent = 12, .descent = 4, .runs = runs_out, .len = text.len };
}

test "cache reuses layouts within a frame and across the next" {
    var dummy: u8 = 0;
    var cache = LineLayoutCache.init(testing.allocator, .{ .ctx = &dummy, .shape_fn = test_shape });
    defer cache.deinit();
    const runs = [_]FontRun{.{ .len = 3, .font_id = 0 }};
    const a = try cache.layout_line("abc", 16, &runs, null);
    const b = try cache.layout_line("abc", 16, &runs, null);
    try testing.expect(a == b);
    try testing.expectEqualStrings("abc", a.text);

    cache.finish_frame();
    // Still valid for the next frame, and reused without reshaping.
    const c = try cache.layout_line("abc", 16, &runs, null);
    try testing.expect(a == c);
    cache.finish_frame();
    cache.finish_frame();
    // Unused for a full frame: freed, so a new request gets a fresh layout.
    const d = try cache.layout_line("abc", 16, &runs, null);
    try testing.expectEqual(@as(f32, 24), d.width);
}

test "wrapped cache keeps its unwrapped layout alive" {
    var dummy: u8 = 0;
    var cache = LineLayoutCache.init(testing.allocator, .{ .ctx = &dummy, .shape_fn = test_shape });
    defer cache.deinit();
    const runs = [_]FontRun{.{ .len = 6, .font_id = 0 }};
    const w = try cache.layout_wrapped_line("ab cde", 16, &runs, 30, null);
    try testing.expectEqual(@as(usize, 6), w.len());
    cache.finish_frame();
    // Reuse the wrapped entry only; its unwrapped layout must follow it into the new frame.
    const w2 = try cache.layout_wrapped_line("ab cde", 16, &runs, 30, null);
    try testing.expect(w == w2);
    cache.finish_frame();
    try testing.expectEqual(@as(f32, 48), w2.unwrapped_layout.width);
    cache.finish_frame();
}

/// The number of leading glyphs whose index is below `byte_index`, found by binary search as Rust's
/// `slice::partition_point` does. The search is part of the contract when the glyphs are not in order.
fn partition_point_glyphs(glyphs: []const ShapedGlyph, byte_index: usize) usize {
    if (glyphs.len == 0) return 0;
    var size = glyphs.len;
    var base: usize = 0;
    while (size > 1) {
        const half = size / 2;
        const mid = base + half;
        if (glyphs[mid].index < byte_index) base = mid;
        size -= half;
    }
    return base + @intFromBool(glyphs[base].index < byte_index);
}

/// Frees the runs of a layout returned by `split_at`.
fn free_split_pieces(left: LineLayout, right: LineLayout) void {
    for (left.runs) |run| testing.allocator.free(run.glyphs);
    testing.allocator.free(left.runs);
    for (right.runs) |run| testing.allocator.free(run.glyphs);
    testing.allocator.free(right.runs);
}

/// Frees a layout built by `make_split_layout`.
fn free_split_layout(layout: *LineLayout) void {
    for (layout.runs) |run| testing.allocator.free(run.glyphs);
    testing.allocator.free(layout.runs);
}

/// Two runs over "abcdef" with glyph ids `index * 10`: run 0 (font 0) holds bytes 0..3 at x 0, 10, 20;
/// run 1 (font 1) holds bytes 3..6 at x 30, 40, 50.
fn make_split_layout() !LineLayout {
    const runs = try testing.allocator.alloc(ShapedRun, 2);
    const a = try testing.allocator.alloc(ShapedGlyph, 3);
    const b = try testing.allocator.alloc(ShapedGlyph, 3);
    for (a, 0..) |*g, i| g.* = .{ .id = @intCast(i * 10), .position = .{ .x = @as(f32, @floatFromInt(i)) * 10, .y = 0 }, .index = i, .is_emoji = false };
    for (b, 0..) |*g, i| g.* = .{ .id = @intCast((i + 3) * 10), .position = .{ .x = 30 + @as(f32, @floatFromInt(i)) * 10, .y = 0 }, .index = i + 3, .is_emoji = false };
    runs[0] = .{ .font_id = 0, .glyphs = a };
    runs[1] = .{ .font_id = 1, .glyphs = b };
    return .{ .font_size = 16, .width = 60, .ascent = 12, .descent = 4, .runs = runs, .len = 6 };
}

/// The glyph ids of every run of `layout`, in run order, written to `buf`.
fn collect_glyph_ids(layout: *const LineLayout, buf: []GlyphId) []GlyphId {
    var n: usize = 0;
    for (layout.runs) |run| for (run.glyphs) |g| {
        buf[n] = g.id;
        n += 1;
    };
    return buf[0..n];
}

test "split_at keeps every glyph at every boundary, with widths and lengths adding up" {
    var layout = try make_split_layout();
    defer free_split_layout(&layout);
    var all_buf: [6]GlyphId = undefined;
    const all = collect_glyph_ids(&layout, &all_buf);
    for (0..layout.len + 1) |i| {
        const left, const right = try layout.split_at(testing.allocator, i);
        defer free_split_pieces(left, right);
        try testing.expectEqual(layout.len, left.len + right.len);
        try testing.expectApproxEqAbs(layout.width, left.width + right.width, 0.0001);
        try testing.expectEqual(layout.font_size, left.font_size);
        try testing.expectEqual(layout.ascent, right.ascent);
        try testing.expectEqual(layout.descent, left.descent);

        // Every glyph lands in exactly one half, in order, with its id intact.
        var left_buf: [6]GlyphId = undefined;
        var right_buf: [6]GlyphId = undefined;
        const lg = collect_glyph_ids(&left, &left_buf);
        const rg = collect_glyph_ids(&right, &right_buf);
        var joined: [6]GlyphId = undefined;
        @memcpy(joined[0..lg.len], lg);
        @memcpy(joined[lg.len .. lg.len + rg.len], rg);
        try testing.expectEqualSlices(GlyphId, all, joined[0 .. lg.len + rg.len]);

        // The suffix starts at x = 0 and its byte indices are rebased; the prefix ends at the split.
        const x_offset = layout.x_for_index(i);
        try testing.expectApproxEqAbs(x_offset, left.width, 0.0001);
        for (right.runs) |run| for (run.glyphs) |g| {
            try testing.expect(g.index < right.len);
            try testing.expectApproxEqAbs(layout.x_for_index(g.index + i) - x_offset, g.position.x, 0.0001);
        };
        for (left.runs) |run| for (run.glyphs) |g| try testing.expect(g.index < left.len);
    }
}

test "split_at inside a run and at the run boundary" {
    var layout = try make_split_layout();
    defer free_split_layout(&layout);

    // Boundary 3 falls between the runs: the prefix is run 0 alone, the suffix run 1 alone.
    const left, const right = try layout.split_at(testing.allocator, 3);
    defer free_split_pieces(left, right);
    try testing.expectEqual(@as(usize, 1), left.runs.len);
    try testing.expectEqual(@as(usize, 1), right.runs.len);
    try testing.expectEqual(@as(FontId, 1), right.runs[0].font_id);
    try testing.expectEqual(@as(f32, 0), right.runs[0].glyphs[0].position.x);
    try testing.expectEqual(@as(usize, 0), right.runs[0].glyphs[0].index);
    try testing.expectEqual(@as(f32, 30), left.width);

    // Boundary 2 cuts run 0 in two: its last glyph (x=20) starts the suffix, and run 1 follows it there.
    const l2, const r2 = try layout.split_at(testing.allocator, 2);
    defer free_split_pieces(l2, r2);
    try testing.expectEqual(@as(usize, 1), l2.runs.len);
    try testing.expectEqual(@as(usize, 2), r2.runs.len);
    try testing.expectEqual(@as(usize, 1), r2.runs[0].glyphs.len);
    try testing.expectEqual(@as(usize, 0), r2.runs[0].glyphs[0].index);
    try testing.expectEqual(@as(f32, 0), r2.runs[0].glyphs[0].position.x);
    try testing.expectEqual(@as(usize, 1), r2.runs[1].glyphs[0].index);
    try testing.expectEqual(@as(f32, 10), r2.runs[1].glyphs[0].position.x);
    try testing.expectEqual(@as(f32, 20), l2.width);
}

test "split_at with multi-byte characters and an emoji" {
    // "aé😀b": 'a' at 0, 'é' at 1..3, '😀' at 3..7 (4 bytes), 'b' at 7. One glyph per cluster.
    const glyphs = try testing.allocator.dupe(ShapedGlyph, &.{
        glyph_at(0, 0),
        glyph_at(8, 1),
        .{ .id = 7, .position = .{ .x = 16, .y = 0 }, .index = 3, .is_emoji = true },
        glyph_at(32, 7),
    });
    const runs = try testing.allocator.alloc(ShapedRun, 1);
    runs[0] = .{ .font_id = 0, .glyphs = glyphs };
    var layout: LineLayout = .{ .font_size = 16, .width = 40, .ascent = 12, .descent = 4, .runs = runs, .len = 8 };
    defer free_split_layout(&layout);

    for ([_]usize{ 0, 1, 3, 7, 8 }) |i| {
        const left, const right = try layout.split_at(testing.allocator, i);
        defer free_split_pieces(left, right);
        try testing.expectEqual(@as(usize, 8), left.len + right.len);
        try testing.expectApproxEqAbs(@as(f32, 40), left.width + right.width, 0.0001);
        var n: usize = 0;
        for (left.runs) |run| n += run.glyphs.len;
        for (right.runs) |run| n += run.glyphs.len;
        try testing.expectEqual(@as(usize, 4), n);
    }

    // Split before 'b': the emoji stays on the left with its flag, and 'b' starts the suffix at x = 0.
    const left, const right = try layout.split_at(testing.allocator, 7);
    defer free_split_pieces(left, right);
    try testing.expectEqual(@as(usize, 7), left.len);
    try testing.expect(left.runs[0].glyphs[2].is_emoji);
    try testing.expectEqual(@as(usize, 0), right.runs[0].glyphs[0].index);
    try testing.expectEqual(@as(f32, 0), right.runs[0].glyphs[0].position.x);
    try testing.expectEqual(@as(f32, 32), left.width);
    try testing.expectEqual(@as(f32, 8), right.width);
}
