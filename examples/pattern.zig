//! Port of GPUI's `examples/pattern.rs`.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const linear_color_stop = gpui.linear_color_stop;
const linear_gradient = gpui.linear_gradient;
const pattern_slash = gpui.pattern_slash;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const PatternExample = struct {
    pub fn render(_: *PatternExample, _: *Window, _: *Context(PatternExample)) *gpui.Div {
        return div()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0xffffff))
            .size(px(600.0))
            .justify_center()
            .items_center()
            .shadow_lg()
            .text_xl()
            .text_color(rgb(0x000000))
            .child("Pattern Example")
            .child(
                div()
                    .flex()
                    .flex_col()
                    .border_1()
                    .border_color(gpui.blue())
                    .child(div().w(px(54.0)).h(px(18.0)).bg(pattern_slash(
                        gpui.red(),
                        18.0 / 4.0,
                        18.0 / 4.0,
                    )))
                    .child(div().w(px(54.0)).h(px(18.0)).bg(pattern_slash(
                        gpui.red(),
                        18.0 / 4.0,
                        18.0 / 4.0,
                    )))
                    .child(div().w(px(54.0)).h(px(18.0)).bg(pattern_slash(
                        gpui.red(),
                        18.0 / 4.0,
                        18.0 / 4.0,
                    )))
                    .child(div().w(px(54.0)).h(px(18.0)).bg(pattern_slash(
                        gpui.red(),
                        18.0 / 4.0,
                        18.0 / 2.0,
                    ))),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .border_1()
                    .border_color(gpui.blue())
                    .bg(gpui.green().opacity(0.16))
                    .child("Elements the same height should align")
                    .child(div().w(px(256.0)).h(px(56.0)).bg(pattern_slash(
                        gpui.red(),
                        56.0 / 6.0,
                        56.0 / 6.0,
                    )))
                    .child(div().w(px(256.0)).h(px(56.0)).bg(pattern_slash(
                        gpui.green(),
                        56.0 / 6.0,
                        56.0 / 6.0,
                    )))
                    .child(div().w(px(256.0)).h(px(56.0)).bg(pattern_slash(
                        gpui.blue(),
                        56.0 / 6.0,
                        56.0 / 6.0,
                    )))
                    .child(div().w(px(256.0)).h(px(26.0)).bg(pattern_slash(
                        gpui.yellow(),
                        56.0 / 6.0,
                        56.0 / 6.0,
                    ))),
            )
            .child(
                div()
                    .border_1()
                    .border_color(gpui.blue())
                    .w(px(240.0))
                    .h(px(40.0))
                    .bg(gpui.red()),
            )
            .child(
                div()
                    .border_1()
                    .border_color(gpui.blue())
                    .w(px(240.0))
                    .h(px(40.0))
                    .bg(linear_gradient(
                        45.0,
                        linear_color_stop(gpui.red(), 0.0),
                        linear_color_stop(gpui.blue(), 1.0),
                    )),
            );
    }
};

fn run_example(cx: *App) void {
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(600.0), px(600.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(PatternExample) {
            return app.new(PatternExample{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
