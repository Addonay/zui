//! Port of GPUI's `examples/text_wrapper.rs`.
//!
//! Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const TextOverflow = gpui.style.TextOverflow;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const size = gpui.size;

const HelloWorld = struct {
    pub fn render(_: *HelloWorld, _: *Window, _: *Context(HelloWorld)) *gpui.Div {
        const text = "The longest word 你好世界这段是中文，こんにちはこの段落は日本語です in any of the major " ++
            "English language dictionaries is pneumonoultramicroscopicsilicovolcanoconiosis, a word that " ++
            "refers to a lung disease contracted from the inhalation of very fine silica particles, " ++
            "a url https://github.com/zed-industries/zed/pull/35724?query=foo&bar=2, " ++
            "specifically from a volcano; medically, it is the same as silicosis.";
        return div()
            .id("page")
            .size_full()
            .flex()
            .flex_col()
            .p_2()
            .gap_2()
            .bg(gpui.white())
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_shrink_0()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .border_1()
                            .border_color(gpui.red())
                            .text_ellipsis()
                            .child("longer text in flex 1"),
                    )
                    .child(
                        div()
                            .flex()
                            .border_1()
                            .border_color(gpui.red())
                            .text_ellipsis()
                            .child("short flex"),
                    )
                    .child(
                        div()
                            .overflow_hidden()
                            .border_1()
                            .border_color(gpui.red())
                            .text_ellipsis()
                            .w_full()
                            .child("A short text in normal div"),
                    ),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_xl()
                    .truncate()
                    .border_1()
                    .border_color(gpui.blue())
                    .child(gpui.format("ELLIPSIS: {s}", .{text})),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_xl()
                    .overflow_hidden()
                    .text_ellipsis()
                    .line_clamp(2)
                    .border_1()
                    .border_color(gpui.blue())
                    .child(gpui.format("ELLIPSIS 2 lines: {s}", .{text})),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_xl()
                    .overflow_hidden()
                    .text_overflow(TextOverflow{ .truncate = "" })
                    .border_1()
                    .border_color(gpui.green())
                    .child(gpui.format("TRUNCATE: {s}", .{text})),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_xl()
                    .overflow_hidden()
                    .text_overflow(TextOverflow{ .truncate = "" })
                    .line_clamp(3)
                    .border_1()
                    .border_color(gpui.green())
                    .child(gpui.format("TRUNCATE 3 lines: {s}", .{text})),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_xl()
                    .whitespace_nowrap()
                    .overflow_hidden()
                    .border_1()
                    .border_color(gpui.black())
                    .child(gpui.format("NOWRAP: {s}", .{text})),
            )
            .child(div().text_xl().w_full().child(text));
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(800.0), px(600.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(HelloWorld) {
            return app.new(HelloWorld{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
