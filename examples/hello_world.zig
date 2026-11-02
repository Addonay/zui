//! Port of GPUI's `examples/hello_world.rs`.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const HelloWorld = struct {
    text: []const u8,

    pub fn render(self: *HelloWorld, _: *Window, _: *Context(HelloWorld)) *gpui.Div {
        return div()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0x505050))
            .size(px(500.0))
            .justify_center()
            .items_center()
            .shadow_lg()
            .border_1()
            .border_color(rgb(0x0000ff))
            .text_xl()
            .text_color(rgb(0xffffff))
            .child(gpui.format("Hello, {s}!", .{self.text}))
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(div().size_8().bg(gpui.red()).border_1().border_dashed().rounded_md().border_color(gpui.white()))
                    .child(div().size_8().bg(gpui.green()).border_1().border_dashed().rounded_md().border_color(gpui.white()))
                    .child(div().size_8().bg(gpui.blue()).border_1().border_dashed().rounded_md().border_color(gpui.white()))
                    .child(div().size_8().bg(gpui.yellow()).border_1().border_dashed().rounded_md().border_color(gpui.white()))
                    .child(div().size_8().bg(gpui.black()).border_1().border_dashed().rounded_md().rounded_md().border_color(gpui.white()))
                    .child(div().size_8().bg(gpui.white()).border_1().border_dashed().rounded_md().border_color(gpui.black())),
            );
    }
};

fn run(cx: *App) void {
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(500.0), px(500.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(HelloWorld) {
            return app.new(HelloWorld{ .text = "World" });
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run);
}
