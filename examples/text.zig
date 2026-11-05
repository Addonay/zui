//! Port of GPUI's `examples/text.rs` (typography specimens).
//!
//! Differences from the Rust version:
//! - Font loading (`add_fonts`) is not ported: ZUI has no `TextSystem::add_fonts` yet,
//!   so the font families are resolved by the system.
//! - `set_menus` is not in ZUI yet.
//! - `Specimen` and `CharacterGrid` are `RenderOnce` in Rust. Here they are plain structs
//!   with a `render(self, window, cx)` method, called directly where the Rust version
//!   passes them to `.child(...)`, because a value-level `into_element` cannot reach the
//!   global text context.
//! - `Specimen.text_style` is always `None` in this example, so its override branch is not ported.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const hsla = gpui.hsla;
const px = gpui.px;
const relative = gpui.relative;
const rgb = gpui.rgb;
const size = gpui.size;
const point = gpui.point;
const Hsla = gpui.Hsla;

pub const TextContext = struct {
    font_size: f32,
    line_height: f32,
    type_scale: f32,

    pub fn default() TextContext {
        return .{
            .font_size = 16.0,
            .line_height = 1.3,
            .type_scale = 1.33,
        };
    }
};

/// GPUI `GlobalTextContext(pub Arc<TextContext>)`. The Arc is a plain value here.
pub const GlobalTextContext = struct {
    value: TextContext,
};

/// GPUI `ActiveTextContext for App`.
pub fn text_context(cx: *App) *const TextContext {
    return &cx.global(GlobalTextContext).value;
}

pub const SpecimenTheme = struct {
    bg: Hsla,
    fg: Hsla,

    pub fn default() SpecimenTheme {
        return .{
            .bg = gpui.white(),
            .fg = gpui.black(),
        };
    }

    pub fn invert(self: *const SpecimenTheme) SpecimenTheme {
        return .{
            .bg = self.fg,
            .fg = self.bg,
        };
    }
};

const Specimen = struct {
    id: []const u8,
    scale: f32 = 1.0,
    string: []const u8,
    invert: bool = false,

    pub fn new(id: usize) Specimen {
        return .{
            .id = gpui.format("specimen-{d}", .{id}),
            .string = "The quick brown fox jumps over the lazy dog",
        };
    }

    pub fn invert_(self: Specimen) Specimen {
        var s = self;
        s.invert = !s.invert;
        return s;
    }

    pub fn scale_(self: Specimen, scale: f32) Specimen {
        var s = self;
        s.scale = scale;
        return s;
    }

    pub fn render(self: Specimen, window: *Window, cx: *App) *Div {
        _ = window;
        const global_style = text_context(cx);

        const font_size = global_style.font_size;
        const line_height = global_style.line_height;

        var theme = SpecimenTheme.default();
        if (self.invert) theme = theme.invert();

        return div()
            .id(self.id)
            .bg(theme.bg)
            .text_color(theme.fg)
            .text_size(px(font_size * self.scale))
            .line_height(relative(line_height))
            .p(px(10.0))
            .child(self.string);
    }
};

const CharacterGrid = struct {
    scale: f32 = 1.0,
    invert: bool = false,

    pub fn new() CharacterGrid {
        return .{};
    }

    pub fn scale_(self: CharacterGrid, scale: f32) CharacterGrid {
        var s = self;
        s.scale = scale;
        return s;
    }

    pub fn render(self: CharacterGrid, _: *Window, _: *App) *Div {
        var theme = SpecimenTheme.default();
        if (self.invert) theme = theme.invert();

        const characters = [_][]const u8{
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "A", "B", "C", "D", "E", "F", "G",
            "H", "I", "J", "K", "L", "M", "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y",
            "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "p", "q",
            "r", "s", "t", "u", "v", "w", "x", "y", "z", "ẞ", "ſ", "ß", "ð", "Þ", "þ", "α", "β",
            "Γ", "γ", "Δ", "δ", "η", "θ", "ι", "κ", "Λ", "λ", "μ", "ν", "ξ", "π", "τ", "υ", "φ",
            "χ", "ψ", "∂", "а", "в", "Ж", "ж", "З", "з", "К", "к", "л", "м", "Н", "н", "Р", "р",
            "У", "у", "ф", "ч", "ь", "ы", "Э", "э", "Я", "я", "ij", "öẋ", ".,", "⣝⣑", "~", "*",
            "_", "^", "`", "'", "(", "{", "«", "#", "&", "@", "$", "¢", "%", "|", "?", "¶", "µ",
            "❮", "<=", "!=", "==", "--", "++", "=>", "->", "🏀", "🎊", "😍", "❤️", "👍", "👎",
        };

        const columns = 20;
        const rows = (characters.len + columns - 1) / columns;

        var grid = div().p_4().gap_2().flex().flex_col();
        var row_idx: usize = 0;
        while (row_idx < rows) : (row_idx += 1) {
            const start_idx = row_idx * columns;
            const end_idx = @min(start_idx + columns, characters.len);

            var row = div().w_full().flex().flex_row();
            for (characters[start_idx..end_idx]) |ch| {
                row = row.child(
                    div()
                        .text_center()
                        .size(px(62.0))
                        .bg(theme.bg)
                        .text_color(theme.fg)
                        .text_size(px(24.0))
                        .line_height(relative(1.0))
                        .child(ch),
                );
            }
            if (end_idx - start_idx < columns) {
                for (0..columns - (end_idx - start_idx)) |_| {
                    row = row.child(div().flex_1());
                }
            }
            grid = grid.child(row);
        }
        return grid;
    }
};

const FONT_FAMILIES = [_][]const u8{
    ".ZedMono",
    ".SystemUIFont",
    "Menlo",
    "Monaco",
    "Courier New",
};

const TextExample = struct {
    next_id: usize,
    font_family: []const u8,

    fn next_id_(self: *TextExample) usize {
        self.next_id += 1;
        return self.next_id;
    }

    /// GPUI `button(text, cx, on_click)`. The Rust closure becomes a comptime handler.
    fn button(text: []const u8, cx: *Context(TextExample), comptime on_click: fn (*TextExample, *Context(TextExample)) void) *Div {
        return div()
            .id(text)
            .flex_none()
            .child(text)
            .bg(gpui.black())
            .text_color(gpui.white())
            .active(gpui.style_refinement().opacity(0.8))
            .px_3()
            .py_1()
            .on_click(cx.listener(ClickAdapter(on_click).call));
    }

    fn ClickAdapter(comptime f: fn (*TextExample, *Context(TextExample)) void) type {
        return struct {
            fn call(this: *TextExample, _: *const ClickEvent, _: *Window, cx: *Context(TextExample)) void {
                f(this, cx);
            }
        };
    }

    fn cycle_font_family(this: *TextExample, cx: *Context(TextExample)) void {
        var new_family: []const u8 = FONT_FAMILIES[0];
        for (FONT_FAMILIES, 0..) |f, idx| {
            if (std.mem.eql(u8, f, this.font_family)) {
                new_family = FONT_FAMILIES[(idx + 1) % FONT_FAMILIES.len];
                break;
            }
        }

        this.font_family = new_family;
        cx.notify();
    }

    pub fn render(self: *TextExample, window: *Window, cx: *Context(TextExample)) *Div {
        const tcx = text_context(cx.app);
        const colors = cx.app.default_colors().*;

        const font_size = tcx.font_size;
        const line_height = tcx.line_height;
        const type_scale = tcx.type_scale;

        const step_down_2 = 1.0 / (type_scale * type_scale);
        const step_down_1 = 1.0 / type_scale;
        const base = 1.0;
        const step_up_1 = base * type_scale;
        const step_up_2 = step_up_1 * type_scale;
        const step_up_3 = step_up_2 * type_scale;
        const step_up_4 = step_up_3 * type_scale;
        const step_up_5 = step_up_4 * type_scale;
        const step_up_6 = step_up_5 * type_scale;

        // A flex column, unlike GPUI's example: there the scroll area is as tall as the window
        // below the header, so its last lines can never be reached.
        return div()
            .font_family(self.font_family)
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .bg(gpui.white())
                    .border_b_1()
                    .border_color(gpui.black())
                    .p_3()
                    .flex()
                    .child(button(self.font_family, cx, cycle_font_family)),
            )
            .child(
                div()
                    .id("text-example")
                    .overflow_y_scroll()
                    .overflow_x_hidden()
                    .bg(rgb(0xffffff))
                    .size_full()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .p_3()
                            .text_size(px(font_size))
                            .line_height(relative(line_height))
                            .children(.{
                                div().child("CJK: 中文「日本語」한글"),
                                div().child("Kana: が / か\u{3099}; Hangul: 각 / \u{1100}\u{1161}\u{11a8}"),
                                div().child("Emoji: 😀 ❤️ ❤\u{fe0e} 👍🏽 🇯🇵 1\u{fe0f}\u{20e3} 👩‍💻 👨‍👩‍👧‍👦"),
                            }),
                    )
                    .child(div().child(CharacterGrid.new().scale_(base).render(window, cx.app)))
                    .child(
                        div()
                            .child(specimen(self, window, cx.app, step_down_2, false))
                            .child(specimen(self, window, cx.app, step_down_2, true))
                            .child(specimen(self, window, cx.app, step_down_1, false))
                            .child(specimen(self, window, cx.app, step_down_1, true))
                            .child(specimen(self, window, cx.app, base, false))
                            .child(specimen(self, window, cx.app, base, true))
                            .child(specimen(self, window, cx.app, step_up_1, false))
                            .child(specimen(self, window, cx.app, step_up_1, true))
                            .child(specimen(self, window, cx.app, step_up_2, false))
                            .child(specimen(self, window, cx.app, step_up_2, true))
                            .child(specimen(self, window, cx.app, step_up_3, false))
                            .child(specimen(self, window, cx.app, step_up_3, true))
                            .child(specimen(self, window, cx.app, step_up_4, false))
                            .child(specimen(self, window, cx.app, step_up_4, true))
                            .child(specimen(self, window, cx.app, step_up_5, false))
                            .child(specimen(self, window, cx.app, step_up_5, true))
                            .child(specimen(self, window, cx.app, step_up_6, false))
                            .child(specimen(self, window, cx.app, step_up_6, true)),
                    ),
            )
            .child(div().w(px(240.0)).h_full().bg(colors.container));
    }
};

/// `Specimen::new(self.next_id()).scale(scale)`, plus `.invert()` when `invert` is set.
fn specimen(self: *TextExample, window: *Window, cx: *App, scale: f32, invert: bool) *Div {
    var s = Specimen.new(self.next_id_()).scale_(scale);
    if (invert) s = s.invert_();
    return s.render(window, cx);
}

fn run_example(cx: *App) void {
    // cx.set_menus(...) and cx.text_system().add_fonts(...) are not ported: they are not in ZUI yet.
    cx.init_colors();
    cx.set_global(GlobalTextContext{ .value = TextContext.default() });

    _ = cx.open_window(
        .{
            .titlebar = .{ .title = "GPUI Typography" },
            .window_bounds = .{ .windowed = Bounds(gpui.Pixels){ .origin = point(px(0.0), px(0.0)), .size = size(px(920.0), px(720.0)) } },
        },
        struct {
            fn build(_: *Window, app: *App) gpui.Entity(TextExample) {
                return app.new(TextExample{
                    .next_id = 0,
                    .font_family = ".ZedMono",
                });
            }
        }.build,
    ) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
