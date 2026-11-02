//! Port of GPUI `elements/text.rs`: text elements, `StyledText` (runs and highlights),
//! `TextLayout` (measurement, painting and position lookups) and `InteractiveText`.
//!
//! Elements allocate their state in the frame arena. `TextLayout` keeps its measured
//! lines in that arena too, so a layout is only valid for the frame it was measured in.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const taffy = @import("../taffy.zig");
const element = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const interactive = @import("../interactive.zig");
const text_system = @import("../text_system.zig");
const line_wrapper = @import("../text_system/line_wrapper.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const LayoutId = taffy.LayoutId;
const TextStyle = style.TextStyle;
const TextRun = style.TextRun;
const HighlightStyle = style.HighlightStyle;
const WrappedLine = text_system.WrappedLine;
const WrappedLineLayout = text_system.WrappedLineLayout;
const IndexResult = text_system.IndexResult;
const Window = window_mod.Window;
const App = app_mod.App;
const Hitbox = window_mod.Hitbox;
const TextAlign = style.TextAlign;

/// A byte range of a string (GPUI `Range<usize>`).
pub const ByteRange = struct {
    start: usize,
    end: usize,

    pub fn contains(self: ByteRange, index: usize) bool {
        return index >= self.start and index < self.end;
    }
};

// ---------------------------------------------------------------------------
// Plain text elements.

/// A string rendered as text, with the inherited text style (GPUI `impl Element for SharedString`).
pub const TextElement = struct {
    text: []const u8,

    pub const RequestLayoutState = TextLayout;
    pub const PrepaintState = void;

    pub fn id(self: *TextElement) ?element.ElementId {
        _ = self;
        return null;
    }

    pub fn request_layout(self: *TextElement, id_: ?*const element.GlobalElementId, window: *Window, cx: *App) struct { LayoutId, TextLayout } {
        _ = id_;
        const state = TextLayout.new();
        const layout_id = state.layout(self.text, null, window, cx);
        return .{ layout_id, state };
    }

    pub fn prepaint(self: *TextElement, id_: ?*const element.GlobalElementId, bounds: Bounds(Pixels), rl: *TextLayout, window: *Window, cx: *App) void {
        _ = id_;
        _ = window;
        _ = cx;
        _ = self;
        rl.prepaint(bounds);
    }

    pub fn paint(self: *TextElement, id_: ?*const element.GlobalElementId, bounds: Bounds(Pixels), rl: *TextLayout, pp: *void, window: *Window, cx: *App) void {
        _ = id_;
        _ = bounds;
        _ = pp;
        rl.paint(self.text, window, cx);
    }
};

/// Wraps `s` as an element (GPUI `IntoElement for SharedString`).
pub fn text_element(s: []const u8) element.AnyElement {
    const e = window_mod.frame_arena().create(TextElement) catch @panic("OOM");
    e.* = .{ .text = s };
    return element.AnyElement.new(e);
}

// ---------------------------------------------------------------------------
// TextLayout.

/// Measured text: the lines, their size, and where the element was painted.
/// A `TextLayout` is a handle to frame-arena state, so copies share it (GPUI `Rc<RefCell<..>>`).
pub const TextLayout = struct {
    state: *State,

    pub const State = struct {
        measured: bool = false,
        len: usize = 0,
        lines: []const WrappedLine = &.{},
        line_height: Pixels = 0,
        wrap_width: ?Pixels = null,
        truncate_width: ?Pixels = null,
        size: ?Size(Pixels) = null,
        bounds: ?Bounds(Pixels) = null,
    };

    /// A new, unmeasured layout in the frame arena.
    pub fn new() TextLayout {
        const state = window_mod.frame_arena().create(State) catch @panic("OOM");
        state.* = .{};
        return .{ .state = state };
    }

    /// Requests a measured layout node for `text` with optional `runs`, measured with the inherited text style.
    pub fn layout(self: TextLayout, source: []const u8, runs: ?[]const TextRun, window: *Window, cx: *App) LayoutId {
        _ = cx;
        const text_style = window.text_style();
        const font_size = text_style.font_size.to_pixels(window.rem_size());
        const lh = text_style.line_height_in_pixels(window.rem_size());

        const used_runs: []const TextRun = runs orelse blk: {
            const single = window_mod.frame_arena().alloc(TextRun, 1) catch @panic("OOM");
            single[0] = text_style.to_run(source.len);
            break :blk single;
        };

        const measure = window_mod.frame_arena().create(MeasureCtx) catch @panic("OOM");
        measure.* = .{
            .state = self.state,
            .text = source,
            .runs = used_runs,
            .text_style = text_style,
            .font_size = font_size,
            .line_height = lh,
        };
        var node_style: style.Style = .{};
        return window.request_measured_layout(&node_style, .{ .ctx = measure, .func = MeasureCtx.measure });
    }

    /// Records the bounds the text was given (GPUI `prepaint`).
    pub fn prepaint(self: TextLayout, bounds: Bounds(Pixels)) void {
        self.state.bounds = bounds;
    }

    /// Paints backgrounds and glyphs.
    pub fn paint(self: TextLayout, source: []const u8, window: *Window, cx: *App) void {
        _ = source;
        self.paint_lines(.all, window, cx);
    }

    /// Paints only the backgrounds of the runs, so highlights can go between backgrounds and glyphs.
    pub fn paint_background(self: TextLayout, window: *Window, cx: *App) void {
        self.paint_lines(.background, window, cx);
    }

    /// Paints only the glyphs and decorations of the runs.
    pub fn paint_foreground(self: TextLayout, window: *Window, cx: *App) void {
        self.paint_lines(.foreground, window, cx);
    }

    const Pass = enum { all, background, foreground };

    fn paint_lines(self: TextLayout, pass: Pass, window: *Window, cx: *App) void {
        const st = self.state;
        const bounds = st.bounds orelse return;
        const lh = st.line_height;
        var line_origin = bounds.origin;
        const text_align = window.text_style().text_align;
        for (st.lines) |line| {
            if (pass != .foreground) {
                line.paint_background(line_origin, lh, text_align, bounds.size.width, window, cx) catch {};
            }
            if (pass != .background) {
                line.paint(line_origin, lh, text_align, bounds.size.width, window, cx) catch {};
            }
            line_origin.y += line.size(lh).height;
        }
    }

    /// The byte index of the character at `position` (relative to the window), or the nearest one.
    pub fn index_for_position(self: TextLayout, position: Point(Pixels)) IndexResult {
        const st = self.state;
        const bounds = st.bounds orelse return .{ .err = 0 };
        if (position.y < bounds.origin.y) return .{ .err = 0 };

        const lh = st.line_height;
        var line_origin = bounds.origin;
        var line_start_ix: usize = 0;
        for (st.lines) |line| {
            const line_bottom = line_origin.y + line.size(lh).height;
            if (position.y > line_bottom) {
                line_origin.y = line_bottom;
                line_start_ix += line.len() + 1;
            } else {
                const within = position.sub(line_origin);
                return switch (line.index_for_position(within, lh)) {
                    .ok => |i| .{ .ok = line_start_ix + i },
                    .err => |i| .{ .err = line_start_ix + i },
                };
            }
        }
        return .{ .err = line_start_ix -| 1 };
    }

    /// The window position of the character at byte `index`, or null when it is out of range.
    pub fn position_for_index(self: TextLayout, index: usize) ?Point(Pixels) {
        const st = self.state;
        const bounds = st.bounds orelse return null;
        const lh = st.line_height;
        var line_origin = bounds.origin;
        var line_start_ix: usize = 0;
        for (st.lines) |line| {
            const line_end_ix = line_start_ix + line.len();
            if (index < line_start_ix) {
                break;
            } else if (index > line_end_ix) {
                line_origin.y += line.size(lh).height;
                line_start_ix = line_end_ix + 1;
                continue;
            } else {
                const within = line.position_for_index(index - line_start_ix, lh) orelse return null;
                return line_origin.add(within);
            }
        }
        return null;
    }

    /// The wrapped layout of the line containing byte `index`.
    pub fn line_layout_for_index(self: TextLayout, index: usize) ?*const WrappedLineLayout {
        var line_start_ix: usize = 0;
        for (self.state.lines) |line| {
            const line_end_ix = line_start_ix + line.len();
            if (index < line_start_ix) {
                break;
            } else if (index > line_end_ix) {
                line_start_ix = line_end_ix + 1;
                continue;
            } else {
                return line.layout;
            }
        }
        return null;
    }

    /// The wrapped lines, in source order.
    pub fn lines(self: TextLayout) []const WrappedLine {
        return self.state.lines;
    }

    /// The bounds the text was painted into (valid after prepaint).
    pub fn bounds_of(self: TextLayout) ?Bounds(Pixels) {
        return self.state.bounds;
    }

    /// The line height the text was measured with.
    pub fn line_height(self: TextLayout) Pixels {
        return self.state.line_height;
    }

    /// The UTF-8 length of the underlying text.
    pub fn len(self: TextLayout) usize {
        return self.state.len;
    }

    /// The text of the layout, with lines joined by `\n`, in the frame arena.
    pub fn text(self: TextLayout) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        const arena = window_mod.frame_arena();
        for (self.state.lines, 0..) |line, i| {
            if (i > 0) out.append(arena, '\n') catch @panic("OOM");
            out.appendSlice(arena, line.text) catch @panic("OOM");
        }
        return out.items;
    }

    /// The text with soft wraps as newlines, in the frame arena.
    pub fn wrapped_text(self: TextLayout) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        const arena = window_mod.frame_arena();
        for (self.state.lines) |line| {
            var seen: usize = 0;
            for (line.layout.wrap_boundaries) |b| {
                const index = line.layout.unwrapped_layout.runs[b.run_ix].glyphs[b.glyph_ix].index;
                out.appendSlice(arena, line.text[seen..index]) catch @panic("OOM");
                out.append(arena, '\n') catch @panic("OOM");
                seen = index;
            }
            out.appendSlice(arena, line.text[seen..]) catch @panic("OOM");
            out.append(arena, '\n') catch @panic("OOM");
        }
        if (out.items.len > 0) out.items.len -= 1;
        return out.items;
    }
};

/// The inputs of one measurement, read by the layout engine (GPUI's measure closure).
const MeasureCtx = struct {
    state: *TextLayout.State,
    text: []const u8,
    runs: []const TextRun,
    text_style: TextStyle,
    font_size: Pixels,
    line_height: Pixels,

    fn measure(ctx: *anyopaque, known: Size(?Pixels), available: Size(taffy.AvailableSpace), window: *Window, cx: *App) Size(Pixels) {
        const self: *MeasureCtx = @ptrCast(@alignCast(ctx));
        return self.measure_impl(known, available, window, cx) catch Size(Pixels){ .width = 0, .height = 0 };
    }

    fn definite(space: taffy.AvailableSpace) ?Pixels {
        return switch (space) {
            .definite => |x| x,
            else => null,
        };
    }

    fn measure_impl(self: *MeasureCtx, known: Size(?Pixels), available: Size(taffy.AvailableSpace), window: *Window, cx: *App) !Size(Pixels) {
        _ = window;
        const ts = cx.text_system();
        const st = self.state;
        const text_style = self.text_style;
        const font_size = self.font_size;
        const line_height = self.line_height;

        const wrap_width: ?Pixels = if (text_style.white_space == .normal)
            known.width orelse definite(available.width)
        else
            null;

        var truncate_width: ?Pixels = null;
        var truncation_affix: []const u8 = "";
        var truncate_from: line_wrapper.TruncateFrom = .end;
        if (text_style.text_overflow) |overflow| {
            truncate_width = known.width orelse if (definite(available.width)) |x|
                (if (text_style.line_clamp) |max_lines| x * @as(f32, @floatFromInt(max_lines)) else x)
            else
                null;
            switch (overflow) {
                .truncate => |s| truncation_affix = s,
                .truncate_start => |s| {
                    truncation_affix = s;
                    truncate_from = .start;
                },
                .truncate_middle => |s| {
                    truncation_affix = s;
                    truncate_from = .middle;
                },
            }
        }

        // A cached measurement is reused when the wrap width matches and no truncation is involved.
        if (st.measured and st.size != null and (wrap_width == null or wrap_width == st.wrap_width) and truncate_width == null and st.truncate_width == null) {
            return st.size.?;
        }

        var wrapper = ts.line_wrapper(text_style.font(), font_size);
        defer wrapper.deinit();
        const arena = window_mod.frame_arena();

        var text = self.text;
        var runs = self.runs;
        if (truncate_width) |tw| {
            if (text_style.line_clamp) |max_lines| {
                if (wrap_width) |ww| {
                    const t = try wrapper.truncate_wrapped_line(arena, text, ww, max_lines, truncation_affix, runs, truncate_from);
                    text = t.text;
                    runs = t.runs;
                }
            }
            if (text_style.line_clamp == null or wrap_width == null) {
                // The unclipped text fits: keep it whole. The per-character width sum overestimates
                // shaped width (no kerning), so check the shaped result first.
                const fits = blk: {
                    const unclipped = ts.shape_text(text, font_size, runs, null, null) catch break :blk false;
                    for (unclipped) |line| {
                        if (line.size(line_height).width > tw) break :blk false;
                    }
                    break :blk true;
                };
                if (!fits) {
                    const t = try wrapper.truncate_line(arena, text, tw, truncation_affix, runs, truncate_from);
                    text = t.text;
                    runs = t.runs;
                }
            }
        }

        const lines = ts.shape_text(text, font_size, runs, wrap_width, text_style.line_clamp) catch {
            st.* = .{ .measured = true, .len = 0, .lines = &.{}, .line_height = line_height, .wrap_width = wrap_width, .truncate_width = truncate_width, .size = Size(Pixels){ .width = 0, .height = 0 } };
            return .{ .width = 0, .height = 0 };
        };

        var size: Size(Pixels) = .{ .width = 0, .height = 0 };
        for (lines) |line| {
            const line_size = line.size(line_height);
            size.height += line_size.height;
            size.width = @ceil(@max(size.width, line_size.width));
        }

        st.* = .{
            .measured = true,
            .len = text.len,
            .lines = lines,
            .line_height = line_height,
            .wrap_width = wrap_width,
            .truncate_width = truncate_width,
            .size = size,
            .bounds = null,
        };
        return size;
    }
};

// ---------------------------------------------------------------------------
// StyledText.

/// A highlighted range of text (GPUI `(Range<usize>, HighlightStyle)`).
pub const Highlight = struct {
    range: ByteRange,
    style: HighlightStyle,
};

/// A font family override for a range of text (GPUI `(Range<usize>, SharedString)`).
pub const FontFamilyOverride = struct {
    range: ByteRange,
    family: []const u8,
};

/// Text with runs of different styles (GPUI `StyledText`).
pub const StyledText = struct {
    text: []const u8,
    runs: ?[]const TextRun = null,
    delayed_highlights: ?[]const Highlight = null,
    delayed_font_family_overrides: ?[]const FontFamilyOverride = null,
    layout_state: TextLayout,

    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    /// Styled text for `text`, with no runs yet.
    pub fn new(text: []const u8) StyledText {
        return .{ .text = text, .layout_state = TextLayout.new() };
    }

    /// The layout of this text, for mapping indices to positions and back.
    pub fn layout(self: *const StyledText) TextLayout {
        return self.layout_state;
    }

    /// Styles the text with `default_style`, with `highlights` applied over it.
    pub fn with_default_highlights(self: StyledText, default_style: *const TextStyle, highlights: []const Highlight) StyledText {
        const runs = compute_runs(self.text, default_style, highlights);
        return self.with_runs(runs);
    }

    /// Applies `highlights` over the window's text style, resolved at layout time.
    pub fn with_highlights(self: StyledText, highlights: []const Highlight) StyledText {
        var out = self;
        out.delayed_highlights = window_mod.frame_arena().dupe(Highlight, highlights) catch @panic("OOM");
        return out;
    }

    /// Overrides the font family for byte ranges, resolved at layout time over the inherited style.
    pub fn with_font_family_overrides(self: StyledText, overrides: []const FontFamilyOverride) StyledText {
        var out = self;
        out.delayed_font_family_overrides = window_mod.frame_arena().dupe(FontFamilyOverride, overrides) catch @panic("OOM");
        return out;
    }

    /// Sets the runs. They must cover the whole text exactly.
    pub fn with_runs(self: StyledText, runs: []const TextRun) StyledText {
        var total: usize = 0;
        for (runs) |run| total += run.len;
        std.debug.assert(total == self.text.len);
        var out = self;
        out.runs = runs;
        return out;
    }

    fn compute_runs(text: []const u8, default_style: *const TextStyle, highlights: []const Highlight) []const TextRun {
        const arena = window_mod.frame_arena();
        var runs: std.ArrayList(TextRun) = .empty;
        var ix: usize = 0;
        for (highlights) |h| {
            if (ix < h.range.start) runs.append(arena, default_style.to_run(h.range.start - ix)) catch @panic("OOM");
            runs.append(arena, default_style.highlight(h.style).to_run(h.range.end - h.range.start)) catch @panic("OOM");
            ix = h.range.end;
        }
        if (ix < text.len) runs.append(arena, default_style.to_run(text.len - ix)) catch @panic("OOM");
        return runs.items;
    }

    fn apply_font_family_overrides(runs: []TextRun, overrides: []const FontFamilyOverride) void {
        var byte_offset: usize = 0;
        var override_idx: usize = 0;
        for (runs) |*run| {
            const run_end = byte_offset + run.len;
            while (override_idx < overrides.len and overrides[override_idx].range.end <= byte_offset) override_idx += 1;
            if (override_idx < overrides.len) {
                const o = overrides[override_idx];
                if (byte_offset >= o.range.start and run_end <= o.range.end) run.font.family = o.family;
            }
            byte_offset = run_end;
        }
    }

    pub fn id(self: *StyledText) ?element.ElementId {
        _ = self;
        return null;
    }

    pub fn request_layout(self: *StyledText, id_: ?*const element.GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        _ = id_;
        const overrides = self.delayed_font_family_overrides;
        self.delayed_font_family_overrides = null;
        var runs: ?[]const TextRun = self.runs;
        self.runs = null;
        if (runs == null) {
            if (self.delayed_highlights) |dh| {
                self.delayed_highlights = null;
                const ts = window.text_style();
                runs = compute_runs(self.text, &ts, dh);
            }
        }
        if (overrides) |ov| {
            const mutable: []TextRun = if (runs) |r| @constCast(r) else blk: {
                const ts = window.text_style();
                const single = window_mod.frame_arena().alloc(TextRun, 1) catch @panic("OOM");
                single[0] = ts.to_run(self.text.len);
                break :blk single;
            };
            apply_font_family_overrides(mutable, ov);
            runs = mutable;
        }
        const layout_id = self.layout_state.layout(self.text, runs, window, cx);
        return .{ layout_id, {} };
    }

    pub fn prepaint(self: *StyledText, id_: ?*const element.GlobalElementId, bounds: Bounds(Pixels), rl: *void, window: *Window, cx: *App) void {
        _ = id_;
        _ = rl;
        _ = window;
        _ = cx;
        self.layout_state.prepaint(bounds);
    }

    pub fn paint(self: *StyledText, id_: ?*const element.GlobalElementId, bounds: Bounds(Pixels), rl: *void, pp: *void, window: *Window, cx: *App) void {
        _ = id_;
        _ = bounds;
        _ = rl;
        _ = pp;
        self.layout_state.paint(self.text, window, cx);
    }
};

// ---------------------------------------------------------------------------
// InteractiveText.

/// Click handler: called with the index of the clicked range.
pub const ClickFn = *const fn (ctx: *anyopaque, range_index: usize, window: *Window, cx: *App) void;
/// Hover handler: called with the hovered byte index (or null) and the mouse event.
pub const HoverFn = *const fn (ctx: *anyopaque, index: ?usize, event: *const interactive.MouseMoveEvent, window: *Window, cx: *App) void;

/// A click handler bound to its context.
pub const ClickHandler = struct { ctx: *anyopaque, func: ClickFn };
/// A hover handler bound to its context.
pub const HoverHandler = struct { ctx: *anyopaque, func: HoverFn };

/// The byte index of an exact hit, or null (GPUI `Result::ok`).
fn ok_index(r: IndexResult) ?usize {
    return switch (r) {
        .ok => |i| i,
        .err => null,
    };
}

/// Mouse state kept across frames for one `InteractiveText` (GPUI `InteractiveTextState`).
pub const InteractiveTextState = struct {
    mouse_down_index: ?usize = null,
    hovered_index: ?usize = null,
};

/// Styled text that reacts to clicks on ranges and to hovering (GPUI `InteractiveText`).
pub const InteractiveText = struct {
    element_id: element.ElementId,
    text: StyledText,
    clickable_ranges: []const ByteRange = &.{},
    click: ?ClickHandler = null,
    hover: ?HoverHandler = null,

    pub const RequestLayoutState = void;
    pub const PrepaintState = Hitbox;

    pub fn new(id_: anytype, text: StyledText) InteractiveText {
        return .{ .element_id = element.ElementId.from(id_), .text = text };
    }

    /// Calls `listener(ctx, range_index, ...)` when a press and release both land in one of `ranges`.
    pub fn on_click(self: InteractiveText, ranges: []const ByteRange, ctx: *anyopaque, func: ClickFn) InteractiveText {
        var out = self;
        out.clickable_ranges = ranges;
        out.click = .{ .ctx = ctx, .func = func };
        return out;
    }

    /// Calls `func(ctx, index, ...)` when the hovered character changes.
    pub fn on_hover(self: InteractiveText, ctx: *anyopaque, func: HoverFn) InteractiveText {
        var out = self;
        out.hover = .{ .ctx = ctx, .func = func };
        return out;
    }

    pub fn id(self: *InteractiveText) ?element.ElementId {
        return self.element_id;
    }

    pub fn request_layout(self: *InteractiveText, id_: ?*const element.GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        _ = id_;
        return self.text.request_layout(null, window, cx);
    }

    pub fn prepaint(self: *InteractiveText, id_: ?*const element.GlobalElementId, bounds: Bounds(Pixels), rl: *void, window: *Window, cx: *App) Hitbox {
        _ = id_;
        self.text.prepaint(null, bounds, rl, window, cx);
        return window.insert_hitbox(bounds, .normal);
    }

    /// Per-interaction state: the pressed index and the one the pointer last hovered.
    const Ctx = struct {
        layout: TextLayout,
        hitbox: Hitbox,
        state: *InteractiveTextState,
        ranges: []const ByteRange,
        click: ?ClickHandler,
        hover: ?HoverHandler,
    };

    pub fn paint(self: *InteractiveText, id_: ?*const element.GlobalElementId, bounds: Bounds(Pixels), rl: *void, hitbox: *Hitbox, window: *Window, cx: *App) void {
        const gid = id_ orelse return;
        const text_layout = self.text.layout();
        const state = window.element_state(InteractiveTextState, gid.*, .{});
        const arena = window_mod.frame_arena();
        const ctx = arena.create(Ctx) catch @panic("OOM");
        ctx.* = .{
            .layout = text_layout,
            .hitbox = hitbox.*,
            .state = state,
            .ranges = self.clickable_ranges,
            .click = self.click,
            .hover = self.hover,
        };

        if (self.click != null) {
            const mouse = window.mouse_position();
            if (ok_index(text_layout.index_for_position(mouse))) |ix| {
                if (any_contains(self.clickable_ranges, ix)) window.set_cursor_style(.pointing_hand, hitbox);
            }
            window.on_mouse_event(interactive.MouseDownEvent, ctx, on_mouse_down);
            window.on_mouse_event(interactive.MouseUpEvent, ctx, on_mouse_up);
        }
        window.on_mouse_event(interactive.MouseMoveEvent, ctx, on_mouse_move);
        var pp: void = {};
        self.text.paint(null, bounds, rl, &pp, window, cx);
    }

    fn any_contains(ranges: []const ByteRange, index: usize) bool {
        for (ranges) |r| if (r.contains(index)) return true;
        return false;
    }

    fn on_mouse_down(ctx_ptr: *anyopaque, event: *const interactive.MouseDownEvent, phase: window_mod.DispatchPhase, window: *Window, cx: *App) void {
        _ = cx;
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        if (phase != .bubble or !ctx.hitbox.is_hovered(window)) return;
        if (ok_index(ctx.layout.index_for_position(event.position))) |ix| {
            ctx.state.mouse_down_index = ix;
            window.refresh();
        }
    }

    fn on_mouse_up(ctx_ptr: *anyopaque, event: *const interactive.MouseUpEvent, phase: window_mod.DispatchPhase, window: *Window, cx: *App) void {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        if (phase != .bubble or !ctx.hitbox.is_hovered(window)) return;
        const down = ctx.state.mouse_down_index orelse return;
        if (ok_index(ctx.layout.index_for_position(event.position))) |up| {
            if (ctx.click) |c| {
                for (ctx.ranges, 0..) |range, i| {
                    if (range.contains(down) and range.contains(up)) c.func(c.ctx, i, window, cx);
                }
            }
        }
        ctx.state.mouse_down_index = null;
        window.refresh();
    }

    fn on_mouse_move(ctx_ptr: *anyopaque, event: *const interactive.MouseMoveEvent, phase: window_mod.DispatchPhase, window: *Window, cx: *App) void {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        if (phase != .bubble or !ctx.hitbox.is_hovered(window)) return;
        const updated: ?usize = ok_index(ctx.layout.index_for_position(event.position));
        if (ctx.state.hovered_index != updated) {
            ctx.state.hovered_index = updated;
            if (ctx.hover) |h| h.func(h.ctx, updated, event, window, cx);
            window.refresh();
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: the pure parts (runs, overrides, highlight composition).

const testing = std.testing;

test "compute_runs covers the text between and around highlights" {
    var ts: TextStyle = .{};
    ts.font_family = "Test";
    const highlights = [_]Highlight{
        .{ .range = .{ .start = 2, .end = 4 }, .style = .{ .font_weight = .BOLD } },
    };
    const runs = StyledText.compute_runs("abcdef", &ts, &highlights);
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expectEqual(@as(usize, 2), runs[0].len);
    try testing.expectEqual(@as(usize, 2), runs[1].len);
    try testing.expectEqual(@as(usize, 2), runs[2].len);
    try testing.expect(runs[1].font.weight.eql(.BOLD));
}

test "font family overrides rewrite only the runs inside their range" {
    const family_default = "Default";
    var runs = [_]TextRun{
        .{ .len = 2, .font = .{ .family = family_default }, .color = .{ .h = 0, .s = 0, .l = 0, .a = 1 } },
        .{ .len = 3, .font = .{ .family = family_default }, .color = .{ .h = 0, .s = 0, .l = 0, .a = 1 } },
    };
    const overrides = [_]FontFamilyOverride{.{ .range = .{ .start = 2, .end = 5 }, .family = "Mono" }};
    StyledText.apply_font_family_overrides(&runs, &overrides);
    try testing.expectEqualStrings("Default", runs[0].font.family);
    try testing.expectEqualStrings("Mono", runs[1].font.family);
}

test "byte range contains is half-open" {
    const r: ByteRange = .{ .start = 1, .end = 3 };
    try testing.expect(r.contains(1));
    try testing.expect(r.contains(2));
    try testing.expect(!r.contains(3));
}
