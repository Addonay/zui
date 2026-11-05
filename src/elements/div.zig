//! Port of GPUI `elements/div.rs`: `Div`, `Interactivity`, the
//! `InteractiveElement` / `StatefulInteractiveElement` methods, and the
//! shared `StyledElement(Ext)` type used by every styled element (Div, Img,
//! Svg, ...), so the ~3000 `Styled` methods are declared once.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color_mod = @import("../color.zig");
const style_mod = @import("../style.zig");
const styled_mod = @import("../styled.zig");
const refineable = @import("../refineable.zig");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const taffy = @import("../taffy.zig");
const interactive = @import("../interactive.zig");
const key_dispatch = @import("../key_dispatch.zig");
const action_mod = @import("../action.zig");
const image_cache_mod = @import("../image_cache.zig");
const animation_mod = @import("animation.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Corners = geometry.Corners;
const Edges = geometry.Edges;
const StyleRefinement = style_mod.StyleRefinement;
const Style = style_mod.Style;
const AnyElement = element_mod.AnyElement;
const ElementId = element_mod.ElementId;
const GlobalElementId = element_mod.GlobalElementId;
const LayoutId = taffy.LayoutId;
const Hitbox = window_mod.Hitbox;
const FocusHandle = window_mod.FocusHandle;
const DispatchPhase = key_dispatch.DispatchPhase;
const Listener = app_mod.Listener;
const MouseButton = interactive.MouseButton;
const MouseDownEvent = interactive.MouseDownEvent;
const MouseUpEvent = interactive.MouseUpEvent;
const MouseMoveEvent = interactive.MouseMoveEvent;
const ScrollWheelEvent = interactive.ScrollWheelEvent;
const MouseExitEvent = interactive.MouseExitEvent;
const FileDropEvent = interactive.FileDropEvent;
const ClickEvent = interactive.ClickEvent;
const PinchEvent = interactive.PinchEvent;
const MousePressureEvent = interactive.MousePressureEvent;
const KeyDownEvent = interactive.KeyDownEvent;
const KeyUpEvent = interactive.KeyUpEvent;
const ModifiersChangedEvent = interactive.ModifiersChangedEvent;

fn arena() std.mem.Allocator {
    return window_mod.frame_arena();
}

fn oom() noreturn {
    @panic("out of memory");
}

fn List(comptime T: type) type {
    return std.ArrayList(T);
}

/// A style applied to elements of a named group (GPUI `GroupStyle`).
pub const GroupStyle = struct {
    group: []const u8,
    style: *StyleRefinement,
};

/// Converts `fn(*StyleRefinement) *StyleRefinement`-style callbacks or a
/// ready-made `*StyleRefinement` (see `style()`) into a refinement pointer.
fn to_style_refinement(f: anytype) *StyleRefinement {
    const T = @TypeOf(f);
    if (T == *StyleRefinement) return f;
    if (T == *StyleBuilder) return f.s;
    const r = arena().create(StyleRefinement) catch oom();
    r.* = .{};
    if (@typeInfo(T) == .@"fn" or (@typeInfo(T) == .pointer and @typeInfo(@typeInfo(T).pointer.child) == .@"fn")) {
        const out = f(StyleBuilder.from(r));
        return out.s;
    }
    @compileError("expected a style refinement or fn(StyleBuilder) StyleBuilder");
}

/// A standalone style builder, used for `.hover(...)`, `.active(...)` etc.
/// In GPUI these take closures `|style| style.bg(red())`; in Zig pass
/// `zui.style().bg(zui.red())`.
pub const StyleBuilder = struct {
    s: *StyleRefinement,

    pub fn from(r: *StyleRefinement) *StyleBuilder {
        const b = arena().create(StyleBuilder) catch oom();
        b.* = .{ .s = r };
        return b;
    }
    pub fn style(self: *StyleBuilder) *StyleRefinement {
        return self.s;
    }
    const BuilderM = styled_mod.Styled(*StyleBuilder);
    pub const text_style = BuilderM.text_style;
    pub const block = BuilderM.block;
    pub const flex = BuilderM.flex;
    pub const grid = BuilderM.grid;
    pub const hidden = BuilderM.hidden;
    pub const scrollbar_width = BuilderM.scrollbar_width;
    pub const whitespace_normal = BuilderM.whitespace_normal;
    pub const whitespace_nowrap = BuilderM.whitespace_nowrap;
    pub const text_ellipsis = BuilderM.text_ellipsis;
    pub const text_ellipsis_start = BuilderM.text_ellipsis_start;
    pub const text_ellipsis_middle = BuilderM.text_ellipsis_middle;
    pub const text_overflow = BuilderM.text_overflow;
    pub const text_align = BuilderM.text_align;
    pub const text_left = BuilderM.text_left;
    pub const text_center = BuilderM.text_center;
    pub const text_right = BuilderM.text_right;
    pub const truncate = BuilderM.truncate;
    pub const line_clamp = BuilderM.line_clamp;
    pub const flex_col = BuilderM.flex_col;
    pub const flex_col_reverse = BuilderM.flex_col_reverse;
    pub const flex_row = BuilderM.flex_row;
    pub const flex_row_reverse = BuilderM.flex_row_reverse;
    pub const flex_1 = BuilderM.flex_1;
    pub const flex_auto = BuilderM.flex_auto;
    pub const flex_initial = BuilderM.flex_initial;
    pub const flex_none = BuilderM.flex_none;
    pub const flex_basis = BuilderM.flex_basis;
    pub const flex_grow = BuilderM.flex_grow;
    pub const flex_grow_0 = BuilderM.flex_grow_0;
    pub const flex_grow_1 = BuilderM.flex_grow_1;
    pub const flex_shrink = BuilderM.flex_shrink;
    pub const flex_shrink_0 = BuilderM.flex_shrink_0;
    pub const flex_shrink_1 = BuilderM.flex_shrink_1;
    pub const flex_wrap = BuilderM.flex_wrap;
    pub const flex_wrap_reverse = BuilderM.flex_wrap_reverse;
    pub const flex_nowrap = BuilderM.flex_nowrap;
    pub const items_start = BuilderM.items_start;
    pub const items_end = BuilderM.items_end;
    pub const items_center = BuilderM.items_center;
    pub const items_baseline = BuilderM.items_baseline;
    pub const items_stretch = BuilderM.items_stretch;
    pub const self_start = BuilderM.self_start;
    pub const self_end = BuilderM.self_end;
    pub const self_flex_start = BuilderM.self_flex_start;
    pub const self_flex_end = BuilderM.self_flex_end;
    pub const self_center = BuilderM.self_center;
    pub const self_baseline = BuilderM.self_baseline;
    pub const self_stretch = BuilderM.self_stretch;
    pub const justify_start = BuilderM.justify_start;
    pub const justify_end = BuilderM.justify_end;
    pub const justify_center = BuilderM.justify_center;
    pub const justify_between = BuilderM.justify_between;
    pub const justify_around = BuilderM.justify_around;
    pub const justify_evenly = BuilderM.justify_evenly;
    pub const content_normal = BuilderM.content_normal;
    pub const content_center = BuilderM.content_center;
    pub const content_start = BuilderM.content_start;
    pub const content_end = BuilderM.content_end;
    pub const content_between = BuilderM.content_between;
    pub const content_around = BuilderM.content_around;
    pub const content_evenly = BuilderM.content_evenly;
    pub const content_stretch = BuilderM.content_stretch;
    pub const aspect_ratio = BuilderM.aspect_ratio;
    pub const aspect_square = BuilderM.aspect_square;
    pub const bg = BuilderM.bg;
    pub const border_dashed = BuilderM.border_dashed;
    pub const border_color = BuilderM.border_color;
    pub const text_color = BuilderM.text_color;
    pub const font_weight = BuilderM.font_weight;
    pub const text_bg = BuilderM.text_bg;
    pub const text_size = BuilderM.text_size;
    pub const text_xs = BuilderM.text_xs;
    pub const text_sm = BuilderM.text_sm;
    pub const text_base = BuilderM.text_base;
    pub const text_lg = BuilderM.text_lg;
    pub const text_xl = BuilderM.text_xl;
    pub const text_2xl = BuilderM.text_2xl;
    pub const text_3xl = BuilderM.text_3xl;
    pub const italic = BuilderM.italic;
    pub const not_italic = BuilderM.not_italic;
    pub const underline = BuilderM.underline;
    pub const line_through = BuilderM.line_through;
    pub const text_decoration_none = BuilderM.text_decoration_none;
    pub const text_decoration_color = BuilderM.text_decoration_color;
    pub const text_decoration_solid = BuilderM.text_decoration_solid;
    pub const text_decoration_wavy = BuilderM.text_decoration_wavy;
    pub const text_decoration_0 = BuilderM.text_decoration_0;
    pub const text_decoration_1 = BuilderM.text_decoration_1;
    pub const text_decoration_2 = BuilderM.text_decoration_2;
    pub const text_decoration_4 = BuilderM.text_decoration_4;
    pub const text_decoration_8 = BuilderM.text_decoration_8;
    pub const font_family = BuilderM.font_family;
    pub const font_features = BuilderM.font_features;
    pub const font = BuilderM.font;
    pub const line_height = BuilderM.line_height;
    pub const opacity = BuilderM.opacity;
    pub const grid_cols = BuilderM.grid_cols;
    pub const grid_cols_min_content = BuilderM.grid_cols_min_content;
    pub const grid_cols_max_content = BuilderM.grid_cols_max_content;
    pub const grid_rows = BuilderM.grid_rows;
    pub const grid_rows_min_content = BuilderM.grid_rows_min_content;
    pub const grid_rows_max_content = BuilderM.grid_rows_max_content;
    pub const col_start = BuilderM.col_start;
    pub const col_start_auto = BuilderM.col_start_auto;
    pub const col_end = BuilderM.col_end;
    pub const col_end_auto = BuilderM.col_end_auto;
    pub const col_span = BuilderM.col_span;
    pub const col_span_full = BuilderM.col_span_full;
    pub const row_start = BuilderM.row_start;
    pub const row_start_auto = BuilderM.row_start_auto;
    pub const row_end = BuilderM.row_end;
    pub const row_end_auto = BuilderM.row_end_auto;
    pub const row_span = BuilderM.row_span;
    pub const row_span_full = BuilderM.row_span_full;
    pub const debug = BuilderM.debug;
    pub const debug_below = BuilderM.debug_below;
    pub const visible = BuilderM.visible;
    pub const invisible = BuilderM.invisible;
    pub const relative = BuilderM.relative;
    pub const absolute = BuilderM.absolute;
    pub const overflow_hidden = BuilderM.overflow_hidden;
    pub const overflow_scroll = BuilderM.overflow_scroll;
    pub const overflow_x_scroll = BuilderM.overflow_x_scroll;
    pub const overflow_y_scroll = BuilderM.overflow_y_scroll;
    pub const overflow_x_hidden = BuilderM.overflow_x_hidden;
    pub const overflow_y_hidden = BuilderM.overflow_y_hidden;
    pub const cursor = BuilderM.cursor;
    pub const cursor_default = BuilderM.cursor_default;
    pub const cursor_pointer = BuilderM.cursor_pointer;
    pub const cursor_text = BuilderM.cursor_text;
    pub const cursor_move = BuilderM.cursor_move;
    pub const cursor_not_allowed = BuilderM.cursor_not_allowed;
    pub const cursor_context_menu = BuilderM.cursor_context_menu;
    pub const cursor_crosshair = BuilderM.cursor_crosshair;
    pub const cursor_vertical_text = BuilderM.cursor_vertical_text;
    pub const cursor_alias = BuilderM.cursor_alias;
    pub const cursor_copy = BuilderM.cursor_copy;
    pub const cursor_no_drop = BuilderM.cursor_no_drop;
    pub const cursor_grab = BuilderM.cursor_grab;
    pub const cursor_grabbing = BuilderM.cursor_grabbing;
    pub const cursor_ew_resize = BuilderM.cursor_ew_resize;
    pub const cursor_ns_resize = BuilderM.cursor_ns_resize;
    pub const cursor_nesw_resize = BuilderM.cursor_nesw_resize;
    pub const cursor_nwse_resize = BuilderM.cursor_nwse_resize;
    pub const cursor_col_resize = BuilderM.cursor_col_resize;
    pub const cursor_row_resize = BuilderM.cursor_row_resize;
    pub const cursor_n_resize = BuilderM.cursor_n_resize;
    pub const cursor_e_resize = BuilderM.cursor_e_resize;
    pub const cursor_s_resize = BuilderM.cursor_s_resize;
    pub const cursor_w_resize = BuilderM.cursor_w_resize;
    pub const border = BuilderM.border;
    pub const border_0 = BuilderM.border_0;
    pub const border_1 = BuilderM.border_1;
    pub const border_2 = BuilderM.border_2;
    pub const border_3 = BuilderM.border_3;
    pub const border_4 = BuilderM.border_4;
    pub const border_5 = BuilderM.border_5;
    pub const border_6 = BuilderM.border_6;
    pub const border_7 = BuilderM.border_7;
    pub const border_8 = BuilderM.border_8;
    pub const border_9 = BuilderM.border_9;
    pub const border_10 = BuilderM.border_10;
    pub const border_11 = BuilderM.border_11;
    pub const border_12 = BuilderM.border_12;
    pub const border_16 = BuilderM.border_16;
    pub const border_20 = BuilderM.border_20;
    pub const border_24 = BuilderM.border_24;
    pub const border_32 = BuilderM.border_32;
    pub const border_t = BuilderM.border_t;
    pub const border_t_0 = BuilderM.border_t_0;
    pub const border_t_1 = BuilderM.border_t_1;
    pub const border_t_2 = BuilderM.border_t_2;
    pub const border_t_3 = BuilderM.border_t_3;
    pub const border_t_4 = BuilderM.border_t_4;
    pub const border_t_5 = BuilderM.border_t_5;
    pub const border_t_6 = BuilderM.border_t_6;
    pub const border_t_7 = BuilderM.border_t_7;
    pub const border_t_8 = BuilderM.border_t_8;
    pub const border_t_9 = BuilderM.border_t_9;
    pub const border_t_10 = BuilderM.border_t_10;
    pub const border_t_11 = BuilderM.border_t_11;
    pub const border_t_12 = BuilderM.border_t_12;
    pub const border_t_16 = BuilderM.border_t_16;
    pub const border_t_20 = BuilderM.border_t_20;
    pub const border_t_24 = BuilderM.border_t_24;
    pub const border_t_32 = BuilderM.border_t_32;
    pub const border_b = BuilderM.border_b;
    pub const border_b_0 = BuilderM.border_b_0;
    pub const border_b_1 = BuilderM.border_b_1;
    pub const border_b_2 = BuilderM.border_b_2;
    pub const border_b_3 = BuilderM.border_b_3;
    pub const border_b_4 = BuilderM.border_b_4;
    pub const border_b_5 = BuilderM.border_b_5;
    pub const border_b_6 = BuilderM.border_b_6;
    pub const border_b_7 = BuilderM.border_b_7;
    pub const border_b_8 = BuilderM.border_b_8;
    pub const border_b_9 = BuilderM.border_b_9;
    pub const border_b_10 = BuilderM.border_b_10;
    pub const border_b_11 = BuilderM.border_b_11;
    pub const border_b_12 = BuilderM.border_b_12;
    pub const border_b_16 = BuilderM.border_b_16;
    pub const border_b_20 = BuilderM.border_b_20;
    pub const border_b_24 = BuilderM.border_b_24;
    pub const border_b_32 = BuilderM.border_b_32;
    pub const border_r = BuilderM.border_r;
    pub const border_r_0 = BuilderM.border_r_0;
    pub const border_r_1 = BuilderM.border_r_1;
    pub const border_r_2 = BuilderM.border_r_2;
    pub const border_r_3 = BuilderM.border_r_3;
    pub const border_r_4 = BuilderM.border_r_4;
    pub const border_r_5 = BuilderM.border_r_5;
    pub const border_r_6 = BuilderM.border_r_6;
    pub const border_r_7 = BuilderM.border_r_7;
    pub const border_r_8 = BuilderM.border_r_8;
    pub const border_r_9 = BuilderM.border_r_9;
    pub const border_r_10 = BuilderM.border_r_10;
    pub const border_r_11 = BuilderM.border_r_11;
    pub const border_r_12 = BuilderM.border_r_12;
    pub const border_r_16 = BuilderM.border_r_16;
    pub const border_r_20 = BuilderM.border_r_20;
    pub const border_r_24 = BuilderM.border_r_24;
    pub const border_r_32 = BuilderM.border_r_32;
    pub const border_l = BuilderM.border_l;
    pub const border_l_0 = BuilderM.border_l_0;
    pub const border_l_1 = BuilderM.border_l_1;
    pub const border_l_2 = BuilderM.border_l_2;
    pub const border_l_3 = BuilderM.border_l_3;
    pub const border_l_4 = BuilderM.border_l_4;
    pub const border_l_5 = BuilderM.border_l_5;
    pub const border_l_6 = BuilderM.border_l_6;
    pub const border_l_7 = BuilderM.border_l_7;
    pub const border_l_8 = BuilderM.border_l_8;
    pub const border_l_9 = BuilderM.border_l_9;
    pub const border_l_10 = BuilderM.border_l_10;
    pub const border_l_11 = BuilderM.border_l_11;
    pub const border_l_12 = BuilderM.border_l_12;
    pub const border_l_16 = BuilderM.border_l_16;
    pub const border_l_20 = BuilderM.border_l_20;
    pub const border_l_24 = BuilderM.border_l_24;
    pub const border_l_32 = BuilderM.border_l_32;
    pub const border_x = BuilderM.border_x;
    pub const border_x_0 = BuilderM.border_x_0;
    pub const border_x_1 = BuilderM.border_x_1;
    pub const border_x_2 = BuilderM.border_x_2;
    pub const border_x_3 = BuilderM.border_x_3;
    pub const border_x_4 = BuilderM.border_x_4;
    pub const border_x_5 = BuilderM.border_x_5;
    pub const border_x_6 = BuilderM.border_x_6;
    pub const border_x_7 = BuilderM.border_x_7;
    pub const border_x_8 = BuilderM.border_x_8;
    pub const border_x_9 = BuilderM.border_x_9;
    pub const border_x_10 = BuilderM.border_x_10;
    pub const border_x_11 = BuilderM.border_x_11;
    pub const border_x_12 = BuilderM.border_x_12;
    pub const border_x_16 = BuilderM.border_x_16;
    pub const border_x_20 = BuilderM.border_x_20;
    pub const border_x_24 = BuilderM.border_x_24;
    pub const border_x_32 = BuilderM.border_x_32;
    pub const border_y = BuilderM.border_y;
    pub const border_y_0 = BuilderM.border_y_0;
    pub const border_y_1 = BuilderM.border_y_1;
    pub const border_y_2 = BuilderM.border_y_2;
    pub const border_y_3 = BuilderM.border_y_3;
    pub const border_y_4 = BuilderM.border_y_4;
    pub const border_y_5 = BuilderM.border_y_5;
    pub const border_y_6 = BuilderM.border_y_6;
    pub const border_y_7 = BuilderM.border_y_7;
    pub const border_y_8 = BuilderM.border_y_8;
    pub const border_y_9 = BuilderM.border_y_9;
    pub const border_y_10 = BuilderM.border_y_10;
    pub const border_y_11 = BuilderM.border_y_11;
    pub const border_y_12 = BuilderM.border_y_12;
    pub const border_y_16 = BuilderM.border_y_16;
    pub const border_y_20 = BuilderM.border_y_20;
    pub const border_y_24 = BuilderM.border_y_24;
    pub const border_y_32 = BuilderM.border_y_32;
    pub const m = BuilderM.m;
    pub const m_0 = BuilderM.m_0;
    pub const m_neg_0 = BuilderM.m_neg_0;
    pub const m_0p5 = BuilderM.m_0p5;
    pub const m_neg_0p5 = BuilderM.m_neg_0p5;
    pub const m_1 = BuilderM.m_1;
    pub const m_neg_1 = BuilderM.m_neg_1;
    pub const m_1p5 = BuilderM.m_1p5;
    pub const m_neg_1p5 = BuilderM.m_neg_1p5;
    pub const m_2 = BuilderM.m_2;
    pub const m_neg_2 = BuilderM.m_neg_2;
    pub const m_2p5 = BuilderM.m_2p5;
    pub const m_neg_2p5 = BuilderM.m_neg_2p5;
    pub const m_3 = BuilderM.m_3;
    pub const m_neg_3 = BuilderM.m_neg_3;
    pub const m_3p5 = BuilderM.m_3p5;
    pub const m_neg_3p5 = BuilderM.m_neg_3p5;
    pub const m_4 = BuilderM.m_4;
    pub const m_neg_4 = BuilderM.m_neg_4;
    pub const m_5 = BuilderM.m_5;
    pub const m_neg_5 = BuilderM.m_neg_5;
    pub const m_6 = BuilderM.m_6;
    pub const m_neg_6 = BuilderM.m_neg_6;
    pub const m_7 = BuilderM.m_7;
    pub const m_neg_7 = BuilderM.m_neg_7;
    pub const m_8 = BuilderM.m_8;
    pub const m_neg_8 = BuilderM.m_neg_8;
    pub const m_9 = BuilderM.m_9;
    pub const m_neg_9 = BuilderM.m_neg_9;
    pub const m_10 = BuilderM.m_10;
    pub const m_neg_10 = BuilderM.m_neg_10;
    pub const m_11 = BuilderM.m_11;
    pub const m_neg_11 = BuilderM.m_neg_11;
    pub const m_12 = BuilderM.m_12;
    pub const m_neg_12 = BuilderM.m_neg_12;
    pub const m_16 = BuilderM.m_16;
    pub const m_neg_16 = BuilderM.m_neg_16;
    pub const m_20 = BuilderM.m_20;
    pub const m_neg_20 = BuilderM.m_neg_20;
    pub const m_24 = BuilderM.m_24;
    pub const m_neg_24 = BuilderM.m_neg_24;
    pub const m_32 = BuilderM.m_32;
    pub const m_neg_32 = BuilderM.m_neg_32;
    pub const m_40 = BuilderM.m_40;
    pub const m_neg_40 = BuilderM.m_neg_40;
    pub const m_48 = BuilderM.m_48;
    pub const m_neg_48 = BuilderM.m_neg_48;
    pub const m_56 = BuilderM.m_56;
    pub const m_neg_56 = BuilderM.m_neg_56;
    pub const m_64 = BuilderM.m_64;
    pub const m_neg_64 = BuilderM.m_neg_64;
    pub const m_72 = BuilderM.m_72;
    pub const m_neg_72 = BuilderM.m_neg_72;
    pub const m_80 = BuilderM.m_80;
    pub const m_neg_80 = BuilderM.m_neg_80;
    pub const m_96 = BuilderM.m_96;
    pub const m_neg_96 = BuilderM.m_neg_96;
    pub const m_112 = BuilderM.m_112;
    pub const m_neg_112 = BuilderM.m_neg_112;
    pub const m_128 = BuilderM.m_128;
    pub const m_neg_128 = BuilderM.m_neg_128;
    pub const m_auto = BuilderM.m_auto;
    pub const m_px = BuilderM.m_px;
    pub const m_neg_px = BuilderM.m_neg_px;
    pub const m_full = BuilderM.m_full;
    pub const m_neg_full = BuilderM.m_neg_full;
    pub const m_1_2 = BuilderM.m_1_2;
    pub const m_neg_1_2 = BuilderM.m_neg_1_2;
    pub const m_1_3 = BuilderM.m_1_3;
    pub const m_neg_1_3 = BuilderM.m_neg_1_3;
    pub const m_2_3 = BuilderM.m_2_3;
    pub const m_neg_2_3 = BuilderM.m_neg_2_3;
    pub const m_1_4 = BuilderM.m_1_4;
    pub const m_neg_1_4 = BuilderM.m_neg_1_4;
    pub const m_2_4 = BuilderM.m_2_4;
    pub const m_neg_2_4 = BuilderM.m_neg_2_4;
    pub const m_3_4 = BuilderM.m_3_4;
    pub const m_neg_3_4 = BuilderM.m_neg_3_4;
    pub const m_1_5 = BuilderM.m_1_5;
    pub const m_neg_1_5 = BuilderM.m_neg_1_5;
    pub const m_2_5 = BuilderM.m_2_5;
    pub const m_neg_2_5 = BuilderM.m_neg_2_5;
    pub const m_3_5 = BuilderM.m_3_5;
    pub const m_neg_3_5 = BuilderM.m_neg_3_5;
    pub const m_4_5 = BuilderM.m_4_5;
    pub const m_neg_4_5 = BuilderM.m_neg_4_5;
    pub const m_1_6 = BuilderM.m_1_6;
    pub const m_neg_1_6 = BuilderM.m_neg_1_6;
    pub const m_5_6 = BuilderM.m_5_6;
    pub const m_neg_5_6 = BuilderM.m_neg_5_6;
    pub const m_1_12 = BuilderM.m_1_12;
    pub const m_neg_1_12 = BuilderM.m_neg_1_12;
    pub const mt = BuilderM.mt;
    pub const mt_0 = BuilderM.mt_0;
    pub const mt_neg_0 = BuilderM.mt_neg_0;
    pub const mt_0p5 = BuilderM.mt_0p5;
    pub const mt_neg_0p5 = BuilderM.mt_neg_0p5;
    pub const mt_1 = BuilderM.mt_1;
    pub const mt_neg_1 = BuilderM.mt_neg_1;
    pub const mt_1p5 = BuilderM.mt_1p5;
    pub const mt_neg_1p5 = BuilderM.mt_neg_1p5;
    pub const mt_2 = BuilderM.mt_2;
    pub const mt_neg_2 = BuilderM.mt_neg_2;
    pub const mt_2p5 = BuilderM.mt_2p5;
    pub const mt_neg_2p5 = BuilderM.mt_neg_2p5;
    pub const mt_3 = BuilderM.mt_3;
    pub const mt_neg_3 = BuilderM.mt_neg_3;
    pub const mt_3p5 = BuilderM.mt_3p5;
    pub const mt_neg_3p5 = BuilderM.mt_neg_3p5;
    pub const mt_4 = BuilderM.mt_4;
    pub const mt_neg_4 = BuilderM.mt_neg_4;
    pub const mt_5 = BuilderM.mt_5;
    pub const mt_neg_5 = BuilderM.mt_neg_5;
    pub const mt_6 = BuilderM.mt_6;
    pub const mt_neg_6 = BuilderM.mt_neg_6;
    pub const mt_7 = BuilderM.mt_7;
    pub const mt_neg_7 = BuilderM.mt_neg_7;
    pub const mt_8 = BuilderM.mt_8;
    pub const mt_neg_8 = BuilderM.mt_neg_8;
    pub const mt_9 = BuilderM.mt_9;
    pub const mt_neg_9 = BuilderM.mt_neg_9;
    pub const mt_10 = BuilderM.mt_10;
    pub const mt_neg_10 = BuilderM.mt_neg_10;
    pub const mt_11 = BuilderM.mt_11;
    pub const mt_neg_11 = BuilderM.mt_neg_11;
    pub const mt_12 = BuilderM.mt_12;
    pub const mt_neg_12 = BuilderM.mt_neg_12;
    pub const mt_16 = BuilderM.mt_16;
    pub const mt_neg_16 = BuilderM.mt_neg_16;
    pub const mt_20 = BuilderM.mt_20;
    pub const mt_neg_20 = BuilderM.mt_neg_20;
    pub const mt_24 = BuilderM.mt_24;
    pub const mt_neg_24 = BuilderM.mt_neg_24;
    pub const mt_32 = BuilderM.mt_32;
    pub const mt_neg_32 = BuilderM.mt_neg_32;
    pub const mt_40 = BuilderM.mt_40;
    pub const mt_neg_40 = BuilderM.mt_neg_40;
    pub const mt_48 = BuilderM.mt_48;
    pub const mt_neg_48 = BuilderM.mt_neg_48;
    pub const mt_56 = BuilderM.mt_56;
    pub const mt_neg_56 = BuilderM.mt_neg_56;
    pub const mt_64 = BuilderM.mt_64;
    pub const mt_neg_64 = BuilderM.mt_neg_64;
    pub const mt_72 = BuilderM.mt_72;
    pub const mt_neg_72 = BuilderM.mt_neg_72;
    pub const mt_80 = BuilderM.mt_80;
    pub const mt_neg_80 = BuilderM.mt_neg_80;
    pub const mt_96 = BuilderM.mt_96;
    pub const mt_neg_96 = BuilderM.mt_neg_96;
    pub const mt_112 = BuilderM.mt_112;
    pub const mt_neg_112 = BuilderM.mt_neg_112;
    pub const mt_128 = BuilderM.mt_128;
    pub const mt_neg_128 = BuilderM.mt_neg_128;
    pub const mt_auto = BuilderM.mt_auto;
    pub const mt_px = BuilderM.mt_px;
    pub const mt_neg_px = BuilderM.mt_neg_px;
    pub const mt_full = BuilderM.mt_full;
    pub const mt_neg_full = BuilderM.mt_neg_full;
    pub const mt_1_2 = BuilderM.mt_1_2;
    pub const mt_neg_1_2 = BuilderM.mt_neg_1_2;
    pub const mt_1_3 = BuilderM.mt_1_3;
    pub const mt_neg_1_3 = BuilderM.mt_neg_1_3;
    pub const mt_2_3 = BuilderM.mt_2_3;
    pub const mt_neg_2_3 = BuilderM.mt_neg_2_3;
    pub const mt_1_4 = BuilderM.mt_1_4;
    pub const mt_neg_1_4 = BuilderM.mt_neg_1_4;
    pub const mt_2_4 = BuilderM.mt_2_4;
    pub const mt_neg_2_4 = BuilderM.mt_neg_2_4;
    pub const mt_3_4 = BuilderM.mt_3_4;
    pub const mt_neg_3_4 = BuilderM.mt_neg_3_4;
    pub const mt_1_5 = BuilderM.mt_1_5;
    pub const mt_neg_1_5 = BuilderM.mt_neg_1_5;
    pub const mt_2_5 = BuilderM.mt_2_5;
    pub const mt_neg_2_5 = BuilderM.mt_neg_2_5;
    pub const mt_3_5 = BuilderM.mt_3_5;
    pub const mt_neg_3_5 = BuilderM.mt_neg_3_5;
    pub const mt_4_5 = BuilderM.mt_4_5;
    pub const mt_neg_4_5 = BuilderM.mt_neg_4_5;
    pub const mt_1_6 = BuilderM.mt_1_6;
    pub const mt_neg_1_6 = BuilderM.mt_neg_1_6;
    pub const mt_5_6 = BuilderM.mt_5_6;
    pub const mt_neg_5_6 = BuilderM.mt_neg_5_6;
    pub const mt_1_12 = BuilderM.mt_1_12;
    pub const mt_neg_1_12 = BuilderM.mt_neg_1_12;
    pub const mb = BuilderM.mb;
    pub const mb_0 = BuilderM.mb_0;
    pub const mb_neg_0 = BuilderM.mb_neg_0;
    pub const mb_0p5 = BuilderM.mb_0p5;
    pub const mb_neg_0p5 = BuilderM.mb_neg_0p5;
    pub const mb_1 = BuilderM.mb_1;
    pub const mb_neg_1 = BuilderM.mb_neg_1;
    pub const mb_1p5 = BuilderM.mb_1p5;
    pub const mb_neg_1p5 = BuilderM.mb_neg_1p5;
    pub const mb_2 = BuilderM.mb_2;
    pub const mb_neg_2 = BuilderM.mb_neg_2;
    pub const mb_2p5 = BuilderM.mb_2p5;
    pub const mb_neg_2p5 = BuilderM.mb_neg_2p5;
    pub const mb_3 = BuilderM.mb_3;
    pub const mb_neg_3 = BuilderM.mb_neg_3;
    pub const mb_3p5 = BuilderM.mb_3p5;
    pub const mb_neg_3p5 = BuilderM.mb_neg_3p5;
    pub const mb_4 = BuilderM.mb_4;
    pub const mb_neg_4 = BuilderM.mb_neg_4;
    pub const mb_5 = BuilderM.mb_5;
    pub const mb_neg_5 = BuilderM.mb_neg_5;
    pub const mb_6 = BuilderM.mb_6;
    pub const mb_neg_6 = BuilderM.mb_neg_6;
    pub const mb_7 = BuilderM.mb_7;
    pub const mb_neg_7 = BuilderM.mb_neg_7;
    pub const mb_8 = BuilderM.mb_8;
    pub const mb_neg_8 = BuilderM.mb_neg_8;
    pub const mb_9 = BuilderM.mb_9;
    pub const mb_neg_9 = BuilderM.mb_neg_9;
    pub const mb_10 = BuilderM.mb_10;
    pub const mb_neg_10 = BuilderM.mb_neg_10;
    pub const mb_11 = BuilderM.mb_11;
    pub const mb_neg_11 = BuilderM.mb_neg_11;
    pub const mb_12 = BuilderM.mb_12;
    pub const mb_neg_12 = BuilderM.mb_neg_12;
    pub const mb_16 = BuilderM.mb_16;
    pub const mb_neg_16 = BuilderM.mb_neg_16;
    pub const mb_20 = BuilderM.mb_20;
    pub const mb_neg_20 = BuilderM.mb_neg_20;
    pub const mb_24 = BuilderM.mb_24;
    pub const mb_neg_24 = BuilderM.mb_neg_24;
    pub const mb_32 = BuilderM.mb_32;
    pub const mb_neg_32 = BuilderM.mb_neg_32;
    pub const mb_40 = BuilderM.mb_40;
    pub const mb_neg_40 = BuilderM.mb_neg_40;
    pub const mb_48 = BuilderM.mb_48;
    pub const mb_neg_48 = BuilderM.mb_neg_48;
    pub const mb_56 = BuilderM.mb_56;
    pub const mb_neg_56 = BuilderM.mb_neg_56;
    pub const mb_64 = BuilderM.mb_64;
    pub const mb_neg_64 = BuilderM.mb_neg_64;
    pub const mb_72 = BuilderM.mb_72;
    pub const mb_neg_72 = BuilderM.mb_neg_72;
    pub const mb_80 = BuilderM.mb_80;
    pub const mb_neg_80 = BuilderM.mb_neg_80;
    pub const mb_96 = BuilderM.mb_96;
    pub const mb_neg_96 = BuilderM.mb_neg_96;
    pub const mb_112 = BuilderM.mb_112;
    pub const mb_neg_112 = BuilderM.mb_neg_112;
    pub const mb_128 = BuilderM.mb_128;
    pub const mb_neg_128 = BuilderM.mb_neg_128;
    pub const mb_auto = BuilderM.mb_auto;
    pub const mb_px = BuilderM.mb_px;
    pub const mb_neg_px = BuilderM.mb_neg_px;
    pub const mb_full = BuilderM.mb_full;
    pub const mb_neg_full = BuilderM.mb_neg_full;
    pub const mb_1_2 = BuilderM.mb_1_2;
    pub const mb_neg_1_2 = BuilderM.mb_neg_1_2;
    pub const mb_1_3 = BuilderM.mb_1_3;
    pub const mb_neg_1_3 = BuilderM.mb_neg_1_3;
    pub const mb_2_3 = BuilderM.mb_2_3;
    pub const mb_neg_2_3 = BuilderM.mb_neg_2_3;
    pub const mb_1_4 = BuilderM.mb_1_4;
    pub const mb_neg_1_4 = BuilderM.mb_neg_1_4;
    pub const mb_2_4 = BuilderM.mb_2_4;
    pub const mb_neg_2_4 = BuilderM.mb_neg_2_4;
    pub const mb_3_4 = BuilderM.mb_3_4;
    pub const mb_neg_3_4 = BuilderM.mb_neg_3_4;
    pub const mb_1_5 = BuilderM.mb_1_5;
    pub const mb_neg_1_5 = BuilderM.mb_neg_1_5;
    pub const mb_2_5 = BuilderM.mb_2_5;
    pub const mb_neg_2_5 = BuilderM.mb_neg_2_5;
    pub const mb_3_5 = BuilderM.mb_3_5;
    pub const mb_neg_3_5 = BuilderM.mb_neg_3_5;
    pub const mb_4_5 = BuilderM.mb_4_5;
    pub const mb_neg_4_5 = BuilderM.mb_neg_4_5;
    pub const mb_1_6 = BuilderM.mb_1_6;
    pub const mb_neg_1_6 = BuilderM.mb_neg_1_6;
    pub const mb_5_6 = BuilderM.mb_5_6;
    pub const mb_neg_5_6 = BuilderM.mb_neg_5_6;
    pub const mb_1_12 = BuilderM.mb_1_12;
    pub const mb_neg_1_12 = BuilderM.mb_neg_1_12;
    pub const my = BuilderM.my;
    pub const my_0 = BuilderM.my_0;
    pub const my_neg_0 = BuilderM.my_neg_0;
    pub const my_0p5 = BuilderM.my_0p5;
    pub const my_neg_0p5 = BuilderM.my_neg_0p5;
    pub const my_1 = BuilderM.my_1;
    pub const my_neg_1 = BuilderM.my_neg_1;
    pub const my_1p5 = BuilderM.my_1p5;
    pub const my_neg_1p5 = BuilderM.my_neg_1p5;
    pub const my_2 = BuilderM.my_2;
    pub const my_neg_2 = BuilderM.my_neg_2;
    pub const my_2p5 = BuilderM.my_2p5;
    pub const my_neg_2p5 = BuilderM.my_neg_2p5;
    pub const my_3 = BuilderM.my_3;
    pub const my_neg_3 = BuilderM.my_neg_3;
    pub const my_3p5 = BuilderM.my_3p5;
    pub const my_neg_3p5 = BuilderM.my_neg_3p5;
    pub const my_4 = BuilderM.my_4;
    pub const my_neg_4 = BuilderM.my_neg_4;
    pub const my_5 = BuilderM.my_5;
    pub const my_neg_5 = BuilderM.my_neg_5;
    pub const my_6 = BuilderM.my_6;
    pub const my_neg_6 = BuilderM.my_neg_6;
    pub const my_7 = BuilderM.my_7;
    pub const my_neg_7 = BuilderM.my_neg_7;
    pub const my_8 = BuilderM.my_8;
    pub const my_neg_8 = BuilderM.my_neg_8;
    pub const my_9 = BuilderM.my_9;
    pub const my_neg_9 = BuilderM.my_neg_9;
    pub const my_10 = BuilderM.my_10;
    pub const my_neg_10 = BuilderM.my_neg_10;
    pub const my_11 = BuilderM.my_11;
    pub const my_neg_11 = BuilderM.my_neg_11;
    pub const my_12 = BuilderM.my_12;
    pub const my_neg_12 = BuilderM.my_neg_12;
    pub const my_16 = BuilderM.my_16;
    pub const my_neg_16 = BuilderM.my_neg_16;
    pub const my_20 = BuilderM.my_20;
    pub const my_neg_20 = BuilderM.my_neg_20;
    pub const my_24 = BuilderM.my_24;
    pub const my_neg_24 = BuilderM.my_neg_24;
    pub const my_32 = BuilderM.my_32;
    pub const my_neg_32 = BuilderM.my_neg_32;
    pub const my_40 = BuilderM.my_40;
    pub const my_neg_40 = BuilderM.my_neg_40;
    pub const my_48 = BuilderM.my_48;
    pub const my_neg_48 = BuilderM.my_neg_48;
    pub const my_56 = BuilderM.my_56;
    pub const my_neg_56 = BuilderM.my_neg_56;
    pub const my_64 = BuilderM.my_64;
    pub const my_neg_64 = BuilderM.my_neg_64;
    pub const my_72 = BuilderM.my_72;
    pub const my_neg_72 = BuilderM.my_neg_72;
    pub const my_80 = BuilderM.my_80;
    pub const my_neg_80 = BuilderM.my_neg_80;
    pub const my_96 = BuilderM.my_96;
    pub const my_neg_96 = BuilderM.my_neg_96;
    pub const my_112 = BuilderM.my_112;
    pub const my_neg_112 = BuilderM.my_neg_112;
    pub const my_128 = BuilderM.my_128;
    pub const my_neg_128 = BuilderM.my_neg_128;
    pub const my_auto = BuilderM.my_auto;
    pub const my_px = BuilderM.my_px;
    pub const my_neg_px = BuilderM.my_neg_px;
    pub const my_full = BuilderM.my_full;
    pub const my_neg_full = BuilderM.my_neg_full;
    pub const my_1_2 = BuilderM.my_1_2;
    pub const my_neg_1_2 = BuilderM.my_neg_1_2;
    pub const my_1_3 = BuilderM.my_1_3;
    pub const my_neg_1_3 = BuilderM.my_neg_1_3;
    pub const my_2_3 = BuilderM.my_2_3;
    pub const my_neg_2_3 = BuilderM.my_neg_2_3;
    pub const my_1_4 = BuilderM.my_1_4;
    pub const my_neg_1_4 = BuilderM.my_neg_1_4;
    pub const my_2_4 = BuilderM.my_2_4;
    pub const my_neg_2_4 = BuilderM.my_neg_2_4;
    pub const my_3_4 = BuilderM.my_3_4;
    pub const my_neg_3_4 = BuilderM.my_neg_3_4;
    pub const my_1_5 = BuilderM.my_1_5;
    pub const my_neg_1_5 = BuilderM.my_neg_1_5;
    pub const my_2_5 = BuilderM.my_2_5;
    pub const my_neg_2_5 = BuilderM.my_neg_2_5;
    pub const my_3_5 = BuilderM.my_3_5;
    pub const my_neg_3_5 = BuilderM.my_neg_3_5;
    pub const my_4_5 = BuilderM.my_4_5;
    pub const my_neg_4_5 = BuilderM.my_neg_4_5;
    pub const my_1_6 = BuilderM.my_1_6;
    pub const my_neg_1_6 = BuilderM.my_neg_1_6;
    pub const my_5_6 = BuilderM.my_5_6;
    pub const my_neg_5_6 = BuilderM.my_neg_5_6;
    pub const my_1_12 = BuilderM.my_1_12;
    pub const my_neg_1_12 = BuilderM.my_neg_1_12;
    pub const mx = BuilderM.mx;
    pub const mx_0 = BuilderM.mx_0;
    pub const mx_neg_0 = BuilderM.mx_neg_0;
    pub const mx_0p5 = BuilderM.mx_0p5;
    pub const mx_neg_0p5 = BuilderM.mx_neg_0p5;
    pub const mx_1 = BuilderM.mx_1;
    pub const mx_neg_1 = BuilderM.mx_neg_1;
    pub const mx_1p5 = BuilderM.mx_1p5;
    pub const mx_neg_1p5 = BuilderM.mx_neg_1p5;
    pub const mx_2 = BuilderM.mx_2;
    pub const mx_neg_2 = BuilderM.mx_neg_2;
    pub const mx_2p5 = BuilderM.mx_2p5;
    pub const mx_neg_2p5 = BuilderM.mx_neg_2p5;
    pub const mx_3 = BuilderM.mx_3;
    pub const mx_neg_3 = BuilderM.mx_neg_3;
    pub const mx_3p5 = BuilderM.mx_3p5;
    pub const mx_neg_3p5 = BuilderM.mx_neg_3p5;
    pub const mx_4 = BuilderM.mx_4;
    pub const mx_neg_4 = BuilderM.mx_neg_4;
    pub const mx_5 = BuilderM.mx_5;
    pub const mx_neg_5 = BuilderM.mx_neg_5;
    pub const mx_6 = BuilderM.mx_6;
    pub const mx_neg_6 = BuilderM.mx_neg_6;
    pub const mx_7 = BuilderM.mx_7;
    pub const mx_neg_7 = BuilderM.mx_neg_7;
    pub const mx_8 = BuilderM.mx_8;
    pub const mx_neg_8 = BuilderM.mx_neg_8;
    pub const mx_9 = BuilderM.mx_9;
    pub const mx_neg_9 = BuilderM.mx_neg_9;
    pub const mx_10 = BuilderM.mx_10;
    pub const mx_neg_10 = BuilderM.mx_neg_10;
    pub const mx_11 = BuilderM.mx_11;
    pub const mx_neg_11 = BuilderM.mx_neg_11;
    pub const mx_12 = BuilderM.mx_12;
    pub const mx_neg_12 = BuilderM.mx_neg_12;
    pub const mx_16 = BuilderM.mx_16;
    pub const mx_neg_16 = BuilderM.mx_neg_16;
    pub const mx_20 = BuilderM.mx_20;
    pub const mx_neg_20 = BuilderM.mx_neg_20;
    pub const mx_24 = BuilderM.mx_24;
    pub const mx_neg_24 = BuilderM.mx_neg_24;
    pub const mx_32 = BuilderM.mx_32;
    pub const mx_neg_32 = BuilderM.mx_neg_32;
    pub const mx_40 = BuilderM.mx_40;
    pub const mx_neg_40 = BuilderM.mx_neg_40;
    pub const mx_48 = BuilderM.mx_48;
    pub const mx_neg_48 = BuilderM.mx_neg_48;
    pub const mx_56 = BuilderM.mx_56;
    pub const mx_neg_56 = BuilderM.mx_neg_56;
    pub const mx_64 = BuilderM.mx_64;
    pub const mx_neg_64 = BuilderM.mx_neg_64;
    pub const mx_72 = BuilderM.mx_72;
    pub const mx_neg_72 = BuilderM.mx_neg_72;
    pub const mx_80 = BuilderM.mx_80;
    pub const mx_neg_80 = BuilderM.mx_neg_80;
    pub const mx_96 = BuilderM.mx_96;
    pub const mx_neg_96 = BuilderM.mx_neg_96;
    pub const mx_112 = BuilderM.mx_112;
    pub const mx_neg_112 = BuilderM.mx_neg_112;
    pub const mx_128 = BuilderM.mx_128;
    pub const mx_neg_128 = BuilderM.mx_neg_128;
    pub const mx_auto = BuilderM.mx_auto;
    pub const mx_px = BuilderM.mx_px;
    pub const mx_neg_px = BuilderM.mx_neg_px;
    pub const mx_full = BuilderM.mx_full;
    pub const mx_neg_full = BuilderM.mx_neg_full;
    pub const mx_1_2 = BuilderM.mx_1_2;
    pub const mx_neg_1_2 = BuilderM.mx_neg_1_2;
    pub const mx_1_3 = BuilderM.mx_1_3;
    pub const mx_neg_1_3 = BuilderM.mx_neg_1_3;
    pub const mx_2_3 = BuilderM.mx_2_3;
    pub const mx_neg_2_3 = BuilderM.mx_neg_2_3;
    pub const mx_1_4 = BuilderM.mx_1_4;
    pub const mx_neg_1_4 = BuilderM.mx_neg_1_4;
    pub const mx_2_4 = BuilderM.mx_2_4;
    pub const mx_neg_2_4 = BuilderM.mx_neg_2_4;
    pub const mx_3_4 = BuilderM.mx_3_4;
    pub const mx_neg_3_4 = BuilderM.mx_neg_3_4;
    pub const mx_1_5 = BuilderM.mx_1_5;
    pub const mx_neg_1_5 = BuilderM.mx_neg_1_5;
    pub const mx_2_5 = BuilderM.mx_2_5;
    pub const mx_neg_2_5 = BuilderM.mx_neg_2_5;
    pub const mx_3_5 = BuilderM.mx_3_5;
    pub const mx_neg_3_5 = BuilderM.mx_neg_3_5;
    pub const mx_4_5 = BuilderM.mx_4_5;
    pub const mx_neg_4_5 = BuilderM.mx_neg_4_5;
    pub const mx_1_6 = BuilderM.mx_1_6;
    pub const mx_neg_1_6 = BuilderM.mx_neg_1_6;
    pub const mx_5_6 = BuilderM.mx_5_6;
    pub const mx_neg_5_6 = BuilderM.mx_neg_5_6;
    pub const mx_1_12 = BuilderM.mx_1_12;
    pub const mx_neg_1_12 = BuilderM.mx_neg_1_12;
    pub const ml = BuilderM.ml;
    pub const ml_0 = BuilderM.ml_0;
    pub const ml_neg_0 = BuilderM.ml_neg_0;
    pub const ml_0p5 = BuilderM.ml_0p5;
    pub const ml_neg_0p5 = BuilderM.ml_neg_0p5;
    pub const ml_1 = BuilderM.ml_1;
    pub const ml_neg_1 = BuilderM.ml_neg_1;
    pub const ml_1p5 = BuilderM.ml_1p5;
    pub const ml_neg_1p5 = BuilderM.ml_neg_1p5;
    pub const ml_2 = BuilderM.ml_2;
    pub const ml_neg_2 = BuilderM.ml_neg_2;
    pub const ml_2p5 = BuilderM.ml_2p5;
    pub const ml_neg_2p5 = BuilderM.ml_neg_2p5;
    pub const ml_3 = BuilderM.ml_3;
    pub const ml_neg_3 = BuilderM.ml_neg_3;
    pub const ml_3p5 = BuilderM.ml_3p5;
    pub const ml_neg_3p5 = BuilderM.ml_neg_3p5;
    pub const ml_4 = BuilderM.ml_4;
    pub const ml_neg_4 = BuilderM.ml_neg_4;
    pub const ml_5 = BuilderM.ml_5;
    pub const ml_neg_5 = BuilderM.ml_neg_5;
    pub const ml_6 = BuilderM.ml_6;
    pub const ml_neg_6 = BuilderM.ml_neg_6;
    pub const ml_7 = BuilderM.ml_7;
    pub const ml_neg_7 = BuilderM.ml_neg_7;
    pub const ml_8 = BuilderM.ml_8;
    pub const ml_neg_8 = BuilderM.ml_neg_8;
    pub const ml_9 = BuilderM.ml_9;
    pub const ml_neg_9 = BuilderM.ml_neg_9;
    pub const ml_10 = BuilderM.ml_10;
    pub const ml_neg_10 = BuilderM.ml_neg_10;
    pub const ml_11 = BuilderM.ml_11;
    pub const ml_neg_11 = BuilderM.ml_neg_11;
    pub const ml_12 = BuilderM.ml_12;
    pub const ml_neg_12 = BuilderM.ml_neg_12;
    pub const ml_16 = BuilderM.ml_16;
    pub const ml_neg_16 = BuilderM.ml_neg_16;
    pub const ml_20 = BuilderM.ml_20;
    pub const ml_neg_20 = BuilderM.ml_neg_20;
    pub const ml_24 = BuilderM.ml_24;
    pub const ml_neg_24 = BuilderM.ml_neg_24;
    pub const ml_32 = BuilderM.ml_32;
    pub const ml_neg_32 = BuilderM.ml_neg_32;
    pub const ml_40 = BuilderM.ml_40;
    pub const ml_neg_40 = BuilderM.ml_neg_40;
    pub const ml_48 = BuilderM.ml_48;
    pub const ml_neg_48 = BuilderM.ml_neg_48;
    pub const ml_56 = BuilderM.ml_56;
    pub const ml_neg_56 = BuilderM.ml_neg_56;
    pub const ml_64 = BuilderM.ml_64;
    pub const ml_neg_64 = BuilderM.ml_neg_64;
    pub const ml_72 = BuilderM.ml_72;
    pub const ml_neg_72 = BuilderM.ml_neg_72;
    pub const ml_80 = BuilderM.ml_80;
    pub const ml_neg_80 = BuilderM.ml_neg_80;
    pub const ml_96 = BuilderM.ml_96;
    pub const ml_neg_96 = BuilderM.ml_neg_96;
    pub const ml_112 = BuilderM.ml_112;
    pub const ml_neg_112 = BuilderM.ml_neg_112;
    pub const ml_128 = BuilderM.ml_128;
    pub const ml_neg_128 = BuilderM.ml_neg_128;
    pub const ml_auto = BuilderM.ml_auto;
    pub const ml_px = BuilderM.ml_px;
    pub const ml_neg_px = BuilderM.ml_neg_px;
    pub const ml_full = BuilderM.ml_full;
    pub const ml_neg_full = BuilderM.ml_neg_full;
    pub const ml_1_2 = BuilderM.ml_1_2;
    pub const ml_neg_1_2 = BuilderM.ml_neg_1_2;
    pub const ml_1_3 = BuilderM.ml_1_3;
    pub const ml_neg_1_3 = BuilderM.ml_neg_1_3;
    pub const ml_2_3 = BuilderM.ml_2_3;
    pub const ml_neg_2_3 = BuilderM.ml_neg_2_3;
    pub const ml_1_4 = BuilderM.ml_1_4;
    pub const ml_neg_1_4 = BuilderM.ml_neg_1_4;
    pub const ml_2_4 = BuilderM.ml_2_4;
    pub const ml_neg_2_4 = BuilderM.ml_neg_2_4;
    pub const ml_3_4 = BuilderM.ml_3_4;
    pub const ml_neg_3_4 = BuilderM.ml_neg_3_4;
    pub const ml_1_5 = BuilderM.ml_1_5;
    pub const ml_neg_1_5 = BuilderM.ml_neg_1_5;
    pub const ml_2_5 = BuilderM.ml_2_5;
    pub const ml_neg_2_5 = BuilderM.ml_neg_2_5;
    pub const ml_3_5 = BuilderM.ml_3_5;
    pub const ml_neg_3_5 = BuilderM.ml_neg_3_5;
    pub const ml_4_5 = BuilderM.ml_4_5;
    pub const ml_neg_4_5 = BuilderM.ml_neg_4_5;
    pub const ml_1_6 = BuilderM.ml_1_6;
    pub const ml_neg_1_6 = BuilderM.ml_neg_1_6;
    pub const ml_5_6 = BuilderM.ml_5_6;
    pub const ml_neg_5_6 = BuilderM.ml_neg_5_6;
    pub const ml_1_12 = BuilderM.ml_1_12;
    pub const ml_neg_1_12 = BuilderM.ml_neg_1_12;
    pub const mr = BuilderM.mr;
    pub const mr_0 = BuilderM.mr_0;
    pub const mr_neg_0 = BuilderM.mr_neg_0;
    pub const mr_0p5 = BuilderM.mr_0p5;
    pub const mr_neg_0p5 = BuilderM.mr_neg_0p5;
    pub const mr_1 = BuilderM.mr_1;
    pub const mr_neg_1 = BuilderM.mr_neg_1;
    pub const mr_1p5 = BuilderM.mr_1p5;
    pub const mr_neg_1p5 = BuilderM.mr_neg_1p5;
    pub const mr_2 = BuilderM.mr_2;
    pub const mr_neg_2 = BuilderM.mr_neg_2;
    pub const mr_2p5 = BuilderM.mr_2p5;
    pub const mr_neg_2p5 = BuilderM.mr_neg_2p5;
    pub const mr_3 = BuilderM.mr_3;
    pub const mr_neg_3 = BuilderM.mr_neg_3;
    pub const mr_3p5 = BuilderM.mr_3p5;
    pub const mr_neg_3p5 = BuilderM.mr_neg_3p5;
    pub const mr_4 = BuilderM.mr_4;
    pub const mr_neg_4 = BuilderM.mr_neg_4;
    pub const mr_5 = BuilderM.mr_5;
    pub const mr_neg_5 = BuilderM.mr_neg_5;
    pub const mr_6 = BuilderM.mr_6;
    pub const mr_neg_6 = BuilderM.mr_neg_6;
    pub const mr_7 = BuilderM.mr_7;
    pub const mr_neg_7 = BuilderM.mr_neg_7;
    pub const mr_8 = BuilderM.mr_8;
    pub const mr_neg_8 = BuilderM.mr_neg_8;
    pub const mr_9 = BuilderM.mr_9;
    pub const mr_neg_9 = BuilderM.mr_neg_9;
    pub const mr_10 = BuilderM.mr_10;
    pub const mr_neg_10 = BuilderM.mr_neg_10;
    pub const mr_11 = BuilderM.mr_11;
    pub const mr_neg_11 = BuilderM.mr_neg_11;
    pub const mr_12 = BuilderM.mr_12;
    pub const mr_neg_12 = BuilderM.mr_neg_12;
    pub const mr_16 = BuilderM.mr_16;
    pub const mr_neg_16 = BuilderM.mr_neg_16;
    pub const mr_20 = BuilderM.mr_20;
    pub const mr_neg_20 = BuilderM.mr_neg_20;
    pub const mr_24 = BuilderM.mr_24;
    pub const mr_neg_24 = BuilderM.mr_neg_24;
    pub const mr_32 = BuilderM.mr_32;
    pub const mr_neg_32 = BuilderM.mr_neg_32;
    pub const mr_40 = BuilderM.mr_40;
    pub const mr_neg_40 = BuilderM.mr_neg_40;
    pub const mr_48 = BuilderM.mr_48;
    pub const mr_neg_48 = BuilderM.mr_neg_48;
    pub const mr_56 = BuilderM.mr_56;
    pub const mr_neg_56 = BuilderM.mr_neg_56;
    pub const mr_64 = BuilderM.mr_64;
    pub const mr_neg_64 = BuilderM.mr_neg_64;
    pub const mr_72 = BuilderM.mr_72;
    pub const mr_neg_72 = BuilderM.mr_neg_72;
    pub const mr_80 = BuilderM.mr_80;
    pub const mr_neg_80 = BuilderM.mr_neg_80;
    pub const mr_96 = BuilderM.mr_96;
    pub const mr_neg_96 = BuilderM.mr_neg_96;
    pub const mr_112 = BuilderM.mr_112;
    pub const mr_neg_112 = BuilderM.mr_neg_112;
    pub const mr_128 = BuilderM.mr_128;
    pub const mr_neg_128 = BuilderM.mr_neg_128;
    pub const mr_auto = BuilderM.mr_auto;
    pub const mr_px = BuilderM.mr_px;
    pub const mr_neg_px = BuilderM.mr_neg_px;
    pub const mr_full = BuilderM.mr_full;
    pub const mr_neg_full = BuilderM.mr_neg_full;
    pub const mr_1_2 = BuilderM.mr_1_2;
    pub const mr_neg_1_2 = BuilderM.mr_neg_1_2;
    pub const mr_1_3 = BuilderM.mr_1_3;
    pub const mr_neg_1_3 = BuilderM.mr_neg_1_3;
    pub const mr_2_3 = BuilderM.mr_2_3;
    pub const mr_neg_2_3 = BuilderM.mr_neg_2_3;
    pub const mr_1_4 = BuilderM.mr_1_4;
    pub const mr_neg_1_4 = BuilderM.mr_neg_1_4;
    pub const mr_2_4 = BuilderM.mr_2_4;
    pub const mr_neg_2_4 = BuilderM.mr_neg_2_4;
    pub const mr_3_4 = BuilderM.mr_3_4;
    pub const mr_neg_3_4 = BuilderM.mr_neg_3_4;
    pub const mr_1_5 = BuilderM.mr_1_5;
    pub const mr_neg_1_5 = BuilderM.mr_neg_1_5;
    pub const mr_2_5 = BuilderM.mr_2_5;
    pub const mr_neg_2_5 = BuilderM.mr_neg_2_5;
    pub const mr_3_5 = BuilderM.mr_3_5;
    pub const mr_neg_3_5 = BuilderM.mr_neg_3_5;
    pub const mr_4_5 = BuilderM.mr_4_5;
    pub const mr_neg_4_5 = BuilderM.mr_neg_4_5;
    pub const mr_1_6 = BuilderM.mr_1_6;
    pub const mr_neg_1_6 = BuilderM.mr_neg_1_6;
    pub const mr_5_6 = BuilderM.mr_5_6;
    pub const mr_neg_5_6 = BuilderM.mr_neg_5_6;
    pub const mr_1_12 = BuilderM.mr_1_12;
    pub const mr_neg_1_12 = BuilderM.mr_neg_1_12;
    pub const p = BuilderM.p;
    pub const p_0 = BuilderM.p_0;
    pub const p_neg_0 = BuilderM.p_neg_0;
    pub const p_0p5 = BuilderM.p_0p5;
    pub const p_neg_0p5 = BuilderM.p_neg_0p5;
    pub const p_1 = BuilderM.p_1;
    pub const p_neg_1 = BuilderM.p_neg_1;
    pub const p_1p5 = BuilderM.p_1p5;
    pub const p_neg_1p5 = BuilderM.p_neg_1p5;
    pub const p_2 = BuilderM.p_2;
    pub const p_neg_2 = BuilderM.p_neg_2;
    pub const p_2p5 = BuilderM.p_2p5;
    pub const p_neg_2p5 = BuilderM.p_neg_2p5;
    pub const p_3 = BuilderM.p_3;
    pub const p_neg_3 = BuilderM.p_neg_3;
    pub const p_3p5 = BuilderM.p_3p5;
    pub const p_neg_3p5 = BuilderM.p_neg_3p5;
    pub const p_4 = BuilderM.p_4;
    pub const p_neg_4 = BuilderM.p_neg_4;
    pub const p_5 = BuilderM.p_5;
    pub const p_neg_5 = BuilderM.p_neg_5;
    pub const p_6 = BuilderM.p_6;
    pub const p_neg_6 = BuilderM.p_neg_6;
    pub const p_7 = BuilderM.p_7;
    pub const p_neg_7 = BuilderM.p_neg_7;
    pub const p_8 = BuilderM.p_8;
    pub const p_neg_8 = BuilderM.p_neg_8;
    pub const p_9 = BuilderM.p_9;
    pub const p_neg_9 = BuilderM.p_neg_9;
    pub const p_10 = BuilderM.p_10;
    pub const p_neg_10 = BuilderM.p_neg_10;
    pub const p_11 = BuilderM.p_11;
    pub const p_neg_11 = BuilderM.p_neg_11;
    pub const p_12 = BuilderM.p_12;
    pub const p_neg_12 = BuilderM.p_neg_12;
    pub const p_16 = BuilderM.p_16;
    pub const p_neg_16 = BuilderM.p_neg_16;
    pub const p_20 = BuilderM.p_20;
    pub const p_neg_20 = BuilderM.p_neg_20;
    pub const p_24 = BuilderM.p_24;
    pub const p_neg_24 = BuilderM.p_neg_24;
    pub const p_32 = BuilderM.p_32;
    pub const p_neg_32 = BuilderM.p_neg_32;
    pub const p_40 = BuilderM.p_40;
    pub const p_neg_40 = BuilderM.p_neg_40;
    pub const p_48 = BuilderM.p_48;
    pub const p_neg_48 = BuilderM.p_neg_48;
    pub const p_56 = BuilderM.p_56;
    pub const p_neg_56 = BuilderM.p_neg_56;
    pub const p_64 = BuilderM.p_64;
    pub const p_neg_64 = BuilderM.p_neg_64;
    pub const p_72 = BuilderM.p_72;
    pub const p_neg_72 = BuilderM.p_neg_72;
    pub const p_80 = BuilderM.p_80;
    pub const p_neg_80 = BuilderM.p_neg_80;
    pub const p_96 = BuilderM.p_96;
    pub const p_neg_96 = BuilderM.p_neg_96;
    pub const p_112 = BuilderM.p_112;
    pub const p_neg_112 = BuilderM.p_neg_112;
    pub const p_128 = BuilderM.p_128;
    pub const p_neg_128 = BuilderM.p_neg_128;
    pub const p_px = BuilderM.p_px;
    pub const p_neg_px = BuilderM.p_neg_px;
    pub const p_full = BuilderM.p_full;
    pub const p_neg_full = BuilderM.p_neg_full;
    pub const p_1_2 = BuilderM.p_1_2;
    pub const p_neg_1_2 = BuilderM.p_neg_1_2;
    pub const p_1_3 = BuilderM.p_1_3;
    pub const p_neg_1_3 = BuilderM.p_neg_1_3;
    pub const p_2_3 = BuilderM.p_2_3;
    pub const p_neg_2_3 = BuilderM.p_neg_2_3;
    pub const p_1_4 = BuilderM.p_1_4;
    pub const p_neg_1_4 = BuilderM.p_neg_1_4;
    pub const p_2_4 = BuilderM.p_2_4;
    pub const p_neg_2_4 = BuilderM.p_neg_2_4;
    pub const p_3_4 = BuilderM.p_3_4;
    pub const p_neg_3_4 = BuilderM.p_neg_3_4;
    pub const p_1_5 = BuilderM.p_1_5;
    pub const p_neg_1_5 = BuilderM.p_neg_1_5;
    pub const p_2_5 = BuilderM.p_2_5;
    pub const p_neg_2_5 = BuilderM.p_neg_2_5;
    pub const p_3_5 = BuilderM.p_3_5;
    pub const p_neg_3_5 = BuilderM.p_neg_3_5;
    pub const p_4_5 = BuilderM.p_4_5;
    pub const p_neg_4_5 = BuilderM.p_neg_4_5;
    pub const p_1_6 = BuilderM.p_1_6;
    pub const p_neg_1_6 = BuilderM.p_neg_1_6;
    pub const p_5_6 = BuilderM.p_5_6;
    pub const p_neg_5_6 = BuilderM.p_neg_5_6;
    pub const p_1_12 = BuilderM.p_1_12;
    pub const p_neg_1_12 = BuilderM.p_neg_1_12;
    pub const pt = BuilderM.pt;
    pub const pt_0 = BuilderM.pt_0;
    pub const pt_neg_0 = BuilderM.pt_neg_0;
    pub const pt_0p5 = BuilderM.pt_0p5;
    pub const pt_neg_0p5 = BuilderM.pt_neg_0p5;
    pub const pt_1 = BuilderM.pt_1;
    pub const pt_neg_1 = BuilderM.pt_neg_1;
    pub const pt_1p5 = BuilderM.pt_1p5;
    pub const pt_neg_1p5 = BuilderM.pt_neg_1p5;
    pub const pt_2 = BuilderM.pt_2;
    pub const pt_neg_2 = BuilderM.pt_neg_2;
    pub const pt_2p5 = BuilderM.pt_2p5;
    pub const pt_neg_2p5 = BuilderM.pt_neg_2p5;
    pub const pt_3 = BuilderM.pt_3;
    pub const pt_neg_3 = BuilderM.pt_neg_3;
    pub const pt_3p5 = BuilderM.pt_3p5;
    pub const pt_neg_3p5 = BuilderM.pt_neg_3p5;
    pub const pt_4 = BuilderM.pt_4;
    pub const pt_neg_4 = BuilderM.pt_neg_4;
    pub const pt_5 = BuilderM.pt_5;
    pub const pt_neg_5 = BuilderM.pt_neg_5;
    pub const pt_6 = BuilderM.pt_6;
    pub const pt_neg_6 = BuilderM.pt_neg_6;
    pub const pt_7 = BuilderM.pt_7;
    pub const pt_neg_7 = BuilderM.pt_neg_7;
    pub const pt_8 = BuilderM.pt_8;
    pub const pt_neg_8 = BuilderM.pt_neg_8;
    pub const pt_9 = BuilderM.pt_9;
    pub const pt_neg_9 = BuilderM.pt_neg_9;
    pub const pt_10 = BuilderM.pt_10;
    pub const pt_neg_10 = BuilderM.pt_neg_10;
    pub const pt_11 = BuilderM.pt_11;
    pub const pt_neg_11 = BuilderM.pt_neg_11;
    pub const pt_12 = BuilderM.pt_12;
    pub const pt_neg_12 = BuilderM.pt_neg_12;
    pub const pt_16 = BuilderM.pt_16;
    pub const pt_neg_16 = BuilderM.pt_neg_16;
    pub const pt_20 = BuilderM.pt_20;
    pub const pt_neg_20 = BuilderM.pt_neg_20;
    pub const pt_24 = BuilderM.pt_24;
    pub const pt_neg_24 = BuilderM.pt_neg_24;
    pub const pt_32 = BuilderM.pt_32;
    pub const pt_neg_32 = BuilderM.pt_neg_32;
    pub const pt_40 = BuilderM.pt_40;
    pub const pt_neg_40 = BuilderM.pt_neg_40;
    pub const pt_48 = BuilderM.pt_48;
    pub const pt_neg_48 = BuilderM.pt_neg_48;
    pub const pt_56 = BuilderM.pt_56;
    pub const pt_neg_56 = BuilderM.pt_neg_56;
    pub const pt_64 = BuilderM.pt_64;
    pub const pt_neg_64 = BuilderM.pt_neg_64;
    pub const pt_72 = BuilderM.pt_72;
    pub const pt_neg_72 = BuilderM.pt_neg_72;
    pub const pt_80 = BuilderM.pt_80;
    pub const pt_neg_80 = BuilderM.pt_neg_80;
    pub const pt_96 = BuilderM.pt_96;
    pub const pt_neg_96 = BuilderM.pt_neg_96;
    pub const pt_112 = BuilderM.pt_112;
    pub const pt_neg_112 = BuilderM.pt_neg_112;
    pub const pt_128 = BuilderM.pt_128;
    pub const pt_neg_128 = BuilderM.pt_neg_128;
    pub const pt_px = BuilderM.pt_px;
    pub const pt_neg_px = BuilderM.pt_neg_px;
    pub const pt_full = BuilderM.pt_full;
    pub const pt_neg_full = BuilderM.pt_neg_full;
    pub const pt_1_2 = BuilderM.pt_1_2;
    pub const pt_neg_1_2 = BuilderM.pt_neg_1_2;
    pub const pt_1_3 = BuilderM.pt_1_3;
    pub const pt_neg_1_3 = BuilderM.pt_neg_1_3;
    pub const pt_2_3 = BuilderM.pt_2_3;
    pub const pt_neg_2_3 = BuilderM.pt_neg_2_3;
    pub const pt_1_4 = BuilderM.pt_1_4;
    pub const pt_neg_1_4 = BuilderM.pt_neg_1_4;
    pub const pt_2_4 = BuilderM.pt_2_4;
    pub const pt_neg_2_4 = BuilderM.pt_neg_2_4;
    pub const pt_3_4 = BuilderM.pt_3_4;
    pub const pt_neg_3_4 = BuilderM.pt_neg_3_4;
    pub const pt_1_5 = BuilderM.pt_1_5;
    pub const pt_neg_1_5 = BuilderM.pt_neg_1_5;
    pub const pt_2_5 = BuilderM.pt_2_5;
    pub const pt_neg_2_5 = BuilderM.pt_neg_2_5;
    pub const pt_3_5 = BuilderM.pt_3_5;
    pub const pt_neg_3_5 = BuilderM.pt_neg_3_5;
    pub const pt_4_5 = BuilderM.pt_4_5;
    pub const pt_neg_4_5 = BuilderM.pt_neg_4_5;
    pub const pt_1_6 = BuilderM.pt_1_6;
    pub const pt_neg_1_6 = BuilderM.pt_neg_1_6;
    pub const pt_5_6 = BuilderM.pt_5_6;
    pub const pt_neg_5_6 = BuilderM.pt_neg_5_6;
    pub const pt_1_12 = BuilderM.pt_1_12;
    pub const pt_neg_1_12 = BuilderM.pt_neg_1_12;
    pub const pb = BuilderM.pb;
    pub const pb_0 = BuilderM.pb_0;
    pub const pb_neg_0 = BuilderM.pb_neg_0;
    pub const pb_0p5 = BuilderM.pb_0p5;
    pub const pb_neg_0p5 = BuilderM.pb_neg_0p5;
    pub const pb_1 = BuilderM.pb_1;
    pub const pb_neg_1 = BuilderM.pb_neg_1;
    pub const pb_1p5 = BuilderM.pb_1p5;
    pub const pb_neg_1p5 = BuilderM.pb_neg_1p5;
    pub const pb_2 = BuilderM.pb_2;
    pub const pb_neg_2 = BuilderM.pb_neg_2;
    pub const pb_2p5 = BuilderM.pb_2p5;
    pub const pb_neg_2p5 = BuilderM.pb_neg_2p5;
    pub const pb_3 = BuilderM.pb_3;
    pub const pb_neg_3 = BuilderM.pb_neg_3;
    pub const pb_3p5 = BuilderM.pb_3p5;
    pub const pb_neg_3p5 = BuilderM.pb_neg_3p5;
    pub const pb_4 = BuilderM.pb_4;
    pub const pb_neg_4 = BuilderM.pb_neg_4;
    pub const pb_5 = BuilderM.pb_5;
    pub const pb_neg_5 = BuilderM.pb_neg_5;
    pub const pb_6 = BuilderM.pb_6;
    pub const pb_neg_6 = BuilderM.pb_neg_6;
    pub const pb_7 = BuilderM.pb_7;
    pub const pb_neg_7 = BuilderM.pb_neg_7;
    pub const pb_8 = BuilderM.pb_8;
    pub const pb_neg_8 = BuilderM.pb_neg_8;
    pub const pb_9 = BuilderM.pb_9;
    pub const pb_neg_9 = BuilderM.pb_neg_9;
    pub const pb_10 = BuilderM.pb_10;
    pub const pb_neg_10 = BuilderM.pb_neg_10;
    pub const pb_11 = BuilderM.pb_11;
    pub const pb_neg_11 = BuilderM.pb_neg_11;
    pub const pb_12 = BuilderM.pb_12;
    pub const pb_neg_12 = BuilderM.pb_neg_12;
    pub const pb_16 = BuilderM.pb_16;
    pub const pb_neg_16 = BuilderM.pb_neg_16;
    pub const pb_20 = BuilderM.pb_20;
    pub const pb_neg_20 = BuilderM.pb_neg_20;
    pub const pb_24 = BuilderM.pb_24;
    pub const pb_neg_24 = BuilderM.pb_neg_24;
    pub const pb_32 = BuilderM.pb_32;
    pub const pb_neg_32 = BuilderM.pb_neg_32;
    pub const pb_40 = BuilderM.pb_40;
    pub const pb_neg_40 = BuilderM.pb_neg_40;
    pub const pb_48 = BuilderM.pb_48;
    pub const pb_neg_48 = BuilderM.pb_neg_48;
    pub const pb_56 = BuilderM.pb_56;
    pub const pb_neg_56 = BuilderM.pb_neg_56;
    pub const pb_64 = BuilderM.pb_64;
    pub const pb_neg_64 = BuilderM.pb_neg_64;
    pub const pb_72 = BuilderM.pb_72;
    pub const pb_neg_72 = BuilderM.pb_neg_72;
    pub const pb_80 = BuilderM.pb_80;
    pub const pb_neg_80 = BuilderM.pb_neg_80;
    pub const pb_96 = BuilderM.pb_96;
    pub const pb_neg_96 = BuilderM.pb_neg_96;
    pub const pb_112 = BuilderM.pb_112;
    pub const pb_neg_112 = BuilderM.pb_neg_112;
    pub const pb_128 = BuilderM.pb_128;
    pub const pb_neg_128 = BuilderM.pb_neg_128;
    pub const pb_px = BuilderM.pb_px;
    pub const pb_neg_px = BuilderM.pb_neg_px;
    pub const pb_full = BuilderM.pb_full;
    pub const pb_neg_full = BuilderM.pb_neg_full;
    pub const pb_1_2 = BuilderM.pb_1_2;
    pub const pb_neg_1_2 = BuilderM.pb_neg_1_2;
    pub const pb_1_3 = BuilderM.pb_1_3;
    pub const pb_neg_1_3 = BuilderM.pb_neg_1_3;
    pub const pb_2_3 = BuilderM.pb_2_3;
    pub const pb_neg_2_3 = BuilderM.pb_neg_2_3;
    pub const pb_1_4 = BuilderM.pb_1_4;
    pub const pb_neg_1_4 = BuilderM.pb_neg_1_4;
    pub const pb_2_4 = BuilderM.pb_2_4;
    pub const pb_neg_2_4 = BuilderM.pb_neg_2_4;
    pub const pb_3_4 = BuilderM.pb_3_4;
    pub const pb_neg_3_4 = BuilderM.pb_neg_3_4;
    pub const pb_1_5 = BuilderM.pb_1_5;
    pub const pb_neg_1_5 = BuilderM.pb_neg_1_5;
    pub const pb_2_5 = BuilderM.pb_2_5;
    pub const pb_neg_2_5 = BuilderM.pb_neg_2_5;
    pub const pb_3_5 = BuilderM.pb_3_5;
    pub const pb_neg_3_5 = BuilderM.pb_neg_3_5;
    pub const pb_4_5 = BuilderM.pb_4_5;
    pub const pb_neg_4_5 = BuilderM.pb_neg_4_5;
    pub const pb_1_6 = BuilderM.pb_1_6;
    pub const pb_neg_1_6 = BuilderM.pb_neg_1_6;
    pub const pb_5_6 = BuilderM.pb_5_6;
    pub const pb_neg_5_6 = BuilderM.pb_neg_5_6;
    pub const pb_1_12 = BuilderM.pb_1_12;
    pub const pb_neg_1_12 = BuilderM.pb_neg_1_12;
    pub const px = BuilderM.px;
    pub const px_0 = BuilderM.px_0;
    pub const px_neg_0 = BuilderM.px_neg_0;
    pub const px_0p5 = BuilderM.px_0p5;
    pub const px_neg_0p5 = BuilderM.px_neg_0p5;
    pub const px_1 = BuilderM.px_1;
    pub const px_neg_1 = BuilderM.px_neg_1;
    pub const px_1p5 = BuilderM.px_1p5;
    pub const px_neg_1p5 = BuilderM.px_neg_1p5;
    pub const px_2 = BuilderM.px_2;
    pub const px_neg_2 = BuilderM.px_neg_2;
    pub const px_2p5 = BuilderM.px_2p5;
    pub const px_neg_2p5 = BuilderM.px_neg_2p5;
    pub const px_3 = BuilderM.px_3;
    pub const px_neg_3 = BuilderM.px_neg_3;
    pub const px_3p5 = BuilderM.px_3p5;
    pub const px_neg_3p5 = BuilderM.px_neg_3p5;
    pub const px_4 = BuilderM.px_4;
    pub const px_neg_4 = BuilderM.px_neg_4;
    pub const px_5 = BuilderM.px_5;
    pub const px_neg_5 = BuilderM.px_neg_5;
    pub const px_6 = BuilderM.px_6;
    pub const px_neg_6 = BuilderM.px_neg_6;
    pub const px_7 = BuilderM.px_7;
    pub const px_neg_7 = BuilderM.px_neg_7;
    pub const px_8 = BuilderM.px_8;
    pub const px_neg_8 = BuilderM.px_neg_8;
    pub const px_9 = BuilderM.px_9;
    pub const px_neg_9 = BuilderM.px_neg_9;
    pub const px_10 = BuilderM.px_10;
    pub const px_neg_10 = BuilderM.px_neg_10;
    pub const px_11 = BuilderM.px_11;
    pub const px_neg_11 = BuilderM.px_neg_11;
    pub const px_12 = BuilderM.px_12;
    pub const px_neg_12 = BuilderM.px_neg_12;
    pub const px_16 = BuilderM.px_16;
    pub const px_neg_16 = BuilderM.px_neg_16;
    pub const px_20 = BuilderM.px_20;
    pub const px_neg_20 = BuilderM.px_neg_20;
    pub const px_24 = BuilderM.px_24;
    pub const px_neg_24 = BuilderM.px_neg_24;
    pub const px_32 = BuilderM.px_32;
    pub const px_neg_32 = BuilderM.px_neg_32;
    pub const px_40 = BuilderM.px_40;
    pub const px_neg_40 = BuilderM.px_neg_40;
    pub const px_48 = BuilderM.px_48;
    pub const px_neg_48 = BuilderM.px_neg_48;
    pub const px_56 = BuilderM.px_56;
    pub const px_neg_56 = BuilderM.px_neg_56;
    pub const px_64 = BuilderM.px_64;
    pub const px_neg_64 = BuilderM.px_neg_64;
    pub const px_72 = BuilderM.px_72;
    pub const px_neg_72 = BuilderM.px_neg_72;
    pub const px_80 = BuilderM.px_80;
    pub const px_neg_80 = BuilderM.px_neg_80;
    pub const px_96 = BuilderM.px_96;
    pub const px_neg_96 = BuilderM.px_neg_96;
    pub const px_112 = BuilderM.px_112;
    pub const px_neg_112 = BuilderM.px_neg_112;
    pub const px_128 = BuilderM.px_128;
    pub const px_neg_128 = BuilderM.px_neg_128;
    pub const px_px = BuilderM.px_px;
    pub const px_neg_px = BuilderM.px_neg_px;
    pub const px_full = BuilderM.px_full;
    pub const px_neg_full = BuilderM.px_neg_full;
    pub const px_1_2 = BuilderM.px_1_2;
    pub const px_neg_1_2 = BuilderM.px_neg_1_2;
    pub const px_1_3 = BuilderM.px_1_3;
    pub const px_neg_1_3 = BuilderM.px_neg_1_3;
    pub const px_2_3 = BuilderM.px_2_3;
    pub const px_neg_2_3 = BuilderM.px_neg_2_3;
    pub const px_1_4 = BuilderM.px_1_4;
    pub const px_neg_1_4 = BuilderM.px_neg_1_4;
    pub const px_2_4 = BuilderM.px_2_4;
    pub const px_neg_2_4 = BuilderM.px_neg_2_4;
    pub const px_3_4 = BuilderM.px_3_4;
    pub const px_neg_3_4 = BuilderM.px_neg_3_4;
    pub const px_1_5 = BuilderM.px_1_5;
    pub const px_neg_1_5 = BuilderM.px_neg_1_5;
    pub const px_2_5 = BuilderM.px_2_5;
    pub const px_neg_2_5 = BuilderM.px_neg_2_5;
    pub const px_3_5 = BuilderM.px_3_5;
    pub const px_neg_3_5 = BuilderM.px_neg_3_5;
    pub const px_4_5 = BuilderM.px_4_5;
    pub const px_neg_4_5 = BuilderM.px_neg_4_5;
    pub const px_1_6 = BuilderM.px_1_6;
    pub const px_neg_1_6 = BuilderM.px_neg_1_6;
    pub const px_5_6 = BuilderM.px_5_6;
    pub const px_neg_5_6 = BuilderM.px_neg_5_6;
    pub const px_1_12 = BuilderM.px_1_12;
    pub const px_neg_1_12 = BuilderM.px_neg_1_12;
    pub const py = BuilderM.py;
    pub const py_0 = BuilderM.py_0;
    pub const py_neg_0 = BuilderM.py_neg_0;
    pub const py_0p5 = BuilderM.py_0p5;
    pub const py_neg_0p5 = BuilderM.py_neg_0p5;
    pub const py_1 = BuilderM.py_1;
    pub const py_neg_1 = BuilderM.py_neg_1;
    pub const py_1p5 = BuilderM.py_1p5;
    pub const py_neg_1p5 = BuilderM.py_neg_1p5;
    pub const py_2 = BuilderM.py_2;
    pub const py_neg_2 = BuilderM.py_neg_2;
    pub const py_2p5 = BuilderM.py_2p5;
    pub const py_neg_2p5 = BuilderM.py_neg_2p5;
    pub const py_3 = BuilderM.py_3;
    pub const py_neg_3 = BuilderM.py_neg_3;
    pub const py_3p5 = BuilderM.py_3p5;
    pub const py_neg_3p5 = BuilderM.py_neg_3p5;
    pub const py_4 = BuilderM.py_4;
    pub const py_neg_4 = BuilderM.py_neg_4;
    pub const py_5 = BuilderM.py_5;
    pub const py_neg_5 = BuilderM.py_neg_5;
    pub const py_6 = BuilderM.py_6;
    pub const py_neg_6 = BuilderM.py_neg_6;
    pub const py_7 = BuilderM.py_7;
    pub const py_neg_7 = BuilderM.py_neg_7;
    pub const py_8 = BuilderM.py_8;
    pub const py_neg_8 = BuilderM.py_neg_8;
    pub const py_9 = BuilderM.py_9;
    pub const py_neg_9 = BuilderM.py_neg_9;
    pub const py_10 = BuilderM.py_10;
    pub const py_neg_10 = BuilderM.py_neg_10;
    pub const py_11 = BuilderM.py_11;
    pub const py_neg_11 = BuilderM.py_neg_11;
    pub const py_12 = BuilderM.py_12;
    pub const py_neg_12 = BuilderM.py_neg_12;
    pub const py_16 = BuilderM.py_16;
    pub const py_neg_16 = BuilderM.py_neg_16;
    pub const py_20 = BuilderM.py_20;
    pub const py_neg_20 = BuilderM.py_neg_20;
    pub const py_24 = BuilderM.py_24;
    pub const py_neg_24 = BuilderM.py_neg_24;
    pub const py_32 = BuilderM.py_32;
    pub const py_neg_32 = BuilderM.py_neg_32;
    pub const py_40 = BuilderM.py_40;
    pub const py_neg_40 = BuilderM.py_neg_40;
    pub const py_48 = BuilderM.py_48;
    pub const py_neg_48 = BuilderM.py_neg_48;
    pub const py_56 = BuilderM.py_56;
    pub const py_neg_56 = BuilderM.py_neg_56;
    pub const py_64 = BuilderM.py_64;
    pub const py_neg_64 = BuilderM.py_neg_64;
    pub const py_72 = BuilderM.py_72;
    pub const py_neg_72 = BuilderM.py_neg_72;
    pub const py_80 = BuilderM.py_80;
    pub const py_neg_80 = BuilderM.py_neg_80;
    pub const py_96 = BuilderM.py_96;
    pub const py_neg_96 = BuilderM.py_neg_96;
    pub const py_112 = BuilderM.py_112;
    pub const py_neg_112 = BuilderM.py_neg_112;
    pub const py_128 = BuilderM.py_128;
    pub const py_neg_128 = BuilderM.py_neg_128;
    pub const py_px = BuilderM.py_px;
    pub const py_neg_px = BuilderM.py_neg_px;
    pub const py_full = BuilderM.py_full;
    pub const py_neg_full = BuilderM.py_neg_full;
    pub const py_1_2 = BuilderM.py_1_2;
    pub const py_neg_1_2 = BuilderM.py_neg_1_2;
    pub const py_1_3 = BuilderM.py_1_3;
    pub const py_neg_1_3 = BuilderM.py_neg_1_3;
    pub const py_2_3 = BuilderM.py_2_3;
    pub const py_neg_2_3 = BuilderM.py_neg_2_3;
    pub const py_1_4 = BuilderM.py_1_4;
    pub const py_neg_1_4 = BuilderM.py_neg_1_4;
    pub const py_2_4 = BuilderM.py_2_4;
    pub const py_neg_2_4 = BuilderM.py_neg_2_4;
    pub const py_3_4 = BuilderM.py_3_4;
    pub const py_neg_3_4 = BuilderM.py_neg_3_4;
    pub const py_1_5 = BuilderM.py_1_5;
    pub const py_neg_1_5 = BuilderM.py_neg_1_5;
    pub const py_2_5 = BuilderM.py_2_5;
    pub const py_neg_2_5 = BuilderM.py_neg_2_5;
    pub const py_3_5 = BuilderM.py_3_5;
    pub const py_neg_3_5 = BuilderM.py_neg_3_5;
    pub const py_4_5 = BuilderM.py_4_5;
    pub const py_neg_4_5 = BuilderM.py_neg_4_5;
    pub const py_1_6 = BuilderM.py_1_6;
    pub const py_neg_1_6 = BuilderM.py_neg_1_6;
    pub const py_5_6 = BuilderM.py_5_6;
    pub const py_neg_5_6 = BuilderM.py_neg_5_6;
    pub const py_1_12 = BuilderM.py_1_12;
    pub const py_neg_1_12 = BuilderM.py_neg_1_12;
    pub const pl = BuilderM.pl;
    pub const pl_0 = BuilderM.pl_0;
    pub const pl_neg_0 = BuilderM.pl_neg_0;
    pub const pl_0p5 = BuilderM.pl_0p5;
    pub const pl_neg_0p5 = BuilderM.pl_neg_0p5;
    pub const pl_1 = BuilderM.pl_1;
    pub const pl_neg_1 = BuilderM.pl_neg_1;
    pub const pl_1p5 = BuilderM.pl_1p5;
    pub const pl_neg_1p5 = BuilderM.pl_neg_1p5;
    pub const pl_2 = BuilderM.pl_2;
    pub const pl_neg_2 = BuilderM.pl_neg_2;
    pub const pl_2p5 = BuilderM.pl_2p5;
    pub const pl_neg_2p5 = BuilderM.pl_neg_2p5;
    pub const pl_3 = BuilderM.pl_3;
    pub const pl_neg_3 = BuilderM.pl_neg_3;
    pub const pl_3p5 = BuilderM.pl_3p5;
    pub const pl_neg_3p5 = BuilderM.pl_neg_3p5;
    pub const pl_4 = BuilderM.pl_4;
    pub const pl_neg_4 = BuilderM.pl_neg_4;
    pub const pl_5 = BuilderM.pl_5;
    pub const pl_neg_5 = BuilderM.pl_neg_5;
    pub const pl_6 = BuilderM.pl_6;
    pub const pl_neg_6 = BuilderM.pl_neg_6;
    pub const pl_7 = BuilderM.pl_7;
    pub const pl_neg_7 = BuilderM.pl_neg_7;
    pub const pl_8 = BuilderM.pl_8;
    pub const pl_neg_8 = BuilderM.pl_neg_8;
    pub const pl_9 = BuilderM.pl_9;
    pub const pl_neg_9 = BuilderM.pl_neg_9;
    pub const pl_10 = BuilderM.pl_10;
    pub const pl_neg_10 = BuilderM.pl_neg_10;
    pub const pl_11 = BuilderM.pl_11;
    pub const pl_neg_11 = BuilderM.pl_neg_11;
    pub const pl_12 = BuilderM.pl_12;
    pub const pl_neg_12 = BuilderM.pl_neg_12;
    pub const pl_16 = BuilderM.pl_16;
    pub const pl_neg_16 = BuilderM.pl_neg_16;
    pub const pl_20 = BuilderM.pl_20;
    pub const pl_neg_20 = BuilderM.pl_neg_20;
    pub const pl_24 = BuilderM.pl_24;
    pub const pl_neg_24 = BuilderM.pl_neg_24;
    pub const pl_32 = BuilderM.pl_32;
    pub const pl_neg_32 = BuilderM.pl_neg_32;
    pub const pl_40 = BuilderM.pl_40;
    pub const pl_neg_40 = BuilderM.pl_neg_40;
    pub const pl_48 = BuilderM.pl_48;
    pub const pl_neg_48 = BuilderM.pl_neg_48;
    pub const pl_56 = BuilderM.pl_56;
    pub const pl_neg_56 = BuilderM.pl_neg_56;
    pub const pl_64 = BuilderM.pl_64;
    pub const pl_neg_64 = BuilderM.pl_neg_64;
    pub const pl_72 = BuilderM.pl_72;
    pub const pl_neg_72 = BuilderM.pl_neg_72;
    pub const pl_80 = BuilderM.pl_80;
    pub const pl_neg_80 = BuilderM.pl_neg_80;
    pub const pl_96 = BuilderM.pl_96;
    pub const pl_neg_96 = BuilderM.pl_neg_96;
    pub const pl_112 = BuilderM.pl_112;
    pub const pl_neg_112 = BuilderM.pl_neg_112;
    pub const pl_128 = BuilderM.pl_128;
    pub const pl_neg_128 = BuilderM.pl_neg_128;
    pub const pl_px = BuilderM.pl_px;
    pub const pl_neg_px = BuilderM.pl_neg_px;
    pub const pl_full = BuilderM.pl_full;
    pub const pl_neg_full = BuilderM.pl_neg_full;
    pub const pl_1_2 = BuilderM.pl_1_2;
    pub const pl_neg_1_2 = BuilderM.pl_neg_1_2;
    pub const pl_1_3 = BuilderM.pl_1_3;
    pub const pl_neg_1_3 = BuilderM.pl_neg_1_3;
    pub const pl_2_3 = BuilderM.pl_2_3;
    pub const pl_neg_2_3 = BuilderM.pl_neg_2_3;
    pub const pl_1_4 = BuilderM.pl_1_4;
    pub const pl_neg_1_4 = BuilderM.pl_neg_1_4;
    pub const pl_2_4 = BuilderM.pl_2_4;
    pub const pl_neg_2_4 = BuilderM.pl_neg_2_4;
    pub const pl_3_4 = BuilderM.pl_3_4;
    pub const pl_neg_3_4 = BuilderM.pl_neg_3_4;
    pub const pl_1_5 = BuilderM.pl_1_5;
    pub const pl_neg_1_5 = BuilderM.pl_neg_1_5;
    pub const pl_2_5 = BuilderM.pl_2_5;
    pub const pl_neg_2_5 = BuilderM.pl_neg_2_5;
    pub const pl_3_5 = BuilderM.pl_3_5;
    pub const pl_neg_3_5 = BuilderM.pl_neg_3_5;
    pub const pl_4_5 = BuilderM.pl_4_5;
    pub const pl_neg_4_5 = BuilderM.pl_neg_4_5;
    pub const pl_1_6 = BuilderM.pl_1_6;
    pub const pl_neg_1_6 = BuilderM.pl_neg_1_6;
    pub const pl_5_6 = BuilderM.pl_5_6;
    pub const pl_neg_5_6 = BuilderM.pl_neg_5_6;
    pub const pl_1_12 = BuilderM.pl_1_12;
    pub const pl_neg_1_12 = BuilderM.pl_neg_1_12;
    pub const pr = BuilderM.pr;
    pub const pr_0 = BuilderM.pr_0;
    pub const pr_neg_0 = BuilderM.pr_neg_0;
    pub const pr_0p5 = BuilderM.pr_0p5;
    pub const pr_neg_0p5 = BuilderM.pr_neg_0p5;
    pub const pr_1 = BuilderM.pr_1;
    pub const pr_neg_1 = BuilderM.pr_neg_1;
    pub const pr_1p5 = BuilderM.pr_1p5;
    pub const pr_neg_1p5 = BuilderM.pr_neg_1p5;
    pub const pr_2 = BuilderM.pr_2;
    pub const pr_neg_2 = BuilderM.pr_neg_2;
    pub const pr_2p5 = BuilderM.pr_2p5;
    pub const pr_neg_2p5 = BuilderM.pr_neg_2p5;
    pub const pr_3 = BuilderM.pr_3;
    pub const pr_neg_3 = BuilderM.pr_neg_3;
    pub const pr_3p5 = BuilderM.pr_3p5;
    pub const pr_neg_3p5 = BuilderM.pr_neg_3p5;
    pub const pr_4 = BuilderM.pr_4;
    pub const pr_neg_4 = BuilderM.pr_neg_4;
    pub const pr_5 = BuilderM.pr_5;
    pub const pr_neg_5 = BuilderM.pr_neg_5;
    pub const pr_6 = BuilderM.pr_6;
    pub const pr_neg_6 = BuilderM.pr_neg_6;
    pub const pr_7 = BuilderM.pr_7;
    pub const pr_neg_7 = BuilderM.pr_neg_7;
    pub const pr_8 = BuilderM.pr_8;
    pub const pr_neg_8 = BuilderM.pr_neg_8;
    pub const pr_9 = BuilderM.pr_9;
    pub const pr_neg_9 = BuilderM.pr_neg_9;
    pub const pr_10 = BuilderM.pr_10;
    pub const pr_neg_10 = BuilderM.pr_neg_10;
    pub const pr_11 = BuilderM.pr_11;
    pub const pr_neg_11 = BuilderM.pr_neg_11;
    pub const pr_12 = BuilderM.pr_12;
    pub const pr_neg_12 = BuilderM.pr_neg_12;
    pub const pr_16 = BuilderM.pr_16;
    pub const pr_neg_16 = BuilderM.pr_neg_16;
    pub const pr_20 = BuilderM.pr_20;
    pub const pr_neg_20 = BuilderM.pr_neg_20;
    pub const pr_24 = BuilderM.pr_24;
    pub const pr_neg_24 = BuilderM.pr_neg_24;
    pub const pr_32 = BuilderM.pr_32;
    pub const pr_neg_32 = BuilderM.pr_neg_32;
    pub const pr_40 = BuilderM.pr_40;
    pub const pr_neg_40 = BuilderM.pr_neg_40;
    pub const pr_48 = BuilderM.pr_48;
    pub const pr_neg_48 = BuilderM.pr_neg_48;
    pub const pr_56 = BuilderM.pr_56;
    pub const pr_neg_56 = BuilderM.pr_neg_56;
    pub const pr_64 = BuilderM.pr_64;
    pub const pr_neg_64 = BuilderM.pr_neg_64;
    pub const pr_72 = BuilderM.pr_72;
    pub const pr_neg_72 = BuilderM.pr_neg_72;
    pub const pr_80 = BuilderM.pr_80;
    pub const pr_neg_80 = BuilderM.pr_neg_80;
    pub const pr_96 = BuilderM.pr_96;
    pub const pr_neg_96 = BuilderM.pr_neg_96;
    pub const pr_112 = BuilderM.pr_112;
    pub const pr_neg_112 = BuilderM.pr_neg_112;
    pub const pr_128 = BuilderM.pr_128;
    pub const pr_neg_128 = BuilderM.pr_neg_128;
    pub const pr_px = BuilderM.pr_px;
    pub const pr_neg_px = BuilderM.pr_neg_px;
    pub const pr_full = BuilderM.pr_full;
    pub const pr_neg_full = BuilderM.pr_neg_full;
    pub const pr_1_2 = BuilderM.pr_1_2;
    pub const pr_neg_1_2 = BuilderM.pr_neg_1_2;
    pub const pr_1_3 = BuilderM.pr_1_3;
    pub const pr_neg_1_3 = BuilderM.pr_neg_1_3;
    pub const pr_2_3 = BuilderM.pr_2_3;
    pub const pr_neg_2_3 = BuilderM.pr_neg_2_3;
    pub const pr_1_4 = BuilderM.pr_1_4;
    pub const pr_neg_1_4 = BuilderM.pr_neg_1_4;
    pub const pr_2_4 = BuilderM.pr_2_4;
    pub const pr_neg_2_4 = BuilderM.pr_neg_2_4;
    pub const pr_3_4 = BuilderM.pr_3_4;
    pub const pr_neg_3_4 = BuilderM.pr_neg_3_4;
    pub const pr_1_5 = BuilderM.pr_1_5;
    pub const pr_neg_1_5 = BuilderM.pr_neg_1_5;
    pub const pr_2_5 = BuilderM.pr_2_5;
    pub const pr_neg_2_5 = BuilderM.pr_neg_2_5;
    pub const pr_3_5 = BuilderM.pr_3_5;
    pub const pr_neg_3_5 = BuilderM.pr_neg_3_5;
    pub const pr_4_5 = BuilderM.pr_4_5;
    pub const pr_neg_4_5 = BuilderM.pr_neg_4_5;
    pub const pr_1_6 = BuilderM.pr_1_6;
    pub const pr_neg_1_6 = BuilderM.pr_neg_1_6;
    pub const pr_5_6 = BuilderM.pr_5_6;
    pub const pr_neg_5_6 = BuilderM.pr_neg_5_6;
    pub const pr_1_12 = BuilderM.pr_1_12;
    pub const pr_neg_1_12 = BuilderM.pr_neg_1_12;
    pub const inset = BuilderM.inset;
    pub const inset_0 = BuilderM.inset_0;
    pub const inset_neg_0 = BuilderM.inset_neg_0;
    pub const inset_0p5 = BuilderM.inset_0p5;
    pub const inset_neg_0p5 = BuilderM.inset_neg_0p5;
    pub const inset_1 = BuilderM.inset_1;
    pub const inset_neg_1 = BuilderM.inset_neg_1;
    pub const inset_1p5 = BuilderM.inset_1p5;
    pub const inset_neg_1p5 = BuilderM.inset_neg_1p5;
    pub const inset_2 = BuilderM.inset_2;
    pub const inset_neg_2 = BuilderM.inset_neg_2;
    pub const inset_2p5 = BuilderM.inset_2p5;
    pub const inset_neg_2p5 = BuilderM.inset_neg_2p5;
    pub const inset_3 = BuilderM.inset_3;
    pub const inset_neg_3 = BuilderM.inset_neg_3;
    pub const inset_3p5 = BuilderM.inset_3p5;
    pub const inset_neg_3p5 = BuilderM.inset_neg_3p5;
    pub const inset_4 = BuilderM.inset_4;
    pub const inset_neg_4 = BuilderM.inset_neg_4;
    pub const inset_5 = BuilderM.inset_5;
    pub const inset_neg_5 = BuilderM.inset_neg_5;
    pub const inset_6 = BuilderM.inset_6;
    pub const inset_neg_6 = BuilderM.inset_neg_6;
    pub const inset_7 = BuilderM.inset_7;
    pub const inset_neg_7 = BuilderM.inset_neg_7;
    pub const inset_8 = BuilderM.inset_8;
    pub const inset_neg_8 = BuilderM.inset_neg_8;
    pub const inset_9 = BuilderM.inset_9;
    pub const inset_neg_9 = BuilderM.inset_neg_9;
    pub const inset_10 = BuilderM.inset_10;
    pub const inset_neg_10 = BuilderM.inset_neg_10;
    pub const inset_11 = BuilderM.inset_11;
    pub const inset_neg_11 = BuilderM.inset_neg_11;
    pub const inset_12 = BuilderM.inset_12;
    pub const inset_neg_12 = BuilderM.inset_neg_12;
    pub const inset_16 = BuilderM.inset_16;
    pub const inset_neg_16 = BuilderM.inset_neg_16;
    pub const inset_20 = BuilderM.inset_20;
    pub const inset_neg_20 = BuilderM.inset_neg_20;
    pub const inset_24 = BuilderM.inset_24;
    pub const inset_neg_24 = BuilderM.inset_neg_24;
    pub const inset_32 = BuilderM.inset_32;
    pub const inset_neg_32 = BuilderM.inset_neg_32;
    pub const inset_40 = BuilderM.inset_40;
    pub const inset_neg_40 = BuilderM.inset_neg_40;
    pub const inset_48 = BuilderM.inset_48;
    pub const inset_neg_48 = BuilderM.inset_neg_48;
    pub const inset_56 = BuilderM.inset_56;
    pub const inset_neg_56 = BuilderM.inset_neg_56;
    pub const inset_64 = BuilderM.inset_64;
    pub const inset_neg_64 = BuilderM.inset_neg_64;
    pub const inset_72 = BuilderM.inset_72;
    pub const inset_neg_72 = BuilderM.inset_neg_72;
    pub const inset_80 = BuilderM.inset_80;
    pub const inset_neg_80 = BuilderM.inset_neg_80;
    pub const inset_96 = BuilderM.inset_96;
    pub const inset_neg_96 = BuilderM.inset_neg_96;
    pub const inset_112 = BuilderM.inset_112;
    pub const inset_neg_112 = BuilderM.inset_neg_112;
    pub const inset_128 = BuilderM.inset_128;
    pub const inset_neg_128 = BuilderM.inset_neg_128;
    pub const inset_auto = BuilderM.inset_auto;
    pub const inset_px = BuilderM.inset_px;
    pub const inset_neg_px = BuilderM.inset_neg_px;
    pub const inset_full = BuilderM.inset_full;
    pub const inset_neg_full = BuilderM.inset_neg_full;
    pub const inset_1_2 = BuilderM.inset_1_2;
    pub const inset_neg_1_2 = BuilderM.inset_neg_1_2;
    pub const inset_1_3 = BuilderM.inset_1_3;
    pub const inset_neg_1_3 = BuilderM.inset_neg_1_3;
    pub const inset_2_3 = BuilderM.inset_2_3;
    pub const inset_neg_2_3 = BuilderM.inset_neg_2_3;
    pub const inset_1_4 = BuilderM.inset_1_4;
    pub const inset_neg_1_4 = BuilderM.inset_neg_1_4;
    pub const inset_2_4 = BuilderM.inset_2_4;
    pub const inset_neg_2_4 = BuilderM.inset_neg_2_4;
    pub const inset_3_4 = BuilderM.inset_3_4;
    pub const inset_neg_3_4 = BuilderM.inset_neg_3_4;
    pub const inset_1_5 = BuilderM.inset_1_5;
    pub const inset_neg_1_5 = BuilderM.inset_neg_1_5;
    pub const inset_2_5 = BuilderM.inset_2_5;
    pub const inset_neg_2_5 = BuilderM.inset_neg_2_5;
    pub const inset_3_5 = BuilderM.inset_3_5;
    pub const inset_neg_3_5 = BuilderM.inset_neg_3_5;
    pub const inset_4_5 = BuilderM.inset_4_5;
    pub const inset_neg_4_5 = BuilderM.inset_neg_4_5;
    pub const inset_1_6 = BuilderM.inset_1_6;
    pub const inset_neg_1_6 = BuilderM.inset_neg_1_6;
    pub const inset_5_6 = BuilderM.inset_5_6;
    pub const inset_neg_5_6 = BuilderM.inset_neg_5_6;
    pub const inset_1_12 = BuilderM.inset_1_12;
    pub const inset_neg_1_12 = BuilderM.inset_neg_1_12;
    pub const top = BuilderM.top;
    pub const top_0 = BuilderM.top_0;
    pub const top_neg_0 = BuilderM.top_neg_0;
    pub const top_0p5 = BuilderM.top_0p5;
    pub const top_neg_0p5 = BuilderM.top_neg_0p5;
    pub const top_1 = BuilderM.top_1;
    pub const top_neg_1 = BuilderM.top_neg_1;
    pub const top_1p5 = BuilderM.top_1p5;
    pub const top_neg_1p5 = BuilderM.top_neg_1p5;
    pub const top_2 = BuilderM.top_2;
    pub const top_neg_2 = BuilderM.top_neg_2;
    pub const top_2p5 = BuilderM.top_2p5;
    pub const top_neg_2p5 = BuilderM.top_neg_2p5;
    pub const top_3 = BuilderM.top_3;
    pub const top_neg_3 = BuilderM.top_neg_3;
    pub const top_3p5 = BuilderM.top_3p5;
    pub const top_neg_3p5 = BuilderM.top_neg_3p5;
    pub const top_4 = BuilderM.top_4;
    pub const top_neg_4 = BuilderM.top_neg_4;
    pub const top_5 = BuilderM.top_5;
    pub const top_neg_5 = BuilderM.top_neg_5;
    pub const top_6 = BuilderM.top_6;
    pub const top_neg_6 = BuilderM.top_neg_6;
    pub const top_7 = BuilderM.top_7;
    pub const top_neg_7 = BuilderM.top_neg_7;
    pub const top_8 = BuilderM.top_8;
    pub const top_neg_8 = BuilderM.top_neg_8;
    pub const top_9 = BuilderM.top_9;
    pub const top_neg_9 = BuilderM.top_neg_9;
    pub const top_10 = BuilderM.top_10;
    pub const top_neg_10 = BuilderM.top_neg_10;
    pub const top_11 = BuilderM.top_11;
    pub const top_neg_11 = BuilderM.top_neg_11;
    pub const top_12 = BuilderM.top_12;
    pub const top_neg_12 = BuilderM.top_neg_12;
    pub const top_16 = BuilderM.top_16;
    pub const top_neg_16 = BuilderM.top_neg_16;
    pub const top_20 = BuilderM.top_20;
    pub const top_neg_20 = BuilderM.top_neg_20;
    pub const top_24 = BuilderM.top_24;
    pub const top_neg_24 = BuilderM.top_neg_24;
    pub const top_32 = BuilderM.top_32;
    pub const top_neg_32 = BuilderM.top_neg_32;
    pub const top_40 = BuilderM.top_40;
    pub const top_neg_40 = BuilderM.top_neg_40;
    pub const top_48 = BuilderM.top_48;
    pub const top_neg_48 = BuilderM.top_neg_48;
    pub const top_56 = BuilderM.top_56;
    pub const top_neg_56 = BuilderM.top_neg_56;
    pub const top_64 = BuilderM.top_64;
    pub const top_neg_64 = BuilderM.top_neg_64;
    pub const top_72 = BuilderM.top_72;
    pub const top_neg_72 = BuilderM.top_neg_72;
    pub const top_80 = BuilderM.top_80;
    pub const top_neg_80 = BuilderM.top_neg_80;
    pub const top_96 = BuilderM.top_96;
    pub const top_neg_96 = BuilderM.top_neg_96;
    pub const top_112 = BuilderM.top_112;
    pub const top_neg_112 = BuilderM.top_neg_112;
    pub const top_128 = BuilderM.top_128;
    pub const top_neg_128 = BuilderM.top_neg_128;
    pub const top_auto = BuilderM.top_auto;
    pub const top_px = BuilderM.top_px;
    pub const top_neg_px = BuilderM.top_neg_px;
    pub const top_full = BuilderM.top_full;
    pub const top_neg_full = BuilderM.top_neg_full;
    pub const top_1_2 = BuilderM.top_1_2;
    pub const top_neg_1_2 = BuilderM.top_neg_1_2;
    pub const top_1_3 = BuilderM.top_1_3;
    pub const top_neg_1_3 = BuilderM.top_neg_1_3;
    pub const top_2_3 = BuilderM.top_2_3;
    pub const top_neg_2_3 = BuilderM.top_neg_2_3;
    pub const top_1_4 = BuilderM.top_1_4;
    pub const top_neg_1_4 = BuilderM.top_neg_1_4;
    pub const top_2_4 = BuilderM.top_2_4;
    pub const top_neg_2_4 = BuilderM.top_neg_2_4;
    pub const top_3_4 = BuilderM.top_3_4;
    pub const top_neg_3_4 = BuilderM.top_neg_3_4;
    pub const top_1_5 = BuilderM.top_1_5;
    pub const top_neg_1_5 = BuilderM.top_neg_1_5;
    pub const top_2_5 = BuilderM.top_2_5;
    pub const top_neg_2_5 = BuilderM.top_neg_2_5;
    pub const top_3_5 = BuilderM.top_3_5;
    pub const top_neg_3_5 = BuilderM.top_neg_3_5;
    pub const top_4_5 = BuilderM.top_4_5;
    pub const top_neg_4_5 = BuilderM.top_neg_4_5;
    pub const top_1_6 = BuilderM.top_1_6;
    pub const top_neg_1_6 = BuilderM.top_neg_1_6;
    pub const top_5_6 = BuilderM.top_5_6;
    pub const top_neg_5_6 = BuilderM.top_neg_5_6;
    pub const top_1_12 = BuilderM.top_1_12;
    pub const top_neg_1_12 = BuilderM.top_neg_1_12;
    pub const bottom = BuilderM.bottom;
    pub const bottom_0 = BuilderM.bottom_0;
    pub const bottom_neg_0 = BuilderM.bottom_neg_0;
    pub const bottom_0p5 = BuilderM.bottom_0p5;
    pub const bottom_neg_0p5 = BuilderM.bottom_neg_0p5;
    pub const bottom_1 = BuilderM.bottom_1;
    pub const bottom_neg_1 = BuilderM.bottom_neg_1;
    pub const bottom_1p5 = BuilderM.bottom_1p5;
    pub const bottom_neg_1p5 = BuilderM.bottom_neg_1p5;
    pub const bottom_2 = BuilderM.bottom_2;
    pub const bottom_neg_2 = BuilderM.bottom_neg_2;
    pub const bottom_2p5 = BuilderM.bottom_2p5;
    pub const bottom_neg_2p5 = BuilderM.bottom_neg_2p5;
    pub const bottom_3 = BuilderM.bottom_3;
    pub const bottom_neg_3 = BuilderM.bottom_neg_3;
    pub const bottom_3p5 = BuilderM.bottom_3p5;
    pub const bottom_neg_3p5 = BuilderM.bottom_neg_3p5;
    pub const bottom_4 = BuilderM.bottom_4;
    pub const bottom_neg_4 = BuilderM.bottom_neg_4;
    pub const bottom_5 = BuilderM.bottom_5;
    pub const bottom_neg_5 = BuilderM.bottom_neg_5;
    pub const bottom_6 = BuilderM.bottom_6;
    pub const bottom_neg_6 = BuilderM.bottom_neg_6;
    pub const bottom_7 = BuilderM.bottom_7;
    pub const bottom_neg_7 = BuilderM.bottom_neg_7;
    pub const bottom_8 = BuilderM.bottom_8;
    pub const bottom_neg_8 = BuilderM.bottom_neg_8;
    pub const bottom_9 = BuilderM.bottom_9;
    pub const bottom_neg_9 = BuilderM.bottom_neg_9;
    pub const bottom_10 = BuilderM.bottom_10;
    pub const bottom_neg_10 = BuilderM.bottom_neg_10;
    pub const bottom_11 = BuilderM.bottom_11;
    pub const bottom_neg_11 = BuilderM.bottom_neg_11;
    pub const bottom_12 = BuilderM.bottom_12;
    pub const bottom_neg_12 = BuilderM.bottom_neg_12;
    pub const bottom_16 = BuilderM.bottom_16;
    pub const bottom_neg_16 = BuilderM.bottom_neg_16;
    pub const bottom_20 = BuilderM.bottom_20;
    pub const bottom_neg_20 = BuilderM.bottom_neg_20;
    pub const bottom_24 = BuilderM.bottom_24;
    pub const bottom_neg_24 = BuilderM.bottom_neg_24;
    pub const bottom_32 = BuilderM.bottom_32;
    pub const bottom_neg_32 = BuilderM.bottom_neg_32;
    pub const bottom_40 = BuilderM.bottom_40;
    pub const bottom_neg_40 = BuilderM.bottom_neg_40;
    pub const bottom_48 = BuilderM.bottom_48;
    pub const bottom_neg_48 = BuilderM.bottom_neg_48;
    pub const bottom_56 = BuilderM.bottom_56;
    pub const bottom_neg_56 = BuilderM.bottom_neg_56;
    pub const bottom_64 = BuilderM.bottom_64;
    pub const bottom_neg_64 = BuilderM.bottom_neg_64;
    pub const bottom_72 = BuilderM.bottom_72;
    pub const bottom_neg_72 = BuilderM.bottom_neg_72;
    pub const bottom_80 = BuilderM.bottom_80;
    pub const bottom_neg_80 = BuilderM.bottom_neg_80;
    pub const bottom_96 = BuilderM.bottom_96;
    pub const bottom_neg_96 = BuilderM.bottom_neg_96;
    pub const bottom_112 = BuilderM.bottom_112;
    pub const bottom_neg_112 = BuilderM.bottom_neg_112;
    pub const bottom_128 = BuilderM.bottom_128;
    pub const bottom_neg_128 = BuilderM.bottom_neg_128;
    pub const bottom_auto = BuilderM.bottom_auto;
    pub const bottom_px = BuilderM.bottom_px;
    pub const bottom_neg_px = BuilderM.bottom_neg_px;
    pub const bottom_full = BuilderM.bottom_full;
    pub const bottom_neg_full = BuilderM.bottom_neg_full;
    pub const bottom_1_2 = BuilderM.bottom_1_2;
    pub const bottom_neg_1_2 = BuilderM.bottom_neg_1_2;
    pub const bottom_1_3 = BuilderM.bottom_1_3;
    pub const bottom_neg_1_3 = BuilderM.bottom_neg_1_3;
    pub const bottom_2_3 = BuilderM.bottom_2_3;
    pub const bottom_neg_2_3 = BuilderM.bottom_neg_2_3;
    pub const bottom_1_4 = BuilderM.bottom_1_4;
    pub const bottom_neg_1_4 = BuilderM.bottom_neg_1_4;
    pub const bottom_2_4 = BuilderM.bottom_2_4;
    pub const bottom_neg_2_4 = BuilderM.bottom_neg_2_4;
    pub const bottom_3_4 = BuilderM.bottom_3_4;
    pub const bottom_neg_3_4 = BuilderM.bottom_neg_3_4;
    pub const bottom_1_5 = BuilderM.bottom_1_5;
    pub const bottom_neg_1_5 = BuilderM.bottom_neg_1_5;
    pub const bottom_2_5 = BuilderM.bottom_2_5;
    pub const bottom_neg_2_5 = BuilderM.bottom_neg_2_5;
    pub const bottom_3_5 = BuilderM.bottom_3_5;
    pub const bottom_neg_3_5 = BuilderM.bottom_neg_3_5;
    pub const bottom_4_5 = BuilderM.bottom_4_5;
    pub const bottom_neg_4_5 = BuilderM.bottom_neg_4_5;
    pub const bottom_1_6 = BuilderM.bottom_1_6;
    pub const bottom_neg_1_6 = BuilderM.bottom_neg_1_6;
    pub const bottom_5_6 = BuilderM.bottom_5_6;
    pub const bottom_neg_5_6 = BuilderM.bottom_neg_5_6;
    pub const bottom_1_12 = BuilderM.bottom_1_12;
    pub const bottom_neg_1_12 = BuilderM.bottom_neg_1_12;
    pub const left = BuilderM.left;
    pub const left_0 = BuilderM.left_0;
    pub const left_neg_0 = BuilderM.left_neg_0;
    pub const left_0p5 = BuilderM.left_0p5;
    pub const left_neg_0p5 = BuilderM.left_neg_0p5;
    pub const left_1 = BuilderM.left_1;
    pub const left_neg_1 = BuilderM.left_neg_1;
    pub const left_1p5 = BuilderM.left_1p5;
    pub const left_neg_1p5 = BuilderM.left_neg_1p5;
    pub const left_2 = BuilderM.left_2;
    pub const left_neg_2 = BuilderM.left_neg_2;
    pub const left_2p5 = BuilderM.left_2p5;
    pub const left_neg_2p5 = BuilderM.left_neg_2p5;
    pub const left_3 = BuilderM.left_3;
    pub const left_neg_3 = BuilderM.left_neg_3;
    pub const left_3p5 = BuilderM.left_3p5;
    pub const left_neg_3p5 = BuilderM.left_neg_3p5;
    pub const left_4 = BuilderM.left_4;
    pub const left_neg_4 = BuilderM.left_neg_4;
    pub const left_5 = BuilderM.left_5;
    pub const left_neg_5 = BuilderM.left_neg_5;
    pub const left_6 = BuilderM.left_6;
    pub const left_neg_6 = BuilderM.left_neg_6;
    pub const left_7 = BuilderM.left_7;
    pub const left_neg_7 = BuilderM.left_neg_7;
    pub const left_8 = BuilderM.left_8;
    pub const left_neg_8 = BuilderM.left_neg_8;
    pub const left_9 = BuilderM.left_9;
    pub const left_neg_9 = BuilderM.left_neg_9;
    pub const left_10 = BuilderM.left_10;
    pub const left_neg_10 = BuilderM.left_neg_10;
    pub const left_11 = BuilderM.left_11;
    pub const left_neg_11 = BuilderM.left_neg_11;
    pub const left_12 = BuilderM.left_12;
    pub const left_neg_12 = BuilderM.left_neg_12;
    pub const left_16 = BuilderM.left_16;
    pub const left_neg_16 = BuilderM.left_neg_16;
    pub const left_20 = BuilderM.left_20;
    pub const left_neg_20 = BuilderM.left_neg_20;
    pub const left_24 = BuilderM.left_24;
    pub const left_neg_24 = BuilderM.left_neg_24;
    pub const left_32 = BuilderM.left_32;
    pub const left_neg_32 = BuilderM.left_neg_32;
    pub const left_40 = BuilderM.left_40;
    pub const left_neg_40 = BuilderM.left_neg_40;
    pub const left_48 = BuilderM.left_48;
    pub const left_neg_48 = BuilderM.left_neg_48;
    pub const left_56 = BuilderM.left_56;
    pub const left_neg_56 = BuilderM.left_neg_56;
    pub const left_64 = BuilderM.left_64;
    pub const left_neg_64 = BuilderM.left_neg_64;
    pub const left_72 = BuilderM.left_72;
    pub const left_neg_72 = BuilderM.left_neg_72;
    pub const left_80 = BuilderM.left_80;
    pub const left_neg_80 = BuilderM.left_neg_80;
    pub const left_96 = BuilderM.left_96;
    pub const left_neg_96 = BuilderM.left_neg_96;
    pub const left_112 = BuilderM.left_112;
    pub const left_neg_112 = BuilderM.left_neg_112;
    pub const left_128 = BuilderM.left_128;
    pub const left_neg_128 = BuilderM.left_neg_128;
    pub const left_auto = BuilderM.left_auto;
    pub const left_px = BuilderM.left_px;
    pub const left_neg_px = BuilderM.left_neg_px;
    pub const left_full = BuilderM.left_full;
    pub const left_neg_full = BuilderM.left_neg_full;
    pub const left_1_2 = BuilderM.left_1_2;
    pub const left_neg_1_2 = BuilderM.left_neg_1_2;
    pub const left_1_3 = BuilderM.left_1_3;
    pub const left_neg_1_3 = BuilderM.left_neg_1_3;
    pub const left_2_3 = BuilderM.left_2_3;
    pub const left_neg_2_3 = BuilderM.left_neg_2_3;
    pub const left_1_4 = BuilderM.left_1_4;
    pub const left_neg_1_4 = BuilderM.left_neg_1_4;
    pub const left_2_4 = BuilderM.left_2_4;
    pub const left_neg_2_4 = BuilderM.left_neg_2_4;
    pub const left_3_4 = BuilderM.left_3_4;
    pub const left_neg_3_4 = BuilderM.left_neg_3_4;
    pub const left_1_5 = BuilderM.left_1_5;
    pub const left_neg_1_5 = BuilderM.left_neg_1_5;
    pub const left_2_5 = BuilderM.left_2_5;
    pub const left_neg_2_5 = BuilderM.left_neg_2_5;
    pub const left_3_5 = BuilderM.left_3_5;
    pub const left_neg_3_5 = BuilderM.left_neg_3_5;
    pub const left_4_5 = BuilderM.left_4_5;
    pub const left_neg_4_5 = BuilderM.left_neg_4_5;
    pub const left_1_6 = BuilderM.left_1_6;
    pub const left_neg_1_6 = BuilderM.left_neg_1_6;
    pub const left_5_6 = BuilderM.left_5_6;
    pub const left_neg_5_6 = BuilderM.left_neg_5_6;
    pub const left_1_12 = BuilderM.left_1_12;
    pub const left_neg_1_12 = BuilderM.left_neg_1_12;
    pub const right = BuilderM.right;
    pub const right_0 = BuilderM.right_0;
    pub const right_neg_0 = BuilderM.right_neg_0;
    pub const right_0p5 = BuilderM.right_0p5;
    pub const right_neg_0p5 = BuilderM.right_neg_0p5;
    pub const right_1 = BuilderM.right_1;
    pub const right_neg_1 = BuilderM.right_neg_1;
    pub const right_1p5 = BuilderM.right_1p5;
    pub const right_neg_1p5 = BuilderM.right_neg_1p5;
    pub const right_2 = BuilderM.right_2;
    pub const right_neg_2 = BuilderM.right_neg_2;
    pub const right_2p5 = BuilderM.right_2p5;
    pub const right_neg_2p5 = BuilderM.right_neg_2p5;
    pub const right_3 = BuilderM.right_3;
    pub const right_neg_3 = BuilderM.right_neg_3;
    pub const right_3p5 = BuilderM.right_3p5;
    pub const right_neg_3p5 = BuilderM.right_neg_3p5;
    pub const right_4 = BuilderM.right_4;
    pub const right_neg_4 = BuilderM.right_neg_4;
    pub const right_5 = BuilderM.right_5;
    pub const right_neg_5 = BuilderM.right_neg_5;
    pub const right_6 = BuilderM.right_6;
    pub const right_neg_6 = BuilderM.right_neg_6;
    pub const right_7 = BuilderM.right_7;
    pub const right_neg_7 = BuilderM.right_neg_7;
    pub const right_8 = BuilderM.right_8;
    pub const right_neg_8 = BuilderM.right_neg_8;
    pub const right_9 = BuilderM.right_9;
    pub const right_neg_9 = BuilderM.right_neg_9;
    pub const right_10 = BuilderM.right_10;
    pub const right_neg_10 = BuilderM.right_neg_10;
    pub const right_11 = BuilderM.right_11;
    pub const right_neg_11 = BuilderM.right_neg_11;
    pub const right_12 = BuilderM.right_12;
    pub const right_neg_12 = BuilderM.right_neg_12;
    pub const right_16 = BuilderM.right_16;
    pub const right_neg_16 = BuilderM.right_neg_16;
    pub const right_20 = BuilderM.right_20;
    pub const right_neg_20 = BuilderM.right_neg_20;
    pub const right_24 = BuilderM.right_24;
    pub const right_neg_24 = BuilderM.right_neg_24;
    pub const right_32 = BuilderM.right_32;
    pub const right_neg_32 = BuilderM.right_neg_32;
    pub const right_40 = BuilderM.right_40;
    pub const right_neg_40 = BuilderM.right_neg_40;
    pub const right_48 = BuilderM.right_48;
    pub const right_neg_48 = BuilderM.right_neg_48;
    pub const right_56 = BuilderM.right_56;
    pub const right_neg_56 = BuilderM.right_neg_56;
    pub const right_64 = BuilderM.right_64;
    pub const right_neg_64 = BuilderM.right_neg_64;
    pub const right_72 = BuilderM.right_72;
    pub const right_neg_72 = BuilderM.right_neg_72;
    pub const right_80 = BuilderM.right_80;
    pub const right_neg_80 = BuilderM.right_neg_80;
    pub const right_96 = BuilderM.right_96;
    pub const right_neg_96 = BuilderM.right_neg_96;
    pub const right_112 = BuilderM.right_112;
    pub const right_neg_112 = BuilderM.right_neg_112;
    pub const right_128 = BuilderM.right_128;
    pub const right_neg_128 = BuilderM.right_neg_128;
    pub const right_auto = BuilderM.right_auto;
    pub const right_px = BuilderM.right_px;
    pub const right_neg_px = BuilderM.right_neg_px;
    pub const right_full = BuilderM.right_full;
    pub const right_neg_full = BuilderM.right_neg_full;
    pub const right_1_2 = BuilderM.right_1_2;
    pub const right_neg_1_2 = BuilderM.right_neg_1_2;
    pub const right_1_3 = BuilderM.right_1_3;
    pub const right_neg_1_3 = BuilderM.right_neg_1_3;
    pub const right_2_3 = BuilderM.right_2_3;
    pub const right_neg_2_3 = BuilderM.right_neg_2_3;
    pub const right_1_4 = BuilderM.right_1_4;
    pub const right_neg_1_4 = BuilderM.right_neg_1_4;
    pub const right_2_4 = BuilderM.right_2_4;
    pub const right_neg_2_4 = BuilderM.right_neg_2_4;
    pub const right_3_4 = BuilderM.right_3_4;
    pub const right_neg_3_4 = BuilderM.right_neg_3_4;
    pub const right_1_5 = BuilderM.right_1_5;
    pub const right_neg_1_5 = BuilderM.right_neg_1_5;
    pub const right_2_5 = BuilderM.right_2_5;
    pub const right_neg_2_5 = BuilderM.right_neg_2_5;
    pub const right_3_5 = BuilderM.right_3_5;
    pub const right_neg_3_5 = BuilderM.right_neg_3_5;
    pub const right_4_5 = BuilderM.right_4_5;
    pub const right_neg_4_5 = BuilderM.right_neg_4_5;
    pub const right_1_6 = BuilderM.right_1_6;
    pub const right_neg_1_6 = BuilderM.right_neg_1_6;
    pub const right_5_6 = BuilderM.right_5_6;
    pub const right_neg_5_6 = BuilderM.right_neg_5_6;
    pub const right_1_12 = BuilderM.right_1_12;
    pub const right_neg_1_12 = BuilderM.right_neg_1_12;
    pub const w = BuilderM.w;
    pub const w_0 = BuilderM.w_0;
    pub const w_neg_0 = BuilderM.w_neg_0;
    pub const w_0p5 = BuilderM.w_0p5;
    pub const w_neg_0p5 = BuilderM.w_neg_0p5;
    pub const w_1 = BuilderM.w_1;
    pub const w_neg_1 = BuilderM.w_neg_1;
    pub const w_1p5 = BuilderM.w_1p5;
    pub const w_neg_1p5 = BuilderM.w_neg_1p5;
    pub const w_2 = BuilderM.w_2;
    pub const w_neg_2 = BuilderM.w_neg_2;
    pub const w_2p5 = BuilderM.w_2p5;
    pub const w_neg_2p5 = BuilderM.w_neg_2p5;
    pub const w_3 = BuilderM.w_3;
    pub const w_neg_3 = BuilderM.w_neg_3;
    pub const w_3p5 = BuilderM.w_3p5;
    pub const w_neg_3p5 = BuilderM.w_neg_3p5;
    pub const w_4 = BuilderM.w_4;
    pub const w_neg_4 = BuilderM.w_neg_4;
    pub const w_5 = BuilderM.w_5;
    pub const w_neg_5 = BuilderM.w_neg_5;
    pub const w_6 = BuilderM.w_6;
    pub const w_neg_6 = BuilderM.w_neg_6;
    pub const w_7 = BuilderM.w_7;
    pub const w_neg_7 = BuilderM.w_neg_7;
    pub const w_8 = BuilderM.w_8;
    pub const w_neg_8 = BuilderM.w_neg_8;
    pub const w_9 = BuilderM.w_9;
    pub const w_neg_9 = BuilderM.w_neg_9;
    pub const w_10 = BuilderM.w_10;
    pub const w_neg_10 = BuilderM.w_neg_10;
    pub const w_11 = BuilderM.w_11;
    pub const w_neg_11 = BuilderM.w_neg_11;
    pub const w_12 = BuilderM.w_12;
    pub const w_neg_12 = BuilderM.w_neg_12;
    pub const w_16 = BuilderM.w_16;
    pub const w_neg_16 = BuilderM.w_neg_16;
    pub const w_20 = BuilderM.w_20;
    pub const w_neg_20 = BuilderM.w_neg_20;
    pub const w_24 = BuilderM.w_24;
    pub const w_neg_24 = BuilderM.w_neg_24;
    pub const w_32 = BuilderM.w_32;
    pub const w_neg_32 = BuilderM.w_neg_32;
    pub const w_40 = BuilderM.w_40;
    pub const w_neg_40 = BuilderM.w_neg_40;
    pub const w_48 = BuilderM.w_48;
    pub const w_neg_48 = BuilderM.w_neg_48;
    pub const w_56 = BuilderM.w_56;
    pub const w_neg_56 = BuilderM.w_neg_56;
    pub const w_64 = BuilderM.w_64;
    pub const w_neg_64 = BuilderM.w_neg_64;
    pub const w_72 = BuilderM.w_72;
    pub const w_neg_72 = BuilderM.w_neg_72;
    pub const w_80 = BuilderM.w_80;
    pub const w_neg_80 = BuilderM.w_neg_80;
    pub const w_96 = BuilderM.w_96;
    pub const w_neg_96 = BuilderM.w_neg_96;
    pub const w_112 = BuilderM.w_112;
    pub const w_neg_112 = BuilderM.w_neg_112;
    pub const w_128 = BuilderM.w_128;
    pub const w_neg_128 = BuilderM.w_neg_128;
    pub const w_auto = BuilderM.w_auto;
    pub const w_px = BuilderM.w_px;
    pub const w_neg_px = BuilderM.w_neg_px;
    pub const w_full = BuilderM.w_full;
    pub const w_neg_full = BuilderM.w_neg_full;
    pub const w_1_2 = BuilderM.w_1_2;
    pub const w_neg_1_2 = BuilderM.w_neg_1_2;
    pub const w_1_3 = BuilderM.w_1_3;
    pub const w_neg_1_3 = BuilderM.w_neg_1_3;
    pub const w_2_3 = BuilderM.w_2_3;
    pub const w_neg_2_3 = BuilderM.w_neg_2_3;
    pub const w_1_4 = BuilderM.w_1_4;
    pub const w_neg_1_4 = BuilderM.w_neg_1_4;
    pub const w_2_4 = BuilderM.w_2_4;
    pub const w_neg_2_4 = BuilderM.w_neg_2_4;
    pub const w_3_4 = BuilderM.w_3_4;
    pub const w_neg_3_4 = BuilderM.w_neg_3_4;
    pub const w_1_5 = BuilderM.w_1_5;
    pub const w_neg_1_5 = BuilderM.w_neg_1_5;
    pub const w_2_5 = BuilderM.w_2_5;
    pub const w_neg_2_5 = BuilderM.w_neg_2_5;
    pub const w_3_5 = BuilderM.w_3_5;
    pub const w_neg_3_5 = BuilderM.w_neg_3_5;
    pub const w_4_5 = BuilderM.w_4_5;
    pub const w_neg_4_5 = BuilderM.w_neg_4_5;
    pub const w_1_6 = BuilderM.w_1_6;
    pub const w_neg_1_6 = BuilderM.w_neg_1_6;
    pub const w_5_6 = BuilderM.w_5_6;
    pub const w_neg_5_6 = BuilderM.w_neg_5_6;
    pub const w_1_12 = BuilderM.w_1_12;
    pub const w_neg_1_12 = BuilderM.w_neg_1_12;
    pub const h = BuilderM.h;
    pub const h_0 = BuilderM.h_0;
    pub const h_neg_0 = BuilderM.h_neg_0;
    pub const h_0p5 = BuilderM.h_0p5;
    pub const h_neg_0p5 = BuilderM.h_neg_0p5;
    pub const h_1 = BuilderM.h_1;
    pub const h_neg_1 = BuilderM.h_neg_1;
    pub const h_1p5 = BuilderM.h_1p5;
    pub const h_neg_1p5 = BuilderM.h_neg_1p5;
    pub const h_2 = BuilderM.h_2;
    pub const h_neg_2 = BuilderM.h_neg_2;
    pub const h_2p5 = BuilderM.h_2p5;
    pub const h_neg_2p5 = BuilderM.h_neg_2p5;
    pub const h_3 = BuilderM.h_3;
    pub const h_neg_3 = BuilderM.h_neg_3;
    pub const h_3p5 = BuilderM.h_3p5;
    pub const h_neg_3p5 = BuilderM.h_neg_3p5;
    pub const h_4 = BuilderM.h_4;
    pub const h_neg_4 = BuilderM.h_neg_4;
    pub const h_5 = BuilderM.h_5;
    pub const h_neg_5 = BuilderM.h_neg_5;
    pub const h_6 = BuilderM.h_6;
    pub const h_neg_6 = BuilderM.h_neg_6;
    pub const h_7 = BuilderM.h_7;
    pub const h_neg_7 = BuilderM.h_neg_7;
    pub const h_8 = BuilderM.h_8;
    pub const h_neg_8 = BuilderM.h_neg_8;
    pub const h_9 = BuilderM.h_9;
    pub const h_neg_9 = BuilderM.h_neg_9;
    pub const h_10 = BuilderM.h_10;
    pub const h_neg_10 = BuilderM.h_neg_10;
    pub const h_11 = BuilderM.h_11;
    pub const h_neg_11 = BuilderM.h_neg_11;
    pub const h_12 = BuilderM.h_12;
    pub const h_neg_12 = BuilderM.h_neg_12;
    pub const h_16 = BuilderM.h_16;
    pub const h_neg_16 = BuilderM.h_neg_16;
    pub const h_20 = BuilderM.h_20;
    pub const h_neg_20 = BuilderM.h_neg_20;
    pub const h_24 = BuilderM.h_24;
    pub const h_neg_24 = BuilderM.h_neg_24;
    pub const h_32 = BuilderM.h_32;
    pub const h_neg_32 = BuilderM.h_neg_32;
    pub const h_40 = BuilderM.h_40;
    pub const h_neg_40 = BuilderM.h_neg_40;
    pub const h_48 = BuilderM.h_48;
    pub const h_neg_48 = BuilderM.h_neg_48;
    pub const h_56 = BuilderM.h_56;
    pub const h_neg_56 = BuilderM.h_neg_56;
    pub const h_64 = BuilderM.h_64;
    pub const h_neg_64 = BuilderM.h_neg_64;
    pub const h_72 = BuilderM.h_72;
    pub const h_neg_72 = BuilderM.h_neg_72;
    pub const h_80 = BuilderM.h_80;
    pub const h_neg_80 = BuilderM.h_neg_80;
    pub const h_96 = BuilderM.h_96;
    pub const h_neg_96 = BuilderM.h_neg_96;
    pub const h_112 = BuilderM.h_112;
    pub const h_neg_112 = BuilderM.h_neg_112;
    pub const h_128 = BuilderM.h_128;
    pub const h_neg_128 = BuilderM.h_neg_128;
    pub const h_auto = BuilderM.h_auto;
    pub const h_px = BuilderM.h_px;
    pub const h_neg_px = BuilderM.h_neg_px;
    pub const h_full = BuilderM.h_full;
    pub const h_neg_full = BuilderM.h_neg_full;
    pub const h_1_2 = BuilderM.h_1_2;
    pub const h_neg_1_2 = BuilderM.h_neg_1_2;
    pub const h_1_3 = BuilderM.h_1_3;
    pub const h_neg_1_3 = BuilderM.h_neg_1_3;
    pub const h_2_3 = BuilderM.h_2_3;
    pub const h_neg_2_3 = BuilderM.h_neg_2_3;
    pub const h_1_4 = BuilderM.h_1_4;
    pub const h_neg_1_4 = BuilderM.h_neg_1_4;
    pub const h_2_4 = BuilderM.h_2_4;
    pub const h_neg_2_4 = BuilderM.h_neg_2_4;
    pub const h_3_4 = BuilderM.h_3_4;
    pub const h_neg_3_4 = BuilderM.h_neg_3_4;
    pub const h_1_5 = BuilderM.h_1_5;
    pub const h_neg_1_5 = BuilderM.h_neg_1_5;
    pub const h_2_5 = BuilderM.h_2_5;
    pub const h_neg_2_5 = BuilderM.h_neg_2_5;
    pub const h_3_5 = BuilderM.h_3_5;
    pub const h_neg_3_5 = BuilderM.h_neg_3_5;
    pub const h_4_5 = BuilderM.h_4_5;
    pub const h_neg_4_5 = BuilderM.h_neg_4_5;
    pub const h_1_6 = BuilderM.h_1_6;
    pub const h_neg_1_6 = BuilderM.h_neg_1_6;
    pub const h_5_6 = BuilderM.h_5_6;
    pub const h_neg_5_6 = BuilderM.h_neg_5_6;
    pub const h_1_12 = BuilderM.h_1_12;
    pub const h_neg_1_12 = BuilderM.h_neg_1_12;
    pub const size = BuilderM.size;
    pub const size_0 = BuilderM.size_0;
    pub const size_neg_0 = BuilderM.size_neg_0;
    pub const size_0p5 = BuilderM.size_0p5;
    pub const size_neg_0p5 = BuilderM.size_neg_0p5;
    pub const size_1 = BuilderM.size_1;
    pub const size_neg_1 = BuilderM.size_neg_1;
    pub const size_1p5 = BuilderM.size_1p5;
    pub const size_neg_1p5 = BuilderM.size_neg_1p5;
    pub const size_2 = BuilderM.size_2;
    pub const size_neg_2 = BuilderM.size_neg_2;
    pub const size_2p5 = BuilderM.size_2p5;
    pub const size_neg_2p5 = BuilderM.size_neg_2p5;
    pub const size_3 = BuilderM.size_3;
    pub const size_neg_3 = BuilderM.size_neg_3;
    pub const size_3p5 = BuilderM.size_3p5;
    pub const size_neg_3p5 = BuilderM.size_neg_3p5;
    pub const size_4 = BuilderM.size_4;
    pub const size_neg_4 = BuilderM.size_neg_4;
    pub const size_5 = BuilderM.size_5;
    pub const size_neg_5 = BuilderM.size_neg_5;
    pub const size_6 = BuilderM.size_6;
    pub const size_neg_6 = BuilderM.size_neg_6;
    pub const size_7 = BuilderM.size_7;
    pub const size_neg_7 = BuilderM.size_neg_7;
    pub const size_8 = BuilderM.size_8;
    pub const size_neg_8 = BuilderM.size_neg_8;
    pub const size_9 = BuilderM.size_9;
    pub const size_neg_9 = BuilderM.size_neg_9;
    pub const size_10 = BuilderM.size_10;
    pub const size_neg_10 = BuilderM.size_neg_10;
    pub const size_11 = BuilderM.size_11;
    pub const size_neg_11 = BuilderM.size_neg_11;
    pub const size_12 = BuilderM.size_12;
    pub const size_neg_12 = BuilderM.size_neg_12;
    pub const size_16 = BuilderM.size_16;
    pub const size_neg_16 = BuilderM.size_neg_16;
    pub const size_20 = BuilderM.size_20;
    pub const size_neg_20 = BuilderM.size_neg_20;
    pub const size_24 = BuilderM.size_24;
    pub const size_neg_24 = BuilderM.size_neg_24;
    pub const size_32 = BuilderM.size_32;
    pub const size_neg_32 = BuilderM.size_neg_32;
    pub const size_40 = BuilderM.size_40;
    pub const size_neg_40 = BuilderM.size_neg_40;
    pub const size_48 = BuilderM.size_48;
    pub const size_neg_48 = BuilderM.size_neg_48;
    pub const size_56 = BuilderM.size_56;
    pub const size_neg_56 = BuilderM.size_neg_56;
    pub const size_64 = BuilderM.size_64;
    pub const size_neg_64 = BuilderM.size_neg_64;
    pub const size_72 = BuilderM.size_72;
    pub const size_neg_72 = BuilderM.size_neg_72;
    pub const size_80 = BuilderM.size_80;
    pub const size_neg_80 = BuilderM.size_neg_80;
    pub const size_96 = BuilderM.size_96;
    pub const size_neg_96 = BuilderM.size_neg_96;
    pub const size_112 = BuilderM.size_112;
    pub const size_neg_112 = BuilderM.size_neg_112;
    pub const size_128 = BuilderM.size_128;
    pub const size_neg_128 = BuilderM.size_neg_128;
    pub const size_auto = BuilderM.size_auto;
    pub const size_px = BuilderM.size_px;
    pub const size_neg_px = BuilderM.size_neg_px;
    pub const size_full = BuilderM.size_full;
    pub const size_neg_full = BuilderM.size_neg_full;
    pub const size_1_2 = BuilderM.size_1_2;
    pub const size_neg_1_2 = BuilderM.size_neg_1_2;
    pub const size_1_3 = BuilderM.size_1_3;
    pub const size_neg_1_3 = BuilderM.size_neg_1_3;
    pub const size_2_3 = BuilderM.size_2_3;
    pub const size_neg_2_3 = BuilderM.size_neg_2_3;
    pub const size_1_4 = BuilderM.size_1_4;
    pub const size_neg_1_4 = BuilderM.size_neg_1_4;
    pub const size_2_4 = BuilderM.size_2_4;
    pub const size_neg_2_4 = BuilderM.size_neg_2_4;
    pub const size_3_4 = BuilderM.size_3_4;
    pub const size_neg_3_4 = BuilderM.size_neg_3_4;
    pub const size_1_5 = BuilderM.size_1_5;
    pub const size_neg_1_5 = BuilderM.size_neg_1_5;
    pub const size_2_5 = BuilderM.size_2_5;
    pub const size_neg_2_5 = BuilderM.size_neg_2_5;
    pub const size_3_5 = BuilderM.size_3_5;
    pub const size_neg_3_5 = BuilderM.size_neg_3_5;
    pub const size_4_5 = BuilderM.size_4_5;
    pub const size_neg_4_5 = BuilderM.size_neg_4_5;
    pub const size_1_6 = BuilderM.size_1_6;
    pub const size_neg_1_6 = BuilderM.size_neg_1_6;
    pub const size_5_6 = BuilderM.size_5_6;
    pub const size_neg_5_6 = BuilderM.size_neg_5_6;
    pub const size_1_12 = BuilderM.size_1_12;
    pub const size_neg_1_12 = BuilderM.size_neg_1_12;
    pub const min_size = BuilderM.min_size;
    pub const min_size_0 = BuilderM.min_size_0;
    pub const min_size_neg_0 = BuilderM.min_size_neg_0;
    pub const min_size_0p5 = BuilderM.min_size_0p5;
    pub const min_size_neg_0p5 = BuilderM.min_size_neg_0p5;
    pub const min_size_1 = BuilderM.min_size_1;
    pub const min_size_neg_1 = BuilderM.min_size_neg_1;
    pub const min_size_1p5 = BuilderM.min_size_1p5;
    pub const min_size_neg_1p5 = BuilderM.min_size_neg_1p5;
    pub const min_size_2 = BuilderM.min_size_2;
    pub const min_size_neg_2 = BuilderM.min_size_neg_2;
    pub const min_size_2p5 = BuilderM.min_size_2p5;
    pub const min_size_neg_2p5 = BuilderM.min_size_neg_2p5;
    pub const min_size_3 = BuilderM.min_size_3;
    pub const min_size_neg_3 = BuilderM.min_size_neg_3;
    pub const min_size_3p5 = BuilderM.min_size_3p5;
    pub const min_size_neg_3p5 = BuilderM.min_size_neg_3p5;
    pub const min_size_4 = BuilderM.min_size_4;
    pub const min_size_neg_4 = BuilderM.min_size_neg_4;
    pub const min_size_5 = BuilderM.min_size_5;
    pub const min_size_neg_5 = BuilderM.min_size_neg_5;
    pub const min_size_6 = BuilderM.min_size_6;
    pub const min_size_neg_6 = BuilderM.min_size_neg_6;
    pub const min_size_7 = BuilderM.min_size_7;
    pub const min_size_neg_7 = BuilderM.min_size_neg_7;
    pub const min_size_8 = BuilderM.min_size_8;
    pub const min_size_neg_8 = BuilderM.min_size_neg_8;
    pub const min_size_9 = BuilderM.min_size_9;
    pub const min_size_neg_9 = BuilderM.min_size_neg_9;
    pub const min_size_10 = BuilderM.min_size_10;
    pub const min_size_neg_10 = BuilderM.min_size_neg_10;
    pub const min_size_11 = BuilderM.min_size_11;
    pub const min_size_neg_11 = BuilderM.min_size_neg_11;
    pub const min_size_12 = BuilderM.min_size_12;
    pub const min_size_neg_12 = BuilderM.min_size_neg_12;
    pub const min_size_16 = BuilderM.min_size_16;
    pub const min_size_neg_16 = BuilderM.min_size_neg_16;
    pub const min_size_20 = BuilderM.min_size_20;
    pub const min_size_neg_20 = BuilderM.min_size_neg_20;
    pub const min_size_24 = BuilderM.min_size_24;
    pub const min_size_neg_24 = BuilderM.min_size_neg_24;
    pub const min_size_32 = BuilderM.min_size_32;
    pub const min_size_neg_32 = BuilderM.min_size_neg_32;
    pub const min_size_40 = BuilderM.min_size_40;
    pub const min_size_neg_40 = BuilderM.min_size_neg_40;
    pub const min_size_48 = BuilderM.min_size_48;
    pub const min_size_neg_48 = BuilderM.min_size_neg_48;
    pub const min_size_56 = BuilderM.min_size_56;
    pub const min_size_neg_56 = BuilderM.min_size_neg_56;
    pub const min_size_64 = BuilderM.min_size_64;
    pub const min_size_neg_64 = BuilderM.min_size_neg_64;
    pub const min_size_72 = BuilderM.min_size_72;
    pub const min_size_neg_72 = BuilderM.min_size_neg_72;
    pub const min_size_80 = BuilderM.min_size_80;
    pub const min_size_neg_80 = BuilderM.min_size_neg_80;
    pub const min_size_96 = BuilderM.min_size_96;
    pub const min_size_neg_96 = BuilderM.min_size_neg_96;
    pub const min_size_112 = BuilderM.min_size_112;
    pub const min_size_neg_112 = BuilderM.min_size_neg_112;
    pub const min_size_128 = BuilderM.min_size_128;
    pub const min_size_neg_128 = BuilderM.min_size_neg_128;
    pub const min_size_auto = BuilderM.min_size_auto;
    pub const min_size_px = BuilderM.min_size_px;
    pub const min_size_neg_px = BuilderM.min_size_neg_px;
    pub const min_size_full = BuilderM.min_size_full;
    pub const min_size_neg_full = BuilderM.min_size_neg_full;
    pub const min_size_1_2 = BuilderM.min_size_1_2;
    pub const min_size_neg_1_2 = BuilderM.min_size_neg_1_2;
    pub const min_size_1_3 = BuilderM.min_size_1_3;
    pub const min_size_neg_1_3 = BuilderM.min_size_neg_1_3;
    pub const min_size_2_3 = BuilderM.min_size_2_3;
    pub const min_size_neg_2_3 = BuilderM.min_size_neg_2_3;
    pub const min_size_1_4 = BuilderM.min_size_1_4;
    pub const min_size_neg_1_4 = BuilderM.min_size_neg_1_4;
    pub const min_size_2_4 = BuilderM.min_size_2_4;
    pub const min_size_neg_2_4 = BuilderM.min_size_neg_2_4;
    pub const min_size_3_4 = BuilderM.min_size_3_4;
    pub const min_size_neg_3_4 = BuilderM.min_size_neg_3_4;
    pub const min_size_1_5 = BuilderM.min_size_1_5;
    pub const min_size_neg_1_5 = BuilderM.min_size_neg_1_5;
    pub const min_size_2_5 = BuilderM.min_size_2_5;
    pub const min_size_neg_2_5 = BuilderM.min_size_neg_2_5;
    pub const min_size_3_5 = BuilderM.min_size_3_5;
    pub const min_size_neg_3_5 = BuilderM.min_size_neg_3_5;
    pub const min_size_4_5 = BuilderM.min_size_4_5;
    pub const min_size_neg_4_5 = BuilderM.min_size_neg_4_5;
    pub const min_size_1_6 = BuilderM.min_size_1_6;
    pub const min_size_neg_1_6 = BuilderM.min_size_neg_1_6;
    pub const min_size_5_6 = BuilderM.min_size_5_6;
    pub const min_size_neg_5_6 = BuilderM.min_size_neg_5_6;
    pub const min_size_1_12 = BuilderM.min_size_1_12;
    pub const min_size_neg_1_12 = BuilderM.min_size_neg_1_12;
    pub const min_w = BuilderM.min_w;
    pub const min_w_0 = BuilderM.min_w_0;
    pub const min_w_neg_0 = BuilderM.min_w_neg_0;
    pub const min_w_0p5 = BuilderM.min_w_0p5;
    pub const min_w_neg_0p5 = BuilderM.min_w_neg_0p5;
    pub const min_w_1 = BuilderM.min_w_1;
    pub const min_w_neg_1 = BuilderM.min_w_neg_1;
    pub const min_w_1p5 = BuilderM.min_w_1p5;
    pub const min_w_neg_1p5 = BuilderM.min_w_neg_1p5;
    pub const min_w_2 = BuilderM.min_w_2;
    pub const min_w_neg_2 = BuilderM.min_w_neg_2;
    pub const min_w_2p5 = BuilderM.min_w_2p5;
    pub const min_w_neg_2p5 = BuilderM.min_w_neg_2p5;
    pub const min_w_3 = BuilderM.min_w_3;
    pub const min_w_neg_3 = BuilderM.min_w_neg_3;
    pub const min_w_3p5 = BuilderM.min_w_3p5;
    pub const min_w_neg_3p5 = BuilderM.min_w_neg_3p5;
    pub const min_w_4 = BuilderM.min_w_4;
    pub const min_w_neg_4 = BuilderM.min_w_neg_4;
    pub const min_w_5 = BuilderM.min_w_5;
    pub const min_w_neg_5 = BuilderM.min_w_neg_5;
    pub const min_w_6 = BuilderM.min_w_6;
    pub const min_w_neg_6 = BuilderM.min_w_neg_6;
    pub const min_w_7 = BuilderM.min_w_7;
    pub const min_w_neg_7 = BuilderM.min_w_neg_7;
    pub const min_w_8 = BuilderM.min_w_8;
    pub const min_w_neg_8 = BuilderM.min_w_neg_8;
    pub const min_w_9 = BuilderM.min_w_9;
    pub const min_w_neg_9 = BuilderM.min_w_neg_9;
    pub const min_w_10 = BuilderM.min_w_10;
    pub const min_w_neg_10 = BuilderM.min_w_neg_10;
    pub const min_w_11 = BuilderM.min_w_11;
    pub const min_w_neg_11 = BuilderM.min_w_neg_11;
    pub const min_w_12 = BuilderM.min_w_12;
    pub const min_w_neg_12 = BuilderM.min_w_neg_12;
    pub const min_w_16 = BuilderM.min_w_16;
    pub const min_w_neg_16 = BuilderM.min_w_neg_16;
    pub const min_w_20 = BuilderM.min_w_20;
    pub const min_w_neg_20 = BuilderM.min_w_neg_20;
    pub const min_w_24 = BuilderM.min_w_24;
    pub const min_w_neg_24 = BuilderM.min_w_neg_24;
    pub const min_w_32 = BuilderM.min_w_32;
    pub const min_w_neg_32 = BuilderM.min_w_neg_32;
    pub const min_w_40 = BuilderM.min_w_40;
    pub const min_w_neg_40 = BuilderM.min_w_neg_40;
    pub const min_w_48 = BuilderM.min_w_48;
    pub const min_w_neg_48 = BuilderM.min_w_neg_48;
    pub const min_w_56 = BuilderM.min_w_56;
    pub const min_w_neg_56 = BuilderM.min_w_neg_56;
    pub const min_w_64 = BuilderM.min_w_64;
    pub const min_w_neg_64 = BuilderM.min_w_neg_64;
    pub const min_w_72 = BuilderM.min_w_72;
    pub const min_w_neg_72 = BuilderM.min_w_neg_72;
    pub const min_w_80 = BuilderM.min_w_80;
    pub const min_w_neg_80 = BuilderM.min_w_neg_80;
    pub const min_w_96 = BuilderM.min_w_96;
    pub const min_w_neg_96 = BuilderM.min_w_neg_96;
    pub const min_w_112 = BuilderM.min_w_112;
    pub const min_w_neg_112 = BuilderM.min_w_neg_112;
    pub const min_w_128 = BuilderM.min_w_128;
    pub const min_w_neg_128 = BuilderM.min_w_neg_128;
    pub const min_w_auto = BuilderM.min_w_auto;
    pub const min_w_px = BuilderM.min_w_px;
    pub const min_w_neg_px = BuilderM.min_w_neg_px;
    pub const min_w_full = BuilderM.min_w_full;
    pub const min_w_neg_full = BuilderM.min_w_neg_full;
    pub const min_w_1_2 = BuilderM.min_w_1_2;
    pub const min_w_neg_1_2 = BuilderM.min_w_neg_1_2;
    pub const min_w_1_3 = BuilderM.min_w_1_3;
    pub const min_w_neg_1_3 = BuilderM.min_w_neg_1_3;
    pub const min_w_2_3 = BuilderM.min_w_2_3;
    pub const min_w_neg_2_3 = BuilderM.min_w_neg_2_3;
    pub const min_w_1_4 = BuilderM.min_w_1_4;
    pub const min_w_neg_1_4 = BuilderM.min_w_neg_1_4;
    pub const min_w_2_4 = BuilderM.min_w_2_4;
    pub const min_w_neg_2_4 = BuilderM.min_w_neg_2_4;
    pub const min_w_3_4 = BuilderM.min_w_3_4;
    pub const min_w_neg_3_4 = BuilderM.min_w_neg_3_4;
    pub const min_w_1_5 = BuilderM.min_w_1_5;
    pub const min_w_neg_1_5 = BuilderM.min_w_neg_1_5;
    pub const min_w_2_5 = BuilderM.min_w_2_5;
    pub const min_w_neg_2_5 = BuilderM.min_w_neg_2_5;
    pub const min_w_3_5 = BuilderM.min_w_3_5;
    pub const min_w_neg_3_5 = BuilderM.min_w_neg_3_5;
    pub const min_w_4_5 = BuilderM.min_w_4_5;
    pub const min_w_neg_4_5 = BuilderM.min_w_neg_4_5;
    pub const min_w_1_6 = BuilderM.min_w_1_6;
    pub const min_w_neg_1_6 = BuilderM.min_w_neg_1_6;
    pub const min_w_5_6 = BuilderM.min_w_5_6;
    pub const min_w_neg_5_6 = BuilderM.min_w_neg_5_6;
    pub const min_w_1_12 = BuilderM.min_w_1_12;
    pub const min_w_neg_1_12 = BuilderM.min_w_neg_1_12;
    pub const min_h = BuilderM.min_h;
    pub const min_h_0 = BuilderM.min_h_0;
    pub const min_h_neg_0 = BuilderM.min_h_neg_0;
    pub const min_h_0p5 = BuilderM.min_h_0p5;
    pub const min_h_neg_0p5 = BuilderM.min_h_neg_0p5;
    pub const min_h_1 = BuilderM.min_h_1;
    pub const min_h_neg_1 = BuilderM.min_h_neg_1;
    pub const min_h_1p5 = BuilderM.min_h_1p5;
    pub const min_h_neg_1p5 = BuilderM.min_h_neg_1p5;
    pub const min_h_2 = BuilderM.min_h_2;
    pub const min_h_neg_2 = BuilderM.min_h_neg_2;
    pub const min_h_2p5 = BuilderM.min_h_2p5;
    pub const min_h_neg_2p5 = BuilderM.min_h_neg_2p5;
    pub const min_h_3 = BuilderM.min_h_3;
    pub const min_h_neg_3 = BuilderM.min_h_neg_3;
    pub const min_h_3p5 = BuilderM.min_h_3p5;
    pub const min_h_neg_3p5 = BuilderM.min_h_neg_3p5;
    pub const min_h_4 = BuilderM.min_h_4;
    pub const min_h_neg_4 = BuilderM.min_h_neg_4;
    pub const min_h_5 = BuilderM.min_h_5;
    pub const min_h_neg_5 = BuilderM.min_h_neg_5;
    pub const min_h_6 = BuilderM.min_h_6;
    pub const min_h_neg_6 = BuilderM.min_h_neg_6;
    pub const min_h_7 = BuilderM.min_h_7;
    pub const min_h_neg_7 = BuilderM.min_h_neg_7;
    pub const min_h_8 = BuilderM.min_h_8;
    pub const min_h_neg_8 = BuilderM.min_h_neg_8;
    pub const min_h_9 = BuilderM.min_h_9;
    pub const min_h_neg_9 = BuilderM.min_h_neg_9;
    pub const min_h_10 = BuilderM.min_h_10;
    pub const min_h_neg_10 = BuilderM.min_h_neg_10;
    pub const min_h_11 = BuilderM.min_h_11;
    pub const min_h_neg_11 = BuilderM.min_h_neg_11;
    pub const min_h_12 = BuilderM.min_h_12;
    pub const min_h_neg_12 = BuilderM.min_h_neg_12;
    pub const min_h_16 = BuilderM.min_h_16;
    pub const min_h_neg_16 = BuilderM.min_h_neg_16;
    pub const min_h_20 = BuilderM.min_h_20;
    pub const min_h_neg_20 = BuilderM.min_h_neg_20;
    pub const min_h_24 = BuilderM.min_h_24;
    pub const min_h_neg_24 = BuilderM.min_h_neg_24;
    pub const min_h_32 = BuilderM.min_h_32;
    pub const min_h_neg_32 = BuilderM.min_h_neg_32;
    pub const min_h_40 = BuilderM.min_h_40;
    pub const min_h_neg_40 = BuilderM.min_h_neg_40;
    pub const min_h_48 = BuilderM.min_h_48;
    pub const min_h_neg_48 = BuilderM.min_h_neg_48;
    pub const min_h_56 = BuilderM.min_h_56;
    pub const min_h_neg_56 = BuilderM.min_h_neg_56;
    pub const min_h_64 = BuilderM.min_h_64;
    pub const min_h_neg_64 = BuilderM.min_h_neg_64;
    pub const min_h_72 = BuilderM.min_h_72;
    pub const min_h_neg_72 = BuilderM.min_h_neg_72;
    pub const min_h_80 = BuilderM.min_h_80;
    pub const min_h_neg_80 = BuilderM.min_h_neg_80;
    pub const min_h_96 = BuilderM.min_h_96;
    pub const min_h_neg_96 = BuilderM.min_h_neg_96;
    pub const min_h_112 = BuilderM.min_h_112;
    pub const min_h_neg_112 = BuilderM.min_h_neg_112;
    pub const min_h_128 = BuilderM.min_h_128;
    pub const min_h_neg_128 = BuilderM.min_h_neg_128;
    pub const min_h_auto = BuilderM.min_h_auto;
    pub const min_h_px = BuilderM.min_h_px;
    pub const min_h_neg_px = BuilderM.min_h_neg_px;
    pub const min_h_full = BuilderM.min_h_full;
    pub const min_h_neg_full = BuilderM.min_h_neg_full;
    pub const min_h_1_2 = BuilderM.min_h_1_2;
    pub const min_h_neg_1_2 = BuilderM.min_h_neg_1_2;
    pub const min_h_1_3 = BuilderM.min_h_1_3;
    pub const min_h_neg_1_3 = BuilderM.min_h_neg_1_3;
    pub const min_h_2_3 = BuilderM.min_h_2_3;
    pub const min_h_neg_2_3 = BuilderM.min_h_neg_2_3;
    pub const min_h_1_4 = BuilderM.min_h_1_4;
    pub const min_h_neg_1_4 = BuilderM.min_h_neg_1_4;
    pub const min_h_2_4 = BuilderM.min_h_2_4;
    pub const min_h_neg_2_4 = BuilderM.min_h_neg_2_4;
    pub const min_h_3_4 = BuilderM.min_h_3_4;
    pub const min_h_neg_3_4 = BuilderM.min_h_neg_3_4;
    pub const min_h_1_5 = BuilderM.min_h_1_5;
    pub const min_h_neg_1_5 = BuilderM.min_h_neg_1_5;
    pub const min_h_2_5 = BuilderM.min_h_2_5;
    pub const min_h_neg_2_5 = BuilderM.min_h_neg_2_5;
    pub const min_h_3_5 = BuilderM.min_h_3_5;
    pub const min_h_neg_3_5 = BuilderM.min_h_neg_3_5;
    pub const min_h_4_5 = BuilderM.min_h_4_5;
    pub const min_h_neg_4_5 = BuilderM.min_h_neg_4_5;
    pub const min_h_1_6 = BuilderM.min_h_1_6;
    pub const min_h_neg_1_6 = BuilderM.min_h_neg_1_6;
    pub const min_h_5_6 = BuilderM.min_h_5_6;
    pub const min_h_neg_5_6 = BuilderM.min_h_neg_5_6;
    pub const min_h_1_12 = BuilderM.min_h_1_12;
    pub const min_h_neg_1_12 = BuilderM.min_h_neg_1_12;
    pub const max_size = BuilderM.max_size;
    pub const max_size_0 = BuilderM.max_size_0;
    pub const max_size_neg_0 = BuilderM.max_size_neg_0;
    pub const max_size_0p5 = BuilderM.max_size_0p5;
    pub const max_size_neg_0p5 = BuilderM.max_size_neg_0p5;
    pub const max_size_1 = BuilderM.max_size_1;
    pub const max_size_neg_1 = BuilderM.max_size_neg_1;
    pub const max_size_1p5 = BuilderM.max_size_1p5;
    pub const max_size_neg_1p5 = BuilderM.max_size_neg_1p5;
    pub const max_size_2 = BuilderM.max_size_2;
    pub const max_size_neg_2 = BuilderM.max_size_neg_2;
    pub const max_size_2p5 = BuilderM.max_size_2p5;
    pub const max_size_neg_2p5 = BuilderM.max_size_neg_2p5;
    pub const max_size_3 = BuilderM.max_size_3;
    pub const max_size_neg_3 = BuilderM.max_size_neg_3;
    pub const max_size_3p5 = BuilderM.max_size_3p5;
    pub const max_size_neg_3p5 = BuilderM.max_size_neg_3p5;
    pub const max_size_4 = BuilderM.max_size_4;
    pub const max_size_neg_4 = BuilderM.max_size_neg_4;
    pub const max_size_5 = BuilderM.max_size_5;
    pub const max_size_neg_5 = BuilderM.max_size_neg_5;
    pub const max_size_6 = BuilderM.max_size_6;
    pub const max_size_neg_6 = BuilderM.max_size_neg_6;
    pub const max_size_7 = BuilderM.max_size_7;
    pub const max_size_neg_7 = BuilderM.max_size_neg_7;
    pub const max_size_8 = BuilderM.max_size_8;
    pub const max_size_neg_8 = BuilderM.max_size_neg_8;
    pub const max_size_9 = BuilderM.max_size_9;
    pub const max_size_neg_9 = BuilderM.max_size_neg_9;
    pub const max_size_10 = BuilderM.max_size_10;
    pub const max_size_neg_10 = BuilderM.max_size_neg_10;
    pub const max_size_11 = BuilderM.max_size_11;
    pub const max_size_neg_11 = BuilderM.max_size_neg_11;
    pub const max_size_12 = BuilderM.max_size_12;
    pub const max_size_neg_12 = BuilderM.max_size_neg_12;
    pub const max_size_16 = BuilderM.max_size_16;
    pub const max_size_neg_16 = BuilderM.max_size_neg_16;
    pub const max_size_20 = BuilderM.max_size_20;
    pub const max_size_neg_20 = BuilderM.max_size_neg_20;
    pub const max_size_24 = BuilderM.max_size_24;
    pub const max_size_neg_24 = BuilderM.max_size_neg_24;
    pub const max_size_32 = BuilderM.max_size_32;
    pub const max_size_neg_32 = BuilderM.max_size_neg_32;
    pub const max_size_40 = BuilderM.max_size_40;
    pub const max_size_neg_40 = BuilderM.max_size_neg_40;
    pub const max_size_48 = BuilderM.max_size_48;
    pub const max_size_neg_48 = BuilderM.max_size_neg_48;
    pub const max_size_56 = BuilderM.max_size_56;
    pub const max_size_neg_56 = BuilderM.max_size_neg_56;
    pub const max_size_64 = BuilderM.max_size_64;
    pub const max_size_neg_64 = BuilderM.max_size_neg_64;
    pub const max_size_72 = BuilderM.max_size_72;
    pub const max_size_neg_72 = BuilderM.max_size_neg_72;
    pub const max_size_80 = BuilderM.max_size_80;
    pub const max_size_neg_80 = BuilderM.max_size_neg_80;
    pub const max_size_96 = BuilderM.max_size_96;
    pub const max_size_neg_96 = BuilderM.max_size_neg_96;
    pub const max_size_112 = BuilderM.max_size_112;
    pub const max_size_neg_112 = BuilderM.max_size_neg_112;
    pub const max_size_128 = BuilderM.max_size_128;
    pub const max_size_neg_128 = BuilderM.max_size_neg_128;
    pub const max_size_auto = BuilderM.max_size_auto;
    pub const max_size_px = BuilderM.max_size_px;
    pub const max_size_neg_px = BuilderM.max_size_neg_px;
    pub const max_size_full = BuilderM.max_size_full;
    pub const max_size_neg_full = BuilderM.max_size_neg_full;
    pub const max_size_1_2 = BuilderM.max_size_1_2;
    pub const max_size_neg_1_2 = BuilderM.max_size_neg_1_2;
    pub const max_size_1_3 = BuilderM.max_size_1_3;
    pub const max_size_neg_1_3 = BuilderM.max_size_neg_1_3;
    pub const max_size_2_3 = BuilderM.max_size_2_3;
    pub const max_size_neg_2_3 = BuilderM.max_size_neg_2_3;
    pub const max_size_1_4 = BuilderM.max_size_1_4;
    pub const max_size_neg_1_4 = BuilderM.max_size_neg_1_4;
    pub const max_size_2_4 = BuilderM.max_size_2_4;
    pub const max_size_neg_2_4 = BuilderM.max_size_neg_2_4;
    pub const max_size_3_4 = BuilderM.max_size_3_4;
    pub const max_size_neg_3_4 = BuilderM.max_size_neg_3_4;
    pub const max_size_1_5 = BuilderM.max_size_1_5;
    pub const max_size_neg_1_5 = BuilderM.max_size_neg_1_5;
    pub const max_size_2_5 = BuilderM.max_size_2_5;
    pub const max_size_neg_2_5 = BuilderM.max_size_neg_2_5;
    pub const max_size_3_5 = BuilderM.max_size_3_5;
    pub const max_size_neg_3_5 = BuilderM.max_size_neg_3_5;
    pub const max_size_4_5 = BuilderM.max_size_4_5;
    pub const max_size_neg_4_5 = BuilderM.max_size_neg_4_5;
    pub const max_size_1_6 = BuilderM.max_size_1_6;
    pub const max_size_neg_1_6 = BuilderM.max_size_neg_1_6;
    pub const max_size_5_6 = BuilderM.max_size_5_6;
    pub const max_size_neg_5_6 = BuilderM.max_size_neg_5_6;
    pub const max_size_1_12 = BuilderM.max_size_1_12;
    pub const max_size_neg_1_12 = BuilderM.max_size_neg_1_12;
    pub const max_w = BuilderM.max_w;
    pub const max_w_0 = BuilderM.max_w_0;
    pub const max_w_neg_0 = BuilderM.max_w_neg_0;
    pub const max_w_0p5 = BuilderM.max_w_0p5;
    pub const max_w_neg_0p5 = BuilderM.max_w_neg_0p5;
    pub const max_w_1 = BuilderM.max_w_1;
    pub const max_w_neg_1 = BuilderM.max_w_neg_1;
    pub const max_w_1p5 = BuilderM.max_w_1p5;
    pub const max_w_neg_1p5 = BuilderM.max_w_neg_1p5;
    pub const max_w_2 = BuilderM.max_w_2;
    pub const max_w_neg_2 = BuilderM.max_w_neg_2;
    pub const max_w_2p5 = BuilderM.max_w_2p5;
    pub const max_w_neg_2p5 = BuilderM.max_w_neg_2p5;
    pub const max_w_3 = BuilderM.max_w_3;
    pub const max_w_neg_3 = BuilderM.max_w_neg_3;
    pub const max_w_3p5 = BuilderM.max_w_3p5;
    pub const max_w_neg_3p5 = BuilderM.max_w_neg_3p5;
    pub const max_w_4 = BuilderM.max_w_4;
    pub const max_w_neg_4 = BuilderM.max_w_neg_4;
    pub const max_w_5 = BuilderM.max_w_5;
    pub const max_w_neg_5 = BuilderM.max_w_neg_5;
    pub const max_w_6 = BuilderM.max_w_6;
    pub const max_w_neg_6 = BuilderM.max_w_neg_6;
    pub const max_w_7 = BuilderM.max_w_7;
    pub const max_w_neg_7 = BuilderM.max_w_neg_7;
    pub const max_w_8 = BuilderM.max_w_8;
    pub const max_w_neg_8 = BuilderM.max_w_neg_8;
    pub const max_w_9 = BuilderM.max_w_9;
    pub const max_w_neg_9 = BuilderM.max_w_neg_9;
    pub const max_w_10 = BuilderM.max_w_10;
    pub const max_w_neg_10 = BuilderM.max_w_neg_10;
    pub const max_w_11 = BuilderM.max_w_11;
    pub const max_w_neg_11 = BuilderM.max_w_neg_11;
    pub const max_w_12 = BuilderM.max_w_12;
    pub const max_w_neg_12 = BuilderM.max_w_neg_12;
    pub const max_w_16 = BuilderM.max_w_16;
    pub const max_w_neg_16 = BuilderM.max_w_neg_16;
    pub const max_w_20 = BuilderM.max_w_20;
    pub const max_w_neg_20 = BuilderM.max_w_neg_20;
    pub const max_w_24 = BuilderM.max_w_24;
    pub const max_w_neg_24 = BuilderM.max_w_neg_24;
    pub const max_w_32 = BuilderM.max_w_32;
    pub const max_w_neg_32 = BuilderM.max_w_neg_32;
    pub const max_w_40 = BuilderM.max_w_40;
    pub const max_w_neg_40 = BuilderM.max_w_neg_40;
    pub const max_w_48 = BuilderM.max_w_48;
    pub const max_w_neg_48 = BuilderM.max_w_neg_48;
    pub const max_w_56 = BuilderM.max_w_56;
    pub const max_w_neg_56 = BuilderM.max_w_neg_56;
    pub const max_w_64 = BuilderM.max_w_64;
    pub const max_w_neg_64 = BuilderM.max_w_neg_64;
    pub const max_w_72 = BuilderM.max_w_72;
    pub const max_w_neg_72 = BuilderM.max_w_neg_72;
    pub const max_w_80 = BuilderM.max_w_80;
    pub const max_w_neg_80 = BuilderM.max_w_neg_80;
    pub const max_w_96 = BuilderM.max_w_96;
    pub const max_w_neg_96 = BuilderM.max_w_neg_96;
    pub const max_w_112 = BuilderM.max_w_112;
    pub const max_w_neg_112 = BuilderM.max_w_neg_112;
    pub const max_w_128 = BuilderM.max_w_128;
    pub const max_w_neg_128 = BuilderM.max_w_neg_128;
    pub const max_w_auto = BuilderM.max_w_auto;
    pub const max_w_px = BuilderM.max_w_px;
    pub const max_w_neg_px = BuilderM.max_w_neg_px;
    pub const max_w_full = BuilderM.max_w_full;
    pub const max_w_neg_full = BuilderM.max_w_neg_full;
    pub const max_w_1_2 = BuilderM.max_w_1_2;
    pub const max_w_neg_1_2 = BuilderM.max_w_neg_1_2;
    pub const max_w_1_3 = BuilderM.max_w_1_3;
    pub const max_w_neg_1_3 = BuilderM.max_w_neg_1_3;
    pub const max_w_2_3 = BuilderM.max_w_2_3;
    pub const max_w_neg_2_3 = BuilderM.max_w_neg_2_3;
    pub const max_w_1_4 = BuilderM.max_w_1_4;
    pub const max_w_neg_1_4 = BuilderM.max_w_neg_1_4;
    pub const max_w_2_4 = BuilderM.max_w_2_4;
    pub const max_w_neg_2_4 = BuilderM.max_w_neg_2_4;
    pub const max_w_3_4 = BuilderM.max_w_3_4;
    pub const max_w_neg_3_4 = BuilderM.max_w_neg_3_4;
    pub const max_w_1_5 = BuilderM.max_w_1_5;
    pub const max_w_neg_1_5 = BuilderM.max_w_neg_1_5;
    pub const max_w_2_5 = BuilderM.max_w_2_5;
    pub const max_w_neg_2_5 = BuilderM.max_w_neg_2_5;
    pub const max_w_3_5 = BuilderM.max_w_3_5;
    pub const max_w_neg_3_5 = BuilderM.max_w_neg_3_5;
    pub const max_w_4_5 = BuilderM.max_w_4_5;
    pub const max_w_neg_4_5 = BuilderM.max_w_neg_4_5;
    pub const max_w_1_6 = BuilderM.max_w_1_6;
    pub const max_w_neg_1_6 = BuilderM.max_w_neg_1_6;
    pub const max_w_5_6 = BuilderM.max_w_5_6;
    pub const max_w_neg_5_6 = BuilderM.max_w_neg_5_6;
    pub const max_w_1_12 = BuilderM.max_w_1_12;
    pub const max_w_neg_1_12 = BuilderM.max_w_neg_1_12;
    pub const max_h = BuilderM.max_h;
    pub const max_h_0 = BuilderM.max_h_0;
    pub const max_h_neg_0 = BuilderM.max_h_neg_0;
    pub const max_h_0p5 = BuilderM.max_h_0p5;
    pub const max_h_neg_0p5 = BuilderM.max_h_neg_0p5;
    pub const max_h_1 = BuilderM.max_h_1;
    pub const max_h_neg_1 = BuilderM.max_h_neg_1;
    pub const max_h_1p5 = BuilderM.max_h_1p5;
    pub const max_h_neg_1p5 = BuilderM.max_h_neg_1p5;
    pub const max_h_2 = BuilderM.max_h_2;
    pub const max_h_neg_2 = BuilderM.max_h_neg_2;
    pub const max_h_2p5 = BuilderM.max_h_2p5;
    pub const max_h_neg_2p5 = BuilderM.max_h_neg_2p5;
    pub const max_h_3 = BuilderM.max_h_3;
    pub const max_h_neg_3 = BuilderM.max_h_neg_3;
    pub const max_h_3p5 = BuilderM.max_h_3p5;
    pub const max_h_neg_3p5 = BuilderM.max_h_neg_3p5;
    pub const max_h_4 = BuilderM.max_h_4;
    pub const max_h_neg_4 = BuilderM.max_h_neg_4;
    pub const max_h_5 = BuilderM.max_h_5;
    pub const max_h_neg_5 = BuilderM.max_h_neg_5;
    pub const max_h_6 = BuilderM.max_h_6;
    pub const max_h_neg_6 = BuilderM.max_h_neg_6;
    pub const max_h_7 = BuilderM.max_h_7;
    pub const max_h_neg_7 = BuilderM.max_h_neg_7;
    pub const max_h_8 = BuilderM.max_h_8;
    pub const max_h_neg_8 = BuilderM.max_h_neg_8;
    pub const max_h_9 = BuilderM.max_h_9;
    pub const max_h_neg_9 = BuilderM.max_h_neg_9;
    pub const max_h_10 = BuilderM.max_h_10;
    pub const max_h_neg_10 = BuilderM.max_h_neg_10;
    pub const max_h_11 = BuilderM.max_h_11;
    pub const max_h_neg_11 = BuilderM.max_h_neg_11;
    pub const max_h_12 = BuilderM.max_h_12;
    pub const max_h_neg_12 = BuilderM.max_h_neg_12;
    pub const max_h_16 = BuilderM.max_h_16;
    pub const max_h_neg_16 = BuilderM.max_h_neg_16;
    pub const max_h_20 = BuilderM.max_h_20;
    pub const max_h_neg_20 = BuilderM.max_h_neg_20;
    pub const max_h_24 = BuilderM.max_h_24;
    pub const max_h_neg_24 = BuilderM.max_h_neg_24;
    pub const max_h_32 = BuilderM.max_h_32;
    pub const max_h_neg_32 = BuilderM.max_h_neg_32;
    pub const max_h_40 = BuilderM.max_h_40;
    pub const max_h_neg_40 = BuilderM.max_h_neg_40;
    pub const max_h_48 = BuilderM.max_h_48;
    pub const max_h_neg_48 = BuilderM.max_h_neg_48;
    pub const max_h_56 = BuilderM.max_h_56;
    pub const max_h_neg_56 = BuilderM.max_h_neg_56;
    pub const max_h_64 = BuilderM.max_h_64;
    pub const max_h_neg_64 = BuilderM.max_h_neg_64;
    pub const max_h_72 = BuilderM.max_h_72;
    pub const max_h_neg_72 = BuilderM.max_h_neg_72;
    pub const max_h_80 = BuilderM.max_h_80;
    pub const max_h_neg_80 = BuilderM.max_h_neg_80;
    pub const max_h_96 = BuilderM.max_h_96;
    pub const max_h_neg_96 = BuilderM.max_h_neg_96;
    pub const max_h_112 = BuilderM.max_h_112;
    pub const max_h_neg_112 = BuilderM.max_h_neg_112;
    pub const max_h_128 = BuilderM.max_h_128;
    pub const max_h_neg_128 = BuilderM.max_h_neg_128;
    pub const max_h_auto = BuilderM.max_h_auto;
    pub const max_h_px = BuilderM.max_h_px;
    pub const max_h_neg_px = BuilderM.max_h_neg_px;
    pub const max_h_full = BuilderM.max_h_full;
    pub const max_h_neg_full = BuilderM.max_h_neg_full;
    pub const max_h_1_2 = BuilderM.max_h_1_2;
    pub const max_h_neg_1_2 = BuilderM.max_h_neg_1_2;
    pub const max_h_1_3 = BuilderM.max_h_1_3;
    pub const max_h_neg_1_3 = BuilderM.max_h_neg_1_3;
    pub const max_h_2_3 = BuilderM.max_h_2_3;
    pub const max_h_neg_2_3 = BuilderM.max_h_neg_2_3;
    pub const max_h_1_4 = BuilderM.max_h_1_4;
    pub const max_h_neg_1_4 = BuilderM.max_h_neg_1_4;
    pub const max_h_2_4 = BuilderM.max_h_2_4;
    pub const max_h_neg_2_4 = BuilderM.max_h_neg_2_4;
    pub const max_h_3_4 = BuilderM.max_h_3_4;
    pub const max_h_neg_3_4 = BuilderM.max_h_neg_3_4;
    pub const max_h_1_5 = BuilderM.max_h_1_5;
    pub const max_h_neg_1_5 = BuilderM.max_h_neg_1_5;
    pub const max_h_2_5 = BuilderM.max_h_2_5;
    pub const max_h_neg_2_5 = BuilderM.max_h_neg_2_5;
    pub const max_h_3_5 = BuilderM.max_h_3_5;
    pub const max_h_neg_3_5 = BuilderM.max_h_neg_3_5;
    pub const max_h_4_5 = BuilderM.max_h_4_5;
    pub const max_h_neg_4_5 = BuilderM.max_h_neg_4_5;
    pub const max_h_1_6 = BuilderM.max_h_1_6;
    pub const max_h_neg_1_6 = BuilderM.max_h_neg_1_6;
    pub const max_h_5_6 = BuilderM.max_h_5_6;
    pub const max_h_neg_5_6 = BuilderM.max_h_neg_5_6;
    pub const max_h_1_12 = BuilderM.max_h_1_12;
    pub const max_h_neg_1_12 = BuilderM.max_h_neg_1_12;
    pub const gap = BuilderM.gap;
    pub const gap_0 = BuilderM.gap_0;
    pub const gap_neg_0 = BuilderM.gap_neg_0;
    pub const gap_0p5 = BuilderM.gap_0p5;
    pub const gap_neg_0p5 = BuilderM.gap_neg_0p5;
    pub const gap_1 = BuilderM.gap_1;
    pub const gap_neg_1 = BuilderM.gap_neg_1;
    pub const gap_1p5 = BuilderM.gap_1p5;
    pub const gap_neg_1p5 = BuilderM.gap_neg_1p5;
    pub const gap_2 = BuilderM.gap_2;
    pub const gap_neg_2 = BuilderM.gap_neg_2;
    pub const gap_2p5 = BuilderM.gap_2p5;
    pub const gap_neg_2p5 = BuilderM.gap_neg_2p5;
    pub const gap_3 = BuilderM.gap_3;
    pub const gap_neg_3 = BuilderM.gap_neg_3;
    pub const gap_3p5 = BuilderM.gap_3p5;
    pub const gap_neg_3p5 = BuilderM.gap_neg_3p5;
    pub const gap_4 = BuilderM.gap_4;
    pub const gap_neg_4 = BuilderM.gap_neg_4;
    pub const gap_5 = BuilderM.gap_5;
    pub const gap_neg_5 = BuilderM.gap_neg_5;
    pub const gap_6 = BuilderM.gap_6;
    pub const gap_neg_6 = BuilderM.gap_neg_6;
    pub const gap_7 = BuilderM.gap_7;
    pub const gap_neg_7 = BuilderM.gap_neg_7;
    pub const gap_8 = BuilderM.gap_8;
    pub const gap_neg_8 = BuilderM.gap_neg_8;
    pub const gap_9 = BuilderM.gap_9;
    pub const gap_neg_9 = BuilderM.gap_neg_9;
    pub const gap_10 = BuilderM.gap_10;
    pub const gap_neg_10 = BuilderM.gap_neg_10;
    pub const gap_11 = BuilderM.gap_11;
    pub const gap_neg_11 = BuilderM.gap_neg_11;
    pub const gap_12 = BuilderM.gap_12;
    pub const gap_neg_12 = BuilderM.gap_neg_12;
    pub const gap_16 = BuilderM.gap_16;
    pub const gap_neg_16 = BuilderM.gap_neg_16;
    pub const gap_20 = BuilderM.gap_20;
    pub const gap_neg_20 = BuilderM.gap_neg_20;
    pub const gap_24 = BuilderM.gap_24;
    pub const gap_neg_24 = BuilderM.gap_neg_24;
    pub const gap_32 = BuilderM.gap_32;
    pub const gap_neg_32 = BuilderM.gap_neg_32;
    pub const gap_40 = BuilderM.gap_40;
    pub const gap_neg_40 = BuilderM.gap_neg_40;
    pub const gap_48 = BuilderM.gap_48;
    pub const gap_neg_48 = BuilderM.gap_neg_48;
    pub const gap_56 = BuilderM.gap_56;
    pub const gap_neg_56 = BuilderM.gap_neg_56;
    pub const gap_64 = BuilderM.gap_64;
    pub const gap_neg_64 = BuilderM.gap_neg_64;
    pub const gap_72 = BuilderM.gap_72;
    pub const gap_neg_72 = BuilderM.gap_neg_72;
    pub const gap_80 = BuilderM.gap_80;
    pub const gap_neg_80 = BuilderM.gap_neg_80;
    pub const gap_96 = BuilderM.gap_96;
    pub const gap_neg_96 = BuilderM.gap_neg_96;
    pub const gap_112 = BuilderM.gap_112;
    pub const gap_neg_112 = BuilderM.gap_neg_112;
    pub const gap_128 = BuilderM.gap_128;
    pub const gap_neg_128 = BuilderM.gap_neg_128;
    pub const gap_px = BuilderM.gap_px;
    pub const gap_neg_px = BuilderM.gap_neg_px;
    pub const gap_full = BuilderM.gap_full;
    pub const gap_neg_full = BuilderM.gap_neg_full;
    pub const gap_1_2 = BuilderM.gap_1_2;
    pub const gap_neg_1_2 = BuilderM.gap_neg_1_2;
    pub const gap_1_3 = BuilderM.gap_1_3;
    pub const gap_neg_1_3 = BuilderM.gap_neg_1_3;
    pub const gap_2_3 = BuilderM.gap_2_3;
    pub const gap_neg_2_3 = BuilderM.gap_neg_2_3;
    pub const gap_1_4 = BuilderM.gap_1_4;
    pub const gap_neg_1_4 = BuilderM.gap_neg_1_4;
    pub const gap_2_4 = BuilderM.gap_2_4;
    pub const gap_neg_2_4 = BuilderM.gap_neg_2_4;
    pub const gap_3_4 = BuilderM.gap_3_4;
    pub const gap_neg_3_4 = BuilderM.gap_neg_3_4;
    pub const gap_1_5 = BuilderM.gap_1_5;
    pub const gap_neg_1_5 = BuilderM.gap_neg_1_5;
    pub const gap_2_5 = BuilderM.gap_2_5;
    pub const gap_neg_2_5 = BuilderM.gap_neg_2_5;
    pub const gap_3_5 = BuilderM.gap_3_5;
    pub const gap_neg_3_5 = BuilderM.gap_neg_3_5;
    pub const gap_4_5 = BuilderM.gap_4_5;
    pub const gap_neg_4_5 = BuilderM.gap_neg_4_5;
    pub const gap_1_6 = BuilderM.gap_1_6;
    pub const gap_neg_1_6 = BuilderM.gap_neg_1_6;
    pub const gap_5_6 = BuilderM.gap_5_6;
    pub const gap_neg_5_6 = BuilderM.gap_neg_5_6;
    pub const gap_1_12 = BuilderM.gap_1_12;
    pub const gap_neg_1_12 = BuilderM.gap_neg_1_12;
    pub const gap_x = BuilderM.gap_x;
    pub const gap_x_0 = BuilderM.gap_x_0;
    pub const gap_x_neg_0 = BuilderM.gap_x_neg_0;
    pub const gap_x_0p5 = BuilderM.gap_x_0p5;
    pub const gap_x_neg_0p5 = BuilderM.gap_x_neg_0p5;
    pub const gap_x_1 = BuilderM.gap_x_1;
    pub const gap_x_neg_1 = BuilderM.gap_x_neg_1;
    pub const gap_x_1p5 = BuilderM.gap_x_1p5;
    pub const gap_x_neg_1p5 = BuilderM.gap_x_neg_1p5;
    pub const gap_x_2 = BuilderM.gap_x_2;
    pub const gap_x_neg_2 = BuilderM.gap_x_neg_2;
    pub const gap_x_2p5 = BuilderM.gap_x_2p5;
    pub const gap_x_neg_2p5 = BuilderM.gap_x_neg_2p5;
    pub const gap_x_3 = BuilderM.gap_x_3;
    pub const gap_x_neg_3 = BuilderM.gap_x_neg_3;
    pub const gap_x_3p5 = BuilderM.gap_x_3p5;
    pub const gap_x_neg_3p5 = BuilderM.gap_x_neg_3p5;
    pub const gap_x_4 = BuilderM.gap_x_4;
    pub const gap_x_neg_4 = BuilderM.gap_x_neg_4;
    pub const gap_x_5 = BuilderM.gap_x_5;
    pub const gap_x_neg_5 = BuilderM.gap_x_neg_5;
    pub const gap_x_6 = BuilderM.gap_x_6;
    pub const gap_x_neg_6 = BuilderM.gap_x_neg_6;
    pub const gap_x_7 = BuilderM.gap_x_7;
    pub const gap_x_neg_7 = BuilderM.gap_x_neg_7;
    pub const gap_x_8 = BuilderM.gap_x_8;
    pub const gap_x_neg_8 = BuilderM.gap_x_neg_8;
    pub const gap_x_9 = BuilderM.gap_x_9;
    pub const gap_x_neg_9 = BuilderM.gap_x_neg_9;
    pub const gap_x_10 = BuilderM.gap_x_10;
    pub const gap_x_neg_10 = BuilderM.gap_x_neg_10;
    pub const gap_x_11 = BuilderM.gap_x_11;
    pub const gap_x_neg_11 = BuilderM.gap_x_neg_11;
    pub const gap_x_12 = BuilderM.gap_x_12;
    pub const gap_x_neg_12 = BuilderM.gap_x_neg_12;
    pub const gap_x_16 = BuilderM.gap_x_16;
    pub const gap_x_neg_16 = BuilderM.gap_x_neg_16;
    pub const gap_x_20 = BuilderM.gap_x_20;
    pub const gap_x_neg_20 = BuilderM.gap_x_neg_20;
    pub const gap_x_24 = BuilderM.gap_x_24;
    pub const gap_x_neg_24 = BuilderM.gap_x_neg_24;
    pub const gap_x_32 = BuilderM.gap_x_32;
    pub const gap_x_neg_32 = BuilderM.gap_x_neg_32;
    pub const gap_x_40 = BuilderM.gap_x_40;
    pub const gap_x_neg_40 = BuilderM.gap_x_neg_40;
    pub const gap_x_48 = BuilderM.gap_x_48;
    pub const gap_x_neg_48 = BuilderM.gap_x_neg_48;
    pub const gap_x_56 = BuilderM.gap_x_56;
    pub const gap_x_neg_56 = BuilderM.gap_x_neg_56;
    pub const gap_x_64 = BuilderM.gap_x_64;
    pub const gap_x_neg_64 = BuilderM.gap_x_neg_64;
    pub const gap_x_72 = BuilderM.gap_x_72;
    pub const gap_x_neg_72 = BuilderM.gap_x_neg_72;
    pub const gap_x_80 = BuilderM.gap_x_80;
    pub const gap_x_neg_80 = BuilderM.gap_x_neg_80;
    pub const gap_x_96 = BuilderM.gap_x_96;
    pub const gap_x_neg_96 = BuilderM.gap_x_neg_96;
    pub const gap_x_112 = BuilderM.gap_x_112;
    pub const gap_x_neg_112 = BuilderM.gap_x_neg_112;
    pub const gap_x_128 = BuilderM.gap_x_128;
    pub const gap_x_neg_128 = BuilderM.gap_x_neg_128;
    pub const gap_x_px = BuilderM.gap_x_px;
    pub const gap_x_neg_px = BuilderM.gap_x_neg_px;
    pub const gap_x_full = BuilderM.gap_x_full;
    pub const gap_x_neg_full = BuilderM.gap_x_neg_full;
    pub const gap_x_1_2 = BuilderM.gap_x_1_2;
    pub const gap_x_neg_1_2 = BuilderM.gap_x_neg_1_2;
    pub const gap_x_1_3 = BuilderM.gap_x_1_3;
    pub const gap_x_neg_1_3 = BuilderM.gap_x_neg_1_3;
    pub const gap_x_2_3 = BuilderM.gap_x_2_3;
    pub const gap_x_neg_2_3 = BuilderM.gap_x_neg_2_3;
    pub const gap_x_1_4 = BuilderM.gap_x_1_4;
    pub const gap_x_neg_1_4 = BuilderM.gap_x_neg_1_4;
    pub const gap_x_2_4 = BuilderM.gap_x_2_4;
    pub const gap_x_neg_2_4 = BuilderM.gap_x_neg_2_4;
    pub const gap_x_3_4 = BuilderM.gap_x_3_4;
    pub const gap_x_neg_3_4 = BuilderM.gap_x_neg_3_4;
    pub const gap_x_1_5 = BuilderM.gap_x_1_5;
    pub const gap_x_neg_1_5 = BuilderM.gap_x_neg_1_5;
    pub const gap_x_2_5 = BuilderM.gap_x_2_5;
    pub const gap_x_neg_2_5 = BuilderM.gap_x_neg_2_5;
    pub const gap_x_3_5 = BuilderM.gap_x_3_5;
    pub const gap_x_neg_3_5 = BuilderM.gap_x_neg_3_5;
    pub const gap_x_4_5 = BuilderM.gap_x_4_5;
    pub const gap_x_neg_4_5 = BuilderM.gap_x_neg_4_5;
    pub const gap_x_1_6 = BuilderM.gap_x_1_6;
    pub const gap_x_neg_1_6 = BuilderM.gap_x_neg_1_6;
    pub const gap_x_5_6 = BuilderM.gap_x_5_6;
    pub const gap_x_neg_5_6 = BuilderM.gap_x_neg_5_6;
    pub const gap_x_1_12 = BuilderM.gap_x_1_12;
    pub const gap_x_neg_1_12 = BuilderM.gap_x_neg_1_12;
    pub const gap_y = BuilderM.gap_y;
    pub const gap_y_0 = BuilderM.gap_y_0;
    pub const gap_y_neg_0 = BuilderM.gap_y_neg_0;
    pub const gap_y_0p5 = BuilderM.gap_y_0p5;
    pub const gap_y_neg_0p5 = BuilderM.gap_y_neg_0p5;
    pub const gap_y_1 = BuilderM.gap_y_1;
    pub const gap_y_neg_1 = BuilderM.gap_y_neg_1;
    pub const gap_y_1p5 = BuilderM.gap_y_1p5;
    pub const gap_y_neg_1p5 = BuilderM.gap_y_neg_1p5;
    pub const gap_y_2 = BuilderM.gap_y_2;
    pub const gap_y_neg_2 = BuilderM.gap_y_neg_2;
    pub const gap_y_2p5 = BuilderM.gap_y_2p5;
    pub const gap_y_neg_2p5 = BuilderM.gap_y_neg_2p5;
    pub const gap_y_3 = BuilderM.gap_y_3;
    pub const gap_y_neg_3 = BuilderM.gap_y_neg_3;
    pub const gap_y_3p5 = BuilderM.gap_y_3p5;
    pub const gap_y_neg_3p5 = BuilderM.gap_y_neg_3p5;
    pub const gap_y_4 = BuilderM.gap_y_4;
    pub const gap_y_neg_4 = BuilderM.gap_y_neg_4;
    pub const gap_y_5 = BuilderM.gap_y_5;
    pub const gap_y_neg_5 = BuilderM.gap_y_neg_5;
    pub const gap_y_6 = BuilderM.gap_y_6;
    pub const gap_y_neg_6 = BuilderM.gap_y_neg_6;
    pub const gap_y_7 = BuilderM.gap_y_7;
    pub const gap_y_neg_7 = BuilderM.gap_y_neg_7;
    pub const gap_y_8 = BuilderM.gap_y_8;
    pub const gap_y_neg_8 = BuilderM.gap_y_neg_8;
    pub const gap_y_9 = BuilderM.gap_y_9;
    pub const gap_y_neg_9 = BuilderM.gap_y_neg_9;
    pub const gap_y_10 = BuilderM.gap_y_10;
    pub const gap_y_neg_10 = BuilderM.gap_y_neg_10;
    pub const gap_y_11 = BuilderM.gap_y_11;
    pub const gap_y_neg_11 = BuilderM.gap_y_neg_11;
    pub const gap_y_12 = BuilderM.gap_y_12;
    pub const gap_y_neg_12 = BuilderM.gap_y_neg_12;
    pub const gap_y_16 = BuilderM.gap_y_16;
    pub const gap_y_neg_16 = BuilderM.gap_y_neg_16;
    pub const gap_y_20 = BuilderM.gap_y_20;
    pub const gap_y_neg_20 = BuilderM.gap_y_neg_20;
    pub const gap_y_24 = BuilderM.gap_y_24;
    pub const gap_y_neg_24 = BuilderM.gap_y_neg_24;
    pub const gap_y_32 = BuilderM.gap_y_32;
    pub const gap_y_neg_32 = BuilderM.gap_y_neg_32;
    pub const gap_y_40 = BuilderM.gap_y_40;
    pub const gap_y_neg_40 = BuilderM.gap_y_neg_40;
    pub const gap_y_48 = BuilderM.gap_y_48;
    pub const gap_y_neg_48 = BuilderM.gap_y_neg_48;
    pub const gap_y_56 = BuilderM.gap_y_56;
    pub const gap_y_neg_56 = BuilderM.gap_y_neg_56;
    pub const gap_y_64 = BuilderM.gap_y_64;
    pub const gap_y_neg_64 = BuilderM.gap_y_neg_64;
    pub const gap_y_72 = BuilderM.gap_y_72;
    pub const gap_y_neg_72 = BuilderM.gap_y_neg_72;
    pub const gap_y_80 = BuilderM.gap_y_80;
    pub const gap_y_neg_80 = BuilderM.gap_y_neg_80;
    pub const gap_y_96 = BuilderM.gap_y_96;
    pub const gap_y_neg_96 = BuilderM.gap_y_neg_96;
    pub const gap_y_112 = BuilderM.gap_y_112;
    pub const gap_y_neg_112 = BuilderM.gap_y_neg_112;
    pub const gap_y_128 = BuilderM.gap_y_128;
    pub const gap_y_neg_128 = BuilderM.gap_y_neg_128;
    pub const gap_y_px = BuilderM.gap_y_px;
    pub const gap_y_neg_px = BuilderM.gap_y_neg_px;
    pub const gap_y_full = BuilderM.gap_y_full;
    pub const gap_y_neg_full = BuilderM.gap_y_neg_full;
    pub const gap_y_1_2 = BuilderM.gap_y_1_2;
    pub const gap_y_neg_1_2 = BuilderM.gap_y_neg_1_2;
    pub const gap_y_1_3 = BuilderM.gap_y_1_3;
    pub const gap_y_neg_1_3 = BuilderM.gap_y_neg_1_3;
    pub const gap_y_2_3 = BuilderM.gap_y_2_3;
    pub const gap_y_neg_2_3 = BuilderM.gap_y_neg_2_3;
    pub const gap_y_1_4 = BuilderM.gap_y_1_4;
    pub const gap_y_neg_1_4 = BuilderM.gap_y_neg_1_4;
    pub const gap_y_2_4 = BuilderM.gap_y_2_4;
    pub const gap_y_neg_2_4 = BuilderM.gap_y_neg_2_4;
    pub const gap_y_3_4 = BuilderM.gap_y_3_4;
    pub const gap_y_neg_3_4 = BuilderM.gap_y_neg_3_4;
    pub const gap_y_1_5 = BuilderM.gap_y_1_5;
    pub const gap_y_neg_1_5 = BuilderM.gap_y_neg_1_5;
    pub const gap_y_2_5 = BuilderM.gap_y_2_5;
    pub const gap_y_neg_2_5 = BuilderM.gap_y_neg_2_5;
    pub const gap_y_3_5 = BuilderM.gap_y_3_5;
    pub const gap_y_neg_3_5 = BuilderM.gap_y_neg_3_5;
    pub const gap_y_4_5 = BuilderM.gap_y_4_5;
    pub const gap_y_neg_4_5 = BuilderM.gap_y_neg_4_5;
    pub const gap_y_1_6 = BuilderM.gap_y_1_6;
    pub const gap_y_neg_1_6 = BuilderM.gap_y_neg_1_6;
    pub const gap_y_5_6 = BuilderM.gap_y_5_6;
    pub const gap_y_neg_5_6 = BuilderM.gap_y_neg_5_6;
    pub const gap_y_1_12 = BuilderM.gap_y_1_12;
    pub const gap_y_neg_1_12 = BuilderM.gap_y_neg_1_12;
    pub const rounded = BuilderM.rounded;
    pub const rounded_none = BuilderM.rounded_none;
    pub const rounded_xs = BuilderM.rounded_xs;
    pub const rounded_sm = BuilderM.rounded_sm;
    pub const rounded_md = BuilderM.rounded_md;
    pub const rounded_lg = BuilderM.rounded_lg;
    pub const rounded_xl = BuilderM.rounded_xl;
    pub const rounded_2xl = BuilderM.rounded_2xl;
    pub const rounded_3xl = BuilderM.rounded_3xl;
    pub const rounded_full = BuilderM.rounded_full;
    pub const rounded_t = BuilderM.rounded_t;
    pub const rounded_t_none = BuilderM.rounded_t_none;
    pub const rounded_t_xs = BuilderM.rounded_t_xs;
    pub const rounded_t_sm = BuilderM.rounded_t_sm;
    pub const rounded_t_md = BuilderM.rounded_t_md;
    pub const rounded_t_lg = BuilderM.rounded_t_lg;
    pub const rounded_t_xl = BuilderM.rounded_t_xl;
    pub const rounded_t_2xl = BuilderM.rounded_t_2xl;
    pub const rounded_t_3xl = BuilderM.rounded_t_3xl;
    pub const rounded_t_full = BuilderM.rounded_t_full;
    pub const rounded_b = BuilderM.rounded_b;
    pub const rounded_b_none = BuilderM.rounded_b_none;
    pub const rounded_b_xs = BuilderM.rounded_b_xs;
    pub const rounded_b_sm = BuilderM.rounded_b_sm;
    pub const rounded_b_md = BuilderM.rounded_b_md;
    pub const rounded_b_lg = BuilderM.rounded_b_lg;
    pub const rounded_b_xl = BuilderM.rounded_b_xl;
    pub const rounded_b_2xl = BuilderM.rounded_b_2xl;
    pub const rounded_b_3xl = BuilderM.rounded_b_3xl;
    pub const rounded_b_full = BuilderM.rounded_b_full;
    pub const rounded_r = BuilderM.rounded_r;
    pub const rounded_r_none = BuilderM.rounded_r_none;
    pub const rounded_r_xs = BuilderM.rounded_r_xs;
    pub const rounded_r_sm = BuilderM.rounded_r_sm;
    pub const rounded_r_md = BuilderM.rounded_r_md;
    pub const rounded_r_lg = BuilderM.rounded_r_lg;
    pub const rounded_r_xl = BuilderM.rounded_r_xl;
    pub const rounded_r_2xl = BuilderM.rounded_r_2xl;
    pub const rounded_r_3xl = BuilderM.rounded_r_3xl;
    pub const rounded_r_full = BuilderM.rounded_r_full;
    pub const rounded_l = BuilderM.rounded_l;
    pub const rounded_l_none = BuilderM.rounded_l_none;
    pub const rounded_l_xs = BuilderM.rounded_l_xs;
    pub const rounded_l_sm = BuilderM.rounded_l_sm;
    pub const rounded_l_md = BuilderM.rounded_l_md;
    pub const rounded_l_lg = BuilderM.rounded_l_lg;
    pub const rounded_l_xl = BuilderM.rounded_l_xl;
    pub const rounded_l_2xl = BuilderM.rounded_l_2xl;
    pub const rounded_l_3xl = BuilderM.rounded_l_3xl;
    pub const rounded_l_full = BuilderM.rounded_l_full;
    pub const rounded_tl = BuilderM.rounded_tl;
    pub const rounded_tl_none = BuilderM.rounded_tl_none;
    pub const rounded_tl_xs = BuilderM.rounded_tl_xs;
    pub const rounded_tl_sm = BuilderM.rounded_tl_sm;
    pub const rounded_tl_md = BuilderM.rounded_tl_md;
    pub const rounded_tl_lg = BuilderM.rounded_tl_lg;
    pub const rounded_tl_xl = BuilderM.rounded_tl_xl;
    pub const rounded_tl_2xl = BuilderM.rounded_tl_2xl;
    pub const rounded_tl_3xl = BuilderM.rounded_tl_3xl;
    pub const rounded_tl_full = BuilderM.rounded_tl_full;
    pub const rounded_tr = BuilderM.rounded_tr;
    pub const rounded_tr_none = BuilderM.rounded_tr_none;
    pub const rounded_tr_xs = BuilderM.rounded_tr_xs;
    pub const rounded_tr_sm = BuilderM.rounded_tr_sm;
    pub const rounded_tr_md = BuilderM.rounded_tr_md;
    pub const rounded_tr_lg = BuilderM.rounded_tr_lg;
    pub const rounded_tr_xl = BuilderM.rounded_tr_xl;
    pub const rounded_tr_2xl = BuilderM.rounded_tr_2xl;
    pub const rounded_tr_3xl = BuilderM.rounded_tr_3xl;
    pub const rounded_tr_full = BuilderM.rounded_tr_full;
    pub const rounded_bl = BuilderM.rounded_bl;
    pub const rounded_bl_none = BuilderM.rounded_bl_none;
    pub const rounded_bl_xs = BuilderM.rounded_bl_xs;
    pub const rounded_bl_sm = BuilderM.rounded_bl_sm;
    pub const rounded_bl_md = BuilderM.rounded_bl_md;
    pub const rounded_bl_lg = BuilderM.rounded_bl_lg;
    pub const rounded_bl_xl = BuilderM.rounded_bl_xl;
    pub const rounded_bl_2xl = BuilderM.rounded_bl_2xl;
    pub const rounded_bl_3xl = BuilderM.rounded_bl_3xl;
    pub const rounded_bl_full = BuilderM.rounded_bl_full;
    pub const rounded_br = BuilderM.rounded_br;
    pub const rounded_br_none = BuilderM.rounded_br_none;
    pub const rounded_br_xs = BuilderM.rounded_br_xs;
    pub const rounded_br_sm = BuilderM.rounded_br_sm;
    pub const rounded_br_md = BuilderM.rounded_br_md;
    pub const rounded_br_lg = BuilderM.rounded_br_lg;
    pub const rounded_br_xl = BuilderM.rounded_br_xl;
    pub const rounded_br_2xl = BuilderM.rounded_br_2xl;
    pub const rounded_br_3xl = BuilderM.rounded_br_3xl;
    pub const rounded_br_full = BuilderM.rounded_br_full;
    pub const shadow = BuilderM.shadow;
    pub const shadow_none = BuilderM.shadow_none;
    pub const shadow_2xs = BuilderM.shadow_2xs;
    pub const shadow_xs = BuilderM.shadow_xs;
    pub const shadow_sm = BuilderM.shadow_sm;
    pub const shadow_md = BuilderM.shadow_md;
    pub const shadow_lg = BuilderM.shadow_lg;
    pub const shadow_xl = BuilderM.shadow_xl;
    pub const shadow_2xl = BuilderM.shadow_2xl;
};

/// A fresh style refinement builder: `div().hover(style().bg(red()))`.
pub fn style() *StyleBuilder {
    const r = arena().create(StyleRefinement) catch oom();
    r.* = .{};
    return StyleBuilder.from(r);
}

// ---------------------------------------------------------------------------
// Interactivity.

const MouseDownL = struct { button: ?MouseButton, phase: DispatchPhase, listener: Listener(MouseDownEvent) };
const MouseUpL = struct { button: ?MouseButton, phase: DispatchPhase, listener: Listener(MouseUpEvent) };
const DownOutL = struct { listener: Listener(MouseDownEvent) };
const view_mod = @import("../view.zig");
const DROP_DRAG_THRESHOLD: f32 = 2;
const DEFAULT_TOOLTIP_SHOW_DELAY_NS: u64 = 500 * std.time.ns_per_ms;
const HOVERABLE_TOOLTIP_HIDE_DELAY_NS: u64 = 500 * std.time.ns_per_ms;

const DropL = struct {
    type_id: app_mod.TypeId,
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, value: *anyopaque, window: *Window, cx: *App) void,
};
const DragListener = struct {
    /// Makes the app's copy of the value and the view that shows it.
    start: *const fn (value: *anyopaque, offset: Point(Pixels), window: *Window, cx: *App) app_mod.AnyDrag,
    value: *anyopaque,
};
const DragOverStyle = struct { type_id: app_mod.TypeId, style: *StyleRefinement };

/// GPUI `DragMoveEvent<T>`: a drag of `T` moved. `event` is the mouse move, `bounds` the element's.
pub fn DragMoveEvent(comptime T: type) type {
    return struct {
        const Self = @This();
        event: MouseMoveEvent,
        bounds: Bounds(Pixels),
        item: *const T,

        /// The value being dragged (GPUI `drag`).
        pub fn drag(_: *const Self, cx: *const App) *const T {
            return cx.active_drag.?.value.downcast(T).?;
        }

        /// The item about to be dropped (GPUI `dragged_item`).
        pub fn dragged_item(self: *const Self) *const T {
            return self.item;
        }
    };
}

const DragMoveL = struct {
    type_id: app_mod.TypeId,
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, event: *const MouseMoveEvent, bounds: Bounds(Pixels), item: *anyopaque, window: *Window, cx: *App) void,
};

/// GPUI `HoverListenerMode`: whether `on_hover` honours the last input being the keyboard.
pub const HoverListenerMode = enum {
    input_modality_aware,
    input_modality_independent,

    pub fn is_hovered(self: HoverListenerMode, hitbox: *const Hitbox, window: *const Window) bool {
        return switch (self) {
            .input_modality_aware => hitbox.is_hovered(window),
            .input_modality_independent => hitbox.is_hovered_ignoring_last_input(window),
        };
    }
};

/// What `on_children_prepainted` hears: the bounds of the children in child order (GPUI passes a
/// `Vec<Bounds>`). Listeners take `*const PrepaintedChildren`, and `cx.listener` works with them.
pub const PrepaintedChildren = struct {
    bounds: []const Bounds(Pixels),
};

/// GPUI `ScrollAnchor`: scrolls an element that need not be a direct child of the scroll container.
pub const ScrollAnchor = struct {
    handle: ScrollHandle,
    /// Where the element was last painted, relative to the scroll content.
    last_origin: *Point(Pixels),

    pub fn for_handle(handle: ScrollHandle) ScrollAnchor {
        const allocator = handle.state.allocator orelse std.heap.page_allocator;
        const origin = allocator.create(Point(Pixels)) catch oom();
        origin.* = .{ .x = 0, .y = 0 };
        return .{ .handle = handle, .last_origin = origin };
    }

    /// Asks the handle's container to scroll this element to the top of its viewport. The container
    /// does it in its next prepaint (GPUI `scroll_to`, which runs on the next frame).
    pub fn scroll_to(self: ScrollAnchor, window: *Window, cx: *App) void {
        _ = cx;
        self.handle.state.anchor_request = self;
        window.refresh();
    }
};
const GroupDragOverStyle = struct { type_id: app_mod.TypeId, group: []const u8, style: *StyleRefinement };

/// Builds the view a tooltip shows. `ctx` may live in the frame arena: elements register
/// their builder again on every frame, so a timer firing later finds a live one.
pub const TooltipBuilder = struct {
    ctx: *anyopaque = undefined,
    build: *const fn (ctx: *anyopaque, window: *Window, cx: *App) view_mod.AnyView,

    pub fn from_fn(comptime f: fn (*Window, *App) view_mod.AnyView) TooltipBuilder {
        return .{ .build = struct {
            fn call(_: *anyopaque, window: *Window, cx: *App) view_mod.AnyView {
                return f(window, cx);
            }
        }.call };
    }

    pub fn with(ctx: anytype, comptime f: anytype) TooltipBuilder {
        const Ctx = @TypeOf(ctx);
        return .{ .ctx = @ptrCast(ctx), .build = struct {
            fn call(raw: *anyopaque, window: *Window, cx: *App) view_mod.AnyView {
                return f(@as(Ctx, @ptrCast(@alignCast(raw))), window, cx);
            }
        }.call };
    }
};

/// Where a tooltip is in its life (GPUI `ActiveTooltip`). Timers cannot be cancelled, so
/// each scheduled one carries a generation and does nothing if it has moved on.
pub const TooltipPhase = enum { none, waiting_for_show, visible, waiting_for_hide };

const UpOutL = struct { button: MouseButton, listener: Listener(MouseUpEvent) };

const ActionL = struct { action_type: app_mod.TypeId, phase: DispatchPhase, ctx: *anyopaque, func: key_dispatch.ActionFn };

/// Scroll position shared between an element and its owner (GPUI `ScrollHandle`).
pub const ScrollHandle = struct {
    state: *ScrollHandleState,

    pub fn new(allocator: std.mem.Allocator) ScrollHandle {
        const s = allocator.create(ScrollHandleState) catch oom();
        s.* = .{};
        return .{ .state = s };
    }
    pub fn offset(self: ScrollHandle) Point(Pixels) {
        return self.state.offset;
    }
    pub fn set_offset(self: ScrollHandle, o: Point(Pixels)) void {
        self.state.offset = o;
    }
    pub fn max_offset(self: ScrollHandle) Size(Pixels) {
        return self.state.max_offset;
    }
    pub fn bounds(self: ScrollHandle) Bounds(Pixels) {
        return self.state.bounds;
    }
    /// Scrolls to the bottom in the next prepaint, once the content size is known (GPUI).
    pub fn scroll_to_bottom(self: ScrollHandle) void {
        self.state.scroll_to_bottom = true;
    }
    /// The child at the top of the viewport (GPUI `top_item`).
    pub fn top_item(self: ScrollHandle) usize {
        return child_index_at(self.state.child_bounds.items, self.state.bounds.top() - self.state.offset.y);
    }
    /// The child at the bottom of the viewport (GPUI `bottom_item`).
    pub fn bottom_item(self: ScrollHandle) usize {
        return child_index_at(self.state.child_bounds.items, self.state.bounds.bottom() - self.state.offset.y);
    }
    /// The top child, and how far its top is above the viewport's top (GPUI `logical_scroll_top`).
    pub fn logical_scroll_top(self: ScrollHandle) struct { usize, Pixels } {
        const ix = self.top_item();
        const children = self.state.child_bounds.items;
        if (ix >= children.len) return .{ ix, 0 };
        return .{ ix, children[ix].top() + self.state.offset.y - self.state.bounds.top() };
    }
    /// The bottom child, and how far its bottom is below the viewport's bottom (GPUI `logical_scroll_bottom`).
    pub fn logical_scroll_bottom(self: ScrollHandle) struct { usize, Pixels } {
        const ix = self.bottom_item();
        const children = self.state.child_bounds.items;
        if (ix >= children.len) return .{ ix, 0 };
        return .{ ix, children[ix].bottom() + self.state.offset.y - self.state.bounds.bottom() };
    }
    pub fn scroll_to_top(self: ScrollHandle) void {
        self.state.offset.y = 0;
    }
    pub fn children_count(self: ScrollHandle) usize {
        return self.state.child_bounds.items.len;
    }
    pub fn bounds_for_item(self: ScrollHandle, ix: usize) ?Bounds(Pixels) {
        if (ix >= self.state.child_bounds.items.len) return null;
        return self.state.child_bounds.items[ix];
    }
    /// Scrolls the least needed to make child `ix` fully visible, in the next prepaint (GPUI `scroll_to_item`).
    pub fn scroll_to_item(self: ScrollHandle, ix: usize) void {
        self.state.active_item = .{ .index = ix, .strategy = .first_visible };
    }
    /// Scrolls so that child `ix` is the top one visible, in the next prepaint (GPUI `scroll_to_top_of_item`).
    pub fn scroll_to_top_of_item(self: ScrollHandle, ix: usize) void {
        self.state.active_item = .{ .index = ix, .strategy = .top };
    }

    /// Applies the requests made since the last prepaint, against the child bounds of that prepaint
    /// (GPUI `scroll_to_active_item`, and the `ScrollAnchor` request).
    fn scroll_to_active_item(self: ScrollHandle) void {
        const st = self.state;
        if (st.anchor_request) |anchor| {
            st.anchor_request = null;
            st.offset = .{ .x = st.bounds.origin.x - anchor.last_origin.x, .y = st.bounds.origin.y - anchor.last_origin.y };
        }
        const active = st.active_item orelse return;
        if (active.index >= st.child_bounds.items.len) return;
        const b = st.child_bounds.items[active.index];
        var off = st.offset;
        switch (active.strategy) {
            .first_visible => if (st.overflow.y == .scroll) {
                if (b.size.height > st.bounds.size.height) {
                    off.y = st.bounds.top() - b.top();
                } else if (b.top() + off.y < st.bounds.top()) {
                    off.y = st.bounds.top() - b.top();
                } else if (b.bottom() + off.y > st.bounds.bottom()) {
                    off.y = st.bounds.bottom() - b.bottom();
                }
            },
            .top => off.y = st.bounds.top() - b.top(),
        }
        if (st.overflow.x == .scroll) {
            if (b.size.width > st.bounds.size.width) {
                off.x = st.bounds.left() - b.left();
            } else if (b.left() + off.x < st.bounds.left()) {
                off.x = st.bounds.left() - b.left();
            } else if (b.right() + off.x > st.bounds.right()) {
                off.x = st.bounds.right() - b.right();
            }
        }
        st.offset = off;
        st.active_item = null;
    }
};

pub const ScrollHandleState = struct {
    offset: Point(Pixels) = .{ .x = 0, .y = 0 },
    bounds: Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    max_offset: Size(Pixels) = .{ .width = 0, .height = 0 },
    child_bounds: std.ArrayList(Bounds(Pixels)) = .empty,
    /// The child to scroll to in the next prepaint (GPUI `active_item`).
    active_item: ?ActiveScrollItem = null,
    /// Scroll to the bottom in the next prepaint (GPUI `scroll_to_bottom`).
    scroll_to_bottom: bool = false,
    /// An element asked to be scrolled to (GPUI `ScrollAnchor::scroll_to`), applied in the next prepaint.
    anchor_request: ?ScrollAnchor = null,
    /// The overflow of the tracked element, from its last prepaint.
    overflow: Point(style_mod.Overflow) = .{ .x = .visible, .y = .visible },
    allocator: ?std.mem.Allocator = null,
};

const ActiveScrollItem = struct {
    index: usize,
    strategy: enum { first_visible, top },
};

/// GPUI's binary search over child bounds, with its comparison: the child that contains `y`, or the
/// nearest one when none does.
fn child_index_at(children: []const Bounds(Pixels), y: Pixels) usize {
    if (children.len == 0) return 0;
    var size = children.len;
    var base: usize = 0;
    while (size > 1) {
        const half = size / 2;
        const mid = base + half;
        if (compare_child(children[mid], y) != .gt) base = mid;
        size -= half;
    }
    const c = compare_child(children[base], y);
    if (c == .eq) return base;
    return @min(base + @intFromBool(c == .lt), children.len - 1);
}

fn compare_child(child: Bounds(Pixels), y: Pixels) std.math.Order {
    if (y < child.top()) return .gt;
    if (y > child.bottom()) return .lt;
    return .eq;
}

/// Per-element state persisted across frames (GPUI `InteractiveElementState`).
fn to_tooltip_builder(build_tooltip: anytype) TooltipBuilder {
    const B = @TypeOf(build_tooltip);
    if (B == TooltipBuilder) return build_tooltip;
    return TooltipBuilder.from_fn(build_tooltip);
}

// -- tooltip state machine, ported from GPUI's register_tooltip_mouse_handlers ----

fn clear_tooltip(st: *InteractiveElementState, window: *Window, cx: *App) void {
    st.tooltip_generation +%= 1;
    const had = st.tooltip_phase != .none;
    st.tooltip_phase = .none;
    if (st.tooltip_view) |view| {
        st.tooltip_view = null;
        cx.release_entity(view.entity_id);
    }
    if (had) window.refresh();
}

fn pointer_on_tooltip(window: *const Window) bool {
    const b = window.tooltip_bounds orelse return false;
    return b.contains(window.mouse_position());
}

/// A click or a scroll closes a tooltip, unless it can be interacted with.
fn dismiss_tooltip_on_input(st: *InteractiveElementState, window: *Window, cx: *App) void {
    if (st.tooltip_hoverable or pointer_on_tooltip(window)) return;
    clear_tooltip(st, window, cx);
}

fn tooltip_on_mouse_move(st: *InteractiveElementState, hovered_now: bool, phase: DispatchPhase, show_delay_ns: u64, window: *Window, cx: *App) void {
    const hovered = hovered_now and st.pending_mouse_down == null;
    switch (st.tooltip_phase) {
        .none => if (hovered and phase == .bubble) {
            st.tooltip_generation +%= 1;
            st.tooltip_phase = .waiting_for_show;
            schedule_tooltip_timer(st, TooltipTimer.show, show_delay_ns, window, cx);
        },
        .waiting_for_show => if (!hovered) {
            st.tooltip_generation +%= 1;
            st.tooltip_phase = .none;
        },
        .visible => if (phase == .capture and !hovered and !(st.tooltip_hoverable and pointer_on_tooltip(window))) {
            window.refresh();
        },
        .waiting_for_hide => if (phase == .capture and (hovered or pointer_on_tooltip(window))) {
            window.refresh();
        },
    }
}

/// Runs while the tooltip is being placed. An element that stopped painting has no mouse
/// handlers left, so this is what finally closes its tooltip.
fn tooltip_check_visible(raw: *anyopaque, tooltip_bounds: Bounds(Pixels), window: *Window, cx: *App) bool {
    const st: *InteractiveElementState = @ptrCast(@alignCast(raw));
    const mouse = window.mouse_position();
    const hovered = !window.last_input_was_keyboard and st.pending_mouse_down == null and
        (st.tooltip_source_bounds.contains(mouse) or (st.tooltip_hoverable and tooltip_bounds.contains(mouse)));
    switch (st.tooltip_phase) {
        .visible => if (!hovered) {
            if (st.tooltip_hoverable) {
                st.tooltip_generation +%= 1;
                st.tooltip_phase = .waiting_for_hide;
                schedule_tooltip_timer(st, TooltipTimer.hide, HOVERABLE_TOOLTIP_HIDE_DELAY_NS, window, cx);
            } else {
                clear_tooltip(st, window, cx);
            }
        },
        .waiting_for_hide => if (hovered) {
            st.tooltip_generation +%= 1;
            st.tooltip_phase = .visible;
        },
        .none, .waiting_for_show => {},
    }
    return st.tooltip_phase == .visible or st.tooltip_phase == .waiting_for_hide;
}

/// A pending timer. Windows and elements can be gone by the time it fires, so it holds ids.
const TooltipTimer = struct {
    app: *App,
    window_id: window_mod.WindowId,
    state: *InteractiveElementState,
    generation: u64,

    /// Finds the state, if its window and element still exist and nothing else happened.
    fn live(self: TooltipTimer) ?*Window {
        const window = self.app.window_by_id(self.window_id) orelse return null;
        if (!window.owns_element_state(self.state) or self.state.tooltip_generation != self.generation) return null;
        return window;
    }

    fn show(self: TooltipTimer) void {
        const window = self.live() orelse return;
        const st = self.state;
        if (st.tooltip_phase != .waiting_for_show) return;
        const builder = st.tooltip_builder orelse return;
        self.app.pending_updates += 1;
        st.tooltip_view = builder.build(builder.ctx, window, self.app);
        self.app.pending_updates -= 1;
        st.tooltip_mouse = window.mouse_position();
        st.tooltip_phase = .visible;
        window.refresh();
        self.app.flush_effects();
    }

    fn hide(self: TooltipTimer) void {
        const window = self.live() orelse return;
        if (self.state.tooltip_phase != .waiting_for_hide) return;
        clear_tooltip(self.state, window, self.app);
        self.app.flush_effects();
    }
};

fn schedule_tooltip_timer(st: *InteractiveElementState, comptime f: fn (TooltipTimer) void, delay_ns: u64, window: *Window, cx: *App) void {
    const timer: TooltipTimer = .{ .app = cx, .window_id = window.window_handle_id(), .state = st, .generation = st.tooltip_generation };
    cx.background_executor().after(cx.foreground_executor(), delay_ns, f, timer);
}

/// How far a scroll moves each axis (GPUI `paint_scroll_listener`). An axis that scrolls takes its own
/// delta, or the other delta when only it scrolls and the scroll is not restricted to one axis. Unless
/// concurrent scrolling is allowed, only the dominant axis moves.
fn scroll_step(delta: Point(Pixels), ox: style_mod.Overflow, oy: style_mod.Overflow, restrict: bool, concurrent: bool) Point(Pixels) {
    var dx: Pixels = if (ox == .scroll and delta.x != 0) delta.x else if (ox == .scroll and !restrict and oy != .scroll) delta.y else 0;
    var dy: Pixels = if (oy == .scroll and delta.y != 0) delta.y else if (oy == .scroll and !restrict and ox != .scroll) delta.x else 0;
    if (!concurrent and dx != 0 and dy != 0) {
        if (@abs(dx) > @abs(dy)) dy = 0 else dx = 0;
    }
    return .{ .x = dx, .y = dy };
}

fn clamp_scroll(offset: Point(Pixels), max: Size(Pixels)) Point(Pixels) {
    return .{ .x = std.math.clamp(offset.x, -max.width, 0), .y = std.math.clamp(offset.y, -max.height, 0) };
}

/// How far the children can scroll inside `bounds`, with the box's padding (GPUI
/// `clamp_scroll_position`).
fn scroll_max(bounds: Bounds(Pixels), s: *const Style, child_layout_ids: []const LayoutId, window: *Window) Size(Pixels) {
    if (child_layout_ids.len == 0) return .{ .width = 0, .height = 0 };
    const inf = std.math.inf(f32);
    var min_x = inf;
    var min_y = inf;
    var max_x = -inf;
    var max_y = -inf;
    for (child_layout_ids) |lid| {
        const child = window.layout_bounds(lid);
        min_x = @min(min_x, child.left());
        min_y = @min(min_y, child.top());
        max_x = @max(max_x, child.right());
        max_y = @max(max_y, child.bottom());
    }
    const rem = window.rem_size();
    const basis_x: geometry.AbsoluteLength = .{ .pixels = bounds.size.width };
    const basis_y: geometry.AbsoluteLength = .{ .pixels = bounds.size.height };
    const width = (max_x - min_x) + s.padding.left.to_pixels(basis_x, rem) + s.padding.right.to_pixels(basis_x, rem);
    const height = (max_y - min_y) + s.padding.top.to_pixels(basis_y, rem) + s.padding.bottom.to_pixels(basis_y, rem);
    // Layout results differ after about five decimals, which must not make a box scrollable.
    return .{
        .width = @max(0, @round((width - bounds.size.width) * 100) / 100),
        .height = @max(0, @round((height - bounds.size.height) * 100) / 100),
    };
}

pub const InteractiveElementState = struct {
    focus_handle: ?FocusHandle = null,
    pending_mouse_down: ?MouseDownEvent = null,
    clicked: bool = false,
    hovered: bool = false,
    group_hovered: bool = false,
    active: bool = false,
    scroll_offset: Point(Pixels) = .{ .x = 0, .y = 0 },
    /// How far the content could scroll in the last frame.
    scroll_max: ?Size(Pixels) = null,
    hover_listener_state: bool = false,
    /// Set in capture, fired in bubble, so stopped propagation cannot leave it stuck.
    captured_mouse_down: ?MouseDownEvent = null,
    tooltip_phase: TooltipPhase = .none,
    tooltip_generation: u64 = 0,
    tooltip_view: ?view_mod.AnyView = null,
    tooltip_mouse: Point(Pixels) = .{ .x = 0, .y = 0 },
    tooltip_builder: ?TooltipBuilder = null,
    tooltip_hoverable: bool = false,
    tooltip_source_bounds: Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
};

/// All interactive and stateful behavior of a styled element (GPUI `Interactivity`).
pub const Interactivity = struct {
    element_id: ?ElementId = null,
    key_context: ?key_dispatch.KeyContext = null,
    focusable: bool = false,
    tracked_focus_handle: ?FocusHandle = null,
    tracked_scroll_handle: ?ScrollHandle = null,
    group: ?[]const u8 = null,
    base_style: StyleRefinement = .{},
    focus_style: ?*StyleRefinement = null,
    in_focus_style: ?*StyleRefinement = null,
    focus_visible_style: ?*StyleRefinement = null,
    hover_style: ?*StyleRefinement = null,
    group_hover_style: ?GroupStyle = null,
    active_style: ?*StyleRefinement = null,
    group_active_style: ?GroupStyle = null,
    mouse_down_listeners: List(MouseDownL) = .empty,
    mouse_up_listeners: List(MouseUpL) = .empty,
    mouse_down_out_listeners: List(DownOutL) = .empty,
    mouse_up_out_listeners: List(UpOutL) = .empty,
    aux_click_listeners: List(Listener(ClickEvent)) = .empty,
    pinch_listeners: List(Listener(PinchEvent)) = .empty,
    capture_pinch_listeners: List(Listener(PinchEvent)) = .empty,
    mouse_pressure_listeners: List(Listener(MousePressureEvent)) = .empty,
    capture_mouse_pressure_listeners: List(Listener(MousePressureEvent)) = .empty,
    drop_listeners: List(DropL) = .empty,
    can_drop_predicate: ?*const fn (value: app_mod.AnyDragValue, window: *Window, cx: *App) bool = null,
    drag_listener: ?DragListener = null,
    drag_over_styles: List(DragOverStyle) = .empty,
    group_drag_over_styles: List(GroupDragOverStyle) = .empty,
    tooltip_builder: ?TooltipBuilder = null,
    tooltip_hoverable: bool = false,
    tooltip_show_delay_ns: ?u64 = null,
    mouse_move_listeners: List(Listener(MouseMoveEvent)) = .empty,
    scroll_wheel_listeners: List(Listener(ScrollWheelEvent)) = .empty,
    key_down_listeners: List(struct { phase: DispatchPhase, l: Listener(KeyDownEvent) }) = .empty,
    key_up_listeners: List(struct { phase: DispatchPhase, l: Listener(KeyUpEvent) }) = .empty,
    modifiers_changed_listeners: List(Listener(ModifiersChangedEvent)) = .empty,
    action_listeners: List(ActionL) = .empty,
    click_listeners: List(Listener(ClickEvent)) = .empty,
    hover_listener: ?Listener(bool) = null,
    hover_listener_mode: HoverListenerMode = .input_modality_aware,
    mouse_exit_listeners: List(Listener(MouseExitEvent)) = .empty,
    file_drop_exit_listeners: List(Listener(FileDropEvent)) = .empty,
    drag_move_listeners: List(DragMoveL) = .empty,
    scroll_anchor: ?ScrollAnchor = null,
    occlude_mouse_: bool = false,
    block_mouse_except_scroll_: bool = false,
    tab_index: ?isize = null,
    tab_stop: ?bool = null,
    tab_group_: bool = false,

    /// Blocks mouse events from reaching the elements behind this one (GPUI `occlude_mouse`).
    pub fn occlude_mouse(self: *Interactivity) void {
        self.occlude_mouse_ = true;
    }

    fn needs_hitbox(self: *const Interactivity) bool {
        return self.element_id != null or self.focusable or self.tracked_focus_handle != null or self.hover_style != null or
            self.active_style != null or self.group != null or self.occlude_mouse_ or self.block_mouse_except_scroll_ or
            self.mouse_down_listeners.items.len > 0 or self.mouse_up_listeners.items.len > 0 or self.mouse_down_out_listeners.items.len > 0 or
            self.mouse_move_listeners.items.len > 0 or self.scroll_wheel_listeners.items.len > 0 or self.click_listeners.items.len > 0 or
            self.mouse_exit_listeners.items.len > 0 or self.file_drop_exit_listeners.items.len > 0 or self.drag_move_listeners.items.len > 0 or
            self.hover_listener != null or self.base_style.mouse_cursor != null or
            self.aux_click_listeners.items.len > 0 or self.pinch_listeners.items.len > 0 or self.capture_pinch_listeners.items.len > 0 or
            self.mouse_pressure_listeners.items.len > 0 or self.capture_mouse_pressure_listeners.items.len > 0 or
            self.drop_listeners.items.len > 0 or self.drag_listener != null or self.drag_over_styles.items.len > 0 or
            self.tooltip_builder != null or self.mouse_up_out_listeners.items.len > 0;
    }

    /// The style for this frame: base refined by focus/hover/active states (GPUI `compute_style`).
    pub fn compute_style(self: *const Interactivity, hitbox: ?*const Hitbox, state: ?*const InteractiveElementState, window: *Window, cx: *App) Style {
        var s: Style = .{};
        s.refine(&self.base_style);
        if (self.tracked_focus_handle) |h| {
            if (self.in_focus_style) |r| if (h.within_focused(window, cx)) s.refine(r);
            if (self.focus_style) |r| if (h.is_focused(window)) s.refine(r);
            if (self.focus_visible_style) |r| if (h.is_focused(window) and window.last_input_was_keyboard) s.refine(r);
        }
        if (hitbox) |hb| {
            if (self.hover_style) |r| if (hb.is_hovered(window)) s.refine(r);
            if (self.group_hover_style) |g| if (group_hitbox(g.group)) |gh| if (window_hovered(gh, window)) s.refine(g.style);
        }
        if (state) |st| {
            if (st.active) {
                if (self.active_style) |r| s.refine(r);
            }
        }
        if (self.group_active_style) |g| if (group_active(g.group)) s.refine(g.style);
        if (cx.active_drag) |drag| {
            const allowed = if (self.can_drop_predicate) |predicate| predicate(drag.value, window, cx) else true;
            if (allowed) {
                for (self.group_drag_over_styles.items) |g| {
                    if (g.type_id != drag.value.type_id) continue;
                    if (group_hitbox(g.group)) |gh| if (window_hovered(gh, window)) s.refine(g.style);
                }
                if (hitbox) |hb| {
                    for (self.drag_over_styles.items) |d| {
                        if (d.type_id == drag.value.type_id and hb.is_hovered(window)) s.refine(d.style);
                    }
                }
            }
            s.mouse_cursor = drag.cursor_style;
        }
        return s;
    }

    // -- per-frame group registry (GPUI GroupHitboxes) --------------------

    threadlocal var groups: std.StringHashMapUnmanaged(GroupInfo) = .empty;
    threadlocal var groups_frame: u64 = 0;
    const GroupInfo = struct { hitbox: window_mod.HitboxId, active: bool };

    fn group_hitbox(name: []const u8) ?window_mod.HitboxId {
        return if (groups.get(name)) |g| g.hitbox else null;
    }
    fn group_active(name: []const u8) bool {
        return if (groups.get(name)) |g| g.active else false;
    }
    fn window_hovered(id: window_mod.HitboxId, window: *Window) bool {
        const hb: Hitbox = .{ .id = id, .bounds = undefined, .content_mask = undefined };
        return hb.is_hovered(window);
    }
};

// ---------------------------------------------------------------------------
// StyledElement.

/// The per-frame state between layout, prepaint and paint.
pub const DivFrameState = struct {
    child_layout_ids: []LayoutId = &.{},
};

pub const DivPrepaintState = struct {
    hitbox: ?Hitbox = null,
    style: Style = .{},
    state: ?*InteractiveElementState = null,
    scroll_offset: Point(Pixels) = .{ .x = 0, .y = 0 },
};

/// The shared implementation of every styled element.
///
/// `Ext` adds element-specific state and hooks:
/// - `fn request_layout_ext(self: *StyledElement(Ext), gid: ?*const GlobalElementId, style: *Style, window, cx) ?LayoutId` (e.g. measured images; `gid` is null without an element id)
/// - `fn paint_ext(self: *StyledElement(Ext), bounds, style: *const Style, window, cx) void` (painted after background, before children)
pub fn StyledElement(comptime Ext: type) type {
    return struct {
        const Self = @This();
        const StyledM = styled_mod.Styled(*Self);
        const Parent = element_mod.ParentElement(*Self);
        const Fluent = element_mod.FluentBuilder(*Self);

        interactivity: Interactivity = .{},
        children_list: element_mod.Children = .empty,
        ext: Ext = .{},
        /// The image cache for the images under this element (set with `image_cache`).
        image_cache_provider: ?image_cache_mod.ImageCacheProvider = null,
        /// Set by `on_children_prepainted` (GPUI `prepaint_listener`).
        prepaint_listener: ?Listener(PrepaintedChildren) = null,
        /// Set by `with_dynamic_prepaint_order` (GPUI `prepaint_order_fn`).
        prepaint_order_fn: ?*const fn (window: *Window, cx: *App) []const usize = null,

        pub const RequestLayoutState = DivFrameState;
        pub const PrepaintState = DivPrepaintState;

        pub fn new() *Self {
            const d = arena().create(Self) catch oom();
            d.* = .{};
            return d;
        }

        pub fn style(self: *Self) *StyleRefinement {
            return &self.interactivity.base_style;
        }

        pub fn children_mut(self: *Self) *element_mod.Children {
            return &self.children_list;
        }

        /// Sets the image cache for the images under this element (GPUI `image_cache`). Those images
        /// load through it instead of the app's own cache; see `image_cache.zig`.
        pub fn image_cache(self: *Self, provider: anytype) *Self {
            self.image_cache_provider = image_cache_mod.ImageCacheProvider.from(provider);
            return self;
        }

        pub fn element_id(self: *Self) ?ElementId {
            return self.interactivity.element_id;
        }

        pub fn into_any_element(self: *Self) AnyElement {
            return AnyElement.new(self);
        }

        // -- ParentElement / FluentBuilder ------------------------------
        pub const child = Parent.child;
        pub const children = Parent.children;
        pub const extend = Parent.extend;
        pub const map = Fluent.map;
        pub const when = Fluent.when;
        pub const when_else = Fluent.when_else;
        pub const when_some = Fluent.when_some;
        pub const when_none = Fluent.when_none;

        // -- InteractiveElement ------------------------------------------

        /// Assigns an element id, making the element stateful (GPUI `.id()`).
        pub fn id(self: *Self, eid: anytype) *Self {
            self.interactivity.element_id = ElementId.from(eid);
            return self;
        }

        /// Names a group for `group_hover` / `group_active` styles.
        pub fn group(self: *Self, name: []const u8) *Self {
            self.interactivity.group = name;
            return self;
        }

        /// Sets the key context used to match key bindings.
        pub fn key_context(self: *Self, context: anytype) *Self {
            const T = @TypeOf(context);
            self.interactivity.key_context = if (T == key_dispatch.KeyContext)
                context
            else
                key_dispatch.KeyContext.parse(context) catch @panic("invalid key context");
            return self;
        }

        /// Tracks focus with `handle` (GPUI `track_focus`).
        pub fn track_focus(self: *Self, handle: *const FocusHandle) *Self {
            self.interactivity.focusable = true;
            self.interactivity.tracked_focus_handle = handle.*;
            return self;
        }

        /// Makes this element focusable with an implicit handle.
        pub fn focusable(self: *Self) *Self {
            self.interactivity.focusable = true;
            return self;
        }

        /// Sets where this element comes in tab order, which makes it focusable and a tab stop.
        pub fn tab_index(self: *Self, index: isize) *Self {
            self.interactivity.focusable = true;
            self.interactivity.tab_index = index;
            self.interactivity.tab_stop = true;
            return self;
        }

        /// Gives this element one place in the tab order, inside which its children's tab
        /// indices start over.
        pub fn tab_group(self: *Self) *Self {
            self.interactivity.tab_group_ = true;
            if (self.interactivity.tab_index == null) self.interactivity.tab_index = 0;
            return self;
        }

        pub fn tab_stop(self: *Self, v: bool) *Self {
            self.interactivity.tab_stop = v;
            return self;
        }

        /// Style applied while hovered: `.hover(style().bg(red()))`.
        pub fn hover(self: *Self, s: anytype) *Self {
            self.interactivity.hover_style = to_style_refinement(s);
            return self;
        }

        pub fn group_hover(self: *Self, group_name: []const u8, s: anytype) *Self {
            self.interactivity.group_hover_style = .{ .group = group_name, .style = to_style_refinement(s) };
            return self;
        }

        /// Style applied while pressed.
        pub fn active(self: *Self, s: anytype) *Self {
            self.interactivity.active_style = to_style_refinement(s);
            return self;
        }

        pub fn group_active(self: *Self, group_name: []const u8, s: anytype) *Self {
            self.interactivity.group_active_style = .{ .group = group_name, .style = to_style_refinement(s) };
            return self;
        }

        /// Style applied while this element is focused.
        pub fn focus(self: *Self, s: anytype) *Self {
            self.interactivity.focus_style = to_style_refinement(s);
            return self;
        }

        /// Style applied while this element or a descendant is focused.
        pub fn in_focus(self: *Self, s: anytype) *Self {
            self.interactivity.in_focus_style = to_style_refinement(s);
            return self;
        }

        pub fn focus_visible(self: *Self, s: anytype) *Self {
            self.interactivity.focus_visible_style = to_style_refinement(s);
            return self;
        }

        pub fn on_mouse_down(self: *Self, button: MouseButton, listener: anytype) *Self {
            self.interactivity.mouse_down_listeners.append(arena(), .{ .button = button, .phase = .bubble, .listener = app_mod.to_listener(MouseDownEvent, listener) }) catch oom();
            return self;
        }

        pub fn capture_any_mouse_down(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_down_listeners.append(arena(), .{ .button = null, .phase = .capture, .listener = app_mod.to_listener(MouseDownEvent, listener) }) catch oom();
            return self;
        }

        pub fn on_any_mouse_down(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_down_listeners.append(arena(), .{ .button = null, .phase = .bubble, .listener = app_mod.to_listener(MouseDownEvent, listener) }) catch oom();
            return self;
        }

        pub fn on_mouse_up(self: *Self, button: MouseButton, listener: anytype) *Self {
            self.interactivity.mouse_up_listeners.append(arena(), .{ .button = button, .phase = .bubble, .listener = app_mod.to_listener(MouseUpEvent, listener) }) catch oom();
            return self;
        }

        pub fn capture_any_mouse_up(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_up_listeners.append(arena(), .{ .button = null, .phase = .capture, .listener = app_mod.to_listener(MouseUpEvent, listener) }) catch oom();
            return self;
        }

        pub fn on_any_mouse_up(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_up_listeners.append(arena(), .{ .button = null, .phase = .bubble, .listener = app_mod.to_listener(MouseUpEvent, listener) }) catch oom();
            return self;
        }

        /// Fires when the mouse goes down outside this element.
        pub fn on_mouse_down_out(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_down_out_listeners.append(arena(), .{ .listener = app_mod.to_listener(MouseDownEvent, listener) }) catch oom();
            return self;
        }

        /// Fires when `button` is released outside this element, as for ending a drag.
        pub fn on_mouse_up_out(self: *Self, button: MouseButton, listener: anytype) *Self {
            self.interactivity.mouse_up_out_listeners.append(arena(), .{ .button = button, .listener = app_mod.to_listener(MouseUpEvent, listener) }) catch oom();
            return self;
        }

        pub fn on_mouse_move(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_move_listeners.append(arena(), app_mod.to_listener(MouseMoveEvent, listener)) catch oom();
            return self;
        }

        /// Scroll events over this element, in the bubble phase (GPUI `on_scroll`).
        pub fn on_scroll(self: *Self, listener: anytype) *Self {
            self.interactivity.scroll_wheel_listeners.append(arena(), app_mod.to_listener(ScrollWheelEvent, listener)) catch oom();
            return self;
        }

        /// The former name of `on_scroll` (GPUI `on_scroll_wheel`, deprecated).
        pub fn on_scroll_wheel(self: *Self, listener: anytype) *Self {
            return self.on_scroll(listener);
        }

        /// Called when the mouse leaves the window while over this element (GPUI `on_mouse_exit`).
        pub fn on_mouse_exit(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_exit_listeners.append(arena(), app_mod.to_listener(MouseExitEvent, listener)) catch oom();
            return self;
        }

        /// Called with `FileDropEvent.exited` when a file drag leaves the window while over this
        /// element (GPUI `on_file_drop_exit`).
        pub fn on_file_drop_exit(self: *Self, listener: anytype) *Self {
            self.interactivity.file_drop_exit_listeners.append(arena(), app_mod.to_listener(FileDropEvent, listener)) catch oom();
            return self;
        }

        /// Called for every move during a drag of a `T` that started with this element under the
        /// pointer, whether or not the pointer is over this element (GPUI `on_drag_move::<T>`). The
        /// listener takes `*const DragMoveEvent(T)`. Useful for resizing and other drags that drop nothing.
        pub fn on_drag_move(self: *Self, comptime T: type, listener: anytype) *Self {
            const E = DragMoveEvent(T);
            const held = arena().create(Listener(E)) catch oom();
            held.* = app_mod.to_listener(E, listener);
            self.interactivity.drag_move_listeners.append(arena(), .{ .type_id = app_mod.type_id(T), .ctx = held, .call = struct {
                fn call(raw: *anyopaque, event: *const MouseMoveEvent, bounds: Bounds(Pixels), item: *anyopaque, window: *Window, cx: *App) void {
                    const l: *const Listener(E) = @ptrCast(@alignCast(raw));
                    const ev: E = .{ .event = event.*, .bounds = bounds, .item = @ptrCast(@alignCast(item)) };
                    l.call(&ev, window, cx);
                }
            }.call }) catch oom();
            return self;
        }

        /// Sets the hit testing `on_hover` uses (GPUI `hover_listener_mode`).
        pub fn hover_listener_mode(self: *Self, mode: HoverListenerMode) *Self {
            self.interactivity.hover_listener_mode = mode;
            return self;
        }

        /// Keeps this element scrolled into view by its scroll container (GPUI `anchor_scroll`).
        pub fn anchor_scroll(self: *Self, scroll_anchor: ?ScrollAnchor) *Self {
            self.interactivity.scroll_anchor = scroll_anchor;
            return self;
        }

        /// Scrolls along the axis the gesture starts on (GPUI `restrict_scroll_to_axis`).
        pub fn restrict_scroll_to_axis(self: *Self) *Self {
            self.interactivity.base_style.restrict_scroll_to_axis = true;
            return self;
        }

        /// Lets a scroll move both axes at once; by default only the dominant axis moves (GPUI `allow_concurrent_scroll`).
        pub fn allow_concurrent_scroll(self: *Self) *Self {
            self.interactivity.base_style.allow_concurrent_scroll = true;
            return self;
        }

        /// Runs `listener` with the bounds of the children once they are prepainted (GPUI `on_children_prepainted`).
        pub fn on_children_prepainted(self: *Self, listener: anytype) *Self {
            self.prepaint_listener = app_mod.to_listener(PrepaintedChildren, listener);
            return self;
        }

        /// Prepaints the children in the order `order_fn` returns their indices (GPUI `with_dynamic_prepaint_order`).
        /// Each index must appear once. The order is asked for in every prepaint.
        pub fn with_dynamic_prepaint_order(self: *Self, comptime order_fn: fn (*Window, *App) []const usize) *Self {
            self.prepaint_order_fn = &order_fn;
            return self;
        }

        pub fn on_key_down(self: *Self, listener: anytype) *Self {
            self.interactivity.key_down_listeners.append(arena(), .{ .phase = .bubble, .l = app_mod.to_listener(KeyDownEvent, listener) }) catch oom();
            return self;
        }

        pub fn capture_key_down(self: *Self, listener: anytype) *Self {
            self.interactivity.key_down_listeners.append(arena(), .{ .phase = .capture, .l = app_mod.to_listener(KeyDownEvent, listener) }) catch oom();
            return self;
        }

        pub fn on_key_up(self: *Self, listener: anytype) *Self {
            self.interactivity.key_up_listeners.append(arena(), .{ .phase = .bubble, .l = app_mod.to_listener(KeyUpEvent, listener) }) catch oom();
            return self;
        }

        pub fn capture_key_up(self: *Self, listener: anytype) *Self {
            self.interactivity.key_up_listeners.append(arena(), .{ .phase = .capture, .l = app_mod.to_listener(KeyUpEvent, listener) }) catch oom();
            return self;
        }

        pub fn on_modifiers_changed(self: *Self, listener: anytype) *Self {
            self.interactivity.modifiers_changed_listeners.append(arena(), app_mod.to_listener(ModifiersChangedEvent, listener)) catch oom();
            return self;
        }

        /// Handles action `A` when this element is on the focus path:
        /// `listener` is `Listener(A)` (from `cx.listener(Self.handler)` where
        /// handler is `fn(*Self, *const A, *Window, *Context(Self)) void`) or
        /// `fn(*const A, *Window, *App) void`.
        pub fn on_action(self: *Self, comptime A: type, listener: anytype) *Self {
            return self.add_action(A, .bubble, listener);
        }

        pub fn capture_action(self: *Self, comptime A: type, listener: anytype) *Self {
            return self.add_action(A, .capture, listener);
        }

        fn add_action(self: *Self, comptime A: type, phase: DispatchPhase, listener: anytype) *Self {
            const l = arena().create(Listener(A)) catch oom();
            l.* = app_mod.to_listener(A, listener);
            const S = struct {
                fn call(ctx: *anyopaque, action: *const anyopaque, ph: DispatchPhase, win: *Window, c: *App) void {
                    const lp: *const ActionCtx = @ptrCast(@alignCast(ctx));
                    if (ph != lp.phase) return;
                    lp.l.call(@ptrCast(@alignCast(action)), win, c);
                }
                const ActionCtx = struct { l: *Listener(A), phase: DispatchPhase };
            };
            const ctx = arena().create(S.ActionCtx) catch oom();
            ctx.* = .{ .l = l, .phase = phase };
            self.interactivity.action_listeners.append(arena(), .{ .action_type = app_mod.type_id(A), .phase = phase, .ctx = ctx, .func = S.call }) catch oom();
            return self;
        }

        /// Blocks mouse events from reaching elements behind this one.
        pub fn occlude(self: *Self) *Self {
            self.interactivity.occlude_mouse();
            return self;
        }

        pub fn block_mouse_except_scroll(self: *Self) *Self {
            self.interactivity.block_mouse_except_scroll_ = true;
            return self;
        }

        // -- StatefulInteractiveElement ------------------------------------

        /// Click handler (requires `.id(...)`).
        /// Fires for clicks with any button but the left one.
        pub fn on_aux_click(self: *Self, listener: anytype) *Self {
            self.interactivity.aux_click_listeners.append(arena(), app_mod.to_listener(ClickEvent, listener)) catch oom();
            return self;
        }

        pub fn on_pinch(self: *Self, listener: anytype) *Self {
            self.interactivity.pinch_listeners.append(arena(), app_mod.to_listener(PinchEvent, listener)) catch oom();
            return self;
        }

        pub fn capture_pinch(self: *Self, listener: anytype) *Self {
            self.interactivity.capture_pinch_listeners.append(arena(), app_mod.to_listener(PinchEvent, listener)) catch oom();
            return self;
        }

        /// Pressure changes over this element (GPUI `on_mouse_pressure`). Only macOS trackpads
        /// report pressure; no other platform emits these events.
        pub fn on_mouse_pressure(self: *Self, listener: anytype) *Self {
            self.interactivity.mouse_pressure_listeners.append(arena(), app_mod.to_listener(MousePressureEvent, listener)) catch oom();
            return self;
        }

        /// The capture-phase form of `on_mouse_pressure` (GPUI `capture_mouse_pressure`).
        pub fn capture_mouse_pressure(self: *Self, listener: anytype) *Self {
            self.interactivity.capture_mouse_pressure_listeners.append(arena(), app_mod.to_listener(MousePressureEvent, listener)) catch oom();
            return self;
        }

        /// Makes this element draggable once the pointer moves past a small threshold.
        /// `constructor(value, cursor_offset, window, cx)` returns the entity to show under the
        /// pointer. `value` is copied for the length of the drag. The element needs an id.
        pub fn on_drag(self: *Self, value: anytype, comptime constructor: anytype) *Self {
            const T = @TypeOf(value);
            const held = arena().create(T) catch oom();
            held.* = value;
            self.interactivity.drag_listener = .{ .value = held, .start = struct {
                fn start(raw: *anyopaque, offset: Point(Pixels), window: *Window, cx: *App) app_mod.AnyDrag {
                    const source: *const T = @ptrCast(@alignCast(raw));
                    const copy = cx.allocator.create(T) catch oom();
                    copy.* = source.*;
                    return .{
                        .value = .{ .ptr = copy, .type_id = app_mod.type_id(T) },
                        .view = view_mod.AnyView.from(constructor(@as(*const T, copy), offset, window, cx)),
                        .cursor_offset = offset,
                        .free_value = struct {
                            fn free(a: std.mem.Allocator, held_value: *anyopaque) void {
                                a.destroy(@as(*T, @ptrCast(@alignCast(held_value))));
                            }
                        }.free,
                    };
                }
            }.start };
            return self;
        }

        /// Receives a dragged `T` released over this element. File drags arrive as `ExternalPaths`.
        pub fn on_drop(self: *Self, comptime T: type, listener: anytype) *Self {
            const held = arena().create(Listener(T)) catch oom();
            held.* = app_mod.to_listener(T, listener);
            self.interactivity.drop_listeners.append(arena(), .{ .type_id = app_mod.type_id(T), .ctx = held, .call = struct {
                fn call(raw: *anyopaque, value: *anyopaque, window: *Window, cx: *App) void {
                    const l: *const Listener(T) = @ptrCast(@alignCast(raw));
                    l.call(@ptrCast(@alignCast(value)), window, cx);
                }
            }.call }) catch oom();
            return self;
        }

        /// Decides whether the drag may be dropped here, and whether drag_over styles apply.
        pub fn can_drop(self: *Self, predicate: *const fn (app_mod.AnyDragValue, *Window, *App) bool) *Self {
            self.interactivity.can_drop_predicate = predicate;
            return self;
        }

        /// Style applied while a dragged `T` is over this element.
        pub fn drag_over(self: *Self, comptime T: type, s: anytype) *Self {
            self.interactivity.drag_over_styles.append(arena(), .{ .type_id = app_mod.type_id(T), .style = to_style_refinement(s) }) catch oom();
            return self;
        }

        /// Style applied while a dragged `T` is over the named group.
        pub fn group_drag_over(self: *Self, comptime T: type, group_name: []const u8, s: anytype) *Self {
            self.interactivity.group_drag_over_styles.append(arena(), .{ .type_id = app_mod.type_id(T), .group = group_name, .style = to_style_refinement(s) }) catch oom();
            return self;
        }

        /// Shows a view after the pointer rests here. Takes a `fn(*Window, *App) AnyView` or
        /// a `TooltipBuilder`. The element needs an id.
        pub fn tooltip(self: *Self, build_tooltip: anytype) *Self {
            self.interactivity.tooltip_builder = to_tooltip_builder(build_tooltip);
            self.interactivity.tooltip_hoverable = false;
            return self;
        }

        /// Like `tooltip`, but the pointer may move onto the tooltip without it closing.
        pub fn hoverable_tooltip(self: *Self, build_tooltip: anytype) *Self {
            self.interactivity.tooltip_builder = to_tooltip_builder(build_tooltip);
            self.interactivity.tooltip_hoverable = true;
            return self;
        }

        pub fn tooltip_show_delay(self: *Self, delay_ms: u64) *Self {
            self.interactivity.tooltip_show_delay_ns = delay_ms * std.time.ns_per_ms;
            return self;
        }

        pub fn on_click(self: *Self, listener: anytype) *Self {
            self.interactivity.click_listeners.append(arena(), app_mod.to_listener(ClickEvent, listener)) catch oom();
            return self;
        }

        /// Called with `true`/`false` when hover starts/ends.
        pub fn on_hover(self: *Self, listener: anytype) *Self {
            self.interactivity.hover_listener = app_mod.to_listener(bool, listener);
            return self;
        }

        /// Runs `listener` for the action when it is dispatched to this element, in the bubble phase
        /// (GPUI `on_boxed_action`). `action` is type-erased, so it must outlive the frame.
        pub fn on_boxed_action(self: *Self, action: action_mod.AnyAction, comptime listener: fn (*const action_mod.AnyAction, *Window, *App) void) *Self {
            const Held = struct {
                action: action_mod.AnyAction,
                fn call(raw: *anyopaque, _: *const anyopaque, phase: DispatchPhase, window: *Window, cx: *App) void {
                    if (phase != .bubble) return;
                    const held: *const @This() = @ptrCast(@alignCast(raw));
                    listener(&held.action, window, cx);
                }
            };
            const held = arena().create(Held) catch oom();
            held.* = .{ .action = action };
            self.interactivity.action_listeners.append(arena(), .{ .action_type = action.type_id, .phase = .bubble, .ctx = held, .func = Held.call }) catch oom();
            return self;
        }

        /// Tracks the scroll position in `handle`.
        pub fn track_scroll(self: *Self, handle: *const ScrollHandle) *Self {
            self.interactivity.tracked_scroll_handle = handle.*;
            return self;
        }

        // -- Element protocol ---------------------------------------------

        pub fn request_layout(self: *Self, gid: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, DivFrameState } {
            var s: Style = .{};
            s.refine(&self.interactivity.base_style);
            const has_text = s.text_style() != null;
            if (has_text) window.push_text_style(s.text);
            defer if (has_text) window.pop_text_style();

            // Set before the element's own hook and its children, so `img` sees its own cache on top.
            const pushed_cache = if (self.image_cache_provider) |provider| blk: {
                window.push_image_cache(provider.provide(window, cx));
                break :blk true;
            } else false;
            defer if (pushed_cache) window.pop_image_cache();

            if (@hasDecl(Ext, "request_layout_ext")) {
                if (Ext.request_layout_ext(self, gid, &s, window, cx)) |lid| return .{ lid, .{} };
            }
            const ids = arena().alloc(LayoutId, self.children_list.items.len) catch oom();
            for (self.children_list.items, 0..) |c, i| ids[i] = c.request_layout(window, cx);
            return .{ window.request_layout(&s, ids, cx), .{ .child_layout_ids = ids } };
        }

        pub fn prepaint(self: *Self, gid: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *DivFrameState, window: *Window, cx: *App) DivPrepaintState {
            const it = &self.interactivity;
            var pp: DivPrepaintState = .{};
            if (gid) |g| pp.state = window.element_state(InteractiveElementState, g.*, .{});
            // Where an anchored element is, so its container can scroll to it (GPUI `scroll_anchor`).
            if (it.scroll_anchor) |anchor| {
                const offset = window.element_offset();
                anchor.last_origin.* = .{ .x = bounds.origin.x - offset.x, .y = bounds.origin.y - offset.y };
            }

            // Focus handle: tracked, or an implicit one stored in element state.
            if (it.focusable and it.tracked_focus_handle == null) {
                if (pp.state) |st| {
                    if (st.focus_handle == null) st.focus_handle = cx.focus_handle();
                    it.tracked_focus_handle = st.focus_handle;
                }
            }
            if (it.tracked_focus_handle) |*fh| {
                var hh = fh.*;
                if (it.tab_index) |ti| hh.tab_index_ = ti;
                if (it.tab_stop) |ts| hh.tab_stop_ = ts;
                window.set_focus_handle(&hh, cx);
            }
            if (it.tab_group_) window.next_frame.dispatch_tree.set_tab_group(it.tab_index.?);
            if (it.key_context) |kc| window.set_key_context(kc);

            // A tooltip that is showing asks to be drawn at the end of the frame.
            if (pp.state) |st| {
                st.tooltip_builder = it.tooltip_builder;
                st.tooltip_hoverable = it.tooltip_hoverable;
                st.tooltip_source_bounds = bounds;
                if (it.tooltip_builder == null) {
                    clear_tooltip(st, window, cx);
                } else if (st.tooltip_view) |view| {
                    window.set_tooltip(.{ .view = view, .mouse_position = st.tooltip_mouse, .ctx = st, .check_visible = tooltip_check_visible });
                }
            }

            // Key & action listeners attach to this element's dispatch node.
            for (it.key_down_listeners.items) |*kl| registerKey(KeyDownEvent, window, kl.phase, &kl.l);
            for (it.key_up_listeners.items) |*kl| registerKey(KeyUpEvent, window, kl.phase, &kl.l);
            for (it.action_listeners.items) |al| window.on_action(al.action_type, al.ctx, al.func);

            if (it.needs_hitbox()) {
                const behavior: window_mod.HitboxBehavior = if (it.occlude_mouse_) .block_mouse else if (it.block_mouse_except_scroll_) .block_mouse_except_scroll else .normal;
                pp.hitbox = window.insert_hitbox(bounds, behavior);
                if (it.group) |g| {
                    if (Interactivity.groups_frame != window.frame_count) {
                        Interactivity.groups.clearRetainingCapacity();
                        Interactivity.groups_frame = window.frame_count;
                    }
                    const is_active = if (pp.state) |st| st.active else false;
                    Interactivity.groups.put(std.heap.page_allocator, g, .{ .hitbox = pp.hitbox.?.id, .active = is_active }) catch oom();
                }
            }

            pp.style = it.compute_style(if (pp.hitbox) |*hbx| hbx else null, pp.state, window, cx);
            const s = &pp.style;

            const has_text = s.text_style() != null;
            if (has_text) window.push_text_style(s.text);
            defer if (has_text) window.pop_text_style();

            // Scroll offset, clamped before the children use it (GPUI `clamp_scroll_position`):
            // a wheel event past the end must not paint a frame out there.
            var scroll: Point(Pixels) = .{ .x = 0, .y = 0 };
            // The children are measured, and the requests made since the last frame applied, before the
            // offset is clamped (GPUI `Div::prepaint` and `scroll_to_active_item`).
            if (it.tracked_scroll_handle) |sh| {
                sh.state.child_bounds.clearRetainingCapacity();
                const allocator = sh.state.allocator orelse std.heap.page_allocator;
                for (rl.child_layout_ids) |lid| sh.state.child_bounds.append(allocator, window.layout_bounds(lid)) catch oom();
                sh.scroll_to_active_item();
            }
            if (s.overflow.x == .scroll or s.overflow.y == .scroll) {
                const max = scroll_max(bounds, s, rl.child_layout_ids, window);
                if (it.tracked_scroll_handle) |sh| {
                    sh.state.max_offset = max;
                    sh.state.bounds = bounds;
                    sh.state.overflow = s.overflow;
                    const to_bottom = sh.state.scroll_to_bottom;
                    sh.state.scroll_to_bottom = false;
                    scroll = clamp_scroll(sh.offset(), max);
                    if (to_bottom) scroll.y = -max.height;
                    sh.set_offset(scroll);
                }
                if (pp.state) |st| {
                    st.scroll_max = max;
                    if (it.tracked_scroll_handle == null) scroll = clamp_scroll(st.scroll_offset, max);
                    st.scroll_offset = scroll;
                }
            }
            pp.scroll_offset = scroll;

            const mask = s.overflow_mask(bounds, window.rem_size());
            if (mask) |mk| window.push_content_mask(.{ .bounds = mk });
            defer if (mask != null) window.pop_content_mask();

            window.push_element_offset(scroll);
            if (self.prepaint_order_fn) |order_fn| {
                for (order_fn(window, cx)) |ix| {
                    if (ix < self.children_list.items.len) self.children_list.items[ix].prepaint(window, cx);
                }
            } else {
                for (self.children_list.items) |c| c.prepaint(window, cx);
            }
            window.pop_element_offset();
            if (self.prepaint_listener) |listener| {
                const child_bounds = arena().alloc(Bounds(Pixels), rl.child_layout_ids.len) catch oom();
                for (rl.child_layout_ids, 0..) |lid, i| child_bounds[i] = window.layout_bounds(lid);
                const prepainted: PrepaintedChildren = .{ .bounds = child_bounds };
                listener.call(&prepainted, window, cx);
            }
            if (@hasDecl(Ext, "prepaint_ext")) Ext.prepaint_ext(self, bounds, window, cx);

            return pp;
        }

        pub fn paint(self: *Self, gid: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *DivFrameState, pp: *DivPrepaintState, window: *Window, cx: *App) void {
            _ = gid;
            _ = rl;
            const s = &pp.style;
            if (s.visibility == .hidden) return;
            const it = &self.interactivity;

            if (pp.hitbox) |*hb| {
                self.register_mouse_listeners(hb, pp.state, window);
                // During a drag its cursor applies everywhere, not just over this element.
                if (cx.active_drag) |drag| {
                    if (drag.cursor_style) |c| window.set_window_cursor_style(c);
                } else if (s.mouse_cursor) |c| {
                    window.set_cursor_style(c, hb);
                }
            }

            const has_text = s.text_style() != null;
            if (has_text) window.push_text_style(s.text);
            defer if (has_text) window.pop_text_style();
            window.push_element_opacity(s.opacity);
            defer window.pop_element_opacity();

            const rem = window.rem_size();
            const radii = s.corner_radii.to_pixels(rem).clamp_radii_for_quad_size(bounds.size);

            // Shadows and background.
            window.paint_shadows(bounds, radii, s.box_shadow);
            if (s.background) |bgf| {
                const bgc = bgf.get_color() orelse color_mod.to_background(color_mod.transparent_black());
                if (!bgc.is_transparent()) {
                    window.paint_quad(.{ .bounds = bounds, .corner_radii = radii, .background = bgc });
                }
            }

            if (@hasDecl(Ext, "paint_ext")) Ext.paint_ext(self, bounds, s, window, cx);

            // Children inside the overflow mask, offset by scroll.
            const mask = s.overflow_mask(bounds, rem);
            if (mask) |mk| window.push_content_mask(.{ .bounds = mk });
            for (self.children_list.items) |c| c.paint(window, cx);
            if (mask != null) window.pop_content_mask();

            // Border on top of children (GPUI paints borders after content).
            if (s.is_border_visible()) {
                if (s.border_color) |bc| {
                    const bw = s.border_widths.to_pixels(.{rem});
                    window.paint_quad(.{
                        .bounds = bounds,
                        .corner_radii = radii,
                        .background = color_mod.to_background(color_mod.transparent_black()),
                        .border_widths = bw,
                        .border_color = bc,
                        .border_style = s.border_style,
                    });
                }
            }

            if (s.debug or s.debug_below) {
                window.paint_quad(window_mod.outline(bounds, color_mod.red(), .solid));
            }
            _ = it;
        }

        fn registerKey(comptime E: type, window: *Window, phase: DispatchPhase, l: *const Listener(E)) void {
            const Ctx = struct { phase: DispatchPhase, l: *const Listener(E) };
            const ctx = arena().create(Ctx) catch oom();
            ctx.* = .{ .phase = phase, .l = l };
            window.on_key_event(E, ctx, struct {
                fn f(c: *anyopaque, e: *const E, ph: DispatchPhase, win: *Window, a: *App) void {
                    const cc: *const Ctx = @ptrCast(@alignCast(c));
                    if (ph == cc.phase) cc.l.call(e, win, a);
                }
            }.f);
        }

        const MouseCtx = struct {
            self: *Self,
            hitbox: Hitbox,
            state: ?*InteractiveElementState,
        };

        fn register_mouse_listeners(self: *Self, hb: *const Hitbox, state: ?*InteractiveElementState, window: *Window) void {
            const it = &self.interactivity;
            const ctx = arena().create(MouseCtx) catch oom();
            ctx.* = .{ .self = self, .hitbox = hb.*, .state = state };

            const needs_down = it.mouse_down_listeners.items.len > 0 or it.click_listeners.items.len > 0 or it.active_style != null or
                it.tracked_focus_handle != null or it.group_active_style != null or it.mouse_down_out_listeners.items.len > 0 or
                it.aux_click_listeners.items.len > 0 or it.drag_listener != null or it.tooltip_builder != null;
            if (needs_down) window.on_mouse_event(MouseDownEvent, ctx, onMouseDown);
            if (it.pinch_listeners.items.len > 0 or it.capture_pinch_listeners.items.len > 0) window.on_mouse_event(PinchEvent, ctx, onPinch);
            if (it.mouse_pressure_listeners.items.len > 0 or it.capture_mouse_pressure_listeners.items.len > 0) window.on_mouse_event(MousePressureEvent, ctx, onMousePressure);
            if (it.drop_listeners.items.len > 0 or it.aux_click_listeners.items.len > 0 or it.drag_listener != null or it.tooltip_builder != null or it.mouse_up_out_listeners.items.len > 0 or it.mouse_up_listeners.items.len > 0 or it.click_listeners.items.len > 0 or it.active_style != null or it.group != null)
                window.on_mouse_event(MouseUpEvent, ctx, onMouseUp);
            if (it.drag_listener != null or it.tooltip_builder != null or it.drag_over_styles.items.len > 0 or it.mouse_move_listeners.items.len > 0 or it.hover_style != null or it.hover_listener != null or it.group_hover_style != null or it.group != null or it.drag_move_listeners.items.len > 0)
                window.on_mouse_event(MouseMoveEvent, ctx, onMouseMove);
            if (it.mouse_exit_listeners.items.len > 0 or it.hover_listener != null) window.on_mouse_event(MouseExitEvent, ctx, onMouseExit);
            if (it.file_drop_exit_listeners.items.len > 0) window.on_mouse_event(FileDropEvent, ctx, onFileDrop);
            if (it.tooltip_builder != null or it.scroll_wheel_listeners.items.len > 0 or it.base_style.overflow.x == .scroll or it.base_style.overflow.y == .scroll)
                window.on_mouse_event(ScrollWheelEvent, ctx, onScrollWheel);
        }

        fn onMouseDown(raw: *anyopaque, e: *const MouseDownEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            const hovered = c.hitbox.is_hovered(window);
            if (it.tooltip_builder != null) if (c.state) |st| dismiss_tooltip_on_input(st, window, cx);
            if (phase == .bubble and !hovered) {
                for (it.mouse_down_out_listeners.items) |l| l.listener.call(e, window, cx);
            }
            if (!hovered) return;
            for (it.mouse_down_listeners.items) |l| {
                if (l.phase != phase) continue;
                if (l.button) |b| if (!b.eql(e.button)) continue;
                l.listener.call(e, window, cx);
                if (!window.propagate_event) return;
            }
            if (phase != .bubble) return;
            if (it.tracked_focus_handle) |fh| {
                if (!window.default_prevented) {
                    window.focus(fh);
                    // A focusable parent must not take focus back as the event bubbles.
                    window.prevent_default();
                }
            }
            if (c.state) |st| {
                if ((it.drag_listener != null and e.button == .left) or it.aux_click_listeners.items.len > 0 and e.button != .left) st.pending_mouse_down = e.*;
                if (it.tooltip_builder != null) st.pending_mouse_down = e.*;
                if (it.click_listeners.items.len > 0 and e.button == .left) st.pending_mouse_down = e.*;
                if (it.active_style != null or it.group != null) {
                    st.active = true;
                    window.refresh();
                }
            }
        }

        fn onMouseUp(raw: *anyopaque, e: *const MouseUpEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            const hovered = c.hitbox.is_hovered(window);
            // Capture phase, as in GPUI: nothing outside may stop the element hearing it.
            if (phase == .capture and !hovered) {
                for (it.mouse_up_out_listeners.items) |l| {
                    if (l.button.eql(e.button)) l.listener.call(e, window, cx);
                }
            }
            if (hovered) {
                for (it.mouse_up_listeners.items) |l| {
                    if (l.phase != phase) continue;
                    if (l.button) |b| if (!b.eql(e.button)) continue;
                    l.listener.call(e, window, cx);
                    if (!window.propagate_event) return;
                }
            }
            if (phase == .capture) {
                // Done here so another handler stopping propagation cannot leave it set. Off
                // the element it just clears, which keeps an element that moved under the
                // pointer from starting a drag on its own.
                if (c.state) |st| {
                    if (st.pending_mouse_down) |down| {
                        st.pending_mouse_down = null;
                        if (hovered) st.captured_mouse_down = down;
                        window.refresh();
                    }
                }
                return;
            }
            if (hovered and it.drop_listeners.items.len > 0) {
                if (cx.active_drag) |drag| {
                    for (it.drop_listeners.items) |l| {
                        if (l.type_id != drag.value.type_id) continue;
                        const allowed = if (it.can_drop_predicate) |predicate| predicate(drag.value, window, cx) else true;
                        if (allowed) {
                            l.call(l.ctx, drag.value.ptr, window, cx);
                            window.refresh();
                            window.stop_propagation();
                        }
                        cx.clear_active_drag();
                        break;
                    }
                }
            }
            if (c.state) |st| {
                if (st.active) {
                    st.active = false;
                    window.refresh();
                }
                if (st.captured_mouse_down) |down| {
                    st.captured_mouse_down = null;
                    const click: ClickEvent = .{ .mouse = .{ .down = down, .up = e.* } };
                    if (down.button == .left) {
                        for (it.click_listeners.items) |l| l.call(&click, window, cx);
                    } else {
                        for (it.aux_click_listeners.items) |l| l.call(&click, window, cx);
                    }
                }
            }
        }

        fn onMouseMove(raw: *anyopaque, e: *const MouseMoveEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            const hovered = c.hitbox.is_hovered(window);
            // Drag-move listeners hear every move of a drag of their type, wherever the pointer is.
            if (phase == .capture) if (cx.active_drag) |drag| {
                for (it.drag_move_listeners.items) |l| {
                    if (l.type_id != drag.value.type_id) continue;
                    l.call(l.ctx, e, c.hitbox.bounds, drag.value.ptr, window, cx);
                }
            };
            if (it.tooltip_builder != null) if (c.state) |st| tooltip_on_mouse_move(st, hovered, phase, it.tooltip_show_delay_ns orelse DEFAULT_TOOLTIP_SHOW_DELAY_NS, window, cx);
            if (phase == .bubble and hovered) {
                for (it.mouse_move_listeners.items) |l| l.call(e, window, cx);
            }
            if (phase == .bubble and !cx.has_active_drag()) {
                if (it.drag_listener) |listener| if (c.state) |st| if (st.pending_mouse_down) |down| {
                    const dx = e.position.x - down.position.x;
                    const dy = e.position.y - down.position.y;
                    if (down.button == .left and @sqrt(dx * dx + dy * dy) > DROP_DRAG_THRESHOLD) {
                        st.active = false;
                        st.pending_mouse_down = null;
                        const offset: Point(Pixels) = .{ .x = e.position.x - c.hitbox.bounds.origin.x, .y = e.position.y - c.hitbox.bounds.origin.y };
                        var drag = listener.start(listener.value, offset, window, cx);
                        drag.cursor_style = it.base_style.mouse_cursor;
                        cx.set_active_drag(drag);
                        window.refresh();
                        window.stop_propagation();
                        return;
                    }
                };
            }
            if (phase != .capture) return;
            if (c.state) |st| {
                if (st.hovered != hovered) {
                    st.hovered = hovered;
                    if (it.hover_style != null or it.group != null) window.refresh();
                }
                if (it.hover_listener) |hl| {
                    // Not while a button is held or a drag runs, as in GPUI.
                    const listener_hovered = st.pending_mouse_down == null and !cx.has_active_drag() and
                        it.hover_listener_mode.is_hovered(&c.hitbox, window);
                    if (st.hover_listener_state != listener_hovered) {
                        st.hover_listener_state = listener_hovered;
                        hl.call(&listener_hovered, window, cx);
                    }
                }
            } else if (it.hover_style != null) {
                // Without persistent state, refresh whenever hover may have changed.
                window.refresh();
            }
            if (it.group_hover_style != null) window.refresh();
        }

        fn onMouseExit(raw: *anyopaque, e: *const MouseExitEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            if (phase != .bubble) return;
            if (c.hitbox.is_hovered(window)) {
                for (it.mouse_exit_listeners.items) |l| l.call(e, window, cx);
            }
            // The pointer can leave without a last move, so the hover listener is cleared here too.
            if (it.hover_listener) |hl| if (c.state) |st| {
                if (st.hover_listener_state) {
                    st.hover_listener_state = false;
                    const off = false;
                    hl.call(&off, window, cx);
                }
            };
        }

        fn onFileDrop(raw: *anyopaque, e: *const FileDropEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            if (phase != .bubble or std.meta.activeTag(e.*) != .exited) return;
            if (!c.hitbox.is_hovered_ignoring_last_input(window)) return;
            for (it.file_drop_exit_listeners.items) |l| l.call(e, window, cx);
        }

        fn onPinch(raw: *anyopaque, e: *const PinchEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            if (!c.hitbox.is_hovered(window)) return;
            const list = if (phase == .capture) it.capture_pinch_listeners.items else it.pinch_listeners.items;
            for (list) |l| l.call(e, window, cx);
        }

        fn onMousePressure(raw: *anyopaque, e: *const MousePressureEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            if (!c.hitbox.is_hovered(window)) return;
            const list = if (phase == .capture) it.capture_mouse_pressure_listeners.items else it.mouse_pressure_listeners.items;
            for (list) |l| l.call(e, window, cx);
        }

        fn onScrollWheel(raw: *anyopaque, e: *const ScrollWheelEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
            const c: *MouseCtx = @ptrCast(@alignCast(raw));
            const it = &c.self.interactivity;
            if (it.tooltip_builder != null) if (c.state) |st| dismiss_tooltip_on_input(st, window, cx);
            if (phase != .bubble or !c.hitbox.should_handle_scroll(window)) return;
            for (it.scroll_wheel_listeners.items) |l| l.call(e, window, cx);
            const s = it.base_style.overflow;
            if (s.x != .scroll and s.y != .scroll) return;
            const delta = e.delta.pixel_delta(window.line_height());
            const old: Point(Pixels) = if (it.tracked_scroll_handle) |sh| sh.offset() else if (c.state) |st| st.scroll_offset else return;
            // Unset refinements read as the defaults: visible overflow, and both flags off.
            const step = scroll_step(delta, s.x orelse .visible, s.y orelse .visible, it.base_style.restrict_scroll_to_axis orelse false, it.base_style.allow_concurrent_scroll orelse false);
            var off: Point(Pixels) = .{ .x = old.x + step.x, .y = old.y + step.y };
            // Unknown until the first frame; prepaint clamps again in any case.
            const max: ?Size(Pixels) = if (it.tracked_scroll_handle) |sh| sh.max_offset() else if (c.state) |st| st.scroll_max else null;
            if (max) |limit| off = clamp_scroll(off, limit);
            // At the limit nothing moved, so nothing needs drawing. Unlike the old behaviour, the event
            // is not stopped: an outer scroll container under this one scrolls too, as in GPUI.
            if (off.x == old.x and off.y == old.y) return;
            if (it.tracked_scroll_handle) |sh| sh.set_offset(off);
            if (c.state) |st| st.scroll_offset = off;
            window.refresh();
        }

        // Styled methods (generated from styled.zig).
        pub const text_style = StyledM.text_style;
        pub const block = StyledM.block;
        pub const flex = StyledM.flex;
        pub const grid = StyledM.grid;
        pub const hidden = StyledM.hidden;
        pub const scrollbar_width = StyledM.scrollbar_width;
        pub const whitespace_normal = StyledM.whitespace_normal;
        pub const whitespace_nowrap = StyledM.whitespace_nowrap;
        pub const text_ellipsis = StyledM.text_ellipsis;
        pub const text_ellipsis_start = StyledM.text_ellipsis_start;
        pub const text_ellipsis_middle = StyledM.text_ellipsis_middle;
        pub const text_overflow = StyledM.text_overflow;
        pub const text_align = StyledM.text_align;
        pub const text_left = StyledM.text_left;
        pub const text_center = StyledM.text_center;
        pub const text_right = StyledM.text_right;
        pub const truncate = StyledM.truncate;
        pub const line_clamp = StyledM.line_clamp;
        pub const flex_col = StyledM.flex_col;
        pub const flex_col_reverse = StyledM.flex_col_reverse;
        pub const flex_row = StyledM.flex_row;
        pub const flex_row_reverse = StyledM.flex_row_reverse;
        pub const flex_1 = StyledM.flex_1;
        pub const flex_auto = StyledM.flex_auto;
        pub const flex_initial = StyledM.flex_initial;
        pub const flex_none = StyledM.flex_none;
        pub const flex_basis = StyledM.flex_basis;
        pub const flex_grow = StyledM.flex_grow;
        pub const flex_grow_0 = StyledM.flex_grow_0;
        pub const flex_grow_1 = StyledM.flex_grow_1;
        pub const flex_shrink = StyledM.flex_shrink;
        pub const flex_shrink_0 = StyledM.flex_shrink_0;
        pub const flex_shrink_1 = StyledM.flex_shrink_1;
        pub const flex_wrap = StyledM.flex_wrap;
        pub const flex_wrap_reverse = StyledM.flex_wrap_reverse;
        pub const flex_nowrap = StyledM.flex_nowrap;
        pub const items_start = StyledM.items_start;
        pub const items_end = StyledM.items_end;
        pub const items_center = StyledM.items_center;
        pub const items_baseline = StyledM.items_baseline;
        pub const items_stretch = StyledM.items_stretch;
        pub const self_start = StyledM.self_start;
        pub const self_end = StyledM.self_end;
        pub const self_flex_start = StyledM.self_flex_start;
        pub const self_flex_end = StyledM.self_flex_end;
        pub const self_center = StyledM.self_center;
        pub const self_baseline = StyledM.self_baseline;
        pub const self_stretch = StyledM.self_stretch;
        pub const justify_start = StyledM.justify_start;
        pub const justify_end = StyledM.justify_end;
        pub const justify_center = StyledM.justify_center;
        pub const justify_between = StyledM.justify_between;
        pub const justify_around = StyledM.justify_around;
        pub const justify_evenly = StyledM.justify_evenly;
        pub const content_normal = StyledM.content_normal;
        pub const content_center = StyledM.content_center;
        pub const content_start = StyledM.content_start;
        pub const content_end = StyledM.content_end;
        pub const content_between = StyledM.content_between;
        pub const content_around = StyledM.content_around;
        pub const content_evenly = StyledM.content_evenly;
        pub const content_stretch = StyledM.content_stretch;
        pub const aspect_ratio = StyledM.aspect_ratio;
        pub const aspect_square = StyledM.aspect_square;
        pub const bg = StyledM.bg;
        pub const border_dashed = StyledM.border_dashed;
        pub const border_color = StyledM.border_color;
        pub const text_color = StyledM.text_color;
        pub const font_weight = StyledM.font_weight;
        pub const text_bg = StyledM.text_bg;
        pub const text_size = StyledM.text_size;
        pub const text_xs = StyledM.text_xs;
        pub const text_sm = StyledM.text_sm;
        pub const text_base = StyledM.text_base;
        pub const text_lg = StyledM.text_lg;
        pub const text_xl = StyledM.text_xl;
        pub const text_2xl = StyledM.text_2xl;
        pub const text_3xl = StyledM.text_3xl;
        pub const italic = StyledM.italic;
        pub const not_italic = StyledM.not_italic;
        pub const underline = StyledM.underline;
        pub const line_through = StyledM.line_through;
        pub const text_decoration_none = StyledM.text_decoration_none;
        pub const text_decoration_color = StyledM.text_decoration_color;
        pub const text_decoration_solid = StyledM.text_decoration_solid;
        pub const text_decoration_wavy = StyledM.text_decoration_wavy;
        pub const text_decoration_0 = StyledM.text_decoration_0;
        pub const text_decoration_1 = StyledM.text_decoration_1;
        pub const text_decoration_2 = StyledM.text_decoration_2;
        pub const text_decoration_4 = StyledM.text_decoration_4;
        pub const text_decoration_8 = StyledM.text_decoration_8;
        pub const font_family = StyledM.font_family;
        pub const font_features = StyledM.font_features;
        pub const font = StyledM.font;
        pub const line_height = StyledM.line_height;
        pub const opacity = StyledM.opacity;
        pub const grid_cols = StyledM.grid_cols;
        pub const grid_cols_min_content = StyledM.grid_cols_min_content;
        pub const grid_cols_max_content = StyledM.grid_cols_max_content;
        pub const grid_rows = StyledM.grid_rows;
        pub const grid_rows_min_content = StyledM.grid_rows_min_content;
        pub const grid_rows_max_content = StyledM.grid_rows_max_content;
        pub const col_start = StyledM.col_start;
        pub const col_start_auto = StyledM.col_start_auto;
        pub const col_end = StyledM.col_end;
        pub const col_end_auto = StyledM.col_end_auto;
        pub const col_span = StyledM.col_span;
        pub const col_span_full = StyledM.col_span_full;
        pub const row_start = StyledM.row_start;
        pub const row_start_auto = StyledM.row_start_auto;
        pub const row_end = StyledM.row_end;
        pub const row_end_auto = StyledM.row_end_auto;
        pub const row_span = StyledM.row_span;
        pub const row_span_full = StyledM.row_span_full;
        pub const debug = StyledM.debug;
        pub const debug_below = StyledM.debug_below;
        pub const visible = StyledM.visible;
        pub const invisible = StyledM.invisible;
        pub const relative = StyledM.relative;
        pub const absolute = StyledM.absolute;
        pub const overflow_hidden = StyledM.overflow_hidden;
        pub const overflow_scroll = StyledM.overflow_scroll;
        pub const overflow_x_scroll = StyledM.overflow_x_scroll;
        pub const overflow_y_scroll = StyledM.overflow_y_scroll;
        pub const overflow_x_hidden = StyledM.overflow_x_hidden;
        pub const overflow_y_hidden = StyledM.overflow_y_hidden;
        pub const cursor = StyledM.cursor;
        pub const cursor_default = StyledM.cursor_default;
        pub const cursor_pointer = StyledM.cursor_pointer;
        pub const cursor_text = StyledM.cursor_text;
        pub const cursor_move = StyledM.cursor_move;
        pub const cursor_not_allowed = StyledM.cursor_not_allowed;
        pub const cursor_context_menu = StyledM.cursor_context_menu;
        pub const cursor_crosshair = StyledM.cursor_crosshair;
        pub const cursor_vertical_text = StyledM.cursor_vertical_text;
        pub const cursor_alias = StyledM.cursor_alias;
        pub const cursor_copy = StyledM.cursor_copy;
        pub const cursor_no_drop = StyledM.cursor_no_drop;
        pub const cursor_grab = StyledM.cursor_grab;
        pub const cursor_grabbing = StyledM.cursor_grabbing;
        pub const cursor_ew_resize = StyledM.cursor_ew_resize;
        pub const cursor_ns_resize = StyledM.cursor_ns_resize;
        pub const cursor_nesw_resize = StyledM.cursor_nesw_resize;
        pub const cursor_nwse_resize = StyledM.cursor_nwse_resize;
        pub const cursor_col_resize = StyledM.cursor_col_resize;
        pub const cursor_row_resize = StyledM.cursor_row_resize;
        pub const cursor_n_resize = StyledM.cursor_n_resize;
        pub const cursor_e_resize = StyledM.cursor_e_resize;
        pub const cursor_s_resize = StyledM.cursor_s_resize;
        pub const cursor_w_resize = StyledM.cursor_w_resize;
        pub const border = StyledM.border;
        pub const border_0 = StyledM.border_0;
        pub const border_1 = StyledM.border_1;
        pub const border_2 = StyledM.border_2;
        pub const border_3 = StyledM.border_3;
        pub const border_4 = StyledM.border_4;
        pub const border_5 = StyledM.border_5;
        pub const border_6 = StyledM.border_6;
        pub const border_7 = StyledM.border_7;
        pub const border_8 = StyledM.border_8;
        pub const border_9 = StyledM.border_9;
        pub const border_10 = StyledM.border_10;
        pub const border_11 = StyledM.border_11;
        pub const border_12 = StyledM.border_12;
        pub const border_16 = StyledM.border_16;
        pub const border_20 = StyledM.border_20;
        pub const border_24 = StyledM.border_24;
        pub const border_32 = StyledM.border_32;
        pub const border_t = StyledM.border_t;
        pub const border_t_0 = StyledM.border_t_0;
        pub const border_t_1 = StyledM.border_t_1;
        pub const border_t_2 = StyledM.border_t_2;
        pub const border_t_3 = StyledM.border_t_3;
        pub const border_t_4 = StyledM.border_t_4;
        pub const border_t_5 = StyledM.border_t_5;
        pub const border_t_6 = StyledM.border_t_6;
        pub const border_t_7 = StyledM.border_t_7;
        pub const border_t_8 = StyledM.border_t_8;
        pub const border_t_9 = StyledM.border_t_9;
        pub const border_t_10 = StyledM.border_t_10;
        pub const border_t_11 = StyledM.border_t_11;
        pub const border_t_12 = StyledM.border_t_12;
        pub const border_t_16 = StyledM.border_t_16;
        pub const border_t_20 = StyledM.border_t_20;
        pub const border_t_24 = StyledM.border_t_24;
        pub const border_t_32 = StyledM.border_t_32;
        pub const border_b = StyledM.border_b;
        pub const border_b_0 = StyledM.border_b_0;
        pub const border_b_1 = StyledM.border_b_1;
        pub const border_b_2 = StyledM.border_b_2;
        pub const border_b_3 = StyledM.border_b_3;
        pub const border_b_4 = StyledM.border_b_4;
        pub const border_b_5 = StyledM.border_b_5;
        pub const border_b_6 = StyledM.border_b_6;
        pub const border_b_7 = StyledM.border_b_7;
        pub const border_b_8 = StyledM.border_b_8;
        pub const border_b_9 = StyledM.border_b_9;
        pub const border_b_10 = StyledM.border_b_10;
        pub const border_b_11 = StyledM.border_b_11;
        pub const border_b_12 = StyledM.border_b_12;
        pub const border_b_16 = StyledM.border_b_16;
        pub const border_b_20 = StyledM.border_b_20;
        pub const border_b_24 = StyledM.border_b_24;
        pub const border_b_32 = StyledM.border_b_32;
        pub const border_r = StyledM.border_r;
        pub const border_r_0 = StyledM.border_r_0;
        pub const border_r_1 = StyledM.border_r_1;
        pub const border_r_2 = StyledM.border_r_2;
        pub const border_r_3 = StyledM.border_r_3;
        pub const border_r_4 = StyledM.border_r_4;
        pub const border_r_5 = StyledM.border_r_5;
        pub const border_r_6 = StyledM.border_r_6;
        pub const border_r_7 = StyledM.border_r_7;
        pub const border_r_8 = StyledM.border_r_8;
        pub const border_r_9 = StyledM.border_r_9;
        pub const border_r_10 = StyledM.border_r_10;
        pub const border_r_11 = StyledM.border_r_11;
        pub const border_r_12 = StyledM.border_r_12;
        pub const border_r_16 = StyledM.border_r_16;
        pub const border_r_20 = StyledM.border_r_20;
        pub const border_r_24 = StyledM.border_r_24;
        pub const border_r_32 = StyledM.border_r_32;
        pub const border_l = StyledM.border_l;
        pub const border_l_0 = StyledM.border_l_0;
        pub const border_l_1 = StyledM.border_l_1;
        pub const border_l_2 = StyledM.border_l_2;
        pub const border_l_3 = StyledM.border_l_3;
        pub const border_l_4 = StyledM.border_l_4;
        pub const border_l_5 = StyledM.border_l_5;
        pub const border_l_6 = StyledM.border_l_6;
        pub const border_l_7 = StyledM.border_l_7;
        pub const border_l_8 = StyledM.border_l_8;
        pub const border_l_9 = StyledM.border_l_9;
        pub const border_l_10 = StyledM.border_l_10;
        pub const border_l_11 = StyledM.border_l_11;
        pub const border_l_12 = StyledM.border_l_12;
        pub const border_l_16 = StyledM.border_l_16;
        pub const border_l_20 = StyledM.border_l_20;
        pub const border_l_24 = StyledM.border_l_24;
        pub const border_l_32 = StyledM.border_l_32;
        pub const border_x = StyledM.border_x;
        pub const border_x_0 = StyledM.border_x_0;
        pub const border_x_1 = StyledM.border_x_1;
        pub const border_x_2 = StyledM.border_x_2;
        pub const border_x_3 = StyledM.border_x_3;
        pub const border_x_4 = StyledM.border_x_4;
        pub const border_x_5 = StyledM.border_x_5;
        pub const border_x_6 = StyledM.border_x_6;
        pub const border_x_7 = StyledM.border_x_7;
        pub const border_x_8 = StyledM.border_x_8;
        pub const border_x_9 = StyledM.border_x_9;
        pub const border_x_10 = StyledM.border_x_10;
        pub const border_x_11 = StyledM.border_x_11;
        pub const border_x_12 = StyledM.border_x_12;
        pub const border_x_16 = StyledM.border_x_16;
        pub const border_x_20 = StyledM.border_x_20;
        pub const border_x_24 = StyledM.border_x_24;
        pub const border_x_32 = StyledM.border_x_32;
        pub const border_y = StyledM.border_y;
        pub const border_y_0 = StyledM.border_y_0;
        pub const border_y_1 = StyledM.border_y_1;
        pub const border_y_2 = StyledM.border_y_2;
        pub const border_y_3 = StyledM.border_y_3;
        pub const border_y_4 = StyledM.border_y_4;
        pub const border_y_5 = StyledM.border_y_5;
        pub const border_y_6 = StyledM.border_y_6;
        pub const border_y_7 = StyledM.border_y_7;
        pub const border_y_8 = StyledM.border_y_8;
        pub const border_y_9 = StyledM.border_y_9;
        pub const border_y_10 = StyledM.border_y_10;
        pub const border_y_11 = StyledM.border_y_11;
        pub const border_y_12 = StyledM.border_y_12;
        pub const border_y_16 = StyledM.border_y_16;
        pub const border_y_20 = StyledM.border_y_20;
        pub const border_y_24 = StyledM.border_y_24;
        pub const border_y_32 = StyledM.border_y_32;
        pub const m = StyledM.m;
        pub const m_0 = StyledM.m_0;
        pub const m_neg_0 = StyledM.m_neg_0;
        pub const m_0p5 = StyledM.m_0p5;
        pub const m_neg_0p5 = StyledM.m_neg_0p5;
        pub const m_1 = StyledM.m_1;
        pub const m_neg_1 = StyledM.m_neg_1;
        pub const m_1p5 = StyledM.m_1p5;
        pub const m_neg_1p5 = StyledM.m_neg_1p5;
        pub const m_2 = StyledM.m_2;
        pub const m_neg_2 = StyledM.m_neg_2;
        pub const m_2p5 = StyledM.m_2p5;
        pub const m_neg_2p5 = StyledM.m_neg_2p5;
        pub const m_3 = StyledM.m_3;
        pub const m_neg_3 = StyledM.m_neg_3;
        pub const m_3p5 = StyledM.m_3p5;
        pub const m_neg_3p5 = StyledM.m_neg_3p5;
        pub const m_4 = StyledM.m_4;
        pub const m_neg_4 = StyledM.m_neg_4;
        pub const m_5 = StyledM.m_5;
        pub const m_neg_5 = StyledM.m_neg_5;
        pub const m_6 = StyledM.m_6;
        pub const m_neg_6 = StyledM.m_neg_6;
        pub const m_7 = StyledM.m_7;
        pub const m_neg_7 = StyledM.m_neg_7;
        pub const m_8 = StyledM.m_8;
        pub const m_neg_8 = StyledM.m_neg_8;
        pub const m_9 = StyledM.m_9;
        pub const m_neg_9 = StyledM.m_neg_9;
        pub const m_10 = StyledM.m_10;
        pub const m_neg_10 = StyledM.m_neg_10;
        pub const m_11 = StyledM.m_11;
        pub const m_neg_11 = StyledM.m_neg_11;
        pub const m_12 = StyledM.m_12;
        pub const m_neg_12 = StyledM.m_neg_12;
        pub const m_16 = StyledM.m_16;
        pub const m_neg_16 = StyledM.m_neg_16;
        pub const m_20 = StyledM.m_20;
        pub const m_neg_20 = StyledM.m_neg_20;
        pub const m_24 = StyledM.m_24;
        pub const m_neg_24 = StyledM.m_neg_24;
        pub const m_32 = StyledM.m_32;
        pub const m_neg_32 = StyledM.m_neg_32;
        pub const m_40 = StyledM.m_40;
        pub const m_neg_40 = StyledM.m_neg_40;
        pub const m_48 = StyledM.m_48;
        pub const m_neg_48 = StyledM.m_neg_48;
        pub const m_56 = StyledM.m_56;
        pub const m_neg_56 = StyledM.m_neg_56;
        pub const m_64 = StyledM.m_64;
        pub const m_neg_64 = StyledM.m_neg_64;
        pub const m_72 = StyledM.m_72;
        pub const m_neg_72 = StyledM.m_neg_72;
        pub const m_80 = StyledM.m_80;
        pub const m_neg_80 = StyledM.m_neg_80;
        pub const m_96 = StyledM.m_96;
        pub const m_neg_96 = StyledM.m_neg_96;
        pub const m_112 = StyledM.m_112;
        pub const m_neg_112 = StyledM.m_neg_112;
        pub const m_128 = StyledM.m_128;
        pub const m_neg_128 = StyledM.m_neg_128;
        pub const m_auto = StyledM.m_auto;
        pub const m_px = StyledM.m_px;
        pub const m_neg_px = StyledM.m_neg_px;
        pub const m_full = StyledM.m_full;
        pub const m_neg_full = StyledM.m_neg_full;
        pub const m_1_2 = StyledM.m_1_2;
        pub const m_neg_1_2 = StyledM.m_neg_1_2;
        pub const m_1_3 = StyledM.m_1_3;
        pub const m_neg_1_3 = StyledM.m_neg_1_3;
        pub const m_2_3 = StyledM.m_2_3;
        pub const m_neg_2_3 = StyledM.m_neg_2_3;
        pub const m_1_4 = StyledM.m_1_4;
        pub const m_neg_1_4 = StyledM.m_neg_1_4;
        pub const m_2_4 = StyledM.m_2_4;
        pub const m_neg_2_4 = StyledM.m_neg_2_4;
        pub const m_3_4 = StyledM.m_3_4;
        pub const m_neg_3_4 = StyledM.m_neg_3_4;
        pub const m_1_5 = StyledM.m_1_5;
        pub const m_neg_1_5 = StyledM.m_neg_1_5;
        pub const m_2_5 = StyledM.m_2_5;
        pub const m_neg_2_5 = StyledM.m_neg_2_5;
        pub const m_3_5 = StyledM.m_3_5;
        pub const m_neg_3_5 = StyledM.m_neg_3_5;
        pub const m_4_5 = StyledM.m_4_5;
        pub const m_neg_4_5 = StyledM.m_neg_4_5;
        pub const m_1_6 = StyledM.m_1_6;
        pub const m_neg_1_6 = StyledM.m_neg_1_6;
        pub const m_5_6 = StyledM.m_5_6;
        pub const m_neg_5_6 = StyledM.m_neg_5_6;
        pub const m_1_12 = StyledM.m_1_12;
        pub const m_neg_1_12 = StyledM.m_neg_1_12;
        pub const mt = StyledM.mt;
        pub const mt_0 = StyledM.mt_0;
        pub const mt_neg_0 = StyledM.mt_neg_0;
        pub const mt_0p5 = StyledM.mt_0p5;
        pub const mt_neg_0p5 = StyledM.mt_neg_0p5;
        pub const mt_1 = StyledM.mt_1;
        pub const mt_neg_1 = StyledM.mt_neg_1;
        pub const mt_1p5 = StyledM.mt_1p5;
        pub const mt_neg_1p5 = StyledM.mt_neg_1p5;
        pub const mt_2 = StyledM.mt_2;
        pub const mt_neg_2 = StyledM.mt_neg_2;
        pub const mt_2p5 = StyledM.mt_2p5;
        pub const mt_neg_2p5 = StyledM.mt_neg_2p5;
        pub const mt_3 = StyledM.mt_3;
        pub const mt_neg_3 = StyledM.mt_neg_3;
        pub const mt_3p5 = StyledM.mt_3p5;
        pub const mt_neg_3p5 = StyledM.mt_neg_3p5;
        pub const mt_4 = StyledM.mt_4;
        pub const mt_neg_4 = StyledM.mt_neg_4;
        pub const mt_5 = StyledM.mt_5;
        pub const mt_neg_5 = StyledM.mt_neg_5;
        pub const mt_6 = StyledM.mt_6;
        pub const mt_neg_6 = StyledM.mt_neg_6;
        pub const mt_7 = StyledM.mt_7;
        pub const mt_neg_7 = StyledM.mt_neg_7;
        pub const mt_8 = StyledM.mt_8;
        pub const mt_neg_8 = StyledM.mt_neg_8;
        pub const mt_9 = StyledM.mt_9;
        pub const mt_neg_9 = StyledM.mt_neg_9;
        pub const mt_10 = StyledM.mt_10;
        pub const mt_neg_10 = StyledM.mt_neg_10;
        pub const mt_11 = StyledM.mt_11;
        pub const mt_neg_11 = StyledM.mt_neg_11;
        pub const mt_12 = StyledM.mt_12;
        pub const mt_neg_12 = StyledM.mt_neg_12;
        pub const mt_16 = StyledM.mt_16;
        pub const mt_neg_16 = StyledM.mt_neg_16;
        pub const mt_20 = StyledM.mt_20;
        pub const mt_neg_20 = StyledM.mt_neg_20;
        pub const mt_24 = StyledM.mt_24;
        pub const mt_neg_24 = StyledM.mt_neg_24;
        pub const mt_32 = StyledM.mt_32;
        pub const mt_neg_32 = StyledM.mt_neg_32;
        pub const mt_40 = StyledM.mt_40;
        pub const mt_neg_40 = StyledM.mt_neg_40;
        pub const mt_48 = StyledM.mt_48;
        pub const mt_neg_48 = StyledM.mt_neg_48;
        pub const mt_56 = StyledM.mt_56;
        pub const mt_neg_56 = StyledM.mt_neg_56;
        pub const mt_64 = StyledM.mt_64;
        pub const mt_neg_64 = StyledM.mt_neg_64;
        pub const mt_72 = StyledM.mt_72;
        pub const mt_neg_72 = StyledM.mt_neg_72;
        pub const mt_80 = StyledM.mt_80;
        pub const mt_neg_80 = StyledM.mt_neg_80;
        pub const mt_96 = StyledM.mt_96;
        pub const mt_neg_96 = StyledM.mt_neg_96;
        pub const mt_112 = StyledM.mt_112;
        pub const mt_neg_112 = StyledM.mt_neg_112;
        pub const mt_128 = StyledM.mt_128;
        pub const mt_neg_128 = StyledM.mt_neg_128;
        pub const mt_auto = StyledM.mt_auto;
        pub const mt_px = StyledM.mt_px;
        pub const mt_neg_px = StyledM.mt_neg_px;
        pub const mt_full = StyledM.mt_full;
        pub const mt_neg_full = StyledM.mt_neg_full;
        pub const mt_1_2 = StyledM.mt_1_2;
        pub const mt_neg_1_2 = StyledM.mt_neg_1_2;
        pub const mt_1_3 = StyledM.mt_1_3;
        pub const mt_neg_1_3 = StyledM.mt_neg_1_3;
        pub const mt_2_3 = StyledM.mt_2_3;
        pub const mt_neg_2_3 = StyledM.mt_neg_2_3;
        pub const mt_1_4 = StyledM.mt_1_4;
        pub const mt_neg_1_4 = StyledM.mt_neg_1_4;
        pub const mt_2_4 = StyledM.mt_2_4;
        pub const mt_neg_2_4 = StyledM.mt_neg_2_4;
        pub const mt_3_4 = StyledM.mt_3_4;
        pub const mt_neg_3_4 = StyledM.mt_neg_3_4;
        pub const mt_1_5 = StyledM.mt_1_5;
        pub const mt_neg_1_5 = StyledM.mt_neg_1_5;
        pub const mt_2_5 = StyledM.mt_2_5;
        pub const mt_neg_2_5 = StyledM.mt_neg_2_5;
        pub const mt_3_5 = StyledM.mt_3_5;
        pub const mt_neg_3_5 = StyledM.mt_neg_3_5;
        pub const mt_4_5 = StyledM.mt_4_5;
        pub const mt_neg_4_5 = StyledM.mt_neg_4_5;
        pub const mt_1_6 = StyledM.mt_1_6;
        pub const mt_neg_1_6 = StyledM.mt_neg_1_6;
        pub const mt_5_6 = StyledM.mt_5_6;
        pub const mt_neg_5_6 = StyledM.mt_neg_5_6;
        pub const mt_1_12 = StyledM.mt_1_12;
        pub const mt_neg_1_12 = StyledM.mt_neg_1_12;
        pub const mb = StyledM.mb;
        pub const mb_0 = StyledM.mb_0;
        pub const mb_neg_0 = StyledM.mb_neg_0;
        pub const mb_0p5 = StyledM.mb_0p5;
        pub const mb_neg_0p5 = StyledM.mb_neg_0p5;
        pub const mb_1 = StyledM.mb_1;
        pub const mb_neg_1 = StyledM.mb_neg_1;
        pub const mb_1p5 = StyledM.mb_1p5;
        pub const mb_neg_1p5 = StyledM.mb_neg_1p5;
        pub const mb_2 = StyledM.mb_2;
        pub const mb_neg_2 = StyledM.mb_neg_2;
        pub const mb_2p5 = StyledM.mb_2p5;
        pub const mb_neg_2p5 = StyledM.mb_neg_2p5;
        pub const mb_3 = StyledM.mb_3;
        pub const mb_neg_3 = StyledM.mb_neg_3;
        pub const mb_3p5 = StyledM.mb_3p5;
        pub const mb_neg_3p5 = StyledM.mb_neg_3p5;
        pub const mb_4 = StyledM.mb_4;
        pub const mb_neg_4 = StyledM.mb_neg_4;
        pub const mb_5 = StyledM.mb_5;
        pub const mb_neg_5 = StyledM.mb_neg_5;
        pub const mb_6 = StyledM.mb_6;
        pub const mb_neg_6 = StyledM.mb_neg_6;
        pub const mb_7 = StyledM.mb_7;
        pub const mb_neg_7 = StyledM.mb_neg_7;
        pub const mb_8 = StyledM.mb_8;
        pub const mb_neg_8 = StyledM.mb_neg_8;
        pub const mb_9 = StyledM.mb_9;
        pub const mb_neg_9 = StyledM.mb_neg_9;
        pub const mb_10 = StyledM.mb_10;
        pub const mb_neg_10 = StyledM.mb_neg_10;
        pub const mb_11 = StyledM.mb_11;
        pub const mb_neg_11 = StyledM.mb_neg_11;
        pub const mb_12 = StyledM.mb_12;
        pub const mb_neg_12 = StyledM.mb_neg_12;
        pub const mb_16 = StyledM.mb_16;
        pub const mb_neg_16 = StyledM.mb_neg_16;
        pub const mb_20 = StyledM.mb_20;
        pub const mb_neg_20 = StyledM.mb_neg_20;
        pub const mb_24 = StyledM.mb_24;
        pub const mb_neg_24 = StyledM.mb_neg_24;
        pub const mb_32 = StyledM.mb_32;
        pub const mb_neg_32 = StyledM.mb_neg_32;
        pub const mb_40 = StyledM.mb_40;
        pub const mb_neg_40 = StyledM.mb_neg_40;
        pub const mb_48 = StyledM.mb_48;
        pub const mb_neg_48 = StyledM.mb_neg_48;
        pub const mb_56 = StyledM.mb_56;
        pub const mb_neg_56 = StyledM.mb_neg_56;
        pub const mb_64 = StyledM.mb_64;
        pub const mb_neg_64 = StyledM.mb_neg_64;
        pub const mb_72 = StyledM.mb_72;
        pub const mb_neg_72 = StyledM.mb_neg_72;
        pub const mb_80 = StyledM.mb_80;
        pub const mb_neg_80 = StyledM.mb_neg_80;
        pub const mb_96 = StyledM.mb_96;
        pub const mb_neg_96 = StyledM.mb_neg_96;
        pub const mb_112 = StyledM.mb_112;
        pub const mb_neg_112 = StyledM.mb_neg_112;
        pub const mb_128 = StyledM.mb_128;
        pub const mb_neg_128 = StyledM.mb_neg_128;
        pub const mb_auto = StyledM.mb_auto;
        pub const mb_px = StyledM.mb_px;
        pub const mb_neg_px = StyledM.mb_neg_px;
        pub const mb_full = StyledM.mb_full;
        pub const mb_neg_full = StyledM.mb_neg_full;
        pub const mb_1_2 = StyledM.mb_1_2;
        pub const mb_neg_1_2 = StyledM.mb_neg_1_2;
        pub const mb_1_3 = StyledM.mb_1_3;
        pub const mb_neg_1_3 = StyledM.mb_neg_1_3;
        pub const mb_2_3 = StyledM.mb_2_3;
        pub const mb_neg_2_3 = StyledM.mb_neg_2_3;
        pub const mb_1_4 = StyledM.mb_1_4;
        pub const mb_neg_1_4 = StyledM.mb_neg_1_4;
        pub const mb_2_4 = StyledM.mb_2_4;
        pub const mb_neg_2_4 = StyledM.mb_neg_2_4;
        pub const mb_3_4 = StyledM.mb_3_4;
        pub const mb_neg_3_4 = StyledM.mb_neg_3_4;
        pub const mb_1_5 = StyledM.mb_1_5;
        pub const mb_neg_1_5 = StyledM.mb_neg_1_5;
        pub const mb_2_5 = StyledM.mb_2_5;
        pub const mb_neg_2_5 = StyledM.mb_neg_2_5;
        pub const mb_3_5 = StyledM.mb_3_5;
        pub const mb_neg_3_5 = StyledM.mb_neg_3_5;
        pub const mb_4_5 = StyledM.mb_4_5;
        pub const mb_neg_4_5 = StyledM.mb_neg_4_5;
        pub const mb_1_6 = StyledM.mb_1_6;
        pub const mb_neg_1_6 = StyledM.mb_neg_1_6;
        pub const mb_5_6 = StyledM.mb_5_6;
        pub const mb_neg_5_6 = StyledM.mb_neg_5_6;
        pub const mb_1_12 = StyledM.mb_1_12;
        pub const mb_neg_1_12 = StyledM.mb_neg_1_12;
        pub const my = StyledM.my;
        pub const my_0 = StyledM.my_0;
        pub const my_neg_0 = StyledM.my_neg_0;
        pub const my_0p5 = StyledM.my_0p5;
        pub const my_neg_0p5 = StyledM.my_neg_0p5;
        pub const my_1 = StyledM.my_1;
        pub const my_neg_1 = StyledM.my_neg_1;
        pub const my_1p5 = StyledM.my_1p5;
        pub const my_neg_1p5 = StyledM.my_neg_1p5;
        pub const my_2 = StyledM.my_2;
        pub const my_neg_2 = StyledM.my_neg_2;
        pub const my_2p5 = StyledM.my_2p5;
        pub const my_neg_2p5 = StyledM.my_neg_2p5;
        pub const my_3 = StyledM.my_3;
        pub const my_neg_3 = StyledM.my_neg_3;
        pub const my_3p5 = StyledM.my_3p5;
        pub const my_neg_3p5 = StyledM.my_neg_3p5;
        pub const my_4 = StyledM.my_4;
        pub const my_neg_4 = StyledM.my_neg_4;
        pub const my_5 = StyledM.my_5;
        pub const my_neg_5 = StyledM.my_neg_5;
        pub const my_6 = StyledM.my_6;
        pub const my_neg_6 = StyledM.my_neg_6;
        pub const my_7 = StyledM.my_7;
        pub const my_neg_7 = StyledM.my_neg_7;
        pub const my_8 = StyledM.my_8;
        pub const my_neg_8 = StyledM.my_neg_8;
        pub const my_9 = StyledM.my_9;
        pub const my_neg_9 = StyledM.my_neg_9;
        pub const my_10 = StyledM.my_10;
        pub const my_neg_10 = StyledM.my_neg_10;
        pub const my_11 = StyledM.my_11;
        pub const my_neg_11 = StyledM.my_neg_11;
        pub const my_12 = StyledM.my_12;
        pub const my_neg_12 = StyledM.my_neg_12;
        pub const my_16 = StyledM.my_16;
        pub const my_neg_16 = StyledM.my_neg_16;
        pub const my_20 = StyledM.my_20;
        pub const my_neg_20 = StyledM.my_neg_20;
        pub const my_24 = StyledM.my_24;
        pub const my_neg_24 = StyledM.my_neg_24;
        pub const my_32 = StyledM.my_32;
        pub const my_neg_32 = StyledM.my_neg_32;
        pub const my_40 = StyledM.my_40;
        pub const my_neg_40 = StyledM.my_neg_40;
        pub const my_48 = StyledM.my_48;
        pub const my_neg_48 = StyledM.my_neg_48;
        pub const my_56 = StyledM.my_56;
        pub const my_neg_56 = StyledM.my_neg_56;
        pub const my_64 = StyledM.my_64;
        pub const my_neg_64 = StyledM.my_neg_64;
        pub const my_72 = StyledM.my_72;
        pub const my_neg_72 = StyledM.my_neg_72;
        pub const my_80 = StyledM.my_80;
        pub const my_neg_80 = StyledM.my_neg_80;
        pub const my_96 = StyledM.my_96;
        pub const my_neg_96 = StyledM.my_neg_96;
        pub const my_112 = StyledM.my_112;
        pub const my_neg_112 = StyledM.my_neg_112;
        pub const my_128 = StyledM.my_128;
        pub const my_neg_128 = StyledM.my_neg_128;
        pub const my_auto = StyledM.my_auto;
        pub const my_px = StyledM.my_px;
        pub const my_neg_px = StyledM.my_neg_px;
        pub const my_full = StyledM.my_full;
        pub const my_neg_full = StyledM.my_neg_full;
        pub const my_1_2 = StyledM.my_1_2;
        pub const my_neg_1_2 = StyledM.my_neg_1_2;
        pub const my_1_3 = StyledM.my_1_3;
        pub const my_neg_1_3 = StyledM.my_neg_1_3;
        pub const my_2_3 = StyledM.my_2_3;
        pub const my_neg_2_3 = StyledM.my_neg_2_3;
        pub const my_1_4 = StyledM.my_1_4;
        pub const my_neg_1_4 = StyledM.my_neg_1_4;
        pub const my_2_4 = StyledM.my_2_4;
        pub const my_neg_2_4 = StyledM.my_neg_2_4;
        pub const my_3_4 = StyledM.my_3_4;
        pub const my_neg_3_4 = StyledM.my_neg_3_4;
        pub const my_1_5 = StyledM.my_1_5;
        pub const my_neg_1_5 = StyledM.my_neg_1_5;
        pub const my_2_5 = StyledM.my_2_5;
        pub const my_neg_2_5 = StyledM.my_neg_2_5;
        pub const my_3_5 = StyledM.my_3_5;
        pub const my_neg_3_5 = StyledM.my_neg_3_5;
        pub const my_4_5 = StyledM.my_4_5;
        pub const my_neg_4_5 = StyledM.my_neg_4_5;
        pub const my_1_6 = StyledM.my_1_6;
        pub const my_neg_1_6 = StyledM.my_neg_1_6;
        pub const my_5_6 = StyledM.my_5_6;
        pub const my_neg_5_6 = StyledM.my_neg_5_6;
        pub const my_1_12 = StyledM.my_1_12;
        pub const my_neg_1_12 = StyledM.my_neg_1_12;
        pub const mx = StyledM.mx;
        pub const mx_0 = StyledM.mx_0;
        pub const mx_neg_0 = StyledM.mx_neg_0;
        pub const mx_0p5 = StyledM.mx_0p5;
        pub const mx_neg_0p5 = StyledM.mx_neg_0p5;
        pub const mx_1 = StyledM.mx_1;
        pub const mx_neg_1 = StyledM.mx_neg_1;
        pub const mx_1p5 = StyledM.mx_1p5;
        pub const mx_neg_1p5 = StyledM.mx_neg_1p5;
        pub const mx_2 = StyledM.mx_2;
        pub const mx_neg_2 = StyledM.mx_neg_2;
        pub const mx_2p5 = StyledM.mx_2p5;
        pub const mx_neg_2p5 = StyledM.mx_neg_2p5;
        pub const mx_3 = StyledM.mx_3;
        pub const mx_neg_3 = StyledM.mx_neg_3;
        pub const mx_3p5 = StyledM.mx_3p5;
        pub const mx_neg_3p5 = StyledM.mx_neg_3p5;
        pub const mx_4 = StyledM.mx_4;
        pub const mx_neg_4 = StyledM.mx_neg_4;
        pub const mx_5 = StyledM.mx_5;
        pub const mx_neg_5 = StyledM.mx_neg_5;
        pub const mx_6 = StyledM.mx_6;
        pub const mx_neg_6 = StyledM.mx_neg_6;
        pub const mx_7 = StyledM.mx_7;
        pub const mx_neg_7 = StyledM.mx_neg_7;
        pub const mx_8 = StyledM.mx_8;
        pub const mx_neg_8 = StyledM.mx_neg_8;
        pub const mx_9 = StyledM.mx_9;
        pub const mx_neg_9 = StyledM.mx_neg_9;
        pub const mx_10 = StyledM.mx_10;
        pub const mx_neg_10 = StyledM.mx_neg_10;
        pub const mx_11 = StyledM.mx_11;
        pub const mx_neg_11 = StyledM.mx_neg_11;
        pub const mx_12 = StyledM.mx_12;
        pub const mx_neg_12 = StyledM.mx_neg_12;
        pub const mx_16 = StyledM.mx_16;
        pub const mx_neg_16 = StyledM.mx_neg_16;
        pub const mx_20 = StyledM.mx_20;
        pub const mx_neg_20 = StyledM.mx_neg_20;
        pub const mx_24 = StyledM.mx_24;
        pub const mx_neg_24 = StyledM.mx_neg_24;
        pub const mx_32 = StyledM.mx_32;
        pub const mx_neg_32 = StyledM.mx_neg_32;
        pub const mx_40 = StyledM.mx_40;
        pub const mx_neg_40 = StyledM.mx_neg_40;
        pub const mx_48 = StyledM.mx_48;
        pub const mx_neg_48 = StyledM.mx_neg_48;
        pub const mx_56 = StyledM.mx_56;
        pub const mx_neg_56 = StyledM.mx_neg_56;
        pub const mx_64 = StyledM.mx_64;
        pub const mx_neg_64 = StyledM.mx_neg_64;
        pub const mx_72 = StyledM.mx_72;
        pub const mx_neg_72 = StyledM.mx_neg_72;
        pub const mx_80 = StyledM.mx_80;
        pub const mx_neg_80 = StyledM.mx_neg_80;
        pub const mx_96 = StyledM.mx_96;
        pub const mx_neg_96 = StyledM.mx_neg_96;
        pub const mx_112 = StyledM.mx_112;
        pub const mx_neg_112 = StyledM.mx_neg_112;
        pub const mx_128 = StyledM.mx_128;
        pub const mx_neg_128 = StyledM.mx_neg_128;
        pub const mx_auto = StyledM.mx_auto;
        pub const mx_px = StyledM.mx_px;
        pub const mx_neg_px = StyledM.mx_neg_px;
        pub const mx_full = StyledM.mx_full;
        pub const mx_neg_full = StyledM.mx_neg_full;
        pub const mx_1_2 = StyledM.mx_1_2;
        pub const mx_neg_1_2 = StyledM.mx_neg_1_2;
        pub const mx_1_3 = StyledM.mx_1_3;
        pub const mx_neg_1_3 = StyledM.mx_neg_1_3;
        pub const mx_2_3 = StyledM.mx_2_3;
        pub const mx_neg_2_3 = StyledM.mx_neg_2_3;
        pub const mx_1_4 = StyledM.mx_1_4;
        pub const mx_neg_1_4 = StyledM.mx_neg_1_4;
        pub const mx_2_4 = StyledM.mx_2_4;
        pub const mx_neg_2_4 = StyledM.mx_neg_2_4;
        pub const mx_3_4 = StyledM.mx_3_4;
        pub const mx_neg_3_4 = StyledM.mx_neg_3_4;
        pub const mx_1_5 = StyledM.mx_1_5;
        pub const mx_neg_1_5 = StyledM.mx_neg_1_5;
        pub const mx_2_5 = StyledM.mx_2_5;
        pub const mx_neg_2_5 = StyledM.mx_neg_2_5;
        pub const mx_3_5 = StyledM.mx_3_5;
        pub const mx_neg_3_5 = StyledM.mx_neg_3_5;
        pub const mx_4_5 = StyledM.mx_4_5;
        pub const mx_neg_4_5 = StyledM.mx_neg_4_5;
        pub const mx_1_6 = StyledM.mx_1_6;
        pub const mx_neg_1_6 = StyledM.mx_neg_1_6;
        pub const mx_5_6 = StyledM.mx_5_6;
        pub const mx_neg_5_6 = StyledM.mx_neg_5_6;
        pub const mx_1_12 = StyledM.mx_1_12;
        pub const mx_neg_1_12 = StyledM.mx_neg_1_12;
        pub const ml = StyledM.ml;
        pub const ml_0 = StyledM.ml_0;
        pub const ml_neg_0 = StyledM.ml_neg_0;
        pub const ml_0p5 = StyledM.ml_0p5;
        pub const ml_neg_0p5 = StyledM.ml_neg_0p5;
        pub const ml_1 = StyledM.ml_1;
        pub const ml_neg_1 = StyledM.ml_neg_1;
        pub const ml_1p5 = StyledM.ml_1p5;
        pub const ml_neg_1p5 = StyledM.ml_neg_1p5;
        pub const ml_2 = StyledM.ml_2;
        pub const ml_neg_2 = StyledM.ml_neg_2;
        pub const ml_2p5 = StyledM.ml_2p5;
        pub const ml_neg_2p5 = StyledM.ml_neg_2p5;
        pub const ml_3 = StyledM.ml_3;
        pub const ml_neg_3 = StyledM.ml_neg_3;
        pub const ml_3p5 = StyledM.ml_3p5;
        pub const ml_neg_3p5 = StyledM.ml_neg_3p5;
        pub const ml_4 = StyledM.ml_4;
        pub const ml_neg_4 = StyledM.ml_neg_4;
        pub const ml_5 = StyledM.ml_5;
        pub const ml_neg_5 = StyledM.ml_neg_5;
        pub const ml_6 = StyledM.ml_6;
        pub const ml_neg_6 = StyledM.ml_neg_6;
        pub const ml_7 = StyledM.ml_7;
        pub const ml_neg_7 = StyledM.ml_neg_7;
        pub const ml_8 = StyledM.ml_8;
        pub const ml_neg_8 = StyledM.ml_neg_8;
        pub const ml_9 = StyledM.ml_9;
        pub const ml_neg_9 = StyledM.ml_neg_9;
        pub const ml_10 = StyledM.ml_10;
        pub const ml_neg_10 = StyledM.ml_neg_10;
        pub const ml_11 = StyledM.ml_11;
        pub const ml_neg_11 = StyledM.ml_neg_11;
        pub const ml_12 = StyledM.ml_12;
        pub const ml_neg_12 = StyledM.ml_neg_12;
        pub const ml_16 = StyledM.ml_16;
        pub const ml_neg_16 = StyledM.ml_neg_16;
        pub const ml_20 = StyledM.ml_20;
        pub const ml_neg_20 = StyledM.ml_neg_20;
        pub const ml_24 = StyledM.ml_24;
        pub const ml_neg_24 = StyledM.ml_neg_24;
        pub const ml_32 = StyledM.ml_32;
        pub const ml_neg_32 = StyledM.ml_neg_32;
        pub const ml_40 = StyledM.ml_40;
        pub const ml_neg_40 = StyledM.ml_neg_40;
        pub const ml_48 = StyledM.ml_48;
        pub const ml_neg_48 = StyledM.ml_neg_48;
        pub const ml_56 = StyledM.ml_56;
        pub const ml_neg_56 = StyledM.ml_neg_56;
        pub const ml_64 = StyledM.ml_64;
        pub const ml_neg_64 = StyledM.ml_neg_64;
        pub const ml_72 = StyledM.ml_72;
        pub const ml_neg_72 = StyledM.ml_neg_72;
        pub const ml_80 = StyledM.ml_80;
        pub const ml_neg_80 = StyledM.ml_neg_80;
        pub const ml_96 = StyledM.ml_96;
        pub const ml_neg_96 = StyledM.ml_neg_96;
        pub const ml_112 = StyledM.ml_112;
        pub const ml_neg_112 = StyledM.ml_neg_112;
        pub const ml_128 = StyledM.ml_128;
        pub const ml_neg_128 = StyledM.ml_neg_128;
        pub const ml_auto = StyledM.ml_auto;
        pub const ml_px = StyledM.ml_px;
        pub const ml_neg_px = StyledM.ml_neg_px;
        pub const ml_full = StyledM.ml_full;
        pub const ml_neg_full = StyledM.ml_neg_full;
        pub const ml_1_2 = StyledM.ml_1_2;
        pub const ml_neg_1_2 = StyledM.ml_neg_1_2;
        pub const ml_1_3 = StyledM.ml_1_3;
        pub const ml_neg_1_3 = StyledM.ml_neg_1_3;
        pub const ml_2_3 = StyledM.ml_2_3;
        pub const ml_neg_2_3 = StyledM.ml_neg_2_3;
        pub const ml_1_4 = StyledM.ml_1_4;
        pub const ml_neg_1_4 = StyledM.ml_neg_1_4;
        pub const ml_2_4 = StyledM.ml_2_4;
        pub const ml_neg_2_4 = StyledM.ml_neg_2_4;
        pub const ml_3_4 = StyledM.ml_3_4;
        pub const ml_neg_3_4 = StyledM.ml_neg_3_4;
        pub const ml_1_5 = StyledM.ml_1_5;
        pub const ml_neg_1_5 = StyledM.ml_neg_1_5;
        pub const ml_2_5 = StyledM.ml_2_5;
        pub const ml_neg_2_5 = StyledM.ml_neg_2_5;
        pub const ml_3_5 = StyledM.ml_3_5;
        pub const ml_neg_3_5 = StyledM.ml_neg_3_5;
        pub const ml_4_5 = StyledM.ml_4_5;
        pub const ml_neg_4_5 = StyledM.ml_neg_4_5;
        pub const ml_1_6 = StyledM.ml_1_6;
        pub const ml_neg_1_6 = StyledM.ml_neg_1_6;
        pub const ml_5_6 = StyledM.ml_5_6;
        pub const ml_neg_5_6 = StyledM.ml_neg_5_6;
        pub const ml_1_12 = StyledM.ml_1_12;
        pub const ml_neg_1_12 = StyledM.ml_neg_1_12;
        pub const mr = StyledM.mr;
        pub const mr_0 = StyledM.mr_0;
        pub const mr_neg_0 = StyledM.mr_neg_0;
        pub const mr_0p5 = StyledM.mr_0p5;
        pub const mr_neg_0p5 = StyledM.mr_neg_0p5;
        pub const mr_1 = StyledM.mr_1;
        pub const mr_neg_1 = StyledM.mr_neg_1;
        pub const mr_1p5 = StyledM.mr_1p5;
        pub const mr_neg_1p5 = StyledM.mr_neg_1p5;
        pub const mr_2 = StyledM.mr_2;
        pub const mr_neg_2 = StyledM.mr_neg_2;
        pub const mr_2p5 = StyledM.mr_2p5;
        pub const mr_neg_2p5 = StyledM.mr_neg_2p5;
        pub const mr_3 = StyledM.mr_3;
        pub const mr_neg_3 = StyledM.mr_neg_3;
        pub const mr_3p5 = StyledM.mr_3p5;
        pub const mr_neg_3p5 = StyledM.mr_neg_3p5;
        pub const mr_4 = StyledM.mr_4;
        pub const mr_neg_4 = StyledM.mr_neg_4;
        pub const mr_5 = StyledM.mr_5;
        pub const mr_neg_5 = StyledM.mr_neg_5;
        pub const mr_6 = StyledM.mr_6;
        pub const mr_neg_6 = StyledM.mr_neg_6;
        pub const mr_7 = StyledM.mr_7;
        pub const mr_neg_7 = StyledM.mr_neg_7;
        pub const mr_8 = StyledM.mr_8;
        pub const mr_neg_8 = StyledM.mr_neg_8;
        pub const mr_9 = StyledM.mr_9;
        pub const mr_neg_9 = StyledM.mr_neg_9;
        pub const mr_10 = StyledM.mr_10;
        pub const mr_neg_10 = StyledM.mr_neg_10;
        pub const mr_11 = StyledM.mr_11;
        pub const mr_neg_11 = StyledM.mr_neg_11;
        pub const mr_12 = StyledM.mr_12;
        pub const mr_neg_12 = StyledM.mr_neg_12;
        pub const mr_16 = StyledM.mr_16;
        pub const mr_neg_16 = StyledM.mr_neg_16;
        pub const mr_20 = StyledM.mr_20;
        pub const mr_neg_20 = StyledM.mr_neg_20;
        pub const mr_24 = StyledM.mr_24;
        pub const mr_neg_24 = StyledM.mr_neg_24;
        pub const mr_32 = StyledM.mr_32;
        pub const mr_neg_32 = StyledM.mr_neg_32;
        pub const mr_40 = StyledM.mr_40;
        pub const mr_neg_40 = StyledM.mr_neg_40;
        pub const mr_48 = StyledM.mr_48;
        pub const mr_neg_48 = StyledM.mr_neg_48;
        pub const mr_56 = StyledM.mr_56;
        pub const mr_neg_56 = StyledM.mr_neg_56;
        pub const mr_64 = StyledM.mr_64;
        pub const mr_neg_64 = StyledM.mr_neg_64;
        pub const mr_72 = StyledM.mr_72;
        pub const mr_neg_72 = StyledM.mr_neg_72;
        pub const mr_80 = StyledM.mr_80;
        pub const mr_neg_80 = StyledM.mr_neg_80;
        pub const mr_96 = StyledM.mr_96;
        pub const mr_neg_96 = StyledM.mr_neg_96;
        pub const mr_112 = StyledM.mr_112;
        pub const mr_neg_112 = StyledM.mr_neg_112;
        pub const mr_128 = StyledM.mr_128;
        pub const mr_neg_128 = StyledM.mr_neg_128;
        pub const mr_auto = StyledM.mr_auto;
        pub const mr_px = StyledM.mr_px;
        pub const mr_neg_px = StyledM.mr_neg_px;
        pub const mr_full = StyledM.mr_full;
        pub const mr_neg_full = StyledM.mr_neg_full;
        pub const mr_1_2 = StyledM.mr_1_2;
        pub const mr_neg_1_2 = StyledM.mr_neg_1_2;
        pub const mr_1_3 = StyledM.mr_1_3;
        pub const mr_neg_1_3 = StyledM.mr_neg_1_3;
        pub const mr_2_3 = StyledM.mr_2_3;
        pub const mr_neg_2_3 = StyledM.mr_neg_2_3;
        pub const mr_1_4 = StyledM.mr_1_4;
        pub const mr_neg_1_4 = StyledM.mr_neg_1_4;
        pub const mr_2_4 = StyledM.mr_2_4;
        pub const mr_neg_2_4 = StyledM.mr_neg_2_4;
        pub const mr_3_4 = StyledM.mr_3_4;
        pub const mr_neg_3_4 = StyledM.mr_neg_3_4;
        pub const mr_1_5 = StyledM.mr_1_5;
        pub const mr_neg_1_5 = StyledM.mr_neg_1_5;
        pub const mr_2_5 = StyledM.mr_2_5;
        pub const mr_neg_2_5 = StyledM.mr_neg_2_5;
        pub const mr_3_5 = StyledM.mr_3_5;
        pub const mr_neg_3_5 = StyledM.mr_neg_3_5;
        pub const mr_4_5 = StyledM.mr_4_5;
        pub const mr_neg_4_5 = StyledM.mr_neg_4_5;
        pub const mr_1_6 = StyledM.mr_1_6;
        pub const mr_neg_1_6 = StyledM.mr_neg_1_6;
        pub const mr_5_6 = StyledM.mr_5_6;
        pub const mr_neg_5_6 = StyledM.mr_neg_5_6;
        pub const mr_1_12 = StyledM.mr_1_12;
        pub const mr_neg_1_12 = StyledM.mr_neg_1_12;
        pub const p = StyledM.p;
        pub const p_0 = StyledM.p_0;
        pub const p_neg_0 = StyledM.p_neg_0;
        pub const p_0p5 = StyledM.p_0p5;
        pub const p_neg_0p5 = StyledM.p_neg_0p5;
        pub const p_1 = StyledM.p_1;
        pub const p_neg_1 = StyledM.p_neg_1;
        pub const p_1p5 = StyledM.p_1p5;
        pub const p_neg_1p5 = StyledM.p_neg_1p5;
        pub const p_2 = StyledM.p_2;
        pub const p_neg_2 = StyledM.p_neg_2;
        pub const p_2p5 = StyledM.p_2p5;
        pub const p_neg_2p5 = StyledM.p_neg_2p5;
        pub const p_3 = StyledM.p_3;
        pub const p_neg_3 = StyledM.p_neg_3;
        pub const p_3p5 = StyledM.p_3p5;
        pub const p_neg_3p5 = StyledM.p_neg_3p5;
        pub const p_4 = StyledM.p_4;
        pub const p_neg_4 = StyledM.p_neg_4;
        pub const p_5 = StyledM.p_5;
        pub const p_neg_5 = StyledM.p_neg_5;
        pub const p_6 = StyledM.p_6;
        pub const p_neg_6 = StyledM.p_neg_6;
        pub const p_7 = StyledM.p_7;
        pub const p_neg_7 = StyledM.p_neg_7;
        pub const p_8 = StyledM.p_8;
        pub const p_neg_8 = StyledM.p_neg_8;
        pub const p_9 = StyledM.p_9;
        pub const p_neg_9 = StyledM.p_neg_9;
        pub const p_10 = StyledM.p_10;
        pub const p_neg_10 = StyledM.p_neg_10;
        pub const p_11 = StyledM.p_11;
        pub const p_neg_11 = StyledM.p_neg_11;
        pub const p_12 = StyledM.p_12;
        pub const p_neg_12 = StyledM.p_neg_12;
        pub const p_16 = StyledM.p_16;
        pub const p_neg_16 = StyledM.p_neg_16;
        pub const p_20 = StyledM.p_20;
        pub const p_neg_20 = StyledM.p_neg_20;
        pub const p_24 = StyledM.p_24;
        pub const p_neg_24 = StyledM.p_neg_24;
        pub const p_32 = StyledM.p_32;
        pub const p_neg_32 = StyledM.p_neg_32;
        pub const p_40 = StyledM.p_40;
        pub const p_neg_40 = StyledM.p_neg_40;
        pub const p_48 = StyledM.p_48;
        pub const p_neg_48 = StyledM.p_neg_48;
        pub const p_56 = StyledM.p_56;
        pub const p_neg_56 = StyledM.p_neg_56;
        pub const p_64 = StyledM.p_64;
        pub const p_neg_64 = StyledM.p_neg_64;
        pub const p_72 = StyledM.p_72;
        pub const p_neg_72 = StyledM.p_neg_72;
        pub const p_80 = StyledM.p_80;
        pub const p_neg_80 = StyledM.p_neg_80;
        pub const p_96 = StyledM.p_96;
        pub const p_neg_96 = StyledM.p_neg_96;
        pub const p_112 = StyledM.p_112;
        pub const p_neg_112 = StyledM.p_neg_112;
        pub const p_128 = StyledM.p_128;
        pub const p_neg_128 = StyledM.p_neg_128;
        pub const p_px = StyledM.p_px;
        pub const p_neg_px = StyledM.p_neg_px;
        pub const p_full = StyledM.p_full;
        pub const p_neg_full = StyledM.p_neg_full;
        pub const p_1_2 = StyledM.p_1_2;
        pub const p_neg_1_2 = StyledM.p_neg_1_2;
        pub const p_1_3 = StyledM.p_1_3;
        pub const p_neg_1_3 = StyledM.p_neg_1_3;
        pub const p_2_3 = StyledM.p_2_3;
        pub const p_neg_2_3 = StyledM.p_neg_2_3;
        pub const p_1_4 = StyledM.p_1_4;
        pub const p_neg_1_4 = StyledM.p_neg_1_4;
        pub const p_2_4 = StyledM.p_2_4;
        pub const p_neg_2_4 = StyledM.p_neg_2_4;
        pub const p_3_4 = StyledM.p_3_4;
        pub const p_neg_3_4 = StyledM.p_neg_3_4;
        pub const p_1_5 = StyledM.p_1_5;
        pub const p_neg_1_5 = StyledM.p_neg_1_5;
        pub const p_2_5 = StyledM.p_2_5;
        pub const p_neg_2_5 = StyledM.p_neg_2_5;
        pub const p_3_5 = StyledM.p_3_5;
        pub const p_neg_3_5 = StyledM.p_neg_3_5;
        pub const p_4_5 = StyledM.p_4_5;
        pub const p_neg_4_5 = StyledM.p_neg_4_5;
        pub const p_1_6 = StyledM.p_1_6;
        pub const p_neg_1_6 = StyledM.p_neg_1_6;
        pub const p_5_6 = StyledM.p_5_6;
        pub const p_neg_5_6 = StyledM.p_neg_5_6;
        pub const p_1_12 = StyledM.p_1_12;
        pub const p_neg_1_12 = StyledM.p_neg_1_12;
        pub const pt = StyledM.pt;
        pub const pt_0 = StyledM.pt_0;
        pub const pt_neg_0 = StyledM.pt_neg_0;
        pub const pt_0p5 = StyledM.pt_0p5;
        pub const pt_neg_0p5 = StyledM.pt_neg_0p5;
        pub const pt_1 = StyledM.pt_1;
        pub const pt_neg_1 = StyledM.pt_neg_1;
        pub const pt_1p5 = StyledM.pt_1p5;
        pub const pt_neg_1p5 = StyledM.pt_neg_1p5;
        pub const pt_2 = StyledM.pt_2;
        pub const pt_neg_2 = StyledM.pt_neg_2;
        pub const pt_2p5 = StyledM.pt_2p5;
        pub const pt_neg_2p5 = StyledM.pt_neg_2p5;
        pub const pt_3 = StyledM.pt_3;
        pub const pt_neg_3 = StyledM.pt_neg_3;
        pub const pt_3p5 = StyledM.pt_3p5;
        pub const pt_neg_3p5 = StyledM.pt_neg_3p5;
        pub const pt_4 = StyledM.pt_4;
        pub const pt_neg_4 = StyledM.pt_neg_4;
        pub const pt_5 = StyledM.pt_5;
        pub const pt_neg_5 = StyledM.pt_neg_5;
        pub const pt_6 = StyledM.pt_6;
        pub const pt_neg_6 = StyledM.pt_neg_6;
        pub const pt_7 = StyledM.pt_7;
        pub const pt_neg_7 = StyledM.pt_neg_7;
        pub const pt_8 = StyledM.pt_8;
        pub const pt_neg_8 = StyledM.pt_neg_8;
        pub const pt_9 = StyledM.pt_9;
        pub const pt_neg_9 = StyledM.pt_neg_9;
        pub const pt_10 = StyledM.pt_10;
        pub const pt_neg_10 = StyledM.pt_neg_10;
        pub const pt_11 = StyledM.pt_11;
        pub const pt_neg_11 = StyledM.pt_neg_11;
        pub const pt_12 = StyledM.pt_12;
        pub const pt_neg_12 = StyledM.pt_neg_12;
        pub const pt_16 = StyledM.pt_16;
        pub const pt_neg_16 = StyledM.pt_neg_16;
        pub const pt_20 = StyledM.pt_20;
        pub const pt_neg_20 = StyledM.pt_neg_20;
        pub const pt_24 = StyledM.pt_24;
        pub const pt_neg_24 = StyledM.pt_neg_24;
        pub const pt_32 = StyledM.pt_32;
        pub const pt_neg_32 = StyledM.pt_neg_32;
        pub const pt_40 = StyledM.pt_40;
        pub const pt_neg_40 = StyledM.pt_neg_40;
        pub const pt_48 = StyledM.pt_48;
        pub const pt_neg_48 = StyledM.pt_neg_48;
        pub const pt_56 = StyledM.pt_56;
        pub const pt_neg_56 = StyledM.pt_neg_56;
        pub const pt_64 = StyledM.pt_64;
        pub const pt_neg_64 = StyledM.pt_neg_64;
        pub const pt_72 = StyledM.pt_72;
        pub const pt_neg_72 = StyledM.pt_neg_72;
        pub const pt_80 = StyledM.pt_80;
        pub const pt_neg_80 = StyledM.pt_neg_80;
        pub const pt_96 = StyledM.pt_96;
        pub const pt_neg_96 = StyledM.pt_neg_96;
        pub const pt_112 = StyledM.pt_112;
        pub const pt_neg_112 = StyledM.pt_neg_112;
        pub const pt_128 = StyledM.pt_128;
        pub const pt_neg_128 = StyledM.pt_neg_128;
        pub const pt_px = StyledM.pt_px;
        pub const pt_neg_px = StyledM.pt_neg_px;
        pub const pt_full = StyledM.pt_full;
        pub const pt_neg_full = StyledM.pt_neg_full;
        pub const pt_1_2 = StyledM.pt_1_2;
        pub const pt_neg_1_2 = StyledM.pt_neg_1_2;
        pub const pt_1_3 = StyledM.pt_1_3;
        pub const pt_neg_1_3 = StyledM.pt_neg_1_3;
        pub const pt_2_3 = StyledM.pt_2_3;
        pub const pt_neg_2_3 = StyledM.pt_neg_2_3;
        pub const pt_1_4 = StyledM.pt_1_4;
        pub const pt_neg_1_4 = StyledM.pt_neg_1_4;
        pub const pt_2_4 = StyledM.pt_2_4;
        pub const pt_neg_2_4 = StyledM.pt_neg_2_4;
        pub const pt_3_4 = StyledM.pt_3_4;
        pub const pt_neg_3_4 = StyledM.pt_neg_3_4;
        pub const pt_1_5 = StyledM.pt_1_5;
        pub const pt_neg_1_5 = StyledM.pt_neg_1_5;
        pub const pt_2_5 = StyledM.pt_2_5;
        pub const pt_neg_2_5 = StyledM.pt_neg_2_5;
        pub const pt_3_5 = StyledM.pt_3_5;
        pub const pt_neg_3_5 = StyledM.pt_neg_3_5;
        pub const pt_4_5 = StyledM.pt_4_5;
        pub const pt_neg_4_5 = StyledM.pt_neg_4_5;
        pub const pt_1_6 = StyledM.pt_1_6;
        pub const pt_neg_1_6 = StyledM.pt_neg_1_6;
        pub const pt_5_6 = StyledM.pt_5_6;
        pub const pt_neg_5_6 = StyledM.pt_neg_5_6;
        pub const pt_1_12 = StyledM.pt_1_12;
        pub const pt_neg_1_12 = StyledM.pt_neg_1_12;
        pub const pb = StyledM.pb;
        pub const pb_0 = StyledM.pb_0;
        pub const pb_neg_0 = StyledM.pb_neg_0;
        pub const pb_0p5 = StyledM.pb_0p5;
        pub const pb_neg_0p5 = StyledM.pb_neg_0p5;
        pub const pb_1 = StyledM.pb_1;
        pub const pb_neg_1 = StyledM.pb_neg_1;
        pub const pb_1p5 = StyledM.pb_1p5;
        pub const pb_neg_1p5 = StyledM.pb_neg_1p5;
        pub const pb_2 = StyledM.pb_2;
        pub const pb_neg_2 = StyledM.pb_neg_2;
        pub const pb_2p5 = StyledM.pb_2p5;
        pub const pb_neg_2p5 = StyledM.pb_neg_2p5;
        pub const pb_3 = StyledM.pb_3;
        pub const pb_neg_3 = StyledM.pb_neg_3;
        pub const pb_3p5 = StyledM.pb_3p5;
        pub const pb_neg_3p5 = StyledM.pb_neg_3p5;
        pub const pb_4 = StyledM.pb_4;
        pub const pb_neg_4 = StyledM.pb_neg_4;
        pub const pb_5 = StyledM.pb_5;
        pub const pb_neg_5 = StyledM.pb_neg_5;
        pub const pb_6 = StyledM.pb_6;
        pub const pb_neg_6 = StyledM.pb_neg_6;
        pub const pb_7 = StyledM.pb_7;
        pub const pb_neg_7 = StyledM.pb_neg_7;
        pub const pb_8 = StyledM.pb_8;
        pub const pb_neg_8 = StyledM.pb_neg_8;
        pub const pb_9 = StyledM.pb_9;
        pub const pb_neg_9 = StyledM.pb_neg_9;
        pub const pb_10 = StyledM.pb_10;
        pub const pb_neg_10 = StyledM.pb_neg_10;
        pub const pb_11 = StyledM.pb_11;
        pub const pb_neg_11 = StyledM.pb_neg_11;
        pub const pb_12 = StyledM.pb_12;
        pub const pb_neg_12 = StyledM.pb_neg_12;
        pub const pb_16 = StyledM.pb_16;
        pub const pb_neg_16 = StyledM.pb_neg_16;
        pub const pb_20 = StyledM.pb_20;
        pub const pb_neg_20 = StyledM.pb_neg_20;
        pub const pb_24 = StyledM.pb_24;
        pub const pb_neg_24 = StyledM.pb_neg_24;
        pub const pb_32 = StyledM.pb_32;
        pub const pb_neg_32 = StyledM.pb_neg_32;
        pub const pb_40 = StyledM.pb_40;
        pub const pb_neg_40 = StyledM.pb_neg_40;
        pub const pb_48 = StyledM.pb_48;
        pub const pb_neg_48 = StyledM.pb_neg_48;
        pub const pb_56 = StyledM.pb_56;
        pub const pb_neg_56 = StyledM.pb_neg_56;
        pub const pb_64 = StyledM.pb_64;
        pub const pb_neg_64 = StyledM.pb_neg_64;
        pub const pb_72 = StyledM.pb_72;
        pub const pb_neg_72 = StyledM.pb_neg_72;
        pub const pb_80 = StyledM.pb_80;
        pub const pb_neg_80 = StyledM.pb_neg_80;
        pub const pb_96 = StyledM.pb_96;
        pub const pb_neg_96 = StyledM.pb_neg_96;
        pub const pb_112 = StyledM.pb_112;
        pub const pb_neg_112 = StyledM.pb_neg_112;
        pub const pb_128 = StyledM.pb_128;
        pub const pb_neg_128 = StyledM.pb_neg_128;
        pub const pb_px = StyledM.pb_px;
        pub const pb_neg_px = StyledM.pb_neg_px;
        pub const pb_full = StyledM.pb_full;
        pub const pb_neg_full = StyledM.pb_neg_full;
        pub const pb_1_2 = StyledM.pb_1_2;
        pub const pb_neg_1_2 = StyledM.pb_neg_1_2;
        pub const pb_1_3 = StyledM.pb_1_3;
        pub const pb_neg_1_3 = StyledM.pb_neg_1_3;
        pub const pb_2_3 = StyledM.pb_2_3;
        pub const pb_neg_2_3 = StyledM.pb_neg_2_3;
        pub const pb_1_4 = StyledM.pb_1_4;
        pub const pb_neg_1_4 = StyledM.pb_neg_1_4;
        pub const pb_2_4 = StyledM.pb_2_4;
        pub const pb_neg_2_4 = StyledM.pb_neg_2_4;
        pub const pb_3_4 = StyledM.pb_3_4;
        pub const pb_neg_3_4 = StyledM.pb_neg_3_4;
        pub const pb_1_5 = StyledM.pb_1_5;
        pub const pb_neg_1_5 = StyledM.pb_neg_1_5;
        pub const pb_2_5 = StyledM.pb_2_5;
        pub const pb_neg_2_5 = StyledM.pb_neg_2_5;
        pub const pb_3_5 = StyledM.pb_3_5;
        pub const pb_neg_3_5 = StyledM.pb_neg_3_5;
        pub const pb_4_5 = StyledM.pb_4_5;
        pub const pb_neg_4_5 = StyledM.pb_neg_4_5;
        pub const pb_1_6 = StyledM.pb_1_6;
        pub const pb_neg_1_6 = StyledM.pb_neg_1_6;
        pub const pb_5_6 = StyledM.pb_5_6;
        pub const pb_neg_5_6 = StyledM.pb_neg_5_6;
        pub const pb_1_12 = StyledM.pb_1_12;
        pub const pb_neg_1_12 = StyledM.pb_neg_1_12;
        pub const px = StyledM.px;
        pub const px_0 = StyledM.px_0;
        pub const px_neg_0 = StyledM.px_neg_0;
        pub const px_0p5 = StyledM.px_0p5;
        pub const px_neg_0p5 = StyledM.px_neg_0p5;
        pub const px_1 = StyledM.px_1;
        pub const px_neg_1 = StyledM.px_neg_1;
        pub const px_1p5 = StyledM.px_1p5;
        pub const px_neg_1p5 = StyledM.px_neg_1p5;
        pub const px_2 = StyledM.px_2;
        pub const px_neg_2 = StyledM.px_neg_2;
        pub const px_2p5 = StyledM.px_2p5;
        pub const px_neg_2p5 = StyledM.px_neg_2p5;
        pub const px_3 = StyledM.px_3;
        pub const px_neg_3 = StyledM.px_neg_3;
        pub const px_3p5 = StyledM.px_3p5;
        pub const px_neg_3p5 = StyledM.px_neg_3p5;
        pub const px_4 = StyledM.px_4;
        pub const px_neg_4 = StyledM.px_neg_4;
        pub const px_5 = StyledM.px_5;
        pub const px_neg_5 = StyledM.px_neg_5;
        pub const px_6 = StyledM.px_6;
        pub const px_neg_6 = StyledM.px_neg_6;
        pub const px_7 = StyledM.px_7;
        pub const px_neg_7 = StyledM.px_neg_7;
        pub const px_8 = StyledM.px_8;
        pub const px_neg_8 = StyledM.px_neg_8;
        pub const px_9 = StyledM.px_9;
        pub const px_neg_9 = StyledM.px_neg_9;
        pub const px_10 = StyledM.px_10;
        pub const px_neg_10 = StyledM.px_neg_10;
        pub const px_11 = StyledM.px_11;
        pub const px_neg_11 = StyledM.px_neg_11;
        pub const px_12 = StyledM.px_12;
        pub const px_neg_12 = StyledM.px_neg_12;
        pub const px_16 = StyledM.px_16;
        pub const px_neg_16 = StyledM.px_neg_16;
        pub const px_20 = StyledM.px_20;
        pub const px_neg_20 = StyledM.px_neg_20;
        pub const px_24 = StyledM.px_24;
        pub const px_neg_24 = StyledM.px_neg_24;
        pub const px_32 = StyledM.px_32;
        pub const px_neg_32 = StyledM.px_neg_32;
        pub const px_40 = StyledM.px_40;
        pub const px_neg_40 = StyledM.px_neg_40;
        pub const px_48 = StyledM.px_48;
        pub const px_neg_48 = StyledM.px_neg_48;
        pub const px_56 = StyledM.px_56;
        pub const px_neg_56 = StyledM.px_neg_56;
        pub const px_64 = StyledM.px_64;
        pub const px_neg_64 = StyledM.px_neg_64;
        pub const px_72 = StyledM.px_72;
        pub const px_neg_72 = StyledM.px_neg_72;
        pub const px_80 = StyledM.px_80;
        pub const px_neg_80 = StyledM.px_neg_80;
        pub const px_96 = StyledM.px_96;
        pub const px_neg_96 = StyledM.px_neg_96;
        pub const px_112 = StyledM.px_112;
        pub const px_neg_112 = StyledM.px_neg_112;
        pub const px_128 = StyledM.px_128;
        pub const px_neg_128 = StyledM.px_neg_128;
        pub const px_px = StyledM.px_px;
        pub const px_neg_px = StyledM.px_neg_px;
        pub const px_full = StyledM.px_full;
        pub const px_neg_full = StyledM.px_neg_full;
        pub const px_1_2 = StyledM.px_1_2;
        pub const px_neg_1_2 = StyledM.px_neg_1_2;
        pub const px_1_3 = StyledM.px_1_3;
        pub const px_neg_1_3 = StyledM.px_neg_1_3;
        pub const px_2_3 = StyledM.px_2_3;
        pub const px_neg_2_3 = StyledM.px_neg_2_3;
        pub const px_1_4 = StyledM.px_1_4;
        pub const px_neg_1_4 = StyledM.px_neg_1_4;
        pub const px_2_4 = StyledM.px_2_4;
        pub const px_neg_2_4 = StyledM.px_neg_2_4;
        pub const px_3_4 = StyledM.px_3_4;
        pub const px_neg_3_4 = StyledM.px_neg_3_4;
        pub const px_1_5 = StyledM.px_1_5;
        pub const px_neg_1_5 = StyledM.px_neg_1_5;
        pub const px_2_5 = StyledM.px_2_5;
        pub const px_neg_2_5 = StyledM.px_neg_2_5;
        pub const px_3_5 = StyledM.px_3_5;
        pub const px_neg_3_5 = StyledM.px_neg_3_5;
        pub const px_4_5 = StyledM.px_4_5;
        pub const px_neg_4_5 = StyledM.px_neg_4_5;
        pub const px_1_6 = StyledM.px_1_6;
        pub const px_neg_1_6 = StyledM.px_neg_1_6;
        pub const px_5_6 = StyledM.px_5_6;
        pub const px_neg_5_6 = StyledM.px_neg_5_6;
        pub const px_1_12 = StyledM.px_1_12;
        pub const px_neg_1_12 = StyledM.px_neg_1_12;
        pub const py = StyledM.py;
        pub const py_0 = StyledM.py_0;
        pub const py_neg_0 = StyledM.py_neg_0;
        pub const py_0p5 = StyledM.py_0p5;
        pub const py_neg_0p5 = StyledM.py_neg_0p5;
        pub const py_1 = StyledM.py_1;
        pub const py_neg_1 = StyledM.py_neg_1;
        pub const py_1p5 = StyledM.py_1p5;
        pub const py_neg_1p5 = StyledM.py_neg_1p5;
        pub const py_2 = StyledM.py_2;
        pub const py_neg_2 = StyledM.py_neg_2;
        pub const py_2p5 = StyledM.py_2p5;
        pub const py_neg_2p5 = StyledM.py_neg_2p5;
        pub const py_3 = StyledM.py_3;
        pub const py_neg_3 = StyledM.py_neg_3;
        pub const py_3p5 = StyledM.py_3p5;
        pub const py_neg_3p5 = StyledM.py_neg_3p5;
        pub const py_4 = StyledM.py_4;
        pub const py_neg_4 = StyledM.py_neg_4;
        pub const py_5 = StyledM.py_5;
        pub const py_neg_5 = StyledM.py_neg_5;
        pub const py_6 = StyledM.py_6;
        pub const py_neg_6 = StyledM.py_neg_6;
        pub const py_7 = StyledM.py_7;
        pub const py_neg_7 = StyledM.py_neg_7;
        pub const py_8 = StyledM.py_8;
        pub const py_neg_8 = StyledM.py_neg_8;
        pub const py_9 = StyledM.py_9;
        pub const py_neg_9 = StyledM.py_neg_9;
        pub const py_10 = StyledM.py_10;
        pub const py_neg_10 = StyledM.py_neg_10;
        pub const py_11 = StyledM.py_11;
        pub const py_neg_11 = StyledM.py_neg_11;
        pub const py_12 = StyledM.py_12;
        pub const py_neg_12 = StyledM.py_neg_12;
        pub const py_16 = StyledM.py_16;
        pub const py_neg_16 = StyledM.py_neg_16;
        pub const py_20 = StyledM.py_20;
        pub const py_neg_20 = StyledM.py_neg_20;
        pub const py_24 = StyledM.py_24;
        pub const py_neg_24 = StyledM.py_neg_24;
        pub const py_32 = StyledM.py_32;
        pub const py_neg_32 = StyledM.py_neg_32;
        pub const py_40 = StyledM.py_40;
        pub const py_neg_40 = StyledM.py_neg_40;
        pub const py_48 = StyledM.py_48;
        pub const py_neg_48 = StyledM.py_neg_48;
        pub const py_56 = StyledM.py_56;
        pub const py_neg_56 = StyledM.py_neg_56;
        pub const py_64 = StyledM.py_64;
        pub const py_neg_64 = StyledM.py_neg_64;
        pub const py_72 = StyledM.py_72;
        pub const py_neg_72 = StyledM.py_neg_72;
        pub const py_80 = StyledM.py_80;
        pub const py_neg_80 = StyledM.py_neg_80;
        pub const py_96 = StyledM.py_96;
        pub const py_neg_96 = StyledM.py_neg_96;
        pub const py_112 = StyledM.py_112;
        pub const py_neg_112 = StyledM.py_neg_112;
        pub const py_128 = StyledM.py_128;
        pub const py_neg_128 = StyledM.py_neg_128;
        pub const py_px = StyledM.py_px;
        pub const py_neg_px = StyledM.py_neg_px;
        pub const py_full = StyledM.py_full;
        pub const py_neg_full = StyledM.py_neg_full;
        pub const py_1_2 = StyledM.py_1_2;
        pub const py_neg_1_2 = StyledM.py_neg_1_2;
        pub const py_1_3 = StyledM.py_1_3;
        pub const py_neg_1_3 = StyledM.py_neg_1_3;
        pub const py_2_3 = StyledM.py_2_3;
        pub const py_neg_2_3 = StyledM.py_neg_2_3;
        pub const py_1_4 = StyledM.py_1_4;
        pub const py_neg_1_4 = StyledM.py_neg_1_4;
        pub const py_2_4 = StyledM.py_2_4;
        pub const py_neg_2_4 = StyledM.py_neg_2_4;
        pub const py_3_4 = StyledM.py_3_4;
        pub const py_neg_3_4 = StyledM.py_neg_3_4;
        pub const py_1_5 = StyledM.py_1_5;
        pub const py_neg_1_5 = StyledM.py_neg_1_5;
        pub const py_2_5 = StyledM.py_2_5;
        pub const py_neg_2_5 = StyledM.py_neg_2_5;
        pub const py_3_5 = StyledM.py_3_5;
        pub const py_neg_3_5 = StyledM.py_neg_3_5;
        pub const py_4_5 = StyledM.py_4_5;
        pub const py_neg_4_5 = StyledM.py_neg_4_5;
        pub const py_1_6 = StyledM.py_1_6;
        pub const py_neg_1_6 = StyledM.py_neg_1_6;
        pub const py_5_6 = StyledM.py_5_6;
        pub const py_neg_5_6 = StyledM.py_neg_5_6;
        pub const py_1_12 = StyledM.py_1_12;
        pub const py_neg_1_12 = StyledM.py_neg_1_12;
        pub const pl = StyledM.pl;
        pub const pl_0 = StyledM.pl_0;
        pub const pl_neg_0 = StyledM.pl_neg_0;
        pub const pl_0p5 = StyledM.pl_0p5;
        pub const pl_neg_0p5 = StyledM.pl_neg_0p5;
        pub const pl_1 = StyledM.pl_1;
        pub const pl_neg_1 = StyledM.pl_neg_1;
        pub const pl_1p5 = StyledM.pl_1p5;
        pub const pl_neg_1p5 = StyledM.pl_neg_1p5;
        pub const pl_2 = StyledM.pl_2;
        pub const pl_neg_2 = StyledM.pl_neg_2;
        pub const pl_2p5 = StyledM.pl_2p5;
        pub const pl_neg_2p5 = StyledM.pl_neg_2p5;
        pub const pl_3 = StyledM.pl_3;
        pub const pl_neg_3 = StyledM.pl_neg_3;
        pub const pl_3p5 = StyledM.pl_3p5;
        pub const pl_neg_3p5 = StyledM.pl_neg_3p5;
        pub const pl_4 = StyledM.pl_4;
        pub const pl_neg_4 = StyledM.pl_neg_4;
        pub const pl_5 = StyledM.pl_5;
        pub const pl_neg_5 = StyledM.pl_neg_5;
        pub const pl_6 = StyledM.pl_6;
        pub const pl_neg_6 = StyledM.pl_neg_6;
        pub const pl_7 = StyledM.pl_7;
        pub const pl_neg_7 = StyledM.pl_neg_7;
        pub const pl_8 = StyledM.pl_8;
        pub const pl_neg_8 = StyledM.pl_neg_8;
        pub const pl_9 = StyledM.pl_9;
        pub const pl_neg_9 = StyledM.pl_neg_9;
        pub const pl_10 = StyledM.pl_10;
        pub const pl_neg_10 = StyledM.pl_neg_10;
        pub const pl_11 = StyledM.pl_11;
        pub const pl_neg_11 = StyledM.pl_neg_11;
        pub const pl_12 = StyledM.pl_12;
        pub const pl_neg_12 = StyledM.pl_neg_12;
        pub const pl_16 = StyledM.pl_16;
        pub const pl_neg_16 = StyledM.pl_neg_16;
        pub const pl_20 = StyledM.pl_20;
        pub const pl_neg_20 = StyledM.pl_neg_20;
        pub const pl_24 = StyledM.pl_24;
        pub const pl_neg_24 = StyledM.pl_neg_24;
        pub const pl_32 = StyledM.pl_32;
        pub const pl_neg_32 = StyledM.pl_neg_32;
        pub const pl_40 = StyledM.pl_40;
        pub const pl_neg_40 = StyledM.pl_neg_40;
        pub const pl_48 = StyledM.pl_48;
        pub const pl_neg_48 = StyledM.pl_neg_48;
        pub const pl_56 = StyledM.pl_56;
        pub const pl_neg_56 = StyledM.pl_neg_56;
        pub const pl_64 = StyledM.pl_64;
        pub const pl_neg_64 = StyledM.pl_neg_64;
        pub const pl_72 = StyledM.pl_72;
        pub const pl_neg_72 = StyledM.pl_neg_72;
        pub const pl_80 = StyledM.pl_80;
        pub const pl_neg_80 = StyledM.pl_neg_80;
        pub const pl_96 = StyledM.pl_96;
        pub const pl_neg_96 = StyledM.pl_neg_96;
        pub const pl_112 = StyledM.pl_112;
        pub const pl_neg_112 = StyledM.pl_neg_112;
        pub const pl_128 = StyledM.pl_128;
        pub const pl_neg_128 = StyledM.pl_neg_128;
        pub const pl_px = StyledM.pl_px;
        pub const pl_neg_px = StyledM.pl_neg_px;
        pub const pl_full = StyledM.pl_full;
        pub const pl_neg_full = StyledM.pl_neg_full;
        pub const pl_1_2 = StyledM.pl_1_2;
        pub const pl_neg_1_2 = StyledM.pl_neg_1_2;
        pub const pl_1_3 = StyledM.pl_1_3;
        pub const pl_neg_1_3 = StyledM.pl_neg_1_3;
        pub const pl_2_3 = StyledM.pl_2_3;
        pub const pl_neg_2_3 = StyledM.pl_neg_2_3;
        pub const pl_1_4 = StyledM.pl_1_4;
        pub const pl_neg_1_4 = StyledM.pl_neg_1_4;
        pub const pl_2_4 = StyledM.pl_2_4;
        pub const pl_neg_2_4 = StyledM.pl_neg_2_4;
        pub const pl_3_4 = StyledM.pl_3_4;
        pub const pl_neg_3_4 = StyledM.pl_neg_3_4;
        pub const pl_1_5 = StyledM.pl_1_5;
        pub const pl_neg_1_5 = StyledM.pl_neg_1_5;
        pub const pl_2_5 = StyledM.pl_2_5;
        pub const pl_neg_2_5 = StyledM.pl_neg_2_5;
        pub const pl_3_5 = StyledM.pl_3_5;
        pub const pl_neg_3_5 = StyledM.pl_neg_3_5;
        pub const pl_4_5 = StyledM.pl_4_5;
        pub const pl_neg_4_5 = StyledM.pl_neg_4_5;
        pub const pl_1_6 = StyledM.pl_1_6;
        pub const pl_neg_1_6 = StyledM.pl_neg_1_6;
        pub const pl_5_6 = StyledM.pl_5_6;
        pub const pl_neg_5_6 = StyledM.pl_neg_5_6;
        pub const pl_1_12 = StyledM.pl_1_12;
        pub const pl_neg_1_12 = StyledM.pl_neg_1_12;
        pub const pr = StyledM.pr;
        pub const pr_0 = StyledM.pr_0;
        pub const pr_neg_0 = StyledM.pr_neg_0;
        pub const pr_0p5 = StyledM.pr_0p5;
        pub const pr_neg_0p5 = StyledM.pr_neg_0p5;
        pub const pr_1 = StyledM.pr_1;
        pub const pr_neg_1 = StyledM.pr_neg_1;
        pub const pr_1p5 = StyledM.pr_1p5;
        pub const pr_neg_1p5 = StyledM.pr_neg_1p5;
        pub const pr_2 = StyledM.pr_2;
        pub const pr_neg_2 = StyledM.pr_neg_2;
        pub const pr_2p5 = StyledM.pr_2p5;
        pub const pr_neg_2p5 = StyledM.pr_neg_2p5;
        pub const pr_3 = StyledM.pr_3;
        pub const pr_neg_3 = StyledM.pr_neg_3;
        pub const pr_3p5 = StyledM.pr_3p5;
        pub const pr_neg_3p5 = StyledM.pr_neg_3p5;
        pub const pr_4 = StyledM.pr_4;
        pub const pr_neg_4 = StyledM.pr_neg_4;
        pub const pr_5 = StyledM.pr_5;
        pub const pr_neg_5 = StyledM.pr_neg_5;
        pub const pr_6 = StyledM.pr_6;
        pub const pr_neg_6 = StyledM.pr_neg_6;
        pub const pr_7 = StyledM.pr_7;
        pub const pr_neg_7 = StyledM.pr_neg_7;
        pub const pr_8 = StyledM.pr_8;
        pub const pr_neg_8 = StyledM.pr_neg_8;
        pub const pr_9 = StyledM.pr_9;
        pub const pr_neg_9 = StyledM.pr_neg_9;
        pub const pr_10 = StyledM.pr_10;
        pub const pr_neg_10 = StyledM.pr_neg_10;
        pub const pr_11 = StyledM.pr_11;
        pub const pr_neg_11 = StyledM.pr_neg_11;
        pub const pr_12 = StyledM.pr_12;
        pub const pr_neg_12 = StyledM.pr_neg_12;
        pub const pr_16 = StyledM.pr_16;
        pub const pr_neg_16 = StyledM.pr_neg_16;
        pub const pr_20 = StyledM.pr_20;
        pub const pr_neg_20 = StyledM.pr_neg_20;
        pub const pr_24 = StyledM.pr_24;
        pub const pr_neg_24 = StyledM.pr_neg_24;
        pub const pr_32 = StyledM.pr_32;
        pub const pr_neg_32 = StyledM.pr_neg_32;
        pub const pr_40 = StyledM.pr_40;
        pub const pr_neg_40 = StyledM.pr_neg_40;
        pub const pr_48 = StyledM.pr_48;
        pub const pr_neg_48 = StyledM.pr_neg_48;
        pub const pr_56 = StyledM.pr_56;
        pub const pr_neg_56 = StyledM.pr_neg_56;
        pub const pr_64 = StyledM.pr_64;
        pub const pr_neg_64 = StyledM.pr_neg_64;
        pub const pr_72 = StyledM.pr_72;
        pub const pr_neg_72 = StyledM.pr_neg_72;
        pub const pr_80 = StyledM.pr_80;
        pub const pr_neg_80 = StyledM.pr_neg_80;
        pub const pr_96 = StyledM.pr_96;
        pub const pr_neg_96 = StyledM.pr_neg_96;
        pub const pr_112 = StyledM.pr_112;
        pub const pr_neg_112 = StyledM.pr_neg_112;
        pub const pr_128 = StyledM.pr_128;
        pub const pr_neg_128 = StyledM.pr_neg_128;
        pub const pr_px = StyledM.pr_px;
        pub const pr_neg_px = StyledM.pr_neg_px;
        pub const pr_full = StyledM.pr_full;
        pub const pr_neg_full = StyledM.pr_neg_full;
        pub const pr_1_2 = StyledM.pr_1_2;
        pub const pr_neg_1_2 = StyledM.pr_neg_1_2;
        pub const pr_1_3 = StyledM.pr_1_3;
        pub const pr_neg_1_3 = StyledM.pr_neg_1_3;
        pub const pr_2_3 = StyledM.pr_2_3;
        pub const pr_neg_2_3 = StyledM.pr_neg_2_3;
        pub const pr_1_4 = StyledM.pr_1_4;
        pub const pr_neg_1_4 = StyledM.pr_neg_1_4;
        pub const pr_2_4 = StyledM.pr_2_4;
        pub const pr_neg_2_4 = StyledM.pr_neg_2_4;
        pub const pr_3_4 = StyledM.pr_3_4;
        pub const pr_neg_3_4 = StyledM.pr_neg_3_4;
        pub const pr_1_5 = StyledM.pr_1_5;
        pub const pr_neg_1_5 = StyledM.pr_neg_1_5;
        pub const pr_2_5 = StyledM.pr_2_5;
        pub const pr_neg_2_5 = StyledM.pr_neg_2_5;
        pub const pr_3_5 = StyledM.pr_3_5;
        pub const pr_neg_3_5 = StyledM.pr_neg_3_5;
        pub const pr_4_5 = StyledM.pr_4_5;
        pub const pr_neg_4_5 = StyledM.pr_neg_4_5;
        pub const pr_1_6 = StyledM.pr_1_6;
        pub const pr_neg_1_6 = StyledM.pr_neg_1_6;
        pub const pr_5_6 = StyledM.pr_5_6;
        pub const pr_neg_5_6 = StyledM.pr_neg_5_6;
        pub const pr_1_12 = StyledM.pr_1_12;
        pub const pr_neg_1_12 = StyledM.pr_neg_1_12;
        pub const inset = StyledM.inset;
        pub const inset_0 = StyledM.inset_0;
        pub const inset_neg_0 = StyledM.inset_neg_0;
        pub const inset_0p5 = StyledM.inset_0p5;
        pub const inset_neg_0p5 = StyledM.inset_neg_0p5;
        pub const inset_1 = StyledM.inset_1;
        pub const inset_neg_1 = StyledM.inset_neg_1;
        pub const inset_1p5 = StyledM.inset_1p5;
        pub const inset_neg_1p5 = StyledM.inset_neg_1p5;
        pub const inset_2 = StyledM.inset_2;
        pub const inset_neg_2 = StyledM.inset_neg_2;
        pub const inset_2p5 = StyledM.inset_2p5;
        pub const inset_neg_2p5 = StyledM.inset_neg_2p5;
        pub const inset_3 = StyledM.inset_3;
        pub const inset_neg_3 = StyledM.inset_neg_3;
        pub const inset_3p5 = StyledM.inset_3p5;
        pub const inset_neg_3p5 = StyledM.inset_neg_3p5;
        pub const inset_4 = StyledM.inset_4;
        pub const inset_neg_4 = StyledM.inset_neg_4;
        pub const inset_5 = StyledM.inset_5;
        pub const inset_neg_5 = StyledM.inset_neg_5;
        pub const inset_6 = StyledM.inset_6;
        pub const inset_neg_6 = StyledM.inset_neg_6;
        pub const inset_7 = StyledM.inset_7;
        pub const inset_neg_7 = StyledM.inset_neg_7;
        pub const inset_8 = StyledM.inset_8;
        pub const inset_neg_8 = StyledM.inset_neg_8;
        pub const inset_9 = StyledM.inset_9;
        pub const inset_neg_9 = StyledM.inset_neg_9;
        pub const inset_10 = StyledM.inset_10;
        pub const inset_neg_10 = StyledM.inset_neg_10;
        pub const inset_11 = StyledM.inset_11;
        pub const inset_neg_11 = StyledM.inset_neg_11;
        pub const inset_12 = StyledM.inset_12;
        pub const inset_neg_12 = StyledM.inset_neg_12;
        pub const inset_16 = StyledM.inset_16;
        pub const inset_neg_16 = StyledM.inset_neg_16;
        pub const inset_20 = StyledM.inset_20;
        pub const inset_neg_20 = StyledM.inset_neg_20;
        pub const inset_24 = StyledM.inset_24;
        pub const inset_neg_24 = StyledM.inset_neg_24;
        pub const inset_32 = StyledM.inset_32;
        pub const inset_neg_32 = StyledM.inset_neg_32;
        pub const inset_40 = StyledM.inset_40;
        pub const inset_neg_40 = StyledM.inset_neg_40;
        pub const inset_48 = StyledM.inset_48;
        pub const inset_neg_48 = StyledM.inset_neg_48;
        pub const inset_56 = StyledM.inset_56;
        pub const inset_neg_56 = StyledM.inset_neg_56;
        pub const inset_64 = StyledM.inset_64;
        pub const inset_neg_64 = StyledM.inset_neg_64;
        pub const inset_72 = StyledM.inset_72;
        pub const inset_neg_72 = StyledM.inset_neg_72;
        pub const inset_80 = StyledM.inset_80;
        pub const inset_neg_80 = StyledM.inset_neg_80;
        pub const inset_96 = StyledM.inset_96;
        pub const inset_neg_96 = StyledM.inset_neg_96;
        pub const inset_112 = StyledM.inset_112;
        pub const inset_neg_112 = StyledM.inset_neg_112;
        pub const inset_128 = StyledM.inset_128;
        pub const inset_neg_128 = StyledM.inset_neg_128;
        pub const inset_auto = StyledM.inset_auto;
        pub const inset_px = StyledM.inset_px;
        pub const inset_neg_px = StyledM.inset_neg_px;
        pub const inset_full = StyledM.inset_full;
        pub const inset_neg_full = StyledM.inset_neg_full;
        pub const inset_1_2 = StyledM.inset_1_2;
        pub const inset_neg_1_2 = StyledM.inset_neg_1_2;
        pub const inset_1_3 = StyledM.inset_1_3;
        pub const inset_neg_1_3 = StyledM.inset_neg_1_3;
        pub const inset_2_3 = StyledM.inset_2_3;
        pub const inset_neg_2_3 = StyledM.inset_neg_2_3;
        pub const inset_1_4 = StyledM.inset_1_4;
        pub const inset_neg_1_4 = StyledM.inset_neg_1_4;
        pub const inset_2_4 = StyledM.inset_2_4;
        pub const inset_neg_2_4 = StyledM.inset_neg_2_4;
        pub const inset_3_4 = StyledM.inset_3_4;
        pub const inset_neg_3_4 = StyledM.inset_neg_3_4;
        pub const inset_1_5 = StyledM.inset_1_5;
        pub const inset_neg_1_5 = StyledM.inset_neg_1_5;
        pub const inset_2_5 = StyledM.inset_2_5;
        pub const inset_neg_2_5 = StyledM.inset_neg_2_5;
        pub const inset_3_5 = StyledM.inset_3_5;
        pub const inset_neg_3_5 = StyledM.inset_neg_3_5;
        pub const inset_4_5 = StyledM.inset_4_5;
        pub const inset_neg_4_5 = StyledM.inset_neg_4_5;
        pub const inset_1_6 = StyledM.inset_1_6;
        pub const inset_neg_1_6 = StyledM.inset_neg_1_6;
        pub const inset_5_6 = StyledM.inset_5_6;
        pub const inset_neg_5_6 = StyledM.inset_neg_5_6;
        pub const inset_1_12 = StyledM.inset_1_12;
        pub const inset_neg_1_12 = StyledM.inset_neg_1_12;
        pub const top = StyledM.top;
        pub const top_0 = StyledM.top_0;
        pub const top_neg_0 = StyledM.top_neg_0;
        pub const top_0p5 = StyledM.top_0p5;
        pub const top_neg_0p5 = StyledM.top_neg_0p5;
        pub const top_1 = StyledM.top_1;
        pub const top_neg_1 = StyledM.top_neg_1;
        pub const top_1p5 = StyledM.top_1p5;
        pub const top_neg_1p5 = StyledM.top_neg_1p5;
        pub const top_2 = StyledM.top_2;
        pub const top_neg_2 = StyledM.top_neg_2;
        pub const top_2p5 = StyledM.top_2p5;
        pub const top_neg_2p5 = StyledM.top_neg_2p5;
        pub const top_3 = StyledM.top_3;
        pub const top_neg_3 = StyledM.top_neg_3;
        pub const top_3p5 = StyledM.top_3p5;
        pub const top_neg_3p5 = StyledM.top_neg_3p5;
        pub const top_4 = StyledM.top_4;
        pub const top_neg_4 = StyledM.top_neg_4;
        pub const top_5 = StyledM.top_5;
        pub const top_neg_5 = StyledM.top_neg_5;
        pub const top_6 = StyledM.top_6;
        pub const top_neg_6 = StyledM.top_neg_6;
        pub const top_7 = StyledM.top_7;
        pub const top_neg_7 = StyledM.top_neg_7;
        pub const top_8 = StyledM.top_8;
        pub const top_neg_8 = StyledM.top_neg_8;
        pub const top_9 = StyledM.top_9;
        pub const top_neg_9 = StyledM.top_neg_9;
        pub const top_10 = StyledM.top_10;
        pub const top_neg_10 = StyledM.top_neg_10;
        pub const top_11 = StyledM.top_11;
        pub const top_neg_11 = StyledM.top_neg_11;
        pub const top_12 = StyledM.top_12;
        pub const top_neg_12 = StyledM.top_neg_12;
        pub const top_16 = StyledM.top_16;
        pub const top_neg_16 = StyledM.top_neg_16;
        pub const top_20 = StyledM.top_20;
        pub const top_neg_20 = StyledM.top_neg_20;
        pub const top_24 = StyledM.top_24;
        pub const top_neg_24 = StyledM.top_neg_24;
        pub const top_32 = StyledM.top_32;
        pub const top_neg_32 = StyledM.top_neg_32;
        pub const top_40 = StyledM.top_40;
        pub const top_neg_40 = StyledM.top_neg_40;
        pub const top_48 = StyledM.top_48;
        pub const top_neg_48 = StyledM.top_neg_48;
        pub const top_56 = StyledM.top_56;
        pub const top_neg_56 = StyledM.top_neg_56;
        pub const top_64 = StyledM.top_64;
        pub const top_neg_64 = StyledM.top_neg_64;
        pub const top_72 = StyledM.top_72;
        pub const top_neg_72 = StyledM.top_neg_72;
        pub const top_80 = StyledM.top_80;
        pub const top_neg_80 = StyledM.top_neg_80;
        pub const top_96 = StyledM.top_96;
        pub const top_neg_96 = StyledM.top_neg_96;
        pub const top_112 = StyledM.top_112;
        pub const top_neg_112 = StyledM.top_neg_112;
        pub const top_128 = StyledM.top_128;
        pub const top_neg_128 = StyledM.top_neg_128;
        pub const top_auto = StyledM.top_auto;
        pub const top_px = StyledM.top_px;
        pub const top_neg_px = StyledM.top_neg_px;
        pub const top_full = StyledM.top_full;
        pub const top_neg_full = StyledM.top_neg_full;
        pub const top_1_2 = StyledM.top_1_2;
        pub const top_neg_1_2 = StyledM.top_neg_1_2;
        pub const top_1_3 = StyledM.top_1_3;
        pub const top_neg_1_3 = StyledM.top_neg_1_3;
        pub const top_2_3 = StyledM.top_2_3;
        pub const top_neg_2_3 = StyledM.top_neg_2_3;
        pub const top_1_4 = StyledM.top_1_4;
        pub const top_neg_1_4 = StyledM.top_neg_1_4;
        pub const top_2_4 = StyledM.top_2_4;
        pub const top_neg_2_4 = StyledM.top_neg_2_4;
        pub const top_3_4 = StyledM.top_3_4;
        pub const top_neg_3_4 = StyledM.top_neg_3_4;
        pub const top_1_5 = StyledM.top_1_5;
        pub const top_neg_1_5 = StyledM.top_neg_1_5;
        pub const top_2_5 = StyledM.top_2_5;
        pub const top_neg_2_5 = StyledM.top_neg_2_5;
        pub const top_3_5 = StyledM.top_3_5;
        pub const top_neg_3_5 = StyledM.top_neg_3_5;
        pub const top_4_5 = StyledM.top_4_5;
        pub const top_neg_4_5 = StyledM.top_neg_4_5;
        pub const top_1_6 = StyledM.top_1_6;
        pub const top_neg_1_6 = StyledM.top_neg_1_6;
        pub const top_5_6 = StyledM.top_5_6;
        pub const top_neg_5_6 = StyledM.top_neg_5_6;
        pub const top_1_12 = StyledM.top_1_12;
        pub const top_neg_1_12 = StyledM.top_neg_1_12;
        pub const bottom = StyledM.bottom;
        pub const bottom_0 = StyledM.bottom_0;
        pub const bottom_neg_0 = StyledM.bottom_neg_0;
        pub const bottom_0p5 = StyledM.bottom_0p5;
        pub const bottom_neg_0p5 = StyledM.bottom_neg_0p5;
        pub const bottom_1 = StyledM.bottom_1;
        pub const bottom_neg_1 = StyledM.bottom_neg_1;
        pub const bottom_1p5 = StyledM.bottom_1p5;
        pub const bottom_neg_1p5 = StyledM.bottom_neg_1p5;
        pub const bottom_2 = StyledM.bottom_2;
        pub const bottom_neg_2 = StyledM.bottom_neg_2;
        pub const bottom_2p5 = StyledM.bottom_2p5;
        pub const bottom_neg_2p5 = StyledM.bottom_neg_2p5;
        pub const bottom_3 = StyledM.bottom_3;
        pub const bottom_neg_3 = StyledM.bottom_neg_3;
        pub const bottom_3p5 = StyledM.bottom_3p5;
        pub const bottom_neg_3p5 = StyledM.bottom_neg_3p5;
        pub const bottom_4 = StyledM.bottom_4;
        pub const bottom_neg_4 = StyledM.bottom_neg_4;
        pub const bottom_5 = StyledM.bottom_5;
        pub const bottom_neg_5 = StyledM.bottom_neg_5;
        pub const bottom_6 = StyledM.bottom_6;
        pub const bottom_neg_6 = StyledM.bottom_neg_6;
        pub const bottom_7 = StyledM.bottom_7;
        pub const bottom_neg_7 = StyledM.bottom_neg_7;
        pub const bottom_8 = StyledM.bottom_8;
        pub const bottom_neg_8 = StyledM.bottom_neg_8;
        pub const bottom_9 = StyledM.bottom_9;
        pub const bottom_neg_9 = StyledM.bottom_neg_9;
        pub const bottom_10 = StyledM.bottom_10;
        pub const bottom_neg_10 = StyledM.bottom_neg_10;
        pub const bottom_11 = StyledM.bottom_11;
        pub const bottom_neg_11 = StyledM.bottom_neg_11;
        pub const bottom_12 = StyledM.bottom_12;
        pub const bottom_neg_12 = StyledM.bottom_neg_12;
        pub const bottom_16 = StyledM.bottom_16;
        pub const bottom_neg_16 = StyledM.bottom_neg_16;
        pub const bottom_20 = StyledM.bottom_20;
        pub const bottom_neg_20 = StyledM.bottom_neg_20;
        pub const bottom_24 = StyledM.bottom_24;
        pub const bottom_neg_24 = StyledM.bottom_neg_24;
        pub const bottom_32 = StyledM.bottom_32;
        pub const bottom_neg_32 = StyledM.bottom_neg_32;
        pub const bottom_40 = StyledM.bottom_40;
        pub const bottom_neg_40 = StyledM.bottom_neg_40;
        pub const bottom_48 = StyledM.bottom_48;
        pub const bottom_neg_48 = StyledM.bottom_neg_48;
        pub const bottom_56 = StyledM.bottom_56;
        pub const bottom_neg_56 = StyledM.bottom_neg_56;
        pub const bottom_64 = StyledM.bottom_64;
        pub const bottom_neg_64 = StyledM.bottom_neg_64;
        pub const bottom_72 = StyledM.bottom_72;
        pub const bottom_neg_72 = StyledM.bottom_neg_72;
        pub const bottom_80 = StyledM.bottom_80;
        pub const bottom_neg_80 = StyledM.bottom_neg_80;
        pub const bottom_96 = StyledM.bottom_96;
        pub const bottom_neg_96 = StyledM.bottom_neg_96;
        pub const bottom_112 = StyledM.bottom_112;
        pub const bottom_neg_112 = StyledM.bottom_neg_112;
        pub const bottom_128 = StyledM.bottom_128;
        pub const bottom_neg_128 = StyledM.bottom_neg_128;
        pub const bottom_auto = StyledM.bottom_auto;
        pub const bottom_px = StyledM.bottom_px;
        pub const bottom_neg_px = StyledM.bottom_neg_px;
        pub const bottom_full = StyledM.bottom_full;
        pub const bottom_neg_full = StyledM.bottom_neg_full;
        pub const bottom_1_2 = StyledM.bottom_1_2;
        pub const bottom_neg_1_2 = StyledM.bottom_neg_1_2;
        pub const bottom_1_3 = StyledM.bottom_1_3;
        pub const bottom_neg_1_3 = StyledM.bottom_neg_1_3;
        pub const bottom_2_3 = StyledM.bottom_2_3;
        pub const bottom_neg_2_3 = StyledM.bottom_neg_2_3;
        pub const bottom_1_4 = StyledM.bottom_1_4;
        pub const bottom_neg_1_4 = StyledM.bottom_neg_1_4;
        pub const bottom_2_4 = StyledM.bottom_2_4;
        pub const bottom_neg_2_4 = StyledM.bottom_neg_2_4;
        pub const bottom_3_4 = StyledM.bottom_3_4;
        pub const bottom_neg_3_4 = StyledM.bottom_neg_3_4;
        pub const bottom_1_5 = StyledM.bottom_1_5;
        pub const bottom_neg_1_5 = StyledM.bottom_neg_1_5;
        pub const bottom_2_5 = StyledM.bottom_2_5;
        pub const bottom_neg_2_5 = StyledM.bottom_neg_2_5;
        pub const bottom_3_5 = StyledM.bottom_3_5;
        pub const bottom_neg_3_5 = StyledM.bottom_neg_3_5;
        pub const bottom_4_5 = StyledM.bottom_4_5;
        pub const bottom_neg_4_5 = StyledM.bottom_neg_4_5;
        pub const bottom_1_6 = StyledM.bottom_1_6;
        pub const bottom_neg_1_6 = StyledM.bottom_neg_1_6;
        pub const bottom_5_6 = StyledM.bottom_5_6;
        pub const bottom_neg_5_6 = StyledM.bottom_neg_5_6;
        pub const bottom_1_12 = StyledM.bottom_1_12;
        pub const bottom_neg_1_12 = StyledM.bottom_neg_1_12;
        pub const left = StyledM.left;
        pub const left_0 = StyledM.left_0;
        pub const left_neg_0 = StyledM.left_neg_0;
        pub const left_0p5 = StyledM.left_0p5;
        pub const left_neg_0p5 = StyledM.left_neg_0p5;
        pub const left_1 = StyledM.left_1;
        pub const left_neg_1 = StyledM.left_neg_1;
        pub const left_1p5 = StyledM.left_1p5;
        pub const left_neg_1p5 = StyledM.left_neg_1p5;
        pub const left_2 = StyledM.left_2;
        pub const left_neg_2 = StyledM.left_neg_2;
        pub const left_2p5 = StyledM.left_2p5;
        pub const left_neg_2p5 = StyledM.left_neg_2p5;
        pub const left_3 = StyledM.left_3;
        pub const left_neg_3 = StyledM.left_neg_3;
        pub const left_3p5 = StyledM.left_3p5;
        pub const left_neg_3p5 = StyledM.left_neg_3p5;
        pub const left_4 = StyledM.left_4;
        pub const left_neg_4 = StyledM.left_neg_4;
        pub const left_5 = StyledM.left_5;
        pub const left_neg_5 = StyledM.left_neg_5;
        pub const left_6 = StyledM.left_6;
        pub const left_neg_6 = StyledM.left_neg_6;
        pub const left_7 = StyledM.left_7;
        pub const left_neg_7 = StyledM.left_neg_7;
        pub const left_8 = StyledM.left_8;
        pub const left_neg_8 = StyledM.left_neg_8;
        pub const left_9 = StyledM.left_9;
        pub const left_neg_9 = StyledM.left_neg_9;
        pub const left_10 = StyledM.left_10;
        pub const left_neg_10 = StyledM.left_neg_10;
        pub const left_11 = StyledM.left_11;
        pub const left_neg_11 = StyledM.left_neg_11;
        pub const left_12 = StyledM.left_12;
        pub const left_neg_12 = StyledM.left_neg_12;
        pub const left_16 = StyledM.left_16;
        pub const left_neg_16 = StyledM.left_neg_16;
        pub const left_20 = StyledM.left_20;
        pub const left_neg_20 = StyledM.left_neg_20;
        pub const left_24 = StyledM.left_24;
        pub const left_neg_24 = StyledM.left_neg_24;
        pub const left_32 = StyledM.left_32;
        pub const left_neg_32 = StyledM.left_neg_32;
        pub const left_40 = StyledM.left_40;
        pub const left_neg_40 = StyledM.left_neg_40;
        pub const left_48 = StyledM.left_48;
        pub const left_neg_48 = StyledM.left_neg_48;
        pub const left_56 = StyledM.left_56;
        pub const left_neg_56 = StyledM.left_neg_56;
        pub const left_64 = StyledM.left_64;
        pub const left_neg_64 = StyledM.left_neg_64;
        pub const left_72 = StyledM.left_72;
        pub const left_neg_72 = StyledM.left_neg_72;
        pub const left_80 = StyledM.left_80;
        pub const left_neg_80 = StyledM.left_neg_80;
        pub const left_96 = StyledM.left_96;
        pub const left_neg_96 = StyledM.left_neg_96;
        pub const left_112 = StyledM.left_112;
        pub const left_neg_112 = StyledM.left_neg_112;
        pub const left_128 = StyledM.left_128;
        pub const left_neg_128 = StyledM.left_neg_128;
        pub const left_auto = StyledM.left_auto;
        pub const left_px = StyledM.left_px;
        pub const left_neg_px = StyledM.left_neg_px;
        pub const left_full = StyledM.left_full;
        pub const left_neg_full = StyledM.left_neg_full;
        pub const left_1_2 = StyledM.left_1_2;
        pub const left_neg_1_2 = StyledM.left_neg_1_2;
        pub const left_1_3 = StyledM.left_1_3;
        pub const left_neg_1_3 = StyledM.left_neg_1_3;
        pub const left_2_3 = StyledM.left_2_3;
        pub const left_neg_2_3 = StyledM.left_neg_2_3;
        pub const left_1_4 = StyledM.left_1_4;
        pub const left_neg_1_4 = StyledM.left_neg_1_4;
        pub const left_2_4 = StyledM.left_2_4;
        pub const left_neg_2_4 = StyledM.left_neg_2_4;
        pub const left_3_4 = StyledM.left_3_4;
        pub const left_neg_3_4 = StyledM.left_neg_3_4;
        pub const left_1_5 = StyledM.left_1_5;
        pub const left_neg_1_5 = StyledM.left_neg_1_5;
        pub const left_2_5 = StyledM.left_2_5;
        pub const left_neg_2_5 = StyledM.left_neg_2_5;
        pub const left_3_5 = StyledM.left_3_5;
        pub const left_neg_3_5 = StyledM.left_neg_3_5;
        pub const left_4_5 = StyledM.left_4_5;
        pub const left_neg_4_5 = StyledM.left_neg_4_5;
        pub const left_1_6 = StyledM.left_1_6;
        pub const left_neg_1_6 = StyledM.left_neg_1_6;
        pub const left_5_6 = StyledM.left_5_6;
        pub const left_neg_5_6 = StyledM.left_neg_5_6;
        pub const left_1_12 = StyledM.left_1_12;
        pub const left_neg_1_12 = StyledM.left_neg_1_12;
        pub const right = StyledM.right;
        pub const right_0 = StyledM.right_0;
        pub const right_neg_0 = StyledM.right_neg_0;
        pub const right_0p5 = StyledM.right_0p5;
        pub const right_neg_0p5 = StyledM.right_neg_0p5;
        pub const right_1 = StyledM.right_1;
        pub const right_neg_1 = StyledM.right_neg_1;
        pub const right_1p5 = StyledM.right_1p5;
        pub const right_neg_1p5 = StyledM.right_neg_1p5;
        pub const right_2 = StyledM.right_2;
        pub const right_neg_2 = StyledM.right_neg_2;
        pub const right_2p5 = StyledM.right_2p5;
        pub const right_neg_2p5 = StyledM.right_neg_2p5;
        pub const right_3 = StyledM.right_3;
        pub const right_neg_3 = StyledM.right_neg_3;
        pub const right_3p5 = StyledM.right_3p5;
        pub const right_neg_3p5 = StyledM.right_neg_3p5;
        pub const right_4 = StyledM.right_4;
        pub const right_neg_4 = StyledM.right_neg_4;
        pub const right_5 = StyledM.right_5;
        pub const right_neg_5 = StyledM.right_neg_5;
        pub const right_6 = StyledM.right_6;
        pub const right_neg_6 = StyledM.right_neg_6;
        pub const right_7 = StyledM.right_7;
        pub const right_neg_7 = StyledM.right_neg_7;
        pub const right_8 = StyledM.right_8;
        pub const right_neg_8 = StyledM.right_neg_8;
        pub const right_9 = StyledM.right_9;
        pub const right_neg_9 = StyledM.right_neg_9;
        pub const right_10 = StyledM.right_10;
        pub const right_neg_10 = StyledM.right_neg_10;
        pub const right_11 = StyledM.right_11;
        pub const right_neg_11 = StyledM.right_neg_11;
        pub const right_12 = StyledM.right_12;
        pub const right_neg_12 = StyledM.right_neg_12;
        pub const right_16 = StyledM.right_16;
        pub const right_neg_16 = StyledM.right_neg_16;
        pub const right_20 = StyledM.right_20;
        pub const right_neg_20 = StyledM.right_neg_20;
        pub const right_24 = StyledM.right_24;
        pub const right_neg_24 = StyledM.right_neg_24;
        pub const right_32 = StyledM.right_32;
        pub const right_neg_32 = StyledM.right_neg_32;
        pub const right_40 = StyledM.right_40;
        pub const right_neg_40 = StyledM.right_neg_40;
        pub const right_48 = StyledM.right_48;
        pub const right_neg_48 = StyledM.right_neg_48;
        pub const right_56 = StyledM.right_56;
        pub const right_neg_56 = StyledM.right_neg_56;
        pub const right_64 = StyledM.right_64;
        pub const right_neg_64 = StyledM.right_neg_64;
        pub const right_72 = StyledM.right_72;
        pub const right_neg_72 = StyledM.right_neg_72;
        pub const right_80 = StyledM.right_80;
        pub const right_neg_80 = StyledM.right_neg_80;
        pub const right_96 = StyledM.right_96;
        pub const right_neg_96 = StyledM.right_neg_96;
        pub const right_112 = StyledM.right_112;
        pub const right_neg_112 = StyledM.right_neg_112;
        pub const right_128 = StyledM.right_128;
        pub const right_neg_128 = StyledM.right_neg_128;
        pub const right_auto = StyledM.right_auto;
        pub const right_px = StyledM.right_px;
        pub const right_neg_px = StyledM.right_neg_px;
        pub const right_full = StyledM.right_full;
        pub const right_neg_full = StyledM.right_neg_full;
        pub const right_1_2 = StyledM.right_1_2;
        pub const right_neg_1_2 = StyledM.right_neg_1_2;
        pub const right_1_3 = StyledM.right_1_3;
        pub const right_neg_1_3 = StyledM.right_neg_1_3;
        pub const right_2_3 = StyledM.right_2_3;
        pub const right_neg_2_3 = StyledM.right_neg_2_3;
        pub const right_1_4 = StyledM.right_1_4;
        pub const right_neg_1_4 = StyledM.right_neg_1_4;
        pub const right_2_4 = StyledM.right_2_4;
        pub const right_neg_2_4 = StyledM.right_neg_2_4;
        pub const right_3_4 = StyledM.right_3_4;
        pub const right_neg_3_4 = StyledM.right_neg_3_4;
        pub const right_1_5 = StyledM.right_1_5;
        pub const right_neg_1_5 = StyledM.right_neg_1_5;
        pub const right_2_5 = StyledM.right_2_5;
        pub const right_neg_2_5 = StyledM.right_neg_2_5;
        pub const right_3_5 = StyledM.right_3_5;
        pub const right_neg_3_5 = StyledM.right_neg_3_5;
        pub const right_4_5 = StyledM.right_4_5;
        pub const right_neg_4_5 = StyledM.right_neg_4_5;
        pub const right_1_6 = StyledM.right_1_6;
        pub const right_neg_1_6 = StyledM.right_neg_1_6;
        pub const right_5_6 = StyledM.right_5_6;
        pub const right_neg_5_6 = StyledM.right_neg_5_6;
        pub const right_1_12 = StyledM.right_1_12;
        pub const right_neg_1_12 = StyledM.right_neg_1_12;
        pub const w = StyledM.w;
        pub const w_0 = StyledM.w_0;
        pub const w_neg_0 = StyledM.w_neg_0;
        pub const w_0p5 = StyledM.w_0p5;
        pub const w_neg_0p5 = StyledM.w_neg_0p5;
        pub const w_1 = StyledM.w_1;
        pub const w_neg_1 = StyledM.w_neg_1;
        pub const w_1p5 = StyledM.w_1p5;
        pub const w_neg_1p5 = StyledM.w_neg_1p5;
        pub const w_2 = StyledM.w_2;
        pub const w_neg_2 = StyledM.w_neg_2;
        pub const w_2p5 = StyledM.w_2p5;
        pub const w_neg_2p5 = StyledM.w_neg_2p5;
        pub const w_3 = StyledM.w_3;
        pub const w_neg_3 = StyledM.w_neg_3;
        pub const w_3p5 = StyledM.w_3p5;
        pub const w_neg_3p5 = StyledM.w_neg_3p5;
        pub const w_4 = StyledM.w_4;
        pub const w_neg_4 = StyledM.w_neg_4;
        pub const w_5 = StyledM.w_5;
        pub const w_neg_5 = StyledM.w_neg_5;
        pub const w_6 = StyledM.w_6;
        pub const w_neg_6 = StyledM.w_neg_6;
        pub const w_7 = StyledM.w_7;
        pub const w_neg_7 = StyledM.w_neg_7;
        pub const w_8 = StyledM.w_8;
        pub const w_neg_8 = StyledM.w_neg_8;
        pub const w_9 = StyledM.w_9;
        pub const w_neg_9 = StyledM.w_neg_9;
        pub const w_10 = StyledM.w_10;
        pub const w_neg_10 = StyledM.w_neg_10;
        pub const w_11 = StyledM.w_11;
        pub const w_neg_11 = StyledM.w_neg_11;
        pub const w_12 = StyledM.w_12;
        pub const w_neg_12 = StyledM.w_neg_12;
        pub const w_16 = StyledM.w_16;
        pub const w_neg_16 = StyledM.w_neg_16;
        pub const w_20 = StyledM.w_20;
        pub const w_neg_20 = StyledM.w_neg_20;
        pub const w_24 = StyledM.w_24;
        pub const w_neg_24 = StyledM.w_neg_24;
        pub const w_32 = StyledM.w_32;
        pub const w_neg_32 = StyledM.w_neg_32;
        pub const w_40 = StyledM.w_40;
        pub const w_neg_40 = StyledM.w_neg_40;
        pub const w_48 = StyledM.w_48;
        pub const w_neg_48 = StyledM.w_neg_48;
        pub const w_56 = StyledM.w_56;
        pub const w_neg_56 = StyledM.w_neg_56;
        pub const w_64 = StyledM.w_64;
        pub const w_neg_64 = StyledM.w_neg_64;
        pub const w_72 = StyledM.w_72;
        pub const w_neg_72 = StyledM.w_neg_72;
        pub const w_80 = StyledM.w_80;
        pub const w_neg_80 = StyledM.w_neg_80;
        pub const w_96 = StyledM.w_96;
        pub const w_neg_96 = StyledM.w_neg_96;
        pub const w_112 = StyledM.w_112;
        pub const w_neg_112 = StyledM.w_neg_112;
        pub const w_128 = StyledM.w_128;
        pub const w_neg_128 = StyledM.w_neg_128;
        pub const w_auto = StyledM.w_auto;
        pub const w_px = StyledM.w_px;
        pub const w_neg_px = StyledM.w_neg_px;
        pub const w_full = StyledM.w_full;
        pub const w_neg_full = StyledM.w_neg_full;
        pub const w_1_2 = StyledM.w_1_2;
        pub const w_neg_1_2 = StyledM.w_neg_1_2;
        pub const w_1_3 = StyledM.w_1_3;
        pub const w_neg_1_3 = StyledM.w_neg_1_3;
        pub const w_2_3 = StyledM.w_2_3;
        pub const w_neg_2_3 = StyledM.w_neg_2_3;
        pub const w_1_4 = StyledM.w_1_4;
        pub const w_neg_1_4 = StyledM.w_neg_1_4;
        pub const w_2_4 = StyledM.w_2_4;
        pub const w_neg_2_4 = StyledM.w_neg_2_4;
        pub const w_3_4 = StyledM.w_3_4;
        pub const w_neg_3_4 = StyledM.w_neg_3_4;
        pub const w_1_5 = StyledM.w_1_5;
        pub const w_neg_1_5 = StyledM.w_neg_1_5;
        pub const w_2_5 = StyledM.w_2_5;
        pub const w_neg_2_5 = StyledM.w_neg_2_5;
        pub const w_3_5 = StyledM.w_3_5;
        pub const w_neg_3_5 = StyledM.w_neg_3_5;
        pub const w_4_5 = StyledM.w_4_5;
        pub const w_neg_4_5 = StyledM.w_neg_4_5;
        pub const w_1_6 = StyledM.w_1_6;
        pub const w_neg_1_6 = StyledM.w_neg_1_6;
        pub const w_5_6 = StyledM.w_5_6;
        pub const w_neg_5_6 = StyledM.w_neg_5_6;
        pub const w_1_12 = StyledM.w_1_12;
        pub const w_neg_1_12 = StyledM.w_neg_1_12;
        pub const h = StyledM.h;
        pub const h_0 = StyledM.h_0;
        pub const h_neg_0 = StyledM.h_neg_0;
        pub const h_0p5 = StyledM.h_0p5;
        pub const h_neg_0p5 = StyledM.h_neg_0p5;
        pub const h_1 = StyledM.h_1;
        pub const h_neg_1 = StyledM.h_neg_1;
        pub const h_1p5 = StyledM.h_1p5;
        pub const h_neg_1p5 = StyledM.h_neg_1p5;
        pub const h_2 = StyledM.h_2;
        pub const h_neg_2 = StyledM.h_neg_2;
        pub const h_2p5 = StyledM.h_2p5;
        pub const h_neg_2p5 = StyledM.h_neg_2p5;
        pub const h_3 = StyledM.h_3;
        pub const h_neg_3 = StyledM.h_neg_3;
        pub const h_3p5 = StyledM.h_3p5;
        pub const h_neg_3p5 = StyledM.h_neg_3p5;
        pub const h_4 = StyledM.h_4;
        pub const h_neg_4 = StyledM.h_neg_4;
        pub const h_5 = StyledM.h_5;
        pub const h_neg_5 = StyledM.h_neg_5;
        pub const h_6 = StyledM.h_6;
        pub const h_neg_6 = StyledM.h_neg_6;
        pub const h_7 = StyledM.h_7;
        pub const h_neg_7 = StyledM.h_neg_7;
        pub const h_8 = StyledM.h_8;
        pub const h_neg_8 = StyledM.h_neg_8;
        pub const h_9 = StyledM.h_9;
        pub const h_neg_9 = StyledM.h_neg_9;
        pub const h_10 = StyledM.h_10;
        pub const h_neg_10 = StyledM.h_neg_10;
        pub const h_11 = StyledM.h_11;
        pub const h_neg_11 = StyledM.h_neg_11;
        pub const h_12 = StyledM.h_12;
        pub const h_neg_12 = StyledM.h_neg_12;
        pub const h_16 = StyledM.h_16;
        pub const h_neg_16 = StyledM.h_neg_16;
        pub const h_20 = StyledM.h_20;
        pub const h_neg_20 = StyledM.h_neg_20;
        pub const h_24 = StyledM.h_24;
        pub const h_neg_24 = StyledM.h_neg_24;
        pub const h_32 = StyledM.h_32;
        pub const h_neg_32 = StyledM.h_neg_32;
        pub const h_40 = StyledM.h_40;
        pub const h_neg_40 = StyledM.h_neg_40;
        pub const h_48 = StyledM.h_48;
        pub const h_neg_48 = StyledM.h_neg_48;
        pub const h_56 = StyledM.h_56;
        pub const h_neg_56 = StyledM.h_neg_56;
        pub const h_64 = StyledM.h_64;
        pub const h_neg_64 = StyledM.h_neg_64;
        pub const h_72 = StyledM.h_72;
        pub const h_neg_72 = StyledM.h_neg_72;
        pub const h_80 = StyledM.h_80;
        pub const h_neg_80 = StyledM.h_neg_80;
        pub const h_96 = StyledM.h_96;
        pub const h_neg_96 = StyledM.h_neg_96;
        pub const h_112 = StyledM.h_112;
        pub const h_neg_112 = StyledM.h_neg_112;
        pub const h_128 = StyledM.h_128;
        pub const h_neg_128 = StyledM.h_neg_128;
        pub const h_auto = StyledM.h_auto;
        pub const h_px = StyledM.h_px;
        pub const h_neg_px = StyledM.h_neg_px;
        pub const h_full = StyledM.h_full;
        pub const h_neg_full = StyledM.h_neg_full;
        pub const h_1_2 = StyledM.h_1_2;
        pub const h_neg_1_2 = StyledM.h_neg_1_2;
        pub const h_1_3 = StyledM.h_1_3;
        pub const h_neg_1_3 = StyledM.h_neg_1_3;
        pub const h_2_3 = StyledM.h_2_3;
        pub const h_neg_2_3 = StyledM.h_neg_2_3;
        pub const h_1_4 = StyledM.h_1_4;
        pub const h_neg_1_4 = StyledM.h_neg_1_4;
        pub const h_2_4 = StyledM.h_2_4;
        pub const h_neg_2_4 = StyledM.h_neg_2_4;
        pub const h_3_4 = StyledM.h_3_4;
        pub const h_neg_3_4 = StyledM.h_neg_3_4;
        pub const h_1_5 = StyledM.h_1_5;
        pub const h_neg_1_5 = StyledM.h_neg_1_5;
        pub const h_2_5 = StyledM.h_2_5;
        pub const h_neg_2_5 = StyledM.h_neg_2_5;
        pub const h_3_5 = StyledM.h_3_5;
        pub const h_neg_3_5 = StyledM.h_neg_3_5;
        pub const h_4_5 = StyledM.h_4_5;
        pub const h_neg_4_5 = StyledM.h_neg_4_5;
        pub const h_1_6 = StyledM.h_1_6;
        pub const h_neg_1_6 = StyledM.h_neg_1_6;
        pub const h_5_6 = StyledM.h_5_6;
        pub const h_neg_5_6 = StyledM.h_neg_5_6;
        pub const h_1_12 = StyledM.h_1_12;
        pub const h_neg_1_12 = StyledM.h_neg_1_12;
        pub const size = StyledM.size;
        pub const size_0 = StyledM.size_0;
        pub const size_neg_0 = StyledM.size_neg_0;
        pub const size_0p5 = StyledM.size_0p5;
        pub const size_neg_0p5 = StyledM.size_neg_0p5;
        pub const size_1 = StyledM.size_1;
        pub const size_neg_1 = StyledM.size_neg_1;
        pub const size_1p5 = StyledM.size_1p5;
        pub const size_neg_1p5 = StyledM.size_neg_1p5;
        pub const size_2 = StyledM.size_2;
        pub const size_neg_2 = StyledM.size_neg_2;
        pub const size_2p5 = StyledM.size_2p5;
        pub const size_neg_2p5 = StyledM.size_neg_2p5;
        pub const size_3 = StyledM.size_3;
        pub const size_neg_3 = StyledM.size_neg_3;
        pub const size_3p5 = StyledM.size_3p5;
        pub const size_neg_3p5 = StyledM.size_neg_3p5;
        pub const size_4 = StyledM.size_4;
        pub const size_neg_4 = StyledM.size_neg_4;
        pub const size_5 = StyledM.size_5;
        pub const size_neg_5 = StyledM.size_neg_5;
        pub const size_6 = StyledM.size_6;
        pub const size_neg_6 = StyledM.size_neg_6;
        pub const size_7 = StyledM.size_7;
        pub const size_neg_7 = StyledM.size_neg_7;
        pub const size_8 = StyledM.size_8;
        pub const size_neg_8 = StyledM.size_neg_8;
        pub const size_9 = StyledM.size_9;
        pub const size_neg_9 = StyledM.size_neg_9;
        pub const size_10 = StyledM.size_10;
        pub const size_neg_10 = StyledM.size_neg_10;
        pub const size_11 = StyledM.size_11;
        pub const size_neg_11 = StyledM.size_neg_11;
        pub const size_12 = StyledM.size_12;
        pub const size_neg_12 = StyledM.size_neg_12;
        pub const size_16 = StyledM.size_16;
        pub const size_neg_16 = StyledM.size_neg_16;
        pub const size_20 = StyledM.size_20;
        pub const size_neg_20 = StyledM.size_neg_20;
        pub const size_24 = StyledM.size_24;
        pub const size_neg_24 = StyledM.size_neg_24;
        pub const size_32 = StyledM.size_32;
        pub const size_neg_32 = StyledM.size_neg_32;
        pub const size_40 = StyledM.size_40;
        pub const size_neg_40 = StyledM.size_neg_40;
        pub const size_48 = StyledM.size_48;
        pub const size_neg_48 = StyledM.size_neg_48;
        pub const size_56 = StyledM.size_56;
        pub const size_neg_56 = StyledM.size_neg_56;
        pub const size_64 = StyledM.size_64;
        pub const size_neg_64 = StyledM.size_neg_64;
        pub const size_72 = StyledM.size_72;
        pub const size_neg_72 = StyledM.size_neg_72;
        pub const size_80 = StyledM.size_80;
        pub const size_neg_80 = StyledM.size_neg_80;
        pub const size_96 = StyledM.size_96;
        pub const size_neg_96 = StyledM.size_neg_96;
        pub const size_112 = StyledM.size_112;
        pub const size_neg_112 = StyledM.size_neg_112;
        pub const size_128 = StyledM.size_128;
        pub const size_neg_128 = StyledM.size_neg_128;
        pub const size_auto = StyledM.size_auto;
        pub const size_px = StyledM.size_px;
        pub const size_neg_px = StyledM.size_neg_px;
        pub const size_full = StyledM.size_full;
        pub const size_neg_full = StyledM.size_neg_full;
        pub const size_1_2 = StyledM.size_1_2;
        pub const size_neg_1_2 = StyledM.size_neg_1_2;
        pub const size_1_3 = StyledM.size_1_3;
        pub const size_neg_1_3 = StyledM.size_neg_1_3;
        pub const size_2_3 = StyledM.size_2_3;
        pub const size_neg_2_3 = StyledM.size_neg_2_3;
        pub const size_1_4 = StyledM.size_1_4;
        pub const size_neg_1_4 = StyledM.size_neg_1_4;
        pub const size_2_4 = StyledM.size_2_4;
        pub const size_neg_2_4 = StyledM.size_neg_2_4;
        pub const size_3_4 = StyledM.size_3_4;
        pub const size_neg_3_4 = StyledM.size_neg_3_4;
        pub const size_1_5 = StyledM.size_1_5;
        pub const size_neg_1_5 = StyledM.size_neg_1_5;
        pub const size_2_5 = StyledM.size_2_5;
        pub const size_neg_2_5 = StyledM.size_neg_2_5;
        pub const size_3_5 = StyledM.size_3_5;
        pub const size_neg_3_5 = StyledM.size_neg_3_5;
        pub const size_4_5 = StyledM.size_4_5;
        pub const size_neg_4_5 = StyledM.size_neg_4_5;
        pub const size_1_6 = StyledM.size_1_6;
        pub const size_neg_1_6 = StyledM.size_neg_1_6;
        pub const size_5_6 = StyledM.size_5_6;
        pub const size_neg_5_6 = StyledM.size_neg_5_6;
        pub const size_1_12 = StyledM.size_1_12;
        pub const size_neg_1_12 = StyledM.size_neg_1_12;
        pub const min_size = StyledM.min_size;
        pub const min_size_0 = StyledM.min_size_0;
        pub const min_size_neg_0 = StyledM.min_size_neg_0;
        pub const min_size_0p5 = StyledM.min_size_0p5;
        pub const min_size_neg_0p5 = StyledM.min_size_neg_0p5;
        pub const min_size_1 = StyledM.min_size_1;
        pub const min_size_neg_1 = StyledM.min_size_neg_1;
        pub const min_size_1p5 = StyledM.min_size_1p5;
        pub const min_size_neg_1p5 = StyledM.min_size_neg_1p5;
        pub const min_size_2 = StyledM.min_size_2;
        pub const min_size_neg_2 = StyledM.min_size_neg_2;
        pub const min_size_2p5 = StyledM.min_size_2p5;
        pub const min_size_neg_2p5 = StyledM.min_size_neg_2p5;
        pub const min_size_3 = StyledM.min_size_3;
        pub const min_size_neg_3 = StyledM.min_size_neg_3;
        pub const min_size_3p5 = StyledM.min_size_3p5;
        pub const min_size_neg_3p5 = StyledM.min_size_neg_3p5;
        pub const min_size_4 = StyledM.min_size_4;
        pub const min_size_neg_4 = StyledM.min_size_neg_4;
        pub const min_size_5 = StyledM.min_size_5;
        pub const min_size_neg_5 = StyledM.min_size_neg_5;
        pub const min_size_6 = StyledM.min_size_6;
        pub const min_size_neg_6 = StyledM.min_size_neg_6;
        pub const min_size_7 = StyledM.min_size_7;
        pub const min_size_neg_7 = StyledM.min_size_neg_7;
        pub const min_size_8 = StyledM.min_size_8;
        pub const min_size_neg_8 = StyledM.min_size_neg_8;
        pub const min_size_9 = StyledM.min_size_9;
        pub const min_size_neg_9 = StyledM.min_size_neg_9;
        pub const min_size_10 = StyledM.min_size_10;
        pub const min_size_neg_10 = StyledM.min_size_neg_10;
        pub const min_size_11 = StyledM.min_size_11;
        pub const min_size_neg_11 = StyledM.min_size_neg_11;
        pub const min_size_12 = StyledM.min_size_12;
        pub const min_size_neg_12 = StyledM.min_size_neg_12;
        pub const min_size_16 = StyledM.min_size_16;
        pub const min_size_neg_16 = StyledM.min_size_neg_16;
        pub const min_size_20 = StyledM.min_size_20;
        pub const min_size_neg_20 = StyledM.min_size_neg_20;
        pub const min_size_24 = StyledM.min_size_24;
        pub const min_size_neg_24 = StyledM.min_size_neg_24;
        pub const min_size_32 = StyledM.min_size_32;
        pub const min_size_neg_32 = StyledM.min_size_neg_32;
        pub const min_size_40 = StyledM.min_size_40;
        pub const min_size_neg_40 = StyledM.min_size_neg_40;
        pub const min_size_48 = StyledM.min_size_48;
        pub const min_size_neg_48 = StyledM.min_size_neg_48;
        pub const min_size_56 = StyledM.min_size_56;
        pub const min_size_neg_56 = StyledM.min_size_neg_56;
        pub const min_size_64 = StyledM.min_size_64;
        pub const min_size_neg_64 = StyledM.min_size_neg_64;
        pub const min_size_72 = StyledM.min_size_72;
        pub const min_size_neg_72 = StyledM.min_size_neg_72;
        pub const min_size_80 = StyledM.min_size_80;
        pub const min_size_neg_80 = StyledM.min_size_neg_80;
        pub const min_size_96 = StyledM.min_size_96;
        pub const min_size_neg_96 = StyledM.min_size_neg_96;
        pub const min_size_112 = StyledM.min_size_112;
        pub const min_size_neg_112 = StyledM.min_size_neg_112;
        pub const min_size_128 = StyledM.min_size_128;
        pub const min_size_neg_128 = StyledM.min_size_neg_128;
        pub const min_size_auto = StyledM.min_size_auto;
        pub const min_size_px = StyledM.min_size_px;
        pub const min_size_neg_px = StyledM.min_size_neg_px;
        pub const min_size_full = StyledM.min_size_full;
        pub const min_size_neg_full = StyledM.min_size_neg_full;
        pub const min_size_1_2 = StyledM.min_size_1_2;
        pub const min_size_neg_1_2 = StyledM.min_size_neg_1_2;
        pub const min_size_1_3 = StyledM.min_size_1_3;
        pub const min_size_neg_1_3 = StyledM.min_size_neg_1_3;
        pub const min_size_2_3 = StyledM.min_size_2_3;
        pub const min_size_neg_2_3 = StyledM.min_size_neg_2_3;
        pub const min_size_1_4 = StyledM.min_size_1_4;
        pub const min_size_neg_1_4 = StyledM.min_size_neg_1_4;
        pub const min_size_2_4 = StyledM.min_size_2_4;
        pub const min_size_neg_2_4 = StyledM.min_size_neg_2_4;
        pub const min_size_3_4 = StyledM.min_size_3_4;
        pub const min_size_neg_3_4 = StyledM.min_size_neg_3_4;
        pub const min_size_1_5 = StyledM.min_size_1_5;
        pub const min_size_neg_1_5 = StyledM.min_size_neg_1_5;
        pub const min_size_2_5 = StyledM.min_size_2_5;
        pub const min_size_neg_2_5 = StyledM.min_size_neg_2_5;
        pub const min_size_3_5 = StyledM.min_size_3_5;
        pub const min_size_neg_3_5 = StyledM.min_size_neg_3_5;
        pub const min_size_4_5 = StyledM.min_size_4_5;
        pub const min_size_neg_4_5 = StyledM.min_size_neg_4_5;
        pub const min_size_1_6 = StyledM.min_size_1_6;
        pub const min_size_neg_1_6 = StyledM.min_size_neg_1_6;
        pub const min_size_5_6 = StyledM.min_size_5_6;
        pub const min_size_neg_5_6 = StyledM.min_size_neg_5_6;
        pub const min_size_1_12 = StyledM.min_size_1_12;
        pub const min_size_neg_1_12 = StyledM.min_size_neg_1_12;
        pub const min_w = StyledM.min_w;
        pub const min_w_0 = StyledM.min_w_0;
        pub const min_w_neg_0 = StyledM.min_w_neg_0;
        pub const min_w_0p5 = StyledM.min_w_0p5;
        pub const min_w_neg_0p5 = StyledM.min_w_neg_0p5;
        pub const min_w_1 = StyledM.min_w_1;
        pub const min_w_neg_1 = StyledM.min_w_neg_1;
        pub const min_w_1p5 = StyledM.min_w_1p5;
        pub const min_w_neg_1p5 = StyledM.min_w_neg_1p5;
        pub const min_w_2 = StyledM.min_w_2;
        pub const min_w_neg_2 = StyledM.min_w_neg_2;
        pub const min_w_2p5 = StyledM.min_w_2p5;
        pub const min_w_neg_2p5 = StyledM.min_w_neg_2p5;
        pub const min_w_3 = StyledM.min_w_3;
        pub const min_w_neg_3 = StyledM.min_w_neg_3;
        pub const min_w_3p5 = StyledM.min_w_3p5;
        pub const min_w_neg_3p5 = StyledM.min_w_neg_3p5;
        pub const min_w_4 = StyledM.min_w_4;
        pub const min_w_neg_4 = StyledM.min_w_neg_4;
        pub const min_w_5 = StyledM.min_w_5;
        pub const min_w_neg_5 = StyledM.min_w_neg_5;
        pub const min_w_6 = StyledM.min_w_6;
        pub const min_w_neg_6 = StyledM.min_w_neg_6;
        pub const min_w_7 = StyledM.min_w_7;
        pub const min_w_neg_7 = StyledM.min_w_neg_7;
        pub const min_w_8 = StyledM.min_w_8;
        pub const min_w_neg_8 = StyledM.min_w_neg_8;
        pub const min_w_9 = StyledM.min_w_9;
        pub const min_w_neg_9 = StyledM.min_w_neg_9;
        pub const min_w_10 = StyledM.min_w_10;
        pub const min_w_neg_10 = StyledM.min_w_neg_10;
        pub const min_w_11 = StyledM.min_w_11;
        pub const min_w_neg_11 = StyledM.min_w_neg_11;
        pub const min_w_12 = StyledM.min_w_12;
        pub const min_w_neg_12 = StyledM.min_w_neg_12;
        pub const min_w_16 = StyledM.min_w_16;
        pub const min_w_neg_16 = StyledM.min_w_neg_16;
        pub const min_w_20 = StyledM.min_w_20;
        pub const min_w_neg_20 = StyledM.min_w_neg_20;
        pub const min_w_24 = StyledM.min_w_24;
        pub const min_w_neg_24 = StyledM.min_w_neg_24;
        pub const min_w_32 = StyledM.min_w_32;
        pub const min_w_neg_32 = StyledM.min_w_neg_32;
        pub const min_w_40 = StyledM.min_w_40;
        pub const min_w_neg_40 = StyledM.min_w_neg_40;
        pub const min_w_48 = StyledM.min_w_48;
        pub const min_w_neg_48 = StyledM.min_w_neg_48;
        pub const min_w_56 = StyledM.min_w_56;
        pub const min_w_neg_56 = StyledM.min_w_neg_56;
        pub const min_w_64 = StyledM.min_w_64;
        pub const min_w_neg_64 = StyledM.min_w_neg_64;
        pub const min_w_72 = StyledM.min_w_72;
        pub const min_w_neg_72 = StyledM.min_w_neg_72;
        pub const min_w_80 = StyledM.min_w_80;
        pub const min_w_neg_80 = StyledM.min_w_neg_80;
        pub const min_w_96 = StyledM.min_w_96;
        pub const min_w_neg_96 = StyledM.min_w_neg_96;
        pub const min_w_112 = StyledM.min_w_112;
        pub const min_w_neg_112 = StyledM.min_w_neg_112;
        pub const min_w_128 = StyledM.min_w_128;
        pub const min_w_neg_128 = StyledM.min_w_neg_128;
        pub const min_w_auto = StyledM.min_w_auto;
        pub const min_w_px = StyledM.min_w_px;
        pub const min_w_neg_px = StyledM.min_w_neg_px;
        pub const min_w_full = StyledM.min_w_full;
        pub const min_w_neg_full = StyledM.min_w_neg_full;
        pub const min_w_1_2 = StyledM.min_w_1_2;
        pub const min_w_neg_1_2 = StyledM.min_w_neg_1_2;
        pub const min_w_1_3 = StyledM.min_w_1_3;
        pub const min_w_neg_1_3 = StyledM.min_w_neg_1_3;
        pub const min_w_2_3 = StyledM.min_w_2_3;
        pub const min_w_neg_2_3 = StyledM.min_w_neg_2_3;
        pub const min_w_1_4 = StyledM.min_w_1_4;
        pub const min_w_neg_1_4 = StyledM.min_w_neg_1_4;
        pub const min_w_2_4 = StyledM.min_w_2_4;
        pub const min_w_neg_2_4 = StyledM.min_w_neg_2_4;
        pub const min_w_3_4 = StyledM.min_w_3_4;
        pub const min_w_neg_3_4 = StyledM.min_w_neg_3_4;
        pub const min_w_1_5 = StyledM.min_w_1_5;
        pub const min_w_neg_1_5 = StyledM.min_w_neg_1_5;
        pub const min_w_2_5 = StyledM.min_w_2_5;
        pub const min_w_neg_2_5 = StyledM.min_w_neg_2_5;
        pub const min_w_3_5 = StyledM.min_w_3_5;
        pub const min_w_neg_3_5 = StyledM.min_w_neg_3_5;
        pub const min_w_4_5 = StyledM.min_w_4_5;
        pub const min_w_neg_4_5 = StyledM.min_w_neg_4_5;
        pub const min_w_1_6 = StyledM.min_w_1_6;
        pub const min_w_neg_1_6 = StyledM.min_w_neg_1_6;
        pub const min_w_5_6 = StyledM.min_w_5_6;
        pub const min_w_neg_5_6 = StyledM.min_w_neg_5_6;
        pub const min_w_1_12 = StyledM.min_w_1_12;
        pub const min_w_neg_1_12 = StyledM.min_w_neg_1_12;
        pub const min_h = StyledM.min_h;
        pub const min_h_0 = StyledM.min_h_0;
        pub const min_h_neg_0 = StyledM.min_h_neg_0;
        pub const min_h_0p5 = StyledM.min_h_0p5;
        pub const min_h_neg_0p5 = StyledM.min_h_neg_0p5;
        pub const min_h_1 = StyledM.min_h_1;
        pub const min_h_neg_1 = StyledM.min_h_neg_1;
        pub const min_h_1p5 = StyledM.min_h_1p5;
        pub const min_h_neg_1p5 = StyledM.min_h_neg_1p5;
        pub const min_h_2 = StyledM.min_h_2;
        pub const min_h_neg_2 = StyledM.min_h_neg_2;
        pub const min_h_2p5 = StyledM.min_h_2p5;
        pub const min_h_neg_2p5 = StyledM.min_h_neg_2p5;
        pub const min_h_3 = StyledM.min_h_3;
        pub const min_h_neg_3 = StyledM.min_h_neg_3;
        pub const min_h_3p5 = StyledM.min_h_3p5;
        pub const min_h_neg_3p5 = StyledM.min_h_neg_3p5;
        pub const min_h_4 = StyledM.min_h_4;
        pub const min_h_neg_4 = StyledM.min_h_neg_4;
        pub const min_h_5 = StyledM.min_h_5;
        pub const min_h_neg_5 = StyledM.min_h_neg_5;
        pub const min_h_6 = StyledM.min_h_6;
        pub const min_h_neg_6 = StyledM.min_h_neg_6;
        pub const min_h_7 = StyledM.min_h_7;
        pub const min_h_neg_7 = StyledM.min_h_neg_7;
        pub const min_h_8 = StyledM.min_h_8;
        pub const min_h_neg_8 = StyledM.min_h_neg_8;
        pub const min_h_9 = StyledM.min_h_9;
        pub const min_h_neg_9 = StyledM.min_h_neg_9;
        pub const min_h_10 = StyledM.min_h_10;
        pub const min_h_neg_10 = StyledM.min_h_neg_10;
        pub const min_h_11 = StyledM.min_h_11;
        pub const min_h_neg_11 = StyledM.min_h_neg_11;
        pub const min_h_12 = StyledM.min_h_12;
        pub const min_h_neg_12 = StyledM.min_h_neg_12;
        pub const min_h_16 = StyledM.min_h_16;
        pub const min_h_neg_16 = StyledM.min_h_neg_16;
        pub const min_h_20 = StyledM.min_h_20;
        pub const min_h_neg_20 = StyledM.min_h_neg_20;
        pub const min_h_24 = StyledM.min_h_24;
        pub const min_h_neg_24 = StyledM.min_h_neg_24;
        pub const min_h_32 = StyledM.min_h_32;
        pub const min_h_neg_32 = StyledM.min_h_neg_32;
        pub const min_h_40 = StyledM.min_h_40;
        pub const min_h_neg_40 = StyledM.min_h_neg_40;
        pub const min_h_48 = StyledM.min_h_48;
        pub const min_h_neg_48 = StyledM.min_h_neg_48;
        pub const min_h_56 = StyledM.min_h_56;
        pub const min_h_neg_56 = StyledM.min_h_neg_56;
        pub const min_h_64 = StyledM.min_h_64;
        pub const min_h_neg_64 = StyledM.min_h_neg_64;
        pub const min_h_72 = StyledM.min_h_72;
        pub const min_h_neg_72 = StyledM.min_h_neg_72;
        pub const min_h_80 = StyledM.min_h_80;
        pub const min_h_neg_80 = StyledM.min_h_neg_80;
        pub const min_h_96 = StyledM.min_h_96;
        pub const min_h_neg_96 = StyledM.min_h_neg_96;
        pub const min_h_112 = StyledM.min_h_112;
        pub const min_h_neg_112 = StyledM.min_h_neg_112;
        pub const min_h_128 = StyledM.min_h_128;
        pub const min_h_neg_128 = StyledM.min_h_neg_128;
        pub const min_h_auto = StyledM.min_h_auto;
        pub const min_h_px = StyledM.min_h_px;
        pub const min_h_neg_px = StyledM.min_h_neg_px;
        pub const min_h_full = StyledM.min_h_full;
        pub const min_h_neg_full = StyledM.min_h_neg_full;
        pub const min_h_1_2 = StyledM.min_h_1_2;
        pub const min_h_neg_1_2 = StyledM.min_h_neg_1_2;
        pub const min_h_1_3 = StyledM.min_h_1_3;
        pub const min_h_neg_1_3 = StyledM.min_h_neg_1_3;
        pub const min_h_2_3 = StyledM.min_h_2_3;
        pub const min_h_neg_2_3 = StyledM.min_h_neg_2_3;
        pub const min_h_1_4 = StyledM.min_h_1_4;
        pub const min_h_neg_1_4 = StyledM.min_h_neg_1_4;
        pub const min_h_2_4 = StyledM.min_h_2_4;
        pub const min_h_neg_2_4 = StyledM.min_h_neg_2_4;
        pub const min_h_3_4 = StyledM.min_h_3_4;
        pub const min_h_neg_3_4 = StyledM.min_h_neg_3_4;
        pub const min_h_1_5 = StyledM.min_h_1_5;
        pub const min_h_neg_1_5 = StyledM.min_h_neg_1_5;
        pub const min_h_2_5 = StyledM.min_h_2_5;
        pub const min_h_neg_2_5 = StyledM.min_h_neg_2_5;
        pub const min_h_3_5 = StyledM.min_h_3_5;
        pub const min_h_neg_3_5 = StyledM.min_h_neg_3_5;
        pub const min_h_4_5 = StyledM.min_h_4_5;
        pub const min_h_neg_4_5 = StyledM.min_h_neg_4_5;
        pub const min_h_1_6 = StyledM.min_h_1_6;
        pub const min_h_neg_1_6 = StyledM.min_h_neg_1_6;
        pub const min_h_5_6 = StyledM.min_h_5_6;
        pub const min_h_neg_5_6 = StyledM.min_h_neg_5_6;
        pub const min_h_1_12 = StyledM.min_h_1_12;
        pub const min_h_neg_1_12 = StyledM.min_h_neg_1_12;
        pub const max_size = StyledM.max_size;
        pub const max_size_0 = StyledM.max_size_0;
        pub const max_size_neg_0 = StyledM.max_size_neg_0;
        pub const max_size_0p5 = StyledM.max_size_0p5;
        pub const max_size_neg_0p5 = StyledM.max_size_neg_0p5;
        pub const max_size_1 = StyledM.max_size_1;
        pub const max_size_neg_1 = StyledM.max_size_neg_1;
        pub const max_size_1p5 = StyledM.max_size_1p5;
        pub const max_size_neg_1p5 = StyledM.max_size_neg_1p5;
        pub const max_size_2 = StyledM.max_size_2;
        pub const max_size_neg_2 = StyledM.max_size_neg_2;
        pub const max_size_2p5 = StyledM.max_size_2p5;
        pub const max_size_neg_2p5 = StyledM.max_size_neg_2p5;
        pub const max_size_3 = StyledM.max_size_3;
        pub const max_size_neg_3 = StyledM.max_size_neg_3;
        pub const max_size_3p5 = StyledM.max_size_3p5;
        pub const max_size_neg_3p5 = StyledM.max_size_neg_3p5;
        pub const max_size_4 = StyledM.max_size_4;
        pub const max_size_neg_4 = StyledM.max_size_neg_4;
        pub const max_size_5 = StyledM.max_size_5;
        pub const max_size_neg_5 = StyledM.max_size_neg_5;
        pub const max_size_6 = StyledM.max_size_6;
        pub const max_size_neg_6 = StyledM.max_size_neg_6;
        pub const max_size_7 = StyledM.max_size_7;
        pub const max_size_neg_7 = StyledM.max_size_neg_7;
        pub const max_size_8 = StyledM.max_size_8;
        pub const max_size_neg_8 = StyledM.max_size_neg_8;
        pub const max_size_9 = StyledM.max_size_9;
        pub const max_size_neg_9 = StyledM.max_size_neg_9;
        pub const max_size_10 = StyledM.max_size_10;
        pub const max_size_neg_10 = StyledM.max_size_neg_10;
        pub const max_size_11 = StyledM.max_size_11;
        pub const max_size_neg_11 = StyledM.max_size_neg_11;
        pub const max_size_12 = StyledM.max_size_12;
        pub const max_size_neg_12 = StyledM.max_size_neg_12;
        pub const max_size_16 = StyledM.max_size_16;
        pub const max_size_neg_16 = StyledM.max_size_neg_16;
        pub const max_size_20 = StyledM.max_size_20;
        pub const max_size_neg_20 = StyledM.max_size_neg_20;
        pub const max_size_24 = StyledM.max_size_24;
        pub const max_size_neg_24 = StyledM.max_size_neg_24;
        pub const max_size_32 = StyledM.max_size_32;
        pub const max_size_neg_32 = StyledM.max_size_neg_32;
        pub const max_size_40 = StyledM.max_size_40;
        pub const max_size_neg_40 = StyledM.max_size_neg_40;
        pub const max_size_48 = StyledM.max_size_48;
        pub const max_size_neg_48 = StyledM.max_size_neg_48;
        pub const max_size_56 = StyledM.max_size_56;
        pub const max_size_neg_56 = StyledM.max_size_neg_56;
        pub const max_size_64 = StyledM.max_size_64;
        pub const max_size_neg_64 = StyledM.max_size_neg_64;
        pub const max_size_72 = StyledM.max_size_72;
        pub const max_size_neg_72 = StyledM.max_size_neg_72;
        pub const max_size_80 = StyledM.max_size_80;
        pub const max_size_neg_80 = StyledM.max_size_neg_80;
        pub const max_size_96 = StyledM.max_size_96;
        pub const max_size_neg_96 = StyledM.max_size_neg_96;
        pub const max_size_112 = StyledM.max_size_112;
        pub const max_size_neg_112 = StyledM.max_size_neg_112;
        pub const max_size_128 = StyledM.max_size_128;
        pub const max_size_neg_128 = StyledM.max_size_neg_128;
        pub const max_size_auto = StyledM.max_size_auto;
        pub const max_size_px = StyledM.max_size_px;
        pub const max_size_neg_px = StyledM.max_size_neg_px;
        pub const max_size_full = StyledM.max_size_full;
        pub const max_size_neg_full = StyledM.max_size_neg_full;
        pub const max_size_1_2 = StyledM.max_size_1_2;
        pub const max_size_neg_1_2 = StyledM.max_size_neg_1_2;
        pub const max_size_1_3 = StyledM.max_size_1_3;
        pub const max_size_neg_1_3 = StyledM.max_size_neg_1_3;
        pub const max_size_2_3 = StyledM.max_size_2_3;
        pub const max_size_neg_2_3 = StyledM.max_size_neg_2_3;
        pub const max_size_1_4 = StyledM.max_size_1_4;
        pub const max_size_neg_1_4 = StyledM.max_size_neg_1_4;
        pub const max_size_2_4 = StyledM.max_size_2_4;
        pub const max_size_neg_2_4 = StyledM.max_size_neg_2_4;
        pub const max_size_3_4 = StyledM.max_size_3_4;
        pub const max_size_neg_3_4 = StyledM.max_size_neg_3_4;
        pub const max_size_1_5 = StyledM.max_size_1_5;
        pub const max_size_neg_1_5 = StyledM.max_size_neg_1_5;
        pub const max_size_2_5 = StyledM.max_size_2_5;
        pub const max_size_neg_2_5 = StyledM.max_size_neg_2_5;
        pub const max_size_3_5 = StyledM.max_size_3_5;
        pub const max_size_neg_3_5 = StyledM.max_size_neg_3_5;
        pub const max_size_4_5 = StyledM.max_size_4_5;
        pub const max_size_neg_4_5 = StyledM.max_size_neg_4_5;
        pub const max_size_1_6 = StyledM.max_size_1_6;
        pub const max_size_neg_1_6 = StyledM.max_size_neg_1_6;
        pub const max_size_5_6 = StyledM.max_size_5_6;
        pub const max_size_neg_5_6 = StyledM.max_size_neg_5_6;
        pub const max_size_1_12 = StyledM.max_size_1_12;
        pub const max_size_neg_1_12 = StyledM.max_size_neg_1_12;
        pub const max_w = StyledM.max_w;
        pub const max_w_0 = StyledM.max_w_0;
        pub const max_w_neg_0 = StyledM.max_w_neg_0;
        pub const max_w_0p5 = StyledM.max_w_0p5;
        pub const max_w_neg_0p5 = StyledM.max_w_neg_0p5;
        pub const max_w_1 = StyledM.max_w_1;
        pub const max_w_neg_1 = StyledM.max_w_neg_1;
        pub const max_w_1p5 = StyledM.max_w_1p5;
        pub const max_w_neg_1p5 = StyledM.max_w_neg_1p5;
        pub const max_w_2 = StyledM.max_w_2;
        pub const max_w_neg_2 = StyledM.max_w_neg_2;
        pub const max_w_2p5 = StyledM.max_w_2p5;
        pub const max_w_neg_2p5 = StyledM.max_w_neg_2p5;
        pub const max_w_3 = StyledM.max_w_3;
        pub const max_w_neg_3 = StyledM.max_w_neg_3;
        pub const max_w_3p5 = StyledM.max_w_3p5;
        pub const max_w_neg_3p5 = StyledM.max_w_neg_3p5;
        pub const max_w_4 = StyledM.max_w_4;
        pub const max_w_neg_4 = StyledM.max_w_neg_4;
        pub const max_w_5 = StyledM.max_w_5;
        pub const max_w_neg_5 = StyledM.max_w_neg_5;
        pub const max_w_6 = StyledM.max_w_6;
        pub const max_w_neg_6 = StyledM.max_w_neg_6;
        pub const max_w_7 = StyledM.max_w_7;
        pub const max_w_neg_7 = StyledM.max_w_neg_7;
        pub const max_w_8 = StyledM.max_w_8;
        pub const max_w_neg_8 = StyledM.max_w_neg_8;
        pub const max_w_9 = StyledM.max_w_9;
        pub const max_w_neg_9 = StyledM.max_w_neg_9;
        pub const max_w_10 = StyledM.max_w_10;
        pub const max_w_neg_10 = StyledM.max_w_neg_10;
        pub const max_w_11 = StyledM.max_w_11;
        pub const max_w_neg_11 = StyledM.max_w_neg_11;
        pub const max_w_12 = StyledM.max_w_12;
        pub const max_w_neg_12 = StyledM.max_w_neg_12;
        pub const max_w_16 = StyledM.max_w_16;
        pub const max_w_neg_16 = StyledM.max_w_neg_16;
        pub const max_w_20 = StyledM.max_w_20;
        pub const max_w_neg_20 = StyledM.max_w_neg_20;
        pub const max_w_24 = StyledM.max_w_24;
        pub const max_w_neg_24 = StyledM.max_w_neg_24;
        pub const max_w_32 = StyledM.max_w_32;
        pub const max_w_neg_32 = StyledM.max_w_neg_32;
        pub const max_w_40 = StyledM.max_w_40;
        pub const max_w_neg_40 = StyledM.max_w_neg_40;
        pub const max_w_48 = StyledM.max_w_48;
        pub const max_w_neg_48 = StyledM.max_w_neg_48;
        pub const max_w_56 = StyledM.max_w_56;
        pub const max_w_neg_56 = StyledM.max_w_neg_56;
        pub const max_w_64 = StyledM.max_w_64;
        pub const max_w_neg_64 = StyledM.max_w_neg_64;
        pub const max_w_72 = StyledM.max_w_72;
        pub const max_w_neg_72 = StyledM.max_w_neg_72;
        pub const max_w_80 = StyledM.max_w_80;
        pub const max_w_neg_80 = StyledM.max_w_neg_80;
        pub const max_w_96 = StyledM.max_w_96;
        pub const max_w_neg_96 = StyledM.max_w_neg_96;
        pub const max_w_112 = StyledM.max_w_112;
        pub const max_w_neg_112 = StyledM.max_w_neg_112;
        pub const max_w_128 = StyledM.max_w_128;
        pub const max_w_neg_128 = StyledM.max_w_neg_128;
        pub const max_w_auto = StyledM.max_w_auto;
        pub const max_w_px = StyledM.max_w_px;
        pub const max_w_neg_px = StyledM.max_w_neg_px;
        pub const max_w_full = StyledM.max_w_full;
        pub const max_w_neg_full = StyledM.max_w_neg_full;
        pub const max_w_1_2 = StyledM.max_w_1_2;
        pub const max_w_neg_1_2 = StyledM.max_w_neg_1_2;
        pub const max_w_1_3 = StyledM.max_w_1_3;
        pub const max_w_neg_1_3 = StyledM.max_w_neg_1_3;
        pub const max_w_2_3 = StyledM.max_w_2_3;
        pub const max_w_neg_2_3 = StyledM.max_w_neg_2_3;
        pub const max_w_1_4 = StyledM.max_w_1_4;
        pub const max_w_neg_1_4 = StyledM.max_w_neg_1_4;
        pub const max_w_2_4 = StyledM.max_w_2_4;
        pub const max_w_neg_2_4 = StyledM.max_w_neg_2_4;
        pub const max_w_3_4 = StyledM.max_w_3_4;
        pub const max_w_neg_3_4 = StyledM.max_w_neg_3_4;
        pub const max_w_1_5 = StyledM.max_w_1_5;
        pub const max_w_neg_1_5 = StyledM.max_w_neg_1_5;
        pub const max_w_2_5 = StyledM.max_w_2_5;
        pub const max_w_neg_2_5 = StyledM.max_w_neg_2_5;
        pub const max_w_3_5 = StyledM.max_w_3_5;
        pub const max_w_neg_3_5 = StyledM.max_w_neg_3_5;
        pub const max_w_4_5 = StyledM.max_w_4_5;
        pub const max_w_neg_4_5 = StyledM.max_w_neg_4_5;
        pub const max_w_1_6 = StyledM.max_w_1_6;
        pub const max_w_neg_1_6 = StyledM.max_w_neg_1_6;
        pub const max_w_5_6 = StyledM.max_w_5_6;
        pub const max_w_neg_5_6 = StyledM.max_w_neg_5_6;
        pub const max_w_1_12 = StyledM.max_w_1_12;
        pub const max_w_neg_1_12 = StyledM.max_w_neg_1_12;
        pub const max_h = StyledM.max_h;
        pub const max_h_0 = StyledM.max_h_0;
        pub const max_h_neg_0 = StyledM.max_h_neg_0;
        pub const max_h_0p5 = StyledM.max_h_0p5;
        pub const max_h_neg_0p5 = StyledM.max_h_neg_0p5;
        pub const max_h_1 = StyledM.max_h_1;
        pub const max_h_neg_1 = StyledM.max_h_neg_1;
        pub const max_h_1p5 = StyledM.max_h_1p5;
        pub const max_h_neg_1p5 = StyledM.max_h_neg_1p5;
        pub const max_h_2 = StyledM.max_h_2;
        pub const max_h_neg_2 = StyledM.max_h_neg_2;
        pub const max_h_2p5 = StyledM.max_h_2p5;
        pub const max_h_neg_2p5 = StyledM.max_h_neg_2p5;
        pub const max_h_3 = StyledM.max_h_3;
        pub const max_h_neg_3 = StyledM.max_h_neg_3;
        pub const max_h_3p5 = StyledM.max_h_3p5;
        pub const max_h_neg_3p5 = StyledM.max_h_neg_3p5;
        pub const max_h_4 = StyledM.max_h_4;
        pub const max_h_neg_4 = StyledM.max_h_neg_4;
        pub const max_h_5 = StyledM.max_h_5;
        pub const max_h_neg_5 = StyledM.max_h_neg_5;
        pub const max_h_6 = StyledM.max_h_6;
        pub const max_h_neg_6 = StyledM.max_h_neg_6;
        pub const max_h_7 = StyledM.max_h_7;
        pub const max_h_neg_7 = StyledM.max_h_neg_7;
        pub const max_h_8 = StyledM.max_h_8;
        pub const max_h_neg_8 = StyledM.max_h_neg_8;
        pub const max_h_9 = StyledM.max_h_9;
        pub const max_h_neg_9 = StyledM.max_h_neg_9;
        pub const max_h_10 = StyledM.max_h_10;
        pub const max_h_neg_10 = StyledM.max_h_neg_10;
        pub const max_h_11 = StyledM.max_h_11;
        pub const max_h_neg_11 = StyledM.max_h_neg_11;
        pub const max_h_12 = StyledM.max_h_12;
        pub const max_h_neg_12 = StyledM.max_h_neg_12;
        pub const max_h_16 = StyledM.max_h_16;
        pub const max_h_neg_16 = StyledM.max_h_neg_16;
        pub const max_h_20 = StyledM.max_h_20;
        pub const max_h_neg_20 = StyledM.max_h_neg_20;
        pub const max_h_24 = StyledM.max_h_24;
        pub const max_h_neg_24 = StyledM.max_h_neg_24;
        pub const max_h_32 = StyledM.max_h_32;
        pub const max_h_neg_32 = StyledM.max_h_neg_32;
        pub const max_h_40 = StyledM.max_h_40;
        pub const max_h_neg_40 = StyledM.max_h_neg_40;
        pub const max_h_48 = StyledM.max_h_48;
        pub const max_h_neg_48 = StyledM.max_h_neg_48;
        pub const max_h_56 = StyledM.max_h_56;
        pub const max_h_neg_56 = StyledM.max_h_neg_56;
        pub const max_h_64 = StyledM.max_h_64;
        pub const max_h_neg_64 = StyledM.max_h_neg_64;
        pub const max_h_72 = StyledM.max_h_72;
        pub const max_h_neg_72 = StyledM.max_h_neg_72;
        pub const max_h_80 = StyledM.max_h_80;
        pub const max_h_neg_80 = StyledM.max_h_neg_80;
        pub const max_h_96 = StyledM.max_h_96;
        pub const max_h_neg_96 = StyledM.max_h_neg_96;
        pub const max_h_112 = StyledM.max_h_112;
        pub const max_h_neg_112 = StyledM.max_h_neg_112;
        pub const max_h_128 = StyledM.max_h_128;
        pub const max_h_neg_128 = StyledM.max_h_neg_128;
        pub const max_h_auto = StyledM.max_h_auto;
        pub const max_h_px = StyledM.max_h_px;
        pub const max_h_neg_px = StyledM.max_h_neg_px;
        pub const max_h_full = StyledM.max_h_full;
        pub const max_h_neg_full = StyledM.max_h_neg_full;
        pub const max_h_1_2 = StyledM.max_h_1_2;
        pub const max_h_neg_1_2 = StyledM.max_h_neg_1_2;
        pub const max_h_1_3 = StyledM.max_h_1_3;
        pub const max_h_neg_1_3 = StyledM.max_h_neg_1_3;
        pub const max_h_2_3 = StyledM.max_h_2_3;
        pub const max_h_neg_2_3 = StyledM.max_h_neg_2_3;
        pub const max_h_1_4 = StyledM.max_h_1_4;
        pub const max_h_neg_1_4 = StyledM.max_h_neg_1_4;
        pub const max_h_2_4 = StyledM.max_h_2_4;
        pub const max_h_neg_2_4 = StyledM.max_h_neg_2_4;
        pub const max_h_3_4 = StyledM.max_h_3_4;
        pub const max_h_neg_3_4 = StyledM.max_h_neg_3_4;
        pub const max_h_1_5 = StyledM.max_h_1_5;
        pub const max_h_neg_1_5 = StyledM.max_h_neg_1_5;
        pub const max_h_2_5 = StyledM.max_h_2_5;
        pub const max_h_neg_2_5 = StyledM.max_h_neg_2_5;
        pub const max_h_3_5 = StyledM.max_h_3_5;
        pub const max_h_neg_3_5 = StyledM.max_h_neg_3_5;
        pub const max_h_4_5 = StyledM.max_h_4_5;
        pub const max_h_neg_4_5 = StyledM.max_h_neg_4_5;
        pub const max_h_1_6 = StyledM.max_h_1_6;
        pub const max_h_neg_1_6 = StyledM.max_h_neg_1_6;
        pub const max_h_5_6 = StyledM.max_h_5_6;
        pub const max_h_neg_5_6 = StyledM.max_h_neg_5_6;
        pub const max_h_1_12 = StyledM.max_h_1_12;
        pub const max_h_neg_1_12 = StyledM.max_h_neg_1_12;
        pub const gap = StyledM.gap;
        pub const gap_0 = StyledM.gap_0;
        pub const gap_neg_0 = StyledM.gap_neg_0;
        pub const gap_0p5 = StyledM.gap_0p5;
        pub const gap_neg_0p5 = StyledM.gap_neg_0p5;
        pub const gap_1 = StyledM.gap_1;
        pub const gap_neg_1 = StyledM.gap_neg_1;
        pub const gap_1p5 = StyledM.gap_1p5;
        pub const gap_neg_1p5 = StyledM.gap_neg_1p5;
        pub const gap_2 = StyledM.gap_2;
        pub const gap_neg_2 = StyledM.gap_neg_2;
        pub const gap_2p5 = StyledM.gap_2p5;
        pub const gap_neg_2p5 = StyledM.gap_neg_2p5;
        pub const gap_3 = StyledM.gap_3;
        pub const gap_neg_3 = StyledM.gap_neg_3;
        pub const gap_3p5 = StyledM.gap_3p5;
        pub const gap_neg_3p5 = StyledM.gap_neg_3p5;
        pub const gap_4 = StyledM.gap_4;
        pub const gap_neg_4 = StyledM.gap_neg_4;
        pub const gap_5 = StyledM.gap_5;
        pub const gap_neg_5 = StyledM.gap_neg_5;
        pub const gap_6 = StyledM.gap_6;
        pub const gap_neg_6 = StyledM.gap_neg_6;
        pub const gap_7 = StyledM.gap_7;
        pub const gap_neg_7 = StyledM.gap_neg_7;
        pub const gap_8 = StyledM.gap_8;
        pub const gap_neg_8 = StyledM.gap_neg_8;
        pub const gap_9 = StyledM.gap_9;
        pub const gap_neg_9 = StyledM.gap_neg_9;
        pub const gap_10 = StyledM.gap_10;
        pub const gap_neg_10 = StyledM.gap_neg_10;
        pub const gap_11 = StyledM.gap_11;
        pub const gap_neg_11 = StyledM.gap_neg_11;
        pub const gap_12 = StyledM.gap_12;
        pub const gap_neg_12 = StyledM.gap_neg_12;
        pub const gap_16 = StyledM.gap_16;
        pub const gap_neg_16 = StyledM.gap_neg_16;
        pub const gap_20 = StyledM.gap_20;
        pub const gap_neg_20 = StyledM.gap_neg_20;
        pub const gap_24 = StyledM.gap_24;
        pub const gap_neg_24 = StyledM.gap_neg_24;
        pub const gap_32 = StyledM.gap_32;
        pub const gap_neg_32 = StyledM.gap_neg_32;
        pub const gap_40 = StyledM.gap_40;
        pub const gap_neg_40 = StyledM.gap_neg_40;
        pub const gap_48 = StyledM.gap_48;
        pub const gap_neg_48 = StyledM.gap_neg_48;
        pub const gap_56 = StyledM.gap_56;
        pub const gap_neg_56 = StyledM.gap_neg_56;
        pub const gap_64 = StyledM.gap_64;
        pub const gap_neg_64 = StyledM.gap_neg_64;
        pub const gap_72 = StyledM.gap_72;
        pub const gap_neg_72 = StyledM.gap_neg_72;
        pub const gap_80 = StyledM.gap_80;
        pub const gap_neg_80 = StyledM.gap_neg_80;
        pub const gap_96 = StyledM.gap_96;
        pub const gap_neg_96 = StyledM.gap_neg_96;
        pub const gap_112 = StyledM.gap_112;
        pub const gap_neg_112 = StyledM.gap_neg_112;
        pub const gap_128 = StyledM.gap_128;
        pub const gap_neg_128 = StyledM.gap_neg_128;
        pub const gap_px = StyledM.gap_px;
        pub const gap_neg_px = StyledM.gap_neg_px;
        pub const gap_full = StyledM.gap_full;
        pub const gap_neg_full = StyledM.gap_neg_full;
        pub const gap_1_2 = StyledM.gap_1_2;
        pub const gap_neg_1_2 = StyledM.gap_neg_1_2;
        pub const gap_1_3 = StyledM.gap_1_3;
        pub const gap_neg_1_3 = StyledM.gap_neg_1_3;
        pub const gap_2_3 = StyledM.gap_2_3;
        pub const gap_neg_2_3 = StyledM.gap_neg_2_3;
        pub const gap_1_4 = StyledM.gap_1_4;
        pub const gap_neg_1_4 = StyledM.gap_neg_1_4;
        pub const gap_2_4 = StyledM.gap_2_4;
        pub const gap_neg_2_4 = StyledM.gap_neg_2_4;
        pub const gap_3_4 = StyledM.gap_3_4;
        pub const gap_neg_3_4 = StyledM.gap_neg_3_4;
        pub const gap_1_5 = StyledM.gap_1_5;
        pub const gap_neg_1_5 = StyledM.gap_neg_1_5;
        pub const gap_2_5 = StyledM.gap_2_5;
        pub const gap_neg_2_5 = StyledM.gap_neg_2_5;
        pub const gap_3_5 = StyledM.gap_3_5;
        pub const gap_neg_3_5 = StyledM.gap_neg_3_5;
        pub const gap_4_5 = StyledM.gap_4_5;
        pub const gap_neg_4_5 = StyledM.gap_neg_4_5;
        pub const gap_1_6 = StyledM.gap_1_6;
        pub const gap_neg_1_6 = StyledM.gap_neg_1_6;
        pub const gap_5_6 = StyledM.gap_5_6;
        pub const gap_neg_5_6 = StyledM.gap_neg_5_6;
        pub const gap_1_12 = StyledM.gap_1_12;
        pub const gap_neg_1_12 = StyledM.gap_neg_1_12;
        pub const gap_x = StyledM.gap_x;
        pub const gap_x_0 = StyledM.gap_x_0;
        pub const gap_x_neg_0 = StyledM.gap_x_neg_0;
        pub const gap_x_0p5 = StyledM.gap_x_0p5;
        pub const gap_x_neg_0p5 = StyledM.gap_x_neg_0p5;
        pub const gap_x_1 = StyledM.gap_x_1;
        pub const gap_x_neg_1 = StyledM.gap_x_neg_1;
        pub const gap_x_1p5 = StyledM.gap_x_1p5;
        pub const gap_x_neg_1p5 = StyledM.gap_x_neg_1p5;
        pub const gap_x_2 = StyledM.gap_x_2;
        pub const gap_x_neg_2 = StyledM.gap_x_neg_2;
        pub const gap_x_2p5 = StyledM.gap_x_2p5;
        pub const gap_x_neg_2p5 = StyledM.gap_x_neg_2p5;
        pub const gap_x_3 = StyledM.gap_x_3;
        pub const gap_x_neg_3 = StyledM.gap_x_neg_3;
        pub const gap_x_3p5 = StyledM.gap_x_3p5;
        pub const gap_x_neg_3p5 = StyledM.gap_x_neg_3p5;
        pub const gap_x_4 = StyledM.gap_x_4;
        pub const gap_x_neg_4 = StyledM.gap_x_neg_4;
        pub const gap_x_5 = StyledM.gap_x_5;
        pub const gap_x_neg_5 = StyledM.gap_x_neg_5;
        pub const gap_x_6 = StyledM.gap_x_6;
        pub const gap_x_neg_6 = StyledM.gap_x_neg_6;
        pub const gap_x_7 = StyledM.gap_x_7;
        pub const gap_x_neg_7 = StyledM.gap_x_neg_7;
        pub const gap_x_8 = StyledM.gap_x_8;
        pub const gap_x_neg_8 = StyledM.gap_x_neg_8;
        pub const gap_x_9 = StyledM.gap_x_9;
        pub const gap_x_neg_9 = StyledM.gap_x_neg_9;
        pub const gap_x_10 = StyledM.gap_x_10;
        pub const gap_x_neg_10 = StyledM.gap_x_neg_10;
        pub const gap_x_11 = StyledM.gap_x_11;
        pub const gap_x_neg_11 = StyledM.gap_x_neg_11;
        pub const gap_x_12 = StyledM.gap_x_12;
        pub const gap_x_neg_12 = StyledM.gap_x_neg_12;
        pub const gap_x_16 = StyledM.gap_x_16;
        pub const gap_x_neg_16 = StyledM.gap_x_neg_16;
        pub const gap_x_20 = StyledM.gap_x_20;
        pub const gap_x_neg_20 = StyledM.gap_x_neg_20;
        pub const gap_x_24 = StyledM.gap_x_24;
        pub const gap_x_neg_24 = StyledM.gap_x_neg_24;
        pub const gap_x_32 = StyledM.gap_x_32;
        pub const gap_x_neg_32 = StyledM.gap_x_neg_32;
        pub const gap_x_40 = StyledM.gap_x_40;
        pub const gap_x_neg_40 = StyledM.gap_x_neg_40;
        pub const gap_x_48 = StyledM.gap_x_48;
        pub const gap_x_neg_48 = StyledM.gap_x_neg_48;
        pub const gap_x_56 = StyledM.gap_x_56;
        pub const gap_x_neg_56 = StyledM.gap_x_neg_56;
        pub const gap_x_64 = StyledM.gap_x_64;
        pub const gap_x_neg_64 = StyledM.gap_x_neg_64;
        pub const gap_x_72 = StyledM.gap_x_72;
        pub const gap_x_neg_72 = StyledM.gap_x_neg_72;
        pub const gap_x_80 = StyledM.gap_x_80;
        pub const gap_x_neg_80 = StyledM.gap_x_neg_80;
        pub const gap_x_96 = StyledM.gap_x_96;
        pub const gap_x_neg_96 = StyledM.gap_x_neg_96;
        pub const gap_x_112 = StyledM.gap_x_112;
        pub const gap_x_neg_112 = StyledM.gap_x_neg_112;
        pub const gap_x_128 = StyledM.gap_x_128;
        pub const gap_x_neg_128 = StyledM.gap_x_neg_128;
        pub const gap_x_px = StyledM.gap_x_px;
        pub const gap_x_neg_px = StyledM.gap_x_neg_px;
        pub const gap_x_full = StyledM.gap_x_full;
        pub const gap_x_neg_full = StyledM.gap_x_neg_full;
        pub const gap_x_1_2 = StyledM.gap_x_1_2;
        pub const gap_x_neg_1_2 = StyledM.gap_x_neg_1_2;
        pub const gap_x_1_3 = StyledM.gap_x_1_3;
        pub const gap_x_neg_1_3 = StyledM.gap_x_neg_1_3;
        pub const gap_x_2_3 = StyledM.gap_x_2_3;
        pub const gap_x_neg_2_3 = StyledM.gap_x_neg_2_3;
        pub const gap_x_1_4 = StyledM.gap_x_1_4;
        pub const gap_x_neg_1_4 = StyledM.gap_x_neg_1_4;
        pub const gap_x_2_4 = StyledM.gap_x_2_4;
        pub const gap_x_neg_2_4 = StyledM.gap_x_neg_2_4;
        pub const gap_x_3_4 = StyledM.gap_x_3_4;
        pub const gap_x_neg_3_4 = StyledM.gap_x_neg_3_4;
        pub const gap_x_1_5 = StyledM.gap_x_1_5;
        pub const gap_x_neg_1_5 = StyledM.gap_x_neg_1_5;
        pub const gap_x_2_5 = StyledM.gap_x_2_5;
        pub const gap_x_neg_2_5 = StyledM.gap_x_neg_2_5;
        pub const gap_x_3_5 = StyledM.gap_x_3_5;
        pub const gap_x_neg_3_5 = StyledM.gap_x_neg_3_5;
        pub const gap_x_4_5 = StyledM.gap_x_4_5;
        pub const gap_x_neg_4_5 = StyledM.gap_x_neg_4_5;
        pub const gap_x_1_6 = StyledM.gap_x_1_6;
        pub const gap_x_neg_1_6 = StyledM.gap_x_neg_1_6;
        pub const gap_x_5_6 = StyledM.gap_x_5_6;
        pub const gap_x_neg_5_6 = StyledM.gap_x_neg_5_6;
        pub const gap_x_1_12 = StyledM.gap_x_1_12;
        pub const gap_x_neg_1_12 = StyledM.gap_x_neg_1_12;
        pub const gap_y = StyledM.gap_y;
        pub const gap_y_0 = StyledM.gap_y_0;
        pub const gap_y_neg_0 = StyledM.gap_y_neg_0;
        pub const gap_y_0p5 = StyledM.gap_y_0p5;
        pub const gap_y_neg_0p5 = StyledM.gap_y_neg_0p5;
        pub const gap_y_1 = StyledM.gap_y_1;
        pub const gap_y_neg_1 = StyledM.gap_y_neg_1;
        pub const gap_y_1p5 = StyledM.gap_y_1p5;
        pub const gap_y_neg_1p5 = StyledM.gap_y_neg_1p5;
        pub const gap_y_2 = StyledM.gap_y_2;
        pub const gap_y_neg_2 = StyledM.gap_y_neg_2;
        pub const gap_y_2p5 = StyledM.gap_y_2p5;
        pub const gap_y_neg_2p5 = StyledM.gap_y_neg_2p5;
        pub const gap_y_3 = StyledM.gap_y_3;
        pub const gap_y_neg_3 = StyledM.gap_y_neg_3;
        pub const gap_y_3p5 = StyledM.gap_y_3p5;
        pub const gap_y_neg_3p5 = StyledM.gap_y_neg_3p5;
        pub const gap_y_4 = StyledM.gap_y_4;
        pub const gap_y_neg_4 = StyledM.gap_y_neg_4;
        pub const gap_y_5 = StyledM.gap_y_5;
        pub const gap_y_neg_5 = StyledM.gap_y_neg_5;
        pub const gap_y_6 = StyledM.gap_y_6;
        pub const gap_y_neg_6 = StyledM.gap_y_neg_6;
        pub const gap_y_7 = StyledM.gap_y_7;
        pub const gap_y_neg_7 = StyledM.gap_y_neg_7;
        pub const gap_y_8 = StyledM.gap_y_8;
        pub const gap_y_neg_8 = StyledM.gap_y_neg_8;
        pub const gap_y_9 = StyledM.gap_y_9;
        pub const gap_y_neg_9 = StyledM.gap_y_neg_9;
        pub const gap_y_10 = StyledM.gap_y_10;
        pub const gap_y_neg_10 = StyledM.gap_y_neg_10;
        pub const gap_y_11 = StyledM.gap_y_11;
        pub const gap_y_neg_11 = StyledM.gap_y_neg_11;
        pub const gap_y_12 = StyledM.gap_y_12;
        pub const gap_y_neg_12 = StyledM.gap_y_neg_12;
        pub const gap_y_16 = StyledM.gap_y_16;
        pub const gap_y_neg_16 = StyledM.gap_y_neg_16;
        pub const gap_y_20 = StyledM.gap_y_20;
        pub const gap_y_neg_20 = StyledM.gap_y_neg_20;
        pub const gap_y_24 = StyledM.gap_y_24;
        pub const gap_y_neg_24 = StyledM.gap_y_neg_24;
        pub const gap_y_32 = StyledM.gap_y_32;
        pub const gap_y_neg_32 = StyledM.gap_y_neg_32;
        pub const gap_y_40 = StyledM.gap_y_40;
        pub const gap_y_neg_40 = StyledM.gap_y_neg_40;
        pub const gap_y_48 = StyledM.gap_y_48;
        pub const gap_y_neg_48 = StyledM.gap_y_neg_48;
        pub const gap_y_56 = StyledM.gap_y_56;
        pub const gap_y_neg_56 = StyledM.gap_y_neg_56;
        pub const gap_y_64 = StyledM.gap_y_64;
        pub const gap_y_neg_64 = StyledM.gap_y_neg_64;
        pub const gap_y_72 = StyledM.gap_y_72;
        pub const gap_y_neg_72 = StyledM.gap_y_neg_72;
        pub const gap_y_80 = StyledM.gap_y_80;
        pub const gap_y_neg_80 = StyledM.gap_y_neg_80;
        pub const gap_y_96 = StyledM.gap_y_96;
        pub const gap_y_neg_96 = StyledM.gap_y_neg_96;
        pub const gap_y_112 = StyledM.gap_y_112;
        pub const gap_y_neg_112 = StyledM.gap_y_neg_112;
        pub const gap_y_128 = StyledM.gap_y_128;
        pub const gap_y_neg_128 = StyledM.gap_y_neg_128;
        pub const gap_y_px = StyledM.gap_y_px;
        pub const gap_y_neg_px = StyledM.gap_y_neg_px;
        pub const gap_y_full = StyledM.gap_y_full;
        pub const gap_y_neg_full = StyledM.gap_y_neg_full;
        pub const gap_y_1_2 = StyledM.gap_y_1_2;
        pub const gap_y_neg_1_2 = StyledM.gap_y_neg_1_2;
        pub const gap_y_1_3 = StyledM.gap_y_1_3;
        pub const gap_y_neg_1_3 = StyledM.gap_y_neg_1_3;
        pub const gap_y_2_3 = StyledM.gap_y_2_3;
        pub const gap_y_neg_2_3 = StyledM.gap_y_neg_2_3;
        pub const gap_y_1_4 = StyledM.gap_y_1_4;
        pub const gap_y_neg_1_4 = StyledM.gap_y_neg_1_4;
        pub const gap_y_2_4 = StyledM.gap_y_2_4;
        pub const gap_y_neg_2_4 = StyledM.gap_y_neg_2_4;
        pub const gap_y_3_4 = StyledM.gap_y_3_4;
        pub const gap_y_neg_3_4 = StyledM.gap_y_neg_3_4;
        pub const gap_y_1_5 = StyledM.gap_y_1_5;
        pub const gap_y_neg_1_5 = StyledM.gap_y_neg_1_5;
        pub const gap_y_2_5 = StyledM.gap_y_2_5;
        pub const gap_y_neg_2_5 = StyledM.gap_y_neg_2_5;
        pub const gap_y_3_5 = StyledM.gap_y_3_5;
        pub const gap_y_neg_3_5 = StyledM.gap_y_neg_3_5;
        pub const gap_y_4_5 = StyledM.gap_y_4_5;
        pub const gap_y_neg_4_5 = StyledM.gap_y_neg_4_5;
        pub const gap_y_1_6 = StyledM.gap_y_1_6;
        pub const gap_y_neg_1_6 = StyledM.gap_y_neg_1_6;
        pub const gap_y_5_6 = StyledM.gap_y_5_6;
        pub const gap_y_neg_5_6 = StyledM.gap_y_neg_5_6;
        pub const gap_y_1_12 = StyledM.gap_y_1_12;
        pub const gap_y_neg_1_12 = StyledM.gap_y_neg_1_12;
        pub const rounded = StyledM.rounded;
        pub const rounded_none = StyledM.rounded_none;
        pub const rounded_xs = StyledM.rounded_xs;
        pub const rounded_sm = StyledM.rounded_sm;
        pub const rounded_md = StyledM.rounded_md;
        pub const rounded_lg = StyledM.rounded_lg;
        pub const rounded_xl = StyledM.rounded_xl;
        pub const rounded_2xl = StyledM.rounded_2xl;
        pub const rounded_3xl = StyledM.rounded_3xl;
        pub const rounded_full = StyledM.rounded_full;
        pub const rounded_t = StyledM.rounded_t;
        pub const rounded_t_none = StyledM.rounded_t_none;
        pub const rounded_t_xs = StyledM.rounded_t_xs;
        pub const rounded_t_sm = StyledM.rounded_t_sm;
        pub const rounded_t_md = StyledM.rounded_t_md;
        pub const rounded_t_lg = StyledM.rounded_t_lg;
        pub const rounded_t_xl = StyledM.rounded_t_xl;
        pub const rounded_t_2xl = StyledM.rounded_t_2xl;
        pub const rounded_t_3xl = StyledM.rounded_t_3xl;
        pub const rounded_t_full = StyledM.rounded_t_full;
        pub const rounded_b = StyledM.rounded_b;
        pub const rounded_b_none = StyledM.rounded_b_none;
        pub const rounded_b_xs = StyledM.rounded_b_xs;
        pub const rounded_b_sm = StyledM.rounded_b_sm;
        pub const rounded_b_md = StyledM.rounded_b_md;
        pub const rounded_b_lg = StyledM.rounded_b_lg;
        pub const rounded_b_xl = StyledM.rounded_b_xl;
        pub const rounded_b_2xl = StyledM.rounded_b_2xl;
        pub const rounded_b_3xl = StyledM.rounded_b_3xl;
        pub const rounded_b_full = StyledM.rounded_b_full;
        pub const rounded_r = StyledM.rounded_r;
        pub const rounded_r_none = StyledM.rounded_r_none;
        pub const rounded_r_xs = StyledM.rounded_r_xs;
        pub const rounded_r_sm = StyledM.rounded_r_sm;
        pub const rounded_r_md = StyledM.rounded_r_md;
        pub const rounded_r_lg = StyledM.rounded_r_lg;
        pub const rounded_r_xl = StyledM.rounded_r_xl;
        pub const rounded_r_2xl = StyledM.rounded_r_2xl;
        pub const rounded_r_3xl = StyledM.rounded_r_3xl;
        pub const rounded_r_full = StyledM.rounded_r_full;
        pub const rounded_l = StyledM.rounded_l;
        pub const rounded_l_none = StyledM.rounded_l_none;
        pub const rounded_l_xs = StyledM.rounded_l_xs;
        pub const rounded_l_sm = StyledM.rounded_l_sm;
        pub const rounded_l_md = StyledM.rounded_l_md;
        pub const rounded_l_lg = StyledM.rounded_l_lg;
        pub const rounded_l_xl = StyledM.rounded_l_xl;
        pub const rounded_l_2xl = StyledM.rounded_l_2xl;
        pub const rounded_l_3xl = StyledM.rounded_l_3xl;
        pub const rounded_l_full = StyledM.rounded_l_full;
        pub const rounded_tl = StyledM.rounded_tl;
        pub const rounded_tl_none = StyledM.rounded_tl_none;
        pub const rounded_tl_xs = StyledM.rounded_tl_xs;
        pub const rounded_tl_sm = StyledM.rounded_tl_sm;
        pub const rounded_tl_md = StyledM.rounded_tl_md;
        pub const rounded_tl_lg = StyledM.rounded_tl_lg;
        pub const rounded_tl_xl = StyledM.rounded_tl_xl;
        pub const rounded_tl_2xl = StyledM.rounded_tl_2xl;
        pub const rounded_tl_3xl = StyledM.rounded_tl_3xl;
        pub const rounded_tl_full = StyledM.rounded_tl_full;
        pub const rounded_tr = StyledM.rounded_tr;
        pub const rounded_tr_none = StyledM.rounded_tr_none;
        pub const rounded_tr_xs = StyledM.rounded_tr_xs;
        pub const rounded_tr_sm = StyledM.rounded_tr_sm;
        pub const rounded_tr_md = StyledM.rounded_tr_md;
        pub const rounded_tr_lg = StyledM.rounded_tr_lg;
        pub const rounded_tr_xl = StyledM.rounded_tr_xl;
        pub const rounded_tr_2xl = StyledM.rounded_tr_2xl;
        pub const rounded_tr_3xl = StyledM.rounded_tr_3xl;
        pub const rounded_tr_full = StyledM.rounded_tr_full;
        pub const rounded_bl = StyledM.rounded_bl;
        pub const rounded_bl_none = StyledM.rounded_bl_none;
        pub const rounded_bl_xs = StyledM.rounded_bl_xs;
        pub const rounded_bl_sm = StyledM.rounded_bl_sm;
        pub const rounded_bl_md = StyledM.rounded_bl_md;
        pub const rounded_bl_lg = StyledM.rounded_bl_lg;
        pub const rounded_bl_xl = StyledM.rounded_bl_xl;
        pub const rounded_bl_2xl = StyledM.rounded_bl_2xl;
        pub const rounded_bl_3xl = StyledM.rounded_bl_3xl;
        pub const rounded_bl_full = StyledM.rounded_bl_full;
        pub const rounded_br = StyledM.rounded_br;
        pub const rounded_br_none = StyledM.rounded_br_none;
        pub const rounded_br_xs = StyledM.rounded_br_xs;
        pub const rounded_br_sm = StyledM.rounded_br_sm;
        pub const rounded_br_md = StyledM.rounded_br_md;
        pub const rounded_br_lg = StyledM.rounded_br_lg;
        pub const rounded_br_xl = StyledM.rounded_br_xl;
        pub const rounded_br_2xl = StyledM.rounded_br_2xl;
        pub const rounded_br_3xl = StyledM.rounded_br_3xl;
        pub const rounded_br_full = StyledM.rounded_br_full;
        pub const shadow = StyledM.shadow;
        pub const shadow_none = StyledM.shadow_none;
        pub const shadow_2xs = StyledM.shadow_2xs;
        pub const shadow_xs = StyledM.shadow_xs;
        pub const shadow_sm = StyledM.shadow_sm;
        pub const shadow_md = StyledM.shadow_md;
        pub const shadow_lg = StyledM.shadow_lg;
        pub const shadow_xl = StyledM.shadow_xl;
        pub const shadow_2xl = StyledM.shadow_2xl;

        // -- element-specific methods forwarded from `Ext` (Img, Svg); void otherwise.
        pub const object_fit = if (@hasDecl(Ext, "object_fit")) Ext.object_fit else {};
        pub const grayscale = if (@hasDecl(Ext, "grayscale")) Ext.grayscale else {};
        pub const with_fallback = if (@hasDecl(Ext, "with_fallback")) Ext.with_fallback else {};
        pub const with_loading = if (@hasDecl(Ext, "with_loading")) Ext.with_loading else {};
        pub const path = if (@hasDecl(Ext, "path")) Ext.path else {};
        pub const external_path = if (@hasDecl(Ext, "external_path")) Ext.external_path else {};
        pub const data = if (@hasDecl(Ext, "data")) Ext.data else {};
        pub const with_transformation = if (@hasDecl(Ext, "with_transformation")) Ext.with_transformation else {};

        // -- GPUI `AnimationExt` for every styled element.
        pub const with_animation = animation_mod.AnimationExt(*Self).with_animation;
        pub const with_animations = animation_mod.AnimationExt(*Self).with_animations;
        pub const with_spring = animation_mod.AnimationExt(*Self).with_spring;
    };
}

/// A `div` has no element-specific extension.
pub const DivExt = struct {};

/// GPUI `Div`.
pub const Div = StyledElement(DivExt);

/// GPUI `Stateful<Div>`: in Zig, `.id()` returns the same `*Div`.
pub fn Stateful(comptime E: type) type {
    return E;
}

/// Creates a new `div` element.
pub fn div() *Div {
    return Div.new();
}

test {
    _ = Div;
}
