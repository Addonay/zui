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

    /// Paints the line's glyphs and decorations at `origin`.
    pub fn paint(self: ShapedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, align_width: ?Pixels, window: *Window, cx: *App) !void {
        try paint_line(origin, self.layout, line_height, text_align, align_width, self.decoration_runs, &.{}, window, cx);
    }

    /// Paints the line's background colors at `origin`.
    pub fn paint_background(self: ShapedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, align_width: ?Pixels, window: *Window, cx: *App) !void {
        try paint_line_background(origin, self.layout, line_height, text_align, align_width, self.decoration_runs, &.{}, window, cx);
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
        return self.layout.wrap_boundaries.len + 1;
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

    /// Paints the line at `origin`. `align_width` defaults to the wrap width.
    pub fn paint(self: WrappedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, align_width: ?Pixels, window: *Window, cx: *App) !void {
        const width = align_width orelse self.layout.wrap_width;
        try paint_line(origin, self.layout.unwrapped_layout, line_height, text_align, width, self.decoration_runs, self.layout.wrap_boundaries, window, cx);
    }

    /// Paints the background colors of the line at `origin`.
    pub fn paint_background(self: WrappedLine, origin: Point(Pixels), line_height: Pixels, text_align: TextAlign, align_width: ?Pixels, window: *Window, cx: *App) !void {
        const width = align_width orelse self.layout.wrap_width;
        try paint_line_background(origin, self.layout.unwrapped_layout, line_height, text_align, width, self.decoration_runs, self.layout.wrap_boundaries, window, cx);
    }
};

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
    err: ?anyerror = null,
};

const UnderlineRun = struct { origin: Point(Pixels), style: UnderlineStyle };
const StrikethroughRun = struct { origin: Point(Pixels), style: StrikethroughStyle };

fn paint_line(
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
                    window.paint_underline(.{ .x = cu.origin.x, .y = cu.origin.y }, glyph_origin.x - cu.origin.x, &cu.style);
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
                    if (current_underline) |cu| {
                        const stored: ?UnderlineStyle = cu.style;
                        if (!std.meta.eql(sr.underline, stored)) {
                            finished_underline = current_underline;
                            current_underline = null;
                        }
                    }
                    if (sr.underline) |ru| {
                        if (current_underline == null) {
                            current_underline = .{
                                .origin = .{ .x = glyph_origin.x, .y = glyph_origin.y + underline_y },
                                .style = .{ .color = ru.color orelse sr.color, .thickness = ru.thickness, .wavy = ru.wavy },
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
                window.paint_underline(o, glyph_origin.x - o.x, &fu.style);
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
        window.paint_underline(o, last_line_end_x - o.x, &cu.style);
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
    var current_background: ?struct { origin: Point(Pixels), color: Hsla } = null;

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

            var finished_background: ?struct { origin: Point(Pixels), color: Hsla } = null;
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
