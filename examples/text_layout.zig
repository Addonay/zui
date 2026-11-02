//! Port of GPUI's `examples/text_layout.rs`.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const FontStyle = gpui.FontStyle;
const FontWeight = gpui.FontWeight;
const StyledText = gpui.StyledText;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const size = gpui.size;

const HelloWorld = struct {
    pub fn render(_: *HelloWorld, _: *Window, _: *Context(HelloWorld)) *gpui.Div {
        const highlights = [_]gpui.elements.text.Highlight{
            .{ .range = .{ .start = 0, .end = 1 }, .style = .{ .font_weight = FontWeight.EXTRA_BOLD } },
            .{ .range = .{ .start = 2, .end = 3 }, .style = .{ .font_style = FontStyle.italic } },
        };
        return div()
            .bg(gpui.white())
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .size_full()
            .child(div().child("Text left"))
            .child(div().text_center().child("Text center"))
            .child(div().text_right().child("Text right"))
            .child(div().text_decoration_1().child("Text left (underline)"))
            .child(
                div()
                    .text_center()
                    .text_decoration_1()
                    .child("Text center (underline)"),
            )
            .child(
                div()
                    .text_right()
                    .text_decoration_1()
                    .child("Text right (underline)"),
            )
            .child(div().line_through().child("Text left (line_through)"))
            .child(
                div()
                    .text_center()
                    .line_through()
                    .child("Text center (line_through)"),
            )
            .child(
                div()
                    .text_right()
                    .line_through()
                    .child("Text right (line_through)"),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .justify_between()
                    .child(
                        div()
                            .w(px(400.0))
                            .border_1()
                            .border_color(gpui.blue())
                            .p_1()
                            .whitespace_nowrap()
                            .overflow_hidden()
                            .text_center()
                            .child("A long non-wrapping text align center"),
                    )
                    .child(
                        div()
                            .w_32()
                            .border_1()
                            .border_color(gpui.blue())
                            .p_1()
                            .whitespace_nowrap()
                            .overflow_hidden()
                            .text_right()
                            .child("100%"),
                    ),
            )
            .child(div().flex().gap_2().justify_between().child(
                StyledText.new("ABCD").with_highlights(&highlights),
            ));
    }
};

fn run_example(cx: *App) void {
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
