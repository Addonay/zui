//! Port of GPUI's `examples/scrollable.rs`.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const size = gpui.size;

const Scrollable = struct {
    pub fn render(_: *Scrollable, _: *Window, _: *Context(Scrollable)) *gpui.Div {
        return div()
            .size_full()
            .id("vertical")
            .p_4()
            .overflow_scroll()
            .bg(gpui.white())
            .child("Example for test 2 way scroll in nested layout")
            .child(
                div()
                    .h(px(5000.0))
                    .border_1()
                    .border_color(gpui.blue())
                    .bg(gpui.blue().opacity(0.05))
                    .p_4()
                    .child(
                        div()
                            .mb_5()
                            .w_full()
                            .id("horizontal")
                            .overflow_scroll()
                            .child(
                                div()
                                    .w(px(2000.0))
                                    .h(px(150.0))
                                    .bg(gpui.green().opacity(0.1))
                                    .hover(gpui.style_refinement().bg(gpui.green().opacity(0.2)))
                                    .border_1()
                                    .border_color(gpui.green())
                                    .p_4()
                                    .child("Scroll Horizontal"),
                            ),
                    )
                    .child("Scroll Vertical"),
            );
    }
};

fn run_example(cx: *App) void {
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(500.0), px(500.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(Scrollable) {
            return app.new(Scrollable{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
