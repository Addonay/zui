//! Port of GPUI's `examples/active_state_bug.rs`.
//! Click the button — the `.active()` background gets stuck on every other click.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const ClickEvent = gpui.ClickEvent;
const div = gpui.div;
const hsla = gpui.hsla;
const px = gpui.px;
const size = gpui.size;

const Example = struct {
    pub fn render(_: *Example, _: *Window, _: *Context(Example)) *gpui.Div {
        // Colors from Zed's default dark theme
        const bg = hsla(215.0 / 360.0, 0.12, 0.15, 1.0);
        const text = hsla(221.0 / 360.0, 0.11, 0.86, 1.0);
        const hover = hsla(225.0 / 360.0, 0.118, 0.267, 1.0);
        const active = hsla(220.0 / 360.0, 0.118, 0.20, 1.0);

        return div().bg(bg).size_full().p_1().child(
            div()
                .id("button")
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_sm()
                .text_color(text)
                .hover(gpui.style_refinement().bg(hover))
                .active(gpui.style_refinement().bg(active))
                .on_click(struct {
                    fn on_click(_: *const ClickEvent, _: *Window, _: *App) void {}
                }.on_click)
                .child("Click me"),
        );
    }
};

fn run(cx: *App) void {
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = Bounds(gpui.Pixels).centered(null, size(px(200.0), px(60.0)), cx) } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(Example) {
            return app.new(Example{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run);
}
