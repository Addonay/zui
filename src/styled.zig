//! Port of GPUI `styled.rs` and the `gpui_macros` style helpers: the `Styled` mixin.
//!
//! Element types get the API by aliasing, e.g. `pub const flex = styled.Styled(*Div).flex;`.
//! `assert_has_all_styled_methods(*Div)` checks at compile time that an element provides every method.

const std = @import("std");
const builtin = @import("builtin");
const style = @import("style.zig");
const geometry = @import("geometry.zig");
const color = @import("color.zig");

const ELLIPSIS = "…";

// Length constructors used by the generated spacing, size, border and radius methods.
fn abs_px(v: f32) geometry.AbsoluteLength {
    return .{ .pixels = geometry.px(v) };
}

fn abs_rem(v: f32) geometry.AbsoluteLength {
    return .{ .rems = geometry.rems(v) };
}

fn def_px(v: f32) geometry.DefiniteLength {
    return .{ .absolute = abs_px(v) };
}

fn def_rem(v: f32) geometry.DefiniteLength {
    return .{ .absolute = abs_rem(v) };
}

fn def_rel(f: f32) geometry.DefiniteLength {
    return geometry.relative(f);
}

fn len_px(v: f32) geometry.Length {
    return .{ .definite = def_px(v) };
}

fn len_rem(v: f32) geometry.Length {
    return .{ .definite = def_rem(v) };
}

fn len_rel(f: f32) geometry.Length {
    return .{ .definite = def_rel(f) };
}

fn underline_mut(t: *style.TextStyleRefinement) *style.UnderlineStyle {
    if (t.underline == null) t.underline = .{};
    return &t.underline.?;
}

fn grid_location_mut(s: *style.StyleRefinement) *style.GridLocation {
    if (s.grid_location == null) s.grid_location = .{};
    return &s.grid_location.?;
}

const shadow_2xs_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 1.0, color.hsla(0.0, 0.0, 0.0, 0.05)),
};
const shadow_xs_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 1.0, color.hsla(0.0, 0.0, 0.0, 0.05)).with_blur_radius(2.0),
};
const shadow_sm_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 1.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(3.0),
    style.BoxShadow.new(0.0, 1.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(2.0).with_spread_radius(-1.0),
};
const shadow_md_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 4.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(6.0).with_spread_radius(-1.0),
    style.BoxShadow.new(0.0, 2.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(4.0).with_spread_radius(-2.0),
};
const shadow_lg_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 10.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(15.0).with_spread_radius(-3.0),
    style.BoxShadow.new(0.0, 4.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(6.0).with_spread_radius(-4.0),
};
const shadow_xl_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 20.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(25.0).with_spread_radius(-5.0),
    style.BoxShadow.new(0.0, 8.0, color.hsla(0.0, 0.0, 0.0, 0.1)).with_blur_radius(10.0).with_spread_radius(-6.0),
};
const shadow_2xl_values = [_]style.BoxShadow{
    style.BoxShadow.new(0.0, 25.0, color.hsla(0.0, 0.0, 0.0, 0.25)).with_blur_radius(50.0).with_spread_radius(-12.0),
};

/// Mixin providing GPUI's `Styled` API. `Self` is the element handle (e.g. `*Div`) and must
/// have `pub fn style(self: Self) *style.StyleRefinement`. Every method returns `Self` for chaining.
pub fn Styled(comptime Self: type) type {
    return struct {
        /// Returns the text style refinement of this element.
        pub fn text_style(self: Self) *style.TextStyleRefinement {
            return &self.style().text;
        }

        /// Sets the display type of the element to `block`.
        pub fn block(self: Self) Self {
            self.style().display = .block;
            return self;
        }

        /// Sets the display type of the element to `flex`.
        pub fn flex(self: Self) Self {
            self.style().display = .flex;
            return self;
        }

        /// Sets the display type of the element to `grid`.
        pub fn grid(self: Self) Self {
            self.style().display = .grid;
            return self;
        }

        /// Sets the display type of the element to `none`.
        pub fn hidden(self: Self) Self {
            self.style().display = .none;
            return self;
        }

        /// Sets the space reserved for the scrollbar.
        pub fn scrollbar_width(self: Self, width: anytype) Self {
            self.style().scrollbar_width = geometry.to_absolute_length(width);
            return self;
        }

        /// Sets the whitespace of the element to `normal`.
        pub fn whitespace_normal(self: Self) Self {
            text_style(self).white_space = .normal;
            return self;
        }

        /// Sets the whitespace of the element to `nowrap`.
        pub fn whitespace_nowrap(self: Self) Self {
            text_style(self).white_space = .nowrap;
            return self;
        }

        /// Truncates overflowing text with an ellipsis (…) at the end.
        pub fn text_ellipsis(self: Self) Self {
            text_style(self).text_overflow = .{ .truncate = ELLIPSIS };
            return self;
        }

        /// Truncates overflowing text with an ellipsis (…) at the start.
        pub fn text_ellipsis_start(self: Self) Self {
            text_style(self).text_overflow = .{ .truncate_start = ELLIPSIS };
            return self;
        }

        /// Truncates overflowing text with an ellipsis (…) in the middle.
        pub fn text_ellipsis_middle(self: Self) Self {
            text_style(self).text_overflow = .{ .truncate_middle = ELLIPSIS };
            return self;
        }

        /// Sets the text overflow behavior of the element.
        pub fn text_overflow(self: Self, overflow: style.TextOverflow) Self {
            text_style(self).text_overflow = overflow;
            return self;
        }

        /// Sets the text alignment of the element.
        pub fn text_align(self: Self, alignment: style.TextAlign) Self {
            text_style(self).text_align = alignment;
            return self;
        }

        /// Sets the text alignment to left.
        pub fn text_left(self: Self) Self {
            return text_align(self, .left);
        }

        /// Sets the text alignment to center.
        pub fn text_center(self: Self) Self {
            return text_align(self, .center);
        }

        /// Sets the text alignment to right.
        pub fn text_right(self: Self) Self {
            return text_align(self, .right);
        }

        /// Prevents text from wrapping and truncates overflowing text with an ellipsis (…).
        pub fn truncate(self: Self) Self {
            return text_ellipsis(whitespace_nowrap(overflow_hidden(self)));
        }

        /// Sets the number of lines to show before truncating the text.
        pub fn line_clamp(self: Self, lines: usize) Self {
            text_style(self).line_clamp = lines;
            return overflow_hidden(self);
        }

        /// Sets the flex direction of the element to `column`.
        pub fn flex_col(self: Self) Self {
            self.style().flex_direction = .column;
            return self;
        }

        /// Sets the flex direction of the element to `column-reverse`.
        pub fn flex_col_reverse(self: Self) Self {
            self.style().flex_direction = .column_reverse;
            return self;
        }

        /// Sets the flex direction of the element to `row`.
        pub fn flex_row(self: Self) Self {
            self.style().flex_direction = .row;
            return self;
        }

        /// Sets the flex direction of the element to `row-reverse`.
        pub fn flex_row_reverse(self: Self) Self {
            self.style().flex_direction = .row_reverse;
            return self;
        }

        /// Lets a flex item grow and shrink as needed, ignoring its initial size.
        pub fn flex_1(self: Self) Self {
            const s = self.style();
            s.flex_grow = 1.0;
            s.flex_shrink = 1.0;
            s.flex_basis = len_rel(0.0);
            return self;
        }

        /// Lets a flex item grow and shrink, taking its initial size into account.
        pub fn flex_auto(self: Self) Self {
            const s = self.style();
            s.flex_grow = 1.0;
            s.flex_shrink = 1.0;
            s.flex_basis = geometry.auto();
            return self;
        }

        /// Lets a flex item shrink but not grow, taking its initial size into account.
        pub fn flex_initial(self: Self) Self {
            const s = self.style();
            s.flex_grow = 0.0;
            s.flex_shrink = 1.0;
            s.flex_basis = geometry.auto();
            return self;
        }

        /// Prevents a flex item from growing or shrinking.
        pub fn flex_none(self: Self) Self {
            const s = self.style();
            s.flex_grow = 0.0;
            s.flex_shrink = 0.0;
            s.flex_basis = geometry.auto();
            return self;
        }

        /// Sets the initial size of flex items for this element.
        pub fn flex_basis(self: Self, basis: anytype) Self {
            self.style().flex_basis = geometry.to_length(basis);
            return self;
        }

        /// Sets the flex item's grow factor.
        pub fn flex_grow(self: Self, grow: f32) Self {
            self.style().flex_grow = grow;
            return self;
        }

        /// Disables flex item growth (flex-grow: 0).
        pub fn flex_grow_0(self: Self) Self {
            self.style().flex_grow = 0.0;
            return self;
        }

        /// Enables flex item growth (flex-grow: 1).
        pub fn flex_grow_1(self: Self) Self {
            self.style().flex_grow = 1.0;
            return self;
        }

        /// Sets the flex item's shrink factor.
        pub fn flex_shrink(self: Self, shrink: f32) Self {
            self.style().flex_shrink = shrink;
            return self;
        }

        /// Disables flex item shrinking (flex-shrink: 0).
        pub fn flex_shrink_0(self: Self) Self {
            self.style().flex_shrink = 0.0;
            return self;
        }

        /// Enables flex item shrinking (flex-shrink: 1).
        pub fn flex_shrink_1(self: Self) Self {
            self.style().flex_shrink = 1.0;
            return self;
        }

        /// Lets flex items wrap.
        pub fn flex_wrap(self: Self) Self {
            self.style().flex_wrap = .wrap;
            return self;
        }

        /// Lets flex items wrap in the reverse direction.
        pub fn flex_wrap_reverse(self: Self) Self {
            self.style().flex_wrap = .wrap_reverse;
            return self;
        }

        /// Prevents flex items from wrapping.
        pub fn flex_nowrap(self: Self) Self {
            self.style().flex_wrap = .no_wrap;
            return self;
        }

        /// Aligns flex items to the start of the cross axis.
        pub fn items_start(self: Self) Self {
            self.style().align_items = .flex_start;
            return self;
        }

        /// Aligns flex items to the end of the cross axis.
        pub fn items_end(self: Self) Self {
            self.style().align_items = .flex_end;
            return self;
        }

        /// Aligns flex items along the center of the cross axis.
        pub fn items_center(self: Self) Self {
            self.style().align_items = .center;
            return self;
        }

        /// Aligns flex items along the baseline of the cross axis.
        pub fn items_baseline(self: Self) Self {
            self.style().align_items = .baseline;
            return self;
        }

        /// Stretches flex items along the cross axis.
        pub fn items_stretch(self: Self) Self {
            self.style().align_items = .stretch;
            return self;
        }

        /// Aligns this element to the start of the container's cross axis.
        pub fn self_start(self: Self) Self {
            self.style().align_self = .start;
            return self;
        }

        /// Aligns this element to the end of the container's cross axis.
        pub fn self_end(self: Self) Self {
            self.style().align_self = .end;
            return self;
        }

        /// Aligns this element to the flex start of the cross axis.
        pub fn self_flex_start(self: Self) Self {
            self.style().align_self = .flex_start;
            return self;
        }

        /// Aligns this element to the flex end of the cross axis.
        pub fn self_flex_end(self: Self) Self {
            self.style().align_self = .flex_end;
            return self;
        }

        /// Aligns this element along the center of the cross axis.
        pub fn self_center(self: Self) Self {
            self.style().align_self = .center;
            return self;
        }

        /// Aligns this element along the baseline of the cross axis.
        pub fn self_baseline(self: Self) Self {
            self.style().align_self = .baseline;
            return self;
        }

        /// Stretches this element along the cross axis.
        pub fn self_stretch(self: Self) Self {
            self.style().align_self = .stretch;
            return self;
        }

        /// Justifies flex items against the start of the main axis.
        pub fn justify_start(self: Self) Self {
            self.style().justify_content = .start;
            return self;
        }

        /// Justifies flex items against the end of the main axis.
        pub fn justify_end(self: Self) Self {
            self.style().justify_content = .end;
            return self;
        }

        /// Justifies flex items along the center of the main axis.
        pub fn justify_center(self: Self) Self {
            self.style().justify_content = .center;
            return self;
        }

        /// Justifies flex items with equal space between them.
        pub fn justify_between(self: Self) Self {
            self.style().justify_content = .space_between;
            return self;
        }

        /// Justifies flex items with equal space on each side of each item.
        pub fn justify_around(self: Self) Self {
            self.style().justify_content = .space_around;
            return self;
        }

        /// Justifies flex items with equal space around each item, including the edges.
        pub fn justify_evenly(self: Self) Self {
            self.style().justify_content = .space_evenly;
            return self;
        }

        /// Packs content items in their default position.
        pub fn content_normal(self: Self) Self {
            self.style().align_content = null;
            return self;
        }

        /// Packs content items in the center of the cross axis.
        pub fn content_center(self: Self) Self {
            self.style().align_content = .center;
            return self;
        }

        /// Packs content items against the start of the cross axis.
        pub fn content_start(self: Self) Self {
            self.style().align_content = .flex_start;
            return self;
        }

        /// Packs content items against the end of the cross axis.
        pub fn content_end(self: Self) Self {
            self.style().align_content = .flex_end;
            return self;
        }

        /// Packs content items with equal space between them.
        pub fn content_between(self: Self) Self {
            self.style().align_content = .space_between;
            return self;
        }

        /// Packs content items with equal space on each side.
        pub fn content_around(self: Self) Self {
            self.style().align_content = .space_around;
            return self;
        }

        /// Packs content items with equal space between each item.
        pub fn content_evenly(self: Self) Self {
            self.style().align_content = .space_evenly;
            return self;
        }

        /// Lets content items fill the available cross axis space.
        pub fn content_stretch(self: Self) Self {
            self.style().align_content = .stretch;
            return self;
        }

        /// Sets the aspect ratio of the element.
        pub fn aspect_ratio(self: Self, ratio: f32) Self {
            self.style().aspect_ratio = ratio;
            return self;
        }

        /// Sets the aspect ratio of the element to 1/1.
        pub fn aspect_square(self: Self) Self {
            self.style().aspect_ratio = 1.0;
            return self;
        }

        /// Sets the background of the element.
        pub fn bg(self: Self, fill: anytype) Self {
            self.style().background = style.to_fill(fill);
            return self;
        }

        /// Sets the border style of the element to dashed.
        pub fn border_dashed(self: Self) Self {
            self.style().border_style = .dashed;
            return self;
        }

        /// Sets the border color of the element.
        pub fn border_color(self: Self, c: anytype) Self {
            self.style().border_color = color.to_hsla(c);
            return self;
        }

        /// Sets the text color of this element. Cascades to children.
        pub fn text_color(self: Self, c: anytype) Self {
            text_style(self).color = color.to_hsla(c);
            return self;
        }

        /// Sets the font weight of this element. Cascades to children.
        pub fn font_weight(self: Self, weight: style.FontWeight) Self {
            text_style(self).font_weight = weight;
            return self;
        }

        /// Sets the background color of this element. Cascades to children.
        pub fn text_bg(self: Self, c: anytype) Self {
            text_style(self).background_color = color.to_hsla(c);
            return self;
        }

        /// Sets the text size of this element. Cascades to children.
        pub fn text_size(self: Self, value: anytype) Self {
            text_style(self).font_size = geometry.to_absolute_length(value);
            return self;
        }

        /// Sets the text size to 'extra small'.
        pub fn text_xs(self: Self) Self {
            text_style(self).font_size = abs_rem(0.75);
            return self;
        }

        /// Sets the text size to 'small'.
        pub fn text_sm(self: Self) Self {
            text_style(self).font_size = abs_rem(0.875);
            return self;
        }

        /// Sets the text size to 'base'.
        pub fn text_base(self: Self) Self {
            text_style(self).font_size = abs_rem(1.0);
            return self;
        }

        /// Sets the text size to 'large'.
        pub fn text_lg(self: Self) Self {
            text_style(self).font_size = abs_rem(1.125);
            return self;
        }

        /// Sets the text size to 'extra large'.
        pub fn text_xl(self: Self) Self {
            text_style(self).font_size = abs_rem(1.25);
            return self;
        }

        /// Sets the text size to 'extra extra large'.
        pub fn text_2xl(self: Self) Self {
            text_style(self).font_size = abs_rem(1.5);
            return self;
        }

        /// Sets the text size to 'extra extra extra large'.
        pub fn text_3xl(self: Self) Self {
            text_style(self).font_size = abs_rem(1.875);
            return self;
        }

        /// Sets the font style of the element to italic.
        pub fn italic(self: Self) Self {
            text_style(self).font_style = .italic;
            return self;
        }

        /// Sets the font style of the element to normal (not italic).
        pub fn not_italic(self: Self) Self {
            text_style(self).font_style = .normal;
            return self;
        }

        /// Sets the text decoration to underline.
        pub fn underline(self: Self) Self {
            text_style(self).underline = .{ .thickness = geometry.px(1.0) };
            return self;
        }

        /// Sets the text decoration to a line through the text.
        pub fn line_through(self: Self) Self {
            text_style(self).strikethrough = .{ .thickness = geometry.px(1.0) };
            return self;
        }

        /// Removes the text decoration on this element.
        pub fn text_decoration_none(self: Self) Self {
            text_style(self).underline = null;
            return self;
        }

        /// Sets the color of the underline on this element.
        pub fn text_decoration_color(self: Self, c: anytype) Self {
            underline_mut(text_style(self)).color = color.to_hsla(c);
            return self;
        }

        /// Sets the text decoration style to a solid line.
        pub fn text_decoration_solid(self: Self) Self {
            underline_mut(text_style(self)).wavy = false;
            return self;
        }

        /// Sets the text decoration style to a wavy line.
        pub fn text_decoration_wavy(self: Self) Self {
            underline_mut(text_style(self)).wavy = true;
            return self;
        }

        /// Sets the text decoration to be 0px thick.
        pub fn text_decoration_0(self: Self) Self {
            underline_mut(text_style(self)).thickness = geometry.px(0.0);
            return self;
        }

        /// Sets the text decoration to be 1px thick.
        pub fn text_decoration_1(self: Self) Self {
            underline_mut(text_style(self)).thickness = geometry.px(1.0);
            return self;
        }

        /// Sets the text decoration to be 2px thick.
        pub fn text_decoration_2(self: Self) Self {
            underline_mut(text_style(self)).thickness = geometry.px(2.0);
            return self;
        }

        /// Sets the text decoration to be 4px thick.
        pub fn text_decoration_4(self: Self) Self {
            underline_mut(text_style(self)).thickness = geometry.px(4.0);
            return self;
        }

        /// Sets the text decoration to be 8px thick.
        pub fn text_decoration_8(self: Self) Self {
            underline_mut(text_style(self)).thickness = geometry.px(8.0);
            return self;
        }

        /// Sets the font family of this element and its children.
        pub fn font_family(self: Self, family_name: []const u8) Self {
            text_style(self).font_family = family_name;
            return self;
        }

        /// Sets the font features of this element and its children.
        pub fn font_features(self: Self, features: style.FontFeatures) Self {
            text_style(self).font_features = features;
            return self;
        }

        /// Sets the font of this element and its children.
        pub fn font(self: Self, f: style.Font) Self {
            const t = text_style(self);
            t.font_family = f.family;
            t.font_features = f.features;
            t.font_weight = f.weight;
            t.font_style = f.style;
            t.font_fallbacks = f.fallbacks;
            return self;
        }

        /// Sets the line height of this element and its children.
        pub fn line_height(self: Self, lh: anytype) Self {
            text_style(self).line_height = geometry.to_definite_length(lh);
            return self;
        }

        /// Sets the opacity of this element and its children.
        pub fn opacity(self: Self, value: f32) Self {
            self.style().opacity = value;
            return self;
        }

        /// Sets the grid columns of this element.
        pub fn grid_cols(self: Self, cols: u16) Self {
            self.style().grid_cols = .{ .repeat = cols, .min_size = .zero };
            return self;
        }

        /// Sets the grid columns with min-content minimum sizing.
        pub fn grid_cols_min_content(self: Self, cols: u16) Self {
            self.style().grid_cols = .{ .repeat = cols, .min_size = .min_content };
            return self;
        }

        /// Sets the grid columns with max-content maximum sizing.
        pub fn grid_cols_max_content(self: Self, cols: u16) Self {
            self.style().grid_cols = .{ .repeat = cols, .min_size = .max_content };
            return self;
        }

        /// Sets the grid rows of this element.
        pub fn grid_rows(self: Self, rows: u16) Self {
            self.style().grid_rows = .{ .repeat = rows, .min_size = .zero };
            return self;
        }

        /// Sets the grid rows with min-content minimum sizing.
        pub fn grid_rows_min_content(self: Self, rows: u16) Self {
            self.style().grid_rows = .{ .repeat = rows, .min_size = .min_content };
            return self;
        }

        /// Sets the grid rows with max-content maximum sizing.
        pub fn grid_rows_max_content(self: Self, rows: u16) Self {
            self.style().grid_rows = .{ .repeat = rows, .min_size = .max_content };
            return self;
        }

        /// Sets the column start of this element.
        pub fn col_start(self: Self, start: i16) Self {
            grid_location_mut(self.style()).column.start = .{ .line = start };
            return self;
        }

        /// Sets the column start of this element to auto.
        pub fn col_start_auto(self: Self) Self {
            grid_location_mut(self.style()).column.start = .auto;
            return self;
        }

        /// Sets the column end of this element.
        pub fn col_end(self: Self, end: i16) Self {
            grid_location_mut(self.style()).column.end = .{ .line = end };
            return self;
        }

        /// Sets the column end of this element to auto.
        pub fn col_end_auto(self: Self) Self {
            grid_location_mut(self.style()).column.end = .auto;
            return self;
        }

        /// Sets the column span of this element.
        pub fn col_span(self: Self, span: u16) Self {
            const loc = grid_location_mut(self.style());
            loc.column.start = .{ .span = span };
            loc.column.end = .{ .span = span };
            return self;
        }

        /// Sets the column span of this element to span all columns.
        pub fn col_span_full(self: Self) Self {
            const loc = grid_location_mut(self.style());
            loc.column.start = .{ .line = 1 };
            loc.column.end = .{ .line = -1 };
            return self;
        }

        /// Sets the row start of this element.
        pub fn row_start(self: Self, start: i16) Self {
            grid_location_mut(self.style()).row.start = .{ .line = start };
            return self;
        }

        /// Sets the row start of this element to auto.
        pub fn row_start_auto(self: Self) Self {
            grid_location_mut(self.style()).row.start = .auto;
            return self;
        }

        /// Sets the row end of this element.
        pub fn row_end(self: Self, end: i16) Self {
            grid_location_mut(self.style()).row.end = .{ .line = end };
            return self;
        }

        /// Sets the row end of this element to auto.
        pub fn row_end_auto(self: Self) Self {
            grid_location_mut(self.style()).row.end = .auto;
            return self;
        }

        /// Sets the row span of this element.
        pub fn row_span(self: Self, span: u16) Self {
            const loc = grid_location_mut(self.style());
            loc.row.start = .{ .span = span };
            loc.row.end = .{ .span = span };
            return self;
        }

        /// Sets the row span of this element to span all rows.
        pub fn row_span_full(self: Self) Self {
            const loc = grid_location_mut(self.style());
            loc.row.start = .{ .line = 1 };
            loc.row.end = .{ .line = -1 };
            return self;
        }

        /// Draws a debug border around this element (debug builds only).
        pub fn debug(self: Self) Self {
            if (builtin.mode == .debug) self.style().debug = true;
            return self;
        }

        /// Draws a debug border on all conforming elements below this element (debug builds only).
        pub fn debug_below(self: Self) Self {
            if (builtin.mode == .debug) self.style().debug_below = true;
            return self;
        }
        /// Sets the visibility of the element to `visible`.
        pub fn visible(self: Self) Self {
            self.style().visibility = .visible;
            return self;
        }

        /// Sets the visibility of the element to `hidden`.
        pub fn invisible(self: Self) Self {
            self.style().visibility = .hidden;
            return self;
        }

        /// Sets the position of the element to `relative`.
        pub fn relative(self: Self) Self {
            self.style().position = .relative;
            return self;
        }

        /// Sets the position of the element to `absolute`.
        pub fn absolute(self: Self) Self {
            self.style().position = .absolute;
            return self;
        }

        /// Sets the behavior of content that overflows the container to be hidden.
        pub fn overflow_hidden(self: Self) Self {
            const s = self.style();
            s.overflow.x = .hidden;
            s.overflow.y = .hidden;
            return self;
        }

        /// Sets the behavior of content that overflows the container on the X axis to be hidden.
        pub fn overflow_x_hidden(self: Self) Self {
            self.style().overflow.x = .hidden;
            return self;
        }

        /// Sets the behavior of content that overflows the container on the Y axis to be hidden.
        pub fn overflow_y_hidden(self: Self) Self {
            self.style().overflow.y = .hidden;
            return self;
        }

        /// Sets the cursor style when hovering over this element.
        pub fn cursor(self: Self, kind: style.CursorStyle) Self {
            self.style().mouse_cursor = kind;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `default`.
        pub fn cursor_default(self: Self) Self {
            self.style().mouse_cursor = .arrow;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `pointer`.
        pub fn cursor_pointer(self: Self) Self {
            self.style().mouse_cursor = .pointing_hand;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `text`.
        pub fn cursor_text(self: Self) Self {
            self.style().mouse_cursor = .i_beam;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `move`.
        pub fn cursor_move(self: Self) Self {
            self.style().mouse_cursor = .closed_hand;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `not-allowed`.
        pub fn cursor_not_allowed(self: Self) Self {
            self.style().mouse_cursor = .operation_not_allowed;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `context-menu`.
        pub fn cursor_context_menu(self: Self) Self {
            self.style().mouse_cursor = .context_menu;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `crosshair`.
        pub fn cursor_crosshair(self: Self) Self {
            self.style().mouse_cursor = .crosshair;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `vertical-text`.
        pub fn cursor_vertical_text(self: Self) Self {
            self.style().mouse_cursor = .i_beam_cursor_for_vertical_layout;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `alias`.
        pub fn cursor_alias(self: Self) Self {
            self.style().mouse_cursor = .drag_link;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `copy`.
        pub fn cursor_copy(self: Self) Self {
            self.style().mouse_cursor = .drag_copy;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `no-drop`.
        pub fn cursor_no_drop(self: Self) Self {
            self.style().mouse_cursor = .operation_not_allowed;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `grab`.
        pub fn cursor_grab(self: Self) Self {
            self.style().mouse_cursor = .open_hand;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `grabbing`.
        pub fn cursor_grabbing(self: Self) Self {
            self.style().mouse_cursor = .closed_hand;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `ew-resize`.
        pub fn cursor_ew_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_left_right;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `ns-resize`.
        pub fn cursor_ns_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_up_down;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `nesw-resize`.
        pub fn cursor_nesw_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_up_right_down_left;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `nwse-resize`.
        pub fn cursor_nwse_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_up_left_down_right;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `col-resize`.
        pub fn cursor_col_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_column;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `row-resize`.
        pub fn cursor_row_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_row;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `n-resize`.
        pub fn cursor_n_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_up;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `e-resize`.
        pub fn cursor_e_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_right;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `s-resize`.
        pub fn cursor_s_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_down;
            return self;
        }

        /// Sets the cursor style when hovering over this element to `w-resize`.
        pub fn cursor_w_resize(self: Self) Self {
            self.style().mouse_cursor = .resize_left;
            return self;
        }

        /// Sets the border width of the element.
        pub fn border(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.top = v;
            s.border_widths.right = v;
            s.border_widths.bottom = v;
            s.border_widths.left = v;
            return self;
        }
        /// Sets the border width of the element to 0px.
        pub fn border_0(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(0.0);
            s.border_widths.right = abs_px(0.0);
            s.border_widths.bottom = abs_px(0.0);
            s.border_widths.left = abs_px(0.0);
            return self;
        }
        /// Sets the border width of the element to 1px.
        pub fn border_1(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(1.0);
            s.border_widths.right = abs_px(1.0);
            s.border_widths.bottom = abs_px(1.0);
            s.border_widths.left = abs_px(1.0);
            return self;
        }
        /// Sets the border width of the element to 2px.
        pub fn border_2(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(2.0);
            s.border_widths.right = abs_px(2.0);
            s.border_widths.bottom = abs_px(2.0);
            s.border_widths.left = abs_px(2.0);
            return self;
        }
        /// Sets the border width of the element to 3px.
        pub fn border_3(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(3.0);
            s.border_widths.right = abs_px(3.0);
            s.border_widths.bottom = abs_px(3.0);
            s.border_widths.left = abs_px(3.0);
            return self;
        }
        /// Sets the border width of the element to 4px.
        pub fn border_4(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(4.0);
            s.border_widths.right = abs_px(4.0);
            s.border_widths.bottom = abs_px(4.0);
            s.border_widths.left = abs_px(4.0);
            return self;
        }
        /// Sets the border width of the element to 5px.
        pub fn border_5(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(5.0);
            s.border_widths.right = abs_px(5.0);
            s.border_widths.bottom = abs_px(5.0);
            s.border_widths.left = abs_px(5.0);
            return self;
        }
        /// Sets the border width of the element to 6px.
        pub fn border_6(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(6.0);
            s.border_widths.right = abs_px(6.0);
            s.border_widths.bottom = abs_px(6.0);
            s.border_widths.left = abs_px(6.0);
            return self;
        }
        /// Sets the border width of the element to 7px.
        pub fn border_7(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(7.0);
            s.border_widths.right = abs_px(7.0);
            s.border_widths.bottom = abs_px(7.0);
            s.border_widths.left = abs_px(7.0);
            return self;
        }
        /// Sets the border width of the element to 8px.
        pub fn border_8(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(8.0);
            s.border_widths.right = abs_px(8.0);
            s.border_widths.bottom = abs_px(8.0);
            s.border_widths.left = abs_px(8.0);
            return self;
        }
        /// Sets the border width of the element to 9px.
        pub fn border_9(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(9.0);
            s.border_widths.right = abs_px(9.0);
            s.border_widths.bottom = abs_px(9.0);
            s.border_widths.left = abs_px(9.0);
            return self;
        }
        /// Sets the border width of the element to 10px.
        pub fn border_10(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(10.0);
            s.border_widths.right = abs_px(10.0);
            s.border_widths.bottom = abs_px(10.0);
            s.border_widths.left = abs_px(10.0);
            return self;
        }
        /// Sets the border width of the element to 11px.
        pub fn border_11(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(11.0);
            s.border_widths.right = abs_px(11.0);
            s.border_widths.bottom = abs_px(11.0);
            s.border_widths.left = abs_px(11.0);
            return self;
        }
        /// Sets the border width of the element to 12px.
        pub fn border_12(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(12.0);
            s.border_widths.right = abs_px(12.0);
            s.border_widths.bottom = abs_px(12.0);
            s.border_widths.left = abs_px(12.0);
            return self;
        }
        /// Sets the border width of the element to 16px.
        pub fn border_16(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(16.0);
            s.border_widths.right = abs_px(16.0);
            s.border_widths.bottom = abs_px(16.0);
            s.border_widths.left = abs_px(16.0);
            return self;
        }
        /// Sets the border width of the element to 20px.
        pub fn border_20(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(20.0);
            s.border_widths.right = abs_px(20.0);
            s.border_widths.bottom = abs_px(20.0);
            s.border_widths.left = abs_px(20.0);
            return self;
        }
        /// Sets the border width of the element to 24px.
        pub fn border_24(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(24.0);
            s.border_widths.right = abs_px(24.0);
            s.border_widths.bottom = abs_px(24.0);
            s.border_widths.left = abs_px(24.0);
            return self;
        }
        /// Sets the border width of the element to 32px.
        pub fn border_32(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(32.0);
            s.border_widths.right = abs_px(32.0);
            s.border_widths.bottom = abs_px(32.0);
            s.border_widths.left = abs_px(32.0);
            return self;
        }

        /// Sets the top border width of the element.
        pub fn border_t(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.top = v;
            return self;
        }
        /// Sets the top border width of the element to 0px.
        pub fn border_t_0(self: Self) Self {
            self.style().border_widths.top = abs_px(0.0);
            return self;
        }
        /// Sets the top border width of the element to 1px.
        pub fn border_t_1(self: Self) Self {
            self.style().border_widths.top = abs_px(1.0);
            return self;
        }
        /// Sets the top border width of the element to 2px.
        pub fn border_t_2(self: Self) Self {
            self.style().border_widths.top = abs_px(2.0);
            return self;
        }
        /// Sets the top border width of the element to 3px.
        pub fn border_t_3(self: Self) Self {
            self.style().border_widths.top = abs_px(3.0);
            return self;
        }
        /// Sets the top border width of the element to 4px.
        pub fn border_t_4(self: Self) Self {
            self.style().border_widths.top = abs_px(4.0);
            return self;
        }
        /// Sets the top border width of the element to 5px.
        pub fn border_t_5(self: Self) Self {
            self.style().border_widths.top = abs_px(5.0);
            return self;
        }
        /// Sets the top border width of the element to 6px.
        pub fn border_t_6(self: Self) Self {
            self.style().border_widths.top = abs_px(6.0);
            return self;
        }
        /// Sets the top border width of the element to 7px.
        pub fn border_t_7(self: Self) Self {
            self.style().border_widths.top = abs_px(7.0);
            return self;
        }
        /// Sets the top border width of the element to 8px.
        pub fn border_t_8(self: Self) Self {
            self.style().border_widths.top = abs_px(8.0);
            return self;
        }
        /// Sets the top border width of the element to 9px.
        pub fn border_t_9(self: Self) Self {
            self.style().border_widths.top = abs_px(9.0);
            return self;
        }
        /// Sets the top border width of the element to 10px.
        pub fn border_t_10(self: Self) Self {
            self.style().border_widths.top = abs_px(10.0);
            return self;
        }
        /// Sets the top border width of the element to 11px.
        pub fn border_t_11(self: Self) Self {
            self.style().border_widths.top = abs_px(11.0);
            return self;
        }
        /// Sets the top border width of the element to 12px.
        pub fn border_t_12(self: Self) Self {
            self.style().border_widths.top = abs_px(12.0);
            return self;
        }
        /// Sets the top border width of the element to 16px.
        pub fn border_t_16(self: Self) Self {
            self.style().border_widths.top = abs_px(16.0);
            return self;
        }
        /// Sets the top border width of the element to 20px.
        pub fn border_t_20(self: Self) Self {
            self.style().border_widths.top = abs_px(20.0);
            return self;
        }
        /// Sets the top border width of the element to 24px.
        pub fn border_t_24(self: Self) Self {
            self.style().border_widths.top = abs_px(24.0);
            return self;
        }
        /// Sets the top border width of the element to 32px.
        pub fn border_t_32(self: Self) Self {
            self.style().border_widths.top = abs_px(32.0);
            return self;
        }

        /// Sets the bottom border width of the element.
        pub fn border_b(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.bottom = v;
            return self;
        }
        /// Sets the bottom border width of the element to 0px.
        pub fn border_b_0(self: Self) Self {
            self.style().border_widths.bottom = abs_px(0.0);
            return self;
        }
        /// Sets the bottom border width of the element to 1px.
        pub fn border_b_1(self: Self) Self {
            self.style().border_widths.bottom = abs_px(1.0);
            return self;
        }
        /// Sets the bottom border width of the element to 2px.
        pub fn border_b_2(self: Self) Self {
            self.style().border_widths.bottom = abs_px(2.0);
            return self;
        }
        /// Sets the bottom border width of the element to 3px.
        pub fn border_b_3(self: Self) Self {
            self.style().border_widths.bottom = abs_px(3.0);
            return self;
        }
        /// Sets the bottom border width of the element to 4px.
        pub fn border_b_4(self: Self) Self {
            self.style().border_widths.bottom = abs_px(4.0);
            return self;
        }
        /// Sets the bottom border width of the element to 5px.
        pub fn border_b_5(self: Self) Self {
            self.style().border_widths.bottom = abs_px(5.0);
            return self;
        }
        /// Sets the bottom border width of the element to 6px.
        pub fn border_b_6(self: Self) Self {
            self.style().border_widths.bottom = abs_px(6.0);
            return self;
        }
        /// Sets the bottom border width of the element to 7px.
        pub fn border_b_7(self: Self) Self {
            self.style().border_widths.bottom = abs_px(7.0);
            return self;
        }
        /// Sets the bottom border width of the element to 8px.
        pub fn border_b_8(self: Self) Self {
            self.style().border_widths.bottom = abs_px(8.0);
            return self;
        }
        /// Sets the bottom border width of the element to 9px.
        pub fn border_b_9(self: Self) Self {
            self.style().border_widths.bottom = abs_px(9.0);
            return self;
        }
        /// Sets the bottom border width of the element to 10px.
        pub fn border_b_10(self: Self) Self {
            self.style().border_widths.bottom = abs_px(10.0);
            return self;
        }
        /// Sets the bottom border width of the element to 11px.
        pub fn border_b_11(self: Self) Self {
            self.style().border_widths.bottom = abs_px(11.0);
            return self;
        }
        /// Sets the bottom border width of the element to 12px.
        pub fn border_b_12(self: Self) Self {
            self.style().border_widths.bottom = abs_px(12.0);
            return self;
        }
        /// Sets the bottom border width of the element to 16px.
        pub fn border_b_16(self: Self) Self {
            self.style().border_widths.bottom = abs_px(16.0);
            return self;
        }
        /// Sets the bottom border width of the element to 20px.
        pub fn border_b_20(self: Self) Self {
            self.style().border_widths.bottom = abs_px(20.0);
            return self;
        }
        /// Sets the bottom border width of the element to 24px.
        pub fn border_b_24(self: Self) Self {
            self.style().border_widths.bottom = abs_px(24.0);
            return self;
        }
        /// Sets the bottom border width of the element to 32px.
        pub fn border_b_32(self: Self) Self {
            self.style().border_widths.bottom = abs_px(32.0);
            return self;
        }

        /// Sets the right border width of the element.
        pub fn border_r(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.right = v;
            return self;
        }
        /// Sets the right border width of the element to 0px.
        pub fn border_r_0(self: Self) Self {
            self.style().border_widths.right = abs_px(0.0);
            return self;
        }
        /// Sets the right border width of the element to 1px.
        pub fn border_r_1(self: Self) Self {
            self.style().border_widths.right = abs_px(1.0);
            return self;
        }
        /// Sets the right border width of the element to 2px.
        pub fn border_r_2(self: Self) Self {
            self.style().border_widths.right = abs_px(2.0);
            return self;
        }
        /// Sets the right border width of the element to 3px.
        pub fn border_r_3(self: Self) Self {
            self.style().border_widths.right = abs_px(3.0);
            return self;
        }
        /// Sets the right border width of the element to 4px.
        pub fn border_r_4(self: Self) Self {
            self.style().border_widths.right = abs_px(4.0);
            return self;
        }
        /// Sets the right border width of the element to 5px.
        pub fn border_r_5(self: Self) Self {
            self.style().border_widths.right = abs_px(5.0);
            return self;
        }
        /// Sets the right border width of the element to 6px.
        pub fn border_r_6(self: Self) Self {
            self.style().border_widths.right = abs_px(6.0);
            return self;
        }
        /// Sets the right border width of the element to 7px.
        pub fn border_r_7(self: Self) Self {
            self.style().border_widths.right = abs_px(7.0);
            return self;
        }
        /// Sets the right border width of the element to 8px.
        pub fn border_r_8(self: Self) Self {
            self.style().border_widths.right = abs_px(8.0);
            return self;
        }
        /// Sets the right border width of the element to 9px.
        pub fn border_r_9(self: Self) Self {
            self.style().border_widths.right = abs_px(9.0);
            return self;
        }
        /// Sets the right border width of the element to 10px.
        pub fn border_r_10(self: Self) Self {
            self.style().border_widths.right = abs_px(10.0);
            return self;
        }
        /// Sets the right border width of the element to 11px.
        pub fn border_r_11(self: Self) Self {
            self.style().border_widths.right = abs_px(11.0);
            return self;
        }
        /// Sets the right border width of the element to 12px.
        pub fn border_r_12(self: Self) Self {
            self.style().border_widths.right = abs_px(12.0);
            return self;
        }
        /// Sets the right border width of the element to 16px.
        pub fn border_r_16(self: Self) Self {
            self.style().border_widths.right = abs_px(16.0);
            return self;
        }
        /// Sets the right border width of the element to 20px.
        pub fn border_r_20(self: Self) Self {
            self.style().border_widths.right = abs_px(20.0);
            return self;
        }
        /// Sets the right border width of the element to 24px.
        pub fn border_r_24(self: Self) Self {
            self.style().border_widths.right = abs_px(24.0);
            return self;
        }
        /// Sets the right border width of the element to 32px.
        pub fn border_r_32(self: Self) Self {
            self.style().border_widths.right = abs_px(32.0);
            return self;
        }

        /// Sets the left border width of the element.
        pub fn border_l(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.left = v;
            return self;
        }
        /// Sets the left border width of the element to 0px.
        pub fn border_l_0(self: Self) Self {
            self.style().border_widths.left = abs_px(0.0);
            return self;
        }
        /// Sets the left border width of the element to 1px.
        pub fn border_l_1(self: Self) Self {
            self.style().border_widths.left = abs_px(1.0);
            return self;
        }
        /// Sets the left border width of the element to 2px.
        pub fn border_l_2(self: Self) Self {
            self.style().border_widths.left = abs_px(2.0);
            return self;
        }
        /// Sets the left border width of the element to 3px.
        pub fn border_l_3(self: Self) Self {
            self.style().border_widths.left = abs_px(3.0);
            return self;
        }
        /// Sets the left border width of the element to 4px.
        pub fn border_l_4(self: Self) Self {
            self.style().border_widths.left = abs_px(4.0);
            return self;
        }
        /// Sets the left border width of the element to 5px.
        pub fn border_l_5(self: Self) Self {
            self.style().border_widths.left = abs_px(5.0);
            return self;
        }
        /// Sets the left border width of the element to 6px.
        pub fn border_l_6(self: Self) Self {
            self.style().border_widths.left = abs_px(6.0);
            return self;
        }
        /// Sets the left border width of the element to 7px.
        pub fn border_l_7(self: Self) Self {
            self.style().border_widths.left = abs_px(7.0);
            return self;
        }
        /// Sets the left border width of the element to 8px.
        pub fn border_l_8(self: Self) Self {
            self.style().border_widths.left = abs_px(8.0);
            return self;
        }
        /// Sets the left border width of the element to 9px.
        pub fn border_l_9(self: Self) Self {
            self.style().border_widths.left = abs_px(9.0);
            return self;
        }
        /// Sets the left border width of the element to 10px.
        pub fn border_l_10(self: Self) Self {
            self.style().border_widths.left = abs_px(10.0);
            return self;
        }
        /// Sets the left border width of the element to 11px.
        pub fn border_l_11(self: Self) Self {
            self.style().border_widths.left = abs_px(11.0);
            return self;
        }
        /// Sets the left border width of the element to 12px.
        pub fn border_l_12(self: Self) Self {
            self.style().border_widths.left = abs_px(12.0);
            return self;
        }
        /// Sets the left border width of the element to 16px.
        pub fn border_l_16(self: Self) Self {
            self.style().border_widths.left = abs_px(16.0);
            return self;
        }
        /// Sets the left border width of the element to 20px.
        pub fn border_l_20(self: Self) Self {
            self.style().border_widths.left = abs_px(20.0);
            return self;
        }
        /// Sets the left border width of the element to 24px.
        pub fn border_l_24(self: Self) Self {
            self.style().border_widths.left = abs_px(24.0);
            return self;
        }
        /// Sets the left border width of the element to 32px.
        pub fn border_l_32(self: Self) Self {
            self.style().border_widths.left = abs_px(32.0);
            return self;
        }

        /// Sets the horizontal border width of the element.
        pub fn border_x(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.left = v;
            s.border_widths.right = v;
            return self;
        }
        /// Sets the horizontal border width of the element to 0px.
        pub fn border_x_0(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(0.0);
            s.border_widths.right = abs_px(0.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 1px.
        pub fn border_x_1(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(1.0);
            s.border_widths.right = abs_px(1.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 2px.
        pub fn border_x_2(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(2.0);
            s.border_widths.right = abs_px(2.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 3px.
        pub fn border_x_3(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(3.0);
            s.border_widths.right = abs_px(3.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 4px.
        pub fn border_x_4(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(4.0);
            s.border_widths.right = abs_px(4.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 5px.
        pub fn border_x_5(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(5.0);
            s.border_widths.right = abs_px(5.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 6px.
        pub fn border_x_6(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(6.0);
            s.border_widths.right = abs_px(6.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 7px.
        pub fn border_x_7(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(7.0);
            s.border_widths.right = abs_px(7.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 8px.
        pub fn border_x_8(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(8.0);
            s.border_widths.right = abs_px(8.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 9px.
        pub fn border_x_9(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(9.0);
            s.border_widths.right = abs_px(9.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 10px.
        pub fn border_x_10(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(10.0);
            s.border_widths.right = abs_px(10.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 11px.
        pub fn border_x_11(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(11.0);
            s.border_widths.right = abs_px(11.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 12px.
        pub fn border_x_12(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(12.0);
            s.border_widths.right = abs_px(12.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 16px.
        pub fn border_x_16(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(16.0);
            s.border_widths.right = abs_px(16.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 20px.
        pub fn border_x_20(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(20.0);
            s.border_widths.right = abs_px(20.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 24px.
        pub fn border_x_24(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(24.0);
            s.border_widths.right = abs_px(24.0);
            return self;
        }
        /// Sets the horizontal border width of the element to 32px.
        pub fn border_x_32(self: Self) Self {
            const s = self.style();
            s.border_widths.left = abs_px(32.0);
            s.border_widths.right = abs_px(32.0);
            return self;
        }

        /// Sets the vertical border width of the element.
        pub fn border_y(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.border_widths.top = v;
            s.border_widths.bottom = v;
            return self;
        }
        /// Sets the vertical border width of the element to 0px.
        pub fn border_y_0(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(0.0);
            s.border_widths.bottom = abs_px(0.0);
            return self;
        }
        /// Sets the vertical border width of the element to 1px.
        pub fn border_y_1(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(1.0);
            s.border_widths.bottom = abs_px(1.0);
            return self;
        }
        /// Sets the vertical border width of the element to 2px.
        pub fn border_y_2(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(2.0);
            s.border_widths.bottom = abs_px(2.0);
            return self;
        }
        /// Sets the vertical border width of the element to 3px.
        pub fn border_y_3(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(3.0);
            s.border_widths.bottom = abs_px(3.0);
            return self;
        }
        /// Sets the vertical border width of the element to 4px.
        pub fn border_y_4(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(4.0);
            s.border_widths.bottom = abs_px(4.0);
            return self;
        }
        /// Sets the vertical border width of the element to 5px.
        pub fn border_y_5(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(5.0);
            s.border_widths.bottom = abs_px(5.0);
            return self;
        }
        /// Sets the vertical border width of the element to 6px.
        pub fn border_y_6(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(6.0);
            s.border_widths.bottom = abs_px(6.0);
            return self;
        }
        /// Sets the vertical border width of the element to 7px.
        pub fn border_y_7(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(7.0);
            s.border_widths.bottom = abs_px(7.0);
            return self;
        }
        /// Sets the vertical border width of the element to 8px.
        pub fn border_y_8(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(8.0);
            s.border_widths.bottom = abs_px(8.0);
            return self;
        }
        /// Sets the vertical border width of the element to 9px.
        pub fn border_y_9(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(9.0);
            s.border_widths.bottom = abs_px(9.0);
            return self;
        }
        /// Sets the vertical border width of the element to 10px.
        pub fn border_y_10(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(10.0);
            s.border_widths.bottom = abs_px(10.0);
            return self;
        }
        /// Sets the vertical border width of the element to 11px.
        pub fn border_y_11(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(11.0);
            s.border_widths.bottom = abs_px(11.0);
            return self;
        }
        /// Sets the vertical border width of the element to 12px.
        pub fn border_y_12(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(12.0);
            s.border_widths.bottom = abs_px(12.0);
            return self;
        }
        /// Sets the vertical border width of the element to 16px.
        pub fn border_y_16(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(16.0);
            s.border_widths.bottom = abs_px(16.0);
            return self;
        }
        /// Sets the vertical border width of the element to 20px.
        pub fn border_y_20(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(20.0);
            s.border_widths.bottom = abs_px(20.0);
            return self;
        }
        /// Sets the vertical border width of the element to 24px.
        pub fn border_y_24(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(24.0);
            s.border_widths.bottom = abs_px(24.0);
            return self;
        }
        /// Sets the vertical border width of the element to 32px.
        pub fn border_y_32(self: Self) Self {
            const s = self.style();
            s.border_widths.top = abs_px(32.0);
            s.border_widths.bottom = abs_px(32.0);
            return self;
        }
        /// Sets the margin of the element.
        pub fn m(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.top = v;
            s.margin.bottom = v;
            s.margin.left = v;
            s.margin.right = v;
            return self;
        }
        /// Sets the margin of the element to 0px.
        pub fn m_0(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(0.0);
            s.margin.bottom = len_px(0.0);
            s.margin.left = len_px(0.0);
            s.margin.right = len_px(0.0);
            return self;
        }
        /// Sets the margin of the element to negative 0px.
        pub fn m_neg_0(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(-0.0);
            s.margin.bottom = len_px(-0.0);
            s.margin.left = len_px(-0.0);
            s.margin.right = len_px(-0.0);
            return self;
        }
        /// Sets the margin of the element to 2px (0.125rem).
        pub fn m_0p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.125);
            s.margin.bottom = len_rem(0.125);
            s.margin.left = len_rem(0.125);
            s.margin.right = len_rem(0.125);
            return self;
        }
        /// Sets the margin of the element to negative 2px (0.125rem).
        pub fn m_neg_0p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.125);
            s.margin.bottom = len_rem(-0.125);
            s.margin.left = len_rem(-0.125);
            s.margin.right = len_rem(-0.125);
            return self;
        }
        /// Sets the margin of the element to 4px (0.25rem).
        pub fn m_1(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.25);
            s.margin.bottom = len_rem(0.25);
            s.margin.left = len_rem(0.25);
            s.margin.right = len_rem(0.25);
            return self;
        }
        /// Sets the margin of the element to negative 4px (0.25rem).
        pub fn m_neg_1(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.25);
            s.margin.bottom = len_rem(-0.25);
            s.margin.left = len_rem(-0.25);
            s.margin.right = len_rem(-0.25);
            return self;
        }
        /// Sets the margin of the element to 6px (0.375rem).
        pub fn m_1p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.375);
            s.margin.bottom = len_rem(0.375);
            s.margin.left = len_rem(0.375);
            s.margin.right = len_rem(0.375);
            return self;
        }
        /// Sets the margin of the element to negative 6px (0.375rem).
        pub fn m_neg_1p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.375);
            s.margin.bottom = len_rem(-0.375);
            s.margin.left = len_rem(-0.375);
            s.margin.right = len_rem(-0.375);
            return self;
        }
        /// Sets the margin of the element to 8px (0.5rem).
        pub fn m_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.5);
            s.margin.bottom = len_rem(0.5);
            s.margin.left = len_rem(0.5);
            s.margin.right = len_rem(0.5);
            return self;
        }
        /// Sets the margin of the element to negative 8px (0.5rem).
        pub fn m_neg_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.5);
            s.margin.bottom = len_rem(-0.5);
            s.margin.left = len_rem(-0.5);
            s.margin.right = len_rem(-0.5);
            return self;
        }
        /// Sets the margin of the element to 10px (0.625rem).
        pub fn m_2p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.625);
            s.margin.bottom = len_rem(0.625);
            s.margin.left = len_rem(0.625);
            s.margin.right = len_rem(0.625);
            return self;
        }
        /// Sets the margin of the element to negative 10px (0.625rem).
        pub fn m_neg_2p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.625);
            s.margin.bottom = len_rem(-0.625);
            s.margin.left = len_rem(-0.625);
            s.margin.right = len_rem(-0.625);
            return self;
        }
        /// Sets the margin of the element to 12px (0.75rem).
        pub fn m_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.75);
            s.margin.bottom = len_rem(0.75);
            s.margin.left = len_rem(0.75);
            s.margin.right = len_rem(0.75);
            return self;
        }
        /// Sets the margin of the element to negative 12px (0.75rem).
        pub fn m_neg_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.75);
            s.margin.bottom = len_rem(-0.75);
            s.margin.left = len_rem(-0.75);
            s.margin.right = len_rem(-0.75);
            return self;
        }
        /// Sets the margin of the element to 14px (0.875rem).
        pub fn m_3p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.875);
            s.margin.bottom = len_rem(0.875);
            s.margin.left = len_rem(0.875);
            s.margin.right = len_rem(0.875);
            return self;
        }
        /// Sets the margin of the element to negative 14px (0.875rem).
        pub fn m_neg_3p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.875);
            s.margin.bottom = len_rem(-0.875);
            s.margin.left = len_rem(-0.875);
            s.margin.right = len_rem(-0.875);
            return self;
        }
        /// Sets the margin of the element to 16px (1rem).
        pub fn m_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.0);
            s.margin.bottom = len_rem(1.0);
            s.margin.left = len_rem(1.0);
            s.margin.right = len_rem(1.0);
            return self;
        }
        /// Sets the margin of the element to negative 16px (1rem).
        pub fn m_neg_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.0);
            s.margin.bottom = len_rem(-1.0);
            s.margin.left = len_rem(-1.0);
            s.margin.right = len_rem(-1.0);
            return self;
        }
        /// Sets the margin of the element to 20px (1.25rem).
        pub fn m_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.25);
            s.margin.bottom = len_rem(1.25);
            s.margin.left = len_rem(1.25);
            s.margin.right = len_rem(1.25);
            return self;
        }
        /// Sets the margin of the element to negative 20px (1.25rem).
        pub fn m_neg_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.25);
            s.margin.bottom = len_rem(-1.25);
            s.margin.left = len_rem(-1.25);
            s.margin.right = len_rem(-1.25);
            return self;
        }
        /// Sets the margin of the element to 24px (1.5rem).
        pub fn m_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.5);
            s.margin.bottom = len_rem(1.5);
            s.margin.left = len_rem(1.5);
            s.margin.right = len_rem(1.5);
            return self;
        }
        /// Sets the margin of the element to negative 24px (1.5rem).
        pub fn m_neg_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.5);
            s.margin.bottom = len_rem(-1.5);
            s.margin.left = len_rem(-1.5);
            s.margin.right = len_rem(-1.5);
            return self;
        }
        /// Sets the margin of the element to 28px (1.75rem).
        pub fn m_7(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.75);
            s.margin.bottom = len_rem(1.75);
            s.margin.left = len_rem(1.75);
            s.margin.right = len_rem(1.75);
            return self;
        }
        /// Sets the margin of the element to negative 28px (1.75rem).
        pub fn m_neg_7(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.75);
            s.margin.bottom = len_rem(-1.75);
            s.margin.left = len_rem(-1.75);
            s.margin.right = len_rem(-1.75);
            return self;
        }
        /// Sets the margin of the element to 32px (2rem).
        pub fn m_8(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.0);
            s.margin.bottom = len_rem(2.0);
            s.margin.left = len_rem(2.0);
            s.margin.right = len_rem(2.0);
            return self;
        }
        /// Sets the margin of the element to negative 32px (2rem).
        pub fn m_neg_8(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.0);
            s.margin.bottom = len_rem(-2.0);
            s.margin.left = len_rem(-2.0);
            s.margin.right = len_rem(-2.0);
            return self;
        }
        /// Sets the margin of the element to 36px (2.25rem).
        pub fn m_9(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.25);
            s.margin.bottom = len_rem(2.25);
            s.margin.left = len_rem(2.25);
            s.margin.right = len_rem(2.25);
            return self;
        }
        /// Sets the margin of the element to negative 36px (2.25rem).
        pub fn m_neg_9(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.25);
            s.margin.bottom = len_rem(-2.25);
            s.margin.left = len_rem(-2.25);
            s.margin.right = len_rem(-2.25);
            return self;
        }
        /// Sets the margin of the element to 40px (2.5rem).
        pub fn m_10(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.5);
            s.margin.bottom = len_rem(2.5);
            s.margin.left = len_rem(2.5);
            s.margin.right = len_rem(2.5);
            return self;
        }
        /// Sets the margin of the element to negative 40px (2.5rem).
        pub fn m_neg_10(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.5);
            s.margin.bottom = len_rem(-2.5);
            s.margin.left = len_rem(-2.5);
            s.margin.right = len_rem(-2.5);
            return self;
        }
        /// Sets the margin of the element to 44px (2.75rem).
        pub fn m_11(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.75);
            s.margin.bottom = len_rem(2.75);
            s.margin.left = len_rem(2.75);
            s.margin.right = len_rem(2.75);
            return self;
        }
        /// Sets the margin of the element to negative 44px (2.75rem).
        pub fn m_neg_11(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.75);
            s.margin.bottom = len_rem(-2.75);
            s.margin.left = len_rem(-2.75);
            s.margin.right = len_rem(-2.75);
            return self;
        }
        /// Sets the margin of the element to 48px (3rem).
        pub fn m_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(3.0);
            s.margin.bottom = len_rem(3.0);
            s.margin.left = len_rem(3.0);
            s.margin.right = len_rem(3.0);
            return self;
        }
        /// Sets the margin of the element to negative 48px (3rem).
        pub fn m_neg_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-3.0);
            s.margin.bottom = len_rem(-3.0);
            s.margin.left = len_rem(-3.0);
            s.margin.right = len_rem(-3.0);
            return self;
        }
        /// Sets the margin of the element to 64px (4rem).
        pub fn m_16(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(4.0);
            s.margin.bottom = len_rem(4.0);
            s.margin.left = len_rem(4.0);
            s.margin.right = len_rem(4.0);
            return self;
        }
        /// Sets the margin of the element to negative 64px (4rem).
        pub fn m_neg_16(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-4.0);
            s.margin.bottom = len_rem(-4.0);
            s.margin.left = len_rem(-4.0);
            s.margin.right = len_rem(-4.0);
            return self;
        }
        /// Sets the margin of the element to 80px (5rem).
        pub fn m_20(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(5.0);
            s.margin.bottom = len_rem(5.0);
            s.margin.left = len_rem(5.0);
            s.margin.right = len_rem(5.0);
            return self;
        }
        /// Sets the margin of the element to negative 80px (5rem).
        pub fn m_neg_20(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-5.0);
            s.margin.bottom = len_rem(-5.0);
            s.margin.left = len_rem(-5.0);
            s.margin.right = len_rem(-5.0);
            return self;
        }
        /// Sets the margin of the element to 96px (6rem).
        pub fn m_24(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(6.0);
            s.margin.bottom = len_rem(6.0);
            s.margin.left = len_rem(6.0);
            s.margin.right = len_rem(6.0);
            return self;
        }
        /// Sets the margin of the element to negative 96px (6rem).
        pub fn m_neg_24(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-6.0);
            s.margin.bottom = len_rem(-6.0);
            s.margin.left = len_rem(-6.0);
            s.margin.right = len_rem(-6.0);
            return self;
        }
        /// Sets the margin of the element to 128px (8rem).
        pub fn m_32(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(8.0);
            s.margin.bottom = len_rem(8.0);
            s.margin.left = len_rem(8.0);
            s.margin.right = len_rem(8.0);
            return self;
        }
        /// Sets the margin of the element to negative 128px (8rem).
        pub fn m_neg_32(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-8.0);
            s.margin.bottom = len_rem(-8.0);
            s.margin.left = len_rem(-8.0);
            s.margin.right = len_rem(-8.0);
            return self;
        }
        /// Sets the margin of the element to 160px (10rem).
        pub fn m_40(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(10.0);
            s.margin.bottom = len_rem(10.0);
            s.margin.left = len_rem(10.0);
            s.margin.right = len_rem(10.0);
            return self;
        }
        /// Sets the margin of the element to negative 160px (10rem).
        pub fn m_neg_40(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-10.0);
            s.margin.bottom = len_rem(-10.0);
            s.margin.left = len_rem(-10.0);
            s.margin.right = len_rem(-10.0);
            return self;
        }
        /// Sets the margin of the element to 192px (12rem).
        pub fn m_48(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(12.0);
            s.margin.bottom = len_rem(12.0);
            s.margin.left = len_rem(12.0);
            s.margin.right = len_rem(12.0);
            return self;
        }
        /// Sets the margin of the element to negative 192px (12rem).
        pub fn m_neg_48(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-12.0);
            s.margin.bottom = len_rem(-12.0);
            s.margin.left = len_rem(-12.0);
            s.margin.right = len_rem(-12.0);
            return self;
        }
        /// Sets the margin of the element to 224px (14rem).
        pub fn m_56(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(14.0);
            s.margin.bottom = len_rem(14.0);
            s.margin.left = len_rem(14.0);
            s.margin.right = len_rem(14.0);
            return self;
        }
        /// Sets the margin of the element to negative 224px (14rem).
        pub fn m_neg_56(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-14.0);
            s.margin.bottom = len_rem(-14.0);
            s.margin.left = len_rem(-14.0);
            s.margin.right = len_rem(-14.0);
            return self;
        }
        /// Sets the margin of the element to 256px (16rem).
        pub fn m_64(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(16.0);
            s.margin.bottom = len_rem(16.0);
            s.margin.left = len_rem(16.0);
            s.margin.right = len_rem(16.0);
            return self;
        }
        /// Sets the margin of the element to negative 256px (16rem).
        pub fn m_neg_64(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-16.0);
            s.margin.bottom = len_rem(-16.0);
            s.margin.left = len_rem(-16.0);
            s.margin.right = len_rem(-16.0);
            return self;
        }
        /// Sets the margin of the element to 288px (18rem).
        pub fn m_72(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(18.0);
            s.margin.bottom = len_rem(18.0);
            s.margin.left = len_rem(18.0);
            s.margin.right = len_rem(18.0);
            return self;
        }
        /// Sets the margin of the element to negative 288px (18rem).
        pub fn m_neg_72(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-18.0);
            s.margin.bottom = len_rem(-18.0);
            s.margin.left = len_rem(-18.0);
            s.margin.right = len_rem(-18.0);
            return self;
        }
        /// Sets the margin of the element to 320px (20rem).
        pub fn m_80(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(20.0);
            s.margin.bottom = len_rem(20.0);
            s.margin.left = len_rem(20.0);
            s.margin.right = len_rem(20.0);
            return self;
        }
        /// Sets the margin of the element to negative 320px (20rem).
        pub fn m_neg_80(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-20.0);
            s.margin.bottom = len_rem(-20.0);
            s.margin.left = len_rem(-20.0);
            s.margin.right = len_rem(-20.0);
            return self;
        }
        /// Sets the margin of the element to 384px (24rem).
        pub fn m_96(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(24.0);
            s.margin.bottom = len_rem(24.0);
            s.margin.left = len_rem(24.0);
            s.margin.right = len_rem(24.0);
            return self;
        }
        /// Sets the margin of the element to negative 384px (24rem).
        pub fn m_neg_96(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-24.0);
            s.margin.bottom = len_rem(-24.0);
            s.margin.left = len_rem(-24.0);
            s.margin.right = len_rem(-24.0);
            return self;
        }
        /// Sets the margin of the element to 448px (28rem).
        pub fn m_112(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(28.0);
            s.margin.bottom = len_rem(28.0);
            s.margin.left = len_rem(28.0);
            s.margin.right = len_rem(28.0);
            return self;
        }
        /// Sets the margin of the element to negative 448px (28rem).
        pub fn m_neg_112(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-28.0);
            s.margin.bottom = len_rem(-28.0);
            s.margin.left = len_rem(-28.0);
            s.margin.right = len_rem(-28.0);
            return self;
        }
        /// Sets the margin of the element to 512px (32rem).
        pub fn m_128(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(32.0);
            s.margin.bottom = len_rem(32.0);
            s.margin.left = len_rem(32.0);
            s.margin.right = len_rem(32.0);
            return self;
        }
        /// Sets the margin of the element to negative 512px (32rem).
        pub fn m_neg_128(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-32.0);
            s.margin.bottom = len_rem(-32.0);
            s.margin.left = len_rem(-32.0);
            s.margin.right = len_rem(-32.0);
            return self;
        }
        /// Sets the margin of the element to auto.
        pub fn m_auto(self: Self) Self {
            const s = self.style();
            s.margin.top = geometry.auto();
            s.margin.bottom = geometry.auto();
            s.margin.left = geometry.auto();
            s.margin.right = geometry.auto();
            return self;
        }
        /// Sets the margin of the element to 1px.
        pub fn m_px(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(1.0);
            s.margin.bottom = len_px(1.0);
            s.margin.left = len_px(1.0);
            s.margin.right = len_px(1.0);
            return self;
        }
        /// Sets the margin of the element to negative 1px.
        pub fn m_neg_px(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(-1.0);
            s.margin.bottom = len_px(-1.0);
            s.margin.left = len_px(-1.0);
            s.margin.right = len_px(-1.0);
            return self;
        }
        /// Sets the margin of the element to 100%.
        pub fn m_full(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(1.0);
            s.margin.bottom = len_rel(1.0);
            s.margin.left = len_rel(1.0);
            s.margin.right = len_rel(1.0);
            return self;
        }
        /// Sets the margin of the element to negative 100%.
        pub fn m_neg_full(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-1.0);
            s.margin.bottom = len_rel(-1.0);
            s.margin.left = len_rel(-1.0);
            s.margin.right = len_rel(-1.0);
            return self;
        }
        /// Sets the margin of the element to 50%.
        pub fn m_1_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.5);
            s.margin.bottom = len_rel(0.5);
            s.margin.left = len_rel(0.5);
            s.margin.right = len_rel(0.5);
            return self;
        }
        /// Sets the margin of the element to negative 50%.
        pub fn m_neg_1_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.5);
            s.margin.bottom = len_rel(-0.5);
            s.margin.left = len_rel(-0.5);
            s.margin.right = len_rel(-0.5);
            return self;
        }
        /// Sets the margin of the element to 33.3333%.
        pub fn m_1_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.3333333333333333);
            s.margin.bottom = len_rel(0.3333333333333333);
            s.margin.left = len_rel(0.3333333333333333);
            s.margin.right = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the margin of the element to negative 33.3333%.
        pub fn m_neg_1_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.3333333333333333);
            s.margin.bottom = len_rel(-0.3333333333333333);
            s.margin.left = len_rel(-0.3333333333333333);
            s.margin.right = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the margin of the element to 66.6667%.
        pub fn m_2_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.6666666666666666);
            s.margin.bottom = len_rel(0.6666666666666666);
            s.margin.left = len_rel(0.6666666666666666);
            s.margin.right = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the margin of the element to negative 66.6667%.
        pub fn m_neg_2_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.6666666666666666);
            s.margin.bottom = len_rel(-0.6666666666666666);
            s.margin.left = len_rel(-0.6666666666666666);
            s.margin.right = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the margin of the element to 25%.
        pub fn m_1_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.25);
            s.margin.bottom = len_rel(0.25);
            s.margin.left = len_rel(0.25);
            s.margin.right = len_rel(0.25);
            return self;
        }
        /// Sets the margin of the element to negative 25%.
        pub fn m_neg_1_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.25);
            s.margin.bottom = len_rel(-0.25);
            s.margin.left = len_rel(-0.25);
            s.margin.right = len_rel(-0.25);
            return self;
        }
        /// Sets the margin of the element to 50%.
        pub fn m_2_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.5);
            s.margin.bottom = len_rel(0.5);
            s.margin.left = len_rel(0.5);
            s.margin.right = len_rel(0.5);
            return self;
        }
        /// Sets the margin of the element to negative 50%.
        pub fn m_neg_2_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.5);
            s.margin.bottom = len_rel(-0.5);
            s.margin.left = len_rel(-0.5);
            s.margin.right = len_rel(-0.5);
            return self;
        }
        /// Sets the margin of the element to 75%.
        pub fn m_3_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.75);
            s.margin.bottom = len_rel(0.75);
            s.margin.left = len_rel(0.75);
            s.margin.right = len_rel(0.75);
            return self;
        }
        /// Sets the margin of the element to negative 75%.
        pub fn m_neg_3_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.75);
            s.margin.bottom = len_rel(-0.75);
            s.margin.left = len_rel(-0.75);
            s.margin.right = len_rel(-0.75);
            return self;
        }
        /// Sets the margin of the element to 20%.
        pub fn m_1_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.2);
            s.margin.bottom = len_rel(0.2);
            s.margin.left = len_rel(0.2);
            s.margin.right = len_rel(0.2);
            return self;
        }
        /// Sets the margin of the element to negative 20%.
        pub fn m_neg_1_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.2);
            s.margin.bottom = len_rel(-0.2);
            s.margin.left = len_rel(-0.2);
            s.margin.right = len_rel(-0.2);
            return self;
        }
        /// Sets the margin of the element to 40%.
        pub fn m_2_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.4);
            s.margin.bottom = len_rel(0.4);
            s.margin.left = len_rel(0.4);
            s.margin.right = len_rel(0.4);
            return self;
        }
        /// Sets the margin of the element to negative 40%.
        pub fn m_neg_2_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.4);
            s.margin.bottom = len_rel(-0.4);
            s.margin.left = len_rel(-0.4);
            s.margin.right = len_rel(-0.4);
            return self;
        }
        /// Sets the margin of the element to 60%.
        pub fn m_3_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.6);
            s.margin.bottom = len_rel(0.6);
            s.margin.left = len_rel(0.6);
            s.margin.right = len_rel(0.6);
            return self;
        }
        /// Sets the margin of the element to negative 60%.
        pub fn m_neg_3_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.6);
            s.margin.bottom = len_rel(-0.6);
            s.margin.left = len_rel(-0.6);
            s.margin.right = len_rel(-0.6);
            return self;
        }
        /// Sets the margin of the element to 80%.
        pub fn m_4_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.8);
            s.margin.bottom = len_rel(0.8);
            s.margin.left = len_rel(0.8);
            s.margin.right = len_rel(0.8);
            return self;
        }
        /// Sets the margin of the element to negative 80%.
        pub fn m_neg_4_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.8);
            s.margin.bottom = len_rel(-0.8);
            s.margin.left = len_rel(-0.8);
            s.margin.right = len_rel(-0.8);
            return self;
        }
        /// Sets the margin of the element to 16.6667%.
        pub fn m_1_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.16666666666666666);
            s.margin.bottom = len_rel(0.16666666666666666);
            s.margin.left = len_rel(0.16666666666666666);
            s.margin.right = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the margin of the element to negative 16.6667%.
        pub fn m_neg_1_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.16666666666666666);
            s.margin.bottom = len_rel(-0.16666666666666666);
            s.margin.left = len_rel(-0.16666666666666666);
            s.margin.right = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the margin of the element to 83.3333%.
        pub fn m_5_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.8333333333333334);
            s.margin.bottom = len_rel(0.8333333333333334);
            s.margin.left = len_rel(0.8333333333333334);
            s.margin.right = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the margin of the element to negative 83.3333%.
        pub fn m_neg_5_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.8333333333333334);
            s.margin.bottom = len_rel(-0.8333333333333334);
            s.margin.left = len_rel(-0.8333333333333334);
            s.margin.right = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the margin of the element to 8.33333%.
        pub fn m_1_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.08333333333333333);
            s.margin.bottom = len_rel(0.08333333333333333);
            s.margin.left = len_rel(0.08333333333333333);
            s.margin.right = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the margin of the element to negative 8.33333%.
        pub fn m_neg_1_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.08333333333333333);
            s.margin.bottom = len_rel(-0.08333333333333333);
            s.margin.left = len_rel(-0.08333333333333333);
            s.margin.right = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the top margin of the element.
        pub fn mt(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.top = v;
            return self;
        }
        /// Sets the top margin of the element to 0px.
        pub fn mt_0(self: Self) Self {
            self.style().margin.top = len_px(0.0);
            return self;
        }
        /// Sets the top margin of the element to negative 0px.
        pub fn mt_neg_0(self: Self) Self {
            self.style().margin.top = len_px(-0.0);
            return self;
        }
        /// Sets the top margin of the element to 2px (0.125rem).
        pub fn mt_0p5(self: Self) Self {
            self.style().margin.top = len_rem(0.125);
            return self;
        }
        /// Sets the top margin of the element to negative 2px (0.125rem).
        pub fn mt_neg_0p5(self: Self) Self {
            self.style().margin.top = len_rem(-0.125);
            return self;
        }
        /// Sets the top margin of the element to 4px (0.25rem).
        pub fn mt_1(self: Self) Self {
            self.style().margin.top = len_rem(0.25);
            return self;
        }
        /// Sets the top margin of the element to negative 4px (0.25rem).
        pub fn mt_neg_1(self: Self) Self {
            self.style().margin.top = len_rem(-0.25);
            return self;
        }
        /// Sets the top margin of the element to 6px (0.375rem).
        pub fn mt_1p5(self: Self) Self {
            self.style().margin.top = len_rem(0.375);
            return self;
        }
        /// Sets the top margin of the element to negative 6px (0.375rem).
        pub fn mt_neg_1p5(self: Self) Self {
            self.style().margin.top = len_rem(-0.375);
            return self;
        }
        /// Sets the top margin of the element to 8px (0.5rem).
        pub fn mt_2(self: Self) Self {
            self.style().margin.top = len_rem(0.5);
            return self;
        }
        /// Sets the top margin of the element to negative 8px (0.5rem).
        pub fn mt_neg_2(self: Self) Self {
            self.style().margin.top = len_rem(-0.5);
            return self;
        }
        /// Sets the top margin of the element to 10px (0.625rem).
        pub fn mt_2p5(self: Self) Self {
            self.style().margin.top = len_rem(0.625);
            return self;
        }
        /// Sets the top margin of the element to negative 10px (0.625rem).
        pub fn mt_neg_2p5(self: Self) Self {
            self.style().margin.top = len_rem(-0.625);
            return self;
        }
        /// Sets the top margin of the element to 12px (0.75rem).
        pub fn mt_3(self: Self) Self {
            self.style().margin.top = len_rem(0.75);
            return self;
        }
        /// Sets the top margin of the element to negative 12px (0.75rem).
        pub fn mt_neg_3(self: Self) Self {
            self.style().margin.top = len_rem(-0.75);
            return self;
        }
        /// Sets the top margin of the element to 14px (0.875rem).
        pub fn mt_3p5(self: Self) Self {
            self.style().margin.top = len_rem(0.875);
            return self;
        }
        /// Sets the top margin of the element to negative 14px (0.875rem).
        pub fn mt_neg_3p5(self: Self) Self {
            self.style().margin.top = len_rem(-0.875);
            return self;
        }
        /// Sets the top margin of the element to 16px (1rem).
        pub fn mt_4(self: Self) Self {
            self.style().margin.top = len_rem(1.0);
            return self;
        }
        /// Sets the top margin of the element to negative 16px (1rem).
        pub fn mt_neg_4(self: Self) Self {
            self.style().margin.top = len_rem(-1.0);
            return self;
        }
        /// Sets the top margin of the element to 20px (1.25rem).
        pub fn mt_5(self: Self) Self {
            self.style().margin.top = len_rem(1.25);
            return self;
        }
        /// Sets the top margin of the element to negative 20px (1.25rem).
        pub fn mt_neg_5(self: Self) Self {
            self.style().margin.top = len_rem(-1.25);
            return self;
        }
        /// Sets the top margin of the element to 24px (1.5rem).
        pub fn mt_6(self: Self) Self {
            self.style().margin.top = len_rem(1.5);
            return self;
        }
        /// Sets the top margin of the element to negative 24px (1.5rem).
        pub fn mt_neg_6(self: Self) Self {
            self.style().margin.top = len_rem(-1.5);
            return self;
        }
        /// Sets the top margin of the element to 28px (1.75rem).
        pub fn mt_7(self: Self) Self {
            self.style().margin.top = len_rem(1.75);
            return self;
        }
        /// Sets the top margin of the element to negative 28px (1.75rem).
        pub fn mt_neg_7(self: Self) Self {
            self.style().margin.top = len_rem(-1.75);
            return self;
        }
        /// Sets the top margin of the element to 32px (2rem).
        pub fn mt_8(self: Self) Self {
            self.style().margin.top = len_rem(2.0);
            return self;
        }
        /// Sets the top margin of the element to negative 32px (2rem).
        pub fn mt_neg_8(self: Self) Self {
            self.style().margin.top = len_rem(-2.0);
            return self;
        }
        /// Sets the top margin of the element to 36px (2.25rem).
        pub fn mt_9(self: Self) Self {
            self.style().margin.top = len_rem(2.25);
            return self;
        }
        /// Sets the top margin of the element to negative 36px (2.25rem).
        pub fn mt_neg_9(self: Self) Self {
            self.style().margin.top = len_rem(-2.25);
            return self;
        }
        /// Sets the top margin of the element to 40px (2.5rem).
        pub fn mt_10(self: Self) Self {
            self.style().margin.top = len_rem(2.5);
            return self;
        }
        /// Sets the top margin of the element to negative 40px (2.5rem).
        pub fn mt_neg_10(self: Self) Self {
            self.style().margin.top = len_rem(-2.5);
            return self;
        }
        /// Sets the top margin of the element to 44px (2.75rem).
        pub fn mt_11(self: Self) Self {
            self.style().margin.top = len_rem(2.75);
            return self;
        }
        /// Sets the top margin of the element to negative 44px (2.75rem).
        pub fn mt_neg_11(self: Self) Self {
            self.style().margin.top = len_rem(-2.75);
            return self;
        }
        /// Sets the top margin of the element to 48px (3rem).
        pub fn mt_12(self: Self) Self {
            self.style().margin.top = len_rem(3.0);
            return self;
        }
        /// Sets the top margin of the element to negative 48px (3rem).
        pub fn mt_neg_12(self: Self) Self {
            self.style().margin.top = len_rem(-3.0);
            return self;
        }
        /// Sets the top margin of the element to 64px (4rem).
        pub fn mt_16(self: Self) Self {
            self.style().margin.top = len_rem(4.0);
            return self;
        }
        /// Sets the top margin of the element to negative 64px (4rem).
        pub fn mt_neg_16(self: Self) Self {
            self.style().margin.top = len_rem(-4.0);
            return self;
        }
        /// Sets the top margin of the element to 80px (5rem).
        pub fn mt_20(self: Self) Self {
            self.style().margin.top = len_rem(5.0);
            return self;
        }
        /// Sets the top margin of the element to negative 80px (5rem).
        pub fn mt_neg_20(self: Self) Self {
            self.style().margin.top = len_rem(-5.0);
            return self;
        }
        /// Sets the top margin of the element to 96px (6rem).
        pub fn mt_24(self: Self) Self {
            self.style().margin.top = len_rem(6.0);
            return self;
        }
        /// Sets the top margin of the element to negative 96px (6rem).
        pub fn mt_neg_24(self: Self) Self {
            self.style().margin.top = len_rem(-6.0);
            return self;
        }
        /// Sets the top margin of the element to 128px (8rem).
        pub fn mt_32(self: Self) Self {
            self.style().margin.top = len_rem(8.0);
            return self;
        }
        /// Sets the top margin of the element to negative 128px (8rem).
        pub fn mt_neg_32(self: Self) Self {
            self.style().margin.top = len_rem(-8.0);
            return self;
        }
        /// Sets the top margin of the element to 160px (10rem).
        pub fn mt_40(self: Self) Self {
            self.style().margin.top = len_rem(10.0);
            return self;
        }
        /// Sets the top margin of the element to negative 160px (10rem).
        pub fn mt_neg_40(self: Self) Self {
            self.style().margin.top = len_rem(-10.0);
            return self;
        }
        /// Sets the top margin of the element to 192px (12rem).
        pub fn mt_48(self: Self) Self {
            self.style().margin.top = len_rem(12.0);
            return self;
        }
        /// Sets the top margin of the element to negative 192px (12rem).
        pub fn mt_neg_48(self: Self) Self {
            self.style().margin.top = len_rem(-12.0);
            return self;
        }
        /// Sets the top margin of the element to 224px (14rem).
        pub fn mt_56(self: Self) Self {
            self.style().margin.top = len_rem(14.0);
            return self;
        }
        /// Sets the top margin of the element to negative 224px (14rem).
        pub fn mt_neg_56(self: Self) Self {
            self.style().margin.top = len_rem(-14.0);
            return self;
        }
        /// Sets the top margin of the element to 256px (16rem).
        pub fn mt_64(self: Self) Self {
            self.style().margin.top = len_rem(16.0);
            return self;
        }
        /// Sets the top margin of the element to negative 256px (16rem).
        pub fn mt_neg_64(self: Self) Self {
            self.style().margin.top = len_rem(-16.0);
            return self;
        }
        /// Sets the top margin of the element to 288px (18rem).
        pub fn mt_72(self: Self) Self {
            self.style().margin.top = len_rem(18.0);
            return self;
        }
        /// Sets the top margin of the element to negative 288px (18rem).
        pub fn mt_neg_72(self: Self) Self {
            self.style().margin.top = len_rem(-18.0);
            return self;
        }
        /// Sets the top margin of the element to 320px (20rem).
        pub fn mt_80(self: Self) Self {
            self.style().margin.top = len_rem(20.0);
            return self;
        }
        /// Sets the top margin of the element to negative 320px (20rem).
        pub fn mt_neg_80(self: Self) Self {
            self.style().margin.top = len_rem(-20.0);
            return self;
        }
        /// Sets the top margin of the element to 384px (24rem).
        pub fn mt_96(self: Self) Self {
            self.style().margin.top = len_rem(24.0);
            return self;
        }
        /// Sets the top margin of the element to negative 384px (24rem).
        pub fn mt_neg_96(self: Self) Self {
            self.style().margin.top = len_rem(-24.0);
            return self;
        }
        /// Sets the top margin of the element to 448px (28rem).
        pub fn mt_112(self: Self) Self {
            self.style().margin.top = len_rem(28.0);
            return self;
        }
        /// Sets the top margin of the element to negative 448px (28rem).
        pub fn mt_neg_112(self: Self) Self {
            self.style().margin.top = len_rem(-28.0);
            return self;
        }
        /// Sets the top margin of the element to 512px (32rem).
        pub fn mt_128(self: Self) Self {
            self.style().margin.top = len_rem(32.0);
            return self;
        }
        /// Sets the top margin of the element to negative 512px (32rem).
        pub fn mt_neg_128(self: Self) Self {
            self.style().margin.top = len_rem(-32.0);
            return self;
        }
        /// Sets the top margin of the element to auto.
        pub fn mt_auto(self: Self) Self {
            self.style().margin.top = geometry.auto();
            return self;
        }
        /// Sets the top margin of the element to 1px.
        pub fn mt_px(self: Self) Self {
            self.style().margin.top = len_px(1.0);
            return self;
        }
        /// Sets the top margin of the element to negative 1px.
        pub fn mt_neg_px(self: Self) Self {
            self.style().margin.top = len_px(-1.0);
            return self;
        }
        /// Sets the top margin of the element to 100%.
        pub fn mt_full(self: Self) Self {
            self.style().margin.top = len_rel(1.0);
            return self;
        }
        /// Sets the top margin of the element to negative 100%.
        pub fn mt_neg_full(self: Self) Self {
            self.style().margin.top = len_rel(-1.0);
            return self;
        }
        /// Sets the top margin of the element to 50%.
        pub fn mt_1_2(self: Self) Self {
            self.style().margin.top = len_rel(0.5);
            return self;
        }
        /// Sets the top margin of the element to negative 50%.
        pub fn mt_neg_1_2(self: Self) Self {
            self.style().margin.top = len_rel(-0.5);
            return self;
        }
        /// Sets the top margin of the element to 33.3333%.
        pub fn mt_1_3(self: Self) Self {
            self.style().margin.top = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the top margin of the element to negative 33.3333%.
        pub fn mt_neg_1_3(self: Self) Self {
            self.style().margin.top = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the top margin of the element to 66.6667%.
        pub fn mt_2_3(self: Self) Self {
            self.style().margin.top = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the top margin of the element to negative 66.6667%.
        pub fn mt_neg_2_3(self: Self) Self {
            self.style().margin.top = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the top margin of the element to 25%.
        pub fn mt_1_4(self: Self) Self {
            self.style().margin.top = len_rel(0.25);
            return self;
        }
        /// Sets the top margin of the element to negative 25%.
        pub fn mt_neg_1_4(self: Self) Self {
            self.style().margin.top = len_rel(-0.25);
            return self;
        }
        /// Sets the top margin of the element to 50%.
        pub fn mt_2_4(self: Self) Self {
            self.style().margin.top = len_rel(0.5);
            return self;
        }
        /// Sets the top margin of the element to negative 50%.
        pub fn mt_neg_2_4(self: Self) Self {
            self.style().margin.top = len_rel(-0.5);
            return self;
        }
        /// Sets the top margin of the element to 75%.
        pub fn mt_3_4(self: Self) Self {
            self.style().margin.top = len_rel(0.75);
            return self;
        }
        /// Sets the top margin of the element to negative 75%.
        pub fn mt_neg_3_4(self: Self) Self {
            self.style().margin.top = len_rel(-0.75);
            return self;
        }
        /// Sets the top margin of the element to 20%.
        pub fn mt_1_5(self: Self) Self {
            self.style().margin.top = len_rel(0.2);
            return self;
        }
        /// Sets the top margin of the element to negative 20%.
        pub fn mt_neg_1_5(self: Self) Self {
            self.style().margin.top = len_rel(-0.2);
            return self;
        }
        /// Sets the top margin of the element to 40%.
        pub fn mt_2_5(self: Self) Self {
            self.style().margin.top = len_rel(0.4);
            return self;
        }
        /// Sets the top margin of the element to negative 40%.
        pub fn mt_neg_2_5(self: Self) Self {
            self.style().margin.top = len_rel(-0.4);
            return self;
        }
        /// Sets the top margin of the element to 60%.
        pub fn mt_3_5(self: Self) Self {
            self.style().margin.top = len_rel(0.6);
            return self;
        }
        /// Sets the top margin of the element to negative 60%.
        pub fn mt_neg_3_5(self: Self) Self {
            self.style().margin.top = len_rel(-0.6);
            return self;
        }
        /// Sets the top margin of the element to 80%.
        pub fn mt_4_5(self: Self) Self {
            self.style().margin.top = len_rel(0.8);
            return self;
        }
        /// Sets the top margin of the element to negative 80%.
        pub fn mt_neg_4_5(self: Self) Self {
            self.style().margin.top = len_rel(-0.8);
            return self;
        }
        /// Sets the top margin of the element to 16.6667%.
        pub fn mt_1_6(self: Self) Self {
            self.style().margin.top = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the top margin of the element to negative 16.6667%.
        pub fn mt_neg_1_6(self: Self) Self {
            self.style().margin.top = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the top margin of the element to 83.3333%.
        pub fn mt_5_6(self: Self) Self {
            self.style().margin.top = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the top margin of the element to negative 83.3333%.
        pub fn mt_neg_5_6(self: Self) Self {
            self.style().margin.top = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the top margin of the element to 8.33333%.
        pub fn mt_1_12(self: Self) Self {
            self.style().margin.top = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the top margin of the element to negative 8.33333%.
        pub fn mt_neg_1_12(self: Self) Self {
            self.style().margin.top = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the bottom margin of the element.
        pub fn mb(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.bottom = v;
            return self;
        }
        /// Sets the bottom margin of the element to 0px.
        pub fn mb_0(self: Self) Self {
            self.style().margin.bottom = len_px(0.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 0px.
        pub fn mb_neg_0(self: Self) Self {
            self.style().margin.bottom = len_px(-0.0);
            return self;
        }
        /// Sets the bottom margin of the element to 2px (0.125rem).
        pub fn mb_0p5(self: Self) Self {
            self.style().margin.bottom = len_rem(0.125);
            return self;
        }
        /// Sets the bottom margin of the element to negative 2px (0.125rem).
        pub fn mb_neg_0p5(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.125);
            return self;
        }
        /// Sets the bottom margin of the element to 4px (0.25rem).
        pub fn mb_1(self: Self) Self {
            self.style().margin.bottom = len_rem(0.25);
            return self;
        }
        /// Sets the bottom margin of the element to negative 4px (0.25rem).
        pub fn mb_neg_1(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.25);
            return self;
        }
        /// Sets the bottom margin of the element to 6px (0.375rem).
        pub fn mb_1p5(self: Self) Self {
            self.style().margin.bottom = len_rem(0.375);
            return self;
        }
        /// Sets the bottom margin of the element to negative 6px (0.375rem).
        pub fn mb_neg_1p5(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.375);
            return self;
        }
        /// Sets the bottom margin of the element to 8px (0.5rem).
        pub fn mb_2(self: Self) Self {
            self.style().margin.bottom = len_rem(0.5);
            return self;
        }
        /// Sets the bottom margin of the element to negative 8px (0.5rem).
        pub fn mb_neg_2(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.5);
            return self;
        }
        /// Sets the bottom margin of the element to 10px (0.625rem).
        pub fn mb_2p5(self: Self) Self {
            self.style().margin.bottom = len_rem(0.625);
            return self;
        }
        /// Sets the bottom margin of the element to negative 10px (0.625rem).
        pub fn mb_neg_2p5(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.625);
            return self;
        }
        /// Sets the bottom margin of the element to 12px (0.75rem).
        pub fn mb_3(self: Self) Self {
            self.style().margin.bottom = len_rem(0.75);
            return self;
        }
        /// Sets the bottom margin of the element to negative 12px (0.75rem).
        pub fn mb_neg_3(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.75);
            return self;
        }
        /// Sets the bottom margin of the element to 14px (0.875rem).
        pub fn mb_3p5(self: Self) Self {
            self.style().margin.bottom = len_rem(0.875);
            return self;
        }
        /// Sets the bottom margin of the element to negative 14px (0.875rem).
        pub fn mb_neg_3p5(self: Self) Self {
            self.style().margin.bottom = len_rem(-0.875);
            return self;
        }
        /// Sets the bottom margin of the element to 16px (1rem).
        pub fn mb_4(self: Self) Self {
            self.style().margin.bottom = len_rem(1.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 16px (1rem).
        pub fn mb_neg_4(self: Self) Self {
            self.style().margin.bottom = len_rem(-1.0);
            return self;
        }
        /// Sets the bottom margin of the element to 20px (1.25rem).
        pub fn mb_5(self: Self) Self {
            self.style().margin.bottom = len_rem(1.25);
            return self;
        }
        /// Sets the bottom margin of the element to negative 20px (1.25rem).
        pub fn mb_neg_5(self: Self) Self {
            self.style().margin.bottom = len_rem(-1.25);
            return self;
        }
        /// Sets the bottom margin of the element to 24px (1.5rem).
        pub fn mb_6(self: Self) Self {
            self.style().margin.bottom = len_rem(1.5);
            return self;
        }
        /// Sets the bottom margin of the element to negative 24px (1.5rem).
        pub fn mb_neg_6(self: Self) Self {
            self.style().margin.bottom = len_rem(-1.5);
            return self;
        }
        /// Sets the bottom margin of the element to 28px (1.75rem).
        pub fn mb_7(self: Self) Self {
            self.style().margin.bottom = len_rem(1.75);
            return self;
        }
        /// Sets the bottom margin of the element to negative 28px (1.75rem).
        pub fn mb_neg_7(self: Self) Self {
            self.style().margin.bottom = len_rem(-1.75);
            return self;
        }
        /// Sets the bottom margin of the element to 32px (2rem).
        pub fn mb_8(self: Self) Self {
            self.style().margin.bottom = len_rem(2.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 32px (2rem).
        pub fn mb_neg_8(self: Self) Self {
            self.style().margin.bottom = len_rem(-2.0);
            return self;
        }
        /// Sets the bottom margin of the element to 36px (2.25rem).
        pub fn mb_9(self: Self) Self {
            self.style().margin.bottom = len_rem(2.25);
            return self;
        }
        /// Sets the bottom margin of the element to negative 36px (2.25rem).
        pub fn mb_neg_9(self: Self) Self {
            self.style().margin.bottom = len_rem(-2.25);
            return self;
        }
        /// Sets the bottom margin of the element to 40px (2.5rem).
        pub fn mb_10(self: Self) Self {
            self.style().margin.bottom = len_rem(2.5);
            return self;
        }
        /// Sets the bottom margin of the element to negative 40px (2.5rem).
        pub fn mb_neg_10(self: Self) Self {
            self.style().margin.bottom = len_rem(-2.5);
            return self;
        }
        /// Sets the bottom margin of the element to 44px (2.75rem).
        pub fn mb_11(self: Self) Self {
            self.style().margin.bottom = len_rem(2.75);
            return self;
        }
        /// Sets the bottom margin of the element to negative 44px (2.75rem).
        pub fn mb_neg_11(self: Self) Self {
            self.style().margin.bottom = len_rem(-2.75);
            return self;
        }
        /// Sets the bottom margin of the element to 48px (3rem).
        pub fn mb_12(self: Self) Self {
            self.style().margin.bottom = len_rem(3.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 48px (3rem).
        pub fn mb_neg_12(self: Self) Self {
            self.style().margin.bottom = len_rem(-3.0);
            return self;
        }
        /// Sets the bottom margin of the element to 64px (4rem).
        pub fn mb_16(self: Self) Self {
            self.style().margin.bottom = len_rem(4.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 64px (4rem).
        pub fn mb_neg_16(self: Self) Self {
            self.style().margin.bottom = len_rem(-4.0);
            return self;
        }
        /// Sets the bottom margin of the element to 80px (5rem).
        pub fn mb_20(self: Self) Self {
            self.style().margin.bottom = len_rem(5.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 80px (5rem).
        pub fn mb_neg_20(self: Self) Self {
            self.style().margin.bottom = len_rem(-5.0);
            return self;
        }
        /// Sets the bottom margin of the element to 96px (6rem).
        pub fn mb_24(self: Self) Self {
            self.style().margin.bottom = len_rem(6.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 96px (6rem).
        pub fn mb_neg_24(self: Self) Self {
            self.style().margin.bottom = len_rem(-6.0);
            return self;
        }
        /// Sets the bottom margin of the element to 128px (8rem).
        pub fn mb_32(self: Self) Self {
            self.style().margin.bottom = len_rem(8.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 128px (8rem).
        pub fn mb_neg_32(self: Self) Self {
            self.style().margin.bottom = len_rem(-8.0);
            return self;
        }
        /// Sets the bottom margin of the element to 160px (10rem).
        pub fn mb_40(self: Self) Self {
            self.style().margin.bottom = len_rem(10.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 160px (10rem).
        pub fn mb_neg_40(self: Self) Self {
            self.style().margin.bottom = len_rem(-10.0);
            return self;
        }
        /// Sets the bottom margin of the element to 192px (12rem).
        pub fn mb_48(self: Self) Self {
            self.style().margin.bottom = len_rem(12.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 192px (12rem).
        pub fn mb_neg_48(self: Self) Self {
            self.style().margin.bottom = len_rem(-12.0);
            return self;
        }
        /// Sets the bottom margin of the element to 224px (14rem).
        pub fn mb_56(self: Self) Self {
            self.style().margin.bottom = len_rem(14.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 224px (14rem).
        pub fn mb_neg_56(self: Self) Self {
            self.style().margin.bottom = len_rem(-14.0);
            return self;
        }
        /// Sets the bottom margin of the element to 256px (16rem).
        pub fn mb_64(self: Self) Self {
            self.style().margin.bottom = len_rem(16.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 256px (16rem).
        pub fn mb_neg_64(self: Self) Self {
            self.style().margin.bottom = len_rem(-16.0);
            return self;
        }
        /// Sets the bottom margin of the element to 288px (18rem).
        pub fn mb_72(self: Self) Self {
            self.style().margin.bottom = len_rem(18.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 288px (18rem).
        pub fn mb_neg_72(self: Self) Self {
            self.style().margin.bottom = len_rem(-18.0);
            return self;
        }
        /// Sets the bottom margin of the element to 320px (20rem).
        pub fn mb_80(self: Self) Self {
            self.style().margin.bottom = len_rem(20.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 320px (20rem).
        pub fn mb_neg_80(self: Self) Self {
            self.style().margin.bottom = len_rem(-20.0);
            return self;
        }
        /// Sets the bottom margin of the element to 384px (24rem).
        pub fn mb_96(self: Self) Self {
            self.style().margin.bottom = len_rem(24.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 384px (24rem).
        pub fn mb_neg_96(self: Self) Self {
            self.style().margin.bottom = len_rem(-24.0);
            return self;
        }
        /// Sets the bottom margin of the element to 448px (28rem).
        pub fn mb_112(self: Self) Self {
            self.style().margin.bottom = len_rem(28.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 448px (28rem).
        pub fn mb_neg_112(self: Self) Self {
            self.style().margin.bottom = len_rem(-28.0);
            return self;
        }
        /// Sets the bottom margin of the element to 512px (32rem).
        pub fn mb_128(self: Self) Self {
            self.style().margin.bottom = len_rem(32.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 512px (32rem).
        pub fn mb_neg_128(self: Self) Self {
            self.style().margin.bottom = len_rem(-32.0);
            return self;
        }
        /// Sets the bottom margin of the element to auto.
        pub fn mb_auto(self: Self) Self {
            self.style().margin.bottom = geometry.auto();
            return self;
        }
        /// Sets the bottom margin of the element to 1px.
        pub fn mb_px(self: Self) Self {
            self.style().margin.bottom = len_px(1.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 1px.
        pub fn mb_neg_px(self: Self) Self {
            self.style().margin.bottom = len_px(-1.0);
            return self;
        }
        /// Sets the bottom margin of the element to 100%.
        pub fn mb_full(self: Self) Self {
            self.style().margin.bottom = len_rel(1.0);
            return self;
        }
        /// Sets the bottom margin of the element to negative 100%.
        pub fn mb_neg_full(self: Self) Self {
            self.style().margin.bottom = len_rel(-1.0);
            return self;
        }
        /// Sets the bottom margin of the element to 50%.
        pub fn mb_1_2(self: Self) Self {
            self.style().margin.bottom = len_rel(0.5);
            return self;
        }
        /// Sets the bottom margin of the element to negative 50%.
        pub fn mb_neg_1_2(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.5);
            return self;
        }
        /// Sets the bottom margin of the element to 33.3333%.
        pub fn mb_1_3(self: Self) Self {
            self.style().margin.bottom = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the bottom margin of the element to negative 33.3333%.
        pub fn mb_neg_1_3(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the bottom margin of the element to 66.6667%.
        pub fn mb_2_3(self: Self) Self {
            self.style().margin.bottom = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the bottom margin of the element to negative 66.6667%.
        pub fn mb_neg_2_3(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the bottom margin of the element to 25%.
        pub fn mb_1_4(self: Self) Self {
            self.style().margin.bottom = len_rel(0.25);
            return self;
        }
        /// Sets the bottom margin of the element to negative 25%.
        pub fn mb_neg_1_4(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.25);
            return self;
        }
        /// Sets the bottom margin of the element to 50%.
        pub fn mb_2_4(self: Self) Self {
            self.style().margin.bottom = len_rel(0.5);
            return self;
        }
        /// Sets the bottom margin of the element to negative 50%.
        pub fn mb_neg_2_4(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.5);
            return self;
        }
        /// Sets the bottom margin of the element to 75%.
        pub fn mb_3_4(self: Self) Self {
            self.style().margin.bottom = len_rel(0.75);
            return self;
        }
        /// Sets the bottom margin of the element to negative 75%.
        pub fn mb_neg_3_4(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.75);
            return self;
        }
        /// Sets the bottom margin of the element to 20%.
        pub fn mb_1_5(self: Self) Self {
            self.style().margin.bottom = len_rel(0.2);
            return self;
        }
        /// Sets the bottom margin of the element to negative 20%.
        pub fn mb_neg_1_5(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.2);
            return self;
        }
        /// Sets the bottom margin of the element to 40%.
        pub fn mb_2_5(self: Self) Self {
            self.style().margin.bottom = len_rel(0.4);
            return self;
        }
        /// Sets the bottom margin of the element to negative 40%.
        pub fn mb_neg_2_5(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.4);
            return self;
        }
        /// Sets the bottom margin of the element to 60%.
        pub fn mb_3_5(self: Self) Self {
            self.style().margin.bottom = len_rel(0.6);
            return self;
        }
        /// Sets the bottom margin of the element to negative 60%.
        pub fn mb_neg_3_5(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.6);
            return self;
        }
        /// Sets the bottom margin of the element to 80%.
        pub fn mb_4_5(self: Self) Self {
            self.style().margin.bottom = len_rel(0.8);
            return self;
        }
        /// Sets the bottom margin of the element to negative 80%.
        pub fn mb_neg_4_5(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.8);
            return self;
        }
        /// Sets the bottom margin of the element to 16.6667%.
        pub fn mb_1_6(self: Self) Self {
            self.style().margin.bottom = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the bottom margin of the element to negative 16.6667%.
        pub fn mb_neg_1_6(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the bottom margin of the element to 83.3333%.
        pub fn mb_5_6(self: Self) Self {
            self.style().margin.bottom = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the bottom margin of the element to negative 83.3333%.
        pub fn mb_neg_5_6(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the bottom margin of the element to 8.33333%.
        pub fn mb_1_12(self: Self) Self {
            self.style().margin.bottom = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the bottom margin of the element to negative 8.33333%.
        pub fn mb_neg_1_12(self: Self) Self {
            self.style().margin.bottom = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the vertical margin of the element.
        pub fn my(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.top = v;
            s.margin.bottom = v;
            return self;
        }
        /// Sets the vertical margin of the element to 0px.
        pub fn my_0(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(0.0);
            s.margin.bottom = len_px(0.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 0px.
        pub fn my_neg_0(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(-0.0);
            s.margin.bottom = len_px(-0.0);
            return self;
        }
        /// Sets the vertical margin of the element to 2px (0.125rem).
        pub fn my_0p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.125);
            s.margin.bottom = len_rem(0.125);
            return self;
        }
        /// Sets the vertical margin of the element to negative 2px (0.125rem).
        pub fn my_neg_0p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.125);
            s.margin.bottom = len_rem(-0.125);
            return self;
        }
        /// Sets the vertical margin of the element to 4px (0.25rem).
        pub fn my_1(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.25);
            s.margin.bottom = len_rem(0.25);
            return self;
        }
        /// Sets the vertical margin of the element to negative 4px (0.25rem).
        pub fn my_neg_1(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.25);
            s.margin.bottom = len_rem(-0.25);
            return self;
        }
        /// Sets the vertical margin of the element to 6px (0.375rem).
        pub fn my_1p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.375);
            s.margin.bottom = len_rem(0.375);
            return self;
        }
        /// Sets the vertical margin of the element to negative 6px (0.375rem).
        pub fn my_neg_1p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.375);
            s.margin.bottom = len_rem(-0.375);
            return self;
        }
        /// Sets the vertical margin of the element to 8px (0.5rem).
        pub fn my_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.5);
            s.margin.bottom = len_rem(0.5);
            return self;
        }
        /// Sets the vertical margin of the element to negative 8px (0.5rem).
        pub fn my_neg_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.5);
            s.margin.bottom = len_rem(-0.5);
            return self;
        }
        /// Sets the vertical margin of the element to 10px (0.625rem).
        pub fn my_2p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.625);
            s.margin.bottom = len_rem(0.625);
            return self;
        }
        /// Sets the vertical margin of the element to negative 10px (0.625rem).
        pub fn my_neg_2p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.625);
            s.margin.bottom = len_rem(-0.625);
            return self;
        }
        /// Sets the vertical margin of the element to 12px (0.75rem).
        pub fn my_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.75);
            s.margin.bottom = len_rem(0.75);
            return self;
        }
        /// Sets the vertical margin of the element to negative 12px (0.75rem).
        pub fn my_neg_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.75);
            s.margin.bottom = len_rem(-0.75);
            return self;
        }
        /// Sets the vertical margin of the element to 14px (0.875rem).
        pub fn my_3p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(0.875);
            s.margin.bottom = len_rem(0.875);
            return self;
        }
        /// Sets the vertical margin of the element to negative 14px (0.875rem).
        pub fn my_neg_3p5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-0.875);
            s.margin.bottom = len_rem(-0.875);
            return self;
        }
        /// Sets the vertical margin of the element to 16px (1rem).
        pub fn my_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.0);
            s.margin.bottom = len_rem(1.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 16px (1rem).
        pub fn my_neg_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.0);
            s.margin.bottom = len_rem(-1.0);
            return self;
        }
        /// Sets the vertical margin of the element to 20px (1.25rem).
        pub fn my_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.25);
            s.margin.bottom = len_rem(1.25);
            return self;
        }
        /// Sets the vertical margin of the element to negative 20px (1.25rem).
        pub fn my_neg_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.25);
            s.margin.bottom = len_rem(-1.25);
            return self;
        }
        /// Sets the vertical margin of the element to 24px (1.5rem).
        pub fn my_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.5);
            s.margin.bottom = len_rem(1.5);
            return self;
        }
        /// Sets the vertical margin of the element to negative 24px (1.5rem).
        pub fn my_neg_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.5);
            s.margin.bottom = len_rem(-1.5);
            return self;
        }
        /// Sets the vertical margin of the element to 28px (1.75rem).
        pub fn my_7(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(1.75);
            s.margin.bottom = len_rem(1.75);
            return self;
        }
        /// Sets the vertical margin of the element to negative 28px (1.75rem).
        pub fn my_neg_7(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-1.75);
            s.margin.bottom = len_rem(-1.75);
            return self;
        }
        /// Sets the vertical margin of the element to 32px (2rem).
        pub fn my_8(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.0);
            s.margin.bottom = len_rem(2.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 32px (2rem).
        pub fn my_neg_8(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.0);
            s.margin.bottom = len_rem(-2.0);
            return self;
        }
        /// Sets the vertical margin of the element to 36px (2.25rem).
        pub fn my_9(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.25);
            s.margin.bottom = len_rem(2.25);
            return self;
        }
        /// Sets the vertical margin of the element to negative 36px (2.25rem).
        pub fn my_neg_9(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.25);
            s.margin.bottom = len_rem(-2.25);
            return self;
        }
        /// Sets the vertical margin of the element to 40px (2.5rem).
        pub fn my_10(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.5);
            s.margin.bottom = len_rem(2.5);
            return self;
        }
        /// Sets the vertical margin of the element to negative 40px (2.5rem).
        pub fn my_neg_10(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.5);
            s.margin.bottom = len_rem(-2.5);
            return self;
        }
        /// Sets the vertical margin of the element to 44px (2.75rem).
        pub fn my_11(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(2.75);
            s.margin.bottom = len_rem(2.75);
            return self;
        }
        /// Sets the vertical margin of the element to negative 44px (2.75rem).
        pub fn my_neg_11(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-2.75);
            s.margin.bottom = len_rem(-2.75);
            return self;
        }
        /// Sets the vertical margin of the element to 48px (3rem).
        pub fn my_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(3.0);
            s.margin.bottom = len_rem(3.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 48px (3rem).
        pub fn my_neg_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-3.0);
            s.margin.bottom = len_rem(-3.0);
            return self;
        }
        /// Sets the vertical margin of the element to 64px (4rem).
        pub fn my_16(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(4.0);
            s.margin.bottom = len_rem(4.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 64px (4rem).
        pub fn my_neg_16(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-4.0);
            s.margin.bottom = len_rem(-4.0);
            return self;
        }
        /// Sets the vertical margin of the element to 80px (5rem).
        pub fn my_20(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(5.0);
            s.margin.bottom = len_rem(5.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 80px (5rem).
        pub fn my_neg_20(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-5.0);
            s.margin.bottom = len_rem(-5.0);
            return self;
        }
        /// Sets the vertical margin of the element to 96px (6rem).
        pub fn my_24(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(6.0);
            s.margin.bottom = len_rem(6.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 96px (6rem).
        pub fn my_neg_24(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-6.0);
            s.margin.bottom = len_rem(-6.0);
            return self;
        }
        /// Sets the vertical margin of the element to 128px (8rem).
        pub fn my_32(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(8.0);
            s.margin.bottom = len_rem(8.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 128px (8rem).
        pub fn my_neg_32(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-8.0);
            s.margin.bottom = len_rem(-8.0);
            return self;
        }
        /// Sets the vertical margin of the element to 160px (10rem).
        pub fn my_40(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(10.0);
            s.margin.bottom = len_rem(10.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 160px (10rem).
        pub fn my_neg_40(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-10.0);
            s.margin.bottom = len_rem(-10.0);
            return self;
        }
        /// Sets the vertical margin of the element to 192px (12rem).
        pub fn my_48(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(12.0);
            s.margin.bottom = len_rem(12.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 192px (12rem).
        pub fn my_neg_48(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-12.0);
            s.margin.bottom = len_rem(-12.0);
            return self;
        }
        /// Sets the vertical margin of the element to 224px (14rem).
        pub fn my_56(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(14.0);
            s.margin.bottom = len_rem(14.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 224px (14rem).
        pub fn my_neg_56(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-14.0);
            s.margin.bottom = len_rem(-14.0);
            return self;
        }
        /// Sets the vertical margin of the element to 256px (16rem).
        pub fn my_64(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(16.0);
            s.margin.bottom = len_rem(16.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 256px (16rem).
        pub fn my_neg_64(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-16.0);
            s.margin.bottom = len_rem(-16.0);
            return self;
        }
        /// Sets the vertical margin of the element to 288px (18rem).
        pub fn my_72(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(18.0);
            s.margin.bottom = len_rem(18.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 288px (18rem).
        pub fn my_neg_72(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-18.0);
            s.margin.bottom = len_rem(-18.0);
            return self;
        }
        /// Sets the vertical margin of the element to 320px (20rem).
        pub fn my_80(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(20.0);
            s.margin.bottom = len_rem(20.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 320px (20rem).
        pub fn my_neg_80(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-20.0);
            s.margin.bottom = len_rem(-20.0);
            return self;
        }
        /// Sets the vertical margin of the element to 384px (24rem).
        pub fn my_96(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(24.0);
            s.margin.bottom = len_rem(24.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 384px (24rem).
        pub fn my_neg_96(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-24.0);
            s.margin.bottom = len_rem(-24.0);
            return self;
        }
        /// Sets the vertical margin of the element to 448px (28rem).
        pub fn my_112(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(28.0);
            s.margin.bottom = len_rem(28.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 448px (28rem).
        pub fn my_neg_112(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-28.0);
            s.margin.bottom = len_rem(-28.0);
            return self;
        }
        /// Sets the vertical margin of the element to 512px (32rem).
        pub fn my_128(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(32.0);
            s.margin.bottom = len_rem(32.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 512px (32rem).
        pub fn my_neg_128(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rem(-32.0);
            s.margin.bottom = len_rem(-32.0);
            return self;
        }
        /// Sets the vertical margin of the element to auto.
        pub fn my_auto(self: Self) Self {
            const s = self.style();
            s.margin.top = geometry.auto();
            s.margin.bottom = geometry.auto();
            return self;
        }
        /// Sets the vertical margin of the element to 1px.
        pub fn my_px(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(1.0);
            s.margin.bottom = len_px(1.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 1px.
        pub fn my_neg_px(self: Self) Self {
            const s = self.style();
            s.margin.top = len_px(-1.0);
            s.margin.bottom = len_px(-1.0);
            return self;
        }
        /// Sets the vertical margin of the element to 100%.
        pub fn my_full(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(1.0);
            s.margin.bottom = len_rel(1.0);
            return self;
        }
        /// Sets the vertical margin of the element to negative 100%.
        pub fn my_neg_full(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-1.0);
            s.margin.bottom = len_rel(-1.0);
            return self;
        }
        /// Sets the vertical margin of the element to 50%.
        pub fn my_1_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.5);
            s.margin.bottom = len_rel(0.5);
            return self;
        }
        /// Sets the vertical margin of the element to negative 50%.
        pub fn my_neg_1_2(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.5);
            s.margin.bottom = len_rel(-0.5);
            return self;
        }
        /// Sets the vertical margin of the element to 33.3333%.
        pub fn my_1_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.3333333333333333);
            s.margin.bottom = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the vertical margin of the element to negative 33.3333%.
        pub fn my_neg_1_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.3333333333333333);
            s.margin.bottom = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the vertical margin of the element to 66.6667%.
        pub fn my_2_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.6666666666666666);
            s.margin.bottom = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the vertical margin of the element to negative 66.6667%.
        pub fn my_neg_2_3(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.6666666666666666);
            s.margin.bottom = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the vertical margin of the element to 25%.
        pub fn my_1_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.25);
            s.margin.bottom = len_rel(0.25);
            return self;
        }
        /// Sets the vertical margin of the element to negative 25%.
        pub fn my_neg_1_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.25);
            s.margin.bottom = len_rel(-0.25);
            return self;
        }
        /// Sets the vertical margin of the element to 50%.
        pub fn my_2_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.5);
            s.margin.bottom = len_rel(0.5);
            return self;
        }
        /// Sets the vertical margin of the element to negative 50%.
        pub fn my_neg_2_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.5);
            s.margin.bottom = len_rel(-0.5);
            return self;
        }
        /// Sets the vertical margin of the element to 75%.
        pub fn my_3_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.75);
            s.margin.bottom = len_rel(0.75);
            return self;
        }
        /// Sets the vertical margin of the element to negative 75%.
        pub fn my_neg_3_4(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.75);
            s.margin.bottom = len_rel(-0.75);
            return self;
        }
        /// Sets the vertical margin of the element to 20%.
        pub fn my_1_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.2);
            s.margin.bottom = len_rel(0.2);
            return self;
        }
        /// Sets the vertical margin of the element to negative 20%.
        pub fn my_neg_1_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.2);
            s.margin.bottom = len_rel(-0.2);
            return self;
        }
        /// Sets the vertical margin of the element to 40%.
        pub fn my_2_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.4);
            s.margin.bottom = len_rel(0.4);
            return self;
        }
        /// Sets the vertical margin of the element to negative 40%.
        pub fn my_neg_2_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.4);
            s.margin.bottom = len_rel(-0.4);
            return self;
        }
        /// Sets the vertical margin of the element to 60%.
        pub fn my_3_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.6);
            s.margin.bottom = len_rel(0.6);
            return self;
        }
        /// Sets the vertical margin of the element to negative 60%.
        pub fn my_neg_3_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.6);
            s.margin.bottom = len_rel(-0.6);
            return self;
        }
        /// Sets the vertical margin of the element to 80%.
        pub fn my_4_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.8);
            s.margin.bottom = len_rel(0.8);
            return self;
        }
        /// Sets the vertical margin of the element to negative 80%.
        pub fn my_neg_4_5(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.8);
            s.margin.bottom = len_rel(-0.8);
            return self;
        }
        /// Sets the vertical margin of the element to 16.6667%.
        pub fn my_1_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.16666666666666666);
            s.margin.bottom = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the vertical margin of the element to negative 16.6667%.
        pub fn my_neg_1_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.16666666666666666);
            s.margin.bottom = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the vertical margin of the element to 83.3333%.
        pub fn my_5_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.8333333333333334);
            s.margin.bottom = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the vertical margin of the element to negative 83.3333%.
        pub fn my_neg_5_6(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.8333333333333334);
            s.margin.bottom = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the vertical margin of the element to 8.33333%.
        pub fn my_1_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(0.08333333333333333);
            s.margin.bottom = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the vertical margin of the element to negative 8.33333%.
        pub fn my_neg_1_12(self: Self) Self {
            const s = self.style();
            s.margin.top = len_rel(-0.08333333333333333);
            s.margin.bottom = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the horizontal margin of the element.
        pub fn mx(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.left = v;
            s.margin.right = v;
            return self;
        }
        /// Sets the horizontal margin of the element to 0px.
        pub fn mx_0(self: Self) Self {
            const s = self.style();
            s.margin.left = len_px(0.0);
            s.margin.right = len_px(0.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 0px.
        pub fn mx_neg_0(self: Self) Self {
            const s = self.style();
            s.margin.left = len_px(-0.0);
            s.margin.right = len_px(-0.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 2px (0.125rem).
        pub fn mx_0p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.125);
            s.margin.right = len_rem(0.125);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 2px (0.125rem).
        pub fn mx_neg_0p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.125);
            s.margin.right = len_rem(-0.125);
            return self;
        }
        /// Sets the horizontal margin of the element to 4px (0.25rem).
        pub fn mx_1(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.25);
            s.margin.right = len_rem(0.25);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 4px (0.25rem).
        pub fn mx_neg_1(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.25);
            s.margin.right = len_rem(-0.25);
            return self;
        }
        /// Sets the horizontal margin of the element to 6px (0.375rem).
        pub fn mx_1p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.375);
            s.margin.right = len_rem(0.375);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 6px (0.375rem).
        pub fn mx_neg_1p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.375);
            s.margin.right = len_rem(-0.375);
            return self;
        }
        /// Sets the horizontal margin of the element to 8px (0.5rem).
        pub fn mx_2(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.5);
            s.margin.right = len_rem(0.5);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 8px (0.5rem).
        pub fn mx_neg_2(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.5);
            s.margin.right = len_rem(-0.5);
            return self;
        }
        /// Sets the horizontal margin of the element to 10px (0.625rem).
        pub fn mx_2p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.625);
            s.margin.right = len_rem(0.625);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 10px (0.625rem).
        pub fn mx_neg_2p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.625);
            s.margin.right = len_rem(-0.625);
            return self;
        }
        /// Sets the horizontal margin of the element to 12px (0.75rem).
        pub fn mx_3(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.75);
            s.margin.right = len_rem(0.75);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 12px (0.75rem).
        pub fn mx_neg_3(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.75);
            s.margin.right = len_rem(-0.75);
            return self;
        }
        /// Sets the horizontal margin of the element to 14px (0.875rem).
        pub fn mx_3p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(0.875);
            s.margin.right = len_rem(0.875);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 14px (0.875rem).
        pub fn mx_neg_3p5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-0.875);
            s.margin.right = len_rem(-0.875);
            return self;
        }
        /// Sets the horizontal margin of the element to 16px (1rem).
        pub fn mx_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(1.0);
            s.margin.right = len_rem(1.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 16px (1rem).
        pub fn mx_neg_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-1.0);
            s.margin.right = len_rem(-1.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 20px (1.25rem).
        pub fn mx_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(1.25);
            s.margin.right = len_rem(1.25);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 20px (1.25rem).
        pub fn mx_neg_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-1.25);
            s.margin.right = len_rem(-1.25);
            return self;
        }
        /// Sets the horizontal margin of the element to 24px (1.5rem).
        pub fn mx_6(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(1.5);
            s.margin.right = len_rem(1.5);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 24px (1.5rem).
        pub fn mx_neg_6(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-1.5);
            s.margin.right = len_rem(-1.5);
            return self;
        }
        /// Sets the horizontal margin of the element to 28px (1.75rem).
        pub fn mx_7(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(1.75);
            s.margin.right = len_rem(1.75);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 28px (1.75rem).
        pub fn mx_neg_7(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-1.75);
            s.margin.right = len_rem(-1.75);
            return self;
        }
        /// Sets the horizontal margin of the element to 32px (2rem).
        pub fn mx_8(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(2.0);
            s.margin.right = len_rem(2.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 32px (2rem).
        pub fn mx_neg_8(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-2.0);
            s.margin.right = len_rem(-2.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 36px (2.25rem).
        pub fn mx_9(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(2.25);
            s.margin.right = len_rem(2.25);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 36px (2.25rem).
        pub fn mx_neg_9(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-2.25);
            s.margin.right = len_rem(-2.25);
            return self;
        }
        /// Sets the horizontal margin of the element to 40px (2.5rem).
        pub fn mx_10(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(2.5);
            s.margin.right = len_rem(2.5);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 40px (2.5rem).
        pub fn mx_neg_10(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-2.5);
            s.margin.right = len_rem(-2.5);
            return self;
        }
        /// Sets the horizontal margin of the element to 44px (2.75rem).
        pub fn mx_11(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(2.75);
            s.margin.right = len_rem(2.75);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 44px (2.75rem).
        pub fn mx_neg_11(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-2.75);
            s.margin.right = len_rem(-2.75);
            return self;
        }
        /// Sets the horizontal margin of the element to 48px (3rem).
        pub fn mx_12(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(3.0);
            s.margin.right = len_rem(3.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 48px (3rem).
        pub fn mx_neg_12(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-3.0);
            s.margin.right = len_rem(-3.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 64px (4rem).
        pub fn mx_16(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(4.0);
            s.margin.right = len_rem(4.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 64px (4rem).
        pub fn mx_neg_16(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-4.0);
            s.margin.right = len_rem(-4.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 80px (5rem).
        pub fn mx_20(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(5.0);
            s.margin.right = len_rem(5.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 80px (5rem).
        pub fn mx_neg_20(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-5.0);
            s.margin.right = len_rem(-5.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 96px (6rem).
        pub fn mx_24(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(6.0);
            s.margin.right = len_rem(6.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 96px (6rem).
        pub fn mx_neg_24(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-6.0);
            s.margin.right = len_rem(-6.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 128px (8rem).
        pub fn mx_32(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(8.0);
            s.margin.right = len_rem(8.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 128px (8rem).
        pub fn mx_neg_32(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-8.0);
            s.margin.right = len_rem(-8.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 160px (10rem).
        pub fn mx_40(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(10.0);
            s.margin.right = len_rem(10.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 160px (10rem).
        pub fn mx_neg_40(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-10.0);
            s.margin.right = len_rem(-10.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 192px (12rem).
        pub fn mx_48(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(12.0);
            s.margin.right = len_rem(12.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 192px (12rem).
        pub fn mx_neg_48(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-12.0);
            s.margin.right = len_rem(-12.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 224px (14rem).
        pub fn mx_56(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(14.0);
            s.margin.right = len_rem(14.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 224px (14rem).
        pub fn mx_neg_56(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-14.0);
            s.margin.right = len_rem(-14.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 256px (16rem).
        pub fn mx_64(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(16.0);
            s.margin.right = len_rem(16.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 256px (16rem).
        pub fn mx_neg_64(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-16.0);
            s.margin.right = len_rem(-16.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 288px (18rem).
        pub fn mx_72(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(18.0);
            s.margin.right = len_rem(18.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 288px (18rem).
        pub fn mx_neg_72(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-18.0);
            s.margin.right = len_rem(-18.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 320px (20rem).
        pub fn mx_80(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(20.0);
            s.margin.right = len_rem(20.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 320px (20rem).
        pub fn mx_neg_80(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-20.0);
            s.margin.right = len_rem(-20.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 384px (24rem).
        pub fn mx_96(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(24.0);
            s.margin.right = len_rem(24.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 384px (24rem).
        pub fn mx_neg_96(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-24.0);
            s.margin.right = len_rem(-24.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 448px (28rem).
        pub fn mx_112(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(28.0);
            s.margin.right = len_rem(28.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 448px (28rem).
        pub fn mx_neg_112(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-28.0);
            s.margin.right = len_rem(-28.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 512px (32rem).
        pub fn mx_128(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(32.0);
            s.margin.right = len_rem(32.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 512px (32rem).
        pub fn mx_neg_128(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rem(-32.0);
            s.margin.right = len_rem(-32.0);
            return self;
        }
        /// Sets the horizontal margin of the element to auto.
        pub fn mx_auto(self: Self) Self {
            const s = self.style();
            s.margin.left = geometry.auto();
            s.margin.right = geometry.auto();
            return self;
        }
        /// Sets the horizontal margin of the element to 1px.
        pub fn mx_px(self: Self) Self {
            const s = self.style();
            s.margin.left = len_px(1.0);
            s.margin.right = len_px(1.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 1px.
        pub fn mx_neg_px(self: Self) Self {
            const s = self.style();
            s.margin.left = len_px(-1.0);
            s.margin.right = len_px(-1.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 100%.
        pub fn mx_full(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(1.0);
            s.margin.right = len_rel(1.0);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 100%.
        pub fn mx_neg_full(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-1.0);
            s.margin.right = len_rel(-1.0);
            return self;
        }
        /// Sets the horizontal margin of the element to 50%.
        pub fn mx_1_2(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.5);
            s.margin.right = len_rel(0.5);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 50%.
        pub fn mx_neg_1_2(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.5);
            s.margin.right = len_rel(-0.5);
            return self;
        }
        /// Sets the horizontal margin of the element to 33.3333%.
        pub fn mx_1_3(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.3333333333333333);
            s.margin.right = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 33.3333%.
        pub fn mx_neg_1_3(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.3333333333333333);
            s.margin.right = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the horizontal margin of the element to 66.6667%.
        pub fn mx_2_3(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.6666666666666666);
            s.margin.right = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 66.6667%.
        pub fn mx_neg_2_3(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.6666666666666666);
            s.margin.right = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the horizontal margin of the element to 25%.
        pub fn mx_1_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.25);
            s.margin.right = len_rel(0.25);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 25%.
        pub fn mx_neg_1_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.25);
            s.margin.right = len_rel(-0.25);
            return self;
        }
        /// Sets the horizontal margin of the element to 50%.
        pub fn mx_2_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.5);
            s.margin.right = len_rel(0.5);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 50%.
        pub fn mx_neg_2_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.5);
            s.margin.right = len_rel(-0.5);
            return self;
        }
        /// Sets the horizontal margin of the element to 75%.
        pub fn mx_3_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.75);
            s.margin.right = len_rel(0.75);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 75%.
        pub fn mx_neg_3_4(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.75);
            s.margin.right = len_rel(-0.75);
            return self;
        }
        /// Sets the horizontal margin of the element to 20%.
        pub fn mx_1_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.2);
            s.margin.right = len_rel(0.2);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 20%.
        pub fn mx_neg_1_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.2);
            s.margin.right = len_rel(-0.2);
            return self;
        }
        /// Sets the horizontal margin of the element to 40%.
        pub fn mx_2_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.4);
            s.margin.right = len_rel(0.4);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 40%.
        pub fn mx_neg_2_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.4);
            s.margin.right = len_rel(-0.4);
            return self;
        }
        /// Sets the horizontal margin of the element to 60%.
        pub fn mx_3_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.6);
            s.margin.right = len_rel(0.6);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 60%.
        pub fn mx_neg_3_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.6);
            s.margin.right = len_rel(-0.6);
            return self;
        }
        /// Sets the horizontal margin of the element to 80%.
        pub fn mx_4_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.8);
            s.margin.right = len_rel(0.8);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 80%.
        pub fn mx_neg_4_5(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.8);
            s.margin.right = len_rel(-0.8);
            return self;
        }
        /// Sets the horizontal margin of the element to 16.6667%.
        pub fn mx_1_6(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.16666666666666666);
            s.margin.right = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 16.6667%.
        pub fn mx_neg_1_6(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.16666666666666666);
            s.margin.right = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the horizontal margin of the element to 83.3333%.
        pub fn mx_5_6(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.8333333333333334);
            s.margin.right = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 83.3333%.
        pub fn mx_neg_5_6(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.8333333333333334);
            s.margin.right = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the horizontal margin of the element to 8.33333%.
        pub fn mx_1_12(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(0.08333333333333333);
            s.margin.right = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the horizontal margin of the element to negative 8.33333%.
        pub fn mx_neg_1_12(self: Self) Self {
            const s = self.style();
            s.margin.left = len_rel(-0.08333333333333333);
            s.margin.right = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the left margin of the element.
        pub fn ml(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.left = v;
            return self;
        }
        /// Sets the left margin of the element to 0px.
        pub fn ml_0(self: Self) Self {
            self.style().margin.left = len_px(0.0);
            return self;
        }
        /// Sets the left margin of the element to negative 0px.
        pub fn ml_neg_0(self: Self) Self {
            self.style().margin.left = len_px(-0.0);
            return self;
        }
        /// Sets the left margin of the element to 2px (0.125rem).
        pub fn ml_0p5(self: Self) Self {
            self.style().margin.left = len_rem(0.125);
            return self;
        }
        /// Sets the left margin of the element to negative 2px (0.125rem).
        pub fn ml_neg_0p5(self: Self) Self {
            self.style().margin.left = len_rem(-0.125);
            return self;
        }
        /// Sets the left margin of the element to 4px (0.25rem).
        pub fn ml_1(self: Self) Self {
            self.style().margin.left = len_rem(0.25);
            return self;
        }
        /// Sets the left margin of the element to negative 4px (0.25rem).
        pub fn ml_neg_1(self: Self) Self {
            self.style().margin.left = len_rem(-0.25);
            return self;
        }
        /// Sets the left margin of the element to 6px (0.375rem).
        pub fn ml_1p5(self: Self) Self {
            self.style().margin.left = len_rem(0.375);
            return self;
        }
        /// Sets the left margin of the element to negative 6px (0.375rem).
        pub fn ml_neg_1p5(self: Self) Self {
            self.style().margin.left = len_rem(-0.375);
            return self;
        }
        /// Sets the left margin of the element to 8px (0.5rem).
        pub fn ml_2(self: Self) Self {
            self.style().margin.left = len_rem(0.5);
            return self;
        }
        /// Sets the left margin of the element to negative 8px (0.5rem).
        pub fn ml_neg_2(self: Self) Self {
            self.style().margin.left = len_rem(-0.5);
            return self;
        }
        /// Sets the left margin of the element to 10px (0.625rem).
        pub fn ml_2p5(self: Self) Self {
            self.style().margin.left = len_rem(0.625);
            return self;
        }
        /// Sets the left margin of the element to negative 10px (0.625rem).
        pub fn ml_neg_2p5(self: Self) Self {
            self.style().margin.left = len_rem(-0.625);
            return self;
        }
        /// Sets the left margin of the element to 12px (0.75rem).
        pub fn ml_3(self: Self) Self {
            self.style().margin.left = len_rem(0.75);
            return self;
        }
        /// Sets the left margin of the element to negative 12px (0.75rem).
        pub fn ml_neg_3(self: Self) Self {
            self.style().margin.left = len_rem(-0.75);
            return self;
        }
        /// Sets the left margin of the element to 14px (0.875rem).
        pub fn ml_3p5(self: Self) Self {
            self.style().margin.left = len_rem(0.875);
            return self;
        }
        /// Sets the left margin of the element to negative 14px (0.875rem).
        pub fn ml_neg_3p5(self: Self) Self {
            self.style().margin.left = len_rem(-0.875);
            return self;
        }
        /// Sets the left margin of the element to 16px (1rem).
        pub fn ml_4(self: Self) Self {
            self.style().margin.left = len_rem(1.0);
            return self;
        }
        /// Sets the left margin of the element to negative 16px (1rem).
        pub fn ml_neg_4(self: Self) Self {
            self.style().margin.left = len_rem(-1.0);
            return self;
        }
        /// Sets the left margin of the element to 20px (1.25rem).
        pub fn ml_5(self: Self) Self {
            self.style().margin.left = len_rem(1.25);
            return self;
        }
        /// Sets the left margin of the element to negative 20px (1.25rem).
        pub fn ml_neg_5(self: Self) Self {
            self.style().margin.left = len_rem(-1.25);
            return self;
        }
        /// Sets the left margin of the element to 24px (1.5rem).
        pub fn ml_6(self: Self) Self {
            self.style().margin.left = len_rem(1.5);
            return self;
        }
        /// Sets the left margin of the element to negative 24px (1.5rem).
        pub fn ml_neg_6(self: Self) Self {
            self.style().margin.left = len_rem(-1.5);
            return self;
        }
        /// Sets the left margin of the element to 28px (1.75rem).
        pub fn ml_7(self: Self) Self {
            self.style().margin.left = len_rem(1.75);
            return self;
        }
        /// Sets the left margin of the element to negative 28px (1.75rem).
        pub fn ml_neg_7(self: Self) Self {
            self.style().margin.left = len_rem(-1.75);
            return self;
        }
        /// Sets the left margin of the element to 32px (2rem).
        pub fn ml_8(self: Self) Self {
            self.style().margin.left = len_rem(2.0);
            return self;
        }
        /// Sets the left margin of the element to negative 32px (2rem).
        pub fn ml_neg_8(self: Self) Self {
            self.style().margin.left = len_rem(-2.0);
            return self;
        }
        /// Sets the left margin of the element to 36px (2.25rem).
        pub fn ml_9(self: Self) Self {
            self.style().margin.left = len_rem(2.25);
            return self;
        }
        /// Sets the left margin of the element to negative 36px (2.25rem).
        pub fn ml_neg_9(self: Self) Self {
            self.style().margin.left = len_rem(-2.25);
            return self;
        }
        /// Sets the left margin of the element to 40px (2.5rem).
        pub fn ml_10(self: Self) Self {
            self.style().margin.left = len_rem(2.5);
            return self;
        }
        /// Sets the left margin of the element to negative 40px (2.5rem).
        pub fn ml_neg_10(self: Self) Self {
            self.style().margin.left = len_rem(-2.5);
            return self;
        }
        /// Sets the left margin of the element to 44px (2.75rem).
        pub fn ml_11(self: Self) Self {
            self.style().margin.left = len_rem(2.75);
            return self;
        }
        /// Sets the left margin of the element to negative 44px (2.75rem).
        pub fn ml_neg_11(self: Self) Self {
            self.style().margin.left = len_rem(-2.75);
            return self;
        }
        /// Sets the left margin of the element to 48px (3rem).
        pub fn ml_12(self: Self) Self {
            self.style().margin.left = len_rem(3.0);
            return self;
        }
        /// Sets the left margin of the element to negative 48px (3rem).
        pub fn ml_neg_12(self: Self) Self {
            self.style().margin.left = len_rem(-3.0);
            return self;
        }
        /// Sets the left margin of the element to 64px (4rem).
        pub fn ml_16(self: Self) Self {
            self.style().margin.left = len_rem(4.0);
            return self;
        }
        /// Sets the left margin of the element to negative 64px (4rem).
        pub fn ml_neg_16(self: Self) Self {
            self.style().margin.left = len_rem(-4.0);
            return self;
        }
        /// Sets the left margin of the element to 80px (5rem).
        pub fn ml_20(self: Self) Self {
            self.style().margin.left = len_rem(5.0);
            return self;
        }
        /// Sets the left margin of the element to negative 80px (5rem).
        pub fn ml_neg_20(self: Self) Self {
            self.style().margin.left = len_rem(-5.0);
            return self;
        }
        /// Sets the left margin of the element to 96px (6rem).
        pub fn ml_24(self: Self) Self {
            self.style().margin.left = len_rem(6.0);
            return self;
        }
        /// Sets the left margin of the element to negative 96px (6rem).
        pub fn ml_neg_24(self: Self) Self {
            self.style().margin.left = len_rem(-6.0);
            return self;
        }
        /// Sets the left margin of the element to 128px (8rem).
        pub fn ml_32(self: Self) Self {
            self.style().margin.left = len_rem(8.0);
            return self;
        }
        /// Sets the left margin of the element to negative 128px (8rem).
        pub fn ml_neg_32(self: Self) Self {
            self.style().margin.left = len_rem(-8.0);
            return self;
        }
        /// Sets the left margin of the element to 160px (10rem).
        pub fn ml_40(self: Self) Self {
            self.style().margin.left = len_rem(10.0);
            return self;
        }
        /// Sets the left margin of the element to negative 160px (10rem).
        pub fn ml_neg_40(self: Self) Self {
            self.style().margin.left = len_rem(-10.0);
            return self;
        }
        /// Sets the left margin of the element to 192px (12rem).
        pub fn ml_48(self: Self) Self {
            self.style().margin.left = len_rem(12.0);
            return self;
        }
        /// Sets the left margin of the element to negative 192px (12rem).
        pub fn ml_neg_48(self: Self) Self {
            self.style().margin.left = len_rem(-12.0);
            return self;
        }
        /// Sets the left margin of the element to 224px (14rem).
        pub fn ml_56(self: Self) Self {
            self.style().margin.left = len_rem(14.0);
            return self;
        }
        /// Sets the left margin of the element to negative 224px (14rem).
        pub fn ml_neg_56(self: Self) Self {
            self.style().margin.left = len_rem(-14.0);
            return self;
        }
        /// Sets the left margin of the element to 256px (16rem).
        pub fn ml_64(self: Self) Self {
            self.style().margin.left = len_rem(16.0);
            return self;
        }
        /// Sets the left margin of the element to negative 256px (16rem).
        pub fn ml_neg_64(self: Self) Self {
            self.style().margin.left = len_rem(-16.0);
            return self;
        }
        /// Sets the left margin of the element to 288px (18rem).
        pub fn ml_72(self: Self) Self {
            self.style().margin.left = len_rem(18.0);
            return self;
        }
        /// Sets the left margin of the element to negative 288px (18rem).
        pub fn ml_neg_72(self: Self) Self {
            self.style().margin.left = len_rem(-18.0);
            return self;
        }
        /// Sets the left margin of the element to 320px (20rem).
        pub fn ml_80(self: Self) Self {
            self.style().margin.left = len_rem(20.0);
            return self;
        }
        /// Sets the left margin of the element to negative 320px (20rem).
        pub fn ml_neg_80(self: Self) Self {
            self.style().margin.left = len_rem(-20.0);
            return self;
        }
        /// Sets the left margin of the element to 384px (24rem).
        pub fn ml_96(self: Self) Self {
            self.style().margin.left = len_rem(24.0);
            return self;
        }
        /// Sets the left margin of the element to negative 384px (24rem).
        pub fn ml_neg_96(self: Self) Self {
            self.style().margin.left = len_rem(-24.0);
            return self;
        }
        /// Sets the left margin of the element to 448px (28rem).
        pub fn ml_112(self: Self) Self {
            self.style().margin.left = len_rem(28.0);
            return self;
        }
        /// Sets the left margin of the element to negative 448px (28rem).
        pub fn ml_neg_112(self: Self) Self {
            self.style().margin.left = len_rem(-28.0);
            return self;
        }
        /// Sets the left margin of the element to 512px (32rem).
        pub fn ml_128(self: Self) Self {
            self.style().margin.left = len_rem(32.0);
            return self;
        }
        /// Sets the left margin of the element to negative 512px (32rem).
        pub fn ml_neg_128(self: Self) Self {
            self.style().margin.left = len_rem(-32.0);
            return self;
        }
        /// Sets the left margin of the element to auto.
        pub fn ml_auto(self: Self) Self {
            self.style().margin.left = geometry.auto();
            return self;
        }
        /// Sets the left margin of the element to 1px.
        pub fn ml_px(self: Self) Self {
            self.style().margin.left = len_px(1.0);
            return self;
        }
        /// Sets the left margin of the element to negative 1px.
        pub fn ml_neg_px(self: Self) Self {
            self.style().margin.left = len_px(-1.0);
            return self;
        }
        /// Sets the left margin of the element to 100%.
        pub fn ml_full(self: Self) Self {
            self.style().margin.left = len_rel(1.0);
            return self;
        }
        /// Sets the left margin of the element to negative 100%.
        pub fn ml_neg_full(self: Self) Self {
            self.style().margin.left = len_rel(-1.0);
            return self;
        }
        /// Sets the left margin of the element to 50%.
        pub fn ml_1_2(self: Self) Self {
            self.style().margin.left = len_rel(0.5);
            return self;
        }
        /// Sets the left margin of the element to negative 50%.
        pub fn ml_neg_1_2(self: Self) Self {
            self.style().margin.left = len_rel(-0.5);
            return self;
        }
        /// Sets the left margin of the element to 33.3333%.
        pub fn ml_1_3(self: Self) Self {
            self.style().margin.left = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the left margin of the element to negative 33.3333%.
        pub fn ml_neg_1_3(self: Self) Self {
            self.style().margin.left = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the left margin of the element to 66.6667%.
        pub fn ml_2_3(self: Self) Self {
            self.style().margin.left = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the left margin of the element to negative 66.6667%.
        pub fn ml_neg_2_3(self: Self) Self {
            self.style().margin.left = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the left margin of the element to 25%.
        pub fn ml_1_4(self: Self) Self {
            self.style().margin.left = len_rel(0.25);
            return self;
        }
        /// Sets the left margin of the element to negative 25%.
        pub fn ml_neg_1_4(self: Self) Self {
            self.style().margin.left = len_rel(-0.25);
            return self;
        }
        /// Sets the left margin of the element to 50%.
        pub fn ml_2_4(self: Self) Self {
            self.style().margin.left = len_rel(0.5);
            return self;
        }
        /// Sets the left margin of the element to negative 50%.
        pub fn ml_neg_2_4(self: Self) Self {
            self.style().margin.left = len_rel(-0.5);
            return self;
        }
        /// Sets the left margin of the element to 75%.
        pub fn ml_3_4(self: Self) Self {
            self.style().margin.left = len_rel(0.75);
            return self;
        }
        /// Sets the left margin of the element to negative 75%.
        pub fn ml_neg_3_4(self: Self) Self {
            self.style().margin.left = len_rel(-0.75);
            return self;
        }
        /// Sets the left margin of the element to 20%.
        pub fn ml_1_5(self: Self) Self {
            self.style().margin.left = len_rel(0.2);
            return self;
        }
        /// Sets the left margin of the element to negative 20%.
        pub fn ml_neg_1_5(self: Self) Self {
            self.style().margin.left = len_rel(-0.2);
            return self;
        }
        /// Sets the left margin of the element to 40%.
        pub fn ml_2_5(self: Self) Self {
            self.style().margin.left = len_rel(0.4);
            return self;
        }
        /// Sets the left margin of the element to negative 40%.
        pub fn ml_neg_2_5(self: Self) Self {
            self.style().margin.left = len_rel(-0.4);
            return self;
        }
        /// Sets the left margin of the element to 60%.
        pub fn ml_3_5(self: Self) Self {
            self.style().margin.left = len_rel(0.6);
            return self;
        }
        /// Sets the left margin of the element to negative 60%.
        pub fn ml_neg_3_5(self: Self) Self {
            self.style().margin.left = len_rel(-0.6);
            return self;
        }
        /// Sets the left margin of the element to 80%.
        pub fn ml_4_5(self: Self) Self {
            self.style().margin.left = len_rel(0.8);
            return self;
        }
        /// Sets the left margin of the element to negative 80%.
        pub fn ml_neg_4_5(self: Self) Self {
            self.style().margin.left = len_rel(-0.8);
            return self;
        }
        /// Sets the left margin of the element to 16.6667%.
        pub fn ml_1_6(self: Self) Self {
            self.style().margin.left = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the left margin of the element to negative 16.6667%.
        pub fn ml_neg_1_6(self: Self) Self {
            self.style().margin.left = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the left margin of the element to 83.3333%.
        pub fn ml_5_6(self: Self) Self {
            self.style().margin.left = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the left margin of the element to negative 83.3333%.
        pub fn ml_neg_5_6(self: Self) Self {
            self.style().margin.left = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the left margin of the element to 8.33333%.
        pub fn ml_1_12(self: Self) Self {
            self.style().margin.left = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the left margin of the element to negative 8.33333%.
        pub fn ml_neg_1_12(self: Self) Self {
            self.style().margin.left = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the right margin of the element.
        pub fn mr(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.margin.right = v;
            return self;
        }
        /// Sets the right margin of the element to 0px.
        pub fn mr_0(self: Self) Self {
            self.style().margin.right = len_px(0.0);
            return self;
        }
        /// Sets the right margin of the element to negative 0px.
        pub fn mr_neg_0(self: Self) Self {
            self.style().margin.right = len_px(-0.0);
            return self;
        }
        /// Sets the right margin of the element to 2px (0.125rem).
        pub fn mr_0p5(self: Self) Self {
            self.style().margin.right = len_rem(0.125);
            return self;
        }
        /// Sets the right margin of the element to negative 2px (0.125rem).
        pub fn mr_neg_0p5(self: Self) Self {
            self.style().margin.right = len_rem(-0.125);
            return self;
        }
        /// Sets the right margin of the element to 4px (0.25rem).
        pub fn mr_1(self: Self) Self {
            self.style().margin.right = len_rem(0.25);
            return self;
        }
        /// Sets the right margin of the element to negative 4px (0.25rem).
        pub fn mr_neg_1(self: Self) Self {
            self.style().margin.right = len_rem(-0.25);
            return self;
        }
        /// Sets the right margin of the element to 6px (0.375rem).
        pub fn mr_1p5(self: Self) Self {
            self.style().margin.right = len_rem(0.375);
            return self;
        }
        /// Sets the right margin of the element to negative 6px (0.375rem).
        pub fn mr_neg_1p5(self: Self) Self {
            self.style().margin.right = len_rem(-0.375);
            return self;
        }
        /// Sets the right margin of the element to 8px (0.5rem).
        pub fn mr_2(self: Self) Self {
            self.style().margin.right = len_rem(0.5);
            return self;
        }
        /// Sets the right margin of the element to negative 8px (0.5rem).
        pub fn mr_neg_2(self: Self) Self {
            self.style().margin.right = len_rem(-0.5);
            return self;
        }
        /// Sets the right margin of the element to 10px (0.625rem).
        pub fn mr_2p5(self: Self) Self {
            self.style().margin.right = len_rem(0.625);
            return self;
        }
        /// Sets the right margin of the element to negative 10px (0.625rem).
        pub fn mr_neg_2p5(self: Self) Self {
            self.style().margin.right = len_rem(-0.625);
            return self;
        }
        /// Sets the right margin of the element to 12px (0.75rem).
        pub fn mr_3(self: Self) Self {
            self.style().margin.right = len_rem(0.75);
            return self;
        }
        /// Sets the right margin of the element to negative 12px (0.75rem).
        pub fn mr_neg_3(self: Self) Self {
            self.style().margin.right = len_rem(-0.75);
            return self;
        }
        /// Sets the right margin of the element to 14px (0.875rem).
        pub fn mr_3p5(self: Self) Self {
            self.style().margin.right = len_rem(0.875);
            return self;
        }
        /// Sets the right margin of the element to negative 14px (0.875rem).
        pub fn mr_neg_3p5(self: Self) Self {
            self.style().margin.right = len_rem(-0.875);
            return self;
        }
        /// Sets the right margin of the element to 16px (1rem).
        pub fn mr_4(self: Self) Self {
            self.style().margin.right = len_rem(1.0);
            return self;
        }
        /// Sets the right margin of the element to negative 16px (1rem).
        pub fn mr_neg_4(self: Self) Self {
            self.style().margin.right = len_rem(-1.0);
            return self;
        }
        /// Sets the right margin of the element to 20px (1.25rem).
        pub fn mr_5(self: Self) Self {
            self.style().margin.right = len_rem(1.25);
            return self;
        }
        /// Sets the right margin of the element to negative 20px (1.25rem).
        pub fn mr_neg_5(self: Self) Self {
            self.style().margin.right = len_rem(-1.25);
            return self;
        }
        /// Sets the right margin of the element to 24px (1.5rem).
        pub fn mr_6(self: Self) Self {
            self.style().margin.right = len_rem(1.5);
            return self;
        }
        /// Sets the right margin of the element to negative 24px (1.5rem).
        pub fn mr_neg_6(self: Self) Self {
            self.style().margin.right = len_rem(-1.5);
            return self;
        }
        /// Sets the right margin of the element to 28px (1.75rem).
        pub fn mr_7(self: Self) Self {
            self.style().margin.right = len_rem(1.75);
            return self;
        }
        /// Sets the right margin of the element to negative 28px (1.75rem).
        pub fn mr_neg_7(self: Self) Self {
            self.style().margin.right = len_rem(-1.75);
            return self;
        }
        /// Sets the right margin of the element to 32px (2rem).
        pub fn mr_8(self: Self) Self {
            self.style().margin.right = len_rem(2.0);
            return self;
        }
        /// Sets the right margin of the element to negative 32px (2rem).
        pub fn mr_neg_8(self: Self) Self {
            self.style().margin.right = len_rem(-2.0);
            return self;
        }
        /// Sets the right margin of the element to 36px (2.25rem).
        pub fn mr_9(self: Self) Self {
            self.style().margin.right = len_rem(2.25);
            return self;
        }
        /// Sets the right margin of the element to negative 36px (2.25rem).
        pub fn mr_neg_9(self: Self) Self {
            self.style().margin.right = len_rem(-2.25);
            return self;
        }
        /// Sets the right margin of the element to 40px (2.5rem).
        pub fn mr_10(self: Self) Self {
            self.style().margin.right = len_rem(2.5);
            return self;
        }
        /// Sets the right margin of the element to negative 40px (2.5rem).
        pub fn mr_neg_10(self: Self) Self {
            self.style().margin.right = len_rem(-2.5);
            return self;
        }
        /// Sets the right margin of the element to 44px (2.75rem).
        pub fn mr_11(self: Self) Self {
            self.style().margin.right = len_rem(2.75);
            return self;
        }
        /// Sets the right margin of the element to negative 44px (2.75rem).
        pub fn mr_neg_11(self: Self) Self {
            self.style().margin.right = len_rem(-2.75);
            return self;
        }
        /// Sets the right margin of the element to 48px (3rem).
        pub fn mr_12(self: Self) Self {
            self.style().margin.right = len_rem(3.0);
            return self;
        }
        /// Sets the right margin of the element to negative 48px (3rem).
        pub fn mr_neg_12(self: Self) Self {
            self.style().margin.right = len_rem(-3.0);
            return self;
        }
        /// Sets the right margin of the element to 64px (4rem).
        pub fn mr_16(self: Self) Self {
            self.style().margin.right = len_rem(4.0);
            return self;
        }
        /// Sets the right margin of the element to negative 64px (4rem).
        pub fn mr_neg_16(self: Self) Self {
            self.style().margin.right = len_rem(-4.0);
            return self;
        }
        /// Sets the right margin of the element to 80px (5rem).
        pub fn mr_20(self: Self) Self {
            self.style().margin.right = len_rem(5.0);
            return self;
        }
        /// Sets the right margin of the element to negative 80px (5rem).
        pub fn mr_neg_20(self: Self) Self {
            self.style().margin.right = len_rem(-5.0);
            return self;
        }
        /// Sets the right margin of the element to 96px (6rem).
        pub fn mr_24(self: Self) Self {
            self.style().margin.right = len_rem(6.0);
            return self;
        }
        /// Sets the right margin of the element to negative 96px (6rem).
        pub fn mr_neg_24(self: Self) Self {
            self.style().margin.right = len_rem(-6.0);
            return self;
        }
        /// Sets the right margin of the element to 128px (8rem).
        pub fn mr_32(self: Self) Self {
            self.style().margin.right = len_rem(8.0);
            return self;
        }
        /// Sets the right margin of the element to negative 128px (8rem).
        pub fn mr_neg_32(self: Self) Self {
            self.style().margin.right = len_rem(-8.0);
            return self;
        }
        /// Sets the right margin of the element to 160px (10rem).
        pub fn mr_40(self: Self) Self {
            self.style().margin.right = len_rem(10.0);
            return self;
        }
        /// Sets the right margin of the element to negative 160px (10rem).
        pub fn mr_neg_40(self: Self) Self {
            self.style().margin.right = len_rem(-10.0);
            return self;
        }
        /// Sets the right margin of the element to 192px (12rem).
        pub fn mr_48(self: Self) Self {
            self.style().margin.right = len_rem(12.0);
            return self;
        }
        /// Sets the right margin of the element to negative 192px (12rem).
        pub fn mr_neg_48(self: Self) Self {
            self.style().margin.right = len_rem(-12.0);
            return self;
        }
        /// Sets the right margin of the element to 224px (14rem).
        pub fn mr_56(self: Self) Self {
            self.style().margin.right = len_rem(14.0);
            return self;
        }
        /// Sets the right margin of the element to negative 224px (14rem).
        pub fn mr_neg_56(self: Self) Self {
            self.style().margin.right = len_rem(-14.0);
            return self;
        }
        /// Sets the right margin of the element to 256px (16rem).
        pub fn mr_64(self: Self) Self {
            self.style().margin.right = len_rem(16.0);
            return self;
        }
        /// Sets the right margin of the element to negative 256px (16rem).
        pub fn mr_neg_64(self: Self) Self {
            self.style().margin.right = len_rem(-16.0);
            return self;
        }
        /// Sets the right margin of the element to 288px (18rem).
        pub fn mr_72(self: Self) Self {
            self.style().margin.right = len_rem(18.0);
            return self;
        }
        /// Sets the right margin of the element to negative 288px (18rem).
        pub fn mr_neg_72(self: Self) Self {
            self.style().margin.right = len_rem(-18.0);
            return self;
        }
        /// Sets the right margin of the element to 320px (20rem).
        pub fn mr_80(self: Self) Self {
            self.style().margin.right = len_rem(20.0);
            return self;
        }
        /// Sets the right margin of the element to negative 320px (20rem).
        pub fn mr_neg_80(self: Self) Self {
            self.style().margin.right = len_rem(-20.0);
            return self;
        }
        /// Sets the right margin of the element to 384px (24rem).
        pub fn mr_96(self: Self) Self {
            self.style().margin.right = len_rem(24.0);
            return self;
        }
        /// Sets the right margin of the element to negative 384px (24rem).
        pub fn mr_neg_96(self: Self) Self {
            self.style().margin.right = len_rem(-24.0);
            return self;
        }
        /// Sets the right margin of the element to 448px (28rem).
        pub fn mr_112(self: Self) Self {
            self.style().margin.right = len_rem(28.0);
            return self;
        }
        /// Sets the right margin of the element to negative 448px (28rem).
        pub fn mr_neg_112(self: Self) Self {
            self.style().margin.right = len_rem(-28.0);
            return self;
        }
        /// Sets the right margin of the element to 512px (32rem).
        pub fn mr_128(self: Self) Self {
            self.style().margin.right = len_rem(32.0);
            return self;
        }
        /// Sets the right margin of the element to negative 512px (32rem).
        pub fn mr_neg_128(self: Self) Self {
            self.style().margin.right = len_rem(-32.0);
            return self;
        }
        /// Sets the right margin of the element to auto.
        pub fn mr_auto(self: Self) Self {
            self.style().margin.right = geometry.auto();
            return self;
        }
        /// Sets the right margin of the element to 1px.
        pub fn mr_px(self: Self) Self {
            self.style().margin.right = len_px(1.0);
            return self;
        }
        /// Sets the right margin of the element to negative 1px.
        pub fn mr_neg_px(self: Self) Self {
            self.style().margin.right = len_px(-1.0);
            return self;
        }
        /// Sets the right margin of the element to 100%.
        pub fn mr_full(self: Self) Self {
            self.style().margin.right = len_rel(1.0);
            return self;
        }
        /// Sets the right margin of the element to negative 100%.
        pub fn mr_neg_full(self: Self) Self {
            self.style().margin.right = len_rel(-1.0);
            return self;
        }
        /// Sets the right margin of the element to 50%.
        pub fn mr_1_2(self: Self) Self {
            self.style().margin.right = len_rel(0.5);
            return self;
        }
        /// Sets the right margin of the element to negative 50%.
        pub fn mr_neg_1_2(self: Self) Self {
            self.style().margin.right = len_rel(-0.5);
            return self;
        }
        /// Sets the right margin of the element to 33.3333%.
        pub fn mr_1_3(self: Self) Self {
            self.style().margin.right = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the right margin of the element to negative 33.3333%.
        pub fn mr_neg_1_3(self: Self) Self {
            self.style().margin.right = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the right margin of the element to 66.6667%.
        pub fn mr_2_3(self: Self) Self {
            self.style().margin.right = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the right margin of the element to negative 66.6667%.
        pub fn mr_neg_2_3(self: Self) Self {
            self.style().margin.right = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the right margin of the element to 25%.
        pub fn mr_1_4(self: Self) Self {
            self.style().margin.right = len_rel(0.25);
            return self;
        }
        /// Sets the right margin of the element to negative 25%.
        pub fn mr_neg_1_4(self: Self) Self {
            self.style().margin.right = len_rel(-0.25);
            return self;
        }
        /// Sets the right margin of the element to 50%.
        pub fn mr_2_4(self: Self) Self {
            self.style().margin.right = len_rel(0.5);
            return self;
        }
        /// Sets the right margin of the element to negative 50%.
        pub fn mr_neg_2_4(self: Self) Self {
            self.style().margin.right = len_rel(-0.5);
            return self;
        }
        /// Sets the right margin of the element to 75%.
        pub fn mr_3_4(self: Self) Self {
            self.style().margin.right = len_rel(0.75);
            return self;
        }
        /// Sets the right margin of the element to negative 75%.
        pub fn mr_neg_3_4(self: Self) Self {
            self.style().margin.right = len_rel(-0.75);
            return self;
        }
        /// Sets the right margin of the element to 20%.
        pub fn mr_1_5(self: Self) Self {
            self.style().margin.right = len_rel(0.2);
            return self;
        }
        /// Sets the right margin of the element to negative 20%.
        pub fn mr_neg_1_5(self: Self) Self {
            self.style().margin.right = len_rel(-0.2);
            return self;
        }
        /// Sets the right margin of the element to 40%.
        pub fn mr_2_5(self: Self) Self {
            self.style().margin.right = len_rel(0.4);
            return self;
        }
        /// Sets the right margin of the element to negative 40%.
        pub fn mr_neg_2_5(self: Self) Self {
            self.style().margin.right = len_rel(-0.4);
            return self;
        }
        /// Sets the right margin of the element to 60%.
        pub fn mr_3_5(self: Self) Self {
            self.style().margin.right = len_rel(0.6);
            return self;
        }
        /// Sets the right margin of the element to negative 60%.
        pub fn mr_neg_3_5(self: Self) Self {
            self.style().margin.right = len_rel(-0.6);
            return self;
        }
        /// Sets the right margin of the element to 80%.
        pub fn mr_4_5(self: Self) Self {
            self.style().margin.right = len_rel(0.8);
            return self;
        }
        /// Sets the right margin of the element to negative 80%.
        pub fn mr_neg_4_5(self: Self) Self {
            self.style().margin.right = len_rel(-0.8);
            return self;
        }
        /// Sets the right margin of the element to 16.6667%.
        pub fn mr_1_6(self: Self) Self {
            self.style().margin.right = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the right margin of the element to negative 16.6667%.
        pub fn mr_neg_1_6(self: Self) Self {
            self.style().margin.right = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the right margin of the element to 83.3333%.
        pub fn mr_5_6(self: Self) Self {
            self.style().margin.right = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the right margin of the element to negative 83.3333%.
        pub fn mr_neg_5_6(self: Self) Self {
            self.style().margin.right = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the right margin of the element to 8.33333%.
        pub fn mr_1_12(self: Self) Self {
            self.style().margin.right = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the right margin of the element to negative 8.33333%.
        pub fn mr_neg_1_12(self: Self) Self {
            self.style().margin.right = len_rel(-0.08333333333333333);
            return self;
        }
        /// Sets the padding of the element.
        pub fn p(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.top = v;
            s.padding.bottom = v;
            s.padding.left = v;
            s.padding.right = v;
            return self;
        }
        /// Sets the padding of the element to 0px.
        pub fn p_0(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(0.0);
            s.padding.bottom = def_px(0.0);
            s.padding.left = def_px(0.0);
            s.padding.right = def_px(0.0);
            return self;
        }
        /// Sets the padding of the element to negative 0px.
        pub fn p_neg_0(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(-0.0);
            s.padding.bottom = def_px(-0.0);
            s.padding.left = def_px(-0.0);
            s.padding.right = def_px(-0.0);
            return self;
        }
        /// Sets the padding of the element to 2px (0.125rem).
        pub fn p_0p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.125);
            s.padding.bottom = def_rem(0.125);
            s.padding.left = def_rem(0.125);
            s.padding.right = def_rem(0.125);
            return self;
        }
        /// Sets the padding of the element to negative 2px (0.125rem).
        pub fn p_neg_0p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.125);
            s.padding.bottom = def_rem(-0.125);
            s.padding.left = def_rem(-0.125);
            s.padding.right = def_rem(-0.125);
            return self;
        }
        /// Sets the padding of the element to 4px (0.25rem).
        pub fn p_1(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.25);
            s.padding.bottom = def_rem(0.25);
            s.padding.left = def_rem(0.25);
            s.padding.right = def_rem(0.25);
            return self;
        }
        /// Sets the padding of the element to negative 4px (0.25rem).
        pub fn p_neg_1(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.25);
            s.padding.bottom = def_rem(-0.25);
            s.padding.left = def_rem(-0.25);
            s.padding.right = def_rem(-0.25);
            return self;
        }
        /// Sets the padding of the element to 6px (0.375rem).
        pub fn p_1p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.375);
            s.padding.bottom = def_rem(0.375);
            s.padding.left = def_rem(0.375);
            s.padding.right = def_rem(0.375);
            return self;
        }
        /// Sets the padding of the element to negative 6px (0.375rem).
        pub fn p_neg_1p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.375);
            s.padding.bottom = def_rem(-0.375);
            s.padding.left = def_rem(-0.375);
            s.padding.right = def_rem(-0.375);
            return self;
        }
        /// Sets the padding of the element to 8px (0.5rem).
        pub fn p_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.5);
            s.padding.bottom = def_rem(0.5);
            s.padding.left = def_rem(0.5);
            s.padding.right = def_rem(0.5);
            return self;
        }
        /// Sets the padding of the element to negative 8px (0.5rem).
        pub fn p_neg_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.5);
            s.padding.bottom = def_rem(-0.5);
            s.padding.left = def_rem(-0.5);
            s.padding.right = def_rem(-0.5);
            return self;
        }
        /// Sets the padding of the element to 10px (0.625rem).
        pub fn p_2p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.625);
            s.padding.bottom = def_rem(0.625);
            s.padding.left = def_rem(0.625);
            s.padding.right = def_rem(0.625);
            return self;
        }
        /// Sets the padding of the element to negative 10px (0.625rem).
        pub fn p_neg_2p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.625);
            s.padding.bottom = def_rem(-0.625);
            s.padding.left = def_rem(-0.625);
            s.padding.right = def_rem(-0.625);
            return self;
        }
        /// Sets the padding of the element to 12px (0.75rem).
        pub fn p_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.75);
            s.padding.bottom = def_rem(0.75);
            s.padding.left = def_rem(0.75);
            s.padding.right = def_rem(0.75);
            return self;
        }
        /// Sets the padding of the element to negative 12px (0.75rem).
        pub fn p_neg_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.75);
            s.padding.bottom = def_rem(-0.75);
            s.padding.left = def_rem(-0.75);
            s.padding.right = def_rem(-0.75);
            return self;
        }
        /// Sets the padding of the element to 14px (0.875rem).
        pub fn p_3p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.875);
            s.padding.bottom = def_rem(0.875);
            s.padding.left = def_rem(0.875);
            s.padding.right = def_rem(0.875);
            return self;
        }
        /// Sets the padding of the element to negative 14px (0.875rem).
        pub fn p_neg_3p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.875);
            s.padding.bottom = def_rem(-0.875);
            s.padding.left = def_rem(-0.875);
            s.padding.right = def_rem(-0.875);
            return self;
        }
        /// Sets the padding of the element to 16px (1rem).
        pub fn p_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.0);
            s.padding.bottom = def_rem(1.0);
            s.padding.left = def_rem(1.0);
            s.padding.right = def_rem(1.0);
            return self;
        }
        /// Sets the padding of the element to negative 16px (1rem).
        pub fn p_neg_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.0);
            s.padding.bottom = def_rem(-1.0);
            s.padding.left = def_rem(-1.0);
            s.padding.right = def_rem(-1.0);
            return self;
        }
        /// Sets the padding of the element to 20px (1.25rem).
        pub fn p_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.25);
            s.padding.bottom = def_rem(1.25);
            s.padding.left = def_rem(1.25);
            s.padding.right = def_rem(1.25);
            return self;
        }
        /// Sets the padding of the element to negative 20px (1.25rem).
        pub fn p_neg_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.25);
            s.padding.bottom = def_rem(-1.25);
            s.padding.left = def_rem(-1.25);
            s.padding.right = def_rem(-1.25);
            return self;
        }
        /// Sets the padding of the element to 24px (1.5rem).
        pub fn p_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.5);
            s.padding.bottom = def_rem(1.5);
            s.padding.left = def_rem(1.5);
            s.padding.right = def_rem(1.5);
            return self;
        }
        /// Sets the padding of the element to negative 24px (1.5rem).
        pub fn p_neg_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.5);
            s.padding.bottom = def_rem(-1.5);
            s.padding.left = def_rem(-1.5);
            s.padding.right = def_rem(-1.5);
            return self;
        }
        /// Sets the padding of the element to 28px (1.75rem).
        pub fn p_7(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.75);
            s.padding.bottom = def_rem(1.75);
            s.padding.left = def_rem(1.75);
            s.padding.right = def_rem(1.75);
            return self;
        }
        /// Sets the padding of the element to negative 28px (1.75rem).
        pub fn p_neg_7(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.75);
            s.padding.bottom = def_rem(-1.75);
            s.padding.left = def_rem(-1.75);
            s.padding.right = def_rem(-1.75);
            return self;
        }
        /// Sets the padding of the element to 32px (2rem).
        pub fn p_8(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.0);
            s.padding.bottom = def_rem(2.0);
            s.padding.left = def_rem(2.0);
            s.padding.right = def_rem(2.0);
            return self;
        }
        /// Sets the padding of the element to negative 32px (2rem).
        pub fn p_neg_8(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.0);
            s.padding.bottom = def_rem(-2.0);
            s.padding.left = def_rem(-2.0);
            s.padding.right = def_rem(-2.0);
            return self;
        }
        /// Sets the padding of the element to 36px (2.25rem).
        pub fn p_9(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.25);
            s.padding.bottom = def_rem(2.25);
            s.padding.left = def_rem(2.25);
            s.padding.right = def_rem(2.25);
            return self;
        }
        /// Sets the padding of the element to negative 36px (2.25rem).
        pub fn p_neg_9(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.25);
            s.padding.bottom = def_rem(-2.25);
            s.padding.left = def_rem(-2.25);
            s.padding.right = def_rem(-2.25);
            return self;
        }
        /// Sets the padding of the element to 40px (2.5rem).
        pub fn p_10(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.5);
            s.padding.bottom = def_rem(2.5);
            s.padding.left = def_rem(2.5);
            s.padding.right = def_rem(2.5);
            return self;
        }
        /// Sets the padding of the element to negative 40px (2.5rem).
        pub fn p_neg_10(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.5);
            s.padding.bottom = def_rem(-2.5);
            s.padding.left = def_rem(-2.5);
            s.padding.right = def_rem(-2.5);
            return self;
        }
        /// Sets the padding of the element to 44px (2.75rem).
        pub fn p_11(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.75);
            s.padding.bottom = def_rem(2.75);
            s.padding.left = def_rem(2.75);
            s.padding.right = def_rem(2.75);
            return self;
        }
        /// Sets the padding of the element to negative 44px (2.75rem).
        pub fn p_neg_11(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.75);
            s.padding.bottom = def_rem(-2.75);
            s.padding.left = def_rem(-2.75);
            s.padding.right = def_rem(-2.75);
            return self;
        }
        /// Sets the padding of the element to 48px (3rem).
        pub fn p_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(3.0);
            s.padding.bottom = def_rem(3.0);
            s.padding.left = def_rem(3.0);
            s.padding.right = def_rem(3.0);
            return self;
        }
        /// Sets the padding of the element to negative 48px (3rem).
        pub fn p_neg_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-3.0);
            s.padding.bottom = def_rem(-3.0);
            s.padding.left = def_rem(-3.0);
            s.padding.right = def_rem(-3.0);
            return self;
        }
        /// Sets the padding of the element to 64px (4rem).
        pub fn p_16(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(4.0);
            s.padding.bottom = def_rem(4.0);
            s.padding.left = def_rem(4.0);
            s.padding.right = def_rem(4.0);
            return self;
        }
        /// Sets the padding of the element to negative 64px (4rem).
        pub fn p_neg_16(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-4.0);
            s.padding.bottom = def_rem(-4.0);
            s.padding.left = def_rem(-4.0);
            s.padding.right = def_rem(-4.0);
            return self;
        }
        /// Sets the padding of the element to 80px (5rem).
        pub fn p_20(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(5.0);
            s.padding.bottom = def_rem(5.0);
            s.padding.left = def_rem(5.0);
            s.padding.right = def_rem(5.0);
            return self;
        }
        /// Sets the padding of the element to negative 80px (5rem).
        pub fn p_neg_20(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-5.0);
            s.padding.bottom = def_rem(-5.0);
            s.padding.left = def_rem(-5.0);
            s.padding.right = def_rem(-5.0);
            return self;
        }
        /// Sets the padding of the element to 96px (6rem).
        pub fn p_24(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(6.0);
            s.padding.bottom = def_rem(6.0);
            s.padding.left = def_rem(6.0);
            s.padding.right = def_rem(6.0);
            return self;
        }
        /// Sets the padding of the element to negative 96px (6rem).
        pub fn p_neg_24(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-6.0);
            s.padding.bottom = def_rem(-6.0);
            s.padding.left = def_rem(-6.0);
            s.padding.right = def_rem(-6.0);
            return self;
        }
        /// Sets the padding of the element to 128px (8rem).
        pub fn p_32(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(8.0);
            s.padding.bottom = def_rem(8.0);
            s.padding.left = def_rem(8.0);
            s.padding.right = def_rem(8.0);
            return self;
        }
        /// Sets the padding of the element to negative 128px (8rem).
        pub fn p_neg_32(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-8.0);
            s.padding.bottom = def_rem(-8.0);
            s.padding.left = def_rem(-8.0);
            s.padding.right = def_rem(-8.0);
            return self;
        }
        /// Sets the padding of the element to 160px (10rem).
        pub fn p_40(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(10.0);
            s.padding.bottom = def_rem(10.0);
            s.padding.left = def_rem(10.0);
            s.padding.right = def_rem(10.0);
            return self;
        }
        /// Sets the padding of the element to negative 160px (10rem).
        pub fn p_neg_40(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-10.0);
            s.padding.bottom = def_rem(-10.0);
            s.padding.left = def_rem(-10.0);
            s.padding.right = def_rem(-10.0);
            return self;
        }
        /// Sets the padding of the element to 192px (12rem).
        pub fn p_48(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(12.0);
            s.padding.bottom = def_rem(12.0);
            s.padding.left = def_rem(12.0);
            s.padding.right = def_rem(12.0);
            return self;
        }
        /// Sets the padding of the element to negative 192px (12rem).
        pub fn p_neg_48(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-12.0);
            s.padding.bottom = def_rem(-12.0);
            s.padding.left = def_rem(-12.0);
            s.padding.right = def_rem(-12.0);
            return self;
        }
        /// Sets the padding of the element to 224px (14rem).
        pub fn p_56(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(14.0);
            s.padding.bottom = def_rem(14.0);
            s.padding.left = def_rem(14.0);
            s.padding.right = def_rem(14.0);
            return self;
        }
        /// Sets the padding of the element to negative 224px (14rem).
        pub fn p_neg_56(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-14.0);
            s.padding.bottom = def_rem(-14.0);
            s.padding.left = def_rem(-14.0);
            s.padding.right = def_rem(-14.0);
            return self;
        }
        /// Sets the padding of the element to 256px (16rem).
        pub fn p_64(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(16.0);
            s.padding.bottom = def_rem(16.0);
            s.padding.left = def_rem(16.0);
            s.padding.right = def_rem(16.0);
            return self;
        }
        /// Sets the padding of the element to negative 256px (16rem).
        pub fn p_neg_64(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-16.0);
            s.padding.bottom = def_rem(-16.0);
            s.padding.left = def_rem(-16.0);
            s.padding.right = def_rem(-16.0);
            return self;
        }
        /// Sets the padding of the element to 288px (18rem).
        pub fn p_72(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(18.0);
            s.padding.bottom = def_rem(18.0);
            s.padding.left = def_rem(18.0);
            s.padding.right = def_rem(18.0);
            return self;
        }
        /// Sets the padding of the element to negative 288px (18rem).
        pub fn p_neg_72(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-18.0);
            s.padding.bottom = def_rem(-18.0);
            s.padding.left = def_rem(-18.0);
            s.padding.right = def_rem(-18.0);
            return self;
        }
        /// Sets the padding of the element to 320px (20rem).
        pub fn p_80(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(20.0);
            s.padding.bottom = def_rem(20.0);
            s.padding.left = def_rem(20.0);
            s.padding.right = def_rem(20.0);
            return self;
        }
        /// Sets the padding of the element to negative 320px (20rem).
        pub fn p_neg_80(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-20.0);
            s.padding.bottom = def_rem(-20.0);
            s.padding.left = def_rem(-20.0);
            s.padding.right = def_rem(-20.0);
            return self;
        }
        /// Sets the padding of the element to 384px (24rem).
        pub fn p_96(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(24.0);
            s.padding.bottom = def_rem(24.0);
            s.padding.left = def_rem(24.0);
            s.padding.right = def_rem(24.0);
            return self;
        }
        /// Sets the padding of the element to negative 384px (24rem).
        pub fn p_neg_96(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-24.0);
            s.padding.bottom = def_rem(-24.0);
            s.padding.left = def_rem(-24.0);
            s.padding.right = def_rem(-24.0);
            return self;
        }
        /// Sets the padding of the element to 448px (28rem).
        pub fn p_112(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(28.0);
            s.padding.bottom = def_rem(28.0);
            s.padding.left = def_rem(28.0);
            s.padding.right = def_rem(28.0);
            return self;
        }
        /// Sets the padding of the element to negative 448px (28rem).
        pub fn p_neg_112(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-28.0);
            s.padding.bottom = def_rem(-28.0);
            s.padding.left = def_rem(-28.0);
            s.padding.right = def_rem(-28.0);
            return self;
        }
        /// Sets the padding of the element to 512px (32rem).
        pub fn p_128(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(32.0);
            s.padding.bottom = def_rem(32.0);
            s.padding.left = def_rem(32.0);
            s.padding.right = def_rem(32.0);
            return self;
        }
        /// Sets the padding of the element to negative 512px (32rem).
        pub fn p_neg_128(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-32.0);
            s.padding.bottom = def_rem(-32.0);
            s.padding.left = def_rem(-32.0);
            s.padding.right = def_rem(-32.0);
            return self;
        }
        /// Sets the padding of the element to 1px.
        pub fn p_px(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(1.0);
            s.padding.bottom = def_px(1.0);
            s.padding.left = def_px(1.0);
            s.padding.right = def_px(1.0);
            return self;
        }
        /// Sets the padding of the element to negative 1px.
        pub fn p_neg_px(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(-1.0);
            s.padding.bottom = def_px(-1.0);
            s.padding.left = def_px(-1.0);
            s.padding.right = def_px(-1.0);
            return self;
        }
        /// Sets the padding of the element to 100%.
        pub fn p_full(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(1.0);
            s.padding.bottom = def_rel(1.0);
            s.padding.left = def_rel(1.0);
            s.padding.right = def_rel(1.0);
            return self;
        }
        /// Sets the padding of the element to negative 100%.
        pub fn p_neg_full(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-1.0);
            s.padding.bottom = def_rel(-1.0);
            s.padding.left = def_rel(-1.0);
            s.padding.right = def_rel(-1.0);
            return self;
        }
        /// Sets the padding of the element to 50%.
        pub fn p_1_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.5);
            s.padding.bottom = def_rel(0.5);
            s.padding.left = def_rel(0.5);
            s.padding.right = def_rel(0.5);
            return self;
        }
        /// Sets the padding of the element to negative 50%.
        pub fn p_neg_1_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.5);
            s.padding.bottom = def_rel(-0.5);
            s.padding.left = def_rel(-0.5);
            s.padding.right = def_rel(-0.5);
            return self;
        }
        /// Sets the padding of the element to 33.3333%.
        pub fn p_1_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.3333333333333333);
            s.padding.bottom = def_rel(0.3333333333333333);
            s.padding.left = def_rel(0.3333333333333333);
            s.padding.right = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the padding of the element to negative 33.3333%.
        pub fn p_neg_1_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.3333333333333333);
            s.padding.bottom = def_rel(-0.3333333333333333);
            s.padding.left = def_rel(-0.3333333333333333);
            s.padding.right = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the padding of the element to 66.6667%.
        pub fn p_2_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.6666666666666666);
            s.padding.bottom = def_rel(0.6666666666666666);
            s.padding.left = def_rel(0.6666666666666666);
            s.padding.right = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the padding of the element to negative 66.6667%.
        pub fn p_neg_2_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.6666666666666666);
            s.padding.bottom = def_rel(-0.6666666666666666);
            s.padding.left = def_rel(-0.6666666666666666);
            s.padding.right = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the padding of the element to 25%.
        pub fn p_1_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.25);
            s.padding.bottom = def_rel(0.25);
            s.padding.left = def_rel(0.25);
            s.padding.right = def_rel(0.25);
            return self;
        }
        /// Sets the padding of the element to negative 25%.
        pub fn p_neg_1_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.25);
            s.padding.bottom = def_rel(-0.25);
            s.padding.left = def_rel(-0.25);
            s.padding.right = def_rel(-0.25);
            return self;
        }
        /// Sets the padding of the element to 50%.
        pub fn p_2_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.5);
            s.padding.bottom = def_rel(0.5);
            s.padding.left = def_rel(0.5);
            s.padding.right = def_rel(0.5);
            return self;
        }
        /// Sets the padding of the element to negative 50%.
        pub fn p_neg_2_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.5);
            s.padding.bottom = def_rel(-0.5);
            s.padding.left = def_rel(-0.5);
            s.padding.right = def_rel(-0.5);
            return self;
        }
        /// Sets the padding of the element to 75%.
        pub fn p_3_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.75);
            s.padding.bottom = def_rel(0.75);
            s.padding.left = def_rel(0.75);
            s.padding.right = def_rel(0.75);
            return self;
        }
        /// Sets the padding of the element to negative 75%.
        pub fn p_neg_3_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.75);
            s.padding.bottom = def_rel(-0.75);
            s.padding.left = def_rel(-0.75);
            s.padding.right = def_rel(-0.75);
            return self;
        }
        /// Sets the padding of the element to 20%.
        pub fn p_1_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.2);
            s.padding.bottom = def_rel(0.2);
            s.padding.left = def_rel(0.2);
            s.padding.right = def_rel(0.2);
            return self;
        }
        /// Sets the padding of the element to negative 20%.
        pub fn p_neg_1_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.2);
            s.padding.bottom = def_rel(-0.2);
            s.padding.left = def_rel(-0.2);
            s.padding.right = def_rel(-0.2);
            return self;
        }
        /// Sets the padding of the element to 40%.
        pub fn p_2_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.4);
            s.padding.bottom = def_rel(0.4);
            s.padding.left = def_rel(0.4);
            s.padding.right = def_rel(0.4);
            return self;
        }
        /// Sets the padding of the element to negative 40%.
        pub fn p_neg_2_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.4);
            s.padding.bottom = def_rel(-0.4);
            s.padding.left = def_rel(-0.4);
            s.padding.right = def_rel(-0.4);
            return self;
        }
        /// Sets the padding of the element to 60%.
        pub fn p_3_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.6);
            s.padding.bottom = def_rel(0.6);
            s.padding.left = def_rel(0.6);
            s.padding.right = def_rel(0.6);
            return self;
        }
        /// Sets the padding of the element to negative 60%.
        pub fn p_neg_3_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.6);
            s.padding.bottom = def_rel(-0.6);
            s.padding.left = def_rel(-0.6);
            s.padding.right = def_rel(-0.6);
            return self;
        }
        /// Sets the padding of the element to 80%.
        pub fn p_4_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.8);
            s.padding.bottom = def_rel(0.8);
            s.padding.left = def_rel(0.8);
            s.padding.right = def_rel(0.8);
            return self;
        }
        /// Sets the padding of the element to negative 80%.
        pub fn p_neg_4_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.8);
            s.padding.bottom = def_rel(-0.8);
            s.padding.left = def_rel(-0.8);
            s.padding.right = def_rel(-0.8);
            return self;
        }
        /// Sets the padding of the element to 16.6667%.
        pub fn p_1_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.16666666666666666);
            s.padding.bottom = def_rel(0.16666666666666666);
            s.padding.left = def_rel(0.16666666666666666);
            s.padding.right = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the padding of the element to negative 16.6667%.
        pub fn p_neg_1_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.16666666666666666);
            s.padding.bottom = def_rel(-0.16666666666666666);
            s.padding.left = def_rel(-0.16666666666666666);
            s.padding.right = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the padding of the element to 83.3333%.
        pub fn p_5_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.8333333333333334);
            s.padding.bottom = def_rel(0.8333333333333334);
            s.padding.left = def_rel(0.8333333333333334);
            s.padding.right = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the padding of the element to negative 83.3333%.
        pub fn p_neg_5_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.8333333333333334);
            s.padding.bottom = def_rel(-0.8333333333333334);
            s.padding.left = def_rel(-0.8333333333333334);
            s.padding.right = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the padding of the element to 8.33333%.
        pub fn p_1_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.08333333333333333);
            s.padding.bottom = def_rel(0.08333333333333333);
            s.padding.left = def_rel(0.08333333333333333);
            s.padding.right = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the padding of the element to negative 8.33333%.
        pub fn p_neg_1_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.08333333333333333);
            s.padding.bottom = def_rel(-0.08333333333333333);
            s.padding.left = def_rel(-0.08333333333333333);
            s.padding.right = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the top padding of the element.
        pub fn pt(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.top = v;
            return self;
        }
        /// Sets the top padding of the element to 0px.
        pub fn pt_0(self: Self) Self {
            self.style().padding.top = def_px(0.0);
            return self;
        }
        /// Sets the top padding of the element to negative 0px.
        pub fn pt_neg_0(self: Self) Self {
            self.style().padding.top = def_px(-0.0);
            return self;
        }
        /// Sets the top padding of the element to 2px (0.125rem).
        pub fn pt_0p5(self: Self) Self {
            self.style().padding.top = def_rem(0.125);
            return self;
        }
        /// Sets the top padding of the element to negative 2px (0.125rem).
        pub fn pt_neg_0p5(self: Self) Self {
            self.style().padding.top = def_rem(-0.125);
            return self;
        }
        /// Sets the top padding of the element to 4px (0.25rem).
        pub fn pt_1(self: Self) Self {
            self.style().padding.top = def_rem(0.25);
            return self;
        }
        /// Sets the top padding of the element to negative 4px (0.25rem).
        pub fn pt_neg_1(self: Self) Self {
            self.style().padding.top = def_rem(-0.25);
            return self;
        }
        /// Sets the top padding of the element to 6px (0.375rem).
        pub fn pt_1p5(self: Self) Self {
            self.style().padding.top = def_rem(0.375);
            return self;
        }
        /// Sets the top padding of the element to negative 6px (0.375rem).
        pub fn pt_neg_1p5(self: Self) Self {
            self.style().padding.top = def_rem(-0.375);
            return self;
        }
        /// Sets the top padding of the element to 8px (0.5rem).
        pub fn pt_2(self: Self) Self {
            self.style().padding.top = def_rem(0.5);
            return self;
        }
        /// Sets the top padding of the element to negative 8px (0.5rem).
        pub fn pt_neg_2(self: Self) Self {
            self.style().padding.top = def_rem(-0.5);
            return self;
        }
        /// Sets the top padding of the element to 10px (0.625rem).
        pub fn pt_2p5(self: Self) Self {
            self.style().padding.top = def_rem(0.625);
            return self;
        }
        /// Sets the top padding of the element to negative 10px (0.625rem).
        pub fn pt_neg_2p5(self: Self) Self {
            self.style().padding.top = def_rem(-0.625);
            return self;
        }
        /// Sets the top padding of the element to 12px (0.75rem).
        pub fn pt_3(self: Self) Self {
            self.style().padding.top = def_rem(0.75);
            return self;
        }
        /// Sets the top padding of the element to negative 12px (0.75rem).
        pub fn pt_neg_3(self: Self) Self {
            self.style().padding.top = def_rem(-0.75);
            return self;
        }
        /// Sets the top padding of the element to 14px (0.875rem).
        pub fn pt_3p5(self: Self) Self {
            self.style().padding.top = def_rem(0.875);
            return self;
        }
        /// Sets the top padding of the element to negative 14px (0.875rem).
        pub fn pt_neg_3p5(self: Self) Self {
            self.style().padding.top = def_rem(-0.875);
            return self;
        }
        /// Sets the top padding of the element to 16px (1rem).
        pub fn pt_4(self: Self) Self {
            self.style().padding.top = def_rem(1.0);
            return self;
        }
        /// Sets the top padding of the element to negative 16px (1rem).
        pub fn pt_neg_4(self: Self) Self {
            self.style().padding.top = def_rem(-1.0);
            return self;
        }
        /// Sets the top padding of the element to 20px (1.25rem).
        pub fn pt_5(self: Self) Self {
            self.style().padding.top = def_rem(1.25);
            return self;
        }
        /// Sets the top padding of the element to negative 20px (1.25rem).
        pub fn pt_neg_5(self: Self) Self {
            self.style().padding.top = def_rem(-1.25);
            return self;
        }
        /// Sets the top padding of the element to 24px (1.5rem).
        pub fn pt_6(self: Self) Self {
            self.style().padding.top = def_rem(1.5);
            return self;
        }
        /// Sets the top padding of the element to negative 24px (1.5rem).
        pub fn pt_neg_6(self: Self) Self {
            self.style().padding.top = def_rem(-1.5);
            return self;
        }
        /// Sets the top padding of the element to 28px (1.75rem).
        pub fn pt_7(self: Self) Self {
            self.style().padding.top = def_rem(1.75);
            return self;
        }
        /// Sets the top padding of the element to negative 28px (1.75rem).
        pub fn pt_neg_7(self: Self) Self {
            self.style().padding.top = def_rem(-1.75);
            return self;
        }
        /// Sets the top padding of the element to 32px (2rem).
        pub fn pt_8(self: Self) Self {
            self.style().padding.top = def_rem(2.0);
            return self;
        }
        /// Sets the top padding of the element to negative 32px (2rem).
        pub fn pt_neg_8(self: Self) Self {
            self.style().padding.top = def_rem(-2.0);
            return self;
        }
        /// Sets the top padding of the element to 36px (2.25rem).
        pub fn pt_9(self: Self) Self {
            self.style().padding.top = def_rem(2.25);
            return self;
        }
        /// Sets the top padding of the element to negative 36px (2.25rem).
        pub fn pt_neg_9(self: Self) Self {
            self.style().padding.top = def_rem(-2.25);
            return self;
        }
        /// Sets the top padding of the element to 40px (2.5rem).
        pub fn pt_10(self: Self) Self {
            self.style().padding.top = def_rem(2.5);
            return self;
        }
        /// Sets the top padding of the element to negative 40px (2.5rem).
        pub fn pt_neg_10(self: Self) Self {
            self.style().padding.top = def_rem(-2.5);
            return self;
        }
        /// Sets the top padding of the element to 44px (2.75rem).
        pub fn pt_11(self: Self) Self {
            self.style().padding.top = def_rem(2.75);
            return self;
        }
        /// Sets the top padding of the element to negative 44px (2.75rem).
        pub fn pt_neg_11(self: Self) Self {
            self.style().padding.top = def_rem(-2.75);
            return self;
        }
        /// Sets the top padding of the element to 48px (3rem).
        pub fn pt_12(self: Self) Self {
            self.style().padding.top = def_rem(3.0);
            return self;
        }
        /// Sets the top padding of the element to negative 48px (3rem).
        pub fn pt_neg_12(self: Self) Self {
            self.style().padding.top = def_rem(-3.0);
            return self;
        }
        /// Sets the top padding of the element to 64px (4rem).
        pub fn pt_16(self: Self) Self {
            self.style().padding.top = def_rem(4.0);
            return self;
        }
        /// Sets the top padding of the element to negative 64px (4rem).
        pub fn pt_neg_16(self: Self) Self {
            self.style().padding.top = def_rem(-4.0);
            return self;
        }
        /// Sets the top padding of the element to 80px (5rem).
        pub fn pt_20(self: Self) Self {
            self.style().padding.top = def_rem(5.0);
            return self;
        }
        /// Sets the top padding of the element to negative 80px (5rem).
        pub fn pt_neg_20(self: Self) Self {
            self.style().padding.top = def_rem(-5.0);
            return self;
        }
        /// Sets the top padding of the element to 96px (6rem).
        pub fn pt_24(self: Self) Self {
            self.style().padding.top = def_rem(6.0);
            return self;
        }
        /// Sets the top padding of the element to negative 96px (6rem).
        pub fn pt_neg_24(self: Self) Self {
            self.style().padding.top = def_rem(-6.0);
            return self;
        }
        /// Sets the top padding of the element to 128px (8rem).
        pub fn pt_32(self: Self) Self {
            self.style().padding.top = def_rem(8.0);
            return self;
        }
        /// Sets the top padding of the element to negative 128px (8rem).
        pub fn pt_neg_32(self: Self) Self {
            self.style().padding.top = def_rem(-8.0);
            return self;
        }
        /// Sets the top padding of the element to 160px (10rem).
        pub fn pt_40(self: Self) Self {
            self.style().padding.top = def_rem(10.0);
            return self;
        }
        /// Sets the top padding of the element to negative 160px (10rem).
        pub fn pt_neg_40(self: Self) Self {
            self.style().padding.top = def_rem(-10.0);
            return self;
        }
        /// Sets the top padding of the element to 192px (12rem).
        pub fn pt_48(self: Self) Self {
            self.style().padding.top = def_rem(12.0);
            return self;
        }
        /// Sets the top padding of the element to negative 192px (12rem).
        pub fn pt_neg_48(self: Self) Self {
            self.style().padding.top = def_rem(-12.0);
            return self;
        }
        /// Sets the top padding of the element to 224px (14rem).
        pub fn pt_56(self: Self) Self {
            self.style().padding.top = def_rem(14.0);
            return self;
        }
        /// Sets the top padding of the element to negative 224px (14rem).
        pub fn pt_neg_56(self: Self) Self {
            self.style().padding.top = def_rem(-14.0);
            return self;
        }
        /// Sets the top padding of the element to 256px (16rem).
        pub fn pt_64(self: Self) Self {
            self.style().padding.top = def_rem(16.0);
            return self;
        }
        /// Sets the top padding of the element to negative 256px (16rem).
        pub fn pt_neg_64(self: Self) Self {
            self.style().padding.top = def_rem(-16.0);
            return self;
        }
        /// Sets the top padding of the element to 288px (18rem).
        pub fn pt_72(self: Self) Self {
            self.style().padding.top = def_rem(18.0);
            return self;
        }
        /// Sets the top padding of the element to negative 288px (18rem).
        pub fn pt_neg_72(self: Self) Self {
            self.style().padding.top = def_rem(-18.0);
            return self;
        }
        /// Sets the top padding of the element to 320px (20rem).
        pub fn pt_80(self: Self) Self {
            self.style().padding.top = def_rem(20.0);
            return self;
        }
        /// Sets the top padding of the element to negative 320px (20rem).
        pub fn pt_neg_80(self: Self) Self {
            self.style().padding.top = def_rem(-20.0);
            return self;
        }
        /// Sets the top padding of the element to 384px (24rem).
        pub fn pt_96(self: Self) Self {
            self.style().padding.top = def_rem(24.0);
            return self;
        }
        /// Sets the top padding of the element to negative 384px (24rem).
        pub fn pt_neg_96(self: Self) Self {
            self.style().padding.top = def_rem(-24.0);
            return self;
        }
        /// Sets the top padding of the element to 448px (28rem).
        pub fn pt_112(self: Self) Self {
            self.style().padding.top = def_rem(28.0);
            return self;
        }
        /// Sets the top padding of the element to negative 448px (28rem).
        pub fn pt_neg_112(self: Self) Self {
            self.style().padding.top = def_rem(-28.0);
            return self;
        }
        /// Sets the top padding of the element to 512px (32rem).
        pub fn pt_128(self: Self) Self {
            self.style().padding.top = def_rem(32.0);
            return self;
        }
        /// Sets the top padding of the element to negative 512px (32rem).
        pub fn pt_neg_128(self: Self) Self {
            self.style().padding.top = def_rem(-32.0);
            return self;
        }
        /// Sets the top padding of the element to 1px.
        pub fn pt_px(self: Self) Self {
            self.style().padding.top = def_px(1.0);
            return self;
        }
        /// Sets the top padding of the element to negative 1px.
        pub fn pt_neg_px(self: Self) Self {
            self.style().padding.top = def_px(-1.0);
            return self;
        }
        /// Sets the top padding of the element to 100%.
        pub fn pt_full(self: Self) Self {
            self.style().padding.top = def_rel(1.0);
            return self;
        }
        /// Sets the top padding of the element to negative 100%.
        pub fn pt_neg_full(self: Self) Self {
            self.style().padding.top = def_rel(-1.0);
            return self;
        }
        /// Sets the top padding of the element to 50%.
        pub fn pt_1_2(self: Self) Self {
            self.style().padding.top = def_rel(0.5);
            return self;
        }
        /// Sets the top padding of the element to negative 50%.
        pub fn pt_neg_1_2(self: Self) Self {
            self.style().padding.top = def_rel(-0.5);
            return self;
        }
        /// Sets the top padding of the element to 33.3333%.
        pub fn pt_1_3(self: Self) Self {
            self.style().padding.top = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the top padding of the element to negative 33.3333%.
        pub fn pt_neg_1_3(self: Self) Self {
            self.style().padding.top = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the top padding of the element to 66.6667%.
        pub fn pt_2_3(self: Self) Self {
            self.style().padding.top = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the top padding of the element to negative 66.6667%.
        pub fn pt_neg_2_3(self: Self) Self {
            self.style().padding.top = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the top padding of the element to 25%.
        pub fn pt_1_4(self: Self) Self {
            self.style().padding.top = def_rel(0.25);
            return self;
        }
        /// Sets the top padding of the element to negative 25%.
        pub fn pt_neg_1_4(self: Self) Self {
            self.style().padding.top = def_rel(-0.25);
            return self;
        }
        /// Sets the top padding of the element to 50%.
        pub fn pt_2_4(self: Self) Self {
            self.style().padding.top = def_rel(0.5);
            return self;
        }
        /// Sets the top padding of the element to negative 50%.
        pub fn pt_neg_2_4(self: Self) Self {
            self.style().padding.top = def_rel(-0.5);
            return self;
        }
        /// Sets the top padding of the element to 75%.
        pub fn pt_3_4(self: Self) Self {
            self.style().padding.top = def_rel(0.75);
            return self;
        }
        /// Sets the top padding of the element to negative 75%.
        pub fn pt_neg_3_4(self: Self) Self {
            self.style().padding.top = def_rel(-0.75);
            return self;
        }
        /// Sets the top padding of the element to 20%.
        pub fn pt_1_5(self: Self) Self {
            self.style().padding.top = def_rel(0.2);
            return self;
        }
        /// Sets the top padding of the element to negative 20%.
        pub fn pt_neg_1_5(self: Self) Self {
            self.style().padding.top = def_rel(-0.2);
            return self;
        }
        /// Sets the top padding of the element to 40%.
        pub fn pt_2_5(self: Self) Self {
            self.style().padding.top = def_rel(0.4);
            return self;
        }
        /// Sets the top padding of the element to negative 40%.
        pub fn pt_neg_2_5(self: Self) Self {
            self.style().padding.top = def_rel(-0.4);
            return self;
        }
        /// Sets the top padding of the element to 60%.
        pub fn pt_3_5(self: Self) Self {
            self.style().padding.top = def_rel(0.6);
            return self;
        }
        /// Sets the top padding of the element to negative 60%.
        pub fn pt_neg_3_5(self: Self) Self {
            self.style().padding.top = def_rel(-0.6);
            return self;
        }
        /// Sets the top padding of the element to 80%.
        pub fn pt_4_5(self: Self) Self {
            self.style().padding.top = def_rel(0.8);
            return self;
        }
        /// Sets the top padding of the element to negative 80%.
        pub fn pt_neg_4_5(self: Self) Self {
            self.style().padding.top = def_rel(-0.8);
            return self;
        }
        /// Sets the top padding of the element to 16.6667%.
        pub fn pt_1_6(self: Self) Self {
            self.style().padding.top = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the top padding of the element to negative 16.6667%.
        pub fn pt_neg_1_6(self: Self) Self {
            self.style().padding.top = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the top padding of the element to 83.3333%.
        pub fn pt_5_6(self: Self) Self {
            self.style().padding.top = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the top padding of the element to negative 83.3333%.
        pub fn pt_neg_5_6(self: Self) Self {
            self.style().padding.top = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the top padding of the element to 8.33333%.
        pub fn pt_1_12(self: Self) Self {
            self.style().padding.top = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the top padding of the element to negative 8.33333%.
        pub fn pt_neg_1_12(self: Self) Self {
            self.style().padding.top = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the bottom padding of the element.
        pub fn pb(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.bottom = v;
            return self;
        }
        /// Sets the bottom padding of the element to 0px.
        pub fn pb_0(self: Self) Self {
            self.style().padding.bottom = def_px(0.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 0px.
        pub fn pb_neg_0(self: Self) Self {
            self.style().padding.bottom = def_px(-0.0);
            return self;
        }
        /// Sets the bottom padding of the element to 2px (0.125rem).
        pub fn pb_0p5(self: Self) Self {
            self.style().padding.bottom = def_rem(0.125);
            return self;
        }
        /// Sets the bottom padding of the element to negative 2px (0.125rem).
        pub fn pb_neg_0p5(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.125);
            return self;
        }
        /// Sets the bottom padding of the element to 4px (0.25rem).
        pub fn pb_1(self: Self) Self {
            self.style().padding.bottom = def_rem(0.25);
            return self;
        }
        /// Sets the bottom padding of the element to negative 4px (0.25rem).
        pub fn pb_neg_1(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.25);
            return self;
        }
        /// Sets the bottom padding of the element to 6px (0.375rem).
        pub fn pb_1p5(self: Self) Self {
            self.style().padding.bottom = def_rem(0.375);
            return self;
        }
        /// Sets the bottom padding of the element to negative 6px (0.375rem).
        pub fn pb_neg_1p5(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.375);
            return self;
        }
        /// Sets the bottom padding of the element to 8px (0.5rem).
        pub fn pb_2(self: Self) Self {
            self.style().padding.bottom = def_rem(0.5);
            return self;
        }
        /// Sets the bottom padding of the element to negative 8px (0.5rem).
        pub fn pb_neg_2(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.5);
            return self;
        }
        /// Sets the bottom padding of the element to 10px (0.625rem).
        pub fn pb_2p5(self: Self) Self {
            self.style().padding.bottom = def_rem(0.625);
            return self;
        }
        /// Sets the bottom padding of the element to negative 10px (0.625rem).
        pub fn pb_neg_2p5(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.625);
            return self;
        }
        /// Sets the bottom padding of the element to 12px (0.75rem).
        pub fn pb_3(self: Self) Self {
            self.style().padding.bottom = def_rem(0.75);
            return self;
        }
        /// Sets the bottom padding of the element to negative 12px (0.75rem).
        pub fn pb_neg_3(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.75);
            return self;
        }
        /// Sets the bottom padding of the element to 14px (0.875rem).
        pub fn pb_3p5(self: Self) Self {
            self.style().padding.bottom = def_rem(0.875);
            return self;
        }
        /// Sets the bottom padding of the element to negative 14px (0.875rem).
        pub fn pb_neg_3p5(self: Self) Self {
            self.style().padding.bottom = def_rem(-0.875);
            return self;
        }
        /// Sets the bottom padding of the element to 16px (1rem).
        pub fn pb_4(self: Self) Self {
            self.style().padding.bottom = def_rem(1.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 16px (1rem).
        pub fn pb_neg_4(self: Self) Self {
            self.style().padding.bottom = def_rem(-1.0);
            return self;
        }
        /// Sets the bottom padding of the element to 20px (1.25rem).
        pub fn pb_5(self: Self) Self {
            self.style().padding.bottom = def_rem(1.25);
            return self;
        }
        /// Sets the bottom padding of the element to negative 20px (1.25rem).
        pub fn pb_neg_5(self: Self) Self {
            self.style().padding.bottom = def_rem(-1.25);
            return self;
        }
        /// Sets the bottom padding of the element to 24px (1.5rem).
        pub fn pb_6(self: Self) Self {
            self.style().padding.bottom = def_rem(1.5);
            return self;
        }
        /// Sets the bottom padding of the element to negative 24px (1.5rem).
        pub fn pb_neg_6(self: Self) Self {
            self.style().padding.bottom = def_rem(-1.5);
            return self;
        }
        /// Sets the bottom padding of the element to 28px (1.75rem).
        pub fn pb_7(self: Self) Self {
            self.style().padding.bottom = def_rem(1.75);
            return self;
        }
        /// Sets the bottom padding of the element to negative 28px (1.75rem).
        pub fn pb_neg_7(self: Self) Self {
            self.style().padding.bottom = def_rem(-1.75);
            return self;
        }
        /// Sets the bottom padding of the element to 32px (2rem).
        pub fn pb_8(self: Self) Self {
            self.style().padding.bottom = def_rem(2.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 32px (2rem).
        pub fn pb_neg_8(self: Self) Self {
            self.style().padding.bottom = def_rem(-2.0);
            return self;
        }
        /// Sets the bottom padding of the element to 36px (2.25rem).
        pub fn pb_9(self: Self) Self {
            self.style().padding.bottom = def_rem(2.25);
            return self;
        }
        /// Sets the bottom padding of the element to negative 36px (2.25rem).
        pub fn pb_neg_9(self: Self) Self {
            self.style().padding.bottom = def_rem(-2.25);
            return self;
        }
        /// Sets the bottom padding of the element to 40px (2.5rem).
        pub fn pb_10(self: Self) Self {
            self.style().padding.bottom = def_rem(2.5);
            return self;
        }
        /// Sets the bottom padding of the element to negative 40px (2.5rem).
        pub fn pb_neg_10(self: Self) Self {
            self.style().padding.bottom = def_rem(-2.5);
            return self;
        }
        /// Sets the bottom padding of the element to 44px (2.75rem).
        pub fn pb_11(self: Self) Self {
            self.style().padding.bottom = def_rem(2.75);
            return self;
        }
        /// Sets the bottom padding of the element to negative 44px (2.75rem).
        pub fn pb_neg_11(self: Self) Self {
            self.style().padding.bottom = def_rem(-2.75);
            return self;
        }
        /// Sets the bottom padding of the element to 48px (3rem).
        pub fn pb_12(self: Self) Self {
            self.style().padding.bottom = def_rem(3.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 48px (3rem).
        pub fn pb_neg_12(self: Self) Self {
            self.style().padding.bottom = def_rem(-3.0);
            return self;
        }
        /// Sets the bottom padding of the element to 64px (4rem).
        pub fn pb_16(self: Self) Self {
            self.style().padding.bottom = def_rem(4.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 64px (4rem).
        pub fn pb_neg_16(self: Self) Self {
            self.style().padding.bottom = def_rem(-4.0);
            return self;
        }
        /// Sets the bottom padding of the element to 80px (5rem).
        pub fn pb_20(self: Self) Self {
            self.style().padding.bottom = def_rem(5.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 80px (5rem).
        pub fn pb_neg_20(self: Self) Self {
            self.style().padding.bottom = def_rem(-5.0);
            return self;
        }
        /// Sets the bottom padding of the element to 96px (6rem).
        pub fn pb_24(self: Self) Self {
            self.style().padding.bottom = def_rem(6.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 96px (6rem).
        pub fn pb_neg_24(self: Self) Self {
            self.style().padding.bottom = def_rem(-6.0);
            return self;
        }
        /// Sets the bottom padding of the element to 128px (8rem).
        pub fn pb_32(self: Self) Self {
            self.style().padding.bottom = def_rem(8.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 128px (8rem).
        pub fn pb_neg_32(self: Self) Self {
            self.style().padding.bottom = def_rem(-8.0);
            return self;
        }
        /// Sets the bottom padding of the element to 160px (10rem).
        pub fn pb_40(self: Self) Self {
            self.style().padding.bottom = def_rem(10.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 160px (10rem).
        pub fn pb_neg_40(self: Self) Self {
            self.style().padding.bottom = def_rem(-10.0);
            return self;
        }
        /// Sets the bottom padding of the element to 192px (12rem).
        pub fn pb_48(self: Self) Self {
            self.style().padding.bottom = def_rem(12.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 192px (12rem).
        pub fn pb_neg_48(self: Self) Self {
            self.style().padding.bottom = def_rem(-12.0);
            return self;
        }
        /// Sets the bottom padding of the element to 224px (14rem).
        pub fn pb_56(self: Self) Self {
            self.style().padding.bottom = def_rem(14.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 224px (14rem).
        pub fn pb_neg_56(self: Self) Self {
            self.style().padding.bottom = def_rem(-14.0);
            return self;
        }
        /// Sets the bottom padding of the element to 256px (16rem).
        pub fn pb_64(self: Self) Self {
            self.style().padding.bottom = def_rem(16.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 256px (16rem).
        pub fn pb_neg_64(self: Self) Self {
            self.style().padding.bottom = def_rem(-16.0);
            return self;
        }
        /// Sets the bottom padding of the element to 288px (18rem).
        pub fn pb_72(self: Self) Self {
            self.style().padding.bottom = def_rem(18.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 288px (18rem).
        pub fn pb_neg_72(self: Self) Self {
            self.style().padding.bottom = def_rem(-18.0);
            return self;
        }
        /// Sets the bottom padding of the element to 320px (20rem).
        pub fn pb_80(self: Self) Self {
            self.style().padding.bottom = def_rem(20.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 320px (20rem).
        pub fn pb_neg_80(self: Self) Self {
            self.style().padding.bottom = def_rem(-20.0);
            return self;
        }
        /// Sets the bottom padding of the element to 384px (24rem).
        pub fn pb_96(self: Self) Self {
            self.style().padding.bottom = def_rem(24.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 384px (24rem).
        pub fn pb_neg_96(self: Self) Self {
            self.style().padding.bottom = def_rem(-24.0);
            return self;
        }
        /// Sets the bottom padding of the element to 448px (28rem).
        pub fn pb_112(self: Self) Self {
            self.style().padding.bottom = def_rem(28.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 448px (28rem).
        pub fn pb_neg_112(self: Self) Self {
            self.style().padding.bottom = def_rem(-28.0);
            return self;
        }
        /// Sets the bottom padding of the element to 512px (32rem).
        pub fn pb_128(self: Self) Self {
            self.style().padding.bottom = def_rem(32.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 512px (32rem).
        pub fn pb_neg_128(self: Self) Self {
            self.style().padding.bottom = def_rem(-32.0);
            return self;
        }
        /// Sets the bottom padding of the element to 1px.
        pub fn pb_px(self: Self) Self {
            self.style().padding.bottom = def_px(1.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 1px.
        pub fn pb_neg_px(self: Self) Self {
            self.style().padding.bottom = def_px(-1.0);
            return self;
        }
        /// Sets the bottom padding of the element to 100%.
        pub fn pb_full(self: Self) Self {
            self.style().padding.bottom = def_rel(1.0);
            return self;
        }
        /// Sets the bottom padding of the element to negative 100%.
        pub fn pb_neg_full(self: Self) Self {
            self.style().padding.bottom = def_rel(-1.0);
            return self;
        }
        /// Sets the bottom padding of the element to 50%.
        pub fn pb_1_2(self: Self) Self {
            self.style().padding.bottom = def_rel(0.5);
            return self;
        }
        /// Sets the bottom padding of the element to negative 50%.
        pub fn pb_neg_1_2(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.5);
            return self;
        }
        /// Sets the bottom padding of the element to 33.3333%.
        pub fn pb_1_3(self: Self) Self {
            self.style().padding.bottom = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the bottom padding of the element to negative 33.3333%.
        pub fn pb_neg_1_3(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the bottom padding of the element to 66.6667%.
        pub fn pb_2_3(self: Self) Self {
            self.style().padding.bottom = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the bottom padding of the element to negative 66.6667%.
        pub fn pb_neg_2_3(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the bottom padding of the element to 25%.
        pub fn pb_1_4(self: Self) Self {
            self.style().padding.bottom = def_rel(0.25);
            return self;
        }
        /// Sets the bottom padding of the element to negative 25%.
        pub fn pb_neg_1_4(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.25);
            return self;
        }
        /// Sets the bottom padding of the element to 50%.
        pub fn pb_2_4(self: Self) Self {
            self.style().padding.bottom = def_rel(0.5);
            return self;
        }
        /// Sets the bottom padding of the element to negative 50%.
        pub fn pb_neg_2_4(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.5);
            return self;
        }
        /// Sets the bottom padding of the element to 75%.
        pub fn pb_3_4(self: Self) Self {
            self.style().padding.bottom = def_rel(0.75);
            return self;
        }
        /// Sets the bottom padding of the element to negative 75%.
        pub fn pb_neg_3_4(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.75);
            return self;
        }
        /// Sets the bottom padding of the element to 20%.
        pub fn pb_1_5(self: Self) Self {
            self.style().padding.bottom = def_rel(0.2);
            return self;
        }
        /// Sets the bottom padding of the element to negative 20%.
        pub fn pb_neg_1_5(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.2);
            return self;
        }
        /// Sets the bottom padding of the element to 40%.
        pub fn pb_2_5(self: Self) Self {
            self.style().padding.bottom = def_rel(0.4);
            return self;
        }
        /// Sets the bottom padding of the element to negative 40%.
        pub fn pb_neg_2_5(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.4);
            return self;
        }
        /// Sets the bottom padding of the element to 60%.
        pub fn pb_3_5(self: Self) Self {
            self.style().padding.bottom = def_rel(0.6);
            return self;
        }
        /// Sets the bottom padding of the element to negative 60%.
        pub fn pb_neg_3_5(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.6);
            return self;
        }
        /// Sets the bottom padding of the element to 80%.
        pub fn pb_4_5(self: Self) Self {
            self.style().padding.bottom = def_rel(0.8);
            return self;
        }
        /// Sets the bottom padding of the element to negative 80%.
        pub fn pb_neg_4_5(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.8);
            return self;
        }
        /// Sets the bottom padding of the element to 16.6667%.
        pub fn pb_1_6(self: Self) Self {
            self.style().padding.bottom = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the bottom padding of the element to negative 16.6667%.
        pub fn pb_neg_1_6(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the bottom padding of the element to 83.3333%.
        pub fn pb_5_6(self: Self) Self {
            self.style().padding.bottom = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the bottom padding of the element to negative 83.3333%.
        pub fn pb_neg_5_6(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the bottom padding of the element to 8.33333%.
        pub fn pb_1_12(self: Self) Self {
            self.style().padding.bottom = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the bottom padding of the element to negative 8.33333%.
        pub fn pb_neg_1_12(self: Self) Self {
            self.style().padding.bottom = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the horizontal padding of the element.
        pub fn px(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.left = v;
            s.padding.right = v;
            return self;
        }
        /// Sets the horizontal padding of the element to 0px.
        pub fn px_0(self: Self) Self {
            const s = self.style();
            s.padding.left = def_px(0.0);
            s.padding.right = def_px(0.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 0px.
        pub fn px_neg_0(self: Self) Self {
            const s = self.style();
            s.padding.left = def_px(-0.0);
            s.padding.right = def_px(-0.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 2px (0.125rem).
        pub fn px_0p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.125);
            s.padding.right = def_rem(0.125);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 2px (0.125rem).
        pub fn px_neg_0p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.125);
            s.padding.right = def_rem(-0.125);
            return self;
        }
        /// Sets the horizontal padding of the element to 4px (0.25rem).
        pub fn px_1(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.25);
            s.padding.right = def_rem(0.25);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 4px (0.25rem).
        pub fn px_neg_1(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.25);
            s.padding.right = def_rem(-0.25);
            return self;
        }
        /// Sets the horizontal padding of the element to 6px (0.375rem).
        pub fn px_1p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.375);
            s.padding.right = def_rem(0.375);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 6px (0.375rem).
        pub fn px_neg_1p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.375);
            s.padding.right = def_rem(-0.375);
            return self;
        }
        /// Sets the horizontal padding of the element to 8px (0.5rem).
        pub fn px_2(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.5);
            s.padding.right = def_rem(0.5);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 8px (0.5rem).
        pub fn px_neg_2(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.5);
            s.padding.right = def_rem(-0.5);
            return self;
        }
        /// Sets the horizontal padding of the element to 10px (0.625rem).
        pub fn px_2p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.625);
            s.padding.right = def_rem(0.625);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 10px (0.625rem).
        pub fn px_neg_2p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.625);
            s.padding.right = def_rem(-0.625);
            return self;
        }
        /// Sets the horizontal padding of the element to 12px (0.75rem).
        pub fn px_3(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.75);
            s.padding.right = def_rem(0.75);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 12px (0.75rem).
        pub fn px_neg_3(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.75);
            s.padding.right = def_rem(-0.75);
            return self;
        }
        /// Sets the horizontal padding of the element to 14px (0.875rem).
        pub fn px_3p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(0.875);
            s.padding.right = def_rem(0.875);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 14px (0.875rem).
        pub fn px_neg_3p5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-0.875);
            s.padding.right = def_rem(-0.875);
            return self;
        }
        /// Sets the horizontal padding of the element to 16px (1rem).
        pub fn px_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(1.0);
            s.padding.right = def_rem(1.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 16px (1rem).
        pub fn px_neg_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-1.0);
            s.padding.right = def_rem(-1.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 20px (1.25rem).
        pub fn px_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(1.25);
            s.padding.right = def_rem(1.25);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 20px (1.25rem).
        pub fn px_neg_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-1.25);
            s.padding.right = def_rem(-1.25);
            return self;
        }
        /// Sets the horizontal padding of the element to 24px (1.5rem).
        pub fn px_6(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(1.5);
            s.padding.right = def_rem(1.5);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 24px (1.5rem).
        pub fn px_neg_6(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-1.5);
            s.padding.right = def_rem(-1.5);
            return self;
        }
        /// Sets the horizontal padding of the element to 28px (1.75rem).
        pub fn px_7(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(1.75);
            s.padding.right = def_rem(1.75);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 28px (1.75rem).
        pub fn px_neg_7(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-1.75);
            s.padding.right = def_rem(-1.75);
            return self;
        }
        /// Sets the horizontal padding of the element to 32px (2rem).
        pub fn px_8(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(2.0);
            s.padding.right = def_rem(2.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 32px (2rem).
        pub fn px_neg_8(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-2.0);
            s.padding.right = def_rem(-2.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 36px (2.25rem).
        pub fn px_9(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(2.25);
            s.padding.right = def_rem(2.25);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 36px (2.25rem).
        pub fn px_neg_9(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-2.25);
            s.padding.right = def_rem(-2.25);
            return self;
        }
        /// Sets the horizontal padding of the element to 40px (2.5rem).
        pub fn px_10(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(2.5);
            s.padding.right = def_rem(2.5);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 40px (2.5rem).
        pub fn px_neg_10(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-2.5);
            s.padding.right = def_rem(-2.5);
            return self;
        }
        /// Sets the horizontal padding of the element to 44px (2.75rem).
        pub fn px_11(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(2.75);
            s.padding.right = def_rem(2.75);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 44px (2.75rem).
        pub fn px_neg_11(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-2.75);
            s.padding.right = def_rem(-2.75);
            return self;
        }
        /// Sets the horizontal padding of the element to 48px (3rem).
        pub fn px_12(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(3.0);
            s.padding.right = def_rem(3.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 48px (3rem).
        pub fn px_neg_12(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-3.0);
            s.padding.right = def_rem(-3.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 64px (4rem).
        pub fn px_16(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(4.0);
            s.padding.right = def_rem(4.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 64px (4rem).
        pub fn px_neg_16(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-4.0);
            s.padding.right = def_rem(-4.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 80px (5rem).
        pub fn px_20(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(5.0);
            s.padding.right = def_rem(5.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 80px (5rem).
        pub fn px_neg_20(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-5.0);
            s.padding.right = def_rem(-5.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 96px (6rem).
        pub fn px_24(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(6.0);
            s.padding.right = def_rem(6.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 96px (6rem).
        pub fn px_neg_24(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-6.0);
            s.padding.right = def_rem(-6.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 128px (8rem).
        pub fn px_32(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(8.0);
            s.padding.right = def_rem(8.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 128px (8rem).
        pub fn px_neg_32(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-8.0);
            s.padding.right = def_rem(-8.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 160px (10rem).
        pub fn px_40(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(10.0);
            s.padding.right = def_rem(10.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 160px (10rem).
        pub fn px_neg_40(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-10.0);
            s.padding.right = def_rem(-10.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 192px (12rem).
        pub fn px_48(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(12.0);
            s.padding.right = def_rem(12.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 192px (12rem).
        pub fn px_neg_48(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-12.0);
            s.padding.right = def_rem(-12.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 224px (14rem).
        pub fn px_56(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(14.0);
            s.padding.right = def_rem(14.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 224px (14rem).
        pub fn px_neg_56(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-14.0);
            s.padding.right = def_rem(-14.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 256px (16rem).
        pub fn px_64(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(16.0);
            s.padding.right = def_rem(16.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 256px (16rem).
        pub fn px_neg_64(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-16.0);
            s.padding.right = def_rem(-16.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 288px (18rem).
        pub fn px_72(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(18.0);
            s.padding.right = def_rem(18.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 288px (18rem).
        pub fn px_neg_72(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-18.0);
            s.padding.right = def_rem(-18.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 320px (20rem).
        pub fn px_80(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(20.0);
            s.padding.right = def_rem(20.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 320px (20rem).
        pub fn px_neg_80(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-20.0);
            s.padding.right = def_rem(-20.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 384px (24rem).
        pub fn px_96(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(24.0);
            s.padding.right = def_rem(24.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 384px (24rem).
        pub fn px_neg_96(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-24.0);
            s.padding.right = def_rem(-24.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 448px (28rem).
        pub fn px_112(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(28.0);
            s.padding.right = def_rem(28.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 448px (28rem).
        pub fn px_neg_112(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-28.0);
            s.padding.right = def_rem(-28.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 512px (32rem).
        pub fn px_128(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(32.0);
            s.padding.right = def_rem(32.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 512px (32rem).
        pub fn px_neg_128(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rem(-32.0);
            s.padding.right = def_rem(-32.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 1px.
        pub fn px_px(self: Self) Self {
            const s = self.style();
            s.padding.left = def_px(1.0);
            s.padding.right = def_px(1.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 1px.
        pub fn px_neg_px(self: Self) Self {
            const s = self.style();
            s.padding.left = def_px(-1.0);
            s.padding.right = def_px(-1.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 100%.
        pub fn px_full(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(1.0);
            s.padding.right = def_rel(1.0);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 100%.
        pub fn px_neg_full(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-1.0);
            s.padding.right = def_rel(-1.0);
            return self;
        }
        /// Sets the horizontal padding of the element to 50%.
        pub fn px_1_2(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.5);
            s.padding.right = def_rel(0.5);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 50%.
        pub fn px_neg_1_2(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.5);
            s.padding.right = def_rel(-0.5);
            return self;
        }
        /// Sets the horizontal padding of the element to 33.3333%.
        pub fn px_1_3(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.3333333333333333);
            s.padding.right = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 33.3333%.
        pub fn px_neg_1_3(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.3333333333333333);
            s.padding.right = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the horizontal padding of the element to 66.6667%.
        pub fn px_2_3(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.6666666666666666);
            s.padding.right = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 66.6667%.
        pub fn px_neg_2_3(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.6666666666666666);
            s.padding.right = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the horizontal padding of the element to 25%.
        pub fn px_1_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.25);
            s.padding.right = def_rel(0.25);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 25%.
        pub fn px_neg_1_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.25);
            s.padding.right = def_rel(-0.25);
            return self;
        }
        /// Sets the horizontal padding of the element to 50%.
        pub fn px_2_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.5);
            s.padding.right = def_rel(0.5);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 50%.
        pub fn px_neg_2_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.5);
            s.padding.right = def_rel(-0.5);
            return self;
        }
        /// Sets the horizontal padding of the element to 75%.
        pub fn px_3_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.75);
            s.padding.right = def_rel(0.75);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 75%.
        pub fn px_neg_3_4(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.75);
            s.padding.right = def_rel(-0.75);
            return self;
        }
        /// Sets the horizontal padding of the element to 20%.
        pub fn px_1_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.2);
            s.padding.right = def_rel(0.2);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 20%.
        pub fn px_neg_1_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.2);
            s.padding.right = def_rel(-0.2);
            return self;
        }
        /// Sets the horizontal padding of the element to 40%.
        pub fn px_2_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.4);
            s.padding.right = def_rel(0.4);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 40%.
        pub fn px_neg_2_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.4);
            s.padding.right = def_rel(-0.4);
            return self;
        }
        /// Sets the horizontal padding of the element to 60%.
        pub fn px_3_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.6);
            s.padding.right = def_rel(0.6);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 60%.
        pub fn px_neg_3_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.6);
            s.padding.right = def_rel(-0.6);
            return self;
        }
        /// Sets the horizontal padding of the element to 80%.
        pub fn px_4_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.8);
            s.padding.right = def_rel(0.8);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 80%.
        pub fn px_neg_4_5(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.8);
            s.padding.right = def_rel(-0.8);
            return self;
        }
        /// Sets the horizontal padding of the element to 16.6667%.
        pub fn px_1_6(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.16666666666666666);
            s.padding.right = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 16.6667%.
        pub fn px_neg_1_6(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.16666666666666666);
            s.padding.right = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the horizontal padding of the element to 83.3333%.
        pub fn px_5_6(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.8333333333333334);
            s.padding.right = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 83.3333%.
        pub fn px_neg_5_6(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.8333333333333334);
            s.padding.right = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the horizontal padding of the element to 8.33333%.
        pub fn px_1_12(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(0.08333333333333333);
            s.padding.right = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the horizontal padding of the element to negative 8.33333%.
        pub fn px_neg_1_12(self: Self) Self {
            const s = self.style();
            s.padding.left = def_rel(-0.08333333333333333);
            s.padding.right = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the vertical padding of the element.
        pub fn py(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.top = v;
            s.padding.bottom = v;
            return self;
        }
        /// Sets the vertical padding of the element to 0px.
        pub fn py_0(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(0.0);
            s.padding.bottom = def_px(0.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 0px.
        pub fn py_neg_0(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(-0.0);
            s.padding.bottom = def_px(-0.0);
            return self;
        }
        /// Sets the vertical padding of the element to 2px (0.125rem).
        pub fn py_0p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.125);
            s.padding.bottom = def_rem(0.125);
            return self;
        }
        /// Sets the vertical padding of the element to negative 2px (0.125rem).
        pub fn py_neg_0p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.125);
            s.padding.bottom = def_rem(-0.125);
            return self;
        }
        /// Sets the vertical padding of the element to 4px (0.25rem).
        pub fn py_1(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.25);
            s.padding.bottom = def_rem(0.25);
            return self;
        }
        /// Sets the vertical padding of the element to negative 4px (0.25rem).
        pub fn py_neg_1(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.25);
            s.padding.bottom = def_rem(-0.25);
            return self;
        }
        /// Sets the vertical padding of the element to 6px (0.375rem).
        pub fn py_1p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.375);
            s.padding.bottom = def_rem(0.375);
            return self;
        }
        /// Sets the vertical padding of the element to negative 6px (0.375rem).
        pub fn py_neg_1p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.375);
            s.padding.bottom = def_rem(-0.375);
            return self;
        }
        /// Sets the vertical padding of the element to 8px (0.5rem).
        pub fn py_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.5);
            s.padding.bottom = def_rem(0.5);
            return self;
        }
        /// Sets the vertical padding of the element to negative 8px (0.5rem).
        pub fn py_neg_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.5);
            s.padding.bottom = def_rem(-0.5);
            return self;
        }
        /// Sets the vertical padding of the element to 10px (0.625rem).
        pub fn py_2p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.625);
            s.padding.bottom = def_rem(0.625);
            return self;
        }
        /// Sets the vertical padding of the element to negative 10px (0.625rem).
        pub fn py_neg_2p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.625);
            s.padding.bottom = def_rem(-0.625);
            return self;
        }
        /// Sets the vertical padding of the element to 12px (0.75rem).
        pub fn py_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.75);
            s.padding.bottom = def_rem(0.75);
            return self;
        }
        /// Sets the vertical padding of the element to negative 12px (0.75rem).
        pub fn py_neg_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.75);
            s.padding.bottom = def_rem(-0.75);
            return self;
        }
        /// Sets the vertical padding of the element to 14px (0.875rem).
        pub fn py_3p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(0.875);
            s.padding.bottom = def_rem(0.875);
            return self;
        }
        /// Sets the vertical padding of the element to negative 14px (0.875rem).
        pub fn py_neg_3p5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-0.875);
            s.padding.bottom = def_rem(-0.875);
            return self;
        }
        /// Sets the vertical padding of the element to 16px (1rem).
        pub fn py_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.0);
            s.padding.bottom = def_rem(1.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 16px (1rem).
        pub fn py_neg_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.0);
            s.padding.bottom = def_rem(-1.0);
            return self;
        }
        /// Sets the vertical padding of the element to 20px (1.25rem).
        pub fn py_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.25);
            s.padding.bottom = def_rem(1.25);
            return self;
        }
        /// Sets the vertical padding of the element to negative 20px (1.25rem).
        pub fn py_neg_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.25);
            s.padding.bottom = def_rem(-1.25);
            return self;
        }
        /// Sets the vertical padding of the element to 24px (1.5rem).
        pub fn py_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.5);
            s.padding.bottom = def_rem(1.5);
            return self;
        }
        /// Sets the vertical padding of the element to negative 24px (1.5rem).
        pub fn py_neg_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.5);
            s.padding.bottom = def_rem(-1.5);
            return self;
        }
        /// Sets the vertical padding of the element to 28px (1.75rem).
        pub fn py_7(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(1.75);
            s.padding.bottom = def_rem(1.75);
            return self;
        }
        /// Sets the vertical padding of the element to negative 28px (1.75rem).
        pub fn py_neg_7(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-1.75);
            s.padding.bottom = def_rem(-1.75);
            return self;
        }
        /// Sets the vertical padding of the element to 32px (2rem).
        pub fn py_8(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.0);
            s.padding.bottom = def_rem(2.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 32px (2rem).
        pub fn py_neg_8(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.0);
            s.padding.bottom = def_rem(-2.0);
            return self;
        }
        /// Sets the vertical padding of the element to 36px (2.25rem).
        pub fn py_9(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.25);
            s.padding.bottom = def_rem(2.25);
            return self;
        }
        /// Sets the vertical padding of the element to negative 36px (2.25rem).
        pub fn py_neg_9(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.25);
            s.padding.bottom = def_rem(-2.25);
            return self;
        }
        /// Sets the vertical padding of the element to 40px (2.5rem).
        pub fn py_10(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.5);
            s.padding.bottom = def_rem(2.5);
            return self;
        }
        /// Sets the vertical padding of the element to negative 40px (2.5rem).
        pub fn py_neg_10(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.5);
            s.padding.bottom = def_rem(-2.5);
            return self;
        }
        /// Sets the vertical padding of the element to 44px (2.75rem).
        pub fn py_11(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(2.75);
            s.padding.bottom = def_rem(2.75);
            return self;
        }
        /// Sets the vertical padding of the element to negative 44px (2.75rem).
        pub fn py_neg_11(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-2.75);
            s.padding.bottom = def_rem(-2.75);
            return self;
        }
        /// Sets the vertical padding of the element to 48px (3rem).
        pub fn py_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(3.0);
            s.padding.bottom = def_rem(3.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 48px (3rem).
        pub fn py_neg_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-3.0);
            s.padding.bottom = def_rem(-3.0);
            return self;
        }
        /// Sets the vertical padding of the element to 64px (4rem).
        pub fn py_16(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(4.0);
            s.padding.bottom = def_rem(4.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 64px (4rem).
        pub fn py_neg_16(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-4.0);
            s.padding.bottom = def_rem(-4.0);
            return self;
        }
        /// Sets the vertical padding of the element to 80px (5rem).
        pub fn py_20(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(5.0);
            s.padding.bottom = def_rem(5.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 80px (5rem).
        pub fn py_neg_20(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-5.0);
            s.padding.bottom = def_rem(-5.0);
            return self;
        }
        /// Sets the vertical padding of the element to 96px (6rem).
        pub fn py_24(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(6.0);
            s.padding.bottom = def_rem(6.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 96px (6rem).
        pub fn py_neg_24(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-6.0);
            s.padding.bottom = def_rem(-6.0);
            return self;
        }
        /// Sets the vertical padding of the element to 128px (8rem).
        pub fn py_32(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(8.0);
            s.padding.bottom = def_rem(8.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 128px (8rem).
        pub fn py_neg_32(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-8.0);
            s.padding.bottom = def_rem(-8.0);
            return self;
        }
        /// Sets the vertical padding of the element to 160px (10rem).
        pub fn py_40(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(10.0);
            s.padding.bottom = def_rem(10.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 160px (10rem).
        pub fn py_neg_40(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-10.0);
            s.padding.bottom = def_rem(-10.0);
            return self;
        }
        /// Sets the vertical padding of the element to 192px (12rem).
        pub fn py_48(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(12.0);
            s.padding.bottom = def_rem(12.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 192px (12rem).
        pub fn py_neg_48(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-12.0);
            s.padding.bottom = def_rem(-12.0);
            return self;
        }
        /// Sets the vertical padding of the element to 224px (14rem).
        pub fn py_56(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(14.0);
            s.padding.bottom = def_rem(14.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 224px (14rem).
        pub fn py_neg_56(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-14.0);
            s.padding.bottom = def_rem(-14.0);
            return self;
        }
        /// Sets the vertical padding of the element to 256px (16rem).
        pub fn py_64(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(16.0);
            s.padding.bottom = def_rem(16.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 256px (16rem).
        pub fn py_neg_64(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-16.0);
            s.padding.bottom = def_rem(-16.0);
            return self;
        }
        /// Sets the vertical padding of the element to 288px (18rem).
        pub fn py_72(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(18.0);
            s.padding.bottom = def_rem(18.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 288px (18rem).
        pub fn py_neg_72(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-18.0);
            s.padding.bottom = def_rem(-18.0);
            return self;
        }
        /// Sets the vertical padding of the element to 320px (20rem).
        pub fn py_80(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(20.0);
            s.padding.bottom = def_rem(20.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 320px (20rem).
        pub fn py_neg_80(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-20.0);
            s.padding.bottom = def_rem(-20.0);
            return self;
        }
        /// Sets the vertical padding of the element to 384px (24rem).
        pub fn py_96(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(24.0);
            s.padding.bottom = def_rem(24.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 384px (24rem).
        pub fn py_neg_96(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-24.0);
            s.padding.bottom = def_rem(-24.0);
            return self;
        }
        /// Sets the vertical padding of the element to 448px (28rem).
        pub fn py_112(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(28.0);
            s.padding.bottom = def_rem(28.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 448px (28rem).
        pub fn py_neg_112(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-28.0);
            s.padding.bottom = def_rem(-28.0);
            return self;
        }
        /// Sets the vertical padding of the element to 512px (32rem).
        pub fn py_128(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(32.0);
            s.padding.bottom = def_rem(32.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 512px (32rem).
        pub fn py_neg_128(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rem(-32.0);
            s.padding.bottom = def_rem(-32.0);
            return self;
        }
        /// Sets the vertical padding of the element to 1px.
        pub fn py_px(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(1.0);
            s.padding.bottom = def_px(1.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 1px.
        pub fn py_neg_px(self: Self) Self {
            const s = self.style();
            s.padding.top = def_px(-1.0);
            s.padding.bottom = def_px(-1.0);
            return self;
        }
        /// Sets the vertical padding of the element to 100%.
        pub fn py_full(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(1.0);
            s.padding.bottom = def_rel(1.0);
            return self;
        }
        /// Sets the vertical padding of the element to negative 100%.
        pub fn py_neg_full(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-1.0);
            s.padding.bottom = def_rel(-1.0);
            return self;
        }
        /// Sets the vertical padding of the element to 50%.
        pub fn py_1_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.5);
            s.padding.bottom = def_rel(0.5);
            return self;
        }
        /// Sets the vertical padding of the element to negative 50%.
        pub fn py_neg_1_2(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.5);
            s.padding.bottom = def_rel(-0.5);
            return self;
        }
        /// Sets the vertical padding of the element to 33.3333%.
        pub fn py_1_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.3333333333333333);
            s.padding.bottom = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the vertical padding of the element to negative 33.3333%.
        pub fn py_neg_1_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.3333333333333333);
            s.padding.bottom = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the vertical padding of the element to 66.6667%.
        pub fn py_2_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.6666666666666666);
            s.padding.bottom = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the vertical padding of the element to negative 66.6667%.
        pub fn py_neg_2_3(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.6666666666666666);
            s.padding.bottom = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the vertical padding of the element to 25%.
        pub fn py_1_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.25);
            s.padding.bottom = def_rel(0.25);
            return self;
        }
        /// Sets the vertical padding of the element to negative 25%.
        pub fn py_neg_1_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.25);
            s.padding.bottom = def_rel(-0.25);
            return self;
        }
        /// Sets the vertical padding of the element to 50%.
        pub fn py_2_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.5);
            s.padding.bottom = def_rel(0.5);
            return self;
        }
        /// Sets the vertical padding of the element to negative 50%.
        pub fn py_neg_2_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.5);
            s.padding.bottom = def_rel(-0.5);
            return self;
        }
        /// Sets the vertical padding of the element to 75%.
        pub fn py_3_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.75);
            s.padding.bottom = def_rel(0.75);
            return self;
        }
        /// Sets the vertical padding of the element to negative 75%.
        pub fn py_neg_3_4(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.75);
            s.padding.bottom = def_rel(-0.75);
            return self;
        }
        /// Sets the vertical padding of the element to 20%.
        pub fn py_1_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.2);
            s.padding.bottom = def_rel(0.2);
            return self;
        }
        /// Sets the vertical padding of the element to negative 20%.
        pub fn py_neg_1_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.2);
            s.padding.bottom = def_rel(-0.2);
            return self;
        }
        /// Sets the vertical padding of the element to 40%.
        pub fn py_2_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.4);
            s.padding.bottom = def_rel(0.4);
            return self;
        }
        /// Sets the vertical padding of the element to negative 40%.
        pub fn py_neg_2_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.4);
            s.padding.bottom = def_rel(-0.4);
            return self;
        }
        /// Sets the vertical padding of the element to 60%.
        pub fn py_3_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.6);
            s.padding.bottom = def_rel(0.6);
            return self;
        }
        /// Sets the vertical padding of the element to negative 60%.
        pub fn py_neg_3_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.6);
            s.padding.bottom = def_rel(-0.6);
            return self;
        }
        /// Sets the vertical padding of the element to 80%.
        pub fn py_4_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.8);
            s.padding.bottom = def_rel(0.8);
            return self;
        }
        /// Sets the vertical padding of the element to negative 80%.
        pub fn py_neg_4_5(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.8);
            s.padding.bottom = def_rel(-0.8);
            return self;
        }
        /// Sets the vertical padding of the element to 16.6667%.
        pub fn py_1_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.16666666666666666);
            s.padding.bottom = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the vertical padding of the element to negative 16.6667%.
        pub fn py_neg_1_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.16666666666666666);
            s.padding.bottom = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the vertical padding of the element to 83.3333%.
        pub fn py_5_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.8333333333333334);
            s.padding.bottom = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the vertical padding of the element to negative 83.3333%.
        pub fn py_neg_5_6(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.8333333333333334);
            s.padding.bottom = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the vertical padding of the element to 8.33333%.
        pub fn py_1_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(0.08333333333333333);
            s.padding.bottom = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the vertical padding of the element to negative 8.33333%.
        pub fn py_neg_1_12(self: Self) Self {
            const s = self.style();
            s.padding.top = def_rel(-0.08333333333333333);
            s.padding.bottom = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the left padding of the element.
        pub fn pl(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.left = v;
            return self;
        }
        /// Sets the left padding of the element to 0px.
        pub fn pl_0(self: Self) Self {
            self.style().padding.left = def_px(0.0);
            return self;
        }
        /// Sets the left padding of the element to negative 0px.
        pub fn pl_neg_0(self: Self) Self {
            self.style().padding.left = def_px(-0.0);
            return self;
        }
        /// Sets the left padding of the element to 2px (0.125rem).
        pub fn pl_0p5(self: Self) Self {
            self.style().padding.left = def_rem(0.125);
            return self;
        }
        /// Sets the left padding of the element to negative 2px (0.125rem).
        pub fn pl_neg_0p5(self: Self) Self {
            self.style().padding.left = def_rem(-0.125);
            return self;
        }
        /// Sets the left padding of the element to 4px (0.25rem).
        pub fn pl_1(self: Self) Self {
            self.style().padding.left = def_rem(0.25);
            return self;
        }
        /// Sets the left padding of the element to negative 4px (0.25rem).
        pub fn pl_neg_1(self: Self) Self {
            self.style().padding.left = def_rem(-0.25);
            return self;
        }
        /// Sets the left padding of the element to 6px (0.375rem).
        pub fn pl_1p5(self: Self) Self {
            self.style().padding.left = def_rem(0.375);
            return self;
        }
        /// Sets the left padding of the element to negative 6px (0.375rem).
        pub fn pl_neg_1p5(self: Self) Self {
            self.style().padding.left = def_rem(-0.375);
            return self;
        }
        /// Sets the left padding of the element to 8px (0.5rem).
        pub fn pl_2(self: Self) Self {
            self.style().padding.left = def_rem(0.5);
            return self;
        }
        /// Sets the left padding of the element to negative 8px (0.5rem).
        pub fn pl_neg_2(self: Self) Self {
            self.style().padding.left = def_rem(-0.5);
            return self;
        }
        /// Sets the left padding of the element to 10px (0.625rem).
        pub fn pl_2p5(self: Self) Self {
            self.style().padding.left = def_rem(0.625);
            return self;
        }
        /// Sets the left padding of the element to negative 10px (0.625rem).
        pub fn pl_neg_2p5(self: Self) Self {
            self.style().padding.left = def_rem(-0.625);
            return self;
        }
        /// Sets the left padding of the element to 12px (0.75rem).
        pub fn pl_3(self: Self) Self {
            self.style().padding.left = def_rem(0.75);
            return self;
        }
        /// Sets the left padding of the element to negative 12px (0.75rem).
        pub fn pl_neg_3(self: Self) Self {
            self.style().padding.left = def_rem(-0.75);
            return self;
        }
        /// Sets the left padding of the element to 14px (0.875rem).
        pub fn pl_3p5(self: Self) Self {
            self.style().padding.left = def_rem(0.875);
            return self;
        }
        /// Sets the left padding of the element to negative 14px (0.875rem).
        pub fn pl_neg_3p5(self: Self) Self {
            self.style().padding.left = def_rem(-0.875);
            return self;
        }
        /// Sets the left padding of the element to 16px (1rem).
        pub fn pl_4(self: Self) Self {
            self.style().padding.left = def_rem(1.0);
            return self;
        }
        /// Sets the left padding of the element to negative 16px (1rem).
        pub fn pl_neg_4(self: Self) Self {
            self.style().padding.left = def_rem(-1.0);
            return self;
        }
        /// Sets the left padding of the element to 20px (1.25rem).
        pub fn pl_5(self: Self) Self {
            self.style().padding.left = def_rem(1.25);
            return self;
        }
        /// Sets the left padding of the element to negative 20px (1.25rem).
        pub fn pl_neg_5(self: Self) Self {
            self.style().padding.left = def_rem(-1.25);
            return self;
        }
        /// Sets the left padding of the element to 24px (1.5rem).
        pub fn pl_6(self: Self) Self {
            self.style().padding.left = def_rem(1.5);
            return self;
        }
        /// Sets the left padding of the element to negative 24px (1.5rem).
        pub fn pl_neg_6(self: Self) Self {
            self.style().padding.left = def_rem(-1.5);
            return self;
        }
        /// Sets the left padding of the element to 28px (1.75rem).
        pub fn pl_7(self: Self) Self {
            self.style().padding.left = def_rem(1.75);
            return self;
        }
        /// Sets the left padding of the element to negative 28px (1.75rem).
        pub fn pl_neg_7(self: Self) Self {
            self.style().padding.left = def_rem(-1.75);
            return self;
        }
        /// Sets the left padding of the element to 32px (2rem).
        pub fn pl_8(self: Self) Self {
            self.style().padding.left = def_rem(2.0);
            return self;
        }
        /// Sets the left padding of the element to negative 32px (2rem).
        pub fn pl_neg_8(self: Self) Self {
            self.style().padding.left = def_rem(-2.0);
            return self;
        }
        /// Sets the left padding of the element to 36px (2.25rem).
        pub fn pl_9(self: Self) Self {
            self.style().padding.left = def_rem(2.25);
            return self;
        }
        /// Sets the left padding of the element to negative 36px (2.25rem).
        pub fn pl_neg_9(self: Self) Self {
            self.style().padding.left = def_rem(-2.25);
            return self;
        }
        /// Sets the left padding of the element to 40px (2.5rem).
        pub fn pl_10(self: Self) Self {
            self.style().padding.left = def_rem(2.5);
            return self;
        }
        /// Sets the left padding of the element to negative 40px (2.5rem).
        pub fn pl_neg_10(self: Self) Self {
            self.style().padding.left = def_rem(-2.5);
            return self;
        }
        /// Sets the left padding of the element to 44px (2.75rem).
        pub fn pl_11(self: Self) Self {
            self.style().padding.left = def_rem(2.75);
            return self;
        }
        /// Sets the left padding of the element to negative 44px (2.75rem).
        pub fn pl_neg_11(self: Self) Self {
            self.style().padding.left = def_rem(-2.75);
            return self;
        }
        /// Sets the left padding of the element to 48px (3rem).
        pub fn pl_12(self: Self) Self {
            self.style().padding.left = def_rem(3.0);
            return self;
        }
        /// Sets the left padding of the element to negative 48px (3rem).
        pub fn pl_neg_12(self: Self) Self {
            self.style().padding.left = def_rem(-3.0);
            return self;
        }
        /// Sets the left padding of the element to 64px (4rem).
        pub fn pl_16(self: Self) Self {
            self.style().padding.left = def_rem(4.0);
            return self;
        }
        /// Sets the left padding of the element to negative 64px (4rem).
        pub fn pl_neg_16(self: Self) Self {
            self.style().padding.left = def_rem(-4.0);
            return self;
        }
        /// Sets the left padding of the element to 80px (5rem).
        pub fn pl_20(self: Self) Self {
            self.style().padding.left = def_rem(5.0);
            return self;
        }
        /// Sets the left padding of the element to negative 80px (5rem).
        pub fn pl_neg_20(self: Self) Self {
            self.style().padding.left = def_rem(-5.0);
            return self;
        }
        /// Sets the left padding of the element to 96px (6rem).
        pub fn pl_24(self: Self) Self {
            self.style().padding.left = def_rem(6.0);
            return self;
        }
        /// Sets the left padding of the element to negative 96px (6rem).
        pub fn pl_neg_24(self: Self) Self {
            self.style().padding.left = def_rem(-6.0);
            return self;
        }
        /// Sets the left padding of the element to 128px (8rem).
        pub fn pl_32(self: Self) Self {
            self.style().padding.left = def_rem(8.0);
            return self;
        }
        /// Sets the left padding of the element to negative 128px (8rem).
        pub fn pl_neg_32(self: Self) Self {
            self.style().padding.left = def_rem(-8.0);
            return self;
        }
        /// Sets the left padding of the element to 160px (10rem).
        pub fn pl_40(self: Self) Self {
            self.style().padding.left = def_rem(10.0);
            return self;
        }
        /// Sets the left padding of the element to negative 160px (10rem).
        pub fn pl_neg_40(self: Self) Self {
            self.style().padding.left = def_rem(-10.0);
            return self;
        }
        /// Sets the left padding of the element to 192px (12rem).
        pub fn pl_48(self: Self) Self {
            self.style().padding.left = def_rem(12.0);
            return self;
        }
        /// Sets the left padding of the element to negative 192px (12rem).
        pub fn pl_neg_48(self: Self) Self {
            self.style().padding.left = def_rem(-12.0);
            return self;
        }
        /// Sets the left padding of the element to 224px (14rem).
        pub fn pl_56(self: Self) Self {
            self.style().padding.left = def_rem(14.0);
            return self;
        }
        /// Sets the left padding of the element to negative 224px (14rem).
        pub fn pl_neg_56(self: Self) Self {
            self.style().padding.left = def_rem(-14.0);
            return self;
        }
        /// Sets the left padding of the element to 256px (16rem).
        pub fn pl_64(self: Self) Self {
            self.style().padding.left = def_rem(16.0);
            return self;
        }
        /// Sets the left padding of the element to negative 256px (16rem).
        pub fn pl_neg_64(self: Self) Self {
            self.style().padding.left = def_rem(-16.0);
            return self;
        }
        /// Sets the left padding of the element to 288px (18rem).
        pub fn pl_72(self: Self) Self {
            self.style().padding.left = def_rem(18.0);
            return self;
        }
        /// Sets the left padding of the element to negative 288px (18rem).
        pub fn pl_neg_72(self: Self) Self {
            self.style().padding.left = def_rem(-18.0);
            return self;
        }
        /// Sets the left padding of the element to 320px (20rem).
        pub fn pl_80(self: Self) Self {
            self.style().padding.left = def_rem(20.0);
            return self;
        }
        /// Sets the left padding of the element to negative 320px (20rem).
        pub fn pl_neg_80(self: Self) Self {
            self.style().padding.left = def_rem(-20.0);
            return self;
        }
        /// Sets the left padding of the element to 384px (24rem).
        pub fn pl_96(self: Self) Self {
            self.style().padding.left = def_rem(24.0);
            return self;
        }
        /// Sets the left padding of the element to negative 384px (24rem).
        pub fn pl_neg_96(self: Self) Self {
            self.style().padding.left = def_rem(-24.0);
            return self;
        }
        /// Sets the left padding of the element to 448px (28rem).
        pub fn pl_112(self: Self) Self {
            self.style().padding.left = def_rem(28.0);
            return self;
        }
        /// Sets the left padding of the element to negative 448px (28rem).
        pub fn pl_neg_112(self: Self) Self {
            self.style().padding.left = def_rem(-28.0);
            return self;
        }
        /// Sets the left padding of the element to 512px (32rem).
        pub fn pl_128(self: Self) Self {
            self.style().padding.left = def_rem(32.0);
            return self;
        }
        /// Sets the left padding of the element to negative 512px (32rem).
        pub fn pl_neg_128(self: Self) Self {
            self.style().padding.left = def_rem(-32.0);
            return self;
        }
        /// Sets the left padding of the element to 1px.
        pub fn pl_px(self: Self) Self {
            self.style().padding.left = def_px(1.0);
            return self;
        }
        /// Sets the left padding of the element to negative 1px.
        pub fn pl_neg_px(self: Self) Self {
            self.style().padding.left = def_px(-1.0);
            return self;
        }
        /// Sets the left padding of the element to 100%.
        pub fn pl_full(self: Self) Self {
            self.style().padding.left = def_rel(1.0);
            return self;
        }
        /// Sets the left padding of the element to negative 100%.
        pub fn pl_neg_full(self: Self) Self {
            self.style().padding.left = def_rel(-1.0);
            return self;
        }
        /// Sets the left padding of the element to 50%.
        pub fn pl_1_2(self: Self) Self {
            self.style().padding.left = def_rel(0.5);
            return self;
        }
        /// Sets the left padding of the element to negative 50%.
        pub fn pl_neg_1_2(self: Self) Self {
            self.style().padding.left = def_rel(-0.5);
            return self;
        }
        /// Sets the left padding of the element to 33.3333%.
        pub fn pl_1_3(self: Self) Self {
            self.style().padding.left = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the left padding of the element to negative 33.3333%.
        pub fn pl_neg_1_3(self: Self) Self {
            self.style().padding.left = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the left padding of the element to 66.6667%.
        pub fn pl_2_3(self: Self) Self {
            self.style().padding.left = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the left padding of the element to negative 66.6667%.
        pub fn pl_neg_2_3(self: Self) Self {
            self.style().padding.left = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the left padding of the element to 25%.
        pub fn pl_1_4(self: Self) Self {
            self.style().padding.left = def_rel(0.25);
            return self;
        }
        /// Sets the left padding of the element to negative 25%.
        pub fn pl_neg_1_4(self: Self) Self {
            self.style().padding.left = def_rel(-0.25);
            return self;
        }
        /// Sets the left padding of the element to 50%.
        pub fn pl_2_4(self: Self) Self {
            self.style().padding.left = def_rel(0.5);
            return self;
        }
        /// Sets the left padding of the element to negative 50%.
        pub fn pl_neg_2_4(self: Self) Self {
            self.style().padding.left = def_rel(-0.5);
            return self;
        }
        /// Sets the left padding of the element to 75%.
        pub fn pl_3_4(self: Self) Self {
            self.style().padding.left = def_rel(0.75);
            return self;
        }
        /// Sets the left padding of the element to negative 75%.
        pub fn pl_neg_3_4(self: Self) Self {
            self.style().padding.left = def_rel(-0.75);
            return self;
        }
        /// Sets the left padding of the element to 20%.
        pub fn pl_1_5(self: Self) Self {
            self.style().padding.left = def_rel(0.2);
            return self;
        }
        /// Sets the left padding of the element to negative 20%.
        pub fn pl_neg_1_5(self: Self) Self {
            self.style().padding.left = def_rel(-0.2);
            return self;
        }
        /// Sets the left padding of the element to 40%.
        pub fn pl_2_5(self: Self) Self {
            self.style().padding.left = def_rel(0.4);
            return self;
        }
        /// Sets the left padding of the element to negative 40%.
        pub fn pl_neg_2_5(self: Self) Self {
            self.style().padding.left = def_rel(-0.4);
            return self;
        }
        /// Sets the left padding of the element to 60%.
        pub fn pl_3_5(self: Self) Self {
            self.style().padding.left = def_rel(0.6);
            return self;
        }
        /// Sets the left padding of the element to negative 60%.
        pub fn pl_neg_3_5(self: Self) Self {
            self.style().padding.left = def_rel(-0.6);
            return self;
        }
        /// Sets the left padding of the element to 80%.
        pub fn pl_4_5(self: Self) Self {
            self.style().padding.left = def_rel(0.8);
            return self;
        }
        /// Sets the left padding of the element to negative 80%.
        pub fn pl_neg_4_5(self: Self) Self {
            self.style().padding.left = def_rel(-0.8);
            return self;
        }
        /// Sets the left padding of the element to 16.6667%.
        pub fn pl_1_6(self: Self) Self {
            self.style().padding.left = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the left padding of the element to negative 16.6667%.
        pub fn pl_neg_1_6(self: Self) Self {
            self.style().padding.left = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the left padding of the element to 83.3333%.
        pub fn pl_5_6(self: Self) Self {
            self.style().padding.left = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the left padding of the element to negative 83.3333%.
        pub fn pl_neg_5_6(self: Self) Self {
            self.style().padding.left = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the left padding of the element to 8.33333%.
        pub fn pl_1_12(self: Self) Self {
            self.style().padding.left = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the left padding of the element to negative 8.33333%.
        pub fn pl_neg_1_12(self: Self) Self {
            self.style().padding.left = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the right padding of the element.
        pub fn pr(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.padding.right = v;
            return self;
        }
        /// Sets the right padding of the element to 0px.
        pub fn pr_0(self: Self) Self {
            self.style().padding.right = def_px(0.0);
            return self;
        }
        /// Sets the right padding of the element to negative 0px.
        pub fn pr_neg_0(self: Self) Self {
            self.style().padding.right = def_px(-0.0);
            return self;
        }
        /// Sets the right padding of the element to 2px (0.125rem).
        pub fn pr_0p5(self: Self) Self {
            self.style().padding.right = def_rem(0.125);
            return self;
        }
        /// Sets the right padding of the element to negative 2px (0.125rem).
        pub fn pr_neg_0p5(self: Self) Self {
            self.style().padding.right = def_rem(-0.125);
            return self;
        }
        /// Sets the right padding of the element to 4px (0.25rem).
        pub fn pr_1(self: Self) Self {
            self.style().padding.right = def_rem(0.25);
            return self;
        }
        /// Sets the right padding of the element to negative 4px (0.25rem).
        pub fn pr_neg_1(self: Self) Self {
            self.style().padding.right = def_rem(-0.25);
            return self;
        }
        /// Sets the right padding of the element to 6px (0.375rem).
        pub fn pr_1p5(self: Self) Self {
            self.style().padding.right = def_rem(0.375);
            return self;
        }
        /// Sets the right padding of the element to negative 6px (0.375rem).
        pub fn pr_neg_1p5(self: Self) Self {
            self.style().padding.right = def_rem(-0.375);
            return self;
        }
        /// Sets the right padding of the element to 8px (0.5rem).
        pub fn pr_2(self: Self) Self {
            self.style().padding.right = def_rem(0.5);
            return self;
        }
        /// Sets the right padding of the element to negative 8px (0.5rem).
        pub fn pr_neg_2(self: Self) Self {
            self.style().padding.right = def_rem(-0.5);
            return self;
        }
        /// Sets the right padding of the element to 10px (0.625rem).
        pub fn pr_2p5(self: Self) Self {
            self.style().padding.right = def_rem(0.625);
            return self;
        }
        /// Sets the right padding of the element to negative 10px (0.625rem).
        pub fn pr_neg_2p5(self: Self) Self {
            self.style().padding.right = def_rem(-0.625);
            return self;
        }
        /// Sets the right padding of the element to 12px (0.75rem).
        pub fn pr_3(self: Self) Self {
            self.style().padding.right = def_rem(0.75);
            return self;
        }
        /// Sets the right padding of the element to negative 12px (0.75rem).
        pub fn pr_neg_3(self: Self) Self {
            self.style().padding.right = def_rem(-0.75);
            return self;
        }
        /// Sets the right padding of the element to 14px (0.875rem).
        pub fn pr_3p5(self: Self) Self {
            self.style().padding.right = def_rem(0.875);
            return self;
        }
        /// Sets the right padding of the element to negative 14px (0.875rem).
        pub fn pr_neg_3p5(self: Self) Self {
            self.style().padding.right = def_rem(-0.875);
            return self;
        }
        /// Sets the right padding of the element to 16px (1rem).
        pub fn pr_4(self: Self) Self {
            self.style().padding.right = def_rem(1.0);
            return self;
        }
        /// Sets the right padding of the element to negative 16px (1rem).
        pub fn pr_neg_4(self: Self) Self {
            self.style().padding.right = def_rem(-1.0);
            return self;
        }
        /// Sets the right padding of the element to 20px (1.25rem).
        pub fn pr_5(self: Self) Self {
            self.style().padding.right = def_rem(1.25);
            return self;
        }
        /// Sets the right padding of the element to negative 20px (1.25rem).
        pub fn pr_neg_5(self: Self) Self {
            self.style().padding.right = def_rem(-1.25);
            return self;
        }
        /// Sets the right padding of the element to 24px (1.5rem).
        pub fn pr_6(self: Self) Self {
            self.style().padding.right = def_rem(1.5);
            return self;
        }
        /// Sets the right padding of the element to negative 24px (1.5rem).
        pub fn pr_neg_6(self: Self) Self {
            self.style().padding.right = def_rem(-1.5);
            return self;
        }
        /// Sets the right padding of the element to 28px (1.75rem).
        pub fn pr_7(self: Self) Self {
            self.style().padding.right = def_rem(1.75);
            return self;
        }
        /// Sets the right padding of the element to negative 28px (1.75rem).
        pub fn pr_neg_7(self: Self) Self {
            self.style().padding.right = def_rem(-1.75);
            return self;
        }
        /// Sets the right padding of the element to 32px (2rem).
        pub fn pr_8(self: Self) Self {
            self.style().padding.right = def_rem(2.0);
            return self;
        }
        /// Sets the right padding of the element to negative 32px (2rem).
        pub fn pr_neg_8(self: Self) Self {
            self.style().padding.right = def_rem(-2.0);
            return self;
        }
        /// Sets the right padding of the element to 36px (2.25rem).
        pub fn pr_9(self: Self) Self {
            self.style().padding.right = def_rem(2.25);
            return self;
        }
        /// Sets the right padding of the element to negative 36px (2.25rem).
        pub fn pr_neg_9(self: Self) Self {
            self.style().padding.right = def_rem(-2.25);
            return self;
        }
        /// Sets the right padding of the element to 40px (2.5rem).
        pub fn pr_10(self: Self) Self {
            self.style().padding.right = def_rem(2.5);
            return self;
        }
        /// Sets the right padding of the element to negative 40px (2.5rem).
        pub fn pr_neg_10(self: Self) Self {
            self.style().padding.right = def_rem(-2.5);
            return self;
        }
        /// Sets the right padding of the element to 44px (2.75rem).
        pub fn pr_11(self: Self) Self {
            self.style().padding.right = def_rem(2.75);
            return self;
        }
        /// Sets the right padding of the element to negative 44px (2.75rem).
        pub fn pr_neg_11(self: Self) Self {
            self.style().padding.right = def_rem(-2.75);
            return self;
        }
        /// Sets the right padding of the element to 48px (3rem).
        pub fn pr_12(self: Self) Self {
            self.style().padding.right = def_rem(3.0);
            return self;
        }
        /// Sets the right padding of the element to negative 48px (3rem).
        pub fn pr_neg_12(self: Self) Self {
            self.style().padding.right = def_rem(-3.0);
            return self;
        }
        /// Sets the right padding of the element to 64px (4rem).
        pub fn pr_16(self: Self) Self {
            self.style().padding.right = def_rem(4.0);
            return self;
        }
        /// Sets the right padding of the element to negative 64px (4rem).
        pub fn pr_neg_16(self: Self) Self {
            self.style().padding.right = def_rem(-4.0);
            return self;
        }
        /// Sets the right padding of the element to 80px (5rem).
        pub fn pr_20(self: Self) Self {
            self.style().padding.right = def_rem(5.0);
            return self;
        }
        /// Sets the right padding of the element to negative 80px (5rem).
        pub fn pr_neg_20(self: Self) Self {
            self.style().padding.right = def_rem(-5.0);
            return self;
        }
        /// Sets the right padding of the element to 96px (6rem).
        pub fn pr_24(self: Self) Self {
            self.style().padding.right = def_rem(6.0);
            return self;
        }
        /// Sets the right padding of the element to negative 96px (6rem).
        pub fn pr_neg_24(self: Self) Self {
            self.style().padding.right = def_rem(-6.0);
            return self;
        }
        /// Sets the right padding of the element to 128px (8rem).
        pub fn pr_32(self: Self) Self {
            self.style().padding.right = def_rem(8.0);
            return self;
        }
        /// Sets the right padding of the element to negative 128px (8rem).
        pub fn pr_neg_32(self: Self) Self {
            self.style().padding.right = def_rem(-8.0);
            return self;
        }
        /// Sets the right padding of the element to 160px (10rem).
        pub fn pr_40(self: Self) Self {
            self.style().padding.right = def_rem(10.0);
            return self;
        }
        /// Sets the right padding of the element to negative 160px (10rem).
        pub fn pr_neg_40(self: Self) Self {
            self.style().padding.right = def_rem(-10.0);
            return self;
        }
        /// Sets the right padding of the element to 192px (12rem).
        pub fn pr_48(self: Self) Self {
            self.style().padding.right = def_rem(12.0);
            return self;
        }
        /// Sets the right padding of the element to negative 192px (12rem).
        pub fn pr_neg_48(self: Self) Self {
            self.style().padding.right = def_rem(-12.0);
            return self;
        }
        /// Sets the right padding of the element to 224px (14rem).
        pub fn pr_56(self: Self) Self {
            self.style().padding.right = def_rem(14.0);
            return self;
        }
        /// Sets the right padding of the element to negative 224px (14rem).
        pub fn pr_neg_56(self: Self) Self {
            self.style().padding.right = def_rem(-14.0);
            return self;
        }
        /// Sets the right padding of the element to 256px (16rem).
        pub fn pr_64(self: Self) Self {
            self.style().padding.right = def_rem(16.0);
            return self;
        }
        /// Sets the right padding of the element to negative 256px (16rem).
        pub fn pr_neg_64(self: Self) Self {
            self.style().padding.right = def_rem(-16.0);
            return self;
        }
        /// Sets the right padding of the element to 288px (18rem).
        pub fn pr_72(self: Self) Self {
            self.style().padding.right = def_rem(18.0);
            return self;
        }
        /// Sets the right padding of the element to negative 288px (18rem).
        pub fn pr_neg_72(self: Self) Self {
            self.style().padding.right = def_rem(-18.0);
            return self;
        }
        /// Sets the right padding of the element to 320px (20rem).
        pub fn pr_80(self: Self) Self {
            self.style().padding.right = def_rem(20.0);
            return self;
        }
        /// Sets the right padding of the element to negative 320px (20rem).
        pub fn pr_neg_80(self: Self) Self {
            self.style().padding.right = def_rem(-20.0);
            return self;
        }
        /// Sets the right padding of the element to 384px (24rem).
        pub fn pr_96(self: Self) Self {
            self.style().padding.right = def_rem(24.0);
            return self;
        }
        /// Sets the right padding of the element to negative 384px (24rem).
        pub fn pr_neg_96(self: Self) Self {
            self.style().padding.right = def_rem(-24.0);
            return self;
        }
        /// Sets the right padding of the element to 448px (28rem).
        pub fn pr_112(self: Self) Self {
            self.style().padding.right = def_rem(28.0);
            return self;
        }
        /// Sets the right padding of the element to negative 448px (28rem).
        pub fn pr_neg_112(self: Self) Self {
            self.style().padding.right = def_rem(-28.0);
            return self;
        }
        /// Sets the right padding of the element to 512px (32rem).
        pub fn pr_128(self: Self) Self {
            self.style().padding.right = def_rem(32.0);
            return self;
        }
        /// Sets the right padding of the element to negative 512px (32rem).
        pub fn pr_neg_128(self: Self) Self {
            self.style().padding.right = def_rem(-32.0);
            return self;
        }
        /// Sets the right padding of the element to 1px.
        pub fn pr_px(self: Self) Self {
            self.style().padding.right = def_px(1.0);
            return self;
        }
        /// Sets the right padding of the element to negative 1px.
        pub fn pr_neg_px(self: Self) Self {
            self.style().padding.right = def_px(-1.0);
            return self;
        }
        /// Sets the right padding of the element to 100%.
        pub fn pr_full(self: Self) Self {
            self.style().padding.right = def_rel(1.0);
            return self;
        }
        /// Sets the right padding of the element to negative 100%.
        pub fn pr_neg_full(self: Self) Self {
            self.style().padding.right = def_rel(-1.0);
            return self;
        }
        /// Sets the right padding of the element to 50%.
        pub fn pr_1_2(self: Self) Self {
            self.style().padding.right = def_rel(0.5);
            return self;
        }
        /// Sets the right padding of the element to negative 50%.
        pub fn pr_neg_1_2(self: Self) Self {
            self.style().padding.right = def_rel(-0.5);
            return self;
        }
        /// Sets the right padding of the element to 33.3333%.
        pub fn pr_1_3(self: Self) Self {
            self.style().padding.right = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the right padding of the element to negative 33.3333%.
        pub fn pr_neg_1_3(self: Self) Self {
            self.style().padding.right = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the right padding of the element to 66.6667%.
        pub fn pr_2_3(self: Self) Self {
            self.style().padding.right = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the right padding of the element to negative 66.6667%.
        pub fn pr_neg_2_3(self: Self) Self {
            self.style().padding.right = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the right padding of the element to 25%.
        pub fn pr_1_4(self: Self) Self {
            self.style().padding.right = def_rel(0.25);
            return self;
        }
        /// Sets the right padding of the element to negative 25%.
        pub fn pr_neg_1_4(self: Self) Self {
            self.style().padding.right = def_rel(-0.25);
            return self;
        }
        /// Sets the right padding of the element to 50%.
        pub fn pr_2_4(self: Self) Self {
            self.style().padding.right = def_rel(0.5);
            return self;
        }
        /// Sets the right padding of the element to negative 50%.
        pub fn pr_neg_2_4(self: Self) Self {
            self.style().padding.right = def_rel(-0.5);
            return self;
        }
        /// Sets the right padding of the element to 75%.
        pub fn pr_3_4(self: Self) Self {
            self.style().padding.right = def_rel(0.75);
            return self;
        }
        /// Sets the right padding of the element to negative 75%.
        pub fn pr_neg_3_4(self: Self) Self {
            self.style().padding.right = def_rel(-0.75);
            return self;
        }
        /// Sets the right padding of the element to 20%.
        pub fn pr_1_5(self: Self) Self {
            self.style().padding.right = def_rel(0.2);
            return self;
        }
        /// Sets the right padding of the element to negative 20%.
        pub fn pr_neg_1_5(self: Self) Self {
            self.style().padding.right = def_rel(-0.2);
            return self;
        }
        /// Sets the right padding of the element to 40%.
        pub fn pr_2_5(self: Self) Self {
            self.style().padding.right = def_rel(0.4);
            return self;
        }
        /// Sets the right padding of the element to negative 40%.
        pub fn pr_neg_2_5(self: Self) Self {
            self.style().padding.right = def_rel(-0.4);
            return self;
        }
        /// Sets the right padding of the element to 60%.
        pub fn pr_3_5(self: Self) Self {
            self.style().padding.right = def_rel(0.6);
            return self;
        }
        /// Sets the right padding of the element to negative 60%.
        pub fn pr_neg_3_5(self: Self) Self {
            self.style().padding.right = def_rel(-0.6);
            return self;
        }
        /// Sets the right padding of the element to 80%.
        pub fn pr_4_5(self: Self) Self {
            self.style().padding.right = def_rel(0.8);
            return self;
        }
        /// Sets the right padding of the element to negative 80%.
        pub fn pr_neg_4_5(self: Self) Self {
            self.style().padding.right = def_rel(-0.8);
            return self;
        }
        /// Sets the right padding of the element to 16.6667%.
        pub fn pr_1_6(self: Self) Self {
            self.style().padding.right = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the right padding of the element to negative 16.6667%.
        pub fn pr_neg_1_6(self: Self) Self {
            self.style().padding.right = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the right padding of the element to 83.3333%.
        pub fn pr_5_6(self: Self) Self {
            self.style().padding.right = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the right padding of the element to negative 83.3333%.
        pub fn pr_neg_5_6(self: Self) Self {
            self.style().padding.right = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the right padding of the element to 8.33333%.
        pub fn pr_1_12(self: Self) Self {
            self.style().padding.right = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the right padding of the element to negative 8.33333%.
        pub fn pr_neg_1_12(self: Self) Self {
            self.style().padding.right = def_rel(-0.08333333333333333);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element.
        pub fn inset(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.inset.top = v;
            s.inset.right = v;
            s.inset.bottom = v;
            s.inset.left = v;
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 0px.
        pub fn inset_0(self: Self) Self {
            const s = self.style();
            s.inset.top = len_px(0.0);
            s.inset.right = len_px(0.0);
            s.inset.bottom = len_px(0.0);
            s.inset.left = len_px(0.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 0px.
        pub fn inset_neg_0(self: Self) Self {
            const s = self.style();
            s.inset.top = len_px(-0.0);
            s.inset.right = len_px(-0.0);
            s.inset.bottom = len_px(-0.0);
            s.inset.left = len_px(-0.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 2px (0.125rem).
        pub fn inset_0p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.125);
            s.inset.right = len_rem(0.125);
            s.inset.bottom = len_rem(0.125);
            s.inset.left = len_rem(0.125);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 2px (0.125rem).
        pub fn inset_neg_0p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.125);
            s.inset.right = len_rem(-0.125);
            s.inset.bottom = len_rem(-0.125);
            s.inset.left = len_rem(-0.125);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 4px (0.25rem).
        pub fn inset_1(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.25);
            s.inset.right = len_rem(0.25);
            s.inset.bottom = len_rem(0.25);
            s.inset.left = len_rem(0.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 4px (0.25rem).
        pub fn inset_neg_1(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.25);
            s.inset.right = len_rem(-0.25);
            s.inset.bottom = len_rem(-0.25);
            s.inset.left = len_rem(-0.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 6px (0.375rem).
        pub fn inset_1p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.375);
            s.inset.right = len_rem(0.375);
            s.inset.bottom = len_rem(0.375);
            s.inset.left = len_rem(0.375);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 6px (0.375rem).
        pub fn inset_neg_1p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.375);
            s.inset.right = len_rem(-0.375);
            s.inset.bottom = len_rem(-0.375);
            s.inset.left = len_rem(-0.375);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 8px (0.5rem).
        pub fn inset_2(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.5);
            s.inset.right = len_rem(0.5);
            s.inset.bottom = len_rem(0.5);
            s.inset.left = len_rem(0.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 8px (0.5rem).
        pub fn inset_neg_2(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.5);
            s.inset.right = len_rem(-0.5);
            s.inset.bottom = len_rem(-0.5);
            s.inset.left = len_rem(-0.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 10px (0.625rem).
        pub fn inset_2p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.625);
            s.inset.right = len_rem(0.625);
            s.inset.bottom = len_rem(0.625);
            s.inset.left = len_rem(0.625);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 10px (0.625rem).
        pub fn inset_neg_2p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.625);
            s.inset.right = len_rem(-0.625);
            s.inset.bottom = len_rem(-0.625);
            s.inset.left = len_rem(-0.625);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 12px (0.75rem).
        pub fn inset_3(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.75);
            s.inset.right = len_rem(0.75);
            s.inset.bottom = len_rem(0.75);
            s.inset.left = len_rem(0.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 12px (0.75rem).
        pub fn inset_neg_3(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.75);
            s.inset.right = len_rem(-0.75);
            s.inset.bottom = len_rem(-0.75);
            s.inset.left = len_rem(-0.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 14px (0.875rem).
        pub fn inset_3p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(0.875);
            s.inset.right = len_rem(0.875);
            s.inset.bottom = len_rem(0.875);
            s.inset.left = len_rem(0.875);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 14px (0.875rem).
        pub fn inset_neg_3p5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-0.875);
            s.inset.right = len_rem(-0.875);
            s.inset.bottom = len_rem(-0.875);
            s.inset.left = len_rem(-0.875);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 16px (1rem).
        pub fn inset_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(1.0);
            s.inset.right = len_rem(1.0);
            s.inset.bottom = len_rem(1.0);
            s.inset.left = len_rem(1.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 16px (1rem).
        pub fn inset_neg_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-1.0);
            s.inset.right = len_rem(-1.0);
            s.inset.bottom = len_rem(-1.0);
            s.inset.left = len_rem(-1.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 20px (1.25rem).
        pub fn inset_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(1.25);
            s.inset.right = len_rem(1.25);
            s.inset.bottom = len_rem(1.25);
            s.inset.left = len_rem(1.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 20px (1.25rem).
        pub fn inset_neg_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-1.25);
            s.inset.right = len_rem(-1.25);
            s.inset.bottom = len_rem(-1.25);
            s.inset.left = len_rem(-1.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 24px (1.5rem).
        pub fn inset_6(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(1.5);
            s.inset.right = len_rem(1.5);
            s.inset.bottom = len_rem(1.5);
            s.inset.left = len_rem(1.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 24px (1.5rem).
        pub fn inset_neg_6(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-1.5);
            s.inset.right = len_rem(-1.5);
            s.inset.bottom = len_rem(-1.5);
            s.inset.left = len_rem(-1.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 28px (1.75rem).
        pub fn inset_7(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(1.75);
            s.inset.right = len_rem(1.75);
            s.inset.bottom = len_rem(1.75);
            s.inset.left = len_rem(1.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 28px (1.75rem).
        pub fn inset_neg_7(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-1.75);
            s.inset.right = len_rem(-1.75);
            s.inset.bottom = len_rem(-1.75);
            s.inset.left = len_rem(-1.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 32px (2rem).
        pub fn inset_8(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(2.0);
            s.inset.right = len_rem(2.0);
            s.inset.bottom = len_rem(2.0);
            s.inset.left = len_rem(2.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 32px (2rem).
        pub fn inset_neg_8(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-2.0);
            s.inset.right = len_rem(-2.0);
            s.inset.bottom = len_rem(-2.0);
            s.inset.left = len_rem(-2.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 36px (2.25rem).
        pub fn inset_9(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(2.25);
            s.inset.right = len_rem(2.25);
            s.inset.bottom = len_rem(2.25);
            s.inset.left = len_rem(2.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 36px (2.25rem).
        pub fn inset_neg_9(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-2.25);
            s.inset.right = len_rem(-2.25);
            s.inset.bottom = len_rem(-2.25);
            s.inset.left = len_rem(-2.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 40px (2.5rem).
        pub fn inset_10(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(2.5);
            s.inset.right = len_rem(2.5);
            s.inset.bottom = len_rem(2.5);
            s.inset.left = len_rem(2.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 40px (2.5rem).
        pub fn inset_neg_10(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-2.5);
            s.inset.right = len_rem(-2.5);
            s.inset.bottom = len_rem(-2.5);
            s.inset.left = len_rem(-2.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 44px (2.75rem).
        pub fn inset_11(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(2.75);
            s.inset.right = len_rem(2.75);
            s.inset.bottom = len_rem(2.75);
            s.inset.left = len_rem(2.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 44px (2.75rem).
        pub fn inset_neg_11(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-2.75);
            s.inset.right = len_rem(-2.75);
            s.inset.bottom = len_rem(-2.75);
            s.inset.left = len_rem(-2.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 48px (3rem).
        pub fn inset_12(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(3.0);
            s.inset.right = len_rem(3.0);
            s.inset.bottom = len_rem(3.0);
            s.inset.left = len_rem(3.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 48px (3rem).
        pub fn inset_neg_12(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-3.0);
            s.inset.right = len_rem(-3.0);
            s.inset.bottom = len_rem(-3.0);
            s.inset.left = len_rem(-3.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 64px (4rem).
        pub fn inset_16(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(4.0);
            s.inset.right = len_rem(4.0);
            s.inset.bottom = len_rem(4.0);
            s.inset.left = len_rem(4.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 64px (4rem).
        pub fn inset_neg_16(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-4.0);
            s.inset.right = len_rem(-4.0);
            s.inset.bottom = len_rem(-4.0);
            s.inset.left = len_rem(-4.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 80px (5rem).
        pub fn inset_20(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(5.0);
            s.inset.right = len_rem(5.0);
            s.inset.bottom = len_rem(5.0);
            s.inset.left = len_rem(5.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 80px (5rem).
        pub fn inset_neg_20(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-5.0);
            s.inset.right = len_rem(-5.0);
            s.inset.bottom = len_rem(-5.0);
            s.inset.left = len_rem(-5.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 96px (6rem).
        pub fn inset_24(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(6.0);
            s.inset.right = len_rem(6.0);
            s.inset.bottom = len_rem(6.0);
            s.inset.left = len_rem(6.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 96px (6rem).
        pub fn inset_neg_24(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-6.0);
            s.inset.right = len_rem(-6.0);
            s.inset.bottom = len_rem(-6.0);
            s.inset.left = len_rem(-6.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 128px (8rem).
        pub fn inset_32(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(8.0);
            s.inset.right = len_rem(8.0);
            s.inset.bottom = len_rem(8.0);
            s.inset.left = len_rem(8.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 128px (8rem).
        pub fn inset_neg_32(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-8.0);
            s.inset.right = len_rem(-8.0);
            s.inset.bottom = len_rem(-8.0);
            s.inset.left = len_rem(-8.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 160px (10rem).
        pub fn inset_40(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(10.0);
            s.inset.right = len_rem(10.0);
            s.inset.bottom = len_rem(10.0);
            s.inset.left = len_rem(10.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 160px (10rem).
        pub fn inset_neg_40(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-10.0);
            s.inset.right = len_rem(-10.0);
            s.inset.bottom = len_rem(-10.0);
            s.inset.left = len_rem(-10.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 192px (12rem).
        pub fn inset_48(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(12.0);
            s.inset.right = len_rem(12.0);
            s.inset.bottom = len_rem(12.0);
            s.inset.left = len_rem(12.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 192px (12rem).
        pub fn inset_neg_48(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-12.0);
            s.inset.right = len_rem(-12.0);
            s.inset.bottom = len_rem(-12.0);
            s.inset.left = len_rem(-12.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 224px (14rem).
        pub fn inset_56(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(14.0);
            s.inset.right = len_rem(14.0);
            s.inset.bottom = len_rem(14.0);
            s.inset.left = len_rem(14.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 224px (14rem).
        pub fn inset_neg_56(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-14.0);
            s.inset.right = len_rem(-14.0);
            s.inset.bottom = len_rem(-14.0);
            s.inset.left = len_rem(-14.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 256px (16rem).
        pub fn inset_64(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(16.0);
            s.inset.right = len_rem(16.0);
            s.inset.bottom = len_rem(16.0);
            s.inset.left = len_rem(16.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 256px (16rem).
        pub fn inset_neg_64(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-16.0);
            s.inset.right = len_rem(-16.0);
            s.inset.bottom = len_rem(-16.0);
            s.inset.left = len_rem(-16.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 288px (18rem).
        pub fn inset_72(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(18.0);
            s.inset.right = len_rem(18.0);
            s.inset.bottom = len_rem(18.0);
            s.inset.left = len_rem(18.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 288px (18rem).
        pub fn inset_neg_72(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-18.0);
            s.inset.right = len_rem(-18.0);
            s.inset.bottom = len_rem(-18.0);
            s.inset.left = len_rem(-18.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 320px (20rem).
        pub fn inset_80(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(20.0);
            s.inset.right = len_rem(20.0);
            s.inset.bottom = len_rem(20.0);
            s.inset.left = len_rem(20.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 320px (20rem).
        pub fn inset_neg_80(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-20.0);
            s.inset.right = len_rem(-20.0);
            s.inset.bottom = len_rem(-20.0);
            s.inset.left = len_rem(-20.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 384px (24rem).
        pub fn inset_96(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(24.0);
            s.inset.right = len_rem(24.0);
            s.inset.bottom = len_rem(24.0);
            s.inset.left = len_rem(24.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 384px (24rem).
        pub fn inset_neg_96(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-24.0);
            s.inset.right = len_rem(-24.0);
            s.inset.bottom = len_rem(-24.0);
            s.inset.left = len_rem(-24.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 448px (28rem).
        pub fn inset_112(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(28.0);
            s.inset.right = len_rem(28.0);
            s.inset.bottom = len_rem(28.0);
            s.inset.left = len_rem(28.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 448px (28rem).
        pub fn inset_neg_112(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-28.0);
            s.inset.right = len_rem(-28.0);
            s.inset.bottom = len_rem(-28.0);
            s.inset.left = len_rem(-28.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 512px (32rem).
        pub fn inset_128(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(32.0);
            s.inset.right = len_rem(32.0);
            s.inset.bottom = len_rem(32.0);
            s.inset.left = len_rem(32.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 512px (32rem).
        pub fn inset_neg_128(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rem(-32.0);
            s.inset.right = len_rem(-32.0);
            s.inset.bottom = len_rem(-32.0);
            s.inset.left = len_rem(-32.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to auto.
        pub fn inset_auto(self: Self) Self {
            const s = self.style();
            s.inset.top = geometry.auto();
            s.inset.right = geometry.auto();
            s.inset.bottom = geometry.auto();
            s.inset.left = geometry.auto();
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 1px.
        pub fn inset_px(self: Self) Self {
            const s = self.style();
            s.inset.top = len_px(1.0);
            s.inset.right = len_px(1.0);
            s.inset.bottom = len_px(1.0);
            s.inset.left = len_px(1.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 1px.
        pub fn inset_neg_px(self: Self) Self {
            const s = self.style();
            s.inset.top = len_px(-1.0);
            s.inset.right = len_px(-1.0);
            s.inset.bottom = len_px(-1.0);
            s.inset.left = len_px(-1.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 100%.
        pub fn inset_full(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(1.0);
            s.inset.right = len_rel(1.0);
            s.inset.bottom = len_rel(1.0);
            s.inset.left = len_rel(1.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 100%.
        pub fn inset_neg_full(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-1.0);
            s.inset.right = len_rel(-1.0);
            s.inset.bottom = len_rel(-1.0);
            s.inset.left = len_rel(-1.0);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 50%.
        pub fn inset_1_2(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.5);
            s.inset.right = len_rel(0.5);
            s.inset.bottom = len_rel(0.5);
            s.inset.left = len_rel(0.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 50%.
        pub fn inset_neg_1_2(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.5);
            s.inset.right = len_rel(-0.5);
            s.inset.bottom = len_rel(-0.5);
            s.inset.left = len_rel(-0.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 33.3333%.
        pub fn inset_1_3(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.3333333333333333);
            s.inset.right = len_rel(0.3333333333333333);
            s.inset.bottom = len_rel(0.3333333333333333);
            s.inset.left = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 33.3333%.
        pub fn inset_neg_1_3(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.3333333333333333);
            s.inset.right = len_rel(-0.3333333333333333);
            s.inset.bottom = len_rel(-0.3333333333333333);
            s.inset.left = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 66.6667%.
        pub fn inset_2_3(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.6666666666666666);
            s.inset.right = len_rel(0.6666666666666666);
            s.inset.bottom = len_rel(0.6666666666666666);
            s.inset.left = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 66.6667%.
        pub fn inset_neg_2_3(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.6666666666666666);
            s.inset.right = len_rel(-0.6666666666666666);
            s.inset.bottom = len_rel(-0.6666666666666666);
            s.inset.left = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 25%.
        pub fn inset_1_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.25);
            s.inset.right = len_rel(0.25);
            s.inset.bottom = len_rel(0.25);
            s.inset.left = len_rel(0.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 25%.
        pub fn inset_neg_1_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.25);
            s.inset.right = len_rel(-0.25);
            s.inset.bottom = len_rel(-0.25);
            s.inset.left = len_rel(-0.25);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 50%.
        pub fn inset_2_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.5);
            s.inset.right = len_rel(0.5);
            s.inset.bottom = len_rel(0.5);
            s.inset.left = len_rel(0.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 50%.
        pub fn inset_neg_2_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.5);
            s.inset.right = len_rel(-0.5);
            s.inset.bottom = len_rel(-0.5);
            s.inset.left = len_rel(-0.5);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 75%.
        pub fn inset_3_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.75);
            s.inset.right = len_rel(0.75);
            s.inset.bottom = len_rel(0.75);
            s.inset.left = len_rel(0.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 75%.
        pub fn inset_neg_3_4(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.75);
            s.inset.right = len_rel(-0.75);
            s.inset.bottom = len_rel(-0.75);
            s.inset.left = len_rel(-0.75);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 20%.
        pub fn inset_1_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.2);
            s.inset.right = len_rel(0.2);
            s.inset.bottom = len_rel(0.2);
            s.inset.left = len_rel(0.2);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 20%.
        pub fn inset_neg_1_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.2);
            s.inset.right = len_rel(-0.2);
            s.inset.bottom = len_rel(-0.2);
            s.inset.left = len_rel(-0.2);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 40%.
        pub fn inset_2_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.4);
            s.inset.right = len_rel(0.4);
            s.inset.bottom = len_rel(0.4);
            s.inset.left = len_rel(0.4);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 40%.
        pub fn inset_neg_2_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.4);
            s.inset.right = len_rel(-0.4);
            s.inset.bottom = len_rel(-0.4);
            s.inset.left = len_rel(-0.4);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 60%.
        pub fn inset_3_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.6);
            s.inset.right = len_rel(0.6);
            s.inset.bottom = len_rel(0.6);
            s.inset.left = len_rel(0.6);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 60%.
        pub fn inset_neg_3_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.6);
            s.inset.right = len_rel(-0.6);
            s.inset.bottom = len_rel(-0.6);
            s.inset.left = len_rel(-0.6);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 80%.
        pub fn inset_4_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.8);
            s.inset.right = len_rel(0.8);
            s.inset.bottom = len_rel(0.8);
            s.inset.left = len_rel(0.8);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 80%.
        pub fn inset_neg_4_5(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.8);
            s.inset.right = len_rel(-0.8);
            s.inset.bottom = len_rel(-0.8);
            s.inset.left = len_rel(-0.8);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 16.6667%.
        pub fn inset_1_6(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.16666666666666666);
            s.inset.right = len_rel(0.16666666666666666);
            s.inset.bottom = len_rel(0.16666666666666666);
            s.inset.left = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 16.6667%.
        pub fn inset_neg_1_6(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.16666666666666666);
            s.inset.right = len_rel(-0.16666666666666666);
            s.inset.bottom = len_rel(-0.16666666666666666);
            s.inset.left = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 83.3333%.
        pub fn inset_5_6(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.8333333333333334);
            s.inset.right = len_rel(0.8333333333333334);
            s.inset.bottom = len_rel(0.8333333333333334);
            s.inset.left = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 83.3333%.
        pub fn inset_neg_5_6(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.8333333333333334);
            s.inset.right = len_rel(-0.8333333333333334);
            s.inset.bottom = len_rel(-0.8333333333333334);
            s.inset.left = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to 8.33333%.
        pub fn inset_1_12(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(0.08333333333333333);
            s.inset.right = len_rel(0.08333333333333333);
            s.inset.bottom = len_rel(0.08333333333333333);
            s.inset.left = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the top, right, bottom and left offsets of the element to negative 8.33333%.
        pub fn inset_neg_1_12(self: Self) Self {
            const s = self.style();
            s.inset.top = len_rel(-0.08333333333333333);
            s.inset.right = len_rel(-0.08333333333333333);
            s.inset.bottom = len_rel(-0.08333333333333333);
            s.inset.left = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the top offset of the element.
        pub fn top(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.inset.top = v;
            return self;
        }
        /// Sets the top offset of the element to 0px.
        pub fn top_0(self: Self) Self {
            self.style().inset.top = len_px(0.0);
            return self;
        }
        /// Sets the top offset of the element to negative 0px.
        pub fn top_neg_0(self: Self) Self {
            self.style().inset.top = len_px(-0.0);
            return self;
        }
        /// Sets the top offset of the element to 2px (0.125rem).
        pub fn top_0p5(self: Self) Self {
            self.style().inset.top = len_rem(0.125);
            return self;
        }
        /// Sets the top offset of the element to negative 2px (0.125rem).
        pub fn top_neg_0p5(self: Self) Self {
            self.style().inset.top = len_rem(-0.125);
            return self;
        }
        /// Sets the top offset of the element to 4px (0.25rem).
        pub fn top_1(self: Self) Self {
            self.style().inset.top = len_rem(0.25);
            return self;
        }
        /// Sets the top offset of the element to negative 4px (0.25rem).
        pub fn top_neg_1(self: Self) Self {
            self.style().inset.top = len_rem(-0.25);
            return self;
        }
        /// Sets the top offset of the element to 6px (0.375rem).
        pub fn top_1p5(self: Self) Self {
            self.style().inset.top = len_rem(0.375);
            return self;
        }
        /// Sets the top offset of the element to negative 6px (0.375rem).
        pub fn top_neg_1p5(self: Self) Self {
            self.style().inset.top = len_rem(-0.375);
            return self;
        }
        /// Sets the top offset of the element to 8px (0.5rem).
        pub fn top_2(self: Self) Self {
            self.style().inset.top = len_rem(0.5);
            return self;
        }
        /// Sets the top offset of the element to negative 8px (0.5rem).
        pub fn top_neg_2(self: Self) Self {
            self.style().inset.top = len_rem(-0.5);
            return self;
        }
        /// Sets the top offset of the element to 10px (0.625rem).
        pub fn top_2p5(self: Self) Self {
            self.style().inset.top = len_rem(0.625);
            return self;
        }
        /// Sets the top offset of the element to negative 10px (0.625rem).
        pub fn top_neg_2p5(self: Self) Self {
            self.style().inset.top = len_rem(-0.625);
            return self;
        }
        /// Sets the top offset of the element to 12px (0.75rem).
        pub fn top_3(self: Self) Self {
            self.style().inset.top = len_rem(0.75);
            return self;
        }
        /// Sets the top offset of the element to negative 12px (0.75rem).
        pub fn top_neg_3(self: Self) Self {
            self.style().inset.top = len_rem(-0.75);
            return self;
        }
        /// Sets the top offset of the element to 14px (0.875rem).
        pub fn top_3p5(self: Self) Self {
            self.style().inset.top = len_rem(0.875);
            return self;
        }
        /// Sets the top offset of the element to negative 14px (0.875rem).
        pub fn top_neg_3p5(self: Self) Self {
            self.style().inset.top = len_rem(-0.875);
            return self;
        }
        /// Sets the top offset of the element to 16px (1rem).
        pub fn top_4(self: Self) Self {
            self.style().inset.top = len_rem(1.0);
            return self;
        }
        /// Sets the top offset of the element to negative 16px (1rem).
        pub fn top_neg_4(self: Self) Self {
            self.style().inset.top = len_rem(-1.0);
            return self;
        }
        /// Sets the top offset of the element to 20px (1.25rem).
        pub fn top_5(self: Self) Self {
            self.style().inset.top = len_rem(1.25);
            return self;
        }
        /// Sets the top offset of the element to negative 20px (1.25rem).
        pub fn top_neg_5(self: Self) Self {
            self.style().inset.top = len_rem(-1.25);
            return self;
        }
        /// Sets the top offset of the element to 24px (1.5rem).
        pub fn top_6(self: Self) Self {
            self.style().inset.top = len_rem(1.5);
            return self;
        }
        /// Sets the top offset of the element to negative 24px (1.5rem).
        pub fn top_neg_6(self: Self) Self {
            self.style().inset.top = len_rem(-1.5);
            return self;
        }
        /// Sets the top offset of the element to 28px (1.75rem).
        pub fn top_7(self: Self) Self {
            self.style().inset.top = len_rem(1.75);
            return self;
        }
        /// Sets the top offset of the element to negative 28px (1.75rem).
        pub fn top_neg_7(self: Self) Self {
            self.style().inset.top = len_rem(-1.75);
            return self;
        }
        /// Sets the top offset of the element to 32px (2rem).
        pub fn top_8(self: Self) Self {
            self.style().inset.top = len_rem(2.0);
            return self;
        }
        /// Sets the top offset of the element to negative 32px (2rem).
        pub fn top_neg_8(self: Self) Self {
            self.style().inset.top = len_rem(-2.0);
            return self;
        }
        /// Sets the top offset of the element to 36px (2.25rem).
        pub fn top_9(self: Self) Self {
            self.style().inset.top = len_rem(2.25);
            return self;
        }
        /// Sets the top offset of the element to negative 36px (2.25rem).
        pub fn top_neg_9(self: Self) Self {
            self.style().inset.top = len_rem(-2.25);
            return self;
        }
        /// Sets the top offset of the element to 40px (2.5rem).
        pub fn top_10(self: Self) Self {
            self.style().inset.top = len_rem(2.5);
            return self;
        }
        /// Sets the top offset of the element to negative 40px (2.5rem).
        pub fn top_neg_10(self: Self) Self {
            self.style().inset.top = len_rem(-2.5);
            return self;
        }
        /// Sets the top offset of the element to 44px (2.75rem).
        pub fn top_11(self: Self) Self {
            self.style().inset.top = len_rem(2.75);
            return self;
        }
        /// Sets the top offset of the element to negative 44px (2.75rem).
        pub fn top_neg_11(self: Self) Self {
            self.style().inset.top = len_rem(-2.75);
            return self;
        }
        /// Sets the top offset of the element to 48px (3rem).
        pub fn top_12(self: Self) Self {
            self.style().inset.top = len_rem(3.0);
            return self;
        }
        /// Sets the top offset of the element to negative 48px (3rem).
        pub fn top_neg_12(self: Self) Self {
            self.style().inset.top = len_rem(-3.0);
            return self;
        }
        /// Sets the top offset of the element to 64px (4rem).
        pub fn top_16(self: Self) Self {
            self.style().inset.top = len_rem(4.0);
            return self;
        }
        /// Sets the top offset of the element to negative 64px (4rem).
        pub fn top_neg_16(self: Self) Self {
            self.style().inset.top = len_rem(-4.0);
            return self;
        }
        /// Sets the top offset of the element to 80px (5rem).
        pub fn top_20(self: Self) Self {
            self.style().inset.top = len_rem(5.0);
            return self;
        }
        /// Sets the top offset of the element to negative 80px (5rem).
        pub fn top_neg_20(self: Self) Self {
            self.style().inset.top = len_rem(-5.0);
            return self;
        }
        /// Sets the top offset of the element to 96px (6rem).
        pub fn top_24(self: Self) Self {
            self.style().inset.top = len_rem(6.0);
            return self;
        }
        /// Sets the top offset of the element to negative 96px (6rem).
        pub fn top_neg_24(self: Self) Self {
            self.style().inset.top = len_rem(-6.0);
            return self;
        }
        /// Sets the top offset of the element to 128px (8rem).
        pub fn top_32(self: Self) Self {
            self.style().inset.top = len_rem(8.0);
            return self;
        }
        /// Sets the top offset of the element to negative 128px (8rem).
        pub fn top_neg_32(self: Self) Self {
            self.style().inset.top = len_rem(-8.0);
            return self;
        }
        /// Sets the top offset of the element to 160px (10rem).
        pub fn top_40(self: Self) Self {
            self.style().inset.top = len_rem(10.0);
            return self;
        }
        /// Sets the top offset of the element to negative 160px (10rem).
        pub fn top_neg_40(self: Self) Self {
            self.style().inset.top = len_rem(-10.0);
            return self;
        }
        /// Sets the top offset of the element to 192px (12rem).
        pub fn top_48(self: Self) Self {
            self.style().inset.top = len_rem(12.0);
            return self;
        }
        /// Sets the top offset of the element to negative 192px (12rem).
        pub fn top_neg_48(self: Self) Self {
            self.style().inset.top = len_rem(-12.0);
            return self;
        }
        /// Sets the top offset of the element to 224px (14rem).
        pub fn top_56(self: Self) Self {
            self.style().inset.top = len_rem(14.0);
            return self;
        }
        /// Sets the top offset of the element to negative 224px (14rem).
        pub fn top_neg_56(self: Self) Self {
            self.style().inset.top = len_rem(-14.0);
            return self;
        }
        /// Sets the top offset of the element to 256px (16rem).
        pub fn top_64(self: Self) Self {
            self.style().inset.top = len_rem(16.0);
            return self;
        }
        /// Sets the top offset of the element to negative 256px (16rem).
        pub fn top_neg_64(self: Self) Self {
            self.style().inset.top = len_rem(-16.0);
            return self;
        }
        /// Sets the top offset of the element to 288px (18rem).
        pub fn top_72(self: Self) Self {
            self.style().inset.top = len_rem(18.0);
            return self;
        }
        /// Sets the top offset of the element to negative 288px (18rem).
        pub fn top_neg_72(self: Self) Self {
            self.style().inset.top = len_rem(-18.0);
            return self;
        }
        /// Sets the top offset of the element to 320px (20rem).
        pub fn top_80(self: Self) Self {
            self.style().inset.top = len_rem(20.0);
            return self;
        }
        /// Sets the top offset of the element to negative 320px (20rem).
        pub fn top_neg_80(self: Self) Self {
            self.style().inset.top = len_rem(-20.0);
            return self;
        }
        /// Sets the top offset of the element to 384px (24rem).
        pub fn top_96(self: Self) Self {
            self.style().inset.top = len_rem(24.0);
            return self;
        }
        /// Sets the top offset of the element to negative 384px (24rem).
        pub fn top_neg_96(self: Self) Self {
            self.style().inset.top = len_rem(-24.0);
            return self;
        }
        /// Sets the top offset of the element to 448px (28rem).
        pub fn top_112(self: Self) Self {
            self.style().inset.top = len_rem(28.0);
            return self;
        }
        /// Sets the top offset of the element to negative 448px (28rem).
        pub fn top_neg_112(self: Self) Self {
            self.style().inset.top = len_rem(-28.0);
            return self;
        }
        /// Sets the top offset of the element to 512px (32rem).
        pub fn top_128(self: Self) Self {
            self.style().inset.top = len_rem(32.0);
            return self;
        }
        /// Sets the top offset of the element to negative 512px (32rem).
        pub fn top_neg_128(self: Self) Self {
            self.style().inset.top = len_rem(-32.0);
            return self;
        }
        /// Sets the top offset of the element to auto.
        pub fn top_auto(self: Self) Self {
            self.style().inset.top = geometry.auto();
            return self;
        }
        /// Sets the top offset of the element to 1px.
        pub fn top_px(self: Self) Self {
            self.style().inset.top = len_px(1.0);
            return self;
        }
        /// Sets the top offset of the element to negative 1px.
        pub fn top_neg_px(self: Self) Self {
            self.style().inset.top = len_px(-1.0);
            return self;
        }
        /// Sets the top offset of the element to 100%.
        pub fn top_full(self: Self) Self {
            self.style().inset.top = len_rel(1.0);
            return self;
        }
        /// Sets the top offset of the element to negative 100%.
        pub fn top_neg_full(self: Self) Self {
            self.style().inset.top = len_rel(-1.0);
            return self;
        }
        /// Sets the top offset of the element to 50%.
        pub fn top_1_2(self: Self) Self {
            self.style().inset.top = len_rel(0.5);
            return self;
        }
        /// Sets the top offset of the element to negative 50%.
        pub fn top_neg_1_2(self: Self) Self {
            self.style().inset.top = len_rel(-0.5);
            return self;
        }
        /// Sets the top offset of the element to 33.3333%.
        pub fn top_1_3(self: Self) Self {
            self.style().inset.top = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the top offset of the element to negative 33.3333%.
        pub fn top_neg_1_3(self: Self) Self {
            self.style().inset.top = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the top offset of the element to 66.6667%.
        pub fn top_2_3(self: Self) Self {
            self.style().inset.top = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the top offset of the element to negative 66.6667%.
        pub fn top_neg_2_3(self: Self) Self {
            self.style().inset.top = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the top offset of the element to 25%.
        pub fn top_1_4(self: Self) Self {
            self.style().inset.top = len_rel(0.25);
            return self;
        }
        /// Sets the top offset of the element to negative 25%.
        pub fn top_neg_1_4(self: Self) Self {
            self.style().inset.top = len_rel(-0.25);
            return self;
        }
        /// Sets the top offset of the element to 50%.
        pub fn top_2_4(self: Self) Self {
            self.style().inset.top = len_rel(0.5);
            return self;
        }
        /// Sets the top offset of the element to negative 50%.
        pub fn top_neg_2_4(self: Self) Self {
            self.style().inset.top = len_rel(-0.5);
            return self;
        }
        /// Sets the top offset of the element to 75%.
        pub fn top_3_4(self: Self) Self {
            self.style().inset.top = len_rel(0.75);
            return self;
        }
        /// Sets the top offset of the element to negative 75%.
        pub fn top_neg_3_4(self: Self) Self {
            self.style().inset.top = len_rel(-0.75);
            return self;
        }
        /// Sets the top offset of the element to 20%.
        pub fn top_1_5(self: Self) Self {
            self.style().inset.top = len_rel(0.2);
            return self;
        }
        /// Sets the top offset of the element to negative 20%.
        pub fn top_neg_1_5(self: Self) Self {
            self.style().inset.top = len_rel(-0.2);
            return self;
        }
        /// Sets the top offset of the element to 40%.
        pub fn top_2_5(self: Self) Self {
            self.style().inset.top = len_rel(0.4);
            return self;
        }
        /// Sets the top offset of the element to negative 40%.
        pub fn top_neg_2_5(self: Self) Self {
            self.style().inset.top = len_rel(-0.4);
            return self;
        }
        /// Sets the top offset of the element to 60%.
        pub fn top_3_5(self: Self) Self {
            self.style().inset.top = len_rel(0.6);
            return self;
        }
        /// Sets the top offset of the element to negative 60%.
        pub fn top_neg_3_5(self: Self) Self {
            self.style().inset.top = len_rel(-0.6);
            return self;
        }
        /// Sets the top offset of the element to 80%.
        pub fn top_4_5(self: Self) Self {
            self.style().inset.top = len_rel(0.8);
            return self;
        }
        /// Sets the top offset of the element to negative 80%.
        pub fn top_neg_4_5(self: Self) Self {
            self.style().inset.top = len_rel(-0.8);
            return self;
        }
        /// Sets the top offset of the element to 16.6667%.
        pub fn top_1_6(self: Self) Self {
            self.style().inset.top = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the top offset of the element to negative 16.6667%.
        pub fn top_neg_1_6(self: Self) Self {
            self.style().inset.top = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the top offset of the element to 83.3333%.
        pub fn top_5_6(self: Self) Self {
            self.style().inset.top = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the top offset of the element to negative 83.3333%.
        pub fn top_neg_5_6(self: Self) Self {
            self.style().inset.top = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the top offset of the element to 8.33333%.
        pub fn top_1_12(self: Self) Self {
            self.style().inset.top = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the top offset of the element to negative 8.33333%.
        pub fn top_neg_1_12(self: Self) Self {
            self.style().inset.top = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the bottom offset of the element.
        pub fn bottom(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.inset.bottom = v;
            return self;
        }
        /// Sets the bottom offset of the element to 0px.
        pub fn bottom_0(self: Self) Self {
            self.style().inset.bottom = len_px(0.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 0px.
        pub fn bottom_neg_0(self: Self) Self {
            self.style().inset.bottom = len_px(-0.0);
            return self;
        }
        /// Sets the bottom offset of the element to 2px (0.125rem).
        pub fn bottom_0p5(self: Self) Self {
            self.style().inset.bottom = len_rem(0.125);
            return self;
        }
        /// Sets the bottom offset of the element to negative 2px (0.125rem).
        pub fn bottom_neg_0p5(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.125);
            return self;
        }
        /// Sets the bottom offset of the element to 4px (0.25rem).
        pub fn bottom_1(self: Self) Self {
            self.style().inset.bottom = len_rem(0.25);
            return self;
        }
        /// Sets the bottom offset of the element to negative 4px (0.25rem).
        pub fn bottom_neg_1(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.25);
            return self;
        }
        /// Sets the bottom offset of the element to 6px (0.375rem).
        pub fn bottom_1p5(self: Self) Self {
            self.style().inset.bottom = len_rem(0.375);
            return self;
        }
        /// Sets the bottom offset of the element to negative 6px (0.375rem).
        pub fn bottom_neg_1p5(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.375);
            return self;
        }
        /// Sets the bottom offset of the element to 8px (0.5rem).
        pub fn bottom_2(self: Self) Self {
            self.style().inset.bottom = len_rem(0.5);
            return self;
        }
        /// Sets the bottom offset of the element to negative 8px (0.5rem).
        pub fn bottom_neg_2(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.5);
            return self;
        }
        /// Sets the bottom offset of the element to 10px (0.625rem).
        pub fn bottom_2p5(self: Self) Self {
            self.style().inset.bottom = len_rem(0.625);
            return self;
        }
        /// Sets the bottom offset of the element to negative 10px (0.625rem).
        pub fn bottom_neg_2p5(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.625);
            return self;
        }
        /// Sets the bottom offset of the element to 12px (0.75rem).
        pub fn bottom_3(self: Self) Self {
            self.style().inset.bottom = len_rem(0.75);
            return self;
        }
        /// Sets the bottom offset of the element to negative 12px (0.75rem).
        pub fn bottom_neg_3(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.75);
            return self;
        }
        /// Sets the bottom offset of the element to 14px (0.875rem).
        pub fn bottom_3p5(self: Self) Self {
            self.style().inset.bottom = len_rem(0.875);
            return self;
        }
        /// Sets the bottom offset of the element to negative 14px (0.875rem).
        pub fn bottom_neg_3p5(self: Self) Self {
            self.style().inset.bottom = len_rem(-0.875);
            return self;
        }
        /// Sets the bottom offset of the element to 16px (1rem).
        pub fn bottom_4(self: Self) Self {
            self.style().inset.bottom = len_rem(1.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 16px (1rem).
        pub fn bottom_neg_4(self: Self) Self {
            self.style().inset.bottom = len_rem(-1.0);
            return self;
        }
        /// Sets the bottom offset of the element to 20px (1.25rem).
        pub fn bottom_5(self: Self) Self {
            self.style().inset.bottom = len_rem(1.25);
            return self;
        }
        /// Sets the bottom offset of the element to negative 20px (1.25rem).
        pub fn bottom_neg_5(self: Self) Self {
            self.style().inset.bottom = len_rem(-1.25);
            return self;
        }
        /// Sets the bottom offset of the element to 24px (1.5rem).
        pub fn bottom_6(self: Self) Self {
            self.style().inset.bottom = len_rem(1.5);
            return self;
        }
        /// Sets the bottom offset of the element to negative 24px (1.5rem).
        pub fn bottom_neg_6(self: Self) Self {
            self.style().inset.bottom = len_rem(-1.5);
            return self;
        }
        /// Sets the bottom offset of the element to 28px (1.75rem).
        pub fn bottom_7(self: Self) Self {
            self.style().inset.bottom = len_rem(1.75);
            return self;
        }
        /// Sets the bottom offset of the element to negative 28px (1.75rem).
        pub fn bottom_neg_7(self: Self) Self {
            self.style().inset.bottom = len_rem(-1.75);
            return self;
        }
        /// Sets the bottom offset of the element to 32px (2rem).
        pub fn bottom_8(self: Self) Self {
            self.style().inset.bottom = len_rem(2.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 32px (2rem).
        pub fn bottom_neg_8(self: Self) Self {
            self.style().inset.bottom = len_rem(-2.0);
            return self;
        }
        /// Sets the bottom offset of the element to 36px (2.25rem).
        pub fn bottom_9(self: Self) Self {
            self.style().inset.bottom = len_rem(2.25);
            return self;
        }
        /// Sets the bottom offset of the element to negative 36px (2.25rem).
        pub fn bottom_neg_9(self: Self) Self {
            self.style().inset.bottom = len_rem(-2.25);
            return self;
        }
        /// Sets the bottom offset of the element to 40px (2.5rem).
        pub fn bottom_10(self: Self) Self {
            self.style().inset.bottom = len_rem(2.5);
            return self;
        }
        /// Sets the bottom offset of the element to negative 40px (2.5rem).
        pub fn bottom_neg_10(self: Self) Self {
            self.style().inset.bottom = len_rem(-2.5);
            return self;
        }
        /// Sets the bottom offset of the element to 44px (2.75rem).
        pub fn bottom_11(self: Self) Self {
            self.style().inset.bottom = len_rem(2.75);
            return self;
        }
        /// Sets the bottom offset of the element to negative 44px (2.75rem).
        pub fn bottom_neg_11(self: Self) Self {
            self.style().inset.bottom = len_rem(-2.75);
            return self;
        }
        /// Sets the bottom offset of the element to 48px (3rem).
        pub fn bottom_12(self: Self) Self {
            self.style().inset.bottom = len_rem(3.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 48px (3rem).
        pub fn bottom_neg_12(self: Self) Self {
            self.style().inset.bottom = len_rem(-3.0);
            return self;
        }
        /// Sets the bottom offset of the element to 64px (4rem).
        pub fn bottom_16(self: Self) Self {
            self.style().inset.bottom = len_rem(4.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 64px (4rem).
        pub fn bottom_neg_16(self: Self) Self {
            self.style().inset.bottom = len_rem(-4.0);
            return self;
        }
        /// Sets the bottom offset of the element to 80px (5rem).
        pub fn bottom_20(self: Self) Self {
            self.style().inset.bottom = len_rem(5.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 80px (5rem).
        pub fn bottom_neg_20(self: Self) Self {
            self.style().inset.bottom = len_rem(-5.0);
            return self;
        }
        /// Sets the bottom offset of the element to 96px (6rem).
        pub fn bottom_24(self: Self) Self {
            self.style().inset.bottom = len_rem(6.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 96px (6rem).
        pub fn bottom_neg_24(self: Self) Self {
            self.style().inset.bottom = len_rem(-6.0);
            return self;
        }
        /// Sets the bottom offset of the element to 128px (8rem).
        pub fn bottom_32(self: Self) Self {
            self.style().inset.bottom = len_rem(8.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 128px (8rem).
        pub fn bottom_neg_32(self: Self) Self {
            self.style().inset.bottom = len_rem(-8.0);
            return self;
        }
        /// Sets the bottom offset of the element to 160px (10rem).
        pub fn bottom_40(self: Self) Self {
            self.style().inset.bottom = len_rem(10.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 160px (10rem).
        pub fn bottom_neg_40(self: Self) Self {
            self.style().inset.bottom = len_rem(-10.0);
            return self;
        }
        /// Sets the bottom offset of the element to 192px (12rem).
        pub fn bottom_48(self: Self) Self {
            self.style().inset.bottom = len_rem(12.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 192px (12rem).
        pub fn bottom_neg_48(self: Self) Self {
            self.style().inset.bottom = len_rem(-12.0);
            return self;
        }
        /// Sets the bottom offset of the element to 224px (14rem).
        pub fn bottom_56(self: Self) Self {
            self.style().inset.bottom = len_rem(14.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 224px (14rem).
        pub fn bottom_neg_56(self: Self) Self {
            self.style().inset.bottom = len_rem(-14.0);
            return self;
        }
        /// Sets the bottom offset of the element to 256px (16rem).
        pub fn bottom_64(self: Self) Self {
            self.style().inset.bottom = len_rem(16.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 256px (16rem).
        pub fn bottom_neg_64(self: Self) Self {
            self.style().inset.bottom = len_rem(-16.0);
            return self;
        }
        /// Sets the bottom offset of the element to 288px (18rem).
        pub fn bottom_72(self: Self) Self {
            self.style().inset.bottom = len_rem(18.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 288px (18rem).
        pub fn bottom_neg_72(self: Self) Self {
            self.style().inset.bottom = len_rem(-18.0);
            return self;
        }
        /// Sets the bottom offset of the element to 320px (20rem).
        pub fn bottom_80(self: Self) Self {
            self.style().inset.bottom = len_rem(20.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 320px (20rem).
        pub fn bottom_neg_80(self: Self) Self {
            self.style().inset.bottom = len_rem(-20.0);
            return self;
        }
        /// Sets the bottom offset of the element to 384px (24rem).
        pub fn bottom_96(self: Self) Self {
            self.style().inset.bottom = len_rem(24.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 384px (24rem).
        pub fn bottom_neg_96(self: Self) Self {
            self.style().inset.bottom = len_rem(-24.0);
            return self;
        }
        /// Sets the bottom offset of the element to 448px (28rem).
        pub fn bottom_112(self: Self) Self {
            self.style().inset.bottom = len_rem(28.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 448px (28rem).
        pub fn bottom_neg_112(self: Self) Self {
            self.style().inset.bottom = len_rem(-28.0);
            return self;
        }
        /// Sets the bottom offset of the element to 512px (32rem).
        pub fn bottom_128(self: Self) Self {
            self.style().inset.bottom = len_rem(32.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 512px (32rem).
        pub fn bottom_neg_128(self: Self) Self {
            self.style().inset.bottom = len_rem(-32.0);
            return self;
        }
        /// Sets the bottom offset of the element to auto.
        pub fn bottom_auto(self: Self) Self {
            self.style().inset.bottom = geometry.auto();
            return self;
        }
        /// Sets the bottom offset of the element to 1px.
        pub fn bottom_px(self: Self) Self {
            self.style().inset.bottom = len_px(1.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 1px.
        pub fn bottom_neg_px(self: Self) Self {
            self.style().inset.bottom = len_px(-1.0);
            return self;
        }
        /// Sets the bottom offset of the element to 100%.
        pub fn bottom_full(self: Self) Self {
            self.style().inset.bottom = len_rel(1.0);
            return self;
        }
        /// Sets the bottom offset of the element to negative 100%.
        pub fn bottom_neg_full(self: Self) Self {
            self.style().inset.bottom = len_rel(-1.0);
            return self;
        }
        /// Sets the bottom offset of the element to 50%.
        pub fn bottom_1_2(self: Self) Self {
            self.style().inset.bottom = len_rel(0.5);
            return self;
        }
        /// Sets the bottom offset of the element to negative 50%.
        pub fn bottom_neg_1_2(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.5);
            return self;
        }
        /// Sets the bottom offset of the element to 33.3333%.
        pub fn bottom_1_3(self: Self) Self {
            self.style().inset.bottom = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the bottom offset of the element to negative 33.3333%.
        pub fn bottom_neg_1_3(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the bottom offset of the element to 66.6667%.
        pub fn bottom_2_3(self: Self) Self {
            self.style().inset.bottom = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the bottom offset of the element to negative 66.6667%.
        pub fn bottom_neg_2_3(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the bottom offset of the element to 25%.
        pub fn bottom_1_4(self: Self) Self {
            self.style().inset.bottom = len_rel(0.25);
            return self;
        }
        /// Sets the bottom offset of the element to negative 25%.
        pub fn bottom_neg_1_4(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.25);
            return self;
        }
        /// Sets the bottom offset of the element to 50%.
        pub fn bottom_2_4(self: Self) Self {
            self.style().inset.bottom = len_rel(0.5);
            return self;
        }
        /// Sets the bottom offset of the element to negative 50%.
        pub fn bottom_neg_2_4(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.5);
            return self;
        }
        /// Sets the bottom offset of the element to 75%.
        pub fn bottom_3_4(self: Self) Self {
            self.style().inset.bottom = len_rel(0.75);
            return self;
        }
        /// Sets the bottom offset of the element to negative 75%.
        pub fn bottom_neg_3_4(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.75);
            return self;
        }
        /// Sets the bottom offset of the element to 20%.
        pub fn bottom_1_5(self: Self) Self {
            self.style().inset.bottom = len_rel(0.2);
            return self;
        }
        /// Sets the bottom offset of the element to negative 20%.
        pub fn bottom_neg_1_5(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.2);
            return self;
        }
        /// Sets the bottom offset of the element to 40%.
        pub fn bottom_2_5(self: Self) Self {
            self.style().inset.bottom = len_rel(0.4);
            return self;
        }
        /// Sets the bottom offset of the element to negative 40%.
        pub fn bottom_neg_2_5(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.4);
            return self;
        }
        /// Sets the bottom offset of the element to 60%.
        pub fn bottom_3_5(self: Self) Self {
            self.style().inset.bottom = len_rel(0.6);
            return self;
        }
        /// Sets the bottom offset of the element to negative 60%.
        pub fn bottom_neg_3_5(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.6);
            return self;
        }
        /// Sets the bottom offset of the element to 80%.
        pub fn bottom_4_5(self: Self) Self {
            self.style().inset.bottom = len_rel(0.8);
            return self;
        }
        /// Sets the bottom offset of the element to negative 80%.
        pub fn bottom_neg_4_5(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.8);
            return self;
        }
        /// Sets the bottom offset of the element to 16.6667%.
        pub fn bottom_1_6(self: Self) Self {
            self.style().inset.bottom = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the bottom offset of the element to negative 16.6667%.
        pub fn bottom_neg_1_6(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the bottom offset of the element to 83.3333%.
        pub fn bottom_5_6(self: Self) Self {
            self.style().inset.bottom = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the bottom offset of the element to negative 83.3333%.
        pub fn bottom_neg_5_6(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the bottom offset of the element to 8.33333%.
        pub fn bottom_1_12(self: Self) Self {
            self.style().inset.bottom = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the bottom offset of the element to negative 8.33333%.
        pub fn bottom_neg_1_12(self: Self) Self {
            self.style().inset.bottom = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the left offset of the element.
        pub fn left(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.inset.left = v;
            return self;
        }
        /// Sets the left offset of the element to 0px.
        pub fn left_0(self: Self) Self {
            self.style().inset.left = len_px(0.0);
            return self;
        }
        /// Sets the left offset of the element to negative 0px.
        pub fn left_neg_0(self: Self) Self {
            self.style().inset.left = len_px(-0.0);
            return self;
        }
        /// Sets the left offset of the element to 2px (0.125rem).
        pub fn left_0p5(self: Self) Self {
            self.style().inset.left = len_rem(0.125);
            return self;
        }
        /// Sets the left offset of the element to negative 2px (0.125rem).
        pub fn left_neg_0p5(self: Self) Self {
            self.style().inset.left = len_rem(-0.125);
            return self;
        }
        /// Sets the left offset of the element to 4px (0.25rem).
        pub fn left_1(self: Self) Self {
            self.style().inset.left = len_rem(0.25);
            return self;
        }
        /// Sets the left offset of the element to negative 4px (0.25rem).
        pub fn left_neg_1(self: Self) Self {
            self.style().inset.left = len_rem(-0.25);
            return self;
        }
        /// Sets the left offset of the element to 6px (0.375rem).
        pub fn left_1p5(self: Self) Self {
            self.style().inset.left = len_rem(0.375);
            return self;
        }
        /// Sets the left offset of the element to negative 6px (0.375rem).
        pub fn left_neg_1p5(self: Self) Self {
            self.style().inset.left = len_rem(-0.375);
            return self;
        }
        /// Sets the left offset of the element to 8px (0.5rem).
        pub fn left_2(self: Self) Self {
            self.style().inset.left = len_rem(0.5);
            return self;
        }
        /// Sets the left offset of the element to negative 8px (0.5rem).
        pub fn left_neg_2(self: Self) Self {
            self.style().inset.left = len_rem(-0.5);
            return self;
        }
        /// Sets the left offset of the element to 10px (0.625rem).
        pub fn left_2p5(self: Self) Self {
            self.style().inset.left = len_rem(0.625);
            return self;
        }
        /// Sets the left offset of the element to negative 10px (0.625rem).
        pub fn left_neg_2p5(self: Self) Self {
            self.style().inset.left = len_rem(-0.625);
            return self;
        }
        /// Sets the left offset of the element to 12px (0.75rem).
        pub fn left_3(self: Self) Self {
            self.style().inset.left = len_rem(0.75);
            return self;
        }
        /// Sets the left offset of the element to negative 12px (0.75rem).
        pub fn left_neg_3(self: Self) Self {
            self.style().inset.left = len_rem(-0.75);
            return self;
        }
        /// Sets the left offset of the element to 14px (0.875rem).
        pub fn left_3p5(self: Self) Self {
            self.style().inset.left = len_rem(0.875);
            return self;
        }
        /// Sets the left offset of the element to negative 14px (0.875rem).
        pub fn left_neg_3p5(self: Self) Self {
            self.style().inset.left = len_rem(-0.875);
            return self;
        }
        /// Sets the left offset of the element to 16px (1rem).
        pub fn left_4(self: Self) Self {
            self.style().inset.left = len_rem(1.0);
            return self;
        }
        /// Sets the left offset of the element to negative 16px (1rem).
        pub fn left_neg_4(self: Self) Self {
            self.style().inset.left = len_rem(-1.0);
            return self;
        }
        /// Sets the left offset of the element to 20px (1.25rem).
        pub fn left_5(self: Self) Self {
            self.style().inset.left = len_rem(1.25);
            return self;
        }
        /// Sets the left offset of the element to negative 20px (1.25rem).
        pub fn left_neg_5(self: Self) Self {
            self.style().inset.left = len_rem(-1.25);
            return self;
        }
        /// Sets the left offset of the element to 24px (1.5rem).
        pub fn left_6(self: Self) Self {
            self.style().inset.left = len_rem(1.5);
            return self;
        }
        /// Sets the left offset of the element to negative 24px (1.5rem).
        pub fn left_neg_6(self: Self) Self {
            self.style().inset.left = len_rem(-1.5);
            return self;
        }
        /// Sets the left offset of the element to 28px (1.75rem).
        pub fn left_7(self: Self) Self {
            self.style().inset.left = len_rem(1.75);
            return self;
        }
        /// Sets the left offset of the element to negative 28px (1.75rem).
        pub fn left_neg_7(self: Self) Self {
            self.style().inset.left = len_rem(-1.75);
            return self;
        }
        /// Sets the left offset of the element to 32px (2rem).
        pub fn left_8(self: Self) Self {
            self.style().inset.left = len_rem(2.0);
            return self;
        }
        /// Sets the left offset of the element to negative 32px (2rem).
        pub fn left_neg_8(self: Self) Self {
            self.style().inset.left = len_rem(-2.0);
            return self;
        }
        /// Sets the left offset of the element to 36px (2.25rem).
        pub fn left_9(self: Self) Self {
            self.style().inset.left = len_rem(2.25);
            return self;
        }
        /// Sets the left offset of the element to negative 36px (2.25rem).
        pub fn left_neg_9(self: Self) Self {
            self.style().inset.left = len_rem(-2.25);
            return self;
        }
        /// Sets the left offset of the element to 40px (2.5rem).
        pub fn left_10(self: Self) Self {
            self.style().inset.left = len_rem(2.5);
            return self;
        }
        /// Sets the left offset of the element to negative 40px (2.5rem).
        pub fn left_neg_10(self: Self) Self {
            self.style().inset.left = len_rem(-2.5);
            return self;
        }
        /// Sets the left offset of the element to 44px (2.75rem).
        pub fn left_11(self: Self) Self {
            self.style().inset.left = len_rem(2.75);
            return self;
        }
        /// Sets the left offset of the element to negative 44px (2.75rem).
        pub fn left_neg_11(self: Self) Self {
            self.style().inset.left = len_rem(-2.75);
            return self;
        }
        /// Sets the left offset of the element to 48px (3rem).
        pub fn left_12(self: Self) Self {
            self.style().inset.left = len_rem(3.0);
            return self;
        }
        /// Sets the left offset of the element to negative 48px (3rem).
        pub fn left_neg_12(self: Self) Self {
            self.style().inset.left = len_rem(-3.0);
            return self;
        }
        /// Sets the left offset of the element to 64px (4rem).
        pub fn left_16(self: Self) Self {
            self.style().inset.left = len_rem(4.0);
            return self;
        }
        /// Sets the left offset of the element to negative 64px (4rem).
        pub fn left_neg_16(self: Self) Self {
            self.style().inset.left = len_rem(-4.0);
            return self;
        }
        /// Sets the left offset of the element to 80px (5rem).
        pub fn left_20(self: Self) Self {
            self.style().inset.left = len_rem(5.0);
            return self;
        }
        /// Sets the left offset of the element to negative 80px (5rem).
        pub fn left_neg_20(self: Self) Self {
            self.style().inset.left = len_rem(-5.0);
            return self;
        }
        /// Sets the left offset of the element to 96px (6rem).
        pub fn left_24(self: Self) Self {
            self.style().inset.left = len_rem(6.0);
            return self;
        }
        /// Sets the left offset of the element to negative 96px (6rem).
        pub fn left_neg_24(self: Self) Self {
            self.style().inset.left = len_rem(-6.0);
            return self;
        }
        /// Sets the left offset of the element to 128px (8rem).
        pub fn left_32(self: Self) Self {
            self.style().inset.left = len_rem(8.0);
            return self;
        }
        /// Sets the left offset of the element to negative 128px (8rem).
        pub fn left_neg_32(self: Self) Self {
            self.style().inset.left = len_rem(-8.0);
            return self;
        }
        /// Sets the left offset of the element to 160px (10rem).
        pub fn left_40(self: Self) Self {
            self.style().inset.left = len_rem(10.0);
            return self;
        }
        /// Sets the left offset of the element to negative 160px (10rem).
        pub fn left_neg_40(self: Self) Self {
            self.style().inset.left = len_rem(-10.0);
            return self;
        }
        /// Sets the left offset of the element to 192px (12rem).
        pub fn left_48(self: Self) Self {
            self.style().inset.left = len_rem(12.0);
            return self;
        }
        /// Sets the left offset of the element to negative 192px (12rem).
        pub fn left_neg_48(self: Self) Self {
            self.style().inset.left = len_rem(-12.0);
            return self;
        }
        /// Sets the left offset of the element to 224px (14rem).
        pub fn left_56(self: Self) Self {
            self.style().inset.left = len_rem(14.0);
            return self;
        }
        /// Sets the left offset of the element to negative 224px (14rem).
        pub fn left_neg_56(self: Self) Self {
            self.style().inset.left = len_rem(-14.0);
            return self;
        }
        /// Sets the left offset of the element to 256px (16rem).
        pub fn left_64(self: Self) Self {
            self.style().inset.left = len_rem(16.0);
            return self;
        }
        /// Sets the left offset of the element to negative 256px (16rem).
        pub fn left_neg_64(self: Self) Self {
            self.style().inset.left = len_rem(-16.0);
            return self;
        }
        /// Sets the left offset of the element to 288px (18rem).
        pub fn left_72(self: Self) Self {
            self.style().inset.left = len_rem(18.0);
            return self;
        }
        /// Sets the left offset of the element to negative 288px (18rem).
        pub fn left_neg_72(self: Self) Self {
            self.style().inset.left = len_rem(-18.0);
            return self;
        }
        /// Sets the left offset of the element to 320px (20rem).
        pub fn left_80(self: Self) Self {
            self.style().inset.left = len_rem(20.0);
            return self;
        }
        /// Sets the left offset of the element to negative 320px (20rem).
        pub fn left_neg_80(self: Self) Self {
            self.style().inset.left = len_rem(-20.0);
            return self;
        }
        /// Sets the left offset of the element to 384px (24rem).
        pub fn left_96(self: Self) Self {
            self.style().inset.left = len_rem(24.0);
            return self;
        }
        /// Sets the left offset of the element to negative 384px (24rem).
        pub fn left_neg_96(self: Self) Self {
            self.style().inset.left = len_rem(-24.0);
            return self;
        }
        /// Sets the left offset of the element to 448px (28rem).
        pub fn left_112(self: Self) Self {
            self.style().inset.left = len_rem(28.0);
            return self;
        }
        /// Sets the left offset of the element to negative 448px (28rem).
        pub fn left_neg_112(self: Self) Self {
            self.style().inset.left = len_rem(-28.0);
            return self;
        }
        /// Sets the left offset of the element to 512px (32rem).
        pub fn left_128(self: Self) Self {
            self.style().inset.left = len_rem(32.0);
            return self;
        }
        /// Sets the left offset of the element to negative 512px (32rem).
        pub fn left_neg_128(self: Self) Self {
            self.style().inset.left = len_rem(-32.0);
            return self;
        }
        /// Sets the left offset of the element to auto.
        pub fn left_auto(self: Self) Self {
            self.style().inset.left = geometry.auto();
            return self;
        }
        /// Sets the left offset of the element to 1px.
        pub fn left_px(self: Self) Self {
            self.style().inset.left = len_px(1.0);
            return self;
        }
        /// Sets the left offset of the element to negative 1px.
        pub fn left_neg_px(self: Self) Self {
            self.style().inset.left = len_px(-1.0);
            return self;
        }
        /// Sets the left offset of the element to 100%.
        pub fn left_full(self: Self) Self {
            self.style().inset.left = len_rel(1.0);
            return self;
        }
        /// Sets the left offset of the element to negative 100%.
        pub fn left_neg_full(self: Self) Self {
            self.style().inset.left = len_rel(-1.0);
            return self;
        }
        /// Sets the left offset of the element to 50%.
        pub fn left_1_2(self: Self) Self {
            self.style().inset.left = len_rel(0.5);
            return self;
        }
        /// Sets the left offset of the element to negative 50%.
        pub fn left_neg_1_2(self: Self) Self {
            self.style().inset.left = len_rel(-0.5);
            return self;
        }
        /// Sets the left offset of the element to 33.3333%.
        pub fn left_1_3(self: Self) Self {
            self.style().inset.left = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the left offset of the element to negative 33.3333%.
        pub fn left_neg_1_3(self: Self) Self {
            self.style().inset.left = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the left offset of the element to 66.6667%.
        pub fn left_2_3(self: Self) Self {
            self.style().inset.left = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the left offset of the element to negative 66.6667%.
        pub fn left_neg_2_3(self: Self) Self {
            self.style().inset.left = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the left offset of the element to 25%.
        pub fn left_1_4(self: Self) Self {
            self.style().inset.left = len_rel(0.25);
            return self;
        }
        /// Sets the left offset of the element to negative 25%.
        pub fn left_neg_1_4(self: Self) Self {
            self.style().inset.left = len_rel(-0.25);
            return self;
        }
        /// Sets the left offset of the element to 50%.
        pub fn left_2_4(self: Self) Self {
            self.style().inset.left = len_rel(0.5);
            return self;
        }
        /// Sets the left offset of the element to negative 50%.
        pub fn left_neg_2_4(self: Self) Self {
            self.style().inset.left = len_rel(-0.5);
            return self;
        }
        /// Sets the left offset of the element to 75%.
        pub fn left_3_4(self: Self) Self {
            self.style().inset.left = len_rel(0.75);
            return self;
        }
        /// Sets the left offset of the element to negative 75%.
        pub fn left_neg_3_4(self: Self) Self {
            self.style().inset.left = len_rel(-0.75);
            return self;
        }
        /// Sets the left offset of the element to 20%.
        pub fn left_1_5(self: Self) Self {
            self.style().inset.left = len_rel(0.2);
            return self;
        }
        /// Sets the left offset of the element to negative 20%.
        pub fn left_neg_1_5(self: Self) Self {
            self.style().inset.left = len_rel(-0.2);
            return self;
        }
        /// Sets the left offset of the element to 40%.
        pub fn left_2_5(self: Self) Self {
            self.style().inset.left = len_rel(0.4);
            return self;
        }
        /// Sets the left offset of the element to negative 40%.
        pub fn left_neg_2_5(self: Self) Self {
            self.style().inset.left = len_rel(-0.4);
            return self;
        }
        /// Sets the left offset of the element to 60%.
        pub fn left_3_5(self: Self) Self {
            self.style().inset.left = len_rel(0.6);
            return self;
        }
        /// Sets the left offset of the element to negative 60%.
        pub fn left_neg_3_5(self: Self) Self {
            self.style().inset.left = len_rel(-0.6);
            return self;
        }
        /// Sets the left offset of the element to 80%.
        pub fn left_4_5(self: Self) Self {
            self.style().inset.left = len_rel(0.8);
            return self;
        }
        /// Sets the left offset of the element to negative 80%.
        pub fn left_neg_4_5(self: Self) Self {
            self.style().inset.left = len_rel(-0.8);
            return self;
        }
        /// Sets the left offset of the element to 16.6667%.
        pub fn left_1_6(self: Self) Self {
            self.style().inset.left = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the left offset of the element to negative 16.6667%.
        pub fn left_neg_1_6(self: Self) Self {
            self.style().inset.left = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the left offset of the element to 83.3333%.
        pub fn left_5_6(self: Self) Self {
            self.style().inset.left = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the left offset of the element to negative 83.3333%.
        pub fn left_neg_5_6(self: Self) Self {
            self.style().inset.left = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the left offset of the element to 8.33333%.
        pub fn left_1_12(self: Self) Self {
            self.style().inset.left = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the left offset of the element to negative 8.33333%.
        pub fn left_neg_1_12(self: Self) Self {
            self.style().inset.left = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the right offset of the element.
        pub fn right(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.inset.right = v;
            return self;
        }
        /// Sets the right offset of the element to 0px.
        pub fn right_0(self: Self) Self {
            self.style().inset.right = len_px(0.0);
            return self;
        }
        /// Sets the right offset of the element to negative 0px.
        pub fn right_neg_0(self: Self) Self {
            self.style().inset.right = len_px(-0.0);
            return self;
        }
        /// Sets the right offset of the element to 2px (0.125rem).
        pub fn right_0p5(self: Self) Self {
            self.style().inset.right = len_rem(0.125);
            return self;
        }
        /// Sets the right offset of the element to negative 2px (0.125rem).
        pub fn right_neg_0p5(self: Self) Self {
            self.style().inset.right = len_rem(-0.125);
            return self;
        }
        /// Sets the right offset of the element to 4px (0.25rem).
        pub fn right_1(self: Self) Self {
            self.style().inset.right = len_rem(0.25);
            return self;
        }
        /// Sets the right offset of the element to negative 4px (0.25rem).
        pub fn right_neg_1(self: Self) Self {
            self.style().inset.right = len_rem(-0.25);
            return self;
        }
        /// Sets the right offset of the element to 6px (0.375rem).
        pub fn right_1p5(self: Self) Self {
            self.style().inset.right = len_rem(0.375);
            return self;
        }
        /// Sets the right offset of the element to negative 6px (0.375rem).
        pub fn right_neg_1p5(self: Self) Self {
            self.style().inset.right = len_rem(-0.375);
            return self;
        }
        /// Sets the right offset of the element to 8px (0.5rem).
        pub fn right_2(self: Self) Self {
            self.style().inset.right = len_rem(0.5);
            return self;
        }
        /// Sets the right offset of the element to negative 8px (0.5rem).
        pub fn right_neg_2(self: Self) Self {
            self.style().inset.right = len_rem(-0.5);
            return self;
        }
        /// Sets the right offset of the element to 10px (0.625rem).
        pub fn right_2p5(self: Self) Self {
            self.style().inset.right = len_rem(0.625);
            return self;
        }
        /// Sets the right offset of the element to negative 10px (0.625rem).
        pub fn right_neg_2p5(self: Self) Self {
            self.style().inset.right = len_rem(-0.625);
            return self;
        }
        /// Sets the right offset of the element to 12px (0.75rem).
        pub fn right_3(self: Self) Self {
            self.style().inset.right = len_rem(0.75);
            return self;
        }
        /// Sets the right offset of the element to negative 12px (0.75rem).
        pub fn right_neg_3(self: Self) Self {
            self.style().inset.right = len_rem(-0.75);
            return self;
        }
        /// Sets the right offset of the element to 14px (0.875rem).
        pub fn right_3p5(self: Self) Self {
            self.style().inset.right = len_rem(0.875);
            return self;
        }
        /// Sets the right offset of the element to negative 14px (0.875rem).
        pub fn right_neg_3p5(self: Self) Self {
            self.style().inset.right = len_rem(-0.875);
            return self;
        }
        /// Sets the right offset of the element to 16px (1rem).
        pub fn right_4(self: Self) Self {
            self.style().inset.right = len_rem(1.0);
            return self;
        }
        /// Sets the right offset of the element to negative 16px (1rem).
        pub fn right_neg_4(self: Self) Self {
            self.style().inset.right = len_rem(-1.0);
            return self;
        }
        /// Sets the right offset of the element to 20px (1.25rem).
        pub fn right_5(self: Self) Self {
            self.style().inset.right = len_rem(1.25);
            return self;
        }
        /// Sets the right offset of the element to negative 20px (1.25rem).
        pub fn right_neg_5(self: Self) Self {
            self.style().inset.right = len_rem(-1.25);
            return self;
        }
        /// Sets the right offset of the element to 24px (1.5rem).
        pub fn right_6(self: Self) Self {
            self.style().inset.right = len_rem(1.5);
            return self;
        }
        /// Sets the right offset of the element to negative 24px (1.5rem).
        pub fn right_neg_6(self: Self) Self {
            self.style().inset.right = len_rem(-1.5);
            return self;
        }
        /// Sets the right offset of the element to 28px (1.75rem).
        pub fn right_7(self: Self) Self {
            self.style().inset.right = len_rem(1.75);
            return self;
        }
        /// Sets the right offset of the element to negative 28px (1.75rem).
        pub fn right_neg_7(self: Self) Self {
            self.style().inset.right = len_rem(-1.75);
            return self;
        }
        /// Sets the right offset of the element to 32px (2rem).
        pub fn right_8(self: Self) Self {
            self.style().inset.right = len_rem(2.0);
            return self;
        }
        /// Sets the right offset of the element to negative 32px (2rem).
        pub fn right_neg_8(self: Self) Self {
            self.style().inset.right = len_rem(-2.0);
            return self;
        }
        /// Sets the right offset of the element to 36px (2.25rem).
        pub fn right_9(self: Self) Self {
            self.style().inset.right = len_rem(2.25);
            return self;
        }
        /// Sets the right offset of the element to negative 36px (2.25rem).
        pub fn right_neg_9(self: Self) Self {
            self.style().inset.right = len_rem(-2.25);
            return self;
        }
        /// Sets the right offset of the element to 40px (2.5rem).
        pub fn right_10(self: Self) Self {
            self.style().inset.right = len_rem(2.5);
            return self;
        }
        /// Sets the right offset of the element to negative 40px (2.5rem).
        pub fn right_neg_10(self: Self) Self {
            self.style().inset.right = len_rem(-2.5);
            return self;
        }
        /// Sets the right offset of the element to 44px (2.75rem).
        pub fn right_11(self: Self) Self {
            self.style().inset.right = len_rem(2.75);
            return self;
        }
        /// Sets the right offset of the element to negative 44px (2.75rem).
        pub fn right_neg_11(self: Self) Self {
            self.style().inset.right = len_rem(-2.75);
            return self;
        }
        /// Sets the right offset of the element to 48px (3rem).
        pub fn right_12(self: Self) Self {
            self.style().inset.right = len_rem(3.0);
            return self;
        }
        /// Sets the right offset of the element to negative 48px (3rem).
        pub fn right_neg_12(self: Self) Self {
            self.style().inset.right = len_rem(-3.0);
            return self;
        }
        /// Sets the right offset of the element to 64px (4rem).
        pub fn right_16(self: Self) Self {
            self.style().inset.right = len_rem(4.0);
            return self;
        }
        /// Sets the right offset of the element to negative 64px (4rem).
        pub fn right_neg_16(self: Self) Self {
            self.style().inset.right = len_rem(-4.0);
            return self;
        }
        /// Sets the right offset of the element to 80px (5rem).
        pub fn right_20(self: Self) Self {
            self.style().inset.right = len_rem(5.0);
            return self;
        }
        /// Sets the right offset of the element to negative 80px (5rem).
        pub fn right_neg_20(self: Self) Self {
            self.style().inset.right = len_rem(-5.0);
            return self;
        }
        /// Sets the right offset of the element to 96px (6rem).
        pub fn right_24(self: Self) Self {
            self.style().inset.right = len_rem(6.0);
            return self;
        }
        /// Sets the right offset of the element to negative 96px (6rem).
        pub fn right_neg_24(self: Self) Self {
            self.style().inset.right = len_rem(-6.0);
            return self;
        }
        /// Sets the right offset of the element to 128px (8rem).
        pub fn right_32(self: Self) Self {
            self.style().inset.right = len_rem(8.0);
            return self;
        }
        /// Sets the right offset of the element to negative 128px (8rem).
        pub fn right_neg_32(self: Self) Self {
            self.style().inset.right = len_rem(-8.0);
            return self;
        }
        /// Sets the right offset of the element to 160px (10rem).
        pub fn right_40(self: Self) Self {
            self.style().inset.right = len_rem(10.0);
            return self;
        }
        /// Sets the right offset of the element to negative 160px (10rem).
        pub fn right_neg_40(self: Self) Self {
            self.style().inset.right = len_rem(-10.0);
            return self;
        }
        /// Sets the right offset of the element to 192px (12rem).
        pub fn right_48(self: Self) Self {
            self.style().inset.right = len_rem(12.0);
            return self;
        }
        /// Sets the right offset of the element to negative 192px (12rem).
        pub fn right_neg_48(self: Self) Self {
            self.style().inset.right = len_rem(-12.0);
            return self;
        }
        /// Sets the right offset of the element to 224px (14rem).
        pub fn right_56(self: Self) Self {
            self.style().inset.right = len_rem(14.0);
            return self;
        }
        /// Sets the right offset of the element to negative 224px (14rem).
        pub fn right_neg_56(self: Self) Self {
            self.style().inset.right = len_rem(-14.0);
            return self;
        }
        /// Sets the right offset of the element to 256px (16rem).
        pub fn right_64(self: Self) Self {
            self.style().inset.right = len_rem(16.0);
            return self;
        }
        /// Sets the right offset of the element to negative 256px (16rem).
        pub fn right_neg_64(self: Self) Self {
            self.style().inset.right = len_rem(-16.0);
            return self;
        }
        /// Sets the right offset of the element to 288px (18rem).
        pub fn right_72(self: Self) Self {
            self.style().inset.right = len_rem(18.0);
            return self;
        }
        /// Sets the right offset of the element to negative 288px (18rem).
        pub fn right_neg_72(self: Self) Self {
            self.style().inset.right = len_rem(-18.0);
            return self;
        }
        /// Sets the right offset of the element to 320px (20rem).
        pub fn right_80(self: Self) Self {
            self.style().inset.right = len_rem(20.0);
            return self;
        }
        /// Sets the right offset of the element to negative 320px (20rem).
        pub fn right_neg_80(self: Self) Self {
            self.style().inset.right = len_rem(-20.0);
            return self;
        }
        /// Sets the right offset of the element to 384px (24rem).
        pub fn right_96(self: Self) Self {
            self.style().inset.right = len_rem(24.0);
            return self;
        }
        /// Sets the right offset of the element to negative 384px (24rem).
        pub fn right_neg_96(self: Self) Self {
            self.style().inset.right = len_rem(-24.0);
            return self;
        }
        /// Sets the right offset of the element to 448px (28rem).
        pub fn right_112(self: Self) Self {
            self.style().inset.right = len_rem(28.0);
            return self;
        }
        /// Sets the right offset of the element to negative 448px (28rem).
        pub fn right_neg_112(self: Self) Self {
            self.style().inset.right = len_rem(-28.0);
            return self;
        }
        /// Sets the right offset of the element to 512px (32rem).
        pub fn right_128(self: Self) Self {
            self.style().inset.right = len_rem(32.0);
            return self;
        }
        /// Sets the right offset of the element to negative 512px (32rem).
        pub fn right_neg_128(self: Self) Self {
            self.style().inset.right = len_rem(-32.0);
            return self;
        }
        /// Sets the right offset of the element to auto.
        pub fn right_auto(self: Self) Self {
            self.style().inset.right = geometry.auto();
            return self;
        }
        /// Sets the right offset of the element to 1px.
        pub fn right_px(self: Self) Self {
            self.style().inset.right = len_px(1.0);
            return self;
        }
        /// Sets the right offset of the element to negative 1px.
        pub fn right_neg_px(self: Self) Self {
            self.style().inset.right = len_px(-1.0);
            return self;
        }
        /// Sets the right offset of the element to 100%.
        pub fn right_full(self: Self) Self {
            self.style().inset.right = len_rel(1.0);
            return self;
        }
        /// Sets the right offset of the element to negative 100%.
        pub fn right_neg_full(self: Self) Self {
            self.style().inset.right = len_rel(-1.0);
            return self;
        }
        /// Sets the right offset of the element to 50%.
        pub fn right_1_2(self: Self) Self {
            self.style().inset.right = len_rel(0.5);
            return self;
        }
        /// Sets the right offset of the element to negative 50%.
        pub fn right_neg_1_2(self: Self) Self {
            self.style().inset.right = len_rel(-0.5);
            return self;
        }
        /// Sets the right offset of the element to 33.3333%.
        pub fn right_1_3(self: Self) Self {
            self.style().inset.right = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the right offset of the element to negative 33.3333%.
        pub fn right_neg_1_3(self: Self) Self {
            self.style().inset.right = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the right offset of the element to 66.6667%.
        pub fn right_2_3(self: Self) Self {
            self.style().inset.right = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the right offset of the element to negative 66.6667%.
        pub fn right_neg_2_3(self: Self) Self {
            self.style().inset.right = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the right offset of the element to 25%.
        pub fn right_1_4(self: Self) Self {
            self.style().inset.right = len_rel(0.25);
            return self;
        }
        /// Sets the right offset of the element to negative 25%.
        pub fn right_neg_1_4(self: Self) Self {
            self.style().inset.right = len_rel(-0.25);
            return self;
        }
        /// Sets the right offset of the element to 50%.
        pub fn right_2_4(self: Self) Self {
            self.style().inset.right = len_rel(0.5);
            return self;
        }
        /// Sets the right offset of the element to negative 50%.
        pub fn right_neg_2_4(self: Self) Self {
            self.style().inset.right = len_rel(-0.5);
            return self;
        }
        /// Sets the right offset of the element to 75%.
        pub fn right_3_4(self: Self) Self {
            self.style().inset.right = len_rel(0.75);
            return self;
        }
        /// Sets the right offset of the element to negative 75%.
        pub fn right_neg_3_4(self: Self) Self {
            self.style().inset.right = len_rel(-0.75);
            return self;
        }
        /// Sets the right offset of the element to 20%.
        pub fn right_1_5(self: Self) Self {
            self.style().inset.right = len_rel(0.2);
            return self;
        }
        /// Sets the right offset of the element to negative 20%.
        pub fn right_neg_1_5(self: Self) Self {
            self.style().inset.right = len_rel(-0.2);
            return self;
        }
        /// Sets the right offset of the element to 40%.
        pub fn right_2_5(self: Self) Self {
            self.style().inset.right = len_rel(0.4);
            return self;
        }
        /// Sets the right offset of the element to negative 40%.
        pub fn right_neg_2_5(self: Self) Self {
            self.style().inset.right = len_rel(-0.4);
            return self;
        }
        /// Sets the right offset of the element to 60%.
        pub fn right_3_5(self: Self) Self {
            self.style().inset.right = len_rel(0.6);
            return self;
        }
        /// Sets the right offset of the element to negative 60%.
        pub fn right_neg_3_5(self: Self) Self {
            self.style().inset.right = len_rel(-0.6);
            return self;
        }
        /// Sets the right offset of the element to 80%.
        pub fn right_4_5(self: Self) Self {
            self.style().inset.right = len_rel(0.8);
            return self;
        }
        /// Sets the right offset of the element to negative 80%.
        pub fn right_neg_4_5(self: Self) Self {
            self.style().inset.right = len_rel(-0.8);
            return self;
        }
        /// Sets the right offset of the element to 16.6667%.
        pub fn right_1_6(self: Self) Self {
            self.style().inset.right = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the right offset of the element to negative 16.6667%.
        pub fn right_neg_1_6(self: Self) Self {
            self.style().inset.right = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the right offset of the element to 83.3333%.
        pub fn right_5_6(self: Self) Self {
            self.style().inset.right = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the right offset of the element to negative 83.3333%.
        pub fn right_neg_5_6(self: Self) Self {
            self.style().inset.right = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the right offset of the element to 8.33333%.
        pub fn right_1_12(self: Self) Self {
            self.style().inset.right = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the right offset of the element to negative 8.33333%.
        pub fn right_neg_1_12(self: Self) Self {
            self.style().inset.right = len_rel(-0.08333333333333333);
            return self;
        }
        /// Sets the width of the element.
        pub fn w(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.size.width = v;
            return self;
        }
        /// Sets the width of the element to 0px.
        pub fn w_0(self: Self) Self {
            self.style().size.width = len_px(0.0);
            return self;
        }
        /// Sets the width of the element to negative 0px.
        pub fn w_neg_0(self: Self) Self {
            self.style().size.width = len_px(-0.0);
            return self;
        }
        /// Sets the width of the element to 2px (0.125rem).
        pub fn w_0p5(self: Self) Self {
            self.style().size.width = len_rem(0.125);
            return self;
        }
        /// Sets the width of the element to negative 2px (0.125rem).
        pub fn w_neg_0p5(self: Self) Self {
            self.style().size.width = len_rem(-0.125);
            return self;
        }
        /// Sets the width of the element to 4px (0.25rem).
        pub fn w_1(self: Self) Self {
            self.style().size.width = len_rem(0.25);
            return self;
        }
        /// Sets the width of the element to negative 4px (0.25rem).
        pub fn w_neg_1(self: Self) Self {
            self.style().size.width = len_rem(-0.25);
            return self;
        }
        /// Sets the width of the element to 6px (0.375rem).
        pub fn w_1p5(self: Self) Self {
            self.style().size.width = len_rem(0.375);
            return self;
        }
        /// Sets the width of the element to negative 6px (0.375rem).
        pub fn w_neg_1p5(self: Self) Self {
            self.style().size.width = len_rem(-0.375);
            return self;
        }
        /// Sets the width of the element to 8px (0.5rem).
        pub fn w_2(self: Self) Self {
            self.style().size.width = len_rem(0.5);
            return self;
        }
        /// Sets the width of the element to negative 8px (0.5rem).
        pub fn w_neg_2(self: Self) Self {
            self.style().size.width = len_rem(-0.5);
            return self;
        }
        /// Sets the width of the element to 10px (0.625rem).
        pub fn w_2p5(self: Self) Self {
            self.style().size.width = len_rem(0.625);
            return self;
        }
        /// Sets the width of the element to negative 10px (0.625rem).
        pub fn w_neg_2p5(self: Self) Self {
            self.style().size.width = len_rem(-0.625);
            return self;
        }
        /// Sets the width of the element to 12px (0.75rem).
        pub fn w_3(self: Self) Self {
            self.style().size.width = len_rem(0.75);
            return self;
        }
        /// Sets the width of the element to negative 12px (0.75rem).
        pub fn w_neg_3(self: Self) Self {
            self.style().size.width = len_rem(-0.75);
            return self;
        }
        /// Sets the width of the element to 14px (0.875rem).
        pub fn w_3p5(self: Self) Self {
            self.style().size.width = len_rem(0.875);
            return self;
        }
        /// Sets the width of the element to negative 14px (0.875rem).
        pub fn w_neg_3p5(self: Self) Self {
            self.style().size.width = len_rem(-0.875);
            return self;
        }
        /// Sets the width of the element to 16px (1rem).
        pub fn w_4(self: Self) Self {
            self.style().size.width = len_rem(1.0);
            return self;
        }
        /// Sets the width of the element to negative 16px (1rem).
        pub fn w_neg_4(self: Self) Self {
            self.style().size.width = len_rem(-1.0);
            return self;
        }
        /// Sets the width of the element to 20px (1.25rem).
        pub fn w_5(self: Self) Self {
            self.style().size.width = len_rem(1.25);
            return self;
        }
        /// Sets the width of the element to negative 20px (1.25rem).
        pub fn w_neg_5(self: Self) Self {
            self.style().size.width = len_rem(-1.25);
            return self;
        }
        /// Sets the width of the element to 24px (1.5rem).
        pub fn w_6(self: Self) Self {
            self.style().size.width = len_rem(1.5);
            return self;
        }
        /// Sets the width of the element to negative 24px (1.5rem).
        pub fn w_neg_6(self: Self) Self {
            self.style().size.width = len_rem(-1.5);
            return self;
        }
        /// Sets the width of the element to 28px (1.75rem).
        pub fn w_7(self: Self) Self {
            self.style().size.width = len_rem(1.75);
            return self;
        }
        /// Sets the width of the element to negative 28px (1.75rem).
        pub fn w_neg_7(self: Self) Self {
            self.style().size.width = len_rem(-1.75);
            return self;
        }
        /// Sets the width of the element to 32px (2rem).
        pub fn w_8(self: Self) Self {
            self.style().size.width = len_rem(2.0);
            return self;
        }
        /// Sets the width of the element to negative 32px (2rem).
        pub fn w_neg_8(self: Self) Self {
            self.style().size.width = len_rem(-2.0);
            return self;
        }
        /// Sets the width of the element to 36px (2.25rem).
        pub fn w_9(self: Self) Self {
            self.style().size.width = len_rem(2.25);
            return self;
        }
        /// Sets the width of the element to negative 36px (2.25rem).
        pub fn w_neg_9(self: Self) Self {
            self.style().size.width = len_rem(-2.25);
            return self;
        }
        /// Sets the width of the element to 40px (2.5rem).
        pub fn w_10(self: Self) Self {
            self.style().size.width = len_rem(2.5);
            return self;
        }
        /// Sets the width of the element to negative 40px (2.5rem).
        pub fn w_neg_10(self: Self) Self {
            self.style().size.width = len_rem(-2.5);
            return self;
        }
        /// Sets the width of the element to 44px (2.75rem).
        pub fn w_11(self: Self) Self {
            self.style().size.width = len_rem(2.75);
            return self;
        }
        /// Sets the width of the element to negative 44px (2.75rem).
        pub fn w_neg_11(self: Self) Self {
            self.style().size.width = len_rem(-2.75);
            return self;
        }
        /// Sets the width of the element to 48px (3rem).
        pub fn w_12(self: Self) Self {
            self.style().size.width = len_rem(3.0);
            return self;
        }
        /// Sets the width of the element to negative 48px (3rem).
        pub fn w_neg_12(self: Self) Self {
            self.style().size.width = len_rem(-3.0);
            return self;
        }
        /// Sets the width of the element to 64px (4rem).
        pub fn w_16(self: Self) Self {
            self.style().size.width = len_rem(4.0);
            return self;
        }
        /// Sets the width of the element to negative 64px (4rem).
        pub fn w_neg_16(self: Self) Self {
            self.style().size.width = len_rem(-4.0);
            return self;
        }
        /// Sets the width of the element to 80px (5rem).
        pub fn w_20(self: Self) Self {
            self.style().size.width = len_rem(5.0);
            return self;
        }
        /// Sets the width of the element to negative 80px (5rem).
        pub fn w_neg_20(self: Self) Self {
            self.style().size.width = len_rem(-5.0);
            return self;
        }
        /// Sets the width of the element to 96px (6rem).
        pub fn w_24(self: Self) Self {
            self.style().size.width = len_rem(6.0);
            return self;
        }
        /// Sets the width of the element to negative 96px (6rem).
        pub fn w_neg_24(self: Self) Self {
            self.style().size.width = len_rem(-6.0);
            return self;
        }
        /// Sets the width of the element to 128px (8rem).
        pub fn w_32(self: Self) Self {
            self.style().size.width = len_rem(8.0);
            return self;
        }
        /// Sets the width of the element to negative 128px (8rem).
        pub fn w_neg_32(self: Self) Self {
            self.style().size.width = len_rem(-8.0);
            return self;
        }
        /// Sets the width of the element to 160px (10rem).
        pub fn w_40(self: Self) Self {
            self.style().size.width = len_rem(10.0);
            return self;
        }
        /// Sets the width of the element to negative 160px (10rem).
        pub fn w_neg_40(self: Self) Self {
            self.style().size.width = len_rem(-10.0);
            return self;
        }
        /// Sets the width of the element to 192px (12rem).
        pub fn w_48(self: Self) Self {
            self.style().size.width = len_rem(12.0);
            return self;
        }
        /// Sets the width of the element to negative 192px (12rem).
        pub fn w_neg_48(self: Self) Self {
            self.style().size.width = len_rem(-12.0);
            return self;
        }
        /// Sets the width of the element to 224px (14rem).
        pub fn w_56(self: Self) Self {
            self.style().size.width = len_rem(14.0);
            return self;
        }
        /// Sets the width of the element to negative 224px (14rem).
        pub fn w_neg_56(self: Self) Self {
            self.style().size.width = len_rem(-14.0);
            return self;
        }
        /// Sets the width of the element to 256px (16rem).
        pub fn w_64(self: Self) Self {
            self.style().size.width = len_rem(16.0);
            return self;
        }
        /// Sets the width of the element to negative 256px (16rem).
        pub fn w_neg_64(self: Self) Self {
            self.style().size.width = len_rem(-16.0);
            return self;
        }
        /// Sets the width of the element to 288px (18rem).
        pub fn w_72(self: Self) Self {
            self.style().size.width = len_rem(18.0);
            return self;
        }
        /// Sets the width of the element to negative 288px (18rem).
        pub fn w_neg_72(self: Self) Self {
            self.style().size.width = len_rem(-18.0);
            return self;
        }
        /// Sets the width of the element to 320px (20rem).
        pub fn w_80(self: Self) Self {
            self.style().size.width = len_rem(20.0);
            return self;
        }
        /// Sets the width of the element to negative 320px (20rem).
        pub fn w_neg_80(self: Self) Self {
            self.style().size.width = len_rem(-20.0);
            return self;
        }
        /// Sets the width of the element to 384px (24rem).
        pub fn w_96(self: Self) Self {
            self.style().size.width = len_rem(24.0);
            return self;
        }
        /// Sets the width of the element to negative 384px (24rem).
        pub fn w_neg_96(self: Self) Self {
            self.style().size.width = len_rem(-24.0);
            return self;
        }
        /// Sets the width of the element to 448px (28rem).
        pub fn w_112(self: Self) Self {
            self.style().size.width = len_rem(28.0);
            return self;
        }
        /// Sets the width of the element to negative 448px (28rem).
        pub fn w_neg_112(self: Self) Self {
            self.style().size.width = len_rem(-28.0);
            return self;
        }
        /// Sets the width of the element to 512px (32rem).
        pub fn w_128(self: Self) Self {
            self.style().size.width = len_rem(32.0);
            return self;
        }
        /// Sets the width of the element to negative 512px (32rem).
        pub fn w_neg_128(self: Self) Self {
            self.style().size.width = len_rem(-32.0);
            return self;
        }
        /// Sets the width of the element to auto.
        pub fn w_auto(self: Self) Self {
            self.style().size.width = geometry.auto();
            return self;
        }
        /// Sets the width of the element to 1px.
        pub fn w_px(self: Self) Self {
            self.style().size.width = len_px(1.0);
            return self;
        }
        /// Sets the width of the element to negative 1px.
        pub fn w_neg_px(self: Self) Self {
            self.style().size.width = len_px(-1.0);
            return self;
        }
        /// Sets the width of the element to 100%.
        pub fn w_full(self: Self) Self {
            self.style().size.width = len_rel(1.0);
            return self;
        }
        /// Sets the width of the element to negative 100%.
        pub fn w_neg_full(self: Self) Self {
            self.style().size.width = len_rel(-1.0);
            return self;
        }
        /// Sets the width of the element to 50%.
        pub fn w_1_2(self: Self) Self {
            self.style().size.width = len_rel(0.5);
            return self;
        }
        /// Sets the width of the element to negative 50%.
        pub fn w_neg_1_2(self: Self) Self {
            self.style().size.width = len_rel(-0.5);
            return self;
        }
        /// Sets the width of the element to 33.3333%.
        pub fn w_1_3(self: Self) Self {
            self.style().size.width = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the width of the element to negative 33.3333%.
        pub fn w_neg_1_3(self: Self) Self {
            self.style().size.width = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the width of the element to 66.6667%.
        pub fn w_2_3(self: Self) Self {
            self.style().size.width = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the width of the element to negative 66.6667%.
        pub fn w_neg_2_3(self: Self) Self {
            self.style().size.width = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the width of the element to 25%.
        pub fn w_1_4(self: Self) Self {
            self.style().size.width = len_rel(0.25);
            return self;
        }
        /// Sets the width of the element to negative 25%.
        pub fn w_neg_1_4(self: Self) Self {
            self.style().size.width = len_rel(-0.25);
            return self;
        }
        /// Sets the width of the element to 50%.
        pub fn w_2_4(self: Self) Self {
            self.style().size.width = len_rel(0.5);
            return self;
        }
        /// Sets the width of the element to negative 50%.
        pub fn w_neg_2_4(self: Self) Self {
            self.style().size.width = len_rel(-0.5);
            return self;
        }
        /// Sets the width of the element to 75%.
        pub fn w_3_4(self: Self) Self {
            self.style().size.width = len_rel(0.75);
            return self;
        }
        /// Sets the width of the element to negative 75%.
        pub fn w_neg_3_4(self: Self) Self {
            self.style().size.width = len_rel(-0.75);
            return self;
        }
        /// Sets the width of the element to 20%.
        pub fn w_1_5(self: Self) Self {
            self.style().size.width = len_rel(0.2);
            return self;
        }
        /// Sets the width of the element to negative 20%.
        pub fn w_neg_1_5(self: Self) Self {
            self.style().size.width = len_rel(-0.2);
            return self;
        }
        /// Sets the width of the element to 40%.
        pub fn w_2_5(self: Self) Self {
            self.style().size.width = len_rel(0.4);
            return self;
        }
        /// Sets the width of the element to negative 40%.
        pub fn w_neg_2_5(self: Self) Self {
            self.style().size.width = len_rel(-0.4);
            return self;
        }
        /// Sets the width of the element to 60%.
        pub fn w_3_5(self: Self) Self {
            self.style().size.width = len_rel(0.6);
            return self;
        }
        /// Sets the width of the element to negative 60%.
        pub fn w_neg_3_5(self: Self) Self {
            self.style().size.width = len_rel(-0.6);
            return self;
        }
        /// Sets the width of the element to 80%.
        pub fn w_4_5(self: Self) Self {
            self.style().size.width = len_rel(0.8);
            return self;
        }
        /// Sets the width of the element to negative 80%.
        pub fn w_neg_4_5(self: Self) Self {
            self.style().size.width = len_rel(-0.8);
            return self;
        }
        /// Sets the width of the element to 16.6667%.
        pub fn w_1_6(self: Self) Self {
            self.style().size.width = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the width of the element to negative 16.6667%.
        pub fn w_neg_1_6(self: Self) Self {
            self.style().size.width = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the width of the element to 83.3333%.
        pub fn w_5_6(self: Self) Self {
            self.style().size.width = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the width of the element to negative 83.3333%.
        pub fn w_neg_5_6(self: Self) Self {
            self.style().size.width = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the width of the element to 8.33333%.
        pub fn w_1_12(self: Self) Self {
            self.style().size.width = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the width of the element to negative 8.33333%.
        pub fn w_neg_1_12(self: Self) Self {
            self.style().size.width = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the height of the element.
        pub fn h(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.size.height = v;
            return self;
        }
        /// Sets the height of the element to 0px.
        pub fn h_0(self: Self) Self {
            self.style().size.height = len_px(0.0);
            return self;
        }
        /// Sets the height of the element to negative 0px.
        pub fn h_neg_0(self: Self) Self {
            self.style().size.height = len_px(-0.0);
            return self;
        }
        /// Sets the height of the element to 2px (0.125rem).
        pub fn h_0p5(self: Self) Self {
            self.style().size.height = len_rem(0.125);
            return self;
        }
        /// Sets the height of the element to negative 2px (0.125rem).
        pub fn h_neg_0p5(self: Self) Self {
            self.style().size.height = len_rem(-0.125);
            return self;
        }
        /// Sets the height of the element to 4px (0.25rem).
        pub fn h_1(self: Self) Self {
            self.style().size.height = len_rem(0.25);
            return self;
        }
        /// Sets the height of the element to negative 4px (0.25rem).
        pub fn h_neg_1(self: Self) Self {
            self.style().size.height = len_rem(-0.25);
            return self;
        }
        /// Sets the height of the element to 6px (0.375rem).
        pub fn h_1p5(self: Self) Self {
            self.style().size.height = len_rem(0.375);
            return self;
        }
        /// Sets the height of the element to negative 6px (0.375rem).
        pub fn h_neg_1p5(self: Self) Self {
            self.style().size.height = len_rem(-0.375);
            return self;
        }
        /// Sets the height of the element to 8px (0.5rem).
        pub fn h_2(self: Self) Self {
            self.style().size.height = len_rem(0.5);
            return self;
        }
        /// Sets the height of the element to negative 8px (0.5rem).
        pub fn h_neg_2(self: Self) Self {
            self.style().size.height = len_rem(-0.5);
            return self;
        }
        /// Sets the height of the element to 10px (0.625rem).
        pub fn h_2p5(self: Self) Self {
            self.style().size.height = len_rem(0.625);
            return self;
        }
        /// Sets the height of the element to negative 10px (0.625rem).
        pub fn h_neg_2p5(self: Self) Self {
            self.style().size.height = len_rem(-0.625);
            return self;
        }
        /// Sets the height of the element to 12px (0.75rem).
        pub fn h_3(self: Self) Self {
            self.style().size.height = len_rem(0.75);
            return self;
        }
        /// Sets the height of the element to negative 12px (0.75rem).
        pub fn h_neg_3(self: Self) Self {
            self.style().size.height = len_rem(-0.75);
            return self;
        }
        /// Sets the height of the element to 14px (0.875rem).
        pub fn h_3p5(self: Self) Self {
            self.style().size.height = len_rem(0.875);
            return self;
        }
        /// Sets the height of the element to negative 14px (0.875rem).
        pub fn h_neg_3p5(self: Self) Self {
            self.style().size.height = len_rem(-0.875);
            return self;
        }
        /// Sets the height of the element to 16px (1rem).
        pub fn h_4(self: Self) Self {
            self.style().size.height = len_rem(1.0);
            return self;
        }
        /// Sets the height of the element to negative 16px (1rem).
        pub fn h_neg_4(self: Self) Self {
            self.style().size.height = len_rem(-1.0);
            return self;
        }
        /// Sets the height of the element to 20px (1.25rem).
        pub fn h_5(self: Self) Self {
            self.style().size.height = len_rem(1.25);
            return self;
        }
        /// Sets the height of the element to negative 20px (1.25rem).
        pub fn h_neg_5(self: Self) Self {
            self.style().size.height = len_rem(-1.25);
            return self;
        }
        /// Sets the height of the element to 24px (1.5rem).
        pub fn h_6(self: Self) Self {
            self.style().size.height = len_rem(1.5);
            return self;
        }
        /// Sets the height of the element to negative 24px (1.5rem).
        pub fn h_neg_6(self: Self) Self {
            self.style().size.height = len_rem(-1.5);
            return self;
        }
        /// Sets the height of the element to 28px (1.75rem).
        pub fn h_7(self: Self) Self {
            self.style().size.height = len_rem(1.75);
            return self;
        }
        /// Sets the height of the element to negative 28px (1.75rem).
        pub fn h_neg_7(self: Self) Self {
            self.style().size.height = len_rem(-1.75);
            return self;
        }
        /// Sets the height of the element to 32px (2rem).
        pub fn h_8(self: Self) Self {
            self.style().size.height = len_rem(2.0);
            return self;
        }
        /// Sets the height of the element to negative 32px (2rem).
        pub fn h_neg_8(self: Self) Self {
            self.style().size.height = len_rem(-2.0);
            return self;
        }
        /// Sets the height of the element to 36px (2.25rem).
        pub fn h_9(self: Self) Self {
            self.style().size.height = len_rem(2.25);
            return self;
        }
        /// Sets the height of the element to negative 36px (2.25rem).
        pub fn h_neg_9(self: Self) Self {
            self.style().size.height = len_rem(-2.25);
            return self;
        }
        /// Sets the height of the element to 40px (2.5rem).
        pub fn h_10(self: Self) Self {
            self.style().size.height = len_rem(2.5);
            return self;
        }
        /// Sets the height of the element to negative 40px (2.5rem).
        pub fn h_neg_10(self: Self) Self {
            self.style().size.height = len_rem(-2.5);
            return self;
        }
        /// Sets the height of the element to 44px (2.75rem).
        pub fn h_11(self: Self) Self {
            self.style().size.height = len_rem(2.75);
            return self;
        }
        /// Sets the height of the element to negative 44px (2.75rem).
        pub fn h_neg_11(self: Self) Self {
            self.style().size.height = len_rem(-2.75);
            return self;
        }
        /// Sets the height of the element to 48px (3rem).
        pub fn h_12(self: Self) Self {
            self.style().size.height = len_rem(3.0);
            return self;
        }
        /// Sets the height of the element to negative 48px (3rem).
        pub fn h_neg_12(self: Self) Self {
            self.style().size.height = len_rem(-3.0);
            return self;
        }
        /// Sets the height of the element to 64px (4rem).
        pub fn h_16(self: Self) Self {
            self.style().size.height = len_rem(4.0);
            return self;
        }
        /// Sets the height of the element to negative 64px (4rem).
        pub fn h_neg_16(self: Self) Self {
            self.style().size.height = len_rem(-4.0);
            return self;
        }
        /// Sets the height of the element to 80px (5rem).
        pub fn h_20(self: Self) Self {
            self.style().size.height = len_rem(5.0);
            return self;
        }
        /// Sets the height of the element to negative 80px (5rem).
        pub fn h_neg_20(self: Self) Self {
            self.style().size.height = len_rem(-5.0);
            return self;
        }
        /// Sets the height of the element to 96px (6rem).
        pub fn h_24(self: Self) Self {
            self.style().size.height = len_rem(6.0);
            return self;
        }
        /// Sets the height of the element to negative 96px (6rem).
        pub fn h_neg_24(self: Self) Self {
            self.style().size.height = len_rem(-6.0);
            return self;
        }
        /// Sets the height of the element to 128px (8rem).
        pub fn h_32(self: Self) Self {
            self.style().size.height = len_rem(8.0);
            return self;
        }
        /// Sets the height of the element to negative 128px (8rem).
        pub fn h_neg_32(self: Self) Self {
            self.style().size.height = len_rem(-8.0);
            return self;
        }
        /// Sets the height of the element to 160px (10rem).
        pub fn h_40(self: Self) Self {
            self.style().size.height = len_rem(10.0);
            return self;
        }
        /// Sets the height of the element to negative 160px (10rem).
        pub fn h_neg_40(self: Self) Self {
            self.style().size.height = len_rem(-10.0);
            return self;
        }
        /// Sets the height of the element to 192px (12rem).
        pub fn h_48(self: Self) Self {
            self.style().size.height = len_rem(12.0);
            return self;
        }
        /// Sets the height of the element to negative 192px (12rem).
        pub fn h_neg_48(self: Self) Self {
            self.style().size.height = len_rem(-12.0);
            return self;
        }
        /// Sets the height of the element to 224px (14rem).
        pub fn h_56(self: Self) Self {
            self.style().size.height = len_rem(14.0);
            return self;
        }
        /// Sets the height of the element to negative 224px (14rem).
        pub fn h_neg_56(self: Self) Self {
            self.style().size.height = len_rem(-14.0);
            return self;
        }
        /// Sets the height of the element to 256px (16rem).
        pub fn h_64(self: Self) Self {
            self.style().size.height = len_rem(16.0);
            return self;
        }
        /// Sets the height of the element to negative 256px (16rem).
        pub fn h_neg_64(self: Self) Self {
            self.style().size.height = len_rem(-16.0);
            return self;
        }
        /// Sets the height of the element to 288px (18rem).
        pub fn h_72(self: Self) Self {
            self.style().size.height = len_rem(18.0);
            return self;
        }
        /// Sets the height of the element to negative 288px (18rem).
        pub fn h_neg_72(self: Self) Self {
            self.style().size.height = len_rem(-18.0);
            return self;
        }
        /// Sets the height of the element to 320px (20rem).
        pub fn h_80(self: Self) Self {
            self.style().size.height = len_rem(20.0);
            return self;
        }
        /// Sets the height of the element to negative 320px (20rem).
        pub fn h_neg_80(self: Self) Self {
            self.style().size.height = len_rem(-20.0);
            return self;
        }
        /// Sets the height of the element to 384px (24rem).
        pub fn h_96(self: Self) Self {
            self.style().size.height = len_rem(24.0);
            return self;
        }
        /// Sets the height of the element to negative 384px (24rem).
        pub fn h_neg_96(self: Self) Self {
            self.style().size.height = len_rem(-24.0);
            return self;
        }
        /// Sets the height of the element to 448px (28rem).
        pub fn h_112(self: Self) Self {
            self.style().size.height = len_rem(28.0);
            return self;
        }
        /// Sets the height of the element to negative 448px (28rem).
        pub fn h_neg_112(self: Self) Self {
            self.style().size.height = len_rem(-28.0);
            return self;
        }
        /// Sets the height of the element to 512px (32rem).
        pub fn h_128(self: Self) Self {
            self.style().size.height = len_rem(32.0);
            return self;
        }
        /// Sets the height of the element to negative 512px (32rem).
        pub fn h_neg_128(self: Self) Self {
            self.style().size.height = len_rem(-32.0);
            return self;
        }
        /// Sets the height of the element to auto.
        pub fn h_auto(self: Self) Self {
            self.style().size.height = geometry.auto();
            return self;
        }
        /// Sets the height of the element to 1px.
        pub fn h_px(self: Self) Self {
            self.style().size.height = len_px(1.0);
            return self;
        }
        /// Sets the height of the element to negative 1px.
        pub fn h_neg_px(self: Self) Self {
            self.style().size.height = len_px(-1.0);
            return self;
        }
        /// Sets the height of the element to 100%.
        pub fn h_full(self: Self) Self {
            self.style().size.height = len_rel(1.0);
            return self;
        }
        /// Sets the height of the element to negative 100%.
        pub fn h_neg_full(self: Self) Self {
            self.style().size.height = len_rel(-1.0);
            return self;
        }
        /// Sets the height of the element to 50%.
        pub fn h_1_2(self: Self) Self {
            self.style().size.height = len_rel(0.5);
            return self;
        }
        /// Sets the height of the element to negative 50%.
        pub fn h_neg_1_2(self: Self) Self {
            self.style().size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the height of the element to 33.3333%.
        pub fn h_1_3(self: Self) Self {
            self.style().size.height = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the height of the element to negative 33.3333%.
        pub fn h_neg_1_3(self: Self) Self {
            self.style().size.height = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the height of the element to 66.6667%.
        pub fn h_2_3(self: Self) Self {
            self.style().size.height = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the height of the element to negative 66.6667%.
        pub fn h_neg_2_3(self: Self) Self {
            self.style().size.height = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the height of the element to 25%.
        pub fn h_1_4(self: Self) Self {
            self.style().size.height = len_rel(0.25);
            return self;
        }
        /// Sets the height of the element to negative 25%.
        pub fn h_neg_1_4(self: Self) Self {
            self.style().size.height = len_rel(-0.25);
            return self;
        }
        /// Sets the height of the element to 50%.
        pub fn h_2_4(self: Self) Self {
            self.style().size.height = len_rel(0.5);
            return self;
        }
        /// Sets the height of the element to negative 50%.
        pub fn h_neg_2_4(self: Self) Self {
            self.style().size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the height of the element to 75%.
        pub fn h_3_4(self: Self) Self {
            self.style().size.height = len_rel(0.75);
            return self;
        }
        /// Sets the height of the element to negative 75%.
        pub fn h_neg_3_4(self: Self) Self {
            self.style().size.height = len_rel(-0.75);
            return self;
        }
        /// Sets the height of the element to 20%.
        pub fn h_1_5(self: Self) Self {
            self.style().size.height = len_rel(0.2);
            return self;
        }
        /// Sets the height of the element to negative 20%.
        pub fn h_neg_1_5(self: Self) Self {
            self.style().size.height = len_rel(-0.2);
            return self;
        }
        /// Sets the height of the element to 40%.
        pub fn h_2_5(self: Self) Self {
            self.style().size.height = len_rel(0.4);
            return self;
        }
        /// Sets the height of the element to negative 40%.
        pub fn h_neg_2_5(self: Self) Self {
            self.style().size.height = len_rel(-0.4);
            return self;
        }
        /// Sets the height of the element to 60%.
        pub fn h_3_5(self: Self) Self {
            self.style().size.height = len_rel(0.6);
            return self;
        }
        /// Sets the height of the element to negative 60%.
        pub fn h_neg_3_5(self: Self) Self {
            self.style().size.height = len_rel(-0.6);
            return self;
        }
        /// Sets the height of the element to 80%.
        pub fn h_4_5(self: Self) Self {
            self.style().size.height = len_rel(0.8);
            return self;
        }
        /// Sets the height of the element to negative 80%.
        pub fn h_neg_4_5(self: Self) Self {
            self.style().size.height = len_rel(-0.8);
            return self;
        }
        /// Sets the height of the element to 16.6667%.
        pub fn h_1_6(self: Self) Self {
            self.style().size.height = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the height of the element to negative 16.6667%.
        pub fn h_neg_1_6(self: Self) Self {
            self.style().size.height = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the height of the element to 83.3333%.
        pub fn h_5_6(self: Self) Self {
            self.style().size.height = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the height of the element to negative 83.3333%.
        pub fn h_neg_5_6(self: Self) Self {
            self.style().size.height = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the height of the element to 8.33333%.
        pub fn h_1_12(self: Self) Self {
            self.style().size.height = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the height of the element to negative 8.33333%.
        pub fn h_neg_1_12(self: Self) Self {
            self.style().size.height = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the width and height of the element.
        pub fn size(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.size.width = v;
            s.size.height = v;
            return self;
        }
        /// Sets the width and height of the element to 0px.
        pub fn size_0(self: Self) Self {
            const s = self.style();
            s.size.width = len_px(0.0);
            s.size.height = len_px(0.0);
            return self;
        }
        /// Sets the width and height of the element to negative 0px.
        pub fn size_neg_0(self: Self) Self {
            const s = self.style();
            s.size.width = len_px(-0.0);
            s.size.height = len_px(-0.0);
            return self;
        }
        /// Sets the width and height of the element to 2px (0.125rem).
        pub fn size_0p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.125);
            s.size.height = len_rem(0.125);
            return self;
        }
        /// Sets the width and height of the element to negative 2px (0.125rem).
        pub fn size_neg_0p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.125);
            s.size.height = len_rem(-0.125);
            return self;
        }
        /// Sets the width and height of the element to 4px (0.25rem).
        pub fn size_1(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.25);
            s.size.height = len_rem(0.25);
            return self;
        }
        /// Sets the width and height of the element to negative 4px (0.25rem).
        pub fn size_neg_1(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.25);
            s.size.height = len_rem(-0.25);
            return self;
        }
        /// Sets the width and height of the element to 6px (0.375rem).
        pub fn size_1p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.375);
            s.size.height = len_rem(0.375);
            return self;
        }
        /// Sets the width and height of the element to negative 6px (0.375rem).
        pub fn size_neg_1p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.375);
            s.size.height = len_rem(-0.375);
            return self;
        }
        /// Sets the width and height of the element to 8px (0.5rem).
        pub fn size_2(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.5);
            s.size.height = len_rem(0.5);
            return self;
        }
        /// Sets the width and height of the element to negative 8px (0.5rem).
        pub fn size_neg_2(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.5);
            s.size.height = len_rem(-0.5);
            return self;
        }
        /// Sets the width and height of the element to 10px (0.625rem).
        pub fn size_2p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.625);
            s.size.height = len_rem(0.625);
            return self;
        }
        /// Sets the width and height of the element to negative 10px (0.625rem).
        pub fn size_neg_2p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.625);
            s.size.height = len_rem(-0.625);
            return self;
        }
        /// Sets the width and height of the element to 12px (0.75rem).
        pub fn size_3(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.75);
            s.size.height = len_rem(0.75);
            return self;
        }
        /// Sets the width and height of the element to negative 12px (0.75rem).
        pub fn size_neg_3(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.75);
            s.size.height = len_rem(-0.75);
            return self;
        }
        /// Sets the width and height of the element to 14px (0.875rem).
        pub fn size_3p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(0.875);
            s.size.height = len_rem(0.875);
            return self;
        }
        /// Sets the width and height of the element to negative 14px (0.875rem).
        pub fn size_neg_3p5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-0.875);
            s.size.height = len_rem(-0.875);
            return self;
        }
        /// Sets the width and height of the element to 16px (1rem).
        pub fn size_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(1.0);
            s.size.height = len_rem(1.0);
            return self;
        }
        /// Sets the width and height of the element to negative 16px (1rem).
        pub fn size_neg_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-1.0);
            s.size.height = len_rem(-1.0);
            return self;
        }
        /// Sets the width and height of the element to 20px (1.25rem).
        pub fn size_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(1.25);
            s.size.height = len_rem(1.25);
            return self;
        }
        /// Sets the width and height of the element to negative 20px (1.25rem).
        pub fn size_neg_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-1.25);
            s.size.height = len_rem(-1.25);
            return self;
        }
        /// Sets the width and height of the element to 24px (1.5rem).
        pub fn size_6(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(1.5);
            s.size.height = len_rem(1.5);
            return self;
        }
        /// Sets the width and height of the element to negative 24px (1.5rem).
        pub fn size_neg_6(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-1.5);
            s.size.height = len_rem(-1.5);
            return self;
        }
        /// Sets the width and height of the element to 28px (1.75rem).
        pub fn size_7(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(1.75);
            s.size.height = len_rem(1.75);
            return self;
        }
        /// Sets the width and height of the element to negative 28px (1.75rem).
        pub fn size_neg_7(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-1.75);
            s.size.height = len_rem(-1.75);
            return self;
        }
        /// Sets the width and height of the element to 32px (2rem).
        pub fn size_8(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(2.0);
            s.size.height = len_rem(2.0);
            return self;
        }
        /// Sets the width and height of the element to negative 32px (2rem).
        pub fn size_neg_8(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-2.0);
            s.size.height = len_rem(-2.0);
            return self;
        }
        /// Sets the width and height of the element to 36px (2.25rem).
        pub fn size_9(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(2.25);
            s.size.height = len_rem(2.25);
            return self;
        }
        /// Sets the width and height of the element to negative 36px (2.25rem).
        pub fn size_neg_9(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-2.25);
            s.size.height = len_rem(-2.25);
            return self;
        }
        /// Sets the width and height of the element to 40px (2.5rem).
        pub fn size_10(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(2.5);
            s.size.height = len_rem(2.5);
            return self;
        }
        /// Sets the width and height of the element to negative 40px (2.5rem).
        pub fn size_neg_10(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-2.5);
            s.size.height = len_rem(-2.5);
            return self;
        }
        /// Sets the width and height of the element to 44px (2.75rem).
        pub fn size_11(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(2.75);
            s.size.height = len_rem(2.75);
            return self;
        }
        /// Sets the width and height of the element to negative 44px (2.75rem).
        pub fn size_neg_11(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-2.75);
            s.size.height = len_rem(-2.75);
            return self;
        }
        /// Sets the width and height of the element to 48px (3rem).
        pub fn size_12(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(3.0);
            s.size.height = len_rem(3.0);
            return self;
        }
        /// Sets the width and height of the element to negative 48px (3rem).
        pub fn size_neg_12(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-3.0);
            s.size.height = len_rem(-3.0);
            return self;
        }
        /// Sets the width and height of the element to 64px (4rem).
        pub fn size_16(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(4.0);
            s.size.height = len_rem(4.0);
            return self;
        }
        /// Sets the width and height of the element to negative 64px (4rem).
        pub fn size_neg_16(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-4.0);
            s.size.height = len_rem(-4.0);
            return self;
        }
        /// Sets the width and height of the element to 80px (5rem).
        pub fn size_20(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(5.0);
            s.size.height = len_rem(5.0);
            return self;
        }
        /// Sets the width and height of the element to negative 80px (5rem).
        pub fn size_neg_20(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-5.0);
            s.size.height = len_rem(-5.0);
            return self;
        }
        /// Sets the width and height of the element to 96px (6rem).
        pub fn size_24(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(6.0);
            s.size.height = len_rem(6.0);
            return self;
        }
        /// Sets the width and height of the element to negative 96px (6rem).
        pub fn size_neg_24(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-6.0);
            s.size.height = len_rem(-6.0);
            return self;
        }
        /// Sets the width and height of the element to 128px (8rem).
        pub fn size_32(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(8.0);
            s.size.height = len_rem(8.0);
            return self;
        }
        /// Sets the width and height of the element to negative 128px (8rem).
        pub fn size_neg_32(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-8.0);
            s.size.height = len_rem(-8.0);
            return self;
        }
        /// Sets the width and height of the element to 160px (10rem).
        pub fn size_40(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(10.0);
            s.size.height = len_rem(10.0);
            return self;
        }
        /// Sets the width and height of the element to negative 160px (10rem).
        pub fn size_neg_40(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-10.0);
            s.size.height = len_rem(-10.0);
            return self;
        }
        /// Sets the width and height of the element to 192px (12rem).
        pub fn size_48(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(12.0);
            s.size.height = len_rem(12.0);
            return self;
        }
        /// Sets the width and height of the element to negative 192px (12rem).
        pub fn size_neg_48(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-12.0);
            s.size.height = len_rem(-12.0);
            return self;
        }
        /// Sets the width and height of the element to 224px (14rem).
        pub fn size_56(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(14.0);
            s.size.height = len_rem(14.0);
            return self;
        }
        /// Sets the width and height of the element to negative 224px (14rem).
        pub fn size_neg_56(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-14.0);
            s.size.height = len_rem(-14.0);
            return self;
        }
        /// Sets the width and height of the element to 256px (16rem).
        pub fn size_64(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(16.0);
            s.size.height = len_rem(16.0);
            return self;
        }
        /// Sets the width and height of the element to negative 256px (16rem).
        pub fn size_neg_64(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-16.0);
            s.size.height = len_rem(-16.0);
            return self;
        }
        /// Sets the width and height of the element to 288px (18rem).
        pub fn size_72(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(18.0);
            s.size.height = len_rem(18.0);
            return self;
        }
        /// Sets the width and height of the element to negative 288px (18rem).
        pub fn size_neg_72(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-18.0);
            s.size.height = len_rem(-18.0);
            return self;
        }
        /// Sets the width and height of the element to 320px (20rem).
        pub fn size_80(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(20.0);
            s.size.height = len_rem(20.0);
            return self;
        }
        /// Sets the width and height of the element to negative 320px (20rem).
        pub fn size_neg_80(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-20.0);
            s.size.height = len_rem(-20.0);
            return self;
        }
        /// Sets the width and height of the element to 384px (24rem).
        pub fn size_96(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(24.0);
            s.size.height = len_rem(24.0);
            return self;
        }
        /// Sets the width and height of the element to negative 384px (24rem).
        pub fn size_neg_96(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-24.0);
            s.size.height = len_rem(-24.0);
            return self;
        }
        /// Sets the width and height of the element to 448px (28rem).
        pub fn size_112(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(28.0);
            s.size.height = len_rem(28.0);
            return self;
        }
        /// Sets the width and height of the element to negative 448px (28rem).
        pub fn size_neg_112(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-28.0);
            s.size.height = len_rem(-28.0);
            return self;
        }
        /// Sets the width and height of the element to 512px (32rem).
        pub fn size_128(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(32.0);
            s.size.height = len_rem(32.0);
            return self;
        }
        /// Sets the width and height of the element to negative 512px (32rem).
        pub fn size_neg_128(self: Self) Self {
            const s = self.style();
            s.size.width = len_rem(-32.0);
            s.size.height = len_rem(-32.0);
            return self;
        }
        /// Sets the width and height of the element to auto.
        pub fn size_auto(self: Self) Self {
            const s = self.style();
            s.size.width = geometry.auto();
            s.size.height = geometry.auto();
            return self;
        }
        /// Sets the width and height of the element to 1px.
        pub fn size_px(self: Self) Self {
            const s = self.style();
            s.size.width = len_px(1.0);
            s.size.height = len_px(1.0);
            return self;
        }
        /// Sets the width and height of the element to negative 1px.
        pub fn size_neg_px(self: Self) Self {
            const s = self.style();
            s.size.width = len_px(-1.0);
            s.size.height = len_px(-1.0);
            return self;
        }
        /// Sets the width and height of the element to 100%.
        pub fn size_full(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(1.0);
            s.size.height = len_rel(1.0);
            return self;
        }
        /// Sets the width and height of the element to negative 100%.
        pub fn size_neg_full(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-1.0);
            s.size.height = len_rel(-1.0);
            return self;
        }
        /// Sets the width and height of the element to 50%.
        pub fn size_1_2(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.5);
            s.size.height = len_rel(0.5);
            return self;
        }
        /// Sets the width and height of the element to negative 50%.
        pub fn size_neg_1_2(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.5);
            s.size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the width and height of the element to 33.3333%.
        pub fn size_1_3(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.3333333333333333);
            s.size.height = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the width and height of the element to negative 33.3333%.
        pub fn size_neg_1_3(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.3333333333333333);
            s.size.height = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the width and height of the element to 66.6667%.
        pub fn size_2_3(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.6666666666666666);
            s.size.height = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the width and height of the element to negative 66.6667%.
        pub fn size_neg_2_3(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.6666666666666666);
            s.size.height = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the width and height of the element to 25%.
        pub fn size_1_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.25);
            s.size.height = len_rel(0.25);
            return self;
        }
        /// Sets the width and height of the element to negative 25%.
        pub fn size_neg_1_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.25);
            s.size.height = len_rel(-0.25);
            return self;
        }
        /// Sets the width and height of the element to 50%.
        pub fn size_2_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.5);
            s.size.height = len_rel(0.5);
            return self;
        }
        /// Sets the width and height of the element to negative 50%.
        pub fn size_neg_2_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.5);
            s.size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the width and height of the element to 75%.
        pub fn size_3_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.75);
            s.size.height = len_rel(0.75);
            return self;
        }
        /// Sets the width and height of the element to negative 75%.
        pub fn size_neg_3_4(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.75);
            s.size.height = len_rel(-0.75);
            return self;
        }
        /// Sets the width and height of the element to 20%.
        pub fn size_1_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.2);
            s.size.height = len_rel(0.2);
            return self;
        }
        /// Sets the width and height of the element to negative 20%.
        pub fn size_neg_1_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.2);
            s.size.height = len_rel(-0.2);
            return self;
        }
        /// Sets the width and height of the element to 40%.
        pub fn size_2_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.4);
            s.size.height = len_rel(0.4);
            return self;
        }
        /// Sets the width and height of the element to negative 40%.
        pub fn size_neg_2_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.4);
            s.size.height = len_rel(-0.4);
            return self;
        }
        /// Sets the width and height of the element to 60%.
        pub fn size_3_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.6);
            s.size.height = len_rel(0.6);
            return self;
        }
        /// Sets the width and height of the element to negative 60%.
        pub fn size_neg_3_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.6);
            s.size.height = len_rel(-0.6);
            return self;
        }
        /// Sets the width and height of the element to 80%.
        pub fn size_4_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.8);
            s.size.height = len_rel(0.8);
            return self;
        }
        /// Sets the width and height of the element to negative 80%.
        pub fn size_neg_4_5(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.8);
            s.size.height = len_rel(-0.8);
            return self;
        }
        /// Sets the width and height of the element to 16.6667%.
        pub fn size_1_6(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.16666666666666666);
            s.size.height = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the width and height of the element to negative 16.6667%.
        pub fn size_neg_1_6(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.16666666666666666);
            s.size.height = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the width and height of the element to 83.3333%.
        pub fn size_5_6(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.8333333333333334);
            s.size.height = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the width and height of the element to negative 83.3333%.
        pub fn size_neg_5_6(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.8333333333333334);
            s.size.height = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the width and height of the element to 8.33333%.
        pub fn size_1_12(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(0.08333333333333333);
            s.size.height = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the width and height of the element to negative 8.33333%.
        pub fn size_neg_1_12(self: Self) Self {
            const s = self.style();
            s.size.width = len_rel(-0.08333333333333333);
            s.size.height = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the minimum width and height of the element.
        pub fn min_size(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.min_size.width = v;
            s.min_size.height = v;
            return self;
        }
        /// Sets the minimum width and height of the element to 0px.
        pub fn min_size_0(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_px(0.0);
            s.min_size.height = len_px(0.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 0px.
        pub fn min_size_neg_0(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_px(-0.0);
            s.min_size.height = len_px(-0.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 2px (0.125rem).
        pub fn min_size_0p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.125);
            s.min_size.height = len_rem(0.125);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 2px (0.125rem).
        pub fn min_size_neg_0p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.125);
            s.min_size.height = len_rem(-0.125);
            return self;
        }
        /// Sets the minimum width and height of the element to 4px (0.25rem).
        pub fn min_size_1(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.25);
            s.min_size.height = len_rem(0.25);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 4px (0.25rem).
        pub fn min_size_neg_1(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.25);
            s.min_size.height = len_rem(-0.25);
            return self;
        }
        /// Sets the minimum width and height of the element to 6px (0.375rem).
        pub fn min_size_1p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.375);
            s.min_size.height = len_rem(0.375);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 6px (0.375rem).
        pub fn min_size_neg_1p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.375);
            s.min_size.height = len_rem(-0.375);
            return self;
        }
        /// Sets the minimum width and height of the element to 8px (0.5rem).
        pub fn min_size_2(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.5);
            s.min_size.height = len_rem(0.5);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 8px (0.5rem).
        pub fn min_size_neg_2(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.5);
            s.min_size.height = len_rem(-0.5);
            return self;
        }
        /// Sets the minimum width and height of the element to 10px (0.625rem).
        pub fn min_size_2p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.625);
            s.min_size.height = len_rem(0.625);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 10px (0.625rem).
        pub fn min_size_neg_2p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.625);
            s.min_size.height = len_rem(-0.625);
            return self;
        }
        /// Sets the minimum width and height of the element to 12px (0.75rem).
        pub fn min_size_3(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.75);
            s.min_size.height = len_rem(0.75);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 12px (0.75rem).
        pub fn min_size_neg_3(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.75);
            s.min_size.height = len_rem(-0.75);
            return self;
        }
        /// Sets the minimum width and height of the element to 14px (0.875rem).
        pub fn min_size_3p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(0.875);
            s.min_size.height = len_rem(0.875);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 14px (0.875rem).
        pub fn min_size_neg_3p5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-0.875);
            s.min_size.height = len_rem(-0.875);
            return self;
        }
        /// Sets the minimum width and height of the element to 16px (1rem).
        pub fn min_size_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(1.0);
            s.min_size.height = len_rem(1.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 16px (1rem).
        pub fn min_size_neg_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-1.0);
            s.min_size.height = len_rem(-1.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 20px (1.25rem).
        pub fn min_size_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(1.25);
            s.min_size.height = len_rem(1.25);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 20px (1.25rem).
        pub fn min_size_neg_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-1.25);
            s.min_size.height = len_rem(-1.25);
            return self;
        }
        /// Sets the minimum width and height of the element to 24px (1.5rem).
        pub fn min_size_6(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(1.5);
            s.min_size.height = len_rem(1.5);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 24px (1.5rem).
        pub fn min_size_neg_6(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-1.5);
            s.min_size.height = len_rem(-1.5);
            return self;
        }
        /// Sets the minimum width and height of the element to 28px (1.75rem).
        pub fn min_size_7(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(1.75);
            s.min_size.height = len_rem(1.75);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 28px (1.75rem).
        pub fn min_size_neg_7(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-1.75);
            s.min_size.height = len_rem(-1.75);
            return self;
        }
        /// Sets the minimum width and height of the element to 32px (2rem).
        pub fn min_size_8(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(2.0);
            s.min_size.height = len_rem(2.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 32px (2rem).
        pub fn min_size_neg_8(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-2.0);
            s.min_size.height = len_rem(-2.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 36px (2.25rem).
        pub fn min_size_9(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(2.25);
            s.min_size.height = len_rem(2.25);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 36px (2.25rem).
        pub fn min_size_neg_9(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-2.25);
            s.min_size.height = len_rem(-2.25);
            return self;
        }
        /// Sets the minimum width and height of the element to 40px (2.5rem).
        pub fn min_size_10(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(2.5);
            s.min_size.height = len_rem(2.5);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 40px (2.5rem).
        pub fn min_size_neg_10(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-2.5);
            s.min_size.height = len_rem(-2.5);
            return self;
        }
        /// Sets the minimum width and height of the element to 44px (2.75rem).
        pub fn min_size_11(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(2.75);
            s.min_size.height = len_rem(2.75);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 44px (2.75rem).
        pub fn min_size_neg_11(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-2.75);
            s.min_size.height = len_rem(-2.75);
            return self;
        }
        /// Sets the minimum width and height of the element to 48px (3rem).
        pub fn min_size_12(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(3.0);
            s.min_size.height = len_rem(3.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 48px (3rem).
        pub fn min_size_neg_12(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-3.0);
            s.min_size.height = len_rem(-3.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 64px (4rem).
        pub fn min_size_16(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(4.0);
            s.min_size.height = len_rem(4.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 64px (4rem).
        pub fn min_size_neg_16(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-4.0);
            s.min_size.height = len_rem(-4.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 80px (5rem).
        pub fn min_size_20(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(5.0);
            s.min_size.height = len_rem(5.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 80px (5rem).
        pub fn min_size_neg_20(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-5.0);
            s.min_size.height = len_rem(-5.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 96px (6rem).
        pub fn min_size_24(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(6.0);
            s.min_size.height = len_rem(6.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 96px (6rem).
        pub fn min_size_neg_24(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-6.0);
            s.min_size.height = len_rem(-6.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 128px (8rem).
        pub fn min_size_32(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(8.0);
            s.min_size.height = len_rem(8.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 128px (8rem).
        pub fn min_size_neg_32(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-8.0);
            s.min_size.height = len_rem(-8.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 160px (10rem).
        pub fn min_size_40(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(10.0);
            s.min_size.height = len_rem(10.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 160px (10rem).
        pub fn min_size_neg_40(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-10.0);
            s.min_size.height = len_rem(-10.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 192px (12rem).
        pub fn min_size_48(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(12.0);
            s.min_size.height = len_rem(12.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 192px (12rem).
        pub fn min_size_neg_48(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-12.0);
            s.min_size.height = len_rem(-12.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 224px (14rem).
        pub fn min_size_56(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(14.0);
            s.min_size.height = len_rem(14.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 224px (14rem).
        pub fn min_size_neg_56(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-14.0);
            s.min_size.height = len_rem(-14.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 256px (16rem).
        pub fn min_size_64(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(16.0);
            s.min_size.height = len_rem(16.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 256px (16rem).
        pub fn min_size_neg_64(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-16.0);
            s.min_size.height = len_rem(-16.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 288px (18rem).
        pub fn min_size_72(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(18.0);
            s.min_size.height = len_rem(18.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 288px (18rem).
        pub fn min_size_neg_72(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-18.0);
            s.min_size.height = len_rem(-18.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 320px (20rem).
        pub fn min_size_80(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(20.0);
            s.min_size.height = len_rem(20.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 320px (20rem).
        pub fn min_size_neg_80(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-20.0);
            s.min_size.height = len_rem(-20.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 384px (24rem).
        pub fn min_size_96(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(24.0);
            s.min_size.height = len_rem(24.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 384px (24rem).
        pub fn min_size_neg_96(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-24.0);
            s.min_size.height = len_rem(-24.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 448px (28rem).
        pub fn min_size_112(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(28.0);
            s.min_size.height = len_rem(28.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 448px (28rem).
        pub fn min_size_neg_112(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-28.0);
            s.min_size.height = len_rem(-28.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 512px (32rem).
        pub fn min_size_128(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(32.0);
            s.min_size.height = len_rem(32.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 512px (32rem).
        pub fn min_size_neg_128(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rem(-32.0);
            s.min_size.height = len_rem(-32.0);
            return self;
        }
        /// Sets the minimum width and height of the element to auto.
        pub fn min_size_auto(self: Self) Self {
            const s = self.style();
            s.min_size.width = geometry.auto();
            s.min_size.height = geometry.auto();
            return self;
        }
        /// Sets the minimum width and height of the element to 1px.
        pub fn min_size_px(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_px(1.0);
            s.min_size.height = len_px(1.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 1px.
        pub fn min_size_neg_px(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_px(-1.0);
            s.min_size.height = len_px(-1.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 100%.
        pub fn min_size_full(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(1.0);
            s.min_size.height = len_rel(1.0);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 100%.
        pub fn min_size_neg_full(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-1.0);
            s.min_size.height = len_rel(-1.0);
            return self;
        }
        /// Sets the minimum width and height of the element to 50%.
        pub fn min_size_1_2(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.5);
            s.min_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 50%.
        pub fn min_size_neg_1_2(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.5);
            s.min_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the minimum width and height of the element to 33.3333%.
        pub fn min_size_1_3(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.3333333333333333);
            s.min_size.height = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 33.3333%.
        pub fn min_size_neg_1_3(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.3333333333333333);
            s.min_size.height = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the minimum width and height of the element to 66.6667%.
        pub fn min_size_2_3(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.6666666666666666);
            s.min_size.height = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 66.6667%.
        pub fn min_size_neg_2_3(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.6666666666666666);
            s.min_size.height = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the minimum width and height of the element to 25%.
        pub fn min_size_1_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.25);
            s.min_size.height = len_rel(0.25);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 25%.
        pub fn min_size_neg_1_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.25);
            s.min_size.height = len_rel(-0.25);
            return self;
        }
        /// Sets the minimum width and height of the element to 50%.
        pub fn min_size_2_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.5);
            s.min_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 50%.
        pub fn min_size_neg_2_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.5);
            s.min_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the minimum width and height of the element to 75%.
        pub fn min_size_3_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.75);
            s.min_size.height = len_rel(0.75);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 75%.
        pub fn min_size_neg_3_4(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.75);
            s.min_size.height = len_rel(-0.75);
            return self;
        }
        /// Sets the minimum width and height of the element to 20%.
        pub fn min_size_1_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.2);
            s.min_size.height = len_rel(0.2);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 20%.
        pub fn min_size_neg_1_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.2);
            s.min_size.height = len_rel(-0.2);
            return self;
        }
        /// Sets the minimum width and height of the element to 40%.
        pub fn min_size_2_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.4);
            s.min_size.height = len_rel(0.4);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 40%.
        pub fn min_size_neg_2_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.4);
            s.min_size.height = len_rel(-0.4);
            return self;
        }
        /// Sets the minimum width and height of the element to 60%.
        pub fn min_size_3_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.6);
            s.min_size.height = len_rel(0.6);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 60%.
        pub fn min_size_neg_3_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.6);
            s.min_size.height = len_rel(-0.6);
            return self;
        }
        /// Sets the minimum width and height of the element to 80%.
        pub fn min_size_4_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.8);
            s.min_size.height = len_rel(0.8);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 80%.
        pub fn min_size_neg_4_5(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.8);
            s.min_size.height = len_rel(-0.8);
            return self;
        }
        /// Sets the minimum width and height of the element to 16.6667%.
        pub fn min_size_1_6(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.16666666666666666);
            s.min_size.height = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 16.6667%.
        pub fn min_size_neg_1_6(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.16666666666666666);
            s.min_size.height = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the minimum width and height of the element to 83.3333%.
        pub fn min_size_5_6(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.8333333333333334);
            s.min_size.height = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 83.3333%.
        pub fn min_size_neg_5_6(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.8333333333333334);
            s.min_size.height = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the minimum width and height of the element to 8.33333%.
        pub fn min_size_1_12(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(0.08333333333333333);
            s.min_size.height = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the minimum width and height of the element to negative 8.33333%.
        pub fn min_size_neg_1_12(self: Self) Self {
            const s = self.style();
            s.min_size.width = len_rel(-0.08333333333333333);
            s.min_size.height = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the minimum width of the element.
        pub fn min_w(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.min_size.width = v;
            return self;
        }
        /// Sets the minimum width of the element to 0px.
        pub fn min_w_0(self: Self) Self {
            self.style().min_size.width = len_px(0.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 0px.
        pub fn min_w_neg_0(self: Self) Self {
            self.style().min_size.width = len_px(-0.0);
            return self;
        }
        /// Sets the minimum width of the element to 2px (0.125rem).
        pub fn min_w_0p5(self: Self) Self {
            self.style().min_size.width = len_rem(0.125);
            return self;
        }
        /// Sets the minimum width of the element to negative 2px (0.125rem).
        pub fn min_w_neg_0p5(self: Self) Self {
            self.style().min_size.width = len_rem(-0.125);
            return self;
        }
        /// Sets the minimum width of the element to 4px (0.25rem).
        pub fn min_w_1(self: Self) Self {
            self.style().min_size.width = len_rem(0.25);
            return self;
        }
        /// Sets the minimum width of the element to negative 4px (0.25rem).
        pub fn min_w_neg_1(self: Self) Self {
            self.style().min_size.width = len_rem(-0.25);
            return self;
        }
        /// Sets the minimum width of the element to 6px (0.375rem).
        pub fn min_w_1p5(self: Self) Self {
            self.style().min_size.width = len_rem(0.375);
            return self;
        }
        /// Sets the minimum width of the element to negative 6px (0.375rem).
        pub fn min_w_neg_1p5(self: Self) Self {
            self.style().min_size.width = len_rem(-0.375);
            return self;
        }
        /// Sets the minimum width of the element to 8px (0.5rem).
        pub fn min_w_2(self: Self) Self {
            self.style().min_size.width = len_rem(0.5);
            return self;
        }
        /// Sets the minimum width of the element to negative 8px (0.5rem).
        pub fn min_w_neg_2(self: Self) Self {
            self.style().min_size.width = len_rem(-0.5);
            return self;
        }
        /// Sets the minimum width of the element to 10px (0.625rem).
        pub fn min_w_2p5(self: Self) Self {
            self.style().min_size.width = len_rem(0.625);
            return self;
        }
        /// Sets the minimum width of the element to negative 10px (0.625rem).
        pub fn min_w_neg_2p5(self: Self) Self {
            self.style().min_size.width = len_rem(-0.625);
            return self;
        }
        /// Sets the minimum width of the element to 12px (0.75rem).
        pub fn min_w_3(self: Self) Self {
            self.style().min_size.width = len_rem(0.75);
            return self;
        }
        /// Sets the minimum width of the element to negative 12px (0.75rem).
        pub fn min_w_neg_3(self: Self) Self {
            self.style().min_size.width = len_rem(-0.75);
            return self;
        }
        /// Sets the minimum width of the element to 14px (0.875rem).
        pub fn min_w_3p5(self: Self) Self {
            self.style().min_size.width = len_rem(0.875);
            return self;
        }
        /// Sets the minimum width of the element to negative 14px (0.875rem).
        pub fn min_w_neg_3p5(self: Self) Self {
            self.style().min_size.width = len_rem(-0.875);
            return self;
        }
        /// Sets the minimum width of the element to 16px (1rem).
        pub fn min_w_4(self: Self) Self {
            self.style().min_size.width = len_rem(1.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 16px (1rem).
        pub fn min_w_neg_4(self: Self) Self {
            self.style().min_size.width = len_rem(-1.0);
            return self;
        }
        /// Sets the minimum width of the element to 20px (1.25rem).
        pub fn min_w_5(self: Self) Self {
            self.style().min_size.width = len_rem(1.25);
            return self;
        }
        /// Sets the minimum width of the element to negative 20px (1.25rem).
        pub fn min_w_neg_5(self: Self) Self {
            self.style().min_size.width = len_rem(-1.25);
            return self;
        }
        /// Sets the minimum width of the element to 24px (1.5rem).
        pub fn min_w_6(self: Self) Self {
            self.style().min_size.width = len_rem(1.5);
            return self;
        }
        /// Sets the minimum width of the element to negative 24px (1.5rem).
        pub fn min_w_neg_6(self: Self) Self {
            self.style().min_size.width = len_rem(-1.5);
            return self;
        }
        /// Sets the minimum width of the element to 28px (1.75rem).
        pub fn min_w_7(self: Self) Self {
            self.style().min_size.width = len_rem(1.75);
            return self;
        }
        /// Sets the minimum width of the element to negative 28px (1.75rem).
        pub fn min_w_neg_7(self: Self) Self {
            self.style().min_size.width = len_rem(-1.75);
            return self;
        }
        /// Sets the minimum width of the element to 32px (2rem).
        pub fn min_w_8(self: Self) Self {
            self.style().min_size.width = len_rem(2.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 32px (2rem).
        pub fn min_w_neg_8(self: Self) Self {
            self.style().min_size.width = len_rem(-2.0);
            return self;
        }
        /// Sets the minimum width of the element to 36px (2.25rem).
        pub fn min_w_9(self: Self) Self {
            self.style().min_size.width = len_rem(2.25);
            return self;
        }
        /// Sets the minimum width of the element to negative 36px (2.25rem).
        pub fn min_w_neg_9(self: Self) Self {
            self.style().min_size.width = len_rem(-2.25);
            return self;
        }
        /// Sets the minimum width of the element to 40px (2.5rem).
        pub fn min_w_10(self: Self) Self {
            self.style().min_size.width = len_rem(2.5);
            return self;
        }
        /// Sets the minimum width of the element to negative 40px (2.5rem).
        pub fn min_w_neg_10(self: Self) Self {
            self.style().min_size.width = len_rem(-2.5);
            return self;
        }
        /// Sets the minimum width of the element to 44px (2.75rem).
        pub fn min_w_11(self: Self) Self {
            self.style().min_size.width = len_rem(2.75);
            return self;
        }
        /// Sets the minimum width of the element to negative 44px (2.75rem).
        pub fn min_w_neg_11(self: Self) Self {
            self.style().min_size.width = len_rem(-2.75);
            return self;
        }
        /// Sets the minimum width of the element to 48px (3rem).
        pub fn min_w_12(self: Self) Self {
            self.style().min_size.width = len_rem(3.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 48px (3rem).
        pub fn min_w_neg_12(self: Self) Self {
            self.style().min_size.width = len_rem(-3.0);
            return self;
        }
        /// Sets the minimum width of the element to 64px (4rem).
        pub fn min_w_16(self: Self) Self {
            self.style().min_size.width = len_rem(4.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 64px (4rem).
        pub fn min_w_neg_16(self: Self) Self {
            self.style().min_size.width = len_rem(-4.0);
            return self;
        }
        /// Sets the minimum width of the element to 80px (5rem).
        pub fn min_w_20(self: Self) Self {
            self.style().min_size.width = len_rem(5.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 80px (5rem).
        pub fn min_w_neg_20(self: Self) Self {
            self.style().min_size.width = len_rem(-5.0);
            return self;
        }
        /// Sets the minimum width of the element to 96px (6rem).
        pub fn min_w_24(self: Self) Self {
            self.style().min_size.width = len_rem(6.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 96px (6rem).
        pub fn min_w_neg_24(self: Self) Self {
            self.style().min_size.width = len_rem(-6.0);
            return self;
        }
        /// Sets the minimum width of the element to 128px (8rem).
        pub fn min_w_32(self: Self) Self {
            self.style().min_size.width = len_rem(8.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 128px (8rem).
        pub fn min_w_neg_32(self: Self) Self {
            self.style().min_size.width = len_rem(-8.0);
            return self;
        }
        /// Sets the minimum width of the element to 160px (10rem).
        pub fn min_w_40(self: Self) Self {
            self.style().min_size.width = len_rem(10.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 160px (10rem).
        pub fn min_w_neg_40(self: Self) Self {
            self.style().min_size.width = len_rem(-10.0);
            return self;
        }
        /// Sets the minimum width of the element to 192px (12rem).
        pub fn min_w_48(self: Self) Self {
            self.style().min_size.width = len_rem(12.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 192px (12rem).
        pub fn min_w_neg_48(self: Self) Self {
            self.style().min_size.width = len_rem(-12.0);
            return self;
        }
        /// Sets the minimum width of the element to 224px (14rem).
        pub fn min_w_56(self: Self) Self {
            self.style().min_size.width = len_rem(14.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 224px (14rem).
        pub fn min_w_neg_56(self: Self) Self {
            self.style().min_size.width = len_rem(-14.0);
            return self;
        }
        /// Sets the minimum width of the element to 256px (16rem).
        pub fn min_w_64(self: Self) Self {
            self.style().min_size.width = len_rem(16.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 256px (16rem).
        pub fn min_w_neg_64(self: Self) Self {
            self.style().min_size.width = len_rem(-16.0);
            return self;
        }
        /// Sets the minimum width of the element to 288px (18rem).
        pub fn min_w_72(self: Self) Self {
            self.style().min_size.width = len_rem(18.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 288px (18rem).
        pub fn min_w_neg_72(self: Self) Self {
            self.style().min_size.width = len_rem(-18.0);
            return self;
        }
        /// Sets the minimum width of the element to 320px (20rem).
        pub fn min_w_80(self: Self) Self {
            self.style().min_size.width = len_rem(20.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 320px (20rem).
        pub fn min_w_neg_80(self: Self) Self {
            self.style().min_size.width = len_rem(-20.0);
            return self;
        }
        /// Sets the minimum width of the element to 384px (24rem).
        pub fn min_w_96(self: Self) Self {
            self.style().min_size.width = len_rem(24.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 384px (24rem).
        pub fn min_w_neg_96(self: Self) Self {
            self.style().min_size.width = len_rem(-24.0);
            return self;
        }
        /// Sets the minimum width of the element to 448px (28rem).
        pub fn min_w_112(self: Self) Self {
            self.style().min_size.width = len_rem(28.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 448px (28rem).
        pub fn min_w_neg_112(self: Self) Self {
            self.style().min_size.width = len_rem(-28.0);
            return self;
        }
        /// Sets the minimum width of the element to 512px (32rem).
        pub fn min_w_128(self: Self) Self {
            self.style().min_size.width = len_rem(32.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 512px (32rem).
        pub fn min_w_neg_128(self: Self) Self {
            self.style().min_size.width = len_rem(-32.0);
            return self;
        }
        /// Sets the minimum width of the element to auto.
        pub fn min_w_auto(self: Self) Self {
            self.style().min_size.width = geometry.auto();
            return self;
        }
        /// Sets the minimum width of the element to 1px.
        pub fn min_w_px(self: Self) Self {
            self.style().min_size.width = len_px(1.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 1px.
        pub fn min_w_neg_px(self: Self) Self {
            self.style().min_size.width = len_px(-1.0);
            return self;
        }
        /// Sets the minimum width of the element to 100%.
        pub fn min_w_full(self: Self) Self {
            self.style().min_size.width = len_rel(1.0);
            return self;
        }
        /// Sets the minimum width of the element to negative 100%.
        pub fn min_w_neg_full(self: Self) Self {
            self.style().min_size.width = len_rel(-1.0);
            return self;
        }
        /// Sets the minimum width of the element to 50%.
        pub fn min_w_1_2(self: Self) Self {
            self.style().min_size.width = len_rel(0.5);
            return self;
        }
        /// Sets the minimum width of the element to negative 50%.
        pub fn min_w_neg_1_2(self: Self) Self {
            self.style().min_size.width = len_rel(-0.5);
            return self;
        }
        /// Sets the minimum width of the element to 33.3333%.
        pub fn min_w_1_3(self: Self) Self {
            self.style().min_size.width = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the minimum width of the element to negative 33.3333%.
        pub fn min_w_neg_1_3(self: Self) Self {
            self.style().min_size.width = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the minimum width of the element to 66.6667%.
        pub fn min_w_2_3(self: Self) Self {
            self.style().min_size.width = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the minimum width of the element to negative 66.6667%.
        pub fn min_w_neg_2_3(self: Self) Self {
            self.style().min_size.width = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the minimum width of the element to 25%.
        pub fn min_w_1_4(self: Self) Self {
            self.style().min_size.width = len_rel(0.25);
            return self;
        }
        /// Sets the minimum width of the element to negative 25%.
        pub fn min_w_neg_1_4(self: Self) Self {
            self.style().min_size.width = len_rel(-0.25);
            return self;
        }
        /// Sets the minimum width of the element to 50%.
        pub fn min_w_2_4(self: Self) Self {
            self.style().min_size.width = len_rel(0.5);
            return self;
        }
        /// Sets the minimum width of the element to negative 50%.
        pub fn min_w_neg_2_4(self: Self) Self {
            self.style().min_size.width = len_rel(-0.5);
            return self;
        }
        /// Sets the minimum width of the element to 75%.
        pub fn min_w_3_4(self: Self) Self {
            self.style().min_size.width = len_rel(0.75);
            return self;
        }
        /// Sets the minimum width of the element to negative 75%.
        pub fn min_w_neg_3_4(self: Self) Self {
            self.style().min_size.width = len_rel(-0.75);
            return self;
        }
        /// Sets the minimum width of the element to 20%.
        pub fn min_w_1_5(self: Self) Self {
            self.style().min_size.width = len_rel(0.2);
            return self;
        }
        /// Sets the minimum width of the element to negative 20%.
        pub fn min_w_neg_1_5(self: Self) Self {
            self.style().min_size.width = len_rel(-0.2);
            return self;
        }
        /// Sets the minimum width of the element to 40%.
        pub fn min_w_2_5(self: Self) Self {
            self.style().min_size.width = len_rel(0.4);
            return self;
        }
        /// Sets the minimum width of the element to negative 40%.
        pub fn min_w_neg_2_5(self: Self) Self {
            self.style().min_size.width = len_rel(-0.4);
            return self;
        }
        /// Sets the minimum width of the element to 60%.
        pub fn min_w_3_5(self: Self) Self {
            self.style().min_size.width = len_rel(0.6);
            return self;
        }
        /// Sets the minimum width of the element to negative 60%.
        pub fn min_w_neg_3_5(self: Self) Self {
            self.style().min_size.width = len_rel(-0.6);
            return self;
        }
        /// Sets the minimum width of the element to 80%.
        pub fn min_w_4_5(self: Self) Self {
            self.style().min_size.width = len_rel(0.8);
            return self;
        }
        /// Sets the minimum width of the element to negative 80%.
        pub fn min_w_neg_4_5(self: Self) Self {
            self.style().min_size.width = len_rel(-0.8);
            return self;
        }
        /// Sets the minimum width of the element to 16.6667%.
        pub fn min_w_1_6(self: Self) Self {
            self.style().min_size.width = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the minimum width of the element to negative 16.6667%.
        pub fn min_w_neg_1_6(self: Self) Self {
            self.style().min_size.width = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the minimum width of the element to 83.3333%.
        pub fn min_w_5_6(self: Self) Self {
            self.style().min_size.width = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the minimum width of the element to negative 83.3333%.
        pub fn min_w_neg_5_6(self: Self) Self {
            self.style().min_size.width = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the minimum width of the element to 8.33333%.
        pub fn min_w_1_12(self: Self) Self {
            self.style().min_size.width = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the minimum width of the element to negative 8.33333%.
        pub fn min_w_neg_1_12(self: Self) Self {
            self.style().min_size.width = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the minimum height of the element.
        pub fn min_h(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.min_size.height = v;
            return self;
        }
        /// Sets the minimum height of the element to 0px.
        pub fn min_h_0(self: Self) Self {
            self.style().min_size.height = len_px(0.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 0px.
        pub fn min_h_neg_0(self: Self) Self {
            self.style().min_size.height = len_px(-0.0);
            return self;
        }
        /// Sets the minimum height of the element to 2px (0.125rem).
        pub fn min_h_0p5(self: Self) Self {
            self.style().min_size.height = len_rem(0.125);
            return self;
        }
        /// Sets the minimum height of the element to negative 2px (0.125rem).
        pub fn min_h_neg_0p5(self: Self) Self {
            self.style().min_size.height = len_rem(-0.125);
            return self;
        }
        /// Sets the minimum height of the element to 4px (0.25rem).
        pub fn min_h_1(self: Self) Self {
            self.style().min_size.height = len_rem(0.25);
            return self;
        }
        /// Sets the minimum height of the element to negative 4px (0.25rem).
        pub fn min_h_neg_1(self: Self) Self {
            self.style().min_size.height = len_rem(-0.25);
            return self;
        }
        /// Sets the minimum height of the element to 6px (0.375rem).
        pub fn min_h_1p5(self: Self) Self {
            self.style().min_size.height = len_rem(0.375);
            return self;
        }
        /// Sets the minimum height of the element to negative 6px (0.375rem).
        pub fn min_h_neg_1p5(self: Self) Self {
            self.style().min_size.height = len_rem(-0.375);
            return self;
        }
        /// Sets the minimum height of the element to 8px (0.5rem).
        pub fn min_h_2(self: Self) Self {
            self.style().min_size.height = len_rem(0.5);
            return self;
        }
        /// Sets the minimum height of the element to negative 8px (0.5rem).
        pub fn min_h_neg_2(self: Self) Self {
            self.style().min_size.height = len_rem(-0.5);
            return self;
        }
        /// Sets the minimum height of the element to 10px (0.625rem).
        pub fn min_h_2p5(self: Self) Self {
            self.style().min_size.height = len_rem(0.625);
            return self;
        }
        /// Sets the minimum height of the element to negative 10px (0.625rem).
        pub fn min_h_neg_2p5(self: Self) Self {
            self.style().min_size.height = len_rem(-0.625);
            return self;
        }
        /// Sets the minimum height of the element to 12px (0.75rem).
        pub fn min_h_3(self: Self) Self {
            self.style().min_size.height = len_rem(0.75);
            return self;
        }
        /// Sets the minimum height of the element to negative 12px (0.75rem).
        pub fn min_h_neg_3(self: Self) Self {
            self.style().min_size.height = len_rem(-0.75);
            return self;
        }
        /// Sets the minimum height of the element to 14px (0.875rem).
        pub fn min_h_3p5(self: Self) Self {
            self.style().min_size.height = len_rem(0.875);
            return self;
        }
        /// Sets the minimum height of the element to negative 14px (0.875rem).
        pub fn min_h_neg_3p5(self: Self) Self {
            self.style().min_size.height = len_rem(-0.875);
            return self;
        }
        /// Sets the minimum height of the element to 16px (1rem).
        pub fn min_h_4(self: Self) Self {
            self.style().min_size.height = len_rem(1.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 16px (1rem).
        pub fn min_h_neg_4(self: Self) Self {
            self.style().min_size.height = len_rem(-1.0);
            return self;
        }
        /// Sets the minimum height of the element to 20px (1.25rem).
        pub fn min_h_5(self: Self) Self {
            self.style().min_size.height = len_rem(1.25);
            return self;
        }
        /// Sets the minimum height of the element to negative 20px (1.25rem).
        pub fn min_h_neg_5(self: Self) Self {
            self.style().min_size.height = len_rem(-1.25);
            return self;
        }
        /// Sets the minimum height of the element to 24px (1.5rem).
        pub fn min_h_6(self: Self) Self {
            self.style().min_size.height = len_rem(1.5);
            return self;
        }
        /// Sets the minimum height of the element to negative 24px (1.5rem).
        pub fn min_h_neg_6(self: Self) Self {
            self.style().min_size.height = len_rem(-1.5);
            return self;
        }
        /// Sets the minimum height of the element to 28px (1.75rem).
        pub fn min_h_7(self: Self) Self {
            self.style().min_size.height = len_rem(1.75);
            return self;
        }
        /// Sets the minimum height of the element to negative 28px (1.75rem).
        pub fn min_h_neg_7(self: Self) Self {
            self.style().min_size.height = len_rem(-1.75);
            return self;
        }
        /// Sets the minimum height of the element to 32px (2rem).
        pub fn min_h_8(self: Self) Self {
            self.style().min_size.height = len_rem(2.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 32px (2rem).
        pub fn min_h_neg_8(self: Self) Self {
            self.style().min_size.height = len_rem(-2.0);
            return self;
        }
        /// Sets the minimum height of the element to 36px (2.25rem).
        pub fn min_h_9(self: Self) Self {
            self.style().min_size.height = len_rem(2.25);
            return self;
        }
        /// Sets the minimum height of the element to negative 36px (2.25rem).
        pub fn min_h_neg_9(self: Self) Self {
            self.style().min_size.height = len_rem(-2.25);
            return self;
        }
        /// Sets the minimum height of the element to 40px (2.5rem).
        pub fn min_h_10(self: Self) Self {
            self.style().min_size.height = len_rem(2.5);
            return self;
        }
        /// Sets the minimum height of the element to negative 40px (2.5rem).
        pub fn min_h_neg_10(self: Self) Self {
            self.style().min_size.height = len_rem(-2.5);
            return self;
        }
        /// Sets the minimum height of the element to 44px (2.75rem).
        pub fn min_h_11(self: Self) Self {
            self.style().min_size.height = len_rem(2.75);
            return self;
        }
        /// Sets the minimum height of the element to negative 44px (2.75rem).
        pub fn min_h_neg_11(self: Self) Self {
            self.style().min_size.height = len_rem(-2.75);
            return self;
        }
        /// Sets the minimum height of the element to 48px (3rem).
        pub fn min_h_12(self: Self) Self {
            self.style().min_size.height = len_rem(3.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 48px (3rem).
        pub fn min_h_neg_12(self: Self) Self {
            self.style().min_size.height = len_rem(-3.0);
            return self;
        }
        /// Sets the minimum height of the element to 64px (4rem).
        pub fn min_h_16(self: Self) Self {
            self.style().min_size.height = len_rem(4.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 64px (4rem).
        pub fn min_h_neg_16(self: Self) Self {
            self.style().min_size.height = len_rem(-4.0);
            return self;
        }
        /// Sets the minimum height of the element to 80px (5rem).
        pub fn min_h_20(self: Self) Self {
            self.style().min_size.height = len_rem(5.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 80px (5rem).
        pub fn min_h_neg_20(self: Self) Self {
            self.style().min_size.height = len_rem(-5.0);
            return self;
        }
        /// Sets the minimum height of the element to 96px (6rem).
        pub fn min_h_24(self: Self) Self {
            self.style().min_size.height = len_rem(6.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 96px (6rem).
        pub fn min_h_neg_24(self: Self) Self {
            self.style().min_size.height = len_rem(-6.0);
            return self;
        }
        /// Sets the minimum height of the element to 128px (8rem).
        pub fn min_h_32(self: Self) Self {
            self.style().min_size.height = len_rem(8.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 128px (8rem).
        pub fn min_h_neg_32(self: Self) Self {
            self.style().min_size.height = len_rem(-8.0);
            return self;
        }
        /// Sets the minimum height of the element to 160px (10rem).
        pub fn min_h_40(self: Self) Self {
            self.style().min_size.height = len_rem(10.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 160px (10rem).
        pub fn min_h_neg_40(self: Self) Self {
            self.style().min_size.height = len_rem(-10.0);
            return self;
        }
        /// Sets the minimum height of the element to 192px (12rem).
        pub fn min_h_48(self: Self) Self {
            self.style().min_size.height = len_rem(12.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 192px (12rem).
        pub fn min_h_neg_48(self: Self) Self {
            self.style().min_size.height = len_rem(-12.0);
            return self;
        }
        /// Sets the minimum height of the element to 224px (14rem).
        pub fn min_h_56(self: Self) Self {
            self.style().min_size.height = len_rem(14.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 224px (14rem).
        pub fn min_h_neg_56(self: Self) Self {
            self.style().min_size.height = len_rem(-14.0);
            return self;
        }
        /// Sets the minimum height of the element to 256px (16rem).
        pub fn min_h_64(self: Self) Self {
            self.style().min_size.height = len_rem(16.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 256px (16rem).
        pub fn min_h_neg_64(self: Self) Self {
            self.style().min_size.height = len_rem(-16.0);
            return self;
        }
        /// Sets the minimum height of the element to 288px (18rem).
        pub fn min_h_72(self: Self) Self {
            self.style().min_size.height = len_rem(18.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 288px (18rem).
        pub fn min_h_neg_72(self: Self) Self {
            self.style().min_size.height = len_rem(-18.0);
            return self;
        }
        /// Sets the minimum height of the element to 320px (20rem).
        pub fn min_h_80(self: Self) Self {
            self.style().min_size.height = len_rem(20.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 320px (20rem).
        pub fn min_h_neg_80(self: Self) Self {
            self.style().min_size.height = len_rem(-20.0);
            return self;
        }
        /// Sets the minimum height of the element to 384px (24rem).
        pub fn min_h_96(self: Self) Self {
            self.style().min_size.height = len_rem(24.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 384px (24rem).
        pub fn min_h_neg_96(self: Self) Self {
            self.style().min_size.height = len_rem(-24.0);
            return self;
        }
        /// Sets the minimum height of the element to 448px (28rem).
        pub fn min_h_112(self: Self) Self {
            self.style().min_size.height = len_rem(28.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 448px (28rem).
        pub fn min_h_neg_112(self: Self) Self {
            self.style().min_size.height = len_rem(-28.0);
            return self;
        }
        /// Sets the minimum height of the element to 512px (32rem).
        pub fn min_h_128(self: Self) Self {
            self.style().min_size.height = len_rem(32.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 512px (32rem).
        pub fn min_h_neg_128(self: Self) Self {
            self.style().min_size.height = len_rem(-32.0);
            return self;
        }
        /// Sets the minimum height of the element to auto.
        pub fn min_h_auto(self: Self) Self {
            self.style().min_size.height = geometry.auto();
            return self;
        }
        /// Sets the minimum height of the element to 1px.
        pub fn min_h_px(self: Self) Self {
            self.style().min_size.height = len_px(1.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 1px.
        pub fn min_h_neg_px(self: Self) Self {
            self.style().min_size.height = len_px(-1.0);
            return self;
        }
        /// Sets the minimum height of the element to 100%.
        pub fn min_h_full(self: Self) Self {
            self.style().min_size.height = len_rel(1.0);
            return self;
        }
        /// Sets the minimum height of the element to negative 100%.
        pub fn min_h_neg_full(self: Self) Self {
            self.style().min_size.height = len_rel(-1.0);
            return self;
        }
        /// Sets the minimum height of the element to 50%.
        pub fn min_h_1_2(self: Self) Self {
            self.style().min_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the minimum height of the element to negative 50%.
        pub fn min_h_neg_1_2(self: Self) Self {
            self.style().min_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the minimum height of the element to 33.3333%.
        pub fn min_h_1_3(self: Self) Self {
            self.style().min_size.height = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the minimum height of the element to negative 33.3333%.
        pub fn min_h_neg_1_3(self: Self) Self {
            self.style().min_size.height = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the minimum height of the element to 66.6667%.
        pub fn min_h_2_3(self: Self) Self {
            self.style().min_size.height = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the minimum height of the element to negative 66.6667%.
        pub fn min_h_neg_2_3(self: Self) Self {
            self.style().min_size.height = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the minimum height of the element to 25%.
        pub fn min_h_1_4(self: Self) Self {
            self.style().min_size.height = len_rel(0.25);
            return self;
        }
        /// Sets the minimum height of the element to negative 25%.
        pub fn min_h_neg_1_4(self: Self) Self {
            self.style().min_size.height = len_rel(-0.25);
            return self;
        }
        /// Sets the minimum height of the element to 50%.
        pub fn min_h_2_4(self: Self) Self {
            self.style().min_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the minimum height of the element to negative 50%.
        pub fn min_h_neg_2_4(self: Self) Self {
            self.style().min_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the minimum height of the element to 75%.
        pub fn min_h_3_4(self: Self) Self {
            self.style().min_size.height = len_rel(0.75);
            return self;
        }
        /// Sets the minimum height of the element to negative 75%.
        pub fn min_h_neg_3_4(self: Self) Self {
            self.style().min_size.height = len_rel(-0.75);
            return self;
        }
        /// Sets the minimum height of the element to 20%.
        pub fn min_h_1_5(self: Self) Self {
            self.style().min_size.height = len_rel(0.2);
            return self;
        }
        /// Sets the minimum height of the element to negative 20%.
        pub fn min_h_neg_1_5(self: Self) Self {
            self.style().min_size.height = len_rel(-0.2);
            return self;
        }
        /// Sets the minimum height of the element to 40%.
        pub fn min_h_2_5(self: Self) Self {
            self.style().min_size.height = len_rel(0.4);
            return self;
        }
        /// Sets the minimum height of the element to negative 40%.
        pub fn min_h_neg_2_5(self: Self) Self {
            self.style().min_size.height = len_rel(-0.4);
            return self;
        }
        /// Sets the minimum height of the element to 60%.
        pub fn min_h_3_5(self: Self) Self {
            self.style().min_size.height = len_rel(0.6);
            return self;
        }
        /// Sets the minimum height of the element to negative 60%.
        pub fn min_h_neg_3_5(self: Self) Self {
            self.style().min_size.height = len_rel(-0.6);
            return self;
        }
        /// Sets the minimum height of the element to 80%.
        pub fn min_h_4_5(self: Self) Self {
            self.style().min_size.height = len_rel(0.8);
            return self;
        }
        /// Sets the minimum height of the element to negative 80%.
        pub fn min_h_neg_4_5(self: Self) Self {
            self.style().min_size.height = len_rel(-0.8);
            return self;
        }
        /// Sets the minimum height of the element to 16.6667%.
        pub fn min_h_1_6(self: Self) Self {
            self.style().min_size.height = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the minimum height of the element to negative 16.6667%.
        pub fn min_h_neg_1_6(self: Self) Self {
            self.style().min_size.height = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the minimum height of the element to 83.3333%.
        pub fn min_h_5_6(self: Self) Self {
            self.style().min_size.height = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the minimum height of the element to negative 83.3333%.
        pub fn min_h_neg_5_6(self: Self) Self {
            self.style().min_size.height = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the minimum height of the element to 8.33333%.
        pub fn min_h_1_12(self: Self) Self {
            self.style().min_size.height = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the minimum height of the element to negative 8.33333%.
        pub fn min_h_neg_1_12(self: Self) Self {
            self.style().min_size.height = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the maximum width and height of the element.
        pub fn max_size(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.max_size.width = v;
            s.max_size.height = v;
            return self;
        }
        /// Sets the maximum width and height of the element to 0px.
        pub fn max_size_0(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_px(0.0);
            s.max_size.height = len_px(0.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 0px.
        pub fn max_size_neg_0(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_px(-0.0);
            s.max_size.height = len_px(-0.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 2px (0.125rem).
        pub fn max_size_0p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.125);
            s.max_size.height = len_rem(0.125);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 2px (0.125rem).
        pub fn max_size_neg_0p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.125);
            s.max_size.height = len_rem(-0.125);
            return self;
        }
        /// Sets the maximum width and height of the element to 4px (0.25rem).
        pub fn max_size_1(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.25);
            s.max_size.height = len_rem(0.25);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 4px (0.25rem).
        pub fn max_size_neg_1(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.25);
            s.max_size.height = len_rem(-0.25);
            return self;
        }
        /// Sets the maximum width and height of the element to 6px (0.375rem).
        pub fn max_size_1p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.375);
            s.max_size.height = len_rem(0.375);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 6px (0.375rem).
        pub fn max_size_neg_1p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.375);
            s.max_size.height = len_rem(-0.375);
            return self;
        }
        /// Sets the maximum width and height of the element to 8px (0.5rem).
        pub fn max_size_2(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.5);
            s.max_size.height = len_rem(0.5);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 8px (0.5rem).
        pub fn max_size_neg_2(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.5);
            s.max_size.height = len_rem(-0.5);
            return self;
        }
        /// Sets the maximum width and height of the element to 10px (0.625rem).
        pub fn max_size_2p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.625);
            s.max_size.height = len_rem(0.625);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 10px (0.625rem).
        pub fn max_size_neg_2p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.625);
            s.max_size.height = len_rem(-0.625);
            return self;
        }
        /// Sets the maximum width and height of the element to 12px (0.75rem).
        pub fn max_size_3(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.75);
            s.max_size.height = len_rem(0.75);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 12px (0.75rem).
        pub fn max_size_neg_3(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.75);
            s.max_size.height = len_rem(-0.75);
            return self;
        }
        /// Sets the maximum width and height of the element to 14px (0.875rem).
        pub fn max_size_3p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(0.875);
            s.max_size.height = len_rem(0.875);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 14px (0.875rem).
        pub fn max_size_neg_3p5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-0.875);
            s.max_size.height = len_rem(-0.875);
            return self;
        }
        /// Sets the maximum width and height of the element to 16px (1rem).
        pub fn max_size_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(1.0);
            s.max_size.height = len_rem(1.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 16px (1rem).
        pub fn max_size_neg_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-1.0);
            s.max_size.height = len_rem(-1.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 20px (1.25rem).
        pub fn max_size_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(1.25);
            s.max_size.height = len_rem(1.25);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 20px (1.25rem).
        pub fn max_size_neg_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-1.25);
            s.max_size.height = len_rem(-1.25);
            return self;
        }
        /// Sets the maximum width and height of the element to 24px (1.5rem).
        pub fn max_size_6(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(1.5);
            s.max_size.height = len_rem(1.5);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 24px (1.5rem).
        pub fn max_size_neg_6(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-1.5);
            s.max_size.height = len_rem(-1.5);
            return self;
        }
        /// Sets the maximum width and height of the element to 28px (1.75rem).
        pub fn max_size_7(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(1.75);
            s.max_size.height = len_rem(1.75);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 28px (1.75rem).
        pub fn max_size_neg_7(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-1.75);
            s.max_size.height = len_rem(-1.75);
            return self;
        }
        /// Sets the maximum width and height of the element to 32px (2rem).
        pub fn max_size_8(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(2.0);
            s.max_size.height = len_rem(2.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 32px (2rem).
        pub fn max_size_neg_8(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-2.0);
            s.max_size.height = len_rem(-2.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 36px (2.25rem).
        pub fn max_size_9(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(2.25);
            s.max_size.height = len_rem(2.25);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 36px (2.25rem).
        pub fn max_size_neg_9(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-2.25);
            s.max_size.height = len_rem(-2.25);
            return self;
        }
        /// Sets the maximum width and height of the element to 40px (2.5rem).
        pub fn max_size_10(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(2.5);
            s.max_size.height = len_rem(2.5);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 40px (2.5rem).
        pub fn max_size_neg_10(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-2.5);
            s.max_size.height = len_rem(-2.5);
            return self;
        }
        /// Sets the maximum width and height of the element to 44px (2.75rem).
        pub fn max_size_11(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(2.75);
            s.max_size.height = len_rem(2.75);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 44px (2.75rem).
        pub fn max_size_neg_11(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-2.75);
            s.max_size.height = len_rem(-2.75);
            return self;
        }
        /// Sets the maximum width and height of the element to 48px (3rem).
        pub fn max_size_12(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(3.0);
            s.max_size.height = len_rem(3.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 48px (3rem).
        pub fn max_size_neg_12(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-3.0);
            s.max_size.height = len_rem(-3.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 64px (4rem).
        pub fn max_size_16(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(4.0);
            s.max_size.height = len_rem(4.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 64px (4rem).
        pub fn max_size_neg_16(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-4.0);
            s.max_size.height = len_rem(-4.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 80px (5rem).
        pub fn max_size_20(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(5.0);
            s.max_size.height = len_rem(5.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 80px (5rem).
        pub fn max_size_neg_20(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-5.0);
            s.max_size.height = len_rem(-5.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 96px (6rem).
        pub fn max_size_24(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(6.0);
            s.max_size.height = len_rem(6.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 96px (6rem).
        pub fn max_size_neg_24(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-6.0);
            s.max_size.height = len_rem(-6.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 128px (8rem).
        pub fn max_size_32(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(8.0);
            s.max_size.height = len_rem(8.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 128px (8rem).
        pub fn max_size_neg_32(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-8.0);
            s.max_size.height = len_rem(-8.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 160px (10rem).
        pub fn max_size_40(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(10.0);
            s.max_size.height = len_rem(10.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 160px (10rem).
        pub fn max_size_neg_40(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-10.0);
            s.max_size.height = len_rem(-10.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 192px (12rem).
        pub fn max_size_48(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(12.0);
            s.max_size.height = len_rem(12.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 192px (12rem).
        pub fn max_size_neg_48(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-12.0);
            s.max_size.height = len_rem(-12.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 224px (14rem).
        pub fn max_size_56(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(14.0);
            s.max_size.height = len_rem(14.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 224px (14rem).
        pub fn max_size_neg_56(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-14.0);
            s.max_size.height = len_rem(-14.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 256px (16rem).
        pub fn max_size_64(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(16.0);
            s.max_size.height = len_rem(16.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 256px (16rem).
        pub fn max_size_neg_64(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-16.0);
            s.max_size.height = len_rem(-16.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 288px (18rem).
        pub fn max_size_72(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(18.0);
            s.max_size.height = len_rem(18.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 288px (18rem).
        pub fn max_size_neg_72(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-18.0);
            s.max_size.height = len_rem(-18.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 320px (20rem).
        pub fn max_size_80(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(20.0);
            s.max_size.height = len_rem(20.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 320px (20rem).
        pub fn max_size_neg_80(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-20.0);
            s.max_size.height = len_rem(-20.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 384px (24rem).
        pub fn max_size_96(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(24.0);
            s.max_size.height = len_rem(24.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 384px (24rem).
        pub fn max_size_neg_96(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-24.0);
            s.max_size.height = len_rem(-24.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 448px (28rem).
        pub fn max_size_112(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(28.0);
            s.max_size.height = len_rem(28.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 448px (28rem).
        pub fn max_size_neg_112(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-28.0);
            s.max_size.height = len_rem(-28.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 512px (32rem).
        pub fn max_size_128(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(32.0);
            s.max_size.height = len_rem(32.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 512px (32rem).
        pub fn max_size_neg_128(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rem(-32.0);
            s.max_size.height = len_rem(-32.0);
            return self;
        }
        /// Sets the maximum width and height of the element to auto.
        pub fn max_size_auto(self: Self) Self {
            const s = self.style();
            s.max_size.width = geometry.auto();
            s.max_size.height = geometry.auto();
            return self;
        }
        /// Sets the maximum width and height of the element to 1px.
        pub fn max_size_px(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_px(1.0);
            s.max_size.height = len_px(1.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 1px.
        pub fn max_size_neg_px(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_px(-1.0);
            s.max_size.height = len_px(-1.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 100%.
        pub fn max_size_full(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(1.0);
            s.max_size.height = len_rel(1.0);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 100%.
        pub fn max_size_neg_full(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-1.0);
            s.max_size.height = len_rel(-1.0);
            return self;
        }
        /// Sets the maximum width and height of the element to 50%.
        pub fn max_size_1_2(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.5);
            s.max_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 50%.
        pub fn max_size_neg_1_2(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.5);
            s.max_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the maximum width and height of the element to 33.3333%.
        pub fn max_size_1_3(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.3333333333333333);
            s.max_size.height = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 33.3333%.
        pub fn max_size_neg_1_3(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.3333333333333333);
            s.max_size.height = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the maximum width and height of the element to 66.6667%.
        pub fn max_size_2_3(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.6666666666666666);
            s.max_size.height = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 66.6667%.
        pub fn max_size_neg_2_3(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.6666666666666666);
            s.max_size.height = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the maximum width and height of the element to 25%.
        pub fn max_size_1_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.25);
            s.max_size.height = len_rel(0.25);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 25%.
        pub fn max_size_neg_1_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.25);
            s.max_size.height = len_rel(-0.25);
            return self;
        }
        /// Sets the maximum width and height of the element to 50%.
        pub fn max_size_2_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.5);
            s.max_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 50%.
        pub fn max_size_neg_2_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.5);
            s.max_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the maximum width and height of the element to 75%.
        pub fn max_size_3_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.75);
            s.max_size.height = len_rel(0.75);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 75%.
        pub fn max_size_neg_3_4(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.75);
            s.max_size.height = len_rel(-0.75);
            return self;
        }
        /// Sets the maximum width and height of the element to 20%.
        pub fn max_size_1_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.2);
            s.max_size.height = len_rel(0.2);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 20%.
        pub fn max_size_neg_1_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.2);
            s.max_size.height = len_rel(-0.2);
            return self;
        }
        /// Sets the maximum width and height of the element to 40%.
        pub fn max_size_2_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.4);
            s.max_size.height = len_rel(0.4);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 40%.
        pub fn max_size_neg_2_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.4);
            s.max_size.height = len_rel(-0.4);
            return self;
        }
        /// Sets the maximum width and height of the element to 60%.
        pub fn max_size_3_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.6);
            s.max_size.height = len_rel(0.6);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 60%.
        pub fn max_size_neg_3_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.6);
            s.max_size.height = len_rel(-0.6);
            return self;
        }
        /// Sets the maximum width and height of the element to 80%.
        pub fn max_size_4_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.8);
            s.max_size.height = len_rel(0.8);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 80%.
        pub fn max_size_neg_4_5(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.8);
            s.max_size.height = len_rel(-0.8);
            return self;
        }
        /// Sets the maximum width and height of the element to 16.6667%.
        pub fn max_size_1_6(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.16666666666666666);
            s.max_size.height = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 16.6667%.
        pub fn max_size_neg_1_6(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.16666666666666666);
            s.max_size.height = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the maximum width and height of the element to 83.3333%.
        pub fn max_size_5_6(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.8333333333333334);
            s.max_size.height = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 83.3333%.
        pub fn max_size_neg_5_6(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.8333333333333334);
            s.max_size.height = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the maximum width and height of the element to 8.33333%.
        pub fn max_size_1_12(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(0.08333333333333333);
            s.max_size.height = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the maximum width and height of the element to negative 8.33333%.
        pub fn max_size_neg_1_12(self: Self) Self {
            const s = self.style();
            s.max_size.width = len_rel(-0.08333333333333333);
            s.max_size.height = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the maximum width of the element.
        pub fn max_w(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.max_size.width = v;
            return self;
        }
        /// Sets the maximum width of the element to 0px.
        pub fn max_w_0(self: Self) Self {
            self.style().max_size.width = len_px(0.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 0px.
        pub fn max_w_neg_0(self: Self) Self {
            self.style().max_size.width = len_px(-0.0);
            return self;
        }
        /// Sets the maximum width of the element to 2px (0.125rem).
        pub fn max_w_0p5(self: Self) Self {
            self.style().max_size.width = len_rem(0.125);
            return self;
        }
        /// Sets the maximum width of the element to negative 2px (0.125rem).
        pub fn max_w_neg_0p5(self: Self) Self {
            self.style().max_size.width = len_rem(-0.125);
            return self;
        }
        /// Sets the maximum width of the element to 4px (0.25rem).
        pub fn max_w_1(self: Self) Self {
            self.style().max_size.width = len_rem(0.25);
            return self;
        }
        /// Sets the maximum width of the element to negative 4px (0.25rem).
        pub fn max_w_neg_1(self: Self) Self {
            self.style().max_size.width = len_rem(-0.25);
            return self;
        }
        /// Sets the maximum width of the element to 6px (0.375rem).
        pub fn max_w_1p5(self: Self) Self {
            self.style().max_size.width = len_rem(0.375);
            return self;
        }
        /// Sets the maximum width of the element to negative 6px (0.375rem).
        pub fn max_w_neg_1p5(self: Self) Self {
            self.style().max_size.width = len_rem(-0.375);
            return self;
        }
        /// Sets the maximum width of the element to 8px (0.5rem).
        pub fn max_w_2(self: Self) Self {
            self.style().max_size.width = len_rem(0.5);
            return self;
        }
        /// Sets the maximum width of the element to negative 8px (0.5rem).
        pub fn max_w_neg_2(self: Self) Self {
            self.style().max_size.width = len_rem(-0.5);
            return self;
        }
        /// Sets the maximum width of the element to 10px (0.625rem).
        pub fn max_w_2p5(self: Self) Self {
            self.style().max_size.width = len_rem(0.625);
            return self;
        }
        /// Sets the maximum width of the element to negative 10px (0.625rem).
        pub fn max_w_neg_2p5(self: Self) Self {
            self.style().max_size.width = len_rem(-0.625);
            return self;
        }
        /// Sets the maximum width of the element to 12px (0.75rem).
        pub fn max_w_3(self: Self) Self {
            self.style().max_size.width = len_rem(0.75);
            return self;
        }
        /// Sets the maximum width of the element to negative 12px (0.75rem).
        pub fn max_w_neg_3(self: Self) Self {
            self.style().max_size.width = len_rem(-0.75);
            return self;
        }
        /// Sets the maximum width of the element to 14px (0.875rem).
        pub fn max_w_3p5(self: Self) Self {
            self.style().max_size.width = len_rem(0.875);
            return self;
        }
        /// Sets the maximum width of the element to negative 14px (0.875rem).
        pub fn max_w_neg_3p5(self: Self) Self {
            self.style().max_size.width = len_rem(-0.875);
            return self;
        }
        /// Sets the maximum width of the element to 16px (1rem).
        pub fn max_w_4(self: Self) Self {
            self.style().max_size.width = len_rem(1.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 16px (1rem).
        pub fn max_w_neg_4(self: Self) Self {
            self.style().max_size.width = len_rem(-1.0);
            return self;
        }
        /// Sets the maximum width of the element to 20px (1.25rem).
        pub fn max_w_5(self: Self) Self {
            self.style().max_size.width = len_rem(1.25);
            return self;
        }
        /// Sets the maximum width of the element to negative 20px (1.25rem).
        pub fn max_w_neg_5(self: Self) Self {
            self.style().max_size.width = len_rem(-1.25);
            return self;
        }
        /// Sets the maximum width of the element to 24px (1.5rem).
        pub fn max_w_6(self: Self) Self {
            self.style().max_size.width = len_rem(1.5);
            return self;
        }
        /// Sets the maximum width of the element to negative 24px (1.5rem).
        pub fn max_w_neg_6(self: Self) Self {
            self.style().max_size.width = len_rem(-1.5);
            return self;
        }
        /// Sets the maximum width of the element to 28px (1.75rem).
        pub fn max_w_7(self: Self) Self {
            self.style().max_size.width = len_rem(1.75);
            return self;
        }
        /// Sets the maximum width of the element to negative 28px (1.75rem).
        pub fn max_w_neg_7(self: Self) Self {
            self.style().max_size.width = len_rem(-1.75);
            return self;
        }
        /// Sets the maximum width of the element to 32px (2rem).
        pub fn max_w_8(self: Self) Self {
            self.style().max_size.width = len_rem(2.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 32px (2rem).
        pub fn max_w_neg_8(self: Self) Self {
            self.style().max_size.width = len_rem(-2.0);
            return self;
        }
        /// Sets the maximum width of the element to 36px (2.25rem).
        pub fn max_w_9(self: Self) Self {
            self.style().max_size.width = len_rem(2.25);
            return self;
        }
        /// Sets the maximum width of the element to negative 36px (2.25rem).
        pub fn max_w_neg_9(self: Self) Self {
            self.style().max_size.width = len_rem(-2.25);
            return self;
        }
        /// Sets the maximum width of the element to 40px (2.5rem).
        pub fn max_w_10(self: Self) Self {
            self.style().max_size.width = len_rem(2.5);
            return self;
        }
        /// Sets the maximum width of the element to negative 40px (2.5rem).
        pub fn max_w_neg_10(self: Self) Self {
            self.style().max_size.width = len_rem(-2.5);
            return self;
        }
        /// Sets the maximum width of the element to 44px (2.75rem).
        pub fn max_w_11(self: Self) Self {
            self.style().max_size.width = len_rem(2.75);
            return self;
        }
        /// Sets the maximum width of the element to negative 44px (2.75rem).
        pub fn max_w_neg_11(self: Self) Self {
            self.style().max_size.width = len_rem(-2.75);
            return self;
        }
        /// Sets the maximum width of the element to 48px (3rem).
        pub fn max_w_12(self: Self) Self {
            self.style().max_size.width = len_rem(3.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 48px (3rem).
        pub fn max_w_neg_12(self: Self) Self {
            self.style().max_size.width = len_rem(-3.0);
            return self;
        }
        /// Sets the maximum width of the element to 64px (4rem).
        pub fn max_w_16(self: Self) Self {
            self.style().max_size.width = len_rem(4.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 64px (4rem).
        pub fn max_w_neg_16(self: Self) Self {
            self.style().max_size.width = len_rem(-4.0);
            return self;
        }
        /// Sets the maximum width of the element to 80px (5rem).
        pub fn max_w_20(self: Self) Self {
            self.style().max_size.width = len_rem(5.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 80px (5rem).
        pub fn max_w_neg_20(self: Self) Self {
            self.style().max_size.width = len_rem(-5.0);
            return self;
        }
        /// Sets the maximum width of the element to 96px (6rem).
        pub fn max_w_24(self: Self) Self {
            self.style().max_size.width = len_rem(6.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 96px (6rem).
        pub fn max_w_neg_24(self: Self) Self {
            self.style().max_size.width = len_rem(-6.0);
            return self;
        }
        /// Sets the maximum width of the element to 128px (8rem).
        pub fn max_w_32(self: Self) Self {
            self.style().max_size.width = len_rem(8.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 128px (8rem).
        pub fn max_w_neg_32(self: Self) Self {
            self.style().max_size.width = len_rem(-8.0);
            return self;
        }
        /// Sets the maximum width of the element to 160px (10rem).
        pub fn max_w_40(self: Self) Self {
            self.style().max_size.width = len_rem(10.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 160px (10rem).
        pub fn max_w_neg_40(self: Self) Self {
            self.style().max_size.width = len_rem(-10.0);
            return self;
        }
        /// Sets the maximum width of the element to 192px (12rem).
        pub fn max_w_48(self: Self) Self {
            self.style().max_size.width = len_rem(12.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 192px (12rem).
        pub fn max_w_neg_48(self: Self) Self {
            self.style().max_size.width = len_rem(-12.0);
            return self;
        }
        /// Sets the maximum width of the element to 224px (14rem).
        pub fn max_w_56(self: Self) Self {
            self.style().max_size.width = len_rem(14.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 224px (14rem).
        pub fn max_w_neg_56(self: Self) Self {
            self.style().max_size.width = len_rem(-14.0);
            return self;
        }
        /// Sets the maximum width of the element to 256px (16rem).
        pub fn max_w_64(self: Self) Self {
            self.style().max_size.width = len_rem(16.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 256px (16rem).
        pub fn max_w_neg_64(self: Self) Self {
            self.style().max_size.width = len_rem(-16.0);
            return self;
        }
        /// Sets the maximum width of the element to 288px (18rem).
        pub fn max_w_72(self: Self) Self {
            self.style().max_size.width = len_rem(18.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 288px (18rem).
        pub fn max_w_neg_72(self: Self) Self {
            self.style().max_size.width = len_rem(-18.0);
            return self;
        }
        /// Sets the maximum width of the element to 320px (20rem).
        pub fn max_w_80(self: Self) Self {
            self.style().max_size.width = len_rem(20.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 320px (20rem).
        pub fn max_w_neg_80(self: Self) Self {
            self.style().max_size.width = len_rem(-20.0);
            return self;
        }
        /// Sets the maximum width of the element to 384px (24rem).
        pub fn max_w_96(self: Self) Self {
            self.style().max_size.width = len_rem(24.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 384px (24rem).
        pub fn max_w_neg_96(self: Self) Self {
            self.style().max_size.width = len_rem(-24.0);
            return self;
        }
        /// Sets the maximum width of the element to 448px (28rem).
        pub fn max_w_112(self: Self) Self {
            self.style().max_size.width = len_rem(28.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 448px (28rem).
        pub fn max_w_neg_112(self: Self) Self {
            self.style().max_size.width = len_rem(-28.0);
            return self;
        }
        /// Sets the maximum width of the element to 512px (32rem).
        pub fn max_w_128(self: Self) Self {
            self.style().max_size.width = len_rem(32.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 512px (32rem).
        pub fn max_w_neg_128(self: Self) Self {
            self.style().max_size.width = len_rem(-32.0);
            return self;
        }
        /// Sets the maximum width of the element to auto.
        pub fn max_w_auto(self: Self) Self {
            self.style().max_size.width = geometry.auto();
            return self;
        }
        /// Sets the maximum width of the element to 1px.
        pub fn max_w_px(self: Self) Self {
            self.style().max_size.width = len_px(1.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 1px.
        pub fn max_w_neg_px(self: Self) Self {
            self.style().max_size.width = len_px(-1.0);
            return self;
        }
        /// Sets the maximum width of the element to 100%.
        pub fn max_w_full(self: Self) Self {
            self.style().max_size.width = len_rel(1.0);
            return self;
        }
        /// Sets the maximum width of the element to negative 100%.
        pub fn max_w_neg_full(self: Self) Self {
            self.style().max_size.width = len_rel(-1.0);
            return self;
        }
        /// Sets the maximum width of the element to 50%.
        pub fn max_w_1_2(self: Self) Self {
            self.style().max_size.width = len_rel(0.5);
            return self;
        }
        /// Sets the maximum width of the element to negative 50%.
        pub fn max_w_neg_1_2(self: Self) Self {
            self.style().max_size.width = len_rel(-0.5);
            return self;
        }
        /// Sets the maximum width of the element to 33.3333%.
        pub fn max_w_1_3(self: Self) Self {
            self.style().max_size.width = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the maximum width of the element to negative 33.3333%.
        pub fn max_w_neg_1_3(self: Self) Self {
            self.style().max_size.width = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the maximum width of the element to 66.6667%.
        pub fn max_w_2_3(self: Self) Self {
            self.style().max_size.width = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the maximum width of the element to negative 66.6667%.
        pub fn max_w_neg_2_3(self: Self) Self {
            self.style().max_size.width = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the maximum width of the element to 25%.
        pub fn max_w_1_4(self: Self) Self {
            self.style().max_size.width = len_rel(0.25);
            return self;
        }
        /// Sets the maximum width of the element to negative 25%.
        pub fn max_w_neg_1_4(self: Self) Self {
            self.style().max_size.width = len_rel(-0.25);
            return self;
        }
        /// Sets the maximum width of the element to 50%.
        pub fn max_w_2_4(self: Self) Self {
            self.style().max_size.width = len_rel(0.5);
            return self;
        }
        /// Sets the maximum width of the element to negative 50%.
        pub fn max_w_neg_2_4(self: Self) Self {
            self.style().max_size.width = len_rel(-0.5);
            return self;
        }
        /// Sets the maximum width of the element to 75%.
        pub fn max_w_3_4(self: Self) Self {
            self.style().max_size.width = len_rel(0.75);
            return self;
        }
        /// Sets the maximum width of the element to negative 75%.
        pub fn max_w_neg_3_4(self: Self) Self {
            self.style().max_size.width = len_rel(-0.75);
            return self;
        }
        /// Sets the maximum width of the element to 20%.
        pub fn max_w_1_5(self: Self) Self {
            self.style().max_size.width = len_rel(0.2);
            return self;
        }
        /// Sets the maximum width of the element to negative 20%.
        pub fn max_w_neg_1_5(self: Self) Self {
            self.style().max_size.width = len_rel(-0.2);
            return self;
        }
        /// Sets the maximum width of the element to 40%.
        pub fn max_w_2_5(self: Self) Self {
            self.style().max_size.width = len_rel(0.4);
            return self;
        }
        /// Sets the maximum width of the element to negative 40%.
        pub fn max_w_neg_2_5(self: Self) Self {
            self.style().max_size.width = len_rel(-0.4);
            return self;
        }
        /// Sets the maximum width of the element to 60%.
        pub fn max_w_3_5(self: Self) Self {
            self.style().max_size.width = len_rel(0.6);
            return self;
        }
        /// Sets the maximum width of the element to negative 60%.
        pub fn max_w_neg_3_5(self: Self) Self {
            self.style().max_size.width = len_rel(-0.6);
            return self;
        }
        /// Sets the maximum width of the element to 80%.
        pub fn max_w_4_5(self: Self) Self {
            self.style().max_size.width = len_rel(0.8);
            return self;
        }
        /// Sets the maximum width of the element to negative 80%.
        pub fn max_w_neg_4_5(self: Self) Self {
            self.style().max_size.width = len_rel(-0.8);
            return self;
        }
        /// Sets the maximum width of the element to 16.6667%.
        pub fn max_w_1_6(self: Self) Self {
            self.style().max_size.width = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the maximum width of the element to negative 16.6667%.
        pub fn max_w_neg_1_6(self: Self) Self {
            self.style().max_size.width = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the maximum width of the element to 83.3333%.
        pub fn max_w_5_6(self: Self) Self {
            self.style().max_size.width = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the maximum width of the element to negative 83.3333%.
        pub fn max_w_neg_5_6(self: Self) Self {
            self.style().max_size.width = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the maximum width of the element to 8.33333%.
        pub fn max_w_1_12(self: Self) Self {
            self.style().max_size.width = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the maximum width of the element to negative 8.33333%.
        pub fn max_w_neg_1_12(self: Self) Self {
            self.style().max_size.width = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the maximum height of the element.
        pub fn max_h(self: Self, length: anytype) Self {
            const v = geometry.to_length(length);
            const s = self.style();
            s.max_size.height = v;
            return self;
        }
        /// Sets the maximum height of the element to 0px.
        pub fn max_h_0(self: Self) Self {
            self.style().max_size.height = len_px(0.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 0px.
        pub fn max_h_neg_0(self: Self) Self {
            self.style().max_size.height = len_px(-0.0);
            return self;
        }
        /// Sets the maximum height of the element to 2px (0.125rem).
        pub fn max_h_0p5(self: Self) Self {
            self.style().max_size.height = len_rem(0.125);
            return self;
        }
        /// Sets the maximum height of the element to negative 2px (0.125rem).
        pub fn max_h_neg_0p5(self: Self) Self {
            self.style().max_size.height = len_rem(-0.125);
            return self;
        }
        /// Sets the maximum height of the element to 4px (0.25rem).
        pub fn max_h_1(self: Self) Self {
            self.style().max_size.height = len_rem(0.25);
            return self;
        }
        /// Sets the maximum height of the element to negative 4px (0.25rem).
        pub fn max_h_neg_1(self: Self) Self {
            self.style().max_size.height = len_rem(-0.25);
            return self;
        }
        /// Sets the maximum height of the element to 6px (0.375rem).
        pub fn max_h_1p5(self: Self) Self {
            self.style().max_size.height = len_rem(0.375);
            return self;
        }
        /// Sets the maximum height of the element to negative 6px (0.375rem).
        pub fn max_h_neg_1p5(self: Self) Self {
            self.style().max_size.height = len_rem(-0.375);
            return self;
        }
        /// Sets the maximum height of the element to 8px (0.5rem).
        pub fn max_h_2(self: Self) Self {
            self.style().max_size.height = len_rem(0.5);
            return self;
        }
        /// Sets the maximum height of the element to negative 8px (0.5rem).
        pub fn max_h_neg_2(self: Self) Self {
            self.style().max_size.height = len_rem(-0.5);
            return self;
        }
        /// Sets the maximum height of the element to 10px (0.625rem).
        pub fn max_h_2p5(self: Self) Self {
            self.style().max_size.height = len_rem(0.625);
            return self;
        }
        /// Sets the maximum height of the element to negative 10px (0.625rem).
        pub fn max_h_neg_2p5(self: Self) Self {
            self.style().max_size.height = len_rem(-0.625);
            return self;
        }
        /// Sets the maximum height of the element to 12px (0.75rem).
        pub fn max_h_3(self: Self) Self {
            self.style().max_size.height = len_rem(0.75);
            return self;
        }
        /// Sets the maximum height of the element to negative 12px (0.75rem).
        pub fn max_h_neg_3(self: Self) Self {
            self.style().max_size.height = len_rem(-0.75);
            return self;
        }
        /// Sets the maximum height of the element to 14px (0.875rem).
        pub fn max_h_3p5(self: Self) Self {
            self.style().max_size.height = len_rem(0.875);
            return self;
        }
        /// Sets the maximum height of the element to negative 14px (0.875rem).
        pub fn max_h_neg_3p5(self: Self) Self {
            self.style().max_size.height = len_rem(-0.875);
            return self;
        }
        /// Sets the maximum height of the element to 16px (1rem).
        pub fn max_h_4(self: Self) Self {
            self.style().max_size.height = len_rem(1.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 16px (1rem).
        pub fn max_h_neg_4(self: Self) Self {
            self.style().max_size.height = len_rem(-1.0);
            return self;
        }
        /// Sets the maximum height of the element to 20px (1.25rem).
        pub fn max_h_5(self: Self) Self {
            self.style().max_size.height = len_rem(1.25);
            return self;
        }
        /// Sets the maximum height of the element to negative 20px (1.25rem).
        pub fn max_h_neg_5(self: Self) Self {
            self.style().max_size.height = len_rem(-1.25);
            return self;
        }
        /// Sets the maximum height of the element to 24px (1.5rem).
        pub fn max_h_6(self: Self) Self {
            self.style().max_size.height = len_rem(1.5);
            return self;
        }
        /// Sets the maximum height of the element to negative 24px (1.5rem).
        pub fn max_h_neg_6(self: Self) Self {
            self.style().max_size.height = len_rem(-1.5);
            return self;
        }
        /// Sets the maximum height of the element to 28px (1.75rem).
        pub fn max_h_7(self: Self) Self {
            self.style().max_size.height = len_rem(1.75);
            return self;
        }
        /// Sets the maximum height of the element to negative 28px (1.75rem).
        pub fn max_h_neg_7(self: Self) Self {
            self.style().max_size.height = len_rem(-1.75);
            return self;
        }
        /// Sets the maximum height of the element to 32px (2rem).
        pub fn max_h_8(self: Self) Self {
            self.style().max_size.height = len_rem(2.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 32px (2rem).
        pub fn max_h_neg_8(self: Self) Self {
            self.style().max_size.height = len_rem(-2.0);
            return self;
        }
        /// Sets the maximum height of the element to 36px (2.25rem).
        pub fn max_h_9(self: Self) Self {
            self.style().max_size.height = len_rem(2.25);
            return self;
        }
        /// Sets the maximum height of the element to negative 36px (2.25rem).
        pub fn max_h_neg_9(self: Self) Self {
            self.style().max_size.height = len_rem(-2.25);
            return self;
        }
        /// Sets the maximum height of the element to 40px (2.5rem).
        pub fn max_h_10(self: Self) Self {
            self.style().max_size.height = len_rem(2.5);
            return self;
        }
        /// Sets the maximum height of the element to negative 40px (2.5rem).
        pub fn max_h_neg_10(self: Self) Self {
            self.style().max_size.height = len_rem(-2.5);
            return self;
        }
        /// Sets the maximum height of the element to 44px (2.75rem).
        pub fn max_h_11(self: Self) Self {
            self.style().max_size.height = len_rem(2.75);
            return self;
        }
        /// Sets the maximum height of the element to negative 44px (2.75rem).
        pub fn max_h_neg_11(self: Self) Self {
            self.style().max_size.height = len_rem(-2.75);
            return self;
        }
        /// Sets the maximum height of the element to 48px (3rem).
        pub fn max_h_12(self: Self) Self {
            self.style().max_size.height = len_rem(3.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 48px (3rem).
        pub fn max_h_neg_12(self: Self) Self {
            self.style().max_size.height = len_rem(-3.0);
            return self;
        }
        /// Sets the maximum height of the element to 64px (4rem).
        pub fn max_h_16(self: Self) Self {
            self.style().max_size.height = len_rem(4.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 64px (4rem).
        pub fn max_h_neg_16(self: Self) Self {
            self.style().max_size.height = len_rem(-4.0);
            return self;
        }
        /// Sets the maximum height of the element to 80px (5rem).
        pub fn max_h_20(self: Self) Self {
            self.style().max_size.height = len_rem(5.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 80px (5rem).
        pub fn max_h_neg_20(self: Self) Self {
            self.style().max_size.height = len_rem(-5.0);
            return self;
        }
        /// Sets the maximum height of the element to 96px (6rem).
        pub fn max_h_24(self: Self) Self {
            self.style().max_size.height = len_rem(6.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 96px (6rem).
        pub fn max_h_neg_24(self: Self) Self {
            self.style().max_size.height = len_rem(-6.0);
            return self;
        }
        /// Sets the maximum height of the element to 128px (8rem).
        pub fn max_h_32(self: Self) Self {
            self.style().max_size.height = len_rem(8.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 128px (8rem).
        pub fn max_h_neg_32(self: Self) Self {
            self.style().max_size.height = len_rem(-8.0);
            return self;
        }
        /// Sets the maximum height of the element to 160px (10rem).
        pub fn max_h_40(self: Self) Self {
            self.style().max_size.height = len_rem(10.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 160px (10rem).
        pub fn max_h_neg_40(self: Self) Self {
            self.style().max_size.height = len_rem(-10.0);
            return self;
        }
        /// Sets the maximum height of the element to 192px (12rem).
        pub fn max_h_48(self: Self) Self {
            self.style().max_size.height = len_rem(12.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 192px (12rem).
        pub fn max_h_neg_48(self: Self) Self {
            self.style().max_size.height = len_rem(-12.0);
            return self;
        }
        /// Sets the maximum height of the element to 224px (14rem).
        pub fn max_h_56(self: Self) Self {
            self.style().max_size.height = len_rem(14.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 224px (14rem).
        pub fn max_h_neg_56(self: Self) Self {
            self.style().max_size.height = len_rem(-14.0);
            return self;
        }
        /// Sets the maximum height of the element to 256px (16rem).
        pub fn max_h_64(self: Self) Self {
            self.style().max_size.height = len_rem(16.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 256px (16rem).
        pub fn max_h_neg_64(self: Self) Self {
            self.style().max_size.height = len_rem(-16.0);
            return self;
        }
        /// Sets the maximum height of the element to 288px (18rem).
        pub fn max_h_72(self: Self) Self {
            self.style().max_size.height = len_rem(18.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 288px (18rem).
        pub fn max_h_neg_72(self: Self) Self {
            self.style().max_size.height = len_rem(-18.0);
            return self;
        }
        /// Sets the maximum height of the element to 320px (20rem).
        pub fn max_h_80(self: Self) Self {
            self.style().max_size.height = len_rem(20.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 320px (20rem).
        pub fn max_h_neg_80(self: Self) Self {
            self.style().max_size.height = len_rem(-20.0);
            return self;
        }
        /// Sets the maximum height of the element to 384px (24rem).
        pub fn max_h_96(self: Self) Self {
            self.style().max_size.height = len_rem(24.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 384px (24rem).
        pub fn max_h_neg_96(self: Self) Self {
            self.style().max_size.height = len_rem(-24.0);
            return self;
        }
        /// Sets the maximum height of the element to 448px (28rem).
        pub fn max_h_112(self: Self) Self {
            self.style().max_size.height = len_rem(28.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 448px (28rem).
        pub fn max_h_neg_112(self: Self) Self {
            self.style().max_size.height = len_rem(-28.0);
            return self;
        }
        /// Sets the maximum height of the element to 512px (32rem).
        pub fn max_h_128(self: Self) Self {
            self.style().max_size.height = len_rem(32.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 512px (32rem).
        pub fn max_h_neg_128(self: Self) Self {
            self.style().max_size.height = len_rem(-32.0);
            return self;
        }
        /// Sets the maximum height of the element to auto.
        pub fn max_h_auto(self: Self) Self {
            self.style().max_size.height = geometry.auto();
            return self;
        }
        /// Sets the maximum height of the element to 1px.
        pub fn max_h_px(self: Self) Self {
            self.style().max_size.height = len_px(1.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 1px.
        pub fn max_h_neg_px(self: Self) Self {
            self.style().max_size.height = len_px(-1.0);
            return self;
        }
        /// Sets the maximum height of the element to 100%.
        pub fn max_h_full(self: Self) Self {
            self.style().max_size.height = len_rel(1.0);
            return self;
        }
        /// Sets the maximum height of the element to negative 100%.
        pub fn max_h_neg_full(self: Self) Self {
            self.style().max_size.height = len_rel(-1.0);
            return self;
        }
        /// Sets the maximum height of the element to 50%.
        pub fn max_h_1_2(self: Self) Self {
            self.style().max_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the maximum height of the element to negative 50%.
        pub fn max_h_neg_1_2(self: Self) Self {
            self.style().max_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the maximum height of the element to 33.3333%.
        pub fn max_h_1_3(self: Self) Self {
            self.style().max_size.height = len_rel(0.3333333333333333);
            return self;
        }
        /// Sets the maximum height of the element to negative 33.3333%.
        pub fn max_h_neg_1_3(self: Self) Self {
            self.style().max_size.height = len_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the maximum height of the element to 66.6667%.
        pub fn max_h_2_3(self: Self) Self {
            self.style().max_size.height = len_rel(0.6666666666666666);
            return self;
        }
        /// Sets the maximum height of the element to negative 66.6667%.
        pub fn max_h_neg_2_3(self: Self) Self {
            self.style().max_size.height = len_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the maximum height of the element to 25%.
        pub fn max_h_1_4(self: Self) Self {
            self.style().max_size.height = len_rel(0.25);
            return self;
        }
        /// Sets the maximum height of the element to negative 25%.
        pub fn max_h_neg_1_4(self: Self) Self {
            self.style().max_size.height = len_rel(-0.25);
            return self;
        }
        /// Sets the maximum height of the element to 50%.
        pub fn max_h_2_4(self: Self) Self {
            self.style().max_size.height = len_rel(0.5);
            return self;
        }
        /// Sets the maximum height of the element to negative 50%.
        pub fn max_h_neg_2_4(self: Self) Self {
            self.style().max_size.height = len_rel(-0.5);
            return self;
        }
        /// Sets the maximum height of the element to 75%.
        pub fn max_h_3_4(self: Self) Self {
            self.style().max_size.height = len_rel(0.75);
            return self;
        }
        /// Sets the maximum height of the element to negative 75%.
        pub fn max_h_neg_3_4(self: Self) Self {
            self.style().max_size.height = len_rel(-0.75);
            return self;
        }
        /// Sets the maximum height of the element to 20%.
        pub fn max_h_1_5(self: Self) Self {
            self.style().max_size.height = len_rel(0.2);
            return self;
        }
        /// Sets the maximum height of the element to negative 20%.
        pub fn max_h_neg_1_5(self: Self) Self {
            self.style().max_size.height = len_rel(-0.2);
            return self;
        }
        /// Sets the maximum height of the element to 40%.
        pub fn max_h_2_5(self: Self) Self {
            self.style().max_size.height = len_rel(0.4);
            return self;
        }
        /// Sets the maximum height of the element to negative 40%.
        pub fn max_h_neg_2_5(self: Self) Self {
            self.style().max_size.height = len_rel(-0.4);
            return self;
        }
        /// Sets the maximum height of the element to 60%.
        pub fn max_h_3_5(self: Self) Self {
            self.style().max_size.height = len_rel(0.6);
            return self;
        }
        /// Sets the maximum height of the element to negative 60%.
        pub fn max_h_neg_3_5(self: Self) Self {
            self.style().max_size.height = len_rel(-0.6);
            return self;
        }
        /// Sets the maximum height of the element to 80%.
        pub fn max_h_4_5(self: Self) Self {
            self.style().max_size.height = len_rel(0.8);
            return self;
        }
        /// Sets the maximum height of the element to negative 80%.
        pub fn max_h_neg_4_5(self: Self) Self {
            self.style().max_size.height = len_rel(-0.8);
            return self;
        }
        /// Sets the maximum height of the element to 16.6667%.
        pub fn max_h_1_6(self: Self) Self {
            self.style().max_size.height = len_rel(0.16666666666666666);
            return self;
        }
        /// Sets the maximum height of the element to negative 16.6667%.
        pub fn max_h_neg_1_6(self: Self) Self {
            self.style().max_size.height = len_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the maximum height of the element to 83.3333%.
        pub fn max_h_5_6(self: Self) Self {
            self.style().max_size.height = len_rel(0.8333333333333334);
            return self;
        }
        /// Sets the maximum height of the element to negative 83.3333%.
        pub fn max_h_neg_5_6(self: Self) Self {
            self.style().max_size.height = len_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the maximum height of the element to 8.33333%.
        pub fn max_h_1_12(self: Self) Self {
            self.style().max_size.height = len_rel(0.08333333333333333);
            return self;
        }
        /// Sets the maximum height of the element to negative 8.33333%.
        pub fn max_h_neg_1_12(self: Self) Self {
            self.style().max_size.height = len_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the gap between rows and columns of the element.
        pub fn gap(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.gap.width = v;
            s.gap.height = v;
            return self;
        }
        /// Sets the gap between rows and columns of the element to 0px.
        pub fn gap_0(self: Self) Self {
            const s = self.style();
            s.gap.width = def_px(0.0);
            s.gap.height = def_px(0.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 0px.
        pub fn gap_neg_0(self: Self) Self {
            const s = self.style();
            s.gap.width = def_px(-0.0);
            s.gap.height = def_px(-0.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 2px (0.125rem).
        pub fn gap_0p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.125);
            s.gap.height = def_rem(0.125);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 2px (0.125rem).
        pub fn gap_neg_0p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.125);
            s.gap.height = def_rem(-0.125);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 4px (0.25rem).
        pub fn gap_1(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.25);
            s.gap.height = def_rem(0.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 4px (0.25rem).
        pub fn gap_neg_1(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.25);
            s.gap.height = def_rem(-0.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 6px (0.375rem).
        pub fn gap_1p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.375);
            s.gap.height = def_rem(0.375);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 6px (0.375rem).
        pub fn gap_neg_1p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.375);
            s.gap.height = def_rem(-0.375);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 8px (0.5rem).
        pub fn gap_2(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.5);
            s.gap.height = def_rem(0.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 8px (0.5rem).
        pub fn gap_neg_2(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.5);
            s.gap.height = def_rem(-0.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 10px (0.625rem).
        pub fn gap_2p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.625);
            s.gap.height = def_rem(0.625);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 10px (0.625rem).
        pub fn gap_neg_2p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.625);
            s.gap.height = def_rem(-0.625);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 12px (0.75rem).
        pub fn gap_3(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.75);
            s.gap.height = def_rem(0.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 12px (0.75rem).
        pub fn gap_neg_3(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.75);
            s.gap.height = def_rem(-0.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 14px (0.875rem).
        pub fn gap_3p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(0.875);
            s.gap.height = def_rem(0.875);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 14px (0.875rem).
        pub fn gap_neg_3p5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-0.875);
            s.gap.height = def_rem(-0.875);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 16px (1rem).
        pub fn gap_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(1.0);
            s.gap.height = def_rem(1.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 16px (1rem).
        pub fn gap_neg_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-1.0);
            s.gap.height = def_rem(-1.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 20px (1.25rem).
        pub fn gap_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(1.25);
            s.gap.height = def_rem(1.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 20px (1.25rem).
        pub fn gap_neg_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-1.25);
            s.gap.height = def_rem(-1.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 24px (1.5rem).
        pub fn gap_6(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(1.5);
            s.gap.height = def_rem(1.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 24px (1.5rem).
        pub fn gap_neg_6(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-1.5);
            s.gap.height = def_rem(-1.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 28px (1.75rem).
        pub fn gap_7(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(1.75);
            s.gap.height = def_rem(1.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 28px (1.75rem).
        pub fn gap_neg_7(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-1.75);
            s.gap.height = def_rem(-1.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 32px (2rem).
        pub fn gap_8(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(2.0);
            s.gap.height = def_rem(2.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 32px (2rem).
        pub fn gap_neg_8(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-2.0);
            s.gap.height = def_rem(-2.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 36px (2.25rem).
        pub fn gap_9(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(2.25);
            s.gap.height = def_rem(2.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 36px (2.25rem).
        pub fn gap_neg_9(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-2.25);
            s.gap.height = def_rem(-2.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 40px (2.5rem).
        pub fn gap_10(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(2.5);
            s.gap.height = def_rem(2.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 40px (2.5rem).
        pub fn gap_neg_10(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-2.5);
            s.gap.height = def_rem(-2.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 44px (2.75rem).
        pub fn gap_11(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(2.75);
            s.gap.height = def_rem(2.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 44px (2.75rem).
        pub fn gap_neg_11(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-2.75);
            s.gap.height = def_rem(-2.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 48px (3rem).
        pub fn gap_12(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(3.0);
            s.gap.height = def_rem(3.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 48px (3rem).
        pub fn gap_neg_12(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-3.0);
            s.gap.height = def_rem(-3.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 64px (4rem).
        pub fn gap_16(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(4.0);
            s.gap.height = def_rem(4.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 64px (4rem).
        pub fn gap_neg_16(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-4.0);
            s.gap.height = def_rem(-4.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 80px (5rem).
        pub fn gap_20(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(5.0);
            s.gap.height = def_rem(5.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 80px (5rem).
        pub fn gap_neg_20(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-5.0);
            s.gap.height = def_rem(-5.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 96px (6rem).
        pub fn gap_24(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(6.0);
            s.gap.height = def_rem(6.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 96px (6rem).
        pub fn gap_neg_24(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-6.0);
            s.gap.height = def_rem(-6.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 128px (8rem).
        pub fn gap_32(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(8.0);
            s.gap.height = def_rem(8.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 128px (8rem).
        pub fn gap_neg_32(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-8.0);
            s.gap.height = def_rem(-8.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 160px (10rem).
        pub fn gap_40(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(10.0);
            s.gap.height = def_rem(10.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 160px (10rem).
        pub fn gap_neg_40(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-10.0);
            s.gap.height = def_rem(-10.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 192px (12rem).
        pub fn gap_48(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(12.0);
            s.gap.height = def_rem(12.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 192px (12rem).
        pub fn gap_neg_48(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-12.0);
            s.gap.height = def_rem(-12.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 224px (14rem).
        pub fn gap_56(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(14.0);
            s.gap.height = def_rem(14.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 224px (14rem).
        pub fn gap_neg_56(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-14.0);
            s.gap.height = def_rem(-14.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 256px (16rem).
        pub fn gap_64(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(16.0);
            s.gap.height = def_rem(16.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 256px (16rem).
        pub fn gap_neg_64(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-16.0);
            s.gap.height = def_rem(-16.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 288px (18rem).
        pub fn gap_72(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(18.0);
            s.gap.height = def_rem(18.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 288px (18rem).
        pub fn gap_neg_72(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-18.0);
            s.gap.height = def_rem(-18.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 320px (20rem).
        pub fn gap_80(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(20.0);
            s.gap.height = def_rem(20.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 320px (20rem).
        pub fn gap_neg_80(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-20.0);
            s.gap.height = def_rem(-20.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 384px (24rem).
        pub fn gap_96(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(24.0);
            s.gap.height = def_rem(24.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 384px (24rem).
        pub fn gap_neg_96(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-24.0);
            s.gap.height = def_rem(-24.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 448px (28rem).
        pub fn gap_112(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(28.0);
            s.gap.height = def_rem(28.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 448px (28rem).
        pub fn gap_neg_112(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-28.0);
            s.gap.height = def_rem(-28.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 512px (32rem).
        pub fn gap_128(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(32.0);
            s.gap.height = def_rem(32.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 512px (32rem).
        pub fn gap_neg_128(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rem(-32.0);
            s.gap.height = def_rem(-32.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 1px.
        pub fn gap_px(self: Self) Self {
            const s = self.style();
            s.gap.width = def_px(1.0);
            s.gap.height = def_px(1.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 1px.
        pub fn gap_neg_px(self: Self) Self {
            const s = self.style();
            s.gap.width = def_px(-1.0);
            s.gap.height = def_px(-1.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 100%.
        pub fn gap_full(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(1.0);
            s.gap.height = def_rel(1.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 100%.
        pub fn gap_neg_full(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-1.0);
            s.gap.height = def_rel(-1.0);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 50%.
        pub fn gap_1_2(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.5);
            s.gap.height = def_rel(0.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 50%.
        pub fn gap_neg_1_2(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.5);
            s.gap.height = def_rel(-0.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 33.3333%.
        pub fn gap_1_3(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.3333333333333333);
            s.gap.height = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 33.3333%.
        pub fn gap_neg_1_3(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.3333333333333333);
            s.gap.height = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 66.6667%.
        pub fn gap_2_3(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.6666666666666666);
            s.gap.height = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 66.6667%.
        pub fn gap_neg_2_3(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.6666666666666666);
            s.gap.height = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 25%.
        pub fn gap_1_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.25);
            s.gap.height = def_rel(0.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 25%.
        pub fn gap_neg_1_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.25);
            s.gap.height = def_rel(-0.25);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 50%.
        pub fn gap_2_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.5);
            s.gap.height = def_rel(0.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 50%.
        pub fn gap_neg_2_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.5);
            s.gap.height = def_rel(-0.5);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 75%.
        pub fn gap_3_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.75);
            s.gap.height = def_rel(0.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 75%.
        pub fn gap_neg_3_4(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.75);
            s.gap.height = def_rel(-0.75);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 20%.
        pub fn gap_1_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.2);
            s.gap.height = def_rel(0.2);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 20%.
        pub fn gap_neg_1_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.2);
            s.gap.height = def_rel(-0.2);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 40%.
        pub fn gap_2_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.4);
            s.gap.height = def_rel(0.4);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 40%.
        pub fn gap_neg_2_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.4);
            s.gap.height = def_rel(-0.4);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 60%.
        pub fn gap_3_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.6);
            s.gap.height = def_rel(0.6);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 60%.
        pub fn gap_neg_3_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.6);
            s.gap.height = def_rel(-0.6);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 80%.
        pub fn gap_4_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.8);
            s.gap.height = def_rel(0.8);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 80%.
        pub fn gap_neg_4_5(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.8);
            s.gap.height = def_rel(-0.8);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 16.6667%.
        pub fn gap_1_6(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.16666666666666666);
            s.gap.height = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 16.6667%.
        pub fn gap_neg_1_6(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.16666666666666666);
            s.gap.height = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 83.3333%.
        pub fn gap_5_6(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.8333333333333334);
            s.gap.height = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 83.3333%.
        pub fn gap_neg_5_6(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.8333333333333334);
            s.gap.height = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the gap between rows and columns of the element to 8.33333%.
        pub fn gap_1_12(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(0.08333333333333333);
            s.gap.height = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the gap between rows and columns of the element to negative 8.33333%.
        pub fn gap_neg_1_12(self: Self) Self {
            const s = self.style();
            s.gap.width = def_rel(-0.08333333333333333);
            s.gap.height = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the gap between columns of the element.
        pub fn gap_x(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.gap.width = v;
            return self;
        }
        /// Sets the gap between columns of the element to 0px.
        pub fn gap_x_0(self: Self) Self {
            self.style().gap.width = def_px(0.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 0px.
        pub fn gap_x_neg_0(self: Self) Self {
            self.style().gap.width = def_px(-0.0);
            return self;
        }
        /// Sets the gap between columns of the element to 2px (0.125rem).
        pub fn gap_x_0p5(self: Self) Self {
            self.style().gap.width = def_rem(0.125);
            return self;
        }
        /// Sets the gap between columns of the element to negative 2px (0.125rem).
        pub fn gap_x_neg_0p5(self: Self) Self {
            self.style().gap.width = def_rem(-0.125);
            return self;
        }
        /// Sets the gap between columns of the element to 4px (0.25rem).
        pub fn gap_x_1(self: Self) Self {
            self.style().gap.width = def_rem(0.25);
            return self;
        }
        /// Sets the gap between columns of the element to negative 4px (0.25rem).
        pub fn gap_x_neg_1(self: Self) Self {
            self.style().gap.width = def_rem(-0.25);
            return self;
        }
        /// Sets the gap between columns of the element to 6px (0.375rem).
        pub fn gap_x_1p5(self: Self) Self {
            self.style().gap.width = def_rem(0.375);
            return self;
        }
        /// Sets the gap between columns of the element to negative 6px (0.375rem).
        pub fn gap_x_neg_1p5(self: Self) Self {
            self.style().gap.width = def_rem(-0.375);
            return self;
        }
        /// Sets the gap between columns of the element to 8px (0.5rem).
        pub fn gap_x_2(self: Self) Self {
            self.style().gap.width = def_rem(0.5);
            return self;
        }
        /// Sets the gap between columns of the element to negative 8px (0.5rem).
        pub fn gap_x_neg_2(self: Self) Self {
            self.style().gap.width = def_rem(-0.5);
            return self;
        }
        /// Sets the gap between columns of the element to 10px (0.625rem).
        pub fn gap_x_2p5(self: Self) Self {
            self.style().gap.width = def_rem(0.625);
            return self;
        }
        /// Sets the gap between columns of the element to negative 10px (0.625rem).
        pub fn gap_x_neg_2p5(self: Self) Self {
            self.style().gap.width = def_rem(-0.625);
            return self;
        }
        /// Sets the gap between columns of the element to 12px (0.75rem).
        pub fn gap_x_3(self: Self) Self {
            self.style().gap.width = def_rem(0.75);
            return self;
        }
        /// Sets the gap between columns of the element to negative 12px (0.75rem).
        pub fn gap_x_neg_3(self: Self) Self {
            self.style().gap.width = def_rem(-0.75);
            return self;
        }
        /// Sets the gap between columns of the element to 14px (0.875rem).
        pub fn gap_x_3p5(self: Self) Self {
            self.style().gap.width = def_rem(0.875);
            return self;
        }
        /// Sets the gap between columns of the element to negative 14px (0.875rem).
        pub fn gap_x_neg_3p5(self: Self) Self {
            self.style().gap.width = def_rem(-0.875);
            return self;
        }
        /// Sets the gap between columns of the element to 16px (1rem).
        pub fn gap_x_4(self: Self) Self {
            self.style().gap.width = def_rem(1.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 16px (1rem).
        pub fn gap_x_neg_4(self: Self) Self {
            self.style().gap.width = def_rem(-1.0);
            return self;
        }
        /// Sets the gap between columns of the element to 20px (1.25rem).
        pub fn gap_x_5(self: Self) Self {
            self.style().gap.width = def_rem(1.25);
            return self;
        }
        /// Sets the gap between columns of the element to negative 20px (1.25rem).
        pub fn gap_x_neg_5(self: Self) Self {
            self.style().gap.width = def_rem(-1.25);
            return self;
        }
        /// Sets the gap between columns of the element to 24px (1.5rem).
        pub fn gap_x_6(self: Self) Self {
            self.style().gap.width = def_rem(1.5);
            return self;
        }
        /// Sets the gap between columns of the element to negative 24px (1.5rem).
        pub fn gap_x_neg_6(self: Self) Self {
            self.style().gap.width = def_rem(-1.5);
            return self;
        }
        /// Sets the gap between columns of the element to 28px (1.75rem).
        pub fn gap_x_7(self: Self) Self {
            self.style().gap.width = def_rem(1.75);
            return self;
        }
        /// Sets the gap between columns of the element to negative 28px (1.75rem).
        pub fn gap_x_neg_7(self: Self) Self {
            self.style().gap.width = def_rem(-1.75);
            return self;
        }
        /// Sets the gap between columns of the element to 32px (2rem).
        pub fn gap_x_8(self: Self) Self {
            self.style().gap.width = def_rem(2.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 32px (2rem).
        pub fn gap_x_neg_8(self: Self) Self {
            self.style().gap.width = def_rem(-2.0);
            return self;
        }
        /// Sets the gap between columns of the element to 36px (2.25rem).
        pub fn gap_x_9(self: Self) Self {
            self.style().gap.width = def_rem(2.25);
            return self;
        }
        /// Sets the gap between columns of the element to negative 36px (2.25rem).
        pub fn gap_x_neg_9(self: Self) Self {
            self.style().gap.width = def_rem(-2.25);
            return self;
        }
        /// Sets the gap between columns of the element to 40px (2.5rem).
        pub fn gap_x_10(self: Self) Self {
            self.style().gap.width = def_rem(2.5);
            return self;
        }
        /// Sets the gap between columns of the element to negative 40px (2.5rem).
        pub fn gap_x_neg_10(self: Self) Self {
            self.style().gap.width = def_rem(-2.5);
            return self;
        }
        /// Sets the gap between columns of the element to 44px (2.75rem).
        pub fn gap_x_11(self: Self) Self {
            self.style().gap.width = def_rem(2.75);
            return self;
        }
        /// Sets the gap between columns of the element to negative 44px (2.75rem).
        pub fn gap_x_neg_11(self: Self) Self {
            self.style().gap.width = def_rem(-2.75);
            return self;
        }
        /// Sets the gap between columns of the element to 48px (3rem).
        pub fn gap_x_12(self: Self) Self {
            self.style().gap.width = def_rem(3.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 48px (3rem).
        pub fn gap_x_neg_12(self: Self) Self {
            self.style().gap.width = def_rem(-3.0);
            return self;
        }
        /// Sets the gap between columns of the element to 64px (4rem).
        pub fn gap_x_16(self: Self) Self {
            self.style().gap.width = def_rem(4.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 64px (4rem).
        pub fn gap_x_neg_16(self: Self) Self {
            self.style().gap.width = def_rem(-4.0);
            return self;
        }
        /// Sets the gap between columns of the element to 80px (5rem).
        pub fn gap_x_20(self: Self) Self {
            self.style().gap.width = def_rem(5.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 80px (5rem).
        pub fn gap_x_neg_20(self: Self) Self {
            self.style().gap.width = def_rem(-5.0);
            return self;
        }
        /// Sets the gap between columns of the element to 96px (6rem).
        pub fn gap_x_24(self: Self) Self {
            self.style().gap.width = def_rem(6.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 96px (6rem).
        pub fn gap_x_neg_24(self: Self) Self {
            self.style().gap.width = def_rem(-6.0);
            return self;
        }
        /// Sets the gap between columns of the element to 128px (8rem).
        pub fn gap_x_32(self: Self) Self {
            self.style().gap.width = def_rem(8.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 128px (8rem).
        pub fn gap_x_neg_32(self: Self) Self {
            self.style().gap.width = def_rem(-8.0);
            return self;
        }
        /// Sets the gap between columns of the element to 160px (10rem).
        pub fn gap_x_40(self: Self) Self {
            self.style().gap.width = def_rem(10.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 160px (10rem).
        pub fn gap_x_neg_40(self: Self) Self {
            self.style().gap.width = def_rem(-10.0);
            return self;
        }
        /// Sets the gap between columns of the element to 192px (12rem).
        pub fn gap_x_48(self: Self) Self {
            self.style().gap.width = def_rem(12.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 192px (12rem).
        pub fn gap_x_neg_48(self: Self) Self {
            self.style().gap.width = def_rem(-12.0);
            return self;
        }
        /// Sets the gap between columns of the element to 224px (14rem).
        pub fn gap_x_56(self: Self) Self {
            self.style().gap.width = def_rem(14.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 224px (14rem).
        pub fn gap_x_neg_56(self: Self) Self {
            self.style().gap.width = def_rem(-14.0);
            return self;
        }
        /// Sets the gap between columns of the element to 256px (16rem).
        pub fn gap_x_64(self: Self) Self {
            self.style().gap.width = def_rem(16.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 256px (16rem).
        pub fn gap_x_neg_64(self: Self) Self {
            self.style().gap.width = def_rem(-16.0);
            return self;
        }
        /// Sets the gap between columns of the element to 288px (18rem).
        pub fn gap_x_72(self: Self) Self {
            self.style().gap.width = def_rem(18.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 288px (18rem).
        pub fn gap_x_neg_72(self: Self) Self {
            self.style().gap.width = def_rem(-18.0);
            return self;
        }
        /// Sets the gap between columns of the element to 320px (20rem).
        pub fn gap_x_80(self: Self) Self {
            self.style().gap.width = def_rem(20.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 320px (20rem).
        pub fn gap_x_neg_80(self: Self) Self {
            self.style().gap.width = def_rem(-20.0);
            return self;
        }
        /// Sets the gap between columns of the element to 384px (24rem).
        pub fn gap_x_96(self: Self) Self {
            self.style().gap.width = def_rem(24.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 384px (24rem).
        pub fn gap_x_neg_96(self: Self) Self {
            self.style().gap.width = def_rem(-24.0);
            return self;
        }
        /// Sets the gap between columns of the element to 448px (28rem).
        pub fn gap_x_112(self: Self) Self {
            self.style().gap.width = def_rem(28.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 448px (28rem).
        pub fn gap_x_neg_112(self: Self) Self {
            self.style().gap.width = def_rem(-28.0);
            return self;
        }
        /// Sets the gap between columns of the element to 512px (32rem).
        pub fn gap_x_128(self: Self) Self {
            self.style().gap.width = def_rem(32.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 512px (32rem).
        pub fn gap_x_neg_128(self: Self) Self {
            self.style().gap.width = def_rem(-32.0);
            return self;
        }
        /// Sets the gap between columns of the element to 1px.
        pub fn gap_x_px(self: Self) Self {
            self.style().gap.width = def_px(1.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 1px.
        pub fn gap_x_neg_px(self: Self) Self {
            self.style().gap.width = def_px(-1.0);
            return self;
        }
        /// Sets the gap between columns of the element to 100%.
        pub fn gap_x_full(self: Self) Self {
            self.style().gap.width = def_rel(1.0);
            return self;
        }
        /// Sets the gap between columns of the element to negative 100%.
        pub fn gap_x_neg_full(self: Self) Self {
            self.style().gap.width = def_rel(-1.0);
            return self;
        }
        /// Sets the gap between columns of the element to 50%.
        pub fn gap_x_1_2(self: Self) Self {
            self.style().gap.width = def_rel(0.5);
            return self;
        }
        /// Sets the gap between columns of the element to negative 50%.
        pub fn gap_x_neg_1_2(self: Self) Self {
            self.style().gap.width = def_rel(-0.5);
            return self;
        }
        /// Sets the gap between columns of the element to 33.3333%.
        pub fn gap_x_1_3(self: Self) Self {
            self.style().gap.width = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the gap between columns of the element to negative 33.3333%.
        pub fn gap_x_neg_1_3(self: Self) Self {
            self.style().gap.width = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the gap between columns of the element to 66.6667%.
        pub fn gap_x_2_3(self: Self) Self {
            self.style().gap.width = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the gap between columns of the element to negative 66.6667%.
        pub fn gap_x_neg_2_3(self: Self) Self {
            self.style().gap.width = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the gap between columns of the element to 25%.
        pub fn gap_x_1_4(self: Self) Self {
            self.style().gap.width = def_rel(0.25);
            return self;
        }
        /// Sets the gap between columns of the element to negative 25%.
        pub fn gap_x_neg_1_4(self: Self) Self {
            self.style().gap.width = def_rel(-0.25);
            return self;
        }
        /// Sets the gap between columns of the element to 50%.
        pub fn gap_x_2_4(self: Self) Self {
            self.style().gap.width = def_rel(0.5);
            return self;
        }
        /// Sets the gap between columns of the element to negative 50%.
        pub fn gap_x_neg_2_4(self: Self) Self {
            self.style().gap.width = def_rel(-0.5);
            return self;
        }
        /// Sets the gap between columns of the element to 75%.
        pub fn gap_x_3_4(self: Self) Self {
            self.style().gap.width = def_rel(0.75);
            return self;
        }
        /// Sets the gap between columns of the element to negative 75%.
        pub fn gap_x_neg_3_4(self: Self) Self {
            self.style().gap.width = def_rel(-0.75);
            return self;
        }
        /// Sets the gap between columns of the element to 20%.
        pub fn gap_x_1_5(self: Self) Self {
            self.style().gap.width = def_rel(0.2);
            return self;
        }
        /// Sets the gap between columns of the element to negative 20%.
        pub fn gap_x_neg_1_5(self: Self) Self {
            self.style().gap.width = def_rel(-0.2);
            return self;
        }
        /// Sets the gap between columns of the element to 40%.
        pub fn gap_x_2_5(self: Self) Self {
            self.style().gap.width = def_rel(0.4);
            return self;
        }
        /// Sets the gap between columns of the element to negative 40%.
        pub fn gap_x_neg_2_5(self: Self) Self {
            self.style().gap.width = def_rel(-0.4);
            return self;
        }
        /// Sets the gap between columns of the element to 60%.
        pub fn gap_x_3_5(self: Self) Self {
            self.style().gap.width = def_rel(0.6);
            return self;
        }
        /// Sets the gap between columns of the element to negative 60%.
        pub fn gap_x_neg_3_5(self: Self) Self {
            self.style().gap.width = def_rel(-0.6);
            return self;
        }
        /// Sets the gap between columns of the element to 80%.
        pub fn gap_x_4_5(self: Self) Self {
            self.style().gap.width = def_rel(0.8);
            return self;
        }
        /// Sets the gap between columns of the element to negative 80%.
        pub fn gap_x_neg_4_5(self: Self) Self {
            self.style().gap.width = def_rel(-0.8);
            return self;
        }
        /// Sets the gap between columns of the element to 16.6667%.
        pub fn gap_x_1_6(self: Self) Self {
            self.style().gap.width = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the gap between columns of the element to negative 16.6667%.
        pub fn gap_x_neg_1_6(self: Self) Self {
            self.style().gap.width = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the gap between columns of the element to 83.3333%.
        pub fn gap_x_5_6(self: Self) Self {
            self.style().gap.width = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the gap between columns of the element to negative 83.3333%.
        pub fn gap_x_neg_5_6(self: Self) Self {
            self.style().gap.width = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the gap between columns of the element to 8.33333%.
        pub fn gap_x_1_12(self: Self) Self {
            self.style().gap.width = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the gap between columns of the element to negative 8.33333%.
        pub fn gap_x_neg_1_12(self: Self) Self {
            self.style().gap.width = def_rel(-0.08333333333333333);
            return self;
        }

        /// Sets the gap between rows of the element.
        pub fn gap_y(self: Self, length: anytype) Self {
            const v = geometry.to_definite_length(length);
            const s = self.style();
            s.gap.height = v;
            return self;
        }
        /// Sets the gap between rows of the element to 0px.
        pub fn gap_y_0(self: Self) Self {
            self.style().gap.height = def_px(0.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 0px.
        pub fn gap_y_neg_0(self: Self) Self {
            self.style().gap.height = def_px(-0.0);
            return self;
        }
        /// Sets the gap between rows of the element to 2px (0.125rem).
        pub fn gap_y_0p5(self: Self) Self {
            self.style().gap.height = def_rem(0.125);
            return self;
        }
        /// Sets the gap between rows of the element to negative 2px (0.125rem).
        pub fn gap_y_neg_0p5(self: Self) Self {
            self.style().gap.height = def_rem(-0.125);
            return self;
        }
        /// Sets the gap between rows of the element to 4px (0.25rem).
        pub fn gap_y_1(self: Self) Self {
            self.style().gap.height = def_rem(0.25);
            return self;
        }
        /// Sets the gap between rows of the element to negative 4px (0.25rem).
        pub fn gap_y_neg_1(self: Self) Self {
            self.style().gap.height = def_rem(-0.25);
            return self;
        }
        /// Sets the gap between rows of the element to 6px (0.375rem).
        pub fn gap_y_1p5(self: Self) Self {
            self.style().gap.height = def_rem(0.375);
            return self;
        }
        /// Sets the gap between rows of the element to negative 6px (0.375rem).
        pub fn gap_y_neg_1p5(self: Self) Self {
            self.style().gap.height = def_rem(-0.375);
            return self;
        }
        /// Sets the gap between rows of the element to 8px (0.5rem).
        pub fn gap_y_2(self: Self) Self {
            self.style().gap.height = def_rem(0.5);
            return self;
        }
        /// Sets the gap between rows of the element to negative 8px (0.5rem).
        pub fn gap_y_neg_2(self: Self) Self {
            self.style().gap.height = def_rem(-0.5);
            return self;
        }
        /// Sets the gap between rows of the element to 10px (0.625rem).
        pub fn gap_y_2p5(self: Self) Self {
            self.style().gap.height = def_rem(0.625);
            return self;
        }
        /// Sets the gap between rows of the element to negative 10px (0.625rem).
        pub fn gap_y_neg_2p5(self: Self) Self {
            self.style().gap.height = def_rem(-0.625);
            return self;
        }
        /// Sets the gap between rows of the element to 12px (0.75rem).
        pub fn gap_y_3(self: Self) Self {
            self.style().gap.height = def_rem(0.75);
            return self;
        }
        /// Sets the gap between rows of the element to negative 12px (0.75rem).
        pub fn gap_y_neg_3(self: Self) Self {
            self.style().gap.height = def_rem(-0.75);
            return self;
        }
        /// Sets the gap between rows of the element to 14px (0.875rem).
        pub fn gap_y_3p5(self: Self) Self {
            self.style().gap.height = def_rem(0.875);
            return self;
        }
        /// Sets the gap between rows of the element to negative 14px (0.875rem).
        pub fn gap_y_neg_3p5(self: Self) Self {
            self.style().gap.height = def_rem(-0.875);
            return self;
        }
        /// Sets the gap between rows of the element to 16px (1rem).
        pub fn gap_y_4(self: Self) Self {
            self.style().gap.height = def_rem(1.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 16px (1rem).
        pub fn gap_y_neg_4(self: Self) Self {
            self.style().gap.height = def_rem(-1.0);
            return self;
        }
        /// Sets the gap between rows of the element to 20px (1.25rem).
        pub fn gap_y_5(self: Self) Self {
            self.style().gap.height = def_rem(1.25);
            return self;
        }
        /// Sets the gap between rows of the element to negative 20px (1.25rem).
        pub fn gap_y_neg_5(self: Self) Self {
            self.style().gap.height = def_rem(-1.25);
            return self;
        }
        /// Sets the gap between rows of the element to 24px (1.5rem).
        pub fn gap_y_6(self: Self) Self {
            self.style().gap.height = def_rem(1.5);
            return self;
        }
        /// Sets the gap between rows of the element to negative 24px (1.5rem).
        pub fn gap_y_neg_6(self: Self) Self {
            self.style().gap.height = def_rem(-1.5);
            return self;
        }
        /// Sets the gap between rows of the element to 28px (1.75rem).
        pub fn gap_y_7(self: Self) Self {
            self.style().gap.height = def_rem(1.75);
            return self;
        }
        /// Sets the gap between rows of the element to negative 28px (1.75rem).
        pub fn gap_y_neg_7(self: Self) Self {
            self.style().gap.height = def_rem(-1.75);
            return self;
        }
        /// Sets the gap between rows of the element to 32px (2rem).
        pub fn gap_y_8(self: Self) Self {
            self.style().gap.height = def_rem(2.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 32px (2rem).
        pub fn gap_y_neg_8(self: Self) Self {
            self.style().gap.height = def_rem(-2.0);
            return self;
        }
        /// Sets the gap between rows of the element to 36px (2.25rem).
        pub fn gap_y_9(self: Self) Self {
            self.style().gap.height = def_rem(2.25);
            return self;
        }
        /// Sets the gap between rows of the element to negative 36px (2.25rem).
        pub fn gap_y_neg_9(self: Self) Self {
            self.style().gap.height = def_rem(-2.25);
            return self;
        }
        /// Sets the gap between rows of the element to 40px (2.5rem).
        pub fn gap_y_10(self: Self) Self {
            self.style().gap.height = def_rem(2.5);
            return self;
        }
        /// Sets the gap between rows of the element to negative 40px (2.5rem).
        pub fn gap_y_neg_10(self: Self) Self {
            self.style().gap.height = def_rem(-2.5);
            return self;
        }
        /// Sets the gap between rows of the element to 44px (2.75rem).
        pub fn gap_y_11(self: Self) Self {
            self.style().gap.height = def_rem(2.75);
            return self;
        }
        /// Sets the gap between rows of the element to negative 44px (2.75rem).
        pub fn gap_y_neg_11(self: Self) Self {
            self.style().gap.height = def_rem(-2.75);
            return self;
        }
        /// Sets the gap between rows of the element to 48px (3rem).
        pub fn gap_y_12(self: Self) Self {
            self.style().gap.height = def_rem(3.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 48px (3rem).
        pub fn gap_y_neg_12(self: Self) Self {
            self.style().gap.height = def_rem(-3.0);
            return self;
        }
        /// Sets the gap between rows of the element to 64px (4rem).
        pub fn gap_y_16(self: Self) Self {
            self.style().gap.height = def_rem(4.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 64px (4rem).
        pub fn gap_y_neg_16(self: Self) Self {
            self.style().gap.height = def_rem(-4.0);
            return self;
        }
        /// Sets the gap between rows of the element to 80px (5rem).
        pub fn gap_y_20(self: Self) Self {
            self.style().gap.height = def_rem(5.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 80px (5rem).
        pub fn gap_y_neg_20(self: Self) Self {
            self.style().gap.height = def_rem(-5.0);
            return self;
        }
        /// Sets the gap between rows of the element to 96px (6rem).
        pub fn gap_y_24(self: Self) Self {
            self.style().gap.height = def_rem(6.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 96px (6rem).
        pub fn gap_y_neg_24(self: Self) Self {
            self.style().gap.height = def_rem(-6.0);
            return self;
        }
        /// Sets the gap between rows of the element to 128px (8rem).
        pub fn gap_y_32(self: Self) Self {
            self.style().gap.height = def_rem(8.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 128px (8rem).
        pub fn gap_y_neg_32(self: Self) Self {
            self.style().gap.height = def_rem(-8.0);
            return self;
        }
        /// Sets the gap between rows of the element to 160px (10rem).
        pub fn gap_y_40(self: Self) Self {
            self.style().gap.height = def_rem(10.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 160px (10rem).
        pub fn gap_y_neg_40(self: Self) Self {
            self.style().gap.height = def_rem(-10.0);
            return self;
        }
        /// Sets the gap between rows of the element to 192px (12rem).
        pub fn gap_y_48(self: Self) Self {
            self.style().gap.height = def_rem(12.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 192px (12rem).
        pub fn gap_y_neg_48(self: Self) Self {
            self.style().gap.height = def_rem(-12.0);
            return self;
        }
        /// Sets the gap between rows of the element to 224px (14rem).
        pub fn gap_y_56(self: Self) Self {
            self.style().gap.height = def_rem(14.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 224px (14rem).
        pub fn gap_y_neg_56(self: Self) Self {
            self.style().gap.height = def_rem(-14.0);
            return self;
        }
        /// Sets the gap between rows of the element to 256px (16rem).
        pub fn gap_y_64(self: Self) Self {
            self.style().gap.height = def_rem(16.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 256px (16rem).
        pub fn gap_y_neg_64(self: Self) Self {
            self.style().gap.height = def_rem(-16.0);
            return self;
        }
        /// Sets the gap between rows of the element to 288px (18rem).
        pub fn gap_y_72(self: Self) Self {
            self.style().gap.height = def_rem(18.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 288px (18rem).
        pub fn gap_y_neg_72(self: Self) Self {
            self.style().gap.height = def_rem(-18.0);
            return self;
        }
        /// Sets the gap between rows of the element to 320px (20rem).
        pub fn gap_y_80(self: Self) Self {
            self.style().gap.height = def_rem(20.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 320px (20rem).
        pub fn gap_y_neg_80(self: Self) Self {
            self.style().gap.height = def_rem(-20.0);
            return self;
        }
        /// Sets the gap between rows of the element to 384px (24rem).
        pub fn gap_y_96(self: Self) Self {
            self.style().gap.height = def_rem(24.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 384px (24rem).
        pub fn gap_y_neg_96(self: Self) Self {
            self.style().gap.height = def_rem(-24.0);
            return self;
        }
        /// Sets the gap between rows of the element to 448px (28rem).
        pub fn gap_y_112(self: Self) Self {
            self.style().gap.height = def_rem(28.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 448px (28rem).
        pub fn gap_y_neg_112(self: Self) Self {
            self.style().gap.height = def_rem(-28.0);
            return self;
        }
        /// Sets the gap between rows of the element to 512px (32rem).
        pub fn gap_y_128(self: Self) Self {
            self.style().gap.height = def_rem(32.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 512px (32rem).
        pub fn gap_y_neg_128(self: Self) Self {
            self.style().gap.height = def_rem(-32.0);
            return self;
        }
        /// Sets the gap between rows of the element to 1px.
        pub fn gap_y_px(self: Self) Self {
            self.style().gap.height = def_px(1.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 1px.
        pub fn gap_y_neg_px(self: Self) Self {
            self.style().gap.height = def_px(-1.0);
            return self;
        }
        /// Sets the gap between rows of the element to 100%.
        pub fn gap_y_full(self: Self) Self {
            self.style().gap.height = def_rel(1.0);
            return self;
        }
        /// Sets the gap between rows of the element to negative 100%.
        pub fn gap_y_neg_full(self: Self) Self {
            self.style().gap.height = def_rel(-1.0);
            return self;
        }
        /// Sets the gap between rows of the element to 50%.
        pub fn gap_y_1_2(self: Self) Self {
            self.style().gap.height = def_rel(0.5);
            return self;
        }
        /// Sets the gap between rows of the element to negative 50%.
        pub fn gap_y_neg_1_2(self: Self) Self {
            self.style().gap.height = def_rel(-0.5);
            return self;
        }
        /// Sets the gap between rows of the element to 33.3333%.
        pub fn gap_y_1_3(self: Self) Self {
            self.style().gap.height = def_rel(0.3333333333333333);
            return self;
        }
        /// Sets the gap between rows of the element to negative 33.3333%.
        pub fn gap_y_neg_1_3(self: Self) Self {
            self.style().gap.height = def_rel(-0.3333333333333333);
            return self;
        }
        /// Sets the gap between rows of the element to 66.6667%.
        pub fn gap_y_2_3(self: Self) Self {
            self.style().gap.height = def_rel(0.6666666666666666);
            return self;
        }
        /// Sets the gap between rows of the element to negative 66.6667%.
        pub fn gap_y_neg_2_3(self: Self) Self {
            self.style().gap.height = def_rel(-0.6666666666666666);
            return self;
        }
        /// Sets the gap between rows of the element to 25%.
        pub fn gap_y_1_4(self: Self) Self {
            self.style().gap.height = def_rel(0.25);
            return self;
        }
        /// Sets the gap between rows of the element to negative 25%.
        pub fn gap_y_neg_1_4(self: Self) Self {
            self.style().gap.height = def_rel(-0.25);
            return self;
        }
        /// Sets the gap between rows of the element to 50%.
        pub fn gap_y_2_4(self: Self) Self {
            self.style().gap.height = def_rel(0.5);
            return self;
        }
        /// Sets the gap between rows of the element to negative 50%.
        pub fn gap_y_neg_2_4(self: Self) Self {
            self.style().gap.height = def_rel(-0.5);
            return self;
        }
        /// Sets the gap between rows of the element to 75%.
        pub fn gap_y_3_4(self: Self) Self {
            self.style().gap.height = def_rel(0.75);
            return self;
        }
        /// Sets the gap between rows of the element to negative 75%.
        pub fn gap_y_neg_3_4(self: Self) Self {
            self.style().gap.height = def_rel(-0.75);
            return self;
        }
        /// Sets the gap between rows of the element to 20%.
        pub fn gap_y_1_5(self: Self) Self {
            self.style().gap.height = def_rel(0.2);
            return self;
        }
        /// Sets the gap between rows of the element to negative 20%.
        pub fn gap_y_neg_1_5(self: Self) Self {
            self.style().gap.height = def_rel(-0.2);
            return self;
        }
        /// Sets the gap between rows of the element to 40%.
        pub fn gap_y_2_5(self: Self) Self {
            self.style().gap.height = def_rel(0.4);
            return self;
        }
        /// Sets the gap between rows of the element to negative 40%.
        pub fn gap_y_neg_2_5(self: Self) Self {
            self.style().gap.height = def_rel(-0.4);
            return self;
        }
        /// Sets the gap between rows of the element to 60%.
        pub fn gap_y_3_5(self: Self) Self {
            self.style().gap.height = def_rel(0.6);
            return self;
        }
        /// Sets the gap between rows of the element to negative 60%.
        pub fn gap_y_neg_3_5(self: Self) Self {
            self.style().gap.height = def_rel(-0.6);
            return self;
        }
        /// Sets the gap between rows of the element to 80%.
        pub fn gap_y_4_5(self: Self) Self {
            self.style().gap.height = def_rel(0.8);
            return self;
        }
        /// Sets the gap between rows of the element to negative 80%.
        pub fn gap_y_neg_4_5(self: Self) Self {
            self.style().gap.height = def_rel(-0.8);
            return self;
        }
        /// Sets the gap between rows of the element to 16.6667%.
        pub fn gap_y_1_6(self: Self) Self {
            self.style().gap.height = def_rel(0.16666666666666666);
            return self;
        }
        /// Sets the gap between rows of the element to negative 16.6667%.
        pub fn gap_y_neg_1_6(self: Self) Self {
            self.style().gap.height = def_rel(-0.16666666666666666);
            return self;
        }
        /// Sets the gap between rows of the element to 83.3333%.
        pub fn gap_y_5_6(self: Self) Self {
            self.style().gap.height = def_rel(0.8333333333333334);
            return self;
        }
        /// Sets the gap between rows of the element to negative 83.3333%.
        pub fn gap_y_neg_5_6(self: Self) Self {
            self.style().gap.height = def_rel(-0.8333333333333334);
            return self;
        }
        /// Sets the gap between rows of the element to 8.33333%.
        pub fn gap_y_1_12(self: Self) Self {
            self.style().gap.height = def_rel(0.08333333333333333);
            return self;
        }
        /// Sets the gap between rows of the element to negative 8.33333%.
        pub fn gap_y_neg_1_12(self: Self) Self {
            self.style().gap.height = def_rel(-0.08333333333333333);
            return self;
        }
        /// Sets the border radius of the element.
        pub fn rounded(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.top_left = v;
            s.corner_radii.top_right = v;
            s.corner_radii.bottom_right = v;
            s.corner_radii.bottom_left = v;
            return self;
        }
        /// Sets the border radius of the element to 0px.
        pub fn rounded_none(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_px(0.0);
            s.corner_radii.top_right = abs_px(0.0);
            s.corner_radii.bottom_right = abs_px(0.0);
            s.corner_radii.bottom_left = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the element to 2px (0.125rem).
        pub fn rounded_xs(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.125);
            s.corner_radii.top_right = abs_rem(0.125);
            s.corner_radii.bottom_right = abs_rem(0.125);
            s.corner_radii.bottom_left = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the element to 4px (0.25rem).
        pub fn rounded_sm(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.25);
            s.corner_radii.top_right = abs_rem(0.25);
            s.corner_radii.bottom_right = abs_rem(0.25);
            s.corner_radii.bottom_left = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the element to 6px (0.375rem).
        pub fn rounded_md(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.375);
            s.corner_radii.top_right = abs_rem(0.375);
            s.corner_radii.bottom_right = abs_rem(0.375);
            s.corner_radii.bottom_left = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the element to 8px (0.5rem).
        pub fn rounded_lg(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.5);
            s.corner_radii.top_right = abs_rem(0.5);
            s.corner_radii.bottom_right = abs_rem(0.5);
            s.corner_radii.bottom_left = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the element to 12px (0.75rem).
        pub fn rounded_xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.75);
            s.corner_radii.top_right = abs_rem(0.75);
            s.corner_radii.bottom_right = abs_rem(0.75);
            s.corner_radii.bottom_left = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the element to 16px (1rem).
        pub fn rounded_2xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(1.0);
            s.corner_radii.top_right = abs_rem(1.0);
            s.corner_radii.bottom_right = abs_rem(1.0);
            s.corner_radii.bottom_left = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the element to 24px (1.5rem).
        pub fn rounded_3xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(1.5);
            s.corner_radii.top_right = abs_rem(1.5);
            s.corner_radii.bottom_right = abs_rem(1.5);
            s.corner_radii.bottom_left = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the element to 9999px.
        pub fn rounded_full(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_px(9999.0);
            s.corner_radii.top_right = abs_px(9999.0);
            s.corner_radii.bottom_right = abs_px(9999.0);
            s.corner_radii.bottom_left = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the top side of the element.
        pub fn rounded_t(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.top_left = v;
            s.corner_radii.top_right = v;
            return self;
        }
        /// Sets the border radius of the top side of the element to 0px.
        pub fn rounded_t_none(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_px(0.0);
            s.corner_radii.top_right = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the top side of the element to 2px (0.125rem).
        pub fn rounded_t_xs(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.125);
            s.corner_radii.top_right = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the top side of the element to 4px (0.25rem).
        pub fn rounded_t_sm(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.25);
            s.corner_radii.top_right = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the top side of the element to 6px (0.375rem).
        pub fn rounded_t_md(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.375);
            s.corner_radii.top_right = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the top side of the element to 8px (0.5rem).
        pub fn rounded_t_lg(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.5);
            s.corner_radii.top_right = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the top side of the element to 12px (0.75rem).
        pub fn rounded_t_xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.75);
            s.corner_radii.top_right = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the top side of the element to 16px (1rem).
        pub fn rounded_t_2xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(1.0);
            s.corner_radii.top_right = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the top side of the element to 24px (1.5rem).
        pub fn rounded_t_3xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(1.5);
            s.corner_radii.top_right = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the top side of the element to 9999px.
        pub fn rounded_t_full(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_px(9999.0);
            s.corner_radii.top_right = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the bottom side of the element.
        pub fn rounded_b(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.bottom_left = v;
            s.corner_radii.bottom_right = v;
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 0px.
        pub fn rounded_b_none(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_px(0.0);
            s.corner_radii.bottom_right = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 2px (0.125rem).
        pub fn rounded_b_xs(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(0.125);
            s.corner_radii.bottom_right = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 4px (0.25rem).
        pub fn rounded_b_sm(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(0.25);
            s.corner_radii.bottom_right = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 6px (0.375rem).
        pub fn rounded_b_md(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(0.375);
            s.corner_radii.bottom_right = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 8px (0.5rem).
        pub fn rounded_b_lg(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(0.5);
            s.corner_radii.bottom_right = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 12px (0.75rem).
        pub fn rounded_b_xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(0.75);
            s.corner_radii.bottom_right = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 16px (1rem).
        pub fn rounded_b_2xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(1.0);
            s.corner_radii.bottom_right = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 24px (1.5rem).
        pub fn rounded_b_3xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_rem(1.5);
            s.corner_radii.bottom_right = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the bottom side of the element to 9999px.
        pub fn rounded_b_full(self: Self) Self {
            const s = self.style();
            s.corner_radii.bottom_left = abs_px(9999.0);
            s.corner_radii.bottom_right = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the right side of the element.
        pub fn rounded_r(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.top_right = v;
            s.corner_radii.bottom_right = v;
            return self;
        }
        /// Sets the border radius of the right side of the element to 0px.
        pub fn rounded_r_none(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_px(0.0);
            s.corner_radii.bottom_right = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the right side of the element to 2px (0.125rem).
        pub fn rounded_r_xs(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(0.125);
            s.corner_radii.bottom_right = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the right side of the element to 4px (0.25rem).
        pub fn rounded_r_sm(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(0.25);
            s.corner_radii.bottom_right = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the right side of the element to 6px (0.375rem).
        pub fn rounded_r_md(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(0.375);
            s.corner_radii.bottom_right = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the right side of the element to 8px (0.5rem).
        pub fn rounded_r_lg(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(0.5);
            s.corner_radii.bottom_right = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the right side of the element to 12px (0.75rem).
        pub fn rounded_r_xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(0.75);
            s.corner_radii.bottom_right = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the right side of the element to 16px (1rem).
        pub fn rounded_r_2xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(1.0);
            s.corner_radii.bottom_right = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the right side of the element to 24px (1.5rem).
        pub fn rounded_r_3xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_rem(1.5);
            s.corner_radii.bottom_right = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the right side of the element to 9999px.
        pub fn rounded_r_full(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_right = abs_px(9999.0);
            s.corner_radii.bottom_right = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the left side of the element.
        pub fn rounded_l(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.top_left = v;
            s.corner_radii.bottom_left = v;
            return self;
        }
        /// Sets the border radius of the left side of the element to 0px.
        pub fn rounded_l_none(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_px(0.0);
            s.corner_radii.bottom_left = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the left side of the element to 2px (0.125rem).
        pub fn rounded_l_xs(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.125);
            s.corner_radii.bottom_left = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the left side of the element to 4px (0.25rem).
        pub fn rounded_l_sm(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.25);
            s.corner_radii.bottom_left = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the left side of the element to 6px (0.375rem).
        pub fn rounded_l_md(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.375);
            s.corner_radii.bottom_left = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the left side of the element to 8px (0.5rem).
        pub fn rounded_l_lg(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.5);
            s.corner_radii.bottom_left = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the left side of the element to 12px (0.75rem).
        pub fn rounded_l_xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(0.75);
            s.corner_radii.bottom_left = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the left side of the element to 16px (1rem).
        pub fn rounded_l_2xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(1.0);
            s.corner_radii.bottom_left = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the left side of the element to 24px (1.5rem).
        pub fn rounded_l_3xl(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_rem(1.5);
            s.corner_radii.bottom_left = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the left side of the element to 9999px.
        pub fn rounded_l_full(self: Self) Self {
            const s = self.style();
            s.corner_radii.top_left = abs_px(9999.0);
            s.corner_radii.bottom_left = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the top left corner of the element.
        pub fn rounded_tl(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.top_left = v;
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 0px.
        pub fn rounded_tl_none(self: Self) Self {
            self.style().corner_radii.top_left = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 2px (0.125rem).
        pub fn rounded_tl_xs(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 4px (0.25rem).
        pub fn rounded_tl_sm(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 6px (0.375rem).
        pub fn rounded_tl_md(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 8px (0.5rem).
        pub fn rounded_tl_lg(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 12px (0.75rem).
        pub fn rounded_tl_xl(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 16px (1rem).
        pub fn rounded_tl_2xl(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 24px (1.5rem).
        pub fn rounded_tl_3xl(self: Self) Self {
            self.style().corner_radii.top_left = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the top left corner of the element to 9999px.
        pub fn rounded_tl_full(self: Self) Self {
            self.style().corner_radii.top_left = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the top right corner of the element.
        pub fn rounded_tr(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.top_right = v;
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 0px.
        pub fn rounded_tr_none(self: Self) Self {
            self.style().corner_radii.top_right = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 2px (0.125rem).
        pub fn rounded_tr_xs(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 4px (0.25rem).
        pub fn rounded_tr_sm(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 6px (0.375rem).
        pub fn rounded_tr_md(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 8px (0.5rem).
        pub fn rounded_tr_lg(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 12px (0.75rem).
        pub fn rounded_tr_xl(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 16px (1rem).
        pub fn rounded_tr_2xl(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 24px (1.5rem).
        pub fn rounded_tr_3xl(self: Self) Self {
            self.style().corner_radii.top_right = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the top right corner of the element to 9999px.
        pub fn rounded_tr_full(self: Self) Self {
            self.style().corner_radii.top_right = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the bottom left corner of the element.
        pub fn rounded_bl(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.bottom_left = v;
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 0px.
        pub fn rounded_bl_none(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 2px (0.125rem).
        pub fn rounded_bl_xs(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 4px (0.25rem).
        pub fn rounded_bl_sm(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 6px (0.375rem).
        pub fn rounded_bl_md(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 8px (0.5rem).
        pub fn rounded_bl_lg(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 12px (0.75rem).
        pub fn rounded_bl_xl(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 16px (1rem).
        pub fn rounded_bl_2xl(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 24px (1.5rem).
        pub fn rounded_bl_3xl(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the bottom left corner of the element to 9999px.
        pub fn rounded_bl_full(self: Self) Self {
            self.style().corner_radii.bottom_left = abs_px(9999.0);
            return self;
        }

        /// Sets the border radius of the bottom right corner of the element.
        pub fn rounded_br(self: Self, length: anytype) Self {
            const v = geometry.to_absolute_length(length);
            const s = self.style();
            s.corner_radii.bottom_right = v;
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 0px.
        pub fn rounded_br_none(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_px(0.0);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 2px (0.125rem).
        pub fn rounded_br_xs(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(0.125);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 4px (0.25rem).
        pub fn rounded_br_sm(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(0.25);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 6px (0.375rem).
        pub fn rounded_br_md(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(0.375);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 8px (0.5rem).
        pub fn rounded_br_lg(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(0.5);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 12px (0.75rem).
        pub fn rounded_br_xl(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(0.75);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 16px (1rem).
        pub fn rounded_br_2xl(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(1.0);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 24px (1.5rem).
        pub fn rounded_br_3xl(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_rem(1.5);
            return self;
        }
        /// Sets the border radius of the bottom right corner of the element to 9999px.
        pub fn rounded_br_full(self: Self) Self {
            self.style().corner_radii.bottom_right = abs_px(9999.0);
            return self;
        }
        /// Sets the box shadow of the element.
        pub fn shadow(self: Self, shadows: []const style.BoxShadow) Self {
            self.style().box_shadow = shadows;
            return self;
        }

        /// Clears the box shadow of the element.
        pub fn shadow_none(self: Self) Self {
            self.style().box_shadow = &[_]style.BoxShadow{};
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_2xs(self: Self) Self {
            self.style().box_shadow = &shadow_2xs_values;
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_xs(self: Self) Self {
            self.style().box_shadow = &shadow_xs_values;
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_sm(self: Self) Self {
            self.style().box_shadow = &shadow_sm_values;
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_md(self: Self) Self {
            self.style().box_shadow = &shadow_md_values;
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_lg(self: Self) Self {
            self.style().box_shadow = &shadow_lg_values;
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_xl(self: Self) Self {
            self.style().box_shadow = &shadow_xl_values;
            return self;
        }

        /// Sets the box shadow of the element.
        pub fn shadow_2xl(self: Self) Self {
            self.style().box_shadow = &shadow_2xl_values;
            return self;
        }
    };
}

/// Compile-time check that element type `Self` (a struct, or a pointer to one) declares every
/// method of `Styled`. Emits a compile error naming the first missing method.
pub fn assert_has_all_styled_methods(comptime Self: type) void {
    const Child = switch (@typeInfo(Self)) {
        .pointer => |p| p.child,
        else => Self,
    };
    @setEvalBranchQuota(10_000_000);
    inline for (@typeInfo(Styled(Self)).@"struct".decl_names) |name| {
        if (!@hasDecl(Child, name)) {
            @compileError(@typeName(Child) ++ " is missing the Styled method `" ++ name ++ "`");
        }
    }
}

// ----------------------------------------------------------------------------------------------
// Tests

const StyleRefinement = style.StyleRefinement;

const TestEl = struct {
    s: StyleRefinement = .{},

    pub fn style(self: *TestEl) *StyleRefinement {
        return &self.s;
    }
};

const M = Styled(*TestEl);

test "display, flex and grid" {
    var el: TestEl = .{};
    _ = M.flex(&el);
    try std.testing.expectEqual(style.Display.flex, el.s.display.?);
    _ = M.flex_col(&el);
    try std.testing.expectEqual(style.FlexDirection.column, el.s.flex_direction.?);
    _ = M.grid(&el);
    _ = M.grid_cols(&el, 3);
    try std.testing.expectEqual(@as(u16, 3), el.s.grid_cols.?.repeat);
    _ = M.col_span(&el, 2);
    try std.testing.expectEqual(@as(u16, 2), el.s.grid_location.?.column.start.span);
    try std.testing.expectEqual(@as(u16, 2), el.s.grid_location.?.column.end.span);
    _ = M.justify_center(&el);
    try std.testing.expectEqual(style.AlignContent.center, el.s.justify_content.?);
    _ = M.items_center(&el);
    try std.testing.expectEqual(style.AlignItems.center, el.s.align_items.?);
}

test "flex sizing shorthands" {
    var el: TestEl = .{};
    _ = M.flex_1(&el);
    try std.testing.expectEqual(@as(f32, 1.0), el.s.flex_grow.?);
    try std.testing.expectEqual(@as(f32, 1.0), el.s.flex_shrink.?);
    try std.testing.expectEqual(@as(f32, 0.0), el.s.flex_basis.?.definite.fraction);
    _ = M.flex_none(&el);
    try std.testing.expect(el.s.flex_basis.? == .auto);
}

test "sizes and spacing" {
    var el: TestEl = .{};
    _ = M.w_full(&el);
    try std.testing.expectEqual(@as(f32, 1.0), el.s.size.width.?.definite.fraction);
    _ = M.size_8(&el);
    try std.testing.expectEqual(@as(f32, 2.0), el.s.size.width.?.definite.absolute.rems.value);
    try std.testing.expectEqual(@as(f32, 2.0), el.s.size.height.?.definite.absolute.rems.value);
    _ = M.px_4(&el);
    try std.testing.expectEqual(@as(f32, 1.0), el.s.padding.left.?.absolute.rems.value);
    try std.testing.expectEqual(@as(f32, 1.0), el.s.padding.right.?.absolute.rems.value);
    try std.testing.expect(el.s.padding.top == null);
    _ = M.mt_neg_1(&el);
    try std.testing.expectEqual(@as(f32, -0.25), el.s.margin.top.?.definite.absolute.rems.value);
    _ = M.m_auto(&el);
    try std.testing.expect(el.s.margin.left.? == .auto);
    try std.testing.expect(el.s.margin.bottom.? == .auto);
    _ = M.gap_3(&el);
    try std.testing.expectEqual(@as(f32, 0.75), el.s.gap.width.?.absolute.rems.value);
    _ = M.top_0(&el);
    try std.testing.expectEqual(@as(f32, 0.0), el.s.inset.top.?.definite.absolute.pixels);
    _ = M.inset_0(&el);
    try std.testing.expectEqual(@as(f32, 0.0), el.s.inset.left.?.definite.absolute.pixels);
    _ = M.absolute(&el);
    try std.testing.expectEqual(style.Position.absolute, el.s.position.?);
}

test "borders, corners and shadows" {
    var el: TestEl = .{};
    _ = M.border_1(&el);
    try std.testing.expectEqual(@as(f32, 1.0), el.s.border_widths.top.?.pixels);
    _ = M.border_dashed(&el);
    try std.testing.expectEqual(style.BorderStyle.dashed, el.s.border_style.?);
    _ = M.rounded_md(&el);
    try std.testing.expectEqual(@as(f32, 0.375), el.s.corner_radii.top_left.?.rems.value);
    _ = M.rounded_full(&el);
    try std.testing.expectEqual(@as(f32, 9999.0), el.s.corner_radii.bottom_right.?.pixels);
    _ = M.shadow_lg(&el);
    try std.testing.expectEqual(@as(usize, 2), el.s.box_shadow.?.len);
    _ = M.shadow_none(&el);
    try std.testing.expectEqual(@as(usize, 0), el.s.box_shadow.?.len);
}

test "text styling" {
    var el: TestEl = .{};
    _ = M.text_xl(&el);
    try std.testing.expectEqual(@as(f32, 1.25), el.s.text.font_size.?.rems.value);
    _ = M.text_color(&el, color.hsla(0.5, 0.5, 0.5, 1.0));
    try std.testing.expectEqual(@as(f32, 0.5), el.s.text.color.?.h);
    _ = M.font_weight(&el, style.FontWeight.BOLD);
    try std.testing.expectEqual(@as(f32, 700.0), el.s.text.font_weight.?.value);
    _ = M.italic(&el);
    try std.testing.expectEqual(style.FontStyle.italic, el.s.text.font_style.?);
    _ = M.text_decoration_2(&el);
    try std.testing.expectEqual(@as(f32, 2.0), el.s.text.underline.?.thickness);
    _ = M.text_decoration_wavy(&el);
    try std.testing.expect(el.s.text.underline.?.wavy);
    _ = M.line_clamp(&el, 3);
    try std.testing.expectEqual(@as(usize, 3), el.s.text.line_clamp.?);
    try std.testing.expectEqual(style.Overflow.hidden, el.s.overflow.x.?);
}

test "truncate and whitespace" {
    var el: TestEl = .{};
    _ = M.truncate(&el);
    try std.testing.expectEqual(style.Overflow.hidden, el.s.overflow.x.?);
    try std.testing.expectEqual(style.Overflow.hidden, el.s.overflow.y.?);
    try std.testing.expectEqual(style.WhiteSpace.nowrap, el.s.text.white_space.?);
    try std.testing.expect(std.meta.activeTag(el.s.text.text_overflow.?) == .truncate);
}

test "visibility, cursor, opacity and debug" {
    var el: TestEl = .{};
    _ = M.invisible(&el);
    try std.testing.expectEqual(style.Visibility.hidden, el.s.visibility.?);
    _ = M.cursor_pointer(&el);
    try std.testing.expectEqual(style.CursorStyle.pointing_hand, el.s.mouse_cursor.?);
    _ = M.opacity(&el, 0.5);
    try std.testing.expectEqual(@as(f32, 0.5), el.s.opacity.?);
    _ = M.debug(&el);
    try std.testing.expect(el.s.debug.?);
}

test "bg and font family" {
    var el: TestEl = .{};
    _ = M.bg(&el, color.hsla(0.0, 0.0, 0.0, 1.0));
    try std.testing.expect(el.s.background != null);
    _ = M.font_family(&el, "Inter");
    try std.testing.expectEqualStrings("Inter", el.s.text.font_family.?);
}

test "mixin exposes every method on the element" {
    comptime {
        try_has(M, "flex");
        try_has(M, "w_full");
        try_has(M, "shadow_2xl");
        try_has(M, "rounded_full");
    }
}

fn try_has(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) @compileError("missing " ++ name);
}
