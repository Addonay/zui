//! Port of GPUI `text_system/line.rs`: shaped and wrapped lines, their hit testing, and
//! painting of glyphs, decorations and backgrounds.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const color_mod = @import("../color.zig");
const text_system = @import("../text_system.zig");
const line_layout = @import("line_layout.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Hsla = color_mod.Hsla;
const TextAlign = style.TextAlign;
const UnderlineStyle = style.UnderlineStyle;
const StrikethroughStyle = style.StrikethroughStyle;
const LineLayout = line_layout.LineLayout;
const ShapedRun = line_layout.ShapedRun;
const WrappedLineLayout = line_layout.WrappedLineLayout;
const WrapBoundary = line_layout.WrapBoundary;
const IndexResult = line_layout.IndexResult;
const Window = window_mod.Window;
const App = app_mod.App;

/// A half-open range of byte indices (GPUI `Range<usize>`).
pub const ByteRange = struct {
    start: usize,
    end: usize,

    pub fn contains(self: ByteRange, index: usize) bool {
        return index >= self.start and index < self.end;
    }
};

/// Called with each underline a line paints, in place of `Window.paint_underline` (GPUI's
/// `paint_underline` closure in `paint_with_underline_handler`). `range` is the bytes the underline
/// covers, and `origin` and `width` are where and how far it goes. Zig has no closures, so `func`
/// takes `ctx` as its first argument.
pub const UnderlineHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, range: ByteRange, origin: Point(Pixels), width: Pixels, underline_style: *const UnderlineStyle, window: *Window) void = paint_default_underline,
};

fn paint_default_underline(ctx: ?*anyopaque, range: ByteRange, origin: Point(Pixels), width: Pixels, underline_style: *const UnderlineStyle, window: *Window) void {
    _ = ctx;
    _ = range;
    window.paint_underline(origin, width, underline_style);
}

/// Decoration (color, background, underline, strikethrough) of `len` bytes of a line.
pub const DecorationRun = struct {
    /// The length of the run in UTF-8 bytes.
    len: u32,
    /// The text color for this run.
    color: Hsla,
    /// The background color for this run.
    background_color: ?Hsla = null,
    /// The underline style for this run.
    underline: ?UnderlineStyle = null,
    /// The strikethrough style for this run.
    strikethrough: ?StrikethroughStyle = null,
};

/// A line of text that has been shaped and decorated (GPUI `ShapedLine`).
pub const ShapedLine = struct {
    /// The shaped glyphs. Owned by the line cache.
    layout: *const LineLayout,
    /// The text that was shaped for this line.
    text: []const u8 = &.{},
    decoration_runs: []const DecorationRun = &.{},

    /// The length of the line in UTF-8 bytes.
    pub fn len(self: ShapedLine) usize {
        return self.layout.len;
    }

    /// The width of the shaped line in pixels.
    pub fn width(self: ShapedLine) Pixels {
        return self.layout.width;
    }

    /// The x position of the character at byte `index`.
    pub fn x_for_index(self: ShapedLine, index: usize) Pixels {
        return self.layout.x_for_index(index);
    }

    /// The byte index of the character at `x`, or null past the end of the line.
    pub fn index_for_x(self: ShapedLine, x: Pixels) ?usize {
        return self.layout.index_for_x(x);
    }

    /// The character boundary closest to `x`.
    pub fn closest_index_for_x(self: ShapedLine, x: Pixels) usize {
        return self.layout.closest_index_for_x(x);
    }

    /// The font of the glyph at byte `index`.
    pub fn font_id_for_index(self: ShapedLine, index: usize) ?text_system.FontId {
        return self.layout.font_id_for_index(index);
    }

    /// Returns a forward-only cursor that splits this line at increasing byte boundaries (GPUI `cursor`).
    /// The line's length must equal its text's length.
    pub fn cursor(self: *const ShapedLine) ShapedLineCursor {
        std.debug.assert(self.len() == self.text.len);
        return .{
            .line = self,
            .unordered_remainder = if (glyphs_in_byte_order(self.layout)) null else self.*,
        };
    }

    /// The same line with `len` as its length, for text that is drawn as other text (GPUI `with_len`).
    pub fn with_len(self: ShapedLine, byte_len: usize) !ShapedLine {
        const layout = try new_layout(.{
            .font_size = self.layout.font_size,
            .width = self.layout.width,
            .ascent = self.layout.ascent,
            .descent = self.layout.descent,
            .runs = self.layout.runs,
            .len = byte_len,
        });
        var out = self;
        out.layout = layout;
        return out;
    }

    /// Splits the line at byte `byte_index` into `(prefix, suffix)` (GPUI `split_at`).
    ///
    /// - `prefix` has the glyphs for bytes `[0, byte_index)` at their positions.
    /// - `suffix` has the glyphs for the rest, shifted left so its first glyph is at x=0, and byte
    ///   indices rebased to 0.
    /// - Decoration runs are partitioned at the boundary, and a run that straddles it is split in two.
    ///
    /// The pieces are allocated in the frame arena.
    pub fn split_at(self: ShapedLine, byte_index: usize) !struct { ShapedLine, ShapedLine } {
        const arena = window_mod.frame_arena();
        const pieces = try self.layout.split_at(arena, byte_index);

        // Partition the decoration runs. A run straddling the boundary is split into two.
        var left_decorations: std.ArrayList(DecorationRun) = .empty;
        var right_decorations: std.ArrayList(DecorationRun) = .empty;
        var decoration_offset: u32 = 0;
        const split_point: u32 = @intCast(byte_index);
        for (self.decoration_runs) |decoration| {
            const run_end = decoration_offset + decoration.len;
            if (run_end <= split_point) {
                try left_decorations.append(arena, decoration);
            } else if (decoration_offset >= split_point) {
                try right_decorations.append(arena, decoration);
            } else {
                var left_part = decoration;
                left_part.len = split_point - decoration_offset;
                var right_part = decoration;
                right_part.len = run_end - split_point;
                try left_decorations.append(arena, left_part);
                try right_decorations.append(arena, right_part);
            }
            decoration_offset = run_end;
        }

        const left: ShapedLine = .{
            .layout = try new_layout(pieces[0]),
            .text = self.text[0..byte_index],
            .decoration_runs = try left_decorations.toOwnedSlice(arena),
        };
        const right: ShapedLine = .{
            .layout = try new_layout(pieces[1]),
            .text = self.text[byte_index..],
            .decoration_runs = try right_decorations.toOwnedSlice(arena),
        };
        return .{ left, right };
    }

    /// Paints the line's glyphs and decorations at `origin`.
    pub fn paint(self: ShapedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, align_width: ?Pixels, window: *Window, cx: *App) !void {
        try self.paint_with_underline_handler(origin, line_height, text_align, align_width, window, cx, .{});
    }

    /// Paints like `paint`, but hands each underline to `underline` instead of painting it (GPUI
    /// `paint_with_underline_handler`). The handler gets the bytes an underline covers, which is how a
    /// caller can place a glyph-specific underline.
    pub fn paint_with_underline_handler(
        self: ShapedLine,
        origin: Point(Pixels),
        line_height: Pixels,
        text_align: TextAlign,
        align_width: ?Pixels,
        window: *Window,
        cx: *App,
        underline: UnderlineHandler,
    ) !void {
        try paint_line(origin, self.layout, line_height, text_align, align_width, self.decoration_runs, &.{}, underline, window, cx);
    }

    /// Paints the line's background colors at `origin`.
    pub fn paint_background(self: ShapedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, align_width: ?Pixels, window: *Window, cx: *App) !void {
        try paint_line_background(origin, self.layout, line_height, text_align, align_width, self.decoration_runs, &.{}, window, cx);
    }
};

/// Allocates `layout` in the frame arena.
fn new_layout(layout: LineLayout) !*const LineLayout {
    const out = try window_mod.frame_arena().create(LineLayout);
    out.* = layout;
    return out;
}

/// Whether the glyphs of every run are in byte order (bidirectional text is not).
fn glyphs_in_byte_order(layout: *const LineLayout) bool {
    var previous: usize = 0;
    for (layout.runs) |run| for (run.glyphs) |glyph| {
        if (glyph.index < previous) return false;
        previous = glyph.index;
    };
    return true;
}

/// Forward-only splitting of a `ShapedLine` at increasing byte boundaries (GPUI `ShapedLineCursor`).
///
/// Each piece keeps the original glyphs and decorations, rebased as in `ShapedLine.split_at`. Glyphs in
/// byte order are advanced in linear time, and each glyph is copied at most once. Visually reordered
/// glyphs fall back to `split_at` on what is left.
pub const ShapedLineCursor = struct {
    line: *const ShapedLine,
    /// Bidirectional shaping can put glyphs out of byte order.
    unordered_remainder: ?ShapedLine,
    byte_index: usize = 0,
    run_index: usize = 0,
    glyph_index: usize = 0,
    decoration_index: usize = 0,
    decoration_offset: u32 = 0,
    at_x: Pixels = 0,

    /// Takes the bytes since the previous boundary.
    ///
    /// The boundary must not move backwards, must not exceed the line's length, and must fall on a
    /// UTF-8 character boundary. These are asserted, which is a panic in Debug builds (GPUI panics too).
    pub fn take_until(self: *ShapedLineCursor, byte_index: usize) !ShapedLine {
        std.debug.assert(byte_index >= self.byte_index); // split boundary moved backwards
        std.debug.assert(byte_index <= self.line.len()); // split boundary exceeds line length
        std.debug.assert(byte_index == self.line.text.len or (self.line.text[byte_index] & 0xC0) != 0x80); // not a character boundary

        const previous_index = self.byte_index;
        const previous_x = self.at_x;
        if (self.unordered_remainder) |*remainder| {
            const pieces = try remainder.split_at(byte_index - previous_index);
            remainder.* = pieces[1];
            self.byte_index = byte_index;
            self.at_x = self.line.layout.x_for_index(byte_index);
            return pieces[0];
        }

        const arena = window_mod.frame_arena();
        const layout = self.line.layout;
        var runs: std.ArrayList(ShapedRun) = .empty;
        var next_x: Pixels = layout.width;
        while (self.run_index < layout.runs.len) {
            const run = layout.runs[self.run_index];
            const start = self.glyph_index;
            while (self.glyph_index < run.glyphs.len and run.glyphs[self.glyph_index].index < byte_index) self.glyph_index += 1;
            const end = self.glyph_index;
            if (start < end) {
                const glyphs = try arena.alloc(line_layout.ShapedGlyph, end - start);
                for (run.glyphs[start..end], glyphs) |glyph, *out| {
                    out.* = .{
                        .id = glyph.id,
                        .position = .{ .x = glyph.position.x - previous_x, .y = glyph.position.y },
                        .index = glyph.index - previous_index,
                        .is_emoji = glyph.is_emoji,
                    };
                }
                try runs.append(arena, .{ .font_id = run.font_id, .glyphs = glyphs });
            }
            if (self.glyph_index < run.glyphs.len) {
                next_x = run.glyphs[self.glyph_index].position.x;
                break;
            }
            self.run_index += 1;
            self.glyph_index = 0;
        }

        // Decoration runs that start before the boundary; the last one may continue past it.
        const split: u32 = @intCast(byte_index);
        var decorations: std.ArrayList(DecorationRun) = .empty;
        while (self.decoration_index < self.line.decoration_runs.len) {
            const decoration = self.line.decoration_runs[self.decoration_index];
            if (!(self.decoration_offset < split or (decoration.len == 0 and self.decoration_offset == split))) break;
            const end = self.decoration_offset + decoration.len;
            const start = @max(self.decoration_offset, @as(u32, @intCast(previous_index)));
            const len = @min(end, split) - start;
            if (len > 0 or decoration.len == 0) {
                var part = decoration;
                part.len = len;
                try decorations.append(arena, part);
            }
            if (end > split) break;
            self.decoration_index += 1;
            self.decoration_offset = end;
        }

        self.byte_index = byte_index;
        self.at_x = next_x;
        return .{
            .layout = try new_layout(.{
                .font_size = layout.font_size,
                .width = next_x - previous_x,
                .ascent = layout.ascent,
                .descent = layout.descent,
                .runs = try runs.toOwnedSlice(arena),
                .len = byte_index - previous_index,
            }),
            .text = self.line.text[previous_index..byte_index],
            .decoration_runs = try decorations.toOwnedSlice(arena),
        };
    }

    /// The x position of the original line at the current boundary (GPUI `x_offset`). The field is `at_x`, since Zig does not allow a field and a method of the same name.
    pub fn x_offset(self: *const ShapedLineCursor) Pixels {
        return self.at_x;
    }
};

/// A line of text that has been wrapped, shaped and decorated (GPUI `WrappedLine`).
pub const WrappedLine = struct {
    /// The wrapped layout. Owned by the line cache.
    layout: *const WrappedLineLayout,
    /// The text that was shaped for this line.
    text: []const u8 = &.{},
    decoration_runs: []const DecorationRun = &.{},

    /// The length of the underlying, unwrapped text in UTF-8 bytes.
    pub fn len(self: WrappedLine) usize {
        return self.layout.len();
    }

    /// The number of visual rows this line takes up.
    pub fn wrap_count(self: WrappedLine) usize {
        return self.layout.wrap_boundaries().len + 1;
    }

    /// The size of the wrapped line for `line_height`.
    pub fn size(self: WrappedLine, line_height: Pixels) Size(Pixels) {
        return self.layout.size(line_height);
    }

    /// The position of byte `index` relative to the line origin.
    pub fn position_for_index(self: WrappedLine, index: usize, line_height: Pixels) ?Point(Pixels) {
        return self.layout.position_for_index(index, line_height);
    }

    /// The byte index at `position` (relative to the line origin).
    pub fn index_for_position(self: WrappedLine, position: Point(Pixels), line_height: Pixels) IndexResult {
        return self.layout.index_for_position(position, line_height);
    }

    /// The character boundary closest to `position` (relative to the line origin).
    pub fn closest_index_for_position(self: WrappedLine, position: Point(Pixels), line_height: Pixels) IndexResult {
        return self.layout.closest_index_for_position(position, line_height);
    }

    /// Paints the line at `origin`, aligned within `bounds` when given (GPUI `paint`). Without bounds,
    /// the alignment width is the wrap width.
    pub fn paint(self: WrappedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, bounds: ?Bounds(Pixels), window: *Window, cx: *App) !void {
        const align_width: ?Pixels = if (bounds) |b| b.size.width else self.layout.wrap_width;
        try paint_line(origin, self.layout.unwrapped_layout, line_height, text_align, align_width, self.decoration_runs, self.layout.wrap_boundaries(), paint_default_underline_handler, window, cx);
    }

    /// Paints the background colors of the line at `origin` (GPUI `paint_background`).
    pub fn paint_background(self: WrappedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, bounds: ?Bounds(Pixels), window: *Window, cx: *App) !void {
        const align_width: ?Pixels = if (bounds) |b| b.size.width else self.layout.wrap_width;
        try paint_line_background(origin, self.layout.unwrapped_layout, line_height, text_align, align_width, self.decoration_runs, self.layout.wrap_boundaries(), window, cx);
    }
};

/// The handler `paint` uses: each underline goes straight to the window.
const paint_default_underline_handler: UnderlineHandler = .{};

/// Paints a bare layout (GPUI `LineLayout::paint`). Used by `LineLayout.paint`.
pub fn paint_layout(
    layout: *const LineLayout,
    origin: Point(Pixels),
    line_height: Pixels,
    text_align: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    window: *Window,
    cx: *App,
) !void {
    try paint_line(origin, layout, line_height, text_align, align_width, decoration_runs, &.{}, paint_default_underline_handler, window, cx);
}

/// Paints the background of a bare layout (GPUI `LineLayout::paint_background`). Used by `LineLayout.paint_background`.
pub fn paint_layout_background(
    layout: *const LineLayout,
    origin: Point(Pixels),
    line_height: Pixels,
    text_align: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    window: *Window,
    cx: *App,
) !void {
    try paint_line_background(origin, layout, line_height, text_align, align_width, decoration_runs, &.{}, window, cx);
}

/// Cursor over decoration runs (GPUI's `decoration_runs.iter()`).
const DecorationIter = struct {
    runs: []const DecorationRun,
    ix: usize = 0,

    fn next(self: *DecorationIter) ?*const DecorationRun {
        if (self.ix >= self.runs.len) return null;
        defer self.ix += 1;
        return &self.runs[self.ix];
    }
};

/// Cursor over wrap boundaries (GPUI's `wraps.peek()` / `wraps.next()`).
const WrapIter = struct {
    boundaries: []const WrapBoundary,
    ix: usize = 0,

    fn peek(self: *const WrapIter) ?WrapBoundary {
        if (self.ix >= self.boundaries.len) return null;
        return self.boundaries[self.ix];
    }

    /// Advances past the next boundary when it is `(run_ix, glyph_ix)`.
    fn take_if(self: *WrapIter, run_ix: usize, glyph_ix: usize) bool {
        const b = self.peek() orelse return false;
        if (b.run_ix != run_ix or b.glyph_ix != glyph_ix) return false;
        self.ix += 1;
        return true;
    }
};

/// Shared arguments for the paint passes; the pass runs inside a clipping layer.
const PaintArgs = struct {
    origin: Point(Pixels),
    layout: *const LineLayout,
    line_height: Pixels,
    text_align: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    wrap_boundaries: []const WrapBoundary,
    underline: UnderlineHandler,
    err: ?anyerror = null,
};

const UnderlineRun = struct { origin: Point(Pixels), style: UnderlineStyle, range: ByteRange };
const BackgroundRun = struct { origin: Point(Pixels), color: Hsla };
const StrikethroughRun = struct { origin: Point(Pixels), style: StrikethroughStyle };

fn paint_line(
    origin: Point(Pixels),
    layout: *const LineLayout,
    line_height: Pixels,
    text_align: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    wrap_boundaries: []const WrapBoundary,
    underline: UnderlineHandler,
    window: *Window,
    cx: *App,
) !void {
    var args: PaintArgs = .{
        .origin = origin,
        .layout = layout,
        .line_height = line_height,
        .text_align = text_align,
        .align_width = align_width,
        .decoration_runs = decoration_runs,
        .wrap_boundaries = wrap_boundaries,
        .underline = underline,
    };
    window.paint_layer(line_paint_bounds(origin, layout, line_height, text_align, align_width, wrap_boundaries), &args, paint_glyphs_pass, cx);
    if (args.err) |e| return e;
}

fn paint_line_background(
    origin: Point(Pixels),
    layout: *const LineLayout,
    line_height: Pixels,
    text_align: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    wrap_boundaries: []const WrapBoundary,
    window: *Window,
    cx: *App,
) !void {
    var args: PaintArgs = .{
        .origin = origin,
        .layout = layout,
        .line_height = line_height,
        .text_align = text_align,
        .align_width = align_width,
        .decoration_runs = decoration_runs,
        .wrap_boundaries = wrap_boundaries,
        .underline = .{},
    };
    window.paint_layer(line_paint_bounds(origin, layout, line_height, text_align, align_width, wrap_boundaries), &args, paint_background_pass, cx);
    if (args.err) |e| return e;
}

fn paint_glyphs_pass(args: *PaintArgs, window: *Window, cx: *App) void {
    paint_glyphs(args, window, cx) catch |e| {
        args.err = e;
    };
}

fn paint_background_pass(args: *PaintArgs, window: *Window, cx: *App) void {
    paint_backgrounds(args, window, cx);
}

/// Glyph, underline and strikethrough pass (GPUI `paint_line`).
fn paint_glyphs(args: *PaintArgs, window: *Window, cx: *App) !void {
    const origin = args.origin;
    const layout = args.layout;
    const line_height = args.line_height;
    const text_sys = cx.text_system();
    const padding_top = (line_height - layout.ascent - layout.descent) / 2.0;
    const baseline_offset: Point(Pixels) = .{ .x = 0, .y = padding_top + layout.ascent };
    const underline_y = text_system.underline_y_offset(line_height, layout.ascent, layout.descent);

    var decorations: DecorationIter = .{ .runs = args.decoration_runs };
    var wraps: WrapIter = .{ .boundaries = args.wrap_boundaries };
    var run_end: usize = 0;
    var color: Hsla = color_mod.black();
    var current_underline: ?UnderlineRun = null;
    var current_strikethrough: ?StrikethroughRun = null;

    const width_for_align = args.align_width orelse layout.width;
    var glyph_origin: Point(Pixels) = .{
        .x = aligned_origin_x(origin, width_for_align, 0, args.text_align, layout, wraps.peek()),
        .y = origin.y,
    };
    var prev_glyph_position: Point(Pixels) = .{ .x = 0, .y = 0 };
    var max_glyph_size: Size(Pixels) = .{ .width = 0, .height = 0 };
    var first_glyph_x = origin.x;

    for (layout.runs, 0..) |run, run_ix| {
        max_glyph_size = text_sys.bounding_box(run.font_id, layout.font_size).size;

        for (run.glyphs, 0..) |glyph, glyph_ix| {
            glyph_origin.x += glyph.position.x - prev_glyph_position.x;
            if (glyph_ix == 0 and run_ix == 0) first_glyph_x = glyph_origin.x;

            if (wraps.take_if(run_ix, glyph_ix)) {
                if (current_underline) |*cu| {
                    if (glyph_origin.x == cu.origin.x) cu.origin.x -= max_glyph_size.width / 2.0;
                    args.underline.func(args.underline.ctx, cu.range, cu.origin, glyph_origin.x - cu.origin.x, &cu.style, window);
                    if (glyph.index < run_end) {
                        cu.origin.x = origin.x;
                        cu.origin.y += line_height;
                    } else {
                        current_underline = null;
                    }
                }
                if (current_strikethrough) |*cs| {
                    if (glyph_origin.x == cs.origin.x) cs.origin.x -= max_glyph_size.width / 2.0;
                    window.paint_strikethrough(cs.origin, glyph_origin.x - cs.origin.x, &cs.style);
                    if (glyph.index < run_end) {
                        cs.origin.x = origin.x;
                        cs.origin.y += line_height;
                    } else {
                        current_strikethrough = null;
                    }
                }

                glyph_origin.x = aligned_origin_x(origin, width_for_align, glyph.position.x, args.text_align, layout, wraps.peek());
                glyph_origin.y += line_height;
            }
            prev_glyph_position = glyph.position;

            var finished_underline: ?UnderlineRun = null;
            var finished_strikethrough: ?StrikethroughRun = null;
            if (glyph.index >= run_end) {
                var style_run = decorations.next();
                // Ignore style runs that apply to a partial glyph.
                while (style_run) |sr| {
                    if (glyph.index < run_end + sr.len) break;
                    run_end += sr.len;
                    style_run = decorations.next();
                }

                if (style_run) |sr| {
                    if (current_underline) |*cu| {
                        const stored: ?UnderlineStyle = cu.style;
                        if (!std.meta.eql(sr.underline, stored)) {
                            finished_underline = current_underline;
                            current_underline = null;
                        } else {
                            // The same underline continues over this style run.
                            cu.range.end = run_end + sr.len;
                        }
                    }
                    if (sr.underline) |ru| {
                        if (current_underline == null) {
                            current_underline = .{
                                .origin = .{ .x = glyph_origin.x, .y = glyph_origin.y + underline_y },
                                .style = .{ .color = ru.color orelse sr.color, .thickness = ru.thickness, .wavy = ru.wavy },
                                .range = .{ .start = run_end, .end = run_end + sr.len },
                            };
                        }
                    }
                    if (current_strikethrough) |cs| {
                        const stored: ?StrikethroughStyle = cs.style;
                        if (!std.meta.eql(sr.strikethrough, stored)) {
                            finished_strikethrough = current_strikethrough;
                            current_strikethrough = null;
                        }
                    }
                    if (sr.strikethrough) |rs| {
                        if (current_strikethrough == null) {
                            current_strikethrough = .{
                                .origin = .{
                                    .x = glyph_origin.x,
                                    .y = glyph_origin.y + (((layout.ascent * 0.5) + baseline_offset.y) * 0.5),
                                },
                                .style = .{ .color = rs.color orelse sr.color, .thickness = rs.thickness },
                            };
                        }
                    }
                    run_end += sr.len;
                    color = sr.color;
                } else {
                    run_end = layout.len;
                    finished_underline = current_underline;
                    current_underline = null;
                    finished_strikethrough = current_strikethrough;
                    current_strikethrough = null;
                }
            }

            if (finished_underline) |fu| {
                var o = fu.origin;
                if (o.x == glyph_origin.x) o.x -= max_glyph_size.width / 2.0;
                args.underline.func(args.underline.ctx, fu.range, o, glyph_origin.x - o.x, &fu.style, window);
            }
            if (finished_strikethrough) |fs| {
                var o = fs.origin;
                if (o.x == glyph_origin.x) o.x -= max_glyph_size.width / 2.0;
                window.paint_strikethrough(o, glyph_origin.x - o.x, &fs.style);
            }

            const max_glyph_bounds: Bounds(Pixels) = .{ .origin = glyph_origin, .size = max_glyph_size };
            if (max_glyph_bounds.intersects(window.content_mask().bounds)) {
                const vertical: Point(Pixels) = .{ .x = 0, .y = glyph.position.y };
                const at: Point(Pixels) = glyph_origin.add(baseline_offset).add(vertical);
                if (glyph.is_emoji) {
                    try window.paint_emoji(at, run.font_id, glyph.id, layout.font_size);
                } else {
                    try window.paint_glyph(at, run.font_id, glyph.id, layout.font_size, color);
                }
            }
        }
    }

    var last_line_end_x = first_glyph_x + layout.width;
    if (args.wrap_boundaries.len > 0) {
        const b = args.wrap_boundaries[args.wrap_boundaries.len - 1];
        last_line_end_x -= layout.runs[b.run_ix].glyphs[b.glyph_ix].position.x;
    }
    if (current_underline) |cu| {
        var o = cu.origin;
        if (last_line_end_x == o.x) o.x -= max_glyph_size.width / 2.0;
        args.underline.func(args.underline.ctx, cu.range, o, last_line_end_x - o.x, &cu.style, window);
    }
    if (current_strikethrough) |cs| {
        var o = cs.origin;
        if (last_line_end_x == o.x) o.x -= max_glyph_size.width / 2.0;
        window.paint_strikethrough(o, last_line_end_x - o.x, &cs.style);
    }
}

/// Background pass (GPUI `paint_line_background`): one quad per run of equal background.
fn paint_backgrounds(args: *PaintArgs, window: *Window, cx: *App) void {
    const origin = args.origin;
    const layout = args.layout;
    const line_height = args.line_height;
    const text_sys = cx.text_system();

    var decorations: DecorationIter = .{ .runs = args.decoration_runs };
    var wraps: WrapIter = .{ .boundaries = args.wrap_boundaries };
    var run_end: usize = 0;
    var current_background: ?BackgroundRun = null;

    const width_for_align = args.align_width orelse layout.width;
    var glyph_origin: Point(Pixels) = .{
        .x = aligned_origin_x(origin, width_for_align, 0, args.text_align, layout, wraps.peek()),
        .y = origin.y,
    };
    var prev_glyph_position: Point(Pixels) = .{ .x = 0, .y = 0 };
    var max_glyph_size: Size(Pixels) = .{ .width = 0, .height = 0 };

    for (layout.runs, 0..) |run, run_ix| {
        max_glyph_size = text_sys.bounding_box(run.font_id, layout.font_size).size;

        for (run.glyphs, 0..) |glyph, glyph_ix| {
            glyph_origin.x += glyph.position.x - prev_glyph_position.x;

            if (wraps.take_if(run_ix, glyph_ix)) {
                if (current_background) |*cb| {
                    if (glyph_origin.x == cb.origin.x) cb.origin.x -= max_glyph_size.width / 2.0;
                    window.paint_quad(window_mod.fill(.{
                        .origin = cb.origin,
                        .size = .{ .width = glyph_origin.x - cb.origin.x, .height = line_height },
                    }, cb.color));
                    if (glyph.index < run_end) {
                        cb.origin.x = origin.x;
                        cb.origin.y += line_height;
                    } else {
                        current_background = null;
                    }
                }
                glyph_origin.x = aligned_origin_x(origin, width_for_align, glyph.position.x, args.text_align, layout, wraps.peek());
                glyph_origin.y += line_height;
            }
            prev_glyph_position = glyph.position;

            var finished_background: ?BackgroundRun = null;
            if (glyph.index >= run_end) {
                var style_run = decorations.next();
                while (style_run) |sr| {
                    if (glyph.index < run_end + sr.len) break;
                    run_end += sr.len;
                    style_run = decorations.next();
                }

                if (style_run) |sr| {
                    if (current_background) |cb| {
                        if (!optional_color_eql(sr.background_color, cb.color)) {
                            finished_background = current_background;
                            current_background = null;
                        }
                    }
                    if (sr.background_color) |bg| {
                        if (current_background == null) current_background = .{ .origin = .{ .x = glyph_origin.x, .y = glyph_origin.y }, .color = bg };
                    }
                    run_end += sr.len;
                } else {
                    run_end = layout.len;
                    finished_background = current_background;
                    current_background = null;
                }
            }

            if (finished_background) |fb| {
                const w = glyph_origin.x - fb.origin.x;
                var o = fb.origin;
                if (o.x == glyph_origin.x) o.x -= max_glyph_size.width / 2.0;
                window.paint_quad(window_mod.fill(.{ .origin = o, .size = .{ .width = w, .height = line_height } }, fb.color));
            }
        }
    }

    var last_line_end_x = origin.x + layout.width;
    if (args.wrap_boundaries.len > 0) {
        const b = args.wrap_boundaries[args.wrap_boundaries.len - 1];
        last_line_end_x -= layout.runs[b.run_ix].glyphs[b.glyph_ix].position.x;
    }
    if (current_background) |cb| {
        var o = cb.origin;
        if (last_line_end_x == o.x) o.x -= max_glyph_size.width / 2.0;
        window.paint_quad(window_mod.fill(.{ .origin = o, .size = .{ .width = last_line_end_x - o.x, .height = line_height } }, cb.color));
    }
}

fn optional_color_eql(a: ?Hsla, b: Hsla) bool {
    return if (a) |c| std.meta.eql(c, b) else false;
}

/// The area the line paints into: the union of its rows, offset by alignment.
fn line_paint_bounds(
    origin: Point(Pixels),
    layout: *const LineLayout,
    line_height: Pixels,
    text_align: TextAlign,
    align_width: ?Pixels,
    wrap_boundaries: []const WrapBoundary,
) Bounds(Pixels) {
    var b: Bounds(Pixels) = .{
        .origin = origin,
        .size = .{ .width = layout.width, .height = line_height * @as(f32, @floatFromInt(wrap_boundaries.len + 1)) },
    };
    if (text_align == .left or layout.len == 0) return b;

    const width = align_width orelse layout.width;
    var row_start: Pixels = 0;
    var row: usize = 0;
    while (row <= wrap_boundaries.len) : (row += 1) {
        const row_end: Pixels = if (row < wrap_boundaries.len) blk: {
            const wb = wrap_boundaries[row];
            break :blk layout.runs[wb.run_ix].glyphs[wb.glyph_ix].position.x;
        } else layout.width;
        const row_width = row_end - row_start;
        const offset: Pixels = switch (text_align) {
            .left => 0,
            .center => (width - row_width) / 2.0,
            .right => width - row_width,
        };
        b = union_bounds(b, .{
            .origin = .{ .x = origin.x + offset, .y = origin.y + line_height * @as(f32, @floatFromInt(row)) },
            .size = .{ .width = row_width, .height = line_height },
        });
        row_start = row_end;
    }
    return b;
}

fn union_bounds(a: Bounds(Pixels), b: Bounds(Pixels)) Bounds(Pixels) {
    const min_x = @min(a.origin.x, b.origin.x);
    const min_y = @min(a.origin.y, b.origin.y);
    const max_x = @max(a.origin.x + a.size.width, b.origin.x + b.size.width);
    const max_y = @max(a.origin.y + a.size.height, b.origin.y + b.size.height);
    return .{ .origin = .{ .x = min_x, .y = min_y }, .size = .{ .width = max_x - min_x, .height = max_y - min_y } };
}

/// The x where a row starts, given its alignment (GPUI `aligned_origin_x`).
fn aligned_origin_x(
    origin: Point(Pixels),
    align_width: Pixels,
    last_glyph_x: Pixels,
    text_align: TextAlign,
    layout: *const LineLayout,
    wrap_boundary: ?WrapBoundary,
) Pixels {
    const end_of_line: Pixels = if (wrap_boundary) |b| layout.runs[b.run_ix].glyphs[b.glyph_ix].position.x else layout.width;
    const line_width = end_of_line - last_glyph_x;
    return switch (text_align) {
        .left => origin.x,
        .center => (origin.x * 2.0 + align_width - line_width) / 2.0,
        .right => origin.x + align_width - line_width,
    };
}

// ---------------------------------------------------------------------------
// Tests: the alignment and bounds math, which needs no font.

const testing = std.testing;

test "aligned origin for left, center and right" {
    var glyphs = [_]line_layout.ShapedGlyph{.{ .id = 0, .position = .{ .x = 0, .y = 0 }, .index = 0, .is_emoji = false }};
    var runs = [_]ShapedRun{.{ .font_id = 0, .glyphs = &glyphs }};
    const layout: LineLayout = .{ .width = 40, .runs = &runs, .len = 1 };
    const origin: Point(Pixels) = .{ .x = 10, .y = 0 };
    try testing.expectEqual(@as(f32, 10), aligned_origin_x(origin, 100, 0, .left, &layout, null));
    try testing.expectEqual(@as(f32, 40), aligned_origin_x(origin, 100, 0, .center, &layout, null));
    try testing.expectEqual(@as(f32, 70), aligned_origin_x(origin, 100, 0, .right, &layout, null));
}

test "line paint bounds for a single left-aligned row" {
    const layout: LineLayout = .{ .width = 40, .runs = &.{}, .len = 3 };
    const b = line_paint_bounds(.{ .x = 5, .y = 7 }, &layout, 20, .left, 100, &.{});
    try testing.expectEqual(@as(f32, 5), b.origin.x);
    try testing.expectEqual(@as(f32, 40), b.size.width);
    try testing.expectEqual(@as(f32, 20), b.size.height);
}

test "union of bounds covers both rectangles" {
    const a: Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 10 } };
    const b: Bounds(Pixels) = .{ .origin = .{ .x = 5, .y = 5 }, .size = .{ .width = 20, .height = 10 } };
    const u = union_bounds(a, b);
    try testing.expectEqual(@as(f32, 25), u.size.width);
    try testing.expectEqual(@as(f32, 15), u.size.height);
}

const FontId = text_system.FontId;

/// A line of one font-0 run whose glyphs have id = byte index, at the given `(index, x)` pairs.
/// Free it with `free_test_line`. Splitting allocates in the frame arena, which tests do not free.
fn make_test_line(text: []const u8, glyphs: []const struct { usize, f32 }, width: f32, decorations: []const DecorationRun) !ShapedLine {
    const shaped = try testing.allocator.alloc(line_layout.ShapedGlyph, glyphs.len);
    for (glyphs, shaped) |g, *out| out.* = .{ .id = @intCast(g[0]), .position = .{ .x = g[1], .y = 0 }, .index = g[0], .is_emoji = false };
    const runs = try testing.allocator.alloc(ShapedRun, 1);
    runs[0] = .{ .font_id = 0, .glyphs = shaped };
    const layout = try testing.allocator.create(LineLayout);
    layout.* = .{ .font_size = 16, .width = width, .ascent = 12, .descent = 4, .runs = runs, .len = text.len };
    return .{ .layout = layout, .text = text, .decoration_runs = try testing.allocator.dupe(DecorationRun, decorations) };
}

fn free_test_line(line: ShapedLine) void {
    for (line.layout.runs) |run| testing.allocator.free(run.glyphs);
    testing.allocator.free(line.layout.runs);
    testing.allocator.destroy(@constCast(line.layout));
    testing.allocator.free(@constCast(line.decoration_runs));
}

fn test_color(h: f32) Hsla {
    return .{ .h = h, .s = 1.0, .l = 0.5, .a = 1.0 };
}

test "aligned line paint bounds for every alignment, wrap and align width" {
    const line = try make_test_line("abcd", &.{ .{ 0, 0 }, .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 } }, 40, &.{});
    defer free_test_line(line);
    const origin: Point(Pixels) = .{ .x = 10, .y = 20 };
    const line_height: Pixels = 16;
    const cases = [_]struct { wrapped: bool, align_width: ?f32, edges: [3][2]f32 }{
        .{ .wrapped = false, .align_width = null, .edges = .{ .{ 10, 50 }, .{ 10, 50 }, .{ 10, 50 } } },
        .{ .wrapped = true, .align_width = null, .edges = .{ .{ 10, 50 }, .{ 10, 50 }, .{ 10, 50 } } },
        .{ .wrapped = false, .align_width = 40, .edges = .{ .{ 10, 50 }, .{ 10, 50 }, .{ 10, 50 } } },
        .{ .wrapped = true, .align_width = 40, .edges = .{ .{ 10, 50 }, .{ 10, 50 }, .{ 10, 50 } } },
        .{ .wrapped = false, .align_width = 100, .edges = .{ .{ 10, 50 }, .{ 10, 80 }, .{ 10, 110 } } },
        .{ .wrapped = true, .align_width = 100, .edges = .{ .{ 10, 50 }, .{ 10, 70 }, .{ 10, 110 } } },
        .{ .wrapped = false, .align_width = 10, .edges = .{ .{ 10, 50 }, .{ -5, 50 }, .{ -20, 50 } } },
        .{ .wrapped = true, .align_width = 10, .edges = .{ .{ 10, 50 }, .{ 5, 50 }, .{ 0, 50 } } },
        .{ .wrapped = false, .align_width = 0, .edges = .{ .{ 10, 50 }, .{ -10, 50 }, .{ -30, 50 } } },
        .{ .wrapped = true, .align_width = 0, .edges = .{ .{ 10, 50 }, .{ 0, 50 }, .{ -10, 50 } } },
    };
    const aligns = [_]TextAlign{ .left, .center, .right };
    for (cases) |c| {
        const boundaries: []const WrapBoundary = if (c.wrapped) &.{.{ .run_ix = 0, .glyph_ix = 2 }} else &.{};
        for (aligns, c.edges) |align_value, edge| {
            const b = line_paint_bounds(origin, line.layout, line_height, align_value, c.align_width, boundaries);
            try testing.expectApproxEqAbs(edge[0], b.origin.x, 0.0001);
            try testing.expectApproxEqAbs(edge[1] - edge[0], b.size.width, 0.0001);
            try testing.expectApproxEqAbs(@as(f32, if (c.wrapped) 32 else 16), b.size.height, 0.0001);
        }
    }

    const empty = try make_test_line("", &.{}, 0, &.{});
    defer free_test_line(empty);
    for (aligns) |align_value| {
        const b = line_paint_bounds(origin, empty.layout, line_height, align_value, 100, &.{});
        try testing.expectEqual(origin, b.origin);
        try testing.expectEqual(@as(f32, 0), b.size.width);
        try testing.expectEqual(line_height, b.size.height);
    }
}

test "split_at keeps every glyph and rebases the suffix at every boundary" {
    const line = try make_test_line("abcdef", &.{ .{ 0, 0 }, .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 }, .{ 5, 50 } }, 60, &.{});
    defer free_test_line(line);
    for (0..7) |i| {
        const left, const right = try line.split_at(i);
        try testing.expectApproxEqAbs(line.width(), left.width() + right.width(), 0.0001);
        try testing.expectEqual(line.len(), left.len() + right.len());
        const joined = try std.mem.concat(testing.allocator, u8, &.{ left.text, right.text });
        defer testing.allocator.free(joined);
        try testing.expectEqualStrings("abcdef", joined);
        try testing.expectEqual(line.layout.font_size, left.layout.font_size);
        try testing.expectEqual(line.layout.ascent, right.layout.ascent);
        try testing.expectEqual(line.layout.descent, right.layout.descent);
        try testing.expectEqual(@as(usize, 6), count_glyphs(left) + count_glyphs(right));
    }

    // Split at 0 puts every glyph on the right, and the end puts them all on the left.
    const at_start = try line.split_at(0);
    try testing.expectEqual(@as(usize, 0), at_start[0].layout.runs.len);
    try testing.expectEqual(@as(usize, 6), at_start[1].layout.runs[0].glyphs.len);
    const at_end = try line.split_at(6);
    try testing.expectEqual(@as(usize, 6), at_end[0].layout.runs[0].glyphs.len);
    try testing.expectEqual(@as(usize, 0), at_end[1].layout.runs.len);
}

fn count_glyphs(line: ShapedLine) usize {
    var n: usize = 0;
    for (line.layout.runs) |run| n += run.glyphs.len;
    return n;
}

test "split_at rebases glyphs across font runs and keeps the text pieces" {
    // Run A (font 0) holds bytes 0..3, run B (font 1) holds bytes 3..6.
    const a = try testing.allocator.alloc(line_layout.ShapedGlyph, 3);
    const b = try testing.allocator.alloc(line_layout.ShapedGlyph, 3);
    for (a, 0..) |*g, i| g.* = .{ .id = 0, .position = .{ .x = @as(f32, @floatFromInt(i)) * 10, .y = 0 }, .index = i, .is_emoji = false };
    for (b, 0..) |*g, i| g.* = .{ .id = 0, .position = .{ .x = 30 + @as(f32, @floatFromInt(i)) * 10, .y = 0 }, .index = i + 3, .is_emoji = false };
    const runs = try testing.allocator.alloc(ShapedRun, 2);
    runs[0] = .{ .font_id = 0, .glyphs = a };
    runs[1] = .{ .font_id = 1, .glyphs = b };
    const layout = try testing.allocator.create(LineLayout);
    layout.* = .{ .font_size = 16, .width = 60, .ascent = 12, .descent = 4, .runs = runs, .len = 6 };
    const line: ShapedLine = .{ .layout = layout, .text = "abcdef" };
    defer {
        for (line.layout.runs) |run| testing.allocator.free(run.glyphs);
        testing.allocator.free(line.layout.runs);
        testing.allocator.destroy(@constCast(line.layout));
    }

    const first, const remainder = try line.split_at(2);
    try testing.expectEqualStrings("ab", first.text);
    try testing.expectEqual(@as(usize, 1), first.layout.runs.len);
    try testing.expectEqual(@as(FontId, 0), first.layout.runs[0].font_id);

    // The remainder "cdef" has the tail of run A (one glyph) and all of run B.
    try testing.expectEqualStrings("cdef", remainder.text);
    try testing.expectEqual(@as(usize, 2), remainder.layout.runs.len);
    try testing.expectEqual(@as(FontId, 0), remainder.layout.runs[0].font_id);
    try testing.expectEqual(@as(usize, 1), remainder.layout.runs[0].glyphs.len);
    try testing.expectEqual(@as(usize, 0), remainder.layout.runs[0].glyphs[0].index);
    try testing.expectEqual(@as(f32, 0), remainder.layout.runs[0].glyphs[0].position.x);
    try testing.expectEqual(@as(FontId, 1), remainder.layout.runs[1].font_id);
    try testing.expectEqual(@as(usize, 1), remainder.layout.runs[1].glyphs[0].index);
    try testing.expectEqual(@as(f32, 10), remainder.layout.runs[1].glyphs[0].position.x);

    // A second split crosses the run boundary inside the remainder.
    const second, const last = try remainder.split_at(2);
    try testing.expectEqualStrings("cd", second.text);
    try testing.expectEqualStrings("ef", last.text);
    try testing.expectEqual(@as(usize, 0), last.layout.runs[0].glyphs[0].index);
    try testing.expectEqual(@as(f32, 0), last.layout.runs[0].glyphs[0].position.x);
    try testing.expectApproxEqAbs(line.width(), first.width() + second.width() + last.width(), 0.0001);
}

test "split_at partitions decoration runs and splits one that straddles the boundary" {
    const red = test_color(0.0);
    const green = test_color(0.3);
    const blue = test_color(0.6);
    const line = try make_test_line("abcdef", &.{ .{ 0, 0 }, .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 }, .{ 5, 50 } }, 60, &.{
        .{ .len = 2, .color = red },
        .{ .len = 3, .color = green },
        .{ .len = 1, .color = blue },
    });
    defer free_test_line(line);

    // Split at 3: red goes left, green is cut in two, blue goes right.
    const left, const right = try line.split_at(3);
    try testing.expectEqual(@as(usize, 2), left.decoration_runs.len);
    try testing.expectEqual(@as(u32, 2), left.decoration_runs[0].len);
    try testing.expectEqual(red, left.decoration_runs[0].color);
    try testing.expectEqual(@as(u32, 1), left.decoration_runs[1].len);
    try testing.expectEqual(green, left.decoration_runs[1].color);
    try testing.expectEqual(@as(usize, 2), right.decoration_runs.len);
    try testing.expectEqual(@as(u32, 2), right.decoration_runs[0].len);
    try testing.expectEqual(green, right.decoration_runs[0].color);
    try testing.expectEqual(@as(u32, 1), right.decoration_runs[1].len);
    try testing.expectEqual(blue, right.decoration_runs[1].color);
}

test "with_len changes only the length the line reports" {
    const line = try make_test_line("ab", &.{ .{ 0, 0 }, .{ 1, 10 } }, 20, &.{});
    defer free_test_line(line);
    const short = try line.with_len(1);
    try testing.expectEqual(@as(usize, 1), short.len());
    try testing.expectEqual(line.width(), short.width());
    try testing.expectEqual(@as(usize, 2), line.len());
    try testing.expectEqualStrings("ab", short.text);
}

test "cursor keeps shaping metadata and glyph positions across runs" {
    // "a😀bcdef": run 0 (font 3) holds 'a', the emoji and a second glyph for 'b'; run 1 (font 8) holds 'c' and 'd'.
    const a = try testing.allocator.dupe(line_layout.ShapedGlyph, &.{
        .{ .id = 11, .position = .{ .x = 0, .y = 1 }, .index = 0, .is_emoji = true },
        .{ .id = 12, .position = .{ .x = 17, .y = 1 }, .index = 1, .is_emoji = false },
        .{ .id = 13, .position = .{ .x = 19, .y = -1 }, .index = 1, .is_emoji = false },
    });
    const b = try testing.allocator.dupe(line_layout.ShapedGlyph, &.{
        .{ .id = 21, .position = .{ .x = 25, .y = 1 }, .index = 5, .is_emoji = true },
        .{ .id = 22, .position = .{ .x = 41, .y = 1 }, .index = 7, .is_emoji = false },
    });
    const runs = try testing.allocator.alloc(ShapedRun, 2);
    runs[0] = .{ .font_id = 3, .glyphs = a };
    runs[1] = .{ .font_id = 8, .glyphs = b };
    const layout = try testing.allocator.create(LineLayout);
    layout.* = .{ .font_size = 16, .width = 50, .ascent = 12, .descent = 4, .runs = runs, .len = 10 };
    const line: ShapedLine = .{ .layout = layout, .text = "a😀bcdef" };
    defer {
        for (line.layout.runs) |run| testing.allocator.free(run.glyphs);
        testing.allocator.free(line.layout.runs);
        testing.allocator.destroy(@constCast(line.layout));
    }

    var cursor = line.cursor();
    const first = try cursor.take_until(5);
    try testing.expectEqualStrings("a😀", first.text);
    try testing.expectEqual(@as(FontId, 3), first.layout.runs[0].font_id);
    try testing.expectEqual(@as(u32, 11), first.layout.runs[0].glyphs[0].id);
    try testing.expect(first.layout.runs[0].glyphs[0].is_emoji);
    try testing.expectEqual(@as(usize, 1), first.layout.runs[0].glyphs[1].index);
    try testing.expectEqual(Point(Pixels){ .x = 17, .y = 1 }, first.layout.runs[0].glyphs[1].position);
    try testing.expectEqual(@as(usize, 3), first.layout.runs[0].glyphs.len);
    try testing.expectEqual(@as(usize, 1), first.layout.runs[0].glyphs[2].index);
    try testing.expectEqual(Point(Pixels){ .x = 19, .y = -1 }, first.layout.runs[0].glyphs[2].position);
    try testing.expectEqual(@as(f32, 25), cursor.x_offset());

    const second = try cursor.take_until(7);
    try testing.expectEqualStrings("bc", second.text);
    try testing.expectEqual(@as(FontId, 8), second.layout.runs[0].font_id);
    try testing.expectEqual(@as(u32, 21), second.layout.runs[0].glyphs[0].id);
    try testing.expectEqual(@as(usize, 0), second.layout.runs[0].glyphs[0].index);
    try testing.expectEqual(Point(Pixels){ .x = 0, .y = 1 }, second.layout.runs[0].glyphs[0].position);
    try testing.expectEqual(@as(f32, 41), cursor.x_offset());

    const final = try cursor.take_until(10);
    try testing.expectEqualStrings("def", final.text);
    try testing.expectEqual(@as(u32, 22), final.layout.runs[0].glyphs[0].id);
    try testing.expectEqual(@as(usize, 0), final.layout.runs[0].glyphs[0].index);
    try testing.expectEqual(Point(Pixels){ .x = 0, .y = 1 }, final.layout.runs[0].glyphs[0].position);
}

test "cursor matches split_at for visually reordered glyphs" {
    // Bidirectional text puts byte 2 before byte 1, so the cursor takes the split_at fallback.
    const line = try make_test_line("abc", &.{ .{ 0, 0 }, .{ 2, 10 }, .{ 1, 20 } }, 30, &.{});
    defer free_test_line(line);
    var cursor = line.cursor();
    var remainder = line;
    var previous: usize = 0;
    for ([_]usize{ 0, 1, 2, 3 }) |boundary| {
        const expected, const rest = try remainder.split_at(boundary - previous);
        const actual = try cursor.take_until(boundary);
        try testing.expectEqualStrings(expected.text, actual.text);
        try testing.expectEqual(expected.width(), actual.width());
        try testing.expectEqual(expected.layout.runs.len, actual.layout.runs.len);
        for (actual.layout.runs, expected.layout.runs) |ar, er| {
            try testing.expectEqual(er.glyphs.len, ar.glyphs.len);
            for (ar.glyphs, er.glyphs) |ag, eg| {
                try testing.expectEqual(eg.id, ag.id);
                try testing.expectEqual(eg.index, ag.index);
                try testing.expectEqual(eg.position, ag.position);
            }
        }
        try testing.expectEqual(line.x_for_index(boundary), cursor.x_offset());
        remainder = rest;
        previous = boundary;
    }
}

test "cursor partitions one decoration across three chunks" {
    const line = try make_test_line("abcdef", &.{ .{ 0, 0 }, .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 }, .{ 5, 50 } }, 60, &.{
        .{ .len = 6, .color = test_color(0.2) },
    });
    defer free_test_line(line);
    var cursor = line.cursor();
    try testing.expectEqual(@as(u32, 2), (try cursor.take_until(2)).decoration_runs[0].len);
    try testing.expectEqual(@as(u32, 2), (try cursor.take_until(4)).decoration_runs[0].len);
    try testing.expectEqual(@as(u32, 2), (try cursor.take_until(6)).decoration_runs[0].len);
}

test "cursor matches successive split_at calls at every pair of boundaries" {
    const decorations = [_]DecorationRun{
        .{ .len = 2, .color = test_color(0.2), .background_color = null },
        .{ .len = 0, .color = test_color(0.0), .background_color = null },
        .{ .len = 3, .color = test_color(0.3), .background_color = null },
        .{ .len = 1, .color = test_color(0.4), .background_color = null },
    };
    const line = try make_test_line("abcdef", &.{ .{ 0, 5 }, .{ 0, 5 }, .{ 2, 15 }, .{ 4, 25 }, .{ 5, 35 } }, 45, &decorations);
    defer free_test_line(line);
    for (0..7) |first| for (first..7) |second| {
        var cursor = line.cursor();
        var remainder = line;
        var previous: usize = 0;
        var total: f32 = 0;
        var text_len: usize = 0;
        for ([_]usize{ first, second, 6, 6 }) |boundary| {
            const expected, const rest = try remainder.split_at(boundary - previous);
            const actual = try cursor.take_until(boundary);
            try testing.expectEqualStrings(expected.text, actual.text);
            try testing.expectEqual(expected.len(), actual.len());
            try testing.expectEqual(expected.width(), actual.width());
            try testing.expectEqual(count_glyphs(expected), count_glyphs(actual));
            try testing.expectEqual(expected.decoration_runs.len, actual.decoration_runs.len);
            for (actual.decoration_runs, expected.decoration_runs) |ad, ed| {
                try testing.expectEqual(ed.len, ad.len);
                try testing.expectEqual(ed.color, ad.color);
            }
            total += actual.width();
            text_len += actual.text.len;
            remainder = rest;
            previous = boundary;
        }
        try testing.expectApproxEqAbs(line.width(), total, 0.0001);
        try testing.expectEqual(line.text.len, text_len);
    };
}

test "cursor takes empty chunks and repeated boundaries" {
    const line = try make_test_line("ab", &.{ .{ 0, 5 }, .{ 1, 15 } }, 20, &.{});
    defer free_test_line(line);
    var cursor = line.cursor();
    try testing.expectEqualStrings("", (try cursor.take_until(0)).text);
    try testing.expectEqualStrings("", (try cursor.take_until(0)).text);
    try testing.expectEqualStrings("a", (try cursor.take_until(1)).text);
    try testing.expectEqualStrings("b", (try cursor.take_until(2)).text);
    try testing.expectEqualStrings("", (try cursor.take_until(2)).text);

    const empty = try make_test_line("", &.{}, 0, &.{});
    defer free_test_line(empty);
    var empty_cursor = empty.cursor();
    const piece = try empty_cursor.take_until(0);
    try testing.expect(piece.text.len == 0);
    try testing.expectEqual(@as(usize, 0), piece.layout.runs.len);
    try testing.expectEqual(@as(f32, 0), piece.width());
}
