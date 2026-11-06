//! Port of GPUI `style.rs`: the CSS-like `Style` and its `StyleRefinement`.

const std = @import("std");
const geometry = @import("geometry.zig");
const color_mod = @import("color.zig");
const refineable = @import("refineable.zig");
const font_mod = @import("text_system/font.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Edges = geometry.Edges;
const Corners = geometry.Corners;
const Length = geometry.Length;
const DefiniteLength = geometry.DefiniteLength;
const AbsoluteLength = geometry.AbsoluteLength;
const Hsla = color_mod.Hsla;
const Background = color_mod.Background;
const SharedString = font_mod.SharedString;
pub const Font = font_mod.Font;
pub const FontWeight = font_mod.FontWeight;
pub const FontStyle = font_mod.FontStyle;
pub const FontFeatures = font_mod.FontFeatures;
pub const FontFallbacks = font_mod.FontFallbacks;

pub const Refinement = refineable.Refinement;

/// How an image fills its bounds.
pub const ObjectFit = enum {
    fill,
    contain,
    cover,
    scale_down,
    none,

    /// Bounds of an image of `image_size` drawn into `bounds` with this fit.
    pub fn get_bounds(self: ObjectFit, b: Bounds(Pixels), image_size: Size(geometry.DevicePixels)) Bounds(Pixels) {
        const iw: f32 = @floatFromInt(image_size.width);
        const ih: f32 = @floatFromInt(image_size.height);
        const image_ratio = iw / ih;
        const bounds_ratio = b.size.width / b.size.height;
        const contain_size: Size(Pixels) = if (bounds_ratio > image_ratio)
            .{ .width = iw * (b.size.height / ih), .height = b.size.height }
        else
            .{ .width = b.size.width, .height = ih * (b.size.width / iw) };
        const cover_size: Size(Pixels) = if (bounds_ratio > image_ratio)
            .{ .width = b.size.width, .height = ih * (b.size.width / iw) }
        else
            .{ .width = iw * (b.size.height / ih), .height = b.size.height };
        const centered = struct {
            fn f(outer: Bounds(Pixels), s: Size(Pixels)) Bounds(Pixels) {
                return .{ .origin = .{ .x = outer.origin.x + (outer.size.width - s.width) / 2.0, .y = outer.origin.y + (outer.size.height - s.height) / 2.0 }, .size = s };
            }
        }.f;
        return switch (self) {
            .fill => b,
            .contain => centered(b, contain_size),
            .scale_down => if (iw > b.size.width or ih > b.size.height) centered(b, contain_size) else centered(b, .{ .width = iw, .height = ih }),
            .cover => centered(b, cover_size),
            .none => .{ .origin = b.origin, .size = .{ .width = iw, .height = ih } },
        };
    }
};

pub const GridTemplateMinSize = enum { zero, min_content, max_content };

/// A repeated grid track template (`repeat(n, minmax(min_size, 1fr))`).
pub const GridTemplate = struct {
    repeat: u16 = 0,
    min_size: GridTemplateMinSize = .zero,
};

/// A single grid line placement.
pub const GridPlacement = union(enum) {
    line: i16,
    span: u16,
    auto,
};

/// Where an item is placed in a grid.
pub const GridLocation = struct {
    row: struct { start: GridPlacement = .auto, end: GridPlacement = .auto } = .{},
    column: struct { start: GridPlacement = .auto, end: GridPlacement = .auto } = .{},
};

pub const Visibility = enum { visible, hidden };

/// A box shadow.
pub const BoxShadow = struct {
    color: Hsla,
    offset: Point(Pixels),
    // Named with a trailing underscore because the builders below share the names.
    blur_radius_: Pixels = 0,
    spread_radius_: Pixels = 0,
    inset: bool = false,

    pub fn new(offset_x: Pixels, offset_y: Pixels, c: Hsla) BoxShadow {
        return .{ .color = c, .offset = .{ .x = offset_x, .y = offset_y } };
    }
    /// Sets the shadow blur radius (GPUI `BoxShadow::blur_radius`).
    pub fn blur_radius(self: BoxShadow, r: Pixels) BoxShadow {
        var s = self;
        s.blur_radius_ = r;
        return s;
    }
    /// Sets the shadow spread radius (GPUI `BoxShadow::spread_radius`).
    pub fn spread_radius(self: BoxShadow, r: Pixels) BoxShadow {
        var s = self;
        s.spread_radius_ = r;
        return s;
    }
    pub const with_blur_radius = blur_radius;
    pub const with_spread_radius = spread_radius;
    pub fn with_inset(self: BoxShadow) BoxShadow {
        var s = self;
        s.inset = true;
        return s;
    }
};

pub const WhiteSpace = enum { normal, nowrap };

pub const TextOverflow = union(enum) {
    truncate: SharedString,
    truncate_start: SharedString,
    truncate_middle: SharedString,
};

pub const TextAlign = enum { left, center, right };

pub const UnderlineStyle = struct {
    thickness: Pixels = 0,
    color: ?Hsla = null,
    wavy: bool = false,
};

pub const StrikethroughStyle = struct {
    thickness: Pixels = 0,
    color: ?Hsla = null,
};

/// The text style of an element, inherited by descendants.
pub const TextStyle = struct {
    color: Hsla = color_mod.black(),
    font_family: SharedString = ".SystemUIFont",
    font_features: FontFeatures = .{},
    font_fallbacks: ?FontFallbacks = null,
    font_size: AbsoluteLength = .{ .rems = .{ .value = 1.0 } },
    line_height: DefiniteLength = geometry.phi(),
    font_weight: FontWeight = .NORMAL,
    font_style: FontStyle = .normal,
    background_color: ?Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,
    white_space: WhiteSpace = .normal,
    text_overflow: ?TextOverflow = null,
    text_align: TextAlign = .left,
    line_clamp: ?usize = null,

    pub fn highlight(self: TextStyle, style: HighlightStyle) TextStyle {
        var s = self;
        if (style.font_weight) |w| s.font_weight = w;
        if (style.font_style) |fs| s.font_style = fs;
        if (style.color) |c| s.color = s.color.blend(c);
        if (style.fade_out) |f| s.color.fade_out(f);
        if (style.background_color) |c| s.background_color = c;
        if (style.underline) |u| s.underline = u;
        if (style.strikethrough) |st| s.strikethrough = st;
        return s;
    }

    pub fn font(self: *const TextStyle) Font {
        return .{
            .family = self.font_family,
            .features = self.font_features,
            .fallbacks = self.font_fallbacks,
            .weight = self.font_weight,
            .style = self.font_style,
        };
    }

    pub fn line_height_in_pixels(self: *const TextStyle, rem_size: Pixels) Pixels {
        return @round(self.line_height.to_pixels(self.font_size, rem_size));
    }

    pub fn to_run(self: *const TextStyle, len: usize) TextRun {
        return .{
            .len = len,
            .font = self.font(),
            .color = self.color,
            .background_color = self.background_color,
            .underline = self.underline,
            .strikethrough = self.strikethrough,
        };
    }
};

pub const TextStyleRefinement = Refinement(TextStyle);

/// A run of text with a single style (GPUI `TextRun`).
pub const TextRun = struct {
    len: usize,
    font: Font,
    color: Hsla,
    background_color: ?Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,
};

/// A highlight applied over a text range.
pub const HighlightStyle = struct {
    color: ?Hsla = null,
    font_weight: ?FontWeight = null,
    font_style: ?FontStyle = null,
    background_color: ?Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,
    fade_out: ?f32 = null,

    pub fn color_only(c: Hsla) HighlightStyle {
        return .{ .color = c };
    }

    pub fn highlight(self: HighlightStyle, other: HighlightStyle) HighlightStyle {
        return .{
            .color = if (other.color) |oc| (if (self.color) |c| c.blend(oc) else oc) else self.color,
            .font_weight = other.font_weight orelse self.font_weight,
            .font_style = other.font_style orelse self.font_style,
            .background_color = other.background_color orelse self.background_color,
            .underline = other.underline orelse self.underline,
            .strikethrough = other.strikethrough orelse self.strikethrough,
            .fade_out = if (other.fade_out) |sf| (if (self.fade_out) |df| std.math.clamp(df * (1.0 + sf), 0.0, 1.0) else sf) else self.fade_out,
        };
    }

    pub fn from_text_style(other: *const TextStyle) HighlightStyle {
        return .{
            .color = other.color,
            .font_weight = other.font_weight,
            .font_style = other.font_style,
            .background_color = other.background_color,
            .underline = other.underline,
            .strikethrough = other.strikethrough,
        };
    }
};

/// The fill of a box.
pub const Fill = union(enum) {
    color: Background,

    pub fn get_color(self: Fill) ?Background {
        return switch (self) {
            .color => |c| c,
        };
    }
};

/// Converts Hsla/Rgba/Background/Fill into a `Fill`.
pub fn to_fill(v: anytype) Fill {
    if (@TypeOf(v) == Fill) return v;
    return .{ .color = color_mod.to_background(v) };
}

pub const AlignItems = enum { start, end, flex_start, flex_end, center, baseline, stretch };
pub const JustifyItems = AlignItems;
pub const AlignSelf = AlignItems;
pub const JustifySelf = AlignItems;
pub const AlignContent = enum { start, end, flex_start, flex_end, center, stretch, space_between, space_evenly, space_around };
pub const JustifyContent = AlignContent;
pub const Display = enum { block, flex, grid, none };
pub const FlexWrap = enum { no_wrap, wrap, wrap_reverse };
pub const FlexDirection = enum { row, column, row_reverse, column_reverse };
pub const Overflow = enum { visible, clip, hidden, scroll };
pub const Position = enum { relative, absolute };
pub const BorderStyle = @import("scene.zig").BorderStyle;

/// The mouse cursor shown over an element.
pub const CursorStyle = enum {
    arrow,
    i_beam,
    crosshair,
    closed_hand,
    open_hand,
    pointing_hand,
    resize_left,
    resize_right,
    resize_left_right,
    resize_up,
    resize_down,
    resize_up_down,
    resize_up_left_down_right,
    resize_up_right_down_left,
    resize_column,
    resize_row,
    i_beam_cursor_for_vertical_layout,
    operation_not_allowed,
    drag_link,
    drag_copy,
    context_menu,
    none,
};

/// The CSS-like style of an element (GPUI `Style`).
pub const Style = struct {
    pub const refineable_fields = .{ "overflow", "inset", "size", "min_size", "max_size", "margin", "padding", "border_widths", "gap", "corner_radii", "text" };

    display: Display = .block,
    visibility: Visibility = .visible,
    overflow: Point(Overflow) = .{ .x = .visible, .y = .visible },
    scrollbar_width: AbsoluteLength = .{ .pixels = 0 },
    allow_concurrent_scroll: bool = false,
    restrict_scroll_to_axis: bool = false,
    position: Position = .relative,
    inset: Edges(Length) = .{ .top = .auto, .right = .auto, .bottom = .auto, .left = .auto },
    size: Size(Length) = .{ .width = .auto, .height = .auto },
    min_size: Size(Length) = .{ .width = .auto, .height = .auto },
    max_size: Size(Length) = .{ .width = .auto, .height = .auto },
    aspect_ratio: ?f32 = null,
    margin: Edges(Length) = zeroEdges(Length),
    padding: Edges(DefiniteLength) = zeroEdges(DefiniteLength),
    border_widths: Edges(AbsoluteLength) = zeroEdges(AbsoluteLength),
    align_items: ?AlignItems = null,
    align_self: ?AlignSelf = null,
    align_content: ?AlignContent = null,
    justify_content: ?JustifyContent = null,
    gap: Size(DefiniteLength) = .{ .width = zeroLen(DefiniteLength), .height = zeroLen(DefiniteLength) },
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .no_wrap,
    flex_basis: Length = .auto,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    background: ?Fill = null,
    border_color: ?Hsla = null,
    border_style: BorderStyle = .solid,
    corner_radii: Corners(AbsoluteLength) = .{ .top_left = zeroLen(AbsoluteLength), .top_right = zeroLen(AbsoluteLength), .bottom_right = zeroLen(AbsoluteLength), .bottom_left = zeroLen(AbsoluteLength) },
    box_shadow: []const BoxShadow = &.{},
    text: TextStyleRefinement = .{},
    mouse_cursor: ?CursorStyle = null,
    opacity: ?f32 = null,
    grid_cols: ?GridTemplate = null,
    grid_rows: ?GridTemplate = null,
    grid_location: ?GridLocation = null,
    debug: bool = false,
    debug_below: bool = false,

    /// The text style refinement carried by this style, if any.
    pub fn text_style(self: *const Style) ?*const TextStyleRefinement {
        if (refineable.is_empty(TextStyle, &self.text)) return null;
        return &self.text;
    }

    /// The content mask for overflow clipping, or null when overflow is visible on both axes.
    pub fn overflow_mask(self: *const Style, b: Bounds(Pixels), rem_size: Pixels) ?Bounds(Pixels) {
        if (self.overflow.x == .visible and self.overflow.y == .visible) return null;
        var min = b.origin;
        var max = b.bottom_right();
        if (self.overflow.x != .visible) {
            min.x += self.border_widths.left.to_pixels(rem_size);
            max.x -= self.border_widths.right.to_pixels(rem_size);
        } else {
            min.x = -std.math.floatMax(f32);
            max.x = std.math.floatMax(f32);
        }
        if (self.overflow.y != .visible) {
            min.y += self.border_widths.top.to_pixels(rem_size);
            max.y -= self.border_widths.bottom.to_pixels(rem_size);
        } else {
            min.y = -std.math.floatMax(f32);
            max.y = std.math.floatMax(f32);
        }
        return Bounds(Pixels).from_corners(min, max);
    }

    /// True if this style paints a fully opaque background.
    pub fn has_opaque_background(self: *const Style) bool {
        const bg = self.background orelse return false;
        return switch (bg) {
            .color => |c| c.tag == .solid and c.solid.a >= 1.0,
        };
    }

    /// True if any border width is non-zero.
    pub fn is_border_visible(self: *const Style) bool {
        return !(self.border_widths.top.is_zero() and self.border_widths.right.is_zero() and self.border_widths.bottom.is_zero() and self.border_widths.left.is_zero());
    }

    /// Applies a refinement in place.
    pub fn refine(self: *Style, r: *const StyleRefinement) void {
        refineable.refine(Style, self, r);
    }
};

pub const StyleRefinement = Refinement(Style);

fn zeroLen(comptime T: type) T {
    return switch (T) {
        Length => .{ .definite = .{ .absolute = .{ .pixels = 0 } } },
        DefiniteLength => .{ .absolute = .{ .pixels = 0 } },
        AbsoluteLength => .{ .pixels = 0 },
        else => @compileError("unsupported"),
    };
}

fn zeroEdges(comptime T: type) Edges(T) {
    const z = zeroLen(T);
    return .{ .top = z, .right = z, .bottom = z, .left = z };
}

/// Merges `other` into `self` (later wins), as GPUI's `StyleRefinement::refine`.
pub fn merge_refinement(self: *StyleRefinement, other: *const StyleRefinement) void {
    refineable.merge(Style, self, other);
}

/// Merges text style refinements.
pub fn merge_text_refinement(self: *TextStyleRefinement, other: *const TextStyleRefinement) void {
    refineable.merge(TextStyle, self, other);
}

test "style refinement" {
    var r: StyleRefinement = .{};
    r.size.width = .{ .definite = .{ .absolute = .{ .pixels = 10 } } };
    r.text.font_weight = FontWeight.BOLD;
    var s: Style = .{};
    s.refine(&r);
    try std.testing.expectEqual(@as(f32, 10), s.size.width.definite.absolute.pixels);
    try std.testing.expect(s.size.height == .auto);
    try std.testing.expect(s.text_style() != null);
}

/// Splits two sets of highlights into non-overlapping segments, each with the fold of every
/// highlight covering it (GPUI `combine_highlights`). `H` is a record with `range: { start, end }`
/// and `style: HighlightStyle`, such as `text.Highlight`. GPUI folds the covering styles in hash
/// order; here they fold in the order given, `a` first, so the result is deterministic.
/// Empty ranges are dropped, and no segment is emitted where nothing covers the text.
pub fn combine_highlights(comptime H: type, allocator: std.mem.Allocator, a: []const H, b: []const H) ![]H {
    const Endpoint = struct { pos: usize, id: usize, start: bool };
    var endpoints: std.ArrayList(Endpoint) = .empty;
    defer endpoints.deinit(allocator);
    var styles: std.ArrayList(HighlightStyle) = .empty;
    defer styles.deinit(allocator);

    for ([_][]const H{ a, b }) |list| {
        for (list) |h| {
            if (h.range.start >= h.range.end) continue;
            const id = styles.items.len;
            try styles.append(allocator, h.style);
            try endpoints.append(allocator, .{ .pos = h.range.start, .id = id, .start = true });
            try endpoints.append(allocator, .{ .pos = h.range.end, .id = id, .start = false });
        }
    }
    std.mem.sort(Endpoint, endpoints.items, {}, struct {
        fn less(_: void, x: Endpoint, y: Endpoint) bool {
            return x.pos < y.pos;
        }
    }.less);

    var active: std.ArrayList(usize) = .empty; // ids covering the cursor, ascending
    defer active.deinit(allocator);
    var out: std.ArrayList(H) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (endpoints.items) |e| {
        if (e.pos > cursor and active.items.len > 0) {
            var style: HighlightStyle = .{};
            for (active.items) |id| style = style.highlight(styles.items[id]);
            try out.append(allocator, .{ .range = .{ .start = cursor, .end = e.pos }, .style = style });
        }
        cursor = e.pos;
        if (e.start) {
            var at: usize = active.items.len;
            while (at > 0 and active.items[at - 1] > e.id) at -= 1;
            try active.insert(allocator, at, e.id);
        } else {
            for (active.items, 0..) |id, i| {
                if (id == e.id) {
                    _ = active.orderedRemove(i);
                    break;
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

test "combine_highlights splits overlapping ranges as GPUI does" {
    const Range = struct { start: usize, end: usize };
    const Hl = struct { range: Range, style: HighlightStyle };
    const green: HighlightStyle = .{ .color = color_mod.hsla(0.33, 1, 0.5, 1) };
    const blue: HighlightStyle = .{ .color = color_mod.hsla(0.66, 1, 0.5, 1) };
    const yellow: HighlightStyle = .{ .color = color_mod.hsla(0.16, 1, 0.5, 1) };
    const red: HighlightStyle = .{ .color = color_mod.hsla(0.0, 1, 0.5, 1) };
    const bold: HighlightStyle = .{ .font_weight = .BOLD };
    const italic: HighlightStyle = .{ .font_style = .italic };

    const a = [_]Hl{
        .{ .range = .{ .start = 0, .end = 5 }, .style = green },
        .{ .range = .{ .start = 4, .end = 10 }, .style = bold },
        .{ .range = .{ .start = 15, .end = 20 }, .style = yellow },
    };
    const b = [_]Hl{
        .{ .range = .{ .start = 2, .end = 6 }, .style = italic },
        .{ .range = .{ .start = 1, .end = 3 }, .style = blue },
        .{ .range = .{ .start = 21, .end = 23 }, .style = red },
    };
    const out = try combine_highlights(Hl, std.testing.allocator, &a, &b);
    defer std.testing.allocator.free(out);

    const expected = [_]struct { start: usize, end: usize, style: HighlightStyle }{
        .{ .start = 0, .end = 1, .style = green },
        .{ .start = 1, .end = 2, .style = blue },
        .{ .start = 2, .end = 3, .style = .{ .color = blue.color, .font_style = .italic } },
        .{ .start = 3, .end = 4, .style = .{ .color = green.color, .font_style = .italic } },
        .{ .start = 4, .end = 5, .style = .{ .color = green.color, .font_weight = .BOLD, .font_style = .italic } },
        .{ .start = 5, .end = 6, .style = .{ .font_weight = .BOLD, .font_style = .italic } },
        .{ .start = 6, .end = 10, .style = bold },
        .{ .start = 15, .end = 20, .style = yellow },
        .{ .start = 21, .end = 23, .style = red },
    };
    try std.testing.expectEqual(expected.len, out.len);
    for (expected, out) |want, got| {
        try std.testing.expectEqual(want.start, got.range.start);
        try std.testing.expectEqual(want.end, got.range.end);
        try std.testing.expectEqualDeep(want.style, got.style);
    }
}

test "combine_highlights emits no empty segment when ranges start together" {
    const Hl = struct { range: struct { start: usize, end: usize }, style: HighlightStyle };
    const bold: HighlightStyle = .{ .font_weight = .BOLD };
    const italic: HighlightStyle = .{ .font_style = .italic };
    const a = [_]Hl{.{ .range = .{ .start = 0, .end = 3 }, .style = bold }};
    const b = [_]Hl{.{ .range = .{ .start = 0, .end = 3 }, .style = italic }};
    const out = try combine_highlights(Hl, std.testing.allocator, &a, &b);
    defer std.testing.allocator.free(out);

    // One segment covering both, not a zero-length one where the second range starts.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 0), out[0].range.start);
    try std.testing.expectEqual(@as(usize, 3), out[0].range.end);
    try std.testing.expectEqual(FontStyle.italic, out[0].style.font_style.?);
    try std.testing.expectEqual(FontWeight.BOLD, out[0].style.font_weight.?);
}

test "highlight combination" {
    const a: HighlightStyle = .{};
    const b: HighlightStyle = .{ .font_style = .italic, .fade_out = 0 };
    const c = a.highlight(b);
    try std.testing.expectEqual(FontStyle.italic, c.font_style.?);
}
